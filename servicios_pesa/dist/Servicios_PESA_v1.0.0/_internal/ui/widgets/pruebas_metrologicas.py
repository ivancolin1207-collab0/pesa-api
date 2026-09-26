"""
pruebas_metrologicas.py — Widgets dinámicos para las Pruebas Metrológicas
Servicios PESA v2.2

Implementa las tres tablas del formato "Toma de Datos" con reglas condicionales:

    • RepetibilidadWidget
        Columnas: VALOR | LECTURA INICIAL | LECTURA FINAL | ERROR MÁX. TOLERADO
        3 filas por defecto

    • ExcentricidadCondicionalWidget
        Selector visual de tipo de instrumento (tarjetas con ícono):
            🏗 Plataforma   → tabla estándar (4 ó 6 posiciones)
            🌾 Tolva        → NO aplica excentricidad
            🏗 Grúa         → NO aplica excentricidad
            🛢 Tanque       → NO aplica excentricidad
            🚛 Camionera/FC → tabla según número de celdas (8→4 pts / 10→5 pts)

    • ExactitudWidget
        Columnas: N | VALOR NOMINAL | LECTURA INICIAL | LECTURA FINAL
        10 puntos por defecto (filas vacías son ignoradas al guardar)
        Clase de Exactitud: ORDINARIA/MEDIA/FINA/ESPECIAL
        Indicadores adicionales: J / I / A (checkboxes independientes)

    • PruebasMetrologicasWidget
        Panel compuesto que agrupa los tres sub-widgets.
"""
from __future__ import annotations

import logging
from typing import Optional

try:
    from services.metrology import decimals_from_d, fmt, calc_emt, emt_para_fila
except ImportError:
    # Fallback si el módulo aún no está disponible (tests aislados)
    def decimals_from_d(d): return 4
    def fmt(v, d, **kw): return '' if v is None else f'{v:.4f}'
    def calc_emt(m, e, clase=3): return e
    def emt_para_fila(m, d): return d

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTableWidget, QTableWidgetItem, QHeaderView, QDoubleSpinBox,
    QAbstractSpinBox, QGroupBox, QSizePolicy, QFrame, QButtonGroup,
    QRadioButton, QScrollArea, QCheckBox, QSpinBox, QStackedWidget,
    QAbstractItemView, QAbstractScrollArea, QComboBox,
)
from PyQt6.QtCore import Qt, pyqtSignal, QLocale
from PyQt6.QtGui import QColor, QFont, QBrush

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# PALETA DE COLOR (consistente con el resto de la app)
# ──────────────────────────────────────────────────────────────────────────────
_RED    = "#E63946"
_BLUE   = "#007AFF"
_PURPLE = "#8B5CF6"
_GREEN  = "#34C759"
_GRAY   = "#86868B"
_DARK   = "#1D1D1F"
_LGRAY  = "#D1D1D6"
_BG     = "#F5F5F7"
_WHITE  = "#FFFFFF"

# ──────────────────────────────────────────────────────────────────────────────
# CONSTANTES DE ESTILO
# ──────────────────────────────────────────────────────────────────────────────
_CELL_SB_STYLE = f"""
QDoubleSpinBox {{
    background:   {_WHITE};
    border:       none;
    color:        {_DARK};
    font-weight:  600;
    padding:      3px 6px;
    font-size:    12px;
}}
QDoubleSpinBox:focus {{
    background:   {_WHITE};
    color:        #003366;
    border-bottom: 2px solid {_RED};
}}
"""

_MINI_BTN_STYLE = f"""
QPushButton {{
    background: {_WHITE};
    color:      {_GRAY};
    border:     1px solid {_LGRAY};
    border-radius: 4px;
    font-size:  11px;
    font-weight: 600;
    padding:    3px 10px;
}}
QPushButton:hover  {{ background: {_LGRAY}; color: {_DARK}; }}
QPushButton:pressed{{ background: #F2F2F7; }}
"""

_SECTION_LABEL_STYLE = (
    f"color: {_RED}; font-size: 11px; font-weight: 800; letter-spacing: 1.2px;"
)
_ERROR_MAX_VALUE_STYLE = f"color: {_RED}; font-size: 14px; font-weight: 900;"
_ERROR_MAX_OK_STYLE    = f"color: {_GREEN}; font-size: 14px; font-weight: 900;"

_TABLE_STYLE = f"""
QTableWidget {{
    background:              {_WHITE};
    alternate-background-color: #FAFBFC;
    border:                  none;
    font-size:               12px;
    gridline-color:          #E5E7EB;
    selection-background-color: rgba(0,122,255,0.08);
    selection-color:         {_DARK};
    outline:                 none;
}}
QTableWidget::item {{
    padding: 4px 8px;
    border-bottom: 1px solid rgba(0,0,0,0.04);
}}
QTableWidget::item:selected {{
    background: rgba(0,122,255,0.08);
    color: {_DARK};
}}
QHeaderView::section {{
    background:    #F3F4F6;
    color:         #374151;
    font-size:     10px;
    font-weight:   700;
    padding:       6px 8px;
    border:        none;
    border-bottom: 1px solid #E5E7EB;
    border-right:  1px solid #E5E7EB;
    letter-spacing: 0.3px;
}}
"""


# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN UTILITARIA: SpinBox para celdas de tabla
# ──────────────────────────────────────────────────────────────────────────────
def _make_cell_spinbox(decimals: int = 4) -> QDoubleSpinBox:  # decimals controlado por d
    """
    Crea un QDoubleSpinBox optimizado para celdas de tabla:
    - Sin botones ▲▼, sin marco
    - specialValueText=" " para mostrar vacío
    - Locale inglés (punto decimal estándar BD)
    """
    sb = QDoubleSpinBox()
    sb.setDecimals(decimals)
    sb.setRange(-9_999_999.9999, 9_999_999.9999)
    sb.setSpecialValueText(" ")
    sb.setValue(sb.minimum())
    sb.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
    sb.setFrame(False)
    sb.setAlignment(Qt.AlignmentFlag.AlignCenter)
    sb.setStyleSheet(_CELL_SB_STYLE)
    locale = QLocale(QLocale.Language.English, QLocale.Country.UnitedStates)
    sb.setLocale(locale)
    return sb


def _val_or_none(sb: QDoubleSpinBox) -> Optional[float]:
    """Retorna el valor del spinbox o None si está vacío."""
    if sb is None:
        return None
    return None if sb.value() == sb.minimum() else sb.value()


def _snap_to_d(sb: QDoubleSpinBox, d: float) -> None:
    """
    Redondea el valor actual del spinbox al múltiplo más cercano de d.
    Se invoca al perder el foco (editingFinished) para garantizar consistencia
    metrológica: si d=0.002, un valor como 3.001 se corrige a 3.002.
    Solo actúa si el spinbox tiene un valor real (no el specialValueText).
    """
    if d is None or d <= 0:
        return
    val = sb.value()
    if val == sb.minimum():
        return   # campo vacío, no tocar
    import math
    snapped = round(round(val / d) * d, 10)  # evita error de punto flotante
    decimals = sb.decimals()
    snapped = round(snapped, decimals)
    if abs(snapped - val) > 1e-12:
        sb.setValue(snapped)


