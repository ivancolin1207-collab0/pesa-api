# -*- coding: utf-8 -*-
"""
ui/theme.py — Sistema de Diseño Dual (Apple Light & Apple Dark) — Básculas PESA (PyQt6)
----------------------------------------------------------------------------------------
Centraliza:
  - Tokens oficiales Claro y Oscuro (Apple Dark: #121214 / #1C1C1E / #2C2C2E / #323236 / #38383A).
  - ThemeManager singleton con persistencia en QSettings("BasculasPESA", "ServiciosPESA")
    (default obligatorio: "system"), detección de tema Windows/Qt y suscripción en vivo a
    app.styleHints().colorSchemeChanged.
  - Adaptación hermética en vivo de QSS inline para widgets montados/lazy, blindando
    estrictamente los pads de firma (pesa_signature_canvas, pesa_signature_preview y
    propiedad pesa_force_light=True) para que SIEMPRE permanezcan con fondo #FFFFFF y trazo #000000.
  - Componentes reutilizables (PrimaryButton, SecondaryButton, OverflowMenuButton,
    StatusBadge, SectionCard, ToastNotification, LinearProgressBar) con QPainter seguro.
"""
from __future__ import annotations

import logging
import re
from typing import Callable, Optional

from PyQt6.QtCore import Qt, QTimer, QRectF, QPoint, QSize, QSettings, QObject, QEvent
from PyQt6.QtGui import QColor, QPainter, QPen, QBrush, QPainterPath, QFont, QFontMetrics, QPalette
from PyQt6.QtWidgets import (
    QApplication, QWidget, QFrame, QPushButton, QLabel, QHBoxLayout, QVBoxLayout,
    QSizePolicy, QStyleFactory, QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox,
    QTextEdit, QPlainTextEdit, QDateEdit,
)

from ui.styles.theme import (
    LIGHT_COLORS,
    DARK_COLORS,
    COLORS as _STYLES_COLORS,
    generate_stylesheet,
    resolve_mode,
)

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# TOKENS OFICIALES — LIGHT & APPLE DARK (BÁSCULAS PESA v4.0.5)
# ──────────────────────────────────────────────────────────────────────────────
LIGHT_PALETTE: dict[str, str] = {
    "canvas":           "#F5F5F7",  # Apple System Gray 6
    "surface":          "#FFFFFF",  # Tarjetas, tablas, sidebar
    "surface_elevated": "#F2F2F7",  # Inputs/badges/elevados
    "surface_muted":    "#F2F2F7",  # Badges neutros, cápsulas
    "surface_hover":    "#F2F2F7",  # Hover filas / botones secundarios
    "table_header":     "#FBFBFD",  # Encabezados de tabla
    "border":           "#E5E5EA",  # Borde principal 1px
    "border_strong":    "#D2D2D7",  # Borde inputs / botones secundarios
    "divider":          "#F2F2F7",  # Divisores horizontales
    "text_primary":     "#1D1D1F",  # Texto principal
    "text_secondary":   "#6E6E73",  # Texto secundario
    "text_tertiary":    "#8E8E93",  # Placeholders / hints
    "brand":            "#C8102E",  # Botón relleno principal (texto #FFFFFF)
    "brand_hover":      "#A60D26",  # Rojo hover
    "brand_pressed":    "#880B20",  # Rojo pressed
    "brand_accent":     "#C8102E",  # Texto/borde/ícono activo sobre superficie clara
    "dot_green":        "#34C759",  # Cerrado / Conectado
    "dot_amber":        "#FF9500",  # En proceso / Offline
    "dot_red":          "#C8102E",  # Pendiente / Alerta
    "dot_neutral":      "#6E6E73",  # Neutro / Cancelada
}

