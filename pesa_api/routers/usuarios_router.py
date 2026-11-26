"""
pesa_api/routers/usuarios_router.py
Endpoints de perfil y firma digital de usuario / técnico (paridad 1:1 Windows y Android):
  PUT/POST /api/v1/usuarios/{id_tecnico}/firma  → Guarda firma_digital (Base64 PNG) en cat_tecnicos
  GET      /api/v1/usuarios/{id_tecnico}/firma  → Obtiene firma_digital registrada
  PUT/POST /api/v1/usuarios/me/firma            → Guarda firma del usuario autenticado
  GET      /api/v1/usuarios/me/firma            → Obtiene firma del usuario autenticado
"""
from __future__ import annotations

import base64
import binascii
import json
import logging
import re
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import (
    es_rol_admin,
    get_current_user,
    id_tecnico_de,
    tiene_visibilidad_global,
)

router = APIRouter()
logger = logging.getLogger("pesa_api.usuarios")


class FirmaPayload(BaseModel):
    firma_digital: Optional[str] = None
    firma_base64:  Optional[str] = None
    firma_png:     Optional[str] = None
    firma_url:     Optional[str] = None
    firma:         Optional[str] = None


class FirmaStatus(BaseModel):
    ok:            bool = True
    tiene_firma:   bool
    id_tecnico:    int
    firma_base64:  Optional[str] = None
    firma_digital: Optional[str] = None


def _limpiar_base64_firma(raw: Any) -> str:
    s = str(raw or "").strip()
    if not s:
        return ""
    if s.startswith("data:") and "," in s:
        s = s.split(",", 1)[1].strip()
    elif "," in s and s.lower().startswith("data:image"):
        s = s.split(",", 1)[1].strip()
    s = re.sub(r"\s+", "", s)
    return s


async def _extraer_firma_de_request(request: Request) -> str:
    """
    Extrae el Base64 de la firma tolerando JSON ('application/json'),
    texto plano ('text/plain' con JSON o Base64 crudo) o multipart/form-data.
    """
    raw_bytes = await request.body()
    if not raw_bytes:
        try:
            form = await request.form()
            for key in ("firma_base64", "firma_digital", "firma_png", "firma", "firma_url"):
                val = form.get(key)
                if val and isinstance(val, str):
                    cleaned = _limpiar_base64_firma(val)
                    if cleaned:
                        return cleaned
        except Exception:
            pass
        return ""

    raw_str = raw_bytes.decode("utf-8", errors="ignore").strip()
    if not raw_str:
        return ""

    # 1. Intentar decodificar como objeto JSON (incluso si vino con Content-Type: text/plain)
    if raw_str.startswith("{") or raw_str.startswith('"'):
        try:
            parsed = json.loads(raw_str)
            if isinstance(parsed, dict):
                for key in ("firma_base64", "firma_digital", "firma_png", "firma", "firma_url"):
                    cand = _limpiar_base64_firma(parsed.get(key))
                    if cand:
                        return cand
                return ""
            if isinstance(parsed, str):
                return _limpiar_base64_firma(parsed)
        except Exception as exc_json:
            logger.warning("[USUARIOS FIRMA] Cuerpo parecia JSON pero fallo parseo: %s", exc_json)

    # 2. Fallback: tratar como cadena Base64 directa (con o sin prefijo data:image/png;base64,)
    return _limpiar_base64_firma(raw_str)


async def _resolver_id_tecnico(db, current_user: dict, requested_id: Optional[int]) -> int:
    """Resuelve el id real en cat_tecnicos del usuario objetivo validando permisos."""
    mi_id = id_tecnico_de(current_user)
    username = str(current_user.get("username") or "").strip()

    if not mi_id and username:
        row_me = await db.fetchrow(
            "SELECT id FROM cat_tecnicos WHERE LOWER(TRIM(usuario)) = LOWER(TRIM($1)) LIMIT 1",
            username,
        )
        if row_me:
            mi_id = int(row_me["id"])

    target_id = requested_id if (requested_id is not None and int(requested_id) > 0) else (mi_id or 0)
    if target_id <= 0:
        logger.warning("[USUARIOS FIRMA] No se pudo resolver id_tecnico para usuario=%r", username)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"No se pudo identificar el registro de usuario/técnico para '{username}'.",
        )

    if not (tiene_visibilidad_global(current_user) or es_rol_admin(current_user)):
        if mi_id != target_id:
            logger.warning(
                "[USUARIOS FIRMA] Permiso denegado: usuario=%r (id=%s) intento modificar/leer id=%s",
                username, mi_id, target_id,
            )
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Solo puedes administrar tu propia firma.",
            )
    return int(target_id)


