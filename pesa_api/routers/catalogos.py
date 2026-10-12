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

import asyncio
import os
import json
import uuid
import base64
import logging
from datetime import date
from typing import Optional, Union, List, Any

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, UploadFile, Request, status
from pydantic import BaseModel

from pesa_api.core.config import settings
from pesa_api.core.database import get_db
from pesa_api.core.security import (
    get_current_user,
    get_optional_user,
    id_tecnico_de,
    tiene_visibilidad_global,
    verificar_acceso_os,
)

logger = logging.getLogger("pesa_api.catalogos")
router = APIRouter()


# ── Schemas ────────────────────────────────────────────────────────────────────

class ClienteOut(BaseModel):
    id:           int
    nombre:       str        # alias de razon_social
    razon_social: str
    rfc:          Optional[str] = None
    telefono:     Optional[str] = None
    direccion:    Optional[str] = None
    activo:       bool = True


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
    activo: Optional[bool] = None,
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Retorna clientes registrados.
    - activo=true  → solo clientes activos (default)
    - activo=false → solo dados de baja
    - sin parámetro → todos
    """
    try:
        # CORRECCIÓN: cat_clientes NO tiene columna 'nombre', solo 'razon_social'
        where_clause = "WHERE activo = TRUE" if activo is not False else (
            "WHERE activo = FALSE" if activo is False else ""
        )
        if activo is None:
            where_clause = ""   # devolver todos (activos e inactivos)
        else:
            where_clause = f"WHERE activo = {'TRUE' if activo else 'FALSE'}"

        rows = await db.fetch(
            f"""
            SELECT id,
                   razon_social,
                   razon_social                           AS nombre,
                   COALESCE(rfc, '')                      AS rfc,
                   COALESCE(telefono, '')                 AS telefono,
                   COALESCE(direccion, '')                AS direccion,
                   activo
            FROM cat_clientes
            {where_clause}
            ORDER BY razon_social ASC
            """
        )
        return [dict(r) for r in rows]

    except Exception as exc:
        logger.error("[GET /clientes] Error al consultar cat_clientes: %s", exc)
        # Fallback defensivo: intentar la consulta mínima sin columnas opcionales
        try:
            rows_fallback = await db.fetch(
                "SELECT id, razon_social, razon_social AS nombre, activo FROM cat_clientes ORDER BY razon_social ASC"
            )
            logger.warning("[GET /clientes] Usando fallback mínimo: %d registros", len(rows_fallback))
            return [
                {"id": r["id"], "nombre": r["razon_social"], "razon_social": r["razon_social"],
                 "rfc": None, "telefono": None, "direccion": None, "activo": r["activo"]}
                for r in rows_fallback
            ]
        except Exception as exc2:
            logger.error("[GET /clientes] Fallback también falló: %s", exc2)
            raise HTTPException(
                status_code=500,
                detail=f"Error al consultar catálogo de clientes: {exc2}"
            )


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


# ── Listar Órdenes de Servicio ──────────────────────────────────────────────────

@router.get(
    "/ordenes",
    summary="Listar órdenes de servicio con parámetros opcionales tolerantes",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def get_ordenes(
    tecnico_id: Optional[str] = None,
    tecnico_nombre: Optional[str] = None,
    updated_after: Optional[str] = None,
    since: Optional[str] = None,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Retorna órdenes de servicio con filtros opcionales tolerantes.
    Filtro flexible y tolerante a mayúsculas/minúsculas y espacios.
    """
    query = """
        SELECT DISTINCT ON (os.folio_os)
            os.folio_os,
            os.id_tecnico,
            COALESCE(os.estado, 'PROCESO') AS estado,
            COALESCE(os.modalidad, 'DIGITAL') AS modalidad,
            os.fecha::text,
            os.observaciones,
            COALESCE(os.marca, '') AS marca,
            COALESCE(os.modelo, '') AS modelo,
            COALESCE(os.ns, '') AS ns,
            COALESCE(os.ns, '') AS serie,
            COALESCE(os.ubicacion, '') AS ubicacion,
            os.alcance_max,
            os.div_minima,
            os.div_verificacion,
            COALESCE(os.id_equipo::text, '') AS id_equipo,
            COALESCE(os.sync_version, 1) AS sync_version,
            COALESCE(os.updated_at, NOW()) AS updated_at,
            COALESCE(cl.razon_social, os.cliente, '') AS cliente,
            COALESCE(cl.razon_social, os.cliente, '') AS cliente_nombre,
            COALESCE(tc.nombre_completo, '') AS tecnico,
            COALESCE(tc.nombre_completo, '') AS tecnico_nombre,
            os.id_tipo_servicio,
            COALESCE(ts.nombre, '') AS tipo_servicio,
            os.sucursal_id,
            COALESCE(cs.nombre_sucursal, '') AS sucursal_nombre,
            COALESCE(os.estatus, '') AS estatus,
            COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status,
            CASE
                WHEN os.has_pdf IS TRUE
                  OR UPPER(os.modalidad) = 'FISICO'
                  OR COALESCE(os.pdf_b64,  '') <> ''
                  OR COALESCE(os.pdf_url,  '') <> ''
                  OR COALESCE(os.pdf_path, '') <> ''
                THEN TRUE
                ELSE FALSE
            END AS has_pdf,
            CASE
                WHEN UPPER(os.modalidad) = 'FISICO'
                  OR COALESCE(os.pdf_b64,  '') <> ''
                  OR COALESCE(os.pdf_url,  '') <> ''
                  OR COALESCE(os.pdf_path, '') <> ''
                THEN '/api/v1/os/' || os.folio_os || '/pdf'
                ELSE NULL
            END AS pdf_url
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
        LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
        LEFT JOIN cliente_sucursales cs ON os.sucursal_id = cs.id
        WHERE (os.estado IS NULL OR UPPER(TRIM(os.estado)) != 'CANCELADA')
    """
    params = []

    # Privacidad: un técnico solo recibe sus propias OS (mismo criterio que /sync/pull).
    if not tiene_visibilidad_global(current_user):
        mi_id = id_tecnico_de(current_user)
        if not mi_id:
            # Fail-closed: sin id de técnico no se expone papelería ajena.
            return []
        params.append(mi_id)
        query += f" AND os.id_tecnico = ${len(params)}"
        tecnico_nombre = None
        tecnico_id = None

    # Filtro flexible y tolerante a mayúsculas/minúsculas y espacios:
    if tecnico_nombre and str(tecnico_nombre).strip():
        nombre_limpio = f"%{str(tecnico_nombre).strip().lower()}%"
        params.append(nombre_limpio)
        query += f" AND (LOWER(tc.nombre_completo) LIKE ${len(params)} OR LOWER(tc.usuario) LIKE ${len(params)} OR LOWER(COALESCE(os.cliente, '')) LIKE ${len(params)})"
    elif tecnico_id and str(tecnico_id).strip().isdigit():
        params.append(int(str(tecnico_id).strip()))
        query += f" AND os.id_tecnico = ${len(params)}"

    raw_date = updated_after or since
    if raw_date and str(raw_date).strip():
        try:
            from datetime import datetime
            clean_s = str(raw_date).strip().replace("Z", "+00:00")
            dt = datetime.fromisoformat(clean_s)
            params.append(dt)
            query += f" AND os.updated_at >= ${len(params)}::timestamp"
        except Exception:
            pass

    params.append(int(settings.SYNC_MAX_BATCH_SIZE))
    query += f" ORDER BY os.folio_os DESC, os.updated_at DESC LIMIT ${len(params)}"

    try:
        rows = await db.fetch(query, *params)
        return [dict(r) for r in rows]
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[ORDENES GET ERROR] Falla al listar órdenes: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error en servidor al obtener órdenes",
        )


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

    # [SEC] Un técnico solo puede crear OS asignadas a sí mismo.
    id_tecnico_asignado = body.id_tecnico
    if not tiene_visibilidad_global(current_user):
        id_tecnico_asignado = id_tecnico_de(current_user)

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
            id_tecnico_asignado,
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

