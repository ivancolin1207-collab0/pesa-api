// lib/services/firma_tecnico_service.dart
// Servicio de firma persistente del técnico por sesión/usuario.
// La firma se captura UNA vez al iniciar sesión y queda guardada
// en SecureStorage local Y en archivo PNG físico en Documents.
// Cada OS reutiliza la firma almacenada sin volver a pedirla.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';   // Para saveAndSyncFirma → guardarFirmaPerfil

class FirmaTecnicoService {
  FirmaTecnicoService._();
  static final instance = FirmaTecnicoService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Clave de almacenamiento ───────────────────────────────────────────────
  String _keyFor(String username) => 'firma_tecnico_$username';

  /// Ruta del archivo PNG de firma persistente (sobrevive reinstalaciones)
  Future<File> _firmaFile(String username) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/pesa_firma_${username.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.png');
  }

  // ── Leer firma guardada ───────────────────────────────────────────────────
  /// Devuelve la firma en base64 del técnico [username], o null si no existe.
  /// Busca primero en SecureStorage, luego en archivo físico (migración).
  Future<String?> getFirma(String username) async {
    if (username.isEmpty) return null;
    // 1. Intentar SecureStorage
    try {
      final stored = await _storage.read(key: _keyFor(username));
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (e) {
      debugPrint('[FirmaTecnico] SecureStorage error al leer: $e');
    }
    // 2. Fallback: leer desde archivo PNG físico
    try {
      final file = await _firmaFile(username);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final b64 = base64Encode(bytes);
        // Restaurar en SecureStorage para la próxima vez
        try { await _storage.write(key: _keyFor(username), value: b64); } catch (_) {}
        debugPrint('[FirmaTecnico] Firma restaurada desde archivo físico para: $username');
        return b64;
      }
    } catch (e) {
      debugPrint('[FirmaTecnico] Error leyendo archivo firma: $e');
    }
    return null;
  }

  // ── Guardar firma ─────────────────────────────────────────────────────────
  /// Persiste la firma base64 del técnico en SecureStorage Y en archivo PNG.
  Future<void> saveFirma(String username, String firmaBase64) async {
    if (username.isEmpty || firmaBase64.isEmpty) return;
    // 1. Guardar en SecureStorage
    try {
      await _storage.write(key: _keyFor(username), value: firmaBase64);
      debugPrint('[FirmaTecnico] Firma guardada en SecureStorage para: $username');
    } catch (e) {
      debugPrint('[FirmaTecnico] Error en SecureStorage al guardar: $e');
    }
    // 2. Guardar como archivo PNG físico (persistencia dual)
    try {
      final bytes = base64Decode(firmaBase64);
      final file  = await _firmaFile(username);
      await file.writeAsBytes(bytes);
      debugPrint('[FirmaTecnico] Firma guardada como PNG en: ${file.path}');
    } catch (e) {
      debugPrint('[FirmaTecnico] Error guardando archivo PNG firma: $e');
    }
  }

  // ── Guardar firma local + sincronizar al servidor (v3.1) ─────────────────
  /// Guarda la firma localmente Y la sube al servidor para que Windows pueda
  /// verificarla en el login del técnico.
  /// [idTecnico] es el ID en cat_tecnicos (requerido para el endpoint de API).
  /// Retorna true si la sincronización al servidor fue exitosa.
  Future<bool> saveAndSyncFirma(
    String username,
    String firmaBase64,
    int idTecnico,
  ) async {
    // 1. Guardar localmente primero (funciona offline)
    await saveFirma(username, firmaBase64);
    // 2. Intentar sincronizar al servidor
    try {
      final ok = await ApiService.instance.guardarFirmaPerfil(idTecnico, firmaBase64);
      if (ok) {
        debugPrint('[FirmaTecnico] ✅ Firma sincronizada al servidor para id=$idTecnico');
      } else {
        debugPrint('[FirmaTecnico] ⚠️  Firma guardada localmente pero NO sincronizada al servidor');
      }
      return ok;
    } catch (e) {
      debugPrint('[FirmaTecnico] Error al sincronizar firma al servidor: $e');
      return false;
    }
  }

  // ── Eliminar firma ────────────────────────────────────────────────────────
  /// Elimina la firma del técnico (para permitir re-captura voluntaria).
  Future<void> deleteFirma(String username) async {
    if (username.isEmpty) return;
    try { await _storage.delete(key: _keyFor(username)); } catch (_) {}
    try {
      final file = await _firmaFile(username);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    debugPrint('[FirmaTecnico] Firma eliminada para: $username');
  }

  // ── ¿Tiene firma? ─────────────────────────────────────────────────────────
  Future<bool> tieneFirma(String username) async {
    final f = await getFirma(username);
    return f != null && f.isNotEmpty;
  }
}


