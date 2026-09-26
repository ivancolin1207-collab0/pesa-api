from database.connection import db_pool
conn = db_pool.get_connection()
with conn.cursor() as cur:
    cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
    tables = [r[0] for r in cur.fetchall()]
    relevant = [t for t in tables if any(k in t for k in ['tecni','usuar','personal','emplea','cat_'])]
    print('All cat_ tables:', [t for t in tables if t.startswith('cat_')])
    print('Relevant:', relevant)
conn.rollback()
db_pool.release_connection(conn)
