"""
main_window.py — Ventana principal Servicios PESA v2.0
Diseño Apple Human Interface Guidelines — Sidebar blanco minimalista.

Layout:
    ┌──────────────────┬──────────────────────────────────────────┐
    │  Sidebar  (220px)│  Header (breadcrumb + acciones)          │
    │  ─────────────── ├──────────────────────────────────────────┤
    │  Logo            │                                          │
    │  ─────────────── │   Área de Contenido (QStackedWidget)     │
    │  Navegación      │   Fondo: #F5F5F7                         │
    │  (filtrada RBAC) │                                          │
    │  ─────────────── │                                          │
    │  [chip usuario]  │                                          │
    │  ● BD Conectada  │                                          │
    └──────────────────┴──────────────────────────────────────────┘
    │                     Status Bar (24px)                        │
    └──────────────────────────────────────────────────────────────┘
"""
from __future__ import annotations

import logging
from typing import Optional

from PyQt6.QtCore    import Qt, QTimer, QPropertyAnimation, QEasingCurve, QParallelAnimationGroup, QPointF, QRectF
from PyQt6.QtGui     import QFont, QColor, QPainter, QPen, QPainterPath
from PyQt6.QtWidgets import (
    QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
    QPushButton, QLabel, QStackedWidget, QStatusBar,
    QFrame, QMessageBox, QSizePolicy, QScrollArea,
    QApplication, QTabWidget,
)

from config import APP_NAME, APP_VERSION, WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT

logger = logging.getLogger(__name__)

# ─── Importar sesión (con fallback si no está listo aún) ─────────────────────
try:
    from auth.session_context import session as _session
    _HAS_SESSION = True
except ImportError:
    _HAS_SESSION = False
    _session = None

# ─── Precarga de widgets para garantizar resolución en PyInstaller ───────────
try:
    from ui.widgets.dashboard_widget import DashboardWidget
except Exception as _e_dash:
    logger.debug("DashboardWidget precarga: %s", _e_dash)
    DashboardWidget = None

try:
    from ui.widgets.batch_generator_widget import BatchGeneratorWidget
except Exception as _e_batch:
    logger.debug("BatchGeneratorWidget precarga: %s", _e_batch)
    BatchGeneratorWidget = None

try:
    from ui.widgets.os_form_widget import OSFormWidget
except Exception as _e_os:
    logger.debug("OSFormWidget precarga: %s", _e_os)
    OSFormWidget = None

try:
    from ui.widgets.lp_form_widget import LPFormWidget
except Exception as _e_lp:
    logger.debug("LPFormWidget precarga: %s", _e_lp)
    LPFormWidget = None

try:
    from ui.widgets.lv_form_widget import LVFormWidget
except Exception as _e_lv:
    logger.debug("LVFormWidget precarga: %s", _e_lv)
    LVFormWidget = None

try:
    from ui.widgets.recepcion_widget import RecepcionWidget
except Exception as _e_rec:
    logger.debug("RecepcionWidget precarga: %s", _e_rec)
    RecepcionWidget = None

try:
    from ui.widgets.scanner_widget import ScannerWidget
except Exception as _e_scan:
    logger.debug("ScannerWidget precarga: %s", _e_scan)
    ScannerWidget = None

try:
    from ui.widgets.catalogos_widget import CatalogosWidget
except Exception as _e_cat:
    logger.debug("CatalogosWidget precarga: %s", _e_cat)
    CatalogosWidget = None

try:
    from ui.widgets.configuracion_widget import ConfiguracionWidget
except Exception as _e_cfg:
    logger.debug("ConfiguracionWidget precarga: %s", _e_cfg)
    ConfiguracionWidget = None


# ─── Definición del menú corporativo (iconos vectoriales QPainter, sin emojis) ─
_NAV_ITEMS: list[tuple[str, str, str, str, list[str]]] = [
    ("dashboard",     "dashboard",     "Dashboard",          "Tablero y resumen de actividad",               ["admin", "logistica", "servicio", "recepcion"]),
    ("mi_firma",      "mi_firma",      "Mi Firma",           "Gestionar firma registrada en servidor",       ["admin", "servicio", "calibrador", "inspector"]),
    ("lote",          "lote",          "Generar Formatos",   "Asistente de generación de OS, RMA y RE",     ["admin", "logistica"]),
    ("buscar_os",     "buscar_os",     "Buscar / Historial", "Buscar, editar y consultar órdenes",           ["admin", "logistica", "recepcion", "calibrador", "inspector"]),
    ("recepcion_os",  "recepcion_os",  "Recepción / Entrega","Control de entrega semanal de OS por fecha",   ["admin", "logistica", "recepcion"]),
    ("escaneos",      "escaneos",      "Adjuntar Escaneo",   "Adjuntar formato físico escaneado",            ["admin", "logistica", "servicio"]),
    ("catalogos",     "catalogos",     "Catálogos",          "Clientes, técnicos e instrumentos",            ["admin"]),
    ("configuracion", "configuracion", "Configuración",      "Conexión a BD y ajustes del sistema",          ["admin"]),
]

_ICON_MAP: dict[str, str] = {k: k for k, *_ in _NAV_ITEMS}


