"""
Generador de PDF — Orden de Servicio (OS) / Toma de Datos.
Réplica fiel del formato oficial de Básculas PESA.
Usa ReportLab canvas para control pixel-perfect del layout.

Correcciones aplicadas:
  - Logos cargados con Path absoluta (logo_pesa.png / Rice Lake.png).
  - Sin contador de páginas "Formato X de Y".
  - Bloque negro superior: solo CLIENTE + DIRECCIÓN (sin TÉCNICO).
  - Cuadro de NOTA oficial debajo de observaciones.
  - Sección de firmas de 2 columnas centradas (Técnico | Cliente).

Uso:
    from services.os_pdf_generator import os_pdf_generator
    path = os_pdf_generator.generate_os_pdf(os_data, repetibilidad, excentricidad, exactitud)
"""
import logging
import re
import io
import base64
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from services.metrology import (
        decimals_from_d, fmt, fmt_patron, calc_emt,
        parse_d, clase_desde_os, clase_label, formato_miles_espacio,
    )
    _METRO_OK = True
except ImportError:
    _METRO_OK = False
    def decimals_from_d(d): return 4
    def fmt(v, d=None, **kw): return '' if v is None else f'{v:.4f}'
    def fmt_patron(v): return '' if v is None else str(v)
    def calc_emt(m, e, clase=3): return e
    def parse_d(t): return None
    def clase_desde_os(os_data): return 3
    def clase_label(clase): return f'Clase {["I","II","III","IIII"][clase-1]} (OIML R 76)'

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



# [FIX colors] import top-level garantizado
from reportlab.lib import colors
from reportlab.lib.colors import HexColor

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib import colors
    from reportlab.pdfgen import canvas as rl_canvas
    _RL_OK = True
except ImportError:
    _RL_OK = False
    logger.warning("ReportLab no instalado: pip install reportlab")

# ---------------------------------------------------------------------------
# Rutas de imágenes — compatible con código fuente Y PyInstaller (_MEIPASS)
# ---------------------------------------------------------------------------
import sys as _sys
import os as _os

def _resolver_ruta_asset(nombre_archivo: str) -> "Optional[Path]":
    """
    Resuelve la ruta de un asset buscando en orden:
    1. _MEIPASS root (PyInstaller bundle)
    2. _MEIPASS/Img/
    3. _MEIPASS/assets/
    4. CWD/Img/
    5. CWD/assets/
    6. directorio del script/../Img/
    """
    base = getattr(_sys, '_MEIPASS', None)
    script_root = Path(__file__).resolve().parent.parent
    candidatas = []
    if base:
        bp = Path(base)
        candidatas += [bp / nombre_archivo, bp / 'Img' / nombre_archivo, bp / 'assets' / nombre_archivo]
    candidatas += [
        Path(_os.getcwd()) / 'Img' / nombre_archivo,
        Path(_os.getcwd()) / 'assets' / nombre_archivo,
        script_root / 'Img' / nombre_archivo,
        script_root / 'assets' / nombre_archivo,
    ]
    for cand in candidatas:
        if cand.exists():
            logger.debug("Asset encontrado: %s", cand)
            return cand
    logger.warning("Asset no encontrado: %s", nombre_archivo)
    return None

# Mantener compatibilidad con código que usa _IMG_DIR
_BASE_DIR = Path(__file__).resolve().parent.parent.parent
_IMG_DIR  = _BASE_DIR / "Img"

def _resolve_logo(name_no_ext: str) -> "Optional[Path]":
    """Retorna Path al logo si existe (.png / .jpg / .jpeg). None si no existe."""
    for ext in (".png", ".jpg", ".jpeg"):
        result = _resolver_ruta_asset(f"{name_no_ext}{ext}")
        if result:
            return result
    return None

_LOGO_PESA_PATH = _resolve_logo("logo_pesa")

# Rice Lake — buscar con y sin espacio en el nombre del archivo
def _resolve_rice_lake() -> "Optional[Path]":
    for name in ("RiceLake", "Rice Lake", "ricelake", "rice_lake"):
        for ext in (".png", ".jpg", ".jpeg"):
            result = _resolver_ruta_asset(f"{name}{ext}")
            if result:
                return result
    return None

_LOGO_RL_PATH = _resolve_rice_lake()

# ---------------------------------------------------------------------------
# Paleta de colores
# ---------------------------------------------------------------------------
_RED        = colors.HexColor("#CC1F1F")
_DARK_HDR   = colors.HexColor("#1C1C1C")
_GRAY_HDR   = colors.HexColor("#2D2D2D")
_GRAY_LIGHT = colors.HexColor("#F5F5F5")
_GRAY_MED   = colors.HexColor("#CCCCCC")
_GRAY_DARK  = colors.HexColor("#888888")
_TBL_HDR    = colors.HexColor("#CC1F1F")
_TBL_BORDER = colors.HexColor("#CCCCCC")
_BLACK      = colors.black
_WHITE      = colors.white
# Color de alerta para campos oblig. vacíos (etiqueta en rojo normativo NOM)
_FIELD_ALERT = colors.HexColor("#C8102E")


# ---------------------------------------------------------------------------
# Helpers de normalización (toleran cualquier formato de entrada)
# ---------------------------------------------------------------------------
def _validar_num(val):
    """
    Convierte cualquier valor a float de forma segura.
    Retorna None si el valor es vacío, '-', None o no convertible.
    NUNCA lanza excepciones. Previene TypeError en comparaciones < > con None.
    """
    if val is None:
        return None
    s = str(val).strip()
    if s in ('', '-', 'None', 'nan', 'NaN'):
        return None
    try:
        return float(s.replace(',', '.'))
    except (ValueError, TypeError):
        return None

def _parse_aplica_excentricidad(os_data: dict) -> bool:
    """
    Normaliza la clave aplica_excentricidad que puede llegar como:
    - bool True/False (del formulario PyQt6)
    - str 'SÍ' / 'NO' / 'SI' / 'Sí' / 'true' / 'false'
    - int 1/0
    - None (default = True)
    """
    val = os_data.get("aplica_excentricidad", True)
    if isinstance(val, bool):
        return val
    if isinstance(val, int):
        return bool(val)
    if isinstance(val, str):
        return val.strip().upper() not in ("NO", "N", "0", "FALSE")
    return True  # fallback seguro


def _inferir_tipo_no_aplica(os_data: dict) -> str:
    """
    Infiere el tipo de instrumento no apto para excentricidad.
    Retorna: 'tanque' | 'tolva' | 'gancho' | 'patin' | 'tolva' (fallback)
    """
    tipo_no = str(os_data.get("tipo_no_aplica_exc") or "").lower()
    tipo_inst = str(os_data.get("tipo_instrumento") or os_data.get("tipo_equipo") or "").lower()
    combined = tipo_no + " " + tipo_inst

    if "tanque" in combined:
        return "tanque"
    elif "tolva" in combined:
        return "tolva"
    elif "gancho" in combined or "grúa" in combined or "grua" in combined:
        return "gancho"
    elif "patín" in combined or "patin" in combined or "transpaleta" in combined:
        return "patin"
    elif "tolva" in combined or "silo" in combined:
        return "tolva"
    return "tolva"  # fallback con dibujo disponible

def _flag_sustitucion_estricto(raw) -> bool:
    """True SOLO si el valor es explícitamente verdadero (True/1/'1'/'true'/'SI'/'SÍ')."""
    if raw is True:
        return True
    if raw is None or raw is False:
        return False
    if isinstance(raw, (int, float)):
        return raw == 1
    return str(raw).strip().lower() in ("1", "true", "si", "sí")


def _es_tanque(os_data: dict) -> bool:
    """Tanque determinado ÚNICAMENTE por tipo_instrumento / tipo_equipo (no por motivo heredado)."""
    tipo = str(os_data.get("tipo_instrumento") or os_data.get("tipo_equipo") or "").lower()
    return "tanque" in tipo


def _es_modo_sustitucion(os_data: dict) -> bool:
    """
    Formato de sustitución (Agua + Pesas, Excentricidad No Apta) SOLO si:
      - tipo_instrumento es Tanque, o
      - aplica_sustitucion es explícitamente verdadero.
    Banderas heredadas (es_sustitucion / es_enlace_sustitucion / motivo 'Tanque')
    ya NO fuerzan este formato en básculas de plataforma.
    """
    if not os_data:
        return False
    if _es_tanque(os_data):
        return True
    raw = os_data.get("aplica_sustitucion")
    if raw is None:
        raw = os_data.get("usa_sustitucion")
    return _flag_sustitucion_estricto(raw)

def _es_servicio_calibracion(os_data: dict) -> bool:
    """
    Retorna True SOLO si el tipo de servicio contiene explícitamente 'calibraci'.
    Servicios que SH requieren CCA e Inicial: Calibración, Ajuste+Calibración, etc.
    Servicios que NO: Ajuste+Inspección, Mantenimiento, Revisión, Entrega Refacciones.
    """
    _ts_raw = (
        os_data.get("tipo_servicio_nombre") or
        os_data.get("tipo_servicio") or
        ""
    )
    servicio = str(_ts_raw).lower()
    # Normalizar acentos para comparación robusta
    servicio_norm = (servicio
        .replace("á", "a").replace("é", "e")
        .replace("í", "i").replace("ó", "o").replace("ú", "u")
    )
    return "calibraci" in servicio_norm


def _limpiar_b64_firma(valor) -> Optional[str]:
    """Normaliza una firma Base64 (quita prefijo data:) y valida que sea imagen."""
    if not valor:
        return None
    s = str(valor).strip()
    if "," in s and s.lower().startswith("data:"):
        s = s.split(",", 1)[1].strip()
    if len(s) <= 50:
        return None
    try:
        cabecera = base64.b64decode(s[:64] + "=" * (-len(s[:64]) % 4))
    except Exception:
        return None
    # PNG o JPEG únicamente
    if cabecera.startswith(b"\x89PNG") or cabecera.startswith(b"\xff\xd8"):
        return s
    return None


def _firma_perfil_tecnico(os_data: dict) -> Optional[str]:
    """
    Firma OFICIAL registrada del técnico asignado (cat_tecnicos.firma_digital).

    Regla de negocio: la firma de perfil ("Mi Firma Digital") tiene prioridad
    sobre cualquier trazo guardado en la orden, para evitar estampar trazos
    residuales o accidentales en el PDF.
    """
    directa = _limpiar_b64_firma(
        os_data.get("firma_tecnico_perfil") or os_data.get("firma_digital")
    )
    if directa:
        return directa
    id_tec = os_data.get("id_tecnico")
    if not id_tec:
        return None
    try:
        from models.orden_servicio import orden_servicio_repo
        row = orden_servicio_repo._fetch_one(
            "SELECT firma_digital FROM cat_tecnicos WHERE id = %s", (int(id_tec),)
        )
        return _limpiar_b64_firma((row or {}).get("firma_digital"))
    except Exception as exc:
        logger.debug("No se pudo leer firma de perfil del técnico %s: %s", id_tec, exc)
        return None


