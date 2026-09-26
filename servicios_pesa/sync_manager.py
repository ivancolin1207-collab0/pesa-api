"""
sync_manager.py — Motor de Sincronización Offline-First
Servicios PESA v3.0

Arquitectura:
    SQLite Local (pesa_local.db)  ←→  SyncManager  ←→  PostgreSQL Central

Modos de operación:
    • OFICINA (conectado):  Descarga asignaciones y catálogos a SQLite.
    • CAMPO (offline):      La app opera 100% sobre SQLite, sin errores de red.
    • RETORNO (reconectado): Sube registros PENDING y PDFs a PostgreSQL.

Uso típico:
    from sync_manager import sync_manager

    # Verificar conectividad
    if sync_manager.is_online():
        sync_manager.download_assignments()

    # Guardar desde formulario táctil (siempre funciona)
    sync_manager.save_local_service(folio, data, pdf_path)

    # Al regresar a la oficina
    n = sync_manager.upload_pending()
    print(f"{n} registros sincronizados")
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Generator, Optional

logger = logging.getLogger(__name__)

# ── Ruta de la base de datos local ────────────────────────────────────────────
try:
    from config import LOCAL_DB_PATH, TABLET_PDF_DIR, APP_DATA_DIR
except ImportError:
    # Fallback multiplataforma (nunca usa rutas de solo lectura)
    import platform as _platform
    if _platform.system() == "Darwin":
        _base = Path.home() / "Library" / "Application Support" / "PesaServicios"
    elif _platform.system() == "Windows":
        _base = Path(os.environ.get("APPDATA") or str(Path.home())) / "PesaServicios"
    else:
        _base = Path.home() / ".pesaservicios"
    _base.mkdir(parents=True, exist_ok=True)
    APP_DATA_DIR   = _base
    LOCAL_DB_PATH  = str(_base / "pesa_local.db")
    TABLET_PDF_DIR = str(Path.home() / "Documents" / "PESA_Tablet" / "Formatos_Generados")

# ── Versión del esquema SQLite local ──────────────────────────────────────────
_SCHEMA_VERSION = 1

# ── DDL del esquema SQLite local ──────────────────────────────────────────────
_SCHEMA_SQL = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
);

-- ── Catálogos (descargados desde PostgreSQL) ──────────────────────────────
CREATE TABLE IF NOT EXISTS cat_clientes (
    id            INTEGER PRIMARY KEY,
    razon_social  TEXT NOT NULL,
    direccion     TEXT,
    rfc           TEXT,
    updated_at    TEXT
);

CREATE TABLE IF NOT EXISTS cat_tecnicos (
    id               INTEGER PRIMARY KEY,
    nombre_completo  TEXT NOT NULL,
    activo           INTEGER DEFAULT 1,
    updated_at       TEXT
);

CREATE TABLE IF NOT EXISTS cliente_sucursales (
    id               INTEGER PRIMARY KEY,
    id_cliente       INTEGER,
    nombre_sucursal  TEXT,
    direccion        TEXT,
    updated_at       TEXT
);

CREATE TABLE IF NOT EXISTS cat_tipo_servicio (
    id      INTEGER PRIMARY KEY,
    nombre  TEXT NOT NULL
);

-- ── Órdenes de Servicio (núcleo offline) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS ordenes_servicio (
    id                      INTEGER PRIMARY KEY,
    folio_os                TEXT NOT NULL UNIQUE,
    fecha                   TEXT,
    id_tipo_servicio        INTEGER,
    tipo_servicio_nombre    TEXT,
    id_cliente              INTEGER,
    cliente_nombre          TEXT,
    id_sucursal             INTEGER,
    sucursal_nombre         TEXT,
    id_tecnico              INTEGER,
    tecnico_nombre          TEXT,
    marca                   TEXT,
    modelo                  TEXT,
    ns                      TEXT,
    ubicacion               TEXT,
    alcance_max             REAL,
    div_minima              REAL,
    div_verificacion        REAL,
    observaciones           TEXT,
    firma_cliente_nombre    TEXT,
    firma_tecnico_b64       TEXT,
    firma_cliente_b64       TEXT,
    estado                  TEXT DEFAULT 'PROCESO',
    modalidad               TEXT DEFAULT 'DIGITAL',
    pdf_path                TEXT,
    sync_status             TEXT NOT NULL DEFAULT 'PENDING',
    updated_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    created_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_local_os_sync   ON ordenes_servicio(sync_status);
CREATE INDEX IF NOT EXISTS idx_local_os_folio  ON ordenes_servicio(folio_os);
CREATE INDEX IF NOT EXISTS idx_local_os_date   ON ordenes_servicio(fecha DESC);

-- ── Detalle Metrológico (tablas de pruebas) ───────────────────────────────
CREATE TABLE IF NOT EXISTS det_repetibilidad (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    id_os            INTEGER NOT NULL,
    posicion_id      INTEGER NOT NULL,
    lectura_inicial  REAL,
    lectura_final    REAL,
    UNIQUE(id_os, posicion_id)
);

CREATE TABLE IF NOT EXISTS det_excentricidad (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    id_os            INTEGER NOT NULL,
    posicion_id      INTEGER NOT NULL,
    lectura_inicial  REAL,
    lectura_final    REAL,
    UNIQUE(id_os, posicion_id)
);

CREATE TABLE IF NOT EXISTS det_exactitud (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    id_os            INTEGER NOT NULL,
    punto_id         INTEGER NOT NULL,
    valor_nominal    REAL,
    lectura_inicial  REAL,
    lectura_final    REAL,
    UNIQUE(id_os, punto_id)
);

-- ── Cola de PDFs pendientes de subir ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS pdf_upload_queue (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    id_os       INTEGER NOT NULL,
    folio_os    TEXT NOT NULL,
    pdf_path    TEXT NOT NULL,
    queued_at   TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    attempts    INTEGER DEFAULT 0
);
"""


