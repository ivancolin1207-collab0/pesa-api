"""
digital_service_dialog.py — Formulario Digital Interactivo de Órdenes de Servicio
Servicios PESA v2.2

Módulo híbrido (laptop + tablet) que permite a los técnicos llenar digitalmente
la OS directamente desde la aplicación de escritorio, sin depender de un emulador móvil.

Estructura del formulario:
    ┌─ ENCABEZADO ──────────────────────────────────────────────────────────────┐
    │  Folio OS · Razón Social · Dirección · Fecha                              │
    ├─ BLOQUE 1: Datos del Equipo ──────────────────────────────────────────────┤
    │  ID Equipo (búsqueda inteligente) → autocompleta Marca, Modelo, N/S…      │
    ├─ BLOQUE 2: Pruebas Metrológicas ──────────────────────────────────────────┤
    │  Tablas: Repetibilidad (3 filas) · Excentricidad (6 filas) · Exactitud (10)│
    ├─ BLOQUE 3: Observaciones del Servicio ────────────────────────────────────┤
    │  QTextEdit amplio multilínea                                               │
    ├─ BLOQUE 4: Firmas Dobles (Táctil / Mouse) ────────────────────────────────┤
    │  Canvas Técnico · Canvas Cliente                                           │
    └─ BOTÓN Guardar y Finalizar Servicio ──────────────────────────────────────┘

Acceso:
    - Desde BatchGeneratorWidget → botón "Llenar Formulario Digital"
    - Desde DashboardWidget → doble clic en tabla → botón "📝 Llenar Digital"
    - Llamada directa: DigitalServiceDialog(folio_os, os_data, parent)
"""

from __future__ import annotations

import logging
import json
from datetime import date, datetime
from pathlib import Path
from typing import Optional

from PyQt6.QtCore import (
    Qt, QDate, QPoint, QPointF, QSize, pyqtSignal, QTimer
)
from PyQt6.QtGui import (
    QFont, QColor, QPainter, QPen, QPixmap, QImage, QPainterPath,
    QBrush, QLinearGradient, QCursor,
)
from PyQt6.QtWidgets import (
    QDialog, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QLineEdit, QTextEdit, QDateEdit,
    QTableWidget, QTableWidgetItem, QHeaderView, QScrollArea,
    QFrame, QSizePolicy, QMessageBox, QCompleter, QAbstractItemView,
    QGroupBox, QSplitter, QToolButton, QApplication, QTabWidget,
)

# Widgets reales de pruebas metrológicas
try:
    from ui.widgets.pruebas_metrologicas import PruebasMetrologicasWidget
    _HAS_PRUEBAS = True
except ImportError:
    _HAS_PRUEBAS = False
    PruebasMetrologicasWidget = None

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales (BD + PDF) ──────────────────────────────────────
# (Sin equipos demo — los datos de instrumentos se cargan exclusivamente desde cat_equipos en PostgreSQL)

try:
    from database.connection import db_pool as _db_pool
    _HAS_DB = True
except ImportError:
    _HAS_DB = False
    _db_pool = None


try:
    from services.os_pdf_generator import OsPdfGenerator
    _HAS_PDF = True
except ImportError:
    _HAS_PDF = False

# ─── Paleta de color PESA (consistente con el resto de la app) ────────────────
_BG      = "#F5F5F7"
_WHITE   = "#FFFFFF"
_DARK    = "#1D1D1F"
_GRAY    = "#86868B"
_LGRAY   = "#D1D5DB"
_RED     = "#E63946"
_DRED    = "#CC1F1F"
_BLUE    = "#007AFF"
_GREEN   = "#34C759"
_AMBER   = "#FF9F0A"
_SURFACE = "#F9FAFB"

# ══════════════════════════════════════════════════════════════════════════════
# DrawingCanvas — Canvas de firma táctil / mouse / lápiz óptico
# ══════════════════════════════════════════════════════════════════════════════
class DrawingCanvas(QWidget):
    """
    Widget de captura de firma libre.
    Soporta: mouse, lápiz digitalizador (tablet), pantalla táctil.
    Almacena la firma como lista de trazos (puntos QPointF).
    """
    signature_changed = pyqtSignal()   # emitido cada vez que se dibuja algo

    def __init__(self, placeholder: str = "Firme aquí", parent=None):
        super().__init__(parent)
        self._placeholder = placeholder
        self._strokes: list[list[QPointF]] = []   # cada trazo es una lista de puntos
        self._current_stroke: list[QPointF] = []
        self._drawing = False
        self._pen_width = 2.5
        self._pen_color = QColor(_DARK)

        self.setMinimumSize(320, 160)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setCursor(QCursor(Qt.CursorShape.CrossCursor))
        self.setAttribute(Qt.WidgetAttribute.WA_AcceptTouchEvents, True)
        self.setStyleSheet(f"""
            background: #FCFCFC;
            border: 2px solid {_LGRAY};
            border-radius: 10px;
        """)

    # ── Eventos de dibujo ──────────────────────────────────────────────────────
    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drawing = True
            self._current_stroke = [QPointF(event.position())]

    def mouseMoveEvent(self, event):
        if self._drawing and event.buttons() & Qt.MouseButton.LeftButton:
            self._current_stroke.append(QPointF(event.position()))
            self.update()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and self._drawing:
            self._drawing = False
            if self._current_stroke:
                self._strokes.append(self._current_stroke)
                self._current_stroke = []
                self.signature_changed.emit()

    def tabletEvent(self, event):
        """Soporte para lápiz digitalizador."""
        from PyQt6.QtCore import QEvent
        if event.type() == QEvent.Type.TabletPress:
            self._drawing = True
            self._current_stroke = [QPointF(event.position())]
        elif event.type() == QEvent.Type.TabletMove and self._drawing:
            self._current_stroke.append(QPointF(event.position()))
            self.update()
        elif event.type() == QEvent.Type.TabletRelease:
            self._drawing = False
            if self._current_stroke:
                self._strokes.append(self._current_stroke)
                self._current_stroke = []
                self.signature_changed.emit()
        event.accept()

    # ── Render ─────────────────────────────────────────────────────────────────
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Fondo suave
        painter.fillRect(self.rect(), QColor("#FCFCFC"))

        # Línea base de firma (guía)
        pen_guide = QPen(QColor("#E5E7EB"), 1, Qt.PenStyle.DashLine)
        painter.setPen(pen_guide)
        y_base = int(self.height() * 0.75)
        painter.drawLine(20, y_base, self.width() - 20, y_base)

        # Ícono de firma (si está vacío)
        if not self._strokes and not self._current_stroke:
            painter.setPen(QColor("#C7C7CC"))
            f = painter.font()
            f.setPointSize(11)
            painter.setFont(f)
            painter.drawText(
                self.rect(),
                Qt.AlignmentFlag.AlignCenter,
                f"✍  {self._placeholder}"
            )
            return

        # Trazos guardados
        pen = QPen(self._pen_color, self._pen_width, Qt.PenStyle.SolidLine,
                   Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)

        for stroke in self._strokes:
            self._draw_stroke(painter, stroke)

        # Trazo actual (en progreso)
        if self._current_stroke:
            self._draw_stroke(painter, self._current_stroke)

    @staticmethod
    def _draw_stroke(painter: QPainter, points: list[QPointF]) -> None:
        if len(points) < 2:
            if points:
                painter.drawPoint(points[0])
            return
        path = QPainterPath(points[0])
        for p in points[1:]:
            path.lineTo(p)
        painter.drawPath(path)

    # ── API pública ────────────────────────────────────────────────────────────
    def clear(self) -> None:
        """Borra todos los trazos de la firma."""
        self._strokes.clear()
        self._current_stroke.clear()
        self._drawing = False
        self.update()
        self.signature_changed.emit()

    def is_empty(self) -> bool:
        """Retorna True si no hay ningún trazo."""
        return len(self._strokes) == 0

    def to_pixmap(self, width: int = 400, height: int = 160) -> QPixmap:
        """
        Renderiza la firma en un QPixmap de tamaño fijo (para incrustar en PDF).
        Fondo blanco transparente, trazos negros.
        """
        pix = QPixmap(width, height)
        pix.fill(Qt.GlobalColor.white)
        if self.is_empty():
            return pix

        painter = QPainter(pix)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Escalar trazos al tamaño del pixmap
        sx = width  / max(self.width(),  1)
        sy = height / max(self.height(), 1)

        pen = QPen(QColor(_DARK), self._pen_width, Qt.PenStyle.SolidLine,
                   Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)

        for stroke in self._strokes:
            scaled = [QPointF(p.x() * sx, p.y() * sy) for p in stroke]
            self._draw_stroke(painter, scaled)

        painter.end()
        return pix

    def to_base64_png(self) -> str:
        """Retorna la firma como PNG en Base64 (para almacenar en BD)."""
        import base64
        pix = self.to_pixmap()
        img = pix.toImage()
        from PyQt6.QtCore import QBuffer, QByteArray, QIODevice
        buf = QBuffer()
        buf.open(QIODevice.OpenModeFlag.WriteOnly)
        img.save(buf, "PNG")
        return base64.b64encode(buf.data().data()).decode("utf-8")


