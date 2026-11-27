"""
pesa_api/core/email_service.py — Servicio de envío automático y manual de correos
vía SMTP Gmail con adjuntos de Órdenes de Servicio individuales y en Lotes.
"""
import asyncio
import base64
from datetime import datetime, timezone, timedelta
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
_email_cols_checked: bool = False


def _obtener_tz_mexico():
    """Retorna la zona horaria oficial de México / Querétaro (America/Mexico_City, UTC-6 permanente)."""
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/Mexico_City")
    except Exception:
        return timezone(timedelta(hours=-6))


def formatear_fecha_hora_mexico(raw_val: Any) -> str:
    """Convierte cualquier timestamp ISO / datetime a DD/MM/YYYY HH:mm en hora America/Mexico_City."""
    if raw_val is None:
        return ""
    if isinstance(raw_val, datetime):
        dt = raw_val
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(_obtener_tz_mexico()).strftime("%d/%m/%Y %H:%M")
    s = str(raw_val).strip()
    if not s or s.lower() in ("none", "null"):
        return ""
    if re.match(r"^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}", s):
        return s[:16]
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(_obtener_tz_mexico()).strftime("%d/%m/%Y %H:%M")
    except Exception:
        return s


def normalizar_cc_correo(cc: Optional[str] = None) -> str:
    """Garantiza que recepcion@basculaspesa.com.mx esté siempre presente en la lista CC."""
    cc_parts = [c.strip() for c in (cc or "").split(",") if c.strip()]
    if "recepcion@basculaspesa.com.mx" not in [c.lower() for c in cc_parts]:
        cc_parts.append("recepcion@basculaspesa.com.mx")
    return ", ".join(cc_parts)


async def _ensure_email_columns(conn) -> None:
    """
    Garantiza de forma idempotente las columnas de equipo y trazabilidad de correo
    (correo_enviado, correo_destino, correo_cc, fecha_envio_correo) y retroalimenta históricos.
    """
    global _email_cols_checked
    if _email_cols_checked or conn is None:
        return
    ddl_statements = (
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS marca TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS modelo TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS numero_cca TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS numero_dve TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS correo_cliente TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS correo_enviado BOOLEAN DEFAULT FALSE",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS correo_destino TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS correo_cc TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS fecha_envio_correo TIMESTAMPTZ",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cca_dve_pdf_checked BOOLEAN DEFAULT FALSE",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS motivo_cancelacion TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cancelada_por TEXT",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS fecha_cancelacion TIMESTAMP",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sin_correo_cliente BOOLEAN DEFAULT FALSE",
        "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS motivo_sin_correo TEXT",
        "ALTER TABLE ordenes_servicio DROP CONSTRAINT IF EXISTS chk_os_estado",
        "ALTER TABLE cliente_sucursales ADD COLUMN IF NOT EXISTS email TEXT",
    )
    for stmt in ddl_statements:
        try:
            await conn.execute(stmt)
        except Exception:
            pass
    try:
        # 1. Limpiar valores genéricos inválidos ('Cliente', 'Sin registrar')
        await conn.execute(
            """
            UPDATE ordenes_servicio
            SET correo_destino = NULL
            WHERE LOWER(TRIM(COALESCE(correo_destino, ''))) IN ('cliente', 'sin registrar', 'destinatario registrado', 'none', 'null')
            """
        )
        await conn.execute(
            """
            UPDATE ordenes_servicio
            SET correo_cliente = NULL
            WHERE LOWER(TRIM(COALESCE(correo_cliente, ''))) IN ('cliente', 'sin registrar', 'destinatario registrado', 'none', 'null')
            """
        )
        # 2. Propagar correos reales ya registrados en órdenes hacia cat_clientes.email si está vacío
        await conn.execute(
            """
            UPDATE cat_clientes cl
            SET email = sub.correo_real
            FROM (
                SELECT DISTINCT ON (id_cliente)
                    id_cliente,
                    COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) AS correo_real
                FROM ordenes_servicio
                WHERE id_cliente IS NOT NULL
                  AND COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) LIKE '%@%'
                ORDER BY id_cliente, fecha_envio_correo DESC NULLS LAST, updated_at DESC NULLS LAST
            ) sub
            WHERE cl.id = sub.id_cliente
              AND COALESCE(NULLIF(TRIM(cl.email), ''), '') = ''
            """
        )
        # 3. Rellenar correo_destino y correo_cliente reales en órdenes enviadas cruzando con sucursal / cliente / hermanas
        await conn.execute(
            """
            UPDATE ordenes_servicio os
            SET correo_enviado     = TRUE,
                correo_destino     = COALESCE(
                    NULLIF(TRIM(os.correo_destino), ''),
                    NULLIF(TRIM(os.correo_cliente), ''),
                    (SELECT NULLIF(TRIM(s.email), '') FROM cliente_sucursales s WHERE s.id = os.sucursal_id AND s.email LIKE '%@%' LIMIT 1),
                    (SELECT NULLIF(TRIM(c.email), '') FROM cat_clientes c WHERE c.id = os.id_cliente AND c.email LIKE '%@%' LIMIT 1),
                    (SELECT COALESCE(NULLIF(TRIM(o2.correo_destino), ''), NULLIF(TRIM(o2.correo_cliente), ''))
                     FROM ordenes_servicio o2
                     WHERE o2.id_cliente = os.id_cliente
                       AND COALESCE(NULLIF(TRIM(o2.correo_destino), ''), NULLIF(TRIM(o2.correo_cliente), '')) LIKE '%@%'
                     ORDER BY o2.fecha_envio_correo DESC NULLS LAST, o2.updated_at DESC NULLS LAST LIMIT 1)
                ),
                correo_cc          = COALESCE(NULLIF(TRIM(os.correo_cc), ''), 'recepcion@basculaspesa.com.mx'),
                fecha_envio_correo = COALESCE(os.fecha_envio_correo, os.fecha_envio_email)
            WHERE COALESCE(os.correo_enviado, os.email_enviado, FALSE) = TRUE
            """
        )
        await conn.execute(
            """
            UPDATE ordenes_servicio
            SET correo_cliente = correo_destino
            WHERE correo_destino IS NOT NULL AND correo_destino LIKE '%@%'
              AND (correo_cliente IS NULL OR TRIM(correo_cliente) = '')
            """
        )
    except Exception:
        pass
    try:
        cand_rows = await conn.fetch(
            """
            SELECT id, folio_os, datos_tecnicos_json, COALESCE(NULLIF(pdf_b64, ''), NULLIF(pdf_base64, '')) AS b64
            FROM ordenes_servicio
            WHERE cca_dve_pdf_checked IS NOT TRUE
              AND COALESCE(NULLIF(TRIM(numero_cca), ''), '') = ''
              AND COALESCE(NULLIF(TRIM(numero_dve), ''), '') = ''
              AND (COALESCE(NULLIF(pdf_b64, ''), NULLIF(pdf_base64, '')) IS NOT NULL)
            ORDER BY id DESC
            LIMIT 50
            """
        )
        for cr in cand_rows:
            cid = cr["id"]
            b64_raw = cr["b64"]
            cca_found = ""
            dve_found = ""
            try:
                cca_dt, dve_dt = extraer_cca_dve({"datos_tecnicos_json": cr["datos_tecnicos_json"]})
                cca_found = cca_dt
                dve_found = dve_dt
            except Exception:
                pass
            if b64_raw and (not cca_found and not dve_found):
                try:
                    pdf_b = base64.b64decode(str(b64_raw).strip())
                    meta_p = extraer_metadatos_equipo_de_pdf_bytes(pdf_b)
                    cca_p, dve_p = extraer_cca_dve(meta_p)
                    cca_found = cca_p or cca_found
                    dve_found = dve_p or dve_found
                except Exception:
                    pass
            try:
                await conn.execute(
                    """
                    UPDATE ordenes_servicio
                    SET numero_cca = COALESCE(NULLIF(TRIM(numero_cca), ''), NULLIF($1, '')),
                        numero_dve = COALESCE(NULLIF(TRIM(numero_dve), ''), NULLIF($2, '')),
                        cca_dve_pdf_checked = TRUE
                    WHERE id = $3
                    """,
                    cca_found,
                    dve_found,
                    cid,
                )
            except Exception:
                pass
    except Exception:
        pass
    _email_cols_checked = True