DARK_PALETTE: dict[str, str] = {
    "canvas":           "#121214",  # Canvas / Fondo principal
    "surface":          "#1C1C1E",  # Tarjetas, tablas y sidebar
    "surface_elevated": "#2C2C2E",  # Inputs, encabezados de tabla, badges neutros
    "surface_muted":    "#2C2C2E",  # Cápsulas neutras
    "surface_hover":    "#323236",  # Hover de filas / botones secundarios
    "table_header":     "#2C2C2E",  # Encabezados de tabla
    "border":           "#38383A",  # Bordes y divisores finos
    "border_strong":    "#38383A",  # Bordes inputs / botones
    "divider":          "#38383A",  # Divisores finos
    "text_primary":     "#F5F5F7",  # Texto primario
    "text_secondary":   "#98989D",  # Texto secundario
    "text_tertiary":    "#636366",  # Placeholder
    "brand":            "#C8102E",  # Botón relleno principal (texto #FFFFFF)
    "brand_hover":      "#A60D26",  # Rojo hover
    "brand_pressed":    "#880B20",  # Rojo pressed
    "brand_accent":     "#F03E55",  # Texto/borde/ícono activo sobre #1C1C1E (contraste AA/AAA)
    "dot_green":        "#30D158",  # Cerrado / Conectado
    "dot_amber":        "#FF9F0A",  # En proceso
    "dot_red":          "#FF453A",  # Pendiente / Alerta
    "dot_neutral":      "#98989D",  # Neutro / Cancelada
}

# Diccionario mutable en vivo — leído por StatusBadge, delegates y vistas
PALETTE: dict[str, str] = dict(LIGHT_PALETTE)

FONT_FAMILY = '"Segoe UI Variable", "Segoe UI", "Inter", -apple-system, BlinkMacSystemFont, Arial, sans-serif'


def get_palette(modo: Optional[str] = None) -> dict[str, str]:
    """Retorna una copia o referencia de los tokens activos ('light' o 'dark')."""
    if modo is None:
        return PALETTE
    return DARK_PALETTE if resolve_mode(modo) == "dark" else LIGHT_PALETTE


def build_qpalette(modo: str) -> QPalette:
    """Construye una QPalette Fusion coherente con el modo resuelto ('light' o 'dark')."""
    is_dark = resolve_mode(modo) == "dark"
    p = DARK_PALETTE if is_dark else LIGHT_PALETTE
    pal = QPalette()
    pal.setColor(QPalette.ColorRole.Window,          QColor(p["canvas"]))
    pal.setColor(QPalette.ColorRole.WindowText,      QColor(p["text_primary"]))
    pal.setColor(QPalette.ColorRole.Base,            QColor(p["surface_elevated"] if is_dark else p["surface"]))
    pal.setColor(QPalette.ColorRole.AlternateBase,   QColor(p["surface"]))
    pal.setColor(QPalette.ColorRole.ToolTipBase,     QColor("#2C2C2E" if is_dark else "#1D1D1F"))
    pal.setColor(QPalette.ColorRole.ToolTipText,     QColor("#FFFFFF"))
    pal.setColor(QPalette.ColorRole.Text,            QColor(p["text_primary"]))
    pal.setColor(QPalette.ColorRole.Button,          QColor(p["surface_elevated"] if is_dark else p["surface"]))
    pal.setColor(QPalette.ColorRole.ButtonText,      QColor(p["text_primary"]))
    pal.setColor(QPalette.ColorRole.BrightText,      QColor(p["brand_accent"]))
    pal.setColor(QPalette.ColorRole.Link,            QColor(p["brand_accent"]))
    pal.setColor(QPalette.ColorRole.Highlight,       QColor(p["surface_hover"]))
    pal.setColor(QPalette.ColorRole.HighlightedText, QColor(p["text_primary"]))
    pal.setColor(QPalette.ColorRole.PlaceholderText, QColor(p["text_tertiary"]))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text,       QColor(p["text_tertiary"]))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.ButtonText, QColor(p["text_tertiary"]))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Base,       QColor(p["surface"] if is_dark else "#F5F5F7"))
    return pal


# ──────────────────────────────────────────────────────────────────────────────
# ADAPTADOR HERMÉTICO DE QSS INLINE (SIN TOCAR PADS DE FIRMA NI BOTONES ROJOS)
# ──────────────────────────────────────────────────────────────────────────────
_SHIELDED_NAMES = {"pesa_signature_canvas", "pesa_signature_preview"}

