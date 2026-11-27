"""
ui/styles/theme.py — Sistema de diseño QSS Dual (Claro / Oscuro) v4.1
Servicios PESA — Apple Minimalist Industrial Enterprise UI (macOS Sequoia)

Paleta Light:
  - Canvas:       #F5F5F7 | Superficies: #FFFFFF | Neutro/Hover: #F2F2F7
  - Bordes:       #E5E5EA / #D2D2D7 | Texto: #1D1D1F / #6E6E73 / #8E8E93
  - Acento:       #C8102E (hover #A60D26, pressed #880B20)

Paleta Dark (Apple Dark — Básculas PESA):
  - Canvas:       #121214
  - Superficie:   #1C1C1E (tarjetas, tablas, sidebar)
  - Elevado:      #2C2C2E (inputs, encabezados de tabla, badges neutros)
  - Hover:        #323236 (hover de filas / botones secundarios)
  - Bordes:       #38383A
  - Texto:        #F5F5F7 (primario) | #98989D (secundario) | #636366 (placeholder)
  - Acento botón: #C8102E (hover #A60D26) con texto #FFFFFF
  - Acento sobre oscuro (texto/borde/ícono activo): #F03E55
  - Puntos semánticos 6px: #30D158 (verde) | #FF9F0A (ámbar) | #FF453A (rojo)
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


LIGHT_COLORS: dict[str, str] = {
    "bg_primary":          "#F5F5F7",
    "bg_surface":          "#F2F2F7",
    "bg_card":             "#FFFFFF",
    "bg_input":            "#FFFFFF",
    "bg_elevated":         "#F2F2F7",
    "bg_hover":            "#F2F2F7",
    "table_header":        "#FBFBFD",

    "accent_primary":      "#C8102E",
    "accent_hover":        "#A60D26",
    "accent_pressed":      "#880B20",
    "accent_active":       "#C8102E",
    "accent_muted":        "#F2F2F7",
    "accent_border":       "#D2D2D7",
    "navy":                "#1D1D1F",
    "focus_blue":          "#C8102E",

    "text_primary":        "#1D1D1F",
    "text_secondary":      "#6E6E73",
    "text_muted":          "#8E8E93",
    "text_disabled":       "#8E8E93",
    "text_on_red":         "#FFFFFF",

    "border_default":      "#E5E5EA",
    "border_strong":       "#D2D2D7",
    "border_focus":        "#C8102E",
    "divider":             "#F2F2F7",

    "success":             "#34C759",
    "success_bg":          "#F2F2F7",
    "warning":             "#FF9500",
    "warning_bg":          "#F2F2F7",
    "error":               "#C8102E",
    "error_bg":            "#FFFFFF",
    "info":                "#1D1D1F",
    "info_bg":             "#F2F2F7",

    "estado_proceso":      "#1D1D1F",
    "estado_proceso_bg":   "#F2F2F7",
    "estado_cancelada":    "#6E6E73",
    "estado_cancelada_bg": "#F2F2F7",
    "estado_escaneada":    "#1D1D1F",
    "estado_escaneada_bg": "#F2F2F7",
    "estado_fisico":       "#1D1D1F",
    "estado_fisico_bg":    "#F2F2F7",
}

DARK_COLORS: dict[str, str] = {
    "bg_primary":          "#121214",
    "bg_surface":          "#2C2C2E",
    "bg_card":             "#1C1C1E",
    "bg_input":            "#2C2C2E",
    "bg_elevated":         "#2C2C2E",
    "bg_hover":            "#323236",
    "table_header":        "#2C2C2E",

    "accent_primary":      "#C8102E",
    "accent_hover":        "#A60D26",
    "accent_pressed":      "#880B20",
    "accent_active":       "#F03E55",
    "accent_muted":        "#2C2C2E",
    "accent_border":       "#38383A",
    "navy":                "#F5F5F7",
    "focus_blue":          "#F03E55",

    "text_primary":        "#F5F5F7",
    "text_secondary":      "#98989D",
    "text_muted":          "#636366",
    "text_disabled":       "#636366",
    "text_on_red":         "#FFFFFF",

    "border_default":      "#38383A",
    "border_strong":       "#38383A",
    "border_focus":        "#F03E55",
    "divider":             "#38383A",

    "success":             "#30D158",
    "success_bg":          "#2C2C2E",
    "warning":             "#FF9F0A",
    "warning_bg":          "#2C2C2E",
    "error":               "#FF453A",
    "error_bg":            "#1C1C1E",
    "info":                "#F5F5F7",
    "info_bg":             "#2C2C2E",

    "estado_proceso":      "#F5F5F7",
    "estado_proceso_bg":   "#2C2C2E",
    "estado_cancelada":    "#98989D",
    "estado_cancelada_bg": "#2C2C2E",
    "estado_escaneada":    "#F5F5F7",
    "estado_escaneada_bg": "#2C2C2E",
    "estado_fisico":       "#F5F5F7",
    "estado_fisico_bg":    "#2C2C2E",
}

# Diccionario mutable en vivo (actualizado por theme_manager al cambiar de modo)
COLORS: dict[str, str] = dict(LIGHT_COLORS)


def resolve_mode(modo: str) -> str:
    """Resuelve 'light' | 'dark' | 'system' al modo efectivo ('light' o 'dark')."""
    m = str(modo or "system").strip().lower()
    if m in ("dark", "oscuro"):
        return "dark"
    if m in ("light", "claro"):
        return "light"
    # Detectar tema del sistema
    try:
        from PyQt6.QtWidgets import QApplication
        from PyQt6.QtCore import Qt
        app = QApplication.instance()
        if app is not None:
            sh = app.styleHints()
            if hasattr(sh, "colorScheme") and hasattr(Qt, "ColorScheme"):
                cs = sh.colorScheme()
                if cs == Qt.ColorScheme.Dark:
                    return "dark"
                if cs == Qt.ColorScheme.Light:
                    return "light"
    except Exception:
        pass
    # Respaldo directo al Registro de Windows
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            ) as key:
                val, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
                return "dark" if int(val) == 0 else "light"
        except Exception:
            pass
    return "light"


def generate_stylesheet(modo: str = "light") -> str:
    """Genera la hoja QSS hermética Apple Minimalist para modo 'light', 'dark' o 'system'."""
    effective = resolve_mode(modo)
    is_dark = (effective == "dark")
    c = DARK_COLORS if is_dark else LIGHT_COLORS

    chevron_svg = _svg_url("chevron_down_dark.svg" if is_dark else "chevron_down.svg")
    arrow_up_svg = _svg_url("arrow_up_dark.svg" if is_dark else "arrow_up.svg")
    arrow_down_svg = _svg_url("arrow_down_dark.svg" if is_dark else "arrow_down.svg")
    check_white_svg = _svg_url("check_white.svg")

    canvas = c["bg_primary"]
    surface = c["bg_card"]
    elevated = c["bg_elevated"]
    hover = c["bg_hover"]
    pressed = "#3A3A3E" if is_dark else "#E5E5EA"
    border = c["border_default"]
    border_strong = c["border_strong"]
    border_hover = "#636366" if is_dark else "#8E8E93"
    divider = c["divider"]
    text_primary = c["text_primary"]
    text_secondary = c["text_secondary"]
    text_muted = c["text_muted"]
    brand = c["accent_primary"]
    brand_hover = c["accent_hover"]
    brand_pressed = c["accent_pressed"]
    brand_active = c["accent_active"]
    table_hdr = c["table_header"]
    scroll_handle = "#48484A" if is_dark else "#D2D2D7"
    scroll_hover = "#636366" if is_dark else "#8E8E93"
    disabled_bg = "#1C1C1E" if is_dark else "#F5F5F7"
    success_btn_bg = "#2C2C2E" if is_dark else "#1D1D1F"
    success_btn_hover = "#323236" if is_dark else "#3A3A3C"
    tooltip_bg = "#2C2C2E" if is_dark else "#1D1D1F"
    tooltip_border = "1px solid #38383A" if is_dark else "none"

    return f"""
