"""
run_migration_v15.py — Agrega sucursal_id a revisiones_bascula y remisiones.

PARTE 1 (pesa_app): nada (sólo ALTER TABLE que requiere dueño)
PARTE 2 (superusuario postgres): ALTER TABLE revisiones_bascula + remisiones
"""
import os
import sys
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)-8s  %(message)s")
logger = logging.getLogger(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

SQL_PARTE2 = """
BEGIN;

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS sucursal_id        INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT
        REFERENCES cliente_equipos(id) ON DELETE SET NULL;

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS marca               VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS modelo              VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS numero_serie        VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS id_indicador_equipo VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS ubicacion_interna   VARCHAR(150);

CREATE INDEX IF NOT EXISTS idx_re_sucursal_id
    ON revisiones_bascula (sucursal_id) WHERE sucursal_id IS NOT NULL;

ALTER TABLE remisiones
    ADD COLUMN IF NOT EXISTS sucursal_id INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_rma_sucursal_id
    ON remisiones (sucursal_id) WHERE sucursal_id IS NOT NULL;

COMMIT;
"""

SQL_MANUAL = """
-- Ejecuta como superusuario (postgres):
--   psql -U postgres -d servicios_pesa
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS sucursal_id        INT REFERENCES cliente_sucursales(id) ON DELETE SET NULL;
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT REFERENCES cliente_equipos(id)    ON DELETE SET NULL;
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS marca               VARCHAR(100);
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS modelo              VARCHAR(100);
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS numero_serie        VARCHAR(100);
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS id_indicador_equipo VARCHAR(100);
ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS ubicacion_interna   VARCHAR(150);
CREATE INDEX IF NOT EXISTS idx_re_sucursal_id  ON revisiones_bascula (sucursal_id) WHERE sucursal_id IS NOT NULL;
ALTER TABLE remisiones ADD COLUMN IF NOT EXISTS sucursal_id INT REFERENCES cliente_sucursales(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_rma_sucursal_id ON remisiones (sucursal_id) WHERE sucursal_id IS NOT NULL;
"""


def _run_sql(conn, sql: str, desc: str) -> bool:
    import psycopg2
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        logger.info("  %s: OK", desc)
        return True
    except psycopg2.Error as exc:
        conn.rollback()
        logger.error("  %s: FALLO — %s", desc, exc)
        return False


def run():
    logger.info("=" * 64)
    logger.info("  MIGRACIÓN v15 — sucursal_id en RE y RMA")
    logger.info("=" * 64)

    try:
        import psycopg2
        from config import DB_CONFIG
        from database.connection import db_pool
        db_pool.initialize(DB_CONFIG)
    except Exception as exc:
        logger.error("Error al inicializar conexión: %s", exc)
        sys.exit(2)

    su_user = os.getenv("PESA_SU_USER", "postgres")
    su_pass = os.getenv("PESA_SU_PASSWORD", "")

    try:
        from config import DB_CONFIG as _dbc
        su_config = {k: v for k, v in _dbc.items() if k not in ("application_name", "options")}
        su_config["user"]     = su_user
        su_config["password"] = su_pass
        conn2 = psycopg2.connect(**su_config)
        conn2.autocommit = False
        ok2 = _run_sql(conn2, SQL_PARTE2, "ALTER TABLE revisiones_bascula + remisiones")
        conn2.close()
    except Exception as exc:
        logger.warning("No se pudo conectar como superusuario (%s).", exc)
        logger.warning("Ejecuta manualmente:")
        for line in SQL_MANUAL.strip().splitlines():
            logger.warning("  %s", line)
        ok2 = False

    # Verificación
    from database.connection import db_pool as _pool
    checks = [
        ("revisiones_bascula.sucursal_id",
         "SELECT 1 FROM information_schema.columns WHERE table_name='revisiones_bascula' AND column_name='sucursal_id'"),
        ("remisiones.sucursal_id",
         "SELECT 1 FROM information_schema.columns WHERE table_name='remisiones' AND column_name='sucursal_id'"),
    ]
    logger.info("")
    logger.info("Verificación:")
    for nombre, sql in checks:
        try:
            row = _pool.execute_one(sql)
            logger.info("  %-40s -> %s", nombre, "OK" if row else "NO ENCONTRADA")
        except Exception as exc:
            logger.warning("  %-40s -> ERROR: %s", nombre, exc)

    logger.info("=" * 64)
    logger.info("  Migración v15: %s", "OK" if ok2 else "pendiente (ejecutar manual)")
    logger.info("=" * 64)


if __name__ == "__main__":
    run()
