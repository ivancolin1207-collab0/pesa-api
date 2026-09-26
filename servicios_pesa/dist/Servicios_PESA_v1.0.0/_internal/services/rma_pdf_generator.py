"""
Generador de PDF — Remision de Material (RMA).
Diseno fiel al formato oficial de Basculas PESA.
Usa ReportLab canvas para control pixel-perfect del layout.
"""

import logging
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
    logger.warning("ReportLab no instalado: pip install reportlab")

import sys as _sys
import os as _os

# ---------------------------------------------------------------------------
# Rutas de imágenes — compatible con código fuente Y PyInstaller (_MEIPASS)
# ---------------------------------------------------------------------------
_BASE_DIR = Path(__file__).resolve().parent.parent.parent
_IMG_DIR  = _BASE_DIR / "Img"

def _resolver_ruta_asset(nombre_archivo: str) -> Optional[Path]:
    """Resuelve ruta de asset compatible con código fuente y PyInstaller (_MEIPASS)."""
    candidatas = []
    if hasattr(_sys, '_MEIPASS'):
        meipass = Path(_sys._MEIPASS)
        candidatas += [meipass / 'Img' / nombre_archivo, meipass / nombre_archivo]
    candidatas += [
        _BASE_DIR / 'Img' / nombre_archivo,
        _BASE_DIR / 'servicios_pesa' / 'assets' / 'images' / nombre_archivo,
        Path(_os.getcwd()) / 'Img' / nombre_archivo,
    ]
    for c in candidatas:
        if c.exists():
            return c
    return None

def _resolve_logo(name_no_ext: str) -> Optional[Path]:
    for ext in (".png", ".jpg", ".jpeg"):
        result = _resolver_ruta_asset(f"{name_no_ext}{ext}")
        if result:
            return result
    return None


def _resolve_rice_lake() -> Optional[Path]:
    for name in ("RiceLake", "Rice Lake", "ricelake", "rice_lake"):
        for ext in (".png", ".jpg", ".jpeg"):
            result = _resolver_ruta_asset(f"{name}{ext}")
            if result:
                return result
    return None


_LOGO_PESA_PATH = _resolve_logo("logo_pesa")
_LOGO_RL_PATH   = _resolve_rice_lake()

# ---------------------------------------------------------------------------
# Paleta de colores
# ---------------------------------------------------------------------------
_RED        = colors.HexColor("#CC1F1F")
_DARK_HDR   = colors.HexColor("#1C1C1C")
_GRAY_LIGHT = colors.HexColor("#F5F5F5")
_GRAY_MED   = colors.HexColor("#CCCCCC")
_GRAY_DARK  = colors.HexColor("#888888")
_GRAY_GRID  = colors.HexColor("#DDDDDD")
_TBL_BORDER = colors.HexColor("#CCCCCC")
_BLACK      = colors.black
_WHITE      = colors.white