_BG_LIGHT_MAP = {
    "#ffffff": "#1C1C1E",
    "#fff":    "#1C1C1E",
    "white":   "#1C1C1E",
    "#fbfbfd": "#1C1C1E",
    "#fcfcfc": "#1C1C1E",
    "#fafafa": "#2C2C2E",
    "#f5f5f7": "#121214",
    "#f0f2f5": "#121214",
    "#f9fafb": "#121214",
    "#f8fafc": "#1C1C1E",
    "#f2f2f7": "#2C2C2E",
    "#f3f4f6": "#2C2C2E",
    "#f1f5f9": "#2C2C2E",
    "#efeff4": "#2C2C2E",
    "#e5e5ea": "#323236",
    "#e5e7eb": "#323236",
    "#e2e8f0": "#323236",
    "#fff5f6": "#2C2C2E",
    "#fef2f2": "#2C2C2E",
    "#fff1f2": "#2C2C2E",
    "#f0fdf4": "#2C2C2E",
    "#ecfdf5": "#2C2C2E",
    "#fffbeb": "#2C2C2E",
    "#fef3c7": "#2C2C2E",
    "#eff6ff": "#2C2C2E",
    "#dbeafe": "#2C2C2E",
}

_BG_INPUT_LIGHT_MAP = {
    **_BG_LIGHT_MAP,
    "#ffffff": "#2C2C2E",
    "#fff":    "#2C2C2E",
    "white":   "#2C2C2E",
    "#fbfbfd": "#2C2C2E",
    "#fcfcfc": "#2C2C2E",
    "#f8fafc": "#2C2C2E",
    "#f9fafb": "#2C2C2E",
    "#f5f5f7": "#2C2C2E",
}

_BORDER_LIGHT_MAP = {
    "#e5e5ea": "#38383A",
    "#d2d2d7": "#38383A",
    "#d1d1d6": "#38383A",
    "#e5e7eb": "#38383A",
    "#e2e8f0": "#38383A",
    "#cbd5e1": "#38383A",
    "#d1d5db": "#38383A",
    "#f2f2f7": "#38383A",
    "#f3f4f6": "#38383A",
    "#c7c7cc": "#48484A",
    "#9ca3af": "#636366",
    "#8e8e93": "#636366",
    "#fecaca": "#F03E55",
    "#fca5a5": "#F03E55",
    "#bbf7d0": "#38383A",
    "#fde68a": "#38383A",
}

_TEXT_LIGHT_MAP = {
    "#1d1d1f": "#F5F5F7",
    "#111827": "#F5F5F7",
    "#0f172a": "#F5F5F7",
    "#1e293b": "#F5F5F7",
    "#334155": "#F5F5F7",
    "#374151": "#F5F5F7",
    "#1f2937": "#F5F5F7",
    "#000000": "#F5F5F7",
    "#000":    "#F5F5F7",
    "black":   "#F5F5F7",
    "#6e6e73": "#98989D",
    "#6b7280": "#98989D",
    "#475569": "#98989D",
    "#64748b": "#98989D",
    "#86868b": "#98989D",
    "#4b5563": "#98989D",
    "#8e8e93": "#98989D",
    "#9ca3af": "#98989D",
    "#94a3b8": "#98989D",
    "#c7c7cc": "#636366",
    "#c8102e": "#F03E55",
    "#b91c1c": "#F03E55",
    "#dc2626": "#FF453A",
    "#16a34a": "#30D158",
    "#15803d": "#30D158",
    "#34c759": "#30D158",
    "#d97706": "#FF9F0A",
    "#ff9500": "#FF9F0A",
}

_RE_BG = re.compile(
    r"(background(?:-color)?\s*:\s*)(#[0-9a-fA-F]{3,6}|white|rgba\([^)]+\))",
    re.IGNORECASE,
)
_RE_BORDER = re.compile(
    r"(border(?:-(?:top|bottom|left|right))?(?:-color)?\s*:[^;{}]*?)(#[0-9a-fA-F]{3,6}|rgba\([^)]+\))",
    re.IGNORECASE,
)
_RE_COLOR = re.compile(
    r"((?:^|[;\s{])color\s*:\s*)(#[0-9a-fA-F]{3,6}|black)\b",
    re.IGNORECASE,
)


