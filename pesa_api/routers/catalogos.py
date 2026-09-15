"""
pesa_api/routers/catalogos.py — Endpoints de catálogos de la tablet PESA.

Expone:
  GET  /api/v1/clientes           → Lista de clientes (cat_clientes)
  GET  /api/v1/tecnicos           → Lista de técnicos activos (cat_tecnicos)
  GET  /api/v1/tipos-servicio     → Tipos de servicio (cat_tipo_servicio)
  GET  /api/v1/tipos-instrumento  → Tipos de instrumento (cat_tipo_instrumento)
  POST /api/v1/ordenes            → Crear nueva Orden de Servicio
  POST /api/v1/ordenes/{id}/adjunto → Adjuntar escaneo a una OS
"""
from __future__ import annotations

import os
import uuid
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user

router = APIRouter()


# ── Schemas ────────────────────────────────────────────────────────────────────

class ClienteOut(BaseModel):
    id:     int
    nombre: str
    rfc:    Optional[str] = None
    telefono: Optional[str] = None


class TecnicoOut(BaseModel):
    id:              int
    nombre_completo: str
    usuario:         str
    rol:             Optional[str] = None
    activo:          bool = True


class TipoServicioOut(BaseModel):
    id:          int
    nombre:      str
    descripcion: Optional[str] = None


class TipoInstrumentoOut(BaseModel):
    id:          int
    nombre:      str
    descripcion: Optional[str] = None


class CrearOrdenBody(BaseModel):
    tipo:                 str = "Individual"   # Individual | Lote
    modalidad:            str = "Digital"      # Digital | Físico
    id_cliente:           Optional[int] = None
    id_tecnico:           Optional[int] = None
    id_tipo_servicio:     Optional[int] = None
    id_tipo_instrumento:  Optional[int] = None
    observaciones:        Optional[str] = None
    cantidad:             int = 1              # Solo para lote


# ── Catálogos ──────────────────────────────────────────────────────────────────

