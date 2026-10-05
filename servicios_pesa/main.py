"""
Servicios PESA v2.0 — Punto de entrada principal.
Arquitectura de inicio a prueba de fallos: NINGÚN import de UI en el nivel
superior. Todo dentro de main() para poder capturar y reportar cualquier error.
"""
from __future__ import annotations

# ─── SOLO imports de stdlib en el nivel superior ──────────────────────────────────
import sys
import os
import traceback
import logging
import platform
from pathlib import Path


# ══════════════════════════════════════════════════════════════════════════════
# BOOTSTRAP — PRIMER PASO ANTES DE CUALQUIER OTRO IMPORT
# Debe ejecutarse antes de configurar logging, importar config, etc.
# ══════════════════════════════════════════════════════════════════════════════
def _bootstrap() -> None:
    """
    Prepara sys.path y carga el .env ANTES de cualquier import de la app.

    Cuando PyInstaller empaqueta la app:
      - sys.frozen = True
      - sys._MEIPASS = directorio temporal donde se extraen los módulos
    En macOS .app:
      - sys.executable está en Contents/MacOS/PesaServicios
      - los recursos están en Contents/MacOS/_MEIPASS/
    """
    _frozen = getattr(sys, "frozen", False)

    # ─ 1. sys.path: añadir las raíces de módulos ──────────────────────────────
    if _frozen:
        # Módulos del proyecto están en _MEIPASS
        meipass = Path(sys._MEIPASS)  # type: ignore[attr-defined]
        for p in [meipass, meipass / "servicios_pesa"]:
            if str(p) not in sys.path:
                sys.path.insert(0, str(p))
    else:
        # Modo desarrollo: añadir la carpeta servicios_pesa/
        _root = Path(__file__).resolve().parent
        if str(_root) not in sys.path:
            sys.path.insert(0, str(_root))

    # ─ 2. Directorio de datos de usuario (escritura garantizada) ───────────
    _sistema = platform.system()
    if _sistema == "Darwin":
        _app_data = Path.home() / "Library" / "Application Support" / "PesaServicios"
    elif _sistema == "Windows":
        _app_data = Path(os.environ.get("APPDATA") or str(Path.home())) / "PesaServicios"
    else:
        _app_data = Path.home() / ".pesaservicios"
    _app_data.mkdir(parents=True, exist_ok=True)

    # ─ 3. Cargar .env con orden de prioridad ───────────────────────────────
    # Se usa dotenv directamente aquí para no depender de que config.py
    # ya esté importado (rompe el ciclo de dependencias en frozen mode).
    try:
        from dotenv import load_dotenv as _load_dotenv

        _candidatos = [_app_data / ".env"]   # 1. configuración del usuario
        if _frozen:
            _exe_dir = Path(sys.executable).parent
            _candidatos.append(_exe_dir / ".env")                       # 2. junto al .exe
            # macOS: fuera del .app (al lado del bundle en el DMG o en /Applications)
            _candidatos.append(_exe_dir.parent.parent.parent / ".env")
        _candidatos.append(Path(__file__).resolve().parent.parent / ".env")  # 3. dev
        _candidatos.append(Path(os.getcwd()) / ".env")
        if _frozen:
            _candidatos.append(Path(sys._MEIPASS) / ".env")  # type: ignore[attr-defined]  # 4. bundle

        for _ruta in _candidatos:
            if _ruta.exists():
                _load_dotenv(_ruta, override=False)  # No sobreescribe vars de sistema
                break
        else:
            _load_dotenv()  # no-op silencioso
    except ImportError:
        pass  # python-dotenv no instalado; usar solo vars de sistema


_bootstrap()  # ◄◄◄ EJECUTAR ANTES DE CUALQUIER OTRO IMPORT ◄◄◄

# Ahora sí podemos configurar la raíz del proyecto (compatibilidad con modo dev)
_PROJECT_ROOT = Path(__file__).resolve().parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))


