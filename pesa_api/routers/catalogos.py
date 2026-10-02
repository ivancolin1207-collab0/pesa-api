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
import json
import uuid
import base64
import logging
from datetime import date
from typing import Optional, Union

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user

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
            COALESCE(tc.nombre_completo, '') AS tecnico_nombre
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
        WHERE (os.estado IS NULL OR UPPER(TRIM(os.estado)) != 'CANCELADA')
    """
    params = []

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

    query += " ORDER BY os.folio_os DESC, os.updated_at DESC LIMIT 200"

    rows = await db.fetch(query, *params)
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
async def download_pdf_orden(
    folio: str,
    db=Depends(get_db),
):
    from pesa_api.routers.os_router import download_pdf
    return await download_pdf(folio_os=folio, db=db)


# ── Subida directa de PDF generado desde la tablet ───────────────────────────

@router.post(
    "/ordenes/{folio}/upload-pdf",
    summary="Subir PDF generado por la tablet a Render",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def upload_pdf_tablet(
    folio: str,
    file: Optional[UploadFile] = File(None),
    archivo: Optional[UploadFile] = File(None),
    folio_os: Optional[str] = Form(None),
    os_id: Optional[int] = Form(None),
    data: Optional[str] = Form(None),
    db=Depends(get_db),
):
    """
    Recibe el archivo binario PDF generado por la tablet al finalizar el servicio.
    Guarda el archivo en el servidor, actualiza pdf_b64, pdf_url y pdf_path en PostgreSQL,
    y marca la OS como COMPLETADA y SINCRONIZADA para que Windows habilite
    de inmediato 'Ver PDF' / 'Descargar PDF'.
    """
    target_file = file or archivo
    if not target_file:
        raise HTTPException(status_code=400, detail="No se proporcionó ningún archivo PDF")

    clean_folio = (folio_os or folio).strip()
    row = await db.fetchrow(
        "SELECT id, folio_os, estado FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1",
        clean_folio,
    )
    if row is None and os_id:
        row = await db.fetchrow(
            "SELECT id, folio_os, estado FROM ordenes_servicio WHERE id = $1",
            os_id,
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

    # Actualizar estado, pdf_b64, pdf_url y sync_status en PostgreSQL
    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estado            = 'Cerrado',
            estatus           = 'Cerrado',
            pdf_b64           = $1,
            pdf_url           = $2,
            pdf_path          = $3,
            pdf_descargado    = FALSE,
            pdf_generado      = TRUE,
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

    logger.info("[UPLOAD-PDF] PDF guardado y sincronizado para %s (%d bytes)", actual_folio, len(content))
    return {
        "ok": True,
        "folio_os": actual_folio,
        "id": actual_id,
        "size_bytes": len(content),
        "sync_status": "SINCRONIZADO",
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

