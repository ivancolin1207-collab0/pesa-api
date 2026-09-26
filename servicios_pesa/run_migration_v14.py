"""
Script de migración v14: sucursal_nombre y sucursal_direccion en v_ordenes_servicio
====================================================================================
Actualiza la vista v_ordenes_servicio para hacer JOIN con cliente_sucursales
y exponer los campos sucursal_nombre y sucursal_direccion.

Esto corrige el campo DIRECCIÓN en blanco en el PDF de la Orden de Servicio.

Uso:
    python run_migration_v14.py <password_postgres>

Ejemplo:
    python run_migration_v14.py MiPasswordSecreta
"""
import sys, os
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

try:
    import psycopg2
except ImportError:
    print("ERROR: psycopg2 no está instalado. Ejecuta: pip install psycopg2-binary")
    sys.exit(1)

from dotenv import load_dotenv
load_dotenv()

HOST   = os.getenv("PESA_DB_HOST", "localhost")
PORT   = int(os.getenv("PESA_DB_PORT", "5432"))
DBNAME = os.getenv("PESA_DB_NAME", "servicios_pesa")

if len(sys.argv) < 2:
    print("Uso: python run_migration_v14.py <password_postgres>")
    print("Ejemplo: python run_migration_v14.py MiPasswordSecreta")
    sys.exit(1)

pg_user = "postgres"
pg_pass = sys.argv[1]

try:
    conn = psycopg2.connect(
        host=HOST, port=PORT, dbname=DBNAME,
        user=pg_user, password=pg_pass,
        connect_timeout=10,
    )
    conn.autocommit = False
    print(f"\n  Conectado como {pg_user} a {DBNAME}@{HOST}:{PORT}")
except Exception as exc:
    print(f"\n  ERROR: No se pudo conectar: {exc}")
    sys.exit(1)

# Leer el SQL de la migración
sql_path = Path(__file__).parent / "database" / "migration_v14_sucursal_en_vista.sql"
sql = sql_path.read_text(encoding="utf-8")

print()
print("=" * 70)
print("  MIGRACIÓN v14 — Dirección de sucursal/planta en v_ordenes_servicio")
print("=" * 70)

try:
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print("  OK - Vista v_ordenes_servicio actualizada con JOIN a cliente_sucursales")
    print("  OK - Campos nuevos: sucursal_nombre, sucursal_direccion")

    # Verificar columnas de la vista
    with conn.cursor() as cur:
        cur.execute("""
            SELECT column_name
            FROM   information_schema.columns
            WHERE  table_name = 'v_ordenes_servicio'
            ORDER  BY ordinal_position
        """)
        cols = [r[0] for r in cur.fetchall()]
        print()
        print("  Columnas en v_ordenes_servicio:")
        for c in cols:
            marker = " <<< NUEVO" if c in ("sucursal_nombre", "sucursal_direccion", "sucursal_id", "equipo_catalogo_id") else ""
            print(f"    {c}{marker}")

except Exception as exc:
    conn.rollback()
    print(f"\n  ERROR — se hizo ROLLBACK: {exc}")
    conn.close()
    sys.exit(1)
finally:
    conn.close()

print()
print("=" * 70)
print("  Migración v14 completada exitosamente.")
print("  Reinicia la aplicación para que el PDF muestre la dirección.")
print("=" * 70)
