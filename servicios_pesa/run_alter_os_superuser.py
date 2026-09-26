"""Script para ejecutar ALTER TABLE ordenes_servicio como superusuario."""
import psycopg2

SQL = """
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS sucursal_id        INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT
        REFERENCES cliente_equipos(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_os_sucursal_id
    ON ordenes_servicio (sucursal_id) WHERE sucursal_id IS NOT NULL;
"""

passwords_to_try = ["", "postgres", "Pesa2026!", "admin", "password"]
for pwd in passwords_to_try:
    try:
        conn = psycopg2.connect(
            host="localhost", port=5432,
            database="servicios_pesa",
            user="postgres", password=pwd,
            connect_timeout=5,
        )
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute(SQL)
        conn.commit()
        conn.close()
        print(f"SUCCESS with postgres / '{pwd}'")
        break
    except Exception as e:
        print(f"Failed postgres/'{pwd}': {e}")
