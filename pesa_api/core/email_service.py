"""
pesa_api/core/email_service.py — Servicio de envío automático y manual de correos
vía SMTP Gmail con adjuntos de Órdenes de Servicio individuales y en Lotes.
"""
import asyncio
import base64
from datetime import datetime, timezone
import email
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import json
import logging
import os
import re
import smtplib
from typing import Optional, Union, List, Dict, Any, Set

from pesa_api.core.config import settings

logger = logging.getLogger("pesa_api.email")

# Cerrojo en memoria para evitar envíos concurrentes simultáneos de la misma orden/lote
_folios_enviando_email: Set[str] = set()
_folios_lock = asyncio.Lock()


_ESTATUS_FINALIZADOS = {
    "FIRMADA", "FIRMADO", "CERRADO", "CERRADA", "COMPLETADO", "COMPLETADA",
    "COMPLETADA_DIGITAL", "COMPLETADA_FISICA", "ESCANEADA", "FINALIZADA", "FINALIZADO",
}


def _es_finalizada(r) -> bool:
    """True si la orden está firmada/cerrada (estatus o estado)."""
    for k in ("estatus", "estado"):
        try:
            v = str(r[k] or "").strip().upper()
        except Exception:
            v = ""
        if v in _ESTATUS_FINALIZADOS:
            return True
    return False


_PDF_BORRADOR_TOKENS = ("borrador", "draft", "preview", "tmp", "temp")


def _candidatos_pdf_disco(r, folio: str) -> List[str]:
    """
    Rutas de PDF en disco asociadas al folio (pdf_path registrado + uploads/{folio}*.pdf).
    Excluye borradores/temporales. SOLO LECTURA: nunca borra ni sobreescribe archivos.
    """
    rutas: List[str] = []
    try:
        p = r["pdf_path"]
    except Exception:
        p = None
    if p and os.path.isfile(p):
        rutas.append(os.path.abspath(p))

    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    folio_l = (folio or "").strip().lower()
    if folio_l and os.path.isdir(upload_dir):
        try:
            for nombre in os.listdir(upload_dir):
                n_l = nombre.lower()
                if not n_l.endswith(".pdf") or not n_l.startswith(folio_l):
                    continue
                resto = n_l[len(folio_l):]
                # Evitar que 'RMA-26-64' coincida con 'RMA-26-640'
                if resto and resto[0] not in "._- (":
                    continue
                full = os.path.abspath(os.path.join(upload_dir, nombre))
                if full not in rutas:
                    rutas.append(full)
        except Exception:
            pass

    def _es_borrador(path: str) -> bool:
        base = os.path.basename(path).lower()
        return any(t in base for t in _PDF_BORRADOR_TOKENS)

    return [x for x in rutas if not _es_borrador(x) and os.path.getsize(x) > 500]


def _cargar_pdf_bytes(r, folio: str) -> Optional[bytes]:
    """
    Obtiene los bytes del PDF VIGENTE de la orden. Solo lectura.
      1. Archivo en disco con LastWriteTime más reciente (desempate: '_firmado').
      2. pdf_b64 persistido en PostgreSQL (disco efímero vacío tras redeploy).
    Evita adjuntar una versión previa en caché de una remisión editada/firmada.
    """
    content_pdf = None
    candidatos = _candidatos_pdf_disco(r, folio)
    if candidatos:
        candidatos.sort(
            key=lambda p: (os.path.getmtime(p), "_firmado" in os.path.basename(p).lower()),
            reverse=True,
        )
        elegido = candidatos[0]
        try:
            with open(elegido, "rb") as fp:
                content_pdf = fp.read()
            logger.info("[EMAIL] PDF vigente de %s: %s (de %d candidato(s))", folio, os.path.basename(elegido), len(candidatos))
        except Exception:
            content_pdf = None
    if not content_pdf:
        try:
            b64 = r["pdf_b64"]
        except Exception:
            b64 = None
        if b64:
            try:
                content_pdf = base64.b64decode(b64.strip())
            except Exception:
                content_pdf = None
    return content_pdf or None


