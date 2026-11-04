"""
osob_digital_dialog.py — Ventana de Captura Digital para Folios OSOB-
(FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS)
Servicios PESA
"""
from __future__ import annotations
import json
import logging
from datetime import datetime
from typing import Optional

from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QScrollArea, QWidget, QFrame,
    QGroupBox, QCheckBox, QRadioButton, QButtonGroup, QMessageBox,
)
from PyQt6.QtCore import Qt, pyqtSignal

from ui.dialogs.digital_service_dialog import DrawingCanvas

logger = logging.getLogger(__name__)

try:
    from database.connection import db_pool as _db_pool
except ImportError:
    _db_pool = None


class OsobDigitalDialog(QDialog):
    """Formulario digital exclusivo para folios OSOB- (Inspección y Revisión de Básculas)."""

    captura_guardada = pyqtSignal()

    CHECKLIST_GROUPS = [
        (
            "A) Estructura y Receptor de Carga",
            [
                (1, "1. Charola / Plato / Cubierta (Sin golpes, deformaciones ni corrosión)"),
                (2, "2. Estructura inferior / Chasis (Soldaduras íntegras, sin fracturas ni óxido severo)"),
                (3, "3. Patas niveladoras (Completas, roscas en buen estado, gomas antiderrapantes firmes)"),
                (4, "4. Nivelación - Gota / Burbuja (Burbuja centrada y nivel visible sin daños)"),
                (5, "5. Topes de sobrecarga y laterales (Con holgura adecuada, sin rozamiento ni obstrucciones)"),
                (6, "6. Limpieza general (Libre de residuos, polvo acumulado, humedad o fauna nociva bajo el plato)"),
            ],
        ),
        (
            "B) Celdas y Transmisión",
            [
                (7, "7. Celda(s) de carga (Sin golpes visibles, corrosión, humedad ni deformación)"),
                (8, "8. Cableado y blindaje (Sin cortes, empalmes improvisados ni aplastamiento; prensaestopas firmes)"),
                (9, "9. Caja suma (Sellada herméticamente, sin sulfatación en bornes ni humedad)"),
            ],
        ),
        (
            "C) Indicador y Electrónica",
            [
                (10, "10. Carcasa y soporte / columna (Fijación firme, sellos en buen estado)"),
                (11, "11. Display / Pantalla (Segmentos o píxeles completos, retroiluminación funcional)"),
                (12, "12. Teclado / Botonera (Membrana íntegra sin perforaciones, respuesta táctil correcta)"),
                (13, "13. Alimentación / Batería (Cable de poder/eliminador sin daños; retención de carga en batería)"),
                (14, "14. Puertos de comunicación (RS-232 / USB / Ethernet / Wi-Fi operando correctamente)"),
            ],
        ),
    ]

    PRUEBAS_RAPIDAS = [
        ("estabilidad_cero", "Estabilidad de Cero al encendido", "Comentarios", False),
        ("retorno_cero", "Retorno a Cero tras descarga", "Comentarios", False),
        ("excentricidad_esquinas", "Prueba de Excentricidad (Esquinas)", "Dif. máx. detectada", False),
        ("repetibilidad_lectura", "Repetibilidad de lectura", "Carga de prueba", False),
        ("exactitud_preliminar", "Exactitud preliminar de pesaje", "Requiere ajuste", True),
    ]

    ACCIONES_REVISION = [
        ("limpieza", "Limpieza superficial e interna"),
        ("nivelacion", "Nivelación de patas y ajuste de topes"),
        ("ajuste_peso", "Ajuste de peso (calibración interna / ajuste con masa patrón)"),
        ("revision_electrica", "Revisión eléctrica y reapriete de conexiones"),
    ]

    DICTAMENES = [
        ("OPERATIVO", "OPERATIVO (Apto para uso normal / Listo para calibración)"),
        (
            "OPERATIVO CON OBSERVACIONES",
            "OPERATIVO CON OBSERVACIONES (Funciona, pero requiere mantenimiento preventivo/correctivo pronto)",
        ),
        ("FUERA DE SERVICIO", "FUERA DE SERVICIO (No apto para uso hasta reparación)"),
    ]

    def __init__(
        self,
        os_id: int = 0,
        folio: str = "",
        orden_data: Optional[dict] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        if isinstance(os_id, dict) and orden_data is None:
            orden_data = os_id
            os_id = int(orden_data.get("id") or orden_data.get("os_id") or 0)
            folio = folio or str(orden_data.get("folio_os") or orden_data.get("folio") or "")
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._os_id = os_id
        self._folio = str(folio or (orden_data or {}).get("folio_os") or (orden_data or {}).get("folio") or "OSOB-26-001").strip()
        self._os_data = dict(orden_data or {})
        self._chk_widgets: dict[int, tuple[QComboBox, QLineEdit]] = {}
        self._pruebas_widgets: dict[str, tuple[QComboBox, QWidget]] = {}
        self._acciones_checks: dict[str, QCheckBox] = {}
        self._dictamen_group = QButtonGroup(self)
        self._dictamen_radios: dict[str, QRadioButton] = {}

        self.setWindowTitle(f"Inspección y Revisión ({self._folio}) — OSOB DIGITAL")
        self.setMinimumSize(1020, 760)
        self.setWindowFlags(
            Qt.WindowType.Dialog
            | Qt.WindowType.WindowCloseButtonHint
            | Qt.WindowType.WindowMinMaxButtonsHint
        )
        self.setStyleSheet("QDialog { background: #F5F6FA; }")
        self._load_db_data()
        self._setup_ui()
        self._populate_initial_values()

    def _load_db_data(self) -> None:
        if not _db_pool or not self._folio:
            return
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT os.id, os.folio_os, os.fecha,
                               COALESCE(c.nombre, '') AS cliente,
                               COALESCE(s.nombre, '') AS sucursal,
                               COALESCE(s.direccion, c.direccion, '') AS direccion,
                               COALESCE(t.nombre, '') AS tecnico,
                               COALESCE(os.tipo_instrumento, '') AS tipo_instrumento,
                               COALESCE(os.marca, '') AS marca,
                               COALESCE(os.modelo, '') AS modelo,
                               COALESCE(os.ns, '') AS ns,
                               COALESCE(os.id_equipo, '') AS id_equipo,
                               COALESCE(os.ubicacion, '') AS ubicacion,
                               os.alcance_max, os.div_minima,
                               COALESCE(os.instrumento_capacidad, '') AS instrumento_capacidad,
                               COALESCE(os.instrumento_division, '') AS instrumento_division,
                               COALESCE(os.unidad_medida, 'kg') AS unidad_medida,
                               COALESCE(os.observaciones, '') AS observaciones,
                               COALESCE(os.dictamen, '') AS dictamen,
                               COALESCE(os.nombre_ing, '') AS nombre_ing,
                               COALESCE(os.puesto_ing, '') AS puesto_ing,
                               os.datos_tecnicos_json
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes c ON os.id_cliente = c.id
                        LEFT JOIN cat_sucursales_cliente s ON os.id_sucursal = s.id
                        LEFT JOIN cat_tecnicos t ON os.id_tecnico = t.id
                        WHERE os.folio_os = %s
                        LIMIT 1
                        """,
                        (self._folio,),
                    )
                    row = cur.fetchone()
                    if row:
                        cols = [d[0] for d in cur.description]
                        db_map = dict(zip(cols, row))
                        for k, v in db_map.items():
                            if v not in (None, ""):
                                self._os_data[k] = v
                        if not self._os_id and db_map.get("id"):
                            self._os_id = int(db_map["id"])
                conn.commit()
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            logger.warning("OsobDigitalDialog._load_db_data error: %s", exc)

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header oscuro institucional
        hdr = QFrame()
        hdr.setStyleSheet("QFrame { background: #1C1C1E; padding: 12px 18px; }")
        hl = QHBoxLayout(hdr)
        lbl_title = QLabel(
            f"<span style='color:#FFFFFF; font-size:13pt; font-weight:800;'>"
            f"FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS</span><br>"
            f"<span style='color:#FF6B6B; font-size:10pt; font-weight:700;'>"
            f"Folio: {self._folio}</span>"
            f"<span style='color:#D1D5DB; font-size:9.5pt;'>  |  Fecha: {datetime.now().strftime('%d / %m / %Y')}</span>"
        )
        hl.addWidget(lbl_title, 1)

        badge = QLabel("OSOB DIGITAL")
        badge.setStyleSheet(
            "background: #C8102E; color: white; font-weight: 800; font-size: 9pt; "
            "padding: 5px 12px; border-radius: 6px;"
        )
        hl.addWidget(badge, 0, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        root.addWidget(hdr)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        bl = QVBoxLayout(body)
        bl.setContentsMargins(16, 14, 16, 16)
        bl.setSpacing(14)

        # Cabecera de control: Orden de Servicio vinculada
        ctrl_box = QGroupBox("Cabecera de Control")
        ctrl_l = QHBoxLayout(ctrl_box)
        ctrl_l.addWidget(QLabel(f"<b>Folio:</b> {self._folio}"))
        ctrl_l.addSpacing(16)
        ctrl_l.addWidget(QLabel(f"<b>Fecha:</b> {datetime.now().strftime('%d / %m / %Y')}"))
        ctrl_l.addSpacing(16)
        ctrl_l.addWidget(QLabel("<b>Orden de Servicio vinculada:</b>"))
        self.le_os_vinculada = QLineEdit()
        self.le_os_vinculada.setPlaceholderText("Ej. OS-26-XXX (opcional)")
        ctrl_l.addWidget(self.le_os_vinculada, 1)
        bl.addWidget(ctrl_box)

        # SECCIÓN 1: Datos del Cliente y del Equipo
        sec1 = QGroupBox("SECCIÓN 1. Datos del Cliente y del Equipo")
        g1 = QGridLayout(sec1)
        self.le_cliente = QLineEdit()
        self.le_planta = QLineEdit()
        self.le_tag = QLineEdit()
        self.le_marca = QLineEdit()
        self.le_modelo = QLineEdit()
        self.le_serie = QLineEdit()
        self.le_capacidad = QLineEdit()
        self.le_division = QLineEdit()
        self.cmb_tipo_inst = QComboBox()
        self.cmb_tipo_inst.addItems(["Mesa", "Camionera", "Colgante", "Tolva", "Tanque", "Otro"])
        self.le_tipo_otro = QLineEdit()
        self.le_tipo_otro.setPlaceholderText("Especifique otro tipo de instrumento...")

        g1.addWidget(QLabel("Cliente / Empresa:"), 0, 0)
        g1.addWidget(self.le_cliente, 0, 1)
        g1.addWidget(QLabel("Planta / Ubicación:"), 0, 2)
        g1.addWidget(self.le_planta, 0, 3)

        g1.addWidget(QLabel("ID Interno / Tag:"), 1, 0)
        g1.addWidget(self.le_tag, 1, 1)
        g1.addWidget(QLabel("Marca:"), 1, 2)
        g1.addWidget(self.le_marca, 1, 3)

        g1.addWidget(QLabel("Modelo:"), 2, 0)
        g1.addWidget(self.le_modelo, 2, 1)
        g1.addWidget(QLabel("Número de Serie:"), 2, 2)
        g1.addWidget(self.le_serie, 2, 3)

        g1.addWidget(QLabel("Capacidad Máx. (Max):"), 3, 0)
        g1.addWidget(self.le_capacidad, 3, 1)
        g1.addWidget(QLabel("División Mínima (d / e):"), 3, 2)
        g1.addWidget(self.le_division, 3, 3)

        g1.addWidget(QLabel("Tipo de Instrumento:"), 4, 0)
        inst_hl = QHBoxLayout()
        inst_hl.addWidget(self.cmb_tipo_inst)
        inst_hl.addWidget(self.le_tipo_otro, 1)
        g1.addLayout(inst_hl, 4, 1, 1, 3)
        bl.addWidget(sec1)

        # SECCIÓN 2: Checklist de Inspección Física y Mecánica (14 ítems)
        sec2 = QGroupBox("SECCIÓN 2. Checklist de Inspección Física y Mecánica (B / R / M / N/A)")
        v2 = QVBoxLayout(sec2)
        for grp_title, items in self.CHECKLIST_GROUPS:
            lbl_g = QLabel(f"<b style='color:#C8102E;'>{grp_title}</b>")
            v2.addWidget(lbl_g)
            grid_c = QGridLayout()
            for row_idx, (num, text) in enumerate(items):
                grid_c.addWidget(QLabel(text), row_idx, 0)
                cmb = QComboBox()
                cmb.addItems(["B", "R", "M", "N/A"])
                cmb.setFixedWidth(85)
                le_obs = QLineEdit()
                le_obs.setPlaceholderText("Observaciones...")
                grid_c.addWidget(cmb, row_idx, 1)
                grid_c.addWidget(le_obs, row_idx, 2)
                self._chk_widgets[num] = (cmb, le_obs)
            v2.addLayout(grid_c)
        bl.addWidget(sec2)

        # SECCIÓN 3: Pruebas Rápidas de Funcionamiento
        sec3 = QGroupBox("SECCIÓN 3. Pruebas Rápidas de Funcionamiento")
        g3 = QGridLayout(sec3)
        for idx, (key, title, sec_lbl, is_yes_no) in enumerate(self.PRUEBAS_RAPIDAS):
            g3.addWidget(QLabel(f"<b>{title}:</b>"), idx, 0)
            cmb_res = QComboBox()
            cmb_res.addItems(["CUMPLE", "NO CUMPLE"])
            cmb_res.setFixedWidth(130)
            g3.addWidget(cmb_res, idx, 1)
            g3.addWidget(QLabel(f"{sec_lbl}:"), idx, 2)
            if is_yes_no:
                cmb_aj = QComboBox()
                cmb_aj.addItems(["NO", "SÍ"])
                g3.addWidget(cmb_aj, idx, 3)
                self._pruebas_widgets[key] = (cmb_res, cmb_aj)
            else:
                le_val = QLineEdit()
                le_val.setPlaceholderText(sec_lbl)
                g3.addWidget(le_val, idx, 3)
                self._pruebas_widgets[key] = (cmb_res, le_val)
        bl.addWidget(sec3)

        # SECCIÓN 4: Diagnóstico General, Observaciones y Refacciones
        sec4 = QGroupBox("SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones")
        v4 = QVBoxLayout(sec4)
        v4.addWidget(QLabel("<b>Observaciones técnicas y hallazgos detallados:</b>"))
        self.txt_observaciones = QTextEdit()
        self.txt_observaciones.setMinimumHeight(70)
        v4.addWidget(self.txt_observaciones)

        v4.addWidget(QLabel("<b>Acciones realizadas durante la revisión:</b>"))
        acc_grid = QGridLayout()
        for idx, (ak, albl) in enumerate(self.ACCIONES_REVISION):
            chk = QCheckBox(albl)
            acc_grid.addWidget(chk, idx // 2, idx % 2)
            self._acciones_checks[ak] = chk
        v4.addLayout(acc_grid)

        v4.addWidget(QLabel("<b>Refacciones o servicios adicionales requeridos:</b>"))
        self.txt_refacciones = QTextEdit()
        self.txt_refacciones.setMinimumHeight(55)
        v4.addWidget(self.txt_refacciones)

        v4.addWidget(QLabel("<b>Dictamen de Estado Operativo del Equipo:</b>"))
        for idx, (d_code, d_lbl) in enumerate(self.DICTAMENES):
            rb = QRadioButton(d_lbl)
            if idx == 0:
                rb.setChecked(True)
            self._dictamen_group.addButton(rb)
            self._dictamen_radios[d_code] = rb
            v4.addWidget(rb)
        bl.addWidget(sec4)

        # SECCIÓN 5: Firmas de Conformidad
        sec5 = QGroupBox("SECCIÓN 5. Firmas de Conformidad")
        h5 = QHBoxLayout(sec5)

        # Técnico
        v_tec = QVBoxLayout()
        v_tec.addWidget(QLabel("<b>Realizó Revisión (Técnico)</b>"))
        self.le_tec_nombre = QLineEdit()
        self.le_tec_nombre.setPlaceholderText("Nombre del Técnico")
        self.le_tec_puesto = QLineEdit("Técnico de Servicio")
        v_tec.addWidget(QLabel("Nombre:"))
        v_tec.addWidget(self.le_tec_nombre)
        v_tec.addWidget(QLabel("Puesto:"))
        v_tec.addWidget(self.le_tec_puesto)
        self.canvas_tec = DrawingCanvas("Firma del Técnico", self)
        v_tec.addWidget(self.canvas_tec)
        btn_clr_tec = QPushButton("Limpiar firma técnico")
        btn_clr_tec.clicked.connect(self.canvas_tec.clear)
        v_tec.addWidget(btn_clr_tec)
        h5.addLayout(v_tec, 1)

        # Cliente
        v_cli = QVBoxLayout()
        v_cli.addWidget(QLabel("<b>Recibió de Conformidad (Cliente / Usuario)</b>"))
        self.le_cli_nombre = QLineEdit()
        self.le_cli_nombre.setPlaceholderText("Nombre de quien recibe")
        self.le_cli_puesto = QLineEdit()
        self.le_cli_puesto.setPlaceholderText("Área / Puesto")
        v_cli.addWidget(QLabel("Nombre:"))
        v_cli.addWidget(self.le_cli_nombre)
        v_cli.addWidget(QLabel("Área / Puesto:"))
        v_cli.addWidget(self.le_cli_puesto)
        self.canvas_cli = DrawingCanvas("Firma de Conformidad Cliente", self)
        v_cli.addWidget(self.canvas_cli)
        btn_clr_cli = QPushButton("Limpiar firma cliente")
        btn_clr_cli.clicked.connect(self.canvas_cli.clear)
        v_cli.addWidget(btn_clr_cli)
        h5.addLayout(v_cli, 1)

        bl.addWidget(sec5)
        scroll.setWidget(body)
        root.addWidget(scroll, 1)

        # Barra inferior de botones
        ftr = QFrame()
        ftr.setStyleSheet("QFrame { background: #FFFFFF; border-top: 1px solid #D1D5DB; padding: 10px 18px; }")
        fl = QHBoxLayout(ftr)
        btn_cancel = QPushButton("Cancelar")
        btn_cancel.clicked.connect(self.reject)
        btn_save = QPushButton("Finalizar y Generar PDF Oficial (OSOB)")
        btn_save.setStyleSheet(
            "QPushButton { background: #C8102E; color: white; font-weight: 800; "
            "padding: 10px 24px; border-radius: 7px; font-size: 10.5pt; }"
            "QPushButton:hover { background: #A00D24; }"
        )
        btn_save.clicked.connect(self._on_guardar)
        fl.addStretch(1)
        fl.addWidget(btn_cancel)
        fl.addWidget(btn_save)
        root.addWidget(ftr)

    def _populate_initial_values(self) -> None:
        d = self._os_data
        dt = {}
        raw_dt = d.get("datos_tecnicos_json")
        if raw_dt:
            try:
                dt = json.loads(raw_dt) if isinstance(raw_dt, str) else dict(raw_dt)
            except Exception:
                dt = {}

        self.le_os_vinculada.setText(str(dt.get("orden_servicio_vinculada") or d.get("orden_servicio_vinculada") or ""))
        self.le_cliente.setText(str(d.get("cliente") or dt.get("cliente") or ""))
        self.le_planta.setText(str(d.get("ubicacion") or d.get("sucursal") or d.get("direccion") or dt.get("planta") or ""))
        self.le_tag.setText(str(d.get("id_equipo") or dt.get("id_equipo") or ""))
        self.le_marca.setText(str(d.get("marca") or dt.get("marca") or ""))
        self.le_modelo.setText(str(d.get("modelo") or dt.get("modelo") or ""))
        self.le_serie.setText(str(d.get("ns") or dt.get("ns") or ""))
        cap = d.get("instrumento_capacidad") or d.get("alcance_max") or dt.get("capacidad_maxima") or ""
        div = d.get("instrumento_division") or d.get("div_minima") or dt.get("division_minima") or ""
        self.le_capacidad.setText(str(cap) if cap is not None else "")
        self.le_division.setText(str(div) if div is not None else "")

        t_inst = str(d.get("tipo_instrumento") or dt.get("tipo_instrumento") or "Mesa").strip()
        idx_t = self.cmb_tipo_inst.findText(t_inst, Qt.MatchFlag.MatchFixedString)
        if idx_t >= 0:
            self.cmb_tipo_inst.setCurrentIndex(idx_t)
        elif t_inst:
            self.cmb_tipo_inst.setCurrentText("Otro")
            self.le_tipo_otro.setText(t_inst)

        self.txt_observaciones.setPlainText(str(dt.get("observaciones_tecnicas") or d.get("observaciones") or ""))
        self.txt_refacciones.setPlainText(str(dt.get("refacciones_requeridas") or ""))
        self.le_tec_nombre.setText(str(d.get("tecnico") or dt.get("tecnico_nombre") or ""))
        self.le_cli_nombre.setText(str(d.get("nombre_ing") or dt.get("nombre_ing") or ""))
        self.le_cli_puesto.setText(str(d.get("puesto_ing") or dt.get("puesto_ing") or ""))

        dict_val = str(d.get("dictamen") or dt.get("dictamen") or "OPERATIVO").strip().upper()
        if dict_val in self._dictamen_radios:
            self._dictamen_radios[dict_val].setChecked(True)

    def _on_guardar(self) -> None:
        checklist_map = {}
        checklist_list = []
        for num, (cmb, le_obs) in self._chk_widgets.items():
            item_obj = {
                "id": num,
                "estado": cmb.currentText(),
                "observaciones": le_obs.text().strip(),
            }
            checklist_map[str(num)] = item_obj
            checklist_list.append(item_obj)

        pruebas_map = {}
        for key, (cmb_res, sec_w) in self._pruebas_widgets.items():
            if isinstance(sec_w, QComboBox):
                pruebas_map[key] = {
                    "resultado": cmb_res.currentText(),
                    "requiere_ajuste": sec_w.currentText(),
                }
            else:
                pruebas_map[key] = {
                    "resultado": cmb_res.currentText(),
                    "valor": sec_w.text().strip(),
                    "comentarios": sec_w.text().strip(),
                }

        acciones_map = {ak: chk.isChecked() for ak, chk in self._acciones_checks.items()}
        dictamen_sel = "OPERATIVO"
        for code, rb in self._dictamen_radios.items():
            if rb.isChecked():
                dictamen_sel = code
                break

        firma_tec_b64 = self.canvas_tec.to_base64_png() if not self.canvas_tec.is_empty() else ""
        firma_cli_b64 = self.canvas_cli.to_base64_png() if not self.canvas_cli.is_empty() else ""

        tipo_inst_sel = self.cmb_tipo_inst.currentText()
        tipo_otro_val = self.le_tipo_otro.text().strip() if tipo_inst_sel == "Otro" else ""

        obs_txt = self.txt_observaciones.toPlainText().strip()
        ref_txt = self.txt_refacciones.toPlainText().strip()

        payload = {
            "folio_os": self._folio,
            "folio": self._folio,
            "tipo_documento": "OSOB",
            "modalidad": "DIGITAL",
            "fecha": datetime.now().strftime("%Y-%m-%d"),
            "orden_servicio_vinculada": self.le_os_vinculada.text().strip(),
            "cliente": self.le_cliente.text().strip(),
            "planta": self.le_planta.text().strip(),
            "ubicacion": self.le_planta.text().strip(),
            "id_equipo": self.le_tag.text().strip(),
            "marca": self.le_marca.text().strip(),
            "modelo": self.le_modelo.text().strip(),
            "ns": self.le_serie.text().strip(),
            "capacidad_maxima": self.le_capacidad.text().strip(),
            "division_minima": self.le_division.text().strip(),
            "tipo_instrumento": tipo_otro_val or tipo_inst_sel,
            "tipo_instrumento_otro": tipo_otro_val,
            "checklist": checklist_map,
            "checklist_inspeccion": checklist_list,
            "pruebas_rapidas": pruebas_map,
            "observaciones_tecnicas": obs_txt,
            "observaciones": obs_txt,
            "acciones_realizadas": acciones_map,
            "refacciones_requeridas": ref_txt,
            "dictamen": dictamen_sel,
            "tecnico_nombre": self.le_tec_nombre.text().strip(),
            "puesto_tecnico": self.le_tec_puesto.text().strip(),
            "nombre_ing": self.le_cli_nombre.text().strip(),
            "puesto_ing": self.le_cli_puesto.text().strip(),
            "firma_tecnico": firma_tec_b64,
            "firma_cliente": firma_cli_b64,
        }

        try:
            from services.os_pdf_generator import osob_pdf_generator
            pdf_path = osob_pdf_generator.generate(payload, force=True, digital=True)
        except Exception as exc:
            QMessageBox.critical(self, "Error PDF", f"No se pudo generar el PDF OSOB:\n{exc}")
            return

        if _db_pool:
            try:
                conn = _db_pool.get_connection()
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            UPDATE ordenes_servicio
                            SET estado = 'COMPLETADA',
                                estatus = 'CERRADO',
                                marca = %s,
                                modelo = %s,
                                ns = %s,
                                id_equipo = %s,
                                ubicacion = %s,
                                tipo_instrumento = %s,
                                observaciones = %s,
                                dictamen = %s,
                                nombre_ing = %s,
                                puesto_ing = %s,
                                datos_tecnicos_json = %s::jsonb,
                                pdf_url = %s,
                                has_pdf = TRUE,
                                updated_at = NOW()
                            WHERE folio_os = %s
                            """,
                            (
                                payload["marca"],
                                payload["modelo"],
                                payload["ns"],
                                payload["id_equipo"],
                                payload["ubicacion"],
                                payload["tipo_instrumento"],
                                obs_txt,
                                dictamen_sel,
                                payload["nombre_ing"],
                                payload["puesto_ing"],
                                json.dumps(payload, ensure_ascii=False),
                                pdf_path,
                                self._folio,
                            ),
                        )
                    conn.commit()
                finally:
                    _db_pool.release_connection(conn)
            except Exception as exc:
                logger.warning("No se pudo actualizar ordenes_servicio para %s: %s", self._folio, exc)

        self.captura_guardada.emit()
        QMessageBox.information(
            self,
            "Formato OSOB Generado",
            f"El Formato de Inspección y Revisión de Básculas ({self._folio}) se guardó correctamente.\n\nPDF: {pdf_path}",
        )
        self.accept()
