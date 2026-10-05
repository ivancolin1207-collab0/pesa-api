"""
Widget Reporte de Revisión de Básculas (RE) — 6 Secciones.
Formulario modular con secciones numeradas, tabla dinámica de Ohms (1-12 celdas),
inspección visual con Cumple/No Cumple, periféricos y estado final.
"""
import logging
from datetime import date
from typing import Optional

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QDateEdit, QTableWidget,
    QTableWidgetItem, QHeaderView, QScrollArea, QFrame, QDoubleSpinBox,
    QAbstractItemView, QMessageBox, QAbstractSpinBox, QTabWidget,
    QSpinBox, QCheckBox, QGroupBox, QButtonGroup, QSizePolicy,
    QGridLayout,
)
from PyQt6.QtCore import Qt, pyqtSignal, QDate
from PyQt6.QtGui import QFont, QColor

logger = logging.getLogger(__name__)

# ─── Constantes ───────────────────────────────────────────────────────────────
_INSPECCION_PUNTOS = [
    (1, "Estado físico general del equipo"),
    (2, "Estado de la plataforma / estructura"),
    (3, "Estado de celdas de carga"),
    (4, "Estado de cableado y conexiones"),
    (5, "Caja sumadora / Conectores"),
    (6, "Indicador de peso / Display"),
    (7, "Teclado / Botones"),
    (8, "Nivelación del equipo"),
    (9, "Limpieza general"),
]

_PERIFERICOS = [
    ("indicador_peso",    "Indicador de Peso"),
    ("teclado_botones",   "Teclado / Botones"),
    ("display",           "Display"),
    ("impresora",         "Impresora / Ticket"),
    ("comunicacion",      "Comunicación / Salida"),
]

_OHMS_ROWS = [
    ("exc_plus_minus",      "Excitación  Exc⁺ / Exc⁻"),
    ("sig_plus_minus",      "Señal  Sig⁺ / Sig⁻"),
    ("sig_plus_exc_plus",   "Señal  Sig⁺ / Exc⁺"),
    ("sig_minus_exc_minus", "Señal  Sig⁻ / Exc⁻"),
    ("resistencia_entrada", "Resistencia de Entrada  (Ω)"),
    ("resistencia_salida",  "Resistencia de Salida   (Ω)"),
]

_TIPOS_BASCULA = [
    "Báscula de plataforma digital",
    "Báscula de plataforma analógica",
    "Báscula puente para camiones",
    "Báscula de fosa",
    "Báscula grúa / colgante",
    "Báscula de piso",
    "Báscula de banda transportadora",
    "Báscula de tolva / silo",
    "Báscula de riel",
    "Otro",
]

# ─── Estilos ──────────────────────────────────────────────────────────────────
_SECTION_HDR = """
QWidget#section_hdr {
    background: #E5E5EA;
    border-radius: 6px;
}
"""
_CUMPLE_BTN_ON  = "QPushButton { background:#D4F5DA; color:#34C759; border:1px solid #34C759; border-radius:4px; font-size:11px; font-weight:700; padding:3px 8px; }"
_CUMPLE_BTN_OFF = "QPushButton { background:#FFFFFF; color:#E5E5EA; border:1px solid #D1D1D6; border-radius:4px; font-size:11px; padding:3px 8px; }"
_NOCUMPLE_BTN_ON  = "QPushButton { background:#FDEEEF; color:#FF3B30; border:1px solid #FF3B30; border-radius:4px; font-size:11px; font-weight:700; padding:3px 8px; }"
_NOCUMPLE_BTN_OFF = "QPushButton { background:#FFFFFF; color:#E5E5EA; border:1px solid #D1D1D6; border-radius:4px; font-size:11px; padding:3px 8px; }"
_FIELD_STYLE = "QLineEdit { background:#FFFFFF; color:#1D1D1F; border:1px solid #D1D1D6; border-radius:4px; padding:4px 8px; font-size:12px; } QLineEdit:focus { border-color:#E63946; }"
_SB_STYLE = "QDoubleSpinBox { background:transparent; border:none; color:#1D1D1F; font-size:11px; } QDoubleSpinBox:focus { border-bottom:1px solid #E63946; }"


# ══════════════════════════════════════════════════════════════════════════════
# Componentes reutilizables
# ══════════════════════════════════════════════════════════════════════════════

def make_section_header(num: int, title: str) -> QWidget:
    """Barra de sección numerada con fondo oscuro y acento rojo."""
    w = QWidget()
    w.setObjectName("section_hdr")
    w.setStyleSheet(_SECTION_HDR)
    w.setFixedHeight(36)
    layout = QHBoxLayout(w)
    layout.setContentsMargins(10, 0, 10, 0)
    layout.setSpacing(10)

    # Círculo de número
    num_lbl = QLabel(str(num))
    num_lbl.setFixedSize(22, 22)
    num_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
    num_lbl.setStyleSheet(
        "background:#E63946; color:#FFFFFF; border-radius:11px; "
        "font-size:11px; font-weight:900;"
    )
    layout.addWidget(num_lbl)

    title_lbl = QLabel(title.upper())
    title_lbl.setStyleSheet("color:#1D1D1F; font-size:11px; font-weight:800; letter-spacing:1px;")
    layout.addWidget(title_lbl)
    layout.addStretch()
    return w


def make_field(label: str, width: int = 180) -> tuple[QLabel, QLineEdit]:
    lbl = QLabel(label)
    lbl.setStyleSheet("color:#86868B; font-size:10px; font-weight:700; letter-spacing:0.5px;")
    fld = QLineEdit()
    fld.setStyleSheet(_FIELD_STYLE)
    fld.setFixedWidth(width)
    fld.setFixedHeight(32)
    return lbl, fld


