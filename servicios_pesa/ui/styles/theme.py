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
    # Fondos corporativos minimalistas (Básculas PESA v3.2)
    "bg_primary":       "#F6F7F9",   # Canvas principal gris muy suave
    "bg_surface":       "#F8FAFC",   # Superficies secundarias / badges neutros
    "bg_card":          "#FFFFFF",   # Tarjetas / paneles / tablas
    "bg_input":         "#FFFFFF",   # Campos de entrada

    # Acentos corporativos
    "accent_primary":   "#C8102E",   # Rojo Corporativo Básculas PESA
    "accent_hover":     "#A60D26",   # Rojo hover
    "accent_pressed":   "#880B20",   # Rojo pressed
    "accent_muted":     "#F8FAFC",   # Superficie neutra activa (cero fondos rosados)
    "accent_border":    "#CBD5E1",   # Borde neutro corporativo
    "navy":             "#111827",   # Carbón corporativo
    "focus_blue":       "#C8102E",   # Foco corporativo

    # Texto
    "text_primary":     "#111827",   # Texto primario
    "text_secondary":   "#6B7280",   # Texto secundario
    "text_muted":       "#9CA3AF",   # Placeholders / hints
    "text_disabled":    "#CBD5E1",
    "text_on_red":      "#FFFFFF",

    # Bordes
    "border_default":   "#E5E7EB",   # Borde fino 1px
    "border_strong":    "#CBD5E1",   # Borde marcado
    "border_focus":     "#C8102E",   # Foco en rojo corporativo

    # Estados semánticos discretos (punto 6px + contenedor neutro)
    "success":          "#16A34A",
    "success_bg":       "#F8FAFC",
    "warning":          "#D97706",
    "warning_bg":       "#F8FAFC",
    "error":            "#C8102E",
    "error_bg":         "#FFFFFF",
    "info":             "#111827",
    "info_bg":          "#F8FAFC",

    # Badges de estado OS corporativos
    "estado_proceso":       "#111827",
    "estado_proceso_bg":    "#F8FAFC",
    "estado_cancelada":     "#C8102E",
    "estado_cancelada_bg":  "#FFFFFF",
    "estado_escaneada":     "#111827",
    "estado_escaneada_bg":  "#F8FAFC",
    "estado_fisico":        "#111827",
    "estado_fisico_bg":     "#F8FAFC",
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
    background-color: #FFFFFF;
    color: #0F172A;
    font-family: 'Segoe UI', 'Inter', -apple-system, 'Helvetica Neue', sans-serif;
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
    border: 1px solid #E2E8F0;
    border-radius: 7px;
    padding: 7px 12px;
    selection-background-color: #FFE4E6;
    selection-color: #0F172A;
    font-size: 13px;
}
QLineEdit:hover, QTextEdit:hover, QPlainTextEdit:hover {
    border-color: #CBD5E1;
}
QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus {
    border: 1.5px solid #C8102E;
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
    border: 1px solid #D1D5DB;
    border-radius: 8px;
    padding: 6px 12px;
    color: #111827;
    font-size: 13px;
    min-height: 32px;
}
QComboBox:hover {
    border-color: #9CA3AF;
}
QComboBox:focus {
    border: 1.5px solid #C8102E;
}
QComboBox::drop-down {
    border: none;
    subcontrol-origin: padding;
    subcontrol-position: top right;
    width: 25px;
}
QComboBox QAbstractItemView {
    background-color: #FFFFFF;
    border: 1px solid #E5E7EB;
    border-radius: 8px;
    selection-background-color: #F8FAFC;
    selection-color: #111827;
    color: #111827;
    outline: none;
    padding: 4px;
}
QComboBox QAbstractItemView::item {
    min-height: 32px;
    padding-left: 8px;
    color: #111827;
    background-color: #FFFFFF;
}
QComboBox QAbstractItemView::item:selected {
    background-color: #F8FAFC;
    color: #111827;
}
QComboBox QAbstractItemView::item:hover {
    background-color: #F8FAFC;
    color: #111827;
}
QComboBox QLineEdit {
    color: #111827;
    background: transparent;
    border: none;
    font-size: 13px;
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
    background-color: #F8FAFC;
}
QTreeWidget::item:selected {
    background-color: #F8FAFC;
    color: #111827;
}

/* Cabecera de la tabla — Enterprise header */
QHeaderView::section {
    background-color: #F9FAFB;
    color: #6B7280;
    font-weight: 700;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    border: none;
    border-bottom: 1px solid #E5E7EB;
    border-right: none;
    padding: 8px 10px;
}
QHeaderView::section:first { border-radius: 8px 0 0 0; }
QHeaderView::section:last  { border-right: none; border-radius: 0 8px 0 0; }
QHeaderView::section:hover { background-color: #F3F4F6; color: #111827; }
QHeaderView { background: transparent; border: none; }

/* ─── QTableWidget ────────────────────────────────────────────────────────── */
QTableWidget, QTableView {
    background-color: #FFFFFF;
    color: #111827;
    gridline-color: #F3F4F6;
    border: 1px solid #E5E7EB;
    border-radius: 12px;
    outline: none;
    alternate-background-color: #FFFFFF;
}
QTableWidget::item, QTableView::item {
    color: #111827;
    padding: 6px 10px;
    border: none;
}
QTableWidget::item:hover, QTableView::item:hover { background-color: #F8FAFC; }
QTableWidget::item:selected, QTableView::item:selected {
    background-color: #F8FAFC;
    color: #111827;
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
    """Retorna el estilo CSS inline monocromático corporativo Básculas PESA."""
    est = estado.upper()
    base = (
        "border-radius: 4px; padding: 2px 7px; "
        "font-size: 11px; font-weight: 600; "
    )
    if est in ("PROCESO", "PENDING", "PENDIENTE"):
        return base + "background-color: #F8FAFC; color: #334155; border: 1px solid #94A3B8;"
    if est == "CANCELADA":
        return base + "background-color: #FFFFFF; color: #C8102E; border: 1px solid #C8102E;"
    return base + "background-color: #F8FAFC; color: #0F172A; border: 1px solid #CBD5E1;"

