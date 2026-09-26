# -*- coding: utf-8 -*-
"""
lv_pdf_generator.py -- Generador de PDF para Levantamiento Metrologico
y Logistica de Pesas (LV).

Orientacion: Letter LANDSCAPE (horizontal).
Ancho util disponible: ~744 pt con margenes de 24 pt.

Estructura del PDF (una sola pagina):
  1. Encabezado institucional: Logo PESA + Folio LV + Fecha + Cliente
  2. Tabla de 8 columnas INDEPENDIENTES de basculas/instrumentos
  3. Bloques inferiores en 2 COLUMNAS PARALELAS:
       Izq: Recomendacion Logistica de Pesas Patron y Maniobra
       Der: Observaciones Generales del Sitio
  4. Pie de pagina: Firma del Tecnico Responsable
"""
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from reportlab.lib.pagesizes import letter, landscape
    from reportlab.lib import colors
    from reportlab.pdfgen import canvas as rl_canvas
    from reportlab.platypus import Table, TableStyle, Paragraph, Image
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.utils import simpleSplit
    _RL_OK = True
except ImportError:
    _RL_OK = False
    logger.warning("ReportLab no instalado: pip install reportlab")

import sys as _sys
import os as _os

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


_LOGO_PESA_PATH = _resolve_logo("logo_pesa")

# -- Paleta de colores --------------------------------------------------------
_RED_PESA    = colors.HexColor("#C8102E")
_GRAY_DARK   = colors.HexColor("#1A3A5C")   # Azul marino (encabezado tabla)
_GRAY_MED    = colors.HexColor("#5D6D7E")
_GRAY_LIGHT  = colors.HexColor("#F4F6F8")
_GRAY_BORDER = colors.HexColor("#D1D5DB")
_BLACK       = colors.HexColor("#1A1A1A")
_WHITE       = colors.white
_BLUE_DARK   = colors.HexColor("#1A3A5C")   # Mismo azul marino


