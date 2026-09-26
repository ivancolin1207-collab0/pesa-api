"""
Widget Formulario de Remisiones (RMA).
Genera folios RMA-AÑO-CONSECUTIVO y registra entregas de material.
"""
import logging
from datetime import date
from typing import Optional

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QTextEdit, QComboBox, QDateEdit, QTableWidget,
    QTableWidgetItem, QHeaderView, QScrollArea, QFrame, QDoubleSpinBox,
    QAbstractItemView, QMessageBox, QAbstractSpinBox, QTabWidget,
    QSizePolicy,
)
from PyQt6.QtCore import Qt, pyqtSignal, QDate
from PyQt6.QtGui import QFont, QColor

logger = logging.getLogger(__name__)

_MINI_BTN = """
QPushButton {
    background:#FFFFFF; color:#86868B; border:1px solid #D1D1D6;
    border-radius:4px; font-size:11px; font-weight:600; padding:3px 10px;
}
QPushButton:hover  { background:#D1D1D6; color:#1D1D1F; }
QPushButton:pressed{ background:#F2F2F7; }
"""


class RMAFormWidget(QWidget):
    """
    Formulario de Remisión de Material.
    Dos tabs: Crear Nueva RMA | Historial de RMAs
    """
    rma_saved = pyqtSignal(str)   # folio_rma

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._clientes:   list[dict] = []
        self._tecnicos:   list[dict] = []
        self._sucursales: list[dict] = []
        self._setup_ui()
        self._load_catalogos()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._load_catalogos()

    # ── UI Setup ──────────────────────────────────────────────────────────────
    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Título
        header = QWidget()
        header.setFixedHeight(54)
        header.setStyleSheet("background:#F2F2F7; border-bottom:1px solid #D1D1D6;")
        hl = QHBoxLayout(header)
        hl.setContentsMargins(24, 0, 24, 0)
        t = QLabel("📋  Remisiones de Material — RMA")
        t.setStyleSheet("font-size:18px; font-weight:800; color:#1D1D1F;")
        hl.addWidget(t)
        hl.addStretch()
        root.addWidget(header)

        # Tabs
        self._tabs = QTabWidget()
        self._tabs.addTab(self._build_form_tab(), "➕  Nueva Remisión")
        self._tabs.addTab(self._build_historial_tab(), "📄  Historial")
        root.addWidget(self._tabs)

    # ── Tab 1: Formulario ─────────────────────────────────────────────────────
    def _build_form_tab(self) -> QWidget:
        w = QWidget()
        root = QVBoxLayout(w)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)

        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(28, 20, 28, 16)
        layout.setSpacing(16)

        # ── Encabezado: Folio + Fecha + Tipo ─────────────────────────────────
        top = QHBoxLayout()
        top.setSpacing(20)

        # Folio panel
        folio_panel = QWidget()
        folio_panel.setFixedSize(200, 72)
        folio_panel.setStyleSheet(
            "background:#FFFFFF; border:2px solid #FF9F0A; border-radius:8px;"
        )
        fp = QVBoxLayout(folio_panel)
        fp.setContentsMargins(10, 6, 10, 6)
        fp.setSpacing(1)
        lbl_ft = QLabel("FOLIO / RMA")
        lbl_ft.setStyleSheet("color:#86868B; font-size:10px; font-weight:700; letter-spacing:1px;")
        lbl_ft.setAlignment(Qt.AlignmentFlag.AlignCenter)
        fp.addWidget(lbl_ft)
        self._lbl_folio = QLabel("— NUEVO —")
        self._lbl_folio.setStyleSheet("color:#FF9F0A; font-size:18px; font-weight:900; letter-spacing:2px;")
        self._lbl_folio.setAlignment(Qt.AlignmentFlag.AlignCenter)
        fp.addWidget(self._lbl_folio)
        top.addWidget(folio_panel)

        # Fecha
        fecha_col = QVBoxLayout()
        fecha_col.setSpacing(4)
        fecha_col.addWidget(QLabel("FECHA:"))
        self._date_edit = QDateEdit(QDate.currentDate())
        self._date_edit.setCalendarPopup(True)
        self._date_edit.setDisplayFormat("dd / MM / yyyy")
        self._date_edit.setFixedWidth(160)
        fecha_col.addWidget(self._date_edit)
        top.addLayout(fecha_col)
        top.addStretch()
        layout.addLayout(top)

        # ── Cliente + Técnico ─────────────────────────────────────────────────
        ct_grp = QFrame()
        ct_grp.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:8px;")
        ct_layout = QHBoxLayout(ct_grp)
        ct_layout.setContentsMargins(16, 12, 16, 12)
        ct_layout.setSpacing(24)

        # Cliente
        cli_col = QVBoxLayout()
        cli_col.setSpacing(4)
        lbl_cli = QLabel("CLIENTE")
        lbl_cli.setStyleSheet("color:#E63946; font-size:10px; font-weight:800; letter-spacing:1px;")
        cli_col.addWidget(lbl_cli)
        self._combo_cliente = QComboBox()
        self._combo_cliente.setEditable(True)
        self._combo_cliente.setMinimumWidth(280)
        cli_col.addWidget(self._combo_cliente)
        ct_layout.addLayout(cli_col)

        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.VLine)
        sep.setStyleSheet("background:#D1D1D6;")
        ct_layout.addWidget(sep)

        # Sucursal / Planta
        suc_col = QVBoxLayout()
        suc_col.setSpacing(4)
        lbl_suc = QLabel("SUCURSAL / PLANTA")
        lbl_suc.setStyleSheet("color:#E63946; font-size:10px; font-weight:800; letter-spacing:1px;")
        suc_col.addWidget(lbl_suc)
        self._combo_sucursal = QComboBox()
        self._combo_sucursal.setMinimumWidth(220)
        self._combo_sucursal.setEnabled(False)
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        suc_col.addWidget(self._combo_sucursal)
        # Dirección (solo lectura, se autocompleta)
        self._lbl_dir_sucursal = QLabel("")
        self._lbl_dir_sucursal.setStyleSheet("color:#86868B; font-size:9px; font-style:italic;")
        self._lbl_dir_sucursal.setWordWrap(True)
        suc_col.addWidget(self._lbl_dir_sucursal)
        ct_layout.addLayout(suc_col)

        sep2 = QFrame()
        sep2.setFrameShape(QFrame.Shape.VLine)
        sep2.setStyleSheet("background:#D1D1D6;")
        ct_layout.addWidget(sep2)

        # Técnico
        tec_col = QVBoxLayout()
        tec_col.setSpacing(4)
        lbl_tec = QLabel("TÉCNICO RESPONSABLE")
        lbl_tec.setStyleSheet("color:#E63946; font-size:10px; font-weight:800; letter-spacing:1px;")
        tec_col.addWidget(lbl_tec)
        self._combo_tecnico = QComboBox()
        self._combo_tecnico.setMinimumWidth(220)
        tec_col.addWidget(self._combo_tecnico)
        ct_layout.addLayout(tec_col)
        ct_layout.addStretch()
        layout.addWidget(ct_grp)

        # Señales de cascada
        self._combo_cliente.currentIndexChanged.connect(self._on_cliente_changed)
        self._combo_sucursal.currentIndexChanged.connect(self._on_sucursal_changed)

        # ── Tabla de Ítems ────────────────────────────────────────────────────
        items_header = QHBoxLayout()
        lbl_items = QLabel("ÍTEMS / MATERIALES REMISIONADOS")
        lbl_items.setStyleSheet("color:#E63946; font-size:11px; font-weight:800; letter-spacing:1px;")
        items_header.addWidget(lbl_items)
        items_header.addStretch()
        btn_add = QPushButton("+ Agregar ítem")
        btn_add.setStyleSheet(_MINI_BTN)
        btn_add.clicked.connect(self._add_item_row)
        items_header.addWidget(btn_add)
        btn_del = QPushButton("− Quitar último")
        btn_del.setStyleSheet(_MINI_BTN)
        btn_del.clicked.connect(self._remove_item_row)
        items_header.addWidget(btn_del)
        layout.addLayout(items_header)

        self._items_table = QTableWidget(0, 6)
        self._items_table.setHorizontalHeaderLabels(
            ["#", "DESCRIPCIÓN / MATERIAL", "CANTIDAD", "UNIDAD", "N/S (Opcional)", "OBSERVACIÓN"]
        )
        self._items_table.verticalHeader().setVisible(False)
        self._items_table.setAlternatingRowColors(True)
        self._items_table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        hdr = self._items_table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        hdr.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self._items_table.setColumnWidth(0, 40)
        self._items_table.setColumnWidth(2, 80)
        self._items_table.setColumnWidth(3, 70)
        self._items_table.setColumnWidth(4, 140)
        self._items_table.setMinimumHeight(180)

        # 3 ítems iniciales
        for _ in range(3):
            self._add_item_row()

        layout.addWidget(self._items_table)

        # ── Observaciones ─────────────────────────────────────────────────────
        lbl_obs = QLabel("OBSERVACIONES")
        lbl_obs.setStyleSheet("color:#E63946; font-size:11px; font-weight:800; letter-spacing:1px;")
        layout.addWidget(lbl_obs)
        self._txt_observaciones = QTextEdit()
        self._txt_observaciones.setPlaceholderText(
            "Condiciones de entrega, receptor, instrucciones especiales..."
        )
        self._txt_observaciones.setFixedHeight(80)
        layout.addWidget(self._txt_observaciones)
        layout.addStretch()

        scroll.setWidget(container)
        root.addWidget(scroll)
        root.addWidget(self._build_action_bar())
        return w

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

        self._btn_guardar = QPushButton("💾  Guardar RMA")
        self._btn_guardar.setProperty("class", "primary")
        self._btn_guardar.setFixedWidth(150)
        self._btn_guardar.clicked.connect(self._save)
        layout.addWidget(self._btn_guardar)
        return bar

    # ── Tab 2: Historial ──────────────────────────────────────────────────────
    def _build_historial_tab(self) -> QWidget:
        w = QWidget()
        layout = QVBoxLayout(w)
        layout.setContentsMargins(16, 12, 16, 12)
        layout.setSpacing(8)

        toolbar = QHBoxLayout()
        btn_refresh = QPushButton("↻  Actualizar")
        btn_refresh.setFixedWidth(120)
        btn_refresh.clicked.connect(self._load_historial)
        toolbar.addWidget(btn_refresh)
        toolbar.addStretch()
        layout.addLayout(toolbar)

        self._hist_table = QTableWidget(0, 6)
        self._hist_table.setHorizontalHeaderLabels(
            ["Folio RMA", "Fecha", "Cliente", "Ítems", "Técnico", "Estado"]
        )
        self._hist_table.verticalHeader().setVisible(False)
        self._hist_table.setAlternatingRowColors(True)
        self._hist_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        hdr = self._hist_table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        layout.addWidget(self._hist_table)
        return w

    # ── Tabla de ítems: helpers ───────────────────────────────────────────────
    def _add_item_row(self) -> None:
        row = self._items_table.rowCount()
        self._items_table.insertRow(row)
        self._items_table.setRowHeight(row, 32)

        num_item = QTableWidgetItem(str(row + 1))
        num_item.setFlags(Qt.ItemFlag.ItemIsEnabled)
        num_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
        num_item.setForeground(QColor("#E5E5EA"))
        self._items_table.setItem(row, 0, num_item)

        for col in range(1, 6):
            item = QTableWidgetItem("")
            self._items_table.setItem(row, col, item)

        # Cantidad (col 2) → spinbox
        sb = QDoubleSpinBox()
        sb.setRange(0.001, 99999)
        sb.setValue(1)
        sb.setDecimals(2)
        sb.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
        sb.setFrame(False)
        sb.setAlignment(Qt.AlignmentFlag.AlignCenter)
        sb.setStyleSheet(
            "QDoubleSpinBox { background:transparent; border:none; color:#1D1D1F; }"
            "QDoubleSpinBox:focus { background:#FAFAFC; border-bottom:1px solid #E63946; }"
        )
        self._items_table.setCellWidget(row, 2, sb)

    def _remove_item_row(self) -> None:
        if self._items_table.rowCount() > 1:
            self._items_table.removeRow(self._items_table.rowCount() - 1)

    def _get_items_data(self) -> list[dict]:
        items = []
        for row in range(self._items_table.rowCount()):
            desc = self._items_table.item(row, 1)
            if desc and desc.text().strip():
                sb = self._items_table.cellWidget(row, 2)
                items.append({
                    "descripcion": desc.text().strip(),
                    "cantidad":    sb.value() if sb else 1,
                    "unidad":      (self._items_table.item(row, 3) or QTableWidgetItem("PZA")).text().strip() or "PZA",
                    "num_serie":   (self._items_table.item(row, 4) or QTableWidgetItem("")).text().strip() or None,
                    "observacion": (self._items_table.item(row, 5) or QTableWidgetItem("")).text().strip() or None,
                })
        return items

    # ── Carga de catálogos ────────────────────────────────────────────────────────────
    def _load_catalogos(self) -> None:
        try:
            from models.catalogo import cliente_repo, tecnico_repo
            self._clientes = cliente_repo.get_all()
            self._tecnicos = tecnico_repo.get_all()
        except Exception as exc:
            logger.error(f"Error al cargar catálogos: {exc}")
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
        c_id = self._combo_cliente.currentData()
        self._combo_sucursal.blockSignals(True)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        self._lbl_dir_sucursal.clear()
        self._sucursales = []
        self._combo_sucursal.setEnabled(False)

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
                logger.error("Error sucursales RMA: %s", exc)

        self._combo_sucursal.blockSignals(False)

    def _on_sucursal_changed(self, index: int) -> None:
        s_id = self._combo_sucursal.currentData()
        self._lbl_dir_sucursal.clear()
        if s_id:
            suc = next((s for s in self._sucursales if s["id"] == s_id), None)
            if suc:
                self._lbl_dir_sucursal.setText(suc.get("direccion") or "")

    def _load_historial(self) -> None:
        try:
            from models.remision import remision_repo
            rows = remision_repo.get_all()
        except Exception as exc:
            logger.error(f"Error al cargar historial RMA: {exc}")
            rows = []

        _ESTADO_COLOR = {"ACTIVA": "#FF9F0A", "CANCELADA": "#FF3B30", "ENTREGADA": "#34C759"}
        self._hist_table.setRowCount(0)
        for r in rows:
            i = self._hist_table.rowCount()
            self._hist_table.insertRow(i)
            self._hist_table.setRowHeight(i, 34)
            vals = [
                r.get("folio_rma", ""),
                str(r.get("fecha", ""))[:10],
                r.get("cliente", ""),
                str(r.get("num_items", 0)),
                r.get("tecnico", ""),
                r.get("estado", ""),
            ]
            for col, v in enumerate(vals):
                item = QTableWidgetItem(v)
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col == 0:
                    item.setData(Qt.ItemDataRole.UserRole, r.get("id"))
                if col == 5:
                    color = _ESTADO_COLOR.get(v, "#86868B")
                    item.setForeground(QColor(color))
                    item.setFont(QFont("Segoe UI", 10, QFont.Weight.Bold))
                self._hist_table.setItem(i, col, item)

    # ── Guardar ───────────────────────────────────────────────────────────────
    def _save(self) -> None:
        if not self._combo_cliente.currentData():
            QMessageBox.warning(self, "Validación", "Debe seleccionar un cliente.")
            return

        items = self._get_items_data()
        if not items:
            QMessageBox.warning(self, "Validación", "Agregue al menos un ítem con descripción.")
            return

        fecha_q = self._date_edit.date()
        sucursal_id = self._combo_sucursal.currentData()
        direccion   = self._lbl_dir_sucursal.text().strip()

        data = {
            "fecha":             date(fecha_q.year(), fecha_q.month(), fecha_q.day()),
            "id_cliente":        self._combo_cliente.currentData(),
            "id_tecnico":        self._combo_tecnico.currentData(),
            "sucursal_id":       sucursal_id,
            "direccion":         direccion,
            "sucursal_direccion":direccion,
            "observaciones":     self._txt_observaciones.toPlainText().strip() or None,
            "items":             items,
        }

        try:
            self._btn_guardar.setEnabled(False)
            self._btn_guardar.setText("Guardando...")
            from models.remision import remision_repo
            result = remision_repo.create(data)
            folio = result.get("folio_rma", "")
            self._lbl_folio.setText(folio)
            QMessageBox.information(self, "Éxito", f"Remisión guardada: {folio}")
            self.rma_saved.emit(folio)
            self._load_historial()
        except Exception as exc:
            logger.error(f"Error al guardar RMA: {exc}")
            QMessageBox.critical(self, "Error", f"No se pudo guardar la remisión:\n{exc}")
        finally:
            self._btn_guardar.setEnabled(True)
            self._btn_guardar.setText("💾  Guardar RMA")

    def _clear_form(self) -> None:
        self._lbl_folio.setText("— NUEVO —")
        self._date_edit.setDate(QDate.currentDate())
        self._combo_cliente.setCurrentIndex(0)
        self._combo_sucursal.clear()
        self._combo_sucursal.addItem("— Seleccionar sucursal —", None)
        self._combo_sucursal.setEnabled(False)
        self._lbl_dir_sucursal.clear()
        self._combo_tecnico.setCurrentIndex(0)
        self._txt_observaciones.clear()
        self._items_table.setRowCount(0)
        for _ in range(3):
            self._add_item_row()
