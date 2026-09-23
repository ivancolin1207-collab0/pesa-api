// lib/services/sync_service.dart — Motor Offline-First con detección automática de red
// Detecta cambios de conectividad y ejecuta Push/Pull silenciosamente en segundo plano.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
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

    // [FIX-TOKEN] Si no hay JWT, intentar renovar antes de abortar.
    // Esto permite sincronizar después de un login offline.
    if (!ApiService.instance.isAuthenticated) {
      debugPrint('[SYNC] Sin token — intentando silentRefresh...');
      _setState(SyncState.syncing, 'Obteniendo sesion...');
      final refreshed = await ApiService.instance.silentRefresh();
      if (!refreshed) {
        debugPrint('[SYNC ERROR] silentRefresh fallo. Sin autenticacion valida.');
        // [FIX-SESSION] Emitir evento para redirigir al login —
        // el usuario debe autenticarse de nuevo con sus credenciales actuales.
        // Esto ocurre cuando el JWT antiguo fue firmado con clave incorrecta
        // y las credenciales guardadas tambien fallan.
        _setState(SyncState.error,
            'Sesion expirada. Inicia sesion nuevamente.');
        sessionExpiredEvents.add(null);
        return;
      }
      debugPrint('[SYNC] silentRefresh OK — continuando sync...');
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
      // [FIX] Siempre emitir success para que _onSyncChanged dispare _loadLocal().
      // Si pull=0, el dashboard mostrara los registros locales existentes.
      // Si no hay nada local tampoco, mostrara la pantalla de "sin ordenes".
      _setState(
        SyncState.success,
        pullCount > 0
            ? 'Sincronizado: $pushCount subida(s), $pullCount descargada(s)'
            : pullCount == 0 && pushCount == 0
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
        // [FIX-NO-LOGOUT] NO hacer logout inmediato por un 401 en background.
        // El 401 en sync puede ser transitorio (cold-start de Render, clock skew).
        // Intentar silentRefresh y reportar error SIN destruir la sesion.
        debugPrint('[Sync] 401 en sync — intentando silentRefresh...');
        final refreshed = await ApiService.instance.silentRefresh();
        if (refreshed) {
          debugPrint('[Sync] silentRefresh OK tras 401 — reintentando pull...');
          _setState(SyncState.syncing, 'Reintentando sincronizacion...');
          try {
            final pullRetry = await _pullNuevos();
            _lastSync = DateTime.now();
            await _refreshPending();
            if (pullRetry > 0) {
              _setState(SyncState.success, 'Sincronizado (reintento): $pullRetry OS');
            }
          } catch (retryErr) {
            debugPrint('[Sync] Error en reintento: $retryErr');
            _setState(SyncState.error, 'Error de red. Reintenta manualmente.');
          }
        } else {
          // silentRefresh fallido — NO cerrar sesion, solo informar
          debugPrint('[Sync] silentRefresh fallido — error sin logout');
          _setState(SyncState.error,
              'Error de autenticacion temporal. Reconecta al WiFi e intenta de nuevo.');
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
        // [FIX] Servidor devolvio 0 ordenes: loguear pero NO poner estado error.
        // El dashboard mostrara los registros locales y el usuario puede sincronizar de nuevo.
        // Antes esto bloqueaba _onSyncChanged (que solo escucha SyncState.success).
        debugPrint('[Sync PULL] AVISO: servidor retorno 0 ordenes para id_tecnico=$idTecnico.'
            ' La BD local puede tener datos previos.');
        return 0;  // performSync pondra SyncState.success y _loadLocal() se ejecutara
      }

      // Upsert individual con error por fila para no perder el resto si una falla
      int guardadas = 0;
      for (final osData in osList) {
        try {
          debugPrint('[Sync PULL]   OS: ${osData["folio_os"]} | '
              'estado: ${osData["estado"]} | tecnico: ${osData["tecnico"]}');
          await db.upsertOs(osData);
          guardadas++;
        } catch (e) {
          debugPrint('[Sync PULL]   AVISO upsertOs fallo para ${osData["folio_os"]}: $e');
        }
      }

      await db.setLastSyncTime(DateTime.now().toUtc());
      debugPrint('[Sync PULL] OK $guardadas/${osList.length} OS guardadas en SQLite');
      return guardadas;
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