"""
pesa_api/core/config.py — Configuración centralizada de la API.

Compatibilidad de entornos:
  - LOCAL:  lee pesa_api/.env (variables PESA_DB_*) vía find_dotenv()
  - RENDER: lee DATABASE_URL inyectada automáticamente por la plataforma
            (formato postgres:// o postgresql://) y la descompone en
            componentes individuales para compatibilidad con asyncpg.
"""
from __future__ import annotations

import os
from typing import List
from urllib.parse import urlparse

from dotenv import load_dotenv, find_dotenv

# ── Carga de .env (solo en local; en Render las vars vienen del dashboard) ────
_dotenv_path = find_dotenv(filename=".env", raise_error_if_not_found=False, usecwd=False)
if _dotenv_path:
    load_dotenv(_dotenv_path, override=False)
else:
    load_dotenv(override=False)


def _parse_database_url(url: str) -> dict:
    """
    Parsea DATABASE_URL de Render al formato que necesita asyncpg.

    Render puede entregar:
      - postgres://user:pass@host:port/db      (legacy scheme)
      - postgresql://user:pass@host:port/db    (standard)

    asyncpg sólo acepta postgresql://. SQLAlchemy usaría postgresql+asyncpg://.
    Esta función normaliza el scheme y extrae los componentes individuales.
    """
    # Normalizar scheme: postgres:// → postgresql://
    normalized = url.replace("postgres://", "postgresql://", 1)
    # Quitar "+asyncpg" si ya viene con driver explícito (SQLAlchemy style)
    normalized = normalized.replace("postgresql+asyncpg://", "postgresql://", 1)

    parsed = urlparse(normalized)
    return {
        "dsn":      normalized,
        "host":     parsed.hostname or "127.0.0.1",
        "port":     parsed.port    or 5432,
        "database": (parsed.path or "/servicios_pesa").lstrip("/"),
        "user":     parsed.username or "pesa_app",
        "password": parsed.password or "",
    }


def _is_remote_host(host: str) -> bool:
    """True si el host NO es localhost → aplicar SSL requerido (Render)."""
    return host not in ("127.0.0.1", "localhost", "::1", "0.0.0.0")


# ── Resolución unificada de configuración de BD ───────────────────────────────
_db_url_raw = os.getenv("DATABASE_URL", "")

if _db_url_raw:
    # ── Modo Render: DATABASE_URL presente ───────────────────────────────────
    _db = _parse_database_url(_db_url_raw)
    _DB_HOST     = _db["host"]
    _DB_PORT     = _db["port"]
    _DB_NAME     = _db["database"]
    _DB_USER     = _db["user"]
    _DB_PASSWORD = _db["password"]
    _DB_DSN      = _db["dsn"]
else:
    # ── Modo local: variables PESA_DB_* ──────────────────────────────────────
    _DB_HOST     = os.getenv("PESA_DB_HOST",     "127.0.0.1")
    _DB_PORT     = int(os.getenv("PESA_DB_PORT", "5432"))
    _DB_NAME     = os.getenv("PESA_DB_NAME",     "servicios_pesa")
    _DB_USER     = os.getenv("PESA_DB_USER",     "pesa_app")
    _DB_PASSWORD = os.getenv("PESA_DB_PASSWORD", "")  # nunca hardcodear
    _DB_DSN      = (
        f"postgresql://{_DB_USER}:{_DB_PASSWORD}"
        f"@{_DB_HOST}:{_DB_PORT}/{_DB_NAME}"
    )

_DB_IS_REMOTE = _is_remote_host(_DB_HOST)


class Settings:
    # ── Base de datos ─────────────────────────────────────────────────────────
    # Estos atributos reflejan el origen resuelto (DATABASE_URL o PESA_DB_*)
    # y son de sólo lectura — no se reasignan en runtime.
    DB_HOST:     str = _DB_HOST
    DB_PORT:     int = _DB_PORT
    DB_NAME:     str = _DB_NAME
    DB_USER:     str = _DB_USER
    DB_PASSWORD: str = _DB_PASSWORD
    DB_IS_REMOTE: bool = _DB_IS_REMOTE   # True → SSL requerido (Render)

    DB_MIN_CONN: int = int(os.getenv("PESA_DB_MIN_CONN", "2"))
    DB_MAX_CONN: int = int(os.getenv("PESA_DB_MAX_CONN", "10"))

    @property
    def DATABASE_DSN(self) -> str:
        """DSN listo para asyncpg.create_pool(dsn=...). Scheme = postgresql://"""
        return _DB_DSN

    # ── JWT ───────────────────────────────────────────────────────────────────
    SECRET_KEY:                  str = (os.getenv("PESA_JWT_SECRET") or "CAMBIAR-EN-PRODUCCION-secret-pesa-2026").strip()
    JWT_SECRET:                  str = SECRET_KEY
    JWT_ALGORITHM:               str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 * 365  # 365 días para tablets de campo
    JWT_EXPIRE_MINUTES:          int = max(int(os.getenv("PESA_JWT_EXPIRE_MINUTES", str(60 * 24 * 365))), 60 * 24 * 365)
    REFRESH_EXPIRE_DAYS:         int = max(int(os.getenv("PESA_REFRESH_EXPIRE_DAYS", "365")), 365)

    # ── CORS ──────────────────────────────────────────────────────────────────
    # "*" permite peticiones desde la tablet Android (HTTP/HTTPS, cualquier IP).
    # En producción restringida, reemplaza "*" por las IPs/dominios reales.
    CORS_ORIGINS: List[str] = ["*"]

    # ── Archivos ──────────────────────────────────────────────────────────────
    FILES_BASE_DIR: str = os.getenv("PESA_FILES_PATH", "/tmp/pesa_files")

    # ── Sincronización ────────────────────────────────────────────────────────
    SYNC_MAX_BATCH_SIZE:  int = 1000  # ampliado para asegurar todas las órdenes activas
    FIRMA_MAX_SIZE_BYTES: int = 500_000

    # ── Logging ───────────────────────────────────────────────────────────────
    LOG_LEVEL: str = os.getenv("PESA_LOG_LEVEL", "INFO")

    # ── SMTP Gmail ────────────────────────────────────────────────────────────
    SMTP_HOST:  str = os.getenv("SMTP_HOST", "smtp.gmail.com")
    SMTP_PORT:  int = int(os.getenv("SMTP_PORT", "587"))
    EMAIL_USER: str = os.getenv("EMAIL_USER", os.getenv("SMTP_USER", "ivancolin1207@gmail.com"))
    EMAIL_PASS: str = os.getenv("EMAIL_PASS", os.getenv("SMTP_PASS", "kqavslorcqmepzww"))
    EMAIL_CC:   str = os.getenv("EMAIL_CC", os.getenv("SMTP_CC", "recepcion@basculaspesa.com.mx"))


settings = Settings()
