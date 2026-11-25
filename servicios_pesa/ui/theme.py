# -*- coding: utf-8 -*-
"""
theme.py — Sistema de Diseño Corporativo Minimalista Básculas PESA (PyQt6)
---------------------------------------------------------------------------
Centraliza tokens cromáticos, tipográficos, QSS corporativo y componentes
reutilizables (PrimaryButton, SecondaryButton, OverflowMenuButton, StatusBadge,
SectionCard, ToastNotification, LinearProgressBar).

Reglas estrictas de seguridad PyQt6:
  - Todas las primitivas QPainter (drawLine, drawRect, drawEllipse, drawRoundedRect,
    fillRect) usan exclusivamente QPointF / QRectF o enteros int(round(...)).
  - Sin colores pastel ni gradientes "IA". Único acento de marca: #C8102E.
"""
from __future__ import annotations

from typing import Optional

from PyQt6.QtCore import Qt, QTimer, QRectF, QPoint, QSize
from PyQt6.QtGui import QColor, QPainter, QPen, QBrush, QPainterPath, QFont, QFontMetrics
from PyQt6.QtWidgets import (
    QWidget, QFrame, QPushButton, QLabel, QHBoxLayout, QVBoxLayout,
    QSizePolicy, QMenu,
)


# ──────────────────────────────────────────────────────────────────────────────
# TOKENS DE DISEÑO — BÁSCULAS PESA (APPLE MINIMALIST macOS SEQUOIA v3.3.1)
# ──────────────────────────────────────────────────────────────────────────────
PALETTE: dict[str, str] = {
    "canvas":         "#F5F5F7",  # Apple System Gray 6 — Fondo principal
    "surface":        "#FFFFFF",  # Tarjetas, tablas, formularios
    "surface_muted":  "#F2F2F7",  # Badges neutros, hover de filas y cápsulas
    "table_header":   "#FBFBFD",  # Encabezados de tabla
    "border":         "#E5E5EA",  # Borde principal ultrafino 1px
    "border_strong":  "#D2D2D7",  # Borde de inputs y botones secundarios
    "divider":        "#F2F2F7",  # Divisores horizontales entre filas
    "text_primary":   "#1D1D1F",  # Texto principal (Apple Anthracite)
    "text_secondary": "#6E6E73",  # Texto secundario / etiquetas
    "text_tertiary":  "#8E8E93",  # Placeholders / hints
    "brand":          "#C8102E",  # Rojo Corporativo Básculas PESA
    "brand_hover":    "#A60D26",  # Rojo hover
    "brand_pressed":  "#880B20",  # Rojo pressed
    "dot_green":      "#34C759",  # Punto semántico 6px: Cerrado / Sincronizado / Conectado
    "dot_amber":      "#FF9500",  # Punto semántico 6px: En Proceso / Offline
    "dot_red":        "#C8102E",  # Punto semántico 6px: Pendiente / Alerta / Cancelada
    "dot_neutral":    "#6E6E73",  # Punto semántico neutro
}

FONT_FAMILY = '"Segoe UI Variable", "Segoe UI", "Inter", -apple-system, BlinkMacSystemFont, Arial, sans-serif'

BTN_PRIMARY_QSS = """
    QPushButton {
        background-color: #C8102E;
        color: #FFFFFF;
        border: 1px solid #C8102E;
        border-radius: 10px;
        padding: 0 16px;
        font-size: 13px;
        font-weight: 600;
        min-height: 36px;
    }
    QPushButton:hover {
        background-color: #A60D26;
        border-color: #A60D26;
    }
    QPushButton:pressed {
        background-color: #880B20;
        border-color: #880B20;
    }
    QPushButton:disabled {
        background-color: #E5E5EA;
        color: #8E8E93;
        border-color: #E5E5EA;
    }
    QPushButton::menu-indicator { image: none; width: 0px; }
"""

