"""
firma_widget.py — Módulo Corporativo de Firma Digital (PyQt6)
------------------------------------------------------------
Provee:
  - DrawingCanvas: lienzo táctil/mouse con línea guía horizontal, validación real de trazo
    y exportación PNG transparente de alta resolución (>= 560x220px).
  - PesaSignatureDialog: modal corporativo reutilizable con Limpiar, Cancelar y Guardar Firma
    (sin cierres silenciosos y con retorno explícito del PNG Base64).
  - FirmaWidget: pantalla Mi Firma con previsualización responsiva, trabajadores asíncronos
    en QThread (nunca congela el hilo UI) y notificaciones limpias.
"""
from __future__ import annotations

import base64
import logging
from typing import Optional

from PyQt6.QtCore import Qt, QPointF, QRectF, QThread, pyqtSignal, QByteArray, QBuffer, QIODevice
from PyQt6.QtGui import QPainter, QPen, QColor, QImage, QPixmap, QPainterPath
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QFrame, QMessageBox, QSizePolicy, QDialog,
)

from auth.session_context import session as _session
from database.connection import db_pool

logger = logging.getLogger(__name__)

_DARK = "#1D1D1F"
_GRAY = "#6E6E73"
_LGRAY = "#D2D2D7"
_BORDER = "#E5E5EA"
_RED = "#C8102E"
_RED_HOVER = "#A60D26"
_SURFACE = "#F2F2F7"


class _LoadFirmaWorker(QThread):
    loaded = pyqtSignal(str)
    empty = pyqtSignal()
    failed = pyqtSignal(str)

    def __init__(self, uid: int, parent=None):
        super().__init__(parent)
        self._uid = uid

    def run(self) -> None:
        try:
            with db_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT firma_digital FROM cat_tecnicos WHERE id = %s", (self._uid,))
                    row = cur.fetchone()
                    if row and row[0] and str(row[0]).strip():
                        self.loaded.emit(str(row[0]).strip())
                        return
            self.empty.emit()
        except Exception as exc:
            logger.error("Error cargando firma desde BD: %s", exc)
            self.failed.emit(str(exc))


class _SaveFirmaWorker(QThread):
    saved_ok = pyqtSignal(str, int)
    failed = pyqtSignal(str)

    def __init__(self, uid: int, b64_png: str, parent=None):
        super().__init__(parent)
        self._uid = uid
        self._b64 = b64_png

    def run(self) -> None:
        closed_orders: list[tuple] = []
        try:
            with db_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE cat_tecnicos SET firma_digital = %s WHERE id = %s RETURNING id",
                        (self._b64, self._uid),
                    )
                    upd_tec = cur.fetchone()
                    if not upd_tec:
                        raise RuntimeError(f"No existe el perfil de técnico id={self._uid} en PostgreSQL.")

                    cur.execute(
                        """
                        SELECT id, folio_os FROM ordenes_servicio
                        WHERE id_tecnico = %s
                          AND (
                            estado IN ('CERRADA', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA')
                            OR estatus IN ('Cerrado', 'CERRADO', 'Cerrada')
                          )
                        """,
                        (self._uid,),
                    )
                    closed_orders = cur.fetchall() or []

                    if closed_orders:
                        cur.execute(
                            """
                            UPDATE ordenes_servicio
                            SET firma_tecnico_b64 = %s,
                                firma_tecnico = %s,
                                updated_at = NOW()
                            WHERE id_tecnico = %s
                              AND (
                                estado IN ('CERRADA', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA')
                                OR estatus IN ('Cerrado', 'CERRADO', 'Cerrada')
                              )
                            """,
                            (self._b64, self._b64, self._uid),
                        )
                conn.commit()

            # Regenerar PDFs fuera de la transacción SQLite/PG en segundo plano
            if closed_orders:
                try:
                    from services.pdf_router import regenerar_pdf
                    for os_id, folio in closed_orders:
                        try:
                            regenerar_pdf(os_id, folio, force=True)
                        except Exception as exc_pdf:
                            logger.warning("No se pudo regenerar PDF %s con firma: %s", folio, exc_pdf)
                except Exception as exc_router:
                    logger.warning("pdf_router no disponible: %s", exc_router)

            self.saved_ok.emit(self._b64, len(closed_orders))
        except Exception as exc:
            logger.error("Error guardando firma en BD: %s", exc)
            self.failed.emit(str(exc))


