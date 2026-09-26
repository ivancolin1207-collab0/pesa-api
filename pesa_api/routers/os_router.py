"""
pesa_api/routers/os_router.py — CRUD de Órdenes de Servicio con filtrado RBAC.

Permisos:
  admin / logistica : ven y modifican TODAS las OS
  servicio          : solo ven sus OS asignadas (filtrado por id_tecnico)
  recepcion         : solo lectura (GET) de estado y archivo adjunto
"""
from __future__ import annotations

import os
import json
import base64
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, File, Form, UploadFile, status
from fastapi.responses import FileResponse, Response
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
    summary = "Descargar PDF de una OS (si fue subido al servidor o guardado en BD)",
)
@router.get(
    "/{folio_os}/download-pdf",
    summary = "Descargar PDF de una OS (alias download-pdf)",
)
async def download_pdf(
    folio_os:     str,
    db            = Depends(get_db),
):
    """
    Busca el PDF de la OS en el directorio UPLOAD_DIR o lo reconstruye desde pdf_b64 en PostgreSQL.
    Permite descarga directa tanto para la app de Windows como para navegadores.
    """
    row = await db.fetchrow(
        "SELECT pdf_path, pdf_url, pdf_b64 FROM ordenes_servicio WHERE folio_os = $1",
        folio_os.strip(),
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

    # Estrategia 4: Reconstruir desde pdf_b64 almacenado en PostgreSQL
    pdf_b64 = row.get("pdf_b64")
    if pdf_b64:
        try:
            pdf_bytes = base64.b64decode(pdf_b64)
            # Guardar en UPLOAD_DIR para acelerar siguientes peticiones
            try:
                os.makedirs(upload_dir, exist_ok=True)
                with open(str(candidate), "wb") as f_out:
                    f_out.write(pdf_bytes)
            except Exception:
                pass
            return Response(
                content=pdf_bytes,
                media_type="application/pdf",
                headers={
                    "Content-Disposition": f'inline; filename="{folio_os}.pdf"'
                },
            )
        except Exception as e:
            pass

    # PDF no disponible en servidor
    raise HTTPException(
        status_code=404,
        detail=f"PDF de '{folio_os}' no disponible en el servidor. El técnico aún no ha finalizado o sincronizado el documento.",
    )


@router.post(
    "/{folio_os}/upload-pdf",
    summary="Subir PDF generado por la tablet a Render",
)
async def upload_pdf_tablet_os(
    folio_os: str,
    file: Optional[UploadFile] = File(None),
    archivo: Optional[UploadFile] = File(None),
    folio: Optional[str] = Form(None),
    data: Optional[str] = Form(None),
    db=Depends(get_db),
):
    target_file = file or archivo
    if not target_file:
        raise HTTPException(status_code=400, detail="No se proporcionó ningún archivo PDF")

    clean_folio = (folio or folio_os).strip()
    row = await db.fetchrow(
        "SELECT id, folio_os, estado FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1",
        clean_folio,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"OS '{clean_folio}' no encontrada")

    actual_folio = row["folio_os"]
    actual_id = row["id"]

    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    os.makedirs(upload_dir, exist_ok=True)
    filename = f"{actual_folio}.pdf"
    filepath = os.path.join(upload_dir, filename)

    content = await target_file.read()
    with open(filepath, "wb") as f:
        f.write(content)

    pdf_b64 = base64.b64encode(content).decode("ascii")

    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado         = 'COMPLETADA',
            pdf_b64        = $1,
            pdf_url        = $2,
            pdf_path       = $3,
            pdf_descargado = FALSE,
            sync_status    = 'SINCRONIZADO',
            sync_version   = COALESCE(sync_version, 0) + 1,
            sync_at        = NOW(),
            updated_at     = NOW()
        WHERE id = $4
        """,
        pdf_b64,
        f"/uploads/{filename}",
        filepath,
        actual_id,
    )

    if data:
        try:
            p = json.loads(data)
            await db.execute(
                """
                UPDATE ordenes_servicio SET
                    observaciones     = COALESCE($1, observaciones),
                    dictamen          = COALESCE($2, dictamen),
                    firma_tecnico_b64 = COALESCE($3, firma_tecnico_b64),
                    firma_cliente_b64 = COALESCE($4, firma_cliente_b64),
                    nombre_ing        = COALESCE($5, nombre_ing),
                    puesto_ing        = COALESCE($6, puesto_ing),
                    unidad_medida     = COALESCE($7, unidad_medida)
                WHERE id = $8
                """,
                p.get("observaciones"), p.get("dictamen"),
                p.get("firma_tecnico"), p.get("firma_cliente"),
                p.get("nombre_ing"), p.get("puesto_ing"),
                p.get("unidad_medida"), actual_id,
            )
            for idx, r in enumerate(p.get("rep_rows", [])):
                pid = r.get("posicion_id") or (idx + 1)
                await db.execute(
                    """
                    INSERT INTO det_repetibilidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                    """,
                    actual_id, int(pid),
                    float(r["lectura_inicial"]) if r.get("lectura_inicial") is not None else None,
                    float(r["lectura_final"]) if r.get("lectura_final") is not None else None,
                )
            for idx, r in enumerate(p.get("exc_rows", [])):
                pid = r.get("posicion_id") or (idx + 1)
                await db.execute(
                    """
                    INSERT INTO det_excentricidad (id_os, posicion_id, lectura_inicial, lectura_final)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                    """,
                    actual_id, int(pid),
                    float(r["lectura_inicial"]) if r.get("lectura_inicial") is not None else None,
                    float(r["lectura_final"]) if r.get("lectura_final") is not None else None,
                )
            for idx, r in enumerate(p.get("exac_rows", [])):
                pid = r.get("punto_id") or r.get("posicion_id") or (idx + 1)
                await db.execute(
                    """
                    INSERT INTO det_exactitud (id_os, punto_id, valor_nominal, lectura_inicial, lectura_final)
                    VALUES ($1, $2, $3, $4, $5)
                    ON CONFLICT (id_os, punto_id) DO UPDATE SET
                        valor_nominal   = EXCLUDED.valor_nominal,
                        lectura_inicial = EXCLUDED.lectura_inicial,
                        lectura_final   = EXCLUDED.lectura_final
                    """,
                    actual_id, int(pid),
                    float(r["valor_nominal"]) if r.get("valor_nominal") is not None else None,
                    float(r["lectura_inicial"]) if r.get("lectura_inicial") is not None else None,
                    float(r["lectura_final"]) if r.get("lectura_final") is not None else None,
                )
        except Exception as e_json:
            pass

    return {
        "ok": True,
        "folio_os": actual_folio,
        "id": actual_id,
        "size_bytes": len(content),
        "sync_status": "SINCRONIZADO",
    }

