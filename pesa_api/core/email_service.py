"""
pesa_api/core/email_service.py — Servicio de envío automático y manual de correos
vía SMTP Gmail con adjuntos de Órdenes de Servicio individuales y en Lotes.
"""
import asyncio
import base64
import email
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import json
import logging
import os
import re
import smtplib
from typing import Optional, Union, List, Dict, Any

from pesa_api.core.config import settings

logger = logging.getLogger("pesa_api.email")


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


def _cargar_pdf_bytes(r, folio: str) -> Optional[bytes]:
    """Obtiene los bytes del PDF (pdf_b64 → pdf_path → uploads/{folio}.pdf). Solo lectura."""
    content_pdf = None
    if r["pdf_b64"]:
        try:
            content_pdf = base64.b64decode(r["pdf_b64"].strip())
        except Exception:
            content_pdf = None
    if not content_pdf and r["pdf_path"] and os.path.exists(r["pdf_path"]):
        try:
            with open(r["pdf_path"], "rb") as fp:
                content_pdf = fp.read()
        except Exception:
            content_pdf = None
    if not content_pdf:
        upload_cand = os.path.join(os.environ.get("UPLOAD_DIR", "uploads"), f"{folio}.pdf")
        if os.path.exists(upload_cand):
            try:
                with open(upload_cand, "rb") as fp:
                    content_pdf = fp.read()
            except Exception:
                content_pdf = None
    return content_pdf or None


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


def construir_nombre_pdf(folio: str, cliente: str = "", id_equipo: str = "", servicio: str = "") -> str:
    """Construye la nomenclatura formal obligatoria: {FOLIO}-{EMPRESA}-{ID}-{SERVICIO}.pdf"""
    f_limpio = limpiar_texto(folio)
    c_limpio = re.sub(r"(?i)\s+(S\.?\s*A\.?(\s*DE\s*C\.?V\.?)?|S\.?\s*DE\s*R\.?L\.?(\s*DE\s*C\.?V\.?)?|S\.?C\.?|INC\.?)$", "", cliente or "")
    c_limpio = limpiar_texto(c_limpio)
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


