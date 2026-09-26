"""
equipo_search_widget.py — Widget inline de búsqueda y autocompletado de equipos
por ID para Servicios PESA v2.0.

Inserta un campo de búsqueda con botón que, al encontrar el equipo en cat_equipos,
emite la señal `equipo_found` con todos los datos técnicos del equipo.

Uso en un formulario:
    self.equipo_search = EquipoSearchWidget(parent=self)
    self.equipo_search.equipo_found.connect(self._on_equipo_autocompletado)

    def _on_equipo_autocompletado(self, datos: dict):
        self.txt_marca.setText(datos.get("marca", ""))
        self.txt_modelo.setText(datos.get("modelo", ""))
        # ... etc.
"""
from __future__ import annotations

import logging
from typing import Optional

from PyQt6.QtCore    import Qt, pyqtSignal, QTimer
from PyQt6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QLineEdit,
    QPushButton, QLabel, QFrame, QCompleter,
    QSizePolicy,
)
from PyQt6.QtGui import QStandardItemModel, QStandardItem

logger = logging.getLogger(__name__)

try:
    from database.connection import db_pool as _db_pool
    _DEPS_OK = True
except ImportError:
    _DEPS_OK = False
    _db_pool = None


# ─── Paleta ───────────────────────────────────────────────────────────────────
_RED  = "#CC1F1F"
_DARK = "#1C1C1C"
_GRAY = "#6B7280"
_BG   = "#F9FAFB"


