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

from PyQt6.QtCore    import Qt, QTimer, QPropertyAnimation, QEasingCurve
from PyQt6.QtGui     import QFont, QColor
from PyQt6.QtWidgets import (
    QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
    QPushButton, QLabel, QStackedWidget, QStatusBar,
    QFrame, QMessageBox, QSizePolicy, QScrollArea,
    QApplication,
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


# ─── Definición del menú (6 ítems definitivos) ──────────────────────────────
# (key, icon, label, tooltip, roles_permitidos)
_NAV_ITEMS: list[tuple[str, str, str, str, list[str]]] = [
    ("dashboard",    "⌂",  "Dashboard",       "Tablero y resumen de actividad",              ["admin", "logistica", "servicio", "recepcion"]),
    ("lote",         "⬚",  "Generar Formatos", "Asistente de generación de OS, RMA y RE",    ["admin", "logistica"]),
    ("buscar_os",    "⌕",  "Buscar / Historial","Buscar, editar y consultar órdenes",        ["admin", "logistica", "recepcion", "calibrador", "inspector"]),
    ("recepcion_os", "📋", "Recepción / Entrega","Control de entrega semanal de OS por fecha", ["admin", "logistica", "recepcion"]),
    ("escaneos",     "⊕",  "Adjuntar Escaneo", "Adjuntar formato físico escaneado",          ["admin", "logistica", "servicio"]),
    ("catalogos",    "⊞",  "Catálogos",        "Clientes, técnicos e instrumentos",          ["admin"]),
    ("configuracion","⚙",  "Configuración",    "Conexión a BD y ajustes del sistema",        ["admin"]),
]

_ICON_MAP: dict[str, str] = {
    "dashboard":     "⌂",
    "lote":          "⬚",
    "buscar_os":     "⌕",
    "recepcion_os":  "📋",
    "escaneos":      "⊕",
    "catalogos":     "⊞",
    "configuracion": "⚙",
}


# ══════════════════════════════════════════════════════════════════════════════
# SidebarNavButton — Botón de navegación Apple-style
# ══════════════════════════════════════════════════════════════════════════════
class SidebarNavButton(QPushButton):
    """
    Botón de navegación con indicador lateral rojo (estilo macOS Sonoma).
    Estados: inactivo / hover / activo
    """
    def __init__(self, icon: str, label: str, tooltip: str, parent=None):
        super().__init__(parent)
        self._icon    = icon
        self._label   = label
        self._active  = False

        self.setToolTip(tooltip)
        self.setFixedHeight(40)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

        # Layout interno: icono + texto
        self._build_layout()
        self._apply_inactive()

    def _build_layout(self):
        from PyQt6.QtWidgets import QHBoxLayout as HL
        lay = HL(self)
        lay.setContentsMargins(14, 0, 12, 0)
        lay.setSpacing(10)

        # Indicador activo (línea izquierda roja)
        self._indicator = QFrame()
        self._indicator.setFixedSize(3, 22)
        self._indicator.setStyleSheet("background: transparent; border-radius: 1px;")
        lay.addWidget(self._indicator)

        # Ícono
        self._lbl_icon = QLabel(self._icon)
        self._lbl_icon.setFixedWidth(18)
        self._lbl_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._lbl_icon.setStyleSheet("font-size: 14px; background: transparent;")
        lay.addWidget(self._lbl_icon)

        # Texto
        self._lbl_text = QLabel(self._label)
        self._lbl_text.setStyleSheet("font-size: 13px; font-weight: 500; background: transparent;")
        lay.addWidget(self._lbl_text, stretch=1)

    def set_active(self, active: bool) -> None:
        self._active = active
        if active:
            self._apply_active()
        else:
            self._apply_inactive()

    def _apply_active(self):
        self.setStyleSheet("""
            QPushButton {
                background-color: #FEF2F2;
                border: none;
                border-left: 4px solid #C8102E;
                border-radius: 0px;
                margin: 0 0 0 0;
                padding-left: 10px;
            }
        """)
        self._indicator.setStyleSheet(
            "background: transparent; border-radius: 0px;"
        )
        self._lbl_icon.setStyleSheet(
            "font-size: 14px; color: #C8102E; background: transparent;"
        )
        self._lbl_text.setStyleSheet(
            "font-size: 13px; font-weight: 700; color: #C8102E; background: transparent;"
        )

    def _apply_inactive(self):
        self.setStyleSheet("""
            QPushButton {
                background-color: transparent;
                border: none;
                border-radius: 0px;
                margin: 0;
                padding-left: 14px;
            }
            QPushButton:hover {
                background-color: #F1F5F9;
            }
            QPushButton:pressed {
                background-color: #E2E8F0;
            }
        """)
        self._indicator.setStyleSheet("background: transparent;")
        self._lbl_icon.setStyleSheet(
            "font-size: 14px; color: #475569; background: transparent;"
        )
        self._lbl_text.setStyleSheet(
            "font-size: 13px; font-weight: 500; color: #475569; background: transparent;"
        )

    # Compatibilidad con código antiguo que usa set_active
    def is_active(self) -> bool:
        return self._active


# ══════════════════════════════════════════════════════════════════════════════
# UserChip — Chip del usuario en la parte inferior del sidebar
# ══════════════════════════════════════════════════════════════════════════════
class UserChip(QFrame):
    """Muestra el usuario activo y su rol con diseño pill-chip."""

    _ROLE_COLORS = {
        "admin":     ("#E63946", "#FEF2F2"),
        "logistica": ("#007AFF", "#EBF5FF"),
        "servicio":  ("#34C759", "#EDFBF2"),
        "recepcion": ("#FF9F0A", "#FFF6E5"),
    }

    def __init__(self, parent=None):
        super().__init__(parent)
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

    def _update_frame_style(self):
        self.setStyleSheet("""
            QFrame#user_chip {
                background-color: #F5F5F7;
                border-radius: 10px;
                border: 1px solid rgba(0,0,0,0.06);
            }
        """)

    def update_user(self, nombre: str, role: str) -> None:
        """Actualiza el chip con los datos del usuario autenticado."""
        initials = "".join(p[0].upper() for p in nombre.split() if p)[:2] or "US"
        color, bg = self._ROLE_COLORS.get(role, ("#86868B", "#F5F5F7"))

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
            "font-size: 12px; font-weight: 600; color: #1D1D1F; background: transparent;"
        )

        role_labels = {
            "admin": "Administrador", "logistica": "Logística",
            "servicio": "Técnico de Campo", "recepcion": "Recepción",
        }
        self._lbl_role.setText(role_labels.get(role, role.title()))
        self._lbl_role.setStyleSheet(
            f"font-size: 10px; color: {color}; font-weight: 500; background: transparent;"
        )