def adapt_inline_qss(qss: str, is_dark: bool, is_input_widget: bool = False) -> str:
    """
    Adapta una hoja QSS inline escrita para modo claro hacia los tokens Apple Dark
    sin alterar botones rojos sólidos (#C8102E + texto #FFFFFF).
    """
    if not is_dark or not qss:
        return qss

    bg_map = _BG_INPUT_LIGHT_MAP if is_input_widget else _BG_LIGHT_MAP

    def _repl_bg(m: re.Match) -> str:
        prefix, raw_val = m.group(1), m.group(2)
        low = raw_val.strip().lower()
        if low.startswith("rgba(0,") or low.startswith("rgba(0 ,"):
            return f"{prefix}#38383A"
        if low.startswith("rgba(245,") or low.startswith("rgba(255,"):
            return f"{prefix}#121214"
        mapped = bg_map.get(low)
        return f"{prefix}{mapped}" if mapped else m.group(0)

    def _repl_border(m: re.Match) -> str:
        prefix, raw_val = m.group(1), m.group(2)
        low = raw_val.strip().lower()
        if low.startswith("rgba(0,") or low.startswith("rgba(0 ,"):
            return f"{prefix}#38383A"
        mapped = _BORDER_LIGHT_MAP.get(low)
        return f"{prefix}{mapped}" if mapped else m.group(0)

    def _repl_color(m: re.Match) -> str:
        prefix, raw_val = m.group(1), m.group(2)
        low = raw_val.strip().lower()
        mapped = _TEXT_LIGHT_MAP.get(low)
        return f"{prefix}{mapped}" if mapped else m.group(0)

    out = _RE_BG.sub(_repl_bg, qss)
    out = _RE_BORDER.sub(_repl_border, out)
    out = _RE_COLOR.sub(_repl_color, out)
    return out


def _is_shielded_widget(w: QWidget) -> bool:
    try:
        if w.objectName() in _SHIELDED_NAMES:
            return True
        if bool(w.property("pesa_force_light")):
            return True
    except Exception:
        pass
    return False


def _adapt_single_widget(w: QWidget, is_dark: bool) -> None:
    if w is None or _is_shielded_widget(w):
        return
    try:
        cur_qss = w.styleSheet()
    except Exception:
        return
    if not cur_qss:
        return

    base_qss = w.property("_pesa_base_qss")
    last_applied = w.property("_pesa_last_qss")
    if base_qss is None or (last_applied is not None and cur_qss != last_applied):
        base_qss = cur_qss
        w.setProperty("_pesa_base_qss", base_qss)

    is_input = isinstance(
        w, (QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox, QTextEdit, QPlainTextEdit, QDateEdit)
    )
    target_qss = adapt_inline_qss(str(base_qss), is_dark, is_input_widget=is_input) if is_dark else str(base_qss)
    if cur_qss != target_qss:
        w.setProperty("_pesa_last_qss", target_qss)
        w.setStyleSheet(target_qss)
    else:
        w.setProperty("_pesa_last_qss", cur_qss)


def retheme_widget_tree(root: QWidget, is_dark: bool) -> None:
    """Reaplica el tema en vivo a todo el árbol de widgets y repinta QPainters."""
    if root is None:
        return
    widgets = [root] + list(root.findChildren(QWidget))
    for w in widgets:
        if _is_shielded_widget(w):
            continue
        if hasattr(w, "apply_theme") and callable(getattr(w, "apply_theme")):
            try:
                w.apply_theme(is_dark)
                continue
            except Exception as exc:
                logger.debug("apply_theme error en %s: %s", type(w).__name__, exc)
        _adapt_single_widget(w, is_dark)
        try:
            w.update()
        except Exception:
            pass


class _ThemeAutoAdaptFilter(QObject):
    """Event filter global que adapta automáticamente diálogos, pestañas lazy y menús al mostrarse."""

    def __init__(self, manager: "ThemeManager", parent: Optional[QObject] = None):
        super().__init__(parent)
        self._manager = manager

    def eventFilter(self, obj: QObject, event: QEvent) -> bool:
        if event.type() == QEvent.Type.Show and isinstance(obj, QWidget):
            if self._manager.is_dark and not _is_shielded_widget(obj):
                try:
                    if hasattr(obj, "apply_theme") and callable(getattr(obj, "apply_theme")):
                        obj.apply_theme(True)
                    else:
                        _adapt_single_widget(obj, True)
                        if obj.isWindow():
                            for child in obj.findChildren(QWidget):
                                if not _is_shielded_widget(child):
                                    if hasattr(child, "apply_theme") and callable(getattr(child, "apply_theme")):
                                        child.apply_theme(True)
                                    else:
                                        _adapt_single_widget(child, True)
                except Exception:
                    pass
        return False