/* ═══════════════════════════════════════════════════════════════════════════
   SERVICIOS PESA — QSS Global Apple Minimalist Industrial v4.1 ({effective.upper()})
   ═══════════════════════════════════════════════════════════════════════════ */

QMainWindow, QDialog {{
    background-color: {canvas};
    color: {text_primary};
    font-family: 'Segoe UI Variable', 'Segoe UI', 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    font-size: 13px;
}}

/* Regla hermética absoluta: nunca heredar bordes ni fondos hacia QLabel */
QLabel {{
    border: none;
    background-color: transparent;
    color: {text_primary};
}}

/* Tarjetas declaradas por propiedad dinámica o SectionCard */
QFrame[card="true"], QFrame#section_card {{
    background-color: {surface};
    border: 1px solid {border};
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
    background: {scroll_handle};
    border-radius: 3px;
    min-height: 28px;
}}
QScrollBar::handle:vertical:hover   {{ background: {scroll_hover}; }}
QScrollBar::handle:vertical:pressed {{ background: {text_secondary}; }}
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
    background: {scroll_handle};
    border-radius: 3px;
    min-width: 28px;
}}
QScrollBar::handle:horizontal:hover   {{ background: {scroll_hover}; }}
QScrollBar::handle:horizontal:pressed {{ background: {text_secondary}; }}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal,
QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {{
    background: none; border: none; width: 0px;
}}

