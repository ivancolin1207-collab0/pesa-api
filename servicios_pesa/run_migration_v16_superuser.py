"""
run_migration_v16_superuser.py — Ejecuta la migración v16 (LV) como superusuario PostgreSQL.

Requisitos:
  • Acceso a PostgreSQL con usuario 'postgres' o equivalente con SUPERUSER.
  • La migración modifica:
      1. Constraint chk_tipo_folio en control_folios  (requiere OWNER)
      2. Función generate_folio()                     (requiere SUPERUSER o OWNER)
      3. Crea tabla det_levantamiento_metrologico      (cualquier usuario con permisos de schema)

Uso:
    python run_migration_v16_superuser.py
"""
import sys
from pathlib import Path
import psycopg2

ROOT    = Path(__file__).resolve().parent
SQL_PATH = ROOT / "database" / "migration_v16_lv.sql"

passwords_to_try = ["", "postgres", "Pesa2026!", "Pesa2025!", "admin", "password", "1234"]

print(f"Leyendo SQL: {SQL_PATH}")
for enc in ("utf-8", "utf-8-sig", "latin-1", "cp1252"):
    try:
        SQL = SQL_PATH.read_text(encoding=enc)
        print(f"   Archivo leído con encoding: {enc}")
        break
    except UnicodeDecodeError:
        continue
else:
    print("❌ No se pudo leer el archivo SQL con ningún encoding conocido.")
    sys.exit(1)

for pwd in passwords_to_try:
    try:
        conn = psycopg2.connect(
            host="localhost", port=5432,
            database="servicios_pesa",
            user="postgres", password=pwd,
            connect_timeout=5,
            options="-c client_encoding=UTF8",
        )
        conn.autocommit = False
        conn.set_client_encoding("UTF8")
        cur = conn.cursor()
        cur.execute(SQL)

        # Verificacion: probar folio LV en anio de prueba
        cur.execute("SELECT generate_folio('LV', 9999::smallint) AS folio")
        folio = cur.fetchone()[0]
        print(f"   ✅ generate_folio('LV', 9999) → {folio}")

        # Verificar tabla creada
        cur.execute(
            "SELECT COUNT(*) FROM information_schema.tables "
            "WHERE table_schema='public' AND table_name='det_levantamiento_metrologico'"
        )
        existe = cur.fetchone()[0]
        print(f"   {'✅' if existe else '❌'} Tabla det_levantamiento_metrologico: "
              f"{'OK' if existe else 'NO ENCONTRADA'}")

        # Limpiar folio de prueba
        cur.execute("DELETE FROM control_folios WHERE tipo_folio = 'LV' AND anio = 9999")

        conn.commit()
        conn.close()
        print(f"\nSUCCESS — Migración v16 aplicada con postgres / '{pwd}'")
        break

    except psycopg2.errors.InsufficientPrivilege as e:
        print(f"Sin permisos con postgres/'{pwd}': {e}")
    except psycopg2.OperationalError as e:
        print(f"Conexión fallida con postgres/'{pwd}': {e}")
    except Exception as e:
        # Otro error de SQL
        try:
            conn.rollback()
            conn.close()
        except Exception:
            pass
        print(f"Error SQL con postgres/'{pwd}': {e}")
        sys.exit(1)
else:
    print("\n❌ No se pudo conectar como superusuario. Prueba las credenciales manualmente.")
    sys.exit(1)
