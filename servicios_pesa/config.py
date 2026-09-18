"""
Configuración central de Servicios PESA.
Todas las variables sensibles se leen desde variables de entorno o archivo .env
Copiar .env.example a .env y ajustar los valores antes de ejecutar.

MULTIPLATAFORMA:
  - Windows : %%APPDATA%%\\PesaServicios\\
  - macOS   : ~/Library/Application Support/PesaServicios/
  - Linux   : ~/.pesaservicios/
"""
import os
import sys
import platform
from pathlib import Path
from dotenv import load_dotenv


# ══════════════════════════════════════════════════════════════════════════════
# DIRECTORIO DE DATOS DE USUARIO (con permisos de escritura garantizados)
# ══════════════════════════════════════════════════════════════════════════════

def get_app_data_dir() -> Path:
    """
    Devuelve la carpeta raíz de datos de la app según el sistema operativo.
    Siempre tiene permisos de escritura (nunca apunta al bundle ni al DMG).
    """
    sistema = platform.system()
    if sistema == "Darwin":                                      # macOS
        base = Path.home() / "Library" / "Application Support" / "PesaServicios"
    elif sistema == "Windows":
        appdata = os.environ.get("APPDATA") or str(Path.home())
        base = Path(appdata) / "PesaServicios"
    else:                                                        # Linux / otros
        base = Path.home() / ".pesaservicios"

    base.mkdir(parents=True, exist_ok=True)
    return base


APP_DATA_DIR: Path = get_app_data_dir()


# ══════════════════════════════════════════════════════════════════════════════
# CARGA DEL ARCHIVO .ENV (resiliente a bundles PyInstaller y DMG)
# ══════════════════════════════════════════════════════════════════════════════

def _cargar_env() -> None:
    """
    Busca el archivo .env en múltiples ubicaciones en orden de prioridad:
      1. Junto al binario empaquetado (sys._MEIPASS, si estamos frozen)
      2. En APP_DATA_DIR (configuración persistente del usuario)
      3. En el directorio de trabajo actual (desarrollo)
    """
    candidatos: list[Path] = []

    # ─ 1. Frozen (PyInstaller / macOS .app bundle) ──────────────────────────
    if getattr(sys, "frozen", False):
        candidatos.append(Path(sys._MEIPASS) / ".env")  # type: ignore[attr-defined]
        # En macOS .app el ejecutable está en Contents/MacOS/
        # El .env empaquetado quedaría en Contents/MacOS/_MEIPASS/.env
        # También buscamos junto al .app para configuración de usuario
        exe_dir = Path(sys.executable).parent
        candidatos.append(exe_dir / ".env")
        candidatos.append(exe_dir.parent.parent / ".env")  # fuera del .app

    # ─ 2. Configuración persistente del usuario ──────────────────────────────
    candidatos.append(APP_DATA_DIR / ".env")

    # ─ 3. Directorio de trabajo (modo desarrollo) ───────────────────────────
    candidatos.append(Path(os.getcwd()) / ".env")
    candidatos.append(Path(__file__).parent.parent / ".env")

    for ruta in candidatos:
        if ruta.exists():
            load_dotenv(ruta)
            return  # Carga solo el primero encontrado

    # Si no se encontró ninguno, dotenv usará solo las variables de entorno
    # del sistema (perfecto para entornos CI/CD o servidores)
    load_dotenv()   # no-op silencioso si no hay .env


_cargar_env()


# ══════════════════════════════════════════════════════════════════════════════
# APLICACIÓN
# ══════════════════════════════════════════════════════════════════════════════
APP_NAME         = "Servicios PESA"
APP_VERSION      = "1.0.0"
APP_ORGANIZATION = "Básculas PESA"


# ══════════════════════════════════════════════════════════════════════════════
# BASE DE DATOS
# Prioridad:
#   1. DATABASE_URL (Render Production)  →  postgresql://user:pass@host:5432/db
#   2. Variables PESA_DB_* individuales  →  Red local / VPN
#   3. Defaults hardcoded               →  192.168.0.9 (servidor de oficina)
# ══════════════════════════════════════════════════════════════════════════════

def _parse_db_url(url: str) -> dict:
    """Parsea un DATABASE_URL PostgreSQL en un dict compatible con psycopg2."""
    import urllib.parse
    p = urllib.parse.urlparse(url)
    return {
        "host":             p.hostname or "localhost",
        "port":             p.port or 5432,
        "database":         (p.path or "/servicios_pesa").lstrip("/"),
        "user":             p.username or "pesa_app",
        "password":         p.password or "PesaApp2026!",
        "connect_timeout":  30,   # Render puede tardar ~10-15s la primera query
        "application_name": APP_NAME,
        "options":          "-c search_path=public",
        "sslmode":          "require" if p.hostname and ".render.com" in p.hostname else "prefer",
    }

_DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
if _DATABASE_URL:
    # Modo producción: Render PostgreSQL
    DB_CONFIG: dict = _parse_db_url(_DATABASE_URL)
else:
    # Modo local / VPN: variables individuales PESA_DB_*
    DB_CONFIG: dict = {
        "host":             os.getenv("PESA_DB_HOST",     "192.168.0.9").strip(),
        "port":             int(os.getenv("PESA_DB_PORT", "5432").strip()),
        "database":         os.getenv("PESA_DB_NAME",     "servicios_pesa").strip(),
        "user":             os.getenv("PESA_DB_USER",     "pesa_app").strip(),
        "password":         os.getenv("PESA_DB_PASSWORD", "PesaApp2026!").strip(),
        "connect_timeout":  10,
        "application_name": APP_NAME,
        "options":          "-c search_path=public",
    }



