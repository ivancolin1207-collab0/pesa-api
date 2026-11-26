"""
services/metrology.py — Utilidades metrológicas OIML R 76 / NOM-010-SCFI
Servicios PESA v2.5

Funciones compartidas entre captura_digital_dialog y batch_generator_widget:
    • decimals_from_d  — calcula decimales exactos desde la división mínima d
    • fmt              — formatea un valor numérico con la resolución de d
    • fmt_patron       — formatea el valor patrón sin ceros sobrantes
    • calc_emt         — calcula el Error Máximo Tolerado (EMT) según OIML R 76
"""
from __future__ import annotations
import math
import re


# ──────────────────────────────────────────────────────────────────────────────
# HELPERS DE CONVERSIÓN
# ──────────────────────────────────────────────────────────────────────────────

def parse_d(text: str) -> float | None:
    """
    Extrae el valor numérico de una cadena de texto de división mínima.

    Ejemplos:
        "0.001"     → 0.001
        "0.001 kg"  → 0.001
        "50 g"      → 0.05   (convierte g → kg automáticamente)
        "1 lb"      → None   (unidad desconocida)
    """
    if not text:
        return None
    text = text.strip()

    # Buscar número (entero o decimal)
    m = re.search(r'[\d]+(?:[.,][\d]+)?', text)
    if not m:
        return None

    valor_str = m.group(0).replace(',', '.')
    try:
        valor = float(valor_str)
    except ValueError:
        return None

    # Detectar unidad
    unidad = text[m.end():].strip().lower()
    if 'g' in unidad and 'k' not in unidad:
        valor = valor / 1000.0   # gramos → kilogramos
    elif 'lb' in unidad or 'lbf' in unidad:
        return None  # libras no soportadas aquí

    return valor if valor > 0 else None


def decimals_from_d(d: float) -> int:
    """
    Calcula el número de decimales necesarios para representar el valor de d.

    Regla: contar los decimales del número d.
        d = 1       → 0 decimales  (ej. 20, 21)
        d = 0.1     → 1 decimal    (ej. 5.1)
        d = 0.01    → 2 decimales  (ej. 5.01)
        d = 0.001   → 3 decimales  (ej. 5.001)
        d = 0.0001  → 4 decimales  (ej. 5.0001)
    """
    if d <= 0:
        return 4  # fallback seguro
    if d >= 1:
        return 0
    # Usar log10 para evitar errores de punto flotante
    return max(0, math.ceil(-math.log10(d)))



def formato_miles_espacio(valor) -> str:
    """
    Formatea un número con espacio como separador de miles para valores >= 1000.
    Separa únicamente la parte entera y conserva decimales y sufijos/unidades intactos.
    """
    if valor is None or str(valor).strip() == "":
        return ""
    val_str = str(valor).strip()
    m = re.match(r'^([-+]?[0-9,.]+)\s*(.*)$', val_str)
    if not m:
        return val_str
    num_part, sufijo = m.group(1), m.group(2)
    is_neg = num_part.startswith('-')

    if '.' in num_part:
        partes = num_part.split('.')
        entera = partes[0].replace(',', '').replace(' ', '')
        decimal = partes[1]
        try:
            ent_val = abs(int(entera))
            entera_fmt = f"{ent_val:,}".replace(',', ' ')
            if is_neg:
                entera_fmt = f"-{entera_fmt}"
            res = f"{entera_fmt}.{decimal}"
        except ValueError:
            res = num_part
    else:
        entera = num_part.replace(',', '').replace(' ', '')
        try:
            ent_val = abs(int(entera))
            entera_fmt = f"{ent_val:,}".replace(',', ' ')
            if is_neg and ent_val != 0:
                entera_fmt = f"-{entera_fmt}"
            res = entera_fmt
        except ValueError:
            res = num_part

    return f"{res} {sufijo}".strip() if sufijo else res


