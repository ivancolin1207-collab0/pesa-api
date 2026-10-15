// lib/services/auth_service.dart
// v5: Login offline dual (SHA-256 + texto plano) + seed forzado con delete-before-write
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'firma_tecnico_service.dart';

class UsuarioActual {
  final int? id;
  final String nombre;
  final String rol;
  final String username;

  UsuarioActual({
    this.id,
    required this.nombre,
    required this.rol,
    required this.username,
  });

  bool get isAdmin {
    final r = AuthService.normalizeRole(rol);
    final u = username.toLowerCase().trim();
    return r == 'administrador' || r == 'admin' || u == 'ivancolin1207';
  }

  bool get isTecnico {
    if (isAdmin) return false;
    final r = AuthService.normalizeRole(rol);
    return r == 'tecnico' ||
           r == 'servicio' ||
           r == 'calibrador' ||
           r == 'inspector' ||
           r == 'operativo';
  }

  @override
  String toString() => 'UsuarioActual(id: $id, nombre: $nombre, rol: $rol, username: $username)';
}

class AuthService extends ChangeNotifier {
  // Opciones Android: modo de cifrado compatible con todos los dispositivos
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static UsuarioActual? _usuarioActual;

  /// Retorna los datos del usuario autenticado en la sesión actual
  static UsuarioActual? get usuarioActual {
    if (_usuarioActual != null) return _usuarioActual;
    final r = ApiService.instance.userRole;
    final n = ApiService.instance.lastNombre;
    final id = ApiService.instance.lastIdTecnico;
    if (r != null || n != null || id != null) {
      return UsuarioActual(
        id: id,
        nombre: n ?? 'Usuario',
        rol: r ?? 'tecnico',
        username: '',
      );
    }
    return null;
  }

  bool    _authenticated  = false;
  String? _username;
  String? _nombreCompleto;
  String? _role;
  bool    _isOfflineMode  = false;
  int?    _idTecnico;      // ID en cat_tecnicos — requerido para firma de perfil

  bool    get isAuthenticated  => _authenticated;
  String? get username         => _username;
  String? get nombreCompleto   => _nombreCompleto;
  String? get role             => _role;
  bool    get isOfflineMode    => _isOfflineMode;
  int?    get idTecnico        => _idTecnico;

  /// Normaliza cualquier variante de rol (con o sin acento, mayúsculas, etc.)
  static String normalizeRole(String? raw) {
    if (raw == null || raw.isEmpty) return 'tecnico';
    final r = raw.toLowerCase().trim()
        .replaceAll('é', 'e')
        .replaceAll('á', 'a')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u');
    if (r.contains('tec')) return 'tecnico';
    if (r.contains('admin')) return 'administrador';
    if (r.contains('recep')) return 'recepcion';
    if (r.contains('logist')) return 'logistica';
    return r;
  }

  /// Indica si el usuario es administrador
  bool get isAdmin {
    final r = normalizeRole(_role ?? usuarioActual?.rol);
    final u = (_username ?? usuarioActual?.username ?? '').toLowerCase().trim();
    return r == 'administrador' || r == 'admin' || u == 'ivancolin1207';
  }

  /// Indica si el usuario es técnico de campo
  bool get isTecnico {
    if (isAdmin) return false;
    if ((_username ?? '').toLowerCase().contains('daikki')) return true;
    final r = normalizeRole(_role);
    return r == 'tecnico' ||
           r == 'servicio' ||
           r == 'calibrador' ||
           r == 'inspector' ||
           r == 'operativo';
  }

  /// Supervisión metrológica: puede CONSULTAR (solo lectura) el repositorio de
  /// calibraciones concluidas de todos los técnicos. Alan Guevara (ID 8,
  /// Daikki19), administradores e ivancolin1207.
  bool get esSupervisorCalibracion => evaluarSupervisorCalibracion(
        username: _username ?? usuarioActual?.username,
        nombre:   _nombreCompleto ?? usuarioActual?.nombre,
        id:       _idTecnico ?? usuarioActual?.id,
        rol:      _role ?? usuarioActual?.rol,
      );

