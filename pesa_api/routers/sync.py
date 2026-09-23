"""
pesa_api/routers/sync.py — Sincronización Offline-First para tablets Flutter.

Endpoints:
  GET  /api/v1/sync/pull          → Descarga OS asignadas al técnico autenticado
  POST /api/v1/sync/push          → Sube cambios del SQLite de la tablet
  POST /api/v1/sync/firmas/{folio}→ Sube las firmas digitales (PNG base64)
  GET  /api/v1/sync/folio-lock    → Reserva el siguiente folio offline

Protocolo Offline-First:
  1. Al conectar al WiFi, la tablet hace GET /sync/pull?since=<last_sync_at>
  2. Si hay cambios locales pendientes, hace POST /sync/push
  3. El servidor aplica los cambios, incrementa sync_version y retorna el nuevo estado
  4. Las firmas se suben con POST /sync/firmas/{folio}

Resolución de conflictos:
  - Si sync_version del servidor > sync_version enviado por la tablet: conflicto
  - Política: para datos metrológicos (pruebas), gana la tablet
  - Para cambios de estado administrativos (CANCELADA), gana el servidor
"""
from __future__ import annotations

import base64
import json
import logging
import traceback
from datetime import datetime, timezone
from typing   import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, field_validator

from pesa_api.core.database import get_db
from pesa_api.core.security import require_roles
from pesa_api.core.config   import settings

router = APIRouter()
logger = logging.getLogger("pesa_api.sync")


# ── Schemas ────────────────────────────────────────────────────────────────────

class OSResumen(BaseModel):
    """Resumen de OS para la lista de la tablet."""
    folio_os:       str
    estado:         str
    cliente:        str
    tecnico:        str
    fecha:          str
    sync_version:   int
    updated_at:     datetime


class OSCompleta(BaseModel):
    """OS completa para descargar a la tablet.
    Todos los campos salvo folio_os son Optional para tolerar
    órdenes físicas con columnas NULL en la BD.
    """
    folio_os:              str
    estado:                Optional[str]   = 'PROCESO'
    modalidad:             Optional[str]   = 'DIGITAL'
    fecha:                 Optional[str]   = None
    cliente:               Optional[str]   = None
    cliente_nombre:        Optional[str]   = None
    direccion_cliente:     Optional[str]   = None
    sucursal_id:           Optional[int]   = None
    sucursal_nombre:       Optional[str]   = None
    tipo_servicio:         Optional[str]   = None
    tecnico:               Optional[str]   = None
    tecnico_nombre:        Optional[str]   = None
    marca:                 Optional[str]   = None
    modelo:                Optional[str]   = None
    ns:                    Optional[str]   = None
    serie:                 Optional[str]   = None
    ubicacion:             Optional[str]   = None
    alcance_max:           Optional[float] = None
    capacidad_maxima:      Optional[float] = None
    div_minima:            Optional[float] = None
    division_minima:       Optional[float] = None
    div_verificacion:      Optional[float] = None
    id_equipo:             Optional[str]   = None
    equipo_catalogo_id:    Optional[int]   = None
    tipo_instrumento:      Optional[str]   = None
    id_tipo_instrumento:   Optional[int]   = None
    numero_cca:            Optional[str]   = None
    holograma_anterior:    Optional[str]   = None
    valor_repetibilidad:   Optional[float] = None
    valor_excentricidad:   Optional[float] = None
    clase_exactitud_codigo: Optional[str]  = None
    observaciones:         Optional[str]   = None
    aplica_excentricidad:  Optional[bool]  = True
    num_celdas_camionera:  Optional[int]   = 0
    secciones_camionera:   Optional[int]   = 0
    filas_excentricidad:   Optional[int]   = 4
    num_secciones:         Optional[int]   = 0
    instrumento_capacidad: Optional[str]   = None
    instrumento_division:  Optional[str]   = None
    datos_tecnicos_json:   Optional[str]   = '{}'
    pdf_url:               Optional[str]   = None
    # Campos Offline-First v2
    pdf_b64:               Optional[str]   = None   # PDF en Base64 subido por la tablet
    firma_tecnico_descargada: Optional[str] = None  # Firma del técnico para uso offline
    unidad_medida:         Optional[str]   = 'kg'   # kg / g / t / lb
    sync_version:          Optional[int]   = 1
    updated_at:            Optional[datetime] = None


