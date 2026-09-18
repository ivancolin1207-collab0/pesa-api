// lib/services/auth_service.dart
// v5: Login offline dual (SHA-256 + texto plano) + seed forzado con delete-before-write
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_service.dart';

class AuthService extends ChangeNotifier {
  // Opciones Android: modo de cifrado compatible con todos los dispositivos
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  bool    _authenticated  = false;
  String? _username;
  String? _nombreCompleto;
  String? _role;
  bool    _isOfflineMode  = false;

  bool    get isAuthenticated  => _authenticated;
  String? get username         => _username;
  String? get nombreCompleto   => _nombreCompleto;
  String? get role             => _role;
  bool    get isOfflineMode    => _isOfflineMode;

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
    if (_authenticated) await _loadClaims();
    // Seed siempre en background (no bloquea la UI)
    _seedDefaultCredentials();
    notifyListeners();
  }

  Future<void> setSession(String username, String role,
      {String? nombreCompleto, bool offline = false}) async {
    _username       = username;
    _role           = role;
    _nombreCompleto = nombreCompleto;
    _authenticated  = true;
    _isOfflineMode  = offline;
    await _storage.write(key: 'pesa_username',       value: username);
    await _storage.write(key: 'pesa_role',           value: role);
    if (nombreCompleto != null) {
      await _storage.write(key: 'pesa_nombre_completo', value: nombreCompleto);
    }
    notifyListeners();
  }

  /// Guarda las credenciales del usuario para login offline futuro.
  /// Guarda AMBOS: el SHA-256 y el texto plano cifrado (para compatibilidad).
  Future<void> saveOfflineCredentials(String username, String password, String role,
      {String? nombreCompleto}) async {
    final hash = sha256.convert(utf8.encode(password)).toString();
    await _storage.write(key: 'offline_hash_$username',   value: hash);
    await _storage.write(key: 'offline_plain_$username',  value: password);
    await _storage.write(key: 'offline_role_$username',   value: role);
    if (nombreCompleto != null) {
      await _storage.write(key: 'offline_nombre_$username', value: nombreCompleto);
    }
    debugPrint('[AuthService] Credenciales offline guardadas para: $username');
  }

  /// Login offline: acepta SHA-256 O texto plano (igual que el backend Python).
  /// Esto garantiza compatibilidad con hashes que puedan estar en distintos formatos.
  Future<String?> loginOffline(String username, String password) async {
    // Siempre refrescar el seed antes de intentar
    await _seedDefaultCredentials();

    final storedHash  = await _storage.read(key: 'offline_hash_$username');
    final storedPlain = await _storage.read(key: 'offline_plain_$username');

    if (storedHash == null && storedPlain == null) {
      return 'Sin credenciales offline para "$username".\n'
             'Conéctate al servidor al menos una vez para guardarlas.';
    }

    final inputHash = sha256.convert(utf8.encode(password)).toString();
    final hashOk    = storedHash  != null && inputHash == storedHash;
    final plainOk   = storedPlain != null && password  == storedPlain;

    if (!hashOk && !plainOk) {
      return 'Contraseña incorrecta (modo offline).';
    }

    final role   = await _storage.read(key: 'offline_role_$username')   ?? 'tecnico';
    final nombre = await _storage.read(key: 'offline_nombre_$username')
        ?? await _storage.read(key: 'pesa_nombre_completo');
    await setSession(username, role, nombreCompleto: nombre, offline: true);
    debugPrint('[AuthService] Login OFFLINE exitoso: $username | rol=$role');
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
    _username       = await _storage.read(key: 'pesa_username');
    _role           = await _storage.read(key: 'pesa_role');
    _nombreCompleto = await _storage.read(key: 'pesa_nombre_completo');
    if (_nombreCompleto == null) {
      try {
        final token = await _storage.read(key: 'jwt_token');
        if (token != null) {
          final parts = token.split('.');
          if (parts.length == 3) {
            final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
            final claims = jsonDecode(payload) as Map<String, dynamic>;
            _nombreCompleto = claims['nombre_completo'] as String?
                ?? claims['nombre'] as String?;
            if (_username == null) {
              _username = claims['username'] as String? ?? claims['user'] as String?;
            }
            _role ??= claims['role'] as String?;
          }
        }
      } catch (e) {
        debugPrint('[AuthService] Error JWT claims: $e');
      }
    }
    debugPrint('[AuthService] Sesion: $_nombreCompleto | $_username | $_role');
  }

  Future<void> logout() async {
    await ApiService.instance.logout();
    await _storage.delete(key: 'pesa_username');
    await _storage.delete(key: 'pesa_role');
    await _storage.delete(key: 'pesa_nombre_completo');
    _authenticated  = false;
    _isOfflineMode  = false;
    _username       = null;
    _nombreCompleto = null;
    _role           = null;
    notifyListeners();
  }
}
