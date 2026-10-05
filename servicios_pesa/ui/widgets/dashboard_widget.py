# -*- coding: utf-8 -*-
"""
dashboard_widget.py -- Dashboard estilo macOS / Apple Desktop Application.
Resumen Operativo de Servicios con KPI Cards, tabla de OS y sincronizacion Offline-First.
Reescritura completa v4.1 -- Agrupacion por lotes (Batch Grouping) con QTreeWidget.
"""
from __future__ import annotations

import logging
import os
from datetime import date, timedelta
from typing import Optional

from PyQt6.QtCore import (
    Qt, pyqtSignal, QTimer, QPoint, QSize, QRect, QDate, QThread, pyqtSlot
)
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QFrame, QPushButton, QTableWidget, QTableWidgetItem,
    QHeaderView, QScrollArea, QSizePolicy, QAbstractItemView, QAbstractScrollArea,
    QMessageBox, QButtonGroup, QStyledItemDelegate, QStyleOptionViewItem,
    QStyle, QComboBox, QMenu, QDialog, QFormLayout, QDialogButtonBox,
    QTextEdit, QLineEdit, QDateEdit, QSpacerItem, QProgressDialog,
    QGraphicsDropShadowEffect, QCheckBox, QFileDialog,
    QTreeWidget, QTreeWidgetItem,
)
from PyQt6.QtGui import (
    QColor, QBrush, QFont, QAction, QPainter, QPainterPath, QFontMetrics, QPen
)

logger = logging.getLogger(__name__)

# -- Dependencias opcionales --------------------------------------------------
try:
    from database.connection import db_pool as _db_pool
    _DEPS_OK = True
except ImportError:
    _DEPS_OK = False
    _db_pool = None

try:
    from auth.session_context import session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    session = None

try:
    from sync_manager import sync_manager as _sync_manager
    _HAS_SYNC = True
except ImportError:
    _HAS_SYNC = False
    _sync_manager = None

try:
    from config import OFFLINE_SYNC_INTERVAL_MS as _SYNC_INTERVAL_MS
except ImportError:
    _SYNC_INTERVAL_MS = 300_000  # 5 minutos

# -- Paleta de colores macOS Pro (PESA) ----------------------------------------
_BG       = "#F5F5F7"   # Fondo canvas gris macOS
_WHITE    = "#FFFFFF"
_DARK     = "#1D1D1F"   # Texto primario Apple Anthracite
_GRAY     = "#86868B"   # Texto secundario / metadatos
_LGRAY    = "#C7C7CC"   # Placeholder / hint
_RED      = "#B81D24"   # Rojo carmín técnico PESA
_RED2     = "#9E161C"   # Rojo hover
_BORDER   = "#E5E5EA"   # Borde por defecto
_SEP      = "#F2F2F7"   # Separador ultra fino
_SEG_BG   = "#EBEBED"   # Fondo segmented control


# =============================================================================
# Delegate para badges de estado (pintado directo con QPainter)
# =============================================================================
class StatusBadgeDelegate(QStyledItemDelegate):
    """Pinta badges tipo 'pill' redondeados para columnas de estado."""

    # Tabla de colores por valor de texto (bg, fg, border)
    _BADGE_MAP = {
        # Modalidad
        "fisico":    ("#EDE7F6", "#4A148C", "#D1C4E9"),
        "digital":   ("#E3F2FD", "#0D47A1", "#BBDEFB"),
        # Estado
        "proceso":   ("#FFF3E0", "#E65100", "#FFE0B2"),
        "cerrado":   ("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "cerrada":   ("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "escaneada": ("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "completada":("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "completada_digital": ("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "cancelada": ("#FEE2E2", "#991B1B", "#FCA5A5"),
        # Sync
        "sincronizado": ("#E8F5E9", "#2E7D32", "#C8E6C9"),
        "pendiente":    ("#FFF3E0", "#E65100", "#FFE0B2"),
        "synced":       ("#E8F5E9", "#2E7D32", "#C8E6C9"),
        "pending":      ("#FFF3E0", "#E65100", "#FFE0B2"),
        # Tipos de servicio — etiquetas homologadas con la tablet (match exacto)
        "cca + dve":    ("#EEF2FF", "#3730A3", "#C7D2FE"),
        "cca + ajuste": ("#EFF6FF", "#1D4ED8", "#BFDBFE"),
        "cca":          ("#EFF6FF", "#1D4ED8", "#BFDBFE"),
        "dve + ajuste": ("#F0FDFA", "#0F766E", "#99F6E4"),
        "dve":          ("#F0FDFA", "#0F766E", "#99F6E4"),
        "sin tipo":     ("#FFFBEB", "#B45309", "#FDE68A"),
        "remisión":     ("#F5F5F7", "#48484A", "#E5E5EA"),
        "revisión":     ("#F5F5F7", "#48484A", "#E5E5EA"),
        # Tipos de servicio (texto libre heredado)
        "calibracion":  ("#E8F5E9", "#1B5E20", "#C8E6C9"),
        "ajuste":       ("#F3F4F6", "#4B5563", "#E5E7EB"),
        "inspeccion":   ("#E3F2FD", "#0D47A1", "#BBDEFB"),
        "revision":     ("#F5F5F7", "#48484A", "#E5E5EA"),
        "refacciones":  ("#F5F5F7", "#48484A", "#E5E5EA"),
        "levantamiento":("#EDE7F6", "#4A148C", "#D1C4E9"),
    }

    def _resolve_colors(self, text: str):
        lower = text.lower().strip()
        if lower in self._BADGE_MAP:
            return self._BADGE_MAP[lower]
        for key, colors in self._BADGE_MAP.items():
            if key in lower:
                return colors
        return ("#F5F5F5", "#616161", "#E0E0E0")

    def _abbreviate(self, text: str) -> str:
        """Mantiene textos legibles y sin truncamiento feo."""
        abbr = {
            "Entrega Refacciones": "Refacciones",
            "Calibracion + Ajuste": "Calibración + Ajuste",
            "Inspeccion Visual":   "Inspección",
        }
        for long, short in abbr.items():
            if long.lower() in text.lower():
                return short
        return text

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index) -> None:
        text = index.data(Qt.ItemDataRole.DisplayRole)
        if not text:
            super().paint(painter, option, index)
            return

        display = self._abbreviate(str(text))
        bg_hex, fg_hex, brd_hex = self._resolve_colors(display)
        bg_color = QColor(bg_hex)
        fg_color = QColor(fg_hex)
        brd_color = QColor(brd_hex)

        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Fondo de la celda (hover / selected)
        if option.state & QStyle.StateFlag.State_Selected:
            painter.fillRect(option.rect, QColor(184, 29, 36, 12))
        elif option.state & QStyle.StateFlag.State_MouseOver:
            painter.fillRect(option.rect, QColor(0, 0, 0, 5))

        padding_h = 10
        padding_v = 4
        margin    = 4

        font = QFont(option.font)
        font.setWeight(QFont.Weight.DemiBold)
        font.setPointSizeF(8.5)
        painter.setFont(font)

        fm = QFontMetrics(font)
        text_w = fm.horizontalAdvance(display)
        text_h = fm.height()

        badge_w = min(text_w + padding_h * 2, option.rect.width() - margin * 2)
        badge_h = text_h + padding_v * 2
        badge_x = option.rect.x() + margin
        badge_y = option.rect.y() + (option.rect.height() - badge_h) // 2

        badge_rect = QRect(badge_x, badge_y, badge_w, badge_h)

        path = QPainterPath()
        path.addRoundedRect(
            float(badge_rect.x()), float(badge_rect.y()),
            float(badge_rect.width()), float(badge_rect.height()),
            12.0, 12.0
        )
        painter.fillPath(path, QBrush(bg_color))
        painter.setPen(QPen(brd_color, 1.0))
        painter.drawPath(path)

        painter.setPen(fg_color)
        draw_rect = badge_rect.adjusted(padding_h, 0, -padding_h, 0)
        painter.drawText(draw_rect, Qt.AlignmentFlag.AlignCenter, display)

        painter.restore()

    def sizeHint(self, option: QStyleOptionViewItem, index) -> QSize:
        text = index.data(Qt.ItemDataRole.DisplayRole)
        if not text:
            return super().sizeHint(option, index)
        font = QFont(option.font)
        font.setPointSizeF(8.5)
        fm = QFontMetrics(font)
        w = fm.horizontalAdvance(str(text)) + 24
        return QSize(w, 44)


# =============================================================================
# Delegate para checks de sincronizacion y trazabilidad (estilo WhatsApp)
# =============================================================================
class SyncCheckDelegate(QStyledItemDelegate):
    """
    Renderiza visualmente el estado de sincronizacion tipo WhatsApp como pildoras redondeadas:
      - ASIGNADA:        ✓ Gris  (#616161) — Asignada en Servidor
      - RECIBIDA_TABLET: ✓✓ Gris (#616161) — Recibida en Tablet / En campo
      - SUBIDA_SERVIDOR: ✓✓ Azul (#1565C0) — Enviada al Servidor / Concluida
      - AUDITADA_ADMIN:  ✓✓ Verde (#2E7D32) — Abierto por Administración
    """
    _CONFIG = {
        "ASIGNADA": {
            "symbol": "✓",
            "text": "Asignada",
            "fg": "#616161",
            "bg": "#F5F5F5",
            "border": "#E0E0E0",
            "tooltip": "✓ Gris — Asignada en Servidor (Pendiente de descarga en tablet)",
        },
        "RECIBIDA_TABLET": {
            "symbol": "✓✓",
            "text": "En tablet",
            "fg": "#616161",
            "bg": "#F5F5F5",
            "border": "#E0E0E0",
            "tooltip": "✓✓ Gris — Recibida en Tablet / Tomada en campo offline",
        },
        "SUBIDA_SERVIDOR": {
            "symbol": "✓✓",
            "text": "Recibida",
            "fg": "#1565C0",
            "bg": "#E3F2FD",
            "border": "#90CAF9",
            "tooltip": "✓✓ Azul — Recibida en Servidor / Concluida con PDF",
        },
        "RECIBIDA_SERVIDOR": {
            "symbol": "✓✓",
            "text": "Recibida",
            "fg": "#1565C0",
            "bg": "#E3F2FD",
            "border": "#90CAF9",
            "tooltip": "✓✓ Azul — Recibida en Servidor / Concluida con PDF",
        },
        "AUDITADA_ADMIN": {
            "symbol": "✓✓",
            "text": "Abierto",
            "fg": "#2E7D32",
            "bg": "#E8F5E9",
            "border": "#A5D6A7",
            "tooltip": "✓✓ Verde — Abierto por Administración / Oficina en Windows",
        },
    }

    def _get_cfg(self, raw_val: str) -> dict:
        v = str(raw_val or "").strip().upper()
        if "AUDIT" in v or "ABIERTO" in v or "OPEN" in v:
            return self._CONFIG["AUDITADA_ADMIN"]
        if "SUBIDA" in v or "COMPLET" in v or "CERRAD" in v or "RECIBIDA_SERVIDOR" in v or "ENVIAD" in v:
            return self._CONFIG["SUBIDA_SERVIDOR"]
        if "TABLET" in v or "RECIBIDA_TABLET" in v or "CAMPO" in v or "PROCESO" in v or "PENDIENTE" in v:
            return self._CONFIG["RECIBIDA_TABLET"]
        return self._CONFIG["ASIGNADA"]

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index) -> None:
        raw_val = index.data(Qt.ItemDataRole.UserRole) or index.data(Qt.ItemDataRole.DisplayRole)
        cfg = self._get_cfg(str(raw_val or ""))

        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        if option.state & QStyle.StateFlag.State_Selected:
            painter.fillRect(option.rect, QColor(184, 29, 36, 12))
        elif option.state & QStyle.StateFlag.State_MouseOver:
            painter.fillRect(option.rect, QColor(0, 0, 0, 5))

        symbol = cfg["symbol"]
        text   = cfg["text"]
        fg_col = QColor(cfg["fg"])
        bg_col = QColor(cfg["bg"])
        brd_col= QColor(cfg["border"])

        font = QFont(option.font)
        font.setPointSizeF(8.5)
        font.setWeight(QFont.Weight.DemiBold)
        painter.setFont(font)
        fm = QFontMetrics(font)

        label_full = f"{symbol} {text}"
        tw = fm.horizontalAdvance(label_full)
        th = fm.height()

        padding_h = 8
        padding_v = 4
        margin    = 4

        badge_w = min(tw + padding_h * 2, option.rect.width() - margin * 2)
        badge_h = th + padding_v * 2
        badge_x = option.rect.x() + margin
        badge_y = option.rect.y() + (option.rect.height() - badge_h) // 2

        badge_rect = QRect(badge_x, badge_y, badge_w, badge_h)

        path = QPainterPath()
        path.addRoundedRect(
            float(badge_rect.x()), float(badge_rect.y()),
            float(badge_rect.width()), float(badge_rect.height()),
            12.0, 12.0
        )
        painter.fillPath(path, QBrush(bg_col))
        painter.setPen(QPen(brd_col, 1.0))
        painter.drawPath(path)

        painter.setPen(fg_col)
        draw_rect = badge_rect.adjusted(padding_h, 0, -padding_h, 0)
        painter.drawText(draw_rect, Qt.AlignmentFlag.AlignCenter, label_full)

        painter.restore()

    def sizeHint(self, option: QStyleOptionViewItem, index) -> QSize:
        return QSize(100, 44)


# =============================================================================
# Helpers de sesion
# =============================================================================
def _session_has_role(*roles: str) -> bool:
    """Retorna True si la sesion activa tiene alguno de los roles indicados."""
    if not _HAS_SESSION or not session or not session.is_authenticated:
        return False
    user_roles = set(getattr(session, "roles", []) or [])
    if not user_roles and getattr(session, "role", None):
        user_roles = {session.role}
    return bool(user_roles & set(roles))


# =============================================================================
# Dialogo de edicion rapida de OS
# =============================================================================
class QuickEditOSDialog(QDialog):
    """Dialogo de edicion rapida de datos de una Orden de Servicio."""

    _ESTADOS_VALIDOS = ["PROCESO", "ESCANEADA", "COMPLETADA", "CANCELADA"]

    def __init__(self, os_id: int, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Editar Orden de Servicio")
        self.setMinimumWidth(440)
        self.os_id = os_id

        can_edit_servicio = _session_has_role("admin", "logistica")
        can_edit_estado   = _session_has_role("admin")

        self.combo_servicio = QComboBox()
        self.combo_servicio.setEnabled(can_edit_servicio)
        if not can_edit_servicio:
            self.combo_servicio.setToolTip("Solo Admin y Logistica pueden cambiar el tipo de servicio")

        self.combo_tecnico = QComboBox()

        self.combo_estado = QComboBox()
        for est in self._ESTADOS_VALIDOS:
            self.combo_estado.addItem(est, est)
        self.combo_estado.setEnabled(can_edit_estado)
        if not can_edit_estado:
            self.combo_estado.setToolTip("Solo Admin puede cambiar el estado")

        self.text_obs = QTextEdit()
        self.text_obs.setMaximumHeight(80)

        lay = QFormLayout(self)
        lay.setSpacing(10)
        lay.addRow("Tipo de Servicio:", self.combo_servicio)
        lay.addRow("Tecnico Asignado:", self.combo_tecnico)
        lay.addRow("Estado:",           self.combo_estado)
        lay.addRow("Observaciones:",    self.text_obs)

        self.btn_box = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        self.btn_box.accepted.connect(self.accept)
        self.btn_box.rejected.connect(self.reject)
        lay.addWidget(self.btn_box)

        self._load_data()

    def _load_data(self):
        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute("SELECT id, nombre FROM cat_tipo_servicio ORDER BY nombre")
                for sid, sname in cur.fetchall():
                    self.combo_servicio.addItem(sname, sid)

                cur.execute(
                    "SELECT id, nombre_completo FROM cat_tecnicos "
                    "WHERE activo=TRUE ORDER BY nombre_completo"
                )
                for tid, tname in cur.fetchall():
                    self.combo_tecnico.addItem(tname, tid)

                cur.execute(
                    "SELECT id_tipo_servicio, id_tecnico, observaciones, estado "
                    "FROM ordenes_servicio WHERE id=%s",
                    (self.os_id,)
                )
                row = cur.fetchone()
                if row:
                    sid, tid, obs, estado = row
                    idx_s = self.combo_servicio.findData(sid)
                    if idx_s >= 0:
                        self.combo_servicio.setCurrentIndex(idx_s)
                    idx_t = self.combo_tecnico.findData(tid)
                    if idx_t >= 0:
                        self.combo_tecnico.setCurrentIndex(idx_t)
                    idx_e = self.combo_estado.findData(estado)
                    if idx_e >= 0:
                        self.combo_estado.setCurrentIndex(idx_e)
                    self.text_obs.setPlainText(obs or "")
            _db_pool.release_connection(conn)
        except Exception as e:
            logger.error("Error cargando datos de edicion rapida: %s", e)

    def save_data(self) -> bool:
        sid    = self.combo_servicio.currentData()
        tid    = self.combo_tecnico.currentData()
        obs    = self.text_obs.toPlainText().strip()
        estado = self.combo_estado.currentData()
        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE ordenes_servicio
                    SET id_tipo_servicio = %s,
                        id_tecnico       = %s,
                        observaciones    = %s,
                        estado           = %s,
                        updated_at       = NOW()
                    WHERE id = %s
                    """,
                    (sid, tid, obs, estado, self.os_id),
                )
            conn.commit()
            _db_pool.release_connection(conn)
            return True
        except Exception as e:
            logger.error("Error guardando edicion rapida: %s", e)
            return False


# =============================================================================
# Tarjeta KPI -- estilo macOS Pro
# =============================================================================
class KPICard(QFrame):
    """
    Tarjeta KPI minimalista estilo Apple/macOS HIG.
    Fondo blanco (#FFFFFF), border: 1px solid #E5E5EA, border-radius: 12px, padding: 18px 20px.
    Cifra principal grande (28px bold) alineada a la izquierda.
    Soporta value_color para colorear la cifra principal.
    """

    def __init__(self, title: str, value: str, subtitle: str = "",
                 value_color: str = "#1D1D1F", parent=None):
        super().__init__(parent)
        self._value_color = value_color
        self.setObjectName("kpi_card")
        self.setStyleSheet("""
            QFrame#kpi_card {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 12px;
            }
        """)

        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(12)
        shadow.setOffset(0, 2)
        shadow.setColor(QColor(0, 0, 0, 12))
        self.setGraphicsEffect(shadow)

        self.setMinimumSize(140, 100)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 18, 20, 18)
        lay.setSpacing(6)

        # Etiqueta superior sutil (11px uppercase)
        lbl_title = QLabel(title.upper())
        lbl_title.setObjectName("kpi_title")
        lbl_title.setStyleSheet(
            "font-size: 11px; font-weight: 600; color: #86868B; "
            "letter-spacing: 0.5px; background: transparent;"
        )
        lay.addWidget(lbl_title)

        # Cifra principal grande (28px bold) — color según tipo de métrica
        self.lbl_value = QLabel(value)
        self.lbl_value.setObjectName("kpi_value")
        self.lbl_value.setStyleSheet(
            f"font-size: 28px; font-weight: 700; color: {value_color}; "
            "letter-spacing: -0.5px; background: transparent;"
        )
        lay.addWidget(self.lbl_value)

        # Subtítulo inferior discreto
        if subtitle:
            lbl_sub = QLabel(subtitle)
            lbl_sub.setObjectName("kpi_subtitle")
            lbl_sub.setStyleSheet(
                "font-size: 11px; color: #86868B; font-weight: 400; background: transparent;"
            )
            lay.addWidget(lbl_sub)

        lay.addStretch()

    def set_value(self, value: str) -> None:
        self.lbl_value.setText(value)


# =============================================================================
# Worker de sincronizacion en QThread
# =============================================================================
class _SyncWorker(QThread):
    """Worker que sube registros PENDING de SQLite a PostgreSQL en background."""

    progress     = pyqtSignal(int, int, str)
    finished_ok  = pyqtSignal(int)
    finished_err = pyqtSignal(str)

    def run(self) -> None:
        try:
            if not _HAS_SYNC or _sync_manager is None:
                self.finished_err.emit("SyncManager no disponible.")
                return
            n = _sync_manager.upload_pending(
                progress_callback=lambda cur, tot, f: self.progress.emit(cur, tot, f)
            )
            self.finished_ok.emit(n)
        except Exception as exc:
            self.finished_err.emit(str(exc))


# =============================================================================
# Worker de carga del Dashboard en QThread
# Ejecuta las 3 queries (KPIs + filtros + tabla) en background para que
# el hilo principal nunca se congele esperando respuesta de Render.
# =============================================================================
class _DashboardLoader(QThread):
    """
    Carga KPIs, filtros y registros de tabla en un hilo separado.
    Emite señales con los resultados para que el hilo principal los aplique.

    Todas las queries se consolidan en UN SOLO viaje a la BD cuando es posible,
    y la query de tabla usa LEFT JOIN en lugar de EXISTS() subquery por fila.
    """

    # Resultados de KPIs: (total, proceso, terminadas, fisicos_pend)
    kpis_ready   = pyqtSignal(int, int, int, int)
    # Resultados de filtros: list[tuple[int, str]] tecnicos
    filters_ready = pyqtSignal(list)
    # Resultados de tabla: list de tuplas
    rows_ready   = pyqtSignal(list)
    # Error genérico
    error        = pyqtSignal(str)

    def __init__(
        self,
        fecha_desde,
        fecha_hasta,
        roles: set,
        id_tecnico,
        combo_tec_id,
        combo_estado: str | None,
        load_filters: bool = False,
        parent=None,
    ):
        super().__init__(parent)
        self._fd          = fecha_desde
        self._fh          = fecha_hasta
        self._roles       = roles
        self._id_tecnico  = id_tecnico
        self._tec_filter  = combo_tec_id
        self._estado_filt = combo_estado
        self._load_filters = load_filters

    # ------------------------------------------------------------------
    def run(self) -> None:
        if not _DEPS_OK or _db_pool is None:
            self._run_offline()
            return
        try:
            conn = _db_pool.get_connection()
            try:
                self._run_kpis(conn)
                if self._load_filters:
                    self._run_filters(conn)
                self._run_table(conn)
                conn.commit()
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            import traceback
            print("ERROR EN DASHBOARD WORKER:")
            traceback.print_exc()
            logger.warning("[DashboardLoader] Error: %s", exc)
            self.error.emit(str(exc))

    # ------------------------------------------------------------------
    def _run_offline(self) -> None:
        """Carga desde SQLite cuando no hay BD remota disponible."""
        if not _HAS_SYNC or _sync_manager is None:
            return
        try:
            fd = self._fd.isoformat() if self._fd else None
            fh = self._fh.isoformat() if self._fh else None
            kpis = _sync_manager.get_local_kpis(fd, fh)
            self.kpis_ready.emit(
                int(kpis.get("total", 0)),
                int(kpis.get("proceso", 0)),
                int(kpis.get("terminadas", 0)),
                int(kpis.get("fisicos_pend", 0)),
            )
            _FULL_ACCESS = {"admin", "logistica", "recepcion"}
            id_tec_offline = None
            if not (self._roles & _FULL_ACCESS):
                id_tec_offline = self._id_tecnico
            
            rows_dicts = _sync_manager.get_local_orders(
                fecha_desde=fd, fecha_hasta=fh,
                id_tecnico=id_tec_offline,
            )
            rows = [
                (
                    d.get("folio_os"), d.get("fecha"), d.get("cliente_nombre"),
                    d.get("sucursal_nombre", ""), d.get("tecnico_nombre"),
                    d.get("tipo_servicio_nombre"), d.get("modalidad"), d.get("estado"),
                    d.get("id"), d.get("id_lote"), bool(d.get("tiene_adjunto")),
                    d.get("sync_status", "PENDING"), d.get("rango_lote"),
                )
                for d in rows_dicts
            ]
            self.rows_ready.emit(rows)
        except Exception as exc:
            logger.warning("[DashboardLoader] Offline error: %s", exc)
            self.error.emit(str(exc))

    # ------------------------------------------------------------------
    def _run_kpis(self, conn) -> None:
        """
        Calcula los contadores del periodo sobre EXACTAMENTE el mismo universo
        que la tabla (_run_table): mismo rango de fechas, mismo RBAC y mismo
        filtro de técnico. Así TOTAL >= EN PROCESO + CERRADOS siempre.

        IMPORTANTE: se usa COUNT(*) y no COUNT(os.id). COUNT(columna) ignora
        NULLs, y si alguna orden quedó con id NULL el TOTAL daba 0 mientras
        los COUNT(CASE ...) sí la contaban (bug 'TOTAL 0 / EN PROCESO 3').
        """
        conds: list = []
        params: list = []

        # Periodo seleccionado — idéntico a _run_table
        if self._fd and self._fh:
            conds.append("os.fecha >= %s AND os.fecha < (%s::date + INTERVAL '1 day')")
            params.extend([self._fd, self._fh])

        # RBAC: técnicos de campo solo ven sus propias OS en los contadores
        _FULL_ACCESS = {"admin", "logistica", "recepcion"}
        if not (self._roles & _FULL_ACCESS):
            if (("servicio" in self._roles or "calibrador" in self._roles
                    or "inspector" in self._roles) and self._id_tecnico):
                conds.append("os.id_tecnico = %s")
                params.append(self._id_tecnico)

        # Filtro de técnico del combo — idéntico a _run_table
        if self._tec_filter:
            conds.append("os.id_tecnico = %s")
            params.append(self._tec_filter)

        where_sql = " AND ".join(conds) if conds else "TRUE"

        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT
                    COUNT(*)                                                            AS total_periodo,
                    COUNT(*) FILTER (
                        WHERE os.estado ILIKE '%%proceso%%'
                           OR os.estado ILIKE 'abiert%%'
                           OR os.estado ILIKE 'pendiente%%'
                           OR COALESCE(NULLIF(TRIM(os.estado), ''), '') = ''
                    )                                                                   AS en_proceso,
                    COUNT(*) FILTER (
                        WHERE os.estado ILIKE '%%cerrad%%' OR os.estado ILIKE '%%finaliz%%'
                           OR os.estado ILIKE '%%complet%%' OR os.estado ILIKE 'escaneada'
                    )                                                                   AS cerrados,
                    COUNT(*) FILTER (WHERE os.modalidad ILIKE '%%fisic%%')               AS formatos_fisicos
                FROM ordenes_servicio os
                WHERE {where_sql}
            """, params)
            row = cur.fetchone()
        if row:
            self.kpis_ready.emit(
                int(row[0] or 0), int(row[1] or 0),
                int(row[2] or 0), int(row[3] or 0),
            )


    # ------------------------------------------------------------------
    def _run_filters(self, conn) -> None:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, nombre_completo FROM cat_tecnicos "
                "WHERE activo=TRUE ORDER BY nombre_completo"
            )
            tecnicos = list(cur.fetchall())
        self.filters_ready.emit(tecnicos)

    # ------------------------------------------------------------------
    def _run_table(self, conn) -> None:
        """Query de tabla con JOINs limpios — sin subquery EXISTS() por fila."""
        conditions: list = []
        params: list = []

        # RBAC
        _FULL_ACCESS = {"admin", "logistica", "recepcion"}
        if not (self._roles & _FULL_ACCESS):
            if (("servicio" in self._roles or "calibrador" in self._roles
                    or "inspector" in self._roles) and self._id_tecnico):
                conditions.append("os.id_tecnico = %s")
                params.append(self._id_tecnico)

        where_clause = ""
        if conditions:
            where_clause = "AND (" + " OR ".join(conditions) + ")"

        where_extra: list = []
        if self._fd and self._fh:
            where_extra.append("os.fecha >= %s AND os.fecha < (%s::date + INTERVAL '1 day')")
            params.extend([self._fd, self._fh])
        if self._tec_filter:
            where_extra.append("os.id_tecnico = %s")
            params.append(self._tec_filter)
        if self._estado_filt:
            where_extra.append("os.estado = %s")
            params.append(self._estado_filt)

        if where_extra:
            where_clause += " AND " + " AND ".join(where_extra)

        # LEFT JOIN adjuntos_os — elimina el EXISTS() por fila (N+1 fix)
        # DISTINCT ON (os.id) — defensa permanente contra JOIN multiplication
        sql = f"""
            SELECT
                folio_os,
                fecha_str,
                razon_social,
                ubicacion_final,
                nombre_completo,
                tipo_servicio_final,
                modalidad,
                estado_final,
                id,
                id_lote,
                tiene_adjunto,
                sync_status,
                rango_lote,
                sync_check_status,
                tipo_instrumento,
                marca,
                modelo
            FROM (
                -- Clave DISTINCT tolerante a id NULL: con DISTINCT ON (os.id) todas
                -- las órdenes sin id se fusionaban en UNA sola fila.
                SELECT DISTINCT ON (COALESCE(os.id::text, 'F:' || os.folio_os))
                    os.folio_os,
                    os.fecha::text AS fecha_str,
                    cl.razon_social,
                    COALESCE(
                        NULLIF(TRIM(suc.nombre_sucursal || ' — ' || suc.direccion), ' — '),
                        NULLIF(TRIM(suc.nombre_sucursal), ''),
                        NULLIF(TRIM(os.ubicacion), ''),
                        NULLIF(TRIM(cl.direccion || ', ' || cl.municipio || ', ' || cl.estado_rep), ', , '),
                        NULLIF(TRIM(cl.direccion), ''),
                        NULLIF(TRIM(cl.municipio || ', ' || cl.estado_rep), ', '),
                        cl.razon_social
                    ) AS ubicacion_final,
                    tc.nombre_completo,
                    COALESCE(ts.nombre, os.tipo_servicio) AS tipo_servicio_final,
                    os.modalidad,
                    COALESCE(NULLIF(os.estado, ''), 'Proceso') AS estado_final,
                    os.id,
                    os.id_lote,
                    CASE WHEN adj.id IS NOT NULL THEN TRUE ELSE FALSE END AS tiene_adjunto,
                    COALESCE(os.sync_status, 'SYNCED')                    AS sync_status,
                    os.rango_lote,
                    COALESCE(os.sync_check_status, 'ASIGNADA')            AS sync_check_status,
                    COALESCE(ti.nombre, '')                               AS tipo_instrumento,
                    COALESCE(os.marca, '')                                AS marca,
                    COALESCE(os.modelo, '')                               AS modelo,
                    os.fecha
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes       cl  ON os.id_cliente       = cl.id
                LEFT JOIN cat_tecnicos       tc  ON os.id_tecnico       = tc.id
                LEFT JOIN cat_tipo_servicio  ts  ON os.id_tipo_servicio = ts.id
                LEFT JOIN cliente_sucursales suc ON os.sucursal_id      = suc.id
                LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
                LEFT JOIN LATERAL (
                    SELECT id FROM adjuntos_os WHERE id_os = os.id LIMIT 1
                ) adj ON TRUE
                WHERE 1=1 {where_clause}
            ) sub
            ORDER BY
                -- Orden descendente seguro: extrae el último número del folio
                -- (funciona con OS-26-645, RMA-26-630, RE-26-605, LV-26-1, etc.)
                CASE WHEN sub.folio_os ~ '-[0-9]+$'
                     THEN CAST(REGEXP_REPLACE(sub.folio_os, '^.*-([0-9]+)$', '\\1') AS INTEGER)
                     ELSE 0
                END DESC,
                sub.fecha DESC
            LIMIT 500
        """.format(where_clause=where_clause)
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params or None)
                rows = list(cur.fetchall())
        except Exception as e:
            import traceback as _tb
            logger.warning("Query principal fallo, aplicando fallback: %s", e)
            _tb.print_exc()
            conn.rollback()
            # Fallback sin sucursales / lotes
            sql_fb = f"""
                SELECT
                    os.folio_os, os.fecha::text,
                    cl.razon_social,
                    COALESCE(
                        NULLIF(TRIM(os.ubicacion), ''),
                        NULLIF(TRIM(cl.direccion || ', ' || cl.municipio || ', ' || cl.estado_rep), ', , '),
                        NULLIF(TRIM(cl.direccion), ''),
                        NULLIF(TRIM(cl.municipio || ', ' || cl.estado_rep), ', '),
                        cl.razon_social,
                        ''
                    ),
                    tc.nombre_completo,
                    COALESCE(ts.nombre, os.tipo_servicio),
                    os.modalidad, os.estado, os.id,
                    NULL AS id_lote, FALSE AS tiene_adjunto,
                    'SYNCED' AS sync_status, NULL AS rango_lote,
                    COALESCE(ti.nombre, '') AS tipo_instrumento,
                    COALESCE(os.marca, '') AS marca,
                    COALESCE(os.modelo, '') AS modelo
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes          cl  ON os.id_cliente       = cl.id
                LEFT JOIN cat_tecnicos          tc  ON os.id_tecnico       = tc.id
                LEFT JOIN cat_tipo_servicio     ts  ON os.id_tipo_servicio = ts.id
                LEFT JOIN cat_tipo_instrumento  ti  ON os.id_tipo_instrumento = ti.id
                WHERE 1=1 {where_clause}
                ORDER BY
                    CASE WHEN os.folio_os ~ '-[0-9]+$'
                         THEN CAST(REGEXP_REPLACE(os.folio_os, '^.*-([0-9]+)$', '\\1') AS INTEGER)
                         ELSE 0
                    END DESC,
                    os.fecha DESC
                LIMIT 500
            """
            with conn.cursor() as cur:
                cur.execute(sql_fb, params or None)
                rows = list(cur.fetchall())
        self.rows_ready.emit(rows)


