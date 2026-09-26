"""
lv_form_widget.py — Formulario para Levantamiento Metrológico y Logística de Pesas (LV).

Características:
  - N tarjetas dinámicas de báscula (agregar / quitar)
  - 8 campos por báscula: ID Tag, Marca, Modelo, Serie, Cap. Máx, Div. Mín., Tipo, Ubicación
  - Sección global de logística de pesas patrón y maniobras
  - ComboBox cliente → sucursal con cascada automática
  - Guardar en BD + generación de PDF
"""
import json
import logging
from datetime import date
from typing import Optional

from PyQt6.QtCore import Qt, pyqtSignal, QDate
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QDateEdit,
    QGroupBox, QFormLayout, QScrollArea, QFrame, QMessageBox,
    QSpinBox, QSizePolicy,
)

from database.connection import db_pool
from models.orden_servicio import orden_servicio_repo

logger = logging.getLogger(__name__)

# ─── Paleta y estilos ──────────────────────────────────────────────────────────
_RED   = "#C8102E"
_DARK  = "#1D1D1F"
_GRAY  = "#86868B"
_BLUE  = "#007AFF"
_BG    = "#F5F5F7"
_WHITE = "#FFFFFF"

_GRP_STYLE = """
    QGroupBox {
        font-weight: bold;
        border: 1px solid #D1D1D6;
        border-radius: 8px;
        margin-top: 10px;
    }
    QGroupBox::title {
        subcontrol-origin: margin;
        left: 10px;
        padding: 0 3px 0 3px;
    }
"""

_FIELD_STYLE = """
    QLineEdit, QComboBox, QTextEdit, QDateEdit, QSpinBox {
        background: #F8FAFC;
        border: 1.5px solid #D1D5DB;
        border-radius: 7px;
        padding: 6px 10px;
        font-size: 12px;
        color: #1D1D1F;
        min-height: 32px;
    }
    QLineEdit:focus, QComboBox:focus, QTextEdit:focus, QDateEdit:focus, QSpinBox:focus {
        border-color: #007AFF;
        background: #FFFFFF;
    }
    QComboBox::drop-down { border: none; width: 24px; }
"""

_TIPOS_INSTRUMENTO = [
    "Báscula Camionera",
    "Báscula de Plataforma",
    "Báscula de Tolva / Tanque",
    "Báscula Analítica / de Precisión",
    "Báscula de Mostrador",
    "Báscula de Gancho / Colgante",
    "Báscula de Piso Industrial",
    "Báscula de Ferrocarril",
    "Báscula de Banda Transportadora",
    "Otro",
]


def _make_le(placeholder: str = "", max_len: int = 200) -> QLineEdit:
    le = QLineEdit()
    le.setPlaceholderText(placeholder)
    le.setMaxLength(max_len)
    le.setStyleSheet(_FIELD_STYLE)
    return le


