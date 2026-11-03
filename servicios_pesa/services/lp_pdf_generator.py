"""
Generador de PDF — Levantamiento de Proyecto (LP).
Diseño para 1 sola página (uso interno).
"""

import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

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

_RED_PESA    = colors.HexColor("#C8102E")
_GRAY_DARK   = colors.HexColor("#2C3E50")
_GRAY_LIGHT  = colors.HexColor("#F8F9FA")
_GRAY_BORDER = colors.HexColor("#D1D5DB")
_BLACK       = colors.HexColor("#1A1A1A")
_WHITE       = colors.white

class LPPdfGenerator:
    ML = 36
    MR = 36
    MT = 36
    MB = 36
    W  = 612
    H  = 792

    @property
    def CW(self) -> float:
        return self.W - self.ML - self.MR

    def generate(
        self,
        os_data: dict,
        output_path: Optional[str] = None,
        force: bool = False,
    ) -> str:
        if not _RL_OK:
            raise RuntimeError("ReportLab no instalado.")

        folio = os_data.get("folio_os", "LP-XXX")
        if output_path is None:
            output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
            try:
                output_dir.mkdir(parents=True, exist_ok=True)
            except (PermissionError, OSError):
                output_dir = Path.home() / "PesaServidorLocal" / "PDF_OS"
                output_dir.mkdir(parents=True, exist_ok=True)
            output_path = str(output_dir / f"{folio}.pdf")

        if not force and Path(output_path).exists():
            logger.info("PDF LP ya existe, omitiendo: %s", output_path)
            return output_path

        c = rl_canvas.Canvas(output_path, pagesize=letter)
        c.setTitle(f"Levantamiento de Proyecto - {folio}")

        self._draw_page(c, os_data)

        c.save()
        logger.info("PDF LP generado en: %s", output_path)
        return output_path

    def _draw_page(self, c, os_data: dict):
        c.setPageSize((self.W, self.H))
        
        y = self.H - self.MT
        
        from reportlab.platypus import Table, TableStyle, Paragraph, Image
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        styles = getSampleStyleSheet()
        
        # ── 1. Encabezado Corporativo ──
        logo_img = ""
        if _LOGO_PESA_PATH:
            logo_img = Image(str(_LOGO_PESA_PATH), width=120, height=31)
            
        style_title = ParagraphStyle(name='T', fontName='Helvetica-Bold', fontSize=10, alignment=1, textColor=_GRAY_DARK, leading=12)
        titulo_paragraph = Paragraph("<b>TOMA DE DIAGNÓSTICO Y LEVANTAMIENTO TÉCNICO</b><br/><font color='#C8102E' size='8'>Uso Interno — Ingeniería & Proyectos</font>", style_title)
        
        folio = os_data.get("folio_os", "LP-")
        fecha_obj = os_data.get("fecha")
        fecha_str = fecha_obj.strftime("%d/%m/%Y") if fecha_obj else ""
        
        style_folio_title = ParagraphStyle(name='FT', fontName='Helvetica-Bold', fontSize=10, alignment=1, textColor=_WHITE)
        style_folio_date = ParagraphStyle(name='FD', fontName='Helvetica', fontSize=9, alignment=1, textColor=_GRAY_DARK)
        
        folio_table = Table([
            [Paragraph(f"FOLIO: {folio}", style_folio_title)],
            [Paragraph(f"Fecha: {fecha_str}", style_folio_date)]
        ], colWidths=[130], rowHeights=[17, 18])
        
        folio_table.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, 0), _RED_PESA),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('BOX', (0, 0), (-1, -1), 1.5, _RED_PESA),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 0),
            ('TOPPADDING', (0, 0), (-1, -1), 1),
        ]))
        
        header_table = Table(
            [[logo_img, titulo_paragraph, folio_table]],
            colWidths=[120, 270, 130]
        )
        header_table.setStyle(TableStyle([
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('ALIGN', (0, 0), (0, 0), 'LEFT'),
            ('ALIGN', (1, 0), (1, 0), 'CENTER'),
            ('ALIGN', (2, 0), (2, 0), 'RIGHT'),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 0),
            ('TOPPADDING', (0, 0), (-1, -1), 0),
        ]))
        
        header_table.wrapOn(c, self.CW, 60)
        header_table.drawOn(c, self.ML, y - 40)
        
        y -= 50
        
        # ── 1. Datos del Cliente y Ubicación ──
        c.setFont("Helvetica-Bold", 10)
        c.setFillColor(_GRAY_DARK)
        c.drawString(self.ML, y, "1. DATOS DEL CLIENTE Y UBICACIÓN")
        y -= 10
        
        # Tabla Platypus para acomodo dinámico de texto
        style_cell = ParagraphStyle('CellText', fontName='Helvetica', fontSize=8, leading=10, textColor=_BLACK)
        p_style_lbl = ParagraphStyle("p_style_lbl", parent=style_cell, fontName="Helvetica-Bold", textColor=_GRAY_DARK)
        
        razon_social_p = Paragraph(str(os_data.get("cliente", "")), style_cell)
        # Patrón unificado de 6 claves para dirección de sucursal
        sucursal_addr = (
            os_data.get("direccion") or
            os_data.get("sucursal_direccion") or
            os_data.get("direccion_planta") or
            os_data.get("cliente_direccion") or
            os_data.get("sucursal") or
            os_data.get("ubicacion") or
            ""
        ).strip()
        sucursal_p = Paragraph(sucursal_addr, style_cell)
        
        data_s1 = [
            [Paragraph("<b>RAZÓN SOCIAL:</b>", p_style_lbl), razon_social_p, Paragraph("<b>SUCURSAL / PLANTA:</b>", p_style_lbl), sucursal_p],
            [Paragraph("<b>ÁREA LEVANTAMIENTO:</b>", p_style_lbl), Paragraph(str(os_data.get("area_levantamiento", "")), style_cell), Paragraph("<b>CONTACTO / TEL / CORREO:</b>", p_style_lbl), Paragraph(str(os_data.get("contacto_planta", "")), style_cell)]
        ]
        
        # Anchos ajustados para que NADA se salga de las celdas
        t = Table(data_s1, colWidths=[110, 150, 110, 150])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (0, 1), _GRAY_LIGHT),
            ('BACKGROUND', (2, 0), (2, 1), _GRAY_LIGHT),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('GRID', (0, 0), (-1, -1), 1, _GRAY_BORDER),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
            ('TOPPADDING', (0, 0), (-1, -1), 4),
        ]))
        
        _, th = t.wrap(self.CW, 100)
        t.drawOn(c, self.ML, y - th)
        
        y -= (th + 10)
        
        # ── 2. Especificaciones Técnicas del Proyecto ──
        lp = os_data.get("levantamiento_proyecto") or {}
        
        def render_opts(options, selected):
            res = []
            for opt in options:
                is_sel = selected and opt.lower() in selected.lower()
                box = "[ X ]" if is_sel else "[   ]"
                res.append(f"{box} {opt}")
            return "&nbsp;&nbsp;&nbsp;".join(res)
            
        style_h2 = ParagraphStyle("h2", fontName="Helvetica-Bold", fontSize=10, textColor=_GRAY_DARK, leading=14)
        style_bold = ParagraphStyle("b", fontName="Helvetica-Bold", fontSize=8, textColor=_GRAY_DARK, leading=12)
        style_normal = ParagraphStyle("n", fontName="Helvetica", fontSize=8, textColor=_BLACK, leading=12)
        
        sec2_content = [
            [Paragraph("<b>2. ESPECIFICACIONES TÉCNICAS DEL PROYECTO</b>", style_h2), ""],
            [Paragraph("<b>Construcción:</b>", style_bold), Paragraph(render_opts(["Acero Inoxidable", "Acero al Carbón", "Especial", "N/A"], lp.get("material", "")), style_normal)],
            [Paragraph("<b>Área / Seguridad:</b>", style_bold), Paragraph(render_opts(["Estándar", "Intrínsecamente Segura"], lp.get("clasificacion_area", "")), style_normal)],
            [Paragraph("<b>Salida de Com.:</b>", style_bold), Paragraph(render_opts(["4-20 mA", "Tarjeta PLC / Bus", "RS232/485", "Ethernet/IP", "N/A", "Otro: ________"], lp.get("senal_comunicacion", "")), style_normal)],
            [Paragraph("<b>Puntos de Corte:</b>", style_bold), Paragraph(render_opts(["Sí Aplica", "No Aplica"], lp.get("puntos_corte", "")), style_normal)],
            [Paragraph("<b>Trabajo en Alturas:</b>", style_bold), Paragraph(render_opts(["Sí Aplica", "No Aplica"], lp.get("alturas", "")), style_normal)],
            [Paragraph("<b>Cursos Seguridad:</b>", style_bold), Paragraph(render_opts(["Sí (Especificar: ________________)", "No"], lp.get("cursos", "")), style_normal)],
            [Paragraph("<b>Capacidad Estimada:</b>", style_bold), Paragraph(f"<u>{lp.get('capacidad_estimada') or '______________________________________'}</u>", style_normal)],
        ]
        
        sec2_table = Table(sec2_content, colWidths=[120, self.CW - 120])
        sec2_table.setStyle(TableStyle([
            ('SPAN', (0, 0), (1, 0)),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('TOPPADDING', (0, 0), (-1, -1), 1),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 1),
        ]))
        
        _, th2 = sec2_table.wrap(self.CW, 100)
        sec2_table.drawOn(c, self.ML, y - th2)
        y -= (th2 + 12)
        
        bloque_a_html = f"""
        <font size="10" color="#2C3E50"><b>BLOQUE A: TANQUES / SILOS</b></font><br/>
        <b>Estructura:</b> {render_opts(["Existente", "Requiere diseño"], lp.get("tanque_estructura", ""))}<br/>
        <b>Apoyos:</b> {render_opts(["3 Puntos", "4 Puntos"], lp.get("tanque_puntos", ""))}<br/>
        <b>Agitador:</b> {render_opts(["Sí", "No"], lp.get("tanque_agitador", ""))}<br/>
        <b>Peso Muerto:</b> {lp.get('tanque_peso_muerto') or '_________ kg / Ton'}<br/>
        <b>Cap. Útil:</b> {lp.get('tanque_capacidad_util') or '_________ kg / Ton'}
        """

        bloque_b_html = f"""
        <font size="10" color="#2C3E50"><b>BLOQUE B: CAMIONERAS / FERROCARRIL</b></font><br/>
        <b>Instalación:</b> {render_opts(["Fosa", "Rampas"], lp.get("cam_tipo", ""))}<br/>
        <b>Báscula tipo:</b> {render_opts(["Camionera", "FFCC"], lp.get("cam_trafico", ""))}<br/>
        <b>Dimensiones:</b> {lp.get('cam_dimensiones') or '_________ m x _________ m'}<br/>
        <b>Cap. Max:</b> {lp.get('cam_capacidad') or '_________ Toneladas'}
        """

        bloques_table = Table([[Paragraph(bloque_a_html, style_normal), Paragraph(bloque_b_html, style_normal)]], colWidths=[self.CW/2, self.CW/2])
        bloques_table.setStyle(TableStyle([
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('TOPPADDING', (0, 0), (-1, -1), 1),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 1),
        ]))
        
        _, th3 = bloques_table.wrap(self.CW, 100)
        bloques_table.drawOn(c, self.ML, y - th3)
        y -= (th3 + 14)
        
        # ── 3. Equipos e Instrumentación Identificados ──
        c.setFont("Helvetica-Bold", 10)
        c.setFillColor(_GRAY_DARK)
        c.drawString(self.ML, y, "3. EQUIPOS E INSTRUMENTACIÓN IDENTIFICADOS")
        y -= 10
        
        # Encabezado
        c.setFillColor(_GRAY_DARK)
        c.rect(self.ML, y - 18, self.CW, 18, stroke=0, fill=1)
        c.setFillColor(_WHITE)
        # Cols: TIPO DE INSTRUMENTO (200) | OBSERVACIONES TÉCNICAS (Stretch)
        cols = [self.ML, self.ML + 200, self.ML + self.CW]
        
        c.drawString(cols[0] + 5, y - 12, "TIPO DE INSTRUMENTO")
        c.drawString(cols[1] + 5, y - 12, "OBSERVACIONES TÉCNICAS")
        
        y -= 18
        
        equipos = lp.get("equipos_dinamicos", [])
        total_rows = max(len(equipos), 5) # Increased min rows to 5 to loosen layout
        
        from reportlab.lib.utils import simpleSplit
        c.setStrokeColor(_GRAY_BORDER)
        c.setLineWidth(0.5)
        w_col0 = cols[1] - cols[0] - 10
        w_col1 = cols[2] - cols[1] - 10
        for i in range(total_rows):
            eq = equipos[i] if i < len(equipos) else {}
            val_tipo = str(eq.get("tipo") or eq.get("marca") or "").strip()
            obs_eq_raw = str(eq.get("observaciones") or "").strip()
            eq_font_size = 7.0 if len(obs_eq_raw) > 160 else 8.0
            eq_lh = eq_font_size + 2.0

            tipo_lines = simpleSplit(val_tipo, "Helvetica", eq_font_size, w_col0) if val_tipo else []
            obs_eq_lines = []
            for p_eq in obs_eq_raw.splitlines():
                if p_eq.strip():
                    obs_eq_lines.extend(simpleSplit(p_eq.strip(), "Helvetica", eq_font_size, w_col1))
                else:
                    obs_eq_lines.append("")

            n_ln = max(1, len(tipo_lines), len(obs_eq_lines))
            row_h = max(18, n_ln * eq_lh + 6)

            if i % 2 == 1:
                c.setFillColor(_GRAY_LIGHT)
                c.rect(self.ML, y - row_h, self.CW, row_h, stroke=0, fill=1)

            c.setFillColor(_BLACK)
            c.setFont("Helvetica", eq_font_size)

            ty_cursor = y - 11
            for tl in tipo_lines:
                c.drawString(cols[0] + 5, ty_cursor, tl)
                ty_cursor -= eq_lh

            oy_cursor = y - 11
            for ol in obs_eq_lines:
                c.drawString(cols[1] + 5, oy_cursor, ol)
                oy_cursor -= eq_lh

            # Vertical lines
            c.line(cols[1], y, cols[1], y - row_h)
            c.rect(self.ML, y - row_h, self.CW, row_h, stroke=1, fill=0) # Outer border of row

            y -= row_h
        
        y -= 14
        
        # ── 4. Requerimientos para Servicio, EPP & Pesas Patrón ──
        c.setFont("Helvetica-Bold", 10)
        c.setFillColor(_GRAY_DARK)
        c.drawString(self.ML, y, "4. REQUERIMIENTOS PARA SERVICIO, EPP Y PESAS PATRÓN")
        y -= 10
        
        c.setFillColor(_RED_PESA)
        c.rect(self.ML, y - 16, self.CW, 16, stroke=0, fill=1)
        c.setFillColor(_WHITE)
        c.setFont("Helvetica-Bold", 8)
        col_w = self.CW / 4
        c.drawString(self.ML + 5, y - 11, "Equipos / Maniobras")
        c.drawString(self.ML + col_w + 5, y - 11, "EPP / Seguridad")
        c.drawString(self.ML + col_w*2 + 5, y - 11, "Pesas Patrón Requeridas")
        c.drawString(self.ML + col_w*3 + 5, y - 11, "Instrumentación Adicional")
        
        y -= 16
        c.setFillColor(_WHITE)
        c.rect(self.ML, y - 65, self.CW, 65, stroke=1, fill=0)
        c.setStrokeColor(_GRAY_BORDER)
        for i in range(1, 4):
            c.line(self.ML + col_w*i, y, self.ML + col_w*i, y - 65)
            
        opts = [
            ["Polipasto / Cadenas", "Patín / Diablito", "Canasto de Elevar", "Camión Tara / Grúa"],
            ["Mascarilla N95", "Cuerdas de Vida", "Arnés de Seguridad", "Casco / Chaleco"],
            ["Pesas 5 kg / 10 kg", "Pesas 20 kg", "Pesas 500 / 1000 kg"],
            ["Indicador", "Celdas de Carga", "Caja Sumadora", "Impresora térmica", "Otro (Especificar: _________)"]
        ]
        
        lists = [
            lp.get("equipos_maniobra", []),
            lp.get("epp_seguridad", []),
            lp.get("masa_requerida", []),
            lp.get("instrumentacion", [])
        ]
        
        c.setFont("Helvetica", 8)
        c.setFillColor(_BLACK)
        for i in range(4):
            cx = self.ML + col_w*i + 5
            cy = y - 14
            for opt in opts[i]:
                is_sel = opt in lists[i] or any(opt.lower() in str(s).lower() for s in lists[i])
                box = "[ X ]" if is_sel else "[   ]"
                c.drawString(cx, cy, f"{box} {opt}")
                cy -= 12
                
        y -= 75
        
        # ── 5. Comentarios Técnicos y Firma ──
        c.setFont("Helvetica-Bold", 10)
        c.setFillColor(_GRAY_DARK)
        c.drawString(self.ML, y, "5. COMENTARIOS TÉCNICOS")
        y -= 12

        obs_raw = str(os_data.get("observaciones") or "").strip()
        font_name = "Helvetica"
        font_size = 7.0 if len(obs_raw) > 300 else (7.8 if len(obs_raw) > 160 else 8.5)
        line_height = font_size + 2.0
        ancho_util = self.CW - 12

        lineas_totales = []
        for parrafo in obs_raw.splitlines():
            if parrafo.strip():
                lineas_totales.extend(simpleSplit(parrafo.strip(), font_name, font_size, ancho_util))
            else:
                lineas_totales.append("")

        y_limite_firmas = self.MB + 55
        needed_h = max(55, len(lineas_totales) * line_height + 10)
        box_h = min(needed_h, max(38, y - y_limite_firmas))

        c.setStrokeColor(_GRAY_DARK)
        c.rect(self.ML, y - box_h, self.CW, box_h, stroke=1, fill=0)
        if not lineas_totales:
            c.setStrokeColor(_GRAY_BORDER)
            c.setLineWidth(0.5)
            c.line(self.ML + 5, y - 18, self.W - self.MR - 5, y - 18)
            c.line(self.ML + 5, y - 36, self.W - self.MR - 5, y - 36)

        c.setFont(font_name, font_size)
        c.setFillColor(_BLACK)
        y_inicio_obs = y - 12
        y_cursor = y_inicio_obs
        for linea in lineas_totales:
            if y_cursor < (y - box_h + 4) or y_cursor < y_limite_firmas:
                break
            c.drawString(self.ML + 6, y_cursor, linea)
            y_cursor -= line_height

        y -= box_h + 10
        
        tecnico_raw = os_data.get("tecnico_nombre") or ""
        valores_omitir = ["sin asignar", "none", "null", "— selecciona técnico —", "selecciona técnico", ""]
        if str(tecnico_raw).strip().lower() in valores_omitir:
            etiqueta_nombre = ""
        else:
            tecnico_texto = str(tecnico_raw).strip()
            etiqueta_nombre = f'<br/>\n        <font size="8" color="#1A1A1A"><b>[ {tecnico_texto} ]</b></font>'
        
        firma_html = f"""
        <para align="center" leading="11">
        ___________________________________________<br/>
        <b>TÉCNICO RESPONSABLE DEL LEVANTAMIENTO</b>{etiqueta_nombre}
        </para>
        """
        style_firma = ParagraphStyle('cb', fontName='Helvetica', fontSize=8, leading=11, textColor=_BLACK)
        p_firma = Paragraph(firma_html, style_firma)
        _, f_h = p_firma.wrap(self.CW, 100)
        
        # Dibujar respetando el flujo de 'y' actual (debajo de la caja de comentarios)
        p_firma.drawOn(c, self.ML, y - f_h - 18)