# ══════════════════════════════════════════════════════════════════════════════
# MetrologicalTable — Tabla dinámica limpia para pruebas metrológicas
# ══════════════════════════════════════════════════════════════════════════════
class MetrologicalTable(QFrame):
    """
    Tabla metrológica editable de alto contraste.
    Configurable: columnas, filas predeterminadas y encabezado de sección.
    """

    def __init__(
        self,
        title:    str,
        columns:  list[str],
        rows:     int       = 5,
        color:    str       = _RED,
        parent               = None,
    ):
        super().__init__(parent)
        self._title   = title
        self._columns = columns
        self._rows    = rows
        self._color   = color
        self._build()

    def _build(self) -> None:
        self.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border: 1px solid rgba(0,0,0,0.07);
                border-radius: 12px;
            }}
        """)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # ── Cabecera de la tabla ───────────────────────────────────────────────
        header = QWidget()
        header.setStyleSheet(f"""
            background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                stop:0 {self._color}, stop:1 {self._color}CC);
            border-radius: 11px 11px 0 0;
        """)
        h_lay = QHBoxLayout(header)
        h_lay.setContentsMargins(16, 10, 12, 10)
        h_lay.setSpacing(8)

        lbl_title = QLabel(self._title)
        lbl_title.setStyleSheet(
            "color: white; font-size: 13px; font-weight: 700; "
            "letter-spacing: -0.2px; background: transparent;"
        )
        h_lay.addWidget(lbl_title)
        h_lay.addStretch()

        # Botón para agregar fila
        btn_add = QPushButton("＋ Fila")
        btn_add.setFixedHeight(26)
        btn_add.setStyleSheet("""
            QPushButton {
                background: rgba(255,255,255,0.20);
                color: white;
                border: 1px solid rgba(255,255,255,0.35);
                border-radius: 6px;
                font-size: 11px;
                font-weight: 600;
                padding: 0 10px;
            }
            QPushButton:hover {
                background: rgba(255,255,255,0.32);
            }
        """)
        btn_add.clicked.connect(self._add_row)
        h_lay.addWidget(btn_add)

        # Botón para limpiar tabla
        btn_clear = QPushButton("Limpiar")
        btn_clear.setFixedHeight(26)
        btn_clear.setStyleSheet("""
            QPushButton {
                background: transparent;
                color: rgba(255,255,255,0.70);
                border: 1px solid rgba(255,255,255,0.25);
                border-radius: 6px;
                font-size: 11px;
                padding: 0 10px;
            }
            QPushButton:hover {
                color: white;
                border-color: rgba(255,255,255,0.50);
            }
        """)
        btn_clear.clicked.connect(self.clear_data)
        h_lay.addWidget(btn_clear)
        lay.addWidget(header)

        # ── QTableWidget ──────────────────────────────────────────────────────
        self._table = QTableWidget(self._rows, len(self._columns))
        self._table.setHorizontalHeaderLabels(self._columns)
        self._table.verticalHeader().setVisible(True)
        self._table.verticalHeader().setFixedWidth(36)
        self._table.setShowGrid(True)
        self._table.setAlternatingRowColors(True)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectItems)
        self._table.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)

        hdr = self._table.horizontalHeader()
        for c in range(len(self._columns)):
            hdr.setSectionResizeMode(c, QHeaderView.ResizeMode.Stretch)

        self._table.setStyleSheet(f"""
            QTableWidget {{
                background: {_WHITE};
                alternate-background-color: #FAFBFC;
                border: none;
                border-radius: 0 0 11px 11px;
                font-size: 13px;
                gridline-color: #E5E7EB;
                selection-background-color: rgba(0,122,255,0.10);
                selection-color: {_DARK};
                outline: none;
            }}
            QTableWidget::item {{
                padding: 8px 10px;
                border-bottom: 1px solid rgba(0,0,0,0.04);
            }}
            QTableWidget::item:selected {{
                background: rgba(0,122,255,0.10);
                color: {_DARK};
            }}
            QHeaderView::section {{
                background: #F3F4F6;
                color: #374151;
                font-size: 11px;
                font-weight: 700;
                padding: 8px 10px;
                border: none;
                border-bottom: 1px solid #E5E7EB;
                border-right: 1px solid #E5E7EB;
                letter-spacing: 0.3px;
            }}
            QScrollBar:vertical {{
                width: 8px;
                background: transparent;
            }}
            QScrollBar::handle:vertical {{
                background: #D1D5DB;
                border-radius: 4px;
                min-height: 20px;
            }}
        """)
        # Estilo del header vertical (numeración)
        self._table.verticalHeader().setStyleSheet("""
            QHeaderView::section {
                background: #F3F4F6;
                color: #9CA3AF;
                font-size: 10px;
                border: none;
                border-bottom: 1px solid #E5E7EB;
                border-right: 1px solid #E5E7EB;
            }
        """)
        # Altura de filas cómoda para tablet
        self._table.verticalHeader().setDefaultSectionSize(42)

        lay.addWidget(self._table)

    # ── API pública ────────────────────────────────────────────────────────────
    def _add_row(self) -> None:
        self._table.insertRow(self._table.rowCount())

    def clear_data(self) -> None:
        for r in range(self._table.rowCount()):
            for c in range(self._table.columnCount()):
                item = self._table.item(r, c)
                if item:
                    item.setText("")

    def get_data(self) -> list[dict]:
        """Retorna los datos de la tabla como lista de dicts {col: valor}."""
        result = []
        for r in range(self._table.rowCount()):
            row_data = {}
            has_data = False
            for c, col in enumerate(self._columns):
                item = self._table.item(r, c)
                val = item.text().strip() if item else ""
                row_data[col] = val
                if val:
                    has_data = True
            if has_data:
                result.append(row_data)
        return result

    def set_row_count(self, count: int) -> None:
        self._table.setRowCount(count)

    @property
    def table_widget(self) -> QTableWidget:
        return self._table


# ══════════════════════════════════════════════════════════════════════════════
# SectionTitle — Separador visual de bloque (Apple-style)
# ══════════════════════════════════════════════════════════════════════════════
class SectionTitle(QWidget):
    def __init__(self, number: str, title: str, icon: str, color: str = _RED, parent=None):
        super().__init__(parent)
        self.setFixedHeight(52)
        self.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(12)

        # Badge numérico
        badge = QLabel(number)
        badge.setFixedSize(32, 32)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(f"""
            background: {color};
            color: white;
            font-size: 14px;
            font-weight: 800;
            border-radius: 16px;
        """)
        lay.addWidget(badge)

        # Ícono + Título
        lbl_icon = QLabel(icon)
        lbl_icon.setStyleSheet(f"font-size: 18px; color: {color}; background: transparent;")
        lay.addWidget(lbl_icon)

        lbl_text = QLabel(title)
        lbl_text.setStyleSheet(
            f"font-size: 17px; font-weight: 700; color: {_DARK}; "
            f"letter-spacing: -0.3px; background: transparent;"
        )
        lay.addWidget(lbl_text, stretch=1)

        # Línea separadora
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setStyleSheet(f"color: {color}; margin-left: 4px;")
        lay.addWidget(line, stretch=2)


# ══════════════════════════════════════════════════════════════════════════════
# DigitalServiceDialog — Dialog principal
# ══════════════════════════════════════════════════════════════════════════════
class DigitalServiceDialog(QDialog):
    """
    Formulario Digital Interactivo de Llenado de Órdenes de Servicio.

    Se abre en pantalla completa (o maximizado) y optimizado para:
      - Laptop: navegación con teclado y mouse
      - Tablet: entradas de alto contraste y Canvas táctil

    Args:
        folio_os:   Folio de la orden (ej. "OS-26-042")
        os_data:    Dict con datos de la OS (cliente, dirección, fecha, técnico, etc.)
        os_id:      ID de la OS en BD (para actualizar estado al guardar)
        parent:     Widget padre
    """

    # Señal emitida cuando el servicio se guarda correctamente
    servicio_completado = pyqtSignal(str)   # folio_os

    def __init__(
        self,
        folio_os:   str  = "",
        os_data:    dict = None,
        os_id:      int  = 0,
        id_cliente: int  = 0,   # ID del cliente en cat_clientes — para autocompletado de equipos
        parent           = None,
    ):
        super().__init__(parent)
        self._folio_os   = folio_os or "OS-??-???"
        self._os_data    = os_data or {}
        self._os_id      = os_id
        self._id_cliente = id_cliente   # filtra cat_equipos por este cliente
        self._equipos: list[dict] = []  # lista de IDs de equipos del cliente

        self.setWindowTitle(f"Formulario Digital  —  {self._folio_os}  |  Servicios PESA")
        self.setModal(True)

        # ── Pantalla completa / maximizado ────────────────────────────────────
        self.showMaximized()
        self.setMinimumSize(1000, 700)

        self._build_ui()
        self._apply_styles()
        self._load_equipos()
        self._prefill_from_os_data()

    # ══════════════════════════════════════════════════════════════════════════
    # BUILD UI
    # ══════════════════════════════════════════════════════════════════════════

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # ── Top Bar ───────────────────────────────────────────────────────────
        root.addWidget(self._build_topbar())

        # ── Área de scroll (contenido del formulario) ─────────────────────────
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet(f"background: {_BG}; border: none;")
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        content = QWidget()
        content.setStyleSheet(f"background: {_BG};")
        self._content_lay = QVBoxLayout(content)
        self._content_lay.setContentsMargins(40, 28, 40, 32)
        self._content_lay.setSpacing(28)

        # Bloques del formulario
        self._content_lay.addWidget(self._build_block_header())
        self._content_lay.addWidget(SectionTitle("1", "Datos del Instrumento", "⚙", _RED))
        self._content_lay.addWidget(self._build_block_equipo())
        self._content_lay.addWidget(SectionTitle("2", "Pruebas Metrológicas", "📊", _BLUE))
        self._content_lay.addWidget(self._build_block_pruebas())
        self._content_lay.addWidget(SectionTitle("3", "Observaciones del Servicio", "📋", "#8B5CF6"))
        self._content_lay.addWidget(self._build_block_observaciones())
        self._content_lay.addWidget(SectionTitle("4", "Firmas Digitales", "✍", _GREEN))
        self._content_lay.addWidget(self._build_block_firmas())
        self._content_lay.addSpacing(16)

        scroll.setWidget(content)
        # Permitir deslizado vertical fluido con dedo o trackpad
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        root.addWidget(scroll, stretch=1)

        # ── Bottom Bar (botón guardar) ─────────────────────────────────────────
        root.addWidget(self._build_bottombar())

    # ── TOP BAR ───────────────────────────────────────────────────────────────

    def _build_topbar(self) -> QWidget:
        bar = QFrame()
        bar.setObjectName("topbar")
        bar.setFixedHeight(64)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(28, 0, 24, 0)
        lay.setSpacing(16)

        # Ícono + identidad
        lbl_icon = QLabel("📝")
        lbl_icon.setStyleSheet("font-size: 24px; background: transparent;")
        lay.addWidget(lbl_icon)

        col = QVBoxLayout()
        col.setSpacing(1)
        lbl_folio = QLabel(f"Formulario Digital — {self._folio_os}")
        lbl_folio.setObjectName("topbar_folio")
        lbl_sub = QLabel("Servicios PESA  ·  Llenado Directo Laptop / Tablet")
        lbl_sub.setObjectName("topbar_sub")
        col.addWidget(lbl_folio)
        col.addWidget(lbl_sub)
        lay.addLayout(col, stretch=1)

        # Badge de estado
        self._lbl_estado = QLabel("  EN LLENADO  ")
        self._lbl_estado.setObjectName("badge_estado")
        lay.addWidget(self._lbl_estado)

        # Botón cerrar
        btn_close = QPushButton("✕")
        btn_close.setObjectName("btn_topbar_close")
        btn_close.setFixedSize(32, 32)
        btn_close.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_close.clicked.connect(self._on_close_requested)
        lay.addWidget(btn_close)

        return bar

    # ── BLOQUE ENCABEZADO ─────────────────────────────────────────────────────

    def _build_block_header(self) -> QFrame:
        card = self._make_card()
        lay = QGridLayout(card)
        lay.setContentsMargins(24, 20, 24, 20)
        lay.setSpacing(14)
        lay.setColumnStretch(0, 2)
        lay.setColumnStretch(1, 2)
        lay.setColumnStretch(2, 1)

        # Folio (solo lectura)
        lay.addWidget(self._field_label("Folio OS"), 0, 0)
        self._lbl_folio = QLabel(self._folio_os)
        self._lbl_folio.setObjectName("folio_display")
        lay.addWidget(self._lbl_folio, 1, 0)

        # Razón Social (solo lectura)
        lay.addWidget(self._field_label("Razón Social / Cliente"), 0, 1)
        self._lbl_cliente = QLabel("—")
        self._lbl_cliente.setObjectName("readonly_field")
        self._lbl_cliente.setWordWrap(True)
        lay.addWidget(self._lbl_cliente, 1, 1)

        # Fecha (editable)
        lay.addWidget(self._field_label("Fecha del Servicio"), 0, 2)
        self._dte_fecha = QDateEdit()
        self._dte_fecha.setObjectName("date_field")
        self._dte_fecha.setCalendarPopup(True)
        self._dte_fecha.setDate(QDate.currentDate())
        self._dte_fecha.setDisplayFormat("dd / MM / yyyy")
        self._dte_fecha.setFixedHeight(44)   # touch-friendly
        lay.addWidget(self._dte_fecha, 1, 2)

        # Dirección
        lay.addWidget(self._field_label("Dirección del Servicio"), 2, 0, 1, 3)
        self._lbl_direccion = QLabel("—")
        self._lbl_direccion.setObjectName("readonly_field")
        self._lbl_direccion.setWordWrap(True)
        lay.addWidget(self._lbl_direccion, 3, 0, 1, 3)

        # Técnico asignado
        lay.addWidget(self._field_label("Técnico Responsable"), 4, 0, 1, 2)
        self._lbl_tecnico = QLabel("—")
        self._lbl_tecnico.setObjectName("readonly_field")
        lay.addWidget(self._lbl_tecnico, 5, 0, 1, 2)

        return card

    # ── BLOQUE 1: Equipo ──────────────────────────────────────────────────────

    def _build_block_equipo(self) -> QFrame:
        card = self._make_card()
        lay = QGridLayout(card)
        lay.setContentsMargins(24, 20, 24, 20)
        lay.setSpacing(14)

        # ── Buscador inteligente por ID / N/S ─────────────────────────────────
        lay.addWidget(self._field_label("ID del Instrumento (buscar por ID, N/S, marca o modelo)"), 0, 0, 1, 3)

        search_row = QHBoxLayout()
        self._inp_equipo_id = QLineEdit()
        self._inp_equipo_id.setObjectName("input_field")
        self._inp_equipo_id.setPlaceholderText("Ej: 01  ·  BASC-02  ·  EQ-007…")
        self._inp_equipo_id.setFixedHeight(44)
        # Auto-completado inmediato al salir del campo
        self._inp_equipo_id.editingFinished.connect(self._on_equipo_id_finished)
        self._inp_equipo_id.textChanged.connect(self._on_equipo_search)
        search_row.addWidget(self._inp_equipo_id, stretch=1)

        btn_buscar = QPushButton("🔍  Buscar")
        btn_buscar.setObjectName("btn_secondary")
        btn_buscar.setFixedHeight(44)
        btn_buscar.clicked.connect(self._buscar_equipo)
        search_row.addWidget(btn_buscar)
        lay.addLayout(search_row, 1, 0, 1, 3)

        # ── Campos editables (se autocompletan con búsqueda, pero editables) ──
        _inp_style = (
            f"QLineEdit {{ background: {_SURFACE}; border: 1.5px solid {_LGRAY}; "
            f"border-radius: 8px; padding: 7px 12px; font-size: 13px; color: {_DARK}; "
            f"min-height: 36px; }}"
            f"QLineEdit:focus {{ border-color: {_RED}; background: #FFFFFF; }}"
        )

        campos = [
            ("Marca",             "_inp_eq_marca",    0, 0, "Ej: METTLER TOLEDO"),
            ("Modelo",            "_inp_eq_modelo",   0, 1, "Ej: IND560"),
            ("Capacidad Máxima",  "_inp_eq_alcance",  0, 2, "Ej: 500 kg"),
            ("División Mínima",   "_inp_eq_division", 1, 0, "Ej: 50 g"),
            ("N° de Serie",       "_inp_eq_ns",       1, 1, "Ej: B215004321"),
            ("Ubicación",         "_inp_eq_ubicacion",1, 2, "Ej: Planta Norte — Báscula #1"),
        ]
        for label_txt, attr, grid_r, grid_c, placeholder in campos:
            row_base = 2 + grid_r * 2
            lay.addWidget(self._field_label(label_txt), row_base, grid_c)
            inp = QLineEdit()
            inp.setObjectName("input_field")
            inp.setPlaceholderText(placeholder)
            inp.setFixedHeight(40)
            inp.setStyleSheet(_inp_style)
            setattr(self, attr, inp)
            lay.addWidget(inp, row_base + 1, grid_c)

        return card

    # ── BLOQUE 2: Pruebas Metrológicas ────────────────────────────────────────

    def _build_block_pruebas(self) -> QWidget:
        """
        Bloque 2: Pruebas Metrológicas en formato de 3 pestañas.
        Elimina el layout horizontal que colapsaba las tablas en pantallas pequeñas.
        """
        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(container)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        if _HAS_PRUEBAS:
            # ── Widget completo usando QTabWidget para evitar colapso horizontal ──
            tabs = QTabWidget()
            tabs.setDocumentMode(True)
            tabs.setStyleSheet(f"""
                QTabWidget::pane {{
                    border: 1px solid rgba(0,0,0,0.08);
                    border-radius: 0 12px 12px 12px;
                    background: {_WHITE};
                }}
                QTabBar::tab {{
                    background: #F3F4F6;
                    color: {_GRAY};
                    border: none;
                    padding: 10px 22px;
                    font-size: 13px;
                    font-weight: 600;
                    margin-right: 2px;
                    border-radius: 8px 8px 0 0;
                    min-width: 120px;
                }}
                QTabBar::tab:selected {{
                    background: {_WHITE};
                    color: {_DARK};
                    border-bottom: 2px solid {_RED};
                }}
                QTabBar::tab:hover:!selected {{
                    background: #EAECEF;
                }}
            """)

            # Importar sub-widgets individuales
            try:
                from ui.widgets.pruebas_metrologicas import (
                    RepetibilidadWidget,
                    ExcentricidadCondicionalWidget,
                    ExactitudWidget,
                )

                # ① Pestaña Repetibilidad
                self._w_repetibilidad = RepetibilidadWidget()
                self._w_repetibilidad.clear()      # elimina valores -9999998.xxx
                wrap_rep = QWidget()
                wrap_rep.setStyleSheet(f"background: {_WHITE};")
                l_rep = QVBoxLayout(wrap_rep)
                l_rep.setContentsMargins(16, 16, 16, 16)
                l_rep.addWidget(self._w_repetibilidad)
                tabs.addTab(wrap_rep, "📏  Repetibilidad")

                # ② Pestaña Excentricidad
                self._w_excentricidad = ExcentricidadCondicionalWidget()
                self._w_excentricidad.clear()
                wrap_exc = QWidget()
                wrap_exc.setStyleSheet(f"background: {_WHITE};")
                l_exc = QVBoxLayout(wrap_exc)
                l_exc.setContentsMargins(16, 16, 16, 16)
                l_exc.addWidget(self._w_excentricidad)
                tabs.addTab(wrap_exc, "⬡  Excentricidad")

                # ③ Pestaña Exactitud
                self._w_exactitud = ExactitudWidget()
                self._w_exactitud.clear()
                wrap_exac = QWidget()
                wrap_exac.setStyleSheet(f"background: {_WHITE};")
                l_exac = QVBoxLayout(wrap_exac)
                l_exac.setContentsMargins(16, 16, 16, 16)
                l_exac.addWidget(self._w_exactitud)
                tabs.addTab(wrap_exac, "✔  Exactitud")

                # Referencia global al widget de tabs para get_all_data()
                self._pruebas_widget = None   # se usa _w_repetibilidad/_w_excentricidad/_w_exactitud
                self._pruebas_tabs   = tabs
                self._uses_tab_mode  = True

            except ImportError:
                # Fallback si no se pueden importar sub-widgets individuales
                from ui.widgets.pruebas_metrologicas import PruebasMetrologicasWidget
                self._pruebas_widget = PruebasMetrologicasWidget()
                self._pruebas_widget.clear()
                self._pruebas_tabs   = None
                self._uses_tab_mode  = False
                wrap_all = QWidget()
                wrap_all.setStyleSheet(f"background: {_WHITE};")
                l_all = QVBoxLayout(wrap_all)
                l_all.setContentsMargins(16, 16, 16, 16)
                l_all.addWidget(self._pruebas_widget)
                tabs.addTab(wrap_all, "📊  Pruebas")

            tabs.setMinimumHeight(420)
            lay.addWidget(tabs)

        else:
            # Fallback mínimo sin pruebas_metrologicas.py
            self._pruebas_widget = None
            self._pruebas_tabs   = None
            self._uses_tab_mode  = False
            for title, cols, nrows, color in [
                ("Repetibilidad",
                 ["N", "VALOR (kg)", "LECTURA INICIAL", "LECTURA FINAL", "ERR. MÁX. TOL."],
                 3, _RED),
                ("Excentricidad",
                 ["POSICIÓN", "LECTURA INICIAL", "LECTURA FINAL"],
                 6, _BLUE),
                ("Exactitud",
                 ["N", "VALOR NOMINAL", "LECTURA INICIAL", "LECTURA FINAL"],
                 10, "#8B5CF6"),
            ]:
                tbl = MetrologicalTable(title=title, columns=cols, rows=nrows, color=color)
                lay.addWidget(tbl)

        return container

    # ── BLOQUE 3: Observaciones ───────────────────────────────────────────────

    def _build_block_observaciones(self) -> QFrame:
        card = self._make_card()
        lay = QVBoxLayout(card)
        lay.setContentsMargins(24, 20, 24, 20)
        lay.setSpacing(12)

        row_top = QHBoxLayout()
        row_top.addWidget(self._field_label("Observaciones, Trabajos Realizados y Notas Técnicas"))
        row_top.addStretch()

        lbl_hint = QLabel("Ej: sustitución de celda de carga, ajuste de span, limpieza de plataforma…")
        lbl_hint.setStyleSheet(f"color: {_GRAY}; font-size: 11px; background: transparent;")
        row_top.addWidget(lbl_hint)
        lay.addLayout(row_top)

        self._txt_observaciones = QTextEdit()
        self._txt_observaciones.setObjectName("txt_observaciones")
        self._txt_observaciones.setPlaceholderText(
            "Describa aquí de forma detallada los trabajos realizados:\n"
            "• Componentes sustituidos (marca, modelo, n/s)\n"
            "• Ajustes o calibraciones efectuadas\n"
            "• Estado general del equipo\n"
            "• Recomendaciones para el cliente\n"
            "• Cualquier anomalía detectada…"
        )
        self._txt_observaciones.setMinimumHeight(160)
        lay.addWidget(self._txt_observaciones)

        return card

    # ── BLOQUE 4: Firmas ──────────────────────────────────────────────────────

    def _build_block_firmas(self) -> QWidget:
        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(container)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(20)

        lay.addWidget(self._build_firma_card(
            title         = "Firma del Técnico Responsable",
            subtitle      = "Técnico de Servicios PESA",
            attr_name     = "_canvas_tecnico",
            name_attr     = "_inp_nombre_tecnico",
            icon          = "🔧",
            color         = _RED,
            name_label    = "Nombre del Técnico Responsable",
            name_required = False,
        ), stretch=1)

        lay.addWidget(self._build_firma_card(
            title         = "Firma del Cliente / Usuario en Planta",
            subtitle      = "Representante del cliente que recibió el servicio",
            attr_name     = "_canvas_cliente",
            name_attr     = "_inp_nombre_cliente",
            icon          = "🏭",
            color         = _BLUE,
            name_label    = "Nombre del Usuario / Representante del Cliente",
            name_required = True,
        ), stretch=1)

        return container

    def _build_firma_card(
        self,
        title:      str,
        subtitle:   str,
        attr_name:  str,
        name_attr:  str,
        icon:       str,
        color:      str,
        name_label: str = "Nombre completo",
        name_required: bool = False,
    ) -> QFrame:
        card = self._make_card()
        lay = QVBoxLayout(card)
        lay.setContentsMargins(20, 18, 20, 18)
        lay.setSpacing(10)

        # Encabezado de la firma
        top = QHBoxLayout()
        lbl_icon = QLabel(icon)
        lbl_icon.setStyleSheet(f"font-size: 20px; color: {color}; background: transparent;")
        top.addWidget(lbl_icon)

        col_info = QVBoxLayout()
        col_info.setSpacing(1)
        lbl_title = QLabel(title)
        lbl_title.setStyleSheet(
            f"font-size: 14px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        lbl_sub = QLabel(subtitle)
        lbl_sub.setStyleSheet(f"font-size: 11px; color: {_GRAY}; background: transparent;")
        col_info.addWidget(lbl_title)
        col_info.addWidget(lbl_sub)
        top.addLayout(col_info, stretch=1)
        lay.addLayout(top)

        # Separador
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet(f"color: {color}30; margin: 2px 0;")
        lay.addWidget(sep)

        # ── Campo de nombre (obligatorio para cliente) ─────────────────────────
        req_marker = "  *" if name_required else ""
        lbl_name = QLabel(f"{name_label}{req_marker}")
        lbl_name.setStyleSheet(
            f"font-size: 10px; font-weight: 700; color: {_GRAY}; "
            f"letter-spacing: 0.4px; background: transparent;"
        )
        lay.addWidget(lbl_name)

        inp_name = QLineEdit()
        inp_name.setObjectName("input_field")
        inp_name.setPlaceholderText(f"Ingrese {name_label.lower()}…")
        inp_name.setFixedHeight(38)
        inp_name.setStyleSheet(
            f"QLineEdit {{ background: {_SURFACE}; border: 1.5px solid {_LGRAY}; "
            f"border-radius: 8px; padding: 6px 12px; font-size: 13px; color: {_DARK}; }}"
            f"QLineEdit:focus {{ border-color: {color}; background: #FFFFFF; }}"
        )
        setattr(self, name_attr, inp_name)
        lay.addWidget(inp_name)

        # Canvas de firma
        canvas = DrawingCanvas(placeholder="Firme aquí con mouse, lápiz o dedo…")
        canvas.setMinimumHeight(180)
        setattr(self, attr_name, canvas)
        lay.addWidget(canvas, stretch=1)

        # Indicador + botón limpiar
        bottom = QHBoxLayout()
        lbl_status = QLabel("○  Sin firma")
        lbl_status.setStyleSheet(f"font-size: 11px; color: {_GRAY}; background: transparent;")

        def _update_status(lbl=lbl_status, c=canvas, col=color):
            if c.is_empty():
                lbl.setText("○  Sin firma")
                lbl.setStyleSheet(f"font-size: 11px; color: {_GRAY}; background: transparent;")
            else:
                lbl.setText("●  Firma capturada")
                lbl.setStyleSheet(f"font-size: 11px; color: {col}; font-weight: 600; background: transparent;")

        canvas.signature_changed.connect(_update_status)
        bottom.addWidget(lbl_status, stretch=1)

        btn_clear = QPushButton("🗑  Limpiar Firma")
        btn_clear.setObjectName("btn_clear_sig")
        btn_clear.setFixedHeight(30)
        btn_clear.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_clear.clicked.connect(canvas.clear)
        bottom.addWidget(btn_clear)
        lay.addLayout(bottom)

        return card

    # ── BOTTOM BAR ────────────────────────────────────────────────────────────

    def _build_bottombar(self) -> QFrame:
        bar = QFrame()
        bar.setObjectName("bottombar")
        bar.setFixedHeight(72)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(40, 0, 40, 0)
        lay.setSpacing(14)

        # Info del folio
        col_info = QVBoxLayout()
        col_info.setSpacing(1)
        lbl_saving = QLabel(f"OS  {self._folio_os}")
        lbl_saving.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        lbl_hint = QLabel("Al guardar se cambiará el estado a COMPLETADA_DIGITAL y se generará el PDF final.")
        lbl_hint.setStyleSheet(f"font-size: 11px; color: {_GRAY}; background: transparent;")
        col_info.addWidget(lbl_saving)
        col_info.addWidget(lbl_hint)
        lay.addLayout(col_info, stretch=1)

        # Botón cancelar
        btn_cancel = QPushButton("Cancelar")
        btn_cancel.setObjectName("btn_cancel")
        btn_cancel.setFixedHeight(44)
        btn_cancel.setFixedWidth(110)
        btn_cancel.clicked.connect(self._on_close_requested)
        lay.addWidget(btn_cancel)

        # Botón guardar
        self._btn_save = QPushButton("💾   Guardar y Finalizar Servicio")
        self._btn_save.setObjectName("btn_save")
        self._btn_save.setFixedHeight(44)
        self._btn_save.setMinimumWidth(280)
        self._btn_save.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_save.clicked.connect(self._on_guardar)
        lay.addWidget(self._btn_save)

        return bar

    # ══════════════════════════════════════════════════════════════════════════
    # ESTILOS
    # ══════════════════════════════════════════════════════════════════════════

    def _apply_styles(self) -> None:
        self.setStyleSheet(f"""
            QDialog {{
                background: {_BG};
            }}
            QFrame#topbar {{
                background: {_WHITE};
                border-bottom: 1.5px solid rgba(0,0,0,0.08);
            }}
            QLabel#topbar_folio {{
                font-size: 16px;
                font-weight: 700;
                color: {_DARK};
                letter-spacing: -0.3px;
                background: transparent;
            }}
            QLabel#topbar_sub {{
                font-size: 11px;
                color: {_GRAY};
                background: transparent;
            }}
            QLabel#badge_estado {{
                background: rgba(230,57,70,0.09);
                color: {_RED};
                font-size: 11px;
                font-weight: 700;
                border-radius: 6px;
                padding: 4px 10px;
                letter-spacing: 0.5px;
            }}
            QPushButton#btn_topbar_close {{
                background: rgba(0,0,0,0.05);
                color: {_GRAY};
                border: none;
                border-radius: 16px;
                font-size: 14px;
                font-weight: 600;
            }}
            QPushButton#btn_topbar_close:hover {{
                background: rgba(230,57,70,0.12);
                color: {_RED};
            }}
            QFrame#bottombar {{
                background: {_WHITE};
                border-top: 1.5px solid rgba(0,0,0,0.08);
            }}
            QLabel#folio_display {{
                font-size: 22px;
                font-weight: 800;
                color: {_RED};
                letter-spacing: -0.5px;
                background: transparent;
            }}
            QLabel#readonly_field {{
                font-size: 14px;
                font-weight: 500;
                color: {_DARK};
                background: #F3F4F6;
                border: 1px solid #E5E7EB;
                border-radius: 8px;
                padding: 8px 12px;
                min-height: 20px;
            }}
            QLabel#readonly_field_filled {{
                font-size: 14px;
                font-weight: 600;
                color: #1D4ED8;
                background: #EBF5FF;
                border: 1px solid #BFDBFE;
                border-radius: 8px;
                padding: 8px 12px;
                min-height: 20px;
            }}
            QLineEdit#input_field {{
                background: {_WHITE};
                border: 1.5px solid {_LGRAY};
                border-radius: 8px;
                padding: 0 12px;
                font-size: 14px;
                color: {_DARK};
                selection-background-color: rgba(0,122,255,0.15);
            }}
            QLineEdit#input_field:focus {{
                border-color: {_RED};
                background: #FFFBFB;
            }}
            QDateEdit#date_field {{
                background: {_WHITE};
                border: 1.5px solid {_LGRAY};
                border-radius: 8px;
                padding: 0 12px;
                font-size: 14px;
                color: {_DARK};
            }}
            QDateEdit#date_field:focus {{
                border-color: {_RED};
            }}
            QDateEdit::drop-down {{
                border: none;
                width: 24px;
            }}
            QTextEdit#txt_observaciones {{
                background: {_WHITE};
                border: 1.5px solid {_LGRAY};
                border-radius: 10px;
                padding: 12px;
                font-size: 14px;
                color: {_DARK};
            }}
            QTextEdit#txt_observaciones:focus {{
                border-color: #8B5CF6;
            }}
            QPushButton#btn_secondary {{
                background: {_SURFACE};
                border: 1.5px solid {_LGRAY};
                border-radius: 8px;
                color: {_DARK};
                font-size: 13px;
                font-weight: 600;
                padding: 0 16px;
            }}
            QPushButton#btn_secondary:hover {{
                background: #E5E7EB;
                border-color: #9CA3AF;
            }}
            QPushButton#btn_clear_sig {{
                background: transparent;
                border: 1px solid #E5E7EB;
                border-radius: 6px;
                color: {_GRAY};
                font-size: 11px;
                padding: 0 10px;
            }}
            QPushButton#btn_clear_sig:hover {{
                background: #FEF2F2;
                border-color: {_RED};
                color: {_RED};
            }}
            QPushButton#btn_cancel {{
                background: {_WHITE};
                border: 1.5px solid {_LGRAY};
                border-radius: 10px;
                color: {_GRAY};
                font-size: 13px;
            }}
            QPushButton#btn_cancel:hover {{
                background: #F9FAFB;
                border-color: #9CA3AF;
                color: {_DARK};
            }}
            QPushButton#btn_save {{
                background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                    stop:0 {_RED}, stop:1 {_DRED});
                color: white;
                border: none;
                border-radius: 10px;
                font-size: 14px;
                font-weight: 700;
                letter-spacing: -0.2px;
            }}
            QPushButton#btn_save:hover {{
                background: {_DRED};
            }}
            QPushButton#btn_save:pressed {{
                background: #AA1515;
            }}
            QPushButton#btn_save:disabled {{
                background: #D1D5DB;
                color: {_GRAY};
            }}
        """)

    # ══════════════════════════════════════════════════════════════════════════
    # HELPERS
    # ══════════════════════════════════════════════════════════════════════════

    @staticmethod
    def _make_card() -> QFrame:
        card = QFrame()
        card.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border: 1px solid rgba(0,0,0,0.07);
                border-radius: 14px;
            }}
        """)
        return card

    @staticmethod
    def _field_label(text: str) -> QLabel:
        lbl = QLabel(text.upper())
        lbl.setStyleSheet(
            f"font-size: 10px; font-weight: 700; color: {_GRAY}; "
            f"letter-spacing: 0.5px; background: transparent;"
        )
        return lbl

    # ══════════════════════════════════════════════════════════════════════════
    # PRE-FILL desde os_data
    # ══════════════════════════════════════════════════════════════════════════

    def _prefill_from_os_data(self) -> None:
        """Rellena los campos de encabezado con los datos de la OS."""
        d = self._os_data

        cliente = d.get("cliente") or d.get("razon_social") or "—"
        self._lbl_cliente.setText(str(cliente))

        direccion = d.get("direccion_cliente") or d.get("direccion") or "—"
        self._lbl_direccion.setText(str(direccion))

        tecnico = d.get("tecnico_nombre") or d.get("tecnico") or "—"
        self._lbl_tecnico.setText(str(tecnico))

        # Fecha
        if "fecha" in d and d["fecha"]:
            try:
                f = d["fecha"]
                if isinstance(f, str):
                    f = date.fromisoformat(f[:10])
                if isinstance(f, date):
                    self._dte_fecha.setDate(QDate(f.year, f.month, f.day))
            except Exception:
                pass

        # Observaciones previas (si las hay)
        obs = d.get("observaciones_tecnico") or d.get("observaciones") or ""
        if obs:
            self._txt_observaciones.setText(str(obs))

        # ── Aplicar reglas metrológicas condicionales (Regla 6 / Tablet) ──────
        # Se ejecutan después de poblar el encabezado para que los widgets
        # de pruebas ya estén construidos y disponibles.
        QTimer.singleShot(0, self._aplicar_reglas_metrologicas)

    def _aplicar_reglas_metrologicas(self) -> None:
        """
        Aplica las 3 reglas de negocio metrológicas al formulario digital:

        R1: Si el servicio NO tiene calibración → deshabilitar CCA e Inicial J/I/A.
        R3A: Si el instrumento NO aplica excentricidad → bloquear pestaña
             de excentricidad y mostrar tarjeta NO APTO.
        R3B: Si la geometría es 'Libre' → marcar bandera para validar antes de firmar.
        """
        d = self._os_data

        # ── R1: CCA e Inicial condicional ─────────────────────────────────────
        try:
            from services.tipo_servicio_rules import pide_cca
            id_ts = d.get("id_tipo_servicio")
            nombre_ts = str(d.get("tipo_servicio_nombre") or d.get("tipo_servicio") or "")
            if id_ts is not None:
                _requiere_cca = pide_cca(int(id_ts))
            else:
                _norm = nombre_ts.lower()
                for ch, rep in [("á","a"),("é","e"),("í","i"),("ó","o"),("ú","u")]:
                    _norm = _norm.replace(ch, rep)
                _requiere_cca = "calibraci" in _norm
            logger.debug("[TABLET R1] tipo_servicio=%r id=%s → requiere_cca=%s",
                         nombre_ts, id_ts, _requiere_cca)
            # Si el widget de Exactitud expone set_cca_visible, usarlo
            if hasattr(self, '_w_exactitud') and self._w_exactitud is not None:
                if hasattr(self._w_exactitud, 'set_cca_visible'):
                    self._w_exactitud.set_cca_visible(_requiere_cca)
            # Ocultar pestañas marcadas como 'cca'
            if hasattr(self, '_pruebas_tabs') and self._pruebas_tabs:
                for idx in range(self._pruebas_tabs.count()):
                    if not _requiere_cca and "cca" in self._pruebas_tabs.tabText(idx).lower():
                        self._pruebas_tabs.setTabVisible(idx, False)
        except Exception as e_r1:
            logger.warning("[TABLET R1] Error aplicando regla CCA: %s", e_r1)

        # ── R3A: Bloquear excentricidad si instrumento no apto ────────────────
        try:
            aplica_exc_raw = d.get("aplica_excentricidad", True)
            if isinstance(aplica_exc_raw, bool):
                aplica_exc = aplica_exc_raw
            elif isinstance(aplica_exc_raw, int):
                aplica_exc = bool(aplica_exc_raw)
            elif isinstance(aplica_exc_raw, str):
                aplica_exc = aplica_exc_raw.strip().upper() not in ("NO", "N", "0", "FALSE")
            else:
                aplica_exc = True

            logger.debug("[TABLET R3A] aplica_excentricidad=%s", aplica_exc)

            if not aplica_exc and hasattr(self, '_pruebas_tabs') and self._pruebas_tabs:
                for idx in range(self._pruebas_tabs.count()):
                    tab_text = self._pruebas_tabs.tabText(idx)
                    if "excentricidad" in tab_text.lower() or "exc" in tab_text.lower():
                        self._pruebas_tabs.setTabEnabled(idx, False)
                        tipo_no = str(d.get("tipo_no_aplica_exc") or d.get("tipo_instrumento") or "")
                        self._pruebas_tabs.setTabToolTip(
                            idx,
                            f"Instrumento NO APTO para prueba de excentricidad ({tipo_no}). "
                            "Ver NOM-010-SCFI-2020."
                        )
                        # Insertar aviso visual dentro de la pestaña
                        tab_widget = self._pruebas_tabs.widget(idx)
                        if tab_widget is not None and tab_widget.layout():
                            from PyQt6.QtWidgets import QLabel as _QL
                            lbl_no = _QL(
                                f"⚠️  INSTRUMENTO NO APTO PARA PRUEBA DE EXCENTRICIDAD\n"
                                f"Tipo: {tipo_no}\n"
                                "(NOM-010-SCFI-2020: geometría variable inhabilita la prueba)"
                            )
                            lbl_no.setAlignment(Qt.AlignmentFlag.AlignCenter)
                            lbl_no.setStyleSheet(
                                "font-size: 14px; font-weight: 700; color: #C8102E; "
                                "padding: 32px; background: #FFF0F0; border-radius: 12px; "
                                "border: 2px solid #FFCCCC;"
                            )
                            lbl_no.setWordWrap(True)
                            tab_widget.layout().insertWidget(0, lbl_no)
                        logger.info("[TABLET R3A] Pestaña excentricidad bloqueada (NO APTO)")
                        break

            # ── R3B: Excentricidad Libre → bandera para validar antes de firmar ──
            if aplica_exc:
                geo = str(d.get("geometria_plataforma") or "").strip().lower()
                for ch, rep in [("á","a"),("é","e"),("í","i"),("ó","o"),("ú","u")]:
                    geo = geo.replace(ch, rep)
                es_libre = (not geo or geo == "libre")
                self._geo_libre_pendiente = es_libre
                if es_libre:
                    logger.info("[TABLET R3B] Geometría Libre: se requerirá selección "
                                "de tipo de receptor antes de la firma digital.")
                    if hasattr(self, '_pruebas_tabs') and self._pruebas_tabs:
                        for idx in range(self._pruebas_tabs.count()):
                            tab_text = self._pruebas_tabs.tabText(idx)
                            if "excentricidad" in tab_text.lower():
                                self._pruebas_tabs.setTabText(idx, tab_text + "  ⚠")
                                self._pruebas_tabs.setTabToolTip(
                                    idx,
                                    "Geometría LIBRE: selecciona el tipo de receptor "
                                    "(Circular / Plataforma / Camionera) antes de firmar."
                                )
                                break
            else:
                self._geo_libre_pendiente = False
        except Exception as e_r3:
            logger.warning("[TABLET R3] Error aplicando reglas de excentricidad: %s", e_r3)


    # ══════════════════════════════════════════════════════════════════════════
    # BÚSQUEDA DE EQUIPOS — nueva lógica por cliente + id_equipo_interno
    # ══════════════════════════════════════════════════════════════════════════

    def _load_equipos(self) -> None:
        """
        Carga los IDs de equipos registrados para este cliente desde cat_equipos.
        Usa EquipoRepository.ids_de_cliente(id_cliente) si hay BD.
        """
        ids: list[str] = []
        if _HAS_DB and self._id_cliente:
            try:
                from models.catalogo import equipo_repo
                ids = equipo_repo.ids_de_cliente(self._id_cliente)
                logger.debug("Equipos cargados para cliente %d: %d registros",
                             self._id_cliente, len(ids))
            except Exception as exc:
                logger.warning("Error cargando equipos de cliente: %s", exc)

        # Sin datos en BD o sin cliente asignado: IDs vacíos (no hay demo)
        self._equipo_ids = ids
        self._setup_equipo_completer()

    def _setup_equipo_completer(self) -> None:
        """Configura el QCompleter con los IDs de equipos del cliente actual."""
        ids = getattr(self, "_equipo_ids", [])
        if not ids:
            return
        completer = QCompleter(ids, self)
        completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        completer.setFilterMode(Qt.MatchFlag.MatchContains)
        completer.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
        self._inp_equipo_id.setCompleter(completer)

    def _on_equipo_id_finished(self) -> None:
        """
        Se ejecuta cuando el usuario sale del campo ID del Equipo (editingFinished).
        Consulta cat_equipos filtrado por (id_cliente, id_equipo_interno) y
        autocompleta los campos si encuentra coincidencia.
        """
        id_equipo = self._inp_equipo_id.text().strip()
        if not id_equipo or not self._id_cliente:
            return

        if _HAS_DB:
            try:
                from models.catalogo import equipo_repo
                eq = equipo_repo.lookup(self._id_cliente, id_equipo)
                if eq:
                    self._fill_equipo(eq)
                    return
            except Exception as exc:
                logger.warning("Error en lookup de equipo: %s", exc)
        else:
            # Sin BD: sin historial de equipos, simplemente no autocompleta
            pass

    def _on_equipo_search(self, text: str) -> None:
        """Búsqueda en tiempo real (solo sin BD)."""
        if _HAS_DB:
            return  # con BD se usa editingFinished para no saturar la BD
        # Sin BD: sin datos de referencia, no se hace nada

    def _buscar_equipo(self) -> None:
        """Búsqueda explícita al pulsar el botón. Funciona igual que editingFinished."""
        self._on_equipo_id_finished()
        id_equipo = self._inp_equipo_id.text().strip()
        # Si no rellenó nada (equipo nuevo), avisar con opción de registrar
        if id_equipo and not self._inp_eq_marca.text().strip():
            reply = QMessageBox.question(
                self,
                "Equipo no registrado",
                f"El ID '{id_equipo}' no existe en el historial de este cliente.\n\n"
                "Al guardar el formulario se registrará automáticamente en el catálogo.",
                QMessageBox.StandardButton.Ok,
            )

    def _fill_equipo(self, eq: dict) -> None:
        """
        Autocompleta los campos del instrumento con los datos del catálogo.
        Mapea tanto las claves de cat_equipos (nueva estructura) como
        las claves del formato demo (herencia).
        """
        def _v(keys):
            """Retorna el primer valor no-vacío entre las claves dadas."""
            for k in keys:
                v = eq.get(k)
                if v not in (None, ""):
                    return str(v)
            return ""

        self._inp_eq_marca.setText(_v(["marca"]))
        self._inp_eq_modelo.setText(_v(["modelo"]))
        self._inp_eq_alcance.setText(_v(["alcance_max", "alcance"]))
        self._inp_eq_division.setText(_v(["div_minima", "division"]))
        self._inp_eq_ns.setText(_v(["ns"]))
        self._inp_eq_ubicacion.setText(_v(["ubicacion"]))

        # Feedback visual breve
        self._inp_eq_marca.setStyleSheet(
            self._inp_eq_marca.styleSheet() +
            " QLineEdit { border-color: #34C759; }"
        )
        from PyQt6.QtCore import QTimer
        QTimer.singleShot(1500, lambda: self._inp_eq_marca.setStyleSheet(""))


    # ══════════════════════════════════════════════════════════════════════════
    # GUARDAR Y FINALIZAR
    # ══════════════════════════════════════════════════════════════════════════

    def _on_guardar(self) -> None:
        """Valida, guarda en BD (o local), genera PDF y emite señal."""
        # ── Validaciones mínimas ──────────────────────────────────────────────
        warnings = []

        if not self._inp_eq_marca.text().strip():
            warnings.append("• No se llenó la Marca del instrumento.")

        if _HAS_PRUEBAS and self._pruebas_widget:
            pruebas = self._pruebas_widget.get_all_data()
            reps = pruebas.get("repetibilidad", [])
            exas = pruebas.get("exactitud", [])
        else:
            reps, exas = [], []
        if not reps and not exas:
            warnings.append("• No se ingresaron datos en ninguna tabla de pruebas.")

        nombre_cliente = self._inp_nombre_cliente.text().strip()
        if not nombre_cliente:
            warnings.append("• El nombre del representante del cliente es obligatorio.")

        if self._canvas_tecnico.is_empty():
            warnings.append("• Falta la firma del Técnico Responsable.")

        if warnings:
            resp = QMessageBox.warning(
                self,
                "Formulario Incompleto",
                "El formulario tiene datos faltantes:\n\n" +
                "\n".join(warnings) +
                "\n\n¿Deseas guardarlo de todas formas?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if resp != QMessageBox.StandardButton.Yes:
                return

        self._btn_save.setEnabled(False)
        self._btn_save.setText("Guardando…")
        QApplication.processEvents()

        try:
            # Recopilar todos los datos del formulario
            form_data = self._collect_form_data()

            # 1. Guardar en BD (o localmente si no hay conexión)
            saved_local = False
            if _HAS_DB:
                try:
                    self._save_to_db(form_data)
                    logger.info("OS %s guardada en BD correctamente.", self._folio_os)
                except Exception as exc:
                    logger.warning("No se pudo guardar en BD: %s — guardando localmente.", exc)
                    self._save_locally(form_data)
                    saved_local = True
            else:
                self._save_locally(form_data)
                saved_local = True

            # 2. Generar PDF final con datos + firmas
            pdf_path = None
            try:
                pdf_path = self._generate_pdf(form_data)
            except Exception as exc:
                logger.error("Error generando PDF final: %s", exc)

            # 3. Actualizar badge de estado
            self._lbl_estado.setText("  COMPLETADA DIGITAL  ")
            self._lbl_estado.setStyleSheet("""
                background: rgba(52,199,89,0.12);
                color: #34C759;
                font-size: 11px;
                font-weight: 700;
                border-radius: 6px;
                padding: 4px 10px;
                letter-spacing: 0.5px;
            """)

            # 4. Mensaje de confirmación
            msg_extra = ""
            if saved_local:
                msg_extra = "\n\nSin conexión a BD — guardado localmente. Se sincronizará al conectarse."
            if pdf_path:
                msg_extra += f"\n\nPDF generado:\n{pdf_path}"

            QMessageBox.information(
                self,
                "Servicio Completado",
                f"La Orden de Servicio {self._folio_os} ha sido guardada exitosamente "
                f"con estado COMPLETADA_DIGITAL.{msg_extra}"
            )

            # 5. Emitir señal y cerrar
            self.servicio_completado.emit(self._folio_os)
            self.accept()

        except Exception as exc:
            logger.exception("Error crítico al guardar formulario digital: %s", exc)
            self._btn_save.setEnabled(True)
            self._btn_save.setText("💾   Guardar y Finalizar Servicio")
            QMessageBox.critical(
                self, "Error al Guardar",
                f"Ocurrió un error inesperado al guardar:\n\n{exc}\n\n"
                "Revisa pesa.log para más detalles."
            )

    def _collect_form_data(self) -> dict:
        """Recoge todos los datos del formulario en un dict serializable."""
        q_date = self._dte_fecha.date()
        fecha  = date(q_date.year(), q_date.month(), q_date.day())

        # ── Pruebas metrológicas (modo pestañas o modo widget completo) ────────
        uses_tabs = getattr(self, "_uses_tab_mode", False)
        if uses_tabs:
            # Modo pestañas: recoger datos de cada sub-widget individualmente
            rep_data  = self._w_repetibilidad.get_data()  if hasattr(self, "_w_repetibilidad")  else []
            exc_data  = self._w_excentricidad.get_data()  if hasattr(self, "_w_excentricidad")  else []
            exac_data = self._w_exactitud.get_data()      if hasattr(self, "_w_exactitud")      else []
            tipo_inst = (self._w_excentricidad.get_tipo_instrumento()
                         if hasattr(self, "_w_excentricidad") else None)
            clase_ex  = (self._w_exactitud.get_clase_exactitud()
                         if hasattr(self, "_w_exactitud") else None)
            jia       = (self._w_exactitud.get_indicadores_jia()
                         if hasattr(self, "_w_exactitud") else {})
            pruebas = {
                "repetibilidad":   rep_data,
                "excentricidad":   exc_data,
                "exactitud":       exac_data,
                "tipo_instrumento": tipo_inst,
                "aplica_excentricidad": (self._w_excentricidad.get_aplica_excentricidad()
                                         if hasattr(self, "_w_excentricidad") else True),
                "filas_excentricidad": (self._w_excentricidad.get_filas_excentricidad()
                                        if hasattr(self, "_w_excentricidad") else 5),
                "id_clase_exactitud": clase_ex,
                "indicadores_jia": jia,
            }
        elif _HAS_PRUEBAS and self._pruebas_widget:
            pruebas = self._pruebas_widget.get_all_data()
        else:
            pruebas = {"repetibilidad": [], "excentricidad": [], "exactitud": [],
                       "tipo_instrumento": None, "id_clase_exactitud": None,
                       "indicadores_jia": {"J": False, "I": False, "A": False}}

        return {
            # Encabezado
            "folio_os":          self._folio_os,
            "os_id":             self._os_id,
            "cliente":           self._lbl_cliente.text(),
            "direccion":         self._lbl_direccion.text(),
            "tecnico":           self._lbl_tecnico.text(),
            "fecha":             fecha.isoformat(),
            # Instrumento
            "equipo_id":         self._inp_equipo_id.text().strip(),
            "equipo_marca":      self._inp_eq_marca.text().strip(),
            "equipo_modelo":     self._inp_eq_modelo.text().strip(),
            "equipo_alcance":    self._inp_eq_alcance.text().strip(),
            "equipo_division":   self._inp_eq_division.text().strip(),
            "equipo_ns":         self._inp_eq_ns.text().strip(),
            "equipo_ubicacion":  self._inp_eq_ubicacion.text().strip(),
            # Pruebas metrológicas
            "tipo_instrumento":     pruebas.get("tipo_instrumento"),
            "aplica_excentricidad": pruebas.get("aplica_excentricidad"),
            "filas_excentricidad":  pruebas.get("filas_excentricidad"),
            "repetibilidad":        pruebas.get("repetibilidad", []),
            "excentricidad":        pruebas.get("excentricidad", []),
            "exactitud":            pruebas.get("exactitud", []),
            "clase_exactitud":      pruebas.get("id_clase_exactitud"),
            "indicadores_jia":      pruebas.get("indicadores_jia", {}),
            # Observaciones
            "observaciones":     self._txt_observaciones.toPlainText().strip(),
            # Firmas — nombre + base64 PNG
            "nombre_tecnico_firma":  self._inp_nombre_tecnico.text().strip(),
            "nombre_cliente_firma":  self._inp_nombre_cliente.text().strip(),
            "firma_tecnico":         self._canvas_tecnico.to_base64_png(),
            "firma_cliente":         self._canvas_cliente.to_base64_png(),
            # Metadata
            "timestamp":         datetime.now().isoformat(),
            "estado":            "COMPLETADA",  # Estado canónico del check constraint
        }


    def _save_to_db(self, data: dict) -> None:
        """Actualiza la OS en PostgreSQL con todos los datos del formulario."""
        conn = _db_pool.get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE ordenes_servicio
                    SET
                        estado                 = 'COMPLETADA',
                        modalidad              = 'Digital',
                        fecha                  = %s,
                        equipo_id_str          = %s,
                        equipo_marca           = %s,
                        equipo_modelo          = %s,
                        equipo_alcance         = %s,
                        equipo_division        = %s,
                        equipo_ns              = %s,
                        equipo_ubicacion       = %s,
                        tipo_instrumento       = %s,
                        aplica_excentricidad   = %s,
                        filas_excentricidad    = %s,
                        pruebas_repetibilidad  = %s,
                        pruebas_excentricidad  = %s,
                        pruebas_exactitud      = %s,
                        clase_exactitud        = %s,
                        indicadores_jia        = %s,
                        observaciones_tecnico  = %s,
                        nombre_tecnico_firma   = %s,
                        nombre_cliente_firma   = %s,
                        firma_tecnico_b64      = %s,
                        firma_cliente_b64      = %s,
                        fecha_completada       = NOW()
                    WHERE id = %s
                """, (
                    data["fecha"],
                    data["equipo_id"],
                    data["equipo_marca"],
                    data["equipo_modelo"],
                    data["equipo_alcance"],
                    data["equipo_division"],
                    data["equipo_ns"],
                    data["equipo_ubicacion"],
                    data["tipo_instrumento"],
                    data.get("aplica_excentricidad"),
                    data.get("filas_excentricidad"),
                    json.dumps(data["repetibilidad"],  ensure_ascii=False),
                    json.dumps(data["excentricidad"],  ensure_ascii=False),
                    json.dumps(data["exactitud"],      ensure_ascii=False),
                    data["clase_exactitud"],
                    json.dumps(data["indicadores_jia"], ensure_ascii=False),
                    data["observaciones"],
                    data["nombre_tecnico_firma"],
                    data["nombre_cliente_firma"],
                    data["firma_tecnico"],
                    data["firma_cliente"],
                    self._os_id,
                ))
            conn.commit()
        finally:
            _db_pool.release_connection(conn)

    def _save_locally(self, data: dict) -> None:
        """Guarda el formulario en JSON local (sync pendiente sin conexión)."""
        local_dir = Path.home() / "PesaServidorLocal" / "FormulariosDigitales" / "Pendientes"
        local_dir.mkdir(parents=True, exist_ok=True)
        out_file = local_dir / f"{self._folio_os}_digital.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        logger.info("Formulario guardado localmente: %s", out_file)

    def _generate_pdf(self, data: dict) -> Optional[str]:
        """
        Genera el PDF final de la OS con todos los datos del formulario
        (incluyendo firmas digitales incrustadas).
        """
        output_dir = Path(r"C:\PesaServidorCentral\PDF_OS")
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
        except (PermissionError, OSError):
            output_dir = Path.home() / "PesaServidorLocal" / "PDF_OS"
            output_dir.mkdir(parents=True, exist_ok=True)

        pdf_path = str(output_dir / f"{self._folio_os}_DIGITAL.pdf")

        if _HAS_PDF:
            # Pixmaps de firmas (para incrustar en PDF)
            firma_tec_pix  = self._canvas_tecnico.to_pixmap(400, 140)
            firma_cli_pix  = self._canvas_cliente.to_pixmap(400, 140)

            # Guardar firmas como PNG temporales
            tmp_dir = Path.home() / "PesaServidorLocal" / "tmp_firmas"
            tmp_dir.mkdir(parents=True, exist_ok=True)
            firma_tec_path = str(tmp_dir / f"{self._folio_os}_firma_tec.png")
            firma_cli_path = str(tmp_dir / f"{self._folio_os}_firma_cli.png")
            firma_tec_pix.save(firma_tec_path, "PNG")
            firma_cli_pix.save(firma_cli_path, "PNG")

            os_data_pdf = {
                "folio_os":               data["folio_os"],
                "cliente":                data["cliente"],
                "razon_social":           data["cliente"],
                "direccion_cliente":      data["direccion"],
                "fecha":                  data["fecha"],
                "observaciones":          data["observaciones"],
                # Instrumento
                "equipo_marca":           data["equipo_marca"],
                "equipo_modelo":          data["equipo_modelo"],
                "equipo_ns":              data["equipo_ns"],
                "equipo_alcance":         data["equipo_alcance"],
                "equipo_division":        data["equipo_division"],
                "equipo_ubicacion":       data["equipo_ubicacion"],
                # Pruebas
                "tipo_instrumento":       data["tipo_instrumento"],
                "repetibilidad":          data["repetibilidad"],
                "excentricidad":          data["excentricidad"],
                "exactitud":              data["exactitud"],
                "clase_exactitud":        data["clase_exactitud"],
                "indicadores_jia":        data["indicadores_jia"],
                # Firmas + nombres
                "nombre_tecnico_firma":   data["nombre_tecnico_firma"],
                "nombre_cliente_firma":   data["nombre_cliente_firma"],
                "firma_tecnico_path":     firma_tec_path,
                "firma_cliente_path":     firma_cli_path,
            }
            gen = OsPdfGenerator()
            gen.generate_os_pdf(
                os_data        = os_data_pdf,
                output_path    = pdf_path,
                tecnico_nombre = data["tecnico"],
                digital        = True,
            )
            logger.info("PDF digital generado: %s", pdf_path)

            # Abrir automáticamente
            try:
                import os as _os, sys, subprocess
                if sys.platform == "win32":
                    _os.startfile(pdf_path)
                elif sys.platform == "darwin":
                    subprocess.run(["open", pdf_path])
                else:
                    subprocess.run(["xdg-open", pdf_path])
            except Exception as exc:
                logger.warning("No se pudo abrir el PDF automáticamente: %s", exc)
        else:
            # Sin OsPdfGenerator — guardar los datos en un JSON legible
            data_only = {k: v for k, v in data.items()
                         if k not in ("firma_tecnico", "firma_cliente")}
            data_only["nota"] = "PDF no generado — OsPdfGenerator no disponible."
            pdf_path = str(output_dir / f"{self._folio_os}_DIGITAL_datos.json")
            with open(pdf_path, "w", encoding="utf-8") as f:
                json.dump(data_only, f, ensure_ascii=False, indent=2)
            logger.warning("OsPdfGenerator no disponible. Datos guardados en: %s", pdf_path)

        return pdf_path

    # ══════════════════════════════════════════════════════════════════════════
    # CIERRE
    # ══════════════════════════════════════════════════════════════════════════

    def _on_close_requested(self) -> None:
        """Confirma el cierre si hay datos ingresados."""
        has_data = (
            not self._canvas_tecnico.is_empty()
            or not self._canvas_cliente.is_empty()
            or bool(self._txt_observaciones.toPlainText().strip())
            or bool(self._inp_equipo_id.text().strip())
        )

        if has_data:
            resp = QMessageBox.question(
                self,
                "Cerrar Formulario",
                "¿Deseas cerrar el formulario?\n\n"
                "Los datos no guardados se perderán.",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if resp != QMessageBox.StandardButton.Yes:
                return

        self.reject()

    def closeEvent(self, event) -> None:
        """Intercepta el botón X de la ventana."""
        has_data = (
            not self._canvas_tecnico.is_empty()
            or not self._canvas_cliente.is_empty()
            or bool(self._txt_observaciones.toPlainText().strip())
        )
        if has_data:
            resp = QMessageBox.question(
                self, "Cerrar",
                "¿Cerrar el formulario sin guardar?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if resp != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
        event.accept()


# ══════════════════════════════════════════════════════════════════════════════
# FUNCIÓN DE CONVENIENCIA — open_digital_form(...)
# ══════════════════════════════════════════════════════════════════════════════
def open_digital_form(
    folio_os:   str,
    os_data:    dict = None,
    os_id:      int  = 0,
    id_cliente: int  = 0,
    parent           = None,
) -> bool:
    """
    Abre el formulario digital de forma conveniente desde cualquier módulo.

    Uso:
        from ui.dialogs.digital_service_dialog import open_digital_form
        completado = open_digital_form("OS-26-042", os_data, os_id=42,
                                       id_cliente=5, parent=self)
        if completado:
            self.refresh()

    Args:
        id_cliente: ID del cliente en cat_clientes.
                    Se usa para filtrar el historial de equipos (cat_equipos)
                    y ofrecer autocompletado por ID de equipo.

    Returns:
        True si el usuario guardó el formulario, False si canceló.
    """
    dlg = DigitalServiceDialog(
        folio_os   = folio_os,
        os_data    = os_data or {},
        os_id      = os_id,
        id_cliente = id_cliente,
        parent     = parent,
    )
    return dlg.exec() == QDialog.DialogCode.Accepted