# ══════════════════════════════════════════════════════════════════════════════
class EquipoSearchWidget(QWidget):
    """
    Widget compacto de búsqueda de equipo por ID con autocompletado.

    Señales:
        equipo_found(dict):  Emitida cuando se encuentra el equipo.
                             El dict contiene todos los campos de cat_equipos.
        equipo_cleared():    Emitida cuando el usuario borra el campo.

    El widget muestra:
      ┌──────────────────────────────────────┬──────────┐
      │  🔍  ID de Equipo  (campo de texto)  │  Buscar  │
      └──────────────────────────────────────┴──────────┘
      [Chip con nombre del equipo encontrado — si aplica]
    """

    equipo_found   = pyqtSignal(dict)
    equipo_cleared = pyqtSignal()

    def __init__(self, label: str = "ID del Equipo:", parent=None):
        super().__init__(parent)
        self._label_text = label
        self._last_found: Optional[dict] = None
        self._debounce = QTimer(self)
        self._debounce.setSingleShot(True)
        self._debounce.setInterval(350)          # 350ms de debounce
        self._debounce.timeout.connect(self._search_by_id)
        self._all_ids: list[str] = []            # Caché de IDs para autocompletado

        self._build_ui()
        self._load_all_ids()

    # ── UI ────────────────────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(4)

        # ── Label ─────────────────────────────────────────────────────────────
        self.lbl = QLabel(self._label_text)
        self.lbl.setObjectName("eq_label")
        root.addWidget(self.lbl)

        # ── Fila de búsqueda ──────────────────────────────────────────────────
        search_row = QHBoxLayout()
        search_row.setSpacing(6)

        self.txt_id = QLineEdit()
        self.txt_id.setPlaceholderText("Ingresa o busca el ID del equipo…")
        self.txt_id.setObjectName("eq_input")
        self.txt_id.setFixedHeight(38)
        self.txt_id.textChanged.connect(self._on_text_changed)
        self.txt_id.returnPressed.connect(self._search_by_id)

        self.btn_buscar = QPushButton("🔍  Buscar")
        self.btn_buscar.setObjectName("btn_buscar_equipo")
        self.btn_buscar.setFixedHeight(38)
        self.btn_buscar.setFixedWidth(100)
        self.btn_buscar.clicked.connect(self._search_by_id)

        self.btn_limpiar = QPushButton("✕")
        self.btn_limpiar.setObjectName("btn_limpiar_equipo")
        self.btn_limpiar.setFixedSize(38, 38)
        self.btn_limpiar.setToolTip("Limpiar búsqueda")
        self.btn_limpiar.setVisible(False)
        self.btn_limpiar.clicked.connect(self._clear)

        search_row.addWidget(self.txt_id, stretch=1)
        search_row.addWidget(self.btn_buscar)
        search_row.addWidget(self.btn_limpiar)
        root.addLayout(search_row)

        # ── Chip / info del equipo encontrado ─────────────────────────────────
        self.chip = QFrame()
        self.chip.setObjectName("equipo_chip")
        self.chip.setVisible(False)
        chip_lay = QHBoxLayout(self.chip)
        chip_lay.setContentsMargins(10, 6, 10, 6)
        chip_lay.setSpacing(8)

        self.lbl_chip_icon = QLabel("⚙")
        self.lbl_chip_icon.setObjectName("chip_icon")

        self.lbl_chip_text = QLabel("")
        self.lbl_chip_text.setObjectName("chip_text")
        self.lbl_chip_text.setWordWrap(False)

        chip_lay.addWidget(self.lbl_chip_icon)
        chip_lay.addWidget(self.lbl_chip_text, stretch=1)
        root.addWidget(self.chip)

        # ── Mensaje de estado ─────────────────────────────────────────────────
        self.lbl_status = QLabel("")
        self.lbl_status.setObjectName("eq_status")
        self.lbl_status.setVisible(False)
        root.addWidget(self.lbl_status)

        self._apply_styles()

    def _apply_styles(self) -> None:
        self.setStyleSheet(f"""
            /* Label */
            QLabel#eq_label {{
                font-size: 12px;
                font-weight: 600;
                color: #374151;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}

            /* Campo de texto */
            QLineEdit#eq_input {{
                border: 1.5px solid #D1D5DB;
                border-radius: 8px;
                padding: 4px 10px;
                font-size: 13px;
                color: {_DARK};
                background: {_BG};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QLineEdit#eq_input:focus {{
                border-color: {_RED};
                background: white;
            }}

            /* Botón buscar */
            QPushButton#btn_buscar_equipo {{
                background: {_RED};
                color: white;
                border: none;
                border-radius: 8px;
                font-size: 11px;
                font-weight: 700;
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
            QPushButton#btn_buscar_equipo:hover {{
                background: #B91C1C;
            }}

            /* Botón limpiar */
            QPushButton#btn_limpiar_equipo {{
                background: #F3F4F6;
                border: 1.5px solid #D1D5DB;
                border-radius: 8px;
                color: {_GRAY};
                font-size: 14px;
            }}
            QPushButton#btn_limpiar_equipo:hover {{
                background: #FEE2E2;
                border-color: {_RED};
                color: {_RED};
            }}

            /* Chip del equipo encontrado */
            QFrame#equipo_chip {{
                background: #F0FDF4;
                border: 1.5px solid #86EFAC;
                border-radius: 8px;
            }}
            QLabel#chip_icon {{
                font-size: 16px;
                color: #16A34A;
            }}
            QLabel#chip_text {{
                font-size: 11px;
                color: #15803D;
                font-family: 'Segoe UI', Arial, sans-serif;
                font-weight: 600;
            }}

            /* Chip de error */
            QFrame#equipo_chip_error {{
                background: #FEF2F2;
                border: 1.5px solid #FCA5A5;
                border-radius: 8px;
            }}

            /* Status */
            QLabel#eq_status {{
                font-size: 10px;
                color: {_GRAY};
                font-family: 'Segoe UI', Arial, sans-serif;
            }}
        """)

    # ── Carga de IDs para autocompletado ──────────────────────────────────────

    def _load_all_ids(self) -> None:
        """Carga todos los IDs de equipos en caché para el autocompletado."""
        if not _DEPS_OK:
            # IDs demo
            self._all_ids = [
                "EQ-001", "EQ-002", "EQ-003", "BASCULA-PLANTA-A",
                "PZ-2024-001", "PZ-2024-002", "CAMIONERA-01",
            ]
        else:
            try:
                conn = _db_pool.get_connection()
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id_equipo FROM cat_equipos ORDER BY id_equipo LIMIT 1000"
                    )
                    self._all_ids = [row["id_equipo"] for row in cur.fetchall()]
                conn.commit()
                _db_pool.release_connection(conn)
            except Exception as exc:
                logger.warning("No se pudo cargar IDs de equipos: %s", exc)
                self._all_ids = []

        # Configurar QCompleter con los IDs cargados
        model = QStandardItemModel()
        for id_eq in self._all_ids:
            model.appendRow(QStandardItem(id_eq))

        completer = QCompleter(model, self)
        completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        completer.setFilterMode(Qt.MatchFlag.MatchContains)
        completer.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
        self.txt_id.setCompleter(completer)

    # ── Lógica de búsqueda ────────────────────────────────────────────────────

    def _on_text_changed(self, text: str) -> None:
        """Se llama en cada keystroke — lanza debounce."""
        if not text.strip():
            self._clear_chip()
            self.btn_limpiar.setVisible(False)
            return
        self.btn_limpiar.setVisible(True)
        self._debounce.start()

    def _search_by_id(self) -> None:
        """Busca el equipo por ID exacto (o el más parecido)."""
        id_eq = self.txt_id.text().strip()
        if not id_eq:
            return

        datos = self._fetch_equipo(id_eq)
        if datos:
            self._show_chip(datos)
            self._last_found = datos
            self.equipo_found.emit(datos)
        else:
            self._show_not_found(id_eq)

    def _fetch_equipo(self, id_equipo: str) -> Optional[dict]:
        """Consulta cat_equipos por id_equipo exacto."""
        if not _DEPS_OK:
            # Demo: retorna datos ficticios para EQ-001
            if id_equipo.upper() == "EQ-001":
                return {
                    "id_equipo": "EQ-001",
                    "marca": "Rice Lake",
                    "modelo": "RL-150",
                    "ns": "SN-2024-0001",
                    "tipo_instrumento": "Báscula de plataforma",
                    "alcance_max": 5000.0,
                    "div_minima": 0.5,
                    "div_verificacion": 1.0,
                    "ultima_os_folio": "OS-24-123",
                    "ultima_os_fecha": "2024-11-15",
                }
            return None

        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                        ce.id_equipo, ce.marca, ce.modelo, ce.ns,
                        ti.nombre AS tipo_instrumento,
                        ce.alcance_max, ce.div_minima, ce.div_verificacion,
                        ce.ultima_os_folio, ce.ultima_os_fecha,
                        cl.razon_social AS cliente
                    FROM cat_equipos ce
                    LEFT JOIN cat_tipo_instrumento ti ON ce.id_tipo_instrumento = ti.id
                    LEFT JOIN cat_clientes cl         ON ce.id_cliente = cl.id
                    WHERE ce.id_equipo = %s
                    """,
                    (id_equipo,)
                )
                row = cur.fetchone()
            conn.commit()
            _db_pool.release_connection(conn)
            return dict(row) if row else None
        except Exception as exc:
            logger.error("Error buscando equipo %r: %s", id_equipo, exc)
            return None

    # ── Chip de resultado ─────────────────────────────────────────────────────

    def _show_chip(self, datos: dict) -> None:
        """Muestra el chip verde con los datos del equipo encontrado."""
        marca   = datos.get("marca", "")
        modelo  = datos.get("modelo", "")
        folio   = datos.get("ultima_os_folio", "")
        folio_s = f" — Última OS: {folio}" if folio else ""

        self.lbl_chip_icon.setText("✅")
        self.lbl_chip_text.setText(
            f"{datos['id_equipo']}  ·  {marca} {modelo}{folio_s}"
        )

        self.chip.setObjectName("equipo_chip")
        self.chip.setStyleSheet("""
            QFrame {
                background: #F0FDF4;
                border: 1.5px solid #86EFAC;
                border-radius: 8px;
            }
        """)
        self.chip.setVisible(True)

        self.lbl_status.setVisible(True)
        self.lbl_status.setText(
            f"✓ Datos autocargados desde el historial del equipo  |  "
            f"Alcance: {datos.get('alcance_max', '—')}  "
            f"Div.mín.: {datos.get('div_minima', '—')}"
        )

    def _show_not_found(self, id_eq: str) -> None:
        """Muestra un chip rojo indicando que el equipo no existe aún."""
        self.lbl_chip_icon.setText("➕")
        self.lbl_chip_text.setText(
            f"ID \"{id_eq}\" no encontrado — se creará al guardar esta OS"
        )
        self.chip.setStyleSheet("""
            QFrame {
                background: #FFF7ED;
                border: 1.5px solid #FCD34D;
                border-radius: 8px;
            }
        """)
        self.chip.setVisible(True)
        self.lbl_status.setVisible(False)

    def _clear_chip(self) -> None:
        self.chip.setVisible(False)
        self.lbl_status.setVisible(False)

    def _clear(self) -> None:
        """Limpia el campo y el chip."""
        self.txt_id.clear()
        self._clear_chip()
        self._last_found = None
        self.btn_limpiar.setVisible(False)
        self.equipo_cleared.emit()

    # ── Getters públicos ──────────────────────────────────────────────────────

    def get_id_equipo(self) -> str:
        """Retorna el texto actual del campo ID."""
        return self.txt_id.text().strip()

    def get_equipo_data(self) -> Optional[dict]:
        """Retorna los datos del último equipo encontrado, o None."""
        return self._last_found

    def set_id_equipo(self, id_eq: str) -> None:
        """Establece el ID programáticamente y lanza búsqueda."""
        self.txt_id.setText(id_eq)
        if id_eq:
            self._search_by_id()