class LvPdfGenerator:
    """
    Genera el PDF de Levantamiento Metrologico y Logistica de Pesas
    en orientacion LANDSCAPE (horizontal) con 8 columnas independientes.
    """

    # -- Dimensiones LANDSCAPE Letter -----------------------------------------
    ML = 24   # Margen izquierdo
    MR = 24   # Margen derecho
    MT = 16   # Margen superior
    MB = 15   # Margen inferior (15pt para alojar pie de página)
    W  = 792  # Ancho landscape letter (puntos)
    H  = 612  # Alto landscape letter (puntos)

    @property
    def CW(self) -> float:
        """Ancho de contenido disponible: ~744 pt."""
        return self.W - self.ML - self.MR

    def generate(
        self,
        os_data: dict,
        output_path: Optional[str] = None,
        force: bool = False,
    ) -> str:
        if not _RL_OK:
            raise RuntimeError(
                "ReportLab no esta instalado. Ejecute: pip install reportlab"
            )

        folio = os_data.get("folio_os", "LV-XXX")
        if output_path is None:
            output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
            try:
                output_dir.mkdir(parents=True, exist_ok=True)
            except (PermissionError, OSError):
                output_dir = Path.home() / "PesaServidorLocal" / "PDF_OS"
                output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")

        if not force and Path(output_path).exists():
            logger.info("PDF LV ya existe, omitiendo: %s", output_path)
            return output_path

        # Canvas en LANDSCAPE
        c = rl_canvas.Canvas(output_path, pagesize=landscape(letter))
        c.setTitle(f"Levantamiento Metrologico y Logistica de Pesas - {folio}")
        c.setAuthor("Basculas PESA -- Servicios Metrologicos")

        self._draw_page(c, os_data)

        c.save()
        logger.info("PDF LV generado en: %s", output_path)
        return output_path

    # =========================================================================
    # Dibujo principal
    # =========================================================================

    def _draw_page(self, c, os_data: dict) -> None:
        c.setPageSize(landscape(letter))
        y = self.H - self.MT

        # -- Estilos de parrafo -----------------------------------------------
        style_white = ParagraphStyle(
            "w",
            fontName="Helvetica-Bold",
            fontSize=8.5,
            textColor=_WHITE,
            leading=11,
            alignment=1,
        )
        style_title = ParagraphStyle(
            "t",
            fontName="Helvetica-Bold",
            fontSize=9.5,
            alignment=1,
            textColor=_GRAY_DARK,
            leading=12,
        )
        style_folio_title = ParagraphStyle(
            "ft",
            fontName="Helvetica-Bold",
            fontSize=10,
            alignment=1,
            textColor=_WHITE,
        )
        style_folio_date = ParagraphStyle(
            "fd",
            fontName="Helvetica",
            fontSize=8.5,
            alignment=1,
            textColor=_GRAY_DARK,
        )
        style_cell = ParagraphStyle(
            "ce",
            fontName="Helvetica",
            fontSize=7.5,
            textColor=_BLACK,
            leading=9,
        )
        style_cell_bold = ParagraphStyle(
            "cb",
            fontName="Helvetica-Bold",
            fontSize=7.5,
            textColor=_GRAY_DARK,
            leading=9,
        )
        style_section = ParagraphStyle(
            "sec",
            fontName="Helvetica-Bold",
            fontSize=8,
            textColor=_WHITE,
            leading=10,
            alignment=0,
        )

        # =====================================================================
        # 1. ENCABEZADO INSTITUCIONAL
        # =====================================================================
        logo_img = ""
        if _LOGO_PESA_PATH:
            logo_img = Image(str(_LOGO_PESA_PATH), width=130, height=34)

        titulo_p = Paragraph(
            "<b>LEVANTAMIENTO METROLOGICO Y LOGISTICA DE PESAS PATRON</b>"
            "<br/><font color='#C8102E' size='8'>"
            "Pre-Visita -- Basculas PESA | Rice Lake Weighing Systems"
            "</font>",
            style_title,
        )

        folio     = os_data.get("folio_os", "LV-")
        fecha_obj = os_data.get("fecha")
        fecha_str = fecha_obj.strftime("%d/%m/%Y") if fecha_obj else ""

        folio_tbl = Table(
            [
                [Paragraph(f"FOLIO: {folio}", style_folio_title)],
                [Paragraph("FECHA:  ____ / ____ / ____", style_folio_date)],
            ],
            colWidths=[140],
            rowHeights=[18, 16],
        )
        folio_tbl.setStyle(TableStyle([
            ("BACKGROUND",    (0, 0), (0, 0), _RED_PESA),
            ("ALIGN",         (0, 0), (-1, -1), "CENTER"),
            ("VALIGN",        (0, 0), (-1, -1), "MIDDLE"),
            ("BOX",           (0, 0), (-1, -1), 1.5, _RED_PESA),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ("TOPPADDING",    (0, 0), (-1, -1), 2),
        ]))

        # El encabezado ocupa todo el ancho (CW = ~744 pt)
        hdr_cw = self.CW
        logo_w = 140
        folio_w = 150
        titulo_w = hdr_cw - logo_w - folio_w

        hdr_tbl = Table(
            [[logo_img, titulo_p, folio_tbl]],
            colWidths=[logo_w, titulo_w, folio_w],
        )
        hdr_tbl.setStyle(TableStyle([
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("ALIGN",  (0, 0), (0, 0), "LEFT"),
            ("ALIGN",  (1, 0), (1, 0), "CENTER"),
            ("ALIGN",  (2, 0), (2, 0), "RIGHT"),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ("TOPPADDING",    (0, 0), (-1, -1), 0),
        ]))
        hdr_tbl.wrapOn(c, hdr_cw, 60)
        hdr_tbl.drawOn(c, self.ML, y - 44)
        y -= 54

        # -- Linea divisoria roja ----------------------------------------------
        c.setStrokeColor(_RED_PESA)
        c.setLineWidth(1.5)
        c.line(self.ML, y, self.W - self.MR, y)
        y -= 10

        # =====================================================================
        # 2. DATOS DEL CLIENTE Y TECNICO
        # =====================================================================
        cliente   = os_data.get("cliente") or os_data.get("cliente_nombre") or ""
        direccion = (
            os_data.get("direccion") or
            os_data.get("sucursal_direccion") or
            os_data.get("direccion_planta") or
            os_data.get("cliente_direccion") or
            os_data.get("sucursal") or
            os_data.get("ubicacion") or ""
        ).strip()
        tecnico = os_data.get("tecnico_nombre") or os_data.get("tecnico") or ""

        # Distribucion del ancho: CW = 744 pt aprox.
        # [Etiqueta Cliente | Valor Cliente | Etiqueta Tecnico | Valor Tecnico]
        # [Etiqueta Direccion | Valor Direccion (span 3 cols)]
        cli_col = [90, 310, 80, 264]
        datos_cli = [
            [
                Paragraph("<b>CLIENTE / RAZON SOCIAL:</b>", style_cell_bold),
                Paragraph(cliente, style_cell),
                Paragraph("<b>TECNICO:</b>", style_cell_bold),
                Paragraph(tecnico, style_cell),
            ],
            [
                Paragraph("<b>DIRECCION DE PLANTA:</b>", style_cell_bold),
                Paragraph(direccion, style_cell),
                Paragraph("", style_cell),
                Paragraph("", style_cell),
            ],
        ]
        t_cli = Table(datos_cli, colWidths=cli_col)
        t_cli.setStyle(TableStyle([
            ("BACKGROUND",    (0, 0), (0, -1), _GRAY_LIGHT),
            ("BACKGROUND",    (2, 0), (2, -1), _GRAY_LIGHT),
            ("VALIGN",        (0, 0), (-1, -1), "MIDDLE"),
            ("GRID",          (0, 0), (-1, -1), 0.5, _GRAY_BORDER),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING",    (0, 0), (-1, -1), 4),
            ("LEFTPADDING",   (0, 0), (-1, -1), 5),
            ("SPAN",          (1, 1), (3, 1)),
        ]))
        _, th = t_cli.wrap(self.CW, 80)
        t_cli.drawOn(c, self.ML, y - th)
        y -= th + 10

        # =====================================================================
        # 3. TABLA DE BASCULAS -- 8 COLUMNAS INDEPENDIENTES
        # =====================================================================
        # Titulo de seccion
        c.setFont("Helvetica-Bold", 9)
        c.setFillColor(_GRAY_DARK)
        c.drawString(self.ML, y, "BASCULAS E INSTRUMENTOS IDENTIFICADOS")
        y -= 5

        # -- Definicion de las 8 columnas -------------------------------------
        # Suma total = 744 pt (ancho util en landscape con margenes de 24)
        #  Col 1: Tag / ID              = 60 pt
        #  Col 2: Tipo de Instrumento   = 110 pt
        #  Col 3: Marca                 = 85 pt
        #  Col 4: Modelo                = 85 pt
        #  Col 5: N de Serie            = 90 pt
        #  Col 6: Capacidad Maxima      = 85 pt
        #  Col 7: Division Minima (e/d) = 65 pt
        #  Col 8: Ubicacion en Planta   = 164 pt
        #  Total                        = 744 pt

        col_widths_basc = [60, 110, 85, 85, 90, 85, 65, 164]
        # Ajuste fino para que sumen exactamente CW
        suma = sum(col_widths_basc)
        diff = self.CW - suma
        col_widths_basc[-1] += diff  # Ajustar ultima columna

        headers_basc = [
            Paragraph("<b>Tag / ID</b>",               style_white),
            Paragraph("<b>Tipo de Instrumento</b>",    style_white),
            Paragraph("<b>Marca</b>",                  style_white),
            Paragraph("<b>Modelo</b>",                 style_white),
            Paragraph("<b>N&#176; de Serie</b>",       style_white),
            Paragraph("<b>Capacidad Maxima</b>",       style_white),
            Paragraph("<b>Division Min. (e/d)</b>",    style_white),
            Paragraph("<b>Ubicacion en Planta / Area</b>", style_white),
        ]

        # Leer basculas del os_data
        lv = os_data.get("levantamiento_metrologico") or {}
        import json
        basculas = lv.get("basculas", [])
        if isinstance(basculas, str):
            try:
                basculas = json.loads(basculas)
            except Exception:
                basculas = []

        tbl_data = [headers_basc]

        for b in basculas:
            tbl_data.append([
                Paragraph(b.get("id_indicador")     or "", style_cell),
                Paragraph(b.get("tipo_instrumento") or "", style_cell),
                Paragraph(b.get("marca")            or "", style_cell),
                Paragraph(b.get("modelo")           or "", style_cell),
                Paragraph(b.get("numero_serie")     or "", style_cell),
                Paragraph(b.get("capacidad_max")    or "", style_cell),
                Paragraph(b.get("division_min")     or "", style_cell),
                Paragraph(b.get("ubicacion_interna")or "", style_cell),
            ])

        # Máximo 8 filas en blanco para llenado a mano (celdas limpias)
        MIN_ROWS = 8
        while len(tbl_data) < MIN_ROWS + 1:
            tbl_data.append(["", "", "", "", "", "", "", ""])

        ROW_H_HDR  = 14   # Encabezado azul marino (reducido a 14pt)
        ROW_H_DATA = 12   # Filas de captura (12pt para liberar espacio vertical)

        tbl_basc = Table(
            tbl_data,
            colWidths=col_widths_basc,
            rowHeights=[ROW_H_HDR] + [ROW_H_DATA] * (len(tbl_data) - 1),
        )

        tbl_style = TableStyle([
            # Encabezado azul marino, texto blanco centrado
            ("BACKGROUND",    (0, 0), (-1, 0), _BLUE_DARK),
            ("TEXTCOLOR",     (0, 0), (-1, 0), _WHITE),
            ("ALIGN",         (0, 0), (-1, 0), "CENTER"),
            ("VALIGN",        (0, 0), (-1, -1), "MIDDLE"),
            ("FONTNAME",      (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE",      (0, 0), (-1, 0), 6.5),  # Fuente reducida a 6.5pt
            # Grid completo
            ("GRID",          (0, 0), (-1, -1), 0.5, _GRAY_BORDER),
            # Padding encabezado (reducido)
            ("BOTTOMPADDING", (0, 0), (-1, 0), 1.5),
            ("TOPPADDING",    (0, 0), (-1, 0), 1.5),
            # Padding filas de datos (reducido al mínimo)
            ("BOTTOMPADDING", (0, 1), (-1, -1), 1.5),
            ("TOPPADDING",    (0, 1), (-1, -1), 1.5),
            ("LEFTPADDING",   (0, 0), (-1, -1), 4),
            ("RIGHTPADDING",  (0, 0), (-1, -1), 4),
        ])

        # Filas alternas (gris muy suave en pares)
        for i in range(1, len(tbl_data)):
            if i % 2 == 0:
                tbl_style.add("BACKGROUND", (0, i), (-1, i), _GRAY_LIGHT)

        tbl_basc.setStyle(tbl_style)
        _, th_basc = tbl_basc.wrap(self.CW, 400)
        tbl_basc.drawOn(c, self.ML, y - th_basc)
        y -= th_basc + 4   # Spacer de 4pt entre tabla y bloque de observaciones

        # =====================================================================
        # 4. BLOQUE UNICO DE OBSERVACIONES -- ANCHO COMPLETO, RENGLON DINAMICO
        # =====================================================================
        # Calculo dinamico de renglones: 2 renglones por bascula identificada.
        # El numero de basculas ya fue calculado arriba al construir tbl_data.
        num_basculas     = max(len(basculas), 1)   # al menos 1 grupo de renglones
        # Limitar a máximo 6 renglones de observaciones para no desbordar página
        total_renglones  = min(num_basculas * 2, 6)

        # Altura de cabecera del bloque (reducida a 13pt)
        OBS_HDR_H = 13

        # Espacio de la pagina reservado para la firma y su spacer:
        #   Spacer(1, 9) entre bloque y firma   =  9 pt
        #   Altura texto firma (linea + nombre) = 34 pt
        #   Margen inferior (MB)                = 15 pt
        SPACER_FIRMA  = 9    # separador reducido entre recuadro y firma
        FIRMA_TOTAL_H = 34   # alto reservado para el texto de firma
        # Base inferior del recuadro:
        # MB(15) + FIRMA_TOTAL_H(34) + SPACER_FIRMA(9) = 58 pt
        BLK_BASE_Y    = self.MB + FIRMA_TOTAL_H + SPACER_FIRMA
        espacio_disponible = y - OBS_HDR_H - BLK_BASE_Y
        # Altura de renglon fija a 11 pt para que quepan en página
        ROW_H_OBS = 11.0
        BLK_OBS_H = total_renglones * ROW_H_OBS   # altura total del cuerpo

        # -- Cabecera del bloque (azul marino, ancho completo) ----------------
        c.setFillColor(_BLUE_DARK)
        c.rect(self.ML, y - OBS_HDR_H, self.CW, OBS_HDR_H, stroke=0, fill=1)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(
            self.ML + 6,
            y - OBS_HDR_H + 4,
            "OBSERVACIONES Y CONDICIONES POR INSTRUMENTO / LOGISTICA",
        )
        y -= OBS_HDR_H

        # -- Cuerpo del bloque (borde azul marino) ----------------------------
        # TOP_PAD: margen interno superior para despegar [1] del encabezado azul
        TOP_PAD   = 8    # pt de respiro entre barra de titulo y primer renglon
        # El rectangulo crece TOP_PAD hacia abajo para absorber el padding interno
        RECT_H    = BLK_OBS_H + TOP_PAD

        c.setStrokeColor(_BLUE_DARK)
        c.setLineWidth(1.0)
        c.rect(self.ML, y - RECT_H, self.CW, RECT_H, stroke=1, fill=0)

        # -- Numeracion lateral y renglones horizontales ----------------------
        # Los renglones empiezan TOP_PAD pt por debajo del borde superior
        NUM_W   = 22   # ancho reservado para el numero [N]
        LINE_X1 = self.ML + NUM_W
        LINE_X2 = self.ML + self.CW - 4

        c.setStrokeColor(_GRAY_BORDER)
        c.setLineWidth(0.35)
        c.setFont("Helvetica", 6)
        c.setFillColor(_GRAY_MED)

        for i in range(total_renglones):
            # ry: posicion Y de la linea horizontal del renglon i
            # Se desplaza TOP_PAD desde el borde superior del recuadro
            ry = y - TOP_PAD - (i + 1) * ROW_H_OBS
            # Linea horizontal de renglon (solo si esta dentro del recuadro)
            if ry >= y - RECT_H + 1:
                c.line(LINE_X1, ry, LINE_X2, ry)

            # Numero de equipo cada 2 renglones (inicio del par)
            if i % 2 == 0:
                equipo_num = (i // 2) + 1
                # Vertline separador de numeracion (muy suave)
                c.setStrokeColor(_GRAY_BORDER)
                c.setLineWidth(0.25)
                top_seg = y - TOP_PAD - i * ROW_H_OBS        # borde superior del par
                bot_seg = y - TOP_PAD - (i + 2) * ROW_H_OBS  # borde inferior del par
                # Limitar al interior del recuadro
                top_seg = min(top_seg, y - 1)
                bot_seg = max(bot_seg, y - RECT_H + 1)
                c.line(self.ML + NUM_W - 1, top_seg, self.ML + NUM_W - 1, bot_seg)
                # Numero centrado verticalmente en el par de renglones
                mid_y = (top_seg + bot_seg) / 2 - 2   # -2 para ajuste optico
                c.setFillColor(_GRAY_MED)
                c.drawCentredString(self.ML + NUM_W / 2, mid_y, f"[{equipo_num}]")

            # Restablecer color de linea para el siguiente renglon
            c.setStrokeColor(_GRAY_BORDER)
            c.setLineWidth(0.35)

        # -- Texto de observaciones almacenado (si existe) --------------------
        obs_texto = lv.get("observaciones_generales") or ""
        if obs_texto:
            c.setFont("Helvetica", 7)
            c.setFillColor(_BLACK)
            obs_lines = simpleSplit(obs_texto, "Helvetica", 7, self.CW - NUM_W - 8)
            for idx, ln in enumerate(obs_lines[:total_renglones]):
                line_y = y - TOP_PAD - (idx + 1) * ROW_H_OBS + (ROW_H_OBS - 7) / 2 + 1
                c.drawString(LINE_X1 + 3, line_y, ln)

        y -= RECT_H + 6

        # =====================================================================
        # 5. PIE DE PAGINA -- FIRMA (anclada siempre al pie, posicion fija)
        # =====================================================================
        tecnico_raw    = os_data.get("tecnico_nombre") or ""
        valores_omitir = {"sin asignar", "none", "null", "-- selecciona tecnico --", ""}
        if tecnico_raw.strip().lower() in valores_omitir:
            tecnico_label = ""
        else:
            tecnico_label = (
                f"<br/><font size='8' color='#1A1A1A'><b>[ {tecnico_raw.strip()} ]</b></font>"
            )

        firma_style = ParagraphStyle(
            "firma",
            fontName="Helvetica",
            fontSize=8,
            leading=11,
            alignment=1,
            textColor=_BLACK,
        )

        firma_html = (
            "<para align='center' leading='11'>"
            "____________________________________________<br/>"
            f"<b>TECNICO RESPONSABLE DEL LEVANTAMIENTO</b>{tecnico_label}"
            "</para>"
        )
        p_firma = Paragraph(firma_html, firma_style)
        _, f_h = p_firma.wrap(self.CW, 60)

        # Firma dibujada en la zona reservada: FUERA y DEBAJO del recuadro.
        # BLK_BASE_Y = MB + FIRMA_TOTAL_H + SPACER_FIRMA (calculado arriba)
        # La firma ocupa desde MB hasta MB + FIRMA_TOTAL_H.
        # SPACER_FIRMA es el gap visible entre el borde del recuadro y la linea de firma.
        firma_draw_y = self.MB + 4   # 4 pt sobre el margen inferior = zona firma
        p_firma.drawOn(c, self.ML, firma_draw_y)

        # -- Pie de marca de agua (anclado a 15pt del borde inferior) ---------
        c.setFont("Helvetica", 6.5)
        c.setFillColor(_GRAY_BORDER)
        c.drawCentredString(
            self.W / 2,
            15,  # 15pt del borde inferior de la hoja
            "Basculas PESA -- Servicios Metrologicos  |  "
            "Documento de uso interno: Pre-Visita / Levantamiento"
        )
