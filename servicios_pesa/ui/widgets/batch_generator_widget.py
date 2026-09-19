"""
batch_generator_widget.py — Asistente de Generación de Formatos (4 pasos)
Servicios PESA v2.1

Flujo:
  Paso 1 → Modalidad      : Digital (Tablet) | Físico (Calca)
  Paso 2 → Tipo documento : OS | RMA | RE
  Paso 3 → Parámetros     : Cliente, Técnico, Cantidad, Fecha
  Paso 4 → Acción         : Generar PDF  |  Asignar a Tablet
"""
from __future__ import annotations

import logging
import datetime
from datetime import date
from typing import Optional

from PyQt6.QtCore    import Qt, QTimer, pyqtSignal, QThread, pyqtSlot
from PyQt6.QtGui     import QFont, QColor
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QFrame, QSpinBox, QDateEdit,
    QComboBox, QScrollArea, QSizePolicy,
    QButtonGroup, QRadioButton, QMessageBox,
    QProgressBar, QAbstractItemView, QTextEdit, QLineEdit, QCompleter,
)
from PyQt6.QtCore import QDate

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales ──────────────────────────────────────────────────
try:
    from database.connection import db_pool as _db_pool
    _HAS_DB = True
except ImportError:
    _HAS_DB = False
    _db_pool = None

try:
    from auth.session_context import session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    session = None

# ─── Paleta ───────────────────────────────────────────────────────────────────
_BG    = "#F5F5F7"
_WHITE = "#FFFFFF"
_DARK  = "#1D1D1F"
_GRAY  = "#86868B"
_RED   = "#E63946"
_BLUE  = "#007AFF"
_GREEN = "#34C759"
_AMBER = "#FF9F0A"

# (Sin datos hardcoded — los catálogos se cargan exclusivamente desde PostgreSQL)


# ══════════════════════════════════════════════════════════════════════════════
# EquipoCard — Tarjeta de datos del instrumento por índice de equipo
# ══════════════════════════════════════════════════════════════════════════════
_EQUIPO_FIELD_STYLE = """
    QLineEdit {
        background: #F8FAFC;
        border: 1.5px solid #D1D5DB;
        border-radius: 8px;
        padding: 7px 12px;
        font-size: 13px;
        color: #1D1D1F;
        min-height: 36px;
    }
    QLineEdit:focus {
        border-color: #007AFF;
        background: #FFFFFF;
    }
    QLineEdit::placeholder { color: #A0ADB8; }
"""

class EquipoCard(QFrame):
    """
    Tarjeta colapsable con 6 campos opcionales para pre-llenar los datos
    del instrumento antes de imprimir el formato.
    Todos los campos son opcionales: si se dejan en blanco, el técnico
    los llena en campo.
    """
    def __init__(self, index: int, parent=None):
        super().__init__(parent)
        self._index = index
        self._expanded = True
        self._catalog = []
        self._build()

    def set_instrument_catalog(self, catalog: list[dict]) -> None:
        """Configura el catálogo de instrumentos sugeridos y actualiza el QCompleter."""
        self._catalog = catalog
        
        # Extraer sugerencias únicas para ID y Serie
        ids = list({str(item.get("id_indicador", "")) for item in catalog if item.get("id_indicador")})
        series = list({str(item.get("numero_serie", "")) for item in catalog if item.get("numero_serie")})
        
        # Configurar completer para ID
        if ids:
            completer_id = QCompleter(ids, self)
            completer_id.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
            completer_id.setFilterMode(Qt.MatchFlag.MatchContains)
            completer_id.activated.connect(lambda text: self._on_completer_activated(text, "id_indicador"))
            self._inp_id.setCompleter(completer_id)
            
        # Configurar completer para Serie
        if series:
            completer_ns = QCompleter(series, self)
            completer_ns.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
            completer_ns.setFilterMode(Qt.MatchFlag.MatchContains)
            completer_ns.activated.connect(lambda text: self._on_completer_activated(text, "numero_serie"))
            self._inp_ns.setCompleter(completer_ns)

    def _on_completer_activated(self, text: str, field_name: str) -> None:
        """Al seleccionar un item del completer, rellena TODOS los campos del equipo."""
        for item in self._catalog:
            if str(item.get(field_name, "")) == text:
                # Siempre rellenar (sobreescribir) para que el autocompletado sea útil
                if item.get("marca"):
                    self._inp_marca.setText(str(item["marca"]))
                if item.get("modelo"):
                    self._inp_modelo.setText(str(item["modelo"]))
                if item.get("capacidad_max"):
                    self._inp_alcance.setText(str(item["capacidad_max"]))
                if item.get("division_min"):
                    self._inp_division.setText(str(item["division_min"]))
                if item.get("ubicacion"):
                    self._inp_ubicacion.setText(str(item["ubicacion"]))
                if item.get("tipo_instrumento") and hasattr(self, '_cmb_tipo'):
                    idx = self._cmb_tipo.findText(item["tipo_instrumento"],
                                                   Qt.MatchFlag.MatchContains)
                    if idx >= 0:
                        self._cmb_tipo.setCurrentIndex(idx)
                # Rellenar el campo cruzado (ID ↔ Serie)
                if field_name == "numero_serie" and item.get("id_indicador"):
                    self._inp_id.setText(str(item["id_indicador"]))
                if field_name == "id_indicador" and item.get("numero_serie"):
                    self._inp_ns.setText(str(item["numero_serie"]))
                break

    def _build(self) -> None:
        self.setObjectName(f"equipo_card_{self._index}")
        self.setStyleSheet("""
            QFrame {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.07);
                border-radius: 12px;
            }
        """)
        root = QVBoxLayout(self)
        root.setContentsMargins(18, 14, 18, 14)
        root.setSpacing(10)

        # ── Cabecera de la tarjeta ─────────────────────────────────────
        header = QHBoxLayout()
        header.setContentsMargins(0, 0, 0, 0)

        badge = QLabel(str(self._index))
        badge.setFixedSize(22, 22)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(
            f"background: {_RED}; color: #FFFFFF; border-radius: 11px; "
            f"font-size: 11px; font-weight: 700;"
        )
        header.addWidget(badge)

        lbl = QLabel(f"Instrumento {self._index}  ·  (datos opcionales)")
        lbl.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        header.addWidget(lbl, stretch=1)

        self._btn_toggle = QPushButton("−")
        self._btn_toggle.setFixedSize(24, 24)
        self._btn_toggle.setStyleSheet(
            f"QPushButton {{ background: transparent; color: {_GRAY}; border: none; "
            f"font-size: 16px; font-weight: 700; }}"
            f"QPushButton:hover {{ color: {_DARK}; }}"
        )
        self._btn_toggle.clicked.connect(self._toggle)
        header.addWidget(self._btn_toggle)
        root.addLayout(header)

        # ── Campos editables ───────────────────────────────────────────
        self._fields_widget = QWidget()
        self._fields_widget.setStyleSheet("background: transparent;")
        fields_lay = QVBoxLayout(self._fields_widget)
        fields_lay.setContentsMargins(0, 4, 0, 0)
        fields_lay.setSpacing(10)

        # Fila 1: Marca / Modelo / N° de Serie / ID
        row1 = QHBoxLayout()
        row1.setSpacing(12)
        self._inp_marca    = self._make_input("Marca (ej: METTLER TOLEDO)",    row1, "Marca")
        self._inp_modelo   = self._make_input("Modelo (ej: IND560)",           row1, "Modelo")
        self._inp_ns       = self._make_input("N° de Serie (ej: B215004321)",  row1, "N° de Serie")
        self._inp_id       = self._make_input("ID Indicador / Equipo (ej: Trailer A)", row1, "ID Indicador / Equipo")
        fields_lay.addLayout(row1)

        # Fila 2: Capacidad Máxima / División Mínima / DVE (solo inspección) / Ubicación
        row2 = QHBoxLayout()
        row2.setSpacing(12)
        self._inp_alcance   = self._make_input("Capacidad Máxima (ej: 500 kg)",   row2, "Capacidad Máx.")
        self._inp_division  = self._make_input("División Mínima (ej: 50 g)",      row2, "División Mín.")

        # DVE: contenedor oculto por defecto; se muestra solo si el servicio contiene 'inspección'
        self._wgt_dve = QWidget()
        self._wgt_dve.setStyleSheet("background: transparent;")
        _dve_col = QVBoxLayout(self._wgt_dve)
        _dve_col.setContentsMargins(0, 0, 0, 0)
        _dve_col.setSpacing(4)
        _lbl_dve = QLabel("DVE")
        _lbl_dve.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; "
            "letter-spacing: 0.3px; background: transparent;"
        )
        _dve_col.addWidget(_lbl_dve)
        self._inp_dve = QLineEdit()
        self._inp_dve.setPlaceholderText("DVE (ej: 10 kg)")
        self._inp_dve.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._inp_dve.setFixedHeight(40)
        _dve_col.addWidget(self._inp_dve)
        self._wgt_dve.setVisible(False)   # oculto hasta que el servicio incluya inspección
        row2.addWidget(self._wgt_dve, stretch=1)

        self._inp_ubicacion = self._make_input("Ubicación (ej: Planta Norte)",     row2, "Ubicación")
        fields_lay.addLayout(row2)

        # ── Fila 3: Capacidad / División / DVE / Puntos de Apoyo ──────────────
        self._wgt_hologramas = QWidget()
        self._wgt_hologramas.setStyleSheet("background: transparent;")
        _holo_lay = QHBoxLayout(self._wgt_hologramas)
        _holo_lay.setContentsMargins(0, 0, 0, 0)
        _holo_lay.setSpacing(12)
        self._inp_holograma_ant = self._make_input(
            "Folio del holograma anterior (opcional)", _holo_lay, "Holograma Anterior"
        )
        self._inp_holograma_act = self._make_input(
            "Folio del holograma actualizado (opcional)", _holo_lay, "Holograma Actualizado"
        )
        self._wgt_hologramas.setVisible(False)   # oculto por defecto; se activa si servicio tiene inspección
        fields_lay.addWidget(self._wgt_hologramas)

        # ── Fila 2: Tipo de Instrumento y Calibración ──────────────────────────────
        self._fields_row2 = QWidget()
        row2 = QHBoxLayout(self._fields_row2)
        row2.setContentsMargins(0,0,0,0)
        row2.setSpacing(12)

        _col_tipo = QVBoxLayout(); _col_tipo.setSpacing(4)
        _lbl_tipo = QLabel("Tipo de Instrumento")
        _lbl_tipo.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_tipo.addWidget(_lbl_tipo)
        self._cmb_tipo_inst = QComboBox()
        self._cmb_tipo_inst.addItems([
            "Báscula de plataforma",
            "Báscula camionera / puente de pesaje",
            "Báscula tipo circular",
            "Báscula tipo Tanque",
            "Báscula tipo Tolva",
            "Báscula tipo Gancho / Grúa suspendida",
            "Báscula tipo Patín / Transpaleta hidráulica",
        ])
        self._cmb_tipo_inst.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_tipo_inst.setFixedHeight(40)
        self._cmb_tipo_inst.currentIndexChanged.connect(self._on_tipo_inst_changed)
        _col_tipo.addWidget(self._cmb_tipo_inst)
        row2.addLayout(_col_tipo, stretch=2)

        # ── Contenedor unificado para Inicial + CCA (ocultar juntos según tipo de servicio) ──
        self._widget_calibracion = QWidget()
        self._widget_calibracion.setStyleSheet("background: transparent;")
        _calib_lay = QHBoxLayout(self._widget_calibracion)
        _calib_lay.setContentsMargins(0, 0, 0, 0)
        _calib_lay.setSpacing(12)

        _col_ini = QVBoxLayout(); _col_ini.setSpacing(4)
        self._lbl_ini = QLabel("Inicial Calibrador")
        self._lbl_ini.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_ini.addWidget(self._lbl_ini)
        self._cmb_inicial = QComboBox()
        self._cmb_inicial.addItems(["Ninguna", "J", "I", "A"])
        self._cmb_inicial.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_inicial.setFixedHeight(40)
        _col_ini.addWidget(self._cmb_inicial)
        _calib_lay.addLayout(_col_ini, stretch=1)

        _col_cca = QVBoxLayout(); _col_cca.setSpacing(4)
        self._lbl_cca = QLabel("Número de CCA")
        self._lbl_cca.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_cca.addWidget(self._lbl_cca)
        self._inp_cca = QLineEdit()
        self._inp_cca.setPlaceholderText("Ej: CCA.26.001")
        self._inp_cca.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._inp_cca.setFixedHeight(40)
        _col_cca.addWidget(self._inp_cca)
        _calib_lay.addLayout(_col_cca, stretch=2)

        row2.addWidget(self._widget_calibracion, stretch=3)

        fields_lay.addWidget(self._fields_row2)

        # Fila 3: Excentricidad + Puntos de Exactitud
        self._fields_row3 = QWidget()
        row3 = QHBoxLayout(self._fields_row3)
        row3.setContentsMargins(0,0,0,0)
        row3.setSpacing(12)

        _col_aplica = QVBoxLayout(); _col_aplica.setSpacing(4)
        _lbl_ap = QLabel("¿Aplica Excentricidad?")
        _lbl_ap.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_aplica.addWidget(_lbl_ap)
        self._cmb_aplica_exc = QComboBox()
        self._cmb_aplica_exc.addItems(["SÍ", "NO"])
        self._cmb_aplica_exc.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_aplica_exc.setFixedHeight(40)
        self._cmb_aplica_exc.currentIndexChanged.connect(self._on_aplica_exc_changed)
        _col_aplica.addWidget(self._cmb_aplica_exc)
        row3.addLayout(_col_aplica, stretch=1)

        # Filas / Puntos de Excentricidad (visible solo cuando aplica = SÍ)
        self._wgt_filas_exc = QWidget()
        self._wgt_filas_exc.setStyleSheet("background: transparent;")
        _col_filas_exc = QVBoxLayout(self._wgt_filas_exc)
        _col_filas_exc.setContentsMargins(0, 0, 0, 0)
        _col_filas_exc.setSpacing(4)
        _lbl_filas_exc = QLabel("Puntos / Filas Exc.")
        _lbl_filas_exc.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_filas_exc.addWidget(_lbl_filas_exc)
        self._spin_filas_exc = QSpinBox()
        self._spin_filas_exc.setRange(1, 10)
        self._spin_filas_exc.setValue(5)
        self._spin_filas_exc.setSuffix(" pos")
        self._spin_filas_exc.setFixedHeight(40)
        self._spin_filas_exc.setFixedWidth(110)
        self._spin_filas_exc.setStyleSheet(
            _EQUIPO_FIELD_STYLE.replace('QLineEdit', 'QSpinBox')
        )
        self._spin_filas_exc.setToolTip(
            "Número de posiciones de excentricidad (renglones en la tabla del PDF).\n"
            "Por defecto: 5.  Cambia según el tipo de instrumento."
        )
        _col_filas_exc.addWidget(self._spin_filas_exc)
        row3.addWidget(self._wgt_filas_exc)

        # Puntos de Exactitud: selector compacto por instrumento
        _col_pts = QVBoxLayout(); _col_pts.setSpacing(4)
        _lbl_pts = QLabel("Pts. Exactitud")
        _lbl_pts.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_pts.addWidget(_lbl_pts)
        self._spin_pts_exact = QSpinBox()
        self._spin_pts_exact.setRange(1, 15)
        self._spin_pts_exact.setValue(5)   # mismo default que el global
        self._spin_pts_exact.setSuffix(" pts")
        self._spin_pts_exact.setFixedHeight(40)
        self._spin_pts_exact.setFixedWidth(110)
        self._spin_pts_exact.setStyleSheet(_EQUIPO_FIELD_STYLE.replace('QLineEdit', 'QSpinBox'))
        self._spin_pts_exact.setToolTip(
            "Número de puntos de exactitud para este instrumento.\n"
            "Sobreescribe el valor global del Paso 3."
        )
        _col_pts.addWidget(self._spin_pts_exact)
        row3.addLayout(_col_pts)

        self._wgt_geo = QWidget()
        _lay_geo = QHBoxLayout(self._wgt_geo)
        _lay_geo.setContentsMargins(0,0,0,0)
        _lay_geo.setSpacing(12)
        _col_geo = QVBoxLayout(); _col_geo.setSpacing(4)
        _lbl_geo = QLabel("Geometría / Puntos")
        _lbl_geo.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_geo.addWidget(_lbl_geo)
        self._cmb_geo = QComboBox()
        self._cmb_geo.addItems(["Libre", "Plataforma Cuadrada", "Plataforma Circular", "Camionera"])
        self._cmb_geo.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_geo.setFixedHeight(40)
        _col_geo.addWidget(self._cmb_geo)
        _lay_geo.addLayout(_col_geo, stretch=2)

        self._wgt_secciones = QWidget()
        self._wgt_secciones.setStyleSheet("background: transparent;")
        _col_sec = QVBoxLayout(self._wgt_secciones)
        _col_sec.setContentsMargins(0,0,0,0)
        _col_sec.setSpacing(4)
        _lbl_sec = QLabel("Secciones")
        _lbl_sec.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_sec.addWidget(_lbl_sec)
        self._spin_sec = QSpinBox()
        self._spin_sec.setRange(2,8)
        self._spin_sec.setValue(4)
        self._spin_sec.setFixedHeight(40)
        self._spin_sec.setStyleSheet(_EQUIPO_FIELD_STYLE.replace('QLineEdit','QSpinBox'))
        _col_sec.addWidget(self._spin_sec)
        _lay_geo.addWidget(self._wgt_secciones, stretch=1)
        row3.addWidget(self._wgt_geo, stretch=2)
        
        self._cmb_geo.currentIndexChanged.connect(self._actualizar_visibilidad_secciones)

        self._wgt_no = QWidget()
        _lay_no = QHBoxLayout(self._wgt_no)
        _lay_no.setContentsMargins(0,0,0,0)
        _lay_no.setSpacing(12)
        _col_no = QVBoxLayout(); _col_no.setSpacing(4)
        _lbl_no = QLabel("Motivo No Aplica")
        _lbl_no.setStyleSheet("font-size: 11px; font-weight: 700; color: #86868B;")
        _col_no.addWidget(_lbl_no)
        self._cmb_no = QComboBox()
        self._cmb_no.addItems([
            "Báscula tipo Tanque",
            "Báscula tipo Tolva",
            "Báscula tipo Gancho / Grúa suspendida",
            "Báscula tipo Patín / Transpaleta hidráulica",
        ])
        self._cmb_no.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_no.setFixedHeight(40)
        self._cmb_no.currentIndexChanged.connect(self._on_motivo_no_changed)
        _col_no.addWidget(self._cmb_no)
        _lay_no.addLayout(_col_no)
        self._wgt_no.setVisible(False)
        row3.addWidget(self._wgt_no, stretch=2)

        fields_lay.addWidget(self._fields_row3)
        self._on_aplica_exc_changed()

        # ── Bloque 4: Calibración por Enlace de Sustitución (solo Tanque) ──────
        # Aparece cuando tipo instrumento = Tanque   O   motivo-no-aplica = Tanque.
        # ────────────────────────────────────────────────────────────
        self._wgt_enlaces = QFrame()
        self._wgt_enlaces.setObjectName("wgt_enlaces_sustitucion")
        self._wgt_enlaces.setStyleSheet("""
            QFrame#wgt_enlaces_sustitucion {
                background: rgba(0,122,255,0.06);
                border: 1.5px solid rgba(0,122,255,0.30);
                border-radius: 10px;
            }
        """)
        _enl_root = QVBoxLayout(self._wgt_enlaces)
        _enl_root.setContentsMargins(14, 10, 14, 10)
        _enl_root.setSpacing(8)

        # —— Título del bloque ——————————————————————————————————
        _enl_hdr_row = QHBoxLayout()
        _enl_hdr_row.setSpacing(8)
        _lbl_enl_icon = QLabel("🔗")
        _lbl_enl_icon.setStyleSheet("font-size: 17px; background: transparent;")
        _lbl_enl_icon.setFixedWidth(24)
        _enl_hdr_row.addWidget(_lbl_enl_icon)
        _lbl_enl_title = QLabel("Calibración por Enlaces de Sustitución  —  NOM-010-SCFI / OIML R 76")
        _lbl_enl_title.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #1D4ED8; background: transparent;"
        )
        _enl_hdr_row.addWidget(_lbl_enl_title, stretch=1)
        _enl_root.addLayout(_enl_hdr_row)

        # —— Controles de enlaces —————————————————————————————
        _enl_controls_row = QHBoxLayout()
        _enl_controls_row.setSpacing(20)

        # Combo: ¿Aplica Enlaces de Sustitución?
        _col_usa_enl = QVBoxLayout(); _col_usa_enl.setSpacing(4)
        _lbl_usa_enl = QLabel("¿Aplica Enlaces de Sustitución?")
        _lbl_usa_enl.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; background: transparent;"
        )
        _col_usa_enl.addWidget(_lbl_usa_enl)
        self._cmb_usa_enlaces = QComboBox()
        self._cmb_usa_enlaces.addItems(["NO", "SÍ"])
        self._cmb_usa_enlaces.setCurrentText("SÍ")
        self._cmb_usa_enlaces.setStyleSheet(_EQUIPO_FIELD_STYLE)
        self._cmb_usa_enlaces.setFixedHeight(40)
        self._cmb_usa_enlaces.setMinimumWidth(120)
        self._cmb_usa_enlaces.currentIndexChanged.connect(self._on_usa_enlaces_changed)
        _col_usa_enl.addWidget(self._cmb_usa_enlaces)
        _enl_controls_row.addLayout(_col_usa_enl)

        # Spinbox: ¿Cuántos Enlaces son? (solo visible si SÍ)
        _col_n_enl = QVBoxLayout(); _col_n_enl.setSpacing(4)
        _lbl_n_enl = QLabel("¿Cuántos Enlaces son?")
        _lbl_n_enl.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; background: transparent;"
        )
        _col_n_enl.addWidget(_lbl_n_enl)
        self._spin_enlaces = QSpinBox()
        self._spin_enlaces.setRange(1, 20)
        self._spin_enlaces.setValue(8)
        self._spin_enlaces.setSuffix("  enlaces")
        self._spin_enlaces.setFixedHeight(40)
        self._spin_enlaces.setMinimumWidth(160)
        self._spin_enlaces.setStyleSheet(
            _EQUIPO_FIELD_STYLE.replace('QLineEdit', 'QSpinBox')
        )
        _col_n_enl.addWidget(self._spin_enlaces)
        self._wgt_spin_enlaces = QWidget()   # contenedor para mostrar/ocultar
        self._wgt_spin_enlaces.setStyleSheet("background: transparent;")
        _sp_wrap = QHBoxLayout(self._wgt_spin_enlaces)
        _sp_wrap.setContentsMargins(0, 0, 0, 0)
        _sp_wrap.addLayout(_col_n_enl)
        _enl_controls_row.addWidget(self._wgt_spin_enlaces)

        # Nota informativa
        _lbl_enl_nota = QLabel(
            "⚠️  La carga de pesas patrón la determina el técnico en campo — no se fija aquí."
        )
        _lbl_enl_nota.setStyleSheet(
            "font-size: 10px; color: #6B7280; background: transparent;"
        )
        _lbl_enl_nota.setWordWrap(True)
        _enl_controls_row.addWidget(_lbl_enl_nota, stretch=1)

        _enl_root.addLayout(_enl_controls_row)

        self._wgt_enlaces.setVisible(False)
        fields_lay.addWidget(self._wgt_enlaces)

        root.addWidget(self._fields_widget)

        # Aplicar reglas iniciales según tipo de instrumento seleccionado
        self._on_tipo_inst_changed()

        # ── Alias públicos para acceso externo seguro (compatibilidad con directiva) ──
        self.input_marca              = self._inp_marca
        self.input_modelo             = self._inp_modelo
        self.input_serie              = self._inp_ns
        self.input_id_equipo          = self._inp_id
        self.input_capacidad          = self._inp_alcance
        self.input_division           = self._inp_division
        self.input_ubicacion          = self._inp_ubicacion
        self.combo_tipo_instrumento   = self._cmb_tipo_inst
        self.combo_inicial            = self._cmb_inicial
        self.label_inicial            = self._lbl_ini
        self.label_cca                = self._lbl_cca
        self.widget_calibracion       = self._widget_calibracion
        self.input_cca                = self._inp_cca
        self.combo_aplica_excentricidad = self._cmb_aplica_exc
        self.combo_geometria          = self._cmb_geo
        self.spin_secciones           = self._spin_sec
        # Alias para hologramas (acceso desde recolector de datos)
        self.input_holograma_ant      = self._inp_holograma_ant
        self.input_holograma_act      = self._inp_holograma_act
        # Alias para DVE
        self.input_dve                = self._inp_dve
        # Alias para Puntos de Exactitud por instrumento
        self.spin_puntos_exactitud    = self._spin_pts_exact
        # Alias para Puntos/Filas de Excentricidad (acceso externo)
        self.spin_filas_excentricidad = self._spin_filas_exc

    def set_puntos_exactitud(self, n: int) -> None:
        """Propaga el valor global de 'Puntos de Exactitud' a esta tarjeta.
        El usuario puede ajustarlo individualmente tras la propagación.
        """
        try:
            self._spin_pts_exact.setValue(int(n))
        except Exception:
            pass

    def _make_input(self, placeholder: str, layout: QHBoxLayout,
                    label_txt: str) -> QLineEdit:
        col = QVBoxLayout()
        col.setSpacing(4)
        lbl = QLabel(label_txt)
        lbl.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; "
            "letter-spacing: 0.3px; background: transparent;"
        )
        col.addWidget(lbl)
        inp = QLineEdit()
        inp.setPlaceholderText(placeholder)
        inp.setStyleSheet(_EQUIPO_FIELD_STYLE)
        inp.setFixedHeight(40)
        col.addWidget(inp)
        layout.addLayout(col, stretch=1)
        return inp


    def _on_aplica_exc_changed(self):
        aplica = self._cmb_aplica_exc.currentText() == "SÍ"
        self._wgt_geo.setVisible(aplica)
        self._wgt_no.setVisible(not aplica)
        # Mostrar / ocultar el spinbox de filas de excentricidad
        if hasattr(self, '_wgt_filas_exc'):
            self._wgt_filas_exc.setVisible(aplica)
        # Al cambiar excentricidad, re-evaluar visibilidad de enlaces y secciones
        self._actualizar_visibilidad_enlaces()
        self._actualizar_visibilidad_secciones()

    def _on_motivo_no_changed(self) -> None:
        """Reacciona al cambio del combo 'Motivo No Aplica' para detectar Tanque."""
        self._actualizar_visibilidad_enlaces()

    def _on_tipo_inst_changed(self) -> None:
        """
        Detecta si el tipo de instrumento es 'Báscula tipo Tanque'.
        Fuerza Excentricidad = NO y muestra bloque de enlaces.
        """
        tipo_txt = self._cmb_tipo_inst.currentText()
        es_tanque = "Tanque" in tipo_txt

        if es_tanque:
            self._cmb_aplica_exc.setCurrentText("NO")
            self._cmb_aplica_exc.setEnabled(False)
            try:
                self._cmb_no.setCurrentText("Báscula tipo Tanque")
            except Exception:
                pass
        else:
            self._cmb_aplica_exc.setEnabled(True)

        self._on_aplica_exc_changed()
        self._actualizar_visibilidad_secciones()

    def _actualizar_visibilidad_secciones(self) -> None:
        """
        Decide si mostrar el bloque de Secciones.
        Se activa SOLO cuando el tipo de instrumento es Camionera O la geometría es Camionera,
        y siempre que Aplica Excentricidad = SÍ.
        """
        if not hasattr(self, '_wgt_secciones'):
            return
        tipo_txt = self._cmb_tipo_inst.currentText().lower() if hasattr(self, '_cmb_tipo_inst') else ""
        geo_txt = self._cmb_geo.currentText().lower() if hasattr(self, '_cmb_geo') else ""
        aplica_exc = self._cmb_aplica_exc.currentText() == "SÍ" if hasattr(self, '_cmb_aplica_exc') else False
        
        es_camionera = "camionera" in tipo_txt or "puente" in tipo_txt or "camionera" in geo_txt
        self._wgt_secciones.setVisible(es_camionera and aplica_exc)

    def _actualizar_visibilidad_enlaces(self) -> None:
        """
        Decide si mostrar el bloque de Calibración por Enlaces de Sustitución.
        Se activa cuando el tipo de instrumento O el motivo de no-excentricidad es 'Tanque'.
        Guard: si el widget aún no fue construido (llamada temprana del constructor), no hace nada.
        """
        if not hasattr(self, '_wgt_enlaces'):
            return   # el widget aún no existe; la llamada inicial de _on_tipo_inst_changed() lo cubrirá
        tipo_txt   = self._cmb_tipo_inst.currentText() if hasattr(self, '_cmb_tipo_inst') else ""
        motivo_txt = self._cmb_no.currentText()        if hasattr(self, '_cmb_no')        else ""
        es_tanque  = ("Tanque" in tipo_txt) or ("Tanque" in motivo_txt and
                      self._cmb_aplica_exc.currentText() == "NO")
        self._wgt_enlaces.setVisible(es_tanque)
        # Si se oculta, restablecer valores por defecto
        if not es_tanque:
            if hasattr(self, '_cmb_usa_enlaces'):
                self._cmb_usa_enlaces.setCurrentText("SÍ")


    def _on_usa_enlaces_changed(self) -> None:
        """Muestra / oculta el spinbox de N° de enlaces según el combo SÍ/NO."""
        usa = self._cmb_usa_enlaces.currentText() == "SÍ"
        self._wgt_spin_enlaces.setVisible(usa)

    def set_calibracion_visible(self, visible: bool) -> None:
        """
        Muestra u oculta los campos de Calibración (Inicial + Número CCA)
        según si el tipo de servicio activo requiere calibración.
        Cuando se ocultan, los valores se limpian para evitar contaminación en el PDF.
        """
        try:
            self._widget_calibracion.setVisible(visible)
            if not visible:
                # Limpiar valores para no contaminar el dict de datos
                if hasattr(self, '_cmb_inicial'):
                    self._cmb_inicial.setCurrentIndex(0)   # "Ninguna"
                if hasattr(self, '_inp_cca'):
                    self._inp_cca.clear()
        except Exception:
            pass

    def set_inspeccion_visible(self, visible: bool) -> None:
        """
        Muestra u oculta los campos de Holograma (Anterior + Actualizado) y DVE
        según si el tipo de servicio activo contiene 'inspección'.
        - Hologramas: opcionales; si se dejan en blanco el PDF los marca en rojo.
        - DVE: metrológicamente solo aplica con inspección oficial.
        """
        try:
            if hasattr(self, '_wgt_hologramas'):
                self._wgt_hologramas.setVisible(visible)
        except Exception:
            pass
        # DVE: mostrar solo con inspección; limpiar al ocultar
        self.set_dve_visible(visible)

    def set_dve_visible(self, visible: bool) -> None:
        """Muestra u oculta el campo DVE. Al ocultarlo limpia el valor capturado."""
        try:
            if hasattr(self, '_wgt_dve'):
                self._wgt_dve.setVisible(visible)
                if not visible and hasattr(self, '_inp_dve'):
                    self._inp_dve.clear()
        except Exception:
            pass

    def _toggle(self) -> None:
        self._expanded = not self._expanded
        self._fields_widget.setVisible(self._expanded)
        self._btn_toggle.setText("−" if self._expanded else "+")

    def get_data(self) -> dict:
        """
        Retorna los datos del equipo de forma 100% blindada.
        Cada acceso a widget usa hasattr() para evitar AttributeError.
        Campos en blanco retornan cadena vacía (nunca None para str).
        """
        def _v(attr: str, default: str = "") -> str:
            """Extrae texto de un QLineEdit por nombre de atributo, con fallback."""
            try:
                widget = getattr(self, attr, None)
                if widget is not None and hasattr(widget, "text"):
                    return widget.text().strip()
            except Exception:
                pass
            return default

        def _cmb(attr: str, default: str = "") -> str:
            """Extrae currentText de un QComboBox por nombre de atributo, con fallback."""
            try:
                widget = getattr(self, attr, None)
                if widget is not None and hasattr(widget, "currentText"):
                    return widget.currentText().strip()
            except Exception:
                pass
            return default

        def _spin(attr: str, default: int = 4) -> int:
            """Extrae value de un QSpinBox por nombre de atributo, con fallback."""
            try:
                widget = getattr(self, attr, None)
                if widget is not None and hasattr(widget, "value"):
                    return widget.value()
            except Exception:
                pass
            return default

        # ── Inicial del calibrador ─────────────────────────────────────────────
        ini_raw = _cmb("_cmb_inicial", "Ninguna")
        ini = "" if ini_raw in ("Ninguna", "") else ini_raw

        # ── Aplica Excentricidad ───────────────────────────────────────────────
        aplica_txt = _cmb("_cmb_aplica_exc", "SÍ")
        aplica_exc = aplica_txt in ("SÍ", "SI", "Sí", "Yes", "yes", "true", "True")

        # ── Puntos / Filas de Excentricidad (spinbox dedicado) ────────────────
        puntos_exc = _spin("_spin_filas_exc", 5) if aplica_exc else 5

        # ── Geometría y Secciones ─────────────────────────────────────────────
        geo = None
        secciones = None
        tipo_no = None

        if aplica_exc:
            g = _cmb("_cmb_geo", "Libre")
            if "Cuadrada" in g or "cuadrada" in g:
                geo = "cuadrada"
            elif "Circular" in g or "circular" in g:
                geo = "circular"
            elif "Camionera" in g or "camionera" in g:
                geo = "camionera"
            else:
                geo = None   # Libre → sin dibujo específico
            secciones = _spin("_spin_sec", 4)
        else:
            # Inferir tipo_no_aplica_exc desde el combo o desde el tipo de instrumento
            no_txt = _cmb("_cmb_no", "")
            tipo_inst_txt = _cmb("_cmb_tipo_inst", "")
            if "Tanque" in no_txt or "Tanque" in tipo_inst_txt:
                tipo_no = "tanque"
            elif "Tolva" in no_txt or "Tolva" in tipo_inst_txt:
                tipo_no = "tolva"
            elif "Gancho" in no_txt or "Grúa" in no_txt or "Gancho" in tipo_inst_txt or "Grúa" in tipo_inst_txt:
                tipo_no = "gancho"
            elif "Patín" in no_txt or "Transpaleta" in no_txt or "Patín" in tipo_inst_txt or "Transpaleta" in tipo_inst_txt:
                tipo_no = "patin"
            else:
                tipo_no = "tolva"   # fallback seguro con dibujo

        es_enlace_val = (
            "Tanque" in _cmb("_cmb_tipo_inst", "")
            or ("Tanque" in _cmb("_cmb_no", "") and not aplica_exc)
        ) and _cmb("_cmb_usa_enlaces", "SÍ") == "SÍ"
        
        num_enlace_val = _spin("_spin_enlaces", 8) if es_enlace_val else None

        return {
            # ── Folio Manual ───────────────────────────────────────────────────
            "folio_base":          _v("input_folio_inicial"),
            # ── Campos de equipo ───────────────────────────────────────────────
            "equipo_marca":        _v("_inp_marca")    or None,
            "equipo_modelo":       _v("_inp_modelo")   or None,
            "equipo_ns":           _v("_inp_ns")       or None,
            "equipo_id":           _v("_inp_id")       or None,
            "equipo_alcance":      _v("_inp_alcance")  or None,
            "equipo_division":     _v("_inp_division") or None,
            "equipo_dve":          _v("_inp_dve")      or None,
            "equipo_ubicacion":    _v("_inp_ubicacion") or None,
            # Alias adicionales para compatibilidad con os_pdf_generator
            "marca":               _v("_inp_marca"),
            "modelo":              _v("_inp_modelo"),
            "serie":               _v("_inp_ns"),
            "ns":                  _v("_inp_ns"),
            "id_equipo":           _v("_inp_id"),
            "alcance_max":         _v("_inp_alcance"),
            "div_minima":          _v("_inp_division"),
            "dve":                 _v("_inp_dve"),
            "ubicacion":           _v("_inp_ubicacion"),
            # ── Calibración ────────────────────────────────────────────────────
            "tipo_instrumento":        _cmb("_cmb_tipo_inst", "Báscula de plataforma"),
            "inicial_calibrador":      ini,
            "tipo_calibracion_inicial": ini,
            "inicial":                 ini,
            "numero_cca":              _v("_inp_cca"),
            "cca":                     _v("_inp_cca"),
            # ── Excentricidad ──────────────────────────────────────────────────
            "aplica_excentricidad":    aplica_exc,
            "geometria_plataforma":    geo,
            "tipo_no_aplica_exc":      tipo_no,
            # Spinbox dedicado de filas de excentricidad.
            # Para Camionera, se toma el mayor entre filas y secciones para no recortar.
            "puntos_excentricidad":    puntos_exc,
            "filas_excentricidad":     max(puntos_exc, secciones) if (aplica_exc and secciones) else puntos_exc,
            "num_secciones":           secciones if secciones else puntos_exc,  # alias Camionera
            # ── Enlaces de Sustitución (Báscula tipo Tanque) ───────────────────
            "es_enlace_sustitucion":   es_enlace_val,
            "num_enlaces_sustitucion": num_enlace_val,
            "es_sustitucion":          es_enlace_val,       # Alias pedido
            "num_enlaces":             num_enlace_val,      # Alias pedido
            # ── Puntos de Exactitud por instrumento ────────────────────────────
            "filas_exactitud":         self._spin_pts_exact.value(),
            "puntos_exactitud":        self._spin_pts_exact.value(),
            # ── Hologramas (solo relevante si el servicio contiene 'inspección') ──
            "holograma_anterior":      _v("_inp_holograma_ant"),
            "holograma_actualizado":   _v("_inp_holograma_act"),
        }


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS — tarjetas de selección
# ══════════════════════════════════════════════════════════════════════════════
class SelectCard(QPushButton):
    """
    Tarjeta seleccionable tipo toggle.
    Muestra: ícono + título + descripción corta.
    """
    def __init__(self, icon: str, title: str, desc: str,
                 accent: str = _RED, parent=None):
        super().__init__(parent)
        self._accent = accent
        self._selected = False
        self.setCheckable(True)
        self.setFixedHeight(96)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(16, 12, 16, 12)
        lay.setSpacing(4)

        top = QHBoxLayout()
        top.setSpacing(10)

        lbl_icon = QLabel(icon)
        lbl_icon.setStyleSheet(f"font-size: 22px; background: transparent; color: {accent};")
        lbl_icon.setFixedWidth(30)
        top.addWidget(lbl_icon)

        lbl_title = QLabel(title)
        lbl_title.setStyleSheet(
            f"font-size: 14px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        top.addWidget(lbl_title, stretch=1)
        lay.addLayout(top)

        lbl_desc = QLabel(desc)
        lbl_desc.setWordWrap(True)
        lbl_desc.setStyleSheet(
            f"font-size: 11px; color: {_GRAY}; background: transparent;"
        )
        lay.addWidget(lbl_desc)

        self._apply_style(False)
        self.toggled.connect(self._apply_style)

    def _apply_style(self, checked: bool) -> None:
        if checked:
            self.setStyleSheet(f"""
                QPushButton {{
                    background: rgba({self._rgb()}, 0.08);
                    border: 2px solid {self._accent};
                    border-radius: 12px;
                    text-align: left;
                }}
            """)
        else:
            self.setStyleSheet("""
                QPushButton {
                    background: #FFFFFF;
                    border: 1.5px solid rgba(0,0,0,0.10);
                    border-radius: 12px;
                    text-align: left;
                }
                QPushButton:hover {
                    border-color: rgba(0,0,0,0.18);
                    background: #FAFAFA;
                }
            """)

    def _rgb(self) -> str:
        h = self._accent.lstrip("#")
        return f"{int(h[0:2],16)}, {int(h[2:4],16)}, {int(h[4:6],16)}"


class StepHeader(QWidget):
    """Cabecera de un paso con número, ícono y título."""
    def __init__(self, step: int, icon: str, title: str, parent=None):
        super().__init__(parent)
        self.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)

        badge = QLabel(str(step))
        badge.setFixedSize(26, 26)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(f"""
            background: {_RED}; color: #FFFFFF;
            border-radius: 13px;
            font-size: 12px; font-weight: 700;
        """)
        lay.addWidget(badge)

        lbl = QLabel(f"{icon}  {title}")
        lbl.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        lay.addWidget(lbl)
        lay.addStretch()