BTN_SECONDARY_QSS = """
    QPushButton {
        background-color: #FFFFFF;
        color: #1D1D1F;
        border: 1px solid #D2D2D7;
        border-radius: 10px;
        padding: 0 14px;
        font-size: 13px;
        font-weight: 500;
        min-height: 36px;
    }
    QPushButton:hover {
        background-color: #F2F2F7;
        border-color: #8E8E93;
    }
    QPushButton:pressed {
        background-color: #E5E5EA;
    }
    QPushButton:disabled {
        background-color: #F2F2F7;
        color: #8E8E93;
        border-color: #E5E5EA;
    }
    QPushButton::menu-indicator { image: none; width: 0px; }
"""

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
    QPushButton:hover {
        background-color: #A60D26;
        border-color: #A60D26;
    }
    QPushButton:pressed {
        background-color: #880B20;
    }
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
    QPushButton:hover {
        background-color: #F2F2F7;
        border-color: #8E8E93;
    }
    QPushButton:pressed {
        background-color: #E5E5EA;
    }
    QPushButton:disabled {
        background-color: #F2F2F7;
        color: #8E8E93;
        border-color: #E5E5EA;
    }
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
# COMPONENTES REUTILIZABLES
# ──────────────────────────────────────────────────────────────────────────────
class PrimaryButton(QPushButton):
    """Botón de acción principal en Rojo Corporativo Básculas PESA (#C8102E)."""

    def __init__(self, text: str = "", height: int = 36, parent: Optional[QWidget] = None):
        super().__init__(text, parent if isinstance(parent, QWidget) else None)
        self.setFixedHeight(int(height))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setStyleSheet(BTN_PRIMARY_QSS)


class SecondaryButton(QPushButton):
    """Botón secundario neutro (#FFFFFF, borde #CBD5E1, texto #111827)."""

    def __init__(self, text: str = "", height: int = 36, parent: Optional[QWidget] = None):
        super().__init__(text, parent if isinstance(parent, QWidget) else None)
        self.setFixedHeight(int(height))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setStyleSheet(BTN_SECONDARY_QSS)


class OverflowMenuButton(QPushButton):
    """Botón discreto '⋯' para agrupar acciones secundarias de fila sin saturar tablas."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__("⋯", parent if isinstance(parent, QWidget) else None)
        self.setFixedSize(30, 28)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip("Más acciones")
        self.setStyleSheet("""
            QPushButton {
                background-color: #FFFFFF;
                color: #4B5563;
                border: 1px solid #CBD5E1;
                border-radius: 6px;
                font-size: 14px;
                font-weight: 700;
                padding: 0px;
            }
            QPushButton:hover {
                background-color: #F8FAFC;
                color: #111827;
                border-color: #9CA3AF;
            }
            QPushButton:pressed {
                background-color: #F3F4F6;
            }
            QPushButton::menu-indicator { image: none; width: 0px; }
        """)


class StatusBadge(QWidget):
    """
    Etiqueta de estado neutra (#F8FAFC, borde 1px #CBD5E1, texto #111827)
    con un punto semántico circular de 6px (#16A34A, #D97706, #C8102E o neutro).
    Renderizado directo con QPainter usando exclusivamente QRectF.
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
    """Contenedor tarjeta corporativa (#FFFFFF, 1px solid #E5E5EA, radio 14px)."""

    def __init__(self, padding: int = 20, spacing: int = 12, parent: Optional[QWidget] = None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self.setObjectName("section_card")
        self.setProperty("card", True)
        self.setStyleSheet("""
            QFrame#section_card {
                background-color: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 14px;
            }
        """)
        self.content_layout = QVBoxLayout(self)
        self.content_layout.setContentsMargins(int(padding), int(padding), int(padding), int(padding))
        self.content_layout.setSpacing(int(spacing))


class LinearProgressBar(QWidget):
    """
    Barra de progreso lineal discreta (3px de alto) en Rojo Corporativo (#C8102E)
    para indicar carga asíncrona en background sin bloquear la UI.
    Usa únicamente QRectF para compatibilidad estricta con PyQt6.
    """

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
        p.fillRect(QRectF(0.0, 0.0, w, h), QColor("#E5E7EB"))
        bar_w = max(40.0, w * 0.28)
        x = (self._pos - 0.30) * w
        p.fillRect(QRectF(x, 0.0, bar_w, h), QColor(PALETTE["brand"]))
        p.end()


class ToastNotification(QFrame):
    """
    Notificación flotante no bloqueante (esquina inferior derecha, autocierre 3s)
    para reemplazar QMessageBox intrusivos tras acciones exitosas.
    """

    _DOT_COLORS = {
        "success": PALETTE["dot_green"],
        "warning": PALETTE["dot_amber"],
        "error":   PALETTE["dot_red"],
        "info":    PALETTE["text_secondary"],
    }

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
        self.setStyleSheet("""
            QFrame#pesa_toast {
                background-color: #111827;
                border: 1px solid #374151;
                border-radius: 10px;
            }
        """)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 10, 14, 10)
        lay.setSpacing(10)

        dot_hex = self._DOT_COLORS.get(level, PALETTE["dot_green"])
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
    # Cerrar toasts previos en el mismo anchor para evitar apilamiento desordenado
    for old in anchor.findChildren(ToastNotification):
        try:
            old.close()
        except Exception:
            pass
    try:
        return ToastNotification(anchor, message, level=level, duration_ms=duration_ms)
    except Exception:
        return None