# ══════════════════════════════════════════════════════════════════════════════
# CLASE BASE: MetrologicaTableWidget
# ══════════════════════════════════════════════════════════════════════════════
class MetrologicaTableWidget(QWidget):
    """
    Widget base para todas las tablas de pruebas metrológicas.

    Subclases deben definir los atributos de clase:
        TITLE         Título de la sección
        HEADERS       Lista de encabezados de columna
        INITIAL_COL   Índice de la columna "Lectura Inicial"
        FINAL_COL     Índice de la columna "Lectura Final"
        NOMINAL_COL   Índice de "Valor Nominal" (-1 si no aplica)
        DEFAULT_ROWS  Número de filas al inicializar
        SHOW_VALOR    Si True, muestra el campo "VALOR:" en el encabezado
        ROW_ID_KEY    Nombre de la clave para el ID de fila al serializar
    """

    data_changed = pyqtSignal()

    TITLE:        str       = "PRUEBA METROLÓGICA"
    HEADERS:      list[str] = []
    INITIAL_COL:  int       = 1
    FINAL_COL:    int       = 2
    NOMINAL_COL:  int       = -1
    DEFAULT_ROWS: int       = 3
    SHOW_VALOR:   bool      = True
    ROW_ID_KEY:   str       = "posicion_id"

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._blocking = False
        self._setup_ui()

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(4, 4, 4, 4)
        root.setSpacing(6)
        root.addLayout(self._build_header())
        root.addWidget(self._build_table())
        root.addLayout(self._build_footer())
        self._build_extra(root)
        root.addStretch(1)

    def _build_header(self) -> QHBoxLayout:
        layout = QHBoxLayout()
        layout.setSpacing(8)

        lbl_title = QLabel(self.TITLE)
        lbl_title.setStyleSheet(_SECTION_LABEL_STYLE)
        layout.addWidget(lbl_title)
        layout.addStretch()

        if self.SHOW_VALOR:
            lbl_valor = QLabel("VALOR:")
            lbl_valor.setStyleSheet(f"color: {_GRAY}; font-size: 12px;")
            layout.addWidget(lbl_valor)

            self._spin_valor = QDoubleSpinBox()
            self._spin_valor.setDecimals(4)
            self._spin_valor.setRange(0, 9_999_999.9999)
            self._spin_valor.setSpecialValueText(" ")
            self._spin_valor.setValue(self._spin_valor.minimum())
            self._spin_valor.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
            self._spin_valor.setFixedWidth(130)
            self._spin_valor.setStyleSheet(
                f"QDoubleSpinBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
                f"border-radius:5px; padding:4px 8px; color:{_DARK}; font-weight:700; }}"
                f"QDoubleSpinBox:focus {{ border:2px solid {_RED}; }}"
            )
            layout.addWidget(self._spin_valor)
            layout.addSpacing(8)

        return layout

    def _build_table(self) -> QTableWidget:
        self._table = QTableWidget(0, len(self.HEADERS))
        self._table.setHorizontalHeaderLabels(self.HEADERS)
        self._table.verticalHeader().setVisible(False)
        self._table.setAlternatingRowColors(True)
        self._table.setShowGrid(True)
        self._table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self._table.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self._table.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._table.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self._table.setStyleSheet(_TABLE_STYLE)

        hdr = self._table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        if len(self.HEADERS) > 0:
            hdr.setSectionResizeMode(0, QHeaderView.ResizeMode.Fixed)
            self._table.setColumnWidth(0, 80)

        for _ in range(self.DEFAULT_ROWS):
            self._insert_row()

        self._update_table_height()
        return self._table

    def _build_footer(self) -> QHBoxLayout:
        layout = QHBoxLayout()
        layout.setSpacing(10)
        lbl = QLabel("ERROR MÁXIMO ENCONTRADO:")
        lbl.setStyleSheet(f"color: {_GRAY}; font-size: 12px; font-weight: 600;")
        layout.addWidget(lbl)
        self._lbl_error_max = QLabel("—")
        self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)
        self._lbl_error_max.setMinimumWidth(90)
        layout.addWidget(self._lbl_error_max)
        layout.addStretch()

        btn_add = QPushButton("+ Agregar Carga / Fila")
        btn_add.setFixedSize(140, 28)
        btn_add.setStyleSheet(
            f"QPushButton {{ background: {_WHITE}; color: {_GRAY}; border: 1px solid {_LGRAY}; border-radius: 4px; font-size: 11px; font-weight: 600; }}"
            f"QPushButton:hover {{ background: {_LGRAY}; color: {_DARK}; }}"
        )
        btn_add.clicked.connect(self.add_row)
        layout.addWidget(btn_add)

        btn_del = QPushButton("− Eliminar Fila")
        btn_del.setFixedSize(120, 28)
        btn_del.setStyleSheet(
            f"QPushButton {{ background: {_WHITE}; color: {_GRAY}; border: 1px solid {_LGRAY}; border-radius: 4px; font-size: 11px; font-weight: 600; }}"
            f"QPushButton:hover {{ background: {_LGRAY}; color: {_DARK}; }}"
        )
        btn_del.clicked.connect(self.remove_last_row)
        layout.addWidget(btn_del)

        return layout

    def _build_extra(self, layout: QVBoxLayout) -> None:
        """Hook para que subclases agreguen widgets adicionales."""
        pass

    # ── Manejo de filas ───────────────────────────────────────────────────────

    def _insert_row(self) -> None:
        row = self._table.rowCount()
        self._table.insertRow(row)
        self._table.setRowHeight(row, 36)

        for col in range(len(self.HEADERS)):
            if col == 0:
                item = QTableWidgetItem(str(row + 1))
                item.setFlags(Qt.ItemFlag.ItemIsEnabled)
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                f = QFont()
                f.setBold(True)
                item.setFont(f)
                item.setForeground(QBrush(QColor(_DARK)))
                self._table.setItem(row, col, item)
            else:
                sb = _make_cell_spinbox()
                # editingFinished → recalcula SOLO al salir del campo
                # Evita hipersensibilidad y bloqueo al teclear
                sb.editingFinished.connect(self._on_value_changed)
                self._table.setCellWidget(row, col, sb)

    def _update_table_height(self) -> None:
        """Ajusta la altura mínima razonable; la tabla puede expandirse."""
        row_h = 36
        hdr_h = self._table.horizontalHeader().height() or 28
        min_h = hdr_h + row_h * self._table.rowCount() + 4
        self._table.setMinimumHeight(min_h)
        self._table.setMaximumHeight(16777215)  # sin límite superior

    # ── Cálculo de errores ────────────────────────────────────────────────────

    def _on_value_changed(self) -> None:
        if not self._blocking:
            self._recalculate()
            self.data_changed.emit()

    def _recalculate(self) -> None:
        errors = []
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        for row in range(self._table.rowCount()):
            err = self._get_row_error(row)
            if err is not None:
                errors.append(err)
        if errors:
            max_err = max(errors)
            style = _ERROR_MAX_VALUE_STYLE if max_err > 0 else _ERROR_MAX_OK_STYLE
            # Error cero es un valor numérico válido: mostrar con decimales de d
            self._lbl_error_max.setText(f"{max_err:.{decimals}f}")
            self._lbl_error_max.setStyleSheet(style)
        else:
            # Sin datos suficientes → guión
            self._lbl_error_max.setText("—")
            self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)

    def _get_row_error(self, row: int) -> Optional[float]:
        sb_ini = self._table.cellWidget(row, self.INITIAL_COL)
        sb_fin = self._table.cellWidget(row, self.FINAL_COL)
        if sb_ini is None or sb_fin is None:
            return None
        if _val_or_none(sb_ini) is None or _val_or_none(sb_fin) is None:
            return None
        if self.NOMINAL_COL >= 0:
            sb_nom = self._table.cellWidget(row, self.NOMINAL_COL)
            if _val_or_none(sb_nom) is None:
                return None
            return abs(sb_fin.value() - sb_nom.value())
        return abs(sb_fin.value() - sb_ini.value())

    # ── API Pública ───────────────────────────────────────────────────────────

    def set_division_minima(self, d: float) -> None:
        """Actualiza la resolución de todos los spinboxes y el footer según d."""
        self._d = d
        decimals = decimals_from_d(d)
        # Reconfigurar todos los spinboxes existentes
        for row in range(self._table.rowCount()):
            for col in range(1, len(self.HEADERS)):
                sb = self._table.cellWidget(row, col)
                if isinstance(sb, QDoubleSpinBox):
                    current_val = sb.value() if sb.value() != sb.minimum() else None
                    sb.setDecimals(decimals)
                    if current_val is not None:
                        sb.setValue(current_val)
                    # Conectar validación de paso si no está ya conectada
                    try:
                        sb.editingFinished.disconnect()
                    except TypeError:
                        pass
                    sb.editingFinished.connect(self._on_value_changed)
                    _d_val = d  # captura para closure
                    sb.editingFinished.connect(lambda _sb=sb, _d=_d_val: _snap_to_d(_sb, _d))
        if self.SHOW_VALOR and hasattr(self, '_spin_valor'):
            current = self._spin_valor.value() if self._spin_valor.value() != self._spin_valor.minimum() else None
            self._spin_valor.setDecimals(decimals)
            if current is not None:
                self._spin_valor.setValue(current)
        self._recalculate()

    def add_row(self) -> None:
        self._insert_row()
        self._update_table_height()

    def remove_last_row(self) -> None:
        if self._table.rowCount() > 1:
            self._table.removeRow(self._table.rowCount() - 1)
            self._update_table_height()
            self._recalculate()
            self.data_changed.emit()

    def set_row_count(self, count: int) -> None:
        """Ajusta el número de filas de la tabla."""
        current = self._table.rowCount()
        while self._table.rowCount() < count:
            self._insert_row()
        while self._table.rowCount() > max(count, 1):
            self._table.removeRow(self._table.rowCount() - 1)
        self._update_table_height()

    def clear(self) -> None:
        self._blocking = True
        try:
            for row in range(self._table.rowCount()):
                for col in range(1, len(self.HEADERS)):
                    sb = self._table.cellWidget(row, col)
                    if sb:
                        sb.setValue(sb.minimum())
            if self.SHOW_VALOR and hasattr(self, "_spin_valor"):
                self._spin_valor.setValue(self._spin_valor.minimum())
        finally:
            self._blocking = False
        self._lbl_error_max.setText("—")
        self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)

    def get_error_maximo(self) -> Optional[float]:
        try:
            return float(self._lbl_error_max.text())
        except ValueError:
            return None

    def get_valor(self) -> Optional[float]:
        if self.SHOW_VALOR and hasattr(self, "_spin_valor"):
            return _val_or_none(self._spin_valor)
        return None

    def set_valor(self, value: float) -> None:
        if self.SHOW_VALOR and hasattr(self, "_spin_valor"):
            self._spin_valor.setValue(value)

    def get_data(self) -> list[dict]:
        rows = []
        for row_idx in range(self._table.rowCount()):
            entry: dict = {self.ROW_ID_KEY: row_idx + 1}
            for col_idx in range(1, len(self.HEADERS)):
                sb = self._table.cellWidget(row_idx, col_idx)
                key = self._header_to_key(self.HEADERS[col_idx])
                entry[key] = _val_or_none(sb)
            rows.append(entry)
        return rows

    def set_data(self, rows: list[dict]) -> None:
        if not rows:
            return
        self._blocking = True
        try:
            while self._table.rowCount() < len(rows):
                self._insert_row()
            for row_idx, row_data in enumerate(rows):
                for col_idx in range(1, len(self.HEADERS)):
                    sb = self._table.cellWidget(row_idx, col_idx)
                    if sb:
                        key = self._header_to_key(self.HEADERS[col_idx])
                        val = row_data.get(key)
                        sb.setValue(float(val) if val is not None else sb.minimum())
        finally:
            self._blocking = False
            self._update_table_height()
            self._recalculate()

    @staticmethod
    def _header_to_key(header: str) -> str:
        return (
            header.lower()
            .replace(" ", "_")
            .replace("á", "a").replace("é", "e").replace("í", "i")
            .replace("ó", "o").replace("ú", "u").replace("ñ", "n")
            .replace(".", "").replace("(", "").replace(")", "")
            .replace("máx", "max").replace("mín", "min")
        )


