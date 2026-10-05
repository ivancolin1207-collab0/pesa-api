"""
theme.py — Sistema de diseño QSS Global v4.0
Servicios PESA — Modern Industrial Enterprise UI

Paleta: Rojo PESA (#C8102E) + Azul Marino (#1E293B) + Gris neutro (#F0F2F5)
Filosofía: Alto contraste, tipografía corporativa limpia, sin pasteles deslavados.
"""

# ──────────────────────────────────────────────────────────────────────────────
# PALETA DE COLORES — Industrial Enterprise
# ──────────────────────────────────────────────────────────────────────────────
COLORS: dict[str, str] = {
    # Fondos
    "bg_primary":       "#F0F2F5",   # Fondo general de la aplicación
    "bg_surface":       "#F8FAFC",   # Superficies secundarias
    "bg_card":          "#FFFFFF",   # Tarjetas / paneles
    "bg_input":         "#FFFFFF",   # Campos de entrada

    # Acentos corporativos
    "accent_primary":   "#C8102E",   # Rojo PESA principal
    "accent_hover":     "#A50D25",   # Rojo hover
    "accent_pressed":   "#8A0B1E",   # Rojo pressed
    "accent_muted":     "#FEF2F2",   # Rojo muy suave (fondos)
    "accent_border":    "#FECDD3",   # Borde rojo sutil
    "navy":             "#1E293B",   # Azul marino industrial (textos principales)
    "focus_blue":       "#2563EB",   # Azul foco

    # Texto
    "text_primary":     "#0F172A",   # Negro pizarra (máximo contraste)
    "text_secondary":   "#64748B",   # Gris medio
    "text_muted":       "#94A3B8",   # Gris claro / hints
    "text_disabled":    "#CBD5E1",
    "text_on_red":      "#FFFFFF",

    # Bordes
    "border_default":   "#E2E8F0",   # Borde estándar suave
    "border_strong":    "#CBD5E1",   # Borde marcado
    "border_focus":     "#C8102E",   # Foco en rojo corporativo

    # Estados semánticos
    "success":          "#16A34A",
    "success_bg":       "#DCFCE7",
    "warning":          "#D97706",
    "warning_bg":       "#FEF3C7",
    "error":            "#C8102E",
    "error_bg":         "#FEF2F2",
    "info":             "#2563EB",
    "info_bg":          "#DBEAFE",

    # Badges de estado OS
    "estado_proceso":       "#92400E",
    "estado_proceso_bg":    "#FEF3C7",
    "estado_cancelada":     "#991B1B",
    "estado_cancelada_bg":  "#FEE2E2",
    "estado_escaneada":     "#166534",
    "estado_escaneada_bg":  "#DCFCE7",
    "estado_fisico":        "#475569",
    "estado_fisico_bg":     "#F1F5F9",
}