class OsPdfGenerator:
    """
    Genera el PDF Toma de Datos de una Orden de Servicio.
    Layout en puntos (1 pt = 1/72 inch).
    Tamano de pagina: Letter = 612 x 792 pt.
    """

    ML = 36   # margen izquierdo
    MR = 36   # margen derecho
    MT = 15   # margen superior
    MB = 15   # margen inferior

    W  = 612
    H  = 792

    @property
    def CW(self) -> float:
        """Ancho util = 612 - 36 - 36 = 540 pt."""
        return self.W - self.ML - self.MR

    # --- API Publica ---------------------------------------------------------

    def generate_os_pdf(
        self,
        os_data:           dict,
        repetibilidad:     list = None,
        excentricidad:     list = None,
        exactitud:         list = None,
        output_path:       Optional[str] = None,
        tecnico_nombre:    Optional[str] = None,
        firma_tecnico_b64: Optional[str] = None,
        digital:           bool = False,
        force:             bool = False,
    ) -> str:
        """
        Genera el PDF completo de la OS.

        Args:
            os_data:        Dict con los datos de la OS.
            repetibilidad:  Filas de det_repetibilidad.
            excentricidad:  Filas de det_excentricidad.
            exactitud:      Filas de det_exactitud.
            output_path:    Ruta de salida (si None → carpeta de servidor).
            tecnico_nombre: Nombre del técnico (si no viene en os_data).
            digital:        True si el PDF viene de un formulario digital firmado.
            force:          True para regenerar aunque el archivo ya exista.

        Returns:
            Ruta absoluta del PDF generado.
        """
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado. Ejecutar: pip install reportlab")

        folio_check = str((os_data or {}).get("folio_os") or (os_data or {}).get("folio_re") or (os_data or {}).get("folio") or "").strip().upper()
        tipo_doc_check = str((os_data or {}).get("tipo_documento") or "").strip().upper()
        if folio_check.startswith("OSOB-") or tipo_doc_check == "OSOB":
            try:
                merged_osob = dict(os_data or {})
                if tecnico_nombre and not merged_osob.get("tecnico_nombre"):
                    merged_osob["tecnico_nombre"] = tecnico_nombre
                if firma_tecnico_b64 and not merged_osob.get("firma_tecnico"):
                    merged_osob["firma_tecnico"] = firma_tecnico_b64
                return osob_pdf_generator.generate(
                    os_data=merged_osob,
                    output_path=output_path,
                    force=force,
                    digital=digital,
                )
            except Exception as exc_osob:
                logger.warning("Delegación a osob_pdf_generator falló (%s); usando flujo estándar.", exc_osob)

        if folio_check.startswith("RE-"):
            try:
                from services.re_pdf_generator import re_pdf_generator
                merged_re = dict(os_data or {})
                if tecnico_nombre and not merged_re.get("tecnico_nombre"):
                    merged_re["tecnico_nombre"] = tecnico_nombre
                if firma_tecnico_b64 and not merged_re.get("firma_tecnico"):
                    merged_re["firma_tecnico"] = firma_tecnico_b64
                return re_pdf_generator.generate(
                    rv_data=merged_re,
                    output_path=output_path,
                    force=force,
                    digital=digital,
                )
            except Exception as exc_re:
                logger.warning("Delegación a re_pdf_generator falló (%s); usando flujo estándar.", exc_re)

        # Si los datos vienen dentro de os_data (llamada desde digital_service_dialog)
        repetibilidad = repetibilidad or os_data.get("repetibilidad", []) or []
        excentricidad = excentricidad or os_data.get("excentricidad", []) or []
        exactitud     = exactitud     or os_data.get("exactitud",     []) or []

        if output_path is None:
            folio = os_data.get("folio_os", "OS")
            output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
            try:
                output_dir.mkdir(parents=True, exist_ok=True)
            except (PermissionError, OSError):
                from pathlib import Path as _P
                output_dir = _P.home() / "PesaServidorLocal" / "PDF_OS"
                output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")

        # Guard anti-duplicado: si el PDF ya existe y no se fuerza, retornar sin regenerar
        if not force and Path(output_path).exists():
            logger.info(f"PDF ya existe, omitiendo regeneración: {output_path}")
            return output_path

        # Prioridad de firma del técnico:
        #   1. Firma oficial registrada en su perfil (cat_tecnicos.firma_digital)
        #   2. Firma explícita recibida por parámetro (trazada en la sesión)
        #   3. Firma guardada en la orden (os_data) — se resuelve en _draw_firmas
        firma_perfil = _firma_perfil_tecnico(os_data)
        if firma_perfil:
            firma_tecnico_b64 = firma_perfil

        # Escritura atómica: se renderiza a .tmp y se reemplaza al final.
        # Si el render falla, el PDF anterior queda intacto en disco.
        tmp_path = f"{output_path}.tmp"
        c = rl_canvas.Canvas(tmp_path, pagesize=letter)
        c.setTitle(f"Toma de Datos - {os_data.get('folio_os', '')}")
        c.setAuthor("Servicios PESA")
        c.setSubject("Orden de Servicio Metrologica")

        try:
            self._draw_page(c, os_data, repetibilidad, excentricidad, exactitud,
                            tecnico_nombre, digital=digital,
                            firma_tecnico_b64=firma_tecnico_b64)
            c.save()
            _os.replace(tmp_path, output_path)
        except Exception:
            try:
                Path(tmp_path).unlink()
            except OSError:
                pass
            raise
        logger.info(f"PDF OS generado: {output_path}")
        return output_path

    # --- Dibujo de pagina completa -------------------------------------------

    def _draw_page(self, c, os_data, rep, exc, exac, tecnico_nombre,
                   digital: bool = False,
                   firma_tecnico_b64: Optional[str] = None) -> None:
        y = self.H
        y = self._draw_header(c, y, os_data)
        y = self._draw_fecha(c, y, os_data, digital=digital)
        y = self._draw_cliente(c, y, os_data)
        y = self._draw_equipo(c, y, os_data)
        y -= 8   # gap entre ficha técnica (incl. fila J/I/A) y PRUEBAS METROLÓGICAS
        y = self._draw_pruebas(c, y, rep, exc, exac, os_data)
        y = self._draw_observaciones(c, y, os_data)
        # Firmas ANTES de la nota (nuevo orden)
        y_after_firmas = self._draw_firmas(
            c, y, os_data, tecnico_nombre,
            digital=digital,
            firma_tecnico_b64=firma_tecnico_b64,
        )
        y = self._draw_nota(c, y_after_firmas)
        self._draw_footer_bar(c)

    # --- Helper único de detección de modalidad (normaliza acentos) ----------

    @staticmethod
    def _es_digital(os_data) -> bool:
        """
        Retorna True SOLO si la modalidad es explícitamente DIGITAL.
        Cualquier otro valor (FISICO, Físico, FÍSICO, None, "") → False.
        Usa unicodedata para eliminar diferencias de acentuación.
        """
        import unicodedata as _ud
        raw = str((os_data or {}).get("modalidad") or "").strip()
        # Normalizar: quitar diacríticos, pasar a ASCII mayúsculas
        normalized = _ud.normalize("NFKD", raw).encode("ascii", "ignore").decode().upper()
        return normalized == "DIGITAL"

    # --- Helper: diagonal de cancelación para celdas vacías ------------------

    def _draw_cancel_slash(self, c, cx: float, cy: float, cell_w: float, cell_h: float) -> None:
        """
        Dibuja una diagonal '/' (de inf-izq a sup-der) centrada en la celda,
        indicando que el campo no fue capturado.
        """
        margin = 2
        x1 = cx + margin
        y1 = cy + margin
        x2 = cx + cell_w - margin
        y2 = cy + cell_h - margin
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.6)
        c.line(x1, y1, x2, y2)


    # --- SECCION 1: Encabezado con logos reales ------------------------------

    def _draw_header(self, c, y: float, os_data: dict) -> float:
        top = y - self.MT

        # Logo BP PESA (izquierda) — altura uniforme 38pt
        LOGO_H = 38
        if _LOGO_PESA_PATH:
            c.drawImage(
                str(_LOGO_PESA_PATH),
                self.ML, top - LOGO_H,
                width=155, height=LOGO_H,
                preserveAspectRatio=True,
                mask="auto",
            )
        else:
            logger.error("logo_pesa no encontrado en %s", _IMG_DIR)
            c.setStrokeColor(_RED)
            c.setLineWidth(1)
            c.rect(self.ML, top - LOGO_H, 155, LOGO_H, fill=0, stroke=1)
            c.setFillColor(_RED)
            c.setFont("Helvetica", 6)
            c.drawCentredString(self.ML + 77, top - LOGO_H / 2, "[ logo_pesa no encontrado ]")

        # Logo Rice Lake (derecha) — misma altura 38pt para balance visual
        # Sin texto 'Authorized Distributor' para un encabezado más limpio
        rl_x = self.ML + self.CW - 145

        if _LOGO_RL_PATH:
            c.drawImage(
                str(_LOGO_RL_PATH),
                rl_x, top - LOGO_H,
                width=145, height=LOGO_H,
                preserveAspectRatio=True,
                mask="auto",
            )
        else:
            logger.error("Rice Lake logo no encontrado en %s", _IMG_DIR)
            c.setStrokeColor(_RED)
            c.setLineWidth(1)
            c.rect(rl_x, top - LOGO_H, 145, LOGO_H, fill=0, stroke=1)
            c.setFillColor(_RED)
            c.setFont("Helvetica", 6)
            c.drawCentredString(rl_x + 72, top - LOGO_H / 2, "[ Rice Lake logo no encontrado ]")

        # Sin línea divisoria — el espacio en blanco bajo los logos crea separación natural
        # sep_y eliminado para un encabezado más limpio
        section_y = top - LOGO_H - 6

        # Encabezado central limpio (area superior entre logo y folio despejada)
        titulo_y = section_y - 8

        # Caja de Folio (derecha) — simétrica y alineada con el título
        # Anclada verticalmente al mismo punto que el título para alineación limpia
        folio_w = 140
        folio_h = 40
        folio_x = self.ML + self.CW - folio_w
        folio_y = titulo_y - folio_h  # alineada con la base del bloque de título

        # Marco externo rojo (2pt de línea para mayor presencia)
        c.setStrokeColor(_RED)
        c.setLineWidth(2)
        c.rect(folio_x, folio_y, folio_w, folio_h, fill=0, stroke=1)

        # Banda roja superior con etiqueta "FOLIO / OS"
        band_h = 15
        c.setFillColor(_RED)
        c.rect(folio_x, folio_y + folio_h - band_h, folio_w, band_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(folio_x + folio_w / 2, folio_y + folio_h - band_h + 4, "FOLIO / OS")

        # Número de folio centrado en el área blanca inferior
        folio_raw  = str(os_data.get('folio') or os_data.get('folio_os') or os_data.get('folio_base') or 'OS-26-547').strip()
        folio_text = folio_raw.replace("[DEMO]", "").strip()
        font_size  = 15 if len(folio_text) <= 10 else 12
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", font_size)
        body_center_y = folio_y + (folio_h - band_h) / 2 - font_size / 4
        c.drawCentredString(folio_x + folio_w / 2, body_center_y, folio_text)

        return titulo_y - 44


    # --- SECCION 2: Fecha (siempre en blanco para llenado manual) ------------
    #
    # La fecha del servicio la registra el TÉCNICO EN CAMPO con bolígrafo.
    # No se imprime ningún valor del sistema para evitar errores de fecha.

    def _draw_fecha(self, c, y: float, os_data: dict,
                    digital: bool = False) -> float:
        y -= 6
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, "FECHA:")

        if digital:
            # Regla metrológica: la fecha del documento debe ser la fecha en
            # que el técnico EJECUTA y FINALIZA la orden, NO la fecha de creación
            # logística.  Prioridad:
            #   1. fecha_servicio  (guardada al generar el PDF final)
            #   2. fecha_cierre    (si existe columna de cierre)
            #   3. Hoy             (fecha real de generación del certificado)
            from datetime import date as _date
            fecha_str = ""
            for campo in ("fecha_servicio", "fecha_cierre", "fecha_ejecucion"):
                v = os_data.get(campo)
                if v:
                    fecha_str = str(v).strip().split(" ")[0]  # solo YYYY-MM-DD
                    break
            if not fecha_str:
                fecha_str = _date.today().strftime("%Y-%m-%d")

            c.setFont("Helvetica", 8)
            c.drawString(self.ML + 36, y, fecha_str)
        else:
            # Modo físico: líneas en blanco para llenado manual con bolígrafo
            c.setFont("Helvetica", 8)
            c.drawString(self.ML + 36, y, "________________________")

        y -= 10
        return y




    # --- SECCION 3: Cliente / Direccion (2 filas, SIN TECNICO) ---------------

    def _draw_cliente(self, c, y: float, os_data: dict) -> float:
        """
        Bloque CLIENTE / DIRECCIÓN sobre fondo blanco limpio.
        Etiqueta en rojo, valor en negro, borde inferior gris.
        """
        row_h = 18
        y -= 4

        for lbl, key in [
            ("CLIENTE",   "cliente"),
            ("DIRECCIÓN / PLANTA", "direccion_cliente"),
        ]:
            # Fondo blanco — sin barras negras
            c.setFillColor(_WHITE)
            c.rect(self.ML, y - row_h, self.CW, row_h, fill=1, stroke=0)

            # Etiqueta en rojo y negrita
            c.setFillColor(_RED)
            c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 4, y - row_h + 5, lbl + ":")

            # Valor — busca en múltiples claves para compatibilidad
            if "DIRECCIÓN" in lbl:
                ubic = str(os_data.get("ubicacion") or os_data.get("area") or os_data.get("ubicacion_equipo") or "").strip()
                # Separar estrictamente la Dirección de la Planta de la Ubicación física del instrumento:
                # NUNCA usar ubicacion, area o ubicacion_equipo
                cands = [
                    os_data.get("sucursal"),
                    os_data.get("planta_direccion"),
                    os_data.get("direccion"),
                    os_data.get("domicilio"),
                    os_data.get("direccion_planta"),
                    os_data.get("sucursal_direccion"),
                    os_data.get("sucursal_nombre"),
                    os_data.get("direccion_cliente"),
                ]
                valor = ""
                for c_val in cands:
                    if c_val:
                        s_val = str(c_val).strip()
                        if s_val and s_val != "-" and s_val.lower() != "null" and s_val.lower() != ubic.lower() and s_val != str(os_data.get("cliente")):
                            valor = s_val
                            break
                if not valor or valor.lower() == ubic.lower():
                    try:
                        from database.connection import db_pool
                        if db_pool:
                            conn_db = db_pool.get_connection()
                            try:
                                with conn_db.cursor() as cur_db:
                                    s_id = os_data.get("sucursal_id") or os_data.get("id_sucursal")
                                    c_id = os_data.get("id_cliente") or os_data.get("cliente_id")
                                    if s_id:
                                        cur_db.execute("SELECT direccion, nombre_sucursal FROM cliente_sucursales WHERE id = %s", (s_id,))
                                        r_s = cur_db.fetchone()
                                        if r_s and r_s[0] and r_s[0].strip() and r_s[0].strip().lower() != ubic.lower():
                                            valor = r_s[0].strip()
                                        elif r_s and r_s[1] and r_s[1].strip() and r_s[1].strip().lower() != ubic.lower():
                                            valor = r_s[1].strip()
                                    if (not valor or valor.lower() == ubic.lower()) and c_id:
                                        cur_db.execute("SELECT direccion, nombre_sucursal FROM cliente_sucursales WHERE cliente_id = %s ORDER BY id ASC LIMIT 1", (c_id,))
                                        r_s2 = cur_db.fetchone()
                                        if r_s2 and r_s2[0] and r_s2[0].strip() and r_s2[0].strip().lower() != ubic.lower():
                                            valor = r_s2[0].strip()
                                        elif r_s2 and r_s2[1] and r_s2[1].strip() and r_s2[1].strip().lower() != ubic.lower():
                                            valor = r_s2[1].strip()
                                    if (not valor or valor.lower() == ubic.lower()) and c_id:
                                        cur_db.execute("SELECT direccion FROM cat_clientes WHERE id = %s", (c_id,))
                                        r_c = cur_db.fetchone()
                                        if r_c and r_c[0] and r_c[0].strip() and r_c[0].strip().lower() != ubic.lower():
                                            valor = r_c[0].strip()
                                conn_db.commit()
                            finally:
                                db_pool.release_connection(conn_db)
                    except Exception:
                        pass
                cliente_str = str(os_data.get("cliente") or os_data.get("razon_social") or "").strip().lower()
                if (not valor or valor.lower() == ubic.lower()) and "mar bran" in cliente_str:
                    valor = "Carretera el Jaral del Progreso- Cortazar km 4.3 C.P. 38470, Jaral del Progreso, Guanajuato"
            else:
                valor = str(os_data.get(key, "") or "")

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 8)
            lbl_w = c.stringWidth(lbl + ":", "Helvetica-Bold", 8)
            c.drawString(self.ML + 4 + lbl_w + 8, y - row_h + 5, valor[:90])

            # Borde inferior gris fino
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            c.line(self.ML, y - row_h, self.ML + self.CW, y - row_h)

            y -= row_h   # avanzar a la siguiente fila

        # Espacio ampliado antes de los campos del instrumento para evitar solapamiento
        y -= 16
        return y



    # --- SECCION 4: Datos del Equipo -----------------------------------------

    def _draw_equipo(self, c, y: float, os_data: dict) -> float:
        """
        Renderiza la sección de Datos del Instrumento.

        Evaluación estricta por palabras clave del tipo de servicio:
          ─ 'calibracion' / 'calibración'  → mostrar_cca = True
          ─ 'inspeccion' / 'inspección'    → mostrar_hologramas = True

        Casos resultantes:
          1. Ajuste puro                   → ningún campo extra
          2. Ajuste y Calibración          → solo NÚMERO CCA
          3. Ajuste e Inspección           → solo HOLOGRAMA ANTERIOR + ACTUALIZADO
          4. Ajuste, Calibración e Insp.   → CCA + ambos hologramas
        """
        # ── Normalizar el texto del tipo de servicio ──────────────────────────
        # Se intenta primero el nombre directo y como fallback el nombre almacenado
        _ts_raw = (
            os_data.get("tipo_servicio_nombre") or
            os_data.get("tipo_servicio") or
            ""
        )
        servicio = str(_ts_raw).lower()
        # Normalizar acentos para comparacion robusta ante BD con o sin acentos
        servicio_norm = (servicio
            .replace("á", "a").replace("é", "e")
            .replace("í", "i").replace("ó", "o").replace("ú", "u")
        )

        # CONDICION ESTRICTA:
        # CCA e Inicial J/I/A SOLO si el servicio contiene 'calibraci' explicitamente.
        # Servicios de Inspeccion pura, Mantenimiento, Revision o Entrega Refacciones
        # NO incluyen casillas de calibrador ni numero CCA.
        tiene_calibracion = "calibraci" in servicio_norm
        tiene_inspeccion  = "inspecci"  in servicio_norm

        mostrar_cca        = tiene_calibracion   # CCA solo con calibracion
        mostrar_hologramas = tiene_inspeccion    # Hologramas solo con inspeccion

        # ── Helpers de dibujo ────────────────────────────────────────────────
        cw     = self.CW
        fila_h = 18
        GAP    = 6  # espacio entre columnas

        def _field(lbl: str, val, x: float, row_y: float, w: float) -> None:
            """Dibuja etiqueta:valor en (x, row_y) dentro del ancho w."""
            raw_val = str(val or "").strip()
            empty   = (raw_val == "")
            max_chars = max(1, int(w / 5.5))
            display_val = raw_val[:max_chars]

            lbl_color = _FIELD_ALERT if empty else _GRAY_DARK
            c.setFillColor(lbl_color)
            c.setFont("Helvetica-Bold", 7)
            lbl_str = lbl + ":"
            c.drawString(x + 2, row_y + 5, lbl_str)
            lbl_w = c.stringWidth(lbl_str, "Helvetica-Bold", 7)

            if empty:
                right = min(x + w - 3, self.ML + cw - 2)
                start = x + 2 + lbl_w + 3
                if start < right:
                    c.setStrokeColor(_GRAY_DARK)
                    c.setLineWidth(0.5)
                    c.line(start, row_y + 5, right, row_y + 5)
            else:
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 7.5)
                c.drawString(x + 2 + lbl_w + 3, row_y + 5, display_val)

        def field_row(fields: list, row_y: float) -> None:
            """Dibuja una fila de campos con posiciones X calculadas con precision."""
            x = self.ML
            for i, (label, val, w) in enumerate(fields):
                _field(label, val, x, row_y, w)
                x += w + GAP

        # ── Fila 1: Marca / Modelo / N/S ──────────────────────────────────────
        _f1_gap = 2 * GAP
        _f1_net = cw - _f1_gap
        field_row([
            ("MARCA",  os_data.get("equipo_marca")  or os_data.get("marca"),  _f1_net * 0.32),
            ("MODELO", os_data.get("equipo_modelo") or os_data.get("modelo"), _f1_net * 0.32),
            ("N/S",    os_data.get("equipo_ns") or os_data.get("ns") or os_data.get("serie") or os_data.get("n_serie"), _f1_net * 0.36),
        ], y)
        y -= fila_h

        # ── Fila 2: ID Equipo / Tipo Instrumento / Funcionamiento ─────────────
        _tipo_inst = (
            os_data.get("tipo_instrumento") or
            os_data.get("tipo_receptor")     or
            os_data.get("tipo_equipo")       or
            os_data.get("instrumento")       or
            ""
        ).strip()
        # Si aún vacío, deducir desde geometria_plataforma
        if not _tipo_inst:
            _geo_raw = (os_data.get("geometria_plataforma") or "").lower()
            if "cuadrada" in _geo_raw or "plataforma" in _geo_raw:
                _tipo_inst = "Plataforma"
            elif "circular" in _geo_raw:
                _tipo_inst = "Plataforma Circular"
            elif "camionera" in _geo_raw:
                _tipo_inst = "Báscula camionera"
        _funcionamiento = str(os_data.get("funcionamiento") or "").strip() or "Electrónico"

        _f2_gap = 2 * GAP
        _f2_net = cw - _f2_gap
        # TIPO DE INSTRUMENTO: columna ampliada para textos largos (camionera/puente)
        field_row([
            ("ID INDICADOR / EQUIPO", os_data.get("equipo_id") or os_data.get("id_equipo"), _f2_net * 0.28),
            ("TIPO DE INSTRUMENTO",   _tipo_inst,      _f2_net * 0.45),
            ("FUNCIONAMIENTO",        _funcionamiento, _f2_net * 0.27),
        ], y)
        y -= fila_h

        # ── Fila 3: Capacidad / División / Puntos Apoyo / Ubicación ──────────
        _puntos_apoyo_raw = str(os_data.get("puntos_apoyo") or os_data.get("puntos_de_apoyo") or "").strip()
        _puntos_apoyo = _puntos_apoyo_raw if _puntos_apoyo_raw.lower() not in ['libre', 'none', 'null', '\u2014', '0', ''] else ''

        _cap_val = os_data.get("equipo_alcance") or os_data.get("alcance_max") or os_data.get("capacidad_max") or os_data.get("capacidad_maxima") or os_data.get("cap_max")
        _div_val  = os_data.get("equipo_division") or os_data.get("div_minima")   or os_data.get("division_min")
        _dve_val  = os_data.get("dve") or os_data.get("equipo_dve") or ""
        _ubic    = str(os_data.get("ubicacion") or os_data.get("area") or os_data.get("ubicacion_equipo") or os_data.get("equipo_ubicacion") or "").strip()

        def _fmt_unidad(raw, unidad="kg"):
            """Evita duplicar la unidad y formatea miles con espacio."""
            if not raw:
                return None
            fmt_raw = formato_miles_espacio(raw)
            s_val = str(fmt_raw).strip()
            if s_val.lower().endswith(unidad.lower()):
                return s_val   # ya trae la unidad
            return f"{s_val} {unidad}"

        if tiene_inspeccion:
            _f3_gap = 3 * GAP
            _f3_net = cw - _f3_gap
            _unidad_pdf = str(os_data.get("unidad_medida") or "kg").strip() or "kg"
            _cap_str  = _fmt_unidad(_cap_val, _unidad_pdf)
            _div_str  = _fmt_unidad(_div_val, _unidad_pdf)
            field_row([
                ("CAPACIDAD MÁXIMA", _cap_str,      _f3_net * 0.26),
                ("DIVISIÓN MÍNIMA",  _div_str,       _f3_net * 0.22),
                ("DVE",              _dve_val,        _f3_net * 0.22),
                ("PUNTOS DE APOYO",  _puntos_apoyo,   _f3_net * 0.30),
            ], y)
            y -= fila_h
            field_row([("UBICACIÓN", _ubic, cw)], y)
            y -= fila_h
        else:
            _f3_gap = 3 * GAP
            _f3_net = cw - _f3_gap
            _unidad_pdf = str(os_data.get("unidad_medida") or "kg").strip() or "kg"
            _cap_str2 = _fmt_unidad(_cap_val, _unidad_pdf)
            _div_str2 = _fmt_unidad(_div_val, _unidad_pdf)
            field_row([
                ("CAPACIDAD MÁXIMA", _cap_str2,     _f3_net * 0.25),
                ("DIVISIÓN MÍNIMA",  _div_str2,      _f3_net * 0.22),
                ("PUNTOS DE APOYO",  _puntos_apoyo,   _f3_net * 0.20),
                ("UBICACIÓN",        _ubic,           _f3_net * 0.33),
            ], y)
            y -= fila_h

        # ── Fila 3 (condicional): CCA / Hologramas ────────────────────────────────────
        # Caso 1 — Ajuste puro: omitir completamente, sin espacio residual
        # Fallback triple de clave para el numero de certificado CCA
        _numero_cca = (
            os_data.get("numero_cca") or
            os_data.get("numero_certificado") or
            os_data.get("cca") or
            ""
        )
        if not mostrar_cca and not mostrar_hologramas:
            pass   # no se dibuja nada, y permanece donde está

        # Caso 2 — Solo CCA (Calibración sin Inspección)
        elif mostrar_cca and not mostrar_hologramas:
            field_row([
                ("NÚMERO CCA", _numero_cca, cw),
            ], y)
            y -= fila_h

        # Caso 3 — Solo Hologramas (Inspección sin Calibración)
        elif not mostrar_cca and mostrar_hologramas:
            # 2 columnas → 1 gap de 8pt (consistente con el gap del Caso 4)
            half_w = (cw - 8) / 2
            field_row([
                ("HOLOGRAMA ANTERIOR",    os_data.get("holograma_anterior")    or "", half_w),
                ("HOLOGRAMA ACTUALIZADO", os_data.get("holograma_actualizado") or "", half_w),
            ], y)
            y -= fila_h

        # Caso 4 — CCA + ambos hologramas (Calibración + Inspección)
        else:
            third_w = (cw - 8) / 3
            field_row([
                ("NÚMERO CCA",            _numero_cca,                                                    third_w),
                ("HOLOGRAMA ANTERIOR",    os_data.get("holograma_anterior")    or "", third_w),
                ("HOLOGRAMA ACTUALIZADO", os_data.get("holograma_actualizado") or "", third_w),
            ], y)
            y -= fila_h

        # ── Fila 4: Casillas  [ ] J   [ ] I   [ ] A  ──────────────────────
        # CONDICION ESTRICTA: solo si el servicio contiene 'calibraci' explicitamente.
        # Ajuste+Inspeccion, Mantenimiento, Revision, Entrega Refacciones: OMITIR.
        if tiene_calibracion:
            jia_h   = 14        # altura de la fila
            chk_sz  = 6         # lado del cuadrito
            gap     = 30        # espacio entre inicio de una casilla y la siguiente
            row_y   = y - jia_h

            # Leer la inicial seleccionada - todos los alias posibles
            inicial_sel = (
                str(
                    os_data.get("inicial_calibrador") or
                    os_data.get("tipo_calibracion_inicial") or
                    os_data.get("inicial") or
                    ""
                ).strip().upper()
            )

            # Fondo gris claro + borde inferior
            c.setFillColor(colors.HexColor("#F7F7F7"))
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.rect(self.ML, row_y, cw, jia_h, fill=1, stroke=0)
            c.line(self.ML, row_y, self.ML + cw, row_y)

            # Centrar las 3 casillas
            total_w = 3 * chk_sz + 2 * gap + 3 * 10   # 3×(cuadro+letra) + 2 gaps
            x0      = self.ML + (cw - total_w) / 2
            mid_y   = row_y + (jia_h - chk_sz) / 2

            for i, code in enumerate(["J", "I", "A"]):
                xc       = x0 + i * (chk_sz + gap + 10)
                is_marked = (inicial_sel == code)

                # Fondo del cuadrito (blanco siempre, con borde rojo si marcado)
                c.setFillColor(_WHITE)
                c.setStrokeColor(colors.HexColor("#CC1F1F") if is_marked else _GRAY_DARK)
                c.setLineWidth(0.9 if is_marked else 0.7)
                c.rect(xc, mid_y, chk_sz, chk_sz, fill=1, stroke=1)

                # Dibujar X roja diagonal si la casilla está marcada
                if is_marked:
                    c.setStrokeColor(colors.HexColor("#CC1F1F"))
                    c.setLineWidth(1.2)
                    c.line(xc + 0.8, mid_y + chk_sz - 0.8, xc + chk_sz - 0.8, mid_y + 0.8)
                    c.line(xc + 0.8, mid_y + 0.8, xc + chk_sz - 0.8, mid_y + chk_sz - 0.8)

                # Letra en negrita — roja si marcada, negra si no
                c.setFillColor(colors.HexColor("#CC1F1F") if is_marked else _BLACK)
                c.setFont("Helvetica-Bold", 8)
                c.drawString(xc + chk_sz + 3, mid_y + (chk_sz - 6) / 2, code)

            y -= jia_h
        # Supresión limpia: sin calibración, la barra sube naturalmente


        return y







    # --- SECCION 5: Pruebas Metrologicas -------------------------------------

    def _draw_pruebas(self, c, y: float, rep, exc, exac, os_data: dict) -> float:
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(self.ML, y, "PRUEBAS METROLOGICAS")
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 8

        # Normalizar aplica_excentricidad (puede llegar como bool, str o int)
        aplica_exc = _parse_aplica_excentricidad(os_data)
        # Tipo de instrumento no apto: priorizar motivo_no_aplica guardado explicitamente
        _motivo_directo = str(os_data.get("motivo_no_aplica") or "").strip()
        tipo_no = _motivo_directo if _motivo_directo else _inferir_tipo_no_aplica(os_data)

        tipo_inst = str(os_data.get("tipo_instrumento") or os_data.get("tipo_equipo") or "").lower()
        # Un motivo 'Tanque' heredado no aplica si el instrumento ya no es Tanque
        if "tanque" in tipo_no.lower() and "tanque" not in tipo_inst:
            tipo_no = _inferir_tipo_no_aplica({**os_data, "tipo_no_aplica_exc": ""})
        if "tanque" in tipo_inst or _es_modo_sustitucion(os_data):
            aplica_exc = False
            if "tanque" in tipo_inst:
                tipo_no = "tanque"

        if aplica_exc:
            # ── Layout 2 columnas: MITADES IGUALES para que los encabezados se alineen exactamente
            GAP     = 8                         # separacion entre columnas
            left_w  = (self.CW - GAP) / 2       # mitades perfectamente iguales
            right_w = left_w                    # MISMO ancho = mismo Y visual
            left_x  = self.ML
            right_x = self.ML + left_w + GAP

            # -- Columna izquierda: Repetibilidad + Excentricidad
            y_left = y   # mismo punto de partida que la derecha
            y_left = self._draw_repetibilidad_table(c, left_x, y_left, left_w, rep, os_data)
            y_left -= 6
            y_left = self._draw_metrol_table(c, left_x, y_left, left_w, "EXCENTRICIDAD", exc, os_data)

            # -- Columna derecha: Exactitud
            y_right = y  # mismo punto de partida exacto
            y_right = self._draw_exactitud_table(c, right_x, y_right, right_w, exac, os_data)

            y_right -= 4
            # -- Croquis de posiciones (debajo de Exactitud, columna derecha)
            geo = (os_data.get("geometria_plataforma") or "").lower()
            CROQUIS_H = 62   # altura fija compacta del croquis
            self._draw_eccentricity_diagram(
                c, right_x, y_right, right_w, CROQUIS_H, geo, os_data
            )
            y_right -= (CROQUIS_H + 4)

            # Línea divisoria vertical exactamente centrada entre columnas
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            div_x = self.ML + left_w + GAP / 2
            c.line(div_x, y, div_x, min(y_left, y_right) - 4)

            return min(y_left, y_right) - 8

        else:
            # ── Layout SIN EXCENTRICIDAD (Tanque con Sustitución)
            GAP = 8
            left_w = 200
            right_w = self.CW - left_w - GAP
            left_x = self.ML
            right_x = self.ML + left_w + GAP

            y_left = self._draw_repetibilidad_table(c, left_x, y, left_w, rep, os_data)
            y_left -= 6

            # Recuadro NO APTO para excentricidad con dibujo vectorial del tipo de instrumento
            y_left = self._draw_no_aplica_exc_box(c, left_x, y_left, left_w, tipo_no)

            # Tabla SUSTITUTO | PESO únicamente si existen registros con peso > 0
            # En FÍSICO: si aplica Sustituto, dibujar la tabla con filas en blanco.
            if os_data and (self._tiene_sustitutos_validos(os_data)
                            or self._sustituto_aplica_fisico(os_data)):
                y_left -= 6
                y_left = self._draw_elementos_sustitucion(c, left_x, y_left, left_w, os_data)

            y_right = self._draw_exactitud_table(c, right_x, y, right_w, exac, os_data)

            # Línea divisoria vertical centrada
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            div_x = self.ML + left_w + GAP / 2
            c.line(div_x, y, div_x, min(y_left, y_right) - 4)

            return min(y_left, y_right) - 8


    def _draw_eccentricity_diagram(self, c, x: float, y_top: float, w: float,
                                    total_h: float, geo: str, os_data: dict) -> None:
        """
        Bloque de 3 diagramas tecnicos de excentricidad (fiel a hoja de referencia).
        Sin titulo "CROQUIS". Cabecera minima con subtitulo de seccion.
        geo: 'cuadrada' | 'circular' | 'camionera' | None (Libre -> 3 casillas vacias)
        """
        from reportlab.lib.colors import HexColor
        _BORDER  = HexColor("#CCCCCC")
        _DOT     = HexColor("#C8102E")
        _TEXT    = HexColor("#1D1D1F")
        _GRAY    = HexColor("#888888")
        _BG      = HexColor("#FAFAFA")
        _SHAPE   = HexColor("#F0F0F0")
        _DLINE   = HexColor("#AAAAAA")
        _CHK_ON  = HexColor("#C8102E")
        _CHK_OFF = HexColor("#AAAAAA")

        geo_raw = str(geo or (os_data or {}).get("geometria_excentricidad") or (os_data or {}).get("geometria_plataforma") or "").strip().lower()
        _tipo_raw = str((os_data or {}).get("tipo_instrumento") or "").lower()
        if not geo_raw:
            if "camion" in _tipo_raw or "ferro" in _tipo_raw or "puente" in _tipo_raw:
                geo_key = "camionera"
            elif "circ" in _tipo_raw:
                geo_key = "circular"
            else:
                geo_key = "cuadrada"
        else:
            geo_key = geo_raw
        n_sec    = int((os_data or {}).get("num_secciones") or (os_data or {}).get("secciones_camionera") or 4)

        # ── Contenedor exterior ───────────────────────────────────────────────
        c.setFillColor(_BG)
        c.setStrokeColor(_BORDER)
        c.setLineWidth(0.5)
        c.rect(x, y_top - total_h, w, total_h, fill=1, stroke=1)

        # ── Titulo de seccion (muy compacto, sin la palabra CROQUIS) ──────────
        hdr_h = 10
        c.setFillColor(HexColor("#E5E5EA"))
        c.rect(x, y_top - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_TEXT)
        c.setFont("Helvetica-Bold", 5.5)
        c.drawCentredString(x + w / 2, y_top - hdr_h + 3.5,
                            "POSICIONES DE EXCENTRICIDAD")

        # Area de dibujo bajo la cabecera
        body_top = y_top - hdr_h
        body_h   = total_h - hdr_h
        pad      = 4

        # 3 paneles iguales separados por lineas finas
        lbl_h   = 9          # altura reservada para checkbox + texto al pie
        chk_sz  = 5.5        # cuadrado del checkbox
        panel_w = w / 3

        # Espacio de dibujo dentro de cada panel
        draw_top  = body_top - pad
        draw_h    = body_h - 2 * pad - lbl_h
        dot_r     = 2.2

        def sep_line(px):
            """Linea divisoria vertical entre paneles."""
            c.setStrokeColor(_BORDER)
            c.setLineWidth(0.4)
            c.line(px, body_top, px, body_top - body_h)

        def fdot(px, py):
            c.setFillColor(_DOT)
            c.setStrokeColor(_DOT)
            c.circle(px, py, dot_r, fill=1, stroke=0)

        def num_label(px, py, txt, dx=2.5, dy=-1.5):
            c.setFillColor(_TEXT)
            c.setFont("Helvetica-Bold", 5)
            c.drawString(px + dx, py + dy, txt)

        def checkbox_row(pcx, y_bottom, label, checked):
            """Checkbox + texto centrado en la parte inferior del panel."""
            lw = c.stringWidth(label, "Helvetica-Bold", 5.5) + chk_sz + 3
            lx = pcx - lw / 2
            # cuadrito
            c.setStrokeColor(_CHK_ON if checked else _CHK_OFF)
            c.setFillColor(HexColor("#FFFFFF"))
            c.setLineWidth(0.8 if checked else 0.5)
            c.rect(lx, y_bottom + 1, chk_sz, chk_sz, fill=1, stroke=1)
            if checked:
                c.setStrokeColor(_CHK_ON)
                c.setLineWidth(1.0)
                c.line(lx + 0.8, y_bottom + chk_sz - 0.5,
                       lx + chk_sz - 0.8, y_bottom + 1.5)
                c.line(lx + 0.8, y_bottom + 1.5,
                       lx + chk_sz - 0.8, y_bottom + chk_sz - 0.5)
            c.setFillColor(_CHK_ON if checked else _TEXT)
            c.setFont("Helvetica-Bold", 5.5)
            c.drawString(lx + chk_sz + 3, y_bottom + 1.5, label)

        # ── PANEL 1: CUADRADA / RECTANGULAR ──────────────────────────────────
        p1_x  = x
        p1_cx = p1_x + panel_w / 2

        # Rectangulo proporcional con X
        sq_w = min(panel_w * 0.76, draw_h * 1.6)
        sq_h = sq_w * 0.62
        sq_x = p1_cx - sq_w / 2
        sq_y = draw_top - pad - draw_h / 2 - sq_h / 2

        c.setStrokeColor(_DLINE)
        c.setFillColor(_SHAPE)
        c.setLineWidth(0.9)
        c.rect(sq_x, sq_y, sq_w, sq_h, fill=1, stroke=1)
        # Diagonales X (raya continua como en la referencia)
        c.setStrokeColor(_DLINE)
        c.setLineWidth(0.6)
        c.line(sq_x, sq_y, sq_x + sq_w, sq_y + sq_h)
        c.line(sq_x + sq_w, sq_y, sq_x, sq_y + sq_h)

        # Puntos en esquinas y centro (Regla metrológica: 1 Centro, 2 TL, 3 TR, 4 BR, 5 BL)
        p1_pts = [
            (p1_cx,       sq_y + sq_h / 2, "1", 2, -2), # 1: Centro
            (sq_x,        sq_y + sq_h,     "2", -6, 0), # 2: Sup-Izq
            (sq_x + sq_w, sq_y + sq_h,     "3",  2, 0), # 3: Sup-Der
            (sq_x + sq_w, sq_y,            "4",  2, -5),# 4: Inf-Der
            (sq_x,        sq_y,            "5", -6, -5),# 5: Inf-Izq
        ]
        for px, py, t, dx, dy in p1_pts:
            fdot(px, py)
            num_label(px, py, t, dx, dy)

        sep_line(p1_x + panel_w)
        # Camionera detectada por geo O por tipo_instrumento
        _es_camionera = ("camionera" in geo_key or "ferro" in geo_key or "camionera" in _tipo_raw
                         or "puente" in _tipo_raw or "ferro" in _tipo_raw)
        _is_circular = not _es_camionera and ("circular" in geo_key or "circular" in _tipo_raw)
        _is_plataforma = not _es_camionera and not _is_circular
        checkbox_row(p1_cx, body_top - body_h + 1,
                     "Plataforma", _is_plataforma)

        # ── PANEL 2: CIRCULAR / ELIPSE ────────────────────────────────────────
        p2_x  = x + panel_w
        p2_cx = p2_x + panel_w / 2
        p2_cy = draw_top - pad - draw_h / 2

        # Elipse vectorial (simulada con circulo escalado via transformacion)
        ry = min(draw_h * 0.38, 16)
        rx = min(panel_w * 0.36, ry * 1.5)

        c.saveState()
        c.translate(p2_cx, p2_cy)
        c.scale(rx / ry, 1.0)
        c.setStrokeColor(_DLINE)
        c.setFillColor(_SHAPE)
        c.setLineWidth(0.9)
        c.circle(0, 0, ry, fill=1, stroke=1)
        c.restoreState()

        # Lineas de cruz interna (proporcional a elipse)
        c.setStrokeColor(_DLINE)
        c.setLineWidth(0.5)
        c.line(p2_cx - rx, p2_cy, p2_cx + rx, p2_cy)   # horizontal
        c.line(p2_cx, p2_cy - ry, p2_cx, p2_cy + ry)   # vertical

        # Puntos en cardinales y centro (Regla metrológica: 1 Centro, 2 Norte, 3 Este, 4 Sur, 5 Oeste)
        p2_pts = [
            (p2_cx,      p2_cy,      "1",  2, -2),   # 1: Centro
            (p2_cx,      p2_cy + ry, "2",  2,  1),   # 2: Norte (12h)
            (p2_cx + rx, p2_cy,      "3",  2, -2),   # 3: Este (3h)
            (p2_cx,      p2_cy - ry, "4",  2, -7),   # 4: Sur (6h)
            (p2_cx - rx, p2_cy,      "5", -7, -2),   # 5: Oeste (9h)
        ]
        for px, py, t, dx, dy in p2_pts:
            fdot(px, py)
            num_label(px, py, t, dx, dy)

        sep_line(p2_x + panel_w)
        checkbox_row(p2_cx, body_top - body_h + 1,
                     "Circular", _is_circular)

        # ── PANEL 3: CAMIONERA / SECCIONES (tabla de celdas) ─────────────────
        p3_x  = x + 2 * panel_w
        p3_cx = p3_x + panel_w / 2

        tbl_w  = panel_w * 0.90
        n_show = min(n_sec, 5)   # mostrar max 5 columnas visibles
        cell_w = tbl_w / (n_show + 0.8)  # ultima celda mas angosta (indicando "...")
        cell_h = min(draw_h * 0.45, 20)  # Alto total de la celda para los 3 textos
        tbl_x  = p3_cx - tbl_w / 2
        tbl_y_top = draw_top - pad - (draw_h / 2) + cell_h / 2

        col_labels_top = ["a", "c", "e", "h", "k"]
        col_labels_bot = ["b", "d", "g", "i", "l"]

        c.setStrokeColor(_DLINE)
        c.setLineWidth(0.5)

        for col in range(n_show + 1):
            cw_col = cell_w * (0.5 if col == n_show else 1)
            cx_col = tbl_x + col * cell_w

            # Dibujar rectángulo de la sección
            c.setFillColor(HexColor("#FAFAFA"))
            c.rect(cx_col, tbl_y_top - cell_h, cw_col, cell_h, fill=1, stroke=1)

            if col < n_show:
                c.setFillColor(_TEXT)
                cx_center = cx_col + cw_col / 2

                # ── Posiciones fijas para separar las letras de los números rojos ──
                # Letras fuera de la celda como fue solicitado
                y_top_cell = tbl_y_top          # techo de la celda
                y_bot_cell = tbl_y_top - cell_h # piso de la celda

                # Letra superior (fuera, +3 pt arriba del techo)
                c.setFont("Helvetica-Bold", 5)
                ltr_top = col_labels_top[col] if col < len(col_labels_top) else chr(ord('a') + col * 2)
                c.drawCentredString(cx_center, y_top_cell + 3, ltr_top)

                # Número central (rojo): alineado verticalmente al centro
                c.setFont("Helvetica-Bold", 5.5)
                c.setFillColor(_DOT)
                num_lbl = str(col + 1) if col < n_show - 1 else "N"
                c.drawCentredString(cx_center, y_bot_cell + cell_h / 2 - 2, num_lbl)

                # Letra inferior (fuera, -6 pt debajo del piso)
                c.setFont("Helvetica-Bold", 5)
                c.setFillColor(_TEXT)
                ltr_bot = col_labels_bot[col] if col < len(col_labels_bot) else chr(ord('b') + col * 2)
                c.drawCentredString(cx_center, y_bot_cell - 6, ltr_bot)
            else:
                # Columna "..." indicadora de más secciones
                c.setFillColor(_GRAY)
                c.setFont("Helvetica", 4.5)
                c.drawCentredString(cx_col + cw_col / 2, tbl_y_top - cell_h / 2 - 1.5, "...")

        checkbox_row(p3_cx, body_top - body_h + 1,
                     f"Camionera ({n_sec} Sec.)", _es_camionera)


    def _draw_repetibilidad_table(self, c, x, y, w, data, os_data: dict = None) -> float:
        """Tabla de Repetibilidad con 4 columnas: VALOR | L.INICIAL | L.FINAL | ERR.MÁX.TOL.

        Utiliza la división mínima d para formatear valores con la precisión exacta.
        Celdas sin datos se cancela con diagonal '/'.
        ERR.MÁX.TOL. se calcula automáticamente según OIML R 76 si no viene guardado.
        """
        # Obtener d de los datos de la OS
        d_raw = (os_data or {}).get('div_minima', '') if os_data else ''
        d = parse_d(str(d_raw)) if d_raw else None

        col_widths = [w * 0.22, w * 0.26, w * 0.26, w * 0.26]   # 4 columnas
        row_h = 16
        hdr_h = 16

        # Título principal (barra oscura)
        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(x + w / 2, y - hdr_h + 5, "REPETIBILIDAD")
        y -= hdr_h

        # Cabecera de columnas (5 columnas) — con unidad de medida
        _u = str((os_data or {}).get("unidad_medida") or "kg").strip() or "kg"
        cols = ["N", f"CARGA ({_u})", f"L. INICIAL ({_u})", f"L. FINAL ({_u})", f"ERROR ({_u})"]
        col_widths = [w * 0.08, w * 0.22, w * 0.24, w * 0.24, w * 0.22]   # 5 columnas
        c.setFillColor(_TBL_HDR)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.0)
        cx = x
        for col_lbl, cw in zip(cols, col_widths):
            c.drawCentredString(cx + cw / 2, y - row_h + 5, col_lbl)
            cx += cw

        # Líneas verticales del encabezado
        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)
        cx_line = x
        for cw in col_widths[:-1]:
            cx_line += cw
            c.line(cx_line, y, cx_line, y - row_h)
        y -= row_h

        n_rows = max(len(data), 3) if data else 3
        for i in range(n_rows):
            bg = _GRAY_LIGHT if i % 2 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)

            row = data[i] if data and i < len(data) else {}
            carga = row.get("valor_kg")
            ini   = row.get("lectura_inicial")
            fin   = row.get("lectura_final")
            error_val = None
            _sf = self._seguro_float
            if fin is not None and carga is not None:
                try:
                    error_val = _sf(fin) - _sf(carga)
                except Exception:
                    pass

            cell_vals = [
                (str(i + 1) if i < len(data) and carga is not None else None),
                (formato_miles_espacio(fmt_patron(carga)) if carga is not None else None),
                (formato_miles_espacio(fmt(ini, d)) if ini is not None else None),
                (formato_miles_espacio(fmt(fin, d)) if fin is not None else None),
                (formato_miles_espacio(fmt(error_val, d)) if error_val is not None else (formato_miles_espacio(fmt(0, d)) if fin is not None else None)),
            ]

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 8)
            col_widths_rep = [w * 0.08, w * 0.22, w * 0.24, w * 0.24, w * 0.22]
            cx = x
            # REGLA: solo dibujar diagonal en modalidad DIGITAL explícita.
            # Si os_data es None o modalidad no está definida → tratar como FÍSICO (seguro).
            _modalidad_up = str((os_data or {}).get("modalidad") or "").upper().strip()
            _is_dig_rep = self._es_digital(os_data)  # norm. acentos: FISICO/FÍSICO/Fisico = False
            for j, (val_str, cw_col) in enumerate(zip(cell_vals, col_widths_rep)):
                cell_x = cx
                cell_y = y - row_h
                if val_str is None:
                    if _is_dig_rep:  # físico: celda en blanco; digital: diagonal
                        self._draw_cancel_slash(c, cell_x, cell_y, cw_col, row_h)
                else:
                    c.drawCentredString(cell_x + cw_col / 2, cell_y + 5, val_str)
                cx += cw_col

            c.setStrokeColor(_TBL_BORDER)
            c.setLineWidth(0.3)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            col_widths_rep2 = [w * 0.08, w * 0.22, w * 0.24, w * 0.24, w * 0.22]
            cx_line = x
            for cw_col in col_widths_rep2[:-1]:
                cx_line += cw_col
                c.line(cx_line, y, cx_line, y - row_h)
            y -= row_h

        # Fila footer: Error Máximo Encontrado
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(x + 3, y - row_h + 6, "ERROR MÁXIMO ENCONTRADO:")
        d_rep = parse_d(str(d_raw)) if d_raw else None
        d_dec_rep = self._get_decimals(d_raw) if d_raw else 0
        errors = []
        for r in (data or []):
            lf    = _validar_num(r.get("lectura_final"))
            li    = _validar_num(r.get("lectura_inicial"))
            cargo = _validar_num(r.get("valor_kg"))
            if lf is not None and cargo is not None:
                errors.append(abs(lf - cargo))
        # REGLA FÍSICA: cuando modalidad no es DIGITAL, pie en blanco (incluye acentos).
        _is_fisico_rep = not self._es_digital(os_data)   # blanco a menos que sea DIGITAL explícito
        if errors:
            if _is_fisico_rep:
                pass  # físico: celda en blanco
            else:
                c.setFillColor(_RED)
                c.drawRightString(x + w - 3, y - row_h + 6, self._fmt(max(errors), d_dec_rep))
        else:
            if not _is_fisico_rep:
                # Digital sin datos: mostrar 0 formateado
                c.setFillColor(_RED)
                c.drawRightString(x + w - 3, y - row_h + 6, self._fmt(0, d_dec_rep))
            # Físico sin datos: celda en blanco para llenado manual
        y -= row_h
        return y

    def _draw_no_aplica_exc_box(self, c, x: float, y: float, w: float, tipo_no: str) -> float:
        """
        Dibuja un recuadro vectorial 'INSTRUMENTO NO APTO PARA PRUEBA DE EXCENTRICIDAD'
        con dibujo vectorial específico y leyenda oficial por tipo de instrumento.

        tipo_no: 'tanque' | 'tolva' | 'gancho' | 'patin'
        Retorna la posición Y tras el recuadro.
        """
        from reportlab.lib.colors import HexColor
        _BOX_BORDER = HexColor("#FFCCCC")
        _BOX_BG     = HexColor("#FFF8F8")
        _ICON_COLOR = HexColor("#C8102E")
        _TEXT_COLOR = HexColor("#7A0010")
        _ICON_STRUCT = HexColor("#8B0000")  # estructura del dibujo

        total_h = 75 # Altura máxima solicitada
        hdr_h   = 14
        body_h  = total_h - hdr_h
        y_bottom = y - total_h

        tipo = (tipo_no or "tolva").lower()

        # ── Cabecera roja tenue con etiqueta ────────────────────────────────────
        c.setFillColor(_BOX_BORDER)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_TEXT_COLOR)
        c.setFont("Helvetica-Bold", 7.0)
        c.drawCentredString(x + w / 2, y - hdr_h + 4, "EXCENTRICIDAD")

        # ── Cuerpo del recuadro ──────────────────────────────────────────────────
        c.setFillColor(_BOX_BG)
        c.setStrokeColor(_BOX_BORDER)
        c.setLineWidth(1.0)
        c.rect(x, y_bottom, w, body_h, fill=1, stroke=1)

        cx  = x + w / 2

        c.setStrokeColor(_ICON_COLOR)
        c.setFillColor(_ICON_COLOR)

        # ══════════════════════════════════════════════════════
        # DIBUJOS VECTORIALES DIFERENCIADOS
        # ══════════════════════════════════════════════════════
        if "tanque" in tipo:
            msg_lineas = [
                ("INSTRUMENTO NO APTO PARA PRUEBA DE EXCENTRICIDAD", "Helvetica-Bold", 6.5, _ICON_COLOR),
                (f"B\u00e1scula tipo: {tipo.title()} \u2014 pesaje de carga est\u00e1tica", "Helvetica-Oblique", 5.5, colors.HexColor("#555555")),
                ("No aplica prueba de excentricidad.", "Helvetica-Oblique", 5.5, colors.HexColor("#555555")),
            ]
            
            # Calcular icy dinámicamente para que el ícono flote en el espacio sobrante
            total_text_h = sum(fsize + 2.5 for _, _, fsize, _ in msg_lineas)
            icon_space_bottom = y_bottom + 6 + total_text_h
            icon_space_top = y_bottom + body_h
            icy = (icon_space_bottom + icon_space_top) / 2
            
            # ── TANQUE: cuerpo cilíndrico + celdas de apoyo laterales ──────────
            c.setLineWidth(1.8)
            c.saveState()
            c.translate(cx, icy)
            c.scale(0.57, 0.57) # Escalar a 28pt altura total según solicitud
            c.translate(-cx, -icy)
            # Elipse superior (tapa del tanque)
            c.ellipse(cx - 16, icy + 12, cx + 16, icy + 20, stroke=1, fill=0)
            # Cuerpo cilíndrico (rectángulo lateral)
            c.setFillColor(HexColor("#FFE5E5"))
            c.rect(cx - 16, icy - 10, 32, 22, fill=1, stroke=1)
            c.setFillColor(_ICON_COLOR)
            # Elipse inferior (fondo visible del cilindro)
            c.setLineWidth(1.2)
            c.ellipse(cx - 16, icy - 14, cx + 16, icy - 6, stroke=1, fill=0)
            # Celdas de carga (tripos de apoyo)
            c.setLineWidth(2.0)
            for dx in [-14, 0, 14]:
                c.line(cx + dx, icy - 12, cx + dx - 3, icy - 22)
                c.line(cx + dx, icy - 12, cx + dx + 3, icy - 22)
                c.line(cx + dx - 5, icy - 22, cx + dx + 5, icy - 22)
            # Tubo de entrada (arriba)
            c.setLineWidth(2.5)
            c.line(cx, icy + 19, cx, icy + 27)
            c.setLineWidth(1.5)
            c.line(cx - 5, icy + 27, cx + 5, icy + 27)
            c.restoreState()

        elif "patin" in tipo or "transpaleta" in tipo:
            msg_lineas = [
                ("INSTRUMENTO NO APTO PARA", "Helvetica-Bold", 6.5, _ICON_COLOR),
                ("PRUEBA DE EXCENTRICIDAD", "Helvetica-Bold", 6.5, _ICON_COLOR),
                ("(Báscula tipo Patín hidraúlico /", "Helvetica-Oblique", 5.5, HexColor("#555555")),
                ("Transpaleta - NOM-010-SCFI)", "Helvetica-Oblique", 5.5, HexColor("#555555")),
            ]
            total_text_h = sum(fsize + 2.5 for _, _, fsize, _ in msg_lineas)
            icy = (y_bottom + 6 + total_text_h + y_bottom + body_h) / 2
            
            c.saveState()
            c.translate(cx, icy)
            c.scale(0.65, 0.65)
            c.translate(-cx, -icy)
            # ── PATIN / TRANSPALETA: timón + chasis + ruedas + horquillas ─────
            c.setLineWidth(1.8)
            # Chasis principal (rectángulo horizontal bajo)
            c.setFillColor(HexColor("#FFE5E5"))
            c.rect(cx - 18, icy - 3, 36, 8, fill=1, stroke=1)
            c.setFillColor(_ICON_COLOR)
            # Horquillas (rectángulos delgados proyectando hacia adelante)
            c.setLineWidth(1.5)
            for dy_fork in [-10, -2]:
                c.setFillColor(HexColor("#FFE5E5"))
                c.rect(cx + 2, icy + dy_fork - 7, 20, 5, fill=1, stroke=1)
                c.setFillColor(_ICON_COLOR)
            # Rueda trasera
            c.saveState()
            c.setFillColor(HexColor("#FFE5E5"))
            c.circle(cx - 14, icy - 8, 5, fill=1, stroke=1)
            c.setFillColor(_ICON_COLOR)
            c.circle(cx - 14, icy - 8, 2, fill=1, stroke=0)
            c.restoreState()
            # Ruedas delanteras (horquillas)
            for yf in [icy - 14, icy - 6]:
                c.setFillColor(HexColor("#FFE5E5"))
                c.circle(cx + 20, yf, 3.5, fill=1, stroke=1)
                c.setFillColor(_ICON_COLOR)
                c.circle(cx + 20, yf, 1.5, fill=1, stroke=0)
            # Timón (brazo inclinado arriba-izquierda)
            c.setStrokeColor(_ICON_COLOR)
            c.setLineWidth(2.5)
            p = c.beginPath()
            p.moveTo(cx - 12, icy + 5)
            p.curveTo(cx - 18, icy + 10, cx - 20, icy + 20, cx - 15, icy + 26)
            c.drawPath(p, stroke=1, fill=0)
            # Manija horizontal del timón
            c.setLineWidth(2.0)
            c.line(cx - 22, icy + 26, cx - 8, icy + 26)
            c.restoreState()

        elif "gancho" in tipo or "grua" in tipo:
            msg_lineas = [
                ("INSTRUMENTO NO APTO PARA", "Helvetica-Bold", 6.5, _ICON_COLOR),
                ("PRUEBA DE EXCENTRICIDAD", "Helvetica-Bold", 6.5, _ICON_COLOR),
                ("(Báscula Grúa / Gancho Din-", "Helvetica-Oblique", 5.5, HexColor("#555555")),
                ("amométrico – Un solo punto de carga)", "Helvetica-Oblique", 5.5, HexColor("#555555")),
            ]
            total_text_h = sum(fsize + 2.5 for _, _, fsize, _ in msg_lineas)
            icy = (y_bottom + 6 + total_text_h + y_bottom + body_h) / 2
            
            c.saveState()
            c.translate(cx, icy)
            c.scale(0.65, 0.65)
            c.translate(-cx, -icy)
            # ── GANCHO / GRUA: dinamometro + grillete + gancho curvo ────────────
            c.setLineWidth(1.8)
            # Barra horizontal superior (viga de la grúa)
            c.setFillColor(HexColor("#FFE5E5"))
            c.rect(cx - 18, icy + 22, 36, 6, fill=1, stroke=1)
            c.setFillColor(_ICON_COLOR)
            c.setLineWidth(1.5)
            c.line(cx - 18, icy + 22, cx - 18, icy + 28)
            c.line(cx + 18, icy + 22, cx + 18, icy + 28)
            # Cadena / cable
            c.setLineWidth(1.5)
            c.setDash([2, 2])
            c.line(cx, icy + 22, cx, icy + 14)
            c.setDash()
            # Cuerpo del dinamometro
            c.setFillColor(HexColor("#FFE5E5"))
            c.ellipse(cx - 8, icy + 4, cx + 8, icy + 14, stroke=1, fill=1)
            c.setFillColor(_ICON_COLOR)
            # Caratula del dinamometro
            c.setLineWidth(0.8)
            c.ellipse(cx - 5, icy + 6, cx + 5, icy + 12, stroke=1, fill=0)
            c.setLineWidth(1.2)
            c.line(cx, icy + 9, cx + 3, icy + 11)
            # Grillete (U invertida)
            c.setLineWidth(2.2)
            c.line(cx - 5, icy + 4, cx - 5, icy - 1)
            c.line(cx + 5, icy + 4, cx + 5, icy - 1)
            c.arc(cx - 5, icy - 4, cx + 5, icy + 0, startAng=180, extent=180)
            # Gancho curvo (bezier)
            c.setLineWidth(2.5)
            p2 = c.beginPath()
            p2.moveTo(cx + 5, icy - 2)
            p2.curveTo(cx + 14, icy - 8, cx + 14, icy - 20, cx + 3, icy - 20)
            p2.curveTo(cx - 4, icy - 20, cx - 6, icy - 14, cx - 2, icy - 14)
            c.drawPath(p2, stroke=1, fill=0)
            c.restoreState()

        else:
            msg_lineas = [
                ("INSTRUMENTO NO APTO PARA PRUEBA DE EXCENTRICIDAD", "Helvetica-Bold", 6.5, _ICON_COLOR),
                ("(Báscula tipo Tolva / Silo dosificador con carga suspendida)", "Helvetica-Oblique", 5.5, HexColor("#555555")),
            ]
            total_text_h = sum(fsize + 2.5 for _, _, fsize, _ in msg_lineas)
            icy = (y_bottom + 6 + total_text_h + y_bottom + body_h) / 2
            
            c.saveState()
            c.translate(cx, icy)
            c.scale(0.65, 0.65)
            c.translate(-cx, -icy)
            # ── TOLVA (default): tolva cónica reducida + pico + soportes ─────────
            # Altura del cono + cilindro = 45 pt (reducido para no amontonarse)
            c.setLineWidth(1.5)
            # Cuerpo cilíndrico superior
            c.ellipse(cx - 14, icy + 8, cx + 14, icy + 16, stroke=1, fill=0)
            # Paredes de la tolva (trapecio invertido)
            c.setFillColor(HexColor("#FFE5E5"))
            p_tolva = c.beginPath()
            p_tolva.moveTo(cx - 14, icy + 12)
            p_tolva.lineTo(cx - 6,  icy - 8)
            p_tolva.lineTo(cx + 6,  icy - 8)
            p_tolva.lineTo(cx + 14, icy + 12)
            c.drawPath(p_tolva, stroke=1, fill=1)
            c.setFillColor(_ICON_COLOR)
            # Pico de descarga inferior
            c.setLineWidth(2)
            c.line(cx - 3, icy - 8, cx - 3, icy - 14)
            c.line(cx + 3, icy - 8, cx + 3, icy - 14)
            c.line(cx - 6, icy - 14, cx + 6, icy - 14)
            # Barras de soporte lateral
            c.setLineWidth(1)
            c.line(cx - 18, icy + 14, cx - 14, icy + 12)
            c.line(cx + 14, icy + 12, cx + 18, icy + 14)
            c.restoreState()

        # ── Texto centrado alineado a la parte baja (y_bottom + 4) ──────────────
        total_text_h = sum(fsize + 2.5 for _, _, fsize, _ in msg_lineas)
        ty = y_bottom + 4 + total_text_h - msg_lineas[0][2]
        
        for text, font_name, font_size, text_color in msg_lineas:
            c.setFillColor(text_color)
            c.setFont(font_name, font_size)
            c.drawCentredString(cx, ty, text)
            ty -= (font_size + 2.5)

        return y_bottom

    def _draw_metrol_table(self, c, x, y, w, titulo, data, os_data) -> float:
        """Tabla Excentricidad: POSICION | L. INICIAL | L. FINAL | ERROR.
        5 filas por defecto (Centro + 4 Esquinas). Diagonal '/' si L.INICIAL es None.
        Error por fila = |L.Final - carga_prueba|. ERROR MAX en el pie.
        """
        # 4 columnas: POSICION | L. INICIAL | L. FINAL | ERROR
        col_widths = [w * 0.26, w * 0.24, w * 0.25, w * 0.25]
        hdr_h = 14

        # ── Número de filas: len(data) → puntos_excentricidad → 5 ──────────
        _nf = len(data) or os_data.get("puntos_excentricidad") \
              or os_data.get("filas_excentricidad") or 5
        try:
            n_rows = max(1, min(int(_nf), 10))
        except (TypeError, ValueError):
            n_rows = 5

        # ── Carga de prueba global ──────────────────────────────────────────
        _sf = self._seguro_float
        _carga_global = (
            os_data.get("carga_prueba_excentricidad")
            or os_data.get("carga_excentricidad")
        )
        if _carga_global is None and data:
            for _r in data:
                _c = _r.get("carga")
                if _c is not None and str(_c).strip():
                    _carga_global = _c
                    break

        # ── Altura de fila dinámica ─────────────────────────────────────────
        row_h = 12.5 if n_rows <= 5 else (11.5 if n_rows == 6 else 10.0)
        data_font_size = 7.5 if n_rows <= 6 else 6.5

        # ── Encabezado oscuro de sección ────────────────────────────────────
        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(x + w / 2, y - hdr_h + 4, titulo)
        y -= hdr_h

        # ── Sub-cabecera de columnas (con unidad de medida) ─────────────────
        _u_exc = str((os_data or {}).get("unidad_medida") or "kg").strip() or "kg"
        cols = ["POSICION", f"L. INICIAL ({_u_exc})", f"L. FINAL ({_u_exc})", f"ERROR ({_u_exc})"]
        c.setFillColor(_TBL_HDR)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 5.5)
        cx = x
        for col, cw in zip(cols, col_widths):
            c.drawCentredString(cx + cw / 2, y - row_h + max(3, row_h * 0.28), col)
            cx += cw
        # Líneas verticales cabecera
        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)
        cx_line = x
        for cw in col_widths[:-1]:
            cx_line += cw
            c.line(cx_line, y, cx_line, y - row_h)
        y -= row_h

        # ── Geometría para etiquetas Camionera ───────────────────────────────
        geo = (os_data.get("geometria_plataforma") or "").lower()
        tipo_ins_low = (
            (os_data.get("tipo_instrumento") or
             os_data.get("tipo_receptor")    or
             os_data.get("tipo_bascula")     or "")
        ).lower()
        # Detectar camionera por geometria O por tipo de instrumento
        _es_camionera = ("camionera" in geo or "puente" in geo or
                          "camionera" in tipo_ins_low or "puente" in tipo_ins_low)
        import re as _re
        # Etiquetas según tipo de instrumento
        if _es_camionera:
            _n_sec = os_data.get("secciones_camionera") or os_data.get("num_secciones") or n_rows
            try: _n_sec = max(1, int(_n_sec))
            except Exception: _n_sec = n_rows
            _POSICIONES_STD = [f"Sección {i+1}" for i in range(max(_n_sec, 10))]
        elif "circular" in geo:
            _POSICIONES_STD = ["Centro", "Norte", "Sur", "Este", "Oeste",
                               "Posición 6", "Posición 7", "Posición 8"]
        else:  # cuadrada / plataforma (default)
            _POSICIONES_STD = ["Centro", "Esquina 1", "Esquina 2", "Esquina 3",
                               "Esquina 4", "Posición 5", "Posición 6"]

        d_dec = self._get_decimals(os_data.get('div_minima'))
        errors_all = []

        # ── Filas de datos ───────────────────────────────────────────────────
        for i in range(n_rows):
            bg = _GRAY_LIGHT if i % 2 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)

            row = data[i] if i < len(data) else {}

            # Etiqueta de posición (eliminar sufijos DF/DT/TF/TT)
            if "posicion_label" in row and row["posicion_label"]:
                raw_lbl = _re.sub(r'\s*\(?(DF|DT|TF|TT)\)?\s*$', '',
                                  str(row["posicion_label"]),
                                  flags=_re.IGNORECASE).strip()
                pos_label = raw_lbl or (_POSICIONES_STD[i] if i < len(_POSICIONES_STD) else str(i+1))
            elif i < len(_POSICIONES_STD):
                pos_label = _POSICIONES_STD[i]
            else:
                pos_label = str(i + 1)

            ini_val   = row.get("lectura_inicial")
            fin_val   = row.get("lectura_final")
            # REGLA METROLÓGICA: carga_row es la carga de prueba global únicamente.
            # lectura_inicial NO se usa como fallback para calcular el error.
            carga_row = _carga_global or row.get("carga")

            # Calcular error de esta fila: |L.FINAL - Carga de Prueba|
            # El error se calcula aunque lectura_inicial sea None (diagonal "/")
            error_val = None
            if fin_val is not None and str(fin_val).strip() and \
               carga_row is not None and str(carga_row).strip():
                error_val = _sf(fin_val) - _sf(carga_row)
                errors_all.append(abs(error_val))

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", data_font_size)
            cx = x

            # Col 0: POSICION
            c.drawCentredString(cx + col_widths[0] / 2,
                                y - row_h + max(2.5, row_h * 0.28), pos_label)
            cx += col_widths[0]

            # Col 1: L. INICIAL (diagonal SOLO en digital con datos; físico = blanco)
            # REGLA: solo diagonal en DIGITAL explícito; norm. acentos vía _es_digital.
            _is_digital_form = self._es_digital(os_data)
            if ini_val is None or str(ini_val).strip() == "":
                if _is_digital_form:
                    self._draw_cancel_slash(c, cx, y - row_h, col_widths[1], row_h)
                # else: celda en blanco para llenado manual
            else:
                c.drawCentredString(cx + col_widths[1] / 2,
                                    y - row_h + max(2.5, row_h * 0.28),
                                    self._fmt(ini_val, d_dec))
            cx += col_widths[1]

            # Col 2: L. FINAL (diagonal SOLO en digital con datos; físico = blanco)
            if fin_val is None or str(fin_val).strip() == "":
                if _is_digital_form:
                    self._draw_cancel_slash(c, cx, y - row_h, col_widths[2], row_h)
                # else: celda en blanco para llenado manual
            else:
                c.drawCentredString(cx + col_widths[2] / 2,
                                    y - row_h + max(2.5, row_h * 0.28),
                                    self._fmt(fin_val, d_dec))
            cx += col_widths[2]

            if error_val is not None:
                c.setFillColor(_RED if abs(error_val) > 0 else _BLACK)
                c.setFont("Helvetica-Bold", data_font_size)
                c.drawCentredString(cx + col_widths[3] / 2,
                                    y - row_h + max(2.5, row_h * 0.28),
                                    self._fmt(error_val, d_dec))
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", data_font_size)
            else:
                # REGLA FÍSICA: en modalidad Físico la celda ERROR vacía se deja
                # en blanco para que el técnico anote el valor a mano.
                # En digital, se dibuja la diagonal de cancelación.
                if _is_digital_form:
                    self._draw_cancel_slash(c, cx, y - row_h, col_widths[3], row_h)

            # Bordes de fila
            c.setStrokeColor(_TBL_BORDER)
            c.setLineWidth(0.3)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            cx_line = x
            for cw in col_widths[:-1]:
                cx_line += cw
                c.line(cx_line, y, cx_line, y - row_h)
            y -= row_h

        # ── Fila pie: ERROR MÁXIMO ENCONTRADO ───────────────────────────────
        footer_h = row_h
        c.setFillColor(_GRAY_LIGHT)
        c.rect(x, y - footer_h, w, footer_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", max(5.5, data_font_size - 0.5))
        c.drawString(x + 3, y - footer_h + max(2, footer_h * 0.28),
                     "ERROR MAXIMO ENCONTRADO:")
        d_dec_exc = self._get_decimals((os_data or {}).get('div_minima'))
        _is_fisico_exc = not self._es_digital(os_data)  # True cuando FISICO/FÍSICO/Fisico/None
        if errors_all and not _is_fisico_exc:
            # Digital con datos: mostrar error máximo en rojo
            err_max_txt = self._fmt(max(errors_all), d_dec_exc)
            c.setFillColor(_RED)
            c.drawRightString(x + w - 3, y - footer_h + max(2, footer_h * 0.28), err_max_txt)
        elif not _is_fisico_exc:
            # Digital sin datos: 0 formateado
            c.setFillColor(_RED)
            c.drawRightString(x + w - 3, y - footer_h + max(2, footer_h * 0.28),
                              self._fmt(0.0, d_dec_exc))
        # Físico: celda del error queda en blanco para llenado manual
        y -= footer_h

        return y

    def _draw_exactitud_table(self, c, x, y, w, data, os_data=None) -> float:
        # ── Modo especial: Calibración por Enlaces de Sustitución ──────────────────────
        if os_data and _es_modo_sustitucion(os_data):
            return self._draw_exactitud_enlaces(c, x, y, w, data, os_data)
        # ── Modo estándar ─────────────────────────────────────────────

        _od = os_data or {}

        # Detectar clase automaticamente desde capacidad y division
        clase = clase_desde_os(_od)
        lbl_clase = clase_label(clase)  # ej. 'Clase III (OIML R 76)'

        # Obtener d para formatear lecturas
        d_raw = _od.get('div_minima', '')
        d = parse_d(str(d_raw)) if d_raw else None

        col_widths = [w * 0.08, w * 0.22, w * 0.245, w * 0.245, w * 0.21]
        row_h = 17
        hdr_h = 14

        # Encabezado con clase detectada (sin OIML R 76)
        import re as _re_ex
        _lbl_clean = _re_ex.sub(r'\s*\(.*?\)', '', lbl_clase).strip()
        _clase_txt = str((_od.get("clase_exactitud") or "")).strip()
        if _clase_txt and "clase" in _clase_txt.lower():
            _lbl_clean = _re_ex.sub(r'\s*\(.*?\)', '', _clase_txt).strip()
        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(x + w / 2, y - hdr_h + 4,
                            f"EXACTITUD — {_lbl_clean}")
        y -= hdr_h

        _u_exa = str((_od or {}).get("unidad_medida") or "kg").strip() or "kg"
        cols = ["N", f"NOMINAL ({_u_exa})", f"L. INICIAL ({_u_exa})", f"L. FINAL ({_u_exa})", f"ERROR ({_u_exa})"]
        c.setFillColor(_TBL_HDR)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 5.5)
        cx = x
        for col, cw in zip(cols, col_widths):
            c.drawCentredString(cx + cw / 2, y - row_h + 4, col)
            cx += cw

        # Lineas verticales del encabezado
        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)
        cx_line = x
        for cw in col_widths[:-1]:
            cx_line += cw
            c.line(cx_line, y, cx_line, y - row_h)
        y -= row_h

        n_pts = int(_od.get("filas_exactitud") or _od.get("puntos_exactitud") or 5)

        for i in range(n_pts):
            bg = _GRAY_LIGHT if i % 2 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
            row = data[i] if i < len(data) else {}
            d_dec = self._get_decimals(os_data.get('div_minima') if os_data else None)
            ini_val = _validar_num(row.get("lectura_inicial"))
            fin_val = _validar_num(row.get("lectura_final"))
            nom_val = _validar_num(row.get("valor_nominal"))
            # Calcular error = L.Final - Valor Nominal (solo si ambos son numéricos)
            error_ex = None
            if fin_val is not None and nom_val is not None:
                try:
                    error_ex = fin_val - nom_val
                except Exception:
                    pass
            _is_fisico_ex = not self._es_digital(os_data)  # True para FISICO/FÍSICO/Fisico/None
            _is_dig_ex = not _is_fisico_ex
            # ERROR: mostrar valor calculado; si no hay datos: '0' en digital, VACIO en físico
            _error_cell = (
                self._fmt(error_ex, d_dec) if error_ex is not None
                else (self._fmt(0, d_dec) if _is_dig_ex else None)   # físico = None, no '0'
            )
            vals = [
                str(i + 1),
                self._fmt_int(nom_val),
                self._fmt(ini_val, d_dec) if ini_val is not None else None,
                # L.FINAL: None en físico sin datos (no '' que imprime nada pero ocupa el slot)
                self._fmt(fin_val, d_dec) if fin_val is not None else None,
                _error_cell,
            ]
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 7.5)
            cx = x
            # REGLA: solo diagonal en DIGITAL; norm. acentos.
            _is_dig_ex = self._es_digital(os_data)
            for v, cw_col in zip(vals, col_widths):
                if v is None:
                    if _is_dig_ex:  # físico: celda en blanco; digital: diagonal
                        self._draw_cancel_slash(c, cx, y - row_h, cw_col, row_h)
                else:
                    c.drawCentredString(cx + cw_col / 2, y - row_h + 3.5, v)
                cx += cw_col
            c.setStrokeColor(_TBL_BORDER)
            c.setLineWidth(0.3)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            
            # Inner grid lines (vertical)
            cx_line = x + col_widths[0]
            c.line(cx_line, y, cx_line, y - row_h)
            cx_line += col_widths[1]
            c.line(cx_line, y, cx_line, y - row_h)
            cx_line += col_widths[2]
            c.line(cx_line, y, cx_line, y - row_h)
            
            y -= row_h

        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(x + 3, y - row_h + 4, "ERROR MAXIMO ENCONTRADO:")
        errors_ex = []
        for r in data:
            lf = _validar_num(r.get("lectura_final"))
            vn = _validar_num(r.get("valor_nominal"))
            if lf is not None and vn is not None:
                errors_ex.append(abs(lf - vn))
        d_dec_ex = self._get_decimals(_od.get('div_minima') if _od else None)
        # REGLA FÍSICO: en modalidad Físico el pie ERROR MÁXIMO se deja en blanco
        # (el técnico lo anota a mano). En digital se imprime el valor o '0'.
        _is_fisico_emax = not self._es_digital(_od)   # True para FISICO/FÍSICO/Fisico/None
        if not _is_fisico_emax:          # NUNCA imprimir en físico
            if errors_ex:
                c.drawRightString(x + w - 3, y - row_h + 4, self._fmt(max(errors_ex), d_dec_ex))
            else:
                c.drawRightString(x + w - 3, y - row_h + 4, self._fmt(0, d_dec_ex))
        # Físico: celda del error queda en blanco para llenado manual
        y -= row_h
        return y

    def _tiene_sustitutos_validos(self, os_data: dict) -> bool:
        """Retorna True solo si existen registros con sustituto y peso > 0."""
        if not os_data:
            return False
        sustitutos_raw = os_data.get("sustitutos") or os_data.get("elementos_sustitucion") or []
        if isinstance(sustitutos_raw, str):
            try:
                import json
                sustitutos_raw = json.loads(sustitutos_raw)
            except Exception:
                sustitutos_raw = []
        if isinstance(sustitutos_raw, list):
            for s in sustitutos_raw:
                if isinstance(s, dict):
                    if self._seguro_float(s.get("peso")) > 0:
                        return True
        if self._seguro_float(os_data.get("peso_sustituto")) > 0:
            return True
        return False

    def _sustituto_aplica_fisico(self, os_data: dict) -> bool:
        """True si el formato es FÍSICO (no DIGITAL) y la OS indica que aplica Sustituto
        (bandera explícita o lista de sustitutos configurada, aunque sin pesos)."""
        if not os_data or self._es_digital(os_data):
            return False
        for k in ("aplica_sustituto", "usa_sustituto", "tiene_sustituto"):
            v = os_data.get(k)
            if v is True or str(v).strip().lower() in ("1", "true", "si", "sí", "yes"):
                return True
        raw = os_data.get("sustitutos") or os_data.get("elementos_sustitucion")
        if isinstance(raw, str):
            try:
                import json
                raw = json.loads(raw)
            except Exception:
                raw = None
        return isinstance(raw, list) and len(raw) > 0

    def _draw_elementos_sustitucion(self, c, x: float, y: float, w: float, os_data: dict) -> float:
        """Tabla para Elementos de Carga Sustituta (Sustituto | Peso). Solo se dibuja si peso > 0."""
        sustitutos_raw = os_data.get("sustitutos") or os_data.get("elementos_sustitucion") or []
        if isinstance(sustitutos_raw, str):
            try:
                import json
                sustitutos_raw = json.loads(sustitutos_raw)
            except Exception:
                sustitutos_raw = []

        valid_sustitutos = []
        if isinstance(sustitutos_raw, list):
            for s in sustitutos_raw:
                if isinstance(s, dict):
                    p = self._seguro_float(s.get("peso"))
                    nom = str(s.get("sustituto") or s.get("nombre") or "").strip()
                    if p > 0:
                        valid_sustitutos.append({"sustituto": nom or f"Sustituto {len(valid_sustitutos)+1}", "peso": p})

        if not valid_sustitutos and os_data.get("peso_sustituto"):
            p = self._seguro_float(os_data.get("peso_sustituto"))
            if p > 0:
                valid_sustitutos.append({"sustituto": "Sustituto 1", "peso": p})

        _fisico_blank = False
        if not valid_sustitutos:
            if not self._sustituto_aplica_fisico(os_data):
                return y
            _fisico_blank = True   # FÍSICO: filas en blanco para llenado manual
            _raw_len = len(sustitutos_raw) if isinstance(sustitutos_raw, list) else 0

        from reportlab.lib.colors import HexColor
        _HDR = HexColor("#D9E2F3")
        
        row_h = 13
        hdr_h = 14
        w_sust = w * 0.70
        w_peso = w * 0.30

        c.setFillColor(_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=1)
        c.setFillColor(HexColor("#000000"))
        c.setFont("Helvetica-Bold", 6.5)
        
        c.drawCentredString(x + w_sust / 2, y - hdr_h + 4, "SUSTITUTO")
        c.drawCentredString(x + w_sust + w_peso / 2, y - hdr_h + 4, "PESO")
        
        c.setStrokeColor(HexColor("#333333"))
        c.setLineWidth(0.3)
        c.line(x + w_sust, y, x + w_sust, y - hdr_h)
        y -= hdr_h
        
        n_rows = max(len(valid_sustitutos), 4) if not _fisico_blank else max(_raw_len, 4)
        total_peso = sum(s["peso"] for s in valid_sustitutos)
        
        c.setFont("Helvetica", 6.5)
        for i in range(n_rows):
            c.setFillColor(HexColor("#FFFFFF"))
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
            c.line(x + w_sust, y, x + w_sust, y - row_h)
            
            if i < len(valid_sustitutos):
                s = valid_sustitutos[i]
                c.setFillColor(HexColor("#000000"))
                c.drawString(x + 5, y - row_h + 3.5, str(s["sustituto"]))
                peso_str = self._fmt(s["peso"])
                c.drawRightString(x + w - 5, y - row_h + 3.5, peso_str)
                
            y -= row_h
            
        c.setFillColor(HexColor("#FFFFFF"))
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.line(x + w_sust, y, x + w_sust, y - row_h)
        c.setFillColor(HexColor("#000000"))
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 5, y - row_h + 4, "TOTAL")
        if not _fisico_blank:
            total_str = self._fmt(total_peso)
            c.drawRightString(x + w - 5, y - row_h + 4, total_str)
        y -= row_h
        
        return y

    def _draw_exactitud_enlaces(self, c, x: float, y: float, w: float, data: list, os_data: dict) -> float:
        """
        Tabla de Exactitud en modo 'Calibración por Enlaces de Sustitución' (7 columnas).
        Columnas: [ N | PESAS | AGUA | AGUA + PESAS | INDICACIÓN | REGRESO | ERROR ]
        """
        _ROW_BG    = _WHITE
        _LBL       = _BLACK

        hdr_h     = 16

        _od = os_data or {}

        # Renglones con datos capturados por el técnico
        puntos_validos = []
        for r in (data or []):
            if not isinstance(r, dict):
                continue
            pesas_raw      = r.get("pesas")
            agua_raw       = r.get("agua")
            indicacion_raw = r.get("indicacion") if r.get("indicacion") is not None else r.get("lectura_inicial")
            if (
                (pesas_raw is not None and str(pesas_raw).strip() != "") or
                (agua_raw is not None and str(agua_raw).strip() != "") or
                (indicacion_raw is not None and str(indicacion_raw).strip() != "")
            ):
                puntos_validos.append(r)

        # ── Bifurcación FÍSICO vs DIGITAL ─────────────────────────────────────
        # FÍSICO (impresión en blanco): NUNCA omitir renglones; dibujar exactamente
        #   las N filas configuradas por logística, con celdas vacías.
        # DIGITAL (capturado): omitir los renglones que el técnico dejó vacíos.
        import unicodedata as _ud
        _mod_norm = _ud.normalize(
            "NFKD", str(_od.get("modalidad") or "")
        ).encode("ascii", "ignore").decode().strip().lower()
        _fisico_explicito = (
            _mod_norm in ("fisico", "impresion", "blanco", "calca")
            or bool(_od.get("es_formato_fisico"))
            or bool(_od.get("es_impresion_en_blanco"))
        )
        # Sin modalidad explícita DIGITAL y sin capturas → es plantilla física.
        es_fisico = _fisico_explicito or (not self._es_digital(_od) and not puntos_validos)

        if es_fisico:
            try:
                n_cfg = int(
                    _od.get("num_enlaces_sustitucion")
                    or _od.get("num_enlaces")
                    or _od.get("pts_exactitud")
                    or len(data or [])
                    or 6
                )
            except (TypeError, ValueError):
                n_cfg = 6
            n_cfg = max(1, n_cfg)
            src = [r if isinstance(r, dict) else {} for r in (data or [])]
            # Exactamente n_cfg filas (rellenar con vacías si faltan); sin filtrar.
            display_data = (src + [{}] * n_cfg)[:n_cfg]
        else:
            display_data = puntos_validos if puntos_validos else (data[:1] if data else [])
        num_enlaces = len(display_data)

        if num_enlaces <= 5:
            row_h = 16
        elif num_enlaces <= 8:
            row_h = 13
        else:
            row_h = 11

        data_font_size = 8 if num_enlaces <= 8 else 7
        y_offset_text  = 4 if row_h >= 13 else 3

        col_w = [w * (18/342), w * (52/342), w * (52/342), w * (66/342), w * (56/342), w * (50/342), w * (48/342)]
        col_hdrs = ["N", "PESAS", "AGUA", "AGUA + PESAS", "INDICACIÓN", "REGRESO", "ERROR"]

        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=1)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.5)
        cx_ = x
        for col_lbl, cw_ in zip(col_hdrs, col_w):
            c.drawCentredString(cx_ + cw_ / 2, y - hdr_h + 5, col_lbl)
            cx_ += cw_
        self._draw_col_lines(c, x, y, hdr_h, col_w)
        y -= hdr_h

        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)

        errors = []
        _sf = self._seguro_float

        for idx_row, row in enumerate(display_data):
            n = idx_row + 1
            bg = _ROW_BG if n % 2 != 0 else _GRAY_LIGHT
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
            
            pesas_raw      = row.get("pesas")
            agua_raw       = row.get("agua")
            agua_pesas_raw = row.get("agua_pesas")
            indicacion_raw = row.get("indicacion") if row.get("indicacion") is not None else row.get("lectura_inicial")
            regreso_raw    = row.get("regreso") if row.get("regreso") is not None else row.get("lectura_final")
            error_raw      = row.get("error")

            has_pesas = pesas_raw is not None and str(pesas_raw).strip() != ""
            has_agua  = agua_raw is not None and str(agua_raw).strip() != ""
            has_ap    = agua_pesas_raw is not None and str(agua_pesas_raw).strip() != ""
            has_ind   = indicacion_raw is not None and str(indicacion_raw).strip() != ""

            p_val = _sf(pesas_raw) if has_pesas else None
            a_val = _sf(agua_raw) if has_agua else None

            # (AGUA + PESAS) = Pesas + Agua
            if has_ap:
                ap_val = _sf(agua_pesas_raw)
            elif has_pesas or has_agua:
                ap_val = (p_val or 0.0) + (a_val or 0.0)
            else:
                ap_val = None

            ind_val = _sf(indicacion_raw) if has_ind else None
            reg_val = _sf(regreso_raw) if (regreso_raw is not None and str(regreso_raw).strip() != "") else None

            # ERROR = INDICACIÓN - (AGUA + PESAS)
            if ind_val is not None and ap_val is not None:
                err_val = ind_val - ap_val
            elif error_raw is not None and str(error_raw).strip() != "":
                err_val = _sf(error_raw)
            else:
                err_val = None

            if err_val is not None:
                errors.append(abs(err_val))

            vals = [
                str(n),
                self._fmt(p_val) if p_val is not None else "",
                self._fmt(a_val) if a_val is not None else "",
                self._fmt(ap_val) if ap_val is not None else "",
                self._fmt(ind_val) if ind_val is not None else "",
                self._fmt(reg_val) if reg_val is not None else "",
                self._fmt(err_val) if err_val is not None else ""
            ]
            
            c.setFillColor(_LBL)
            cx_ = x
            for i, (v, cw_) in enumerate(zip(vals, col_w)):
                if i == 0:
                    c.setFont("Helvetica-Bold", min(7.5, data_font_size))
                else:
                    c.setFont("Helvetica", data_font_size)
                c.drawCentredString(cx_ + cw_ / 2, y - row_h + y_offset_text, v)
                cx_ += cw_
                
            self._draw_col_lines(c, x, y, row_h, col_w)
            y -= row_h

        # Fila base de Error Encontrado
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawString(x + 5, y - row_h + 4, "ERROR MÁXIMO ENCONTRADO:")
        
        if errors:
            c.drawRightString(x + w - 5, y - row_h + 4, self._fmt(max(errors)))
            
        y -= row_h
        return y

    def _draw_col_lines(self, c, x: float, y: float, row_h: float, col_w: list) -> None:
        """Dibuja las líneas divisorias verticales de una fila, dado el ancho de cada columna."""
        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)
        cx_ = x
        for cw_ in col_w[:-1]:
            cx_ += cw_
            c.line(cx_, y, cx_, y - row_h)

    def _draw_clase_exactitud(self, c, x, y, w, clase, jia: dict, os_data: dict) -> float:
        """
        Fila de CLASE DE EXACTITUD con celdas proporcionales y checkboxes para Inicial/J/I/A
        """
        jia = jia or {}
        hdr_h   = 13
        check_h = 22
        y -= 3

        # Encabezado gris
        c.setFillColor(_GRAY_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 7)
        c.drawCentredString(x + w / 2, y - hdr_h + 4, "CLASE DE EXACTITUD")
        y -= hdr_h

        # Lógica de tipo de servicio para mostrar Inicial / J / I / A
        _ts_raw = (os_data.get("tipo_servicio_nombre") or os_data.get("tipo_servicio") or "")
        servicio = str(_ts_raw).lower()
        tiene_calibracion = "calibracion" in servicio or "calibración" in servicio

        if tiene_calibracion:
            col_ija = w * 0.40  # 40% del ancho para los 4 checkboxes (Inicial, J, I, A)
        else:
            col_ija = 0         # Sin calibración, las clases ocupan el 100%

        col_w = (w - col_ija) / 4

        c.setFillColor(_GRAY_LIGHT)
        c.rect(x, y - check_h, w, check_h, fill=1, stroke=1)

        # Dibujar casillas Inicial / J / I / A si aplica
        if tiene_calibracion:
            jia_items = [
                ("Inicial", jia.get("inicial")),
                ("J", jia.get("j")),
                ("I", jia.get("i")),
                ("A", jia.get("a")),
            ]
            cw_jia = col_ija / 4
            cx_jia = x
            for lbl_jia, is_sel_jia in jia_items:
                chk_size = 6
                chk_x = cx_jia + 2
                chk_y = y - check_h + (check_h - chk_size) / 2

                if is_sel_jia:
                    c.setFillColor(_RED)
                    c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=0)
                    c.setFillColor(_WHITE)
                    c.setFont("Helvetica-Bold", 5)
                    c.drawCentredString(chk_x + chk_size / 2, chk_y + 1, "V")
                else:
                    c.setFillColor(_WHITE)
                    c.setStrokeColor(_BLACK)
                    c.setLineWidth(0.5)
                    c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=1)

                label_x = chk_x + chk_size + 2
                c.setFillColor(_RED if is_sel_jia else _BLACK)
                c.setFont("Helvetica-Bold", 5.5)
                label_y = y - check_h + (check_h - 5.5) / 2
                c.drawString(label_x, label_y, lbl_jia)
                
                cx_jia += cw_jia

            # Línea vertical divisoria entre J/I/A y Clases
            c.setStrokeColor(_BLACK)
            c.setLineWidth(0.5)
            c.line(x + col_ija, y - check_h, x + col_ija, y)

        # Dibujar clases
        clases = [
            ("ORD",     "IV"),
            ("MEDIA",   "III"),
            ("FINA",    "II"),
            ("ESPECIAL","I"),
        ]

        cx = x + col_ija
        for lbl, codigo in clases:
            is_sel = bool(clase and clase.upper() == codigo.upper())
            bg = colors.HexColor("#FFE5E5") if is_sel else _WHITE
            c.setFillColor(bg)
            c.rect(cx, y - check_h, col_w, check_h, fill=1, stroke=1)

            chk_size = 6
            chk_x = cx + 3
            chk_y = y - check_h + (check_h - chk_size) / 2

            if is_sel:
                c.setFillColor(_RED)
                c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=0)
                c.setFillColor(_WHITE)
                c.setFont("Helvetica-Bold", 5)
                c.drawCentredString(chk_x + chk_size / 2, chk_y + 1, "V")
            else:
                c.setFillColor(_WHITE)
                c.setStrokeColor(_BLACK)
                c.setLineWidth(0.5)
                c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=1)

            # Etiqueta de clase
            label_x = chk_x + chk_size + 2
            c.setFillColor(_RED if is_sel else _BLACK)
            c.setFont("Helvetica-Bold", 6)
            label_y = y - check_h + (check_h - 6) / 2
            c.drawString(label_x, label_y, lbl)
            cx += col_w

        y -= check_h

        # ── Fila de indicadores J / I / A eliminada por solicitud del cliente ──
        # (estaba: INDICADORES: J = Juicio  I = Incertidumbre  A = Ajuste)

        return y - 2



    # --- SECCION 6: Observaciones --------------------------------------------

    def _draw_observaciones(self, c, y: float, os_data: dict) -> float:
        """
        Sección OBSERVACIONES con ajuste multilínea dinámico usando simpleSplit.
        Respeta saltos de línea \n y adapta el tamaño de fuente según la longitud.
        """
        from reportlab.lib.utils import simpleSplit

        y -= 18  # Espaciado moderado antes del encabezado
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawCentredString(self.ML + self.CW / 2, y, "OBSERVACIONES")   # CENTRADO
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 8

        orden = os_data
        obs_raw = str(orden.get("observaciones") or orden.get("observaciones_tecnico") or "").strip()
        font_name = "Helvetica"
        font_size = 7.0 if len(obs_raw) > 300 else (7.8 if len(obs_raw) > 160 else 8.5)
        line_height = font_size + 2.0
        ancho_tabla = self.CW
        ancho_util = ancho_tabla - 12
        x_margen = self.ML

        lineas_totales = []
        for parrafo in obs_raw.splitlines():
            if parrafo.strip():
                lineas_totales.extend(simpleSplit(parrafo.strip(), font_name, font_size, ancho_util))
            else:
                lineas_totales.append("")

        # Reservar espacio: firmas (65pt) + nota (55pt) + cintillo (28pt) + margen (10pt)
        limit_y = self.MB + 158
        y_limite_firmas = limit_y
        line_gap = 18   # espacio entre renglones pautados para escritura a mano

        if lineas_totales:
            y_inicio_obs = y - 6
            c.setFillColor(_BLACK)
            c.setFont(font_name, font_size)
            y_cursor = y_inicio_obs
            for linea in lineas_totales:
                if y_cursor < y_limite_firmas:
                    break
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.35)
                c.line(self.ML, y_cursor - 2, self.ML + self.CW, y_cursor - 2)
                c.setFillColor(_BLACK)
                c.setFont(font_name, font_size)
                c.drawString(x_margen + 6, y_cursor, linea)
                y_cursor -= line_height

            # Líneas vacías restantes si aún queda espacio hasta limit_y
            empty_lines = []
            _scan_y = y_cursor - 4
            while _scan_y > limit_y:
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.4)
                c.line(self.ML, _scan_y, self.ML + self.CW, _scan_y)
                empty_lines.append(_scan_y)
                _scan_y -= line_gap

            _is_dig_obs = self._es_digital(os_data)
            if _is_dig_obs and len(empty_lines) >= 2:
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.5)
                c.line(self.ML, empty_lines[0], self.ML + self.CW, empty_lines[-1])

            y = (empty_lines[-1] - line_gap) if empty_lines else min(y_cursor, limit_y)
            return y

        # Caso en blanco (sin texto de observaciones): renglones pautados para llenado manual
        y -= 14
        all_lines_y = []
        _scan_y = y
        while _scan_y > limit_y:
            all_lines_y.append(_scan_y)
            _scan_y -= line_gap

        for line_y in all_lines_y:
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.line(self.ML, line_y, self.ML + self.CW, line_y)

        _is_dig_obs = self._es_digital(os_data)
        if _is_dig_obs and len(all_lines_y) >= 2:
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            c.line(self.ML, all_lines_y[0], self.ML + self.CW, all_lines_y[-1])

        y = (all_lines_y[-1] - line_gap) if all_lines_y else limit_y
        return y


    # --- SECCION 7: Cuadro de NOTA oficial -----------------------------------

    def _draw_nota(self, c, y: float) -> float:
        """
        Cuadro oficial de nota (posicionado DESPUÉS de las firmas).
        """
        # Espaciado generoso antes del cuadro para no encimar con las firmas
        y -= 14
        nota_h = 40

        c.setFillColor(colors.HexColor("#FDEEEF"))
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.roundRect(self.ML, y - nota_h, self.CW, nota_h, radius=4, fill=1, stroke=1)

        # Etiqueta NOTA:
        text_x = self.ML + 10
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(text_x, y - 10, "NOTA:")

        # Texto de la nota
        nota_text = (
            "La firma del presente documento constituye la aceptación de los servicios prestados, "
            "así como la conformidad con los 'Datos para certificado y dictamen de inspección' "
            "consignados. Es responsabilidad del cliente realizar la verificación previa de dichos "
            "datos, los cuales se utilizarán de manera vinculante para la emisión de sus documentos finales."
        )
        c.setFillColor(_BLACK)
        c.setFont("Helvetica", 6.5)
        # Se ajusta el X del texto y el ancho disponible al no haber ícono
        self._wrap_text(c, nota_text, text_x + 32, y - 10, self.CW - 50, 6.5, 8.5)

        return y - nota_h

    # --- SECCION 8: Firmas (2 columnas centradas) ----------------------------

    def _draw_firmas(self, c, y: float, os_data: dict,
                     tecnico_nombre: Optional[str],
                     digital: bool = False,
                     firma_tecnico_b64: Optional[str] = None) -> float:
        """
        Dos columnas centradas. Retorna la y final después de las firmas.
        En modo digital: incrusta las imágenes de firma y los nombres debajo.
        En modo físico: sólo la línea de firma y el cargo.
        firma_tecnico_b64: cadena base64 PNG de la firma del técnico.
        """
        firma_y = y - 10

        col_w   = self.CW * 0.38
        gap     = (self.CW - 2 * col_w) / 3
        left_x  = self.ML + gap
        right_x = self.ML + gap + col_w + gap

        img_h = 40   # altura máxima de la imagen de firma en el PDF

        has_firma_cli = False
        # Intentar estampar firma del técnico si hay base64 disponible
        # (aplica en modo digital Y físico — la firma se descarga al sincronizar)
        _firma_b64_efectiva = _limpiar_b64_firma(
            firma_tecnico_b64
            or os_data.get("firma_tecnico_b64")
            or os_data.get("firma_tecnico")
        )

        if digital or _firma_b64_efectiva:
            img_y = firma_y - img_h

            # ── Firma del técnico ─────────────────────────────────────────────
            # Prioridad: base64 > ruta de archivo
            firma_tec_rendered = False
            if _firma_b64_efectiva:
                try:
                    from reportlab.lib.utils import ImageReader
                    img_bytes = base64.b64decode(_firma_b64_efectiva)
                    img_reader = ImageReader(io.BytesIO(img_bytes))
                    c.drawImage(
                        img_reader, left_x, img_y,
                        width=col_w, height=img_h,
                        preserveAspectRatio=True,
                        anchor="c",
                        mask="auto",
                    )
                    firma_tec_rendered = True
                except Exception as e:
                    logger.warning("No se pudo incrustar firma_tecnico_b64: %s", e)

            if not firma_tec_rendered:
                # Buscar firma en rutas conocidas
                firma_tec_path = os_data.get("firma_tecnico_path")
                if not firma_tec_path:
                    # Intentar desde datos_metrologicos JSON del OS
                    _dm = os_data.get("datos_metrologicos") or {}
                    if isinstance(_dm, str):
                        import json as _json
                        try: _dm = _json.loads(_dm)
                        except: _dm = {}
                    firma_tec_path = _dm.get("_firma_tecnico") or _dm.get("firma_tecnico_path")
                # Fallback: buscar en Img/firmas/
                if not firma_tec_path:
                    _tec = str(os_data.get("tecnico_nombre") or os_data.get("tecnico") or "").lower().replace(" ", "_")
                    from pathlib import Path as _P
                    _base = getattr(__import__("sys"), "_MEIPASS", str(_P(__file__).parent.parent))
                    for _cand in [f"Img/firmas/{_tec}.png", f"assets/firmas/{_tec}.png"]:
                        _rp = _P(_base) / _cand
                        if _rp.exists():
                            firma_tec_path = str(_rp)
                            break
                if firma_tec_path:
                    logger.info("[Firma tecnico] Usando ruta: %s", firma_tec_path)
                else:
                    logger.warning("[Firma tecnico] No encontrada - revisar os_data[firma_tecnico_path] o Img/firmas/<nombre>.png")
                firma_tec_path = firma_tec_path
                if firma_tec_path and Path(firma_tec_path).exists():
                    try:
                        c.drawImage(
                            firma_tec_path, left_x, img_y,
                            width=col_w, height=img_h,
                            preserveAspectRatio=True,
                            mask="auto",
                        )
                    except Exception as e:
                        logger.warning("No se pudo incrustar firma_tecnico_path: %s", e)

            # ── Firma del cliente ──────────────────────────────────────────────
            _firma_cli_b64 = _limpiar_b64_firma(
                os_data.get("firma_cliente_b64") or os_data.get("firma_cliente")
            )
            if _firma_cli_b64:
                try:
                    from reportlab.lib.utils import ImageReader
                    cli_bytes = base64.b64decode(_firma_cli_b64)
                    cli_reader = ImageReader(io.BytesIO(cli_bytes))
                    c.drawImage(
                        cli_reader, right_x, img_y,
                        width=col_w, height=img_h,
                        preserveAspectRatio=True,
                        anchor="c",
                        mask="auto",
                    )
                    has_firma_cli = True
                except Exception as e:
                    logger.warning("No se pudo incrustar firma_cliente_b64: %s", e)

            if not has_firma_cli:
                firma_cli_path = os_data.get("firma_cliente_path")
                if firma_cli_path and Path(firma_cli_path).exists():
                    try:
                        c.drawImage(
                            firma_cli_path, right_x, img_y,
                            width=col_w, height=img_h,
                            preserveAspectRatio=True,
                            mask="auto",
                        )
                        has_firma_cli = True
                    except Exception as e:
                        logger.warning("No se pudo incrustar firma_cliente_path: %s", e)

            firma_y = img_y  # la línea va debajo de la imagen
        else:
            img_y = firma_y  # sin firma: imagen no aplica

        # Líneas de firma
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.8)
        c.line(left_x,  firma_y, left_x  + col_w, firma_y)
        c.line(right_x, firma_y, right_x + col_w, firma_y)

        # Cargo (rojo, negrita)
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(left_x  + col_w / 2, firma_y - 11, "TECNICO RESPONSABLE")
        c.drawCentredString(right_x + col_w / 2, firma_y - 11, "CLIENTE")

        # Nombre impreso en texto
        c.setFillColor(_BLACK)
        c.setFont("Helvetica", 7)

        tecnico_raw = (os_data.get("nombre_tecnico_firma") or
                       tecnico_nombre or
                       os_data.get("tecnico", "") or "")
        valores_omitir = ["sin asignar", "none", "null", "— selecciona técnico —", "selecciona técnico", ""]
        tecnico_texto = "" if str(tecnico_raw).strip().lower() in valores_omitir else str(tecnico_raw).strip()

        nombre_cli = (
            os_data.get("nombre_cliente_firma")
            or os_data.get("firma_cliente_nombre")
            or ""
        ).strip()

        c.drawCentredString(left_x  + col_w / 2, firma_y - 22, tecnico_texto)

        # Nombre del cliente — obligatorio en ambos modos
        if nombre_cli:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 7)
            c.drawCentredString(right_x + col_w / 2, firma_y - 22,
                                f"NOMBRE Y FIRMA: {nombre_cli}")
        else:
            # Alerta visual cuando no se capturó el nombre del cliente
            c.setFillColor(_RED)
            c.setFont("Helvetica-Bold", 7)
            c.drawCentredString(right_x + col_w / 2, firma_y - 22, "NOMBRE Y FIRMA")

        final_y = firma_y - 30

        if not has_firma_cli:
            c.setFillColor(colors.HexColor("#555555"))
            c.setFont("Helvetica-Oblique", 6)
            c.drawCentredString(right_x + col_w / 2, firma_y - 32, "(Recibido sin firma digital)")
            final_y = firma_y - 40

        return final_y


    # --- Cintillo inferior corporativo ---------------------------------------

    def _draw_footer_bar(self, c) -> None:
        bar_h = 24
        c.setFillColor(_DARK_HDR)
        c.rect(0, 0, self.W, bar_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML,               8, "438 154 8258")
        c.drawCentredString(self.W / 2,     8, "www.basculaspesa.com.mx")
        c.drawRightString(self.W - self.MR, 8, "Queretaro, Mexico")

    # --- Utilidades ----------------------------------------------------------

    @staticmethod
    def _get_decimals(div_minima) -> int:
        if not div_minima: return 0
        s = str(div_minima).strip()
        if '.' in s: return len(s.split('.')[1].rstrip('0'))
        return 0

    @staticmethod
    def _fmt_int(value) -> str:
        """Formatea como entero si el valor es numérico entero (sin decimales)."""
        if value is None or str(value).strip() == "": return ""
        try:
            val_clean = str(value).strip().replace(' ', '')
            f = float(val_clean)
            if f == int(f):
                return formato_miles_espacio(int(f))
            return formato_miles_espacio(f)
        except (TypeError, ValueError):
            return formato_miles_espacio(value)

    @staticmethod
    def _seguro_float(val, default: float = 0.0) -> float:
        """Convierte cualquier valor a float de forma segura. Nunca lanza excepciones."""
        if val is None:
            return default
        if isinstance(val, (int, float)):
            return float(val)
        try:
            s = str(val).strip().replace(',', '.').replace(' ', '')
            return float(s) if s else default
        except (ValueError, TypeError):
            return default

    @staticmethod
    def _fmt(value, dec: int = None) -> str:
        if value is None or str(value).strip() == "":
            return ""
        try:
            val_clean = str(value).strip().replace(' ', '')
            f = float(val_clean)
            if dec is not None:
                res = f"{f:.{dec}f}"
            else:
                res = "0" if f == 0 else f"{f:.4f}".rstrip("0").rstrip(".")
            return formato_miles_espacio(res)
        except (TypeError, ValueError):
            return formato_miles_espacio(value)

    def _wrap_text(self, c, text: str, x: float, y: float,
                   max_w: float, font_size: float, line_h: float) -> float:
        words = text.split()
        line  = ""
        for word in words:
            test = (line + " " + word).strip()
            if c.stringWidth(test, "Helvetica", font_size) <= max_w:
                line = test
            else:
                c.drawString(x, y, line)
                y -= line_h
                line = word
        if line:
            c.drawString(x, y, line)
            y -= line_h
        return y


