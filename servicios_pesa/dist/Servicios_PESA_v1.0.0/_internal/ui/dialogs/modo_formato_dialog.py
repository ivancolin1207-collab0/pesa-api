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


# ─── Paleta ───────────────────────────────────────────────────────────────────
_RED   = "#CC1F1F"
_DARK  = "#1C1C1C"
_GRAY  = "#6B7280"
_BG    = "#F9FAFB"
_WHITE = "#FFFFFF"
_BLUE  = "#2563EB"


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
        super().__init__(parent)
        self._tipo = tipo_formato
        self._tecnicos: list[dict] = []
        self._resultado: Optional[dict] = None

        self.setWindowTitle(f"Nueva {self._TIPO_LABELS.get(tipo_formato, tipo_formato)} — Modo de Trabajo")
        self.setModal(True)
        self.setFixedSize(520, 560)
        self.setWindowFlag(Qt.WindowType.FramelessWindowHint)

        self._build_ui()
        self._apply_styles()
        self._load_tecnicos()

    # ── UI ────────────────────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        main = QVBoxLayout(self)
        main.setContentsMargins(0, 0, 0, 0)
        main.setSpacing(0)

        # ── Cabecera roja ──────────────────────────────────────────────────────
        header = QFrame()
        header.setObjectName("dlg_header")
        header.setFixedHeight(80)
        h_lay = QVBoxLayout(header)
        h_lay.setContentsMargins(30, 0, 30, 0)

        tipo_label = self._TIPO_LABELS.get(self._tipo, self._tipo)
        lbl_h1 = QLabel(f"Nueva {tipo_label}")
        lbl_h1.setObjectName("h1")
        lbl_h2 = QLabel("Selecciona la modalidad de trabajo para este formato")
        lbl_h2.setObjectName("h2")
        h_lay.addStretch()
        h_lay.addWidget(lbl_h1)
        h_lay.addWidget(lbl_h2)
        h_lay.addStretch()
        main.addWidget(header)

        # ── Cuerpo ────────────────────────────────────────────────────────────
        body = QFrame()
        body.setObjectName("dlg_body")
        body_lay = QVBoxLayout(body)
        body_lay.setContentsMargins(30, 24, 30, 24)
        body_lay.setSpacing(20)

        # ── Selector de modalidad ─────────────────────────────────────────────
        lbl_modo = QLabel("Modalidad de trabajo:")
        lbl_modo.setObjectName("section_label")
        body_lay.addWidget(lbl_modo)

        modes_row = QHBoxLayout()
        modes_row.setSpacing(14)

        self.card_fisico  = self._make_mode_card(
            "FÍSICO",
            "🖨️",
            "Impresión en papel calca.\nEl técnico llena el formato\na mano en campo.",
            "FISICO",
        )
        self.card_digital = self._make_mode_card(
            "DIGITAL",
            "📱",
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
        self.cmb_tecnico.setFixedHeight(42)
        self.cmb_tecnico.setPlaceholderText("— Seleccionar técnico —")
        body_lay.addWidget(self.cmb_tecnico)

        self.lbl_tec_info = QLabel("ℹ️  Requerido para modo DIGITAL. Opcional para FÍSICO.")
        self.lbl_tec_info.setObjectName("lbl_tec_info")
        body_lay.addWidget(self.lbl_tec_info)

        # ── Nota modo seleccionado ────────────────────────────────────────────
        self.lbl_nota = QLabel("")
        self.lbl_nota.setObjectName("lbl_nota")
        self.lbl_nota.setWordWrap(True)
        self.lbl_nota.setMinimumHeight(40)
        body_lay.addWidget(self.lbl_nota)

        body_lay.addStretch()

        # ── Botones ───────────────────────────────────────────────────────────
        btn_row = QHBoxLayout()
        btn_row.setSpacing(12)

        self.btn_cancel = QPushButton("Cancelar")
        self.btn_cancel.setObjectName("btn_cancel")
        self.btn_cancel.setFixedHeight(42)
        self.btn_cancel.clicked.connect(self.reject)

        self.btn_confirm = QPushButton("✓  Crear Formato")
        self.btn_confirm.setObjectName("btn_confirm")
        self.btn_confirm.setFixedHeight(42)
        self.btn_confirm.clicked.connect(self._on_confirm)

        btn_row.addWidget(self.btn_cancel)
        btn_row.addWidget(self.btn_confirm, stretch=2)
        body_lay.addLayout(btn_row)

        main.addWidget(body, stretch=1)

        # Seleccionar FÍSICO por defecto
        self._select_mode("FISICO")

    def _make_mode_card(self, title: str, icon: str, desc: str, mode: str) -> QFrame:
        """Crea una tarjeta seleccionable para la modalidad."""
        card = QFrame()
        card.setObjectName(f"mode_card_{mode.lower()}")
        card.setProperty("mode", mode)
        card.setCursor(Qt.CursorShape.PointingHandCursor)
        card.setFixedHeight(160)
        card.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        lay = QVBoxLayout(card)
        lay.setContentsMargins(16, 16, 16, 16)
        lay.setSpacing(8)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_icon = QLabel(icon)
        lbl_icon.setObjectName("card_icon")
        lbl_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_title = QLabel(title)
        lbl_title.setObjectName("card_title")
        lbl_title.setAlignment(Qt.AlignmentFlag.AlignCenter)

        lbl_desc = QLabel(desc)
        lbl_desc.setObjectName("card_desc")
        lbl_desc.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_desc.setWordWrap(True)

        lay.addWidget(lbl_icon)
        lay.addWidget(lbl_title)
        lay.addWidget(lbl_desc)

        # Click handler
        card.mousePressEvent = lambda evt, m=mode: self._select_mode(m)
        return card

    def _apply_styles(self) -> None:
        self.setStyleSheet(f"""
            /* Ventana */
            QDialog {{
                background: {_WHITE};
                border-radius: 12px;
                border: 1px solid #E5E7EB;
            }}

            /* Cabecera */
            QFrame#dlg_header {{
                background: {_RED};
                border-radius: 12px 12px 0 0;
            }}
            QLabel#h1 {{
                color: white;
                font-size: 18px;
                font-weight: 700;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QLabel#h2 {{
                color: rgba(255,255,255,0.8);
                font-size: 11px;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Cuerpo */
            QFrame#dlg_body {{
                background: {_WHITE};
            }}

            /* Labels de sección */
            QLabel#section_label {{
                font-size: 13px;
                font-weight: 700;
                color: {_DARK};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Tarjetas de modo - inactivas */
            QFrame[mode="FISICO"], QFrame[mode="DIGITAL"] {{
                border: 2px solid #E5E7EB;
                border-radius: 10px;
                background: {_BG};
            }}
            QFrame[mode="FISICO"]:hover, QFrame[mode="DIGITAL"]:hover {{
                border-color: {_RED};
                background: #FFF5F5;
            }}

            /* Tarjeta activa - se pone via Python */
            QFrame#mode_card_fisico_active, QFrame#mode_card_digital_active {{
                border: 2.5px solid {_RED};
                border-radius: 10px;
                background: #FEF2F2;
            }}

            /* Ícono de tarjeta */
            QLabel#card_icon {{
                font-size: 32px;
            }}
            QLabel#card_title {{
                font-size: 14px;
                font-weight: 700;
                color: {_DARK};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QLabel#card_desc {{
                font-size: 10px;
                color: {_GRAY};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Separador */
            QFrame#separator {{
                color: #E5E7EB;
            }}

            /* ComboBox */
            QComboBox#cmb_tecnico {{
                border: 1.5px solid #D1D5DB;
                border-radius: 8px;
                padding: 8px 12px;
                font-size: 13px;
                color: {_DARK};
                background: {_BG};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QComboBox#cmb_tecnico:focus {{
                border-color: {_RED};
            }}
            QComboBox#cmb_tecnico::drop-down {{
                border: none;
                width: 30px;
            }}

            /* Info técnico */
            QLabel#lbl_tec_info {{
                font-size: 10px;
                color: {_GRAY};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Nota */
            QLabel#lbl_nota {{
                font-size: 11px;
                color: #374151;
                background: #F3F4F6;
                border-radius: 6px;
                padding: 8px 12px;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Botón cancelar */
            QPushButton#btn_cancel {{
                border: 1.5px solid #D1D5DB;
                border-radius: 8px;
                background: {_WHITE};
                color: {_GRAY};
                font-size: 13px;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QPushButton#btn_cancel:hover {{
                background: #F9FAFB;
                border-color: #9CA3AF;
            }}

            /* Botón confirmar */
            QPushButton#btn_confirm {{
                background: {_RED};
                color: white;
                border: none;
                border-radius: 8px;
                font-size: 13px;
                font-weight: 700;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QPushButton#btn_confirm:hover {{
                background: #B91C1C;
            }}
            QPushButton#btn_confirm:disabled {{
                background: #9CA3AF;
            }}
        """)

    # ── Lógica ────────────────────────────────────────────────────────────────

    def _select_mode(self, mode: str) -> None:
        """Cambia la tarjeta activa y actualiza la nota informativa."""
        self._selected_mode = mode

        # Resetear estilos de ambas tarjetas
        for card, m in [(self.card_fisico, "FISICO"), (self.card_digital, "DIGITAL")]:
            if m == mode:
                card.setStyleSheet(f"""
                    QFrame {{
                        border: 2.5px solid {_RED};
                        border-radius: 10px;
                        background: #FEF2F2;
                    }}
                """)
            else:
                card.setStyleSheet(f"""
                    QFrame {{
                        border: 2px solid #E5E7EB;
                        border-radius: 10px;
                        background: {_BG};
                    }}
                    QFrame:hover {{
                        border-color: {_RED};
                        background: #FFF5F5;
                    }}
                """)

        if mode == "FISICO":
            self.lbl_nota.setText(
                "📄  Se generará e imprimirá el PDF en papel calca. "
                "El técnico completa el formato a mano y debe entregar el original "
                "firmado para escanearlo y cerrarlo en el sistema."
            )
        else:
            self.lbl_nota.setText(
                "📱  El formato se enviará a la tablet del técnico seleccionado. "
                "El técnico puede trabajar sin conexión. Las firmas digitales se "
                "capturan en campo y se sincronizan al conectarse al WiFi de la oficina."
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
            conn = _db_pool.get_connection()
            try:
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
                conn.commit()
            finally:
                _db_pool.release_connection(conn)
            for row in rows:
                _id  = int(row["id"])               # garantizar entero numérico
                _nom = str(row["nombre_completo"] or "")
                self.cmb_tecnico.addItem(_nom, _id)
                self._tecnicos.append({"id": _id, "nombre_completo": _nom})
            logger.info("[MODO_FORMATO] %d técnicos cargados desde BD", len(rows))
        except Exception as exc:
            logger.error("Error cargando técnicos en ModoFormatoDialog: %s", exc)
            self.cmb_tecnico.addItem("⚠ Error al cargar técnicos", None)

    def _on_confirm(self) -> None:
        """Valida y acepta el diálogo."""
        mode = getattr(self, "_selected_mode", "FISICO")

        id_tecnico = self.cmb_tecnico.currentData()
        tecnico_nombre = self.cmb_tecnico.currentText() \
            if id_tecnico is not None else ""

        # Validación: para DIGITAL el técnico es obligatorio
        if mode == "DIGITAL" and id_tecnico is None:
            self.lbl_nota.setText(
                "⚠️  Para el modo DIGITAL debes seleccionar un técnico."
            )
            self.lbl_nota.setStyleSheet(
                "color: #CC1F1F; background: #FEF2F2; border-radius: 6px; "
                "padding: 8px 12px; font-size: 11px;"
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