class PushDetalle(BaseModel):
    """Detalle metrológico de una prueba (fila de la tabla)."""
    posicion_id:     int
    lectura_inicial: Optional[float] = None
    lectura_final:   Optional[float] = None
    valor_nominal:   Optional[float] = None


class PushPayload(BaseModel):
    """Payload de sincronización enviado por la tablet."""
    folio_os:           str
    device_id:          str = Field(..., description="UUID único del dispositivo tablet")
    sync_version_base:  int = Field(..., description="sync_version que tenía la tablet al empezar a editar")

    # Datos editables en campo
    observaciones:      Optional[str] = None
    valor_repetibilidad: Optional[float] = None
    valor_excentricidad: Optional[float] = None
    clase_exactitud_codigo: Optional[str] = None

    # Datos del equipo (pueden cambiar en campo)
    marca:              Optional[str] = None
    modelo:             Optional[str] = None
    ns:                 Optional[str] = None
    ubicacion:          Optional[str] = None
    id_equipo:          Optional[str] = None
    unidad_medida:      Optional[str] = None   # kg / g / t / lb

    # Vinculación a catálogo de sucursales (v13)
    sucursal_id:        Optional[int] = None
    equipo_catalogo_id: Optional[int] = None

    # Tablas de pruebas
    repetibilidad:  list[PushDetalle] = Field(default_factory=list)
    excentricidad:  list[PushDetalle] = Field(default_factory=list)
    exactitud:      list[PushDetalle] = Field(default_factory=list)

    # Estado solicitado por la tablet
    nuevo_estado:   Optional[str] = None

    # Offline-First v2: PDF + firmas digitales
    pdf_b64:              Optional[str] = None  # PDF completo en Base64
    firma_tecnico:        Optional[str] = None  # PNG firma técnico en Base64
    firma_cliente:        Optional[str] = None  # PNG firma cliente en Base64
    nombre_ing:           Optional[str] = None
    puesto_ing:           Optional[str] = None


class PushResponse(BaseModel):
    folio_os:       str
    sync_version:   int
    estado:         str
    conflicto:      bool = False
    mensaje:        str  = "Sincronización exitosa"


class FirmasPayload(BaseModel):
    firma_tecnico_png: str = Field(..., description="PNG codificado en base64")
    firma_cliente_png: str = Field(..., description="PNG codificado en base64")

    @field_validator("firma_tecnico_png", "firma_cliente_png")
    @classmethod
    def validate_base64_size(cls, v: str) -> str:
        raw_size = len(v) * 3 // 4
        if raw_size > settings.FIRMA_MAX_SIZE_BYTES:
            raise ValueError(
                f"Firma demasiado grande: {raw_size} bytes "
                f"(máximo: {settings.FIRMA_MAX_SIZE_BYTES} bytes)"
            )
        return v


