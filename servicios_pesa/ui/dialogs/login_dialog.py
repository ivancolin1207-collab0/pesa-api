"""
login_dialog.py — Diálogo de inicio de sesión Enterprise v3.0
Básculas PESA — ERP Metrológico y de Servicios

Diseño: Enterprise / Industrial UI
- Fondo oscuro corporativo (#1A1C23) con fondo de patrón de cuadrícula sutil
- Tarjeta blanca centrada con logo BP cargado desde assets
- Inputs flat con focus en rojo corporativo (#C8102E)
- Botón CTA rojo PESA, botón Salir ghost
- Badge de conexión BD minimalista
- Sin emojis, sin doodles, sin patrones informales
"""
from __future__ import annotations

import hashlib
import logging
import os
from pathlib import Path
from typing import Optional

from PyQt6.QtCore    import Qt, QTimer, QSize, QPoint, pyqtSignal
from PyQt6.QtGui     import (
    QAction, QColor, QLinearGradient, QPainter, QBrush,
    QPen, QFont, QPixmap, QPainterPath,
)
from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QFrame,
    QProgressBar, QSizePolicy, QWidget,
)

logger = logging.getLogger(__name__)

# ─── Dependencias opcionales ──────────────────────────────────────────────────
try:
    from auth.session_context import session as _global_session, normalize_role
    _HAS_SESSION = True
except ImportError as _e:
    logger.warning("session_context no disponible: %s", _e)
    _HAS_SESSION = False
    _global_session = None
    def normalize_role(r: str) -> str: return r.strip().lower()  # fallback

try:
    from database.connection import db_pool
    _HAS_DB = True
except ImportError as _e:
    logger.warning("database.connection no disponible: %s", _e)
    _HAS_DB = False
    db_pool = None  # type: ignore

# ─── Paleta corporativa ───────────────────────────────────────────────────────
_RED      = "#B81D24"    # Rojo carmín PESA principal
_RED_H    = "#9E161C"    # Hover
_RED_P    = "#831116"    # Pressed
_BG       = "#F5F5F7"    # Fondo ventana macOS gray
_DARK2    = "#1D1D1F"    # Texto Apple Anthracite
_CARD_BG  = "#FFFFFF"    # Tarjeta blanca
_FIELD_BG = "#FAFAFA"    # Fondo input
_BORDER   = "#D1D1D6"    # Borde input neutro
_GRAY     = "#86868B"    # Texto secundario
_GRAY2    = "#5A6070"    # Texto botón salir
_LGRAY    = "#B0B7C3"    # Gris claro
_SUCCESS  = "#16A34A"    # Verde conexión OK
_DANGER   = "#DC2626"    # Rojo conexión KO
_WHITE    = "#FFFFFF"


# ══════════════════════════════════════════════════════════════════════════════
class _BackgroundWidget(QWidget):
    """
    Widget de fondo gris neutro estilo macOS (#F5F5F7).
    """

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("#F5F5F7"))


