// lib/services/sync_service.dart — Motor Offline-First con detección automática de red
// v3.1.20+58: Sincronización diferencial ultra rápida con SharedPreferences como
//             caché de timestamp, catálogos 24h, PUSH concurrente y timeout garantizado.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'local_db_service.dart';



/// Evento global que dispara cuando el servidor responde 401 (sesión expirada).
/// El AppShell o el Router escuchan este stream para redirigir al Login.
/// IMPORTANTE: solo se emite desde login/refresh explícito, NO desde sync de fondo.
final sessionExpiredEvents = StreamController<void>.broadcast();

enum SyncState { idle, syncing, success, error, offline }

class SyncService extends ChangeNotifier {
  SyncState _state     = SyncState.idle;
  bool      isSyncing  = false;
  String    _message   = '';
  String?   _errorMessage;
  int       _pending   = 0;
  DateTime? _lastSync;
  StreamSubscription? _connSub;
  Timer?    _syncWatchdog;  // [FIX-CUELGUE] Watchdog: libera el lock si sync excede 90s

  String? get errorMessage => _errorMessage;

  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> get orders => _orders;

  // ── Contadores reactivos del Dashboard ───────────────────────────────────
  int _kpiTotal   = 0;
  int _kpiProceso = 0;
  int _kpiCerrado = 0;
  int _kpiFisico  = 0;

  int get kpiTotal   => _kpiTotal;
  int get kpiProceso => _kpiProceso;
  int get kpiCerrado => _kpiCerrado;
  int get kpiFisico  => _kpiFisico;

  /// Alias de conveniencia para sincronizar todo
  Future<void> sincronizarTodo() => performSync();

  /// Recarga incondicionalmente las órdenes desde SQLite hacia la memoria del servicio y actualiza contadores
  Future<void> cargarOrdenes() async {
    try {
      final db = LocalDbService.instance;
      final usuario = AuthService.usuarioActual;
      final userRole = (usuario?.rol ?? ApiService.instance.userRole ?? '').toLowerCase();
      final isTecnicoUser = (usuario != null && (usuario.rol.toUpperCase() == "TECNICO" || usuario.isTecnico)) ||
          (userRole.contains('tec') || userRole.contains('serv') || userRole.contains('oper'));
      final idTecnico = usuario?.id ?? ApiService.instance.lastIdTecnico;
      final currentNombre = usuario?.nombre ?? ApiService.instance.lastNombre;
      final isAdmin = !isTecnicoUser && (userRole.contains('admin') || userRole.contains('logist') || userRole.contains('recep') || (usuario?.username.toLowerCase() == 'ivancolin1207'));

      var localDbOrders = (isAdmin || !isTecnicoUser)
          ? await db.getAllOs()
          : await db.getOsForTecnico(
              nombreTecnico: currentNombre,
              idTecnico: idTecnico,
            );

      if (localDbOrders.isEmpty && isTecnicoUser && !isAdmin) {
        final all = await db.getAllOs();
        if (all.isNotEmpty) {
          final myNom = (currentNombre ?? '').toLowerCase().trim();
          localDbOrders = all.where((o) {
            final oId = int.tryParse(o['id_tecnico']?.toString() ?? '');
            if (oId != null && oId > 0 && idTecnico != null && idTecnico > 0 && oId == idTecnico) return true;
            final t = (o['tecnico']?.toString() ?? '').toLowerCase().trim();
            if (t.isNotEmpty && myNom.isNotEmpty) {
              return t == myNom || t.contains(myNom) || myNom.contains(t);
            }
            return false;
          }).toList();
        }
      }

      setOrdersFromPull(localDbOrders);
      debugPrint('[Sync] Dashboard recargado incondicionalmente desde SQLite: ${localDbOrders.length} OS');
      notifyListeners();
    } catch (e) {
      debugPrint('[Sync cargarOrdenes] Error: $e');
    }
  }

  /// Resguardo de base local: si la red falla o retorna error,
  /// muestra de inmediato los datos locales de SQLite para que nunca quede en ceros.
  Future<void> _fallbackCargarLocal() => cargarOrdenes();

  /// Asigna directamente la lista de órdenes recibidas en memoria
  /// y actualiza de inmediato las variables reactivas de los contadores.
  void setOrdersFromPull(List<Map<String, dynamic>> osList) {
    _orders = List<Map<String, dynamic>>.from(osList);
    _updateCounters(_orders);
    notifyListeners();
  }

  /// Actualiza en memoria los datos de una orden específica de forma reactiva
  void updateLocalOrder(String folio, Map<String, dynamic> updates) {
    final folioTrim = folio.trim();
    final idx = _orders.indexWhere((o) =>
        (o['folio_os']?.toString().trim() == folioTrim) ||
        (o['folio']?.toString().trim() == folioTrim));
    if (idx >= 0) {
      _orders[idx] = {..._orders[idx], ...updates};
      _updateCounters(_orders);
      notifyListeners();
    }
  }

  void _updateCounters(List<Map<String, dynamic>> list) {
    _kpiTotal = list.length;
    int proceso = 0;
    int cerrado = 0;
    int fisico  = 0;

    final db = LocalDbService.instance;

    for (final o in list) {
      final estado = (o['estado'] as String? ?? '').trim().toUpperCase();
      final estatus = (o['estatus'] as String? ?? '').trim().toUpperCase();
      final modalidad = (o['modalidad'] as String? ?? '').trim().toUpperCase();
      final pdfPath = (o['pdf_path_local'] as String? ?? '').trim();
      final folio = (o['folio_os'] as String? ?? o['folio'] as String? ?? '').trim();

      final bool hasLocalPdf = (pdfPath.isNotEmpty && File(pdfPath).existsSync()) ||
          db.checkPdfExistsOnDiskSync(folio, pdfPath);

      final isCerrada = estado == 'CERRADA' ||
          estado == 'CERRADO' ||
          estado == 'COMPLETADA' ||
          estado == 'COMPLETADA_DIGITAL' ||
          estado == 'COMPLETADA_FISICA' ||
          estado == 'FIRMADA' ||
          estatus == 'CERRADO' ||
          estatus == 'CERRADA' ||
          estatus == 'COMPLETADA' ||
          hasLocalPdf;

      final isCancelada = estado == 'CANCELADA' || estado == 'CANCELADO' || estatus == 'CANCELADO';

      if (isCerrada) {
        cerrado++;
      } else if (!isCancelada) {
        proceso++;
      }

      if (modalidad.contains('FISIC') || modalidad.contains('FÍSIC')) {
        fisico++;
      }
    }

    _kpiProceso = proceso;
    _kpiCerrado = cerrado;
    _kpiFisico  = fisico;
  }

