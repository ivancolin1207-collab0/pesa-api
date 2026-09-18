"""
captura_digital_dialog.py — Dialogo de Captura Metrologica Digital Interactiva
Servicios PESA v2.3
"""
from __future__ import annotations
import json, logging, os, sys, subprocess, base64
from typing import Optional
from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QScrollArea, QWidget,
    QFrame, QFormLayout, QGroupBox, QCheckBox, QMessageBox, QSpinBox,
    QCompleter,
)
from PyQt6.QtCore import Qt, pyqtSignal, QTimer, QStringListModel

logger = logging.getLogger(__name__)

try:
    from database.connection import db_pool as _db_pool
    _DEPS_OK = True
except ImportError:
    _db_pool = None
    _DEPS_OK = False

# Import a nivel de módulo para que PyInstaller lo rastree correctamente
try:
    from ui.widgets.pruebas_metrologicas import PruebasMetrologicasWidget as _PruebasMetrologicasWidget
    _PRUEBAS_OK = True
except Exception as _pruebas_import_err:
    _PruebasMetrologicasWidget = None
    _PRUEBAS_OK = False
    logger = logging.getLogger(__name__)
    logger.warning("PruebasMetrologicasWidget no disponible: %s", _pruebas_import_err)

_BTN_PRIMARY = """
QPushButton {
    background: #1A7F64; color: white; border: none; border-radius: 8px;
    font-size: 10pt; font-weight: 700; padding: 10px 28px; min-height: 38px;
}
QPushButton:hover { background: #145C48; }
"""
_BTN_SECONDARY = """
QPushButton {
    background: #F2F2F7; color: #1D1D1F; border: 1px solid #D1D1D6;
    border-radius: 8px; font-size: 10pt; font-weight: 500;
    padding: 10px 20px; min-height: 38px;
}
QPushButton:hover { background: #E5E5EA; }
"""


