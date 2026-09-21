"""
pesa_api/main.py — Aplicación FastAPI principal para Servicios PESA v2.0.

Arranque:
    uvicorn pesa_api.main:app --host 0.0.0.0 --port 8000 --reload

Endpoints base:
    GET  /             → Healthcheck
    POST /auth/login   → JWT login
    GET  /api/v1/...   → API protegida por JWT
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from pesa_api.core.config  import settings
from pesa_api.core.database import init_db_pool, close_db_pool
from pesa_api.routers      import (
    auth, os_router, sync, equipos, entrega_semanal, catalogos,
    usuarios_router, errores_router,
)

logger = logging.getLogger("pesa_api")

# ─── Lifespan (startup / shutdown) ───────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Inicializa el pool de BD al arrancar y lo cierra al apagar."""
    env_mode = "RENDER (remoto)" if settings.DB_IS_REMOTE else "LOCAL (localhost)"
    logger.info("🚀 Servicios PESA API v2.0 iniciando — Entorno: %s", env_mode)
    logger.info("   PostgreSQL: %s:%s/%s", settings.DB_HOST, settings.DB_PORT, settings.DB_NAME)
    await init_db_pool()
    # ── Migración automática de columnas opcionales ───────────────────────────
    # Agrega columnas que pueden faltar en instalaciones antiguas de la BD.
    # ADD COLUMN IF NOT EXISTS es idempotente: no falla si ya existen.
    try:
        from pesa_api.core.database import get_pool
        async with get_pool().acquire() as conn:
            for ddl in [
                "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sync_version  INTEGER DEFAULT 1",
                "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS sync_at       TIMESTAMPTZ",
                "ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS device_id     TEXT",
            ]:
                await conn.execute(ddl)
        logger.info("✅ Migración de columnas de sync completada")
    except Exception as e:
        logger.warning("⚠️  Migración automática no pudo completarse: %s", e)
    yield
    await close_db_pool()
    logger.info("API detenida.")

# ─── Aplicación ──────────────────────────────────────────────────────────────

app = FastAPI(
    title       = "Servicios PESA API",
    description = (
        "API REST para sincronización Offline-First entre el servidor central "
        "(PostgreSQL) y las tablets Android de los técnicos de campo.\n\n"
        "**Roles RBAC:** admin · logistica · servicio · recepcion"
    ),
    version     = "2.0.0",
    docs_url    = "/docs",
    redoc_url   = "/redoc",
    lifespan    = lifespan,
)

# ─── CORS ─────────────────────────────────────────────────────────────────────
# allow_origins=["*"] permite peticiones desde cualquier origen:
# tablets Android (LAN), Render dashboard, curl, etc.
# Si necesitas restringir, agrega CORS_ORIGINS al .env o al dashboard de Render.
app.add_middleware(
    CORSMiddleware,
    allow_origins     = settings.CORS_ORIGINS,   # ["*"] — configurado en config.py
    allow_credentials = False,                    # False es obligatorio con allow_origins=["*"]
    allow_methods     = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers     = ["*"],
)

# ─── Middleware de logging ────────────────────────────────────────────────────

@app.middleware("http")
async def log_requests(request: Request, call_next):
    import time
    start = time.perf_counter()
    response = await call_next(request)
    ms = (time.perf_counter() - start) * 1000
    logger.info(
        "%s %s → %d  (%.1fms)",
        request.method, request.url.path, response.status_code, ms
    )
    return response

# ─── Manejador de errores global ─────────────────────────────────────────────

@app.exception_handler(PermissionError)
async def permission_handler(request: Request, exc: PermissionError):
    return JSONResponse(
        status_code = status.HTTP_403_FORBIDDEN,
        content     = {"detail": str(exc)},
    )

# ─── Routers ─────────────────────────────────────────────────────────────────

app.include_router(auth.router,             prefix="/auth",             tags=["Autenticación"])
app.include_router(os_router.router,        prefix="/api/v1/os",        tags=["Órdenes de Servicio"])
app.include_router(sync.router,             prefix="/api/v1/sync",      tags=["Sincronización Offline"])
app.include_router(equipos.router,          prefix="/api/v1/equipos",   tags=["Catálogo de Equipos"])
app.include_router(entrega_semanal.router,  prefix="/api/v1/entregas",  tags=["Entregas Semanales"])
# ── Catálogos y Ordenes desde Tablet ────────────────────────────────────────────
app.include_router(catalogos.router,        prefix="/api/v1",              tags=["Catálogos"])
# ── Firma de perfil del técnico + errores de campo (v3.1) ────────────────
app.include_router(usuarios_router.router,  prefix="/api/v1/usuarios",     tags=["Usuarios - Firma"])
app.include_router(errores_router.router,   prefix="/api/v1/errores-tecnicos", tags=["Errores Técnicos"])

# ─── Healthcheck ─────────────────────────────────────────────────────────────

@app.get("/", tags=["Sistema"], summary="Healthcheck")
async def root():
    """
    Verifica que la API esté funcionando.
    Retorna estado del servidor, versión y estado de la BD.
    Siempre responde HTTP 200 — incluso si PostgreSQL no está conectado.
    """
    from pesa_api.core.database import is_db_available, get_pool

    db_status = "disconnected"
    if is_db_available():
        try:
            async with get_pool().acquire() as conn:
                await conn.fetchval("SELECT 1")
            db_status = "connected"
        except Exception:
            db_status = "error"

    return {
        "service": "Servicios PESA API",
        "version": "2.0.0",
        "status":  "ok",
        "db":      db_status,
        "db_host": f"{settings.DB_HOST}:{settings.DB_PORT}/{settings.DB_NAME}",
        "docs":    "/docs",
    }
