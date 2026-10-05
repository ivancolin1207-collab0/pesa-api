"""Migración: ordenes_servicio.id -> SERIAL NOT NULL PRIMARY KEY.

Corrige el desfase tablet->Postgres: los endpoints de la API actualizan con
WHERE id = $N, y 64 filas tenían id NULL (0 filas afectadas, 200 OK falso).
Todo en una sola transacción. No toca PDFs ni ninguna otra columna.
"""
import sys
sys.path.insert(0, "/Users/cesarivan/Desktop/Ordenes De Servicio/servicios_pesa")
from database.connection import db_pool

conn = db_pool.get_connection()
try:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*), COUNT(id), MAX(id) FROM ordenes_servicio")
        print("ANTES  total/non-null/max:", cur.fetchone())

        cur.execute("LOCK TABLE ordenes_servicio IN ACCESS EXCLUSIVE MODE")
        cur.execute("CREATE SEQUENCE IF NOT EXISTS ordenes_servicio_id_seq OWNED BY ordenes_servicio.id")
        cur.execute("SELECT setval('ordenes_servicio_id_seq', COALESCE((SELECT MAX(id) FROM ordenes_servicio), 0) + 1, false)")
        # Asignar ids en orden cronológico/folio para que sean estables
        cur.execute("""
            WITH faltantes AS (
                SELECT ctid, folio_os FROM ordenes_servicio
                WHERE id IS NULL
                ORDER BY fecha NULLS LAST, folio_os
            )
            UPDATE ordenes_servicio o
               SET id = nextval('ordenes_servicio_id_seq')
              FROM faltantes f
             WHERE o.ctid = f.ctid
        """)
        print("ids asignados:", cur.rowcount)
        cur.execute("ALTER TABLE ordenes_servicio ALTER COLUMN id SET DEFAULT nextval('ordenes_servicio_id_seq')")
        cur.execute("ALTER TABLE ordenes_servicio ALTER COLUMN id SET NOT NULL")
        cur.execute("ALTER TABLE ordenes_servicio ADD CONSTRAINT ordenes_servicio_pkey PRIMARY KEY (id)")

        cur.execute("SELECT COUNT(*), COUNT(id), MAX(id), COUNT(DISTINCT id) FROM ordenes_servicio")
        after = cur.fetchone()
        print("DESPUÉS total/non-null/max/distinct:", after)
        assert after[0] == after[1] == after[3], "Verificación falló — rollback"
    conn.commit()
    print("COMMIT OK")
except Exception as e:
    conn.rollback()
    print("ROLLBACK:", e)
    raise
finally:
    db_pool.release_connection(conn)