# ══════════════════════════════════════════════════════════════════════════════
# REPETIBILIDAD
# Columnas: VALOR | LECTURA INICIAL | LECTURA FINAL | ERROR MÁX. TOLERADO
# ══════════════════════════════════════════════════════════════════════════════
class RepetibilidadWidget(MetrologicaTableWidget):
    """
    Tabla de Repetibilidad.

    Columnas:
        VALOR           — Carga aplicada (kg) — editable
        LECTURA INICIAL — Lectura inicial de la balanza
        LECTURA FINAL   — Lectura final de la balanza
        ERR. MÁX. TOL.  — Auto-calculado (OIML R 76) al cambiar VALOR

    Error por fila calculado = |Lectura Final − Lectura Inicial| (footer)
    """
    TITLE        = "REPETIBILIDAD"
    HEADERS      = ["N", "VALOR (kg)", "L. INICIAL", "L. FINAL", "ERROR"]
    INITIAL_COL  = 2
    FINAL_COL    = 3
    NOMINAL_COL  = -1
    DEFAULT_ROWS = 3
    SHOW_VALOR   = False
    ROW_ID_KEY   = "punto_id"

    def _insert_row(self) -> None:
        """Override: col 4=ERROR read-only (Item)."""
        row = self._table.rowCount()
        self._table.insertRow(row)
        self._table.setRowHeight(row, 36)

        # Col 0: número de fila
        item = QTableWidgetItem(str(row + 1))
        item.setFlags(Qt.ItemFlag.ItemIsEnabled)
        item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
        f = QFont(); f.setBold(True); item.setFont(f)
        item.setForeground(QBrush(QColor(_DARK)))
        self._table.setItem(row, 0, item)

        d = getattr(self, '_d', None)
        dec = decimals_from_d(d) if d else 4

        for col in range(1, len(self.HEADERS)):
            if col == 4:  # ERROR — read-only Item
                it = QTableWidgetItem("—")
                it.setFlags(Qt.ItemFlag.ItemIsEnabled)
                it.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                self._table.setItem(row, col, it)
            else:
                sb = _make_cell_spinbox(dec)
                if col == 1:  # VALOR (kg)
                    sb.editingFinished.connect(lambda r=row: self._on_valor_changed(r))
                else:
                    sb.editingFinished.connect(self._on_value_changed)
                self._table.setCellWidget(row, col, sb)

    def _on_valor_changed(self, row: int) -> None:
        """Calcula ERROR (L.Final − Carga) cuando cambia VALOR (kg)."""
        if self._blocking:
            return
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        sb_val = self._table.cellWidget(row, 1)
        sb_fin = self._table.cellWidget(row, 3)
        err_item = self._table.item(row, 4)   # ERROR ahora en col 4
        if not all([sb_val, err_item]):
            return

        carga = _val_or_none(sb_val)

        # ERROR = L.Final − Carga
        fin_v = _val_or_none(sb_fin) if sb_fin else None
        if fin_v is not None and carga is not None:
            error_v = fin_v - carga
            err_txt = f"{error_v:.{decimals}f}"  # siempre muestra decimales, ej: 0.000
            color = _RED if abs(error_v) > 0 else _GREEN
            err_item.setText(err_txt)
            err_item.setForeground(QBrush(QColor(color)))
        else:
            err_item.setText("—")

    def set_division_minima(self, d: float) -> None:
        """Override para también actualizar ERROR de todas las filas."""
        super().set_division_minima(d)
        for row in range(self._table.rowCount()):
            self._on_valor_changed(row)

    def update_unidad(self, unit: str = "kg") -> None:
        """Actualiza dinámicamente los encabezados de columna con la unidad."""
        headers = ["N", f"VALOR ({unit})", f"L. INICIAL ({unit})",
                   f"L. FINAL ({unit})", f"ERROR ({unit})"]
        for i, h in enumerate(headers):
            item = self._table.horizontalHeaderItem(i)
            if item:
                item.setText(h)
            else:
                self._table.setHorizontalHeaderItem(i, QTableWidgetItem(h))

    def _recalculate(self) -> None:
        """Override: calcula ERROR (L.Final − Carga) y actualiza footer."""
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        errors = []
        for row in range(self._table.rowCount()):
            sb_val = self._table.cellWidget(row, 1)
            sb_fin = self._table.cellWidget(row, 3)
            carga = _val_or_none(sb_val) if sb_val else None
            fin_v = _val_or_none(sb_fin) if sb_fin else None
            if carga is not None and fin_v is not None:
                error_v = fin_v - carga
                errors.append(abs(error_v))
                # Actualizar celda ERROR (ahora col 4)
                err_item = self._table.item(row, 4)
                if err_item:
                    err_txt = f"{error_v:.{decimals}f}"
                    color = _RED if abs(error_v) > 0 else _GREEN
                    err_item.setText(err_txt)
                    err_item.setForeground(QBrush(QColor(color)))
        if errors:
            max_err = max(errors)
            style = _ERROR_MAX_VALUE_STYLE if max_err > 0 else _ERROR_MAX_OK_STYLE
            self._lbl_error_max.setText(f"{max_err:.{decimals}f}")
            self._lbl_error_max.setStyleSheet(style)
        else:
            self._lbl_error_max.setText("—")
            self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)

    def get_data(self) -> list[dict]:
        rows = []
        for i in range(self._table.rowCount()):
            sb_val = self._table.cellWidget(i, 1)
            sb_ini = self._table.cellWidget(i, 2)
            sb_fin = self._table.cellWidget(i, 3)
            carga  = _val_or_none(sb_val)
            ini    = _val_or_none(sb_ini)
            fin    = _val_or_none(sb_fin)
            # Si tiene alguna lectura la exportamos
            if carga is not None or ini is not None or fin is not None:
                rows.append({
                    "punto_id":           i + 1,
                    "valor_kg":           carga,
                    # L.Inicial es opcional: None → str '/' para PDF
                    "lectura_inicial":    ini if ini is not None else None,
                    "lectura_final":      fin,
                })
        return rows

    def set_data(self, rows: list[dict]) -> None:
        if not rows:
            return
        self._blocking = True
        try:
            while self._table.rowCount() < len(rows):
                self._insert_row()
            for i, r in enumerate(rows):
                if i >= self._table.rowCount():
                    break
                for col, key in [
                    (1, "valor_kg"),
                    (2, "lectura_inicial"),
                    (3, "lectura_final"),
                ]:
                    sb = self._table.cellWidget(i, col)
                    if sb:
                        v = r.get(key)
                        sb.setValue(float(v) if v is not None else sb.minimum())
        finally:
            self._blocking = False
            self._update_table_height()
            for row in range(self._table.rowCount()):
                self._on_valor_changed(row)


