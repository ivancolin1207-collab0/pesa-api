// lib/services/local_db_service.dart — SQLite offline-first
// Replica el esquema de PostgreSQL en el dispositivo Android.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'metrology_helper.dart';

class LocalDbService {
  static final LocalDbService instance = LocalDbService._();
  LocalDbService._();
  Database? _db;

  // ── Schema — se aplica en onCreate / onUpgrade (ver método init()) ─────────
  // Las sentencias DDL se ejecutan individualmente para evitar problemas con
  // el split por ';' al incluir PRAGMA y comentarios SQL multilínea.

  // ── Inicializacion ────────────────────────────────────────────────────────

  String? lastUpsertError;

  /// Función auxiliar de normalización de cadenas (remover diacríticos/acentos y minúsculas)
  static String normalizarTexto(String texto) {
    var conAcentos = 'ÁÉÍÓÚáéíóúÀÈÌÒÙàèìòùÄËÏÖÜäëïöüÑñ';
    var sinAcentos = 'AEIOUaeiouAEIOUaeiouAEIOUaeiouNn';
    String resultado = texto.trim().toLowerCase();
    for (int i = 0; i < conAcentos.length; i++) {
      resultado = resultado.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return resultado;
  }

  /// Normaliza la modalidad respetando estrictamente el valor recibido del backend.
  static String normalizarModalidad(dynamic rawVal) {
    final String rem = (rawVal ?? '').toString().trim().toLowerCase();
    if (rem.contains('digital')) return 'Digital';
    if (rem.contains('fisic') || rem.contains('físic')) return 'Fisico';
    return 'Digital';
  }

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
      direccion              TEXT,
      tecnico                TEXT,
      tipo_servicio          TEXT,
      id_tipo_servicio       INTEGER,
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
      numero_dve             TEXT,
      motivo_no_excentricidad TEXT,
      id_cliente             INTEGER,
      sucursal_id            INTEGER,
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
      correo_cliente         TEXT,
      correo_destino         TEXT,
      correo_cc              TEXT DEFAULT 'recepcion@basculaspesa.com.mx',
      email_enviado          INTEGER DEFAULT 0,
      correo_enviado         INTEGER DEFAULT 0,
      fecha_envio_email      TEXT,
      fecha_envio_correo     TEXT,
      sync_check_status      TEXT DEFAULT 'ASIGNADA',
      fecha_descarga_tablet  TEXT,
      fecha_subida_servidor  TEXT,
      fecha_apertura_admin   TEXT,
      sync_version           INTEGER DEFAULT 0,
      sync_status            TEXT DEFAULT 'SINCRONIZADO',
      needs_push             INTEGER DEFAULT 0,
      is_synced              INTEGER DEFAULT 0,
      is_dirty               INTEGER DEFAULT 0,
      partidas               TEXT,
      tipo_documento         TEXT,
      datos_tecnicos_json    TEXT,
      fecha_servicio         TEXT,
      fecha_cierre           TEXT,
      fecha_creacion_logistica TEXT,
      updated_at             TEXT
    )
  ''';

  /// Tabla de borradores offline. Se crea en onCreate, onOpen y en cada
  /// _ensureInit() para tablets con BD previa (sin desinstalar ni perder datos).
  static const _createTableBorradoresSql = '''
    CREATE TABLE IF NOT EXISTS borradores_captura (
      folio_os TEXT PRIMARY KEY,
      draft_json TEXT,
      updated_at TEXT
    )
  ''';

  bool _borradoresVerificada = false;
  bool _adminTablesVerificada = false;

  static const Set<String> _loteLimpiarManualFolios = {
    'OS-26-725', 'OS-26-726', 'OS-26-727', 'OS-26-728',
    'OS-26-729', 'OS-26-730', 'OS-26-731', 'OS-26-732',
  };

  Future<void> _asegurarTablaBorradores(Database db) async {
    try {
      await db.execute(_createTableBorradoresSql);
      try {
        await db.execute('ALTER TABLE ordenes_servicio ADD COLUMN id INTEGER');
      } catch (_) {}
      await _limpiarLoteInstrumentosClonados(db);
      await _limpiarBorradoresOsobCorruptos(db);
      _borradoresVerificada = true;
    } catch (e) {
      debugPrint('[LocalDB] Error creando borradores_captura: $e');
    }
  }

  /// Limpia borradores corruptos de RMA guardados por error en folios OSOB-%
  /// y corrige tipo_documento = 'OSOB' en ordenes_servicio.
  Future<void> _limpiarBorradoresOsobCorruptos(Database db) async {
    try {
      await db.rawDelete('''
        DELETE FROM borradores_captura
        WHERE UPPER(folio_os) LIKE 'OSOB-%'
          AND (
            draft_json LIKE '%"partidas"%'
            OR draft_json LIKE '%"items"%'
            OR draft_json NOT LIKE '%"checklist_inspeccion"%'
          )
      ''');
      await db.rawUpdate('''
        UPDATE ordenes_servicio
        SET tipo_documento = 'OSOB',
            partidas = NULL
        WHERE UPPER(folio_os) LIKE 'OSOB-%'
      ''');
    } catch (e) {
      debugPrint('[LocalDB] Aviso en _limpiarBorradoresOsobCorruptos: $e');
    }
  }

  /// Limpia datos clonados previos ("Kubota / KS-C880-P / Báscula colgante")
  /// en los folios OS-26-725 a OS-26-732 que aún no estén cerrados,
  /// dejando la captura 100% manual y libre para el técnico.
  Future<void> _limpiarLoteInstrumentosClonados(Database db) async {
    try {
      const folios = [
        'OS-26-725', 'OS-26-726', 'OS-26-727', 'OS-26-728',
        'OS-26-729', 'OS-26-730', 'OS-26-731', 'OS-26-732',
      ];
      final ph = List.filled(folios.length, '?').join(',');
      await db.rawUpdate('''
        UPDATE ordenes_servicio
        SET marca = '',
            modelo = '',
            ns = '',
            id_equipo = '',
            ubicacion = '',
            tipo_instrumento = '',
            alcance_max = NULL,
            div_minima = NULL,
            instrumento_capacidad = '',
            instrumento_division = '',
            aplica_excentricidad = 1,
            usa_sustitucion = 0
        WHERE folio_os IN ($ph)
          AND UPPER(COALESCE(estado, '')) NOT IN ('CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA')
          AND COALESCE(pdf_path_local, '') = ''
          AND (
            LOWER(COALESCE(marca, '')) = 'kubota'
            OR LOWER(COALESCE(modelo, '')) = 'ks-c880-p'
            OR LOWER(COALESCE(id_equipo, '')) = 'slitter 2'
            OR COALESCE(datos_tecnicos_json, '') LIKE '%"instrumento_limpio_manual": true%'
            OR COALESCE(datos_tecnicos_json, '') LIKE '%"instrumento_limpio_manual":true%'
          )
      ''', folios);

      await db.rawDelete('''
        DELETE FROM borradores_captura
        WHERE folio_os IN ($ph)
          AND (
            LOWER(COALESCE(draft_json, '')) LIKE '%kubota%'
            OR LOWER(COALESCE(draft_json, '')) LIKE '%ks-c880-p%'
            OR LOWER(COALESCE(draft_json, '')) LIKE '%slitter 2%'
            OR COALESCE(draft_json, '') LIKE '%"instrumento_limpio_manual"%'
          )
      ''', folios);
    } catch (e) {
      debugPrint('[LocalDB] _limpiarLoteInstrumentosClonados warning: $e');
    }
  }

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
          await db.execute('DROP TRIGGER IF EXISTS tr_update_ordenes_view');
          await db.execute('''
            CREATE TRIGGER IF NOT EXISTS tr_update_ordenes_view
            INSTEAD OF UPDATE ON ordenes
            BEGIN
              UPDATE ordenes_servicio
              SET 
                fecha = COALESCE(NEW.fecha, ordenes_servicio.fecha),
                fecha_servicio = COALESCE(NEW.fecha_servicio, NEW.fecha, ordenes_servicio.fecha_servicio),
                fecha_cierre = COALESCE(NEW.fecha_cierre, ordenes_servicio.fecha_cierre),
                fecha_creacion_logistica = COALESCE(NEW.fecha_creacion_logistica, ordenes_servicio.fecha_creacion_logistica),
                estatus = COALESCE(NEW.estatus, ordenes_servicio.estatus),
                estado = CASE 
                  WHEN NEW.estatus IN ('Cerrado', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL') THEN 'COMPLETADA_DIGITAL'
                  WHEN NEW.estado IS NOT NULL AND NEW.estado != '' THEN NEW.estado
                  ELSE ordenes_servicio.estado
                END,
                tecnico = COALESCE(NEW.tecnico, ordenes_servicio.tecnico),
                has_pdf = COALESCE(NEW.has_pdf, ordenes_servicio.has_pdf),
                pdf_url = COALESCE(NEW.pdf_url, ordenes_servicio.pdf_url),
                modalidad = COALESCE(NEW.modalidad, ordenes_servicio.modalidad),
                sync_status = COALESCE(NEW.sync_status, ordenes_servicio.sync_status),
                sync_check_status = CASE
                  WHEN NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 'SUBIDA_SERVIDOR'
                  WHEN NEW.sync_check_status IS NOT NULL AND NEW.sync_check_status != '' THEN NEW.sync_check_status
                  ELSE ordenes_servicio.sync_check_status
                END,
                needs_push = COALESCE(NEW.needs_push, ordenes_servicio.needs_push),
                is_dirty = CASE
                  WHEN NEW.needs_push = 0 OR NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 0
                  ELSE ordenes_servicio.is_dirty
                END,
                is_synced = CASE
                  WHEN NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 1
                  ELSE ordenes_servicio.is_synced
                END,
                updated_at = datetime('now')
              WHERE folio_os = OLD.folio_os OR folio_os = OLD.folio OR folio = OLD.folio;
            END;
          ''');
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
        await db.execute(_createTableBorradoresSql);
        await _asegurarTablasCatalogosAdmin(db);
        await _asegurarIndicesRendimiento(db);
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
        // Salvaguarda: tablets con BD existente crean la tabla de borradores al abrir
        await _asegurarTablaBorradores(db);
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
            'numero_dve': 'TEXT',
            'motivo_no_excentricidad': 'TEXT',
            'id_cliente': 'INTEGER',
            'sucursal_id': 'INTEGER',
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
            'id_tipo_servicio': 'INTEGER',
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
            'correo_cliente': 'TEXT',
            'correo_destino': 'TEXT',
            'correo_cc': "TEXT DEFAULT 'recepcion@basculaspesa.com.mx'",
            'email_enviado': 'INTEGER DEFAULT 0',
            'correo_enviado': 'INTEGER DEFAULT 0',
            'fecha_envio_email': 'TEXT',
            'fecha_envio_correo': 'TEXT',
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
            'needs_push': 'INTEGER DEFAULT 0',
            'sync_status': "TEXT DEFAULT 'SINCRONIZADO'",
            'partidas': 'TEXT',
            'tipo_documento': 'TEXT',
            'datos_tecnicos_json': 'TEXT',
            'fecha_servicio': 'TEXT',
            'fecha_cierre': 'TEXT',
            'fecha_creacion_logistica': 'TEXT',
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

          // Crear vista 'ordenes' y trigger INSTEAD OF UPDATE para compatibilidad total
          try {
            await db.execute('DROP TRIGGER IF EXISTS tr_update_ordenes_view');
            await db.execute('DROP VIEW IF EXISTS ordenes');
            await db.execute('CREATE VIEW IF NOT EXISTS ordenes AS SELECT *, folio_os AS folio, estado AS estatus FROM ordenes_servicio');
            await db.execute('''
              CREATE TRIGGER IF NOT EXISTS tr_update_ordenes_view
              INSTEAD OF UPDATE ON ordenes
              BEGIN
                UPDATE ordenes_servicio
                SET 
                  fecha = COALESCE(NEW.fecha, ordenes_servicio.fecha),
                  fecha_servicio = COALESCE(NEW.fecha_servicio, NEW.fecha, ordenes_servicio.fecha_servicio),
                  fecha_cierre = COALESCE(NEW.fecha_cierre, ordenes_servicio.fecha_cierre),
                  fecha_creacion_logistica = COALESCE(NEW.fecha_creacion_logistica, ordenes_servicio.fecha_creacion_logistica),
                  estatus = COALESCE(NEW.estatus, ordenes_servicio.estatus),
                  estado = CASE 
                    WHEN NEW.estatus IN ('Cerrado', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL') THEN 'COMPLETADA_DIGITAL'
                    WHEN NEW.estado IS NOT NULL AND NEW.estado != '' THEN NEW.estado
                    ELSE ordenes_servicio.estado
                  END,
                  tecnico = COALESCE(NEW.tecnico, ordenes_servicio.tecnico),
                  has_pdf = COALESCE(NEW.has_pdf, ordenes_servicio.has_pdf),
                  pdf_url = COALESCE(NEW.pdf_url, ordenes_servicio.pdf_url),
                  modalidad = COALESCE(NEW.modalidad, ordenes_servicio.modalidad),
                  sync_status = COALESCE(NEW.sync_status, ordenes_servicio.sync_status),
                  sync_check_status = CASE
                    WHEN NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 'SUBIDA_SERVIDOR'
                    WHEN NEW.sync_check_status IS NOT NULL AND NEW.sync_check_status != '' THEN NEW.sync_check_status
                    ELSE ordenes_servicio.sync_check_status
                  END,
                  needs_push = COALESCE(NEW.needs_push, ordenes_servicio.needs_push),
                  is_dirty = CASE
                    WHEN NEW.needs_push = 0 OR NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 0
                    ELSE ordenes_servicio.is_dirty
                  END,
                  is_synced = CASE
                    WHEN NEW.sync_status IN ('Enviada', 'ENVIADA', 'Sincronizado', 'SINCRONIZADO') THEN 1
                    ELSE ordenes_servicio.is_synced
                  END,
                  updated_at = datetime('now')
                WHERE folio_os = OLD.folio_os OR folio_os = OLD.folio OR folio = OLD.folio;
              END;
            ''');
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
            // Actualización correctiva para orden OS-26-701
            await db.rawUpdate(
              "UPDATE ordenes_servicio SET id_tecnico = 9, tecnico = 'Néstor Arias', sync_status = 'Asignada' WHERE (folio_os = 'OS-26-701' OR folio = 'OS-26-701')",
            );
          } catch (e) {
            debugPrint('[LocalDB] Backfill id_tecnico error: $e');
          }
          await _asegurarIndicesRendimiento(db);
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
        await _asegurarTablasCatalogosAdmin(db);
      },
    );
  }

  Future<void> _asegurarTablasCatalogosAdmin(Database db) async {
    if (_adminTablesVerificada) return;
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS catalogo_clientes (
          id              INTEGER PRIMARY KEY,
          nombre          TEXT NOT NULL,
          razon_social    TEXT,
          rfc             TEXT,
          correo          TEXT,
          telefono        TEXT,
          direccion       TEXT,
          sucursales_json TEXT,
          updated_at      TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS catalogo_sucursales (
          id              INTEGER PRIMARY KEY AUTOINCREMENT,
          sucursal_id     INTEGER,
          cliente_id      INTEGER,
          cliente_nombre  TEXT,
          nombre          TEXT,
          direccion       TEXT,
          ciudad          TEXT,
          contacto        TEXT,
          telefono        TEXT,
          correo          TEXT,
          UNIQUE(cliente_id, nombre, direccion) ON CONFLICT REPLACE
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_cat_sucursales_cli ON catalogo_sucursales(cliente_id, cliente_nombre)
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS catalogo_tecnicos (
          id       INTEGER PRIMARY KEY,
          nombre   TEXT NOT NULL,
          username TEXT,
          rol      TEXT,
          activo   INTEGER DEFAULT 1
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS catalogo_tipos_servicio (
          id     INTEGER PRIMARY KEY,
          nombre TEXT NOT NULL,
          codigo TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS catalogo_tipos_instrumento (
          id                   INTEGER PRIMARY KEY,
          nombre               TEXT NOT NULL,
          aplica_excentricidad INTEGER DEFAULT 1
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS historial_instrumentos (
          id               INTEGER PRIMARY KEY AUTOINCREMENT,
          cliente_id       INTEGER,
          cliente_nombre   TEXT NOT NULL DEFAULT '',
          sucursal_id      INTEGER,
          sucursal_nombre  TEXT NOT NULL DEFAULT '',
          marca            TEXT NOT NULL DEFAULT '',
          modelo           TEXT NOT NULL DEFAULT '',
          serie            TEXT NOT NULL DEFAULT '',
          id_indicador     TEXT NOT NULL DEFAULT '',
          capacidad_maxima TEXT NOT NULL DEFAULT '',
          division_minima  TEXT NOT NULL DEFAULT '',
          ubicacion        TEXT NOT NULL DEFAULT '',
          tipo_instrumento TEXT NOT NULL DEFAULT '',
          numero_cca       TEXT NOT NULL DEFAULT '',
          numero_dve       TEXT NOT NULL DEFAULT '',
          updated_at       TEXT,
          UNIQUE(cliente_nombre, marca, modelo, serie, id_indicador, ubicacion) ON CONFLICT REPLACE
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_hist_inst_cliente ON historial_instrumentos(cliente_nombre, sucursal_nombre)
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cola_instrumento_parcial (
          folio_os     TEXT PRIMARY KEY,
          payload_json TEXT NOT NULL,
          updated_at   TEXT NOT NULL
        )
      ''');

      // Poblar historial_instrumentos inicialmente desde ordenes_servicio si está vacío
      final cntHist = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM historial_instrumentos'),
      ) ?? 0;
      if (cntHist == 0) {
        await db.execute('''
          INSERT OR IGNORE INTO historial_instrumentos (
            cliente_nombre, sucursal_nombre, marca, modelo, serie, id_indicador,
            capacidad_maxima, division_minima, ubicacion, tipo_instrumento,
            numero_cca, numero_dve, updated_at
          )
          SELECT DISTINCT
            COALESCE(TRIM(cliente), ''),
            COALESCE(NULLIF(TRIM(sucursal), ''), TRIM(direccion), ''),
            COALESCE(TRIM(marca), ''),
            COALESCE(TRIM(modelo), ''),
            COALESCE(TRIM(ns), ''),
            COALESCE(TRIM(id_equipo), ''),
            COALESCE(NULLIF(TRIM(instrumento_capacidad), ''), CAST(alcance_max AS TEXT), ''),
            COALESCE(NULLIF(TRIM(instrumento_division), ''), CAST(div_minima AS TEXT), ''),
            COALESCE(TRIM(ubicacion), ''),
            COALESCE(TRIM(tipo_instrumento), ''),
            COALESCE(TRIM(numero_cca), ''),
            COALESCE(TRIM(numero_dve), ''),
            COALESCE(updated_at, datetime('now'))
          FROM ordenes_servicio
          WHERE (marca IS NOT NULL AND TRIM(marca) != '')
             OR (modelo IS NOT NULL AND TRIM(modelo) != '')
             OR (ns IS NOT NULL AND TRIM(ns) != '')
             OR (id_equipo IS NOT NULL AND TRIM(id_equipo) != '')
        ''');
      }
      _adminTablesVerificada = true;
    } catch (e) {
      debugPrint('[LocalDB] _asegurarTablasCatalogosAdmin error: $e');
    }
  }

  /// Crea los índices SQLite de alto rendimiento y sanea destinatarios genéricos ('Cliente').
  Future<void> _asegurarIndicesRendimiento(Database db) async {
    const ddl = <String>[
      'CREATE INDEX IF NOT EXISTS idx_ordenes_folio ON ordenes_servicio(folio_os)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_folio_alt ON ordenes_servicio(folio)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_lote ON ordenes_servicio(id_lote)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_estatus ON ordenes_servicio(estatus)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_fecha ON ordenes_servicio(fecha DESC)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_cliente ON ordenes_servicio(cliente)',
      'CREATE INDEX IF NOT EXISTS idx_ordenes_updated_at ON ordenes_servicio(updated_at DESC)',
    ];
    for (final stmt in ddl) {
      try {
        await db.execute(stmt);
      } catch (e) {
        debugPrint('[LocalDB] Error creando índice ($stmt): $e');
      }
    }
    try {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_ordenes_v_folio ON ordenes(folio)');
    } catch (_) {}

    // Saneamiento local de valores genéricos ('Cliente', 'Sin registrar') en correo_destino / correo_cliente
    try {
      await db.execute('''
        UPDATE ordenes_servicio
        SET correo_destino = NULL
        WHERE LOWER(TRIM(COALESCE(correo_destino, ''))) IN ('cliente', 'sin registrar', 'destinatario registrado', 'none', 'null', '-', '—')
      ''');
      await db.execute('''
        UPDATE ordenes_servicio
        SET correo_cliente = NULL
        WHERE LOWER(TRIM(COALESCE(correo_cliente, ''))) IN ('cliente', 'sin registrar', 'destinatario registrado', 'none', 'null', '-', '—')
      ''');
      await db.execute('''
        UPDATE ordenes_servicio
        SET correo_destino = correo_cliente
        WHERE (correo_destino IS NULL OR TRIM(correo_destino) = '')
          AND correo_cliente IS NOT NULL AND correo_cliente LIKE '%@%'
      ''');
      await db.execute('''
        UPDATE ordenes_servicio
        SET correo_destino = (
          SELECT c.email FROM cat_clientes_local c
          WHERE LOWER(TRIM(c.nombre)) = LOWER(TRIM(ordenes_servicio.cliente))
            AND c.email IS NOT NULL AND c.email LIKE '%@%'
          LIMIT 1
        )
        WHERE (correo_enviado = 1 OR email_enviado = 1)
          AND (correo_destino IS NULL OR TRIM(correo_destino) = '')
      ''');
      await db.execute('''
        UPDATE ordenes_servicio
        SET correo_destino = (
          SELECT o2.correo_destino FROM ordenes_servicio o2
          WHERE LOWER(TRIM(o2.cliente)) = LOWER(TRIM(ordenes_servicio.cliente))
            AND o2.correo_destino IS NOT NULL AND o2.correo_destino LIKE '%@%'
          ORDER BY o2.fecha_envio_correo DESC
          LIMIT 1
        )
        WHERE (correo_enviado = 1 OR email_enviado = 1)
          AND (correo_destino IS NULL OR TRIM(correo_destino) = '')
      ''');
    } catch (e) {
      debugPrint('[LocalDB] Saneamiento de correos locales: $e');
    }
  }

  bool _initializing = false;

  /// Lazy init: abre la BD si aun no está lista.
  /// Seguro ante llamadas concurrentes (espera a que termine la primera).
  Future<Database> _ensureInit() async {
    if (_db != null) {
      if (!_borradoresVerificada) await _asegurarTablaBorradores(_db!);
      if (!_adminTablesVerificada) await _asegurarTablasCatalogosAdmin(_db!);
      return _db!;
    }
    while (_initializing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_db != null) {
      if (!_borradoresVerificada) await _asegurarTablaBorradores(_db!);
      if (!_adminTablesVerificada) await _asegurarTablasCatalogosAdmin(_db!);
      return _db!;
    }
    _initializing = true;
    try {
      await init();
    } finally {
      _initializing = false;
    }
    // Salvaguarda obligatoria antes de devolver la instancia
    await _asegurarTablaBorradores(_db!);
    await _asegurarTablasCatalogosAdmin(_db!);
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

    // [PULL PROTEGIDO] Folios trabajados localmente (cerrados, sucios, con PDF,
    // mediciones o firmas) NUNCA se reemplazan con REPLACE: se fusionan vía upsertOs.
    final protegidos = <String>{};
    try {
      final locales = await db.rawQuery('''
        SELECT folio_os FROM ordenes_servicio
        WHERE COALESCE(is_dirty, 0) = 1
           OR UPPER(COALESCE(estado, '')) IN ('CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA')
           OR UPPER(COALESCE(estatus, '')) IN ('CERRADO','CERRADA','COMPLETADA')
           OR COALESCE(pdf_path_local, '') <> ''
           OR COALESCE(pdf_b64_local, '') <> ''
           OR COALESCE(rep_json, '') NOT IN ('', '[]', 'null')
           OR COALESCE(exac_json, '') NOT IN ('', '[]', 'null')
           OR COALESCE(firma_cliente, '') <> ''
      ''');
      for (final r in locales) {
        final f = (r['folio_os'] as String? ?? '').trim();
        if (f.isNotEmpty) protegidos.add(f);
      }
      final parciales = await db.rawQuery('SELECT folio_os FROM cola_instrumento_parcial');
      for (final r in parciales) {
        final f = (r['folio_os'] as String? ?? '').trim();
        if (f.isNotEmpty) protegidos.add(f);
      }
    } catch (e) {
      debugPrint('[LocalDB] insertOrdenesBatch: no se pudo leer protegidos ($e)');
    }
    final pendientesMerge = <Map<String, dynamic>>[];

    int count = 0;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final raw in listaJson) {
        final folio = (raw['folio_os'] ?? raw['folio'])?.toString().trim();
        if (folio == null || folio.isEmpty) continue;
        if (protegidos.contains(folio)) {
          pendientesMerge.add(raw);
          continue;
        }

        final cliente   = (raw['cliente'] ?? raw['cliente_nombre'] ?? '').toString();
        final sucursal  = (raw['sucursal'] ?? raw['sucursal_nombre'] ?? '').toString();
        final tecnico   = (raw['tecnico'] ?? raw['tecnico_nombre'] ?? '').toString();
        final tipoSvc   = (raw['tipo_servicio'] ?? raw['tipo_servicio_nombre'] ?? raw['tipo'] ?? '').toString().trim();
        final idTipoSvc = _toIntOrNull(raw['id_tipo_servicio'] ?? raw['tipo_servicio_id']);
        final direccion = (raw['direccion'] ?? raw['direccion_cliente'] ?? raw['sucursal_direccion'] ?? raw['planta'] ?? raw['domicilio'] ?? '').toString();

        final String finalSucursal = sucursal.trim().isNotEmpty ? sucursal.trim() : (direccion.trim().isNotEmpty ? direccion.trim() : '');
        final String finalDireccion = direccion.trim().isNotEmpty ? direccion.trim() : (sucursal.trim().isNotEmpty ? sucursal.trim() : '');

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

        final String modNorm = normalizarModalidad(raw['modalidad']);

        final String? pdfUrlRaw = raw['pdf_url']?.toString().trim();
        final String? pdfB64Raw = (raw['pdf_base64'] ?? raw['pdf_b64'] ?? raw['pdf_b64_local'])?.toString().trim();
        final String? pdfPathRaw = (raw['pdf_path_local'] ?? raw['pdf_path'])?.toString().trim();

        final bool hasPdfRemoto = (pdfUrlRaw != null && pdfUrlRaw.isNotEmpty && !pdfUrlRaw.contains('null') && !pdfUrlRaw.contains('404')) ||
                                  (pdfB64Raw != null && pdfB64Raw.isNotEmpty && pdfB64Raw.length > 100) ||
                                  (pdfPathRaw != null && pdfPathRaw.isNotEmpty && File(pdfPathRaw).existsSync() && File(pdfPathRaw).lengthSync() > 500);

        final bool esCerrada = hasPdfRemoto;
        final String rawEstatus = (raw['estatus'] ?? '').toString().trim();
        final String finalEstatus = esCerrada
            ? 'Cerrado'
            : (rawEstatus.isNotEmpty ? rawEstatus : 'Asignada');
        final String finalEstado = esCerrada ? 'COMPLETADA_DIGITAL' : 'PROCESO';

        final mapped = <String, dynamic>{
          'id':                _toIntOrNull(raw['id']),
          'folio_os':          folio,
          'folio':             folio,
          'id_tecnico':        idTecnicoFinal,
          'estado':            finalEstado,
          'estatus':           finalEstatus,
          'has_pdf':           esCerrada ? 1 : 0,
          'modalidad':         modNorm,
          'fecha':             raw['fecha']?.toString(),
          'cliente':           cliente,
          'sucursal':          finalSucursal,
          'direccion':         finalDireccion,
          'tecnico':           tecnico,
          'tipo_servicio':     tipoSvc,
          if (idTipoSvc != null && idTipoSvc > 0) 'id_tipo_servicio': idTipoSvc,
          'tipo_instrumento':  raw['tipo_instrumento']?.toString(),
          'aplica_excentricidad': _toBoolInt(raw['aplica_excentricidad']),
          'num_celdas_camionera': _toInt(raw['num_celdas_camionera'], 0),
          'clase_exactitud':   (raw['clase_exactitud'] ?? raw['clase_exactitud_codigo'])?.toString(),
          'observaciones':     raw['observaciones']?.toString(),
          'marca':             raw['marca']?.toString(),
          'modelo':            raw['modelo']?.toString(),
          'ns':                (raw['ns'] ?? raw['serie'])?.toString(),
          'ubicacion':         raw['ubicacion']?.toString(),
          'id_equipo':         (raw['id_equipo'] ?? raw['id_indicador'])?.toString(),
          'alcance_max':       _toDouble(raw['alcance_max'] ?? raw['capacidad_maxima']),
          'div_minima':        _toDouble(raw['div_minima'] ?? raw['division_minima']),
          'div_verificacion':  _toDouble(raw['div_verificacion'] ?? raw['div_ver']),
          'numero_cca':        (raw['numero_cca'] ?? raw['cca'])?.toString(),
          'numero_dve':        (raw['numero_dve'] ?? raw['folio_dve'])?.toString(),
          'motivo_no_excentricidad': raw['motivo_no_excentricidad']?.toString(),
          if (_toIntOrNull(raw['id_cliente'] ?? raw['cliente_id']) != null)
            'id_cliente': _toIntOrNull(raw['id_cliente'] ?? raw['cliente_id']),
          if (_toIntOrNull(raw['sucursal_id'] ?? raw['id_sucursal']) != null)
            'sucursal_id': _toIntOrNull(raw['sucursal_id'] ?? raw['id_sucursal']),
          'holograma_anterior': raw['holograma_anterior']?.toString(),
          'usa_sustitucion': _toBoolInt(raw['usa_sustitucion']) > 0 || (raw['datos_tecnicos_json'] != null && raw['datos_tecnicos_json'].toString().contains('"es_enlace_sustitucion":true')) || (raw['datos_tecnicos_json'] != null && raw['datos_tecnicos_json'].toString().contains('"es_enlace_sustitucion": true')) ? 1 : 0,
          'factor_sustitucion': _toDouble(raw['factor_sustitucion']),
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
          'tipo_documento':    (raw['tipo_documento'] ?? (folio.toUpperCase().startsWith('OSOCC') ? 'OSOCC' : (folio.toUpperCase().startsWith('OSOB') ? 'OSOB' : (folio.startsWith('RMA') ? 'RMA' : (folio.startsWith('RE') ? 'RE' : (folio.startsWith('LP') ? 'LP' : (folio.startsWith('LV') ? 'LV' : 'OS')))))))?.toString(),
          'datos_tecnicos_json': raw['datos_tecnicos_json']?.toString(),
          'partidas':          raw['partidas'] is String
              ? raw['partidas']
              : (raw['partidas'] != null
                  ? jsonEncode(raw['partidas'])
                  : (raw['refacciones'] is String
                      ? raw['refacciones']
                      : (raw['refacciones'] != null
                          ? jsonEncode(raw['refacciones'])
                          : (raw['items'] is String
                              ? raw['items']
                              : (raw['items'] != null ? jsonEncode(raw['items']) : null))))),
          'sync_check_status': esCerrada ? 'SUBIDA_SERVIDOR' : (raw['sync_check_status']?.toString() ?? 'ASIGNADA'),
          'sync_status':       raw['sync_status']?.toString() ?? 'SINCRONIZADO',
          'correo_enviado':    (raw['correo_enviado'] == true || raw['correo_enviado'] == 1 || raw['correo_enviado'] == '1' || raw['email_enviado'] == true || raw['email_enviado'] == 1 || raw['email_enviado'] == '1') ? 1 : 0,
          'email_enviado':     (raw['correo_enviado'] == true || raw['correo_enviado'] == 1 || raw['correo_enviado'] == '1' || raw['email_enviado'] == true || raw['email_enviado'] == 1 || raw['email_enviado'] == '1') ? 1 : 0,
          if ((raw['correo_destino'] ?? raw['correo_cliente']) != null && (raw['correo_destino'] ?? raw['correo_cliente']).toString().trim().isNotEmpty)
            'correo_destino':  (raw['correo_destino'] ?? raw['correo_cliente']).toString().trim(),
          if ((raw['correo_cliente'] ?? raw['correo_destino']) != null && (raw['correo_cliente'] ?? raw['correo_destino']).toString().trim().isNotEmpty)
            'correo_cliente':  (raw['correo_cliente'] ?? raw['correo_destino']).toString().trim(),
          'correo_cc':         (raw['correo_cc']?.toString().trim().isNotEmpty == true) ? raw['correo_cc'].toString().trim() : 'recepcion@basculaspesa.com.mx',
          if ((raw['fecha_envio_correo'] ?? raw['fecha_envio_email']) != null && (raw['fecha_envio_correo'] ?? raw['fecha_envio_email']).toString().trim().isNotEmpty)
            'fecha_envio_correo': formatearFechaHoraMexico(raw['fecha_envio_correo'] ?? raw['fecha_envio_email']),
          if ((raw['fecha_envio_email'] ?? raw['fecha_envio_correo']) != null && (raw['fecha_envio_email'] ?? raw['fecha_envio_correo']).toString().trim().isNotEmpty)
            'fecha_envio_email':  formatearFechaHoraMexico(raw['fecha_envio_email'] ?? raw['fecha_envio_correo']),
          'is_synced':         1,
          'is_dirty':          0,
          'updated_at':        raw['updated_at']?.toString() ?? DateTime.now().toIso8601String(),
        };

        if (raw['datos_tecnicos_json'] != null) {
          try {
            final dtRaw = raw['datos_tecnicos_json'];
            final dt = dtRaw is String ? jsonDecode(dtRaw) : dtRaw;
            if (dt is Map) {
              if (mapped['partidas'] == null) {
                final p = dt['partidas'] ?? dt['refacciones'] ?? dt['items'];
                if (p != null) {
                  mapped['partidas'] = p is String ? p : jsonEncode(p);
                }
              }
              if ((mapped['tipo_instrumento'] == null || mapped['tipo_instrumento'].toString().trim().isEmpty) &&
                  dt['tipo_instrumento'] != null && dt['tipo_instrumento'].toString().trim().isNotEmpty) {
                mapped['tipo_instrumento'] = dt['tipo_instrumento'].toString().trim();
              }
              if (dt['aplica_excentricidad'] != null) {
                mapped['aplica_excentricidad'] = _toBoolInt(dt['aplica_excentricidad']);
              }
              for (final k in ['marca', 'modelo', 'ns', 'ubicacion', 'id_equipo', 'numero_cca', 'numero_dve', 'motivo_no_excentricidad']) {
                if ((mapped[k] == null || mapped[k].toString().trim().isEmpty) &&
                    dt[k] != null && dt[k].toString().trim().isNotEmpty) {
                  mapped[k] = dt[k].toString().trim();
                }
              }
              if ((mapped['ns'] == null || mapped['ns'].toString().trim().isEmpty) &&
                  dt['serie'] != null && dt['serie'].toString().trim().isNotEmpty) {
                mapped['ns'] = dt['serie'].toString().trim();
              }
              if ((mapped['numero_cca'] == null || mapped['numero_cca'].toString().trim().isEmpty) &&
                  dt['cca'] != null && dt['cca'].toString().trim().isNotEmpty) {
                mapped['numero_cca'] = dt['cca'].toString().trim();
              }
              if ((mapped['numero_dve'] == null || mapped['numero_dve'].toString().trim().isEmpty) &&
                  dt['folio_dve'] != null && dt['folio_dve'].toString().trim().isNotEmpty) {
                mapped['numero_dve'] = dt['folio_dve'].toString().trim();
              }
              if ((mapped['id_equipo'] == null || mapped['id_equipo'].toString().trim().isEmpty) &&
                  dt['id_indicador'] != null && dt['id_indicador'].toString().trim().isNotEmpty) {
                mapped['id_equipo'] = dt['id_indicador'].toString().trim();
              }
            }
          } catch (_) {}
        }

        final safeRow = <String, dynamic>{};
        for (final entry in mapped.entries) {
          if (validCols.contains(entry.key)) {
            safeRow[entry.key] = entry.value;
          }
        }

        batch.insert('ordenes_servicio', safeRow, conflictAlgorithm: ConflictAlgorithm.replace);
        final dt = raw['datos_tecnicos_json'];
        final String dtStr = dt?.toString().trim() ?? '';
        final bool instrumentoVacioServidor = !esCerrada && (
          _loteLimpiarManualFolios.contains(folio) ||
          dtStr.contains('"instrumento_limpio_manual":true') ||
          dtStr.contains('"instrumento_limpio_manual": true') ||
          ((safeRow['marca'] == null || safeRow['marca'].toString().trim().isEmpty) &&
           (safeRow['modelo'] == null || safeRow['modelo'].toString().trim().isEmpty) &&
           (safeRow['tipo_instrumento'] == null || safeRow['tipo_instrumento'].toString().trim().isEmpty))
        );
        if (instrumentoVacioServidor) {
          batch.delete('borradores_captura', where: 'folio_os = ?', whereArgs: [folio]);
        } else if (dtStr.isNotEmpty && dtStr != '{}') {
          batch.insert('borradores_captura', {
            'folio_os': folio,
            'draft_json': dtStr,
            'updated_at': DateTime.now().toUtc().toIso8601String()
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        count++;
      }
      await batch.commit(noResult: true);
    });

    // Fusión protegida (REGLA 1 de upsertOs) para órdenes trabajadas en la tablet.
    for (final raw in pendientesMerge) {
      try {
        if (await upsertOs(raw)) count++;
      } catch (e) {
        debugPrint('[LocalDB] Merge protegido falló para ${raw['folio_os']}: $e');
      }
    }
    await _limpiarLoteInstrumentosClonados(db);
    return count;
  }

  /// Actualiza estrictamente el estatus remoto, PDF y técnico de una orden
  Future<void> updateEstatusYPdfRemoto({
    required String folio,
    required String tecnico,
    required String estatus,
    required String estado,
    required int hasPdf,
    required String modalidad,
  }) async {
    final db = await _ensureInit();
    final updateMap = <String, dynamic>{
      if (tecnico.isNotEmpty) 'tecnico': tecnico,
      'estatus': estatus,
      'estado': estado,
      'has_pdf': hasPdf,
      'modalidad': modalidad,
      'sync_status': 'Sincronizado',
      'is_synced': 1,
    };
    try {
      await db.update(
        'ordenes_servicio',
        updateMap,
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [folio, folio],
      );
    } catch (e) {
      debugPrint('[LocalDB] updateEstatusYPdfRemoto error: $e');
    }
  }

  /// Reconciliación única: re-encola para PUSH las órdenes cerradas en la tablet
  /// (con PDF) de los últimos [dias] días. El reenvío es idempotente en el servidor.
  /// No borra ni modifica PDFs: solo marca is_dirty / pdf_subido.
  Future<int> marcarCerradasParaReenvio({int dias = 30}) async {
    final db = await _ensureInit();
    final desde = DateTime.now().subtract(Duration(days: dias)).toIso8601String().substring(0, 10);
    return await db.rawUpdate('''
      UPDATE ordenes_servicio
         SET is_dirty = 1, pdf_subido = 0, sync_status = 'PENDIENTE'
       WHERE (UPPER(COALESCE(estado, '')) IN ('CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','FIRMADA')
              OR UPPER(COALESCE(estatus, '')) IN ('CERRADO','CERRADA','COMPLETADA'))
         AND (COALESCE(pdf_path_local, '') <> '' OR COALESCE(pdf_b64_local, '') <> '')
         AND COALESCE(fecha, '') >= ?
    ''', [desde]);
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
    final String estatus = (o['estatus'] ?? o['estado'] ?? '').toString().toUpperCase().trim();
    final bool isCerrado = estatus == 'CERRADO' || estatus == 'CERRADA' || estatus == 'COMPLETADA' || estatus == 'COMPLETADA_DIGITAL' || estatus == 'COMPLETADA_FISICA' || estatus == 'FIRMADA';
    if (isCerrado) return true;

    final String? pdfPath = o['pdf_path']?.toString() ?? o['pdf_path_local']?.toString();
    final String? pdfUrl = o['pdf_url']?.toString();
    final bool hasPdfFlag = (o['has_pdf'] == 1 || o['has_pdf'] == '1' || o['has_pdf'] == true || o['pdf_subido'] == 1);
    if (hasPdfFlag) return true;

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
    
    final bool hasB64 = (o['pdf_b64_local']?.toString().length ?? 0) > 100 || (o['pdf_base64']?.toString().length ?? 0) > 100;
    
    return isCerrado || hasPdfFlag || (pdfUrl != null && pdfUrl.isNotEmpty) || tieneMetrologia || fileExiste || hasB64;
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

    final sucursal = (data['sucursal_nombre'] ?? data['sucursal'] ?? '').toString().trim();
    final cliente  = (data['cliente'] ?? data['cliente_nombre'] ?? '').toString().trim();
    final tecnico  = (data['tecnico'] ?? data['tecnico_nombre'] ?? '').toString().trim();
    final tipoSvc  = (data['tipo_servicio'] ?? data['tipo_servicio_nombre'] ?? data['tipo'] ?? '').toString().trim();
    final idTipoSvc = _toIntOrNull(data['id_tipo_servicio'] ?? data['tipo_servicio_id']);
    final direccion = (data['direccion'] ?? data['direccion_cliente'] ?? data['sucursal_direccion'] ?? data['planta'] ?? data['domicilio'] ?? '').toString().trim();

    final String finalSucursal = sucursal.isNotEmpty ? sucursal : (direccion.isNotEmpty ? direccion : '');
    final String finalDireccion = direccion.isNotEmpty ? direccion : (sucursal.isNotEmpty ? sucursal : '');

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

    final String modNorm = normalizarModalidad(data['modalidad']);

    final row = <String, dynamic>{
      'folio_os':          folio,
      'id_tecnico':        idTecnicoFinal,
      'estado':            data['estado']?.toString() ?? 'PROCESO',
      'modalidad':         modNorm,
      'fecha':             data['fecha']?.toString(),
      'cliente':           cliente,
      'sucursal':          finalSucursal,
      'direccion':         finalDireccion,
      'tecnico':           tecnico,
      'tipo_servicio':     tipoSvc,
      if (idTipoSvc != null && idTipoSvc > 0) 'id_tipo_servicio': idTipoSvc,
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
      'id_equipo':         (data['id_equipo'] ?? data['id_indicador'])?.toString(),
      'alcance_max':       _toDouble(data['alcance_max'] ?? data['capacidad_maxima']),
      'div_minima':        _toDouble(data['div_minima'] ?? data['division_minima']),
      'div_verificacion':  _toDouble(data['div_verificacion'] ?? data['div_ver']),
      'numero_cca':        (data['numero_cca'] ?? data['cca'])?.toString(),
      'numero_dve':        (data['numero_dve'] ?? data['folio_dve'])?.toString(),
      'motivo_no_excentricidad': data['motivo_no_excentricidad']?.toString(),
      if (_toIntOrNull(data['id_cliente'] ?? data['cliente_id']) != null)
        'id_cliente': _toIntOrNull(data['id_cliente'] ?? data['cliente_id']),
      if (_toIntOrNull(data['sucursal_id'] ?? data['id_sucursal']) != null)
        'sucursal_id': _toIntOrNull(data['sucursal_id'] ?? data['id_sucursal']),
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
      'tipo_documento':    (data['tipo_documento'] ?? (folio.toUpperCase().startsWith('OSOCC') ? 'OSOCC' : (folio.toUpperCase().startsWith('OSOB') ? 'OSOB' : (folio.toUpperCase().startsWith('RMA') ? 'RMA' : (folio.toUpperCase().startsWith('RE') ? 'RE' : (folio.toUpperCase().startsWith('LP') ? 'LP' : (folio.toUpperCase().startsWith('LV') ? 'LV' : 'OS')))))))?.toString(),
      if (data['datos_tecnicos_json'] != null)
        'datos_tecnicos_json': data['datos_tecnicos_json'] is String
            ? data['datos_tecnicos_json']
            : jsonEncode(data['datos_tecnicos_json']),
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
      if (data['correo_enviado'] == true || data['correo_enviado'] == 1 || data['correo_enviado'] == '1' || data['email_enviado'] == true || data['email_enviado'] == 1 || data['email_enviado'] == '1') ...{
        'correo_enviado': 1,
        'email_enviado': 1,
        'email_status': 'enviado',
      },
      if ((data['correo_destino'] ?? data['correo_cliente']) != null && (data['correo_destino'] ?? data['correo_cliente']).toString().trim().isNotEmpty) ...{
        'correo_destino': (data['correo_destino'] ?? data['correo_cliente']).toString().trim(),
        'correo_cliente': (data['correo_cliente'] ?? data['correo_destino']).toString().trim(),
      },
      if (data['correo_cc'] != null && data['correo_cc'].toString().trim().isNotEmpty)
        'correo_cc': data['correo_cc'].toString().trim(),
      if ((data['fecha_envio_correo'] ?? data['fecha_envio_email']) != null && (data['fecha_envio_correo'] ?? data['fecha_envio_email']).toString().trim().isNotEmpty) ...{
        'fecha_envio_correo': formatearFechaHoraMexico(data['fecha_envio_correo'] ?? data['fecha_envio_email']),
        'fecha_envio_email': formatearFechaHoraMexico(data['fecha_envio_email'] ?? data['fecha_envio_correo']),
      },
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
        final String exEstatus = (ex['estatus'] as String? ?? '').toUpperCase().trim();
        final String exEstado = (ex['estado'] as String? ?? '').toUpperCase().trim();

        final bool statusIsClosed = exEstatus == 'CERRADO' ||
            exEstatus == 'CERRADA' ||
            exEstatus == 'COMPLETADA' ||
            {'CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA'}.contains(exEstado);

        final bool hasPdfPath = pdfPath != null && pdfPath.isNotEmpty;
        final bool hasPdfB64 = pdfB64 != null && pdfB64.isNotEmpty;
        final bool pdfDiskExists = await checkPdfExistsOnDisk(folio, pdfPath);
        final bool hasLocalChanges = localIsDirty == 1;

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

          final String modSafe = normalizarModalidad(data['modalidad'] ?? ex['modalidad']);

          final safeUpdate = <String, dynamic>{
            'cliente': cliente.isNotEmpty ? cliente : ex['cliente'],
            'sucursal': sucursal.isNotEmpty ? sucursal : ex['sucursal'],
            'direccion': direccion.isNotEmpty ? direccion : ex['direccion'],
            'tecnico': tecnico.isNotEmpty ? tecnico : ex['tecnico'],
            'tipo_servicio': tipoSvc.isNotEmpty ? tipoSvc : ex['tipo_servicio'],
            if (idTipoSvc != null && idTipoSvc > 0) 'id_tipo_servicio': idTipoSvc,
            if (idTecnicoFinal != null && idTecnicoFinal > 0) 'id_tecnico': idTecnicoFinal,
            'modalidad': modSafe,

            // Mantener intactos: fecha de ejecución real, estatus 'Cerrado', estado local, mediciones, firmas y pdf_path_local
            if (ex['fecha'] != null && ex['fecha'].toString().trim().isNotEmpty) 'fecha': ex['fecha'],
            if (ex['fecha_servicio'] != null && ex['fecha_servicio'].toString().trim().isNotEmpty) 'fecha_servicio': ex['fecha_servicio'],
            if (ex['fecha_cierre'] != null && ex['fecha_cierre'].toString().trim().isNotEmpty) 'fecha_cierre': ex['fecha_cierre'],
            if (ex['fecha_creacion_logistica'] != null && ex['fecha_creacion_logistica'].toString().trim().isNotEmpty) 'fecha_creacion_logistica': ex['fecha_creacion_logistica'],
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

          // Sincronizar trazabilidad de envío de correo si el servidor reporta correo enviado
          if (row['correo_enviado'] == 1 || row['email_enviado'] == 1) {
            safeUpdate['correo_enviado'] = 1;
            safeUpdate['email_enviado'] = 1;
            safeUpdate['email_status'] = 'enviado';
            if (row['correo_destino'] != null && row['correo_destino'].toString().trim().isNotEmpty) {
              safeUpdate['correo_destino'] = row['correo_destino'];
              safeUpdate['correo_cliente'] = row['correo_cliente'] ?? row['correo_destino'];
            }
            safeUpdate['correo_cc'] = row['correo_cc'] ?? 'recepcion@basculaspesa.com.mx';
            if (row['fecha_envio_correo'] != null && row['fecha_envio_correo'].toString().trim().isNotEmpty) {
              safeUpdate['fecha_envio_correo'] = row['fecha_envio_correo'];
              safeUpdate['fecha_envio_email'] = row['fecha_envio_email'] ?? row['fecha_envio_correo'];
            }
          }

          // AUTO-REPARACIÓN DE DESFASE: la tablet la tiene Cerrada (con PDF) pero
          // PostgreSQL sigue en 'Proceso' → re-encolar para PUSH en el próximo ciclo.
          final srvEstado = (row['estado']?.toString() ?? '').trim().toUpperCase();
          final srvCerrada = {'CERRADO','CERRADA','COMPLETADA','COMPLETADA_DIGITAL','COMPLETADA_FISICA','ESCANEADA','FIRMADA'}.contains(srvEstado)
              || srvEstado.startsWith('CANCEL');
          if (statusIsClosed && (hasPdfPath || hasPdfB64 || pdfDiskExists) && !srvCerrada) {
            debugPrint('[LocalDB] ♻️ Desfase detectado en $folio (local=Cerrado, servidor=$srvEstado) → re-encolando PUSH');
            safeUpdate['is_dirty'] = 1;
            safeUpdate['pdf_subido'] = 0;
            safeUpdate['sync_status'] = 'PENDIENTE';
            safeUpdate['is_synced'] = 0;
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

        // Si existen datos de instrumento guardados parcialmente pendientes de envío, preservarlos
        try {
          final pendParcial = await db.query(
            'cola_instrumento_parcial',
            where: 'folio_os = ?',
            whereArgs: [folio],
            limit: 1,
          );
          if (pendParcial.isNotEmpty) {
            for (final col in [
              'marca', 'modelo', 'ns', 'id_equipo', 'ubicacion',
              'alcance_max', 'div_minima', 'instrumento_capacidad', 'instrumento_division',
              'tipo_instrumento', 'aplica_excentricidad', 'motivo_no_excentricidad',
              'numero_cca', 'numero_dve', 'datos_tecnicos_json', 'estado', 'estatus',
            ]) {
              if (ex[col] != null) row[col] = ex[col];
            }
          }
        } catch (_) {}

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
    // Ordenar cronológicamente (fecha DESC, id de servidor DESC, local_id DESC)
    return await db.rawQuery(
      "SELECT * FROM ordenes_servicio ORDER BY COALESCE(NULLIF(TRIM(fecha), ''), '') DESC, COALESCE(id, 0) DESC, local_id DESC",
    );
  }

  /// Devuelve solo las órdenes asignadas al técnico por ID y nombre.
  /// Si es admin (idTecnico == null y nombreTecnico vacío), devuelve TODAS.
  Future<List<Map<String, dynamic>>> getOsForTecnico({
    String? nombreTecnico,
    int? idTecnico,
  }) async {
    final db = await _ensureInit();
    final userNorm = normalizarTexto(nombreTecnico ?? '');

    // Admin: (idTecnico null o <= 0 Y nombreTecnico vacío) -> devuelve todas
    if ((idTecnico == null || idTecnico <= 0) && userNorm.isEmpty) {
      return await db.rawQuery(
        "SELECT * FROM ordenes_servicio ORDER BY COALESCE(NULLIF(TRIM(fecha), ''), '') DESC, COALESCE(id, 0) DESC, local_id DESC",
      );
    }

    final all = await db.rawQuery(
      "SELECT * FROM ordenes_servicio ORDER BY COALESCE(NULLIF(TRIM(fecha), ''), '') DESC, COALESCE(id, 0) DESC, local_id DESC",
    );
    return all.where((o) {
      final oId = int.tryParse(o['id_tecnico']?.toString() ?? '');
      if (oId != null && oId > 0 && idTecnico != null && idTecnico > 0) {
        if (oId == idTecnico) return true;
        return false;
      }
      final bool esMiOrden = normalizarTexto(o['tecnico']?.toString() ?? '') == userNorm ||
                             normalizarTexto(o['tecnico_nombre']?.toString() ?? '') == userNorm;
      if (esMiOrden) return true;
      final tecNorm = normalizarTexto(o['tecnico']?.toString() ?? o['tecnico_nombre']?.toString() ?? '');
      if (tecNorm.isNotEmpty && userNorm.isNotEmpty) {
        final tp = tecNorm.split(RegExp(r'\s+'));
        final mp = userNorm.split(RegExp(r'\s+'));
        if (tp.length >= 2 && mp.length >= 2 && tp[0] == mp[0] && tp[1] != mp[1]) return false;
        return tecNorm.contains(userNorm) || userNorm.contains(tecNorm);
      }
      return false;
    }).toList();
  }

  // ── Repositorio de Calibraciones (consulta read-only) ──────────────────────
  // Tabla SEPARADA de `ordenes_servicio`: la purga de órdenes de otros técnicos
  // y el PUSH de sincronización nunca la tocan, por lo que el repositorio no
  // altera las órdenes activas ni puede generar registros "dirty".

  bool _calibTableReady = false;

  Future<void> _ensureCalibracionesTable(Database db) async {
    if (_calibTableReady) return;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS calibraciones_consulta (
        folio_os            TEXT PRIMARY KEY,
        fecha               TEXT,
        cliente             TEXT,
        sucursal            TEXT,
        tecnico             TEXT,
        id_tecnico          INTEGER,
        tipo_servicio       TEXT,
        estado              TEXT,
        estatus             TEXT,
        modalidad           TEXT,
        marca               TEXT,
        modelo              TEXT,
        ns                  TEXT,
        id_equipo           TEXT,
        ubicacion           TEXT,
        numero_cca          TEXT,
        numero_dve          TEXT,
        datos_tecnicos_json TEXT,
        tiene_pdf           INTEGER DEFAULT 0,
        pdf_path_local      TEXT,
        updated_at          TEXT
      )
    ''');
    try {
      final info = await db.rawQuery('PRAGMA table_info(calibraciones_consulta)');
      final cols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      for (final col in [
        'marca', 'modelo', 'ns', 'id_equipo', 'ubicacion',
        'numero_cca', 'numero_dve', 'datos_tecnicos_json',
      ]) {
        if (!cols.contains(col)) {
          await db.execute('ALTER TABLE calibraciones_consulta ADD COLUMN $col TEXT');
        }
      }
    } catch (_) {}
    _calibTableReady = true;
  }

  /// Reemplaza la caché del repositorio con lo devuelto por el servidor,
  /// preservando la ruta local del PDF ya descargado de cada folio.
  Future<void> guardarCalibracionesConsulta(List<Map<String, dynamic>> rows) async {
    final db = await _ensureInit();
    await _ensureCalibracionesTable(db);
    await db.transaction((txn) async {
      final prev = await txn.query('calibraciones_consulta',
          columns: ['folio_os', 'pdf_path_local']);
      final paths = <String, String>{
        for (final r in prev)
          if ((r['pdf_path_local'] ?? '').toString().isNotEmpty)
            r['folio_os'].toString(): r['pdf_path_local'].toString(),
      };
      await txn.delete('calibraciones_consulta');
      for (final r in rows) {
        final folio = (r['folio_os'] ?? '').toString().trim();
        if (folio.isEmpty) continue;
        final tipo = (r['tipo_servicio'] ?? '').toString().toLowerCase();
        // Estricto: Solo Calibración, Calibración + Ajuste, Calibración + Ajuste + Inspección
        if (!tipo.contains('calibraci')) continue;
        final tienePdf = r['tiene_pdf'];
        await txn.insert(
          'calibraciones_consulta',
          {
            'folio_os': folio,
            'fecha': r['fecha']?.toString(),
            'cliente': r['cliente']?.toString(),
            'sucursal': r['sucursal']?.toString(),
            'tecnico': r['tecnico']?.toString(),
            'id_tecnico': int.tryParse('${r['id_tecnico'] ?? ''}'),
            'tipo_servicio': r['tipo_servicio']?.toString(),
            'estado': r['estado']?.toString(),
            'estatus': r['estatus']?.toString(),
            'modalidad': r['modalidad']?.toString(),
            'marca': r['marca']?.toString(),
            'modelo': r['modelo']?.toString(),
            'ns': (r['ns'] ?? r['serie'])?.toString(),
            'id_equipo': (r['id_equipo'] ?? r['id_indicador'])?.toString(),
            'ubicacion': r['ubicacion']?.toString(),
            'numero_cca': (r['numero_cca'] ?? r['cca'])?.toString(),
            'numero_dve': (r['numero_dve'] ?? r['folio_dve'])?.toString(),
            'datos_tecnicos_json': r['datos_tecnicos_json'] is String
                ? r['datos_tecnicos_json']
                : (r['datos_tecnicos_json'] != null ? jsonEncode(r['datos_tecnicos_json']) : null),
            'tiene_pdf': (tienePdf == true || tienePdf == 1 || tienePdf == '1') ? 1 : 0,
            'pdf_path_local': paths[folio],
            'updated_at': r['updated_at']?.toString(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Registra la ruta local del PDF descargado para un folio del repositorio.
  Future<void> setCalibracionPdfPath(String folio, String path) async {
    final db = await _ensureInit();
    await _ensureCalibracionesTable(db);
    await db.update('calibraciones_consulta', {'pdf_path_local': path},
        where: 'folio_os = ?', whereArgs: [folio]);
  }

  /// Órdenes de calibración concluidas (Cerrado / Completado) para
  /// consulta. Combina la caché del servidor con las propias órdenes cerradas
  /// locales (la caché tiene prioridad por folio). Solo lectura.
  /// Incluye ÚNICAMENTE registros cuyo tipo_servicio contenga 'calibraci'.
  Future<List<Map<String, dynamic>>> getCalibracionesFinalizadasConsulta() async {
    final db = await _ensureInit();
    await _ensureCalibracionesTable(db);

    final cache = await db.rawQuery('''
      SELECT * FROM calibraciones_consulta
    ''');

    final propias = await db.rawQuery('''
      SELECT folio_os, fecha, cliente, sucursal, tecnico, id_tecnico,
             tipo_servicio, estado, estatus, modalidad, pdf_path_local,
             marca, modelo, ns, id_equipo, ubicacion, numero_cca, numero_dve, datos_tecnicos_json,
             CASE WHEN COALESCE(pdf_path_local, '') != ''
                       OR COALESCE(pdf_subido, 0) = 1 THEN 1 ELSE 0 END AS tiene_pdf,
             updated_at
      FROM ordenes_servicio
      WHERE (
          LOWER(COALESCE(estatus, '')) IN ('cerrado', 'cerrada', 'completado', 'completada')
          OR UPPER(COALESCE(estado, '')) IN ('CERRADO', 'CERRADA', 'COMPLETADA',
             'COMPLETADO', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'ESCANEADA', 'FIRMADA')
        )
    ''');

    final byFolio = <String, Map<String, dynamic>>{};
    for (final r in propias) {
      byFolio[r['folio_os'].toString()] = Map<String, dynamic>.from(r);
    }
    for (final r in cache) {
      final folio = r['folio_os'].toString();
      final merged = Map<String, dynamic>.from(r);
      final local = byFolio[folio];
      if ((merged['pdf_path_local'] ?? '').toString().isEmpty && local != null) {
        merged['pdf_path_local'] = local['pdf_path_local'];
      }
      byFolio[folio] = merged;
    }

    final list = byFolio.values.toList();
    list.sort((a, b) {
      final fa = (a['fecha'] ?? '').toString();
      final fb = (b['fecha'] ?? '').toString();
      final c = fb.compareTo(fa);
      if (c != 0) return c;
      return (b['folio_os'] ?? '').toString().compareTo((a['folio_os'] ?? '').toString());
    });
    return list;
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
        final userNorm = normalizarTexto(currentNombre);
        final rows = await db.query(
          'ordenes_servicio',
          columns: ['local_id', 'folio_os', 'tecnico', 'is_dirty', 'id_tecnico'],
          where: 'is_dirty = 0',
        );

        for (final r in rows) {
          final tecNorm = normalizarTexto(r['tecnico']?.toString() ?? '');
          final rId = int.tryParse(r['id_tecnico']?.toString() ?? '');
          final localId = r['local_id'] as int;

          // Si coincide por id_tecnico con el usuario actual, conservar
          if (currentIdTecnico != null && currentIdTecnico > 0 && rId == currentIdTecnico) {
            continue;
          }
          // Si coincide por nombre normalizado exacto, conservar
          if (tecNorm.isNotEmpty && tecNorm == userNorm) continue;

          if (tecNorm.isEmpty) continue;

          // Verificación con apellido: si primer nombre igual pero apellido distinto → purgar
          final tecParts = tecNorm.split(RegExp(r'\s+'));
          final myParts  = userNorm.split(RegExp(r'\s+'));
          if (tecParts.length >= 2 && myParts.length >= 2 &&
              tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) {
            // Mismo primer nombre, apellido distinto → es otro técnico → purgar
            await db.delete('ordenes_servicio', where: 'local_id = ?', whereArgs: [localId]);
            totalEliminadas++;
            continue;
          }

          // Coincidencia parcial de nombre completo
          if (tecNorm.contains(userNorm) || userNorm.contains(tecNorm)) {
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
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (folioKey.toUpperCase().startsWith('OSOB-') &&
          (decoded.containsKey('partidas') ||
              decoded.containsKey('items') ||
              !decoded.containsKey('checklist_inspeccion'))) {
        await db.delete(
          'borradores_captura',
          where: 'folio_os = ?',
          whereArgs: [folioKey],
        );
        return null;
      }
      return decoded;
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

  /// Actualiza la fecha de ejecución real al finalizar un servicio/formato (OS, RMA, LP, LV, RE)
  /// tanto en la vista/tabla `ordenes` como en `ordenes_servicio`.
  Future<void> actualizarFechaEjecucionAlFinalizar(
    String folio,
    String fechaEjecucionHoy, {
    int? localId,
    String? fechaCierre,
    String? fechaCreacionLogistica,
  }) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty && (localId == null || localId <= 0)) return;
    final db = await _ensureInit();
    final nowIso = fechaCierre ?? DateTime.now().toIso8601String();

    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();

      final rawUpd = <String, dynamic>{
        'fecha': fechaEjecucionHoy,
        'fecha_servicio': fechaEjecucionHoy,
        'fecha_cierre': nowIso,
        if (fechaCreacionLogistica != null && fechaCreacionLogistica.trim().isNotEmpty)
          'fecha_creacion_logistica': fechaCreacionLogistica.trim(),
        'is_dirty': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      final sanitized = <String, dynamic>{};
      rawUpd.forEach((k, v) {
        if (existingCols.contains(k.toLowerCase())) {
          sanitized[k] = v;
        }
      });

      if (localId != null && localId > 0) {
        await db.update('ordenes_servicio', sanitized, where: 'local_id = ?', whereArgs: [localId]);
      }
      if (folioKey.isNotEmpty) {
        await db.update(
          'ordenes_servicio',
          sanitized,
          where: 'folio_os = ? OR folio = ?',
          whereArgs: [folioKey, folioKey],
        );
        try {
          await db.update(
            'ordenes',
            {'fecha': fechaEjecucionHoy},
            where: 'folio_os = ? OR folio = ?',
            whereArgs: [folioKey, folioKey],
          );
        } catch (_) {}
      }
      debugPrint('[LocalDB] 📅 Fecha de ejecución actualizada para $folioKey -> $fechaEjecucionHoy');
    } catch (e) {
      debugPrint('[LocalDB] Error en actualizarFechaEjecucionAlFinalizar($folioKey): $e');
    }
  }

  Future<void> savePdfPath(
    int localId,
    String path, {
    String? folio,
    String? pdfB64,
    bool isOnline = false,
    bool uploadOk = false,
    String? fechaEjecucion,
    String? fechaCierre,
    String? fechaCreacionLogistica,
  }) async {
    final db = await _ensureInit();
    final folioKey = (folio ?? '').trim();
    final syncCheck = (isOnline && uploadOk) ? 'SUBIDA_SERVIDOR' : 'PENDIENTE_SUBIDA';
    final syncStatus = (isOnline && uploadOk) ? 'SINCRONIZADO' : 'PENDIENTE';
    final isSynced = (isOnline && uploadOk) ? 1 : 0;
    final pdfSubido = (isOnline && uploadOk) ? 1 : 0;
    final isDirty = (isOnline && uploadOk) ? 0 : 1;

    final String hoy = (fechaEjecucion != null && fechaEjecucion.trim().isNotEmpty)
        ? fechaEjecucion.trim()
        : DateTime.now().toIso8601String().split('T').first;

    final updateData = <String, dynamic>{
      'pdf_path_local': path,
      if (pdfB64 != null && pdfB64.isNotEmpty) 'pdf_b64_local': pdfB64,
      'fecha': hoy,
      'fecha_servicio': hoy,
      'fecha_cierre': fechaCierre ?? DateTime.now().toIso8601String(),
      if (fechaCreacionLogistica != null && fechaCreacionLogistica.trim().isNotEmpty)
        'fecha_creacion_logistica': fechaCreacionLogistica.trim(),
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
      debugPrint('[LocalDB] savePdfPath exitoso para $folioKey (localId: $localId, path: $path, fecha: $hoy, syncCheck: $syncCheck)');
    } catch (e) {
      debugPrint('[LocalDB] Error en savePdfPath: $e');
    }
  }

  /// Actualiza únicamente el campo `sync_status` de una OS por folio.
  /// Útil para marcar PENDIENTE_RESET o SINCRONIZADO tras un reset remoto.
  Future<void> updateSyncStatus(String folio, String syncStatus) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.update(
        'ordenes_servicio',
        {'sync_status': syncStatus, 'updated_at': DateTime.now().toIso8601String()},
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [folioKey, folioKey],
      );
      debugPrint('[LocalDB] updateSyncStatus: $folioKey → $syncStatus');
    } catch (e) {
      debugPrint('[LocalDB] Error en updateSyncStatus para $folioKey: $e');
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

  /// Borra TODAS las copias locales del PDF de un folio (caché estancada).
  /// Retorna cuántos archivos se eliminaron.
  Future<int> invalidarPdfLocal(String folio, {String? pathExtra}) async {
    final f = folio.trim();
    if (f.isEmpty) return 0;
    final safe = f.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    int borrados = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final candidatos = <String>{
        '${dir.path}/$safe.pdf',
        '${dir.path}/pdfs/$safe.pdf',
        '${dir.path}/pdfs/OS-$safe.pdf',
        '${dir.path}/Pesa_PDFs/$safe.pdf',
        '${dir.path}/Pesa_PDFs/OS-$safe.pdf',
        '${dir.path}/PESA_Tablet/PDF_OS/$safe.pdf',
        if (pathExtra != null && pathExtra.trim().isNotEmpty) pathExtra.trim(),
      };
      for (final p in candidatos) {
        try {
          final file = File(p);
          if (await file.exists()) {
            await file.delete();
            borrados++;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[LocalDB] invalidarPdfLocal($f) error: $e');
    }
    debugPrint('[LocalDB] invalidarPdfLocal($f): $borrados archivo(s) eliminados');
    return borrados;
  }

  /// Reemplaza la ruta y el Base64 del PDF local por la versión fresca del servidor.
  Future<void> reemplazarPdfLocal(String folio, String path, String? pdfB64) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return;
    try {
      final db = await _ensureInit();
      await db.update(
        'ordenes_servicio',
        {
          'pdf_path_local': path,
          if (pdfB64 != null && pdfB64.isNotEmpty) 'pdf_b64_local': pdfB64,
        },
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [folioKey, folioKey],
      );
    } catch (e) {
      debugPrint('[LocalDB] reemplazarPdfLocal($folioKey) error: $e');
    }
  }

  /// Número de órdenes locales sin tipo de servicio (para forzar PULL completo).
  Future<int> contarSinTipoServicio() async {
    try {
      final db = await _ensureInit();
      return Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM ordenes_servicio WHERE TRIM(COALESCE(tipo_servicio, '')) = ''",
          )) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Respaldo para órdenes históricas que quedaron sin tipo en SQLite.
  /// Valores confirmados en PostgreSQL (cat_tipo_servicio). Solo rellena vacíos.
  static const Map<String, (int, String)> _tiposConocidos = {
    'OS-26-688': (6, 'Ajuste + Inspección'),
    'OS-26-689': (7, 'Calibración + Ajuste + Inspección'),
    'OS-26-696': (4, 'Calibración + Ajuste'),
    'OS-26-697': (4, 'Calibración + Ajuste'),
    'OS-26-698': (4, 'Calibración + Ajuste'),
  };

  Future<int> parchearTiposServicioConocidos() async {
    int n = 0;
    try {
      final db = await _ensureInit();
      for (final e in _tiposConocidos.entries) {
        n += await db.rawUpdate(
          "UPDATE ordenes_servicio SET tipo_servicio = ?, id_tipo_servicio = ? "
          "WHERE (folio_os = ? OR folio = ?) AND TRIM(COALESCE(tipo_servicio, '')) = ''",
          [e.value.$2, e.value.$1, e.key, e.key],
        );
      }
    } catch (e) {
      debugPrint('[LocalDB] parchearTiposServicioConocidos error: $e');
    }
    if (n > 0) debugPrint('[LocalDB] Tipo de servicio restaurado en $n orden(es) histórica(s)');
    return n;
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
    String? correoCliente,
    String? fechaEjecucion,
    String? fechaCierre,
    String? fechaCreacionLogistica,
  }) async {
    final db = await _ensureInit();
    final whereClause = (localId > 0) ? 'local_id = ?' : 'folio_os = ?';
    final whereArg = (localId > 0) ? localId : folio;
    final String hoy = (fechaEjecucion != null && fechaEjecucion.trim().isNotEmpty)
        ? fechaEjecucion.trim()
        : DateTime.now().toIso8601String().split('T').first;
    final Map<String, dynamic> upd = {
      'firma_tecnico': firmaTecBase64,
      'firma_cliente': firmaCliBase64,
      'nombre_ing':    nombreIng,
      'puesto_ing':    puestoIng,
      'fecha':         hoy,
      'is_dirty':      1,
    };
    if (correoCliente != null && correoCliente.trim().isNotEmpty) {
      upd['correo_cliente'] = correoCliente.trim();
    }
    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final existingCols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      if (existingCols.contains('fecha_servicio')) upd['fecha_servicio'] = hoy;
      if (existingCols.contains('fecha_cierre')) {
        upd['fecha_cierre'] = fechaCierre ?? DateTime.now().toIso8601String();
      }
      if (fechaCreacionLogistica != null &&
          fechaCreacionLogistica.trim().isNotEmpty &&
          existingCols.contains('fecha_creacion_logistica')) {
        upd['fecha_creacion_logistica'] = fechaCreacionLogistica.trim();
      }
    } catch (_) {}
    await db.update(
      'ordenes_servicio',
      upd,
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

  /// Actualiza el estado de envío de correo en la base de datos SQLite local
  Future<void> updateEmailStatus(
    String folio, {
    required bool enviado,
    String? status,
    String? correo,
    String? fechaEnvio,
    String? cc,
  }) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final String emailSt = status ?? (enviado ? 'enviado' : 'cola');
    final String fechaMx = enviado
        ? formatearFechaHoraMexico(fechaEnvio ?? DateTime.now().toUtc())
        : '';
    final String ccVal = (cc != null && cc.trim().isNotEmpty)
        ? cc.trim()
        : 'recepcion@basculaspesa.com.mx';
    final Map<String, dynamic> data = {
      'email_enviado': enviado ? 1 : 0,
      'correo_enviado': enviado ? 1 : 0,
      'email_status': emailSt,
      'correo_cc': ccVal,
      if (enviado && fechaMx.isNotEmpty) ...{
        'fecha_envio_email': fechaMx,
        'fecha_envio_correo': fechaMx,
      },
    };
    if (correo != null && correo.trim().isNotEmpty) {
      data['correo_cliente'] = correo.trim();
      data['correo_destino'] = correo.trim();
    }
    await db.update(
      'ordenes_servicio',
      data,
      where: 'folio_os = ? OR folio = ?',
      whereArgs: [folio, folio],
    );
  }

  /// Alias explícito para actualizar registro de entrega por correo
  Future<void> actualizarEnvioCorreo({
    required String folio,
    required int enviado,
    required String fechaEnvio,
    required String correos,
  }) async {
    await updateEmailStatus(
      folio,
      enviado: enviado == 1,
      status: enviado == 1 ? 'enviado' : 'cola',
      correo: correos,
      fechaEnvio: fechaEnvio,
    );
  }

  /// Busca folios u órdenes en SQLite local por lote_id o coincidencia de cliente y fecha.
  Future<List<Map<String, dynamic>>> obtenerFoliosPorLoteOCliente({
    String? loteId,
    String? cliente,
    String? fecha,
  }) async {
    final db = await _ensureInit();
    final cleanLote = (loteId ?? '').trim();
    final cleanCli = (cliente ?? '').trim();
    final cleanFecha = (fecha ?? '').split('T').first.trim();

    if (cleanLote.isNotEmpty &&
        !cleanLote.startsWith('grp_') &&
        !cleanLote.startsWith('LOTE-') &&
        !cleanLote.startsWith('solo_')) {
      final rows = await db.query(
        'ordenes_servicio',
        where: 'id_lote = ? OR lote = ?',
        whereArgs: [cleanLote, cleanLote],
      );
      if (rows.isNotEmpty) return rows;
    }

    if (cleanCli.isNotEmpty) {
      if (cleanFecha.isNotEmpty) {
        final rows = await db.query(
          'ordenes_servicio',
          where: 'cliente LIKE ? AND (fecha_servicio LIKE ? OR fecha_os LIKE ? OR fecha LIKE ?)',
          whereArgs: ['%$cleanCli%', '%$cleanFecha%', '%$cleanFecha%', '%$cleanFecha%'],
        );
        if (rows.isNotEmpty) return rows;
      }
      final rowsCli = await db.query(
        'ordenes_servicio',
        where: 'cliente LIKE ?',
        whereArgs: ['%$cleanCli%'],
      );
      if (rowsCli.isNotEmpty) return rowsCli;
    }
    return [];
  }

  Future<List<String>> obtenerListaFoliosPorLoteOCliente({
    String? loteId,
    String? cliente,
    String? fecha,
  }) async {
    final rows = await obtenerFoliosPorLoteOCliente(loteId: loteId, cliente: cliente, fecha: fecha);
    return rows.map((r) => ((r['folio_os'] ?? r['folio']) ?? '').toString().trim()).where((f) => f.isNotEmpty).toList();
  }

  // ── Cola local offline de correos (SQLite) ────────────────────────────────
  bool _colaCorreosReady = false;

  Future<void> _ensureColaCorreos(Database db) async {
    if (_colaCorreosReady) return;
    await db.execute("""
      CREATE TABLE IF NOT EXISTS cola_correos (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        tipo         TEXT NOT NULL,
        referencia   TEXT NOT NULL,
        correo       TEXT NOT NULL,
        folios       TEXT,
        email_status TEXT DEFAULT 'pendiente',
        intentos     INTEGER DEFAULT 0,
        ultimo_error TEXT,
        created_at   TEXT,
        updated_at   TEXT
      )
    """);
    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final cols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      if (!cols.contains('email_status')) {
        await db.execute("ALTER TABLE ordenes_servicio ADD COLUMN email_status TEXT");
      }
    } catch (e) {
      debugPrint('[LocalDB] email_status column: $e');
    }
    _colaCorreosReady = true;
  }

  /// Encola un envío de correo (orden o lote) con email_status IN ('pendiente','cola').
  /// Si ya existe uno pendiente para la misma referencia, se actualiza (sin duplicar).
  Future<void> encolarCorreo({
    required String tipo,
    required String referencia,
    required String correo,
    List<String> folios = const [],
  }) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final now = DateTime.now().toIso8601String();
    final listaFolios = folios.isNotEmpty ? folios : [referencia];
    final existing = await db.query(
      'cola_correos',
      where: "tipo = ? AND referencia = ? AND email_status IN ('pendiente','cola')",
      whereArgs: [tipo, referencia],
      limit: 1,
    );
    final data = <String, dynamic>{
      'tipo': tipo,
      'referencia': referencia,
      'correo': correo.trim(),
      'folios': listaFolios.join(','),
      'email_status': 'cola',
      'updated_at': now,
    };
    if (existing.isNotEmpty) {
      await db.update('cola_correos', data, where: 'id = ?', whereArgs: [existing.first['id']]);
    } else {
      data['created_at'] = now;
      data['intentos'] = 0;
      await db.insert('cola_correos', data);
    }
    for (final f in listaFolios) {
      await db.update(
        'ordenes_servicio',
        {'correo_cliente': correo.trim(), 'email_enviado': 0, 'email_status': 'cola'},
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
    }
    debugPrint('[LocalDB] 📥 Correo encolado ($tipo $referencia → $correo) folios: $listaFolios');
  }

  /// Envíos pendientes de la cola (FIFO).
  Future<List<Map<String, dynamic>>> getCorreosPendientes() async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    return db.query('cola_correos', where: "email_status IN ('pendiente','cola')", orderBy: 'id ASC');
  }

  Future<int> contarCorreosPendientes() async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final r = await db.rawQuery("SELECT COUNT(*) AS c FROM cola_correos WHERE email_status IN ('pendiente','cola')");
    return _toInt(r.first['c'], 0);
  }

  /// Marca el envío como despachado y las órdenes como enviadas (email_enviado = 1, correo_enviado = 1).
  Future<void> marcarCorreoEnviado(int id, List<String> folios, String correo) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final nowIso = DateTime.now().toIso8601String();
    final nowMx = formatearFechaHoraMexico(DateTime.now().toUtc());
    await db.update('cola_correos', {'email_status': 'enviado', 'ultimo_error': null, 'updated_at': nowIso},
        where: 'id = ?', whereArgs: [id]);
    for (final f in folios) {
      await db.update(
        'ordenes_servicio',
        {
          'email_enviado': 1,
          'correo_enviado': 1,
          'email_status': 'enviado',
          'fecha_envio_email': nowMx,
          'fecha_envio_correo': nowMx,
          'correo_cliente': correo,
          'correo_destino': correo,
          'correo_cc': 'recepcion@basculaspesa.com.mx',
        },
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
    }
  }

  /// Marca el registro de cola_correos y sus órdenes asociadas como 'enviando'
  /// para que ningún otro hilo o llamada concurrente intente despacharlos.
  Future<void> marcarColaCorreoEnviando(int id, List<String> folios, String correo) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final now = DateTime.now().toIso8601String();
    await db.update(
      'cola_correos',
      {'email_status': 'enviando', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    for (final f in folios) {
      await db.update(
        'ordenes_servicio',
        {'email_status': 'enviando', 'correo_cliente': correo.trim()},
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
    }
  }

  /// Revierte el estado a 'cola' si falló la conexión para reintento posterior.
  Future<void> revertirColaCorreoACola(int id, List<String> folios, String correo) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    final now = DateTime.now().toIso8601String();
    await db.update(
      'cola_correos',
      {'email_status': 'cola', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    for (final f in folios) {
      await db.update(
        'ordenes_servicio',
        {'email_status': 'cola', 'correo_cliente': correo.trim()},
        where: 'folio_os = ? OR folio = ?',
        whereArgs: [f, f],
      );
    }
  }

  /// Registra un intento fallido. Con [descartar] = true sale de la cola (estado 'error').
  Future<void> marcarCorreoFallido(int id, String error, {bool descartar = false}) async {
    final db = await _ensureInit();
    await _ensureColaCorreos(db);
    await db.rawUpdate(
      "UPDATE cola_correos SET intentos = COALESCE(intentos,0) + 1, ultimo_error = ?, updated_at = ?, "
      "email_status = CASE WHEN ? = 1 THEN 'error' ELSE email_status END WHERE id = ?",
      [error, DateTime.now().toIso8601String(), descartar ? 1 : 0, id],
    );
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

  /// Marca un formato físico (OS/Remisión/Revisión de Celdas) como recibido
  /// tras subir su escaneo: modalidad FISICO, estatus Cerrado, PDF local.
  Future<void> marcarFormatoFisicoRecibido(
    String folio, {
    required String pdfPath,
    String estado = 'Cerrado',
  }) async {
    final db = await _ensureInit();
    final f = folio.trim();
    if (f.isEmpty) return;
    final data = <String, dynamic>{
      'estado': estado.toUpperCase(),
      'estatus': 'Cerrado',
      'modalidad': 'FISICO',
      'pdf_path_local': pdfPath,
      'pdf_subido': 1,
      'sync_status': 'SINCRONIZADO',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final info = await db.rawQuery('PRAGMA table_info(ordenes_servicio)');
      final cols = info.map((r) => (r['name'] as String).toLowerCase()).toSet();
      final sanitized = <String, dynamic>{};
      data.forEach((k, v) {
        if (cols.contains(k.toLowerCase())) sanitized[k] = v;
      });
      if (sanitized.isEmpty) return;
      final where = cols.contains('folio') ? 'folio_os = ? OR folio = ?' : 'folio_os = ?';
      final args = cols.contains('folio') ? [f, f] : [f];
      await db.update('ordenes_servicio', sanitized, where: where, whereArgs: args);
      debugPrint('[LocalDB] marcarFormatoFisicoRecibido OK para $f');
    } catch (e) {
      debugPrint('[LocalDB] Error en marcarFormatoFisicoRecibido para $f: $e');
    }
  }

  /// Obtiene órdenes completadas/cerradas cuyo PDF aún no se ha confirmado subido al servidor.
  Future<List<Map<String, dynamic>>> getOsParaSubirPdf() async {
    final db = await _ensureInit();
    return await db.rawQuery('''
      SELECT * FROM ordenes_servicio 
      WHERE (
        estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA')
        OR estatus = 'Cerrado'
        OR has_pdf = 1
        OR (pdf_path_local IS NOT NULL AND pdf_path_local != '')
        OR (pdf_path IS NOT NULL AND pdf_path != '')
      )
      AND (pdf_subido IS NULL OR pdf_subido = 0)
    ''');
  }

  /// Obtiene órdenes completadas/cerradas cuyo correo electrónico está pendiente de envío
  /// y ya cuentan con correo de cliente válido para ser despachadas al sincronizar.
  Future<List<Map<String, dynamic>>> getOsParaEnviarEmail() async {
    final db = await _ensureInit();
    return await db.rawQuery('''
      SELECT * FROM ordenes_servicio 
      WHERE (
        email_status IN ('cola', 'pendiente')
        OR (
          (email_enviado IS NULL OR email_enviado = 0)
          AND (
            estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA')
            OR estatus IN ('Cerrado', 'FIRMADA', 'Cerrada')
            OR has_pdf = 1
            OR pdf_subido = 1
          )
        )
      )
      AND (email_status IS NULL OR email_status NOT IN ('enviando', 'enviado'))
      AND correo_cliente IS NOT NULL
      AND TRIM(correo_cliente) != ''
      AND LOWER(TRIM(correo_cliente)) != 'ivancolin1207@gmail.com'
      AND LOWER(TRIM(correo_cliente)) != 'sin registrar'
      AND LOWER(TRIM(correo_cliente)) != 'none'
      AND LOWER(TRIM(correo_cliente)) != 'null'
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
         OR needs_push = 1
         OR UPPER(TRIM(COALESCE(sync_status, ''))) IN ('PENDIENTE', 'PENDIENTE_ACTUALIZAR', 'PENDIENTE_SUBIDA')
         OR (pdf_path_local IS NOT NULL AND (pdf_subido = 0 OR pdf_subido IS NULL) AND (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA') OR estatus = 'Cerrado'))
         OR (sync_check_status IN ('RECIBIDA_TABLET', 'PENDIENTE_SUBIDA', 'ASIGNADA') 
             AND (estado IN ('COMPLETADA', 'COMPLETADA_DIGITAL', 'CERRADA', 'CERRADO', 'FIRMADA') OR estatus = 'Cerrado'))
    ''');
  }

  /// Forzar reenvío de órdenes cerradas:
  /// Actualiza en SQLite local sync_status = 'PENDIENTE', needs_push = 1, is_dirty = 1, pdf_subido = 0
  /// para todas las órdenes cerradas y retorna cuántas fueron encoladas.
  Future<int> forzarReenvioOrdenesCerradas() async {
    final db = await _ensureInit();
    final count = await db.rawUpdate('''
      UPDATE ordenes_servicio
      SET sync_status = 'PENDIENTE',
          needs_push = 1,
          is_dirty = 1,
          pdf_subido = 0,
          sync_check_status = 'PENDIENTE_SUBIDA'
      WHERE UPPER(TRIM(COALESCE(estatus, ''))) IN ('CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL')
         OR UPPER(TRIM(COALESCE(estado, ''))) IN ('CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'FIRMADA')
    ''');
    debugPrint('[LocalDB] 🚀 Se marcaron $count órdenes cerradas para reenvío obligatorio');
    return count;
  }

  /// Retorna todas las OSs que tengan un `sync_status` específico.
  /// Usado por [SyncService._pushResetsPendientes] para reintentar
  /// resets que fallaron por red offline.
  Future<List<Map<String, dynamic>>> getOrdenesConSyncStatus(String status) async {
    final db = await _ensureInit();
    return await db.query(
      'ordenes_servicio',
      columns: ['local_id', 'folio_os', 'folio', 'sync_status'],
      where: 'sync_status = ?',
      whereArgs: [status],
    );
  }

  /// Comprueba si existen lecturas de metrología, firmas o archivo PDF localmente guardados para este folio.
  Future<bool> hasLecturasGuardadas(String folio) async {
    final db = await _ensureInit();
    final rows = await db.query(
      'ordenes_servicio',
      columns: ['rep_json', 'exc_json', 'exac_json', 'firma_tecnico', 'firma_cliente', 'pdf_path_local', 'pdf_b64_local'],
      where: 'folio_os = ? OR folio = ?',
      whereArgs: [folio, folio],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final r = rows.first;
    for (final col in ['rep_json', 'exc_json', 'exac_json', 'firma_tecnico', 'firma_cliente', 'pdf_b64_local']) {
      final val = r[col]?.toString().trim() ?? '';
      if (val.isNotEmpty && val != '{}' && val != '[]' && val != 'null') {
        return true;
      }
    }
    final pdfLocal = r['pdf_path_local']?.toString().trim() ?? '';
    if (pdfLocal.isNotEmpty) {
      try {
        final f = File(pdfLocal);
        if (f.existsSync() && f.lengthSync() > 500) return true;
      } catch (_) {}
    }
    return false;
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

  /// Obtiene la dirección histórica conocida de un cliente en la base local
  Future<String?> getDireccionCliente(String cliente) async {
    final cli = cliente.trim();
    if (cli.isEmpty) return null;
    try {
      final db = await _ensureInit();
      final res = await db.rawQuery('''
        SELECT COALESCE(NULLIF(TRIM(direccion), ''), NULLIF(TRIM(sucursal), '')) AS dir
        FROM ordenes_servicio
        WHERE LOWER(TRIM(cliente)) = LOWER(?) AND (
          (direccion IS NOT NULL AND TRIM(direccion) != '' AND TRIM(direccion) != '-') OR
          (sucursal IS NOT NULL AND TRIM(sucursal) != '' AND TRIM(sucursal) != '-')
        )
        ORDER BY local_id DESC LIMIT 1
      ''', [cli]);
      if (res.isNotEmpty && res.first['dir'] != null) {
        final d = res.first['dir'].toString().trim();
        if (d.isNotEmpty && d != '-' && !d.toLowerCase().contains('aseguramiento') && !d.toLowerCase().contains('calidad')) {
          return d;
        }
      }
    } catch (_) {}
    if (cli.toLowerCase().contains('mar bran')) {
      return 'Carretera el Jaral del Progreso- Cortazar km 4.3 C.P. 38470, Jaral del Progreso, Guanajuato';
    }
    return null;
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

  // ── Catálogos Completos de Administración + Historial de Instrumentos + Cola Parcial ──

  Future<int> getConteoCatalogoClientes() async {
    try {
      final db = await _ensureInit();
      await _asegurarTablasCatalogosAdmin(db);
      final n = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM catalogo_clientes'),
          ) ??
          0;
      return n;
    } catch (_) {
      return 0;
    }
  }

  static Map<String, dynamic> _parseSucursalRow(Map raw, {int? fallbackClienteId, String fallbackClienteNombre = ''}) {
    final s = Map<String, dynamic>.from(raw);
    final sid = _toIntOrNull(s['id'] ?? s['sucursal_id']);
    final cid = _toIntOrNull(s['cliente_id'] ?? s['id_cliente']) ?? fallbackClienteId;
    final sNom = (s['nombre'] ?? s['nombre_sucursal'] ?? s['planta'] ?? s['sucursal'] ?? '').toString().trim();
    final sDir = (s['direccion'] ?? '').toString().trim();
    final effNom = sNom.isNotEmpty ? sNom : sDir;
    final effDir = sDir.isNotEmpty ? sDir : sNom;
    return {
      'id': sid,
      'sucursal_id': sid,
      'cliente_id': cid ?? 0,
      'cliente_nombre': (s['cliente_nombre'] ?? s['cliente'] ?? fallbackClienteNombre).toString().trim(),
      'nombre': effNom,
      'nombre_sucursal': effNom,
      'planta': (s['planta'] ?? effNom).toString().trim(),
      'direccion': effDir,
      'ciudad': (s['ciudad'] ?? '').toString().trim(),
      'contacto': (s['contacto'] ?? s['contacto_nombre'] ?? '').toString().trim(),
      'telefono': (s['telefono'] ?? s['contacto_telefono'] ?? '').toString().trim(),
      'correo': (s['correo'] ?? s['email'] ?? '').toString().trim(),
    };
  }

  /// Persiste de forma atómica el payload completo de `GET /api/admin/catalogos`
  /// (clientes con todas sus direcciones/sucursales, técnicos, tipos de servicio,
  /// tipos de instrumento e historial de instrumentos para autocompletado).
  Future<void> guardarCatalogosAdmin(Map<String, dynamic> data) async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final rawClientes = (data['clientes'] as List?) ?? const [];
    final rawSucursales = (data['sucursales'] as List?) ?? (data['direcciones'] as List?) ?? const [];
    final rawTecnicos = (data['tecnicos'] as List?) ?? const [];
    final rawTiposSvc = (data['tipos_servicio'] as List?) ?? const [];
    final rawTiposInst = (data['tipos_instrumento'] as List?) ?? const [];
    final rawHistorial = (data['historial_instrumentos'] as List?) ?? const [];

    await db.transaction((txn) async {
      final batch = txn.batch();

      if (rawClientes.isNotEmpty) {
        batch.delete('catalogo_clientes');
        batch.delete('catalogo_sucursales');
        final seenClientIds = <int>{};
        final seenClientNames = <String>{};
        final insertedSucKeys = <String>{};

        for (final item in rawClientes) {
          if (item is! Map) continue;
          final c = Map<String, dynamic>.from(item);
          final cid = _toIntOrNull(c['id'] ?? c['id_cliente']);
          if (cid == null || cid <= 0) continue;
          final nombre = (c['nombre'] ?? c['razon_social'] ?? '').toString().trim();
          if (nombre.isEmpty) continue;
          final razon = (c['razon_social'] ?? nombre).toString().trim();
          final normKey = razon.toLowerCase();
          if (!seenClientIds.add(cid) || !seenClientNames.add(normKey)) continue;

          final correoCli = (c['correo'] ?? c['email'] ?? '').toString().trim();
          final dirCli = (c['direccion'] ?? '').toString().trim();
          final rawNested = (c['sucursales'] as List?) ?? (c['direcciones'] as List?) ?? const [];

          final cleanNested = <Map<String, dynamic>>[];
          final seenPerCli = <String>{};
          for (final sItem in rawNested) {
            if (sItem is! Map) continue;
            final parsed = _parseSucursalRow(sItem, fallbackClienteId: cid, fallbackClienteNombre: razon);
            final n = (parsed['nombre'] ?? '').toString().trim();
            final d = (parsed['direccion'] ?? '').toString().trim();
            if (n.isEmpty && d.isEmpty) continue;
            if (seenPerCli.add('${n.toLowerCase()}|${d.toLowerCase()}')) {
              cleanNested.add(parsed);
            }
          }
          if (dirCli.isNotEmpty &&
              !cleanNested.any((s) =>
                  (s['direccion'] ?? '').toString().toLowerCase() == dirCli.toLowerCase() ||
                  (s['nombre'] ?? '').toString().toLowerCase() == dirCli.toLowerCase())) {
            cleanNested.add({
              'id': null,
              'sucursal_id': null,
              'cliente_id': cid,
              'cliente_nombre': razon,
              'nombre': dirCli.length <= 80 ? dirCli : 'Matriz / Principal',
              'nombre_sucursal': 'Matriz / Principal',
              'planta': 'Matriz / Principal',
              'direccion': dirCli,
              'ciudad': '',
              'contacto': (c['contacto_nombre'] ?? '').toString().trim(),
              'telefono': (c['telefono'] ?? '').toString().trim(),
              'correo': correoCli,
            });
          }

          batch.insert(
            'catalogo_clientes',
            {
              'id': cid,
              'nombre': nombre,
              'razon_social': razon,
              'rfc': (c['rfc'] ?? '').toString().trim(),
              'correo': correoCli,
              'telefono': (c['telefono'] ?? '').toString().trim(),
              'direccion': dirCli,
              'sucursales_json': jsonEncode(cleanNested),
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          for (final s in cleanNested) {
            final sNom = (s['nombre'] ?? '').toString().trim();
            final sDir = (s['direccion'] ?? '').toString().trim();
            if (sNom.isEmpty && sDir.isEmpty) continue;
            final skey = '$cid|${sNom.toLowerCase()}|${sDir.toLowerCase()}';
            if (!insertedSucKeys.add(skey)) continue;
            batch.insert(
              'catalogo_sucursales',
              {
                'sucursal_id': _toIntOrNull(s['id'] ?? s['sucursal_id']),
                'cliente_id': cid,
                'cliente_nombre': razon,
                'nombre': sNom.isNotEmpty ? sNom : sDir,
                'direccion': sDir.isNotEmpty ? sDir : sNom,
                'ciudad': (s['ciudad'] ?? '').toString().trim(),
                'contacto': (s['contacto'] ?? '').toString().trim(),
                'telefono': (s['telefono'] ?? '').toString().trim(),
                'correo': (s['correo'] ?? '').toString().trim(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        if (rawSucursales.isNotEmpty) {
          for (final sItem in rawSucursales) {
            if (sItem is! Map) continue;
            final parsed = _parseSucursalRow(sItem);
            final cid = _toIntOrNull(parsed['cliente_id']) ?? 0;
            final sNom = (parsed['nombre'] ?? '').toString().trim();
            final sDir = (parsed['direccion'] ?? '').toString().trim();
            if (sNom.isEmpty && sDir.isEmpty) continue;
            final skey = '$cid|${sNom.toLowerCase()}|${sDir.toLowerCase()}';
            if (!insertedSucKeys.add(skey)) continue;
            batch.insert(
              'catalogo_sucursales',
              {
                'sucursal_id': _toIntOrNull(parsed['id'] ?? parsed['sucursal_id']),
                'cliente_id': cid,
                'cliente_nombre': (parsed['cliente_nombre'] ?? '').toString().trim(),
                'nombre': sNom.isNotEmpty ? sNom : sDir,
                'direccion': sDir.isNotEmpty ? sDir : sNom,
                'ciudad': (parsed['ciudad'] ?? '').toString().trim(),
                'contacto': (parsed['contacto'] ?? '').toString().trim(),
                'telefono': (parsed['telefono'] ?? '').toString().trim(),
                'correo': (parsed['correo'] ?? '').toString().trim(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      } else if (rawSucursales.isNotEmpty) {
        for (final sItem in rawSucursales) {
          if (sItem is! Map) continue;
          final parsed = _parseSucursalRow(sItem);
          final cid = _toIntOrNull(parsed['cliente_id']) ?? 0;
          final sNom = (parsed['nombre'] ?? '').toString().trim();
          final sDir = (parsed['direccion'] ?? '').toString().trim();
          if (sNom.isEmpty && sDir.isEmpty) continue;
          batch.insert(
            'catalogo_sucursales',
            {
              'sucursal_id': _toIntOrNull(parsed['id'] ?? parsed['sucursal_id']),
              'cliente_id': cid,
              'cliente_nombre': (parsed['cliente_nombre'] ?? '').toString().trim(),
              'nombre': sNom.isNotEmpty ? sNom : sDir,
              'direccion': sDir.isNotEmpty ? sDir : sNom,
              'ciudad': (parsed['ciudad'] ?? '').toString().trim(),
              'contacto': (parsed['contacto'] ?? '').toString().trim(),
              'telefono': (parsed['telefono'] ?? '').toString().trim(),
              'correo': (parsed['correo'] ?? '').toString().trim(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      if (rawTecnicos.isNotEmpty) {
        batch.delete('catalogo_tecnicos');
        for (final tItem in rawTecnicos) {
          if (tItem is! Map) continue;
          final t = Map<String, dynamic>.from(tItem);
          final tid = _toIntOrNull(t['id'] ?? t['id_tecnico']);
          final nom = (t['nombre'] ?? t['nombre_completo'] ?? '').toString().trim();
          if (tid == null || tid <= 0 || nom.isEmpty) continue;
          batch.insert(
            'catalogo_tecnicos',
            {
              'id': tid,
              'nombre': nom,
              'username': (t['username'] ?? '').toString().trim(),
              'rol': (t['rol'] ?? 'TECNICO').toString().trim(),
              'activo': _toBoolInt(t['activo'] ?? true),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      if (rawTiposSvc.isNotEmpty) {
        batch.delete('catalogo_tipos_servicio');
        for (final tsItem in rawTiposSvc) {
          if (tsItem is! Map) continue;
          final ts = Map<String, dynamic>.from(tsItem);
          final id = _toIntOrNull(ts['id']);
          final nom = (ts['nombre'] ?? '').toString().trim();
          if (id == null || id <= 0 || nom.isEmpty) continue;
          batch.insert(
            'catalogo_tipos_servicio',
            {
              'id': id,
              'nombre': nom,
              'codigo': (ts['codigo'] ?? '').toString().trim(),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      if (rawTiposInst.isNotEmpty) {
        batch.delete('catalogo_tipos_instrumento');
        for (final tiItem in rawTiposInst) {
          if (tiItem is! Map) continue;
          final ti = Map<String, dynamic>.from(tiItem);
          final id = _toIntOrNull(ti['id']);
          final nom = (ti['nombre'] ?? '').toString().trim();
          if (id == null || id <= 0 || nom.isEmpty) continue;
          batch.insert(
            'catalogo_tipos_instrumento',
            {
              'id': id,
              'nombre': nom,
              'aplica_excentricidad': _toBoolInt(ti['aplica_excentricidad'] ?? true),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      if (rawHistorial.isNotEmpty) {
        for (final hItem in rawHistorial) {
          if (hItem is! Map) continue;
          final h = Map<String, dynamic>.from(hItem);
          final marca = (h['marca'] ?? '').toString().trim();
          final modelo = (h['modelo'] ?? '').toString().trim();
          final serie = (h['serie'] ?? h['ns'] ?? '').toString().trim();
          final idInd = (h['id_indicador'] ?? h['id_equipo'] ?? '').toString().trim();
          if (marca.isEmpty && modelo.isEmpty && serie.isEmpty && idInd.isEmpty) continue;
          batch.insert(
            'historial_instrumentos',
            {
              'cliente_id': _toIntOrNull(h['cliente_id'] ?? h['id_cliente']),
              'cliente_nombre': (h['cliente'] ?? h['cliente_nombre'] ?? '').toString().trim(),
              'sucursal_id': _toIntOrNull(h['sucursal_id']),
              'sucursal_nombre': (h['sucursal'] ?? h['sucursal_nombre'] ?? '').toString().trim(),
              'marca': marca,
              'modelo': modelo,
              'serie': serie,
              'id_indicador': idInd,
              'capacidad_maxima': (h['capacidad_maxima'] ?? h['alcance_max'] ?? '').toString().trim(),
              'division_minima': (h['division_minima'] ?? h['div_minima'] ?? '').toString().trim(),
              'ubicacion': (h['ubicacion'] ?? '').toString().trim(),
              'tipo_instrumento': (h['tipo_instrumento'] ?? '').toString().trim(),
              'numero_cca': (h['numero_cca'] ?? '').toString().trim(),
              'numero_dve': (h['numero_dve'] ?? '').toString().trim(),
              'updated_at': nowIso,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (marca.isNotEmpty && modelo.isNotEmpty) {
            batch.insert(
              'catalogo_marcas_modelos',
              {'marca': marca, 'modelo': modelo},
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        }
      }

      await batch.commit(noResult: true);
    });
    debugPrint('[LocalDB] ✅ Catálogos Admin guardados: ${rawClientes.length} clientes, ${rawTecnicos.length} técnicos, ${rawHistorial.length} instrumentos');
  }

  /// Devuelve el catálogo completo de clientes con sus sucursales/direcciones anidadas.
  Future<List<Map<String, dynamic>>> getCatalogoClientes() async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final rows = await db.rawQuery(
      'SELECT * FROM catalogo_clientes ORDER BY nombre COLLATE NOCASE ASC',
    );
    if (rows.isNotEmpty) {
      final result = <Map<String, dynamic>>[];
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r);
        List<Map<String, dynamic>> sucs = [];
        final rawJson = m['sucursales_json']?.toString();
        if (rawJson != null && rawJson.trim().isNotEmpty) {
          try {
            final dec = jsonDecode(rawJson);
            if (dec is List) {
              sucs = dec.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
            }
          } catch (_) {}
        }
        m['sucursales'] = sucs;
        result.add(m);
      }
      return result;
    }

    // Fallback: derivar clientes y direcciones desde ordenes_servicio locales
    final derived = await db.rawQuery('''
      SELECT DISTINCT TRIM(cliente) AS nombre,
             COALESCE(NULLIF(TRIM(direccion), ''), TRIM(sucursal), '') AS direccion
      FROM ordenes_servicio
      WHERE cliente IS NOT NULL AND TRIM(cliente) != ''
      ORDER BY cliente COLLATE NOCASE ASC
    ''');
    final byName = <String, Map<String, dynamic>>{};
    int fakeId = 1;
    for (final r in derived) {
      final nom = (r['nombre'] ?? '').toString().trim();
      if (nom.isEmpty) continue;
      final dir = (r['direccion'] ?? '').toString().trim();
      final entry = byName.putIfAbsent(nom, () => {
        'id': fakeId++,
        'nombre': nom,
        'razon_social': nom,
        'rfc': '',
        'telefono': '',
        'direccion': dir,
        'sucursales': <Map<String, dynamic>>[],
      });
      if (dir.isNotEmpty) {
        final list = entry['sucursales'] as List<Map<String, dynamic>>;
        if (!list.any((s) => (s['direccion'] ?? '') == dir || (s['nombre'] ?? '') == dir)) {
          list.add({'id': null, 'nombre': dir, 'direccion': dir});
        }
      }
    }
    return byName.values.toList();
  }

  /// Devuelve todas las sucursales/direcciones registradas para un cliente (por ID y/o nombre).
  Future<List<Map<String, dynamic>>> getCatalogoSucursales({
    int? clienteId,
    String? clienteNombre,
  }) async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addBranch(Map<String, dynamic> raw) {
      final nom = (raw['nombre'] ?? raw['nombre_sucursal'] ?? raw['planta'] ?? raw['sucursal'] ?? '').toString().trim();
      final dir = (raw['direccion'] ?? '').toString().trim();
      if (nom.isEmpty && dir.isEmpty) return;
      final key = '${nom.toLowerCase()}|${dir.toLowerCase()}';
      if (seen.contains(key)) return;
      seen.add(key);
      out.add({
        'id': _toIntOrNull(raw['sucursal_id'] ?? raw['id']),
        'sucursal_id': _toIntOrNull(raw['sucursal_id'] ?? raw['id']),
        'cliente_id': _toIntOrNull(raw['cliente_id']),
        'nombre': nom.isNotEmpty ? nom : dir,
        'nombre_sucursal': nom.isNotEmpty ? nom : dir,
        'direccion': dir.isNotEmpty ? dir : nom,
        'correo': (raw['correo'] ?? raw['email'] ?? '').toString().trim(),
        'ciudad': (raw['ciudad'] ?? '').toString().trim(),
        'contacto': (raw['contacto'] ?? raw['contacto_nombre'] ?? '').toString().trim(),
        'telefono': (raw['telefono'] ?? raw['contacto_telefono'] ?? '').toString().trim(),
      });
    }

    if (clienteId != null && clienteId > 0) {
      final rows = await db.query(
        'catalogo_sucursales',
        where: 'cliente_id = ?',
        whereArgs: [clienteId],
        orderBy: 'nombre COLLATE NOCASE ASC',
      );
      for (final r in rows) addBranch(r);

      final cliRows = await db.query(
        'catalogo_clientes',
        where: 'id = ?',
        whereArgs: [clienteId],
        limit: 1,
      );
      if (cliRows.isNotEmpty) {
        final cli = cliRows.first;
        final cliDir = (cli['direccion'] ?? '').toString().trim();
        if (cliDir.isNotEmpty) {
          addBranch({'id': null, 'cliente_id': clienteId, 'nombre': 'Matriz', 'direccion': cliDir});
        }
        final sj = cli['sucursales_json']?.toString();
        if (sj != null && sj.isNotEmpty) {
          try {
            final dec = jsonDecode(sj);
            if (dec is List) {
              for (final s in dec.whereType<Map>()) {
                addBranch(Map<String, dynamic>.from(s));
              }
            }
          } catch (_) {}
        }
      }
    }

    if (clienteNombre != null && clienteNombre.trim().isNotEmpty) {
      final nomTrim = clienteNombre.trim();
      final rowsByName = await db.rawQuery(
        'SELECT * FROM catalogo_sucursales WHERE LOWER(TRIM(cliente_nombre)) = LOWER(?) ORDER BY nombre COLLATE NOCASE ASC',
        [nomTrim],
      );
      for (final r in rowsByName) addBranch(r);

      // Enriquecer también con direcciones históricas reales en ordenes_servicio
      final histDirs = await db.rawQuery('''
        SELECT DISTINCT TRIM(sucursal) AS nombre, TRIM(direccion) AS direccion
        FROM ordenes_servicio
        WHERE LOWER(TRIM(cliente)) = LOWER(?)
          AND ((sucursal IS NOT NULL AND TRIM(sucursal) != '') OR (direccion IS NOT NULL AND TRIM(direccion) != ''))
        ORDER BY local_id DESC
        LIMIT 25
      ''', [nomTrim]);
      for (final r in histDirs) addBranch(r);
    }

    if (clienteId == null && (clienteNombre == null || clienteNombre.trim().isEmpty)) {
      final allRows = await db.rawQuery(
        'SELECT * FROM catalogo_sucursales ORDER BY cliente_nombre COLLATE NOCASE ASC, nombre COLLATE NOCASE ASC',
      );
      for (final r in allRows) addBranch(r);
    }

    return out;
  }

  /// Devuelve el catálogo completo de técnicos activos.
  Future<List<Map<String, dynamic>>> getCatalogoTecnicos() async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final rows = await db.rawQuery(
      'SELECT * FROM catalogo_tecnicos WHERE COALESCE(activo, 1) = 1 ORDER BY nombre COLLATE NOCASE ASC',
    );
    if (rows.isNotEmpty) {
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    // Fallback offline garantizado con los técnicos oficiales de Básculas PESA
    return const [
      {'id': 8, 'nombre': 'Alan Guevara', 'rol': 'TECNICO'},
      {'id': 10, 'nombre': 'Alan Terrazas', 'rol': 'TECNICO'},
      {'id': 7, 'nombre': 'Alessandro Segovia', 'rol': 'TECNICO'},
      {'id': 4, 'nombre': 'Fernando Arias', 'rol': 'TECNICO'},
      {'id': 44, 'nombre': 'Jhonny Jiménez', 'rol': 'TECNICO'},
      {'id': 171, 'nombre': 'José Landaverde', 'rol': 'TECNICO'},
      {'id': 9, 'nombre': 'Néstor Arias', 'rol': 'TECNICO'},
      {'id': 11, 'nombre': 'Adriana Arias', 'rol': 'LOGISTICA'},
      {'id': 2, 'nombre': 'Iván Colín', 'rol': 'ADMIN'},
    ];
  }

  /// Devuelve el catálogo de tipos de servicio.
  Future<List<Map<String, dynamic>>> getCatalogoTiposServicio() async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final rows = await db.rawQuery(
      'SELECT * FROM catalogo_tipos_servicio ORDER BY id ASC',
    );
    if (rows.isNotEmpty) {
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    return const [
      {'id': 1, 'nombre': 'Calibración'},
      {'id': 2, 'nombre': 'Calibración + Ajuste'},
      {'id': 3, 'nombre': 'Calibración + Ajuste + Inspección'},
      {'id': 4, 'nombre': 'Inspección (Verificación UVA)'},
      {'id': 5, 'nombre': 'Mantenimiento Preventivo'},
      {'id': 6, 'nombre': 'Mantenimiento Correctivo'},
      {'id': 7, 'nombre': 'Instalación y Puesta en Marcha'},
    ];
  }

  /// Devuelve el catálogo de tipos de instrumento.
  Future<List<Map<String, dynamic>>> getCatalogoTiposInstrumento() async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final rows = await db.rawQuery(
      'SELECT * FROM catalogo_tipos_instrumento ORDER BY nombre COLLATE NOCASE ASC',
    );
    if (rows.isNotEmpty) {
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    return const [
      {'id': 1, 'nombre': 'Báscula de plataforma', 'aplica_excentricidad': 1},
      {'id': 2, 'nombre': 'Báscula camionera', 'aplica_excentricidad': 1},
      {'id': 3, 'nombre': 'Báscula de mostrador', 'aplica_excentricidad': 1},
      {'id': 4, 'nombre': 'Báscula analítica / precisión', 'aplica_excentricidad': 1},
      {'id': 5, 'nombre': 'Báscula colgante / Grúa', 'aplica_excentricidad': 0},
      {'id': 6, 'nombre': 'Tolva / Tanque / Silo', 'aplica_excentricidad': 0},
      {'id': 7, 'nombre': 'Patín hidráulico', 'aplica_excentricidad': 0},
    ];
  }

  /// Devuelve el historial de instrumentos priorizando coincidencias del cliente y sucursal,
  /// combinando `historial_instrumentos` y `ordenes_servicio` para autocompletado instantáneo.
  Future<List<Map<String, dynamic>>> getHistorialInstrumentos({
    int? clienteId,
    String? cliente,
    int? sucursalId,
    String? sucursal,
  }) async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);

    final cliNorm = normalizarTexto(cliente ?? '');
    final sucNorm = normalizarTexto(sucursal ?? '');

    final rowsHist = await db.rawQuery('''
      SELECT * FROM historial_instrumentos
      ORDER BY updated_at DESC, id DESC
      LIMIT 600
    ''');

    final rowsOs = await db.rawQuery('''
      SELECT DISTINCT
        id_cliente AS cliente_id,
        COALESCE(TRIM(cliente), '') AS cliente_nombre,
        sucursal_id,
        COALESCE(NULLIF(TRIM(sucursal), ''), TRIM(direccion), '') AS sucursal_nombre,
        COALESCE(TRIM(marca), '') AS marca,
        COALESCE(TRIM(modelo), '') AS modelo,
        COALESCE(TRIM(ns), '') AS serie,
        COALESCE(TRIM(id_equipo), '') AS id_indicador,
        COALESCE(NULLIF(TRIM(instrumento_capacidad), ''), CAST(alcance_max AS TEXT), '') AS capacidad_maxima,
        COALESCE(NULLIF(TRIM(instrumento_division), ''), CAST(div_minima AS TEXT), '') AS division_minima,
        COALESCE(TRIM(ubicacion), '') AS ubicacion,
        COALESCE(TRIM(tipo_instrumento), '') AS tipo_instrumento,
        COALESCE(TRIM(numero_cca), '') AS numero_cca,
        COALESCE(TRIM(numero_dve), '') AS numero_dve
      FROM ordenes_servicio
      WHERE (marca IS NOT NULL AND TRIM(marca) != '')
         OR (modelo IS NOT NULL AND TRIM(modelo) != '')
         OR (ns IS NOT NULL AND TRIM(ns) != '')
         OR (id_equipo IS NOT NULL AND TRIM(id_equipo) != '')
      ORDER BY local_id DESC
      LIMIT 400
    ''');

    final combined = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final raw in [...rowsHist, ...rowsOs]) {
      final marca = (raw['marca'] ?? '').toString().trim();
      final modelo = (raw['modelo'] ?? '').toString().trim();
      final serie = (raw['serie'] ?? raw['ns'] ?? '').toString().trim();
      final idInd = (raw['id_indicador'] ?? raw['id_equipo'] ?? '').toString().trim();
      final ubic = (raw['ubicacion'] ?? '').toString().trim();
      if (marca.isEmpty && modelo.isEmpty && serie.isEmpty && idInd.isEmpty) continue;

      final cNom = (raw['cliente_nombre'] ?? raw['cliente'] ?? '').toString().trim();
      final sNom = (raw['sucursal_nombre'] ?? raw['sucursal'] ?? '').toString().trim();
      final cId = _toIntOrNull(raw['cliente_id']);
      final sId = _toIntOrNull(raw['sucursal_id']);

      final dedupKey = '${cNom.toLowerCase()}|${marca.toLowerCase()}|${modelo.toLowerCase()}|${serie.toLowerCase()}|${idInd.toLowerCase()}|${ubic.toLowerCase()}';
      if (seen.contains(dedupKey)) continue;
      seen.add(dedupKey);

      int prio = 3;
      final matchCli = (clienteId != null && clienteId > 0 && cId == clienteId) ||
          (cliNorm.isNotEmpty && normalizarTexto(cNom) == cliNorm) ||
          (cliNorm.isNotEmpty && cNom.isNotEmpty && (normalizarTexto(cNom).contains(cliNorm) || cliNorm.contains(normalizarTexto(cNom))));
      if (matchCli) {
        final matchSuc = (sucursalId != null && sucursalId > 0 && sId == sucursalId) ||
            (sucNorm.isNotEmpty && sNom.isNotEmpty && (normalizarTexto(sNom) == sucNorm || normalizarTexto(sNom).contains(sucNorm)));
        prio = matchSuc ? 0 : 1;
      }

      combined.add({
        'cliente_id': cId,
        'cliente': cNom,
        'sucursal_id': sId,
        'sucursal': sNom,
        'marca': marca,
        'modelo': modelo,
        'serie': serie,
        'id_indicador': idInd,
        'capacidad_maxima': (raw['capacidad_maxima'] ?? '').toString().replaceAll(RegExp(r'\.0$'), '').trim(),
        'division_minima': (raw['division_minima'] ?? '').toString().trim(),
        'ubicacion': ubic,
        'tipo_instrumento': (raw['tipo_instrumento'] ?? '').toString().trim(),
        'numero_cca': (raw['numero_cca'] ?? '').toString().trim(),
        'numero_dve': (raw['numero_dve'] ?? '').toString().trim(),
        '_prio': prio,
      });
    }

    combined.sort((a, b) {
      final pa = a['_prio'] as int? ?? 3;
      final pb = b['_prio'] as int? ?? 3;
      if (pa != pb) return pa.compareTo(pb);
      final ma = (a['marca'] ?? '').toString().toLowerCase();
      final mb = (b['marca'] ?? '').toString().toLowerCase();
      return ma.compareTo(mb);
    });

    // Si hay equipos del cliente seleccionado, mostrarlos primero (y también conservar catálogo general al final)
    return combined;
  }

  /// Guarda/actualiza los datos del instrumento de una orden de forma PARCIAL en SQLite
  /// SIN finalizar ni cerrar la orden (mantiene estatus 'En Proceso' / 'Asignada').
  Future<Map<String, dynamic>> guardarInstrumentoParcialLocal(
    String folio,
    Map<String, dynamic> datos, {
    int? localId,
    bool encolarSync = true,
  }) async {
    final folioKey = folio.trim();
    if (folioKey.isEmpty) return {};
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final existing = await getOsByFolio(folioKey);
    Map<String, dynamic> dtMap = {};
    if (existing != null && existing['datos_tecnicos_json'] != null) {
      try {
        final rawDt = existing['datos_tecnicos_json'];
        final dec = rawDt is String ? jsonDecode(rawDt) : rawDt;
        if (dec is Map) dtMap = Map<String, dynamic>.from(dec);
      } catch (_) {}
    }

    final marca = (datos['marca'] ?? '').toString().trim();
    final modelo = (datos['modelo'] ?? '').toString().trim();
    final serie = (datos['serie'] ?? datos['ns'] ?? '').toString().trim();
    final idInd = (datos['id_indicador'] ?? datos['id_equipo'] ?? '').toString().trim();
    final capStr = (datos['capacidad_maxima'] ?? datos['instrumento_capacidad'] ?? datos['alcance_max'] ?? '').toString().trim();
    final divStr = (datos['division_minima'] ?? datos['instrumento_division'] ?? datos['div_minima'] ?? '').toString().trim();
    final ubicacion = (datos['ubicacion'] ?? '').toString().trim();
    final tipoInst = (datos['tipo_instrumento'] ?? '').toString().trim();
    final numCca = (datos['numero_cca'] ?? datos['cca'] ?? '').toString().trim();
    final numDve = (datos['numero_dve'] ?? datos['folio_dve'] ?? '').toString().trim();
    final motivoNoExc = (datos['motivo_no_excentricidad'] ?? '').toString().trim();
    final bool? aplicaExc = datos['aplica_excentricidad'] is bool
        ? datos['aplica_excentricidad'] as bool
        : (datos['aplica_excentricidad'] != null ? _toBoolInt(datos['aplica_excentricidad']) == 1 : null);

    dtMap['marca'] = marca;
    dtMap['modelo'] = modelo;
    dtMap['serie'] = serie;
    dtMap['ns'] = serie;
    dtMap['id_indicador'] = idInd;
    dtMap['id_equipo'] = idInd;
    if (capStr.isNotEmpty) dtMap['capacidad_maxima'] = capStr;
    if (divStr.isNotEmpty) dtMap['division_minima'] = divStr;
    dtMap['ubicacion'] = ubicacion;
    if (tipoInst.isNotEmpty) dtMap['tipo_instrumento'] = tipoInst;
    dtMap['numero_cca'] = numCca;
    dtMap['cca'] = numCca;
    dtMap['numero_dve'] = numDve;
    dtMap['folio_dve'] = numDve;
    if (aplicaExc != null) dtMap['aplica_excentricidad'] = aplicaExc;
    if (motivoNoExc.isNotEmpty) dtMap['motivo_no_excentricidad'] = motivoNoExc;
    dtMap.remove('instrumento_limpio_manual');

    final double? capNum = double.tryParse(capStr.split(' ').first.replaceAll(',', '.'));
    final double? divNum = double.tryParse(divStr.split(' ').first.replaceAll(',', '.'));

    final String prevEstado = (existing?['estado'] ?? '').toString().toUpperCase().trim();
    final bool yaCerrada = {'CERRADO', 'CERRADA', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA'}.contains(prevEstado);

    final updates = <String, dynamic>{
      'marca': marca,
      'modelo': modelo,
      'ns': serie,
      'id_equipo': idInd,
      'ubicacion': ubicacion,
      'numero_cca': numCca,
      'numero_dve': numDve,
      if (tipoInst.isNotEmpty) 'tipo_instrumento': tipoInst,
      if (capStr.isNotEmpty) 'instrumento_capacidad': capStr,
      if (capNum != null) 'alcance_max': capNum,
      if (divStr.isNotEmpty) 'instrumento_division': divStr,
      if (divNum != null) 'div_minima': divNum,
      if (aplicaExc != null) 'aplica_excentricidad': aplicaExc ? 1 : 0,
      if (motivoNoExc.isNotEmpty) 'motivo_no_excentricidad': motivoNoExc,
      'datos_tecnicos_json': jsonEncode(dtMap),
      if (!yaCerrada) 'estado': 'PROCESO',
      if (!yaCerrada) 'estatus': 'En Proceso',
      'updated_at': nowIso,
    };

    if (localId != null && localId > 0) {
      await db.update('ordenes_servicio', updates, where: 'local_id = ?', whereArgs: [localId]);
    } else {
      await db.update('ordenes_servicio', updates, where: 'folio_os = ? OR folio = ?', whereArgs: [folioKey, folioKey]);
    }

    // Fusionar en borrador local para que al reabrir la captura todo persista
    try {
      final draftActual = await getDraft(folioKey) ?? <String, dynamic>{};
      draftActual.addAll({
        'marca': marca,
        'modelo': modelo,
        'ns': serie,
        'serie': serie,
        'id_equipo': idInd,
        'id_indicador': idInd,
        'ubicacion': ubicacion,
        'numero_cca': numCca,
        'cca': numCca,
        'numero_dve': numDve,
        'folio_dve': numDve,
        if (capStr.isNotEmpty) 'alcance_max': capStr,
        if (divStr.isNotEmpty) 'div_minima': divStr,
        if (tipoInst.isNotEmpty) 'tipo_instrumento': tipoInst,
        if (aplicaExc != null) 'aplica_excentricidad': aplicaExc,
        if (motivoNoExc.isNotEmpty) 'motivo_no_excentricidad': motivoNoExc,
      });
      await saveDraft(folioKey, draftActual);
    } catch (_) {}

    // Alimentar historial local de instrumentos y marcas/modelos para autocompletado inmediato
    if (marca.isNotEmpty || modelo.isNotEmpty || serie.isNotEmpty || idInd.isNotEmpty) {
      try {
        await db.insert(
          'historial_instrumentos',
          {
            'cliente_id': _toIntOrNull(existing?['id_cliente']),
            'cliente_nombre': (existing?['cliente'] ?? '').toString().trim(),
            'sucursal_id': _toIntOrNull(existing?['sucursal_id']),
            'sucursal_nombre': (existing?['sucursal'] ?? existing?['direccion'] ?? '').toString().trim(),
            'marca': marca,
            'modelo': modelo,
            'serie': serie,
            'id_indicador': idInd,
            'capacidad_maxima': capStr,
            'division_minima': divStr,
            'ubicacion': ubicacion,
            'tipo_instrumento': tipoInst,
            'numero_cca': numCca,
            'numero_dve': numDve,
            'updated_at': nowIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
    }
    if (marca.isNotEmpty && modelo.isNotEmpty) {
      await saveMarcaModelo(marca, modelo);
    }

    if (encolarSync) {
      final syncPayload = <String, dynamic>{
        'folio_os': folioKey,
        'marca': marca,
        'modelo': modelo,
        'serie': serie,
        'ns': serie,
        'id_indicador': idInd,
        'id_equipo': idInd,
        'capacidad_maxima': capStr,
        'division_minima': divStr,
        'ubicacion': ubicacion,
        'tipo_instrumento': tipoInst,
        'numero_cca': numCca,
        'numero_dve': numDve,
        if (aplicaExc != null) 'aplica_excentricidad': aplicaExc,
        if (motivoNoExc.isNotEmpty) 'motivo_no_excentricidad': motivoNoExc,
      };
      await db.insert(
        'cola_instrumento_parcial',
        {
          'folio_os': folioKey,
          'payload_json': jsonEncode(syncPayload),
          'updated_at': nowIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    return updates;
  }

  Future<List<Map<String, dynamic>>> getColaInstrumentoParcial() async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    return await db.query('cola_instrumento_parcial', orderBy: 'updated_at ASC');
  }

  Future<Set<String>> getFoliosEnColaInstrumentoParcial() async {
    final rows = await getColaInstrumentoParcial();
    return rows
        .map((r) => (r['folio_os'] ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  Future<void> eliminarDeColaInstrumentoParcial(String folio) async {
    final db = await _ensureInit();
    await _asegurarTablasCatalogosAdmin(db);
    await db.delete(
      'cola_instrumento_parcial',
      where: 'folio_os = ?',
      whereArgs: [folio.trim()],
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