"""
pesa_api/routers/entrega_semanal.py — Módulo de auditoría semanal de Recepción.
"""
from __future__ import annotations

from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user, require_roles

router = APIRouter()


class EntregaCreateRequest(BaseModel):
    semana_inicio:  date
    semana_fin:     date
    id_tecnico:     int
    folios:         list[str]           # Lista de folios a incluir


class EntregaValidar(BaseModel):
    firma_recepcion_png: str
    notas:               Optional[str] = None


@router.post("/", summary="Crear acta de entrega semanal")
async def crear_entrega(
    body:         EntregaCreateRequest,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("servicio", "logistica", "admin")),
):
    """El técnico o logística generan el acta con los folios de la semana."""
    entrega_id = await db.fetchval(
        """
        INSERT INTO entregas_semanales
            (semana_inicio, semana_fin, id_tecnico, estado)
        VALUES ($1, $2, $3, 'PENDIENTE')
        ON CONFLICT (semana_inicio, id_tecnico)
            DO UPDATE SET estado = 'PENDIENTE', updated_at = NOW()
        RETURNING id
        """,
        body.semana_inicio, body.semana_fin, body.id_tecnico,
    )

    # Insertar items (folios)
    for folio in body.folios:
        row = await db.fetchrow(
            "SELECT tipo_folio FROM control_folios WHERE $1 LIKE tipo_folio || '-%' LIMIT 1",
            folio,
        )
        tipo = "OS"   # fallback
        if folio.startswith("RMA"): tipo = "RMA"
        elif folio.startswith("RE"): tipo = "RE"

        os_row = await db.fetchrow(
            "SELECT modalidad FROM ordenes_servicio WHERE folio_os = $1", folio
        )
        modalidad = os_row["modalidad"] if os_row else "FISICO"

        await db.execute(
            """
            INSERT INTO entregas_semanales_items
                (id_entrega, folio, tipo, modalidad, incluido_fisico)
            VALUES ($1, $2, $3, $4, FALSE)
            ON CONFLICT DO NOTHING
            """,
            entrega_id, folio, tipo, modalidad,
        )

    return {"id": entrega_id, "detail": "Acta de entrega creada"}


@router.put("/{entrega_id}/validar", summary="Recepción valida y firma el acta")
async def validar_entrega(
    entrega_id:   int,
    body:         EntregaValidar,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("recepcion", "admin")),
):
    """Recepción confirma la entrega y adjunta su firma digital."""
    result = await db.execute(
        """
        UPDATE entregas_semanales SET
            estado                  = 'VALIDADA',
            id_usuario_recepcion    = $1,
            firma_recepcion_png     = $2,
            notas                   = COALESCE($3, notas),
            updated_at              = NOW()
        WHERE id = $4
        """,
        current_user["id"], body.firma_recepcion_png,
        body.notas, entrega_id,
    )
    if result == "UPDATE 0":
        raise HTTPException(status_code=404, detail="Acta no encontrada")

    return {"id": entrega_id, "estado": "VALIDADA"}


@router.get("/semana/{semana_inicio}", summary="Consultar entregas de una semana")
async def get_entregas_semana(
    semana_inicio: date,
    db             = Depends(get_db),
    current_user:  dict = Depends(get_current_user),
):
    """Retorna todas las actas de una semana (para el módulo de Recepción)."""
    rows = await db.fetch(
        """
        SELECT es.id, es.semana_inicio, es.semana_fin, es.estado,
               tc.nombre_completo AS tecnico,
               (SELECT COUNT(*) FROM entregas_semanales_items ei WHERE ei.id_entrega = es.id)
                   AS total_formatos
        FROM entregas_semanales es
        JOIN cat_tecnicos tc ON es.id_tecnico = tc.id
        WHERE es.semana_inicio = $1
        ORDER BY tc.nombre_completo
        """,
        semana_inicio,
    )
    return [dict(r) for r in rows]