def _normalizar_modalidad(valor) -> Optional[str]:
    """'Físico'/'fisico'/'FISICO' → 'FISICO'; 'Digital' → 'DIGITAL'; otro → None."""
    if valor is None:
        return None
    v = str(valor).strip().upper().replace("Í", "I")
    if v.startswith("FISIC"):
        return "FISICO"
    if v.startswith("DIGITAL"):
        return "DIGITAL"
    return None


@router.post(
    "/ordenes/{os_id}/adjunto",
    summary="Adjuntar escaneo a una OS",
    tags=["Catálogos"],
)
async def adjuntar_escaneo(
    os_id:    int,
    folio_os: str      = Form(...),
    archivo:  UploadFile = File(...),
    modalidad: Optional[str] = Form(None),
    estatus:   Optional[str] = Form(None),
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Recibe un archivo (imagen/PDF) y lo adjunta como escaneo a la OS indicada.
    La OS se localiza PRIMERO por folio; os_id solo se usa como respaldo
    (la tablet no conoce el id del servidor). Si el archivo es PDF se guarda
    también en pdf_b64 (persistente) y se marca estatus 'Cerrado'.
    """
    clean_folio = (folio_os or "").strip()
    row = None
    if clean_folio:
        row = await db.fetchrow(
            "SELECT id, folio_os, id_tecnico FROM ordenes_servicio WHERE folio_os = $1",
            clean_folio,
        )
    if row is None and os_id and os_id > 0:
        row = await db.fetchrow(
            "SELECT id, folio_os, id_tecnico FROM ordenes_servicio WHERE id = $1",
            os_id,
        )
    if row is None:
        raise HTTPException(status_code=404, detail="Orden de servicio no encontrada")
    verificar_acceso_os(current_user, row["id_tecnico"])

    folio = row["folio_os"]
    actual_id = row["id"]

    # Guardar archivo
    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    os.makedirs(upload_dir, exist_ok=True)

    ext        = os.path.splitext(archivo.filename or "scan.jpg")[1] or ".jpg"
    filename   = f"{folio}-ESCANEADO-{uuid.uuid4().hex[:8]}{ext}"
    filepath   = os.path.join(upload_dir, filename)

    content    = await archivo.read()
    with open(filepath, "wb") as f:
        f.write(content)

    es_pdf     = ext.lower() == ".pdf" or content[:4] == b"%PDF"
    pdf_b64    = base64.b64encode(content).decode("ascii") if es_pdf else None
    modalidad_n = _normalizar_modalidad(modalidad) or "FISICO"
    estatus_n  = (estatus or "").strip() or "Cerrado"
    estado_n   = "Cerrado" if es_pdf else "ESCANEADA"

    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado       = $1,
            estatus      = $2,
            modalidad    = $3,
            pdf_url      = $4,
            pdf_b64      = COALESCE($5, pdf_b64),
            pdf_generado = CASE WHEN $5::text IS NULL THEN pdf_generado ELSE TRUE END,
            updated_at   = NOW()
        WHERE id = $6
        """,
        estado_n,
        estatus_n,
        modalidad_n,
        f"/uploads/{filename}",
        pdf_b64,
        actual_id,
    )

    return {
        "folio_os":  folio,
        "archivo":   filename,
        "estado":    estado_n,
        "estatus":   estatus_n,
        "modalidad": modalidad_n,
        "size_kb":   round(len(content) / 1024, 1),
    }


