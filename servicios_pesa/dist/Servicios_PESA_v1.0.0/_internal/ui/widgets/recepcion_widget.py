"""
recepcion_widget.py — Módulo de Recepción / Entrega Semanal de OS.
Servicios PESA v2.1

Replica el flujo de control del Excel "GESTIÓN DE ÓRDENES DE SERVICIO
DIGITALIZADAS" con tabla agrupada por fecha y dos partes:
  - PARTE 1: Asignación Inicial (Empresa, Servicio, Folios, Responsable)
  - PARTE 2: Cierre / Recepción (Factura, Certs, Confirmación, Escaneo, Conteos)

REGLA ESTRICTA: Una OS no puede marcarse COMPLETADA sin confirmar la
                entrega del documento impreso firmado.
"""
from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Optional

from PyQt6.QtCore import Qt, QTimer, pyqtSignal, QDate
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QFrame, QScrollArea, QSizePolicy, QComboBox, QDateEdit,
    QTableWidget, QTableWidgetItem, QHeaderView, QAbstractItemView,
    QDialog, QLineEdit, QTextEdit, QCheckBox, QMessageBox,
    QFormLayout, QSpinBox, QGroupBox, QApplication,
)

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales ─────────────────────────────────────────────────
try:
    from models.recepcion_repo import recepcion_repo
    _HAS_REPO = True
except ImportError:
    _HAS_REPO = False
    recepcion_repo = None  # type: ignore

try:
    from auth.session_context import session as _session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    _session = None

# ─── Paleta de colores ───────────────────────────────────────────────────────
_BG        = "#F5F5F7"
_WHITE     = "#FFFFFF"
_DARK      = "#1D1D1F"
_GRAY      = "#86868B"
_RED       = "#E63946"
_GREEN     = "#34C759"
_AMBER     = "#FF9F0A"
_BLUE      = "#007AFF"
_BLUE_DARK = "#0A2342"
_LIGHT_RED = "#FEE2E2"
_LIGHT_GRN = "#DCFCE7"
_LIGHT_AMB = "#FEF9C3"

# ─── Colores de estado de celdas ─────────────────────────────────────────────
_CELL_OK_BG   = "#DCFCE7"
_CELL_OK_FG   = "#166534"
_CELL_ERR_BG  = "#FEE2E2"
_CELL_ERR_FG  = "#991B1B"
_CELL_NA_BG   = "#F3F4F6"
_CELL_NA_FG   = "#6B7280"
_CELL_PEND_BG = "#FEF9C3"
_CELL_PEND_FG = "#92400E"

# ─── Cabecera de columnas ─────────────────────────────────────────────────────
_COL_HEADERS = [
    # PARTE 1
    "Empresa / Cliente",
    "Tipo de Servicio",
    "Cant.\nOS",
    "Folios Asignados",
    "Responsable / Técnico",
    # PARTE 2
    "Factura",
    "Certificados B&S",
    "Confirm.\nOS",
    "OS\nEscaneada",
    "Entrega\nImpresa",
    "No. OS\nRealizadas",
    "No. OS\nEn Blanco",
    # Acción
    "Acción",
]

_COL_IDX = {h.replace("\n", " "): i for i, h in enumerate(_COL_HEADERS)}
_N_COLS = len(_COL_HEADERS)

# Anchos de columnas
_COL_WIDTHS = [180, 150, 50, 180, 160, 100, 170, 70, 80, 80, 70, 70, 110]

# Índices fijos
_IDX_EMPRESA    = 0
_IDX_SERVICIO   = 1
_IDX_CANT       = 2
_IDX_FOLIOS     = 3
_IDX_TECNICO    = 4
_IDX_FACTURA    = 5
_IDX_CERTS      = 6
_IDX_CONFIRM    = 7
_IDX_ESCANEO    = 8
_IDX_IMPRESA    = 9
_IDX_REALIZADAS = 10
_IDX_BLANCO     = 11
_IDX_ACCION     = 12

# ─────────────────────────────────────────────────────────────────────────────

def _bool_icon(val: Optional[bool]) -> tuple[str, str, str]:
    """Retorna (texto, bg_color, fg_color) para un booleano."""
    if val is True:
        return ("  ✓  ", _CELL_OK_BG,   _CELL_OK_FG)
    elif val is False:
        return ("  ✗  ", _CELL_ERR_BG,  _CELL_ERR_FG)
    else:
        return ("  —  ", _CELL_NA_BG,   _CELL_NA_FG)


def _escaneo_display(val: Optional[str]) -> tuple[str, str, str]:
    """Retorna (texto, bg, fg) para el estado de escaneo."""
    if val == "OK":
        return ("  ✓  ", _CELL_OK_BG,  _CELL_OK_FG)
    elif val == "NA":
        return ("  N/A  ", _CELL_NA_BG, _CELL_NA_FG)
    else:
        return ("  —  ", _CELL_PEND_BG, _CELL_PEND_FG)


# ══════════════════════════════════════════════════════════════════════════════
# CeldaEstado — QTableWidgetItem con código de color automático
# ══════════════════════════════════════════════════════════════════════════════
class CeldaEstado(QTableWidgetItem):
    def __init__(self, texto: str, bg: str, fg: str):
        super().__init__(texto)
        self.setBackground(QColor(bg))
        self.setForeground(QColor(fg))
        self.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
        font = self.font()
        font.setBold(True)
        self.setFont(font)
        self.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)