class DrawingCanvas(QWidget):
    """Canvas de firma táctil/mouse con exportación PNG transparente nítida (>= 560x220)."""
    signature_changed = pyqtSignal()

    def __init__(self, placeholder: str = "Firme aquí sobre la línea guía", parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._placeholder = placeholder
        self._strokes: list[list[QPointF]] = []
        self._current_stroke: list[QPointF] = []
        self._preloaded_pixmap: Optional[QPixmap] = None
        self._drawing = False
        self.setObjectName("pesa_signature_canvas")
        self.setMinimumSize(420, 190)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setAttribute(Qt.WidgetAttribute.WA_AcceptTouchEvents, True)
        self.setStyleSheet(
            "QWidget#pesa_signature_canvas { "
            "background: #FFFFFF; border: 1.5px solid #D2D2D7; border-radius: 8px; }"
        )

    def set_base64_image(self, b64_data: str) -> bool:
        """Precarga una firma PNG existente (Base64) como fondo dibujado."""
        clean = str(b64_data or "").strip()
        if clean.startswith("data:image") and "base64," in clean:
            clean = clean.split("base64,", 1)[-1].strip()
        if not clean:
            return False
        try:
            raw = base64.b64decode(clean)
            pix = QPixmap()
            if pix.loadFromData(raw) and not pix.isNull():
                self._strokes.clear()
                self._current_stroke.clear()
                self._preloaded_pixmap = pix
                self.update()
                self.signature_changed.emit()
                return True
        except Exception:
            pass
        return False

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._preloaded_pixmap = None
            self._drawing = True
            self._current_stroke = [QPointF(event.position())]

    def mouseMoveEvent(self, event):
        if self._drawing and (event.buttons() & Qt.MouseButton.LeftButton):
            self._current_stroke.append(QPointF(event.position()))
            self.update()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and self._drawing:
            self._drawing = False
            if self._current_stroke:
                self._strokes.append(self._current_stroke)
                self._current_stroke = []
                self.update()
                self.signature_changed.emit()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Fondo blanco limpio con borde sutil interno
        rect = self.rect()
        p.fillRect(rect, QColor("#FFFFFF"))

        # Línea guía horizontal corporativa (enteros seguros QPainter)
        guide_y = int(round(rect.height() * 0.74))
        p.setPen(QPen(QColor("#E5E7EB"), 1.0, Qt.PenStyle.SolidLine))
        p.drawLine(20, guide_y, max(24, rect.width() - 20), guide_y)

        if self._preloaded_pixmap is not None and not self._preloaded_pixmap.isNull():
            scaled = self._preloaded_pixmap.scaled(
                max(10, rect.width() - 24),
                max(10, rect.height() - 24),
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
            x0 = int(round((rect.width() - scaled.width()) / 2))
            y0 = int(round((rect.height() - scaled.height()) / 2))
            p.drawPixmap(x0, y0, scaled)
            p.end()
            return

        if not self._strokes and not self._current_stroke:
            p.setPen(QColor("#9CA3AF"))
            font = p.font()
            font.setPointSize(11)
            p.setFont(font)
            p.drawText(rect, Qt.AlignmentFlag.AlignCenter, self._placeholder)
            p.end()
            return

        pen = QPen(
            QColor(_DARK),
            3.0,
            Qt.PenStyle.SolidLine,
            Qt.PenCapStyle.RoundCap,
            Qt.PenJoinStyle.RoundJoin,
        )
        p.setPen(pen)

        for stroke in self._strokes + ([self._current_stroke] if self._current_stroke else []):
            if len(stroke) < 2:
                if stroke:
                    p.drawPoint(stroke[0])
                continue
            path = QPainterPath()
            path.moveTo(stroke[0])
            for pt in stroke[1:]:
                path.lineTo(pt)
            p.drawPath(path)
        p.end()

    def clear(self):
        self._strokes.clear()
        self._current_stroke.clear()
        self._preloaded_pixmap = None
        self._drawing = False
        self.update()
        self.signature_changed.emit()

    def is_empty(self) -> bool:
        if self._preloaded_pixmap is not None and not self._preloaded_pixmap.isNull():
            return False
        total_pts = sum(len(s) for s in self._strokes)
        return len(self._strokes) == 0 or total_pts < 2

    def get_base64(self, min_width: int = 560, min_height: int = 220) -> str:
        """Retorna la firma como imagen PNG transparente nítida en Base64."""
        if self.is_empty():
            return ""
        if self._preloaded_pixmap is not None and not self._strokes:
            ba = QByteArray()
            buf = QBuffer(ba)
            buf.open(QIODevice.OpenModeFlag.WriteOnly)
            self._preloaded_pixmap.save(buf, "PNG")
            return bytes(ba.toBase64()).decode("ascii")

        src_w = max(1, self.width())
        src_h = max(1, self.height())
        out_w = max(min_width, src_w)
        out_h = max(min_height, src_h)

        img = QImage(out_w, out_h, QImage.Format.Format_ARGB32)
        img.fill(Qt.GlobalColor.transparent)
        p = QPainter(img)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)

        sx = out_w / float(src_w)
        sy = out_h / float(src_h)
        pen = QPen(
            QColor(_DARK),
            3.2 * min(sx, sy),
            Qt.PenStyle.SolidLine,
            Qt.PenCapStyle.RoundCap,
            Qt.PenJoinStyle.RoundJoin,
        )
        p.setPen(pen)

        for stroke in self._strokes:
            if len(stroke) < 2:
                if stroke:
                    p.drawPoint(QPointF(stroke[0].x() * sx, stroke[0].y() * sy))
                continue
            path = QPainterPath()
            path.moveTo(QPointF(stroke[0].x() * sx, stroke[0].y() * sy))
            for pt in stroke[1:]:
                path.lineTo(QPointF(pt.x() * sx, pt.y() * sy))
            p.drawPath(path)
        p.end()

        ba = QByteArray()
        buf = QBuffer(ba)
        buf.open(QIODevice.OpenModeFlag.WriteOnly)
        img.save(buf, "PNG")
        return bytes(ba.toBase64()).decode("ascii")

    # Alias estándar usado por diálogos digitales
    def to_base64_png(self) -> str:
        return self.get_base64()


class PesaSignatureDialog(QDialog):
    """
    Modal corporativo reutilizable para capturar firma del técnico con validación,
    guardado en BD opcional, deshabilitación mientras guarda y retorno explícito del PNG Base64.
    """

    def __init__(
        self,
        title: str = "Captura de Firma Digital",
        subtitle: str = "Traza tu firma sobre la línea guía. Se insertará automáticamente en tus órdenes y PDFs.",
        uid_tecnico: Optional[int] = None,
        save_to_db: bool = True,
        parent=None,
    ):
        super().__init__(parent)
        self._uid_tecnico = uid_tecnico
        self._save_to_db = save_to_db
        self._result_b64: str = ""
        self._save_worker: Optional[_SaveFirmaWorker] = None

        self.setWindowTitle(title)
        self.setModal(True)
        self.setMinimumSize(560, 390)
        self.setObjectName("pesa_signature_dialog")
        self.setStyleSheet(
            "QDialog#pesa_signature_dialog { background: #FFFFFF; } "
            "QLabel { border: none; background: transparent; }"
        )

        root = QVBoxLayout(self)
        root.setContentsMargins(24, 22, 24, 22)
        root.setSpacing(14)

        lbl_title = QLabel(title)
        lbl_title.setStyleSheet("font-size: 17px; font-weight: 700; color: #111827;")
        root.addWidget(lbl_title)

        lbl_sub = QLabel(subtitle)
        lbl_sub.setWordWrap(True)
        lbl_sub.setStyleSheet("font-size: 12.5px; color: #6B7280;")
        root.addWidget(lbl_sub)

        self._canvas = DrawingCanvas(parent=self)
        self._canvas.signature_changed.connect(self._on_sig_changed)
        root.addWidget(self._canvas, stretch=1)

        self._lbl_error = QLabel("")
        self._lbl_error.setWordWrap(True)
        self._lbl_error.setStyleSheet("font-size: 12px; font-weight: 600; color: #C8102E;")
        self._lbl_error.hide()
        root.addWidget(self._lbl_error)

        btn_row = QHBoxLayout()
        btn_row.setSpacing(10)

        self._btn_limpiar = QPushButton("Limpiar")
        self._btn_limpiar.setFixedHeight(38)
        self._btn_limpiar.clicked.connect(self._on_limpiar)

        self._btn_cancelar = QPushButton("Cancelar")
        self._btn_cancelar.setFixedHeight(38)
        self._btn_cancelar.clicked.connect(self.reject)

        self._btn_guardar = QPushButton("Guardar Firma")
        self._btn_guardar.setFixedHeight(38)
        self._btn_guardar.setEnabled(False)
        self._btn_guardar.setStyleSheet(
            "QPushButton { background: #C8102E; color: #FFFFFF; border: 1px solid #C8102E; "
            "border-radius: 8px; padding: 0 20px; font-size: 13px; font-weight: 600; } "
            "QPushButton:hover { background: #A60D26; } "
            "QPushButton:disabled { background: #E5E7EB; color: #9CA3AF; border-color: #E5E7EB; }"
        )
        self._btn_guardar.clicked.connect(self._on_guardar)

        btn_row.addWidget(self._btn_limpiar)
        btn_row.addStretch()
        btn_row.addWidget(self._btn_cancelar)
        btn_row.addWidget(self._btn_guardar)
        root.addLayout(btn_row)

    @property
    def signature_base64(self) -> str:
        return self._result_b64

    def _on_sig_changed(self) -> None:
        self._lbl_error.hide()
        self._btn_guardar.setEnabled(not self._canvas.is_empty())

    def _on_limpiar(self) -> None:
        self._lbl_error.hide()
        self._canvas.clear()

    def _on_guardar(self) -> None:
        if self._canvas.is_empty():
            self._lbl_error.setText("Traza tu firma sobre la línea antes de guardar.")
            self._lbl_error.show()
            return

        b64 = self._canvas.get_base64()
        if not b64 or len(b64) < 32:
            self._lbl_error.setText("No se pudo generar la imagen de la firma.")
            self._lbl_error.show()
            return

        if not self._save_to_db or not self._uid_tecnico:
            self._result_b64 = b64
            self.accept()
            return

        self._set_busy(True)
        self._save_worker = _SaveFirmaWorker(int(self._uid_tecnico), b64, self)
        self._save_worker.saved_ok.connect(self._on_worker_ok)
        self._save_worker.failed.connect(self._on_worker_err)
        self._save_worker.start()

    def _set_busy(self, busy: bool) -> None:
        self._btn_guardar.setEnabled(not busy and not self._canvas.is_empty())
        self._btn_guardar.setText("Guardando..." if busy else "Guardar Firma")
        self._btn_limpiar.setEnabled(not busy)
        self._btn_cancelar.setEnabled(not busy)

    def _on_worker_ok(self, b64: str, _regen_count: int) -> None:
        self._set_busy(False)
        self._result_b64 = b64
        self.accept()

    def _on_worker_err(self, err: str) -> None:
        self._set_busy(False)
        self._lbl_error.setText(f"No se pudo guardar en servidor: {err}")
        self._lbl_error.show()

    @classmethod
    def capturar(
        cls,
        parent=None,
        title: str = "Captura de Firma Digital",
        subtitle: str = "Traza tu firma sobre la línea guía. Se aplicará en tus órdenes y PDFs.",
        uid_tecnico: Optional[int] = None,
        save_to_db: bool = True,
    ) -> str:
        dlg = cls(
            title=title,
            subtitle=subtitle,
            uid_tecnico=uid_tecnico,
            save_to_db=save_to_db,
            parent=parent,
        )
        if dlg.exec() == QDialog.DialogCode.Accepted:
            return dlg.signature_base64
        return ""


class FirmaWidget(QWidget):
    """Pantalla Mi Firma para gestionar la firma digital del perfil de usuario."""

    firma_guardada = pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._current_b64: str = ""
        self._current_pixmap: Optional[QPixmap] = None
        self._load_worker: Optional[_LoadFirmaWorker] = None
        self._save_worker: Optional[_SaveFirmaWorker] = None
        self._setup_ui()

    def _setup_ui(self):
        self.setObjectName("firma_widget_root")
        self.setStyleSheet(
            "QWidget#firma_widget_root { background: #F5F5F7; } "
            "QLabel { border: none; background: transparent; }"
        )

        main_lay = QVBoxLayout(self)
        main_lay.setContentsMargins(32, 28, 32, 32)
        main_lay.setSpacing(18)

        hdr = QLabel("Mi Firma Digital")
        hdr.setStyleSheet("font-size: 20px; font-weight: 700; color: #1D1D1F;")
        main_lay.addWidget(hdr)

        sub = QLabel(
            "Registra o actualiza tu firma autógrafa digital. Se inserta automáticamente "
            "en tus Órdenes de Servicio, formatos de campo y certificados PDF."
        )
        sub.setWordWrap(True)
        sub.setStyleSheet("font-size: 13px; color: #6E6E73;")
        main_lay.addWidget(sub)

        card = QFrame()
        card.setObjectName("firma_profile_card")
        card.setProperty("card", True)
        card.setStyleSheet(
            "QFrame#firma_profile_card { "
            "background: #FFFFFF; border: 1px solid #E5E5EA; border-radius: 14px; }"
        )
        card_lay = QVBoxLayout(card)
        card_lay.setContentsMargins(24, 22, 24, 22)
        card_lay.setSpacing(14)

        status_row = QHBoxLayout()
        self._status_dot = QFrame()
        self._status_dot.setFixedSize(6, 6)
        self._status_dot.setStyleSheet("background: #6E6E73; border-radius: 3px; border: none;")
        status_row.addWidget(self._status_dot)

        self._lbl_status = QLabel("Consultando perfil de firma...")
        self._lbl_status.setStyleSheet("font-size: 13px; font-weight: 600; color: #6E6E73;")
        status_row.addWidget(self._lbl_status)
        status_row.addStretch()
        card_lay.addLayout(status_row)

        self._img_preview = QLabel("Sin firma registrada")
        self._img_preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._img_preview.setMinimumHeight(210)
        self._img_preview.setStyleSheet(
            "border: 1px dashed #D2D2D7; border-radius: 10px; background: #F2F2F7; "
            "color: #6E6E73; font-size: 13px;"
        )
        card_lay.addWidget(self._img_preview)

        self._canvas = DrawingCanvas(parent=card)
        self._canvas.hide()
        self._canvas.signature_changed.connect(self._on_signature_changed)
        card_lay.addWidget(self._canvas)

        btn_lay = QHBoxLayout()
        btn_lay.setSpacing(10)

        self._btn_modal = QPushButton("Capturar en Modal")
        self._btn_modal.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_modal.setFixedHeight(38)
        self._btn_modal.clicked.connect(self._on_abrir_modal)

        self._btn_reemplazar = QPushButton("Reemplazar Firma")
        self._btn_reemplazar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_reemplazar.setFixedHeight(38)
        self._btn_reemplazar.clicked.connect(self._on_reemplazar_clicked)

        self._btn_limpiar = QPushButton("Limpiar")
        self._btn_limpiar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_limpiar.setFixedHeight(38)
        self._btn_limpiar.clicked.connect(self._canvas.clear)
        self._btn_limpiar.hide()

        self._btn_cancelar = QPushButton("Cancelar")
        self._btn_cancelar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_cancelar.setFixedHeight(38)
        self._btn_cancelar.clicked.connect(self._on_cancelar_edicion)
        self._btn_cancelar.hide()

        self._btn_guardar = QPushButton("Guardar y Sincronizar Firma")
        self._btn_guardar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_guardar.setFixedHeight(38)
        self._btn_guardar.setStyleSheet(
            "QPushButton { background: #C8102E; color: #FFFFFF; border: 1px solid #C8102E; "
            "border-radius: 8px; font-size: 13px; font-weight: 600; padding: 0 20px; } "
            "QPushButton:hover { background: #A60D26; } "
            "QPushButton:disabled { background: #E5E7EB; color: #9CA3AF; border-color: #E5E7EB; }"
        )
        self._btn_guardar.clicked.connect(self._on_guardar_clicked)
        self._btn_guardar.hide()

        btn_lay.addWidget(self._btn_modal)
        btn_lay.addStretch()
        btn_lay.addWidget(self._btn_reemplazar)
        btn_lay.addWidget(self._btn_cancelar)
        btn_lay.addWidget(self._btn_limpiar)
        btn_lay.addWidget(self._btn_guardar)

        card_lay.addLayout(btn_lay)
        main_lay.addWidget(card)
        main_lay.addStretch()

    def showEvent(self, event):
        super().showEvent(event)
        self._load_signature()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._refresh_scaled_preview()

    def _current_uid(self) -> Optional[int]:
        if not _session or not _session.is_authenticated:
            return None
        return _session.id_tecnico or _session.user_id

    def _load_signature(self):
        uid = self._current_uid()
        if not uid:
            self._set_status("Usuario sin perfil de técnico activo.", "#D97706")
            return
        if self._load_worker is not None and self._load_worker.isRunning():
            return
        self._load_worker = _LoadFirmaWorker(int(uid), self)
        self._load_worker.loaded.connect(self._on_firma_loaded)
        self._load_worker.empty.connect(self._on_firma_empty)
        self._load_worker.failed.connect(self._on_firma_load_error)
        self._load_worker.start()

    def _set_status(self, text: str, dot_color: str) -> None:
        self._lbl_status.setText(text)
        self._lbl_status.setStyleSheet("font-size: 13px; font-weight: 600; color: #111827;")
        self._status_dot.setStyleSheet(f"background: {dot_color}; border-radius: 4px; border: none;")

    def _on_firma_loaded(self, b64: str) -> None:
        self._show_preview(b64)

    def _on_firma_empty(self) -> None:
        self._set_status("Sin firma registrada — captura tu firma para comenzar.", "#D97706")
        self._img_preview.setPixmap(QPixmap())
        self._img_preview.setText("Sin firma registrada")

    def _on_firma_load_error(self, err: str) -> None:
        self._set_status("No se pudo consultar la firma en el servidor.", "#C8102E")
        self._img_preview.setText(f"Error de conexión: {err}")

    def _show_preview(self, b64_data: str):
        self._current_b64 = b64_data
        self._img_preview.show()
        self._canvas.hide()
        self._btn_modal.show()
        self._btn_reemplazar.show()
        self._btn_cancelar.hide()
        self._btn_limpiar.hide()
        self._btn_guardar.hide()

        self._set_status("Firma Registrada en Servidor", "#16A34A")

        clean = b64_data
        if clean.startswith("data:image") and "base64," in clean:
            clean = clean.split("base64,", 1)[-1]

        try:
            raw_bytes = base64.b64decode(clean.strip())
            img = QImage()
            if img.loadFromData(raw_bytes) and not img.isNull():
                self._current_pixmap = QPixmap.fromImage(img)
                self._refresh_scaled_preview()
            else:
                self._current_pixmap = None
                self._img_preview.setText("Formato de imagen inválido")
        except Exception:
            self._current_pixmap = None
            self._img_preview.setText("Error decodificando firma")

    def _refresh_scaled_preview(self) -> None:
        if self._current_pixmap is None or self._current_pixmap.isNull():
            return
        w = max(280, self._img_preview.width() - 24)
        h = max(140, self._img_preview.height() - 24)
        self._img_preview.setPixmap(
            self._current_pixmap.scaled(
                w, h,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )

    def _on_abrir_modal(self):
        uid = self._current_uid()
        b64 = PesaSignatureDialog.capturar(
            parent=self,
            title="Actualizar Firma Digital",
            uid_tecnico=uid,
            save_to_db=bool(uid),
        )
        if b64:
            self._show_preview(b64)
            self.firma_guardada.emit(b64)
            self._notify_saved("Firma guardada correctamente")

    def _on_reemplazar_clicked(self):
        self._img_preview.hide()
        self._canvas.show()
        self._canvas.clear()

        self._btn_modal.hide()
        self._btn_reemplazar.hide()
        self._btn_cancelar.show()
        self._btn_limpiar.show()
        self._btn_guardar.show()
        self._btn_guardar.setEnabled(False)

        self._set_status("Traza tu nueva firma en el recuadro:", "#111827")

    def _on_cancelar_edicion(self):
        if self._current_b64:
            self._show_preview(self._current_b64)
        else:
            self._canvas.hide()
            self._img_preview.show()
            self._btn_modal.show()
            self._btn_reemplazar.show()
            self._btn_cancelar.hide()
            self._btn_limpiar.hide()
            self._btn_guardar.hide()

    def _on_signature_changed(self):
        self._btn_guardar.setEnabled(not self._canvas.is_empty())

    def _on_guardar_clicked(self):
        uid = self._current_uid()
        if not uid:
            QMessageBox.warning(self, "Error", "No se identificó el ID del técnico en sesión.")
            return

        b64 = self._canvas.get_base64()
        if not b64:
            QMessageBox.warning(self, "Validación", "Traza tu firma antes de guardar.")
            return

        self._btn_guardar.setText("Guardando...")
        self._btn_guardar.setEnabled(False)
        self._btn_limpiar.setEnabled(False)
        self._btn_cancelar.setEnabled(False)

        self._save_worker = _SaveFirmaWorker(int(uid), b64, self)
        self._save_worker.saved_ok.connect(self._on_save_worker_ok)
        self._save_worker.failed.connect(self._on_save_worker_err)
        self._save_worker.start()

    def _on_save_worker_ok(self, b64: str, regen_count: int) -> None:
        self._btn_guardar.setText("Guardar y Sincronizar Firma")
        self._btn_limpiar.setEnabled(True)
        self._btn_cancelar.setEnabled(True)
        self._show_preview(b64)
        self.firma_guardada.emit(b64)
        msg = "Firma guardada correctamente"
        if regen_count:
            msg = f"Firma guardada correctamente ({regen_count} PDF(s) actualizados)"
        self._notify_saved(msg)

    def _on_save_worker_err(self, err: str) -> None:
        self._btn_guardar.setText("Guardar y Sincronizar Firma")
        self._btn_guardar.setEnabled(not self._canvas.is_empty())
        self._btn_limpiar.setEnabled(True)
        self._btn_cancelar.setEnabled(True)
        QMessageBox.critical(self, "Error", f"No se pudo guardar la firma:\n{err}")

    def _notify_saved(self, msg: str) -> None:
        win = self.window()
        if hasattr(win, "show_toast"):
            try:
                win.show_toast(msg)
                return
            except Exception:
                pass
        QMessageBox.information(self, "Firma Digital", msg)