# ══════════════════════════════════════════════════════════════════════════════
# RUTAS DE ARCHIVOS (Servidor central via VPN/LAN)
# ══════════════════════════════════════════════════════════════════════════════

def _get_files_path() -> str:
    """
    Resuelve la ruta de archivos compartidos según el SO y disponibilidad.

    Prioridad:
      1. Variable de entorno PESA_FILES_PATH (si está definida)
      2. macOS: /Volumes/PesaServidorCentral (si el volumen SMB está montado)
      3. macOS fallback: ~/Library/Application Support/PesaServicios/archivos (local)
      4. Windows: ruta UNC \\\\192.168.0.9\\PesaServidorCentral
      5. Linux: ~/.pesaservicios/archivos
    """
    env_val = os.getenv("PESA_FILES_PATH", "").strip()
    if env_val:
        return env_val

    sistema = platform.system()
    if sistema == "Darwin":  # macOS
        smb_mount = Path("/Volumes/PesaServidorCentral")
        if smb_mount.exists() and smb_mount.is_dir():
            return str(smb_mount)  # Volumen SMB montado ✓
        # Fallback local: nunca crashea, siempre escribible
        local_files = APP_DATA_DIR / "archivos"
        local_files.mkdir(parents=True, exist_ok=True)
        return str(local_files)
    elif sistema == "Windows":
        return r"\\192.168.0.9\PesaServidorCentral"
    else:
        local_files = APP_DATA_DIR / "archivos"
        local_files.mkdir(parents=True, exist_ok=True)
        return str(local_files)


SERVER_FILES_BASE: str = _get_files_path()
ESCANEOS_DIR: str      = "Escaneos_OS"   # Subcarpeta para escaneos
PDF_DIR: str           = "PDF_OS"        # Subcarpeta para PDFs del servidor


# ══════════════════════════════════════════════════════════════════════════════
# RUTAS LOCALES (escritura garantizada en cualquier plataforma)
# ══════════════════════════════════════════════════════════════════════════════

# Directorio de PDFs generados localmente (modo campo / tablet / sin red)
PDFS_DIR: Path = APP_DATA_DIR / "formatos_generados"
PDFS_DIR.mkdir(parents=True, exist_ok=True)

# SQLite local para modo offline
LOCAL_DB_PATH: str = os.getenv(
    "PESA_LOCAL_DB",
    str(APP_DATA_DIR / "pesa_local.db"),
)

# Carpeta de PDFs en la tablet (compatible con ambos sistemas)
TABLET_PDF_DIR: str = os.getenv(
    "PESA_TABLET_PDF_DIR",
    str(Path.home() / "Documents" / "PESA_Tablet" / "Formatos_Generados"),
)

# Intervalo de auto-sincronización en background (ms). 5 minutos por defecto.
OFFLINE_SYNC_INTERVAL_MS: int = int(os.getenv("PESA_SYNC_INTERVAL_MS", "300000"))


# ══════════════════════════════════════════════════════════════════════════════
# LOGGING (siempre en APP_DATA_DIR, nunca junto al binario)
# ══════════════════════════════════════════════════════════════════════════════
LOG_DIR: Path = APP_DATA_DIR / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE  = LOG_DIR / "servicios_pesa.log"
LOG_LEVEL = os.getenv("PESA_LOG_LEVEL", "INFO")


# ══════════════════════════════════════════════════════════════════════════════
# FOLIOS
# ══════════════════════════════════════════════════════════════════════════════
FOLIO_TIPOS: dict[str, str] = {
    "OS":  "Orden de Servicio",
    "RMA": "Remisión",
    "RE":  "Revisión / Revisión Externa",
    "LP":  "Levantamiento de Proyecto",
    "LV":  "Levantamiento Metrológico y Logística de Pesas",
}


# ══════════════════════════════════════════════════════════════════════════════
# INTERFAZ DE USUARIO
# ══════════════════════════════════════════════════════════════════════════════
WINDOW_MIN_WIDTH  = 900
WINDOW_MIN_HEIGHT = 700
WINDOW_TITLE      = f"{APP_NAME}  —  v{APP_VERSION}"


# ══════════════════════════════════════════════════════════════════════════════
# TABLAS DE PRUEBAS METROLÓGICAS (número de filas por defecto)
# ══════════════════════════════════════════════════════════════════════════════
DEFAULT_REPETIBILIDAD_ROWS  = 3
DEFAULT_EXCENTRICIDAD_ROWS  = 6
DEFAULT_EXACTITUD_ROWS      = 10


# ══════════════════════════════════════════════════════════════════════════════
# ESTADOS DE OS
# ══════════════════════════════════════════════════════════════════════════════
ESTADO_PROCESO   = "PROCESO"
ESTADO_CANCELADA = "CANCELADA"
ESTADO_ESCANEADA = "ESCANEADA"

ESTADOS_OS: dict[str, str] = {
    ESTADO_PROCESO:   "En Proceso",
    ESTADO_CANCELADA: "Cancelada",
    ESTADO_ESCANEADA: "Escaneada / Terminada",
}
