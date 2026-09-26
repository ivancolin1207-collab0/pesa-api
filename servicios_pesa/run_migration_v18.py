#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_migration_v18.py
Ejecuta la migración v18 — PDF Snapshot + Vista completa de excentricidad.

Uso:
    python run_migration_v18.py
"""
import logging
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


def run():
    sql_path = Path(__file__).parent / "database" / "migration_v18_pdf_snapshot.sql"
    if not sql_path.exists():
        logger.error("No se encontró el archivo de migración: %s", sql_path)
        sys.exit(1)

    try:
        from database.connection import db_pool

        sql = sql_path.read_text(encoding="utf-8")

        conn = db_pool.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
            conn.commit()
            logger.info("✅  Migración v18 aplicada exitosamente.")
        finally:
            db_pool.release_connection(conn)

    except Exception as exc:
        logger.exception("❌  Error al ejecutar la migración v18: %s", exc)
        sys.exit(1)

    # Verificación rápida
    try:
        from database.connection import db_pool

        conn = db_pool.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT column_name, data_type
                    FROM information_schema.columns
                    WHERE table_name = 'ordenes_servicio'
                      AND column_name IN (
                          'datos_tecnicos_json', 'pdf_path',
                          'aplica_excentricidad', 'filas_excentricidad',
                          'geometria_plataforma', 'num_secciones',
                          'tipo_no_aplica_exc', 'indicadores_jia'
                      )
                    ORDER BY column_name;
                """)
                rows = cur.fetchall()
                logger.info("Columnas verificadas en ordenes_servicio:")
                for row in rows:
                    logger.info("  %-30s %s", row[0], row[1])

                # Verificar vista
                cur.execute("""
                    SELECT column_name
                    FROM information_schema.columns
                    WHERE table_name = 'v_ordenes_servicio'
                      AND column_name IN ('pdf_path', 'datos_tecnicos_json', 'aplica_excentricidad')
                    ORDER BY column_name;
                """)
                vista_rows = cur.fetchall()
                logger.info("Columnas verificadas en v_ordenes_servicio:")
                for row in vista_rows:
                    logger.info("  %s", row[0])
            conn.commit()
        finally:
            db_pool.release_connection(conn)
    except Exception as exc:
        logger.warning("Error en verificación post-migración: %s", exc)


if __name__ == "__main__":
    run()
