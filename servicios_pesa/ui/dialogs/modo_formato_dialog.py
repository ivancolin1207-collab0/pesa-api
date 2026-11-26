"""
modo_formato_dialog.py — Dialog de selección de modalidad de trabajo (Físico/Digital)
para la creación de OS, RMA y RE en Servicios PESA v2.0.

Al confirmar retorna un dict con:
    {
        "modalidad":    "FISICO" | "DIGITAL",
        "id_tecnico":   int | None,
        "tecnico_nombre": str,
    }

Uso:
    dialog = ModoFormatoDialog(tipo_formato="OS", parent=self)
    if dialog.exec():
        resultado = dialog.get_resultado()
        # resultado["modalidad"] == "DIGITAL"
        # resultado["id_tecnico"] == 3
"""
from __future__ import annotations

import logging
from typing import Optional

from PyQt6.QtCore    import Qt, pyqtSignal
from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QComboBox, QFrame,
    QButtonGroup, QRadioButton, QGroupBox,
    QDialogButtonBox, QSizePolicy, QSpacerItem,
)
from PyQt6.QtGui import QFont

logger = logging.getLogger(__name__)

try:
    from database.connection import db_pool as _db_pool
    _DEPS_OK = True
except ImportError:
    _DEPS_OK = False
    _db_pool = None


# ─── Paleta Apple Minimalist (macOS Sequoia v3.3.1) ───────────────────────────
_RED   = "#C8102E"
_DARK  = "#1D1D1F"
_GRAY  = "#6E6E73"
_BG    = "#F5F5F7"
_WHITE = "#FFFFFF"
_BLUE  = "#1D1D1F"