# ══════════════════════════════════════════════════════════════════════════════
# EXCENTRICIDAD CONDICIONAL
# ══════════════════════════════════════════════════════════════════════════════
class ExcentricidadCondicionalWidget(QWidget):
    """
    Widget de Excentricidad con logica condicional completa.

    CASO SÍ aplica:
        - Selector Geometria / Tipo de Plataforma:
            * Cuadrada / Rectangular  -> 5 posiciones (4 esquinas + centro)
            * Circular                -> 5 posiciones (norte, sur, este, oeste, centro)
            * Camionera / FFCC        -> N secciones (SpinBox 3-8)
        - Tabla de posiciones POSICION | LECTURA INICIAL | LECTURA FINAL

    CASO NO aplica:
        - Selector de Motivo:
            * Tolva / Tanque / Silo
            * Bascula de Grua / Gancho Dinamometrico
            * Otro (No apto)
    """
    data_changed = pyqtSignal()
    tipo_changed = pyqtSignal(str)   # mantenido por compatibilidad

    # Mapeo geometria -> etiquetas de posicion predefinidas
    # Regla metrológica: 5 puntos obligatorios — Centro PRIMERO, luego esquinas
    _POSICIONES = {
        "cuadrada": ["Centro", "Esquina 1", "Esquina 2", "Esquina 3", "Esquina 4"],
        "circular": ["Centro", "Norte", "Sur", "Este", "Oeste"],
        "camionera": [],   # se generan dinamicamente segun num_secciones
    }

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._blocking = False
        self._setup_ui()

    # ── Construccion UI ───────────────────────────────────────────────────────

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(4, 4, 4, 4)
        root.setSpacing(6)

        # ── Fila 1: Aplica SÍ/NO ──────────────────────────────────────────────
        fila1 = QHBoxLayout()
        fila1.setSpacing(10)

        lbl_aplica = QLabel("Aplica excentricidad:")
        lbl_aplica.setStyleSheet(f"color: {_GRAY}; font-size: 11px; font-weight: 600;")
        fila1.addWidget(lbl_aplica)

        self._combo_aplica = QComboBox()
        self._combo_aplica.addItems(["SI", "NO"])
        self._combo_aplica.setFixedWidth(80)
        self._combo_aplica.setStyleSheet(
            f"QComboBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
            f"border-radius:5px; padding:3px 8px; font-size:12px; color:{_DARK}; }}"
        )
        self._combo_aplica.currentIndexChanged.connect(self._on_config_changed)
        fila1.addWidget(self._combo_aplica)
        fila1.addStretch()
        root.addLayout(fila1)

        # ── Panel SÍ aplica ───────────────────────────────────────────────────
        self._wgt_si = QWidget()
        si_lay = QVBoxLayout(self._wgt_si)
        si_lay.setContentsMargins(0, 0, 0, 0)
        si_lay.setSpacing(6)

        # Fila: geometria + carga de prueba + secciones (camionera)
        fila_geo = QHBoxLayout()
        fila_geo.setSpacing(10)

        lbl_geo = QLabel("Geometria / Tipo de Plataforma:")
        lbl_geo.setStyleSheet(f"color: {_GRAY}; font-size: 11px; font-weight: 600;")
        fila_geo.addWidget(lbl_geo)

        self._combo_geometria = QComboBox()
        self._combo_geometria.addItems([
            "Plataforma Cuadrada / Rectangular",
            "Plataforma Circular",
            "Plataforma Camionera / FFCC",
        ])
        self._combo_geometria.setFixedWidth(260)
        self._combo_geometria.setStyleSheet(
            f"QComboBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
            f"border-radius:5px; padding:3px 8px; font-size:12px; color:{_DARK}; }}"
        )
        self._combo_geometria.currentIndexChanged.connect(self._on_geometria_changed)
        fila_geo.addWidget(self._combo_geometria)

        # ── Campo Carga de Prueba (kg) ─────────────────────────────────
        lbl_carga = QLabel("Carga de Prueba (kg):")
        lbl_carga.setStyleSheet(f"color: {_GRAY}; font-size: 11px; font-weight: 600;")
        fila_geo.addWidget(lbl_carga)

        self._sb_carga = QDoubleSpinBox()
        self._sb_carga.setDecimals(3)
        self._sb_carga.setRange(0.0, 9_999_999.0)
        self._sb_carga.setSuffix(" kg")
        self._sb_carga.setSpecialValueText(" ")
        self._sb_carga.setValue(0)
        self._sb_carga.setFixedWidth(130)
        self._sb_carga.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
        self._sb_carga.setFrame(True)
        self._sb_carga.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._sb_carga.setStyleSheet(
            f"QDoubleSpinBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
            f"border-radius:5px; padding:3px 8px; font-size:12px; color:{_DARK}; }}"
        )
        locale = QLocale(QLocale.Language.English, QLocale.Country.UnitedStates)
        self._sb_carga.setLocale(locale)
        # Recalcular EMT al salir del campo (editingFinished = sin hipersensibilidad)
        self._sb_carga.editingFinished.connect(self._on_carga_changed)
        fila_geo.addWidget(self._sb_carga)

        # Secciones (solo visible para Camionera)
        self._wgt_secciones = QWidget()
        sec_lay = QHBoxLayout(self._wgt_secciones)
        sec_lay.setContentsMargins(0, 0, 0, 0)
        sec_lay.setSpacing(6)
        lbl_sec = QLabel("N de Secciones:")
        lbl_sec.setStyleSheet(f"color: {_GRAY}; font-size: 11px; font-weight: 600;")
        sec_lay.addWidget(lbl_sec)
        self._spin_secciones = QSpinBox()
        self._spin_secciones.setRange(3, 8)
        self._spin_secciones.setValue(4)
        self._spin_secciones.setFixedWidth(70)
        self._spin_secciones.setStyleSheet(
            f"QSpinBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
            f"border-radius:5px; padding:3px 8px; font-size:12px; color:{_DARK}; }}"
        )
        self._spin_secciones.valueChanged.connect(self._on_secciones_changed)
        sec_lay.addWidget(self._spin_secciones)
        self._wgt_secciones.setVisible(False)
        fila_geo.addWidget(self._wgt_secciones)
        fila_geo.addStretch()
        si_lay.addLayout(fila_geo)

        # Tabla de posiciones ─ 5 columnas: POSICION | CARGA | L.INI | L.FIN | EMT | ERROR
        self._tabla_widget = QWidget()
        self._tabla_widget.setStyleSheet("background: transparent;")
        tabla_lay = QVBoxLayout(self._tabla_widget)
        tabla_lay.setContentsMargins(0, 0, 0, 0)
        tabla_lay.setSpacing(4)

        _COLS_EXC = ["POSICION", "CARGA (kg)", "L. INICIAL", "L. FINAL", "ERROR"]
        self._table = QTableWidget(0, len(_COLS_EXC))
        self._table.setHorizontalHeaderLabels(_COLS_EXC)
        self._table.verticalHeader().setVisible(False)
        self._table.setAlternatingRowColors(True)
        self._table.setShowGrid(True)
        self._table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self._table.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self._table.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._table.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self._table.setSizeAdjustPolicy(QAbstractScrollArea.SizeAdjustPolicy.AdjustToContents)
        self._table.setStyleSheet(_TABLE_STYLE)
        hdr = self._table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        hdr.setSectionResizeMode(0, QHeaderView.ResizeMode.Fixed)
        self._table.setColumnWidth(0, 130)
        # Columnas EMT y ERROR son solo lectura (calculadas)
        tabla_lay.addWidget(self._table)

        # Footer error maximo
        footer = QHBoxLayout()
        lbl_f = QLabel("ERROR MAXIMO ENCONTRADO:")
        lbl_f.setStyleSheet(f"color: {_GRAY}; font-size: 12px; font-weight: 600;")
        footer.addWidget(lbl_f)
        self._lbl_error_max = QLabel("—")
        self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)
        footer.addWidget(self._lbl_error_max)
        footer.addStretch()
        tabla_lay.addLayout(footer)
        si_lay.addWidget(self._tabla_widget)

        root.addWidget(self._wgt_si)

        # ── Panel NO aplica ───────────────────────────────────────────────────
        self._wgt_no = QWidget()
        no_lay = QHBoxLayout(self._wgt_no)
        no_lay.setContentsMargins(0, 0, 0, 0)
        no_lay.setSpacing(10)

        lbl_motivo = QLabel("Motivo / Tipo de instrumento:")
        lbl_motivo.setStyleSheet(f"color: {_GRAY}; font-size: 11px; font-weight: 600;")
        no_lay.addWidget(lbl_motivo)

        self._combo_motivo_no = QComboBox()
        self._combo_motivo_no.addItems([
            "Tolva / Tanque / Silo",
            "Bascula de Grua / Gancho Dinamometrico",
            "Otro (No apto)",
        ])
        self._combo_motivo_no.setFixedWidth(300)
        self._combo_motivo_no.setStyleSheet(
            f"QComboBox {{ background:{_WHITE}; border:1px solid {_LGRAY}; "
            f"border-radius:5px; padding:3px 8px; font-size:12px; color:{_DARK}; }}"
        )
        self._combo_motivo_no.currentIndexChanged.connect(
            lambda: self.data_changed.emit()
        )
        no_lay.addWidget(self._combo_motivo_no)
        no_lay.addStretch()

        root.addWidget(self._wgt_no)
        root.addStretch(1)  # empuja controles al tope — sin espacio vacío entre pestañas

        # Iniciar estado
        self._on_config_changed()

    # ── Handlers internos ─────────────────────────────────────────────────────

    def _on_config_changed(self) -> None:
        aplica = self._combo_aplica.currentText() == "SI"
        self._wgt_si.setVisible(aplica)
        self._wgt_no.setVisible(not aplica)

        if not self._blocking:
            if aplica:
                self._rebuild_rows_from_geometria()
            else:
                self._set_row_count_internal(0)
            self.data_changed.emit()

    def _on_geometria_changed(self) -> None:
        geo_text = self._combo_geometria.currentText()
        es_camionera = "Camionera" in geo_text
        self._wgt_secciones.setVisible(es_camionera)
        if not self._blocking:
            self._rebuild_rows_from_geometria()
            self.data_changed.emit()

    def _on_secciones_changed(self) -> None:
        if not self._blocking:
            self._rebuild_rows_from_geometria()
            self.data_changed.emit()

    def _rebuild_rows_from_geometria(self) -> None:
        """Reconstruye las filas de la tabla segun la geometria seleccionada."""
        geo_text = self._combo_geometria.currentText()
        if "Cuadrada" in geo_text or "Rectangular" in geo_text:
            labels = self._POSICIONES["cuadrada"]
        elif "Circular" in geo_text:
            labels = self._POSICIONES["circular"]
        else:  # Camionera
            n = self._spin_secciones.value()
            labels = [f"Seccion {i + 1}" for i in range(n)]

        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 3

        # Limpiar y reconstruir
        self._table.setRowCount(0)
        for lbl in labels:
            row = self._table.rowCount()
            self._table.insertRow(row)
            self._table.setRowHeight(row, 36)

            # Col 0: POSICION (read-only)
            item = QTableWidgetItem(lbl)
            item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            f = QFont(); f.setBold(True); item.setFont(f)
            item.setForeground(QBrush(QColor(_DARK)))
            self._table.setItem(row, 0, item)

            # Col 1: CARGA (kg) — spinbox editable, sync con _sb_carga al salir
            sb_carga = _make_cell_spinbox(decimals)
            sb_carga.editingFinished.connect(self._on_value_changed)
            self._table.setCellWidget(row, 1, sb_carga)

            # Col 2: LECTURA INICIAL (opcional — puede quedar vacía)
            sb_ini = _make_cell_spinbox(decimals)
            sb_ini.editingFinished.connect(self._on_value_changed)
            self._table.setCellWidget(row, 2, sb_ini)

            # Col 3: LECTURA FINAL
            sb_fin = _make_cell_spinbox(decimals)
            sb_fin.editingFinished.connect(self._on_value_changed)
            self._table.setCellWidget(row, 3, sb_fin)

            # Col 4: ERROR — read-only
            err_item = QTableWidgetItem("—")
            err_item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            err_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            self._table.setItem(row, 4, err_item)

        hdr_h = self._table.horizontalHeader().height() or 28
        self._table.setFixedHeight(hdr_h + 36 * self._table.rowCount() + 4)

        # Propagar carga global a todas las filas
        self._propagar_carga_global()

    def _set_row_count_internal(self, count: int) -> None:
        """Ajuste directo de numero de filas con etiquetas numericas (para set_data)."""
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 3
        self._table.setRowCount(0)
        for i in range(count):
            row = self._table.rowCount()
            self._table.insertRow(row)
            self._table.setRowHeight(row, 36)
            item = QTableWidgetItem(str(row + 1))
            item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            f = QFont(); f.setBold(True); item.setFont(f)
            item.setForeground(QBrush(QColor(_DARK)))
            self._table.setItem(row, 0, item)
            for col in [1, 2, 3]:
                sb = _make_cell_spinbox(decimals)
                sb.editingFinished.connect(self._on_value_changed)
                self._table.setCellWidget(row, col, sb)
            # Col 4: ERROR read-only
            it = QTableWidgetItem("—")
            it.setFlags(Qt.ItemFlag.ItemIsEnabled)
            it.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            self._table.setItem(row, 4, it)
        hdr_h = self._table.horizontalHeader().height() or 28
        self._table.setFixedHeight(max(32, hdr_h + 36 * count + 4))

    def _on_carga_changed(self) -> None:
        """Propaga la carga global a todas las filas y recalcula EMT+ERROR."""
        if not self._blocking:
            self._propagar_carga_global()
            self._recalculate()
            self.data_changed.emit()

    def _on_value_changed(self) -> None:
        if not self._blocking:
            self._recalculate()
            self.data_changed.emit()

    def _propagar_carga_global(self) -> None:
        """Copia el valor del spinbox global 'Carga de Prueba' a la columna 1 de todas las filas."""
        carga = self._sb_carga.value()
        if carga <= 0:
            return
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 3
        for row in range(self._table.rowCount()):
            sb_c = self._table.cellWidget(row, 1)
            if isinstance(sb_c, QDoubleSpinBox):
                sb_c.setDecimals(decimals)
                sb_c.setValue(carga)

    def _recalculate(self) -> None:
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 3
        errors = []

        for row in range(self._table.rowCount()):
            sb_carga_fila = self._table.cellWidget(row, 1)  # CARGA
            sb_fin        = self._table.cellWidget(row, 3)  # LECTURA FINAL
            err_item      = self._table.item(row, 4)         # ERROR col 4

            if err_item is None:
                err_item = QTableWidgetItem()
                err_item.setFlags(Qt.ItemFlag.ItemIsEnabled)
                err_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                self._table.setItem(row, 4, err_item)

            carga_v = _val_or_none(sb_carga_fila) if sb_carga_fila else None
            fin_v   = _val_or_none(sb_fin)        if sb_fin        else None

            # ERROR = L.Final - Carga (con signo)
            if fin_v is not None and carga_v is not None:
                error_v = fin_v - carga_v
                errors.append(abs(error_v))
                err_txt = f"{error_v:.{decimals}f}"  # 0.000 si error es cero
                color = _RED if abs(error_v) > 0 else _GREEN
                err_item.setText(err_txt)
                err_item.setForeground(QBrush(QColor(color)))
            else:
                err_item.setText("—")

        # Footer
        if errors:
            max_err = max(errors)
            style = _ERROR_MAX_VALUE_STYLE if max_err > 0 else _ERROR_MAX_OK_STYLE
            self._lbl_error_max.setText(f"{max_err:.{decimals}f}")
            self._lbl_error_max.setStyleSheet(style)
        else:
            self._lbl_error_max.setText("—")
            self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)

    # ── API Publica ───────────────────────────────────────────────────────────

    def get_aplica_excentricidad(self) -> bool:
        return self._combo_aplica.currentText() == "SI"

    def get_filas_excentricidad(self) -> int:
        """Retorna la cantidad efectiva de filas segun geometria activa."""
        return self._table.rowCount()

    def update_unidad(self, unit: str = "kg") -> None:
        """Actualiza dinámicamente los encabezados de la tabla con la unidad."""
        headers = ["POSICION", f"CARGA ({unit})", f"L. INICIAL ({unit})",
                   f"L. FINAL ({unit})", f"ERROR ({unit})"]
        for i, h in enumerate(headers):
            item = self._table.horizontalHeaderItem(i)
            if item:
                item.setText(h)
            else:
                self._table.setHorizontalHeaderItem(i, QTableWidgetItem(h))

    def get_geometria_plataforma(self) -> str:
        """Retorna el key de geometria: 'cuadrada', 'circular' o 'camionera'."""
        txt = self._combo_geometria.currentText()
        if "Cuadrada" in txt or "Rectangular" in txt:
            return "cuadrada"
        elif "Circular" in txt:
            return "circular"
        return "camionera"

    def get_num_secciones(self) -> int:
        return self._spin_secciones.value()

    def get_tipo_no_aplica(self) -> str:
        """Retorna el motivo de no aplicacion: 'tolva', 'grua' o 'otro'."""
        txt = self._combo_motivo_no.currentText()
        if "Tolva" in txt or "Tanque" in txt or "Silo" in txt:
            return "tolva"
        elif "Grua" in txt or "Gancho" in txt:
            return "grua"
        return "otro"

    def set_tipo_no_aplica(self, tipo: str) -> None:
        tipo = (tipo or "").lower()
        if "tolva" in tipo or "tanque" in tipo or "silo" in tipo:
            self._combo_motivo_no.setCurrentText("Tolva / Tanque / Silo")
        elif "grua" in tipo or "gancho" in tipo:
            self._combo_motivo_no.setCurrentText("Bascula de Grua / Gancho Dinamometrico")
        else:
            self._combo_motivo_no.setCurrentText("Otro (No apto)")

    def set_geometria_plataforma(self, geometria: str, secciones: int = 4) -> None:
        """Restaura la geometria al cargar una OS guardada."""
        self._blocking = True
        try:
            geo = (geometria or "").lower()
            if "cuadrada" in geo or "rectangular" in geo:
                self._combo_geometria.setCurrentText("Plataforma Cuadrada / Rectangular")
            elif "circular" in geo:
                self._combo_geometria.setCurrentText("Plataforma Circular")
            else:
                self._combo_geometria.setCurrentText("Plataforma Camionera / FFCC")
                self._spin_secciones.setValue(secciones or 4)
                self._wgt_secciones.setVisible(True)
        finally:
            self._blocking = False
        self._rebuild_rows_from_geometria()

    def set_excentricidad_config(self, aplica: bool, filas: int) -> None:
        """Compatibilidad: fija SÍ/NO y numero de filas (usa etiquetas numericas)."""
        self._blocking = True
        try:
            self._combo_aplica.setCurrentText("SI" if aplica else "NO")
            self._wgt_si.setVisible(aplica)
            self._wgt_no.setVisible(not aplica)
            if aplica:
                self._set_row_count_internal(filas or 5)
            else:
                self._set_row_count_internal(0)
        finally:
            self._blocking = False
            self.data_changed.emit()

    # Compatibilidad con codigo anterior que usaba "SÍ"/"NO" con acento
    def _normalize_aplica(self, text: str) -> str:
        return "SI" if text.upper().replace("\u00cd", "I") in ("SI", "S\u00cd") else "NO"

    # ── Serialización ─────────────────────────────────────────────────────────

    def get_data(self) -> list[dict]:
        if not self.get_aplica_excentricidad():
            return []
        rows = []
        for i in range(self._table.rowCount()):
            item      = self._table.item(i, 0)
            # La tabla tiene 5 columnas: 0=Posicion, 1=Carga, 2=L.Inicial, 3=L.Final, 4=Error
            sb_carga  = self._table.cellWidget(i, 1)   # CARGA DE PRUEBA
            sb_ini    = self._table.cellWidget(i, 2)   # LECTURA INICIAL (puede ser None)
            sb_fin    = self._table.cellWidget(i, 3)   # LECTURA FINAL
            carga_v   = _val_or_none(sb_carga)
            fin_v     = _val_or_none(sb_fin)
            ini_v     = _val_or_none(sb_ini)
            # Error: |L.Final - Carga|
            error_v   = abs(fin_v - carga_v) if (fin_v is not None and carga_v is not None) else None
            rows.append({
                "posicion_id":     i + 1,
                "posicion_label":  item.text() if item else str(i + 1),
                "carga":           carga_v,
                "lectura_inicial": ini_v,     # None si no se capturó — PDF imprime '/'
                "lectura_final":   fin_v,
                "error":           error_v,
            })
        return rows

    def set_data(self, rows: list[dict]) -> None:
        if not rows:
            return
        self._blocking = True
        try:
            self._set_row_count_internal(len(rows))
            for i, r in enumerate(rows):
                if i >= self._table.rowCount():
                    break
                # Restaurar etiqueta de posicion si esta guardada
                lbl = r.get("posicion_label") or str(r.get("posicion_id", i + 1))
                item = self._table.item(i, 0)
                if item:
                    item.setText(str(lbl))
                for col, key in [
                    (1, "carga"),
                    (2, "lectura_inicial"),
                    (3, "lectura_final"),
                ]:
                    sb = self._table.cellWidget(i, col)
                    if sb:
                        v = r.get(key)
                        sb.setValue(float(v) if v is not None else sb.minimum())
        finally:
            self._blocking = False
            self._recalculate()

    def get_tipo_instrumento(self) -> str:
        return "N/A"

    def set_tipo_instrumento(self, tipo: str, celdas: int = None) -> None:
        pass

    def get_valor(self) -> None:
        return None

    def set_valor(self, value: float) -> None:
        pass

    def get_error_maximo(self) -> Optional[float]:
        if not self.get_aplica_excentricidad():
            return None
        try:
            return float(self._lbl_error_max.text())
        except ValueError:
            return None

    def clear(self) -> None:
        self._blocking = True
        try:
            for row in range(self._table.rowCount()):
                for col in [1, 2]:
                    sb = self._table.cellWidget(row, col)
                    if sb:
                        sb.setValue(sb.minimum())
        finally:
            self._blocking = False
        self._lbl_error_max.setText("--")
        self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)