class ThemeManager:
    """
    Gestor singleton de tema Claro / Oscuro / Automático del Sistema para PyQt6.
    - Persiste en QSettings("BasculasPESA", "ServiciosPESA"), clave "ui/theme_mode".
    - Valor por defecto obligatorio en primera ejecución: "system".
    - Escucha app.styleHints().colorSchemeChanged para cambio automático en vivo.
    """

    SETTINGS_ORG = "BasculasPESA"
    SETTINGS_APP = "ServiciosPESA"
    SETTINGS_KEY = "ui/theme_mode"

    def __init__(self) -> None:
        self._preference: str = "system"
        self._resolved: str = "light"
        self._listeners: list[Callable[[bool], None]] = []
        self._app: Optional[QApplication] = None
        self._event_filter: Optional[_ThemeAutoAdaptFilter] = None
        self._signal_connected: bool = False

    @property
    def preference(self) -> str:
        """Preferencia del usuario: 'system', 'light' o 'dark'."""
        return self._preference

    @property
    def resolved_mode(self) -> str:
        """Modo efectivo aplicado: 'light' o 'dark'."""
        return self._resolved

    @property
    def is_dark(self) -> bool:
        return self._resolved == "dark"

    def load_preference(self) -> str:
        """Lee la preferencia persistida; default obligatorio: 'system'."""
        try:
            qs = QSettings(self.SETTINGS_ORG, self.SETTINGS_APP)
            raw = str(qs.value(self.SETTINGS_KEY, "system") or "system").strip().lower()
            if raw in ("light", "dark", "system"):
                self._preference = raw
            else:
                self._preference = "system"
        except Exception:
            self._preference = "system"
        return self._preference

    def save_preference(self, mode: str) -> None:
        m = str(mode or "system").strip().lower()
        if m not in ("light", "dark", "system"):
            m = "system"
        self._preference = m
        try:
            qs = QSettings(self.SETTINGS_ORG, self.SETTINGS_APP)
            qs.setValue(self.SETTINGS_KEY, m)
            qs.sync()
        except Exception as exc:
            logger.debug("No se pudo persistir preferencia de tema: %s", exc)

    def subscribe(self, callback: Callable[[bool], None]) -> None:
        if callback not in self._listeners:
            self._listeners.append(callback)

    def unsubscribe(self, callback: Callable[[bool], None]) -> None:
        if callback in self._listeners:
            self._listeners.remove(callback)

    def init_app(self, app: QApplication) -> str:
        """Inicializa Fusion, lee preferencia ('system' por defecto), conecta colorSchemeChanged y aplica el tema."""
        self._app = app
        try:
            app.setStyle(QStyleFactory.create("Fusion"))
        except Exception:
            pass

        self.load_preference()

        if self._event_filter is None:
            self._event_filter = _ThemeAutoAdaptFilter(self, app)
            app.installEventFilter(self._event_filter)

        if not self._signal_connected:
            try:
                sh = app.styleHints()
                if hasattr(sh, "colorSchemeChanged"):
                    sh.colorSchemeChanged.connect(self._on_system_color_scheme_changed)
                    self._signal_connected = True
            except Exception as exc:
                logger.debug("colorSchemeChanged no disponible: %s", exc)

        return self.apply(self._preference, persist=False)

    def _on_system_color_scheme_changed(self, *_args) -> None:
        """Reacciona en vivo cuando Windows cambia entre Claro y Oscuro estando en modo 'system'."""
        if self._preference == "system":
            self.apply("system", persist=False)

    def set_mode(self, mode: str) -> str:
        """Cambia y persiste el modo ('light', 'dark' o 'system') aplicando inmediatamente en vivo."""
        return self.apply(mode, persist=True)

    def toggle_light_dark(self) -> str:
        """Alterna en 1 clic entre Claro y Oscuro desde el botón rápido del Sidebar."""
        next_mode = "light" if self.is_dark else "dark"
        return self.apply(next_mode, persist=True)

    def apply(self, mode: Optional[str] = None, persist: bool = False) -> str:
        if mode is not None:
            m = str(mode).strip().lower()
            if m in ("light", "dark", "system"):
                self._preference = m
        if persist:
            self.save_preference(self._preference)

        self._resolved = resolve_mode(self._preference)
        is_dark = (self._resolved == "dark")

        # Actualizar diccionarios compartidos PALETTE y COLORS in-place
        PALETTE.update(DARK_PALETTE if is_dark else LIGHT_PALETTE)
        _STYLES_COLORS.update(DARK_COLORS if is_dark else LIGHT_COLORS)

        qss = generate_stylesheet(self._resolved)
        try:
            import ui.styles.theme as _st_mod
            _st_mod.STYLESHEET = qss
        except Exception:
            pass

        app = self._app or QApplication.instance()
        if app is not None:
            try:
                app.setPalette(build_qpalette(self._resolved))
                app.setStyleSheet(qss)
            except Exception as exc:
                logger.warning("Error aplicando tema global (%s): %s", self._resolved, exc)

            # Reestilizar todas las ventanas abiertas en vivo sin cerrarlas
            for top in list(app.topLevelWidgets()):
                try:
                    retheme_widget_tree(top, is_dark)
                except Exception as exc:
                    logger.debug("Error re-estilizando ventana %s: %s", type(top).__name__, exc)

        # Notificar suscriptores explícitos
        for cb in list(self._listeners):
            try:
                cb(is_dark)
            except Exception as exc:
                logger.debug("Listener de tema omitido: %s", exc)

        return self._resolved