def formatear_division_minima(raw_div) -> str:
    """
    Normaliza el texto de división mínima eliminando ceros insignificantes a la derecha
    (ej. '0.020 kg' -> '0.02 kg', '0.100' -> '0.1', '5.00' -> '5') sin alterar la precisión numérica.
    """
    if raw_div is None:
        return ""
    s = str(raw_div).strip()
    if not s:
        return ""
    m = re.match(r'^([+-]?\d+(?:[.,]\d+)?)\s*(.*)$', s)
    if not m:
        return s
    num_str = m.group(1).replace(',', '.')
    unidad = m.group(2).strip()
    try:
        val = float(num_str)
    except ValueError:
        return s
    limpio = f"{val:.6f}".rstrip('0').rstrip('.')
    return f"{limpio} {unidad}".strip() if unidad else limpio


def _es_placeholder_regulatorio(val) -> bool:
    """Retorna True si el valor de CCA/DVE está vacío, es nulo o es un placeholder (ej. CCA.26., CCA.26.XXXXX)."""
    s = str(val or "").strip()
    if not s:
        return True
    low = s.lower()
    invalidos = {
        "", "-", "--", "none", "null", "n/a", "na", "s/n", "sn",
        "sin cca", "sin dve", "por definir", "pendiente",
        "cca.26.xxxx", "dve.26.xxxx", "cca.26.xxxxx", "dve.26.xxxxx",
    }
    if low in invalidos:
        return True
    if re.match(r"^(CCA|DVE)\.\d{2}\.?$", s, flags=re.IGNORECASE):
        return True
    if re.search(r"(?:^|[.\-\s])x{2,}(?:$|[.\-\s])", s, flags=re.IGNORECASE) or re.search(r"\.x+$", s, flags=re.IGNORECASE):
        return True
    return False


def limpiar_numero_regulatorio(val) -> str:
    """
    Limpia un número CCA o DVE descartando valores vacíos o prefijos incompletos
    como 'CCA.26.', 'DVE.26.' o máscaras 'CCA.26.XXXXX'.
    """
    if _es_placeholder_regulatorio(val):
        return ""
    return str(val or "").strip()


def extraer_cca_dve(orden: dict) -> tuple[str, str]:
    """
    Extractor universal de CCA y DVE desde todas las llaves posibles de BD y JSON anidados
    (numero_cca, num_cca, cca, no_cca, certificado_cca, folio_cca / numero_dve, num_dve, dve, no_dve,
    dictamen_dve, folio_dve, más datos_json, datos_tecnicos_json, payload_json, mediciones_json, etc.).
    """
    import json as _json

    if not isinstance(orden, dict):
        orden = dict(orden) if orden else {}

    extra: dict = {}
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
        raw = orden.get(jkey)
        if isinstance(raw, dict):
            extra.update(raw)
        elif isinstance(raw, str) and raw.strip().startswith("{"):
            try:
                parsed = _json.loads(raw)
                if isinstance(parsed, dict):
                    extra.update(parsed)
            except Exception:
                pass

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

    return cca, dve


def construir_etiqueta_instrumento(orden: dict) -> str:
    """
    Construye dinámicamente el identificador compuesto con los campos disponibles del instrumento:
      FOLIO - MARCA - MODELO - SERIE - ID - UBICACIÓN
    Omitiendo valores vacíos, null, 'sin id', 'sin modelo' o 'sin serie'.
    """
    if not isinstance(orden, dict):
        return ""
    folio = str(orden.get("folio") or orden.get("folio_os") or "").strip()
    invalidos = {
        "", "none", "null", "sin id", "sin modelo", "sin serie",
        "n/a", "na", "--", "s/n", "sn", "s/m", "s/i",
    }

    dt_map = {}
    dt = orden.get("datos_tecnicos_json")
    if isinstance(dt, dict):
        dt_map = dt
    elif isinstance(dt, str) and dt.strip().startswith("{"):
        try:
            import json as _json
            parsed = _json.loads(dt)
            if isinstance(parsed, dict):
                dt_map = parsed
        except Exception:
            dt_map = {}

    def _pick(*keys: str) -> str:
        for k in keys:
            v = orden.get(k)
            if (v is None or str(v).strip() == "") and dt_map:
                v = dt_map.get(k)
            val = str(v or "").strip()
            if val and val.lower() not in invalidos:
                return val
        return ""

    partes = [folio] if folio else []
    for group in (
        ("marca", "equipo_marca"),
        ("modelo", "equipo_modelo"),
        ("serie", "ns", "numero_serie", "equipo_ns"),
        ("id_indicador", "id_equipo", "equipo_id"),
        ("ubicacion", "equipo_ubicacion"),
    ):
        val = _pick(*group)
        if val:
            partes.append(val)
    return " - ".join(partes)