# ══════════════════════════════════════════════════════════════════════════════
# EXACTITUD
# Columnas: N | VALOR NOMINAL | LECTURA INICIAL | LECTURA FINAL
# ══════════════════════════════════════════════════════════════════════════════
class ExactitudWidget(MetrologicaTableWidget):
    """
    Tabla de Exactitud + Clase de Exactitud + indicadores J/I/A.

    Columnas: N | VALOR NOMINAL | LECTURA INICIAL | LECTURA FINAL
    Error por fila = |Lectura Final − Valor Nominal|
    10 puntos por defecto. Filas con todos los valores en None son ignoradas.
    """
    TITLE        = "EXACTITUD"
    HEADERS      = ["N", "NOMINAL (kg)", "L. INICIAL", "L. FINAL", "ERROR"]
    INITIAL_COL  = 2
    FINAL_COL    = 3
    NOMINAL_COL  = 1
    DEFAULT_ROWS = 10
    SHOW_VALOR   = False
    ROW_ID_KEY   = "punto_id"

    clase_changed = pyqtSignal(str)

    def _build_extra(self, layout) -> None:
        pass  # CLASE y J/I/A eliminados según reglas PESA v2.5

    def get_clase_exactitud(self) -> Optional[str]:
        return None

    def set_clase_exactitud(self, codigo: str) -> None:
        pass

    def get_indicadores_jia(self) -> dict:
        return {"J": False, "I": False, "A": False}

    def set_indicadores_jia(self, jia: dict) -> None:
        pass

    def _insert_row(self) -> None:
        """Override: N | NOMINAL(sb) | L.INI(sb) | L.FIN(sb) | ERROR(item)."""
        row = self._table.rowCount()
        self._table.insertRow(row)
        self._table.setRowHeight(row, 36)
        # Col 0: Número
        it0 = QTableWidgetItem(str(row + 1))
        it0.setFlags(Qt.ItemFlag.ItemIsEnabled)
        it0.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
        f0 = QFont(); f0.setBold(True); it0.setFont(f0)
        it0.setForeground(QBrush(QColor(_DARK)))
        self._table.setItem(row, 0, it0)

        d = getattr(self, '_d', None)
        dec = decimals_from_d(d) if d else 4

        for col in [1, 2, 3]:  # NOMINAL, L.INI, L.FIN
            sb = _make_cell_spinbox(dec)
            if col == 1:  # NOMINAL
                sb.editingFinished.connect(lambda r=row: self._on_nominal_changed(r))
            else:
                sb.editingFinished.connect(lambda r=row: self._on_lectura_changed(r))
            self._table.setCellWidget(row, col, sb)

        # Col 4: ERROR (read-only) — sin EMT
        err_it = QTableWidgetItem("—")
        err_it.setFlags(Qt.ItemFlag.ItemIsEnabled)
        err_it.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
        self._table.setItem(row, 4, err_it)

    def _on_nominal_changed(self, row: int) -> None:
        """Recalcula ERROR cuando cambia el valor nominal."""
        if self._blocking:
            return
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        sb_nom = self._table.cellWidget(row, 1)
        sb_fin = self._table.cellWidget(row, 3)
        err_item = self._table.item(row, 4)   # ERROR en col 4
        if not all([sb_nom, err_item]):
            return
        nom   = _val_or_none(sb_nom)
        fin_v = _val_or_none(sb_fin) if sb_fin else None
        # ERROR = L.Final − Nominal
        if fin_v is not None and nom is not None:
            error_v = fin_v - nom
            err_txt = f"{error_v:.{decimals}f}"  # 0.000 cuando son iguales
            color = _RED if abs(error_v) > 0 else _GREEN
            err_item.setText(err_txt)
            err_item.setForeground(QBrush(QColor(color)))
        else:
            err_item.setText("—")  # sin datos todavía
        self._recalculate()
        self.data_changed.emit()

    def _on_lectura_changed(self, row: int) -> None:
        """Recalcula ERROR cuando cambia L.Final o L.Inicial."""
        if self._blocking:
            return
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        sb_nom = self._table.cellWidget(row, 1)
        sb_fin = self._table.cellWidget(row, 3)
        err_item = self._table.item(row, 4)   # ERROR en col 4
        if not all([sb_nom, sb_fin, err_item]):
            return
        nom   = _val_or_none(sb_nom)
        fin_v = _val_or_none(sb_fin)
        if fin_v is not None and nom is not None:
            error_v = fin_v - nom
            err_txt = f"{error_v:.{decimals}f}"  # 0.000 si son iguales
            color = _RED if abs(error_v) > 0 else _GREEN
            err_item.setText(err_txt)
            err_item.setForeground(QBrush(QColor(color)))
        else:
            err_item.setText("—")
        self._recalculate()
        self.data_changed.emit()

    def _recalculate(self) -> None:
        """Override: errores = |L.Final − Nominal| ignorando filas sin datos."""
        d = getattr(self, '_d', None)
        decimals = decimals_from_d(d) if d else 4
        errors = []
        for row in range(self._table.rowCount()):
            sb_nom = self._table.cellWidget(row, 1)
            sb_fin = self._table.cellWidget(row, 3)
            nom   = _val_or_none(sb_nom) if sb_nom else None
            fin_v = _val_or_none(sb_fin) if sb_fin else None
            if nom is not None and fin_v is not None:
                errors.append(abs(fin_v - nom))
        if errors:
            max_err = max(errors)
            style = _ERROR_MAX_VALUE_STYLE if max_err > 0 else _ERROR_MAX_OK_STYLE
            self._lbl_error_max.setText(f"{max_err:.{decimals}f}")
            self._lbl_error_max.setStyleSheet(style)
        else:
            self._lbl_error_max.setText("—")
            self._lbl_error_max.setStyleSheet(_ERROR_MAX_VALUE_STYLE)

    def set_division_minima(self, d: float) -> None:
        """Override para recalcular EMT+ERROR al cambiar d."""
        self._d = d
        decimals = decimals_from_d(d)
        # Actualizar spinboxes existentes
        for row in range(self._table.rowCount()):
            for col in [1, 2, 3]:
                sb = self._table.cellWidget(row, col)
                if isinstance(sb, QDoubleSpinBox):
                    current_val = sb.value() if sb.value() != sb.minimum() else None
                    sb.setDecimals(decimals)
                    if current_val is not None:
                        sb.setValue(current_val)
            self._on_nominal_changed(row)
        self._recalculate()

    def update_unidad(self, unit: str = "kg") -> None:
        """Actualiza dinámicamente los encabezados de columna con la unidad."""
        headers = ["N", f"NOMINAL ({unit})", f"L. INICIAL ({unit})",
                   f"L. FINAL ({unit})", f"ERROR ({unit})"]
        for i, h in enumerate(headers):
            item = self._table.horizontalHeaderItem(i)
            if item:
                item.setText(h)
            else:
                self._table.setHorizontalHeaderItem(i, QTableWidgetItem(h))

    def get_data(self) -> list[dict]:
        """Retorna filas con al menos un valor; L.Inicial=None significa no capturada."""
        rows = []
        for i in range(self._table.rowCount()):
            sb_nom = self._table.cellWidget(i, 1)
            sb_ini = self._table.cellWidget(i, 2)
            sb_fin = self._table.cellWidget(i, 3)
            nom = _val_or_none(sb_nom)
            ini = _val_or_none(sb_ini)
            fin = _val_or_none(sb_fin)
            if any(v is not None for v in [nom, ini, fin]):
                rows.append({
                    "punto_id":        i + 1,
                    "valor_nominal":   nom,
                    "lectura_inicial": ini,   # None si no se capturó (PDF imprime '/')
                    "lectura_final":   fin,
                })
        return rows

    def set_data(self, rows: list[dict]) -> None:
        if not rows:
            return
        self._blocking = True
        try:
            while self._table.rowCount() < len(rows):
                self._insert_row()
            for i, r in enumerate(rows):
                if i >= self._table.rowCount():
                    break
                for col, key in [
                    (1, "valor_nominal"),
                    (2, "lectura_inicial"),
                    (3, "lectura_final"),
                ]:
                    sb = self._table.cellWidget(i, col)
                    if sb:
                        v = r.get(key)
                        sb.setValue(float(v) if v is not None else sb.minimum())
        finally:
            self._blocking = False
            self._update_table_height()
            for row in range(self._table.rowCount()):
                self._on_nominal_changed(row)


