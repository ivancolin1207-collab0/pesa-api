"""
Formulario para Levantamiento de Proyecto (LP).
"""
import logging
from datetime import date
from typing import Optional
import json

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QDateEdit,
    QGroupBox, QFormLayout, QScrollArea, QFrame, QMessageBox,
    QTableWidget, QTableWidgetItem, QHeaderView, QCheckBox,
    QGridLayout,
)
from PyQt6.QtCore import Qt, pyqtSignal, QDate
from PyQt6.QtGui import QFont

from database.connection import db_pool
from models.orden_servicio import orden_servicio_repo

logger = logging.getLogger(__name__)

def _make_line_edit(placeholder: str = "", max_len: int = 200) -> QLineEdit:
    le = QLineEdit()
    le.setPlaceholderText(placeholder)
    le.setMaxLength(max_len)
    return le

def _section_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setStyleSheet(
        "color:#D32F2F; font-size:11px; font-weight:800; "
        "letter-spacing:1.2px; padding:4px 0;"
    )
    return lbl

class LPFormWidget(QWidget):
    os_saved = pyqtSignal(str)   # folio_os

    def __init__(self, os_id: Optional[int] = None, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._os_id   = os_id
        self._is_edit = os_id is not None
        self._folio_os: str = ""

        # Catálogos
        self._clientes:   list[dict] = []
        self._tecnicos:   list[dict] = []
        self._sucursales: list[dict] = []   # sucursales del cliente activo

        self._setup_ui()
        self._load_catalogos()

        if self._is_edit:
            self._load_lp(os_id)

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("QScrollArea { background-color: #F5F5F7; }")
        root.addWidget(scroll)

        content = QWidget()
        content.setStyleSheet("QWidget { background-color: #F5F5F7; }")
        scroll.setWidget(content)

        main_lay = QVBoxLayout(content)
        main_lay.setContentsMargins(20, 20, 20, 40)
        main_lay.setSpacing(16)

        # ── Encabezado (ID, Fecha) ──
        header_lay = QHBoxLayout()
        title = QLabel("Levantamiento de Proyecto (LP)")
        title.setStyleSheet("font-size:24px; font-weight:700; color:#1D1D1F; letter-spacing:-0.5px;")
        header_lay.addWidget(title)
        header_lay.addStretch()

        self._lbl_folio = QLabel("NUEVO LP")
        self._lbl_folio.setStyleSheet("font-size:15px; font-weight:700; color:#D32F2F; padding:4px 8px; background:#FFE5E5; border-radius:6px;")
        header_lay.addWidget(self._lbl_folio)

        main_lay.addLayout(header_lay)

        # ── Bloque 1: Cliente y Datos Generales ──
        gb_cliente = QGroupBox("1. DATOS DEL CLIENTE Y FECHA")
        gb_cliente.setStyleSheet("QGroupBox { font-weight:bold; border:1px solid #D1D1D6; border-radius:8px; margin-top:10px; } QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 3px 0 3px; }")
        form_cliente = QFormLayout(gb_cliente)
        
        self._combo_cliente = QComboBox()
        self._combo_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        form_cliente.addRow("Cliente:", self._combo_cliente)

        self._combo_sucursal = QComboBox()
        self._combo_sucursal.setEnabled(False)
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        form_cliente.addRow("Sucursal/Planta:", self._combo_sucursal)
        # Etiqueta de dirección autocompleta
        self._lbl_suc_dir = QLabel("")
        self._lbl_suc_dir.setStyleSheet("color:#86868B; font-size:9px; font-style:italic;")
        self._lbl_suc_dir.setWordWrap(True)
        form_cliente.addRow("", self._lbl_suc_dir)
        # Señal de sucursal
        self._combo_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)
        
        self._combo_tecnico = QComboBox()
        form_cliente.addRow("Técnico Asignado:", self._combo_tecnico)

        self._date_fecha = QDateEdit()
        self._date_fecha.setCalendarPopup(True)
        self._date_fecha.setDate(QDate.currentDate())
        form_cliente.addRow("Fecha:", self._date_fecha)

        main_lay.addWidget(gb_cliente)

        # ── Bloque A: Especificaciones Técnicas ──
        gb_specs = QGroupBox("2. ESPECIFICACIONES TÉCNICAS")
        gb_specs.setStyleSheet(gb_cliente.styleSheet())
        form_specs = QFormLayout(gb_specs)

        self._le_material = _make_line_edit("Ej. Acero al carbón, Inoxidable, N/A...")
        self._le_clasificacion = _make_line_edit("Ej. Estándar, Intrínsecamente Segura...")
        self._le_comunicacion = _make_line_edit("Ej. 4-20mA, Tarjeta PLC, N/A...")
        self._le_puntos_corte = _make_line_edit("Ej. Sí Aplica, No Aplica")
        self._le_capacidad = _make_line_edit("Ej. 10 Toneladas")
        self._le_alturas = _make_line_edit("Ej. Sí Aplica, No Aplica")
        self._le_cursos = _make_line_edit("Ej. Sí (Especificar...), No")

        form_specs.addRow("Material/Construcción:", self._le_material)
        form_specs.addRow("Clasificación de Área:", self._le_clasificacion)
        form_specs.addRow("Salida de Comunicación:", self._le_comunicacion)
        form_specs.addRow("Puntos de Corte:", self._le_puntos_corte)
        form_specs.addRow("Capacidad Estimada:", self._le_capacidad)
        form_specs.addRow("Trabajo en Alturas:", self._le_alturas)
        form_specs.addRow("Cursos / Inducción:", self._le_cursos)

        main_lay.addWidget(gb_specs)

        # ── Bloque Especializado A: Tanques ──
        gb_tanques = QGroupBox("Bloque Especializado A: Sistemas de Pesaje (Tanques/Silos)")
        gb_tanques.setStyleSheet(gb_cliente.styleSheet())
        form_tanques = QFormLayout(gb_tanques)
        self._le_tanque_estructura = _make_line_edit("Ej. Ya cuenta con estructura, Requiere diseño...")
        self._le_tanque_puntos = _make_line_edit("Ej. 3 Puntos, 4 Puntos")
        self._le_tanque_agitador = _make_line_edit("Ej. Sí incluye agitador, No")
        self._le_tanque_peso_muerto = _make_line_edit("Ej. 1500 kg")
        self._le_tanque_capacidad_util = _make_line_edit("Ej. 5000 kg")
        form_tanques.addRow("Estructura Existente:", self._le_tanque_estructura)
        form_tanques.addRow("Puntos de Apoyo/Celdas:", self._le_tanque_puntos)
        form_tanques.addRow("Agitador/Mezclador:", self._le_tanque_agitador)
        form_tanques.addRow("Peso Muerto del Tanque:", self._le_tanque_peso_muerto)
        form_tanques.addRow("Capacidad Útil / Peso a Pesarse:", self._le_tanque_capacidad_util)
        main_lay.addWidget(gb_tanques)

        # ── Bloque Especializado B: Básculas Camioneras ──
        gb_camioneras = QGroupBox("Bloque Especializado B: Básculas Camioneras / Ferrocarril / Fosa")
        gb_camioneras.setStyleSheet(gb_cliente.styleSheet())
        form_camioneras = QFormLayout(gb_camioneras)
        self._le_cam_tipo = _make_line_edit("Ej. Sobre Piso, En Fosa, Rampas...")
        self._le_cam_dimensiones = _make_line_edit("Ej. 12 m x 3 m")
        self._le_cam_capacidad = _make_line_edit("Ej. 80 Toneladas")
        self._le_cam_trafico = _make_line_edit("Ej. Camionera, FFCC...")
        self._le_cam_obra = _make_line_edit("Ej. Cliente realiza obra, PESA incluye...")
        form_camioneras.addRow("Tipo de Instalación:", self._le_cam_tipo)
        form_camioneras.addRow("Dimensiones Requeridas:", self._le_cam_dimensiones)
        form_camioneras.addRow("Capacidad Máxima:", self._le_cam_capacidad)
        form_camioneras.addRow("Báscula Tipo (Camionera o FFCC):", self._le_cam_trafico)
        form_camioneras.addRow("Guías / Obras Civiles:", self._le_cam_obra)
        main_lay.addWidget(gb_camioneras)

        # ── Bloque B: Equipos / Instrumentación ──
        gb_equipos = QGroupBox("3. EQUIPOS E INSTRUMENTACIÓN EXISTENTE (Bloque B)")
        gb_equipos.setStyleSheet(gb_cliente.styleSheet())
        lay_equipos = QVBoxLayout(gb_equipos)

        self._table_equipos = QTableWidget(0, 4)
        self._table_equipos.setHorizontalHeaderLabels(["Marca", "Modelo", "Capacidad", "Observaciones"])
        self._table_equipos.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self._table_equipos.setFixedHeight(150)
        lay_equipos.addWidget(self._table_equipos)

        btn_add_equipo = QPushButton("＋ Agregar Equipo")
        btn_add_equipo.clicked.connect(self._add_equipo_row)
        lay_equipos.addWidget(btn_add_equipo)

        main_lay.addWidget(gb_equipos)

        # ── Bloque C: Requerimientos Adicionales ──
        gb_req = QGroupBox("4. REQUERIMIENTOS ADICIONALES (Checkboxes)")
        gb_req.setStyleSheet(gb_cliente.styleSheet())
        lay_req = QGridLayout(gb_req)

        # Grupos de Checkboxes
        self._checks_instrumentacion = [
            QCheckBox("Indicador"), QCheckBox("Celdas de Carga"), 
            QCheckBox("Caja Suma"), QCheckBox("Cableado"), QCheckBox("Display Repetidor")
        ]
        self._checks_maniobra = [
            QCheckBox("Montacargas"), QCheckBox("Grúa Titán"), QCheckBox("Gatos Hidráulicos"), QCheckBox("Polipasto")
        ]
        self._checks_epp = [
            QCheckBox("Casco"), QCheckBox("Lentes"), QCheckBox("Zapatos de Seguridad"), 
            QCheckBox("Chaleco"), QCheckBox("Arnés"), QCheckBox("Tapones Auditivos")
        ]
        self._checks_masa = [
            QCheckBox("Masas Patrón Propias"), QCheckBox("Masas del Cliente"), QCheckBox("Renta de Masas")
        ]

        def add_checkbox_group(title, checks, col):
            lay_req.addWidget(_section_label(title), 0, col)
            for i, chk in enumerate(checks):
                lay_req.addWidget(chk, i+1, col)

        add_checkbox_group("Instrumentación Req.", self._checks_instrumentacion, 0)
        add_checkbox_group("Equipos de Maniobra", self._checks_maniobra, 1)
        add_checkbox_group("EPP Seguridad", self._checks_epp, 2)
        add_checkbox_group("Masa Requerida", self._checks_masa, 3)

        main_lay.addWidget(gb_req)

        # ── Bloque D: Observaciones Finales ──
        gb_obs = QGroupBox("5. OBSERVACIONES GENERALES")
        gb_obs.setStyleSheet(gb_cliente.styleSheet())
        lay_obs = QVBoxLayout(gb_obs)
        self._txt_observaciones = QTextEdit()
        self._txt_observaciones.setFixedHeight(80)
        lay_obs.addWidget(self._txt_observaciones)
        main_lay.addWidget(gb_obs)

        # ── Barra Inferior ──
        bottom_bar = QFrame()
        bottom_bar.setStyleSheet("background-color:white; border-top:1px solid #E5E5EA;")
        bottom_lay = QHBoxLayout(bottom_bar)
        bottom_lay.setContentsMargins(16, 12, 16, 12)

        self._btn_cancel = QPushButton("Cancelar")
        self._btn_cancel.clicked.connect(self._on_cancel)
        
        self._btn_pdf = QPushButton("📄 Generar PDF")
        self._btn_pdf.setStyleSheet("background-color:#E5E5EA; color:#1D1D1F; font-weight:bold; padding:8px 16px; border-radius:6px;")
        self._btn_pdf.clicked.connect(self._generate_pdf)
        self._btn_pdf.setEnabled(self._is_edit) # Solo activo si ya se guardó
        
        self._btn_save = QPushButton("💾 Guardar LP")
        self._btn_save.setStyleSheet("background-color:#007AFF; color:white; font-weight:bold; padding:8px 16px; border-radius:6px;")
        self._btn_save.clicked.connect(self._on_save)

        bottom_lay.addStretch()
        bottom_lay.addWidget(self._btn_cancel)
        bottom_lay.addWidget(self._btn_pdf)
        bottom_lay.addWidget(self._btn_save)

        root.addWidget(bottom_bar)

    def _add_equipo_row(self, data=None):
        row = self._table_equipos.rowCount()
        self._table_equipos.insertRow(row)
        for col in range(4):
            item = QTableWidgetItem("")
            if data and col < len(data):
                item.setText(data[col])
            self._table_equipos.setItem(row, col, item)

    def _load_catalogos(self):
        try:
            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                # Clientes
                cur.execute("SELECT id, razon_social FROM cat_clientes WHERE activo=TRUE ORDER BY razon_social")
                self._clientes = [{"id": r[0], "razon_social": r[1]} for r in cur.fetchall()]
                
                # Técnicos
                cur.execute("SELECT id, nombre_completo FROM cat_tecnicos WHERE activo=TRUE ORDER BY nombre_completo")
                self._tecnicos = [{"id": r[0], "nombre": r[1]} for r in cur.fetchall()]

            _db_pool.release_connection(conn)
        except Exception:
            pass

        self._combo_cliente.clear()
        self._combo_cliente.addItem("— Seleccione Cliente —", None)
        for c in self._clientes:
            self._combo_cliente.addItem(c["razon_social"], c["id"])

        self._combo_tecnico.clear()
        self._combo_tecnico.addItem("— Seleccione Técnico —", None)
        for t in self._tecnicos:
            self._combo_tecnico.addItem(t["nombre"], t["id"])

    def _on_cliente_changed(self) -> None:
        """Cascade: cargar sucursales del cliente seleccionado."""
        self._combo_sucursal.blockSignals(True)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        self._lbl_suc_dir.clear()
        self._sucursales = []
        self._combo_sucursal.setEnabled(False)

        c_id = self._combo_cliente.currentData()
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
                logger.error("Error cargando sucursales LP: %s", exc)

        self._combo_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, index: int) -> None:
        """Autocompleta la etiqueta de dirección al cambiar sucursal."""
        s_id = self._combo_sucursal.currentData()
        self._lbl_suc_dir.clear()
        if s_id:
            suc = next((s for s in self._sucursales if s["id"] == s_id), None)
            if suc:
                self._lbl_suc_dir.setText(suc.get("direccion") or "")

    def _load_lp(self, os_id: int):
        data = orden_servicio_repo.get_by_id(os_id)
        if not data: return

        self._folio_os = data.get("folio_os", "")
        self._lbl_folio.setText(self._folio_os)

        idx_c = self._combo_cliente.findData(data.get("id_cliente"))
        if idx_c >= 0: self._combo_cliente.setCurrentIndex(idx_c)

        self._combo_sucursal.setCurrentText(data.get("ubicacion") or "")
        
        idx_t = self._combo_tecnico.findData(data.get("id_tecnico"))
        if idx_t >= 0: self._combo_tecnico.setCurrentIndex(idx_t)

        d = data.get("fecha")
        if d: self._date_fecha.setDate(QDate(d.year, d.month, d.day))

        self._txt_observaciones.setPlainText(data.get("observaciones") or "")

        lp = data.get("levantamiento_proyecto", {})
        if lp:
            self._le_material.setText(lp.get("material") or "")
            self._le_clasificacion.setText(lp.get("clasificacion_area") or "")
            self._le_comunicacion.setText(lp.get("senal_comunicacion") or "")
            self._le_puntos_corte.setText(lp.get("puntos_corte") or "")
            self._le_capacidad.setText(lp.get("capacidad_estimada") or "")
            self._le_alturas.setText(lp.get("alturas") or "")
            self._le_cursos.setText(lp.get("cursos") or "")
            
            self._le_tanque_estructura.setText(lp.get("tanque_estructura") or "")
            self._le_tanque_puntos.setText(lp.get("tanque_puntos") or "")
            self._le_tanque_agitador.setText(lp.get("tanque_agitador") or "")
            self._le_tanque_peso_muerto.setText(lp.get("tanque_peso_muerto") or "")
            self._le_tanque_capacidad_util.setText(lp.get("tanque_capacidad_util") or "")
            
            self._le_cam_tipo.setText(lp.get("cam_tipo") or "")
            self._le_cam_dimensiones.setText(lp.get("cam_dimensiones") or "")
            self._le_cam_capacidad.setText(lp.get("cam_capacidad") or "")
            self._le_cam_trafico.setText(lp.get("cam_trafico") or "")
            self._le_cam_obra.setText(lp.get("cam_obra") or "")

            equipos = lp.get("equipos_dinamicos", [])
            for eq in equipos:
                self._add_equipo_row([eq.get("marca",""), eq.get("modelo",""), eq.get("capacidad",""), eq.get("observaciones","")])

            inst = lp.get("instrumentacion", [])
            for chk in self._checks_instrumentacion:
                if chk.text() in inst: chk.setChecked(True)
            
            maniobra = lp.get("equipos_maniobra", [])
            for chk in self._checks_maniobra:
                if chk.text() in maniobra: chk.setChecked(True)
                
            epp = lp.get("epp_seguridad", [])
            for chk in self._checks_epp:
                if chk.text() in epp: chk.setChecked(True)
                
            masa = lp.get("masa_requerida", [])
            for chk in self._checks_masa:
                if chk.text() in masa: chk.setChecked(True)

    def _on_save(self) -> None:
        c_id = self._combo_cliente.currentData()
        if not c_id:
            QMessageBox.warning(self, "Error", "Debe seleccionar un Cliente.")
            return

        equipos_dinamicos = []
        for row in range(self._table_equipos.rowCount()):
            marca = self._table_equipos.item(row, 0).text() if self._table_equipos.item(row, 0) else ""
            if not marca: continue # Saltar vacíos
            equipos_dinamicos.append({
                "marca": marca,
                "modelo": self._table_equipos.item(row, 1).text() if self._table_equipos.item(row, 1) else "",
                "capacidad": self._table_equipos.item(row, 2).text() if self._table_equipos.item(row, 2) else "",
                "observaciones": self._table_equipos.item(row, 3).text() if self._table_equipos.item(row, 3) else "",
            })

        lp_data = {
            "material": self._le_material.text(),
            "clasificacion_area": self._le_clasificacion.text(),
            "senal_comunicacion": self._le_comunicacion.text(),
            "puntos_corte": self._le_puntos_corte.text(),
            "capacidad_estimada": self._le_capacidad.text(),
            "alturas": self._le_alturas.text(),
            "cursos": self._le_cursos.text(),
            
            "tanque_estructura": self._le_tanque_estructura.text(),
            "tanque_puntos": self._le_tanque_puntos.text(),
            "tanque_agitador": self._le_tanque_agitador.text(),
            "tanque_peso_muerto": self._le_tanque_peso_muerto.text(),
            "tanque_capacidad_util": self._le_tanque_capacidad_util.text(),
            
            "cam_tipo": self._le_cam_tipo.text(),
            "cam_dimensiones": self._le_cam_dimensiones.text(),
            "cam_capacidad": self._le_cam_capacidad.text(),
            "cam_trafico": self._le_cam_trafico.text(),
            "cam_obra": self._le_cam_obra.text(),
            
            "equipos_dinamicos": equipos_dinamicos,
            "instrumentacion": [c.text() for c in self._checks_instrumentacion if c.isChecked()],
            "equipos_maniobra": [c.text() for c in self._checks_maniobra if c.isChecked()],
            "epp_seguridad": [c.text() for c in self._checks_epp if c.isChecked()],
            "masa_requerida": [c.text() for c in self._checks_masa if c.isChecked()],
        }

        # Para compatibilidad, metemos "LEVANTAMIENTO" como tipo de servicio en OS
        # Necesitamos el id_tipo_servicio. Como no sabemos el id exacto para LP (no existe en catálogo por defecto, o sí)
        # Lo dejaremos en NULL si no existe, o requerimos uno.
        # Mejor buscar un ID de "Levantamiento" o simplemente dejarlo como Ajuste o 1 y en config el tipo de folio manda.
        # El folio se manda mediante la bandera levantamiento_proyecto.
        
        payload = {
            "fecha": self._date_fecha.date().toPyDate(),
            "id_cliente": c_id,
            "ubicacion":          (
                self._lbl_suc_dir.text().strip() or
                self._combo_sucursal.currentText().strip() or
                ""
            ),
            "direccion":          self._lbl_suc_dir.text().strip(),
            "sucursal_direccion": self._lbl_suc_dir.text().strip(),
            "sucursal_id":        self._combo_sucursal.currentData(),
            "id_tecnico": self._combo_tecnico.currentData(),
            "observaciones": self._txt_observaciones.toPlainText(),
            "estado": "PROCESO",
            
            # Campos OS obligatorios a nulos o vacíos
            "id_tipo_servicio": 1, # Placeholder, LP no usa metrología de OS
            "id_equipo": None,
            "id_tipo_instrumento": None,
            "numero_cca": None,
            "holograma_anterior": None,
            "holograma_actualizado": None,
            "valor_repetibilidad": None,
            "valor_excentricidad": None,
            "id_clase_exactitud": None,
            "firma_cliente_nombre": None,
            "marca": None, "modelo": None, "ns": None, 
            "alcance_max": None, "div_minima": None, "div_verificacion": None,
            "levantamiento_proyecto": lp_data
        }

        try:
            if self._is_edit:
                res = orden_servicio_repo.update(self._os_id, payload)
                folio = res.get("folio_os", "")
            else:
                res = orden_servicio_repo.create(payload)
                folio = res.get("folio_os", "")

            self.os_saved.emit(folio)
            self._is_edit = True
            self._os_id = res.get("id")
            self._folio_os = folio
            self._lbl_folio.setText(folio)
            self._btn_pdf.setEnabled(True)
        except Exception as exc:
            logger.exception("Error guardando LP")
            QMessageBox.critical(self, "Error", f"Fallo al guardar:\n{exc}")

    def _on_cancel(self):
        parent = self.parent()
        while parent and not hasattr(parent, "_navigate"):
            parent = parent.parent()
        if parent: parent._navigate("dashboard")

    def _generate_pdf(self) -> None:
        """Genera el PDF de la OS actual y lo abre con el visor del sistema."""
        if not self._os_id:
            QMessageBox.warning(self, "Sin LP", "Guarde primero el formato para poder generar el PDF.")
            return

        try:
            from services.lp_pdf_generator import LPPdfGenerator
            import subprocess
            import os

            os_data = orden_servicio_repo.get_by_id(self._os_id)
            if not os_data:
                QMessageBox.warning(self, "Error", "No se encontraron los datos del LP.")
                return
                
            os_data["tecnico_nombre"] = self._combo_tecnico.currentText()
            os_data["cliente_nombre"] = self._combo_cliente.currentText()
            # Inyectar dirección unificada
            addr = self._lbl_suc_dir.text().strip()
            if addr:
                os_data["direccion"]          = addr
                os_data["sucursal_direccion"] = addr

            self._btn_pdf.setEnabled(False)
            self._btn_pdf.setText("Generando...")

            gen = LPPdfGenerator()
            path = gen.generate(os_data=os_data, force=True)

            QMessageBox.information(
                self, "PDF Generado",
                f"PDF generado exitosamente:\n{path}\n\nSe abrirá con el visor predeterminado."
            )

            if os.name == "nt":
                os.startfile(path)
            else:
                subprocess.Popen(["xdg-open", path])

        except Exception as exc:
            logger.error(f"Error al generar PDF LP: {exc}")
            QMessageBox.critical(self, "Error PDF", f"No se pudo generar el PDF:\n{exc}")
        finally:
            self._btn_pdf.setEnabled(True)
            self._btn_pdf.setText("📄 Generar PDF")
