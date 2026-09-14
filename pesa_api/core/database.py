"""
pesa_api/core/database.py — Pool de conexiones asyncpg para FastAPI.

Comportamiento offline-safe:
  - 3 reintentos con backoff exponencial al arrancar
  - Si PostgreSQL no está disponible, la API arranca en modo degradado
    (pool = None) y responde 503 en endpoints que requieren BD
  - El healthcheck GET / siempre responde aunque la BD no esté conectada
"""
from __future__ import annotations

import asyncio
import logging
import os
import ssl

import asyncpg
from fastapi import HTTPException, status

from pesa_api.core.config import settings

logger = logging.getLogger("pesa_api.database")

_pool: asyncpg.Pool | None = None

# ── Inicialización con reintentos ─────────────────────────────────────────────

async def init_db_pool(
    retries: int = 3,
    retry_delay: float = 2.0,
) -> None:
    """
    Intenta crear el pool de conexiones asyncpg.

    Si PostgreSQL no está disponible después de `retries` intentos,
    registra el error y deja _pool = None para que la API arranque
    en modo degradado. El endpoint GET / (healthcheck) siempre responde.
    """
    global _pool

    # ── Determinar DSN y configuración SSL ───────────────────────────────────
    database_url = os.getenv("DATABASE_URL")

    if database_url:
        # Modo Render / producción: usar DATABASE_URL
        # Normalizar el esquema legacy de Heroku/Render
        if database_url.startswith("postgres://"):
            database_url = database_url.replace("postgres://", "postgresql://", 1)

        # Determinar si es un host remoto para configurar SSL
        is_remote = ("localhost" not in database_url and "127.0.0.1" not in database_url)
        if is_remote:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ssl_cfg = ctx
        else:
            ssl_cfg = False

        logger.info(
            "Conectando a PostgreSQL mediante DATABASE_URL  [SSL=%s]",
            "ctx" if is_remote else "off",
        )

        pool_kwargs = dict(
            dsn      = database_url,
            ssl      = ssl_cfg,
            min_size = 1,
            max_size = 10,
        )
    else:
        # Modo local: usar settings (DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME)
        ssl_mode = "require" if settings.DB_IS_REMOTE else False

        logger.info(
            "Conectando a PostgreSQL → %s:%s/%s  [SSL=%s]  (usuario: %s)",
            settings.DB_HOST, settings.DB_PORT, settings.DB_NAME,
            "require" if settings.DB_IS_REMOTE else "off",
            settings.DB_USER,
        )

        pool_kwargs = dict(
            dsn      = settings.DATABASE_DSN,
            ssl      = ssl_mode,
            min_size = settings.DB_MIN_CONN,
            max_size = settings.DB_MAX_CONN,
        )

    for attempt in range(1, retries + 1):
        try:
            _pool = await asyncpg.create_pool(
                **pool_kwargs,
                timeout         = 10.0,  # segundos por intento de conexión
                command_timeout = 15.0,  # segundos por query
            )
            # Verificar que el pool realmente puede ejecutar queries
            async with _pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
            logger.info("✅ Pool de PostgreSQL listo (min=%d, max=%d)",
                        pool_kwargs["min_size"], pool_kwargs["max_size"])
            return

        except (
            asyncpg.PostgresConnectionError,
            asyncpg.CannotConnectNowError,
            OSError,                        # ConnectionRefusedError, etc.
            asyncio.TimeoutError,
        ) as exc:
            logger.warning(
                "⚠️  Intento %d/%d — No se pudo conectar a PostgreSQL: %s",
                attempt, retries, exc,
            )
            if attempt < retries:
                wait = retry_delay * (2 ** (attempt - 1))   # backoff exponencial
                logger.info("   Reintentando en %.1f segundos...", wait)
                await asyncio.sleep(wait)
            else:
                logger.error(
                    "❌ No se pudo establecer el pool de BD después de %d intentos. "
                    "La API arranca en MODO DEGRADADO — los endpoints de datos "
                    "devolverán HTTP 503 hasta que PostgreSQL esté disponible.",
                    retries,
                )
                _pool = None   # Arranque degradado — no crashear uvicorn

        except Exception as exc:
            logger.error("❌ Error inesperado al crear pool de BD: %s", exc, exc_info=True)
            _pool = None
            return


# ── Cierre ────────────────────────────────────────────────────────────────────

async def close_db_pool() -> None:
    global _pool
    if _pool:
        await _pool.close()
        _pool = None
        logger.info("Pool de PostgreSQL cerrado.")


# ── Helpers ───────────────────────────────────────────────────────────────────

def is_db_available() -> bool:
    """True si el pool está inicializado y listo para aceptar conexiones."""
    return _pool is not None


def get_pool() -> asyncpg.Pool:
    """
    Retorna el pool activo.
    Lanza RuntimeError si el pool no está disponible (uso interno).
    """
    if _pool is None:
        raise RuntimeError(
            "Pool de BD no disponible. PostgreSQL puede estar offline."
        )
    return _pool


async def get_db():
    """
    Dependency de FastAPI: retorna una conexión del pool.
    Responde HTTP 503 si el pool no está activo, en lugar de crashear.
    """
    if _pool is None:
        raise HTTPException(
            status_code = status.HTTP_503_SERVICE_UNAVAILABLE,
            detail      = (
                "Base de datos no disponible. "
                "Verifique que PostgreSQL esté activo en "
                f"{settings.DB_HOST}:{settings.DB_PORT}."
            ),
        )
    async with _pool.acquire() as conn:
        yield conn