def _extraer_campos_tabla_correo(orden: dict) -> dict[str, str]:
    """
    Extrae y normaliza los campos individuales de un equipo para el asunto y la tabla HTML institucional:
      folio, marca, modelo, id_indicador, cca, dve y codigo_completo (FOLIO-MARCA-MODELO-ID-CCA-DVE).
    """
    import json as _json
    import re as _re

    if not isinstance(orden, dict):
        orden = dict(orden) if orden else {}

    invalidos = {
        "", "none", "null", "sin id", "sin modelo", "sin serie", "sin marca",
        "n/a", "na", "--", "-", "s-id", "s/id", "por definir", "sin ubicacion", "sin ubicación",
    }

    extra: dict = {}
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
        raw = orden.get(jkey)
        if isinstance(raw, dict):
            extra.update(raw)
        elif isinstance(raw, str) and raw.strip().startswith("{"):
            try:
                parsed = _json.loads(raw)
                if isinstance(parsed, dict):
                    extra.update(parsed)
            except Exception:
                pass

    def _clean(raw_v) -> str:
        if raw_v is None:
            return ""
        s = _re.sub(r"[\r\n\t]+", " ", str(raw_v)).strip()
        if not s or s.lower() in invalidos:
            return ""
        return s

    def _pick(*keys: str) -> str:
        for k in keys:
            v = _clean(orden.get(k))
            if v:
                return v
        for k in keys:
            v = _clean(extra.get(k))
            if v:
                return v
        return ""

    folio = _clean(orden.get("folio") or orden.get("folio_os") or extra.get("folio_os") or extra.get("folio"))
    marca = _pick("marca", "equipo_marca", "indicador_marca")
    modelo = _pick("modelo", "equipo_modelo", "indicador_modelo")
    id_ind = _pick("id_indicador", "id_equipo", "indicador_id", "no_identificacion", "id_interno", "tag")

    cca_raw, dve_raw = extraer_cca_dve(orden)
    cca_fmt = (cca_raw if cca_raw.upper().startswith("CCA") else f"CCA.{cca_raw}") if cca_raw else ""
    dve_fmt = (dve_raw if dve_raw.upper().startswith("DVE") else f"DVE.{dve_raw}") if dve_raw else ""

    partes = [p for p in (folio, marca, modelo, id_ind, cca_fmt, dve_fmt) if p]
    codigo = "-".join(partes)

    return {
        "folio": folio,
        "marca": marca,
        "modelo": modelo,
        "id_indicador": id_ind,
        "cca": cca_fmt,
        "dve": dve_fmt,
        "codigo": codigo,
    }


def formatear_linea_correo_orden(orden: dict) -> str:
    """
    Construye dinámicamente el identificador compuesto por equipo para el Asunto y tabla HTML:
      FOLIO-MARCA-MODELO-ID-CCA-DVE
    Omitiendo campos vacíos o placeholders.
    """
    return _extraer_campos_tabla_correo(orden)["codigo"]


