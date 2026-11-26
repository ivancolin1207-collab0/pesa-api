// lib/services/api_service.dart — Cliente HTTP para la API REST de PESA
// v2.2: reautenticación silenciosa automática (_renovarSesionSilenciosa), interceptor 401 universal
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'local_db_service.dart';
import 'metrology_helper.dart';

class ApiService {
  static final ApiService instance = ApiService._();
  ApiService._();

  // URL base — se sobreescribe desde ConfigService al iniciar la app
  static const String _defaultBase = 'https://pesa-api-za9i.onrender.com';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _legacyStorage = FlutterSecureStorage();

  String _baseUrl = _defaultBase;
  String? _token;
  bool _isRefreshing = false;
  bool _credentialsRevoked = false;

  // Timeouts — 90s para tolerar cold-start de Render (~50-80s). 120s para sync.
  Duration _connTimeout = const Duration(seconds: 90);
  Duration _syncTimeout = const Duration(seconds: 120);

  void setTimeouts({Duration? connTimeout, Duration? syncTimeout}) {
    if (connTimeout != null) _connTimeout = connTimeout;
    if (syncTimeout != null) _syncTimeout = syncTimeout;
  }

  String? _userRole;
  String? _lastNombre; // Nombre completo del último login exitoso
  int?    _lastIdTecnico; // ID en cat_tecnicos del último login

  bool    get isAuthenticated    => _token != null;
  String? get token              => _token;
  String? get userRole           => _userRole;
  String? get lastNombre         => _lastNombre;
  int?    get lastIdTecnico      => _lastIdTecnico;
  bool    get credentialsRevoked => _credentialsRevoked;

