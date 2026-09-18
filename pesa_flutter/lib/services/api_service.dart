// lib/services/api_service.dart — Cliente HTTP para la API REST de PESA
// v2.1: interceptor 401, silentRefresh, downloadPdf, uploadEscaneo, catálogos
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class ApiService {
  static final ApiService instance = ApiService._();
  ApiService._();

  // URL base — se sobreescribe desde ConfigService al iniciar la app
  static const String _defaultBase = 'https://pesa-api-za9i.onrender.com';
  static const _storage = FlutterSecureStorage();

  String _baseUrl = _defaultBase;
  String? _token;
  bool _isRefreshing = false;

  // Timeouts — 90s para tolerar cold-start de Render (~50-80s). 120s para sync.
  Duration _connTimeout = const Duration(seconds: 90);
  Duration _syncTimeout = const Duration(seconds: 120);

  void setTimeouts({Duration? connTimeout, Duration? syncTimeout}) {
    if (connTimeout != null) _connTimeout = connTimeout;
    if (syncTimeout != null) _syncTimeout = syncTimeout;
  }

  String? _userRole;
  String? _lastNombre; // Nombre completo del último login exitoso

  /// Rol del usuario autenticado (extraído del JWT claims).
  String? get userRole => _userRole;

  /// Nombre completo del usuario (del response del servidor).
  String? get lastNombre => _lastNombre;

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Intenta autenticarse contra el servidor.
  /// Devuelve null si el login fue exitoso.
  /// Devuelve un String descriptivo si hubo error (para mostrarlo en la UI).
  Future<String?> login(String username, String password) async {
    try {
      // FastAPI usa OAuth2PasswordRequestForm → requiere form-urlencoded
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/login'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'username': username.trim(),
          'password': password.trim(),
        },
      ).timeout(_connTimeout);  // 90s — tolera cold-start de Render

      debugPrint('[API Login] Status: ${resp.statusCode} Body: ${resp.body}');

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _token = data['access_token'] as String?;
        final refreshToken = data['refresh_token'] as String?;

        if (_token != null) {
          await _storage.write(key: 'jwt_token', value: _token);
          if (refreshToken != null) {
            await _storage.write(key: 'jwt_refresh_token', value: refreshToken);
          }
          // Persistir credenciales para silentRefresh de emergencia
          await _storage.write(key: 'pesa_cred_user', value: username.trim());
          await _storage.write(key: 'pesa_cred_pass', value: password.trim());

          // Guardar nombre completo del response del servidor
          _lastNombre = data['nombre'] as String?;
          if (_lastNombre != null) {
            await _storage.write(
                key: 'pesa_nombre_completo', value: _lastNombre);
          }

          // Extraer role del JWT payload
          try {
            final parts = _token!.split('.');
            if (parts.length == 3) {
              final payload = utf8.decode(base64Url.decode(
                  base64Url.normalize(parts[1])));
              final claims = jsonDecode(payload) as Map<String, dynamic>;
              _userRole = claims['role'] as String?;
            }
          } catch (_) {}

          debugPrint('[API Login] ✅ Token guardado — rol: $_userRole | nombre: $_lastNombre');
          return null; // éxito
        }
        return 'El servidor no devolvió un token válido (respuesta incompleta).';
      }

      // Errores HTTP específicos con mensaje claro
      switch (resp.statusCode) {
        case 401:
          // Intentar extraer el mensaje exacto del backend
          try {
            final body = jsonDecode(resp.body);
            final detail = (body as Map<String, dynamic>)['detail'] as String?;
            if (detail != null && detail.isNotEmpty) {
              return 'Acceso denegado: $detail';
            }
          } catch (_) {}
          return 'Credenciales incorrectas (401). Verifica tu usuario y contraseña.';
        case 403:
          return 'Acceso denegado (403). Tu cuenta puede estar inactiva.';
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

  // ── Silent Refresh de Token ───────────────────────────────────────────────

  /// Intenta renovar el access_token sin interrumpir al usuario.
  /// Primero usa el refresh_token; si falla, reloguea con credenciales guardadas.
  /// Retorna true si tuvo éxito.
  Future<bool> silentRefresh() async {
    if (_isRefreshing) {
      // Esperar a que termine el refresh en curso
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!_isRefreshing) break;
      }
      return _token != null;
    }

    _isRefreshing = true;
    try {
      // Estrategia 1: usar refresh_token
      final refreshToken = await _storage.read(key: 'jwt_refresh_token');
      if (refreshToken != null) {
        try {
          final resp = await http.post(
            Uri.parse('$_baseUrl/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          ).timeout(_connTimeout);

          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            _token = data['access_token'] as String?;
            final newRefresh = data['refresh_token'] as String?;
            if (_token != null) {
              await _storage.write(key: 'jwt_token', value: _token);
              if (newRefresh != null) {
                await _storage.write(key: 'jwt_refresh_token', value: newRefresh);
              }
              debugPrint('[API] ✅ Silent refresh via refresh_token exitoso');
              return true;
            }
          }
        } catch (e) {
          debugPrint('[API] refresh_token falló: $e — intentando con credenciales');
        }
      }

      // Estrategia 2: re-login con credenciales guardadas
      final user = await _storage.read(key: 'pesa_cred_user');
      final pass = await _storage.read(key: 'pesa_cred_pass');
      if (user != null && pass != null) {
        final error = await login(user, pass);
        if (error == null) {
          debugPrint('[API] ✅ Silent refresh via credenciales exitoso');
          return true;
        }
        debugPrint('[API] ❌ Re-login falló: $error');
      }

      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  /// Carga el token guardado y, si está expirado, lo renueva silenciosamente.
  /// Así la primera petición tras abrir la app nunca falla con 401.
  Future<void> loadSavedToken() async {
    _token = await _storage.read(key: 'jwt_token');
    if (_token != null && _isTokenExpired(_token!)) {
      debugPrint('[API] Token cargado está EXPIRADO — renovando proactivamente...');
      _token = null; // invalidar para forzar refresh
      final ok = await silentRefresh();
      debugPrint('[API] Renovación proactiva: ${ok ? "✅ OK" : "❌ Falló"}');
    }
  }

  /// Decodifica el claim `exp` del JWT y retorna true si ya expió.
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
      // Margen de 60 s para evitar expirar justo al enviar
      return DateTime.now().toUtc().isAfter(
          expDt.subtract(const Duration(seconds: 60)));
    } catch (_) {
      return true; // Si no se puede decodificar, asumir expirado
    }
  }

  Future<void> logout() async {
    _token = null;
    await _storage.delete(key: 'jwt_token');
    await _storage.delete(key: 'jwt_refresh_token');
    // No borramos credenciales — se mantienen para el próximo login
  }

  bool get isAuthenticated => _token != null;

  // ── Headers con JWT ───────────────────────────────────────────────────────

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Map<String, String> get _authHeaders => {
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  // ── GET con interceptor 401 automático ───────────────────────────────────

  /// Realiza GET con retry automático si recibe 401.
  Future<http.Response> _getWithRetry(Uri uri, {Duration? timeout}) async {
    var resp = await http.get(uri, headers: _headers)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 detectado → intentando silentRefresh...');
      final ok = await silentRefresh();
      if (ok) {
        // Reintentar con el nuevo token
        resp = await http.get(uri, headers: _headers)
            .timeout(timeout ?? _connTimeout);
        debugPrint('[API] Retry post-refresh → ${resp.statusCode}');
      }
    }
    return resp;
  }

  /// Realiza POST con retry automático si recibe 401.
  Future<http.Response> _postWithRetry(Uri uri, String body,
      {Duration? timeout}) async {
    var resp = await http.post(uri, headers: _headers, body: body)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 en POST → intentando silentRefresh...');
      final ok = await silentRefresh();
      if (ok) {
        resp = await http.post(uri, headers: _headers, body: body)
            .timeout(timeout ?? _connTimeout);
      }
    }
    return resp;
  }

  // ── Sync Pull ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> syncPull({DateTime? since}) async {
    final sinceStr = (since ?? DateTime(2000)).toUtc().toIso8601String();
    final uri = Uri.parse(
        '$_baseUrl/api/v1/sync/pull?since=${Uri.encodeComponent(sinceStr)}');

    debugPrint('[SyncPull] → URL: $uri');
    debugPrint('[SyncPull] → Token presente: ${_token != null}');
    debugPrint('[SyncPull] → Timeout: ${_syncTimeout.inSeconds}s');

    try {
      // Asegurar token válido antes de la petición
      if (_token == null || _isTokenExpired(_token!)) {
        debugPrint('[SyncPull] Token ausente/expirado — renovando antes de pull...');
        await silentRefresh();
      }

      final resp = await _getWithRetry(uri, timeout: _syncTimeout);

      debugPrint('[SyncPull] ← HTTP ${resp.statusCode}');

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        debugPrint('[SyncPull] ✅ ${list.length} OS recibidas');
        return list.cast<Map<String, dynamic>>();
      }

      if (resp.statusCode == 401) {
        // _getWithRetry ya intentó refresh una vez — si sigue 401 es fallo real
        debugPrint('[SyncPull] ❌ 401 persistente tras refresh');
        throw HttpException('Pull failed: 401 {"detail":"Sesión expirada — inicia sesión nuevamente"}');
      }

      debugPrint('[SyncPull] ❌ ERROR ${resp.statusCode} — Body: ${resp.body}');
      throw HttpException('Pull failed: ${resp.statusCode} ${resp.body}');

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
  /// en el directorio temporal de la app. Retorna la ruta local del archivo.
  Future<String> downloadPdf(String url) async {
    final fullUrl = url.startsWith('http') ? url : '$_baseUrl$url';
    debugPrint('[API] downloadPdf → $fullUrl');

    final resp = await _getWithRetry(Uri.parse(fullUrl), timeout: _syncTimeout);

    if (resp.statusCode != 200) {
      throw HttpException(
          'PDF download failed: HTTP ${resp.statusCode}');
    }

    final tmpDir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final localPath = '${tmpDir.path}/pesa_pdf_$ts.pdf';
    await File(localPath).writeAsBytes(resp.bodyBytes);
    debugPrint('[API] PDF guardado en: $localPath');
    return localPath;
  }

  // ── Upload Escaneo (multipart) ────────────────────────────────────────────

  /// Sube el archivo escaneado al servidor como adjunto de la OS.
  Future<void> uploadEscaneo(int osId, File file, String folio) async {
    final uri = Uri.parse('$_baseUrl/api/v1/ordenes/$osId/adjunto');
    debugPrint('[API] uploadEscaneo → $uri (folio: $folio)');

    Future<http.StreamedResponse> sendRequest() async {
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_authHeaders);
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

  // ── Crear Orden de Servicio ───────────────────────────────────────────────

  /// Crea una nueva Orden de Servicio en el servidor.
  Future<Map<String, dynamic>> crearOrden(
      Map<String, dynamic> payload) async {
    final resp = await _postWithRetry(
      Uri.parse('$_baseUrl/api/v1/ordenes'),
      jsonEncode(payload),
    );

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    throw HttpException(
        'crearOrden failed: HTTP ${resp.statusCode} — ${resp.body}');
  }

  // ── Configuracion ────────────────────────────────────────────────────────

  void setBaseUrl(String url) {
    _baseUrl = url.trimRight().replaceAll(RegExp(r'/+$'), '');
  }

  String get baseUrl => _baseUrl;
}
