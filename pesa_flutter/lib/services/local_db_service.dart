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
      id_tecnico             INTEGER,
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
      holograma_actualizado  TEXT,
      funcionamiento         TEXT,
      puntos_apoyo           INTEGER DEFAULT 4,
      usa_sustitucion        INTEGER DEFAULT 0,
      masa_patron_disponible REAL,
      factor_sustitucion     REAL,
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
      pdf_subido             INTEGER DEFAULT 0,
      sync_check_status      TEXT DEFAULT 'ASIGNADA',
      fecha_descarga_tablet  TEXT,
      fecha_subida_servidor  TEXT,
      fecha_apertura_admin   TEXT,
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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS contactos_planta (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            cliente         TEXT NOT NULL,
            planta          TEXT NOT NULL,
            nombre_contacto TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            UNIQUE(cliente, planta, nombre_contacto) ON CONFLICT REPLACE
          )
        ''');
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_contactos_planta_cli_pla ON contactos_planta(cliente, planta)
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
            'id_tecnico': 'INTEGER',
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
            'holograma_actualizado': 'TEXT',
            'funcionamiento': 'TEXT',
            'puntos_apoyo': 'INTEGER DEFAULT 4',
            'usa_sustitucion': 'INTEGER DEFAULT 0',
            'masa_patron_disponible': 'REAL',
            'factor_sustitucion': 'REAL',
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
            'direccion': 'TEXT',
            'calibrado_por': 'TEXT',
            'cca_aplica': 'INTEGER DEFAULT 0',
            'pdf_subido': 'INTEGER DEFAULT 0',
            'sync_check_status': "TEXT DEFAULT 'ASIGNADA'",
            'fecha_descarga_tablet': 'TEXT',
            'fecha_subida_servidor': 'TEXT',
            'fecha_apertura_admin': 'TEXT',
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

          // Backfill de id_tecnico en ordenes_servicio si está en NULL
          try {
            final tecnicosMap = {
              'alan guevara': 8,
              'nestor arias': 9,
              'néstor arias': 9,
              'alan terrazas': 10,
              'iván colín': 2,
              'ivan colin': 2,
              'fernando arias': 4,
              'alessandro segovia': 7,
              'adriana arias': 11,
              'jhonny jimenez': 44,
              'jhonny jiménez': 44,
              'josé landaverde': 171,
              'jose landaverde': 171,
            };
            for (final entry in tecnicosMap.entries) {
              await db.rawUpdate(
                'UPDATE ordenes_servicio SET id_tecnico = ? WHERE id_tecnico IS NULL AND LOWER(tecnico) LIKE ?',
                [entry.value, '%${entry.key}%'],
              );
            }
          } catch (e) {
            debugPrint('[LocalDB] Backfill id_tecnico error: $e');
          }
        } catch (e) {
          debugPrint('[LocalDB] onOpen check error: $e');
        }

        // [CONTACTOS PLANTA] Asegurar tabla e indexar firmantes históricos de ordenes_servicio
        try {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS contactos_planta (
              id              INTEGER PRIMARY KEY AUTOINCREMENT,
              cliente         TEXT NOT NULL,
              planta          TEXT NOT NULL,
              nombre_contacto TEXT NOT NULL,
              updated_at      TEXT NOT NULL,
              UNIQUE(cliente, planta, nombre_contacto) ON CONFLICT REPLACE
            )
          ''');
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_contactos_planta_cli_pla ON contactos_planta(cliente, planta)
          ''');
          await db.execute('''
            INSERT OR IGNORE INTO contactos_planta (cliente, planta, nombre_contacto, updated_at)
            SELECT DISTINCT 
              TRIM(cliente), 
              COALESCE(NULLIF(TRIM(direccion), ''), TRIM(sucursal), ''), 
              TRIM(firma_cliente_nombre), 
              COALESCE(updated_at, datetime('now'))
            FROM ordenes_servicio 
            WHERE firma_cliente_nombre IS NOT NULL 
              AND TRIM(firma_cliente_nombre) != ''
              AND cliente IS NOT NULL 
              AND TRIM(cliente) != ''
          ''');
          await db.execute('''
            INSERT OR IGNORE INTO contactos_planta (cliente, planta, nombre_contacto, updated_at)
            SELECT DISTINCT 
              TRIM(cliente), 
              COALESCE(NULLIF(TRIM(direccion), ''), TRIM(sucursal), ''), 
              TRIM(nombre_ing), 
              COALESCE(updated_at, datetime('now'))
            FROM ordenes_servicio 
            WHERE nombre_ing IS NOT NULL 
              AND TRIM(nombre_ing) != ''
              AND cliente IS NOT NULL 
              AND TRIM(cliente) != ''
          ''');
        } catch (e) {
          debugPrint('[LocalDB] contactos_planta setup error: $e');
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
    final direccion = (data['direccion'] ?? data['direccion_cliente'] ?? data['sucursal_direccion'] ?? data['planta'] ?? '').toString();

    final rawIdTec = _toIntOrNull(data['id_tecnico'] ?? data['tecnico_id']);
    int? idTecnicoFinal = rawIdTec;
    if (idTecnicoFinal == null || idTecnicoFinal <= 0) {
      final tecLow = tecnico.toLowerCase();
      if (tecLow.contains('nestor') || tecLow.contains('néstor')) idTecnicoFinal = 9;
      else if (tecLow.contains('terrazas')) idTecnicoFinal = 10;
      else if (tecLow.contains('guevara') || tecLow.contains('daikki')) idTecnicoFinal = 8;
      else if (tecLow.contains('fernando')) idTecnicoFinal = 4;
      else if (tecLow.contains('segovia') || tecLow.contains('alessandro')) idTecnicoFinal = 7;
      else if (tecLow.contains('jimenez') || tecLow.contains('jiménez') || tecLow.contains('jhonny')) idTecnicoFinal = 44;
      else if (tecLow.contains('landaverde')) idTecnicoFinal = 171;
      else if (tecLow.contains('adriana')) idTecnicoFinal = 11;
      else if (tecLow.contains('jessica')) idTecnicoFinal = 1;
      else if (tecLow.contains('iván') || tecLow.contains('ivan')) idTecnicoFinal = 2;
    }

    final row = <String, dynamic>{
      'folio_os':          folio,
      'id_tecnico':        idTecnicoFinal,
      'estado':            data['estado']?.toString() ?? 'PROCESO',
      'modalidad':         data['modalidad']?.toString() ?? 'DIGITAL',
      'fecha':             data['fecha']?.toString(),
      'cliente':           cliente,
      'sucursal':          sucursal,
      'direccion':         direccion,
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
      // Sync & Trazabilidad
      'sync_check_status': (data['sync_check_status'] as String?)?.isNotEmpty == true
          ? data['sync_check_status'].toString()
          : 'RECIBIDA_TABLET',
      if (data['fecha_descarga_tablet'] != null)
        'fecha_descarga_tablet': data['fecha_descarga_tablet']?.toString(),
      if (data['fecha_subida_servidor'] != null)
        'fecha_subida_servidor': data['fecha_subida_servidor']?.toString(),
      if (data['fecha_apertura_admin'] != null)
        'fecha_apertura_admin': data['fecha_apertura_admin']?.toString(),
      'sync_version':      _toInt(data['sync_version'], 0),
      'sync_status':       'SINCRONIZADO',
      'updated_at':        data['updated_at']?.toString(),
    };

    try {
      final db = await _ensureInit();
      // [FIX-OFFLINE-PDF] Preservar rutas de PDF locales y estado de subida
      final existingRows = await db.query(
        'ordenes_servicio',
        columns: ['pdf_path_local', 'pdf_b64_local', 'pdf_subido', 'sync_check_status'],
        where: 'folio_os = ?',
        whereArgs: [folio],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        final ex = existingRows.first;
        if (row['pdf_path_local'] == null && ex['pdf_path_local'] != null) {
          row['pdf_path_local'] = ex['pdf_path_local'];
        }
        if (row['pdf_b64_local'] == null && ex['pdf_b64_local'] != null) {
          row['pdf_b64_local'] = ex['pdf_b64_local'];
        }
        if (ex['pdf_subido'] != null) {
          row['pdf_subido'] = ex['pdf_subido'];
        }
        if (ex['sync_check_status'] != null) {
          final localSt = ex['sync_check_status'].toString();
          final srvSt   = row['sync_check_status']?.toString();
          // Si el servidor reporta AUDITADA_ADMIN, gana el servidor.
          // De lo contrario, si localmente ya se subió (SUBIDA_SERVIDOR), no degradar.
          if (srvSt != 'AUDITADA_ADMIN' && (localSt == 'SUBIDA_SERVIDOR' || localSt == 'AUDITADA_ADMIN')) {
            row['sync_check_status'] = localSt;
          }
        }
      }

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

  /// Convierte cualquier valor numérico a int de forma segura o retorna null.
  static int? _toIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
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

  /// Devuelve solo las órdenes asignadas al técnico por ID y nombre.
  /// Si es admin (idTecnico == null y nombreTecnico vacío), devuelve TODAS.
  Future<List<Map<String, dynamic>>> getOsForTecnico({
    String? nombreTecnico,
    int? idTecnico,
  }) async {
    final db = await _ensureInit();
    final nombreLow = (nombreTecnico ?? '').toLowerCase().trim();

    // Admin: devuelve todas
    if ((idTecnico == null || idTecnico <= 0) && nombreLow.isEmpty) {
      return await db.rawQuery(
        "SELECT * FROM ordenes_servicio ORDER BY local_id DESC, fecha DESC",
      );
    }

    // Filtrar estrictamente por id_tecnico si está disponible
    if (idTecnico != null && idTecnico > 0) {
      final rows = await db.rawQuery(
        """
        SELECT * FROM ordenes_servicio 
        WHERE id_tecnico = ? 
           OR (id_tecnico IS NULL AND LOWER(tecnico) LIKE ?)
        ORDER BY local_id DESC, fecha DESC
        """,
        [idTecnico, '%$nombreLow%'],
      );
      return rows;
    }

    // Fallback por nombre
    final all = await db.rawQuery(
      "SELECT * FROM ordenes_servicio ORDER BY local_id DESC, fecha DESC",
    );
    final words = nombreLow.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
    return all.where((r) {
      final tec = (r['tecnico'] as String? ?? '').toLowerCase().trim();
      if (tec.isEmpty) return false;
      if (tec.contains(nombreLow) || nombreLow.contains(tec)) return true;
      for (final w in words) {
        if (tec.contains(w)) return true;
      }
      return false;
    }).toList();
  }

  /// Purga órdenes locales que pertenezcan a otros técnicos (para garantizar privacidad y filtrado estricto).
  /// Si el usuario es Administrador (isAdmin == true), NO se borra nada.
  /// Si el usuario es Técnico, se eliminan todas las órdenes cuyo id_tecnico sea distinto al suyo,
  /// o cuyo nombre de técnico corresponda a otro usuario.
  Future<int> purgarOrdenesDeOtrosTecnicos({
    required int? currentIdTecnico,
    required String? currentNombre,
    required bool isAdmin,
  }) async {
    if (isAdmin) return 0;
    if ((currentIdTecnico == null || currentIdTecnico <= 0) &&
        (currentNombre == null || currentNombre.trim().isEmpty)) {
      return 0;
    }
    final db = await _ensureInit();
    int totalEliminadas = 0;

    try {
      // 1. Si tenemos id_tecnico, borrar cualquier orden con id_tecnico != currentIdTecnico
      if (currentIdTecnico != null && currentIdTecnico > 0) {
        final count = await db.delete(
          'ordenes_servicio',
          where: 'id_tecnico IS NOT NULL AND id_tecnico != ?',
          whereArgs: [currentIdTecnico],
        );
        totalEliminadas += count;
        if (count > 0) {
          debugPrint('[LocalDB] Purga id_tecnico != $currentIdTecnico: $count órdenes eliminadas de otros técnicos');
        }
      }

      // 2. Para órdenes donde id_tecnico IS NULL, revisar el nombre del técnico
      if (currentNombre != null && currentNombre.trim().isNotEmpty) {
        final nombreLow = currentNombre.toLowerCase().trim();
        final rows = await db.query(
          'ordenes_servicio',
          columns: ['local_id', 'folio_os', 'tecnico'],
          where: 'id_tecnico IS NULL',
        );

        for (final r in rows) {
          final tec = (r['tecnico'] as String? ?? '').toLowerCase().trim();
          final localId = r['local_id'] as int;
          // Si tiene técnico y NO coincide con el usuario actual, borrar
          if (tec.isNotEmpty && !tec.contains(nombreLow) && !nombreLow.contains(tec)) {
            await db.delete('ordenes_servicio', where: 'local_id = ?', whereArgs: [localId]);
            totalEliminadas++;
          }
        }
      }
    } catch (e) {
      debugPrint('[LocalDB] Error purgando órdenes ajenas: $e');
    }
    return totalEliminadas;
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

  Future<Map<String, dynamic>?> getOsByFolio(String folio) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return null;
    final db = await _ensureInit();
    final rows = await db.query(
      'ordenes_servicio',
      where: 'folio_os = ?',
      whereArgs: [folioKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // ── Almacenamiento local indexado de Borradores (Offline-First) ───────────

  Future<void> saveDraft(String folio, Map<String, dynamic> draftData) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.execute('''
        CREATE TABLE IF NOT EXISTS borradores_captura (
          folio_os TEXT PRIMARY KEY,
          draft_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.insert(
        'borradores_captura',
        {
          'folio_os': folioKey,
          'draft_json': jsonEncode(draftData),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint('[LocalDB] Borrador guardado exitosamente para $folioKey');
    } catch (e) {
      debugPrint('[LocalDB] Error al guardar borrador para $folioKey: $e');
    }
  }

  Future<Map<String, dynamic>?> getDraft(String folio) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return null;
    try {
      final db = await _ensureInit();
      await db.execute('''
        CREATE TABLE IF NOT EXISTS borradores_captura (
          folio_os TEXT PRIMARY KEY,
          draft_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      final rows = await db.query(
        'borradores_captura',
        where: 'folio_os = ?',
        whereArgs: [folioKey],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['draft_json'] as String?;
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[LocalDB] Error recuperando borrador para $folioKey: $e');
      return null;
    }
  }

  Future<void> deleteDraft(String folio) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.execute('''
        CREATE TABLE IF NOT EXISTS borradores_captura (
          folio_os TEXT PRIMARY KEY,
          draft_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.delete(
        'borradores_captura',
        where: 'folio_os = ?',
        whereArgs: [folioKey],
      );
      debugPrint('[LocalDB] Borrador eliminado para $folioKey');
    } catch (e) {
      debugPrint('[LocalDB] Error eliminando borrador para $folioKey: $e');
    }
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
    bool isDraft = false,
    Map<String, dynamic>? instrumentData,
  }) async {
    final db = await _ensureInit();
    final Map<String, dynamic> updateMap = {
      'rep_json':              jsonEncode(repRows),
      'exc_json':              jsonEncode(excRows),
      'exac_json':             jsonEncode(exacRows),
      'observaciones':         observaciones,
      if (dictamen != null)    'dictamen': dictamen,
      if (!isDraft)            'estado': 'COMPLETADA_DIGITAL',
      'unidad_medida':         unidadMedida ?? 'kg',
      'sync_status':           'PENDIENTE_ACTUALIZAR',
      'updated_at':            DateTime.now().toUtc().toIso8601String(),
      if (firmaClienteNombre != null && firmaClienteNombre.isNotEmpty)
        'firma_cliente_nombre': firmaClienteNombre,
    };

    if (instrumentData != null) {
      for (final field in [
        'marca', 'modelo', 'ns', 'id_equipo', 'ubicacion',
        'tipo_instrumento', 'numero_cca', 'holograma_anterior', 'holograma_actualizado',
        'funcionamiento', 'puntos_apoyo', 'cliente', 'sucursal', 'direccion', 'fecha', 'tecnico'
      ]) {
        if (instrumentData[field] != null) {
          updateMap[field] = instrumentData[field].toString();
        }
      }
      if (instrumentData['alcance_max'] != null) {
        updateMap['alcance_max'] = _toDouble(instrumentData['alcance_max']);
      }
      if (instrumentData['div_minima'] != null) {
        updateMap['div_minima'] = _toDouble(instrumentData['div_minima']);
      }
      if (instrumentData['div_verificacion'] != null) {
        updateMap['div_verificacion'] = _toDouble(instrumentData['div_verificacion']);
      }
      if (instrumentData['aplica_excentricidad'] != null) {
        updateMap['aplica_excentricidad'] = _toBoolInt(instrumentData['aplica_excentricidad']);
      }
    }

    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      final sanitizedMap = <String, dynamic>{};
      updateMap.forEach((k, v) {
        if (existingCols.contains(k.toLowerCase())) {
          sanitizedMap[k] = v;
        }
      });

      final String? folio = instrumentData?['folio_os']?.toString().trim();
      if (localId > 0) {
        await db.update(
          'ordenes_servicio',
          sanitizedMap,
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      } else if (folio != null && folio.isNotEmpty) {
        await db.update(
          'ordenes_servicio',
          sanitizedMap,
          where: 'folio_os = ?',
          whereArgs: [folio],
        );
      }
    } catch (e) {
      debugPrint('[LocalDB] Error en saveLecturas: $e');
    }
  }

  Future<void> savePdfPath(int localId, String path, {String? folio, String? pdfB64}) async {
    final db = await _ensureInit();
    final whereClause = (localId > 0) ? 'local_id = ?' : 'folio_os = ?';
    final whereArg = (localId > 0) ? localId : (folio ?? '');
    await db.update(
      'ordenes_servicio',
      {
        'pdf_path_local': path,
        if (pdfB64 != null && pdfB64.isNotEmpty) 'pdf_b64_local': pdfB64,
        'estado': 'COMPLETADA_DIGITAL',
        'sync_status': 'PENDIENTE_ACTUALIZAR',
        'pdf_subido': 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: whereClause,
      whereArgs: [whereArg],
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
        'pdf_subido':    0,
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
    final whereClause = (localId > 0) ? 'local_id = ?' : 'folio_os = ?';
    final whereArg = (localId > 0) ? localId : folio;
    await db.update(
      'ordenes_servicio',
      {
        'firma_tecnico': firmaTecBase64,
        'firma_cliente': firmaCliBase64,
        'nombre_ing':    nombreIng,
        'puesto_ing':    puestoIng,
      },
      where: whereClause, whereArgs: [whereArg],
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

  Future<void> markOsSincronizada(int localId, int newVersion, {String? folio}) async {
    final db = await _ensureInit();
    final whereClause = (localId > 0) ? 'local_id = ?' : 'folio_os = ?';
    final whereArg = (localId > 0) ? localId : (folio ?? '');
    await db.update(
      'ordenes_servicio',
      {'sync_status': 'SINCRONIZADO', 'sync_version': newVersion},
      where: whereClause, whereArgs: [whereArg],
    );
  }

  /// Marca que el archivo PDF binario fue recibido y confirmado por Render (HTTP 200).
  Future<void> markPdfSubido(int localId, {String? folio}) async {
    final db = await _ensureInit();
    final whereClause = (localId > 0) ? 'local_id = ?' : 'folio_os = ?';
    final whereArg = (localId > 0) ? localId : (folio ?? '');
    await db.update(
      'ordenes_servicio',
      {
        'pdf_subido': 1,
        'sync_check_status': 'SUBIDA_SERVIDOR',
        if (folio != null && folio.isNotEmpty) 'pdf_url': '/uploads/$folio.pdf',
      },
      where: whereClause,
      whereArgs: [whereArg],
    );
  }

  /// Obtiene órdenes completadas/cerradas cuyo PDF aún no se ha confirmado subido al servidor.
  Future<List<Map<String, dynamic>>> getOsParaSubirPdf() async {
    final db = await _ensureInit();
    return await db.rawQuery('''
      SELECT * FROM ordenes_servicio 
      WHERE (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA'))
        AND (pdf_subido IS NULL OR pdf_subido = 0)
    ''');
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

  // ── Contactos de Planta / Cliente (Memoria y Autocompletado) ───────────────

  Future<void> _ensureContactosTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contactos_planta (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        cliente         TEXT NOT NULL,
        planta          TEXT NOT NULL,
        nombre_contacto TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        UNIQUE(cliente, planta, nombre_contacto) ON CONFLICT REPLACE
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contactos_planta_cli_pla ON contactos_planta(cliente, planta)
    ''');
  }

  /// Guarda o actualiza un contacto asociado a una planta y cliente.
  /// Se ejecuta automáticamente al ingresar o editar el firmante al finalizar o guardar.
  Future<void> saveContactoPlanta({
    required String cliente,
    required String planta,
    required String nombreContacto,
  }) async {
    final cli = cliente.trim();
    final pla = planta.trim();
    final nom = nombreContacto.trim();
    if (cli.isEmpty || nom.isEmpty) return;

    try {
      final db = await _ensureInit();
      await _ensureContactosTable(db);
      await db.insert(
        'contactos_planta',
        {
          'cliente':         cli,
          'planta':          pla,
          'nombre_contacto': nom,
          'updated_at':      DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint('[LocalDB] Contacto guardado para $cli ($pla): $nom');
    } catch (e) {
      debugPrint('[LocalDB] Error al guardar contacto de planta: $e');
    }
  }

  /// Obtiene los contactos históricos asociados a una planta o cliente,
  /// ordenados por prioridad (planta exacta > planta parcial > cliente) y fecha reciente.
  Future<List<String>> getContactosPlanta({
    required String cliente,
    String? planta,
  }) async {
    final cli = cliente.trim();
    final pla = (planta ?? '').trim();
    if (cli.isEmpty) return [];

    try {
      final db = await _ensureInit();
      await _ensureContactosTable(db);

      final results = await db.rawQuery('''
        SELECT DISTINCT nombre_contacto, updated_at,
          CASE 
            WHEN ? != '' AND LOWER(TRIM(planta)) = LOWER(?) THEN 1
            WHEN ? != '' AND (INSTR(LOWER(?), LOWER(TRIM(planta))) > 0 OR INSTR(LOWER(TRIM(planta)), LOWER(?)) > 0) THEN 2
            ELSE 3
          END as prioridad
        FROM contactos_planta
        WHERE LOWER(TRIM(cliente)) = LOWER(?)
          AND TRIM(nombre_contacto) != ''
        ORDER BY prioridad ASC, updated_at DESC
      ''', [pla, pla, pla, pla, pla, cli]);

      final list = results
          .map((r) => (r['nombre_contacto'] as String? ?? '').trim())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList();

      // Si aún no hay en contactos_planta, consultar ordenes_servicio y auto-indexar
      if (list.isEmpty) {
        final histRows = await db.rawQuery('''
          SELECT DISTINCT 
            COALESCE(NULLIF(TRIM(firma_cliente_nombre), ''), NULLIF(TRIM(nombre_ing), '')) as nom,
            updated_at
          FROM ordenes_servicio
          WHERE LOWER(TRIM(cliente)) = LOWER(?)
            AND (
              (firma_cliente_nombre IS NOT NULL AND TRIM(firma_cliente_nombre) != '')
              OR (nombre_ing IS NOT NULL AND TRIM(nombre_ing) != '')
            )
          ORDER BY updated_at DESC
          LIMIT 10
        ''', [cli]);

        for (final r in histRows) {
          final nom = (r['nom'] as String? ?? '').trim();
          if (nom.isNotEmpty && !list.contains(nom)) {
            list.add(nom);
            await saveContactoPlanta(cliente: cli, planta: pla, nombreContacto: nom);
          }
        }
      }

      return list;
    } catch (e) {
      debugPrint('[LocalDB] Error consultando contactos de planta: $e');
      return [];
    }
  }

  /// Retorna el contacto más recientemente registrado para esa planta/cliente.
  Future<String?> getContactoReciente({
    required String cliente,
    String? planta,
  }) async {
    final list = await getContactosPlanta(cliente: cliente, planta: planta);
    return list.isNotEmpty ? list.first : null;
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