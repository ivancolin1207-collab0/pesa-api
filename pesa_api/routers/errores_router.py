"""
pesa_api/routers/errores_router.py
Endpoints para registro de errores técnicos desde la Tablet:
  POST /api/v1/errores-tecnicos      → Registra un incidente de captura digital fallida
  GET  /api/v1/errores-tecnicos      → Lista errores no resueltos (admin)
  PUT  /api/v1/errores-tecnicos/{id} → Marcar como resuelto
"""
from __future__ import annotations
from typing import Optional
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user

router = APIRouter()


class ErrorTecnicoPayload(BaseModel):
    folio:          Optional[str] = None
    tecnico:        Optional[str] = None
    error_mensaje:  str
    stack_trace:    Optional[str] = None
    dispositivo:    Optional[str] = "Tablet Android"


class ErrorTecnicoResponse(BaseModel):
    id:             int
    folio:          Optional[str]
    tecnico:        Optional[str]
    error_mensaje:  str
    dispositivo:    Optional[str]
    fecha:          Optional[datetime]
    resuelto:       bool


@router.post(
    "",
    summary="Registrar error técnico desde Tablet",
    response_model=ErrorTecnicoResponse,
    status_code=status.HTTP_201_CREATED,
)
def registrar_error_tecnico(
    payload: ErrorTecnicoPayload,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Registra un incidente cuando falla la captura digital en campo.
    Visible en el Dashboard de Windows para auditoría.
    """
    try:
        with db.cursor() as cur:
            cur.execute(
                """
                INSERT INTO registro_errores_tecnicos
                    (folio, tecnico, error_mensaje, stack_trace, dispositivo)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id, folio, tecnico, error_mensaje, dispositivo, fecha, resuelto
                """,
                (
                    payload.folio,
                    payload.tecnico,
                    payload.error_mensaje,
                    payload.stack_trace,
                    payload.dispositivo or "Tablet Android",
                ),
            )
            row = cur.fetchone()
        db.commit()
    except Exception as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al registrar incidente: {exc}",
        ) from exc

    return ErrorTecnicoResponse(**dict(row))


@router.get(
    "",
    summary="Listar errores técnicos pendientes (admin)",
    response_model=list[ErrorTecnicoResponse],
)
def listar_errores_tecnicos(
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    try:
        with db.cursor() as cur:
            cur.execute(
                """
                SELECT id, folio, tecnico, error_mensaje, dispositivo, fecha, resuelto
                FROM registro_errores_tecnicos
                WHERE resuelto = FALSE
                ORDER BY fecha DESC
                LIMIT 200
                """
            )
            rows = cur.fetchall()
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al consultar: {exc}",
        ) from exc

    return [ErrorTecnicoResponse(**dict(r)) for r in rows]


@router.put(
    "/{error_id}/resolver",
    summary="Marcar error técnico como resuelto",
    response_model=ErrorTecnicoResponse,
)
def resolver_error_tecnico(
    error_id: int,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    try:
        with db.cursor() as cur:
            cur.execute(
                """
                UPDATE registro_errores_tecnicos
                SET resuelto = TRUE
                WHERE id = %s
                RETURNING id, folio, tecnico, error_mensaje, dispositivo, fecha, resuelto
                """,
                (error_id,),
            )
            row = cur.fetchone()
        db.commit()
    except Exception as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al actualizar: {exc}",
        ) from exc

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Error id={error_id} no encontrado.",
        )

    return ErrorTecnicoResponse(**dict(row))
