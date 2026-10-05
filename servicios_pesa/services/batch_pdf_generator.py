"""
Generador de PDF por Lote — Impresión Calca (Original + Copia).
Para cada folio en el lote genera dos páginas idénticas marcadas
"ORIGINAL" y "COPIA" respectivamente, aptas para papel carbón/calca.

Soporta tipos: OS, RE, RMA.
"""
import logging
import os
from datetime import date, datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib import colors
    from reportlab.pdfgen import canvas as rl_canvas
    from reportlab.lib.colors import Color
    _RL_OK = True
except ImportError:
    _RL_OK = False

# ─── Colores ──────────────────────────────────────────────────────────────────
_RED      = colors.HexColor("#CC1F1F")
_DARK     = colors.HexColor("#1C1C1C")
_GRAY     = colors.HexColor("#CCCCCC")
_GRAY_DK  = colors.HexColor("#888888")
_BLACK    = colors.black
_WHITE    = colors.white

# Marcas de agua semitransparentes
_WM_ORIG = Color(0.1, 0.6, 0.1, alpha=0.08)    # verde muy tenue
_WM_COPY = Color(0.0, 0.3, 0.8, alpha=0.08)    # azul muy tenue


class BatchPdfGenerator:
    """
    Genera un único PDF multi-página para impresión por lote en papel calca.
    Estructura: (Original pág 1)(Copia pág 1)(Original pág 2)(Copia pág 2)...
    """

    W = 612; H = 792
    ML = 36; MR = 36; MT = 36; MB = 36

    @property
    def CW(self): return self.W - self.ML - self.MR

    # ── API Pública ───────────────────────────────────────────────────────────

    def generate_lote(
        self,
        tipo:          str,           # 'OS' | 'RE' | 'RMA'
        folios:        list[str],     # ['OS-26-10', 'OS-26-11', ...]
        cliente_nombre: str,
        cliente_direccion: str,
        tecnico_nombre: str,
        fecha:         date,
        output_path:   Optional[str] = None,
    ) -> str:
        """
        Genera el PDF por lote.

        Args:
            tipo:           Tipo de documento (OS, RE, RMA).
            folios:         Lista de folios consecutivos ya reservados.
            cliente_nombre: Nombre del cliente a imprimir en el encabezado.
            cliente_direccion: Dirección del cliente.
            tecnico_nombre: Nombre del técnico responsable.
            fecha:          Fecha a imprimir en los formatos.
            output_path:    Ruta de salida. Si None → temp dir.

        Returns:
            Ruta absoluta del PDF generado.
        """
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado: pip install reportlab")
            
        valores_omitir = ["sin asignar", "none", "null", "— selecciona técnico —", "selecciona técnico", ""]
        if str(tecnico_nombre).strip().lower() in valores_omitir:
            tecnico_nombre = ""
        else:
            tecnico_nombre = str(tecnico_nombre).strip()

        if output_path is None:
            import tempfile
            fn = f"LOTE_{tipo}_{folios[0]}_al_{folios[-1]}.pdf"
            output_path = str(Path(tempfile.gettempdir()) / fn)

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Lote {tipo} — {folios[0]} al {folios[-1]}")
        c.setAuthor("Servicios PESA")

        draw_fn = {
            "OS":  self._draw_os_page,
            "RE":  self._draw_re_page,
            "RMA": self._draw_rma_page,
        }.get(tipo.upper(), self._draw_os_page)

        total = len(folios)
        for idx, folio in enumerate(folios, start=1):
            # ── Página ORIGINAL (Calca 1) ─────────────────────────────────────
            draw_fn(c, folio, cliente_nombre, cliente_direccion, tecnico_nombre, fecha)
            self._draw_page_counter(c, idx, total, "")
            self._draw_footer(c)
            c.showPage()

            # ── Página COPIA (Calca 2) ────────────────────────────────────────
            draw_fn(c, folio, cliente_nombre, cliente_direccion, tecnico_nombre, fecha)
            self._draw_page_counter(c, idx, total, "")
            self._draw_footer(c)
            c.showPage()

        c.save()
        logger.info(f"PDF lote generado ({total} folios × 2 páginas): {output_path}")
        return output_path

    # ── Marca de agua / Sello ─────────────────────────────────────────────────


    def _draw_page_counter(self, c, idx: int, total: int, copy_type: str) -> None:
        """Paginación en esquina inferior derecha."""
        c.setFillColor(_GRAY_DK)
        c.setFont("Helvetica", 7)
        texto = f"Formato {idx} de {total}"
        if copy_type:
            texto += f" — {copy_type}"
        c.drawRightString(self.ML + self.CW, self.MB - 12, texto)

    def _draw_footer(self, c) -> None:
        bar_h = 22
        c.setFillColor(_DARK)
        c.rect(0, 0, self.W, bar_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, 7, "📞  438 154 8258")
        c.drawCentredString(self.W / 2, 7, "🌐  www.basculaspesa.com.mx")
        c.drawRightString(self.ML + self.CW, 7, "📍  Querétaro, México")

    # ── Plantilla OS ──────────────────────────────────────────────────────────

    def _draw_os_page(
        self, c, folio: str, cliente: str, direccion: str,
        tecnico: str, fecha: date
    ) -> None:
        top = self.H - self.MT

        # ── Header logos ─────────────────────────────────────────────────────
        c.setFillColor(_RED)
        c.rect(self.ML, top - 34, 40, 34, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(self.ML + 20, top - 22, "BP")
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 13)
        c.drawString(self.ML + 46, top - 12, "BÁSCULAS PESA")
        c.setFont("Helvetica", 7)
        c.drawString(self.ML + 46, top - 22, "UNA EMPRESA QUE PESA ®")

        # Rice Lake derecha
        rl_x = self.ML + self.CW - 140
        c.setFont("Helvetica", 7); c.setFillColor(_GRAY_DK)
        c.drawString(rl_x, top - 8, "Authorized Distributor")
        c.setFont("Helvetica-Bold", 14); c.setFillColor(_BLACK)
        c.drawString(rl_x, top - 20, "RICE LAKE")
        c.setFont("Helvetica-BoldOblique", 7); c.setFillColor(_RED)
        c.drawString(rl_x, top - 28, "WEIGHING SYSTEMS")

        c.setStrokeColor(_GRAY); c.setLineWidth(0.5)
        c.line(self.ML, top - 42, self.ML + self.CW, top - 42)

        # ── Título + Folio (Área central limpia) ─────────────────────────────
        ty = top - 46

        # Caja folio
        fx = self.ML + self.CW - 148
        c.setStrokeColor(_RED); c.setLineWidth(1.5)
        c.rect(fx, ty - 50, 148, 48, fill=0, stroke=1)
        c.setFillColor(_RED)
        c.rect(fx, ty - 18, 148, 16, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(fx + 74, ty - 13, "FOLIO / OS")
        c.setFillColor(_RED); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(fx + 74, ty - 40, folio)

        y = ty - 58

        # ── Fecha / Cliente / Técnico ─────────────────────────────────────────
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, f"FECHA:  {fecha.strftime('%d / %m / %Y')}")
        y -= 14

        for lbl, val in [("CLIENTE", cliente), ("TÉCNICO", tecnico)]:
            c.setFillColor(_DARK)
            c.rect(self.ML, y - 18, self.CW, 18, fill=1, stroke=0)
            c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 4, y - 12, lbl + ":")
            c.setFont("Helvetica", 8)
            c.drawString(self.ML + 60, y - 12, str(val or "")[:80])
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.rect(self.ML, y - 18, self.CW, 18, fill=0, stroke=1)
            y -= 18

        y -= 6

        # ── Sección Datos del Equipo ──────────────────────────────────────────
        y = self._draw_section_hdr(c, y, "DATOS DEL EQUIPO")

        fields_row1 = [("MARCA", 120), ("MODELO", 130), ("N/S", 130), ("UBICACIÓN", 140)]
        fields_row2 = [("ALCANCE MÁX.", 110), ("DIV. MÍNIMA", 110),
                       ("DIV. VERIFICACIÓN", 120), ("ID EQUIPO", 140)]
        fields_row3 = [("TIPO DE INSTRUMENTO", 200), ("NÚMERO CCA", 150),
                       ("HOLOGRAMA ANTERIOR", 160)]

        for row_fields in [fields_row1, fields_row2, fields_row3]:
            y = self._draw_blank_fields_row(c, y, row_fields)

        y -= 4

        # ── Tablas metrológicas ───────────────────────────────────────────────
        y = self._draw_section_hdr(c, y, "PRUEBAS METROLÓGICAS")
        left_x  = self.ML
        left_w  = self.CW * 0.44
        right_x = self.ML + left_w + 8
        right_w = self.CW - left_w - 8

        y_l = self._draw_blank_metrol_table(c, left_x, y, left_w, "REPETIBILIDAD",     3)
        y_l = self._draw_blank_metrol_table(c, left_x, y_l - 4, left_w, "EXCENTRICIDAD", 6)
        y_r = self._draw_blank_metrol_table(c, right_x, y, right_w, "EXACTITUD (10 puntos)", 10,
                                            cols=["N", "VALOR NOMINAL", "LECTURA INICIAL", "LECTURA FINAL"])
        y = min(y_l, y_r) - 4

        # ── Observaciones ─────────────────────────────────────────────────────
        y = self._draw_section_hdr(c, y, "OBSERVACIONES")
        for _ in range(3):
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.line(self.ML, y - 2, self.ML + self.CW, y - 2)
            y -= 14

    # ── Plantilla RE ──────────────────────────────────────────────────────────

    def _draw_re_page(
        self, c, folio: str, cliente: str, direccion: str,
        tecnico: str, fecha: date
    ) -> None:
        top = self.H - self.MT

        # Header compacto
        c.setFillColor(_RED)
        c.rect(self.ML, top - 34, 40, 34, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(self.ML + 20, top - 22, "BP")
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 12)
        c.drawString(self.ML + 46, top - 12, "BÁSCULAS PESA")

        # Caja folio RE (verde)
        fx = self.ML + self.CW - 148
        c.setStrokeColor(colors.HexColor("#2EA043")); c.setLineWidth(1.5)
        c.rect(fx, top - 50, 148, 48, fill=0, stroke=1)
        c.setFillColor(colors.HexColor("#2EA043"))
        c.rect(fx, top - 18, 148, 16, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(fx + 74, top - 13, "FOLIO / RE")
        c.setFillColor(colors.HexColor("#2EA043")); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(fx + 74, top - 40, folio)

        c.setStrokeColor(_GRAY); c.setLineWidth(0.5)
        c.line(self.ML, top - 42, self.ML + self.CW, top - 42)

        ty = top - 48
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 20)
        c.drawString(self.ML, ty - 20, "REPORTE DE REVISIÓN DE BÁSCULAS")
        c.setFont("Helvetica", 9); c.setFillColor(_GRAY_DK)
        c.drawString(self.ML, ty - 30, "PESAJE SISTEMAS Y AUTOMATIZACIÓN")

        y = ty - 40
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, f"FECHA: {fecha.strftime('%d / %m / %Y')}     TÉCNICO: {tecnico:.35s}")
        y -= 10

        # Sección 1
        y = self._draw_section_hdr_numbered(c, 1, "DATOS DEL CLIENTE", y)
        for lbl, w in [("RAZÓN SOCIAL / CLIENTE", self.CW), ("DIRECCIÓN", self.CW),
                       ("TELÉFONO", self.CW * 0.4), ("CORREO", self.CW * 0.55)]:
            c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 6.5)
            c.drawString(self.ML + 1, y - 4, lbl + ":")
            if lbl == "RAZÓN SOCIAL / CLIENTE":
                c.setFillColor(_BLACK); c.setFont("Helvetica", 8)
                c.drawString(self.ML + 1, y - 13, cliente[:90])
            elif lbl == "DIRECCIÓN":
                c.setFillColor(_BLACK); c.setFont("Helvetica", 8)
                c.drawString(self.ML + 1, y - 13, direccion[:90])
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.line(self.ML, y - 16, self.ML + w, y - 16)
            y -= 18

        # Sección 2 compacta
        y = self._draw_section_hdr_numbered(c, 2, "DATOS DEL EQUIPO", y)
        for r in [
            [("MARCA", 120), ("MODELO", 130), ("N/S", 130), ("ALCANCE MÁX.", 120)],
            [("TIPO", 160), ("DIV. MÍNIMA", 100), ("DIV. VER.", 100), ("# CCA", 130)],
        ]:
            y = self._draw_blank_fields_row(c, y, r)

        # Sección 3 - Inspección resumida
        y = self._draw_section_hdr_numbered(c, 3, "INSPECCIÓN VISUAL Y FUNCIONAL", y)
        puntos = [
            "Estado físico general del equipo",
            "Estado de la plataforma / estructura",
            "Estado de celdas de carga",
            "Estado de cableado y conexiones",
            "Caja sumadora / Conectores",
            "Indicador de peso / Display",
            "Teclado / Botones",
            "Nivelación del equipo",
            "Limpieza general",
        ]
        rh = 13
        for i, p in enumerate(puntos):
            bg = colors.HexColor("#F5F5F5") if i % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.rect(self.ML, y - rh, self.CW, rh, fill=1, stroke=0)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 7)
            c.drawString(self.ML + 2, y - rh + 4, str(i + 1) + ".")
            c.setFillColor(_BLACK); c.setFont("Helvetica", 7)
            c.drawString(self.ML + 14, y - rh + 4, p)
            # Checkboxes
            for cx, lbl in [(self.ML + 300, "CUMPLE"), (self.ML + 360, "NO CUMPLE")]:
                c.setStrokeColor(_GRAY_DK); c.setFillColor(_WHITE); c.setLineWidth(0.5)
                c.rect(cx, y - rh + 3, 8, 8, fill=1, stroke=1)
                c.setFillColor(_GRAY_DK); c.setFont("Helvetica", 6)
                c.drawString(cx + 10, y - rh + 4, lbl)
            c.setStrokeColor(_GRAY); c.setLineWidth(0.2)
            c.rect(self.ML, y - rh, self.CW, rh, fill=0, stroke=1)
            y -= rh

        # Sección 4 — Ohms encabezado simplificado (sin datos)
        y = self._draw_section_hdr_numbered(c, 4, "LECTURAS SIN CARGA — OHMS", y - 4)
        ohm_rows = ["Exc⁺/Exc⁻", "Sig⁺/Sig⁻", "Sig⁺/Exc⁺", "Sig⁻/Exc⁻",
                    "Res. Entrada Ω", "Res. Salida Ω"]
        hdr_h = 13
        c.setFillColor(_DARK)
        c.rect(self.ML, y - hdr_h, self.CW, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7)
        c.drawString(self.ML + 4, y - hdr_h + 4, "MEDICIÓN")
        for i in range(4):
            c.drawCentredString(self.ML + 120 + i * 100, y - hdr_h + 4, f"Celda {i+1}")
        y -= hdr_h
        for j, rl in enumerate(ohm_rows):
            bg = colors.HexColor("#F5F5F5") if j % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.rect(self.ML, y - 13, self.CW, 13, fill=1, stroke=0)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 6.5)
            c.drawString(self.ML + 3, y - 13 + 4, rl)
            c.setStrokeColor(_GRAY); c.setLineWidth(0.2)
            c.rect(self.ML, y - 13, self.CW, 13, fill=0, stroke=1)
            y -= 13

        # Observaciones + firma
        y -= 6
        c.setStrokeColor(_BLACK); c.setLineWidth(0.5)
        fw = self.CW * 0.4
        c.line(self.ML, y, self.ML + fw, y)
        c.line(self.ML + self.CW - fw, y, self.ML + self.CW, y)
        c.setFont("Helvetica-Bold", 7); c.setFillColor(_BLACK)
        c.drawCentredString(self.ML + fw / 2, y + 2, "TÉCNICO — " + tecnico[:25])
        c.drawCentredString(self.ML + self.CW - fw / 2, y + 2, "CLIENTE")

    # ── Plantilla RMA ─────────────────────────────────────────────────────────

    def _draw_rma_page(
        self, c, folio: str, cliente: str, direccion: str,
        tecnico: str, fecha: date
    ) -> None:
        top = self.H - self.MT

        # Header
        c.setFillColor(_RED)
        c.rect(self.ML, top - 34, 40, 34, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(self.ML + 20, top - 22, "BP")
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 13)
        c.drawString(self.ML + 46, top - 12, "BÁSCULAS PESA")

        # Caja folio (dorado)
        fx = self.ML + self.CW - 148
        folio_clr = colors.HexColor("#D29922")
        c.setStrokeColor(folio_clr); c.setLineWidth(1.5)
        c.rect(fx, top - 50, 148, 48, fill=0, stroke=1)
        c.setFillColor(folio_clr)
        c.rect(fx, top - 18, 148, 16, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(fx + 74, top - 13, "FOLIO / RMA")
        c.setFillColor(folio_clr); c.setFont("Helvetica-Bold", 18)
        c.drawCentredString(fx + 74, top - 40, folio)

        c.setStrokeColor(_GRAY); c.setLineWidth(0.5)
        c.line(self.ML, top - 42, self.ML + self.CW, top - 42)

        ty = top - 48
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 24)
        c.drawString(self.ML, ty - 22, "REMISIÓN DE MATERIAL")
        c.setFont("Helvetica", 9); c.setFillColor(_GRAY_DK)
        c.drawString(self.ML, ty - 32, "PESAJE SISTEMAS Y AUTOMATIZACIÓN")

        y = ty - 42

        # Datos
        c.setFont("Helvetica-Bold", 8); c.setFillColor(_BLACK)
        c.drawString(self.ML, y, f"FECHA: {fecha.strftime('%d / %m / %Y')}     TÉCNICO: {tecnico:.35s}")
        y -= 14

        for lbl, val in [("CLIENTE", cliente), ("DIRECCIÓN", direccion)]:
            c.setFillColor(_DARK)
            c.rect(self.ML, y - 18, self.CW, 18, fill=1, stroke=0)
            c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 4, y - 12, lbl + ":")
            if val:
                c.setFont("Helvetica", 8)
                c.drawString(self.ML + 70, y - 12, str(val)[:80])
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.rect(self.ML, y - 18, self.CW, 18, fill=0, stroke=1)
            y -= 18

        y -= 6

        # Sección: Tabla de ítems
        y = self._draw_section_hdr(c, y, "ÍTEMS / MATERIALES REMISIONADOS")
        col_ws = [30, 240, 70, 70, 130]
        col_labels = ["#", "DESCRIPCIÓN / MATERIAL", "CANTIDAD", "UNIDAD", "N/S (Opcional)"]
        total_w = sum(col_ws)

        # Encabezado de tabla
        c.setFillColor(_RED)
        c.rect(self.ML, y - 16, total_w, 16, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7)
        x = self.ML
        for lbl, cw in zip(col_labels, col_ws):
            c.drawCentredString(x + cw / 2, y - 11, lbl)
            x += cw
        y -= 16

        # 15 filas en blanco
        for i in range(15):
            rh = 18
            bg = colors.HexColor("#F5F5F5") if i % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.rect(self.ML, y - rh, total_w, rh, fill=1, stroke=0)
            # Número de ítem
            c.setFillColor(_GRAY_DK); c.setFont("Helvetica", 8)
            c.drawCentredString(self.ML + col_ws[0] / 2, y - rh + 6, str(i + 1))
            # Líneas verticales
            x = self.ML
            for cw in col_ws:
                c.setStrokeColor(_GRAY); c.setLineWidth(0.2)
                c.rect(x, y - rh, cw, rh, fill=0, stroke=1)
                x += cw
            y -= rh

        # Observaciones
        y -= 8
        c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 7)
        c.drawString(self.ML, y, "OBSERVACIONES:")
        y -= 2
        for _ in range(3):
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.line(self.ML, y, self.ML + self.CW, y)
            y -= 16

        # Firmas
        y -= 10
        c.setStrokeColor(_BLACK); c.setLineWidth(0.5)
        fw = self.CW * 0.4
        c.line(self.ML, y, self.ML + fw, y)
        c.line(self.ML + self.CW - fw, y, self.ML + self.CW, y)
        c.setFont("Helvetica-Bold", 7); c.setFillColor(_BLACK)
        c.drawCentredString(self.ML + fw / 2, y + 2, "ENTREGÓ — TÉCNICO")
        c.drawCentredString(self.ML + self.CW - fw / 2, y + 2, "RECIBIÓ — CLIENTE")
        c.setFont("Helvetica", 7); c.setFillColor(_GRAY_DK)
        c.drawCentredString(self.ML + fw / 2, y - 10, tecnico[:30])
        c.drawCentredString(self.ML + self.CW - fw / 2, y - 10, "NOMBRE Y FIRMA")

    # ── Helpers de dibujo ─────────────────────────────────────────────────────

    def _draw_section_hdr(self, c, y: float, title: str, gap: int = 6) -> float:
        y -= gap
        c.setFillColor(_RED); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, f"⬛  {title}")
        y -= 3
        c.setStrokeColor(_RED); c.setLineWidth(0.8)
        c.line(self.ML, y, self.ML + self.CW, y)
        return y - 8

    def _draw_section_hdr_numbered(self, c, num: int, title: str, y: float, gap: int = 4) -> float:
        y -= gap
        hdr_h = 20
        c.setFillColor(_DARK)
        c.rect(self.ML, y - hdr_h, self.CW, hdr_h, fill=1, stroke=0)
        c.setFillColor(_RED)
        c.circle(self.ML + 12, y - hdr_h / 2, 7, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawCentredString(self.ML + 12, y - hdr_h / 2 - 2.5, str(num))
        c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML + 24, y - hdr_h + 7, title.upper())
        return y - hdr_h - 3

    def _draw_blank_fields_row(self, c, y: float, fields: list[tuple]) -> float:
        """Dibuja una fila de campos en blanco con líneas de relleno."""
        fh = 20; x = self.ML
        for label, w in fields:
            c.setFillColor(_GRAY_DK); c.setFont("Helvetica-Bold", 6.5)
            c.drawString(x + 1, y - 5, label + ":")
            c.setStrokeColor(_GRAY); c.setLineWidth(0.3)
            c.line(x, y - 16, x + w, y - 16)
            x += w + 4
        return y - fh

    def _draw_blank_metrol_table(
        self, c, x: float, y: float, w: float,
        title: str, n_rows: int,
        cols: list[str] = None
    ) -> float:
        """Tabla metrológica en blanco con N filas."""
        if cols is None:
            cols = ["POSICIÓN", "LECTURA INICIAL", "LECTURA FINAL"]
        col_w = w / len(cols)
        row_h = 13
        hdr_h = 14

        # Encabezado título
        c.setFillColor(_DARK)
        c.rect(x, y - hdr_h, w, hdr_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawString(x + 3, y - hdr_h + 4, title)
        y -= hdr_h

        # Encabezados columnas
        c.setFillColor(_RED)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 6.5)
        for i, col in enumerate(cols):
            c.drawCentredString(x + col_w * i + col_w / 2, y - row_h + 4, col)
        y -= row_h

        # Filas en blanco
        for i in range(n_rows):
            bg = colors.HexColor("#F5F5F5") if i % 2 == 0 else _WHITE
            c.setFillColor(bg)
            c.rect(x, y - row_h, w, row_h, fill=1, stroke=0)
            c.setFillColor(_BLACK); c.setFont("Helvetica", 7)
            c.drawCentredString(x + col_w / 2, y - row_h + 4, str(i + 1))
            c.setStrokeColor(_GRAY); c.setLineWidth(0.2)
            c.rect(x, y - row_h, w, row_h, fill=0, stroke=1)
            y -= row_h

        # Fila Error máximo
        c.setFillColor(_WHITE)
        c.rect(x, y - row_h, w, row_h, fill=1, stroke=1)
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 3, y - row_h + 4, "ERROR MÁXIMO ENCONTRADO:")
        y -= row_h

        return y


batch_pdf_generator = BatchPdfGenerator()