def extraer_metadatos_equipo_de_pdf_bytes(pdf_bytes: bytes | None) -> dict[str, str]:
    """Extrae (marca, modelo, id_indicador, numero_cca, numero_dve) del PDF firmado (solo lectura)."""
    import io as _io
    import re as _re

    if not pdf_bytes or len(pdf_bytes) < 100:
        return {}
    txt = ""
    try:
        import fitz  # type: ignore
        doc = fitz.open(stream=pdf_bytes, filetype="pdf")
        if len(doc) > 0:
            txt = doc[0].get_text() or ""
    except Exception:
        pass
    if not txt.strip():
        try:
            from pypdf import PdfReader
            reader = PdfReader(_io.BytesIO(pdf_bytes))
            if reader.pages:
                txt = reader.pages[0].extract_text() or ""
        except Exception:
            pass
    if not txt.strip():
        return {}

    txt_norm = _re.sub(r"\s+", " ", txt).strip()
    tokens_hdr = {
        "TIPO", "MARCA", "MODELO", "SERIE", "ALCANCE", "CAPACIDAD", "DIVISION", "DIVISIÓN",
        "PUNTOS", "UBICACION", "UBICACIÓN", "FUNCIONAMIENTO", "NUMERO", "NÚMERO", "FOLIO",
        "HOLO", "HOLO.", "PRUEBAS", "N/A", "NA", "NONE", "NULL", "--", "-",
    }
    invalidos = {'', 'none', 'null', 'sin id', 'sin modelo', 'sin serie', 'sin marca', 'n/a', 'na', '--', '-'}

    def _limp(raw: str, es_reg: bool = False) -> str:
        val = _re.sub(r"[\r\n\t]+", " ", str(raw or "")).strip()
        if not val or val.lower() in invalidos or val.upper() in tokens_hdr:
            return ""
        if es_reg and _es_placeholder_regulatorio(val):
            return ""
        return val

    out: dict[str, str] = {}
    m_marca = _re.search(
        r"(?:MARCA\s+INDICADOR|MARCA)\s*:\s*(.*?)(?=\s*(?:MODELO(?:\s+INDICADOR)?\s*:|(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE(?:\s*/\s*N/S)?\s*:|N/S\s*:|ID\s+(?:INDICADOR|INTERNO|EQUIPO)|CAPACIDAD|ALCANCE|$))",
        txt_norm,
        _re.IGNORECASE,
    )
    if m_marca and _limp(m_marca.group(1)):
        out["marca"] = _limp(m_marca.group(1))

    m_modelo = _re.search(
        r"(?:MODELO\s+INDICADOR|MODELO)\s*:\s*(.*?)(?=\s*(?:(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE(?:\s*/\s*N/S)?\s*:|N/S\s*:|ID\s+(?:INDICADOR|INTERNO|EQUIPO)|CAPACIDAD|ALCANCE|DIVISI[ÓO]N|CLASE|$))",
        txt_norm,
        _re.IGNORECASE,
    )
    if m_modelo and _limp(m_modelo.group(1)):
        out["modelo"] = _limp(m_modelo.group(1))

    m_id = _re.search(
        r"ID\s*(?:INTERNO\s*/\s*TAG|INDICADOR\s*/\s*EQUIPO|INDICADOR|EQUIPO)\s*:\s*(.*?)(?=\s*(?:TIPO\s+DE\s+INSTRUMENTO\s*:|FUNCIONAMIENTO\s*:|MARCA(?:\s+INDICADOR)?\s*:|MODELO(?:\s+INDICADOR)?\s*:|(?:NO\.?\s*DE\s*|N[ÚU]MERO\s+DE\s*)?SERIE|CAPACIDAD|ALCANCE|DIVISI[ÓO]N|UBICACI[ÓO]N|CELDAS\s+DE\s+CARGA|PRUEBAS|$))",
        txt_norm,
        _re.IGNORECASE,
    )
    if m_id and _limp(m_id.group(1)):
        out["id_indicador"] = _limp(m_id.group(1))

    m_cca = _re.search(
        r"(?:N[ÚU]MERO\s+CCA|FOLIO\s+CCA|CCA)\s*:\s*(.*?)(?=\s*(?:FOLIO\s+DVE\s*:|N[ÚU]MERO\s+DVE\s*:|HOLO\.?\s*ANTERIOR|TIPO\s+DE\s+INSTRUMENTO\s*:|PRUEBAS\s+METROL|INSTRUCCI[ÓO]N\s*:|INSPECCI[ÓO]N|OBSERVACIONES|$))",
        txt_norm,
        _re.IGNORECASE,
    )
    if m_cca:
        raw_cca = _re.sub(r"(?:^|\s+)[XJIA](?=\s+[XJIA]|\s*$)", "", m_cca.group(1).strip())
        raw_cca = _re.sub(r"(?:\s+[XJIA])+\s*$", "", raw_cca).strip()
        if not _re.match(r"^(?:[XJIA]\s*)+$", raw_cca):
            vc = _limp(raw_cca, es_reg=True)
            if vc:
                out["numero_cca"] = vc

    m_dve = _re.search(
        r"(?:FOLIO\s+DVE|N[ÚU]MERO\s+DVE|DICTAMEN\s+DVE)\s*:\s*(.*?)(?=\s*(?:HOLO\.?\s*ANTERIOR\s*:|HOLO\.?\s*NUEVO\s*:|TIPO\s+DE\s+INSTRUMENTO\s*:|PRUEBAS\s+METROL|INSTRUCCI[ÓO]N\s*:|INSPECCI[ÓO]N|UBICACI[ÓO]N\s*:|OBSERVACIONES|$))",
        txt_norm,
        _re.IGNORECASE,
    )
    if m_dve and _limp(m_dve.group(1), es_reg=True):
        out["numero_dve"] = _limp(m_dve.group(1), es_reg=True)

    return out


