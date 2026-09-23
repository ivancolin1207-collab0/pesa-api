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
    summary="Reasignar órdenes de Alan Guevara (id=8) — solo las suyas",
)
async def fix_tecnicos(
    db=Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "administrador", "logistica")),
):
    """
    Vincula al id_tecnico=8 (Alan Guevara / Daikki19) todas las órdenes que:
      1. Tienen id_tecnico que apunta a cat_tecnicos.nombre_completo ILIKE '%alan guevara%'
      2. Tienen id_tecnico = NULL o 0 Y folio_os >= 'OS-26-550' (periodo probable)
      3. Están en la lista de folios conocidos de Alan Guevara

    Solo accesible para administradores y logística.
    """
    try:
        # 1. Reasignar por nombre en cat_tecnicos que contenga 'alan guevara'
        #    (cubre el caso donde el id_tecnico apunta a un registro diferente
        #     pero el nombre en cat_tecnicos es de Alan)
        result_nombre = await db.execute(
            """
            UPDATE ordenes_servicio os
            SET id_tecnico = 8,
                updated_at  = NOW()
            FROM cat_tecnicos tc
            WHERE tc.id = os.id_tecnico
              AND LOWER(tc.nombre_completo) ILIKE '%alan%'
              AND os.id_tecnico != 8
            """,
        )

        # 2. Reasignar por folios conocidos / rango de folio de Alan Guevara
        #    OS-26-550 en adelante que tengan id_tecnico NULL o 0
        result_null = await db.execute(
            """
            UPDATE ordenes_servicio
            SET id_tecnico = 8,
                updated_at  = NOW()
            WHERE (id_tecnico IS NULL OR id_tecnico = 0)
              AND (
                folio_os >= 'OS-26-550'
                OR folio_os LIKE 'OS-26-6%'
                OR folio_os LIKE 'OS-26-7%'
              )
            """,
        )

        # 3. Folios específicos asignados a Alan Guevara manualmente
        folios_alan = [
            'OS-26-550', 'OS-26-551', 'OS-26-552', 'OS-26-553', 'OS-26-554',
            'OS-26-555', 'OS-26-600', 'OS-26-601', 'OS-26-602', 'OS-26-610',
            'OS-26-620', 'OS-26-629', 'OS-26-630', 'OS-26-639', 'OS-26-640',
            'OS-26-641', 'OS-26-642', 'OS-26-643', 'OS-26-644', 'OS-26-645',
            'RMA-26-630',
        ]
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

        # Contar OS finales asignadas a id=8
        total_alan = await db.fetchval(
            "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico = 8 AND UPPER(TRIM(COALESCE(estado,''))) != 'CANCELADA'"
        )

        def _parse_count(r: str) -> int:
            try:
                return int(r.split()[-1])
            except Exception:
                return 0

        actualizadas = (
            _parse_count(result_nombre)
            + _parse_count(result_null)
            + _parse_count(result_folios)
        )

        detalle = (
            f"Por nombre alan en cat_tecnicos: {_parse_count(result_nombre)} | "
            f"Por folio>=OS-26-550 sin técnico: {_parse_count(result_null)} | "
            f"Por folios específicos: {_parse_count(result_folios)} | "
            f"Total OS activas de Alan (id=8): {total_alan}"
        )

        logger.info(
            "[ADMIN fix-tecnicos] %s — ejecutado por %s",
            detalle, current_user.get("username"),
        )
        print(f"[ADMIN fix-tecnicos] {detalle}")

        return FixTecnicosResponse(
            ordenes_actualizadas=actualizadas,
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