  /// Variante estática para servicios sin BuildContext (p.ej. SyncService).
  static bool get esSupervisorCalibracionActual {
    final u = usuarioActual;
    if (u == null) return false;
    return evaluarSupervisorCalibracion(
      username: u.username, nombre: u.nombre, id: u.id, rol: u.rol,
    );
  }

  static bool evaluarSupervisorCalibracion({
    String? username,
    String? nombre,
    int? id,
    String? rol,
  }) {
    final user = (username ?? '').toLowerCase().trim();
    final nom  = (nombre ?? '').toLowerCase().trim();
    final r    = normalizeRole(rol);
    return r == 'admin' ||
           r == 'administrador' ||
           nom.contains('alan guevara') ||
           nom.contains('ivan colin') ||
           nom.contains('iván colín') ||
           user == 'daikki19' ||
           user == 'ivancolin1207' ||
           id == 8;
  }

  String get displayName => _nombreCompleto?.isNotEmpty == true
      ? _nombreCompleto!
      : (_username ?? 'Usuario');

  String get initials {
    final name  = displayName;
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }

  Future<void> loadSession() async {
    await ApiService.instance.loadSavedToken();
    _authenticated = ApiService.instance.isAuthenticated;

    // Mantener la sesión activa indefinidamente mientras el usuario no pulse "Cerrar Sesión"
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionActive = prefs.getBool('pesa_session_active') ?? false;
      final savedUser = prefs.getString('pesa_username') ?? await _storage.read(key: 'pesa_username');
      if (!_authenticated && sessionActive && savedUser != null && savedUser.isNotEmpty) {
        _authenticated = true;
      }
    } catch (_) {}

