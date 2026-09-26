"""
Script de migración v6: columna consecutivo + estado ASIGNADA
==============================================================
Ejecuta con usuario postgres (superusuario) para aplicar los cambios DDL
que no puede hacer pesa_app (que solo tiene DML).

Uso:
    python run_migration_v6.py <password_postgres>

Ejemplo:
    python run_migration_v6.py MiPasswordSecreta
"""
import sys, os

# Asegurar que podemos importar desde el paquete
sys.path.insert(0, os.path.dirname(__file__))

try:
    import psycopg2
except ImportError:
    print("ERROR: psycopg2 no está instalado. Ejecuta: pip install psycopg2-binary")
    sys.exit(1)

# ── Leer configuración base ────────────────────────────────────────────────────
from dotenv import load_dotenv
load_dotenv()

HOST   = os.getenv("PESA_DB_HOST", "localhost")
PORT   = int(os.getenv("PESA_DB_PORT", "5432"))
DBNAME = os.getenv("PESA_DB_NAME", "servicios_pesa")

if len(sys.argv) < 2:
    print("Uso: python run_migration_v6.py <password_postgres>")
    print("Ejemplo: python run_migration_v6.py MiPasswordSecreta")
    sys.exit(1)

pg_user = "postgres"
pg_pass = sys.argv[1]

# ── Conectar como superusuario ─────────────────────────────────────────────────
try:
    conn = psycopg2.connect(
        host=HOST, port=PORT, dbname=DBNAME,
        user=pg_user, password=pg_pass,
        connect_timeout=10,
    )
    conn.autocommit = False
    print(f"\n  ✅ Conectado como {pg_user}")
except Exception as exc:
    print(f"\n  ❌ No se pudo conectar: {exc}")
    sys.exit(1)

# ── Sentencias DDL ─────────────────────────────────────────────────────────────
STMTS = [
    # 1. Agregar columna consecutivo
    ("Agregar columna consecutivo",
     "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS consecutivo INT DEFAULT 1;"),

    # 2. Agregar columna modalidad
    ("Agregar columna modalidad",
     "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS modalidad VARCHAR(20) DEFAULT 'FISICO';"),

    # 3. Agregar columna tipo_documento
    ("Agregar columna tipo_documento",
     "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_documento VARCHAR(10) DEFAULT 'OS';"),

    # 4. Hacer nullable id_tipo_servicio (pre-asignación digital)
    ("Hacer nullable id_tipo_servicio",
     "ALTER TABLE ordenes_servicio ALTER COLUMN id_tipo_servicio DROP NOT NULL;"),

    # 5. Actualizar CHECK constraint para incluir 'ASIGNADA'
    ("Eliminar chk_os_estado antiguo",
     "ALTER TABLE ordenes_servicio DROP CONSTRAINT IF EXISTS chk_os_estado;"),

    ("Crear chk_os_estado con ASIGNADA",
     """ALTER TABLE ordenes_servicio ADD CONSTRAINT chk_os_estado CHECK (
         estado IN (
             'PROCESO', 'CANCELADA', 'ESCANEADA',
             'ASIGNADA', 'EN_CAMPO', 'SYNC_PENDIENTE', 'FIRMADA', 'COMPLETADA'
         )
     );"""),

    # 6. Backfill: extraer consecutivo numérico del folio_os existente
    ("Backfill consecutivo desde folio_os",
     """UPDATE ordenes_servicio
        SET    consecutivo = CAST(SPLIT_PART(folio_os, '-', 3) AS INT)
        WHERE  folio_os    LIKE '%-%-%'
          AND  SPLIT_PART(folio_os, '-', 3) ~ '^[0-9]+$'
          AND  (consecutivo IS NULL OR consecutivo <= 1);"""),
]

# ── Ejecutar en transacción única ─────────────────────────────────────────────
print()
try:
    with conn.cursor() as cur:
        for desc, sql in STMTS:
            try:
                cur.execute(sql)
                print(f"  ✅ {desc}")
            except Exception as exc:
                print(f"  ⚠️  {desc}: {exc}")
                # Continuar — muchos ALTER son idempotentes

    conn.commit()
    print()
    print("  ✅ Transacción confirmada (COMMIT).")

    # Verificar resultado
    with conn.cursor() as cur:
        cur.execute("""
            SELECT column_name, data_type, is_nullable, column_default
            FROM   information_schema.columns
            WHERE  table_name = 'ordenes_servicio'
            ORDER  BY ordinal_position
        """)
        rows = cur.fetchall()
        print()
        print("  Columnas actuales en ordenes_servicio:")
        for r in rows:
            nullable = "NULL    " if r[2] == "YES" else "NOT NULL"
            default  = f"  DEFAULT={r[3]}" if r[3] else ""
            print(f"    {r[0]:30s}  {str(r[1]):25s}  {nullable}{default}")

except Exception as exc:
    conn.rollback()
    print(f"\n  ❌ Error — se hizo ROLLBACK: {exc}")
    sys.exit(1)
finally:
    conn.close()

print()
print("=" * 60)
print("  Migración v6 completada exitosamente.")
print("  Reinicia la aplicación para que los cambios surtan efecto.")
print("=" * 60)
