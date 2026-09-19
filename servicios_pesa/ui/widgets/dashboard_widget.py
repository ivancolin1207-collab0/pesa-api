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
    QHeaderView, QScrollArea, QSizePolicy, QAbstractItemView,
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
_RED      = "#C8102E"   # Rojo corporativo PESA
_RED2     = "#A50D25"   # Rojo hover
_BORDER   = "#E5E5EA"   # Borde por defecto
_SEP      = "#F2F2F7"   # Separador ultra fino
_SEG_BG   = "#E5E5EA"   # Fondo segmented control


# =============================================================================
# Delegate para badges de estado (pintado directo con QPainter)
# =============================================================================
class StatusBadgeDelegate(QStyledItemDelegate):
    """Pinta badges tipo 'pill' redondeados para columnas de estado."""

    # Tabla de colores por valor de texto (lower)
    _BADGE_MAP = {
        # Modalidad
        "fisico":    ("#F2F2F7", "#475569"),
        "digital":   ("#EFF6FF", "#1D4ED8"),
        # Estado
        "proceso":   ("#FEF3C7", "#92400E"),
        "cerrado":   ("#DCFCE7", "#166534"),
        "cerrada":   ("#DCFCE7", "#166534"),   # nuevo — estado canónico digital
        "escaneada": ("#DCFCE7", "#166534"),
        "completada":("#DCFCE7", "#166534"),
        "completada_digital": ("#DCFCE7", "#166534"),
        "cancelada": ("#FEE2E2", "#991B1B"),
        # Sync
        "sincronizado": ("#DCFCE7", "#166534"),
        "pendiente":    ("#FEF3C7", "#92400E"),
        "synced":       ("#DCFCE7", "#166534"),
        "pending":      ("#FEF3C7", "#92400E"),
        # Tipos de servicio
        "calibracion":  ("#DCFCE7", "#166534"),
        "ajuste":       ("#FEF3C7", "#92400E"),
        "inspeccion":   ("#EFF6FF", "#1D4ED8"),
        "revision":     ("#F2F2F7", "#475569"),
        "refacciones":  ("#F2F2F7", "#475569"),
        "levantamiento":("#F2F2F7", "#475569"),
    }

    def _resolve_colors(self, text: str):
        lower = text.lower().strip()
        # Busqueda exacta primero
        if lower in self._BADGE_MAP:
            return self._BADGE_MAP[lower]
        # Busqueda parcial
        for key, colors in self._BADGE_MAP.items():
            if key in lower:
                return colors
        return ("#F2F2F7", "#636366")

    def _abbreviate(self, text: str) -> str:
        """Abrevia textos largos para que quepan en el badge."""
        abbr = {
            "Entrega Refacciones": "Refacciones",
            "Calibracion + Ajuste": "Calib+Ajuste",
            "Inspeccion Visual":   "Inspeccion",
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
        bg_hex, fg_hex = self._resolve_colors(display)
        bg_color = QColor(bg_hex)
        fg_color = QColor(fg_hex)

        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Fondo de la celda (hover / selected)
        if option.state & QStyle.StateFlag.State_Selected:
            painter.fillRect(option.rect, QColor(200, 16, 46, 12))
        elif option.state & QStyle.StateFlag.State_MouseOver:
            painter.fillRect(option.rect, QColor(0, 0, 0, 5))

        padding_h = 8
        padding_v = 3
        margin    = 6

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
            4.0, 4.0
        )
        painter.fillPath(path, QBrush(bg_color))

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
        h = fm.height() + 10
        return QSize(w, h)


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
    Tarjeta KPI minimalista estilo Apple.
    Fondo blanco, etiqueta superior gris, numero principal en 22pt.
    Sin barras laterales de colores.
    """

    def __init__(self, title: str, value: str, subtitle: str = "", parent=None):
        super().__init__(parent)
        self.setObjectName("kpi_card")
        self.setStyleSheet("""
            QFrame#kpi_card {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 10px;
            }
        """)

        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(10)
        shadow.setOffset(0, 2)
        shadow.setColor(QColor(0, 0, 0, 12))
        self.setGraphicsEffect(shadow)

        self.setMinimumSize(140, 88)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(16, 14, 16, 14)
        lay.setSpacing(4)

        # Etiqueta superior gris
        lbl_title = QLabel(title.upper())
        lbl_title.setStyleSheet(
            "font-size: 8pt; font-weight: 600; color: #86868B; "
            "letter-spacing: 0.5px; background: transparent;"
        )
        lay.addWidget(lbl_title)

        # Numero principal
        self.lbl_value = QLabel(value)
        self.lbl_value.setStyleSheet(
            "font-size: 22pt; font-weight: 700; color: #1D1D1F; "
            "letter-spacing: -0.5px; background: transparent;"
        )
        lay.addWidget(self.lbl_value)

        # Subtitulo / contexto
        if subtitle:
            lbl_sub = QLabel(subtitle)
            lbl_sub.setStyleSheet(
                "font-size: 8pt; color: #86868B; font-weight: 400; background: transparent;"
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
            rows_dicts = _sync_manager.get_local_orders(
                fecha_desde=fd, fecha_hasta=fh,
                id_tecnico=self._id_tecnico,
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
        fd, fh = self._fd, self._fh
        if fd and fh:
            date_cond = "os.fecha >= DATE_TRUNC('month', CURRENT_DATE) AND os.fecha < (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month')"
            params = []
        else:
            date_cond = "1=1"
            params = []

        # RBAC: técnicos de campo solo ven sus propias OS en los contadores
        _FULL_ACCESS = {"admin", "logistica", "recepcion"}
        rbac_cond = ""
        if not (self._roles & _FULL_ACCESS):
            if (("servicio" in self._roles or "calibrador" in self._roles
                    or "inspector" in self._roles) and self._id_tecnico):
                rbac_cond = f" AND os.id_tecnico = {int(self._id_tecnico)}"

        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT
                    COUNT(os.id)                                                                AS total_periodo,
                    COUNT(CASE WHEN os.estado ILIKE '%%proceso%%' THEN 1 END)                   AS en_proceso,
                    COUNT(CASE WHEN os.estado ILIKE '%%cerrad%%' OR os.estado ILIKE '%%finaliz%%'
                               OR os.estado IN ('ESCANEADA','COMPLETADA','COMPLETADA_DIGITAL')
                               THEN 1 END)                                                      AS cerrados,
                    COUNT(CASE WHEN os.modalidad ILIKE '%%fisic%%' THEN 1 END)                  AS formatos_fisicos
                FROM ordenes_servicio os
                WHERE {date_cond}{rbac_cond}
            """)
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
        # por filas duplicadas en catálogos (cat_tipo_instrumento, etc.)
        sql = f"""
            SELECT DISTINCT ON (os.id)
                os.folio_os,
                os.fecha::text,
                cl.razon_social,
                COALESCE(
                    NULLIF(TRIM(suc.nombre_sucursal || ' — ' || suc.direccion), ' — '),
                    NULLIF(TRIM(suc.nombre_sucursal), ''),
                    NULLIF(TRIM(os.ubicacion), ''),
                    NULLIF(TRIM(cl.direccion || ', ' || cl.municipio || ', ' || cl.estado_rep), ', , '),
                    NULLIF(TRIM(cl.direccion), ''),
                    NULLIF(TRIM(cl.municipio || ', ' || cl.estado_rep), ', '),
                    cl.razon_social
                ),
                tc.nombre_completo,
                COALESCE(ts.nombre, os.tipo_servicio),
                os.modalidad,
                os.estado,
                os.id,
                os.id_lote,
                CASE WHEN adj.id IS NOT NULL THEN TRUE ELSE FALSE END AS tiene_adjunto,
                COALESCE(os.sync_status, 'SYNCED')                    AS sync_status,
                os.rango_lote,
                COALESCE(ti.nombre, '')          AS tipo_instrumento,
                COALESCE(os.marca, '')                                AS marca,
                COALESCE(os.modelo, '')                               AS modelo
            FROM ordenes_servicio os
            LEFT JOIN cat_clientes       cl  ON os.id_cliente       = cl.id
            LEFT JOIN cat_tecnicos       tc  ON os.id_tecnico       = tc.id
            LEFT JOIN cat_tipo_servicio  ts  ON os.id_tipo_servicio = ts.id
            LEFT JOIN cliente_sucursales suc ON os.sucursal_id      = suc.id
            LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
            LEFT JOIN LATERAL (
                SELECT id FROM adjuntos_os WHERE id_os = os.id LIMIT 1
            ) adj ON TRUE
            WHERE 1=1 {{where_clause}}
            ORDER BY os.id, os.id_lote NULLS LAST, os.fecha DESC, os.created_at DESC
            LIMIT 500
        """.format(where_clause=where_clause)
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params or None)
                rows = list(cur.fetchall())
        except Exception as e:
            logger.warning("Query principal fallo, aplicando fallback: %s", e)
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
                ORDER BY os.fecha DESC, os.created_at DESC
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

    # -- Indices de columna de la QTableWidget (0-based) ----------------------
    # Col 0: Folio
    # Col 1: Fecha

    # Col 2: Cliente
    # Col 3: Sucursal / Planta
    # Col 4: Tecnico Asignado
    # Col 5: Tipo de Servicio
    # Col 6: Modalidad
    # Col 7: Estatus
    # Col 8: Sync
    # Col 9: Acciones
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
    _COL_ACCIONES = 10

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
        self._inner_lay.setContentsMargins(28, 22, 28, 28)
        self._inner_lay.setSpacing(14)

        # 1. Header de bienvenida
        self._inner_lay.addWidget(self._build_header())

        # 2. Barra de filtros unificada
        self._inner_lay.addWidget(self._build_filter_bar())

        # 3. KPI Cards (4 tarjetas)
        kpi_row = QHBoxLayout()
        kpi_row.setSpacing(12)
        self._card_total     = KPICard("Total Periodo",      "--", subtitle="del periodo seleccionado")
        self._card_proceso   = KPICard("En Proceso",         "--", subtitle="activos actualmente")
        self._card_cerrados  = KPICard("Cerrados",           "--", subtitle="finalizados")
        self._card_fisicos   = KPICard("Formatos Fisicos",   "--", subtitle="pendientes de escanear")
        for card in [self._card_total, self._card_proceso,
                     self._card_cerrados, self._card_fisicos]:
            kpi_row.addWidget(card)
        self._inner_lay.addLayout(kpi_row)

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
            "font-size: 20pt; font-weight: 700; color: #1D1D1F; "
            "letter-spacing: -0.3px; background: transparent;"
        )
        col.addWidget(lbl_title)

        sub_text = "Ordenes de Servicio, Remisiones, Revisiones y Levantamientos"
        if self._rbac_filter == "calibrador":
            sub_text = "OS con componente de Calibracion asignadas o completadas."
        elif self._rbac_filter == "inspector":
            sub_text = "OS con componente de Inspeccion asignadas o completadas."
        lbl_sub = QLabel(sub_text)
        lbl_sub.setStyleSheet(
            "font-size: 10pt; color: #86868B; background: transparent;"
        )
        col.addWidget(lbl_sub)

        lay.addLayout(col)
        lay.addStretch()

        # Boton Sincronizar (secundario)
        role = ""
        if _HAS_SESSION and session and session.is_authenticated:
            role = getattr(session, "role", "")

        btn_sync_header = QPushButton("Sincronizar")
        btn_sync_header.setObjectName("btn_sync_header")
        btn_sync_header.setFixedHeight(34)
        btn_sync_header.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_sync_header.setStyleSheet("""
            QPushButton {
                background: #FFFFFF;
                color: #1D1D1F;
                border: 1px solid #E5E5EA;
                border-radius: 7px;
                font-size: 10pt;
                font-weight: 500;
                padding: 0 16px;
            }
            QPushButton:hover { background: #F5F5F7; border-color: #C7C7CC; }
            QPushButton:pressed { background: #E5E5EA; }
        """)
        btn_sync_header.clicked.connect(self._on_sync_clicked)
        lay.addWidget(btn_sync_header)

        # Boton primario [+ Nuevo Documento] con menu desplegable
        if role in ("admin", "logistica", ""):
            self.btn_nueva_os = QPushButton("+ Nuevo Documento")
            self.btn_nueva_os.setFixedHeight(34)
            self.btn_nueva_os.setCursor(Qt.CursorShape.PointingHandCursor)
            self.btn_nueva_os.setStyleSheet(f"""
                QPushButton {{
                    background: {_RED};
                    color: #FFFFFF;
                    border: none;
                    border-radius: 7px;
                    font-size: 10pt;
                    font-weight: 600;
                    padding: 0 16px;
                }}
                QPushButton:hover {{ background: {_RED2}; }}
                QPushButton::menu-indicator {{ image: none; width: 0px; }}
            """)
            menu = QMenu(self.btn_nueva_os)
            menu.setStyleSheet("""
                QMenu {
                    background: #FFFFFF;
                    border: 1px solid #E5E5EA;
                    border-radius: 8px;
                    padding: 4px;
                    font-size: 10pt;
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
            act_rma = menu.addAction("Remision (RMA)")
            act_re  = menu.addAction("Revision (RE)")
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
        seg.setStyleSheet(
            f"background: {_SEG_BG}; border-radius: 7px; border: none;"
        )
        seg_lay = QHBoxLayout(seg)
        seg_lay.setContentsMargins(2, 2, 2, 2)
        seg_lay.setSpacing(1)

        self._btn_grp_preset = QButtonGroup(self)
        self._btn_grp_preset.setExclusive(True)

        _presets = [("Hoy", "hoy"), ("Esta Semana", "semana"),
                    ("Este Mes", "mes"), ("Todo", "todo")]

        _seg_btn_style = """
            QPushButton {
                background: transparent;
                color: #636366;
                border: none;
                border-radius: 6px;
                font-size: 9pt;
                font-weight: 500;
                padding: 0 11px;
                min-height: 26px;
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
            b.setCheckable(True)
            b.setFixedHeight(26)
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
            "background: #F5F5F7; border: 1px solid #E5E5EA; "
            "border-radius: 6px; padding: 0 8px; font-size: 9pt; color: #1D1D1F;"
        )
        self._dte_desde = QDateEdit()
        self._dte_desde.setCalendarPopup(True)
        self._dte_desde.setDate(QDate.currentDate().addDays(-30))
        self._dte_desde.setDisplayFormat("dd/MM/yy")
        self._dte_desde.setFixedHeight(28)
        self._dte_desde.setStyleSheet(_dte_style)
        self._dte_desde.dateChanged.connect(lambda _: self._on_filter_changed())

        self._dte_hasta = QDateEdit()
        self._dte_hasta.setCalendarPopup(True)
        self._dte_hasta.setDate(QDate.currentDate())
        self._dte_hasta.setDisplayFormat("dd/MM/yy")
        self._dte_hasta.setFixedHeight(28)
        self._dte_hasta.setStyleSheet(_dte_style)
        self._dte_hasta.dateChanged.connect(lambda _: self._on_filter_changed())

        lbl_de = QLabel("De:")
        lbl_de.setStyleSheet("font-size: 9pt; color: #86868B; background: transparent;")
        lbl_a  = QLabel("a:")
        lbl_a.setStyleSheet("font-size: 9pt; color: #86868B; background: transparent;")

        cd.addWidget(lbl_de)
        cd.addWidget(self._dte_desde)
        cd.addWidget(lbl_a)
        cd.addWidget(self._dte_hasta)
        self._widget_custom_dates.setVisible(False)
        lay.addWidget(self._widget_custom_dates)

        # -- Separador --------------------------------------------------------
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.VLine)
        sep.setStyleSheet("background: #E5E5EA; border: none; max-width: 1px;")
        lay.addWidget(sep)

        # -- Filtro de Tecnicos -----------------------------------------------
        _combo_style = (
            "background: #FFFFFF; border: 1px solid #D1D1D6; border-radius: 7px; "
            "padding: 0 10px; font-size: 9pt; color: #1D1D1F; min-height: 28px;"
        )
        self._combo_tec_bar = QComboBox()
        self._combo_tec_bar.setFixedHeight(28)
        self._combo_tec_bar.setMinimumWidth(160)
        self._combo_tec_bar.setStyleSheet(_combo_style)
        self._combo_tec_bar.currentIndexChanged.connect(self._on_filter_changed)
        lay.addWidget(self._combo_tec_bar)

        # Ocultar combo de tecnicos si el usuario logueado es un tecnico de campo
        # (solo ve sus propias ordenes — no tiene sentido filtrar por otro tecnico)
        _is_field_tech = False
        if _HAS_SESSION and session and session.is_authenticated:
            _tech_roles = {"servicio", "calibrador", "inspector"}
            _is_field_tech = bool(set(getattr(session, "roles", []) or []) & _tech_roles)
        if _is_field_tech:
            self._combo_tec_bar.setVisible(False)

        # -- Filtro de Estado --------------------------------------------------
        self._combo_estado_global = QComboBox()
        self._combo_estado_global.setFixedHeight(28)
        self._combo_estado_global.setMinimumWidth(145)
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
            "Buscar por folio, cliente, sucursal o tecnico..."
        )
        self._search_global.setFixedHeight(28)
        self._search_global.setStyleSheet("""
            QLineEdit {
                background: #F5F5F7;
                border: 1px solid #E5E5EA;
                border-radius: 7px;
                padding: 0 10px;
                font-size: 9pt;
                color: #1D1D1F;
            }
            QLineEdit:focus {
                background: #FFFFFF;
                border: 1.5px solid #C8102E;
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

        _btn_sync_style = """
            QPushButton {
                background: #FFFFFF;
                color: #1D1D1F;
                border: 1px solid #E5E5EA;
                border-radius: 6px;
                font-size: 9pt;
                font-weight: 500;
                padding: 0 14px;
                min-height: 26px;
            }
            QPushButton:hover { background: #F5F5F7; border-color: #C7C7CC; }
            QPushButton:disabled { color: #C7C7CC; background: #F5F5F7; }
        """

        self._btn_download = QPushButton("Descargar Asignaciones")
        self._btn_download.setFixedHeight(28)
        self._btn_download.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_download.setStyleSheet(_btn_sync_style)
        self._btn_download.clicked.connect(self._on_download_assignments)
        lay.addWidget(self._btn_download)

        self._btn_sync = QPushButton("Sincronizar")
        self._btn_sync.setFixedHeight(28)
        self._btn_sync.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_sync.setStyleSheet(_btn_sync_style)
        self._btn_sync.clicked.connect(self._on_sync_clicked)
        lay.addWidget(self._btn_sync)

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
        """Configura el QTreeWidget con 11 columnas estilo macOS y soporte de expansion."""
        cols = [
            "",               # 0  - checkbox de seleccion
            "FOLIO OS",       # 1  - bold rojo / resumen lote
            "FECHA",          # 2
            "CLIENTE",        # 3  - stretch
            "SUCURSAL / PLANTA", # 4 - stretch medio
            "TECNICO",        # 5
            "TIPO SERVICIO",  # 6  - badge
            "MODALIDAD",      # 7  - badge
            "ESTATUS",        # 8  - badge
            "SYNC",           # 9  - badge
            "ACCIONES",       # 10
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

        # Altura de cabecera: 34px
        table.header().setFixedHeight(34)
        table.header().setDefaultAlignment(
            Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter
        )

        # Anchos de columna
        header = table.header()
        header.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        header.setStretchLastSection(False)

        header.setSectionResizeMode(self._COL_CHK,      QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_CHK, 36)

        header.setSectionResizeMode(self._COL_FOLIO,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_FOLIO, 200)  # mas ancho para rangos de lote

        header.setSectionResizeMode(self._COL_FECHA,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_FECHA, 90)

        header.setSectionResizeMode(self._COL_CLIENTE,  QHeaderView.ResizeMode.Stretch)

        header.setSectionResizeMode(self._COL_SUCURSAL, QHeaderView.ResizeMode.Stretch)

        header.setSectionResizeMode(self._COL_TECNICO,  QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_TECNICO, 130)

        header.setSectionResizeMode(self._COL_SERVICIO, QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_SERVICIO, 120)

        header.setSectionResizeMode(self._COL_MODAL,    QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_MODAL, 165)

        header.setSectionResizeMode(self._COL_ESTADO,   QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_ESTADO, 90)

        header.setSectionResizeMode(self._COL_SYNC,     QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_SYNC, 100)

        header.setSectionResizeMode(self._COL_ACCIONES, QHeaderView.ResizeMode.Fixed)
        table.setColumnWidth(self._COL_ACCIONES, 235)

        table.customContextMenuRequested.connect(self._on_table_context_menu)
        table.itemDoubleClicked.connect(self._on_tree_item_double_click_full)

        # Colocar el checkbox maestro dentro de la cabecera col 0
        QTimer.singleShot(0, lambda: self._place_header_checkbox(table))

        # Estilo del QTreeWidget (mismo look que el QTableWidget original)
        table.setStyleSheet(f"""
            QTreeWidget {{
                background: #FFFFFF;
                border: none;
                border-radius: 0 0 10px 10px;
                font-size: 9.5pt;
                color: #1D1D1F;
                outline: none;
                selection-background-color: rgba(200, 16, 46, 0.05);
                selection-color: #1D1D1F;
            }}
            QTreeWidget::item {{
                padding: 3px 10px;
                border-bottom: 1px solid #F2F2F7;
                min-height: 40px;
            }}
            QTreeWidget::item:hover {{
                background: #F8F9FA;
            }}
            QTreeWidget::item:selected {{
                background: rgba(200, 16, 46, 0.05);
                color: #1D1D1F;
            }}
            QHeaderView::section {{
                background: #FAFAFA;
                color: #86868B;
                font-size: 8pt;
                font-weight: 600;
                letter-spacing: 0.4px;
                padding: 0 10px;
                border: none;
                border-bottom: 1px solid #E5E5EA;
                border-right: 1px solid #F2F2F7;
            }}
            QHeaderView::section:last {{
                border-right: none;
            }}
            QHeaderView::section:hover {{
                background: #F5F5F7;
            }}
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

    def _on_search_changed(self, text: str) -> None:
        self._apply_search_filter()

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

    def _on_sync_clicked(self) -> None:
        if not _HAS_SYNC or _sync_manager is None:
            QMessageBox.information(self, "Sin Sync", "El modulo de sincronizacion no esta disponible.")
            return
        if not _sync_manager.is_online():
            QMessageBox.warning(self, "Sin Conexion",
                                "No hay conexion al servidor.\n"
                                "Conectate a la red de oficina e intenta de nuevo.")
            return

        pending = _sync_manager.get_pending_count()
        if pending == 0:
            QMessageBox.information(self, "Sin Pendientes",
                                    "No hay registros pendientes de sincronizar.")
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
        self._refresh_pending_count()
        QTimer.singleShot(300, self.refresh)
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

    def refresh(self) -> None:
        """Lanza carga asíncrona (sin load_filters para mayor velocidad)."""
        self._async_refresh(load_filters=False)

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
        combo_tec   = self._combo_tec_bar.currentData() if hasattr(self, "_combo_tec_bar") else None
        combo_est   = self._combo_estado_global.currentData() if hasattr(self, "_combo_estado_global") else None

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
        # Guardar en caché para restauración instantánea
        self._data_cache['rows'] = rows
        self._cache_valid = True
        self._fill_table_rows(rows)

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

            if hasattr(self, "_combo_tec_bar") and self._combo_tec_bar.currentData():
                where_extra.append("os.id_tecnico = %s")
                params.append(self._combo_tec_bar.currentData())

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
                            os.rango_lote
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes       cl    ON os.id_cliente       = cl.id
                        LEFT JOIN cat_tecnicos       tc    ON os.id_tecnico       = tc.id
                        LEFT JOIN cat_tipo_servicio  ts    ON os.id_tipo_servicio = ts.id
                        LEFT JOIN cliente_sucursales suc   ON os.sucursal_id      = suc.id
                        WHERE 1=1 {where_clause}
                        ORDER BY os.id_lote NULLS LAST, os.fecha DESC, os.created_at DESC
                        LIMIT 200
                        """,
                        params or None,
                    )
                    rows = cur.fetchall()
                except Exception as e:
                    conn.rollback()
                    logger.warning("Query principal fallo, aplicando fallback: %s", e)
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
                            NULL as rango_lote
                        FROM ordenes_servicio os
                        LEFT JOIN cat_clientes      cl ON os.id_cliente       = cl.id
                        LEFT JOIN cat_tecnicos      tc ON os.id_tecnico       = tc.id
                        LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
                        WHERE 1=1 {where_clause}
                        ORDER BY os.fecha DESC, os.created_at DESC
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

    @staticmethod
    def _get_sync_label(estado: str, sync_status: str) -> str:
        if estado.upper() in ("ESCANEADA", "COMPLETADA", "COMPLETADA_DIGITAL"):
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
        item.setText(self._COL_SERVICIO, servicio)
        item.setText(self._COL_MODAL,    modal_label)
        item.setText(self._COL_ESTADO,   estado_label)
        item.setText(self._COL_SYNC,     sync_label)

        # Fondo diferenciado para filas padre de lote
        if is_batch_parent:
            bg = QBrush(QColor("#F0F4FF"))
            for col in range(self._COL_ACCIONES + 1):
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
                "TECNICO", "TIPO SERVICIO", "MODALIDAD", "ESTATUS", "SYNC", "ACCIONES"
            ])

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

            def _make_chk(folios, os_ids, is_batch=False):
                w = QWidget(); w.setStyleSheet("background: transparent;")
                hl = QHBoxLayout(w); hl.setContentsMargins(0,0,0,0)
                hl.setAlignment(Qt.AlignmentFlag.AlignCenter)
                c = QCheckBox(); c.setStyleSheet(_CHK_STYLE)
                c.setProperty("folio",       folios[0] if folios else "")
                c.setProperty("os_id",       os_ids[0] if os_ids else None)
                c.setProperty("all_folios",  folios)
                c.setProperty("all_os_ids",  os_ids)
                c.setProperty("is_batch",    is_batch)
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
                    
                    modal_label  = modalidad.capitalize() + " (Lote)"
                    estado_label = "Cerrado" if estado.upper() in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA") else estado.capitalize()
                    sync_label   = self._get_sync_label(estado, sync_status)

                    # Crear item padre
                    parent_item = QTreeWidgetItem(self._table)
                    self._populate_tree_item(
                        parent_item, texto_folio, fecha_str, cliente, sucursal,
                        tecnico, servicio, modal_label, estado_label, sync_label, os_id,
                        is_batch_parent=True
                    )
                    
                    # Checkbox del lote
                    folios_lote = [str(r[0]) for r in grupo_ord if r[0]]
                    ids_lote = [r[8] for r in grupo_ord if len(r) > 8 and r[8]]
                    chk_p, _ = _make_chk(folios_lote, ids_lote, is_batch=True)
                    self._table.setItemWidget(parent_item, self._COL_CHK, chk_p)

                    # Acciones del lote
                    acts_p = self._build_action_cell_lote(
                        lote_id=lote_id, all_os_ids=ids_lote, all_folios=folios_lote,
                        folio_inicio=f_ini, folio_fin=f_fin,
                        modalidad=modalidad, estado=estado, sync_status=sync_status,
                        parent_item=parent_item
                    )
                    self._table.setItemWidget(parent_item, self._COL_ACCIONES, acts_p)

                    # Agregar las ordenes hijas (ocultas por defecto)
                    for row in grupo_ord:
                        c_folio = str(row[0] or "")
                        c_oid = row[8] if len(row) > 8 else None
                        c_est = str(row[7] or "--")
                        c_sync = str(row[11]) if len(row) > 11 and row[11] else "SYNCED"
                        c_est_label = "Cerrado" if c_est.upper() in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA") else c_est.capitalize()
                        c_sync_label = self._get_sync_label(c_est, c_sync)
                        
                        child = QTreeWidgetItem(parent_item)
                        self._populate_tree_item(
                            child, c_folio, self._fmt_fecha(str(row[1] or "")), str(row[2] or ""), str(row[3] or ""),
                            str(row[4] or ""), str(row[5] or ""), str(row[6] or "").capitalize(), c_est_label, c_sync_label, c_oid
                        )
                        
                        chk_c, _ = _make_chk([c_folio], [c_oid])
                        self._table.setItemWidget(child, self._COL_CHK, chk_c)
                        
                        acts_child = self._build_action_cell(
                            folio=c_folio, estado=c_est, os_id=c_oid,
                            tiene_adjunto=bool(row[10]) if len(row) > 10 else False,
                            sync_status=c_sync, row_data=row,
                        )
                        self._table.setItemWidget(child, self._COL_ACCIONES, acts_child)

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
                    modal_label  = modalidad.capitalize()
                    estado_label = "Cerrado" if estado.upper() in ("COMPLETADA","COMPLETADA_DIGITAL","ESCANEADA") else estado.capitalize()
                    sync_label   = self._get_sync_label(estado, sync_status)

                    item = QTreeWidgetItem(self._table)
                    self._populate_tree_item(
                        item, folio, fecha_str, cliente, sucursal,
                        tecnico, servicio, modal_label, estado_label, sync_label, os_id
                    )
                    chk_w, _ = _make_chk([folio], [os_id])
                    self._table.setItemWidget(item, self._COL_CHK, chk_w)

                    acts = self._build_action_cell(
                        folio=folio, estado=estado, os_id=os_id,
                        tiene_adjunto=bool(tiene_adj), sync_status=sync_status, row_data=row,
                    )
                    self._table.setItemWidget(item, self._COL_ACCIONES, acts)
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


    def _open_pdf_lote(
        self, folio_inicio: str, folio_fin: str, all_folios: list
    ) -> None:
        """
        Abre el PDF compilado de un lote usando búsqueda glob multi-patrón.
        Primero busca un PDF combinado con el rango; si no existe, abre el
        primer folio individual disponible.
        """
        import glob as _glob
        import sys
        import subprocess
        import pathlib

        def _open_file(path: str) -> None:
            try:
                if sys.platform == "win32":
                    os.startfile(path)
                elif sys.platform == "darwin":
                    subprocess.run(["open", path], check=False)
                else:
                    subprocess.run(["xdg-open", path], check=False)
            except Exception as exc:
                logger.warning("_open_pdf_lote: no se pudo abrir %s: %s", path, exc)

        fi = folio_inicio.strip()
        ff = folio_fin.strip()

        # ── Carpetas de búsqueda ──────────────────────────────────────────────
        _pdf_dirs = [
            pathlib.Path(r"C:\PesaServidorCentral\PDF_OS"),
            pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS",
        ]

        # ── Patrones glob para PDFs de lote combinado ─────────────────────────
        patrones = [
            f"*{fi}*{ff}*.pdf",          # «OS-26-570...OS-26-595.pdf»
            f"*{fi}*a*{ff}*.pdf",        # «OS-26-570_a_OS-26-595.pdf»
            f"*{fi}*al*{ff}*.pdf",       # «OS-26-570 al OS-26-595.pdf»
            f"{fi}*.pdf",                # «OS-26-570_lote.pdf»
        ]

        for pdf_dir in _pdf_dirs:
            if not pdf_dir.exists():
                continue
            for patron in patrones:
                matches = list(pdf_dir.glob(patron))
                if matches:
                    logger.info("_open_pdf_lote: PDF lote encontrado: %s", matches[0])
                    _open_file(str(matches[0]))
                    return

        # ── Fallback: abrir el primero que exista del rango ───────────────────
        for folio in all_folios:
            for pdf_dir in _pdf_dirs:
                candidate = pdf_dir / f"{folio}.pdf"
                if candidate.exists():
                    logger.info("_open_pdf_lote: abriendo primer folio disponible: %s", candidate)
                    _open_file(str(candidate))
                    return

        # ── No encontrado ─────────────────────────────────────────────────────
        carpetas_str = "\n".join(f"  • {d}" for d in _pdf_dirs)
        QMessageBox.warning(
            self, "Archivo no encontrado",
            f"No se encontró el PDF del lote:\n\n"
            f"  {fi} al {ff}\n\n"
            f"Carpetas buscadas:\n{carpetas_str}\n\n"
            f"Asegúrate de que el PDF combinado exista en alguna de estas rutas."
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
        lay.setContentsMargins(6, 2, 6, 2)
        lay.setSpacing(8)

        _btn_lote_style = """
            QPushButton {
                background: #E8EDFF;
                color: #1D3A8A;
                border: 1px solid #B8C8FF;
                border-radius: 4px;
                font-size: 8.5pt;
                font-weight: 600;
                padding: 0 8px;
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
                padding: 0 7px;
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
                padding: 0 7px;
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
                padding: 0 8px;
                min-height: 26px;
            }
            QPushButton:hover { background: #FFE0E0; }
        """

        # ── Botón PDF Lote ────────────────────────────────────────────────────
        btn_pdf_lote = QPushButton("PDF Lote")
        btn_pdf_lote.setStyleSheet(_btn_lote_style)
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
        """Confirma y elimina todos los registros de un lote."""
        msg = QMessageBox(self)
        msg.setWindowTitle("Eliminar Lote")
        msg.setText(
            f"¿Eliminar el lote completo ({len(folios)} formatos)?\n"
            f"Folios: {folios[0]} … {folios[-1]}"
        )
        msg.setStandardButtons(
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel
        )
        msg.setDefaultButton(QMessageBox.StandardButton.Cancel)
        msg.setIcon(QMessageBox.Icon.Warning)
        if msg.exec() != QMessageBox.StandardButton.Yes:
            return
        try:
            conn = _db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "DELETE FROM ordenes_servicio WHERE id = ANY(%s)", (os_ids,)
                )
            conn.commit()
            _db_pool.release_connection(conn)
            self._load_table()
            self._load_kpis()
        except Exception as exc:
            logger.error("Error eliminando lote: %s", exc)
            QMessageBox.critical(self, "Error", f"No se pudo eliminar el lote:\n{exc}")

    def _build_action_cell(self, folio: str, estado: str, os_id,
                           tiene_adjunto: bool, sync_status: str,
                           row_data: tuple) -> QWidget:
        """Crea el widget de acciones adaptado según modalidad (FISICO / DIGITAL)."""
        # Extraer modalidad de row_data (col 6) o desde el texto del item padre
        modalidad = str(row_data[6] or "FISICO").upper() if len(row_data) > 6 else "FISICO"
        is_digital = (modalidad == "DIGITAL")
        is_closed  = estado.upper() in ("COMPLETADA", "COMPLETADA_DIGITAL",
                                        "ESCANEADA", "CERRADO", "CERRADA")

        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(container)
        lay.setContentsMargins(6, 2, 6, 2)
        lay.setSpacing(8)

        # Usar constantes de clase (evita recrear strings CSS por fila)
        _btn_pdf_style       = self._BTN_PDF_STYLE
        _btn_capturar_style  = self._BTN_CAPTURAR_STYLE
        _btn_pdf_final_style = self._BTN_PDF_FINAL_STYLE

        # ── Botón primario adaptativo ─────────────────────────────────────────
        if is_digital and not is_closed:
            # DIGITAL + EN PROCESO → Capturar OS
            btn_primary = QPushButton("📝 Capturar OS")
            btn_primary.setFixedHeight(26)
            btn_primary.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_primary.setStyleSheet(_btn_capturar_style)
            btn_primary.setToolTip(
                "Abrir la interfaz de captura digital de lecturas metrológicas"
            )
            btn_primary.clicked.connect(
                lambda _, fid=os_id, fl=folio, rd=row_data: self._abrir_captura_digital(fid, fl, rd)
            )
            lay.addWidget(btn_primary)
        elif is_digital and is_closed:
            # DIGITAL + CERRADO → Ver PDF Final y Editar OS
            btn_primary = QPushButton("Ver PDF Final")
            btn_primary.setFixedHeight(26)
            btn_primary.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_primary.setStyleSheet(_btn_pdf_final_style)
            btn_primary.setToolTip("Abrir el PDF digital final con lecturas impresas")
            btn_primary.clicked.connect(lambda _, fid=os_id: self._open_pdf(fid))
            lay.addWidget(btn_primary)
            
            btn_editar = QPushButton("📝 Editar OS")
            btn_editar.setFixedHeight(26)
            btn_editar.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_editar.setStyleSheet(_btn_capturar_style)
            btn_editar.setToolTip("Reabrir la captura para corregir datos y regenerar PDF")
            btn_editar.clicked.connect(lambda _, fid=os_id, fl=folio, rd=row_data: self._abrir_captura_digital(fid, fl, rd))
            lay.addWidget(btn_editar)
        else:
            # FISICO → Ver PDF
            btn_primary = QPushButton("Ver PDF")
            btn_primary.setFixedHeight(26)
            btn_primary.setCursor(Qt.CursorShape.PointingHandCursor)
            btn_primary.setStyleSheet(_btn_pdf_style)
            btn_primary.setToolTip("Abrir el PDF en blanco para imprimir")
            btn_primary.clicked.connect(lambda _, fid=os_id: self._open_pdf(fid))
            lay.addWidget(btn_primary)

        # ── Botón Opciones con QMenu ──────────────────────────────────────────
        btn_opts = QPushButton("Opciones")
        btn_opts.setFixedHeight(26)
        btn_opts.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_opts.setStyleSheet(_btn_pdf_style)
        opts_menu = QMenu(btn_opts)
        opts_menu.setStyleSheet("""
            QMenu {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 8px;
                padding: 4px;
                font-size: 9pt;
            }
            QMenu::item {
                padding: 7px 16px;
                border-radius: 4px;
                color: #1D1D1F;
            }
            QMenu::item:selected { background: #F5F5F7; }
            QMenu::separator { height: 1px; background: #E5E5EA; margin: 3px 8px; }
        """)

        # Capturar / Ver PDF borrador (digital)
        if is_digital and not is_closed:
            act_pdf_borr = QAction("Ver PDF borrador", btn_opts)
            act_pdf_borr.triggered.connect(lambda _, fid=os_id: self._open_pdf(fid))
            opts_menu.addAction(act_pdf_borr)
            opts_menu.addSeparator()

        # Editar Captura Digital (digital cerrado)
        if is_digital and is_closed:
            act_editar_cap = QAction("📝  Editar Captura Digital", btn_opts)
            act_editar_cap.triggered.connect(
                lambda _, fid=os_id, fl=folio, rd=row_data: self._abrir_captura_digital(fid, fl, rd)
            )
            opts_menu.addAction(act_editar_cap)
            opts_menu.addSeparator()

        if self._is_admin_or_logistica():
            act_edit = QAction("Editar", btn_opts)
            act_edit.triggered.connect(lambda _, fid=os_id: self._quick_edit_os(fid))
            opts_menu.addAction(act_edit)

        if self._is_admin_or_logistica():
            act_reasignar = QAction("Reasignar", btn_opts)
            act_reasignar.triggered.connect(lambda _, fid=os_id: self._quick_edit_os(fid))
            opts_menu.addAction(act_reasignar)

        if self._is_admin_or_logistica():
            act_actividad = QAction("\U0001f4c5  Editar Actividad", btn_opts)
            act_actividad.triggered.connect(
                lambda _, fid=os_id, fl=folio: self._editar_actividad_os(fid, fl)
            )
            opts_menu.addSeparator()
            opts_menu.addAction(act_actividad)

        # ── Opción Descargar PDF (admin / recepción) ──────────────────────────
        if _session_has_role("admin", "recepcion", "logistica"):
            act_download = QAction("\U0001f4e5  Descargar PDF", btn_opts)
            act_download.triggered.connect(
                lambda _, fid=os_id, fl=folio: self._descargar_pdf_os(fid, fl)
            )
            opts_menu.addSeparator()
            opts_menu.addAction(act_download)

        if self._is_admin():
            opts_menu.addSeparator()
            # ── Cambiar modalidad individual ───────────────────────────────────
            cur_modal = (modalidad or "").upper()
            if cur_modal != "FISICO":
                act_to_fis = QAction("📄  Cambiar a Formato Físico", btn_opts)
                act_to_fis.triggered.connect(
                    lambda _, fid=os_id: self._cambiar_modalidad_os(fid, "FISICO")
                )
                opts_menu.addAction(act_to_fis)
            if cur_modal != "DIGITAL":
                act_to_dig = QAction("📱  Cambiar a Formato Digital", btn_opts)
                act_to_dig.triggered.connect(
                    lambda _, fid=os_id: self._cambiar_modalidad_os(fid, "Digital")
                )
                opts_menu.addAction(act_to_dig)
            opts_menu.addSeparator()
            act_del = QAction("🗑️  Eliminar Orden", btn_opts)
            act_del.triggered.connect(
                lambda _, fid=os_id, fl=folio: self._delete_single_os(fid, folio_fallback=fl)
            )
            opts_menu.addAction(act_del)

        btn_opts.setMenu(opts_menu)
        btn_opts.setStyleSheet(_btn_pdf_style + "QPushButton::menu-indicator { image: none; width: 0; }")
        lay.addWidget(btn_opts)

        lay.addStretch()
        return container

    def _descargar_pdf_os(self, os_id: int, folio: str) -> None:
        """
        Permite al usuario elegir dónde guardar el PDF de una OS,
        lo copia al destino y marca pdf_descargado=TRUE en la BD.
        """
        import os as _os
        import shutil

        # 1. Buscar el PDF en la carpeta de PDFs de la aplicación
        pdf_src = None
        try:
            from services.pdf_router import get_pdf_path
            pdf_src = get_pdf_path(os_id, folio)
        except Exception:
            pass
        if not pdf_src or not _os.path.exists(pdf_src):
            # Buscar por nombre de archivo en carpeta local
            from pathlib import Path
            for search_dir in [
                _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', '..', 'PDFs'),
                _os.path.join(_os.path.expanduser('~'), 'Documents', 'PESA', 'PDFs'),
            ]:
                candidate = Path(search_dir) / f'{folio}.pdf'
                if candidate.exists():
                    pdf_src = str(candidate)
                    break

        if not pdf_src or not _os.path.exists(pdf_src):
            QMessageBox.warning(
                self, "PDF no encontrado",
                f"No se encontró el PDF para el folio {folio}.\n"
                "Genera primero el PDF desde la pantalla de captura."
            )
            return

        # 2. Pedir al usuario dónde guardarlo
        dest_path, _ = QFileDialog.getSaveFileName(
            self,
            f"Guardar PDF — {folio}",
            f"{folio}.pdf",
            "Archivos PDF (*.pdf)",
        )
        if not dest_path:
            return  # canceló

        # 3. Copiar el archivo
        try:
            shutil.copy2(pdf_src, dest_path)
        except Exception as exc:
            QMessageBox.critical(
                self, "Error al copiar",
                f"No se pudo guardar el PDF:\n{exc}"
            )
            return

        # 4. Registrar en BD: pdf_descargado = TRUE
        if _DEPS_OK and _db_pool:
            try:
                conn = _db_pool.get_connection()
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE ordenes_servicio SET pdf_descargado = TRUE WHERE id = %s",
                        (os_id,)
                    )
                conn.commit()
                _db_pool.release_connection(conn)
            except Exception as exc:
                logger.warning("No se pudo actualizar pdf_descargado: %s", exc)

        QMessageBox.information(
            self, "PDF descargado",
            f"PDF guardado exitosamente en:\n{dest_path}"
        )

    def _abrir_captura_digital(self, os_id, folio: str, row_data: tuple = None) -> None:
        """Abre el diálogo de captura digital interactiva para la OS indicada."""
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

        def _matches(text: str) -> bool:
            t = text.lower()
            return all(w in t for w in words)

        for i in range(n_top):
            parent_item = root.child(i)

            # Texto buscable del padre: columnas 0..6 (folio, fecha, cliente,
            # sucursal, técnico, tipo_servicio, modalidad)
            parent_texts = " ".join(
                (parent_item.text(col) or "") for col in range(7)
            )
            parent_match = _matches(parent_texts)

            child_count    = parent_item.childCount()
            any_child_match = False

            for j in range(child_count):
                child = parent_item.child(j)
                child_texts = " ".join(
                    (child.text(col) or "") for col in range(7)
                )
                child_match = _matches(child_texts)

                if parent_match:
                    # Padre coincide → todos los hijos visibles
                    child.setHidden(False)
                else:
                    child.setHidden(not child_match)
                    if child_match:
                        any_child_match = True

            # El padre se muestra si él mismo o algún hijo coincide
            show_parent = parent_match or any_child_match
            parent_item.setHidden(not show_parent)

            # Si hay coincidencia en hijos, expandir el grupo automáticamente
            if any_child_match and not parent_match:
                parent_item.setExpanded(True)
            elif parent_match:
                parent_item.setExpanded(True)


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
        """Devuelve lista de {folio, os_id} de las filas marcadas (soporta lotes)."""
        selected = []

        def _collect(item: QTreeWidgetItem) -> None:
            w = self._table.itemWidget(item, self._COL_CHK)
            if w:
                chk = w.findChild(QCheckBox)
                if chk and chk.isChecked():
                    all_folios = chk.property("all_folios") or [chk.property("folio")]
                    all_os_ids = chk.property("all_os_ids") or [chk.property("os_id")]
                    for f, oid in zip(all_folios, all_os_ids):
                        selected.append({"folio": f, "os_id": oid})
            # Siempre revisar hijos, independientemente del padre
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

    def _on_row_checkbox_changed(self) -> None:
        """Actualiza el contador del botón de borrado al marcar/desmarcar filas."""
        self._update_delete_btn_label()

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
            conn = _db_pool.getconn()
            conn.autocommit = False
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

                cur.execute("DELETE FROM ordenes_servicio WHERE id = %s", (_resolved_id,))
                rows = cur.rowcount
            conn.commit()
            logger.info("[DELETE] OS id=%s folio=%s eliminada (%d)",
                        _resolved_id, _folio_known, rows)
            if rows == 0:
                QMessageBox.warning(self, "Sin resultado",
                    f"No se encontró id={_resolved_id}. Es posible que ya estuviera eliminada.")
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
                try: _db_pool.putconn(conn)
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

    def _open_pdf(self, os_id_or_folio) -> None:
        """
        Abre el PDF de una OS.

        Orden de búsqueda:
          0. pdf_b64 en BD (subido por tablet vía push — Offline-First v2)
          1. PDF individual en filesystem
          2. PDF de lote en filesystem
          3. Adjunto escaneado en BD

        Acepta tanto os_id (int) como folio directo (str).
        """
        import sys
        import subprocess
        import pathlib
        import base64
        import tempfile

        def _open_file(path: str) -> None:
            try:
                if sys.platform == "win32":
                    os.startfile(path)
                elif sys.platform == "darwin":
                    subprocess.run(["open", path], check=False)
                else:
                    subprocess.run(["xdg-open", path], check=False)
            except Exception as exc:
                logger.warning("_open_pdf: no se pudo abrir %s: %s", path, exc)

        # ── Resolver el folio ─────────────────────────────────────────────────
        folio_os: str | None = None

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

        # ── 0. pdf_b64 en BD (Offline-First v2 — tablet subió el PDF) ─────────
        try:
            conn = _db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT pdf_b64 FROM ordenes_servicio WHERE folio_os = %s",
                        (folio_limpio,)
                    )
                    row_b64 = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)

            if row_b64 and row_b64[0]:
                pdf_bytes = base64.b64decode(row_b64[0])
                tmp_path = pathlib.Path(tempfile.gettempdir()) / f"PESA_{folio_limpio}.pdf"
                tmp_path.write_bytes(pdf_bytes)
                logger.info("_open_pdf: abriendo pdf_b64 desde BD → %s", tmp_path)
                _open_file(str(tmp_path))
                return
        except Exception as exc:
            logger.warning("_open_pdf: no se pudo leer pdf_b64 de BD: %s", exc)

        # ── Carpetas donde pueden estar los PDFs ──────────────────────────────
        _pdf_dirs = [
            pathlib.Path(r"C:\PesaServidorCentral\PDF_OS"),
            pathlib.Path.home() / "PesaServidorLocal" / "PDF_OS",
        ]

        # ── 1. PDF individual exacto: <folio>.pdf ─────────────────────────────
        for pdf_dir in _pdf_dirs:
            candidate = pdf_dir / f"{folio_limpio}.pdf"
            if candidate.exists():
                logger.info("_open_pdf: encontrado PDF individual: %s", candidate)
                _open_file(str(candidate))
                return

        # ── 2. PDF de lote combinado ──────────────────────────────────────────
        for pdf_dir in _pdf_dirs:
            if not pdf_dir.exists():
                continue
            try:
                for archivo in pdf_dir.iterdir():
                    if archivo.suffix.lower() == ".pdf" and folio_limpio in archivo.stem:
                        logger.info("_open_pdf: encontrado PDF de lote: %s", archivo)
                        _open_file(str(archivo))
                        return
            except (PermissionError, OSError):
                continue

        # ── 3. Adjunto escaneado en BD ────────────────────────────────────────
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
                        (folio_limpio,)
                    )
                    row_adj = cur.fetchone()
                conn.commit()
            finally:
                _db_pool.release_connection(conn)

            if row_adj and row_adj[0] and pathlib.Path(row_adj[0]).exists():
                logger.info("_open_pdf: usando adjunto escaneado: %s", row_adj[0])
                _open_file(row_adj[0])
                return
        except Exception as exc:
            logger.warning("_open_pdf: no se pudo leer adjunto: %s", exc)

        # ── 4. No encontrado → mensaje claro ──────────────────────────────────
        QMessageBox.warning(
            self, "Archivo no encontrado",
            f"No se encontró el archivo PDF para el folio:\n\n"
            f"  {folio_limpio}\n\n"
            f"Si el técnico ya cerró la orden desde la tablet,\n"
            f"pídele que sincronice (presione 'Sincronizar').\n\n"
            f"Carpetas locales buscadas:\n"
            + "\n".join(f"  • {d}" for d in _pdf_dirs)
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