/* ─── Campos de entrada uniformes (38px, border-radius 10px) ─────────────── */
QLineEdit, QSpinBox, QDoubleSpinBox {{
    background-color: {c["bg_input"]};
    color: {text_primary};
    border: 1px solid {border_strong};
    border-radius: 10px;
    padding: 0px 12px;
    min-height: 36px;
    max-height: 38px;
    selection-background-color: {brand};
    selection-color: #FFFFFF;
    font-size: 13px;
}}
QTextEdit, QPlainTextEdit {{
    background-color: {c["bg_input"]};
    color: {text_primary};
    border: 1px solid {border_strong};
    border-radius: 10px;
    padding: 8px 12px;
    min-height: 76px;
    selection-background-color: {brand};
    selection-color: #FFFFFF;
    font-size: 13px;
}}
QLineEdit:hover, QTextEdit:hover, QPlainTextEdit:hover, QSpinBox:hover, QDoubleSpinBox:hover {{
    border-color: {border_hover};
}}
QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus {{
    border: 1.5px solid {brand_active};
    background-color: {c["bg_input"]};
}}
QLineEdit:disabled, QTextEdit:disabled, QPlainTextEdit:disabled,
QSpinBox:disabled, QDoubleSpinBox:disabled {{
    background-color: {disabled_bg};
    color: {text_muted};
    border-color: {border};
}}
QSpinBox::up-button, QDoubleSpinBox::up-button {{
    subcontrol-origin: border;
    subcontrol-position: top right;
    width: 24px;
    border: none;
    border-left: 1px solid {border};
    border-top-right-radius: 9px;
    background: transparent;
}}
QSpinBox::down-button, QDoubleSpinBox::down-button {{
    subcontrol-origin: border;
    subcontrol-position: bottom right;
    width: 24px;
    border: none;
    border-left: 1px solid {border};
    border-top: 1px solid {border};
    border-bottom-right-radius: 9px;
    background: transparent;
}}
QSpinBox::up-button:hover, QDoubleSpinBox::up-button:hover,
QSpinBox::down-button:hover, QDoubleSpinBox::down-button:hover {{
    background: {hover};
}}
QSpinBox::up-arrow, QDoubleSpinBox::up-arrow {{
    image: url("{arrow_up_svg}");
    width: 10px;
    height: 10px;
}}
QSpinBox::down-arrow, QDoubleSpinBox::down-arrow {{
    image: url("{arrow_down_svg}");
    width: 10px;
    height: 10px;
}}

