// lib/services/local_db_service.dart — SQLite offline-first
// Replica el esquema de PostgreSQL en el dispositivo Android.
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class LocalDbService {
  static final LocalDbService instance = LocalDbService._();
  LocalDbService._();
  Database? _db;

  // ── Schema — se aplica en onCreate / onUpgrade (ver método init()) ─────────
  // Las sentencias DDL se ejecutan individualmente para evitar problemas con
  // el split por ';' al incluir PRAGMA y comentarios SQL multilínea.

  // ── Inicializacion ────────────────────────────────────────────────────────

  String? lastUpsertError;

  static const _createTableOrdenesSql = '''
    CREATE TABLE IF NOT EXISTS ordenes_servicio (
      local_id               INTEGER PRIMARY KEY AUTOINCREMENT,
      folio_os               TEXT UNIQUE NOT NULL,
      estado                 TEXT DEFAULT 'PROCESO',
      modalidad              TEXT DEFAULT 'DIGITAL',
      fecha                  TEXT,
      cliente                TEXT,
      sucursal               TEXT,
      tecnico                TEXT,
      tipo_servicio          TEXT,
      tipo_instrumento       TEXT,
      aplica_excentricidad   INTEGER DEFAULT 1,
      num_celdas_camionera   INTEGER DEFAULT 0,
      clase_exactitud        TEXT,
      num_puntos_exactitud   INTEGER DEFAULT 10,
      observaciones          TEXT,
      rep_json               TEXT,
      exc_json               TEXT,
      exac_json              TEXT,
      firma_tecnico          TEXT,
      firma_cliente          TEXT,
      nombre_ing             TEXT,
      puesto_ing             TEXT,
      pdf_path_local         TEXT,
      pdf_url                TEXT,
      marca                  TEXT,
      modelo                 TEXT,
      ns                     TEXT,
      ubicacion              TEXT,
      id_equipo              TEXT,
      alcance_max            REAL,
      div_minima             REAL,
      div_verificacion       REAL,
      numero_cca             TEXT,
      holograma_anterior     TEXT,
      instrumento_capacidad  TEXT,
      instrumento_division   TEXT,
      secciones_camionera    INTEGER DEFAULT 0,
      num_secciones          INTEGER DEFAULT 0,
      unidad_medida          TEXT DEFAULT 'kg',
      firma_tecnico_descargada TEXT,
      pdf_b64_local          TEXT,
      id_lote                TEXT,
      rango_lote             TEXT,
      firma_cliente_nombre   TEXT,
      sync_version           INTEGER DEFAULT 0,
      sync_status            TEXT DEFAULT 'SINCRONIZADO',
      updated_at             TEXT
    )
  ''';

  // ── Inicializacion ────────────────────────────────────────────────────────

  Future<void> init() async {
    final dbPath = p.join(await getDatabasesPath(), 'pesa_local.db');
    _db = await openDatabase(
      dbPath,
      version: 10,   // v10: corrección crítica SQL INSTR y sanitización de tipos SQLite
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
        await db.execute(_createTableOrdenesSql);
        await db.execute('''
          CREATE TABLE IF NOT EXISTS firmas_pendientes (
            local_id      INTEGER PRIMARY KEY AUTOINCREMENT,
            folio_os      TEXT NOT NULL,
            firma_tecnico TEXT NOT NULL,
            firma_cliente TEXT NOT NULL,
            nombre_ing    TEXT,
            puesto_ing    TEXT,
            sincronizado  INTEGER DEFAULT 0
          )
        ''');
        final devId = _generateUuid();
        await db.insert('meta', {'key': 'device_id', 'value': devId});
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v10: DROP+CREATE garantiza esquema 100% limpio desde cualquier versión anterior
        if (oldVersion < 10) {
          await db.execute('DROP TABLE IF EXISTS ordenes_servicio');
          await db.execute(_createTableOrdenesSql);
          try {
            await db.insert('meta',
              {'key': 'last_sync_at', 'value': '2000-01-01T00:00:00.000Z'},
              conflictAlgorithm: ConflictAlgorithm.replace);
          } catch (_) {}
          return;
        }
      },
      onOpen: (db) async {
        // [FIX-DEFENSIVO] Verificar columnas requeridas y agregarlas si faltan
        try {
          final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
          final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
          final requiredCols = {
            'nombre_ing': 'TEXT',
            'puesto_ing': 'TEXT',
            'pdf_path_local': 'TEXT',
            'pdf_url': 'TEXT',
            'marca': 'TEXT',
            'modelo': 'TEXT',
            'ns': 'TEXT',
            'ubicacion': 'TEXT',
            'id_equipo': 'TEXT',
            'alcance_max': 'REAL',
            'div_minima': 'REAL',
            'div_verificacion': 'REAL',
            'numero_cca': 'TEXT',
            'holograma_anterior': 'TEXT',
            'instrumento_capacidad': 'TEXT',
            'instrumento_division': 'TEXT',
            'secciones_camionera': 'INTEGER DEFAULT 0',
            'num_secciones': 'INTEGER DEFAULT 0',
            'unidad_medida': "TEXT DEFAULT 'kg'",
            'firma_tecnico_descargada': 'TEXT',
            'pdf_b64_local': 'TEXT',
            'id_lote': 'TEXT',
            'rango_lote': 'TEXT',
            'firma_cliente_nombre': 'TEXT',
          };
          for (final entry in requiredCols.entries) {
            if (!existingCols.contains(entry.key.toLowerCase())) {
              try {
                await db.execute('ALTER TABLE ordenes_servicio ADD COLUMN ${entry.key} ${entry.value}');
                debugPrint('[LocalDB] Columna agregada defensivamente: ${entry.key}');
              } catch (e) {
                debugPrint('[LocalDB] Error agregando columna ${entry.key}: $e');
              }
            }
          }
        } catch (e) {
          debugPrint('[LocalDB] onOpen check error: $e');
        }
      },
    );
  }

  bool _initializing = false;

  /// Lazy init: abre la BD si aun no está lista.
  /// Seguro ante llamadas concurrentes (espera a que termine la primera).
  Future<Database> _ensureInit() async {
    if (_db != null) return _db!;
    while (_initializing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_db != null) return _db!;
    _initializing = true;
    try {
      await init();
    } finally {
      _initializing = false;
    }
    return _db!;
  }

  // ── CRUD OS ───────────────────────────────────────────────────────────────

  Future<bool> upsertOs(Map<String, dynamic> data) async {
    final folio = (data['folio_os'] as String? ?? '').trim();
    if (folio.isEmpty) {
      debugPrint('[LocalDB] upsertOs: folio_os vacío, saltando registro');
      return false;
    }

    final sucursal = (data['sucursal_nombre'] ?? data['sucursal'] ?? '').toString();
    final cliente  = (data['cliente'] ?? data['cliente_nombre'] ?? '').toString();
    final tecnico  = (data['tecnico'] ?? data['tecnico_nombre'] ?? '').toString();
    final tipoSvc  = (data['tipo_servicio'] ?? data['tipo_servicio_nombre'] ?? '').toString();

    final row = <String, dynamic>{
      'folio_os':          folio,
      'estado':            data['estado']?.toString() ?? 'PROCESO',
      'modalidad':         data['modalidad']?.toString() ?? 'DIGITAL',
      'fecha':             data['fecha']?.toString(),
      'cliente':           cliente,
      'sucursal':          sucursal,
      'tecnico':           tecnico,
      'tipo_servicio':     tipoSvc,
      'tipo_instrumento':  data['tipo_instrumento']?.toString(),
      // [FIX] aplica_excentricidad puede llegar como bool (JSON), int o String
      'aplica_excentricidad': _toBoolInt(data['aplica_excentricidad']),
      'num_celdas_camionera': _toInt(data['num_celdas_camionera'], 0),
      'clase_exactitud':   data['clase_exactitud_codigo']?.toString(),
      'observaciones':     data['observaciones']?.toString(),
      // ── Datos del instrumento ──────────────────────────────────────────────
      'marca':             data['marca']?.toString(),
      'modelo':            data['modelo']?.toString(),
      'ns':                (data['ns'] ?? data['serie'])?.toString(),
      'ubicacion':         data['ubicacion']?.toString(),
      'id_equipo':         data['id_equipo']?.toString(),
      'alcance_max':       _toDouble(data['alcance_max'] ?? data['capacidad_maxima']),
      'div_minima':        _toDouble(data['div_minima'] ?? data['division_minima']),
      'div_verificacion':  _toDouble(data['div_verificacion']),
      'numero_cca':        data['numero_cca']?.toString(),
      'holograma_anterior': data['holograma_anterior']?.toString(),
      'pdf_url':           data['pdf_url']?.toString(),
      // ── Campos precargados por logística ───────────────────────────────────
      'instrumento_capacidad': data['instrumento_capacidad']?.toString(),
      'instrumento_division':  data['instrumento_division']?.toString(),
      'secciones_camionera':   _toInt(data['secciones_camionera'] ?? data['num_celdas_camionera'], 0),
      'num_secciones':         _toInt(data['num_secciones'], 0),
      // Offline-First v2 + Lotes
      'unidad_medida':     data['unidad_medida']?.toString() ?? 'kg',
      'id_lote':           (data['id_lote'] ?? data['lote'])?.toString() ?? '',
      'rango_lote':        data['rango_lote']?.toString() ?? '',
      if (data['firma_tecnico_descargada'] != null)
        'firma_tecnico_descargada': data['firma_tecnico_descargada']?.toString(),
      // Sync
      'sync_version':      _toInt(data['sync_version'], 0),
      'sync_status':       'SINCRONIZADO',
      'updated_at':        data['updated_at']?.toString(),
    };

    try {
      final db = await _ensureInit();
      await db.insert(
        'ordenes_servicio',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      lastUpsertError = null;
      return true;
    } catch (e, st) {
      lastUpsertError = e.toString();
      debugPrint('[LocalDB] ERROR upsertOs folio=$folio: $e');
      debugPrint('[LocalDB] Stack: $st');
      // [FIX] Intentar insertar solo los campos seguros si el error es de tipo
      try {
        final db = await _ensureInit();
        final safeRow = Map<String, dynamic>.from(row)
          ..remove('alcance_max')
          ..remove('div_minima')
          ..remove('div_verificacion');
        await db.insert('ordenes_servicio', safeRow,
            conflictAlgorithm: ConflictAlgorithm.replace);
        debugPrint('[LocalDB] Fallback safe-insert OK para $folio');
        lastUpsertError = null;
        return true;
      } catch (e2) {
        lastUpsertError = e2.toString();
        debugPrint('[LocalDB] Fallback safe-insert también falló: $e2');
        return false;
      }
    }
  }

  /// Convierte cualquier representación de booleano a 0/1 para SQLite INTEGER.
  static int _toBoolInt(dynamic v) {
    if (v == null) return 1; // default: aplica
    if (v is bool) return v ? 1 : 0;
    if (v is int) return v != 0 ? 1 : 0;
    final s = v.toString().toLowerCase().trim();
    return (s == 'true' || s == '1' || s == 'yes') ? 1 : 0;
  }

  /// Convierte cualquier valor numérico a int de forma segura.
  static int _toInt(dynamic v, int defaultVal) {
    if (v == null) return defaultVal;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? defaultVal;
  }

  /// Convierte cualquier valor numérico a double de forma segura.
  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Borra TODAS las órdenes locales (usado antes de un pull completo).
  /// Retorna el número de filas eliminadas.
  Future<int> deleteAllOs() async {
    final db = await _ensureInit();
    return await db.delete('ordenes_servicio');
  }

  Future<List<Map<String, dynamic>>> getAllOs() async {
    final db = await _ensureInit();
    // Ordenar por local_id descendente (más recientes arriba) y fecha
    return await db.rawQuery(
      "SELECT * FROM ordenes_servicio ORDER BY local_id DESC, fecha DESC",
    );
  }

  /// Devuelve solo las órdenes asignadas al técnico por nombre completo.
  /// Si el nombre está vacío, devuelve TODAS (caso admin).
  /// [FIX] Ya no hace fallback a TODAS cuando matched=[] — antes ocultaba el bug.
  Future<List<Map<String, dynamic>>> getOsForTecnico(String nombreTecnico) async {
    final db = await _ensureInit();
    final rows = await db.rawQuery(
      "SELECT * FROM ordenes_servicio ORDER BY local_id DESC, fecha DESC",
    );
    final nombreLow = nombreTecnico.toLowerCase().trim();
    if (nombreLow.isEmpty) return rows;  // Sin nombre = admin, devuelve todo
    final words = nombreLow.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
    final matched = rows.where((r) {
      final tec = (r['tecnico'] as String? ?? '').toLowerCase().trim();
      if (tec.isEmpty) return false;
      if (tec.contains(nombreLow) || nombreLow.contains(tec)) return true;
      for (final w in words) {
        if (tec.contains(w)) return true;
      }
      return false;
    }).toList();
    // [FIX] Si matched está vacío, devolver lista vacía (no todas las órdenes).
    // La vista del dashboard mostrará 0 y el usuario puede sincronizar de nuevo.
    return matched;
  }

  Future<Map<String, dynamic>?> getOs(int localId) async {
    final db = await _ensureInit();
    final rows = await db.query(
      'ordenes_servicio',
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveLecturas({
    required int localId,
    required List repRows,
    required List excRows,
    required List exacRows,
    required String observaciones,
    String? dictamen,
    String? unidadMedida,
    String? firmaClienteNombre,   // nombre del receptor — obligatorio metrológico
  }) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {
        'rep_json':              jsonEncode(repRows),
        'exc_json':              jsonEncode(excRows),
        'exac_json':             jsonEncode(exacRows),
        'observaciones':         observaciones,
        'estado':                'COMPLETADA_DIGITAL',
        'unidad_medida':         unidadMedida ?? 'kg',
        'sync_status':           'PENDIENTE_ACTUALIZAR',
        'updated_at':            DateTime.now().toUtc().toIso8601String(),
        // firma_cliente_nombre existe en el esquema desde v8+
        if (firmaClienteNombre != null && firmaClienteNombre.isNotEmpty)
          'firma_cliente_nombre': firmaClienteNombre,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> savePdfPath(int localId, String path) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {
        'pdf_path_local': path,
        'estado': 'COMPLETADA_DIGITAL',
        'sync_status': 'PENDIENTE_ACTUALIZAR',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Consolida el cierre de una OS con PDF local y firmas en un solo UPDATE.
  /// Llamar justo después de generar el PDF.
  Future<void> saveOsCerrada({
    required int localId,
    required String pdfPathLocal,
    String? pdfB64,              // Base64 del PDF para subir al servidor
    String? firmaTecnico,
    String? firmaCliente,
    String? nombreIng,
    String? puestoIng,
  }) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {
        'pdf_path_local': pdfPathLocal,
        if (pdfB64 != null)       'pdf_b64_local':  pdfB64,
        if (firmaTecnico != null) 'firma_tecnico':  firmaTecnico,
        if (firmaCliente != null) 'firma_cliente':  firmaCliente,
        if (nombreIng != null)    'nombre_ing':     nombreIng,
        if (puestoIng != null)    'puesto_ing':     puestoIng,
        'estado':        'COMPLETADA_DIGITAL',
        'sync_status':   'PENDIENTE_ACTUALIZAR',
        'updated_at':    DateTime.now().toUtc().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Retorna la ruta local del PDF y el Base64 si existen.
  Future<Map<String, String?>> getPdfData(int localId) async {
    final db = await _ensureInit();
    final rows = await db.query(
      'ordenes_servicio',
      columns: ['pdf_path_local', 'pdf_b64_local'],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return {};
    return {
      'path':   rows.first['pdf_path_local'] as String?,
      'pdf_b64': rows.first['pdf_b64_local'] as String?,
    };
  }

  /// Retorna la firma del técnico guardada localmente (descargada en el Pull).
  Future<String?> getFirmaLocalTecnico(int localId) async {
    final db = await _ensureInit();
    final rows = await db.query(
      'ordenes_servicio',
      columns: ['firma_tecnico_descargada', 'firma_tecnico'],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    // Prioridad: firma descargada del servidor > firma capturada en campo
    return (rows.first['firma_tecnico_descargada'] as String?)
        ?? (rows.first['firma_tecnico'] as String?);
  }

  Future<void> saveFirmas({
    required int localId,
    required String folio,
    required String firmaTecBase64,
    required String firmaCliBase64,
    String nombreIng = '',
    String puestoIng = '',
  }) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {
        'firma_tecnico': firmaTecBase64,
        'firma_cliente': firmaCliBase64,
        'nombre_ing':    nombreIng,
        'puesto_ing':    puestoIng,
      },
      where: 'local_id = ?', whereArgs: [localId],
    );
    await db.insert('firmas_pendientes', {
      'folio_os':      folio,
      'firma_tecnico': firmaTecBase64,
      'firma_cliente': firmaCliBase64,
      'nombre_ing':    nombreIng,
      'puesto_ing':    puestoIng,
      'sincronizado':  0,
    });
  }

  Future<void> markOsSincronizada(int localId, int newVersion) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {'sync_status': 'SINCRONIZADO', 'sync_version': newVersion},
      where: 'local_id = ?', whereArgs: [localId],
    );
  }

  Future<void> markFirmaSincronizada(int localId) async {
    final db = await _ensureInit();
    await db.update(
      'firmas_pendientes',
      {'sincronizado': 1},
      where: 'local_id = ?', whereArgs: [localId],
    );
  }

  // ── Queries de sync ───────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getOsPendientes() async {
    final db = await _ensureInit();
    return await db.query(
      'ordenes_servicio',
      where: 'sync_status = ?',
      whereArgs: ['PENDIENTE_ACTUALIZAR'],
    );
  }

  Future<List<Map<String, dynamic>>> getFirmasPendientes() async {
    final db = await _ensureInit();
    return await db.query(
      'firmas_pendientes',
      where: 'sincronizado = 0',
    );
  }

  Future<int> getPendingCount() async {
    final db = await _ensureInit();
    final r = await db.rawQuery(
      "SELECT COUNT(*) as c FROM ordenes_servicio WHERE sync_status = 'PENDIENTE_ACTUALIZAR'"
    );
    return (r.first['c'] as int?) ?? 0;
  }

  // ── Meta (last_sync, device_id) ───────────────────────────────────────────

  Future<DateTime?> getLastSyncTime() async {
    final db = await _ensureInit();
    final rows = await db.query(
      'meta', where: "key = 'last_sync'", limit: 1,
    );
    if (rows.isEmpty) return null;
    return DateTime.tryParse(rows.first['value'] as String? ?? '');
  }

  Future<void> setLastSyncTime(DateTime dt) async {
    final db = await _ensureInit();
    await db.insert(
      'meta',
      {'key': 'last_sync', 'value': dt.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> getDeviceId() async {
    final db = await _ensureInit();
    final rows = await db.query(
      'meta', where: "key = 'device_id'", limit: 1,
    );
    return rows.isEmpty ? 'UNKNOWN' : (rows.first['value'] as String? ?? 'UNKNOWN');
  }



  // ── UUID v4 simple ────────────────────────────────────────────────────────

  static String _generateUuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0,8)}-${hex.substring(8,12)}'
        '-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}';
  }
}