# ---------------------------------------------------------------------------
# Generador Oficial Formato de Inspección y Revisión de Básculas (OSOB-26-XXX)
# ---------------------------------------------------------------------------

class OsobPdfGenerator:
    """
    Generador de PDF del FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS (OSOB-26-XXX).
    Soporta modalidad Física (calca=True o campos en blanco para llenado a mano)
    y Digital (campos completos, casillas marcadas, texto multilínea con simpleSplit
    sin truncar y firmas digitales incrustadas).
    """

    W, H = 612.0, 792.0
    ML = 20.0
    MR = 20.0
    MT = 14.0
    MB = 14.0

    CHECKLIST_GROUPS = [
        (
            "A) Estructura y Receptor de Carga",
            [
                (1, "1. Charola / Plato / Cubierta (Sin golpes, deformaciones ni corrosión)"),
                (2, "2. Estructura inferior / Chasis (Soldaduras íntegras, sin fracturas ni óxido severo)"),
                (3, "3. Patas niveladoras (Completas, roscas en buen estado, gomas antiderrapantes firmes)"),
                (4, "4. Nivelación - Gota / Burbuja (Burbuja centrada y nivel visible sin daños)"),
                (5, "5. Topes de sobrecarga y laterales (Con holgura adecuada, sin rozamiento ni obstrucciones)"),
                (6, "6. Limpieza general (Libre de residuos, polvo acumulado, humedad o fauna nociva bajo el plato)"),
            ],
        ),
        (
            "B) Celdas y Transmisión",
            [
                (7, "7. Celda(s) de carga (Sin golpes visibles, corrosión, humedad ni deformación)"),
                (8, "8. Cableado y blindaje (Sin cortes, empalmes improvisados ni aplastamiento; prensaestopas firmes)"),
                (9, "9. Caja suma (Sellada herméticamente, sin sulfatación en bornes ni humedad)"),
            ],
        ),
        (
            "C) Indicador y Electrónica",
            [
                (10, "10. Carcasa y soporte / columna (Fijación firme, sellos en buen estado)"),
                (11, "11. Display / Pantalla (Segmentos o píxeles completos, retroiluminación funcional)"),
                (12, "12. Teclado / Botonera (Membrana íntegra sin perforaciones, respuesta táctil correcta)"),
                (13, "13. Alimentación / Batería (Cable de poder/eliminador sin daños; retención de carga en batería)"),
                (14, "14. Puertos de comunicación (RS-232 / USB / Ethernet / Wi-Fi operando correctamente)"),
            ],
        ),
    ]

    PRUEBAS_RAPIDAS = [
        ("estabilidad_cero", "Estabilidad de Cero al encendido", "Comentarios"),
        ("retorno_cero", "Retorno a Cero tras descarga", "Comentarios"),
        ("excentricidad_esquinas", "Prueba de Excentricidad (Esquinas)", "Dif. máx. detectada"),
        ("repetibilidad_lectura", "Repetibilidad de lectura", "Carga de prueba"),
        ("exactitud_preliminar", "Exactitud preliminar de pesaje", "Requiere ajuste"),
    ]

    ACCIONES_REVISION = [
        ("limpieza", "Limpieza superficial e interna"),
        ("nivelacion", "Nivelación de patas y ajuste de topes"),
        ("ajuste_peso", "Ajuste de peso (calibración interna / ajuste con masa patrón)"),
        ("revision_electrica", "Revisión eléctrica y reapriete de conexiones"),
    ]

    DICTAMENES_EQUIPO = [
        ("OPERATIVO", "OPERATIVO (Apto para uso normal / Listo para calibración)"),
        ("OPERATIVO CON OBSERVACIONES", "OPERATIVO CON OBSERVACIONES (Funciona, pero requiere mantenimiento preventivo/correctivo pronto)"),
        ("FUERA DE SERVICIO", "FUERA DE SERVICIO (No apto para uso hasta reparación)"),
    ]

    @property
    def CW(self) -> float:
        return self.W - self.ML - self.MR

    @staticmethod
    def _unpack_data(raw: dict) -> dict:
        import json as _json
        data = dict(raw or {})
        dt_raw = data.get("datos_tecnicos_json")
        if dt_raw:
            try:
                dt = _json.loads(dt_raw) if isinstance(dt_raw, str) else dt_raw
                if isinstance(dt, dict):
                    merged = dict(dt)
                    for k, v in data.items():
                        if v not in (None, "", [], {}):
                            merged[k] = v
                    data = merged
            except Exception:
                pass
        return data

    def generate(
        self,
        os_data: dict,
        output_path: Optional[str] = None,
        calca: bool = False,
        force: bool = True,
        digital: Optional[bool] = None,
    ) -> str:
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado.")

        os_data = self._unpack_data(os_data)
        folio = str(os_data.get("folio_os") or os_data.get("folio") or "OSOB-26-001").strip()

        if digital is None:
            mod = str(os_data.get("modalidad") or "").strip().upper().replace("Í", "I")
            has_cap = bool(
                os_data.get("checklist")
                or os_data.get("checklist_inspeccion")
                or os_data.get("pruebas_rapidas")
                or os_data.get("dictamen")
                or os_data.get("firma_cliente")
                or os_data.get("firma_cliente_b64")
            )
            digital = (mod == "DIGITAL") or has_cap

        if output_path is None:
            try:
                from config import PDF_OS_DIR
                out_dir = Path(PDF_OS_DIR)
                out_dir.mkdir(parents=True, exist_ok=True)
            except Exception:
                out_dir = Path.home() / "PesaServidorLocal" / "PDF_OS"
                out_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(out_dir / f"{folio}.pdf")

        if not force and Path(output_path).exists():
            return output_path

        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        tmp_path = f"{output_path}.tmp"
        c = rl_canvas.Canvas(tmp_path, pagesize=letter)
        c.setTitle(f"Formato de Inspección y Revisión de Básculas - {folio}")
        c.setAuthor("Básculas PESA")
        c.setSubject("FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS")

        try:
            if calca and not digital:
                for copy_label in ("ORIGINAL", "COPIA"):
                    self.draw_on_canvas(c, os_data, digital=False, copy_label=copy_label)
                    c.showPage()
            else:
                self.draw_on_canvas(c, os_data, digital=bool(digital), copy_label="")
                c.showPage()
            c.save()
            _os.replace(tmp_path, output_path)
        except Exception:
            try:
                Path(tmp_path).unlink()
            except OSError:
                pass
            raise

        logger.info("PDF OSOB generado: %s", output_path)
        return output_path

    def draw_on_canvas(
        self,
        c,
        raw_data: dict,
        digital: bool = False,
        copy_label: str = "",
    ) -> None:
        from reportlab.lib.utils import simpleSplit

        d = self._unpack_data(raw_data)
        y = self.H - self.MT

        # Marca de agua opcional para calca
        if copy_label:
            c.saveState()
            c.setFillColor(colors.Color(0.1, 0.5, 0.1, alpha=0.07) if copy_label == "ORIGINAL" else colors.Color(0.0, 0.3, 0.8, alpha=0.07))
            c.setFont("Helvetica-Bold", 54)
            c.translate(self.W / 2, self.H / 2)
            c.rotate(35)
            c.drawCentredString(0, 0, copy_label)
            c.restoreState()

        # ── CABECERA INSTITUCIONAL Y TÍTULO ──────────────────────────────────
        y = self._draw_header(c, y, d, digital=digital, copy_label=copy_label)
        y -= 3

        # ── SECCIÓN 1. Datos del Cliente y del Equipo ────────────────────────
        y = self._draw_section_bar(c, y, "SECCIÓN 1. Datos del Cliente y del Equipo")
        y = self._draw_seccion_1(c, y, d, digital=digital)
        y -= 3

        # ── SECCIÓN 2. Checklist de Inspección Física y Mecánica ─────────────
        y = self._draw_section_bar(c, y, "SECCIÓN 2. Checklist de Inspección Física y Mecánica")
        y = self._draw_seccion_2(c, y, d, digital=digital)
        y -= 3

        # ── SECCIÓN 3. Pruebas Rápidas de Funcionamiento ─────────────────────
        y = self._draw_section_bar(c, y, "SECCIÓN 3. Pruebas Rápidas de Funcionamiento")
        y = self._draw_seccion_3(c, y, d, digital=digital)
        y -= 3

        # ── SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones ──────
        y = self._draw_section_bar(c, y, "SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones")
        y = self._draw_seccion_4(c, y, d, digital=digital, simpleSplit=simpleSplit)
        y -= 3

        # ── SECCIÓN 5. Firmas de Conformidad ─────────────────────────────────
        y = self._draw_section_bar(c, y, "SECCIÓN 5. Firmas de Conformidad")
        self._draw_seccion_5(c, y, d, digital=digital)

        # ── PIE DE PÁGINA ────────────────────────────────────────────────────
        folio = str(d.get("folio_os") or d.get("folio") or "OSOB-26-001").strip()
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica", 5.8)
        c.drawString(self.ML, 7, f"Folio: {folio}  |  BÁSCULAS PESA — Pesaje, Sistemas y Automatización")
        if copy_label:
            c.setFont("Helvetica-Bold", 6)
            c.drawRightString(self.ML + self.CW, 7, copy_label)

    def _draw_header(self, c, y: float, d: dict, digital: bool = False, copy_label: str = "") -> float:
        hdr_h = 34.0
        folio = str(d.get("folio_os") or d.get("folio") or "OSOB-26-001").strip()
        orden_vinculada = str(
            d.get("orden_servicio_vinculada")
            or d.get("os_vinculada")
            or d.get("orden_servicio")
            or ""
        ).strip()

        # Fecha: en digital o si viene fecha, formatear DD / MM / 2026
        fecha_raw = d.get("fecha") or d.get("fecha_servicio")
        fecha_str = "____ / ____ / 2026"
        if fecha_raw:
            try:
                if isinstance(fecha_raw, (date, datetime)):
                    fecha_str = fecha_raw.strftime("%d / %m / %Y")
                else:
                    s = str(fecha_raw).strip()[:10]
                    dt_p = datetime.strptime(s, "%Y-%m-%d")
                    fecha_str = dt_p.strftime("%d / %m / %Y")
            except Exception:
                fecha_str = str(fecha_raw)
        elif digital:
            fecha_str = datetime.now().strftime("%d / %m / %Y")

        # Logos institucionales a la izquierda
        logo_x = self.ML
        if _LOGO_PESA_PATH and _LOGO_PESA_PATH.exists():
            try:
                c.drawImage(str(_LOGO_PESA_PATH), logo_x, y - hdr_h + 2, width=68, height=hdr_h - 4,
                            preserveAspectRatio=True, mask="auto")
                logo_x += 72
            except Exception:
                pass
        if _LOGO_RL_PATH and _LOGO_RL_PATH.exists():
            try:
                c.drawImage(str(_LOGO_RL_PATH), logo_x, y - hdr_h + 4, width=54, height=hdr_h - 8,
                            preserveAspectRatio=True, mask="auto")
                logo_x += 58
            except Exception:
                pass

        # Título principal centrado/institucional
        title_cx = self.ML + self.CW / 2 + 12
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 10.5)
        c.drawCentredString(title_cx, y - 12, "FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS")
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawCentredString(title_cx, y - 21, "PESAJE, SISTEMAS Y AUTOMATIZACIÓN S.A. DE C.V.  |  RFC: PSA040611L90")
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica", 5.6)
        c.drawCentredString(title_cx, y - 29, "recepcion@basculaspesa.com.mx  |  Tel: (442) 215-2409")

        # Recuadro de folio a la derecha
        fb_w = 112.0
        fb_x = self.ML + self.CW - fb_w
        c.setStrokeColor(_RED)
        c.setLineWidth(1.0)
        c.rect(fb_x, y - hdr_h + 2, fb_w, hdr_h - 2, fill=0, stroke=1)
        c.setFillColor(_RED)
        c.rect(fb_x, y - 10, fb_w, 10, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawCentredString(fb_x + fb_w / 2, y - 8, "FOLIO INSPECCIÓN")
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 10.5)
        c.drawCentredString(fb_x + fb_w / 2, y - 24, folio)

        y -= hdr_h + 2

        # Subtítulo / Cabecera de control:
        # Folio: OSOB-26-XXX | Fecha: DD / MM / 2026 | Orden de Servicio: _______________
        ctrl_h = 13.5
        c.setFillColor(_GRAY_LIGHT)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.5)
        c.rect(self.ML, y - ctrl_h, self.CW, ctrl_h, fill=1, stroke=1)

        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7.0)
        c.drawString(self.ML + 6, y - 9.5, f"Folio: {folio}")
        c.drawString(self.ML + 175, y - 9.5, f"|   Fecha: {fecha_str}")
        os_lbl = "|   Orden de Servicio: "
        c.drawString(self.ML + 355, y - 9.5, os_lbl)
        os_val_x = self.ML + 355 + c.stringWidth(os_lbl, "Helvetica-Bold", 7.0)
        if orden_vinculada:
            c.setFont("Helvetica-Bold", 7.2)
            c.drawString(os_val_x + 2, y - 9.5, orden_vinculada[:28])
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.4)
        c.line(os_val_x, y - 11, self.ML + self.CW - 8, y - 11)

        return y - ctrl_h

    def _draw_section_bar(self, c, y: float, title: str) -> float:
        bar_h = 11.5
        c.setFillColor(_DARK_HDR)
        c.rect(self.ML, y - bar_h, self.CW, bar_h, fill=1, stroke=0)
        c.setFillColor(_RED)
        c.rect(self.ML, y - bar_h, 4.0, bar_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.8)
        c.drawString(self.ML + 8, y - bar_h + 3.2, title)
        return y - bar_h

    @staticmethod
    def _draw_checkbox(c, x: float, y: float, size: float = 7.5, checked: bool = False, label_inside: str = "") -> None:
        c.setFillColor(colors.HexColor("#FDECEC") if checked else _WHITE)
        c.setStrokeColor(_RED if checked else _GRAY_DARK)
        c.setLineWidth(0.9 if checked else 0.5)
        c.rect(x, y, size, size, fill=1, stroke=1)
        if checked:
            c.setStrokeColor(_RED)
            c.setLineWidth(1.1)
            c.line(x + 1.0, y + 1.0, x + size - 1.0, y + size - 1.0)
            c.line(x + 1.0, y + size - 1.0, x + size - 1.0, y + 1.0)
        elif label_inside:
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 5.0)
            c.drawCentredString(x + size / 2, y + 1.8, label_inside)

    def _draw_seccion_1(self, c, y: float, d: dict, digital: bool = False) -> float:
        cliente = str(d.get("cliente") or d.get("cliente_nombre") or "").strip()
        planta = str(d.get("planta") or d.get("ubicacion") or d.get("sucursal_nombre") or d.get("direccion_cliente") or "").strip()
        id_tag = str(d.get("id_equipo") or d.get("id_indicador") or d.get("tag") or "").strip()
        marca = str(d.get("marca") or "").strip()
        modelo = str(d.get("modelo") or "").strip()
        serie = str(d.get("ns") or d.get("serie") or "").strip()

        unidad = str(d.get("unidad_medida") or "kg").strip()
        cap_raw = d.get("capacidad_maxima") if d.get("capacidad_maxima") not in (None, "") else d.get("alcance_max")
        if cap_raw in (None, "", 0, "0", 0.0):
            cap_raw = d.get("instrumento_capacidad") or ""
        cap_str = str(cap_raw).strip()
        if cap_str and unidad.lower() not in cap_str.lower():
            cap_str = f"{cap_str} {unidad}"

        div_raw = d.get("division_minima") if d.get("division_minima") not in (None, "") else d.get("div_minima")
        if div_raw in (None, "", 0, "0", 0.0):
            div_raw = d.get("instrumento_division") or ""
        div_str = str(div_raw).strip()
        if div_str and unidad.lower() not in div_str.lower():
            div_str = f"{div_str} {unidad}"

        tipo_inst = str(d.get("tipo_instrumento") or "").strip()
        tipo_otro = str(d.get("tipo_instrumento_otro") or "").strip()

        row_h = 16.5
        cw = self.CW

        def draw_cell(x: float, top_y: float, w: float, h: float, lbl: str, val: str):
            c.setFillColor(_WHITE)
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.rect(x, top_y - h, w, h, fill=1, stroke=1)
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 5.5)
            c.drawString(x + 4, top_y - 6.2, lbl)
            if val:
                c.setFillColor(_BLACK)
                c.setFont("Helvetica-Bold", 7.2)
                c.drawString(x + 4, top_y - h + 3.2, val[:55])

        # Fila 1: Cliente / Empresa (60%) | Planta / Ubicación (40%)
        w1 = cw * 0.58
        draw_cell(self.ML, y, w1, row_h, "Cliente / Empresa:", cliente)
        draw_cell(self.ML + w1, y, cw - w1, row_h, "Planta / Ubicación:", planta)
        y -= row_h

        # Fila 2: ID Interno / Tag | Marca | Modelo | Número de Serie
        w_f2 = cw / 4.0
        draw_cell(self.ML, y, w_f2, row_h, "ID Interno / Tag:", id_tag)
        draw_cell(self.ML + w_f2, y, w_f2, row_h, "Marca:", marca)
        draw_cell(self.ML + w_f2 * 2, y, w_f2, row_h, "Modelo:", modelo)
        draw_cell(self.ML + w_f2 * 3, y, w_f2, row_h, "Número de Serie:", serie)
        y -= row_h

        # Fila 3: Capacidad Máx. (Max) (50%) | División Mínima (d / e) (50%)
        w_f3 = cw / 2.0
        draw_cell(self.ML, y, w_f3, row_h, "Capacidad Máx. (Max):", cap_str)
        draw_cell(self.ML + w_f3, y, cw - w_f3, row_h, "División Mínima (d / e):", div_str)
        y -= row_h

        # Fila 4: Tipo de Instrumento: [ ] Mesa  [ ] Camionera  [ ] Colgante  [ ] Tolva  [ ] Tanque  [ ] Otro (especifique): ___
        inst_h = 14.5
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.4)
        c.rect(self.ML, y - inst_h, cw, inst_h, fill=1, stroke=1)

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 6.0)
        c.drawString(self.ML + 4, y - 9.8, "Tipo de Instrumento:")

        tipos_std = ["Mesa", "Camionera", "Colgante", "Tolva", "Tanque"]
        tipo_norm = tipo_inst.lower().strip()
        es_otro = bool(tipo_otro) or (bool(tipo_norm) and not any(t.lower() in tipo_norm for t in tipos_std))
        if es_otro and not tipo_otro and tipo_inst:
            tipo_otro = tipo_inst

        x_cur = self.ML + 76
        for t_lbl in tipos_std:
            marked = (t_lbl.lower() in tipo_norm) and not es_otro
            self._draw_checkbox(c, x_cur, y - 11.2, size=7.2, checked=marked)
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold" if marked else "Helvetica", 6.3)
            c.drawString(x_cur + 9.5, y - 9.8, t_lbl)
            x_cur += 9.5 + c.stringWidth(t_lbl, "Helvetica", 6.3) + 14

        # Otro (especifique): _________________
        self._draw_checkbox(c, x_cur, y - 11.2, size=7.2, checked=es_otro)
        otro_lbl = "Otro (especifique):"
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold" if es_otro else "Helvetica", 6.3)
        c.drawString(x_cur + 9.5, y - 9.8, otro_lbl)
        line_x0 = x_cur + 9.5 + c.stringWidth(otro_lbl, "Helvetica", 6.3) + 4
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.4)
        c.line(line_x0, y - 11.2, self.ML + cw - 6, y - 11.2)
        if es_otro and tipo_otro:
            c.setFont("Helvetica-Bold", 6.5)
            c.drawString(line_x0 + 2, y - 9.8, tipo_otro[:32])

        return y - inst_h

    def _draw_seccion_2(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        # Instrucción
        inst_h = 11.0
        c.setFillColor(_GRAY_LIGHT)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.4)
        c.rect(self.ML, y - inst_h, cw, inst_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 5.7)
        c.drawString(
            self.ML + 4,
            y - 8.0,
            'Instrucción: Marcar con una "X" el estado actual de cada componente '
            '(B = Bueno / Operativo, R = Regular / Requiere ajuste o limpieza, M = Malo / Requiere reemplazo, N/A = No aplica).',
        )
        y -= inst_h

        checklist_data = d.get("checklist") or d.get("checklist_inspeccion") or {}
        if isinstance(checklist_data, list):
            # Convertir lista a dict por índice 1..14
            tmp_chk = {}
            for idx, item in enumerate(checklist_data):
                if isinstance(item, dict):
                    k = str(item.get("id") or (idx + 1))
                    tmp_chk[k] = item
            checklist_data = tmp_chk

        grp_h = 10.5
        row_h = 12.2
        col_comp_w = 278.0
        col_opt_w = 112.0
        col_obs_w = cw - col_comp_w - col_opt_w

        for grp_title, items in self.CHECKLIST_GROUPS:
            # Barra de subgrupo A, B, C
            c.setFillColor(colors.HexColor("#EAEAEA"))
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.rect(self.ML, y - grp_h, cw, grp_h, fill=1, stroke=1)
            c.setFillColor(_RED)
            c.setFont("Helvetica-Bold", 6.3)
            c.drawString(self.ML + 4, y - 7.8, grp_title)
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 5.5)
            c.drawCentredString(self.ML + col_comp_w + col_opt_w / 2, y - 7.8, "ESTADO [ B ] [ R ] [ M ] [ N/A ]")
            c.drawString(self.ML + col_comp_w + col_opt_w + 4, y - 7.8, "Observaciones")
            y -= grp_h

            for item_num, item_label in items:
                item_info = checklist_data.get(str(item_num)) or checklist_data.get(item_num) or {}
                if not isinstance(item_info, dict):
                    item_info = {"estado": str(item_info)}
                estado_sel = str(item_info.get("estado") or "").strip().upper() if digital else ""
                obs_item = str(item_info.get("observaciones") or "").strip() if digital else ""

                c.setFillColor(_WHITE if item_num % 2 == 1 else colors.HexColor("#FAFAFA"))
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.35)
                c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=1)
                c.line(self.ML + col_comp_w, y, self.ML + col_comp_w, y - row_h)
                c.line(self.ML + col_comp_w + col_opt_w, y, self.ML + col_comp_w + col_opt_w, y - row_h)

                # Texto del punto
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 5.8)
                c.drawString(self.ML + 4, y - 8.5, item_label)

                # Casillas [ B ] [ R ] [ M ] [ N/A ]
                opts = [("B", "B", 22), ("R", "R", 22), ("M", "M", 22), ("N/A", "N/A", 30)]
                ox = self.ML + col_comp_w + 6
                for code, disp, step_w in opts:
                    is_sel = (estado_sel == code)
                    box_w = 18.0 if code == "N/A" else 13.0
                    box_h = 8.4
                    by = y - row_h + 1.9
                    c.setFillColor(colors.HexColor("#FDECEC") if is_sel else _WHITE)
                    c.setStrokeColor(_RED if is_sel else _GRAY_DARK)
                    c.setLineWidth(0.9 if is_sel else 0.45)
                    c.rect(ox, by, box_w, box_h, fill=1, stroke=1)
                    c.setFillColor(_RED if is_sel else _BLACK)
                    c.setFont("Helvetica-Bold", 5.6)
                    txt_box = f"X:{disp}" if is_sel else disp
                    c.drawCentredString(ox + box_w / 2, by + 2.0, txt_box)
                    ox += step_w + 2

                # Observaciones: _________________
                obs_x = self.ML + col_comp_w + col_opt_w + 4
                c.setFillColor(_GRAY_DARK)
                c.setFont("Helvetica", 5.4)
                c.drawString(obs_x, y - 8.5, "Obs.:")
                val_x = obs_x + 16
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.35)
                c.line(val_x, y - row_h + 2.2, self.ML + cw - 4, y - row_h + 2.2)
                if obs_item:
                    c.setFillColor(_BLACK)
                    c.setFont("Helvetica", 5.8)
                    c.drawString(val_x + 1, y - 8.5, obs_item[:48])

                y -= row_h

        return y

    def _draw_seccion_3(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        pruebas = d.get("pruebas_rapidas") or {}
        if not isinstance(pruebas, dict):
            pruebas = {}

        row_h = 12.6
        col_lbl_w = 165.0
        col_cumple_w = 135.0

        for idx, (key, title_lbl, sec_lbl) in enumerate(self.PRUEBAS_RAPIDAS):
            alt_key = "excentricidad" if key == "excentricidad_esquinas" else ("repetibilidad" if key == "repetibilidad_lectura" else key)
            p_info = pruebas.get(key) or pruebas.get(alt_key) or {}
            if not isinstance(p_info, dict):
                p_info = {}
            res_val = str(p_info.get("resultado") or "").strip().upper() if digital else ""
            sec_val = str(p_info.get("valor") or p_info.get("comentarios") or "").strip() if digital else ""
            req_ajuste = str(p_info.get("requiere_ajuste") or "").strip().upper() if digital else ""

            c.setFillColor(_WHITE if idx % 2 == 0 else colors.HexColor("#FAFAFA"))
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.35)
            c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=1)
            c.line(self.ML + col_lbl_w, y, self.ML + col_lbl_w, y - row_h)
            c.line(self.ML + col_lbl_w + col_cumple_w, y, self.ML + col_lbl_w + col_cumple_w, y - row_h)

            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.1)
            c.drawString(self.ML + 4, y - 8.6, f"{title_lbl}:")

            # [ ] Cumple   [ ] No cumple
            cx = self.ML + col_lbl_w + 8
            is_cumple = res_val == "CUMPLE"
            is_no_cumple = res_val in ("NO CUMPLE", "NO_CUMPLE")
            self._draw_checkbox(c, cx, y - 10.0, size=7.2, checked=is_cumple)
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold" if is_cumple else "Helvetica", 6.0)
            c.drawString(cx + 9.5, y - 8.6, "Cumple")

            cx2 = cx + 56
            self._draw_checkbox(c, cx2, y - 10.0, size=7.2, checked=is_no_cumple)
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold" if is_no_cumple else "Helvetica", 6.0)
            c.drawString(cx2 + 9.5, y - 8.6, "No cumple")

            # Columna secundaria
            sx = self.ML + col_lbl_w + col_cumple_w + 6
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 5.9)
            c.drawString(sx, y - 8.6, f"{sec_lbl}:")
            sx_after = sx + c.stringWidth(f"{sec_lbl}:", "Helvetica-Bold", 5.9) + 5

            if key == "exactitud_preliminar":
                is_si = req_ajuste in ("SI", "SÍ", "TRUE", "1")
                is_no = req_ajuste in ("NO", "FALSE", "0")
                self._draw_checkbox(c, sx_after, y - 10.0, size=7.2, checked=is_si)
                c.setFillColor(_BLACK)
                c.setFont("Helvetica-Bold" if is_si else "Helvetica", 6.0)
                c.drawString(sx_after + 9.5, y - 8.6, "Sí")

                sx_no = sx_after + 36
                self._draw_checkbox(c, sx_no, y - 10.0, size=7.2, checked=is_no)
                c.setFillColor(_BLACK)
                c.setFont("Helvetica-Bold" if is_no else "Helvetica", 6.0)
                c.drawString(sx_no + 9.5, y - 8.6, "No")
            else:
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.35)
                c.line(sx_after, y - row_h + 2.2, self.ML + cw - 5, y - row_h + 2.2)
                if sec_val:
                    c.setFillColor(_BLACK)
                    c.setFont("Helvetica", 6.1)
                    c.drawString(sx_after + 2, y - 8.6, sec_val[:52])

            y -= row_h

        return y

    def _draw_seccion_4(self, c, y: float, d: dict, digital: bool = False, simpleSplit=None) -> float:
        if simpleSplit is None:
            from reportlab.lib.utils import simpleSplit

        cw = self.CW
        obs_raw = str(
            d.get("observaciones_tecnicas")
            or d.get("observaciones")
            or ""
        ).strip() if digital else ""

        ref_raw = str(
            d.get("refacciones_requeridas")
            or d.get("refacciones_texto")
            or ""
        ).strip() if digital else ""

        acciones_raw = d.get("acciones_realizadas") or {}
        if isinstance(acciones_raw, list):
            acciones_raw = {str(k): True for k in acciones_raw}
        elif not isinstance(acciones_raw, dict):
            acciones_raw = {}

        dictamen_val = str(d.get("dictamen") or d.get("estado_operativo") or "").strip().upper() if digital else ""

        # 1) Observaciones técnicas y hallazgos detallados (Multilínea con word-wrap dinámico sin truncar)
        ancho_util = cw - 12.0
        obs_font_size = 6.8 if len(obs_raw) > 350 else (7.4 if len(obs_raw) > 180 else 8.0)
        obs_lh = obs_font_size + 1.8
        obs_lines = []
        if obs_raw:
            for parrafo in obs_raw.splitlines():
                if parrafo.strip():
                    obs_lines.extend(simpleSplit(parrafo.strip(), "Helvetica", obs_font_size, ancho_util))
                else:
                    obs_lines.append("")

        obs_box_h = max(36.0, min(68.0, len(obs_lines) * obs_lh + 13.0))
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - obs_box_h, cw, obs_box_h, fill=1, stroke=1)
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawString(self.ML + 5, y - 8.2, "Observaciones técnicas y hallazgos detallados:")

        if obs_lines:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", obs_font_size)
            yc = y - 17.5
            for ln in obs_lines:
                if yc < (y - obs_box_h + 3):
                    break
                c.drawString(self.ML + 6, yc, ln)
                yc -= obs_lh
        elif not digital:
            # Renglones guía para llenado manual
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.3)
            for ry in (y - 19.0, y - 30.0):
                c.line(self.ML + 6, ry, self.ML + cw - 6, ry)
        else:
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Oblique", 7.0)
            c.drawString(self.ML + 6, y - 20.0, "Sin observaciones adicionales.")

        y -= obs_box_h

        # 2) Acciones realizadas durante la revisión (4 checkboxes en grid 2x2)
        acc_h = 28.0
        c.setFillColor(colors.HexColor("#FAFAFA"))
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - acc_h, cw, acc_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 6.1)
        c.drawString(self.ML + 5, y - 8.0, "Acciones realizadas durante la revisión:")

        half_w = cw / 2.0
        for idx, (ak, albl) in enumerate(self.ACCIONES_REVISION):
            col = idx % 2
            row = idx // 2
            ax = self.ML + 8 + col * half_w
            ay = y - 16.5 - row * 9.2
            is_chk = bool(acciones_raw.get(ak) or acciones_raw.get(albl)) if digital else False
            self._draw_checkbox(c, ax, ay - 1.2, size=6.8, checked=is_chk)
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold" if is_chk else "Helvetica", 5.9)
            c.drawString(ax + 9.0, ay, albl)

        y -= acc_h

        # 3) Refacciones o servicios adicionales requeridos (Multilínea con word-wrap dinámico)
        ref_font_size = 6.8 if len(ref_raw) > 300 else (7.4 if len(ref_raw) > 150 else 8.0)
        ref_lh = ref_font_size + 1.8
        ref_lines = []
        if ref_raw:
            for parrafo in ref_raw.splitlines():
                if parrafo.strip():
                    ref_lines.extend(simpleSplit(parrafo.strip(), "Helvetica", ref_font_size, ancho_util))
                else:
                    ref_lines.append("")

        ref_box_h = max(28.0, min(52.0, len(ref_lines) * ref_lh + 12.0))
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - ref_box_h, cw, ref_box_h, fill=1, stroke=1)
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawString(self.ML + 5, y - 8.2, "Refacciones o servicios adicionales requeridos:")

        if ref_lines:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", ref_font_size)
            yc = y - 17.0
            for ln in ref_lines:
                if yc < (y - ref_box_h + 3):
                    break
                c.drawString(self.ML + 6, yc, ln)
                yc -= ref_lh
        elif not digital:
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.3)
            c.line(self.ML + 6, y - 20.0, self.ML + cw - 6, y - 20.0)
        else:
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Oblique", 7.0)
            c.drawString(self.ML + 6, y - 19.0, "Ninguna requerida.")

        y -= ref_box_h

        # 4) Dictamen de Estado Operativo del Equipo
        dict_h = 35.0
        c.setFillColor(_GRAY_LIGHT)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - dict_h, cw, dict_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawString(self.ML + 5, y - 8.0, "Dictamen de Estado Operativo del Equipo:")

        for idx, (d_code, d_text) in enumerate(self.DICTAMENES_EQUIPO):
            dy = y - 16.2 - idx * 8.2
            is_d = (dictamen_val == d_code) or (d_code in dictamen_val and (d_code != "OPERATIVO" or "OBSERVACIONES" not in dictamen_val))
            if not dictamen_val:
                is_d = False
            self._draw_checkbox(c, self.ML + 8, dy - 1.2, size=6.8, checked=is_d)
            c.setFillColor(_RED if is_d else _BLACK)
            c.setFont("Helvetica-Bold" if is_d else "Helvetica", 5.9)
            c.drawString(self.ML + 17.5, dy, d_text)

        return y - dict_h

    def _draw_seccion_5(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        box_h = 62.0
        half_w = (cw - 8.0) / 2.0

        tec_nombre = str(d.get("tecnico_nombre") or d.get("tecnico") or "").strip()
        tec_puesto = str(d.get("puesto_tecnico") or "Técnico de Servicio").strip() if (digital or d.get("puesto_tecnico")) else ""
        cli_nombre = str(d.get("nombre_ing") or d.get("firma_cliente_nombre") or "").strip() if digital else ""
        cli_puesto = str(d.get("puesto_ing") or d.get("area_cliente") or "").strip() if digital else ""

        firma_tec_b64 = d.get("firma_tecnico") or d.get("firma_tecnico_b64") or _firma_perfil_tecnico(d)
        firma_cli_b64 = d.get("firma_cliente") or d.get("firma_cliente_b64")

        # Columna Izquierda: Realizó Revisión (Técnico)
        lx = self.ML
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(lx, y - box_h, half_w, box_h, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(lx + 6, y - 9.0, "Realizó Revisión (Técnico):")

        # Nombre
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 20.0, "Nombre:")
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.35)
        c.line(lx + 36, y - 21.0, lx + half_w - 6, y - 21.0)
        if tec_nombre:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.3)
            c.drawString(lx + 38, y - 19.8, tec_nombre[:40])

        # Puesto
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 31.0, "Puesto:")
        c.line(lx + 36, y - 32.0, lx + half_w - 6, y - 32.0)
        if tec_puesto:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 6.2)
            c.drawString(lx + 38, y - 30.8, tec_puesto[:40])

        # Firma
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 54.0, "Firma:")
        c.line(lx + 36, y - 55.0, lx + half_w - 6, y - 55.0)
        if digital and firma_tec_b64:
            self._draw_sig_b64(c, firma_tec_b64, lx + 45, y - 54.0, width=110, height=21)

        # Columna Derecha: Recibió de Conformidad (Cliente / Usuario)
        rx = self.ML + half_w + 8.0
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(rx, y - box_h, half_w, box_h, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(rx + 6, y - 9.0, "Recibió de Conformidad (Cliente / Usuario):")

        # Nombre
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 20.0, "Nombre:")
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.35)
        c.line(rx + 36, y - 21.0, rx + half_w - 6, y - 21.0)
        if cli_nombre:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.3)
            c.drawString(rx + 38, y - 19.8, cli_nombre[:40])

        # Área / Puesto
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 31.0, "Área / Puesto:")
        c.line(rx + 52, y - 32.0, rx + half_w - 6, y - 32.0)
        if cli_puesto:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 6.2)
            c.drawString(rx + 54, y - 30.8, cli_puesto[:36])

        # Firma
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 54.0, "Firma:")
        c.line(rx + 36, y - 55.0, rx + half_w - 6, y - 55.0)
        if digital and firma_cli_b64:
            self._draw_sig_b64(c, firma_cli_b64, rx + 45, y - 54.0, width=110, height=21)

        return y - box_h

    @staticmethod
    def _draw_sig_b64(c, b64_str: str, x: float, y: float, width: float, height: float) -> None:
        if not b64_str or len(str(b64_str).strip()) < 20:
            return
        try:
            import base64
            import io
            from reportlab.lib.utils import ImageReader
            clean = str(b64_str).strip()
            if "," in clean:
                clean = clean.split(",", 1)[1]
            raw = base64.b64decode(clean)
            img = ImageReader(io.BytesIO(raw))
            c.drawImage(img, x, y, width=width, height=height, preserveAspectRatio=True, mask="auto")
        except Exception as exc:
            logger.debug("No se pudo incrustar firma en OSOB PDF: %s", exc)