class CumpleRow(QWidget):
    """Fila de inspección: descripción | [CUMPLE] | [NO CUMPLE] | obs."""

    def __init__(self, num: int, desc: str, parent=None):
        super().__init__(parent)
        self._state: Optional[bool] = None

        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 2, 4, 2)
        layout.setSpacing(6)

        # Número
        n = QLabel(f"{num}.")
        n.setFixedWidth(20)
        n.setStyleSheet("color:#E63946; font-size:11px; font-weight:700;")
        layout.addWidget(n)

        # Descripción
        d = QLabel(desc)
        d.setStyleSheet("color:#1D1D1F; font-size:11px;")
        d.setFixedWidth(220)
        layout.addWidget(d)

        # Botones
        self._btn_c  = QPushButton("✓ CUMPLE")
        self._btn_nc = QPushButton("✗ NO CUMPLE")
        for b, w in [(self._btn_c, 90), (self._btn_nc, 100)]:
            b.setFixedSize(w, 26)
            b.setCheckable(True)
        self._btn_c.clicked.connect(lambda: self._select(True))
        self._btn_nc.clicked.connect(lambda: self._select(False))
        layout.addWidget(self._btn_c)
        layout.addWidget(self._btn_nc)

        # Observación
        self._obs = QLineEdit()
        self._obs.setPlaceholderText("Observación...")
        self._obs.setStyleSheet(_FIELD_STYLE)
        self._obs.setFixedHeight(26)
        self._obs.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        layout.addWidget(self._obs)

        self._update_styles()

    def _select(self, cumple: bool) -> None:
        self._state = cumple
        self._btn_c.setChecked(cumple)
        self._btn_nc.setChecked(not cumple)
        self._update_styles()

    def _update_styles(self) -> None:
        self._btn_c.setStyleSheet(
            _CUMPLE_BTN_ON if self._state is True else _CUMPLE_BTN_OFF
        )
        self._btn_nc.setStyleSheet(
            _NOCUMPLE_BTN_ON if self._state is False else _NOCUMPLE_BTN_OFF
        )

    def get_data(self) -> dict:
        return {"cumple": self._state, "observacion": self._obs.text().strip() or None}

    def set_data(self, cumple: Optional[bool], obs: str = "") -> None:
        if cumple is not None:
            self._select(cumple)
        self._obs.setText(obs or "")


class PeriferalRow(QWidget):
    """Fila de periférico: nombre | CUMPLE | NO CUMPLE | obs."""

    def __init__(self, desc: str, parent=None):
        super().__init__(parent)
        self._state: Optional[bool] = None
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 2, 4, 2)
        layout.setSpacing(6)

        d = QLabel(desc)
        d.setStyleSheet("color:#1D1D1F; font-size:11px;")
        d.setFixedWidth(180)
        layout.addWidget(d)

        self._btn_c  = QPushButton("✓")
        self._btn_nc = QPushButton("✗")
        for b, c in [(self._btn_c, 30), (self._btn_nc, 30)]:
            b.setFixedSize(c, 26)
            b.setCheckable(True)
        self._btn_c.clicked.connect(lambda: self._select(True))
        self._btn_nc.clicked.connect(lambda: self._select(False))
        layout.addWidget(self._btn_c)
        layout.addWidget(self._btn_nc)

        self._obs = QLineEdit()
        self._obs.setPlaceholderText("Observación...")
        self._obs.setStyleSheet(_FIELD_STYLE)
        self._obs.setFixedHeight(26)
        self._obs.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        layout.addWidget(self._obs)
        self._update_styles()

    def _select(self, v: bool) -> None:
        self._state = v
        self._btn_c.setChecked(v)
        self._btn_nc.setChecked(not v)
        self._update_styles()

    def _update_styles(self) -> None:
        self._btn_c.setStyleSheet(
            _CUMPLE_BTN_ON if self._state is True else _CUMPLE_BTN_OFF
        )
        self._btn_nc.setStyleSheet(
            _NOCUMPLE_BTN_ON if self._state is False else _NOCUMPLE_BTN_OFF
        )

    def get_data(self) -> dict:
        return {"cumple": self._state, "observacion": self._obs.text().strip() or None}


