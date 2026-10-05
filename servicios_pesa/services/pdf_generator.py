"""
Generador de PDF — Toma de Datos / Orden de Servicio.
Réplica fiel del formato oficial de Básculas PESA.
Usa ReportLab canvas para control pixel-perfect del layout.

Uso:
    from services.pdf_generator import pdf_generator
    path = pdf_generator.generate_os_pdf(os_data, repetibilidad, excentricidad, exactitud)
"""
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.units import cm, mm
    from reportlab.lib import colors
    from reportlab.pdfgen import canvas as rl_canvas
    from reportlab.platypus import Table, TableStyle
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.platypus import Paragraph
    from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
    _RL_OK = True
except ImportError:
    _RL_OK = False
    logger.warning("ReportLab no instalado: pip install reportlab")

# ─── Constantes de color ───────────────────────────────────────────────────────
_RED        = colors.HexColor("#CC1F1F")
_DARK       = colors.HexColor("#1A1A2E")
_DARK_HDR   = colors.HexColor("#1C1C1C")
_GRAY_HDR   = colors.HexColor("#2D2D2D")
_GRAY_LIGHT = colors.HexColor("#F5F5F5")
_GRAY_MED   = colors.HexColor("#CCCCCC")
_GRAY_DARK  = colors.HexColor("#888888")
_BLACK      = colors.black
_WHITE      = colors.white

# Paleta de la tabla metrológica
_TBL_HDR_RED  = colors.HexColor("#CC1F1F")   # Encabezado rojo (REPETIBILIDAD, etc.)
_TBL_COL_RED  = colors.HexColor("#CC1F1F")   # Fila de columnas
_TBL_ROW_ALT  = colors.HexColor("#F5F5F5")
_TBL_BORDER   = colors.HexColor("#CCCCCC")