# ══════════════════════════════════════════════════════════════════════════════
# PASO 0 — Hook global de excepciones no capturadas
# Captura cualquier crash que ocurra fuera de un try/except explícito.
# ══════════════════════════════════════════════════════════════════════════════
def _global_exception_handler(exc_type, exc_value, exc_tb):
    """Captura excepciones no manejadas y las muestra antes de cerrar."""
    error_text = "".join(traceback.format_exception(exc_type, exc_value, exc_tb))
    print("=" * 70, file=sys.stderr)
    print("ERROR CRÍTICO NO CAPTURADO:", file=sys.stderr)
    print(error_text, file=sys.stderr)
    print("=" * 70, file=sys.stderr)

    # Intentar mostrar QMessageBox si QApplication ya existe
    try:
        from PyQt6.QtWidgets import QApplication, QMessageBox
        if QApplication.instance():
            QMessageBox.critical(
                None,
                "Error Crítico — Servicios PESA",
                f"Error inesperado en la aplicación:\n\n"
                f"{exc_type.__name__}: {exc_value}\n\n"
                f"Revisa el archivo pesa.log para detalles completos."
            )
    except Exception:
        pass  # Si QMessageBox falla, al menos el stderr ya tiene el error

    sys.__excepthook__(exc_type, exc_value, exc_tb)

sys.excepthook = _global_exception_handler


# ══════════════════════════════════════════════════════════════════════════════
def _setup_logging() -> logging.Logger:
    """Configura logging a archivo + consola. Seguro ante permisos."""
    log_format  = "%(asctime)s  [%(levelname)-8s]  %(name)-20s  %(message)s"
    date_format = "%Y-%m-%d %H:%M:%S"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]

    try:
        # Intentar leer LOG_FILE de config, con fallback multiplataforma
        try:
            import config as _cfg
            log_file = str(_cfg.LOG_FILE)
        except Exception:
            # Fallback: escribir en APP_DATA_DIR según el SO
            _sistema = platform.system()
            if _sistema == "Darwin":
                _log_dir = Path.home() / "Library" / "Application Support" / "PesaServicios" / "logs"
            elif _sistema == "Windows":
                _log_dir = Path(os.environ.get("APPDATA") or str(Path.home())) / "PesaServicios" / "logs"
            else:
                _log_dir = Path.home() / ".pesaservicios" / "logs"
            _log_dir.mkdir(parents=True, exist_ok=True)
            log_file = str(_log_dir / "servicios_pesa.log")

        fh = logging.FileHandler(log_file, encoding="utf-8")
        handlers.append(fh)
    except Exception as exc:
        print(f"[WARN] No se pudo crear archivo de log: {exc}", file=sys.stderr)

    logging.basicConfig(
        level    = logging.DEBUG,
        format   = log_format,
        datefmt  = date_format,
        handlers = handlers,
    )
    return logging.getLogger("main")


# ══════════════════════════════════════════════════════════════════════════════
def _load_qss_safe(logger: logging.Logger) -> str:
    """
    Carga la hoja de estilos QSS de forma segura.
    - Omite el QSS si tiene errores de lectura.
    - Nunca lanza excepción.
    - Retorna "" si no puede cargar nada (Qt usará estilos por defecto).
    """
    qss_path = _PROJECT_ROOT / "ui" / "styles" / "theme_apple.qss"

    # Intentar leer el archivo .qss
    if qss_path.exists():
        try:
            content = qss_path.read_text(encoding="utf-8")
            logger.info("QSS cargado: %s (%d bytes)", qss_path.name, len(content))
            return content
        except Exception as exc:
            logger.warning("No se pudo leer %s: %s", qss_path, exc)

    # Fallback al módulo Python
    try:
        from ui.styles.theme import STYLESHEET  # type: ignore
        logger.info("QSS: usando fallback de theme.py")
        return STYLESHEET
    except ImportError:
        logger.info("QSS: sin hoja de estilos (usando Qt por defecto)")
        return ""


