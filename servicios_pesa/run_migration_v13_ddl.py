"""
Script de migración v13 parcial (DDL): agrega columnas sucursal_id y equipo_catalogo_id
a la tabla ordenes_servicio, y actualiza la vista v_ordenes_servicio.

REQUIERE contraseña del superusuario postgres.

Uso:
    python run_migration_v13_ddl.py <password_postgres>
"""
import sys, os
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

try:
    import psycopg2
except ImportError:
    print("ERROR: pip install psycopg2-binary")
    sys.exit(1)

from dotenv import load_dotenv
load_dotenv()

HOST   = os.getenv("PESA_DB_HOST", "localhost")
PORT   = int(os.getenv("PESA_DB_PORT", "5432"))
DBNAME = os.getenv("PESA_DB_NAME", "servicios_pesa")

if len(sys.argv) < 2:
    print("Uso: python run_migration_v13_ddl.py <password_postgres>")
    sys.exit(1)

try:
    conn = psycopg2.connect(host=HOST, port=PORT, dbname=DBNAME,
                             user="postgres", password=sys.argv[1], connect_timeout=10)
    conn.autocommit = False
    print(f"Conectado como postgres a {DBNAME}@{HOST}:{PORT}")
except Exception as e:
    print(f"ERROR al conectar: {e}")
    sys.exit(1)

DDL_STEPS = [
    ("ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sucursal_id INT REFERENCES cliente_sucursales(id) ON DELETE SET NULL",
     "Agregar columna sucursal_id"),
    ("ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT REFERENCES cliente_equipos(id) ON DELETE SET NULL",
     "Agregar columna equipo_catalogo_id"),
    ("ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS holograma_actualizado VARCHAR(100)",
     "Agregar columna holograma_actualizado"),
    ("CREATE INDEX IF NOT EXISTS idx_os_sucursal_id ON ordenes_servicio (sucursal_id) WHERE sucursal_id IS NOT NULL",
     "Crear indice idx_os_sucursal_id"),
]

with conn.cursor() as cur:
    for sql, desc in DDL_STEPS:
        try:
            cur.execute(sql)
            print(f"  OK: {desc}")
        except Exception as e:
            print(f"  WARN: {desc}: {e}")

# Aplicar la vista v14
sql_path = Path(__file__).parent / "database" / "migration_v14_sucursal_en_vista.sql"
view_sql = sql_path.read_text(encoding="utf-8-sig").lstrip("\ufeff")
try:
    with conn.cursor() as cur:
        cur.execute(view_sql)
    print("  OK: Vista v_ordenes_servicio actualizada (v14)")
except Exception as e:
    print(f"  ERROR en vista: {e}")
    conn.rollback()
    conn.close()
    sys.exit(1)

conn.commit()
print()

# Verificar
with conn.cursor() as cur:
    cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name='v_ordenes_servicio' ORDER BY ordinal_position")
    cols = [r[0] for r in cur.fetchall()]
    print("sucursal_direccion en vista:", "sucursal_direccion" in cols)
    print("sucursal_nombre en vista:", "sucursal_nombre" in cols)

conn.close()
print()
print("MIGRACION COMPLETADA - Reinicia la aplicacion.")