# ══════════════════════════════════════════════════════════════════════════════
class PdfGenerator:
    """
    Genera el PDF "Toma de Datos" de una Orden de Servicio.
    Layout en puntos (1 pt = 1/72 inch).
    Tamaño de página: Letter = 612 × 792 pt.
    """

    # Márgenes
    ML = 36   # left
    MR = 36   # right
    MT = 15   # top
    MB = 15   # bottom

    @property
    def W(self): return 612   # ancho útil total
    @property
    def H(self): return 792   # alto total

    @property
    def CW(self): return self.W - self.ML - self.MR   # 540 pt útiles

    # ── API Pública ───────────────────────────────────────────────────────────

    def generate_os_pdf(
        self,
        os_data: dict,
        repetibilidad: list[dict] = None,
        excentricidad: list[dict] = None,
        exactitud: list[dict] = None,
        output_path: Optional[str] = None,
        tecnico_nombre: Optional[str] = None,
    ) -> str:
        """
        Genera el PDF completo de la OS.

        Args:
            os_data:       Dict con los datos de la OS (de v_ordenes_servicio).
            repetibilidad: Filas de det_repetibilidad.
            excentricidad: Filas de det_excentricidad.
            exactitud:     Filas de det_exactitud.
            output_path:   Ruta de salida (si None → temp).
            tecnico_nombre:Nombre del técnico (si no viene en os_data).

        Returns:
            Ruta absoluta del PDF generado.
        """
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado. Ejecutar: pip install reportlab")

        repetibilidad = repetibilidad or []
        excentricidad = excentricidad or []
        exactitud     = exactitud     or []

        # Ruta de salida
        if output_path is None:
            folio = os_data.get("folio_os", "OS")
            output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
            output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Toma de Datos — {os_data.get('folio_os', '')}")
        c.setAuthor("Servicios PESA")
        c.setSubject("Orden de Servicio Metrológica")

        self._draw_page(c, os_data, repetibilidad, excentricidad, exactitud, tecnico_nombre)

        c.save()
        logger.info(f"PDF generado: {output_path}")
        return output_path

    # ── Dibujo completo de la página ──────────────────────────────────────────

    def _draw_page(self, c, os_data, rep, exc, exac, tecnico_nombre) -> None:
        """Dibuja todos los elementos de la página en orden de arriba hacia abajo."""
        y = self.H  # cursor Y, desciende

        y = self._draw_header(c, y, os_data)
        y = self._draw_fecha(c, y, os_data)
        y = self._draw_cliente(c, y, os_data)
        y = self._draw_equipo(c, y, os_data)
        y = self._draw_pruebas(c, y, rep, exc, exac, os_data)
        y = self._draw_observaciones(c, y, os_data)
        self._draw_footer(c, os_data, tecnico_nombre)

    # ── SECCIÓN 1: Encabezado ─────────────────────────────────────────────────

    def _draw_header(self, c, y: float, os_data: dict) -> float:
        """Logo BP PESA | logo Rice Lake | título | folio."""
        top = y - self.MT
        BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        
        # ── Logo BP PESA (izquierda) ──────────────────────────────────────────
        logo_pesa_path = os.path.join(BASE_DIR, 'Img', 'logo_pesa.png')
        try:
            # Insertar imagen proporcionalmente (ancho: ~140, alto: ajustado, aprox 40)
            c.drawImage(logo_pesa_path, self.ML, top - 34, width=150, height=40, preserveAspectRatio=True, mask='auto')
        except Exception as e:
            logger.warning(f"No se pudo cargar logo_pesa.png: {e}")
            # Fallback seguro
            c.setFillColor(_RED)
            c.rect(self.ML, top - 34, 40, 34, fill=1, stroke=0)
            c.setFillColor(_WHITE)
            c.setFont("Helvetica-Bold", 18)
            c.drawCentredString(self.ML + 20, top - 22, "BP")
            c.setFillColor(_BLACK)
            c.setFont("Helvetica-Bold", 13)
            c.drawString(self.ML + 46, top - 12, "BÁSCULAS PESA")
            c.setFont("Helvetica", 7)
            c.drawString(self.ML + 46, top - 22, "UNA EMPRESA QUE PESA ®")

        # ── Logo Rice Lake (derecha) ──────────────────────────────────────────
        rl_x = self.ML + self.CW - 140
        c.setFont("Helvetica", 7)
        c.setFillColor(_GRAY_DARK)
        c.drawString(rl_x, top - 8, "Authorized Distributor")
        
        logo_rice_path = os.path.join(BASE_DIR, 'Img', 'Rice Lake.png')
        try:
            # Insertar imagen proporcionalmente
            c.drawImage(logo_rice_path, rl_x, top - 36, width=140, height=25, preserveAspectRatio=True, mask='auto')
        except Exception as e:
            logger.warning(f"No se pudo cargar Rice Lake.png: {e}")
            # Fallback seguro
            c.setFont("Helvetica-Bold", 14)
            c.setFillColor(_BLACK)
            c.drawString(rl_x, top - 20, "RICE LAKE")
            c.setFont("Helvetica-BoldOblique", 7)
            c.setFillColor(_RED)
            c.drawString(rl_x, top - 28, "WEIGHING SYSTEMS")
            c.setFont("Helvetica", 6)
            c.setFillColor(_GRAY_DARK)
            c.drawString(rl_x, top - 36, "Exactitud • Confiabilidad • Durabilidad")

        # ── Línea divisoria ───────────────────────────────────────────────────
        sep_y = top - 42
        c.setStrokeColor(_GRAY_MED)
        c.setLineWidth(0.5)
        c.line(self.ML, sep_y, self.ML + self.CW, sep_y)

        # ── Título (Área central limpia) ────────────────────────────────────
        titulo_y = sep_y - 4

        # ── Caja de Folio (derecha) ───────────────────────────────────────────
        folio_x  = self.ML + self.CW - 150
        folio_w  = 150
        folio_h  = 48
        folio_y  = titulo_y - folio_h

        # Borde exterior rojo
        c.setStrokeColor(_RED)
        c.setLineWidth(1.5)
        c.rect(folio_x, folio_y, folio_w, folio_h, fill=0, stroke=1)

        # Etiqueta "FOLIO / OS" con fondo rojo
        c.setFillColor(_RED)
        c.rect(folio_x, folio_y + folio_h - 16, folio_w, 16, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(folio_x + folio_w / 2, folio_y + folio_h - 11, "FOLIO / OS")

        # Número de folio
        folio_text = os_data.get("folio_os", "—")
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(folio_x + folio_w / 2, folio_y + 9, folio_text)

        return titulo_y - 52   # Nueva posición Y después del encabezado

    # ── SECCIÓN 2: Fecha ──────────────────────────────────────────────────────

    def _draw_fecha(self, c, y: float, os_data: dict) -> float:
        fecha = os_data.get("fecha")
        if fecha:
            fecha_str = str(fecha)[:10]
            partes = fecha_str.split("-")
            fecha_fmt = f"__{partes[2]}__ / __{partes[1]}__ / __{partes[0]}__" if len(partes) == 3 else fecha_str
        else:
            fecha_fmt = "______ / ______ / ______"

        y -= 6
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, "FECHA:")
        c.setFont("Helvetica", 8)
        c.drawString(self.ML + 32, y, "  _____ / _____ / _________")
        y -= 10
        return y

    # ── SECCIÓN 3: Cliente / Dirección ────────────────────────────────────────

    def _draw_cliente(self, c, y: float, os_data: dict) -> float:
        row_h = 18
        y -= 2

        for lbl, key in [("CLIENTE", "cliente"), ("DIRECCIÓN", "direccion_cliente")]:
            # Franja oscura con label
            c.setFillColor(_DARK_HDR)
            c.rect(self.ML, y - row_h, self.CW, row_h, fill=1, stroke=0)

            # Ícono (círculo simple)
            c.setFillColor(_WHITE)
            c.circle(self.ML + 8, y - row_h / 2, 5, fill=1, stroke=0)
            c.setFillColor(_DARK_HDR)
            c.setFont("Helvetica-Bold", 6)
            c.drawCentredString(self.ML + 8, y - row_h / 2 - 2, "★")

            # Texto label
            c.setFillColor(_WHITE)
            c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 18, y - row_h + 5, lbl)

            # Valor (en blanco a la derecha del label)
            valor = str(os_data.get(key, "") or "")
            c.setFont("Helvetica", 8)
            c.drawString(self.ML + 90, y - row_h + 5, valor[:85])

            # Borde completo
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.5)
            c.rect(self.ML, y - row_h, self.CW, row_h, fill=0, stroke=1)

            y -= row_h

        y -= 6
        return y

    # ── SECCIÓN 4: Datos del Equipo ───────────────────────────────────────────

    def _draw_equipo(self, c, y: float, os_data: dict) -> float:
        # Encabezado de sección
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(self.ML, y, "⚙  DATOS DEL EQUIPO")
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 10

        # Definición de campos en 3 filas
        def field_row(fields: list[tuple[str, str, float]], row_y: float):
            """fields: [(label, key, width%), ...]  width en pt"""
            x = self.ML
            for label, key, w in fields:
                valor = str(os_data.get(key, "") or "")[:int(w / 5)]
                c.setFillColor(_GRAY_DARK)
                c.setFont("Helvetica-Bold", 6.5)
                c.drawString(x + 1, row_y + 5, label + ":")
                c.setFillColor(_BLACK)
                c.setFont("Helvetica", 8)
                c.drawString(x + 1, row_y - 4, valor)
                c.setStrokeColor(_GRAY_MED)
                c.setLineWidth(0.3)
                c.line(x, row_y - 8, x + w, row_y - 8)  # Línea inferior
                x += w + 4

        cw = self.CW
        fila_h = 24

        # Fila 1: MARCA | MODELO | N/S | UBICACIÓN
        field_row([
            ("MARCA",    "marca",     cw * 0.22),
            ("MODELO",   "modelo",    cw * 0.22),
            ("N/S",      "ns",        cw * 0.22),
            ("UBICACIÓN","ubicacion", cw * 0.30),
        ], y)
        y -= fila_h

        # Fila 2: ALCANCE MÁX | DIV. MÍNIMA | DIV. VERIFICACIÓN | ID
        field_row([
            ("ALCANCE MÁX.",     "alcance_max",      cw * 0.22),
            ("DIV. MÍNIMA",      "div_minima",       cw * 0.22),
            ("DIV. VERIFICACIÓN","div_verificacion",  cw * 0.22),
            ("ID",               "id_equipo",        cw * 0.30),
        ], y)
        y -= fila_h

        # Fila 3: TIPO INSTRUMENTO (ancho) | NÚMERO CCA | HOLOGRAMA ANTERIOR
        field_row([
            ("TIPO DE INSTRUMENTO","tipo_instrumento", cw * 0.36),
            ("NÚMERO CCA",         "numero_cca",       cw * 0.26),
            ("HOLOGRAMA ANTERIOR", "holograma_anterior",cw * 0.34),
        ], y)
        y -= fila_h + 8

        return y

    # ── SECCIÓN 5: Pruebas Metrológicas ──────────────────────────────────────

    def _draw_pruebas(self, c, y: float, rep, exc, exac, os_data: dict) -> float:
        """Dos columnas: izq (Repetibilidad + Excentricidad) | der (Exactitud)"""

        # Encabezado de sección
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(self.ML, y, "≡  PRUEBAS METROLÓGICAS")
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 8

        left_x  = self.ML
        left_w  = self.CW * 0.44
        right_x = self.ML + left_w + 8
        right_w = self.CW - left_w - 8

        start_y = y

        # ── Columna izquierda ─────────────────────────────────────────────────
        y_left = y
        y_left = self._draw_metrol_table(c, left_x, y_left, left_w, "REPETIBILIDAD",
                                          rep, os_data.get("valor_repetibilidad"))
        y_left -= 8
        y_left = self._draw_metrol_table(c, left_x, y_left, left_w, "EXCENTRICIDAD",
                                          exc, os_data.get("valor_excentricidad"))

        # ── Columna derecha ───────────────────────────────────────────────────
        y_right = y
        y_right = self._draw_exactitud_table(c, right_x, y_right, right_w, exac)
        y_right = self._draw_clase_exactitud(c, right_x, y_right, right_w, os_data.get("clase_exactitud_codigo"))

        # Posición Y final: la menor de las dos columnas
        final_y = min(y_left, y_right) - 8
        return final_y

    def _draw_metrol_table(
        self, c, x: float, y: float, w: float,
        titulo: str, data: list[dict], valor=None
    ) -> float:
        """Dibuja una tabla de Repetibilidad o Excentricidad."""
        col_widths = [w * 0.22, w * 0.39, w * 0.39]
        row_h = 17

        # ── Encabezado principal (título + VALOR:) ────────────────────────────
        hdr_h = 14
        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x + 3, y - hdr_h + 4, titulo)
        # VALOR:
        valor_str = f"VALOR: {valor:.4f}" if valor is not None else "VALOR: _________"
        c.setFont("Helvetica", 7)
        c.drawRightString(x + w - 3, y - hdr_h + 4, valor_str)
        y -= hdr_h

        # ── Encabezados de columnas (fondo rojo) ─────────────────────────────
        cols = ["POSICIÓN", "LECTURA INICIAL", "LECTURA FINAL"]
        c.setFillColor(_TBL_HDR_RED)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.5)
        cx = x
        for i, (col, cw) in enumerate(zip(cols, col_widths)):
            c.drawCentredString(cx + cw / 2, y - row_h + 4, col)
            cx += cw
        y -= row_h

        # ── Filas de datos ─────────────────────────────────────────────────────
        n_rows = max(len(data), 3 if titulo == "REPETIBILIDAD" else 6)
        for row_idx in range(n_rows):
            bg = _GRAY_LIGHT if row_idx % 2 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)

            row_data = data[row_idx] if row_idx < len(data) else {}
            vals = [
                str(row_idx + 1),
                self._fmt(row_data.get("lectura_inicial")),
                self._fmt(row_data.get("lectura_final")),
            ]
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 7.5)
            cx = x
            for v, cw in zip(vals, col_widths):
                c.drawCentredString(cx + cw / 2, y - row_h + 3.5, v)
                cx += cw

            # Borde de la fila
            c.setStrokeColor(_TBL_BORDER)
            c.setLineWidth(0.3)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            y -= row_h

        # ── ERROR MÁXIMO ──────────────────────────────────────────────────────
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(x + 3, y - row_h + 4, "ERROR MÁXIMO ENCONTRADO:")
        # Calcular error máximo
        errors = [
            abs((r.get("lectura_final") or 0) - (r.get("valor_kg") or r.get("carga") or 0))
            for r in data
            if r.get("lectura_final") is not None and (r.get("valor_kg") is not None or r.get("carga") is not None)
        ]
        if errors:
            c.drawRightString(x + w - 3, y - row_h + 4, self._fmt(max(errors)))
        y -= row_h

        c.setStrokeColor(_TBL_BORDER)
        c.setLineWidth(0.3)
        c.rect(x, y, w, -row_h * 0.3, fill=0, stroke=1)  # línea base

        return y

    def _draw_exactitud_table(
        self, c, x: float, y: float, w: float, data: list[dict]
    ) -> float:
        """Dibuja la tabla de Exactitud (10 puntos)."""
        col_widths = [w * 0.10, w * 0.24, w * 0.33, w * 0.33]
        row_h = 17

        # Encabezado principal
        hdr_h = 14
        c.setFillColor(_DARK_HDR)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x + 3, y - hdr_h + 4, "EXACTITUD")
        y -= hdr_h

        # Encabezados columnas
        cols = ["N", "VALOR NOMINAL", "LECTURA INICIAL", "LECTURA FINAL"]
        c.setFillColor(_TBL_HDR_RED)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 6.5)
        cx = x
        for col, cw in zip(cols, col_widths):
            c.drawCentredString(cx + cw / 2, y - row_h + 4, col)
            cx += cw
        y -= row_h

        # 10 filas de datos
        for row_idx in range(10):
            bg = _GRAY_LIGHT if row_idx % 2 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)

            row_data = data[row_idx] if row_idx < len(data) else {}
            vals = [
                str(row_idx + 1),
                self._fmt(row_data.get("valor_nominal")),
                self._fmt(row_data.get("lectura_inicial")),
                self._fmt(row_data.get("lectura_final")),
            ]
            c.setFillColor(_BLACK)
            c.setFont("Helvetica", 7.5)
            cx = x
            for v, cw in zip(vals, col_widths):
                c.drawCentredString(cx + cw / 2, y - row_h + 3.5, v)
                cx += cw

            c.setStrokeColor(_TBL_BORDER)
            c.setLineWidth(0.3)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            y -= row_h

        # ERROR MÁXIMO
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(x + 3, y - row_h + 4, "ERROR MÁXIMO ENCONTRADO:")
        errors = [
            abs((r.get("lectura_final") or 0) - (r.get("valor_nominal") or 0))
            for r in data
            if r.get("lectura_final") is not None and r.get("valor_nominal") is not None
        ]
        if errors:
            c.drawRightString(x + w - 3, y - row_h + 4, self._fmt(max(errors)))
        y -= row_h
        return y

    def _draw_clase_exactitud(
        self, c, x: float, y: float, w: float, clase: Optional[str]
    ) -> float:
        """Dibuja la tabla de selección de Clase de Exactitud."""
        row_h = 14
        y -= 3

        # Encabezado
        c.setFillColor(_GRAY_HDR)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 7)
        c.drawCentredString(x + w / 2, y - row_h + 4, "CLASE DE EXACTITUD")
        y -= row_h

        # Fila de checkboxes I J A | ORDINARIA | MEDIA | FINA | ESPECIAL
        check_h = row_h
        c.setFillColor(_GRAY_LIGHT)
        c.rect(x, y - check_h, w, check_h, fill=1, stroke=1)

        col_ija = w * 0.14
        col_w   = (w - col_ija) / 4

        # I J A headers
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        c.drawCentredString(x + col_ija / 2, y - check_h + 4, "J  I  A")

        clases = [
            ("ORDINARIA\n(IIII)", "IV"),
            ("MEDIA\n(III)",      "III"),
            ("FINA\n(II)",        "II"),
            ("ESPECIAL\n(I)",     "I"),
        ]

        cx = x + col_ija
        for lbl, codigo in clases:
            is_sel = clase and clase.upper() == codigo.upper()

            # Fondo de la celda
            bg = colors.HexColor("#FFE5E5") if is_sel else _WHITE
            c.setFillColor(bg)
            c.rect(cx, y - check_h, col_w, check_h, fill=1, stroke=1)

            # Checkbox cuadradito
            chk_size = 6
            chk_x = cx + (col_w - chk_size) / 2
            chk_y = y - check_h + (check_h - chk_size) / 2

            if is_sel:
                c.setFillColor(_RED)
                c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=0)
                c.setFillColor(_WHITE)
                c.setFont("Helvetica-Bold", 6)
                c.drawCentredString(chk_x + chk_size / 2, chk_y + 1, "✓")
            else:
                c.setFillColor(_WHITE)
                c.setStrokeColor(_BLACK)
                c.setLineWidth(0.5)
                c.rect(chk_x, chk_y, chk_size, chk_size, fill=1, stroke=1)

            # Texto de clase (solo la primera línea — nombre)
            c.setFillColor(_RED if is_sel else _BLACK)
            c.setFont("Helvetica-Bold", 6)
            lbl_line = lbl.split("\n")[0]
            c.drawCentredString(cx + col_w / 2, y - check_h + 3, lbl_line)

            cx += col_w

        return y - check_h - 2

    # ── SECCIÓN 6: Observaciones ──────────────────────────────────────────────

    def _draw_observaciones(self, c, y: float, os_data: dict) -> float:
        y -= 8
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(self.ML, y, "≡  OBSERVACIONES")
        y -= 4
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 6

        obs = os_data.get("observaciones", "") or ""
        c.setFillColor(_BLACK)
        c.setFont("Helvetica", 8)

        # Dividir observaciones en líneas de texto
        words = obs.split()
        line = ""
        max_w = self.CW
        
        limit_y = self.MB + 140  # Límite inferior seguro arriba de la nota y firmas
        
        for word in words:
            if y <= limit_y: break
            test = (line + " " + word).strip()
            if c.stringWidth(test, "Helvetica", 8) < max_w:
                line = test
            else:
                c.drawString(self.ML, y, line)
                y -= 14
                line = word
                
        if line and y > limit_y:
            c.drawString(self.ML, y, line)
            y -= 14

        # Líneas vacías llenando el espacio
        while y > limit_y:
            c.setStrokeColor(_GRAY_MED)
            c.setLineWidth(0.4)
            c.line(self.ML, y, self.ML + self.CW, y)
            y -= 16

        return y

    # ── SECCIÓN 7: Pie de Página ──────────────────────────────────────────────

    def _draw_footer(self, c, os_data: dict, tecnico_nombre: Optional[str]) -> None:
        """Nota legal + firmas + barra de contacto."""
        footer_start = self.MB + 56

        # ── Nota legal con icono de alerta ────────────────────────────────────
        nota_y = footer_start + 50
        
        # Cuadro de campana/alerta
        icon_x = self.ML
        icon_y = nota_y - 8
        c.setFillColor(colors.HexColor("#FDEEEF"))
        c.setStrokeColor(_RED)
        c.setLineWidth(1)
        c.roundRect(icon_x, icon_y, 20, 20, radius=4, fill=1, stroke=1)
        
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 14)
        c.drawCentredString(icon_x + 10, icon_y + 5, "!")
        
        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(icon_x + 30, icon_y + 12, "NOTA:")
        
        nota_text = (
            "La firma indica la aceptación de los servicios realizados. Favor de revisar los datos de los equipos y los "
            "\"datos para certificado y dictamen de inspección\" para la emisión de los mismos, ya que así es como se "
            "elaborarán."
        )
        c.setFillColor(_BLACK)
        c.setFont("Helvetica", 7)
        max_w = self.CW - 60
        self._wrap_text(c, nota_text, icon_x + 60, icon_y + 12, max_w, 7, 10)

        # ── Firmas (2 Columnas) ───────────────────────────────────────────────
        firma_y   = footer_start + 10
        col_w     = self.CW * 0.40
        left_fx   = self.ML + (self.CW * 0.10) - (col_w / 2)
        right_fx  = self.ML + (self.CW * 0.90) - (col_w / 2)

        # Líneas de firma
        c.setStrokeColor(_GRAY_DARK)
        c.setLineWidth(0.5)
        c.line(left_fx, firma_y, left_fx + col_w, firma_y)
        c.line(right_fx, firma_y, right_fx + col_w, firma_y)

        c.setFillColor(_RED)
        c.setFont("Helvetica-Bold", 7)
        c.drawCentredString(left_fx + col_w / 2, firma_y - 10, "TÉCNICO RESPONSABLE")
        c.drawCentredString(right_fx + col_w / 2, firma_y - 10, "CLIENTE")

        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 7)
        tec = tecnico_nombre or os_data.get("tecnico", "") or ""
        c.drawCentredString(left_fx + col_w / 2, firma_y - 20, f"{tec} / NOMBRE Y FIRMA")
        
        firma_cliente = os_data.get("firma_cliente_nombre", "") or ""
        if firma_cliente:
            c.drawCentredString(right_fx + col_w / 2, firma_y - 20, f"{firma_cliente} / NOMBRE Y FIRMA")
        else:
            c.drawCentredString(right_fx + col_w / 2, firma_y - 20, "NOMBRE Y FIRMA")

        # ── Cintillo Inferior Corporativo ─────────────────────────────────────
        bar_h = 24
        c.setFillColor(_DARK_HDR)
        c.rect(0, 0, self.W, bar_h, fill=1, stroke=0)

        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        
        # Teléfono (Izquierda)
        c.drawString(self.ML, 8, "📞  438 154 8258")
        
        # Sitio web (Centro)
        c.drawCentredString(self.W / 2, 8, "🌐  www.basculaspesa.com.mx")
        
        # Ubicación (Derecha)
        c.drawRightString(self.W - self.MR, 8, "📍  Querétaro, México")

    # ── Utilidades ────────────────────────────────────────────────────────────

    @staticmethod
    def _fmt(value) -> str:
        """Formatea un valor numérico o retorna espacio vacío."""
        if value is None:
            return ""
        try:
            f = float(value)
            if f == 0:
                return "0"
            return f"{f:.4f}".rstrip("0").rstrip(".")
        except (TypeError, ValueError):
            return str(value)

    def _wrap_text(self, c, text: str, x: float, y: float, max_w: float,
                   font_size: float, line_h: float) -> float:
        """Dibuja texto envuelto en múltiples líneas. Retorna Y final."""
        words = text.split()
        line = ""
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


# ─── Instancia singleton ────────────────────────────────────────────────────────
pdf_generator = PdfGenerator()