# ===========================================================================
class RmaPdfGenerator:
    ML = 36
    MR = 36
    MT = 15
    MB = 15
    W  = 612
    H  = 792

    @property
    def CW(self) -> float:
        return self.W - self.ML - self.MR

    def generate(
        self,
        rma_data:    dict,
        output_path: Optional[str] = None,
        calca:       bool = False,
        force:       bool = False,
    ) -> str:
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado. Ejecutar: pip install reportlab")

        if output_path is None:
            folio = rma_data.get("folio_rma", "RMA")
            output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
            try:
                output_dir.mkdir(parents=True, exist_ok=True)
            except (PermissionError, OSError):
                output_dir = Path.home() / "PesaServidorLocal" / "PDF_OS"
                output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")

        if not force and Path(output_path).exists():
            logger.info("PDF RMA ya existe, omitiendo: %s", output_path)
            return output_path

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Remision de Material - {rma_data.get('folio_rma', '')}")
        c.setAuthor("Servicios PESA")
        c.setSubject("Remision de Material RMA")

        self._draw_page(c, rma_data)
        c.showPage()

        if calca:
            self._draw_page(c, rma_data)
            c.showPage()

        c.save()
        logger.info("PDF RMA generado: %s (calca=%s)", output_path, calca)
        return output_path

    def _draw_page(self, c, rma_data: dict) -> None:
        y = self.H
        y = self._draw_header(c, y, rma_data)
        y = self._draw_info_bar(c, y, rma_data)
        y = self._draw_tabla_materiales(c, y, rma_data)
        y = self._draw_firmas(c, y, rma_data)
        self._draw_footer_bar(c)

    def _draw_header(self, c, y: float, rma_data: dict) -> float:
        """
        Encabezado rediseñado:
          Fila A: Logo PESA (izq) | espacio | Logo Rice Lake (der)    → altura 44pt
          Separador horizontal gris fino
          Fila B: Título centrado | Caja FOLIO anclada a la derecha    → altura 44pt
        """
        top = y - self.MT

        # ── FILA A: Logos ────────────────────────────────────────────────
        LOGO_H = 44

        if _LOGO_PESA_PATH:
            c.drawImage(str(_LOGO_PESA_PATH), self.ML, top - LOGO_H,
                        width=170, height=LOGO_H, preserveAspectRatio=True, mask="auto")
        else:
            c.setStrokeColor(_RED); c.setLineWidth(1)
            c.rect(self.ML, top - LOGO_H, 170, LOGO_H, fill=0, stroke=1)
            c.setFillColor(_RED); c.setFont("Helvetica", 6)
            c.drawCentredString(self.ML + 85, top - LOGO_H / 2, "[ logo_pesa ]")

        rl_w = 160
        rl_x = self.ML + self.CW - rl_w
        if _LOGO_RL_PATH:
            c.drawImage(str(_LOGO_RL_PATH), rl_x, top - LOGO_H,
                        width=rl_w, height=LOGO_H, preserveAspectRatio=True, mask="auto")
        else:
            c.setStrokeColor(_RED); c.setLineWidth(1)
            c.rect(rl_x, top - LOGO_H, rl_w, LOGO_H, fill=0, stroke=1)
            c.setFillColor(_RED); c.setFont("Helvetica", 6)
            c.drawCentredString(rl_x + rl_w / 2, top - LOGO_H / 2, "[ Rice Lake ]")

        logos_bottom = top - LOGO_H

        # Separador horizontal delgado
        sep_y = logos_bottom - 8
        c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.5)
        c.line(self.ML, sep_y, self.ML + self.CW, sep_y)

        # ── FILA B: Título + Caja Folio ───────────────────────────────────
        TITULO_H = 44
        titulo_top = sep_y - 6
        titulo_mid = titulo_top - TITULO_H / 2   # centro vertical de la zona de título

        # Caja FOLIO — anclada a la derecha, alineada verticalmente con el título
        folio_w = 140; folio_h = 40
        folio_x = self.ML + self.CW - folio_w
        folio_y = titulo_top - folio_h          # parte inferior de la caja

        c.setStrokeColor(_RED); c.setLineWidth(2)
        c.rect(folio_x, folio_y, folio_w, folio_h, fill=0, stroke=1)

        band_h = 15
        c.setFillColor(_RED)
        c.rect(folio_x, folio_y + folio_h - band_h, folio_w, band_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(folio_x + folio_w / 2, folio_y + folio_h - band_h + 4, "FOLIO / RMA")

        folio_raw  = rma_data.get("folio_rma", "-") or "-"
        folio_text = folio_raw.replace("[DEMO]", "").strip()
        font_size  = 15 if len(folio_text) <= 10 else 12
        c.setFillColor(_RED); c.setFont("Helvetica-Bold", font_size)
        body_center_y = folio_y + (folio_h - band_h) / 2 - font_size / 4
        c.drawCentredString(folio_x + folio_w / 2, body_center_y, folio_text)

        # Título centrado (solo en el ancho libre, sin invadir el folio)
        title_avail_w = self.CW - folio_w - 10
        c.setFillColor(_BLACK)
        c.setFont("Helvetica-Bold", 20)
        c.drawCentredString(self.ML + title_avail_w / 2, titulo_mid + 5, "REMISION DE MATERIAL")
        c.setFont("Helvetica-Bold", 7.5)
        c.setFillColor(_GRAY_DARK)
        c.drawCentredString(self.ML + title_avail_w / 2, titulo_mid - 10, "PESAJE SISTEMAS Y AUTOMATIZACION")

        return titulo_top - TITULO_H - 4

    def _draw_info_bar(self, c, y: float, rma_data: dict) -> float:
        y -= 6
        c.setFillColor(_BLACK); c.setFont("Helvetica-Bold", 8)
        c.drawString(self.ML, y, "FECHA:")
        c.setFont("Helvetica", 8)
        fecha_str = str(rma_data.get("fecha") or "").strip()
        c.drawString(self.ML + 38, y, fecha_str if fecha_str else "________________________")
        y -= 10

        row_h = 18
        for lbl, key in [("CLIENTE", "cliente"), ("DIRECCION", None)]:
            c.setFillColor(_WHITE)
            c.rect(self.ML, y - row_h, self.CW, row_h, fill=1, stroke=0)
            c.setFillColor(_RED); c.setFont("Helvetica-Bold", 8)
            c.drawString(self.ML + 4, y - row_h + 5, lbl + ":")
            if lbl == "DIRECCION":
                # Patrón unificado de 4 claves — mismo orden que OS y RE
                valor = (
                    rma_data.get("direccion") or
                    rma_data.get("sucursal_direccion") or
                    rma_data.get("cliente_direccion") or
                    rma_data.get("sucursal") or
                    ""
                ).strip()
            else:
                valor = str(rma_data.get(key, "") or "")
            c.setFillColor(_BLACK); c.setFont("Helvetica", 8)
            lbl_w = c.stringWidth(lbl + ":", "Helvetica-Bold", 8)
            c.drawString(self.ML + 4 + lbl_w + 8, y - row_h + 5, valor[:90])
            c.setStrokeColor(_GRAY_MED); c.setLineWidth(0.5)
            c.line(self.ML, y - row_h, self.ML + self.CW, y - row_h)
            y -= row_h

        y -= 12
        return y

    def _draw_tabla_materiales(self, c, y: float, rma_data: dict) -> float:
        # Platypus Table para soporte de word-wrap automatico en celdas de serie/desc
        from reportlab.platypus import Table, TableStyle, Paragraph
        from reportlab.lib.styles import ParagraphStyle
        from reportlab.lib.enums import TA_LEFT, TA_CENTER

        c.setFillColor(_RED); c.setFont("Helvetica-Bold", 9)
        c.drawString(self.ML, y, "ENTREGA DE REFACCIONES / MATERIALES")
        y -= 4
        c.setStrokeColor(_RED); c.setLineWidth(1)
        c.line(self.ML, y, self.ML + self.CW, y)
        y -= 6

        # ── Anchos ajustados: CANTIDAD / N°PARTE / DESCRIPCION / N°SERIE ─
        # Total = self.CW (≈540 pt en Letter con ML=MR=36)
        col_raw = [45, 80, 190, 225]
        scale   = self.CW / sum(col_raw)
        col_ws  = [w * scale for w in col_raw]

        # ── Estilos Paragraph ─────────────────────────────────────────────
        _st_hdr = ParagraphStyle(
            "rma_hdr", fontName="Helvetica-Bold", fontSize=7,
            textColor=_WHITE, alignment=TA_CENTER, leading=9,
        )
        _st_ctr = ParagraphStyle(
            "rma_ctr", fontName="Helvetica", fontSize=7.5,
            textColor=_BLACK, alignment=TA_CENTER, leading=9, wordWrap="CJK",
        )
        _st_lft = ParagraphStyle(
            "rma_lft", fontName="Helvetica", fontSize=7.5,
            textColor=_BLACK, alignment=TA_LEFT, leading=9, wordWrap="CJK",
        )

        def _p(text, style):
            safe = (str(text) if text is not None else "")
            safe = safe.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            return Paragraph(safe, style)

        # ── Cabecera ──────────────────────────────────────────────────────
        header_row = [
            _p("CANTIDAD",        _st_hdr),
            _p("NUMERO DE PARTE", _st_hdr),
            _p("DESCRIPCION",     _st_hdr),
            _p("NUMERO DE SERIE", _st_hdr),
        ]

        # ── Filas de datos ────────────────────────────────────────────────
        items = rma_data.get("items", []) or []

        reserved    = 70 + 28 + 15          # firmas + footer + margen
        available_h = y - self.MB - reserved
        min_rows    = 8
        min_row_h   = 18
        max_rows    = max(min_rows, int(available_h / min_row_h))
        n_rows      = min(max(len(items), min_rows), max_rows)

        data_rows = []
        for i in range(n_rows):
            item = items[i] if i < len(items) else {}

            # Formatear series: "2511037836,2511037884,..." → "2511037836, 2511037884, ..."
            series_raw = str(
                item.get("numero_serie") or item.get("series") or ""
            ).strip()
            series_fmt = ", ".join(
                s.strip() for s in series_raw.split(",") if s.strip()
            ) if series_raw else ""

            data_rows.append([
                _p(str(item.get("cantidad",    "") or ""), _st_ctr),
                _p(str(item.get("numero_parte","") or ""), _st_lft),
                _p(str(item.get("descripcion", "") or ""), _st_lft),
                _p(series_fmt,                             _st_lft),
            ])

        # ── Construir tabla platypus ──────────────────────────────────────
        all_rows = [header_row] + data_rows
        tbl = Table(all_rows, colWidths=col_ws, repeatRows=1)

        row_cmds = [
            # Header
            ("BACKGROUND",    (0, 0), (-1, 0), _DARK_HDR),
            ("TEXTCOLOR",     (0, 0), (-1, 0), _WHITE),
            ("ALIGN",         (0, 0), (-1, 0), "CENTER"),
            ("TOPPADDING",    (0, 0), (-1, 0), 4),
            ("BOTTOMPADDING", (0, 0), (-1, 0), 4),
            # Datos
            ("ALIGN",         (0, 1), (0, -1), "CENTER"),   # CANTIDAD centrada
            ("ALIGN",         (1, 1), (-1,-1), "LEFT"),
            ("LEFTPADDING",   (1, 1), (-1,-1), 4),
            ("RIGHTPADDING",  (0, 1), (-1,-1), 4),
            ("TOPPADDING",    (0, 1), (-1,-1), 3),
            ("BOTTOMPADDING", (0, 1), (-1,-1), 3),
            ("VALIGN",        (0, 0), (-1,-1), "MIDDLE"),
            # Bordes
            ("GRID",          (0, 0), (-1,-1), 0.3, _GRAY_GRID),
            ("BOX",           (0, 0), (-1,-1), 0.8, _TBL_BORDER),
            ("LINEBELOW",     (0, 0), (-1, 0), 1.0, _DARK_HDR),
        ]
        # Fondos alternos
        for i in range(1, n_rows + 1):
            bg = _GRAY_LIGHT if i % 2 == 0 else _WHITE
            row_cmds.append(("BACKGROUND", (0, i), (-1, i), bg))

        tbl.setStyle(TableStyle(row_cmds))

        # ── Posicionar en el canvas ───────────────────────────────────────
        _w, h_tbl = tbl.wrapOn(c, self.CW, available_h)
        tbl.drawOn(c, self.ML, y - h_tbl)
        y = y - h_tbl - 8
        return y

    def _draw_firmas(self, c, y: float, rma_data: dict) -> float:
        """
        Firmas ancladas a una posición fija sobre el cintillo del pie de página,
        independientemente de cuantas filas tenga la tabla.
        """
        # Anclar: footer_bar (22pt) + margen (15pt) + bloque firma (50pt) = 87pt desde MB
        firma_y = self.MB + 22 + 15 + 50

        col_w   = self.CW * 0.38
        gap     = (self.CW - 2 * col_w) / 3
        left_x  = self.ML + gap
        right_x = self.ML + gap + col_w + gap

        c.setStrokeColor(_GRAY_DARK); c.setLineWidth(0.8)
        c.line(left_x,  firma_y, left_x  + col_w, firma_y)
        c.line(right_x, firma_y, right_x + col_w, firma_y)

        c.setFillColor(_RED); c.setFont("Helvetica-Bold", 7.5)
        c.drawCentredString(left_x  + col_w / 2, firma_y - 11, "ENTREGADO POR")
        c.drawCentredString(right_x + col_w / 2, firma_y - 11, "RECIBIDO DE CONFORMIDAD")

        c.setFillColor(_BLACK); c.setFont("Helvetica", 7)
        
        tecnico_raw = rma_data.get("tecnico_nombre") or rma_data.get("tecnico") or ""
        valores_omitir = ["sin asignar", "none", "null", "— selecciona técnico —", "selecciona técnico", ""]
        if str(tecnico_raw).strip().lower() in valores_omitir:
            tecnico_texto = ""
        else:
            tecnico_texto = str(tecnico_raw).strip()
            
        nombre_cli = str(rma_data.get("nombre_cliente_firma") or "")

        c.drawCentredString(left_x  + col_w / 2, firma_y - 22, tecnico_texto)
        c.drawCentredString(right_x + col_w / 2, firma_y - 22, nombre_cli or "NOMBRE Y FIRMA")

        return firma_y - 30



    def _draw_footer_bar(self, c) -> None:
        bar_h = 22; bar_y = self.MB
        bar_x = self.ML; bar_w = self.CW
        c.setFillColor(_DARK_HDR)
        c.rect(bar_x, bar_y, bar_w, bar_h, fill=1, stroke=0)
        c.setFillColor(_WHITE); c.setFont("Helvetica-Bold", 8)
        c.drawString(bar_x + 6, bar_y + 7, "438 154 8258")
        c.drawCentredString(bar_x + bar_w / 2, bar_y + 7, "www.basculaspesa.com.mx")
        c.drawRightString(bar_x + bar_w - 6, bar_y + 7, "Queretaro, Mexico")

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
rma_pdf_generator = RmaPdfGenerator()
