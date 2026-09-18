"""
Módulo de conexión y pool de conexiones a PostgreSQL.
Implementa un pool thread-safe con reconexión automática,
optimizado para el entorno VPN (latencia variable).
"""
import logging
import os
import time
from contextlib import contextmanager
from typing import Any, Generator, Optional

import psycopg2
from psycopg2 import pool as pg_pool, OperationalError, DatabaseError
from psycopg2.extras import RealDictCursor, RealDictRow

logger = logging.getLogger(__name__)


def _safe_pg_error_str(exc: BaseException) -> str:
    """
    Extrae un mensaje legible de cualquier excepción de psycopg2,
    incluyendo UnicodeDecodeError cuando PostgreSQL en Windows devuelve
    mensajes en cp1252/latin-1 (bytes 0x80-0xFF).

    Estrategia:
    1. Si exc es UnicodeDecodeError, los bytes reales del servidor están
       en exc.object → decodificar con cp1252 para obtener el texto original.
    2. Si str(exc) funciona, usarlo directamente.
    3. Fallback a repr().
    """
    if isinstance(exc, UnicodeDecodeError):
        # exc.object contiene los bytes crudos que PostgreSQL envíó.
        # El servidor Windows con locale español los envía en cp1252.
        try:
            return exc.object.decode("cp1252", errors="replace")
        except Exception:
            return repr(exc)
    try:
        return str(exc)
    except UnicodeDecodeError:
        raw = getattr(exc, "args", (b"",))
        b = raw[0] if raw else b""
        return b.decode("cp1252", errors="replace") if isinstance(b, bytes) else repr(exc)


class DatabaseConnectionError(Exception):
    """Excepción personalizada para errores de conexión a BD."""
    pass


