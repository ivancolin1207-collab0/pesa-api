import sys, pathlib
sys.path.insert(0, '.')
from config import DB_CONFIG
import psycopg2

# Leer SQL como UTF-8 SIN BOM y ejecutar sentencias por separado
sql_raw = pathlib.Path('database/migration_v20_arquitectura_integral.sql').read_text(encoding='utf-8-sig')
conn = psycopg2.connect(**DB_CONFIG)
conn.autocommit = True
with conn.cursor() as cur:
    cur.execute(sql_raw)
conn.close()
print('[v20] Migracion completada OK')