# ══════════════════════════════════════════════════════════════════════════════
# LoteEditDialog — Diálogo de edición/creación de lote de recepción
# ══════════════════════════════════════════════════════════════════════════════
class LoteEditDialog(QDialog):
    """
    Diálogo modal para crear o editar un lote de recepción.
    Muestra ambas partes del formulario con validaciones.
    """

    saved = pyqtSignal(dict)  # Emite el dict guardado

    def __init__(self, lote: Optional[dict] = None, parent=None):
        super().__init__(parent)
        self._lote = lote or {}
        self._is_edit = bool(lote)
        self.setWindowTitle("Editar Lote de Recepción" if self._is_edit else "Nuevo Lote de Recepción")
        self.setMinimumWidth(620)
        self.setModal(True)
        self._build_ui()
        if self._is_edit:
            self._load_data()

    def _build_ui(self):
        root = QVBoxLayout(self)
        root.setSpacing(16)
        root.setContentsMargins(24, 24, 24, 24)

        # ── Título ────────────────────────────────────────────────────────────
        title = QLabel("✏  Lote de Recepción")
        title.setStyleSheet(
            "font-size: 18px; font-weight: 700; color: #1D1D1F;"
        )
        root.addWidget(title)

        # ── PARTE 1: Asignación Inicial ───────────────────────────────────────
        grp1 = QGroupBox("PARTE 1 — Asignación Inicial")
        grp1.setStyleSheet(self._group_style("#007AFF"))
        form1 = QFormLayout(grp1)
        form1.setSpacing(10)

        self._inp_fecha = QDateEdit()
        self._inp_fecha.setCalendarPopup(True)
        self._inp_fecha.setDate(QDate.currentDate())
        self._inp_fecha.setDisplayFormat("dd/MM/yyyy")
        form1.addRow("Fecha:", self._inp_fecha)

        self._inp_cliente = QLineEdit()
        self._inp_cliente.setPlaceholderText("Empresa / Cliente")
        form1.addRow("Empresa / Cliente:", self._inp_cliente)

        self._inp_servicio = QLineEdit()
        self._inp_servicio.setPlaceholderText("Tipo de Servicio")
        form1.addRow("Tipo de Servicio:", self._inp_servicio)

        self._inp_cantidad = QSpinBox()
        self._inp_cantidad.setRange(1, 500)
        self._inp_cantidad.setValue(1)
        form1.addRow("Cantidad de OS:", self._inp_cantidad)

        self._inp_folios = QLineEdit()
        self._inp_folios.setPlaceholderText("Ej. 26-363/02 ó 26-344/11, 26-344/14")
        form1.addRow("Folios Asignados:", self._inp_folios)

        self._inp_tecnico = QLineEdit()
        self._inp_tecnico.setPlaceholderText("Nombre del técnico responsable")
        form1.addRow("Responsable / Técnico:", self._inp_tecnico)

        self._inp_tecnicos_extra = QLineEdit()
        self._inp_tecnicos_extra.setPlaceholderText("Técnicos adicionales (opcional)")
        form1.addRow("Técnicos adicionales:", self._inp_tecnicos_extra)

        root.addWidget(grp1)

        # ── PARTE 2: Cierre / Recepción ───────────────────────────────────────
        grp2 = QGroupBox("PARTE 2 — Cierre y Recepción Físico/Digital")
        grp2.setStyleSheet(self._group_style("#34C759"))
        form2 = QFormLayout(grp2)
        form2.setSpacing(10)

        self._inp_factura = QLineEdit()
        self._inp_factura.setPlaceholderText("N° Factura ó N/A si no aplica")
        form2.addRow("Factura:", self._inp_factura)

        self._inp_certs = QLineEdit()
        self._inp_certs.setPlaceholderText("OS.CAL.26.00284 ó N/A")
        form2.addRow("Certificados B&S:", self._inp_certs)

        self._chk_confirm = QCheckBox("Confirmación de OS recibida (✓)")
        form2.addRow("Confirmación OS:", self._chk_confirm)

        self._cmb_escaneo = QComboBox()
        self._cmb_escaneo.addItems(["PENDIENTE", "OK  (✓ Escaneada)", "N/A  (Digital)"])
        form2.addRow("Check OS Escaneada:", self._cmb_escaneo)

        self._inp_realizadas = QSpinBox()
        self._inp_realizadas.setRange(0, 500)
        form2.addRow("No. OS Realizadas:", self._inp_realizadas)

        self._inp_blanco = QSpinBox()
        self._inp_blanco.setRange(0, 500)
        form2.addRow("No. OS en Blanco:", self._inp_blanco)

        self._inp_notas = QTextEdit()
        self._inp_notas.setPlaceholderText("Notas internas de recepción…")
        self._inp_notas.setMaximumHeight(70)
        form2.addRow("Notas:", self._inp_notas)

        root.addWidget(grp2)

        # ── REGLA ESTRICTA ────────────────────────────────────────────────────
        grp3 = QGroupBox("⚠  REGLA ESTRICTA — Entrega de Documento Físico")
        grp3.setStyleSheet(self._group_style("#E63946"))
        lay3 = QVBoxLayout(grp3)

        aviso = QLabel(
            "El técnico tiene la OBLIGACIÓN de entregar la versión impresa en papel\n"
            "con firmas físicas y datos completos. Una OS no puede marcarse\n"
            "COMPLETADA hasta que se confirme la entrega de la copia impresa."
        )
        aviso.setStyleSheet("font-size: 12px; color: #7F1D1D; background: #FEE2E2; "
                            "padding: 10px; border-radius: 6px; line-height: 1.5;")
        aviso.setWordWrap(True)
        lay3.addWidget(aviso)

        self._chk_impresa = QCheckBox(
            "  ✅  Entrega Impresa Recibida (documento físico firmado entregado en recepción)"
        )
        self._chk_impresa.setStyleSheet(
            "font-size: 13px; font-weight: 600; color: #E63946; padding: 6px 0;"
        )
        lay3.addWidget(self._chk_impresa)

        root.addWidget(grp3)

        # ── Botones ───────────────────────────────────────────────────────────
        btn_row = QHBoxLayout()
        btn_row.setSpacing(10)
        btn_row.addStretch()

        btn_cancel = QPushButton("Cancelar")
        btn_cancel.setFixedSize(110, 36)
        btn_cancel.setStyleSheet(self._btn_secondary_style())
        btn_cancel.clicked.connect(self.reject)
        btn_row.addWidget(btn_cancel)

        self._btn_save = QPushButton("💾  Guardar")
        self._btn_save.setFixedSize(130, 36)
        self._btn_save.setStyleSheet(self._btn_primary_style())
        self._btn_save.clicked.connect(self._on_save)
        btn_row.addWidget(self._btn_save)

        root.addLayout(btn_row)
        self._apply_field_styles()

    def _load_data(self):
        """Rellena el formulario con los datos del lote existente."""
        d = self._lote
        if d.get("fecha_asignacion"):
            try:
                from datetime import date as _date
                fd = d["fecha_asignacion"]
                if isinstance(fd, str):
                    fd = _date.fromisoformat(fd)
                self._inp_fecha.setDate(QDate(fd.year, fd.month, fd.day))
            except Exception:
                pass

        self._inp_cliente.setText(str(d.get("cliente") or ""))
        self._inp_servicio.setText(str(d.get("tipo_servicio") or ""))
        self._inp_cantidad.setValue(int(d.get("cantidad_os_asignadas") or 1))
        self._inp_folios.setText(str(d.get("folios_asignados") or ""))
        self._inp_tecnico.setText(str(d.get("tecnico") or ""))
        self._inp_tecnicos_extra.setText(str(d.get("tecnicos_adicionales") or ""))
        self._inp_factura.setText(str(d.get("numero_factura") or ""))
        self._inp_certs.setText(str(d.get("certificados_bs") or ""))
        self._chk_confirm.setChecked(bool(d.get("confirmacion_os")))
        # Escaneo
        escaneo = d.get("check_os_escaneada", "PENDIENTE")
        idx = 0
        if escaneo == "OK":
            idx = 1
        elif escaneo == "NA":
            idx = 2
        self._cmb_escaneo.setCurrentIndex(idx)
        self._inp_realizadas.setValue(int(d.get("no_os_realizadas") or 0))
        self._inp_blanco.setValue(int(d.get("no_os_en_blanco") or 0))
        self._inp_notas.setPlainText(str(d.get("notas_recepcion") or ""))
        self._chk_impresa.setChecked(bool(d.get("entrega_impresa_recibida")))

    def _on_save(self):
        cliente = self._inp_cliente.text().strip()
        if not cliente:
            QMessageBox.warning(self, "Validación", "El campo 'Empresa / Cliente' es obligatorio.")
            return

        escaneo_map = {0: "PENDIENTE", 1: "OK", 2: "NA"}
        escaneo_val = escaneo_map.get(self._cmb_escaneo.currentIndex(), "PENDIENTE")

        qd = self._inp_fecha.date()
        fecha_str = f"{qd.year()}-{qd.month():02d}-{qd.day():02d}"

        data = {
            "fecha_asignacion":          fecha_str,
            "id_cliente":                self._lote.get("id_cliente"),
            "id_tipo_servicio":          self._lote.get("id_tipo_servicio"),
            "id_tecnico":                self._lote.get("id_tecnico"),
            "id_lote_ref":               self._lote.get("id_lote_ref"),
            # Texto libre (cuando no hay IDs directos)
            "_cliente_texto":            cliente,
            "_servicio_texto":           self._inp_servicio.text().strip(),
            "_tecnico_texto":            self._inp_tecnico.text().strip(),
            "tecnicos_adicionales":      self._inp_tecnicos_extra.text().strip() or None,
            "cantidad_os_asignadas":     self._inp_cantidad.value(),
            "folios_asignados":          self._inp_folios.text().strip() or None,
            "numero_factura":            self._inp_factura.text().strip() or None,
            "certificados_bs":           self._inp_certs.text().strip() or None,
            "confirmacion_os":           self._chk_confirm.isChecked(),
            "check_os_escaneada":        escaneo_val,
            "no_os_realizadas":          self._inp_realizadas.value(),
            "no_os_en_blanco":           self._inp_blanco.value(),
            "notas_recepcion":           self._inp_notas.toPlainText().strip() or None,
            "entrega_impresa_recibida":  self._chk_impresa.isChecked(),
        }
        self.saved.emit(data)
        self.accept()

    # ── Estilos ───────────────────────────────────────────────────────────────
    @staticmethod
    def _group_style(color: str) -> str:
        return f"""
            QGroupBox {{
                font-size: 12px; font-weight: 700; color: {color};
                border: 1.5px solid {color}44;
                border-radius: 10px; margin-top: 8px; padding-top: 6px;
            }}
            QGroupBox::title {{
                subcontrol-origin: margin; left: 12px; padding: 0 6px;
                background: white;
            }}
        """

    @staticmethod
    def _btn_primary_style() -> str:
        return """
            QPushButton {
                background: #007AFF; color: white;
                border: none; border-radius: 8px;
                font-size: 13px; font-weight: 600;
            }
            QPushButton:hover { background: #0056CC; }
            QPushButton:pressed { background: #003D99; }
        """

    @staticmethod
    def _btn_secondary_style() -> str:
        return """
            QPushButton {
                background: #F3F4F6; color: #374151;
                border: 1px solid #D1D5DB; border-radius: 8px;
                font-size: 13px;
            }
            QPushButton:hover { background: #E5E7EB; }
        """

    def _apply_field_styles(self):
        field_style = """
            QLineEdit, QTextEdit, QSpinBox, QComboBox, QDateEdit {
                background: #F8FAFC; border: 1.5px solid #D1D5DB;
                border-radius: 8px; padding: 6px 10px;
                font-size: 13px; color: #1D1D1F; min-height: 32px;
            }
            QLineEdit:focus, QTextEdit:focus, QSpinBox:focus,
            QComboBox:focus, QDateEdit:focus {
                border-color: #007AFF; background: #FFFFFF;
            }
        """
        self.setStyleSheet(field_style)


