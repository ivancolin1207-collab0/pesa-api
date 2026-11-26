"""
theme.py — Sistema de diseño QSS Global v4.0
Servicios PESA — Apple Minimalist Industrial Enterprise UI (macOS Sequoia)

Paleta corporativa oficial:
  - Canvas:       #F5F5F7 (Apple System Gray 6)
  - Superficies:  #FFFFFF (Tarjetas, tablas, inputs)
  - Neutro/Hover: #F2F2F7
  - Bordes:       #E5E5EA (tarjetas/divisores) | #D2D2D7 (inputs/botones)
  - Texto:        #1D1D1F (primario) | #6E6E73 (secundario) | #8E8E93 (terciario)
  - Acento único: #C8102E (Rojo Básculas PESA)

Reglas herméticas QSS:
  - QLabel { border: none; background-color: transparent; } absoluto.
  - Cero directivas !important (inválidas en Qt).
  - Cero fondos rosados (rosados pastel) ni colores pastel "IA".
  - Iconos SVG vectoriales nítidos resueltos por ruta absoluta para QComboBox, QSpinBox y QCheckBox.
"""
from __future__ import annotations

import sys
from pathlib import Path


def _icons_dir() -> Path:
    """Resuelve la carpeta de iconos SVG tanto en desarrollo como en PyInstaller (_internal)."""
    candidates = [
        Path(__file__).resolve().parent.parent / "assets" / "icons",
        Path(getattr(sys, "_MEIPASS", "")) / "ui" / "assets" / "icons",
    ]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


def _svg_url(filename: str) -> str:
    p = _icons_dir() / filename
    return p.as_posix()


_CHEVRON_DOWN_SVG = _svg_url("chevron_down.svg")
_ARROW_UP_SVG = _svg_url("arrow_up.svg")
_ARROW_DOWN_SVG = _svg_url("arrow_down.svg")
_CHECK_WHITE_SVG = _svg_url("check_white.svg")


# ──────────────────────────────────────────────────────────────────────────────
# PALETA DE COLORES — Apple Minimalist Industrial Enterprise v4.0
# ──────────────────────────────────────────────────────────────────────────────
COLORS: dict[str, str] = {
    # Fondos Apple Minimalist
    "bg_primary":       "#F5F5F7",   # Canvas Apple System Gray 6
    "bg_surface":       "#F2F2F7",   # Superficies secundarias / badges neutros
    "bg_card":          "#FFFFFF",   # Tarjetas / paneles / tablas
    "bg_input":         "#FFFFFF",   # Campos de entrada

    # Acentos corporativos
    "accent_primary":   "#C8102E",   # Rojo Corporativo Básculas PESA
    "accent_hover":     "#A60D26",   # Rojo hover
    "accent_pressed":   "#880B20",   # Rojo pressed
    "accent_muted":     "#F2F2F7",   # Superficie neutra activa (cero fondos rosados)
    "accent_border":    "#D2D2D7",   # Borde neutro Apple
    "navy":             "#1D1D1F",   # Apple Anthracite
    "focus_blue":       "#C8102E",   # Foco corporativo

    # Texto
    "text_primary":     "#1D1D1F",   # Texto primario
    "text_secondary":   "#6E6E73",   # Texto secundario
    "text_muted":       "#8E8E93",   # Placeholders / hints
    "text_disabled":    "#D2D2D7",
    "text_on_red":      "#FFFFFF",

    # Bordes
    "border_default":   "#E5E5EA",   # Borde fino 1px
    "border_strong":    "#D2D2D7",   # Borde marcado inputs
    "border_focus":     "#C8102E",   # Foco en rojo corporativo

    # Estados semánticos discretos (punto 6px + contenedor neutro #F2F2F7)
    "success":          "#34C759",
    "success_bg":       "#F2F2F7",
    "warning":          "#FF9500",
    "warning_bg":       "#F2F2F7",
    "error":            "#C8102E",
    "error_bg":         "#FFFFFF",
    "info":             "#1D1D1F",
    "info_bg":          "#F2F2F7",

    # Badges de estado OS corporativos
    "estado_proceso":       "#1D1D1F",
    "estado_proceso_bg":    "#F2F2F7",
    "estado_cancelada":     "#6E6E73",
    "estado_cancelada_bg":  "#F2F2F7",
    "estado_escaneada":     "#1D1D1F",
    "estado_escaneada_bg":  "#F2F2F7",
    "estado_fisico":        "#1D1D1F",
    "estado_fisico_bg":     "#F2F2F7",
}


