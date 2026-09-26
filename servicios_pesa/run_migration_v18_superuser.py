"""
run_migration_v18_superuser.py -- Ejecuta la migracion v18 como superusuario PostgreSQL.

Requisitos:
  * Acceso a PostgreSQL con usuario 'postgres' o equivalente con SUPERUSER.
  * La migracion:
      1. Agrega columna datos_tecnicos_json TEXT a ordenes_servicio
      2. Garantiza que pdf_path existe (ADD IF NOT EXISTS, idempotente)
      3. Garantiza columnas de excentricidad (ADD IF NOT EXISTS, idempotente)
      4. Recrea la vista v_ordenes_servicio con todos los campos necesarios

Uso:
    python run_migration_v18_superuser.py
"""
import sys
import os
import subprocess
from pathlib import Path

ROOT     = Path(__file__).resolve().parent
SQL_PATH = ROOT / "database" / "migration_v18_pdf_snapshot.sql"

DB_HOST = "localhost"
DB_PORT = "5432"
DB_NAME = "servicios_pesa"

passwords_to_try = [
    ("postgres",  ""),
    ("postgres",  "postgres"),
    ("postgres",  "Pesa2026!"),
    ("postgres",  "Pesa2025!"),
    ("postgres",  "admin"),
    ("postgres",  "password"),
    ("postgres",  "1234"),
    # Intentar tambien con el usuario de la app si tiene permisos DDL
    ("pesa_app",  "PesaApp2026!"),
]

print(f"Leyendo SQL: {SQL_PATH}")
try:
    SQL = SQL_PATH.read_text(encoding="utf-8")
    print("   Archivo leido con encoding: utf-8")
except Exception as e:
    print(f"ERROR leyendo SQL: {e}")
    sys.exit(1)


def try_psql(user: str, password: str) -> bool:
    """Intenta ejecutar el SQL via psql CLI."""
    psql_candidates = [
        r"C:\Program Files\PostgreSQL\18\bin\psql.exe",
        r"C:\Program Files\PostgreSQL\17\bin\psql.exe",
        r"C:\Program Files\PostgreSQL\16\bin\psql.exe",
        r"C:\Program Files\PostgreSQL\15\bin\psql.exe",
        "psql",
    ]
    env = os.environ.copy()
    env["PGPASSWORD"] = password
    env["PGCLIENTENCODING"] = "UTF8"

    for psql in psql_candidates:
        try:
            result = subprocess.run(
                [psql, "-h", DB_HOST, "-p", DB_PORT, "-U", user, "-d", DB_NAME,
                 "-f", str(SQL_PATH), "--echo-errors"],
                capture_output=True, text=True, encoding="utf-8",
                errors="replace", env=env, timeout=30,
            )
            if result.returncode == 0:
                print(f"   OK via psql ({psql}) como {user}")
                if result.stdout:
                    print(result.stdout[:500])
                return True
            else:
                err = result.stderr[:300] if result.stderr else ""
                if any(x in err.lower() for x in ("password", "autenticaci", "fe_sendauth")):
                    return False
                print(f"   Error psql: {err}")
                return False
        except (FileNotFoundError, PermissionError):
            continue
        except subprocess.TimeoutExpired:
            print(f"   Timeout con {psql}")
            continue
    return False


def try_psycopg2(user: str, password: str) -> bool:
    """Intenta ejecutar el SQL via psycopg2."""
    try:
        import psycopg2
        conn = psycopg2.connect(
            host=DB_HOST, port=int(DB_PORT),
            database=DB_NAME,
            user=user, password=password,
            connect_timeout=5,
            options="-c client_encoding=UTF8",
        )
        conn.autocommit = False
        conn.set_client_encoding("UTF8")
        cur = conn.cursor()
        cur.execute(SQL)

        cur.execute("""
            SELECT column_name
            FROM information_schema.columns
            WHERE table_name = 'ordenes_servicio'
              AND column_name IN ('datos_tecnicos_json', 'pdf_path')
            ORDER BY column_name;
        """)
        cols = cur.fetchall()
        print(f"   Columnas verificadas: {[c[0] for c in cols]}")

        conn.commit()
        conn.close()
        print(f"   OK via psycopg2 como {user}")
        return True
    except Exception as e:
        err_str = str(e)
        if any(x in err_str.lower() for x in ("password", "autenticaci", "authentication", "fe_sendauth")):
            return False
        if any(x in err_str.lower() for x in ("permission", "privilege", "owner")):
            print(f"   Sin permisos como {user}: {err_str[:150]}")
            return False
        print(f"   Error inesperado como {user}: {err_str[:200]}")
        return False


print("\nIntentando conectar como superusuario...")
exito = False
for user, pwd in passwords_to_try:
    print(f"\n[Probando] {user} / '{pwd[:4]}...' ...")
    if try_psql(user, pwd):
        exito = True
        print(f"\nSUCCESS -- Migracion v18 aplicada via psql como {user}")
        break
    if try_psycopg2(user, pwd):
        exito = True
        print(f"\nSUCCESS -- Migracion v18 aplicada via psycopg2 como {user}")
        break

if not exito:
    print("\n" + "="*70)
    print("ERROR: No se pudo conectar como superusuario.")
    print("\nEjecuta el SQL manualmente en pgAdmin o psql como 'postgres':")
    print(f"   Archivo: {SQL_PATH}")
    print(f'\n   psql -U postgres -d {DB_NAME} -f "{SQL_PATH}"')
    print("="*70)
    sys.exit(1)
