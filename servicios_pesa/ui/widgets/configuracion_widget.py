"""
configuracion_widget.py — Panel de Configuración del Sistema — Servicios PESA v2.1

Secciones:
  • Estado de Conexión a BD (con reconexión)
  • Configuración de Red / BD
  • Zona de Administrador (solo admin):
      - Reset de Folios y Pruebas  ← nueva sección peligrosa
  • Información del sistema
"""
from __future__ import annotations

import logging
import datetime
import platform
import sys
from typing import Optional

from PyQt6.QtCore    import Qt, QTimer, pyqtSignal
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QFrame, QLineEdit, QScrollArea,
    QMessageBox, QSizePolicy, QProgressBar, QSpinBox,
)
from PyQt6.QtGui import QFont, QColor

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales ──────────────────────────────────────────────────
try:
    from database.connection import db_pool
    _HAS_DB = True
except ImportError:
    _HAS_DB = False
    db_pool = None

try:
    from auth.session_context import session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    session = None

try:
    import config as _cfg
    _DB_CFG = _cfg.DB_CONFIG
except Exception:
    _DB_CFG = {}

# ─── Paleta ───────────────────────────────────────────────────────────────────
_BG    = "#F5F5F7"
_WHITE = "#FFFFFF"
_DARK  = "#1D1D1F"
_GRAY  = "#86868B"
_RED   = "#E63946"
_BLUE  = "#007AFF"
_GREEN = "#34C759"
_AMBER = "#FF9F0A"


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════
def _section_card() -> tuple[QFrame, QVBoxLayout]:
    card = QFrame()
    card.setStyleSheet("""
        QFrame {
            background: #FFFFFF;
            border: 1px solid rgba(0,0,0,0.07);
            border-radius: 14px;
        }
    """)
    lay = QVBoxLayout(card)
    lay.setContentsMargins(24, 20, 24, 20)
    lay.setSpacing(14)
    return card, lay


def _section_title(text: str, icon: str = "") -> QLabel:
    lbl = QLabel(f"{icon}  {text}" if icon else text)
    lbl.setStyleSheet(
        f"font-size: 14px; font-weight: 700; color: {_DARK}; background: transparent;"
    )
    return lbl


def _sep() -> QFrame:
    f = QFrame()
    f.setFrameShape(QFrame.Shape.HLine)
    f.setStyleSheet("background: rgba(0,0,0,0.06); border: none;")
    f.setFixedHeight(1)
    return f


def _info_row(label: str, value: str) -> QHBoxLayout:
    row = QHBoxLayout()
    lbl_k = QLabel(label)
    lbl_k.setFixedWidth(160)
    lbl_k.setStyleSheet(f"color: {_GRAY}; font-size: 12px; background: transparent;")
    lbl_v = QLabel(value)
    lbl_v.setStyleSheet(f"color: {_DARK}; font-size: 12px; background: transparent;")
    row.addWidget(lbl_k)
    row.addWidget(lbl_v)
    row.addStretch()
    return row


