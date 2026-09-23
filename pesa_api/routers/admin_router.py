"""
pesa_api/routers/admin_router.py
Endpoints de administración y mantenimiento de datos.
  POST /api/v1/admin/fix-tecnicos  → Reasigna órdenes de Alan Guevara a id_tecnico=8
  GET  /api/v1/admin/check-ordenes → Diagnóstico: cuántas órdenes tiene cada técnico
"""
from __future__ import annotations

import logging
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import require_roles

router = APIRouter()
logger = logging.getLogger("pesa_api.admin")


class FixTecnicosResponse(BaseModel):
    ordenes_actualizadas: int
    detalle: str


class DiagOrdenesRow(BaseModel):
    id_tecnico: int | None
    nombre: str
    total_ordenes: int


# ---------------------------------------------------------------------------
# POST /api/v1/admin/fix-tecnicos
# ---------------------------------------------------------------------------
@router.post(
    "/fix-tecnicos",
    response_model=FixTecnicosResponse,
    summary="Reasignar órdenes de Alan Guevara a id_tecnico=8",
)
async def fix_tecnicos(
    db=Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "administrador", "logistica")),
):
    """
    Ejecuta el UPDATE en PostgreSQL para reasignar las órdenes de Alan Guevara
    (identificadas por tecnico_texto ILIKE '%alan%' o folios conocidos) al
    id_tecnico correcto (8) en la tabla ordenes_servicio.

    Solo accesible para administradores y logística.
    """
    try:
        # 1. Reasignar por tecnico_texto que contenga 'alan'
        result_texto = await db.execute(
            """
            UPDATE ordenes_servicio
            SET id_tecnico = 8,
                updated_at  = NOW()
            WHERE id_tecnico IS NULL
               OR id_tecnico NOT IN (SELECT id FROM cat_tecnicos WHERE activo = TRUE)
            """,
        )

        # 2. Reasignar por nombre del técnico en cat_tecnicos unida
        result_nombre = await db.execute(
            """
            UPDATE ordenes_servicio os
            SET id_tecnico = tc.id,
                updated_at  = NOW()
            FROM cat_tecnicos tc
            WHERE LOWER(tc.nombre_completo) ILIKE '%alan guevara%'
              AND (
                    os.id_tecnico IS NULL
                 OR os.id_tecnico = 0
              )
            """,
        )

        # 3. Reasignar folios conocidos de Alan Guevara
        folios_alan = ['OS-26-629', 'OS-26-639', 'RMA-26-630', 'OS-26-600']
        result_folios = await db.execute(
            """
            UPDATE ordenes_servicio
            SET id_tecnico = 8,
                updated_at  = NOW()
            WHERE folio_os = ANY($1::text[])
              AND (id_tecnico IS NULL OR id_tecnico != 8)
            """,
            folios_alan,
        )

        # Extraer conteos (asyncpg retorna string "UPDATE N")
        def _parse_count(r: str) -> int:
            try:
                return int(r.split()[-1])
            except Exception:
                return 0

        total = (
            _parse_count(result_texto)
            + _parse_count(result_nombre)
            + _parse_count(result_folios)
        )

        detalle = (
            f"Por tecnico_texto/null: {_parse_count(result_texto)} | "
            f"Por nombre Alan Guevara: {_parse_count(result_nombre)} | "
            f"Por folios conocidos: {_parse_count(result_folios)}"
        )

        logger.info(
            "[ADMIN fix-tecnicos] %s — ejecutado por %s",
            detalle, current_user.get("username"),
        )
        return FixTecnicosResponse(
            ordenes_actualizadas=total,
            detalle=detalle,
        )

    except Exception as exc:
        logger.error("[ADMIN fix-tecnicos] Error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al reasignar técnicos: {exc}",
        ) from exc


# ---------------------------------------------------------------------------
# GET /api/v1/admin/check-ordenes
# ---------------------------------------------------------------------------
@router.get(
    "/check-ordenes",
    summary="Diagnóstico: conteo de órdenes por técnico",
)
async def check_ordenes(
    db=Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "administrador", "logistica")),
):
    """
    Retorna cuántas órdenes tiene asignadas cada técnico en la BD.
    Útil para verificar que el fix-tecnicos funcionó correctamente.
    """
    rows = await db.fetch(
        """
        SELECT
            os.id_tecnico,
            COALESCE(tc.nombre_completo, 'SIN TÉCNICO') AS nombre,
            COUNT(os.id) AS total_ordenes
        FROM ordenes_servicio os
        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
        WHERE os.estado NOT IN ('CANCELADA')
        GROUP BY os.id_tecnico, tc.nombre_completo
        ORDER BY total_ordenes DESC
        """,
    )
    return [dict(r) for r in rows]