async def enviar_email_orden(db=None, folio_o_id: Union[str, int] = "", correo_override: Optional[str] = None, forzar: bool = False, folios_lista: Optional[List[str]] = None) -> Dict[str, Any]:
    """
    Envía por correo el PDF de una orden (o lote si pertenece a uno).
    Se ejecuta de forma asíncrona tolerante a fallos. Soporta db=None (obtiene del pool).
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

    try:
        str_id = str(folio_o_id).strip()
        row = await conn.fetchrow(
            """
            SELECT os.id, os.folio_os, os.id_lote, os.correo_cliente, os.email_enviado,
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

        # Si pertenece a un Lote o se pasó lista de folios, agrupar las órdenes del lote
        es_agrupacion_lote = False
        lote_rows = []
        if folios_lista and len(folios_lista) > 1:
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente, os.email_enviado,
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
            if len(lote_rows) > 1:
                es_agrupacion_lote = True
        elif id_lote and str(id_lote).strip():
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente, os.email_enviado,
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
            if len(lote_rows) > 1:
                es_agrupacion_lote = True

        if es_agrupacion_lote:
                # REGLA ESTRICTA: solo órdenes FIRMADAS/CERRADAS y con PDF existente.
                ordenes_validas = []   # [(row, pdf_bytes)]
                no_listas = []
                for r in lote_rows:
                    pdf_bytes = _cargar_pdf_bytes(r, r["folio_os"]) if _es_finalizada(r) else None
                    if pdf_bytes:
                        ordenes_validas.append((r, pdf_bytes))
                    else:
                        no_listas.append(r["folio_os"])

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
                folios_lote = []   # SOLO folios válidos (las no realizadas no se mencionan)
                empresa_lote = ordenes_validas[0][0]["cliente"] or lote_rows[0]["cliente"] or "Cliente"

                for r, content_pdf in ordenes_validas:
                    f_i = r["folio_os"]
                    folios_lote.append(f_i)
                    id_eq = r["id_equipo"] or r["indicador_id"] or ""
                    if not id_eq and r["datos_tecnicos_json"]:
                        try:
                            dj = json.loads(r["datos_tecnicos_json"]) if isinstance(r["datos_tecnicos_json"], str) else r["datos_tecnicos_json"]
                            if isinstance(dj, dict):
                                id_eq = dj.get("id_equipo") or dj.get("id_indicador") or ""
                        except Exception:
                            pass
                    nombre_adj = construir_nombre_pdf(
                        folio=f_i,
                        cliente=r["cliente"],
                        id_equipo=id_eq,
                        servicio=r["srv_nombre"] or r["tipo_servicio"],
                    )
                    adjuntos.append((nombre_adj, content_pdf))

                n = len(adjuntos)
                txt_ordenes = "orden" if n == 1 else "órdenes"
                folios_str = _unir_folios(folios_lote)
                asunto = f"Reporte de Servicio - Lote {folios_str} ({n} {txt_ordenes}) - {empresa_lote} | Básculas PESA"

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
                    <div style="background-color: #B81D24; padding: 18px 24px; border-radius: 8px 8px 0 0;">
                        <h2 style="color: #FFFFFF; margin: 0; font-size: 20px;">Básculas PESA</h2>
                        <p style="color: #FEE2E2; margin: 4px 0 0 0; font-size: 13px;">Entrega Oficial de Servicios Metrológicos</p>
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

        # Extraer PDF
        content_pdf = None
        if row["pdf_b64"]:
            try:
                content_pdf = base64.b64decode(row["pdf_b64"].strip())
            except Exception:
                pass
        if not content_pdf and row["pdf_path"] and os.path.exists(row["pdf_path"]):
            try:
                with open(row["pdf_path"], "rb") as fp:
                    content_pdf = fp.read()
            except Exception:
                pass
        if not content_pdf:
            upload_cand = os.path.join(os.environ.get("UPLOAD_DIR", "uploads"), f"{folio}.pdf")
            if os.path.exists(upload_cand):
                try:
                    with open(upload_cand, "rb") as fp:
                        content_pdf = fp.read()
                except Exception:
                    pass

        if not content_pdf:
            return {"ok": False, "motivo": f"No se encontró el PDF para la orden {folio}"}

        id_eq = row["id_equipo"] or row["indicador_id"] or ""
        if not id_eq and row["datos_tecnicos_json"]:
            try:
                dj = json.loads(row["datos_tecnicos_json"]) if isinstance(row["datos_tecnicos_json"], str) else row["datos_tecnicos_json"]
                if isinstance(dj, dict):
                    id_eq = dj.get("id_equipo") or dj.get("id_indicador") or ""
            except Exception:
                pass

        empresa = row["cliente"] or "Cliente"
        nombre_adj = construir_nombre_pdf(
            folio=folio,
            cliente=empresa,
            id_equipo=id_eq,
            servicio=row["srv_nombre"] or row["tipo_servicio"],
        )

        asunto = f"Orden de Servicio {folio} - {empresa} | Básculas PESA"
        cuerpo_texto = f"""Estimado cliente ({empresa}):

Adjuntamos el reporte oficial correspondiente a la Orden de Servicio {folio}.
Servicio: {row['srv_nombre'] or row['tipo_servicio'] or 'Calibración'}
Dictamen: {row['dictamen'] or 'APTO'}

El documento cuenta con validez y firmas digitales.

Atentamente,
Básculas PESA
recepcion@basculaspesa.com.mx
"""
        cuerpo_html = f"""
        <html>
        <body style="font-family: Arial, sans-serif; color: #1D1D1F; line-height: 1.5;">
            <div style="background-color: #B81D24; padding: 18px 24px; border-radius: 8px 8px 0 0;">
                <h2 style="color: #FFFFFF; margin: 0; font-size: 20px;">Básculas PESA</h2>
                <p style="color: #FEE2E2; margin: 4px 0 0 0; font-size: 13px;">Comprobante de Servicio Finalizado</p>
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
                    <tr style="border-bottom: 1px solid #E2E8F0;">
                        <td style="padding: 8px 0; color: #64748B;">Dictamen:</td>
                        <td style="padding: 8px 0; font-weight: 600; color: #16A34A;">{row['dictamen'] or 'APTO'}</td>
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
        if release_needed:
            try:
                from pesa_api.core.database import get_pool
                await get_pool().release(conn)
            except Exception:
                pass