/* ─── ComboBox con chevron SVG vectorial adaptado al tema ────────────────── */
QComboBox {{
    background-color: {c["bg_input"]};
    border: 1px solid {border_strong};
    border-radius: 10px;
    padding: 0px 30px 0px 12px;
    color: {text_primary};
    font-size: 13px;
    min-height: 36px;
    max-height: 38px;
}}
QComboBox:hover {{
    border-color: {border_hover};
}}
QComboBox:focus {{
    border: 1.5px solid {brand_active};
}}
QComboBox:disabled {{
    background-color: {disabled_bg};
    color: {text_muted};
    border-color: {border};
}}
QComboBox::drop-down {{
    border: none;
    subcontrol-origin: padding;
    subcontrol-position: top right;
    width: 28px;
    background: transparent;
}}
QComboBox::down-arrow {{
    image: url("{chevron_svg}");
    width: 12px;
    height: 12px;
    border: none;
}}
QComboBox QAbstractItemView {{
    background-color: {surface};
    border: 1px solid {border};
    border-radius: 10px;
    selection-background-color: {hover};
    selection-color: {text_primary};
    color: {text_primary};
    outline: none;
    padding: 4px;
}}
QComboBox QAbstractItemView::item {{
    min-height: 32px;
    padding: 4px 10px;
    border-radius: 6px;
    color: {text_primary};
    background-color: {surface};
}}
QComboBox QAbstractItemView::item:selected {{
    background-color: {hover};
    color: {text_primary};
}}
QComboBox QAbstractItemView::item:hover {{
    background-color: {hover};
    color: {text_primary};
}}
QComboBox QLineEdit {{
    color: {text_primary};
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
    background-color: {c["bg_input"]};
    color: {text_primary};
    border: 1px solid {border_strong};
    border-radius: 10px;
    padding: 0px 12px;
    min-height: 36px;
    max-height: 38px;
}}
QDateEdit:hover {{ border-color: {border_hover}; }}
QDateEdit:focus {{ border: 1.5px solid {brand_active}; }}
QDateEdit::drop-down {{
    border: none;
    width: 28px;
    border-left: 1px solid {border};
    background: transparent;
}}
QDateEdit::down-arrow {{
    image: url("{chevron_svg}");
    width: 12px;
    height: 12px;
}}
QCalendarWidget {{ background: {surface}; color: {text_primary}; border: 1px solid {border}; }}
QCalendarWidget QWidget {{ alternate-background-color: {elevated}; color: {text_primary}; }}
QCalendarWidget QToolButton {{
    background: {elevated}; color: {text_primary}; border: none;
    padding: 4px 8px; border-radius: 6px;
}}
QCalendarWidget QToolButton:hover {{ background: {brand}; color: #FFFFFF; }}
QCalendarWidget QAbstractItemView {{
    background: {surface};
    color: {text_primary};
    selection-background-color: {brand};
    selection-color: #FFFFFF;
}}

/* ─── Botones (Apple neutral base + variantes declarativas) ──────────────── */
QPushButton {{
    background-color: {elevated if is_dark else surface};
    color: {text_primary};
    border: 1px solid {border_strong};
    border-radius: 10px;
    padding: 6px 16px;
    font-weight: 600;
    font-size: 12.5px;
    min-height: 34px;
}}
QPushButton:hover {{
    background-color: {hover};
    border-color: {border_hover};
}}
QPushButton:pressed {{
    background-color: {pressed};
    border-color: {text_secondary};
}}
QPushButton:disabled {{
    background-color: {disabled_bg};
    color: {text_muted};
    border-color: {border};
}}
QPushButton::menu-indicator {{
    image: none;
    width: 0px;
}}

/* Botón Primario — Rojo PESA sólido */
QPushButton[class="primary"], QPushButton[variant="primary"] {{
    background-color: {brand};
    color: #FFFFFF;
    border: 1px solid {brand};
    font-weight: 600;
}}
QPushButton[class="primary"]:hover, QPushButton[variant="primary"]:hover {{
    background-color: {brand_hover};
    border-color: {brand_hover};
}}
QPushButton[class="primary"]:pressed, QPushButton[variant="primary"]:pressed {{
    background-color: {brand_pressed};
    border-color: {brand_pressed};
}}
QPushButton[class="primary"]:disabled, QPushButton[variant="primary"]:disabled {{
    background-color: {elevated};
    color: {text_muted};
    border-color: {border};
}}

/* Botón Overflow tabla ('⋯') */
QPushButton[variant="overflow"] {{
    background-color: {elevated if is_dark else surface};
    color: {text_secondary};
    border: 1px solid {border_strong};
    border-radius: 8px;
    font-size: 14px;
    font-weight: 700;
    padding: 0px;
    min-height: 28px;
}}
QPushButton[variant="overflow"]:hover {{
    background-color: {hover};
    color: {text_primary};
    border-color: {border_hover};
}}

/* Botón Éxito */
QPushButton[class="success"], QPushButton[variant="success"] {{
    background-color: {success_btn_bg};
    color: #FFFFFF;
    border: 1px solid {border_strong if is_dark else success_btn_bg};
    font-weight: 600;
}}
QPushButton[class="success"]:hover, QPushButton[variant="success"]:hover {{
    background-color: {success_btn_hover};
}}

/* Botón Peligro (outlined limpio) */
QPushButton[class="danger"], QPushButton[variant="danger"] {{
    background-color: {surface};
    color: {brand_active};
    border: 1px solid {brand_active};
    font-weight: 600;
}}
QPushButton[class="danger"]:hover, QPushButton[variant="danger"]:hover {{
    background-color: {hover};
    border-color: {brand_active};
    color: {brand_active};
}}

/* ─── QMenu ──────────────────────────────────────────────────────────────── */
QMenu {{
    background-color: {surface};
    border: 1px solid {border};
    border-radius: 10px;
    padding: 4px;
    font-size: 12.5px;
}}
QMenu::item {{
    padding: 7px 14px;
    border-radius: 8px;
    color: {text_primary};
}}
QMenu::item:selected {{
    background-color: {hover};
    color: {text_primary};
}}
QMenu::item:disabled {{
    color: {text_muted};
}}
QMenu::separator {{
    height: 1px;
    background-color: {divider};
    margin: 4px 8px;
}}

/* ─── Etiquetas semánticas ────────────────────────────────────────────────── */
QLabel[class="title"] {{
    font-size: 22px; font-weight: 700;
    color: {text_primary}; letter-spacing: -0.4px;
}}
QLabel[class="section-header"] {{
    font-size: 11px; font-weight: 700;
    color: {text_secondary}; text-transform: uppercase; letter-spacing: 0.7px;
}}
QLabel[class="folio"] {{
    font-size: 26px; font-weight: 800;
    color: {text_primary}; letter-spacing: 0.5px;
}}
QLabel[class="muted"] {{
    color: {text_secondary}; font-size: 12px;
}}
QLabel[class="error-max"] {{
    font-size: 14px; font-weight: 700; color: {brand_active};
}}

/* ─── TreeWidget / Tabla principal de OS ────────────────────────────────── */
QTreeWidget {{
    background-color: {surface};
    color: {text_primary};
    border: 1px solid {border};
    border-radius: 12px;
    outline: none;
    alternate-background-color: {surface};
    gridline-color: transparent;
    font-size: 12.5px;
}}
QTreeWidget::item {{
    color: {text_primary};
    padding: 0px 6px;
    min-height: 36px;
    border-bottom: 1px solid {divider};
}}
QTreeWidget::item:hover {{
    background-color: {hover};
}}
QTreeWidget::item:selected {{
    background-color: {hover};
    color: {text_primary};
}}

/* Cabecera de tabla Apple */
QHeaderView::section {{
    background-color: {table_hdr};
    color: {text_secondary};
    font-weight: 700;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border: none;
    border-bottom: 1px solid {border};
    border-right: none;
    padding: 8px 10px;
}}
QHeaderView::section:first {{ border-radius: 10px 0 0 0; }}
QHeaderView::section:last  {{ border-right: none; border-radius: 0 10px 0 0; }}
QHeaderView::section:hover {{ background-color: {hover}; color: {text_primary}; }}
QHeaderView {{ background: transparent; border: none; }}

/* ─── QTableWidget ────────────────────────────────────────────────────────── */
QTableWidget, QTableView {{
    background-color: {surface};
    color: {text_primary};
    gridline-color: {divider};
    border: 1px solid {border};
    border-radius: 12px;
    outline: none;
    alternate-background-color: {surface};
}}
QTableWidget::item, QTableView::item {{
    color: {text_primary};
    padding: 6px 10px;
    border: none;
}}
QTableWidget::item:hover, QTableView::item:hover {{ background-color: {hover}; }}
QTableWidget::item:selected, QTableView::item:selected {{
    background-color: {hover};
    color: {text_primary};
}}
QTableWidget QLineEdit {{
    color: {text_primary};
    background-color: {c["bg_input"]};
    border: 1.5px solid {brand_active};
    border-radius: 6px;
    font-weight: 600;
}}
QTableWidget QTableCornerButton::section {{ background: {table_hdr}; border: none; }}

/* ─── GroupBox ────────────────────────────────────────────────────────────── */
QGroupBox {{
    border: 1px solid {border};
    border-radius: 12px;
    margin-top: 22px;
    padding: 20px 14px 14px 14px;
    background-color: {surface};
    color: {text_primary};
}}
QGroupBox::title {{
    background-color: {elevated};
    color: {text_secondary};
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
    border: 1px solid {border};
    border-radius: 0 12px 12px 12px;
    background: {surface};
    top: -1px;
}}
QTabBar::tab {{
    background: {elevated};
    color: {text_secondary};
    border: 1px solid {border};
    border-bottom: none;
    border-radius: 8px 8px 0 0;
    padding: 9px 18px;
    font-weight: 600;
    font-size: 12.5px;
    margin-right: 3px;
}}
QTabBar::tab:selected {{
    color: {text_primary};
    background: {surface};
    border-color: {border};
    border-bottom-color: {surface};
}}
QTabBar::tab:hover:!selected {{ color: {text_primary}; background: {hover}; }}

/* ─── Frame / Separadores ─────────────────────────────────────────────────── */
QFrame[frameShape="4"], QFrame[frameShape="5"] {{
    color: {border}; border: none; background: {border};
}}

/* ─── CheckBox con icono check SVG nítido ─────────────────────────────────── */
QCheckBox {{ color: {text_primary}; spacing: 8px; background: transparent; border: none; }}
QCheckBox::indicator {{
    width: 17px; height: 17px;
    border: 1.5px solid {border_strong};
    border-radius: 5px;
    background: {c["bg_input"]};
}}
QCheckBox::indicator:checked {{
    background: {brand};
    border-color: {brand};
    image: url("{check_white_svg}");
}}
QCheckBox::indicator:hover {{ border-color: {border_hover}; }}

/* ─── RadioButton ─────────────────────────────────────────────────────────── */
QRadioButton {{ color: {text_primary}; spacing: 8px; background: transparent; border: none; }}
QRadioButton::indicator {{
    width: 17px; height: 17px;
    border: 1.5px solid {border_strong};
    border-radius: 9px;
    background: {c["bg_input"]};
}}
QRadioButton::indicator:checked {{ background: {brand}; border-color: {brand}; }}
QRadioButton::indicator:hover   {{ border-color: {border_hover}; }}

/* ─── Barra de estado ─────────────────────────────────────────────────────── */
QStatusBar {{
    background: {canvas};
    color: {text_secondary};
    border-top: 1px solid {border};
    font-size: 11px;
    padding: 2px 10px;
}}
QStatusBar::item {{ border: none; }}

/* ─── MessageBox ──────────────────────────────────────────────────────────── */
QMessageBox {{ background: {surface}; color: {text_primary}; }}
QMessageBox QLabel {{ color: {text_primary}; border: none; background: transparent; }}
QMessageBox QPushButton {{ min-width: 92px; }}

/* ─── Tooltip ─────────────────────────────────────────────────────────────── */
QToolTip {{
    background: {tooltip_bg};
    color: #FFFFFF;
    border: {tooltip_border};
    border-radius: 8px;
    padding: 6px 10px;
    font-size: 11.5px;
}}

/* ─── Splitter ────────────────────────────────────────────────────────────── */
QSplitter::handle:vertical   {{ background: {border}; height: 1px; }}
QSplitter::handle:horizontal {{ background: {border}; width: 1px; }}

/* ─── Barra de herramientas ───────────────────────────────────────────────── */
QToolBar {{
    background: {surface};
    border-bottom: 1px solid {border};
    spacing: 4px;
    padding: 4px;
}}
QToolBar QToolButton {{
    background: transparent;
    color: {text_secondary};
    border: none;
    border-radius: 8px;
    padding: 6px 10px;
}}
QToolBar QToolButton:hover {{ background: {hover}; color: {text_primary}; }}

/* ─── Blindaje obligatorio para áreas de firma (siempre fondo blanco) ─────── */
QWidget#pesa_signature_canvas, QFrame#pesa_signature_canvas {{
    background-color: #FFFFFF;
    border: 1.5px solid {border_strong};
    border-radius: 8px;
}}
QLabel#pesa_signature_preview {{
    background-color: #FFFFFF;
    border: 1px dashed {border_strong};
    border-radius: 10px;
    color: #6E6E73;
}}
"""


STYLESHEET = generate_stylesheet("light")


def get_badge_style(estado: str, is_dark: bool | None = None) -> str:
    """Retorna el estilo CSS inline monocromático corporativo Apple PESA según el tema activo."""
    c = DARK_COLORS if (is_dark if is_dark is not None else (COLORS.get("bg_primary") == "#121214")) else LIGHT_COLORS
    est = str(estado or "").upper()
    base = (
        "border-radius: 6px; padding: 2px 8px; "
        "font-size: 11px; font-weight: 600; "
    )
    if est in ("PROCESO", "PENDING", "PENDIENTE"):
        return base + f"background-color: {c['bg_elevated']}; color: {c['text_primary']}; border: 1px solid {c['border_strong']};"
    if est in ("CANCELADA", "CANCELADO"):
        return base + f"background-color: {c['bg_elevated']}; color: {c['text_secondary']}; border: 1px solid {c['border_default']};"
    return base + f"background-color: {c['bg_elevated']}; color: {c['text_primary']}; border: 1px solid {c['border_default']};"
