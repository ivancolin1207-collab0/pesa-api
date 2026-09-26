"""
run_migration_v13.py — Ejecuta la migración v13 (Sucursales y Catálogo de Equipos).

Uso:
    python run_migration_v13.py

PARTE 1 (usuario pesa_app):
  - Crea tabla cliente_sucursales
  - Crea tabla cliente_equipos
  - Crea función fn_upsert_equipo_desde_os()

PARTE 2 (superusuario postgres):
  - Agrega columnas sucursal_id y equipo_catalogo_id a ordenes_servicio
  - Usa PESA_SU_USER / PESA_SU_PASSWORD del entorno (default: postgres / "")
  - Si falla, imprime el SQL para que lo ejecutes manualmente como DBA
"""
import os
import sys
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
)
logger = logging.getLogger(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

# ── SQL Parte 1: tablas + función (pesa_app tiene permisos) ──────────────────
SQL_PARTE1 = """
BEGIN;

-- Tabla de Sucursales / Plantas por Cliente
CREATE TABLE IF NOT EXISTS cliente_sucursales (
    id                SERIAL          PRIMARY KEY,
    cliente_id        INT             NOT NULL
                          REFERENCES cat_clientes(id) ON DELETE CASCADE,
    nombre_sucursal   VARCHAR(150)    NOT NULL,
    direccion         TEXT            NOT NULL,
    contacto_nombre   VARCHAR(150),
    contacto_telefono VARCHAR(50),
    activo            BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_sucursal_nombre_cliente UNIQUE (cliente_id, nombre_sucursal)
);

CREATE INDEX IF NOT EXISTS idx_sucursales_cliente_id
    ON cliente_sucursales (cliente_id);

-- Tabla de Equipos / Básculas por Sucursal
CREATE TABLE IF NOT EXISTS cliente_equipos (
    id                   SERIAL          PRIMARY KEY,
    sucursal_id          INT             NOT NULL
                             REFERENCES cliente_sucursales(id) ON DELETE CASCADE,
    marca                VARCHAR(100),
    modelo               VARCHAR(100),
    numero_serie         VARCHAR(100)    NOT NULL,
    id_indicador_equipo  VARCHAR(100),
    ubicacion_interna    VARCHAR(150),
    capacidad_maxima     VARCHAR(50),
    division_minima      VARCHAR(50),
    tipo_instrumento     VARCHAR(100),
    activo               BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT unique_serie_sucursal UNIQUE (sucursal_id, numero_serie)
);

CREATE INDEX IF NOT EXISTS idx_equipos_sucursal_id
    ON cliente_equipos (sucursal_id);

-- Función de upsert
CREATE OR REPLACE FUNCTION fn_upsert_equipo_desde_os(
    p_sucursal_id        INT,
    p_numero_serie       VARCHAR,
    p_marca              VARCHAR DEFAULT NULL,
    p_modelo             VARCHAR DEFAULT NULL,
    p_id_indicador       VARCHAR DEFAULT NULL,
    p_ubicacion          VARCHAR DEFAULT NULL,
    p_capacidad          VARCHAR DEFAULT NULL,
    p_division           VARCHAR DEFAULT NULL,
    p_tipo_instrumento   VARCHAR DEFAULT NULL
)
RETURNS INT AS $$
DECLARE
    v_id INT;
BEGIN
    INSERT INTO cliente_equipos (
        sucursal_id, numero_serie, marca, modelo,
        id_indicador_equipo, ubicacion_interna,
        capacidad_maxima, division_minima, tipo_instrumento
    )
    VALUES (
        p_sucursal_id, p_numero_serie, p_marca, p_modelo,
        p_id_indicador, p_ubicacion,
        p_capacidad, p_division, p_tipo_instrumento
    )
    ON CONFLICT (sucursal_id, numero_serie) DO UPDATE SET
        marca               = COALESCE(EXCLUDED.marca,             cliente_equipos.marca),
        modelo              = COALESCE(EXCLUDED.modelo,            cliente_equipos.modelo),
        id_indicador_equipo = COALESCE(EXCLUDED.id_indicador_equipo, cliente_equipos.id_indicador_equipo),
        ubicacion_interna   = COALESCE(EXCLUDED.ubicacion_interna,  cliente_equipos.ubicacion_interna),
        capacidad_maxima    = COALESCE(EXCLUDED.capacidad_maxima,   cliente_equipos.capacidad_maxima),
        division_minima     = COALESCE(EXCLUDED.division_minima,    cliente_equipos.division_minima),
        tipo_instrumento    = COALESCE(EXCLUDED.tipo_instrumento,   cliente_equipos.tipo_instrumento),
        updated_at          = NOW()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

COMMIT;
"""

# ── SQL Parte 2: ALTER TABLE ordenes_servicio (requiere owner/superusuario) ──
SQL_PARTE2 = """
BEGIN;
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS sucursal_id        INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT
        REFERENCES cliente_equipos(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_os_sucursal_id
    ON ordenes_servicio (sucursal_id) WHERE sucursal_id IS NOT NULL;
COMMIT;
"""

SQL_PARTE2_MANUAL = """
-- Ejecuta este SQL como superusuario (postgres):
--   psql -U postgres -d servicios_pesa
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sucursal_id        INT REFERENCES cliente_sucursales(id) ON DELETE SET NULL;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT REFERENCES cliente_equipos(id)    ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_os_sucursal_id ON ordenes_servicio (sucursal_id) WHERE sucursal_id IS NOT NULL;
"""


def _run_sql(conn, sql: str, descripcion: str) -> bool:
    import psycopg2
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        logger.info("  %s: OK", descripcion)
        return True
    except psycopg2.Error as exc:
        conn.rollback()
        logger.error("  %s: FALLO — %s", descripcion, exc)
        return False


def run():
    logger.info("=" * 64)
    logger.info("  MIGRACIÓN v13 — Sucursales & Catálogo de Equipos por Planta")
    logger.info("=" * 64)

    try:
        import psycopg2
        from config import DB_CONFIG
        from database.connection import db_pool
        db_pool.initialize(DB_CONFIG)
        logger.info("Pool de conexiones inicializado.")
    except Exception as exc:
        logger.error("Error al inicializar la conexión: %s", exc)
        sys.exit(2)

    # ── PARTE 1: Tablas + Función ──────────────────────────────────────────────
    logger.info("")
    logger.info("PARTE 1: Creando tablas y función SQL (usuario pesa_app)...")
    ok1 = False
    try:
        cfg1 = {k: v for k, v in DB_CONFIG.items() if k not in ("application_name", "options")}
        conn1 = psycopg2.connect(**cfg1)
        conn1.autocommit = False
        ok1 = _run_sql(conn1, SQL_PARTE1, "Tablas + Función")
        conn1.close()
    except Exception as exc:
        logger.error("Error de conexión PARTE 1: %s", exc)

    # ── PARTE 2: ALTER TABLE ordenes_servicio (superusuario) ──────────────────
    logger.info("")
    logger.info("PARTE 2: Agregando columnas a ordenes_servicio (superusuario)...")
    su_user = os.getenv("PESA_SU_USER", "postgres")
    su_pass = os.getenv("PESA_SU_PASSWORD", "")
    su_config = {**DB_CONFIG, "user": su_user, "password": su_pass}
    su_config.pop("application_name", None)
    su_config.pop("options", None)

    ok2 = False
    try:
        conn2 = psycopg2.connect(**su_config)
        conn2.autocommit = False
        ok2 = _run_sql(conn2, SQL_PARTE2, "ALTER TABLE ordenes_servicio")
        conn2.close()
    except Exception as exc:
        logger.warning("No se pudo conectar como superusuario (%s).", exc)
        logger.warning("Ejecuta manualmente el siguiente SQL como postgres:")
        logger.warning("")
        for line in SQL_PARTE2_MANUAL.strip().splitlines():
            logger.warning("  %s", line)
        logger.warning("")

    # ── Verificación ────────────────────────────────────────────────────────────
    logger.info("")
    logger.info("-" * 50)
    logger.info("Verificando objetos creados...")
    checks = [
        ("TABLA",   "SELECT 1 FROM information_schema.tables "
                    "WHERE table_name = 'cliente_sucursales' AND table_schema = 'public'",
                    "cliente_sucursales"),
        ("TABLA",   "SELECT 1 FROM information_schema.tables "
                    "WHERE table_name = 'cliente_equipos' AND table_schema = 'public'",
                    "cliente_equipos"),
        ("COLUMNA", "SELECT 1 FROM information_schema.columns "
                    "WHERE table_name = 'ordenes_servicio' AND column_name = 'sucursal_id'",
                    "ordenes_servicio.sucursal_id"),
        ("COLUMNA", "SELECT 1 FROM information_schema.columns "
                    "WHERE table_name = 'ordenes_servicio' AND column_name = 'equipo_catalogo_id'",
                    "ordenes_servicio.equipo_catalogo_id"),
        ("FUNCION", "SELECT 1 FROM pg_proc WHERE proname = 'fn_upsert_equipo_desde_os'",
                    "fn_upsert_equipo_desde_os()"),
    ]
    try:
        for tipo, sql, nombre in checks:
            row = db_pool.execute_one(sql)
            status = "OK" if row else "NO ENCONTRADO"
            logger.info("  %-8s  %-42s  ->  %s", tipo, nombre, status)
    except Exception as exc:
        logger.warning("No se pudo verificar: %s", exc)

    logger.info("=" * 64)
    logger.info("  Migración v13 (Parte 1): %s", "OK" if ok1 else "FALLO")
    logger.info("  Migración v13 (Parte 2): %s", "OK" if ok2 else "pendiente (ejecutar manual)")
    logger.info("  Reinicia la aplicación para usar los nuevos catálogos.")
    logger.info("=" * 64)


if __name__ == "__main__":
    run()