# ──────────────────────────────────────────────────────────────────────────────
# HOJA DE ESTILOS QSS GLOBAL — Industrial Enterprise v4.0
# ──────────────────────────────────────────────────────────────────────────────
STYLESHEET = """
/* ═══════════════════════════════════════════════════════════════════════════
   SERVICIOS PESA — QSS Global Industrial Enterprise v4.0
   ═══════════════════════════════════════════════════════════════════════════ */

/* ─── Raíz ──────────────────────────────────────────────────────────────── */
QMainWindow, QDialog, QWidget {
    background-color: #F0F2F5;
    color: #0F172A;
    font-family: 'Segoe UI', -apple-system, 'Helvetica Neue', sans-serif;
    font-size: 13px;
}

/* ─── Contenedores de Scroll ─────────────────────────────────────────────── */
QScrollArea {
    border: none;
    background-color: transparent;
}
QScrollArea > QWidget > QWidget {
    background-color: transparent;
}

/* ─── Barras de desplazamiento (slim enterprise) ─────────────────────────── */
QScrollBar:vertical {
    background: transparent;
    width: 7px;
    margin: 0;
}
QScrollBar::handle:vertical {
    background: #CBD5E1;
    border-radius: 3px;
    min-height: 28px;
}
QScrollBar::handle:vertical:hover   { background: #94A3B8; }
QScrollBar::handle:vertical:pressed { background: #64748B; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical,
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
    background: none; border: none; height: 0px;
}
QScrollBar:horizontal {
    background: transparent;
    height: 7px;
    margin: 0;
}
QScrollBar::handle:horizontal {
    background: #CBD5E1;
    border-radius: 3px;
    min-width: 28px;
}
QScrollBar::handle:horizontal:hover   { background: #94A3B8; }
QScrollBar::handle:horizontal:pressed { background: #64748B; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal,
QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {
    background: none; border: none; width: 0px;
}

/* ─── Campos de texto ────────────────────────────────────────────────────── */
QLineEdit, QTextEdit, QPlainTextEdit {
    background-color: #FFFFFF;
    color: #0F172A;
    border: 1px solid #CBD5E1;
    border-radius: 6px;
    padding: 7px 12px;
    selection-background-color: #DBEAFE;
    selection-color: #0F172A;
    font-size: 13px;
}
QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus {
    border: 1px solid #007AFF;
    background-color: #FFFFFF;
    padding: 6px 11px;
}
QLineEdit:disabled, QTextEdit:disabled, QPlainTextEdit:disabled {
    background-color: #F8FAFC;
    color: #94A3B8;
    border-color: #E2E8F0;
}
QLineEdit::placeholder, QTextEdit::placeholder { color: #94A3B8; }

/* ─── SpinBox ─────────────────────────────────────────────────────────────── */
QSpinBox, QDoubleSpinBox {
    background-color: #FFFFFF;
    color: #0F172A;
    border: 1px solid #CBD5E1;
    border-radius: 6px;
    padding: 6px 10px;
}
QSpinBox:focus, QDoubleSpinBox:focus { border: 1.5px solid #C8102E; }
QSpinBox::up-button, QDoubleSpinBox::up-button,
QSpinBox::down-button, QDoubleSpinBox::down-button {
    background: transparent; border: none; width: 18px; border-radius: 3px;
}
QSpinBox::up-button:hover, QDoubleSpinBox::up-button:hover,
QSpinBox::down-button:hover, QDoubleSpinBox::down-button:hover {
    background: #F1F5F9;
}

/* ─── ComboBox ────────────────────────────────────────────────────────────── */
QComboBox {
    background-color: #FFFFFF;
    color: #0F172A;
    border: 1px solid #CBD5E1;
    border-radius: 6px;
    padding: 7px 12px;
    min-height: 32px;
    font-size: 13px;
}
QComboBox:focus { border: 1.5px solid #C8102E; }
QComboBox:hover { border-color: #94A3B8; }
QComboBox::drop-down {
    border: none; width: 28px;
    border-left: 1px solid #E2E8F0;
}
QComboBox::down-arrow {
    border-left: 4px solid transparent;
    border-right: 4px solid transparent;
    border-top: 5px solid #64748B;
    margin-right: 6px;
}
QComboBox QAbstractItemView {
    background-color: #FFFFFF;
    color: #0F172A;
    selection-background-color: #F1F5F9;
    selection-color: #0F172A;
    border: 1px solid #E2E8F0;
    border-radius: 6px;
    outline: none;
    padding: 4px;
}

/* ─── DateEdit ────────────────────────────────────────────────────────────── */
QDateEdit {
    background-color: #FFFFFF;
    color: #0F172A;
    border: 1px solid #CBD5E1;
    border-radius: 6px;
    padding: 7px 12px;
}
QDateEdit:focus { border: 1.5px solid #C8102E; }
QDateEdit::drop-down {
    border: none; width: 28px;
    border-left: 1px solid #E2E8F0;
}
QCalendarWidget { background: #FFFFFF; color: #0F172A; border: 1px solid #E2E8F0; }
QCalendarWidget QToolButton {
    background: #F8FAFC; color: #0F172A; border: none;
    padding: 4px 8px; border-radius: 5px;
}
QCalendarWidget QToolButton:hover { background: #C8102E; color: #FFFFFF; }
QCalendarWidget QAbstractItemView {
    background: #FFFFFF;
    selection-background-color: #C8102E;
    selection-color: #FFFFFF;
}

/* ─── Botones (base) ─────────────────────────────────────────────────────── */
QPushButton {
    background-color: #FFFFFF;
    color: #1E293B;
    border: 1px solid #CBD5E1;
    border-radius: 6px;
    padding: 8px 18px;
    font-weight: 600;
    font-size: 12px;
    min-height: 32px;
}
QPushButton:hover {
    background-color: #F8FAFC;
    border-color: #94A3B8;
}
QPushButton:pressed {
    background-color: #F1F5F9;
    border-color: #64748B;
}
QPushButton:disabled {
    background-color: #F8FAFC;
    color: #CBD5E1;
    border-color: #E2E8F0;
}

/* Botón Primario — Rojo PESA sólido */
QPushButton[class="primary"] {
    background-color: #C8102E;
    color: #FFFFFF;
    border: none;
    font-weight: 700;
}
QPushButton[class="primary"]:hover   { background-color: #A50D25; }
QPushButton[class="primary"]:pressed { background-color: #8A0B1E; }

/* Botón Éxito */
QPushButton[class="success"] {
    background-color: #16A34A;
    color: #FFFFFF;
    border: none;
    font-weight: 600;
}
QPushButton[class="success"]:hover { background-color: #15803D; }

/* Botón Peligro (outlined) */
QPushButton[class="danger"] {
    background-color: transparent;
    color: #C8102E;
    border: 1.5px solid #C8102E;
    font-weight: 600;
}
QPushButton[class="danger"]:hover { background-color: #FEF2F2; }

/* ─── Etiquetas ───────────────────────────────────────────────────────────── */
QLabel { color: #0F172A; background: transparent; }

QLabel[class="title"] {
    font-size: 24px; font-weight: 700;
    color: #0F172A; letter-spacing: -0.5px;
}
QLabel[class="section-header"] {
    font-size: 11px; font-weight: 700;
    color: #475569; text-transform: uppercase; letter-spacing: 0.8px;
}
QLabel[class="folio"] {
    font-size: 28px; font-weight: 800;
    color: #0F172A; letter-spacing: 1px;
}
QLabel[class="muted"] {
    color: #94A3B8; font-size: 12px;
}
QLabel[class="error-max"] {
    font-size: 15px; font-weight: 700; color: #C8102E;
}

/* ─── TreeWidget / Tabla principal de OS ────────────────────────────────── */
QTreeWidget {
    background-color: #FFFFFF;
    color: #0F172A;
    border: 1px solid #E2E8F0;
    border-radius: 8px;
    outline: none;
    alternate-background-color: #FBFCFD;
    gridline-color: transparent;
    font-size: 12px;
}
QTreeWidget::item {
    color: #0F172A;
    padding: 0px 6px;
    min-height: 36px;
    border-bottom: 1px solid #F1F5F9;
}
QTreeWidget::item:hover {
    background-color: #F1F5F9;
}
QTreeWidget::item:selected {
    background-color: #EFF6FF;
    color: #0F172A;
}

/* Cabecera de la tabla — Enterprise dark header */
QHeaderView::section {
    background-color: #F8FAFC;
    color: #475569;
    font-weight: 700;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    border: none;
    border-bottom: 2px solid #E2E8F0;
    border-right: 1px solid #F1F5F9;
    padding: 8px 10px;
}
QHeaderView::section:first { border-radius: 8px 0 0 0; }
QHeaderView::section:last  { border-right: none; border-radius: 0 8px 0 0; }
QHeaderView::section:hover { background-color: #EFF6FF; color: #0F172A; }
QHeaderView { background: transparent; border: none; }

/* ─── QTableWidget ────────────────────────────────────────────────────────── */
QTableWidget, QTableView {
    background-color: #FFFFFF;
    color: #0F172A;
    gridline-color: #F1F5F9;
    border: 1px solid #E2E8F0;
    border-radius: 8px;
    outline: none;
    alternate-background-color: #FBFCFD;
}
QTableWidget::item, QTableView::item {
    color: #0F172A;
    padding: 6px 10px;
    border: none;
}
QTableWidget::item:hover, QTableView::item:hover { background-color: #F1F5F9; }
QTableWidget::item:selected, QTableView::item:selected {
    background-color: #EFF6FF;
    color: #0F172A;
}
QTableWidget QLineEdit {
    color: #0F172A !important;
    background-color: #FFFFFF !important;
    border: 1.5px solid #C8102E;
    font-weight: bold;
}
QTableWidget QTableCornerButton::section { background: #F8FAFC; border: none; }

/* ─── GroupBox ────────────────────────────────────────────────────────────── */
QGroupBox {
    border: 1px solid #E2E8F0;
    border-radius: 8px;
    margin-top: 24px;
    padding: 24px 12px 12px 12px;
    background-color: #FFFFFF;
}
QGroupBox::title {
    background-color: #F8FAFC;
    color: #475569;
    font-weight: 700;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    padding: 4px 10px;
    border-radius: 4px;
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 10px;
    top: 0px;
}

/* ─── Tabs ────────────────────────────────────────────────────────────────── */
QTabWidget::pane {
    border: 1px solid #E2E8F0;
    border-radius: 0 8px 8px 8px;
    background: #FFFFFF;
    top: -1px;
}
QTabBar::tab {
    background: #F1F5F9;
    color: #64748B;
    border: 1px solid #E2E8F0;
    border-bottom: none;
    border-radius: 6px 6px 0 0;
    padding: 9px 20px;
    font-weight: 600;
    font-size: 12px;
    margin-right: 2px;
}
QTabBar::tab:selected {
    color: #0F172A;
    background: #FFFFFF;
    border-color: #E2E8F0;
    border-bottom-color: #FFFFFF;
}
QTabBar::tab:hover:!selected { color: #0F172A; background: #E2E8F0; }

/* ─── Frame / Separadores ─────────────────────────────────────────────────── */
QFrame[frameShape="4"], QFrame[frameShape="5"] {
    color: #E2E8F0; border: none; background: #E2E8F0;
}

/* ─── CheckBox ────────────────────────────────────────────────────────────── */
QCheckBox { color: #0F172A; spacing: 8px; }
QCheckBox::indicator {
    width: 16px; height: 16px;
    border: 1.5px solid #CBD5E1;
    border-radius: 4px;
    background: #FFFFFF;
}
QCheckBox::indicator:checked {
    background: #C8102E;
    border-color: #C8102E;
}
QCheckBox::indicator:hover { border-color: #94A3B8; }

/* ─── RadioButton ─────────────────────────────────────────────────────────── */
QRadioButton { color: #0F172A; spacing: 8px; }
QRadioButton::indicator {
    width: 16px; height: 16px;
    border: 1.5px solid #CBD5E1;
    border-radius: 8px;
    background: #FFFFFF;
}
QRadioButton::indicator:checked { background: #C8102E; border-color: #C8102E; }
QRadioButton::indicator:hover   { border-color: #94A3B8; }

/* ─── Barra de estado ─────────────────────────────────────────────────────── */
QStatusBar {
    background: #FFFFFF;
    color: #64748B;
    border-top: 1px solid #E2E8F0;
    font-size: 11px;
    padding: 2px 8px;
}
QStatusBar::item { border: none; }

/* ─── MessageBox ──────────────────────────────────────────────────────────── */
QMessageBox { background: #FFFFFF; }
QMessageBox QLabel { color: #0F172A; }
QMessageBox QPushButton { min-width: 90px; }

/* ─── Tooltip ─────────────────────────────────────────────────────────────── */
QToolTip {
    background: #1E293B;
    color: #FFFFFF;
    border: none;
    border-radius: 5px;
    padding: 6px 10px;
    font-size: 11px;
}

/* ─── Splitter ────────────────────────────────────────────────────────────── */
QSplitter::handle:vertical   { background: #E2E8F0; height: 1px; }
QSplitter::handle:horizontal { background: #E2E8F0; width: 1px; }

/* ─── Barra de herramientas ───────────────────────────────────────────────── */
QToolBar {
    background: #FFFFFF;
    border-bottom: 1px solid #E2E8F0;
    spacing: 4px;
    padding: 4px;
}
QToolBar QToolButton {
    background: transparent;
    color: #64748B;
    border: none;
    border-radius: 5px;
    padding: 6px 10px;
}
QToolBar QToolButton:hover { background: #F1F5F9; color: #0F172A; }
"""