def armar_correo_institucional(
    ordenes: list[dict],
    cliente: str,
    es_lote: bool | None = None,
) -> tuple[str, str]:
    """
    Constructor único e institucional de Asunto y Cuerpo HTML con Tabla Oficial (1 a N órdenes):
      - Asunto:
          * 1 orden:  Reporte de Servicio - {codigo_1} - {cliente} | Básculas PESA
          * N órdenes: Reporte de Servicio - Lote ({N} documentos): {codigo_1}, {codigo_2}, ... - {cliente} | Básculas PESA
      - Cuerpo HTML:
          Encabezado rojo #B91C1C + saludo al cliente + tabla HTML con bordes visibles:
          #, Identificador Completo, Marca, Modelo, ID / Equipo, CCA, DVE.
    """
    subject, cuerpo_html, _, _ = construir_asunto_y_cuerpo_correo(
        ordenes,
        cliente,
        es_lote=bool(es_lote) if es_lote is not None else (len(ordenes or []) > 1),
    )
    return subject, cuerpo_html


def _nombre_tipo_documento_correo(folios: list[str]) -> str:
    """Determina el nombre institucional del formato según el prefijo del folio."""
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


def _es_cancelada_orden_correo(o: dict) -> bool:
    if not isinstance(o, dict):
        return False
    est = str(o.get("estatus") or "").strip().upper()
    edo = str(o.get("estado") or "").strip().upper()
    return est in {"CANCELADA", "CANCELADO"} or edo in {"CANCELADA", "CANCELADO"}