class FolioLockResponse(BaseModel):
    folio:      str
    tipo:       str
    reservado:  bool = True


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get(
    "/pull",
    response_model = list[OSCompleta],
    summary        = "Descargar OS asignadas al técnico (Tablet → Servidor)",
)
async def sync_pull(
    since: datetime = Query(
        default = datetime(2000, 1, 1, tzinfo=timezone.utc),
        description = "Timestamp del último sync exitoso (ISO 8601). Se retornan solo OS modificadas después de este tiempo.",
    ),
    db          = Depends(get_db),
    current_user: dict = Depends(require_roles(
        "servicio", "tecnico", "tecnico_campo", "admin", "administrador",
        "logistica", "operativo",
    )),
):
    """
    La tablet llama a este endpoint al reconectar al WiFi.
    Retorna SOLO las OS digitales asignadas al técnico autenticado
    que hayan sido modificadas después del timestamp `since`.

    El campo `since` debe ser el `updated_at` del último pull exitoso.
    """
    id_tecnico = current_user.get("id_tecnico")
    role       = str(current_user.get("role", "")).lower().strip()
    # Admin y logística ven todo; técnicos en cualquier variante solo ven sus OS
    _ADMIN_ROLES = {"admin", "administrador", "logistica"}
    is_admin   = any(ar in role for ar in _ADMIN_ROLES) or (not id_tecnico and role not in {
        "tecnico", "tecnico_campo", "tecnico_externo", "servicio", "operativo"
    })

    # [FIX-TZ] asyncpg no puede comparar datetime aware con TIMESTAMP WITHOUT TIME ZONE
    if since.tzinfo is not None:
        since = since.astimezone(timezone.utc).replace(tzinfo=None)

    # ── SELECT blindado con COALESCE en todos los campos de texto ─────────────
    # Garantiza que ningún NULL en órdenes físicas rompa la validación Pydantic.
    _SELECT = """
        SELECT
            os.folio_os,
            COALESCE(os.estado,    'PROCESO') AS estado,
            COALESCE(os.modalidad, 'DIGITAL') AS modalidad,
            os.fecha::text,
            os.observaciones,
            COALESCE(os.marca,    '') AS marca,
            COALESCE(os.modelo,   '') AS modelo,
            COALESCE(os.ns,       '') AS ns,
            COALESCE(os.ns,       '') AS serie,
            COALESCE(os.ubicacion,'') AS ubicacion,
            os.alcance_max,
            os.alcance_max AS capacidad_maxima,
            os.div_minima,
            os.div_minima AS division_minima,
            os.div_verificacion,
            COALESCE(os.id_equipo::text, '') AS id_equipo,
            os.numero_cca, os.holograma_anterior,
            os.valor_repetibilidad, os.valor_excentricidad,
            COALESCE(os.aplica_excentricidad, true)  AS aplica_excentricidad,
            COALESCE(os.secciones_camionera,   0)    AS num_celdas_camionera,
            COALESCE(os.secciones_camionera,   0)    AS secciones_camionera,
            COALESCE(os.filas_excentricidad,   4)    AS filas_excentricidad,
            COALESCE(os.num_secciones,         0)    AS num_secciones,
            COALESCE(os.instrumento_capacidad, '')   AS instrumento_capacidad,
            COALESCE(os.instrumento_division,  '')   AS instrumento_division,
            COALESCE(os.datos_tecnicos_json,   '{}') AS datos_tecnicos_json,
            os.id_tipo_instrumento,
            COALESCE(os.sync_version, 1)            AS sync_version,
            COALESCE(os.updated_at, NOW())          AS updated_at,
            COALESCE(cl.razon_social,    '') AS cliente,
            COALESCE(cl.razon_social,    '') AS cliente_nombre,
            COALESCE(cl.direccion,       '') AS direccion_cliente,
            COALESCE(suc.nombre_sucursal, '') AS sucursal_nombre,
            -- [FIX] Preferir texto directo os.tipo_servicio si el JOIN no resuelve
            COALESCE(ts.nombre, os.tipo_servicio, '') AS tipo_servicio,
            COALESCE(tc.nombre_completo, '') AS tecnico,
            COALESCE(tc.nombre_completo, '') AS tecnico_nombre,
            ce.codigo                        AS clase_exactitud_codigo,
            COALESCE(ti.nombre,          '') AS tipo_instrumento,
            -- Offline-First v2: PDF + firma del técnico para uso offline
            NULL::text                       AS pdf_b64,
            NULL::text                       AS firma_tecnico_descargada,
            'kg'                             AS unidad_medida,
            CASE
                WHEN UPPER(os.modalidad) = 'FISICO'
                THEN '/api/v1/os/' || os.folio_os || '/pdf'
                ELSE NULL
            END AS pdf_url
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes         cl ON os.id_cliente         = cl.id
        LEFT JOIN cat_tipo_servicio    ts ON os.id_tipo_servicio    = ts.id
        LEFT JOIN cat_tecnicos         tc ON os.id_tecnico          = tc.id
        LEFT JOIN cat_clase_exactitud  ce ON os.id_clase_exactitud  = ce.id
        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
        LEFT JOIN cliente_sucursales   suc ON os.sucursal_id        = suc.id
    """

    try:
        if is_admin:
            # Admin: TODAS las OS (Física + Digital) sin filtro de técnico ni fecha
            # El admin siempre descarga el set completo para tener visión total
            rows = await db.fetch(
                _SELECT + """
                WHERE os.estado NOT IN ('CANCELADA')
                ORDER BY os.updated_at DESC
                LIMIT $1
                """,
                settings.SYNC_MAX_BATCH_SIZE,
            )
            logger.info(
                "Sync PULL [ADMIN %s]: %d OS totales (físicas + digitales)",
                current_user.get("username"), len(rows),
            )
        else:
            # Técnico: todas las órdenes asignadas por ID o por nombre
            # Trae todas las modalidades (FÍSICO, DIGITAL, HÍBRIDO) sin exclusión rígida
            username_jwt = str(current_user.get("username") or "")
            # [FIX-SYNC-PULL] Leer 'nombre_completo' (clave correcta del dict get_current_user)
            # y tambien el alias 'nombre' que ahora incluimos en el JWT y en current_user.
            nombre_jwt = (
                str(current_user.get("nombre_completo") or "")
                or str(current_user.get("nombre") or "")
                or username_jwt
            )

            # Si no hay nombre en JWT pero hay id_tecnico, obtenerlo de la BD
            if not nombre_jwt.strip() and id_tecnico:
                tec_row = await db.fetchrow(
                    "SELECT nombre_completo, usuario FROM cat_tecnicos WHERE id = $1",
                    id_tecnico,
                )
                if tec_row:
                    nombre_jwt = str(tec_row["nombre_completo"] or tec_row["usuario"] or "")

            nombre_param = f"%{nombre_jwt.strip().lower()}%" if nombre_jwt.strip() else "%"

            where_clauses = [
                """(
                    os.id_tecnico = $1
                    OR LOWER(COALESCE(tc.nombre_completo, '')) ILIKE $2
                    OR LOWER(COALESCE(tc.usuario, ''))         ILIKE $2
                )""",
                "os.estado NOT IN ('CANCELADA')",
            ]
            params = [id_tecnico or -1, nombre_param]

            if since and since.year > 2000:
                params.append(since)
                where_clauses.append(f"os.updated_at >= ${len(params)}::timestamp")

            params.append(settings.SYNC_MAX_BATCH_SIZE)
            query_sql = _SELECT + f"""
                WHERE {" AND ".join(where_clauses)}
                ORDER BY os.fecha DESC NULLS LAST, os.folio_os DESC
                LIMIT ${len(params)}
            """
            rows = await db.fetch(query_sql, *params)
            logger.info(
                "Sync PULL [TECNICO id=%s user=%s nombre=%s]: %d OS encontradas",
                id_tecnico, username_jwt, nombre_jwt, len(rows),
            )

        return [OSCompleta(**dict(r)) for r in rows]

    except HTTPException:
        raise
    except Exception as exc:
        logger.error("[SYNC PULL CRITICAL ERROR]: %s", exc)
        traceback.print_exc()
        raise HTTPException(
            status_code = status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail      = f"Error interno al generar el payload de sync: {exc}",
        )