def _section_lbl(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setStyleSheet(
        f"color:{_RED}; font-size:11px; font-weight:800; "
        "letter-spacing:1.2px; padding:4px 0;"
    )
    return lbl


# ══════════════════════════════════════════════════════════════════════════════
# BásculaCard — Tarjeta dinámica de un instrumento
# ══════════════════════════════════════════════════════════════════════════════
class BasculaCard(QFrame):
    """
    Tarjeta colapsable con 8 campos para capturar los datos de una báscula.
    """
    remove_requested = pyqtSignal(object)  # emite self

    def __init__(self, index: int, parent=None):
        super().__init__(parent)
        self._index = index
        self._expanded = True
        self._build()

    def _build(self) -> None:
        self.setObjectName(f"bascula_card_{self._index}")
        self.setStyleSheet("""
            QFrame {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.08);
                border-radius: 12px;
            }
        """)
        root = QVBoxLayout(self)
        root.setContentsMargins(16, 12, 16, 14)
        root.setSpacing(10)

        # ── Cabecera de la tarjeta ─────────────────────────────────────────────
        header = QHBoxLayout()
        header.setContentsMargins(0, 0, 0, 0)

        badge = QLabel(str(self._index))
        badge.setFixedSize(24, 24)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(
            f"background: {_RED}; color: #FFFFFF; border-radius: 12px; "
            "font-size: 11px; font-weight: 700;"
        )
        header.addWidget(badge)

        lbl = QLabel(f"Báscula {self._index}")
        lbl.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        header.addWidget(lbl, stretch=1)

        self._btn_toggle = QPushButton("−")
        self._btn_toggle.setFixedSize(24, 24)
        self._btn_toggle.setStyleSheet(
            f"QPushButton {{ background: transparent; color: {_GRAY}; border: none; "
            "font-size: 16px; font-weight: 700; }}"
            f"QPushButton:hover {{ color: {_DARK}; }}"
        )
        self._btn_toggle.clicked.connect(self._toggle)
        header.addWidget(self._btn_toggle)

        btn_remove = QPushButton("✕")
        btn_remove.setFixedSize(24, 24)
        btn_remove.setToolTip("Quitar esta báscula")
        btn_remove.setStyleSheet(
            "QPushButton { background: transparent; color: #C0392B; border: none; "
            "font-size: 13px; font-weight: 700; }"
            "QPushButton:hover { color: #E63946; }"
        )
        btn_remove.clicked.connect(lambda: self.remove_requested.emit(self))
        header.addWidget(btn_remove)

        root.addLayout(header)

        # ── Campos editables ──────────────────────────────────────────────────
        self._fields_widget = QWidget()
        self._fields_widget.setStyleSheet("background: transparent;")
        fields_lay = QVBoxLayout(self._fields_widget)
        fields_lay.setContentsMargins(0, 4, 0, 0)
        fields_lay.setSpacing(10)

        # Fila 1: ID Tag · Marca · Modelo · N° de Serie
        row1 = QHBoxLayout()
        row1.setSpacing(12)
        self._inp_id_tag = self._make_field("ID / Tag de Planta", "Ej: BASC-01, TAG-A", row1)
        self._inp_marca  = self._make_field("Marca", "Ej: METTLER TOLEDO", row1)
        self._inp_modelo = self._make_field("Modelo", "Ej: IND560", row1)
        self._inp_serie  = self._make_field("N° de Serie", "Ej: B215004321", row1)
        fields_lay.addLayout(row1)

        # Fila 2: Capacidad Máx · División Mín · Tipo de Instrumento · Ubicación
        row2 = QHBoxLayout()
        row2.setSpacing(12)
        self._inp_cap_max = self._make_field("Capacidad Máxima", "Ej: 60 t / 500 kg", row2)
        self._inp_div_min = self._make_field("División Mínima", "Ej: 20 kg / 50 g", row2)
        # Tipo de instrumento — ComboBox
        col_tipo = QVBoxLayout()
        col_tipo.setSpacing(4)
        lbl_tipo = QLabel("Tipo de Instrumento")
        lbl_tipo.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; "
            "letter-spacing: 0.3px; background: transparent;"
        )
        col_tipo.addWidget(lbl_tipo)
        self._cmb_tipo = QComboBox()
        self._cmb_tipo.addItems(_TIPOS_INSTRUMENTO)
        self._cmb_tipo.setStyleSheet(_FIELD_STYLE)
        col_tipo.addWidget(self._cmb_tipo)
        row2.addLayout(col_tipo, stretch=2)
        # Ubicación interna
        self._inp_ubicacion = self._make_field("Ubicación Interna", "Ej: Nave 2 – Embarques", row2)
        fields_lay.addLayout(row2)

        root.addWidget(self._fields_widget)

    def _make_field(self, label: str, placeholder: str, layout: QHBoxLayout) -> QLineEdit:
        col = QVBoxLayout()
        col.setSpacing(4)
        lbl = QLabel(label)
        lbl.setStyleSheet(
            "font-size: 11px; font-weight: 700; color: #86868B; "
            "letter-spacing: 0.3px; background: transparent;"
        )
        col.addWidget(lbl)
        inp = QLineEdit()
        inp.setPlaceholderText(placeholder)
        inp.setStyleSheet(_FIELD_STYLE)
        inp.setFixedHeight(38)
        col.addWidget(inp)
        layout.addLayout(col, stretch=1)
        return inp

    def _toggle(self) -> None:
        self._expanded = not self._expanded
        self._fields_widget.setVisible(self._expanded)
        self._btn_toggle.setText("−" if self._expanded else "+")

    def update_index(self, new_index: int) -> None:
        """Actualiza el número de badge (usado al reordenar)."""
        self._index = new_index
        # Actualizar badge y etiqueta
        for i in range(self.layout().count()):
            item = self.layout().itemAt(i)
            if item and item.layout():
                hl = item.layout()
                if hl.count() > 0:
                    badge = hl.itemAt(0).widget()
                    if isinstance(badge, QLabel):
                        badge.setText(str(new_index))
                    lbl = hl.itemAt(1).widget()
                    if isinstance(lbl, QLabel):
                        lbl.setText(f"Báscula {new_index}")
                    break

    def get_data(self) -> dict:
        """Retorna los datos de la báscula como diccionario."""
        def v(inp: QLineEdit) -> Optional[str]:
            t = inp.text().strip()
            return t if t else None
        return {
            "id_indicador":     v(self._inp_id_tag),
            "marca":            v(self._inp_marca),
            "modelo":           v(self._inp_modelo),
            "numero_serie":     v(self._inp_serie),
            "capacidad_max":    v(self._inp_cap_max),
            "division_min":     v(self._inp_div_min),
            "tipo_instrumento": self._cmb_tipo.currentText(),
            "ubicacion_interna": v(self._inp_ubicacion),
        }

    def set_data(self, data: dict) -> None:
        """Rellena los campos con datos existentes."""
        self._inp_id_tag.setText(data.get("id_indicador") or "")
        self._inp_marca.setText(data.get("marca") or "")
        self._inp_modelo.setText(data.get("modelo") or "")
        self._inp_serie.setText(data.get("numero_serie") or "")
        self._inp_cap_max.setText(data.get("capacidad_max") or "")
        self._inp_div_min.setText(data.get("division_min") or "")
        tipo = data.get("tipo_instrumento") or ""
        idx = self._cmb_tipo.findText(tipo)
        if idx >= 0:
            self._cmb_tipo.setCurrentIndex(idx)
        self._inp_ubicacion.setText(data.get("ubicacion_interna") or "")