# ══════════════════════════════════════════════════════════════════════════════
class SyncManager:
    """
    Motor de sincronización offline-first.
    Thread-safe: usa un lock por conexión SQLite y opera el pool de PostgreSQL
    únicamente cuando hay conectividad confirmada.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._local_db_path = Path(LOCAL_DB_PATH)
        self._tablet_pdf_dir = Path(TABLET_PDF_DIR)
        self._init_local_db()

    # ── Inicialización de SQLite ──────────────────────────────────────────────

    def _init_local_db(self) -> None:
        """Crea el directorio y el esquema SQLite si no existen."""
        self._local_db_path.parent.mkdir(parents=True, exist_ok=True)
        self._tablet_pdf_dir.mkdir(parents=True, exist_ok=True)

        with self._get_local_conn() as conn:
            conn.executescript(_SCHEMA_SQL)
            cur = conn.execute("SELECT COUNT(*) FROM schema_version")
            if cur.fetchone()[0] == 0:
                conn.execute("INSERT INTO schema_version VALUES (?)", (_SCHEMA_VERSION,))
            conn.commit()
        logger.info("SQLite local inicializado en: %s", self._local_db_path)

    @contextmanager
    def _get_local_conn(self) -> Generator[sqlite3.Connection, None, None]:
        """Context manager que entrega una conexión SQLite thread-safe."""
        with self._lock:
            conn = sqlite3.connect(
                str(self._local_db_path),
                timeout=10,
                detect_types=sqlite3.PARSE_DECLTYPES,
            )
            conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

    def get_local_db_path(self) -> str:
        """Retorna la ruta de la base de datos local."""
        return str(self._local_db_path)

    # ── Conectividad ─────────────────────────────────────────────────────────

    def is_online(self) -> bool:
        """
        Intenta conectar al pool de PostgreSQL.
        Retorna True si hay conectividad, False en cualquier otro caso.
        NO lanza excepciones.
        """
        try:
            from database.connection import db_pool
            conn = db_pool.get_connection()
            conn.cursor().execute("SELECT 1")
            db_pool.release_connection(conn)
            return True
        except Exception:
            return False

    # ── Descarga de asignaciones (Modo Oficina) ──────────────────────────────

    def download_assignments(
        self,
        id_tecnico: Optional[int] = None,
        limit: int = 200,
    ) -> int:
        """
        Descarga OS asignadas y catálogos desde PostgreSQL a SQLite local.

        Args:
            id_tecnico: ID del técnico activo (filtra sus asignaciones).
                        Si es None, descarga todas las OS en PROCESO.
            limit:      Máximo de OS a descargar.

        Returns:
            Número de OS descargadas/actualizadas.
        """
        if not self.is_online():
            logger.warning("download_assignments: sin conexión, omitiendo.")
            return 0

        try:
            from database.connection import db_pool
            pg_conn = db_pool.get_connection()
            downloaded = 0

            try:
                with pg_conn.cursor() as cur:
                    # ── Catálogos ────────────────────────────────────────────
                    self._sync_catalog(cur, "cat_clientes",
                                       "SELECT id, razon_social, direccion, rfc, NOW()::text FROM cat_clientes")
                    self._sync_catalog(cur, "cat_tecnicos",
                                       "SELECT id, nombre_completo, activo::int, NOW()::text FROM cat_tecnicos WHERE activo=TRUE")
                    self._sync_catalog(cur, "cliente_sucursales",
                                       "SELECT id, id_cliente, nombre_sucursal, direccion, NOW()::text FROM cliente_sucursales")
                    self._sync_catalog(cur, "cat_tipo_servicio",
                                       "SELECT id, nombre FROM cat_tipo_servicio ORDER BY id")

                    # ── OS asignadas ─────────────────────────────────────────
                    where = "AND os.id_tecnico = %s" if id_tecnico else ""
                    params: list = [id_tecnico] if id_tecnico else []

                    cur.execute(f"""
                        SELECT
                            os.id, os.folio_os, os.fecha::text,
                            os.id_tipo_servicio,
                            COALESCE(ts.nombre, os.tipo_servicio) AS tipo_servicio_nombre,
                            os.id_cliente, cl.razon_social,
                            os.id_sucursal,
                            COALESCE(suc.nombre_sucursal, os.ubicacion, '') AS sucursal_nombre,
                            os.id_tecnico, tc.nombre_completo,
                            os.marca, os.modelo, os.ns, os.ubicacion,
                            os.alcance_max, os.div_minima, os.div_verificacion,
                            os.observaciones, os.firma_cliente_nombre,
                            os.estado, os.modalidad,
                            COALESCE(os.pdf_path, '') AS pdf_path,
                            COALESCE(os.sync_status, 'SYNCED') AS sync_status,
                            COALESCE(os.updated_at::text, NOW()::text),
                            COALESCE(os.firma_tecnico_b64, tc.firma_digital, '') AS firma_tecnico_b64
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes      cl  ON os.id_cliente       = cl.id
                        LEFT JOIN cat_tecnicos      tc  ON os.id_tecnico       = tc.id
                        LEFT JOIN cat_tipo_servicio ts  ON os.id_tipo_servicio = ts.id
                        LEFT JOIN cliente_sucursales suc ON os.id_sucursal     = suc.id
                        WHERE os.estado NOT IN ('CANCELADA')
                        {where}
                        ORDER BY os.fecha DESC, os.created_at DESC
                        LIMIT %s
                    """, params + [limit])

                    rows = cur.fetchall()

                pg_conn.commit()

                with self._get_local_conn() as local:
                    for row in rows:
                        local.execute("""
                            INSERT INTO ordenes_servicio (
                                id, folio_os, fecha, id_tipo_servicio, tipo_servicio_nombre,
                                id_cliente, cliente_nombre, id_sucursal, sucursal_nombre,
                                id_tecnico, tecnico_nombre, marca, modelo, ns, ubicacion,
                                alcance_max, div_minima, div_verificacion, observaciones,
                                firma_cliente_nombre, estado, modalidad, pdf_path,
                                sync_status, updated_at, firma_tecnico_b64
                            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            ON CONFLICT(folio_os) DO UPDATE SET
                                fecha                = excluded.fecha,
                                estado               = excluded.estado,
                                tecnico_nombre       = excluded.tecnico_nombre,
                                cliente_nombre       = excluded.cliente_nombre,
                                sucursal_nombre      = excluded.sucursal_nombre,
                                observaciones        = excluded.observaciones,
                                pdf_path             = excluded.pdf_path,
                                firma_tecnico_b64    = COALESCE(excluded.firma_tecnico_b64,
                                                               ordenes_servicio.firma_tecnico_b64),
                                sync_status          = CASE
                                    WHEN ordenes_servicio.sync_status = 'PENDING'
                                    THEN 'PENDING'   -- No sobreescribir trabajo local
                                    ELSE excluded.sync_status
                                END,
                                updated_at           = excluded.updated_at
                        """, tuple(row))
                        downloaded += 1
                    local.commit()

            finally:
                db_pool.release_connection(pg_conn)

            logger.info("download_assignments: %d OS descargadas/actualizadas.", downloaded)
            return downloaded

        except Exception as exc:
            logger.error("Error en download_assignments: %s", exc)
            return 0

    def _sync_catalog(self, pg_cursor, local_table: str, sql: str) -> None:
        """Descarga un catálogo completo desde PostgreSQL a SQLite."""
        try:
            pg_cursor.execute(sql)
            rows = pg_cursor.fetchall()
            with self._get_local_conn() as local:
                local.execute(f"DELETE FROM {local_table}")
                if rows:
                    placeholders = ",".join(["?"] * len(rows[0]))
                    local.executemany(
                        f"INSERT OR REPLACE INTO {local_table} VALUES ({placeholders})",
                        rows
                    )
                local.commit()
        except Exception as exc:
            logger.warning("Error sincronizando catálogo %s: %s", local_table, exc)

    # ── Guardado local (Modo Campo) ──────────────────────────────────────────

    def save_local_service(
        self,
        folio_os: str,
        form_data: dict,
        pdf_path: Optional[str] = None,
    ) -> bool:
        """
        Guarda/actualiza una OS completa en SQLite local con sync_status='PENDING'.
        Se llama siempre desde el formulario táctil, independientemente de si
        hay conexión o no.

        Args:
            folio_os:  Folio de la OS (ej. "OS-2025-001").
            form_data: Diccionario con todos los datos del formulario digital.
            pdf_path:  Ruta local al PDF generado (opcional).

        Returns:
            True si se guardó correctamente.
        """
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            with self._get_local_conn() as conn:
                conn.execute("""
                    INSERT INTO ordenes_servicio (
                        folio_os, fecha, marca, modelo, ns, ubicacion,
                        observaciones, firma_cliente_nombre,
                        firma_tecnico_b64, firma_cliente_b64,
                        estado, modalidad, pdf_path,
                        sync_status, updated_at, created_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(folio_os) DO UPDATE SET
                        fecha               = excluded.fecha,
                        marca               = excluded.marca,
                        modelo              = excluded.modelo,
                        ns                  = excluded.ns,
                        ubicacion           = excluded.ubicacion,
                        observaciones       = excluded.observaciones,
                        firma_cliente_nombre= excluded.firma_cliente_nombre,
                        firma_tecnico_b64   = excluded.firma_tecnico_b64,
                        firma_cliente_b64   = excluded.firma_cliente_b64,
                        estado              = excluded.estado,
                        pdf_path            = COALESCE(excluded.pdf_path, ordenes_servicio.pdf_path),
                        sync_status         = 'PENDING',
                        updated_at          = excluded.updated_at
                """, (
                    folio_os,
                    form_data.get("fecha"),
                    form_data.get("equipo_marca", form_data.get("marca", "")),
                    form_data.get("equipo_modelo", form_data.get("modelo", "")),
                    form_data.get("equipo_ns", form_data.get("ns", "")),
                    form_data.get("equipo_ubicacion", form_data.get("ubicacion", "")),
                    form_data.get("observaciones", ""),
                    form_data.get("nombre_cliente_firma", ""),
                    form_data.get("firma_tecnico", ""),
                    form_data.get("firma_cliente", ""),
                    form_data.get("estado", "Cerrada"),
                    "DIGITAL",
                    pdf_path,
                    "PENDING",
                    now, now,
                ))

                # Obtener el id_os local para las tablas de detalle
                row = conn.execute(
                    "SELECT id FROM ordenes_servicio WHERE folio_os = ?", (folio_os,)
                ).fetchone()
                if row:
                    os_id_local = row[0]
                    self._save_local_metrology(conn, os_id_local, form_data)

                conn.commit()

                # Encolar PDF para subir
                if pdf_path:
                    conn.execute(
                        "INSERT OR REPLACE INTO pdf_upload_queue (id_os, folio_os, pdf_path)"
                        " VALUES (?, ?, ?)",
                        (os_id_local if row else 0, folio_os, pdf_path)
                    )
                    conn.commit()

            logger.info("Guardado local OK: %s (PENDING sync)", folio_os)
            return True

        except Exception as exc:
            logger.error("Error guardando localmente %s: %s", folio_os, exc)
            return False

    def _save_local_metrology(
        self, conn: sqlite3.Connection, os_id: int, data: dict
    ) -> None:
        """Inserta/actualiza tablas de detalle metrológico en SQLite."""
        for row in data.get("repetibilidad", []):
            if row.get("lectura_inicial") is not None or row.get("lectura_final") is not None:
                conn.execute("""
                    INSERT INTO det_repetibilidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES (?,?,?,?)
                    ON CONFLICT(id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = excluded.lectura_inicial,
                        lectura_final   = excluded.lectura_final
                """, (os_id, row["posicion_id"], row.get("lectura_inicial"), row.get("lectura_final")))

        for row in data.get("excentricidad", []):
            if row.get("lectura_inicial") is not None or row.get("lectura_final") is not None:
                conn.execute("""
                    INSERT INTO det_excentricidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES (?,?,?,?)
                    ON CONFLICT(id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = excluded.lectura_inicial,
                        lectura_final   = excluded.lectura_final
                """, (os_id, row["posicion_id"], row.get("lectura_inicial"), row.get("lectura_final")))

        for row in data.get("exactitud", []):
            if any(row.get(k) is not None for k in ("valor_nominal", "lectura_inicial", "lectura_final")):
                conn.execute("""
                    INSERT INTO det_exactitud (id_os, punto_id, valor_nominal, lectura_inicial, lectura_final)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(id_os, punto_id) DO UPDATE SET
                        valor_nominal   = excluded.valor_nominal,
                        lectura_inicial = excluded.lectura_inicial,
                        lectura_final   = excluded.lectura_final
                """, (os_id, row["punto_id"], row.get("valor_nominal"),
                      row.get("lectura_inicial"), row.get("lectura_final")))

    # ── Subida de pendientes (Modo Retorno) ──────────────────────────────────

    def upload_pending(
        self,
        progress_callback=None,
    ) -> int:
        """
        Sube todos los registros con sync_status='PENDING' a PostgreSQL.

        Args:
            progress_callback: Función callable(current, total, folio) para
                               reportar progreso (usado por la UI).

        Returns:
            Número de registros sincronizados exitosamente.
        """
        if not self.is_online():
            logger.warning("upload_pending: sin conexión, abortando.")
            return 0

        pending = self._get_pending_local()
        if not pending:
            logger.info("upload_pending: no hay registros pendientes.")
            return 0

        total = len(pending)
        synced = 0
        errors = 0

        try:
            from database.connection import db_pool
            pg_conn = db_pool.get_connection()

            try:
                for idx, local_row in enumerate(pending):
                    folio = local_row["folio_os"]
                    if progress_callback:
                        progress_callback(idx + 1, total, folio)

                    try:
                        self._push_one_to_pg(pg_conn, local_row)
                        synced += 1
                        # Marcar como SYNCED en local
                        with self._get_local_conn() as lc:
                            lc.execute(
                                "UPDATE ordenes_servicio SET sync_status='SYNCED' WHERE folio_os=?",
                                (folio,)
                            )
                            lc.commit()
                    except Exception as row_exc:
                        errors += 1
                        logger.error("Error subiendo %s: %s", folio, row_exc)

                pg_conn.commit()

                # Subir PDFs encolados
                self._upload_pdf_queue(pg_conn)

            finally:
                db_pool.release_connection(pg_conn)

        except Exception as exc:
            logger.error("Error crítico en upload_pending: %s", exc)

        logger.info(
            "upload_pending: %d/%d sincronizados, %d errores.",
            synced, total, errors
        )
        return synced

    def _get_pending_local(self) -> list[dict]:
        """Retorna lista de OS con sync_status='PENDING' desde SQLite."""
        with self._get_local_conn() as conn:
            cur = conn.execute(
                "SELECT * FROM ordenes_servicio WHERE sync_status='PENDING' ORDER BY updated_at"
            )
            return [dict(r) for r in cur.fetchall()]

    def _push_one_to_pg(self, pg_conn, local_row: dict) -> None:
        """
        Actualiza una OS en PostgreSQL con los datos capturados en la tablet.
        Solo actualiza los campos que el técnico pudo modificar en campo;
        no sobreescribe datos administrativos (cliente, folio, fecha, técnico).
        """
        with pg_conn.cursor() as cur:
            # Verificar que el folio exista en PG
            cur.execute(
                "SELECT id FROM ordenes_servicio WHERE folio_os = %s",
                (local_row["folio_os"],)
            )
            pg_row = cur.fetchone()

            if pg_row:
                # Actualizar registro existente
                cur.execute("""
                    UPDATE ordenes_servicio SET
                        marca                = COALESCE(%s, marca),
                        modelo               = COALESCE(%s, modelo),
                        ns                   = COALESCE(%s, ns),
                        ubicacion            = COALESCE(%s, ubicacion),
                        observaciones        = COALESCE(%s, observaciones),
                        firma_cliente_nombre = COALESCE(%s, firma_cliente_nombre),
                        firma_tecnico_b64    = %s,
                        firma_cliente_b64    = %s,
                        estado               = COALESCE(%s, estado),
                        pdf_path             = COALESCE(%s, pdf_path),
                        sync_status          = 'SYNCED',
                        updated_at           = NOW()
                    WHERE folio_os = %s
                """, (
                    local_row.get("marca") or None,
                    local_row.get("modelo") or None,
                    local_row.get("ns") or None,
                    local_row.get("ubicacion") or None,
                    local_row.get("observaciones") or None,
                    local_row.get("firma_cliente_nombre") or None,
                    local_row.get("firma_tecnico_b64") or None,
                    local_row.get("firma_cliente_b64") or None,
                    local_row.get("estado") or None,
                    local_row.get("pdf_path") or None,
                    local_row["folio_os"],
                ))
                pg_conn.commit()

                # Subir detalle metrológico
                os_id = pg_row[0]
                self._push_metrology_to_pg(pg_conn, os_id, local_row["id"])
            else:
                logger.warning(
                    "Folio %s no encontrado en PostgreSQL; se omite el push.",
                    local_row["folio_os"]
                )

    def _push_metrology_to_pg(
        self, pg_conn, pg_os_id: int, local_os_id: int
    ) -> None:
        """Sube tablas de pruebas metrológicas de SQLite a PostgreSQL."""
        with self._get_local_conn() as lc:
            reps = lc.execute(
                "SELECT posicion_id, lectura_inicial, lectura_final FROM det_repetibilidad WHERE id_os=?",
                (local_os_id,)
            ).fetchall()
            excs = lc.execute(
                "SELECT posicion_id, lectura_inicial, lectura_final FROM det_excentricidad WHERE id_os=?",
                (local_os_id,)
            ).fetchall()
            exas = lc.execute(
                "SELECT punto_id, valor_nominal, lectura_inicial, lectura_final FROM det_exactitud WHERE id_os=?",
                (local_os_id,)
            ).fetchall()

        with pg_conn.cursor() as cur:
            for r in reps:
                cur.execute("""
                    INSERT INTO det_repetibilidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES (%s,%s,%s,%s)
                    ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                """, (pg_os_id, r[0], r[1], r[2]))

            for r in excs:
                cur.execute("""
                    INSERT INTO det_excentricidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES (%s,%s,%s,%s)
                    ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                """, (pg_os_id, r[0], r[1], r[2]))

            for r in exas:
                cur.execute("""
                    INSERT INTO det_exactitud (id_os, punto_id, valor_nominal, lectura_inicial, lectura_final)
                    VALUES (%s,%s,%s,%s,%s)
                    ON CONFLICT (id_os, punto_id) DO UPDATE SET
                        valor_nominal   = EXCLUDED.valor_nominal,
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                """, (pg_os_id, r[0], r[1], r[2], r[3]))

        pg_conn.commit()

    def _upload_pdf_queue(self, pg_conn) -> None:
        """Sube PDFs físicos locales al servidor central (copia de archivo)."""
        try:
            from config import SERVER_FILES_BASE, PDF_DIR
            server_pdf_dir = Path(SERVER_FILES_BASE) / PDF_DIR
        except Exception:
            logger.debug("Ruta servidor no configurada, omitiendo copia de PDFs.")
            return

        with self._get_local_conn() as lc:
            queue = lc.execute(
                "SELECT id, id_os, folio_os, pdf_path FROM pdf_upload_queue ORDER BY queued_at"
            ).fetchall()

        for item in queue:
            qid, os_id, folio, local_path = item[0], item[1], item[2], item[3]
            try:
                src = Path(local_path)
                if not src.exists():
                    continue
                dst = server_pdf_dir / src.name
                server_pdf_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)

                # Registrar ruta en PostgreSQL
                with pg_conn.cursor() as cur:
                    cur.execute(
                        "UPDATE ordenes_servicio SET pdf_path=%s WHERE folio_os=%s",
                        (str(dst), folio)
                    )
                pg_conn.commit()

                # Limpiar de la cola local
                with self._get_local_conn() as lc:
                    lc.execute("DELETE FROM pdf_upload_queue WHERE id=?", (qid,))
                    lc.commit()

                logger.info("PDF copiado al servidor: %s → %s", src.name, dst)
            except Exception as exc:
                logger.warning("No se pudo subir PDF %s: %s", local_path, exc)

    # ── Consultas locales (para el dashboard offline) ─────────────────────────

    def get_local_orders(
        self,
        fecha_desde: Optional[str] = None,
        fecha_hasta: Optional[str] = None,
        id_tecnico: Optional[int] = None,
        estado: Optional[str] = None,
        sync_status: Optional[str] = None,
        search: Optional[str] = None,
    ) -> list[dict]:
        """
        Retorna OS desde SQLite para mostrar en el dashboard cuando está offline.

        Returns:
            Lista de dicts con los mismos campos que la query de PostgreSQL
            del dashboard, para compatibilidad directa.
        """
        conditions = ["1=1"]
        params: list[Any] = []

        if fecha_desde and fecha_hasta:
            conditions.append("fecha BETWEEN ? AND ?")
            params.extend([fecha_desde, fecha_hasta])
        if id_tecnico:
            conditions.append("id_tecnico = ?")
            params.append(id_tecnico)
        if estado:
            conditions.append("estado = ?")
            params.append(estado)
        if sync_status:
            conditions.append("sync_status = ?")
            params.append(sync_status)
        if search:
            like = f"%{search}%"
            conditions.append(
                "(folio_os LIKE ? OR cliente_nombre LIKE ? OR tecnico_nombre LIKE ?)"
            )
            params.extend([like, like, like])

        where = " AND ".join(conditions)
        with self._get_local_conn() as conn:
            cur = conn.execute(f"""
                SELECT
                    folio_os, fecha, cliente_nombre, sucursal_nombre,
                    tecnico_nombre, tipo_servicio_nombre, modalidad, estado, id,
                    NULL AS id_lote,
                    CASE WHEN pdf_path IS NOT NULL AND pdf_path != '' THEN 1 ELSE 0 END AS tiene_adjunto,
                    sync_status
                FROM ordenes_servicio
                WHERE {where}
                ORDER BY fecha DESC, created_at DESC
                LIMIT 200
            """, params)
            return [dict(r) for r in cur.fetchall()]

    def get_pending_count(self) -> int:
        """Retorna el número de OS pendientes de sincronizar."""
        with self._get_local_conn() as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM ordenes_servicio WHERE sync_status='PENDING'"
            ).fetchone()
            return row[0] if row else 0

    def get_local_order(self, folio_os: str) -> Optional[dict]:
        """Retorna una OS completa desde SQLite por folio."""
        with self._get_local_conn() as conn:
            row = conn.execute(
                "SELECT * FROM ordenes_servicio WHERE folio_os=?", (folio_os,)
            ).fetchone()
            return dict(row) if row else None

    def get_local_catalogs(self) -> dict:
        """Retorna todos los catálogos descargados desde SQLite."""
        with self._get_local_conn() as conn:
            return {
                "clientes": [dict(r) for r in conn.execute("SELECT * FROM cat_clientes").fetchall()],
                "tecnicos": [dict(r) for r in conn.execute("SELECT * FROM cat_tecnicos WHERE activo=1").fetchall()],
                "tipos_servicio": [dict(r) for r in conn.execute("SELECT * FROM cat_tipo_servicio").fetchall()],
            }

    def get_local_kpis(
        self,
        fecha_desde: Optional[str] = None,
        fecha_hasta: Optional[str] = None,
    ) -> dict:
        """
        Calcula los KPIs del dashboard desde SQLite local.
        Usado en modo offline.
        """
        conditions = ["1=1"]
        params: list[Any] = []
        if fecha_desde and fecha_hasta:
            conditions.append("fecha BETWEEN ? AND ?")
            params.extend([fecha_desde, fecha_hasta])
        where = " AND ".join(conditions)

        with self._get_local_conn() as conn:
            row = conn.execute(f"""
                SELECT
                    COUNT(*) AS total,
                    SUM(CASE WHEN estado='PROCESO' THEN 1 ELSE 0 END) AS proceso,
                    SUM(CASE WHEN estado IN ('ESCANEADA','COMPLETADA','COMPLETADA_DIGITAL') THEN 1 ELSE 0 END) AS terminadas,
                    SUM(CASE WHEN modalidad='FISICO' AND estado='PROCESO' THEN 1 ELSE 0 END) AS fisicos_pend,
                    SUM(CASE WHEN sync_status='PENDING' THEN 1 ELSE 0 END) AS sync_pending
                FROM ordenes_servicio
                WHERE {where}
            """, params).fetchone()
        return {
            "total":        row[0] or 0,
            "proceso":      row[1] or 0,
            "terminadas":   row[2] or 0,
            "fisicos_pend": row[3] or 0,
            "sync_pending": row[4] or 0,
        }


# ── Instancia global singleton ────────────────────────────────────────────────
sync_manager = SyncManager()