# ── Descarga de PDF de la OS ──────────────────────────────────────────────────

@router.get(
    "/ordenes/{folio}/pdf",
    summary="Descargar PDF de una OS",
    tags=["Catálogos", "Órdenes de Servicio"],
)
@router.get(
    "/ordenes/{folio}/download-pdf",
    summary="Descargar PDF de una OS (alias download-pdf)",
    tags=["Catálogos", "Órdenes de Servicio"],
)
@router.get(
    "/pdf/{folio}",
    summary="Descargar PDF vigente de una OS (alias corto, sin caché)",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def download_pdf_orden(
    folio: str,
    db=Depends(get_db),
    current_user: Optional[dict] = Depends(get_optional_user),
):
    from pesa_api.routers.os_router import download_pdf
    resp = await download_pdf(folio_os=folio, db=db, current_user=current_user)
    # Siempre la versión vigente (p. ej. tras re-estampar la firma del técnico)
    try:
        resp.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        resp.headers["Pragma"] = "no-cache"
    except Exception:
        pass
    return resp


# ── Subida directa de PDF generado desde la tablet ───────────────────────────

@router.post(
    "/ordenes/{folio}/upload-pdf",
    summary="Subir PDF generado por la tablet a Render",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def upload_pdf_tablet(
    folio: str,
    request: Request,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Recibe el archivo binario PDF generado por la tablet al finalizar el servicio.
    Soporta multipart/form-data (archivos directos) o JSON con payload base64.
    Guarda el archivo en el servidor, actualiza pdf_b64, pdf_base64, has_pdf, pdf_url y pdf_path en PostgreSQL,
    y marca la OS como COMPLETADA y SINCRONIZADA para que Windows/Mac habiliten
    de inmediato 'Ver PDF' / 'Descargar PDF'.
    """
    content: Optional[bytes] = None
    folio_os: Optional[str] = None
    os_id: Optional[int] = None
    data: Optional[str] = None
    content_type = request.headers.get("content-type", "").lower()

    correo_cliente: Optional[str] = None
    if "application/json" in content_type:
        try:
            body = await request.json()
        except Exception:
            raise HTTPException(status_code=400, detail="JSON mal formado")
        folio_os = body.get("folio") or body.get("folio_os")
        correo_cliente = body.get("correo_cliente") or body.get("email_cliente") or body.get("correo")
        if body.get("os_id"):
            try:
                os_id = int(body["os_id"])
            except Exception:
                pass
        b64_str = body.get("pdf_base64") or body.get("pdf_b64") or body.get("file_base64")
        if b64_str:
            try:
                content = base64.b64decode(b64_str.strip())
            except Exception as e_dec:
                raise HTTPException(status_code=400, detail=f"Base64 inválido: {e_dec}")
        data_val = body.get("data")
        if isinstance(data_val, dict):
            data = json.dumps(data_val)
            if not correo_cliente:
                correo_cliente = data_val.get("correo_cliente") or data_val.get("email_cliente") or data_val.get("correo")
        elif isinstance(data_val, str):
            data = data_val
    else:
        form = await request.form()
        target_file = form.get("file") or form.get("archivo")
        if target_file and hasattr(target_file, "read"):
            content = await target_file.read()
        folio_os = form.get("folio_os") or form.get("folio")
        correo_cliente = form.get("correo_cliente") or form.get("email_cliente") or form.get("correo")
        if form.get("os_id"):
            try:
                os_id = int(form.get("os_id"))
            except Exception:
                pass
        data_val = form.get("data")
        if isinstance(data_val, str):
            data = data_val
            if not correo_cliente:
                try:
                    dj = json.loads(data_val)
                    if isinstance(dj, dict):
                        correo_cliente = dj.get("correo_cliente") or dj.get("email_cliente") or dj.get("correo")
                except Exception:
                    pass

    if not content:
        raise HTTPException(status_code=400, detail="No se proporcionó ningún archivo o base64 de PDF")

    clean_folio = str(folio_os or folio).strip()
    row = await db.fetchrow(
        "SELECT id, folio_os, estado, id_tecnico FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1",
        clean_folio,
    )
    if row is None and os_id:
        row = await db.fetchrow(
            "SELECT id, folio_os, estado, id_tecnico FROM ordenes_servicio WHERE id = $1",
            os_id,
        )
    if row is None:
        raise HTTPException(status_code=404, detail=f"OS '{clean_folio}' no encontrada")
    verificar_acceso_os(current_user, row["id_tecnico"])

    actual_folio = row["folio_os"]
    actual_id = row["id"]

    upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
    os.makedirs(upload_dir, exist_ok=True)
    filename = f"{actual_folio}.pdf"
    filepath = os.path.join(upload_dir, filename)

    with open(filepath, "wb") as f:
        f.write(content)

    pdf_b64 = base64.b64encode(content).decode("ascii")

    # Actualizar estado, pdf_b64, pdf_base64, has_pdf, pdf_url y sync_status en PostgreSQL
    upd_status = await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado            = 'Cerrado',
            estatus           = 'Cerrado',
            pdf_b64           = $1,
            pdf_base64        = $1,
            pdf_url           = $2,
            pdf_path          = $3,
            pdf_descargado    = FALSE,
            pdf_generado      = TRUE,
            has_pdf           = TRUE,
            sync_check_status = 'SUBIDA_SERVIDOR',
            fecha_subida_servidor = NOW(),
            sync_status       = 'SINCRONIZADO',
            sync_version      = COALESCE(sync_version, 0) + 1,
            sync_at           = NOW(),
            updated_at        = NOW()
        WHERE id = $4
        """,
        pdf_b64,
        f"/uploads/{filename}",
        filepath,
        actual_id,
    )

    if str(upd_status or "").strip().endswith(" 0"):
        raise HTTPException(
            status_code=409,
            detail=f"OS '{actual_folio}' no se pudo actualizar en el servidor (id={actual_id})",
        )

    if data:
        # Modalidad homologada enviada por la tablet (p. ej. escaneos 'FISICO').
        try:
            modalidad_n = _normalizar_modalidad(json.loads(data).get("modalidad"))
            if modalidad_n:
                await db.execute(
                    "UPDATE ordenes_servicio SET modalidad = $1 WHERE id = $2",
                    modalidad_n, actual_id,
                )
        except Exception as e_mod:
            logger.warning("[UPLOAD-PDF] No se pudo aplicar modalidad: %s", e_mod)

    if data:
        try:
            p = json.loads(data)
            await db.execute(
                """
                UPDATE ordenes_servicio SET
                    observaciones        = COALESCE($1, observaciones),
                    dictamen             = COALESCE($2, dictamen),
                    firma_tecnico        = COALESCE($3, firma_tecnico),
                    firma_tecnico_b64    = COALESCE($3, firma_tecnico_b64),
                    firma_cliente        = COALESCE($4, firma_cliente),
                    firma_cliente_b64    = COALESCE($4, firma_cliente_b64),
                    nombre_ing           = COALESCE($5, nombre_ing),
                    puesto_ing           = COALESCE($6, puesto_ing),
                    firma_cliente_nombre = COALESCE($5, firma_cliente_nombre),
                    unidad_medida        = COALESCE($7, unidad_medida)
                WHERE id = $8
                """,
                p.get("observaciones"), p.get("dictamen"),
                p.get("firma_tecnico"), p.get("firma_cliente"),
                p.get("nombre_ing") or p.get("firma_cliente_nombre"), p.get("puesto_ing"),
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
            logger.warning("[UPLOAD-PDF] Error procesando payload JSON: %s", e_json)

    if correo_cliente and str(correo_cliente).strip():
        try:
            await db.execute(
                "UPDATE ordenes_servicio SET correo_cliente = $1 WHERE id = $2",
                str(correo_cliente).strip(), actual_id,
            )
        except Exception as e_cc:
            logger.warning("[UPLOAD-PDF] No se pudo guardar correo_cliente: %s", e_cc)

    # Disparar envío de correo vía Gmail SMTP (asíncrono tolerante a fallos)
    try:
        from pesa_api.core.email_service import enviar_email_orden
        asyncio.create_task(enviar_email_orden(None, actual_folio, correo_override=correo_cliente))
        logger.info("[UPLOAD-PDF] Envío automático de correo programado para %s", actual_folio)
    except Exception as e_mail:
        logger.warning("[UPLOAD-PDF] Error programando envío de correo: %s", e_mail)

    logger.info("[UPLOAD-PDF] PDF guardado y sincronizado para %s (%d bytes)", actual_folio, len(content))
    return {
        "ok": True,
        "folio_os": actual_folio,
        "id": actual_id,
        "size_bytes": len(content),
        "sync_status": "SINCRONIZADO",
    }


# ── Envío manual / reintento de correo electrónico ──────────────────────────

class EnviarEmailBody(BaseModel):
    correo: Optional[str] = None
    forzar: Optional[bool] = False
    folios: Optional[List[str]] = None

EnviarEmailBody.model_rebuild()


@router.post(
    "/ordenes/{folio}/enviar-email",
    summary="Enviar o reintentar el envío por correo del PDF de la orden",
    tags=["Email", "Órdenes de Servicio"],
)
@router.post("/ordenes/{folio}/enviar-correo", include_in_schema=True, tags=["Email"])
async def api_enviar_email_orden(
    folio: str,
    body: Optional[EnviarEmailBody] = Body(default=None),
    db = Depends(get_db),
    current_user: dict = Depends(get_optional_user),
):
    from pesa_api.core.email_service import enviar_email_orden
    override = body.correo if body else None
    forzar = body.forzar if body else False
    resultado = await enviar_email_orden(db, folio, correo_override=override, forzar=forzar)
    if not resultado.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo",
        )
    return resultado


@router.post(
    "/lotes/{lote_id}/enviar-email",
    summary="Enviar o reintentar el envío agrupado por correo de todas las órdenes de un lote",
    tags=["Email", "Lotes"],
)
@router.post("/lotes/{lote_id}/enviar-correo", include_in_schema=True, tags=["Email"])
async def api_enviar_email_lote(
    lote_id: str,
    body: Optional[EnviarEmailBody] = Body(default=None),
    db = Depends(get_db),
    current_user: dict = Depends(get_optional_user),
):
    from pesa_api.core.email_service import enviar_email_orden
    override = body.correo if body else None
    forzar = body.forzar if body else True
    folios_in = body.folios if (body and body.folios) else None
    if folios_in:
        folios_in = list(dict.fromkeys([str(f).strip() for f in folios_in if str(f).strip()]))

    # Si vienen folios específicos en el body, usarlos directamente para agrupar el lote
    if folios_in and len(folios_in) > 0:
        resultado = await enviar_email_orden(
            db, folios_in[0], correo_override=override, forzar=forzar, folios_lista=folios_in
        )
        if not resultado.get("ok"):
            raise HTTPException(
                status_code=400,
                detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo del lote",
            )
        return resultado

    row = await db.fetchrow(
        "SELECT folio_os FROM ordenes_servicio WHERE id_lote = $1 LIMIT 1",
        lote_id,
    )
    if not row:
        clean = lote_id.replace("LOTE-", "").strip()
        row = await db.fetchrow(
            "SELECT folio_os FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1 LIMIT 1",
            clean,
        )
    if not row:
        raise HTTPException(status_code=404, detail=f"Lote '{lote_id}' no encontrado")

    resultado = await enviar_email_orden(db, row["folio_os"], correo_override=override, forzar=forzar)
    if not resultado.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo del lote",
        )
    return resultado


class EnviarCorreoUniversalBody(BaseModel):
    folio: Optional[str] = None
    lote_id: Optional[str] = None
    correo: Optional[str] = None
    forzar: Optional[bool] = True
    folios: Optional[List[str]] = None

EnviarCorreoUniversalBody.model_rebuild()


@router.post(
    "/correos/enviar",
    summary="Endpoint universal de envío de correo (orden individual o lote)",
    tags=["Email"],
)
async def api_enviar_correo_universal(
    body: EnviarCorreoUniversalBody = Body(...),
    db = Depends(get_db),
    current_user: dict = Depends(get_optional_user),
):
    from pesa_api.core.email_service import enviar_email_orden
    forzar = True if body.forzar is None else body.forzar
    folio_ref = (body.folio or "").strip()
    folios_in = body.folios if (body.folios and len(body.folios) > 0) else None
    if folios_in:
        folios_in = list(dict.fromkeys([str(f).strip() for f in folios_in if str(f).strip()]))

    if folios_in and len(folios_in) > 0 and not folio_ref:
        folio_ref = folios_in[0].strip()

    if body.lote_id and str(body.lote_id).strip() and not folio_ref:
        lid = str(body.lote_id).strip()
        row = await db.fetchrow(
            "SELECT folio_os FROM ordenes_servicio WHERE id_lote = $1 LIMIT 1",
            lid,
        )
        if not row:
            clean = lid.replace("LOTE-", "").strip()
            row = await db.fetchrow(
                "SELECT folio_os FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1 LIMIT 1",
                clean,
            )
        if row:
            folio_ref = row["folio_os"]

    if not folio_ref:
        raise HTTPException(status_code=422, detail="Debe indicar 'folio', 'lote_id' o 'folios'")

    resultado = await enviar_email_orden(
        db, folio_ref, correo_override=body.correo, forzar=forzar, folios_lista=folios_in
    )
    if not resultado.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo",
        )
    return resultado


