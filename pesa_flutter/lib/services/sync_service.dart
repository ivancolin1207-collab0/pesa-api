// lib/services/sync_service.dart — Motor Offline-First con detección automática de red
// Detecta cambios de conectividad y ejecuta Push/Pull silenciosamente en segundo plano.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_service.dart';
import 'local_db_service.dart';



/// Evento global que dispara cuando el servidor responde 401 (sesión expirada).
/// El AppShell o el Router escuchan este stream para redirigir al Login.
/// IMPORTANTE: solo se emite desde login/refresh explícito, NO desde sync de fondo.
final sessionExpiredEvents = StreamController<void>.broadcast();

enum SyncState { idle, syncing, success, error, offline }

class SyncService extends ChangeNotifier {
  SyncState _state     = SyncState.idle;
  String    _message   = '';
  int       _pending   = 0;
  DateTime? _lastSync;
  StreamSubscription? _connSub;

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

  /// Asigna directamente la lista de órdenes recibidas en memoria
  /// y actualiza de inmediato las variables reactivas de los contadores.
  void setOrdersFromPull(List<Map<String, dynamic>> osList) {
    _orders = List<Map<String, dynamic>>.from(osList);
    _updateCounters(_orders);
    notifyListeners();
  }

  void _updateCounters(List<Map<String, dynamic>> list) {
    _kpiTotal = list.length;
    int proceso = 0;
    int cerrado = 0;
    int fisico  = 0;

    for (final o in list) {
      final estado = (o['estado'] as String? ?? '').trim().toUpperCase();
      final modalidad = (o['modalidad'] as String? ?? '').trim().toUpperCase();

      final isCerrada = estado == 'CERRADA' ||
          estado == 'CERRADO' ||
          estado == 'COMPLETADA' ||
          estado == 'COMPLETADA_DIGITAL' ||
          estado == 'FIRMADA';

      final isCancelada = estado == 'CANCELADA' || estado == 'CANCELADO';

      if (isCerrada) {
        cerrado++;
      } else if (!isCancelada) {
        // En Proceso: órdenes con estatus distinto a 'Cerrada' o 'Cancelada'
        proceso++;
      }

      // Formatos Físicos: órdenes cuya modalidad contenga 'Físico'
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

  Future<void> performSync() async {
    if (_state == SyncState.syncing) return;

    // ── [FIX-CUELGUE] Estrategia simplificada de autenticación ────────────────
    // ANTES: silentRefresh() con timeout 90s → cuelgue en "Obteniendo sesion..."
    // AHORA:
    //   1. Si ya hay token en memoria → ir directo al pull (no llamar servidor)
    //   2. Si NO hay token en memoria → leer de SecureStorage (sin HTTP, instantáneo)
    //   3. Si tampoco está en storage → login rápido con timeout ESTRICTO de 10s
    //   4. Proceder al pull sea cual sea el resultado; el servidor dirá 401 si es inválido
    // ─────────────────────────────────────────────────────────────────────────────
    if (!ApiService.instance.isAuthenticated) {
      _setState(SyncState.syncing, 'Obteniendo sesion...');

      // Paso 1: intentar cargar token de SecureStorage (sin llamada HTTP)
      bool tokenLoaded = false;
      try {
        const st = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );
        final savedToken = await st.read(key: 'jwt_token')
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (savedToken != null && savedToken.isNotEmpty) {
          // Inyectar el token directamente — sin validar contra servidor
          ApiService.instance.injectToken(savedToken);
          tokenLoaded = true;
          debugPrint('[SYNC] Token recuperado de SecureStorage sin HTTP');
        }
      } catch (e) {
        debugPrint('[SYNC] Error leyendo token de storage: $e');
      }

      // Paso 2: si no hay token guardado → login rápido con timeout 10s
      if (!tokenLoaded) {
        debugPrint('[SYNC] Sin token en storage — intentando login rapido (10s)...');
        bool loginOk = false;
        try {
          const st = FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );
          final savedUser = await st.read(key: 'pesa_username')
              .timeout(const Duration(seconds: 3), onTimeout: () => null);
          final savedPass = await st.read(key: 'pesa_cred_pass')
              .timeout(const Duration(seconds: 3), onTimeout: () => null);
          if (savedUser != null && savedPass != null && savedUser.isNotEmpty) {
            final loginErr = await ApiService.instance
                .login(savedUser, savedPass)
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => 'Timeout de login (10s) — servidor lento',
                );
            if (loginErr == null) {
              loginOk = true;
              debugPrint('[SYNC] Login rapido OK para: $savedUser');
            } else {
              debugPrint('[SYNC] Login rapido fallo: $loginErr');
            }
          }
        } catch (e) {
          debugPrint('[SYNC] Error en login rapido: $e');
        }
        if (!loginOk && !ApiService.instance.isAuthenticated) {
          // Sin credenciales ni token — no se puede sincronizar
          _setState(SyncState.error,
              'Sin sesion activa. Abre la app y reingresa tu usuario y contrasena.');
          return;
        }
      }
    }