_INVALIDOS_CORREO = {
    "", "none", "null", "sin id", "sin modelo", "sin serie", "sin marca",
    "n/a", "na", "--", "-", "s-id", "s/id", "por definir", "sin ubicacion", "sin ubicación",
    "sin cca", "sin dve", "cca.26.xxxx", "dve.26.xxxx", "cca.26.xxxxx", "dve.26.xxxxx",
}


def _es_placeholder_regulatorio(raw_val: Any) -> bool:
    s = str(raw_val or "").strip()
    if not s:
        return True
    if s.lower() in _INVALIDOS_CORREO or s.lower() == "pendiente":
        return True
    if re.match(r"^(CCA|DVE)\.\d{2}\.?$", s, re.IGNORECASE):
        return True
    if re.search(r"(?:^|[.\-\s])x{2,}(?:$|[.\-\s])", s, re.IGNORECASE) or re.search(r"\.x+$", s, re.IGNORECASE):
        return True
    return False


def _limpiar_val_correo(raw_val: Any, es_regulatorio: bool = False) -> str:
    if raw_val is None:
        return ""
    s = re.sub(r"[\r\n\t]+", " ", str(raw_val)).strip()
    if not s or s.lower() in _INVALIDOS_CORREO:
        return ""
    if es_regulatorio and _es_placeholder_regulatorio(s):
        return ""
    return s


def _extraer_dt_dict(orden: Dict[str, Any]) -> Dict[str, Any]:
    extra: Dict[str, Any] = {}
    for jkey in (
        "datos_json",
        "datos_tecnicos_json",
        "datos_captura",
        "payload_json",
        "mediciones_json",
        "metrologia_data",
        "detalle_json",
        "raw_data",
    ):
        raw_dt = orden.get(jkey)
        if isinstance(raw_dt, dict):
            extra.update(raw_dt)
        elif isinstance(raw_dt, str) and raw_dt.strip().startswith("{"):
            try:
                parsed = json.loads(raw_dt)
                if isinstance(parsed, dict):
                    extra.update(parsed)
            except Exception:
                pass
    return extra


def extraer_cca_dve(orden: dict) -> tuple[str, str]:
    """
    Extractor universal de CCA y DVE desde todas las llaves posibles de BD/JSON:
      numero_cca, num_cca, cca, no_cca, certificado_cca, folio_cca
      numero_dve, num_dve, dve, no_dve, dictamen_dve, folio_dve
    incluyendo JSONs anidados (datos_json, datos_tecnicos_json, payload_json, etc.).
    """
    if not isinstance(orden, dict):
        orden = dict(orden) if orden else {}
    extra = _extraer_dt_dict(orden)
    fuente = dict(extra)
    for k_ord, v_ord in orden.items():
        if v_ord is not None and str(v_ord).strip() != "":
            fuente[k_ord] = v_ord
        elif k_ord not in fuente:
            fuente[k_ord] = v_ord

    cca = ""
    for k in ("numero_cca", "num_cca", "cca", "no_cca", "certificado_cca", "folio_cca"):
        val = str(fuente.get(k) or "").strip()
        if val and not _es_placeholder_regulatorio(val):
            cca = val
            break

    dve = ""
    for k in ("numero_dve", "num_dve", "dve", "no_dve", "dictamen_dve", "folio_dve"):
        val = str(fuente.get(k) or "").strip()
        if val and not _es_placeholder_regulatorio(val):
            dve = val
            break

    if not dve:
        div_ver = str(fuente.get("div_verificacion") or "").strip()
        if div_ver and div_ver.upper().startswith("DVE") and not _es_placeholder_regulatorio(div_ver):
            dve = div_ver

    # Respetar regla estricta si tipo_servicio viene explícito sin calibración / inspección
    ts_raw = str(fuente.get("tipo_servicio_nombre") or fuente.get("tipo_servicio") or "").strip()
    if ts_raw:
        import unicodedata as _ud_e
        ts_norm = "".join(
            ch for ch in _ud_e.normalize("NFKD", ts_raw.lower()) if not _ud_e.combining(ch)
        )
        tiene_calib = "calibraci" in ts_norm or bool(re.search(r"\bcca\b", ts_norm))
        tiene_insp = (
            "inspecc" in ts_norm
            or "verifica" in ts_norm
            or bool(re.search(r"\bdve\b", ts_norm))
        )
        if not tiene_calib:
            cca = ""
        if not tiene_insp:
            dve = ""

    return cca, dve


def _extraer_campos_tabla_correo(orden: dict) -> Dict[str, str]:
    if not isinstance(orden, dict):
        orden = dict(orden) if orden else {}
    dt = _extraer_dt_dict(orden)

    def _obtener(claves: tuple[str, ...]) -> str:
        for k in claves:
            v = _limpiar_val_correo(orden.get(k))
            if v:
                return v
        for k in claves:
            v = _limpiar_val_correo(dt.get(k))
            if v:
                return v
        return ""

    folio = _limpiar_val_correo(orden.get("folio") or orden.get("folio_os") or dt.get("folio_os") or dt.get("folio"))
    marca = _obtener(("marca", "equipo_marca", "indicador_marca"))
    modelo = _obtener(("modelo", "equipo_modelo", "indicador_modelo"))
    id_ind = _obtener(("id_indicador", "id_equipo", "indicador_id", "no_identificacion", "id_interno", "tag"))

    cca_raw, dve_raw = extraer_cca_dve(orden)
    cca_fmt = (cca_raw if cca_raw.upper().startswith("CCA") else f"CCA.{cca_raw}") if cca_raw else ""
    dve_fmt = (dve_raw if dve_raw.upper().startswith("DVE") else f"DVE.{dve_raw}") if dve_raw else ""

    partes = [p for p in (folio, marca, modelo, id_ind, cca_fmt, dve_fmt) if p]
    return {
        "folio": folio,
        "marca": marca,
        "modelo": modelo,
        "id_indicador": id_ind,
        "cca": cca_fmt,
        "dve": dve_fmt,
        "codigo": "-".join(partes),
    }


def formatear_linea_correo_orden(orden: dict) -> str:
    """
    Construye el identificador dinámico de equipo para Asunto y Tabla HTML:
      FOLIO-MARCA-MODELO-ID-CCA-DVE
    """
    return _extraer_campos_tabla_correo(orden)["codigo"]


