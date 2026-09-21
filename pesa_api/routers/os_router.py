"""
pesa_api/routers/os_router.py — CRUD de Órdenes de Servicio con filtrado RBAC.

Permisos:
  admin / logistica : ven y modifican TODAS las OS
  servicio          : solo ven sus OS asignadas (filtrado por id_tecnico)
  recepcion         : solo lectura (GET) de estado y archivo adjunto
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import FileResponse
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user, require_roles

router = APIRouter()


# ── Schemas ────────────────────────────────────────────────────────────────────

class OSListItem(BaseModel):
    folio_os:   str
    fecha:      str
    estado:     str
    modalidad:  str
    cliente:    str
    tecnico:    Optional[str]
    sync_version: int


class OSEstadoUpdate(BaseModel):
    nuevo_estado: str
    notas:        Optional[str] = None


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get(
    "/",
    response_model = list[OSListItem],
    summary        = "Listar OS con filtrado por rol",
)
async def list_os(
    estado:    Optional[str] = Query(None),
    modalidad: Optional[str] = Query(None),
    limit:     int           = Query(50, le=200),
    offset:    int           = Query(0),
    db = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Retorna OS filtradas según el rol:
    - admin/logistica: todas las OS
    - servicio: solo las asignadas al técnico vinculado al usuario
    - recepcion: todas (solo lectura)
    """
    role       = current_user["role"]
    id_tecnico = current_user.get("id_tecnico")

    # Construir filtro por rol
    extra_filter = ""
    params: list = []

    if role == "servicio":
        if not id_tecnico:
            return []
        extra_filter = "AND os.id_tecnico = $1"
        params = [id_tecnico]
    else:
        params = []

    # Filtros adicionales opcionales
    idx = len(params) + 1
    if estado:
        extra_filter += f" AND os.estado = ${idx}"
        params.append(estado)
        idx += 1
    if modalidad:
        extra_filter += f" AND os.modalidad = ${idx}"
        params.append(modalidad)
        idx += 1

    params.extend([limit, offset])
    lim_idx = idx; off_idx = idx + 1

    rows = await db.fetch(
        f"""
        SELECT os.folio_os, os.fecha::text, os.estado, os.modalidad,
               cl.razon_social AS cliente,
               tc.nombre_completo AS tecnico,
               os.sync_version
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes  cl ON os.id_cliente = cl.id
        LEFT JOIN cat_tecnicos  tc ON os.id_tecnico = tc.id
        WHERE 1=1 {extra_filter}
        ORDER BY os.fecha DESC, os.folio_os DESC
        LIMIT ${lim_idx} OFFSET ${off_idx}
        """,
        *params,
    )
    return [dict(r) for r in rows]


@router.get(
    "/{folio_os}",
    summary = "Obtener OS completa por folio",
)
async def get_os(
    folio_os:     str,
    db            = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Retorna todos los datos de una OS, con control de acceso por rol."""
    row = await db.fetchrow(
        "SELECT * FROM v_ordenes_servicio WHERE folio_os = $1", folio_os
    )
    if row is None:
        raise HTTPException(status_code=404, detail="OS no encontrada")

    # Servicio solo puede ver sus propias OS
    if (current_user["role"] == "servicio"
            and row["id_tecnico"] != current_user.get("id_tecnico")):
        raise HTTPException(status_code=403, detail="Acceso denegado a esta OS")

    return dict(row)


@router.patch(
    "/{folio_os}/estado",
    summary = "Actualizar estado de una OS (solo admin/logistica)",
)
async def update_estado(
    folio_os:     str,
    body:         OSEstadoUpdate,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "logistica")),
):
    """
    Permite a admin y logística cambiar el estado de una OS.
    Por ejemplo: FIRMADA → COMPLETADA, o cualquier OS → CANCELADA.
    """
    _ESTADOS_VALIDOS = [
        "PROCESO", "CANCELADA", "ESCANEADA",
        "ASIGNADA", "EN_CAMPO", "SYNC_PENDIENTE", "FIRMADA", "COMPLETADA",
    ]
    if body.nuevo_estado not in _ESTADOS_VALIDOS:
        raise HTTPException(status_code=400, detail=f"Estado inválido: {body.nuevo_estado!r}")

    result = await db.execute(
        """
        UPDATE ordenes_servicio SET
            estado     = $1,
            updated_at = NOW()
        WHERE folio_os = $2
        """,
        body.nuevo_estado, folio_os,
    )
    if result == "UPDATE 0":
        raise HTTPException(status_code=404, detail="OS no encontrada")

    return {"folio_os": folio_os, "nuevo_estado": body.nuevo_estado}


@router.get(
    "/{folio_os}/pdf",
    summary = "Descargar PDF de una OS (si fue subido al servidor)",
)
async def download_pdf(
    folio_os:     str,
    db            = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Busca el PDF de la OS en el directorio UPLOAD_DIR configurado en el servidor.
    Los PDFs físicos los genera la app Windows y deben subirse al servidor
    mediante el endpoint POST /api/v1/ordenes/{id}/adjunto.

    Respuestas:
      200 application/pdf  → Archivo encontrado.
      404                  → PDF no disponible en servidor (no subido aún).
    """
    # Buscar en BD el pdf_path o pdf_url registrado
    row = await db.fetchrow(
        "SELECT pdf_path, pdf_url FROM ordenes_servicio WHERE folio_os = $1",
        folio_os,
    )
    if row is None:
        raise HTTPException(
            status_code=404,
            detail=f"OS '{folio_os}' no encontrada",
        )

    # Estrategia 1: pdf_path absoluto guardado en BD
    bd_path = row.get("pdf_path")
    if bd_path and Path(bd_path).exists():
        return FileResponse(
            path=bd_path,
            media_type="application/pdf",
            filename=f"{folio_os}.pdf",
        )

    # Estrategia 2: buscar en UPLOAD_DIR por nombre de folio
    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    candidate  = Path(upload_dir) / f"{folio_os}.pdf"
    if candidate.exists():
        return FileResponse(
            path=str(candidate),
            media_type="application/pdf",
            filename=f"{folio_os}.pdf",
        )

    # Estrategia 3: pdf_url es una ruta relativa local
    pdf_url = row.get("pdf_url") or ""
    if pdf_url.startswith("/uploads/"):
        local_path = Path(upload_dir) / Path(pdf_url).name
        if local_path.exists():
            return FileResponse(
                path=str(local_path),
                media_type="application/pdf",
                filename=f"{folio_os}.pdf",
            )

    # PDF no disponible en servidor
    raise HTTPException(
        status_code=404,
        detail=(
            f"PDF de '{folio_os}' no disponible en el servidor. "
            "El PDF lo genera la app Windows. Para enviarlo a la tablet, "
            "use el botón 'Adjuntar Escaneo' desde el dashboard."
        ),
    )