# ══════════════════════════════════════════════════════════════════════════════
# BloqueFecha — Bloque visual para una fecha agrupada
# ══════════════════════════════════════════════════════════════════════════════
class BloqueFecha(QFrame):
    """
    Bloque desplegable que agrupa los lotes de una misma fecha.
    Contiene: cabecera coloreada + tabla con dos partes (PARTE 1 / PARTE 2).
    """

    accion_editar      = pyqtSignal(int)         # id_lote_recepcion
    accion_completar   = pyqtSignal(int)         # id_lote_recepcion
    accion_impresa     = pyqtSignal(int, bool)   # id, valor
    accion_alta_equipo = pyqtSignal(int, dict)   # id_lote, lote_data

    def __init__(self, fecha: str, lotes: list[dict], parent=None):
        super().__init__(parent)
        self._fecha  = fecha
        self._lotes  = lotes
        self._expanded = True
        self._build()

    def _build(self):
        self.setObjectName(f"bloque_{self._fecha}")
        self.setStyleSheet("""
            QFrame {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.08);
                border-radius: 12px;
            }
        """)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # ── Cabecera de fecha ─────────────────────────────────────────────────
        self._header_btn = QPushButton()
        self._header_btn.setFlat(True)
        self._header_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._header_btn.clicked.connect(self._toggle)
        self._update_header()
        root.addWidget(self._header_btn)

        # ── Tabla con cabeceras de dos secciones ──────────────────────────────
        self._tabla_container = QWidget()
        self._tabla_container.setStyleSheet("background: transparent;")
        tc_lay = QVBoxLayout(self._tabla_container)
        tc_lay.setContentsMargins(12, 8, 12, 12)
        tc_lay.setSpacing(4)

        # Leyenda de partes
        leyenda_row = QHBoxLayout()
        leyenda_row.setSpacing(0)

        lbl_p1 = self._make_parte_label("◼  PARTE 1 — Asignación Inicial", _BLUE, 5)
        lbl_p2 = self._make_parte_label("◼  PARTE 2 — Cierre / Recepción Físico-Digital", _GREEN, 8)
        lbl_acc = self._make_parte_label("", _GRAY, 1)

        leyenda_row.addWidget(lbl_p1, 5)
        leyenda_row.addWidget(lbl_p2, 8)
        leyenda_row.addWidget(lbl_acc, 1)
        tc_lay.addLayout(leyenda_row)

        # Tabla principal
        self._table = QTableWidget(len(self._lotes), _N_COLS)
        self._table.setHorizontalHeaderLabels(_COL_HEADERS)
        self._table.setAlternatingRowColors(True)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        self._table.verticalHeader().setVisible(False)
        self._table.setShowGrid(True)
        self._table.setGridStyle(Qt.PenStyle.SolidLine)
        self._table.setStyleSheet(self._table_style())
        self._table.setMinimumHeight(42 * max(len(self._lotes), 1) + 44)

        for col, w in enumerate(_COL_WIDTHS):
            self._table.setColumnWidth(col, w)

        self._populate_table()
        tc_lay.addWidget(self._table)
        root.addWidget(self._tabla_container)

    def _update_header(self):
        """Actualiza el texto del header con la fecha y conteo."""
        arrow = "▲" if self._expanded else "▼"
        try:
            from datetime import date as _date
            fd = _date.fromisoformat(self._fecha)
            meses = ["ene","feb","mar","abr","may","jun",
                     "jul","ago","sep","oct","nov","dic"]
            fecha_fmt = f"{fd.day:02d}-{meses[fd.month - 1]}"
        except Exception:
            fecha_fmt = self._fecha

        n = len(self._lotes)
        texto = f"  📅  Fecha: {fecha_fmt}    ({n} registro{'s' if n != 1 else ''})    {arrow}"
        self._header_btn.setText(texto)
        self._header_btn.setStyleSheet(f"""
            QPushButton {{
                background: qlineargradient(
                    x1:0, y1:0, x2:1, y2:0,
                    stop:0 #0A2342, stop:1 #1A3F6F
                );
                color: white;
                border: none;
                border-radius: 12px 12px 0 0;
                font-size: 14px;
                font-weight: 700;
                text-align: left;
                padding: 10px 20px;
                letter-spacing: 0.3px;
            }}
            QPushButton:hover {{
                background: qlineargradient(
                    x1:0, y1:0, x2:1, y2:0,
                    stop:0 #0D2D52, stop:1 #1F4A7A
                );
            }}
        """)

    def _populate_table(self):
        """Llena la tabla con los datos de los lotes."""
        self._table.setRowCount(len(self._lotes))
        for row, lote in enumerate(self._lotes):
            self._table.setRowHeight(row, 42)
            lid = lote.get("id", row)

            # ── PARTE 1: Asignación ───────────────────────────────────────────
            self._set_text(row, _IDX_EMPRESA,  str(lote.get("cliente") or "—"))
            self._set_text(row, _IDX_SERVICIO, str(lote.get("tipo_servicio") or "—"))
            self._set_text(row, _IDX_CANT,     str(lote.get("cantidad_os_asignadas") or 1),
                           align=Qt.AlignmentFlag.AlignCenter)
            self._set_text(row, _IDX_FOLIOS,   str(lote.get("folios_asignados") or "—"))
            self._set_text(row, _IDX_TECNICO,  str(lote.get("tecnico") or "—"))

            # ── PARTE 2: Recepción ────────────────────────────────────────────

            # Factura — alerta roja si vacía
            factura = lote.get("numero_factura")
            if not factura or str(factura).strip() == "":
                item_fac = CeldaEstado("  ⚠ Sin factura  ", _CELL_ERR_BG, _CELL_ERR_FG)
            elif str(factura).strip().upper() == "N/A":
                item_fac = CeldaEstado("  N/A  ", _CELL_NA_BG, _CELL_NA_FG)
            else:
                item_fac = CeldaEstado(f"  {factura}  ", _CELL_OK_BG, _CELL_OK_FG)
            self._table.setItem(row, _IDX_FACTURA, item_fac)

            # Certificados B&S
            certs = lote.get("certificados_bs")
            if not certs or str(certs).strip() == "":
                self._set_text(row, _IDX_CERTS, "—", align=Qt.AlignmentFlag.AlignCenter)
            elif str(certs).strip().upper() == "N/A":
                self._table.setItem(row, _IDX_CERTS,
                    CeldaEstado("  N/A  ", _CELL_NA_BG, _CELL_NA_FG))
            else:
                it = QTableWidgetItem(str(certs))
                it.setForeground(QColor(_CELL_OK_FG))
                it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                self._table.setItem(row, _IDX_CERTS, it)

            # Confirmación OS
            txt, bg, fg = _bool_icon(lote.get("confirmacion_os"))
            self._table.setItem(row, _IDX_CONFIRM, CeldaEstado(txt, bg, fg))

            # OS Escaneada
            txt, bg, fg = _escaneo_display(lote.get("check_os_escaneada"))
            self._table.setItem(row, _IDX_ESCANEO, CeldaEstado(txt, bg, fg))

            # Entrega Impresa — eje central de la REGLA ESTRICTA
            impresa = lote.get("entrega_impresa_recibida", False)
            txt_imp, bg_imp, fg_imp = _bool_icon(impresa if impresa is not None else None)
            item_imp = CeldaEstado(txt_imp, bg_imp, fg_imp)
            if impresa:
                item_imp.setBackground(QColor("#DCFCE7"))
                item_imp.setForeground(QColor("#166534"))
                item_imp.setText("  ✓ Entregado  ")
            else:
                item_imp.setBackground(QColor("#FEE2E2"))
                item_imp.setForeground(QColor("#991B1B"))
                item_imp.setText("  ✗ Pendiente  ")
            self._table.setItem(row, _IDX_IMPRESA, item_imp)

            # Conteos
            self._set_text(row, _IDX_REALIZADAS, str(lote.get("no_os_realizadas") or 0),
                           align=Qt.AlignmentFlag.AlignCenter)
            self._set_text(row, _IDX_BLANCO,     str(lote.get("no_os_en_blanco") or 0),
                           align=Qt.AlignmentFlag.AlignCenter)

            # ── Celda de Acción: botones ──────────────────────────────────────
            cell_widget = QWidget()
            cell_widget.setStyleSheet("background: transparent;")
            cell_lay = QHBoxLayout(cell_widget)
            cell_lay.setContentsMargins(4, 2, 4, 2)
            cell_lay.setSpacing(4)

            btn_edit = QPushButton("✏")
            btn_edit.setFixedSize(30, 30)
            btn_edit.setToolTip("Editar este lote")
            btn_edit.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_edit.setStyleSheet(self._btn_icon_style(_BLUE))
            btn_edit.clicked.connect(lambda _, lid=lid: self.accion_editar.emit(lid))
            cell_lay.addWidget(btn_edit)

            puede_completar = bool(lote.get("puede_completar") or lote.get("entrega_impresa_recibida"))

            btn_ok = QPushButton("✔")
            btn_ok.setFixedSize(30, 30)
            btn_ok.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_ok.setEnabled(puede_completar)
            if puede_completar:
                btn_ok.setToolTip("Marcar lote como COMPLETADO")
                btn_ok.setStyleSheet(self._btn_icon_style(_GREEN))
            else:
                btn_ok.setToolTip("⚠ Requiere confirmar Entrega Impresa primero")
                btn_ok.setStyleSheet(self._btn_icon_style(_GRAY))
            btn_ok.clicked.connect(lambda _, lid=lid: self.accion_completar.emit(lid))
            cell_lay.addWidget(btn_ok)

            # Toggle rápido de Entrega Impresa
            btn_imp = QPushButton("📄")
            btn_imp.setFixedSize(30, 30)
            btn_imp.setCursor(Qt.CursorShape.PointingHandCursor)
            estado_imp = bool(lote.get("entrega_impresa_recibida"))
            btn_imp.setToolTip(
                "✓ Entrega impresa confirmada" if estado_imp
                else "Marcar como: impresa entregada"
            )
            btn_imp.setStyleSheet(
                self._btn_icon_style(_GREEN if estado_imp else _AMBER)
            )
            btn_imp.clicked.connect(
                lambda _, lid=lid, cur=estado_imp: self.accion_impresa.emit(lid, not cur)
            )
            cell_lay.addWidget(btn_imp)

            # ── Botón [+] Dar de Alta Equipo (Modalidad FÍSICO) ─────────────────
            # Solo aparece cuando hay datos de báscula escaneados pero no registrados en catálogo
            ns_lote = lote.get("ns") or lote.get("numero_serie") or ""
            btn_alta_eq = QPushButton("⊕")
            btn_alta_eq.setFixedSize(30, 30)
            btn_alta_eq.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_alta_eq.setToolTip(
                "➕ Dar de Alta Equipo en el catálogo de esta planta"
            )
            btn_alta_eq.setStyleSheet(self._btn_icon_style("#9B59B6"))
            btn_alta_eq.clicked.connect(
                lambda _, lid=lid, lote_data=lote: self.accion_alta_equipo.emit(lid, lote_data)
            )
            cell_lay.addWidget(btn_alta_eq)

            self._table.setCellWidget(row, _IDX_ACCION, cell_widget)


    def _set_text(
        self, row: int, col: int, texto: str,
        align: Qt.AlignmentFlag = Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
    ):
        item = QTableWidgetItem(texto)
        item.setTextAlignment(align)
        item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
        self._table.setItem(row, col, item)

    def _toggle(self):
        self._expanded = not self._expanded
        self._tabla_container.setVisible(self._expanded)
        self._update_header()

    # ── Estilos ───────────────────────────────────────────────────────────────
    @staticmethod
    def _table_style() -> str:
        return """
            QTableWidget {
                background: #FFFFFF;
                gridline-color: rgba(0,0,0,0.07);
                border: none;
                font-size: 12px;
                color: #1D1D1F;
            }
            QTableWidget::item {
                padding: 4px 8px;
            }
            QTableWidget::item:selected {
                background: rgba(0,122,255,0.12);
                color: #1D1D1F;
            }
            QTableWidget::item:alternate {
                background: #F8FAFC;
            }
            QHeaderView::section {
                background: #F1F5F9;
                color: #374151;
                font-size: 11px;
                font-weight: 700;
                padding: 6px 8px;
                border: none;
                border-right: 1px solid rgba(0,0,0,0.07);
                border-bottom: 1.5px solid rgba(0,0,0,0.10);
            }
        """

    @staticmethod
    def _btn_icon_style(color: str) -> str:
        return f"""
            QPushButton {{
                background: {color}18;
                color: {color};
                border: 1.5px solid {color}44;
                border-radius: 7px;
                font-size: 14px;
                font-weight: 700;
            }}
            QPushButton:hover {{
                background: {color}35;
                border-color: {color};
            }}
            QPushButton:disabled {{
                background: #F3F4F6;
                color: #9CA3AF;
                border-color: #E5E7EB;
            }}
        """

    @staticmethod
    def _make_parte_label(texto: str, color: str, stretch: int) -> QLabel:
        lbl = QLabel(texto)
        lbl.setStyleSheet(f"""
            QLabel {{
                background: {color}12;
                color: {color};
                font-size: 10px;
                font-weight: 700;
                padding: 3px 10px;
                border-radius: 4px;
                letter-spacing: 0.3px;
            }}
        """)
        return lbl

    def refresh(self, lotes: list[dict]):
        """Recarga los datos de la tabla."""
        self._lotes = lotes
        self._populate_table()
        self._update_header()