@router.post(
    "/push",
    response_model = PushResponse,
    summary        = "Subir cambios de la tablet al servidor",
)
async def sync_push(
    payload:      PushPayload,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("servicio", "tecnico", "admin", "administrador", "logistica")),
) -> PushResponse:
    """
    La tablet envía los cambios acumulados en SQLite offline.

    Resolución de conflictos:
    - Si sync_version del servidor == payload.sync_version_base → sin conflicto, se aplica
    - Si sync_version del servidor > payload.sync_version_base → conflicto detectado
      → Para datos metrológicos: gana la tablet (campo = verdad)
      → Para estado: si servidor tiene CANCELADA/COMPLETADA, no se sobreescribe
    """
    id_tecnico = current_user.get("id_tecnico")

    # Obtener OS actual del servidor
    row = await db.fetchrow(
        """
        SELECT id, estado,
               COALESCE(sync_version, 0) AS sync_version,
               id_tecnico, id_tipo_servicio, id_clase_exactitud
        FROM ordenes_servicio
        WHERE folio_os = $1
        """,
        payload.folio_os,
    )
    if row is None:
        raise HTTPException(
            status_code = status.HTTP_404_NOT_FOUND,
            detail      = f"OS {payload.folio_os!r} no encontrada",
        )

    # Verificar que la OS pertenece al técnico autenticado
    if row["id_tecnico"] != id_tecnico:
        raise HTTPException(
            status_code = status.HTTP_403_FORBIDDEN,
            detail      = "Esta OS no está asignada a tu usuario",
        )

    os_id         = row["id"]
    server_version = row["sync_version"]
    conflicto     = server_version > payload.sync_version_base

    # Determinar estado final
    estado_protegido = row["estado"] in ("CANCELADA", "COMPLETADA")
    nuevo_estado = row["estado"]

    if not estado_protegido and payload.nuevo_estado:
        # Acepta transiciones válidas + cierre digital desde tablet
        _TRANSICIONES_VALIDAS = {
            "ASIGNADA":          ["EN_CAMPO", "COMPLETADA_DIGITAL"],
            "EN_CAMPO":          ["SYNC_PENDIENTE", "FIRMADA", "COMPLETADA_DIGITAL"],
            "SYNC_PENDIENTE":    ["EN_CAMPO", "FIRMADA", "COMPLETADA_DIGITAL"],
            "FIRMADA":           ["COMPLETADA_DIGITAL"],
            "COMPLETADA_DIGITAL": [],  # estado final desde tablet
        }
        estados_siguientes = _TRANSICIONES_VALIDAS.get(row["estado"], [])
        if payload.nuevo_estado in estados_siguientes:
            nuevo_estado = payload.nuevo_estado
        elif payload.nuevo_estado == "COMPLETADA_DIGITAL":
            # Permitir cierre siempre que no esté ya cancelada/completada por admin
            nuevo_estado = "COMPLETADA_DIGITAL"

    # Resolver clase de exactitud (si viene el código, buscar el ID)
    id_clase = row["id_clase_exactitud"]
    if payload.clase_exactitud_codigo:
        clase_row = await db.fetchrow(
            "SELECT id FROM cat_clase_exactitud WHERE codigo = $1",
            payload.clase_exactitud_codigo,
        )
        if clase_row:
            id_clase = clase_row["id"]

    # Actualizar OS en el servidor
    # [FIX] Primer intento con sync_version, sync_at, device_id, pdf_b64, unidad_medida.
    # Si alguna columna no existe (BD sin migrar), reintenta sin ellas.
    try:
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                estado                = $1,
                observaciones         = COALESCE($2, observaciones),
                valor_repetibilidad   = COALESCE($3, valor_repetibilidad),
                valor_excentricidad   = COALESCE($4, valor_excentricidad),
                id_clase_exactitud    = COALESCE($5, id_clase_exactitud),
                marca                 = COALESCE($6, marca),
                modelo                = COALESCE($7, modelo),
                ns                    = COALESCE($8, ns),
                ubicacion             = COALESCE($9, ubicacion),
                id_equipo             = COALESCE($10, id_equipo),
                pdf_b64               = COALESCE($11, pdf_b64),
                unidad_medida         = COALESCE($12, unidad_medida),
                firma_tecnico_b64     = COALESCE($13, firma_tecnico_b64),
                firma_cliente_b64     = COALESCE($14, firma_cliente_b64),
                sync_version          = COALESCE(sync_version, 0) + 1,
                sync_at               = NOW(),
                device_id             = $15,
                updated_at            = NOW()
            WHERE id = $16
            """,
            nuevo_estado,
            payload.observaciones,
            payload.valor_repetibilidad,
            payload.valor_excentricidad,
            id_clase,
            payload.marca, payload.modelo, payload.ns, payload.ubicacion,
            payload.id_equipo,
            payload.pdf_b64,        # $11
            payload.unidad_medida,  # $12
            payload.firma_tecnico,  # $13
            payload.firma_cliente,  # $14
            payload.device_id,      # $15
            os_id,                  # $16
        )
    except Exception as e_full:
        logger.warning("UPDATE con sync_version falló (%s) — reintentando sin columnas opcionales", e_full)
        # Fallback sin sync_version / sync_at / device_id (BD sin migración)
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                estado              = $1,
                observaciones       = COALESCE($2, observaciones),
                valor_repetibilidad = COALESCE($3, valor_repetibilidad),
                valor_excentricidad = COALESCE($4, valor_excentricidad),
                id_clase_exactitud  = COALESCE($5, id_clase_exactitud),
                marca               = COALESCE($6, marca),
                modelo              = COALESCE($7, modelo),
                ns                  = COALESCE($8, ns),
                ubicacion           = COALESCE($9, ubicacion),
                id_equipo           = COALESCE($10, id_equipo),
                updated_at          = NOW()
            WHERE id = $11
            """,
            nuevo_estado,
            payload.observaciones,
            payload.valor_repetibilidad,
            payload.valor_excentricidad,
            id_clase,
            payload.marca, payload.modelo, payload.ns, payload.ubicacion,
            payload.id_equipo,
            os_id,
        )

    # Upsert de pruebas metrológicas
    await _upsert_pruebas(db, os_id, payload)

    # ── Auto-registro de báscula (Modalidad DIGITAL) ──────────────────────────────
    # Si la tablet envía sucursal_id + número de serie, registramos el equipo
    # en cliente_equipos si es nuevo (UPSERT = nunca duplica).
    nuevo_equipo_id: Optional[int] = payload.equipo_catalogo_id
    if payload.sucursal_id and payload.ns:
        try:
            existing = await db.fetchrow(
                "SELECT id FROM cliente_equipos "
                "WHERE sucursal_id = $1 AND numero_serie = $2 AND activo = TRUE",
                payload.sucursal_id, payload.ns,
            )
            if existing:
                nuevo_equipo_id = existing["id"]
            else:
                # Equipo nuevo: insertar vía función SQL
                upsert_row = await db.fetchrow(
                    """
                    SELECT fn_upsert_equipo_desde_os(
                        $1, $2, $3, $4, $5, $6, NULL, NULL, NULL
                    ) AS equipo_id
                    """,
                    payload.sucursal_id,
                    payload.ns,
                    payload.marca,
                    payload.modelo,
                    payload.id_equipo,
                    payload.ubicacion,
                )
                if upsert_row:
                    nuevo_equipo_id = upsert_row["equipo_id"]
                    logger.info(
                        "Auto-registro báscula: sucursal=%d ns=%s → equipo_id=%s",
                        payload.sucursal_id, payload.ns, nuevo_equipo_id,
                    )
        except Exception as exc_eq:
            # Si la función SQL aún no existe (migración pendiente), no bloqueamos el push
            logger.warning("Auto-registro equipo: fn_upsert_equipo_desde_os no disponible (%s)", exc_eq)

    # Vincular OS al equipo y a la sucursal
    if payload.sucursal_id or nuevo_equipo_id:
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                sucursal_id        = COALESCE($1, sucursal_id),
                equipo_catalogo_id = COALESCE($2, equipo_catalogo_id)
            WHERE id = $3
            """,
            payload.sucursal_id,
            nuevo_equipo_id,
            os_id,
        )

    new_version = server_version + 1
    logger.info(
        "Sync PUSH: folio=%s device=%s estado=%s sync_v=%d conflicto=%s",
        payload.folio_os, payload.device_id, nuevo_estado, new_version, conflicto
    )

    return PushResponse(
        folio_os     = payload.folio_os,
        sync_version = new_version,
        estado       = nuevo_estado,
        conflicto    = conflicto,
        mensaje      = (
            "Sincronización exitosa (conflicto resuelto: datos de tablet aplicados)"
            if conflicto else "Sincronización exitosa"
        ),
    )


async def _upsert_pruebas(db, os_id: int, payload: PushPayload) -> None:
    """Inserta o actualiza filas de repetibilidad, excentricidad y exactitud."""
    for fila in payload.repetibilidad:
        await db.execute(
            """
            INSERT INTO det_repetibilidad (id_os, posicion_id, lectura_inicial, lectura_final)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                lectura_inicial = EXCLUDED.lectura_inicial,
                lectura_final   = EXCLUDED.lectura_final
            """,
            os_id, fila.posicion_id, fila.lectura_inicial, fila.lectura_final,
        )
    for fila in payload.excentricidad:
        await db.execute(
            """
            INSERT INTO det_excentricidad (id_os, posicion_id, lectura_inicial, lectura_final)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (id_os, posicion_id) DO UPDATE SET
                lectura_inicial = EXCLUDED.lectura_inicial,
                lectura_final   = EXCLUDED.lectura_final
            """,
            os_id, fila.posicion_id, fila.lectura_inicial, fila.lectura_final,
        )
    for fila in payload.exactitud:
        await db.execute(
            """
            INSERT INTO det_exactitud (id_os, punto_id, valor_nominal, lectura_inicial, lectura_final)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (id_os, punto_id) DO UPDATE SET
                valor_nominal   = EXCLUDED.valor_nominal,
                lectura_inicial = EXCLUDED.lectura_inicial,
                lectura_final   = EXCLUDED.lectura_final
            """,
            os_id, fila.posicion_id, fila.valor_nominal,
            fila.lectura_inicial, fila.lectura_final,
        )


@router.post(
    "/firmas/{folio_os}",
    summary = "Subir firmas digitales PNG base64 de una OS",
)
async def upload_firmas(
    folio_os:     str,
    payload:      FirmasPayload,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("servicio", "tecnico", "admin", "administrador", "logistica")),
):
    """
    Sube las firmas digitales del técnico y del cliente.
    Las firmas son PNG codificados en base64, capturadas en la tablet.
    Tamaño máximo: 500 KB por firma (suficiente para PNG de firma sobre WiFi LAN).

    Al recibir las firmas, el estado de la OS avanza automáticamente a FIRMADA.
    """
    id_tecnico = current_user.get("id_tecnico")

    row = await db.fetchrow(
        "SELECT id, id_tecnico, estado FROM ordenes_servicio WHERE folio_os = $1",
        folio_os,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"OS {folio_os!r} no encontrada")
    if row["id_tecnico"] != id_tecnico:
        raise HTTPException(status_code=403, detail="OS no asignada a este usuario")
    if row["estado"] in ("CANCELADA", "COMPLETADA"):
        raise HTTPException(status_code=400, detail=f"OS en estado {row['estado']!r}, no se pueden añadir firmas")

    # [FIX] Intenta con sync_version y sync_at; si no existen, usa fallback
    try:
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                firma_tecnico_png = $1,
                firma_cliente_png = $2,
                estado            = 'FIRMADA',
                sync_version      = COALESCE(sync_version, 0) + 1,
                sync_at           = NOW(),
                updated_at        = NOW()
            WHERE id = $3
            """,
            payload.firma_tecnico_png,
            payload.firma_cliente_png,
            row["id"],
        )
    except Exception as e_firmas:
        logger.warning("UPDATE firmas con sync_version falló (%s) — reintentando sin columnas opcionales", e_firmas)
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                firma_tecnico_png = $1,
                firma_cliente_png = $2,
                estado            = 'FIRMADA',
                updated_at        = NOW()
            WHERE id = $3
            """,
            payload.firma_tecnico_png,
            payload.firma_cliente_png,
            row["id"],
        )

    logger.info("Firmas subidas para folio=%s por tecnico_id=%d", folio_os, id_tecnico)
    return {
        "detail":       "Firmas registradas. Estado actualizado a FIRMADA.",
        "folio_os":     folio_os,
        "nuevo_estado": "FIRMADA",
    }


@router.get(
    "/folio-lock",
    response_model = FolioLockResponse,
    summary        = "Reservar el siguiente folio para uso offline",
)
async def folio_lock(
    tipo:         str         = Query(..., pattern="^(OS|RMA|RE)$"),
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("servicio", "logistica", "admin")),
) -> FolioLockResponse:
    """
    Genera y reserva el siguiente folio consecutivo para que la tablet
    pueda asignárselo a una OS creada sin conexión.

    El folio se genera con la función generate_folio() de PostgreSQL
    (atómica, sin condición de carrera).

    La tablet debe almacenar este folio en su SQLite offline y enviarlo
    en el primer push de sync.
    """
    import datetime as dt
    anio = dt.date.today().year
    folio: str = await db.fetchval(
        "SELECT generate_folio($1::CHAR(3), $2::SMALLINT)",
        tipo, anio,
    )
    logger.info(
        "Folio reservado offline: %s por usuario=%s",
        folio, current_user["username"]
    )
    return FolioLockResponse(folio=folio, tipo=tipo)