    if (_authenticated) await _loadClaims();
    if (_authenticated && _username != null && _username!.isNotEmpty) {
      FirmaTecnicoService.instance.syncFirmaFromCloud(_username!, _idTecnico ?? 0);
    }
    // Seed siempre en background (no bloquea la UI)
    _seedDefaultCredentials();
    notifyListeners();
  }

  /// Renueva la sesión silenciosamente en segundo plano usando las credenciales guardadas.
  Future<bool> renovarSesionSilenciosa() => _renovarSesionSilenciosa();

  Future<bool> _renovarSesionSilenciosa() async {
    return ApiService.instance.renovarSesionSilenciosa();
  }

  static String? getDefaultPasswordForUser(String? usernameOrName) {
    if (usernameOrName == null || usernameOrName.trim().isEmpty) return null;
    final q = usernameOrName.trim().toLowerCase();
    for (final cred in _defaultOfflineUsers) {
      if (cred[0].toLowerCase() == q || cred[3].toLowerCase() == q) {
        return cred[1];
      }
    }
    return null;
  }

  static int? resolveKnownIdTecnico(String username) {
    final u = username.toLowerCase().trim();
    switch (u) {
      case 'daikki19':
      case 'alan.guevara':
        return 8;
      case 'nestor.arias':
        return 9;
      case 'alan.terrazas':
        return 10;
      case 'ivancolin1207':
        return 2;
      case 'jessica.colin':
        return 1;
      case 'fernando.arias':
        return 4;
      case 'alessandro.segovia':
        return 7;
      case 'adriana.arias':
        return 11;
      case 'jhonny.jimenez':
        return 44;
      case 'jose.landaverde':
        return 171;
      default:
        return null;
    }
  }

  Future<void> setSession(String username, String role,
      {String? nombreCompleto, bool offline = false, int? idTecnico}) async {
    _username       = username;
    _role           = normalizeRole(role);
    _nombreCompleto = nombreCompleto;
    _authenticated  = true;
    _isOfflineMode  = offline;
    _idTecnico      = idTecnico ?? resolveKnownIdTecnico(username);
    await _storage.write(key: 'pesa_username',       value: username);
    await _storage.write(key: 'pesa_role',           value: _role!);
    await _storage.write(key: 'pesa_cred_user',      value: username);
    if (nombreCompleto != null) {
      await _storage.write(key: 'pesa_nombre_completo', value: nombreCompleto);
    }
    if (_idTecnico != null) {
      await _storage.write(key: 'pesa_id_tecnico', value: _idTecnico.toString());
      await _storage.write(key: 'offline_id_tecnico_$username', value: _idTecnico.toString());
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pesa_session_active', true);
      await prefs.setString('pesa_username', username);
      await prefs.setString('pesa_cred_user', username);
      await prefs.setString('pesa_role', _role!);
      if (nombreCompleto != null) {
        await prefs.setString('pesa_nombre_completo', nombreCompleto);
      }
      if (_idTecnico != null) {
        await prefs.setInt('pesa_id_tecnico', _idTecnico!);
      }
      final fallbackPass = getDefaultPasswordForUser(username);
      if (fallbackPass != null && (prefs.getString('pesa_cred_pass') ?? '').isEmpty) {
        await prefs.setString('pesa_cred_pass', fallbackPass);
        await _storage.write(key: 'pesa_cred_pass', value: fallbackPass);
      }
    } catch (_) {}

    if (_username != null && _username!.isNotEmpty) {
      FirmaTecnicoService.instance.syncFirmaFromCloud(_username!, _idTecnico ?? 0);
    }
    _usuarioActual = UsuarioActual(
      id: _idTecnico,
      nombre: _nombreCompleto ?? username,
      rol: _role ?? 'tecnico',
      username: username,
    );
    notifyListeners();
  }

  /// Guarda las credenciales del usuario para login offline futuro y renovación silenciosa.
  /// Guarda AMBOS: el SHA-256 y el texto plano cifrado en SecureStorage y SharedPreferences.
  Future<void> saveOfflineCredentials(String username, String password, String role,
      {String? nombreCompleto}) async {
    final hash = sha256.convert(utf8.encode(password)).toString();
    await _storage.write(key: 'offline_hash_$username',   value: hash);
    await _storage.write(key: 'offline_plain_$username',  value: password);
    await _storage.write(key: 'offline_role_$username',   value: role);
    await _storage.write(key: 'pesa_cred_user',           value: username.trim());
    await _storage.write(key: 'pesa_cred_pass',           value: password.trim());
    if (nombreCompleto != null) {
      await _storage.write(key: 'offline_nombre_$username', value: nombreCompleto);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pesa_session_active', true);
      await prefs.setString('pesa_cred_user', username.trim());
      await prefs.setString('pesa_cred_pass', password.trim());
      await prefs.setString('offline_plain_$username', password.trim());
    } catch (_) {}
    debugPrint('[AuthService] Credenciales offline y de auto-login guardadas para: $username');
  }

  /// Login offline: acepta SHA-256 O texto plano (igual que el backend Python).
  /// [FIX v3.1.2] Fallback hardcoded: si SecureStorage falla (fresh install / Keystore reset),
  /// compara contra la lista embebida _defaultOfflineUsers para no bloquear al tecnico.
  Future<String?> loginOffline(String username, String password) async {
    // Siempre refrescar el seed antes de intentar
    await _seedDefaultCredentials();

    final storedHash  = await _storage.read(key: 'offline_hash_$username');
    final storedPlain = await _storage.read(key: 'offline_plain_$username');
    final inputHash   = sha256.convert(utf8.encode(password)).toString();

    // [FIX] Fallback hardcoded: si SecureStorage devuelve null (bug post-install en Android),
    // verificar contra la lista _defaultOfflineUsers embebida en el APK.
    final hardcoded = _defaultOfflineUsers.where(
      (c) => c[0].toLowerCase() == username.toLowerCase(),
    ).toList();
    bool hardcodedOk = false;
    String? hardcodedRole;
    String? hardcodedNombre;
    if (hardcoded.isNotEmpty) {
      final cred = hardcoded.first;
      hardcodedOk     = password == cred[1];  // plain match
      hardcodedRole   = cred[2];
      hardcodedNombre = cred[3];
    }

    if (storedHash == null && storedPlain == null && !hardcodedOk) {
      return 'Sin credenciales offline para "$username".\n'
             'Conecta la tablet a WiFi al menos una vez para guardarlas.';
    }

    final hashOk  = storedHash  != null && inputHash == storedHash;
    final plainOk = storedPlain != null && password  == storedPlain;

    if (!hashOk && !plainOk && !hardcodedOk) {
      return 'Contrasena incorrecta (modo offline).';
    }

    final role   = await _storage.read(key: 'offline_role_$username')
        ?? hardcodedRole ?? 'tecnico';
    final nombre = await _storage.read(key: 'offline_nombre_$username')
        ?? await _storage.read(key: 'pesa_nombre_completo')
        ?? hardcodedNombre;

    // Persistir credenciales para renovación silenciosa cuando regrese Wi-Fi
    await saveOfflineCredentials(username, password, role, nombreCompleto: nombre);

    final storedIdTec = await _storage.read(key: 'offline_id_tecnico_$username');
    final idTec = int.tryParse(storedIdTec ?? '') ?? resolveKnownIdTecnico(username);

    await setSession(username, role, nombreCompleto: nombre, offline: true, idTecnico: idTec);
    debugPrint('[AuthService] Login OFFLINE exitoso: $username | rol=$role | idTec=$idTec');
    return null;
  }

  // ── Catálogo oficial de usuarios con credenciales offline ─────────────────
  // [usuario, password_plano, role, nombre_completo]
  // IMPORTANTE: si una contraseña cambia en Render, actualizar aquí y rebuild.
  static const List<List<String>> _defaultOfflineUsers = [
    ['Daikki19',           '131019',   'tecnico',        'Alan Guevara'],
    ['alan.terrazas',      '131019',   'tecnico',        'Alan Terrazas'],
    ['ivancolin1207',      'Daikki19', 'administrador',  'Iván Colín'],
    ['adriana.arias',      '131019',   'recepcion',      'Adriana Arias'],
    ['alessandro.segovia', '131019',   'tecnico',        'Alessandro Segovia'],
    ['jose.landaverde',    '131019',   'tecnico',        'José Landaverde'],
    ['jhonny.jimenez',     '131019',   'tecnico',        'Jhonny Jiménez'],
    ['fernando.arias',     '131019',   'tecnico',        'Fernando Arias'],
    ['nestor.arias',       '131019',   'tecnico',        'Néstor Arias'],
  ];

  /// Siembra el catálogo completo usando delete-before-write para garantizar
  /// que los valores nuevos reemplacen cualquier hash anterior corrupto.
  Future<void> _seedDefaultCredentials() async {
    for (final cred in _defaultOfflineUsers) {
      final user  = cred[0];
      final plain = cred[1];
      final role  = cred[2];
      final name  = cred[3];
      final hash  = sha256.convert(utf8.encode(plain)).toString();

      // delete-before-write: evita que SecureStorage ignore escrituras si la
      // clave ya existe con cifrado distinto (bug conocido en Android).
      await _storage.delete(key: 'offline_hash_$user');
      await _storage.delete(key: 'offline_plain_$user');
      await _storage.delete(key: 'offline_role_$user');
      await _storage.delete(key: 'offline_nombre_$user');

      await _storage.write(key: 'offline_hash_$user',   value: hash);
      await _storage.write(key: 'offline_plain_$user',  value: plain);
      await _storage.write(key: 'offline_role_$user',   value: role);
      await _storage.write(key: 'offline_nombre_$user', value: name);
    }
    debugPrint('[AuthService] Seed v5 completado (${_defaultOfflineUsers.length} usuarios)');
  }

  Future<void> _loadClaims() async {
    final prefs     = await SharedPreferences.getInstance();
    _username       = await _storage.read(key: 'pesa_username') ?? prefs.getString('pesa_username');
    _role           = normalizeRole(await _storage.read(key: 'pesa_role') ?? prefs.getString('pesa_role'));
    _nombreCompleto = await _storage.read(key: 'pesa_nombre_completo') ?? prefs.getString('pesa_nombre_completo');
    final idTecStr  = await _storage.read(key: 'pesa_id_tecnico');
    if (idTecStr != null && idTecStr.isNotEmpty) {
      _idTecnico = int.tryParse(idTecStr);
    }
    _idTecnico ??= prefs.getInt('pesa_id_tecnico');
    try {
      final token = await _storage.read(key: 'jwt_token') ?? prefs.getString('jwt_token');
      if (token != null) {
        final parts = token.split('.');
        if (parts.length == 3) {
          final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
          final claims = jsonDecode(payload) as Map<String, dynamic>;
          _nombreCompleto ??= claims['nombre_completo'] as String?
              ?? claims['nombre'] as String?;
          if (_username == null) {
            _username = claims['username'] as String? ?? claims['user'] as String?;
          }
          _role = normalizeRole(claims['role'] as String? ?? _role);
          // [FIX] Leer 'id_tecnico' Y 'id' del JWT (ambos ahora presentes en el token)
          _idTecnico ??= int.tryParse(claims['id_tecnico']?.toString() ?? '');
          _idTecnico ??= int.tryParse(claims['id']?.toString() ?? '');
        }
      }
    } catch (e) {
      debugPrint('[AuthService] Error JWT claims: $e');
    }
    if (_idTecnico == null || _idTecnico == 0) {
      _idTecnico = resolveKnownIdTecnico(_username ?? '');
    }
    _usuarioActual = UsuarioActual(
      id: _idTecnico,
      nombre: _nombreCompleto ?? _username ?? '',
      rol: _role ?? 'tecnico',
      username: _username ?? '',
    );
    debugPrint('[AuthService] Sesión: $_nombreCompleto | $_username | $_role | idTec=$_idTecnico');
  }


  /// Consulta directamente si el técnico tiene firma registrada (en Render o localmente).
  Future<bool> verificarFirmaEnServidor() async {
    final user = _username ?? '';
    final idTec = _idTecnico ?? (user.toLowerCase() == 'daikki19' ? 8 : 0);
    if (user.isNotEmpty || idTec > 0) {
      final cloudFirma = await FirmaTecnicoService.instance.syncFirmaFromCloud(user, idTec);
      if (cloudFirma != null && cloudFirma.length > 50) return true;
    }
    if (idTec > 0) {
      try {
        final serverTiene = await ApiService.instance.verificarFirmaPerfil(idTec);
        if (serverTiene) {
          debugPrint('[AuthService] Servidor confirma que técnico id=$idTec tiene firma');
          return true;
        }
      } catch (e) {
        debugPrint('[AuthService] Error consultando firma en servidor: $e');
      }
    }
    // Verificación local persistente
    if (user.isNotEmpty) {
      final localTiene = await FirmaTecnicoService.instance.tieneFirma(user, idTecnico: idTec);
      if (localTiene) return true;
    }
    return false;
  }

  Future<void> logout() async {
    await ApiService.instance.logout();
    await _storage.delete(key: 'pesa_username');
    await _storage.delete(key: 'pesa_role');
    await _storage.delete(key: 'pesa_nombre_completo');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pesa_session_active', false);
    } catch (_) {}
    _authenticated  = false;
    _isOfflineMode  = false;
    _username       = null;
    _nombreCompleto = null;
    _role           = null;
    _usuarioActual  = null;
    notifyListeners();
  }
}