# ══════════════════════════════════════════════════════════════════════════════
class ModoFormatoDialog(QDialog):
    """
    Dialog modal para que Logística seleccione:
      1. Modalidad: FÍSICO (impresión calca) o DIGITAL (tablet técnico).
      2. Técnico asignado (obligatorio para DIGITAL).

    Args:
        tipo_formato: 'OS', 'RMA' o 'RE'
        parent: widget padre
    """

    _TIPO_LABELS = {"OS": "Orden de Servicio", "RMA": "Remisión", "RE": "Revisión de Báscula"}

    def __init__(self, tipo_formato: str = "OS", parent=None):
        from PyQt6.QtWidgets import QWidget as _QW
        super().__init__(parent if isinstance(parent, _QW) else None)
        self._tipo = tipo_formato
        self._tecnicos: list[dict] = []
        self._resultado: Optional[dict] = None

        self.setWindowTitle(f"Nueva {self._TIPO_LABELS.get(tipo_formato, tipo_formato)} — Modo de Trabajo")
        self.setModal(True)
        self.setMinimumSize(540, 540)
        self.resize(560, 580)
        self.setWindowFlag(Qt.WindowType.FramelessWindowHint)

        self._build_ui()
        self._apply_styles()
        self._load_tecnicos()

    # ── UI ────────────────────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        main = QVBoxLayout(self)
        main.setContentsMargins(0, 0, 0, 0)
        main.setSpacing(0)

        # ── Cabecera corporativa Apple ─────────────────────────────────────────
        header = QFrame()
        header.setObjectName("dlg_header")
        header.setMinimumHeight(76)
        h_lay = QVBoxLayout(header)
        h_lay.setContentsMargins(28, 16, 28, 16)
        h_lay.setSpacing(4)

        tipo_label = self._TIPO_LABELS.get(self._tipo, self._tipo)
        lbl_h1 = QLabel(f"Nueva {tipo_label}")
        lbl_h1.setObjectName("h1")
        lbl_h2 = QLabel("Selecciona la modalidad de trabajo para este formato")
        lbl_h2.setObjectName("h2")
        h_lay.addWidget(lbl_h1)
        h_lay.addWidget(lbl_h2)
        main.addWidget(header)

        # ── Cuerpo ────────────────────────────────────────────────────────────
        body = QFrame()
        body.setObjectName("dlg_body")
        body_lay = QVBoxLayout(body)
        body_lay.setContentsMargins(28, 22, 28, 22)
        body_lay.setSpacing(16)

        # ── Selector de modalidad ─────────────────────────────────────────────
        lbl_modo = QLabel("Modalidad de trabajo:")
        lbl_modo.setObjectName("section_label")
        body_lay.addWidget(lbl_modo)

        modes_row = QHBoxLayout()
        modes_row.setSpacing(14)

        self.card_fisico = self._make_mode_card(
            "FÍSICO",
            "IMPRESIÓN",
            "Impresión en papel calca.\nEl técnico llena el formato\na mano en campo.",
            "FISICO",
        )
        self.card_digital = self._make_mode_card(
            "DIGITAL",
            "TABLET / MÓVIL",
            "El formato se sincroniza\na la tablet del técnico.\nFirmas digitales en campo.",
            "DIGITAL",
        )
        modes_row.addWidget(self.card_fisico)
        modes_row.addWidget(self.card_digital)
        body_lay.addLayout(modes_row)

        # ── Separador ─────────────────────────────────────────────────────────
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setObjectName("separator")
        body_lay.addWidget(sep)

        # ── Selector de técnico ───────────────────────────────────────────────
        lbl_tec = QLabel("Técnico asignado:")
        lbl_tec.setObjectName("section_label")
        body_lay.addWidget(lbl_tec)

        self.cmb_tecnico = QComboBox()
        self.cmb_tecnico.setObjectName("cmb_tecnico")
        self.cmb_tecnico.setFixedHeight(38)
        self.cmb_tecnico.setPlaceholderText("— Seleccionar técnico —")
        body_lay.addWidget(self.cmb_tecnico)

        self.lbl_tec_info = QLabel("Requerido para modo DIGITAL. Opcional para FÍSICO.")
        self.lbl_tec_info.setObjectName("lbl_tec_info")
        body_lay.addWidget(self.lbl_tec_info)

        # ── Nota modo seleccionado ────────────────────────────────────────────
        self.lbl_nota = QLabel("")
        self.lbl_nota.setObjectName("lbl_nota")
        self.lbl_nota.setWordWrap(True)
        self.lbl_nota.setMinimumHeight(44)
        body_lay.addWidget(self.lbl_nota)

        body_lay.addStretch()

        # ── Botones ───────────────────────────────────────────────────────────
        btn_row = QHBoxLayout()
        btn_row.setSpacing(12)

        self.btn_cancel = QPushButton("Cancelar")
        self.btn_cancel.setObjectName("btn_cancel")
        self.btn_cancel.setFixedHeight(38)
        self.btn_cancel.clicked.connect(self.reject)

        self.btn_confirm = QPushButton("Crear Formato")
        self.btn_confirm.setObjectName("btn_confirm")
        self.btn_confirm.setFixedHeight(38)
        self.btn_confirm.clicked.connect(self._on_confirm)

        btn_row.addWidget(self.btn_cancel)
        btn_row.addWidget(self.btn_confirm, stretch=2)
        body_lay.addLayout(btn_row)

        main.addWidget(body, stretch=1)

        # Seleccionar FÍSICO por defecto
        self._select_mode("FISICO")

    def _make_mode_card(self, title: str, tag: str, desc: str, mode: str) -> QFrame:
        """Crea una tarjeta seleccionable flexible sin altura rígida para evitar recortes."""
        card = QFrame()
        card.setObjectName(f"mode_card_{mode.lower()}")
        card.setProperty("mode", mode)
        card.setCursor(Qt.CursorShape.PointingHandCursor)
        card.setMinimumHeight(140)
        card.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.MinimumExpanding)

        lay = QVBoxLayout(card)
        lay.setContentsMargins(16, 16, 16, 16)
        lay.setSpacing(6)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_tag = QLabel(tag)
        lbl_tag.setObjectName("card_tag")
        lbl_tag.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_title = QLabel(title)
        lbl_title.setObjectName("card_title")
        lbl_title.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_desc = QLabel(desc)
        lbl_desc.setObjectName("card_desc")
        lbl_desc.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_desc.setWordWrap(True)

        lay.addWidget(lbl_tag)
        lay.addWidget(lbl_title)
        lay.addWidget(lbl_desc)

        # Click handler
        card.mousePressEvent = lambda evt, m=mode: self._select_mode(m)
        return card

    def _apply_styles(self) -> None:
        self.setStyleSheet(f"""
            QDialog {{
                background: {_WHITE};
                border-radius: 14px;
                border: 1px solid #E5E5EA;
            }}
            QLabel {{
                border: none;
                background: transparent;
            }}
            QFrame#dlg_header {{
                background: #1D1D1F;
                border-top-left-radius: 14px;
                border-top-right-radius: 14px;
                border-bottom: 1px solid #2C2C2E;
            }}
            QLabel#h1 {{
                color: #FFFFFF;
                font-size: 17px;
                font-weight: 700;
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QLabel#h2 {{
                color: #AEAEB2;
                font-size: 12px;
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QFrame#dlg_body {{
                background: {_WHITE};
            }}
            QLabel#section_label {{
                font-size: 12.5px;
                font-weight: 600;
                color: {_DARK};
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QLabel#card_tag {{
                font-size: 10px;
                font-weight: 700;
                letter-spacing: 0.6px;
                color: {_RED};
                background: #F2F2F7;
                border-radius: 6px;
                padding: 3px 8px;
            }}
            QLabel#card_title {{
                font-size: 14px;
                font-weight: 700;
                color: {_DARK};
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QLabel#card_desc {{
                font-size: 11px;
                color: {_GRAY};
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QFrame#separator {{
                color: #E5E5EA;
                background: #E5E5EA;
                max-height: 1px;
            }}
            QComboBox#cmb_tecnico {{
                border: 1px solid #D2D2D7;
                border-radius: 10px;
                padding: 6px 12px;
                font-size: 13px;
                color: {_DARK};
                background: {_WHITE};
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QComboBox#cmb_tecnico:focus {{
                border: 1.5px solid {_RED};
            }}
            QComboBox#cmb_tecnico::drop-down {{
                border: none;
                width: 28px;
            }}
            QLabel#lbl_tec_info {{
                font-size: 11px;
                color: {_GRAY};
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QLabel#lbl_nota {{
                font-size: 11.5px;
                color: {_DARK};
                background: #F5F5F7;
                border: 1px solid #E5E5EA;
                border-radius: 10px;
                padding: 10px 12px;
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QPushButton#btn_cancel {{
                border: 1px solid #D2D2D7;
                border-radius: 10px;
                background: {_WHITE};
                color: {_DARK};
                font-size: 13px;
                font-weight: 500;
                padding: 0 16px;
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QPushButton#btn_cancel:hover {{
                background: #F2F2F7;
                border-color: #8E8E93;
            }}
            QPushButton#btn_confirm {{
                background: {_RED};
                color: #FFFFFF;
                border: none;
                border-radius: 10px;
                font-size: 13px;
                font-weight: 600;
                padding: 0 18px;
                font-family: "Segoe UI Variable", "Segoe UI", Arial, sans-serif;
            }}
            QPushButton#btn_confirm:hover {{
                background: #A60D26;
            }}
            QPushButton#btn_confirm:disabled {{
                background: #E5E5EA;
                color: #8E8E93;
            }}
        """)

    # ── Lógica ────────────────────────────────────────────────────────────────

    def _select_mode(self, mode: str) -> None:
        """Cambia la tarjeta activa y actualiza la nota informativa."""
        self._selected_mode = mode

        # Resetear estilos de ambas tarjetas (Apple Minimalist — sin rosados pastel)
        for card, m in [(self.card_fisico, "FISICO"), (self.card_digital, "DIGITAL")]:
            cid = f"modo_card_{m.lower()}"
            card.setObjectName(cid)
            if m == mode:
                card.setStyleSheet(f"""
                    QFrame#{cid} {{
                        border: 2px solid {_RED};
                        border-radius: 12px;
                        background: #FFFFFF;
                    }}
                    QFrame#{cid} QLabel {{ border: none; background: transparent; }}
                    QFrame#{cid} QLabel#card_tag {{ background: #F2F2F7; color: {_RED}; border-radius: 6px; padding: 3px 8px; }}
                """)
            else:
                card.setStyleSheet(f"""
                    QFrame#{cid} {{
                        border: 1px solid #E5E5EA;
                        border-radius: 12px;
                        background: #F5F5F7;
                    }}
                    QFrame#{cid}:hover {{
                        border-color: #8E8E93;
                        background: #FFFFFF;
                    }}
                    QFrame#{cid} QLabel {{ border: none; background: transparent; }}
                    QFrame#{cid} QLabel#card_tag {{ background: #E5E5EA; color: #6E6E73; border-radius: 6px; padding: 3px 8px; }}
                """)

        self.lbl_nota.setStyleSheet("")
        if mode == "FISICO":
            self.lbl_nota.setText(
                "Se generará e imprimirá el PDF en papel calca. "
                "El técnico completa el formato a mano y entrega el original "
                "firmado para escanearlo y cerrarlo en el sistema."
            )
        else:
            self.lbl_nota.setText(
                "El formato se enviará a la tablet del técnico seleccionado. "
                "El técnico puede trabajar sin conexión y las firmas digitales se "
                "capturan en campo y sincronizan al conectarse."
            )

    def _load_tecnicos(self) -> None:
        """Carga la lista de técnicos activos desde la BD."""
        self.cmb_tecnico.clear()
        self.cmb_tecnico.addItem("— Seleccionar técnico —", None)

        if not _DEPS_OK:
            # Datos demo
            demo = [
                {"id": 1, "nombre_completo": "Luis Fernando"},
                {"id": 2, "nombre_completo": "Jhonny Jimenez"},
                {"id": 3, "nombre_completo": "Angel Rosales"},
                {"id": 4, "nombre_completo": "Alan Terrazas"},
                {"id": 5, "nombre_completo": "Nestor Gabriel"},
                {"id": 6, "nombre_completo": "Alan Guevara"},
                {"id": 7, "nombre_completo": "Alessandro Segovia"},
            ]
            for t in demo:
                self.cmb_tecnico.addItem(t["nombre_completo"], t["id"])
            self._tecnicos = demo
            return

        try:
            from psycopg2.extras import RealDictCursor as _RDC
            with _db_pool.transaction() as conn:
                with conn.cursor(cursor_factory=_RDC) as cur:
                    cur.execute(
                        """
                        SELECT id, nombre_completo
                        FROM cat_tecnicos
                        WHERE activo = TRUE
                        ORDER BY nombre_completo
                        """
                    )
                    rows = cur.fetchall()
            for row in rows:
                _id  = int(row["id"])
                _nom = str(row["nombre_completo"] or "")
                self.cmb_tecnico.addItem(_nom, _id)
                self._tecnicos.append({"id": _id, "nombre_completo": _nom})
            logger.info("[MODO_FORMATO] %d técnicos cargados desde BD", len(rows))
        except Exception as exc:
            logger.error("Error cargando técnicos en ModoFormatoDialog: %s", exc)
            self.cmb_tecnico.addItem("Error al cargar técnicos", None)

    def _on_confirm(self) -> None:
        """Valida y acepta el diálogo."""
        mode = getattr(self, "_selected_mode", "FISICO")

        id_tecnico = self.cmb_tecnico.currentData()
        tecnico_nombre = self.cmb_tecnico.currentText() \
            if id_tecnico is not None else ""

        # Validación: para DIGITAL el técnico es obligatorio
        if mode == "DIGITAL" and id_tecnico is None:
            self.lbl_nota.setText(
                "Para el modo DIGITAL debes seleccionar un técnico asignado."
            )
            self.lbl_nota.setStyleSheet(
                "color: #C8102E; background: #F5F5F7; border: 1px solid #C8102E; "
                "border-radius: 10px; padding: 10px 12px; font-size: 11.5px; font-weight: 600;"
            )
            return

        self._resultado = {
            "modalidad":      mode,
            "id_tecnico":     id_tecnico,
            "tecnico_nombre": tecnico_nombre,
        }
        logger.info(
            "Formato nuevo: tipo=%s modalidad=%s tecnico_id=%s",
            self._tipo, mode, id_tecnico
        )
        self.accept()

    def get_resultado(self) -> Optional[dict]:
        """
        Retorna el resultado de la selección tras accept().

        Returns:
            {
                "modalidad":      "FISICO" | "DIGITAL",
                "id_tecnico":     int | None,
                "tecnico_nombre": str,
            }
        """
        return self._resultado