# ══════════════════════════════════════════════════════════════════════════════
# ResumenKPIBar — Barra de KPIs de la semana seleccionada
# ══════════════════════════════════════════════════════════════════════════════
class ResumenKPIBar(QFrame):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("kpi_bar")
        self.setFixedHeight(80)
        self.setStyleSheet("""
            QFrame#kpi_bar {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.08);
                border-radius: 12px;
            }
        """)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(24, 0, 24, 0)
        lay.setSpacing(0)
        self._kpis: dict[str, tuple[QLabel, QLabel]] = {}
        self._build_kpis(lay)

    def _build_kpis(self, lay):
        items = [
            ("lotes",       "Lotes Registrados", _BLUE),
            ("asignadas",   "OS Asignadas",       _DARK),
            ("realizadas",  "OS Realizadas",      _GREEN),
            ("en_blanco",   "OS en Blanco",       _AMBER),
            ("impresos",    "Impresas ✓",         _GREEN),
            ("sin_factura", "Sin Factura ⚠",      _RED),
        ]
        for i, (key, label, color) in enumerate(items):
            if i > 0:
                sep = QFrame()
                sep.setFrameShape(QFrame.Shape.VLine)
                sep.setStyleSheet("color: rgba(0,0,0,0.08);")
                lay.addWidget(sep)

            col = QWidget()
            col.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
            cl = QVBoxLayout(col)
            cl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            cl.setSpacing(2)

            val_lbl = QLabel("—")
            val_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            val_lbl.setStyleSheet(
                f"font-size: 22px; font-weight: 800; color: {color}; background: transparent;"
            )
            key_lbl = QLabel(label)
            key_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            key_lbl.setStyleSheet(
                "font-size: 10px; color: #86868B; font-weight: 500; background: transparent;"
            )
            cl.addWidget(val_lbl)
            cl.addWidget(key_lbl)
            lay.addWidget(col)
            self._kpis[key] = (val_lbl, key_lbl)

    def update_kpis(self, data: dict):
        mapping = {
            "lotes":       "total_lotes",
            "asignadas":   "total_os_asignadas",
            "realizadas":  "total_os_realizadas",
            "en_blanco":   "total_os_blanco",
            "impresos":    "lotes_impresos",
            "sin_factura": "lotes_sin_factura",
        }
        for key, field in mapping.items():
            val = data.get(field, "—")
            if val is not None:
                self._kpis[key][0].setText(str(val))