class OsoccPdfGenerator(OsobPdfGenerator):
    """
    Generador de PDF para el formato OSOCC (OSOCC-26-XXX):
    FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA
    Diagnóstico unitario de 1 celda de carga (Cliente o Stock / Laboratorio Interno).
    Soporta tanto modalidad Física (líneas limpias / calca) como Digital.
    """

    SECCION_2_ITEMS = [
        ("cuerpo_metalico", "1. Cuerpo metálico / Deformación"),
        ("roscas_barrenos", "2. Roscas, barrenos y apoyos mecánicos"),
        ("sellos_galgas", "3. Sellos herméticos y encapsulado de galgas"),
        ("integridad_cable", "4. Integridad del cable (sin cortes, aplastamientos ni empalmes)"),
        ("prensaestopas", "5. Prensaestopas / Salida de cable"),
        ("corrosion_humedad", "6. Evidencia de corrosión, humedad o sobrecarga térmica"),
    ]

    SECCION_3_PARAMS = [
        ("exc_pos_exc_neg", "1. Excitación Exc+ / Exc-", "Ohms", "OK", "Falla"),
        ("sig_pos_sig_neg", "2. Resistencia Sig+ / Sig-", "Ohms", "OK", "Falla"),
        ("exc_pos_sig_pos", "3. Resistencia Exc+ / Sig+", "Ohms", "OK", "Falla"),
        ("exc_pos_sig_neg", "4. Resistencia Exc+ / Sig-", "Ohms", "OK", "Falla"),
        ("exc_neg_sig_pos", "5. Resistencia Exc- / Sig+", "Ohms", "OK", "Falla"),
        ("exc_neg_sig_neg", "6. Resistencia Exc- / Sig-", "Ohms", "OK", "Falla"),
        ("sig_neg_exc_pos", "7. Resistencia Sig- + Exc+", "Ohms", "OK", "Falla"),
        ("sig_neg_exc_neg", "8. Resistencia Sig- + Exc-", "Ohms", "OK", "Falla"),
        ("exc_ambos_sig_pos", "9. Resistencia Exc-+ / Sig+", "Ohms", "OK", "Falla"),
        ("exc_ambos_sig_neg", "10. Resistencia Exc-+ / Sig-", "Ohms", "OK", "Falla"),
        ("senal_salida_mv", "11. Señal de Salida (Milivoltaje)", "mV", "OK", "Falla"),
        ("aislamiento_mohm", "12. Resistencia de Aislamiento", "MΩ", "> 5000 MΩ (OK)", "Fuga"),
    ]

    DICTAMENES = [
        ("OPERATIVA", "OPERATIVA / EN TOLERANCIA (Apta para instalación o calibración)"),
        ("REPARABLE", "REPARABLE (Requiere reemplazo de cable, conector o reapriete)"),
        ("DANADA", "DAÑADA / DESCALIBRADA (Sobrecarga, galgas abiertas o fuga - FUERA DE SERVICIO)"),
    ]

    def generate(
        self,
        os_data: dict,
        output_path: Optional[str] = None,
        force: bool = True,
        calca: bool = False,
    ) -> str:
        if not _REPORTLAB_AVAILABLE:
            raise RuntimeError("ReportLab no está instalado.")

        d = self._normalize_data(os_data)
        folio = d.get("folio_os") or "OSOCC-26-001"

        if output_path is None:
            output_dir = Path(PDFS_DIR)
            output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")
        else:
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)

        if not force and Path(output_path).exists():
            return output_path

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Diagnóstico y Revisión de Celda de Carga — {folio}")
        c.setAuthor("Servicios PESA — Básculas PESA")
        c.setSubject("FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA")

        is_digital = self._is_digital_filled(d) and not calca
        num_copies = 2 if calca else 1
        for _ in range(num_copies):
            self.draw_on_canvas(c, d, digital=is_digital)
            c.showPage()

        c.save()
        logger.info("PDF OSOCC generado exitosamente: %s", output_path)
        return output_path

    def generate_lote(
        self,
        folios: list[str],
        base_data: dict,
        output_path: Optional[str] = None,
        calca: bool = True,
        equipos_por_folio: Optional[dict[str, dict]] = None,
    ) -> str:
        if not _REPORTLAB_AVAILABLE:
            raise RuntimeError("ReportLab no está instalado.")

        if not folios:
            raise ValueError("Lista de folios vacía para lote OSOCC.")

        if output_path is None:
            import tempfile
            fn = f"LOTE_OSOCC_{folios[0]}_al_{folios[-1]}.pdf" if len(folios) > 1 else f"{folios[0]}.pdf"
            output_path = str(Path(tempfile.gettempdir()) / fn)
        else:
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Lote OSOCC — {folios[0]} al {folios[-1]}")
        c.setAuthor("Servicios PESA — Básculas PESA")

        total = len(folios)
        copies = 2 if calca else 1
        for idx, folio in enumerate(folios, start=1):
            row_data = dict(base_data or {})
            row_data["folio_os"] = folio
            if equipos_por_folio and folio in equipos_por_folio:
                row_data.update(equipos_por_folio[folio])
            d = self._normalize_data(row_data)
            for _ in range(copies):
                self.draw_on_canvas(c, d, digital=False)
                if total > 1:
                    c.setFillColor(_GRAY_DARK)
                    c.setFont("Helvetica", 6.5)
                    c.drawRightString(self.ML + self.CW, 23, f"Formato {idx} de {total}")
                c.showPage()

        c.save()
        logger.info("PDF lote OSOCC generado (%d folios): %s", total, output_path)
        return output_path

    def _is_digital_filled(self, d: dict) -> bool:
        mod = str(d.get("modalidad") or "").strip().upper()
        est = str(d.get("estado") or "").strip().upper()
        if d.get("osocc_digital") or d.get("inspeccion_fisica_celda") or d.get("mediciones_electricas_celda") or d.get("dictamen_celda"):
            return True
        if est in ("CERRADA", "CERRADO", "COMPLETADA", "COMPLETADA_DIGITAL", "FINALIZADA") and mod != "FISICO":
            return True
        return False

    def draw_on_canvas(self, c, data: dict, digital: bool = False) -> None:
        d = self._normalize_data(data)
        y = self.H - self.MT

        # ── CABECERA INSTITUCIONAL Y DE CONTROL ───────────────────────────────
        y = self._draw_header_osocc(c, y, d, digital=digital)
        y -= 4

        # ── SECCIÓN 1: DATOS DE IDENTIFICACIÓN DE LA CELDA ────────────────────
        y = self._draw_sec_hdr(c, y, "SECCIÓN 1. DATOS DE IDENTIFICACIÓN DE LA CELDA")
        y = self._draw_seccion_1_osocc(c, y, d, digital=digital)
        y -= 4

        # ── SECCIÓN 2: INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA ───────────────
        y = self._draw_sec_hdr(
            c,
            y,
            "SECCIÓN 2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA",
            right_label="Criterio:  [ B ] Bueno    [ R ] Regular    [ M ] Malo    [ N/A ]",
        )
        y = self._draw_seccion_2_osocc(c, y, d, digital=digital)
        y -= 4

        # ── SECCIÓN 3: PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA) ──
        y = self._draw_sec_hdr(
            c,
            y,
            "SECCIÓN 3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA)",
            right_label="Diagnóstico unitario de 1 celda de carga",
        )
        y = self._draw_seccion_3_osocc(c, y, d, digital=digital)
        y -= 4

        # ── SECCIÓN 4: DICTAMEN TÉCNICO Y OBSERVACIONES ───────────────────────
        y = self._draw_sec_hdr(c, y, "SECCIÓN 4. DICTAMEN TÉCNICO Y OBSERVACIONES")
        y = self._draw_seccion_4_osocc(c, y, d, digital=digital)
        y -= 4

        # ── SECCIÓN 5: FIRMAS DE RESPONSABILIDAD ──────────────────────────────
        y = self._draw_sec_hdr(c, y, "SECCIÓN 5. FIRMAS DE RESPONSABILIDAD")
        self._draw_seccion_5_osocc(c, y, d, digital=digital)

        # ── PIE DE PÁGINA ─────────────────────────────────────────────────────
        self._draw_footer(c)

    def _draw_header_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        hdr_h = 52.0

        # Fondo y borde superior
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.6)
        c.rect(self.ML, y - hdr_h, cw, hdr_h, fill=1, stroke=1)

        # Barra superior azul celeste / rojo corporativo
        c.setFillColor(_RED)
        c.rect(self.ML, y - 3, cw, 3, fill=1, stroke=0)

        # Logo BP a la izquierda
        logo_path = _find_asset(
            "logo_bp.png", "bp_logo.png", "logo_pesa.png",
            "basculas_pesa.png", "logo.png"
        )
        if logo_path:
            try:
                c.drawImage(
                    logo_path,
                    self.ML + 6, y - 33,
                    width=105, height=26,
                    preserveAspectRatio=True, mask="auto",
                )
            except Exception:
                self._draw_bp_fallback(c, self.ML + 6, y - 33)
        else:
            self._draw_bp_fallback(c, self.ML + 6, y - 33)

        # Logo Rice Lake a la derecha
        rl_path = _find_asset("logo_ricelake.png", "ricelake_logo.png", "rice_lake.png", "ricelake.png")
        if rl_path:
            try:
                c.drawImage(
                    rl_path,
                    self.ML + cw - 110, y - 33,
                    width=104, height=26,
                    preserveAspectRatio=True, mask="auto",
                )
            except Exception:
                self._draw_rl_fallback(c, self.ML + cw - 110, y - 33)
        else:
            self._draw_rl_fallback(c, self.ML + cw - 110, y - 33)

        # Título Oficial centrado
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 9.6)
        c.drawCentredString(self.ML + cw / 2, y - 16, "FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA")
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica", 6.2)
        c.drawCentredString(self.ML + cw / 2, y - 25, "DIAGNÓSTICO UNITARIO DE RESISTENCIA, MILIVOLTAJE, AISLAMIENTO E INTEGRIDAD MECÁNICA")

        # Subtítulo / Cabecera de control:
        # Folio: OSOCC-26-XXX | Fecha: DD / MM / 2026 | Ref. / Orden: _______________ | Destino: [ ] Cliente   [ ] Stock / Laboratorio Interno
        ctrl_y = y - hdr_h
        ctrl_h = 16.5
        c.setFillColor(_CREAM_BG)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.5)
        c.rect(self.ML, ctrl_y, cw, ctrl_h, fill=1, stroke=1)

        folio = str(d.get("folio_os") or "OSOCC-26-001").strip()
        fecha_str = self._fmt_fecha(d.get("fecha"))
        ref_orden = str(d.get("orden_referencia") or d.get("ref_orden") or "").strip()

        destino_raw = str(d.get("destino_celda") or d.get("destino") or "").strip().upper()
        cli_val = str(d.get("cliente") or d.get("razon_social") or "").strip()
        if not destino_raw:
            if not cli_val or "stock" in cli_val.lower() or "taller" in cli_val.lower() or "laboratorio" in cli_val.lower() or "basculas pesa" in cli_val.lower() or "básculas pesa" in cli_val.lower():
                destino_raw = "STOCK"
            else:
                destino_raw = "CLIENTE"
        is_cliente = "CLI" in destino_raw
        is_stock = ("STOCK" in destino_raw) or ("LAB" in destino_raw) or ("TALLER" in destino_raw) or ("INTERN" in destino_raw)

        # Col 1: Folio
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.8)
        c.drawString(self.ML + 5, ctrl_y + 4.8, "Folio:")
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 8.2)
        c.drawString(self.ML + 27, ctrl_y + 4.5, folio)

        # Separador 1
        sep1 = self.ML + 112
        c.setStrokeColor(_GRAY_MED)
        c.line(sep1, ctrl_y, sep1, ctrl_y + ctrl_h)

        # Col 2: Fecha
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.8)
        c.drawString(sep1 + 5, ctrl_y + 4.8, "Fecha:")
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7.2)
        c.drawString(sep1 + 31, ctrl_y + 4.8, fecha_str)

        # Separador 2
        sep2 = self.ML + 220
        c.line(sep2, ctrl_y, sep2, ctrl_y + ctrl_h)

        # Col 3: Ref. / Orden
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.8)
        c.drawString(sep2 + 5, ctrl_y + 4.8, "Ref. / Orden:")
        line_x1 = sep2 + 52
        line_x2 = self.ML + 340
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.4)
        c.line(line_x1, ctrl_y + 3.5, line_x2, ctrl_y + 3.5)
        if ref_orden:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 7.0)
            c.drawString(line_x1 + 2, ctrl_y + 4.8, ref_orden[:22])

        # Separador 3
        sep3 = self.ML + 345
        c.setStrokeColor(_GRAY_MED)
        c.line(sep3, ctrl_y, sep3, ctrl_y + ctrl_h)

        # Col 4: Destino: [ ] Cliente   [ ] Stock / Laboratorio Interno
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.6)
        c.drawString(sep3 + 5, ctrl_y + 4.8, "Destino:")

        cx_cli = sep3 + 36
        self._draw_checkbox(c, cx_cli, ctrl_y + 4.2, size=6.5, checked=is_cliente)
        c.setFillColor(_RED if is_cliente else _BLACK)
        c.setFont("Helvetica-Bold" if is_cliente else "Helvetica", 6.3)
        c.drawString(cx_cli + 8.5, ctrl_y + 4.8, "Cliente")

        cx_stk = cx_cli + 38
        self._draw_checkbox(c, cx_stk, ctrl_y + 4.2, size=6.5, checked=is_stock)
        c.setFillColor(_RED if is_stock else _BLACK)
        c.setFont("Helvetica-Bold" if is_stock else "Helvetica", 6.3)
        c.drawString(cx_stk + 8.5, ctrl_y + 4.8, "Stock / Laboratorio Interno")

        return y - hdr_h

    def _draw_seccion_1_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        row_h = 15.5
        total_h = row_h * 4

        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - total_h, cw, total_h, fill=1, stroke=1)

        cliente_val = str(
            d.get("cliente")
            or d.get("razon_social")
            or d.get("ubicacion")
            or "Stock / Taller Básculas PESA"
        ).strip()
        if not cliente_val or cliente_val.lower() in ("none", "null", "--"):
            cliente_val = "Stock / Taller Básculas PESA"

        marca = str(d.get("marca") or "").strip()
        modelo = str(d.get("modelo") or "").strip()
        ns = str(d.get("ns") or d.get("numero_serie") or "").strip()
        cap_max = str(d.get("alcance_max") or d.get("capacidad_max") or "").strip()
        if cap_max.endswith(".0"):
            cap_max = cap_max[:-2]
        unidad_cap = str(d.get("unidad_capacidad") or d.get("unidad") or "").strip()
        if cap_max and unidad_cap and unidad_cap.lower() not in cap_max.lower():
            cap_max = f"{cap_max} {unidad_cap}"

        sensibilidad = str(d.get("sensibilidad_nominal") or d.get("sensibilidad") or "").strip()
        res_nominal = str(d.get("resistencia_nominal") or d.get("resistencia_entrada_salida") or "").strip()

        cables_cfg = d.get("configuracion_cables")
        if not isinstance(cables_cfg, dict):
            cables_cfg = {}
        exc_pos_col = str(cables_cfg.get("exc_pos") or d.get("cable_exc_pos") or "Rojo").strip()
        exc_neg_col = str(cables_cfg.get("exc_neg") or d.get("cable_exc_neg") or "Negro").strip()
        sig_pos_col = str(cables_cfg.get("sig_pos") or d.get("cable_sig_pos") or "Verde").strip()
        sig_neg_col = str(cables_cfg.get("sig_neg") or d.get("cable_sig_neg") or "Blanco").strip()
        blindaje_col = str(cables_cfg.get("blindaje") or d.get("cable_blindaje") or "Malla").strip()
        sense_col = str(cables_cfg.get("sense") or d.get("cable_sense") or ("Si/No" if not digital else "No")).strip()

        # Fila 1: Cliente / Destino (56%) | Marca (22%) | Modelo (22%)
        r1_y = y
        w_cli = cw * 0.52
        w_mar = cw * 0.24
        w_mod = cw - w_cli - w_mar
        self._draw_labeled_cell(c, self.ML, r1_y, w_cli, row_h, "Cliente / Destino:", cliente_val)
        self._draw_labeled_cell(c, self.ML + w_cli, r1_y, w_mar, row_h, "Marca:", marca)
        self._draw_labeled_cell(c, self.ML + w_cli + w_mar, r1_y, w_mod, row_h, "Modelo:", modelo)

        # Fila 2: Número de Serie (38%) | Capacidad Nominal (Max) (kg / lb / t) (34%) | Sensibilidad Nominal (mV/V) (28%)
        r2_y = y - row_h
        w_ns = cw * 0.36
        w_cap = cw * 0.34
        w_sen = cw - w_ns - w_cap
        self._draw_labeled_cell(c, self.ML, r2_y, w_ns, row_h, "Número de Serie:", ns)
        self._draw_labeled_cell(c, self.ML + w_ns, r2_y, w_cap, row_h, "Capacidad Nominal (Max) (kg/lb/t):", cap_max)
        self._draw_labeled_cell(
            c, self.ML + w_ns + w_cap, r2_y, w_sen, row_h,
            "Sensibilidad Nominal (mV/V):",
            f"{sensibilidad} mV/V" if sensibilidad and "mv" not in sensibilidad.lower() else sensibilidad,
        )

        # Fila 3: Resistencia Nominal Entrada / Salida: ___________ Ohms (ej. 350 Ω / 700 Ω / 1000 Ω)
        r3_y = y - row_h * 2
        res_display = f"{res_nominal} Ohms" if res_nominal and "ohm" not in res_nominal.lower() and "Ω" not in res_nominal else res_nominal
        self._draw_labeled_cell(
            c, self.ML, r3_y, cw, row_h,
            "Resistencia Nominal Entrada / Salida (Ohms — ej. 350 Ω / 700 Ω / 1000 Ω):",
            res_display,
        )

        # Fila 4: Configuración de Cables / Colores: [ Exc+: Rojo | Exc-: Negro | Sig+: Verde | Sig-: Blanco | Blindaje: Malla | Sense: Si/No ]
        r4_y = y - row_h * 3
        c.setStrokeColor(_GRAY_LIGHT)
        c.setLineWidth(0.35)
        c.rect(self.ML, r4_y - row_h, cw, row_h, fill=0, stroke=1)
        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 6.0)
        c.drawString(self.ML + 4, r4_y - 10.2, "Configuración de Cables / Colores:")

        cables_str = (
            f"[ Exc+: {exc_pos_col}  |  Exc-: {exc_neg_col}  |  "
            f"Sig+: {sig_pos_col}  |  Sig-: {sig_neg_col}  |  "
            f"Blindaje: {blindaje_col}  |  Sense: {sense_col} ]"
        )
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(self.ML + 116, r4_y - 10.2, cables_str)

        return y - total_h

    def _draw_seccion_2_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        insp = d.get("inspeccion_fisica_celda")
        if not isinstance(insp, dict):
            insp = {}

        row_h = 13.0
        for idx, (key, label) in enumerate(self.SECCION_2_ITEMS):
            bg = _GRAY_ROW if idx % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.3)
            c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=1)

            item_val = insp.get(key)
            estado_sel = ""
            obs_txt = ""
            if isinstance(item_val, dict):
                estado_sel = str(item_val.get("estado") or item_val.get("criterio") or "").strip().upper()
                obs_txt = str(item_val.get("obs") or item_val.get("observacion") or "").strip()
            elif isinstance(item_val, str):
                estado_sel = item_val.strip().upper()

            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.2)
            c.drawString(self.ML + 5, y - 9.0, label)

            # Checkboxes [ B ] [ R ] [ M ] [ N/A ]
            crit_x = self.ML + 225
            for opt in ("B", "R", "M", "N/A"):
                checked = (estado_sel == opt)
                self._draw_checkbox(c, crit_x, y - 9.6, size=6.0, checked=checked)
                c.setFillColor(_RED if checked else _DARK_HDR)
                c.setFont("Helvetica-Bold" if checked else "Helvetica", 5.8)
                c.drawString(crit_x + 7.5, y - 8.8, opt)
                crit_x += 23 if opt != "N/A" else 28

            # | Obs: _________________
            obs_lbl_x = self.ML + 324
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 5.8)
            c.drawString(obs_lbl_x, y - 8.8, "| Obs:")
            line_start = obs_lbl_x + 21
            line_end = self.ML + cw - 5
            c.setStrokeColor(_GRAY_DARK)
            c.setLineWidth(0.3)
            c.line(line_start, y - 10.2, line_end, y - 10.2)
            if obs_txt:
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 6.0)
                c.drawString(line_start + 2, y - 8.8, obs_txt[:62])

            y -= row_h

        return y

    def _draw_seccion_3_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        meds = d.get("mediciones_electricas_celda")
        if not isinstance(meds, dict):
            meds = {}

        hdr_h = 13.0
        row_h = 12.8

        # Columnas: [ PARÁMETRO ELÉCTRICO | UND | VALOR MEDIDO | ESTADO (OK / FALLA) ]
        w_param = cw * 0.44
        w_und = cw * 0.10
        w_val = cw * 0.22
        w_est = cw - w_param - w_und - w_val

        # Encabezado de tabla
        c.setFillColor(colors.HexColor("#2B3548"))
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.4)
        c.rect(self.ML, y - hdr_h, cw, hdr_h, fill=1, stroke=1)

        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(self.ML + 6, y - 9.0, "PARÁMETRO ELÉCTRICO")
        c.drawCentredString(self.ML + w_param + w_und / 2, y - 9.0, "UND")
        c.drawCentredString(self.ML + w_param + w_und + w_val / 2, y - 9.0, "VALOR MEDIDO")
        c.drawCentredString(self.ML + w_param + w_und + w_val + w_est / 2, y - 9.0, "ESTADO (OK / FALLA)")
        y -= hdr_h

        for idx, (key, label, und, ok_lbl, fail_lbl) in enumerate(self.SECCION_3_PARAMS):
            bg = _GRAY_ROW if idx % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.3)
            c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=1)

            # Líneas divisorias de columnas
            c.line(self.ML + w_param, y - row_h, self.ML + w_param, y)
            c.line(self.ML + w_param + w_und, y - row_h, self.ML + w_param + w_und, y)
            c.line(self.ML + w_param + w_und + w_val, y - row_h, self.ML + w_param + w_und + w_val, y)

            row_data = meds.get(key)
            val_str = ""
            est_str = ""
            if isinstance(row_data, dict):
                val_str = str(row_data.get("valor") or row_data.get("medido") or "").strip()
                est_str = str(row_data.get("estado") or "").strip().upper()
            elif row_data is not None:
                val_str = str(row_data).strip()

            # Col 1: Parámetro
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.2)
            c.drawString(self.ML + 6, y - 8.8, label)

            # Col 2: Unidad
            c.setFillColor(_GRAY_DARK)
            c.setFont("Helvetica-Bold", 6.2)
            c.drawCentredString(self.ML + w_param + w_und / 2, y - 8.8, und)

            # Col 3: Valor Medido
            val_x1 = self.ML + w_param + w_und + 8
            val_x2 = self.ML + w_param + w_und + w_val - 8
            c.setStrokeColor(_GRAY_DARK)
            c.setLineWidth(0.35)
            c.line(val_x1, y - 10.2, val_x2, y - 10.2)
            if val_str:
                c.setFillColor(_BLACK)
                c.setFont("Helvetica-Bold", 6.8)
                c.drawCentredString(self.ML + w_param + w_und + w_val / 2, y - 8.6, val_str[:22])

            # Col 4: Estado [ ] OK   [ ] Falla  (o [ ] > 5000 MΩ (OK)  [ ] Fuga)
            est_x0 = self.ML + w_param + w_und + w_val + 8
            is_ok = est_str in ("OK", "> 5000 MΩ (OK)", ">5000", "BUENO", "CUMPLE")
            is_fail = est_str in ("FALLA", "FUGA", "MALO", "NO CUMPLE")

            self._draw_checkbox(c, est_x0, y - 9.4, size=6.0, checked=is_ok)
            c.setFillColor(_GREEN_OK if is_ok else _DARK_HDR)
            c.setFont("Helvetica-Bold" if is_ok else "Helvetica", 5.8)
            c.drawString(est_x0 + 8, y - 8.8, ok_lbl)

            fail_x = est_x0 + (78 if len(ok_lbl) > 4 else 48)
            self._draw_checkbox(c, fail_x, y - 9.4, size=6.0, checked=is_fail)
            c.setFillColor(_RED if is_fail else _DARK_HDR)
            c.setFont("Helvetica-Bold" if is_fail else "Helvetica", 5.8)
            c.drawString(fail_x + 8, y - 8.8, fail_lbl)

            y -= row_h

        return y

    def _draw_seccion_4_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        obs_text = str(d.get("observaciones_diagnostico") or d.get("observaciones") or "").strip()
        dictamen_sel = str(d.get("dictamen_celda") or d.get("dictamen") or "").strip().upper()

        wrapped_lines: list[str] = []
        if obs_text:
            for paragraph in obs_text.splitlines():
                paragraph = paragraph.strip()
                if not paragraph:
                    wrapped_lines.append("")
                    continue
                wrapped_lines.extend(simpleSplit(paragraph, "Helvetica", 6.6, cw - 14))

        num_obs_rows = max(4, len(wrapped_lines))
        line_step = 10.5
        obs_box_h = 13.0 + num_obs_rows * line_step + 4.0

        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - obs_box_h, cw, obs_box_h, fill=1, stroke=1)

        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.2)
        c.drawString(self.ML + 5, y - 9.0, "Observaciones Técnicas y Diagnóstico:")

        for i in range(num_obs_rows):
            ly = y - 19.5 - i * line_step
            c.setStrokeColor(_GRAY_LIGHT)
            c.setLineWidth(0.35)
            c.line(self.ML + 6, ly - 1.5, self.ML + cw - 6, ly - 1.5)
            if i < len(wrapped_lines) and wrapped_lines[i]:
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 6.6)
                c.drawString(self.ML + 7, ly, wrapped_lines[i])

        y -= obs_box_h + 2.5

        # Dictamen Final de la Celda
        dict_h = 41.0
        c.setFillColor(_CREAM_BG)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(self.ML, y - dict_h, cw, dict_h, fill=1, stroke=1)

        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(self.ML + 5, y - 8.5, "Dictamen Final de la Celda:")

        for idx, (d_code, d_text) in enumerate(self.DICTAMENES):
            dy = y - 17.5 - idx * 9.8
            is_d = (
                dictamen_sel == d_code
                or (d_code == "OPERATIVA" and "OPERATIVA" in dictamen_sel)
                or (d_code == "REPARABLE" and "REPARABLE" in dictamen_sel)
                or (d_code == "DANADA" and ("DAÑADA" in dictamen_sel or "DANADA" in dictamen_sel or "DESCALIBRADA" in dictamen_sel))
            )
            self._draw_checkbox(c, self.ML + 8, dy - 1.2, size=6.5, checked=is_d)
            c.setFillColor(_RED if is_d else _BLACK)
            c.setFont("Helvetica-Bold" if is_d else "Helvetica", 6.1)
            c.drawString(self.ML + 17.5, dy, d_text)

        return y - dict_h

    def _draw_seccion_5_osocc(self, c, y: float, d: dict, digital: bool = False) -> float:
        cw = self.CW
        box_h = 62.0
        half_w = (cw - 8.0) / 2.0

        tec_nombre = str(d.get("tecnico_nombre") or d.get("tecnico") or "").strip()
        tec_puesto = str(d.get("puesto_tecnico") or "Técnico de Servicio / Laboratorio").strip() if (digital or d.get("puesto_tecnico")) else ""
        cli_nombre = str(d.get("nombre_ing") or d.get("firma_cliente_nombre") or "").strip() if digital else ""
        cli_puesto = str(d.get("puesto_ing") or d.get("area_cliente") or "").strip() if digital else ""

        firma_tec_b64 = d.get("firma_tecnico") or d.get("firma_tecnico_b64") or _firma_perfil_tecnico(d)
        firma_cli_b64 = d.get("firma_cliente") or d.get("firma_cliente_b64")

        # Columna Izquierda: Evaluó / Técnico Responsable
        lx = self.ML
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(lx, y - box_h, half_w, box_h, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(lx + 6, y - 9.0, "Evaluó / Técnico Responsable:")

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 20.0, "Nombre:")
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.35)
        c.line(lx + 36, y - 21.0, lx + half_w - 6, y - 21.0)
        if tec_nombre:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.3)
            c.drawString(lx + 38, y - 19.8, tec_nombre[:40])

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 31.0, "Puesto:")
        c.line(lx + 36, y - 32.0, lx + half_w - 6, y - 32.0)
        if tec_puesto:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 6.2)
            c.drawString(lx + 38, y - 30.8, tec_puesto[:40])

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(lx + 6, y - 54.0, "Firma:")
        c.line(lx + 36, y - 55.0, lx + half_w - 6, y - 55.0)
        if digital and firma_tec_b64:
            self._draw_sig_b64(c, firma_tec_b64, lx + 45, y - 54.0, width=110, height=21)

        # Columna Derecha: Recibió / Almacén o Cliente
        rx = self.ML + half_w + 8.0
        c.setFillColor(_WHITE)
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.45)
        c.rect(rx, y - box_h, half_w, box_h, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(rx + 6, y - 9.0, "Recibió / Almacén o Cliente:")

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 20.0, "Nombre:")
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.35)
        c.line(rx + 36, y - 21.0, rx + half_w - 6, y - 21.0)
        if cli_nombre:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 6.3)
            c.drawString(rx + 38, y - 19.8, cli_nombre[:40])

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 31.0, "Puesto:")
        c.line(rx + 36, y - 32.0, rx + half_w - 6, y - 32.0)
        if cli_puesto:
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 6.2)
            c.drawString(rx + 38, y - 30.8, cli_puesto[:40])

        c.setFillColor(_GRAY_DARK)
        c.setFont("Helvetica-Bold", 5.8)
        c.drawString(rx + 6, y - 54.0, "Firma:")
        c.line(rx + 36, y - 55.0, rx + half_w - 6, y - 55.0)
        if digital and firma_cli_b64:
            self._draw_sig_b64(c, firma_cli_b64, rx + 45, y - 54.0, width=110, height=21)

        return y - box_h


# ---------------------------------------------------------------------------
# Instancias singleton
# ---------------------------------------------------------------------------
osob_pdf_generator = OsobPdfGenerator()
osocc_pdf_generator = OsoccPdfGenerator()
os_pdf_generator = OsPdfGenerator()
