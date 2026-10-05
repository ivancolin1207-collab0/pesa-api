"""
Widget de carga de escaneos.
Permite seleccionar una OS y adjuntarle su formato físico escaneado.
"""
import logging
from typing import Optional

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QLineEdit, QFileDialog, QMessageBox, QComboBox, QFrame,
    QProgressBar, QCompleter
)
from PyQt6.QtCore import Qt, QThread, pyqtSignal

logger = logging.getLogger(__name__)


class ScannerWidget(QWidget):
    """
    Módulo para adjuntar archivos escaneados a una OS.

    Flujo:
        1. El técnico busca/selecciona la OS (por folio).
        2. Hace clic en "Seleccionar Archivo" y elige el PDF o imagen.
        3. Hace clic en "Adjuntar" y el servicio copia el archivo al servidor,
           lo renombra y actualiza el estado de la OS a ESCANEADA.
    """

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self._selected_os: Optional[dict] = None
        self._selected_file: str = ""
        self._setup_ui()
        self._populate_folios()

    def set_folio(self, folio: str) -> None:
        """Permite establecer un folio desde otra vista y buscarlo automáticamente."""
        if not folio:
            return
        
        self._txt_folio.setCurrentText(folio)
        # Asegurar que se haga la búsqueda
        self._search_os()

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 20)
        root.setSpacing(20)

        # Título
        title = QLabel("📎  Adjuntar Escaneo a Orden de Servicio")
        title.setStyleSheet("font-size:18px; font-weight:800; color:#1D1D1F;")
        root.addWidget(title)

        # Instrucciones
        note = QLabel(
            "El archivo será copiado y renombrado automáticamente al servidor central.\n"
            "Formato de nombre: OS-AA-NNN-ESCANEADO.pdf"
        )
        note.setStyleSheet(
            "background:#EBF5FF; color:#0A3663; border:1px solid #BFE0FF; "
            "border-radius:6px; padding:10px 14px; font-size:12px; line-height:1.6;"
        )
        note.setWordWrap(True)
        root.addWidget(note)

        # ── Paso 1: Buscar OS ─────────────────────────────────────────────────
        step1 = QFrame()
        step1.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:8px;")
        s1_layout = QVBoxLayout(step1)
        s1_layout.setContentsMargins(16, 14, 16, 14)
        s1_layout.setSpacing(10)

        lbl1 = QLabel("PASO 1 — Buscar la Orden de Servicio")
        lbl1.setStyleSheet("color:#E63946; font-size:11px; font-weight:800; letter-spacing:1px;")
        s1_layout.addWidget(lbl1)

        search_row = QHBoxLayout()
        self._txt_folio = QComboBox()
        self._txt_folio.setEditable(True)
        self._txt_folio.lineEdit().setPlaceholderText("Escribir folio (Ej. OS-26-443) o seleccionar...")
        self._txt_folio.setFixedHeight(36)
        self._txt_folio.setStyleSheet("""
            QComboBox { background: white; border: 1px solid #D1D1D6; border-radius: 4px; padding: 4px; }
            QComboBox::drop-down { border: none; }
        """)
        search_row.addWidget(self._txt_folio, stretch=1)

        btn_buscar = QPushButton("🔍  Buscar")
        btn_buscar.setFixedWidth(110)
        btn_buscar.clicked.connect(self._search_os)
        search_row.addWidget(btn_buscar)
        s1_layout.addLayout(search_row)

        # Info de OS encontrada
        self._lbl_os_info = QLabel("—  Sin OS seleccionada")
        self._lbl_os_info.setStyleSheet("color:#86868B; font-size:12px; padding:4px 0;")
        s1_layout.addWidget(self._lbl_os_info)

        root.addWidget(step1)

        # ── Paso 2: Seleccionar archivo ───────────────────────────────────────
        step2 = QFrame()
        step2.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:8px;")
        s2_layout = QVBoxLayout(step2)
        s2_layout.setContentsMargins(16, 14, 16, 14)
        s2_layout.setSpacing(10)

        lbl2 = QLabel("PASO 2 — Seleccionar el archivo escaneado")
        lbl2.setStyleSheet("color:#E63946; font-size:11px; font-weight:800; letter-spacing:1px;")
        s2_layout.addWidget(lbl2)

        file_row = QHBoxLayout()
        self._txt_file = QLineEdit()
        self._txt_file.setPlaceholderText("Ruta del archivo PDF o imagen...")
        self._txt_file.setReadOnly(True)
        self._txt_file.setFixedHeight(36)
        file_row.addWidget(self._txt_file)

        btn_browse = QPushButton("📂  Examinar...")
        btn_browse.setFixedWidth(130)
        btn_browse.clicked.connect(self._browse_file)
        file_row.addWidget(btn_browse)
        s2_layout.addLayout(file_row)

        self._lbl_file_info = QLabel("—  Sin archivo seleccionado")
        self._lbl_file_info.setStyleSheet("color:#86868B; font-size:12px; padding:4px 0;")
        s2_layout.addWidget(self._lbl_file_info)

        root.addWidget(step2)

        # ── Paso 3: Adjuntar ──────────────────────────────────────────────────
        step3 = QFrame()
        step3.setStyleSheet("background:#FFFFFF; border:1px solid #D1D1D6; border-radius:8px;")
        s3_layout = QVBoxLayout(step3)
        s3_layout.setContentsMargins(16, 14, 16, 14)
        s3_layout.setSpacing(10)

        lbl3 = QLabel("PASO 3 — Adjuntar al servidor")
        lbl3.setStyleSheet("color:#E63946; font-size:11px; font-weight:800; letter-spacing:1px;")
        s3_layout.addWidget(lbl3)

        self._btn_adjuntar = QPushButton("📎  Adjuntar y Marcar como Escaneada")
        self._btn_adjuntar.setProperty("class", "success")
        self._btn_adjuntar.setFixedHeight(42)
        self._btn_adjuntar.setEnabled(False)
        self._btn_adjuntar.clicked.connect(self._attach)
        s3_layout.addWidget(self._btn_adjuntar)

        self._progress = QProgressBar()
        self._progress.setVisible(False)
        self._progress.setRange(0, 0)   # Indeterminado
        s3_layout.addWidget(self._progress)

        root.addWidget(step3)
        root.addStretch()

    # ── Métodos ───────────────────────────────────────────────────────────────

    def _populate_folios(self) -> None:
        try:
            from database.connection import db_pool
            conn = db_pool.get_connection()
            with conn.cursor() as cur:
                cur.execute("SELECT folio_os FROM ordenes_servicio WHERE estado = 'PROCESO' ORDER BY fecha DESC, created_at DESC")
                folios = [row[0] for row in cur.fetchall() if row[0]]
            db_pool.release_connection(conn)
            
            self._txt_folio.clear()
            self._txt_folio.addItem("") # Vacío
            self._txt_folio.addItems(folios)
            
            completer = QCompleter(folios, self)
            completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
            completer.setFilterMode(Qt.MatchFlag.MatchContains)
            self._txt_folio.setCompleter(completer)
        except Exception as e:
            logger.warning(f"Error cargando folios para escaneo: {e}")

    def _search_os(self) -> None:
        folio = self._txt_folio.currentText().strip().upper()
        if not folio:
            return
        try:
            from models.orden_servicio import orden_servicio_repo
            os_data = orden_servicio_repo.get_by_folio(folio)

            if not os_data:
                self._lbl_os_info.setText(f"❌  No se encontró la OS: {folio}")
                self._lbl_os_info.setStyleSheet("color:#FF3B30; font-size:12px;")
                self._selected_os = None
            else:
                estado = os_data.get("estado", "")
                cliente = os_data.get("cliente", "—")
                fecha = str(os_data.get("fecha", ""))[:10]

                self._selected_os = dict(os_data)
                self._lbl_os_info.setText(
                    f"✅  {folio}  |  {cliente}  |  {fecha}  |  Estado: {estado}"
                )
                self._lbl_os_info.setStyleSheet("color:#34C759; font-size:12px; font-weight:600;")

                if estado == "ESCANEADA":
                    self._lbl_os_info.setText(
                        self._lbl_os_info.text() + "\n⚠️  Esta OS ya tiene un escaneo. Se sobreescribirá."
                    )
                    self._lbl_os_info.setStyleSheet("color:#FF9F0A; font-size:12px;")

        except Exception as exc:
            logger.error(f"Error al buscar OS: {exc}")
            self._lbl_os_info.setText(f"Error al buscar: {exc}")
            self._lbl_os_info.setStyleSheet("color:#FF3B30; font-size:12px;")

        self._update_attach_btn()

    def _browse_file(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Seleccionar archivo escaneado",
            "",
            "Archivos soportados (*.pdf *.jpg *.jpeg *.png *.tif *.tiff);;Todos (*.*)",
        )
        if path:
            self._selected_file = path
            self._txt_file.setText(path)
            from pathlib import Path
            size_kb = Path(path).stat().st_size // 1024
            ext = Path(path).suffix.upper()
            self._lbl_file_info.setText(f"✅  {Path(path).name}  ({ext}, {size_kb} KB)")
            self._lbl_file_info.setStyleSheet("color:#34C759; font-size:12px; font-weight:600;")
        self._update_attach_btn()

    def _update_attach_btn(self) -> None:
        self._btn_adjuntar.setEnabled(
            self._selected_os is not None and bool(self._selected_file)
        )

    def _attach(self) -> None:
        if not self._selected_os or not self._selected_file:
            return

        self._btn_adjuntar.setEnabled(False)
        self._progress.setVisible(True)

        try:
            from services.scanner_service import scanner_service
            result = scanner_service.attach_scan(
                os_id=self._selected_os["id"],
                folio_os=self._selected_os["folio_os"],
                source_path=self._selected_file,
            )
            self._progress.setVisible(False)
            QMessageBox.information(
                self,
                "Éxito",
                f"✅ Escaneo adjuntado correctamente.\n\n"
                f"Archivo: {result['nombre_archivo']}\n"
                f"MD5: {result['hash_md5']}\n"
                f"Tamaño: {result['tamano_bytes'] // 1024} KB\n\n"
                f"La OS fue marcada como ESCANEADA.",
            )
            # Limpiar formulario
            self._selected_os    = None
            self._selected_file  = ""
            self._txt_folio.setCurrentText("")
            self._txt_file.clear()
            self._lbl_os_info.setText("—  Sin OS seleccionada")
            self._lbl_os_info.setStyleSheet("color:#86868B; font-size:12px;")
            self._lbl_file_info.setText("—  Sin archivo seleccionado")
            self._lbl_file_info.setStyleSheet("color:#86868B; font-size:12px;")
            self._btn_adjuntar.setEnabled(False)

        except Exception as exc:
            self._progress.setVisible(False)
            self._btn_adjuntar.setEnabled(True)
            logger.error(f"Error al adjuntar escaneo: {exc}")
            QMessageBox.critical(self, "Error al Adjuntar", str(exc))
