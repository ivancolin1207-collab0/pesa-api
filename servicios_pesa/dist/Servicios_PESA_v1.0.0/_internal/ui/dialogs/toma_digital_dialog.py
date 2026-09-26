"""
toma_digital_dialog.py — Formulario Táctil Optimizado para Tablet
Servicios PESA v3.0

Diálogo Touch-Friendly para técnicos en campo (modo offline).

Características:
    - Botones mínimo 48×48px (WCAG Touch Target)
    - Teclado numérico personalizado 0-9, ., ⌫ (teclas 60×60px)
    - Celdas de tabla con alto mínimo 52px
    - Cálculo en vivo: Error = Lectura − ValorNominal
    - Lienzo de firma táctil (DrawingCanvas reutilizado)
    - Guarda en SQLite local con sync_status='PENDING'
    - Genera PDF local en TABLET_PDF_DIR

Acceso:
    - Desde DashboardWidget → botón "📱 Abrir en Tablet"
    - Desde BatchGeneratorWidget → botón táctil
"""
from __future__ import annotations

import logging
from datetime import date, datetime
from pathlib import Path
from typing import Optional

from PyQt6.QtCore import (
    Qt, QDate, QPoint, QPointF, QSize, pyqtSignal, QTimer,
)
from PyQt6.QtGui import (
    QFont, QColor, QPainter, QPen, QPixmap, QPainterPath, QBrush,
)
from PyQt6.QtWidgets import (
    QDialog, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QLineEdit, QTextEdit, QDateEdit,
    QTableWidget, QTableWidgetItem, QHeaderView, QScrollArea,
    QFrame, QSizePolicy, QMessageBox, QAbstractItemView,
    QGroupBox, QApplication, QTabWidget, QSplitter,
)

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales ──────────────────────────────────────────────────
try:
    from sync_manager import sync_manager as _sync_manager
    _HAS_SYNC = True
except ImportError:
    _HAS_SYNC = False
    _sync_manager = None

try:
    from config import TABLET_PDF_DIR, PDFS_DIR
except ImportError:
    import platform as _plat
    if _plat.system() == "Darwin":
        _base = Path.home() / "Library" / "Application Support" / "PesaServicios"
    elif _plat.system() == "Windows":
        _base = Path(os.environ.get("APPDATA") or str(Path.home())) / "PesaServicios"
    else:
        _base = Path.home() / ".pesaservicios"
    _base.mkdir(parents=True, exist_ok=True)
    PDFS_DIR       = _base / "formatos_generados"
    TABLET_PDF_DIR = str(PDFS_DIR)
    PDFS_DIR.mkdir(parents=True, exist_ok=True)

try:
    from services.os_pdf_generator import OsPdfGenerator
    _HAS_PDF = True
except ImportError:
    _HAS_PDF = False

try:
    from auth.session_context import session as _session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    _session = None

# ─── Paleta PESA ──────────────────────────────────────────────────────────────
_BG      = "#F0F2F5"
_WHITE   = "#FFFFFF"
_DARK    = "#1D1D1F"
_GRAY    = "#86868B"
_LGRAY   = "#D1D5DB"
_RED     = "#E63946"
_DRED    = "#C42B37"
_BLUE    = "#007AFF"
_GREEN   = "#34C759"
_AMBER   = "#FF9F0A"
_SURFACE = "#FAFAFA"

# ── Constantes táctiles ───────────────────────────────────────────────────────
_TOUCH_BTN_H  = 52   # Altura mínima botones
_TOUCH_ROW_H  = 52   # Altura mínima filas de tabla
_TOUCH_FONT   = 15   # Tamaño de fuente en tablas táctiles
_NUM_PAD_SIZE = 64   # Tamaño de teclas del teclado numérico