async def _guardar_firma_impl(target_id: int, request: Request, db, current_user: dict) -> FirmaStatus:
    real_id = await _resolver_id_tecnico(db, current_user, target_id)
    firma_b64 = await _extraer_firma_de_request(request)

    if not firma_b64 or len(firma_b64) < 32:
        logger.warning(
            "[USUARIOS FIRMA] Firma rechazada para id=%s (len=%d, content-type=%r)",
            real_id, len(firma_b64 or ""), request.headers.get("content-type"),
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="La firma digital en Base64 está vacía o es demasiado corta.",
        )

    # Validar que sea Base64 decodificable válido (normalizando padding si falta)
    pad = (-len(firma_b64)) % 4
    if pad:
        firma_b64 = firma_b64 + ("=" * pad)
    try:
        decoded_bytes = base64.b64decode(firma_b64, validate=False)
        if len(decoded_bytes) < 32:
            raise ValueError(f"Imagen decodificada demasiado pequeña ({len(decoded_bytes)} bytes)")
    except (binascii.Error, ValueError) as exc_b64:
        logger.warning("[USUARIOS FIRMA] Base64 inválido para id=%s: %s", real_id, exc_b64)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Formato Base64 de firma inválido: {exc_b64}",
        ) from exc_b64

    try:
        row = await db.fetchrow(
            "UPDATE cat_tecnicos SET firma_digital = $1 WHERE id = $2 RETURNING id",
            firma_b64,
            real_id,
        )
        if not row:
            username = str(current_user.get("username") or "").strip()
            if username and real_id == (id_tecnico_de(current_user) or real_id):
                row = await db.fetchrow(
                    "UPDATE cat_tecnicos SET firma_digital = $1 WHERE LOWER(TRIM(usuario)) = LOWER(TRIM($2)) RETURNING id",
                    firma_b64,
                    username,
                )
                if row:
                    real_id = int(row["id"])
    except Exception as exc:
        logger.error("[USUARIOS FIRMA ERROR] Error SQL guardando firma id=%s: %s", real_id, exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error en base de datos al guardar firma: {exc}",
        ) from exc

    if not row:
        logger.warning("[USUARIOS FIRMA] No existe registro en cat_tecnicos con id=%s", real_id)
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No se encontró usuario/técnico con id={real_id} en cat_tecnicos.",
        )

    try:
        await db.execute(
            """
            UPDATE ordenes_servicio
            SET firma_tecnico_b64 = $1,
                firma_tecnico = $1,
                updated_at = NOW()
            WHERE id_tecnico = $2
              AND (estado IN ('CERRADA', 'CERRADO', 'COMPLETADA', 'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA', 'FIRMADA')
                   OR estatus IN ('Cerrado', 'CERRADO'))
            """,
            firma_b64,
            real_id,
        )
    except Exception as e_upd_os:
        logger.warning("[USUARIOS FIRMA] No se pudo propagar firma a órdenes previas de id=%s: %s", real_id, e_upd_os)

    logger.info(
        "[USUARIOS FIRMA] Firma actualizada OK en cat_tecnicos.firma_digital para id=%s (%d chars b64)",
        real_id, len(firma_b64),
    )
    return FirmaStatus(
        ok=True,
        tiene_firma=True,
        id_tecnico=real_id,
        firma_base64=firma_b64,
        firma_digital=firma_b64,
    )


async def _obtener_firma_impl(target_id: Optional[int], db, current_user: dict) -> FirmaStatus:
    real_id = await _resolver_id_tecnico(db, current_user, target_id)
    try:
        row = await db.fetchrow(
            "SELECT COALESCE(firma_digital, '') AS firma FROM cat_tecnicos WHERE id = $1 LIMIT 1",
            real_id,
        )
    except Exception as exc:
        logger.error("[USUARIOS FIRMA] Error consultando firma id=%s: %s", real_id, exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error consultando firma en base de datos: {exc}",
        ) from exc

    if not row:
        return FirmaStatus(
            ok=True,
            tiene_firma=False,
            id_tecnico=real_id,
            firma_base64=None,
            firma_digital=None,
        )

    firma = _limpiar_base64_firma(row["firma"])
    tiene = len(firma) >= 32
    return FirmaStatus(
        ok=True,
        tiene_firma=tiene,
        id_tecnico=real_id,
        firma_base64=firma if tiene else None,
        firma_digital=firma if tiene else None,
    )


@router.put("/me/firma", response_model=FirmaStatus, summary="Guardar firma del usuario actual")
@router.post("/me/firma", response_model=FirmaStatus, include_in_schema=False)
@router.put("/firma", response_model=FirmaStatus, include_in_schema=False)
@router.post("/firma", response_model=FirmaStatus, include_in_schema=False)
async def guardar_mi_firma(
    request: Request,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await _guardar_firma_impl(0, request, db, current_user)


@router.get("/me/firma", response_model=FirmaStatus, summary="Obtener firma del usuario actual")
@router.get("/firma", response_model=FirmaStatus, include_in_schema=False)
async def obtener_mi_firma(
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await _obtener_firma_impl(0, db, current_user)


@router.put(
    "/{id_tecnico}/firma",
    summary="Guardar firma digital de perfil del técnico",
    response_model=FirmaStatus,
)
@router.post(
    "/{id_tecnico}/firma",
    summary="Guardar firma digital de perfil del técnico (alias POST)",
    response_model=FirmaStatus,
)
async def guardar_firma_tecnico(
    id_tecnico: int,
    request: Request,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await _guardar_firma_impl(id_tecnico, request, db, current_user)


@router.get(
    "/{id_tecnico}/firma",
    summary="Verificar y obtener firma digital registrada del técnico",
    response_model=FirmaStatus,
)
async def verificar_firma_tecnico(
    id_tecnico: int,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await _obtener_firma_impl(id_tecnico, db, current_user)
