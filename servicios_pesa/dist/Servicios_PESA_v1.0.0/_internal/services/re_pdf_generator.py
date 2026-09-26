"""
Generador de PDF — Ficha Técnica Diagnóstica de Celdas de Carga (RE).
Estructura:
  1. Encabezado (logo, folio RE-XX-N, fecha, técnico)
  2. Datos del Cliente
  3. Datos del Equipo / Indicador (con líneas manuales si vacío)
  4. Celdas de Carga (tabla encabezado)
  5. Diagrama de Estructura (Camionera / Plataforma / Tolva)
  6. Lecturas Sin Carga — N columnas dinámicas (Ohms)
  7. Funcionalidad de Celdas e Indicador (checkboxes)
  8. Observaciones + Firmas
"""
import logging
import math
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib import colors
    from reportlab.pdfgen import canvas as rl_canvas
    _RL_OK = True
except ImportError:
    _RL_OK = False

_RED      = colors.HexColor("#CC1F1F")
_DARK_HDR = colors.HexColor("#1C1C1C")
_GRAY_HDR = colors.HexColor("#2D2D2D")
_GRAY_LT  = colors.HexColor("#F5F5F5")
_GRAY_MED = colors.HexColor("#CCCCCC")
_GRAY_DK  = colors.HexColor("#888888")
_BLACK    = colors.black
_WHITE    = colors.white

_OHMS_PARAMS = [
    ("A", "Excitacion  Exc+ / Exc-",   "Ohms"),
    ("B", "Resistencia  Sig+ / Sig-",   "Ohms"),
    ("C", "Resistencia  Exc+ / Sig+",   "Ohms"),
    ("D", "Resistencia  Exc+ / Sig-",   "Ohms"),
    ("E", "Resistencia  Exc- / Sig+",   "Ohms"),
    ("F", "Resistencia  Exc- / Sig-",   "Ohms"),
    ("G", "Resistencia  Sig- + Exc+",   "Ohms"),
    ("H", "Resistencia  Sig- + Exc-",   "Ohms"),
    ("I", "Resistencia  Exc-+ / Sig+",  "Ohms"),
    ("J", "Resistencia  Exc-+ / Sig-",  "Ohms"),
    ("K", "Señal de Salida (Milivoltaje)", "mV"),
]

_INDICADOR_ITEMS = [
    "Indicador de Peso",
    "Teclado / Botones",
    "Luminosidad / Display",
    "Convertidor Analogico",
    "Caja Sumadora",
    "Potenciometro 1",
    "Potenciometro 2",
    "Potenciometro 3",
    "Potenciometro 4",
]