# ══════════════════════════════════════════════════════════════════════════════
# NumericKeypad — Teclado numérico táctil emergente
# ══════════════════════════════════════════════════════════════════════════════
class NumericKeypad(QDialog):
    """
    Teclado numérico flotante para captura táctil de valores metrológicos.
    Teclas: 0–9, punto decimal, retroceso, limpiar, confirmar.
    """

    value_confirmed = pyqtSignal(str)  # Emite el valor final al confirmar

    def __init__(self, current_value: str = "", parent=None):
        super().__init__(parent)
        self.setWindowTitle("Ingresar Valor")
        self.setModal(True)
        self.setMinimumWidth(380)
        self.setWindowFlags(
            Qt.WindowType.Dialog |
            Qt.WindowType.FramelessWindowHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self._current = current_value
        self._build_ui()

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)

        card = QFrame()
        card.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-radius: 20px;
                border: 1px solid rgba(0,0,0,0.10);
            }}
        """)
        lay = QVBoxLayout(card)
        lay.setContentsMargins(20, 20, 20, 20)
        lay.setSpacing(12)

        # Display
        self._display = QLineEdit(self._current)
        self._display.setAlignment(Qt.AlignmentFlag.AlignRight)
        self._display.setReadOnly(True)
        self._display.setStyleSheet(f"""
            QLineEdit {{
                font-size: 32px;
                font-weight: 700;
                color: {_DARK};
                background: #F2F2F7;
                border: none;
                border-radius: 12px;
                padding: 12px 16px;
            }}
        """)
        self._display.setMinimumHeight(64)
        lay.addWidget(self._display)

        # Grid de teclas
        grid = QGridLayout()
        grid.setSpacing(8)

        keys = [
            ("7", 0, 0), ("8", 0, 1), ("9", 0, 2), ("⌫", 0, 3),
            ("4", 1, 0), ("5", 1, 1), ("6", 1, 2), ("C", 1, 3),
            ("1", 2, 0), ("2", 2, 1), ("3", 2, 2), ("✓", 2, 3),
            ("0", 3, 0), (".", 3, 1), ("±", 3, 2), ("", 3, 3),
        ]

        for label, row, col in keys:
            if not label:
                continue
            btn = QPushButton(label)
            btn.setFixedSize(_NUM_PAD_SIZE, _NUM_PAD_SIZE)
            btn.setCursor(Qt.CursorShape.PointingHandCursor)

            if label == "✓":
                color, fg = _GREEN, _WHITE
            elif label in ("⌫", "C"):
                color, fg = "#FF3B30", _WHITE
            elif label == "±":
                color, fg = _AMBER, _WHITE
            else:
                color, fg = "#F2F2F7", _DARK

            btn.setStyleSheet(f"""
                QPushButton {{
                    background: {color};
                    color: {fg};
                    font-size: 22px;
                    font-weight: 600;
                    border-radius: 14px;
                    border: none;
                }}
                QPushButton:pressed {{ opacity: 0.7; }}
            """)
            btn.clicked.connect(lambda _, k=label: self._on_key(k))
            grid.addWidget(btn, row, col)

        lay.addLayout(grid)
        outer.addWidget(card)

    def _on_key(self, key: str) -> None:
        txt = self._display.text()
        if key == "⌫":
            self._display.setText(txt[:-1])
        elif key == "C":
            self._display.setText("")
        elif key == "✓":
            self.value_confirmed.emit(self._display.text())
            self.accept()
        elif key == "±":
            if txt.startswith("-"):
                self._display.setText(txt[1:])
            elif txt:
                self._display.setText("-" + txt)
        elif key == ".":
            if "." not in txt:
                self._display.setText(txt + ".")
        else:
            self._display.setText(txt + key)

    def get_value(self) -> str:
        return self._display.text()


# ══════════════════════════════════════════════════════════════════════════════
# TouchTableWidget — Tabla metrológica táctil con cálculo en vivo
# ══════════════════════════════════════════════════════════════════════════════
class TouchTableWidget(QFrame):
    """
    Tabla de pruebas metrológicas optimizada para touch.
    Calcula Error = Lectura − ValorNominal en tiempo real.
    """

    def __init__(
        self,
        title: str,
        headers: list[str],
        rows: int,
        color: str = _RED,
        has_nominal: bool = False,
        parent=None,
    ):
        super().__init__(parent)
        self._title      = title
        self._headers    = headers
        self._rows       = rows
        self._color      = color
        self._has_nominal = has_nominal  # True para Exactitud (tiene Valor Nominal)
        self._build()

    def _build(self) -> None:
        self.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border: 1.5px solid rgba(0,0,0,0.07);
                border-radius: 14px;
            }}
        """)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # Cabecera con color de sección
        header_w = QWidget()
        header_w.setStyleSheet(f"""
            background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                stop:0 {self._color}, stop:1 {self._color}CC);
            border-radius: 13px 13px 0 0;
        """)
        header_w.setFixedHeight(44)
        hl = QHBoxLayout(header_w)
        hl.setContentsMargins(16, 0, 16, 0)
        lbl = QLabel(self._title)
        lbl.setStyleSheet("color: white; font-size: 14px; font-weight: 700; background: transparent;")
        hl.addWidget(lbl)
        lay.addWidget(header_w)

        # Tabla QTableWidget
        self._table = QTableWidget(self._rows, len(self._headers))
        self._table.setHorizontalHeaderLabels(self._headers)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectItems)
        self._table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._table.setAlternatingRowColors(True)
        self._table.verticalHeader().setDefaultSectionSize(_TOUCH_ROW_H)
        self._table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self._table.setStyleSheet(f"""
            QTableWidget {{
                background: {_WHITE};
                alternate-background-color: #F8F9FB;
                border: none;
                font-size: {_TOUCH_FONT}px;
                gridline-color: #E5E7EB;
                outline: none;
            }}
            QTableWidget::item {{
                padding: 6px 10px;
                border-bottom: 1px solid #F0F0F5;
            }}
            QTableWidget::item:selected {{
                background: rgba(0,122,255,0.10);
                color: {_DARK};
            }}
            QHeaderView::section {{
                background: #F7F8FA;
                color: #6B7280;
                font-size: 12px;
                font-weight: 600;
                padding: 8px;
                border: none;
                border-bottom: 1.5px solid #E5E7EB;
            }}
        """)

        # Poblar celdas con ítems editables
        for r in range(self._rows):
            for c in range(len(self._headers)):
                cell_item = QTableWidgetItem("")
                cell_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                self._table.setItem(r, c, cell_item)

        # Conectar doble clic → teclado numérico
        self._table.cellDoubleClicked.connect(self._on_cell_double_click)
        # Conectar cambio de celda → calcular error
        self._table.itemChanged.connect(self._on_item_changed)

        lay.addWidget(self._table)

    def _on_cell_double_click(self, row: int, col: int) -> None:
        """Abre el teclado numérico táctil para la celda seleccionada."""
        # Las columnas de Error son solo lectura (calculadas)
        header = self._headers[col].lower()
        if "error" in header:
            return

        current = self._table.item(row, col)
        current_val = current.text() if current else ""

        pad = NumericKeypad(current_val, self)
        pad.value_confirmed.connect(
            lambda val, r=row, c=col: self._set_cell(r, c, val)
        )
        # Posicionar el teclado cerca del tap
        pad.move(self.mapToGlobal(QPoint(
            max(0, self.width() // 2 - 190),
            max(0, self.height() // 2 - 200)
        )))
        pad.exec()

    def _set_cell(self, row: int, col: int, value: str) -> None:
        """Establece el valor de la celda y dispara el cálculo de error."""
        item = self._table.item(row, col)
        if not item:
            item = QTableWidgetItem()
            self._table.setItem(row, col, item)
        item.setText(value)
        self._calculate_error(row)

    def _on_item_changed(self, item: QTableWidgetItem) -> None:
        self._calculate_error(item.row())

    def _calculate_error(self, row: int) -> None:
        """
        Calcula Error = Lectura − ValorNominal y colorea en rojo/verde.
        Solo aplica si hay columna Valor Nominal en la tabla (Exactitud).
        """
        if not self._has_nominal:
            return

        headers_lower = [h.lower() for h in self._headers]
        try:
            idx_nom    = next(i for i, h in enumerate(headers_lower) if "nominal" in h)
            idx_lec    = next(i for i, h in enumerate(headers_lower) if "lectura" in h and "inicial" in h)
            idx_error  = next((i for i, h in enumerate(headers_lower) if "error" in h), None)
        except StopIteration:
            return

        try:
            nom_text = (self._table.item(row, idx_nom) or QTableWidgetItem("")).text()
            lec_text = (self._table.item(row, idx_lec) or QTableWidgetItem("")).text()

            if not nom_text or not lec_text:
                if idx_error is not None:
                    e_item = self._table.item(row, idx_error) or QTableWidgetItem()
                    e_item.setText("")
                    self._table.setItem(row, idx_error, e_item)
                return

            nom = float(nom_text)
            lec = float(lec_text)
            error = round(lec - nom, 6)

            if idx_error is not None:
                e_item = self._table.item(row, idx_error) or QTableWidgetItem()
                e_item.setText(f"{error:+.4f}")
                # Color según magnitud
                if abs(error) < 1e-9:
                    e_item.setForeground(QColor(_GREEN))
                elif abs(error) <= abs(nom) * 0.01:   # dentro del 1%
                    e_item.setForeground(QColor(_AMBER))
                else:
                    e_item.setForeground(QColor(_RED))
                self._table.setItem(row, idx_error, e_item)
        except (ValueError, ZeroDivisionError):
            pass

    def get_data(self) -> list[dict]:
        """
        Retorna las filas como lista de dicts.
        Formato compatible con el modelo OrdenServicioRepository.
        """
        result = []
        for r in range(self._rows):
            row_data: dict = {}
            for c, h in enumerate(self._headers):
                item = self._table.item(r, c)
                val  = item.text().strip() if item else ""
                # Convertir a número si es posible
                try:
                    row_data[h.lower().replace(" ", "_")] = float(val) if val else None
                except ValueError:
                    row_data[h.lower().replace(" ", "_")] = val or None
            # Agregar posicion_id / punto_id
            row_data["posicion_id"] = r + 1
            row_data["punto_id"]    = r + 1
            # Determinar si tiene datos (al menos un valor no None)
            if any(v is not None for k, v in row_data.items()
                   if k not in ("posicion_id", "punto_id")):
                result.append(row_data)
        return result

    def load_data(self, rows: list[dict]) -> None:
        """Pre-carga datos existentes en la tabla (ej. desde SQLite local)."""
        self._table.blockSignals(True)
        for row_data in rows:
            pos = row_data.get("posicion_id", row_data.get("punto_id", 1)) - 1
            if 0 <= pos < self._rows:
                for c, h in enumerate(self._headers):
                    key = h.lower().replace(" ", "_")
                    val = row_data.get(key)
                    if val is not None:
                        item = self._table.item(pos, c) or QTableWidgetItem()
                        item.setText(str(val))
                        self._table.setItem(pos, c, item)
        self._table.blockSignals(False)
        # Recalcular errores
        for r in range(self._rows):
            self._calculate_error(r)


# ══════════════════════════════════════════════════════════════════════════════
# DrawingCanvas — Reutilizado del digital_service_dialog
# (re-implementado aquí para evitar dependencia circular)
# ══════════════════════════════════════════════════════════════════════════════
class DrawingCanvas(QWidget):
    """Canvas de firma táctil/mouse/lápiz digitalizador."""

    signature_changed = pyqtSignal()

    def __init__(self, placeholder: str = "Firme aquí", parent=None):
        super().__init__(parent)
        self._placeholder = placeholder
        self._strokes: list[list[QPointF]] = []
        self._current_stroke: list[QPointF] = []
        self._drawing = False
        self.setMinimumSize(300, 140)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setAttribute(Qt.WidgetAttribute.WA_AcceptTouchEvents, True)
        self.setStyleSheet(f"""
            background: #FCFCFC;
            border: 2px solid {_LGRAY};
            border-radius: 10px;
        """)

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

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("#FCFCFC"))

        pen_guide = QPen(QColor("#E5E7EB"), 1, Qt.PenStyle.DashLine)
        painter.setPen(pen_guide)
        y_base = int(self.height() * 0.75)
        painter.drawLine(20, y_base, self.width() - 20, y_base)

        if not self._strokes and not self._current_stroke:
            painter.setPen(QColor("#C7C7CC"))
            f = painter.font()
            f.setPointSize(12)
            painter.setFont(f)
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter,
                             f"✍  {self._placeholder}")
            return

        pen = QPen(QColor(_DARK), 2.5, Qt.PenStyle.SolidLine,
                   Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        for stroke in self._strokes:
            self._draw_stroke(painter, stroke)
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

    def clear(self) -> None:
        self._strokes.clear()
        self._current_stroke.clear()
        self._drawing = False
        self.update()
        self.signature_changed.emit()

    def is_empty(self) -> bool:
        return len(self._strokes) == 0

    def to_pixmap(self, width: int = 400, height: int = 150) -> QPixmap:
        pix = QPixmap(width, height)
        pix.fill(Qt.GlobalColor.white)
        if self.is_empty():
            return pix
        painter = QPainter(pix)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        sx = width  / max(self.width(),  1)
        sy = height / max(self.height(), 1)
        pen = QPen(QColor(_DARK), 2.5, Qt.PenStyle.SolidLine,
                   Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        for stroke in self._strokes:
            scaled = [QPointF(p.x() * sx, p.y() * sy) for p in stroke]
            self._draw_stroke(painter, scaled)
        painter.end()
        return pix

    def to_base64_png(self) -> str:
        import base64
        from PyQt6.QtCore import QBuffer, QIODevice
        pix = self.to_pixmap()
        buf = QBuffer()
        buf.open(QIODevice.OpenModeFlag.WriteOnly)
        pix.toImage().save(buf, "PNG")
        return base64.b64encode(buf.data().data()).decode("utf-8")


# ══════════════════════════════════════════════════════════════════════════════
# EnlacesSustitucionWidget — Tabla táctil de Exactitud para Calibración
# por Enlaces de Sustitución (Báscula tipo Tanque / NOM-010-SCFI / OIML R 76)
# ══════════════════════════════════════════════════════════════════════════════
class EnlacesSustitucionWidget(QFrame):
    """
    Tabla táctil especializada para Calibración por Enlaces de Sustitución.

    Genera filas alternadas por cada enlace:
      [Pto N / Patrón]     → El técnico ingresa Val. Nominal de sus pesas + lectura del instrumento.
      [Sust. N (Agua/Aux)] → El técnico captura la lectura real tras ajuste de válvulas.

    La app encadena automáticamente el valor acumulado base para el siguiente
    enlace (Valor Nominal patrón + lectura de sustitución anterior).

    get_data() retorna lista de dicts compatible con el modelo de exactitud de la OS.
    """

    def __init__(self, n_enlaces: int = 4, parent=None):
        super().__init__(parent)
        self._n_enlaces  = max(2, int(n_enlaces))
        self._rows_wgt: list[dict] = []  # dicts con los widgets de cada fila
        self._build()

    def _build(self) -> None:
        self.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border: 1.5px solid rgba(0,0,0,0.07);
                border-radius: 14px;
            }}
        """)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # Cabecera
        hdr = QWidget()
        hdr.setStyleSheet("""
            background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                stop:0 #1D4ED8, stop:1 #1D4ED8CC);
            border-radius: 13px 13px 0 0;
        """)
        hdr.setFixedHeight(44)
        hl = QHBoxLayout(hdr)
        hl.setContentsMargins(16, 0, 16, 0)
        lbl_hdr = QLabel("🔗  Exactitud — Calibración por Enlaces de Sustitución (NOM-010-SCFI / OIML R 76)")
        lbl_hdr.setStyleSheet("color: white; font-size: 13px; font-weight: 700; background: transparent;")
        hl.addWidget(lbl_hdr)
        lay.addWidget(hdr)

        # Instrucción
        lbl_hint = QLabel(
            "  Ingrese el Valor Nominal de sus pesas patrón en las filas azules. "
            "Las filas verdes son para la lectura tras añadir agua/auxiliar."
        )
        lbl_hint.setStyleSheet(
            f"font-size: 11px; color: {_GRAY}; background: #F8F9FB; "
            "padding: 6px 16px; border-bottom: 1px solid #E5E7EB;"
        )
        lbl_hint.setWordWrap(True)
        lay.addWidget(lbl_hint)

        # Scroll area para las filas
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("background: transparent; border: none;")
        content_w = QWidget()
        content_w.setStyleSheet("background: transparent;")
        rows_lay = QVBoxLayout(content_w)
        rows_lay.setContentsMargins(8, 8, 8, 8)
        rows_lay.setSpacing(4)

        for n in range(1, self._n_enlaces + 1):
            # — Fila Patrón —
            row_patron = self._make_row(
                paso   = n * 2 - 1,
                label  = f"Pto {n} / Patrón",
                color  = "#EBF5FF",
                border = "#1D4ED8",
                label_color = "#1D4ED8",
                editable_nominal = True,
                n_index = n,
                is_patron = True,
            )
            rows_lay.addWidget(row_patron["widget"])
            self._rows_wgt.append(row_patron)

            # — Fila Sustitución —
            row_sust = self._make_row(
                paso   = n * 2,
                label  = f"Sust. {n}  (Agua / Aux.)",
                color  = "#F0F7E8",
                border = "#166534",
                label_color = "#166534",
                editable_nominal = False,
                n_index = n,
                is_patron = False,
            )
            rows_lay.addWidget(row_sust["widget"])
            self._rows_wgt.append(row_sust)

        rows_lay.addStretch()
        scroll.setWidget(content_w)
        lay.addWidget(scroll, stretch=1)

    def _make_row(
        self,
        paso: int,
        label: str,
        color: str,
        border: str,
        label_color: str,
        editable_nominal: bool,
        n_index: int,
        is_patron: bool,
    ) -> dict:
        """Crea una fila de la tabla y retorna un dict con los widgets de entrada."""
        w = QFrame()
        w.setStyleSheet(f"""
            QFrame {{
                background: {color};
                border: 1px solid {border}33;
                border-radius: 8px;
            }}
        """)
        lay = QHBoxLayout(w)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(10)

        # Badge de número de paso
        badge = QLabel(str(paso))
        badge.setFixedSize(28, 28)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(
            f"background: {border}; color: white; border-radius: 14px; "
            "font-size: 12px; font-weight: 700;"
        )
        lay.addWidget(badge)

        # Etiqueta de descripción
        lbl = QLabel(label)
        lbl.setFixedWidth(180)
        lbl.setStyleSheet(
            f"font-size: 12px; font-weight: {'700' if is_patron else '600'}; "
            f"color: {label_color}; background: transparent;"
        )
        lay.addWidget(lbl)

        def _make_le(placeholder: str, enabled: bool) -> QLineEdit:
            le = QLineEdit()
            le.setPlaceholderText(placeholder)
            le.setMinimumHeight(_TOUCH_BTN_H)
            le.setEnabled(enabled)
            le.setStyleSheet(f"""
                QLineEdit {{
                    font-size: {_TOUCH_FONT}px;
                    background: {'white' if enabled else '#F0F0F5'};
                    border: 1.5px solid {'#E5E7EB' if enabled else '#D0D0D5'};
                    border-radius: 8px;
                    padding: 0 10px;
                    color: {_DARK};
                }}
                QLineEdit:focus {{
                    background: white;
                    border-color: {border};
                }}
            """)
            return le

        # Campo Valor Nominal (solo patrón lo tiene editable)
        le_nominal = _make_le(
            "Pesas patrón (kg)" if editable_nominal else "—",
            editable_nominal
        )
        lay.addWidget(le_nominal, stretch=1)

        # Campo Lectura Inicial (siempre editable en campo)
        le_lectura = _make_le("Lectura instrumento", True)
        lay.addWidget(le_lectura, stretch=1)

        # Conectar doble clic para teclado numérico táctil
        for le_field in (le_nominal, le_lectura):
            if le_field.isEnabled():
                le_field.mouseDoubleClickEvent = (
                    lambda _event, f=le_field: self._open_keypad(f)
                )

        return {
            "widget":    w,
            "paso":      paso,
            "label":     label,
            "is_patron": is_patron,
            "n_index":   n_index,
            "le_nominal": le_nominal,
            "le_lectura": le_lectura,
        }

    def _open_keypad(self, field: QLineEdit) -> None:
        """Abre el teclado numérico táctil para el campo dado."""
        pad = NumericKeypad(field.text(), self)
        pad.value_confirmed.connect(lambda val, f=field: f.setText(val))
        pad.exec()

    def get_data(self) -> list[dict]:
        """
        Retorna la lista de filas en formato compatible con det_exactitud:
        [{punto_id, valor_nominal, lectura_inicial, is_patron, descripcion}, ...]
        """
        result = []
        for row in self._rows_wgt:
            nom_txt = row["le_nominal"].text().strip()
            lec_txt = row["le_lectura"].text().strip()
            try:
                nom_val = float(nom_txt) if nom_txt else None
            except ValueError:
                nom_val = None
            try:
                lec_val = float(lec_txt) if lec_txt else None
            except ValueError:
                lec_val = None
            result.append({
                "punto_id":      row["paso"],
                "posicion_id":   row["paso"],
                "valor_nominal": nom_val,
                "lectura_inicial": lec_val,
                "lectura_final":   lec_val,
                "descripcion":   row["label"],
                "es_patron":     row["is_patron"],
                "n_enlace":      row["n_index"],
            })
        return result

    def load_data(self, rows: list[dict]) -> None:
        """Pre-carga datos guardados previamente."""
        for saved in rows:
            paso = saved.get("punto_id", saved.get("posicion_id", 1))
            for row in self._rows_wgt:
                if row["paso"] == paso:
                    nom = saved.get("valor_nominal")
                    lec = saved.get("lectura_inicial") or saved.get("lectura_final")
                    if nom is not None and row["le_nominal"].isEnabled():
                        row["le_nominal"].setText(str(nom))
                    if lec is not None:
                        row["le_lectura"].setText(str(lec))
                    break


# ══════════════════════════════════════════════════════════════════════════════
# TomDigitalDialog — Diálogo principal táctil
# ══════════════════════════════════════════════════════════════════════════════
class TomDigitalDialog(QDialog):

    """
    Formulario táctil completo para llenado en campo (Tablet).

    Flujo:
        1. Técnico abre la OS asignada (desde SQLite local o PostgreSQL)
        2. Llena datos del equipo y pruebas metrológicas con teclado numérico
        3. Captura firmas táctiles
        4. Guarda → SQLite (PENDING) + genera PDF local
    """

    servicio_completado = pyqtSignal(str)   # Emite folio_os al finalizar

    # ── Columnas de las tablas metrológicas ──────────────────────────────────
    _HEADERS_REP  = ["Pesada", "Lectura Inicial", "Lectura Final", "Error"]
    _HEADERS_EXC  = ["Posición", "Lectura Inicial", "Lectura Final", "Error"]
    _HEADERS_EXAC = ["Punto", "Valor Nominal", "Lectura Inicial", "Error"]

    def __init__(
        self,
        folio_os:  str,
        os_data:   Optional[dict] = None,
        os_id:     int = 0,
        parent=None,
    ):
        super().__init__(parent)
        self._folio_os = folio_os
        self._os_data  = os_data or {}
        self._os_id    = os_id

        self.setWindowTitle(f"📱  Formulario Táctil — {folio_os}")
        self.setWindowState(Qt.WindowState.WindowMaximized)
        self.setStyleSheet(f"background: {_BG};")

        self._build_ui()
        self._load_os_data()

    # ── Regla de calibración (NOM-010-SCFI-2020) ─────────────────────────────

    def _es_calibracion(self) -> bool:
        """
        Retorna True si el tipo de servicio requiere capturar Inicial J/I/A y CCA.
        Utiliza la misma regla de palabras clave que el generador de PDF:
          'calibraci' (normalizado) en el nombre del tipo de servicio.
        """
        tipo = str(
            self._os_data.get("tipo_servicio_nombre") or
            self._os_data.get("tipo_servicio")        or
            ""
        ).strip().lower()
        # Normalizar acentos para comparación robusta
        tipo_norm = (
            tipo.replace('\u00e1', 'a').replace('\u00e9', 'e')
                .replace('\u00ed', 'i').replace('\u00f3', 'o').replace('\u00fa', 'u')
        )
        return "calibraci" in tipo_norm

    # ── Construcción de UI ────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # ── Barra superior ────────────────────────────────────────────────────
        top_bar = self._build_top_bar()
        root.addWidget(top_bar)

        # ── Contenido con scroll ──────────────────────────────────────────────
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setStyleSheet("background: transparent; border: none;")

        content = QWidget()
        content.setStyleSheet(f"background: {_BG};")
        self._content_lay = QVBoxLayout(content)
        self._content_lay.setContentsMargins(20, 16, 20, 16)
        self._content_lay.setSpacing(16)

        # Bloque 1: Datos del Equipo
        self._content_lay.addWidget(self._build_equipo_block())

        # Bloque 2: Pruebas Metrológicas (Tabs)
        self._content_lay.addWidget(self._build_pruebas_block())

        # Bloque 3: Observaciones
        self._content_lay.addWidget(self._build_observaciones_block())

        # Bloque 4: Firmas
        self._content_lay.addWidget(self._build_firmas_block())

        self._content_lay.addStretch()
        scroll.setWidget(content)
        root.addWidget(scroll, stretch=1)

        # ── Barra inferior de acción ──────────────────────────────────────────
        bottom_bar = self._build_bottom_bar()
        root.addWidget(bottom_bar)

    def _build_top_bar(self) -> QWidget:
        """Barra superior: Folio | Cliente | Técnico | Fecha | Modo."""
        bar = QFrame()
        bar.setFixedHeight(70)
        bar.setStyleSheet(f"""
            QFrame {{
                background: {_DARK};
                border-bottom: 2px solid {_RED};
            }}
        """)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(20, 0, 20, 0)
        lay.setSpacing(16)

        def _lbl(text: str, is_bold: bool = False) -> QLabel:
            l = QLabel(text)
            l.setStyleSheet(
                f"color: {'#FFFFFF' if is_bold else '#AEAEB2'}; "
                f"font-size: {'16px' if is_bold else '12px'}; "
                f"font-weight: {'700' if is_bold else '400'}; "
                "background: transparent;"
            )
            return l

        # Folio
        folio_col = QVBoxLayout()
        folio_col.addWidget(_lbl("Folio"))
        self._lbl_folio = _lbl(self._folio_os, True)
        self._lbl_folio.setStyleSheet(
            f"color: {_RED}; font-size: 16px; font-weight: 700; background: transparent;"
        )
        folio_col.addWidget(self._lbl_folio)
        lay.addLayout(folio_col)

        self._sep("gray", lay)

        # Cliente
        cliente_col = QVBoxLayout()
        cliente_col.addWidget(_lbl("Cliente"))
        self._lbl_cliente = _lbl(self._os_data.get("cliente", "—"), True)
        cliente_col.addWidget(self._lbl_cliente)
        lay.addLayout(cliente_col)

        self._sep("gray", lay)

        # Técnico
        tec_col = QVBoxLayout()
        tec_col.addWidget(_lbl("Técnico"))
        tec_name = self._os_data.get("tecnico_nombre", "—")
        if _HAS_SESSION and _session and _session.is_authenticated:
            tec_name = _session.nombre_completo or tec_name
        self._lbl_tecnico = _lbl(tec_name, True)
        tec_col.addWidget(self._lbl_tecnico)
        lay.addLayout(tec_col)

        self._sep("gray", lay)

        # Fecha
        fecha_col = QVBoxLayout()
        fecha_col.addWidget(_lbl("Fecha"))
        fecha_str = self._os_data.get("fecha", date.today().isoformat())
        self._lbl_fecha = _lbl(fecha_str, True)
        fecha_col.addWidget(self._lbl_fecha)
        lay.addLayout(fecha_col)

        lay.addStretch()

        # Badge Offline / Online
        self._lbl_modo = QLabel()
        self._lbl_modo.setFixedHeight(30)
        self._lbl_modo.setStyleSheet("""
            background: rgba(255,159,10,0.15);
            color: #FF9F0A;
            font-size: 12px;
            font-weight: 700;
            border-radius: 8px;
            padding: 0 12px;
        """)
        self._update_mode_badge()
        lay.addWidget(self._lbl_modo)

        # Botón cerrar
        btn_close = QPushButton("✕")
        btn_close.setFixedSize(44, 44)
        btn_close.setStyleSheet("""
            QPushButton {
                background: rgba(255,255,255,0.10);
                color: white;
                border: none;
                border-radius: 10px;
                font-size: 16px;
                font-weight: 700;
            }
            QPushButton:hover { background: rgba(255,59,48,0.8); }
        """)
        btn_close.clicked.connect(self.reject)
        lay.addWidget(btn_close)
        return bar

    @staticmethod
    def _sep(color: str, lay: QHBoxLayout) -> None:
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.VLine)
        sep.setStyleSheet(f"background: rgba(255,255,255,0.15); max-width: 1px;")
        sep.setFixedWidth(1)
        lay.addWidget(sep)

    def _update_mode_badge(self) -> None:
        if _HAS_SYNC and _sync_manager and _sync_manager.is_online():
            self._lbl_modo.setText("  🟢  Conectado — PostgreSQL  ")
            self._lbl_modo.setStyleSheet("""
                background: rgba(52,199,89,0.15);
                color: #34C759;
                font-size: 12px; font-weight: 700;
                border-radius: 8px; padding: 0 12px;
            """)
        else:
            self._lbl_modo.setText("  🟡  Offline — SQLite Local  ")
            self._lbl_modo.setStyleSheet("""
                background: rgba(255,159,10,0.15);
                color: #FF9F0A;
                font-size: 12px; font-weight: 700;
                border-radius: 8px; padding: 0 12px;
            """)

    def _build_section_header(self, icon: str, title: str, color: str) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 4)
        lbl = QLabel(f"{icon}  {title}")
        lbl.setStyleSheet(
            f"font-size: 15px; font-weight: 700; color: {color}; background: transparent;"
        )
        lay.addWidget(lbl)
        lay.addStretch()
        return w

    def _build_equipo_block(self) -> QFrame:
        """Bloque de datos del instrumento (táctil, campos grandes)."""
        frame = QFrame()
        frame.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-radius: 14px;
                border: 1.5px solid rgba(0,0,0,0.06);
            }}
        """)
        lay = QVBoxLayout(frame)
        lay.setContentsMargins(20, 16, 20, 16)
        lay.setSpacing(12)

        lay.addWidget(self._build_section_header("🔧", "Datos del Instrumento", _BLUE))

        grid = QGridLayout()
        grid.setSpacing(10)

        def _field(label: str, col: int, row: int, attr: str, placeholder: str = "") -> None:
            lbl = QLabel(label)
            lbl.setStyleSheet("font-size: 12px; font-weight: 600; color: #6B7280; background: transparent;")
            grid.addWidget(lbl, row * 2, col)

            le = QLineEdit()
            le.setPlaceholderText(placeholder)
            le.setMinimumHeight(_TOUCH_BTN_H)
            le.setStyleSheet(f"""
                QLineEdit {{
                    font-size: {_TOUCH_FONT}px;
                    background: #F7F8FA;
                    border: 1.5px solid #E5E7EB;
                    border-radius: 10px;
                    padding: 0 14px;
                    color: {_DARK};
                }}
                QLineEdit:focus {{
                    background: {_WHITE};
                    border: 1.5px solid {_BLUE};
                }}
            """)
            setattr(self, attr, le)
            grid.addWidget(le, row * 2 + 1, col)

        _field("Marca",          0, 0, "_inp_marca",    "Ejemplo: METTLER TOLEDO")
        _field("Modelo",         1, 0, "_inp_modelo",   "Ejemplo: ICS465")
        _field("N° Serie",       2, 0, "_inp_ns",       "Número de serie")
        _field("Capacidad Max",  0, 1, "_inp_capacidad", "ej. 30000")
        _field("División",       1, 1, "_inp_division",  "ej. 10")
        _field("Ubicación",      2, 1, "_inp_ubicacion", "Planta / Área")

        lay.addLayout(grid)

        # ── Bloque condicional: Inicial J/I/A + Número CCA ──────────────────────
        # Visible SOLO cuando el servicio incluye Calibración (NOM-010-SCFI-2020)
        self._frame_calib = QFrame()
        self._frame_calib.setStyleSheet(f"""
            QFrame {{
                background: rgba(200,16,46,0.05);
                border: 1.5px solid rgba(200,16,46,0.25);
                border-radius: 10px;
            }}
        """)
        _calib_lay = QVBoxLayout(self._frame_calib)
        _calib_lay.setContentsMargins(14, 10, 14, 10)
        _calib_lay.setSpacing(8)

        _lbl_calib_hdr = QLabel("🛡️  Datos de Calibración  (NOM-010-SCFI-2020)")
        _lbl_calib_hdr.setStyleSheet(
            "font-size: 13px; font-weight: 700; color: #C8102E; background: transparent;"
        )
        _calib_lay.addWidget(_lbl_calib_hdr)

        _calib_row = QHBoxLayout()
        _calib_row.setSpacing(16)

        # Inicial del Calibrador — toggles J / I / A (touch-friendly, 52×52 px)
        _ini_col = QVBoxLayout(); _ini_col.setSpacing(6)
        _lbl_ini = QLabel("Inicial del Calibrador:")
        _lbl_ini.setStyleSheet("font-size: 12px; font-weight: 600; color: #6B7280; background: transparent;")
        _ini_col.addWidget(_lbl_ini)

        _ini_row = QHBoxLayout(); _ini_row.setSpacing(8)
        self._btn_ini_j = QPushButton("J")
        self._btn_ini_i = QPushButton("I")
        self._btn_ini_a = QPushButton("A")
        for _btn in (self._btn_ini_j, self._btn_ini_i, self._btn_ini_a):
            _btn.setCheckable(True)
            _btn.setFixedSize(52, 52)
            _btn.setStyleSheet("""
                QPushButton {
                    background: #F2F2F7; color: #1D1D1F;
                    border: 2px solid #D1D5DB; border-radius: 10px;
                    font-size: 18px; font-weight: 700;
                }
                QPushButton:checked {
                    background: #C8102E; color: white;
                    border-color: #A00020;
                }
            """)
        from PyQt6.QtWidgets import QButtonGroup as _BG
        _ini_grp = _BG(self)
        _ini_grp.setExclusive(True)
        _ini_grp.addButton(self._btn_ini_j)
        _ini_grp.addButton(self._btn_ini_i)
        _ini_grp.addButton(self._btn_ini_a)
        _ini_row.addWidget(self._btn_ini_j)
        _ini_row.addWidget(self._btn_ini_i)
        _ini_row.addWidget(self._btn_ini_a)
        _ini_row.addStretch()
        _ini_col.addLayout(_ini_row)
        _calib_row.addLayout(_ini_col)

        # Número de Certificado CCA
        _cca_col = QVBoxLayout(); _cca_col.setSpacing(6)
        _lbl_cca = QLabel("Número de Certificado CCA:")
        _lbl_cca.setStyleSheet("font-size: 12px; font-weight: 600; color: #6B7280; background: transparent;")
        _cca_col.addWidget(_lbl_cca)
        self._inp_cca = QLineEdit()
        self._inp_cca.setPlaceholderText("Ej: CCA-PESA-26-001")
        self._inp_cca.setMinimumHeight(_TOUCH_BTN_H)
        self._inp_cca.setStyleSheet(f"""
            QLineEdit {{
                font-size: {_TOUCH_FONT}px;
                background: #FFF5F7;
                border: 1.5px solid rgba(200,16,46,0.35);
                border-radius: 10px;
                padding: 0 14px; color: {_DARK};
            }}
            QLineEdit:focus {{
                background: white;
                border-color: #C8102E;
            }}
        """)
        _cca_col.addWidget(self._inp_cca)
        _calib_row.addLayout(_cca_col, stretch=1)

        _calib_lay.addLayout(_calib_row)
        lay.addWidget(self._frame_calib)
        # Se oculta por defecto; _aplicar_reglas_servicio() lo mostrará si aplica
        self._frame_calib.setVisible(False)

        return frame

    def _build_pruebas_block(self) -> QFrame:
        """Bloque de pruebas metrológicas con pestañas táctiles."""
        frame = QFrame()
        frame.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-radius: 14px;
                border: 1.5px solid rgba(0,0,0,0.06);
            }}
        """)
        lay = QVBoxLayout(frame)
        lay.setContentsMargins(16, 16, 16, 16)
        lay.setSpacing(12)

        lay.addWidget(self._build_section_header("📊", "Pruebas Metrológicas", _RED))

        tabs = QTabWidget()
        tabs.setStyleSheet("""
            QTabWidget::pane { border: none; }
            QTabBar::tab {
                background: #F2F2F7;
                padding: 12px 20px;
                font-size: 14px;
                font-weight: 600;
                color: #6B7280;
                border-radius: 8px 8px 0 0;
                margin-right: 4px;
                min-height: 48px;
            }
            QTabBar::tab:selected {
                background: white;
                color: #E63946;
            }
        """)

        # Repetibilidad
        self._tbl_rep = TouchTableWidget(
            "Repetibilidad", self._HEADERS_REP, rows=3, color=_RED
        )
        tabs.addTab(self._tbl_rep, "🔄  Repetibilidad")

        # ── Detectar modo de Calibración por Enlaces de Sustitución ──────────
        _es_enlaces  = bool(self._os_data.get("es_enlace_sustitucion"))
        _n_enlaces   = int(self._os_data.get("num_enlaces_sustitucion") or 4)

        if _es_enlaces:
            # Modo Tanque: ocultar Excentricidad, usar widget especial de enlaces
            self._tbl_exc = None    # no aplica para Tanque
            self._tbl_exac = None   # sustituido por el widget de enlaces

            self._w_enlaces_sustitucion = EnlacesSustitucionWidget(n_enlaces=_n_enlaces)
            tabs.addTab(self._w_enlaces_sustitucion, "🔗  Exactitud (Sustitución)")
        else:
            # Modo estándar: Excentricidad + Exactitud con tabla normal
            self._w_enlaces_sustitucion = None

            self._tbl_exc = TouchTableWidget(
                "Excentricidad", self._HEADERS_EXC, rows=6, color=_AMBER
            )
            tabs.addTab(self._tbl_exc, "⚖️  Excentricidad")

            self._tbl_exac = TouchTableWidget(
                "Exactitud", self._HEADERS_EXAC, rows=10, color=_BLUE, has_nominal=True
            )
            tabs.addTab(self._tbl_exac, "🎯  Exactitud")

        lay.addWidget(tabs)
        return frame


    def _build_observaciones_block(self) -> QFrame:
        """Bloque de observaciones con teclado virtual hint."""
        frame = QFrame()
        frame.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-radius: 14px;
                border: 1.5px solid rgba(0,0,0,0.06);
            }}
        """)
        lay = QVBoxLayout(frame)
        lay.setContentsMargins(20, 16, 20, 16)
        lay.setSpacing(10)

        lay.addWidget(self._build_section_header("📝", "Observaciones del Servicio", _GRAY))

        self._txt_obs = QTextEdit()
        self._txt_obs.setPlaceholderText(
            "Describa el estado del instrumento, condiciones ambientales, "
            "anomalías encontradas o cualquier observación relevante del servicio..."
        )
        self._txt_obs.setMinimumHeight(120)
        self._txt_obs.setStyleSheet(f"""
            QTextEdit {{
                font-size: {_TOUCH_FONT}px;
                background: #F7F8FA;
                border: 1.5px solid #E5E7EB;
                border-radius: 10px;
                padding: 12px;
                color: {_DARK};
            }}
            QTextEdit:focus {{
                background: {_WHITE};
                border: 1.5px solid {_BLUE};
            }}
        """)
        lay.addWidget(self._txt_obs)
        return frame

    def _build_firmas_block(self) -> QFrame:
        """Bloque de firmas táctiles dobles (técnico + cliente)."""
        frame = QFrame()
        frame.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-radius: 14px;
                border: 1.5px solid rgba(0,0,0,0.06);
            }}
        """)
        lay = QVBoxLayout(frame)
        lay.setContentsMargins(20, 16, 20, 16)
        lay.setSpacing(14)

        lay.addWidget(self._build_section_header("✍️", "Firmas Digitales", _GREEN))

        firmas_row = QHBoxLayout()
        firmas_row.setSpacing(16)

        for attr, title, color, name_attr in [
            ("_canvas_tecnico", "Técnico Responsable", _BLUE,  "_inp_nombre_tecnico"),
            ("_canvas_cliente", "Receptor / Cliente",  _GREEN, "_inp_nombre_cliente"),
        ]:
            col = QVBoxLayout()
            col.setSpacing(8)

            # Nombre
            lbl_n = QLabel(f"{title}:")
            lbl_n.setStyleSheet(
                f"font-size: 13px; font-weight: 700; color: {color}; background: transparent;"
            )
            col.addWidget(lbl_n)

            name_le = QLineEdit()
            name_le.setPlaceholderText("Nombre completo...")
            name_le.setMinimumHeight(_TOUCH_BTN_H)
            name_le.setStyleSheet(f"""
                QLineEdit {{
                    font-size: {_TOUCH_FONT}px;
                    background: #F7F8FA;
                    border: 1.5px solid #E5E7EB;
                    border-radius: 10px;
                    padding: 0 14px;
                    color: {_DARK};
                }}
                QLineEdit:focus {{
                    background: {_WHITE};
                    border: 1.5px solid {color};
                }}
            """)
            setattr(self, name_attr, name_le)
            col.addWidget(name_le)

            # Canvas de firma
            canvas = DrawingCanvas(f"Firme aquí — {title}", self)
            canvas.setMinimumHeight(150)
            canvas.setStyleSheet(f"""
                background: #FCFCFC;
                border: 2px solid {color};
                border-radius: 10px;
            """)
            setattr(self, attr, canvas)
            col.addWidget(canvas, stretch=1)

            # Botón limpiar
            btn_clear = QPushButton("🗑️  Limpiar firma")
            btn_clear.setFixedHeight(44)
            btn_clear.setStyleSheet(f"""
                QPushButton {{
                    background: rgba(255,59,48,0.08);
                    color: #FF3B30;
                    border: 1px solid rgba(255,59,48,0.20);
                    border-radius: 10px;
                    font-size: 13px;
                    font-weight: 600;
                }}
                QPushButton:hover {{ background: rgba(255,59,48,0.14); }}
            """)
            btn_clear.clicked.connect(canvas.clear)
            col.addWidget(btn_clear)

            firmas_row.addLayout(col)

        lay.addLayout(firmas_row)
        return frame

    def _build_bottom_bar(self) -> QWidget:
        """Barra inferior fija con el botón principal de guardado."""
        bar = QFrame()
        bar.setFixedHeight(80)
        bar.setStyleSheet(f"""
            QFrame {{
                background: {_WHITE};
                border-top: 1px solid rgba(0,0,0,0.08);
            }}
        """)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(20, 12, 20, 12)
        lay.setSpacing(12)

        # Indicador de guardado local
        self._lbl_save_status = QLabel("  📋  Los datos se guardan localmente hasta sincronizar")
        self._lbl_save_status.setStyleSheet(
            "font-size: 12px; color: #86868B; background: transparent;"
        )
        lay.addWidget(self._lbl_save_status)
        lay.addStretch()

        # Botón secundario: guardar borrador
        btn_draft = QPushButton("💾  Guardar Borrador")
        btn_draft.setFixedHeight(_TOUCH_BTN_H + 4)
        btn_draft.setMinimumWidth(180)
        btn_draft.setStyleSheet(f"""
            QPushButton {{
                background: rgba(0,122,255,0.08);
                color: {_BLUE};
                border: 1.5px solid rgba(0,122,255,0.25);
                border-radius: 12px;
                font-size: 14px;
                font-weight: 600;
                padding: 0 20px;
            }}
            QPushButton:hover {{ background: rgba(0,122,255,0.14); }}
        """)
        btn_draft.clicked.connect(lambda: self._on_guardar(draft=True))
        lay.addWidget(btn_draft)

        # Botón principal: guardar y generar PDF
        self._btn_save = QPushButton("  💾   Guardar y Generar PDF en Tablet  ")
        self._btn_save.setFixedHeight(_TOUCH_BTN_H + 4)
        self._btn_save.setMinimumWidth(280)
        self._btn_save.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_save.setStyleSheet(f"""
            QPushButton {{
                background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                    stop:0 {_RED}, stop:1 {_DRED});
                color: white;
                border: none;
                border-radius: 12px;
                font-size: 15px;
                font-weight: 700;
                padding: 0 24px;
            }}
            QPushButton:hover {{
                background: qlineargradient(x1:0,y1:0,x2:1,y2:0,
                    stop:0 {_DRED}, stop:1 #A5262F);
            }}
            QPushButton:disabled {{ background: #C7C7CC; }}
        """)
        self._btn_save.clicked.connect(lambda: self._on_guardar(draft=False))
        lay.addWidget(self._btn_save)

        return bar

    # ── Carga de datos ────────────────────────────────────────────────────────

    def _load_os_data(self) -> None:
        """Pre-carga datos de la OS desde SQLite local o del diccionario os_data."""
        local_data = None

        # Intentar desde SQLite primero
        if _HAS_SYNC and _sync_manager:
            local_data = _sync_manager.get_local_order(self._folio_os)

        # Combinar: preferencia a SQLite, fallback a os_data pasado como parámetro
        data = local_data or self._os_data

        # Encabezado
        self._lbl_cliente.setText(
            data.get("cliente_nombre", data.get("cliente", "—"))
        )
        tec = data.get("tecnico_nombre", data.get("tecnico_nombre", ""))
        if _HAS_SESSION and _session and _session.is_authenticated:
            tec = _session.nombre_completo or tec
        self._lbl_tecnico.setText(tec)
        self._lbl_fecha.setText(
            data.get("fecha", date.today().isoformat())
        )

        # Instrumento
        self._inp_marca.setText(data.get("marca", ""))
        self._inp_modelo.setText(data.get("modelo", ""))
        self._inp_ns.setText(data.get("ns", ""))
        self._inp_ubicacion.setText(data.get("ubicacion", ""))
        if data.get("alcance_max"):
            self._inp_capacidad.setText(str(data["alcance_max"]))
        if data.get("div_minima"):
            self._inp_division.setText(str(data["div_minima"]))

        # Observaciones
        self._txt_obs.setPlainText(data.get("observaciones", ""))

        # Nombre de firmantes
        self._inp_nombre_tecnico.setText(tec)
        self._inp_nombre_cliente.setText(data.get("firma_cliente_nombre", ""))

        # Aplicar reglas metrológicas de calibración
        self._aplicar_reglas_servicio()

    def _aplicar_reglas_servicio(self) -> None:
        """
        Muestra u oculta los campos de Calibración (Inicial J/I/A + CCA)
        según si el tipo de servicio requiere calibración (NOM-010-SCFI-2020).
        Debe llamarse después de que os_data esté disponible.
        """
        es_calib = self._es_calibracion()
        if hasattr(self, '_frame_calib'):
            self._frame_calib.setVisible(es_calib)

        # Pre-llenar inicial si ya viene en los datos
        if es_calib and hasattr(self, '_btn_ini_j'):
            ini = str(
                self._os_data.get("inicial_calibrador") or
                self._os_data.get("inicial") or ""
            ).strip().upper()
            self._btn_ini_j.setChecked(ini == "J")
            self._btn_ini_i.setChecked(ini == "I")
            self._btn_ini_a.setChecked(ini == "A")

        # Pre-llenar CCA si ya viene en los datos
        if es_calib and hasattr(self, '_inp_cca'):
            cca_val = str(
                self._os_data.get("numero_cca") or
                self._os_data.get("cca") or ""
            ).strip()
            self._inp_cca.setText(cca_val)

    # ── Guardado ──────────────────────────────────────────────────────────────

    def _on_guardar(self, draft: bool = False) -> None:
        """Valida, guarda en SQLite y opcionalmente genera PDF."""
        if not draft:
            # ── Validación de campos de calibración (NOM-010-SCFI-2020) ─────────
            if self._es_calibracion():
                calib_faltantes = []
                ini_sel = (
                    (hasattr(self, '_btn_ini_j') and self._btn_ini_j.isChecked()) or
                    (hasattr(self, '_btn_ini_i') and self._btn_ini_i.isChecked()) or
                    (hasattr(self, '_btn_ini_a') and self._btn_ini_a.isChecked())
                )
                if not ini_sel:
                    calib_faltantes.append("• Inicial del Calibrador  (J / I / A)")
                if hasattr(self, '_inp_cca') and not self._inp_cca.text().strip():
                    calib_faltantes.append("• Número de Certificado CCA")

                if calib_faltantes:
                    QMessageBox.critical(
                        self,
                        "⛔  Datos de Calibración Obligatorios",
                        "Este servicio es de Calibración (NOM-010-SCFI-2020).\n\n"
                        "Los siguientes campos son OBLIGATORIOS antes de guardar:\n\n" +
                        "\n".join(calib_faltantes) +
                        "\n\nCompleta estos campos y vuelve a intentarlo."
                    )
                    return
            # ── Validación general de formulario ─────────────────────────────────
            warnings = self._validate()
            if warnings:
                resp = QMessageBox.warning(
                    self,
                    "Formulario Incompleto",
                    "Datos faltantes:\n\n" + "\n".join(warnings) +
                    "\n\n¿Guardar de todas formas?",
                    QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                    QMessageBox.StandardButton.No,
                )
                if resp != QMessageBox.StandardButton.Yes:
                    return

        self._btn_save.setEnabled(False)
        self._btn_save.setText("Guardando…")
        QApplication.processEvents()

        try:
            form_data = self._collect_form_data(draft)

            # 1. Guardar en SQLite local (siempre)
            pdf_path = None
            if not draft:
                try:
                    pdf_path = self._generate_pdf_local(form_data)
                except Exception as exc:
                    logger.error("Error generando PDF: %s", exc)

            saved = True
            if _HAS_SYNC and _sync_manager:
                saved = _sync_manager.save_local_service(
                    self._folio_os, form_data, pdf_path
                )

            # 2. Intentar guardar también en PostgreSQL si hay conexión
            if not draft and _HAS_SYNC and _sync_manager and _sync_manager.is_online():
                try:
                    from database.connection import db_pool
                    pg_conn = db_pool.get_connection()
                    try:
                        self._save_to_postgres(pg_conn, form_data)
                    finally:
                        db_pool.release_connection(pg_conn)
                    logger.info("OS %s guardada también en PostgreSQL.", self._folio_os)
                except Exception as exc:
                    logger.warning("No se pudo guardar en PostgreSQL: %s", exc)

            if not saved:
                raise RuntimeError("No se pudo guardar en SQLite local.")

            # Feedback
            mode_msg = "borrador guardado" if draft else "servicio completado"
            pdf_msg  = f"\n\nPDF generado:\n{pdf_path}" if pdf_path else ""
            QMessageBox.information(
                self,
                "✅ Guardado",
                f"Orden {self._folio_os}: {mode_msg}.{pdf_msg}\n\n"
                f"{'Los datos se sincronizarán al conectarse a la red de oficina.' if not draft else ''}"
            )

            if not draft:
                self.servicio_completado.emit(self._folio_os)
                self.accept()

        except Exception as exc:
            logger.exception("Error guardando formulario táctil: %s", exc)
            QMessageBox.critical(
                self, "Error al Guardar",
                f"Error inesperado:\n{exc}\n\nRevisa los logs para más detalles."
            )
        finally:
            self._btn_save.setEnabled(True)
            self._btn_save.setText("  💾   Guardar y Generar PDF en Tablet  ")

    def _validate(self) -> list[str]:
        warnings: list[str] = []
        if not self._inp_marca.text().strip():
            warnings.append("• Falta la Marca del instrumento.")
        if self._canvas_tecnico.is_empty():
            warnings.append("• Falta la firma del Técnico.")
        if not self._inp_nombre_cliente.text().strip():
            warnings.append("• Falta el nombre del receptor/cliente.")
        return warnings

    def _collect_form_data(self, draft: bool = False) -> dict:
        return {
            "folio_os":             self._folio_os,
            "os_id":                self._os_id,
            "fecha":                date.today().isoformat(),
            "equipo_marca":         self._inp_marca.text().strip(),
            "equipo_modelo":        self._inp_modelo.text().strip(),
            "equipo_ns":            self._inp_ns.text().strip(),
            "equipo_ubicacion":     self._inp_ubicacion.text().strip(),
            "alcance_max":          self._inp_capacidad.text().strip(),
            "div_minima":           self._inp_division.text().strip(),
            "observaciones":        self._txt_obs.toPlainText().strip(),
            "nombre_tecnico_firma": self._inp_nombre_tecnico.text().strip(),
            "nombre_cliente_firma": self._inp_nombre_cliente.text().strip(),
            "firma_tecnico":        self._canvas_tecnico.to_base64_png(),
            "firma_cliente":        self._canvas_cliente.to_base64_png(),
            "repetibilidad":        self._tbl_rep.get_data(),
            "excentricidad":        (
                self._tbl_exc.get_data()
                if self._tbl_exc is not None
                else []
            ),
            "exactitud":            (
                self._w_enlaces_sustitucion.get_data()
                if getattr(self, "_w_enlaces_sustitucion", None) is not None
                else (self._tbl_exac.get_data() if self._tbl_exac is not None else [])
            ),
            "estado":               "PROCESO" if draft else "Cerrada",  # Cerrada = digital completada
            "timestamp":            datetime.now().isoformat(),
        }


    def _save_to_postgres(self, pg_conn, form_data: dict) -> None:
        """Guarda directamente en PostgreSQL si hay conectividad."""
        with pg_conn.cursor() as cur:
            cur.execute("""
                UPDATE ordenes_servicio SET
                    marca                = COALESCE(%s, marca),
                    modelo               = COALESCE(%s, modelo),
                    ns                   = COALESCE(%s, ns),
                    ubicacion            = COALESCE(%s, ubicacion),
                    observaciones        = COALESCE(%s, observaciones),
                    firma_cliente_nombre = COALESCE(%s, firma_cliente_nombre),
                    firma_tecnico_b64    = %s,
                    firma_cliente_b64    = %s,
                    estado               = %s,
                    modalidad            = 'Digital',
                    sync_status          = 'SYNCED',
                    updated_at           = NOW()
                WHERE folio_os = %s
            """, (
                form_data.get("equipo_marca") or None,
                form_data.get("equipo_modelo") or None,
                form_data.get("equipo_ns") or None,
                form_data.get("equipo_ubicacion") or None,
                form_data.get("observaciones") or None,
                form_data.get("nombre_cliente_firma") or None,
                form_data.get("firma_tecnico") or None,
                form_data.get("firma_cliente") or None,
                form_data.get("estado", "Cerrada"),
                self._folio_os,
            ))
        pg_conn.commit()

    def _generate_pdf_local(self, form_data: dict) -> Optional[str]:
        """Genera el PDF localmente y lo guarda en TABLET_PDF_DIR."""
        if not _HAS_PDF:
            logger.warning("OsPdfGenerator no disponible, omitiendo generación de PDF.")
            return None

        pdf_dir = Path(TABLET_PDF_DIR)
        pdf_dir.mkdir(parents=True, exist_ok=True)
        pdf_path = str(pdf_dir / f"{self._folio_os}.pdf")

        try:
            gen = OsPdfGenerator()

            # Preparar datos compatibles con el generador
            os_dict = {**self._os_data, **form_data}
            os_dict["folio_os"]           = self._folio_os
            os_dict["marca"]              = form_data.get("equipo_marca", "")
            os_dict["modelo"]             = form_data.get("equipo_modelo", "")
            os_dict["ns"]                 = form_data.get("equipo_ns", "")
            os_dict["alcance_max"]        = form_data.get("alcance_max", "")
            os_dict["div_minima"]         = form_data.get("div_minima", "")
            os_dict["firma_cliente_nombre"] = form_data.get("nombre_cliente_firma", "")

            # Convertir firmas b64 a pixmaps
            import base64
            def _b64_to_pixmap(b64: str) -> Optional[QPixmap]:
                if not b64:
                    return None
                try:
                    data = base64.b64decode(b64)
                    pix = QPixmap()
                    pix.loadFromData(data, "PNG")
                    return pix
                except Exception:
                    return None

            os_dict["firma_tecnico_pixmap"] = _b64_to_pixmap(form_data.get("firma_tecnico", ""))
            os_dict["firma_cliente_pixmap"] = _b64_to_pixmap(form_data.get("firma_cliente", ""))
            os_dict["repetibilidad"]  = form_data.get("repetibilidad", [])
            os_dict["excentricidad"]  = form_data.get("excentricidad", [])
            os_dict["exactitud"]      = form_data.get("exactitud", [])

            gen.generate(os_dict, pdf_path)
            logger.info("PDF generado localmente: %s", pdf_path)
            return pdf_path

        except Exception as exc:
            logger.error("Error generando PDF local: %s", exc)
            return None


# ── Función pública de apertura ───────────────────────────────────────────────

def open_tablet_form(
    folio_os: str,
    os_data:  Optional[dict] = None,
    os_id:    int = 0,
    parent=None,
) -> bool:
    """
    Abre el formulario táctil y retorna True si el técnico completó el servicio.

    Uso desde dashboard:
        completado = open_tablet_form(folio_os="OS-2025-001", os_data={...}, parent=self)
    """
    dlg = TomDigitalDialog(
        folio_os=folio_os,
        os_data=os_data,
        os_id=os_id,
        parent=parent,
    )
    result = dlg.exec()
    return result == QDialog.DialogCode.Accepted
