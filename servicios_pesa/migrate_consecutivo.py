"""
Script de migración: agrega columna 'consecutivo' y otras columnas requeridas
a la tabla ordenes_servicio si no existen.
"""
import sys, os

sys.path.insert(0, os.path.dirname(__file__))
os.chdir(os.path.dirname(__file__))

from database.connection import db_pool
from config import DB_CONFIG

print("Conectando a:", DB_CONFIG.get("host"), "/", DB_CONFIG.get("database"))
db_pool.initialize()
conn = db_pool.get_connection()

MIGRATIONS = [
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS consecutivo          INT DEFAULT 0;",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_documento        VARCHAR(10) DEFAULT 'OS';",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS modalidad             VARCHAR(20) DEFAULT 'FISICO';",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cliente               TEXT;",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS id_cliente            INT;",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS id_tecnico            INT;",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;",
    "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS created_at            TIMESTAMPTZ DEFAULT NOW();",
]

try:
    with conn.cursor() as cur:
        for sql in MIGRATIONS:
            try:
                cur.execute(sql)
                conn.commit()
                print("  OK :", sql[:70])
            except Exception as e:
                conn.rollback()
                print("SKIP :", str(e)[:90])

    # Verificar columnas resultantes
    with conn.cursor() as cur2:
        cur2.execute("""
            SELECT column_name, data_type, column_default
            FROM information_schema.columns
            WHERE table_name = 'ordenes_servicio'
            ORDER BY ordinal_position
        """)
        cols = cur2.fetchall()
        print()
        print("Columnas actuales en ordenes_servicio:")
        for c in cols:
            print(f"  {c[0]:38s} {c[1]:22s} default={c[2]}")
finally:
    db_pool.release_connection(conn)

print()
print("Migracion completada exitosamente.")