class RePdfGenerator:
    ML = 20; MR = 20; MT = 15; MB = 15
    W  = 612; H  = 792

    @property
    def CW(self): return self.W - self.ML - self.MR

    def generate(self, rv_data, celdas=None, inspeccion=None, perifericos=None, output_path=None):
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado")
        if output_path is None:
            import tempfile
            folio = rv_data.get("folio_re") or rv_data.get("folio_os", "RE")
            output_path = str(Path(tempfile.gettempdir()) / f"{folio}.pdf")

        n_a = int(rv_data.get("celda_a_cantidad") or 4)
        mixtas = bool(rv_data.get("celdas_mixtas"))
        n_b = int(rv_data.get("celda_b_cantidad") or 0) if mixtas else 0
        n_celdas = max(1, n_a + n_b)

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        folio_txt = rv_data.get("folio_re") or rv_data.get("folio_os", "—")
        c.setTitle(f"RE — {folio_txt}"); c.setAuthor("Servicios PESA")
        def _render_all(canvas_obj):
            """Dibuja el documento completo en una sola página."""
            y = self.H
            y = self._draw_header(canvas_obj, y, rv_data)
            y = self._draw_section(canvas_obj, 1, "DATOS DEL CLIENTE", y)
            y = self._draw_cliente(canvas_obj, y, rv_data)
            y = self._draw_section(canvas_obj, 2, "DATOS DEL EQUIPO / INDICADOR", y)
            y = self._draw_equipo(canvas_obj, y, rv_data)
            y = self._draw_celdas_header(canvas_obj, y, rv_data)
            if rv_data.get("tipo_estructura"):
                y = self._draw_estructura_diagrama(canvas_obj, y, rv_data)
            lbl_celdas = f"LECTURAS SIN CARGA — {n_celdas} CELDA{'S' if n_celdas > 1 else ''}  (Ohms / mV)"
            y = self._draw_section(canvas_obj, 3, lbl_celdas, y)
            y = self._draw_ohms_table_re(canvas_obj, y, n_celdas, mixtas, n_a, n_b)
            y = self._draw_section(canvas_obj, 4, "FUNCIONALIDAD DE CELDAS E INDICADOR", y)
            y = self._draw_funcionalidad_re(canvas_obj, y, n_celdas)
            y = self._draw_section(canvas_obj, 5, "OBSERVACIONES Y FIRMAS", y)
            self._draw_firmas(canvas_obj, y, rv_data)

        # ── Página 1 — Original ────────────────────────────────────────────
        _render_all(c)
        c.showPage()

        # ── Página 2 — Copia calca idéntica ──────────────────────────────
        _render_all(c)

        c.save()
        logger.info("PDF RE (diagnostico) generado: %s", output_path)
        return output_path

    # ── Ruta de logos ─────────────────────────────────────────────────────────
    _IMG_DIR = Path(r"C:\Users\ivan1\OneDrive\Escritorio\Software Ivan\Ordenes De Servicio\Img")

    def _draw_header(self, c, y, rv):
        """Encabezado comprimido. Altura total ≈ 60 pt."""
        top = y - self.MT

        right_w = 110; right_x = self.ML + self.CW - right_w

        # Rice Lake logo — 20pt
        logo_rl = str(self._IMG_DIR / "RiceLake.png")
        rl_h = 20
        try:
            c.drawImage(logo_rl, right_x, top - rl_h,
                        width=right_w, height=rl_h,
                        preserveAspectRatio=True, mask="auto")
        except Exception:
            c.setFont("Helvetica-Bold", 9); c.setFillColor(_BLACK)
            c.drawString(right_x + 4, top - 12, "RICE LAKE")

        # Folio box — 30pt, 4pt bajo RL
        ctrl_h = 30; ctrl_y = top - rl_h - 4 - ctrl_h
        c.setStrokeColor(_RED); c.setLineWidth(1.5)
        c.rect(right_x, ctrl_y, right_w, ctrl_h, fill=0, stroke=1)
        c.setFillColor(_RED)
        c.rect(right_x, ctrl_y + ctrl_h - 12, right_w, 12, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 6.5)
        c.drawCentredString(right_x + right_w / 2, ctrl_y + ctrl_h - 9, "FOLIO / RE")
        folio_txt = rv.get("folio_re") or rv.get("folio_os", "—")
        c.setFillColor(_RED); c.setFont("Helvetica-Bold", 12)
        c.drawCentredString(right_x + right_w / 2, ctrl_y + 6, folio_txt)

        # Logo PESA — izquierda, 26pt
        logo_pesa = str(self._IMG_DIR / "logo_pesa.png")
        pesa_w = 90; pesa_h = 26
        try:
            c.drawImage(logo_pesa, self.ML, top - pesa_h,
                        width=pesa_w, height=pesa_h,
                        preserveAspectRatio=True, mask="auto")
        except Exception:
            c.setFillColor(_RED); c.rect(self.ML, top - 28, 30, 28, fill=1, stroke=0)
            c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 12)
            c.drawCentredString(self.ML + 15, top - 18, "BP")
            c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 9)
            c.drawString(self.ML + 36, top - 11, "BASCULAS PESA")

        # Título central
        center_x = self.ML + pesa_w + (right_x - self.ML - pesa_w) / 2
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 12)
        c.drawCentredString(center_x, top - 12, "FICHA TECNICA DIAGNOSTICA")
        c.setFont("Helvetica-Bold", 7.5); c.setFillColor(_GRAY_DK)
        c.drawCentredString(center_x, top - 26, "REVISION DE CELDAS DE CARGA Y BASCULA")
        c.setFont("Helvetica", 6.5)
        c.drawCentredString(center_x, top - 36, "PESAJE SISTEMAS Y AUTOMATIZACION")

        # Línea divisoria removida según solicitud
        sep_y = top - 52
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, sep_y - 10, "FECHA: _______________________________")
        return sep_y - 14

    def _draw_section(self, c, num, title, y, gap=2):
        y -= gap; bar_h = 16
        c.setFillColor(_DARK_HDR); c.rect(self.ML, y - bar_h, self.CW, bar_h, fill=1, stroke=0)
        cx = self.ML + 11
        c.setFillColor(_RED); c.circle(cx, y - bar_h / 2, 6, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(cx, y - bar_h / 2 - 2.5, str(num))
        c.setFont("Helvetica-Bold", 8.5)
        c.drawString(self.ML + 21, y - bar_h + 5, title.upper())
        return y - bar_h - 2

    def _check_page(self, c, y, need):
        if y - need < self.MB + 40:
            self._draw_page_footer(c); c.showPage()
            return self.H - self.MT - 10
        return y

    def _draw_page_footer(self, c):
        """Pie de página — vacío (sin leyenda)."""
        pass

    def _draw_cliente(self, c, y, rv):
        """Sección 1: Datos del cliente."""
        y -= 1
        for label, key, w in [
            ("RAZON SOCIAL / CLIENTE", "cliente",   self.CW * 0.65),
            ("DIRECCION COMPLETA",     None,         self.CW),
        ]:
            if key:
                val = str(rv.get(key, "") or "").strip()
            else:
                # Patrón unificado de 5 claves — mismo orden que OS, RMA, LP, LV
                val = (
                    rv.get("direccion") or
                    rv.get("sucursal_direccion") or
                    rv.get("direccion_planta") or
                    rv.get("cliente_direccion") or
                    rv.get("sucursal") or
                    ""
                ).strip()
            c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 6)
            c.drawString(self.ML + 2, y - 4, label + ":")
            if val:
                c.setFillColor(_BLACK); c.setFont("Helvetica", 7.5)
                c.drawString(self.ML + 2, y - 14, val[:int(w / 4.8)])
            c.setStrokeColor(colors.HexColor("#CCCCCC")); c.setLineWidth(0.4)
            c.line(self.ML, y - 18, self.ML + w, y - 18)
            y -= 22
        return y - 2


    def _draw_equipo(self, c, y, rv):
        fh = 18; y -= 1

        def field_row(items):
            nonlocal y
            x = self.ML
            for lbl, key, w in items:
                raw = str(rv.get(key, "") or "").strip()
                c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 6)
                c.drawString(x + 1, y - 4, lbl + ":")
                if raw:
                    c.setFillColor(_BLACK); c.setFont("Helvetica", 7)
                    c.drawString(x + 1, y - 13, raw[:int(w / 4.8)])
                c.setStrokeColor(colors.HexColor("#CCCCCC")); c.setLineWidth(0.4)
                c.line(x, y - 16, x + w, y - 16)
                x += w + 4
            y -= fh

        cw = self.CW
        field_row([
            ("MARCA INDICADOR",   "indicador_marca",  cw * 0.22),
            ("MODELO INDICADOR",  "indicador_modelo", cw * 0.26),
            ("No. DE SERIE",      "indicador_serie",  cw * 0.22),
            ("ID INDICADOR",      "indicador_id",     cw * 0.22),
        ])
        field_row([
            ("CAPACIDAD MAX.",    "cap_maxima",  cw * 0.25),
            ("DIVISION MIN. (d)", "div_minima",  cw * 0.25),
        ])
        return y - 2


    def _draw_celdas_header(self, c, y, rv):
        BLANK = "—"; row_h = 12; cw = self.CW
        mixtas = bool(rv.get("celdas_mixtas"))
        col_w = [cw * 0.10, cw * 0.26, cw * 0.30, cw * 0.20, cw * 0.14]
        hdrs  = ["TIPO", "MARCA", "MODELO", "CAPACIDAD INDIV.", "CANTIDAD"]
        y -= 2
        tipo_txt = "ARREGLO MIXTO (A + B)" if mixtas else "HOMOGENEO"
        c.setFillColor(_GRAY_HDR); c.rect(self.ML, y - 14, cw, 14, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawString(self.ML + 4, y - 14 + 4, "CELDAS DE CARGA")
        c.drawRightString(self.ML + cw - 4, y - 14 + 4, tipo_txt)
        y -= 14
        c.setFillColor(_DARK_HDR); c.rect(self.ML, y - 12, cw, 12, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 6.5)
        cx = self.ML
        for hdr, cw_col in zip(hdrs, col_w):
            c.drawCentredString(cx + cw_col / 2, y - 12 + 3.5, hdr); cx += cw_col
        y -= 12

        def draw_row(lbl, marca, modelo, cap, cant, fill):
            nonlocal y
            c.setFillColor(fill); c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=0)
            vals = [lbl, str(marca or BLANK)[:20], str(modelo or BLANK)[:24],
                    str(cap or BLANK)[:18], str(cant) if cant else BLANK]
            c.setFont("Helvetica", 7); cx2 = self.ML
            for i, (val, cw_col) in enumerate(zip(vals, col_w)):
                # Línea sólida gris fina (sin guiones punteados)
                c.setFillColor(_BLACK)
                if i > 0 and val == BLANK:
                    mid_y = y - row_h + 6
                    c.setStrokeColor(colors.HexColor("#CCCCCC")); c.setLineWidth(0.4)
                    c.line(cx2 + cw_col * 0.05, mid_y, cx2 + cw_col * 0.95, mid_y)
                else:
                    c.drawCentredString(cx2 + cw_col / 2, y - row_h + 3.5, val)
                cx2 += cw_col
            c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.2)
            c.rect(self.ML, y - row_h, cw, row_h, fill=0, stroke=1)
            y -= row_h

        if not mixtas:
            draw_row("Unico", rv.get("celda_a_marca"), rv.get("celda_a_modelo"),
                     rv.get("celda_a_capacidad"), rv.get("celda_a_cantidad"), _WHITE)
        else:
            draw_row("Tipo A", rv.get("celda_a_marca"), rv.get("celda_a_modelo"),
                     rv.get("celda_a_capacidad"), rv.get("celda_a_cantidad"), _GRAY_LT)
            draw_row("Tipo B", rv.get("celda_b_marca"), rv.get("celda_b_modelo"),
                     rv.get("celda_b_capacidad"), rv.get("celda_b_cantidad"), _WHITE)
        return y - 2


    def _draw_ohms_table_re(self, c, y, n, mixtas, n_a, n_b):
        cw = self.CW; lbl_w = 114; unit_w = 26
        avail_w = cw - lbl_w - unit_w
        cell_w = max(26, avail_w / n)
        row_h = 10.5; hdr_h = 14
        y -= 1

        # Encabezado de columnas
        c.setFillColor(_DARK_HDR); c.rect(self.ML, y - hdr_h, cw, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawString(self.ML + 4, y - hdr_h + 4.5, "PARAMETRO ELECTRICO")
        c.drawString(self.ML + lbl_w + 4, y - hdr_h + 4.5, "UND")
        for i in range(n):
            cx_cell = self.ML + lbl_w + unit_w + i * cell_w
            if mixtas:
                bg = colors.HexColor("#1E3A5F") if i < n_a else colors.HexColor("#5F3A00")
                suffix = " (A)" if i < n_a else " (B)"
            else:
                bg = _DARK_HDR; suffix = ""
            c.setFillColor(bg); c.rect(cx_cell, y - hdr_h, cell_w, hdr_h, fill=1, stroke=0)
            c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
            c.drawCentredString(cx_cell + cell_w / 2, y - hdr_h + 4.5, f"C-{i+1}{suffix}")
        y -= hdr_h

        # Filas de parámetros
        for row_idx, (key, param_lbl, unit) in enumerate(_OHMS_PARAMS):
            bg = _GRAY_LT if row_idx % 2 == 0 else _WHITE
            c.setFillColor(bg); c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=0)
            c.setFillColor(_BLACK); c.setFont("Helvetica", 6.5)
            c.drawString(self.ML + 2, y - row_h + 3.5, param_lbl)
            c.setFont("Helvetica-Bold", 6.5); c.setFillColor(_GRAY_DK)
            c.drawCentredString(self.ML + lbl_w + unit_w / 2, y - row_h + 3.5, unit)
            for i in range(n):
                cx_cell = self.ML + lbl_w + unit_w + i * cell_w
                mid_y = y - row_h + 5.5
                # Línea sólida fina y limpia, sin guiones
                c.setStrokeColor(colors.HexColor("#DDDDDD")); c.setLineWidth(0.5)
                c.line(cx_cell + 2, mid_y, cx_cell + cell_w - 2, mid_y)
            c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.2)
            c.rect(self.ML, y - row_h, cw, row_h, fill=0, stroke=1)
            for i in range(n + 1):
                sep_x = self.ML + lbl_w + unit_w + i * cell_w
                c.line(sep_x, y - row_h, sep_x, y)
            c.line(self.ML + lbl_w, y - row_h, self.ML + lbl_w, y)
            y -= row_h
        return y - 3

    def _draw_funcionalidad_re(self, c, y, n):
        cw = self.CW; col_ind_w = cw * 0.46; col_cel_w = cw * 0.50; hdr_h = 16; row_h = 12
        y -= 1
        c.setFillColor(_GRAY_HDR); c.rect(self.ML, y - hdr_h, col_ind_w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawString(self.ML + 4, y - hdr_h + 5, "INDICADOR / DISPLAY")
        cel_x = self.ML + cw - col_cel_w
        c.setFillColor(_GRAY_HDR); c.rect(cel_x, y - hdr_h, col_cel_w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawString(cel_x + 4, y - hdr_h + 5, "ESTADO INDIVIDUAL DE CELDAS")
        y -= hdr_h
        max_rows = max(len(_INDICADOR_ITEMS), n)

        def chk(cx, cy, size=6):
            c.setStrokeColor(_BLACK); c.setLineWidth(0.6); c.rect(cx, cy, size, size, fill=0, stroke=1)

        for i in range(max_rows):
            bg = colors.HexColor("#F8F9FA") if i % 2 == 0 else _WHITE
            c.setFillColor(bg)
            
            # Left block (Indicador)
            if i < len(_INDICADOR_ITEMS):
                c.rect(self.ML, y - row_h, col_ind_w, row_h, fill=1, stroke=0)
                chk(self.ML + 3, y - row_h + 3)
                c.setFillColor(_BLACK); c.setFont("Helvetica", 6.5)
                c.drawString(self.ML + 12, y - row_h + 4, _INDICADOR_ITEMS[i])
                c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.2)
                c.rect(self.ML, y - row_h, col_ind_w, row_h, fill=0, stroke=1)
            
            # Right block (Celdas)
            if i < n:
                c.setFillColor(bg)
                c.rect(cel_x, y - row_h, col_cel_w, row_h, fill=1, stroke=0)
                c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 6.5)
                c.drawString(cel_x + 3, y - row_h + 4, f"Celda {i+1}:")
                chk(cel_x + 46, y - row_h + 3)
                c.setFont("Helvetica", 6.5); c.drawString(cel_x + 55, y - row_h + 4, "OK")
                chk(cel_x + 75, y - row_h + 3); c.drawString(cel_x + 84, y - row_h + 4, "Falla")
                c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.2)
                c.rect(cel_x, y - row_h, col_cel_w, row_h, fill=0, stroke=1)

            y -= row_h
            
        c.setFillColor(colors.HexColor("#F8F9FA")); c.rect(self.ML, y - row_h, cw, row_h, fill=1, stroke=0)
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 6.5)
        c.drawString(self.ML + 4, y - row_h + 4, "Cables:")
        chk(self.ML + 44, y - row_h + 3)
        c.setFont("Helvetica", 6.5); c.drawString(self.ML + 53, y - row_h + 4, "OK")
        chk(self.ML + 70, y - row_h + 3); c.drawString(self.ML + 79, y - row_h + 4, "Falla")
        
        c.setFont("Helvetica-Bold", 6.5); c.drawString(self.ML + 110, y - row_h + 4, "Conectores:")
        chk(self.ML + 162, y - row_h + 3); c.setFont("Helvetica", 6.5)
        c.drawString(self.ML + 171, y - row_h + 4, "OK")
        chk(self.ML + 188, y - row_h + 3); c.drawString(self.ML + 197, y - row_h + 4, "Falla")
        
        c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.2)
        c.rect(self.ML, y - row_h, cw, row_h, fill=0, stroke=1)
        return y - row_h - 4


    def _draw_firmas(self, c, y, rv):
        cw = self.CW; obs_h = 25
        c.setFillColor(_GRAY_LT); c.rect(self.ML, y - obs_h, cw, obs_h, fill=1, stroke=0)
        c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.3)
        c.rect(self.ML, y - obs_h, cw, obs_h, fill=0, stroke=1)
        c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 6)
        c.drawString(self.ML + 4, y - 8, "OBSERVACIONES:")
        obs_txt = rv.get("observaciones", "") or rv.get("observaciones_tecnico", "") or ""
        c.setFont("Helvetica", 6.5); c.setFillColor(_BLACK)
        for ln_idx, line in enumerate(obs_txt.splitlines()[:1]):
            c.drawString(self.ML + 6, y - 18, line[:120])
        y -= obs_h + 35
        col_w = cw * 0.42
        
        tecnico_raw = rv.get("tecnico_nombre") or rv.get("tecnico", "")
        valores_omitir = ["sin asignar", "none", "null", "— selecciona técnico —", "selecciona técnico", ""]
        if str(tecnico_raw).strip().lower() in valores_omitir:
            tecnico_texto = ""
        else:
            tecnico_texto = str(tecnico_raw).strip()

        for lbl, name, x_pos in [
            ("TECNICO RESPONSABLE", tecnico_texto, self.ML),
            ("FIRMA CLIENTE", "", self.ML + cw - col_w),
        ]:
            c.setStrokeColor(_GRAY_DK); c.setLineWidth(0.5)
            c.line(x_pos, y, x_pos + col_w, y)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 7)
            c.drawCentredString(x_pos + col_w / 2, y - 9, lbl)
            if name:
                c.setFillColor(_BLACK); c.setFont("Helvetica", 6.5)
                c.drawCentredString(x_pos + col_w / 2, y - 17, str(name))
        return y - 20


    def _draw_estructura_diagrama(self, c, y, rv):
        tipo = (rv.get("tipo_estructura") or "").upper()
        instalacion = (rv.get("tipo_instalacion_camionera") or "RAMPA").upper()
        secciones = int(rv.get("secciones_camionera") or 2)
        tipo_labels = {"CAMIONERA": "CAMIONERA", "PLATAFORMA": "PLATAFORMA", "TOLVA_TANQUE": "TOLVA / TANQUE"}
        tipo_label = tipo_labels.get(tipo, tipo)
        y -= 6
        c.setFillColor(_DARK_HDR); c.rect(self.ML, y - 12, self.CW, 12, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7)
        c.drawString(self.ML + 4, y - 9, f"DIAGRAMA DE ESTRUCTURA — {tipo_label}")
        y -= 12
        diag_h = 55; y -= 2
        c.setFillColor(_GRAY_LT); c.rect(self.ML, y - diag_h, self.CW, diag_h, fill=1, stroke=0)
        c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.5)
        c.rect(self.ML, y - diag_h, self.CW, diag_h, fill=0, stroke=1)
        cx_center = self.ML + self.CW / 2; cy_center = y - diag_h / 2
        if tipo == "CAMIONERA": self._draw_camionera(c, cx_center, cy_center, secciones, instalacion)
        elif tipo == "PLATAFORMA": self._draw_plataforma(c, cx_center, cy_center)
        elif tipo == "TOLVA_TANQUE": self._draw_tolva_tanque(c, cx_center, cy_center)
        else:
            c.setFillColor(_DARK_HDR); c.setFont("Helvetica", 8)
            c.drawCentredString(cx_center, cy_center, f"Estructura: {tipo_label}")
        return y - diag_h - 8

    def _draw_indicador_box(self, c, ix, iy, iw, ih, connect_to_x, connect_to_y, posicion):
        """Dibuja la caja INDICADOR en la posición indicada con línea al punto sumador.
        Si posición es MANUAL o el espacio es insuficiente, deja el área limpia."""
        if iw < 30 or posicion == "MANUAL":
            return  # espacio en blanco para el técnico
        # Caja sólida (borde azul)
        c.setStrokeColor(colors.HexColor("#2563EB")); c.setLineWidth(1)
        c.setFillColor(_WHITE)
        c.rect(ix, iy, iw, ih, fill=1, stroke=1)
        c.setFillColor(colors.HexColor("#2563EB")); c.setFont("Helvetica-Bold", 6)
        c.drawCentredString(ix + iw / 2, iy + ih / 2 + 2, "INDICADOR")
        c.setFillColor(_GRAY_DK); c.setFont("Helvetica", 5)
        c.drawCentredString(ix + iw / 2, iy + ih / 2 - 7, posicion.capitalize())
        # Línea de conexión al punto sumador
        c.setStrokeColor(colors.HexColor("#2563EB")); c.setLineWidth(0.8)
        c.line(ix, iy + ih / 2, connect_to_x, connect_to_y)

    def _draw_camionera(self, c, cx, cy, n, instalacion, ub_ind="MANUAL"):
        rect_w = min(self.CW * 0.55, 296); rect_h = 56
        rx = cx - rect_w / 2; ry = cy - rect_h / 2
        c.setFillColor(_WHITE); c.setStrokeColor(colors.HexColor("#333333")); c.setLineWidth(1.5)
        c.rect(rx, ry, rect_w, rect_h, fill=1, stroke=1)
        sec_w = rect_w / n
        c.setStrokeColor(colors.HexColor("#555555")); c.setLineWidth(0.8)
        for i in range(1, n): lx = rx + i * sec_w; c.line(lx, ry, lx, ry + rect_h)
        for i in range(n + 1):
            for py in [ry, ry + rect_h]:
                px = rx + i * sec_w
                c.setFillColor(_RED); c.circle(px, py, 5, fill=1, stroke=0)
                c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 5)
                c.drawCentredString(px, py - 2, "C")
        c.setFillColor(_DARK_HDR); c.setFont("Helvetica", 6.5)
        for i in range(n): c.drawCentredString(rx + (i + 0.5) * sec_w, cy - 3, f"Sec {i+1}")
        c.setFillColor(colors.HexColor("#0D47A1")); c.setFont("Helvetica-Bold", 7.5)
        # Esquina superior izquierda del recuadro gris
        c.drawString(self.ML + 6, cy + 16, f"Instalacion: {instalacion}")
        # ─ Caja de indicador (posición configurable) ─────────────────────────────
        ind_box_x = cx + rect_w / 2 + 10
        ind_box_w = self.ML + self.CW - ind_box_x - 4
        ind_box_y = cy - 28; ind_box_h = 56
        self._draw_indicador_box(c, ind_box_x, ind_box_y, ind_box_w, ind_box_h,
                                  rx + rect_w, cy, ub_ind)

    def _draw_plataforma(self, c, cx, cy, ub_ind="MANUAL"):
        side = 76; rx = cx - side / 2; ry = cy - side / 2
        c.setFillColor(_WHITE); c.setStrokeColor(colors.HexColor("#333333")); c.setLineWidth(1.5)
        c.rect(rx, ry, side, side, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR); c.setFont("Helvetica", 7); c.drawCentredString(cx, cy - 4, "PLATAFORMA")
        cs = 12
        for px, py in [(rx - cs/2, ry - cs/2), (rx + side - cs/2, ry - cs/2),
                       (rx - cs/2, ry + side - cs/2), (rx + side - cs/2, ry + side - cs/2)]:
            c.setFillColor(colors.HexColor("#FEE2E2")); c.setStrokeColor(_RED); c.setLineWidth(1)
            c.rect(px, py, cs, cs, fill=1, stroke=1)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 5); c.drawCentredString(px + cs/2, py + 4, "C")
        ind_box_x = cx + side/2 + 16; ind_box_w = self.ML + self.CW - ind_box_x - 4
        ind_box_y = cy - 28; ind_box_h = 56
        self._draw_indicador_box(c, ind_box_x, ind_box_y, ind_box_w, ind_box_h,
                                  rx + side, cy, ub_ind)

    def _draw_tolva_tanque(self, c, cx, cy, ub_ind="MANUAL"):
        r = 36
        c.setFillColor(_WHITE); c.setStrokeColor(colors.HexColor("#333333")); c.setLineWidth(1.5)
        c.circle(cx, cy, r, fill=1, stroke=1)
        c.setFillColor(_DARK_HDR); c.setFont("Helvetica", 7); c.drawCentredString(cx, cy - 4, "TOLVA / TANQUE")
        cs = 13
        for ang in [0, 90, 180, 270]:
            rad = math.radians(ang); mx = cx + (r + 10) * math.cos(rad); my = cy + (r + 10) * math.sin(rad)
            c.setFillColor(colors.HexColor("#FEE2E2")); c.setStrokeColor(_RED); c.setLineWidth(1)
            c.rect(mx - cs/2, my - cs/2, cs, cs, fill=1, stroke=1)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 5); c.drawCentredString(mx, my - 2, "C")
        ind_box_x = cx + r + 20; ind_box_w = self.ML + self.CW - ind_box_x - 4
        ind_box_y = cy - 28; ind_box_h = 56
        self._draw_indicador_box(c, ind_box_x, ind_box_y, ind_box_w, ind_box_h,
                                  cx + r, cy, ub_ind)

    # Compat stubs
    def _draw_inspeccion(self, c, y, insp_rows): return y
    def _draw_ohms_table(self, c, y, celdas): return y
    def _draw_funcionalidad(self, c, y, celdas, perifericos, rv): return y
    def _draw_observaciones_firmas(self, c, y, rv): return self._draw_firmas(c, y, rv)


re_pdf_generator = RePdfGenerator()
