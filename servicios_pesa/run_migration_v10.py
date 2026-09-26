import sys
import logging
from database.connection import DatabasePool

# Configuración básica de logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

def run_migration():
    pool = DatabasePool()
    pool.initialize()

    migration_file = "database/migration_v10_cliente_instrumentos.sql"
    
    try:
        with open(migration_file, "r", encoding="utf-8") as f:
            sql_script = f.read()
    except Exception as e:
        logger.error(f"Error al leer el archivo de migración: {e}")
        sys.exit(1)

    logger.info("Ejecutando migración V10: cliente_instrumentos...")
    
    try:
        with pool.transaction() as conn:
            with conn.cursor() as cur:
                cur.execute(sql_script)
            logger.info("¡Migración V10 ejecutada correctamente!")
    except Exception as e:
        logger.error(f"Error al ejecutar la migración V10: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_migration()
