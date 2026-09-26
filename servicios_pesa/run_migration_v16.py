"""
run_migration_v16.py — Ejecuta la migración v16: Levantamiento Metrológico (LV).

Cambios aplicados:
  1. Amplía constraint control_folios para aceptar 'LV'
  2. Actualiza generate_folio() con TRIM para tipos de 2 chars
  3. Crea tabla det_levantamiento_metrologico

Uso:
    python run_migration_v16.py
"""
import sys
from pathlib import Path

# Asegurar que el directorio raíz esté en el PYTHONPATH
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from database.connection import db_pool
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)


def run():
    sql_path = ROOT / "database" / "migration_v16_lv.sql"
    logger.info("Leyendo migración: %s", sql_path)

    sql = sql_path.read_text(encoding="utf-8")

    conn = db_pool.get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        logger.info("✅  Migración v16 aplicada correctamente.")

        # ── Verificación inmediata ────────────────────────────────────────────
        with conn.cursor() as cur:
            # Probar folio LV en año de prueba 9999 para no contaminar consecutivos reales
            cur.execute("SELECT generate_folio('LV', 9999::smallint) AS folio")
            folio = cur.fetchone()[0]
            logger.info("   Prueba generate_folio('LV', 9999) → %s", folio)

            # Verificar que la tabla se creó
            cur.execute("""
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name = 'det_levantamiento_metrologico'
            """)
            existe = cur.fetchone()[0]
            if existe:
                logger.info("   Tabla det_levantamiento_metrologico: ✅ existe")
            else:
                logger.error("   Tabla det_levantamiento_metrologico: ❌ NO encontrada")

            # Limpiar folio de prueba
            cur.execute(
                "DELETE FROM control_folios WHERE tipo_folio = 'LV' AND anio = 9999"
            )
        conn.commit()
        logger.info("   Registro de prueba eliminado.")

    except Exception as exc:
        conn.rollback()
        logger.exception("❌  Error ejecutando migración v16: %s", exc)
        sys.exit(1)
    finally:
        db_pool.release_connection(conn)


if __name__ == "__main__":
    run()