@router.get(
    "/clientes",
    response_model=list[ClienteOut],
    summary="Listar clientes",
    tags=["Catálogos"],
)
async def listar_clientes(
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """Retorna todos los clientes registrados."""
    rows = await db.fetch(
        """
        SELECT id,
               COALESCE(razon_social, nombre, 'Sin nombre') AS nombre,
               rfc,
               telefono
        FROM cat_clientes
        ORDER BY nombre ASC
        """
    )
    return [dict(r) for r in rows]


@router.get(
    "/tecnicos",
    response_model=list[TecnicoOut],
    summary="Listar técnicos activos",
    tags=["Catálogos"],
)
async def listar_tecnicos(
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """Retorna los técnicos activos del sistema."""
    rows = await db.fetch(
        """
        SELECT id,
               nombre_completo,
               usuario,
               rol,
               activo
        FROM cat_tecnicos
        WHERE activo = TRUE
        ORDER BY nombre_completo ASC
        """
    )
    return [dict(r) for r in rows]


@router.get(
    "/tipos-servicio",
    response_model=list[TipoServicioOut],
    summary="Listar tipos de servicio",
    tags=["Catálogos"],
)
async def listar_tipos_servicio(
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """Retorna los tipos de servicio disponibles."""
    rows = await db.fetch(
        """
        SELECT id, nombre, descripcion
        FROM cat_tipo_servicio
        ORDER BY nombre ASC
        """
    )
    return [dict(r) for r in rows]


@router.get(
    "/tipos-instrumento",
    response_model=list[TipoInstrumentoOut],
    summary="Listar tipos de instrumento",
    tags=["Catálogos"],
)
async def listar_tipos_instrumento(
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """Retorna los tipos de instrumento disponibles."""
    # Intentar desde cat_tipo_instrumento; fallback a cat_equipos si no existe
    try:
        rows = await db.fetch(
            "SELECT id, nombre, descripcion FROM cat_tipo_instrumento ORDER BY nombre ASC"
        )
    except Exception:
        # Fallback: extraer tipos únicos desde ordenes_servicio
        rows = await db.fetch(
            """
            SELECT ROW_NUMBER() OVER (ORDER BY tipo_instrumento) AS id,
                   tipo_instrumento AS nombre,
                   NULL::text AS descripcion
            FROM (
                SELECT DISTINCT tipo_instrumento
                FROM ordenes_servicio
                WHERE tipo_instrumento IS NOT NULL
            ) t
            ORDER BY nombre ASC
            """
        )
    return [dict(r) for r in rows]


# ── Crear Orden de Servicio ────────────────────────────────────────────────────

@router.post(
    "/ordenes",
    summary="Crear nueva Orden de Servicio desde la tablet",
    tags=["Catálogos"],
    status_code=status.HTTP_201_CREATED,
)
async def crear_orden(
    body: CrearOrdenBody,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Crea una nueva OS (o lote de OS) directamente desde la tablet.
    Asigna folio autogenerado y devuelve los datos creados.
    """
    # Generar folio/s
    today = date.today()
    year_short = today.strftime("%y")

    # Obtener el siguiente número de secuencia
    seq_row = await db.fetchrow(
        """
        SELECT COALESCE(MAX(
            NULLIF(
                REGEXP_REPLACE(folio_os, '^OS-\\d+-', '', 'g'),
                ''
            )::integer
        ), 0) + 1 AS siguiente
        FROM ordenes_servicio
        WHERE folio_os LIKE $1
        """,
        f"OS-{year_short}-%"
    )
    siguiente = seq_row["siguiente"] if seq_row else 1

    cantidad = max(1, body.cantidad) if body.tipo == "Lote" else 1
    folios_creados = []

    for i in range(cantidad):
        folio = f"OS-{year_short}-{siguiente + i:03d}"
        await db.execute(
            """
            INSERT INTO ordenes_servicio (
                folio_os, estado, modalidad, fecha,
                id_cliente, id_tecnico, id_tipo_servicio,
                observaciones, sync_version, updated_at
            ) VALUES (
                $1, 'PROCESO', $2, NOW()::date,
                $3, $4, $5,
                $6, 1, NOW()
            )
            ON CONFLICT (folio_os) DO NOTHING
            """,
            folio,
            body.modalidad.upper(),
            body.id_cliente,
            body.id_tecnico,
            body.id_tipo_servicio,
            body.observaciones or "",
        )
        folios_creados.append(folio)

    return {
        "folio_os": folios_creados[0],
        "folios":   folios_creados,
        "cantidad": cantidad,
        "tipo":     body.tipo,
        "modalidad": body.modalidad,
    }


# ── Adjuntar escaneo ──────────────────────────────────────────────────────────

@router.post(
    "/ordenes/{os_id}/adjunto",
    summary="Adjuntar escaneo a una OS",
    tags=["Catálogos"],
)
async def adjuntar_escaneo(
    os_id:    int,
    folio_os: str      = Form(...),
    archivo:  UploadFile = File(...),
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Recibe un archivo (imagen/PDF) y lo adjunta como escaneo a la OS indicada.
    El archivo se guarda en el directorio /uploads/ del servidor.
    El estado de la OS se actualiza a ESCANEADA.
    """
    # Validar que la OS existe
    row = await db.fetchrow(
        "SELECT folio_os FROM ordenes_servicio WHERE id = $1 OR folio_os = $2",
        os_id, folio_os,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Orden de servicio no encontrada")

    folio = row["folio_os"]

    # Guardar archivo
    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    os.makedirs(upload_dir, exist_ok=True)

    ext        = os.path.splitext(archivo.filename or "scan.jpg")[1] or ".jpg"
    filename   = f"{folio}-ESCANEADO-{uuid.uuid4().hex[:8]}{ext}"
    filepath   = os.path.join(upload_dir, filename)

    content    = await archivo.read()
    with open(filepath, "wb") as f:
        f.write(content)

    # Actualizar estado de la OS
    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado      = 'ESCANEADA',
            pdf_url     = $1,
            updated_at  = NOW()
        WHERE folio_os = $2
        """,
        f"/uploads/{filename}",
        folio,
    )

    return {
        "folio_os": folio,
        "archivo":  filename,
        "estado":   "ESCANEADA",
        "size_kb":  round(len(content) / 1024, 1),
    }