def get_badge_style(estado: str) -> str:
    """Retorna el estilo CSS inline para un badge de estado OS — macOS Technical Pills."""
    styles = {
        "PROCESO":            "background: #FFF3E0; color: #E65100; border: 1px solid #FFE0B2;",
        "CANCELADA":          "background: #FEE2E2; color: #991B1B; border: 1px solid #FCA5A5;",
        "ESCANEADA":          "background: #E8F5E9; color: #1B5E20; border: 1px solid #C8E6C9;",
        "COMPLETADA":         "background: #E8F5E9; color: #1B5E20; border: 1px solid #C8E6C9;",
        "COMPLETADA_DIGITAL": "background: #E8F5E9; color: #1B5E20; border: 1px solid #C8E6C9;",
        "CERRADO":            "background: #E8F5E9; color: #1B5E20; border: 1px solid #C8E6C9;",
        "CERRADA":            "background: #E8F5E9; color: #1B5E20; border: 1px solid #C8E6C9;",
        "FISICO":             "background: #EDE7F6; color: #4A148C; border: 1px solid #D1C4E9;",
        "DIGITAL":            "background: #E3F2FD; color: #0D47A1; border: 1px solid #BBDEFB;",
        "PENDING":            "background: #FFF3E0; color: #E65100; border: 1px solid #FFE0B2;",
        "SYNCED":             "background: #E8F5E9; color: #2E7D32; border: 1px solid #C8E6C9;",
    }
    base = (
        "border-radius: 6px; padding: 3px 8px; "
        "font-size: 11px; font-weight: 600; letter-spacing: 0.2px; "
    )
    return base + styles.get(estado.upper(), "background: #F5F5F7; color: #1D1D1F; border: 1px solid #E5E5EA;")