# ══════════════════════════════════════════════════════════════════════════════
# Widget Principal
# ══════════════════════════════════════════════════════════════════════════════
class REFormWidget(QWidget):
    """
    Reporte de Revisión de Básculas — 6 secciones completas.
    """
    re_saved = pyqtSignal(str)

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._clientes:   list[dict] = []
        self._tecnicos:   list[dict] = []
        self._sucursales: list[dict] = []   # sucursales del cliente activo
        self._equipos_sucursal: list[dict] = []  # equipos de la sucursal activa
        self._num_celdas = 4
        self._inspeccion_rows: list[CumpleRow]    = []
        self._celda_rows:      list[CumpleRow]    = []
        self._periferico_rows: list[PeriferalRow] = []
        self._setup_ui()
        self._load_catalogos()
        self._rebuild_dynamic_sections(4)

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._load_catalogos()

    # ── Setup general ─────────────────────────────────────────────────────────
    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header
        hdr = QWidget()
        hdr.setFixedHeight(54)
        hdr.setStyleSheet("background:#F2F2F7; border-bottom:1px solid #D1D1D6;")
        hl = QHBoxLayout(hdr)
        hl.setContentsMargins(24, 0, 24, 0)
        t = QLabel("⚖️  Reporte de Revisión de Básculas — RE")
        t.setStyleSheet("font-size:18px; font-weight:800; color:#1D1D1F;")
        hl.addWidget(t)
        hl.addStretch()
        root.addWidget(hdr)

        self._tabs = QTabWidget()
        self._tabs.addTab(self._build_form_tab(), "📋  Nuevo Reporte")
        self._tabs.addTab(self._build_historial_tab(), "📄  Historial")
        root.addWidget(self._tabs)

    # ══════════════════════════════════════════════════════════════════════════
    # TAB 1: Formulario completo
    # ══════════════════════════════════════════════════════════════════════════
    def _build_form_tab(self) -> QWidget:
        w = QWidget()
        outer = QVBoxLayout(w)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        self._form_container = QWidget()
        self._form_layout = QVBoxLayout(self._form_container)
        self._form_layout.setContentsMargins(24, 16, 24, 16)
        self._form_layout.setSpacing(12)

        self._build_encabezado()
        self._build_sec1_cliente()
        self._build_sec2_equipo()
        self._build_sec3_inspeccion()
        # Secciones 4 y 5 son dinámicas — se reconstruyen al cambiar celdas
        self._sec4_container = QWidget()
        self._sec4_layout    = QVBoxLayout(self._sec4_container)
        self._sec4_layout.setContentsMargins(0, 0, 0, 0)
        self._form_layout.addWidget(self._sec4_container)

        self._sec5_container = QWidget()
        self._sec5_layout    = QVBoxLayout(self._sec5_container)
        self._sec5_layout.setContentsMargins(0, 0, 0, 0)
        self._form_layout.addWidget(self._sec5_container)

        self._build_sec6_observaciones()
        self._form_layout.addStretch()

        scroll.setWidget(self._form_container)
        outer.addWidget(scroll)
        outer.addWidget(self._build_action_bar())
        return w

    # ── Encabezado de control ─────────────────────────────────────────────────
    def _build_encabezado(self) -> None:
        top = QHBoxLayout()
        top.setSpacing(20)

        # Panel de folio
        fp = QWidget()
        fp.setFixedSize(200, 72)
        fp.setStyleSheet("background:#FFFFFF; border:2px solid #34C759; border-radius:8px;")
        fl = QVBoxLayout(fp)
        fl.setContentsMargins(10, 6, 10, 6); fl.setSpacing(1)
        fl.addWidget(QLabel("FOLIO / RE", alignment=Qt.AlignmentFlag.AlignCenter,
                            styleSheet="color:#86868B; font-size:10px; font-weight:700;"))
        self._lbl_folio = QLabel("— NUEVO —")
        self._lbl_folio.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._lbl_folio.setStyleSheet("color:#34C759; font-size:18px; font-weight:900; letter-spacing:2px;")
        fl.addWidget(self._lbl_folio)
        top.addWidget(fp)

        # Fecha
        fc = QVBoxLayout(); fc.setSpacing(4)
        fc.addWidget(QLabel("FECHA:"))
        self._date_edit = QDateEdit(QDate.currentDate())
        self._date_edit.setCalendarPopup(True)
        self._date_edit.setDisplayFormat("dd / MM / yyyy")
        self._date_edit.setFixedSize(160, 34)
        fc.addWidget(self._date_edit)
        top.addLayout(fc)

        # Horario
        hc = QVBoxLayout(); hc.setSpacing(4)
        hc.addWidget(QLabel("HORARIO:"))
        self._txt_horario = QLineEdit()
        self._txt_horario.setPlaceholderText("09:00 - 14:00")
        self._txt_horario.setStyleSheet(_FIELD_STYLE)
        self._txt_horario.setFixedSize(130, 34)
        hc.addWidget(self._txt_horario)
        top.addLayout(hc)

        # Técnico
        tc = QVBoxLayout(); tc.setSpacing(4)
        tc.addWidget(QLabel("TÉCNICO:"))
        self._combo_tecnico = QComboBox()
        self._combo_tecnico.setMinimumWidth(220)
        self._combo_tecnico.setFixedHeight(34)
        tc.addWidget(self._combo_tecnico)
        top.addLayout(tc)
        top.addStretch()

        self._form_layout.addLayout(top)

    # ── Sección 1: Datos del Cliente ─────────────────────────────────────────
    def _build_sec1_cliente(self) -> None:
        self._form_layout.addWidget(make_section_header(1, "Datos del Cliente"))
        grp = QWidget()
        grp.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:6px;")
        gl = QGridLayout(grp)
        gl.setContentsMargins(16, 12, 16, 12)
        gl.setHorizontalSpacing(16); gl.setVerticalSpacing(8)

        # ── Cliente ──
        lbl_c = QLabel("RAZÓN SOCIAL / CLIENTE")
        lbl_c.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._combo_cliente = QComboBox()
        self._combo_cliente.setEditable(True)
        self._combo_cliente.setMinimumWidth(380)
        self._combo_cliente.setFixedHeight(34)
        gl.addWidget(lbl_c, 0, 0, 1, 2)
        gl.addWidget(self._combo_cliente, 1, 0, 1, 2)

        # ── Sucursal / Planta ──
        lbl_s = QLabel("SUCURSAL / PLANTA")
        lbl_s.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._combo_sucursal = QComboBox()
        self._combo_sucursal.setMinimumWidth(380)
        self._combo_sucursal.setFixedHeight(34)
        self._combo_sucursal.setEnabled(False)
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        gl.addWidget(lbl_s, 2, 0, 1, 2)
        gl.addWidget(self._combo_sucursal, 3, 0, 1, 2)

        # ── Dirección (sólo lectura — se autocompleta) ──
        lbl_d = QLabel("DIRECCIÓN DE PLANTA")
        lbl_d.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._txt_direccion = QLineEdit()
        self._txt_direccion.setReadOnly(True)
        self._txt_direccion.setPlaceholderText("Se autocompleta al seleccionar sucursal...")
        self._txt_direccion.setStyleSheet(
            "QLineEdit { background:#F9F9FB; color:#1D1D1F; border:1px solid #D1D1D6; "
            "border-radius:4px; padding:4px 8px; font-size:12px; }"
        )
        self._txt_direccion.setFixedHeight(32)
        self._txt_direccion.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        gl.addWidget(lbl_d, 4, 0, 1, 2)
        gl.addWidget(self._txt_direccion, 5, 0, 1, 2)

        # ── Señales ──
        self._combo_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        self._combo_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)

        self._form_layout.addWidget(grp)

    # ── Sección 2: Datos del Equipo ──────────────────────────────────────────
    def _build_sec2_equipo(self) -> None:
        self._form_layout.addWidget(make_section_header(2, "Datos del Equipo"))
        grp = QWidget()
        grp.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:6px;")
        gl = QGridLayout(grp)
        gl.setContentsMargins(16, 12, 16, 12)
        gl.setHorizontalSpacing(16); gl.setVerticalSpacing(8)

        # ── ID Indicador / Equipo (combo con búsqueda) ──
        lbl_id = QLabel("ID INDICADOR / EQUIPO")
        lbl_id.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._combo_equipo_cat = QComboBox()
        self._combo_equipo_cat.setEditable(True)
        self._combo_equipo_cat.setMinimumWidth(300)
        self._combo_equipo_cat.setFixedHeight(32)
        self._combo_equipo_cat.setEnabled(False)
        self._combo_equipo_cat.addItem("— Seleccionar o escribir ID —", None)
        self._combo_equipo_cat.activated.connect(self._on_id_equipo_changed)
        gl.addWidget(lbl_id, 0, 0, 1, 2)
        gl.addWidget(self._combo_equipo_cat, 1, 0, 1, 2)

        def f(r, c, lbl, attr, w=160, cs=1):
            lab = QLabel(lbl); lab.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
            fld = QLineEdit(); fld.setStyleSheet(_FIELD_STYLE); fld.setFixedHeight(32)
            setattr(self, attr, fld)
            gl.addWidget(lab, r*2, c, 1, cs); gl.addWidget(fld, r*2+1, c, 1, cs)

        f(1, 0, "MARCA",                "_txt_marca", 160)
        f(1, 1, "MODELO",               "_txt_modelo", 160)
        f(1, 2, "NÚMERO DE SERIE",       "_txt_ns", 160)
        f(1, 3, "ALCANCE MÁXIMO",        "_txt_alcance", 130)

        f(2, 0, "TIPO DE INSTRUMENTO",   "_txt_tipo_inst", 160)
        f(2, 1, "DIVISIÓN MÍNIMA",       "_txt_div_min", 130)
        f(2, 2, "DIV. VERIFICACIÓN",     "_txt_div_ver", 130)
        f(2, 3, "NÚMERO CCA",            "_txt_cca", 130)

        f(3, 0, "UBICACIÓN EXACTA",      "_txt_ubicacion", 200, 2)
        f(3, 2, "ID INTERNO",            "_txt_id_interno", 130)
        f(3, 3, "HOLOGRAMA ANTERIOR",    "_txt_holograma", 130)

        # Tipo de báscula + celdas
        lbl_tb = QLabel("TIPO DE BÁSCULA")
        lbl_tb.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._combo_tipo_bascula = QComboBox()
        self._combo_tipo_bascula.setEditable(True)
        self._combo_tipo_bascula.addItems(_TIPOS_BASCULA)
        self._combo_tipo_bascula.setFixedHeight(32)
        gl.addWidget(lbl_tb, 8, 0, 1, 2)
        gl.addWidget(self._combo_tipo_bascula, 9, 0, 1, 2)

        lbl_nc = QLabel("NÚMERO DE CELDAS (1-12)")
        lbl_nc.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        self._spin_celdas = QSpinBox()
        self._spin_celdas.setRange(1, 12)
        self._spin_celdas.setValue(4)
        self._spin_celdas.setFixedSize(70, 32)
        btn_gen = QPushButton("⟳ Generar Secciones 4 y 5")
        btn_gen.setFixedHeight(32)
        btn_gen.setProperty("class", "primary")
        btn_gen.clicked.connect(lambda: self._rebuild_dynamic_sections(self._spin_celdas.value()))
        row_nc = QHBoxLayout()
        row_nc.addWidget(self._spin_celdas)
        row_nc.addWidget(btn_gen)
        row_nc.addStretch()
        gl.addWidget(lbl_nc, 8, 2, 1, 2)
        gl.addLayout(row_nc, 9, 2, 1, 2)

        self._form_layout.addWidget(grp)

    # ── Sección 3: Inspección Visual y Funcional ─────────────────────────────
    def _build_sec3_inspeccion(self) -> None:
        self._form_layout.addWidget(make_section_header(3, "Inspección Visual y Funcional"))
        grp = QWidget()
        grp.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:6px;")
        layout = QVBoxLayout(grp)
        layout.setContentsMargins(12, 10, 12, 10)
        layout.setSpacing(3)

        # Encabezado de columnas
        hdr_row = QHBoxLayout()
        hdr_row.setContentsMargins(4, 0, 4, 0)
        for txt, w in [("PUNTO", 240), ("CUMPLE", 90), ("NO CUMPLE", 100), ("OBSERVACIONES", 300)]:
            lbl = QLabel(txt)
            lbl.setFixedWidth(w) if txt != "OBSERVACIONES" else lbl.setSizePolicy(
                QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed
            )
            lbl.setStyleSheet("color:#E63946; font-size:9px; font-weight:800; letter-spacing:1px;")
            hdr_row.addWidget(lbl)
        layout.addLayout(hdr_row)

        sep = QFrame(); sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("background:#E63946; max-height:1px;")
        layout.addWidget(sep)

        self._inspeccion_rows = []
        for num, desc in _INSPECCION_PUNTOS:
            row = CumpleRow(num, desc)
            row.setStyleSheet(
                "background:#FAFAFC;" if num % 2 == 0 else "background:transparent;"
            )
            layout.addWidget(row)
            self._inspeccion_rows.append(row)

        self._form_layout.addWidget(grp)

    # ── Secciones 4 y 5: Dinámicas (se reconstruyen) ─────────────────────────
    def _rebuild_dynamic_sections(self, n: int) -> None:
        self._num_celdas = n

        # Limpiar contenedores
        for layout in [self._sec4_layout, self._sec5_layout]:
            while layout.count():
                item = layout.takeAt(0)
                if item.widget():
                    item.widget().deleteLater()

        self._build_sec4_ohms(n)
        self._build_sec5_funcionalidad(n)

    def _build_sec4_ohms(self, n: int) -> None:
        hdr = make_section_header(4, f"Lecturas Sin Carga — Ohms  ({n} celda{'s' if n > 1 else ''})")
        self._sec4_layout.addWidget(hdr)

        # Tabla pivot: filas = mediciones, columnas = celdas
        ncols = n + 1   # +1 para la columna de nombre
        self._ohms_table = QTableWidget(6, ncols)

        col_headers = ["MEDICIÓN"] + [f"Celda {i}" for i in range(1, n + 1)]
        self._ohms_table.setHorizontalHeaderLabels(col_headers)
        self._ohms_table.verticalHeader().setVisible(False)
        self._ohms_table.setAlternatingRowColors(True)
        self._ohms_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)

        hdr_t = self._ohms_table.horizontalHeader()
        hdr_t.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        for c in range(1, ncols):
            hdr_t.setSectionResizeMode(c, QHeaderView.ResizeMode.Stretch)

        for row_idx, (key, label) in enumerate(_OHMS_ROWS):
            # Columna 0: nombre
            item = QTableWidgetItem(label)
            item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            item.setFont(QFont("Segoe UI", 9, QFont.Weight.Bold))
            item.setForeground(QColor("#E63946"))
            self._ohms_table.setItem(row_idx, 0, item)

            # Columnas 1..n: QDoubleSpinBox
            for col_idx in range(1, ncols):
                sb = QDoubleSpinBox()
                sb.setDecimals(4)
                sb.setRange(0, 99999)
                sb.setSpecialValueText(" ")
                sb.setValue(sb.minimum())
                sb.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
                sb.setFrame(False)
                sb.setAlignment(Qt.AlignmentFlag.AlignCenter)
                sb.setStyleSheet(_SB_STYLE)
                # Guardar referencia con clave (row, col)
                sb.setProperty("ohm_key", key)
                sb.setProperty("ohm_col", col_idx)
                self._ohms_table.setCellWidget(row_idx, col_idx, sb)

        row_h = 32
        self._ohms_table.setMinimumHeight(
            self._ohms_table.horizontalHeader().height() + row_h * 6 + 4
        )
        for r in range(6):
            self._ohms_table.setRowHeight(r, row_h)

        self._sec4_layout.addWidget(self._ohms_table)

    def _build_sec5_funcionalidad(self, n: int) -> None:
        hdr = make_section_header(5, "Funcionalidad de Celdas e Indicadores")
        self._sec5_layout.addWidget(hdr)

        body = QWidget()
        body.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:6px;")
        body_layout = QHBoxLayout(body)
        body_layout.setContentsMargins(12, 12, 12, 12)
        body_layout.setSpacing(16)

        # ── Columna izquierda: Funcionalidad por celda ────────────────────────
        left = QVBoxLayout()
        left.setSpacing(4)
        lbl_l = QLabel("FUNCIONALIDAD DE CELDAS")
        lbl_l.setStyleSheet("color:#E63946; font-size:10px; font-weight:800; letter-spacing:1px;")
        left.addWidget(lbl_l)

        self._celda_rows = []
        for i in range(1, n + 1):
            row = CumpleRow(i, f"Celda {i}")
            self._celda_rows.append(row)
            left.addWidget(row)

        # Cables y conectores
        left.addSpacing(6)
        lbl_cab = QLabel("CABLES Y CONECTORES:")
        lbl_cab.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        left.addWidget(lbl_cab)
        self._txt_cables_obs = QTextEdit()
        self._txt_cables_obs.setPlaceholderText("Observaciones de cables y conectores...")
        self._txt_cables_obs.setFixedHeight(60)
        left.addWidget(self._txt_cables_obs)
        left.addStretch()

        # ── Separador ─────────────────────────────────────────────────────────
        vsep = QFrame()
        vsep.setFrameShape(QFrame.Shape.VLine)
        vsep.setStyleSheet("background:#D1D1D6;")

        # ── Columna derecha: Periféricos ──────────────────────────────────────
        right = QVBoxLayout()
        right.setSpacing(4)
        lbl_r = QLabel("INDICADORES Y PERIFÉRICOS")
        lbl_r.setStyleSheet("color:#E63946; font-size:10px; font-weight:800; letter-spacing:1px;")
        right.addWidget(lbl_r)

        self._periferico_rows = []
        for key, desc in _PERIFERICOS:
            row = PeriferalRow(desc)
            row.setProperty("tipo", key)
            self._periferico_rows.append(row)
            right.addWidget(row)

        right.addStretch()

        body_layout.addLayout(left, 3)
        body_layout.addWidget(vsep)
        body_layout.addLayout(right, 2)

        self._sec5_layout.addWidget(body)

    # ── Sección 6: Observaciones y Firmas ─────────────────────────────────────
    def _build_sec6_observaciones(self) -> None:
        self._form_layout.addWidget(make_section_header(6, "Observaciones Generales y Firmas"))
        grp = QWidget()
        grp.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:6px;")
        layout = QVBoxLayout(grp)
        layout.setContentsMargins(14, 12, 14, 12)
        layout.setSpacing(8)

        lbl = QLabel("OBSERVACIONES GENERALES:")
        lbl.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        layout.addWidget(lbl)
        self._txt_obs_generales = QTextEdit()
        self._txt_obs_generales.setPlaceholderText("Observaciones finales, estado general, recomendaciones...")
        self._txt_obs_generales.setFixedHeight(80)
        layout.addWidget(self._txt_obs_generales)

        # Estatus
        estatus_row = QHBoxLayout()
        lbl_est = QLabel("ESTATUS DE LA REVISIÓN:")
        lbl_est.setStyleSheet("color:#86868B; font-size:10px; font-weight:700;")
        estatus_row.addWidget(lbl_est)

        self._btn_completa  = QPushButton("✓  REVISIÓN COMPLETA")
        self._btn_pendiente = QPushButton("⏳  PENDIENTE")
        self._btn_parcial   = QPushButton("◑  PARCIAL")

        for btn, style in [
            (self._btn_completa,  "background:#D4F5DA; color:#34C759; border:1px solid #34C759;"),
            (self._btn_pendiente, "background:#FFF6E5; color:#FF9F0A; border:1px solid #FF9F0A;"),
            (self._btn_parcial,   "background:#E5F0FF; color:#007AFF; border:1px solid #007AFF;"),
        ]:
            btn.setStyleSheet(f"QPushButton {{ {style} border-radius:5px; font-size:11px; font-weight:700; padding:5px 14px; }}")
            btn.setCheckable(True)
            estatus_row.addWidget(btn)

        self._btn_completa.setChecked(False)
        self._btn_pendiente.setChecked(True)

        for btn in [self._btn_completa, self._btn_pendiente, self._btn_parcial]:
            btn.clicked.connect(lambda _, b=btn: self._select_estatus(b))

        estatus_row.addStretch()
        layout.addLayout(estatus_row)
        layout.addSpacing(4)

        self._form_layout.addWidget(grp)

    def _select_estatus(self, selected: QPushButton) -> None:
        for b in [self._btn_completa, self._btn_pendiente, self._btn_parcial]:
            b.setChecked(b == selected)

    def _get_estatus(self) -> str:
        if self._btn_completa.isChecked():  return "COMPLETA"
        if self._btn_parcial.isChecked():   return "PARCIAL"
        return "PENDIENTE"

    # ── Action Bar ────────────────────────────────────────────────────────────
    def _build_action_bar(self) -> QWidget:
        bar = QWidget()
        bar.setFixedHeight(52)
        bar.setStyleSheet("background:#F2F2F7; border-top:1px solid #D1D1D6;")
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(24, 8, 24, 8)
        layout.setSpacing(10)

        btn_limpiar = QPushButton("↺  Limpiar")
        btn_limpiar.setFixedWidth(100)
        btn_limpiar.clicked.connect(self._clear_form)
        layout.addWidget(btn_limpiar)
        layout.addStretch()

        self._btn_pdf = QPushButton("📄  Generar PDF")
        self._btn_pdf.setFixedWidth(150)
        self._btn_pdf.setEnabled(False)
        self._btn_pdf.clicked.connect(self._generate_pdf)
        layout.addWidget(self._btn_pdf)

        self._btn_guardar = QPushButton("💾  Guardar Reporte")
        self._btn_guardar.setProperty("class", "primary")
        self._btn_guardar.setFixedWidth(160)
        self._btn_guardar.clicked.connect(self._save)
        layout.addWidget(self._btn_guardar)
        return bar

    # ── Tab 2: Historial ──────────────────────────────────────────────────────
    def _build_historial_tab(self) -> QWidget:
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 12, 16, 12)
        layout.setSpacing(8)
        tb = QHBoxLayout()
        btn_r = QPushButton("↻  Actualizar"); btn_r.setFixedWidth(120)
        btn_r.clicked.connect(self._load_historial)
        tb.addWidget(btn_r); tb.addStretch()
        layout.addLayout(tb)
        self._hist_table = QTableWidget(0, 7)
        self._hist_table.setHorizontalHeaderLabels(
            ["Folio RE", "Fecha", "Cliente", "Tipo Báscula", "Celdas", "Estatus", "Estado"]
        )
        self._hist_table.verticalHeader().setVisible(False)
        self._hist_table.setAlternatingRowColors(True)
        self._hist_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        hdr = self._hist_table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        layout.addWidget(self._hist_table)
        return w

    # ── Catálogos ─────────────────────────────────────────────────────────────
    def _load_catalogos(self) -> None:
        try:
            from models.catalogo import cliente_repo, tecnico_repo
            self._clientes = cliente_repo.get_all()
            self._tecnicos = tecnico_repo.get_all()
        except Exception as exc:
            logger.error(f"Error catálogos: {exc}")
            self._clientes = self._tecnicos = []

        self._combo_cliente.blockSignals(True)
        self._combo_cliente.clear()
        self._combo_cliente.addItem("— Seleccionar cliente —", None)
        for c in self._clientes:
            self._combo_cliente.addItem(c["razon_social"], c["id"])
        self._combo_cliente.blockSignals(False)

        self._combo_tecnico.clear()
        self._combo_tecnico.addItem("— Seleccionar técnico —", None)
        for t in self._tecnicos:
            self._combo_tecnico.addItem(t["nombre_completo"], t["id"])

    # ── Sucursal / Planta — Cascada ───────────────────────────────────────────
    def _on_cliente_changed(self, index: int) -> None:
        """Al cambiar cliente: cargar sus sucursales."""
        c_id = self._combo_cliente.currentData()
        self._combo_sucursal.blockSignals(True)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        self._txt_direccion.clear()
        self._sucursales = []
        self._combo_sucursal.setEnabled(False)
        self._combo_equipo_cat.clear()
        self._combo_equipo_cat.addItem("— Seleccionar o escribir ID —", None)
        self._combo_equipo_cat.setEnabled(False)

        if c_id:
            try:
                from models.catalogo import sucursal_repo
                self._sucursales = sucursal_repo.get_by_cliente(c_id)
                for s in self._sucursales:
                    self._combo_sucursal.addItem(
                        f"{s['nombre_sucursal']}  —  {s['direccion'][:40]}", s["id"]
                    )
                self._combo_sucursal.setEnabled(True)
            except Exception as exc:
                logger.error("Error cargando sucursales RE: %s", exc)

        self._combo_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, index: int) -> None:
        """Al cambiar sucursal: autocompleta dirección y carga equipos."""
        s_id = self._combo_sucursal.currentData()
        self._txt_direccion.clear()
        self._equipos_sucursal = []
        self._combo_equipo_cat.blockSignals(True)
        self._combo_equipo_cat.clear()
        self._combo_equipo_cat.addItem("— Seleccionar o escribir ID —", None)
        self._combo_equipo_cat.setEnabled(False)
        self._combo_equipo_cat.blockSignals(False)

        if not s_id:
            return

        # Autocompleta dirección desde la lista de sucursales ya cargadas
        suc = next((s for s in self._sucursales if s["id"] == s_id), None)
        if suc:
            self._txt_direccion.setText(suc.get("direccion") or "")

        # Carga equipos de la sucursal
        try:
            from models.catalogo import equipo_sucursal_repo
            self._equipos_sucursal = equipo_sucursal_repo.get_by_sucursal(s_id)
            self._combo_equipo_cat.blockSignals(True)
            for eq in self._equipos_sucursal:
                tag   = eq.get("id_indicador_equipo") or ""
                marca = eq.get("marca") or ""
                ns    = eq.get("numero_serie") or ""
                label = f"{tag}  —  {marca}  N/S: {ns}" if tag else f"{marca}  N/S: {ns}"
                self._combo_equipo_cat.addItem(label.strip(), eq["id"])
            self._combo_equipo_cat.setEnabled(True)
            self._combo_equipo_cat.blockSignals(False)
        except Exception as exc:
            logger.error("Error cargando equipos RE sucursal: %s", exc)

    def _on_id_equipo_changed(self, index: int) -> None:
        """Al seleccionar equipo del catálogo: autorrellena campos del instrumento."""
        eq_id = self._combo_equipo_cat.itemData(index)
        if not eq_id:
            return
        eq = next((e for e in self._equipos_sucursal if e["id"] == eq_id), None)
        if not eq:
            return
        self._txt_marca.setText(eq.get("marca") or "")
        self._txt_modelo.setText(eq.get("modelo") or "")
        self._txt_ns.setText(eq.get("numero_serie") or "")
        self._txt_alcance.setText(eq.get("capacidad_maxima") or "")
        self._txt_div_min.setText(eq.get("division_minima") or "")
        self._txt_tipo_inst.setText(eq.get("tipo_instrumento") or "")
        self._txt_ubicacion.setText(eq.get("ubicacion_interna") or "")
        self._txt_id_interno.setText(eq.get("id_indicador_equipo") or "")

    def _load_historial(self) -> None:
        try:
            from models.revision_bascula import revision_bascula_repo
            rows = revision_bascula_repo.get_all()
        except Exception as exc:
            logger.error(f"Error historial RE: {exc}")
            rows = []
        _EC = {"COMPLETA": "#34C759", "PENDIENTE": "#FF9F0A", "PARCIAL": "#007AFF"}
        self._hist_table.setRowCount(0)
        for r in rows:
            i = self._hist_table.rowCount()
            self._hist_table.insertRow(i)
            self._hist_table.setRowHeight(i, 34)
            for col, v in enumerate([
                r.get("folio_re", ""), str(r.get("fecha", ""))[:10],
                r.get("cliente", ""), r.get("tipo_bascula", ""),
                str(r.get("num_celdas", "")),
                r.get("estatus_revision", ""), r.get("estado", ""),
            ]):
                it = QTableWidgetItem(str(v))
                it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col == 0: it.setData(Qt.ItemDataRole.UserRole, r.get("id"))
                if col == 5: it.setForeground(QColor(_EC.get(str(v), "#86868B")))
                self._hist_table.setItem(i, col, it)

    # ── Colectar datos ────────────────────────────────────────────────────────
    def _collect_celdas_data(self) -> list[dict]:
        """Recolecta datos de la tabla Ohms y funcionalidad por celda."""
        n = self._num_celdas
        celdas = [{} for _ in range(n)]

        # Ohms
        for row_idx, (key, _) in enumerate(_OHMS_ROWS):
            for col_idx in range(1, n + 1):
                sb = self._ohms_table.cellWidget(row_idx, col_idx)
                val = None if (not sb or sb.value() == sb.minimum()) else sb.value()
                celdas[col_idx - 1][key] = val

        # Funcionalidad
        for i, crow in enumerate(self._celda_rows):
            if i < n:
                d = crow.get_data()
                celdas[i]["funciona"]         = d["cumple"]
                celdas[i]["obs_funcionalidad"] = d["observacion"]

        return celdas

    def _collect_inspeccion_data(self) -> list[dict]:
        result = []
        for i, (crow, (num, desc)) in enumerate(
            zip(self._inspeccion_rows, _INSPECCION_PUNTOS)
        ):
            d = crow.get_data()
            result.append({"punto_num": num, "descripcion": desc, **d})
        return result

    def _collect_perifericos_data(self) -> list[dict]:
        result = []
        for row, (key, desc) in zip(self._periferico_rows, _PERIFERICOS):
            d = row.get_data()
            result.append({"tipo": key, "descripcion": desc, **d})
        return result

    # ── Guardar ───────────────────────────────────────────────────────────────
    def _save(self) -> None:
        if not self._combo_cliente.currentData():
            QMessageBox.warning(self, "Validación", "Seleccione un cliente.")
            return

        fecha_q = self._date_edit.date()
        sucursal_id  = self._combo_sucursal.currentData()
        eq_cat_id    = self._combo_equipo_cat.currentData()
        direccion    = self._txt_direccion.text().strip()
        data = {
            "fecha":              date(fecha_q.year(), fecha_q.month(), fecha_q.day()),
            "id_cliente":         self._combo_cliente.currentData(),
            "id_tecnico":         self._combo_tecnico.currentData(),
            "sucursal_id":        sucursal_id,       # FK nullable — requiere migración v15
            "equipo_catalogo_id": eq_cat_id,          # FK nullable
            "marca":              self._txt_marca.text().strip() or None,
            "modelo":             self._txt_modelo.text().strip() or None,
            "numero_serie":       self._txt_ns.text().strip() or None,
            "id_indicador_equipo": self._txt_id_interno.text().strip() or None,
            "ubicacion_interna":  self._txt_ubicacion.text().strip() or None,
            "tipo_bascula":       self._combo_tipo_bascula.currentText().strip() or None,
            "num_celdas":         self._num_celdas,
            "horario":            self._txt_horario.text().strip() or None,
            "contacto_nombre":    None,
            "contacto_telefono":  None,
            "contacto_correo":    None,
            "obs_cables_conectores": self._txt_cables_obs.toPlainText().strip() or None,
            "obs_generales":      self._txt_obs_generales.toPlainText().strip() or None,
            "observaciones":      None,
            "estatus_revision":   self._get_estatus(),
            # Campos de dirección (para inyección en PDF)
            "direccion":          direccion,
            "sucursal_direccion": direccion,
            # Detalles
            "celdas":      self._collect_celdas_data(),
            "inspeccion":  self._collect_inspeccion_data(),
            "perifericos": self._collect_perifericos_data(),
        }

        try:
            self._btn_guardar.setEnabled(False)
            self._btn_guardar.setText("Guardando...")
            from models.revision_bascula import revision_bascula_repo
            result = revision_bascula_repo.create_full(data)
            folio = result.get("folio_re", "")
            self._lbl_folio.setText(folio)
            self._last_revision_id = result.get("id")
            self._btn_pdf.setEnabled(True)
            QMessageBox.information(self, "Éxito", f"Reporte guardado: {folio}")
            self.re_saved.emit(folio)
            self._load_historial()
        except Exception as exc:
            logger.error(f"Error al guardar RE: {exc}")
            QMessageBox.critical(self, "Error", f"No se pudo guardar:\n{exc}")
        finally:
            self._btn_guardar.setEnabled(True)
            self._btn_guardar.setText("💾  Guardar Reporte")

    def _generate_pdf(self) -> None:
        rev_id = getattr(self, "_last_revision_id", None)
        if not rev_id:
            QMessageBox.warning(self, "Sin Reporte", "Guarde el reporte primero.")
            return
        try:
            from models.revision_bascula import revision_bascula_repo
            from services.re_pdf_generator import re_pdf_generator
            import config, os
            from pathlib import Path

            rv_data     = revision_bascula_repo.get_by_id(rev_id)
            celdas      = revision_bascula_repo.get_celdas(rev_id)
            inspeccion  = revision_bascula_repo.get_inspeccion(rev_id)
            perifericos = revision_bascula_repo.get_perifericos(rev_id)

            # Inyectar dirección unificada desde el widget
            direccion_widget = self._txt_direccion.text().strip()
            if direccion_widget:
                rv_data["direccion"]          = direccion_widget
                rv_data["sucursal_direccion"] = direccion_widget
            elif not rv_data.get("direccion") and not rv_data.get("sucursal_direccion"):
                # Fallback: buscar en lista de sucursales
                s_id = self._combo_sucursal.currentData()
                if s_id:
                    suc = next((s for s in self._sucursales if s["id"] == s_id), None)
                    if suc:
                        rv_data["direccion"] = suc.get("direccion") or ""

            output_dir = Path(config.SERVER_FILES_BASE) / "PDF_RE"
            output_dir.mkdir(parents=True, exist_ok=True)
            out = str(output_dir / f"{rv_data.get('folio_re','RE')}.pdf")

            self._btn_pdf.setEnabled(False)
            self._btn_pdf.setText("Generando...")
            path = re_pdf_generator.generate(rv_data, celdas, inspeccion, perifericos, out)
            QMessageBox.information(self, "PDF", f"PDF generado:\n{path}")
            os.startfile(path)
        except Exception as exc:
            logger.error(f"Error PDF RE: {exc}")
            QMessageBox.critical(self, "Error PDF", str(exc))
        finally:
            self._btn_pdf.setEnabled(True)
            self._btn_pdf.setText("📄  Generar PDF")

    def _clear_form(self) -> None:
        self._lbl_folio.setText("— NUEVO —")
        self._date_edit.setDate(QDate.currentDate())
        self._txt_horario.clear()
        self._combo_cliente.setCurrentIndex(0)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        self._combo_sucursal.setEnabled(False)
        self._combo_equipo_cat.clear()
        self._combo_equipo_cat.addItem("— Seleccionar o escribir ID —", None)
        self._combo_equipo_cat.setEnabled(False)
        self._txt_direccion.clear()
        self._combo_tecnico.setCurrentIndex(0)
        self._txt_contacto_nombre.clear()
        self._txt_cli_telefono.clear()
        self._txt_cli_correo.clear()
        for w in [self._txt_marca, self._txt_modelo, self._txt_ns,
                  self._txt_alcance, self._txt_tipo_inst, self._txt_div_min,
                  self._txt_div_ver, self._txt_cca, self._txt_ubicacion,
                  self._txt_id_interno, self._txt_holograma]:
            w.clear()
        for row in self._inspeccion_rows:
            row._state = None; row._obs.clear(); row._update_styles()
        self._txt_obs_generales.clear()
        self._txt_cables_obs.clear()
        self._btn_pendiente.setChecked(True)
        self._btn_completa.setChecked(False)
        self._btn_parcial.setChecked(False)
        self._btn_pdf.setEnabled(False)
        self._rebuild_dynamic_sections(4)
        self._spin_celdas.setValue(4)