def construir_asunto_y_cuerpo_correo(
    ordenes_lote: list[dict],
    cliente: str,
    es_lote: bool = False,
) -> tuple[str, str, str, list[str]]:
    """
    Construye (subject, cuerpo_html, cuerpo_texto, folios) con:
      - Exclusión estricta de órdenes con estatus/estado CANCELADA.
      - Asunto:
          * 1 doc:  '{Tipo} {folios[0]} - {cliente} | Básculas PESA'
          * Lote:   '{Tipo} {folios[0]} a {folios[-1]} - {cliente} | Básculas PESA'
      - Tabla HTML dinámica (paleta Apple Minimalista #1D1D1F / #E5E5EA / #F5F5F7):
          * Columnas fijas: # | ID | Marca | Modelo | ID / Equipo
          * Columna CCA solo si tiene_cca es True; columna DVE solo si tiene_dve es True
          * Celdas vacías completamente limpias ('') sin guiones '-' ni '—'.
    """
    import html as _html
    import re as _re

    activas = [o for o in (ordenes_lote or []) if o and not _es_cancelada_orden_correo(o)]
    filas_raw = [_extraer_campos_tabla_correo(o) for o in activas]
    filas_por_folio: dict[str, dict[str, str]] = {}
    filas_sin_folio: list[dict[str, str]] = []
    for f in filas_raw:
        if not f["folio"] and not f["codigo"]:
            continue
        fk = f["folio"].upper() if f["folio"] else ""
        if not fk:
            filas_sin_folio.append(f)
        elif fk not in filas_por_folio or len(f["codigo"]) > len(filas_por_folio[fk]["codigo"]):
            filas_por_folio[fk] = f

    def _nat_key(d: dict[str, str]):
        return [int(p) if p.isdigit() else p for p in _re.split(r"(\d+)", str(d.get("folio") or "").upper())]

    filas_ordenadas = sorted(filas_por_folio.values(), key=_nat_key) + filas_sin_folio
    folios = [f["folio"] for f in filas_ordenadas if f["folio"]]

    cliente_limpio = _re.sub(r"[\r\n]+", " ", str(cliente or "Cliente")).strip() or "Cliente"
    cliente_esc = _html.escape(cliente_limpio)
    n = len(filas_ordenadas)
    tipo_titulo = _nombre_tipo_documento_correo(folios)

    if len(folios) == 1:
        subject = f"{tipo_titulo} {folios[0]} - {cliente_limpio} | Básculas PESA"
    elif len(folios) >= 2:
        subject = f"{tipo_titulo} {folios[0]} a {folios[-1]} - {cliente_limpio} | Básculas PESA"
    else:
        subject = f"{tipo_titulo} - {cliente_limpio} | Básculas PESA"

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
    thead_cols_str = "\n                                        ".join(headers_html)

    tr_html_list: list[str] = []
    lineas_txt_list: list[str] = []
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

    filas_tabla_html = "\n                                    ".join(tr_html_list)
    lineas_txt = "\n".join(lineas_txt_list)

    cuerpo_texto = f"""Estimado cliente ({cliente_limpio}):

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
    return subject, cuerpo_html, cuerpo_texto, folios


def obtener_tz_mexico():
    """Retorna la zona horaria oficial America/Mexico_City (UTC-6 permanente)."""
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/Mexico_City")
    except Exception:
        from datetime import timezone, timedelta
        return timezone(timedelta(hours=-6))


def formatear_fecha_hora_mexico(raw_val) -> str:
    """Convierte cualquier timestamp ISO / datetime (UTC o con offset) a DD/MM/YYYY HH:mm en hora de México."""
    from datetime import datetime, timezone
    import re as _re

    if raw_val is None:
        return ""
    if isinstance(raw_val, datetime):
        dt = raw_val
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(obtener_tz_mexico()).strftime("%d/%m/%Y %H:%M")

    s = str(raw_val).strip()
    if not s or s.lower() in ("none", "null"):
        return ""
    if _re.match(r"^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}", s):
        return s[:16]
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(obtener_tz_mexico()).strftime("%d/%m/%Y %H:%M")
    except Exception:
        return s


def formatear_info_envio_correo(orden: dict) -> str:
    """
    Construye el indicador corporativo de trazabilidad de envío de correo:
      Enviado el DD/MM/YYYY HH:mm | Para: {correo_destino} | CC: {correo_cc}
    Nunca coloca la palabra genérica 'Cliente' como destinatario.
    """
    if not isinstance(orden, dict):
        orden = dict(orden) if orden else {}

    enviado = (
        bool(orden.get("correo_enviado"))
        or bool(orden.get("email_enviado"))
        or bool(orden.get("fecha_envio_correo"))
        or bool(orden.get("fecha_envio_email"))
    )
    if not enviado:
        return ""

    raw_fecha = orden.get("fecha_envio_correo") or orden.get("fecha_envio_email")
    fecha_str = formatear_fecha_hora_mexico(raw_fecha)

    invalidos_dest = {"", "none", "null", "sin registrar", "cliente", "destinatario registrado"}
    destino = ""
    for k in ("correo_destino", "correo_cliente", "email_cliente"):
        cand = str(orden.get(k) or "").strip()
        if cand and cand.lower() not in invalidos_dest and "@" in cand:
            destino = cand
            break

    cc_raw = orden.get("correo_cc") or ""
    cc = str(cc_raw or "").strip()
    if not cc or cc.lower() in ("none", "null"):
        cc = "recepcion@basculaspesa.com.mx"

    encabezado = f"Enviado el {fecha_str}" if fecha_str else "Enviado"
    if destino:
        return f"{encabezado} | Para: {destino} | CC: {cc}"
    return f"{encabezado} | CC: {cc}"



def fmt(value: float | None, d: float, *, zero_as_empty: bool = False) -> str:
    """
    Formatea un valor numérico con exactamente los decimales que indica d.

    Args:
        value:        El valor a formatear.
        d:            División mínima del instrumento (en las mismas unidades).
        zero_as_empty: Si True y value es 0, retorna '' en lugar de '0.000'.

    Returns:
        Cadena formateada con exactamente decimals_from_d(d) decimales.
        '' si value es None.
    """
    if value is None:
        return ''
    if zero_as_empty and value == 0.0:
        return ''
    decimals = decimals_from_d(d)
    return formato_miles_espacio(f'{value:.{decimals}f}')


def fmt_patron(value: float | None) -> str:
    """
    Formatea el valor de una masa patrón sin ceros decimales sobrantes.

    Regla de negocio:
        5.0    → '5'
        2.5    → '2.5'
        0.5    → '0.5'
        5.001  → '5.001'
        None   → ''
    """
    if value is None:
        return ''
    # Verificar si es entero exacto
    if value == math.floor(value):
        return formato_miles_espacio(str(int(value)))
    # Formatear con g (elimina ceros trailing) pero sin notación científica
    formatted = f'{value:.10g}'
    return formato_miles_espacio(formatted)


# ──────────────────────────────────────────────────────────────────────────────
# CÁLCULO DE EMT (OIML R 76 / NOM-010-SCFI)
# ──────────────────────────────────────────────────────────────────────────────

# Tablas de límites por clase (fracción de e)
# Formato: lista de (límite_superior_en_múltiplos_de_e, factor_e)
_EMT_TABLA = {
    # Clase I (precisión): umbrales muy altos
    1: [(50_000, 0.5), (200_000, 1.0), (float('inf'), 1.5)],
    # Clase II (fina): uso en joyería, farmacia
    2: [(500, 0.5), (2_000, 1.0), (10_000, 1.5), (float('inf'), 2.0)],
    # Clase III (media / comercio e industria):
    3: [(500, 1.0), (2_000, 2.0), (10_000, 3.0), (float('inf'), 3.0)],
    # Clase IIII (ordinaria):
    4: [(50, 1.0), (200, 2.0), (1_000, 3.0), (float('inf'), 3.0)],
}


def calc_emt(carga_kg: float, e_kg: float, clase: int = 3) -> float:
    """
    Calcula el Error Máximo Tolerado (EMT) según OIML R 76 / NOM-010-SCFI.

    Args:
        carga_kg:  Carga nominal aplicada en kg.
        e_kg:      Intervalo de escala de verificación (e) en kg.
                   Si no se conoce e por separado, usar el mismo valor de d.
        clase:     Clase metrológica del instrumento (1, 2, 3 o 4).
                   Por defecto 3 (más común en báscula comercial/industrial).

    Returns:
        EMT como valor positivo en kg. El error real debe estar en [-EMT, +EMT].

    Ejemplo Clase III, e=0.001 kg, m=5 kg:
        m/e = 5000 → supera 2000e → factor 3 → EMT = 3 × 0.001 = 0.003 kg
    """
    if e_kg <= 0 or carga_kg < 0:
        return e_kg  # fallback seguro: ±1e

    tabla = _EMT_TABLA.get(clase, _EMT_TABLA[3])
    multiplos = carga_kg / e_kg

    for limite, factor in tabla:
        if multiplos <= limite:
            return round(factor * e_kg, 10)

    # Fallback: último factor
    return round(tabla[-1][1] * e_kg, 10)


def emt_para_fila(carga_kg: float | None, d: float | None, clase: int = 3) -> float | None:
    """
    Wrapper conveniente: dado el valor de carga y la división d,
    retorna el EMT en kg o None si los datos son insuficientes.
    """
    if carga_kg is None or d is None or carga_kg < 0 or d <= 0:
        return None
    return calc_emt(carga_kg, d, clase=clase)


# ──────────────────────────────────────────────────────────────────────────────
# DETECCIÓN AUTOMÁTICA DE CLASE METROLÓGICA (OIML R 76 / NOM-010-SCFI)
# ──────────────────────────────────────────────────────────────────────────────

# Límites del número de divisiones n = Max / d por clase
# OIML R 76-1:2006 Tabla 1
_N_RANGES = {
    # clase: (n_min, n_max)
    1: (50_000,  float('inf')),  # Clase I  — alta precisión
    2: (100,     100_000),       # Clase II — fina (joyería, farmacia)
    3: (100,     10_000),        # Clase III — media (comercio / industria)
    4: (100,     1_000),         # Clase IIII — ordinaria (grúas, silos)
}

# Límites de d mínimo permitido por clase (en kg)
_D_MIN = {
    1: 0.001e-3,   # 0.001 mg
    2: 0.001e-3,   # 0.001 mg
    3: 0.1e-3,     # 0.1 g = 0.0001 kg
    4: 5e-3,       # 5 g   = 0.005 kg
}


def detectar_clase(max_kg: float, d_kg: float) -> int:
    """
    Infiere la clase metrológica OIML R 76 más restrictiva posible
    a partir de la capacidad máxima (Max) y la división mínima (d).

    Criterio: n = Max / d  → se asigna la clase más alta que contenga n.

    Reglas de prioridad (de más exigente a menos):
        Clase I   → n > 50 000
        Clase II  → 100 ≤ n ≤ 100 000  (y d ≥ 0.001 mg)
        Clase III → 100 ≤ n ≤ 10 000   (más común en báscula comercial)
        Clase IV  → 100 ≤ n ≤ 1 000

    Args:
        max_kg: Capacidad máxima del instrumento en kg.
        d_kg:   División mínima en kg.

    Returns:
        Número de clase: 1, 2, 3 o 4. Por defecto 3 si no se puede determinar.
    """
    if max_kg <= 0 or d_kg <= 0:
        return 3  # fallback seguro

    n = max_kg / d_kg

    # Clase I: alta precisión (n > 50 000)
    if n > 50_000:
        return 1

    # Clase II: fina (100 ≤ n ≤ 100 000 y d ≥ límite mínimo)
    if 100 <= n <= 100_000 and d_kg >= _D_MIN[2]:
        # Solo Clase II si d es muy pequeño (joyería / farmacia)
        # Heurística práctica: si d < 0.01 kg → Clase II candidate
        if d_kg < 0.01:
            return 2

    # Clase III: comercio e industria general (100 ≤ n ≤ 10 000)
    if 100 <= n <= 10_000:
        return 3

    # Clase IV: ordinaria (n ≤ 1 000)
    if n <= 1_000:
        return 4

    # n entre 1 000 y 10 000 pero no cubierto → Clase III
    return 3


def clase_label(clase: int) -> str:
    """
    Retorna la etiqueta oficial de la clase metrológica para mostrar en UI y PDF.
    Sin paréntesis OIML para mantener limpieza en el encabezado del reporte.

    Ejemplos:
        clase_label(1) → 'Clase I'
        clase_label(3) → 'Clase III'
    """
    nombres = {
        1: 'Clase I',
        2: 'Clase II',
        3: 'Clase III',
        4: 'Clase IIII',
    }
    return nombres.get(clase, f'Clase {clase}')



def clase_desde_os(os_data: dict) -> int:
    """
    Obtiene la clase metrológica de los datos de la OS.
    Prioridad:
        1. Campo 'clase_exactitud' explícito (int 1–4 o str 'I'/'II'/'III'/'IIII')
        2. Inferencia automática desde 'alcance_max' y 'div_minima'
        3. Fallback: Clase III

    Args:
        os_data: Diccionario de datos de la OS.

    Returns:
        int: 1, 2, 3 o 4.
    """
    # 1. Campo explícito
    raw = os_data.get('clase_exactitud')
    if raw is not None:
        if isinstance(raw, int) and raw in (1, 2, 3, 4):
            return raw
        if isinstance(raw, str):
            mapping = {'I': 1, 'II': 2, 'III': 3, 'IIII': 4, '1': 1, '2': 2, '3': 3, '4': 4}
            found = mapping.get(raw.strip().upper())
            if found:
                return found

    # 2. Inferencia automática
    try:
        max_kg = float(os_data.get('alcance_max') or 0)
        d_kg   = float(os_data.get('div_minima')  or 0)
        if max_kg > 0 and d_kg > 0:
            return detectar_clase(max_kg, d_kg)
    except (ValueError, TypeError):
        pass

    # 3. Fallback
    return 3
