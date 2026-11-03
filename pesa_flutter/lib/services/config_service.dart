// lib/services/config_service.dart
// Gestiona la configuracion persistente de la app (URL del servidor, timeout, etc.)
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ConfigService {
  static final ConfigService instance = ConfigService._();
  ConfigService._();

  static const _storage = FlutterSecureStorage();
  static const _kServerUrl   = 'server_url';
  static const _kConnTimeout = 'conn_timeout_sec';
  static const _kSyncTimeout = 'sync_timeout_sec';

  static const defaultServerUrl   = 'https://pesa-api-za9i.onrender.com';
  static const defaultConnTimeout = 90;   // Render: toleramos hasta 90s de cold-start
  static const defaultSyncTimeout = 120;

  Future<String> getServerUrl() async {
    final saved = await _storage.read(key: _kServerUrl);
    if (saved == null || saved.trim().isEmpty) {
      // Primera ejecución: persistir el default para que quede precargado
      await _storage.write(key: _kServerUrl, value: defaultServerUrl);
      return defaultServerUrl;
    }
    return saved.trim();
  }

  Future<int> getConnTimeout() async {
    final s = await _storage.read(key: _kConnTimeout);
    return int.tryParse(s ?? '') ?? defaultConnTimeout;
  }

  Future<int> getSyncTimeout() async {
    final s = await _storage.read(key: _kSyncTimeout);
    return int.tryParse(s ?? '') ?? defaultSyncTimeout;
  }

  Future<void> setServerUrl(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _storage.write(key: _kServerUrl, value: clean);
  }

  Future<void> setConnTimeout(int seconds) async =>
      _storage.write(key: _kConnTimeout, value: seconds.toString());

  Future<void> setSyncTimeout(int seconds) async =>
      _storage.write(key: _kSyncTimeout, value: seconds.toString());

  Future<void> resetToDefaults() async {
    await _storage.write(key: _kServerUrl,   value: defaultServerUrl);
    await _storage.write(key: _kConnTimeout, value: defaultConnTimeout.toString());
    await _storage.write(key: _kSyncTimeout, value: defaultSyncTimeout.toString());
  }
}