# =============================================================================
# Dialog: Editar Actividad (Logística / Admin)
# =============================================================================
class EditarActividadDialog(QDialog):
    """
    Diálogo de edición de actividad logística para una OS.
    Permite modificar: Fecha compromiso, Hora compromiso,
    Técnico asignado y Unidad/Vehículo.
    Solo accesible para roles admin y logística.
    """

    def __init__(self, os_id: int, folio: str, parent=None):
        super().__init__(parent)
        self._os_id  = os_id
        self._folio  = folio
        self._tecnicos: list[tuple[int, str]] = []

        self.setWindowTitle(f"📅  Editar Actividad  —  {folio}")
        self.setMinimumWidth(480)
        self.setModal(True)

        self._build_ui()
        self._load_data()

    # ── UI ────────────────────────────────────────────────────────────────────
    def _build_ui(self) -> None:
        lay = QVBoxLayout(self)
        lay.setContentsMargins(24, 20, 24, 20)
        lay.setSpacing(16)

        _STYLE_INPUT = (
            "QLineEdit, QDateEdit, QTimeEdit, QComboBox {"
            "  background: #F5F5F7; border: 1.5px solid #D1D1D6;"
            "  border-radius: 8px; padding: 7px 12px;"
            "  font-size: 12px; color: #1D1D1F; min-height: 34px;"
            "}"
            "QLineEdit:focus, QDateEdit:focus, QTimeEdit:focus, QComboBox:focus {"
            "  border-color: #C8102E; background: #FFFFFF;"
            "}"
        )

        title = QLabel(f"📅  Actividad — {self._folio}")
        title.setStyleSheet(
            "font-size: 15px; font-weight: 700; color: #1D1D1F;"
            " background: transparent;"
        )
        lay.addWidget(title)

        # Separador
        sep = QFrame(); sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("color: #E5E5EA;")
        lay.addWidget(sep)

        form = QGridLayout()
        form.setSpacing(10)
        form.setColumnStretch(1, 1)

        # Fecha compromiso
        form.addWidget(QLabel("Fecha compromiso:"), 0, 0)
        self._dte_fecha = QDateEdit()
        self._dte_fecha.setCalendarPopup(True)
        self._dte_fecha.setDate(QDate.currentDate())
        self._dte_fecha.setDisplayFormat("dd / MM / yyyy")
        self._dte_fecha.setStyleSheet(_STYLE_INPUT)
        form.addWidget(self._dte_fecha, 0, 1)

        # Hora compromiso
        form.addWidget(QLabel("Hora compromiso:"), 1, 0)
        self._dte_hora = QTimeEdit()
        self._dte_hora.setDisplayFormat("HH:mm")
        self._dte_hora.setTime(QTime(8, 0))
        self._dte_hora.setStyleSheet(_STYLE_INPUT)
        form.addWidget(self._dte_hora, 1, 1)

        # Técnico asignado
        form.addWidget(QLabel("Técnico asignado:"), 2, 0)
        self._cmb_tecnico = QComboBox()
        self._cmb_tecnico.setEditable(False)
        self._cmb_tecnico.setStyleSheet(_STYLE_INPUT)
        form.addWidget(self._cmb_tecnico, 2, 1)

        # Unidad / Vehículo
        form.addWidget(QLabel("Unidad / Vehículo:"), 3, 0)
        self._inp_unidad = QLineEdit()
        self._inp_unidad.setPlaceholderText("Ej: Suburban Blanca — Placa ABC-123")
        self._inp_unidad.setStyleSheet(_STYLE_INPUT)
        form.addWidget(self._inp_unidad, 3, 1)

        # Notas de ruta
        form.addWidget(QLabel("Notas de ruta:"), 4, 0)
        self._inp_notas = QLineEdit()
        self._inp_notas.setPlaceholderText("Instrucciones adicionales para el técnico…")
        self._inp_notas.setStyleSheet(_STYLE_INPUT)
        form.addWidget(self._inp_notas, 4, 1)

        lay.addLayout(form)

        # Botones
        btn_row = QHBoxLayout()
        btn_row.addStretch()

        btn_cancel = QPushButton("Cancelar")
        btn_cancel.setFixedHeight(36)
        btn_cancel.setStyleSheet(
            "QPushButton { background:#F2F2F7; color:#1D1D1F; border:1px solid #D1D1D6;"
            " border-radius:7px; font-size:11px; padding:0 18px; }"
            "QPushButton:hover { background:#E5E5EA; }"
        )
        btn_cancel.clicked.connect(self.reject)
        btn_row.addWidget(btn_cancel)

        self._btn_save = QPushButton("💾  Guardar Actividad")
        self._btn_save.setFixedHeight(36)
        self._btn_save.setStyleSheet(
            "QPushButton { background:#C8102E; color:#FFFFFF; border:none;"
            " border-radius:7px; font-size:11px; font-weight:700; padding:0 20px; }"
            "QPushButton:hover { background:#A80D25; }"
        )
        self._btn_save.clicked.connect(self._on_save)
        btn_row.addWidget(self._btn_save)

        lay.addLayout(btn_row)

    # ── Carga de datos actuales ───────────────────────────────────────────────
    def _load_data(self) -> None:
        """Carga los datos actuales de la OS y la lista de técnicos desde BD."""
        if not _HAS_DB or not _db_pool:
            self._cmb_tecnico.addItem("— Sin conexión a BD —")
            return
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    # Técnicos activos
                    cur.execute(
                        "SELECT id, nombre FROM cat_tecnicos WHERE activo = TRUE ORDER BY nombre"
                    )
                    self._tecnicos = cur.fetchall() or []
                    self._cmb_tecnico.clear()
                    self._cmb_tecnico.addItem("— Selecciona técnico —", None)
                    for tid, tnombre in self._tecnicos:
                        self._cmb_tecnico.addItem(tnombre, tid)

                    # Datos actuales de la OS
                    cur.execute(
                        "SELECT fecha, hora_compromiso, id_tecnico, unidad, notas_ruta "
                        "FROM ordenes_servicio WHERE id = %s",
                        (self._os_id,)
                    )
                    row = cur.fetchone()
                    if row:
                        fecha_os, hora_os, id_tec, unidad_os, notas_os = row
                        if fecha_os:
                            if hasattr(fecha_os, 'year'):
                                self._dte_fecha.setDate(
                                    QDate(fecha_os.year, fecha_os.month, fecha_os.day)
                                )
                        if hora_os:
                            try:
                                if hasattr(hora_os, 'hour'):
                                    self._dte_hora.setTime(QTime(hora_os.hour, hora_os.minute))
                                elif isinstance(hora_os, str):
                                    parts = hora_os.split(":")
                                    self._dte_hora.setTime(QTime(int(parts[0]), int(parts[1])))
                            except Exception:
                                pass
                        if id_tec:
                            for i in range(self._cmb_tecnico.count()):
                                if self._cmb_tecnico.itemData(i) == id_tec:
                                    self._cmb_tecnico.setCurrentIndex(i)
                                    break
                        if unidad_os:
                            self._inp_unidad.setText(str(unidad_os))
                        if notas_os:
                            self._inp_notas.setText(str(notas_os))
            finally:
                _db_pool.release_connection(conn)
        except Exception as exc:
            logger.warning("EditarActividadDialog: error cargando datos OS=%s: %s",
                           self._os_id, exc)

    # ── Guardar ───────────────────────────────────────────────────────────────
    def _on_save(self) -> None:
        """Guarda los campos de actividad logística en ordenes_servicio."""
        fecha = self._dte_fecha.date().toString("yyyy-MM-dd")
        hora  = self._dte_hora.time().toString("HH:mm")
        id_tec = self._cmb_tecnico.currentData()
        unidad = self._inp_unidad.text().strip()
        notas  = self._inp_notas.text().strip()

        if not _HAS_DB or not _db_pool:
            QMessageBox.warning(self, "Sin BD", "No hay conexión a la base de datos.")
            return

        self._btn_save.setEnabled(False)
        self._btn_save.setText("Guardando…")

        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    # Actualiza sólo los campos de actividad. Se hace un UPDATE parcial
                    # para no afectar ningún otro dato de la OS.
                    cur.execute(
                        """
                        UPDATE ordenes_servicio
                           SET fecha              = %s,
                               hora_compromiso    = %s,
                               id_tecnico         = COALESCE(%s, id_tecnico),
                               unidad             = %s,
                               notas_ruta         = %s,
                               updated_at         = NOW()
                         WHERE id = %s
                        """,
                        (fecha, hora, id_tec, unidad or None, notas or None, self._os_id)
                    )
                conn.commit()
                logger.info("Actividad OS=%s actualizada: fecha=%s hora=%s tec=%s unidad=%s",
                            self._os_id, fecha, hora, id_tec, unidad)
            finally:
                _db_pool.release_connection(conn)
            QMessageBox.information(
                self, "Guardado",
                f"Actividad del folio {self._folio} actualizada correctamente."
            )
            self.accept()
        except Exception as exc:
            logger.error("Error guardando actividad OS=%s: %s", self._os_id, exc)
            QMessageBox.critical(
                self, "Error al guardar",
                f"No se pudo actualizar la actividad:\n{exc}"
            )
        finally:
            self._btn_save.setEnabled(True)
            self._btn_save.setText("💾  Guardar Actividad")


