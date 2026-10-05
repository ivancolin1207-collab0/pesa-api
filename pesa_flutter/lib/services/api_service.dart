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
  int?    _lastIdTecnico; // ID en cat_tecnicos del último login

  bool    get isAuthenticated => _token != null;
  String? get userRole       => _userRole;
  String? get lastNombre     => _lastNombre;
  int?    get lastIdTecnico  => _lastIdTecnico;

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Ping al servidor para despertarlo (Cold Start en Render)
  /// Retorna true si responde 200 OK
  Future<bool> pingServer() async {
    try {
      debugPrint('[API] Enviando ping a $_baseUrl/health ...');
      // Intentamos con un timeout de 60s para cold start
      var resp = await http.get(Uri.parse('$_baseUrl/health')).timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200) return true;
      
      debugPrint('[API] /health fallo. Intentando /api/v1/ping ...');
      resp = await http.get(Uri.parse('$_baseUrl/api/v1/ping')).timeout(const Duration(seconds: 60));
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[API] Falló el ping al servidor: $e');
      return false;
    }
  }

  /// Intenta autenticarse contra el servidor.
  /// Devuelve null si el login fue exitoso.
  /// Devuelve un String descriptivo si hubo error (para mostrarlo en la UI).
  Future<String?> login(String username, String password) async {
    try {
      // [FIX v3.1.2] Usar JSON en lugar de form-urlencoded.
      // El backend auth.py procesa JSON primero (Content-Type: application/json).
      // Esto elimina problemas de codificación con caracteres especiales y es más fiable.
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

          // Si el payload contiene la firma en base64/url, guardarla temporalmente
          String? firmaCloud = data['firma_base64'] as String? ??
              data['firma_digital'] as String? ??
              data['firma_url'] as String? ??
              data['firma'] as String?;
          if (firmaCloud != null && firmaCloud.trim().length > 50) {
            final clean = firmaCloud.contains(',') ? firmaCloud.split(',').last : firmaCloud;
            await _storage.write(key: 'firma_cloud_login', value: clean.trim());
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
              // Fallback: id_tecnico puede venir como String numérico
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

  /// Carga el token guardado y, si está expirado o inválido contra el servidor,
  /// lo renueva silenciosamente.
  /// [FIX] Valida el token localmente (exp) Y contra el servidor (/auth/me).
  /// Si el servidor rechaza el token (p.ej. clave JWT cambiada), lo descarta
  /// y ejecuta silentRefresh para obtener uno nuevo.
  Future<void> loadSavedToken() async {
    _token = await _storage.read(key: 'jwt_token');
    if (_token == null) {
      debugPrint('[API] No hay token guardado.');
      return;
    }

    // 1. Validación local de exp
    if (_isTokenExpired(_token!)) {
      debugPrint('[API] Token guardado EXPIRADO localmente — renovando...');
      // [FIX-401-LOOP] No limpiar el token si silentRefresh falla (sin red):
      // se mantiene para trabajo offline.
      final ok = await silentRefresh();
      debugPrint('[API] Renovacion proactiva: ${ok ? "OK" : "Fallo — usando sesion local"}');
      return;
    }

    // 2. [FIX] Validación contra el servidor — detecta tokens con firma incorrecta
    // Usa /auth/me que es liviano y retorna rapidamente
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/auth/me'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 401) {
        // Token rechazado por el servidor (firma incorrecta o revocado).
        // [FIX-401-LOOP] Intentar renovar UNA VEZ sin destruir la sesión local.
        // Si silentRefresh falla (servidor frío, sin red), mantener el token
        // para permitir trabajo offline. NO redirigir al login automáticamente.
        debugPrint('[API] Token rechazado por servidor (401) — intentando silentRefresh...');
        final ok = await silentRefresh();
        debugPrint('[API] silentRefresh post-401: ${ok ? "OK" : "Fallo — se mantiene sesion local para offline"}');
        // NO emitir sessionExpiredEvents aquí: este método se ejecuta en background
        // (arranque de app). Solo emitir desde login/refresh explícito del usuario.
      } else if (resp.statusCode == 200) {
        // Token valido — extraer role e id_tecnico del response
        debugPrint('[API] Token validado contra servidor OK');
        try {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          _userRole      = data['role'] as String?;
          _lastIdTecnico = data['id_tecnico'] as int?;
          _lastNombre    = data['nombre_completo'] as String?;
        } catch (_) {}
      } else {
        // Error de servidor (5xx, cold-start) — no descartar el token
        debugPrint('[API] Servidor retorno ${resp.statusCode} en validacion — manteniendo token local');
      }
    } on SocketException {
      // Sin red — token local considerado valido por ahora
      debugPrint('[API] Sin red al validar token — usando token local');
    } on TimeoutException {
      debugPrint('[API] Timeout al validar token (servidor frio) — usando token local');
    } catch (e) {
      debugPrint('[API] Error inesperado al validar token: $e — usando token local');
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

  /// Inyecta un token JWT directamente en memoria (sin llamada HTTP).
  /// Usado por SyncService para recuperar el token de SecureStorage
  /// sin disparar silentRefresh (que tiene timeout de 90s).
  void injectToken(String token) {
    _token = token;
    // Extraer claims del JWT para poblar userRole e idTecnico
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

  // ── GET con interceptor 401 automático ───────────────────────────────────

  /// Realiza GET con retry automático si recibe 401.
  Future<http.Response> _getWithRetry(Uri uri, {Duration? timeout}) async {
    var resp = await http.get(uri, headers: _headers)
        .timeout(timeout ?? _connTimeout);

    if (resp.statusCode == 401) {
      debugPrint('[API] 401 detectado → intentando silentRefresh (15s max)...');
      bool ok = false;
      try {
        ok = await silentRefresh()
            .timeout(const Duration(seconds: 15), onTimeout: () => false);
      } catch (_) {}
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
      debugPrint('[API] 401 en POST → intentando silentRefresh (15s max)...');
      bool ok = false;
      try {
        ok = await silentRefresh()
            .timeout(const Duration(seconds: 15), onTimeout: () => false);
      } catch (_) {}
      if (ok) {
        resp = await http.post(uri, headers: _headers, body: body)
            .timeout(timeout ?? _connTimeout);
      }
    }
    return resp;
  }

  // ── Sync Pull ─────────────────────────────────────────────────────────────

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
  }) async {
    final queryParams = <String, String>{};

    final dateParam = updatedAfter ?? (since != null ? since.toUtc().toIso8601String() : null);
    if (dateParam != null && dateParam.trim().isNotEmpty) {
      queryParams['since'] = dateParam.trim();
      queryParams['updated_after'] = dateParam.trim();
    }

    if (tecnicoId != null && tecnicoId > 0) {
      queryParams['tecnico_id'] = tecnicoId.toString();
    }
    if (tecnicoNombre != null && tecnicoNombre.trim().isNotEmpty) {
      queryParams['tecnico_nombre'] = tecnicoNombre.trim();
    }

    // Si updatedAfter == null y no hay fecha: consultar directamente GET /api/v1/ordenes sin filtros de fecha
    final endpointPath = (dateParam == null || dateParam.trim().isEmpty)
        ? '/api/v1/ordenes'
        : '/api/v1/sync/pull';

    final baseUri = Uri.parse('$_baseUrl$endpointPath');
    final uri = queryParams.isNotEmpty
        ? baseUri.replace(queryParameters: queryParams)
        : baseUri;

    debugPrint('[SyncPull] → URL: $uri');
    debugPrint('[SyncPull] → Token presente: ${_token != null}');
    debugPrint('[SyncPull] → Timeout: ${_syncTimeout.inSeconds}s');

    try {
      final resp = await _getWithRetry(uri, timeout: _syncTimeout);

      debugPrint('[SyncPull] ← HTTP ${resp.statusCode}');

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        debugPrint('[SyncPull] ✅ ${list.length} OS recibidas');
        return list.cast<Map<String, dynamic>>();
      } else {
        final msg = "Error ${resp.statusCode}: ${resp.body}";
        debugPrint("[SYNC ERROR] $msg");
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
  }) async {
    return syncPull(
      updatedAfter: updatedAfter,
      tecnicoId: tecnicoId,
      tecnicoNombre: tecnicoNombre,
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

  // ── Upload PDF Generado (multipart) ───────────────────────────────────────

  /// Sube el PDF binario generado al endpoint de Render para disponibilidad inmediata.
  Future<bool> uploadPdf(String folio, File file, {int? osId, Map<String, dynamic>? data}) async {
    final uri = Uri.parse('$_baseUrl/api/v1/ordenes/$folio/upload-pdf');
    debugPrint('[API] uploadPdf → $uri (folio: $folio, size: ${file.lengthSync()} bytes)');

    Future<http.StreamedResponse> sendRequest() async {
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_authHeaders);
      request.fields['folio_os'] = folio;
      request.fields['folio'] = folio;
      if (osId != null && osId > 0) {
        request.fields['os_id'] = osId.toString();
      }
      if (data != null) {
        request.fields['data'] = jsonEncode(data);
      }
      request.files.add(await http.MultipartFile.fromPath(
        'file', file.path,
        filename: '$folio.pdf',
      ));
      return request.send().timeout(const Duration(seconds: 45));
    }

    try {
      var streamed = await sendRequest();
      if (streamed.statusCode == 401) {
        debugPrint('[API] 401 en uploadPdf → silentRefresh...');
        final ok = await silentRefresh();
        if (ok) streamed = await sendRequest();
      }
      if (streamed.statusCode == 200 || streamed.statusCode == 201) {
        debugPrint('[API] ✅ PDF subido exitosamente a Render para $folio');
        return true;
      } else {
        // Fallback a /api/v1/os/$folio/upload-pdf si el primero no responde 200
        final fallbackUri = Uri.parse('$_baseUrl/api/v1/os/$folio/upload-pdf');
        final req2 = http.MultipartRequest('POST', fallbackUri);
        req2.headers.addAll(_authHeaders);
        req2.fields['folio_os'] = folio;
        req2.fields['folio'] = folio;
        if (osId != null && osId > 0) {
          req2.fields['os_id'] = osId.toString();
        }
        if (data != null) {
          req2.fields['data'] = jsonEncode(data);
        }
        req2.files.add(await http.MultipartFile.fromPath(
          'file', file.path,
          filename: '$folio.pdf',
        ));
        final streamed2 = await req2.send().timeout(const Duration(seconds: 30));
        if (streamed2.statusCode == 200 || streamed2.statusCode == 201) {
          debugPrint('[API] ✅ PDF subido exitosamente a Render (fallback) para $folio');
          return true;
        }
        final body = await streamed.stream.bytesToString();
        debugPrint('[API] ⚠️ uploadPdf falló: HTTP ${streamed.statusCode} — $body');
      }
    } catch (e) {
      debugPrint('[API] Error en uploadPdf: $e');
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
        final ok = await silentRefresh();
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
      final fbRes = await http.post(fbUri, headers: _authHeaders).timeout(const Duration(seconds: 15));
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

  // ── Firma de perfil del técnico (v3.1) ───────────────────────────────────

  /// Guarda la firma de perfil permanente del técnico en el servidor.
  /// [idTecnico] es el ID del técnico en cat_tecnicos.
  /// [firmaBase64] es el trazo PNG en Base64.
  /// Retorna true si se guardó correctamente.
  Future<bool> guardarFirmaPerfil(int idTecnico, String firmaBase64) async {
    debugPrint('[API] guardarFirmaPerfil → /api/v1/usuarios/$idTecnico/firma');
    final uri = Uri.parse('$_baseUrl/api/v1/usuarios/$idTecnico/firma');
    final body = jsonEncode({
      'firma_digital': firmaBase64,
      'firma_base64':  firmaBase64,
      'firma':         firmaBase64,
    });

    Future<http.Response> doPost() =>
        http.post(uri, headers: _authHeaders, body: body).timeout(_connTimeout);
    Future<http.Response> doPut() =>
        http.put(uri, headers: _authHeaders, body: body).timeout(_connTimeout);

    var resp = await doPost();
    if (resp.statusCode == 405 || resp.statusCode == 404) {
      debugPrint('[API] POST retornó ${resp.statusCode}, intentando PUT...');
      resp = await doPut();
    } else if (resp.statusCode == 401) {
      final ok = await silentRefresh();
      if (ok) {
        resp = await doPost();
        if (resp.statusCode == 405 || resp.statusCode == 404) {
          resp = await doPut();
        }
      }
    }

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      debugPrint('[API] ✅ Firma de perfil guardada para técnico $idTecnico');
      return true;
    }
    debugPrint('[API] ❌ guardarFirmaPerfil: HTTP ${resp.statusCode} — ${resp.body}');
    return false;
  }

  /// Consulta al servidor si el técnico con [idTecnico] tiene firma registrada en cat_tecnicos.
  Future<bool> verificarFirmaPerfil(int idTecnico) async {
    debugPrint('[API] verificarFirmaPerfil → /api/v1/usuarios/$idTecnico/firma');
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/usuarios/$idTecnico/firma');
      final resp = await _getWithRetry(uri, timeout: _connTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final tiene = data['tiene_firma'] == true ||
            (data['firma_digital'] != null && data['firma_digital'].toString().length > 50) ||
            (data['firma_base64'] != null && data['firma_base64'].toString().length > 50);
        debugPrint('[API] verificarFirmaPerfil id=$idTecnico → tiene_firma: $tiene');
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
    if (idTecnico <= 0) return null;
    final uri = Uri.parse('$_baseUrl/api/v1/usuarios/$idTecnico/firma');
    debugPrint('[API] obtenerFirmaPerfil → $uri');
    try {
      final resp = await _getWithRetry(uri, timeout: _connTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        String? b64 = data['firma_digital'] as String? ??
            data['firma_base64'] as String? ??
            data['firma_url'] as String? ??
            data['firma'] as String?;
        if (b64 != null && b64.trim().isNotEmpty) {
          final clean = b64.trim();
          final pure = clean.contains(',') ? clean.split(',').last : clean;
          return pure.trim();
        }
      }
    } catch (e) {
      debugPrint('[API] Error en obtenerFirmaPerfil id=$idTecnico: $e');
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