# ══════════════════════════════════════════════════════════════════════════════
def _connect_db_safe(logger: logging.Logger) -> bool:
    """
    Intenta conectar a la BD. NUNCA bloquea el inicio de la app.
    Muestra un QMessageBox de advertencia si falla, con opción de Reintentar.
    Retorna True si conectó, False si sigue sin conexión (modo offline).
    """
    from PyQt6.QtWidgets import QMessageBox
    from PyQt6.QtCore    import Qt

    try:
        import config as _cfg
        host = _cfg.DB_CONFIG.get("host", "?")
        port = _cfg.DB_CONFIG.get("port", "?")
        db   = _cfg.DB_CONFIG.get("database", "?")
    except Exception:
        host, port, db = "?", "?", "?"

    logger.info("Intentando conectar a PostgreSQL: %s:%s/%s", host, port, db)

    try:
        from database.connection import db_pool
        db_pool.initialize()
        if db_pool.test_connection():
            try:
                ver = db_pool.get_server_version()
                logger.info("BD conectada: %s", ver[:80])
            except Exception:
                logger.info("BD conectada (versión no disponible)")

            # ── Sembrar usuario administrador si no existe ─────────────────
            try:
                from database.seed import sembrar_usuarios
                _seed_conn = db_pool.get_connection()
                try:
                    sembrados = sembrar_usuarios(_seed_conn)
                    if sembrados:
                        logger.info("Seed: usuarios creados/actualizados: %s", sembrados)
                finally:
                    db_pool.release_connection(_seed_conn)
            except Exception as _seed_exc:
                logger.warning("Seed omitido: %s", _seed_exc)

            return True
        raise ConnectionError("test_connection() retornó False")

    except Exception as exc:
        # Extraer mensaje de forma segura: psycopg2 en Windows puede devolver
        # bytes en cp1252/latin-1 que rompen str() con UnicodeDecodeError.
        try:
            error_str = str(exc)
        except UnicodeDecodeError:
            raw = getattr(exc, "args", None)
            error_str = raw[0].decode("cp1252", errors="replace") if raw else repr(exc)

        logger.warning("Sin conexión a BD: %s", error_str)

        msg = QMessageBox()
        msg.setWindowTitle("Sin Conexión — Servicios PESA")
        msg.setIcon(QMessageBox.Icon.Warning)
        msg.setText(
            "No se pudo conectar a la base de datos PostgreSQL.\n"
            "La aplicación continuará en modo offline (solo Demo)."
        )
        msg.setInformativeText(
            f"Servidor: {host}:{port}\n"
            f"Base de datos: {db}\n\n"
            f"Error: {error_str}\n\n"
            f"Verifique:\n"
            f"  • Servidor PostgreSQL iniciado\n"
            f"  • Credenciales en .env correctas\n"
            f"  • Red / VPN activa"
        )
        msg.setStandardButtons(
            QMessageBox.StandardButton.Retry |
            QMessageBox.StandardButton.Ok
        )
        msg.setDefaultButton(QMessageBox.StandardButton.Ok)

        choice = msg.exec()
        if choice == QMessageBox.StandardButton.Retry:
            return _connect_db_safe(logger)

        logger.info("Continuando en modo offline sin BD.")
        return False



