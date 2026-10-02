// lib/services/local_db_service.dart — SQLite offline-first
// Replica el esquema de PostgreSQL en el dispositivo Android.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
      is_synced              INTEGER DEFAULT 0,
      is_dirty               INTEGER DEFAULT 0,
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
        try {
          await db.execute('CREATE VIEW IF NOT EXISTS ordenes AS SELECT *, folio_os AS folio, estado AS estatus FROM ordenes_servicio');
        } catch (_) {}
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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS catalogo_marcas_modelos (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            marca  TEXT NOT NULL,
            modelo TEXT NOT NULL,
            UNIQUE(marca, modelo) ON CONFLICT IGNORE
          )
        ''');
        await db.execute('''
          CREATE INDEX IF NOT EXISTS idx_marcas_modelos_marca ON catalogo_marcas_modelos(marca)
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
            'geometria_plataforma': 'TEXT',
            'geometria_excentricidad': 'TEXT',
            'unidad_medida': "TEXT DEFAULT 'kg'",
            'firma_tecnico_descargada': 'TEXT',
            'pdf_b64_local': 'TEXT',
            'id_lote': 'TEXT',
            'rango_lote': 'TEXT',
            'firma_cliente_nombre': 'TEXT',
            'dictamen': 'TEXT',
            'firma_tecnico': 'TEXT',
            'firma_cliente': 'TEXT',
            'direccion': 'TEXT',
            'calibrado_por': 'TEXT',
            'cca_aplica': 'INTEGER DEFAULT 0',
            'pdf_subido': 'INTEGER DEFAULT 0',
            'sync_check_status': "TEXT DEFAULT 'ASIGNADA'",
            'fecha_descarga_tablet': 'TEXT',
            'fecha_subida_servidor': 'TEXT',
            'fecha_apertura_admin': 'TEXT',
            'estatus': "TEXT DEFAULT 'PROCESO'",
            'folio': 'TEXT',
            'has_pdf': 'INTEGER DEFAULT 0',
            'pdf_path': 'TEXT',
            'metrologia_data': 'TEXT',
            'is_synced': 'INTEGER DEFAULT 0',
            'is_dirty': 'INTEGER DEFAULT 0',
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

          // Crear vista 'ordenes' para compatibilidad si no existe
          try {
            await db.execute('CREATE VIEW IF NOT EXISTS ordenes AS SELECT *, folio_os AS folio, estado AS estatus FROM ordenes_servicio');
          } catch (_) {}

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

        // [CATALOGO MARCAS Y MODELOS] Tabla offline-first con soporte para autocompletado
        try {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS catalogo_marcas_modelos (
              id     INTEGER PRIMARY KEY AUTOINCREMENT,
              marca  TEXT NOT NULL,
              modelo TEXT NOT NULL,
              UNIQUE(marca, modelo) ON CONFLICT IGNORE
            )
          ''');
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_marcas_modelos_marca ON catalogo_marcas_modelos(marca)
          ''');
          final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM catalogo_marcas_modelos')
          ) ?? 0;
          if (count == 0) {
            await db.execute('''
              INSERT OR IGNORE INTO catalogo_marcas_modelos (marca, modelo)
              SELECT DISTINCT TRIM(marca), TRIM(modelo)
              FROM ordenes_servicio
              WHERE marca IS NOT NULL AND TRIM(marca) != ''
                AND modelo IS NOT NULL AND TRIM(modelo) != ''
            ''');
            debugPrint('[LocalDB] catalogo_marcas_modelos inicializado desde ordenes locales');
          }
        } catch (e) {
          debugPrint('[LocalDB] catalogo_marcas_modelos setup error: $e');
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

  /// Getter público para la instancia de Database SQLite
  Future<Database> get database => _ensureInit();

  /// Devuelve el total de órdenes en la base local (revisa vista 'ordenes' y tabla 'ordenes_servicio')
  Future<int> getConteoTotal() async {
    try {
      final db = await _ensureInit();
      try {
        final c = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ordenes')
        );
        if (c != null) return c;
      } catch (_) {}
      final c2 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ordenes_servicio')
      );
      return c2 ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Inserta o actualiza un lote de órdenes JSON desde Render en una única transacción atómica
  Future<int> insertOrdenesBatch(List<Map<String, dynamic>> listaJson) async {
    if (listaJson.isEmpty) return 0;
    final db = await _ensureInit();
    final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
    final validCols = info.map((r) => r['name'] as String).toSet();

    int count = 0;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final raw in listaJson) {
        final folio = (raw['folio_os'] ?? raw['folio'])?.toString().trim();
        if (folio == null || folio.isEmpty) continue;

        final cliente   = (raw['cliente'] ?? raw['cliente_nombre'] ?? '').toString();
        final sucursal  = (raw['sucursal'] ?? raw['sucursal_nombre'] ?? '').toString();
        final tecnico   = (raw['tecnico'] ?? raw['tecnico_nombre'] ?? '').toString();
        final tipoSvc   = (raw['tipo_servicio'] ?? raw['tipo_servicio_nombre'] ?? '').toString();
        final direccion = (raw['direccion'] ?? raw['direccion_cliente'] ?? raw['sucursal_direccion'] ?? raw['planta'] ?? '').toString();

        final rawIdTec = _toIntOrNull(raw['id_tecnico'] ?? raw['tecnico_id']);
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

        final mapped = <String, dynamic>{
          'folio_os':          folio,
          'folio':             folio,
          'id_tecnico':        idTecnicoFinal,
          'estado':            (raw['estado'] ?? raw['estatus'] ?? 'PROCESO').toString(),
          'estatus':           (raw['estado'] ?? raw['estatus'] ?? 'PROCESO').toString(),
          'modalidad':         (raw['modalidad'] ?? 'DIGITAL').toString(),
          'fecha':             raw['fecha']?.toString(),
          'cliente':           cliente,
          'sucursal':          sucursal,
          'direccion':         direccion,
          'tecnico':           tecnico,
          'tipo_servicio':     tipoSvc,
          'tipo_instrumento':  raw['tipo_instrumento']?.toString(),
          'aplica_excentricidad': _toBoolInt(raw['aplica_excentricidad']),
          'num_celdas_camionera': _toInt(raw['num_celdas_camionera'], 0),
          'clase_exactitud':   (raw['clase_exactitud'] ?? raw['clase_exactitud_codigo'])?.toString(),
          'observaciones':     raw['observaciones']?.toString(),
          'marca':             raw['marca']?.toString(),
          'modelo':            raw['modelo']?.toString(),
          'ns':                (raw['ns'] ?? raw['serie'])?.toString(),
          'ubicacion':         raw['ubicacion']?.toString(),
          'id_equipo':         raw['id_equipo']?.toString(),
          'alcance_max':       _toDouble(raw['alcance_max'] ?? raw['capacidad_maxima']),
          'div_minima':        _toDouble(raw['div_minima'] ?? raw['division_minima']),
          'div_verificacion':  (raw['div_verificacion'] ?? raw['folio_dve'] ?? raw['numero_dve'] ?? raw['div_ver'])?.toString(),
          'numero_cca':        (raw['numero_cca'] ?? raw['cca'])?.toString(),
          'holograma_anterior': raw['holograma_anterior']?.toString(),
          'holograma_actualizado': (raw['holograma_actualizado'] ?? raw['holograma_nuevo'])?.toString(),
          'pdf_url':           raw['pdf_url']?.toString(),
          'instrumento_capacidad': raw['instrumento_capacidad']?.toString(),
          'instrumento_division':  raw['instrumento_division']?.toString(),
          'secciones_camionera':   _toInt(raw['secciones_camionera'] ?? raw['num_celdas_camionera'], 0),
          'num_secciones':         _toInt(raw['num_secciones'], 0),
          'unidad_medida':     raw['unidad_medida']?.toString() ?? 'kg',
          'id_lote':           (raw['id_lote'] ?? raw['lote'])?.toString() ?? '',
          'rango_lote':        raw['rango_lote']?.toString() ?? '',
          'dictamen':          raw['dictamen']?.toString(),
          'nombre_ing':        (raw['nombre_ing'] ?? raw['firma_cliente_nombre'])?.toString(),
          'puesto_ing':        raw['puesto_ing']?.toString(),
          'firma_cliente_nombre': (raw['firma_cliente_nombre'] ?? raw['nombre_ing'])?.toString(),
          'firma_tecnico':     (raw['firma_tecnico'] ?? raw['firma_tecnico_b64'])?.toString(),
          'firma_cliente':     (raw['firma_cliente'] ?? raw['firma_cliente_b64'])?.toString(),
          'pdf_path_local':    raw['pdf_path_local']?.toString(),
          'pdf_b64_local':     (raw['pdf_b64_local'] ?? raw['pdf_b64'])?.toString(),
          'sync_check_status': raw['sync_check_status']?.toString() ?? 'ASIGNADA',
          'sync_status':       raw['sync_status']?.toString() ?? 'SINCRONIZADO',
          'is_synced':         1,
          'is_dirty':          0,
          'updated_at':        raw['updated_at']?.toString() ?? DateTime.now().toIso8601String(),
        };

        final safeRow = <String, dynamic>{};
        for (final entry in mapped.entries) {
          if (validCols.contains(entry.key)) {
            safeRow[entry.key] = entry.value;
          }
        }

        batch.insert('ordenes_servicio', safeRow,
            conflictAlgorithm: ConflictAlgorithm.replace);
        count++;
      }
      await batch.commit(noResult: true);
    });
    return count;
  }

  static String? appDocDirPath;

  /// Verifica asíncronamente si el archivo PDF de un folio existe físicamente en el almacenamiento de la tablet.
  Future<bool> checkPdfExistsOnDisk(String folio, [String? pdfPathLocal]) async {
    final f = folio.trim();
    if (f.isEmpty) return false;

    if (pdfPathLocal != null && pdfPathLocal.trim().isNotEmpty) {
      try {
        final file = File(pdfPathLocal.trim());
        if (await file.exists() && await file.length() > 500) return true;
      } catch (_) {}
    }

    final safeFolio = f.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      appDocDirPath = appDocDir.path;

      final cand1 = File('${appDocDir.path}/Pesa_PDFs/$safeFolio.pdf');
      if (await cand1.exists() && await cand1.length() > 500) return true;

      final cand2 = File('${appDocDir.path}/PESA_Tablet/PDF_OS/$safeFolio.pdf');
      if (await cand2.exists() && await cand2.length() > 500) return true;

      final pdfDir = Directory('${appDocDir.path}/Pesa_PDFs');
      if (await pdfDir.exists()) {
        final files = pdfDir.listSync().whereType<File>();
        if (files.any((file) => file.path.split(Platform.pathSeparator).last.startsWith(safeFolio) && file.lengthSync() > 500)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Lógica unificada para determinar si una orden cuenta con documento generado/adjunto o metrología
  bool tieneDocumento(Map<String, dynamic> o) {
    final String? pdfPath = o['pdf_path']?.toString() ?? o['pdf_path_local']?.toString();
    final String? pdfUrl = o['pdf_url']?.toString();
    final bool hasPdfFlag = (o['has_pdf'] == 1 || o['has_pdf'] == '1' || o['has_pdf'] == true || o['pdf_subido'] == 1);
    final metro = o['metrologia_data'] ?? o['rep_json'] ?? o['exac_json'];
    final bool tieneMetrologia = metro != null && 
                                 metro.toString().trim().isNotEmpty && 
                                 metro.toString().trim() != '{}' &&
                                 metro.toString().trim() != '[]' &&
                                 metro.toString().trim() != 'null';
    
    // Verificar si el archivo existe físicamente en el almacenamiento local:
    bool fileExiste = false;
    if (pdfPath != null && pdfPath.isNotEmpty) {
      try {
        fileExiste = File(pdfPath).existsSync();
      } catch (_) {}
    }

    final folioStr = (o['folio_os'] as String? ?? o['folio'] as String? ?? '').trim();
    if (!fileExiste && folioStr.isNotEmpty) {
      fileExiste = checkPdfExistsOnDiskSync(folioStr, pdfPath);
    }
    
    final bool hasB64 = (o['pdf_b64_local']?.toString().length ?? 0) > 100;
    
    return hasPdfFlag || (pdfUrl != null && pdfUrl.isNotEmpty) || tieneMetrologia || fileExiste || hasB64;
  }

  /// Verifica síncronamente si el archivo PDF de un folio existe en el disco usando la ruta base de documentos.
  bool checkPdfExistsOnDiskSync(String folio, [String? pdfPathLocal]) {
    final f = folio.trim();
    if (f.isEmpty) return false;

    if (pdfPathLocal != null && pdfPathLocal.trim().isNotEmpty) {
      try {
        final file = File(pdfPathLocal.trim());
        if (file.existsSync() && file.lengthSync() > 500) return true;
      } catch (_) {}
    }

    final safeFolio = f.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (appDocDirPath != null && appDocDirPath!.isNotEmpty) {
      final candidates = [
        '$appDocDirPath/pdfs/OS-$safeFolio.pdf',
        '$appDocDirPath/pdfs/$safeFolio.pdf',
        '$appDocDirPath/Pesa_PDFs/$safeFolio.pdf',
        '$appDocDirPath/Pesa_PDFs/OS-$safeFolio.pdf',
        '$appDocDirPath/PESA_Tablet/PDF_OS/$safeFolio.pdf',
      ];
      for (final p in candidates) {
        try {
          final file = File(p);
          if (file.existsSync() && file.lengthSync() > 500) return true;
        } catch (_) {}
      }
    }
    return false;
  }

  /// Reconstruye la ruta absoluta válida del archivo PDF local en disco para un folio dado.
  Future<String?> resolvePdfPathFromDisk(String folio) async {
    final f = folio.trim();
    if (f.isEmpty) return null;
    final safeFolio = f.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      appDocDirPath = appDocDir.path;

      final directCandidates = [
        '${appDocDir.path}/pdfs/OS-$safeFolio.pdf',
        '${appDocDir.path}/pdfs/$safeFolio.pdf',
        '${appDocDir.path}/Pesa_PDFs/$safeFolio.pdf',
        '${appDocDir.path}/Pesa_PDFs/OS-$safeFolio.pdf',
        '${appDocDir.path}/PESA_Tablet/PDF_OS/$safeFolio.pdf',
      ];

      for (final path in directCandidates) {
        final cand = File(path);
        if (await cand.exists() && await cand.length() > 500) return cand.path;
      }

      for (final sub in ['pdfs', 'Pesa_PDFs']) {
        final pdfDir = Directory('${appDocDir.path}/$sub');
        if (await pdfDir.exists()) {
          final files = pdfDir.listSync().whereType<File>();
          for (final file in files) {
            final name = file.path.split(Platform.pathSeparator).last;
            if ((name.startsWith(safeFolio) || name.startsWith('OS-$safeFolio')) && file.lengthSync() > 500) {
              return file.path;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }



  // ── Fallback catálogos: derivar datos desde órdenes locales ──────────────

  /// Retorna clientes únicos derivados de las órdenes guardadas localmente.
  /// Se usa como fallback cuando /api/v1/clientes devuelve error HTTP.
  Future<List<Map<String, dynamic>>> getClientesFromLocalOrders() async {
    final db = await _ensureInit();
    final rows = await db.rawQuery(
      '''SELECT DISTINCT cliente AS nombre, cliente AS razon_social,
                '' AS rfc, '' AS telefono
         FROM ordenes_servicio
         WHERE cliente IS NOT NULL AND TRIM(cliente) != ''
         ORDER BY cliente ASC''',
    );
    return rows;
  }

  // ── CRUD OS ───────────────────────────────────────────────────────────────


  Future<bool> upsertOs(Map<String, dynamic> data) async {
    final folio = (data['folio_os'] as String? ?? data['folio'] as String? ?? '').trim();
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
      'div_verificacion':  (data['div_verificacion'] ?? data['folio_dve'] ?? data['numero_dve'] ?? data['div_ver'])?.toString(),
      'numero_cca':        (data['numero_cca'] ?? data['cca'])?.toString(),
      'holograma_anterior': data['holograma_anterior']?.toString(),
      'holograma_actualizado': (data['holograma_actualizado'] ?? data['holograma_nuevo'])?.toString(),
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
      if (data['firma_tecnico'] != null && data['firma_tecnico'].toString().isNotEmpty)
        'firma_tecnico': data['firma_tecnico'].toString(),
      if (data['firma_cliente'] != null && data['firma_cliente'].toString().isNotEmpty)
        'firma_cliente': data['firma_cliente'].toString(),
      if (data['firma_cliente_nombre'] != null && data['firma_cliente_nombre'].toString().isNotEmpty)
        'firma_cliente_nombre': data['firma_cliente_nombre'].toString(),
      if (data['nombre_ing'] != null && data['nombre_ing'].toString().isNotEmpty)
        'nombre_ing': data['nombre_ing'].toString(),
      if (data['puesto_ing'] != null && data['puesto_ing'].toString().isNotEmpty)
        'puesto_ing': data['puesto_ing'].toString(),
      if (data['dictamen'] != null && data['dictamen'].toString().isNotEmpty)
        'dictamen': data['dictamen'].toString(),
      // Sync & Trazabilidad
      'sync_check_status': (data['sync_check_status'] as String?)?.isNotEmpty == true
          ? data['sync_check_status'].toString()
          : (data['syncCheckStatus'] as String?)?.isNotEmpty == true
              ? data['syncCheckStatus'].toString()
              : 'RECIBIDA_TABLET',
      if (data['fecha_descarga_tablet'] != null)
        'fecha_descarga_tablet': data['fecha_descarga_tablet']?.toString(),
      if (data['fecha_subida_servidor'] != null)
        'fecha_subida_servidor': data['fecha_subida_servidor']?.toString(),
      if (data['fecha_apertura_admin'] != null)
        'fecha_apertura_admin': data['fecha_apertura_admin']?.toString(),
      'sync_version':      _toInt(data['sync_version'], 0),
      'sync_status':       'SINCRONIZADO',
      'is_synced':         (data['is_synced'] == 1 || data['is_synced'] == true || data['sync_status'] == 'SINCRONIZADO' || data['sync_check_status'] == 'SUBIDA_SERVIDOR' || data['sync_check_status'] == 'AUDITADA_ADMIN' || data['sync_check_status'] == 'ABIERTO') ? 1 : 0,
      'updated_at':        data['updated_at']?.toString(),
    };

    try {
      final db = await _ensureInit();
      // [PULL PROTEGIDO] Verificación exhaustiva de registro local antes de actualizar
      final existingRows = await db.query(
        'ordenes_servicio',
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [folio, folio],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        final ex = existingRows.first;
        final int localIsDirty = _toInt(ex['is_dirty'], 0);
        final String? pdfPath = ex['pdf_path_local'] as String?;
        final String? pdfB64 = ex['pdf_b64_local'] as String?;
        final String syncCheckSt = (ex['sync_check_status'] as String? ?? '').toUpperCase().trim();
        final String exEstatus = (ex['estatus'] as String? ?? '').toUpperCase().trim();
        final String exEstado = (ex['estado'] as String? ?? '').toUpperCase().trim();

        final bool statusIsClosed = exEstatus == 'CERRADO' ||
            exEstatus == 'CERRADA' ||
            exEstatus == 'COMPLETADA' ||
            {'CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA'}.contains(exEstado);

        final bool hasPdfPath = pdfPath != null && pdfPath.isNotEmpty;
        final bool hasPdfB64 = pdfB64 != null && pdfB64.isNotEmpty;
        final bool pdfDiskExists = await checkPdfExistsOnDisk(folio, pdfPath);
        final bool hasLocalChanges = localIsDirty == 1 || (syncCheckSt != 'SUBIDA_SERVIDOR' && syncCheckSt != 'AUDITADA_ADMIN' && syncCheckSt != 'ABIERTO');

        final bool localIsClosed = statusIsClosed || hasPdfPath || hasPdfB64 || pdfDiskExists || hasLocalChanges;

        // REGLA 1 (REGLA DE ORO): CANDADO ESTRICTO CONTRA SOBRESCRITURA
        // SI la orden local ya está cerrada o fue trabajada localmente (tiene cambios pendientes o PDF):
        // ¡PROHIBIDO SOBREESCRIBIR CON EL ESTATUS 'PROCESO' DEL SERVIDOR!
        if (localIsClosed) {
          debugPrint('[LocalDB] 🛡 CANDADO PULL (REGLA 1): Inmunidad de orden cerrada/trabajada para $folio (estatus=$exEstatus, estado=$exEstado, dirty=$localIsDirty, changes=$hasLocalChanges, pdfDisk=$pdfDiskExists)');

          String? validPdfPath = pdfPath;
          if ((validPdfPath == null || validPdfPath.isEmpty) && pdfDiskExists) {
            validPdfPath = await resolvePdfPathFromDisk(folio);
          }

          final safeUpdate = <String, dynamic>{
            'cliente': cliente.isNotEmpty ? cliente : ex['cliente'],
            'sucursal': sucursal.isNotEmpty ? sucursal : ex['sucursal'],
            'direccion': direccion.isNotEmpty ? direccion : ex['direccion'],
            'tecnico': tecnico.isNotEmpty ? tecnico : ex['tecnico'],
            'tipo_servicio': tipoSvc.isNotEmpty ? tipoSvc : ex['tipo_servicio'],
            if (idTecnicoFinal != null && idTecnicoFinal > 0) 'id_tecnico': idTecnicoFinal,

            // Mantener intactos: estatus 'Cerrado', estado local, mediciones, firmas y pdf_path_local
            'estado': (ex['estado'] != null && ex['estado'].toString().isNotEmpty && ex['estado'] != 'PROCESO')
                ? ex['estado']
                : 'COMPLETADA_DIGITAL',
            'estatus': 'Cerrado',
            if (validPdfPath != null && validPdfPath.isNotEmpty) 'pdf_path_local': validPdfPath,
            if (ex['pdf_b64_local'] != null) 'pdf_b64_local': ex['pdf_b64_local'],
            if (ex['pdf_subido'] != null) 'pdf_subido': ex['pdf_subido'],
            if (ex['is_dirty'] != null) 'is_dirty': ex['is_dirty'],
            if (ex['firma_tecnico'] != null) 'firma_tecnico': ex['firma_tecnico'],
            if (ex['firma_cliente'] != null) 'firma_cliente': ex['firma_cliente'],
            if (ex['firma_cliente_nombre'] != null) 'firma_cliente_nombre': ex['firma_cliente_nombre'],
            if (ex['nombre_ing'] != null) 'nombre_ing': ex['nombre_ing'],
            if (ex['puesto_ing'] != null) 'puesto_ing': ex['puesto_ing'],
            if (ex['dictamen'] != null) 'dictamen': ex['dictamen'],
            if (ex['observaciones'] != null) 'observaciones': ex['observaciones'],
            if (ex['rep_json'] != null) 'rep_json': ex['rep_json'],
            if (ex['exc_json'] != null) 'exc_json': ex['exc_json'],
            if (ex['exac_json'] != null) 'exac_json': ex['exac_json'],
          };

          // Solo actualizar metadatos externos si el servidor confirma SUBIDA_SERVIDOR o AUDITADA_ADMIN
          final srvSt = row['sync_check_status']?.toString().trim().toUpperCase();
          if (srvSt == 'SUBIDA_SERVIDOR' || srvSt == 'AUDITADA_ADMIN' || srvSt == 'ABIERTO') {
            safeUpdate['sync_check_status'] = srvSt == 'AUDITADA_ADMIN' ? 'AUDITADA_ADMIN' : 'SUBIDA_SERVIDOR';
            safeUpdate['is_synced'] = 1;
            safeUpdate['sync_status'] = 'SINCRONIZADO';
          }

          await db.update(
            'ordenes_servicio',
            safeUpdate,
            where: 'folio_os = ? OR folio = ?',
            whereArgs: [folio, folio],
          );
          lastUpsertError = null;
          return true;
        }

        // Si la orden local no está cerrada ni tiene trabajo pendiente, fusionar de forma segura
        if (row['pdf_path_local'] == null && ex['pdf_path_local'] != null) {
          final f = File(ex['pdf_path_local'].toString());
          if (f.existsSync()) {
            row['pdf_path_local'] = ex['pdf_path_local'];
          }
        }
        if (row['pdf_b64_local'] == null && ex['pdf_b64_local'] != null) {
          row['pdf_b64_local'] = ex['pdf_b64_local'];
        }
        if (ex['pdf_subido'] != null) {
          row['pdf_subido'] = ex['pdf_subido'];
        }
        if (ex['firma_tecnico'] != null) row['firma_tecnico'] = ex['firma_tecnico'];
        if (ex['firma_cliente'] != null) row['firma_cliente'] = ex['firma_cliente'];
        if (ex['firma_cliente_nombre'] != null) row['firma_cliente_nombre'] = ex['firma_cliente_nombre'];
        if (ex['nombre_ing'] != null) row['nombre_ing'] = ex['nombre_ing'];
        if (ex['puesto_ing'] != null) row['puesto_ing'] = ex['puesto_ing'];
        if (ex['dictamen'] != null) row['dictamen'] = ex['dictamen'];

        await db.update(
          'ordenes_servicio',
          row,
          where: 'folio_os = ? OR folio = ?',
          whereArgs: [folio, folio],
        );
        lastUpsertError = null;
        return true;
      }

      await db.insert(
        'ordenes_servicio',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
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
            conflictAlgorithm: ConflictAlgorithm.ignore);
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

    // Admin: (idTecnico null o <= 0 Y nombreTecnico vacío) -> devuelve todas
    if ((idTecnico == null || idTecnico <= 0) && nombreLow.isEmpty) {
      return await db.rawQuery(
        "SELECT * FROM ordenes_servicio ORDER BY local_id DESC, fecha DESC",
      );
    }

    // Regla estricta de aislamiento por técnico:
    // La consulta base SIEMPRE debe incluir WHERE LOWER(tecnico) = LOWER('${usuario.nombre}')
    if (nombreLow.isNotEmpty) {
      final likePattern = '%$nombreLow%';
      if (idTecnico != null && idTecnico > 0) {
        return await db.rawQuery(
          """
          SELECT * FROM ordenes_servicio 
          WHERE LOWER(TRIM(COALESCE(tecnico, ''))) = LOWER(?) 
             OR LOWER(TRIM(COALESCE(tecnico, ''))) LIKE LOWER(?)
             OR id_tecnico = ?
          ORDER BY local_id DESC, fecha DESC
          """,
          [nombreLow, likePattern, idTecnico],
        );
      } else {
        return await db.rawQuery(
          """
          SELECT * FROM ordenes_servicio 
          WHERE LOWER(TRIM(COALESCE(tecnico, ''))) = LOWER(?)
             OR LOWER(TRIM(COALESCE(tecnico, ''))) LIKE LOWER(?)
          ORDER BY local_id DESC, fecha DESC
          """,
          [nombreLow, likePattern],
        );
      }
    }

    if (idTecnico != null && idTecnico > 0) {
      return await db.rawQuery(
        """
        SELECT * FROM ordenes_servicio 
        WHERE id_tecnico = ?
        ORDER BY local_id DESC, fecha DESC
        """,
        [idTecnico],
      );
    }

    return [];
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
      // 1. Si tenemos id_tecnico, borrar cualquier orden limpia de otro técnico
      if (currentIdTecnico != null && currentIdTecnico > 0) {
        final count = await db.delete(
          'ordenes_servicio',
          where: 'id_tecnico IS NOT NULL AND id_tecnico != ? AND is_dirty = 0',
          whereArgs: [currentIdTecnico],
        );
        totalEliminadas += count;
        if (count > 0) {
          debugPrint('[LocalDB] Purga id_tecnico != $currentIdTecnico: $count órdenes eliminadas de otros técnicos');
        }
      }

      // 2. Para órdenes restantes, verificar que el nombre del técnico coincida
      if (currentNombre != null && currentNombre.trim().isNotEmpty) {
        String _norm(String s) => s
            .replaceAll('á','a').replaceAll('é','e').replaceAll('í','i')
            .replaceAll('ó','o').replaceAll('ú','u').replaceAll('ü','u');
        final nombreLow = _norm(currentNombre.toLowerCase().trim());
        final rows = await db.query(
          'ordenes_servicio',
          columns: ['local_id', 'folio_os', 'tecnico', 'is_dirty', 'id_tecnico'],
          where: 'is_dirty = 0',
        );

        for (final r in rows) {
          final tecRaw = (r['tecnico'] as String? ?? '').toLowerCase().trim();
          final tecNorm = _norm(tecRaw);
          final rId = int.tryParse(r['id_tecnico']?.toString() ?? '');
          final localId = r['local_id'] as int;

          // Si coincide por id_tecnico con el usuario actual, conservar
          if (currentIdTecnico != null && currentIdTecnico > 0 && rId == currentIdTecnico) {
            continue;
          }
          // Si coincide por nombre completo exacto, conservar
          if (tecNorm.isNotEmpty && tecNorm == nombreLow) continue;

          // Verificación con apellido: si primer nombre igual pero apellido distinto → purgar
          final tecParts = tecNorm.split(RegExp(r'\s+'));
          final myParts  = nombreLow.split(RegExp(r'\s+'));
          if (tecParts.length >= 2 && myParts.length >= 2 &&
              tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) {
            // Mismo primer nombre, apellido distinto → es otro técnico → purgar
            await db.delete('ordenes_servicio', where: 'local_id = ?', whereArgs: [localId]);
            totalEliminadas++;
            continue;
          }

          // Coincidencia parcial de nombre completo
          if (tecNorm.isNotEmpty && (tecNorm.contains(nombreLow) || nombreLow.contains(tecNorm))) {
            continue; // conservar
          }

          // No coincide → pertenece a otro técnico → purgar de SQLite local
          await db.delete('ordenes_servicio', where: 'local_id = ?', whereArgs: [localId]);
          totalEliminadas++;
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

  Future<void> resetOsCaptura(String folio) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await deleteDraft(folioKey);
      await db.update(
        'ordenes_servicio',
        {
          'rep_json': null,
          'exc_json': null,
          'exac_json': null,
          'observaciones': null,
          'dictamen': null,
          'firma_tecnico_b64': null,
          'firma_cliente_b64': null,
          'firma_cliente_nombre': null,
          'puesto_ing': null,
          'nombre_ing': null,
          'estado': 'Proceso',
          'sync_status': 'PENDIENTE_ACTUALIZAR',
          'is_dirty': 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'folio_os = ?',
        whereArgs: [folioKey],
      );
      debugPrint('[LocalDB] Toma reseteada para $folioKey');
    } catch (e) {
      debugPrint('[LocalDB] Error reseteando toma para $folioKey: $e');
    }
  }

  /// Elimina de disco físico cualquier PDF generado o guardado para este folio.
  Future<void> deletePdfFromDisk(String folio) async {
    final path = await resolvePdfPathFromDisk(folio);
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
          debugPrint('[LocalDB] PDF eliminado de disco: $path');
        }
      } catch (e) {
        debugPrint('[LocalDB] Error eliminando PDF de disco ($path): $e');
      }
    }
  }

  /// Reset atómico y tolerante a fallos en SQLite local (Offline-First).
  Future<bool> resetearOrdenLocal(String folio, {int? localId}) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty && localId == null) return false;

    try {
      final db = await _ensureInit();

      // 1. Obtener columnas válidas existentes en ordenes_servicio
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final validCols = info.map((r) => r['name'] as String).toSet();

      final fullUpdate = <String, dynamic>{
        'metrologia_data': null,
        'rep_json': null,
        'exc_json': null,
        'exac_json': null,
        'observaciones': null,
        'dictamen': null,
        'firma_cliente': null,
        'firma_cliente_b64': null,
        'firma_cliente_nombre': null,
        'puesto_ing': null,
        'nombre_ing': null,
        'firma_tecnico': null,
        'firma_tecnico_b64': null,
        'pdf_path': null,
        'pdf_path_local': null,
        'pdf_b64_local': null,
        'pdf_url': null,
        'has_pdf': 0,
        'pdf_subido': 0,
        'estado': 'PROCESO',
        'estatus': 'Proceso',
        'is_dirty': 1, // Marcar para que la próxima sync limpie el servidor
        'sync_status': 'PENDIENTE_RESET',
        'sync_check_status': 'ASIGNADA',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      final safeUpdate = <String, dynamic>{};
      for (final entry in fullUpdate.entries) {
        if (validCols.contains(entry.key)) {
          safeUpdate[entry.key] = entry.value;
        }
      }

      // Aplicar actualización atómica
      if (localId != null && localId > 0) {
        await db.update('ordenes_servicio', safeUpdate, where: 'local_id = ?', whereArgs: [localId]);
      }
      if (folioKey.isNotEmpty) {
        await db.update(
          'ordenes_servicio',
          safeUpdate,
          where: 'folio_os = ? OR folio = ?',
          whereArgs: [folioKey, folioKey],
        );
        // Borrar borrador local si existía
        try {
          await deleteDraft(folioKey);
        } catch (_) {}
      }

      // 2. Eliminar archivos PDF físicos locales de forma segura
      try {
        final dir = await getApplicationDocumentsDirectory();
        final safeFolio = folioKey.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final candidates = [
          '${dir.path}/pdfs/$safeFolio.pdf',
          '${dir.path}/pdfs/OS-$safeFolio.pdf',
          '${dir.path}/Pesa_PDFs/$safeFolio.pdf',
          '${dir.path}/Pesa_PDFs/OS-$safeFolio.pdf',
          '${dir.path}/PESA_Tablet/PDF_OS/$safeFolio.pdf',
        ];
        for (final p in candidates) {
          try {
            final file = File(p);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('[RESET] Advertencia al borrar archivo PDF físico: $e');
      }

      debugPrint('[RESET LOCAL] ✅ Orden $folioKey (localId: $localId) reseteada exitosamente en SQLite');
      return true;
    } catch (e) {
      debugPrint('[RESET ERROR LOCAL] Error reseteando orden $folio: $e');
      return false;
    }
  }

  /// Reset completo de toma metrológica desde cero (Lecturas, dictamen, firmas y PDF local).
  Future<void> resetTomaDesdeCero(String folio, {int? localId}) async {
    await resetearOrdenLocal(folio, localId: localId);
  }

  /// Guarda la ruta y base64 de un PDF manual cargado por el usuario, marcando la orden como pendiente de subida.
  Future<void> saveManualPdf(String folio, String path, {String? pdfB64}) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      final Map<String, dynamic> updateMap = {
        'pdf_path_local': path,
        if (pdfB64 != null) 'pdf_b64_local': pdfB64,
        'pdf_subido': 0,
        'estado': 'Cerrado',
        'sync_status': 'PENDIENTE',
        'sync_check_status': 'PENDIENTE_SUBIDA',
        'is_dirty': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      await db.update('ordenes_servicio', updateMap, where: 'folio_os = ?', whereArgs: [folioKey]);
      debugPrint('[LocalDB] saveManualPdf exitoso para $folioKey -> $path');
    } catch (e) {
      debugPrint('[LocalDB] Error en saveManualPdf: $e');
      rethrow;
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
      'is_dirty':              1,
      'updated_at':            DateTime.now().toUtc().toIso8601String(),
      if (firmaClienteNombre != null && firmaClienteNombre.isNotEmpty)
        'firma_cliente_nombre': firmaClienteNombre,
    };

    if (instrumentData != null) {
      for (final field in [
        'marca', 'modelo', 'ns', 'id_equipo', 'ubicacion',
        'tipo_instrumento', 'numero_cca', 'cca', 'holograma_anterior', 'holograma_actualizado', 'holograma_nuevo',
        'div_verificacion', 'folio_dve', 'numero_dve', 'div_ver',
        'funcionamiento', 'puntos_apoyo', 'cliente', 'sucursal', 'direccion', 'fecha', 'tecnico',
        'geometria_plataforma', 'geometria_excentricidad'
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
      if (instrumentData['aplica_excentricidad'] != null) {
        updateMap['aplica_excentricidad'] = _toBoolInt(instrumentData['aplica_excentricidad']);
      }
      if (instrumentData['num_secciones'] != null) {
        updateMap['num_secciones'] = _toIntOrNull(instrumentData['num_secciones']);
      }
      if (instrumentData['secciones_camionera'] != null) {
        updateMap['secciones_camionera'] = _toIntOrNull(instrumentData['secciones_camionera']);
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

  Future<void> savePdfPath(
    int localId,
    String path, {
    String? folio,
    String? pdfB64,
    bool isOnline = false,
    bool uploadOk = false,
  }) async {
    final db = await _ensureInit();
    final folioKey = (folio ?? '').trim();
    final syncCheck = (isOnline && uploadOk) ? 'SUBIDA_SERVIDOR' : 'PENDIENTE_SUBIDA';
    final syncStatus = (isOnline && uploadOk) ? 'SINCRONIZADO' : 'PENDIENTE';
    final isSynced = (isOnline && uploadOk) ? 1 : 0;
    final pdfSubido = (isOnline && uploadOk) ? 1 : 0;
    final isDirty = (isOnline && uploadOk) ? 0 : 1;

    final updateData = <String, dynamic>{
      'pdf_path_local': path,
      if (pdfB64 != null && pdfB64.isNotEmpty) 'pdf_b64_local': pdfB64,
      'estado': 'COMPLETADA_DIGITAL',
      'estatus': 'Cerrado',
      'sync_check_status': syncCheck,
      'sync_status': syncStatus,
      'is_synced': isSynced,
      'pdf_subido': pdfSubido,
      'is_dirty': isDirty,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      final sanitized = <String, dynamic>{};
      updateData.forEach((k, v) {
        if (existingCols.contains(k.toLowerCase())) {
          sanitized[k] = v;
        }
      });

      if (localId > 0) {
        await db.update(
          'ordenes_servicio',
          sanitized,
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      }
      if (folioKey.isNotEmpty) {
        await db.update(
          'ordenes_servicio',
          sanitized,
          where: 'folio_os = ?',
          whereArgs: [folioKey],
        );
      }
      debugPrint('[LocalDB] savePdfPath exitoso para $folioKey (localId: $localId, path: $path, syncCheck: $syncCheck)');
    } catch (e) {
      debugPrint('[LocalDB] Error en savePdfPath: $e');
    }
  }

  Future<void> updatePdfPathLocal(String folio, String path) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.update(
        'ordenes_servicio',
        {
          'pdf_path_local': path,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'folio_os = ?',
        whereArgs: [folioKey],
      );
      debugPrint('[LocalDB] updatePdfPathLocal exitoso para $folioKey -> $path');
    } catch (e) {
      debugPrint('[LocalDB] Error en updatePdfPathLocal: $e');
    }
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
        'sync_status':   'PENDIENTE',
        'pdf_subido':    0,
        'is_dirty':      1,
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
        'is_dirty':      1,
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
      {
        'sync_status': 'SINCRONIZADO',
        'is_synced': 1,
        'is_dirty': 0,
        'sync_check_status': 'SUBIDA_SERVIDOR',
        'sync_version': newVersion,
      },
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
        'is_synced': 1,
        'is_dirty': 0,
        'sync_status': 'SINCRONIZADO',
        'sync_check_status': 'SUBIDA_SERVIDOR',
        if (folio != null && folio.isNotEmpty) 'pdf_url': '/uploads/$folio.pdf',
      },
      where: whereClause,
      whereArgs: [whereArg],
    );
  }

  /// Limpia la bandera is_dirty una vez que PUSH fue confirmado HTTP 200/201 por Render.
  Future<void> clearDirty(String folio) async {
    final f = folio.trim();
    if (f.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.update(
        'ordenes_servicio',
        {
          'is_dirty': 0,
          'sync_status': 'SINCRONIZADO',
          'is_synced': 1,
          'sync_check_status': 'SUBIDA_SERVIDOR',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
      debugPrint('[LocalDB] clearDirty exitoso para $f');
    } catch (e) {
      debugPrint('[LocalDB] Error en clearDirty para $f: $e');
    }
  }

  /// Homologa el estado de sincronización y estatus desde Render en cada pull
  Future<void> updateSyncAndStatus({
    required String folio,
    required String syncCheckStatus,
    required String estatus,
  }) async {
    final db = await _ensureInit();
    final f = folio.trim();
    if (f.isEmpty) return;

    final normSync = syncCheckStatus.trim().toUpperCase();
    final isSynced = (normSync == 'SUBIDA_SERVIDOR' || normSync == 'AUDITADA_ADMIN' || normSync == 'ABIERTO') ? 1 : 0;

    try {
      final existing = await db.query(
        'ordenes_servicio',
        columns: ['estado', 'estatus', 'is_dirty', 'pdf_path_local'],
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        final ex = existing.first;
        final String exEstado = (ex['estado'] as String? ?? '').toUpperCase().trim();
        final String exEstatus = (ex['estatus'] as String? ?? '').toUpperCase().trim();
        final bool statusIsClosed = exEstatus == 'CERRADO' ||
            exEstatus == 'CERRADA' ||
            exEstatus == 'COMPLETADA' ||
            {'CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA'}.contains(exEstado);
        final int localIsDirty = _toInt(ex['is_dirty'], 0);
        final String? pdfPath = ex['pdf_path_local'] as String?;
        final bool pdfDiskExists = await checkPdfExistsOnDisk(f, pdfPath);
        final bool hasLocalPdf = (pdfPath != null && pdfPath.isNotEmpty) || pdfDiskExists;

        if (statusIsClosed || localIsDirty == 1 || hasLocalPdf) {
          debugPrint('[LocalDB] 🛡 updateSyncAndStatus: Preservando estatus cerrado/dirty local para $f');
          await db.rawUpdate('''
            UPDATE ordenes_servicio SET 
              sync_check_status = ?,
              estatus = 'Cerrado',
              estado = CASE WHEN estado IS NULL OR estado = '' OR estado = 'PROCESO' THEN 'COMPLETADA_DIGITAL' ELSE estado END,
              is_synced = CASE WHEN ? = 1 THEN 1 ELSE is_synced END,
              is_dirty = CASE WHEN ? = 1 THEN 0 ELSE is_dirty END,
              sync_status = CASE WHEN ? = 1 THEN 'SINCRONIZADO' ELSE sync_status END
            WHERE folio_os = ? OR folio = ?
          ''', [syncCheckStatus, isSynced, isSynced, isSynced, f, f]);
          return;
        }
      }

      await db.rawUpdate('''
        UPDATE ordenes_servicio SET 
          sync_check_status = ?,
          estado = ?,
          estatus = ?,
          is_synced = CASE WHEN ? = 1 THEN 1 ELSE is_synced END,
          is_dirty = CASE WHEN ? = 1 THEN 0 ELSE is_dirty END,
          sync_status = CASE WHEN ? = 1 THEN 'SINCRONIZADO' ELSE sync_status END
        WHERE folio_os = ? OR folio = ?
      ''', [syncCheckStatus, estatus, estatus, isSynced, isSynced, isSynced, f, f]);
    } catch (e) {
      debugPrint('[LocalDB] Error en updateSyncAndStatus para $f: $e');
    }
  }

  /// Actualiza inmediatamente el estado local tras push exitoso
  Future<void> updateOsSyncCheckStatus(
    String folio,
    String status, {
    int isSynced = 1,
    int? pdfSubido,
    String? estado,
  }) async {
    final db = await _ensureInit();
    final f = folio.trim();
    if (f.isEmpty) return;

    final isDirty = (status == 'SUBIDA_SERVIDOR' || status == 'AUDITADA_ADMIN' || isSynced == 1) ? 0 : 1;
    final updateData = <String, dynamic>{
      'sync_check_status': status,
      'is_synced': isSynced,
      'is_dirty': isDirty,
      'sync_status': isSynced == 1 ? 'SINCRONIZADO' : 'PENDIENTE_ACTUALIZAR',
      if (pdfSubido != null) 'pdf_subido': pdfSubido,
      if (estado != null && estado.isNotEmpty) ...{
        'estado': estado,
        'estatus': estado,
      },
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      final sanitized = <String, dynamic>{};
      updateData.forEach((k, v) {
        if (existingCols.contains(k.toLowerCase())) {
          sanitized[k] = v;
        }
      });

      await db.update(
        'ordenes_servicio',
        sanitized,
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
      debugPrint('[LocalDB] updateOsSyncCheckStatus exitoso para $f -> $status');
    } catch (e) {
      debugPrint('[LocalDB] Error en updateOsSyncCheckStatus para $f: $e');
    }
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
    return await db.rawQuery('''
      SELECT * FROM ordenes_servicio 
      WHERE is_dirty = 1 
         OR sync_status = 'PENDIENTE'
         OR sync_status = 'PENDIENTE_ACTUALIZAR'
         OR (pdf_path_local IS NOT NULL AND (pdf_subido = 0 OR pdf_subido IS NULL) AND (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA') OR estatus = 'Cerrado'))
         OR (sync_check_status IN ('RECIBIDA_TABLET', 'PENDIENTE_SUBIDA', 'ASIGNADA') 
             AND (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA') OR estatus = 'Cerrado'))
    ''');
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
    final r = await db.rawQuery('''
      SELECT COUNT(*) as c FROM ordenes_servicio 
      WHERE is_dirty = 1 
         OR sync_status = 'PENDIENTE'
         OR sync_status = 'PENDIENTE_ACTUALIZAR'
         OR (pdf_path_local IS NOT NULL AND (pdf_subido = 0 OR pdf_subido IS NULL) AND (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA') OR estatus = 'Cerrado'))
    ''');
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

  /// Elimina el timestamp de última sincronización para forzar un pull completo en el próximo ciclo.
  Future<void> resetLastSyncTime() async {
    try {
      final db = await _ensureInit();
      await db.delete('meta', where: "key = 'last_sync'");
      debugPrint('[LocalDB] resetLastSyncTime: timestamp eliminado — próximo pull será completo');
    } catch (e) {
      debugPrint('[LocalDB] resetLastSyncTime error: $e');
    }
  }
  Future<DateTime?> getLastCatalogSyncTime() async {
    final db = await _ensureInit();
    try {
      final rows = await db.query('meta', where: "key = 'last_catalog_sync'", limit: 1);
      if (rows.isEmpty) return null;
      return DateTime.tryParse(rows.first['value'] as String? ?? '');
    } catch (_) { return null; }
  }

  Future<void> setLastCatalogSyncTime(DateTime dt) async {
    final db = await _ensureInit();
    try {
      await db.insert('meta', {'key': 'last_catalog_sync', 'value': dt.toIso8601String()},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('[LocalDB] setLastCatalogSyncTime error: $e');
    }
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

  // ── Catálogo Marcas y Modelos (Offline-First) ─────────────────────────────

  /// Guarda una combinación de marca y modelo en la base de datos local SQLite.
  /// No hace nada si alguno de los dos está vacío.
  Future<void> saveMarcaModelo(String marca, String modelo) async {
    final m = marca.trim();
    final mod = modelo.trim();
    if (m.isEmpty || mod.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.insert(
        'catalogo_marcas_modelos',
        {'marca': m, 'modelo': mod},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      debugPrint('[LocalDB] Marca/Modelo guardado: ($m, $mod)');
    } catch (e) {
      debugPrint('[LocalDB] Error saveMarcaModelo ($m, $mod): $e');
    }
  }

  /// Retorna la lista única de marcas disponibles ordenadas alfabéticamente.
  Future<List<String>> getMarcas() async {
    try {
      final db = await _ensureInit();
      final rows = await db.rawQuery(
        'SELECT DISTINCT marca FROM catalogo_marcas_modelos ORDER BY marca COLLATE NOCASE ASC'
      );
      return rows
          .map((r) => (r['marca'] as String? ?? '').trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[LocalDB] Error getMarcas: $e');
      return [];
    }
  }

  /// Retorna la lista de modelos. Si [marca] se especifica y no está vacía,
  /// retorna únicamente los modelos asociados a esa marca.
  Future<List<String>> getModelos({String? marca}) async {
    try {
      final db = await _ensureInit();
      final m = marca?.trim();
      List<Map<String, dynamic>> rows;
      if (m != null && m.isNotEmpty) {
        rows = await db.rawQuery(
          'SELECT DISTINCT modelo FROM catalogo_marcas_modelos WHERE LOWER(marca) = LOWER(?) ORDER BY modelo COLLATE NOCASE ASC',
          [m],
        );
      } else {
        rows = await db.rawQuery(
          'SELECT DISTINCT modelo FROM catalogo_marcas_modelos ORDER BY modelo COLLATE NOCASE ASC'
        );
      }
      return rows
          .map((r) => (r['modelo'] as String? ?? '').trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[LocalDB] Error getModelos: $e');
      return [];
    }
  }

  /// Retorna todas las combinaciones de (marca, modelo) registradas localmente.
  Future<List<Map<String, String>>> getAllMarcasModelos() async {
    try {
      final db = await _ensureInit();
      final rows = await db.rawQuery(
        'SELECT DISTINCT marca, modelo FROM catalogo_marcas_modelos ORDER BY marca COLLATE NOCASE ASC, modelo COLLATE NOCASE ASC'
      );
      return rows.map((r) => {
        'marca': (r['marca'] as String? ?? '').trim(),
        'modelo': (r['modelo'] as String? ?? '').trim(),
      }).where((m) => m['marca']!.isNotEmpty && m['modelo']!.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[LocalDB] Error getAllMarcasModelos: $e');
      return [];
    }
  }

  /// Inserta en lote una lista de marcas/modelos recibidas del servidor o archivo.
  Future<int> insertMarcasModelosBatch(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return 0;
    try {
      final db = await _ensureInit();
      final batch = db.batch();
      int count = 0;
      for (final it in items) {
        final m = (it['marca'] as String? ?? '').trim();
        final mod = (it['modelo'] as String? ?? '').trim();
        if (m.isNotEmpty && mod.isNotEmpty) {
          batch.insert(
            'catalogo_marcas_modelos',
            {'marca': m, 'modelo': mod},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          count++;
        }
      }
      await batch.commit(noResult: true);
      return count;
    } catch (e) {
      debugPrint('[LocalDB] Error insertMarcasModelosBatch: $e');
      return 0;
    }
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