# ══════════════════════════════════════════════════════════════════════════════
class LoginDialog(QDialog):
    """
    Diálogo modal de autenticación — Enterprise UI v4.0.
    Diseño minimalista con tarjeta central flotante (420px, radius 16px).
    """
    login_successful = pyqtSignal(str)   # emite el rol del usuario

    _MAX_ATTEMPTS    = 5
    _LOCKOUT_SECONDS = 60

    def __init__(self, parent=None):
        try:
            super().__init__(parent)
            self._attempts   = 0
            self._locked     = False
            self._eye_action = None
            self._lock_timer = QTimer(self)
            self._lock_timer.setSingleShot(True)
            self._lock_timer.timeout.connect(self._unlock)

            self._build_ui()
            self._apply_styles()

            QTimer.singleShot(200, self._check_db_connection)

        except Exception as exc:
            logger.exception("Error al inicializar LoginDialog: %s", exc)
            raise

    # ══════════════════════════════════════════════════════════════════════════
    # CONSTRUCCIÓN DE LA UI
    # ══════════════════════════════════════════════════════════════════════════

    def _build_ui(self) -> None:
        self.setWindowTitle("Servicios PESA — Acceso Corporativo")
        self.setModal(True)
        self.setFixedSize(480, 620)
        self.setWindowFlag(Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)

        # Capa exterior: fondo gris con padding para la sombra
        outer = QVBoxLayout(self)
        outer.setContentsMargins(30, 30, 30, 30)
        outer.setSpacing(0)

        # Tarjeta blanca central flotante (420px de ancho)
        card = QFrame()
        card.setObjectName("login_card")
        card.setFixedWidth(420)

        # Sombra suave desplegada en tarjeta
        from PyQt6.QtWidgets import QGraphicsDropShadowEffect
        shadow = QGraphicsDropShadowEffect(card)
        shadow.setBlurRadius(24)
        shadow.setOffset(0, 6)
        shadow.setColor(QColor(0, 0, 0, 16))
        card.setGraphicsEffect(shadow)

        outer.addWidget(card, alignment=Qt.AlignmentFlag.AlignCenter)

        lay = QVBoxLayout(card)
        lay.setContentsMargins(36, 32, 36, 28)
        lay.setSpacing(0)

        # ── 1. Franja de marca superior (logo + subtítulo técnico) ────────────
        lay.addWidget(self._build_logo_header())
        lay.addSpacing(22)

        # ── 2. Separador con etiqueta ──────────────────────────────────────────
        lay.addWidget(self._build_divider("ACCESO AL SISTEMA"))
        lay.addSpacing(18)

        # ── 3. Campo Usuario ───────────────────────────────────────────────────
        lay.addWidget(self._field_label("USUARIO"))
        lay.addSpacing(5)
        self.txt_user = self._build_input(
            placeholder="Nombre de usuario",
            object_name="login_input"
        )
        lay.addWidget(self.txt_user)
        lay.addSpacing(14)

        # ── 4. Campo Contraseña ────────────────────────────────────────────────
        lay.addWidget(self._field_label("CONTRASEÑA"))
        lay.addSpacing(5)
        self.txt_pass = self._build_password_field()
        lay.addWidget(self.txt_pass)
        lay.addSpacing(4)

        # ── 5. Estado / error ──────────────────────────────────────────────────
        self.lbl_status = QLabel("")
        self.lbl_status.setObjectName("login_status")
        self.lbl_status.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.lbl_status.setWordWrap(True)
        self.lbl_status.setFixedHeight(28)
        lay.addWidget(self.lbl_status)

        # ── 6. Barra de progreso (indeterminada, oculta por defecto) ───────────
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setObjectName("login_progress")
        self.progress.setFixedHeight(3)
        self.progress.setVisible(False)
        lay.addWidget(self.progress)
        lay.addSpacing(10)

        # ── 7. Botón principal CTA ────────────────────────────────────────────
        self.btn_login = QPushButton("Iniciar Sesión")
        self.btn_login.setObjectName("btn_login")
        self.btn_login.setFixedHeight(48)
        self.btn_login.setCursor(Qt.CursorShape.PointingHandCursor)
        self.btn_login.clicked.connect(self._do_login)
        lay.addWidget(self.btn_login)
        lay.addSpacing(8)

        # ── 8. Botón Salir (ghost) ────────────────────────────────────────────
        self.btn_salir = QPushButton("Cerrar Aplicación")
        self.btn_salir.setObjectName("btn_salir")
        self.btn_salir.setFixedHeight(36)
        self.btn_salir.setCursor(Qt.CursorShape.PointingHandCursor)
        self.btn_salir.clicked.connect(self._on_salir)
        lay.addWidget(self.btn_salir)

        lay.addStretch()

        # ── 9. Footer: BD badge + versión ────────────────────────────────────
        lay.addWidget(self._build_footer())

        # ── Conexiones de teclado ─────────────────────────────────────────────
        self.txt_user.returnPressed.connect(lambda: self.txt_pass.setFocus())
        self.txt_pass.returnPressed.connect(self._do_login)

    # ── Componentes de UI ─────────────────────────────────────────────────────

    def _build_logo_header(self) -> QWidget:
        """
        Cabecera con logo BP cargado desde assets/images/bp_pesa_logo.jpg y subtítulo técnico.
        """
        container = QWidget()
        container.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(container)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # ── Intentar cargar el logo ───────────────────────────────────────────
        logo_path = Path(__file__).parent.parent.parent / "assets" / "images" / "bp_pesa_logo.jpg"
        logo_loaded = False

        if logo_path.exists():
            pix = QPixmap(str(logo_path))
            if not pix.isNull():
                pix_scaled = pix.scaledToWidth(240, Qt.TransformationMode.SmoothTransformation)
                lbl_logo = QLabel()
                lbl_logo.setPixmap(pix_scaled)
                lbl_logo.setAlignment(Qt.AlignmentFlag.AlignCenter)
                lbl_logo.setStyleSheet("background: transparent; border: none;")
                lay.addWidget(lbl_logo)
                logo_loaded = True

        if not logo_loaded:
            row = QHBoxLayout()
            row.setAlignment(Qt.AlignmentFlag.AlignCenter)
            row.setSpacing(12)

            lbl_mono = QLabel("BP")
            lbl_mono.setFixedSize(50, 50)
            lbl_mono.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl_mono.setStyleSheet(f"""
                background: {_RED};
                color: white;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
                font-size: 20px;
                font-weight: 800;
                border-radius: 10px;
            """)
            row.addWidget(lbl_mono)

            text_col = QVBoxLayout()
            text_col.setSpacing(1)

            lbl_name = QLabel("BÁSCULAS PESA")
            lbl_name.setStyleSheet(f"""
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
                font-size: 18px;
                font-weight: 800;
                color: {_DARK2};
                background: transparent;
                letter-spacing: 1.2px;
            """)
            text_col.addWidget(lbl_name)

            lbl_tagline = QLabel("Metrología & Servicios")
            lbl_tagline.setStyleSheet(f"""
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 11px;
                color: {_GRAY};
                background: transparent;
            """)
            text_col.addWidget(lbl_tagline)
            row.addLayout(text_col)
            lay.addLayout(row)

        # ── Subtítulo del sistema ─────────────────────────────────────────────
        lbl_sys = QLabel("Ecosistema Metrológico Operativo")
        lbl_sys.setObjectName("login_subtitle")
        lbl_sys.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.addWidget(lbl_sys)

        return container

    def _build_divider(self, label: str) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(10)

        for i in range(2):
            line = QFrame()
            line.setFrameShape(QFrame.Shape.HLine)
            line.setStyleSheet(f"background: #E5E5EA; max-height: 1px; border: none;")
            lay.addWidget(line, stretch=1)
            if i == 0:
                lbl = QLabel(label)
                lbl.setStyleSheet(f"""
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                    font-size: 9px;
                    font-weight: 700;
                    color: {_GRAY};
                    background: transparent;
                    letter-spacing: 1.5px;
                    padding: 0 4px;
                """)
                lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
                lay.addWidget(lbl)

        return w

    @staticmethod
    def _field_label(text: str) -> QLabel:
        lbl = QLabel(text)
        lbl.setObjectName("login_field_label")
        return lbl

    @staticmethod
    def _build_input(placeholder: str = "", object_name: str = "login_input") -> QLineEdit:
        field = QLineEdit()
        field.setObjectName(object_name)
        field.setPlaceholderText(placeholder)
        field.setFixedHeight(46)
        return field

    def _build_password_field(self) -> QLineEdit:
        field = QLineEdit()
        field.setObjectName("login_input")
        field.setPlaceholderText("Contraseña")
        field.setEchoMode(QLineEdit.EchoMode.Password)
        field.setFixedHeight(46)

        try:
            self._eye_action = QAction(field)
            self._eye_action.setText("👁")
            self._eye_action.setCheckable(True)
            self._eye_action.toggled.connect(
                lambda visible, f=field: f.setEchoMode(
                    QLineEdit.EchoMode.Normal if visible else QLineEdit.EchoMode.Password
                )
            )
            field.addAction(self._eye_action, QLineEdit.ActionPosition.TrailingPosition)
        except Exception as exc:
            logger.debug("QAction ojo no disponible (%s).", exc)
            self._eye_action = None

        return field

    def _build_footer(self) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        lay = QHBoxLayout(w)
        lay.setContentsMargins(0, 6, 0, 0)
        lay.setSpacing(0)

        conn_row = QHBoxLayout()
        conn_row.setSpacing(5)
        conn_row.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)

        self.lbl_conn_dot = QLabel("●")
        self.lbl_conn_dot.setStyleSheet(f"color: {_LGRAY}; font-size: 7px; background: transparent;")
        self.lbl_conn_text = QLabel("Verificando…")
        self.lbl_conn_text.setStyleSheet(
            f"color: {_GRAY}; font-size: 9px; font-family: -apple-system, sans-serif; background: transparent;"
        )
        conn_row.addWidget(self.lbl_conn_dot)
        conn_row.addWidget(self.lbl_conn_text)
        lay.addLayout(conn_row)

        lay.addStretch()

        lbl_ver = QLabel("Básculas PESA  ·  v4.0")
        lbl_ver.setObjectName("login_version")
        lbl_ver.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        lay.addWidget(lbl_ver)

        return w

    # ── Estilos QSS ──────────────────────────────────────────────────────────

    def _apply_styles(self) -> None:
        self.setStyleSheet(f"""
            QDialog {{
                background-color: transparent;
            }}

            QFrame#login_card {{
                background-color: {_CARD_BG};
                border-radius: 16px;
                border: 1px solid #E5E5EA;
            }}

            QLabel#login_subtitle {{
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 11px;
                color: {_GRAY};
                background: transparent;
                padding-top: 2px;
            }}

            QLabel#login_field_label {{
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 10px;
                font-weight: 600;
                color: {_GRAY};
                background: transparent;
                letter-spacing: 1.2px;
            }}

            QLineEdit#login_input {{
                background-color: {_FIELD_BG};
                color: {_DARK2};
                border: 1px solid {_BORDER};
                border-radius: 8px;
                padding: 0px 14px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 14px;
                selection-background-color: rgba(184, 29, 36, 0.15);
            }}
            QLineEdit#login_input:focus {{
                border: 1.5px solid {_RED};
                background-color: {_WHITE};
                color: {_DARK2};
            }}
            QLineEdit#login_input:disabled {{
                background-color: #F5F5F7;
                color: {_LGRAY};
                border-color: {_BORDER};
            }}
            QLineEdit#login_input::placeholder {{
                color: {_LGRAY};
            }}

            QLabel#login_status {{
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 11px;
                background: transparent;
                padding: 2px 4px;
            }}

            QProgressBar#login_progress {{
                border: none;
                border-radius: 1px;
                background-color: #E5E5EA;
            }}
            QProgressBar#login_progress::chunk {{
                background-color: {_RED};
                border-radius: 1px;
            }}

            QPushButton#btn_login {{
                background-color: {_RED};
                color: {_WHITE};
                border: none;
                border-radius: 8px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 14px;
                font-weight: 600;
                letter-spacing: 0.5px;
                min-height: 48px;
            }}
            QPushButton#btn_login:hover   {{ background-color: {_RED_H}; }}
            QPushButton#btn_login:pressed {{ background-color: {_RED_P}; }}
            QPushButton#btn_login:disabled {{
                background-color: #C7C7CC;
                color: #FFFFFF;
            }}

            QPushButton#btn_salir {{
                background: transparent;
                color: {_GRAY};
                border: 1px solid #E5E5EA;
                border-radius: 8px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 12px;
                font-weight: 500;
            }}
            QPushButton#btn_salir:hover {{
                background: #F5F5F7;
                color: {_DARK2};
                border-color: #D1D1D6;
            }}
            QPushButton#btn_salir:pressed {{
                background: #E5E5EA;
            }}

            QLabel#login_version {{
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 9px;
                color: {_GRAY};
                background: transparent;
            }}
        """)

    def paintEvent(self, event) -> None:
        """Dibuja el fondo gris neutro #F5F5F7 estilo macOS."""
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), QColor("#F5F5F7"))

    # ══════════════════════════════════════════════════════════════════════════
    # LÓGICA DE AUTENTICACIÓN (sin cambios funcionales)
    # ══════════════════════════════════════════════════════════════════════════

    def _do_login(self) -> None:
        if self._locked:
            self._show_error("Cuenta bloqueada. Espera para intentar de nuevo.")
            return

        username = self.txt_user.text().strip()
        password = self.txt_pass.text()

        if not username:
            self._show_error("Ingresa tu nombre de usuario.")
            self.txt_user.setFocus()
            return
        if not password:
            self._show_error("Ingresa tu contraseña.")
            self.txt_pass.setFocus()
            return

        self._set_loading(True)
        self.lbl_status.setText("")

        try:
            user_data = self._authenticate(username, password)
            if user_data:
                self._on_success(user_data)
            else:
                self._on_fail(username)
        except Exception as exc:
            # Mensaje seguro ante bytes ANSI/cp1252 de psycopg2 en Windows
            try:
                exc_str = str(exc)
            except UnicodeDecodeError:
                raw = getattr(exc, "args", None)
                exc_str = raw[0].decode("cp1252", errors="replace") if raw else repr(exc)
            logger.exception("Error durante autenticación: %s", exc_str)
            self._show_error(f"Error de conexión:\n{exc_str}")
        finally:
            self._set_loading(False)

    @staticmethod
    def _hash_pw(plain: str) -> str:
        return hashlib.sha256(plain.encode("utf-8")).hexdigest()

    def _authenticate(self, username: str, password: str) -> Optional[dict]:
        input_hash = self._hash_pw(password)
        print(f"[LOGIN DEBUG] Buscando usuario: '{username}' | Hash SHA-256: {input_hash[:16]}...")

        if _HAS_DB and db_pool is not None:
            conn = None
            try:
                import json as _json
                from psycopg2.extras import RealDictCursor
                conn = db_pool.get_connection()
                try:
                    with conn.cursor(cursor_factory=RealDictCursor) as cur:
                        cur.execute(
                            """
                            SELECT id,
                                   usuario          AS username,
                                   nombre_completo,
                                   id               AS id_tecnico,
                                   rol,
                                   password_hash,
                                   COALESCE(firma_digital, '') AS firma_digital
                            FROM   cat_tecnicos
                            WHERE  LOWER(usuario) = LOWER(%s)
                              AND  activo = TRUE
                            """,
                            (username.strip(),),
                        )
                        row = cur.fetchone()

                        if row is None:
                            print(f"[LOGIN DEBUG] Usuario '{username}' no encontrado.")
                            return None

                        try:
                            cur.execute(
                                "SELECT roles FROM cat_tecnicos "
                                "WHERE LOWER(usuario) = LOWER(%s) AND activo = TRUE",
                                (username.strip(),)
                            )
                            roles_row = cur.fetchone()
                            roles_raw = (roles_row or {}).get("roles") if roles_row else None
                        except Exception:
                            roles_raw = None

                        if roles_raw:
                            try:
                                roles_list = _json.loads(roles_raw)
                                if not isinstance(roles_list, list):
                                    roles_list = [str(roles_list)]
                            except Exception:
                                roles_list = [roles_raw]
                        else:
                            roles_list = [row.get("rol") or "Técnico"]

                        db_hash  = row.get("password_hash") or ""
                        is_valid = False

                        if db_hash.startswith("$2"):
                            try:
                                import bcrypt
                                is_valid = bcrypt.checkpw(
                                    password.encode("utf-8"),
                                    db_hash.encode("utf-8")
                                )
                            except ImportError:
                                logger.warning("[LOGIN] bcrypt no instalado.")
                        else:
                            is_valid = (input_hash == db_hash)

                        if not is_valid:
                            return None

                        user_dict = dict(row)
                        user_dict.pop("password_hash", None)
                        user_dict["roles"] = roles_list

                        # ── Bloqueo de login: técnico sin firma digital ──
                        # Si el usuario tiene rol de técnico y no tiene
                        # firma_digital registrada, se bloquea el acceso a
                        # Windows hasta que registre su firma en la Tablet.
                        _roles_internos = {normalize_role(r) for r in roles_list}
                        _roles_tecnicos = {"servicio", "calibrador", "inspector"}
                        if _roles_internos & _roles_tecnicos and not _roles_internos.issuperset({"admin"}):
                            firma_val = str(user_dict.get("firma_digital") or "").strip()
                            if not firma_val:
                                from PyQt6.QtWidgets import QMessageBox
                                QMessageBox.warning(
                                    None,
                                    "⚠️  Firma Digital Requerida",
                                    f"Hola {user_dict.get('nombre_completo', username)},\n\n"
                                    "No se encontró tu firma digital registrada en el sistema.\n\n"
                                    "Para ingresar al sistema de escritorio de Windows, "
                                    "primero debes trazar y guardar tu firma en la "
                                    "\n\nApp PESA en la Tablet Android.\n\n"
                                    "Pasos:\n"
                                    "  1. Abre la app PESA en la Tablet.\n"
                                    "  2. Ve a Configuración \u2192 Mi Firma.\n"
                                    "  3. Traza tu firma y pulsa [Guardar].\n"
                                    "  4. Intenta iniciar sesión en Windows nuevamente."
                                )
                                return None  # Login bloqueado

                        user_dict.pop("firma_digital", None)   # No exponer el blob
                        return user_dict
                finally:
                    if conn:
                        db_pool.release_connection(conn)
            except Exception as exc:
                logger.error("Error de BD en autenticación: %s", exc)

        # ── Modo Demo (sin BD) ────────────────────────────────────────────────
        _DEMO = {
            "admin":         ("Administrador [Demo]",          "admin",     None),
            "ivancolin1207": ("Iván Colín [Demo]",             "admin",     None),
            "logistica":     ("Logística Demo",                "logistica", None),
            "luis.fernando": ("Luis Fernando Guerrero [Demo]", "servicio",  1),
            "recepcion":     ("Recepción Demo",                "recepcion", None),
        }
        entry = _DEMO.get(username.lower())
        if entry and password:
            nombre, rol, id_tec = entry
            return {
                "id": 0, "username": username.lower(),
                "nombre_completo": nombre,
                "rol": rol, "id_tecnico": id_tec,
            }
        return None

    def _on_success(self, user_data: dict) -> None:
        try:
            if _HAS_SESSION and _global_session is not None:
                roles = user_data.get("roles")
                if not roles:
                    rol_str = user_data.get("rol", "Técnico")
                    roles = [rol_str] if rol_str else ["Técnico"]

                _global_session.set(
                    user_id         = user_data.get("id", 0),
                    username        = user_data.get("username", ""),
                    nombre_completo = user_data.get("nombre_completo", ""),
                    roles           = roles,
                    id_tecnico      = user_data.get("id_tecnico"),
                )
        except Exception as exc:
            logger.error("Error configurando sesión: %s", exc)

        logger.info(
            "Login exitoso — usuario=%s roles=%s",
            user_data.get("username"), user_data.get("roles", user_data.get("rol")),
        )
        self.login_successful.emit(user_data.get("rol", "admin"))
        self.accept()

    def _on_fail(self, username: str) -> None:
        self._attempts += 1
        logger.warning("Login fallido — usuario=%r intento=%d", username, self._attempts)

        remaining = self._MAX_ATTEMPTS - self._attempts
        if remaining > 0:
            self._show_error(
                f"Usuario o contraseña incorrectos  ·  "
                f"{remaining} intento{'s' if remaining != 1 else ''} restante{'s' if remaining != 1 else ''}"
            )
            self.txt_pass.setText("")
            self.txt_pass.setFocus()
        else:
            self._locked = True
            self.btn_login.setEnabled(False)
            self.txt_user.setEnabled(False)
            self.txt_pass.setEnabled(False)
            self._show_error(
                f"Acceso bloqueado {self._LOCKOUT_SECONDS}s por demasiados intentos."
            )
            self._lock_timer.start(self._LOCKOUT_SECONDS * 1000)

    def _unlock(self) -> None:
        self._locked   = False
        self._attempts = 0
        self.btn_login.setEnabled(True)
        self.txt_user.setEnabled(True)
        self.txt_pass.setEnabled(True)
        self.txt_pass.setText("")
        self._show_status("Puedes intentar de nuevo.", color=_SUCCESS)

    # ── Conexión a BD ─────────────────────────────────────────────────────────

    def _check_db_connection(self) -> None:
        try:
            if not _HAS_DB or db_pool is None:
                self._set_conn(
                    "●", f"color:{_DANGER};font-size:7px;background:transparent;",
                    "Sin BD — modo offline",
                    f"color:{_LGRAY};font-size:9px;font-family:'Segoe UI';background:transparent;"
                )
                return
            conn = db_pool.get_connection()
            db_pool.release_connection(conn)
            self._set_conn(
                "●", f"color:{_SUCCESS};font-size:7px;background:transparent;",
                "BD Conectada — PostgreSQL",
                f"color:{_SUCCESS};font-size:9px;font-family:'Segoe UI';font-weight:600;background:transparent;"
            )
        except Exception as exc:
            # Mensaje seguro ante bytes ANSI/cp1252 de psycopg2 en Windows
            try:
                exc_str = str(exc)
            except UnicodeDecodeError:
                raw = getattr(exc, "args", None)
                exc_str = raw[0].decode("cp1252", errors="replace") if raw else repr(exc)
            logger.warning("Sin conexión a BD en login: %s", exc_str)
            self._set_conn(
                "●", f"color:{_DANGER};font-size:7px;background:transparent;",
                "Sin conexión — modo offline",
                f"color:{_LGRAY};font-size:9px;font-family:'Segoe UI';background:transparent;"
            )

    def _set_conn(self, dot: str, dot_css: str, text: str, text_css: str) -> None:
        try:
            self.lbl_conn_dot.setText(dot)
            self.lbl_conn_dot.setStyleSheet(dot_css)
            self.lbl_conn_text.setText(text)
            self.lbl_conn_text.setStyleSheet(text_css)
        except RuntimeError:
            pass

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _set_loading(self, loading: bool) -> None:
        self.progress.setVisible(loading)
        self.btn_login.setEnabled(not loading)
        self.btn_login.setText("VERIFICANDO…" if loading else "INGRESAR AL SISTEMA")

    def _show_error(self, msg: str) -> None:
        self._show_status(msg, color=_RED)

    def _show_status(self, msg: str, color: str = "#374151") -> None:
        self.lbl_status.setText(msg)
        self.lbl_status.setStyleSheet(
            f"color:{color}; font-size:11px; background:transparent; font-family:'Segoe UI';"
        )

    # ── Salir ─────────────────────────────────────────────────────────────────

    def _on_salir(self) -> None:
        try:
            from PyQt6.QtWidgets import QApplication
            QApplication.quit()
        except Exception as exc:
            logger.exception("Error al salir: %s", exc)
            import sys
            sys.exit(0)

    def closeEvent(self, event) -> None:
        try:
            from PyQt6.QtWidgets import QApplication
            QApplication.quit()
        except Exception:
            import sys
            sys.exit(0)
        event.accept()