# ══════════════════════════════════════════════════════════════════════════════
# ConnectionIndicator — Estado de conexión BD
# ══════════════════════════════════════════════════════════════════════════════
class ConnectionIndicator(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 4, 14, 4)
        lay.setSpacing(6)

        self._dot = QLabel("●")
        self._dot.setStyleSheet("font-size: 8px; color: #FF9F0A;")
        self._dot.setFixedWidth(12)

        self._lbl = QLabel("Verificando…")
        self._lbl.setStyleSheet("font-size: 10px; color: #86868B;")

        lay.addWidget(self._dot)
        lay.addWidget(self._lbl, stretch=1)

    def set_status(self, connected: Optional[bool]) -> None:
        if connected is True:
            self._dot.setStyleSheet("font-size: 8px; color: #34C759;")
            self._lbl.setText("BD Conectada")
        elif connected is False:
            self._dot.setStyleSheet("font-size: 8px; color: #FF3B30;")
            self._lbl.setText("Sin conexión")
        else:
            self._dot.setStyleSheet("font-size: 8px; color: #FF9F0A;")
            self._lbl.setText("Verificando…")


# ══════════════════════════════════════════════════════════════════════════════
# MainWindow — Ventana principal Apple-style con RBAC
# ══════════════════════════════════════════════════════════════════════════════
class MainWindow(QMainWindow):
    """
    Ventana principal con:
    - Sidebar Apple (blanco, 220px, indicador rojo lateral)
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

        self._setup_window()
        self._setup_ui()
        self._setup_statusbar()
        self._start_conn_monitor()

        # Aplicar permisos de rol en el sidebar desde el primer instante
        QTimer.singleShot(0, self.aplicar_permisos_rol)
        QTimer.singleShot(80, lambda: self._navigate("dashboard"))

    # ── Setup ──────────────────────────────────────────────────────────────────

    def _setup_window(self) -> None:
        self.setWindowTitle(f"{APP_NAME}  —  v{APP_VERSION}")
        self.setMinimumSize(WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

        # Iniciar maximizado para adaptarse a tablets y pantallas grandes.
        # Si la pantalla disponible es menor a 1440px (ej. tablet 1024px),
        # ajustamos el tamaño para ocupar todo el espacio disponible.
        if screen := self.screen():
            geo = screen.availableGeometry()
            if geo.width() >= 1440:
                self.resize(1440, 900)
                self.move((geo.width() - 1440) // 2, (geo.height() - 900) // 2)
            else:
                # Tablet / pantalla pequeña — ocupar todo el espacio disponible
                self.resize(geo.width(), geo.height())
                self.move(geo.left(), geo.top())
        else:
            self.resize(1440, 900)

        # Arrancar maximizado para una mejor experiencia en tablets
        self.showMaximized()

    def _setup_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Sidebar
        root.addWidget(self._build_sidebar())

        # Área de contenido (header + stack)
        content_wrapper = QWidget()
        content_wrapper.setStyleSheet("background-color: #F0F2F5;")
        content_wrapper.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        cw_lay = QVBoxLayout(content_wrapper)
        cw_lay.setContentsMargins(0, 0, 0, 0)
        cw_lay.setSpacing(0)

        # Header breadcrumb
        self._header = self._build_header()
        cw_lay.addWidget(self._header)

        # Stack de páginas con tamaño expandible
        self._stack = QStackedWidget()
        self._stack.setStyleSheet("background-color: #F0F2F5;")
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
                border-right: 1px solid #E2E8F0;
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
        bl.setContentsMargins(18, 18, 18, 8)
        bl.setSpacing(2)

        # Ícono + nombre
        brand_row = QHBoxLayout()
        brand_row.setSpacing(8)

        icon_box = QLabel("⚖")
        icon_box.setStyleSheet("""
            font-size: 20px;
            color: #E63946;
            background: rgba(230, 57, 70, 0.08);
            border-radius: 8px;
            padding: 2px 6px;
        """)
        icon_box.setFixedSize(34, 34)
        icon_box.setAlignment(Qt.AlignmentFlag.AlignCenter)
        brand_row.addWidget(icon_box)

        name_lay = QVBoxLayout()
        name_lay.setSpacing(0)
        lbl_name = QLabel("Servicios PESA")
        lbl_name.setStyleSheet(
            "font-size: 14px; font-weight: 700; color: #1E293B; letter-spacing: -0.2px;"
        )
        lbl_sub = QLabel("ERP Metrológico")
        lbl_sub.setStyleSheet("font-size: 9px; color: #94A3B8; letter-spacing: 0.5px; font-weight: 600;")
        name_lay.addWidget(lbl_name)
        name_lay.addWidget(lbl_sub)
        brand_row.addLayout(name_lay, stretch=1)
        bl.addLayout(brand_row)
        lay.addWidget(brand)

        # Separador fino
        lay.addWidget(self._hsep())
        lay.addSpacing(8)

        # ── Navegación — se crean TODOS los botones desde el inicio ───────────
        # IMPORTANTE: crear TODOS los items aunque el rol actual no tenga
        # permiso para algunos. La visibilidad se controla en
        # aplicar_permisos_rol() que se invoca justo después.
        # Si solo se crean los permitidos en el primer login, los botones
        # "faltantes" nunca existirán en self._nav_buttons y no podrán
        # mostrarse cuando el usuario cambie a un rol con más privilegios.
        sec_nav = QLabel("MENÚ")
        sec_nav.setObjectName("sidebar_section")
        sec_nav.setStyleSheet(
            "color: #94A3B8; font-size: 9px; font-weight: 700; "
            "letter-spacing: 1.5px; padding-left: 16px; padding-bottom: 4px;"
        )
        lay.addWidget(sec_nav)

        for key, icon, label, tip, roles in _NAV_ITEMS:
            icon_char = _ICON_MAP.get(key, icon)
            btn = SidebarNavButton(icon_char, label, tip)
            btn.clicked.connect(lambda _=False, k=key: self._navigate(k))
            self._nav_buttons[key] = btn
            self._page_meta[key] = (icon_char, label, tip)
            lay.addWidget(btn)
            btn.setVisible(False)   # ocultar por defecto; aplicar_permisos_rol los mostrará

        lay.addStretch()
        lay.addWidget(self._hsep())
        lay.addSpacing(6)

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
        btn_logout = QPushButton("🚪  Cerrar Sesión")
        btn_logout.setObjectName("btn_logout")
        btn_logout.setFixedHeight(32)
        btn_logout.setCursor(Qt.CursorShape.PointingHandCursor)
        btn_logout.setStyleSheet("""
            QPushButton#btn_logout {
                background: transparent;
                color: #86868B;
                border: 1px solid rgba(0,0,0,0.10);
                border-radius: 7px;
                font-size: 12px;
                margin: 2px 8px 4px 8px;
                padding: 0 8px;
            }
            QPushButton#btn_logout:hover {
                background: rgba(230,57,70,0.06);
                color: #E63946;
                border-color: rgba(230,57,70,0.3);
            }
            QPushButton#btn_logout:pressed {
                background: rgba(230,57,70,0.12);
            }
        """)
        btn_logout.clicked.connect(self._on_cerrar_sesion)
        lay.addWidget(btn_logout)

        # ── Indicador de conexión ──────────────────────────────────────────────
        self._conn_indicator = ConnectionIndicator()
        lay.addWidget(self._conn_indicator)

        # Versión
        ver = QLabel(f"v{APP_VERSION}")
        ver.setStyleSheet("color: #C7C7CC; font-size: 9px; padding-left: 16px; padding-bottom: 8px;")
        lay.addWidget(ver)

        return sb

    def _build_header(self) -> QWidget:
        """Header mínimo con breadcrumb y título de página actual."""
        header = QWidget()
        header.setObjectName("content_header")
        header.setFixedHeight(52)
        header.setStyleSheet("""
            QWidget#content_header {
                background-color: #F5F5F7;
                border-bottom: 1px solid rgba(0, 0, 0, 0.06);
            }
        """)

        lay = QHBoxLayout(header)
        lay.setContentsMargins(28, 0, 24, 0)
        lay.setSpacing(12)

        # Breadcrumb
        self._lbl_breadcrumb = QLabel("Dashboard")
        self._lbl_breadcrumb.setObjectName("breadcrumb")
        self._lbl_breadcrumb.setStyleSheet(
            "color: #86868B; font-size: 12px; font-weight: 500;"
        )

        lay.addWidget(self._lbl_breadcrumb)
        lay.addStretch()

        # Indicador de sesión (pequeño)
        if _HAS_SESSION and _session and _session.is_authenticated:
            _role_labels = {
                "admin":      "ADMINISTRADOR",
                "logistica":  "LOGÍSTICA",
                "servicio":   "TÉCNICO",
                "calibrador": "CALIBRADOR",
                "inspector":  "INSPECTOR",
                "recepcion":  "RECEPCIÓN",
            }
            _role_txt = _role_labels.get(_session.role, _session.role.upper())
            role_chip = QLabel(f"  {_role_txt}  ")
            role_chip.setStyleSheet("""
                background-color: rgba(230, 57, 70, 0.08);
                color: #E63946;
                font-size: 10px;
                font-weight: 700;
                border-radius: 5px;
                padding: 2px 8px;
                letter-spacing: 0.5px;
            """)
            lay.addWidget(role_chip)

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

        # Paso 3: actualizar chip de usuario
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
            self._stack.setCurrentWidget(self._pages[key])
            self._current_key = key

            # Actualizar botones activos
            for k, btn in self._nav_buttons.items():
                btn.set_active(k == key)

            # Actualizar breadcrumb
            meta = self._page_meta.get(key, ("", key.replace("_", " ").title(), ""))
            self._lbl_breadcrumb.setText(f"{meta[0]}  {meta[1]}")
            self.statusBar().showMessage(f"Módulo: {meta[1]}")
            logger.debug("Navegado a: %s", key)

    def _create_page(self, key: str) -> Optional[QWidget]:
        """Instancia la página del módulo (lazy load)."""
        try:
            if key == "dashboard":
                from ui.widgets.dashboard_widget import DashboardWidget
                w = DashboardWidget()
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

            elif key == "nueva_os":
                from ui.widgets.os_form_widget import OSFormWidget
                w = OSFormWidget()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w
                
            elif key == "nuevo_lp":
                from ui.widgets.lp_form_widget import LPFormWidget
                w = LPFormWidget()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w

            elif key == "nuevo_lv":
                from ui.widgets.lv_form_widget import LVFormWidget
                w = LVFormWidget()
                if hasattr(w, "os_saved"):
                    w.os_saved.connect(self._on_os_saved)
                return w

            elif key == "lote":
                from ui.widgets.batch_generator_widget import BatchGeneratorWidget
                return BatchGeneratorWidget()

            elif key == "buscar_os":
                from ui.widgets.dashboard_widget import DashboardWidget
                # Aplicar filtro RBAC según el rol del usuario activo
                rbac_filter = None
                if _HAS_SESSION and _session:
                    if _session.has_role("calibrador"):
                        rbac_filter = "calibrador"
                    elif _session.has_role("inspector"):
                        rbac_filter = "inspector"
                w = DashboardWidget(
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
                from ui.widgets.recepcion_widget import RecepcionWidget
                return RecepcionWidget()

            elif key == "escaneos":
                from ui.widgets.scanner_widget import ScannerWidget
                return ScannerWidget()

            elif key == "catalogos":
                from ui.widgets.catalogos_widget import CatalogosWidget
                return CatalogosWidget()

            elif key == "configuracion":
                from ui.widgets.configuracion_widget import ConfiguracionWidget
                cfg_w = ConfiguracionWidget()
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

        icon_char = "🚧" if (error or wip) else "⚠"
        lbl_icon = QLabel(icon_char)
        lbl_icon.setObjectName("placeholder_icon")
        lbl_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_icon.setStyleSheet("font-size: 52px; background: transparent;")
        lay.addWidget(lbl_icon)

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
        self.statusBar().showMessage("✅  Folios reiniciados. Dashboard actualizado.", 6000)
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

    def _test_connection(self) -> None:
        from database.connection import db_pool
        self._conn_indicator.set_status(None)
        ok = db_pool.test_connection()
        self._conn_indicator.set_status(ok)
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
            self._conn_indicator.set_status(ok)
        except Exception:
            self._conn_indicator.set_status(False)

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