# ══════════════════════════════════════════════════════════════════════════════
# WIDGET COMPUESTO: PruebasMetrologicasWidget
# ══════════════════════════════════════════════════════════════════════════════
class PruebasMetrologicasWidget(QWidget):
    """
    Panel completo de Pruebas Metrológicas.

    Distribución:
        ┌────────────────────┬──────────────────────────────────────┐
        │  REPETIBILIDAD     │                                      │
        │  (3 filas, 4 cols) │           EXACTITUD                  │
        ├────────────────────┤           (10 filas, 4 cols)         │
        │  EXCENTRICIDAD     │           + CLASE DE EXACTITUD       │
        │  (condicional)     │           + J / I / A                │
        └────────────────────┴──────────────────────────────────────┘

    Atributos públicos:
        repetibilidad   RepetibilidadWidget
        excentricidad   ExcentricidadCondicionalWidget
        exactitud       ExactitudWidget
    """

    data_changed = pyqtSignal()

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._setup_ui()

    def _setup_ui(self) -> None:
        root_layout = QVBoxLayout(self)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        from PyQt6.QtWidgets import QTabWidget
        self._tabs = QTabWidget()
        self._tabs.setStyleSheet(
            "QTabWidget::pane { border: 1px solid #E5E7EB; background: #FFFFFF; border-radius: 4px; }"
            "QTabBar::tab { background: #F3F4F6; color: #374151; font-weight: 600; padding: 10px 20px; border: 1px solid #E5E7EB; border-bottom: none; border-top-left-radius: 6px; border-top-right-radius: 6px; margin-right: 4px; }"
            "QTabBar::tab:selected { background: #FFFFFF; color: #C8102E; border-bottom: 1px solid #FFFFFF; }"
            "QTabBar::tab:hover:!selected { background: #E5E7EB; }"
        )

        self.repetibilidad = RepetibilidadWidget()
        self.repetibilidad.data_changed.connect(self.data_changed)
        w_rep = QWidget()
        w_rep.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        l_rep = QVBoxLayout(w_rep)
        l_rep.setContentsMargins(8, 8, 8, 8)
        l_rep.setSpacing(0)
        l_rep.addWidget(self.repetibilidad)
        self._tabs.addTab(w_rep, "1. Repetibilidad")

        self.excentricidad = ExcentricidadCondicionalWidget()
        self.excentricidad.data_changed.connect(self.data_changed)
        w_exc = QWidget()
        w_exc.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        l_exc = QVBoxLayout(w_exc)
        l_exc.setContentsMargins(8, 8, 8, 8)
        l_exc.setSpacing(0)
        l_exc.addWidget(self.excentricidad)
        self._tabs.addTab(w_exc, "2. Excentricidad")

        self.exactitud = ExactitudWidget()
        self.exactitud.data_changed.connect(self.data_changed)
        w_exa = QWidget()
        w_exa.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        l_exa = QVBoxLayout(w_exa)
        l_exa.setContentsMargins(8, 8, 8, 8)
        l_exa.setSpacing(0)
        l_exa.addWidget(self.exactitud)
        self._tabs.addTab(w_exa, "3. Exactitud")

        self._tabs.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        root_layout.addWidget(self._tabs)

    # ── API de datos ──────────────────────────────────────────────────────────

    def get_all_data(self) -> dict:
        """
        Retorna todos los datos de prueba en un solo diccionario.

        Returns:
            {
                "tipo_instrumento":    str | None,
                "repetibilidad":       [{...}, ...],
                "excentricidad":       [{...}, ...],
                "exactitud":           [{...}, ...],
                "valor_repetibilidad": float | None,
                "id_clase_exactitud":  str | None,   # "I","II","III","IV"
                "indicadores_jia":     {"J":bool, "I":bool, "A":bool},
            }
        """
        return {
            "tipo_instrumento":    self.excentricidad.get_tipo_instrumento() or None,
            "aplica_excentricidad": self.excentricidad.get_aplica_excentricidad(),
            "filas_excentricidad": self.excentricidad.get_filas_excentricidad(),
            "repetibilidad":       self.repetibilidad.get_data(),
            "excentricidad":       self.excentricidad.get_data(),
            "exactitud":           self.exactitud.get_data(),
            "valor_repetibilidad": self.repetibilidad.get_valor(),
            "id_clase_exactitud":  self.exactitud.get_clase_exactitud(),
            "indicadores_jia":     self.exactitud.get_indicadores_jia(),
        }

    def set_all_data(
        self,
        repetibilidad:       list[dict],
        excentricidad:       list[dict],
        exactitud:           list[dict],
        tipo_instrumento:    Optional[str]   = None,
        numero_celdas:       Optional[int]   = None,
        valor_repetibilidad: Optional[float] = None,
        valor_excentricidad: Optional[float] = None,
        clase_exactitud:     Optional[str]   = None,
        indicadores_jia:     Optional[dict]  = None,
        aplica_excentricidad: Optional[bool] = None,
        filas_excentricidad: Optional[int]   = None,
    ) -> None:
        """Carga todos los datos de prueba desde la BD."""
        if aplica_excentricidad is not None:
            self.excentricidad.set_excentricidad_config(aplica_excentricidad, filas_excentricidad or 5)
            self._tabs.setTabEnabled(1, aplica_excentricidad)
        elif tipo_instrumento:
            self.excentricidad.set_tipo_instrumento(tipo_instrumento, numero_celdas)
        
        self.repetibilidad.set_data(repetibilidad)
        self.excentricidad.set_data(excentricidad)
        self.exactitud.set_data(exactitud)
        if valor_repetibilidad is not None:
            self.repetibilidad.set_valor(valor_repetibilidad)
        if clase_exactitud:
            self.exactitud.set_clase_exactitud(clase_exactitud)
        if indicadores_jia:
            self.exactitud.set_indicadores_jia(indicadores_jia)
        # valor_excentricidad se acepta para compatibilidad con el formulario
        # de OS pero ExcentricidadWidget no expone un set_valor independiente.

    def set_division_minima(self, d: float) -> None:
        """Propaga la resolución d a los tres sub-widgets."""
        self.repetibilidad.set_division_minima(d)
        if hasattr(self.excentricidad, 'set_division_minima'):
            self.excentricidad.set_division_minima(d)
        else:
            self._apply_d_to_exc_table(d)
        self.exactitud.set_division_minima(d)

    def set_unidad(self, unit: str = "kg") -> None:
        """
        Propaga la unidad de medida a los tres sub-widgets.
        Actualiza dinámicamente los encabezados de columna en las tablas.
        """
        self._unidad = unit
        # Repetibilidad
        if hasattr(self.repetibilidad, 'update_unidad'):
            self.repetibilidad.update_unidad(unit)
        # Excentricidad
        if hasattr(self.excentricidad, 'update_unidad'):
            self.excentricidad.update_unidad(unit)
        # Exactitud
        if hasattr(self.exactitud, 'update_unidad'):
            self.exactitud.update_unidad(unit)

    def get_unidad(self) -> str:
        """Retorna la unidad actualmente seleccionada."""
        return getattr(self, '_unidad', 'kg')

    def _apply_d_to_exc_table(self, d: float) -> None:
        """Aplica d a la tabla de excentricidad (spinboxes de lecturas)."""
        dec = decimals_from_d(d)
        table = getattr(self.excentricidad, '_table', None)
        if table is None:
            return
        for row in range(table.rowCount()):
            for col in [1, 2]:
                sb = table.cellWidget(row, col)
                if isinstance(sb, QDoubleSpinBox):
                    current_val = sb.value() if sb.value() != sb.minimum() else None
                    sb.setDecimals(dec)
                    if current_val is not None:
                        sb.setValue(current_val)

    def clear_all(self) -> None:
        """Limpia todos los datos de las tres tablas."""
        self.repetibilidad.clear()
        self.excentricidad.clear()
        self.exactitud.clear()