theme_manager = ThemeManager()


# ──────────────────────────────────────────────────────────────────────────────
# HELPERS QSS DINÁMICOS PARA BOTONES/MENÚS (COMPATIBILIDAD)
# ──────────────────────────────────────────────────────────────────────────────
def get_btn_primary_qss() -> str:
    p = PALETTE
    return f"""
        QPushButton {{
            background-color: {p['brand']};
            color: #FFFFFF;
            border: 1px solid {p['brand']};
            border-radius: 10px;
            padding: 0 16px;
            font-size: 13px;
            font-weight: 600;
            min-height: 36px;
        }}
        QPushButton:hover {{ background-color: {p['brand_hover']}; border-color: {p['brand_hover']}; }}
        QPushButton:pressed {{ background-color: {p['brand_pressed']}; border-color: {p['brand_pressed']}; }}
        QPushButton:disabled {{ background-color: {p['surface_muted']}; color: {p['text_tertiary']}; border-color: {p['border']}; }}
        QPushButton::menu-indicator {{ image: none; width: 0px; }}
    """


def get_btn_secondary_qss() -> str:
    p = PALETTE
    bg = p["surface_elevated"] if theme_manager.is_dark else p["surface"]
    return f"""
        QPushButton {{
            background-color: {bg};
            color: {p['text_primary']};
            border: 1px solid {p['border_strong']};
            border-radius: 10px;
            padding: 0 14px;
            font-size: 13px;
            font-weight: 500;
            min-height: 36px;
        }}
        QPushButton:hover {{ background-color: {p['surface_hover']}; border-color: {p['text_secondary']}; }}
        QPushButton:disabled {{ background-color: {p['surface']}; color: {p['text_tertiary']}; border-color: {p['border']}; }}
        QPushButton::menu-indicator {{ image: none; width: 0px; }}
    """


BTN_PRIMARY_QSS = get_btn_primary_qss()
BTN_SECONDARY_QSS = get_btn_secondary_qss()

BTN_TABLE_PRIMARY_QSS = """
    QPushButton {
        background-color: #C8102E;
        color: #FFFFFF;
        border: 1px solid #C8102E;
        border-radius: 8px;
        padding: 0 10px;
        font-size: 11.5px;
        font-weight: 600;
        min-height: 28px;
    }
    QPushButton:hover { background-color: #A60D26; border-color: #A60D26; }
    QPushButton:pressed { background-color: #880B20; }
    QPushButton::menu-indicator { image: none; width: 0px; }
"""

BTN_TABLE_SECONDARY_QSS = """
    QPushButton {
        background-color: #FFFFFF;
        color: #1D1D1F;
        border: 1px solid #D2D2D7;
        border-radius: 8px;
        padding: 0 10px;
        font-size: 11.5px;
        font-weight: 600;
        min-height: 28px;
    }
    QPushButton:hover { background-color: #F2F2F7; border-color: #8E8E93; }
    QPushButton:pressed { background-color: #E5E5EA; }
    QPushButton:disabled { background-color: #F2F2F7; color: #8E8E93; border-color: #E5E5EA; }
    QPushButton::menu-indicator { image: none; width: 0px; }
"""

