"""
pesa_api/routers/ordenes.py — Router compatible para /api/v1/ordenes
Provee endpoints de órdenes de servicio tolerantes a parámetros opcionales.
"""
from __future__ import annotations
from typing import Optional
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user
from pesa_api.routers.catalogos import get_ordenes

router = APIRouter()

@router.get("", summary="Listar órdenes de servicio", tags=["Órdenes de Servicio"])
@router.get("/", include_in_schema=False)
async def list_ordenes_endpoint(
    tecnico_id: Optional[str] = Query(None),
    tecnico_nombre: Optional[str] = Query(None),
    updated_after: Optional[str] = Query(None),
    since: Optional[str] = Query(None),
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await get_ordenes(
        tecnico_id=tecnico_id,
        tecnico_nombre=tecnico_nombre,
        updated_after=updated_after,
        since=since,
        db=db,
        current_user=current_user,
    )