class DatabasePool:
    """
    Singleton que gestiona el pool de conexiones PostgreSQL.

    Características:
    - Thread-safe mediante ThreadedConnectionPool
    - Reconexión automática ante pérdida de VPN
    - Context managers para transacciones y queries
    - Logging detallado de operaciones
    """

    _instance: Optional["DatabasePool"] = None
    _pool: Optional[pg_pool.ThreadedConnectionPool] = None
    _config: dict = {}

    def __new__(cls) -> "DatabasePool":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    # ── Inicialización ────────────────────────────────────────────────────────

    def initialize(
        self,
        db_config: Optional[dict] = None,
        min_conn: int = 1,
        max_conn: int = 8,
    ) -> None:
        """
        Inicializa el pool de conexiones.

        Args:
            db_config: Diccionario con parámetros de conexión psycopg2.
                       Si es None, usa la configuración de config.py.
            min_conn: Número mínimo de conexiones en el pool.
            max_conn: Número máximo de conexiones en el pool.
        """
        if db_config is not None:
            self._config = db_config
        else:
            # Importación diferida para evitar ciclos
            from config import DB_CONFIG
            self._config = DB_CONFIG.copy()

        # Cerrar pool existente si hay uno
        if self._pool is not None:
            try:
                self._pool.closeall()
            except Exception:
                pass
            self._pool = None

        def _try_create_pool(cfg: dict) -> None:
            """Intenta crear el pool con la configuración dada."""
            self._pool = pg_pool.ThreadedConnectionPool(
                minconn=min_conn,
                maxconn=max_conn,
                **cfg,
            )

        # ── Intento 1: host configurado (puede ser LAN o localhost) ───────────
        primary_error: Optional[str] = None
        try:
            _try_create_pool(self._config)
            logger.info(
                "Pool de conexiones inicializado: %s:%s/%s (min=%d, max=%d)",
                self._config.get('host'), self._config.get('port'),
                self._config.get('database'), min_conn, max_conn,
            )
            self._ensure_schema()
            return  # éxito con el host primario

        except (OperationalError, UnicodeDecodeError) as exc:
            primary_error = _safe_pg_error_str(exc)
            logger.warning(
                "Conexión a host primario %s:%s falló: %s",
                self._config.get('host'), self._config.get('port'), primary_error,
            )

        # ── Intento 2: fallback automático a 127.0.0.1 ───────────────────────
        # Solo aplica cuando el host primario NO es ya localhost.
        _primary_host = str(self._config.get("host", "")).strip()
        _is_local = _primary_host in ("127.0.0.1", "localhost", "::1", "")

        if not _is_local:
            logger.info("Intentando fallback local a 127.0.0.1…")
            _fallback_cfg = dict(self._config)
            _fallback_cfg["host"] = "127.0.0.1"
            try:
                _try_create_pool(_fallback_cfg)
                logger.info(
                    "Pool inicializado en fallback local: 127.0.0.1:%s/%s",
                    _fallback_cfg.get('port'), _fallback_cfg.get('database'),
                )
                self._ensure_schema()
                return  # éxito con fallback local

            except (OperationalError, UnicodeDecodeError) as fallback_exc:
                fallback_error = _safe_pg_error_str(fallback_exc)
                logger.warning("Fallback local también falló: %s", fallback_error)
                # Reportar ambos errores para diagnóstico
                primary_error = (
                    f"Host {_primary_host}: {primary_error}\n"
                    f"Fallback 127.0.0.1: {fallback_error}"
                )

        # ── Sin conexión disponible ────────────────────────────────────────────
        logger.error("Error al crear pool de conexiones: %s", primary_error)
        raise DatabaseConnectionError(
            f"No se pudo conectar a PostgreSQL en "
            f"{self._config.get('host')}:{self._config.get('port')}.\n"
            f"Detalle: {primary_error}\n\n"
            "Verifique:\n"
            "  \u2022 La VPN/SD-WAN est\u00e9 activa y conectada\n"
            "  \u2022 El servidor PostgreSQL est\u00e9 iniciado\n"
            "  \u2022 Las credenciales en .env o config.py sean correctas"
        )



    def _ensure_schema(self) -> None:
        """
        Verifica y agrega automáticamente las columnas requeridas que
        puedan faltar en la BD (idempotente: ADD COLUMN IF NOT EXISTS).

        Ejecutado automáticamente cada vez que se inicializa el pool.
        Nunca lanza excepción: si algo falla, solo registra un warning.
        """
        _MIGRATIONS = [
            # ── cat_tecnicos ────────────────────────────────────────────────
            "ALTER TABLE cat_tecnicos ADD COLUMN IF NOT EXISTS rol VARCHAR(50) NOT NULL DEFAULT 'Técnico';",
            "ALTER TABLE cat_tecnicos ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255);",
            "ALTER TABLE cat_tecnicos ADD COLUMN IF NOT EXISTS password VARCHAR(255);",
            # ── columna roles (JSON) para soporte multi-rol ──────────────────
            "ALTER TABLE cat_tecnicos ADD COLUMN IF NOT EXISTS roles TEXT;",
            # Backfill: para filas que ya existen sin roles, inicializar con el rol actual
            """
            UPDATE cat_tecnicos
               SET roles = '["' || rol || '"]'
             WHERE roles IS NULL OR roles = '' OR roles = '[]';
            """,
            # ── usuarios (puede o no existir en instalaciones antiguas) ─────
            """
            DO $$ BEGIN
                IF EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = 'public' AND table_name = 'usuarios'
                ) THEN
                    ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS rol VARCHAR(50) DEFAULT 'Técnico';
                    ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255);
                    ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS password VARCHAR(255);
                END IF;
            END; $$
            """,
            # ── ordenes_servicio — columnas requeridas por la lógica de folios ──
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS consecutivo      INT DEFAULT 1;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_documento   VARCHAR(10) DEFAULT 'OS';",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS modalidad        VARCHAR(20) DEFAULT 'FISICO';",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cliente          TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS created_at       TIMESTAMPTZ DEFAULT NOW();",
            # Backfill consecutivo desde el texto del folio_os (OS-26-43 → 43)
            """
            UPDATE ordenes_servicio
            SET    consecutivo = CAST(SPLIT_PART(folio_os, '-', 3) AS INT)
            WHERE  folio_os LIKE '%-%-%'
              AND  (consecutivo IS NULL OR consecutivo = 0 OR consecutivo = 1)
              AND  SPLIT_PART(folio_os, '-', 3) ~ '^[0-9]+$';
            """,
            # Hacer nullable id_tipo_servicio para folios digitales pre-asignados
            "ALTER TABLE ordenes_servicio ALTER COLUMN id_tipo_servicio DROP NOT NULL;",
            # Eliminar chk_os_estado para permitir estados digitales sin bloqueo
            "ALTER TABLE ordenes_servicio DROP CONSTRAINT IF EXISTS chk_os_estado;",
            # Timestamps de auditoría
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();",
            # Lógica dinámica Excentricidad
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS aplica_excentricidad BOOLEAN DEFAULT TRUE;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS filas_excentricidad INTEGER DEFAULT 5;",
            # Campos de Tipo de Estructura (RE)
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_estructura TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_instalacion_camionera TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS secciones_camionera INTEGER;",
            # Campos de Indicador e Instrumento (RE)
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS indicador_marca TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS indicador_modelo TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS indicador_serie TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS indicador_id TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cap_maxima TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS div_minima TEXT;",
            # Campos de Celdas de Carga (RE)
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celdas_mixtas BOOLEAN DEFAULT FALSE;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_a_marca TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_a_modelo TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_a_capacidad TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_a_cantidad INTEGER;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_b_marca TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_b_modelo TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_b_capacidad TEXT;",
            "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS celda_b_cantidad INTEGER;",
        ]

        conn = None
        try:
            conn = self._pool.getconn()  # type: ignore[union-attr]
            conn.autocommit = True
            with conn.cursor() as cur:
                for stmt in _MIGRATIONS:
                    try:
                        cur.execute(stmt)
                    except Exception as col_exc:
                        logger.warning("_ensure_schema: sentencia ignorada (%s): %s",
                                       stmt.strip()[:60], col_exc)
            logger.info("_ensure_schema: esquema verificado correctamente.")
        except Exception as exc:
            logger.warning("_ensure_schema: no se pudo verificar el esquema: %s", exc)
        finally:
            if conn:
                try:
                    conn.autocommit = False
                    self._pool.putconn(conn)  # type: ignore[union-attr]
                except Exception:
                    pass


    def _reinitialize(self) -> None:
        """Reinicializa el pool (invocado en reconexión automática)."""
        logger.warning("Intentando reinicializar pool de conexiones...")
        self.initialize()

    # ── Obtención y liberación de conexiones ──────────────────────────────────

    def get_connection(
        self,
        retries: int = 3,
        retry_delay: float = 2.0,
    ) -> Any:
        """
        Obtiene una conexión del pool con reintentos automáticos.

        Args:
            retries: Número de intentos antes de lanzar excepción.
            retry_delay: Segundos entre intentos.

        Returns:
            Conexión psycopg2.

        Raises:
            DatabaseConnectionError: Si no se puede obtener conexión.
        """
        for attempt in range(1, retries + 1):
            try:
                if self._pool is None:
                    self.initialize()
                conn = self._pool.getconn()  # type: ignore[union-attr]
                conn.autocommit = False
                # Forzar UTF-8 en cada conexión para evitar acentos rotos
                # al leer desde Render PostgreSQL (que almacena en UTF-8)
                try:
                    conn.set_client_encoding('UTF8')
                except Exception:
                    pass
                return conn

            except (OperationalError, pg_pool.PoolError, UnicodeDecodeError) as exc:
                # _safe_pg_error_str() extrae el texto real del servidor PostgreSQL
                # incluso si está codificado en cp1252 (Windows español).
                exc_str = _safe_pg_error_str(exc)
                logger.warning("Intento %d/%d fallido: %s", attempt, retries, exc_str)
                if attempt < retries:
                    time.sleep(retry_delay)
                    try:
                        self._reinitialize()
                    except DatabaseConnectionError:
                        pass
                else:
                    raise DatabaseConnectionError(
                        f"No se pudo obtener conexión después de {retries} intentos.\n"
                        f"Detalle: {exc_str}\n"
                        "La VPN puede estar caída. Intente reconectarse e inténtelo de nuevo."
                    ) from exc

    def release_connection(self, conn: Any) -> None:
        """Devuelve una conexión al pool."""
        if self._pool is not None and conn is not None:
            try:
                self._pool.putconn(conn)
            except Exception as exc:
                logger.error(f"Error al liberar conexión: {exc}")

    # ── Context Managers ──────────────────────────────────────────────────────

    @contextmanager
    def transaction(self) -> Generator[Any, None, None]:
        """
        Context manager para transacciones atómicas.

        Uso:
            with db_pool.transaction() as conn:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    cur.execute("INSERT INTO ...")
                    cur.execute("SELECT generate_folio(...)")

        El commit se hace automáticamente al salir del bloque.
        El rollback se hace automáticamente si hay una excepción.
        """
        conn = self.get_connection()
        try:
            yield conn
            conn.commit()
            logger.debug("Transacción confirmada (commit)")
        except (DatabaseError, Exception) as exc:
            try:
                conn.rollback()
                logger.warning(f"Transacción revertida (rollback): {exc}")
            except Exception:
                pass
            raise
        finally:
            self.release_connection(conn)

    @contextmanager
    def query(
        self, dict_cursor: bool = True
    ) -> Generator[Any, None, None]:
        """
        Context manager para queries de solo lectura (sin commit explícito).

        Uso:
            with db_pool.query() as cur:
                cur.execute("SELECT * FROM v_ordenes_servicio WHERE estado = %s", ('PROCESO',))
                rows = cur.fetchall()

        Args:
            dict_cursor: Si True, retorna filas como diccionarios.
        """
        conn = self.get_connection()
        cursor_factory = RealDictCursor if dict_cursor else None
        try:
            with conn.cursor(cursor_factory=cursor_factory) as cur:
                yield cur
            conn.commit()
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            raise
        finally:
            self.release_connection(conn)

    # ── Utilidades ────────────────────────────────────────────────────────────

    def test_connection(self) -> bool:
        """
        Prueba la conexión a la BD de forma no invasiva.

        Returns:
            True si la conexión es exitosa, False en caso contrario.
        """
        try:
            conn = self.get_connection(retries=1, retry_delay=0.5)
            with conn.cursor() as cur:
                cur.execute("SELECT 1 AS ping")
                cur.fetchone()
            self.release_connection(conn)
            return True
        except Exception as exc:
            logger.debug(f"test_connection falló: {exc}")
            return False

    def execute_one(
        self,
        sql: str,
        params: tuple = (),
        dict_cursor: bool = True,
    ) -> Optional[RealDictRow]:
        """Ejecuta un query y retorna un solo resultado."""
        with self.query(dict_cursor=dict_cursor) as cur:
            cur.execute(sql, params)
            return cur.fetchone()

    def execute_all(
        self,
        sql: str,
        params: tuple = (),
        dict_cursor: bool = True,
    ) -> list:
        """Ejecuta un query y retorna todos los resultados."""
        with self.query(dict_cursor=dict_cursor) as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    def execute_write(
        self,
        sql: str,
        params: tuple = (),
        returning: bool = False,
    ) -> Optional[Any]:
        """
        Ejecuta un INSERT/UPDATE/DELETE dentro de una transacción.

        Args:
            sql:       Query SQL parametrizado.
            params:    Parámetros del query.
            returning: Si True, retorna el primer resultado (para RETURNING).

        Returns:
            Primera fila si returning=True, None en caso contrario.
        """
        with self.transaction() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(sql, params)
                if returning:
                    return cur.fetchone()
                return None

    def get_server_version(self) -> str:
        """Retorna la versión del servidor PostgreSQL."""
        row = self.execute_one("SELECT version() AS ver")
        return row["ver"] if row else "Desconocida"

    def close_all(self) -> None:
        """Cierra todas las conexiones del pool. Llamar al cerrar la app."""
        if self._pool is not None:
            try:
                self._pool.closeall()
                logger.info("Pool de conexiones cerrado correctamente.")
            except Exception as exc:
                logger.error(f"Error al cerrar pool: {exc}")
            finally:
                self._pool = None


# ─── Instancia global del pool ─────────────────────────────────────────────────
# Importar y usar en toda la aplicación:
#   from database.connection import db_pool
db_pool = DatabasePool()
