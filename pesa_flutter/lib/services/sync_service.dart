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

  /// Resguardo de base local: si la red falla o retorna error,
  /// muestra de inmediato los datos locales de SQLite para que nunca quede en ceros.
  Future<void> _fallbackCargarLocal() async {
    try {
      final db = LocalDbService.instance;
      final usuario = AuthService.usuarioActual;
      final userRole = (usuario?.rol ?? ApiService.instance.userRole ?? '').toLowerCase();
      final isTecnicoUser = (usuario != null && (usuario.rol.toUpperCase() == "TECNICO" || usuario.isTecnico)) ||
          (userRole.contains('tec') || userRole.contains('serv') || userRole.contains('oper'));
      final idTecnico = usuario?.id ?? ApiService.instance.lastIdTecnico;
      final currentNombre = usuario?.nombre ?? ApiService.instance.lastNombre;

      var localDbOrders = isTecnicoUser
          ? await db.getOsForTecnico(
              nombreTecnico: currentNombre,
              idTecnico: idTecnico,
            )
          : await db.getAllOs();

      if (localDbOrders.isEmpty && isTecnicoUser) {
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

      if (localDbOrders.isNotEmpty) {
        setOrdersFromPull(localDbOrders);
      }
    } catch (e) {
      debugPrint('[Sync Fallback Local] Error: $e');
    }
  }

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

      try {
        final pushed = await _pushPendientes()
            .timeout(const Duration(seconds: 15), onTimeout: () => 0);
        debugPrint('[Sync PUSH] $pushed OS subidas');
      } catch (e) {
        debugPrint('[Sync PUSH pendientes] Error ignorado: $e');
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

      // ── Fase 2: PULL diferencial — timeout estricto 20s, manejo de 401 ───
      // Usa el timestamp de SharedPreferences (lectura en RAM, sin abrir SQLite)
      _message = 'Descargando órdenes...';
      notifyListeners();

      try {
        final pullCount = await _pullNuevos().timeout(
          const Duration(seconds: 18),
          onTimeout: () {
            // Timeout silencioso: Render puede tardar hasta 15s en cold start.
            // Sirve los datos locales inmediatamente para no dejar el dashboard en ceros.
            debugPrint('[Sync PULL] ⏱ TIMEOUT 18s — sirviendo datos locales inmediatamente');
            _fallbackCargarLocal(); // ← CLAVE: restaurar desde SQLite
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
      // Persistir timestamp en SharedPreferences (lectura ultrarápida en RAM)
      // para que el próximo ciclo evite abrir SQLite solo para leer last_sync.
      if (_state == SyncState.success) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_sync_timestamp', DateTime.now().toIso8601String());
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

      final payload = {
        'folio_os':          folio,
        'device_id':         await db.getDeviceId(),
        'sync_version_base': os['sync_version'] ?? 0,
        'nuevo_estado':      os['estado'] ?? 'COMPLETADA_DIGITAL',
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
      // 1. Reset en SQLite local
      await db.resetTomaDesdeCero(folioKey, localId: os['local_id'] as int?);

      // 2. Notificar actualización reactiva en memoria / Provider
      updateLocalOrder(folioKey, {
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
        'pdf_path_local': null,
        'pdf_b64_local': null,
        'pdf_url': null,
        'pdf_subido': 0,
        'estado': 'PROCESO',
        'estatus': 'Proceso',
        'sync_status': 'PENDIENTE',
        'sync_check_status': 'BORRADOR_LOCAL',
        'is_dirty': 1,
      });

      // 3. Reset en Backend si hay red
      try {
        await ApiService.instance.resetTomaEnServidor(folioKey).timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[SYNC] Reset en servidor falló o sin red (se enviará en PUSH): $e');
      }

      notifyListeners();
      return true;
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

    // 3. Carpeta Documents / PESA_Tablet / PDF_OS (Legacy)
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final cand1 = File('${appDocDir.path}/PESA_Tablet/PDF_OS/$folio.pdf');
      if (await cand1.exists() && await cand1.length() > 500) {
        return cand1;
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

  Future<int> _pullNuevos() async {
    final db = LocalDbService.instance;

    // ── SINCRONIZACIÓN DIFERENCIAL ULTRA RÁPIDA ──────────────────────────────
    // 1. Leer primero de SharedPreferences (en RAM, sin abrir SQLite)
    // 2. Fallback a SQLite si no hay valor en cache
    DateTime? lastSyncTs;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedTs = prefs.getString('last_sync_timestamp');
      if (cachedTs != null && cachedTs.isNotEmpty) {
        lastSyncTs = DateTime.tryParse(cachedTs);
        debugPrint('[Sync PULL] timestamp desde SharedPreferences (RAM): $lastSyncTs');
      }
    } catch (_) {}

    // Fallback: leer de SQLite si SharedPreferences no tiene valor
    lastSyncTs ??= await db.getLastSyncTime();

    final usuario       = AuthService.usuarioActual;
    final userRole      = (usuario?.rol ?? ApiService.instance.userRole ?? '').toLowerCase();
    final isTecnicoUser = (usuario != null && (usuario.rol.toUpperCase() == "TECNICO" || usuario.isTecnico)) ||
        (userRole.contains('tec') || userRole.contains('serv') || userRole.contains('oper'));
    final idTecnico     = usuario?.id ?? ApiService.instance.lastIdTecnico;
    final currentNombre = usuario?.nombre ?? ApiService.instance.lastNombre;
    final isAdmin       = !isTecnicoUser && (userRole.contains('admin') || userRole.contains('logist') || userRole.contains('recep'));

    final isFirstSync = lastSyncTs == null;

    debugPrint('[Sync PULL] ${isFirstSync ? "CARGA INICIAL COMPLETA" : "INCREMENTAL desde $lastSyncTs"}');
    debugPrint('[Sync PULL] URL: ${ApiService.instance.baseUrl}/api/v1/sync/pull');
    debugPrint('[Sync PULL] id_tecnico=$idTecnico | role=$userRole | isTecnicoUser=$isTecnicoUser | nombre=$currentNombre');

    try {
      // En pull incremental enviamos el timestamp y forzosamente filtro de técnico si rol == TECNICO
      final osList = await ApiService.instance.syncPull(
        since: lastSyncTs,
        tecnicoId: isTecnicoUser ? idTecnico : null,
        tecnicoNombre: isTecnicoUser ? currentNombre : null,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          debugPrint('[Sync PULL] ⏱ TIMEOUT 20s — abortando pull');
          throw TimeoutException('PULL timeout 20s');
        },
      );
      debugPrint('[Sync PULL] RECIBIDAS: ${osList.length} OS del servidor');

      // ── Privacidad estricta: purgar órdenes de otros técnicos si no es admin ──
      if (isTecnicoUser) {
        await db.purgarOrdenesDeOtrosTecnicos(
          currentIdTecnico: idTecnico,
          currentNombre: currentNombre,
          isAdmin: false,
        );
      }

      // Si el servidor retorna 0 en pull incremental:
      // - Si ya tenemos órdenes en memoria (→ sin cambios nuevos, OK)
      // - Si _orders está vacío (primera carga real o sección después de reinstalación)
      //   → FORZAR carga completa desde SQLite local independientemente del timestamp
      if (osList.isEmpty) {
        debugPrint('[Sync PULL] Sin cambios nuevos desde $lastSyncTs');
        if (_orders.isEmpty) {
          debugPrint('[Sync PULL] _orders está vacío — forzando recarga COMPLETA desde SQLite');
          // Resetear timestamp para que el próximo pull sea completo (force full pull)
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('last_sync_timestamp');
          await db.resetLastSyncTime();
          // Cargar de SQLite
          final localDbOrders = isTecnicoUser
              ? await db.getOsForTecnico(
                  nombreTecnico: currentNombre,
                  idTecnico: idTecnico,
                )
              : await db.getAllOs();
          setOrdersFromPull(localDbOrders);
          debugPrint('[Sync PULL] Cargadas ${localDbOrders.length} OS desde SQLite local (recuperación)');
        } else {
          debugPrint('[Sync PULL] Manteniendo ${_orders.length} OS en memoria — sin cambios del servidor');
        }
        return 0;
      }

      // Filtrar por técnico en memoria (solo si es técnico)
      final filteredList = (isTecnicoUser)
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

      // ── Guardar en SQLite con lógica de inmunidad local ──────────────────
      int guardadas = 0;
      String? lastErr;

      for (final remoteOrder in filteredList) {
        final folio = (remoteOrder['folio_os'] ?? remoteOrder['folio'])?.toString().trim();
        if (folio == null || folio.isEmpty) continue;

        final localOrder    = await db.getOsByFolio(folio);
        final pdfDiskExists = await db.checkPdfExistsOnDisk(folio, localOrder?['pdf_path_local']?.toString());

        bool isLocalClosed   = false;
        bool hasLocalChanges = false;

        if (localOrder != null) {
          final localEstado  = (localOrder['estado']  as String? ?? '').toUpperCase().trim();
          final localEstatus = (localOrder['estatus'] as String? ?? '').toUpperCase().trim();
          final syncCheckSt  = (localOrder['sync_check_status'] as String? ?? '').toUpperCase().trim();
          final pdfPath      = localOrder['pdf_path_local']?.toString().trim();
          final pdfB64       = localOrder['pdf_b64_local']?.toString().trim();
          final isDirty      = (localOrder['is_dirty'] as int? ?? 0);
          final hasPdf       = (pdfPath != null && pdfPath.isNotEmpty) || (pdfB64 != null && pdfB64.isNotEmpty) || pdfDiskExists;

          isLocalClosed = localEstatus == 'CERRADO' || localEstatus == 'CERRADA' ||
              {'CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA'}.contains(localEstado) || hasPdf;
          hasLocalChanges = isDirty == 1 ||
              (syncCheckSt != 'SUBIDA_SERVIDOR' && syncCheckSt != 'AUDITADA_ADMIN' && syncCheckSt != 'ABIERTO');
        } else if (pdfDiskExists) {
          isLocalClosed = true;
        }

        if (isLocalClosed || hasLocalChanges) {
          debugPrint('[Sync PULL] 🛡 INMUNIDAD: preservando $folio (closed=$isLocalClosed, dirty=$hasLocalChanges)');
          final mergedLocal = localOrder != null
              ? Map<String, dynamic>.from(localOrder)
              : Map<String, dynamic>.from(remoteOrder);
          String? validPath = mergedLocal['pdf_path_local']?.toString();
          if ((validPath == null || validPath.isEmpty) && pdfDiskExists) {
            validPath = await db.resolvePdfPathFromDisk(folio);
          }
          if (validPath != null && validPath.isNotEmpty) mergedLocal['pdf_path_local'] = validPath;
          if (isLocalClosed || pdfDiskExists) {
            mergedLocal['estatus'] = 'Cerrado';
            mergedLocal['estado']  = (mergedLocal['estado'] != null && mergedLocal['estado'].toString().isNotEmpty && mergedLocal['estado'] != 'PROCESO')
                ? mergedLocal['estado']
                : 'COMPLETADA_DIGITAL';
          }
          await db.upsertOs(mergedLocal);
          guardadas++;
        } else {
          final ok = await db.upsertOs(remoteOrder);
          if (ok) guardadas++; else lastErr = db.lastUpsertError;
        }
      }

      // ── Actualizar dashboard: merge incremental (no reemplazar todo) ──────
      if (isFirstSync || _orders.isEmpty) {
        // Carga inicial O _orders vacío (reinstalación, logout/login): leer todo de SQLite
        final allLocal = isTecnicoUser
            ? await db.getOsForTecnico(
                nombreTecnico: currentNombre,
                idTecnico: idTecnico,
              )
            : await db.getAllOs();
        setOrdersFromPull(allLocal);
        debugPrint('[Sync PULL] Dashboard recargado desde SQLite: ${allLocal.length} OS');
      } else {
        // Pull incremental: parchear SOLO las órdenes que llegaron
        for (final o in filteredList) {
          final folio = (o['folio_os'] ?? o['folio'])?.toString().trim();
          if (folio == null || folio.isEmpty) continue;
          final idx = _orders.indexWhere((r) =>
              (r['folio_os']?.toString().trim() == folio) ||
              (r['folio']?.toString().trim() == folio));
          if (idx >= 0) {
            _orders[idx] = {..._orders[idx], ...o};  // parchear fila existente
          } else {
            _orders.add(o);  // nueva orden asignada
          }
        }
        // Si es técnico, depurar _orders para que NUNCA contenga órdenes de otros técnicos
        if (isTecnicoUser) {
          final myNom = (currentNombre ?? '').toLowerCase().trim();
          _orders.removeWhere((o) {
            final oId = int.tryParse(o['id_tecnico']?.toString() ?? '');
            if (oId != null && oId > 0 && idTecnico != null && idTecnico > 0) {
              if (oId != idTecnico) return true;
            }
            final tec = (o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '').toLowerCase().trim();
            if (myNom.isNotEmpty) {
              return !(tec == myNom || tec.contains(myNom) || myNom.contains(tec));
            }
            return false;
          });
        }
        _updateCounters(_orders);
        notifyListeners();
      }

      await db.setLastSyncTime(DateTime.now().toUtc());
      debugPrint('[Sync PULL] Persistencia SQLite: $guardadas/${filteredList.length} guardadas (lastErr: $lastErr)');
      return filteredList.length;

    } catch (e, st) {
      debugPrint('[Sync PULL] ERROR GRAVE: $e');
      debugPrint(st.toString());
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