# =============================================================================
# Dashboard Principal
# =============================================================================
class DashboardWidget(QWidget):

    """
    Dashboard principal -- Resumen Operativo de Servicios.
    Diseno macOS Pro con KPI Cards, barra de filtros unificada y tabla de 10 columnas.
    Soporta modo Offline-First (SQLite <-> PostgreSQL).
    """

    # Senales publicas
    os_selected             = pyqtSignal(int)
    os_pdf_requested        = pyqtSignal(int)
    lp_selected             = pyqtSignal(int)
    goto_escaneos           = pyqtSignal(str)
    solicitar_nuevo_formato = pyqtSignal(str)
    navegar_a               = pyqtSignal(str)

    # ── Estilos de botones de acción — constantes de clase para no recrear por fila ──
    _BTN_PDF_STYLE = (
        "QPushButton{background:#F2F2F7;color:#1D1D1F;border:1px solid #D1D1D6;"
        "border-radius:4px;font-size:9pt;font-weight:500;padding:0 8px;min-height:26px;}"
        "QPushButton:hover{background:#E5E5EA;}QPushButton:pressed{background:#D1D1D6;}"
    )
    _BTN_CAPTURAR_STYLE = (
        "QPushButton{background:qlineargradient(x1:0,y1:0,x2:1,y2:0,"
        "stop:0 #1A7F64,stop:1 #0E6E53);color:white;border:none;border-radius:4px;"
        "font-size:8.5pt;font-weight:700;padding:0 10px;min-height:26px;}"
        "QPushButton:hover{background:#145C48;}"
    )
    _BTN_PDF_FINAL_STYLE = (
        "QPushButton{background:qlineargradient(x1:0,y1:0,x2:1,y2:0,"
        "stop:0 #0A5C9E,stop:1 #0869B8);color:white;border:none;border-radius:4px;"
        "font-size:8.5pt;font-weight:700;padding:0 10px;min-height:26px;}"
        "QPushButton:hover{background:#0747A6;}"
    )
    _BTN_DESCARGAR_STYLE = (
        "QPushButton{background:#EBF5FF;color:#007AFF;border:1px solid #B9DBFF;"
        "border-radius:4px;font-size:8.5pt;font-weight:700;padding:0 8px;min-height:26px;}"
        "QPushButton:hover{background:#D0E8FF;}QPushButton:pressed{background:#B9DBFF;}"
    )

    # -- Indices de columna de la QTableWidget (0-based) ----------------------
    # Col 0: Folio
    # Col 1: Fecha

    # Col 2: Cliente
    # Col 3: Sucursal / Planta
    # Col 4: Tecnico Asignado
    # Col 0: Checkbox  Col 1: Folio  Col 2: Fecha  Col 3: Cliente
    # Col 4: Sucursal  Col 5: Técnico  Col 6: Tipo Servicio
    # Col 7: Modalidad  Col 8: Estatus  Col 9: Sync
    # ACCIONES → sub-fila span completo (sin columna dedicada)
    _COL_CHK      = 0   # checkbox de selección múltiple
    _COL_FOLIO    = 1
    _COL_FECHA    = 2
    _COL_CLIENTE  = 3
    _COL_SUCURSAL = 4
    _COL_TECNICO  = 5
    _COL_SERVICIO = 6
    _COL_MODAL    = 7
    _COL_ESTADO   = 8
    _COL_SYNC     = 9
    _COL_ACCIONES = 10  # columna dedicada de botones de acción (220px fijo)
    _W_SYNC       = 100
    _W_ACCIONES   = 220   # ancho útil para botones (contenido)
    _ITEM_PAD_H   = 14    # = padding horizontal de QTreeWidget::item en el QSS

    def __init__(self, title: str = "Dashboard", rbac_filter: Optional[str] = None, parent=None):
        super().__init__(parent)
        self._title        = title
        self._rbac_filter  = rbac_filter
        self._sync_worker: Optional[_SyncWorker]       = None
        self._loader:      Optional[_DashboardLoader]   = None
        self._all_loaded_rows: list = []
        self._date_preset  = "mes"
        self._filters_loaded = False

        # ── Caché en memoria para navegación instantánea entre pestañas ──────
        # Estructura: {'kpis': (total, proceso, cerrados, fisicos),
        #              'rows': [...], 'filters': [...], 'preset': str}
        self._data_cache: dict = {}
        self._cache_valid: bool = False

        self._build_ui()
        # Primera carga: incluir filtros (load_filters=True)
        QTimer.singleShot(200, lambda: self._async_refresh(load_filters=True))

        # Auto-sync silencioso en background
        self._auto_sync_timer = QTimer(self)
        self._auto_sync_timer.setInterval(_SYNC_INTERVAL_MS)
        self._auto_sync_timer.timeout.connect(self._auto_sync)
        self._auto_sync_timer.start()

    # =========================================================================
    # Construccion de la interfaz
    # =========================================================================

    def _build_ui(self) -> None:
        self.setStyleSheet(f"background: {_BG};")

        root_lay = QVBoxLayout(self)
        root_lay.setContentsMargins(0, 0, 0, 0)
        root_lay.setSpacing(0)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("background: transparent; border: none;")
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        inner = QWidget()
        inner.setStyleSheet(f"background: {_BG};")
        scroll.setWidget(inner)

        self._inner_lay = QVBoxLayout(inner)
        self._inner_lay.setContentsMargins(28, 24, 28, 24)
        self._inner_lay.setSpacing(20)

        # 1. Header de bienvenida
        self._inner_lay.addWidget(self._build_header())

        # 2. KPI Cards (4 tarjetas) — SIEMPRE ENCIMA DE LOS FILTROS
        kpi_row = QHBoxLayout()
        kpi_row.setSpacing(16)
        self._card_total     = KPICard("Total Periodo",      "--", subtitle="del periodo seleccionado")
        self._card_proceso   = KPICard("En Proceso",         "--", subtitle="activos actualmente",   value_color="#E65100")
        self._card_cerrados  = KPICard("Cerrados",           "--", subtitle="finalizados",            value_color="#1B5E20")
        self._card_fisicos   = KPICard("Formatos Fisicos",   "--", subtitle="pendientes de escanear", value_color="#4A148C")
        for card in [self._card_total, self._card_proceso,
                     self._card_cerrados, self._card_fisicos]:
            kpi_row.addWidget(card)
        self._inner_lay.addLayout(kpi_row)

        # 3. Barra de filtros — DEBAJO DE LOS KPIS, NUNCA ENCIMADA
        self._inner_lay.addSpacing(4)
        self._inner_lay.addWidget(self._build_filter_bar())

        # 4. Barra de estado de conexion / sync
        self._inner_lay.addWidget(self._build_sync_bar())

        # 5. Tabla principal
        self._inner_lay.addWidget(self._build_table_panel(), stretch=1)

        root_lay.addWidget(scroll)

    # -------------------------------------------------------------------------
    # Header de bienvenida
    # -------------------------------------------------------------------------
    def _build_header(self) -> QWidget:
        """Header con titulo del modulo y botones de accion principales."""
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)

        # Columna izquierda: titulo
        col = QVBoxLayout()
        col.setSpacing(2)

        lbl_title = QLabel("Resumen Operativo de Servicios")
        lbl_title.setStyleSheet(
            "font-size: 20px; font-weight: 700; color: #1D1D1F; "
            "letter-spacing: -0.3px; background: transparent;"
        )
        col.addWidget(lbl_title)

        sub_text = "Órdenes de Servicio, Remisiones, Revisiones y Levantamientos"
        if self._rbac_filter == "calibrador":
            sub_text = "OS con componente de Calibración asignadas o completadas."
        elif self._rbac_filter == "inspector":
            sub_text = "OS con componente de Inspección asignadas o completadas."
        lbl_sub = QLabel(sub_text)
        lbl_sub.setStyleSheet(
            "font-size: 13px; color: #86868B; background: transparent;"
        )
        col.addWidget(lbl_sub)

        lay.addLayout(col)
        lay.addStretch()

        # Botones de accion en la cabecera
        role = ""
        if _HAS_SESSION and session and session.is_authenticated:
            role = getattr(session, "role", "")

        btn_refresh_header = QPushButton("⟳  Actualizar")
        btn_refresh_header.setObjectName("btn_refresh_header")
        btn_refresh_header.setFixedHeight(36)
        btn_refresh_header.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_refresh_header.setStyleSheet("""
            QPushButton {
                background: #FFFFFF;
                color: #1D1D1F;
                border: 1px solid #D1D1D6;
                border-radius: 8px;
                font-size: 13px;
                font-weight: 500;
                padding: 0 14px;
            }
            QPushButton:hover { background: #F2F2F7; border-color: #86868B; }
            QPushButton:pressed { background: #E5E5EA; }
        """)
        btn_refresh_header.clicked.connect(self._on_refresh_clicked)
        lay.addWidget(btn_refresh_header)

        btn_sync_header = QPushButton("⇅  Sincronizar")
        btn_sync_header.setObjectName("btn_sync_header")
        btn_sync_header.setFixedHeight(36)
        btn_sync_header.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_sync_header.setStyleSheet("""
            QPushButton {
                background: #FFFFFF;
                color: #1D1D1F;
                border: 1px solid #D1D1D6;
                border-radius: 8px;
                font-size: 13px;
                font-weight: 500;
                padding: 0 16px;
            }
            QPushButton:hover { background: #F2F2F7; border-color: #86868B; }
            QPushButton:pressed { background: #E5E5EA; }
        """)
        btn_sync_header.clicked.connect(self._on_sync_clicked)
        lay.addWidget(btn_sync_header)

        # Boton primario [+ Nuevo Documento] con menu desplegable
        if role in ("admin", "logistica", ""):
            self.btn_nueva_os = QPushButton("+ Nuevo Documento")
            self.btn_nueva_os.setFixedHeight(36)
            self.btn_nueva_os.setCursor(Qt.CursorShape.PointingHandCursor)
            self.btn_nueva_os.setStyleSheet("""
                QPushButton {
                    background: #B81D24;
                    color: #FFFFFF;
                    border: none;
                    border-radius: 8px;
                    font-size: 13px;
                    font-weight: 600;
                    padding: 0 16px;
                }
                QPushButton:hover { background: #9E161C; }
                QPushButton::menu-indicator { image: none; width: 0px; }
            """)
            menu = QMenu(self.btn_nueva_os)
            menu.setStyleSheet("""
                QMenu {
                    background: #FFFFFF;
                    border: 1px solid #E5E5EA;
                    border-radius: 8px;
                    padding: 4px;
                    font-size: 13px;
                }
                QMenu::item {
                    padding: 8px 16px;
                    border-radius: 5px;
                    color: #1D1D1F;
                }
                QMenu::item:selected { background: #F5F5F7; }
                QMenu::separator { height: 1px; background: #E5E5EA; margin: 3px 8px; }
            """)
            act_os  = menu.addAction("Orden de Servicio (OS)")
            act_rma = menu.addAction("Remisión (RMA)")
            act_re  = menu.addAction("Revisión (RE)")
            menu.addSeparator()
            act_lp  = menu.addAction("Levantamiento de Planta (LP)")
            act_os.triggered.connect(lambda: self.solicitar_nuevo_formato.emit("OS"))
            act_rma.triggered.connect(lambda: self.solicitar_nuevo_formato.emit("RMA"))
            act_re.triggered.connect(lambda: self.solicitar_nuevo_formato.emit("RE"))
            act_lp.triggered.connect(lambda: self.solicitar_nuevo_formato.emit("LP"))
            self.btn_nueva_os.setMenu(menu)
            lay.addWidget(self.btn_nueva_os)

        return w

    # -------------------------------------------------------------------------
    # Barra de filtros unificada (Segmented Toolbar)
    # -------------------------------------------------------------------------
    def _build_filter_bar(self) -> QFrame:
        """Barra de filtros en una sola fila: periodo, tecnico, estado, buscador."""
        bar = QFrame()
        bar.setObjectName("filter_bar")
        bar.setStyleSheet("""
            QFrame#filter_bar {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 10px;
            }
        """)
        sh = QGraphicsDropShadowEffect(bar)
        sh.setBlurRadius(8)
        sh.setOffset(0, 1)
        sh.setColor(QColor(0, 0, 0, 10))
        bar.setGraphicsEffect(sh)

        lay = QHBoxLayout(bar)
        lay.setContentsMargins(12, 8, 12, 8)
        lay.setSpacing(10)

        # -- Segmented Control de periodos ------------------------------------
        seg = QFrame()
        seg.setObjectName("segmented_control")
        seg.setStyleSheet(
            "background: #EBEBED; border-radius: 8px; border: none; padding: 2px;"
        )
        seg_lay = QHBoxLayout(seg)
        seg_lay.setContentsMargins(2, 2, 2, 2)
        seg_lay.setSpacing(2)

        self._btn_grp_preset = QButtonGroup(self)
        self._btn_grp_preset.setExclusive(True)

        _presets = [("Hoy", "hoy"), ("Esta Semana", "semana"),
                    ("Este Mes", "mes"), ("Todo", "todo")]

        _seg_btn_style = """
            QPushButton {
                background: transparent;
                color: #6E6E73;
                border: none;
                border-radius: 6px;
                font-size: 12px;
                font-weight: 500;
                padding: 0 12px;
                min-height: 28px;
            }
            QPushButton:checked {
                background: #FFFFFF;
                color: #1D1D1F;
                font-weight: 600;
            }
            QPushButton:hover:!checked { color: #1D1D1F; }
        """

        for lbl_txt, key in _presets:
            b = QPushButton(lbl_txt)
            b.setObjectName("seg_btn")
            b.setCheckable(True)
            b.setFixedHeight(28)
            b.setStyleSheet(_seg_btn_style)
            if key == "mes":
                b.setChecked(True)
            b.clicked.connect(lambda _, k=key: self._on_preset_clicked(k))
            self._btn_grp_preset.addButton(b)
            seg_lay.addWidget(b)

        lay.addWidget(seg)

        # -- Fechas personalizadas (ocultas por defecto) ----------------------
        self._widget_custom_dates = QWidget()
        self._widget_custom_dates.setStyleSheet("background: transparent;")
        cd = QHBoxLayout(self._widget_custom_dates)
        cd.setContentsMargins(0, 0, 0, 0)
        cd.setSpacing(4)

        _dte_style = (
            "background: #FFFFFF; border: 1px solid #D1D1D6; "
            "border-radius: 8px; padding: 0 8px; font-size: 12px; color: #1D1D1F;"
        )
        self._dte_desde = QDateEdit()
        self._dte_desde.setCalendarPopup(True)
        self._dte_desde.setDate(QDate.currentDate().addDays(-30))
        self._dte_desde.setDisplayFormat("dd/MM/yy")
        self._dte_desde.setFixedHeight(36)
        self._dte_desde.setStyleSheet(_dte_style)
        self._dte_desde.dateChanged.connect(lambda _: self._on_filter_changed())

        self._dte_hasta = QDateEdit()
        self._dte_hasta.setCalendarPopup(True)
        self._dte_hasta.setDate(QDate.currentDate())
        self._dte_hasta.setDisplayFormat("dd/MM/yy")
        self._dte_hasta.setFixedHeight(36)
        self._dte_hasta.setStyleSheet(_dte_style)
        self._dte_hasta.dateChanged.connect(lambda _: self._on_filter_changed())

        lbl_de = QLabel("De:")
        lbl_de.setStyleSheet("font-size: 12px; color: #86868B; background: transparent;")
        lbl_a  = QLabel("a:")
        lbl_a.setStyleSheet("font-size: 12px; color: #86868B; background: transparent;")

        cd.addWidget(lbl_de)
        cd.addWidget(self._dte_desde)
        cd.addWidget(lbl_a)
        cd.addWidget(self._dte_hasta)
        self._widget_custom_dates.setVisible(False)
        lay.addWidget(self._widget_custom_dates)

        # ── Separador vertical ─────────────────────────────────────────────
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.VLine)
        sep.setStyleSheet("background: #E5E5EA; border: none; max-width: 1px;")
        lay.addWidget(sep)

        # -- Filtro de Tecnicos -----------------------------------------------
        _combo_style = (
            "background: #FFFFFF; border: 1px solid #D1D1D6; border-radius: 8px; "
            "padding-left: 10px; font-size: 13px; color: #1D1D1F; min-height: 36px;"
        )

        # ── Filtro de Modalidad (NUEVO) — Todas / Solo Digitales / Solo Físicos ──
        self._combo_modal_bar = QComboBox()
        self._combo_modal_bar.setFixedHeight(36)
        self._combo_modal_bar.setMinimumWidth(165)
        self._combo_modal_bar.setToolTip("")
        self._combo_modal_bar.setStyleSheet(_combo_style)
        for texto, valor in [
            ("Todas las Modalidades", ""),
            ("Solo Digitales",        "Digital"),
            ("Solo Físicos",          "Fisico"),
        ]:
            self._combo_modal_bar.addItem(texto, valor)
        self._combo_modal_bar.currentIndexChanged.connect(self._on_filter_changed)
        lay.addWidget(self._combo_modal_bar)

        # ── Filtro de Técnicos ───────────────────────────────────────────────
        self._combo_tec_bar = QComboBox()
        self._combo_tec_bar.setFixedHeight(36)
        self._combo_tec_bar.setMinimumWidth(150)
        self._combo_tec_bar.setToolTip("")
        self._combo_tec_bar.setStyleSheet(_combo_style)
        self._combo_tec_bar.currentIndexChanged.connect(self._on_filter_changed)
        lay.addWidget(self._combo_tec_bar)

        # Ocultar si el usuario logueado es un técnico de campo
        _is_field_tech = False
        if _HAS_SESSION and session and session.is_authenticated:
            _tech_roles = {"servicio", "calibrador", "inspector"}
            _is_field_tech = bool(set(getattr(session, "roles", []) or []) & _tech_roles)
        if _is_field_tech:
            self._combo_tec_bar.setVisible(False)

        # ── Filtro de Estado ─────────────────────────────────────────────────
        self._combo_estado_global = QComboBox()
        self._combo_estado_global.setFixedHeight(36)
        self._combo_estado_global.setMinimumWidth(150)
        self._combo_estado_global.setToolTip("")
        self._combo_estado_global.setStyleSheet(_combo_style)
        for texto, valor in [
            ("Todos los Estados", ""),
            ("En Proceso",        "PROCESO"),
            ("Completada",        "COMPLETADA"),
            ("Escaneada",         "ESCANEADA"),
            ("Cancelada",         "CANCELADA"),
        ]:
            self._combo_estado_global.addItem(texto, valor)
        self._combo_estado_global.currentIndexChanged.connect(self._on_filter_changed)
        lay.addWidget(self._combo_estado_global)

        # -- Buscador rapido --------------------------------------------------
        self._search_global = QLineEdit()
        self._search_global.setPlaceholderText(
            "Buscar por folio, cliente, sucursal o técnico..."
        )
        self._search_global.setFixedHeight(36)
        self._search_global.setStyleSheet("""
            QLineEdit {
                background: #FFFFFF;
                border: 1px solid #D1D1D6;
                border-radius: 8px;
                padding: 0 12px;
                font-size: 13px;
                color: #1D1D1F;
            }
            QLineEdit:focus {
                background: #FFFFFF;
                border: 1px solid #007AFF;
            }
        """)
        self._search_global.textChanged.connect(self._on_search_changed)
        lay.addWidget(self._search_global, stretch=1)

        return bar

    # -------------------------------------------------------------------------
    # Barra de estado de conexion / sync
    # -------------------------------------------------------------------------
    def _build_sync_bar(self) -> QFrame:
        """Barra compacta de estado de conexion y controles de sync."""
        bar = QFrame()
        bar.setObjectName("sync_bar")
        bar.setStyleSheet("""
            QFrame#sync_bar {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 8px;
            }
        """)

        lay = QHBoxLayout(bar)
        lay.setContentsMargins(14, 7, 14, 7)
        lay.setSpacing(8)

        self._lbl_conn_mode = QLabel()
        self._lbl_conn_mode.setFixedHeight(20)
        self._lbl_conn_mode.setStyleSheet(
            "font-size: 9pt; font-weight: 500; background: transparent;"
        )
        self._update_conn_badge()
        lay.addWidget(self._lbl_conn_mode)

        self._lbl_pending_count = QLabel()
        self._lbl_pending_count.setStyleSheet(
            "font-size: 9pt; color: #92400E; font-weight: 600; background: transparent;"
        )
        lay.addWidget(self._lbl_pending_count)
        self._refresh_pending_count()

        # ── Indicador de carga asíncrona ────────────────────────────────────
        self._lbl_loading = QLabel("⟳ Cargando...")
        self._lbl_loading.setStyleSheet(
            "font-size: 9pt; color: #6B7280; font-style: italic; background: transparent;"
        )
        self._lbl_loading.setVisible(False)
        lay.addWidget(self._lbl_loading)

        lay.addStretch()
        return bar

    # -------------------------------------------------------------------------
    # Panel de tabla principal
    # -------------------------------------------------------------------------
    def _build_table_panel(self) -> QFrame:
        """Panel con cabecera de tabla y QTreeWidget expandible por lotes."""
        panel = QFrame()
        panel.setObjectName("table_panel")
        panel.setStyleSheet("""
            QFrame#table_panel {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 10px;
            }
        """)
        sh = QGraphicsDropShadowEffect(panel)
        sh.setBlurRadius(12)
        sh.setOffset(0, 2)
        sh.setColor(QColor(0, 0, 0, 10))
        panel.setGraphicsEffect(sh)

        lay = QVBoxLayout(panel)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # -- Cabecera del panel -----------------------------------------------
        thead = QWidget()
        thead.setStyleSheet(
            "background: #FFFFFF; border-radius: 10px 10px 0 0; "
            "border-bottom: 1px solid #E5E5EA;"
        )
        thead_lay = QHBoxLayout(thead)
        thead_lay.setContentsMargins(20, 12, 16, 12)
        thead_lay.setSpacing(10)

        lbl_tit = QLabel("Registros del Periodo")
        lbl_tit.setStyleSheet(
            "font-size: 12pt; font-weight: 600; color: #1D1D1F; "
            "background: transparent; letter-spacing: -0.2px;"
        )
        thead_lay.addWidget(lbl_tit)
        thead_lay.addStretch()

        # Botón Descargar Selección (.zip / .rar)
        self._btn_descargar_zip = QPushButton("📦 Descargar Selección (.zip / .rar)")
        self._btn_descargar_zip.setFixedHeight(28)
        self._btn_descargar_zip.setEnabled(False)
        self._btn_descargar_zip.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_descargar_zip.setStyleSheet("""
            QPushButton {
                background: #F2F2F7;
                color: #8E8E93;
                border: 1px solid #D1D1D6;
                border-radius: 6px;
                font-size: 9pt;
                font-weight: 600;
                padding: 0 12px;
            }
            QPushButton:enabled {
                background: #007AFF;
                color: #FFFFFF;
                border: none;
            }
            QPushButton:enabled:hover {
                background: #0062CC;
            }
            QPushButton:disabled {
                background: #F2F2F7;
                color: #8E8E93;
                border: 1px solid #D1D1D6;
            }
        """)
        self._btn_descargar_zip.clicked.connect(self._on_descargar_seleccion_zip)
        thead_lay.addWidget(self._btn_descargar_zip)

        # Boton eliminar seleccionados (solo admin)
        self._btn_eliminar_sel = QPushButton("Eliminar seleccionados")
        self._btn_eliminar_sel.setVisible(False)
        self._btn_eliminar_sel.setFixedHeight(28)
        self._btn_eliminar_sel.setStyleSheet(f"""
            QPushButton {{
                background: {_RED};
                color: white;
                border: none;
                border-radius: 6px;
                font-size: 9pt;
                font-weight: 600;
                padding: 0 12px;
            }}
            QPushButton:hover {{ background: {_RED2}; }}
        """)
        self._btn_eliminar_sel.clicked.connect(self._on_delete_selected)
        if self._is_admin():
            thead_lay.addWidget(self._btn_eliminar_sel)

        btn_ver_todas = QPushButton("Ver todas  ->")
        btn_ver_todas.setStyleSheet("""
            QPushButton {
                background: transparent;
                color: #007AFF;
                border: none;
                font-size: 9pt;
                font-weight: 500;
                padding: 0 6px;
            }
            QPushButton:hover { color: #0062CC; }
        """)
        btn_ver_todas.clicked.connect(lambda: self._navigate_to("buscar_os"))
        thead_lay.addWidget(btn_ver_todas)

        lay.addWidget(thead)

        # -- QTreeWidget (reemplaza QTableWidget) -----------------------------
        self._table = QTreeWidget()
        self._configure_table(self._table)
        lay.addWidget(self._table)

        return panel

    # =========================================================================
    # Configuracion del QTreeWidget (mantiene columnas y estilos originales)
    # =========================================================================
    def _configure_table(self, table: QTreeWidget) -> None:
        """Configura el QTreeWidget con 11 columnas estilo macOS.
        Col 9 (SYNC, 100px) solo aloja la píldora de sincronización y
        col 10 (ACCIONES, 220px) aloja el QHBoxLayout de botones, tanto en
        filas padre de lote como en filas hijas / individuales."""
        cols = [
            "",                  # 0  - checkbox de selección
            "FOLIO OS",          # 1  - bold rojo / resumen lote
            "FECHA",             # 2  - 95px fijo
            "CLIENTE",           # 3  - Stretch (espacio central)
            "SUCURSAL / PLANTA", # 4  - Stretch secundario
            "TÉCNICO",           # 5  - 130px fijo
            "TIPO SERVICIO",     # 6  - badge, 130px
            "MODALIDAD",         # 7  - badge, 100px
            "ESTATUS",           # 8  - badge, 100px
            "SYNC",              # 9  - badge, 100px fijo
            "ACCIONES",          # 10 - botones, 220px fijo
        ]
        table.setColumnCount(len(cols))
        table.setHeaderLabels(cols)

        # Checkbox maestro en la cabecera de la columna 0
        self._chk_all = QCheckBox()
        self._chk_all.setToolTip("Seleccionar / deseleccionar todos los grupos")
        self._chk_all.setStyleSheet("margin-left: 8px;")
        self._chk_all.stateChanged.connect(self._on_chk_all_changed)

        table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setAlternatingRowColors(False)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        table.header().setHighlightSections(False)
        table.setRootIsDecorated(True)
        table.setIndentation(20)
        table.setUniformRowHeights(False)
        table.setAnimated(True)
        table.setExpandsOnDoubleClick(False)

        # Altura de cabecera: 40px
        table.header().setFixedHeight(40)
        table.header().setDefaultAlignment(
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter
        )

        # ── BLOQUEO DEFINITIVO de scroll horizontal: 100% ancho sin columna extra ──
        table.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        table.setSizeAdjustPolicy(QAbstractScrollArea.SizeAdjustPolicy.AdjustToContents)
        header = table.header()
        header.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        header.setStretchLastSection(False)

        # Col 0 — Selector / Check (fijo 32px)
        header.setSectionResizeMode(self._COL_CHK,      QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_CHK, 32)

        # Col 1 — Folio OS (fijo 140px)
        header.setSectionResizeMode(self._COL_FOLIO,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_FOLIO, 140)

        # Col 2 — Fecha (fijo 95px)
        header.setSectionResizeMode(self._COL_FECHA,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_FECHA, 95)

        # Col 3 — Cliente: absorbe todo el espacio dinámico central (Stretch)
        header.setSectionResizeMode(self._COL_CLIENTE,  QHeaderView.ResizeMode.Stretch)

        # Col 4 — Sucursal / Planta: Stretch secundario (comparte con Cliente)
        header.setSectionResizeMode(self._COL_SUCURSAL, QHeaderView.ResizeMode.Stretch)

        # Col 5 — Técnico (fijo 130px)
        header.setSectionResizeMode(self._COL_TECNICO,  QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_TECNICO, 130)

        # Col 6 — Tipo Servicio / badge (fijo 130px)
        header.setSectionResizeMode(self._COL_SERVICIO, QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_SERVICIO, 130)

        # Col 7 — Modalidad / badge (fijo 100px)
        header.setSectionResizeMode(self._COL_MODAL,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_MODAL, 100)

        # Col 8 — Estatus / badge (fijo 100px)
        header.setSectionResizeMode(self._COL_ESTADO,   QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_ESTADO, 100)

        # Col 9 — SYNC / badge (fijo 100px) — solo la píldora ✓✓
        header.setSectionResizeMode(self._COL_SYNC,     QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_SYNC, self._W_SYNC)

        # Col 10 — ACCIONES (fijo) — 220px útiles + padding del item (QSS
        # 'padding: 0 14px' desplaza los item-widgets 14px a la derecha).
        header.setSectionResizeMode(self._COL_ACCIONES, QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_ACCIONES, self._W_ACCIONES + 2 * self._ITEM_PAD_H)

        # Delegates para columnas de estado, modalidad, servicio y sync
        self._status_delegate = StatusBadgeDelegate(table)
        table.setItemDelegateForColumn(self._COL_ESTADO,   self._status_delegate)
        table.setItemDelegateForColumn(self._COL_MODAL,    self._status_delegate)
        table.setItemDelegateForColumn(self._COL_SERVICIO, self._status_delegate)

        self._sync_delegate = SyncCheckDelegate(table)
        table.setItemDelegateForColumn(self._COL_SYNC, self._sync_delegate)

        table.customContextMenuRequested.connect(self._on_table_context_menu)
        table.itemDoubleClicked.connect(self._on_tree_item_double_click_full)

        # Colocar el checkbox maestro dentro de la cabecera col 0
        QTimer.singleShot(0, lambda: self._place_header_checkbox(table))

        # Estilo del QTreeWidget (macOS UI HIG)
        table.setStyleSheet("""
            QTreeWidget {
                background: #FFFFFF;
                border: none;
                border-radius: 0 0 10px 10px;
                font-size: 13px;
                color: #1D1D1F;
                outline: none;
                selection-background-color: #F2F2F7;
                selection-color: #1D1D1F;
            }
            QTreeWidget::item {
                padding: 0px 14px;
                border-bottom: 1px solid #E5E5EA;
                min-height: 52px;
                height: 52px;
                font-size: 13px;
                font-weight: 400;
                color: #1D1D1F;
            }
            QTreeWidget::item:hover {
                background: #F9F9FB;
            }
            QTreeWidget::item:selected {
                background: #F2F2F7;
                color: #1D1D1F;
            }
            QHeaderView::section {
                background: #FAFAFC;
                color: #6E6E73;
                font-size: 11px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                padding: 0 14px;
                border: none;
                border-bottom: 1px solid #E5E5EA;
                height: 40px;
                min-height: 40px;
            }
            QHeaderView::section:hover {
                background: #F5F5F7;
            }
        """)


    # =========================================================================
    # Filtros y datos de periodo
    # =========================================================================
    def _get_date_range(self) -> tuple:
        """Retorna (fecha_desde, fecha_hasta) segun el preset activo."""
        today = date.today()
        if self._date_preset == "hoy":
            return today, today
        elif self._date_preset == "semana":
            start = today - timedelta(days=today.weekday())
            return start, today
        elif self._date_preset == "mes":
            import calendar
            start = today.replace(day=1)
            last_day = calendar.monthrange(today.year, today.month)[1]
            return start, today.replace(day=last_day)
        elif self._date_preset == "custom":
            d_from = getattr(self, "_dte_desde", None)
            d_to   = getattr(self, "_dte_hasta", None)
            if d_from and d_to:
                return d_from.date().toPyDate(), d_to.date().toPyDate()
        return None, None  # sin filtro de fecha (todo)

    def _on_preset_clicked(self, key: str) -> None:
        self._date_preset = key
        self._widget_custom_dates.setVisible(key == "custom")
        self._on_filter_changed()

    def _on_filter_changed(self) -> None:
        # Invalidar caché: el usuario cambió filtros, necesita datos frescos
        self._cache_valid = False
        self._data_cache.clear()
        self._async_refresh(load_filters=False, force=True)

    def _on_search_changed(self, text: str = None) -> None:
        if text is None:
            if hasattr(self, "_search_global"):
                text = self._search_global.text()
            elif hasattr(self, "search_input"):
                text = self.search_input.text()
        text = (text or "").strip()

        # Aplicar filtro visual sobre las filas ya cargadas
        self._apply_search_filter()

        if not text:
            return

        # ── Si no hay coincidencias en los datos ya cargados, relanzar la
        # consulta SQL con ILIKE para superar el LIMIT 200 ─────────────────
        # Ejemplo: OS-26-688 podría estar fuera del top-200 por fecha/consecutivo.
        root = self._table.invisibleRootItem()
        any_visible = any(
            not root.child(i).isHidden()
            for i in range(root.childCount())
        )
        if not any_visible:
            QTimer.singleShot(0, lambda t=text: self._search_refresh_from_db(t))

    def _search_refresh_from_db(self, search_text: str) -> None:
        """Lanza una query SQL con ILIKE cuando el texto no se encontró en el
        caché local de 500 filas. Busca en folio, cliente y sucursal.

        IMPORTANTE: respeta el filtro de técnico activo en el combo. Si hay
        un técnico seleccionado, la query SQL agrega 'AND os.id_tecnico = %s'
        para evitar mezclar órdenes de técnicos distintos con el mismo cliente.
        """
        if not search_text:
            return
        try:
            conn = _db_pool.get_connection()
            like_val = f"%{search_text}%"

            # ── Respetar filtro de técnico activo en el combo ───────────────────
            tec_id_filter = None
            if hasattr(self, "_combo_tec_bar"):
                tec_id_filter = self._combo_tec_bar.currentData()  # int o None

            tec_clause = "AND os.id_tecnico = %s" if tec_id_filter is not None else ""

            params_list = [like_val, like_val, like_val]
            if tec_id_filter is not None:
                params_list.append(tec_id_filter)

            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT DISTINCT ON (os.folio_os)
                        os.folio_os, os.fecha::text,
                        cl.razon_social,
                        COALESCE(
                            NULLIF(suc.nombre_sucursal, ''),
                            NULLIF(os.ubicacion, ''),
                            ''
                        ),
                        tc.nombre_completo,
                        COALESCE(ts.nombre, os.tipo_servicio),
                        os.modalidad,
                        os.estado,
                        os.id,
                        os.id_lote,
                        EXISTS(SELECT 1 FROM adjuntos_os WHERE id_os = os.id) AS tiene_adjunto,
                        COALESCE(os.sync_status, 'SYNCED') AS sync_status,
                        os.rango_lote,
                        COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status
                    FROM ordenes_servicio os
                    LEFT JOIN cat_clientes       cl  ON os.id_cliente       = cl.id
                    LEFT JOIN cat_tecnicos       tc  ON os.id_tecnico       = tc.id
                    LEFT JOIN cat_tipo_servicio  ts  ON os.id_tipo_servicio = ts.id
                    LEFT JOIN cliente_sucursales suc ON os.sucursal_id      = suc.id
                    WHERE (
                        os.folio_os          ILIKE %s OR
                        cl.razon_social      ILIKE %s OR
                        suc.nombre_sucursal  ILIKE %s
                    )
                    {tec_clause}
                    ORDER BY os.folio_os DESC
                    LIMIT 100
                    """,
                    params_list,
                )
                rows = cur.fetchall()
            conn.commit()
            _db_pool.release_connection(conn)

            if rows:
                # Combinar con filas existentes (sin duplicados) y refrescar tabla
                existing_folios = {
                    self._table.invisibleRootItem().child(i)
                       .text(self._COL_FOLIO).strip()
                    for i in range(self._table.invisibleRootItem().childCount())
                }
                new_rows = [r for r in rows if r[0] not in existing_folios]
                if new_rows:
                    combined = list(self._all_loaded_rows) + list(new_rows)
                    self._all_loaded_rows = combined
                    self._fill_table_rows(combined)
                    self._apply_search_filter()
        except Exception as exc:
            import traceback as _tb
            _tb.print_exc()
            logger.warning("[search_refresh_from_db] Error: %s", exc)


    # =========================================================================
    # Badges de conexion
    # =========================================================================
    def _update_conn_badge(self) -> None:
        if not hasattr(self, "_lbl_conn_mode"):
            return
        if _HAS_SYNC and _sync_manager and _sync_manager.is_online():
            self._lbl_conn_mode.setText("  Conectado -- PostgreSQL")
            self._lbl_conn_mode.setStyleSheet(
                "font-size: 9pt; font-weight: 500; color: #16A34A; background: transparent;"
            )
        else:
            self._lbl_conn_mode.setText("  Offline -- SQLite Local")
            self._lbl_conn_mode.setStyleSheet(
                "font-size: 9pt; font-weight: 500; color: #92400E; background: transparent;"
            )

    def _refresh_pending_count(self) -> None:
        if not hasattr(self, "_lbl_pending_count"):
            return
        if _HAS_SYNC and _sync_manager:
            n = _sync_manager.get_pending_count()
            if n > 0:
                self._lbl_pending_count.setText(f"  {n} registro(s) sin sincronizar")
                self._lbl_pending_count.setVisible(True)
            else:
                self._lbl_pending_count.setText("")
                self._lbl_pending_count.setVisible(False)
        else:
            self._lbl_pending_count.setVisible(False)

    # =========================================================================
    # Sincronizacion
    # =========================================================================
    def _on_download_assignments(self) -> None:
        if not _HAS_SYNC or _sync_manager is None:
            QMessageBox.information(self, "Sin Sync", "El modulo de sincronizacion no esta disponible.")
            return
        if not _sync_manager.is_online():
            QMessageBox.warning(self, "Sin Conexion",
                                "No hay conexion al servidor.\n"
                                "Conectate a la red de oficina e intenta de nuevo.")
            return

        id_tec = None
        if _HAS_SESSION and session and session.is_authenticated:
            id_tec = session.id_tecnico

        self._btn_download.setEnabled(False)
        self._btn_download.setText("Descargando...")

        try:
            from PyQt6.QtWidgets import QApplication
            QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
            n = _sync_manager.download_assignments(id_tecnico=id_tec)
            QApplication.restoreOverrideCursor()
            QMessageBox.information(
                self, "Descarga Completada",
                f"Se descargaron/actualizaron {n} ordenes de servicio\n"
                "y los catalogos al dispositivo local."
            )
            self._refresh_pending_count()
            self.refresh()
        except Exception as exc:
            try:
                from PyQt6.QtWidgets import QApplication
                QApplication.restoreOverrideCursor()
            except Exception:
                pass
            QMessageBox.critical(self, "Error", f"Error al descargar:\n{exc}")
        finally:
            self._btn_download.setEnabled(True)
            self._btn_download.setText("Descargar Asignaciones")

    def _on_refresh_clicked(self) -> None:
        """Fuerza la recarga directa desde PostgreSQL/BD central e invalida la caché en memoria."""
        self._cache_valid = False
        self._data_cache.clear()
        self._refresh_pending_count()
        self._update_conn_badge()
        self._async_refresh(load_filters=False, force=True)

    def _on_sync_clicked(self) -> None:
        if not _HAS_SYNC or _sync_manager is None:
            self._on_refresh_clicked()
            return
        if not _sync_manager.is_online():
            QMessageBox.warning(self, "Sin Conexion",
                                "No hay conexion al servidor.\n"
                                "Conectate a la red de oficina e intenta de nuevo.")
            return

        pending = _sync_manager.get_pending_count()
        if pending == 0:
            # En vez de solo avisar "no hay pendientes", refrescar PostgreSQL de inmediato
            self._cache_valid = False
            self._data_cache.clear()
            self._refresh_pending_count()
            self._update_conn_badge()
            self._async_refresh(load_filters=False, force=True)
            QMessageBox.information(
                self, "Sincronización y Actualización",
                "No hay registros locales pendientes de sincronizar.\n"
                "Se ha consultado y actualizado la lista de órdenes directamente desde PostgreSQL."
            )
            return

        self._btn_sync.setEnabled(False)
        self._btn_sync.setText("Sincronizando...")

        self._progress_dlg = QProgressDialog(
            "Sincronizando registros con el servidor...", "Cancelar", 0, pending, self
        )
        self._progress_dlg.setWindowTitle("Sincronizacion")
        self._progress_dlg.setWindowModality(Qt.WindowModality.WindowModal)
        self._progress_dlg.setAutoClose(True)
        self._progress_dlg.show()

        self._sync_worker = _SyncWorker()
        self._sync_worker.progress.connect(self._on_sync_progress)
        self._sync_worker.finished_ok.connect(self._on_sync_done)
        self._sync_worker.finished_err.connect(self._on_sync_error)
        self._sync_worker.start()

    def _on_sync_progress(self, current: int, total: int, folio: str) -> None:
        if hasattr(self, "_progress_dlg") and self._progress_dlg:
            self._progress_dlg.setValue(current)
            self._progress_dlg.setLabelText(f"Sincronizando: {folio} ({current}/{total})")

    def _on_sync_done(self, n: int) -> None:
        if hasattr(self, "_progress_dlg") and self._progress_dlg:
            self._progress_dlg.close()
        self._btn_sync.setEnabled(True)
        self._btn_sync.setText("Sincronizar")
        self._cache_valid = False
        self._data_cache.clear()
        self._refresh_pending_count()
        QTimer.singleShot(300, lambda: self._async_refresh(load_filters=False, force=True))
        QMessageBox.information(
            self, "Sincronizacion Completada",
            f"{n} registro(s) sincronizado(s) con el servidor central."
        )

    def _on_sync_error(self, msg: str) -> None:
        if hasattr(self, "_progress_dlg") and self._progress_dlg:
            self._progress_dlg.close()
        self._btn_sync.setEnabled(True)
        self._btn_sync.setText("Sincronizar")
        QMessageBox.critical(self, "Error de Sincronizacion", f"Error:\n{msg}")

    def _auto_sync(self) -> None:
        """Auto-sync silencioso en background cada N minutos."""
        if not _HAS_SYNC or _sync_manager is None:
            return
        if self._sync_worker and self._sync_worker.isRunning():
            return
        if not _sync_manager.is_online():
            self._update_conn_badge()
            return
        self._update_conn_badge()
        pending = _sync_manager.get_pending_count()
        if pending > 0:
            logger.info("Auto-sync: %d registros pendientes, iniciando upload.", pending)
            self._sync_worker = _SyncWorker()
            self._sync_worker.finished_ok.connect(
                lambda n: (
                    self._refresh_pending_count(),
                    QTimer.singleShot(500, self.refresh) if n > 0 else None
                )
            )
            self._sync_worker.start()

    # =========================================================================
    # Carga de datos (refresh, KPIs, tabla)
    # =========================================================================
    # =========================================================================
    # Carga ASINCRONA — todas las queries van en _DashboardLoader (QThread)
    # =========================================================================

    def refresh(self, force: bool = True) -> None:
        """Lanza carga asíncrona forzando actualización desde BD central."""
        if force:
            self._cache_valid = False
            self._data_cache.clear()
        self._async_refresh(load_filters=False, force=force)

    def _async_refresh(self, load_filters: bool = False, force: bool = False) -> None:
        """
        Inicia el loader en background.
        Muestra un overlay sutil y no congela el hilo principal.
        Si hay cache válida para el mismo preset, la sirve instantáneamente
        sin tocar la red/BD (carga instantánea al volver a la pestaña).
        """
        if self._loader and self._loader.isRunning():
            return  # ya hay una carga en progreso

        # ── Servir desde caché si el preset no cambió ─────────────────────────
        if self._cache_valid and not force:
            cached_preset = self._data_cache.get('preset')
            if cached_preset == self._date_preset:
                kpis = self._data_cache.get('kpis')
                rows = self._data_cache.get('rows')
                if kpis and rows is not None:
                    self._on_kpis_ready(*kpis)
                    self._on_rows_ready(rows)
                    return

        self._show_loading(True)

        # Recoger parámetros del filtro UI (en hilo principal, antes del thread)
        fecha_desde, fecha_hasta = self._get_date_range()
        roles       = set(getattr(session, "roles", []) or []) if _HAS_SESSION and session and session.is_authenticated else set()
        id_tecnico  = getattr(session, "id_tecnico", None) if _HAS_SESSION and session else None
        combo_tec   = self._combo_tec_bar.currentData()       if hasattr(self, "_combo_tec_bar")   else None
        combo_est   = self._combo_estado_global.currentData() if hasattr(self, "_combo_estado_global") else None
        combo_modal = self._combo_modal_bar.currentData()     if hasattr(self, "_combo_modal_bar")  else None

        self._loader = _DashboardLoader(
            fecha_desde=fecha_desde,
            fecha_hasta=fecha_hasta,
            roles=roles,
            id_tecnico=id_tecnico,
            combo_tec_id=combo_tec,
            combo_estado=combo_est,
            load_filters=load_filters and not self._filters_loaded,
            parent=self,
        )
        self._loader.kpis_ready.connect(self._on_kpis_ready)
        self._loader.filters_ready.connect(self._on_filters_ready)
        self._loader.rows_ready.connect(self._on_rows_ready)
        self._loader.error.connect(self._on_load_error)
        self._loader.finished.connect(lambda: self._show_loading(False))
        self._loader.start()

    # ── Slots de resultados (ejecutan en hilo PRINCIPAL) ──────────────────────

    # Override showEvent: al volver a la pestaña Dashboard se sirve del caché
    def showEvent(self, event) -> None:
        super().showEvent(event)
        if not self._cache_valid:
            self._async_refresh(load_filters=True)
        else:
            # Restaurar desde caché instantáneamente (sin consulta a la BD)
            kpis = self._data_cache.get('kpis')
            rows = self._data_cache.get('rows')
            if kpis:
                self._card_total.set_value(str(kpis[0]))
                self._card_proceso.set_value(str(kpis[1]))
                self._card_cerrados.set_value(str(kpis[2]))
                self._card_fisicos.set_value(str(kpis[3]))
            if rows:
                self._fill_table_rows(rows)

    @pyqtSlot(int, int, int, int)
    def _on_kpis_ready(self, total: int, proceso: int, terminadas: int, fisicos: int) -> None:
        # Invariante matemática: TOTAL >= EN PROCESO + CERRADOS (estados disjuntos).
        # Si alguna fuente (online u offline) llegara inconsistente, nunca
        # mostrar TOTAL=0 con elementos en proceso.
        piso = int(proceso or 0) + int(terminadas or 0)
        if int(total or 0) < piso:
            logger.warning(
                "KPI inconsistente: total=%s < proceso(%s)+cerrados(%s); se corrige a %s",
                total, proceso, terminadas, piso,
            )
            total = piso
        self._card_total.set_value(str(total))
        self._card_proceso.set_value(str(proceso))
        self._card_cerrados.set_value(str(terminadas))
        self._card_fisicos.set_value(str(fisicos))
        self._update_conn_badge()
        self._refresh_pending_count()
        # Actualizar caché de KPIs
        self._data_cache['kpis'] = (total, proceso, terminadas, fisicos)
        self._data_cache['preset'] = self._date_preset

    @pyqtSlot(list)
    def _on_filters_ready(self, tecnicos: list) -> None:
        if not hasattr(self, "_combo_tec_bar"):
            return
        self._combo_tec_bar.blockSignals(True)
        self._combo_tec_bar.clear()
        self._combo_tec_bar.addItem("Todos los Tecnicos", None)
        for t_id, t_name in tecnicos:
            self._combo_tec_bar.addItem(t_name, t_id)
        self._combo_tec_bar.blockSignals(False)
        self._filters_loaded = True

    @pyqtSlot(list)
    def _on_rows_ready(self, rows: list) -> None:
        self._all_loaded_rows = rows

        # --- APLICAR FILTRO DE MODALIDAD ---
        if hasattr(self, "_combo_modal_bar"):
            filtro_mod = self._combo_modal_bar.currentText().strip()
            if filtro_mod and filtro_mod != "Todas las Modalidades":
                filtered_rows = []
                for row in rows:
                    modalidad_raw = str(row[6]).lower() if len(row) > 6 else ""
                    if filtro_mod == "Solo Digitales":
                        if "digital" not in modalidad_raw:
                            continue  # Ocultar si no es digital
                    elif filtro_mod == "Solo Físicos":
                        if "fisic" not in modalidad_raw and "físic" not in modalidad_raw:
                            continue  # Ocultar si no es físico
                    filtered_rows.append(row)
                rows = filtered_rows
        # -----------------------------------

        # Guardar en caché para restauración instantánea
        self._data_cache['rows'] = rows
        self._cache_valid = True
        self._fill_table_rows(rows)
        # Reaplicar filtro de búsqueda si el usuario ya escribió algo en el buscador
        if hasattr(self, "_search_global") and self._search_global.text().strip():
            self._on_search_changed()

    @pyqtSlot(str)
    def _on_load_error(self, msg: str) -> None:
        logger.warning("[Dashboard] Error de carga: %s", msg)
        self._show_loading(False)

    def _show_loading(self, visible: bool) -> None:
        """Muestra/oculta un indicador sutil en la barra de estado."""
        if hasattr(self, "_lbl_loading"):
            self._lbl_loading.setVisible(visible)

    # ── Métodos de carga síncronos (legacy) — ahora delegados al loader ───────

    def _load_kpis(self) -> None:
        """Método legacy — ahora el loader asíncrono lo reemplaza."""
        self._update_conn_badge()
        self._refresh_pending_count()

    def _populate_filters(self) -> None:
        """Carga inicial de filtros — solo si aún no se cargaron."""
        if self._filters_loaded or not _DEPS_OK or _db_pool is None:
            return
        # Se carga vía _async_refresh(load_filters=True) en __init__

    def _load_table(self) -> None:
        """Método legacy — redirige al loader asíncrono."""
        self._async_refresh(load_filters=False)



    def _load_table(self) -> None:
        """Carga los registros con filtrado por rol. Soporta modo offline."""
        if not hasattr(self, "_table"):
            return
        self._table.clear()
        self._table.setHeaderLabels([
            "", "FOLIO OS", "FECHA", "CLIENTE", "SUCURSAL / PLANTA",
            "TECNICO", "TIPO SERVICIO", "MODALIDAD", "ESTATUS", "SYNC", "ACCIONES"
        ])

        if not _DEPS_OK or _db_pool is None:
            if _HAS_SYNC and _sync_manager:
                try:
                    fecha_desde, fecha_hasta = self._get_date_range()
                    id_tec = None
                    if _HAS_SESSION and session and session.is_authenticated:
                        roles = set(getattr(session, "roles", []) or [])
                        _FULL_ACCESS = {"admin", "logistica", "recepcion"}
                        if not (roles & _FULL_ACCESS):
                            id_tec = session.id_tecnico
                    rows_dicts = _sync_manager.get_local_orders(
                        fecha_desde=fecha_desde.isoformat() if fecha_desde else None,
                        fecha_hasta=fecha_hasta.isoformat() if fecha_hasta else None,
                        id_tecnico=id_tec,
                    )
                    rows = [
                        (
                            d.get("folio_os"), d.get("fecha"), d.get("cliente_nombre"),
                            d.get("sucursal_nombre", ""), d.get("tecnico_nombre"),
                            d.get("tipo_servicio_nombre"), d.get("modalidad"), d.get("estado"),
                            d.get("id"), d.get("id_lote"), bool(d.get("tiene_adjunto")),
                            d.get("sync_status", "PENDING"),
                            d.get("rango_lote"),  # col 12
                        )
                        for d in rows_dicts
                    ]
                    self._all_loaded_rows = rows
                    self._fill_table_rows(rows)
                    return
                except Exception as exc:
                    logger.warning("Error cargando tabla desde SQLite: %s", exc)
            return

        try:
            conn = _db_pool.get_connection()

            conditions: list = []
            params: list = []

            if _HAS_SESSION and session and session.is_authenticated:
                roles = set(getattr(session, "roles", []) or [])
                _FULL_ACCESS = {"admin", "logistica", "recepcion"}
                if not (roles & _FULL_ACCESS):
                    if (("servicio" in roles or "calibrador" in roles
                            or "inspector" in roles) and session.id_tecnico):
                        conditions.append("os.id_tecnico = %s")
                        params.append(session.id_tecnico)
                    if "calibrador" in roles:
                        conditions.append(
                            "(os.id_tipo_servicio IN (1, 4, 5, 7) "
                            " AND os.estado IN ('COMPLETADA', 'ESCANEADA'))"
                        )
                    if "inspector" in roles:
                        conditions.append(
                            "(os.id_tipo_servicio IN (3, 5, 6, 7) "
                            " AND os.estado IN ('COMPLETADA', 'ESCANEADA'))"
                        )

            where_clause = ""
            if conditions:
                where_clause = "AND (" + " OR ".join(conditions) + ")"

            where_extra: list = []

            fecha_desde, fecha_hasta = self._get_date_range()
            if fecha_desde and fecha_hasta:
                where_extra.append("os.fecha::date BETWEEN %s AND %s")
                params.extend([fecha_desde, fecha_hasta])

            if hasattr(self, "_combo_tec_bar"):
                tec_data = self._combo_tec_bar.currentData()
                if tec_data is not None and str(tec_data).strip() != "":
                    where_extra.append("os.id_tecnico = %s")
                    params.append(tec_data)

            if hasattr(self, "_combo_estado_global") and self._combo_estado_global.currentData():
                where_extra.append("os.estado = %s")
                params.append(self._combo_estado_global.currentData())

            if where_extra:
                where_clause += " AND " + " AND ".join(where_extra)

            with conn.cursor() as cur:
                try:
                    cur.execute(
                        f"""
                        SELECT
                            os.folio_os, os.fecha::text,
                            cl.razon_social,
                            COALESCE(
                                NULLIF(suc.nombre_sucursal, ''),
                                NULLIF(suc.direccion, ''),
                                NULLIF((
                                    SELECT COALESCE(NULLIF(s2.direccion,''), NULLIF(s2.nombre_sucursal,''))
                                    FROM cliente_sucursales s2
                                    WHERE s2.cliente_id = os.id_cliente
                                    ORDER BY s2.id ASC LIMIT 1
                                ), ''),
                                NULLIF(os.ubicacion, ''),
                                ''
                            ),
                            tc.nombre_completo,
                            COALESCE(ts.nombre, os.tipo_servicio),
                            os.modalidad,
                            os.estado,
                            os.id,
                            os.id_lote,
                            EXISTS(SELECT 1 FROM adjuntos_os WHERE id_os = os.id) AS tiene_adjunto,
                            COALESCE(os.sync_status, 'SYNCED') AS sync_status,
                            os.rango_lote,
                            COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes       cl    ON os.id_cliente       = cl.id
                        LEFT JOIN cat_tecnicos       tc    ON os.id_tecnico       = tc.id
                        LEFT JOIN cat_tipo_servicio  ts    ON os.id_tipo_servicio = ts.id
                        LEFT JOIN cliente_sucursales suc   ON os.sucursal_id      = suc.id
                        WHERE 1=1 {where_clause}
                        ORDER BY
                            CASE WHEN os.folio_os ~ '-[0-9]+$'
                                 THEN CAST(REGEXP_REPLACE(os.folio_os, '^.*-([0-9]+)$', '\\1') AS INTEGER)
                                 ELSE 0
                            END DESC,
                            os.fecha DESC
                        LIMIT 200
                        """,
                        params or None,
                    )
                    rows = cur.fetchall()
                except Exception as e:
                    import traceback as _tb
                    conn.rollback()
                    logger.warning("Query principal fallo, aplicando fallback: %s", e)
                    _tb.print_exc()
                    cur.execute(
                        f"""
                        SELECT
                            os.folio_os, os.fecha::text,
                            cl.razon_social,
                            COALESCE(os.ubicacion, ''),
                            tc.nombre_completo,
                            COALESCE(ts.nombre, os.tipo_servicio),
                            os.modalidad,
                            os.estado,
                            os.id,
                            NULL as id_lote,
                            EXISTS(SELECT 1 FROM adjuntos_os WHERE id_os = os.id) AS tiene_adjunto,
                            'SYNCED' AS sync_status,
                            NULL as rango_lote,
                            COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes      cl ON os.id_cliente       = cl.id
                        LEFT JOIN cat_tecnicos      tc ON os.id_tecnico       = tc.id
                        LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                        WHERE 1=1 {where_clause}
                        ORDER BY
                            CASE WHEN os.folio_os ~ '-[0-9]+$'
                                 THEN CAST(REGEXP_REPLACE(os.folio_os, '^.*-([0-9]+)$', '\\1') AS INTEGER)
                                 ELSE 0
                            END DESC,
                            os.fecha DESC
                        LIMIT 200
                        """,
                        params or None,
                    )
                    rows = cur.fetchall()

            conn.commit()
            _db_pool.release_connection(conn)
            self._all_loaded_rows = list(rows)
            self._fill_table_rows(self._all_loaded_rows)

        except Exception as exc:
            logger.warning("Error cargando tabla dashboard: %s", exc, exc_info=True)
            # NO limpiar la tabla — mantener datos anteriores o dejar encabezados
            if not self._all_loaded_rows:
                self._show_loading(False)

    # =========================================================================
    # Llenado del QTreeWidget con agrupacion por lotes
    # =========================================================================

    @staticmethod
    def _fmt_fecha(fecha_raw: str) -> str:
        """Convierte 'YYYY-MM-DD' a 'DD/MM/YY'."""
        try:
            parts = str(fecha_raw).split(" ")[0].split("-")
            if len(parts) == 3:
                return f"{parts[2]}/{parts[1]}/{parts[0][-2:]}"
        except Exception:
            pass
        return str(fecha_raw)

    _ESTADOS_CERRADOS = frozenset({
        "CERRADO", "CERRADA", "COMPLETADA", "COMPLETADA_DIGITAL",
        "COMPLETADA_FISICA", "ESCANEADA", "FIRMADA", "TERMINADA", "FINALIZADA",
    })

    @classmethod
    def _is_estado_cerrado(cls, estado: str) -> bool:
        e = str(estado or "").strip().upper()
        return e in cls._ESTADOS_CERRADOS or "CERRAD" in e or "COMPLET" in e or "FINALIZ" in e

    @classmethod
    def _estado_label(cls, estado: str) -> str:
        """Etiqueta del badge: verde 'Cerrado' para cualquier estado final, nunca 'Proceso'."""
        e = str(estado or "").strip()
        if cls._is_estado_cerrado(e):
            return "Cerrado"
        if e.upper().startswith("CANCEL"):
            return "Cancelada"
        return e.capitalize() if e and e != "--" else "Proceso"

    @classmethod
    def _get_sync_label(cls, estado: str, sync_status: str) -> str:
        if cls._is_estado_cerrado(estado):
            return "Sincronizado"
        return "Pendiente" if sync_status == "PENDING" else "Sincronizado"

    def _make_chk_widget(self, folios: list[str], os_ids: list, is_batch: bool = False) -> QWidget:
        """Crea el widget de checkbox para una fila (simple o lote)."""
        chk_widget = QWidget()
        chk_widget.setStyleSheet("background: transparent;")
        chk_lay = QHBoxLayout(chk_widget)
        chk_lay.setContentsMargins(0, 0, 0, 0)
        chk_lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        chk = QCheckBox()
        chk.setStyleSheet("""
            QCheckBox::indicator { width: 16px; height: 16px; border-radius: 4px; }
            QCheckBox::indicator:unchecked { border: 2px solid #C7C7CC; background: white; }
            QCheckBox::indicator:checked   { border: 2px solid #C8102E; background: #C8102E; }
        """)
        chk.setProperty("folio", folios[0] if folios else "")
        chk.setProperty("os_id", os_ids[0] if os_ids else None)
        chk.setProperty("all_folios", folios)
        chk.setProperty("all_os_ids", os_ids)
        chk.setProperty("is_batch", is_batch)
        chk.stateChanged.connect(self._on_row_checkbox_changed)
        chk_lay.addWidget(chk)
        return chk_widget

    @staticmethod
    def _get_sync_check_tooltip(status: str) -> str:
        s = str(status or "").strip().upper()
        if "AUDIT" in s or "ABIERTO" in s or "OPEN" in s:
            return "✓✓ Verde — Abierto por Administración / Oficina en Windows"
        if "SUBIDA" in s or "COMPLET" in s or "CERRAD" in s:
            return "✓✓ Azul — Enviada al Servidor / Concluida con PDF"
        if "TABLET" in s or "RECIBID" in s or "CAMPO" in s or "PROCESO" in s or "PENDIENTE" in s:
            return "✓✓ Gris — Recibida en Tablet / Tomada en campo offline"
        return "✓ Gris — Asignada en Servidor (Pendiente descarga en tablet)"

    def _populate_tree_item(
        self,
        item: QTreeWidgetItem,
        folio_text: str,
        fecha_str: str,
        cliente: str,
        sucursal: str,
        tecnico: str,
        servicio: str,
        modal_label: str,
        estado_label: str,
        sync_label: str,
        os_id,
        is_batch_parent: bool = False,
        sync_check_status: str = "ASIGNADA",
    ) -> None:
        """Rellena las columnas de texto de un QTreeWidgetItem."""
        # Col 1: Folio
        item.setText(self._COL_FOLIO, folio_text)
        font = item.font(self._COL_FOLIO)
        font.setWeight(QFont.Weight.DemiBold if is_batch_parent else QFont.Weight.Medium)
        item.setFont(self._COL_FOLIO, font)
        item.setForeground(self._COL_FOLIO, QBrush(QColor(_RED if not is_batch_parent else "#1D1D1F")))
        item.setData(self._COL_FOLIO, Qt.ItemDataRole.UserRole, os_id)

        # Col 2-5: datos comunes
        item.setText(self._COL_FECHA,    fecha_str)
        item.setForeground(self._COL_FECHA, QBrush(QColor("#636366")))
        item.setText(self._COL_CLIENTE,  cliente)
        item.setText(self._COL_SUCURSAL, sucursal)
        item.setText(self._COL_TECNICO,  tecnico)

        # Col 6-9: badges (texto para el delegate)
        # Col 6: TIPO SERVICIO homologado (CCA + DVE / DVE + Ajuste / CCA + Ajuste / Ajuste)
        try:
            from services.tipo_servicio_rules import etiqueta_corta, etiqueta_larga
            _folio_ref = "" if is_batch_parent else folio_text
            item.setText(self._COL_SERVICIO, etiqueta_corta(servicio, folio=_folio_ref))
            item.setToolTip(
                self._COL_SERVICIO,
                f"{etiqueta_larga(servicio, folio=_folio_ref)}\nAsignado: {servicio or '—'}",
            )
        except Exception:
            item.setText(self._COL_SERVICIO, servicio)
        item.setText(self._COL_MODAL,    modal_label)
        item.setText(self._COL_ESTADO,   estado_label)

        # Col 9: badge SYNC tipo WhatsApp
        check_val = sync_check_status or sync_label or "ASIGNADA"
        item.setText(self._COL_SYNC, check_val)
        item.setData(self._COL_SYNC, Qt.ItemDataRole.UserRole, check_val)
        item.setData(self._COL_SYNC, Qt.ItemDataRole.DisplayRole, check_val)
        item.setToolTip(self._COL_SYNC, self._get_sync_check_tooltip(check_val))

        # Fondo diferenciado para filas padre de lote (solo las 10 columnas de datos)
        if is_batch_parent:
            bg = QBrush(QColor("#F0F4FF"))
            for col in range(self._table.columnCount()):
                item.setBackground(col, bg)

    def _fill_table_rows(self, rows: list) -> None:
        """Inserta items en el QTreeWidget agrupando por id_lote."""
        if not isinstance(rows, list):
            print(f"ADVERTENCIA: rows no es una lista, es {type(rows)}. Intentando extraer datos...")
            if isinstance(rows, dict):
                rows = rows.get('registros') or rows.get('ordenes') or rows.get('data') or []
            else:
                rows = []

        if not rows:
            print("ADVERTENCIA: La lista de rows para la tabla esta vacia.")

        # ── Desactivar redraws durante inserción masiva (crítico para 200+ filas) ──
        self._table.setUpdatesEnabled(False)
        self._table.blockSignals(True)
        try:
            self._table.clear()
            self._table.setHeaderLabels([
                "", "FOLIO OS", "FECHA", "CLIENTE", "SUCURSAL / PLANTA",
                "TÉCNICO", "TIPO SERVICIO", "MODALIDAD", "ESTATUS", "SYNC", "ACCIONES"
            ])

        # ── DEDUPLICACIÓN: un solo registro por folio_os (evita duplicados
            # causados por JOINs multiplicativos en lotes/partidas) ──────────
            _seen_folios: dict = {}
            for _r in rows:
                _folio_key = str(_r[0] or "").strip()
                if _folio_key:
                    _seen_folios[_folio_key] = _r
            rows = list(_seen_folios.values()) if _seen_folios else rows

            # ── Agrupar filas: primero por id_lote (BD), luego retroactivo en Python ─
            # Para registros históricos sin id_lote, detectar folios consecutivos que
            # comparten (fecha, cliente, tecnico, servicio) → tratarlos como lote virtual.
            from collections import OrderedDict

            lote_groups: OrderedDict[str, list] = OrderedDict()
            rows_sin_lote: list = []


            for row in rows:
                id_lote = row[9] if len(row) > 9 else None
                if id_lote:
                    key = str(id_lote)
                    lote_groups.setdefault(key, []).append(row)
                else:
                    rows_sin_lote.append(row)

            # ── Agrupación retroactiva: folios consecutivos mismo cliente/fecha/tec/srv ──
            def _extraer_consecutivo(folio: str) -> int | None:
                """Extrae el último número de un folio tipo OS-26-570 → 570."""
                try:
                    return int(str(folio).split("-")[-1])
                except (ValueError, IndexError):
                    return None

            def _clave_grupo(row) -> tuple:
                """Clave de agrupación: fecha + cliente + técnico + tipo_servicio."""
                return (
                    str(row[1] or ""),   # fecha
                    str(row[2] or ""),   # cliente
                    str(row[4] or ""),   # tecnico
                    str(row[5] or ""),   # tipo_servicio
                    str(row[6] or ""),   # modalidad
                )

            # Ordenar los singles por clave de grupo y consecutivo para detectar secuencias
            rows_sin_lote_sorted = sorted(
                rows_sin_lote,
                key=lambda r: (_clave_grupo(r), _extraer_consecutivo(str(r[0] or "")) or 0)
            )

            singles: list = []   # filas finalmente sin grupo (lote size = 1)
            retro_groups: OrderedDict[str, list] = OrderedDict()

            if rows_sin_lote_sorted:
                current_group: list = [rows_sin_lote_sorted[0]]
                retro_key_counter = 0

                for row in rows_sin_lote_sorted[1:]:
                    prev = current_group[-1]
                    prev_consec = _extraer_consecutivo(str(prev[0] or ""))
                    curr_consec = _extraer_consecutivo(str(row[0] or ""))
                    same_group = (
                        _clave_grupo(row) == _clave_grupo(prev)
                        and prev_consec is not None
                        and curr_consec is not None
                        and curr_consec == prev_consec + 1
                    )
                    if same_group:
                        current_group.append(row)
                    else:
                        # Cerrar grupo anterior
                        if len(current_group) >= 2:
                            retro_key = f"RETRO-{retro_key_counter}"
                            retro_key_counter += 1
                            retro_groups[retro_key] = current_group
                        else:
                            singles.extend(current_group)
                        current_group = [row]

                # Cerrar último grupo
                if len(current_group) >= 2:
                    retro_key = f"RETRO-{retro_key_counter}"
                    retro_groups[retro_key] = current_group
                else:
                    singles.extend(current_group)

            # Unir grupos de BD + grupos retroactivos
            all_groups: OrderedDict[str, list] = OrderedDict()
            all_groups.update(lote_groups)
            all_groups.update(retro_groups)

            _CHK_STYLE = """
                QCheckBox::indicator { width: 16px; height: 16px; border-radius: 4px; }
                QCheckBox::indicator:unchecked { border: 2px solid #C7C7CC; background: white; }
                QCheckBox::indicator:checked   { border: 2px solid #C8102E; background: #C8102E; }
            """

            def _make_chk(folios, os_ids, is_batch=False, pdf_flags=None):
                w = QWidget(); w.setStyleSheet("background: transparent;")
                hl = QHBoxLayout(w); hl.setContentsMargins(0,0,0,0)
                hl.setAlignment(Qt.AlignmentFlag.AlignCenter)
                c = QCheckBox(); c.setStyleSheet(_CHK_STYLE)
                c.setProperty("folio",       folios[0] if folios else "")
                c.setProperty("os_id",       os_ids[0] if os_ids else None)
                c.setProperty("all_folios",  folios)
                c.setProperty("all_os_ids",  os_ids)
                c.setProperty("is_batch",    is_batch)
                if pdf_flags is None:
                    pdf_flags = [False] * len(folios)
                c.setProperty("pdf_flags",   pdf_flags)
                c.setProperty("has_pdf",     any(pdf_flags))
                c.stateChanged.connect(self._on_row_checkbox_changed)
                hl.addWidget(c)
                return w, c

            # ── 1. Lotes (filas padre + hijas) ────────────────────────────────────
            for lote_id, group in all_groups.items():
                if not group:
                    continue

                try:
                    # Ordenar el grupo por folio para encontrar min y max
                    grupo_ord = sorted(group, key=lambda r: _extraer_consecutivo(str(r[0] or "")) or 0)
                    f_ini = str(grupo_ord[0][0] or "")
                    f_fin = str(grupo_ord[-1][0] or "")
                    total_os = len(grupo_ord)
                    
                    texto_folio = f"▸ {f_ini} al {f_fin} ({total_os} OS asignadas)"
                    rep = grupo_ord[0]  # Representante
                    
                    fecha_str    = self._fmt_fecha(str(rep[1] or ""))
                    cliente      = str(rep[2] or "--")
                    sucursal     = str(rep[3] or "")
                    tecnico      = str(rep[4] or "--")
                    servicio     = str(rep[5] or "--")
                    modalidad    = str(rep[6] or "FISICO")
                    estado       = str(rep[7] or "Proceso")
                    os_id        = rep[8] if len(rep) > 8 else None
                    tiene_adj    = rep[10] if len(rep) > 10 else False
                    sync_status  = str(rep[11]) if len(rep) > 11 and rep[11] else "SYNCED"
                    sync_check   = str(rep[13]) if len(rep) > 13 and rep[13] else "ASIGNADA"
                    
                    modal_label  = modalidad.capitalize() + " (Lote)"
                    # Estatus del lote padre derivado de TODAS sus hijas:
                    # 'Cerrado' solo si todas están cerradas; si no, 'Proceso'.
                    if all(self._is_estado_cerrado(str(r[7] or "")) for r in grupo_ord):
                        estado = "Cerrado"
                    elif self._is_estado_cerrado(estado):
                        estado = "Proceso"
                    estado_label = self._estado_label(estado)
                    sync_label   = self._get_sync_label(estado, sync_status)

                    # Crear item padre
                    parent_item = QTreeWidgetItem(self._table)
                    self._populate_tree_item(
                        parent_item, texto_folio, fecha_str, cliente, sucursal,
                        tecnico, servicio, modal_label, estado_label, sync_label, os_id,
                        is_batch_parent=True, sync_check_status=sync_check
                    )
                    
                    # Checkbox del lote con flags de PDF de sus integrantes
                    folios_lote = [str(r[0]) for r in grupo_ord if r[0]]
                    ids_lote = [r[8] for r in grupo_ord if len(r) > 8 and r[8]]
                    flags_lote = []
                    for r in grupo_ord:
                        r_est = str(r[7] or "").upper()
                        r_sync_chk = str(r[13] or "").upper() if len(r) > 13 else ""
                        r_adj = bool(r[10]) if len(r) > 10 else False
                        flags_lote.append(
                            r_est in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA","CERRADO","CERRADA","TERMINADA","FINALIZADA")
                            or "CERRAD" in r_est or "COMPLET" in r_est or "FINALIZ" in r_est
                            or r_sync_chk in ("SUBIDA_SERVIDOR", "AUDITADA_ADMIN")
                            or r_adj
                        )
                    chk_p, _ = _make_chk(folios_lote, ids_lote, is_batch=True, pdf_flags=flags_lote)
                    self._table.setItemWidget(parent_item, self._COL_CHK, chk_p)

                    # Guardamos lista de folios y rango de consecutivos en parent_item para búsqueda
                    consecs = [_extraer_consecutivo(f) for f in folios_lote if _extraer_consecutivo(f) is not None]
                    min_c = min(consecs) if consecs else None
                    max_c = max(consecs) if consecs else None
                    parent_item.setData(self._COL_FOLIO, Qt.ItemDataRole.UserRole + 1, folios_lote)
                    parent_item.setData(self._COL_FOLIO, Qt.ItemDataRole.UserRole + 2, (min_c, max_c))

                    # Acciones del lote → celda ACCIONES (col 10) de la fila padre
                    acts_p = self._build_action_cell_lote(
                        lote_id=lote_id, all_os_ids=ids_lote, all_folios=folios_lote,
                        folio_inicio=f_ini, folio_fin=f_fin,
                        modalidad=modalidad, estado=estado, sync_status=sync_status,
                        parent_item=parent_item
                    )
                    self._set_action_cell(parent_item, acts_p)

                    # Agregar las ordenes hijas (ocultas por defecto)
                    for row in grupo_ord:
                        c_folio = str(row[0] or "")
                        c_oid = row[8] if len(row) > 8 else None
                        c_est = str(row[7] or "--")
                        c_sync = str(row[11]) if len(row) > 11 and row[11] else "SYNCED"
                        c_sync_check = str(row[13]) if len(row) > 13 and row[13] else "ASIGNADA"
                        c_est_label = self._estado_label(c_est)
                        c_sync_label = self._get_sync_label(c_est, c_sync)
                        
                        child = QTreeWidgetItem(parent_item)
                        self._populate_tree_item(
                            child, c_folio, self._fmt_fecha(str(row[1] or "")), str(row[2] or ""), str(row[3] or ""),
                            str(row[4] or ""), str(row[5] or ""), str(row[6] or "").capitalize(), c_est_label, c_sync_label, c_oid,
                            sync_check_status=c_sync_check
                        )
                        
                        c_has_pdf = (
                            c_est.upper() in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA","CERRADO","CERRADA","TERMINADA","FINALIZADA")
                            or "CERRAD" in c_est.upper() or "COMPLET" in c_est.upper() or "FINALIZ" in c_est.upper()
                            or c_sync_check.upper() in ("SUBIDA_SERVIDOR", "AUDITADA_ADMIN")
                            or bool(row[10] if len(row) > 10 else False)
                        )
                        chk_c, _ = _make_chk([c_folio], [c_oid], is_batch=False, pdf_flags=[c_has_pdf])
                        self._table.setItemWidget(child, self._COL_CHK, chk_c)

                        acts_child = self._build_action_cell(
                            folio=c_folio, estado=c_est, os_id=c_oid,
                            tiene_adjunto=bool(row[10]) if len(row) > 10 else False,
                            sync_status=c_sync, row_data=row,
                        )
                        self._set_action_cell(child, acts_child)

                    parent_item.setExpanded(False)

                except Exception as e_lote:
                    print(f"Error procesando lote {lote_id}: {e_lote}")
                    continue

            # ── 2. Registros individuales (sin lote) ──────────────────────────────
            for row in singles:
                try:
                    folio        = str(row[0] or "")
                    fecha_str    = self._fmt_fecha(str(row[1] or ""))
                    cliente      = str(row[2] or "--")
                    sucursal     = str(row[3] or "")
                    tecnico      = str(row[4] or "--")
                    servicio     = str(row[5] or "--")
                    modalidad    = str(row[6] or "FISICO")
                    estado       = str(row[7] or "--")
                    os_id        = row[8] if len(row) > 8 else None
                    tiene_adj    = row[10] if len(row) > 10 else False
                    sync_status  = str(row[11]) if len(row) > 11 and row[11] else "SYNCED"
                    sync_check   = str(row[13]) if len(row) > 13 and row[13] else "ASIGNADA"
                    modal_label  = modalidad.capitalize()
                    estado_label = self._estado_label(estado)
                    sync_label   = self._get_sync_label(estado, sync_status)

                    item = QTreeWidgetItem(self._table)
                    self._populate_tree_item(
                        item, folio, fecha_str, cliente, sucursal,
                        tecnico, servicio, modal_label, estado_label, sync_label, os_id,
                        sync_check_status=sync_check
                    )
                    s_has_pdf = (
                        estado.upper() in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA","CERRADO","CERRADA","TERMINADA","FINALIZADA")
                        or "CERRAD" in estado.upper() or "COMPLET" in estado.upper() or "FINALIZ" in estado.upper()
                        or sync_check.upper() in ("SUBIDA_SERVIDOR", "AUDITADA_ADMIN")
                        or bool(tiene_adj)
                    )
                    chk_w, _ = _make_chk([folio], [os_id], is_batch=False, pdf_flags=[s_has_pdf])
                    self._table.setItemWidget(item, self._COL_CHK, chk_w)

                    acts = self._build_action_cell(
                        folio=folio, estado=estado, os_id=os_id,
                        tiene_adjunto=bool(tiene_adj), sync_status=sync_status, row_data=row,
                    )
                    self._set_action_cell(item, acts)
                except Exception as err_fila:
                    print(f"Error procesando registro individual: {err_fila}")
                    continue

        except Exception as e_full:
            import traceback
            print("ERROR CRITICO LLENANDO TABLA DASHBOARD:")
            traceback.print_exc()
        finally:
            self._table.blockSignals(False)
            # ── Reactivar redraws y forzar repaint limpio ────────────────────────
            self._table.setUpdatesEnabled(True)
            self._table.viewport().update()
            self._place_header_checkbox(self._table)
            self._update_download_zip_btn()


    def _open_pdf_lote(
        self, folio_inicio: str, folio_fin: str, all_folios: list
    ) -> None:
        """
        Abre el PDF de un lote descargándolo directamente desde Render vía HTTP GET
        o recuperándolo de la base de datos / almacenamiento local.
        """
        fi = folio_inicio.strip()
        ff = folio_fin.strip()

        # 1. Intentar descargar/abrir archivo combinado de lote
        lote_cand = f"{fi}_al_{ff}"
        if self._download_and_open_pdf_from_render(lote_cand):
            return

        # 2. Intentar descargar el lote por folio inicial con sufijo lote
        if self._download_and_open_pdf_from_render(f"{fi}_lote"):
            return

        # 3. Intentar cada folio individual disponible en orden
        for fol in all_folios:
            fol_clean = str(fol).strip()
            if self._download_and_open_pdf_from_render(fol_clean):
                return

        # 4. Si ninguno se encontró
        QMessageBox.warning(
            self, "Archivo no encontrado",
            f"No se encontró el PDF del lote:\n\n"
            f"  {fi} al {ff}\n\n"
            f"No está disponible en la nube (Render) ni en almacenamiento local.\n\n"
            f"Si el técnico ya cerró las órdenes desde la tablet,\n"
            f"pídele que sincronice (presione 'Sincronizar' en la tablet)."
        )

    def _build_action_cell_lote(
        self, lote_id: str, all_os_ids: list, all_folios: list,
        folio_inicio: str = "", folio_fin: str = "",
        modalidad: str = "FISICO",
        estado: str = "", sync_status: str = "",
        parent_item: "QTreeWidgetItem | None" = None,
    ) -> QWidget:
        """Crea el widget de acciones para una fila PADRE de lote."""
        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(container)
        lay.setContentsMargins(6, 0, 4, 0)
        lay.setSpacing(4)

        _btn_lote_style = """
            QPushButton {
                background: #E8EDFF;
                color: #1D3A8A;
                border: 1px solid #B8C8FF;
                border-radius: 4px;
                font-size: 8.5pt;
                font-weight: 600;
                padding: 0 4px;
                min-height: 26px;
            }
            QPushButton:hover { background: #D0DAFF; }
        """
        _btn_modal_fisico_style = """
            QPushButton {
                background: #F2F2F7;
                color: #3A3A3C;
                border: 1px solid #D1D1D6;
                border-radius: 4px;
                font-size: 8pt;
                font-weight: 500;
                padding: 0 4px;
                min-height: 26px;
            }
            QPushButton:hover { background: #E5E5EA; }
            QPushButton::menu-indicator { image: none; width: 0; }
        """
        _btn_modal_digital_style = """
            QPushButton {
                background: #E8F4FF;
                color: #0A5C9E;
                border: 1px solid #B3D8FF;
                border-radius: 4px;
                font-size: 8pt;
                font-weight: 600;
                padding: 0 4px;
                min-height: 26px;
            }
            QPushButton:hover { background: #CCE9FF; }
            QPushButton::menu-indicator { image: none; width: 0; }
        """
        _btn_del_style = """
            QPushButton {
                background: #FFF0F0;
                color: #C8102E;
                border: 1px solid #FFB3B3;
                border-radius: 4px;
                font-size: 8.5pt;
                font-weight: 600;
                padding: 0 4px;
                min-height: 26px;
            }
            QPushButton:hover { background: #FFE0E0; }
        """

        # ── Botón PDF Lote ────────────────────────────────────────────────────
        btn_pdf_lote = QPushButton("PDF Lote")
        btn_pdf_lote.setStyleSheet(_btn_lote_style)
        btn_pdf_lote.setFixedSize(62, 28)
        btn_pdf_lote.setToolTip(
            f"Buscar y abrir el PDF compilado del lote\n"
            f"{folio_inicio or all_folios[0]} → {folio_fin or all_folios[-1]}"
        )
        fi = folio_inicio or (all_folios[0] if all_folios else "")
        ff = folio_fin   or (all_folios[-1] if all_folios else "")
        btn_pdf_lote.clicked.connect(
            lambda _c, _fi=fi, _ff=ff, _af=list(all_folios):
                self._open_pdf_lote(_fi, _ff, _af)
        )
        lay.addWidget(btn_pdf_lote)

        # ── Botón Modalidad (menú desplegable Físico ↔ Digital) ───────────────
        is_digital = (str(modalidad).upper() == "DIGITAL")
        modal_text  = "📱 Digital" if is_digital else "📄 Físico"
        modal_style = _btn_modal_digital_style if is_digital else _btn_modal_fisico_style

        btn_modal = QPushButton(modal_text)
        btn_modal.setStyleSheet(modal_style)
        btn_modal.setFixedSize(72, 28)
        btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")
        btn_modal.setCursor(Qt.CursorShape.PointingHandCursor)

        menu_modal = QMenu(btn_modal)
        menu_modal.setStyleSheet("""
            QMenu {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 8px;
                padding: 4px;
                font-size: 9pt;
            }
            QMenu::item { padding: 8px 18px; border-radius: 4px; color: #1D1D1F; }
            QMenu::item:selected { background: #F5F5F7; }
        """)
        act_fisico  = QAction("📄  Físico  — formato impreso / escaneo", btn_modal)
        act_digital = QAction("📱  Digital — captura en tablet / app móvil", btn_modal)
        menu_modal.addAction(act_fisico)
        menu_modal.addAction(act_digital)

        act_fisico.triggered.connect(
            lambda _c, ids=list(all_os_ids), b=btn_modal, pi=parent_item:
                self._cambiar_modalidad_lote(ids, "FISICO", b, pi)
        )
        act_digital.triggered.connect(
            lambda _c, ids=list(all_os_ids), b=btn_modal, pi=parent_item:
                self._cambiar_modalidad_lote(ids, "DIGITAL", b, pi)
        )

        btn_modal.setMenu(menu_modal)
        lay.addWidget(btn_modal)

        # ── Botón Eliminar Lote (solo admin) ──────────────────────────────────
        if self._is_admin():
            btn_del = QPushButton("Eliminar")
            btn_del.setStyleSheet(_btn_del_style)
            btn_del.setFixedSize(62, 28)
            btn_del.setToolTip("Eliminar todos los folios de este lote")
            btn_del.clicked.connect(
                lambda _checked, ids=list(all_os_ids), fols=list(all_folios):
                    self._confirm_delete_batch(ids, fols)
            )
            lay.addWidget(btn_del)

        lay.addStretch()
        return container

    def _cambiar_modalidad_lote(
        self, os_ids: list, nueva_modalidad: str,
        btn_modal: "QPushButton", parent_item: "QTreeWidgetItem | None"
    ) -> None:
        """
        Actualiza la modalidad de todos los registros del lote en PostgreSQL
        y refresca el botón + la celda MODALIDAD del árbol en tiempo real.
        """
        if not os_ids or not _DEPS_OK or _db_pool is None:
            return
        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE ordenes_servicio SET modalidad = %s WHERE id = ANY(%s)",
                    (nueva_modalidad, os_ids)
                )
            conn.commit()
            _db_pool.release_connection(conn)
            logger.info(
                "_cambiar_modalidad_lote: %d registros → %s",
                len(os_ids), nueva_modalidad
            )
        except Exception as exc:
            logger.error("Error cambiando modalidad: %s", exc)
            QMessageBox.critical(
                self, "Error",
                f"No se pudo cambiar la modalidad:\n{exc}"
            )
            return

        # ── Actualizar UI en tiempo real sin recargar toda la tabla ──────────
        is_digital = (nueva_modalidad.upper() == "DIGITAL")
        new_text   = "📱 Digital" if is_digital else "📄 Físico"
        new_label  = "Digital (Lote)" if is_digital else "Fisico (Lote)"
        new_style  = """
            QPushButton {
                background: #E8F4FF; color: #0A5C9E;
                border: 1px solid #B3D8FF; border-radius: 4px;
                font-size: 8pt; font-weight: 600;
                padding: 0 7px; min-height: 26px;
            }
            QPushButton:hover { background: #CCE9FF; }
            QPushButton::menu-indicator { image: none; width: 0; }
        """ if is_digital else """
            QPushButton {
                background: #F2F2F7; color: #3A3A3C;
                border: 1px solid #D1D1D6; border-radius: 4px;
                font-size: 8pt; font-weight: 500;
                padding: 0 7px; min-height: 26px;
            }
            QPushButton:hover { background: #E5E5EA; }
            QPushButton::menu-indicator { image: none; width: 0; }
        """
        if btn_modal:
            btn_modal.setText(new_text)
            btn_modal.setStyleSheet(new_style)

        # Actualizar la celda MODALIDAD del item padre en el árbol
        if parent_item:
            parent_item.setText(self._COL_MODAL, new_label)
            # Actualizar filas hijas también
            for i in range(parent_item.childCount()):
                child = parent_item.child(i)
                child.setText(
                    self._COL_MODAL,
                    "Digital" if is_digital else "Fisico"
                )

        # Notificar éxito brevemente
        lbl = QLabel(
            f"  ✅ Modalidad → {'Digital' if is_digital else 'Físico'} guardada  ",
            self
        )
        lbl.setStyleSheet(
            "background: #D1FAE5; color: #065F46; border-radius: 6px; "
            "font-size: 9pt; font-weight: 600; padding: 6px 10px;"
        )
        lbl.setWindowFlags(Qt.WindowType.ToolTip)
        lbl.move(self.mapToGlobal(self.rect().center()))
        lbl.show()
        QTimer.singleShot(2000, lbl.deleteLater)


    def _confirm_delete_batch(self, os_ids: list, folios: list) -> None:
        """Confirma y elimina todos los registros de un lote (con cascada).

        Estrategia resiliente:
        1. Intenta borrar por IDs numéricos (os_ids sin None).
        2. Si no hay IDs válidos (lotes físicos), borra por folio_os.
        3. Si folios también está vacío, intenta desglosar el rango del texto.
        """
        # ── 1. Resolver lista de folios ───────────────────────────────────────
        folios_limpios = [f for f in (folios or []) if f]

        # Fallback: desglosar rango "OS-26-631 al OS-26-638" si folios viene vacío
        if not folios_limpios and os_ids:
            # os_ids puede traer strings de folio en algunos contextos
            folios_limpios = [str(x) for x in os_ids if x and not str(x).isdigit()]

        # ── 2. Resolver IDs numéricos ─────────────────────────────────────────
        valid_ids = []
        for i in os_ids:
            try:
                valid_ids.append(int(i))
            except (TypeError, ValueError):
                pass  # None o strings de folio → ignorar para esta lista

        # ── 3. Verificar que tengamos algo con qué borrar ─────────────────────
        if not valid_ids and not folios_limpios:
            QMessageBox.warning(
                self, "Sin datos para eliminar",
                "No se encontraron IDs ni folios válidos para este lote.\n"
                "Intenta refrescar el dashboard (F5) y vuelve a intentarlo."
            )
            return

        n_items = len(folios_limpios) or len(valid_ids)
        modo    = "folios" if folios_limpios else f"{len(valid_ids)} ID(s)"
        label_f = f"{folios_limpios[0]} … {folios_limpios[-1]}" if folios_limpios else str(valid_ids[:3])

        # ── 4. Diálogo de confirmación ────────────────────────────────────────
        msg = QMessageBox(self)
        msg.setWindowTitle("⚠️  Eliminar Lote")
        msg.setText(
            f"¿Eliminar el lote completo ({n_items} formato(s)) de forma definitiva?\n\n"
            f"Folios: {label_f}\n\n"
            "Esta acción es IRREVERSIBLE."
        )
        msg.setStandardButtons(
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel
        )
        msg.setDefaultButton(QMessageBox.StandardButton.Cancel)
        msg.setIcon(QMessageBox.Icon.Warning)
        if msg.exec() != QMessageBox.StandardButton.Yes:
            return

        # ── 5. Tablas hijas con SAVEPOINT ────────────────────────────────────
        _CHILD_TABLES = [
            ("adjuntos_os",        "id_os"),
            ("det_excentricidad",  "id_os"),
            ("det_repetibilidad",  "id_os"),
            ("det_exactitud",      "id_os"),
            ("det_celdas_carga",   "id_os"),
            ("det_levantamiento_metrologico", "id_os"),
            ("det_levantamiento_proyecto",    "id_os"),
            ("historial_ordenes",  "id_os"),
            ("historial_os",       "id_os"),
        ]
        conn = None
        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:

                if valid_ids:
                    # ── Borrado por IDs numéricos (cascada) ──────────────────
                    for tabla, col in _CHILD_TABLES:
                        sp = f"sp_{tabla[:20]}"
                        try:
                            cur.execute(f"SAVEPOINT {sp}")
                            cur.execute(
                                f"DELETE FROM {tabla} WHERE {col} = ANY(%s)",
                                (valid_ids,)
                            )
                            cur.execute(f"RELEASE SAVEPOINT {sp}")
                        except Exception:
                            try: cur.execute(f"ROLLBACK TO SAVEPOINT {sp}")
                            except Exception: pass

                    cur.execute(
                        "DELETE FROM ordenes_servicio WHERE id = ANY(%s)",
                        (valid_ids,)
                    )
                    rows = cur.rowcount

                else:
                    # ── Borrado por folio_os cuando no hay IDs ────────────────
                    # Primero obtener los IDs internos desde los folios
                    cur.execute(
                        "SELECT id FROM ordenes_servicio WHERE folio_os = ANY(%s)",
                        (folios_limpios,)
                    )
                    db_ids = [r[0] for r in cur.fetchall() if r[0] is not None]

                    if db_ids:
                        # Borrar hijos por IDs recuperados
                        for tabla, col in _CHILD_TABLES:
                            sp = f"sp_{tabla[:20]}"
                            try:
                                cur.execute(f"SAVEPOINT {sp}")
                                cur.execute(
                                    f"DELETE FROM {tabla} WHERE {col} = ANY(%s)",
                                    (db_ids,)
                                )
                                cur.execute(f"RELEASE SAVEPOINT {sp}")
                            except Exception:
                                try: cur.execute(f"ROLLBACK TO SAVEPOINT {sp}")
                                except Exception: pass

                    # Borrar la OS por folio_os directamente (tolerante a id=None)
                    cur.execute(
                        "DELETE FROM ordenes_servicio WHERE folio_os = ANY(%s)",
                        (folios_limpios,)
                    )
                    rows = cur.rowcount

            conn.commit()
            logger.info("[DELETE LOTE] %d registros eliminados: %s", rows, label_f)
            QMessageBox.information(
                self, "Lote eliminado",
                f"Se eliminaron {rows} orden(es) correctamente.\n"
                f"Folios: {label_f}"
            )
            self._load_table()
            self._load_kpis()

        except Exception as exc:
            if conn:
                try: conn.rollback()
                except Exception: pass
            logger.error("Error eliminando lote: %s", exc)
            QMessageBox.critical(
                self, "Error al eliminar",
                f"No se pudo eliminar el lote:\n\n{exc}"
            )
        finally:
            if conn:
                try: _db_pool.release_connection(conn)
                except Exception: pass

    # =========================================================================
    # Celda de acciones: columna dedicada ACCIONES (col 10, 220px fijo)
    # =========================================================================

    def _set_action_cell(self, item: QTreeWidgetItem, action_widget: QWidget) -> None:
        """Inserta el QHBoxLayout de botones dentro de la celda ACCIONES (col 10)
        de la MISMA fila (padre de lote, hija o individual).

        Antes se usaba una sub-fila con setFirstColumnSpanned(True) y botones
        alineados a la derecha; el ancho real de ese span no coincidía con el
        de las columnas y los botones quedaban montados sobre SYNC. Ahora el
        widget tiene ancho fijo = ancho de la columna, así que nunca invade
        columnas vecinas.
        """
        action_widget.setFixedWidth(self._W_ACCIONES)
        action_widget.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Preferred)
        lay = action_widget.layout()
        if lay is not None:
            lay.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        self._table.setItemWidget(item, self._COL_ACCIONES, action_widget)

    def _build_action_cell(self, folio: str, estado: str, os_id,
                           tiene_adjunto: bool, sync_status: str,
                           row_data: tuple) -> QWidget:
        """Construye el widget de botones de acción (sin contenedor de celda propio).
        - Cerrado + PDF: [ 👁 Ver PDF ] [ 📥 Descargar ] [ 🔄 Rehacer ]
        - En Proceso:    [ ✏️ Continuar Captura ]
        - Asignado/Pendiente: etiqueta 'Pendiente'
        Altura de botones: 28px, border-radius: 6px, font-size: 12px.
        """
        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(container)
        lay.setContentsMargins(6, 0, 4, 0)
        lay.setSpacing(4)

        estatus = str(estado or "").strip().lower()
        sync_check = str(row_data[13]).upper() if len(row_data) > 13 and row_data[13] else ""

        is_closed = (
            estatus in ("cerrado", "cerrada", "completada", "completada_digital",
                        "escaneada", "terminada", "finalizada")
            or "cerrad" in estatus
            or "complet" in estatus
            or "finaliz" in estatus
        )

        has_pdf = (
            is_closed
            or sync_check in ("SUBIDA_SERVIDOR", "AUDITADA_ADMIN")
            or bool(tiene_adjunto)
        )

        is_proceso = estatus in ('en proceso', 'proceso')

        # ── CONDICIÓN DE ORO ─────────────────────────────────────────────────
        if is_closed and has_pdf:
            # 1. [ 👁 PDF ] — Azul suave, 68px de ancho para texto completo
            btn_pdf = QPushButton("👁 PDF")
            btn_pdf.setObjectName("btn_action_pdf")
            btn_pdf.setFixedSize(54, 28)
            btn_pdf.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_pdf.setStyleSheet("""
                QPushButton {
                    background-color: #E3F2FD;
                    color: #1976D2;
                    border: 1px solid #BBDEFB;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 600;
                    padding: 2px 3px;
                }
                QPushButton:hover { background-color: #BBDEFB; }
            """)
            btn_pdf.setToolTip(f"Visualizar PDF de {folio}")
            btn_pdf.clicked.connect(lambda _, fl=str(folio): self._open_pdf(fl))
            lay.addWidget(btn_pdf)

            # 2. [ 📥 Descargar ] — Verde suave, 82px de ancho para texto completo
            btn_dl = QPushButton("📥 Descargar")
            btn_dl.setObjectName("btn_action_download")
            btn_dl.setFixedSize(80, 28)
            btn_dl.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_dl.setStyleSheet("""
                QPushButton {
                    background-color: #E8F5E9;
                    color: #2E7D32;
                    border: 1px solid #C8E6C9;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 600;
                    padding: 2px 3px;
                }
                QPushButton:hover { background-color: #C8E6C9; }
            """)
            btn_dl.setToolTip(f"Descargar PDF de {folio} al disco")
            btn_dl.clicked.connect(lambda _, fid=os_id, fl=folio: self._descargar_pdf_os(fid, fl))
            lay.addWidget(btn_dl)

            # 3. [ 🔄 Rehacer ] — Naranja suave, 78px de ancho para texto completo
            btn_rehacer = QPushButton("🔄 Rehacer")
            btn_rehacer.setObjectName("btn_action_rehacer")
            btn_rehacer.setFixedSize(68, 28)
            btn_rehacer.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_rehacer.setStyleSheet("""
                QPushButton {
                    background-color: #FFF3E0;
                    color: #E65100;
                    border: 1px solid #FFE0B2;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 600;
                    padding: 2px 3px;
                }
                QPushButton:hover { background-color: #FFE0B2; }
            """)
            btn_rehacer.setToolTip(f"Rehacer toma metrológica de {folio} (corregir y reemitir PDF)")
            btn_rehacer.clicked.connect(
                lambda _, fid=os_id, fl=folio, rd=row_data: self._abrir_captura_digital(fid, fl, rd)
            )
            lay.addWidget(btn_rehacer)

        elif is_proceso:
            # [ 📝 Capturar / Continuar ] — Rojo institucional PESA, texto blanco
            btn_cap = QPushButton("Capturar")
            btn_cap.setObjectName("btn_action_capturar")
            btn_cap.setFixedSize(72, 26)
            btn_cap.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_cap.setStyleSheet("""
                QPushButton {
                    background-color: #B81D24;
                    color: #FFFFFF;
                    border: none;
                    border-radius: 6px;
                    font-size: 10px;
                    font-weight: 700;
                }
                QPushButton:hover { background-color: #9E161C; }
            """)
            btn_cap.setToolTip(f"Abrir captura metrológica de {folio}")
            btn_cap.clicked.connect(
                lambda _, fid=os_id, fl=folio, rd=row_data: self._abrir_captura_digital(fid, fl, rd)
            )
            lay.addWidget(btn_cap)

        else:
            # Órdenes Asignadas, Abiertas o sin realizar:
            # PROHIBIDO mostrar botones de PDF o Descarga
            label_pend = QLabel("Pendiente")
            label_pend.setStyleSheet(
                "color: #8E8E93; font-size: 11px; font-style: italic; background: transparent;"
            )
            lay.addWidget(label_pend)

        lay.addStretch()
        return container

    def _get_id_indicador_for_os(self, os_id, folio: str) -> str:
        """
        Obtiene el ID Indicador / ID Equipo asociado a la orden para la nomenclatura
        estricta al guardar: {FOLIO}-{ID_INDICADOR}.pdf (ej. OS-26-570-AC-01.pdf).
        Si no existe o no aplica, retorna cadena vacía.
        """
        clean_folio = str(folio or "").strip()
        if not _DEPS_OK or not _db_pool:
            return ""
        try:
            conn = _db_pool.get_connection()
            id_ind = ""
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT 
                        COALESCE(id_equipo, indicador_id, ''),
                        datos_tecnicos_json
                    FROM ordenes_servicio 
                    WHERE folio_os = %s OR id = %s 
                    LIMIT 1
                    """,
                    (clean_folio, os_id)
                )
                row = cur.fetchone()
                if row:
                    col_id, dt_json = row
                    if col_id and str(col_id).strip() not in ("", "None", "NULL", "N/A", "--"):
                        id_ind = str(col_id).strip()
                    elif dt_json:
                        import json
                        dj = json.loads(dt_json) if isinstance(dt_json, str) else dt_json
                        if isinstance(dj, dict):
                            val = dj.get("id_equipo") or dj.get("id_indicador") or dj.get("indicador_id") or dj.get("id_instrumento")
                            if val and str(val).strip() not in ("", "None", "NULL", "N/A", "--"):
                                id_ind = str(val).strip()
            _db_pool.release_connection(conn)

            # Limpiar caracteres inválidos para nombres de archivo en Windows
            if id_ind:
                import re
                id_ind = re.sub(r'[\\/*?:"<>|]', '_', id_ind).strip()
            return id_ind
        except Exception as exc:
            logger.warning("Error obteniendo id_indicador para %s: %s", clean_folio, exc)
            return ""

    def _descargar_pdf_os(self, os_id: int, folio: str) -> None:
        """
        Descarga el PDF de la OS sugiriendo el formato estricto:
        {FOLIO}-{ID_INDICADOR}.pdf (ej: OS-26-570-AC-01.pdf)
        o {FOLIO}.pdf si id_indicador no aplica.
        Actualiza el estado a 'Abierto' (✓✓ Verde) con marca temporal en PostgreSQL.
        """
        import os as _os
        import shutil
        import base64

        clean_folio = str(folio or "").strip()

        # 1. Buscar el PDF en la carpeta de PDFs de la aplicación
        pdf_src = None
        try:
            from services.pdf_router import get_pdf_path
            pdf_src = get_pdf_path(os_id, clean_folio)
        except Exception:
            pass
        if not pdf_src or not _os.path.exists(pdf_src):
            from pathlib import Path
            for search_dir in [
                _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', '..', 'PDFs'),
                _os.path.join(_os.path.expanduser('~'), 'Documents', 'PESA', 'PDFs'),
            ]:
                candidate = Path(search_dir) / f'{clean_folio}.pdf'
                if candidate.exists():
                    pdf_src = str(candidate)
                    break

        # Si no existe localmente, intentar descargar desde PostgreSQL (pdf_b64 subido por tablet)
        if (not pdf_src or not _os.path.exists(pdf_src)) and _DEPS_OK and _db_pool:
            try:
                conn = _db_pool.get_connection()
                pdf_b64 = None
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT pdf_b64 FROM ordenes_servicio WHERE id = %s OR folio_os = %s LIMIT 1",
                        (os_id, clean_folio)
                    )
                    row = cur.fetchone()
                    if row and row[0]:
                        pdf_b64 = row[0]
                _db_pool.release_connection(conn)

                if pdf_b64:
                    import tempfile
                    temp_dir = tempfile.gettempdir()
                    temp_pdf = _os.path.join(temp_dir, f"{clean_folio}.pdf")
                    with open(temp_pdf, "wb") as f_out:
                        f_out.write(base64.b64decode(pdf_b64))
                    pdf_src = temp_pdf
            except Exception as exc:
                logger.warning("No se pudo obtener pdf_b64 de la BD para %s: %s", clean_folio, exc)

        # Si aún no existe, intentar descarga directa desde Render vía HTTP
        if not pdf_src or not _os.path.exists(pdf_src):
            try:
                import urllib.request
                import tempfile
                render_url = f"https://pesa-api-za9i.onrender.com/api/v1/os/{clean_folio}/pdf"
                req = urllib.request.Request(render_url, headers={"User-Agent": "PesaDesktop/1.0"})
                with urllib.request.urlopen(req, timeout=12) as resp:
                    if resp.status == 200:
                        temp_pdf = _os.path.join(tempfile.gettempdir(), f"{clean_folio}.pdf")
                        with open(temp_pdf, "wb") as f_out:
                            f_out.write(resp.read())
                        pdf_src = temp_pdf
            except Exception as exc_render:
                logger.debug("No se pudo descargar PDF desde Render en _descargar_pdf_os para %s: %s", clean_folio, exc_render)

        if not pdf_src or not _os.path.exists(pdf_src):
            QMessageBox.warning(
                self, "PDF no encontrado",
                f"No se encontró el PDF para el folio {clean_folio}.\n"
                "Genera primero el PDF desde la pantalla de captura o espera a que el técnico sincronice."
            )
            return

        # 2. Lógica de nomenclatura estricta: {FOLIO}-{ID_INDICADOR}.pdf
        id_ind = self._get_id_indicador_for_os(os_id, clean_folio)
        if id_ind:
            suggested_name = f"{clean_folio}-{id_ind}.pdf"
        else:
            suggested_name = f"{clean_folio}.pdf"

        # Diálogo de guardado sugiriendo el nombre de archivo predeterminado
        dest_path, _ = QFileDialog.getSaveFileName(
            self,
            f"Descargar PDF — {clean_folio}",
            suggested_name,
            "Archivos PDF (*.pdf)",
        )
        if not dest_path:
            return  # canceló

        # 3. Guardar / copiar el archivo
        try:
            shutil.copy2(pdf_src, dest_path)
        except Exception as exc:
            QMessageBox.critical(
                self, "Error al guardar",
                f"No se pudo guardar el archivo PDF:\n{exc}"
            )
            return

        # 4. Registrar en BD y cambiar inmediatamente el check a 'Abierto' (✓✓ Verde)
        self._marcar_auditada_admin(clean_folio)

        QMessageBox.information(
            self, "PDF Descargado",
            f"PDF guardado exitosamente como:\n{dest_path}\n\n"
            "Estatus de la orden actualizado a 'Abierto' (✓✓ Verde)."
        )

    def _confirmar_pdf_recibido(self, os_id: int, folio: str) -> None:
        """Marca manualmente la orden como PDF recibido / abierto por administración."""
        self._marcar_auditada_admin(folio)
        QMessageBox.information(
            self, "Estatus Actualizado",
            f"La orden {folio} ha sido actualizada a 'Abierto' (✓✓ Verde) en el sistema."
        )

    def _abrir_captura_digital(self, os_id, folio: str, row_data: tuple = None) -> None:
        """Abre el diálogo de captura digital interactiva para la OS indicada.
        Antes de abrir, verifica que la OS exista en la BD para evitar abrir
        un diálogo de una orden huérfana (eliminada remotamente).
        """
        # ── Verificación de existencia: evitar abrir captura de orden huérfana ───
        if folio:
            try:
                _conn_chk = _db_pool.get_connection()
                try:
                    with _conn_chk.cursor() as _cur_chk:
                        _cur_chk.execute(
                            "SELECT id FROM ordenes_servicio WHERE folio_os = %s",
                            (folio.strip(),)
                        )
                        _exists = _cur_chk.fetchone()
                    _conn_chk.commit()
                finally:
                    _db_pool.release_connection(_conn_chk)

                if not _exists:
                    # Orden eliminada remotamente — purgar de la vista sin error bloqueante
                    logger.warning("_abrir_captura_digital: OS huérfana '%s' (eliminada en servidor). Purgar del tree.", folio)
                    self._remove_folio_from_tree(folio)
                    QMessageBox.information(
                        self, "Orden no encontrada",
                        f"La orden {folio} ya no existe en el servidor.\n"
                        "La tabla se actualizó automáticamente."
                    )
                    self._async_refresh(load_filters=False, force=True)
                    return
            except Exception as _exc_chk:
                logger.warning("_abrir_captura_digital: no se pudo verificar existencia: %s", _exc_chk)

        try:
            from ui.widgets.captura_digital_dialog import CapturaDigitalDialog
        except ImportError as exc:
            QMessageBox.critical(
                self, "Error",
                f"No se pudo cargar el módulo de captura digital:\n{exc}"
            )
            return

        orden_dict = {}
        if row_data and len(row_data) >= 6:
            orden_dict = {
                'fecha': row_data[1] or '',
                'cliente': row_data[2] or '',
                'sucursal': row_data[3] or '',
                'tecnico': row_data[4] or '',
                'tipo_servicio': row_data[5] or ''
            }
            if len(row_data) > 13:
                orden_dict['tipo_instrumento'] = row_data[13]
                orden_dict['marca'] = row_data[14]
                orden_dict['modelo'] = row_data[15]

        dlg = CapturaDigitalDialog(os_id=os_id, folio=folio, orden_data=orden_dict, parent=self)
        dlg.captura_guardada.connect(self.refresh)
        dlg.exec()

    def _remove_folio_from_tree(self, folio: str) -> None:
        """Elimina del QTreeWidget la fila (o grupo) que coincide con el folio dado.
        Soporta tanto filas individuales como nodos hijo dentro de lotes."""
        if not hasattr(self, "_table") or not folio:
            return
        folio = folio.strip()
        root = self._table.invisibleRootItem()
        to_remove = []   # (parent_item_or_None, child_item)
        for i in range(root.childCount()):
            top = root.child(i)
            # ¿Es un nodo individual con ese folio?
            if top.text(0).strip() == folio:
                to_remove.append((None, top))
                continue
            # ¿Es un grupo con ese folio como hijo?
            for j in range(top.childCount()):
                child = top.child(j)
                if child.text(0).strip() == folio:
                    to_remove.append((top, child))
        for parent, item in to_remove:
            if parent is None:
                idx = root.indexOfChild(item)
                if idx >= 0:
                    root.takeChild(idx)
            else:
                idx = parent.indexOfChild(item)
                if idx >= 0:
                    parent.takeChild(idx)
                # Si el grupo quedó vacío, también lo eliminamos
                if parent.childCount() == 0:
                    pidx = root.indexOfChild(parent)
                    if pidx >= 0:
                        root.takeChild(pidx)
        logger.info("_remove_folio_from_tree: purgadas %d entrada(s) de folio '%s'",
                    len(to_remove), folio)


    # =========================================================================
    # Filtrado de busqueda
    # =========================================================================
    def _apply_search_filter(self) -> None:
        """
        Filtrado jerárquico sobre el QTreeWidget de lotes.

        Reglas:
          1. Si un HIJO (folio individual) coincide → el padre se muestra y se expande.
          2. Si el PADRE (rango del lote / cliente) coincide → el grupo completo se muestra.
          3. Las ramas sin ninguna coincidencia se ocultan.
          4. Sin texto → todos los ítems visibles (sin modificar expansión del usuario).
        """
        if not hasattr(self, "_table"):
            return

        search_term = ""
        if hasattr(self, "_search_global"):
            search_term = self._search_global.text().strip().lower()

        root = self._table.invisibleRootItem()
        n_top = root.childCount()

        if not search_term:
            # Sin filtro: mostrar todo, restaurar estado colapsado por defecto
            for i in range(n_top):
                parent_item = root.child(i)
                parent_item.setHidden(False)
                for j in range(parent_item.childCount()):
                    parent_item.child(j).setHidden(False)
            return

        words = search_term.split()

        # ── Detección de modo de búsqueda ────────────────────────────────────
        # Numérico puro (ej. "624") → solo buscar en FOLIO (columna 0).
        # Evita que códigos postales, teléfonos o números en direcciones
        # hagan falso-positivo.
        _is_numeric_search = search_term.isdigit()

        # Prefijo de folio (ej. "OS-26", "RMA-26") → solo folio.
        _FOLIO_PREFIXES = ("os-", "rma-", "re-", "lp-", "lv-")
        _is_folio_prefix = any(search_term.startswith(p) for p in _FOLIO_PREFIXES)

        _folio_only = _is_numeric_search or _is_folio_prefix

        def _matches_folio_only(folio_text: str) -> bool:
            """Coincidencia de subcadena SOLO sobre el texto del folio.
            No evalúa sucursal ni dirección → evita falsos positivos con CPs.
            '624' → True para 'OS-26-624', False para sucursal con '76246'
            porque la sucursal NUNCA se evalúa en este modo.
            """
            return search_term in folio_text.lower().strip()

        def _matches_all_fields(text: str) -> bool:
            """Búsqueda general: todas las palabras deben aparecer en algún campo."""
            t = text.lower()
            return all(w in t for w in words)

        for i in range(n_top):
            parent_item = root.child(i)

            # ── COLUMNA 1 = FOLIO OS (columna 0 es el checkbox, siempre vacío) ──
            parent_folio = parent_item.text(1) or ""
            child_count  = parent_item.childCount()

            folios_lote = parent_item.data(self._COL_FOLIO, Qt.ItemDataRole.UserRole + 1) or []
            range_tuple = parent_item.data(self._COL_FOLIO, Qt.ItemDataRole.UserRole + 2)

            any_child_match = False

            # Evaluar si el padre en sí coincide
            if _folio_only:
                parent_match = _matches_folio_only(parent_folio)
                # Si es numérico y tenemos rango de lote (ej. 669..672), checar si search_term cae dentro
                if not parent_match and _is_numeric_search and range_tuple:
                    min_c, max_c = range_tuple
                    if min_c is not None and max_c is not None:
                        try:
                            s_num = int(search_term)
                            if min_c <= s_num <= max_c:
                                parent_match = True
                        except ValueError:
                            pass
            else:
                # Excluir col 5 (Técnico) del filtro de texto del padre.
                # El técnico se filtra por ID exacto en SQL — incluirlo en texto
                # genera falsos positivos con nombres parcialmente iguales.
                parent_texts = " ".join(
                    (parent_item.text(col) or "")
                    for col in range(1, 7)
                    if col != self._COL_TECNICO   # excluir columna Técnico
                )
                parent_match = _matches_all_fields(parent_texts)

            for j in range(child_count):
                child = parent_item.child(j)
                child_folio = child.text(1) or ""

                if _folio_only:
                    child_match = _matches_folio_only(child_folio)
                else:
                    # Excluir col 5 (Técnico) del filtro textual: el técnico ya
                    # fue filtrado exactamente por ID en la query SQL. Incluirlo
                    # en el texto causaba falsos positivos cuando dos técnicos
                    # comparten el mismo nombre parcial (ej. "Alan Guevara" vs
                    # "Alan Terrazas").
                    child_texts = " ".join(
                        (child.text(col) or "")
                        for col in range(1, 7)
                        if col != self._COL_TECNICO   # excluir columna Técnico
                    )
                    child_match = _matches_all_fields(child_texts)

                if child_match:
                    any_child_match = True
                    child.setHidden(False)
                else:
                    # Si no coincide el hijo directamente:
                    # En modo general (búsqueda por cliente/sucursal/técnico), si el padre coincidió, mostrar todos
                    if not _folio_only and parent_match:
                        child.setHidden(False)
                    else:
                        child.setHidden(True)

            # El padre se muestra si él mismo o algún hijo coincide
            show_parent = parent_match or any_child_match
            parent_item.setHidden(not show_parent)

            # Si hay coincidencia y el padre está visible, expandir el grupo automáticamente
            if show_parent:
                if any_child_match or child_count > 0:
                    parent_item.setExpanded(True)
            else:
                parent_item.setExpanded(False)




    # =========================================================================
    # Roles y permisos
    # =========================================================================
    def _is_admin(self) -> bool:
        return _session_has_role("admin")

    def _is_admin_or_logistica(self) -> bool:
        return _session_has_role("admin", "logistica")

    # =========================================================================
    # Acciones sobre OS
    # =========================================================================
    def _quick_edit_os(self, os_id) -> None:
        if not os_id:
            return
        dlg = QuickEditOSDialog(os_id, self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            if dlg.save_data():
                try:
                    from services.pdf_router import regenerar_pdf
                    from database.connection import db_pool as _dbp
                    conn_r = _dbp.get_connection()
                    folio_os = None
                    try:
                        with conn_r.cursor() as cur_r:
                            cur_r.execute(
                                "SELECT folio_os FROM ordenes_servicio WHERE id = %s",
                                (os_id,)
                            )
                            r = cur_r.fetchone()
                            if r:
                                folio_os = r[0]
                        conn_r.commit()
                    finally:
                        _dbp.release_connection(conn_r)
                    if folio_os:
                        regenerar_pdf(os_id, folio_os, force=True)
                except Exception as pdf_exc:
                    logger.warning("No se pudo regenerar PDF post-QuickEdit: %s", pdf_exc)
                QTimer.singleShot(100, self.refresh)
            else:
                QMessageBox.warning(self, "Error", "No se pudo guardar la orden.")

    def _editar_actividad_os(self, os_id: int, folio: str) -> None:
        """Abre el diálogo de edición de actividad logística para la OS indicada."""
        if not os_id:
            return
        dlg = EditarActividadDialog(os_id, folio, self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            # Refrescar la tabla para mostrar la nueva fecha/técnico
            QTimer.singleShot(80, self.refresh)

    # =========================================================================
    # Helpers de selección múltiple (checkboxes)
    # =========================================================================

    def _place_header_checkbox(self, table: QTreeWidget) -> None:
        """Coloca el QCheckBox maestro dentro de la celda de cabecera col 0."""
        try:
            header = table.header()
            rect = header.sectionViewportPosition(self._COL_CHK)
            self._chk_all.setParent(header)
            self._chk_all.move(rect + 8, (header.height() - 16) // 2)
            self._chk_all.show()
        except Exception:
            pass

    def _on_tree_item_double_click(self, item: QTreeWidgetItem, col: int) -> None:
        """Doble clic en item del arbol: abre edicion si es fila individual."""
        os_id = item.data(self._COL_FOLIO, Qt.ItemDataRole.UserRole)
        if os_id:
            self._quick_edit_os(os_id)

    def _get_selected_rows(self) -> list[dict]:
        """Devuelve lista de {folio, os_id, has_pdf} de las filas marcadas sin duplicados (soporta lotes)."""
        seen_folios = set()
        selected = []

        def _collect(item: QTreeWidgetItem) -> None:
            w = self._table.itemWidget(item, self._COL_CHK)
            if w:
                chk = w.findChild(QCheckBox)
                if chk and chk.isChecked():
                    all_folios = chk.property("all_folios") or ([chk.property("folio")] if chk.property("folio") else [])
                    all_os_ids = chk.property("all_os_ids") or ([chk.property("os_id")] if chk.property("os_id") else [])
                    pdf_flags  = chk.property("pdf_flags")
                    if pdf_flags is None:
                        pdf_flags = [bool(chk.property("has_pdf"))] * len(all_folios)
                    for f, oid, hp in zip(all_folios, all_os_ids, pdf_flags):
                        f_str = str(f or "").strip()
                        if f_str and f_str not in seen_folios:
                            seen_folios.add(f_str)
                            selected.append({"folio": f_str, "os_id": oid, "has_pdf": bool(hp)})
            for i in range(item.childCount()):
                _collect(item.child(i))

        for idx in range(self._table.topLevelItemCount()):
            _collect(self._table.topLevelItem(idx))
        return selected

    def _on_chk_all_changed(self, state: int) -> None:
        """Selecciona / deselecciona todos los items visibles (padres e hijos)."""
        checked = (state == Qt.CheckState.Checked.value)
        self._table.blockSignals(True)

        def _toggle(item: QTreeWidgetItem) -> None:
            w = self._table.itemWidget(item, self._COL_CHK)
            if w:
                chk = w.findChild(QCheckBox)
                if chk:
                    chk.blockSignals(True)
                    chk.setChecked(checked)
                    chk.blockSignals(False)
            for i in range(item.childCount()):
                _toggle(item.child(i))

        for idx in range(self._table.topLevelItemCount()):
            _toggle(self._table.topLevelItem(idx))

        self._table.blockSignals(False)
        self._update_delete_btn_label()
        self._update_download_zip_btn()

    def _on_row_checkbox_changed(self) -> None:
        """Actualiza el contador del botón de borrado y descarga masiva al marcar/desmarcar filas."""
        self._update_delete_btn_label()
        self._update_download_zip_btn()

    def _update_download_zip_btn(self) -> None:
        """Actualiza el estado y texto del botón 'Descargar Selección (.zip / .rar)'."""
        if not hasattr(self, '_btn_descargar_zip'):
            return
        selected = self._get_selected_rows()
        with_pdf = [s for s in selected if s.get("has_pdf")]
        if with_pdf:
            self._btn_descargar_zip.setEnabled(True)
            self._btn_descargar_zip.setText(f"📦 Descargar Selección ({len(with_pdf)}) (.zip / .rar)")
            self._btn_descargar_zip.setToolTip(f"Descargar y empaquetar {len(with_pdf)} orden(es) con PDF disponible")
        else:
            self._btn_descargar_zip.setEnabled(False)
            if selected:
                self._btn_descargar_zip.setText("📦 Descargar Selección (.zip / .rar)")
                self._btn_descargar_zip.setToolTip("Ninguna de las órdenes seleccionadas tiene PDF disponible")
            else:
                self._btn_descargar_zip.setText("📦 Descargar Selección (.zip / .rar)")
                self._btn_descargar_zip.setToolTip("Selecciona al menos una orden con PDF para descargar en .zip / .rar")

    def _fetch_pdf_bytes_for_os(self, os_id, folio: str) -> bytes | None:
        """
        Obtiene los bytes del PDF de una OS buscando en orden:
        1. Archivo local en disco (services.pdf_router o carpetas estándar).
        2. Campo pdf_b64 en la base de datos PostgreSQL.
        3. Endpoint HTTP de Render: /api/v1/os/{folio}/pdf.
        Retorna bytes si tuvo éxito, o None si no se encontró.
        """
        import os as _os
        import base64
        import urllib.request
        from pathlib import Path

        clean_folio = str(folio or "").strip()
        if not clean_folio:
            return None

        # 1. Archivo local en disco
        try:
            from services.pdf_router import get_pdf_path
            loc_p = get_pdf_path(os_id, clean_folio)
            if loc_p and _os.path.exists(loc_p) and _os.path.getsize(loc_p) > 0:
                with open(loc_p, "rb") as f:
                    return f.read()
        except Exception:
            pass

        for search_dir in [
            _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', '..', 'PDFs'),
            _os.path.join(_os.path.expanduser('~'), 'Documents', 'PESA', 'PDFs'),
            r"C:\PesaServidorCentral\PDF_OS",
            _os.path.join(_os.path.expanduser('~'), 'PesaServidorLocal', 'PDF_OS'),
        ]:
            cand = Path(search_dir) / f"{clean_folio}.pdf"
            if cand.exists() and cand.stat().st_size > 0:
                try:
                    with open(cand, "rb") as f:
                        return f.read()
                except Exception:
                    pass

        # 2. Campo pdf_b64 en PostgreSQL
        if _DEPS_OK and _db_pool:
            try:
                conn = _db_pool.get_connection()
                pdf_b64 = None
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT pdf_b64 FROM ordenes_servicio WHERE folio_os = %s OR id = %s LIMIT 1",
                            (clean_folio, os_id)
                        )
                        row = cur.fetchone()
                        if row and row[0]:
                            pdf_b64 = row[0]
                    conn.commit()
                finally:
                    _db_pool.release_connection(conn)

                if pdf_b64:
                    raw = base64.b64decode(pdf_b64)
                    if len(raw) > 100:
                        return raw
            except Exception as exc_db:
                logger.debug("No se pudo obtener pdf_b64 para %s: %s", clean_folio, exc_db)

        # 3. HTTP GET desde Render API
        try:
            render_url = f"https://pesa-api-za9i.onrender.com/api/v1/os/{clean_folio}/pdf"
            req = urllib.request.Request(render_url, headers={"User-Agent": "PesaDesktop/1.0"})
            with urllib.request.urlopen(req, timeout=12) as resp:
                if resp.status == 200:
                    raw = resp.read()
                    if len(raw) > 100:
                        return raw
        except Exception as exc_render:
            logger.debug("No se pudo descargar PDF desde Render para %s: %s", clean_folio, exc_render)

        return None

    def _on_descargar_seleccion_zip(self) -> None:
        """
        Descarga por lotes las órdenes seleccionadas con PDF disponible,
        nombradas con el formato {FOLIO}-{ID_INDICADOR}.pdf (o {FOLIO}.pdf si no tiene indicador),
        y las empaqueta en un archivo .zip (o .rar si WinRAR está instalado).
        Muestra barra de progreso y al finalizar ofrece abrir la carpeta contenedora.
        """
        import os as _os
        import shutil
        import zipfile
        import tempfile
        import subprocess
        from datetime import date
        from PyQt6.QtWidgets import QApplication

        selected = self._get_selected_rows()
        valid_items = [s for s in selected if s.get("has_pdf")]
        if not valid_items:
            valid_items = selected
        if not valid_items:
            QMessageBox.warning(self, "Sin Selección", "No hay órdenes seleccionadas para descargar.")
            return

        today_str = date.today().isoformat()
        default_name = f"Ordenes_PESA_{today_str}.zip"

        dest_path, _ = QFileDialog.getSaveFileName(
            self,
            "Guardar archivo comprimido",
            default_name,
            "Archivo ZIP (*.zip);;Archivo RAR (*.rar);;Todos los archivos (*.*)"
        )
        if not dest_path:
            return

        is_rar = dest_path.lower().endswith(".rar")
        rar_bin = None
        if is_rar:
            for cand in [
                shutil.which("rar"),
                shutil.which("winrar"),
                r"C:\Program Files\WinRAR\Rar.exe",
                r"C:\Program Files\WinRAR\WinRAR.exe",
                r"C:\Program Files (x86)\WinRAR\Rar.exe",
                r"C:\Program Files (x86)\WinRAR\WinRAR.exe",
            ]:
                if cand and _os.path.exists(cand):
                    rar_bin = cand
                    break

        if is_rar and not rar_bin:
            dest_path = dest_path[:-4] + ".zip"
            is_rar = False

        total = len(valid_items)
        progress = QProgressDialog("Iniciando descarga por lotes...", "Cancelar", 0, total, self)
        progress.setWindowTitle("Descarga Masiva de Órdenes")
        progress.setWindowModality(Qt.WindowModality.WindowModal)
        progress.setMinimumDuration(0)
        progress.setValue(0)
        progress.show()
        QApplication.processEvents()

        temp_dir = tempfile.mkdtemp(prefix="pesa_lote_zip_")
        downloaded = []
        failed = []

        try:
            for idx, item in enumerate(valid_items):
                if progress.wasCanceled():
                    break
                folio = str(item.get("folio") or "").strip()
                os_id = item.get("os_id")
                progress.setLabelText(f"Descargando ({idx + 1}/{total}): {folio}...")
                progress.setValue(idx)
                QApplication.processEvents()

                pdf_bytes = self._fetch_pdf_bytes_for_os(os_id, folio)
                if pdf_bytes:
                    id_ind = self._get_id_indicador_for_os(os_id, folio)
                    if id_ind:
                        arc_name = f"{folio}-{id_ind}.pdf"
                    else:
                        arc_name = f"{folio}.pdf"

                    tmp_file = _os.path.join(temp_dir, arc_name)
                    with open(tmp_file, "wb") as f_out:
                        f_out.write(pdf_bytes)
                    downloaded.append((tmp_file, arc_name, folio))
                    self._marcar_auditada_admin(folio)
                else:
                    failed.append(folio)

            progress.setValue(total)
            progress.setLabelText("Empaquetando archivo comprimido...")
            QApplication.processEvents()

            if downloaded:
                if is_rar and rar_bin:
                    files_to_add = [p for p, _, _ in downloaded]
                    cmd = [rar_bin, "a", "-ep", dest_path] + files_to_add
                    subprocess.run(cmd, check=True)
                else:
                    if not dest_path.lower().endswith(".zip"):
                        dest_path += ".zip"
                    with zipfile.ZipFile(dest_path, "w", zipfile.ZIP_DEFLATED) as zf:
                        for tmp_file, arc_name, _ in downloaded:
                            zf.write(tmp_file, arcname=arc_name)

        except Exception as exc:
            logger.error("Error durante descarga por lotes: %s", exc)
            QMessageBox.critical(self, "Error de Empaquetado", f"Ocurrió un error al crear el archivo comprimido:\n{exc}")
            return
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)
            progress.close()

        if downloaded:
            msg_box = QMessageBox(self)
            msg_box.setWindowTitle("Descarga por Lotes Exitosa")
            msg_box.setIcon(QMessageBox.Icon.Information)
            msg_text = f"Se descargaron y empaquetaron {len(downloaded)} órdenes exitosamente en:\n\n{dest_path}\n"
            if failed:
                msg_text += f"\nNo se pudo encontrar el PDF de {len(failed)} orden(es):\n" + ", ".join(failed[:8])
            msg_box.setText(msg_text)
            btn_abrir = msg_box.addButton("Abrir Carpeta", QMessageBox.ButtonRole.ActionRole)
            btn_aceptar = msg_box.addButton("Aceptar", QMessageBox.ButtonRole.AcceptRole)
            msg_box.setDefaultButton(btn_abrir)
            msg_box.exec()

            if msg_box.clickedButton() == btn_abrir:
                folder = _os.path.dirname(_os.path.abspath(dest_path))
                try:
                    _os.startfile(folder)
                except Exception:
                    from PyQt6.QtGui import QDesktopServices
                    from PyQt6.QtCore import QUrl
                    QDesktopServices.openUrl(QUrl.fromLocalFile(folder))

            QTimer.singleShot(250, self.refresh)
        else:
            QMessageBox.warning(
                self, "Descarga no completada",
                "No se pudo descargar ningún PDF de las órdenes seleccionadas.\n"
                "Verifica que las órdenes estén concluidas y que la conexión esté activa."
            )

    def _update_delete_btn_label(self) -> None:
        """Actualiza el texto y estado del botón 'Eliminar seleccionados'."""
        if not hasattr(self, '_btn_eliminar_sel'):
            return
        n = len(self._get_selected_rows())
        if n > 0:
            self._btn_eliminar_sel.setText(f"🗑️  Eliminar ({n})")
            self._btn_eliminar_sel.setEnabled(True)
            self._btn_eliminar_sel.setVisible(True)
        else:
            self._btn_eliminar_sel.setText("Eliminar seleccionados")
            self._btn_eliminar_sel.setEnabled(False)
            # Mantener visible para admin para que el botón no "salte" la UI
            if self._is_admin():
                self._btn_eliminar_sel.setVisible(True)

    def _delete_single_os(self, os_id, folio_fallback: str = None) -> None:
        """Elimina una OS individual con cascada en tablas hijas y commit explícito.
        Acepta os_id (int) o folio_fallback (str) como identificador.
        """
        if not self._is_admin():
            return

        # ── Resolver identificador ────────────────────────────────────────────
        # os_id puede ser None cuando la fila viene de un lote físico sin id en el row.
        # En ese caso usamos folio_fallback para buscar el id en la BD.
        _resolved_id = None
        _folio_known = folio_fallback or None

        if os_id:
            try:
                _resolved_id = int(os_id)
            except (TypeError, ValueError):
                _resolved_id = None

        if _resolved_id is None and not _folio_known:
            QMessageBox.warning(self, "Sin ID",
                "No se pudo identificar la orden (ni ID ni folio disponible).")
            return

        resp = QMessageBox.warning(
            self, "⚠️  Eliminar Orden",
            "Esta acción es IRREVERSIBLE.\n\n"
            "¿Desea eliminar permanentemente esta orden de servicio?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        # Tablas hijas — SAVEPOINT permite ignorar las que no existen
        _CHILD_TABLES = [
            ("adjuntos_os",      "id_os"),
            ("det_excentricidad", "id_os"),
            ("det_repetibilidad", "id_os"),
            ("det_exactitud",     "id_os"),
            ("historial_ordenes", "id_os"),
            ("historial_os",      "id_os"),
            ("folio_locks",       "folio_os"),   # referencia por texto
        ]
        conn = None
        try:
            conn = _db_pool.get_connection()   # API correcta del DatabasePool
            with conn.cursor() as cur:
                # Si no tenemos id, buscarlo por folio
                if _resolved_id is None:
                    cur.execute(
                        "SELECT id, folio_os FROM ordenes_servicio WHERE folio_os = %s",
                        (_folio_known,)
                    )
                    row = cur.fetchone()
                    if not row:
                        QMessageBox.warning(self, "No encontrada",
                            f"No existe ninguna orden con folio '{_folio_known}'.")
                        return
                    _resolved_id = row[0]
                    _folio_known = row[1]
                else:
                    cur.execute(
                        "SELECT folio_os FROM ordenes_servicio WHERE id = %s",
                        (_resolved_id,)
                    )
                    frow = cur.fetchone()
                    _folio_known = frow[0] if frow else _folio_known

                # ── BORRADO EN CASCADA ─────────────────────────────────────
                # Si _resolved_id sigue None (no encontrado por folio en BD)
                # abortar con mensaje cláro — evita 'id=None' confuso.
                if _resolved_id is None and not _folio_known:
                    QMessageBox.warning(self, "No encontrada",
                        "No se pudo determinar el identificador de la orden.\n"
                        "Intenta refrescar el dashboard e intentarlo de nuevo.")
                    return

                for tabla, col in _CHILD_TABLES:
                    sp = f"sp_{tabla[:20]}"
                    try:
                        cur.execute(f"SAVEPOINT {sp}")
                        val = _resolved_id if col == "id_os" else _folio_known
                        if val:
                            cur.execute(f"DELETE FROM {tabla} WHERE {col} = %s", (val,))
                        cur.execute(f"RELEASE SAVEPOINT {sp}")
                    except Exception:
                        try: cur.execute(f"ROLLBACK TO SAVEPOINT {sp}")
                        except Exception: pass

                # DELETE principal: preferir por id, pero usar folio como fallback
                if _resolved_id is not None:
                    cur.execute("DELETE FROM ordenes_servicio WHERE id = %s",
                                (_resolved_id,))
                else:
                    # Fallback: borrar por folio_os (es único en la tabla)
                    cur.execute("DELETE FROM ordenes_servicio WHERE folio_os = %s",
                                (_folio_known,))
                rows = cur.rowcount
            conn.commit()
            logger.info("[DELETE] OS id=%s folio=%s eliminada (%d)",
                        _resolved_id, _folio_known, rows)
            if rows == 0:
                QMessageBox.warning(self, "Sin resultado",
                    f"No se encontró la orden '{_folio_known}'. "
                    "Es posible que ya estuviera eliminada.")
            else:
                QMessageBox.information(self, "Listo",
                    f"Orden {_folio_known or _resolved_id} eliminada correctamente.")
            QTimer.singleShot(100, self.refresh)
        except Exception as e:
            if conn:
                try: conn.rollback()
                except Exception: pass
            logger.error("Error eliminando OS id=%s folio=%s: %s",
                         _resolved_id, _folio_known, e)
            QMessageBox.critical(self, "Error al eliminar",
                                 f"No se pudo eliminar la orden:\n\n{e}")
        finally:
            if conn:
                try: _db_pool.release_connection(conn)   # API correcta
                except Exception: pass

    def _cambiar_modalidad_os(self, os_id: int, nueva_modalidad: str) -> None:
        """Cambia la modalidad (Físico / Digital) de una OS individual (solo admin)."""
        if not self._is_admin() or not os_id:
            return
        etiqueta = "Físico (impresión manual)" if nueva_modalidad.upper() == "FISICO" \
                   else "Digital (captura en tablet)"
        resp = QMessageBox.question(
            self, "Cambiar Modalidad",
            f"¿Cambiar esta orden a modalidad {etiqueta}?\n\n"
            "Si se cambia a Digital, la tablet podrá descargarla en la próxima sincronización.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return
        try:
            with _db_pool.transaction() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE ordenes_servicio
                           SET modalidad    = %s,
                               sync_status  = 'PENDIENTE',
                               updated_at   = NOW()
                         WHERE id = %s
                        """,
                        (nueva_modalidad, os_id),
                    )
                    logger.info("[ADMIN] Modalidad OS id=%s → %s", os_id, nueva_modalidad)
            QMessageBox.information(
                self, "Listo",
                f"Modalidad actualizada a {nueva_modalidad}.\n"
                "La tablet la descargará en la próxima sincronización."
            )
            QTimer.singleShot(100, self.refresh)
        except Exception as e:
            logger.error("Error cambiando modalidad OS %s: %s", os_id, e)
            QMessageBox.critical(self, "Error", f"No se pudo cambiar la modalidad:\n{e}")

    def _on_delete_selected(self) -> None:
        """Elimina en lote las OS marcadas con checkbox (solo admin)."""
        if not self._is_admin():
            return

        seleccionados = self._get_selected_rows()
        if not seleccionados:
            QMessageBox.information(self, "Sin selección",
                                    "Marca al menos un registro para eliminar.")
            return

        n = len(seleccionados)
        folios_str = "\n".join(f"  • {s['folio']}" for s in seleccionados[:20])
        if n > 20:
            folios_str += f"\n  … y {n - 20} más"

        resp = QMessageBox.warning(
            self, "⚠️  Confirmar eliminación",
            f"¿Estás seguro de eliminar {n} formato(s) seleccionado(s)?\n\n"
            f"{folios_str}\n\n"
            "Esta acción:\n"
            "  • Eliminará los registros de la base de datos\n"
            "  • Borrará los archivos PDF generados del disco\n"
            "  • Ajustará el consecutivo de folio si corresponde\n\n"
            "Esta acción es IRREVERSIBLE.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        os_ids  = [s["os_id"]  for s in seleccionados if s["os_id"]]
        folios  = [s["folio"]  for s in seleccionados if s["folio"]]
        errores = []

        # ── 1. Borrar archivos PDF del disco ─────────────────────────────────
        import os as _os, pathlib
        _PDF_DIRS = [
            pathlib.Path(r"C:\PesaServidorCentral\PDF_OS"),
            pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS",
        ]
        for folio in folios:
            for pdf_dir in _PDF_DIRS:
                pdf_path = pdf_dir / f"{folio}.pdf"
                try:
                    if pdf_path.exists():
                        pdf_path.unlink()
                        logger.info("[DELETE] PDF eliminado: %s", pdf_path)
                except Exception as exc:
                    logger.warning("[DELETE] No se pudo borrar %s: %s", pdf_path, exc)

        # ── 2. Eliminar de la BD (dentro de una transacción atómica) ─────────
        if os_ids:
            try:
                with _db_pool.transaction() as conn:
                    with conn.cursor() as cur:

                        # 2a. Adjuntos — SAVEPOINT para no abortar si la tabla no existe
                        cur.execute("SAVEPOINT sp_adj")
                        try:
                            cur.execute(
                                "DELETE FROM adjuntos_os WHERE id_os = ANY(%s)",
                                (os_ids,)
                            )
                            cur.execute("RELEASE SAVEPOINT sp_adj")
                        except Exception as exc_adj:
                            cur.execute("ROLLBACK TO SAVEPOINT sp_adj")
                            logger.warning("[DELETE] adjuntos_os omitido: %s", exc_adj)

                        # 2b. Órdenes de servicio — sentencia principal
                        cur.execute(
                            "DELETE FROM ordenes_servicio WHERE id = ANY(%s)",
                            (os_ids,)
                        )
                        deleted = cur.rowcount
                        logger.info("[DELETE] %d fila(s) eliminadas de ordenes_servicio", deleted)

                        # 2c. Ajuste del consecutivo de folio ─────────────────
                        cur.execute("SAVEPOINT sp_folio")
                        try:
                            import datetime as _dt
                            anio = _dt.date.today().year
                            prefix = f"OS-{str(anio)[2:]}-"
                            consec_borrados = []
                            for f in folios:
                                if f.startswith(prefix):
                                    try:
                                        consec_borrados.append(int(f[len(prefix):]))
                                    except ValueError:
                                        pass

                            if consec_borrados:
                                min_borrado = min(consec_borrados)
                                cur.execute(
                                    """
                                    SELECT COALESCE(MAX(consecutivo), 0)
                                    FROM ordenes_servicio
                                    WHERE tipo_documento = 'OS'
                                      AND consecutivo IS NOT NULL
                                    """
                                )
                                max_restante = cur.fetchone()[0] or 0
                                nuevo_consec = max(max_restante, min_borrado - 1)
                                cur.execute(
                                    """
                                    INSERT INTO control_folios
                                        (tipo_documento, anio, ultimo_consecutivo)
                                    VALUES ('OS', %s, %s)
                                    ON CONFLICT (tipo_documento, anio)
                                    DO UPDATE SET ultimo_consecutivo =
                                        LEAST(control_folios.ultimo_consecutivo,
                                              EXCLUDED.ultimo_consecutivo)
                                    """,
                                    (anio, nuevo_consec),
                                )
                                logger.info(
                                    "[DELETE] Consecutivo ajustado a %d "
                                    "(mín. borrado: %d)",
                                    nuevo_consec, min_borrado
                                )
                            cur.execute("RELEASE SAVEPOINT sp_folio")
                        except Exception as exc_cf:
                            cur.execute("ROLLBACK TO SAVEPOINT sp_folio")
                            logger.warning(
                                "[DELETE] No se pudo ajustar control_folios: %s",
                                exc_cf
                            )
                # -- transaction() hace commit automático al salir sin excepción --
                logger.info("[DELETE] COMMIT OK — eliminadas %d OS: %s",
                            len(os_ids), folios)

            except Exception as exc:
                logger.error("[DELETE] Error al eliminar lote: %s", exc)
                errores.append(str(exc))

        # ── 4. Refrescar tabla y notificar ───────────────────────────────────
        QTimer.singleShot(150, self.refresh)

        if errores:
            QMessageBox.critical(
                self, "Error parcial",
                f"Se eliminaron {n - len(errores)} de {n} registros.\n\n"
                f"Errores:\n" + "\n".join(errores)
            )
        else:
            QMessageBox.information(
                self, "✅ Eliminación completada",
                f"Se eliminaron correctamente {n} formato(s):\n\n{folios_str}"
            )

    def _marcar_auditada_admin(self, folio: str) -> None:
        """
        Marca en segundo plano una orden como AUDITADA_ADMIN (Doble palomita verde)
        en PostgreSQL central y actualiza el QTreeWidget localmente de inmediato.
        """
        clean_folio = str(folio or "").strip()
        if not clean_folio:
            return

        def _do_update():
            if _DEPS_OK and _db_pool:
                try:
                    conn = _db_pool.get_connection()
                    try:
                        with conn.cursor() as cur:
                            cur.execute(
                                """
                                UPDATE ordenes_servicio
                                SET sync_check_status = 'AUDITADA_ADMIN',
                                    fecha_apertura_admin = COALESCE(fecha_apertura_admin, NOW()),
                                    pdf_descargado = TRUE,
                                    auditoria_digital = 'Recibido'
                                WHERE folio_os = %s
                                """,
                                (clean_folio,)
                            )
                        conn.commit()
                    finally:
                        _db_pool.release_connection(conn)
                    logger.info("[AUDIT ADMIN] OS %s marcada como AUDITADA_ADMIN en BD central", clean_folio)
                except Exception as exc:
                    logger.warning("[AUDIT ADMIN] Error al actualizar AUDITADA_ADMIN en BD: %s", exc)

            # Notificar al endpoint de auditoría de Render
            try:
                import urllib.request
                url = f"https://pesa-api-za9i.onrender.com/api/v1/os/{clean_folio}/auditar"
                req = urllib.request.Request(
                    url, data=b"", method="POST",
                    headers={"User-Agent": "PesaWindowsERP/1.0", "Content-Type": "application/json"}
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    pass
            except Exception:
                pass

        import threading
        threading.Thread(target=_do_update, daemon=True).start()

        # Actualización visual reactiva inmediata en la tabla
        try:
            for i in range(self._table.topLevelItemCount()):
                p_item = self._table.topLevelItem(i)
                if not p_item:
                    continue
                f_text = p_item.text(self._COL_FOLIO)
                if clean_folio in f_text:
                    p_item.setData(self._COL_SYNC, Qt.ItemDataRole.UserRole, "AUDITADA_ADMIN")
                    p_item.setData(self._COL_SYNC, Qt.ItemDataRole.DisplayRole, "AUDITADA_ADMIN")
                    p_item.setToolTip(self._COL_SYNC, "✓✓ Verde — Abierto por Administración / Oficina en Windows")
                for j in range(p_item.childCount()):
                    c_item = p_item.child(j)
                    if c_item and c_item.text(self._COL_FOLIO).strip() == clean_folio:
                        c_item.setData(self._COL_SYNC, Qt.ItemDataRole.UserRole, "AUDITADA_ADMIN")
                        c_item.setData(self._COL_SYNC, Qt.ItemDataRole.DisplayRole, "AUDITADA_ADMIN")
                        c_item.setToolTip(self._COL_SYNC, "✓✓ Verde — Abierto por Administración / Oficina en Windows")
            self._table.viewport().update()
        except Exception as e_vis:
            logger.debug("[AUDIT ADMIN] Error actualizando vista QTreeWidget: %s", e_vis)

    def _download_and_open_pdf_from_render(self, folio_str: str) -> bool:
        """
        Descarga el PDF de la orden directamente desde Render vía HTTP GET,
        o lo recupera de la base de datos central PostgreSQL (pdf_b64),
        lo almacena en %TEMP%/Pesa_PDFs/{folio}.pdf y lo abre con el visor predeterminado.
        """
        import os
        import sys
        import subprocess
        import pathlib
        import tempfile
        import urllib.request
        import base64

        def _open_file(path: str) -> None:
            try:
                if sys.platform == "win32":
                    os.startfile(path)
                elif sys.platform == "darwin":
                    subprocess.run(["open", path], check=False)
                else:
                    subprocess.run(["xdg-open", path], check=False)
                self._marcar_auditada_admin(clean_folio)
            except Exception as exc:
                logger.warning("_open_file: error abriendo %s: %s", path, exc)

        clean_folio = folio_str.strip()
        if not clean_folio:
            return False

        # Directorio temporal especificado: %TEMP%/Pesa_PDFs
        temp_dir = pathlib.Path(tempfile.gettempdir()) / "Pesa_PDFs"
        temp_dir.mkdir(parents=True, exist_ok=True)
        target_path = temp_dir / f"{clean_folio}.pdf"

        # 1. Estrategia: Base de datos PostgreSQL central (pdf_b64)
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT pdf_b64 FROM ordenes_servicio WHERE folio_os = %s",
                        (clean_folio,)
                    )
                    row_b64 = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)

            if row_b64 and row_b64[0]:
                pdf_bytes = base64.b64decode(row_b64[0])
                if len(pdf_bytes) > 500:
                    target_path.write_bytes(pdf_bytes)
                    logger.info("PDF obtenido desde PostgreSQL (pdf_b64) → %s", target_path)
                    _open_file(str(target_path))
                    return True
        except Exception as exc_db:
            logger.warning("Error leyendo pdf_b64 de BD para %s: %s", clean_folio, exc_db)

        # 2. Estrategia: Descarga HTTP GET directa desde la API de Render
        render_endpoints = [
            f"https://pesa-api-za9i.onrender.com/api/v1/ordenes/{clean_folio}/download-pdf",
            f"https://pesa-api-za9i.onrender.com/api/v1/os/{clean_folio}/pdf",
            f"https://pesa-api-za9i.onrender.com/api/v1/ordenes/{clean_folio}/pdf",
            f"https://pesa-api-za9i.onrender.com/api/v1/os/{clean_folio}/download-pdf",
            f"https://pesa-api-za9i.onrender.com/uploads/{clean_folio}.pdf",
        ]
        for url in render_endpoints:
            try:
                logger.info("Descargando PDF desde Render: %s", url)
                req = urllib.request.Request(
                    url,
                    headers={"User-Agent": "PesaWindowsApp/1.0", "Accept": "application/pdf"}
                )
                with urllib.request.urlopen(req, timeout=12) as resp:
                    if resp.status == 200:
                        content = resp.read()
                        if len(content) > 500:
                            target_path.write_bytes(content)
                            logger.info("✅ PDF descargado exitosamente de Render → %s", target_path)
                            _open_file(str(target_path))
                            return True
            except Exception as exc_http:
                logger.debug("Fallo descarga HTTP desde %s: %s", url, exc_http)

        # 3. Estrategia: Adjunto escaneado en BD
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT adj.ruta_completa
                        FROM adjuntos_os adj
                        JOIN ordenes_servicio os ON adj.id_os = os.id
                        WHERE os.folio_os = %s
                        ORDER BY adj.fecha_adjunto DESC LIMIT 1
                        """,
                        (clean_folio,)
                    )
                    row_adj = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)

            if row_adj and row_adj[0] and pathlib.Path(row_adj[0]).exists():
                logger.info("Usando adjunto escaneado: %s", row_adj[0])
                _open_file(row_adj[0])
                return True
        except Exception as exc_adj:
            logger.debug("No se pudo leer adjunto: %s", exc_adj)

        # 4. Estrategia: Archivos locales en disco (carpetas de red)
        _pdf_dirs = [
            pathlib.Path(r"C:\PesaServidorCentral\PDF_OS"),
            pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS",
            pathlib.Path(tempfile.gettempdir()),
        ]
        for pdir in _pdf_dirs:
            cand = pdir / f"{clean_folio}.pdf"
            if cand.exists() and cand.stat().st_size > 500:
                logger.info("PDF encontrado en disco local: %s", cand)
                _open_file(str(cand))
                return True

        # 5. Si ya existía un archivo en target_path con contenido válido
        if target_path.exists() and target_path.stat().st_size > 500:
            logger.info("Abriendo PDF en caché local previa: %s", target_path)
            _open_file(str(target_path))
            return True

        return False

    def _open_pdf(self, os_id_or_folio) -> None:
        """
        Abre el PDF de una OS descargándolo desde Render vía HTTP GET a %TEMP%/Pesa_PDFs,
        o consultando la base de datos central PostgreSQL.
        """
        folio_os = None
        if isinstance(os_id_or_folio, str) and os_id_or_folio.strip():
            folio_os = os_id_or_folio.strip()
        elif os_id_or_folio:
            try:
                conn = _db_pool.get_connection()
                try:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT folio_os FROM ordenes_servicio WHERE id = %s",
                            (os_id_or_folio,)
                        )
                        row = cur.fetchone()
                        if row:
                            folio_os = row[0]
                    conn.commit()
                finally:
                    _db_pool.release_connection(conn)
            except Exception as exc:
                logger.warning("_open_pdf: error leyendo folio_os: %s", exc)

        if not folio_os:
            QMessageBox.warning(self, "Error", "No se pudo determinar el folio de la orden.")
            return

        folio_limpio = folio_os.strip()
        if self._download_and_open_pdf_from_render(folio_limpio):
            return

        QMessageBox.warning(
            self, "Archivo no encontrado",
            f"No se encontró el archivo PDF para el folio:\n\n"
            f"  {folio_limpio}\n\n"
            f"No está disponible en la nube (Render) ni en almacenamiento local.\n\n"
            f"Si el técnico ya cerró la orden desde la tablet,\n"
            f"pídele que sincronice (presione 'Sincronizar' en la tablet)."
        )



    # =========================================================================
    # Eventos de la tabla
    # =========================================================================
    def _on_table_context_menu(self, pos: QPoint) -> None:
        item = self._table.itemAt(pos)
        if not item:
            return
        os_id = item.data(self._COL_FOLIO, Qt.ItemDataRole.UserRole)
        if not os_id:
            return

        menu = QMenu(self)
        menu.setStyleSheet("""
            QMenu {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 8px;
                padding: 4px;
                font-size: 9pt;
            }
            QMenu::item { padding: 7px 16px; border-radius: 4px; color: #1D1D1F; }
            QMenu::item:selected { background: #F5F5F7; }
        """)
        if self._is_admin_or_logistica():
            act_edit = QAction("Editar registro", self)
            act_edit.triggered.connect(lambda: self._quick_edit_os(os_id))
            menu.addAction(act_edit)
        if self._is_admin():
            act_del = QAction("Eliminar permanentemente", self)
            act_del.triggered.connect(lambda: self._delete_single_os(os_id))
            menu.addAction(act_del)
        menu.exec(self._table.viewport().mapToGlobal(pos))

    def _on_row_double_click(self, index) -> None:
        """Doble-clic (legacy para compatibilidad). Delegado a _on_tree_item_double_click."""
        pass  # El QTreeWidget usa itemDoubleClicked -> _on_tree_item_double_click

    def _on_tree_item_double_click_full(self, item: QTreeWidgetItem, col: int) -> None:
        """Doble-clic en item del arbol: abre PDF (fisico) o formulario (digital)."""
        os_id = item.data(self._COL_FOLIO, Qt.ItemDataRole.UserRole)
        if not os_id:
            return

        folio     = item.text(self._COL_FOLIO).strip()
        modalidad = item.text(self._COL_MODAL)

        if folio.startswith("LP-"):
            self.lp_selected.emit(int(os_id))
            return

        if modalidad.upper() == "DIGITAL":
            self.os_selected.emit(int(os_id))
        else:
            try:
                import pathlib
                candidates = [
                    pathlib.Path(r"C:\PesaServidorCentral\PDF_OS") / f"{folio}.pdf",
                    pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS" / f"{folio}.pdf",
                ]
                pdf_path = next((p for p in candidates if p.exists()), None)
                if pdf_path:
                    import subprocess, sys
                    if sys.platform == "win32":
                        subprocess.Popen(["start", "", str(pdf_path)], shell=True)
                    else:
                        subprocess.Popen(["xdg-open", str(pdf_path)])
                else:
                    self.os_selected.emit(int(os_id))
            except Exception as exc:
                logger.warning("Error abriendo PDF para OS %s: %s", folio, exc)
                self.os_selected.emit(int(os_id))

    # =========================================================================
    # Navegacion
    # =========================================================================
    def _navigate_to(self, key: str) -> None:
        """Emite la senal navegar_a para que MainWindow cambie de modulo."""
        self.navegar_a.emit(key)

    # =========================================================================
    # Compatibilidad con MainWindow (metodos publicos heredados)
    # =========================================================================
    def get_active_table(self):
        """Retorna la tabla activa (compatibilidad con MainWindow)."""
        return self._table if hasattr(self, "_table") else None
