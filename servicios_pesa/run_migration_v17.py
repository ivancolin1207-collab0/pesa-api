"""
run_migration_v17.py — Migración v17: Soporte Offline-First / Sync
Servicios PESA

Ejecutar desde el directorio servicios_pesa/:
    python run_migration_v17.py

Agrega las columnas sync_status, updated_at, pdf_path,
firma_tecnico_b64, firma_cliente_b64 a ordenes_servicio
y crea el trigger de actualización automática.
"""
import logging
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def run_migration() -> None:
    # Agregar el directorio actual al path
    sys.path.insert(0, str(Path(__file__).parent))

    try:
        from database.connection import db_pool
    except ImportError as e:
        logger.error("No se pudo importar db_pool: %s", e)
        sys.exit(1)

    sql_file = Path(__file__).parent / "database" / "migration_v17_sync.sql"
    if not sql_file.exists():
        logger.error("Archivo de migración no encontrado: %s", sql_file)
        sys.exit(1)

    sql_content = sql_file.read_text(encoding="utf-8")

    logger.info("Iniciando Migración v17 — Soporte Offline-First / Sync")
    logger.info("Servidor: %s", db_pool._config.get("host", "?"))
    logger.info("Base de datos: %s", db_pool._config.get("database", "?"))

    try:
        conn = db_pool.get_connection()
        try:
            with conn.cursor() as cur:
                # Ejecutar statement por statement (ignorando comentarios y bloques vacíos)
                statements = []
                current = []
                in_do_block = False

                for line in sql_content.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("--") or not stripped:
                        continue
                    if stripped.upper().startswith("DO $$"):
                        in_do_block = True
                    current.append(line)
                    if in_do_block and stripped.endswith("$$;"):
                        in_do_block = False
                        statements.append("\n".join(current))
                        current = []
                    elif not in_do_block and stripped.endswith(";"):
                        statements.append("\n".join(current))
                        current = []

                for i, stmt in enumerate(statements, 1):
                    stmt = stmt.strip()
                    if not stmt:
                        continue
                    try:
                        cur.execute(stmt)
                        logger.info("  [OK] Statement %d ejecutado.", i)
                    except Exception as stmt_exc:
                        logger.warning("  [WARN] Statement %d: %s", i, stmt_exc)
                        conn.rollback()

            conn.commit()
            logger.info("✅ Migración v17 completada exitosamente.")

            # Verificación final
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT column_name, data_type, column_default
                    FROM information_schema.columns
                    WHERE table_name = 'ordenes_servicio'
                      AND column_name IN (
                          'sync_status','updated_at','pdf_path',
                          'firma_tecnico_b64','firma_cliente_b64'
                      )
                    ORDER BY column_name
                """)
                rows = cur.fetchall()
                if rows:
                    logger.info("Columnas creadas/verificadas:")
                    for col, dtype, default in rows:
                        logger.info("  ✓ %s (%s, default=%s)", col, dtype, default)
                else:
                    logger.warning("No se encontraron las columnas esperadas.")

            conn.commit()

        finally:
            db_pool.release_connection(conn)

    except Exception as exc:
        logger.error("Error ejecutando migración: %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    run_migration()