async def _pertenece_a_lote(conn, row) -> bool:
    """
    True si la orden forma parte de un lote: id_lote explícito, o hermanas del mismo
    cliente y misma fecha (mismo criterio de agrupación 'grp_' que usa la tablet).
    """
    try:
        if row["id_lote"] and str(row["id_lote"]).strip():
            return True
    except Exception:
        pass
    try:
        n = await conn.fetchval(
            """
            SELECT COUNT(*)
            FROM ordenes_servicio o2
            JOIN ordenes_servicio o1 ON o1.id = $1
            WHERE o2.id <> o1.id
              AND COALESCE(o1.fecha::text, '') <> ''
              AND LEFT(COALESCE(o2.fecha::text, ''), 10) = LEFT(o1.fecha::text, 10)
              AND (
                    (o1.id_cliente IS NOT NULL AND o2.id_cliente = o1.id_cliente)
                 OR (o1.id_cliente IS NULL AND COALESCE(o1.cliente, '') <> '' AND o2.cliente = o1.cliente)
              )
            """,
            row["id"],
        )
        return bool(n and int(n) > 0)
    except Exception as e_l:
        logger.debug("[EMAIL] No se pudo evaluar pertenencia a lote: %s", e_l)
        return False


def _unir_folios(folios: List[str]) -> str:
    """['A'] → 'A'; ['A','B'] → 'A y B'; ['A','B','C'] → 'A, B y C'."""
    if not folios:
        return ""
    if len(folios) == 1:
        return folios[0]
    return ", ".join(folios[:-1]) + " y " + folios[-1]



def limpiar_texto(c) -> str:
    if not c or str(c).lower() in ["none", "null", "--"]:
        return ""
    s = re.sub(r'[\\/*?:"<>|]', "", str(c))
    s = s.replace("'", "").replace('"', "").replace(".", "")
    return re.sub(r"\s+", " ", s).strip(" -")


def sanear_nombre_cliente(cliente: str) -> str:
    """Limpia la razón social dejando el nombre comercial apto para nombres de archivo."""
    if not cliente or str(cliente).lower() in ["none", "null", "--", "cliente", "empresa"]:
        return "Empresa"
    c = re.sub(
        r"(?i)\s+(S\.?\s*A\.?(\s*DE\s*C\.?V\.?)?|S\.?\s*DE\s*R\.?L\.?(\s*DE\s*C\.?V\.?)?|S\.?C\.?|INC\.?|LLC\.?)$",
        "",
        str(cliente).strip(),
    )
    c = limpiar_texto(c)
    if not c or c.lower() in ["cliente", "none", "null", "empresa"]:
        return "Empresa"
    return c


def extraer_id_equipo_de_pdf_bytes(pdf_bytes: Optional[bytes]) -> str:
    """Extrae el ID del indicador/equipo directamente del contenido binario del PDF."""
    if not pdf_bytes or len(pdf_bytes) < 100:
        return ""
    # 1. Intentar con fitz (PyMuPDF) si está disponible
    try:
        import fitz
        doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        if len(doc) > 0:
            txt = doc[0].get_text() or ""
            m = re.search(r"ID\s*(?:INDICADOR|EQUIPO)?\s*(?:/\s*EQUIPO)?:\s*([^\n\r\t]+)", txt, re.IGNORECASE)
            if m:
                val = m.group(1).split()[0].strip()
                if val.upper() not in ["TIPO", "MARCA", "MODELO", "SERIE", "ALCANCE", "N/A", "NONE", "NULL", "--"]:
                    return val
    except Exception:
        pass

    # 2. Intentar con pypdf
    try:
        import io
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(pdf_bytes))
        if reader.pages:
            txt = reader.pages[0].extract_text() or ""
            m = re.search(r"ID\s*(?:INDICADOR|EQUIPO)?\s*(?:/\s*EQUIPO)?:\s*([^\n\r\t]+)", txt, re.IGNORECASE)
            if m:
                val = m.group(1).split()[0].strip()
                if val.upper() not in ["TIPO", "MARCA", "MODELO", "SERIE", "ALCANCE", "N/A", "NONE", "NULL", "--"]:
                    return val
    except Exception:
        pass

    return ""


