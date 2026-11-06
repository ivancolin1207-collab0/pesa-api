"""
osocc_digital_dialog.py — Ventana de Captura Digital para Folios OSOCC-
(FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA)
Servicios PESA
"""
from __future__ import annotations
import base64
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QScrollArea, QWidget, QFrame,
    QGroupBox, QRadioButton, QButtonGroup, QMessageBox,
)
from PyQt6.QtCore import Qt, pyqtSignal

from ui.dialogs.digital_service_dialog import DrawingCanvas

logger = logging.getLogger(__name__)

try:
    from database.connection import db_pool as _db_pool
except ImportError:
    _db_pool = None


class OsoccDigitalDialog(QDialog):
    """Formulario digital exclusivo para folios OSOCC- (Diagnóstico y Revisión de Celda de Carga)."""

    captura_guardada = pyqtSignal()
    servicio_completado = pyqtSignal(str)

    SECCION_2_ITEMS = [
        ("cuerpo_metalico", "1. Cuerpo metálico / Deformación"),
        ("roscas_barrenos", "2. Roscas, barrenos y apoyos mecánicos"),
        ("sellos_galgas", "3. Sellos herméticos y encapsulado de galgas"),
        ("integridad_cable", "4. Integridad del cable (sin cortes, aplastamientos ni empalmes)"),
        ("prensaestopas", "5. Prensaestopas / Salida de cable"),
        ("corrosion_humedad", "6. Evidencia de corrosión, humedad o sobrecarga térmica"),
    ]

    SECCION_3_PARAMS = [
        ("exc_pos_exc_neg", "1. Excitación Exc+ / Exc-", "Ohms", ["OK", "Falla"]),
        ("sig_pos_sig_neg", "2. Resistencia Sig+ / Sig-", "Ohms", ["OK", "Falla"]),
        ("exc_pos_sig_pos", "3. Resistencia Exc+ / Sig+", "Ohms", ["OK", "Falla"]),
        ("exc_pos_sig_neg", "4. Resistencia Exc+ / Sig-", "Ohms", ["OK", "Falla"]),
        ("exc_neg_sig_pos", "5. Resistencia Exc- / Sig+", "Ohms", ["OK", "Falla"]),
        ("exc_neg_sig_neg", "6. Resistencia Exc- / Sig-", "Ohms", ["OK", "Falla"]),
        ("sig_neg_exc_pos", "7. Resistencia Sig- + Exc+", "Ohms", ["OK", "Falla"]),
        ("sig_neg_exc_neg", "8. Resistencia Sig- + Exc-", "Ohms", ["OK", "Falla"]),
        ("exc_ambos_sig_pos", "9. Resistencia Exc-+ / Sig+", "Ohms", ["OK", "Falla"]),
        ("exc_ambos_sig_neg", "10. Resistencia Exc-+ / Sig-", "Ohms", ["OK", "Falla"]),
        ("senal_salida_mv", "11. Señal de Salida (Milivoltaje)", "mV", ["OK", "Falla"]),
        ("aislamiento_mohm", "12. Resistencia de Aislamiento", "MΩ", ["> 5000 MΩ (OK)", "Fuga"]),
    ]

    DICTAMENES = [
        ("OPERATIVA", "OPERATIVA / EN TOLERANCIA (Apta para instalación o calibración)"),
        ("REPARABLE", "REPARABLE (Requiere reemplazo de cable, conector o reapriete)"),
        ("DANADA", "DAÑADA / DESCALIBRADA (Sobrecarga, galgas abiertas o fuga - FUERA DE SERVICIO)"),
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
        self._folio = str(
            folio
            or (orden_data or {}).get("folio_os")
            or (orden_data or {}).get("folio")
            or "OSOCC-26-001"
        ).strip()
        self._os_data = dict(orden_data or {})
        self._sec2_widgets: dict[str, tuple[QComboBox, QLineEdit]] = {}
        self._sec3_widgets: dict[str, tuple[QLineEdit, QComboBox]] = {}
        self._dictamen_group = QButtonGroup(self)
        self._dictamen_radios: dict[str, QRadioButton] = {}

        self.setWindowTitle(f"Diagnóstico y Revisión de Celda de Carga ({self._folio}) — OSOCC DIGITAL")
        self.setMinimumSize(1020, 780)
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
                               COALESCE(c.razon_social, '') AS cliente,
                               COALESCE(s.nombre_sucursal, '') AS sucursal,
                               COALESCE(s.direccion, c.direccion, '') AS direccion,
                               COALESCE(t.nombre_completo, '') AS tecnico,
                               COALESCE(os.marca, '') AS marca,
                               COALESCE(os.modelo, '') AS modelo,
                               COALESCE(os.ns, '') AS ns,
                               COALESCE(os.id_equipo, '') AS id_equipo,
                               COALESCE(os.ubicacion, '') AS ubicacion,
                               os.alcance_max, os.div_minima,
                               COALESCE(os.observaciones, '') AS observaciones,
                               COALESCE(os.firma_cliente_nombre, '') AS firma_cliente_nombre,
                               os.datos_tecnicos_json
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes c ON os.id_cliente = c.id
                        LEFT JOIN cliente_sucursales s ON os.sucursal_id = s.id
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
            logger.warning("OsoccDigitalDialog._load_db_data error: %s", exc)

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
            f"FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA</span><br>"
            f"<span style='color:#38BDF8; font-size:10pt; font-weight:700;'>"
            f"Folio: {self._folio}</span>"
            f"<span style='color:#D1D5DB; font-size:9.5pt;'>  |  Fecha: {datetime.now().strftime('%d / %m / %Y')}</span>"
        )
        hl.addWidget(lbl_title, 1)

        badge = QLabel("OSOCC DIGITAL")
        badge.setStyleSheet(
            "background: #0284C7; color: white; font-weight: 800; font-size: 9pt; "
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

        # Cabecera de control
        ctrl_box = QGroupBox("Cabecera de Control")
        ctrl_l = QHBoxLayout(ctrl_box)
        ctrl_l.addWidget(QLabel(f"<b>Folio:</b> {self._folio}"))
        ctrl_l.addSpacing(12)
        ctrl_l.addWidget(QLabel(f"<b>Fecha:</b> {datetime.now().strftime('%d / %m / %Y')}"))
        ctrl_l.addSpacing(12)
        ctrl_l.addWidget(QLabel("<b>Ref. / Orden:</b>"))
        self.le_ref_orden = QLineEdit()
        self.le_ref_orden.setPlaceholderText("Ej. OS-26-XXX o lote interno (opcional)")
        ctrl_l.addWidget(self.le_ref_orden, 1)
        ctrl_l.addSpacing(12)
        ctrl_l.addWidget(QLabel("<b>Destino:</b>"))
        self.cmb_destino = QComboBox()
        self.cmb_destino.addItems(["Stock / Laboratorio Interno", "Cliente"])
        self.cmb_destino.currentTextChanged.connect(self._on_destino_changed)
        ctrl_l.addWidget(self.cmb_destino)
        bl.addWidget(ctrl_box)

        # SECCIÓN 1. DATOS DE IDENTIFICACIÓN DE LA CELDA
        sec1 = QGroupBox("SECCIÓN 1. DATOS DE IDENTIFICACIÓN DE LA CELDA")
        g1 = QGridLayout(sec1)
        self.le_cliente = QLineEdit("Stock / Taller Básculas PESA")
        self.le_marca = QLineEdit()
        self.le_modelo = QLineEdit()
        self.le_serie = QLineEdit()
        self.le_capacidad = QLineEdit()
        self.le_capacidad.setPlaceholderText("Ej. 1000, 25000")
        self.cmb_unidad_cap = QComboBox()
        self.cmb_unidad_cap.addItems(["kg", "lb", "t"])
        self.le_sensibilidad = QLineEdit()
        self.le_sensibilidad.setPlaceholderText("Ej. 2.0, 3.0")
        self.le_resistencia_nom = QLineEdit()
        self.le_resistencia_nom.setPlaceholderText("Ej. 350 Ω / 700 Ω / 1000 Ω")

        g1.addWidget(QLabel("Cliente / Destino:"), 0, 0)
        g1.addWidget(self.le_cliente, 0, 1, 1, 3)

        g1.addWidget(QLabel("Marca:"), 1, 0)
        g1.addWidget(self.le_marca, 1, 1)
        g1.addWidget(QLabel("Modelo:"), 1, 2)
        g1.addWidget(self.le_modelo, 1, 3)

        g1.addWidget(QLabel("Número de Serie:"), 2, 0)
        g1.addWidget(self.le_serie, 2, 1)
        g1.addWidget(QLabel("Capacidad Nominal (Max):"), 2, 2)
        cap_hl = QHBoxLayout()
        cap_hl.addWidget(self.le_capacidad, 1)
        cap_hl.addWidget(self.cmb_unidad_cap)
        g1.addLayout(cap_hl, 2, 3)

        g1.addWidget(QLabel("Sensibilidad Nominal (mV/V):"), 3, 0)
        g1.addWidget(self.le_sensibilidad, 3, 1)
        g1.addWidget(QLabel("Resistencia Nominal Ent./Sal. (Ohms):"), 3, 2)
        g1.addWidget(self.le_resistencia_nom, 3, 3)

        # Configuración de cables / colores
        g1.addWidget(QLabel("<b>Configuración de Cables / Colores:</b>"), 4, 0)
        cables_hl = QHBoxLayout()
        self.le_cable_exc_pos = QLineEdit("Rojo")
        self.le_cable_exc_neg = QLineEdit("Negro")
        self.le_cable_sig_pos = QLineEdit("Verde")
        self.le_cable_sig_neg = QLineEdit("Blanco")
        self.le_cable_blindaje = QLineEdit("Malla")
        self.cmb_cable_sense = QComboBox()
        self.cmb_cable_sense.addItems(["No", "Si"])
        for lbl_c, w_c in [
            ("Exc+:", self.le_cable_exc_pos),
            ("Exc-:", self.le_cable_exc_neg),
            ("Sig+:", self.le_cable_sig_pos),
            ("Sig-:", self.le_cable_sig_neg),
            ("Blindaje:", self.le_cable_blindaje),
            ("Sense:", self.cmb_cable_sense),
        ]:
            cables_hl.addWidget(QLabel(lbl_c))
            cables_hl.addWidget(w_c)
        g1.addLayout(cables_hl, 4, 1, 1, 3)
        bl.addWidget(sec1)

        # SECCIÓN 2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA
        sec2 = QGroupBox("SECCIÓN 2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA (Criterio: B / R / M / N/A)")
        g2 = QGridLayout(sec2)
        for row_idx, (key, label) in enumerate(self.SECCION_2_ITEMS):
            g2.addWidget(QLabel(label), row_idx, 0)
            cmb = QComboBox()
            cmb.addItems(["B", "R", "M", "N/A"])
            cmb.setFixedWidth(90)
            le_obs = QLineEdit()
            le_obs.setPlaceholderText("Obs: _________________")
            g2.addWidget(cmb, row_idx, 1)
            g2.addWidget(le_obs, row_idx, 2)
            self._sec2_widgets[key] = (cmb, le_obs)
        bl.addWidget(sec2)

        # SECCIÓN 3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA)
        sec3 = QGroupBox("SECCIÓN 3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA)")
        g3 = QGridLayout(sec3)
        g3.addWidget(QLabel("<b>PARÁMETRO ELÉCTRICO</b>"), 0, 0)
        g3.addWidget(QLabel("<b>UND</b>"), 0, 1)
        g3.addWidget(QLabel("<b>VALOR MEDIDO</b>"), 0, 2)
        g3.addWidget(QLabel("<b>ESTADO (OK / FALLA)</b>"), 0, 3)

        for idx, (key, label, und, opts) in enumerate(self.SECCION_3_PARAMS, start=1):
            g3.addWidget(QLabel(label), idx, 0)
            lbl_u = QLabel(f"<b>{und}</b>")
            g3.addWidget(lbl_u, idx, 1)
            le_val = QLineEdit()
            le_val.setPlaceholderText(f"Valor en {und}")
            g3.addWidget(le_val, idx, 2)
            cmb_est = QComboBox()
            cmb_est.addItems(opts)
            cmb_est.setFixedWidth(155)
            g3.addWidget(cmb_est, idx, 3)
            self._sec3_widgets[key] = (le_val, cmb_est)
        bl.addWidget(sec3)

        # SECCIÓN 4. DICTAMEN TÉCNICO Y OBSERVACIONES
        sec4 = QGroupBox("SECCIÓN 4. DICTAMEN TÉCNICO Y OBSERVACIONES")
        v4 = QVBoxLayout(sec4)
        v4.addWidget(QLabel("<b>Observaciones Técnicas y Diagnóstico:</b>"))
        self.txt_observaciones = QTextEdit()
        self.txt_observaciones.setMinimumHeight(80)
        self.txt_observaciones.setPlaceholderText(
            "Anote el diagnóstico detallado de resistencia, balance de cero, aislamiento y estado del cable..."
        )
        v4.addWidget(self.txt_observaciones)

        v4.addWidget(QLabel("<b>Dictamen Final de la Celda:</b>"))
        for idx, (d_code, d_lbl) in enumerate(self.DICTAMENES):
            rb = QRadioButton(d_lbl)
            if idx == 0:
                rb.setChecked(True)
            self._dictamen_group.addButton(rb)
            self._dictamen_radios[d_code] = rb
            v4.addWidget(rb)
        bl.addWidget(sec4)

        # SECCIÓN 5. FIRMAS DE RESPONSABILIDAD
        sec5 = QGroupBox("SECCIÓN 5. FIRMAS DE RESPONSABILIDAD")
        h5 = QHBoxLayout(sec5)

        # Evaluó / Técnico Responsable
        v_tec = QVBoxLayout()
        v_tec.addWidget(QLabel("<b>Evaluó / Técnico Responsable</b>"))
        self.le_tec_nombre = QLineEdit()
        self.le_tec_nombre.setPlaceholderText("Nombre del Técnico")
        self.le_tec_puesto = QLineEdit("Técnico de Servicio / Laboratorio")
        v_tec.addWidget(QLabel("Nombre:"))
        v_tec.addWidget(self.le_tec_nombre)
        v_tec.addWidget(QLabel("Puesto:"))
        v_tec.addWidget(self.le_tec_puesto)
        self.canvas_tec = DrawingCanvas("Firma del Técnico Responsable", self)
        v_tec.addWidget(self.canvas_tec)
        btn_clr_tec = QPushButton("Limpiar firma técnico")
        btn_clr_tec.clicked.connect(self.canvas_tec.clear)
        v_tec.addWidget(btn_clr_tec)
        h5.addLayout(v_tec, 1)

        # Recibió / Almacén o Cliente
        v_cli = QVBoxLayout()
        v_cli.addWidget(QLabel("<b>Recibió / Almacén o Cliente (Opcional en Stock)</b>"))
        self.le_cli_nombre = QLineEdit()
        self.le_cli_nombre.setPlaceholderText("Nombre de quien recibe (opcional)")
        self.le_cli_puesto = QLineEdit()
        self.le_cli_puesto.setPlaceholderText("Puesto / Almacén o Cliente")
        v_cli.addWidget(QLabel("Nombre:"))
        v_cli.addWidget(self.le_cli_nombre)
        v_cli.addWidget(QLabel("Puesto:"))
        v_cli.addWidget(self.le_cli_puesto)
        self.canvas_cli = DrawingCanvas("Firma Recibió / Almacén o Cliente", self)
        v_cli.addWidget(self.canvas_cli)
        btn_clr_cli = QPushButton("Limpiar firma recibido")
        btn_clr_cli.clicked.connect(self.canvas_cli.clear)
        v_cli.addWidget(btn_clr_cli)
        h5.addLayout(v_cli, 1)

        bl.addWidget(sec5)
        scroll.setWidget(body)
        root.addWidget(scroll, 1)

        # Barra inferior
        ftr = QFrame()
        ftr.setStyleSheet("QFrame { background: #FFFFFF; border-top: 1px solid #D1D5DB; padding: 10px 18px; }")
        fl = QHBoxLayout(ftr)
        btn_cancel = QPushButton("Cancelar")
        btn_cancel.clicked.connect(self.reject)
        btn_save = QPushButton("Finalizar y Generar PDF Oficial (OSOCC)")
        btn_save.setStyleSheet(
            "QPushButton { background: #0284C7; color: white; font-weight: 800; "
            "padding: 10px 24px; border-radius: 7px; font-size: 10.5pt; }"
            "QPushButton:hover { background: #0369A1; }"
        )
        btn_save.clicked.connect(self._on_guardar)
        fl.addStretch(1)
        fl.addWidget(btn_cancel)
        fl.addWidget(btn_save)
        root.addWidget(ftr)

    def _on_destino_changed(self, text: str) -> None:
        if "Stock" in text:
            cur = self.le_cliente.text().strip()
            if not cur:
                self.le_cliente.setText("Stock / Taller Básculas PESA")

    def _populate_initial_values(self) -> None:
        d = self._os_data
        dt = {}
        raw_dt = d.get("datos_tecnicos_json")
        if raw_dt:
            try:
                dt = json.loads(raw_dt) if isinstance(raw_dt, str) else dict(raw_dt)
            except Exception:
                dt = {}

        self.le_ref_orden.setText(str(dt.get("orden_referencia") or d.get("orden_referencia") or ""))
        cli = str(d.get("cliente") or dt.get("cliente") or d.get("ubicacion") or "").strip()
        if not cli or cli.lower() in ("none", "null", "--"):
            cli = "Stock / Taller Básculas PESA"
        self.le_cliente.setText(cli)

        destino_str = str(dt.get("destino_celda") or d.get("destino_celda") or "").strip().upper()
        if "CLI" in destino_str or (cli and "stock" not in cli.lower() and "taller" not in cli.lower() and "laboratorio" not in cli.lower() and "básculas pesa" not in cli.lower() and "basculas pesa" not in cli.lower()):
            self.cmb_destino.setCurrentText("Cliente")
        else:
            self.cmb_destino.setCurrentText("Stock / Laboratorio Interno")

        self.le_marca.setText(str(d.get("marca") or dt.get("marca") or ""))
        self.le_modelo.setText(str(d.get("modelo") or dt.get("modelo") or ""))
        self.le_serie.setText(str(d.get("ns") or dt.get("ns") or ""))
        cap = d.get("alcance_max") or dt.get("capacidad_maxima") or dt.get("alcance_max") or ""
        self.le_capacidad.setText(str(cap) if cap is not None else "")
        und = str(dt.get("unidad_capacidad") or "kg").strip()
        idx_u = self.cmb_unidad_cap.findText(und, Qt.MatchFlag.MatchFixedString)
        if idx_u >= 0:
            self.cmb_unidad_cap.setCurrentIndex(idx_u)

        self.le_sensibilidad.setText(str(dt.get("sensibilidad_nominal") or d.get("sensibilidad_nominal") or ""))
        self.le_resistencia_nom.setText(str(dt.get("resistencia_nominal") or d.get("resistencia_nominal") or ""))

        cables = dt.get("configuracion_cables")
        if isinstance(cables, dict):
            self.le_cable_exc_pos.setText(str(cables.get("exc_pos") or "Rojo"))
            self.le_cable_exc_neg.setText(str(cables.get("exc_neg") or "Negro"))
            self.le_cable_sig_pos.setText(str(cables.get("sig_pos") or "Verde"))
            self.le_cable_sig_neg.setText(str(cables.get("sig_neg") or "Blanco"))
            self.le_cable_blindaje.setText(str(cables.get("blindaje") or "Malla"))
            sense_v = str(cables.get("sense") or "No")
            idx_s = self.cmb_cable_sense.findText(sense_v, Qt.MatchFlag.MatchFixedString)
            if idx_s >= 0:
                self.cmb_cable_sense.setCurrentIndex(idx_s)

        insp = dt.get("inspeccion_fisica_celda")
        if isinstance(insp, dict):
            for k, (cmb, le_o) in self._sec2_widgets.items():
                iv = insp.get(k)
                if isinstance(iv, dict):
                    est = str(iv.get("estado") or "B")
                    i_e = cmb.findText(est, Qt.MatchFlag.MatchFixedString)
                    if i_e >= 0:
                        cmb.setCurrentIndex(i_e)
                    le_o.setText(str(iv.get("obs") or ""))

        meds = dt.get("mediciones_electricas_celda")
        if isinstance(meds, dict):
            for k, (le_v, cmb_e) in self._sec3_widgets.items():
                mv = meds.get(k)
                if isinstance(mv, dict):
                    le_v.setText(str(mv.get("valor") or ""))
                    est = str(mv.get("estado") or "")
                    i_e = cmb_e.findText(est, Qt.MatchFlag.MatchFixedString)
                    if i_e >= 0:
                        cmb_e.setCurrentIndex(i_e)

        self.txt_observaciones.setPlainText(
            str(dt.get("observaciones_diagnostico") or d.get("observaciones") or "")
        )
        self.le_tec_nombre.setText(str(d.get("tecnico") or dt.get("tecnico_nombre") or ""))
        self.le_cli_nombre.setText(str(d.get("firma_cliente_nombre") or dt.get("nombre_ing") or ""))
        self.le_cli_puesto.setText(str(dt.get("puesto_ing") or ""))

        dict_val = str(dt.get("dictamen_celda") or dt.get("dictamen") or "OPERATIVA").strip().upper()
        if dict_val in self._dictamen_radios:
            self._dictamen_radios[dict_val].setChecked(True)

    def _on_guardar(self) -> None:
        insp_map = {}
        for key, (cmb, le_obs) in self._sec2_widgets.items():
            insp_map[key] = {
                "estado": cmb.currentText(),
                "obs": le_obs.text().strip(),
            }

        meds_map = {}
        for key, (le_val, cmb_est) in self._sec3_widgets.items():
            meds_map[key] = {
                "valor": le_val.text().strip(),
                "estado": cmb_est.currentText(),
            }

        dictamen_sel = "OPERATIVA"
        for code, rb in self._dictamen_radios.items():
            if rb.isChecked():
                dictamen_sel = code
                break

        firma_tec_b64 = self.canvas_tec.to_base64_png() if not self.canvas_tec.is_empty() else ""
        firma_cli_b64 = self.canvas_cli.to_base64_png() if not self.canvas_cli.is_empty() else ""

        obs_txt = self.txt_observaciones.toPlainText().strip()
        destino_val = "CLIENTE" if self.cmb_destino.currentText() == "Cliente" else "STOCK"
        cliente_txt = self.le_cliente.text().strip() or "Stock / Taller Básculas PESA"

        payload = {
            "folio_os": self._folio,
            "folio": self._folio,
            "tipo_documento": "OSOCC",
            "tipo_servicio": "Observaciones Celda",
            "osocc_digital": True,
            "modalidad": "DIGITAL",
            "estado": "COMPLETADA",
            "fecha": datetime.now().strftime("%Y-%m-%d"),
            "orden_referencia": self.le_ref_orden.text().strip(),
            "destino_celda": destino_val,
            "cliente": cliente_txt,
            "ubicacion": cliente_txt,
            "marca": self.le_marca.text().strip(),
            "modelo": self.le_modelo.text().strip(),
            "ns": self.le_serie.text().strip(),
            "alcance_max": self.le_capacidad.text().strip(),
            "capacidad_maxima": self.le_capacidad.text().strip(),
            "unidad_capacidad": self.cmb_unidad_cap.currentText(),
            "sensibilidad_nominal": self.le_sensibilidad.text().strip(),
            "resistencia_nominal": self.le_resistencia_nom.text().strip(),
            "configuracion_cables": {
                "exc_pos": self.le_cable_exc_pos.text().strip() or "Rojo",
                "exc_neg": self.le_cable_exc_neg.text().strip() or "Negro",
                "sig_pos": self.le_cable_sig_pos.text().strip() or "Verde",
                "sig_neg": self.le_cable_sig_neg.text().strip() or "Blanco",
                "blindaje": self.le_cable_blindaje.text().strip() or "Malla",
                "sense": self.cmb_cable_sense.currentText(),
            },
            "inspeccion_fisica_celda": insp_map,
            "mediciones_electricas_celda": meds_map,
            "observaciones_diagnostico": obs_txt,
            "observaciones": obs_txt,
            "dictamen_celda": dictamen_sel,
            "dictamen": dictamen_sel,
            "tecnico_nombre": self.le_tec_nombre.text().strip(),
            "puesto_tecnico": self.le_tec_puesto.text().strip(),
            "nombre_ing": self.le_cli_nombre.text().strip(),
            "firma_cliente_nombre": self.le_cli_nombre.text().strip(),
            "puesto_ing": self.le_cli_puesto.text().strip(),
            "firma_tecnico": firma_tec_b64,
            "firma_cliente": firma_cli_b64,
        }

        try:
            from services.os_pdf_generator import osocc_pdf_generator
            pdf_path = osocc_pdf_generator.generate(payload, force=True, calca=False)
        except Exception as exc:
            QMessageBox.critical(self, "Error PDF", f"No se pudo generar el PDF OSOCC:\n{exc}")
            return

        pdf_b64 = ""
        try:
            if pdf_path and Path(pdf_path).exists():
                pdf_b64 = base64.b64encode(Path(pdf_path).read_bytes()).decode("ascii")
        except Exception:
            pass

        if _db_pool:
            try:
                conn = _db_pool.get_connection()
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            UPDATE ordenes_servicio
                            SET estado = 'COMPLETADA',
                                tipo_documento = 'OSOCC',
                                tipo_servicio = 'Observaciones Celda',
                                marca = %s,
                                modelo = %s,
                                ns = %s,
                                ubicacion = %s,
                                observaciones = %s,
                                firma_cliente_nombre = %s,
                                datos_tecnicos_json = %s,
                                pdf_path = %s,
                                pdf_b64 = COALESCE(NULLIF(%s, ''), pdf_b64),
                                pdf_generado = TRUE,
                                updated_at = NOW()
                            WHERE folio_os = %s
                            """,
                            (
                                payload["marca"],
                                payload["modelo"],
                                payload["ns"],
                                payload["ubicacion"],
                                obs_txt,
                                payload["nombre_ing"],
                                json.dumps(payload, ensure_ascii=False),
                                pdf_path,
                                pdf_b64,
                                self._folio,
                            ),
                        )
                    conn.commit()
                finally:
                    _db_pool.release_connection(conn)
            except Exception as exc:
                logger.warning("No se pudo actualizar ordenes_servicio para %s: %s", self._folio, exc)

        self.captura_guardada.emit()
        self.servicio_completado.emit(self._folio)
        QMessageBox.information(
            self,
            "Formato OSOCC Generado",
            f"El Formato de Diagnóstico y Revisión de Celda de Carga ({self._folio}) se guardó correctamente.\n\nPDF: {pdf_path}",
        )
        self.accept()