    debugPrint('[Sync] Iniciando sync -> ${ApiService.instance.baseUrl}');
    _setState(SyncState.syncing, 'Sincronizando con el servidor...');

    try {
      // 1. Push: subir cambios locales pendientes
      debugPrint('[Sync] PUSH: subiendo cambios locales...');
      final pushCount = await _pushPendientes();
      debugPrint('[Sync] PUSH completado: $pushCount OS subidas');

      // 2. Pull: descargar nuevas asignaciones del servidor
      debugPrint('[Sync] PULL: descargando ordenes del servidor...');
      final pullCount = await _pullNuevos();
      debugPrint('[Sync] PULL completado: $pullCount OS descargadas');

      // 3. Push firmas pendientes
      await _pushFirmasPendientes();

      _lastSync = DateTime.now();
      await _refreshPending();
      _setState(
        SyncState.success,
        pullCount > 0
            ? 'Sincronizado: $pushCount subida(s), $pullCount descargada(s)'
            : pushCount == 0 && pullCount == 0
                ? 'Sincronizado. Sin cambios nuevos.'
                : 'Sincronizado: $pushCount subida(s)',
      );
    } on SocketException catch (e) {
      debugPrint('[Sync] SocketException: $e');
      _setState(SyncState.offline, 'Sin conexion al servidor — verifica WiFi');
    } on TimeoutException catch (e) {
      debugPrint('[Sync] TimeoutException: $e');
      _setState(SyncState.offline, 'Tiempo de espera agotado — servidor lento o sin red');
    } on HttpException catch (e) {
      final msg = e.message;
      debugPrint('[Sync] HttpException: $msg');
      if (msg.contains('401')) {
        // 401 durante el pull → token expirado/inválido → silentRefresh CON timeout 10s
        debugPrint('[Sync] 401 en pull — intentando silentRefresh (10s max)...');
        bool refreshed = false;
        try {
          refreshed = await ApiService.instance.silentRefresh()
              .timeout(const Duration(seconds: 10), onTimeout: () => false);
        } catch (_) {}
        if (refreshed) {
          debugPrint('[Sync] silentRefresh OK — reintentando pull...');
          _setState(SyncState.syncing, 'Reintentando sincronizacion...');
          try {
            final pullRetry = await _pullNuevos();
            _lastSync = DateTime.now();
            await _refreshPending();
            _setState(SyncState.success,
                pullRetry > 0
                    ? 'Sincronizado (reintento): $pullRetry OS'
                    : 'Sincronizado. Sin cambios nuevos.');
          } catch (retryErr) {
            debugPrint('[Sync] Error en reintento: $retryErr');
            _setState(SyncState.error, 'Error de red. Reintenta manualmente.');
          }
        } else {
          _setState(SyncState.error,
              'Sesion expirada. Cierra y vuelve a abrir la app.');
        }
      } else {
        _setState(SyncState.error, 'Error HTTP: $msg');
      }
    } catch (e, st) {
      debugPrint('[Sync] Error inesperado: $e\n$st');
      _setState(SyncState.error, 'Error de sync: $e');
    }
  }

  // ── Push: Subir OS con estado PENDIENTE_ACTUALIZAR ────────────────────────


  Future<int> _pushPendientes() async {
    final db      = LocalDbService.instance;
    final pending = await db.getOsPendientes();
    int uploaded  = 0;

    for (final os in pending) {
      try {
        // Leer PDF local en Base64 si existe
        final String? pdfB64 = await _readPdfBase64(os['pdf_path_local'] as String?);

        final payload = {
          'folio_os':          os['folio_os'],
          'device_id':         await db.getDeviceId(),
          'sync_version_base': os['sync_version'] ?? 0,
          'nuevo_estado':      os['estado'],     // 'COMPLETADA_DIGITAL'
          'observaciones':     os['observaciones'],
          'repetibilidad':     _decodeJson(os['rep_json']),
          'excentricidad':     _decodeJson(os['exc_json']),
          'exactitud':         _decodeJson(os['exac_json']),
          // Offline-First v2: firmas + PDF + unidad
          if (pdfB64 != null)              'pdf_b64':       pdfB64,
          if (os['pdf_b64_local'] != null) 'pdf_b64':       os['pdf_b64_local'],
          if ((os['firma_tecnico'] as String?)?.isNotEmpty == true)
            'firma_tecnico': os['firma_tecnico'],
          if ((os['firma_cliente'] as String?)?.isNotEmpty == true)
            'firma_cliente': os['firma_cliente'],
          if ((os['nombre_ing'] as String?)?.isNotEmpty == true)
            'nombre_ing': os['nombre_ing'],
          if ((os['puesto_ing'] as String?)?.isNotEmpty == true)
            'puesto_ing': os['puesto_ing'],
          'unidad_medida': os['unidad_medida'] ?? 'kg',
        };

        final result = await ApiService.instance.syncPush(payload);
        await db.markOsSincronizada(
          os['local_id'] as int,
          result['sync_version'] as int? ?? 0,
        );
        uploaded++;
      } catch (e) {
        debugPrint('Push error para ${os['folio_os']}: $e');
      }
    }
    return uploaded;
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

  Future<int> _pullNuevos() async {
    final db = LocalDbService.instance;

    // SIEMPRE usar since=2000-01-01 para pull completo.
    // ConflictAlgorithm.replace en upsertOs garantiza idempotencia (no duplicados).
    const since = null; // null → ApiService.syncPull usa DateTime(2000) por defecto

    // [FIX-SYNC-DIAG] Datos de diagnóstico directo desde ApiService singleton.
    // Ya NO se crea una nueva instancia de AuthService (que nunca tiene datos).
    final idTecnico = ApiService.instance.lastIdTecnico;
    final username  = ApiService.instance.userRole ?? 'desconocido';

    debugPrint('[Sync PULL] Full refresh desde 2000-01-01');
    debugPrint('[Sync PULL] URL: ${ApiService.instance.baseUrl}/api/v1/sync/pull');
    debugPrint('[Sync PULL] JWT id_tecnico=$idTecnico | role=$username');
    debugPrint('[Sync PULL] Token: ${ApiService.instance.isAuthenticated ? "OK" : "NO AUTENTICADO"}');

    try {
      final osList = await ApiService.instance.syncPull(since: since);
      debugPrint('[Sync PULL] RECIBIDAS: ${osList.length} ordenes del servidor');

      if (osList.isEmpty) {
        debugPrint('[Sync PULL] AVISO: servidor retorno 0 ordenes para id_tecnico=$idTecnico.');
        return 0;
      }

      // ── [ASIGNACIÓN DIRECTA INMEDIATA AL ESTADO DEL DASHBOARD] ──────────
      // En cuanto se recibe la lista de órdenes en la respuesta HTTP 200:
      // Asigna directamente esa lista de órdenes al estado/proveedor que maneja el Dashboard.
      // Actualiza de inmediato las variables reactivas de los contadores e invoca notifyListeners().
      setOrdersFromPull(osList);
      debugPrint('[Sync PULL] Dashboard en memoria actualizado: ${osList.length} OS '
          '| Total: $_kpiTotal, Proceso: $_kpiProceso, Cerrados: $_kpiCerrado, Físicos: $_kpiFisico');

      // Persistir también en SQLite de forma segura (sin borrar si falla)
      int guardadas = 0;
      String? lastErr;
      for (final osData in osList) {
        final ok = await db.upsertOs(osData);
        if (ok) {
          guardadas++;
        } else {
          lastErr = db.lastUpsertError;
        }
      }

      await db.setLastSyncTime(DateTime.now().toUtc());
      debugPrint('[Sync PULL] Persistencia SQLite: $guardadas/${osList.length} guardadas (lastErr: $lastErr)');
      return osList.length;
    } catch (e, st) {
      debugPrint('[Sync PULL] ERROR GRAVE: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }


  // ── Push firmas pendientes ────────────────────────────────────────────────

  Future<void> _pushFirmasPendientes() async {
    final db           = LocalDbService.instance;
    final firmasPend   = await db.getFirmasPendientes();

    for (final f in firmasPend) {
      try {
        await ApiService.instance.pushFirmas(
          f['folio_os'] as String,
          f['firma_tecnico'] as String,
          f['firma_cliente'] as String,
          nombreIng: f['nombre_ing'] as String? ?? '',
          puestoIng: f['puesto_ing'] as String? ?? '',
        );
        await db.markFirmaSincronizada(f['local_id'] as int);
      } catch (e) {
        debugPrint('Push firma error: $e');
      }
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