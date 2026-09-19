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
import io
import base64
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from services.metrology import (
        decimals_from_d, fmt, fmt_patron, calc_emt,
        parse_d, clase_desde_os, clase_label,
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

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Toma de Datos - {os_data.get('folio_os', '')}")
        c.setAuthor("Servicios PESA")
        c.setSubject("Orden de Servicio Metrologica")

        self._draw_page(c, os_data, repetibilidad, excentricidad, exactitud,
                        tecnico_nombre, digital=digital,
                        firma_tecnico_b64=firma_tecnico_b64)

        c.save()
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

        # Titulo TOMA DE DATOS — fuente reducida (22pt) para balance y compactidad
        titulo_y = section_y - 8
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 22)
        c.drawCentredString(self.ML + self.CW / 2, titulo_y - 22, "TOMA DE DATOS")
        c.setFont("Helvetica-Bold", 8)
        c.setFillColor(_GRAY_DARK)
        c.drawCentredString(self.ML + self.CW / 2, titulo_y - 32, "PESAJE SISTEMAS Y AUTOMATIZACION")

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
            ("DIRECCIÓN", "direccion_cliente"),
        ]:
            # Fondo blanco — sin barras negras
            c.setFillColor(_WHITE)
            c.rect(self.ML, y - row_h, self.CW, row_h, fill=1, stroke=0)

            # Etiqueta en rojo y negrita
            c.setFillColor(_RED)
            c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 4, y - row_h + 5, lbl + ":")

            # Valor — busca en múltiples claves para compatibilidad
            if lbl == "DIRECCIÓN":
                valor = str(
                    os_data.get("domicilio") or
                    os_data.get("direccion_planta") or
                    os_data.get("sucursal_nombre") or
                    os_data.get("sucursal_direccion") or
                    os_data.get("sucursal") or
                    os_data.get("direccion") or
                    ""
                )
                if not valor and os_data.get("direccion_cliente") and os_data.get("direccion_cliente") != os_data.get("cliente"):
                    valor = str(os_data.get("direccion_cliente"))
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
        field_row([
            ("ID INDICADOR / EQUIPO", os_data.get("equipo_id") or os_data.get("id_equipo"), _f2_net * 0.30),
            ("TIPO DE INSTRUMENTO",   _tipo_inst,      _f2_net * 0.38),
            ("FUNCIONAMIENTO",        _funcionamiento, _f2_net * 0.32),
        ], y)
        y -= fila_h

        # ── Fila 3: Capacidad / División / Puntos Apoyo / Ubicación ──────────
        _puntos_apoyo_raw = str(os_data.get("puntos_apoyo") or os_data.get("puntos_de_apoyo") or "").strip()
        _puntos_apoyo = _puntos_apoyo_raw if _puntos_apoyo_raw.lower() not in ['libre', 'none', 'null', '\u2014', '0', ''] else ''

        _cap_val = os_data.get("equipo_alcance")  or os_data.get("alcance_max")  or os_data.get("capacidad_max")
        _div_val  = os_data.get("equipo_division") or os_data.get("div_minima")   or os_data.get("division_min")
        _dve_val  = os_data.get("dve") or os_data.get("equipo_dve") or ""
        _ubic    = os_data.get("equipo_ubicacion") or os_data.get("ubicacion") or ""

        if tiene_inspeccion:
            _f3_gap = 3 * GAP
            _f3_net = cw - _f3_gap
            _unidad_pdf = str(os_data.get("unidad_medida") or "kg").strip() or "kg"
            _cap_str  = f"{_cap_val} {_unidad_pdf}" if _cap_val else None
            _div_str  = f"{_div_val} {_unidad_pdf}" if _div_val else None
            field_row([
                ("CAPACIDAD M\u00c1XIMA", _cap_str,      _f3_net * 0.26),
                ("DIVISI\u00d3N M\u00cdNIMA",  _div_str,       _f3_net * 0.22),
                ("DVE",              _dve_val,        _f3_net * 0.22),
                ("PUNTOS DE APOYO",  _puntos_apoyo,   _f3_net * 0.30),
            ], y)
            y -= fila_h
            field_row([("UBICACI\u00d3N", _ubic, cw)], y)
            y -= fila_h
        else:
            _f3_gap = 3 * GAP
            _f3_net = cw - _f3_gap
            _unidad_pdf = str(os_data.get("unidad_medida") or "kg").strip() or "kg"
            _cap_str2 = f"{_cap_val} {_unidad_pdf}" if _cap_val else None
            _div_str2 = f"{_div_val} {_unidad_pdf}" if _div_val else None
            field_row([
                ("CAPACIDAD M\u00c1XIMA", _cap_str2,     _f3_net * 0.25),
                ("DIVISI\u00d3N M\u00cdNIMA",  _div_str2,      _f3_net * 0.22),
                ("PUNTOS DE APOYO",  _puntos_apoyo,   _f3_net * 0.20),
                ("UBICACI\u00d3N",        _ubic,           _f3_net * 0.33),
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

            y_left = self._draw_repetibilidad_table(c, left_x, y, left_w, rep)
            y_left -= 6

            # Recuadro NO APTO para excentricidad con dibujo vectorial del tipo de instrumento
            y_left = self._draw_no_aplica_exc_box(c, left_x, y_left, left_w, tipo_no)

            if os_data and os_data.get("es_enlace_sustitucion"):
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

        geo_key  = (geo or "").strip().lower()
        n_sec    = int(os_data.get("num_secciones") or 4)

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

        # Puntos en esquinas y centro
        p1_pts = [
            (sq_x,        sq_y + sq_h, "1",  -6,  0),   # Sup-Izq
            (sq_x + sq_w, sq_y + sq_h, "4",   2,  0),   # Sup-Der
            (sq_x,        sq_y,        "2",  -6, -5),   # Inf-Izq
            (sq_x + sq_w, sq_y,        "3",   2, -5),   # Inf-Der
            (p1_cx,       sq_y + sq_h / 2, "5", 2, -2), # Centro
        ]
        for px, py, t, dx, dy in p1_pts:
            fdot(px, py)
            num_label(px, py, t, dx, dy)

        sep_line(p1_x + panel_w)
        # Marcar 'Plataforma' si la geometría es cuadrada/rectangular o 'plataforma'
        _is_plataforma = ("cuadrada" in geo_key or "plataforma" in geo_key or
                          (not geo_key and True))  # default si vacío = plataforma
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

        # Puntos en cardinales y centro
        p2_pts = [
            (p2_cx,      p2_cy + ry, "1",  2,  1),   # Norte
            (p2_cx + rx, p2_cy,      "2",  2, -2),   # Este
            (p2_cx,      p2_cy - ry, "3",  2, -7),   # Sur
            (p2_cx - rx, p2_cy,      "4", -7, -2),   # Oeste
            (p2_cx,      p2_cy,      "5",  2, -2),   # Centro
        ]
        for px, py, t, dx, dy in p2_pts:
            fdot(px, py)
            num_label(px, py, t, dx, dy)

        sep_line(p2_x + panel_w)
        checkbox_row(p2_cx, body_top - body_h + 1,
                     "Circular", "circular" in geo_key)

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
                     f"Camionera ({n_sec} Sec.)", "camionera" in geo_key)


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
            if fin is not None and ini is not None:
                try:
                    error_val = _sf(fin) - _sf(ini)
                except Exception:
                    pass
            elif fin is not None and carga is not None:
                try:
                    error_val = _sf(fin) - _sf(carga)
                except Exception:
                    pass

            cell_vals = [
                (str(i + 1) if i < len(data) and carga is not None else None),
                (fmt_patron(carga) if carga is not None else None),
                (fmt(ini, d) if ini is not None else None),
                (fmt(fin, d) if fin is not None else None),
                (fmt(error_val, d) if error_val is not None else (fmt(0, d) if fin is not None else None)),
            ]

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 8)
            col_widths_rep = [w * 0.08, w * 0.22, w * 0.24, w * 0.24, w * 0.22]
            cx = x
            _is_dig_rep = str((os_data or {}).get("modalidad") or "").upper() != "FISICO"
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
            if lf is not None:
                if li is not None:
                    errors.append(abs(lf - li))
                elif cargo is not None:
                    errors.append(abs(lf - cargo))
        _is_fisico_rep = str((os_data or {}).get("modalidad") or "").upper() == "FISICO"
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
                error_val = abs(_sf(fin_val) - _sf(carga_row))
                errors_all.append(error_val)

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", data_font_size)
            cx = x

            # Col 0: POSICION
            c.drawCentredString(cx + col_widths[0] / 2,
                                y - row_h + max(2.5, row_h * 0.28), pos_label)
            cx += col_widths[0]

            # Col 1: L. INICIAL (diagonal SOLO en digital con datos; físico = blanco)
            _is_digital_form = str((os_data or {}).get("modalidad") or "").upper() != "FISICO"
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

            # Col 3: ERROR — Negro si = 0, Rojo si > 0 (nunca verde)
            if error_val is not None:
                c.setFillColor(_RED if error_val > 0 else _BLACK)
                c.setFont("Helvetica-Bold", data_font_size)
                c.drawCentredString(cx + col_widths[3] / 2,
                                    y - row_h + max(2.5, row_h * 0.28),
                                    self._fmt(error_val, d_dec))
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", data_font_size)
            else:
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
        _is_fisico_exc = str((os_data or {}).get("modalidad") or "").upper() == "FISICO"
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
        if os_data and os_data.get("es_enlace_sustitucion"):
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
            vals = [
                str(i + 1),
                self._fmt_int(nom_val),      # Valor nominal como entero: "1", "2", "5"
                self._fmt(ini_val, d_dec) if ini_val is not None else None,
                self._fmt(fin_val, d_dec),
                self._fmt(error_ex, d_dec) if error_ex is not None else self._fmt(0, d_dec),
            ]
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 7.5)
            cx = x
            _is_dig_ex = str((os_data or {}).get("modalidad") or "").upper() != "FISICO"
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
        c.drawRightString(x + w - 3, y - row_h + 4,
                          self._fmt(max(errors_ex), d_dec_ex) if errors_ex else self._fmt(0, d_dec_ex))
        y -= row_h
        return y

    def _draw_elementos_sustitucion(self, c, x: float, y: float, w: float, os_data: dict) -> float:
        """Tabla para Elementos de Carga Sustituta (Canastas, Cadenas, etc.)"""
        from reportlab.lib.colors import HexColor
        _HDR = HexColor("#D9E2F3")
        
        row_h = 13
        hdr_h = 14
        
        c.setFillColor(_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=1)
        c.setFillColor(HexColor("#000000"))
        c.setFont("Helvetica-Bold", 6.5)
        
        c.drawCentredString(x + w * 0.35, y - hdr_h + 4, "SUSTITUTO")
        c.drawCentredString(x + w * 0.85, y - hdr_h + 4, "PESO")
        
        c.setStrokeColor(HexColor("#333333"))
        c.setLineWidth(0.3)
        c.line(x + w * 0.7, y, x + w * 0.7, y - hdr_h)
        y -= hdr_h
        
        for i in range(3):
            c.setFillColor(HexColor("#FFFFFF"))
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
            c.line(x + w * 0.7, y, x + w * 0.7, y - row_h)
            y -= row_h
            
        c.setFillColor(HexColor("#FFFFFF"))
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.line(x + w * 0.7, y, x + w * 0.7, y - row_h)
        c.setFillColor(HexColor("#000000"))
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 5, y - row_h + 4, "TOTAL")
        y -= row_h
        
        return y

    def _draw_exactitud_enlaces(self, c, x: float, y: float, w: float, data: list, os_data: dict) -> float:
        """
        Tabla de Exactitud en modo 'Calibración por Enlaces de Sustitución' (7 columnas).
        El número de filas se determina dinámicamente por os_data['num_enlaces_sustitucion'].
        Soporta 5, 8 o 10 enlaces con row_h adaptativo para no romper la hoja Carta.
        """
        _ROW_BG    = _WHITE
        _LBL       = _BLACK

        hdr_h     = 16

        # ── Número de filas dinámico (prioridad: num_enlaces_sustitucion → num_enlaces → fallback 8) ──
        num_enlaces = int(
            os_data.get("num_enlaces_sustitucion")
            or os_data.get("num_enlaces")
            or 8
        )
        num_enlaces = max(1, num_enlaces)  # al menos 1 fila

        # ── Altura de fila adaptativa según cantidad de enlaces ────────────────
        if num_enlaces <= 5:
            row_h = 16
        elif num_enlaces <= 8:
            row_h = 13
        else:  # 9-10+ enlaces: reducir para que quepan en el espacio vertical disponible
            row_h = 11

        # ── Padding vertical adaptativo para filas muy densas ─────────────────
        data_font_size = 8 if num_enlaces <= 8 else 7
        y_offset_text  = 4 if row_h >= 13 else 3   # offset vertical del texto dentro de celda

        # Anchos de columna basados en la solicitud exacta sumando 327 pt (redistribuidos al ancho w de 340pt)
        col_w = [w * (16/327), w * (48/327), w * (48/327), w * (65/327), w * (55/327), w * (50/327), w * (45/327)]
        col_hdrs = ["N", "PESAS", "AGUA", "AGUA + PESAS", "INDICACIÓN", "REGRESO", "ERROR"]

        # ── Título y Cabecera Combinados (estilo Pesa ERP) ────────────
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

        # Filas dinámicas: exactamente num_enlaces filas numeradas
        for n in range(1, num_enlaces + 1):
            c.setFillColor(_ROW_BG)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
            
            row = data[n - 1] if data and (n - 1) < len(data) else {}
            
            # Mapeo flexible de datos de la toma
            pesas       = row.get("pesas")
            agua        = row.get("agua")
            agua_pesas  = row.get("agua_pesas")
            indicacion  = row.get("indicacion") or row.get("lectura_inicial")
            regreso     = row.get("regreso")    or row.get("lectura_final")
            error       = row.get("error")
            
            # Para renglones no utilizados, defaults según especificación
            is_empty = not any(v is not None and str(v).strip() != "" for v in [pesas, agua, indicacion])
            if is_empty:
                agua_pesas = ""
                error = ""

            vals = [
                str(n),
                self._fmt(pesas) if pesas is not None else "",
                self._fmt(agua) if agua is not None else "",
                self._fmt(agua_pesas) if agua_pesas is not None else "",
                self._fmt(indicacion) if indicacion is not None else "",
                self._fmt(regreso) if regreso is not None else "",
                self._fmt(error) if error is not None else ""
            ]
            
            c.setFillColor(_LBL)
            cx_ = x
            for i, (v, cw_) in enumerate(zip(vals, col_w)):
                if i == 0:
                    c.setFont("Helvetica-BoldOblique", min(7.5, data_font_size))
                else:
                    c.setFont("Helvetica", data_font_size)
                c.drawCentredString(cx_ + cw_ / 2, y - row_h + y_offset_text, v)
                cx_ += cw_
                
            self._draw_col_lines(c, x, y, row_h, col_w)
            y -= row_h


        # Fila base de Error Encontrado para consistencia (opcional, o se maneja arriba)
        # La plantilla original tenía la barra de error abajo.
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawString(x + 3, y - row_h + 4, "ERROR MÁXIMO ENCONTRADO:")
        
        # Calcular error máximo real si hay datos
        errors = []
        _sf = self._seguro_float
        if data:
            for r in data:
                e_val = r.get("error")
                if e_val is not None and str(e_val).strip() not in ("", "None"):
                    errors.append(abs(_sf(e_val)))
        if errors:
            c.drawRightString(x + w - 3, y - row_h + 4, self._fmt(max(errors)))
            
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
        Sección OBSERVACIONES: líneas en blanco proporcionales al espacio disponible.
        Espaciado de líneas ampliado (18 pt) y margen inferior respetado.
        Se preserva un bloque amplio con 5-6 renglones visibles para anotaciones a mano.
        """
        y -= 18  # Espaciado moderado antes del encabezado
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawCentredString(self.ML + self.CW / 2, y, "OBSERVACIONES")   # CENTRADO
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 8

        obs = os_data.get("observaciones", "") or ""
        c.setFillColor(_BLACK)
        c.setFont("Helvetica", 8)

        # Reservar espacio: firmas (65pt) + nota (55pt) + cintillo (28pt) + margen (10pt)
        limit_y = self.MB + 158
        line_gap = 18   # espacio generoso entre renglones para escritura a mano

        # Espaciado entre línea roja de "OBSERVACIONES" y primer renglón pautado
        y -= 14   # 14 pt adicionales para que el texto no choque con el header

        # 1. Calcular cuántas líneas caben
        all_lines_y = []
        _scan_y = y
        while _scan_y > limit_y:
            all_lines_y.append(_scan_y)
            _scan_y -= line_gap

        # 2. Preparar líneas de texto (word-wrap)
        text_lines = []
        if obs:
            words = obs.split()
            cur_line = ""
            for word in words:
                test = (cur_line + " " + word).strip()
                if c.stringWidth(test, "Helvetica", 8) < self.CW - 4:
                    cur_line = test
                else:
                    if cur_line:
                        text_lines.append(cur_line)
                    cur_line = word
            if cur_line:
                text_lines.append(cur_line)

        # 3. Dibujar: primero la línea pautada, luego el texto sobre ella
        first_empty_idx = len(text_lines)   # índice de la primera línea sin texto
        for idx, line_y in enumerate(all_lines_y):
            # Línea pautada gris
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.line(self.ML, line_y, self.ML + self.CW, line_y)
            # Texto (si corresponde a esta línea)
            if idx < len(text_lines):
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 8)
                # +2 pt sobre la línea para que el texto descanse sobre ella
                c.drawString(self.ML + 2, line_y + 2, text_lines[idx])

        # 4. Diagonal de cancelación en las líneas vacías
        empty_lines = all_lines_y[first_empty_idx:]
        if len(empty_lines) >= 2:
            top_y    = empty_lines[0]
            bot_y    = empty_lines[-1]
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            c.line(self.ML, top_y, self.ML + self.CW, bot_y)

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
        _firma_b64_efectiva = (
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
            f = float(value)
            if f == int(f):
                return str(int(f))
            return str(f)
        except (TypeError, ValueError):
            return str(value)

    @staticmethod
    def _seguro_float(val, default: float = 0.0) -> float:
        """Convierte cualquier valor a float de forma segura. Nunca lanza excepciones."""
        if val is None:
            return default
        if isinstance(val, (int, float)):
            return float(val)
        try:
            s = str(val).strip().replace(',', '.')
            return float(s) if s else default
        except (ValueError, TypeError):
            return default

    @staticmethod
    def _fmt(value, dec: int = None) -> str:
        if value is None or str(value).strip() == "":
            return ""
        try:
            f = float(value)
            if dec is not None:
                return f"{f:.{dec}f}"
            return "0" if f == 0 else f"{f:.4f}".rstrip("0").rstrip(".")
        except (TypeError, ValueError):
            return str(value)

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
# Instancia singleton
# ---------------------------------------------------------------------------
os_pdf_generator = OsPdfGenerator()
