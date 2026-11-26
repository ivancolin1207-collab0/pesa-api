// lib/services/firma_tecnico_service.dart — Servicio de firma persistente del técnico
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class FirmaTecnicoService {
  FirmaTecnicoService._();
  static final instance = FirmaTecnicoService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String _keyFor(String username) => 'firma_tecnico_${username.trim().toLowerCase()}';
  String _legacyKeyFor(String username) => 'firma_tecnico_$username';

  static String limpiarBase64(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (s.contains(',')) {
      s = s.split(',').last.trim();
    }
    return s.replaceAll(RegExp(r'\s+'), '');
  }

  Future<File> _firmaFile(String username) async {
    final dir = await getApplicationDocumentsDirectory();
    final cleanUser = username.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return File('${dir.path}/pesa_firma_$cleanUser.png');
  }

  Future<File> _firmaFileById(int idTecnico) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/firmas_tecnicos');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File('${folder.path}/firma_$idTecnico.png');
  }

  Future<File> _firmaFileInFirmasFolder(int idTecnico) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/firmas');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File('${folder.path}/firma_$idTecnico.png');
  }

  // ── Leer firma guardada (SharedPreferences + SecureStorage + PNG local) ──
  Future<String?> getFirma(String username, {int idTecnico = 0}) async {
    if (username.isEmpty && idTecnico <= 0) return null;

    // 1. SharedPreferences (rápido y resistente a fallos de Keystore Android)
    try {
      final prefs = await SharedPreferences.getInstance();
      if (username.isNotEmpty) {
        final spUser = prefs.getString(_keyFor(username)) ?? prefs.getString(_legacyKeyFor(username));
        if (spUser != null && spUser.trim().length > 50) return limpiarBase64(spUser);
      }
      if (idTecnico > 0) {
        final spId = prefs.getString('firma_tecnico_id_$idTecnico');
        if (spId != null && spId.trim().length > 50) return limpiarBase64(spId);
      }
      final spGen = prefs.getString('tecnico_firma_base64');
      if (spGen != null && spGen.trim().length > 50) return limpiarBase64(spGen);
    } catch (_) {}

    // 2. SecureStorage por username
    if (username.isNotEmpty) {
      for (final k in [_keyFor(username), _legacyKeyFor(username)]) {
        try {
          final stored = await _storage.read(key: k);
          if (stored != null && stored.trim().length > 50) return limpiarBase64(stored);
        } catch (e) {
          debugPrint('[FirmaTecnico] SecureStorage error ($k): $e');
        }
      }
    }

    // 3. SecureStorage clave genérica
    try {
      final genStored = await _storage.read(key: 'tecnico_firma_base64');
      if (genStored != null && genStored.trim().length > 50) return limpiarBase64(genStored);
    } catch (_) {}

    // 4. Fallback: leer desde archivo PNG físico de idTecnico
    if (idTecnico > 0) {
      for (final loader in [_firmaFileById, _firmaFileInFirmasFolder]) {
        try {
          final file = await loader(idTecnico);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            if (bytes.length > 32) {
              final b64 = base64Encode(bytes);
              await _persistPrefsAndSecure(username, b64, idTecnico: idTecnico);
              return b64;
            }
          }
        } catch (e) {
          debugPrint('[FirmaTecnico] Error leyendo archivo por ID: $e');
        }
      }
    }

    // 5. Fallback: leer desde archivo PNG por username
    if (username.isNotEmpty) {
      try {
        final file = await _firmaFile(username);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.length > 32) {
            final b64 = base64Encode(bytes);
            await _persistPrefsAndSecure(username, b64, idTecnico: idTecnico);
            return b64;
          }
        }
      } catch (e) {
        debugPrint('[FirmaTecnico] Error leyendo archivo por username: $e');
      }
    }

    return null;
  }

  Future<void> _persistPrefsAndSecure(String username, String cleanB64, {int idTecnico = 0}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tecnico_firma_base64', cleanB64);
      if (username.isNotEmpty) {
        await prefs.setString(_keyFor(username), cleanB64);
        await prefs.setString(_legacyKeyFor(username), cleanB64);
      }
      if (idTecnico > 0) {
        await prefs.setString('firma_tecnico_id_$idTecnico', cleanB64);
      }
    } catch (_) {}

    try {
      await _storage.write(key: 'tecnico_firma_base64', value: cleanB64);
      if (username.isNotEmpty) {
        await _storage.write(key: _keyFor(username), value: cleanB64);
        await _storage.write(key: _legacyKeyFor(username), value: cleanB64);
      }
    } catch (e) {
      debugPrint('[FirmaTecnico] Error SecureStorage write: $e');
    }
  }

  // ── Guardar firma localmente (SharedPreferences + SecureStorage + PNG) ───
  Future<void> saveFirma(String username, String firmaBase64, {int idTecnico = 0}) async {
    final cleanB64 = limpiarBase64(firmaBase64);
    if (cleanB64.isEmpty) return;

    await _persistPrefsAndSecure(username, cleanB64, idTecnico: idTecnico);

    Uint8List? bytes;
    try {
      bytes = base64Decode(cleanB64);
    } catch (e) {
      debugPrint('[FirmaTecnico] Error decodificando Base64 al guardar PNG: $e');
      return;
    }

    if (username.isNotEmpty) {
      try {
        final file = await _firmaFile(username);
        await file.writeAsBytes(bytes, flush: true);
      } catch (e) {
        debugPrint('[FirmaTecnico] Error PNG username: $e');
      }
    }

    if (idTecnico > 0) {
      try {
        final fileId1 = await _firmaFileById(idTecnico);
        await fileId1.writeAsBytes(bytes, flush: true);
        final fileId2 = await _firmaFileInFirmasFolder(idTecnico);
        await fileId2.writeAsBytes(bytes, flush: true);
      } catch (e) {
        debugPrint('[FirmaTecnico] Error PNG idTecnico: $e');
      }
    }
  }

  // ── Sync desde la nube (PostgreSQL / Render) ─────────────────────────────
  Future<String?> syncFirmaFromCloud(String username, int idTecnico) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loginFirma = prefs.getString('firma_cloud_login') ?? await _storage.read(key: 'firma_cloud_login');
      if (loginFirma != null && loginFirma.trim().length > 50) {
        final clean = limpiarBase64(loginFirma);
        await saveFirma(username, clean, idTecnico: idTecnico);
        try { await prefs.remove('firma_cloud_login'); } catch (_) {}
        try { await _storage.delete(key: 'firma_cloud_login'); } catch (_) {}
        return clean;
      }
    } catch (_) {}

    try {
      final cloudB64 = await ApiService.instance.obtenerFirmaPerfil(idTecnico);
      if (cloudB64 != null && cloudB64.trim().length > 50) {
        final clean = limpiarBase64(cloudB64);
        await saveFirma(username, clean, idTecnico: idTecnico);
        debugPrint('[FirmaTecnico] ✅ Firma descargada del servidor para id=$idTecnico ($username)');
        return clean;
      }
    } catch (e) {
      debugPrint('[FirmaTecnico] Warning sync nube: $e');
    }

    return getFirma(username, idTecnico: idTecnico);
  }

  Future<bool> saveAndSyncFirma(
    String username,
    String firmaBase64,
    int idTecnico,
  ) async {
    final clean = limpiarBase64(firmaBase64);
    await saveFirma(username, clean, idTecnico: idTecnico);
    try {
      final savedServerB64 = await ApiService.instance.guardarFirmaPerfilConRespuesta(idTecnico, clean);
      if (savedServerB64.isNotEmpty) {
        await saveFirma(username, savedServerB64, idTecnico: idTecnico);
      }
      return true;
    } catch (e) {
      debugPrint('[FirmaTecnico] Error guardando firma en servidor: $e');
      return false;
    }
  }

  Future<void> deleteFirma(String username, {int idTecnico = 0}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('tecnico_firma_base64');
      if (username.isNotEmpty) {
        await prefs.remove(_keyFor(username));
        await prefs.remove(_legacyKeyFor(username));
      }
      if (idTecnico > 0) {
        await prefs.remove('firma_tecnico_id_$idTecnico');
      }
    } catch (_) {}
    if (username.isNotEmpty) {
      try { await _storage.delete(key: _keyFor(username)); } catch (_) {}
      try { await _storage.delete(key: _legacyKeyFor(username)); } catch (_) {}
    }
    try { await _storage.delete(key: 'tecnico_firma_base64'); } catch (_) {}
    if (username.isNotEmpty) {
      try {
        final file = await _firmaFile(username);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (idTecnico > 0) {
      try {
        final fileId1 = await _firmaFileById(idTecnico);
        if (await fileId1.exists()) await fileId1.delete();
        final fileId2 = await _firmaFileInFirmasFolder(idTecnico);
        if (await fileId2.exists()) await fileId2.delete();
      } catch (_) {}
    }
  }

  Future<bool> tieneFirma(String username, {int idTecnico = 0}) async {
    final f = await getFirma(username, idTecnico: idTecnico);
    return f != null && f.length > 50;
  }
}