# ══════════════════════════════════════════════════════════════════════════════
class ConfiguracionWidget(QWidget):
    """Panel de configuración con zona peligrosa de administrador."""

    # Señal para refrescar el dashboard y las listas tras un reset
    folios_reseteados = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._build_ui()
        QTimer.singleShot(200, self._check_connection)

    # ══════════════════════════════════════════════════════════════════════════
    # BUILD UI
    # ══════════════════════════════════════════════════════════════════════════
    def _build_ui(self) -> None:
        self.setStyleSheet(f"background: {_BG};")

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("background: transparent; border: none;")

        inner = QWidget()
        inner.setStyleSheet(f"background: {_BG};")
        lay = QVBoxLayout(inner)
        lay.setContentsMargins(28, 24, 28, 40)
        lay.setSpacing(20)
        scroll.setWidget(inner)
        root.addWidget(scroll)

        # Título
        lbl_title = QLabel("⚙️  Configuración del Sistema")
        lbl_title.setStyleSheet(
            f"font-size: 22px; font-weight: 700; color: {_DARK}; "
            f"letter-spacing: -0.4px; background: transparent;"
        )
        lay.addWidget(lbl_title)

        # ── 1. Estado de conexión ─────────────────────────────────────────────
        lay.addWidget(self._build_connection_card())

        # ── 2. Información de BD ──────────────────────────────────────────────
        lay.addWidget(self._build_db_info_card())

        # ── 3. Información del sistema ────────────────────────────────────────
        lay.addWidget(self._build_sysinfo_card())

        # ── 4. Zona de Administrador (solo visible para admin) ────────────────
        is_admin = (session.has_role("admin") if _HAS_SESSION and session else True)
        if is_admin:
            lay.addWidget(self._build_admin_zone())

        lay.addStretch()

    # ── Tarjeta de conexión ───────────────────────────────────────────────────
    def _build_connection_card(self) -> QFrame:
        card, lay = _section_card()
        lay.addWidget(_section_title("Estado de Conexión", "🔌"))
        lay.addWidget(_sep())

        row = QHBoxLayout()

        self._dot = QLabel("●")
        self._dot.setStyleSheet(f"color: {_GRAY}; font-size: 12px; background: transparent;")
        row.addWidget(self._dot)

        self._lbl_conn_status = QLabel("Verificando…")
        self._lbl_conn_status.setStyleSheet(
            f"font-size: 13px; color: {_GRAY}; background: transparent;"
        )
        row.addWidget(self._lbl_conn_status, stretch=1)

        btn_reconectar = QPushButton("↺  Reconectar")
        btn_reconectar.setFixedHeight(32)
        btn_reconectar.setStyleSheet(f"""
            QPushButton {{
                background: transparent;
                color: {_BLUE};
                border: 1px solid rgba(0,122,255,0.3);
                border-radius: 7px;
                font-size: 12px;
                padding: 0 14px;
            }}
            QPushButton:hover {{ background: rgba(0,122,255,0.07); }}
        """)
        btn_reconectar.clicked.connect(self._check_connection)
        row.addWidget(btn_reconectar)

        lay.addLayout(row)

        self._lbl_conn_detail = QLabel("")
        self._lbl_conn_detail.setStyleSheet(
            f"font-size: 11px; color: {_GRAY}; background: transparent;"
        )
        lay.addWidget(self._lbl_conn_detail)
        return card

    # ── Info de BD ────────────────────────────────────────────────────────────
    def _build_db_info_card(self) -> QFrame:
        card, lay = _section_card()
        lay.addWidget(_section_title("Parámetros de Base de Datos", "🗄️"))
        lay.addWidget(_sep())

        host = _DB_CFG.get("host", "—")
        port = str(_DB_CFG.get("port", "—"))
        db   = _DB_CFG.get("database", "—")
        user = _DB_CFG.get("user", "—")

        for k, v in [("Host:", host), ("Puerto:", port),
                     ("Base de datos:", db), ("Usuario:", user)]:
            lay.addLayout(_info_row(k, v))

        return card

    # ── Info del sistema ──────────────────────────────────────────────────────
    def _build_sysinfo_card(self) -> QFrame:
        card, lay = _section_card()
        lay.addWidget(_section_title("Información del Sistema", "💻"))
        lay.addWidget(_sep())

        try:
            import config as _c
            version = _c.APP_VERSION
        except Exception:
            version = "2.0"

        for k, v in [
            ("Versión app:",       f"Servicios PESA v{version}"),
            ("Python:",            sys.version.split()[0]),
            ("Sistema operativo:", platform.system() + " " + platform.version()[:30]),
            ("Fecha del sistema:", datetime.datetime.now().strftime("%d/%m/%Y %H:%M")),
        ]:
            lay.addLayout(_info_row(k, v))

        return card

    # ══════════════════════════════════════════════════════════════════════════
    # ZONA DE ADMINISTRADOR — RESET DE PRUEBAS
    # ══════════════════════════════════════════════════════════════════════════
    def _build_admin_zone(self) -> QFrame:
        """
        Sección de acciones peligrosas, visualmente diferenciada con borde rojo.
        Solo visible para usuarios con rol 'admin'.
        """
        card = QFrame()
        card.setStyleSheet("""
            QFrame {
                background: #FFFFFF;
                border: 1.5px solid rgba(230, 57, 70, 0.35);
                border-radius: 14px;
            }
        """)
        lay = QVBoxLayout(card)
        lay.setContentsMargins(24, 20, 24, 20)
        lay.setSpacing(14)

        # Encabezado
        header_row = QHBoxLayout()
        badge = QLabel("⚠️  ZONA DE ADMINISTRADOR")
        badge.setStyleSheet(f"""
            font-size: 11px; font-weight: 700;
            color: {_RED}; background: rgba(230,57,70,0.08);
            border-radius: 6px; padding: 4px 10px;
        """)
        header_row.addWidget(badge)
        header_row.addStretch()
        lay.addLayout(header_row)

        lay.addWidget(_sep())

        # Descripción
        lbl_desc = QLabel(
            "Las siguientes acciones son irreversibles. "
            "Úsalas únicamente en entorno de desarrollo y pruebas."
        )
        lbl_desc.setWordWrap(True)
        lbl_desc.setStyleSheet(f"font-size: 12px; color: {_GRAY}; background: transparent;")
        lay.addWidget(lbl_desc)

        # ── Sección: Gestión de Secuencia de Folios ────────────────────────────────
        lay.addWidget(_sep())

        lbl_seq_title = QLabel("🔢  Gestión de Secuencia de Folios")
        lbl_seq_title.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        lay.addWidget(lbl_seq_title)

        anio_corto = str(datetime.datetime.now().year)[2:]
        lbl_seq_desc = QLabel(
            f"Define el último número reservado de cada tipo de folio para el año 20{anio_corto}.\n"
            f"El próximo folio generado será el número siguiente al que ingreses."
        )
        lbl_seq_desc.setWordWrap(True)
        lbl_seq_desc.setStyleSheet(f"font-size: 11px; color: {_GRAY}; background: transparent;")
        lay.addWidget(lbl_seq_desc)

        _spn_style = f"""
            QSpinBox {{
                border: 1.5px solid rgba(0,0,0,0.15);
                border-radius: 8px;
                font-size: 14px;
                font-weight: 700;
                padding: 0 8px;
                color: {_DARK};
                background: #FAFAFA;
            }}
            QSpinBox:focus {{ border-color: {_BLUE}; }}
            QSpinBox:disabled {{ color: #C7C7CC; background: #F5F5F7; }}
        """

        grid_row = QHBoxLayout()
        grid_row.setSpacing(24)

        for lbl_txt, attr in [
            ("Folio OS",  "_spin_consec_os"),
            ("Folio RE",  "_spin_consec_re"),
            ("Folio RMA", "_spin_consec_rma"),
        ]:
            col = QVBoxLayout(); col.setSpacing(4)
            col.addWidget(QLabel(lbl_txt))
            spn = QSpinBox()
            spn.setRange(0, 99999); spn.setValue(0)
            spn.setFixedWidth(110); spn.setFixedHeight(36)
            spn.setStyleSheet(_spn_style)
            setattr(self, attr, spn)
            col.addWidget(spn)
            grid_row.addLayout(col)

        grid_row.addStretch()
        lay.addLayout(grid_row)

        btn_save_seq = QPushButton("✓  Guardar Consecutivos")
        btn_save_seq.setFixedHeight(36)
        btn_save_seq.setFixedWidth(210)
        btn_save_seq.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_save_seq.setStyleSheet(f"""
            QPushButton {{
                background: {_BLUE}; color: #FFFFFF;
                border: none; border-radius: 8px;
                font-size: 13px; font-weight: 700; padding: 0 12px;
            }}
            QPushButton:hover {{ background: #0062CC; }}
            QPushButton:pressed {{ background: #0055BB; }}
        """)
        btn_save_seq.clicked.connect(self._on_guardar_consecutivos)
        lay.addWidget(btn_save_seq, alignment=Qt.AlignmentFlag.AlignLeft)

        self._lbl_seq_result = QLabel("")
        self._lbl_seq_result.setStyleSheet(
            f"font-size: 11px; background: transparent; color: {_GREEN};"
        )
        lay.addWidget(self._lbl_seq_result)

        # ── Acción: Reset de Folios y Pruebas ─────────────────────────────────
        lay.addWidget(_sep())
        action_row = QHBoxLayout()
        action_row.setSpacing(16)

        col_desc = QVBoxLayout()
        lbl_action_title = QLabel("🗑️  Reiniciar Folios y Datos de Prueba")
        lbl_action_title.setStyleSheet(
            f"font-size: 13px; font-weight: 700; color: {_DARK}; background: transparent;"
        )
        lbl_action_sub = QLabel(
            "Elimina todas las OS, RMA, RE y sus detalles. "
            "Resetea los consecutivos de folios a 0 para el año actual.\n"
            "El próximo folio generado será OS-26-1."
        )
        lbl_action_sub.setWordWrap(True)
        lbl_action_sub.setStyleSheet(
            f"font-size: 11px; color: {_GRAY}; background: transparent;"
        )
        col_desc.addWidget(lbl_action_title)
        col_desc.addWidget(lbl_action_sub)
        action_row.addLayout(col_desc, stretch=1)

        self.btn_reset = QPushButton("🗑️  Reiniciar Folios y Pruebas")
        self.btn_reset.setFixedHeight(40)
        self.btn_reset.setFixedWidth(230)
        self.btn_reset.setCursor(Qt.CursorShape.PointingHandCursor)
        self.btn_reset.setStyleSheet(f"""
            QPushButton {{
                background: transparent;
                color: {_RED};
                border: 1.5px solid rgba(230, 57, 70, 0.5);
                border-radius: 9px;
                font-size: 13px;
                font-weight: 700;
                padding: 0 16px;
            }}
            QPushButton:hover {{
                background: rgba(230, 57, 70, 0.07);
                border-color: {_RED};
            }}
            QPushButton:pressed {{
                background: rgba(230, 57, 70, 0.14);
            }}
            QPushButton:disabled {{
                color: #C7C7CC;
                border-color: #E5E5EA;
            }}
        """)
        self.btn_reset.clicked.connect(self._on_reset_clicked)
        action_row.addWidget(self.btn_reset)
        lay.addLayout(action_row)

        # Barra de progreso del reset
        self._reset_progress = QProgressBar()
        self._reset_progress.setRange(0, 0)
        self._reset_progress.setFixedHeight(3)
        self._reset_progress.setVisible(False)
        self._reset_progress.setStyleSheet("""
            QProgressBar { border: none; background: #F5F5F7; border-radius: 2px; }
            QProgressBar::chunk { background: #E63946; border-radius: 2px; }
        """)
        lay.addWidget(self._reset_progress)

        # Label de resultado del último reset
        self._lbl_reset_result = QLabel("")
        self._lbl_reset_result.setStyleSheet(
            f"font-size: 11px; background: transparent; color: {_GREEN};"
        )
        lay.addWidget(self._lbl_reset_result)

        # Cargar consecutivos actuales desde la BD
        QTimer.singleShot(300, self._load_consecutivos_actuales)

        return card

    def _load_consecutivos_actuales(self) -> None:
        """Carga los consecutivos actuales de OS, RE y RMA desde la BD."""
        if not _HAS_DB or db_pool is None:
            return
        anio = datetime.datetime.now().year
        try:
            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT tipo_folio, ultimo_consecutivo "
                    "FROM control_folios WHERE anio = %s",
                    (anio,)
                )
                rows = {r[0]: int(r[1] or 0) for r in cur.fetchall()}
            conn.commit()
            db_pool.release_connection(conn)
            mapping = {
                "OS":  "_spin_consec_os",
                "RE":  "_spin_consec_re",
                "RMA": "_spin_consec_rma",
            }
            for tipo, attr in mapping.items():
                if hasattr(self, attr) and tipo in rows:
                    getattr(self, attr).setValue(rows[tipo])
        except Exception as exc:
            logger.warning("No se pudo leer consecutivos actuales: %s", exc)

    def _load_consecutivo_actual(self) -> None:
        """Alias de compatibilidad."""
        self._load_consecutivos_actuales()

    def _on_guardar_consecutivos(self) -> None:
        """Guarda OS, RE y RMA en control_folios con una sola confirmacion."""
        anio = datetime.datetime.now().year
        anio_corto = str(anio)[2:]
        spn_os  = getattr(self, "_spin_consec_os",  None)
        spn_re  = getattr(self, "_spin_consec_re",  None)
        spn_rma = getattr(self, "_spin_consec_rma", None)
        if not all([spn_os, spn_re, spn_rma]):
            return
        v_os = spn_os.value(); v_re = spn_re.value(); v_rma = spn_rma.value()

        resp = QMessageBox.warning(
            self,
            "\u26a0\ufe0f  Actualizar Consecutivos",
            f"Se guardaran:\n\n"
            f"  OS-{anio_corto}-{v_os+1}  (consecutivo \u2192 {v_os})\n"
            f"  RE-{anio_corto}-{v_re+1}  (consecutivo \u2192 {v_re})\n"
            f"  RMA-{anio_corto}-{v_rma+1}  (consecutivo \u2192 {v_rma})\n\n"
            f"\u00bfConfirmas el cambio?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        lbl = getattr(self, "_lbl_seq_result", None)
        if not _HAS_DB or db_pool is None:
            if lbl:
                lbl.setText("\u26a0\ufe0f  Sin BD \u2014 cambio simulado")
                lbl.setStyleSheet(f"font-size: 11px; background: transparent; color: {_AMBER};")
            return

        try:
            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                for tipo, valor in [("OS", v_os), ("RE", v_re), ("RMA", v_rma)]:
                    cur.execute(
                        """
                        INSERT INTO control_folios
                               (tipo_folio, anio, ultimo_consecutivo, updated_at)
                        VALUES (%s, %s, %s, NOW())
                        ON CONFLICT (tipo_folio, anio)
                        DO UPDATE SET ultimo_consecutivo = EXCLUDED.ultimo_consecutivo,
                                      updated_at = NOW()
                        """,
                        (tipo, anio, valor)
                    )
            conn.commit()
            db_pool.release_connection(conn)
            if lbl:
                lbl.setText(
                    f"\u2705  Guardado: OS\u2192{v_os} | RE\u2192{v_re} | RMA\u2192{v_rma}  "
                    f"({datetime.datetime.now().strftime('%H:%M:%S')})"
                )
                lbl.setStyleSheet(f"font-size: 11px; background: transparent; color: {_GREEN};")
            logger.info("Consecutivos: OS=%s RE=%s RMA=%s", v_os, v_re, v_rma)
        except Exception as exc:
            logger.exception("Error al guardar consecutivos: %s", exc)
            if lbl:
                lbl.setText(f"\u274c  Error: {exc}")
                lbl.setStyleSheet(f"font-size: 11px; background: transparent; color: {_RED};")

    def _on_set_consecutivo(self) -> None:
        """Alias de compatibilidad — delega a _on_guardar_consecutivos."""
        self._on_guardar_consecutivos()


    # ══════════════════════════════════════════════════════════════════════════
    # LÓGICA
    # ══════════════════════════════════════════════════════════════════════════

    def _on_reset_clicked(self) -> None:
        """
        Muestra el diálogo de confirmación obligatorio antes del reset.
        Requiere doble confirmación explícita.
        """
        anio = datetime.datetime.now().year
        anio_corto = str(anio)[2:]

        # ── Primera confirmación ───────────────────────────────────────────────
        resp = QMessageBox.warning(
            self,
            "⚠️  Reiniciar Folios y Datos de Prueba",
            f"¿Estás seguro de que deseas eliminar TODAS las OS, RMA y RE de prueba\n"
            f"y reiniciar los consecutivos de folios a 1?\n\n"
            f"• Se eliminarán todas las órdenes de servicio\n"
            f"• Se eliminarán todos los adjuntos y detalles metrológicos\n"
            f"• Los folios volverán a iniciar desde OS-{anio_corto}-1\n\n"
            f"⚠️  Esta acción es IRREVERSIBLE y no se puede deshacer.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,    # Botón por defecto: No
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        # ── Segunda confirmación (protección extra) ────────────────────────────
        resp2 = QMessageBox.critical(
            self,
            "Confirmar Reset — Última oportunidad",
            f"Esta es la última confirmación.\n\n"
            f"Se eliminarán TODOS los datos transaccionales.\n"
            f"El próximo folio será OS-{anio_corto}-1.\n\n"
            f"¿Confirmas el reset completo?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp2 != QMessageBox.StandardButton.Yes:
            return

        # ── Ejecutar reset ─────────────────────────────────────────────────────
        self._ejecutar_reset()

    def _ejecutar_reset(self) -> None:
        """Llama a fn_reset_pruebas() en BD o ejecuta el reset local en modo demo."""
        self.btn_reset.setEnabled(False)
        self._reset_progress.setVisible(True)
        self._lbl_reset_result.setText("")

        anio = datetime.datetime.now().year
        anio_corto = str(anio)[2:]

        try:
            resultado = self._do_reset_db()

            self._reset_progress.setVisible(False)
            self.btn_reset.setEnabled(True)

            # Mostrar resultado
            self._lbl_reset_result.setText(
                f"✅  {resultado}  —  "
                f"{datetime.datetime.now().strftime('%H:%M:%S')}"
            )
            self._lbl_reset_result.setStyleSheet(
                f"font-size: 11px; background: transparent; color: {_GREEN};"
            )

            # Confirmación de éxito
            QMessageBox.information(
                self,
                "✅ Reset Completado",
                f"Folios y datos de prueba reiniciados correctamente.\n\n"
                f"El siguiente folio será:  OS-{anio_corto}-1\n\n"
                f"{resultado}",
            )

            # Emitir señal para refrescar dashboard
            self.folios_reseteados.emit()
            logger.info("Reset de pruebas completado: %s", resultado)

        except Exception as exc:
            self._reset_progress.setVisible(False)
            self.btn_reset.setEnabled(True)
            self._lbl_reset_result.setText(f"❌  Error: {exc}")
            self._lbl_reset_result.setStyleSheet(
                f"font-size: 11px; background: transparent; color: {_RED};"
            )
            logger.exception("Error en reset de pruebas: %s", exc)
            QMessageBox.critical(
                self, "Error en Reset",
                f"No se pudo completar el reset:\n\n{exc}\n\n"
                f"Revisa la consola o pesa.log para más detalles."
            )

    def _do_reset_db(self) -> str:
        """
        Ejecuta el reset real en la base de datos.
        Usa fn_reset_pruebas() si está disponible, si no ejecuta SQL directo.
        Retorna el mensaje de resultado.
        Modo demo: limpieza local sin BD.
        """
        if not _HAS_DB or db_pool is None:
            return (
                "Modo demo — reset simulado. "
                "Sin BD real disponible."
            )

        conn = db_pool.get_connection()
        try:
            with conn.cursor() as cur:
                # Intentar usar la función SQL si existe
                cur.execute("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_proc
                        WHERE proname = 'fn_reset_pruebas'
                    )
                """)
                fn_exists = cur.fetchone()[0]

                if fn_exists:
                    cur.execute("SELECT resultado, os_borradas, anio_reset FROM fn_reset_pruebas()")
                    row = cur.fetchone()
                    conn.commit()
                    return f"{row[0]} ({row[1]} OS eliminadas, año {row[2]})"

                else:
                    # Fallback: ejecutar SQL directo
                    cur.execute("DELETE FROM det_repetibilidad")
                    cur.execute("DELETE FROM det_excentricidad")
                    cur.execute("DELETE FROM det_exactitud")
                    cur.execute("DELETE FROM adjuntos_os")
                    os_count = cur.rowcount
                    cur.execute("DELETE FROM ordenes_servicio")
                    os_count = cur.rowcount

                    anio = datetime.datetime.now().year
                    cur.execute("""
                        UPDATE control_folios
                        SET ultimo_consecutivo = 0, updated_at = NOW()
                        WHERE anio = %s
                    """, (anio,))
                    cur.execute("""
                        INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo)
                        VALUES ('OS', %s, 0), ('RMA', %s, 0), ('RE', %s, 0)
                        ON CONFLICT (tipo_folio, anio) DO NOTHING
                    """, (anio, anio, anio))

                    conn.commit()
                    anio_corto = str(anio)[2:]
                    return (
                        f"Reset completado. Siguiente folio: OS-{anio_corto}-1. "
                        f"{os_count} OS eliminadas."
                    )
        finally:
            db_pool.release_connection(conn)

    # ── Verificar conexión ────────────────────────────────────────────────────
    def _check_connection(self) -> None:
        """Verifica la conexión a BD y actualiza el indicador."""
        self._dot.setStyleSheet(f"color: {_AMBER}; font-size: 12px; background: transparent;")
        self._lbl_conn_status.setText("Verificando…")

        try:
            if not _HAS_DB or db_pool is None:
                self._set_conn_status(False, "Sin módulo de BD — modo demo")
                return

            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute("SELECT version(), NOW()")
                row = cur.fetchone()
                ver  = row[0].split(" ")[0] + " " + row[0].split(" ")[1]
                hora = row[1].strftime("%H:%M:%S") if row[1] else ""
            conn.commit()
            db_pool.release_connection(conn)
            self._set_conn_status(True, f"Conectado — {ver}")
            self._lbl_conn_detail.setText(f"Servidor activo  ·  {hora}")
        except Exception as exc:
            self._set_conn_status(False, f"Sin conexión — {exc}")

    def _set_conn_status(self, ok: bool, msg: str) -> None:
        color = _GREEN if ok else _RED
        self._dot.setStyleSheet(
            f"color: {color}; font-size: 12px; background: transparent;"
        )
        self._lbl_conn_status.setText(msg)
        self._lbl_conn_status.setStyleSheet(
            f"font-size: 13px; color: {_DARK if ok else _GRAY}; background: transparent;"
        )
