"""
run_migration_v9.py — Ejecuta la migración v9 (Módulo de Recepción).

Uso:
    python run_migration_v9.py

Aplica el archivo migration_v9_recepcion.sql que:
  1. Agrega estado COMPLETADA a ordenes_servicio.
  2. Crea tablas lotes_recepcion y lotes_recepcion_items.
  3. Crea vista v_recepcion_semanal.
  4. Crea función PL/pgSQL marcar_lote_completado().
"""
import os
import sys
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
)
logger = logging.getLogger(__name__)

# Agregar el directorio raíz al path para importar config y db_pool
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

SQL_FILE = os.path.join(BASE_DIR, "database", "migration_v9_recepcion.sql")


def run():
    logger.info("=" * 62)
    logger.info("  MIGRACIÓN v9 — Módulo de Recepción / Entrega Semanal OS")
    logger.info("=" * 62)

    # 1. Verificar que el archivo SQL existe
    if not os.path.isfile(SQL_FILE):
        logger.error("No se encontró el archivo SQL: %s", SQL_FILE)
        sys.exit(1)
    logger.info("Archivo SQL encontrado: %s", SQL_FILE)

    # 2. Cargar la migración
    with open(SQL_FILE, encoding="utf-8") as f:
        sql_content = f.read()
    logger.info("SQL leído (%d caracteres)", len(sql_content))

    # 3. Conectar e inicializar el pool
    try:
        from config import DB_CONFIG
        from database.connection import db_pool
        db_pool.initialize(DB_CONFIG)
        logger.info("Pool de conexiones inicializado correctamente.")
    except Exception as exc:
        logger.error("Error al inicializar la conexión: %s", exc)
        sys.exit(2)

    # 4. Ejecutar la migración
    try:
        import psycopg2
        from psycopg2.extras import RealDictCursor

        with db_pool.transaction() as conn:
            with conn.cursor() as cur:
                logger.info("Ejecutando migración SQL…")
                cur.execute(sql_content)
            logger.info("COMMIT realizado. Migración aplicada correctamente.")

    except Exception as exc:
        logger.error("Error durante la migración (ROLLBACK automático): %s", exc)
        logger.error("Detalle: %s", str(exc))
        sys.exit(3)

    # 5. Verificar tablas creadas
    logger.info("-" * 50)
    logger.info("Verificando objetos creados…")
    try:
        checks = [
            ("TABLA",    "SELECT 1 FROM information_schema.tables "
                         "WHERE table_name = 'lotes_recepcion' AND table_schema = 'public'"),
            ("TABLA",    "SELECT 1 FROM information_schema.tables "
                         "WHERE table_name = 'lotes_recepcion_items' AND table_schema = 'public'"),
            ("VISTA",    "SELECT 1 FROM information_schema.views "
                         "WHERE table_name = 'v_recepcion_semanal' AND table_schema = 'public'"),
            ("FUNCIÓN",  "SELECT 1 FROM pg_proc WHERE proname = 'marcar_lote_completado'"),
        ]
        nombres = [
            "lotes_recepcion",
            "lotes_recepcion_items",
            "v_recepcion_semanal",
            "marcar_lote_completado()",
        ]
        for (tipo, sql), nombre in zip(checks, nombres):
            row = db_pool.execute_one(sql)
            status = "✅ OK" if row else "❌ NO ENCONTRADO"
            logger.info("  %s  %-30s  →  %s", tipo, nombre, status)

        # Verificar estado COMPLETADA en CHECK constraint
        row = db_pool.execute_one("""
            SELECT pg_get_constraintdef(oid) AS def
            FROM pg_constraint
            WHERE conname = 'chk_os_estado' AND conrelid = 'ordenes_servicio'::regclass
        """)
        if row and "COMPLETADA" in row.get("def", ""):
            logger.info("  CHECK  chk_os_estado (COMPLETADA)        →  ✅ OK")
        else:
            logger.warning("  CHECK  chk_os_estado                     →  ⚠  No contiene COMPLETADA")

    except Exception as exc:
        logger.warning("No se pudo verificar: %s", exc)

    logger.info("=" * 62)
    logger.info("  Migración v9 completada exitosamente.")
    logger.info("  Reinicia la aplicación para usar el módulo de Recepción.")
    logger.info("=" * 62)


if __name__ == "__main__":
    run()