class CapturaDigitalDialog(QDialog):
    """Ventana modal de captura digital metrologica."""

    captura_guardada = pyqtSignal()

    def __init__(self, os_id: int, folio: str = "", orden_data: dict = None, parent=None) -> None:
        super().__init__(parent)
        self._os_id  = os_id
        self._folio  = folio
        self._os_data: dict = orden_data or {}
        self._datos_json_previos: dict = {}
        self._motivo_no_aplica: str = ""   # subtipo elegido cuando aplica_excentricidad=False
        self._pruebas_widget = None

        self.setWindowTitle(f"Captura Digital — {folio}")
        self.setMinimumSize(980, 720)
        self.setWindowFlags(
            Qt.WindowType.Dialog |
            Qt.WindowType.WindowCloseButtonHint |
            Qt.WindowType.WindowMinMaxButtonsHint
        )
        self.setStyleSheet("QDialog { background: #F9FAFB; }")
        self._setup_ui()
        QTimer.singleShot(0, self._load_os_data)

    # ── Setup UI ─────────────────────────────────────────────────────────────

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 16, 20, 16)
        root.setSpacing(12)

        lbl_titulo = QLabel("📝  Captura Metrologica Digital")
        lbl_titulo.setStyleSheet(
            "font-size: 16pt; font-weight: 800; color: #1D1D1F;"
        )
        root.addWidget(lbl_titulo)

        lbl_sub = QLabel(
            f"Folio: {self._folio}  ·  Ingresa las lecturas y genera el PDF final."
        )
        lbl_sub.setStyleSheet("font-size: 9pt; color: #86868B; margin-bottom: 8px;")
        root.addWidget(lbl_sub)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        content = QWidget()
        content.setStyleSheet("background: #F5F5F7;")
        self._content_layout = QVBoxLayout(content)
        self._content_layout.setSpacing(12)

        self._grp_header = self._build_header_section()
        self._content_layout.addWidget(self._grp_header)
        self._grp_instrumento = self._build_instrumento_section()
        self._content_layout.addWidget(self._grp_instrumento)
        self._grp_pruebas = self._build_pruebas_section()
        self._content_layout.addWidget(self._grp_pruebas)
        self._grp_obs = self._build_obs_section()
        self._content_layout.addWidget(self._grp_obs)
        self._grp_firma = self._build_firma_section()
        self._content_layout.addWidget(self._grp_firma)
        self._content_layout.addStretch()

        scroll.setWidget(content)
        root.addWidget(scroll, 1)
        root.addWidget(self._build_button_bar())

    def _ro_field(self, text: str) -> QLineEdit:
        le = QLineEdit(text)
        le.setReadOnly(True)
        le.setStyleSheet(
            "background: #F5F5F7; color: #86868B; border: 1px solid #E5E5EA;"
            "border-radius: 6px; padding: 4px 8px; font-size: 9pt;"
        )
        return le

    def _input_field(self, placeholder: str = "") -> QLineEdit:
        le = QLineEdit()
        le.setPlaceholderText(placeholder)
        le.setStyleSheet(
            "background: #FFFFFF; color: #1D1D1F; border: 1px solid #D1D1D6;"
            "border-radius: 6px; padding: 4px 8px; font-size: 9pt;"
        )
        return le

    def _build_header_section(self) -> QGroupBox:
        grp = QGroupBox("INFORMACION DE LA ORDEN")
        grp.setStyleSheet(
            "QGroupBox { background: #FFFFFF; border: 1px solid #E5E5EA;"
            "border-radius: 10px; padding: 14px; margin-top: 8px;"
            "font-size: 9pt; font-weight: 700; color: #C8102E; }"
        )
        form = QFormLayout(grp)
        form.setSpacing(8)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignRight)
        self._lbl_folio    = self._ro_field(self._folio)
        self._lbl_fecha    = self._ro_field(self._os_data.get('fecha', ''))
        self._lbl_cliente  = self._ro_field(self._os_data.get('cliente', ''))
        self._lbl_sucursal = self._ro_field(self._os_data.get('sucursal', ''))
        self._lbl_tecnico  = self._ro_field(self._os_data.get('tecnico', ''))
        self._lbl_tipo_srv = self._ro_field(self._os_data.get('tipo_servicio', ''))
        
        tipo_equipo_str = f"{self._os_data.get('tipo_instrumento', 'Báscula')} - {self._os_data.get('marca', '')} {self._os_data.get('modelo', '')}".strip(" -")
        self._lbl_tipo_ins = self._ro_field(tipo_equipo_str if tipo_equipo_str else "Báscula de plataforma")
        
        for label, widget in [
            ("Folio OS:", self._lbl_folio),
            ("Fecha:", self._lbl_fecha),
            ("Cliente:", self._lbl_cliente),
            ("Sucursal / Planta:", self._lbl_sucursal),
            ("Tecnico asignado:", self._lbl_tecnico),
            ("Tipo de servicio:", self._lbl_tipo_srv),
            ("Tipo de equipo:", self._lbl_tipo_ins),
        ]:
            lbl = QLabel(label)
            lbl.setStyleSheet("color: #1D1D1F; font-size: 9pt;")
            form.addRow(lbl, widget)
        return grp

    def _build_instrumento_section(self) -> QGroupBox:
        grp = QGroupBox("DATOS DEL INSTRUMENTO / BÁSCULA")
        grp.setStyleSheet(
            "QGroupBox { background: #FFFFFF; border: 1px solid #E5E7EB;"
            "border-radius: 8px; padding: 14px; margin-top: 8px;"
            "font-size: 13px; font-weight: 600; color: #C8102E; }"
            "QLabel { color: #374151; font-weight: 600; font-size: 13px; }"
            "QLineEdit, QComboBox { background: #FFFFFF; border: 1px solid #D1D5DB; padding: 6px 10px; border-radius: 4px; }"
            "QLineEdit:focus, QComboBox:focus { border: 1px solid #C8102E; }"
        )
        lay = QVBoxLayout(grp)
        lay.setSpacing(10)

        # Fila 1
        row1 = QHBoxLayout()
        self._le_marca = QLineEdit()
        self._le_modelo = QLineEdit()
        self._le_serie = QLineEdit()
        self._le_id_equipo = QLineEdit()
        
        for lbl_text, widget in [("Marca:", self._le_marca), ("Modelo:", self._le_modelo), 
                                 ("N° de Serie:", self._le_serie), ("ID Equipo:", self._le_id_equipo)]:
            vl = QVBoxLayout()
            vl.addWidget(QLabel(lbl_text))
            vl.addWidget(widget)
            row1.addLayout(vl)
        lay.addLayout(row1)

        # Fila 2: Capacidad | División | UNIDAD | Ubicación
        row2 = QHBoxLayout()
        self._le_capacidad = QLineEdit()
        self._le_capacidad.setPlaceholderText("ej. 500")
        self._le_div_min = QLineEdit()
        self._le_div_min.setPlaceholderText("ej. 0.001")

        # ── Selector de unidad de medida ───────────────────────────────
        self._cmb_unidad = QComboBox()
        self._cmb_unidad.addItems(["kg", "g", "t", "lb"])
        self._cmb_unidad.setCurrentText(self._os_data.get("unidad_medida", "kg") or "kg")
        self._cmb_unidad.setFixedWidth(70)
        self._cmb_unidad.setStyleSheet(
            f"QComboBox {{ background: #FFFFFF; border: 1px solid #D1D5DB; "
            f"padding: 5px 8px; border-radius: 4px; font-weight: 700; color: #C8102E; }}"
            f"QComboBox::drop-down {{ border: none; }}"
        )
        self._cmb_unidad.currentTextChanged.connect(self._on_unidad_changed)

        self._le_ubicacion = QLineEdit()

        for lbl_text, widget in [
            ("Capacidad Máx:", self._le_capacidad),
            ("División Mín.:", self._le_div_min),
            ("Unidad:", self._cmb_unidad),
            ("Ubicación en Planta:", self._le_ubicacion),
        ]:
            vl = QVBoxLayout()
            vl.addWidget(QLabel(lbl_text))
            vl.addWidget(widget)
            row2.addLayout(vl)
        lay.addLayout(row2)

        # Cargar autocomplete histórico después de que el diálogo termine de construirse
        QTimer.singleShot(300, self._load_autocomplete_historico)

        # Fila 3 (Dinámica)
        self._row3 = QHBoxLayout()
        self._le_num_cca = QLineEdit()
        self._cmb_inicial = QComboBox()
        self._cmb_inicial.addItems(["", "J", "A", "I"])
        self._le_holo_ant = QLineEdit()
        self._le_holo_nuevo = QLineEdit()
        self._le_dve = QLineEdit()

        self._w_cca = QWidget()
        l_cca = QHBoxLayout(self._w_cca)
        l_cca.setContentsMargins(0, 0, 0, 0)
        v1 = QVBoxLayout(); v1.addWidget(QLabel("Número de CCA:")); v1.addWidget(self._le_num_cca); l_cca.addLayout(v1)
        v2 = QVBoxLayout(); v2.addWidget(QLabel("Inicial Calibrador:")); v2.addWidget(self._cmb_inicial); l_cca.addLayout(v2)
        
        self._w_holo = QWidget()
        l_holo = QHBoxLayout(self._w_holo)
        l_holo.setContentsMargins(0, 0, 0, 0)
        v3 = QVBoxLayout(); v3.addWidget(QLabel("Holograma Anterior:")); v3.addWidget(self._le_holo_ant); l_holo.addLayout(v3)
        v4 = QVBoxLayout(); v4.addWidget(QLabel("Holograma Nuevo:")); v4.addWidget(self._le_holo_nuevo); l_holo.addLayout(v4)
        v5 = QVBoxLayout(); v5.addWidget(QLabel("DVE:")); v5.addWidget(self._le_dve); l_holo.addLayout(v5)

        self._row3.addWidget(self._w_cca)
        self._row3.addWidget(self._w_holo)
        lay.addLayout(self._row3)

        # Aplicar reglas de visibilidad según tipo de servicio precargado
        tipo_srv = self._os_data.get('tipo_servicio', '').lower()
        if "calibraci" in tipo_srv or "cca" in tipo_srv:
            self._w_holo.hide()
            self._w_cca.show()
        elif "inspecc" in tipo_srv or "verific" in tipo_srv:
            self._w_cca.hide()
            self._w_holo.show()
        else: # Solo Ajuste / Mantenimiento
            self._w_cca.hide()
            self._w_holo.hide()

        # Fila 4: Excentricidad, Tipo Receptor, Funcionamiento, Puntos de Apoyo
        row4 = QHBoxLayout()
        self._cmb_excentricidad = QComboBox()
        self._cmb_excentricidad.addItems(["Sí", "No"])
        self._cmb_receptor = QComboBox()
        self._cmb_receptor.addItems(["Plataforma", "Camionera", "Tolva", "Otro"])
        
        # Nuevos: Funcionamiento y Puntos de Apoyo
        self._cmb_funcionamiento = QComboBox()
        self._cmb_funcionamiento.addItems(["Electrónico", "Mecánico", "Electromecánico"])
        self._spn_puntos_apoyo = QSpinBox()
        self._spn_puntos_apoyo.setRange(1, 12)
        self._spn_puntos_apoyo.setValue(4)
        self._spn_puntos_apoyo.setStyleSheet(
            "background: #FFFFFF; border: 1px solid #D1D5DB;"
            "padding: 6px 10px; border-radius: 4px;"
        )

        v6 = QVBoxLayout(); v6.addWidget(QLabel("¿Aplica Excentricidad?")); v6.addWidget(self._cmb_excentricidad); row4.addLayout(v6)
        v7 = QVBoxLayout(); v7.addWidget(QLabel("Tipo de Receptor:")); v7.addWidget(self._cmb_receptor); row4.addLayout(v7)
        v8 = QVBoxLayout(); v8.addWidget(QLabel("Funcionamiento:")); v8.addWidget(self._cmb_funcionamiento); row4.addLayout(v8)
        v9 = QVBoxLayout(); v9.addWidget(QLabel("Puntos de Apoyo:")); v9.addWidget(self._spn_puntos_apoyo); row4.addLayout(v9)
        row4.addStretch()
        lay.addLayout(row4)
        
        # Conectar div_min para propagar d a las tablas de pruebas
        self._le_div_min.textChanged.connect(self._on_div_min_changed)
        
        self._cmb_excentricidad.currentTextChanged.connect(self._on_excentricidad_changed)

        return grp

    def _on_div_min_changed(self, text: str) -> None:
        """Propaga d a las tablas de pruebas metrológicas al cambiar División Mín."""
        if not self._pruebas_widget:
            return
        try:
            from services.metrology import parse_d
            d = parse_d(text)
            if d:
                self._pruebas_widget.set_division_minima(d)
        except Exception:
            pass

    def _on_excentricidad_changed(self, text: str) -> None:
        """Cuando se elige 'No', deshabilita la tabla silenciosamente.
        El motivo se infiere automáticamente del tipo de receptor/instrumento
        definido por Logística — SIN interrumpir al técnico con modales."""
        aplica = (text == "Sí")
        # Habilitar/deshabilitar la pestaña de excentricidad en pruebas
        if hasattr(self, '_pruebas_widget') and self._pruebas_widget:
            try:
                self._pruebas_widget._tabs.setTabEnabled(1, aplica)
            except Exception:
                pass

        if not aplica:
            # Auto-detectar el motivo desde tipo_receptor (sin preguntar al técnico)
            _receptor = ""
            if hasattr(self, '_cmb_receptor'):
                _receptor = self._cmb_receptor.currentText()
            # Mapeo receptor → motivo legible
            _MAPA = {
                "Tolva":     "Tolva",
                "Tanque":    "Tanque",
                "Silo":      "Tolva / Tanque / Silo",
                "Grua":      "Báscula de Grúa / Gancho Dinamométrico",
                "Colgante":  "Báscula de Grúa / Gancho Dinamométrico",
            }
            motivo_auto = next(
                (v for k, v in _MAPA.items() if k.lower() in _receptor.lower()),
                _receptor or "Tolva / Tanque / Silo"
            )
            # Solo actualizar si no hay uno ya guardado explícitamente
            if not self._motivo_no_aplica:
                self._motivo_no_aplica = motivo_auto
        else:
            self._motivo_no_aplica = ""

    def _on_unidad_changed(self, unit: str) -> None:
        """Propaga la unidad de medida a las tablas metrológicas."""
        if self._pruebas_widget and hasattr(self._pruebas_widget, 'set_unidad'):
            self._pruebas_widget.set_unidad(unit)

    def _build_pruebas_section(self) -> QGroupBox:
        grp = QGroupBox("PRUEBAS METROLOGICAS")
        grp.setStyleSheet(
            "QGroupBox { background: #FFFFFF; border: 1px solid #E5E5EA;"
            "border-radius: 10px; padding: 14px; margin-top: 8px;"
            "font-size: 9pt; font-weight: 700; color: #C8102E; }"
        )
        lay = QVBoxLayout(grp)
        lay.setSpacing(8)
        if _PRUEBAS_OK and _PruebasMetrologicasWidget is not None:
            self._pruebas_widget = _PruebasMetrologicasWidget()
            lay.addWidget(self._pruebas_widget)
        else:
            lbl_err = QLabel(
                "No se pudo cargar el widget de pruebas metrológicas.\n"
                "Reinicia la aplicación o contacta a soporte PESA."
            )
            lbl_err.setStyleSheet("color: #C8102E; font-size: 9pt;")
            lbl_err.setWordWrap(True)
            lay.addWidget(lbl_err)
        return grp

    def _build_obs_section(self) -> QGroupBox:
        grp = QGroupBox("OBSERVACIONES Y DICTAMEN")
        grp.setStyleSheet(
            "QGroupBox { background: #FFFFFF; border: 1px solid #E5E5EA;"
            "border-radius: 10px; padding: 14px; margin-top: 8px;"
            "font-size: 9pt; font-weight: 700; color: #C8102E; }"
        )
        lay = QVBoxLayout(grp)
        lay.setSpacing(8)
        lbl_obs = QLabel("Observaciones del técnico:")
        lbl_obs.setStyleSheet("color: #1D1D1F; font-size: 9pt;")
        lay.addWidget(lbl_obs)
        self._txt_obs = QTextEdit()
        self._txt_obs.setPlaceholderText(
            "Ej. Se realizó ajuste de plataforma. Sensor de celda en buen estado..."
        )
        self._txt_obs.setMinimumHeight(80)
        self._txt_obs.setMaximumHeight(120)
        self._txt_obs.setStyleSheet(
            "background: #FFFFFF; border: 1px solid #D1D1D6;"
            "border-radius: 6px; padding: 4px 8px; font-size: 9pt;"
        )
        lay.addWidget(self._txt_obs)
        return grp

    def _build_firma_section(self) -> QGroupBox:
        grp = QGroupBox("CONFIRMACION DEL TECNICO Y CLIENTE")
        grp.setStyleSheet(
            "QGroupBox { background: #FFFFFF; border: 1px solid #E5E5EA;"
            "border-radius: 10px; padding: 14px; margin-top: 8px;"
            "font-size: 9pt; font-weight: 700; color: #C8102E; }"
        )
        form = QFormLayout(grp)
        form.setSpacing(8)
        self._le_tecnico_exec = self._input_field(
            "Cargando nombre del tecnico..."
        )
        # Campo de solo lectura: se auto-rellena del usuario de sesion
        self._le_tecnico_exec.setReadOnly(True)
        self._le_tecnico_exec.setStyleSheet(
            "background: #F3F4F6; color: #374151;"
            "border: 1px solid #D1D5DB; border-radius: 6px;"
            "padding: 6px 10px; font-size: 9pt;"
        )
        lbl = QLabel("Tecnico ejecutor:")
        lbl.setStyleSheet("color: #1D1D1F; font-size: 9pt;")
        form.addRow(lbl, self._le_tecnico_exec)

        # ── Campo obligatorio: Nombre de quien recibe / Conforme Cliente ──────
        self._le_cliente_firma = QLineEdit()
        self._le_cliente_firma.setPlaceholderText(
            "Nombre completo del responsable que recibe / firma de conformidad"
        )
        self._le_cliente_firma.setStyleSheet(
            "background: #FFFFFF; color: #1D1D1F; border: 1.5px solid #C8102E;"
            "border-radius: 6px; padding: 6px 10px; font-size: 9pt;"
        )
        lbl_cli = QLabel("Recibe / Conforme Cliente: *")
        lbl_cli.setStyleSheet("color: #C8102E; font-size: 9pt; font-weight: 700;")
        form.addRow(lbl_cli, self._le_cliente_firma)
        return grp

    def _build_button_bar(self) -> QWidget:
        bar = QWidget()
        bar.setStyleSheet(
            "background: #FFFFFF; border-top: 1px solid #E5E5EA; padding: 4px;"
        )
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(10)

        btn_cancel = QPushButton("Cancelar")
        btn_cancel.setStyleSheet(_BTN_SECONDARY)
        btn_cancel.clicked.connect(self.reject)

        # Botón Reiniciar Captura
        btn_reset = QPushButton("🔄  Reiniciar Captura")
        btn_reset.setStyleSheet(
            "QPushButton {"
            "  background: #FFF3E0; color: #E65100;"
            "  border: 1px solid #FFCC80;"
            "  border-radius: 8px; font-size: 10pt; font-weight: 600;"
            "  padding: 8px 18px;"
            "}"
            "QPushButton:hover { background: #FFE0B2; }"
        )
        btn_reset.clicked.connect(self._on_reiniciar_captura)

        self._btn_borrador = QPushButton("\U0001f4be  Guardar Borrador")
        self._btn_borrador.setStyleSheet(
            "QPushButton {"
            "  background: #F5F5F7; color: #374151;"
            "  border: 1px solid #D1D5DB;"
            "  border-radius: 8px; font-size: 11pt; font-weight: 600;"
            "  padding: 8px 18px;"
            "}"
            "QPushButton:hover { background: #E5E7EB; }"
            "QPushButton:disabled { color: #9CA3AF; }"
        )
        self._btn_borrador.clicked.connect(self._on_guardar_borrador)

        self._btn_guardar = QPushButton("\U0001f5a8  Guardar y Generar PDF Final")
        self._btn_guardar.setStyleSheet(_BTN_PRIMARY)
        self._btn_guardar.clicked.connect(self._on_guardar)

        lay.addWidget(btn_cancel)
        lay.addWidget(btn_reset)
        lay.addStretch()
        lay.addWidget(self._btn_borrador)
        lay.addWidget(self._btn_guardar)
        return bar

    # ── Carga de datos ───────────────────────────────────────────────────────

    def _load_os_data(self) -> None:
        if not _DEPS_OK or _db_pool is None or not self._os_id:
            return
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT
                            os.folio_os, os.fecha::text,
                            COALESCE(cl.razon_social, ''),
                            COALESCE(
                                NULLIF(
                                    CASE
                                        WHEN suc.nombre_sucursal IS NOT NULL AND suc.direccion IS NOT NULL
                                             AND suc.nombre_sucursal <> suc.direccion
                                             THEN suc.nombre_sucursal || ' — ' || suc.direccion
                                        WHEN suc.direccion IS NOT NULL AND suc.direccion <> ''
                                             THEN suc.direccion
                                        WHEN suc.nombre_sucursal IS NOT NULL AND suc.nombre_sucursal <> ''
                                             THEN suc.nombre_sucursal
                                        ELSE NULL
                                    END,
                                ''),
                                -- Fallback: primera sucursal del cliente
                                NULLIF((
                                    SELECT COALESCE(
                                        NULLIF(s2.direccion, ''),
                                        NULLIF(s2.nombre_sucursal, '')
                                    )
                                    FROM cliente_sucursales s2
                                    WHERE s2.cliente_id = os.id_cliente
                                    ORDER BY s2.id ASC
                                    LIMIT 1
                                ), ''),
                                NULLIF(os.ubicacion, '')
                            ) AS sucursal_completa,
                            COALESCE(tc.nombre_completo, ''),
                            COALESCE(ts.nombre, os.tipo_servicio, ''),
                            COALESCE(ti.nombre, ''),
                            os.estado, os.modalidad,
                            COALESCE(os.datos_tecnicos_json, '{}'),
                            COALESCE(os.observaciones, ''),
                            os.id_tipo_instrumento,
                            os.aplica_excentricidad,
                            COALESCE(os.numero_celdas, 0),
                            COALESCE(CAST(os.id_clase_exactitud AS text), '3'),
                            10,
                            COALESCE(tc.nombre_completo, ''),
                            COALESCE(os.marca, ''),
                            COALESCE(os.modelo, '')
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
                        LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                        LEFT JOIN cliente_sucursales suc ON os.sucursal_id = suc.id
                        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
                        WHERE os.id = %s
                        """,
                        (self._os_id,)
                    )
                    row = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)

            if not row:
                return

            (folio, fecha, cliente, sucursal, tecnico, tipo_srv, tipo_ins,
             estado, modalidad, datos_json_str, obs_prev, id_tipo_ins,
             aplica_exc, num_celdas, clase_exactitud, num_puntos,
             tecnico_nombre, marca, modelo) = row

            self._folio = folio or self._folio
            self._os_data = {
                "folio_os": folio, "fecha": fecha, "cliente": cliente,
                "sucursal": sucursal, "tecnico": tecnico,
                "tipo_servicio": tipo_srv, "tipo_instrumento": tipo_ins,
                "estado": estado, "modalidad": modalidad,
                "aplica_excentricidad": aplica_exc,
                "num_celdas_camionera": num_celdas,
                "clase_exactitud": clase_exactitud,
                "num_puntos_exactitud": num_puntos or 10,
            }
            try:
                self._datos_json_previos = json.loads(datos_json_str or "{}")
            except (json.JSONDecodeError, TypeError):
                self._datos_json_previos = {}

            self.setWindowTitle(f"Captura Digital — {folio}")
            self._lbl_folio.setText(folio or "—")
            self._lbl_fecha.setText(str(fecha or "—"))
            self._lbl_cliente.setText(cliente or "—")
            # Resolver sucursal — triple fallback con nombres de columna correctos
            if not sucursal or sucursal.strip() in ('', '—', '-'):
                # Fallback 1: consulta directa usando cliente_id (nombre real en BD)
                try:
                    with conn.cursor() as cur2:
                        cur2.execute(
                            """
                            SELECT COALESCE(
                                NULLIF(s.direccion, ''),
                                NULLIF(s.nombre_sucursal, '')
                            )
                            FROM cliente_sucursales s
                            WHERE s.cliente_id = (
                                SELECT id_cliente FROM ordenes_servicio WHERE id = %s
                            )
                            ORDER BY s.id ASC
                            LIMIT 1
                            """,
                            (self._os_id,)
                        )
                        row2 = cur2.fetchone()
                        if row2 and row2[0]:
                            sucursal = row2[0]
                            logger.info("Sucursal resuelta via fallback BD: %s", sucursal)
                except Exception as e2:
                    logger.warning("Fallback sucursal BD fallo: %s", e2)

            # Fallback 2: campos auxiliares de orden_data pasados desde el dashboard
            if not sucursal or sucursal.strip() in ('', '—', '-'):
                sucursal = (
                    self._os_data.get('sucursal_direccion') or
                    self._os_data.get('direccion_planta') or
                    self._os_data.get('ubicacion') or
                    ''
                )

            print(f"DEBUG SUCURSAL FINAL: '{sucursal}' — os_id={self._os_id}")
            self._lbl_sucursal.setText(sucursal.strip() if sucursal else '')
            self._lbl_sucursal.setStyleSheet(
                "background: #F5F5F7; color: #1D1D1F; border: 1px solid #E5E5EA;"
                "border-radius: 6px; padding: 4px 8px; font-size: 9pt;"
            )
            self._lbl_tecnico.setText(tecnico or "—")
            self._lbl_tipo_srv.setText(tipo_srv or "—")
            self._le_tecnico_exec.setText(tecnico_nombre or "")
            
            # ── Poblar campos desde borrador guardado (SIEMPRE, no solo si vacía) ──
            # Prioridad: datos del borrador JSON > datos de la BD de la OS
            djp = self._datos_json_previos

            self._le_marca.setText(djp.get("marca") or marca or "")
            self._le_modelo.setText(djp.get("modelo") or modelo or "")
            self._le_serie.setText(djp.get("serie") or self._os_data.get("ns") or "")
            self._le_id_equipo.setText(djp.get("id_equipo") or "")
            self._le_num_cca.setText(djp.get("numero_cca") or "")
            self._le_capacidad.setText(str(djp.get("alcance_max") or self._os_data.get("alcance_max") or ""))
            self._le_div_min.setText(str(djp.get("div_minima") or self._os_data.get("div_minima") or ""))
            self._le_ubicacion.setText(str(djp.get("ubicacion") or self._os_data.get("ubicacion") or ""))
            self._le_holo_ant.setText(djp.get("holograma_anterior") or "")
            self._le_holo_nuevo.setText(djp.get("holograma_nuevo") or "")
            self._le_dve.setText(djp.get("dve") or "")

            # Combos guardados en borrador
            if djp.get("funcionamiento"):
                self._cmb_funcionamiento.setCurrentText(djp["funcionamiento"])
            if djp.get("puntos_apoyo") is not None:
                try:
                    pa = int(djp["puntos_apoyo"])
                    # Solo restaurar si el usuario explícitamente capturó >= 2
                    # (valor 1 era el antiguo valor por defecto incorrecto)
                    if pa >= 2:
                        self._spn_puntos_apoyo.setValue(pa)
                    # Si pa==1 y el usuario realmente quiere 1, puede cambiarlo manualmente
                except (ValueError, TypeError):
                    pass

            # ── Auto-configurar tipo_receptor desde tipo_instrumento de la BD ──
            # Si Logística ya definió el tipo, propagarlo al combo receptor
            _tipo_ins_nombre = self._os_data.get("tipo_instrumento", "") or ""
            _TIPO_MAP = [
                (["Camionera", "Ferrocarril", "FFCC", "Puente"],   "Camionera"),
                (["Tolva", "Silo", "Silo"],                        "Tolva"),
                (["Tanque"],                                        "Tanque"),
                (["Grúa", "Grua", "Colgante", "Dinamometrico"],    "Otro"),
                (["Plataforma", "Mesa", "Balanza", "Banco"],       "Plataforma"),
            ]
            _receptor_from_tipo = None
            for _keywords, _receptor_val in _TIPO_MAP:
                if any(k.lower() in _tipo_ins_nombre.lower() for k in _keywords):
                    _receptor_from_tipo = _receptor_val
                    break

            # Auto-configurar aplica_excentricidad desde tipo de instrumento si BD lo indica
            _TIPOS_SIN_EXC = ["Tolva", "Tanque", "Silo", "Grúa", "Grua", "Colgante"]
            if aplica_exc is None:
                # Si aplica_exc es NULL en BD, inferir del nombre del tipo de instrumento
                aplica_exc = not any(k.lower() in _tipo_ins_nombre.lower() for k in _TIPOS_SIN_EXC)

            # Bloquear señal para evitar que _on_excentricidad_changed dispare un popup
            self._cmb_excentricidad.blockSignals(True)
            try:
                if aplica_exc:
                    self._cmb_excentricidad.setCurrentText("Sí")
                    self._motivo_no_aplica = ""
                else:
                    self._cmb_excentricidad.setCurrentText("No")
                    # Restaurar motivo guardado en borrador (sin popup)
                    self._motivo_no_aplica = (
                        djp.get("motivo_no_aplica") or
                        self._os_data.get("motivo_no_aplica") or
                        _tipo_ins_nombre or
                        "Tolva / Tanque / Silo"
                    )
                    # Deshabilitar pestaña de excentricidad
                    if hasattr(self, '_pruebas_widget') and self._pruebas_widget:
                        try:
                            self._pruebas_widget._tabs.setTabEnabled(1, False)
                        except Exception:
                            pass
            finally:
                self._cmb_excentricidad.blockSignals(False)

            # Tipo receptor: prioridad borrador > inferido del tipo instrumento > default
            _receptor_final = djp.get("tipo_receptor") or _receptor_from_tipo
            if _receptor_final:
                idx = self._cmb_receptor.findText(_receptor_final)
                if idx >= 0:
                    self._cmb_receptor.setCurrentIndex(idx)

            # Observaciones: prioridad borrador > BD
            obs_restore = djp.get("observaciones") or obs_prev or ""
            if obs_restore:
                self._txt_obs.setPlainText(obs_restore)

            # Nombre cliente que recibe (campo obligatorio)
            cliente_firma_restore = djp.get("cliente_firma") or djp.get("firma_cliente_nombre") or ""
            if hasattr(self, '_le_cliente_firma') and cliente_firma_restore:
                self._le_cliente_firma.setText(cliente_firma_restore)

            if self._pruebas_widget:
                try:
                    self._pruebas_widget.set_os_config({
                        "aplica_excentricidad": aplica_exc,
                        "num_celdas_camionera": num_celdas,
                        "clase_exactitud": clase_exactitud,
                        "num_puntos": num_puntos or 10,
                        "id_tipo_instrumento": id_tipo_ins,
                    })
                except AttributeError:
                    pass

                # ── Restaurar geometría de excentricidad desde borrador ──────────
                _geo_saved   = self._datos_json_previos.get("geometria_plataforma", "")
                _secs_saved  = int(self._datos_json_previos.get("num_secciones", 4) or 4)
                _tipo_rec    = (self._datos_json_previos.get("tipo_receptor")
                               or self._cmb_receptor.currentText())
                # Auto-deshabilitar excentricidad para Tolva/Tanque
                _exc_widget = getattr(self._pruebas_widget, 'excentricidad', None)
                if _exc_widget:
                    if any(t in (_tipo_rec or "") for t in ("Tolva", "Tanque", "Silo", "Grua")):
                        try:
                            _exc_widget.set_excentricidad_config(aplica=False, filas=0)
                            self._tabs.setTabEnabled(1, False) if hasattr(self, '_tabs') else None
                        except Exception:
                            pass
                    elif _geo_saved:
                        try:
                            if hasattr(_exc_widget, 'set_geometria_plataforma'):
                                _exc_widget.set_geometria_plataforma(_geo_saved, _secs_saved)
                        except Exception:
                            pass

                if self._datos_json_previos:
                    try:
                        self._pruebas_widget.set_all_data(
                            repetibilidad=self._datos_json_previos.get("repetibilidad", []),
                            excentricidad=self._datos_json_previos.get("excentricidad", []),
                            exactitud=self._datos_json_previos.get("exactitud", []),
                            tipo_instrumento=self._datos_json_previos.get("tipo_instrumento"),
                            numero_celdas=num_celdas,
                            clase_exactitud=clase_exactitud or None,
                            aplica_excentricidad=aplica_exc if aplica_exc is not None else None,
                            filas_excentricidad=self._datos_json_previos.get("filas_excentricidad"),
                        )
                    except AttributeError:
                        pass
                # Propagar unidad de medida almacenada
                unidad_bd = (self._os_data.get("unidad_medida")
                             or self._datos_json_previos.get("unidad_medida", "kg")
                             or "kg")
                self._cmb_unidad.setCurrentText(unidad_bd)
                if hasattr(self._pruebas_widget, 'set_unidad'):
                    self._pruebas_widget.set_unidad(unidad_bd)
                # Propagar div_minima para que los spinboxes tengan los decimales correctos
                # y la validación de paso quede activa desde la carga
                _div_raw = (self._datos_json_previos.get("div_minima")
                            or self._os_data.get("div_minima")
                            or self._os_data.get("division_min")
                            or "")
                if _div_raw:
                    try:
                        from services.metrology import parse_d
                        _d_val = parse_d(str(_div_raw))
                        if _d_val and _d_val > 0:
                            if hasattr(self._pruebas_widget, 'set_division_minima'):
                                self._pruebas_widget.set_division_minima(_d_val)
                    except Exception as _de:
                        logger.debug("No se pudo propagar div_minima al cargar: %s", _de)

        except Exception as exc:
            import traceback
            traceback.print_exc()
            logger.error("CapturaDigitalDialog._load_os_data FALLO: %s", exc)
            # Mostrar al usuario para que no quede en blanco silenciosamente
            try:
                QMessageBox.warning(
                    self, "Error al cargar datos",
                    f"No se pudieron cargar los datos guardados de la orden.\n\nError: {exc}"
                )
            except Exception:
                pass

    # ── Guardar ──────────────────────────────────────────────────────────────

    def _on_reiniciar_captura(self) -> None:
        """Limpia todas las lecturas del widget de pruebas y resetea los campos de texto."""
        resp = QMessageBox.question(
            self,
            "Reiniciar captura",
            "¿Deseas limpiar TODAS las lecturas de Repetibilidad, Excentricidad y Exactitud?\n\n"
            "Esta acción no se puede deshacer.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return
        if self._pruebas_widget:
            try:
                if hasattr(self._pruebas_widget, 'clear_all'):
                    self._pruebas_widget.clear_all()
                elif hasattr(self._pruebas_widget, 'clear'):
                    self._pruebas_widget.clear()
            except Exception as exc:
                logger.warning("_on_reiniciar_captura: %s", exc)
        # Limpiar campo nombre cliente
        if hasattr(self, '_le_cliente_firma'):
            self._le_cliente_firma.clear()
        # Limpiar observaciones
        if hasattr(self, '_txt_obs'):
            self._txt_obs.clear()
        logger.info("Captura reiniciada para OS %s", self._folio)

    def _on_guardar_borrador(self) -> None:
        """Guarda el avance actual con estado='Proceso' sin generar PDF."""
        self._btn_borrador.setEnabled(False)
        self._btn_borrador.setText("Guardando borrador...")
        try:
            def _filtrar_filas(rows: list) -> list:
                return [r for r in rows if any([
                    r.get('valor') is not None, r.get('valor_nominal') is not None,
                    r.get('carga') is not None, r.get('lectura_final') is not None,
                    r.get('lectura_inicial') is not None,
                ])]

            rep_rows = exc_rows = exac_rows = []
            if self._pruebas_widget:
                try:
                    data = self._pruebas_widget.get_all_data()
                    rep_rows  = _filtrar_filas(data.get("repetibilidad", []))
                    exc_rows  = _filtrar_filas(data.get("excentricidad", []))
                    exac_rows = _filtrar_filas(data.get("exactitud", []))
                except AttributeError:
                    pass

            aplica_exc = (self._cmb_excentricidad.currentText() == "Sí")
            leyenda_exc = (
                "El tipo de instrumento no es apto para realizar prueba de excentricidad"
                if not aplica_exc else ""
            )
            # Definir obs_text desde el widget de observaciones (evita NameError)
            obs_text = self._txt_obs.toPlainText().strip() if hasattr(self, "_txt_obs") else ""
            cliente_firma = getattr(self, '_le_cliente_firma', None)
            cliente_firma_text = cliente_firma.text().strip() if cliente_firma else ""
            datos_json = {
                **self._datos_json_previos,
                "repetibilidad":  rep_rows,
                "excentricidad":  exc_rows,
                "exactitud":      exac_rows,
                "observaciones":  obs_text,
                "unidad_medida":  self._cmb_unidad.currentText() if hasattr(self, '_cmb_unidad') else "kg",
                "tecnico_ejecutor": self._le_tecnico_exec.text().strip(),
                "marca": self._le_marca.text().strip(),
                "modelo": self._le_modelo.text().strip(),
                "serie": self._le_serie.text().strip(),
                "id_equipo": self._le_id_equipo.text().strip(),
                "numero_cca": self._le_num_cca.text().strip(),
                "holograma_anterior": self._le_holo_ant.text().strip(),
                "holograma_nuevo": self._le_holo_nuevo.text().strip(),
                "dve": self._le_dve.text().strip(),
                "alcance_max": self._le_capacidad.text().strip(),
                "div_minima": self._le_div_min.text().strip(),
                "ubicacion": self._le_ubicacion.text().strip(),
                "funcionamiento": self._cmb_funcionamiento.currentText(),
                "puntos_apoyo": self._spn_puntos_apoyo.value(),
                "aplica_excentricidad": aplica_exc,
                "motivo_no_aplica": self._motivo_no_aplica if not aplica_exc else "",
                "leyenda_excentricidad": leyenda_exc,
                "cliente_firma": cliente_firma_text,
                "tipo_receptor": self._cmb_receptor.currentText() if hasattr(self, '_cmb_receptor') else "",
                # ── Geometría de excentricidad (para restaurar al reabrir) ──
                "geometria_plataforma": (
                    self._pruebas_widget.excentricidad.get_geometria_plataforma()
                    if self._pruebas_widget and hasattr(self._pruebas_widget, 'excentricidad')
                    and hasattr(self._pruebas_widget.excentricidad, 'get_geometria_plataforma')
                    else ""
                ),
                "num_secciones": (
                    self._pruebas_widget.excentricidad._spin_secciones.value()
                    if self._pruebas_widget and hasattr(self._pruebas_widget, 'excentricidad')
                    and hasattr(getattr(self._pruebas_widget, 'excentricidad', None), '_spin_secciones')
                    else 4
                ),
                "tipo_instrumento": (
                    self._pruebas_widget.excentricidad.get_tipo_instrumento()
                    if self._pruebas_widget and hasattr(self._pruebas_widget, 'excentricidad')
                    and hasattr(self._pruebas_widget.excentricidad, 'get_tipo_instrumento')
                    else ""
                ),
                "filas_excentricidad": (
                    data.get("filas_excentricidad")
                    if self._pruebas_widget else None
                ),
                "_es_borrador": True,
            }

            # Guardar con estado 'PROCESO' - sin cerrar la OS
            self._persistir_en_bd(datos_json, obs_text, "PROCESO")

            QMessageBox.information(
                self, "Borrador guardado",
                "Avance guardado exitosamente.\n\n"
                "Podras continuar la captura en cualquier momento\n"
                "presionando nuevamente 'Capturar OS'."
            )
            self.captura_guardada.emit()
            self.accept()

        except Exception as exc:
            logger.error("CapturaDigitalDialog._on_guardar_borrador: %s", exc)
            QMessageBox.critical(
                self, "Error al guardar borrador",
                f"No se pudo guardar el borrador:\n\n{exc}"
            )
        finally:
            self._btn_borrador.setEnabled(True)
            self._btn_borrador.setText("\U0001f4be  Guardar Borrador")

    def _on_guardar(self) -> None:
        tecnico_exec = self._le_tecnico_exec.text().strip()
        # Campo es read-only, se auto-rellena desde la sesion; si por alguna razon
        # queda vacio, se usa el nombre del tecnico asignado de los datos de la OS.
        if not tecnico_exec:
            tecnico_exec = (self._os_data.get("tecnico_nombre")
                            or self._os_data.get("tecnico", "")
                            or "Tecnico")
            self._le_tecnico_exec.setText(tecnico_exec)

        self._btn_guardar.setEnabled(False)
        self._btn_guardar.setText("Guardando...")
        try:
            # ── Filtrar filas vacías (sin carga ni lectura) ─────────────────
            def _filtrar_filas(rows: list) -> list:
                resultado = []
                for r in rows:
                    tiene_carga = (
                        r.get('valor') is not None or
                        r.get('valor_nominal') is not None or
                        r.get('carga') is not None
                    )
                    tiene_lectura = (
                        r.get('lectura_final') is not None or
                        r.get('lectura_inicial') is not None
                    )
                    if tiene_carga or tiene_lectura:
                        resultado.append(r)
                return resultado

            rep_rows = exc_rows = exac_rows = []
            if self._pruebas_widget:
                try:
                    data = self._pruebas_widget.get_all_data()
                    rep_rows  = _filtrar_filas(data.get("repetibilidad", []))
                    exc_rows  = _filtrar_filas(data.get("excentricidad", []))
                    exac_rows = _filtrar_filas(data.get("exactitud", []))
                except AttributeError:
                    try:
                        rep_rows  = self._pruebas_widget.repetibilidad_widget.get_rows()
                        exc_rows  = self._pruebas_widget.excentricidad_widget.get_rows()
                        exac_rows = self._pruebas_widget.exactitud_widget.get_rows()
                        rep_rows  = _filtrar_filas(rep_rows)
                        exc_rows  = _filtrar_filas(exc_rows)
                        exac_rows = _filtrar_filas(exac_rows)
                    except AttributeError:
                        pass

            jia = {"j": False, "i": False, "a": False}
            dictamen = "APTO"
            obs_text = self._txt_obs.toPlainText().strip() if hasattr(self, "_txt_obs") else ""
            cliente_firma = getattr(self, '_le_cliente_firma', None)
            cliente_firma_text = cliente_firma.text().strip() if cliente_firma else ""

            # Validar nombre del cliente antes de generar PDF final
            if not cliente_firma_text:
                QMessageBox.warning(
                    self,
                    "Campo obligatorio",
                    "Debes ingresar el nombre de quien recibe / conforme cliente\n"
                    "antes de generar el PDF final."
                )
                self._btn_guardar.setEnabled(True)
                self._btn_guardar.setText("🖨  Guardar y Generar PDF Final")
                return

            # Filtrar filas vacías (sin carga/valor nominal) antes de guardar/PDF
            def _filtrar_filas(rows: list) -> list:
                resultado = []
                for r in rows:
                    # Una fila activa debe tener al menos una lectura final o un valor
                    tiene_carga = (
                        r.get('valor') is not None or
                        r.get('valor_nominal') is not None or
                        r.get('carga') is not None
                    )
                    tiene_lectura = (
                        r.get('lectura_final') is not None or
                        r.get('lectura_inicial') is not None
                    )
                    if tiene_carga or tiene_lectura:
                        resultado.append(r)
                return resultado

            datos_json = {
                **self._datos_json_previos,
                "repetibilidad":  rep_rows,
                "excentricidad":  exc_rows,
                "exactitud":      exac_rows,
                "estado_previo":  jia,
                "dictamen":       dictamen,
                "observaciones":  obs_text,
                "tecnico_ejecutor": tecnico_exec,
                "captura_digital":  True,
                "marca": self._le_marca.text().strip(),
                "modelo": self._le_modelo.text().strip(),
                "serie": self._le_serie.text().strip(),
                "id_equipo": self._le_id_equipo.text().strip(),
                "numero_cca": self._le_num_cca.text().strip(),
                "inicial_calibrador": self._cmb_inicial.currentText(),
                "holograma_anterior": self._le_holo_ant.text().strip(),
                "holograma_nuevo": self._le_holo_nuevo.text().strip(),
                "dve": self._le_dve.text().strip(),
                "alcance_max": self._le_capacidad.text().strip(),
                "div_minima": self._le_div_min.text().strip(),
                "unidad_medida": self._cmb_unidad.currentText(),  # kg / g / t / lb
                "ubicacion": self._le_ubicacion.text().strip(),
                "aplica_excentricidad": (self._cmb_excentricidad.currentText() == "Sí"),
                "motivo_no_aplica": self._motivo_no_aplica if self._cmb_excentricidad.currentText() != "Sí" else "",
                "leyenda_excentricidad": (
                    "El tipo de instrumento no es apto para realizar prueba de excentricidad"
                    if self._cmb_excentricidad.currentText() != "Sí" else ""
                ),
                "tipo_receptor": self._cmb_receptor.currentText(),
                # Nuevos campos
                "funcionamiento": self._cmb_funcionamiento.currentText(),
                "puntos_apoyo": self._spn_puntos_apoyo.value(),
                "cliente_firma": cliente_firma_text,
            }
            os_data_pdf = {
                **self._os_data,
                "folio_os":      self._os_data.get("folio_os", self._folio),
                "observaciones": obs_text,
                "dictamen":      dictamen,
                "jia_j": jia["j"], "jia_i": jia["i"], "jia_a": jia["a"],
                "repetibilidad":  rep_rows,
                "excentricidad":  exc_rows,
                "exactitud":      exac_rows,
                "marca": self._le_marca.text().strip() or self._os_data.get("marca", ""),
                "modelo": self._le_modelo.text().strip() or self._os_data.get("modelo", ""),
                "ns": self._le_serie.text().strip() or self._os_data.get("ns", ""),
                "id_equipo": self._le_id_equipo.text().strip() or self._os_data.get("id_equipo", ""),
                "numero_cca": self._le_num_cca.text().strip() or self._os_data.get("numero_cca", ""),
                "inicial_calibrador": self._cmb_inicial.currentText() or self._os_data.get("inicial_calibrador", ""),
                "holograma_anterior": self._le_holo_ant.text().strip() or self._os_data.get("holograma_anterior", ""),
                "holograma_nuevo": self._le_holo_nuevo.text().strip() or self._os_data.get("holograma_nuevo", ""),
                "div_verificacion": self._le_dve.text().strip() or self._os_data.get("div_verificacion", ""),
                "alcance_max": self._le_capacidad.text().strip() or self._os_data.get("alcance_max", ""),
                "div_minima": self._le_div_min.text().strip() or self._os_data.get("div_minima", ""),
                "unidad_medida": self._cmb_unidad.currentText(),  # para títulos dinámicos en PDF
                "ubicacion": self._le_ubicacion.text().strip() or self._os_data.get("ubicacion", ""),
                "aplica_excentricidad": (self._cmb_excentricidad.currentText() == "Sí"),
                "motivo_no_aplica": self._motivo_no_aplica if self._cmb_excentricidad.currentText() != "Sí" else "",
                "leyenda_excentricidad": (
                    "El tipo de instrumento no es apto para realizar prueba de excentricidad"
                    if self._cmb_excentricidad.currentText() != "Sí" else ""
                ),
                "tipo_receptor": self._cmb_receptor.currentText(),
                # Nuevos campos
                "funcionamiento": self._cmb_funcionamiento.currentText(),
                "puntos_apoyo": self._spn_puntos_apoyo.value(),
                "cliente_firma": cliente_firma_text,
                "firma_cliente_nombre": cliente_firma_text,
            }
            # Fecha real de ejecución metrológica = hoy al generar el PDF final
            from datetime import date as _today_mod
            _fecha_servicio = _today_mod.today().strftime("%Y-%m-%d")
            os_data_pdf["fecha_servicio"] = _fecha_servicio


            # Buscar firma del técnico asignado
            firma_tecnico_b64 = self._get_firma_tecnico()

            nuevo_estado = "COMPLETADA"   # Estado canónico del check constraint
            self._persistir_en_bd(datos_json, obs_text, nuevo_estado)
            pdf_path = self._generar_pdf(
                os_data_pdf, rep_rows, exc_rows, exac_rows, tecnico_exec,
                firma_tecnico_b64=firma_tecnico_b64,
            )

            if pdf_path and os.path.exists(pdf_path):
                self._open_file(pdf_path)

            self.captura_guardada.emit()
            QMessageBox.information(
                self, "Guardado correctamente",
                f"La captura digital se guardo exitosamente.\n\n"
                f"PDF generado:\n  {pdf_path or '(no disponible)'}"
            )
            self.accept()

        except Exception as exc:
            logger.error("CapturaDigitalDialog._on_guardar: %s", exc)
            QMessageBox.critical(
                self, "Error al guardar",
                f"Ocurrio un error durante el guardado:\n\n{exc}"
            )
        finally:
            self._btn_guardar.setEnabled(True)
            self._btn_guardar.setText("💾  Guardar y Generar PDF Final")

    def _persistir_en_bd(
        self, datos_json: dict, obs: str, nuevo_estado: str
    ) -> None:
        if not _DEPS_OK or _db_pool is None:
            logger.warning("_persistir_en_bd: dependencias no disponibles, datos NO guardados")
            return
        if not self._os_id:
            raise ValueError(f"ID de orden de servicio inválido: {self._os_id!r}")

        conn = _db_pool.get_connection()
        try:
            # Limpiar cualquier transacción abortada previa del pool
            try:
                conn.rollback()
            except Exception:
                pass

            json_str = json.dumps(datos_json, ensure_ascii=False, default=str)
            # Extraer firma_cliente_nombre del payload para guardar en columna dedicada
            firma_cli = str(datos_json.get("cliente_firma") or
                           datos_json.get("firma_cliente_nombre") or "").strip()

            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE ordenes_servicio "
                    "SET datos_tecnicos_json = %s, "
                    "    observaciones       = %s, "
                    "    estado              = %s, "
                    "    modalidad           = 'Digital', "
                    "    firma_cliente_nombre = %s, "
                    "    fecha_servicio      = CURRENT_DATE, "
                    "    updated_at          = NOW() "
                    "WHERE id = %s",
                    (json_str, obs, nuevo_estado, firma_cli, self._os_id)
                )
                affected = cur.rowcount

            conn.commit()

            if affected == 0:
                raise RuntimeError(
                    f"El UPDATE no afectó ninguna fila (id={self._os_id}). "
                    "Verifica que la orden exista en la BD."
                )
            logger.info("OS id=%s guardada correctamente (%s filas, estado=%s)",
                        self._os_id, affected, nuevo_estado)
        except Exception:
            try:
                conn.rollback()
            except Exception:
                pass
            raise
        finally:
            _db_pool.release_connection(conn)

    def _get_firma_tecnico(self) -> Optional[str]:
        """Obtiene la firma digital (base64) del técnico asignado desde la BD."""
        if not _DEPS_OK or _db_pool is None:
            return None
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT tc.firma_digital
                        FROM ordenes_servicio os
                        JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
                        WHERE os.id = %s AND tc.firma_digital IS NOT NULL
                        """,
                        (self._os_id,)
                    )
                    row = cur.fetchone()
                    return row[0] if row else None
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            logger.warning("No se pudo obtener firma del técnico: %s", exc)
            return None

    def _generar_pdf(
        self,
        os_data: dict,
        rep_rows: list,
        exc_rows: list,
        exac_rows: list,
        tecnico_nombre: str,
        firma_tecnico_b64: Optional[str] = None,
    ) -> Optional[str]:
        import traceback as _tb
        try:
            from services.os_pdf_generator import OsPdfGenerator
            gen = OsPdfGenerator()
            path = gen.generate_os_pdf(
                os_data       = os_data,
                repetibilidad = rep_rows,
                excentricidad = exc_rows,
                exactitud     = exac_rows,
                tecnico_nombre= tecnico_nombre,
                firma_tecnico_b64 = firma_tecnico_b64,
                digital       = True,
                force         = True,
            )
            if not path or not os.path.exists(path):
                logger.error("_generar_pdf: el generador no devolvió ruta válida — retornó: %r", path)
                return None
            return path
        except Exception as exc:
            _tb.print_exc()   # Imprime el traceback completo en la consola
            logger.error("_generar_pdf EXCEPTION: %s", exc)
            # Mostrar el error real al usuario
            QMessageBox.warning(
                self, "Error al generar PDF",
                f"El PDF no pudo generarse.\n\nError:\n{exc}\n\n"
                f"Revisa la consola para el detalle completo."
            )
            return None

    @staticmethod
    def _open_file(path: str) -> None:
        try:
            if sys.platform == "win32":
                os.startfile(path)
            elif sys.platform == "darwin":
                subprocess.run(["open", path], check=False)
            else:
                subprocess.run(["xdg-open", path], check=False)
        except Exception as exc:
            logger.warning("No se pudo abrir el PDF: %s", exc)

    # ── Autocomplete histórico de Marca / Modelo / Ubicación ─────────────────

    def _load_autocomplete_historico(self) -> None:
        """
        Consulta el historial de órdenes del mismo cliente y adjunta
        QCompleter a los campos Marca, Modelo y Ubicación para sugerir
        valores ya usados en visitas anteriores.
        """
        if not _DEPS_OK or _db_pool is None:
            return

        id_cliente = self._os_data.get('id_cliente') or self._os_data.get('cliente_id')
        if not id_cliente:
            # Intentar obtenerlo por nombre del cliente
            nombre_cliente = self._os_data.get('cliente', '')
            if nombre_cliente:
                try:
                    row = _db_pool.execute_one(
                        "SELECT id FROM clientes WHERE LOWER(TRIM(nombre)) = LOWER(TRIM(%s)) LIMIT 1",
                        (nombre_cliente,)
                    )
                    if row:
                        id_cliente = row.get('id')
                except Exception:
                    pass

        try:
            if id_cliente:
                rows = _db_pool.execute_many(
                    """
                    SELECT DISTINCT
                        NULLIF(TRIM(marca),    '') AS marca,
                        NULLIF(TRIM(modelo),   '') AS modelo,
                        NULLIF(TRIM(ubicacion),'') AS ubicacion
                    FROM ordenes_servicio
                    WHERE id_cliente = %s
                      AND (marca IS NOT NULL OR modelo IS NOT NULL OR ubicacion IS NOT NULL)
                    ORDER BY marca, modelo
                    LIMIT 200
                    """,
                    (id_cliente,)
                )
            else:
                # Sin id_cliente: muestra sugerencias globales (últimas 100 únicas)
                rows = _db_pool.execute_many(
                    """
                    SELECT DISTINCT
                        NULLIF(TRIM(marca),    '') AS marca,
                        NULLIF(TRIM(modelo),   '') AS modelo,
                        NULLIF(TRIM(ubicacion),'') AS ubicacion
                    FROM ordenes_servicio
                    WHERE marca IS NOT NULL
                    ORDER BY marca, modelo
                    LIMIT 100
                    """
                )

            marcas    = sorted({r.get('marca')    for r in rows if r.get('marca')})
            modelos   = sorted({r.get('modelo')   for r in rows if r.get('modelo')})
            ubicaciones = sorted({r.get('ubicacion') for r in rows if r.get('ubicacion')})

            def _attach_completer(line_edit: QLineEdit, suggestions: list[str]) -> None:
                if not suggestions:
                    return
                model = QStringListModel(suggestions, line_edit)
                comp  = QCompleter(model, line_edit)
                comp.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
                comp.setFilterMode(Qt.MatchFlag.MatchContains)
                comp.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
                line_edit.setCompleter(comp)

            _attach_completer(self._le_marca,    marcas)
            _attach_completer(self._le_modelo,   modelos)
            _attach_completer(self._le_ubicacion, ubicaciones)

            logger.debug(
                "[Autocomplete] cliente=%s → %d marcas, %d modelos, %d ubicaciones",
                id_cliente, len(marcas), len(modelos), len(ubicaciones)
            )

        except Exception as exc:
            logger.warning("[Autocomplete] No se pudo cargar historial: %s", exc)