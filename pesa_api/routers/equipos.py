"""
pesa_api/routers/equipos.py — Catálogo de equipos con búsqueda fuzzy y autocompletado.

GET /api/v1/equipos/{id_equipo}  → Datos completos del equipo por ID exacto
GET /api/v1/equipos/search?q=... → Búsqueda fuzzy en id_equipo, marca, modelo, ns
"""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user

router = APIRouter()


class EquipoResponse(BaseModel):
    id_equipo:          str
    marca:              Optional[str]
    modelo:             Optional[str]
    ns:                 Optional[str]
    tipo_instrumento:   Optional[str]
    alcance_max:        Optional[float]
    div_minima:         Optional[float]
    div_verificacion:   Optional[float]
    cliente:            Optional[str]
    ultima_os_folio:    Optional[str]
    ultima_os_fecha:    Optional[str]


@router.get(
    "/{id_equipo}",
    response_model = EquipoResponse,
    summary        = "Obtener equipo por ID (autocompletado exacto)",
)
async def get_equipo(
    id_equipo:    str,
    db            = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Retorna los datos técnicos del equipo para autocompletar el formulario de OS.
    Accesible para todos los roles autenticados.
    """
    row = await db.fetchrow(
        """
        SELECT
            ce.id_equipo, ce.marca, ce.modelo, ce.ns,
            ti.nombre        AS tipo_instrumento,
            ce.alcance_max, ce.div_minima, ce.div_verificacion,
            cl.razon_social  AS cliente,
            ce.ultima_os_folio,
            ce.ultima_os_fecha::text AS ultima_os_fecha
        FROM cat_equipos ce
        LEFT JOIN cat_tipo_instrumento ti ON ce.id_tipo_instrumento = ti.id
        LEFT JOIN cat_clientes         cl ON ce.id_cliente          = cl.id
        WHERE ce.id_equipo = $1
        """,
        id_equipo,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"Equipo {id_equipo!r} no encontrado")
    return dict(row)


@router.get(
    "/",
    response_model = list[EquipoResponse],
    summary        = "Buscar equipos (fuzzy por ID, marca, modelo, NS)",
)
async def search_equipos(
    q:     str = Query(..., min_length=2, description="Texto a buscar"),
    limit: int = Query(20, le=50),
    db            = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Búsqueda fuzzy usando pg_trgm. Busca en id_equipo, marca, modelo y ns.
    Retorna los resultados ordenados por similitud descendente.

    Mínimo 2 caracteres para activar la búsqueda.
    """
    rows = await db.fetch(
        """
        SELECT
            ce.id_equipo, ce.marca, ce.modelo, ce.ns,
            ti.nombre        AS tipo_instrumento,
            ce.alcance_max, ce.div_minima, ce.div_verificacion,
            cl.razon_social  AS cliente,
            ce.ultima_os_folio,
            ce.ultima_os_fecha::text AS ultima_os_fecha,
            GREATEST(
                similarity(ce.id_equipo, $1),
                similarity(COALESCE(ce.marca,  ''), $1),
                similarity(COALESCE(ce.modelo, ''), $1),
                similarity(COALESCE(ce.ns,     ''), $1)
            ) AS score
        FROM cat_equipos ce
        LEFT JOIN cat_tipo_instrumento ti ON ce.id_tipo_instrumento = ti.id
        LEFT JOIN cat_clientes         cl ON ce.id_cliente          = cl.id
        WHERE
            ce.id_equipo    %% $1
            OR ce.marca     %% $1
            OR ce.modelo    %% $1
            OR ce.ns        %% $1
        ORDER BY score DESC
        LIMIT $2
        """,
        q, limit,
    )
    return [dict(r) for r in rows]
