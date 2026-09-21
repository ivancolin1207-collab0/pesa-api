"""
pesa_api/routers/__init__.py
"""
from . import auth, sync, os_router, equipos, entrega_semanal, catalogos
from . import usuarios_router, errores_router

__all__ = [
    "auth", "sync", "os_router", "equipos", "entrega_semanal", "catalogos",
    "usuarios_router", "errores_router",
]
