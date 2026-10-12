"""
Script de regeneración inmediata de OS-26-570 y OS-26-571.
Corrige el membrete de DIRECCIÓN / PLANTA preservando 100% de las mediciones,
observaciones y firmas digitales (Alan Guevara y Janet López).
"""
import os
import sys
import base64
import sqlite3
from pathlib import Path
import fitz  # PyMuPDF
import psycopg2
import psycopg2.extras

DB_URL = 'postgresql://pesa_user:J494uuILfhNw6qL3n1xFQeijrFX5aSxG@dpg-dak6nh61egvs739ar760-a.oregon-postgres.render.com/pesa_db'
SUCURSAL_DIR = "Carretera el Jaral del Progreso- Cortazar km 4.3 C.P. 38470, Jaral del Progreso, Guanajuato"
UBICACION_EQUIPO = "Aseguramiento de calidad"

def regenerar():
    print("=" * 70)
    print("INICIANDO REGENERACIÓN INMEDIATA DE OS-26-570 Y OS-26-571")
    print("=" * 70)

    # 1. Conexión a PostgreSQL
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = False
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    folios = ['OS-26-570', 'OS-26-571']
    cur.execute("""
        SELECT id, folio_os, id_cliente, sucursal_id, estado, estatus, cliente, ubicacion,
               firma_cliente_nombre, firma_tecnico_b64, firma_cliente_b64, pdf_b64, pdf_path,
               observaciones, fecha
        FROM ordenes_servicio 
        WHERE folio_os IN %s
        ORDER BY folio_os
    """, (tuple(folios),))
    
    rows = cur.fetchall()
    if not rows:
        print("ERROR: No se encontraron las órdenes en PostgreSQL.")
        sys.exit(1)

    # Preparar carpetas de salida
    output_dirs = [
        Path(r"D:\Ordenes De Servicio\uploads"),
        Path(r"C:\PesaServidorCentral\PDF_OS"),
        Path(r"D:\Ordenes De Servicio\servicios_pesa\CPesaServidorCentralPDF_OS")
    ]
    for od in output_dirs:
        try:
            od.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            print(f"Aviso al crear directorio {od}: {e}")

    # Conectar también a SQLite local si existe
    appdata = os.environ.get('APPDATA')
    local_sqlite_path = Path(appdata) / "PesaServicios" / "pesa_local.db" if appdata else None
    sqlite_conn = None
    if local_sqlite_path and local_sqlite_path.exists():
        try:
            sqlite_conn = sqlite3.connect(local_sqlite_path)
            print(f"Conectado a SQLite local: {local_sqlite_path}")
        except Exception as e:
            print(f"Aviso SQLite: {e}")

    for row in rows:
        folio = row['folio_os']
        print(f"\n--- Procesando {folio} (ID: {row['id']}) ---")
        
        pdf_raw_b64 = row['pdf_b64']
        if not pdf_raw_b64:
            print(f"ERROR: {folio} no tiene pdf_b64 en la base de datos.")
            continue

        pdf_bytes = base64.b64decode(pdf_raw_b64)
        doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        page = doc[0]

        # Verificar firmas existentes en el PDF
        images = page.get_images()
        print(f"Imágenes incrustadas en el PDF original: {len(images)}")
        
        # Extraer firma de Janet López para respaldarla en firma_cliente_b64 si es necesario
        firma_cliente_b64_extracted = None
        for img_info in images:
            xref = img_info[0]
            base_img = doc.extract_image(xref)
            # Janet López signature is small PNG (w=260, h=116)
            if base_img['width'] < 400 and base_img['height'] < 200:
                firma_cliente_b64_extracted = base64.b64encode(base_img['image']).decode('ascii')
                print(f"Firma de cliente detectada y extraída (xref={xref}, {len(firma_cliente_b64_extracted)} chars)")

        # Localizar el bloque entre FECHA y MARCA para rediseñar CLIENTE y DIRECCIÓN / PLANTA
        # Redactar de forma exacta el área entre y=112.0 e y=137.5
        redact_rect = fitz.Rect(25.0, 112.0, 586.0, 137.5)
        print(f"Aplicando redacción a rectángulo de cabecera: {redact_rect}")
        page.add_redact_annot(redact_rect, fill=(1, 1, 1))
        page.apply_redactions()

        # Renglón 1: CLIENTE
        p_cli_lbl = fitz.Point(26.0, 121.5)
        page.insert_text(p_cli_lbl, "CLIENTE: ", fontsize=8, color=(0.835, 0.0, 0.0), fontname="hebo")
        w_cli = fitz.get_text_length("CLIENTE: ", fontname="hebo", fontsize=8)
        p_cli_val = fitz.Point(26.0 + w_cli + 2, 121.5)
        page.insert_text(p_cli_val, "Mar Bran S.A. de C.V.", fontsize=8, color=(0, 0, 0), fontname="helv")

        # Renglón 2: DIRECCIÓN / PLANTA
        p_dir_lbl = fitz.Point(26.0, 133.5)
        page.insert_text(p_dir_lbl, "DIRECCIÓN / PLANTA: ", fontsize=8, color=(0.835, 0.0, 0.0), fontname="hebo")
        w_dir = fitz.get_text_length("DIRECCION / PLANTA: ", fontname="hebo", fontsize=8)
        p_dir_val = fitz.Point(26.0 + w_dir + 2, 133.5)
        page.insert_text(p_dir_val, SUCURSAL_DIR, fontsize=8, color=(0, 0, 0), fontname="helv")

        # Guardar binario regenerado
        new_pdf_bytes = doc.write(deflate=True, garbage=3)
        doc.close()

        # Validar el PDF regenerado
        test_doc = fitz.open(stream=new_pdf_bytes, filetype="pdf")
        test_text = test_doc[0].get_text()
        test_imgs = test_doc[0].get_images()
        test_doc.close()

        has_address = SUCURSAL_DIR in test_text
        has_ubic = f"UBICACIÓN: {UBICACION_EQUIPO}" in test_text or UBICACION_EQUIPO in test_text
        print(f"Validación {folio}:")
        print(f"  - Dirección en membrete presente: {has_address}")
        print(f"  - Ubicación de equipo presente:   {has_ubic}")
        print(f"  - Imágenes (firmas + logos):      {len(test_imgs)}")

        if not has_address:
            print("ERROR: La dirección no fue insertada correctamente.")
            sys.exit(1)

        new_pdf_b64 = base64.b64encode(new_pdf_bytes).decode('ascii')

        # 4. Actualizar en PostgreSQL
        final_cli_b64 = row['firma_cliente_b64'] or firma_cliente_b64_extracted or ''
        cur.execute("""
            UPDATE ordenes_servicio
            SET sucursal_id = 16,
                cliente = 'Mar Bran S.A. de C.V.',
                ubicacion = %s,
                firma_cliente_nombre = 'Janet Lopez',
                firma_cliente_b64 = CASE WHEN (firma_cliente_b64 IS NULL OR firma_cliente_b64 = '') THEN %s ELSE firma_cliente_b64 END,
                pdf_b64 = %s,
                pdf_base64 = %s,
                has_pdf = TRUE,
                estado = 'FIRMADA',
                estatus = 'Cerrado',
                sync_status = 'SINCRONIZADO',
                updated_at = NOW()
            WHERE folio_os = %s
        """, (
            UBICACION_EQUIPO,
            final_cli_b64,
            new_pdf_b64,
            new_pdf_b64,
            folio
        ))
        print(f"PostgreSQL actualizado para {folio}.")

        # 5. Actualizar en SQLite local si la tabla contiene la orden
        if sqlite_conn:
            try:
                sc = sqlite_conn.cursor()
                sc.execute("""
                    UPDATE ordenes_servicio
                    SET sucursal_nombre = ?,
                        ubicacion = ?,
                        firma_cliente_nombre = 'Janet Lopez',
                        estado = 'FIRMADA',
                        sync_status = 'Sincronizado'
                    WHERE folio_os = ?
                """, (SUCURSAL_DIR, UBICACION_EQUIPO, folio))
                sqlite_conn.commit()
                print(f"SQLite local actualizado para {folio}.")
            except Exception as se:
                print(f"Aviso actualizando SQLite local: {se}")

        # 6. Guardar en los discos locales
        saved_paths = []
        for od in output_dirs:
            target_file = od / f"{folio}.pdf"
            try:
                target_file.write_bytes(new_pdf_bytes)
                saved_paths.append(str(target_file))
                p_display = str(target_file).encode('ascii', errors='replace').decode('ascii')
                print(f"Archivo guardado: {p_display} ({len(new_pdf_bytes)} bytes)")
            except Exception as e:
                p_display = str(target_file).encode('ascii', errors='replace').decode('ascii')
                print(f"Aviso escribiendo en {p_display}: {e}")

    conn.commit()
    conn.close()
    if sqlite_conn:
        sqlite_conn.close()

    print("\n" + "=" * 70)
    print("REGENERACIÓN DE OS-26-570 Y OS-26-571 COMPLETADA CON ÉXITO")
    print("=" * 70)

if __name__ == '__main__':
    regenerar()
