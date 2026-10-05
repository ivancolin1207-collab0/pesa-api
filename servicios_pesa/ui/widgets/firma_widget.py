import base64
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, 
    QFrame, QMessageBox, QSizePolicy
)
from PyQt6.QtCore import Qt, QPointF, pyqtSignal, QByteArray, QBuffer, QIODevice
from PyQt6.QtGui import QPainter, QPen, QColor, QImage, QPixmap, QPainterPath

from auth.session_context import session as _session
from database.connection import db_pool
import logging

logger = logging.getLogger(__name__)

_BLUE = "#007AFF"
_RED = "#B81D24"
_GRAY = "#86868B"
_LGRAY = "#E5E5EA"

class DrawingCanvas(QWidget):
    """Canvas de firma táctil/mouse para capturar la firma."""
    signature_changed = pyqtSignal()

    def __init__(self, placeholder: str = "Firme aquí", parent=None):
        super().__init__(parent)
        self._placeholder = placeholder
        self._strokes: list[list[QPointF]] = []
        self._current_stroke: list[QPointF] = []
        self._drawing = False
        self.setMinimumSize(400, 200)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setAttribute(Qt.WidgetAttribute.WA_AcceptTouchEvents, True)
        self.setStyleSheet(f"""
            background: #FCFCFC;
            border: 2px solid {_LGRAY};
            border-radius: 12px;
        """)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drawing = True
            self._current_stroke = [QPointF(event.position())]

    def mouseMoveEvent(self, event):
        if self._drawing and event.buttons() & Qt.MouseButton.LeftButton:
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

        if not self._strokes and not self._current_stroke:
            p.setPen(QColor("#C7C7CC"))
            font = p.font()
            font.setPointSize(16)
            font.setItalic(True)
            p.setFont(font)
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self._placeholder)
            return

        pen = QPen(QColor("#1D1D1F"), 3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
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

    def clear(self):
        self._strokes.clear()
        self._current_stroke.clear()
        self._drawing = False
        self.update()
        self.signature_changed.emit()

    def is_empty(self) -> bool:
        return len(self._strokes) == 0

    def get_base64(self) -> str:
        """Retorna la firma como imagen PNG en base64."""
        if self.is_empty():
            return ""
        # Create image with transparent background
        img = QImage(self.size(), QImage.Format.Format_ARGB32)
        img.fill(Qt.GlobalColor.transparent)
        p = QPainter(img)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        
        pen = QPen(QColor("#000000"), 3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        
        for stroke in self._strokes:
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

        # Scale down for efficient storage (e.g. 800 width max)
        if img.width() > 800:
            img = img.scaledToWidth(800, Qt.TransformationMode.SmoothTransformation)
            
        ba = QByteArray()
        buf = QBuffer(ba)
        buf.open(QIODevice.OpenModeFlag.WriteOnly)
        img.save(buf, "PNG")
        buf.close()
        return ba.toBase64().data().decode("utf-8")


class FirmaWidget(QWidget):
    """
    Vista de gestión de firma técnica.
    Muestra la firma actual desde el servidor y permite actualizarla.
    """
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self._setup_ui()
        
    def _setup_ui(self):
        main_lay = QVBoxLayout(self)
        main_lay.setContentsMargins(40, 40, 40, 40)
        main_lay.setSpacing(20)
        
        # Header
        lbl_title = QLabel("Mi Firma Técnica")
        lbl_title.setStyleSheet("font-size: 24px; font-weight: 600; color: #1D1D1F;")
        
        lbl_desc = QLabel("La firma que guardes aquí se utilizará automáticamente en las órdenes de servicio, remisiones y reportes. Asegúrate de que sea legible.")
        lbl_desc.setStyleSheet("font-size: 14px; color: #86868B;")
        lbl_desc.setWordWrap(True)
        
        main_lay.addWidget(lbl_title)
        main_lay.addWidget(lbl_desc)
        main_lay.addSpacing(10)
        
        # Tarjeta Principal
        card = QFrame()
        card.setObjectName("firma_card")
        card.setStyleSheet("""
            QFrame#firma_card {
                background: #FFFFFF;
                border: 1px solid #E5E5EA;
                border-radius: 12px;
            }
        """)
        card_lay = QVBoxLayout(card)
        card_lay.setContentsMargins(24, 24, 24, 24)
        card_lay.setSpacing(16)
        
        # Status
        self._lbl_status = QLabel("Consultando estado de firma...")
        self._lbl_status.setStyleSheet("font-size: 14px; font-weight: 500; color: #86868B;")
        self._lbl_status.setAlignment(Qt.AlignmentFlag.AlignCenter)
        card_lay.addWidget(self._lbl_status)
        
        # Imagen / Canvas Switcher
        self._lay_preview = QVBoxLayout()
        self._img_preview = QLabel()
        self._img_preview.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._img_preview.setMinimumHeight(200)
        self._img_preview.setStyleSheet(f"border: 2px dashed {_LGRAY}; border-radius: 12px; background: #FAFAFA;")
        self._lay_preview.addWidget(self._img_preview)
        
        self._canvas = DrawingCanvas()
        self._canvas.hide()
        self._canvas.signature_changed.connect(self._on_signature_changed)
        
        card_lay.addLayout(self._lay_preview)
        card_lay.addWidget(self._canvas)
        
        # Botones
        btn_lay = QHBoxLayout()
        self._btn_reemplazar = QPushButton("Reemplazar Firma")
        self._btn_reemplazar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_reemplazar.setFixedHeight(40)
        self._btn_reemplazar.setStyleSheet(f"""
            QPushButton {{
                background: #F2F2F7; color: {_BLUE}; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; padding: 0 20px;
            }}
            QPushButton:hover {{ background: #E5E5EA; }}
        """)
        self._btn_reemplazar.clicked.connect(self._on_reemplazar_clicked)
        
        self._btn_limpiar = QPushButton("Limpiar")
        self._btn_limpiar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_limpiar.setFixedHeight(40)
        self._btn_limpiar.setStyleSheet(f"""
            QPushButton {{
                background: #F2F2F7; color: {_GRAY}; border: none; border-radius: 8px; font-size: 14px; font-weight: 500; padding: 0 20px;
            }}
            QPushButton:hover {{ background: #E5E5EA; }}
        """)
        self._btn_limpiar.clicked.connect(self._canvas.clear)
        self._btn_limpiar.hide()
        
        self._btn_guardar = QPushButton("Guardar y Sincronizar Firma")
        self._btn_guardar.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_guardar.setFixedHeight(40)
        self._btn_guardar.setStyleSheet(f"""
            QPushButton {{
                background: {_RED}; color: white; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; padding: 0 24px;
            }}
            QPushButton:hover {{ background: #9B171E; }}
            QPushButton:disabled {{ background: #FFC5C7; }}
        """)
        self._btn_guardar.clicked.connect(self._on_guardar_clicked)
        self._btn_guardar.hide()
        
        btn_lay.addStretch()
        btn_lay.addWidget(self._btn_reemplazar)
        btn_lay.addWidget(self._btn_limpiar)
        btn_lay.addWidget(self._btn_guardar)
        
        card_lay.addLayout(btn_lay)
        main_lay.addWidget(card)
        main_lay.addStretch()
        
    def showEvent(self, event):
        super().showEvent(event)
        self._load_signature()
        
    def _load_signature(self):
        if not _session or not _session.is_authenticated:
            self._lbl_status.setText("Usuario no autenticado.")
            return
            
        uid = _session.id_tecnico or _session.user_id
        if not uid:
            self._lbl_status.setText("No se encontro un ID de usuario/tecnico.")
            return
            
        try:
            with db_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT firma_digital FROM cat_tecnicos WHERE id = %s", (uid,))
                    row = cur.fetchone()
                    if row and row[0]:
                        self._show_preview(row[0])
                        return
            
            # Si no hay firma
            self._lbl_status.setText("No tienes una firma registrada.")
            self._lbl_status.setStyleSheet("font-size: 14px; font-weight: 500; color: #FF9F0A;")
            self._img_preview.setText("Sin firma registrada")
            
        except Exception as e:
            logger.error("Error al cargar firma desde BD: %s", e)
            self._lbl_status.setText("Error al consultar firma desde la base de datos.")
            self._img_preview.setText("Error de conexion")

    def _show_preview(self, b64_data: str):
        self._img_preview.show()
        self._canvas.hide()
        self._btn_reemplazar.show()
        self._btn_limpiar.hide()
        self._btn_guardar.hide()
        
        self._lbl_status.setText("✓ Firma Registrada en Servidor")
        self._lbl_status.setStyleSheet("font-size: 14px; font-weight: 600; color: #34C759;")
        
        # Limpiar prefix de data uri si existe
        if b64_data.startswith("data:image"):
            b64_data = b64_data.split("base64,")[-1]
            
        try:
            import base64
            raw_bytes = base64.b64decode(b64_data.strip())
            img = QImage()
            img.loadFromData(raw_bytes)
            if not img.isNull():
                pix = QPixmap.fromImage(img)
                self._img_preview.setPixmap(pix.scaled(
                    self._img_preview.size(), 
                    Qt.AspectRatioMode.KeepAspectRatio, 
                    Qt.TransformationMode.SmoothTransformation
                ))
            else:
                self._img_preview.setText("Formato de imagen invalido")
        except Exception:
            self._img_preview.setText("Error decodificando imagen")

    def _on_reemplazar_clicked(self):
        self._img_preview.hide()
        self._canvas.show()
        self._canvas.clear()
        
        self._btn_reemplazar.hide()
        self._btn_limpiar.show()
        self._btn_guardar.show()
        self._btn_guardar.setEnabled(False)
        
        self._lbl_status.setText("Dibuja tu nueva firma en el recuadro:")
        self._lbl_status.setStyleSheet("font-size: 14px; font-weight: 500; color: #1D1D1F;")
        
    def _on_signature_changed(self):
        self._btn_guardar.setEnabled(not self._canvas.is_empty())
        
    def _on_guardar_clicked(self):
        if not _session or not _session.is_authenticated:
            return
            
        uid = _session.id_tecnico or _session.user_id
        if not uid:
            QMessageBox.warning(self, "Error", "No se identifico el ID del usuario.")
            return
            
        b64 = self._canvas.get_base64()
        if not b64:
            return
            
        self._btn_guardar.setText("Guardando...")
        self._btn_guardar.setEnabled(False)
        
        try:
            with db_pool.get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("UPDATE cat_tecnicos SET firma_digital = %s WHERE id = %s", (b64, uid))
                    
                    # REGLA DE NEGOCIO: Regenerar/actualizar la firma ÚNICAMENTE del técnico en todos los PDFs de órdenes ya realizadas/cerradas
                    cur.execute("""
                        SELECT id, folio_os FROM ordenes_servicio 
                        WHERE id_tecnico = %s AND (estado IN ('CERRADA', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA') OR estatus IN ('Cerrado', 'CERRADO'))
                    """, (uid,))
                    closed_orders = cur.fetchall()
                    
                    if closed_orders:
                        cur.execute("""
                            UPDATE ordenes_servicio 
                            SET firma_tecnico_b64 = %s,
                                firma_tecnico = %s,
                                updated_at = NOW() 
                            WHERE id_tecnico = %s AND (estado IN ('CERRADA', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA') OR estatus IN ('Cerrado', 'CERRADO'))
                        """, (b64, b64, uid))
                conn.commit()
            
            if closed_orders:
                from services.pdf_router import regenerar_pdf
                for os_id, folio in closed_orders:
                    regenerar_pdf(os_id, folio, force=True)
            
            QMessageBox.information(
                self, "Exito", 
                "✓ Firma actualizada.\nSe utilizara automaticamente en la tablet y en escritorio para emitir ordenes."
            )
            self._show_preview(b64)
                
        except Exception as e:
            logger.error("Error al guardar firma en BD: %s", e)
            QMessageBox.critical(self, "Error", f"Error de BD al guardar la firma:\n{e}")
        finally:
            self._btn_guardar.setText("Guardar y Sincronizar Firma")
            self._btn_guardar.setEnabled(True)
