"""
Script de saneamiento de órdenes huérfanas en PostgreSQL (Render) y SQLite local.
Actualiza órdenes que fueron cerradas falsamente sin binario PDF ni mediciones.
"""
import os
import sys
import psycopg2
import psycopg2.extras

from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.environ.get('DATABASE_URL')
if not DATABASE_URL:
    _u = os.environ.get("PESA_DB_USER")
    _p = os.environ.get("PESA_DB_PASSWORD")
    _h = os.environ.get("PESA_DB_HOST")
    _port = os.environ.get("PESA_DB_PORT", "5432")
    _db = os.environ.get("PESA_DB_NAME", "pesa_db")
    if _u and _p and _h:
        DATABASE_URL = f"postgresql://{_u}:{_p}@{_h}:{_port}/{_db}?sslmode=require"

DB_URL = DATABASE_URL

def sanear_base_central():
    print("=" * 70)
    print("SANEAMIENTO DE ÓRDENES HUÉRFANAS EN POSTGRESQL")
    print("=" * 70)
    
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = False
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    query_select = """
        SELECT folio_os, estatus, estado
        FROM ordenes_servicio
        WHERE 
            (pdf_url IS NULL OR pdf_url = '' OR pdf_url LIKE '%404%')
            AND (pdf_base64 IS NULL OR pdf_base64 = '')
            AND (pdf_b64 IS NULL OR pdf_b64 = '')
            AND (datos_tecnicos_json IS NULL OR datos_tecnicos_json::text IN ('{}', '[]', 'null', ''))
            AND (estatus ILIKE '%cerrad%' OR estatus ILIKE '%complet%' OR estado ILIKE '%cerrad%' OR estado ILIKE '%complet%');
    """
    cur.execute(query_select)
    orphan_rows = cur.fetchall()
    print(f"Órdenes huérfanas detectadas: {len(orphan_rows)}")
    
    if orphan_rows:
        sample = [r['folio_os'] for r in orphan_rows[:10]]
        print(f"Muestra de folios: {sample} ...")

        query_update = """
            UPDATE ordenes_servicio
            SET 
                estatus = 'Asignada',
                estado = 'PROCESO',
                sync_status = 'Asignada',
                sync_check_status = 'ASIGNADA',
                has_pdf = false,
                pdf_url = NULL,
                pdf_base64 = NULL,
                pdf_b64 = NULL,
                updated_at = NOW()
            WHERE 
                (pdf_url IS NULL OR pdf_url = '' OR pdf_url LIKE '%404%')
                AND (pdf_base64 IS NULL OR pdf_base64 = '')
                AND (pdf_b64 IS NULL OR pdf_b64 = '')
                AND (datos_tecnicos_json IS NULL OR datos_tecnicos_json::text IN ('{}', '[]', 'null', ''))
                AND (estatus ILIKE '%cerrad%' OR estatus ILIKE '%complet%' OR estado ILIKE '%cerrad%' OR estado ILIKE '%complet%');
        """
        cur.execute(query_update)
        updated_count = cur.rowcount
        conn.commit()
        print(f"[OK] Se sanearon {updated_count} ordenes en PostgreSQL.")
    else:
        print("No se encontraron órdenes huérfanas para sanear.")

    conn.close()
    print("=" * 70)

if __name__ == '__main__':
    sanear_base_central()