class VectorNavIcon(QWidget):
    """Dibuja iconos vectoriales geométricos limpios (1.7px) para navegación corporativa."""

    def __init__(self, icon_key: str, color: str = "#475569", parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._key = icon_key
        self._color = QColor(color)
        self.setFixedSize(20, 20)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)

    def set_color(self, hex_color: str) -> None:
        self._color = QColor(hex_color)
        self.update()

    @staticmethod
    def _dl(p: QPainter, x1: float, y1: float, x2: float, y2: float) -> None:
        """Traza una línea vectorial usando QPointF explícito (compatible 100% con PyQt6)."""
        p.drawLine(QPointF(float(x1), float(y1)), QPointF(float(x2), float(y2)))

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        pen = QPen(self._color, 1.65, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        k = self._key
        dl = self._dl

        if k == "dashboard":
            p.drawRoundedRect(QRectF(2.5, 2.5, 6.2, 6.2), 1.5, 1.5)
            p.drawRoundedRect(QRectF(11.3, 2.5, 6.2, 6.2), 1.5, 1.5)
            p.drawRoundedRect(QRectF(2.5, 11.3, 6.2, 6.2), 1.5, 1.5)
            p.drawRoundedRect(QRectF(11.3, 11.3, 6.2, 6.2), 1.5, 1.5)
        elif k == "mi_firma":
            path = QPainterPath()
            path.moveTo(3.0, 16.5)
            path.lineTo(6.5, 15.5)
            path.lineTo(15.8, 6.2)
            path.lineTo(13.8, 4.2)
            path.lineTo(4.5, 13.5)
            path.closeSubpath()
            p.drawPath(path)
            dl(p, 3.0, 17.0, 17.0, 17.0)
        elif k == "lote":
            p.drawRoundedRect(QRectF(4.0, 2.5, 11.0, 14.0), 1.8, 1.8)
            dl(p, 7.0, 7.0, 12.0, 7.0)
            dl(p, 7.0, 10.0, 12.0, 10.0)
            dl(p, 7.0, 13.0, 10.0, 13.0)
        elif k == "buscar_os":
            p.drawEllipse(QRectF(3.0, 3.0, 10.5, 10.5))
            dl(p, 12.2, 12.2, 16.8, 16.8)
        elif k == "recepcion_os":
            p.drawRoundedRect(QRectF(3.0, 3.5, 14.0, 13.0), 2.0, 2.0)
            dl(p, 3.0, 11.5, 7.0, 11.5)
            dl(p, 13.0, 11.5, 17.0, 11.5)
            dl(p, 7.2, 8.2, 9.5, 10.5)
            dl(p, 9.5, 10.5, 13.2, 6.5)
        elif k == "escaneos":
            dl(p, 3.0, 6.5, 3.0, 3.5)
            dl(p, 3.0, 3.5, 6.0, 3.5)
            dl(p, 14.0, 3.5, 17.0, 3.5)
            dl(p, 17.0, 3.5, 17.0, 6.5)
            dl(p, 3.0, 13.5, 3.0, 16.5)
            dl(p, 3.0, 16.5, 6.0, 16.5)
            dl(p, 14.0, 16.5, 17.0, 16.5)
            dl(p, 17.0, 16.5, 17.0, 13.5)
            dl(p, 4.5, 10.0, 15.5, 10.0)
        elif k == "catalogos":
            p.drawEllipse(QRectF(3.5, 3.0, 13.0, 4.2))
            dl(p, 3.5, 5.1, 3.5, 14.8)
            dl(p, 16.5, 5.1, 16.5, 14.8)
            p.drawArc(QRectF(3.5, 8.2, 13.0, 4.2), int(180 * 16), int(180 * 16))
            p.drawArc(QRectF(3.5, 12.6, 13.0, 4.2), int(180 * 16), int(180 * 16))
        elif k == "configuracion":
            dl(p, 3.0, 6.0, 17.0, 6.0)
            dl(p, 3.0, 10.0, 17.0, 10.0)
            dl(p, 3.0, 14.0, 17.0, 14.0)
            p.setBrush(QColor("#FFFFFF"))
            p.drawEllipse(QRectF(6.0, 4.2, 3.6, 3.6))
            p.drawEllipse(QRectF(11.5, 8.2, 3.6, 3.6))
            p.drawEllipse(QRectF(7.5, 12.2, 3.6, 3.6))
        elif k == "brand":
            # Balanza metrológica corporativa vectorial
            dl(p, 10.0, 3.5, 10.0, 15.5)
            dl(p, 5.5, 16.2, 14.5, 16.2)
            dl(p, 4.0, 6.5, 16.0, 6.5)
            dl(p, 4.5, 6.5, 3.0, 11.2)
            dl(p, 4.5, 6.5, 6.0, 11.2)
            p.drawArc(QRectF(2.5, 10.0, 4.0, 2.5), int(180 * 16), int(180 * 16))
            dl(p, 15.5, 6.5, 14.0, 11.2)
            dl(p, 15.5, 6.5, 17.0, 11.2)
            p.drawArc(QRectF(13.5, 10.0, 4.0, 2.5), int(180 * 16), int(180 * 16))
        else:
            p.drawRoundedRect(QRectF(4.0, 4.0, 12.0, 12.0), 2.0, 2.0)
        p.end()


# ══════════════════════════════════════════════════════════════════════════════
# SidebarNavButton — Botón de navegación corporativo Básculas PESA
# ══════════════════════════════════════════════════════════════════════════════
class SidebarNavButton(QPushButton):
    """
    Botón de navegación minimalista corporativo (#FFFFFF / #FFF1F2 + #C8102E).
    """
    def __init__(self, icon: str, label: str, tooltip: str, parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self._icon    = icon
        self._label   = label
        self._active  = False
        self._collapsed = False

        self.setToolTip("")
        self.setFixedHeight(40)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        self._build_layout()
        self._apply_inactive()

    def _build_layout(self):
        lay = QHBoxLayout(self)
        self._lay = lay
        lay.setContentsMargins(12, 0, 10, 0)
        lay.setSpacing(10)

        self._lbl_icon = VectorNavIcon(self._icon, "#475569", self)
        lay.addWidget(self._lbl_icon)

        self._lbl_text = QLabel(self._label)
        self._lbl_text.setStyleSheet("font-size: 13px; font-weight: 500; background: transparent;")
        self._lbl_text.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        lay.addWidget(self._lbl_text, stretch=1)

    def set_collapsed(self, collapsed: bool) -> None:
        self._collapsed = collapsed
        if collapsed:
            self._lbl_text.hide()
            self._lay.setContentsMargins(9, 0, 9, 0)
        else:
            self._lbl_text.show()
            self._lay.setContentsMargins(12, 0, 10, 0)

    def set_active(self, active: bool) -> None:
        self._active = active
        if active:
            self._apply_active()
        else:
            self._apply_inactive()

    def _apply_active(self):
        self.setStyleSheet("""
            QPushButton {
                background-color: #F8FAFC;
                border: none;
                border-left: 3px solid #C8102E;
                border-radius: 6px;
                margin: 2px 8px;
            }
        """)
        self._lbl_icon.set_color("#C8102E")
        self._lbl_text.setStyleSheet(
            "font-size: 13px; font-weight: 700; color: #C8102E; background: transparent;"
        )

    def _apply_inactive(self):
        self.setStyleSheet("""
            QPushButton {
                background-color: transparent;
                border: none;
                border-left: 3px solid transparent;
                border-radius: 6px;
                margin: 2px 8px;
            }
            QPushButton:hover {
                background-color: #F8FAFC;
            }
            QPushButton:pressed {
                background-color: #F1F5F9;
            }
        """)
        self._lbl_icon.set_color("#475569")
        self._lbl_text.setStyleSheet(
            "font-size: 13px; font-weight: 500; color: #475569; background: transparent;"
        )

    def is_active(self) -> bool:
        return self._active


# ══════════════════════════════════════════════════════════════════════════════
# UserChip — Chip del usuario en la parte inferior del sidebar
# ══════════════════════════════════════════════════════════════════════════════
class UserChip(QFrame):
    """Muestra el usuario activo y su rol con diseño pill-chip."""

    _ROLE_COLORS = {
        "admin":     ("#C8102E", "#F8FAFC"),
        "logistica": ("#0F172A", "#F8FAFC"),
        "servicio":  ("#334155", "#F8FAFC"),
        "recepcion": ("#334155", "#F8FAFC"),
    }

    def __init__(self, parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        self.setObjectName("user_chip")
        self.setFixedHeight(56)

        lay = QHBoxLayout(self)
        lay.setContentsMargins(12, 8, 12, 8)
        lay.setSpacing(10)

        # Avatar circular
        self._avatar = QLabel("·")
        self._avatar.setFixedSize(34, 34)
        self._avatar.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._avatar.setStyleSheet("""
            background-color: #E63946;
            color: white;
            font-size: 14px;
            font-weight: 700;
            border-radius: 17px;
        """)
        lay.addWidget(self._avatar)

        # Nombre + rol
        info_lay = QVBoxLayout()
        info_lay.setSpacing(1)
        info_lay.setContentsMargins(0, 0, 0, 0)

        self._lbl_name = QLabel("—")
        self._lbl_name.setObjectName("user_name")

        self._lbl_role = QLabel("")
        self._lbl_role.setObjectName("user_role")

        info_lay.addWidget(self._lbl_name)
        info_lay.addWidget(self._lbl_role)
        lay.addLayout(info_lay, stretch=1)

        self._update_frame_style()

    def set_collapsed(self, collapsed: bool) -> None:
        if collapsed:
            self._lbl_name.hide()
            self._lbl_role.hide()
        else:
            self._lbl_name.show()
            self._lbl_role.show()

    def _update_frame_style(self):
        self.setStyleSheet("""
            QFrame#user_chip {
                background-color: #F8FAFC;
                border-radius: 10px;
                border: 1px solid #E5E7EB;
            }
        """)

    def update_user(self, nombre: str, role: str) -> None:
        """Actualiza el chip con los datos del usuario autenticado."""
        initials = "".join(p[0].upper() for p in nombre.split() if p)[:2] or "US"
        color, _bg = self._ROLE_COLORS.get(role, ("#111827", "#F8FAFC"))

        self._avatar.setText(initials)
        self._avatar.setStyleSheet(f"""
            background-color: {color};
            color: white;
            font-size: 13px;
            font-weight: 700;
            border-radius: 17px;
        """)
        self._lbl_name.setText(nombre)
        self._lbl_name.setStyleSheet(
            "font-size: 12px; font-weight: 600; color: #111827; background: transparent;"
        )

        role_labels = {
            "admin": "Administrador", "logistica": "Logística",
            "servicio": "Técnico de Campo", "recepcion": "Recepción",
        }
        self._lbl_role.setText(role_labels.get(role, role.title()))
        self._lbl_role.setStyleSheet(
            "font-size: 10.5px; color: #6B7280; font-weight: 500; background: transparent;"
        )


# ══════════════════════════════════════════════════════════════════════════════
# ConnectionIndicator — Estado de conexión BD (punto semántico 6px)
# ══════════════════════════════════════════════════════════════════════════════
class ConnectionIndicator(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent if isinstance(parent, QWidget) else None)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 4, 14, 4)
        lay.setSpacing(6)

        self._dot = QLabel()
        self._dot.setFixedSize(6, 6)
        self._dot.setStyleSheet("background-color: #D97706; border-radius: 3px;")

        self._lbl = QLabel("Verificando…")
        self._lbl.setStyleSheet("font-size: 10.5px; color: #6B7280; font-weight: 500;")

        lay.addWidget(self._dot)
        lay.addWidget(self._lbl, stretch=1)

    def set_collapsed(self, collapsed: bool) -> None:
        if collapsed:
            self._lbl.hide()
        else:
            self._lbl.show()

    def set_status(self, connected: Optional[bool]) -> None:
        if connected is True:
            self._dot.setStyleSheet("background-color: #16A34A; border-radius: 3px;")
            self._lbl.setText("BD Conectada")
        elif connected is False:
            self._dot.setStyleSheet("background-color: #C8102E; border-radius: 3px;")
            self._lbl.setText("Sin conexión")
        else:
            self._dot.setStyleSheet("background-color: #D97706; border-radius: 3px;")
            self._lbl.setText("Verificando…")


# ══════════════════════════════════════════════════════════════════════════════
# MainWindow — Ventana principal Apple-style con RBAC
# ══════════════════════════════════════════════════════════════════════════════
class MainWindow(QMainWindow):
    """
    Ventana principal con:
    - Sidebar Apple (blanco, 210px colapsable a 56px con botón hamburguesa ☰)
    - Header/breadcrumb integrado al contenido
    - Navegación filtrada por rol (RBAC via session_context)
    - Monitor de conexión BD cada 30s
    """

    def __init__(self) -> None:
        super().__init__()
        self._pages:       dict[str, QWidget] = {}
        self._nav_buttons: dict[str, SidebarNavButton] = {}
        self._current_key: str = ""
        self._page_meta:   dict[str, tuple[str, str, str]] = {}  # key → (icon, label, tooltip)
        self._sidebar_collapsed: bool = False

        self._setup_window()
        self._setup_ui()
        self._setup_statusbar()
        self._start_conn_monitor()

        # Aplicar permisos de rol en el sidebar y precalentar catálogos en segundo plano
        QTimer.singleShot(0, self.aplicar_permisos_rol)
        QTimer.singleShot(20, self._warmup_catalogs_async)
        QTimer.singleShot(80, lambda: self._navigate("dashboard"))

    def _warmup_catalogs_async(self) -> None:
        try:
            from services.catalog_cache import catalog_cache
            catalog_cache.warm_up_async()
        except Exception as exc:
            logger.debug("Warmup catalogos omitido: %s", exc)

    def _setup_window(self) -> None:
        self.setWindowTitle(f"{APP_NAME}  —  v{APP_VERSION}")
        self.setMinimumSize(WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

        if screen := self.screen():
            geo = screen.availableGeometry()
            if geo.width() >= 1440:
                self.resize(1440, 900)
                self.move((geo.width() - 1440) // 2, (geo.height() - 900) // 2)
            else:
                self.resize(geo.width(), geo.height())
                self.move(geo.left(), geo.top())
        else:
            self.resize(1440, 900)

        self.showMaximized()

    def _setup_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Sidebar
        self._sidebar = self._build_sidebar()
        root.addWidget(self._sidebar)

        # Área de contenido (header + stack) sobre canvas corporativo #F6F7F9
        content_wrapper = QWidget()
        content_wrapper.setStyleSheet("background-color: #F6F7F9;")
        content_wrapper.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        cw_lay = QVBoxLayout(content_wrapper)
        cw_lay.setContentsMargins(0, 0, 0, 0)
        cw_lay.setSpacing(0)

        # Header minimalista con título, estado BD y acción primaria
        self._header = self._build_header()
        cw_lay.addWidget(self._header)

        # Stack de páginas con tamaño expandible
        self._stack = QStackedWidget()
        self._stack.setStyleSheet("background-color: #F6F7F9;")
        self._stack.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        cw_lay.addWidget(self._stack, stretch=1)

        root.addWidget(content_wrapper, stretch=1)

    def _build_sidebar(self) -> QWidget:
        sb = QWidget()
        sb.setObjectName("sidebar")
        sb.setFixedWidth(220)
        sb.setStyleSheet("""
            QWidget#sidebar {
                background-color: #FFFFFF;
                border-right: 1px solid #E5E7EB;
            }
        """)

        lay = QVBoxLayout(sb)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # ── Logo / Marca ───────────────────────────────────────────────────────
        brand = QWidget()
        brand.setFixedHeight(72)
        brand.setStyleSheet("background-color: #FFFFFF;")
        bl = QVBoxLayout(brand)
        bl.setContentsMargins(14, 18, 14, 8)
        bl.setSpacing(2)

        brand_row = QHBoxLayout()
        brand_row.setSpacing(8)

        icon_box = QFrame()
        icon_box.setStyleSheet("""
            QFrame {
                background: #C8102E;
                border: 1px solid #C8102E;
                border-radius: 7px;
            }
        """)
        icon_box.setFixedSize(34, 34)
        ib_lay = QHBoxLayout(icon_box)
        ib_lay.setContentsMargins(0, 0, 0, 0)
        ib_lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        ib_lay.addWidget(VectorNavIcon("brand", "#FFFFFF", icon_box))
        brand_row.addWidget(icon_box)

        name_lay = QVBoxLayout()
        name_lay.setSpacing(0)
        self._lbl_brand_name = QLabel("Básculas PESA")
        self._lbl_brand_name.setStyleSheet(
            "font-size: 14px; font-weight: 700; color: #0F172A; letter-spacing: -0.2px;"
        )
        self._lbl_brand_sub = QLabel("ERP Metrológico")
        self._lbl_brand_sub.setStyleSheet("font-size: 10px; color: #475569; letter-spacing: 0.4px; font-weight: 600;")
        name_lay.addWidget(self._lbl_brand_name)
        name_lay.addWidget(self._lbl_brand_sub)
        brand_row.addLayout(name_lay, stretch=1)
        bl.addLayout(brand_row)
        lay.addWidget(brand)

        # Separador fino
        lay.addWidget(self._hsep())
        lay.addSpacing(8)

        # ── Navegación ────────────────────────────────────────────────────────
        self._sec_nav_label = QLabel("MENÚ")
        self._sec_nav_label.setObjectName("sidebar_section")
        self._sec_nav_label.setStyleSheet(
            "color: #86868B; font-size: 10px; font-weight: 700; "
            "letter-spacing: 1.2px; padding-left: 16px; padding-bottom: 4px;"
        )
        lay.addWidget(self._sec_nav_label)

        for key, icon, label, tip, roles in _NAV_ITEMS:
            icon_char = _ICON_MAP.get(key, icon)
            btn = SidebarNavButton(icon_char, label, tip)
            btn.clicked.connect(lambda _=False, k=key: self._navigate(k))
            self._nav_buttons[key] = btn
            self._page_meta[key] = (icon_char, label, tip)
            lay.addWidget(btn)
            btn.setVisible(False)

        lay.addStretch()
        lay.addWidget(self._hsep())
        lay.addSpacing(8)

        # ── Chip de usuario ────────────────────────────────────────────────────
        self._user_chip = UserChip()
        if _HAS_SESSION and _session and _session.is_authenticated:
            self._user_chip.update_user(_session.nombre_completo, _session.role)
        else:
            self._user_chip.update_user("Sin sesión", "—")

        chip_wrapper = QWidget()
        chip_wrapper.setStyleSheet("background: transparent;")
        cw = QHBoxLayout(chip_wrapper)
        cw.setContentsMargins(8, 4, 8, 4)
        cw.addWidget(self._user_chip)
        lay.addWidget(chip_wrapper)

        # ── Botón Cerrar Sesión ────────────────────────────────────────────────
        self._btn_logout = QPushButton("Cerrar Sesión")
        self._btn_logout.setObjectName("btn_logout")
        self._btn_logout.setFixedHeight(32)
        self._btn_logout.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_logout.setToolTip("")
        self._btn_logout.setStyleSheet("""
            QPushButton#btn_logout {
                background: #FFFFFF;
                color: #475569;
                border: 1px solid #E2E8F0;
                border-radius: 7px;
                font-size: 12px;
                font-weight: 600;
                margin: 2px 8px 4px 8px;
                padding: 0 8px;
            }
            QPushButton#btn_logout:hover {
                background: #F8FAFC;
                color: #C8102E;
                border-color: #C8102E;
            }
            QPushButton#btn_logout:pressed {
                background: #F1F5F9;
            }
        """)
        self._btn_logout.clicked.connect(self._on_cerrar_sesion)
        lay.addWidget(self._btn_logout)

        # ── Indicador de conexión + Versión (sin superposición) ───────────────
        self._conn_indicator = ConnectionIndicator()
        lay.addWidget(self._conn_indicator)

        lay.addSpacing(2)

        # Versión — color muy discreto, no compite con el resto
        self._ver_label = QLabel(f"v{APP_VERSION}")
        self._ver_label.setStyleSheet(
            "color: #C7C7CC; font-size: 9px; padding-left: 16px; padding-bottom: 10px;"
        )
        lay.addWidget(self._ver_label)

        return sb

    def _toggle_sidebar(self) -> None:
        """Alterna el menú lateral entre modo expandido (220px), riel compacto (54px) y oculto (0px) con QPropertyAnimation."""
        if not hasattr(self, "_sidebar_mode"):
            self._sidebar_mode = 0  # 0: 220px, 1: 54px, 2: 0px

        self._sidebar_mode = (self._sidebar_mode + 1) % 3
        
        target_w = 220
        if self._sidebar_mode == 1:
            target_w = 54
        elif self._sidebar_mode == 2:
            target_w = 0

        self._sidebar_collapsed = (self._sidebar_mode != 0)
        is_hidden = (self._sidebar_mode == 2)

        start_w = self._sidebar.width()

        # Animación QPropertyAnimation sobre maximumWidth y minimumWidth
        self._anim_group = QParallelAnimationGroup(self)

        anim_max = QPropertyAnimation(self._sidebar, b"maximumWidth")
        anim_max.setDuration(220)
        anim_max.setStartValue(start_w)
        anim_max.setEndValue(target_w)
        anim_max.setEasingCurve(QEasingCurve.Type.InOutCubic)

        anim_min = QPropertyAnimation(self._sidebar, b"minimumWidth")
        anim_min.setDuration(220)
        anim_min.setStartValue(start_w)
        anim_min.setEndValue(target_w)
        anim_min.setEasingCurve(QEasingCurve.Type.InOutCubic)

        self._anim_group.addAnimation(anim_max)
        self._anim_group.addAnimation(anim_min)

        # Actualizar visibilidad
        if is_hidden:
            self._sidebar.setVisible(False)
        else:
            self._sidebar.setVisible(True)

        if hasattr(self, "_lbl_brand_name"):
            self._lbl_brand_name.setVisible(not self._sidebar_collapsed)
        if hasattr(self, "_lbl_brand_sub"):
            self._lbl_brand_sub.setVisible(not self._sidebar_collapsed)
        if hasattr(self, "_sec_nav_label"):
            self._sec_nav_label.setVisible(not self._sidebar_collapsed)
        if hasattr(self, "_ver_label"):
            self._ver_label.setVisible(not self._sidebar_collapsed)
        if hasattr(self, "_btn_logout"):
            self._btn_logout.setText("Salir" if self._sidebar_collapsed else "Cerrar Sesión")
        if hasattr(self, "_user_chip"):
            self._user_chip.set_collapsed(self._sidebar_collapsed)
        if hasattr(self, "_conn_indicator"):
            self._conn_indicator.set_collapsed(self._sidebar_collapsed)

        for btn in self._nav_buttons.values():
            btn.set_collapsed(self._sidebar_collapsed)

        self._anim_group.start()

    def _build_header(self) -> QWidget:
        """Header minimalista con título de vista, estado discreto de PostgreSQL y acción primaria."""
        header = QWidget()
        header.setObjectName("content_header")
        header.setFixedHeight(56)
        header.setStyleSheet("""
            QWidget#content_header {
                background-color: #FFFFFF;
                border-bottom: 1px solid #E5E7EB;
            }
        """)

        lay = QHBoxLayout(header)
        lay.setContentsMargins(24, 0, 24, 0)
        lay.setSpacing(12)

        # Título / Breadcrumb de la vista activa
        self._lbl_breadcrumb = QLabel("Dashboard")
        self._lbl_breadcrumb.setObjectName("breadcrumb")
        self._lbl_breadcrumb.setStyleSheet(
            "color: #111827; font-size: 15px; font-weight: 700; letter-spacing: -0.2px; background: transparent;"
        )
        lay.addWidget(self._lbl_breadcrumb)
        lay.addStretch()

        # Píldora discreta de conexión PostgreSQL (punto semántico 6px)
        try:
            from ui.theme import StatusBadge, PrimaryButton
            self._header_conn_badge = StatusBadge("Verificando BD…", dot_color="#D97706", parent=header)
            lay.addWidget(self._header_conn_badge)
        except Exception:
            self._header_conn_badge = None

        # Indicador de rol discreto
        self._header_role_chip = QLabel("")
        self._header_role_chip.setStyleSheet("""
            background-color: #F8FAFC;
            color: #6B7280;
            border: 1px solid #E5E7EB;
            font-size: 10.5px;
            font-weight: 700;
            border-radius: 6px;
            padding: 4px 9px;
            letter-spacing: 0.5px;
        """)
        self._header_role_chip.setVisible(False)
        lay.addWidget(self._header_role_chip)

        # Botón primario global [+ Nuevo Documento] (visible para admin/logística fuera de Generar Formatos)
        self._btn_header_nuevo = QPushButton("+ Nuevo Documento")
        self._btn_header_nuevo.setFixedHeight(34)
        self._btn_header_nuevo.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_header_nuevo.setStyleSheet("""
            QPushButton {
                background-color: #C8102E;
                color: #FFFFFF;
                border: 1px solid #C8102E;
                border-radius: 8px;
                font-size: 12.5px;
                font-weight: 600;
                padding: 0 14px;
            }
            QPushButton:hover { background-color: #A60D26; border-color: #A60D26; }
            QPushButton:pressed { background-color: #880B20; }
        """)
        self._btn_header_nuevo.clicked.connect(lambda: self.ir_a_generar_formato("OS"))
        self._btn_header_nuevo.setVisible(False)
        lay.addWidget(self._btn_header_nuevo)

        return header

    @staticmethod
    def _hsep() -> QFrame:
        f = QFrame()
        f.setFrameShape(QFrame.Shape.HLine)
        f.setFixedHeight(1)
        f.setStyleSheet("background: rgba(0,0,0,0.07); border: none; margin: 0 12px;")
        return f

    def _setup_statusbar(self) -> None:
        sb = QStatusBar()
        sb.setStyleSheet("""
            QStatusBar {
                background-color: rgba(245,245,247,0.95);
                color: #86868B;
                font-size: 11px;
                border-top: 1px solid rgba(0,0,0,0.06);
                padding: 0 12px;
                min-height: 24px;
            }
        """)
        self.setStatusBar(sb)
        sb.showMessage("Listo")

    # ── RBAC: determinar ítems permitidos ─────────────────────────────────────

    def _get_allowed_nav_keys(self) -> set[str]:
        """Retorna las claves de navegación permitidas para el rol activo."""
        if not _HAS_SESSION or _session is None or not _session.is_authenticated:
            # Sin sesión activa: solo mostrar Dashboard como placeholder
            return {"dashboard"}

        allowed = _session.nav_items_allowed()
        return set(allowed)

    def aplicar_permisos_rol(self) -> None:
        """
        Muestra u oculta los botones del sidebar según el rol activo.
        Debe llamarse después de cada login o cambio de sesión.

        Estrategia:
          1. Ocultar TODOS los botones (limpia cualquier estado previo).
          2. Obtener las claves permitidas para el rol actual.
          3. Mostrar solo los permitidos.
        Esto garantiza que cambiar de un rol restringido a admin
        vuelva a mostrar todos los botones sin reiniciar la app.
        """
        if not _HAS_SESSION or _session is None:
            return

        allowed = self._get_allowed_nav_keys()

        # Paso 1: ocultar TODOS los botones registrados
        for btn in self._nav_buttons.values():
            btn.setVisible(False)

        # Paso 2: mostrar solo los permitidos para el rol activo
        for key in allowed:
            if key in self._nav_buttons:
                self._nav_buttons[key].setVisible(True)

        # Paso 3: actualizar chip de usuario y controles de cabecera
        if _session.is_authenticated:
            _role_labels_chip = {
                "admin":      "Administrador",
                "logistica":  "Logística",
                "servicio":   "Técnico de Campo",
                "calibrador": "Técnico Calibrador",
                "inspector":  "Técnico Inspector",
                "recepcion":  "Recepción",
            }
            _rol_display = _role_labels_chip.get(_session.role, _session.role.capitalize())
            self._user_chip.update_user(_session.nombre_completo, _rol_display)

            if hasattr(self, "_header_role_chip") and self._header_role_chip is not None:
                _role_upper = {
                    "admin":      "ADMINISTRADOR",
                    "logistica":  "LOGÍSTICA",
                    "servicio":   "TÉCNICO",
                    "calibrador": "CALIBRADOR",
                    "inspector":  "INSPECTOR",
                    "recepcion":  "RECEPCIÓN",
                }.get(_session.role, _session.role.upper())
                self._header_role_chip.setText(_role_upper)
                self._header_role_chip.setVisible(True)

            if hasattr(self, "_btn_header_nuevo") and self._btn_header_nuevo is not None:
                can_create = "lote" in allowed
                self._btn_header_nuevo.setVisible(can_create and self._current_key not in ("dashboard", "lote"))

        # Paso 4: log para trazabilidad
        try:
            role_label = {
                "admin": "ADMINISTRADOR", "logistica": "LOGÍSTICA",
                "servicio": "TÉCNICO", "recepcion": "RECEPCIÓN",
            }.get(_session.role, _session.role.upper())
            logger.debug("Permisos aplicados para rol: %s — visibles: %s",
                         role_label, sorted(allowed))
        except Exception:
            pass

    # ── Navegación ────────────────────────────────────────────────────────────

    def _navigate(self, key: str) -> None:
        """Navega al módulo indicado (lazy loading) con RBAC."""
        # Validación RBAC
        allowed = self._get_allowed_nav_keys()
        if allowed and key not in allowed:
            logger.warning("Acceso denegado al módulo '%s' para rol '%s'",
                           key, _session.role if _session else "?")
            return

        if key not in self._pages:
            widget = self._create_page(key)
            if widget:
                self._pages[key] = widget
                self._stack.addWidget(widget)

        if key in self._pages:
            page = self._pages[key]
            self._stack.setCurrentWidget(page)
            self._current_key = key

            # Si se navega a Generar Formatos, recargar catálogos dinámicamente desde BD
            if key == "lote" and hasattr(page, "recargar_catalogos"):
                try:
                    page.recargar_catalogos()
                except Exception as e_rec:
                    logger.warning("Error al recargar catálogos en lote: %s", e_rec)

            # Actualizar botones activos
            for k, btn in self._nav_buttons.items():
                btn.set_active(k == key)

            # Actualizar breadcrumb y visibilidad del botón rápido de cabecera
            meta = self._page_meta.get(key, ("", key.replace("_", " ").title(), ""))
            self._lbl_breadcrumb.setText(meta[1])
            if hasattr(self, "_btn_header_nuevo") and self._btn_header_nuevo is not None:
                self._btn_header_nuevo.setVisible(("lote" in allowed) and key not in ("dashboard", "lote"))
            self.statusBar().showMessage("Listo")
            logger.debug("Navegado a: %s", key)

    def _create_page(self, key: str) -> Optional[QWidget]:
        """Instancia la página del módulo (lazy load)."""
        try:
            if key == "dashboard":
                _cls = DashboardWidget
                if _cls is None:
                    from ui.widgets.dashboard_widget import DashboardWidget as _cls
                w = _cls()
                if hasattr(w, "os_selected"):
                    w.os_selected.connect(self._on_os_selected)
                if hasattr(w, "lp_selected"):
                    w.lp_selected.connect(self._on_lp_selected)
                if hasattr(w, "lv_selected"):
                    w.lv_selected.connect(self._on_lv_selected)
                if hasattr(w, "goto_escaneos"):
                    w.goto_escaneos.connect(self._on_goto_escaneos)
                if hasattr(w, "solicitar_nuevo_formato"):
                    w.solicitar_nuevo_formato.connect(self.ir_a_generar_formato)
                # Navegacion desacoplada: senal limpia sin traversal de arbol
                if hasattr(w, "navegar_a"):
                    w.navegar_a.connect(self._navigate)
                return w

            elif key == "mi_firma":
                from ui.widgets.firma_widget import FirmaWidget
                return FirmaWidget()

            elif key == "nueva_os":
                _cls = OSFormWidget
                if _cls is None:
                    from ui.widgets.os_form_widget import OSFormWidget as _cls
                w = _cls()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w
                
            elif key == "nuevo_lp":
                _cls = LPFormWidget
                if _cls is None:
                    from ui.widgets.lp_form_widget import LPFormWidget as _cls
                w = _cls()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w

            elif key == "nuevo_lv":
                _cls = LVFormWidget
                if _cls is None:
                    from ui.widgets.lv_form_widget import LVFormWidget as _cls
                w = _cls()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w

            elif key == "lote":
                _cls = BatchGeneratorWidget
                if _cls is None:
                    from ui.widgets.batch_generator_widget import BatchGeneratorWidget as _cls
                return _cls()

            elif key == "buscar_os":
                _cls = DashboardWidget
                if _cls is None:
                    from ui.widgets.dashboard_widget import DashboardWidget as _cls
                # Aplicar filtro RBAC según el rol del usuario activo
                rbac_filter = None
                if _HAS_SESSION and _session:
                    if _session.has_role("calibrador"):
                        rbac_filter = "calibrador"
                    elif _session.has_role("inspector"):
                        rbac_filter = "inspector"
                w = _cls(
                    title="Buscar / Editar Órdenes de Servicio",
                    rbac_filter=rbac_filter,
                )
                if hasattr(w, "os_selected"):
                    w.os_selected.connect(self._on_os_selected)
                if hasattr(w, "lp_selected"):
                    w.lp_selected.connect(self._on_lp_selected)
                if hasattr(w, "goto_escaneos"):
                    w.goto_escaneos.connect(self._on_goto_escaneos)
                # Navegacion desacoplada: senal limpia sin traversal de arbol
                if hasattr(w, "navegar_a"):
                    w.navegar_a.connect(self._navigate)
                return w

            elif key == "recepcion_os":
                _cls = RecepcionWidget
                if _cls is None:
                    from ui.widgets.recepcion_widget import RecepcionWidget as _cls
                return _cls()

            elif key == "escaneos":
                _cls = ScannerWidget
                if _cls is None:
                    from ui.widgets.scanner_widget import ScannerWidget as _cls
                return _cls()

            elif key == "catalogos":
                _cls = CatalogosWidget
                if _cls is None:
                    from ui.widgets.catalogos_widget import CatalogosWidget as _cls
                return _cls()

            elif key == "configuracion":
                _cls = ConfiguracionWidget
                if _cls is None:
                    from ui.widgets.configuracion_widget import ConfiguracionWidget as _cls
                cfg_w = _cls()
                # Refrescar el dashboard cuando se haga un reset de pruebas
                cfg_w.folios_reseteados.connect(self._on_folios_reseteados)
                return cfg_w

            return self._build_placeholder(key)

        except ImportError as exc:
            logger.error("ImportError al crear página '%s': %s", key, exc)
            return self._build_placeholder(key, error=str(exc))
        except Exception as exc:
            logger.exception("Error al crear página '%s'", key)
            return self._build_placeholder(key, error=str(exc))

    def _build_placeholder(self, key: str, error: str = "", wip: bool = False) -> QWidget:
        """Página de marcador cuando el módulo no está disponible."""
        w = QWidget()
        w.setStyleSheet("background-color: #F5F5F7;")
        lay = QVBoxLayout(w)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.setSpacing(14)

        icon_char = "!" if (error or wip) else "i"
        lbl_icon = QLabel(icon_char)
        lbl_icon.setObjectName("placeholder_icon")
        lbl_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_icon.setFixedSize(48, 48)
        lbl_icon.setStyleSheet(
            "font-size: 20px; font-weight: 700; color: #6B7280; "
            "background: #FFFFFF; border: 1px solid #E5E7EB; border-radius: 24px;"
        )
        lay.addWidget(lbl_icon, alignment=Qt.AlignmentFlag.AlignCenter)

        title = key.replace("_", " ").title() if not wip else "Próximamente"
        lbl_title = QLabel(title)
        lbl_title.setObjectName("placeholder_title")
        lbl_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_title.setStyleSheet(
            "font-size: 17px; font-weight: 600; color: #1D1D1F; background: transparent;"
        )
        lay.addWidget(lbl_title)

        msg_text = f"Error de importación:\n{error}" if error else (
            "Este módulo estará disponible en la próxima versión." if wip
            else "Módulo en desarrollo."
        )
        lbl_msg = QLabel(msg_text)
        lbl_msg.setObjectName("placeholder_sub")
        lbl_msg.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_msg.setWordWrap(True)
        lbl_msg.setStyleSheet("font-size: 13px; color: #86868B; background: transparent;")
        lay.addWidget(lbl_msg)
        return w

    def _on_folios_reseteados(self) -> None:
        """Refresca el dashboard tras un reset de folios de prueba."""
        self.statusBar().showMessage("Folios reiniciados. Dashboard actualizado.", 6000)
        try:
            from ui.theme import show_toast
            show_toast(self, "Folios reiniciados y Dashboard actualizado.", level="success")
        except Exception:
            pass
        if "dashboard" in self._pages:
            dash = self._pages["dashboard"]
            if hasattr(dash, "refresh"):
                dash.refresh()
        # Limpiar cache de la página de configuración para forzar recreación limpia
        if "configuracion" in self._pages:
            old = self._pages.pop("configuracion")
            self._stack.removeWidget(old)
            old.deleteLater()

    # ── Slots ─────────────────────────────────────────────────────────────────

    def _on_os_selected(self, os_id: int) -> None:
        if "editar_os" in self._pages:
            old = self._pages.pop("editar_os")
            self._stack.removeWidget(old)
            old.deleteLater()
        try:
            from ui.widgets.os_form_widget import OSFormWidget
            w = OSFormWidget(os_id=os_id)
            w.os_saved.connect(self._on_os_saved)
            self._pages["editar_os"] = w
            self._stack.addWidget(w)
            self._stack.setCurrentWidget(w)
            self._current_key = "editar_os"
            self.statusBar().showMessage(f"Editando OS — ID: {os_id}")
        except Exception as exc:
            logger.exception("Error al abrir OS ID=%d", os_id)
            QMessageBox.critical(self, "Error", f"No se pudo abrir la OS:\n{exc}")

    def _on_lp_selected(self, os_id: int) -> None:
        if "editar_lp" in self._pages:
            old = self._pages.pop("editar_lp")
            self._stack.removeWidget(old)
            old.deleteLater()
        try:
            from ui.widgets.lp_form_widget import LPFormWidget
            w = LPFormWidget(os_id=os_id)
            w.os_saved.connect(self._on_os_saved)
            self._pages["editar_lp"] = w
            self._stack.addWidget(w)
            self._stack.setCurrentWidget(w)
            self._current_key = "editar_lp"
            self.statusBar().showMessage(f"Editando LP — ID: {os_id}")
        except Exception as exc:
            logger.exception("Error al abrir LP ID=%d", os_id)
            QMessageBox.critical(self, "Error", f"No se pudo abrir la LP:\n{exc}")

    def _on_lv_selected(self, os_id: int) -> None:
        if "editar_lv" in self._pages:
            old = self._pages.pop("editar_lv")
            self._stack.removeWidget(old)
            old.deleteLater()
        try:
            from ui.widgets.lv_form_widget import LVFormWidget
            w = LVFormWidget(os_id=os_id)
            w.os_saved.connect(self._on_os_saved)
            self._pages["editar_lv"] = w
            self._stack.addWidget(w)
            self._stack.setCurrentWidget(w)
            self._current_key = "editar_lv"
            self.statusBar().showMessage(f"Editando LV — ID: {os_id}")
        except Exception as exc:
            logger.exception("Error al abrir LV ID=%d", os_id)
            QMessageBox.critical(self, "Error", f"No se pudo abrir el LV:\n{exc}")

    def _on_goto_escaneos(self, folio: str) -> None:
        self._navigate("escaneos")
        w = self._pages.get("escaneos")
        if w and hasattr(w, "set_folio"):
            w.set_folio(folio)

    def _on_os_saved(self, folio: str) -> None:
        self.statusBar().showMessage(f"✓  OS guardada: {folio}", 6000)
        if "dashboard" in self._pages:
            dash = self._pages["dashboard"]
            if hasattr(dash, "refresh"):
                dash.refresh()
        self._navigate("dashboard")

    def _sync_conn_widgets(self, connected: Optional[bool]) -> None:
        self._conn_indicator.set_status(connected)
        if hasattr(self, "_header_conn_badge") and self._header_conn_badge is not None:
            if connected is True:
                self._header_conn_badge.set_status("PostgreSQL Conectado", "#16A34A")
            elif connected is False:
                self._header_conn_badge.set_status("Modo Offline", "#D97706")
            else:
                self._header_conn_badge.set_status("Verificando BD…", "#D97706")

    def _test_connection(self) -> None:
        from database.connection import db_pool
        self._sync_conn_widgets(None)
        ok = db_pool.test_connection()
        self._sync_conn_widgets(ok)
        if ok:
            ver = db_pool.get_server_version()
            QMessageBox.information(self, "Conexión Exitosa",
                                    f"Conexión a la base de datos establecida.\n\n{ver}")
        else:
            QMessageBox.warning(self, "Sin Conexión",
                                "No se pudo conectar a la base de datos.\n\n"
                                "Verifique:\n"
                                "  • La VPN/LAN esté activa\n"
                                "  • El servidor PostgreSQL esté iniciado\n"
                                "  • Las credenciales en .env sean correctas")

    # ── Monitor de conexión ────────────────────────────────────────────────────

    def _start_conn_monitor(self) -> None:
        self._conn_timer = QTimer(self)
        self._conn_timer.timeout.connect(self._check_connection_bg)
        self._conn_timer.start(30_000)
        QTimer.singleShot(1200, self._check_connection_bg)

    def _check_connection_bg(self) -> None:
        try:
            from database.connection import db_pool
            ok = db_pool.test_connection()
            self._sync_conn_widgets(ok)
        except Exception:
            self._sync_conn_widgets(False)

    # ── Cerrar Sesión ─────────────────────────────────────────────────────────

    def _on_cerrar_sesion(self) -> None:
        """
        Muestra confirmación, limpia la sesión y regresa a la pantalla de login.
        Si el usuario vuelve a autenticarse, la ventana principal se muestra de nuevo.
        Si cancela en el login, la app termina.
        """
        resp = QMessageBox.question(
            self,
            "Cerrar Sesión",
            "¿Deseas cerrar la sesión actual?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return

        # 1. Destruir sesión
        try:
            if _HAS_SESSION and _session:
                _session.logout()   # Método correcto (no clear())
        except Exception as exc:
            logger.warning("Error al limpiar sesión: %s", exc)

        # 2. Ocultar ventana principal
        self.hide()

        # 3. Mostrar login nuevamente
        try:
            from ui.dialogs.login_dialog import LoginDialog
            from PyQt6.QtWidgets import QDialog

            app = QApplication.instance()
            app.setQuitOnLastWindowClosed(False)

            dlg = LoginDialog()
            app._login_dlg = dlg   # referencia fuerte — evita GC

            if dlg.exec() == QDialog.DialogCode.Accepted:
                # Re-autenticado: reconstruir sidebar y mostrar ventana
                self.aplicar_permisos_rol()
                # Refrescar el dashboard para actualizar saludo y KPIs con la nueva sesión
                if "dashboard" in self._pages:
                    dash = self._pages["dashboard"]
                    if hasattr(dash, "refresh"):
                        dash.refresh()
                # Navegar al dashboard al reingresar
                self._navigate("dashboard")
                self.show()
            else:
                # El usuario cerró el login → salir
                QApplication.quit()

        except Exception as exc:
            logger.exception("Error al mostrar login después de cerrar sesión: %s", exc)
            QApplication.quit()

    # ── Cierre ────────────────────────────────────────────────────────────────

    def closeEvent(self, event) -> None:
        try:
            from database.connection import db_pool
            db_pool.close_all()
        except Exception:
            pass
        logger.info("Aplicación cerrada correctamente.")
        super().closeEvent(event)
    @property
    def generar_formatos_widget(self):
        """Devuelve el widget de Generar Formatos (lote)."""
        if "lote" not in self._pages:
            w = self._create_page("lote")
            self._pages["lote"] = w
            self._stack.addWidget(w)
        return self._pages.get("lote")

    def ir_a_generar_formato(self, tipo_documento: str) -> None:
        """
        1. Cambia el índice del QStackedWidget al formulario de 'Generar Formatos'.
        2. Llama al método interno para seleccionar la tarjeta correspondiente.
        """
        self._navigate("lote")
        if hasattr(self.generar_formatos_widget, "seleccionar_tipo_documento"):
            self.generar_formatos_widget.seleccionar_tipo_documento(tipo_documento)