  SyncState get state         => _state;
  String    get message       => _message;
  String    get statusMessage => _message;
  int       get pending       => _pending;
  DateTime? get lastSync => _lastSync;

  // ── Iniciar monitor de red ────────────────────────────────────────────────

  void startNetworkMonitor() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _state != SyncState.syncing) {
        performSync();
      } else if (!online) {
        _setState(SyncState.offline, 'Sin conexión a la red');
      }
    });
    // Verificar estado inicial
    _checkAndSync();
  }

  void stopNetworkMonitor() {
    _connSub?.cancel();
    _connSub = null;
  }

  Future<void> _checkAndSync() async {
    final results = await Connectivity().checkConnectivity();
    final online  = results.any((r) => r != ConnectivityResult.none);
    if (online) await performSync();
  }

  // ── Ciclo de sincronización completo ──────────────────────────────────────

  /// Fuerza el reseteo del estado si quedó trabado en "Sincronizando..."
  void forceResetSync() {
    debugPrint('[Sync] forceResetSync() llamado manualmente — liberando lock');
    _syncWatchdog?.cancel();
      isSyncing = false;
    _syncWatchdog = null;
    _state = SyncState.idle;
    _message = 'Listo';
    notifyListeners();
  }

  /// Descarga el repositorio de calibraciones concluidas (todos los técnicos)
  /// a la tabla local `calibraciones_consulta`. Solo lectura; errores ignorados.
  Future<void> _refrescarRepositorioCalibraciones() async {
    try {
      final rows = await ApiService.instance
          .getCalibracionesConsulta()
          .timeout(const Duration(seconds: 10));
      await LocalDbService.instance.guardarCalibracionesConsulta(rows);
      debugPrint('[Sync CALIB] Repositorio de calibraciones: ${rows.length} órdenes en caché');
    } catch (e) {
      debugPrint('[Sync CALIB] Refresco de repositorio ignorado: $e');
    }
  }

  Future<void> performSync() async {
    // ═══════════════════════════════════════════════════════════════════════
    //  GUARD: un solo sync activo a la vez; el watchdog libera si se cuelga.
    // ═══════════════════════════════════════════════════════════════════════
    if (_state == SyncState.syncing) {
      debugPrint('[Sync] Ya en curso — ignorando solicitud duplicada');
      return;
    }

    // Marcar estado Y bandera de forma atómica ANTES de cualquier await
    _state    = SyncState.syncing;
    _message  = 'Sincronizando...';
    isSyncing = true;
    notifyListeners();

    // Watchdog de 20s — libera el lock aunque todo lo demás falle
    _syncWatchdog?.cancel();
    _syncWatchdog = Timer(const Duration(seconds: 20), () {
      if (_state == SyncState.syncing || isSyncing) {
        debugPrint('[Sync] ⚠️ WATCHDOG 20s: forzando liberación del lock');
        _state    = SyncState.error;
        _message  = 'Tiempo agotado. Toca para reintentar.';
        isSyncing = false;
        notifyListeners();
      }
    });

    try {
      // ── Fase 0: Despertar servidor (Cold Start Render) ────────────────────
      // Timeout ESTRICTO 3s — si Render no responde (cold start), continuar de inmediato
      try {
        _message = 'Despertando servidor...';
        notifyListeners();
        await ApiService.instance.pingServer()
            .timeout(const Duration(seconds: 3), onTimeout: () => false);
      } catch (_) {
        debugPrint('[Sync] pingServer ignorado — continuando');
      }

      // ── Fase 0.5: Autenticación (sin HTTP si ya hay token en memoria) ─────
      if (!ApiService.instance.isAuthenticated) {
        _message = 'Obteniendo sesión...';
        notifyListeners();

        // Paso 1: cargar token de SecureStorage (sin llamada HTTP)
        bool tokenLoaded = false;
        try {
          const st = FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );
          final savedToken = await st
              .read(key: 'jwt_token')
              .timeout(const Duration(seconds: 5), onTimeout: () => null);
          if (savedToken != null && savedToken.isNotEmpty) {
            ApiService.instance.injectToken(savedToken);
            tokenLoaded = true;
            debugPrint('[SYNC] Token inyectado desde SecureStorage');
          }
        } catch (e) {
          debugPrint('[SYNC] Error leyendo token de storage: $e');
        }

        // Paso 2: login rápido si no había token guardado
        if (!tokenLoaded) {
          try {
            const st = FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );
            final savedUser = await st
                .read(key: 'pesa_username')
                .timeout(const Duration(seconds: 3), onTimeout: () => null);
            final savedPass = await st
                .read(key: 'pesa_cred_pass')
                .timeout(const Duration(seconds: 3), onTimeout: () => null);
            if (savedUser != null && savedUser.isNotEmpty && savedPass != null) {
              final loginErr = await ApiService.instance
                  .login(savedUser, savedPass)
                  .timeout(
                    const Duration(seconds: 10),
                    onTimeout: () => 'Timeout login 10s',
                  );
              if (loginErr != null) {
                debugPrint('[SYNC] Login rápido falló: $loginErr');
              }
            }
          } catch (e) {
            debugPrint('[SYNC] Error en login rápido: $e');
          }
        }

        if (!ApiService.instance.isAuthenticated) {
          _state   = SyncState.error;
          _message = 'Sin sesión activa. Vuelve a iniciar sesión.';
          return; // el finally liberará isSyncing
        }
      }

      // ── Fase 1: PUSH — cada sub-operación aislada con timeout propio ──────
      _message = 'Subiendo cambios locales...';
      notifyListeners();

      // Reconciliación única (v3.1.20+73): órdenes cerradas que el servidor
      // respondió 200 pero NO registró (id NULL en PostgreSQL) se re-encolan.
      try {
        final prefsRec = await SharedPreferences.getInstance();
        if (!(prefsRec.getBool('reconcile_estatus_v73_done') ?? false)) {
          final n = await LocalDbService.instance.marcarCerradasParaReenvio(dias: 30);
          await prefsRec.setBool('reconcile_estatus_v73_done', true);
          debugPrint('[Sync] ♻️ Reconciliación v73: $n órdenes cerradas re-encoladas para PUSH');
        }
      } catch (e) {
        debugPrint('[Sync] Reconciliación v73 ignorada: $e');
      }

      try {
        final pushed = await _pushPendientes()
            .timeout(const Duration(seconds: 15), onTimeout: () => 0);
        debugPrint('[Sync PUSH] $pushed OS subidas');
      } catch (e) {
        debugPrint('[Sync PUSH pendientes] Error ignorado: $e');
      }

      // Reintentar resets que fallaron por red offline en el ciclo anterior
      try {
        final resets = await _pushResetsPendientes()
            .timeout(const Duration(seconds: 10), onTimeout: () => 0);
        if (resets > 0) debugPrint('[Sync PUSH RESET] $resets resets propagados al servidor');
      } catch (e) {
        debugPrint('[Sync PUSH RESET] Error ignorado: $e');
      }

      try {
        final pdfsPushed = await _subirPdfsPendientes()
            .timeout(const Duration(seconds: 15), onTimeout: () => 0);
        debugPrint('[Sync PUSH PDF] $pdfsPushed PDFs subidos');
      } catch (e) {
        debugPrint('[Sync PUSH PDF] Error ignorado: $e');
      }

      // ── Catálogos: solo si han pasado > 24h desde la última descarga ──────
      // Desacoplado del ciclo rutinario: NO actualizar clientes/técnicos en cada sync.
      final lastCatSync = await LocalDbService.instance.getLastCatalogSyncTime();
      final catalogStale = lastCatSync == null ||
          DateTime.now().toUtc().difference(lastCatSync).inHours >= 24;

      if (catalogStale) {
        try {
          await _pushMarcasModelos()
              .timeout(const Duration(seconds: 8), onTimeout: () {});
        } catch (e) {
          debugPrint('[Sync PUSH Marcas/Modelos] Error ignorado: $e');
        }
      } else {
        debugPrint('[Sync] Catálogos frescos (< 24h) — skip PUSH marcas/modelos');
      }

      try {
        await _pushFirmasPendientes()
            .timeout(const Duration(seconds: 10), onTimeout: () {});
      } catch (e) {
        debugPrint('[Sync PUSH Firmas] Error ignorado: $e');
      }

      // ── Fase 2: PULL diferencial — verificación de conteo local y reset si vacía ───
      final db = await LocalDbService.instance.database;
      final prefs = await SharedPreferences.getInstance();

      int conteoLocal = 0;
      try {
        conteoLocal = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ordenes')
        ) ?? 0;
      } catch (_) {
        conteoLocal = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ordenes_servicio')
        ) ?? 0;
      }

      String? updatedAfter;
      if (conteoLocal > 0) {
        updatedAfter = prefs.getString('last_sync_timestamp');
        // v3.1.20+76: backfill único de tipo_servicio. Las OS descargadas por
        // /api/v1/ordenes antes de este fix llegaron sin tipo → forzar 1 PULL completo.
        if (!(prefs.getBool('backfill_tipo_servicio_v76') ?? false)) {
          debugPrint('[SYNC] Backfill v76: PULL completo para recuperar tipo_servicio');
          updatedAfter = null;
          await prefs.remove('last_sync_timestamp');
          await prefs.setBool('backfill_tipo_servicio_v76', true);
        }
      } else {
        // SI LOCAL ESTÁ EN 0, OBLIGAR CARGA COMPLETA
        debugPrint("[SYNC] Base local vacía (0 registros). Forzando PULL completo sin updated_after.");
        await prefs.remove('last_sync_timestamp');
        await LocalDbService.instance.resetLastSyncTime();
        updatedAfter = null;
      }

      _message = 'Descargando órdenes...';
      notifyListeners();

      try {
        final pullCount = await _pullNuevos(updatedAfter: updatedAfter).timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            debugPrint('[Sync PULL] ⏱ TIMEOUT 25s — sirviendo datos locales inmediatamente');
            _fallbackCargarLocal();
            return 0;
          },
        );

        // Catálogos lazy: pull solo si > 24h desde la última descarga
        if (catalogStale) {
          try {
            await _pullMarcasModelos()
                .timeout(const Duration(seconds: 8), onTimeout: () {});
            await LocalDbService.instance.setLastCatalogSyncTime(DateTime.now().toUtc());
          } catch (_) {}
        } else {
          debugPrint('[Sync] Catálogos frescos (< 24h) — skip PULL marcas/modelos');
        }

        _lastSync = DateTime.now();
        await _refreshPending();
        _state   = SyncState.success;
        _message = pullCount > 0
            ? 'Sincronizado ✓ ($pullCount nuevas OS)'
            : 'Sincronizado ✓ Sin cambios nuevos';

        // Repositorio de Calibraciones (solo supervisión metrológica):
        // refresco en segundo plano, sin bloquear el ciclo ni el watchdog.
        // Se guarda en la tabla separada `calibraciones_consulta`.
        if (AuthService.esSupervisorCalibracionActual) {
          unawaited(_refrescarRepositorioCalibraciones());
        }

      } on TimeoutException catch (e) {
        _state   = SyncState.offline;
        _errorMessage = 'Timeout: ${e.message ?? '20s agotados'}';
        _message = _errorMessage!;
        debugPrint('[SYNC ERROR] $_errorMessage');
        notifyListeners();
        await _fallbackCargarLocal();

      } on SocketException catch (e) {
        _state   = SyncState.offline;
        _errorMessage = 'Sin conexión: ${e.message}';
        _message = _errorMessage!;
        debugPrint('[SYNC ERROR] $_errorMessage');
        notifyListeners();
        await _fallbackCargarLocal();

      } on HttpException catch (e) {
        final msg = e.message;
        debugPrint('[SYNC ERROR] HTTP: $msg');
        if (msg.contains('401')) {
          // Intentar refrescar token y reintentar pull UNA sola vez
          bool refreshed = false;
          try {
            refreshed = await ApiService.instance
                .silentRefresh()
                .timeout(const Duration(seconds: 10), onTimeout: () => false);
          } catch (_) {}

          if (refreshed) {
            try {
              final pullRetry = await _pullNuevos()
                  .timeout(const Duration(seconds: 20), onTimeout: () => 0);
              _lastSync = DateTime.now();
              await _refreshPending();
              _state   = SyncState.success;
              _errorMessage = null;
              _message = pullRetry > 0
                  ? 'Sincronizado (reintento): $pullRetry OS'
                  : 'Sincronizado. Sin cambios nuevos.';
              notifyListeners();
            } catch (retryErr) {
              debugPrint('[SYNC ERROR] Error en reintento post-refresh: $retryErr');
              _state   = SyncState.error;
              _errorMessage = 'Reintento falló: $retryErr';
              _message = _errorMessage!;
              notifyListeners();
              await _fallbackCargarLocal();
            }
          } else {
            _state   = SyncState.error;
            _errorMessage = 'Sesión expirada (401). Vuelve a iniciar sesión.';
            _message = _errorMessage!;
            notifyListeners();
            await _fallbackCargarLocal();
          }
        } else {
          _state   = SyncState.error;
          _errorMessage = msg;
          _message = msg;
          notifyListeners();
          await _fallbackCargarLocal();
        }

      } catch (pullErr, pullSt) {
        final msg = 'Error: $pullErr';
        debugPrint('[SYNC ERROR] Inesperado en PULL: $msg\n$pullSt');
        _state   = SyncState.error;
        _errorMessage = msg;
        _message = msg;
        notifyListeners();
        await _fallbackCargarLocal();
      }

    } catch (e, st) {
      final msg = 'Excepción: $e';
      debugPrint('[SYNC ERROR] EXCEPCIÓN GENERAL: $msg\n$st');
      _state   = SyncState.error;
      _errorMessage = msg;
      _message = msg;
      notifyListeners();
      await _fallbackCargarLocal();

    } finally {
      // ╔══════════════════════════════════════════════════════════════╗
      // ║  LIBERACIÓN OBLIGATORIA E INCONDICIONAL DEL LOCK            ║
      // ║  Este bloque SIEMPRE se ejecuta — sin importar qué pasó     ║
      // ╚══════════════════════════════════════════════════════════════╝
      _syncWatchdog?.cancel();
      _syncWatchdog = null;
      isSyncing     = false;
      // Guard de seguridad: si por algún motivo el estado quedó en syncing
      if (_state == SyncState.syncing) {
        _state   = SyncState.error;
        _message = _errorMessage ?? 'Sincronización interrumpida. Toca para reintentar.';
      }
      notifyListeners();
      // Persistir timestamp en SharedPreferences SOLO si el sync fue exitoso Y SQLite tiene registros
      // (evita guardar timestamp si la base local quedó vacía).
      if (_state == SyncState.success) {
        try {
          final countNow = await LocalDbService.instance.getConteoTotal();
          if (countNow > 0) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('last_sync_timestamp', DateTime.now().toIso8601String());
          }
        } catch (_) {}
      }
      notifyListeners();
      debugPrint('[Sync] finally → isSyncing=false, estado=${_state.name}');
    }
  }


  // ── Push: Subir OS con estado PENDIENTE_ACTUALIZAR ────────────────────────


  // ── Push: Subir OS con estado is_dirty=1 (solo las sucias) ─────────────────
  //   Concurrencia: Future.wait envía hasta 3 órdenes en paralelo.

  Future<int> _pushPendientes() async {
    final db      = LocalDbService.instance;
    // Consulta estricta: SOLO registros con cambios locales no sincronizados
    // (is_dirty = 1 OR sync_status = 'PENDIENTE')
    final pending = await db.getOsPendientes();

    if (pending.isEmpty) {
      debugPrint('[Sync PUSH] Sin órdenes sucias — skip PUSH directo a PULL');
      return 0;
    }

    debugPrint('[Sync PUSH] ${pending.length} pendientes → subida concurrente (lotes de 3)');

    // Lotes de 3 en paralelo con timeout 10s por orden — según spec v3.1.20
    const batchSize = 3;
    int uploaded = 0;

    for (int i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
          i, (i + batchSize) > pending.length ? pending.length : (i + batchSize));

      final results = await Future.wait(
        batch.map((os) =>
            _subirUnaOrden(os)
                .timeout(const Duration(seconds: 10), onTimeout: () => false)
                .catchError((_) => false)),
      );
      uploaded += results.where((ok) => ok == true).length;
    }
    return uploaded;
  }

  /// Reintenta los resets de toma que fallaron en un ciclo anterior (sin red).
  /// Busca OSs con sync_status = 'PENDIENTE_RESET' y llama al endpoint correspondiente.
  Future<int> _pushResetsPendientes() async {
    try {
      final db   = LocalDbService.instance;
      final rows = await db.getOrdenesConSyncStatus('PENDIENTE_RESET');
      if (rows.isEmpty) return 0;
      int ok = 0;
      for (final os in rows) {
        final folio = ((os['folio_os'] ?? os['folio']) as String? ?? '').trim();
        if (folio.isEmpty) continue;
        try {
          final success = await ApiService.instance
              .resetTomaEnServidor(folio)
              .timeout(const Duration(seconds: 8));
          if (success) {
            await db.updateSyncStatus(folio, 'SINCRONIZADO');
            updateLocalOrder(folio, {'sync_status': 'SINCRONIZADO'});
            ok++;
          }
        } catch (e) {
          debugPrint('[SYNC PUSH RESET] Reintentar $folio falló: $e');
        }
      }
      if (ok > 0) notifyListeners();
      return ok;
    } catch (e) {
      debugPrint('[SYNC PUSH RESET] Error en _pushResetsPendientes: $e');
      return 0;
    }
  }

  /// Sube UNA orden al servidor. Retorna true si fue confirmada por Render.
  Future<bool> _subirUnaOrden(Map<String, dynamic> os) async {
    final db    = LocalDbService.instance;
    final folio = ((os['folio_os'] ?? os['folio']) as String? ?? '').trim();
    if (folio.isEmpty) return false;

    try {
      bool pdfUploadedOk  = false;
      bool dataUploadedOk = false;

      // Resolver PDF físico en disco con máxima tolerancia de rutas
      final pdfFile = await _resolveLocalPdfFile(os);
      String? pdfB64;
      if (pdfFile != null && await pdfFile.exists()) {
        try {
          final bytes = await pdfFile.readAsBytes();
          if (bytes.length > 500) {
            pdfB64 = base64Encode(bytes);
          }
        } catch (e) {
          debugPrint('[PUSH] Error codificando PDF a base64 para $folio: $e');
        }
      }
      if (pdfB64 == null && os['pdf_b64_local'] != null) {
        pdfB64 = (os['pdf_b64_local'] as String?).toString().trim();
      }
      if (pdfB64 == null && os['pdf_path_local'] != null) {
        pdfB64 = await _readPdfBase64(os['pdf_path_local'] as String?);
      }

      final estLocal     = (os['estado']  as String? ?? '').toUpperCase().trim();
      final estatusLocal = (os['estatus'] as String? ?? '').toUpperCase().trim();
      final cerradaLocal = {'CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA'}.contains(estLocal)
                        || {'CERRADO','CERRADA','COMPLETADA'}.contains(estatusLocal);

      final payload = {
        'folio_os':          folio,
        'device_id':         await db.getDeviceId(),
        'sync_version_base': os['sync_version'] ?? 0,
        // Estado canónico que el servidor acepta como cierre (evita que 'Cerrado'
        // local sea rechazado por la tabla de transiciones y quede en 'Proceso').
        'nuevo_estado':      cerradaLocal ? 'COMPLETADA_DIGITAL' : (os['estado'] ?? 'COMPLETADA_DIGITAL'),
        // Estatus y modalidad explícitos para que PostgreSQL / macOS reflejen el cierre.
        'estatus':           cerradaLocal ? 'Cerrado' : (os['estatus'] ?? 'Proceso'),
        if ((os['modalidad'] as String?)?.isNotEmpty == true) 'modalidad': os['modalidad'],
        'observaciones':     os['observaciones'],
        'repetibilidad':     _decodeJson(os['rep_json']),
        'excentricidad':     _decodeJson(os['exc_json']),
        'exactitud':         _decodeJson(os['exac_json']),
        if (pdfB64 != null && pdfB64.isNotEmpty) 'pdf_b64': pdfB64,
        if ((os['firma_tecnico']        as String?)?.isNotEmpty == true) 'firma_tecnico': os['firma_tecnico'],
        if ((os['firma_cliente']        as String?)?.isNotEmpty == true) 'firma_cliente': os['firma_cliente'],
        if ((os['firma_cliente_nombre'] as String?)?.isNotEmpty == true) 'firma_cliente_nombre': os['firma_cliente_nombre'],
        if ((os['nombre_ing']           as String?)?.isNotEmpty == true) 'nombre_ing': os['nombre_ing'],
        if ((os['puesto_ing']           as String?)?.isNotEmpty == true) 'puesto_ing': os['puesto_ing'],
        if ((os['dictamen']             as String?)?.isNotEmpty == true) 'dictamen': os['dictamen'],
        'unidad_medida': os['unidad_medida'] ?? 'kg',
      };

      Map<String, dynamic>? result;
      try {
        result = await ApiService.instance.syncPush(payload).timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('syncPush timeout $folio'),
        );
        dataUploadedOk = true;
      } catch (e) {
        debugPrint('[PUSH] JSON falló para $folio: $e');
      }

      try {
        if (pdfFile != null && await pdfFile.exists()) {
          pdfUploadedOk = await ApiService.instance.uploadPdf(
            folio, pdfFile,
            osId: os['local_id'] as int?,
            data: payload,
          ).timeout(const Duration(seconds: 20), onTimeout: () => false);
        } else {
          final est = (os['estado'] as String? ?? '').toUpperCase();
          if (!{'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO'}.contains(est)) {
            pdfUploadedOk = true;
          }
        }
      } catch (e) {
        debugPrint('[PUSH] PDF upload falló para $folio: $e');
      }

      final estUpper    = (os['estado']  as String? ?? '').toUpperCase().trim();
      final estatusUp   = (os['estatus'] as String? ?? '').toUpperCase().trim();
      final isCerrada   = {'CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA'}.contains(estUpper)
                       || {'CERRADO','CERRADA','COMPLETADA'}.contains(estatusUp);
      final canMark     = isCerrada ? (dataUploadedOk && pdfUploadedOk) : (dataUploadedOk || pdfUploadedOk);

      if (canMark) {
        final osId  = os['local_id'] as int? ?? 0;
        final newVer = (result?['sync_version'] as int?) ?? ((os['sync_version'] as int? ?? 0) + 1);
        await db.markOsSincronizada(osId, newVer, folio: folio);
        if (pdfUploadedOk) await db.markPdfSubido(osId, folio: folio);
        await db.clearDirty(folio);
        updateLocalOrder(folio, {
          'is_dirty': 0, 'sync_check_status': 'SUBIDA_SERVIDOR',
          'is_synced': 1, 'sync_status': 'ENVIADO',
          if (pdfUploadedOk) 'pdf_subido': 1,
        });
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[PUSH] Error al subir $folio: $e');
      return false;
    }
  }

  /// Reset completo de la orden desde cero (SQLite local + Render PostgreSQL)
  Future<bool> resetearOrdenDesdeCero(String folio, Map<String, dynamic> os) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return false;
    try {
      final db = LocalDbService.instance;
      // 1. Reset atómico Offline-First en SQLite local
      final ok = await db.resetearOrdenLocal(folioKey, localId: os['local_id'] as int?);

      // 2. Notificar actualización reactiva en memoria / Provider
      updateLocalOrder(folioKey, {
        'metrologia_data': null,
        'rep_json': null,
        'exc_json': null,
        'exac_json': null,
        'observaciones': null,
        'dictamen': null,
        'firma_tecnico': null,
        'firma_tecnico_b64': null,
        'firma_cliente': null,
        'firma_cliente_b64': null,
        'firma_cliente_nombre': null,
        'puesto_ing': null,
        'nombre_ing': null,
        'pdf_path': null,
        'pdf_path_local': null,
        'pdf_b64_local': null,
        'pdf_url': null,
        'has_pdf': 0,
        'pdf_subido': 0,
        'estado': 'PROCESO',
        'estatus': 'Proceso',
        'sync_status': 'PENDIENTE_RESET',
        'sync_check_status': 'ASIGNADA',
        'is_dirty': 1,
      });

      // 3. Reset en Backend si hay red en segundo plano (no bloqueante).
      //    Si falla (sin red), queda marcado PENDIENTE_RESET y el próximo
      //    ciclo de PUSH lo reintentará automáticamente.
      unawaited(
        Future(() async {
          try {
            final serverOk = await ApiService.instance
                .resetTomaEnServidor(folioKey)
                .timeout(const Duration(seconds: 10));
            if (serverOk) {
              debugPrint('[SYNC BG] Reset en servidor exitoso para $folioKey');
              // Actualizar sync_status a SINCRONIZADO una vez que el servidor confirmó
              await LocalDbService.instance.updateSyncStatus(folioKey, 'SINCRONIZADO');
              updateLocalOrder(folioKey, {'sync_status': 'SINCRONIZADO'});
              notifyListeners();
            } else {
              debugPrint('[SYNC BG] Servidor rechazó el reset de $folioKey — reintentará en PUSH');
            }
          } catch (e) {
            debugPrint('[SYNC BG] Reset en servidor falló o sin red para $folioKey: $e');
            // Asegurar que quede marcado para reintento en el próximo PUSH
            try {
              await LocalDbService.instance.updateSyncStatus(folioKey, 'PENDIENTE_RESET');
              updateLocalOrder(folioKey, {'sync_status': 'PENDIENTE_RESET'});
            } catch (_) {}
          }
        }),
      );

      notifyListeners();
      return ok;
    } catch (e) {
      debugPrint('[SYNC] Error al resetear orden $folioKey desde cero: $e');
      return false;
    }
  }



  /// Encuentra o reconstruye el archivo binario PDF en el disco de la tablet.
  Future<File?> _resolveLocalPdfFile(Map<String, dynamic> os) async {
    final folio = (os['folio_os'] as String? ?? '').trim();
    if (folio.isEmpty) return null;

    // 1. Ruta registrada en la BD
    final pathLocal = os['pdf_path_local'] as String?;
    if (pathLocal != null && pathLocal.isNotEmpty) {
      final f = File(pathLocal);
      if (await f.exists() && await f.length() > 500) {
        return f;
      }
    }

    // 2. Carpeta Documents / Pesa_PDFs (Almacenamiento persistente)
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${appDocDir.path}/Pesa_PDFs');
      if (await pdfDir.exists()) {
        final files = pdfDir.listSync().whereType<File>();
        final match = files.firstWhere(
          (f) => f.path.split(Platform.pathSeparator).last.startsWith(folio),
          orElse: () => File(''),
        );
        if (match.path.isNotEmpty && await match.exists() && await match.length() > 500) {
          return match;
        }
      }
    } catch (_) {}

    // 3. Carpeta Documents / pdfs / Pesa_PDFs / PESA_Tablet
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      for (final p in [
        '${appDocDir.path}/pdfs/OS-$folio.pdf',
        '${appDocDir.path}/pdfs/$folio.pdf',
        '${appDocDir.path}/Pesa_PDFs/$folio.pdf',
        '${appDocDir.path}/Pesa_PDFs/OS-$folio.pdf',
        '${appDocDir.path}/PESA_Tablet/PDF_OS/$folio.pdf',
      ]) {
        final f = File(p);
        if (await f.exists() && await f.length() > 500) {
          return f;
        }
      }
    } catch (_) {}

    // 3. Carpeta Temporal / PESA_Tablet / PDF_OS
    try {
      final tmpDir = await getTemporaryDirectory();
      final cand2 = File('${tmpDir.path}/PESA_Tablet/PDF_OS/$folio.pdf');
      if (await cand2.exists() && await cand2.length() > 500) {
        return cand2;
      }
      final cand3 = File('${tmpDir.path}/$folio.pdf');
      if (await cand3.exists() && await cand3.length() > 500) {
        return cand3;
      }
    } catch (_) {}

    // 4. Reconstrucción desde pdf_b64_local almacenado en SQLite
    final b64 = os['pdf_b64_local'] as String?;
    if (b64 != null && b64.trim().isNotEmpty) {
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        final dir = Directory('${appDocDir.path}/PESA_Tablet/PDF_OS');
        await dir.create(recursive: true);
        final restored = File('${dir.path}/$folio.pdf');
        await restored.writeAsBytes(base64Decode(b64.trim()));
        debugPrint('[Sync] PDF reconstruido desde Base64 local para $folio (${await restored.length()} bytes)');
        return restored;
      } catch (e) {
        debugPrint('[Sync] Error al reconstruir PDF desde Base64 para $folio: $e');
      }
    }

    return null;
  }

  /// Sube los PDFs binarios pendientes de órdenes completadas/cerradas a Render.
  /// Obligatorio: envía HTTP Multipart POST a /api/v1/ordenes/{folio}/upload-pdf.
  /// Solo al recibir HTTP 200 OK marca el PDF como subido en SQLite.
  Future<int> _subirPdfsPendientes() async {
    final db = LocalDbService.instance;
    final pendentesPdf = await db.getOsParaSubirPdf();
    int subidos = 0;

    for (final os in pendentesPdf) {
      final folio = (os['folio_os'] as String? ?? '').trim();
      if (folio.isEmpty) continue;

      try {
        final pdfFile = await _resolveLocalPdfFile(os);
        if (pdfFile == null || !await pdfFile.exists()) {
          debugPrint('[Sync] ⚠️ No se encontró PDF local en tablet para folio $folio');
          continue;
        }

        final osId = os['local_id'] as int?;
        debugPrint('[Sync] Subiendo binario PDF multipart para $folio (${await pdfFile.length()} bytes)...');
        final uploadOk = await ApiService.instance.uploadPdf(
          folio,
          pdfFile,
          osId: osId,
          data: {
            'folio_os': folio,
            'observaciones': os['observaciones'],
            'rep_rows': _decodeJson(os['rep_json']),
            'exc_rows': _decodeJson(os['exc_json']),
            'exac_rows': _decodeJson(os['exac_json']),
            'firma_tecnico': os['firma_tecnico'],
            'firma_cliente': os['firma_cliente'],
            'firma_cliente_nombre': os['firma_cliente_nombre'],
            'nombre_ing': os['nombre_ing'],
            'puesto_ing': os['puesto_ing'],
            'dictamen': os['dictamen'],
            'unidad_medida': os['unidad_medida'] ?? 'kg',
          },
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            debugPrint('[Sync] ⏱ TIMEOUT 15s al subir PDF para $folio');
            return false;
          },
        );

        if (uploadOk) {
          debugPrint('[Sync] ✅ PDF binario subido exitosamente a Render para $folio');
          await db.markPdfSubido(osId ?? 0, folio: folio);
          await db.updateOsSyncCheckStatus(folio, 'SUBIDA_SERVIDOR', isSynced: 1, pdfSubido: 1);
          updateLocalOrder(folio, {
            'sync_check_status': 'SUBIDA_SERVIDOR',
            'is_synced': 1,
            'sync_status': 'SINCRONIZADO',
            'pdf_subido': 1,
          });
          subidos++;
        } else {
          debugPrint('[Sync] ❌ Subida multipart de PDF falló para $folio');
        }
      } catch (e) {
        debugPrint('[Sync] Error subiendo PDF para $folio (continuando): $e');
      }
    }

    return subidos;
  }

  /// Lee el archivo PDF local y lo convierte a Base64 para el push.
  Future<String?> _readPdfBase64(String? pdfPath) async {
    if (pdfPath == null || pdfPath.isEmpty) return null;
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('[Sync] No se pudo leer PDF local ($pdfPath): $e');
      return null;
    }
  }

  // ── Pull: Descargar nuevas OS asignadas al técnico ────────────────────────

  // ── Pull Incremental: solo OS modificadas después del último sync ────────────
  //   Si lastSync existe → ?since=timestamp → backend retorna 2-3 OS en vez de 235.
  //   Si es primera vez → since=null → pull completo.

  Future<int> _pullNuevos({String? updatedAfter}) async {
    final db = LocalDbService.instance;
    final prefs = await SharedPreferences.getInstance();

    final usuario       = AuthService.usuarioActual;
    final userRole      = (usuario?.rol ?? ApiService.instance.userRole ?? '').toLowerCase();
    final isTecnicoUser = (usuario != null && (usuario.rol.toUpperCase() == "TECNICO" || usuario.isTecnico)) ||
        (userRole.contains('tec') || userRole.contains('serv') || userRole.contains('oper'));
    final idTecnico     = usuario?.id ?? ApiService.instance.lastIdTecnico;
    final currentNombre = usuario?.nombre ?? ApiService.instance.lastNombre;
    final isAdmin       = !isTecnicoUser && (userRole.contains('admin') || userRole.contains('logist') || userRole.contains('recep') || (usuario?.username.toLowerCase() == 'ivancolin1207'));

    // Si no se proporcionó updatedAfter, verificar conteo local en SQLite
    String? effectiveUpdatedAfter = updatedAfter;
    if (effectiveUpdatedAfter == null) {
      final conteoLocal = await db.getConteoTotal();
      if (conteoLocal > 0) {
        effectiveUpdatedAfter = prefs.getString('last_sync_timestamp');
      } else {
        debugPrint("[SYNC] Base local vacía (0 registros). Forzando PULL completo sin updated_after.");
        await prefs.remove('last_sync_timestamp');
        await db.resetLastSyncTime();
        effectiveUpdatedAfter = null;
      }
    }

    final isFirstSync = effectiveUpdatedAfter == null;

    debugPrint('[Sync PULL] ${isFirstSync ? "CARGA INICIAL COMPLETA" : "INCREMENTAL desde $effectiveUpdatedAfter"}');
    debugPrint('[Sync PULL] isAdmin=$isAdmin | isTecnicoUser=$isTecnicoUser | id_tecnico=$idTecnico | nombre=$currentNombre');

    try {
      // Para Administrador (Iván Colín): NO enviar ningún parámetro tecnico en el query string. Traer todo el lote.
      // Si updatedAfter == null: Traer sin parámetros de fecha.
      final osList = await ApiService.instance.syncPull(
        updatedAfter: effectiveUpdatedAfter,
        since: effectiveUpdatedAfter != null ? DateTime.tryParse(effectiveUpdatedAfter) : null,
        tecnicoId: (isAdmin || !isTecnicoUser) ? null : idTecnico,
        tecnicoNombre: (isAdmin || !isTecnicoUser) ? null : currentNombre,
      ).timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          debugPrint('[Sync PULL] ⏱ TIMEOUT 25s — abortando pull');
          throw TimeoutException('PULL timeout 25s');
        },
      );
      debugPrint('[Sync PULL] RECIBIDAS: ${osList.length} OS del servidor');

      // ── Privacidad estricta: purgar órdenes de otros técnicos si no es admin ──
      if (isTecnicoUser && !isAdmin) {
        await db.purgarOrdenesDeOtrosTecnicos(
          currentIdTecnico: idTecnico,
          currentNombre: currentNombre,
          isAdmin: false,
        );
      }

      // Si el servidor retorna 0 en pull:
      if (osList.isEmpty) {
        debugPrint('[Sync PULL] Sin cambios nuevos desde $effectiveUpdatedAfter');
        final conteoLocal = await db.getConteoTotal();
        if (conteoLocal == 0) {
          debugPrint('[Sync PULL] Base local vacía (0 registros) pero server retornó 0. Removiendo timestamp.');
          await prefs.remove('last_sync_timestamp');
          await db.resetLastSyncTime();
        }
        await cargarOrdenes();
        return 0;
      }

      // Filtrar por técnico en memoria (solo si es técnico y no admin)
      final filteredList = (isTecnicoUser && !isAdmin)
          ? osList.where((o) {
              final oId = int.tryParse(o['id_tecnico']?.toString() ?? '');
              if (oId != null && oId > 0 && idTecnico != null && idTecnico > 0) {
                if (oId != idTecnico) return false;
              }
              final tec   = (o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '').toLowerCase().trim();
              final myNom = (currentNombre ?? '').toLowerCase().trim();
              if (tec.isNotEmpty && myNom.isNotEmpty) {
                return tec == myNom || tec.contains(myNom) || myNom.contains(tec);
              }
              return true;
            }).toList()
          : osList;

      // ── Inserción en bloque con transacción atómica en SQLite ──────────────
      final insertedCount = await db.insertOrdenesBatch(filteredList);
      debugPrint('[Sync PULL] ✅ Guardadas $insertedCount órdenes en bloque atómico en SQLite');

      // Solo DESPUÉS de confirmar que se insertaron registros con éxito, actualizar:
      if (insertedCount > 0) {
        await prefs.setString('last_sync_timestamp', DateTime.now().toIso8601String());
        await db.setLastSyncTime(DateTime.now());
      }

      // ── Refrescar dashboard incondicionalmente desde SQLite ──────────────
      await cargarOrdenes();

      return insertedCount;

    } catch (e, st) {
      debugPrint('[Sync PULL] ERROR: $e\n$st');
      rethrow;
    }
  }




  // ── Push firmas pendientes (concurrente con Future.wait) ─────────────────

  Future<void> _pushFirmasPendientes() async {
    final db         = LocalDbService.instance;
    final firmasPend = await db.getFirmasPendientes();

    if (firmasPend.isEmpty) {
      debugPrint('[Sync PUSH Firmas] Sin firmas pendientes — skip');
      return;
    }

    debugPrint('[Sync PUSH Firmas] ${firmasPend.length} firmas → subida concurrente (timeout 10s/firma)');

    // Subida paralela de todas las firmas pendientes con timeout individual
    await Future.wait(
      firmasPend.map((f) async {
        try {
          await ApiService.instance.pushFirmas(
            f['folio_os'] as String,
            f['firma_tecnico'] as String,
            f['firma_cliente'] as String,
            nombreIng: f['nombre_ing'] as String? ?? '',
            puestoIng: f['puesto_ing'] as String? ?? '',
          ).timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              debugPrint('[Sync] ⏱ TIMEOUT 10s al subir firma para ${f['folio_os']}');
            },
          );
          await db.markFirmaSincronizada(f['local_id'] as int);
        } catch (e) {
          debugPrint('[Sync PUSH Firmas] Error en ${f['folio_os']}: $e');
        }
      }),
    );
  }

  // ── Sincronización Catálogo Dinámico Marcas / Modelos ─────────────────────

  Future<void> _pushMarcasModelos() async {
    try {
      final db = LocalDbService.instance;
      final localPairs = await db.getAllMarcasModelos();
      if (localPairs.isNotEmpty) {
        await ApiService.instance.pushMarcasModelos(localPairs);
      }
    } catch (e) {
      debugPrint('[Sync] Error _pushMarcasModelos: $e');
    }
  }

  Future<void> _pullMarcasModelos() async {
    try {
      final db = LocalDbService.instance;
      final remoteList = await ApiService.instance.getMarcasModelos();
      if (remoteList.isNotEmpty) {
        final count = await db.insertMarcasModelosBatch(remoteList);
        debugPrint('[Sync] PULL Marcas/Modelos: $count registros actualizados en SQLite local');
      }
    } catch (e) {
      debugPrint('[Sync] Error _pullMarcasModelos: $e');
    }
  }


  // ── Utilidades ────────────────────────────────────────────────────────────

  Future<void> _refreshPending() async {
    _pending = await LocalDbService.instance.getPendingCount();
    notifyListeners();
  }

  void _setState(SyncState s, String msg) {
    _state   = s;
    _message = msg;
    notifyListeners();
  }

  dynamic _decodeJson(dynamic raw) {
    if (raw == null || raw == '') return [];
    if (raw is List) return raw;
    try {
      return jsonDecode(raw as String);
    } catch (_) {
      return [];
    }
  }
}