def _clave_orden_folio(folio_str: str):
    """Ordenamiento natural numérico de folios (ej. OS-26-810 < OS-26-811 < OS-26-1000)."""
    partes = re.split(r"(\d+)", str(folio_str or "").strip().upper())
    return [int(p) if p.isdigit() else p for p in partes]


def armar_correo_institucional(
    ordenes: List[Dict[str, Any]],
    cliente: str,
    es_lote: Optional[bool] = None,
) -> tuple[str, str]:
    """
    Constructor único institucional de Asunto y Cuerpo HTML con Tabla Oficial (1 a N órdenes).
    """
    asunto, cuerpo_html, _, _ = construir_asunto_y_cuerpo_correo(
        ordenes,
        cliente,
        es_lote=bool(es_lote) if es_lote is not None else (len(ordenes or []) > 1),
    )
    return asunto, cuerpo_html


def _nombre_tipo_documento_correo(folios: List[str]) -> str:
    f0 = (folios[0] if folios else "").strip().upper()
    if f0.startswith("OSOCC-"):
        return "Diagnóstico de Celda de Carga"
    if f0.startswith("OSOB-"):
        return "Inspección de Báscula"
    if f0.startswith("RMA-"):
        return "Remisión de Material"
    if f0.startswith("RE-"):
        return "Revisión de Báscula"
    if f0.startswith("LP-"):
        return "Levantamiento de Proyecto"
    if f0.startswith("LV-"):
        return "Levantamiento Metrológico"
    return "Orden de Servicio"


def _es_cancelada_orden(r: Any) -> bool:
    """Retorna True si la orden fue marcada como CANCELADA / no utilizada en lote."""
    if not r:
        return False
    for k in ("estatus", "estado"):
        try:
            v = str(r[k] if isinstance(r, dict) or hasattr(r, "__getitem__") else getattr(r, k, "") or "").strip().upper()
        except Exception:
            v = ""
        if v in ("CANCELADA", "CANCELADO", "ELIMINADA", "ELIMINADO"):
            return True
    return False