def _sep() -> QFrame:
    f = QFrame()
    f.setFrameShape(QFrame.Shape.HLine)
    f.setStyleSheet("background: rgba(0,0,0,0.06); border: none; margin: 2px 0;")
    f.setFixedHeight(1)
    return f


def _section_card() -> tuple[QFrame, QVBoxLayout]:
    card = QFrame()
    card.setStyleSheet("""
        QFrame {
            background: #FFFFFF;
            border: 1px solid rgba(0,0,0,0.07);
            border-radius: 14px;
        }
    """)
    lay = QVBoxLayout(card)
    lay.setContentsMargins(22, 18, 22, 18)
    lay.setSpacing(14)
    return card, lay


def _field_label(text: str, required: bool = False) -> QLabel:
    suffix = "  <span style='color:#E63946'>*</span>" if required else ""
    lbl = QLabel(f"{text}{suffix}")
    lbl.setTextFormat(Qt.TextFormat.RichText)
    lbl.setStyleSheet(
        "font-size: 11px; font-weight: 700; color: #86868B; "
        "letter-spacing: 0.3px; background: transparent;"
    )
    return lbl


def _input_style() -> str:
    return """
        QComboBox, QSpinBox, QDateEdit {
            background: #F8FAFC;
            border: 1.5px solid #D1D5DB;
            border-radius: 8px;
            padding: 7px 12px;
            font-size: 13px;
            color: #1D1D1F;
            min-height: 36px;
        }
        QComboBox:focus, QSpinBox:focus, QDateEdit:focus {
            border-color: #007AFF;
            background: #FFFFFF;
        }
        QComboBox::drop-down { border: none; width: 28px; }
    """


# =============================================================================
# _CatalogLoader — precarga todos los catalogos en un solo viaje a la BD
# =============================================================================
class _CatalogLoader(QThread):
    """
    Worker que carga todos los catalogos relacionales en un solo viaje
    de red a Render, sin bloquear el hilo de interfaz grafica.

    Precarga clave: todas las sucursales de todos los clientes en UN solo
    SELECT, agrupadas en un dict {cliente_id: [(sid, nombre, dir), ...]}.
    Al cambiar el combo de cliente, _on_cliente_changed hace un dict lookup
    instantaneo (0 ms) en lugar de una query de red.
    """

    clientes_ready   = pyqtSignal(list)   # [(id, razon_social), ...]
    sucursales_ready = pyqtSignal(dict)   # {cliente_id: [(sid, nom, dir), ...]}
    tecnicos_ready   = pyqtSignal(list)   # [(id, nombre_completo), ...]
    tipos_srv_ready  = pyqtSignal(list)   # [(id, nombre), ...]
    tipos_inst_ready = pyqtSignal(list)   # [(id, nombre), ...]
    error            = pyqtSignal(str)

    def run(self) -> None:
        if not _HAS_DB or not _db_pool:
            self.error.emit("Sin conexion a BD")
            return
        try:
            conn = _db_pool.get_connection()
            try:
                # Clientes
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id, razon_social FROM cat_clientes "
                        "WHERE activo = TRUE ORDER BY razon_social"
                    )
                    clientes = list(cur.fetchall())
                self.clientes_ready.emit(clientes)

                # Sucursales — UN solo SELECT para todos los clientes
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT cliente_id, id, nombre_sucursal, "
                            "       COALESCE(direccion, '') "
                            "FROM cliente_sucursales "
                            "WHERE activo = TRUE "
                            "ORDER BY cliente_id, nombre_sucursal"
                        )
                        suc_map: dict[int, list] = {}
                        for cid, sid, snom, sdir in cur.fetchall():
                            suc_map.setdefault(cid, []).append(
                                (sid, snom or "", sdir or "")
                            )
                    self.sucursales_ready.emit(suc_map)
                except Exception as exc_s:
                    logger.warning("Sucursales no disponibles: %s", exc_s)
                    self.sucursales_ready.emit({})

                # Tecnicos
                try:
                    from models.catalogo import tecnico_repo as _trepo
                    ops = _trepo.get_operativos()
                    tecnicos = [(r["id"], r["nombre_completo"]) for r in ops]
                except Exception:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT id, nombre_completo FROM cat_tecnicos "
                            "WHERE activo=TRUE ORDER BY nombre_completo"
                        )
                        tecnicos = list(cur.fetchall())
                self.tecnicos_ready.emit(tecnicos)

                # Tipos de Servicio
                try:
                    with conn.cursor() as cur:
                        cur.execute("SELECT id, nombre FROM cat_tipo_servicio ORDER BY id")
                        self.tipos_srv_ready.emit(list(cur.fetchall()))
                except Exception as exc:
                    logger.warning("Tipos servicio error: %s", exc)

                # Tipos de Instrumento
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT id, nombre FROM cat_tipo_instrumento ORDER BY nombre"
                        )
                        self.tipos_inst_ready.emit(list(cur.fetchall()))
                except Exception as exc:
                    logger.warning("Tipos instrumento error: %s", exc)

                conn.commit()
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            logger.error("[CatalogLoader] %s", exc)
            self.error.emit(str(exc))