# ══════════════════════════════════════════════════════════════════════════════
def _show_login_safe(app, logger: logging.Logger) -> bool:
    """
    Muestra el LoginDialog de forma segura.
    - Guarda la referencia en `app._login_dlg` para evitar recolección de GC.
    - Retorna True si el usuario autenticó, False si canceló.
    - Si hay cualquier error al crear el dialog, retorna True (modo dev).
    """
    try:
        from ui.dialogs.login_dialog import LoginDialog
        app._login_dlg = LoginDialog()       # referencia fuerte → evita crash de GC
        result = app._login_dlg.exec()
        authenticated = (result == LoginDialog.DialogCode.Accepted)
        logger.info("Login: %s", "OK" if authenticated else "CANCELADO")
        return authenticated

    except ImportError as exc:
        logger.warning("LoginDialog no disponible: %s — saltando login.", exc)
        return True   # Modo dev: continuar sin login

    except Exception as exc:
        logger.exception("ERROR al mostrar LoginDialog: %s", exc)
        # Mostrar el error al usuario y permitir continuar
        try:
            from PyQt6.QtWidgets import QMessageBox
            choice = QMessageBox.critical(
                None,
                "Error en Login — Servicios PESA",
                f"No se pudo mostrar la ventana de login:\n\n{exc}\n\n"
                f"¿Deseas continuar en modo demo (sin autenticación)?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            )
            if choice == QMessageBox.StandardButton.Yes:
                # Configurar sesión demo
                try:
                    from auth.session_context import session
                    session.set(0, "demo", "Usuario Demo", "admin")
                except Exception:
                    pass
                return True
        except Exception:
            pass
        return False


# ══════════════════════════════════════════════════════════════════════════════
def main() -> int:
    """
    Función principal con manejo de errores en cada etapa.
    Estructura:
        1. QApplication + configuración básica
        2. Logging
        3. QSS (tolerante a fallos)
        4. Conexión BD (tolerante, modo offline)
        5. Login (tolerante a fallos de BD)
        6. MainWindow
    """
    # ── Crear QApplication PRIMERO (antes de cualquier widget o import de UI) ──
    # IMPORTANTE: QApplication debe existir antes de cualquier QMessageBox/QDialog
    from PyQt6.QtWidgets import QApplication, QMessageBox
    from PyQt6.QtGui     import QFont

    app = QApplication(sys.argv)

    # ── CRITICO: Forzar estilo Fusion + paleta CLARA para evitar que Windows 11
    #    Dark Mode sobreescriba los popups flotantes de QComboBox con fondo negro.
    #    Fusion es el unico estilo de Qt que respeta 100% el QSS del popup.
    try:
        from PyQt6.QtWidgets import QStyleFactory
        from PyQt6.QtGui     import QPalette, QColor
        app.setStyle(QStyleFactory.create("Fusion"))

        # Paleta clara corporativa PESA
        pal = QPalette()
        # Fondos
        pal.setColor(QPalette.ColorRole.Window,          QColor("#F0F2F5"))
        pal.setColor(QPalette.ColorRole.WindowText,      QColor("#0F172A"))
        pal.setColor(QPalette.ColorRole.Base,            QColor("#FFFFFF"))   # combo/list background
        pal.setColor(QPalette.ColorRole.AlternateBase,   QColor("#F8FAFC"))
        pal.setColor(QPalette.ColorRole.ToolTipBase,     QColor("#1E293B"))
        pal.setColor(QPalette.ColorRole.ToolTipText,     QColor("#FFFFFF"))
        pal.setColor(QPalette.ColorRole.Text,            QColor("#0F172A"))   # combo/list text
        pal.setColor(QPalette.ColorRole.Button,          QColor("#FFFFFF"))
        pal.setColor(QPalette.ColorRole.ButtonText,      QColor("#0F172A"))
        pal.setColor(QPalette.ColorRole.BrightText,      QColor("#C8102E"))
        pal.setColor(QPalette.ColorRole.Link,            QColor("#C8102E"))
        pal.setColor(QPalette.ColorRole.Highlight,       QColor("#FEE2E2"))   # seleccion rojo tenue
        pal.setColor(QPalette.ColorRole.HighlightedText, QColor("#C8102E"))   # texto seleccionado rojo
        pal.setColor(QPalette.ColorRole.PlaceholderText, QColor("#94A3B8"))
        # Disabled
        pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text,       QColor("#CBD5E1"))
        pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.ButtonText, QColor("#CBD5E1"))
        pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Base,       QColor("#F1F5F9"))
        app.setPalette(pal)
        logger.debug("Tema Fusion + paleta clara corporativa PESA aplicada") if 'logger' in dir() else None
    except Exception as _e:
        pass  # Si falla, Qt usara el estilo del sistema (aceptable)

    # ① CRITICO: evitar que Qt cierre el event loop cuando el LoginDialog
    #    se acepta (y aun no hay ninguna ventana visible)
    app.setQuitOnLastWindowClosed(False)

    # ── Logging ────────────────────────────────────────────────────────────────
    logger = _setup_logging()

    try:
        import config as _cfg
        app.setApplicationName(_cfg.APP_NAME)
        app.setApplicationVersion(_cfg.APP_VERSION)
        app.setOrganizationName(getattr(_cfg, "APP_ORGANIZATION", "PESA"))
        logger.info("Iniciando %s v%s", _cfg.APP_NAME, _cfg.APP_VERSION)
    except Exception as exc:
        logger.warning("No se pudo cargar config.py: %s", exc)

    # ── Fuente global ──────────────────────────────────────────────────────────
    try:
        if platform.system() == "Darwin":
            font = QFont(".AppleSystemUIFont", 10)
            font.setFamilies(["-apple-system", "BlinkMacSystemFont", "SF Pro Text", "Helvetica Neue", "Arial"])
        else:
            font = QFont("Segoe UI", 10)
        font.setHintingPreference(QFont.HintingPreference.PreferFullHinting)
        app.setFont(font)
        logger.debug("Fuente global configurada para %s", platform.system())
    except Exception as exc:
        logger.warning("Error configurando fuente: %s", exc)

    # ── QSS (tolerante a fallos) ───────────────────────────────────────────────
    try:
        stylesheet = _load_qss_safe(logger)
        if stylesheet:
            app.setStyleSheet(stylesheet)
            logger.info("QSS aplicado (%d bytes)", len(stylesheet))
    except Exception as exc:
        logger.warning("Error aplicando QSS (se usará estilo por defecto): %s", exc)
        # NO crashear — el estilo por defecto de Qt es perfectamente funcional

    # ── Conexión a BD (nunca bloquea) ─────────────────────────────────────────
    try:
        _connect_db_safe(logger)
    except Exception as exc:
        logger.error("Error inesperado en _connect_db_safe: %s", exc)
        # Continuar en modo offline

    # ── Login ──────────────────────────────────────────────────────────────────
    # ② Referencia fuerte en el objeto `app` para evitar recolección GC
    authenticated = _show_login_safe(app, logger)

    if not authenticated:
        logger.info("Login cancelado por el usuario. Cerrando.")
        return 0

    logger.info("Login exitoso. Cargando ventana principal…")

    # ── MainWindow ─────────────────────────────────────────────────────────────
    # ③ Solo DESPUÉS del login activamos el quit automático
    app.setQuitOnLastWindowClosed(True)

    try:
        from ui.main_window import MainWindow
        window = MainWindow()
        window.show()
        window.activateWindow()
        window.raise_()
        logger.info("MainWindow visible. Iniciando event loop.")
    except Exception as exc:
        logger.exception("ERROR al crear MainWindow: %s", exc)
        QMessageBox.critical(
            None,
            "Error al Iniciar — Servicios PESA",
            f"No se pudo cargar la ventana principal:\n\n{exc}\n\n"
            f"Revisa pesa.log para más detalles.",
        )
        return 1

    return_code = app.exec()
    logger.info("Aplicación terminada con código %d.", return_code)
    return return_code


# ══════════════════════════════════════════════════════════════════════════════
# Entry point con try/except global de último recurso
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise   # Dejar que sys.exit() funcione normalmente
    except Exception:
        error_text = traceback.format_exc()
        print("\n" + "=" * 70, file=sys.stderr)
        print("ERROR CRÍTICO AL INICIAR SERVICIOS PESA:", file=sys.stderr)
        print(error_text, file=sys.stderr)
        print("=" * 70 + "\n", file=sys.stderr)

        # Intentar mostrar QMessageBox si QApplication existe
        try:
            from PyQt6.QtWidgets import QApplication, QMessageBox
            _emergency_app = QApplication.instance() or QApplication(sys.argv)
            QMessageBox.critical(
                None,
                "Error de Inicialización — Servicios PESA",
                f"No se pudo iniciar la aplicación.\n\n"
                f"{error_text[-800:]}",   # Últimas 800 chars del traceback
            )
        except Exception:
            pass

        sys.exit(1)