# ══════════════════════════════════════════════════════════════════════════════
# LVFormWidget — Formulario principal
# ══════════════════════════════════════════════════════════════════════════════
class LVFormWidget(QWidget):
    """Formulario completo para Levantamiento Metrológico y Logística de Pesas."""

    os_saved = pyqtSignal(str)  # folio_os

    def __init__(self, os_id: Optional[int] = None, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._os_id   = os_id
        self._is_edit = os_id is not None
        self._folio_os: str = ""

        self._clientes:   list[dict] = []
        self._tecnicos:   list[dict] = []
        self._sucursales: list[dict] = []

        self._bascula_cards: list[BasculaCard] = []

        self._setup_ui()
        self._load_catalogos()

        if self._is_edit:
            self._load_lv(os_id)

    # ── UI ────────────────────────────────────────────────────────────────────

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet(f"QScrollArea {{ background-color: {_BG}; }}")
        root.addWidget(scroll)

        content = QWidget()
        content.setStyleSheet(f"QWidget {{ background-color: {_BG}; }}")
        scroll.setWidget(content)

        main_lay = QVBoxLayout(content)
        main_lay.setContentsMargins(24, 20, 24, 40)
        main_lay.setSpacing(18)

        # ── Encabezado ────────────────────────────────────────────────────────
        hdr = QHBoxLayout()
        title = QLabel("Levantamiento Metrológico y Logística de Pesas (LV)")
        title.setStyleSheet(
            "font-size: 22px; font-weight: 700; color: #1D1D1F; letter-spacing: -0.5px;"
        )
        hdr.addWidget(title)
        hdr.addStretch()
        self._lbl_folio = QLabel("NUEVO LV")
        self._lbl_folio.setStyleSheet(
            "font-size: 15px; font-weight: 700; color: #C8102E; "
            "padding: 4px 10px; background: #FFE5E5; border-radius: 6px;"
        )
        hdr.addWidget(self._lbl_folio)
        main_lay.addLayout(hdr)

        sub = QLabel("Pre-Visita · Identificación de Instrumentos · Planeación Logística")
        sub.setStyleSheet(f"font-size: 12px; color: {_GRAY};")
        main_lay.addWidget(sub)

        # ── Bloque 1: Datos del Cliente ───────────────────────────────────────
        gb_cli = QGroupBox("1. DATOS DEL CLIENTE Y FECHA")
        gb_cli.setStyleSheet(_GRP_STYLE)
        form_cli = QFormLayout(gb_cli)
        form_cli.setSpacing(10)
        form_cli.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
        form_cli.setStyleSheet(_FIELD_STYLE)

        self._cmb_cliente = QComboBox()
        self._cmb_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        form_cli.addRow("Cliente:", self._cmb_cliente)

        self._cmb_sucursal = QComboBox()
        self._cmb_sucursal.setEnabled(False)
        self._cmb_sucursal.addItem("— Seleccionar sucursal —", None)
        self._cmb_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)
        form_cli.addRow("Sucursal / Planta:", self._cmb_sucursal)

        self._lbl_suc_dir = QLabel("")
        self._lbl_suc_dir.setStyleSheet(
            "color: #86868B; font-size: 10px; font-style: italic;"
        )
        self._lbl_suc_dir.setWordWrap(True)
        form_cli.addRow("", self._lbl_suc_dir)

        self._cmb_tecnico = QComboBox()
        form_cli.addRow("Técnico Responsable:", self._cmb_tecnico)

        self._date_fecha = QDateEdit()
        self._date_fecha.setCalendarPopup(True)
        self._date_fecha.setDate(QDate.currentDate())
        form_cli.addRow("Fecha del Levantamiento:", self._date_fecha)

        main_lay.addWidget(gb_cli)

        # ── Bloque 2: Lista de Básculas Dinámicas ─────────────────────────────
        gb_basc = QGroupBox("2. BÁSCULAS IDENTIFICADAS EN PLANTA")
        gb_basc.setStyleSheet(_GRP_STYLE)
        lay_basc = QVBoxLayout(gb_basc)
        lay_basc.setSpacing(12)

        # Contador de básculas
        row_cnt = QHBoxLayout()
        lbl_cnt = QLabel("Cantidad de básculas a levantar:")
        lbl_cnt.setStyleSheet(f"font-weight: 700; color: {_DARK};")
        row_cnt.addWidget(lbl_cnt)

        self._spn_cantidad = QSpinBox()
        self._spn_cantidad.setRange(1, 50)
        self._spn_cantidad.setValue(1)
        self._spn_cantidad.setFixedWidth(80)
        self._spn_cantidad.setStyleSheet(_FIELD_STYLE + "QSpinBox { min-height: 32px; }")
        row_cnt.addWidget(self._spn_cantidad)

        btn_set = QPushButton("Establecer cantidad")
        btn_set.setStyleSheet(
            f"background: {_BLUE}; color: white; font-weight: 700; "
            "padding: 7px 14px; border-radius: 7px; border: none;"
        )
        btn_set.clicked.connect(self._set_bascula_count)
        row_cnt.addWidget(btn_set)

        btn_add = QPushButton("＋ Agregar Báscula")
        btn_add.setStyleSheet(
            "background: #F0F4FF; color: #007AFF; font-weight: 700; "
            "padding: 7px 14px; border-radius: 7px; border: 1.5px solid #007AFF;"
        )
        btn_add.clicked.connect(lambda: self._add_bascula_card())
        row_cnt.addWidget(btn_add)
        row_cnt.addStretch()
        lay_basc.addLayout(row_cnt)

        # Contenedor scroll de tarjetas
        self._cards_container = QWidget()
        self._cards_container.setStyleSheet(f"background: {_BG};")
        self._cards_layout = QVBoxLayout(self._cards_container)
        self._cards_layout.setContentsMargins(0, 0, 0, 0)
        self._cards_layout.setSpacing(10)
        self._cards_layout.addStretch()
        lay_basc.addWidget(self._cards_container)

        # Agregar la primera tarjeta por defecto
        self._add_bascula_card()

        main_lay.addWidget(gb_basc)

        # ── Bloque 3: Logística de Pesas Patrón ───────────────────────────────
        gb_log = QGroupBox("3. RECOMENDACIÓN LOGÍSTICA DE PESAS PATRÓN Y MANIOBRAS")
        gb_log.setStyleSheet(
            _GRP_STYLE + """
            QGroupBox {
                border-color: #C8102E;
                background: rgba(200,16,46,0.03);
            }
            """
        )
        form_log = QFormLayout(gb_log)
        form_log.setSpacing(12)
        form_log.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
        form_log.setStyleSheet(_FIELD_STYLE)

        self._le_pesas = QLineEdit()
        self._le_pesas.setPlaceholderText(
            "Ej: 2 ton pesas paralelepípedas + 6 pesas cilíndricas 20 kg clase M1"
        )
        self._le_pesas.setMaxLength(400)
        self._le_pesas.setStyleSheet(_FIELD_STYLE)
        form_log.addRow("Cantidad / Tipo de Pesas:", self._le_pesas)

        self._txt_maniobra = QTextEdit()
        self._txt_maniobra.setPlaceholderText(
            "Ej: Se requiere montacargas del cliente (Cap. mín. 3 ton) para maniobra de pesas. "
            "Acceso por Puerta Sur – Nave 1. Sin canastilla disponible."
        )
        self._txt_maniobra.setFixedHeight(85)
        self._txt_maniobra.setStyleSheet(_FIELD_STYLE)
        form_log.addRow("Acomodo y Maniobra de Pesas:", self._txt_maniobra)

        self._txt_obs_generales = QTextEdit()
        self._txt_obs_generales.setPlaceholderText(
            "Observaciones generales del sitio: condiciones del área, acceso, riesgos, "
            "requerimientos especiales de seguridad, EPP necesario, etc."
        )
        self._txt_obs_generales.setFixedHeight(85)
        self._txt_obs_generales.setStyleSheet(_FIELD_STYLE)
        form_log.addRow("Observaciones Técnicas del Sitio:", self._txt_obs_generales)

        main_lay.addWidget(gb_log)

        # ── Barra de acciones inferior ────────────────────────────────────────
        bottom_bar = QFrame()
        bottom_bar.setStyleSheet("background: white; border-top: 1px solid #E5E5EA;")
        bot_lay = QHBoxLayout(bottom_bar)
        bot_lay.setContentsMargins(20, 12, 20, 12)
        bot_lay.setSpacing(12)

        self._btn_cancel = QPushButton("Cancelar")
        self._btn_cancel.setStyleSheet(
            "padding: 8px 16px; border-radius: 7px; border: 1px solid #D1D1D6; "
            "background: white; color: #1D1D1F;"
        )
        self._btn_cancel.clicked.connect(self._on_cancel)

        self._btn_pdf = QPushButton("📄 Generar PDF")
        self._btn_pdf.setStyleSheet(
            "background: #E5E5EA; color: #1D1D1F; font-weight: 700; "
            "padding: 8px 18px; border-radius: 7px; border: none;"
        )
        self._btn_pdf.clicked.connect(self._generate_pdf)
        self._btn_pdf.setEnabled(self._is_edit)

        self._btn_save = QPushButton("💾 Guardar LV")
        self._btn_save.setStyleSheet(
            f"background: {_RED}; color: white; font-weight: 700; "
            "padding: 8px 20px; border-radius: 7px; border: none;"
        )
        self._btn_save.clicked.connect(self._on_save)

        bot_lay.addStretch()
        bot_lay.addWidget(self._btn_cancel)
        bot_lay.addWidget(self._btn_pdf)
        bot_lay.addWidget(self._btn_save)
        root.addWidget(bottom_bar)

    # ── Tarjetas dinámicas ────────────────────────────────────────────────────

    def _add_bascula_card(self, data: Optional[dict] = None) -> BasculaCard:
        """Agrega una tarjeta de báscula al contenedor."""
        idx = len(self._bascula_cards) + 1
        card = BasculaCard(index=idx)
        card.remove_requested.connect(self._remove_bascula_card)
        if data:
            card.set_data(data)
        # Insertar antes del stretch (último item)
        insert_pos = max(0, self._cards_layout.count() - 1)
        self._cards_layout.insertWidget(insert_pos, card)
        self._bascula_cards.append(card)
        self._spn_cantidad.setValue(len(self._bascula_cards))
        return card

    def _remove_bascula_card(self, card: BasculaCard) -> None:
        """Quita una tarjeta del formulario y reordena los badges."""
        if len(self._bascula_cards) <= 1:
            QMessageBox.information(self, "Mínimo", "Debe haber al menos 1 báscula.")
            return
        self._cards_layout.removeWidget(card)
        card.setParent(None)
        card.deleteLater()
        self._bascula_cards.remove(card)
        # Reasignar índices
        for i, c in enumerate(self._bascula_cards, start=1):
            c.update_index(i)
        self._spn_cantidad.setValue(len(self._bascula_cards))

    def _set_bascula_count(self) -> None:
        """Ajusta el número de tarjetas al valor del SpinBox."""
        target = self._spn_cantidad.value()
        current = len(self._bascula_cards)
        if target > current:
            for _ in range(target - current):
                self._add_bascula_card()
        elif target < current:
            # Remover desde el final
            while len(self._bascula_cards) > max(1, target):
                card = self._bascula_cards[-1]
                self._cards_layout.removeWidget(card)
                card.setParent(None)
                card.deleteLater()
                self._bascula_cards.pop()

    # ── Catálogos ─────────────────────────────────────────────────────────────

    def _load_catalogos(self) -> None:
        try:
            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, razon_social FROM cat_clientes WHERE activo=TRUE ORDER BY razon_social"
                )
                self._clientes = [{"id": r[0], "razon_social": r[1]} for r in cur.fetchall()]
                cur.execute(
                    "SELECT id, nombre_completo FROM cat_tecnicos WHERE activo=TRUE ORDER BY nombre_completo"
                )
                self._tecnicos = [{"id": r[0], "nombre": r[1]} for r in cur.fetchall()]
            db_pool.release_connection(conn)
        except Exception as exc:
            logger.error("Error cargando catálogos LV: %s", exc)

        self._cmb_cliente.clear()
        self._cmb_cliente.addItem("— Seleccione Cliente —", None)
        for c in self._clientes:
            self._cmb_cliente.addItem(c["razon_social"], c["id"])

        self._cmb_tecnico.clear()
        self._cmb_tecnico.addItem("— Seleccione Técnico —", None)
        for t in self._tecnicos:
            self._cmb_tecnico.addItem(t["nombre"], t["id"])

    def _on_cliente_changed(self) -> None:
        self._cmb_sucursal.blockSignals(True)
        self._cmb_sucursal.clear()
        self._cmb_sucursal.addItem("— Seleccionar sucursal —", None)
        self._lbl_suc_dir.clear()
        self._sucursales = []
        self._cmb_sucursal.setEnabled(False)

        c_id = self._cmb_cliente.currentData()
        if c_id:
            try:
                from models.catalogo import sucursal_repo
                self._sucursales = sucursal_repo.get_by_cliente(c_id)
                for s in self._sucursales:
                    self._cmb_sucursal.addItem(
                        f"{s['nombre_sucursal']}  —  {s['direccion'][:45]}", s["id"]
                    )
                self._cmb_sucursal.setEnabled(True)
            except Exception as exc:
                logger.error("Error cargando sucursales LV: %s", exc)
        self._cmb_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, _: int) -> None:
        s_id = self._cmb_sucursal.currentData()
        self._lbl_suc_dir.clear()
        if s_id:
            suc = next((s for s in self._sucursales if s["id"] == s_id), None)
            if suc:
                self._lbl_suc_dir.setText(suc.get("direccion") or "")

    # ── Carga de LV existente ─────────────────────────────────────────────────

    def _load_lv(self, os_id: int) -> None:
        data = orden_servicio_repo.get_by_id(os_id)
        if not data:
            return

        self._folio_os = data.get("folio_os", "")
        self._lbl_folio.setText(self._folio_os)

        idx_c = self._cmb_cliente.findData(data.get("id_cliente"))
        if idx_c >= 0:
            self._cmb_cliente.setCurrentIndex(idx_c)

        sucursal_id = data.get("sucursal_id")
        if sucursal_id:
            idx_s = self._cmb_sucursal.findData(sucursal_id)
            if idx_s >= 0:
                self._cmb_sucursal.setCurrentIndex(idx_s)

        idx_t = self._cmb_tecnico.findData(data.get("id_tecnico"))
        if idx_t >= 0:
            self._cmb_tecnico.setCurrentIndex(idx_t)

        d = data.get("fecha")
        if d:
            self._date_fecha.setDate(QDate(d.year, d.month, d.day))

        lv = data.get("levantamiento_metrologico") or {}
        basculas = lv.get("basculas", [])

        # Limpiar tarjetas actuales
        while self._bascula_cards:
            card = self._bascula_cards[-1]
            self._cards_layout.removeWidget(card)
            card.setParent(None)
            card.deleteLater()
            self._bascula_cards.pop()

        # Restaurar tarjetas
        if basculas:
            for b in basculas:
                self._add_bascula_card(b)
        else:
            self._add_bascula_card()

        self._le_pesas.setText(lv.get("pesas_descripcion") or "")
        self._txt_maniobra.setPlainText(lv.get("acomodo_maniobra") or "")
        self._txt_obs_generales.setPlainText(lv.get("observaciones_generales") or "")
        self._btn_pdf.setEnabled(True)

    # ── Guardar ───────────────────────────────────────────────────────────────

    def _on_save(self) -> None:
        c_id = self._cmb_cliente.currentData()
        if not c_id:
            QMessageBox.warning(self, "Error", "Debe seleccionar un Cliente.")
            return

        # Recolectar datos de básculas
        basculas = [card.get_data() for card in self._bascula_cards]
        # Filtrar tarjetas completamente vacías
        basculas = [
            b for b in basculas
            if any(v for v in b.values() if v)
        ]

        lv_data = {
            "basculas":              basculas,
            "pesas_descripcion":     self._le_pesas.text().strip() or None,
            "acomodo_maniobra":      self._txt_maniobra.toPlainText().strip() or None,
            "observaciones_generales": self._txt_obs_generales.toPlainText().strip() or None,
        }

        payload = {
            "fecha":               self._date_fecha.date().toPyDate(),
            "id_cliente":          c_id,
            "sucursal_id":         self._cmb_sucursal.currentData(),
            "id_tecnico":          self._cmb_tecnico.currentData(),
            "ubicacion":           self._lbl_suc_dir.text().strip(),
            "direccion":           self._lbl_suc_dir.text().strip(),
            "sucursal_direccion":  self._lbl_suc_dir.text().strip(),
            "observaciones":       self._txt_obs_generales.toPlainText().strip(),
            "estado":              "PROCESO",
            # Campos de OS no aplican para LV
            "id_tipo_servicio":    1,
            "id_equipo":           None,
            "id_tipo_instrumento": None,
            "numero_cca":          None,
            "holograma_anterior":  None,
            "holograma_actualizado": None,
            "valor_repetibilidad": None,
            "valor_excentricidad": None,
            "id_clase_exactitud":  None,
            "firma_cliente_nombre": None,
            "marca": None, "modelo": None, "ns": None,
            "alcance_max": None, "div_minima": None, "div_verificacion": None,
            "levantamiento_metrologico": lv_data,
        }

        try:
            if self._is_edit:
                res = orden_servicio_repo.update(self._os_id, payload)
            else:
                res = orden_servicio_repo.create(payload)

            folio = res.get("folio_os", "")
            self.os_saved.emit(folio)
            self._is_edit = True
            self._os_id = res.get("id")
            self._folio_os = folio
            self._lbl_folio.setText(folio)
            self._btn_pdf.setEnabled(True)

            QMessageBox.information(
                self, "LV Guardado",
                f"✅ Levantamiento guardado correctamente.\nFolio: {folio}\n"
                f"Básculas registradas: {len(basculas)}"
            )
        except Exception as exc:
            logger.exception("Error guardando LV")
            QMessageBox.critical(self, "Error", f"Fallo al guardar:\n{exc}")

    # ── Cancelar ─────────────────────────────────────────────────────────────

    def _on_cancel(self) -> None:
        parent = self.parent()
        while parent and not hasattr(parent, "_navigate"):
            parent = parent.parent()
        if parent:
            parent._navigate("dashboard")

    # ── Generar PDF ───────────────────────────────────────────────────────────

    def _generate_pdf(self) -> None:
        if not self._os_id:
            QMessageBox.warning(
                self, "Sin LV", "Guarde primero el levantamiento para poder generar el PDF."
            )
            return

        try:
            from services.lv_pdf_generator import LvPdfGenerator
            import os

            os_data = orden_servicio_repo.get_by_id(self._os_id)
            if not os_data:
                QMessageBox.warning(self, "Error", "No se encontraron los datos del LV.")
                return

            # Enriquecer con datos del formulario
            os_data["tecnico_nombre"] = self._cmb_tecnico.currentText()
            os_data["cliente_nombre"] = self._cmb_cliente.currentText()
            addr = self._lbl_suc_dir.text().strip()
            if addr:
                os_data["direccion"]         = addr
                os_data["sucursal_direccion"] = addr

            self._btn_pdf.setEnabled(False)
            self._btn_pdf.setText("Generando…")

            gen = LvPdfGenerator()
            path = gen.generate(os_data=os_data, force=True)

            QMessageBox.information(
                self, "PDF Generado",
                f"PDF generado exitosamente:\n{path}\n\nSe abrirá con el visor predeterminado."
            )

            if os.name == "nt":
                os.startfile(path)
        except Exception as exc:
            logger.error("Error al generar PDF LV: %s", exc)
            QMessageBox.critical(self, "Error PDF", f"No se pudo generar el PDF:\n{exc}")
        finally:
            self._btn_pdf.setEnabled(True)
            self._btn_pdf.setText("📄 Generar PDF")