# ──────────────────────────────────────────────────────────────────────────────
# HOJA DE ESTILOS QSS GLOBAL — Apple Minimalist Industrial v4.0
# ──────────────────────────────────────────────────────────────────────────────
STYLESHEET = f"""
/* ═══════════════════════════════════════════════════════════════════════════
   SERVICIOS PESA — QSS Global Apple Minimalist Industrial v4.0
   ═══════════════════════════════════════════════════════════════════════════ */

/* ─── Raíz ──────────────────────────────────────────────────────────────── */
QMainWindow, QDialog {{
    background-color: #F5F5F7;
    color: #1D1D1F;
    font-family: 'Segoe UI Variable', 'Segoe UI', 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 13px;
}}

/* Regla hermética absoluta: nunca heredar bordes ni fondos hacia QLabel */
QLabel {{
    border: none;
    background-color: transparent;
    color: #1D1D1F;
}}

/* Tarjetas declaradas por propiedad dinámica */
QFrame[card="true"] {{
    background-color: #FFFFFF;
    border: 1px solid #E5E5EA;
    border-radius: 14px;
}}

/* ─── Contenedores de Scroll ─────────────────────────────────────────────── */
QScrollArea {{
    border: none;
    background-color: transparent;
}}
QScrollArea > QWidget > QWidget {{
    background-color: transparent;
}}

/* ─── Barras de desplazamiento (Apple slim) ──────────────────────────────── */
QScrollBar:vertical {{
    background: transparent;
    width: 7px;
    margin: 2px 0;
}}
QScrollBar::handle:vertical {{
    background: #D2D2D7;
    border-radius: 3px;
    min-height: 28px;
}}
QScrollBar::handle:vertical:hover   {{ background: #8E8E93; }}
QScrollBar::handle:vertical:pressed {{ background: #6E6E73; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical,
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{
    background: none; border: none; height: 0px;
}}
QScrollBar:horizontal {{
    background: transparent;
    height: 7px;
    margin: 0 2px;
}}
QScrollBar::handle:horizontal {{
    background: #D2D2D7;
    border-radius: 3px;
    min-width: 28px;
}}
QScrollBar::handle:horizontal:hover   {{ background: #8E8E93; }}
QScrollBar::handle:horizontal:pressed {{ background: #6E6E73; }}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal,
QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {{
    background: none; border: none; width: 0px;
}}

/* ─── Campos de entrada uniformes (38px, border-radius 10px) ─────────────── */
QLineEdit, QSpinBox, QDoubleSpinBox {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    border: 1px solid #D2D2D7;
    border-radius: 10px;
    padding: 0px 12px;
    min-height: 36px;
    max-height: 38px;
    selection-background-color: #E5E5EA;
    selection-color: #1D1D1F;
    font-size: 13px;
}}
QTextEdit, QPlainTextEdit {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    border: 1px solid #D2D2D7;
    border-radius: 10px;
    padding: 8px 12px;
    min-height: 76px;
    selection-background-color: #E5E5EA;
    selection-color: #1D1D1F;
    font-size: 13px;
}}
QLineEdit:hover, QTextEdit:hover, QPlainTextEdit:hover, QSpinBox:hover, QDoubleSpinBox:hover {{
    border-color: #8E8E93;
}}
QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus {{
    border: 1.5px solid #C8102E;
    background-color: #FFFFFF;
}}
QLineEdit:disabled, QTextEdit:disabled, QPlainTextEdit:disabled,
QSpinBox:disabled, QDoubleSpinBox:disabled {{
    background-color: #F5F5F7;
    color: #8E8E93;
    border-color: #E5E5EA;
}}
QSpinBox::up-button, QDoubleSpinBox::up-button {{
    subcontrol-origin: border;
    subcontrol-position: top right;
    width: 24px;
    border: none;
    border-left: 1px solid #E5E5EA;
    border-top-right-radius: 9px;
    background: transparent;
}}
QSpinBox::down-button, QDoubleSpinBox::down-button {{
    subcontrol-origin: border;
    subcontrol-position: bottom right;
    width: 24px;
    border: none;
    border-left: 1px solid #E5E5EA;
    border-top: 1px solid #E5E5EA;
    border-bottom-right-radius: 9px;
    background: transparent;
}}
QSpinBox::up-button:hover, QDoubleSpinBox::up-button:hover,
QSpinBox::down-button:hover, QDoubleSpinBox::down-button:hover {{
    background: #F2F2F7;
}}
QSpinBox::up-arrow, QDoubleSpinBox::up-arrow {{
    image: url("{_ARROW_UP_SVG}");
    width: 10px;
    height: 10px;
}}
QSpinBox::down-arrow, QDoubleSpinBox::down-arrow {{
    image: url("{_ARROW_DOWN_SVG}");
    width: 10px;
    height: 10px;
}}

/* ─── ComboBox con chevron SVG vectorial ─────────────────────────────────── */
QComboBox {{
    background-color: #FFFFFF;
    border: 1px solid #D2D2D7;
    border-radius: 10px;
    padding: 0px 30px 0px 12px;
    color: #1D1D1F;
    font-size: 13px;
    min-height: 36px;
    max-height: 38px;
}}
QComboBox:hover {{
    border-color: #8E8E93;
}}
QComboBox:focus {{
    border: 1.5px solid #C8102E;
}}
QComboBox:disabled {{
    background-color: #F5F5F7;
    color: #8E8E93;
    border-color: #E5E5EA;
}}
QComboBox::drop-down {{
    border: none;
    subcontrol-origin: padding;
    subcontrol-position: top right;
    width: 28px;
    background: transparent;
}}
QComboBox::down-arrow {{
    image: url("{_CHEVRON_DOWN_SVG}");
    width: 12px;
    height: 12px;
    border: none;
}}
QComboBox QAbstractItemView {{
    background-color: #FFFFFF;
    border: 1px solid #E5E5EA;
    border-radius: 10px;
    selection-background-color: #F2F2F7;
    selection-color: #1D1D1F;
    color: #1D1D1F;
    outline: none;
    padding: 4px;
}}
QComboBox QAbstractItemView::item {{
    min-height: 32px;
    padding: 4px 10px;
    border-radius: 6px;
    color: #1D1D1F;
    background-color: #FFFFFF;
}}
QComboBox QAbstractItemView::item:selected {{
    background-color: #F2F2F7;
    color: #1D1D1F;
}}
QComboBox QAbstractItemView::item:hover {{
    background-color: #F2F2F7;
    color: #1D1D1F;
}}
QComboBox QLineEdit {{
    color: #1D1D1F;
    background: transparent;
    border: none;
    padding: 0px 2px;
    margin: 0px;
    min-height: 0px;
    max-height: 36px;
    font-size: 13px;
}}

/* ─── DateEdit ────────────────────────────────────────────────────────────── */
QDateEdit {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    border: 1px solid #D2D2D7;
    border-radius: 10px;
    padding: 0px 12px;
    min-height: 36px;
    max-height: 38px;
}}
QDateEdit:hover {{ border-color: #8E8E93; }}
QDateEdit:focus {{ border: 1.5px solid #C8102E; }}
QDateEdit::drop-down {{
    border: none;
    width: 28px;
    border-left: 1px solid #E5E5EA;
    background: transparent;
}}
QDateEdit::down-arrow {{
    image: url("{_CHEVRON_DOWN_SVG}");
    width: 12px;
    height: 12px;
}}
QCalendarWidget {{ background: #FFFFFF; color: #1D1D1F; border: 1px solid #E5E5EA; }}
QCalendarWidget QToolButton {{
    background: #F2F2F7; color: #1D1D1F; border: none;
    padding: 4px 8px; border-radius: 6px;
}}
QCalendarWidget QToolButton:hover {{ background: #C8102E; color: #FFFFFF; }}
QCalendarWidget QAbstractItemView {{
    background: #FFFFFF;
    selection-background-color: #C8102E;
    selection-color: #FFFFFF;
}}

/* ─── Botones (Apple neutral base + variantes declarativas) ──────────────── */
QPushButton {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    border: 1px solid #D2D2D7;
    border-radius: 10px;
    padding: 6px 16px;
    font-weight: 600;
    font-size: 12.5px;
    min-height: 34px;
}}
QPushButton:hover {{
    background-color: #F2F2F7;
    border-color: #8E8E93;
}}
QPushButton:pressed {{
    background-color: #E5E5EA;
    border-color: #6E6E73;
}}
QPushButton:disabled {{
    background-color: #F5F5F7;
    color: #8E8E93;
    border-color: #E5E5EA;
}}
QPushButton::menu-indicator {{
    image: none;
    width: 0px;
}}

/* Botón Primario — Rojo PESA sólido */
QPushButton[class="primary"], QPushButton[variant="primary"] {{
    background-color: #C8102E;
    color: #FFFFFF;
    border: 1px solid #C8102E;
    font-weight: 600;
}}
QPushButton[class="primary"]:hover, QPushButton[variant="primary"]:hover {{
    background-color: #A60D26;
    border-color: #A60D26;
}}
QPushButton[class="primary"]:pressed, QPushButton[variant="primary"]:pressed {{
    background-color: #880B20;
    border-color: #880B20;
}}
QPushButton[class="primary"]:disabled, QPushButton[variant="primary"]:disabled {{
    background-color: #E5E5EA;
    color: #8E8E93;
    border-color: #E5E5EA;
}}

/* Botón Éxito */
QPushButton[class="success"], QPushButton[variant="success"] {{
    background-color: #1D1D1F;
    color: #FFFFFF;
    border: 1px solid #1D1D1F;
    font-weight: 600;
}}
QPushButton[class="success"]:hover, QPushButton[variant="success"]:hover {{
    background-color: #3A3A3C;
}}

/* Botón Peligro (outlined limpio sin fondo rosado) */
QPushButton[class="danger"], QPushButton[variant="danger"] {{
    background-color: #FFFFFF;
    color: #C8102E;
    border: 1px solid #C8102E;
    font-weight: 600;
}}
QPushButton[class="danger"]:hover, QPushButton[variant="danger"]:hover {{
    background-color: #F2F2F7;
    border-color: #A60D26;
    color: #A60D26;
}}

/* ─── Etiquetas semánticas ────────────────────────────────────────────────── */
QLabel[class="title"] {{
    font-size: 22px; font-weight: 700;
    color: #1D1D1F; letter-spacing: -0.4px;
}}
QLabel[class="section-header"] {{
    font-size: 11px; font-weight: 700;
    color: #6E6E73; text-transform: uppercase; letter-spacing: 0.7px;
}}
QLabel[class="folio"] {{
    font-size: 26px; font-weight: 800;
    color: #1D1D1F; letter-spacing: 0.5px;
}}
QLabel[class="muted"] {{
    color: #6E6E73; font-size: 12px;
}}
QLabel[class="error-max"] {{
    font-size: 14px; font-weight: 700; color: #C8102E;
}}

/* ─── TreeWidget / Tabla principal de OS ────────────────────────────────── */
QTreeWidget {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    border: 1px solid #E5E5EA;
    border-radius: 12px;
    outline: none;
    alternate-background-color: #FFFFFF;
    gridline-color: transparent;
    font-size: 12.5px;
}}
QTreeWidget::item {{
    color: #1D1D1F;
    padding: 0px 6px;
    min-height: 36px;
    border-bottom: 1px solid #F2F2F7;
}}
QTreeWidget::item:hover {{
    background-color: #F5F5F7;
}}
QTreeWidget::item:selected {{
    background-color: #F2F2F7;
    color: #1D1D1F;
}}

/* Cabecera de tabla Apple */
QHeaderView::section {{
    background-color: #FBFBFD;
    color: #6E6E73;
    font-weight: 700;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border: none;
    border-bottom: 1px solid #E5E5EA;
    border-right: none;
    padding: 8px 10px;
}}
QHeaderView::section:first {{ border-radius: 10px 0 0 0; }}
QHeaderView::section:last  {{ border-right: none; border-radius: 0 10px 0 0; }}
QHeaderView::section:hover {{ background-color: #F2F2F7; color: #1D1D1F; }}
QHeaderView {{ background: transparent; border: none; }}

/* ─── QTableWidget ────────────────────────────────────────────────────────── */
QTableWidget, QTableView {{
    background-color: #FFFFFF;
    color: #1D1D1F;
    gridline-color: #F2F2F7;
    border: 1px solid #E5E5EA;
    border-radius: 12px;
    outline: none;
    alternate-background-color: #FFFFFF;
}}
QTableWidget::item, QTableView::item {{
    color: #1D1D1F;
    padding: 6px 10px;
    border: none;
}}
QTableWidget::item:hover, QTableView::item:hover {{ background-color: #F5F5F7; }}
QTableWidget::item:selected, QTableView::item:selected {{
    background-color: #F2F2F7;
    color: #1D1D1F;
}}
QTableWidget QLineEdit {{
    color: #1D1D1F;
    background-color: #FFFFFF;
    border: 1.5px solid #C8102E;
    border-radius: 6px;
    font-weight: 600;
}}
QTableWidget QTableCornerButton::section {{ background: #FBFBFD; border: none; }}

/* ─── GroupBox ────────────────────────────────────────────────────────────── */
QGroupBox {{
    border: 1px solid #E5E5EA;
    border-radius: 12px;
    margin-top: 22px;
    padding: 20px 14px 14px 14px;
    background-color: #FFFFFF;
}}
QGroupBox::title {{
    background-color: #F2F2F7;
    color: #6E6E73;
    font-weight: 700;
    font-size: 10.5px;
    text-transform: uppercase;
    letter-spacing: 0.6px;
    padding: 4px 10px;
    border-radius: 6px;
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 12px;
    top: 0px;
}}

/* ─── Tabs ────────────────────────────────────────────────────────────────── */
QTabWidget::pane {{
    border: 1px solid #E5E5EA;
    border-radius: 0 12px 12px 12px;
    background: #FFFFFF;
    top: -1px;
}}
QTabBar::tab {{
    background: #F2F2F7;
    color: #6E6E73;
    border: 1px solid #E5E5EA;
    border-bottom: none;
    border-radius: 8px 8px 0 0;
    padding: 9px 18px;
    font-weight: 600;
    font-size: 12.5px;
    margin-right: 3px;
}}
QTabBar::tab:selected {{
    color: #1D1D1F;
    background: #FFFFFF;
    border-color: #E5E5EA;
    border-bottom-color: #FFFFFF;
}}
QTabBar::tab:hover:!selected {{ color: #1D1D1F; background: #E5E5EA; }}

/* ─── Frame / Separadores ─────────────────────────────────────────────────── */
QFrame[frameShape="4"], QFrame[frameShape="5"] {{
    color: #E5E5EA; border: none; background: #E5E5EA;
}}

/* ─── CheckBox con icono check SVG nítido ─────────────────────────────────── */
QCheckBox {{ color: #1D1D1F; spacing: 8px; background: transparent; border: none; }}
QCheckBox::indicator {{
    width: 17px; height: 17px;
    border: 1.5px solid #D2D2D7;
    border-radius: 5px;
    background: #FFFFFF;
}}
QCheckBox::indicator:checked {{
    background: #C8102E;
    border-color: #C8102E;
    image: url("{_CHECK_WHITE_SVG}");
}}
QCheckBox::indicator:hover {{ border-color: #8E8E93; }}

/* ─── RadioButton ─────────────────────────────────────────────────────────── */
QRadioButton {{ color: #1D1D1F; spacing: 8px; background: transparent; border: none; }}
QRadioButton::indicator {{
    width: 17px; height: 17px;
    border: 1.5px solid #D2D2D7;
    border-radius: 9px;
    background: #FFFFFF;
}}
QRadioButton::indicator:checked {{ background: #C8102E; border-color: #C8102E; }}
QRadioButton::indicator:hover   {{ border-color: #8E8E93; }}

/* ─── Barra de estado ─────────────────────────────────────────────────────── */
QStatusBar {{
    background: #F5F5F7;
    color: #6E6E73;
    border-top: 1px solid #E5E5EA;
    font-size: 11px;
    padding: 2px 10px;
}}
QStatusBar::item {{ border: none; }}

/* ─── MessageBox ──────────────────────────────────────────────────────────── */
QMessageBox {{ background: #FFFFFF; }}
QMessageBox QLabel {{ color: #1D1D1F; border: none; background: transparent; }}
QMessageBox QPushButton {{ min-width: 92px; }}

/* ─── Tooltip ─────────────────────────────────────────────────────────────── */
QToolTip {{
    background: #1D1D1F;
    color: #FFFFFF;
    border: none;
    border-radius: 8px;
    padding: 6px 10px;
    font-size: 11.5px;
}}

/* ─── Splitter ────────────────────────────────────────────────────────────── */
QSplitter::handle:vertical   {{ background: #E5E5EA; height: 1px; }}
QSplitter::handle:horizontal {{ background: #E5E5EA; width: 1px; }}

/* ─── Barra de herramientas ───────────────────────────────────────────────── */
QToolBar {{
    background: #FFFFFF;
    border-bottom: 1px solid #E5E5EA;
    spacing: 4px;
    padding: 4px;
}}
QToolBar QToolButton {{
    background: transparent;
    color: #6E6E73;
    border: none;
    border-radius: 8px;
    padding: 6px 10px;
}}
QToolBar QToolButton:hover {{ background: #F2F2F7; color: #1D1D1F; }}
"""


def get_badge_style(estado: str) -> str:
    """Retorna el estilo CSS inline monocromático corporativo Apple PESA."""
    est = str(estado or "").upper()
    base = (
        "border-radius: 6px; padding: 2px 8px; "
        "font-size: 11px; font-weight: 600; "
    )
    if est in ("PROCESO", "PENDING", "PENDIENTE"):
        return base + "background-color: #F2F2F7; color: #1D1D1F; border: 1px solid #D2D2D7;"
    if est in ("CANCELADA", "CANCELADO"):
        return base + "background-color: #F2F2F7; color: #6E6E73; border: 1px solid #E5E5EA;"
    return base + "background-color: #F2F2F7; color: #1D1D1F; border: 1px solid #E5E5EA;"