MENU_QSS = """
    QMenu {
        background-color: #FFFFFF;
        border: 1px solid #E5E5EA;
        border-radius: 10px;
        padding: 4px;
        font-size: 12.5px;
    }
    QMenu::item {
        padding: 7px 14px;
        border-radius: 8px;
        color: #1D1D1F;
    }
    QMenu::item:selected {
        background-color: #F2F2F7;
        color: #1D1D1F;
    }
    QMenu::item:disabled {
        color: #8E8E93;
    }
    QMenu::separator {
        height: 1px;
        background-color: #F2F2F7;
        margin: 4px 8px;
    }
"""


# ──────────────────────────────────────────────────────────────────────────────
# COMPONENTES REUTILIZABLES (HEREDAN QSS GLOBAL — SIN FUGAS AL CAMBIAR DE TEMA)
# ──────────────────────────────────────────────────────────────────────────────
class PrimaryButton(QPushButton):
    """Botón de acción principal en Rojo Corporativo Básculas PESA (#C8102E)."""

    def __init__(self, text: str = "", height: int = 36, parent: Optional[QWidget] = None):
        super().__init__(text, parent if isinstance(parent, QWidget) else None)
        self.setFixedHeight(int(height))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setProperty("variant", "primary")


class SecondaryButton(QPushButton):
    """Botón secundario neutro adaptado automáticamente a modo Claro y Oscuro."""

    def __init__(self, text: str = "", height: int = 36, parent: Optional[QWidget] = None):
        super().__init__(text, parent if isinstance(parent, QWidget) else None)
        self.setFixedHeight(int(height))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setProperty("variant", "secondary")