# ==============================================================================
# WIDGET PRINCIPAL
# ==============================================================================
class BatchGeneratorWidget(QWidget):
    """
    Asistente de generación de formatos en 4 pasos.

    Paso 1 → Modalidad   (Digital | Físico)
    Paso 2 → Documento   (OS | RMA | RE)
    Paso 3 → Parámetros  (Cliente, Técnico, Cantidad, Fecha)
    Paso 4 → Resumen + Acción
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self._modalidad:  str = ""   # "DIGITAL" | "FISICO"
        self._tipo_doc:   str = ""   # "OS" | "RMA" | "RE"
        self._clientes:   list[str] = []
        self._clientes_ids: list[int] = []
        self._tecnicos:   list[tuple[int, str]] = []
        self._folios_preview: list[str] = []
        self._equipo_cards: list = []   # tarjetas de equipo

        self._current_catalog: list[dict] = []   # catálogo de instrumentos activo
        # Diccionario de sucursales precargadas: {cliente_id: [(sid, nom, dir), ...]}
        self._suc_map: dict[int, list] = {}
        self._catalog_loader: Optional[_CatalogLoader] = None

        self._build_ui()
        # Lanzar precarga asíncrona de catálogos (no bloquea la UI)
        QTimer.singleShot(150, self._launch_catalog_loader)

    @property
    def cards_instrumentos(self) -> list:
        """Alias público de _equipo_cards para compatibilidad con la directiva."""
        return self._equipo_cards
    # ══════════════════════════════════════════════════════════════════════════
    # BUILD UI
    # ══════════════════════════════════════════════════════════════════════════
    def _build_ui(self) -> None:
        self.setStyleSheet(f"background: {_BG};")

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Scroll exterior
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("background: transparent; border: none;")
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        inner = QWidget()
        inner.setStyleSheet(f"background: {_BG};")
        self._main_lay = QVBoxLayout(inner)
        self._main_lay.setContentsMargins(28, 24, 28, 40)
        self._main_lay.setSpacing(20)
        scroll.setWidget(inner)
        root.addWidget(scroll)

        # ── Título de página ──────────────────────────────────────────────────
        self._lbl_title = QLabel("🖨️  Asistente de Generación de Formatos")
        self._lbl_title.setStyleSheet(
            f"font-size: 22px; font-weight: 700; color: {_DARK}; "
            f"letter-spacing: -0.4px; background: transparent;"
        )
        self._main_lay.addWidget(self._lbl_title)

        self._lbl_sub = QLabel("Completa los 4 pasos para reservar folios y generar los documentos.")
        self._lbl_sub.setStyleSheet(f"font-size: 12px; color: {_GRAY}; background: transparent;")
        self._main_lay.addWidget(self._lbl_sub)

        # ── PASO 1: Modalidad ─────────────────────────────────────────────────
        self._main_lay.addWidget(self._build_step1())

        # ── PASO 2: Tipo de documento ─────────────────────────────────────────
        self._card_step2, step2_lay = _section_card()
        step2_lay.addWidget(StepHeader(2, "📄", "Tipo de Documento"))
        step2_lay.addWidget(_sep())
        self._card_step2_content = self._build_step2_content()
        step2_lay.addWidget(self._card_step2_content)
        self._main_lay.addWidget(self._card_step2)
        self._card_step2.setEnabled(False)
        self._card_step2.setStyleSheet("""
            QFrame { background: #FAFAFA; border: 1px solid rgba(0,0,0,0.05);
                     border-radius: 14px; }
        """)

        # ── PASO 3: Parámetros ────────────────────────────────────────────────
        self._card_step3, step3_lay = _section_card()
        step3_lay.addWidget(StepHeader(3, "⚙️", "Parámetros del Formato"))
        step3_lay.addWidget(_sep())
        self._card_step3_content = self._build_step3_content()
        step3_lay.addWidget(self._card_step3_content)
        self._main_lay.addWidget(self._card_step3)
        self._card_step3.setEnabled(False)
        self._card_step3.setStyleSheet("""
            QFrame { background: #FAFAFA; border: 1px solid rgba(0,0,0,0.05);
                     border-radius: 14px; }
        """)

        # ── PASO 4: Resumen + acción ──────────────────────────────────────────
        self._card_step4, step4_lay = _section_card()
        step4_lay.addWidget(StepHeader(4, "🚀", "Confirmar y Ejecutar"))
        step4_lay.addWidget(_sep())
        self._step4_content = self._build_step4_content()
        step4_lay.addWidget(self._step4_content)
        self._main_lay.addWidget(self._card_step4)
        self._card_step4.setEnabled(False)
        self._card_step4.setStyleSheet("""
            QFrame { background: #FAFAFA; border: 1px solid rgba(0,0,0,0.05);
                     border-radius: 14px; }
        """)

        self._main_lay.addStretch()

        # ── Barra inferior de acciones ────────────────────────────────────────
        root.addWidget(self._build_action_bar())

    # ── PASO 1 ────────────────────────────────────────────────────────────────
    def _build_step1(self) -> QFrame:
        card, lay = _section_card()
        lay.addWidget(StepHeader(1, "📱", "Modalidad de Trabajo"))
        lay.addWidget(_sep())

        cards_row = QHBoxLayout()
        cards_row.setSpacing(14)

        self._card_digital = SelectCard(
            "📱", "Digital — Tablet",
            "El técnico llena el formato en campo con la app móvil.\n"
            "Firma digital integrada. Sincronización automática.",
            accent=_BLUE,
        )
        self._card_fisico = SelectCard(
            "🖨️", "Físico — Impresión Calca",
            "Genera PDF para papel duplicado carbón.\n"
            "Requiere escaneo posterior del original firmado.",
            accent=_RED,
        )

        # Grupo exclusivo
        self._modal_group = QButtonGroup(self)
        self._modal_group.setExclusive(True)
        self._modal_group.addButton(self._card_digital, 1)
        self._modal_group.addButton(self._card_fisico,  2)

        self._card_digital.toggled.connect(lambda chk: chk and self._on_modalidad("DIGITAL"))
        self._card_fisico.toggled.connect(lambda chk: chk and self._on_modalidad("FISICO"))

        cards_row.addWidget(self._card_digital)
        cards_row.addWidget(self._card_fisico)
        lay.addLayout(cards_row)
        return card

    # ── PASO 2 ────────────────────────────────────────────────────────────────
    def _build_step2_content(self) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        row = QHBoxLayout(w)
        row.setSpacing(14)
        row.setContentsMargins(0, 0, 0, 0)

        self._card_os = SelectCard(
            "📄", "Orden de Servicio (OS)",
            "Calibración, ajuste e inspección de instrumentos.",
            accent=_RED,
        )
        self._card_rma = SelectCard(
            "📋", "Remisión de Material (RMA)",
            "Traslado de equipos o partes para servicio.",
            accent=_BLUE,
        )
        self._card_re = SelectCard(
            "⚖️", "Revisión de Báscula (RE)",
            "Verificación de celdas de carga y básculas.",
            accent="#8B5CF6",
        )
        self._card_lp = SelectCard(
            "📋", "Levantamiento de Proyecto (LP)",
            "Levantamiento técnico de campo y proyectos.",
            accent="#D32F2F",
        )
        self._card_lv = SelectCard(
            "📏", "Levantamiento Metrológico (LV)",
            "Pre-Visita: N básculas, logística de pesas patrón.",
            accent="#E67E22",
        )

        self._doc_group = QButtonGroup(self)
        self._doc_group.setExclusive(True)
        self._doc_group.addButton(self._card_os,  1)
        self._doc_group.addButton(self._card_rma, 2)
        self._doc_group.addButton(self._card_re,  3)
        self._doc_group.addButton(self._card_lp,  4)
        self._doc_group.addButton(self._card_lv,  5)

        self._card_os.toggled.connect(lambda chk: chk and self._on_tipo_doc("OS"))
        self._card_rma.toggled.connect(lambda chk: chk and self._on_tipo_doc("RMA"))
        self._card_re.toggled.connect(lambda chk: chk and self._on_tipo_doc("RE"))
        self._card_lp.toggled.connect(lambda chk: chk and self._on_tipo_doc("LP"))
        self._card_lv.toggled.connect(lambda chk: chk and self._on_tipo_doc("LV"))

        row.addWidget(self._card_os)
        row.addWidget(self._card_rma)
        row.addWidget(self._card_re)
        row.addWidget(self._card_lp)
        row.addWidget(self._card_lv)
        return w

    # ── PASO 3 ────────────────────────────────────────────────────────────────
    def _build_step3_content(self) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        w.setStyleSheet(_input_style() + "QWidget { background: transparent; }")

        grid = QVBoxLayout(w)
        grid.setSpacing(14)
        grid.setContentsMargins(0, 0, 0, 0)

        # Fila 1: Cliente + Sucursal + Técnico
        row1 = QHBoxLayout()
        row1.setSpacing(16)

        col_cliente = QVBoxLayout()
        col_cliente.setSpacing(6)
        col_cliente.addWidget(_field_label("Cliente / Razón Social", required=True))
        self.cmb_cliente = QComboBox()
        self.cmb_cliente.setMinimumWidth(240)
        self.cmb_cliente.setEditable(True)
        self.cmb_cliente.setPlaceholderText("— Selecciona un cliente —")
        self.cmb_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        col_cliente.addWidget(self.cmb_cliente)
        row1.addLayout(col_cliente, stretch=2)

        col_sucursal = QVBoxLayout()
        col_sucursal.setSpacing(6)
        col_sucursal.addWidget(_field_label("Sucursal / Planta", required=True))
        self.cmb_sucursal = QComboBox()
        self.cmb_sucursal.setMinimumWidth(240)
        self.cmb_sucursal.setEditable(False)
        self.cmb_sucursal.setEnabled(False)
        self.cmb_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)
        col_sucursal.addWidget(self.cmb_sucursal)
        row1.addLayout(col_sucursal, stretch=2)

        col_tec = QVBoxLayout()
        col_tec.setSpacing(6)
        col_tec.addWidget(_field_label("Técnico Asignado", required=True))
        self.cmb_tecnico = QComboBox()
        self.cmb_tecnico.setMinimumWidth(200)
        self.cmb_tecnico.setPlaceholderText("— Selecciona técnico —")
        self.cmb_tecnico.currentIndexChanged.connect(self._on_params_changed)
        col_tec.addWidget(self.cmb_tecnico)
        row1.addLayout(col_tec, stretch=2)
        grid.addLayout(row1)

        # Fila 1b: Tipo de Servicio y Tipo de Instrumento
        # Se oculta para documentos RE (no aplica)
        self._widget_row_tipo_serv = QWidget()
        _row1b_lay = QHBoxLayout(self._widget_row_tipo_serv)
        _row1b_lay.setContentsMargins(0, 0, 0, 0)
        _row1b_lay.setSpacing(16)

        col_tipo_serv = QVBoxLayout()
        col_tipo_serv.setSpacing(6)
        col_tipo_serv.addWidget(_field_label("Tipo de Servicio", required=True))
        self.cmb_tipo_servicio = QComboBox()
        self.cmb_tipo_servicio.setMinimumWidth(340)
        self.cmb_tipo_servicio.setPlaceholderText("— Selecciona el tipo de servicio —")
        self.cmb_tipo_servicio.currentIndexChanged.connect(self._on_params_changed)
        self.cmb_tipo_servicio.currentIndexChanged.connect(self._on_tipo_servicio_changed)
        col_tipo_serv.addWidget(self.cmb_tipo_servicio)
        _row1b_lay.addLayout(col_tipo_serv, stretch=2)

        grid.addWidget(self._widget_row_tipo_serv)

        # Fila Extra: Excentricidad (se oculta para RE)
        self._widget_row_exc = QWidget()
        _row_exc_lay = QHBoxLayout(self._widget_row_exc)
        _row_exc_lay.setContentsMargins(0, 0, 0, 0)
        _row_exc_lay.setSpacing(16)



        col_exactitud = QVBoxLayout()
        col_exactitud.setSpacing(6)
        col_exactitud.addWidget(_field_label("Puntos de Exactitud"))
        self.cmb_puntos_exactitud = QComboBox()
        self.cmb_puntos_exactitud.addItems(["3", "4", "5", "6", "7", "8", "9", "10"])
        self.cmb_puntos_exactitud.setCurrentText("5")
        self.cmb_puntos_exactitud.currentIndexChanged.connect(self._on_params_changed)
        # Propagar valor global a todas las tarjetas al cambiar
        self.cmb_puntos_exactitud.currentIndexChanged.connect(self._on_puntos_exactitud_changed)
        self.cmb_puntos_exactitud.setFixedWidth(100)
        col_exactitud.addWidget(self.cmb_puntos_exactitud)
        _row_exc_lay.addLayout(col_exactitud)

        col_puntos_apoyo = QVBoxLayout()
        col_puntos_apoyo.setSpacing(6)
        col_puntos_apoyo.addWidget(_field_label("Puntos de Apoyo"))
        self.cmb_puntos_apoyo = QComboBox()
        self.cmb_puntos_apoyo.addItems(["", "3", "4", "5", "6", "8", "Libre"])
        self.cmb_puntos_apoyo.setCurrentIndex(0)  # vacío por defecto
        self.cmb_puntos_apoyo.setFixedWidth(100)
        col_puntos_apoyo.addWidget(self.cmb_puntos_apoyo)
        _row_exc_lay.addLayout(col_puntos_apoyo)

        _row_exc_lay.addStretch()
        grid.addWidget(self._widget_row_exc)



        # ── Bloque condicional: Tipo de Estructura para Revisión de Báscula (RE) ────
        self._frame_re_estructura = QFrame()
        self._frame_re_estructura.setObjectName("frame_re_estructura")
        self._frame_re_estructura.setStyleSheet("""
            QFrame#frame_re_estructura {
                background: rgba(139,92,246,0.06);
                border: 1.5px solid rgba(139,92,246,0.25);
                border-radius: 10px;
            }
        """)
        _re_vlay = QVBoxLayout(self._frame_re_estructura)
        _re_vlay.setContentsMargins(14, 10, 14, 10)
        _re_vlay.setSpacing(8)

        _lbl_re_sec = QLabel("⚖️  Información de Estructura  (Revisión de Báscula)")
        _lbl_re_sec.setStyleSheet(
            "font-size: 12px; font-weight: 700; color: #8B5CF6; background: transparent;"
        )
        _re_vlay.addWidget(_lbl_re_sec)

        _re_row = QHBoxLayout()
        _re_row.setSpacing(16)

        _col_estr = QVBoxLayout()
        _col_estr.setSpacing(6)
        _col_estr.addWidget(_field_label("Tipo de Estructura"))
        self.cmb_tipo_estructura = QComboBox()
        self.cmb_tipo_estructura.addItems(["Camionera", "Plataforma", "Tolva / Tanque"])
        self.cmb_tipo_estructura.setFixedWidth(200)
        self.cmb_tipo_estructura.currentIndexChanged.connect(self._on_tipo_estructura_changed)
        self.cmb_tipo_estructura.currentIndexChanged.connect(self._on_params_changed)
        _col_estr.addWidget(self.cmb_tipo_estructura)
        _re_row.addLayout(_col_estr)

        # Sub-bloque Camionera: Instalación + N° Secciones (se oculta para otros tipos)
        self._widget_camionera_extra = QWidget()
        self._widget_camionera_extra.setStyleSheet("background: transparent;")
        _cam_lay = QHBoxLayout(self._widget_camionera_extra)
        _cam_lay.setContentsMargins(0, 0, 0, 0)
        _cam_lay.setSpacing(16)

        _col_inst = QVBoxLayout()
        _col_inst.setSpacing(6)
        _col_inst.addWidget(_field_label("Instalación"))
        self.cmb_instalacion_camionera = QComboBox()
        self.cmb_instalacion_camionera.addItems(["Rampa", "Fosa"])
        self.cmb_instalacion_camionera.setFixedWidth(140)
        self.cmb_instalacion_camionera.currentIndexChanged.connect(self._on_params_changed)
        _col_inst.addWidget(self.cmb_instalacion_camionera)
        _cam_lay.addLayout(_col_inst)

        _col_secc = QVBoxLayout()
        _col_secc.setSpacing(6)
        _col_secc.addWidget(_field_label("N° de Secciones"))
        self.spn_secciones_camionera = QSpinBox()
        self.spn_secciones_camionera.setRange(2, 5)
        self.spn_secciones_camionera.setValue(2)
        self.spn_secciones_camionera.setSuffix("  secc.")
        self.spn_secciones_camionera.setFixedWidth(120)
        self.spn_secciones_camionera.valueChanged.connect(self._on_params_changed)
        _col_secc.addWidget(self.spn_secciones_camionera)
        _cam_lay.addLayout(_col_secc)

        _re_row.addWidget(self._widget_camionera_extra)
        _re_row.addStretch()
        _re_vlay.addLayout(_re_row)

        # ── Ubicación del Indicador ──────────────────────────────────────────────
        _ub_row = QHBoxLayout()
        _ub_row.setSpacing(16)
        _col_ub = QVBoxLayout(); _col_ub.setSpacing(6)
        _col_ub.addWidget(_field_label("Ubicación del Indicador"))
        self.cmb_ubicacion_indicador = QComboBox()
        self.cmb_ubicacion_indicador.addItems([
            "Manual (Dibujo del Técnico)",
            "Derecha",
            "Izquierda",
            "Centro / Superior",
        ])
        self.cmb_ubicacion_indicador.setFixedWidth(220)
        self.cmb_ubicacion_indicador.setToolTip(
            "Manual: deja el espacio en blanco para que el técnico dibuje.\n"
            "Derecha / Izquierda / Centro: imprime la caja INDICADOR en el PDF."
        )
        self.cmb_ubicacion_indicador.currentIndexChanged.connect(self._on_params_changed)
        _col_ub.addWidget(self.cmb_ubicacion_indicador)
        _ub_row.addLayout(_col_ub)
        _ub_row.addStretch()
        _re_vlay.addLayout(_ub_row)

        # ── Sub-bloque 2: Indicador e Instrumento ────────────────────────────────
        _lbl_sep2 = QLabel("📡  Indicador e Instrumento")
        _lbl_sep2.setStyleSheet(
            "font-size: 11px; font-weight: 600; color: #7C3AED; "
            "border-top: 1px solid rgba(139,92,246,0.25); "
            "padding-top: 6px; background: transparent;"
        )
        _re_vlay.addWidget(_lbl_sep2)

        _ind_row1 = QHBoxLayout(); _ind_row1.setSpacing(12)
        for _attr, _lbl, _w in [
            ("le_ind_marca",  "Marca Indicador",  150),
            ("le_ind_modelo", "Modelo Indicador", 170),
            ("le_ind_serie",  "N° de Serie",      130),
            ("le_ind_id",     "ID Indicador",     120),
        ]:
            _cv = QVBoxLayout(); _cv.setSpacing(4)
            _cv.addWidget(_field_label(_lbl))
            _le = QLineEdit(); _le.setPlaceholderText("—"); _le.setFixedWidth(_w)
            setattr(self, _attr, _le)
            _cv.addWidget(_le); _ind_row1.addLayout(_cv)
        _ind_row1.addStretch()
        _re_vlay.addLayout(_ind_row1)

        _ind_row2 = QHBoxLayout(); _ind_row2.setSpacing(12)
        for _attr, _lbl, _w in [
            ("le_cap_maxima", "Capacidad Máxima",    160),
            ("le_div_minima", "División Mínima (d)", 160),
        ]:
            _cv = QVBoxLayout(); _cv.setSpacing(4)
            _cv.addWidget(_field_label(_lbl))
            _le = QLineEdit(); _le.setPlaceholderText("—"); _le.setFixedWidth(_w)
            setattr(self, _attr, _le)
            _cv.addWidget(_le); _ind_row2.addLayout(_cv)
        _ind_row2.addStretch()
        _re_vlay.addLayout(_ind_row2)

        # ── Sub-bloque 3: Configuración de Celdas de Carga ─────────────────────
        _lbl_sep3 = QLabel("🔋  Celdas de Carga")
        _lbl_sep3.setStyleSheet(
            "font-size: 11px; font-weight: 600; color: #7C3AED; "
            "border-top: 1px solid rgba(139,92,246,0.25); "
            "padding-top: 6px; background: transparent;"
        )
        _re_vlay.addWidget(_lbl_sep3)

        _row_homo = QHBoxLayout(); _row_homo.setSpacing(12)
        _cv_homo = QVBoxLayout(); _cv_homo.setSpacing(4)
        _cv_homo.addWidget(_field_label("¿Todas las celdas son de la misma marca/modelo?"))
        self.cmb_celdas_homogeneas = QComboBox()
        self.cmb_celdas_homogeneas.addItems(["SÍ — Homogéneas", "NO — Mixtas (2 grupos)"])
        self.cmb_celdas_homogeneas.setFixedWidth(240)
        self.cmb_celdas_homogeneas.currentIndexChanged.connect(self._on_celdas_homogeneas_changed)
        _cv_homo.addWidget(self.cmb_celdas_homogeneas)
        _row_homo.addLayout(_cv_homo); _row_homo.addStretch()
        _re_vlay.addLayout(_row_homo)

        # Grupo A — siempre visible
        _lbl_ga = QLabel("Grupo A — Celdas")
        _lbl_ga.setStyleSheet(
            "font-size: 10px; font-weight: 700; color: #6D28D9; background: transparent;"
        )
        _re_vlay.addWidget(_lbl_ga)
        _row_ga = QHBoxLayout(); _row_ga.setSpacing(12)
        for _attr, _lbl, _w in [
            ("le_celda_a_marca",     "Marca",     130),
            ("le_celda_a_modelo",    "Modelo",    170),
            ("le_celda_a_capacidad", "Capacidad", 120),
        ]:
            _cv = QVBoxLayout(); _cv.setSpacing(4)
            _cv.addWidget(_field_label(_lbl))
            _le = QLineEdit(); _le.setPlaceholderText("—"); _le.setFixedWidth(_w)
            setattr(self, _attr, _le); _cv.addWidget(_le); _row_ga.addLayout(_cv)
        _cv_cnt_a = QVBoxLayout(); _cv_cnt_a.setSpacing(4)
        _cv_cnt_a.addWidget(_field_label("Cantidad"))
        self.spn_celda_a_cantidad = QSpinBox()
        self.spn_celda_a_cantidad.setRange(1, 20); self.spn_celda_a_cantidad.setValue(4)
        self.spn_celda_a_cantidad.setFixedWidth(90)
        _cv_cnt_a.addWidget(self.spn_celda_a_cantidad); _row_ga.addLayout(_cv_cnt_a)
        _row_ga.addStretch(); _re_vlay.addLayout(_row_ga)

        # Grupo B — visible solo si mixtas
        self._widget_grupo_b = QWidget()
        self._widget_grupo_b.setStyleSheet("background: transparent;")
        _gb_vlay = QVBoxLayout(self._widget_grupo_b)
        _gb_vlay.setContentsMargins(0, 0, 0, 0); _gb_vlay.setSpacing(4)
        _lbl_gb = QLabel("Grupo B — Celdas (Mixtas)")
        _lbl_gb.setStyleSheet(
            "font-size: 10px; font-weight: 700; color: #DC2626; background: transparent;"
        )
        _gb_vlay.addWidget(_lbl_gb)
        _row_gb = QHBoxLayout(); _row_gb.setSpacing(12)
        for _attr, _lbl, _w in [
            ("le_celda_b_marca",     "Marca",     130),
            ("le_celda_b_modelo",    "Modelo",    170),
            ("le_celda_b_capacidad", "Capacidad", 120),
        ]:
            _cv = QVBoxLayout(); _cv.setSpacing(4)
            _cv.addWidget(_field_label(_lbl))
            _le = QLineEdit(); _le.setPlaceholderText("—"); _le.setFixedWidth(_w)
            setattr(self, _attr, _le); _cv.addWidget(_le); _row_gb.addLayout(_cv)
        _cv_cnt_b = QVBoxLayout(); _cv_cnt_b.setSpacing(4)
        _cv_cnt_b.addWidget(_field_label("Cantidad"))
        self.spn_celda_b_cantidad = QSpinBox()
        self.spn_celda_b_cantidad.setRange(1, 20); self.spn_celda_b_cantidad.setValue(2)
        self.spn_celda_b_cantidad.setFixedWidth(90)
        _cv_cnt_b.addWidget(self.spn_celda_b_cantidad); _row_gb.addLayout(_cv_cnt_b)
        _row_gb.addStretch(); _gb_vlay.addLayout(_row_gb)
        _re_vlay.addWidget(self._widget_grupo_b)
        self._widget_grupo_b.setVisible(False)

        grid.addWidget(self._frame_re_estructura)
        self._frame_re_estructura.setVisible(False)

        # Fila 2: Cantidad + Fecha
        row2 = QHBoxLayout()
        row2.setSpacing(16)

        col_cant = QVBoxLayout()
        col_cant.setSpacing(6)
        col_cant.addWidget(_field_label("Cantidad de Formatos", required=True))
        self.spn_cantidad = QSpinBox()
        self.spn_cantidad.setRange(1, 50)
        self.spn_cantidad.setValue(1)
        self.spn_cantidad.setSuffix("  formato(s)")
        self.spn_cantidad.setFixedWidth(180)
        self.spn_cantidad.valueChanged.connect(self._on_params_changed)
        # Actualizar el rango de folios en tiempo real al cambiar la cantidad
        self.spn_cantidad.valueChanged.connect(self._actualizar_resumen)
        col_cant.addWidget(self.spn_cantidad)
        row2.addLayout(col_cant)

        col_fecha = QVBoxLayout()
        col_fecha.setSpacing(6)
        col_fecha.addWidget(_field_label("Fecha de los Formatos", required=True))
        self.dte_fecha = QDateEdit()
        self.dte_fecha.setCalendarPopup(True)
        self.dte_fecha.setDate(QDate.currentDate())
        self.dte_fecha.setDisplayFormat("dd / MM / yyyy")
        self.dte_fecha.setFixedWidth(180)
        self.dte_fecha.dateChanged.connect(self._on_params_changed)
        # ── Estilo del QCalendarWidget (tema claro institucional) ──
        self.dte_fecha.calendarWidget().setStyleSheet("""
            QCalendarWidget QWidget {
                background-color: #FFFFFF;
                color: #1D1D1F;
                font-size: 12px;
            }
            /* Cabecera mes/año y botones de navegación */
            QCalendarWidget QWidget#qt_calendar_navigationbar {
                background-color: #E63946;
                border-radius: 6px 6px 0 0;
                padding: 4px;
            }
            QCalendarWidget QToolButton {
                color: #FFFFFF;
                background: transparent;
                border: none;
                font-size: 13px;
                font-weight: 700;
                padding: 4px 8px;
            }
            QCalendarWidget QToolButton:hover {
                background: rgba(255,255,255,0.20);
                border-radius: 4px;
            }
            QCalendarWidget QMenu {
                background: #FFFFFF;
                color: #1D1D1F;
                border: 1px solid #D1D5DB;
                border-radius: 6px;
            }
            QCalendarWidget QSpinBox {
                color: #FFFFFF;
                background: transparent;
                border: none;
                font-size: 13px;
                font-weight: 700;
            }
            QCalendarWidget QSpinBox::up-button,
            QCalendarWidget QSpinBox::down-button { width: 0; }
            /* Cabecera de días (L M Mi J V S D) */
            QCalendarWidget QHeaderView::section {
                background-color: #F5F5F7;
                color: #86868B;
                font-size: 10px;
                font-weight: 700;
                letter-spacing: 0.5px;
                border: none;
                padding: 4px 0;
            }
            /* Días del mes */
            QCalendarWidget QAbstractItemView {
                background-color: #FFFFFF;
                color: #1D1D1F;
                selection-background-color: #E63946;
                selection-color: #FFFFFF;
                outline: none;
                border: none;
                gridline-color: #F0F0F0;
            }
            QCalendarWidget QAbstractItemView:enabled {
                color: #1D1D1F;
            }
            QCalendarWidget QAbstractItemView:disabled {
                color: #C7C7CC;
            }
        """)
        col_fecha.addWidget(self.dte_fecha)
        row2.addLayout(col_fecha)

        row2.addStretch()
        grid.addLayout(row2)

        # Fila 3: Observaciones del Servicio
        col_obs = QVBoxLayout()
        col_obs.setSpacing(6)

        obs_header = QHBoxLayout()
        obs_header.addWidget(_field_label("Observaciones del Servicio"))
        lbl_obs_hint = QLabel("(opcional — visible en app del técnico y en BD)")
        lbl_obs_hint.setStyleSheet(
            f"font-size: 10px; color: {_GRAY}; background: transparent;"
        )
        obs_header.addWidget(lbl_obs_hint)
        obs_header.addStretch()
        col_obs.addLayout(obs_header)

        self.txt_observaciones = QTextEdit()
        self.txt_observaciones.setPlaceholderText(
            "Ej: Se reemplaza el 1100a por otro tanque y se recalibran celdas de carga. "
            "Falla en celda Nº3 — pendiente revisión. Equipo requiere limpieza de display."
        )
        self.txt_observaciones.setMinimumHeight(80)
        self.txt_observaciones.setMaximumHeight(120)
        self.txt_observaciones.setStyleSheet("""
            QTextEdit {
                background: #FFFFFF;
                border: 1.5px solid #D1D5DB;
                border-radius: 8px;
                padding: 8px 12px;
                font-size: 13px;
                color: #1D1D1F;
            }
            QTextEdit:focus {
                border-color: #007AFF;
                background: #FFFFFF;
            }
        """)
        col_obs.addWidget(self.txt_observaciones)
        grid.addLayout(col_obs)

        # ── Sección de equipos por lote (se oculta para RE) ──────────────────
        # Envuelta en QWidget para poder ocultarla cuando tipo_doc == "RE"
        self._widget_equipos_section = QWidget()
        self._widget_equipos_section.setStyleSheet("background: transparent;")
        _eq_vlay = QVBoxLayout(self._widget_equipos_section)
        _eq_vlay.setContentsMargins(0, 0, 0, 0)
        _eq_vlay.setSpacing(10)

        equipo_header = QHBoxLayout()
        lbl_equipo_sec = _field_label("Datos del Instrumento por Equipo")
        equipo_header.addWidget(lbl_equipo_sec)
        lbl_equipo_hint = QLabel("(todos los campos son opcionales — el técnico puede completarlos en campo)")
        lbl_equipo_hint.setStyleSheet(f"font-size: 10px; color: {_GRAY}; background: transparent;")
        equipo_header.addWidget(lbl_equipo_hint)
        equipo_header.addStretch()
        _eq_vlay.addLayout(equipo_header)

        # Contenedor dinámico de tarjetas de equipo
        self._equipos_container = QVBoxLayout()
        self._equipos_container.setSpacing(10)
        self._equipos_container.setContentsMargins(0, 0, 0, 0)
        _eq_vlay.addLayout(self._equipos_container)
        grid.addWidget(self._widget_equipos_section)

        # Inicializar con 1 tarjeta de equipo
        self._update_equipos_section(1)

        # Conectar cambio de cantidad → actualizar tarjetas
        self.spn_cantidad.valueChanged.connect(self._update_equipos_section)

        # ── Bloque exclusivo RMA: Tabla de ítems (Refacciones / Materiales) ────────
        self._frame_rma_items = QFrame()
        self._frame_rma_items.setObjectName("frame_rma_items")
        self._frame_rma_items.setStyleSheet("""
            QFrame#frame_rma_items {
                background: rgba(37,99,235,0.04);
                border: 1.5px solid rgba(37,99,235,0.22);
                border-radius: 10px;
            }
        """)
        _rma_vlay = QVBoxLayout(self._frame_rma_items)
        _rma_vlay.setContentsMargins(14, 10, 14, 10)
        _rma_vlay.setSpacing(10)

        _lbl_rma_sec = QLabel("📦  Partidas / Refacciones a Entregar")
        _lbl_rma_sec.setStyleSheet(
            "font-size: 12px; font-weight: 700; color: #1D4ED8; background: transparent;"
        )
        _rma_vlay.addWidget(_lbl_rma_sec)

        # Cabecera de la tabla de ítems
        _rma_hdr = QWidget()
        _rma_hdr.setStyleSheet("background: #1C1C1C; border-radius: 6px;")
        _rma_hdr_lay = QHBoxLayout(_rma_hdr)
        _rma_hdr_lay.setContentsMargins(8, 6, 8, 6)
        _rma_hdr_lay.setSpacing(0)
        for _col_lbl, _col_stretch in [
            ("CANTIDAD", 1), ("N° DE PARTE", 2),
            ("DESCRIPCIÓN", 4), ("N° DE SERIE", 2),
        ]:
            _h = QLabel(_col_lbl)
            _h.setStyleSheet(
                "color: #FFFFFF; font-size: 10px; font-weight: 700; background: transparent;"
            )
            _h.setAlignment(Qt.AlignmentFlag.AlignCenter)
            _rma_hdr_lay.addWidget(_h, stretch=_col_stretch)
        _rma_vlay.addWidget(_rma_hdr)

        # Contenedor dinámico de filas de ítems
        self._rma_items_container = QVBoxLayout()
        self._rma_items_container.setSpacing(4)
        self._rma_items_container.setContentsMargins(0, 0, 0, 0)
        _rma_vlay.addLayout(self._rma_items_container)
        self._rma_item_rows: list[dict] = []   # lista de dicts con los QLineEdit de cada fila

        # Botón agregar fila
        _btn_add_item = QPushButton("➕  Agregar Refacción")
        _btn_add_item.setFixedHeight(32)
        _btn_add_item.setStyleSheet("""
            QPushButton {
                background: transparent;
                color: #1D4ED8;
                font-size: 12px;
                font-weight: 600;
                border: 1.5px dashed #93C5FD;
                border-radius: 6px;
                padding: 0 14px;
            }
            QPushButton:hover { background: rgba(37,99,235,0.06); }
        """)
        _btn_add_item.clicked.connect(self._rma_add_item_row)
        _rma_vlay.addWidget(_btn_add_item)

        grid.addWidget(self._frame_rma_items)
        self._frame_rma_items.setVisible(False)

        # Agregar 3 filas iniciales RMA (visibles solo cuando RMA esté activo)
        for _ in range(3):
            self._rma_add_item_row()

        # ── Bloque exclusivo LV: N Básculas + Logística de Pesas Patrón ─────────────
        self._frame_lv_basculas = QFrame()
        self._frame_lv_basculas.setObjectName("frame_lv_basculas")
        self._frame_lv_basculas.setStyleSheet("""
            QFrame#frame_lv_basculas {
                background: rgba(230,126,34,0.05);
                border: 1.5px solid rgba(230,126,34,0.35);
                border-radius: 12px;
            }
        """)
        _lv_vlay = QVBoxLayout(self._frame_lv_basculas)
        _lv_vlay.setContentsMargins(16, 12, 16, 12)
        _lv_vlay.setSpacing(10)

        _lbl_lv_title = QLabel("\U0001f4cf  B\u00e1sculas e Instrumentos a Levantar")
        _lbl_lv_title.setStyleSheet(
            "font-size: 13px; font-weight: 700; color: #C0500A; background: transparent;"
        )
        _lv_vlay.addWidget(_lbl_lv_title)

        # Fila de control: spin + botón agregar
        _lv_ctrl = QHBoxLayout()
        _lv_ctrl.setSpacing(12)
        _lbl_cant_basc = QLabel("Cantidad de B\u00e1sculas a Levantar:")
        _lbl_cant_basc.setStyleSheet("font-size: 12px; color: #7C3F00; background: transparent;")
        _lv_ctrl.addWidget(_lbl_cant_basc)
        self.spn_lv_basculas = QSpinBox()
        self.spn_lv_basculas.setRange(1, 20)
        self.spn_lv_basculas.setValue(1)
        self.spn_lv_basculas.setFixedWidth(90)
        self.spn_lv_basculas.setToolTip("N\u00famero de b\u00e1sculas o instrumentos a levantar en este pre-visita")
        _lv_ctrl.addWidget(self.spn_lv_basculas)
        _btn_add_basc = QPushButton("\u2795  Agregar B\u00e1scula")
        _btn_add_basc.setFixedHeight(30)
        _btn_add_basc.setStyleSheet("""
            QPushButton {
                background: transparent;
                color: #C0500A;
                font-size: 11px; font-weight: 600;
                border: 1.5px dashed rgba(230,126,34,0.7);
                border-radius: 6px;
                padding: 0 12px;
            }
            QPushButton:hover { background: rgba(230,126,34,0.08); }
        """)
        _btn_add_basc.clicked.connect(self._lv_add_bascula_row)
        _lv_ctrl.addWidget(_btn_add_basc)
        _lv_ctrl.addStretch()
        _lv_vlay.addLayout(_lv_ctrl)

        # Cabecera de tabla de básculas
        _lv_hdr = QWidget()
        _lv_hdr.setStyleSheet("background: #2C1810; border-radius: 6px;")
        _lv_hdr_lay = QHBoxLayout(_lv_hdr)
        _lv_hdr_lay.setContentsMargins(8, 5, 8, 5)
        _lv_hdr_lay.setSpacing(0)
        for _htxt, _hstretch in [
            ("Tag / ID", 1), ("Tipo de Instrumento", 2),
            ("Marca", 1), ("Modelo", 1),
            ("N\u00b0 de Serie", 1), ("Cap. M\u00e1x.", 1),
            ("Div. M\u00edn.", 1), ("Ubicaci\u00f3n en Planta", 2),
        ]:
            _hl = QLabel(_htxt)
            _hl.setStyleSheet(
                "color: #FED7AA; font-size: 9px; font-weight: 700; background: transparent;"
            )
            _hl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            _lv_hdr_lay.addWidget(_hl, stretch=_hstretch)
        _lv_vlay.addWidget(_lv_hdr)

        # Contenedor dinámico de filas de básculas
        self._lv_basculas_container = QVBoxLayout()
        self._lv_basculas_container.setSpacing(4)
        self._lv_basculas_container.setContentsMargins(0, 0, 0, 0)
        _lv_vlay.addLayout(self._lv_basculas_container)
        self._lv_bascula_rows: list[dict] = []

        # Agregar 1 fila inicial
        self._lv_add_bascula_row()
        # Conectar spinner para sincronizar filas
        self.spn_lv_basculas.valueChanged.connect(self._lv_sync_bascula_rows)

        # ── Sección Logística de Pesas Patrón ────────────────────────────────────
        _sep = QFrame()
        _sep.setFrameShape(QFrame.Shape.HLine)
        _sep.setStyleSheet("color: rgba(230,126,34,0.4);")
        _lv_vlay.addWidget(_sep)

        _lbl_log = QLabel("\U0001f4e6  Log\u00edstica de Pesas Patr\u00f3n y Maniobras")
        _lbl_log.setStyleSheet(
            "font-size: 12px; font-weight: 700; color: #C0500A; background: transparent;"
        )
        _lv_vlay.addWidget(_lbl_log)

        _log_row = QHBoxLayout()
        _log_row.setSpacing(12)

        _col_pesas = QVBoxLayout(); _col_pesas.setSpacing(4)
        _lbl_pesas = QLabel("Pesas Patr\u00f3n a Llevar (cantidad / tipo):")
        _lbl_pesas.setStyleSheet("font-size: 11px; font-weight: 600; color: #7C3F00; background: transparent;")
        _col_pesas.addWidget(_lbl_pesas)
        self.txt_lv_pesas = QTextEdit()
        self.txt_lv_pesas.setPlaceholderText(
            "Ej: 2 masas de 500 kg OIML F2, 4 masas de 100 kg, \n"
            "Barra de 2 ton\u2026"
        )
        self.txt_lv_pesas.setMinimumHeight(70)
        self.txt_lv_pesas.setMaximumHeight(100)
        self.txt_lv_pesas.setStyleSheet("""
            QTextEdit {
                background: #FFFBF5;
                border: 1.5px solid rgba(230,126,34,0.5);
                border-radius: 7px;
                padding: 6px 10px;
                font-size: 12px; color: #1D1D1F;
            }
            QTextEdit:focus { border-color: #E67E22; }
        """)
        _col_pesas.addWidget(self.txt_lv_pesas)
        _log_row.addLayout(_col_pesas, stretch=1)

        _col_maniobra = QVBoxLayout(); _col_maniobra.setSpacing(4)
        _lbl_maniobra = QLabel("Acomodo, Maniobras y Condiciones de Montaje:")
        _lbl_maniobra.setStyleSheet("font-size: 11px; font-weight: 600; color: #7C3F00; background: transparent;")
        _col_maniobra.addWidget(_lbl_maniobra)
        self.txt_lv_maniobra = QTextEdit()
        self.txt_lv_maniobra.setPlaceholderText(
            "Ej: Requiere montacargas de 3 ton. Acceso por puerta norte. "
            "Estibado en plataforma del proveedor\u2026"
        )
        self.txt_lv_maniobra.setMinimumHeight(70)
        self.txt_lv_maniobra.setMaximumHeight(100)
        self.txt_lv_maniobra.setStyleSheet("""
            QTextEdit {
                background: #FFFBF5;
                border: 1.5px solid rgba(230,126,34,0.5);
                border-radius: 7px;
                padding: 6px 10px;
                font-size: 12px; color: #1D1D1F;
            }
            QTextEdit:focus { border-color: #E67E22; }
        """)
        _col_maniobra.addWidget(self.txt_lv_maniobra)
        _log_row.addLayout(_col_maniobra, stretch=1)

        _lv_vlay.addLayout(_log_row)
        grid.addWidget(self._frame_lv_basculas)
        self._frame_lv_basculas.setVisible(False)

        return w

    # ── PASO 4 ────────────────────────────────────────────────────────────────
    def _build_step4_content(self) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(w)
        lay.setSpacing(12)
        lay.setContentsMargins(0, 0, 0, 0)

        # Resumen de la solicitud
        self._lbl_resumen = QLabel("")
        self._lbl_resumen.setWordWrap(True)
        self._lbl_resumen.setTextFormat(Qt.TextFormat.RichText)
        self._lbl_resumen.setStyleSheet(
            f"font-size: 13px; color: {_DARK}; background: transparent; line-height: 1.7;"
        )
        lay.addWidget(self._lbl_resumen)

        # Lista de folios y campo editable de folio
        folios_row = QHBoxLayout()
        folios_row.setSpacing(16)
        
        lbl_folio_title = QLabel("Folio Inicial (Consecutivo) *")
        lbl_folio_title.setStyleSheet(f"font-size: 11px; font-weight: 600; color: {_DARK}; background: transparent;")
        folios_row.addWidget(lbl_folio_title)

        self.input_folio_inicial = QLineEdit()
        self.input_folio_inicial.setPlaceholderText("Ej: OS-26-549")
        self.input_folio_inicial.setFixedWidth(160)
        self.input_folio_inicial.setEnabled(True)
        self.input_folio_inicial.setReadOnly(False)
        self.input_folio_inicial.textChanged.connect(self._validar_formulario)
        folios_row.addWidget(self.input_folio_inicial)
        
        self.lbl_folio_preview = QLabel("")
        self.lbl_folio_preview.setStyleSheet(
            f"font-size: 12px; color: {_BLUE}; background: transparent; font-weight: 600;"
        )
        folios_row.addWidget(self.lbl_folio_preview, stretch=1)

        lay.addLayout(folios_row)

        # Indicador de modo
        self._lbl_modo_badge = QLabel("")
        self._lbl_modo_badge.setAlignment(Qt.AlignmentFlag.AlignLeft)
        lay.addWidget(self._lbl_modo_badge)

        return w

    # ── Barra de acción inferior ──────────────────────────────────────────────
    def _build_action_bar(self) -> QWidget:
        bar = QWidget()
        bar.setFixedHeight(60)
        bar.setStyleSheet("""
            QWidget {
                background: #FFFFFF;
                border-top: 1px solid rgba(0,0,0,0.07);
            }
        """)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(28, 0, 28, 0)
        lay.setSpacing(12)

        # Botón reiniciar
        self.btn_reiniciar = QPushButton("↺  Reiniciar")
        self.btn_reiniciar.setFixedHeight(36)
        self.btn_reiniciar.setStyleSheet("""
            QPushButton {
                background: transparent;
                color: #86868B;
                border: 1px solid rgba(0,0,0,0.12);
                border-radius: 8px;
                font-size: 13px;
                padding: 0 16px;
            }
            QPushButton:hover { background: rgba(0,0,0,0.04); color: #1D1D1F; }
        """)
        self.btn_reiniciar.clicked.connect(self._reset)
        lay.addWidget(self.btn_reiniciar)

        lay.addStretch()

        # Progreso (mientras genera)
        self._progress = QProgressBar()
        self._progress.setRange(0, 0)
        self._progress.setFixedWidth(120)
        self._progress.setFixedHeight(4)
        self._progress.setVisible(False)
        self._progress.setStyleSheet("""
            QProgressBar { border: none; border-radius: 2px; background: #E5E5EA; }
            QProgressBar::chunk { background: #E63946; border-radius: 2px; }
        """)
        lay.addWidget(self._progress)

        # Botón de acción principal (cambia según modalidad)
        self.btn_ejecutar = QPushButton("🖨️  Generar e Imprimir PDF")
        self.btn_ejecutar.setFixedHeight(40)
        self.btn_ejecutar.setEnabled(True)
        self.btn_ejecutar.setStyleSheet("""
            QPushButton {
                background-color: #E63946;
                color: #FFFFFF;
                border: none;
                border-radius: 9px;
                font-size: 14px;
                font-weight: 700;
                padding: 0 24px;
            }
            QPushButton:hover   { background-color: #D90429; }
            QPushButton:pressed { background-color: #B70020; }
            QPushButton:disabled {
                background-color: #C7C7CC;
                color: #FFFFFF;
            }
        """)
        self.btn_ejecutar.clicked.connect(self._ejecutar)
        lay.addWidget(self.btn_ejecutar)
        
        # Alias para compatibilidad global y evitar AttributeError
        self._btn_imprimir = self.btn_ejecutar
        self.btn_imprimir = self.btn_ejecutar
        self.btn_generar = self.btn_ejecutar
        self._btn_asignar = self.btn_ejecutar

        # ── Botón Llenar Formulario Digital (solo visible tras asignación DIGITAL) ──
        self.btn_llenar_digital = QPushButton("📝  Llenar Formulario Digital")
        self.btn_llenar_digital.setFixedHeight(40)
        self.btn_llenar_digital.setVisible(False)
        self.btn_llenar_digital.setStyleSheet("""
            QPushButton {
                background-color: #8B5CF6;
                color: #FFFFFF;
                border: none;
                border-radius: 9px;
                font-size: 13px;
                font-weight: 700;
                padding: 0 20px;
            }
            QPushButton:hover   { background-color: #7C3AED; }
            QPushButton:pressed { background-color: #6D28D9; }
        """)
        self.btn_llenar_digital.clicked.connect(self._abrir_formulario_digital)
        lay.addWidget(self.btn_llenar_digital)

        # Guardar referencia al último lote asignado
        self._ultimo_folio_digital: str = ""
        self._ultimo_os_data_digital: dict = {}

        return bar

    # ══════════════════════════════════════════════════════════════════════════
    # CATÁLOGOS
    # ══════════════════════════════════════════════════════════════════════════
    # ══════════════════════════════════════════════════════════════════════════
    # CATÁLOGOS — carga asíncrona en background (sin bloquear la UI)
    # ══════════════════════════════════════════════════════════════════════════

    def _launch_catalog_loader(self) -> None:
        """Lanza _CatalogLoader en background. Los slots reciben los datos al terminar."""
        if self._catalog_loader and self._catalog_loader.isRunning():
            return
        loader = _CatalogLoader(parent=self)
        loader.clientes_ready.connect(self._on_clientes_loaded)
        loader.sucursales_ready.connect(self._on_sucursales_loaded)
        loader.tecnicos_ready.connect(self._on_tecnicos_loaded)
        loader.tipos_srv_ready.connect(self._on_tipos_srv_loaded)
        loader.tipos_inst_ready.connect(self._on_tipos_inst_loaded)
        loader.error.connect(lambda msg: logger.warning("[Catalog] %s", msg))
        self._catalog_loader = loader
        loader.start()

    # ── Slots de resultados — se ejecutan en el HILO PRINCIPAL ───────────────

    @pyqtSlot(list)
    def _on_clientes_loaded(self, clientes: list) -> None:
        self._clientes_ids = [r[0] for r in clientes]
        self._clientes     = [r[1] for r in clientes]
        self.cmb_cliente.blockSignals(True)
        self.cmb_cliente.clear()
        self.cmb_cliente.addItem("— Selecciona un cliente —", None)
        for cid, nombre in clientes:
            self.cmb_cliente.addItem(nombre, cid)
        self.cmb_cliente.blockSignals(False)

    @pyqtSlot(dict)
    def _on_sucursales_loaded(self, suc_map: dict) -> None:
        """Guarda el mapa en memoria — _on_cliente_changed lo usará sin red."""
        self._suc_map = suc_map

    @pyqtSlot(list)
    def _on_tecnicos_loaded(self, tecnicos: list) -> None:
        self._tecnicos = tecnicos
        self.cmb_tecnico.blockSignals(True)
        self.cmb_tecnico.clear()
        self.cmb_tecnico.addItem("— Selecciona técnico —", None)
        for tid, tnom in tecnicos:
            self.cmb_tecnico.addItem(tnom, tid)
        self.cmb_tecnico.blockSignals(False)

    @pyqtSlot(list)
    def _on_tipos_srv_loaded(self, tipos: list) -> None:
        _fallback = [(1,"Ajuste"),(2,"Ajuste e Inspección"),(3,"Ajuste y Calibración"),(4,"Ajuste, Calibración e Inspección")]
        self.cmb_tipo_servicio.blockSignals(True)
        self.cmb_tipo_servicio.clear()
        self.cmb_tipo_servicio.addItem("— Selecciona el tipo de servicio —", None)
        for tid, tnombre in (tipos or _fallback):
            self.cmb_tipo_servicio.addItem(tnombre, tid)
        self.cmb_tipo_servicio.blockSignals(False)

    @pyqtSlot(list)
    def _on_tipos_inst_loaded(self, tipos: list) -> None:
        if not hasattr(self, "cmb_tipo_instrumento"):
            return
        self.cmb_tipo_instrumento.blockSignals(True)
        self.cmb_tipo_instrumento.clear()
        self.cmb_tipo_instrumento.addItem("— Selecciona instrumento —", None)
        for tid, tnombre in tipos:
            self.cmb_tipo_instrumento.addItem(tnombre, tid)
        self.cmb_tipo_instrumento.blockSignals(False)

    def _load_catalogs(self) -> None:
        """Compatibilidad: redirige a la carga asíncrona."""
        self._launch_catalog_loader()

    def _on_params_changed(self, *args, **kwargs) -> None:
        """Maneja las actualizaciones visuales y cálculos cuando cambian los parámetros del formato."""
        try:
            if hasattr(self, '_actualizar_visibilidad_campos'):
                self._actualizar_visibilidad_campos()
            elif hasattr(self, 'actualizar_ui'):
                self.actualizar_ui()
        except Exception:
            pass

        valido = True
        if hasattr(self, 'cmb_cliente') and (self.cmb_cliente.currentText().strip() == "" or "Selecciona" in self.cmb_cliente.currentText()):
            valido = False
        if hasattr(self, 'cmb_tecnico') and (self.cmb_tecnico.currentText().strip() == "" or "Selecciona" in self.cmb_tecnico.currentText()):
            valido = False
        if hasattr(self, '_tipo_doc') and self._tipo_doc == "OS" and hasattr(self, 'cmb_tipo_servicio') and (self.cmb_tipo_servicio.currentText().strip() == "" or "Selecciona" in self.cmb_tipo_servicio.currentText()):
            valido = False
        if hasattr(self, 'input_folio_inicial') and self.input_folio_inicial.text().strip() == "":
            valido = False
        if hasattr(self, 'btn_ejecutar'):
            self.btn_ejecutar.setEnabled(valido)

    on_params_changed = _on_params_changed

    # ══════════════════════════════════════════════════════════════════════════
    # HANDLERS DE SELECCIÓN
    # ══════════════════════════════════════════════════════════════════════════
    def _on_cliente_changed(self, index=0):
        """
        Llena el combo de Sucursal/Planta INSTANTANEAMENTE desde el diccionario
        en memoria (_suc_map). CERO viajes de red — O(1) dict lookup.
        """
        if not hasattr(self, 'cmb_sucursal'):
            return

        self.cmb_sucursal.blockSignals(True)
        self.cmb_sucursal.clear()

        cliente_id = self.cmb_cliente.currentData()

        if cliente_id is None:
            self.cmb_sucursal.addItem("— Selecciona sucursal —", None)
            self.cmb_sucursal.setEnabled(False)
            self.cmb_sucursal.blockSignals(False)
            return

        sucursales = self._suc_map.get(int(cliente_id), [])
        if sucursales:
            self.cmb_sucursal.addItem("— Selecciona sucursal / planta —", None)
            for sid, sname, sdir in sucursales:
                if sname and sdir and sname != sdir:
                    texto = f"{sname} — {sdir}".strip(" —")
                else:
                    texto = sdir or sname or "Sucursal"
                self.cmb_sucursal.addItem(texto, sid)
        else:
            self.cmb_sucursal.addItem("Matriz / Única Planta", None)

        self.cmb_sucursal.setEnabled(True)
        self.cmb_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, index=0):
        """Carga el catálogo de equipos de la sucursal seleccionada para el autocompletado."""
        self._on_params_changed()
        if not hasattr(self, 'cmb_sucursal'):
            return

        sucursal_id = self.cmb_sucursal.currentData()
        catalog = []
        if sucursal_id and _HAS_DB and _db_pool:
            try:
                conn = _db_pool.get_connection()
                try:
                    with conn.cursor() as cur:
                        cur.execute('''
                            SELECT numero_serie, marca, modelo, id_indicador_equipo,
                                   ubicacion_interna, capacidad_maxima, division_minima, tipo_instrumento
                            FROM cliente_equipos
                            WHERE sucursal_id = %s AND activo = TRUE
                        ''', (sucursal_id,))
                        for row in cur.fetchall():
                            catalog.append({
                                "numero_serie": row[0] or "",
                                "marca": row[1] or "",
                                "modelo": row[2] or "",
                                "id_indicador": row[3] or "",
                                "ubicacion": row[4] or "",
                                "capacidad_max": row[5] or "",
                                "division_min": row[6] or "",
                                "tipo_instrumento": row[7] or "",
                            })
                finally:
                    _db_pool.release_connection(conn)
            except Exception as e:
                logger.warning(f"Error cargando equipos de la sucursal {sucursal_id}: {e}")

        # Guardar el catálogo activo: las tarjetas creadas DESPUÉS del cambio
        # de sucursal también lo recibirán vía self._current_catalog en
        # _update_equipos_section.
        self._current_catalog = catalog

        # Distribuir el catálogo a todas las tarjetas de equipo activas
        if hasattr(self, '_equipo_cards'):
            for card in self._equipo_cards:
                if hasattr(card, 'set_instrument_catalog'):
                    card.set_instrument_catalog(catalog)

    on_params_changed = _on_params_changed

    def _obtener_siguiente_folio(self, tipo_doc="OS") -> str:
        """Consulta el siguiente folio disponible SIN consumirlo (solo para previsualizar).

        Estrategia de doble consulta para máxima robustez:
        1. Lee control_folios.ultimo_consecutivo (fuente principal, actualizada en _reservar_folios).
        2. Lee MAX(consecutivo) de ordenes_servicio (fuente de respaldo, refleja la realidad real de BD).
        3. Usa el MAYOR de ambos + 1 como siguiente sugerido.

        Esto garantiza que el campo siempre avanza, incluso si control_folios estuvo desincronizado.
        """
        try:
            if _HAS_DB and _db_pool:
                anio = QDate.currentDate().year()
                anio2 = str(anio)[2:]
                max_control = 0
                max_os = 0

                # 1. Leer de control_folios
                try:
                    from models.folio_manager import FolioManager
                    max_control = FolioManager.get_current_consecutivo(tipo_doc, anio)
                except Exception as e_fm:
                    logger.warning("FolioManager no disponible: %s", e_fm)

                # 2. Leer MAX(consecutivo) real de ordenes_servicio (respaldo)
                try:
                    conn = _db_pool.get_connection()
                    try:
                        with conn.cursor() as cur:
                            cur.execute(
                                """
                                SELECT COALESCE(MAX(consecutivo), 0)
                                FROM ordenes_servicio
                                WHERE tipo_documento = %s
                                  AND EXTRACT(YEAR FROM fecha) = %s
                                """,
                                (tipo_doc, anio)
                            )
                            row = cur.fetchone()
                            max_os = int(row[0]) if row else 0
                        conn.commit()
                    finally:
                        _db_pool.release_connection(conn)
                except Exception as e_os:
                    logger.warning("No se pudo leer MAX(consecutivo) de ordenes_servicio: %s", e_os)

                # 3. Usar el mayor de las dos fuentes
                ultimo = max(max_control, max_os)
                siguiente = ultimo + 1
                folio_preview = f"{tipo_doc}-{anio2}-{siguiente}"
                logger.debug(
                    "Folio sugerido: %s (control_folios=%d, os_max=%d → siguiente=%d)",
                    folio_preview, max_control, max_os, siguiente
                )
                return folio_preview
        except Exception:
            pass
        # Fallback genérico si no hay BD
        anio2 = str(QDate.currentDate().year())[2:]
        return f"{tipo_doc}-{anio2}-1"

    def _actualizar_resumen(self):
        """Actualiza el bloque 4 (Confirmar y Ejecutar) con el resumen y el folio."""
        # 1. Resumen técnico
        cliente  = self.cmb_cliente.currentText().strip()       if hasattr(self, 'cmb_cliente')       else ""
        sucursal = self.cmb_sucursal.currentText().strip()      if hasattr(self, 'cmb_sucursal')      else ""
        tecnico  = self.cmb_tecnico.currentText().strip()       if hasattr(self, 'cmb_tecnico')       else ""
        servicio = self.cmb_tipo_servicio.currentText().strip() if hasattr(self, 'cmb_tipo_servicio') else ""
        cant     = getattr(self.spn_cantidad, 'value', lambda: 1)() if hasattr(self, 'spn_cantidad') else 1

        html  = f"<b>Cliente:</b> {cliente} &nbsp;&nbsp;|&nbsp;&nbsp; <b>Sucursal:</b> {sucursal}<br>"
        html += f"<b>Técnico:</b> {tecnico}<br>"
        if getattr(self, '_tipo_doc', '') == 'OS':
            html += f"<b>Servicio:</b> {servicio}<br>"
        html += f"<b>Cantidad de Formatos a generar:</b> {cant}"

        if hasattr(self, '_lbl_resumen'):
            self._lbl_resumen.setText(html)

        # 2. Auto-poblar el folio si el campo está vacío
        if hasattr(self, 'input_folio_inicial') and not self.input_folio_inicial.text().strip():
            tipo_doc  = getattr(self, '_tipo_doc', 'OS') or "OS"
            nxt_folio = self._obtener_siguiente_folio(tipo_doc) if hasattr(self, '_obtener_siguiente_folio') else f"{tipo_doc}-26-1"
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.setText(str(nxt_folio))
            self.input_folio_inicial.setEnabled(True)
            self.input_folio_inicial.setReadOnly(False)
            self.input_folio_inicial.blockSignals(False)

        # 3. Etiqueta de rango en tiempo real — siempre se recalcula
        if hasattr(self, 'lbl_folio_rango'):
            folio_base = self.input_folio_inicial.text().strip() if hasattr(self, 'input_folio_inicial') else ""
            if folio_base:
                parts = folio_base.split("-")
                if len(parts) >= 2 and parts[-1].isdigit():
                    num_inicio = int(parts[-1])
                    prefix     = "-".join(parts[:-1])
                    if cant == 1:
                        self.lbl_folio_rango.setText(
                            f"▶  Se generará el folio: "
                            f"<b>{folio_base}</b>"
                        )
                    else:
                        num_fin    = num_inicio + cant - 1
                        folio_fin  = f"{prefix}-{num_fin}"
                        self.lbl_folio_rango.setText(
                            f"▶  Se generará el lote de <b>{cant} folios</b>: "
                            f"<b>{folio_base}</b> al <b>{folio_fin}</b>"
                        )
                else:
                    # Folio sin número al final (formato libre)
                    self.lbl_folio_rango.setText(
                        f"▶  Se generarán <b>{cant}</b> folio(s) a partir de <b>{folio_base}</b>"
                    )
            else:
                self.lbl_folio_rango.setText("")

    def _validar_formulario(self):
        """No bloquea botones, solo actualiza la interfaz visual y fuerza la activación incondicional."""
        try:
            self._actualizar_resumen()
            
            # 5. Forzar activación inmediata incondicional de los botones
            if hasattr(self, 'btn_ejecutar'):
                self.btn_ejecutar.setEnabled(True)
            if hasattr(self, 'btn_generar_pdf'):
                self.btn_generar_pdf.setEnabled(True)
            if hasattr(self, '_btn_imprimir'):
                self._btn_imprimir.setEnabled(True)
            
            return True

        except Exception as e:
            logger.warning(f"Error en validación de formulario: {e}")
            if hasattr(self, 'btn_ejecutar'):
                self.btn_ejecutar.setEnabled(True)
            if hasattr(self, 'btn_generar_pdf'):
                self.btn_generar_pdf.setEnabled(True)
            if hasattr(self, '_btn_imprimir'):
                self._btn_imprimir.setEnabled(True)
            return True

    def _on_modalidad(self, modalidad: str) -> None:
        """Paso 1 completado → habilitar paso 2."""
        self._modalidad = modalidad
        self._tipo_doc  = ""

        # Marcar visualmente la tarjeta de modalidad de forma forzada
        self._card_digital.blockSignals(True)
        self._card_fisico.blockSignals(True)
        self._card_digital.setChecked(modalidad == "DIGITAL")
        self._card_fisico.setChecked(modalidad == "FISICO")
        self._card_digital._apply_style(modalidad == "DIGITAL")
        self._card_fisico._apply_style(modalidad == "FISICO")
        self._card_digital.blockSignals(False)
        self._card_fisico.blockSignals(False)

        # Restablecer selección de documento
        for btn in [self._card_os, self._card_rma, self._card_re, self._card_lp, self._card_lv]:
            btn.blockSignals(True)
            btn.setChecked(False)
            if hasattr(btn, '_apply_style'): btn._apply_style(False)
            btn.blockSignals(False)

        # Habilitar paso 2
        self._enable_card(self._card_step2)

        # Actualizar botón de acción según modalidad
        if modalidad == "DIGITAL":
            self.btn_ejecutar.setText("📱  Asignar y Sincronizar a Tablet")
            self.btn_ejecutar.setStyleSheet(self.btn_ejecutar.styleSheet()
                                            .replace("#E63946", _BLUE)
                                            .replace("#D90429", "#0062CC")
                                            .replace("#B70020", "#004A99"))
        else:
            self.btn_ejecutar.setText("🖨️  Generar e Imprimir PDF")
            # Restaurar rojo
            self.btn_ejecutar.setStyleSheet("""
                QPushButton {
                    background-color: #E63946;
                    color: #FFFFFF; border: none;
                    border-radius: 9px;
                    font-size: 14px; font-weight: 700;
                    padding: 0 24px;
                }
                QPushButton:hover   { background-color: #D90429; }
                QPushButton:pressed { background-color: #B70020; }
                QPushButton:disabled { background-color: #C7C7CC; color: #FFFFFF; }
            """)

        self._update_title()
        self.btn_ejecutar.setEnabled(True)
        
        # Si ya había un tipo seleccionado antes, refrescar pasos 3 y 4
        if getattr(self, '_tipo_doc', ''):
            self._mostrar_pasos_3_y_4()

    def _rma_add_item_row(self) -> None:
        """Agrega una fila de ítem (Cantidad / N° Parte / Descripción / N° Serie) a la tabla RMA."""
        row_widget = QWidget()
        row_widget.setStyleSheet("background: transparent;")
        row_lay = QHBoxLayout(row_widget)
        row_lay.setContentsMargins(0, 2, 0, 2)
        row_lay.setSpacing(0)

        le_cant   = QLineEdit(); le_cant.setPlaceholderText("1");   le_cant.setFixedHeight(28)
        le_parte  = QLineEdit(); le_parte.setPlaceholderText("RL-000");  le_parte.setFixedHeight(28)
        le_desc   = QLineEdit(); le_desc.setPlaceholderText("Descripción del material"); le_desc.setFixedHeight(28)
        le_serie  = QLineEdit(); le_serie.setPlaceholderText("N° Serie (opcional)");  le_serie.setFixedHeight(28)

        for _le in (le_cant, le_parte, le_desc, le_serie):
            _le.setStyleSheet("""
                QLineEdit {
                    background: #FFFFFF; border: 1px solid #D1D5DB;
                    border-radius: 5px; padding: 2px 6px;
                    font-size: 12px; color: #1D1D1F;
                }
                QLineEdit:focus { border-color: #2563EB; }
            """)

        btn_del = QPushButton("✖")
        btn_del.setFixedSize(26, 26)
        btn_del.setStyleSheet("""
            QPushButton {
                background: transparent; color: #9CA3AF;
                border: none; font-size: 12px;
            }
            QPushButton:hover { color: #EF4444; }
        """)

        row_lay.addWidget(le_cant,  stretch=1)
        row_lay.addSpacing(4)
        row_lay.addWidget(le_parte, stretch=2)
        row_lay.addSpacing(4)
        row_lay.addWidget(le_desc,  stretch=4)
        row_lay.addSpacing(4)
        row_lay.addWidget(le_serie, stretch=2)
        row_lay.addSpacing(4)
        row_lay.addWidget(btn_del)

        row_data = {
            "widget":   row_widget,
            "cantidad": le_cant,
            "parte":    le_parte,
            "desc":     le_desc,
            "serie":    le_serie,
        }
        self._rma_item_rows.append(row_data)
        self._rma_items_container.addWidget(row_widget)

        def _remove():
            row_widget.setParent(None)
            if row_data in self._rma_item_rows:
                self._rma_item_rows.remove(row_data)
        btn_del.clicked.connect(_remove)

    # ─── Helpers para el panel LV de básculas ────────────────────────────────
    _LE_STYLE = (
        "QLineEdit { background: #FFFBF5; border: 1px solid rgba(230,126,34,0.5); "
        "border-radius: 5px; padding: 2px 5px; font-size: 11px; color: #1D1D1F; } "
        "QLineEdit:focus { border-color: #E67E22; }"
    )
    _TIPOS_BASCULA = [
        "", "Camionera", "Plataforma", "Tolva / Tanque",
        "Analítica", "Conteo", "Colgante / Grúa", "Banco",
    ]

    def _lv_add_bascula_row(self) -> None:
        """Agrega una fila de báscula al panel LV."""
        idx = len(self._lv_bascula_rows) + 1
        row_w = QWidget()
        row_w.setStyleSheet("background: transparent;")
        row_lay = QHBoxLayout(row_w)
        row_lay.setContentsMargins(0, 2, 0, 2)
        row_lay.setSpacing(4)

        # Número de báscula (etiqueta)
        lbl_n = QLabel(f"{idx}.")
        lbl_n.setFixedWidth(20)
        lbl_n.setStyleSheet("font-size: 11px; font-weight: 700; color: #C0500A; background: transparent;")
        row_lay.addWidget(lbl_n)

        # Tag / ID
        le_tag = QLineEdit(); le_tag.setPlaceholderText("Tag/ID"); le_tag.setFixedHeight(27)
        le_tag.setStyleSheet(self._LE_STYLE)
        # Tipo de instrumento (combo)
        cmb_tipo = QComboBox(); cmb_tipo.addItems(self._TIPOS_BASCULA)
        cmb_tipo.setFixedHeight(27); cmb_tipo.setMinimumWidth(130)
        # Marca
        le_marca = QLineEdit(); le_marca.setPlaceholderText("Marca"); le_marca.setFixedHeight(27)
        le_marca.setStyleSheet(self._LE_STYLE)
        # Modelo
        le_modelo = QLineEdit(); le_modelo.setPlaceholderText("Modelo"); le_modelo.setFixedHeight(27)
        le_modelo.setStyleSheet(self._LE_STYLE)
        # N° Serie
        le_serie = QLineEdit(); le_serie.setPlaceholderText("Serie"); le_serie.setFixedHeight(27)
        le_serie.setStyleSheet(self._LE_STYLE)
        # Cap. Máx.
        le_cap = QLineEdit(); le_cap.setPlaceholderText("Cap. Máx."); le_cap.setFixedHeight(27)
        le_cap.setStyleSheet(self._LE_STYLE)
        # Div. Mín.
        le_div = QLineEdit(); le_div.setPlaceholderText("Div. Mín."); le_div.setFixedHeight(27)
        le_div.setStyleSheet(self._LE_STYLE)
        # Ubicación
        le_ubic = QLineEdit(); le_ubic.setPlaceholderText("Ubicación en Planta"); le_ubic.setFixedHeight(27)
        le_ubic.setStyleSheet(self._LE_STYLE)

        # Botón eliminar
        btn_del = QPushButton("✖")
        btn_del.setFixedSize(24, 24)
        btn_del.setStyleSheet(
            "QPushButton { background: transparent; color: #9CA3AF; border: none; font-size: 11px; } "
            "QPushButton:hover { color: #EF4444; }"
        )

        for _w, _stretch in [
            (le_tag,    1), (cmb_tipo, 2), (le_marca,  1), (le_modelo, 1),
            (le_serie,  1), (le_cap,   1), (le_div,    1), (le_ubic,   2),
        ]:
            row_lay.addWidget(_w, stretch=_stretch)
        row_lay.addWidget(btn_del)

        row_data = {
            "widget":   row_w,
            "tag":      le_tag,
            "tipo":     cmb_tipo,
            "marca":    le_marca,
            "modelo":   le_modelo,
            "serie":    le_serie,
            "cap":      le_cap,
            "div":      le_div,
            "ubicacion": le_ubic,
        }
        self._lv_bascula_rows.append(row_data)
        self._lv_basculas_container.addWidget(row_w)

        def _remove():
            row_w.setParent(None)
            if row_data in self._lv_bascula_rows:
                self._lv_bascula_rows.remove(row_data)
            # Actualizar spinner
            if hasattr(self, "spn_lv_basculas"):
                self.spn_lv_basculas.blockSignals(True)
                self.spn_lv_basculas.setValue(len(self._lv_bascula_rows))
                self.spn_lv_basculas.blockSignals(False)
        btn_del.clicked.connect(_remove)

    def _lv_sync_bascula_rows(self, n: int) -> None:
        """Agrega o elimina filas LV para tener exactamente n."""
        while len(self._lv_bascula_rows) < n:
            self._lv_add_bascula_row()
        while len(self._lv_bascula_rows) > n:
            row = self._lv_bascula_rows.pop()
            row["widget"].setParent(None)

    def _lv_collect_basculas(self) -> list:
        """Recoge los datos de las filas de básculas LV."""
        result = []
        for row in getattr(self, "_lv_bascula_rows", []):
            result.append({
                "id_indicador":     row["tag"].text().strip(),
                "tipo_instrumento": row["tipo"].currentText().strip(),
                "marca":            row["marca"].text().strip(),
                "modelo":           row["modelo"].text().strip(),
                "numero_serie":     row["serie"].text().strip(),
                "capacidad_max":    row["cap"].text().strip(),
                "division_min":     row["div"].text().strip(),
                "ubicacion_interna": row["ubicacion"].text().strip(),
            })
        return result

    def _on_tipo_doc(self, tipo: str) -> None:
        """Paso 2 completado → habilitar paso 3 y adaptar la UI segun el tipo de documento."""
        self._tipo_doc = tipo
        
        # Forzar visualmente el estado de selección de la tarjeta de documento
        for c, t in [(self._card_os, "OS"), (self._card_rma, "RMA"), 
                     (self._card_re, "RE"), (self._card_lp, "LP"), (self._card_lv, "LV")]:
            c.blockSignals(True)
            c.setChecked(tipo == t)
            if hasattr(c, '_apply_style'): c._apply_style(tipo == t)
            c.blockSignals(False)

        es_re  = (tipo == "RE")
        es_rma = (tipo == "RMA")
        es_os  = (tipo == "OS")
        es_lv  = (tipo == "LV")
        # LV redirige al formulario dedicado al ejecutar — no necesita campos extra en paso 3
        # Los campos de OS / RE / RMA se ocultan para LP y LV
        es_os_fields = es_os  # solo OS muestra tipo servicio, excentricidad, equipo

        # Bloque estructura RE
        if hasattr(self, "_frame_re_estructura"):
            self._frame_re_estructura.setVisible(es_re)

        # Bloque ítems RMA
        if hasattr(self, "_frame_rma_items"):
            self._frame_rma_items.setVisible(es_rma)

        # Bloque básculas LV
        if hasattr(self, "_frame_lv_basculas"):
            self._frame_lv_basculas.setVisible(es_lv)

        # Tipo de Servicio / Instrumento → visible solo para OS
        if hasattr(self, "_widget_row_tipo_serv"):
            self._widget_row_tipo_serv.setVisible(es_os_fields)

        # Excentricidad / Puntos de Exactitud → visible solo para OS
        if hasattr(self, "_widget_row_exc"):
            self._widget_row_exc.setVisible(es_os_fields)

        # Datos del Instrumento por Equipo → visible solo para OS
        if hasattr(self, "_widget_equipos_section"):
            self._widget_equipos_section.setVisible(es_os_fields)

        # Frame de Calibración → siempre oculto al cambiar tipo de doc;
        # _on_params_changed lo mostrará si aplica según el tipo de servicio.
        if hasattr(self, "_frame_calibracion") and not es_os:
            self._frame_calibracion.setVisible(False)

        self._mostrar_pasos_3_y_4()

    def _mostrar_pasos_3_y_4(self):
        """Despliega y habilita forzosamente los pasos 3 y 4 del asistente."""
        self._enable_card(self._card_step3)
        self._card_step4.setVisible(True)
        self._enable_card(self._card_step4)
        
        # Poblar el folio de forma obligatoria en el Paso 4
        if hasattr(self, 'input_folio_inicial') and not self.input_folio_inicial.text().strip():
            tipo_doc = getattr(self, '_tipo_doc', 'OS') or "OS"
            nxt_folio = self._obtener_siguiente_folio(tipo_doc) if hasattr(self, '_obtener_siguiente_folio') else f"{tipo_doc}-26-549"
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.setText(str(nxt_folio))
            self.input_folio_inicial.setEnabled(True)
            self.input_folio_inicial.setReadOnly(False)
            self.input_folio_inicial.blockSignals(False)

        if hasattr(self, '_on_params_changed'):
            self._on_params_changed()


    def _on_tipo_estructura_changed(self) -> None:
        """Muestra/oculta controles de Instalación y N° Secciones según tipo de estructura."""
        es_camionera = self.cmb_tipo_estructura.currentText() == "Camionera"
        self._widget_camionera_extra.setVisible(es_camionera)

    def _on_celdas_homogeneas_changed(self) -> None:
        """Muestra/oculta el Grupo B de celdas según si son mixtas (NO Homogéneas)."""
        mixtas = self.cmb_celdas_homogeneas.currentIndex() == 1  # 0=SÍ, 1=NO
        self._widget_grupo_b.setVisible(mixtas)

    def _update_title(self) -> None:
        tipo_str = {"DIGITAL": "Digital — Tablet", "FISICO": "Físico — Impresión Calca"}.get(
            self._modalidad, ""
        )
        self._lbl_title.setText(
            f"{'📱' if self._modalidad == 'DIGITAL' else '🖨️'}  "
            f"Asistente de Generación — {tipo_str}"
        )

    def _on_cambiar_consecutivo(self):
        """Permite a un administrador cambiar el número consecutivo actual en la BD."""
        if not _HAS_DB or not _db_pool:
            QMessageBox.warning(self, "Modo Demo", "No se puede editar el consecutivo en modo offline/demo.")
            return

        tipo = self._tipo_doc
        if not tipo:
            QMessageBox.warning(self, "Aviso", "Selecciona primero un tipo de documento.")
            return

        from PyQt6.QtWidgets import QInputDialog
        from datetime import date
        anio = date.today().year

        nuevo_consecutivo, ok = QInputDialog.getInt(
            self, "Editar Consecutivo",
            f"Introduce el nuevo consecutivo base para {tipo}-{str(anio)[2:]}:",
            1, 1, 99999
        )
        if ok:
            try:
                conn = _db_pool.get_connection()
                try:
                    with conn.cursor() as cur:
                        # control_folios tiene consecutivo, tipo_documento, anio
                        cur.execute(
                            "UPDATE control_folios SET consecutivo = %s WHERE tipo_documento = %s AND anio = %s",
                            (nuevo_consecutivo - 1, tipo, anio)
                        )
                    conn.commit()
                finally:
                    _db_pool.release_connection(conn)
                QMessageBox.information(self, "Éxito", f"El próximo folio será {tipo}-{str(anio)[2:]}-{nuevo_consecutivo:04d}")
            except Exception as e:
                QMessageBox.critical(self, "Error", f"Error al actualizar consecutivo: {e}")

    # ══════════════════════════════════════════════════════════════════════════
    # EJECUTAR
    # ══════════════════════════════════════════════════════════════════════════
    def _validate_catalogs(self) -> bool:
        """
        Verifica que haya al menos un cliente y un técnico registrados
        en los QComboBox antes de permitir la generación de un formato.

        Retorna True si todo está OK para continuar.
        Retorna False y muestra QMessageBox si falta algún catálogo.
        """
        sin_clientes = self.cmb_cliente.count() <= 1   # solo el placeholder
        sin_tecnicos = self.cmb_tecnico.count() <= 1   # solo el placeholder

        # Validar cliente seleccionado
        cliente_data = self.cmb_cliente.currentData()
        sin_seleccion_cliente = (cliente_data is None)

        if sin_clientes:
            QMessageBox.information(
                self,
                "⚠️  Sin clientes registrados",
                "No hay clientes / razones sociales registradas en el sistema.\n\n"
                "Por favor, ve al módulo ‘Catálogos’ y da de alta al menos "
                "un cliente antes de generar un formato.",
            )
            return False

        if sin_tecnicos:
            QMessageBox.information(
                self,
                "⚠️  Sin técnicos registrados",
                "No hay técnicos registrados en el sistema.\n\n"
                "Por favor, ve al módulo ‘Catálogos’ y da de alta al menos "
                "un técnico antes de generar un formato.",
            )
            return False

        if sin_seleccion_cliente:
            QMessageBox.warning(
                self,
                "Cliente requerido",
                "Debes seleccionar un Cliente / Razón Social antes de continuar.",
            )
            return False

        return True

    def _ejecutar(self) -> None:
        """Valida catálogos y procesa según modalidad elegida, mostrando QMessageBox si faltan campos."""
        # Validación en el momento del clic solicitada por el usuario
        cliente = self.cmb_cliente.currentText().strip() if hasattr(self, 'cmb_cliente') else ""
        sucursal = self.cmb_sucursal.currentText().strip() if hasattr(self, 'cmb_sucursal') else ""
        tecnico = self.cmb_tecnico.currentText().strip() if hasattr(self, 'cmb_tecnico') else ""
        servicio = self.cmb_tipo_servicio.currentText().strip() if hasattr(self, 'cmb_tipo_servicio') else ""
        tipo_doc = getattr(self, '_tipo_doc', 'OS') or 'OS'

        faltan = []
        if not cliente or "Selecciona" in cliente or "—" in cliente: faltan.append("Cliente / Razón Social")
        if not sucursal or "Selecciona" in sucursal or "—" in sucursal: faltan.append("Sucursal / Planta")
        if not tecnico or "Selecciona" in tecnico or "—" in tecnico: faltan.append("Técnico Asignado")
        if tipo_doc == "OS" and (not servicio or "Selecciona" in servicio or "—" in servicio): faltan.append("Tipo de Servicio")
        
        if faltan:
            QMessageBox.warning(
                self, 
                "Campos Incompletos", 
                "Por favor completa los siguientes campos obligatorios para continuar:\n\n• " + "\n• ".join(faltan)
            )
            return

        # Si el usuario borró el folio y presionó generar, autopoblar
        if hasattr(self, 'input_folio_inicial') and not self.input_folio_inicial.text().strip():
            fallback = self._obtener_siguiente_folio(tipo_doc) if hasattr(self, '_obtener_siguiente_folio') else f"{tipo_doc}-26-549"
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.setText(str(fallback))
            self.input_folio_inicial.blockSignals(False)

        if not self._validate_catalogs():
            return
            
        try:
            # Guardar historial de equipos del cliente seleccionado
            datos = self._collect_datos()
            self._save_cliente_instrumentos(datos)
            
            if self._modalidad == "FISICO":
                self._generar_pdf()
            else:
                self._asignar_tablet()
        except Exception as e:
            logger.exception("Error inesperado en _ejecutar: %s", e)
            QMessageBox.critical(
                self, "Error Inesperado",
                f"Ocurrió un error al procesar el formulario:\n\n{e}\n\nLos datos en pantalla se mantendrán para que puedas corregirlos o reintentar."
            )


    def _get_inicial_calibrador(self) -> str:
        """Obtiene la inicial seleccionada en el formulario global o retorna vacío."""
        if hasattr(self, 'btn_inicial_j') and self.btn_inicial_j.isChecked():
            return "J"
        elif hasattr(self, 'btn_inicial_i') and self.btn_inicial_i.isChecked():
            return "I"
        elif hasattr(self, 'btn_inicial_a') and self.btn_inicial_a.isChecked():
            return "A"
        return ""

    def _get_numero_cca(self) -> str:
        """Obtiene el texto del CCA global si existe."""
        if hasattr(self, 'input_numero_cca'):
            return self.input_numero_cca.text().strip()
        elif hasattr(self, 'le_numero_cca'):
            return self.le_numero_cca.text().strip()
        return ""

    def _generar_pdf(self) -> None:
        """Reserva folios y genera un único PDF con todos los folios del lote.
        En modalidad FÍSICO: cada folio produce 2 páginas idénticas (papel calca)."""
        self._set_loading(True)
        try:
            datos    = self._collect_datos()
            registros = self._reservar_folios(datos)
            self._set_loading(False)

            if registros:
                try:
                    pdf_path = self._generar_pdf_lote(registros, datos)
                    folios_str = ", ".join(registros)
                    paginas = len(registros) * 2  # Original + Calca por folio
                    # ── Avanzar el folio en la UI antes de mostrar el diálogo ────────────────
                    self._avanzar_folio_ui(registros)
                    QMessageBox.information(
                        self, "✅ PDF Generado",
                        f"Se generaron {len(registros)} folio(s) en un solo PDF:\n"
                        f"{folios_str}\n\n"
                        f"Total de páginas: {paginas} "
                        f"(Original + Copia Calca por folio)\n\nAbriendo vista previa…"
                    )
                    self._abrir_pdf_preview(pdf_path)
                except Exception as exc:
                    logger.exception("Error generando PDF lote: %s", exc)
                    QMessageBox.critical(
                        self, "Error en PDF",
                        f"No se pudo generar el PDF del lote:\n\n{exc}"
                    )
        except Exception as exc:
            self._set_loading(False)
            logger.exception("Error al generar PDF: %s", exc)
            QMessageBox.critical(self, "Error", f"No se pudo generar el PDF:\n\n{exc}")

    def _avanzar_folio_ui(self, folios_generados: list) -> None:
        """
        Refresca el campo 'input_folio_inicial' al próximo consecutivo disponible
        después de que se generó un lote exitosamente.

        Limpia el campo primero para forzar la re-consulta en _actualizar_resumen()
        y luego pide el nuevo consecutivo directamente a la BD, que ya fue
        actualizada por _reservar_folios().
        """
        if not hasattr(self, 'input_folio_inicial'):
            return
        try:
            tipo_doc = getattr(self, '_tipo_doc', 'OS') or 'OS'
            # Limpiar el campo primero: _actualizar_resumen solo auto-llena cuando está vacío
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.clear()
            self.input_folio_inicial.blockSignals(False)
            # Consultar nuevo consecutivo (control_folios ya fue actualizado en _reservar_folios)
            nuevo_folio = self._obtener_siguiente_folio(tipo_doc)
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.setText(nuevo_folio)
            self.input_folio_inicial.blockSignals(False)
            logger.info("[UI] Folio avanzado a: %s (tras generar: %s)",
                        nuevo_folio, ', '.join(str(f) for f in folios_generados))
        except Exception as exc:
            logger.warning("[UI] No se pudo avanzar el folio en la UI: %s", exc)


    def _asignar_tablet(self) -> None:
        """Reserva folios con modalidad DIGITAL y estado Proceso para sincronizar con tablet."""
        self._set_loading(True)
        try:
            datos = self._collect_datos()
            # ── Garantizar modalidad Digital y sync_status para tablet ──────
            datos["modalidad"]    = "Digital"   # La tablet solo procesa órdenes digitales
            datos["sync_status"]  = "PENDIENTE" # Marcadas para que el pull las descargue

            # Usar estado 'Proceso' (visible en dashboard y en el pull de tablet)
            registros = self._reservar_folios(datos, estado="Proceso")
            self._set_loading(False)

            if registros:
                tec = datos.get("tecnico_nombre", "el técnico asignado")
                info = "\n".join(f"  • {r}" for r in registros[:10])
                QMessageBox.information(
                    self, "📱 Asignado a Tablet",
                    f"Se crearon {len(registros)} formato(s) digitales:\n\n"
                    f"{info}\n\n"
                    f"Aparecerán de inmediato en el dashboard de {tec}\n"
                    f"y se descargarán en la siguiente sincronización de la tablet."
                )
                # Guardar el primer folio del lote para abrir el formulario digital
                self._ultimo_folio_digital = registros[0]
                self._ultimo_os_data_digital = {
                    "cliente":         datos.get("cliente", ""),
                    "tecnico_nombre":  datos.get("tecnico_nombre", ""),
                    "fecha":           str(datos.get("fecha", "")),
                    "observaciones_tecnico": datos.get("observaciones_tecnico", ""),
                    "id_cliente":      datos.get("id_cliente", 0),
                }
                # Mostrar botón de formulario digital
                self.btn_llenar_digital.setVisible(True)
                # Emitir señal para refrescar el dashboard inmediatamente
                try:
                    from core.app_session import AppSession
                    if hasattr(AppSession, 'dashboard_refresh') and AppSession.dashboard_refresh:
                        AppSession.dashboard_refresh()
                except Exception:
                    pass
        except Exception as exc:
            self._set_loading(False)
            logger.exception("Error al asignar a tablet: %s", exc)
            QMessageBox.critical(self, "Error", f"No se pudo asignar a tablet:\n\n{exc}")

    def _abrir_formulario_digital(self) -> None:
        """Abre el Formulario Digital para el último folio asignado a tablet."""
        folio = self._ultimo_folio_digital
        if not folio:
            QMessageBox.information(
                self, "Sin folio asignado",
                "Primero debes completar el paso 'Asignar y Sincronizar a Tablet' "
                "para generar un folio y luego llenar el formulario digital."
            )
            return

        try:
            from ui.dialogs.digital_service_dialog import open_digital_form
            os_data    = self._ultimo_os_data_digital or {}
            id_cliente = os_data.get("id_cliente", 0)
            completado = open_digital_form(
                folio_os   = folio,
                os_data    = os_data,
                os_id      = 0,
                id_cliente = id_cliente,
                parent     = self,
            )
            if completado:
                logger.info("Formulario digital completado para folio: %s", folio)
                self.btn_llenar_digital.setVisible(False)
                self._ultimo_folio_digital = ""
        except Exception as exc:
            logger.exception("Error abriendo formulario digital: %s", exc)
            QMessageBox.critical(self, "Error", f"No se pudo abrir el formulario digital:\n\n{exc}")

    # ══════════════════════════════════════════════════════════════════════════
    # ACTUALIZAR TARJETAS DE EQUIPO
    # ══════════════════════════════════════════════════════════════════════════
    def _update_equipos_section(self, n: int) -> None:
        """Agrega o elimina EquipoCard para que haya exactamente n tarjetas."""
        # Determinar si el servicio activo requiere calibración
        es_calib = self._servicio_requiere_calibracion()

        # Eliminar tarjetas sobrantes
        while len(self._equipo_cards) > n:
            card = self._equipo_cards.pop()
            self._equipos_container.removeWidget(card)
            card.deleteLater()

        # Agregar tarjetas faltantes
        es_inspec = self._servicio_requiere_inspeccion()
        _n_pts_global = 5
        try:
            if hasattr(self, 'cmb_puntos_exactitud'):
                _n_pts_global = int(self.cmb_puntos_exactitud.currentText())
        except Exception:
            pass
        while len(self._equipo_cards) < n:
            idx  = len(self._equipo_cards) + 1
            card = EquipoCard(idx)
            card.set_instrument_catalog(self._current_catalog)
            card.set_calibracion_visible(es_calib)   # visibilidad inmediata
            card.set_inspeccion_visible(es_inspec)   # visibilidad de hologramas
            card.set_puntos_exactitud(_n_pts_global) # sembrar con valor global
            self._equipo_cards.append(card)
            self._equipos_container.addWidget(card)

    def _servicio_requiere_calibracion(self) -> bool:
        """Retorna True si el tipo de servicio seleccionado contiene 'calibraci'."""
        try:
            if not hasattr(self, 'cmb_tipo_servicio'):
                return True  # default seguro hasta que la UI esté lista
            texto = self.cmb_tipo_servicio.currentText().strip().lower()
            # Normalizar: quitar acentos para comparación robusta
            texto_norm = texto.replace('á','a').replace('é','e').replace('í','i').replace('ó','o').replace('ú','u')
            return "calibraci" in texto_norm
        except Exception:
            return True  # fallback seguro

    def _servicio_requiere_inspeccion(self) -> bool:
        """Retorna True si el tipo de servicio seleccionado contiene 'inspección' / 'inspeccion'."""
        try:
            if not hasattr(self, 'cmb_tipo_servicio'):
                return False  # default: no inspección hasta que la UI esté lista
            texto = self.cmb_tipo_servicio.currentText().strip().lower()
            # Normalizar acentos para comparación robusta
            texto_norm = texto.replace('á','a').replace('é','e').replace('í','i').replace('ó','o').replace('ú','u')
            return "inspecci" in texto_norm
        except Exception:
            return False  # fallback seguro

    def _on_tipo_servicio_changed(self) -> None:
        """Propaga la visibilidad de campos de calibración e inspección a todas las tarjetas activas."""
        es_calib   = self._servicio_requiere_calibracion()
        es_inspec  = self._servicio_requiere_inspeccion()
        for card in self._equipo_cards:
            try:
                card.set_calibracion_visible(es_calib)
                card.set_inspeccion_visible(es_inspec)
            except Exception:
                pass

    def _on_puntos_exactitud_changed(self) -> None:
        """Propaga el valor global de 'Puntos de Exactitud' a todas las tarjetas.
        El usuario puede ajustar cada tarjeta individualmente después.
        """
        try:
            n = int(self.cmb_puntos_exactitud.currentText())
        except Exception:
            return
        for card in self._equipo_cards:
            try:
                card.set_puntos_exactitud(n)
            except Exception:
                pass

    # ══════════════════════════════════════════════════════════════════════════
    # HELPERS
    # ══════════════════════════════════════════════════════════════════════════

    def _get_direccion_cliente(self, id_cliente) -> str:
        """
        Consulta la dirección del cliente en cat_clientes dado su ID.
        Retorna string vacío si no hay BD o el cliente no existe.
        """
        if not id_cliente:
            return ""
        try:
            if not _HAS_DB or not _db_pool:
                return ""
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT COALESCE(direccion, '') FROM cat_clientes WHERE id = %s",
                        (id_cliente,)
                    )
                    row = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)
            return str(row[0]) if row else ""
        except Exception as exc:
            logger.warning("No se pudo cargar dirección del cliente id=%s: %s", id_cliente, exc)
            return ""

    def _get_direccion_sucursal(self, sucursal_id) -> str:
        """
        Consulta la dirección de la sucursal en cliente_sucursales dado su ID.
        Retorna string vacío si no hay BD o la sucursal no existe.
        """
        if not sucursal_id:
            return ""
        try:
            if not _HAS_DB or not _db_pool:
                return ""
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT COALESCE(direccion, '') FROM cliente_sucursales WHERE id = %s",
                        (sucursal_id,)
                    )
                    row = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)
            return str(row[0]) if row else ""
        except Exception as exc:
            logger.warning("No se pudo cargar dirección de sucursal id=%s: %s", sucursal_id, exc)
            return ""

    # ══════════════════════════════════════════════════════════════════════════
    # COLLECT DATOS
    # ══════════════════════════════════════════════════════════════════════════
    def _save_cliente_instrumentos(self, datos: dict) -> None:
        """Guarda o actualiza los instrumentos del cliente en la BD."""
        cliente_id = datos.get("id_cliente")
        if not cliente_id:
            return
            
        equipos = datos.get("equipos", [])
        
        try:
            from database.connection import DatabasePool
            pool = DatabasePool()
            with pool.transaction() as conn:
                with conn.cursor() as cur:
                    for eq in equipos:
                        # Si no hay ID Indicador ni Número de Serie, no se puede guardar como único
                        if not eq.get("equipo_id") and not eq.get("equipo_ns"):
                            continue
                            
                        # Upsert seguro sin ON CONFLICT: SELECT primero, luego INSERT o UPDATE
                        cur.execute(
                            "SELECT id FROM cliente_instrumentos WHERE cliente_id = %s AND id_indicador = %s AND numero_serie = %s",
                            (
                                cliente_id,
                                eq.get("equipo_id") or "",
                                eq.get("equipo_ns") or "",
                            )
                        )
                        ci_row = cur.fetchone()
                        if ci_row:
                            cur.execute(
                                """
                                UPDATE cliente_instrumentos SET
                                    marca          = %s,
                                    modelo         = %s,
                                    capacidad_max  = %s,
                                    division_min   = %s,
                                    ubicacion      = %s
                                WHERE id = %s
                                """,
                                (
                                    eq.get("equipo_marca"),
                                    eq.get("equipo_modelo"),
                                    eq.get("equipo_alcance"),
                                    eq.get("equipo_division"),
                                    eq.get("equipo_ubicacion"),
                                    ci_row[0],
                                )
                            )
                        else:
                            cur.execute(
                                """
                                INSERT INTO cliente_instrumentos
                                (cliente_id, id_indicador, marca, modelo, numero_serie, capacidad_max, division_min, ubicacion)
                                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                                """,
                                (
                                    cliente_id,
                                    eq.get("equipo_id") or "",
                                    eq.get("equipo_marca"),
                                    eq.get("equipo_modelo"),
                                    eq.get("equipo_ns") or "",
                                    eq.get("equipo_alcance"),
                                    eq.get("equipo_division"),
                                    eq.get("equipo_ubicacion"),
                                )
                            )
        except Exception as exc:
            logger.warning("Error guardando cliente_instrumentos: %s", exc)

    def _collect_rma_items(self) -> list:
        """Recoge los datos de la tabla de ítems RMA y los retorna como lista de dicts."""
        items = []
        for row in getattr(self, "_rma_item_rows", []):
            cant  = row["cantidad"].text().strip()
            parte = row["parte"].text().strip()
            desc  = row["desc"].text().strip()
            serie = row["serie"].text().strip()
            # Solo incluir filas que tengan al menos descripción o parte
            if desc or parte:
                items.append({
                    "cantidad":      cant  or "1",
                    "numero_parte":  parte,
                    "descripcion":   desc,
                    "numero_serie":  serie,
                })
        return items


    def _collect_datos(self) -> dict:
        """Recoge los datos del formulario en un dict (incluye equipos y id_cliente)."""
        cliente_idx  = self.cmb_cliente.currentIndex()
        id_cliente   = self.cmb_cliente.currentData()   if cliente_idx > 0 else None
        cliente_nom  = self.cmb_cliente.currentText()   if cliente_idx > 0 else ""

        tecnico_idx  = self.cmb_tecnico.currentIndex()
        tecnico_id   = self.cmb_tecnico.currentData()   if tecnico_idx > 0 else None
        tecnico_nom  = self.cmb_tecnico.currentText()   if tecnico_idx > 0 else "Sin asignar"

        obs          = self.txt_observaciones.toPlainText().strip() or None
        equipos      = [card.get_data() for card in self._equipo_cards]

        ts_idx        = self.cmb_tipo_servicio.currentIndex()
        id_tipo_serv  = self.cmb_tipo_servicio.currentData() if ts_idx > 0 else None
        tipo_serv_nom = self.cmb_tipo_servicio.currentText() if ts_idx > 0 else ""


        # Puntos de Apoyo (campo opcional)
        puntos_apoyo_val = ""
        if hasattr(self, "cmb_puntos_apoyo"):
            puntos_apoyo_val = self.cmb_puntos_apoyo.currentText().strip()

        # Sucursal seleccionada (para inyectar dirección en PDF)
        sucursal_idx_sel = self.cmb_sucursal.currentIndex()
        sucursal_id_sel  = self.cmb_sucursal.currentData() if sucursal_idx_sel > 0 else None
        sucursal_nom_sel = self.cmb_sucursal.currentText() if sucursal_idx_sel > 0 else ""
        
        tipo_servicio_mapped = tipo_serv_nom
        if self._tipo_doc == "RE":
            tipo_servicio_mapped = "Revisión"
        elif self._tipo_doc == "RMA":
            tipo_servicio_mapped = "Entrega Refacciones"
        
        puntos_exactitud = int(self.cmb_puntos_exactitud.currentText()) if hasattr(self, "cmb_puntos_exactitud") else 5


        # Campos de Tipo de Estructura, Indicador y Celdas (solo para RE)
        tipo_estructura       = None
        instalacion_camionera = None
        secciones_camionera   = None
        ubicacion_indicador   = "MANUAL"
        indicador_marca = indicador_modelo = indicador_serie = indicador_id_val = None
        cap_maxima = div_minima = None
        celdas_mixtas = None
        celda_a_marca = celda_a_modelo = celda_a_capacidad = celda_a_cantidad = None
        celda_b_marca = celda_b_modelo = celda_b_capacidad = celda_b_cantidad = None

        if self._tipo_doc == "RE":
            _raw = self.cmb_tipo_estructura.currentText()
            tipo_estructura = {
                "Camionera":      "CAMIONERA",
                "Plataforma":     "PLATAFORMA",
                "Tolva / Tanque": "TOLVA_TANQUE",
            }.get(_raw, _raw.upper())
            if tipo_estructura == "CAMIONERA":
                instalacion_camionera = self.cmb_instalacion_camionera.currentText().upper()
                secciones_camionera   = self.spn_secciones_camionera.value()
            # Ubicación del indicador en el diagrama
            _ub_txt = self.cmb_ubicacion_indicador.currentText() if hasattr(self, "cmb_ubicacion_indicador") else "Manual (Dibujo del Técnico)"
            ubicacion_indicador = {
                "Manual (Dibujo del Técnico)": "MANUAL",
                "Derecha":           "DERECHA",
                "Izquierda":         "IZQUIERDA",
                "Centro / Superior": "CENTRO",
            }.get(_ub_txt, "MANUAL")
            # Indicador e instrumento
            indicador_marca   = self.le_ind_marca.text().strip() or None
            indicador_modelo  = self.le_ind_modelo.text().strip() or None
            indicador_serie   = self.le_ind_serie.text().strip() or None
            indicador_id_val  = self.le_ind_id.text().strip() or None
            cap_maxima        = self.le_cap_maxima.text().strip() or None
            div_minima        = self.le_div_minima.text().strip() or None
            # Celdas de carga
            celdas_mixtas     = self.cmb_celdas_homogeneas.currentIndex() == 1
            celda_a_marca     = self.le_celda_a_marca.text().strip() or None
            celda_a_modelo    = self.le_celda_a_modelo.text().strip() or None
            celda_a_capacidad = self.le_celda_a_capacidad.text().strip() or None
            celda_a_cantidad  = self.spn_celda_a_cantidad.value()
            if celdas_mixtas:
                celda_b_marca     = self.le_celda_b_marca.text().strip() or None
                celda_b_modelo    = self.le_celda_b_modelo.text().strip() or None
                celda_b_capacidad = self.le_celda_b_capacidad.text().strip() or None
                celda_b_cantidad  = self.spn_celda_b_cantidad.value()

        datos_formato = {
            "modalidad":             self._modalidad,
            "tipo_doc":              self._tipo_doc or "OS",
            "cliente":               cliente_nom,
            "id_cliente":            id_cliente,
            "id_tecnico":            tecnico_id,
            "tecnico_nombre":        tecnico_nom,
            "cantidad":              self.spn_cantidad.value(),
            "fecha":                 self.dte_fecha.date().toPyDate(),
            "observaciones_tecnico": obs,
            "equipos":               equipos,
            "id_tipo_servicio":      id_tipo_serv,
            "tipo_servicio_nombre":  tipo_serv_nom,
            "tipo_servicio_mapped":  tipo_servicio_mapped,
            "puntos_apoyo":            puntos_apoyo_val,
            "sucursal_id":             sucursal_id_sel,
            "sucursal_nombre":         sucursal_nom_sel,
            "filas_exactitud":       puntos_exactitud,
            "tipo_estructura":            tipo_estructura,
            "tipo_instalacion_camionera": instalacion_camionera,
            "secciones_camionera":        secciones_camionera,
            "ubicacion_indicador":        ubicacion_indicador,
            "indicador_marca":    indicador_marca,
            "indicador_modelo":   indicador_modelo,
            "indicador_serie":    indicador_serie,
            "indicador_id":       indicador_id_val,
            "cap_maxima":         cap_maxima,
            "div_minima":         div_minima,
            "celdas_mixtas":      celdas_mixtas,
            "celda_a_marca":      celda_a_marca,
            "celda_a_modelo":     celda_a_modelo,
            "celda_a_capacidad":  celda_a_capacidad,
            "celda_a_cantidad":   celda_a_cantidad,
            "celda_b_marca":      celda_b_marca,
            "celda_b_modelo":     celda_b_modelo,
            "celda_b_capacidad":  celda_b_capacidad,
            "celda_b_cantidad":   celda_b_cantidad,
            "items":              self._collect_rma_items() if getattr(self, '_tipo_doc', '') == 'RMA' and hasattr(self, '_collect_rma_items') else [],
            # ── Datos de Calibración (Inicial J/I/A + Número CCA) ─────────────
            "inicial_calibrador":      self._get_inicial_calibrador(),
            "tipo_calibracion_inicial": self._get_inicial_calibrador(),
            "numero_cca":               self._get_numero_cca(),
            # ── Datos específicos LV ───────────────────────────────────────────
            "lv_basculas":        self._lv_collect_basculas() if self._tipo_doc == "LV" else [],
            "lv_pesas":           (
                self.txt_lv_pesas.toPlainText().strip()
                if hasattr(self, "txt_lv_pesas") and self._tipo_doc == "LV" else ""
            ),
            "lv_maniobra":        (
                self.txt_lv_maniobra.toPlainText().strip()
                if hasattr(self, "txt_lv_maniobra") and self._tipo_doc == "LV" else ""
            ),
        }

        # Extraer y asignar el folio exacto escrito por el usuario
        # El campo input_folio_inicial es editable: el valor del usuario SIEMPRE tiene prioridad.
        folio_ingresado = self.input_folio_inicial.text().strip() if hasattr(self, 'input_folio_inicial') else ""
        if not folio_ingresado:
            folio_ingresado = getattr(self, 'folio_sugerido_actual', '')
        if not folio_ingresado:
            # Último recurso: generar uno áhoro mismo
            tipo_doc_fb = getattr(self, '_tipo_doc', 'OS') or 'OS'
            folio_ingresado = self._obtener_siguiente_folio(tipo_doc_fb)
        
        logger.info("[FOLIO] Folio tomado del campo editable: %r", folio_ingresado)
        datos_formato['folio'] = folio_ingresado
        datos_formato['folio_base'] = folio_ingresado

        return datos_formato

    def _reservar_folios(self, datos: dict, estado: str = "PROCESO") -> list[str]:
        """
        Reserva folios consecutivos y crea los registros en BD.

        Usa la función PostgreSQL generate_folio() para garantizar atomicidad
        y consecutividad incluso con múltiples usuarios simultáneos.
        El consecutivo (entero) se persiste junto al texto completo del folio.

        Estado para modal digital: 'ASIGNADA' (válido en chk_os_estado).
        En modo demo retorna folios ficticios para previsualización.
        """
        tipo   = datos["tipo_doc"] or "OS"  # nunca enviar '' a chk_tipo_documento
        anio   = datos["fecha"].year
        cant   = datos["cantidad"]
        anio2  = str(anio)[2:]   # "26" para 2026
        folios: list[str] = []

        if not (_HAS_DB and _db_pool):
            # Modo demo: folios ficticios sin tocar la BD
            base = {"OS": 40, "RMA": 10, "RE": 5}.get(tipo, 1)
            for i in range(cant):
                folios.append(f"{tipo}-{anio2}-{base + i:04d}  [DEMO]")
            return folios

        # Normalizar estado: 'PENDIENTE_DIGITAL' no existe en chk_os_estado;
        # el estado correcto para folios asignados a tablet es 'ASIGNADA'.
        if estado == "PENDIENTE_DIGITAL":
            estado = "ASIGNADA"

        import uuid
        id_lote = str(uuid.uuid4()) if cant > 1 else None
        # rango_lote: se calcula después de conocer folio_base (ver más abajo)
        _rango_lote: str | None = None

        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    # Determinar prefijo y base a partir del folio manual proveído por el usuario.
                    # El campo input_folio_inicial siempre tiene prioridad sobre cualquier valor
                    # calculado automáticamente. Si folio_base está vacío (caso defensivo),
                    # se usa el consecutivo actual de control_folios + 1.
                    folio_base = datos.get("folio_base", "").strip()
                    logger.info("[RESERVAR] folio_base recibido: %r (tipo=%s, cant=%d)",
                                folio_base, tipo, cant)
                    parts = folio_base.split("-")
                    if len(parts) >= 2 and parts[-1].isdigit():
                        consec_base = int(parts[-1])
                        prefix = "-".join(parts[:-1])
                        logger.info("[RESERVAR] Usando folio del usuario: prefix=%r, consec_base=%d",
                                    prefix, consec_base)
                    else:
                        # Folio_base mal formado o vacío: consultar consecutivo actual de BD
                        try:
                            from models.folio_manager import FolioManager
                            consec_base = FolioManager.get_current_consecutivo(tipo, anio) + 1
                        except Exception:
                            consec_base = 1
                        prefix = f"{tipo}-{anio2}"
                        logger.warning("[RESERVAR] folio_base inválido %r, usando consecutivo BD: %s-%d",
                                       folio_base, prefix, consec_base)

                    # Calcular rango_lote una sola vez (antes del loop)
                    if cant > 1:
                        folio_ini = f"{prefix}-{consec_base}"
                        folio_fin = f"{prefix}-{consec_base + cant - 1}"
                        _rango_lote = f"{folio_ini} al {folio_fin}"
                        logger.info("[RESERVAR] rango_lote=%r  id_lote=%s", _rango_lote, id_lote)

                    for i in range(cant):
                        consec = consec_base + i
                        folio = f"{prefix}-{consec}"

                        # Upsert seguro sin ON CONFLICT: verificar si el folio ya existe
                        cur.execute(
                            "SELECT id FROM ordenes_servicio WHERE folio_os = %s",
                            (folio,)
                        )
                        os_existente = cur.fetchone()
                        if not os_existente:
                            # ── Extraer datos del primer equipo (instrumento principal) ──
                            _equipos = datos.get("equipos") or []
                            _eq1 = _equipos[0] if _equipos else {}
                            _marca    = _eq1.get("marca", "").strip() or None
                            _modelo   = _eq1.get("modelo", "").strip() or None
                            _ns       = (_eq1.get("numero_serie") or _eq1.get("ns") or _eq1.get("serie", "")).strip() or None
                            _id_eq    = (_eq1.get("id_indicador") or _eq1.get("id_equipo", "")).strip() or None
                            _ubicacion = (_eq1.get("ubicacion_interna") or _eq1.get("ubicacion", "")).strip() or None
                            _tipo_ins_nombre = _eq1.get("tipo_instrumento", "").strip() or None
                            # capacidad y división: normalizar a numérico
                            def _to_num(v):
                                if v is None: return None
                                try:
                                    return float(str(v).replace(",", ".").replace(" ", "").split()[0])
                                except Exception:
                                    return None
                            _cap_raw  = _eq1.get("capacidad_max") or _eq1.get("capacidad") or ""
                            _div_raw  = _eq1.get("division_min")  or _eq1.get("division")  or ""
                            _cap_num  = _to_num(_cap_raw)
                            _div_num  = _to_num(_div_raw)
                            _cap_str  = str(_cap_raw).strip() or None
                            _div_str  = str(_div_raw).strip() or None
                            # secciones: del eq o del campo general
                            _secciones = datos.get("secciones_camionera") or None
                            if not _secciones:
                                _secciones_raw = _eq1.get("secciones") or _eq1.get("num_secciones")
                                try: _secciones = int(_secciones_raw) if _secciones_raw else None
                                except Exception: _secciones = None
                            # aplica_excentricidad: inferir de tipo instrumento si no hay dato
                            _aplica_exc = datos.get("aplica_excentricidad")
                            if _aplica_exc is None:
                                _tipo_low = (_tipo_ins_nombre or "").lower()
                                _TIPOS_SIN_EXC = ["tolva", "tanque", "silo", "grúa", "grua", "colgante"]
                                _aplica_exc = not any(k in _tipo_low for k in _TIPOS_SIN_EXC)
                            # filas_excentricidad: del campo o por defecto 4 para camionera
                            _filas_exc = datos.get("filas_excentricidad")
                            if not _filas_exc and _secciones:
                                _filas_exc = _secciones
                            cur.execute(
                                """
                                INSERT INTO ordenes_servicio (
                                    folio_os, consecutivo, tipo_documento, modalidad, fecha,
                                    id_tipo_servicio, tipo_servicio, id_cliente, id_tecnico,
                                    observaciones, estado, id_lote, rango_lote,
                                    id_tipo_instrumento, aplica_excentricidad, filas_excentricidad,
                                    tipo_estructura, secciones_camionera, tipo_instalacion_camionera,
                                    marca, modelo, ns, id_equipo, ubicacion,
                                    alcance_max, div_minima,
                                    instrumento_capacidad, instrumento_division,
                                    num_secciones, sucursal_id,
                                    sync_status, updated_at
                                ) VALUES (
                                    %s, %s, %s, %s, %s,
                                    %s, %s, %s, %s,
                                    %s, %s, %s, %s,
                                    %s, %s, %s,
                                    %s, %s, %s,
                                    %s, %s, %s, %s, %s,
                                    %s, %s,
                                    %s, %s,
                                    %s, %s,
                                    %s, NOW()
                                )
                                """,
                                (
                                    folio, consec, tipo,
                                    datos.get("modalidad", "FISICO"),
                                    datos["fecha"],
                                    datos.get("id_tipo_servicio"),
                                    datos.get("tipo_servicio_mapped"),
                                    datos.get("id_cliente"),
                                    datos.get("id_tecnico"),
                                    datos.get("observaciones_tecnico"),
                                    estado, id_lote, _rango_lote,
                                    datos.get("id_tipo_instrumento"),
                                    _aplica_exc,
                                    _filas_exc,
                                    datos.get("tipo_estructura"),
                                    _secciones,
                                    datos.get("tipo_instalacion_camionera"),
                                    # ── datos del instrumento ──
                                    _marca, _modelo, _ns, _id_eq, _ubicacion,
                                    _cap_num, _div_num,
                                    _cap_str, _div_str,
                                    _secciones,
                                    datos.get("sucursal_id"),
                                    datos.get("sync_status", "PENDIENTE"),
                                ),
                            )
                        # Se agrega siempre para que el PDF se genere correctamente
                        folios.append(folio)

                    # Calcular el último consecutivo usado (necesario para control_folios)
                    ultimo_consec_usado = consec_base + cant - 1

                    # Actualizar control_folios sin ON CONFLICT: SELECT + UPDATE/INSERT
                    cur.execute(
                        "SELECT id FROM control_folios WHERE tipo_folio = %s AND anio = %s",
                        (tipo, anio)
                    )
                    cf_row = cur.fetchone()
                    if cf_row:
                        cur.execute(
                            """
                            UPDATE control_folios
                            SET ultimo_consecutivo = GREATEST(ultimo_consecutivo, %s),
                                updated_at = NOW()
                            WHERE tipo_folio = %s AND anio = %s
                            """,
                            (ultimo_consec_usado, tipo, anio)
                        )
                    else:
                        cur.execute(
                            """
                            INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo, updated_at)
                            VALUES (%s, %s, %s, NOW())
                            """,
                            (tipo, anio, ultimo_consec_usado)
                        )
                    logger.info("[RESERVAR] control_folios actualizado: tipo=%s, anio=%s, ultimo_consecutivo=%d",
                                tipo, anio, ultimo_consec_usado)

                conn.commit()
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            logger.error("Error reservando folios: %s", exc)
            raise

        return folios



    def _generar_pdf_lote(self, folios: list[str], datos: dict) -> str:
        """
        Genera un único PDF que contiene todos los folios del lote.
        En modalidad FÍSICO: cada folio aparece 2 veces seguidas (papel calca).
        Las 2 páginas son idénticas, sin marca de agua ni etiqueta.
        Retorna la ruta del PDF generado.
        """
        import pathlib

        output_dir = pathlib.Path(r"C:\PesaServidorCentral\PDF_OS")
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
        except (PermissionError, OSError):
            output_dir = pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS"
            output_dir.mkdir(parents=True, exist_ok=True)

        # Nombre del archivo: lote con el primer y último folio
        nombre = folios[0] if len(folios) == 1 else f"{folios[0]}_a_{folios[-1]}"
        
        pdf_path_obj = output_dir / f"{nombre}.pdf"
        counter = 1
        while pdf_path_obj.exists():
            try:
                with open(pdf_path_obj, "a"):
                    pass
                break
            except (PermissionError, OSError):
                pdf_path_obj = output_dir / f"{nombre}_{counter}.pdf"
                counter += 1
        pdf_path = str(pdf_path_obj)

        equipos = datos.get("equipos", [])

        # ← Obtener la dirección del cliente desde BD
        direccion_cliente = self._get_direccion_cliente(datos.get("id_cliente"))

        tipo_doc = datos.get("tipo_doc", "OS")

        # ── RE: Ficha Técnica Diagnóstica (RePdfGenerator) ────────────────────
        if tipo_doc == "RE":
            from services.re_pdf_generator import re_pdf_generator as _re_gen
            import pathlib, shutil
            # Obtener dirección de sucursal (preferida) o cliente (fallback)
            sucursal_dir_re = self._get_direccion_sucursal(datos.get("sucursal_id")) or direccion_cliente
            tmp_paths = []
            for i, folio in enumerate(folios):
                equipo_data = equipos[i] if i < len(equipos) else (equipos[-1] if equipos else {})
                re_data = {
                    **datos,
                    "folio_re":            folio,
                    "folio_os":            folio,
                    "cliente":             datos.get("cliente", "—"),
                    "direccion":           sucursal_dir_re,
                    "sucursal_direccion":  sucursal_dir_re,
                    "direccion_planta":    sucursal_dir_re,
                    "cliente_direccion":   sucursal_dir_re,
                    "sucursal":            sucursal_dir_re,
                    "tecnico_nombre":      datos.get("tecnico_nombre", ""),
                    **equipo_data,
                }
                tmp = str(output_dir / f"{folio}_tmp.pdf")
                _re_gen.generate(re_data, output_path=tmp)
                tmp_paths.append(tmp)
            if len(tmp_paths) == 1:
                shutil.move(tmp_paths[0], pdf_path)
            else:
                try:
                    from pypdf import PdfWriter, PdfReader
                    writer = PdfWriter()
                    for tmp in tmp_paths:
                        for page in PdfReader(tmp).pages:
                            writer.add_page(page)
                    with open(pdf_path, "wb") as fh:
                        writer.write(fh)
                except ImportError:
                    shutil.copy(tmp_paths[0], pdf_path)
                finally:
                    import os as _os
                    for tmp in tmp_paths:
                        try: _os.remove(tmp)
                        except: pass
            logger.info("PDF RE generado: %s (%d folios)", pdf_path, len(folios))
            return pdf_path

        # ── RMA: Remision de Material (lote calca) ────────────────────────────
        if tipo_doc == "RMA":
            from services.rma_pdf_generator import rma_pdf_generator as _rma_gen
            import shutil as _shutil
            # Obtener dirección de sucursal (preferida) o cliente (fallback)
            sucursal_dir_rma = self._get_direccion_sucursal(datos.get("sucursal_id")) or direccion_cliente
            tmp_paths_rma = []
            is_calca_rma  = self._modalidad == "FISICO"
            for i, folio in enumerate(folios):
                rma_data = {
                    **datos,
                    "folio_rma":           folio,
                    "cliente":             datos.get("cliente", "—"),
                    "direccion":           sucursal_dir_rma,
                    "sucursal_direccion":  sucursal_dir_rma,
                    "direccion_planta":    sucursal_dir_rma,
                    "cliente_direccion":   sucursal_dir_rma,
                    "sucursal":            sucursal_dir_rma,
                    "tecnico_nombre":      datos.get("tecnico_nombre", ""),
                    "items":               datos.get("items", []),
                    "observaciones":       datos.get("observaciones_tecnico", ""),
                    "fecha":               datos.get("fecha"),
                }
                tmp = str(output_dir / f"{folio}_tmp.pdf")
                _rma_gen.generate(rma_data, output_path=tmp, calca=is_calca_rma, force=True)
                tmp_paths_rma.append(tmp)
            if len(tmp_paths_rma) == 1:
                _shutil.move(tmp_paths_rma[0], pdf_path)
            else:
                try:
                    from pypdf import PdfWriter, PdfReader
                    writer = PdfWriter()
                    for tmp in tmp_paths_rma:
                        for page in PdfReader(tmp).pages:
                            writer.add_page(page)
                    with open(pdf_path, "wb") as fh:
                        writer.write(fh)
                except ImportError:
                    _shutil.copy(tmp_paths_rma[0], pdf_path)
                finally:
                    import os as _os
                    for tmp in tmp_paths_rma:
                        try: _os.remove(tmp)
                        except: pass
            logger.info("PDF RMA lote generado: %s (%d folios)", pdf_path, len(folios))
            return pdf_path

        # ── LP: Levantamiento de Proyecto (lote) ──────────────────────────────────
        # NUNCA lleva página duplicada calca, se genera una sola vez.
        if tipo_doc == "LP":
            from services.lp_pdf_generator import LPPdfGenerator
            import pathlib, shutil
            # Obtener dirección de sucursal (preferida) o cliente (fallback)
            sucursal_dir_lp = self._get_direccion_sucursal(datos.get("sucursal_id")) or direccion_cliente
            tmp_paths = []
            for i, folio in enumerate(folios):
                equipo_data = equipos[i] if i < len(equipos) else (equipos[-1] if equipos else {})
                lp_data = {
                    **datos,
                    "folio_os":              folio,
                    "cliente":               datos.get("cliente", "—"),
                    "direccion":             sucursal_dir_lp,
                    "sucursal_direccion":    sucursal_dir_lp,
                    "direccion_planta":      sucursal_dir_lp,
                    "cliente_direccion":     sucursal_dir_lp,
                    "sucursal":              sucursal_dir_lp,
                    "fecha":                 datos.get("fecha"),
                    "id_tipo_servicio":      datos.get("id_tipo_servicio"),
                    "tipo_servicio_nombre":  datos.get("tipo_servicio_nombre", ""),
                    "observaciones":         datos.get("observaciones_tecnico", ""),
                    **equipo_data,
                }
                tmp = str(output_dir / f"{folio}_tmp.pdf")
                gen = LPPdfGenerator()
                gen.generate(lp_data, output_path=tmp, force=True)
                tmp_paths.append(tmp)
            if len(tmp_paths) == 1:
                shutil.move(tmp_paths[0], pdf_path)
            else:
                try:
                    from pypdf import PdfWriter, PdfReader
                    writer = PdfWriter()
                    for tmp in tmp_paths:
                        for page in PdfReader(tmp).pages:
                            writer.add_page(page)
                    with open(pdf_path, "wb") as fh:
                        writer.write(fh)
                except ImportError:
                    shutil.copy(tmp_paths[0], pdf_path)
                finally:
                    import os as _os
                    for tmp in tmp_paths:
                        try: _os.remove(tmp)
                        except: pass
            logger.info("PDF LP lote generado: %s (%d folios)", pdf_path, len(folios))
            return pdf_path

        # ── LV: Levantamiento Metrológico y Logística de Pesas ────────────────
        if tipo_doc == "LV":
            from services.lv_pdf_generator import LvPdfGenerator
            import shutil as _shutil_lv
            # Obtener dirección de sucursal (preferida) o cliente (fallback)
            sucursal_dir_lv = self._get_direccion_sucursal(datos.get("sucursal_id")) or direccion_cliente
            tmp_paths_lv = []
            for folio in folios:
                lv_data = {
                    **datos,
                    "folio_os":             folio,
                    "cliente":              datos.get("cliente", "—"),
                    "direccion":            sucursal_dir_lv,
                    "sucursal_direccion":   sucursal_dir_lv,
                    "direccion_planta":     sucursal_dir_lv,
                    "cliente_direccion":    sucursal_dir_lv,
                    "sucursal":             sucursal_dir_lv,
                    "tecnico_nombre":       datos.get("tecnico_nombre", ""),
                    "fecha":                datos.get("fecha"),
                    "levantamiento_metrologico": {
                        "basculas":              datos.get("lv_basculas", []),
                        "pesas_descripcion":     datos.get("lv_pesas", ""),
                        "acomodo_maniobra":      datos.get("lv_maniobra", ""),
                        "observaciones_generales": datos.get("observaciones_tecnico", ""),
                    },
                }
                tmp = str(output_dir / f"{folio}_tmp.pdf")
                gen = LvPdfGenerator()
                gen.generate(lv_data, output_path=tmp, force=True)
                tmp_paths_lv.append(tmp)
            if len(tmp_paths_lv) == 1:
                _shutil_lv.move(tmp_paths_lv[0], pdf_path)
            else:
                try:
                    from pypdf import PdfWriter, PdfReader
                    writer = PdfWriter()
                    for tmp in tmp_paths_lv:
                        for page in PdfReader(tmp).pages:
                            writer.add_page(page)
                    with open(pdf_path, "wb") as fh:
                        writer.write(fh)
                except ImportError:
                    _shutil_lv.copy(tmp_paths_lv[0], pdf_path)
                finally:
                    import os as _os
                    for tmp in tmp_paths_lv:
                        try: _os.remove(tmp)
                        except: pass
            logger.info("PDF LV lote generado: %s (%d folios)", pdf_path, len(folios))
            return pdf_path

        # ── OS: plantilla calca estandar ──────────────────────────────────────────────
        from services.os_pdf_generator import OsPdfGenerator
        gen = OsPdfGenerator()

        try:
            from reportlab.lib.pagesizes import letter
            from reportlab.pdfgen import canvas as rl_canvas_mod
        except ImportError:
            raise RuntimeError("ReportLab no instalado. Ejecutar: pip install reportlab")

        c = rl_canvas_mod.Canvas(pdf_path, pagesize=letter)

        # Obtener la dirección de la sucursal (más precisa que la del cliente)
        sucursal_dir = self._get_direccion_sucursal(datos.get("sucursal_id"))
        tipo_inst    = datos.get("tipo_instrumento") or datos.get("tipo_instrumento_nombre") or ""
        puntos_apoyo = datos.get("puntos_apoyo") or ""

        # ── Regla de herencia: encontrar la tarjeta con más datos capturados ────
        # Claves del instrumento que determinan si una tarjeta «tiene datos»
        _INST_KEYS = ('marca', 'modelo', 'ns', 'id_equipo', 'alcance_max',
                      'div_minima', 'dve', 'ubicacion', 'equipo_marca')

        def _riqueza(eq_dict: dict) -> int:
            """Cuenta cuántas claves de instrumento no están vacías."""
            return sum(1 for k in _INST_KEYS if str(eq_dict.get(k, '')).strip())

        # Tarjeta de respaldo: la que tenga más campos rellenos
        _fallback_equipo: dict = {}
        if equipos:
            _mejor = max(equipos, key=_riqueza, default=None)
            if _mejor is not None and _riqueza(_mejor) > 0:
                _fallback_equipo = _mejor
            else:
                _fallback_equipo = equipos[0]   # si todas están vacías, usar la primera

        for i, folio in enumerate(folios):
            # Usar la tarjeta propia si tiene datos; si no, heredar la más completa.
            # Casos cubiertos:
            #   a) 1 tarjeta llena + cantidad 16  → todos heredan la tarjeta 1
            #   b) 16 tarjetas, solo algunas llenas → las vacías heredan la mejor
            #   c) Cada tarjeta con su propio equipo → cada folio usa su propia tarjeta
            if equipos and i < len(equipos) and _riqueza(equipos[i]) > 0:
                equipo_data = equipos[i]
            elif _fallback_equipo:
                equipo_data = _fallback_equipo
            else:
                equipo_data = {}

            os_data = {
                # equipo_data primero — los campos explicitos lo sobreescriben
                "folio_os":              folio,
                "cliente":               datos.get("cliente", "—"),
                "direccion":             sucursal_dir or direccion_cliente,
                "sucursal_direccion":    sucursal_dir or direccion_cliente,
                "direccion_cliente":     direccion_cliente,
                # Inyectar nombre de sucursal para que aparezca en la fila DIRECCIÓN
                "sucursal_nombre":       datos.get("sucursal_nombre", ""),
                "fecha":                 datos.get("fecha"),
                "id_tipo_servicio":      datos.get("id_tipo_servicio"),
                "tipo_servicio_nombre":  datos.get("tipo_servicio_nombre", ""),
                "observaciones":         datos.get("observaciones_tecnico", ""),
                "aplica_excentricidad":  datos.get("aplica_excentricidad", True),
                "filas_excentricidad":   datos.get("filas_excentricidad", 5),
                "filas_exactitud":       datos.get("filas_exactitud", 5),
                "tipo_instrumento":      tipo_inst,
                "puntos_apoyo":          puntos_apoyo,
                # ── MODALIDAD: crítico para suprimir diagonales en físico ──────────
                "modalidad":             datos.get("modalidad", "FISICO"),
                # Campos de Calibracion (Inicial J/I/A + CCA) - TODAS las variantes de clave
                "inicial_calibrador":       datos.get("inicial_calibrador", ""),
                "tipo_calibracion_inicial": datos.get("tipo_calibracion_inicial", ""),
                "inicial":                  datos.get("inicial_calibrador", ""),
                "cca":                     datos.get("numero_cca", ""),
                "holograma_anterior":      datos.get("holograma_anterior", ""),
                "holograma_actualizado":   datos.get("holograma_actualizado", ""),
                # Geometria
                "geometria_plataforma":    datos.get("geometria_plataforma"),
                "num_secciones":           datos.get("num_secciones"),
                "tipo_no_aplica_exc":      datos.get("tipo_no_aplica_exc"),
                **(equipo_data or {}),
            }
            # ── Alias de claves: el PDF generator busca ambas variantes ─────────
            _eq_alias = equipo_data or {}
            # N/S: tarjeta exporta 'ns'; PDF también acepta 'serie'
            if not os_data.get('serie'):
                os_data['serie'] = _eq_alias.get('ns') or _eq_alias.get('equipo_ns') or ''
            # ID: tarjeta exporta 'id_equipo'; PDF también busca 'equipo_id'
            if not os_data.get('equipo_id'):
                os_data['equipo_id'] = _eq_alias.get('id_equipo') or ''
            # Capacidad alias
            if not os_data.get('capacidad_max'):
                os_data['capacidad_max'] = _eq_alias.get('alcance_max') or ''
            # División alias
            if not os_data.get('division_min'):
                os_data['division_min'] = _eq_alias.get('div_minima') or ''
            # Post-normalizacion de campos criticos per-equipo
            _ini = (equipo_data or {}).get('inicial_calibrador') or (equipo_data or {}).get('inicial') or datos.get('inicial_calibrador', '')
            _cca = (equipo_data or {}).get('numero_cca') or (equipo_data or {}).get('cca') or datos.get('numero_cca', '')
            os_data['inicial_calibrador']       = _ini
            os_data['tipo_calibracion_inicial'] = _ini
            os_data['inicial']                  = _ini
            os_data['numero_cca']               = _cca
            os_data['cca']                      = _cca
            # Post-normalizacion de hologramas: el valor per-equipo tiene prioridad sobre el de lote
            _holo_ant = (equipo_data or {}).get('holograma_anterior', '') or datos.get('holograma_anterior', '')
            _holo_act = (equipo_data or {}).get('holograma_actualizado', '') or datos.get('holograma_actualizado', '')
            os_data['holograma_anterior']   = _holo_ant
            os_data['holograma_actualizado'] = _holo_act
            if not (equipo_data or {}).get('tipo_instrumento'):
                os_data['tipo_instrumento'] = tipo_inst
            # ── Post-normalización: campos de Tanque / Enlaces de Sustitución ──
            _eq = equipo_data or {}
            if _eq.get('es_enlace_sustitucion'):
                _n_enl = int(_eq.get('num_enlaces_sustitucion') or _eq.get('num_enlaces') or 8)
                os_data['es_enlace_sustitucion']   = True
                os_data['es_sustitucion']          = True
                os_data['num_enlaces_sustitucion'] = _n_enl
                os_data['num_enlaces']             = _n_enl   # alias para el generador
                os_data['aplica_excentricidad']    = False
                os_data['tipo_no_aplica_exc']      = 'tanque'
            # ── Post-normalización: Puntos de Exactitud por instrumento ──────────
            # El valor de equipo_data (per-instrument) tiene prioridad sobre datos (global).
            _pts_equipo = (_eq.get('filas_exactitud') or _eq.get('puntos_exactitud'))
            if _pts_equipo is not None:
                os_data['filas_exactitud'] = int(_pts_equipo)
                os_data['puntos_exactitud'] = int(_pts_equipo)
            logger.debug('[LOTE] folio=%s ini=%r cca=%r geo=%r aplica=%r tipo_no=%r tipo=%r enlaces=%r N=%r',
                folio, _ini, _cca, os_data.get('geometria_plataforma'),
                os_data.get('aplica_excentricidad'), os_data.get('tipo_no_aplica_exc'),
                os_data.get('tipo_instrumento'),
                os_data.get('es_enlace_sustitucion'), os_data.get('num_enlaces_sustitucion'))

            gen._draw_page(c, os_data, [], [], [], datos.get("tecnico_nombre"))
            c.showPage()
            gen._draw_page(c, os_data, [], [], [], datos.get("tecnico_nombre"))
            c.showPage()

        c.save()
        logger.info("PDF lote calca generado: %s (%d folios, %d páginas)",
                    pdf_path, len(folios), len(folios) * 2)
        return pdf_path

    def _generar_pdf_real(self, folio: str, datos: dict,
                           equipo_data: dict = None) -> str:
        """
        Genera el PDF de un solo folio (sin calca).
        Retorna la ruta del PDF generado.
        Funciona tanto en modo conectado a BD como en modo demo.
        """
        import pathlib

        output_dir = pathlib.Path(r"C:\PesaServidorCentral\PDF_OS")
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
        except (PermissionError, OSError):
            output_dir = pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS"
            output_dir.mkdir(parents=True, exist_ok=True)

        pdf_path_obj = output_dir / f"{folio}.pdf"
        counter = 1
        while pdf_path_obj.exists():
            try:
                with open(pdf_path_obj, "a"):
                    pass
                break
            except (PermissionError, OSError):
                pdf_path_obj = output_dir / f"{folio}_{counter}.pdf"
                counter += 1
        pdf_path = str(pdf_path_obj)

        # Obtener direccion del cliente (fallback) y de la sucursal (preferida)
        direccion_cliente = self._get_direccion_cliente(datos.get("id_cliente"))
        sucursal_dir = self._get_direccion_sucursal(datos.get("sucursal_id"))
        tipo_inst    = datos.get("tipo_instrumento") or datos.get("tipo_instrumento_nombre") or ""
        puntos_apoyo = datos.get("puntos_apoyo") or ""

        os_data = {
            "folio_os":              folio,
            "cliente":               datos.get("cliente", "—"),
            "direccion":             sucursal_dir or direccion_cliente,
            "sucursal_direccion":    sucursal_dir or direccion_cliente,
            "direccion_cliente":     direccion_cliente,
            "fecha":                 datos.get("fecha"),
            "id_tipo_servicio":      datos.get("id_tipo_servicio"),
            "tipo_servicio_nombre":  datos.get("tipo_servicio_nombre", ""),
            "observaciones":         datos.get("observaciones_tecnico", ""),
            "aplica_excentricidad":  datos.get("aplica_excentricidad", True),
            "filas_excentricidad":   datos.get("filas_excentricidad", 5),
            "filas_exactitud":       datos.get("filas_exactitud", 5),
            "tipo_instrumento":      tipo_inst,
            "puntos_apoyo":          puntos_apoyo,
            # Calibracion: TODAS las variantes de clave
            "inicial_calibrador":       datos.get("inicial_calibrador", ""),
            "tipo_calibracion_inicial": datos.get("tipo_calibracion_inicial", ""),
            "inicial":                  datos.get("inicial_calibrador", ""),
            "cca":                     datos.get("numero_cca", ""),
            "holograma_anterior":      datos.get("holograma_anterior", ""),
            "holograma_actualizado":   datos.get("holograma_actualizado", ""),
            # Geometria / Excentricidad
            "geometria_plataforma":    datos.get("geometria_plataforma"),
            "num_secciones":           datos.get("num_secciones"),
            "tipo_no_aplica_exc":      datos.get("tipo_no_aplica_exc"),
            **(equipo_data or {}),
        }
        # DEBUG: confirmar que los campos de calibracion llegan al PDF
        print(
            f"[DEBUG PDF] folio={folio} "
            f"inicial={os_data.get('inicial_calibrador')!r} "
            f"cca={os_data.get('numero_cca')!r} "
            f"geo={os_data.get('geometria_plataforma')!r} "
            f"no_aplica={os_data.get('tipo_no_aplica_exc')!r}"
        )

        # ── Post-normalización: enlaces de sustitución ────────────────────────
        # Si el instrumento es Tanque con sustitución, asegurar consistencia
        # de claves entre lo que viene de equipo_data y lo que espera el generador.
        if os_data.get('es_enlace_sustitucion') or os_data.get('es_sustitucion'):
            _n_enl = int(
                os_data.get('num_enlaces_sustitucion')
                or os_data.get('num_enlaces')
                or 8
            )
            os_data['es_enlace_sustitucion']   = True
            os_data['es_sustitucion']          = True
            os_data['num_enlaces_sustitucion'] = _n_enl
            os_data['num_enlaces']             = _n_enl
            os_data['aplica_excentricidad']    = False
            os_data['tipo_no_aplica_exc']      = os_data.get('tipo_no_aplica_exc') or 'tanque'

        # ── RMA: Remision de Material (folio individual) ──────────────────────────
        if datos.get("tipo_doc") == "RMA":
            from services.rma_pdf_generator import rma_pdf_generator as _rma_gen
            is_calca = self._modalidad == "FISICO"
            rma_dir = sucursal_dir or direccion_cliente
            rma_data = {
                **datos,
                "folio_rma":           folio,
                "cliente":             datos.get("cliente", "—"),
                "direccion":           rma_dir,
                "sucursal_direccion":  rma_dir,
                "direccion_planta":    rma_dir,
                "cliente_direccion":   rma_dir,
                "sucursal":            rma_dir,
                "tecnico_nombre":      datos.get("tecnico_nombre", ""),
                "items":               datos.get("items", []),
                "observaciones":       datos.get("observaciones_tecnico", ""),
                "fecha":               datos.get("fecha"),
            }
            _rma_gen.generate(rma_data, output_path=pdf_path, calca=is_calca, force=True)
            logger.info("PDF RMA individual generado: %s", pdf_path)
            return pdf_path

        # ── RE: Revisión de Báscula ───────────────────────────────────────────────
        elif datos.get("tipo_doc") == "RE":
            from services.re_pdf_generator import RePdfGenerator
            gen = RePdfGenerator()
            gen.generate_re_pdf(
                re_data     = os_data,
                output_path = pdf_path,
                tecnico_nombre = datos.get("tecnico_nombre"),
            )
            logger.info("PDF RE generado: %s", pdf_path)
            return pdf_path
            
        # ── LP: Levantamiento de Proyecto ─────────────────────────────────────────
        elif datos.get("tipo_doc") == "LP":
            from services.lp_pdf_generator import LPPdfGenerator
            gen = LPPdfGenerator()
            lp_dir = sucursal_dir or direccion_cliente
            os_data["direccion"]          = lp_dir
            os_data["sucursal_direccion"] = lp_dir
            os_data["direccion_planta"]   = lp_dir
            os_data["cliente_direccion"]  = lp_dir
            os_data["sucursal"]           = lp_dir
            gen.generate(
                os_data     = os_data,
                output_path = pdf_path,
                force       = True
            )
            logger.info("PDF LP generado: %s", pdf_path)
            return pdf_path

        # ── OS: Orden de Servicio (Por Defecto) ───────────────────────────────────
        else:
            from services.os_pdf_generator import OsPdfGenerator
            gen = OsPdfGenerator()
            gen.generate_os_pdf(
                os_data     = os_data,
                output_path = pdf_path,
                tecnico_nombre = datos.get("tecnico_nombre"),
            )
            logger.info("PDF OS generado: %s", pdf_path)
            return pdf_path
        logger.info("PDF generado: %s", pdf_path)
        return pdf_path

    def seleccionar_tipo_documento(self, tipo: str) -> None:
        """
        Selecciona visualmente la tarjeta requerida y despliega sus campos dinámicos.
        Se activa el paso 1 si no está activo, y se selecciona la tarjeta del paso 2.
        """
        # Asegurar que el modal esté activado en Digital por defecto si no hay ninguno
        if not self._card_digital.isChecked() and not self._card_fisico.isChecked():
            self._card_digital.setChecked(True)
            
        # Marcar y activar el formulario correspondiente (el toggled llama a _on_tipo_doc automáticamente)
        if tipo == "OS":
            self._card_os.setChecked(True)
        elif tipo == "RMA":
            self._card_rma.setChecked(True)
        elif tipo == "RE":
            self._card_re.setChecked(True)
        elif tipo == "LP":
            self._card_lp.setChecked(True)
        elif tipo == "LV":
            if hasattr(self, "_card_lv"):
                self._card_lv.setChecked(True)

    def _abrir_pdf_preview(self, pdf_path: str) -> None:
        """
        Abre el PDF con el visor predeterminado del sistema.
        Windows: os.startfile().
        Linux/macOS: subprocess.run(['xdg-open' / 'open', ...])
        """
        import os, sys, subprocess, pathlib

        path = pathlib.Path(pdf_path)
        if not path.exists():
            QMessageBox.warning(self, "PDF no encontrado",
                                f"No se encontró el archivo:\n{pdf_path}")
            return

        try:
            if sys.platform == "win32":
                os.startfile(str(path))          # Abre con el visor PDF de Windows
            elif sys.platform == "darwin":
                subprocess.run(["open", str(path)], check=True)
            else:
                subprocess.run(["xdg-open", str(path)], check=True)
            logger.info("PDF abierto: %s", path)
        except Exception as exc:
            logger.error("Error al abrir PDF: %s", exc)
            QMessageBox.warning(
                self, "No se pudo abrir el PDF",
                f"El PDF fue generado pero no se pudo abrir automáticamente:\n"
                f"{path}\n\nError: {exc}"
            )

    # ══════════════════════════════════════════════════════════════════════════
    # HELPERS
    # ══════════════════════════════════════════════════════════════════════════
    def _enable_card(self, card: QFrame) -> None:
        card.setEnabled(True)
        card.setStyleSheet("""
            QFrame {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.07);
                border-radius: 14px;
            }
        """)

    def _set_loading(self, loading: bool) -> None:
        self._progress.setVisible(loading)
        self.btn_ejecutar.setEnabled(not loading)

    def _reset(self) -> None:
        """Reinicia el asistente a su estado inicial."""
        self._modalidad = ""
        self._tipo_doc  = ""

        # Desmarcar tarjetas de modalidad
        self._card_digital.setChecked(False)
        self._card_fisico.setChecked(False)

        # Desmarcar tarjetas de documento
        for _btn in [self._card_os, self._card_rma, self._card_re, self._card_lp]:
            _btn.setChecked(False)
        if hasattr(self, "_card_lv"):
            self._card_lv.setChecked(False)

        # Resetear parámetros
        self.cmb_cliente.setCurrentIndex(0)
        self.cmb_tecnico.setCurrentIndex(0)
        self.spn_cantidad.setValue(1)
        self.dte_fecha.setDate(QDate.currentDate())
        self.txt_observaciones.clear()
        # Resetear campos de estructura RE
        if hasattr(self, "_frame_re_estructura"):
            self._frame_re_estructura.setVisible(False)
        if hasattr(self, "cmb_tipo_estructura"):
            self.cmb_tipo_estructura.setCurrentIndex(0)
        if hasattr(self, "cmb_instalacion_camionera"):
            self.cmb_instalacion_camionera.setCurrentIndex(0)
        if hasattr(self, "spn_secciones_camionera"):
            self.spn_secciones_camionera.setValue(2)
        # Resetear campos de indicador y celdas RE
        for _attr in [
            "le_ind_marca", "le_ind_modelo", "le_ind_serie", "le_ind_id",
            "le_cap_maxima", "le_div_minima",
            "le_celda_a_marca", "le_celda_a_modelo", "le_celda_a_capacidad",
            "le_celda_b_marca", "le_celda_b_modelo", "le_celda_b_capacidad",
        ]:
            if hasattr(self, _attr):
                getattr(self, _attr).clear()
        if hasattr(self, "spn_celda_a_cantidad"):
            self.spn_celda_a_cantidad.setValue(4)
        if hasattr(self, "spn_celda_b_cantidad"):
            self.spn_celda_b_cantidad.setValue(2)
        if hasattr(self, "cmb_celdas_homogeneas"):
            self.cmb_celdas_homogeneas.setCurrentIndex(0)
        if hasattr(self, "_widget_grupo_b"):
            self._widget_grupo_b.setVisible(False)
        # Resetear controles de calibración
        if hasattr(self, "_frame_calibracion"):
            self._frame_calibracion.setVisible(False)

        # Resetear tarjetas de equipo a 1
        self._update_equipos_section(1)

        # Deshabilitar pasos 2-4
        for card in [self._card_step2, self._card_step3, self._card_step4]:
            card.setEnabled(False)
            card.setStyleSheet("""
                QFrame { background: #FAFAFA; border: 1px solid rgba(0,0,0,0.05);
                         border-radius: 14px; }
            """)

        self.btn_ejecutar.setEnabled(False)
        self.btn_ejecutar.setText("🖨️  Generar e Imprimir PDF")
        self._lbl_title.setText("🖨️  Asistente de Generación de Formatos")
        if hasattr(self, '_lbl_resumen'):
            self._lbl_resumen.setText("")
        # Limpiar folio para que se auto-pueble con el consecutivo real en el próximo ciclo
        if hasattr(self, 'input_folio_inicial'):
            self.input_folio_inicial.blockSignals(True)
            self.input_folio_inicial.clear()
            self.input_folio_inicial.blockSignals(False)
        if hasattr(self, 'lbl_folio_preview'):
            self.lbl_folio_preview.setText("")
        if hasattr(self, '_lbl_modo_badge'):
            self._lbl_modo_badge.setText("")