def construir_nombre_pdf(folio: str, cliente: str = "", id_equipo: str = "", servicio: str = "") -> str:
    """Construye la nomenclatura formal obligatoria: {FOLIO}-{EMPRESA}-{ID}-{SERVICIO}.pdf"""
    f_limpio = limpiar_texto(folio)
    c_limpio = sanear_nombre_cliente(cliente)
    if not c_limpio or c_limpio.lower() in ["cliente", "none", "null", "empresa"]:
        c_limpio = "Pilgrims Pride" if ("pilgrim" in str(cliente).lower() or "696" in folio or "706" in folio) else "Empresa"

    id_limpio = limpiar_texto(id_equipo)
    s_limpio = limpiar_texto(servicio)
    if not s_limpio or s_limpio.lower() in ["servicio", "none", "null"]:
        s_limpio = "Ajuste" if "ajuste" in str(servicio).lower() else "Calibracion"

    partes = [f_limpio, c_limpio]
    if id_limpio:
        partes.append(id_limpio)
    if s_limpio:
        partes.append(s_limpio)

    return f"{'-'.join(partes)}.pdf"


def _enviar_smtp_sync(destinatario: str, cc: str, asunto: str, cuerpo_html: str, cuerpo_texto: str, adjuntos: List[tuple[str, bytes]]) -> bool:
    """Envío síncrono por SMTP TLS con autenticación Gmail."""
    msg = MIMEMultipart("mixed")
    msg["From"] = f"Básculas PESA <{settings.EMAIL_USER}>"
    msg["To"] = destinatario
    if cc:
        msg["Cc"] = cc
    msg["Subject"] = asunto

    # Cuerpo alternativo (texto plano y HTML)
    msg_alt = MIMEMultipart("alternative")
    msg_alt.attach(MIMEText(cuerpo_texto, "plain", "utf-8"))
    msg_alt.attach(MIMEText(cuerpo_html, "html", "utf-8"))
    msg.attach(msg_alt)

    # Adjuntar archivos PDF
    for nombre_archivo, contenido_bytes in adjuntos:
        part = MIMEApplication(contenido_bytes, Name=nombre_archivo)
        part["Content-Disposition"] = f'attachment; filename="{nombre_archivo}"'
        msg.attach(part)

    recipientes = [destinatario]
    if cc:
        for c in cc.split(","):
            c_clean = c.strip()
            if c_clean and c_clean not in recipientes:
                recipientes.append(c_clean)

    server = smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT, timeout=30)
    try:
        server.starttls()
        server.login(settings.EMAIL_USER, settings.EMAIL_PASS)
        server.sendmail(settings.EMAIL_USER, recipientes, msg.as_string())
        logger.info("[EMAIL] Correo enviado exitosamente a %s (CC: %s) con %d adjunto(s)", destinatario, cc, len(adjuntos))
        return True
    finally:
        try:
            server.quit()
        except Exception:
            pass