# ══════════════════════════════════════════════════════════════════════════════
# RecepcionWidget — Widget principal del módulo
# ══════════════════════════════════════════════════════════════════════════════
class RecepcionWidget(QWidget):
    """
    Módulo de Recepción / Entrega Semanal de Órdenes de Servicio.

    Estructura:
      ┌──────────────────────────────────────────────────────────┐
      │  Header con título + barra de filtros por fecha          │
      ├──────────────────────────────────────────────────────────┤
      │  KPI Bar (resumen de la semana)                          │
      ├──────────────────────────────────────────────────────────┤
      │  ScrollArea con bloques por fecha                        │
      │    ┌── Fecha: 11-may ──────────────────────────────┐    │
      │    │  [PARTE 1 | PARTE 2 | Acción]                 │    │
      │    └────────────────────────────────────────────────┘    │
      │    ┌── Fecha: 12-may ──────────────────────────────┐    │
      │    │  …                                            │    │
      │    └────────────────────────────────────────────────┘    │
      └──────────────────────────────────────────────────────────┘
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self._bloques: dict[str, BloqueFecha] = {}
        self._is_admin_or_logistica = self._check_role()
        self._build_ui()
        QTimer.singleShot(200, self.refresh)

    def _check_role(self) -> bool:
        """Retorna True si el usuario tiene rol admin o logística."""
        if _HAS_SESSION and _session and _session.is_authenticated:
            return _session.role in ("admin", "logistica")
        return False

    # ── Construcción de la UI ─────────────────────────────────────────────────

    def _build_ui(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 20)
        root.setSpacing(16)

        # ── Header ────────────────────────────────────────────────────────────
        root.addWidget(self._build_header())

        # ── KPI Bar ───────────────────────────────────────────────────────────
        self._kpi_bar = ResumenKPIBar()
        root.addWidget(self._kpi_bar)

        # ── Barra de filtros ──────────────────────────────────────────────────
        root.addWidget(self._build_filter_bar())

        # ── Aviso regla estricta ──────────────────────────────────────────────
        root.addWidget(self._build_aviso_regla())

        # ── ScrollArea con bloques ────────────────────────────────────────────
        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setStyleSheet("""
            QScrollArea { border: none; background: transparent; }
            QScrollBar:vertical {
                background: #F1F5F9; width: 8px; border-radius: 4px;
            }
            QScrollBar::handle:vertical {
                background: #CBD5E1; border-radius: 4px; min-height: 20px;
            }
        """)

        self._scroll_content = QWidget()
        self._scroll_content.setStyleSheet("background: transparent;")
        self._bloques_layout = QVBoxLayout(self._scroll_content)
        self._bloques_layout.setContentsMargins(0, 0, 0, 0)
        self._bloques_layout.setSpacing(16)
        self._bloques_layout.addStretch()

        self._scroll.setWidget(self._scroll_content)
        root.addWidget(self._scroll, stretch=1)

        # ── Barra de estado ───────────────────────────────────────────────────
        self._lbl_status = QLabel("Cargando datos…")
        self._lbl_status.setStyleSheet(
            "font-size: 11px; color: #86868B; background: transparent;"
        )
        root.addWidget(self._lbl_status)

    def _build_header(self) -> QWidget:
        header = QWidget()
        header.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(header)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(12)

        # Ícono + título
        lbl_icon = QLabel("📋")
        lbl_icon.setStyleSheet("font-size: 28px; background: transparent;")
        lay.addWidget(lbl_icon)

        title_col = QVBoxLayout()
        lbl_title = QLabel("Recepción / Entrega Semanal de OS")
        lbl_title.setStyleSheet(
            "font-size: 20px; font-weight: 800; color: #1D1D1F; background: transparent;"
        )
        lbl_sub = QLabel("Control de asignación, cierre y entrega de Órdenes de Servicio por fecha")
        lbl_sub.setStyleSheet(
            "font-size: 12px; color: #86868B; background: transparent;"
        )
        title_col.addWidget(lbl_title)
        title_col.addWidget(lbl_sub)
        lay.addLayout(title_col, stretch=1)

        # Botón nuevo lote
        if self._is_admin_or_logistica:
            btn_nuevo = QPushButton("＋  Nuevo Lote")
            btn_nuevo.setFixedHeight(36)
            btn_nuevo.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_nuevo.setStyleSheet("""
                QPushButton {
                    background: #E63946; color: white;
                    border: none; border-radius: 8px;
                    font-size: 13px; font-weight: 700;
                    padding: 0 18px;
                }
                QPushButton:hover { background: #C1121F; }
                QPushButton:pressed { background: #9B0D16; }
            """)
            btn_nuevo.clicked.connect(self._on_nuevo_lote)
            lay.addWidget(btn_nuevo)

        return header

    def _build_filter_bar(self) -> QWidget:
        bar = QWidget()
        bar.setObjectName("filter_bar")
        bar.setFixedHeight(52)
        bar.setStyleSheet("""
            QWidget#filter_bar {
                background: #FFFFFF;
                border: 1px solid rgba(0,0,0,0.08);
                border-radius: 10px;
            }
        """)
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(16, 0, 16, 0)
        lay.setSpacing(12)

        lbl_desde = QLabel("Desde:")
        lbl_desde.setStyleSheet("font-size: 12px; color: #374151; font-weight: 600;")
        lay.addWidget(lbl_desde)

        self._dt_desde = QDateEdit()
        self._dt_desde.setCalendarPopup(True)
        self._dt_desde.setDate(QDate.currentDate().addDays(-14))
        self._dt_desde.setDisplayFormat("dd/MM/yyyy")
        self._dt_desde.setFixedWidth(130)
        self._dt_desde.setStyleSheet(self._date_field_style())
        lay.addWidget(self._dt_desde)

        lbl_hasta = QLabel("Hasta:")
        lbl_hasta.setStyleSheet("font-size: 12px; color: #374151; font-weight: 600;")
        lay.addWidget(lbl_hasta)

        self._dt_hasta = QDateEdit()
        self._dt_hasta.setCalendarPopup(True)
        self._dt_hasta.setDate(QDate.currentDate())
        self._dt_hasta.setDisplayFormat("dd/MM/yyyy")
        self._dt_hasta.setFixedWidth(130)
        self._dt_hasta.setStyleSheet(self._date_field_style())
        lay.addWidget(self._dt_hasta)

        lay.addStretch()

        # Botón semana actual
        btn_semana = QPushButton("📅 Semana actual")
        btn_semana.setFixedHeight(32)
        btn_semana.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_semana.setStyleSheet(self._btn_filter_style())
        btn_semana.clicked.connect(self._set_semana_actual)
        lay.addWidget(btn_semana)

        # Botón mes actual
        btn_mes = QPushButton("🗓 Mes actual")
        btn_mes.setFixedHeight(32)
        btn_mes.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_mes.setStyleSheet(self._btn_filter_style())
        btn_mes.clicked.connect(self._set_mes_actual)
        lay.addWidget(btn_mes)

        # Botón actualizar
        self._btn_refresh = QPushButton("🔄 Actualizar")
        self._btn_refresh.setFixedHeight(32)
        self._btn_refresh.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_refresh.setStyleSheet("""
            QPushButton {
                background: #007AFF; color: white;
                border: none; border-radius: 7px;
                font-size: 12px; font-weight: 600;
                padding: 0 14px;
            }
            QPushButton:hover { background: #0056CC; }
        """)
        self._btn_refresh.clicked.connect(self.refresh)
        lay.addWidget(self._btn_refresh)

        return bar

    def _build_aviso_regla(self) -> QWidget:
        aviso = QFrame()
        aviso.setStyleSheet("""
            QFrame {
                background: #FFF7ED;
                border: 1.5px solid #F97316;
                border-radius: 8px;
            }
        """)
        aviso.setFixedHeight(44)
        lay = QHBoxLayout(aviso)
        lay.setContentsMargins(14, 0, 14, 0)
        lay.setSpacing(10)

        lbl = QLabel(
            "⚠️  REGLA ESTRICTA:  Sin importar la modalidad (Digital o Físico), el técnico DEBE entregar "
            "la versión impresa con firmas físicas en Recepción. La OS no puede marcarse COMPLETADA sin confirmar la entrega."
        )
        lbl.setStyleSheet(
            "font-size: 11px; color: #9A3412; font-weight: 600; background: transparent;"
        )
        lbl.setWordWrap(False)
        lay.addWidget(lbl)
        return aviso

    # ── Carga de datos ────────────────────────────────────────────────────────

    def refresh(self):
        """Recarga los datos desde la BD y reconstruye los bloques."""
        self._btn_refresh.setEnabled(False)
        self._lbl_status.setText("⏳ Cargando…")
        QApplication.processEvents()

        try:
            fecha_desde = self._dt_desde.date().toString("yyyy-MM-dd")
            fecha_hasta = self._dt_hasta.date().toString("yyyy-MM-dd")

            if not _HAS_REPO or recepcion_repo is None:
                self._show_placeholder("⚠", "Base de datos no disponible",
                    "No se pudo conectar al repositorio de recepción.")
                return

            lotes = recepcion_repo.get_all(fecha_desde, fecha_hasta)
            resumen = recepcion_repo.get_resumen_semana(fecha_desde, fecha_hasta)

            # Agrupar por fecha
            por_fecha: dict[str, list[dict]] = {}
            for lote in lotes:
                fkey = str(lote.get("fecha_asignacion", "sin-fecha"))
                if fkey not in por_fecha:
                    por_fecha[fkey] = []
                por_fecha[fkey].append(lote)

            self._rebuild_bloques(por_fecha)
            self._kpi_bar.update_kpis(resumen)

            n_total = sum(len(v) for v in por_fecha.values())
            self._lbl_status.setText(
                f"✅  {n_total} lotes cargados en {len(por_fecha)} fechas  |  "
                f"Rango: {fecha_desde} → {fecha_hasta}"
            )

        except Exception as exc:
            logger.exception("Error al cargar datos de recepción")
            self._lbl_status.setText(f"❌ Error: {exc}")
        finally:
            self._btn_refresh.setEnabled(True)

    def _rebuild_bloques(self, por_fecha: dict[str, list[dict]]):
        """Reconstruye los bloques de fecha en el scroll area."""
        # Limpiar bloques anteriores
        for bloque in self._bloques.values():
            bloque.setParent(None)
            bloque.deleteLater()
        self._bloques.clear()

        # Quitar el stretch al final
        while self._bloques_layout.count() > 0:
            item = self._bloques_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        if not por_fecha:
            # Placeholder vacío
            placeholder = self._build_empty_placeholder()
            self._bloques_layout.addWidget(placeholder)
            self._bloques_layout.addStretch()
            return

        # Insertar bloques ordenados por fecha descendente
        for fecha in sorted(por_fecha.keys(), reverse=True):
            lotes = por_fecha[fecha]
            bloque = BloqueFecha(fecha, lotes)
            bloque.accion_editar.connect(self._on_editar_lote)
            bloque.accion_completar.connect(self._on_completar_lote)
            bloque.accion_impresa.connect(self._on_toggle_impresa)
            bloque.accion_alta_equipo.connect(self._on_alta_equipo_from_lote)
            self._bloques[fecha] = bloque
            self._bloques_layout.addWidget(bloque)

        self._bloques_layout.addStretch()

    # ── Acciones ──────────────────────────────────────────────────────────────

    def _on_nuevo_lote(self):
        dlg = LoteEditDialog(parent=self)
        dlg.saved.connect(self._guardar_nuevo_lote)
        dlg.exec()

    def _on_alta_equipo_from_lote(self, lote_id: int, lote_data: dict):
        """
        Abre el diálogo para dar de alta un equipo en el catálogo de la planta
        a partir de los datos disponibles en el lote de recepción (Modalidad FÍSICO).
        """
        # Intentar obtener sucursal_id del lote
        sucursal_id = lote_data.get("sucursal_id")
        sucursal_nombre = lote_data.get("sucursal_nombre") or "(no especificada)"

        if not sucursal_id:
            # Sin sucursal asignada: el usuario debe elegirla primero
            QMessageBox.information(
                self, "Sucursal no asignada",
                "Este lote no tiene sucursal/planta asignada.\n"
                "Por favor asigna una sucursal al cliente en el módulo de Catálogos primero."
            )
            return

        try:
            from ui.widgets.catalogos_widget import _EquipoEditDialog
            from models.catalogo import equipo_sucursal_repo
        except ImportError as exc:
            QMessageBox.critical(
                self, "Error de importación",
                f"No se pudo cargar el módulo de equipos:\n{exc}"
            )
            return

        # Pre-llenar con datos del lote si existen
        prefill = {
            "numero_serie": lote_data.get("ns") or lote_data.get("numero_serie") or "",
            "marca":        lote_data.get("marca") or "",
            "modelo":       lote_data.get("modelo") or "",
        }

        dlg = _EquipoEditDialog(
            sucursal_id=sucursal_id,
            sucursal_nombre=sucursal_nombre,
            data=prefill if any(prefill.values()) else None,
            parent=self,
        )
        if dlg.exec() == dlg.DialogCode.Accepted:
            try:
                resultado = equipo_sucursal_repo.create(dlg.get_data())
                QMessageBox.information(
                    self, "Equipo Registrado",
                    f"Equipo N/S '{resultado.get('numero_serie')}' registrado correctamente\n"
                    f"en la planta '{sucursal_nombre}'."
                )
            except Exception as exc:
                QMessageBox.critical(
                    self, "Error",
                    f"No se pudo dar de alta el equipo:\n{exc}"
                )

    def _guardar_nuevo_lote(self, data: dict):
        if not _HAS_REPO:
            return
        try:
            # Resolver IDs desde texto si no se tiene el ID directo
            # (en implementación completa se usarían combos con IDs reales)
            recepcion_repo.create(data)
            self.refresh()
        except Exception as exc:
            logger.exception("Error al guardar nuevo lote")
            QMessageBox.critical(self, "Error", f"No se pudo guardar el lote:\n{exc}")

    def _on_editar_lote(self, lote_id: int):
        if not _HAS_REPO:
            return
        lote = recepcion_repo.get_by_id(lote_id)
        if not lote:
            QMessageBox.warning(self, "Lote no encontrado",
                f"No se encontró el lote con ID {lote_id}.")
            return
        dlg = LoteEditDialog(lote=lote, parent=self)
        dlg.saved.connect(lambda data, lid=lote_id: self._guardar_edicion(lid, data))
        dlg.exec()

    def _guardar_edicion(self, lote_id: int, data: dict):
        if not _HAS_REPO:
            return
        try:
            recepcion_repo.update(lote_id, data)
            self.refresh()
        except Exception as exc:
            logger.exception("Error al actualizar lote ID=%d", lote_id)
            QMessageBox.critical(self, "Error", f"No se pudo actualizar el lote:\n{exc}")

    def _on_completar_lote(self, lote_id: int):
        """Intenta marcar el lote como COMPLETADO con la regla estricta."""
        if not _HAS_REPO:
            return

        resp = QMessageBox.question(
            self, "Confirmar completar lote",
            "¿Confirmas que todas las OS del lote han sido entregadas en versión impresa "
            "con firmas físicas y están listas para marcarse como COMPLETADAS?\n\n"
            "Esta acción cambiará el estado de las OS a COMPLETADA.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        resultado = recepcion_repo.marcar_completado(lote_id)
        if resultado.get("ok"):
            n = resultado.get("os_actualizadas", 0)
            QMessageBox.information(
                self, "✅ Lote Completado",
                f"El lote ha sido marcado como COMPLETADO.\n"
                f"{n} OS actualizadas al estado COMPLETADA."
            )
            self.refresh()
        else:
            error = resultado.get("error", "Error desconocido")
            QMessageBox.warning(
                self, "⚠ No se puede completar",
                f"REGLA ESTRICTA:\n\n{error}\n\n"
                "Confirme primero la entrega del documento impreso firmado."
            )

    def _on_toggle_impresa(self, lote_id: int, nuevo_valor: bool):
        """Toggle rápido del estado de entrega impresa."""
        if not _HAS_REPO:
            return

        if nuevo_valor:
            resp = QMessageBox.question(
                self, "Confirmar entrega impresa",
                "¿Confirmas que el técnico entregó el documento impreso con\n"
                "firmas físicas completas en Recepción?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if resp != QMessageBox.StandardButton.Yes:
                return

        ok = recepcion_repo.set_entrega_impresa(lote_id, nuevo_valor)
        if ok:
            self.refresh()
        else:
            QMessageBox.critical(self, "Error",
                "No se pudo actualizar el estado de entrega impresa.")

    # ── Filtros rápidos ───────────────────────────────────────────────────────

    def _set_semana_actual(self):
        hoy = QDate.currentDate()
        inicio_semana = hoy.addDays(-(hoy.dayOfWeek() - 1))
        self._dt_desde.setDate(inicio_semana)
        self._dt_hasta.setDate(hoy)
        self.refresh()

    def _set_mes_actual(self):
        hoy = QDate.currentDate()
        inicio_mes = QDate(hoy.year(), hoy.month(), 1)
        self._dt_desde.setDate(inicio_mes)
        self._dt_hasta.setDate(hoy)
        self.refresh()

    # ── Placeholder vacío ─────────────────────────────────────────────────────

    def _build_empty_placeholder(self) -> QWidget:
        ph = QWidget()
        ph.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(ph)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.setSpacing(12)

        lbl_icon = QLabel("📋")
        lbl_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_icon.setStyleSheet("font-size: 48px; background: transparent;")
        lay.addWidget(lbl_icon)

        lbl_txt = QLabel("Sin registros de recepción en el período seleccionado")
        lbl_txt.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_txt.setStyleSheet(
            "font-size: 15px; color: #86868B; background: transparent;"
        )
        lay.addWidget(lbl_txt)

        if self._is_admin_or_logistica:
            lbl_hint = QLabel("Usa el botón ＋ Nuevo Lote para agregar un registro de recepción.")
            lbl_hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl_hint.setStyleSheet(
                "font-size: 12px; color: #A0ADB8; background: transparent;"
            )
            lay.addWidget(lbl_hint)

        return ph

    def _show_placeholder(self, icon: str, title: str, msg: str):
        ph = QWidget()
        ph.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(ph)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.setSpacing(10)
        lay.addWidget(QLabel(icon))
        t = QLabel(title)
        t.setStyleSheet("font-size: 17px; font-weight: 600; color: #1D1D1F;")
        lay.addWidget(t)
        m = QLabel(msg)
        m.setStyleSheet("font-size: 13px; color: #86868B;")
        lay.addWidget(m)

        while self._bloques_layout.count() > 0:
            item = self._bloques_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._bloques_layout.addWidget(ph)
        self._bloques_layout.addStretch()

    # ── Estilos auxiliares ────────────────────────────────────────────────────
    @staticmethod
    def _date_field_style() -> str:
        return """
            QDateEdit {
                background: #F8FAFC; border: 1.5px solid #D1D5DB;
                border-radius: 7px; padding: 4px 8px;
                font-size: 12px; color: #1D1D1F; min-height: 28px;
            }
            QDateEdit:focus { border-color: #007AFF; background: #FFFFFF; }
        """

    @staticmethod
    def _btn_filter_style() -> str:
        return """
            QPushButton {
                background: #F3F4F6; color: #374151;
                border: 1px solid #D1D5DB; border-radius: 7px;
                font-size: 12px; padding: 0 12px;
            }
            QPushButton:hover { background: #E5E7EB; }
        """