# ── Reset / Eliminar toma metrológica desde cero ──────────────────────────────

@router.delete(
    "/ordenes/{folio}/toma",
    summary="Eliminar lecturas metrológicas, dictamen y firmas para reiniciar orden",
    tags=["Catálogos", "Órdenes de Servicio"],
)
@router.post(
    "/ordenes/{folio}/reset-toma",
    summary="Alias POST para reiniciar orden metrológica desde cero",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def reset_toma_orden(
    folio: str,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    clean_folio = folio.strip()
    row = await db.fetchrow(
        "SELECT id, folio_os, estado, id_tecnico FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1",
        clean_folio,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"OS '{clean_folio}' no encontrada")
    verificar_acceso_os(current_user, row["id_tecnico"])

    actual_folio = row["folio_os"]
    actual_id = row["id"]

    # 1. Purgar tablas de detalle de lecturas
    await db.execute("DELETE FROM det_repetibilidad WHERE id_os = $1", actual_id)
    await db.execute("DELETE FROM det_excentricidad WHERE id_os = $1", actual_id)
    await db.execute("DELETE FROM det_exactitud WHERE id_os = $1", actual_id)

    # 2. Resetear ordenes_servicio a estado inicial 'PROCESO'
    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado               = 'PROCESO',
            estatus              = 'Proceso',
            dictamen             = NULL,
            observaciones        = NULL,
            valor_repetibilidad  = NULL,
            valor_excentricidad  = NULL,
            firma_tecnico        = NULL,
            firma_tecnico_b64    = NULL,
            firma_cliente        = NULL,
            firma_cliente_b64    = NULL,
            nombre_ing           = NULL,
            puesto_ing           = NULL,
            firma_cliente_nombre = NULL,
            pdf_b64              = NULL,
            pdf_url              = NULL,
            pdf_path             = NULL,
            pdf_generado         = FALSE,
            pdf_descargado       = FALSE,
            sync_check_status    = 'BORRADOR_LOCAL',
            fecha_cierre         = NULL,
            sync_status          = 'PENDIENTE',
            sync_version         = COALESCE(sync_version, 0) + 1,
            updated_at           = NOW()
        WHERE id = $1
        """,
        actual_id,
    )

    # 3. Eliminar archivo PDF de disco en uploads si existía
    try:
        upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
        filepath = os.path.join(upload_dir, f"{actual_folio}.pdf")
        if os.path.exists(filepath):
            os.remove(filepath)
    except Exception as e_rm:
        logger.warning("[RESET TOMA] Error al eliminar PDF de disco: %s", e_rm)

    logger.info("[RESET TOMA] Orden %s (ID %s) reiniciada desde cero exitosamente", actual_folio, actual_id)
    return {
        "ok": True,
        "folio_os": actual_folio,
        "id": actual_id,
        "estado": "PROCESO",
        "detail": "Lecturas, dictamen y firmas eliminadas. Orden reseteada a estado inicial.",
    }


# ── Catálogo Marcas y Modelos Dinámico ─────────────────────────────────────────

class MarcaModeloItem(BaseModel):
    marca:  str
    modelo: str

class MarcaModeloOut(BaseModel):
    id:     int
    marca:  str
    modelo: str

@router.get(
    "/marcas-modelos",
    response_model=list[MarcaModeloOut],
    summary="Listar marcas y modelos consolidados",
    tags=["Catálogos"],
)
async def listar_marcas_modelos(
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """Retorna todas las marcas y modelos consolidados en Render."""
    rows = await db.fetch(
        """
        SELECT id, marca, modelo
        FROM catalogo_marcas_modelos
        ORDER BY marca ASC, modelo ASC
        """
    )
    return [dict(r) for r in rows]


@router.post(
    "/marcas-modelos",
    summary="Registrar nuevas marcas y modelos",
    tags=["Catálogos"],
)
async def registrar_marcas_modelos(
    items: Union[list[MarcaModeloItem], MarcaModeloItem],
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Registra nuevas combinaciones de marca y modelo.
    Usa ON CONFLICT (marca, modelo) DO NOTHING para idempotencia.
    """
    if isinstance(items, MarcaModeloItem):
        item_list = [items]
    else:
        item_list = items

    inserted = 0
    for it in item_list:
        m = it.marca.strip()
        mod = it.modelo.strip()
        if not m or not mod:
            continue
        try:
            res = await db.execute(
                """
                INSERT INTO catalogo_marcas_modelos (marca, modelo)
                VALUES ($1, $2)
                ON CONFLICT (marca, modelo) DO NOTHING
                """,
                m, mod,
            )
            if res and "INSERT 0 1" in res:
                inserted += 1
        except Exception as e:
            logger.warning("[MARCAS-MODELOS] Error insertando (%s, %s): %s", m, mod, e)

    return {"ok": True, "recibidos": len(item_list), "insertados": inserted}