def construir_asunto_y_cuerpo_correo(
    ordenes_lote: List[Dict[str, Any]],
    cliente: str,
    es_lote: bool = False,
    solo_recepcion: bool = False,
    motivo_sin_correo: str = "",
) -> tuple[str, str, str, List[str]]:
    """
    Genera (asunto, cuerpo_html, cuerpo_texto, folios) con:
      - Asunto:
          * 1 doc: '{Tipo} {folios[0]} - {cliente} | Básculas PESA'
          * Lote:  '{Tipo} {folios[0]} a {folios[-1]} - {cliente} | Básculas PESA'
      - Tabla HTML dinámica (#, ID [solo folio], Marca, Modelo, ID / Equipo, y CCA/DVE solo si existen;
        celdas vacías '' sin guiones '-' ni '—').
      - Excluye estrictamente cualquier orden con estatus/estado CANCELADA.
    """
    import html as _html

    ordenes_activas_in = [o for o in (ordenes_lote or []) if o and not _es_cancelada_orden(o)]
    filas_raw = [_extraer_campos_tabla_correo(o) for o in ordenes_activas_in]
    filas_por_folio: Dict[str, Dict[str, str]] = {}
    filas_sin_folio: List[Dict[str, str]] = []
    for f in filas_raw:
        if not f["folio"] and not f["codigo"]:
            continue
        fk = f["folio"].upper() if f["folio"] else ""
        if not fk:
            filas_sin_folio.append(f)
        elif fk not in filas_por_folio or len(f["codigo"]) > len(filas_por_folio[fk]["codigo"]):
            filas_por_folio[fk] = f

    filas_ordenadas = sorted(filas_por_folio.values(), key=lambda d: _clave_orden_folio(d.get("folio") or "")) + filas_sin_folio
    folios = [f["folio"] for f in filas_ordenadas if f["folio"]]

    cliente_limpio = re.sub(r"[\r\n]+", " ", str(cliente or "Cliente")).strip() or "Cliente"
    cliente_esc = _html.escape(cliente_limpio)
    n = len(filas_ordenadas)
    tipo_titulo = _nombre_tipo_documento_correo(folios)

    if len(folios) == 1:
        asunto = f"{tipo_titulo} {folios[0]} - {cliente_limpio} | Básculas PESA"
    elif len(folios) >= 2:
        asunto = f"{tipo_titulo} {folios[0]} a {folios[-1]} - {cliente_limpio} | Básculas PESA"
    else:
        asunto = f"{tipo_titulo} - {cliente_limpio} | Básculas PESA"

    tiene_cca = any(bool(f["cca"]) for f in filas_ordenadas)
    tiene_dve = any(bool(f["dve"]) for f in filas_ordenadas)

    if n > 1 or es_lote:
        txt_ordenes = "documento" if n == 1 else "documentos"
        intro_html = (
            f"Hacemos entrega de los reportes digitales correspondientes al "
            f"<strong>Lote de Servicios ({n} {txt_ordenes})</strong>:"
        )
        cierre_html = (
            "Adjunto a este correo encontrará cada uno de los certificados y reportes "
            "en formato PDF con sus respectivas firmas digitales."
        )
    else:
        intro_html = "Hacemos entrega del reporte digital correspondiente al servicio realizado:"
        cierre_html = (
            "Adjunto a este correo encontrará el certificado y reporte en formato PDF "
            "con sus respectivas firmas digitales."
        )

    th_style = (
        "border: 1px solid #E5E5EA; padding: 10px 12px; background-color: #F5F5F7; "
        "color: #1D1D1F; font-weight: 700; font-size: 12px; text-align: left;"
    )
    td_base = "border: 1px solid #E5E5EA; padding: 9px 12px; font-size: 13px; color: #1D1D1F; vertical-align: middle;"

    headers_html = [
        f'<th style="{th_style} text-align: center; width: 38px;">#</th>',
        f'<th style="{th_style}">ID</th>',
        f'<th style="{th_style}">Marca</th>',
        f'<th style="{th_style}">Modelo</th>',
        f'<th style="{th_style}">ID / Equipo</th>',
    ]
    if tiene_cca:
        headers_html.append(f'<th style="{th_style}">CCA</th>')
    if tiene_dve:
        headers_html.append(f'<th style="{th_style}">DVE</th>')
    thead_cols_str = "\n                                            ".join(headers_html)

    tr_html_list: List[str] = []
    lineas_txt_list: List[str] = []
    for idx, f in enumerate(filas_ordenadas, start=1):
        bg = "#FFFFFF" if idx % 2 == 1 else "#F5F5F7"
        folio_esc = _html.escape(f["folio"]) if f["folio"] else ""
        marca_esc = _html.escape(f["marca"]) if f["marca"] else ""
        modelo_esc = _html.escape(f["modelo"]) if f["modelo"] else ""
        id_esc = _html.escape(f["id_indicador"]) if f["id_indicador"] else ""

        celdas_fila = [
            f'<td style="{td_base} text-align: center; font-weight: 600; color: #6E6E73; width: 38px;">{idx}</td>',
            f'<td style="{td_base} font-weight: 700; color: #C8102E; white-space: nowrap;">{folio_esc}</td>',
            f'<td style="{td_base}">{marca_esc}</td>',
            f'<td style="{td_base}">{modelo_esc}</td>',
            f'<td style="{td_base}">{id_esc}</td>',
        ]
        if tiene_cca:
            if f["cca"]:
                cca_cell = f'<span style="color: #1D1D1F; font-weight: 600; font-size: 12px;">{_html.escape(f["cca"])}</span>'
            else:
                cca_cell = ""
            celdas_fila.append(f'<td style="{td_base}">{cca_cell}</td>')

        if tiene_dve:
            if f["dve"]:
                dve_cell = f'<span style="color: #1D1D1F; font-weight: 600; font-size: 12px;">{_html.escape(f["dve"])}</span>'
            else:
                dve_cell = ""
            celdas_fila.append(f'<td style="{td_base}">{dve_cell}</td>')

        tr_html_list.append(f'<tr style="background-color: {bg};">' + "".join(celdas_fila) + "</tr>")

        partes_txt = [f"{idx}. {f['folio']}"]
        if f["marca"]:
            partes_txt.append(f"Marca: {f['marca']}")
        if f["modelo"]:
            partes_txt.append(f"Modelo: {f['modelo']}")
        if f["id_indicador"]:
            partes_txt.append(f"ID / Equipo: {f['id_indicador']}")
        if tiene_cca and f["cca"]:
            partes_txt.append(f"CCA: {f['cca']}")
        if tiene_dve and f["dve"]:
            partes_txt.append(f"DVE: {f['dve']}")
        lineas_txt_list.append(" | ".join(partes_txt))

    filas_tabla_html = "\n                                        ".join(tr_html_list)
    lineas_txt = "\n".join(lineas_txt_list)

    aviso_sin_correo_txt = ""
    aviso_sin_correo_html = ""
    if solo_recepcion:
        motivo_limpio = re.sub(r"[\r\n]+", " ", str(motivo_sin_correo or "").strip()) or "El cliente no proporcionó correo en planta"
        aviso_sin_correo_txt = (
            f"\nNOTA INTERNA RECEPCIÓN PESA: El cliente no proporcionó correo electrónico en sitio.\n"
            f"Motivo reportado por el técnico: {motivo_limpio}\n"
        )
        aviso_sin_correo_html = (
            f'<div style="margin: 0 0 16px 0; padding: 12px 14px; background-color: #F5F5F7; '
            f'border: 1px solid #E5E5EA; border-left: 3px solid #C8102E; border-radius: 8px; '
            f'font-size: 13px; color: #1D1D1F;">'
            f'<strong>Respaldo interno (Solo recepción):</strong> El cliente no proporcionó correo electrónico al firmar.<br>'
            f'<span style="color: #6E6E73;">Motivo capturado en campo: {_html.escape(motivo_limpio)}</span>'
            f'</div>'
        )

    cuerpo_texto = f"""Estimado cliente ({cliente_limpio}):
{aviso_sin_correo_txt}
Hacemos entrega de los reportes digitales correspondientes ({n} {'documento' if n == 1 else 'documentos'}):

{lineas_txt}

Los documentos se encuentran certificados con sus respectivas firmas digitales.

Atentamente,
Básculas PESA
recepcion@basculaspesa.com.mx
"""

    cuerpo_html = f"""
                <html>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, Helvetica, sans-serif; color: #1D1D1F; line-height: 1.55; margin: 0; padding: 16px; background-color: #F5F5F7;">
                    <div style="max-width: 880px; margin: 0 auto; background-color: #FFFFFF; border-radius: 10px; overflow: hidden; border: 1px solid #E5E5EA;">
                        <div style="background-color: #C8102E; padding: 20px 24px; text-align: left;">
                            <h1 style="color: #FFFFFF; margin: 0; font-size: 22px; font-weight: 700; letter-spacing: 0.2px;">Básculas PESA</h1>
                        </div>
                        <div style="padding: 24px; background-color: #FFFFFF;">
                            {aviso_sin_correo_html}
                            <p style="margin-top: 0; font-size: 14.5px; color: #1D1D1F;">Estimado cliente <strong>{cliente_esc}</strong>,</p>
                            <p style="font-size: 14px; color: #6E6E73;">{intro_html}</p>
                            <div style="overflow-x: auto; margin: 18px 0;">
                                <table style="border-collapse: collapse; width: 100%; border: 1px solid #E5E5EA;">
                                    <thead>
                                        <tr>
                                            {thead_cols_str}
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {filas_tabla_html}
                                    </tbody>
                                </table>
                            </div>
                            <p style="font-size: 14px; color: #6E6E73;">{cierre_html}</p>
                            <hr style="border: none; border-top: 1px solid #E5E5EA; margin: 24px 0;">
                            <p style="font-size: 12px; color: #6E6E73; margin: 0;">
                                Este es un correo automático emitido por el sistema institucional de Básculas PESA.<br>
                                Para cualquier aclaración o seguimiento, favor de responder con copia a
                                <a href="mailto:recepcion@basculaspesa.com.mx" style="color: #C8102E; text-decoration: none; font-weight: 600;">recepcion@basculaspesa.com.mx</a>.
                            </p>
                        </div>
                    </div>
                </body>
                </html>
                """
    return asunto, cuerpo_html, cuerpo_texto, folios


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
      1. FUENTE DE VERDAD: pdf_b64 / pdf_base64 persistido en PostgreSQL (siempre
         sobrescrito al finalizar o rehacer una orden).
      2. Respaldo: archivo en disco con LastWriteTime más reciente si la BD no tiene blob.
    Evita adjuntar una versión previa en caché de disco tras Rehacer/re-firmar.
    """
    content_pdf = None
    b64 = None
    for bkey in ("pdf_b64", "pdf_base64"):
        try:
            if r[bkey]:
                b64 = r[bkey]
                break
        except Exception:
            pass
    if b64:
        try:
            decoded = base64.b64decode(str(b64).strip())
            if decoded and len(decoded) > 500:
                content_pdf = decoded
        except Exception:
            content_pdf = None
    if not content_pdf:
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
                logger.info("[EMAIL] PDF disco (respaldo) de %s: %s (de %d candidato(s))", folio, os.path.basename(elegido), len(candidatos))
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


_TOKENS_CABECERA_PDF = {
    "TIPO", "MARCA", "MODELO", "SERIE", "ALCANCE", "CAPACIDAD", "DIVISION", "DIVISIÓN",
    "PUNTOS", "UBICACION", "UBICACIÓN", "FUNCIONAMIENTO", "NUMERO", "NÚMERO", "FOLIO",
    "HOLO", "HOLO.", "PRUEBAS", "N/A", "NA", "NONE", "NULL", "--", "-",
}


def _extraer_texto_primera_pagina_pdf(pdf_bytes: Optional[bytes]) -> str:
    """Obtiene el texto plano de la primera página del PDF (solo lectura en memoria)."""
    if not pdf_bytes or len(pdf_bytes) < 100:
        return ""
    try:
        import fitz
        doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        if len(doc) > 0:
            txt = doc[0].get_text() or ""
            if txt.strip():
                return txt
    except Exception:
        pass
    try:
        import io
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(pdf_bytes))
        if reader.pages:
            txt = reader.pages[0].extract_text() or ""
            if txt.strip():
                return txt
    except Exception:
        pass
    return ""


def extraer_metadatos_equipo_de_pdf_bytes(pdf_bytes: Optional[bytes]) -> Dict[str, str]:
    """
    Extrae (marca, modelo, id_indicador, numero_cca, numero_dve) directamente
    del encabezado del PDF firmado (OS, OSOB, OSOCC, RE, LP, LV) en memoria.
    """
    txt = _extraer_texto_primera_pagina_pdf(pdf_bytes)
    if not txt:
        return {}
    txt_norm = re.sub(r"\s+", " ", txt).strip()
    out: Dict[str, str] = {}

    def _limpiar_captura(raw: str, es_reg: bool = False) -> str:
        val = _limpiar_val_correo(raw, es_regulatorio=es_reg)
        if not val or val.upper() in _TOKENS_CABECERA_PDF:
            return ""
        return val

    m_marca = re.search(
        r"(?:MARCA\s+INDICADOR|MARCA)\s*:\s*(.*?)(?=\s*(?:MODELO(?:\s+INDICADOR)?\s*:|(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE(?:\s*/\s*N/S)?\s*:|N/S\s*:|ID\s+(?:INDICADOR|INTERNO|EQUIPO)|CAPACIDAD|ALCANCE|$))",
        txt_norm,
        re.IGNORECASE,
    )
    if m_marca:
        v = _limpiar_captura(m_marca.group(1))
        if v:
            out["marca"] = v

    m_modelo = re.search(
        r"(?:MODELO\s+INDICADOR|MODELO)\s*:\s*(.*?)(?=\s*(?:(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE(?:\s*/\s*N/S)?\s*:|N/S\s*:|ID\s+(?:INDICADOR|INTERNO|EQUIPO)|CAPACIDAD|ALCANCE|DIVISI[ÓO]N|CLASE|$))",
        txt_norm,
        re.IGNORECASE,
    )
    if m_modelo:
        v = _limpiar_captura(m_modelo.group(1))
        if v:
            out["modelo"] = v

    m_id = re.search(
        r"ID\s*(?:INTERNO\s*/\s*TAG|INDICADOR\s*/\s*EQUIPO|INDICADOR|EQUIPO)\s*:\s*(.*?)(?=\s*(?:TIPO\s+DE\s+INSTRUMENTO\s*:|FUNCIONAMIENTO\s*:|MARCA(?:\s+INDICADOR)?\s*:|MODELO(?:\s+INDICADOR)?\s*:|(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE|CAPACIDAD|ALCANCE|DIVISI[ÓO]N|UBICACI[ÓO]N|CELDAS\s+DE\s+CARGA|PRUEBAS|$))",
        txt_norm,
        re.IGNORECASE,
    )
    if m_id:
        v = _limpiar_captura(m_id.group(1))
        if v:
            out["id_indicador"] = v

    m_cca = re.search(
        r"(?:N[ÚU]MERO\s+CCA|FOLIO\s+CCA)\s*:\s*(.*?)(?=\s*(?:FOLIO\s+DVE\s*:|N[ÚU]MERO\s+DVE\s*:|HOLO\.?\s*ANTERIOR|TIPO\s+DE\s+INSTRUMENTO\s*:|PRUEBAS\s+METROL|INSTRUCCI[ÓO]N\s*:|INSPECCI[ÓO]N|OBSERVACIONES|$))",
        txt_norm,
        re.IGNORECASE,
    )
    if m_cca:
        raw_cca = re.sub(r"(?:^|\s+)[XJIA](?=\s+[XJIA]|\s*$)", "", m_cca.group(1).strip())
        raw_cca = re.sub(r"(?:\s+[XJIA])+\s*$", "", raw_cca).strip()
        if not re.match(r"^(?:[XJIA]\s*)+$", raw_cca):
            v = _limpiar_captura(raw_cca, es_reg=True)
            if v:
                out["numero_cca"] = v

    m_dve = re.search(
        r"(?:FOLIO\s+DVE|N[ÚU]MERO\s+DVE)\s*:\s*(.*?)(?=\s*(?:HOLO\.?\s*ANTERIOR\s*:|HOLO\.?\s*NUEVO\s*:|TIPO\s+DE\s+INSTRUMENTO\s*:|PRUEBAS\s+METROL|INSTRUCCI[ÓO]N\s*:|INSPECCI[ÓO]N|UBICACI[ÓO]N\s*:|OBSERVACIONES|$))",
        txt_norm,
        re.IGNORECASE,
    )
    if m_dve:
        v = _limpiar_captura(m_dve.group(1), es_reg=True)
        if v:
            out["numero_dve"] = v

    return out


def extraer_id_equipo_de_pdf_bytes(pdf_bytes: Optional[bytes]) -> str:
    """Extrae el ID del indicador/equipo directamente del contenido binario del PDF."""
    meta = extraer_metadatos_equipo_de_pdf_bytes(pdf_bytes)
    if meta.get("id_indicador"):
        return meta["id_indicador"]
    return ""


def _consolidar_orden_correo(orden_row: Dict[str, Any], content_pdf: Optional[bytes], folio_fallback: str = "") -> Dict[str, Any]:
    """
    Unifica los metadatos de una orden combinando el PDF firmado adjunto,
    las columnas de BD y datos_tecnicos_json para construir su etiqueta de correo.
    """
    base = dict(orden_row) if orden_row else {}
    dt = _extraer_dt_dict(base)
    meta_pdf = extraer_metadatos_equipo_de_pdf_bytes(content_pdf)

    def _pick(claves_db: tuple[str, ...], clave_pdf: str, es_reg: bool = False) -> str:
        # Prioridad 1: valor impreso en el certificado PDF adjunto (fuente de verdad del documento enviado)
        v_pdf = _limpiar_val_correo(meta_pdf.get(clave_pdf), es_regulatorio=es_reg)
        if v_pdf:
            return v_pdf
        # Prioridad 2: columnas directas en ordenes_servicio
        for k in claves_db:
            v_db = _limpiar_val_correo(base.get(k), es_regulatorio=es_reg)
            if v_db:
                return v_db
        # Prioridad 3: datos_tecnicos_json
        for k in claves_db:
            v_dt = _limpiar_val_correo(dt.get(k), es_regulatorio=es_reg)
            if v_dt:
                return v_dt
        return ""

    folio_real = _limpiar_val_correo(base.get("folio_os") or base.get("folio") or folio_fallback)
    cca_bd, dve_bd = extraer_cca_dve(base)
    cca_pdf, dve_pdf = extraer_cca_dve(meta_pdf)
    return {
        "folio": folio_real,
        "folio_os": folio_real,
        "marca": _pick(("marca", "equipo_marca", "indicador_marca"), "marca"),
        "modelo": _pick(("modelo", "equipo_modelo", "indicador_modelo"), "modelo"),
        "id_indicador": _pick(("id_indicador", "id_equipo", "indicador_id", "no_identificacion", "id_interno", "tag"), "id_indicador"),
        "numero_cca": cca_pdf or cca_bd,
        "numero_dve": dve_pdf or dve_bd,
        "datos_tecnicos_json": dt,
    }


def construir_nombre_pdf(folio: str, cliente: str = "", id_equipo: str = "", servicio: str = "") -> str:
    """Construye la nomenclatura formal obligatoria: {FOLIO}-{EMPRESA}-{ID}-{SERVICIO}.pdf"""
    f_limpio = limpiar_texto(folio)
    c_limpio = sanear_nombre_cliente(cliente)
    if not c_limpio or c_limpio.lower() in ["cliente", "none", "null", "empresa"]:
        c_limpio = "Pilgrims Pride" if ("pilgrim" in str(cliente).lower() or "696" in folio or "706" in folio) else "Empresa"

    id_limpio = limpiar_texto(id_equipo)
    if id_limpio.upper() in ("S-ID", "SID", "SIN ID"):
        id_limpio = ""
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
    cc_parts = [c.strip() for c in (cc or "").split(",") if c.strip()]
    if "recepcion@basculaspesa.com.mx" not in [c.lower() for c in cc_parts]:
        cc_parts.append("recepcion@basculaspesa.com.mx")
    cc = ", ".join(cc_parts)

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

    recipientes = [d.strip() for d in re.split(r"[,;]+", str(destinatario or "")) if d.strip() and "@" in d]
    if not recipientes and destinatario and "@" in str(destinatario):
        recipientes = [str(destinatario).strip()]
    if cc:
        for c in re.split(r"[,;]+", cc):
            c_clean = c.strip()
            if c_clean and "@" in c_clean and c_clean.lower() not in [r.lower() for r in recipientes]:
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


async def enviar_email_orden(
    db=None,
    folio_o_id: Union[str, int] = "",
    correo_override: Optional[str] = None,
    forzar: bool = False,
    folios_lista: Optional[List[str]] = None,
    auto: bool = False,
    sin_correo_cliente: bool = False,
    motivo_sin_correo: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Envía por correo el PDF de una orden (o lote de 1 hasta N documentos terminados).
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
        await _ensure_email_columns(conn)
        str_id = str(folio_o_id).strip()
        row = await conn.fetchrow(
            """
            SELECT os.id, os.folio_os, os.id_lote, os.correo_cliente, os.correo_destino,
                   COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS email_enviado,
                   os.fecha_envio_email,
                   os.pdf_path, COALESCE(NULLIF(os.pdf_b64, ''), NULLIF(os.pdf_base64, '')) AS pdf_b64, os.tipo_servicio,
                   os.marca, os.modelo, os.id_equipo, os.indicador_id,
                   os.numero_cca, os.numero_dve,
                   os.fecha, os.dictamen, os.datos_tecnicos_json,
                   COALESCE(os.estatus, '') AS estatus, COALESCE(os.estado, '') AS estado,
                   COALESCE(os.sin_correo_cliente, FALSE) AS sin_correo_cliente,
                   COALESCE(os.motivo_sin_correo, '') AS motivo_sin_correo,
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

        # Si pertenece a un Lote o se pasó lista explícita de folios (1..N), agrupar órdenes del lote
        es_agrupacion_lote = False
        lote_rows = []
        if folios_lista and len(folios_lista) >= 1:
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente,
                       COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS email_enviado,
                       os.fecha_envio_email,
                       os.pdf_path, COALESCE(NULLIF(os.pdf_b64, ''), NULLIF(os.pdf_base64, '')) AS pdf_b64, os.tipo_servicio,
                       os.marca, os.modelo, os.id_equipo, os.indicador_id,
                       os.numero_cca, os.numero_dve,
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
            lote_rows_dict = {}
            for r in lote_rows:
                fk = str(r["folio_os"] or "").strip()
                if fk and fk not in lote_rows_dict:
                    lote_rows_dict[fk] = r
            lote_rows = sorted(
                [rx for rx in lote_rows_dict.values() if not _es_cancelada_orden(rx)],
                key=lambda rx: _clave_orden_folio(rx["folio_os"]),
            )
            if len(lote_rows) >= 1:
                es_agrupacion_lote = True
        elif id_lote and str(id_lote).strip():
            lote_rows = await conn.fetch(
                """
                SELECT os.id, os.folio_os, os.correo_cliente, os.correo_destino,
                       COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS email_enviado,
                       os.fecha_envio_email,
                       os.pdf_path, COALESCE(NULLIF(os.pdf_b64, ''), NULLIF(os.pdf_base64, '')) AS pdf_b64, os.tipo_servicio,
                       os.marca, os.modelo, os.id_equipo, os.indicador_id,
                       os.numero_cca, os.numero_dve,
                       os.fecha, os.dictamen, os.datos_tecnicos_json, os.has_pdf,
                       COALESCE(os.estatus, '') AS estatus, COALESCE(os.estado, '') AS estado,
                       COALESCE(os.sin_correo_cliente, FALSE) AS sin_correo_cliente,
                       COALESCE(os.motivo_sin_correo, '') AS motivo_sin_correo,
                       COALESCE(cl.razon_social, os.cliente, '') AS cliente,
                       COALESCE(ts.nombre, os.tipo_servicio, '') AS srv_nombre
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                WHERE os.id_lote = $1
                  AND UPPER(TRIM(COALESCE(os.estatus, ''))) NOT IN ('CANCELADA', 'CANCELADO', 'ELIMINADA', 'ELIMINADO')
                  AND UPPER(TRIM(COALESCE(os.estado, ''))) NOT IN ('CANCELADA', 'CANCELADO', 'ELIMINADA', 'ELIMINADO')
                ORDER BY os.folio_os ASC
                """,
                id_lote,
            )
            lote_rows_dict = {}
            for r in lote_rows:
                fk = str(r["folio_os"] or "").strip()
                if fk and fk not in lote_rows_dict and not _es_cancelada_orden(r):
                    lote_rows_dict[fk] = r
            lote_rows = sorted(lote_rows_dict.values(), key=lambda rx: _clave_orden_folio(rx["folio_os"]))
            if len(lote_rows) > 1 or (len(lote_rows) == 1 and forzar):
                es_agrupacion_lote = True

        # ── Control de Idempotencia contra envíos duplicados automáticos ───────
        # Si forzar=True (acción explícita "Reenviar Lote" / "Reenviar Correo"), solo
        # proteger contra reintentos HTTP idénticos en <= 5s; en modo auto usar 120s.
        ventana_idemp = 5 if forzar else 120
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
                if len(tiempos) == len(lote_rows) and all(t <= ventana_idemp for t in tiempos):
                    lote_ya_enviado = True

            if lote_ya_enviado:
                folios_desc = [str(r["folio_os"]) for r in lote_rows]
                logger.info(
                    "[EMAIL IDEMPOTENCIA] Lote %s ya fue enviado hace <= %ds. Retornando status=already_sent.",
                    id_lote or folios_desc,
                    ventana_idemp,
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
                    if diff_seg <= ventana_idemp:
                        logger.info(
                            "[EMAIL IDEMPOTENCIA] Orden %s ya fue enviada hace %.1fs (<= %ds). Retornando status=already_sent.",
                            folio_str,
                            diff_seg,
                            ventana_idemp,
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
                pdf_bytes = _cargar_pdf_bytes(r, f_i) if (_es_finalizada(r) or forzar) else None
                if not pdf_bytes and _es_finalizada(r):
                    pdf_bytes = _cargar_pdf_bytes(r, f_i)
                if pdf_bytes and (_es_finalizada(r) or r.get("has_pdf")):
                    adjuntos_procesados.add(f_i)
                    ordenes_validas.append((r, pdf_bytes))
                elif pdf_bytes and folios_lista and f_i in folios_lista:
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

            # Destinatario para el lote (nunca 'Cliente' ni 'Sin registrar')
            invalidos_dest = {"", "cliente", "sin registrar", "destinatario registrado", "none", "null"}
            override_raw = str(correo_override or "").strip()
            es_solo_recepcion_lote = bool(sin_correo_cliente) or override_raw.upper().startswith("PENDIENTE")
            motivo_sin_lote = str(motivo_sin_correo or "").strip()

            destinatario = "" if es_solo_recepcion_lote else override_raw
            if destinatario.lower() in invalidos_dest or "@" not in destinatario:
                destinatario = ""
            if not destinatario and not es_solo_recepcion_lote:
                for r in lote_rows:
                    cand = str(r.get("correo_destino") or r.get("correo_cliente") or "").strip()
                    if cand.upper().startswith("PENDIENTE") or bool(r.get("sin_correo_cliente")):
                        es_solo_recepcion_lote = True
                        if not motivo_sin_lote and r.get("motivo_sin_correo"):
                            motivo_sin_lote = str(r.get("motivo_sin_correo") or "").strip()
                    elif cand and cand.lower() not in invalidos_dest and "@" in cand:
                        destinatario = cand
                        es_solo_recepcion_lote = False
                        break
            if not destinatario and not es_solo_recepcion_lote and lote_rows:
                try:
                    r_cli = await conn.fetchrow(
                        """
                        SELECT COALESCE(
                            NULLIF(TRIM(s.email), ''),
                            NULLIF(TRIM(c.email), '')
                        ) AS correo_cat
                        FROM ordenes_servicio os
                        LEFT JOIN cliente_sucursales s ON os.sucursal_id = s.id
                        LEFT JOIN cat_clientes c ON os.id_cliente = c.id
                        WHERE os.folio_os = $1
                        LIMIT 1
                        """,
                        str(lote_rows[0]["folio_os"]),
                    )
                    if r_cli and r_cli["correo_cat"] and "@" in str(r_cli["correo_cat"]):
                        destinatario = str(r_cli["correo_cat"]).strip()
                except Exception:
                    pass

            if es_solo_recepcion_lote and not destinatario:
                destinatario = "recepcion@basculaspesa.com.mx"

            if not destinatario:
                logger.warning("[EMAIL] No se encontró correo de cliente para el lote %s", id_lote)
                return {"ok": False, "motivo": "No se ha capturado el correo del cliente para este lote"}

            adjuntos = []
            folios_lote = []
            ordenes_lote_correo: List[Dict[str, Any]] = []
            empresa_lote = ordenes_validas[0][0]["cliente"] or lote_rows[0]["cliente"] or "Cliente"
            folios_agregados = set()

            for r, content_pdf in ordenes_validas:
                f_i = str(r["folio_os"] or "").strip()
                if not f_i or f_i in folios_agregados:
                    continue
                folios_agregados.add(f_i)
                folios_lote.append(f_i)

                try:
                    row_hija = await conn.fetchrow(
                        """
                        SELECT os.id, os.folio_os, os.id_lote, os.correo_cliente, os.email_enviado,
                               os.pdf_path, os.pdf_b64, os.tipo_servicio,
                               os.marca, os.modelo, os.id_equipo, os.indicador_id,
                               os.numero_cca, os.numero_dve,
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

                orden_consolidada = _consolidar_orden_correo(orden_hija, content_pdf, folio_fallback=f_i)
                ordenes_lote_correo.append(orden_consolidada)

                # Auto-sanar columnas vacías en BD con los datos reales extraídos del PDF firmado
                try:
                    await conn.execute(
                        """
                        UPDATE ordenes_servicio SET
                            marca      = COALESCE(NULLIF(marca, ''), NULLIF($1, '')),
                            modelo     = COALESCE(NULLIF(modelo, ''), NULLIF($2, '')),
                            id_equipo  = COALESCE(NULLIF(id_equipo, ''), NULLIF($3, '')),
                            numero_cca = COALESCE(NULLIF(numero_cca, ''), NULLIF($4, '')),
                            numero_dve = COALESCE(NULLIF(numero_dve, ''), NULLIF($5, ''))
                        WHERE folio_os = $6
                        """,
                        orden_consolidada["marca"],
                        orden_consolidada["modelo"],
                        orden_consolidada["id_indicador"],
                        orden_consolidada["numero_cca"],
                        orden_consolidada["numero_dve"],
                        f_i,
                    )
                except Exception:
                    pass

                id_equipo_real = orden_consolidada["id_indicador"] or ""
                servicio_real = str(orden_hija.get("srv_nombre") or orden_hija.get("tipo_servicio") or "Servicio").strip()
                empresa_real = sanear_nombre_cliente(orden_hija.get("cliente") or empresa_lote)

                nombre_adj = construir_nombre_pdf(
                    folio=f_i,
                    cliente=empresa_real,
                    id_equipo=id_equipo_real,
                    servicio=servicio_real,
                )
                adjuntos.append((nombre_adj, content_pdf))

            folios_lote = list(dict.fromkeys([f.strip() for f in folios_lote if f]))
            n = len(adjuntos)
            asunto, cuerpo_html, cuerpo_texto, etiquetas = construir_asunto_y_cuerpo_correo(
                ordenes_lote_correo,
                empresa_lote,
                es_lote=True,
                solo_recepcion=es_solo_recepcion_lote,
                motivo_sin_correo=motivo_sin_lote,
            )

            cc_efectivo = "" if es_solo_recepcion_lote else normalizar_cc_correo(settings.EMAIL_CC)
            destino_bd = "PENDIENTE (Solo recepción)" if es_solo_recepcion_lote else destinatario
            cc_bd = "recepcion@basculaspesa.com.mx" if es_solo_recepcion_lote else cc_efectivo
            loop = asyncio.get_running_loop()
            ok = await loop.run_in_executor(
                None,
                _enviar_smtp_sync,
                destinatario,
                cc_efectivo,
                asunto,
                cuerpo_html,
                cuerpo_texto,
                adjuntos,
            )

            if ok:
                now_mx = datetime.now(_obtener_tz_mexico())
                fecha_mx_str = now_mx.strftime("%d/%m/%Y %H:%M")
                await conn.execute(
                    """
                    UPDATE ordenes_servicio
                    SET email_enviado      = TRUE,
                        correo_enviado     = TRUE,
                        correo_cliente     = $2,
                        correo_destino     = $2,
                        correo_cc          = $3,
                        fecha_envio_email  = $4,
                        fecha_envio_correo = $4,
                        sin_correo_cliente = $5,
                        motivo_sin_correo  = COALESCE(NULLIF($6, ''), motivo_sin_correo),
                        updated_at         = NOW()
                    WHERE folio_os = ANY($1::text[])
                    """,
                    folios_lote,
                    destino_bd,
                    cc_bd,
                    now_mx,
                    es_solo_recepcion_lote,
                    motivo_sin_lote,
                )
                if not es_solo_recepcion_lote and "@" in destino_bd:
                    try:
                        await conn.execute(
                            """
                            UPDATE cat_clientes cl
                            SET email = $1
                            FROM ordenes_servicio os
                            WHERE os.folio_os = ANY($2::text[])
                              AND os.id_cliente = cl.id
                              AND COALESCE(NULLIF(TRIM(cl.email), ''), '') = ''
                            """,
                            destino_bd,
                            folios_lote,
                        )
                    except Exception:
                        pass
                return {
                    "ok": True,
                    "lote": True,
                    "count": n,
                    "folios": folios_lote,
                    "etiquetas": etiquetas,
                    "omitidas": no_listas,
                    "destinatario": destino_bd,
                    "correo_enviado": True,
                    "correo_destino": destino_bd,
                    "correo_cc": cc_bd,
                    "sin_correo_cliente": es_solo_recepcion_lote,
                    "fecha_envio_correo": fecha_mx_str,
                    "asunto": asunto,
                }
            return {"ok": False, "motivo": "Fallo el envío por SMTP"}

        # ── Orden individual ──────────────────────────────────────────────────
        if _es_cancelada_orden(row):
            return {"ok": False, "motivo": f"La orden {folio} está marcada como CANCELADA y no debe enviarse"}

        invalidos_dest = {"", "cliente", "sin registrar", "destinatario registrado", "none", "null"}
        override_ind = str(correo_override or "").strip()
        es_solo_recepcion_ind = (
            bool(sin_correo_cliente)
            or override_ind.upper().startswith("PENDIENTE")
            or (not override_ind and (bool(row.get("sin_correo_cliente")) or str(row.get("correo_destino") or "").strip().upper().startswith("PENDIENTE")))
        )
        motivo_sin_ind = str(motivo_sin_correo or row.get("motivo_sin_correo") or "").strip()

        destinatario = "" if es_solo_recepcion_ind else override_ind
        if destinatario.lower() in invalidos_dest or "@" not in destinatario:
            cand_row = str(row.get("correo_destino") or row.get("correo_cliente") or "").strip()
            destinatario = cand_row if (not es_solo_recepcion_ind and cand_row.lower() not in invalidos_dest and "@" in cand_row) else ""
        if not destinatario and not es_solo_recepcion_ind:
            try:
                r_cli = await conn.fetchrow(
                    """
                    SELECT COALESCE(NULLIF(TRIM(s.email), ''), NULLIF(TRIM(c.email), '')) AS correo_cat
                    FROM ordenes_servicio os
                    LEFT JOIN cliente_sucursales s ON os.sucursal_id = s.id
                    LEFT JOIN cat_clientes c ON os.id_cliente = c.id
                    WHERE os.id = $1
                    LIMIT 1
                    """,
                    actual_id,
                )
                if r_cli and r_cli["correo_cat"] and "@" in str(r_cli["correo_cat"]):
                    destinatario = str(r_cli["correo_cat"]).strip()
            except Exception:
                pass
        if es_solo_recepcion_ind and not destinatario:
            destinatario = "recepcion@basculaspesa.com.mx"
        if not destinatario:
            logger.info("[EMAIL] Orden %s no tiene correo_cliente definido. Envío omitido.", folio)
            return {"ok": False, "motivo": "Sin correo de cliente especificado"}

        # Extraer PDF VIGENTE (archivo más reciente en disco → pdf_b64)
        content_pdf = _cargar_pdf_bytes(row, folio)

        if not content_pdf:
            return {"ok": False, "motivo": f"No se encontró el PDF para la orden {folio}"}

        orden_consolidada = _consolidar_orden_correo(dict(row), content_pdf, folio_fallback=str(folio or ""))
        try:
            await conn.execute(
                """
                UPDATE ordenes_servicio SET
                    marca      = COALESCE(NULLIF(marca, ''), NULLIF($1, '')),
                    modelo     = COALESCE(NULLIF(modelo, ''), NULLIF($2, '')),
                    id_equipo  = COALESCE(NULLIF(id_equipo, ''), NULLIF($3, '')),
                    numero_cca = COALESCE(NULLIF(numero_cca, ''), NULLIF($4, '')),
                    numero_dve = COALESCE(NULLIF(numero_dve, ''), NULLIF($5, ''))
                WHERE id = $6
                """,
                orden_consolidada["marca"],
                orden_consolidada["modelo"],
                orden_consolidada["id_indicador"],
                orden_consolidada["numero_cca"],
                orden_consolidada["numero_dve"],
                actual_id,
            )
        except Exception:
            pass

        id_equipo_real = orden_consolidada["id_indicador"] or ""
        cliente_mostrar = str(row["cliente"] or "Cliente").strip() or "Cliente"
        empresa = sanear_nombre_cliente(cliente_mostrar)
        folio_up = str(folio or "").strip().upper()
        if folio_up.startswith("OSOCC-"):
            servicio_default = "Diagnóstico y Revisión de Celda de Carga"
        elif folio_up.startswith("OSOB-"):
            servicio_default = "Inspección y Revisión de Básculas"
        else:
            servicio_default = "Calibración"
        servicio_real = str(row["srv_nombre"] or row["tipo_servicio"] or servicio_default).strip()

        nombre_adj = construir_nombre_pdf(
            folio=folio,
            cliente=empresa,
            id_equipo=id_equipo_real,
            servicio=servicio_real,
        )

        asunto, cuerpo_html, cuerpo_texto, etiquetas = construir_asunto_y_cuerpo_correo(
            [orden_consolidada],
            cliente_mostrar,
            es_lote=False,
            solo_recepcion=es_solo_recepcion_ind,
            motivo_sin_correo=motivo_sin_ind,
        )

        cc_efectivo = "" if es_solo_recepcion_ind else normalizar_cc_correo(settings.EMAIL_CC)
        destino_ind_bd = "PENDIENTE (Solo recepción)" if es_solo_recepcion_ind else destinatario
        cc_ind_bd = "recepcion@basculaspesa.com.mx" if es_solo_recepcion_ind else cc_efectivo
        loop = asyncio.get_running_loop()
        ok = await loop.run_in_executor(
            None,
            _enviar_smtp_sync,
            destinatario,
            cc_efectivo,
            asunto,
            cuerpo_html,
            cuerpo_texto,
            [(nombre_adj, content_pdf)],
        )

        if ok:
            now_mx = datetime.now(_obtener_tz_mexico())
            fecha_mx_str = now_mx.strftime("%d/%m/%Y %H:%M")
            await conn.execute(
                """
                UPDATE ordenes_servicio
                SET email_enviado      = TRUE,
                    correo_enviado     = TRUE,
                    correo_cliente     = $2,
                    correo_destino     = $2,
                    correo_cc          = $3,
                    fecha_envio_email  = $4,
                    fecha_envio_correo = $4,
                    sin_correo_cliente = $5,
                    motivo_sin_correo  = COALESCE(NULLIF($6, ''), motivo_sin_correo),
                    updated_at         = NOW()
                WHERE id = $1
                """,
                actual_id,
                destino_ind_bd,
                cc_ind_bd,
                now_mx,
                es_solo_recepcion_ind,
                motivo_sin_ind,
            )
            if not es_solo_recepcion_ind and "@" in destino_ind_bd:
                try:
                    await conn.execute(
                        """
                        UPDATE cat_clientes cl
                        SET email = $1
                        FROM ordenes_servicio os
                        WHERE os.id = $2
                          AND os.id_cliente = cl.id
                          AND COALESCE(NULLIF(TRIM(cl.email), ''), '') = ''
                        """,
                        destino_ind_bd,
                        actual_id,
                    )
                except Exception:
                    pass
            return {
                "ok": True,
                "folio": folio,
                "etiquetas": etiquetas,
                "destinatario": destino_ind_bd,
                "correo_enviado": True,
                "correo_destino": destino_ind_bd,
                "correo_cc": cc_ind_bd,
                "sin_correo_cliente": es_solo_recepcion_ind,
                "fecha_envio_correo": fecha_mx_str,
                "asunto": asunto,
            }

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
