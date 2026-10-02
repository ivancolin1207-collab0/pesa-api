// lib/services/firma_tecnico_service.dart — Servicio de firma persistente del técnico
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

class FirmaTecnicoService {
  FirmaTecnicoService._();
  static final instance = FirmaTecnicoService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String _keyFor(String username) => 'firma_tecnico_$username';

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

  // ── Leer firma guardada ───────────────────────────────────────────────────
  Future<String?> getFirma(String username, {int idTecnico = 0}) async {
    if (username.isEmpty && idTecnico <= 0) return null;

    // 1. Intentar SecureStorage por username
    if (username.isNotEmpty) {
      try {
        final stored = await _storage.read(key: _keyFor(username));
        if (stored != null && stored.trim().length > 50) return stored.trim();
      } catch (e) {
        debugPrint('[FirmaTecnico] SecureStorage error: $e');
      }
    }

    // 2. Intentar SecureStorage por clave genérica
    try {
      final genStored = await _storage.read(key: 'tecnico_firma_base64');
      if (genStored != null && genStored.trim().length > 50) return genStored.trim();
    } catch (_) {}

    // 3. Fallback: leer desde archivo PNG físico de idTecnico
    if (idTecnico > 0) {
      try {
        final file = await _firmaFileById(idTecnico);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final b64 = base64Encode(bytes);
          if (username.isNotEmpty) {
            try { await _storage.write(key: _keyFor(username), value: b64); } catch (_) {}
          }
          return b64;
        }
      } catch (e) {
        debugPrint('[FirmaTecnico] Error leyendo archivo por ID: $e');
      }

      try {
        final fileAlt = await _firmaFileInFirmasFolder(idTecnico);
        if (await fileAlt.exists()) {
          final bytes = await fileAlt.readAsBytes();
          final b64 = base64Encode(bytes);
          if (username.isNotEmpty) {
            try { await _storage.write(key: _keyFor(username), value: b64); } catch (_) {}
          }
          return b64;
        }
      } catch (_) {}
    }

    // 4. Fallback: leer desde archivo PNG por username
    if (username.isNotEmpty) {
      try {
        final file = await _firmaFile(username);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final b64 = base64Encode(bytes);
          try { await _storage.write(key: _keyFor(username), value: b64); } catch (_) {}
          return b64;
        }
      } catch (e) {
        debugPrint('[FirmaTecnico] Error leyendo archivo por username: $e');
      }
    }

    return null;
  }

  // ── Guardar firma ─────────────────────────────────────────────────────────
  Future<void> saveFirma(String username, String firmaBase64, {int idTecnico = 0}) async {
    final cleanB64 = firmaBase64.contains(',') ? firmaBase64.split(',').last.trim() : firmaBase64.trim();
    if (cleanB64.isEmpty) return;

    // 1. SecureStorage
    if (username.isNotEmpty) {
      try {
        await _storage.write(key: _keyFor(username), value: cleanB64);
        await _storage.write(key: 'tecnico_firma_base64', value: cleanB64);
      } catch (e) {
        debugPrint('[FirmaTecnico] Error SecureStorage: $e');
      }
    }

    // 2. PNG por username
    if (username.isNotEmpty) {
      try {
        final bytes = base64Decode(cleanB64);
        final file = await _firmaFile(username);
        await file.writeAsBytes(bytes);
      } catch (e) {
        debugPrint('[FirmaTecnico] Error PNG username: $e');
      }
    }

    // 3. PNG por idTecnico en ambas carpetas (/firmas_tecnicos y /firmas)
    if (idTecnico > 0) {
      try {
        final bytes = base64Decode(cleanB64);
        final fileId1 = await _firmaFileById(idTecnico);
        await fileId1.writeAsBytes(bytes);
        final fileId2 = await _firmaFileInFirmasFolder(idTecnico);
        await fileId2.writeAsBytes(bytes);
      } catch (e) {
        debugPrint('[FirmaTecnico] Error PNG idTecnico: $e');
      }
    }
  }

  // ── Sync desde la nube ─────────────────────────────────────────────────────
  Future<String?> syncFirmaFromCloud(String username, int idTecnico) async {
    try {
      final loginFirma = await _storage.read(key: 'firma_cloud_login');
      if (loginFirma != null && loginFirma.trim().length > 50) {
        final clean = loginFirma.trim();
        await saveFirma(username, clean, idTecnico: idTecnico);
        await _storage.delete(key: 'firma_cloud_login');
        return clean;
      }
    } catch (_) {}

    if (idTecnico > 0) {
      try {
        final cloudB64 = await ApiService.instance.obtenerFirmaPerfil(idTecnico);
        if (cloudB64 != null && cloudB64.trim().length > 50) {
          final clean = cloudB64.trim();
          await saveFirma(username, clean, idTecnico: idTecnico);
          debugPrint('[FirmaTecnico] ✅ Firma descargada del servidor para id=$idTecnico ($username)');
          return clean;
        }
      } catch (e) {
        debugPrint('[FirmaTecnico] Warning sync nube: $e');
      }
    }

    return getFirma(username, idTecnico: idTecnico);
  }

  Future<bool> saveAndSyncFirma(
    String username,
    String firmaBase64,
    int idTecnico,
  ) async {
    await saveFirma(username, firmaBase64, idTecnico: idTecnico);
    if (idTecnico > 0) {
      try {
        final ok = await ApiService.instance.guardarFirmaPerfil(idTecnico, firmaBase64);
        return ok;
      } catch (e) {
        debugPrint('[FirmaTecnico] Error guardando firma en servidor: $e');
        return false;
      }
    }
    return true;
  }

  Future<void> deleteFirma(String username, {int idTecnico = 0}) async {
    if (username.isEmpty) return;
    try { await _storage.delete(key: _keyFor(username)); } catch (_) {}
    try { await _storage.delete(key: 'tecnico_firma_base64'); } catch (_) {}
    try {
      final file = await _firmaFile(username);
      if (await file.exists()) await file.delete();
    } catch (_) {}
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
