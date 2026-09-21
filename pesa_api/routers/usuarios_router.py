"""
pesa_api/routers/usuarios_router.py
Endpoints de perfil de usuario:
  PUT  /api/v1/usuarios/{id}/firma  → Guarda firma_digital (Base64 PNG) del técnico
  GET  /api/v1/usuarios/{id}/firma  → Verifica si el técnico tiene firma registrada
"""
from __future__ import annotations
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user

router = APIRouter()


class FirmaPayload(BaseModel):
    firma_digital: str   # Base64 PNG del trazo del técnico


class FirmaStatus(BaseModel):
    tiene_firma: bool
    id_tecnico: int


@router.put(
    "/{id_tecnico}/firma",
    summary="Guardar firma digital de perfil del técnico",
    response_model=FirmaStatus,
)
async def guardar_firma_tecnico(
    id_tecnico: int,
    payload: FirmaPayload,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Guarda la firma de perfil del técnico en cat_tecnicos.firma_digital.
    La firma se reutiliza en todos los PDFs que genere el técnico.
    """
    firma_b64 = (payload.firma_digital or "").strip()
    if not firma_b64:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="firma_digital no puede estar vacía.",
        )

    try:
        row = await db.fetchrow(
            "UPDATE cat_tecnicos SET firma_digital = $1 WHERE id = $2 RETURNING id",
            firma_b64, id_tecnico,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al guardar firma: {exc}",
        ) from exc

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No se encontró técnico con id={id_tecnico}.",
        )

    return FirmaStatus(tiene_firma=True, id_tecnico=id_tecnico)


@router.get(
    "/{id_tecnico}/firma",
    summary="Verificar si el técnico tiene firma digital registrada",
    response_model=FirmaStatus,
)
async def verificar_firma_tecnico(
    id_tecnico: int,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    try:
        row = await db.fetchrow(
            "SELECT COALESCE(firma_digital, '') AS firma FROM cat_tecnicos WHERE id = $1",
            id_tecnico,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al consultar firma: {exc}",
        ) from exc

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No se encontró técnico con id={id_tecnico}.",
        )

    tiene = bool((row["firma"] or "").strip())
    return FirmaStatus(tiene_firma=tiene, id_tecnico=id_tecnico)

