"""
Formulario principal de Orden de Servicio.
Replica fielmente el layout del formato físico "Toma de Datos".
Soporta modo Crear (os_id=None) y modo Editar (os_id=int).
"""
import logging
from datetime import date
from typing import Optional

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QDateEdit, QDoubleSpinBox,
    QGroupBox, QFormLayout, QScrollArea, QFrame, QMessageBox,
    QSizePolicy, QAbstractSpinBox, QCompleter,
)
from PyQt6.QtCore import Qt, pyqtSignal, QDate, QStringListModel
from PyQt6.QtGui import QFont, QColor

from ui.widgets.pruebas_metrologicas import PruebasMetrologicasWidget

logger = logging.getLogger(__name__)


def _make_line_edit(placeholder: str = "", max_len: int = 200) -> QLineEdit:
    le = QLineEdit()
    le.setPlaceholderText(placeholder)
    le.setMaxLength(max_len)
    return le


def _section_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setStyleSheet(
        "color:#E63946; font-size:11px; font-weight:800; "
        "letter-spacing:1.2px; padding:4px 0;"
    )
    return lbl


class OSFormWidget(QWidget):
    """
    Formulario completo de Orden de Servicio.
    Contiene todas las secciones del formato físico:
        1. Encabezado (Folio, Fecha, Tipo de Servicio)
        2. Cliente y Dirección
        3. Datos del Equipo
        4. Pruebas Metrológicas (Repetibilidad, Excentricidad, Exactitud)
        5. Observaciones
        6. Técnico y Firma del Cliente

    Señales:
        os_saved(str): Emitida con el folio de la OS cuando se guarda exitosamente.
    """

    os_saved = pyqtSignal(str)   # folio_os

    def __init__(
        self,
        os_id: Optional[int] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        super().__init__(parent)
        self._os_id   = os_id
        self._is_edit = os_id is not None
        self._folio_os: str = ""

        # Datos de catálogos (se cargan desde BD)
        self._clientes:          list[dict] = []
        self._sucursales:        list[dict] = []
        self._equipos_cat:       list[dict] = []
        self._tecnicos:          list[dict] = []
        self._tipos_servicio:    list[dict] = []
        self._tipos_instrumento: list[dict] = []
        self._clases_exactitud:  list[dict] = []

        self._setup_ui()
        self._load_catalogos()

        if self._is_edit:
            self._load_os(os_id)

    def showEvent(self, event) -> None:
        super().showEvent(event)
        # Solo recargar catálogos si el formulario está en modo nuevo.
        # En modo edición, recargar los catálogos sobreescribe los combos cargados
        # en _load_os() y borra los valores seleccionados (marca, serie, etc.).
        if not self._is_edit:
            self._load_catalogos()

    # ── UI Setup ──────────────────────────────────────────────────────────────

    def _on_aplica_exc_changed(self) -> None:
        """Sincroniza el combo del encabezado con ExcentricidadCondicionalWidget interno."""
        aplica = self._combo_aplica_exc.currentText() in ("SI", "SÍ")
        self._wgt_filas_exc.setVisible(aplica)

        exc_widget = self._pruebas_widget.excentricidad
        if aplica:
            filas = int(self._combo_filas_exc.currentText())
            exc_widget.set_excentricidad_config(True, filas)
        else:
            exc_widget.set_excentricidad_config(False, 0)

    def _setup_ui(self) -> None:
        # Layout raíz: scroll area + barra inferior de acciones
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Área con scroll para el formulario
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        form_container = QWidget()
        form_layout = QVBoxLayout(form_container)
        form_layout.setContentsMargins(28, 20, 28, 20)
        form_layout.setSpacing(20)

        # Secciones del formulario
        form_layout.addLayout(self._build_header_section())
        form_layout.addWidget(self._build_separator())
        form_layout.addWidget(self._build_cliente_section())
        form_layout.addWidget(self._build_equipo_section())
        form_layout.addWidget(self._build_pruebas_section())
        form_layout.addWidget(self._build_observaciones_section())
        form_layout.addWidget(self._build_firmas_section())
        form_layout.addStretch()

        scroll.setWidget(form_container)
        root.addWidget(scroll)

        # Barra de acciones
        root.addWidget(self._build_action_bar())

    # ── Sección 1: Encabezado ─────────────────────────────────────────────────
    def _build_header_section(self) -> QHBoxLayout:
        layout = QHBoxLayout()

        # Izquierda: título + fecha + tipo de servicio
        left = QVBoxLayout()
        left.setSpacing(10)

        title_lbl = QLabel("TOMA DE DATOS / ORDEN DE SERVICIO")
        title_lbl.setStyleSheet("font-size:18px; font-weight:900; color:#1D1D1F; letter-spacing:1px;")
        left.addWidget(title_lbl)

        sub_lbl = QLabel("Básculas PESA — Pesaje Sistemas y Automatización")
        sub_lbl.setStyleSheet("color:#86868B; font-size:12px;")
        left.addWidget(sub_lbl)

        left.addSpacing(8)

        # Fecha
        fecha_row = QHBoxLayout()
        fecha_row.setSpacing(8)
        fecha_row.addWidget(QLabel("FECHA:"))
        self._date_edit = QDateEdit(QDate.currentDate())
        self._date_edit.setCalendarPopup(True)
        self._date_edit.setDisplayFormat("dd / MM / yyyy")
        self._date_edit.setFixedWidth(160)
        fecha_row.addWidget(self._date_edit)
        fecha_row.addSpacing(20)

        fecha_row.addWidget(QLabel("TIPO DE SERVICIO:"))
        self._combo_tipo_servicio = QComboBox()
        self._combo_tipo_servicio.setFixedWidth(250)
        # Conectar cambio de tipo de servicio para actualizar visibilidad de campos
        self._combo_tipo_servicio.currentIndexChanged.connect(self._on_tipo_servicio_changed)
        fecha_row.addWidget(self._combo_tipo_servicio)
        fecha_row.addStretch()
        left.addLayout(fecha_row)

        layout.addLayout(left, stretch=1)

        # Derecha: Panel de Folio
        folio_panel = QWidget()
        folio_panel.setFixedSize(200, 80)
        folio_panel.setStyleSheet(
            "background:#FFFFFF; border:2px solid #E63946; border-radius:8px;"
        )
        fp_layout = QVBoxLayout(folio_panel)
        fp_layout.setContentsMargins(12, 8, 12, 8)
        fp_layout.setSpacing(2)

        lbl_folio_title = QLabel("FOLIO / OS")
        lbl_folio_title.setStyleSheet("color:#86868B; font-size:10px; font-weight:700; letter-spacing:1px;")
        lbl_folio_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        fp_layout.addWidget(lbl_folio_title)

        self._lbl_folio = QLabel("— NUEVO —" if not self._is_edit else "Cargando...")
        self._lbl_folio.setStyleSheet("color:#E63946; font-size:20px; font-weight:900; letter-spacing:2px;")
        self._lbl_folio.setAlignment(Qt.AlignmentFlag.AlignCenter)
        fp_layout.addWidget(self._lbl_folio)

        layout.addWidget(folio_panel)
        return layout

    # ── Sección 2: Cliente ────────────────────────────────────────────────────
    def _build_cliente_section(self) -> QGroupBox:
        grp = QGroupBox("CLIENTE Y DIRECCIÓN")
        layout = QFormLayout(grp)
        layout.setSpacing(10)
        layout.setLabelAlignment(Qt.AlignmentFlag.AlignRight)

        # ── Combo Cliente ──────────────────────────────────────────────────────
        self._combo_cliente = QComboBox()
        self._combo_cliente.setEditable(True)
        self._combo_cliente.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        self._combo_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        layout.addRow("Cliente:", self._combo_cliente)

        # ── Combo Sucursal / Planta ────────────────────────────────────────────
        self._combo_sucursal = QComboBox()
        self._combo_sucursal.setEditable(False)
        self._combo_sucursal.setEnabled(False)
        self._combo_sucursal.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._combo_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)
        layout.addRow("Sucursal / Planta:", self._combo_sucursal)

        # ── Dirección (autocompleta desde sucursal) ────────────────────────────
        self._txt_direccion = QLineEdit()
        self._txt_direccion.setPlaceholderText("Dirección (se autocompleta al elegir planta)")
        self._txt_direccion.setReadOnly(True)
        self._txt_direccion.setStyleSheet(
            "QLineEdit { background:#F5F5F7; color:#86868B; }"
        )
        layout.addRow("Dirección:", self._txt_direccion)

        return grp

    # ── Sección 3: Datos del Equipo ───────────────────────────────────────────
    # ── Sección 3: Datos del Equipo ───────────────────────────────────────────
    def _build_equipo_section(self) -> QGroupBox:
        grp = QGroupBox("DATOS DEL EQUIPO / BÁSCULA")
        main = QVBoxLayout(grp)
        main.setSpacing(16)

        # Fila 1: Selector principal y botón de nuevo/limpiar
        top_row = QHBoxLayout()
        top_row.setSpacing(12)
        
        lbl_cat = QLabel("Báscula Registrada:")
        lbl_cat.setStyleSheet("color:#1D1D1F; font-size:12px; font-weight:700;")
        top_row.addWidget(lbl_cat)
        
        self._combo_equipo_cat = QComboBox()
        self._combo_equipo_cat.setEditable(False)
        self._combo_equipo_cat.setEnabled(False)
        self._combo_equipo_cat.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._combo_equipo_cat.setToolTip("Selecciona una báscula para autocompletar, o elige 'Sin datos' para registrar una nueva.")
        self._combo_equipo_cat.currentIndexChanged.connect(self._on_equipo_cat_changed)
        top_row.addWidget(self._combo_equipo_cat, stretch=1)
        
        self._btn_limpiar_equipo = QPushButton("+ Nuevo Instrumento")
        self._btn_limpiar_equipo.setStyleSheet("background:#E63946; color:white; border-radius:6px; font-weight:bold;")
        self._btn_limpiar_equipo.clicked.connect(self._limpiar_campos_equipo)
        top_row.addWidget(self._btn_limpiar_equipo)
        
        top_row.addStretch()
        main.addLayout(top_row)
        
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("background:#E5E5EA; max-height:1px;")
        main.addWidget(sep)

        # Grid de 3 Columnas para los datos
        from PyQt6.QtWidgets import QGridLayout
        grid = QGridLayout()
        grid.setSpacing(12)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        grid.setColumnStretch(2, 1)

        def grid_field(label: str, widget: QWidget, row: int, col: int) -> None:
            lyt = QVBoxLayout()
            lyt.setSpacing(4)
            lbl = QLabel(label)
            lbl.setStyleSheet("color:#86868B; font-size:11px; font-weight:bold; letter-spacing:0.5px;")
            lyt.addWidget(lbl)
            lyt.addWidget(widget)
            grid.addLayout(lyt, row, col)

        def make_spin(decimals: int = 4) -> QDoubleSpinBox:
            sb = QDoubleSpinBox()
            sb.setDecimals(decimals)
            sb.setRange(0, 9_999_999)
            sb.setSpecialValueText(" ")
            sb.setValue(0)
            sb.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
            sb.setStyleSheet("QDoubleSpinBox { background:#F8FAFC; border:1px solid #D1D5DB; border-radius:6px; padding:6px; }")
            return sb

        # Instanciar inputs
        # ── ID INDICADOR / TAG: QComboBox editable con autocompletado ──────────
        self._txt_id_equipo = QComboBox()
        self._txt_id_equipo.setEditable(True)
        self._txt_id_equipo.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        self._txt_id_equipo.lineEdit().setPlaceholderText("Ej. ALMR-02, CIT-MIT…")
        self._txt_id_equipo.setToolTip(
            "Selecciona un Tag/ID de la lista o escribe uno nuevo.\n"
            "Se autocompleta al elegir una planta."
        )
        # Completer para búsqueda instantánea mientras se escribe
        self._id_equipo_model = QStringListModel([])
        self._id_equipo_completer = QCompleter(self._id_equipo_model)
        self._id_equipo_completer.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
        self._id_equipo_completer.setFilterMode(Qt.MatchFlag.MatchContains)
        self._id_equipo_completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        self._txt_id_equipo.setCompleter(self._id_equipo_completer)
        # Señal: al activar un ítem del desplegable → autocompletar otros campos
        self._txt_id_equipo.activated.connect(self._on_id_equipo_changed)
        self._txt_id_equipo.setStyleSheet(
            "QComboBox { background:#F8FAFC; border:1px solid #D1D5DB;"
            " border-radius:6px; padding:6px; }"
        )
        self._txt_marca           = _make_line_edit("Ej. Rice Lake", 100)
        self._txt_modelo          = _make_line_edit("Ej. IQ355", 100)
        
        self._txt_ns              = _make_line_edit("Número de Serie", 100)
        self._spin_alcance_max    = make_spin(2)
        self._spin_div_minima     = make_spin(4)
        
        self._combo_tipo_instrumento = QComboBox()
        self._combo_tipo_instrumento.setStyleSheet("QComboBox { background:#F8FAFC; border:1px solid #D1D5DB; border-radius:6px; padding:6px; }")
        self._txt_ubicacion       = _make_line_edit("Ej. Almacén 2", 200)
        self._spin_div_verificacion = make_spin(4)

        # Fila 1 del Grid
        grid_field("ID INDICADOR / TAG", self._txt_id_equipo, 0, 0)
        grid_field("MARCA", self._txt_marca, 0, 1)
        grid_field("MODELO", self._txt_modelo, 0, 2)
        
        # Fila 2 del Grid
        grid_field("NÚMERO DE SERIE", self._txt_ns, 1, 0)
        grid_field("CAPACIDAD MÁXIMA (kg)", self._spin_alcance_max, 1, 1)
        grid_field("DIVISIÓN MÍNIMA (d)", self._spin_div_minima, 1, 2)
        
        # Fila 3 del Grid
        grid_field("TIPO DE INSTRUMENTO", self._combo_tipo_instrumento, 2, 0)
        grid_field("UBICACIÓN INTERNA", self._txt_ubicacion, 2, 1)
        grid_field("DIVISIÓN VERIF. (e)", self._spin_div_verificacion, 2, 2)

        main.addLayout(grid)
        
        sep2 = QFrame()
        sep2.setFrameShape(QFrame.Shape.HLine)
        sep2.setStyleSheet("background:#E5E5EA; max-height:1px;")
        main.addWidget(sep2)

        # Fila Extra: Excentricidad y Hologramas
        row3 = QHBoxLayout()
        row3.setSpacing(16)
        
        # Excentricidad Controls
        self._combo_aplica_exc = QComboBox()
        self._combo_aplica_exc.addItems(["SÍ", "NO"])
        self._combo_aplica_exc.setFixedWidth(80)
        self._combo_aplica_exc.currentIndexChanged.connect(self._on_aplica_exc_changed)
        
        self._combo_filas_exc = QComboBox()
        self._combo_filas_exc.addItems(["3", "4", "5", "6"])
        self._combo_filas_exc.setCurrentText("5")
        self._combo_filas_exc.setFixedWidth(80)
        self._combo_filas_exc.currentIndexChanged.connect(self._on_aplica_exc_changed)
        
        lyt_aplica = QVBoxLayout()
        lyt_aplica.setSpacing(4)
        lbl_aplica = QLabel("APLICA EXCENTRICIDAD")
        lbl_aplica.setStyleSheet("color:#86868B; font-size:11px; font-weight:bold;")
        lyt_aplica.addWidget(lbl_aplica)
        lyt_aplica.addWidget(self._combo_aplica_exc)
        row3.addLayout(lyt_aplica)
        
        self._wgt_filas_exc = QWidget()
        lyt_filas = QVBoxLayout(self._wgt_filas_exc)
        lyt_filas.setContentsMargins(0, 0, 0, 0)
        lyt_filas.setSpacing(4)
        lbl_filas = QLabel("FILAS EXCENTRICIDAD")
        lbl_filas.setStyleSheet("color:#86868B; font-size:11px; font-weight:bold;")
        lyt_filas.addWidget(lbl_filas)
        lyt_filas.addWidget(self._combo_filas_exc)
        row3.addWidget(self._wgt_filas_exc)

        row3.addStretch()

        self._txt_numero_cca        = _make_line_edit("Nº CCA", 100)
        self._txt_numero_cca.setFixedWidth(180)
        self._wgt_cca = QWidget()
        lyt_cca = QVBoxLayout(self._wgt_cca)
        lyt_cca.setContentsMargins(0, 0, 0, 0)
        lyt_cca.addWidget(QLabel("NÚMERO CCA"))
        lyt_cca.addWidget(self._txt_numero_cca)
        row3.addWidget(self._wgt_cca)

        self._txt_holograma_anterior = _make_line_edit("Código holograma", 100)
        self._txt_holograma_anterior.setFixedWidth(180)
        self._wgt_holo_ant = QWidget()
        lyt_h_ant = QVBoxLayout(self._wgt_holo_ant)
        lyt_h_ant.setContentsMargins(0, 0, 0, 0)
        lyt_h_ant.addWidget(QLabel("HOLOGRAMA ANT."))
        lyt_h_ant.addWidget(self._txt_holograma_anterior)
        row3.addWidget(self._wgt_holo_ant)

        self._txt_holograma_actualizado = _make_line_edit("Nuevo holograma", 100)
        self._txt_holograma_actualizado.setFixedWidth(180)
        self._wgt_holo_act = QWidget()
        lyt_h_act = QVBoxLayout(self._wgt_holo_act)
        lyt_h_act.setContentsMargins(0, 0, 0, 0)
        lyt_h_act.addWidget(QLabel("HOLOGRAMA ACT."))
        lyt_h_act.addWidget(self._txt_holograma_actualizado)
        row3.addWidget(self._wgt_holo_act)

        main.addLayout(row3)
        return grp

    # ── Sección 4: Pruebas Metrológicas ───────────────────────────────────────
    def _build_pruebas_section(self) -> QGroupBox:
        grp = QGroupBox("PRUEBAS METROLÓGICAS")
        layout = QVBoxLayout(grp)
        layout.setSpacing(0)

        self._pruebas_widget = PruebasMetrologicasWidget()
        layout.addWidget(self._pruebas_widget)
        return grp

    # ── Sección 5: Observaciones ──────────────────────────────────────────────
    def _build_observaciones_section(self) -> QGroupBox:
        grp = QGroupBox("OBSERVACIONES")
        layout = QVBoxLayout(grp)

        self._txt_observaciones = QTextEdit()
        self._txt_observaciones.setPlaceholderText(
            "Observaciones técnicas, condiciones del servicio, recomendaciones..."
        )
        self._txt_observaciones.setFixedHeight(90)
        layout.addWidget(self._txt_observaciones)
        return grp

    # ── Sección 6: Técnico y Firma ────────────────────────────────────────────
    def _build_firmas_section(self) -> QGroupBox:
        grp = QGroupBox("TÉCNICO RESPONSABLE Y FIRMA DEL CLIENTE")
        layout = QHBoxLayout(grp)
        layout.setSpacing(24)

        # Técnico
        left = QFormLayout()
        left.setSpacing(10)
        self._combo_tecnico = QComboBox()
        self._combo_tecnico.setFixedWidth(280)
        left.addRow("Técnico Responsable:", self._combo_tecnico)
        layout.addLayout(left)

        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.VLine)
        sep.setStyleSheet("color:#D1D1D6;")
        layout.addWidget(sep)

        # Firma del cliente
        right = QFormLayout()
        right.setSpacing(10)
        self._txt_firma_cliente = _make_line_edit("Nombre completo de quien recibe", 200)
        self._txt_firma_cliente.setFixedWidth(280)
        right.addRow("Nombre y Firma del Cliente:", self._txt_firma_cliente)
        layout.addLayout(right)

        layout.addStretch()
        return grp

    # ── Barra de Acciones ─────────────────────────────────────────────────────
    def _build_action_bar(self) -> QWidget:
        bar = QWidget()
        bar.setFixedHeight(56)
        bar.setStyleSheet("background:#F2F2F7; border-top:1px solid #D1D1D6;")

        layout = QHBoxLayout(bar)
        layout.setContentsMargins(24, 8, 24, 8)
        layout.setSpacing(10)

        btn_limpiar = QPushButton("↺  Limpiar")
        btn_limpiar.setFixedWidth(110)
        btn_limpiar.clicked.connect(self._clear_form)
        layout.addWidget(btn_limpiar)

        layout.addStretch()

        btn_cancelar = QPushButton("✖  Cancelar")
        btn_cancelar.setFixedWidth(110)
        btn_cancelar.setProperty("class", "danger")
        btn_cancelar.clicked.connect(self._clear_form)
        layout.addWidget(btn_cancelar)

        self._btn_pdf = QPushButton("📄  Generar PDF")
        self._btn_pdf.setFixedWidth(140)
        self._btn_pdf.setEnabled(self._is_edit)
        self._btn_pdf.clicked.connect(self._generate_pdf)
        layout.addWidget(self._btn_pdf)

        self._btn_guardar = QPushButton(
            "💾  Actualizar OS" if self._is_edit else "💾  Guardar OS"
        )
        self._btn_guardar.setFixedWidth(160)
        self._btn_guardar.setProperty("class", "primary")
        self._btn_guardar.clicked.connect(self._save)
        layout.addWidget(self._btn_guardar)

        return bar

    @staticmethod
    def _build_separator() -> QFrame:
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("background:#D1D1D6; max-height:1px;")
        return sep

    # ── Carga de Catálogos ────────────────────────────────────────────────────

    def _load_catalogos(self) -> None:
        """Carga todos los catálogos desde la BD y llena los ComboBox."""
        try:
            from models.catalogo import (
                cliente_repo, tecnico_repo,
                tipo_servicio_repo, tipo_instrumento_repo,
            )
            self._clientes          = cliente_repo.get_all()
            self._tecnicos          = tecnico_repo.get_all()
            self._tipos_servicio    = tipo_servicio_repo.get_all()
            self._tipos_instrumento = tipo_instrumento_repo.get_all()

        except Exception as exc:
            logger.error(f"Error al cargar catálogos: {exc}")
    # ── Carga de OS existente (modo edición) ──────────────────────────────────

    def _load_os(self, os_id: int) -> None:
        """Carga los datos de una OS existente en el formulario."""
        try:
            from models.orden_servicio import orden_servicio_repo

            os_data = orden_servicio_repo.get_by_id(os_id)
            if not os_data:
                QMessageBox.warning(self, "Error", f"No se encontró la OS con ID={os_id}")
                return

            # Intentar enriquecer con datos_tecnicos_json si campos del equipo vienen NULL
            # (ocurre con OS antiguas importadas o creadas antes de v18)
            _snapshot: dict = {}
            try:
                import json as _json
                raw_snap = os_data.get("datos_tecnicos_json") or ""
                if raw_snap:
                    _snapshot = _json.loads(raw_snap)
            except Exception:
                _snapshot = {}

            def _field(key: str, fallback_key: str = ""):
                """Devuelve el valor de os_data; si es None/vacío, intenta el snapshot."""
                val = os_data.get(key)
                if val is None or val == "":
                    val = _snapshot.get(key)
                if val is None and fallback_key:
                    val = _snapshot.get(fallback_key)
                return val

            # Folio
            self._folio_os = os_data.get("folio_os", "")
            self._lbl_folio.setText(self._folio_os)

            # Fecha
            fecha = os_data.get("fecha")
            if fecha:
                self._date_edit.setDate(QDate(fecha.year, fecha.month, fecha.day))

            # ── Cascada controlada (sin disparar señales intermedias) ──────────
            # Paso 1: Seleccionar Cliente (bloqueando señal para evitar _on_cliente_changed)
            id_cliente = os_data.get("id_cliente")
            self._combo_cliente.blockSignals(True)
            self._set_combo_by_id(self._combo_cliente, id_cliente)
            self._combo_cliente.blockSignals(False)

            # Paso 2: Cargar sucursales del cliente directamente (sin señal)
            self._combo_sucursal.blockSignals(True)
            self._combo_sucursal.clear()
            self._combo_sucursal.addItem("— Seleccionar sucursal / planta —", None)
            self._sucursales = []
            if id_cliente:
                try:
                    from models.catalogo import sucursal_repo
                    self._sucursales = sucursal_repo.get_by_cliente(id_cliente)
                    for s in self._sucursales:
                        self._combo_sucursal.addItem(s["nombre_sucursal"], s["id"])
                    self._combo_sucursal.setEnabled(bool(self._sucursales))
                except Exception as exc_suc:
                    logger.warning("Error cargando sucursales en _load_os: %s", exc_suc)

            # Paso 3: Seleccionar sucursal
            sucursal_id = os_data.get("sucursal_id")
            self._set_combo_by_id(self._combo_sucursal, sucursal_id)
            self._combo_sucursal.blockSignals(False)

            # Autocompletar dirección de la sucursal seleccionada
            if sucursal_id:
                suc = next((s for s in self._sucursales if s.get("id") == sucursal_id), None)
                if suc:
                    self._txt_direccion.setText(suc.get("direccion") or "")

            # Paso 4: Cargar equipos de la sucursal directamente (sin señal)
            self._combo_equipo_cat.blockSignals(True)
            self._combo_equipo_cat.clear()
            self._combo_equipo_cat.addItem("— Sin datos / Equipo no registrado —", None)
            self._equipos_cat = []
            if sucursal_id:
                try:
                    from models.catalogo import equipo_sucursal_repo
                    self._equipos_cat = equipo_sucursal_repo.get_by_sucursal(sucursal_id)
                    for eq in self._equipos_cat:
                        tag   = eq.get("id_indicador_equipo") or ""
                        ns    = eq.get("numero_serie") or ""
                        marca = eq.get("marca") or ""
                        label = f"{tag}  —  {marca}  N/S: {ns}".strip(" — ")
                        self._combo_equipo_cat.addItem(label, eq["id"])
                    self._combo_equipo_cat.setEnabled(True)
                except Exception as exc_eq:
                    logger.warning("Error cargando equipos en _load_os: %s", exc_eq)

            # Paso 5: Seleccionar equipo del catálogo
            self._set_combo_by_id(self._combo_equipo_cat, os_data.get("equipo_catalogo_id"))
            self._combo_equipo_cat.blockSignals(False)

            # ── Resto de combos simples ───────────────────────────────────────
            self._set_combo_by_id(self._combo_tipo_servicio, os_data.get("id_tipo_servicio"))
            self._set_combo_by_id(self._combo_tipo_instrumento, os_data.get("id_tipo_instrumento"))

            aplica_exc = os_data.get("aplica_excentricidad")
            if aplica_exc is not None:
                self._combo_aplica_exc.setCurrentText("SI" if aplica_exc else "NO")
            if os_data.get("filas_excentricidad"):
                self._combo_filas_exc.setCurrentText(str(os_data["filas_excentricidad"]))

            # Restaurar geometria y motivo de no aplicacion
            exc_widget = self._pruebas_widget.excentricidad
            geo = os_data.get("geometria_plataforma", "")
            if geo:
                exc_widget.set_geometria_plataforma(
                    geo, os_data.get("num_secciones", 4)
                )
            tipo_no = os_data.get("tipo_no_aplica_exc", "")
            if tipo_no:
                exc_widget.set_tipo_no_aplica(tipo_no)

            self._on_aplica_exc_changed()
            self._set_combo_by_id(self._combo_tecnico, os_data.get("id_tecnico"))

            # ── Datos del equipo (texto libre) ────────────────────────────────
            self._txt_marca.setText(_field("marca") or "")
            self._txt_modelo.setText(_field("modelo") or "")
            self._txt_ns.setText(_field("ns") or "")
            self._txt_ubicacion.setText(_field("ubicacion") or "")
            # Restaurar ID INDICADOR en el combo
            id_equipo_val = os_data.get("id_equipo") or ""
            self._txt_id_equipo.blockSignals(True)
            found_id = False
            for i in range(self._txt_id_equipo.count()):
                eq_dat = self._txt_id_equipo.itemData(i)
                if eq_dat and next(
                    (e for e in self._equipos_cat if e.get("id") == eq_dat
                     and (e.get("id_indicador_equipo") or "") == id_equipo_val), None
                ):
                    self._txt_id_equipo.setCurrentIndex(i)
                    found_id = True
                    break
            if not found_id:
                self._txt_id_equipo.lineEdit().setText(id_equipo_val)
            self._txt_id_equipo.blockSignals(False)
            self._txt_numero_cca.setText(os_data.get("numero_cca") or "")
            self._txt_holograma_anterior.setText(os_data.get("holograma_anterior") or "")
            self._txt_holograma_actualizado.setText(os_data.get("holograma_actualizado") or "")

            # Recuperar campos numéricos con fallback al snapshot
            if _field("alcance_max") is not None:
                self._spin_alcance_max.setValue(float(_field("alcance_max")))
            if _field("div_minima") is not None:
                self._spin_div_minima.setValue(float(_field("div_minima")))
            if _field("div_verificacion") is not None:
                self._spin_div_verificacion.setValue(float(_field("div_verificacion")))

            # ── Observaciones y firma ─────────────────────────────────────────
            self._txt_observaciones.setPlainText(_field("observaciones") or "")
            self._txt_firma_cliente.setText(_field("firma_cliente_nombre") or "")

            # ── Pruebas metrológicas ──────────────────────────────────────────
            # Usar datos_tecnicos_json como fuente de verdad para repetibilidad,
            # excentricidad y exactitud si los campos del snapshot están disponibles
            rep_snap  = _snapshot.get("repetibilidad")  if _snapshot else None
            exc_snap  = _snapshot.get("excentricidad")  if _snapshot else None
            exac_snap = _snapshot.get("exactitud")      if _snapshot else None

            self._pruebas_widget.set_all_data(
                repetibilidad=rep_snap  if rep_snap  is not None else os_data.get("repetibilidad", []),
                excentricidad=exc_snap  if exc_snap  is not None else os_data.get("excentricidad", []),
                exactitud=exac_snap     if exac_snap is not None else os_data.get("exactitud", []),
                tipo_instrumento=_field("tipo_instrumento"),
                numero_celdas=_field("numero_celdas"),
                valor_repetibilidad=_field("valor_repetibilidad"),
                valor_excentricidad=_field("valor_excentricidad"),
                clase_exactitud=_field("id_clase_exactitud"),
                indicadores_jia=(
                    _field("indicadores_jia")
                    or {"J": False, "I": False, "A": False}
                ),
                aplica_excentricidad=_field("aplica_excentricidad"),
                filas_excentricidad=_field("filas_excentricidad"),
            )

            logger.info(f"OS ID={os_id} cargada en el formulario: {self._folio_os}")

        except Exception as exc:
            logger.error(f"Error al cargar OS ID={os_id}: {exc}")
            QMessageBox.critical(self, "Error", f"No se pudo cargar la OS:\n{exc}")

    # ── Slots ─────────────────────────────────────────────────────────────────

    def _on_cliente_changed(self, index: int) -> None:
        """Al cambiar cliente: carga sus sucursales y resetea combos dependientes."""
        cliente_id = self._combo_cliente.currentData()

        # Limpiar combo de sucursal
        self._combo_sucursal.blockSignals(True)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal / planta —", None)
        self._sucursales = []

        # Limpiar combo de equipo
        self._combo_equipo_cat.blockSignals(True)
        self._combo_equipo_cat.clear()
        self._combo_equipo_cat.addItem("— Sin datos / Equipo no registrado —", None)
        self._equipos_cat = []
        self._combo_equipo_cat.setEnabled(False)
        self._combo_equipo_cat.blockSignals(False)

        self._txt_direccion.clear()

        if cliente_id:
            try:
                from models.catalogo import sucursal_repo
                self._sucursales = sucursal_repo.get_by_cliente(cliente_id)
            except Exception as exc:
                logger.warning("No se pudieron cargar sucursales: %s", exc)
                self._sucursales = []

            for s in self._sucursales:
                self._combo_sucursal.addItem(s["nombre_sucursal"], s["id"])

            self._combo_sucursal.setEnabled(bool(self._sucursales))
        else:
            self._combo_sucursal.setEnabled(False)

        self._combo_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, index: int) -> None:
        """Al cambiar sucursal: autocompleta dirección y carga equipos de esa planta."""
        sucursal_id = self._combo_sucursal.currentData()

        # Limpiar combo de equipo
        self._combo_equipo_cat.blockSignals(True)
        self._combo_equipo_cat.clear()
        self._combo_equipo_cat.addItem("— Sin datos / Equipo no registrado —", None)
        self._equipos_cat = []

        if sucursal_id:
            # Autocompletar dirección desde la sucursal
            suc = next((s for s in self._sucursales if s.get("id") == sucursal_id), None)
            if suc:
                self._txt_direccion.setText(suc.get("direccion") or "")

            # Cargar equipos de la sucursal
            try:
                from models.catalogo import equipo_sucursal_repo
                self._equipos_cat = equipo_sucursal_repo.get_by_sucursal(sucursal_id)
            except Exception as exc:
                logger.warning("No se pudieron cargar equipos: %s", exc)
                self._equipos_cat = []

            for eq in self._equipos_cat:
                tag   = eq.get("id_indicador_equipo") or ""
                ns    = eq.get("numero_serie") or ""
                marca = eq.get("marca") or ""
                label = f"{tag}  —  {marca}  N/S: {ns}".strip(" — ")
                self._combo_equipo_cat.addItem(label, eq["id"])

            self._combo_equipo_cat.setEnabled(True)

            # ── Poblar combo ID INDICADOR / TAG ──────────────────────────────
            self._populate_id_equipo_combo()
        else:
            self._txt_direccion.clear()
            self._combo_equipo_cat.setEnabled(False)
            self._txt_id_equipo.blockSignals(True)
            self._txt_id_equipo.clear()
            self._txt_id_equipo.lineEdit().setPlaceholderText("Ej. ALMR-02, CIT-MIT…")
            self._txt_id_equipo.blockSignals(False)

        self._combo_equipo_cat.blockSignals(False)

    def _populate_id_equipo_combo(self) -> None:
        """
        Rellena el QComboBox de ID INDICADOR con los equipos de la sucursal
        actualmente cargada. Llama solo después de actualizar self._equipos_cat.
        """
        self._txt_id_equipo.blockSignals(True)
        current_text = self._txt_id_equipo.lineEdit().text()
        self._txt_id_equipo.clear()
        self._txt_id_equipo.addItem("", None)          # ítem vacío/placeholder
        tag_list: list[str] = []
        for eq in self._equipos_cat:
            tag   = eq.get("id_indicador_equipo") or ""
            ns    = eq.get("numero_serie") or ""
            marca = eq.get("marca") or ""
            # Label compacto en el desplegable: TAG — Marca (N/S: ...)
            label = tag
            if marca:
                label += f"  —  {marca}"
            if ns:
                label += f"  (N/S: {ns[:12]})"
            self._txt_id_equipo.addItem(label.strip(), eq["id"])
            if tag:
                tag_list.append(tag)
        # Actualizar completer con solo los Tags para búsqueda rápida
        self._id_equipo_model.setStringList(tag_list)
        # Restaurar texto previo si el usuario ya había escrito algo
        if current_text:
            self._txt_id_equipo.lineEdit().setText(current_text)
        else:
            self._txt_id_equipo.lineEdit().setPlaceholderText(
                f"{len(self._equipos_cat)} básculas disponibles — escribe o selecciona"
            )
        self._txt_id_equipo.blockSignals(False)

    def _on_id_equipo_changed(self, index: int) -> None:
        """
        Slot disparado cuando el usuario SELECCIONA un ítem del combo
        ID INDICADOR / TAG (por clic o autocompletado).
        Sincroniza con _combo_equipo_cat y autocompleta los campos del equipo.
        """
        equipo_id = self._txt_id_equipo.itemData(index)
        if not equipo_id:
            return

        # Buscar el equipo en la lista cargada
        eq = next((e for e in self._equipos_cat if e.get("id") == equipo_id), None)
        if not eq:
            return

        # Sincronizar el selector principal "Báscula Registrada"
        self._combo_equipo_cat.blockSignals(True)
        for i in range(self._combo_equipo_cat.count()):
            if self._combo_equipo_cat.itemData(i) == equipo_id:
                self._combo_equipo_cat.setCurrentIndex(i)
                break
        self._combo_equipo_cat.blockSignals(False)

        # Autocompletar todos los campos del instrumento
        self._txt_marca.setText(eq.get("marca") or "")
        self._txt_modelo.setText(eq.get("modelo") or "")
        self._txt_ns.setText(eq.get("numero_serie") or "")
        self._txt_ubicacion.setText(eq.get("ubicacion_interna") or "")

        # Capacidad y División
        import re as _re
        cap_str = eq.get("capacidad_maxima") or ""
        div_str = eq.get("division_minima") or ""
        cap_match = _re.search(r"[\d.,]+", str(cap_str).replace(",", "."))
        div_match = _re.search(r"[\d.,]+", str(div_str).replace(",", "."))
        if cap_match:
            try:
                self._spin_alcance_max.setValue(float(cap_match.group()))
            except ValueError:
                pass
        if div_match:
            try:
                self._spin_div_minima.setValue(float(div_match.group()))
            except ValueError:
                pass

        # Tipo de instrumento si está disponible
        tipo_inst = eq.get("tipo_instrumento")
        if tipo_inst:
            idx = self._combo_tipo_instrumento.findData(tipo_inst)
            if idx >= 0:
                self._combo_tipo_instrumento.setCurrentIndex(idx)

        logger.debug("ID Equipo seleccionado: %s / %s", eq.get("id_indicador_equipo"), eq.get("numero_serie"))

    def _limpiar_campos_equipo(self) -> None:
        """Limpia los campos del grid de instrumento para captura manual."""
        self._combo_equipo_cat.setCurrentIndex(0)
        self._txt_marca.clear()
        self._txt_modelo.clear()
        self._txt_ns.clear()
        self._txt_ubicacion.clear()
        self._txt_id_equipo.blockSignals(True)
        self._txt_id_equipo.setCurrentIndex(0)
        self._txt_id_equipo.lineEdit().clear()
        self._txt_id_equipo.blockSignals(False)
        self._spin_alcance_max.setValue(0)
        self._spin_div_minima.setValue(0)
        self._spin_div_verificacion.setValue(0)
        self._combo_tipo_instrumento.setCurrentIndex(0)

    def _on_equipo_cat_changed(self, index: int) -> None:
        """Al seleccionar un equipo del catálogo: autocompleta Marca/Modelo/N/S/Capacidad/Div.Mín."""
        equipo_id = self._combo_equipo_cat.currentData()
        if not equipo_id:
            self._limpiar_campos_equipo()
            return  # "— Sin datos —" seleccionado

        eq = next((e for e in self._equipos_cat if e.get("id") == equipo_id), None)
        if not eq:
            return

        # Autocompletar campos del equipo inmediatamente
        self._txt_marca.setText(eq.get("marca") or "")
        self._txt_modelo.setText(eq.get("modelo") or "")
        self._txt_ns.setText(eq.get("numero_serie") or "")
        self._txt_ubicacion.setText(eq.get("ubicacion_interna") or "")
        # Sincronizar combo ID INDICADOR
        tag = eq.get("id_indicador_equipo") or ""
        self._txt_id_equipo.blockSignals(True)
        for i in range(self._txt_id_equipo.count()):
            if self._txt_id_equipo.itemData(i) == equipo_id:
                self._txt_id_equipo.setCurrentIndex(i)
                break
        else:
            self._txt_id_equipo.lineEdit().setText(tag)
        self._txt_id_equipo.blockSignals(False)

        # Configurar tipo instrumento si está disponible
        tipo_inst = eq.get("tipo_instrumento")
        if tipo_inst:
            idx = self._combo_tipo_instrumento.findData(tipo_inst)
            if idx >= 0:
                self._combo_tipo_instrumento.setCurrentIndex(idx)

        # Capacidad máxima → spin alcance_max (extraer número)
        cap_str = eq.get("capacidad_maxima") or ""
        div_str = eq.get("division_minima") or ""
        import re as _re
        cap_match = _re.search(r"[\d.,]+", str(cap_str).replace(",", "."))
        div_match = _re.search(r"[\d.,]+", str(div_str).replace(",", "."))
        if cap_match:
            try:
                self._spin_alcance_max.setValue(float(cap_match.group()))
            except ValueError:
                pass
        if div_match:
            try:
                self._spin_div_minima.setValue(float(div_match.group()))
            except ValueError:
                pass

        logger.debug("Equipo autocompleted: %s / %s", eq.get("marca"), eq.get("numero_serie"))

    def _on_tipo_servicio_changed(self, _index: int) -> None:
        """
        Actualiza la visibilidad de los campos CCA / Holograma Anterior /
        Holograma Actualizado según el tipo de servicio seleccionado.
        Implementa la matriz de reglas de negocios de tipo_servicio_rules.
        """
        try:
            from services.tipo_servicio_rules import get_rules
            id_tipo = self._combo_tipo_servicio.currentData()
            rules = get_rules(id_tipo)
        except Exception:
            # Si no se pueden obtener las reglas, mostrar todo
            return

        # Mostrar/ocultar campos según las reglas
        self._wgt_cca.setVisible(rules.pide_cca)
        self._wgt_holo_ant.setVisible(rules.pide_holograma_anterior)
        self._wgt_holo_act.setVisible(rules.pide_holograma_actualizado)

        # Si el tipo requiere CCA, agregar indicador visual (tooltip EMA)
        if rules.pide_cca:
            self._txt_numero_cca.setToolTip(
                "Solo técnicos con acreditación EMA pueden ser signatarios del CCA."
            )
        else:
            self._txt_numero_cca.setToolTip("")

    def _save(self) -> None:
        """Valida y guarda la OS en la base de datos."""
        # Validaciones básicas
        if not self._combo_cliente.currentData():
            QMessageBox.warning(self, "Validación", "Debe seleccionar un cliente.")
            self._combo_cliente.setFocus()
            return
        if not self._combo_tipo_servicio.currentData():
            QMessageBox.warning(self, "Validación", "Debe seleccionar el tipo de servicio.")
            return
        if not self._txt_firma_cliente.text().strip():
            QMessageBox.warning(self, "Validación", "El Nombre y Firma del Cliente (quien recibe) es obligatorio.")
            self._txt_firma_cliente.setFocus()
            return

        # Recopilar datos
        pruebas = self._pruebas_widget.get_all_data()
        fecha_qdate = self._date_edit.date()

        data = {
            "fecha": date(fecha_qdate.year(), fecha_qdate.month(), fecha_qdate.day()),
            "id_tipo_servicio":    self._combo_tipo_servicio.currentData(),
            "id_cliente":          self._combo_cliente.currentData(),
            "sucursal_id":         self._combo_sucursal.currentData(),
            "equipo_catalogo_id":  self._combo_equipo_cat.currentData(),
            "id_tecnico":          self._combo_tecnico.currentData(),
            "id_tipo_instrumento": self._combo_tipo_instrumento.currentData(),
            "marca":               self._txt_marca.text().strip() or None,
            "modelo":              self._txt_modelo.text().strip() or None,
            "ns":                  self._txt_ns.text().strip() or None,
            "ubicacion":           self._txt_ubicacion.text().strip() or None,
            "alcance_max":         self._spin_alcance_max.value() or None,
            "div_minima":          self._spin_div_minima.value() or None,
            "div_verificacion":    self._spin_div_verificacion.value() or None,
            "id_equipo":           self._txt_id_equipo.lineEdit().text().strip() or None,
            "numero_cca":          self._txt_numero_cca.text().strip() or None,
            "holograma_anterior":  self._txt_holograma_anterior.text().strip() or None,
            "holograma_actualizado": self._txt_holograma_actualizado.text().strip() or None,
            "observaciones":       self._txt_observaciones.toPlainText().strip() or None,
            "firma_cliente_nombre": self._txt_firma_cliente.text().strip() or None,
            "valor_repetibilidad":  pruebas.get("valor_repetibilidad"),
            "valor_excentricidad":  pruebas.get("valor_excentricidad"),
            "id_clase_exactitud":   pruebas.get("id_clase_exactitud"),   # Código: I,II,III,IV
            "aplica_excentricidad":   self._pruebas_widget.excentricidad.get_aplica_excentricidad(),
            "filas_excentricidad":    self._pruebas_widget.excentricidad.get_filas_excentricidad(),
            "geometria_plataforma":   self._pruebas_widget.excentricidad.get_geometria_plataforma()
                                      if self._pruebas_widget.excentricidad.get_aplica_excentricidad()
                                      else None,
            "num_secciones":          self._pruebas_widget.excentricidad.get_num_secciones()
                                      if self._pruebas_widget.excentricidad.get_aplica_excentricidad()
                                      and self._pruebas_widget.excentricidad.get_geometria_plataforma() == "camionera"
                                      else None,
            "tipo_no_aplica_exc":     self._pruebas_widget.excentricidad.get_tipo_no_aplica()
                                      if not self._pruebas_widget.excentricidad.get_aplica_excentricidad()
                                      else None,
            "repetibilidad":          pruebas.get("repetibilidad", []),
            "excentricidad":          pruebas.get("excentricidad", []),
            "exactitud":              pruebas.get("exactitud", []),
        }

        try:
            from models.orden_servicio import orden_servicio_repo
            from models.catalogo import equipo_sucursal_repo

            self._btn_guardar.setEnabled(False)
            self._btn_guardar.setText("Guardando...")
            
            # Upsert del Equipo (Guardar si es nuevo, o actualizar info)
            sucursal_id = self._combo_sucursal.currentData()
            if sucursal_id:
                try:
                    equipo_upserted = equipo_sucursal_repo.upsert_from_os(sucursal_id, data)
                    # Si acabamos de crear un equipo nuevo manual, recuperar su ID para la OS
                    if equipo_upserted and equipo_upserted.get("id") and not data.get("equipo_catalogo_id"):
                        data["equipo_catalogo_id"] = equipo_upserted["id"]
                except Exception as eq_exc:
                    logger.warning(f"Error al auto-persistir equipo: {eq_exc}")

            if self._is_edit:
                result = orden_servicio_repo.update(self._os_id, data)
                folio  = result.get("folio_os", self._folio_os)
                msg    = f"OS actualizada exitosamente: {folio}"
            else:
                result = orden_servicio_repo.create(data)
                folio  = result.get("folio_os", "")
                self._folio_os = folio
                self._lbl_folio.setText(folio)
                self._is_edit  = True
                self._os_id    = result.get("id")
                msg = f"OS creada exitosamente: {folio}"

            # NUEVO: Re-generar PDF automáticamente con los datos actualizados
            try:
                from services.os_pdf_generator import os_pdf_generator
                import config
                from pathlib import Path

                os_data = orden_servicio_repo.get_by_id(self._os_id)
                rep  = orden_servicio_repo.get_repetibilidad(self._os_id)
                exc  = orden_servicio_repo.get_excentricidad(self._os_id)
                exac = orden_servicio_repo.get_exactitud(self._os_id)

                # Inyectar dirección de la sucursal seleccionada en el widget.
                # La dirección de la SUCURSAL siempre tiene prioridad sobre la
                # dirección general del cliente guardada en la BD.
                direccion_widget = self._txt_direccion.text().strip()
                if direccion_widget:
                    # Caso 1: El widget tiene una dirección cargada → usarla siempre
                    os_data["sucursal_direccion"] = direccion_widget
                    os_data["direccion"]           = direccion_widget
                    os_data["direccion_cliente"]   = direccion_widget  # bloquear fallback en pdf_generator
                else:
                    # Caso 2: Intentar recuperar desde la lista interna de sucursales
                    sucursal_id = self._combo_sucursal.currentData()
                    if sucursal_id and hasattr(self, "_sucursales"):
                        suc = next((s for s in self._sucursales if s.get("id") == sucursal_id), None)
                        if suc and suc.get("direccion"):
                            os_data["sucursal_direccion"] = suc.get("direccion")
                            os_data["direccion"]           = suc.get("direccion")
                            os_data["direccion_cliente"]   = suc.get("direccion")

                # Inyectar tipo de instrumento desde el combo del widget
                # (la vista puede devolver NULL si id_tipo_instrumento no se guardó
                # correctamente, o si la OS es muy antigua)
                if not os_data.get("tipo_instrumento"):
                    ti_texto = self._combo_tipo_instrumento.currentText().strip()
                    # Descartar placeholder
                    if ti_texto and "—" not in ti_texto and "selecciona" not in ti_texto.lower():
                        os_data["tipo_instrumento"] = ti_texto

                # Inyectar aplica_excentricidad, geometria y tipo_no_aplica desde el widget
                exc_w = self._pruebas_widget.excentricidad
                aplica_exc_widget = exc_w.get_aplica_excentricidad()
                os_data["aplica_excentricidad"] = aplica_exc_widget
                os_data["filas_excentricidad"]  = exc_w.get_filas_excentricidad()
                if aplica_exc_widget:
                    os_data["geometria_plataforma"] = exc_w.get_geometria_plataforma()
                    if exc_w.get_geometria_plataforma() == "camionera":
                        os_data["num_secciones"] = exc_w.get_num_secciones()
                else:
                    os_data["tipo_no_aplica_exc"] = exc_w.get_tipo_no_aplica()

                output_dir = Path(config.SERVER_FILES_BASE) / "PDF_OS"
                output_dir.mkdir(parents=True, exist_ok=True)
                output_path = str(output_dir / f"{folio}.pdf")
                
                tecnico = self._combo_tecnico.currentText()

                os_pdf_generator.generate_os_pdf(
                    os_data=os_data,
                    repetibilidad=rep,
                    excentricidad=exc,
                    exactitud=exac,
                    output_path=output_path,
                    tecnico_nombre=tecnico,
                    force=True
                )
                logger.info(f"PDF auto-regenerado al guardar para folio: {folio}")

                # Persistir ruta del PDF en BD para que el Dashboard la use directamente
                try:
                    orden_servicio_repo.update_pdf_path(self._os_id, output_path)
                except Exception as pp_exc:
                    logger.warning(f"No se pudo persistir pdf_path: {pp_exc}")
            except Exception as pdf_exc:
                logger.error(f"Error al regenerar PDF automáticamente: {pdf_exc}")

            logger.info(msg)
            QMessageBox.information(self, "Éxito", msg)
            self.os_saved.emit(folio)

        except Exception as exc:
            logger.error(f"Error al guardar OS: {exc}")
            QMessageBox.critical(self, "Error al Guardar", f"No se pudo guardar la OS:\n\n{exc}")
        finally:
            self._btn_guardar.setEnabled(True)
            self._btn_guardar.setText(
                "💾  Actualizar OS" if self._is_edit else "💾  Guardar OS"
            )

    def _clear_form(self) -> None:
        """Limpia el formulario para una nueva OS."""
        self._os_id   = None
        self._is_edit = False
        self._folio_os = ""

        self._lbl_folio.setText("— NUEVO —")
        self._date_edit.setDate(QDate.currentDate())
        self._combo_cliente.setCurrentIndex(0)
        self._combo_sucursal.setCurrentIndex(0)
        self._combo_sucursal.setEnabled(False)
        self._combo_equipo_cat.setCurrentIndex(0)
        self._combo_equipo_cat.setEnabled(False)
        self._combo_tipo_servicio.setCurrentIndex(0)
        self._combo_tipo_instrumento.setCurrentIndex(0)
        self._combo_tecnico.setCurrentIndex(0)
        self._txt_direccion.clear()

        for w in (self._txt_marca, self._txt_modelo, self._txt_ns,
                  self._txt_ubicacion,
                  self._txt_numero_cca, self._txt_holograma_anterior,
                  self._txt_holograma_actualizado,
                  self._txt_firma_cliente):
            w.clear()
        self._txt_id_equipo.blockSignals(True)
        self._txt_id_equipo.clear()
        self._txt_id_equipo.lineEdit().clear()
        self._txt_id_equipo.blockSignals(False)

        self._spin_alcance_max.setValue(0)
        self._spin_div_minima.setValue(0)
        self._spin_div_verificacion.setValue(0)
        self._txt_observaciones.clear()
        self._pruebas_widget.clear_all()
        self._btn_guardar.setText("💾  Guardar OS")

    # ── Utilidades ────────────────────────────────────────────────────────────

    @staticmethod
    def _set_combo_by_id(combo: QComboBox, item_id) -> None:
        """Selecciona el elemento del ComboBox que tenga el ID dado."""
        if item_id is None:
            combo.setCurrentIndex(0)
            return
        for i in range(combo.count()):
            if combo.itemData(i) == item_id:
                combo.setCurrentIndex(i)
                return

    # ── Generación de PDF ─────────────────────────────────────────────────────

    def _generate_pdf(self) -> None:
        """Genera el PDF de la OS actual y lo abre con el visor del sistema."""
        if not self._os_id:
            QMessageBox.warning(
                self, "Sin OS",
                "Guarde primero la OS para poder generar el PDF."
            )
            return

        try:
            from models.orden_servicio import orden_servicio_repo
            from services.os_pdf_generator import os_pdf_generator
            import subprocess
            import os

            # Cargar datos completos
            os_data = orden_servicio_repo.get_by_id(self._os_id)
            rep  = orden_servicio_repo.get_repetibilidad(self._os_id)
            exc  = orden_servicio_repo.get_excentricidad(self._os_id)
            exac = orden_servicio_repo.get_exactitud(self._os_id)

            # Ruta de salida en carpeta del servidor
            import config
            from pathlib import Path
            output_dir = Path(config.SERVER_FILES_BASE) / "PDF_OS"
            output_dir.mkdir(parents=True, exist_ok=True)
            folio = os_data.get("folio_os", "OS")
            output_path = str(output_dir / f"{folio}.pdf")

            tecnico = self._combo_tecnico.currentText()

            # Inyectar dirección de la sucursal seleccionada.
            # La dirección de la SUCURSAL siempre tiene prioridad sobre
            # la dirección general del cliente guardada en la BD.
            direccion_widget = self._txt_direccion.text().strip()
            if direccion_widget:
                os_data["sucursal_direccion"] = direccion_widget
                os_data["direccion"]           = direccion_widget
                os_data["direccion_cliente"]   = direccion_widget  # bloquear fallback en pdf_generator
            else:
                # Recuperar desde la lista interna de sucursales
                sucursal_id_sel = self._combo_sucursal.currentData()
                if sucursal_id_sel and hasattr(self, "_sucursales"):
                    suc = next((s for s in self._sucursales if s.get("id") == sucursal_id_sel), None)
                    if suc and suc.get("direccion"):
                        os_data["sucursal_direccion"] = suc.get("direccion")
                        os_data["direccion"]           = suc.get("direccion")
                        os_data["direccion_cliente"]   = suc.get("direccion")

            # Inyectar aplica_excentricidad, geometria y tipo_no_aplica desde el widget
            exc_w = self._pruebas_widget.excentricidad
            aplica_exc_widget = exc_w.get_aplica_excentricidad()
            os_data["aplica_excentricidad"] = aplica_exc_widget
            os_data["filas_excentricidad"]  = exc_w.get_filas_excentricidad()
            if aplica_exc_widget:
                os_data["geometria_plataforma"] = exc_w.get_geometria_plataforma()
                if exc_w.get_geometria_plataforma() == "camionera":
                    os_data["num_secciones"] = exc_w.get_num_secciones()
            else:
                os_data["tipo_no_aplica_exc"] = exc_w.get_tipo_no_aplica()

            # Inyectar tipo de instrumento desde el combo del widget
            if not os_data.get("tipo_instrumento"):
                ti_texto = self._combo_tipo_instrumento.currentText().strip()
                if ti_texto and "—" not in ti_texto and "selecciona" not in ti_texto.lower():
                    os_data["tipo_instrumento"] = ti_texto

            self._btn_pdf.setEnabled(False)
            self._btn_pdf.setText("Generando...")

            path = os_pdf_generator.generate_os_pdf(
                os_data=os_data,
                repetibilidad=rep,
                excentricidad=exc,
                exactitud=exac,
                output_path=output_path,
                tecnico_nombre=tecnico,
            )

            # Persistir ruta del PDF en BD
            try:
                orden_servicio_repo.update_pdf_path(self._os_id, path)
            except Exception as pp_exc:
                logger.warning(f"No se pudo persistir pdf_path desde _generate_pdf: {pp_exc}")

            QMessageBox.information(
                self, "PDF Generado",
                f"PDF generado exitosamente:\n{path}\n\nSe abrirá con el visor predeterminado."
            )

            # Abrir el PDF con el programa predeterminado del sistema
            if os.name == "nt":
                os.startfile(path)
            else:
                subprocess.Popen(["xdg-open", path])

        except Exception as exc:
            logger.error(f"Error al generar PDF: {exc}")
            QMessageBox.critical(self, "Error PDF", f"No se pudo generar el PDF:\n{exc}")
        finally:
            self._btn_pdf.setEnabled(True)
            self._btn_pdf.setText("📄  Generar PDF")
