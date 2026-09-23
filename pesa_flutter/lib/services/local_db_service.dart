// lib/services/local_db_service.dart — SQLite offline-first
// Replica el esquema de PostgreSQL en el dispositivo Android.
import 'dart:convert';
import 'dart:math';
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

  Future<void> init() async {
    // [FIX] getDatabasesPath() puede fallar en Android 11+ si los permisos
    // aún no están resueltos. El try/catch en main.dart captura este error.
    final dbPath = p.join(await getDatabasesPath(), 'pesa_local.db');
    _db = await openDatabase(
      dbPath,
      version: 6,   // v6: schema limpio — DROP+CREATE para forzar migracion en APK v4.0.0 -> v3.0.0
      // ── onConfigure: único lugar donde SQLite acepta PRAGMAs globales ──────
      // journal_mode = WAL NO puede ejecutarse dentro de una transacción
      // (onCreate / onUpgrade están envueltos en una tx implícita por sqflite).
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // PRAGMA journal_mode = WAL eliminado: el driver nativo de Android
        // no permite ejecutarlo via execute(); sqflite lo gestiona por defecto.
      },
      onCreate: (db, version) async {
        // Solo DDL e INSERT de seed — NO PRAGMAs globales aquí
        await db.execute('''
          CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
        await db.execute('''
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
            sync_version           INTEGER DEFAULT 0,
            sync_status            TEXT DEFAULT 'SINCRONIZADO',
            updated_at             TEXT
          )
        ''');
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
        // Generar device_id unico
        final devId = _generateUuid();
        await db.insert('meta', {'key': 'device_id', 'value': devId});
      },
      // [FIX] onUpgrade: agregar columnas faltantes a BDs existentes sin DROP
      onUpgrade: (db, oldVersion, newVersion) async {
        // ── v6: Schema limpio — drop+recreate para solucionar migraciones corruptas
        // Se ejecuta si el usuario viene de CUALQUIER version anterior a 6.
        // Los datos locales se pierden pero se re-descargan del servidor al sincronizar.
        final colMigrations = [
          // v2/v3 migraciones previas (toleradas con try/catch si ya existen)
          'ALTER TABLE ordenes_servicio ADD COLUMN nombre_ing TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN puesto_ing TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN pdf_path_local TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN pdf_url TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN marca TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN modelo TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN ns TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN ubicacion TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN alcance_max REAL',
          'ALTER TABLE ordenes_servicio ADD COLUMN div_minima REAL',
          'ALTER TABLE ordenes_servicio ADD COLUMN div_verificacion REAL',
          'ALTER TABLE ordenes_servicio ADD COLUMN numero_cca TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN holograma_anterior TEXT',
          'ALTER TABLE firmas_pendientes ADD COLUMN nombre_ing TEXT',
          'ALTER TABLE firmas_pendientes ADD COLUMN puesto_ing TEXT',
          // v3
          'ALTER TABLE ordenes_servicio ADD COLUMN modalidad TEXT DEFAULT \'DIGITAL\'',
          'ALTER TABLE ordenes_servicio ADD COLUMN clase_exactitud TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN tipo_instrumento TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN updated_at TEXT',
          // v4: Offline-First v2 — unidad, firma descargada, pdf local b64
          'ALTER TABLE ordenes_servicio ADD COLUMN unidad_medida TEXT DEFAULT \'kg\'',
          'ALTER TABLE ordenes_servicio ADD COLUMN firma_tecnico_descargada TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN pdf_b64_local TEXT',
          // v5: campos de instrumento precargados por logística
          'ALTER TABLE ordenes_servicio ADD COLUMN id_equipo TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN instrumento_capacidad TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN instrumento_division TEXT',
          'ALTER TABLE ordenes_servicio ADD COLUMN secciones_camionera INTEGER DEFAULT 0',
          'ALTER TABLE ordenes_servicio ADD COLUMN num_secciones INTEGER DEFAULT 0',
        ];
        // [v6] Si venimos de version < 6, hacer DROP+CREATE para limpiar schema corrupto
        if (oldVersion < 6) {
          await db.execute('DROP TABLE IF EXISTS ordenes_servicio');
          await db.execute('''
            CREATE TABLE ordenes_servicio (
              local_id               INTEGER PRIMARY KEY AUTOINCREMENT,
              folio_os               TEXT UNIQUE NOT NULL,
              estado                 TEXT DEFAULT \'PROCESO\',
              modalidad              TEXT DEFAULT \'DIGITAL\',
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
              unidad_medida          TEXT DEFAULT \'kg\',
              firma_tecnico_descargada TEXT,
              pdf_b64_local          TEXT,
              sync_version           INTEGER DEFAULT 0,
              sync_status            TEXT DEFAULT \'SINCRONIZADO\',
              updated_at             TEXT
            )
          ''');
          return; // Schema ya es correcto, no aplicar ALTER TABLEs
        }
        for (final sql in colMigrations) {
          try { await db.execute(sql); } catch (_) {}
        }
      },
    );
  }

  bool _initializing = false;

  /// Lazy init: abre la BD si aun no está lista.
  /// Seguro ante llamadas concurrentes (espera a que termine la primera).
  Future<Database> _ensureInit() async {
    if (_db != null) return _db!;
    // Si ya hay un init en curso, esperar hasta que termine
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

  Future<void> upsertOs(Map<String, dynamic> data) async {
    // [FIX] Tolerancia a variaciones de nombre de campo que devuelve el API
    final sucursal  = data['sucursal_nombre'] ?? data['sucursal'] ?? '';
    final cliente   = data['cliente'] ?? data['cliente_nombre'] ?? '';
    final tecnico   = data['tecnico'] ?? data['tecnico_nombre'] ?? '';
    final tipoSvc   = data['tipo_servicio'] ?? data['tipo_servicio_nombre'] ?? '';

    final row = {
      'folio_os':          data['folio_os'] ?? '',
      'estado':            data['estado'] ?? 'PROCESO',
      'modalidad':         data['modalidad'] ?? 'DIGITAL',
      'fecha':             data['fecha'],
      'cliente':           cliente,
      'sucursal':          sucursal,
      'tecnico':           tecnico,
      'tipo_servicio':     tipoSvc,
      'tipo_instrumento':  data['tipo_instrumento'],
      'aplica_excentricidad': data['aplica_excentricidad'] == true ? 1 : 0,
      'num_celdas_camionera': data['num_celdas_camionera'] ?? 0,
      'clase_exactitud':   data['clase_exactitud_codigo'],
      'observaciones':     data['observaciones'],
      // ── Datos del instrumento (v3) ─────────────────────────────────────────
      'marca':             data['marca'],
      'modelo':            data['modelo'],
      'ns':                data['ns'] ?? data['serie'],
      'ubicacion':         data['ubicacion'],
      'id_equipo':         data['id_equipo'],
      'alcance_max':       data['alcance_max'] ?? data['capacidad_maxima'],
      'div_minima':        data['div_minima'] ?? data['division_minima'],
      'div_verificacion':  data['div_verificacion'],
      'numero_cca':        data['numero_cca'],
      'holograma_anterior': data['holograma_anterior'],
      'pdf_url':           data['pdf_url'],
      // ── Campos precargados por logística (v5) ──────────────────────────────
      'instrumento_capacidad': data['instrumento_capacidad'],
      'instrumento_division':  data['instrumento_division'],
      'secciones_camionera':   data['secciones_camionera'] ?? data['num_celdas_camionera'] ?? 0,
      'num_secciones':         data['num_secciones'] ?? 0,
      // Offline-First v2
      'unidad_medida':     data['unidad_medida'] ?? 'kg',
      if (data['firma_tecnico_descargada'] != null)
        'firma_tecnico_descargada': data['firma_tecnico_descargada'],
      // Sync
      'sync_version':      data['sync_version'] ?? 0,
      'sync_status':       'SINCRONIZADO',
      'updated_at':        data['updated_at']?.toString(),
    };

    final db = await _ensureInit();
    await db.insert(
      'ordenes_servicio',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAllOs() async {
    final db = await _ensureInit();
    // Ordenar por último número del folio (ej. OS-26-645 > OS-26-551)
    // usando CAST en SQLite para extraer el consecutivo
    return await db.rawQuery(
      "SELECT * FROM ordenes_servicio "
      "ORDER BY CAST(SUBSTR(folio_os, INSTR(folio_os, '-', INSTR(folio_os, '-') + 1) + 1) AS INTEGER) DESC, "
      "fecha DESC",
    );
  }

  /// Devuelve solo las órdenes asignadas al técnico por nombre completo.
  /// Si el nombre está vacío, devuelve TODAS (caso admin).
  /// [FIX] Ya no hace fallback a TODAS cuando matched=[] — antes ocultaba el bug.
  Future<List<Map<String, dynamic>>> getOsForTecnico(String nombreTecnico) async {
    final db = await _ensureInit();
    final rows = await db.rawQuery(
      "SELECT * FROM ordenes_servicio "
      "ORDER BY CAST(SUBSTR(folio_os, INSTR(folio_os, '-', INSTR(folio_os, '-') + 1) + 1) AS INTEGER) DESC, "
      "fecha DESC",
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
        if (firmaClienteNombre != null && firmaClienteNombre.isNotEmpty)
          'firma_cliente_nombre': firmaClienteNombre,
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


  // ── Guardar ruta del PDF generado on-device ───────────────────────────────

  Future<void> savePdfPath(int localId, String pdfPath) async {
    final db = await _ensureInit();
    await db.update(
      'ordenes_servicio',
      {
        'pdf_path_local': pdfPath,
        'sync_status': 'PENDIENTE_ACTUALIZAR',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
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