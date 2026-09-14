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
from datetime import datetime, timezone
from typing import Optional

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
    """OS completa para descargar a la tablet."""
    folio_os:           str
    estado:             str
    modalidad:          str
    fecha:              str
    cliente:            str
    direccion_cliente:  str
    sucursal_id:        Optional[int]   = None
    sucursal_nombre:    Optional[str]   = None
    tipo_servicio:      str
    marca:              Optional[str]   = None
    modelo:             Optional[str]   = None
    ns:                 Optional[str]   = None
    ubicacion:          Optional[str]   = None
    alcance_max:        Optional[float] = None
    div_minima:         Optional[float] = None
    div_verificacion:   Optional[float] = None
    id_equipo:          Optional[str]   = None
    equipo_catalogo_id: Optional[int]   = None
    tipo_instrumento:   Optional[str]   = None
    numero_cca:         Optional[str]   = None
    holograma_anterior: Optional[str]   = None
    valor_repetibilidad: Optional[float] = None
    valor_excentricidad: Optional[float] = None
    clase_exactitud_codigo: Optional[str] = None
    observaciones:      Optional[str]   = None
    sync_version:       int
    updated_at:         datetime


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

    # Vinculación a catálogo de sucursales (v13)
    sucursal_id:        Optional[int] = None  # ID de la sucursal/planta del cliente
    equipo_catalogo_id: Optional[int] = None  # ID equipo en cliente_equipos (si ya existía)

    # Tablas de pruebas
    repetibilidad:  list[PushDetalle] = Field(default_factory=list)
    excentricidad:  list[PushDetalle] = Field(default_factory=list)
    exactitud:      list[PushDetalle] = Field(default_factory=list)

    # Estado solicitado por la tablet
    nuevo_estado:   Optional[str] = None


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
    current_user: dict = Depends(require_roles("servicio")),
):
    """
    La tablet llama a este endpoint al reconectar al WiFi.
    Retorna SOLO las OS digitales asignadas al técnico autenticado
    que hayan sido modificadas después del timestamp `since`.

    El campo `since` debe ser el `updated_at` del último pull exitoso.
    """
    id_tecnico = current_user.get("id_tecnico")
    if not id_tecnico:
        raise HTTPException(
            status_code = status.HTTP_400_BAD_REQUEST,
            detail      = "El usuario no tiene técnico asignado",
        )

    # [FIX-TZ] asyncpg/PostgreSQL no puede comparar datetime aware con TIMESTAMP
    # WITHOUT TIME ZONE. Convertimos since a UTC y eliminamos tzinfo antes de
    # pasarlo como parámetro. El cast SQL ::timestamp es una segunda protección.
    if since.tzinfo is not None:
        since = since.astimezone(timezone.utc).replace(tzinfo=None)

    rows = await db.fetch(
        """
        SELECT
            os.folio_os, os.estado, os.modalidad,
            os.fecha::text, os.observaciones,
            os.marca, os.modelo, os.ns, os.ubicacion,
            os.alcance_max, os.div_minima, os.div_verificacion,
            os.id_equipo, os.numero_cca, os.holograma_anterior,
            os.valor_repetibilidad, os.valor_excentricidad,
            COALESCE(os.sync_version, 1) AS sync_version,
            os.updated_at,
            cl.razon_social   AS cliente,
            cl.direccion      AS direccion_cliente,
            ts.nombre         AS tipo_servicio,
            tc.nombre_completo AS tecnico,
            ce.codigo         AS clase_exactitud_codigo,
            ti.nombre         AS tipo_instrumento
        FROM ordenes_servicio os
        LEFT JOIN cat_clientes         cl ON os.id_cliente         = cl.id
        LEFT JOIN cat_tipo_servicio    ts ON os.id_tipo_servicio    = ts.id
        LEFT JOIN cat_tecnicos         tc ON os.id_tecnico          = tc.id
        LEFT JOIN cat_clase_exactitud  ce ON os.id_clase_exactitud  = ce.id
        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
        WHERE os.id_tecnico = $1
          AND os.modalidad  = 'DIGITAL'
          AND os.estado     NOT IN ('CANCELADA', 'COMPLETADA')
          AND os.updated_at > $2::timestamp
        ORDER BY os.updated_at DESC
        LIMIT $3
        """,
        id_tecnico, since, settings.SYNC_MAX_BATCH_SIZE,
    )

    logger.info(
        "Sync PULL: tecnico_id=%d since=%s -> %d OS",
        id_tecnico, since.isoformat(), len(rows)
    )
    return [dict(r) for r in rows]


@router.post(
    "/push",
    response_model = PushResponse,
    summary        = "Subir cambios de la tablet al servidor",
)
async def sync_push(
    payload:      PushPayload,
    db            = Depends(get_db),
    current_user: dict = Depends(require_roles("servicio")),
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
        # Solo acepta transiciones válidas
        _TRANSICIONES_VALIDAS = {
            "ASIGNADA":      ["EN_CAMPO"],
            "EN_CAMPO":      ["SYNC_PENDIENTE", "FIRMADA"],
            "SYNC_PENDIENTE":["EN_CAMPO", "FIRMADA"],
            "FIRMADA":       [],            # Solo logistica puede avanzar a COMPLETADA
        }
        estados_siguientes = _TRANSICIONES_VALIDAS.get(row["estado"], [])
        if payload.nuevo_estado in estados_siguientes:
            nuevo_estado = payload.nuevo_estado

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
    # [FIX] Primer intento con sync_version, sync_at, device_id.
    # Si la columna no existe todavía (BD antigua), reintenta sin ellas.
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
                sync_version          = COALESCE(sync_version, 0) + 1,
                sync_at               = NOW(),
                device_id             = $11,
                updated_at            = NOW()
            WHERE id = $12
            """,
            nuevo_estado,
            payload.observaciones,
            payload.valor_repetibilidad,
            payload.valor_excentricidad,
            id_clase,
            payload.marca, payload.modelo, payload.ns, payload.ubicacion,
            payload.id_equipo,
            payload.device_id,
            os_id,
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
    current_user: dict = Depends(require_roles("servicio")),
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