  Future<String?> _readStoredValue(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fromPrefs = prefs.getString(key);
      if (fromPrefs != null && fromPrefs.isNotEmpty) return fromPrefs;
    } catch (_) {}
    try {
      final fromSec = await _storage.read(key: key);
      if (fromSec != null && fromSec.isNotEmpty) return fromSec;
    } catch (_) {}
    try {
      final fromLeg = await _legacyStorage.read(key: key);
      if (fromLeg != null && fromLeg.isNotEmpty) return fromLeg;
    } catch (_) {}
    return null;
  }

  Future<void> _writeStoredValue(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Ping al servidor para despertarlo (Cold Start en Render)
  /// Retorna true si responde 200 OK
  Future<bool> pingServer() async {
    for (final path in ['/', '/health', '/api/v1/ping']) {
      try {
        final resp = await http
            .get(Uri.parse('$_baseUrl$path'))
            .timeout(const Duration(seconds: 25));
        if (resp.statusCode == 200) return true;
      } catch (e) {
        debugPrint('[API] Falló el ping a $_baseUrl$path: $e');
      }
    }
    return false;
  }

  /// Intenta autenticarse contra el servidor.
  /// Devuelve null si el login fue exitoso.
  /// Devuelve un String descriptivo si hubo error (para mostrarlo en la UI).
  Future<String?> login(String username, String password) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          'password': password.trim(),
        }),
      ).timeout(_connTimeout);  // 90s — tolera cold-start de Render

      debugPrint('[API Login] Status: ${resp.statusCode} Body: ${resp.body}');

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _token = data['access_token'] as String?;
        final refreshToken = data['refresh_token'] as String?;
        _credentialsRevoked = false;

        if (_token != null) {
          await _writeStoredValue('jwt_token', _token!);
          if (refreshToken != null) {
            await _writeStoredValue('jwt_refresh_token', refreshToken);
          }
          // Persistir credenciales para _renovarSesionSilenciosa en SharedPreferences y SecureStorage
          await _writeStoredValue('pesa_cred_user', username.trim());
          await _writeStoredValue('pesa_cred_pass', password.trim());
          await _writeStoredValue('pesa_username', username.trim());
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('pesa_session_active', true);
          } catch (_) {}

          // Guardar nombre completo del response del servidor
          _lastNombre = data['nombre'] as String?;
          if (_lastNombre != null) {
            await _writeStoredValue('pesa_nombre_completo', _lastNombre!);
          }

          // Si el payload contiene la firma en base64/url, guardarla temporalmente
          String? firmaCloud = data['firma_base64'] as String? ??
              data['firma_digital'] as String? ??
              data['firma_url'] as String? ??
              data['firma'] as String?;
          if (firmaCloud != null && firmaCloud.trim().length > 50) {
            final clean = firmaCloud.contains(',') ? firmaCloud.split(',').last : firmaCloud;
            await _writeStoredValue('firma_cloud_login', clean.trim());
          }

          // Extraer role e id_tecnico del JWT payload
          try {
            final parts = _token!.split('.');
            if (parts.length == 3) {
              final payload = utf8.decode(base64Url.decode(
                  base64Url.normalize(parts[1])));
              final claims = jsonDecode(payload) as Map<String, dynamic>;
              _userRole      = claims['role'] as String?;
              _lastIdTecnico = claims['id_tecnico'] as int?;
              if (_lastIdTecnico == null && claims['id_tecnico'] != null) {
                _lastIdTecnico = int.tryParse(claims['id_tecnico'].toString());
              }
            }
          } catch (_) {}

          debugPrint('[API Login] \u2705 Token guardado — rol: $_userRole | nombre: $_lastNombre | idTec: $_lastIdTecnico');
          return null; // éxito
        }
        return 'El servidor no devolvió un token válido (respuesta incompleta).';
      }

      // Errores HTTP específicos con mensaje claro
      switch (resp.statusCode) {
        case 401:
          try {
            final body = jsonDecode(resp.body);
            final detail = (body as Map<String, dynamic>)['detail'] as String?;
            if (detail != null && detail.isNotEmpty) {
              return 'Acceso denegado: $detail';
            }
          } catch (_) {}
          return 'Credenciales incorrectas (401). Verifica tu usuario y contraseña.';
        case 403:
          _credentialsRevoked = true;
          return 'Acceso denegado (403). Tu cuenta puede estar inactiva o dada de baja.';
        case 422:
          return 'Error de formato (422). Contacta soporte técnico.';
        case 500:
        case 502:
        case 503:
          return 'Error interno del servidor (${resp.statusCode}). Intenta en unos minutos.';
        default:
          return 'Respuesta inesperada del servidor: HTTP ${resp.statusCode}.\n'
              'Cuerpo: ${resp.body.length > 120 ? resp.body.substring(0, 120) + "..." : resp.body}';
      }
    } on SocketException {
      return 'Sin conexión a la red.\n'
          'Verifica que la tablet tenga Wi-Fi activo y pueda alcanzar:\n$_baseUrl';
    } on TimeoutException {
      return 'Tiempo de espera agotado (>90s).\n'
          'El servidor puede estar iniciando (cold-start). Intenta de nuevo en 30 segundos.';
    } catch (e) {
      return 'Error inesperado: $e';
    }
  }

  // ── Renovación Silenciosa de Sesión (401 Auto-Login) ──────────────────────

  Future<bool> renovarSesionSilenciosa() => _renovarSesionSilenciosa();

  Future<bool> silentRefresh() => _renovarSesionSilenciosa();

  /// Invoca automáticamente en segundo plano el endpoint de login (o refresh)
  /// enviando las credenciales guardadas del técnico para renovar el token sin
  /// mostrar el bloqueo "Sesión expirada (401)".
  Future<bool> _renovarSesionSilenciosa() async {
    if (_isRefreshing) {
      for (int i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!_isRefreshing) break;
      }
      return _token != null;
    }

    _isRefreshing = true;
    try {
      // 1. Resolver credenciales guardadas del técnico (SharedPreferences + SecureStorage + Catálogo Offline)
      String? user = await _readStoredValue('pesa_cred_user') ??
          await _readStoredValue('pesa_username') ??
          AuthService.usuarioActual?.username;
      String? pass = await _readStoredValue('pesa_cred_pass');
      if ((pass == null || pass.isEmpty) && user != null && user.isNotEmpty) {
        pass = await _readStoredValue('offline_plain_$user');
      }
      if ((pass == null || pass.isEmpty) && user != null && user.isNotEmpty) {
        pass = AuthService.getDefaultPasswordForUser(user);
      }
      if ((pass == null || pass.isEmpty) && _lastNombre != null) {
        pass = AuthService.getDefaultPasswordForUser(_lastNombre);
      }

      // Prioridad A: Re-login silencioso directo con credenciales guardadas (emite token de 365 días)
      if (user != null && user.trim().isNotEmpty && pass != null && pass.trim().isNotEmpty) {
        debugPrint('[API] 🔄 _renovarSesionSilenciosa() → autenticando en segundo plano a $user...');
        final error = await login(user.trim(), pass.trim());
        if (error == null && _token != null) {
          debugPrint('[API] ✅ _renovarSesionSilenciosa() exitoso para $user');
          return true;
        }
        // Si la contraseña guardada difiere del catálogo por defecto, probar fallback del catálogo
        final defaultPass = AuthService.getDefaultPasswordForUser(user);
        if (defaultPass != null && defaultPass != pass.trim()) {
          final err2 = await login(user.trim(), defaultPass);
          if (err2 == null && _token != null) {
            debugPrint('[API] ✅ _renovarSesionSilenciosa() exitoso (fallback catálogo) para $user');
            return true;
          }
        }
        debugPrint('[API] ⚠️ Re-login con credenciales no completado: $error');
      }

      // Prioridad B: Usar refresh_token si existe
      final refreshToken = await _readStoredValue('jwt_refresh_token');
      if (refreshToken != null && refreshToken.isNotEmpty) {
        try {
          final resp = await http.post(
            Uri.parse('$_baseUrl/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          ).timeout(const Duration(seconds: 30));

          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            _token = data['access_token'] as String?;
            final newRefresh = data['refresh_token'] as String?;
            _credentialsRevoked = false;
            if (_token != null) {
              await _writeStoredValue('jwt_token', _token!);
              if (newRefresh != null) {
                await _writeStoredValue('jwt_refresh_token', newRefresh);
              }
              debugPrint('[API] ✅ _renovarSesionSilenciosa() vía refresh_token exitoso');
              return true;
            }
          } else if (resp.statusCode == 403) {
            _credentialsRevoked = true;
          }
        } catch (e) {
          debugPrint('[API] refresh_token falló: $e');
        }
      }

      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  /// Carga el token guardado y, si está expirado o inválido contra el servidor,
  /// lo renueva silenciosamente.
  Future<void> loadSavedToken() async {
    _token = await _readStoredValue('jwt_token');
    if (_token == null) {
      debugPrint('[API] No hay token guardado — intentando _renovarSesionSilenciosa si hay sesión activa...');
      try {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('pesa_session_active') == true) {
          await _renovarSesionSilenciosa();
        }
      } catch (_) {}
      return;
    }

    // 1. Validación local de exp
    if (_isTokenExpired(_token!)) {
      debugPrint('[API] Token guardado EXPIRADO localmente — renovando silenciosamente...');
      final ok = await _renovarSesionSilenciosa();
      debugPrint('[API] Renovación proactiva: ${ok ? "OK" : "Fallo — manteniendo sesión local"}');
      return;
    }

    // 2. Validación contra el servidor (/auth/me)
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/auth/me'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 401) {
        debugPrint('[API] Token rechazado por servidor (401) — ejecutando _renovarSesionSilenciosa...');
        final ok = await _renovarSesionSilenciosa();
        debugPrint('[API] _renovarSesionSilenciosa post-401: ${ok ? "OK" : "Fallo — se mantiene sesión local"}');
      } else if (resp.statusCode == 200) {
        debugPrint('[API] Token validado contra servidor OK');
        try {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          _userRole      = data['role'] as String?;
          _lastIdTecnico = data['id_tecnico'] as int?;
          _lastNombre    = data['nombre_completo'] as String?;
        } catch (_) {}
      } else {
        debugPrint('[API] Servidor retornó ${resp.statusCode} en validación — manteniendo token local');
      }
    } on SocketException {
      debugPrint('[API] Sin red al validar token — usando token local');
    } on TimeoutException {
      debugPrint('[API] Timeout al validar token (servidor frío) — usando token local');
    } catch (e) {
      debugPrint('[API] Error inesperado al validar token: $e — usando token local');
    }
  }

  /// Decodifica el claim `exp` del JWT y retorna true si ya expiró.
  bool _isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;
      final payload = utf8.decode(
          base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload) as Map<String, dynamic>;
      final exp = claims['exp'];
      if (exp == null) return false;
      final expDt = DateTime.fromMillisecondsSinceEpoch(
          (exp as int) * 1000, isUtc: true);
      return DateTime.now().toUtc().isAfter(
          expDt.subtract(const Duration(seconds: 60)));
    } catch (_) {
      return true;
    }
  }

  Future<void> logout() async {
    _token = null;
    _credentialsRevoked = false;
    await _storage.delete(key: 'jwt_token');
    await _storage.delete(key: 'jwt_refresh_token');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('jwt_token');
      await prefs.remove('jwt_refresh_token');
      await prefs.setBool('pesa_session_active', false);
    } catch (_) {}
  }

  /// Inyecta un token JWT directamente en memoria (sin llamada HTTP).
  void injectToken(String token) {
    _token = token;
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
        final claims = jsonDecode(payload) as Map<String, dynamic>;
        _userRole      = claims['role'] as String?;
        _lastIdTecnico = claims['id_tecnico'] as int?;
        if (_lastIdTecnico == null && claims['id_tecnico'] != null) {
          _lastIdTecnico = int.tryParse(claims['id_tecnico'].toString());
        }
        _lastNombre = claims['nombre'] as String? ?? claims['sub'] as String?;
      }
    } catch (_) {}
    debugPrint('[API] injectToken OK — role=$_userRole | idTec=$_lastIdTecnico');
  }

  // ── Headers con JWT ───────────────────────────────────────────────────────

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Map<String, String> get _authHeaders => {
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  // ── Wrapper / Interceptor HTTP con Reautenticación Silenciosa en 401 ─────

  /// Realiza GET con interceptor 401 automático (_renovarSesionSilenciosa + retry).
  Future<http.Response> _getWithRetry(Uri uri, {Duration? timeout}) async {
    if (_token == null) {
      await _renovarSesionSilenciosa();
    }
    var resp = await http.get(uri, headers: _headers)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 en GET $uri → invocando _renovarSesionSilenciosa()...');
      bool ok = false;
      try {
        ok = await _renovarSesionSilenciosa()
            .timeout(const Duration(seconds: 35), onTimeout: () => false);
      } catch (_) {}
      if (ok) {
        resp = await http.get(uri, headers: _headers)
            .timeout(timeout ?? _connTimeout);
        debugPrint('[API] Retry GET post-refresh → ${resp.statusCode}');
      }
    }
    return resp;
  }

  /// Realiza POST con interceptor 401 automático (_renovarSesionSilenciosa + retry).
  Future<http.Response> _postWithRetry(Uri uri, String body,
      {Duration? timeout}) async {
    if (_token == null) {
      await _renovarSesionSilenciosa();
    }
    var resp = await http.post(uri, headers: _headers, body: body)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 en POST $uri → invocando _renovarSesionSilenciosa()...');
      bool ok = false;
      try {
        ok = await _renovarSesionSilenciosa()
            .timeout(const Duration(seconds: 35), onTimeout: () => false);
      } catch (_) {}
      if (ok) {
        resp = await http.post(uri, headers: _headers, body: body)
            .timeout(timeout ?? _connTimeout);
        debugPrint('[API] Retry POST post-refresh → ${resp.statusCode}');
      }
    }
    return resp;
  }

  /// Wrapper público para peticiones POST JSON (sincronizar, subirPdf, enviarCorreo) con interceptor 401.
  Future<http.Response> postJsonWithAuthRetry(
    Uri uri,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) {
    return _postWithRetry(uri, jsonEncode(payload), timeout: timeout);
  }

  /// Realiza PATCH con interceptor 401 automático (_renovarSesionSilenciosa + retry).
  Future<http.Response> _patchWithRetry(Uri uri, String body,
      {Duration? timeout}) async {
    if (_token == null) {
      await _renovarSesionSilenciosa();
    }
    var resp = await http.patch(uri, headers: _headers, body: body)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 en PATCH $uri → invocando _renovarSesionSilenciosa()...');
      bool ok = false;
      try {
        ok = await _renovarSesionSilenciosa()
            .timeout(const Duration(seconds: 35), onTimeout: () => false);
      } catch (_) {}
      if (ok) {
        resp = await http.patch(uri, headers: _headers, body: body)
            .timeout(timeout ?? _connTimeout);
        debugPrint('[API] Retry PATCH post-refresh → ${resp.statusCode}');
      }
    }
    return resp;
  }

  /// Realiza PUT con interceptor 401 automático (_renovarSesionSilenciosa + retry).
  Future<http.Response> _putWithRetry(Uri uri, String body,
      {Duration? timeout}) async {
    if (_token == null) {
      await _renovarSesionSilenciosa();
    }
    var resp = await http.put(uri, headers: _headers, body: body)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 en PUT $uri → invocando _renovarSesionSilenciosa()...');
      bool ok = false;
      try {
        ok = await _renovarSesionSilenciosa()
            .timeout(const Duration(seconds: 35), onTimeout: () => false);
      } catch (_) {}
      if (ok) {
        resp = await http.put(uri, headers: _headers, body: body)
            .timeout(timeout ?? _connTimeout);
        debugPrint('[API] Retry PUT post-refresh → ${resp.statusCode}');
      }
    }
    return resp;
  }

  /// Repositorio de calibraciones concluidas (solo lectura, supervisión metrológica).
  /// El servidor valida que el usuario sea Alan Guevara (ID 8) o administrador.
  Future<List<Map<String, dynamic>>> getCalibracionesConsulta() async {
    final uri = Uri.parse('$_baseUrl/api/v1/sync/calibraciones-consulta');
    final resp = await _getWithRetry(uri, timeout: const Duration(seconds: 30));
    if (resp.statusCode == 200) {
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is List) {
        return data
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return const [];
    }
    throw HttpException('calibraciones-consulta HTTP ${resp.statusCode}');
  }

  Future<List<Map<String, dynamic>>> syncPull({
    DateTime? since,
    String? updatedAfter,
    int? tecnicoId,
    String? tecnicoNombre,
    String? q,
    int? limit,
  }) async {
    final queryParams = <String, String>{};

    final cleanQ = q?.trim();
    if (cleanQ != null && cleanQ.isNotEmpty) {
      queryParams['q'] = cleanQ;
    } else {
      final dateParam = updatedAfter ?? (since != null ? since.toUtc().toIso8601String() : null);
      if (dateParam != null && dateParam.trim().isNotEmpty) {
        queryParams['since'] = dateParam.trim();
        queryParams['updated_after'] = dateParam.trim();
      }
    }

    if (tecnicoId != null && tecnicoId > 0) {
      queryParams['tecnico_id'] = tecnicoId.toString();
    }
    if (tecnicoNombre != null && tecnicoNombre.trim().isNotEmpty) {
      queryParams['tecnico_nombre'] = tecnicoNombre.trim();
    }
    if (limit != null && limit > 0) {
      queryParams['limit'] = limit.toString();
    }

    final bool hasIncrementalDate = queryParams.containsKey('since');
    final endpointPath = (cleanQ != null && cleanQ.isNotEmpty) || !hasIncrementalDate
        ? '/api/v1/ordenes'
        : '/api/v1/sync/pull';

    final baseUri = Uri.parse('$_baseUrl$endpointPath');
    final uri = queryParams.isNotEmpty
        ? baseUri.replace(queryParameters: queryParams)
        : baseUri;

    debugPrint('[SyncPull] → URL: $uri (token=${_token != null})');

    try {
      var resp = await _getWithRetry(uri, timeout: _syncTimeout);
      if (resp.statusCode == 404 && endpointPath == '/api/v1/ordenes') {
        final altUri = Uri.parse('$_baseUrl/api/ordenes').replace(
          queryParameters: queryParams.isNotEmpty ? queryParams : null,
        );
        resp = await _getWithRetry(altUri, timeout: _syncTimeout);
      }

      debugPrint('[SyncPull] ← HTTP ${resp.statusCode}');

      if (resp.statusCode == 200) {
        final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
        debugPrint('[SyncPull] ✅ ${list.length} OS recibidas');
        return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      } else {
        final det = _detalleError(utf8.decode(resp.bodyBytes, allowMalformed: true));
        final msg = 'HTTP ${resp.statusCode} - $det';
        debugPrint('[SYNC ERROR] $msg');
        throw HttpException(msg);
      }
    } on TimeoutException catch (e) {
      debugPrint('[SyncPull] ⏱ TIMEOUT (${_syncTimeout.inSeconds}s): $e');
      rethrow;
    } on SocketException catch (e) {
      debugPrint('[SyncPull] 🔌 SIN RED / servidor inalcanzable: $e');
      rethrow;
    } catch (e, st) {
      debugPrint('[SyncPull] 💥 EXCEPCIÓN INESPERADA: $e\n$st');
      rethrow;
    }
  }

  /// Consulta directa a GET /api/v1/ordenes para descarga completa o con filtros
  Future<List<Map<String, dynamic>>> getOrdenes({
    String? updatedAfter,
    int? tecnicoId,
    String? tecnicoNombre,
    String? q,
    int? limit,
  }) async {
    return syncPull(
      updatedAfter: updatedAfter,
      tecnicoId: tecnicoId,
      tecnicoNombre: tecnicoNombre,
      q: q,
      limit: limit,
    );
  }

  /// Búsqueda directa en servidor (?q=...) por folio, cliente, marca, modelo, serie, CCA o DVE.
  Future<List<Map<String, dynamic>>> buscarOrdenesServidor(
    String query, {
    int limit = 150,
  }) async {
    final clean = query.trim();
    if (clean.isEmpty) return const [];
    return syncPull(
      q: clean,
      limit: limit,
    );
  }

  // ── Sync Push ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> syncPush(Map<String, dynamic> payload) async {
    final resp = await _postWithRetry(
      Uri.parse('$_baseUrl/api/v1/sync/push'),
      jsonEncode(payload),
      timeout: _syncTimeout,
    );

    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    throw HttpException('Push failed: ${resp.statusCode} ${resp.body}');
  }

  // ── Sync Firmas ───────────────────────────────────────────────────────────

  Future<void> pushFirmas(
      String folio,
      String firmaTecBase64,
      String firmaCliBase64, {
      String nombreIng = '',
      String puestoIng = '',
  }) async {
    final resp = await _postWithRetry(
      Uri.parse('$_baseUrl/api/v1/sync/firmas/$folio'),
      jsonEncode({
        'firma_tecnico':     firmaTecBase64,
        'firma_cliente':     firmaCliBase64,
        'firma_tecnico_png': firmaTecBase64,
        'firma_cliente_png': firmaCliBase64,
        'nombre_ing':        nombreIng.trim(),
        'puesto_ing':        puestoIng.trim(),
      }),
      timeout: _syncTimeout,
    );

    if (resp.statusCode != 200) {
      throw HttpException('Firmas failed: ${resp.statusCode}');
    }
  }

  // ── Download PDF autenticado ──────────────────────────────────────────────

  /// Descarga un PDF desde la URL dada con el token Bearer y lo guarda
  /// en el almacenamiento persistente de documentos de la app (Pesa_PDFs). Retorna la ruta local del archivo.
  Future<String> downloadPdf(String url, {String? targetFileName}) async {
    final urlsToTry = <String>[];
    final fullUrl = url.startsWith('http') ? url : '$_baseUrl$url';
    urlsToTry.add(fullUrl);

    String? folioFromUrl;
    // Si la URL es de tipo ordenes u os, agregar endpoints alternativos y /uploads
    try {
      final uri = Uri.parse(fullUrl);
      final segments = uri.pathSegments;
      if (segments.contains('ordenes') || segments.contains('os')) {
        final folio = segments.lastWhere((s) => s != 'pdf' && s != 'download-pdf', orElse: () => '');
        if (folio.isNotEmpty) {
          folioFromUrl = folio;
          urlsToTry.add('$_baseUrl/api/v1/ordenes/$folio/download-pdf');
          urlsToTry.add('$_baseUrl/api/v1/ordenes/$folio/pdf');
          urlsToTry.add('$_baseUrl/api/v1/os/$folio/download-pdf');
          urlsToTry.add('$_baseUrl/api/v1/os/$folio/pdf');
          urlsToTry.add('$_baseUrl/uploads/$folio.pdf');
        }
      }
    } catch (_) {}

    http.Response? lastResp;
    for (final tryUrl in urlsToTry.toSet()) {
      try {
        debugPrint('[API] downloadPdf intentando → $tryUrl');
        final baseTry = Uri.parse(tryUrl);
        final noCacheUri = baseTry.replace(queryParameters: {
          ...baseTry.queryParameters,
          't': DateTime.now().millisecondsSinceEpoch.toString(),
        });
        final resp = await _getWithRetry(noCacheUri, timeout: _syncTimeout);
        if (resp.statusCode == 200 && resp.bodyBytes.length > 500) {
          final docDir = await getApplicationDocumentsDirectory();
          final pdfDir = Directory('${docDir.path}/pdfs');
          if (!await pdfDir.exists()) await pdfDir.create(recursive: true);

          final cleanFolio = (folioFromUrl != null && folioFromUrl.isNotEmpty ? folioFromUrl : '').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final cleanName = targetFileName ?? (cleanFolio.isNotEmpty ? (cleanFolio.startsWith('OS-') ? '$cleanFolio.pdf' : 'OS-$cleanFolio.pdf') : 'pesa_pdf_${DateTime.now().millisecondsSinceEpoch}.pdf');
          final localPath = '${pdfDir.path}/$cleanName';
          final file = File(localPath);
          await file.writeAsBytes(resp.bodyBytes, flush: true, mode: FileMode.write);
          debugPrint('[API] PDF descargado con éxito desde $tryUrl → $localPath');

          // Guardar también copia en Pesa_PDFs para compatibilidad
          try {
            final legacyDir = Directory('${docDir.path}/Pesa_PDFs');
            if (!await legacyDir.exists()) await legacyDir.create(recursive: true);
            await File('${legacyDir.path}/$cleanName').writeAsBytes(resp.bodyBytes, flush: true, mode: FileMode.write);
          } catch (_) {}

          return localPath;
        }
        lastResp = resp;
      } catch (e) {
        debugPrint('[API] Error intentando $tryUrl: $e');
      }
    }

    throw HttpException('PDF download failed: HTTP ${lastResp?.statusCode ?? 404}');
  }

  /// Descarga en memoria la versión VIGENTE del PDF de un folio, evitando
  /// cualquier caché HTTP (query param `t` + cabeceras no-cache).
  /// Retorna null si el servidor no tiene PDF o no hay conexión.
  Future<Uint8List?> fetchPdfFresco(String folio) async {
    final f = folio.trim();
    if (f.isEmpty) return null;
    final t = DateTime.now().millisecondsSinceEpoch;
    final urls = <String>[
      '$_baseUrl/api/v1/ordenes/$f/download-pdf?t=$t',
      '$_baseUrl/api/v1/pdf/$f?t=$t',
      '$_baseUrl/api/v1/os/$f/download-pdf?t=$t',
      '$_baseUrl/api/v1/ordenes/$f/pdf?t=$t',
    ];
    final headers = <String, String>{
      ..._authHeaders,
      'Cache-Control': 'no-cache, no-store, max-age=0',
      'Pragma': 'no-cache',
    };
    for (final u in urls) {
      try {
        var resp = await http.get(Uri.parse(u), headers: headers).timeout(_syncTimeout);
        if (resp.statusCode == 401 &&
            await silentRefresh().timeout(const Duration(seconds: 15), onTimeout: () => false)) {
          resp = await http.get(Uri.parse(u), headers: {...headers, ..._authHeaders}).timeout(_syncTimeout);
        }
        final b = resp.bodyBytes;
        final esPdf = b.length > 500 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46; // %PDF
        debugPrint('[API] fetchPdfFresco $u → ${resp.statusCode} (${b.length} B, pdf=$esPdf)');
        if (resp.statusCode == 200 && esPdf) return b;
      } catch (e) {
        debugPrint('[API] fetchPdfFresco error $u: $e');
      }
    }
    return null;
  }

  // ── Upload Escaneo (multipart) ────────────────────────────────────────────

  /// Sube el archivo escaneado al servidor como adjunto de la OS.
  Future<void> uploadEscaneo(int osId, File file, String folio,
      {Map<String, dynamic>? campos}) async {
    final uri = Uri.parse('$_baseUrl/api/v1/ordenes/$osId/adjunto');
    debugPrint('[API] uploadEscaneo → $uri (folio: $folio)');

    Future<http.StreamedResponse> sendRequest() async {
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_authHeaders);
      campos?.forEach((k, v) {
        if (v != null && v.toString().trim().isNotEmpty) {
          request.fields[k] = v.toString();
        }
      });
      request.fields['folio_os'] = folio;
      request.files.add(await http.MultipartFile.fromPath(
        'archivo', file.path,
        filename: '$folio-ESCANEADO.pdf',
      ));
      return request.send().timeout(_syncTimeout);
    }

    var streamed = await sendRequest();

    if (streamed.statusCode == 401) {
      debugPrint('[API] 401 en upload → silentRefresh...');
      final ok = await silentRefresh();
      if (ok) streamed = await sendRequest();
    }

    if (streamed.statusCode != 200 && streamed.statusCode != 201) {
      final body = await streamed.stream.bytesToString();
      throw HttpException(
          'uploadEscaneo failed: HTTP ${streamed.statusCode} — $body');
    }
    debugPrint('[API] ✅ Escaneo subido para OS $osId');
  }

  // ── Upload PDF Generado (multipart + JSON fallback con interceptor 401) ───

  Future<bool> subirPdf(String folio, File file, {int? osId, Map<String, dynamic>? data}) =>
      uploadPdf(folio, file, osId: osId, data: data);

  /// Sube el PDF binario generado al endpoint de Render para disponibilidad inmediata,
  /// adjuntando siempre los metadatos actualizados del equipo (marca, modelo, id_indicador, CCA, DVE).
  Future<bool> uploadPdf(String folio, File file, {int? osId, Map<String, dynamic>? data}) async {
    if (_token == null) {
      await _renovarSesionSilenciosa();
    }
    Map<String, dynamic> effectiveData = <String, dynamic>{
      if (data != null) ...data,
    };
    try {
      final osLocal = await LocalDbService.instance.getOsByFolio(folio);
      if (osLocal != null) {
        final metaLocal = extraerMetaCorreoOrden({
          ...osLocal,
          if (data != null) ...data,
        });
        effectiveData = <String, dynamic>{
          ...metaLocal,
          if (osLocal['datos_tecnicos_json'] != null && effectiveData['datos_tecnicos_json'] == null)
            'datos_tecnicos_json': osLocal['datos_tecnicos_json'],
          ...effectiveData,
        };
      } else if (data != null) {
        effectiveData = <String, dynamic>{
          ...extraerMetaCorreoOrden(data),
          ...effectiveData,
        };
      }
    } catch (e) {
      debugPrint('[API] uploadPdf meta enrich fallback ($folio): $e');
    }

    final uri = Uri.parse('$_baseUrl/api/v1/ordenes/$folio/upload-pdf');
    debugPrint('[API] uploadPdf → $uri (folio: $folio, size: ${file.lengthSync()} bytes)');

    Future<http.StreamedResponse> sendMultipart(Uri targetUri, {Duration timeout = const Duration(seconds: 45)}) async {
      final request = http.MultipartRequest('POST', targetUri);
      request.headers.addAll(_authHeaders);
      request.fields['folio_os'] = folio;
      request.fields['folio'] = folio;
      if (osId != null && osId > 0) {
        request.fields['os_id'] = osId.toString();
      }
      if (effectiveData.isNotEmpty) {
        request.fields['data'] = jsonEncode(effectiveData);
      }
      if (effectiveData['correo_cliente'] != null &&
          effectiveData['correo_cliente'].toString().trim().isNotEmpty) {
        request.fields['correo_cliente'] = effectiveData['correo_cliente'].toString().trim();
      }
      request.files.add(await http.MultipartFile.fromPath(
        'file', file.path,
        filename: '$folio.pdf',
      ));
      return request.send().timeout(timeout);
    }

    try {
      var streamed = await sendMultipart(uri);
      if (streamed.statusCode == 401) {
        debugPrint('[API] 401 en uploadPdf → invocando _renovarSesionSilenciosa()...');
        final ok = await _renovarSesionSilenciosa();
        if (ok) streamed = await sendMultipart(uri);
      }
      if (streamed.statusCode == 200 || streamed.statusCode == 201) {
        debugPrint('[API] ✅ PDF subido exitosamente a Render para $folio');
        return true;
      } else {
        // Fallback a /api/v1/os/$folio/upload-pdf si el primero no responde 200
        final fallbackUri = Uri.parse('$_baseUrl/api/v1/os/$folio/upload-pdf');
        var streamed2 = await sendMultipart(fallbackUri, timeout: const Duration(seconds: 30));
        if (streamed2.statusCode == 401) {
          final ok = await _renovarSesionSilenciosa();
          if (ok) streamed2 = await sendMultipart(fallbackUri, timeout: const Duration(seconds: 30));
        }
        if (streamed2.statusCode == 200 || streamed2.statusCode == 201) {
          debugPrint('[API] ✅ PDF subido exitosamente a Render (fallback) para $folio');
          return true;
        }
        final body = await streamed.stream.bytesToString();
        debugPrint('[API] ⚠️ uploadPdf multipart falló: HTTP ${streamed.statusCode} — $body');
      }
    } catch (e) {
      debugPrint('[API] Error en multipart uploadPdf: $e');
    }

    // Fallback 3: JSON payload con base64 (tolerante a proxies y restricciones de multipart)
    try {
      final bytes = await file.readAsBytes();
      final base64Pdf = base64Encode(bytes);
      final jsonPayload = <String, dynamic>{
        'folio': folio,
        'folio_os': folio,
        if (osId != null && osId > 0) 'os_id': osId,
        'pdf_base64': base64Pdf,
        'estatus': 'Cerrado',
        if (data != null) 'data': data,
      };

      for (final u in [uri, Uri.parse('$_baseUrl/api/v1/os/$folio/upload-pdf')]) {
        final resJson = await postJsonWithAuthRetry(
          u,
          jsonPayload,
          timeout: const Duration(seconds: 30),
        );

        if (resJson.statusCode == 200 || resJson.statusCode == 201) {
          debugPrint('[API] ✅ PDF subido exitosamente a Render vía JSON Base64 para $folio');
          return true;
        }
      }
    } catch (eJson) {
      debugPrint('[API] Error en fallback JSON uploadPdf: $eJson');
    }

    return false;
  }

  /// Elimina en el backend (PostgreSQL en Render) las lecturas metrológicas, dictamen y firmas guardadas.
  Future<bool> resetTomaEnServidor(String folio) async {
    final cleanFolio = folio.trim();
    if (cleanFolio.isEmpty) return false;
    final uri = Uri.parse('$_baseUrl/api/v1/ordenes/$cleanFolio/toma');
    debugPrint('[API] resetTomaEnServidor → DELETE $uri');
    try {
      var response = await http.delete(uri, headers: _authHeaders).timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) {
        final ok = await _renovarSesionSilenciosa();
        if (ok) {
          response = await http.delete(uri, headers: _authHeaders).timeout(const Duration(seconds: 15));
        }
      }
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('[API] ✅ Toma metrológica reseteada en servidor para $cleanFolio');
        return true;
      }
      // Fallback a POST /api/v1/ordenes/$cleanFolio/reset-toma
      final fbUri = Uri.parse('$_baseUrl/api/v1/ordenes/$cleanFolio/reset-toma');
      final fbRes = await _postWithRetry(fbUri, '{}', timeout: const Duration(seconds: 15));
      if (fbRes.statusCode == 200 || fbRes.statusCode == 204) {
        debugPrint('[API] ✅ Toma metrológica reseteada en servidor (vía POST) para $cleanFolio');
        return true;
      }
      debugPrint('[API] ⚠️ Error al resetear toma en servidor: HTTP ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('[API] Excepción al resetear toma en servidor: $e');
    }
    return false;
  }

  /// Rutas de correo soportadas por el backend (Render). Se prueban en orden y solo se
  /// avanza a la siguiente si el servidor responde 404 (ruta no desplegada / no encontrada).
  ///   1. POST /api/v1/ordenes/{folio}/enviar-email      (ruta canónica)
  ///   2. POST /api/v1/ordenes/{folio}/enviar-correo     (alias)
  ///   3. POST /api/ordenes/{folio}/enviar-correo        (alias legacy)
  ///   4. POST /api/v1/correos/enviar                    (universal, body {folio|lote_id})
  List<Uri> _rutasCorreoOrden(String folio) {
    final f = Uri.encodeComponent(folio);
    return [
      Uri.parse('$_baseUrl/api/v1/ordenes/$f/enviar-email'),
      Uri.parse('$_baseUrl/api/v1/ordenes/$f/enviar-correo'),
      Uri.parse('$_baseUrl/api/ordenes/$f/enviar-correo'),
      Uri.parse('$_baseUrl/api/v1/correos/enviar'),
    ];
  }

  List<Uri> _rutasCorreoLote(String loteId) {
    final l = Uri.encodeComponent(loteId);
    return [
      Uri.parse('$_baseUrl/api/v1/lotes/$l/enviar-email'),
      Uri.parse('$_baseUrl/api/v1/lotes/$l/enviar-correo'),
      Uri.parse('$_baseUrl/api/lotes/$l/enviar-correo'),
      Uri.parse('$_baseUrl/api/v1/correos/enviar'),
    ];
  }

  String _detalleError(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) return j['detail'].toString();
    } catch (_) {}
    return body;
  }

  /// POST de correo con fallback de rutas y errores tipados:
  ///  - [CorreoSinConexionException]: sin red / timeout / Render 5xx  → encolar offline.
  ///  - [CorreoEndpointNoDisponibleException]: todas las rutas 404    → encolar offline.
  ///  - [CorreoRechazadoException]: 400/422 con motivo del servidor   → aviso al técnico.
  Future<Map<String, dynamic>> _postCorreo(
    List<Uri> rutas,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    String ultimo404 = '';
    for (final uri in rutas) {
      debugPrint('[API] Correo → POST $uri');
      http.Response response;
      try {
        response = await postJsonWithAuthRetry(uri, payload, timeout: timeout);
      } on SocketException catch (e) {
        throw CorreoSinConexionException('Sin conexión a internet (${e.message})');
      } on TimeoutException {
        throw CorreoSinConexionException('Tiempo de espera agotado con el servidor');
      } on HandshakeException catch (e) {
        throw CorreoSinConexionException('Error de conexión segura (${e.message})');
      } on http.ClientException catch (e) {
        throw CorreoSinConexionException('Error de red (${e.message})');
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
        return {'ok': true};
      }
      if (response.statusCode == 404) {
        ultimo404 = _detalleError(response.body);
        debugPrint('[API] Correo 404 en $uri ($ultimo404) → probando siguiente ruta');
        continue;
      }
      if (response.statusCode >= 500) {
        throw CorreoSinConexionException('Servidor no disponible (HTTP ${response.statusCode})');
      }
      throw CorreoRechazadoException(_detalleError(response.body), response.statusCode);
    }
    throw CorreoEndpointNoDisponibleException(
        'El servidor aún no expone el endpoint de correo ($ultimo404)');
  }

  /// Dispara el envío o reintento de correo electrónico para una orden individual.
  Future<Map<String, dynamic>> enviarEmailOrden(
    String folio, {
    String? correo,
    bool forzar = false,
    List<Map<String, dynamic>>? ordenesMeta,
    bool sinCorreoCliente = false,
    String? motivoSinCorreo,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cleanFolio = folio.trim();
    debugPrint('[API] enviarEmailOrden $cleanFolio (destinatario: $correo, sinCorreo: $sinCorreoCliente)');
    return _postCorreo(_rutasCorreoOrden(cleanFolio), <String, dynamic>{
      'folio': cleanFolio,
      'forzar': forzar,
      if (correo != null && correo.trim().isNotEmpty) 'correo': correo.trim(),
      if (ordenesMeta != null && ordenesMeta.isNotEmpty) 'ordenes_meta': ordenesMeta,
      if (sinCorreoCliente) 'sin_correo_cliente': true,
      if (motivoSinCorreo != null && motivoSinCorreo.trim().isNotEmpty) 'motivo_sin_correo': motivoSinCorreo.trim(),
    }, timeout: timeout);
  }

  /// Dispara el envío agrupado de un lote. El backend adjunta y cita ÚNICAMENTE
  /// las órdenes FIRMADAS/Cerradas activas (excluyendo CANCELADA) con PDF existente.
  Future<Map<String, dynamic>> enviarEmailLote(
    String loteId, {
    String? correo,
    bool forzar = true,
    List<String>? folios,
    List<Map<String, dynamic>>? ordenesMeta,
    bool sinCorreoCliente = false,
    String? motivoSinCorreo,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final cleanLote = loteId.trim();
    debugPrint('[API] enviarEmailLote $cleanLote (destinatario: $correo, folios: $folios, sinCorreo: $sinCorreoCliente)');
    return _postCorreo(_rutasCorreoLote(cleanLote), <String, dynamic>{
      'lote_id': cleanLote,
      'forzar': forzar,
      if (correo != null && correo.trim().isNotEmpty) 'correo': correo.trim(),
      if (folios != null && folios.isNotEmpty) 'folios': folios,
      if (ordenesMeta != null && ordenesMeta.isNotEmpty) 'ordenes_meta': ordenesMeta,
      if (sinCorreoCliente) 'sin_correo_cliente': true,
      if (motivoSinCorreo != null && motivoSinCorreo.trim().isNotEmpty) 'motivo_sin_correo': motivoSinCorreo.trim(),
    }, timeout: timeout);
  }

  /// Marca una orden sobrante no utilizada dentro de un lote como CANCELADA en el servidor
  /// sin eliminar el consecutivo de la base de datos (`PATCH /api/ordenes/{folio}/cancelar`).
  Future<Map<String, dynamic>> cancelarOrden(
    String folio, {
    required String motivo,
    String? usuario,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final f = Uri.encodeComponent(folio.trim());
    final payload = jsonEncode({
      'motivo': motivo.trim().isNotEmpty ? motivo.trim() : 'Se asignaron folios de más',
      if (usuario != null && usuario.trim().isNotEmpty) 'usuario': usuario.trim(),
    });
    final paths = [
      '/api/ordenes/$f/cancelar',
      '/api/v1/ordenes/$f/cancelar',
      '/api/v1/os/$f/cancelar',
    ];
    int lastStatus = 0;
    String lastBody = '';
    for (final pth in paths) {
      final uri = Uri.parse('$_baseUrl$pth');
      var resp = await _patchWithRetry(uri, payload, timeout: timeout);
      if (resp.statusCode == 405) {
        resp = await _postWithRetry(uri, payload, timeout: timeout);
      }
      lastStatus = resp.statusCode;
      lastBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final dec = jsonDecode(lastBody);
        return dec is Map ? Map<String, dynamic>.from(dec) : {'ok': true};
      }
      if (resp.statusCode != 404) break;
    }
    throw HttpException('HTTP $lastStatus - ${_detalleError(lastBody)}');
  }

  /// Reactiva una orden CANCELADA devolviéndola a EN_PROCESO (`PATCH /api/ordenes/{folio}/reactivar`, solo Admin).
  Future<Map<String, dynamic>> reactivarOrden(
    String folio, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final f = Uri.encodeComponent(folio.trim());
    final paths = [
      '/api/ordenes/$f/reactivar',
      '/api/v1/ordenes/$f/reactivar',
      '/api/v1/os/$f/reactivar',
    ];
    int lastStatus = 0;
    String lastBody = '';
    for (final pth in paths) {
      final uri = Uri.parse('$_baseUrl$pth');
      var resp = await _patchWithRetry(uri, '{}', timeout: timeout);
      if (resp.statusCode == 405) {
        resp = await _postWithRetry(uri, '{}', timeout: timeout);
      }
      lastStatus = resp.statusCode;
      lastBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final dec = jsonDecode(lastBody);
        return dec is Map ? Map<String, dynamic>.from(dec) : {'ok': true};
      }
      if (resp.statusCode != 404) break;
    }
    throw HttpException('HTTP $lastStatus - ${_detalleError(lastBody)}');
  }

  /// Obtiene la lista deduplicada de correos frecuentes de un cliente/sucursal desde Render.
  Future<List<String>> getCorreosFrecuentesCliente(
    int clienteId, {
    int? sucursalId,
    String? clienteNombre,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final qp = <String, String>{
      if (sucursalId != null && sucursalId > 0) 'sucursal_id': sucursalId.toString(),
      if (clienteNombre != null && clienteNombre.trim().isNotEmpty) 'cliente_nombre': clienteNombre.trim(),
    };
    for (final pth in ['/api/clientes/$clienteId/correos', '/api/v1/clientes/$clienteId/correos']) {
      try {
        final base = Uri.parse('$_baseUrl$pth');
        final uri = qp.isNotEmpty ? base.replace(queryParameters: qp) : base;
        final resp = await _getWithRetry(uri, timeout: timeout);
        if (resp.statusCode == 200) {
          final dec = jsonDecode(utf8.decode(resp.bodyBytes));
          if (dec is Map && dec['correos_frecuentes'] is List) {
            return (dec['correos_frecuentes'] as List)
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList();
          }
        }
      } catch (_) {}
    }
    return const [];
  }


  // ── Catálogos ────────────────────────────────────────────────────────────

  /// Obtiene una lista de registros de un endpoint de catálogo.
  /// [endpoint] debe ser relativo, p.ej. '/api/v1/clientes'
  Future<List<Map<String, dynamic>>> getCatalogo(String endpoint) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    debugPrint('[API] getCatalogo → $uri');

    final resp = await _getWithRetry(uri, timeout: _connTimeout);

    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body);
      if (body is List) return body.cast<Map<String, dynamic>>();
      // Algunos endpoints devuelven { "items": [...] }
      if (body is Map && body.containsKey('items')) {
        return (body['items'] as List).cast<Map<String, dynamic>>();
      }
      return [];
    }
    throw HttpException(
        'getCatalogo($endpoint) failed: HTTP ${resp.statusCode}');
  }

  // ── Catálogo Marcas y Modelos ────────────────────────────────────────────

  /// Obtiene la lista completa de marcas y modelos consolidados desde Render.
  Future<List<Map<String, dynamic>>> getMarcasModelos() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/marcas-modelos');
      debugPrint('[API] getMarcasModelos → $uri');
      final resp = await _getWithRetry(uri, timeout: _connTimeout);
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is List) return body.cast<Map<String, dynamic>>();
        if (body is Map && body.containsKey('items')) {
          return (body['items'] as List).cast<Map<String, dynamic>>();
        }
      }
      debugPrint('[API] getMarcasModelos falló con status: ${resp.statusCode}');
    } catch (e) {
      debugPrint('[API] Error getMarcasModelos: $e');
    }
    return [];
  }

  /// Envía marcas y modelos locales a Render para consolidación.
  Future<bool> pushMarcasModelos(List<Map<String, String>> items) async {
    if (items.isEmpty) return true;
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/marcas-modelos');
      debugPrint('[API] pushMarcasModelos (${items.length} items) → $uri');
      final resp = await _postWithRetry(
        uri,
        jsonEncode(items),
        timeout: _connTimeout,
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[API] ✅ Marcas y modelos consolidados en Render exitosamente');
        return true;
      }
      debugPrint('[API] ⚠️ pushMarcasModelos HTTP ${resp.statusCode}: ${resp.body}');
    } catch (e) {
      debugPrint('[API] Error pushMarcasModelos: $e');
    }
    return false;
  }

  // ── Catálogo Unificado de Administración y Guardado Parcial de Equipo ────

  String? _lastCatalogError;
  String? get lastCatalogError => _lastCatalogError;

  static Map<String, dynamic> _normalizarSucursalMap(Map raw, {int? defaultClienteId, String defaultClienteNombre = ''}) {
    final s = Map<String, dynamic>.from(raw);
    final sid = int.tryParse('${s['id'] ?? s['sucursal_id'] ?? ''}');
    final cid = int.tryParse('${s['cliente_id'] ?? s['id_cliente'] ?? ''}') ?? defaultClienteId;
    final nom = (s['nombre'] ?? s['nombre_sucursal'] ?? s['planta'] ?? s['sucursal'] ?? '').toString().trim();
    final dir = (s['direccion'] ?? '').toString().trim();
    final effNom = nom.isNotEmpty ? nom : dir;
    final effDir = dir.isNotEmpty ? dir : nom;
    final correo = (s['correo'] ?? s['email'] ?? '').toString().trim();
    final contacto = (s['contacto'] ?? s['contacto_nombre'] ?? '').toString().trim();
    final tel = (s['telefono'] ?? s['contacto_telefono'] ?? '').toString().trim();
    return {
      ...s,
      'id': sid,
      'sucursal_id': sid,
      'cliente_id': cid,
      'cliente_nombre': (s['cliente_nombre'] ?? s['cliente'] ?? defaultClienteNombre).toString().trim(),
      'nombre': effNom,
      'nombre_sucursal': effNom,
      'planta': (s['planta'] ?? effNom).toString().trim(),
      'direccion': effDir,
      'correo': correo,
      'contacto': contacto,
      'contacto_nombre': contacto,
      'telefono': tel,
      'contacto_telefono': tel,
    };
  }

  static Map<String, dynamic> _normalizarClienteMap(Map raw, [List<Map<String, dynamic>> extraSucs = const []]) {
    final c = Map<String, dynamic>.from(raw);
    final cid = int.tryParse('${c['id'] ?? c['id_cliente'] ?? ''}') ?? 0;
    final nom = (c['nombre'] ?? c['razon_social'] ?? '').toString().trim();
    final razon = (c['razon_social'] ?? nom).toString().trim();
    final correo = (c['correo'] ?? c['email'] ?? '').toString().trim();
    final dirBase = (c['direccion'] ?? '').toString().trim();
    final rawFrec = (c['correos_frecuentes'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];

    final rawNested = (c['sucursales'] as List?) ?? (c['direcciones'] as List?) ?? const [];
    final seen = <String>{};
    final sucs = <Map<String, dynamic>>[];

    void pushSuc(Map rawSuc) {
      final norm = _normalizarSucursalMap(rawSuc, defaultClienteId: cid, defaultClienteNombre: razon);
      final n = (norm['nombre'] ?? '').toString().trim();
      final d = (norm['direccion'] ?? '').toString().trim();
      if (n.isEmpty && d.isEmpty) return;
      final key = '${n.toLowerCase()}|${d.toLowerCase()}';
      if (seen.add(key)) sucs.add(norm);
    }

    for (final s in rawNested.whereType<Map>()) {
      pushSuc(s);
    }
    for (final s in extraSucs) {
      pushSuc(s);
    }
    if (dirBase.isNotEmpty &&
        !sucs.any((s) =>
            (s['direccion'] ?? '').toString().toLowerCase() == dirBase.toLowerCase() ||
            (s['nombre'] ?? '').toString().toLowerCase() == dirBase.toLowerCase())) {
      pushSuc({
        'id': null,
        'cliente_id': cid,
        'nombre': dirBase.length <= 80 ? dirBase : 'Matriz / Principal',
        'planta': 'Matriz / Principal',
        'direccion': dirBase,
        'correo': correo,
      });
    }

    return {
      ...c,
      'id': cid,
      'nombre': nom.isNotEmpty ? nom : razon,
      'razon_social': razon.isNotEmpty ? razon : nom,
      'correo': correo,
      'email': correo,
      'correos_frecuentes': rawFrec,
      'direccion': dirBase,
      'sucursales': sucs,
      'direcciones': sucs,
    };
  }

  /// Descarga los catálogos de Administración con manejo individual resiliente (sin Future.wait que aborte todo):
  /// clientes (con sus direcciones/sucursales anidadas), técnicos activos,
  /// tipos de servicio, tipos de instrumento e historial de instrumentos.
  Future<Map<String, dynamic>?> getAdminCatalogos() async {
    _lastCatalogError = null;
    final endpointErrors = <String>[];

    for (final path in ['/api/admin/catalogos', '/api/v1/admin/catalogos']) {
      try {
        final uri = Uri.parse('$_baseUrl$path');
        debugPrint('[API] getAdminCatalogos → $uri');
        final resp = await _getWithRetry(uri, timeout: const Duration(seconds: 35));
        if (resp.statusCode == 200) {
          final dec = jsonDecode(utf8.decode(resp.bodyBytes));
          final map = dec is Map<String, dynamic>
              ? dec
              : (dec is Map ? Map<String, dynamic>.from(dec) : null);
          if (map != null) {
            final rawCli = (map['clientes'] as List?) ?? const [];
            final rawSuc = (map['sucursales'] as List?) ?? const [];
            final sucsNorm = rawSuc.whereType<Map>().map((s) => _normalizarSucursalMap(s)).toList();
            final sucsByCli = <int, List<Map<String, dynamic>>>{};
            for (final s in sucsNorm) {
              final cid = s['cliente_id'] as int?;
              if (cid != null && cid > 0) {
                sucsByCli.putIfAbsent(cid, () => []).add(s);
              }
            }
            final clientesNorm = rawCli.whereType<Map>().map((c) {
              final cid = int.tryParse('${c['id'] ?? c['id_cliente'] ?? ''}') ?? 0;
              return _normalizarClienteMap(c, sucsByCli[cid] ?? const []);
            }).toList();
            return {
              ...map,
              'clientes': clientesNorm,
              'sucursales': sucsNorm,
            };
          }
        } else {
          final det = _detalleError(utf8.decode(resp.bodyBytes, allowMalformed: true));
          endpointErrors.add('$path: HTTP ${resp.statusCode} - $det');
          debugPrint('[API] getAdminCatalogos ($path) HTTP ${resp.statusCode}: $det');
        }
      } catch (e) {
        endpointErrors.add('$path: $e');
        debugPrint('[API] getAdminCatalogos ($path) error: $e');
      }
    }

    // Fallback resiliente: cada catálogo se descarga en su propio try/catch independiente.
    List<Map<String, dynamic>> clientes = [];
    List<Map<String, dynamic>> sucursales = [];
    List<Map<String, dynamic>> tecnicos = [];
    List<Map<String, dynamic>> tiposSvc = [];
    List<Map<String, dynamic>> tiposInst = [];
    List<Map<String, dynamic>> marcasModelos = [];

    try {
      clientes = await getCatalogo('/api/v1/clientes');
    } catch (e) {
      try {
        clientes = await getCatalogo('/api/clientes');
      } catch (e2) {
        endpointErrors.add('clientes: $e2');
      }
    }
    try {
      sucursales = await getCatalogo('/api/v1/sucursales');
    } catch (_) {
      try {
        sucursales = await getCatalogo('/api/sucursales');
      } catch (e2) {
        debugPrint('[API] Fallback sucursales: $e2');
      }
    }
    try {
      tecnicos = await getCatalogo('/api/v1/tecnicos');
    } catch (e) {
      endpointErrors.add('tecnicos: $e');
    }
    try {
      tiposSvc = await getCatalogo('/api/v1/tipos-servicio');
    } catch (_) {}
    try {
      tiposInst = await getCatalogo('/api/v1/tipos-instrumento');
    } catch (_) {}
    try {
      marcasModelos = await getMarcasModelos();
    } catch (_) {}

    if (clientes.isEmpty && tecnicos.isEmpty) {
      _lastCatalogError = endpointErrors.isNotEmpty
          ? endpointErrors.first
          : 'Catálogos vacíos o sin respuesta del servidor';
      return null;
    }

    final sucsNorm = sucursales.map((s) => _normalizarSucursalMap(s)).toList();
    final sucsByCli = <int, List<Map<String, dynamic>>>{};
    for (final s in sucsNorm) {
      final cid = s['cliente_id'] as int?;
      if (cid != null && cid > 0) {
        sucsByCli.putIfAbsent(cid, () => []).add(s);
      }
    }

    final clientesEnriquecidos = clientes.map((c) {
      final cid = int.tryParse('${c['id'] ?? c['id_cliente'] ?? ''}') ?? 0;
      return _normalizarClienteMap(c, sucsByCli[cid] ?? const []);
    }).toList();

    final allSucs = <Map<String, dynamic>>[];
    for (final c in clientesEnriquecidos) {
      final list = (c['sucursales'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
      allSucs.addAll(list);
    }

    final historial = marcasModelos
        .map((mm) => {
              'cliente': '',
              'sucursal': '',
              'marca': (mm['marca'] ?? '').toString(),
              'modelo': (mm['modelo'] ?? '').toString(),
              'serie': '',
              'id_indicador': '',
              'capacidad_maxima': '',
              'division_minima': '',
              'ubicacion': '',
              'tipo_instrumento': '',
            })
        .toList();

    if (endpointErrors.isNotEmpty && clientesEnriquecidos.isEmpty) {
      _lastCatalogError = endpointErrors.join(' | ');
    }

    return {
      'clientes': clientesEnriquecidos,
      'sucursales': allSucs.isNotEmpty ? allSucs : sucsNorm,
      'tecnicos': tecnicos,
      'tipos_servicio': tiposSvc,
      'tipos_instrumento': tiposInst,
      'historial_instrumentos': historial,
    };
  }

  /// Envía actualización ligera y parcial de datos de instrumento (`PATCH /api/ordenes/{folio}/instrumento`)
  /// manteniendo el estatus de la orden abierto (`EN_PROCESO` / `ASIGNADA`) sin finalizarla.
  Future<bool> patchInstrumentoOrden(
    String folio,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final f = Uri.encodeComponent(folio.trim());
    if (f.isEmpty) return false;
    final bodyStr = jsonEncode(payload);

    final patchPaths = [
      '/api/ordenes/$f/instrumento',
      '/api/v1/ordenes/$f/instrumento',
    ];

    for (final pth in patchPaths) {
      try {
        final resp = await _patchWithRetry(
          Uri.parse('$_baseUrl$pth'),
          bodyStr,
          timeout: timeout,
        );
        if (resp.statusCode == 200 || resp.statusCode == 201) {
          debugPrint('[API] ✅ patchInstrumentoOrden exitoso para $folio vía PATCH $pth');
          return true;
        }
        if (resp.statusCode != 404 && resp.statusCode != 405) {
          debugPrint('[API] ⚠️ PATCH $pth retornó HTTP ${resp.statusCode}: ${resp.body}');
        }
      } catch (e) {
        debugPrint('[API] Error en PATCH $pth ($folio): $e');
        return false;
      }
    }

    // Fallback POST alias
    try {
      final respPost = await _postWithRetry(
        Uri.parse('$_baseUrl/api/v1/ordenes/$f/instrumento'),
        bodyStr,
        timeout: timeout,
      );
      if (respPost.statusCode == 200 || respPost.statusCode == 201) {
        debugPrint('[API] ✅ patchInstrumentoOrden exitoso para $folio vía POST');
        return true;
      }
    } catch (_) {}

    // Fallback a /api/v1/sync/push con bandera parcial_instrumento = true (sin cerrar orden)
    try {
      final respSync = await _postWithRetry(
        Uri.parse('$_baseUrl/api/v1/sync/push'),
        jsonEncode({
          'folio_os': folio.trim(),
          'parcial_instrumento': true,
          'nuevo_estado': 'EN_PROCESO',
          'estatus': 'En Proceso',
          ...payload,
        }),
        timeout: timeout,
      );
      if (respSync.statusCode == 200 || respSync.statusCode == 201) {
        debugPrint('[API] ✅ patchInstrumentoOrden exitoso vía sync/push parcial para $folio');
        return true;
      }
    } catch (e) {
      debugPrint('[API] Fallback sync/push parcial falló ($folio): $e');
    }

    return false;
  }

  // ── Siguiente Folio Consecutivo Real ──────────────────────────────────────

  /// Consulta en vivo el siguiente folio consecutivo real en PostgreSQL
  /// para el [tipo] solicitado (OS, RMA, RE, LP, LV, OSOB, OSOCC).
  Future<Map<String, dynamic>?> getSiguienteFolio(String tipo) async {
    final t = Uri.encodeQueryComponent(tipo.trim().toUpperCase());
    final paths = <String>[
      '/api/folios/siguiente?tipo=$t',
      '/api/v1/folios/siguiente?tipo=$t',
    ];
    for (final path in paths) {
      try {
        final resp = await _getWithRetry(
          Uri.parse('$_baseUrl$path'),
          timeout: const Duration(seconds: 20),
        );
        if (resp.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
          if (decoded is Map) {
            return Map<String, dynamic>.from(decoded);
          }
        }
      } catch (e) {
        debugPrint('[API] getSiguienteFolio($path) falló: $e');
      }
    }
    return null;
  }

  // ── Crear Orden de Servicio ───────────────────────────────────────────────

  /// Crea una nueva Orden de Servicio (individual o lote, cualquiera de los 7 formatos) en el servidor.
  Future<Map<String, dynamic>> crearOrden(
      Map<String, dynamic> payload) async {
    var resp = await _postWithRetry(
      Uri.parse('$_baseUrl/api/v1/ordenes'),
      jsonEncode(payload),
    );
    if (resp.statusCode == 404) {
      resp = await _postWithRetry(
        Uri.parse('$_baseUrl/api/ordenes'),
        jsonEncode(payload),
      );
    }

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    }
    throw HttpException(
        'crearOrden failed: HTTP ${resp.statusCode} — ${resp.body}');
  }

  // ── Configuracion ────────────────────────────────────────────────────────

  void setBaseUrl(String url) {
    _baseUrl = url.trimRight().replaceAll(RegExp(r'/+$'), '');
  }

  String get baseUrl => _baseUrl;

  // ── Firma de perfil del técnico (Paridad 1:1 Windows y Render) ───────────

  /// Guarda la firma de perfil permanente del usuario/técnico en PostgreSQL (cat_tecnicos.firma_digital)
  /// enviando Content-Type: application/json + Authorization: Bearer <token> y retorna el Base64 confirmado.
  Future<String> guardarFirmaPerfilConRespuesta(int idTecnico, String firmaBase64) async {
    if (_token == null) {
      await loadSavedToken();
      if (_token == null) {
        await _renovarSesionSilenciosa();
      }
    }

    final cleanB64 = firmaBase64.contains(',')
        ? firmaBase64.split(',').last.trim().replaceAll(RegExp(r'\s+'), '')
        : firmaBase64.trim().replaceAll(RegExp(r'\s+'), '');
    if (cleanB64.length < 32) {
      throw Exception('La imagen de firma está vacía o corrupta');
    }

    final body = jsonEncode({
      'firma_base64':  cleanB64,
      'firma_digital': cleanB64,
      'firma_png':     cleanB64,
      'firma':         cleanB64,
    });

    final candidatePaths = <String>[
      if (idTecnico > 0) '/api/v1/usuarios/$idTecnico/firma',
      '/api/v1/usuarios/me/firma',
      if (idTecnico > 0) '/api/usuarios/$idTecnico/firma',
      '/api/usuarios/me/firma',
    ];

    int lastStatus = 0;
    String lastDetail = 'Sin respuesta del servidor';

    for (final pth in candidatePaths) {
      final uri = Uri.parse('$_baseUrl$pth');
      debugPrint('[API] guardarFirmaPerfil → PUT $uri (headers: Content-Type=application/json, auth=${_token != null})');

      http.Response resp = await _putWithRetry(uri, body, timeout: _connTimeout);
      if (resp.statusCode == 405 || resp.statusCode == 404) {
        debugPrint('[API] PUT $pth retornó ${resp.statusCode} → intentando POST...');
        resp = await _postWithRetry(uri, body, timeout: _connTimeout);
      }

      lastStatus = resp.statusCode;
      final respText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      lastDetail = _detalleError(respText);

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[API] ✅ Firma guardada en servidor vía $pth (HTTP ${resp.statusCode})');
        try {
          final decoded = jsonDecode(respText);
          if (decoded is Map) {
            final serverB64 = (decoded['firma_base64'] ?? decoded['firma_digital'] ?? '').toString().trim();
            if (serverB64.length >= 32) {
              return serverB64.contains(',') ? serverB64.split(',').last.trim() : serverB64;
            }
          }
        } catch (_) {}
        return cleanB64;
      }

      if (resp.statusCode != 404) {
        debugPrint('[API] ❌ guardarFirmaPerfil ($pth): HTTP ${resp.statusCode} — $lastDetail');
        throw Exception('HTTP $lastStatus - $lastDetail');
      }
    }

    throw Exception('HTTP $lastStatus - $lastDetail');
  }

  /// Compatibilidad booleana: retorna true si se guardó en el servidor o lanza excepción con código HTTP y detalle.
  Future<bool> guardarFirmaPerfil(int idTecnico, String firmaBase64) async {
    await guardarFirmaPerfilConRespuesta(idTecnico, firmaBase64);
    return true;
  }

  // ── CRUD Administrativo (Clientes, Sucursales y Asignación de OS) ────────

  Future<Map<String, dynamic>> crearCliente({
    required String razonSocial,
    String? rfc,
    String? telefono,
    String? correo,
    String? direccion,
  }) async {
    final payload = jsonEncode({
      'razon_social': razonSocial.trim(),
      'nombre': razonSocial.trim(),
      if (rfc != null && rfc.trim().isNotEmpty) 'rfc': rfc.trim(),
      if (telefono != null && telefono.trim().isNotEmpty) 'telefono': telefono.trim(),
      if (correo != null && correo.trim().isNotEmpty) 'correo': correo.trim(),
      if (direccion != null && direccion.trim().isNotEmpty) 'direccion': direccion.trim(),
    });
    var resp = await _postWithRetry(Uri.parse('$_baseUrl/api/v1/clientes'), payload);
    if (resp.statusCode == 404) {
      resp = await _postWithRetry(Uri.parse('$_baseUrl/api/clientes'), payload);
    }
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(resp.bodyBytes)) as Map);
    }
    throw Exception('Error creando cliente (${resp.statusCode}): ${resp.body}');
  }

  Future<Map<String, dynamic>> actualizarCliente(
    int clienteId, {
    String? razonSocial,
    String? rfc,
    String? telefono,
    String? direccion,
  }) async {
    final payload = jsonEncode({
      if (razonSocial != null && razonSocial.trim().isNotEmpty) 'razon_social': razonSocial.trim(),
      if (rfc != null) 'rfc': rfc.trim(),
      if (telefono != null) 'telefono': telefono.trim(),
      if (direccion != null) 'direccion': direccion.trim(),
    });
    var resp = await _putWithRetry(Uri.parse('$_baseUrl/api/v1/clientes/$clienteId'), payload);
    if (resp.statusCode == 404) {
      resp = await _putWithRetry(Uri.parse('$_baseUrl/api/clientes/$clienteId'), payload);
    }
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(resp.bodyBytes)) as Map);
    }
    throw Exception('Error actualizando cliente (${resp.statusCode}): ${resp.body}');
  }

  Future<List<Map<String, dynamic>>> getSucursalesCliente(int clienteId) async {
    for (final p in ['/api/v1/clientes/$clienteId/sucursales', '/api/clientes/$clienteId/sucursales']) {
      final resp = await _getWithRetry(Uri.parse('$_baseUrl$p'));
      if (resp.statusCode == 200) {
        final raw = jsonDecode(utf8.decode(resp.bodyBytes));
        if (raw is List) {
          return raw
              .whereType<Map>()
              .map((e) => _normalizarSucursalMap(e, defaultClienteId: clienteId))
              .toList();
        }
      }
    }
    return const [];
  }

  Future<Map<String, dynamic>> crearSucursal(
    int clienteId, {
    required String nombreSucursal,
    required String direccion,
    String? contactoNombre,
    String? contactoTelefono,
  }) async {
    final payload = jsonEncode({
      'nombre_sucursal': nombreSucursal.trim(),
      'direccion': direccion.trim(),
      if (contactoNombre != null && contactoNombre.trim().isNotEmpty) 'contacto_nombre': contactoNombre.trim(),
      if (contactoTelefono != null && contactoTelefono.trim().isNotEmpty) 'contacto_telefono': contactoTelefono.trim(),
    });
    var resp = await _postWithRetry(
      Uri.parse('$_baseUrl/api/v1/clientes/$clienteId/sucursales'),
      payload,
    );
    if (resp.statusCode == 404) {
      resp = await _postWithRetry(
        Uri.parse('$_baseUrl/api/clientes/$clienteId/sucursales'),
        payload,
      );
    }
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(resp.bodyBytes)) as Map);
    }
    throw Exception('Error creando sucursal (${resp.statusCode}): ${resp.body}');
  }

  Future<Map<String, dynamic>> actualizarSucursal(
    int clienteId,
    int sucursalId, {
    String? nombreSucursal,
    String? direccion,
    String? contactoNombre,
    String? contactoTelefono,
  }) async {
    final payload = jsonEncode({
      if (nombreSucursal != null && nombreSucursal.trim().isNotEmpty) 'nombre_sucursal': nombreSucursal.trim(),
      if (direccion != null) 'direccion': direccion.trim(),
      if (contactoNombre != null) 'contacto_nombre': contactoNombre.trim(),
      if (contactoTelefono != null) 'contacto_telefono': contactoTelefono.trim(),
    });
    var resp = await _putWithRetry(
      Uri.parse('$_baseUrl/api/v1/clientes/$clienteId/sucursales/$sucursalId'),
      payload,
    );
    if (resp.statusCode == 404) {
      resp = await _putWithRetry(
        Uri.parse('$_baseUrl/api/clientes/$clienteId/sucursales/$sucursalId'),
        payload,
      );
    }
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(resp.bodyBytes)) as Map);
    }
    throw Exception('Error actualizando sucursal (${resp.statusCode}): ${resp.body}');
  }

  Future<Map<String, dynamic>> asignarOrdenAdmin(
    String folio, {
    required int idTecnico,
    String? modalidad,
  }) async {
    final f = Uri.encodeComponent(folio.trim());
    final payload = jsonEncode({
      'id_tecnico': idTecnico,
      if (modalidad != null && modalidad.trim().isNotEmpty) 'modalidad': modalidad.trim(),
    });
    var resp = await _patchWithRetry(Uri.parse('$_baseUrl/api/v1/ordenes/$f/asignar'), payload);
    if (resp.statusCode == 404 || resp.statusCode == 405) {
      resp = await _postWithRetry(Uri.parse('$_baseUrl/api/v1/ordenes/$f/asignar'), payload);
    }
    if (resp.statusCode == 404) {
      resp = await _postWithRetry(Uri.parse('$_baseUrl/api/ordenes/$f/asignar'), payload);
    }
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(resp.bodyBytes)) as Map);
    }
    throw Exception('Error asignando orden (${resp.statusCode}): ${resp.body}');
  }

  /// Consulta al servidor si el técnico con [idTecnico] tiene firma registrada en cat_tecnicos.
  Future<bool> verificarFirmaPerfil(int idTecnico) async {
    final path = idTecnico > 0 ? '/api/v1/usuarios/$idTecnico/firma' : '/api/v1/usuarios/me/firma';
    debugPrint('[API] verificarFirmaPerfil → $path');
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final resp = await _getWithRetry(uri, timeout: _connTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final tiene = data['tiene_firma'] == true ||
            (data['firma_digital'] != null && data['firma_digital'].toString().length > 50) ||
            (data['firma_base64'] != null && data['firma_base64'].toString().length > 50);
        debugPrint('[API] verificarFirmaPerfil ($path) → tiene_firma: $tiene');
        return tiene;
      }
      debugPrint('[API] verificarFirmaPerfil: HTTP ${resp.statusCode}');
    } catch (e) {
      debugPrint('[API] verificarFirmaPerfil error: $e');
    }
    return false;
  }

  /// Obtiene la firma de perfil guardada del técnico en el servidor.
  Future<String?> obtenerFirmaPerfil(int idTecnico) async {
    final paths = <String>[
      if (idTecnico > 0) '/api/v1/usuarios/$idTecnico/firma',
      '/api/v1/usuarios/me/firma',
    ];
    for (final pth in paths) {
      final uri = Uri.parse('$_baseUrl$pth');
      debugPrint('[API] obtenerFirmaPerfil → $uri');
      try {
        final resp = await _getWithRetry(uri, timeout: _connTimeout);
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final String? b64 = data['firma_base64'] as String? ??
              data['firma_digital'] as String? ??
              data['firma_url'] as String? ??
              data['firma'] as String?;
          if (b64 != null && b64.trim().isNotEmpty) {
            final clean = b64.trim();
            final pure = clean.contains(',') ? clean.split(',').last : clean;
            return pure.trim();
          }
          return null;
        }
      } catch (e) {
        debugPrint('[API] Error en obtenerFirmaPerfil ($pth): $e');
      }
    }
    return null;
  }

  // ── Registro de errores técnicos en campo (v3.1) ─────────────────────────

  /// Reporta un incidente de captura digital fallida al servidor.
  /// Se usa cuando la modalidad es Híbrido y falla el guardado digital.
  /// Devuelve true si el reporte fue recibido.
  Future<bool> registrarErrorTecnico({
    required String errorMensaje,
    String? folio,
    String? tecnico,
    String? stackTrace,
    String dispositivo = 'Tablet Android',
  }) async {
    debugPrint('[API] registrarErrorTecnico → folio=$folio tecnico=$tecnico');
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/errores-tecnicos');
      final body = jsonEncode({
        'folio':         folio,
        'tecnico':       tecnico,
        'error_mensaje': errorMensaje,
        'stack_trace':   stackTrace,
        'dispositivo':   dispositivo,
      });

      Future<http.Response> doRequest() =>
          _postWithRetry(uri, body, timeout: _connTimeout);

      var resp = await doRequest();
      if (resp.statusCode == 401) {
        final ok = await silentRefresh();
        if (ok) resp = await doRequest();
      }

      if (resp.statusCode == 201 || resp.statusCode == 200) {
        debugPrint('[API] ✅ Error técnico registrado en servidor');
        return true;
      }
      debugPrint('[API] registrarErrorTecnico: HTTP ${resp.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[API] registrarErrorTecnico exception: $e');
      return false; // No lanzar — este método nunca debe romper el flujo
    }
  }
}


// ── Excepciones tipadas del envío de correo ─────────────────────────────────
/// Sin red, timeout o servidor caído: el envío debe encolarse en SQLite.
class CorreoSinConexionException implements Exception {
  final String mensaje;
  CorreoSinConexionException(this.mensaje);
  @override
  String toString() => mensaje;
}

/// Ninguna ruta de correo existe en el servidor (404): encolar y reintentar al sincronizar.
class CorreoEndpointNoDisponibleException implements Exception {
  final String mensaje;
  CorreoEndpointNoDisponibleException(this.mensaje);
  @override
  String toString() => mensaje;
}

/// El servidor rechazó el envío con un motivo de negocio (p. ej. lote sin órdenes firmadas).
class CorreoRechazadoException implements Exception {
  final String mensaje;
  final int statusCode;
  CorreoRechazadoException(this.mensaje, [this.statusCode = 400]);
  @override
  String toString() => mensaje;
}
