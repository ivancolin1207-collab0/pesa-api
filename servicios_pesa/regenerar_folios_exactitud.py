"""
regenerar_folios_exactitud.py
Regenera los PDFs de OS-26-558 (4 pts) y OS-26-561 a OS-26-566 (5 pts).
Coloca este archivo en el directorio servicios_pesa/ y ejecuta:
    python regenerar_folios_exactitud.py
"""
import sys
import os
import pathlib
import datetime
import logging

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

_PROJ_ROOT = pathlib.Path(__file__).parent
if str(_PROJ_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJ_ROOT))

try:
    from database.connection import db_pool
    _HAS_DB = True
except Exception as e:
    logger.error("No se pudo conectar a la BD: %s", e)
    _HAS_DB = False

try:
    from services.os_pdf_generator import OsPdfGenerator, os_pdf_generator as _gen
except Exception as e:
    logger.error("No se pudo importar OsPdfGenerator: %s", e)
    sys.exit(1)

OUTPUT_DIR = pathlib.Path(r"C:\PesaServidorCentral\PDF_OS")
if not OUTPUT_DIR.exists():
    OUTPUT_DIR = pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

TRABAJOS = [
    ("OS-26-551", 5),
]


def _leer_os(cursor, folio_os):
    cursor.execute(
        """
        SELECT os.folio_os, os.consecutivo, os.tipo_documento, os.fecha,
               os.observaciones, os.estado, os.id_tipo_servicio, os.tipo_servicio,
               os.id_cliente, os.id_tecnico, os.aplica_excentricidad,
               COALESCE(os.filas_excentricidad, 5) AS filas_excentricidad,
               c.razon_social AS cliente,
               COALESCE(c.direccion, '') AS direccion,
               COALESCE(t.nombre_completo, '') AS tecnico_nombre
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes c ON c.id = os.id_cliente
        LEFT JOIN cat_tecnicos t ON t.id = os.id_tecnico
        WHERE os.folio_os = %s
        """,
        (folio_os,),
    )
    row = cursor.fetchone()
    if row is None:
        return None
    cols = [d.name for d in cursor.description]
    return dict(zip(cols, row))


def _actualizar_filas_exactitud(cursor, folio_os, n):
    try:
        cursor.execute(
            "UPDATE ordenes_servicio SET filas_exactitud = %s WHERE folio_os = %s",
            (n, folio_os),
        )
        logger.info("[BD] %s filas_exactitud=%d OK", folio_os, n)
    except Exception as exc:
        logger.warning("[BD] No se pudo actualizar filas_exactitud para %s: %s", folio_os, exc)


def _construir_os_data(row, puntos):
    fecha = row.get("fecha")
    if isinstance(fecha, datetime.date) and not isinstance(fecha, datetime.datetime):
        fecha = datetime.datetime.combine(fecha, datetime.time())
    return {
        "folio_os":               row["folio_os"],
        "cliente":                row.get("cliente") or "—",
        "direccion":              row.get("direccion") or "",
        "sucursal_direccion":     row.get("direccion") or "",
        "fecha":                  fecha,
        "id_tipo_servicio":       row.get("id_tipo_servicio"),
        "tipo_servicio_nombre":   row.get("tipo_servicio") or "",
        "observaciones":          row.get("observaciones") or "",
        "aplica_excentricidad":   bool(row.get("aplica_excentricidad", True)),
        "filas_excentricidad":    int(row.get("filas_excentricidad") or 5),
        "filas_exactitud":        puntos,
        "puntos_exactitud":       puntos,
        "tecnico_nombre":         row.get("tecnico_nombre") or "—",
        "inicial_calibrador":     "",
        "tipo_calibracion_inicial": "",
        "inicial":                "",
        "numero_cca":             "",
        "cca":                    "",
    }


def _generar_pdf(os_data, tecnico):
    from reportlab.pdfgen import canvas as rl_canvas_mod
    from reportlab.lib.pagesizes import letter
    folio = os_data["folio_os"]
    pdf_path = str(OUTPUT_DIR / f"{folio}.pdf")
    c = rl_canvas_mod.Canvas(pdf_path, pagesize=letter)
    _gen._draw_page(c, os_data, [], [], [], tecnico)
    c.showPage()
    _gen._draw_page(c, os_data, [], [], [], tecnico)
    c.showPage()
    c.save()
    logger.info("[PDF] %s -> %s", folio, pdf_path)
    return pdf_path


def main():
    if not _HAS_DB:
        logger.error("Sin conexion a BD. Abortando.")
        sys.exit(1)

    conn = db_pool.get_connection()
    conn.rollback()   # limpiar cualquier transacción abortada residual
    generados = []
    errores = []
    try:
        with conn.cursor() as cur:
            for folio_os, puntos in TRABAJOS:
                logger.info("--- %s  puntos=%d ---", folio_os, puntos)
                # SAVEPOINT por folio: un error en la actualización no aborta los demás
                cur.execute("SAVEPOINT sp_folio")
                try:
                    row = _leer_os(cur, folio_os)
                    if row is None:
                        logger.warning("[%s] No encontrado en BD", folio_os)
                        cur.execute("RELEASE SAVEPOINT sp_folio")
                        errores.append(folio_os)
                        continue
                    # Intentar actualizar filas_exactitud en BD
                    try:
                        cur.execute("SAVEPOINT sp_update")
                        _actualizar_filas_exactitud(cur, folio_os, puntos)
                        cur.execute("RELEASE SAVEPOINT sp_update")
                    except Exception as exc_upd:
                        cur.execute("ROLLBACK TO SAVEPOINT sp_update")
                        logger.warning("[%s] Actualización BD omitida: %s", folio_os, exc_upd)
                    cur.execute("RELEASE SAVEPOINT sp_folio")
                except Exception as exc_row:
                    cur.execute("ROLLBACK TO SAVEPOINT sp_folio")
                    logger.error("[%s] Error leyendo datos: %s", folio_os, exc_row)
                    errores.append(folio_os)
                    continue
                # Generar el PDF (fuera del cursor section, independiente de BD)
                os_data = _construir_os_data(row, puntos)
                tecnico = row.get("tecnico_nombre") or "—"
                try:
                    pdf_path = _generar_pdf(os_data, tecnico)
                    generados.append((folio_os, pdf_path))
                except Exception as exc_pdf:
                    logger.error("[%s] Error PDF: %s", folio_os, exc_pdf)
                    errores.append(folio_os)
        conn.commit()
        logger.info("COMMIT OK")
    except Exception as exc:
        conn.rollback()
        logger.error("ROLLBACK general: %s", exc)
        raise
    finally:
        db_pool.release_connection(conn)

    print("\n" + "="*60)
    print(f"PDFs regenerados: {len(generados)}")
    for f, p in generados:
        print(f"  OK  {f} -> {p}")
    if errores:
        print(f"\nCon errores: {errores}")
    print("="*60)


if __name__ == "__main__":
    main()