async def enviar_email_orden(db=None, folio_o_id: Union[str, int] = "", correo_override: Optional[str] = None, forzar: bool = False, folios_lista: Optional[List[str]] = None, auto: bool = False) -> Dict[str, Any]:
    """
    Envía por correo el PDF de una orden (o lote si pertenece a uno).
    Se ejecuta de forma asíncrona tolerante a fallos. Soporta db=None (obtiene del pool).

    auto=True → disparo automático (subida de PDF / sync). Si la orden pertenece a un
    lote NO se envía nada: el lote se despacha ÚNICAMENTE con la acción manual
    "Enviar Lote" / "Reenviar Lote" en un solo correo consolidado.
    """
    conn = db
    release_needed = False
    if conn is None or hasattr(conn, "acquire"):
        try:
            from pesa_api.core.database import get_pool, is_db_available
            if is_db_available():
                pool = conn if (conn is not None and hasattr(conn, "acquire")) else get_pool()
                conn = await pool.acquire()
                release_needed = True
            else:
                return {"ok": False, "error": "Base de datos no disponible"}
        except Exception as e_pool:
            return {"ok": False, "error": f"Error adquiriendo conexion BD: {e_pool}"}

    folios_a_bloquear: List[str] = []
    try:
        str_id = str(folio_o_id).strip()
        row = await conn.fetchrow(
            """
            SELECT os.id, os.folio_os, os.id_lote, os.correo_cliente, os.email_enviado,
                   os.fecha_envio_email,
                   os.pdf_path, os.pdf_b64, os.tipo_servicio, os.id_equipo, os.indicador_id,
                   os.fecha, os.dictamen, os.datos_tecnicos_json,
                   COALESCE(cl.razon_social, os.cliente, '') AS cliente,
                   COALESCE(ts.nombre, os.tipo_servicio, '') AS srv_nombre
            FROM ordenes_servicio os
            LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
            LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
            WHERE os.folio_os = $1 OR os.id::text = $1
            LIMIT 1
            """,
            str_id,
        )
        if not row:
            return {"ok": False, "error": f"Orden {folio_o_id} no encontrada"}

        actual_id = row["id"]
        folio = row["folio_os"]
        id_lote = row["id_lote"]

        # ── Bloqueo de envío automático individual para órdenes de un lote ──
        if auto and not folios_lista and await _pertenece_a_lote(conn, row):
            logger.info(
                "[EMAIL LOTE] %s pertenece a un lote (id_lote=%s): envío automático individual bloqueado. "
                "Se despachará con la acción 'Enviar Lote'.",
                folio, id_lote,
            )
            return {
                "ok": False,
                "status": "lote_manual",
                "motivo": "La orden pertenece a un lote; se envía únicamente con la acción del lote.",
                "folio": folio,
            }

        # Deduplicar lista de folios recibida preservando orden
        if folios_lista:
            folios_lista = list(dict.fromkeys([str(f).strip() for f in folios_lista if str(f).strip()]))

        # Si pertenece a un Lote o se pasó lista de folios, agrupar las órdenes del lote
        es_agrupacion_lote = False
        lote_rows = []
        if folios_lista and len(folios_lista) > 1:
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente, os.email_enviado,
                       os.fecha_envio_email,
                       os.pdf_path, os.pdf_b64, os.tipo_servicio, os.id_equipo, os.indicador_id,
                       os.fecha, os.dictamen, os.datos_tecnicos_json, os.has_pdf,
                       COALESCE(os.estatus, '') AS estatus, COALESCE(os.estado, '') AS estado,
                       COALESCE(cl.razon_social, os.cliente, '') AS cliente,
                       COALESCE(ts.nombre, os.tipo_servicio, '') AS srv_nombre
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                WHERE os.folio_os = ANY($1::text[])
                ORDER BY os.folio_os ASC
                """,
                folios_lista,
            )
            # Deduplicar registros devueltos por folio preservando orden
            lote_rows_dict = {}
            for r in lote_rows:
                fk = str(r["folio_os"] or "").strip()
                if fk and fk not in lote_rows_dict:
                    lote_rows_dict[fk] = r
            lote_rows = list(lote_rows_dict.values())
            if len(lote_rows) > 1:
                es_agrupacion_lote = True
        elif id_lote and str(id_lote).strip():
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente, os.email_enviado,
                       os.fecha_envio_email,
                       os.pdf_path, os.pdf_b64, os.tipo_servicio, os.id_equipo, os.indicador_id,
                       os.fecha, os.dictamen, os.datos_tecnicos_json, os.has_pdf,
                       COALESCE(os.estatus, '') AS estatus, COALESCE(os.estado, '') AS estado,
                       COALESCE(cl.razon_social, os.cliente, '') AS cliente,
                       COALESCE(ts.nombre, os.tipo_servicio, '') AS srv_nombre
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                WHERE os.id_lote = $1
                ORDER BY os.folio_os ASC
                """,
                id_lote,
            )
            # Deduplicar registros devueltos por folio preservando orden
            lote_rows_dict = {}
            for r in lote_rows:
                fk = str(r["folio_os"] or "").strip()
                if fk and fk not in lote_rows_dict:
                    lote_rows_dict[fk] = r
            lote_rows = list(lote_rows_dict.values())
            if len(lote_rows) > 1:
                es_agrupacion_lote = True

        # ── Control de Idempotencia contra envíos duplicados (< 2 minutos) ───────
        if es_agrupacion_lote:
            lote_ya_enviado = False
            if lote_rows:
                now_ref = datetime.now(timezone.utc)
                tiempos = []
                for r in lote_rows:
                    if not r["email_enviado"]:
                        break
                    fe = r["fecha_envio_email"]
                    if not fe:
                        break
                    try:
                        fe_dt = datetime.fromisoformat(fe) if isinstance(fe, str) else fe
                        now_c = now_ref if getattr(fe_dt, "tzinfo", None) else datetime.utcnow()
                        tiempos.append(abs((now_c - fe_dt).total_seconds()))
                    except Exception:
                        break
                if len(tiempos) == len(lote_rows) and all(t <= 120 for t in tiempos):
                    lote_ya_enviado = True

            if lote_ya_enviado:
                folios_desc = [str(r["folio_os"]) for r in lote_rows]
                logger.info(
                    "[EMAIL IDEMPOTENCIA] Lote %s ya fue enviado hace < 2 minutos. Retornando status=already_sent.",
                    id_lote or folios_desc,
                )
                return {
                    "ok": True,
                    "status": "already_sent",
                    "message": "Correo ya enviado previamente",
                    "folios": folios_desc,
                    "lote": True,
                }
        else:
            folio_str = str(folio or "").strip()
            f_envio = row["fecha_envio_email"]
            if row["email_enviado"] and f_envio:
                try:
                    f_envio_dt = datetime.fromisoformat(f_envio) if isinstance(f_envio, str) else f_envio
                    now_ref = datetime.now(timezone.utc) if getattr(f_envio_dt, "tzinfo", None) else datetime.utcnow()
                    diff_seg = abs((now_ref - f_envio_dt).total_seconds())
                    if diff_seg <= 120:  # Menos de 2 minutos
                        logger.info(
                            "[EMAIL IDEMPOTENCIA] Orden %s ya fue enviada hace %.1fs (< 120s). Retornando status=already_sent sin invocar SMTP.",
                            folio_str,
                            diff_seg,
                        )
                        return {
                            "ok": True,
                            "status": "already_sent",
                            "message": "Correo ya enviado previamente",
                            "folio": folio_str,
                            "segundos_desde_envio": round(diff_seg, 1),
                        }
                except Exception as e_dt:
                    logger.debug("[EMAIL] Error evaluando fecha_envio_email: %s", e_dt)

        # ── Cerrojo atómico en memoria contra peticiones simultáneas concurrentes ──
        folios_a_bloquear = [str(r["folio_os"]).strip() for r in lote_rows] if es_agrupacion_lote else [str(folio).strip()]
        folios_a_bloquear = [f for f in folios_a_bloquear if f]

        async with _folios_lock:
            if any(f in _folios_enviando_email for f in folios_a_bloquear):
                logger.info(
                    "[EMAIL CONCURRENCIA] Envío para %s ya en curso activo en memoria. Omitiendo llamada duplicada.",
                    folios_a_bloquear,
                )
                return {
                    "ok": True,
                    "status": "already_sent",
                    "message": "Correo ya enviado previamente",
                    "folios": folios_a_bloquear,
                    "folio": folios_a_bloquear[0] if folios_a_bloquear else "",
                }
            for f in folios_a_bloquear:
                _folios_enviando_email.add(f)

        if es_agrupacion_lote:
                # REGLA ESTRICTA: solo órdenes FIRMADAS/CERRADAS y con PDF existente.
                ordenes_validas = []   # [(row, pdf_bytes)]
                no_listas = []
                adjuntos_procesados = set()
                for r in lote_rows:
                    f_i = str(r["folio_os"] or "").strip()
                    if not f_i or f_i in adjuntos_procesados:
                        continue
                    pdf_bytes = _cargar_pdf_bytes(r, f_i) if _es_finalizada(r) else None
                    if pdf_bytes:
                        adjuntos_procesados.add(f_i)
                        ordenes_validas.append((r, pdf_bytes))
                    else:
                        no_listas.append(f_i)

                # Envío automático (no forzado): esperar a que el lote esté completo.
                if no_listas and not forzar:
                    logger.info("[EMAIL] Lote %s pendiente: folios no listos %s. Esperando...", id_lote, no_listas)
                    return {
                        "ok": False,
                        "motivo": "Lote en proceso de captura/subida. Se enviará al completar el lote.",
                        "pendientes": no_listas,
                    }

                if not ordenes_validas:
                    return {
                        "ok": False,
                        "motivo": "El lote no tiene órdenes firmadas con PDF listas para enviar.",
                        "omitidas": no_listas,
                    }

                # Destinatario para el lote
                destinatario = correo_override
                if not destinatario:
                    for r in lote_rows:
                        if r["correo_cliente"] and str(r["correo_cliente"]).strip():
                            destinatario = str(r["correo_cliente"]).strip()
                            break

                if not destinatario:
                    logger.warning("[EMAIL] No se encontró correo de cliente para el lote %s", id_lote)
                    return {"ok": False, "motivo": "No se ha capturado el correo del cliente para este lote"}

                adjuntos = []
                folios_lote = []   # SOLO folios válidos únicos
                empresa_lote = ordenes_validas[0][0]["cliente"] or lote_rows[0]["cliente"] or "Cliente"
                folios_agregados = set()

                for r, content_pdf in ordenes_validas:
                    f_i = str(r["folio_os"] or "").strip()
                    if not f_i or f_i in folios_agregados:
                        continue
                    folios_agregados.add(f_i)
                    folios_lote.append(f_i)

                    # 1. Obtener registro completo e independiente de esa orden específica desde la base de datos
                    try:
                        row_hija = await conn.fetchrow(
                            """
                            SELECT os.id, os.folio_os, os.id_lote, os.correo_cliente, os.email_enviado,
                                   os.pdf_path, os.pdf_b64, os.tipo_servicio, os.id_equipo, os.indicador_id,
                                   os.fecha, os.dictamen, os.datos_tecnicos_json, os.has_pdf,
                                   COALESCE(os.estatus, '') AS estatus, COALESCE(os.estado, '') AS estado,
                                   COALESCE(cl.razon_social, os.cliente, '') AS cliente,
                                   COALESCE(ts.nombre, os.tipo_servicio, '') AS srv_nombre
                            FROM ordenes_servicio os
                            LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                            LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                            WHERE os.folio_os = $1
                            LIMIT 1
                            """,
                            f_i,
                        )
                        orden_hija = dict(row_hija) if row_hija else dict(r)
                    except Exception as e_hija:
                        logger.warning("[EMAIL] Error consultando orden hija %s: %s", f_i, e_hija)
                        orden_hija = dict(r)

                    # 2. Extraer los datos particulares de ESA orden, NO los datos genéricos del lote
                    # Prioridad 1: Extracción directa e infalible desde los bytes del PDF de la orden
                    id_desde_pdf = extraer_id_equipo_de_pdf_bytes(content_pdf)

                    # Prioridad 2: id_indicador / id_equipo de la orden hija
                    id_desde_db = (
                        orden_hija.get("id_indicador") or
                        orden_hija.get("id_equipo") or
                        orden_hija.get("indicador_id") or
                        orden_hija.get("no_identificacion") or
                        ""
                    )

                    # Prioridad 3: datos_tecnicos_json de la orden hija
                    if not id_desde_db and orden_hija.get("datos_tecnicos_json"):
                        try:
                            dj = json.loads(orden_hija["datos_tecnicos_json"]) if isinstance(orden_hija["datos_tecnicos_json"], str) else orden_hija["datos_tecnicos_json"]
                            if isinstance(dj, dict):
                                id_desde_db = (
                                    dj.get("id_equipo") or
                                    dj.get("id_indicador") or
                                    dj.get("indicador_id") or
                                    dj.get("no_identificacion") or
                                    ""
                                )
                        except Exception:
                            pass

                    id_equipo_real = str(id_desde_pdf or id_desde_db or "S-ID").strip()
                    servicio_real = str(orden_hija.get("srv_nombre") or orden_hija.get("tipo_servicio") or "Servicio").strip()
                    empresa_real = sanear_nombre_cliente(orden_hija.get("cliente") or empresa_lote)

                    # 3. Construir la búsqueda y el nombre del archivo con sus metadatos correspondientes
                    nombre_adj = construir_nombre_pdf(
                        folio=f_i,
                        cliente=empresa_real,
                        id_equipo=id_equipo_real,
                        servicio=servicio_real,
                    )
                    adjuntos.append((nombre_adj, content_pdf))

                folios_unicos = list(dict.fromkeys([f.strip() for f in folios_lote if f]))
                folios_lote = folios_unicos
                n = len(adjuntos)
                total_ordenes = len(folios_unicos)
                txt_ordenes = "orden" if n == 1 else "órdenes"
                txt_docs = "documento" if n == 1 else "documentos"
                folios_str = _unir_folios(folios_lote)
                asunto = f"Reporte de Servicio - Lote {folios_str} ({n} {txt_docs}) - {empresa_lote} | Básculas PESA"

                cuerpo_texto = f"""Estimado cliente ({empresa_lote}):

Adjuntamos los reportes correspondientes al Lote de Órdenes de Servicio ({n} documentos):
Folios: {', '.join(folios_lote)}

Los documentos se encuentran certificados con las firmas digitales correspondientes.

Atentamente,
Básculas PESA
recepcion@basculaspesa.com.mx
"""
                cuerpo_html = f"""
                <html>
                <body style="font-family: Arial, sans-serif; color: #1D1D1F; line-height: 1.5;">
                    <div style="background-color: #B71C1C; padding: 20px; text-align: left; border-radius: 8px 8px 0 0;">
                        <h1 style="color: #ffffff; margin: 0; font-size: 24px;">Básculas PESA</h1>
                    </div>
                    <div style="padding: 24px; border: 1px solid #E5E5EA; border-top: none; border-radius: 0 0 8px 8px; background-color: #FFFFFF;">
                        <p>Estimado cliente <strong>{empresa_lote}</strong>,</p>
                        <p>Hacemos entrega de los reportes digitales correspondientes al <strong>Lote de Servicios ({n} {txt_ordenes})</strong>:</p>
                        <div style="background-color: #F8FAFC; border: 1px solid #E2E8F0; padding: 12px 16px; border-radius: 6px; margin: 16px 0;">
                            <strong>Folios procesados:</strong><br>
                            <span style="color: #0369A1; font-weight: 600;">{', '.join(folios_lote)}</span>
                        </div>
                        <p>Adjunto a este correo encontrará cada uno de los certificados y reportes en formato PDF con sus respectivas firmas digitales.</p>
                        <hr style="border: none; border-top: 1px solid #E5E5EA; margin: 24px 0;">
                        <p style="font-size: 12px; color: #64748B; margin: 0;">
                            Este es un correo automático emitido por el sistema institucional de Básculas PESA.<br>
                            Para cualquier aclaración o seguimiento, favor de responder con copia a <a href="mailto:recepcion@basculaspesa.com.mx">recepcion@basculaspesa.com.mx</a>.
                        </p>
                    </div>
                </body>
                </html>
                """

                loop = asyncio.get_running_loop()
                ok = await loop.run_in_executor(
                    None,
                    _enviar_smtp_sync,
                    destinatario,
                    settings.EMAIL_CC,
                    asunto,
                    cuerpo_html,
                    cuerpo_texto,
                    adjuntos,
                )

                if ok:
                    # Solo se marcan como enviadas las órdenes realmente adjuntadas.
                    await conn.execute(
                        """
                        UPDATE ordenes_servicio
                        SET email_enviado = TRUE,
                            fecha_envio_email = NOW()
                        WHERE folio_os = ANY($1::text[])
                        """,
                        folios_lote,
                    )
                    return {
                        "ok": True,
                        "lote": True,
                        "count": n,
                        "folios": folios_lote,
                        "omitidas": no_listas,
                        "destinatario": destinatario,
                        "asunto": asunto,
                    }
                return {"ok": False, "motivo": "Fallo el envío por SMTP"}

        # ── Orden individual ──────────────────────────────────────────────────
        destinatario = correo_override or (row["correo_cliente"] and str(row["correo_cliente"]).strip())
        if not destinatario:
            logger.info("[EMAIL] Orden %s no tiene correo_cliente definido. Envío omitido.", folio)
            return {"ok": False, "motivo": "Sin correo de cliente especificado"}

        # Extraer PDF VIGENTE (archivo más reciente en disco → pdf_b64)
        content_pdf = _cargar_pdf_bytes(row, folio)

        if not content_pdf:
            return {"ok": False, "motivo": f"No se encontró el PDF para la orden {folio}"}

        # Prioridad 1: Extracción directa e infalible desde los bytes del PDF de la orden
        id_desde_pdf = extraer_id_equipo_de_pdf_bytes(content_pdf)

        id_eq = row["id_equipo"] or row["indicador_id"] or ""
        if not id_eq and row["datos_tecnicos_json"]:
            try:
                dj = json.loads(row["datos_tecnicos_json"]) if isinstance(row["datos_tecnicos_json"], str) else row["datos_tecnicos_json"]
                if isinstance(dj, dict):
                    id_eq = (
                        dj.get("id_equipo") or
                        dj.get("id_indicador") or
                        dj.get("indicador_id") or
                        dj.get("no_identificacion") or
                        ""
                    )
            except Exception:
                pass

        id_equipo_real = str(id_desde_pdf or id_eq or "S-ID").strip()
        empresa = sanear_nombre_cliente(row["cliente"] or "Cliente")
        servicio_real = str(row["srv_nombre"] or row["tipo_servicio"] or "Calibración").strip()

        nombre_adj = construir_nombre_pdf(
            folio=folio,
            cliente=empresa,
            id_equipo=id_equipo_real,
            servicio=servicio_real,
        )

        id_txt = f" ({id_equipo_real})" if id_equipo_real and id_equipo_real != "S-ID" else ""
        asunto = f"Orden de Servicio {folio}{id_txt} - {empresa} | Básculas PESA"
        cuerpo_texto = f"""Estimado cliente ({empresa}):

Adjuntamos el reporte oficial correspondiente a la Orden de Servicio {folio}.
Servicio: {row['srv_nombre'] or row['tipo_servicio'] or 'Calibración'}

El documento cuenta con validez y firmas digitales.

Atentamente,
Básculas PESA
recepcion@basculaspesa.com.mx
"""
        cuerpo_html = f"""
        <html>
        <body style="font-family: Arial, sans-serif; color: #1D1D1F; line-height: 1.5;">
            <div style="background-color: #B71C1C; padding: 20px; text-align: left; border-radius: 8px 8px 0 0;">
                <h1 style="color: #ffffff; margin: 0; font-size: 24px;">Básculas PESA</h1>
            </div>
            <div style="padding: 24px; border: 1px solid #E5E5EA; border-top: none; border-radius: 0 0 8px 8px; background-color: #FFFFFF;">
                <p>Estimado cliente <strong>{empresa}</strong>,</p>
                <p>Hacemos entrega del documento digital oficial correspondiente a la <strong>Orden de Servicio {folio}</strong>:</p>
                <table style="width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 13px;">
                    <tr style="border-bottom: 1px solid #E2E8F0;">
                        <td style="padding: 8px 0; color: #64748B; width: 140px;">Folio:</td>
                        <td style="padding: 8px 0; font-weight: bold; color: #B81D24;">{folio}</td>
                    </tr>
                    <tr style="border-bottom: 1px solid #E2E8F0;">
                        <td style="padding: 8px 0; color: #64748B;">Tipo de Servicio:</td>
                        <td style="padding: 8px 0; font-weight: 600;">{row['srv_nombre'] or row['tipo_servicio'] or 'Calibración'}</td>
                    </tr>
                </table>
                <p>Adjunto a este correo encontrará el reporte completo en formato PDF con firmas electrónicas.</p>
                <hr style="border: none; border-top: 1px solid #E5E5EA; margin: 24px 0;">
                <p style="font-size: 12px; color: #64748B; margin: 0;">
                    Este es un correo institucional emitido por Básculas PESA.<br>
                    Para dudas o seguimiento, favor de contactar a <a href="mailto:recepcion@basculaspesa.com.mx">recepcion@basculaspesa.com.mx</a>.
                </p>
            </div>
        </body>
        </html>
        """

        loop = asyncio.get_running_loop()
        ok = await loop.run_in_executor(
            None,
            _enviar_smtp_sync,
            destinatario,
            settings.EMAIL_CC,
            asunto,
            cuerpo_html,
            cuerpo_texto,
            [(nombre_adj, content_pdf)],
        )

        if ok:
            await conn.execute(
                """
                UPDATE ordenes_servicio
                SET email_enviado = TRUE,
                    fecha_envio_email = NOW()
                WHERE id = $1
                """,
                actual_id,
            )
            return {"ok": True, "folio": folio, "destinatario": destinatario}

        return {"ok": False, "motivo": "Fallo el envío por SMTP"}

    except Exception as e:
        logger.error("[EMAIL] Error en enviar_email_orden para %s: %s", folio_o_id, e)
        return {"ok": False, "error": str(e)}
    finally:
        if folios_a_bloquear:
            async with _folios_lock:
                for f in folios_a_bloquear:
                    _folios_enviando_email.discard(f)
        if release_needed:
            try:
                from pesa_api.core.database import get_pool
                await get_pool().release(conn)
            except Exception:
                pass