class OverflowMenuButton(QPushButton):
    """Botón discreto '⋯' para agrupar acciones secundarias de fila sin saturar tablas."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__("⋯", parent if isinstance(parent, QWidget) else None)
        self.setFixedSize(30, 28)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip("Más acciones")
        self.setProperty("variant", "overflow")


class StatusBadge(QWidget):
    """
    Etiqueta de estado neutra (cápsula #F2F2F7 en Claro / #2C2C2E en Oscuro)
    con punto semántico circular de 6px. Renderizado directo con QPainter (QRectF).
    """

    def __init__(
        self,
        text: str = "",
        dot_color: Optional[str] = None,
        parent: Optional[QWidget] = None,
    ):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._text = str(text or "")
        self._dot_color = QColor(dot_color) if dot_color else None
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self._sync_size()

    def set_status(self, text: str, dot_color: Optional[str] = None) -> None:
        self._text = str(text or "")
        self._dot_color = QColor(dot_color) if dot_color else None
        self._sync_size()
        self.update()

    def _sync_size(self) -> None:
        f = QFont("Segoe UI")
        f.setPixelSize(11)
        f.setWeight(QFont.Weight.DemiBold)
        fm = QFontMetrics(f)
        dot_w = 12 if self._dot_color is not None else 0
        w = int(fm.horizontalAdvance(self._text) + 18 + dot_w)
        self.setFixedSize(max(44, w), 24)

    def sizeHint(self) -> QSize:
        return self.minimumSize()

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = QRectF(0.5, 0.5, float(self.width() - 1), float(self.height() - 1))

        path = QPainterPath()
        path.addRoundedRect(r, 8.0, 8.0)
        p.fillPath(path, QBrush(QColor(PALETTE["surface_muted"])))
        p.setPen(QPen(QColor(PALETTE["border"]), 1.0))
        p.drawPath(path)

        text_left = 9.0
        if self._dot_color is not None:
            dot_d = 6.0
            dot_y = (float(self.height()) - dot_d) / 2.0
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(self._dot_color)
            p.drawEllipse(QRectF(9.0, dot_y, dot_d, dot_d))
            text_left = 20.0

        f = QFont("Segoe UI")
        f.setPixelSize(11)
        f.setWeight(QFont.Weight.DemiBold)
        p.setFont(f)
        p.setPen(QColor(PALETTE["text_primary"]))
        text_rect = QRectF(text_left, 0.0, float(self.width()) - text_left - 8.0, float(self.height()))
        p.drawText(text_rect, Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, self._text)
        p.end()


class SectionCard(QFrame):
    """Contenedor tarjeta corporativa (adaptado automáticamente a Claro y Oscuro)."""

    def __init__(self, padding: int = 20, spacing: int = 12, parent: Optional[QWidget] = None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self.setObjectName("section_card")
        self.setProperty("card", True)
        self.content_layout = QVBoxLayout(self)
        self.content_layout.setContentsMargins(int(padding), int(padding), int(padding), int(padding))
        self.content_layout.setSpacing(int(spacing))


class LinearProgressBar(QWidget):
    """Barra de progreso lineal discreta (3px de alto) en Rojo Corporativo (#C8102E)."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self.setFixedHeight(3)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._pos = 0.0
        self._running = False
        self._timer = QTimer(self)
        self._timer.setInterval(24)
        self._timer.timeout.connect(self._tick)
        self.setVisible(False)

    def set_running(self, running: bool) -> None:
        self._running = bool(running)
        if self._running:
            self.setVisible(True)
            if not self._timer.isActive():
                self._timer.start()
        else:
            self._timer.stop()
            self.setVisible(False)
        self.update()

    def _tick(self) -> None:
        self._pos = (self._pos + 0.028) % 1.35
        self.update()

    def paintEvent(self, _event) -> None:
        if not self._running:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        w = float(self.width())
        h = float(self.height())
        p.fillRect(QRectF(0.0, 0.0, w, h), QColor(PALETTE["border"]))
        bar_w = max(40.0, w * 0.28)
        x = (self._pos - 0.30) * w
        p.fillRect(QRectF(x, 0.0, bar_w, h), QColor(PALETTE["brand"]))
        p.end()


class ToastNotification(QFrame):
    """Notificación flotante no bloqueante (esquina inferior derecha, autocierre 3s)."""

    def __init__(
        self,
        parent: QWidget,
        message: str,
        level: str = "success",
        duration_ms: int = 3200,
    ):
        super().__init__(parent)
        self.setObjectName("pesa_toast")
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, True)
        bg = "#2C2C2E" if theme_manager.is_dark else "#1D1D1F"
        brd = "#38383A"
        self.setStyleSheet(f"""
            QFrame#pesa_toast {{
                background-color: {bg};
                border: 1px solid {brd};
                border-radius: 10px;
            }}
        """)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 10)
        lay.setSpacing(10)

        dot_map = {
            "success": PALETTE["dot_green"],
            "warning": PALETTE["dot_amber"],
            "error":   PALETTE["dot_red"],
            "info":    PALETTE["text_secondary"],
        }
        dot_hex = dot_map.get(level, PALETTE["dot_green"])
        dot = QLabel()
        dot.setFixedSize(8, 8)
        dot.setStyleSheet(f"background-color: {dot_hex}; border-radius: 4px; border: none;")
        lay.addWidget(dot)

        lbl = QLabel(str(message or ""))
        lbl.setWordWrap(True)
        lbl.setMaximumWidth(360)
        lbl.setStyleSheet(
            "color: #FFFFFF; font-size: 12.5px; font-weight: 500; background: transparent; border: none;"
        )
        lay.addWidget(lbl)

        self.adjustSize()
        self._reposition(parent)
        self.show()
        self.raise_()

        QTimer.singleShot(int(duration_ms), self.close)

    def _reposition(self, parent: QWidget) -> None:
        if parent is None:
            return
        margin = 20
        x = max(margin, int(parent.width() - self.width() - margin))
        y = max(margin, int(parent.height() - self.height() - margin))
        self.move(QPoint(x, y))


def show_toast(
    parent: Optional[QWidget],
    message: str,
    level: str = "success",
    duration_ms: int = 3200,
) -> Optional[ToastNotification]:
    """Muestra un toast discreto anclado a la ventana principal o al widget padre."""
    if parent is None:
        return None
    anchor = parent.window() if hasattr(parent, "window") and parent.window() is not None else parent
    for old in anchor.findChildren(ToastNotification):
        try:
            old.close()
        except Exception:
            pass
    try:
        return ToastNotification(anchor, message, level=level, duration_ms=duration_ms)
    except Exception:
        return None
