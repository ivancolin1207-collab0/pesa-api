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
import os
import traceback
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Union

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, field_validator

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user, require_roles
from pesa_api.core.config   import settings

router = APIRouter()
logger = logging.getLogger("pesa_api.sync")

# Tipo de servicio efectivo. En formatos físicos RE (Revisión de Celdas),
# RMA (Remisión / Entrega Refacciones) y LV prevalece el texto capturado en
# os.tipo_servicio: existen órdenes con id_tipo_servicio erróneo (p. ej. 4 =
# "Calibración + Ajuste") que harían que la tablet exigiera CCA/DVE.
_TIPO_SERVICIO_SQL = """
            CASE
                WHEN UPPER(COALESCE(os.tipo_documento, '')) = 'OSOCC'
                  OR os.folio_os ~* '^OSOCC-'
                THEN COALESCE(NULLIF(TRIM(os.tipo_servicio), ''), 'Observaciones Celda')
                WHEN UPPER(COALESCE(os.tipo_documento, '')) IN ('RE', 'RMA', 'LV', 'OSOB')
                  OR os.folio_os ~* '^(RE|RMA|LV|OSOB)-'
                THEN COALESCE(NULLIF(TRIM(os.tipo_servicio), ''), ts.nombre, '')
                ELSE COALESCE(ts.nombre, os.tipo_servicio, '')
            END"""


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
    id:                    Optional[int]   = None
    folio_os:              str
    id_tecnico:            Optional[int]   = None
    id_cliente:            Optional[int]   = None
    estado:                Optional[str]   = 'PROCESO'
    estatus:               Optional[str]   = None
    has_pdf:               Optional[bool]  = None
    modalidad:             Optional[str]   = 'DIGITAL'
    fecha:                 Optional[str]   = None
    cliente:               Optional[str]   = None
    cliente_nombre:        Optional[str]   = None
    direccion:             Optional[str]   = None
    direccion_cliente:     Optional[str]   = None
    sucursal_id:           Optional[int]   = None
    sucursal:              Optional[str]   = None
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
    id_indicador:          Optional[str]   = None
    equipo_catalogo_id:    Optional[int]   = None
    tipo_instrumento:      Optional[str]   = None
    id_tipo_instrumento:   Optional[int]   = None
    numero_cca:            Optional[str]   = None
    numero_dve:            Optional[str]   = None
    holograma_anterior:    Optional[str]   = None
    holograma_actualizado: Optional[str]   = None
    valor_repetibilidad:   Optional[float] = None
    valor_excentricidad:   Optional[float] = None
    clase_exactitud_codigo: Optional[str]  = None
    observaciones:         Optional[str]   = None
    aplica_excentricidad:  Optional[bool]  = True
    motivo_no_excentricidad: Optional[str] = None
    num_celdas_camionera:  Optional[int]   = 0
    secciones_camionera:   Optional[int]   = 0
    filas_excentricidad:   Optional[int]   = 4
    num_secciones:         Optional[int]   = 0
    instrumento_capacidad: Optional[str]   = None
    instrumento_division:  Optional[str]   = None
    datos_tecnicos_json:   Optional[str]   = '{}'
    partidas:              Optional[Union[List[dict], List[Any], str, Any]] = None
    refacciones:           Optional[Union[List[dict], List[Any], str, Any]] = None
    tipo_documento:        Optional[str]   = None
    pdf_url:               Optional[str]   = None
    # Campos Offline-First v2
    pdf_b64:               Optional[str]   = None   # PDF en Base64 subido por la tablet
    firma_tecnico_descargada: Optional[str] = None  # Firma del técnico para uso offline
    unidad_medida:         Optional[str]   = 'kg'   # kg / g / t / lb
    id_lote:               Optional[str]   = None   # Identificador del lote
    rango_lote:            Optional[str]   = None   # Rango legible del lote
    sync_check_status:     Optional[str]   = 'ASIGNADA' # ASIGNADA | RECIBIDA_TABLET | SUBIDA_SERVIDOR | AUDITADA_ADMIN
    fecha_descarga_tablet: Optional[datetime] = None
    fecha_subida_servidor: Optional[datetime] = None
    fecha_apertura_admin:  Optional[datetime] = None
    firma_tecnico:         Optional[str]   = None
    firma_cliente:         Optional[str]   = None
    firma_tecnico_b64:     Optional[str]   = None
    firma_cliente_b64:     Optional[str]   = None
    firma_cliente_nombre:  Optional[str]   = None
    nombre_ing:            Optional[str]   = None
    puesto_ing:            Optional[str]   = None
    dictamen:              Optional[str]   = None
    correo_cliente:        Optional[str]   = None
    email_enviado:         Optional[bool]  = False
    fecha_envio_email:     Optional[Union[datetime, str]] = None
    correo_enviado:        Optional[bool]  = False
    correo_destino:        Optional[str]   = None
    correo_cc:             Optional[str]   = None
    fecha_envio_correo:    Optional[str]   = None
    motivo_cancelacion:    Optional[str]   = None
    cancelada_por:         Optional[str]   = None
    fecha_cancelacion:     Optional[str]   = None
    sin_correo_cliente:    Optional[bool]  = False
    motivo_sin_correo:     Optional[str]   = None
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
    serie:              Optional[str] = None
    ubicacion:          Optional[str] = None
    id_equipo:          Optional[str] = None
    id_indicador:       Optional[str] = None
    no_identificacion:  Optional[str] = None
    unidad_medida:      Optional[str] = None   # kg / g / t / lb
    numero_cca:         Optional[str] = None
    cca:                Optional[str] = None
    numero_dve:         Optional[str] = None
    folio_dve:          Optional[str] = None
    holograma_anterior: Optional[str] = None
    holograma_actualizado: Optional[str] = None
    aplica_excentricidad: Optional[bool] = None
    motivo_no_excentricidad: Optional[str] = None
    parcial_instrumento: Optional[bool] = False

    # Vinculación a catálogo de sucursales (v13)
    sucursal_id:        Optional[int] = None
    equipo_catalogo_id: Optional[int] = None

    # Tablas de pruebas
    repetibilidad:  list[PushDetalle] = Field(default_factory=list)
    excentricidad:  list[PushDetalle] = Field(default_factory=list)
    exactitud:      list[PushDetalle] = Field(default_factory=list)
    datos_captura:  Optional[str] = None
    datos_tecnicos_json: Optional[Union[str, dict]] = None
    usa_sustitucion: Optional[bool] = None
    factor_sustitucion: Optional[str] = None
    capacidad_maxima: Optional[float] = None
    alcance_max:      Optional[float] = None
    division_minima:  Optional[float] = None
    div_minima:       Optional[float] = None
    tipo_instrumento: Optional[str] = None
    cliente:          Optional[str] = None
    area_cliente:     Optional[str] = None
    puesto_tecnico:   Optional[str] = None

    # Estado solicitado por la tablet
    nuevo_estado:   Optional[str] = None
    # Estatus legible (Proceso/Cerrado) y modalidad enviados explícitamente por la tablet
    estatus:        Optional[str] = None
    modalidad:      Optional[str] = None

    # Fecha real de ejecución y cierre en campo
    fecha:                    Optional[str] = None
    fecha_servicio:           Optional[str] = None
    fecha_cierre:             Optional[str] = None
    fecha_creacion_logistica: Optional[str] = None

    # Offline-First v2: PDF + firmas digitales
    pdf_b64:              Optional[str] = None  # PDF completo en Base64
    firma_tecnico:        Optional[str] = None  # PNG firma técnico en Base64
    firma_cliente:        Optional[str] = None  # PNG firma cliente en Base64
    nombre_ing:           Optional[str] = None
    puesto_ing:           Optional[str] = None
    firma_cliente_nombre: Optional[str] = None
    dictamen:             Optional[str] = None
    correo_cliente:       Optional[str] = None
    email_enviado:        Optional[bool] = None
    fecha_envio_email:    Optional[Union[datetime, str]] = None
    correo_enviado:       Optional[bool] = None
    correo_destino:       Optional[str] = None
    correo_cc:            Optional[str] = None
    fecha_envio_correo:   Optional[Union[datetime, str]] = None
    motivo_cancelacion:   Optional[str] = None
    cancelada_por:        Optional[str] = None
    fecha_cancelacion:    Optional[str] = None
    sin_correo_cliente:   Optional[bool] = None
    motivo_sin_correo:    Optional[str] = None


class PushResponse(BaseModel):
    folio_os:       str
    sync_version:   int
    estado:         str
    conflicto:      bool = False
    mensaje:        str  = "Sincronización exitosa"


class FirmasPayload(BaseModel):
    firma_tecnico_png:    Optional[str] = None
    firma_cliente_png:    Optional[str] = None
    firma_tecnico:        Optional[str] = None
    firma_cliente:        Optional[str] = None
    nombre_ing:           Optional[str] = None
    puesto_ing:           Optional[str] = None
    firma_cliente_nombre: Optional[str] = None
    correo_cliente:       Optional[str] = None

    @field_validator("firma_tecnico_png", "firma_cliente_png", "firma_tecnico", "firma_cliente", mode="before")
    @classmethod
    def validate_base64_size(cls, v: Optional[str]) -> Optional[str]:
        if not v:
            return v
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


# Reconstrucción explícita de modelos para resolver TypeAdapter y forward references en Pydantic v2
OSResumen.model_rebuild()
OSCompleta.model_rebuild()
PushDetalle.model_rebuild()
PushPayload.model_rebuild()
PushResponse.model_rebuild()
FirmasPayload.model_rebuild()
FolioLockResponse.model_rebuild()


# ── Endpoints ─────────────────────────────────────────────────────────────────

# Supervisores de calibración autorizados a consultar el repositorio global
# (solo lectura). Alan Guevara = cat_tecnicos.id 8 / usuario Daikki19.
_SUPERVISORES_CALIBRACION_IDS       = {8}
_SUPERVISORES_CALIBRACION_USERNAMES = {"daikki19", "ivancolin1207"}


@router.get(
    "/calibraciones-consulta",
    summary = "Repositorio de calibraciones concluidas (solo lectura, supervisión metrológica)",
)
async def calibraciones_consulta(
    db           = Depends(get_db),
    current_user: dict = Depends(get_current_user),
) -> list[dict]:
    """
    Devuelve las OS concluidas cuyo tipo de servicio contiene 'Calibración' o 'Ajuste',
    de TODOS los técnicos, con el nombre del técnico ejecutor y si tienen PDF.
    Solo metadatos de consulta: no incluye mediciones, firmas ni PDF en Base64.
    """
    import unicodedata
    from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
    await _ensure_email_columns(db)
    role = "".join(
        c for c in unicodedata.normalize("NFKD", str(current_user.get("role", "")))
        if not unicodedata.combining(c)
    ).lower()
    username = str(current_user.get("username", "")).strip().lower()
    try:
        id_tec = int(current_user.get("id_tecnico") or 0)
    except (TypeError, ValueError):
        id_tec = 0

    autorizado = (
        "admin" in role
        or username in _SUPERVISORES_CALIBRACION_USERNAMES
        or id_tec in _SUPERVISORES_CALIBRACION_IDS
    )
    if not autorizado:
        raise HTTPException(
            status_code = status.HTTP_403_FORBIDDEN,
            detail      = "No autorizado para consultar el repositorio de calibraciones",
        )

    tipo_expr = _TIPO_SERVICIO_SQL
    try:
        rows = await db.fetch(
            """
            SELECT DISTINCT ON (os.folio_os)
                os.folio_os,
                os.fecha::text                                   AS fecha,
                COALESCE(cl.razon_social, os.cliente, '')        AS cliente,
                COALESCE(suc.nombre_sucursal, '')                AS sucursal,
                os.id_tecnico,
                COALESCE(tc.nombre_completo, '')                 AS tecnico,
                """ + tipo_expr + """                            AS tipo_servicio,
                COALESCE(os.estado, '')                          AS estado,
                COALESCE(os.estatus, '')                         AS estatus,
                COALESCE(os.modalidad, '')                       AS modalidad,
                COALESCE(os.marca, '')                           AS marca,
                COALESCE(os.modelo, '')                          AS modelo,
                COALESCE(os.ns, '')                              AS ns,
                COALESCE(os.ns, '')                              AS serie,
                COALESCE(os.id_equipo::text, '')                 AS id_equipo,
                COALESCE(os.id_equipo::text, '')                 AS id_indicador,
                COALESCE(os.ubicacion, '')                       AS ubicacion,
                COALESCE(os.numero_cca, '')                      AS numero_cca,
                COALESCE(os.numero_dve, '')                      AS numero_dve,
                COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS correo_enviado,
                COALESCE(NULLIF(os.correo_destino, ''), os.correo_cliente, '') AS correo_destino,
                COALESCE(NULLIF(os.correo_cc, ''), 'recepcion@basculaspesa.com.mx') AS correo_cc,
                COALESCE(os.fecha_envio_correo, os.fecha_envio_email) AS fecha_envio_email,
                (COALESCE(os.pdf_generado, FALSE)
                   OR COALESCE(os.pdf_url, '') <> ''
                   OR COALESCE(os.pdf_path, '') <> '')           AS tiene_pdf,
                COALESCE(os.updated_at, NOW())::text             AS updated_at
            FROM ordenes_servicio os
            LEFT JOIN cat_clientes       cl  ON os.id_cliente       = cl.id
            LEFT JOIN cliente_sucursales suc ON os.sucursal_id      = suc.id
            LEFT JOIN cat_tecnicos       tc  ON os.id_tecnico       = tc.id
            LEFT JOIN cat_tipo_servicio  ts  ON os.id_tipo_servicio = ts.id
            WHERE (
                    UPPER(TRIM(COALESCE(os.estado, ''))) IN
                        ('CERRADO','CERRADA','COMPLETADA','COMPLETADO','COMPLETADA_DIGITAL',
                         'COMPLETADA_FISICA','ESCANEADA','FIRMADA')
                 OR UPPER(TRIM(COALESCE(os.estatus, ''))) IN ('CERRADO','CERRADA','COMPLETADO','COMPLETADA')
              )
              AND LOWER(""" + tipo_expr + """) LIKE '%%calibraci%%'
            ORDER BY os.folio_os, os.updated_at DESC NULLS LAST
            """.replace("%%", "%"),
        )
        data = []
        for r in rows:
            dr = dict(r)
            dr["fecha_envio_correo"] = formatear_fecha_hora_mexico(dr.get("fecha_envio_email")) or None
            data.append(dr)
        data.sort(key=lambda r: (r.get("fecha") or "", r.get("folio_os") or ""), reverse=True)
        logger.info("[CALIBRACIONES CONSULTA] user=%s id_tec=%s → %d registros", username, id_tec, len(data))
        return data
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[SYNC ERROR] Falla en calibraciones_consulta: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error en servidor al consultar calibraciones: {str(e)}",
        )


@router.get("", response_model=list[OSCompleta], summary="Sincronización de OS (alias de /pull)", tags=["Sincronización Offline"])
@router.get("/", response_model=list[OSCompleta], include_in_schema=False)
@router.get(
    "/pull",
    response_model = list[OSCompleta],
    summary        = "Descargar OS asignadas al técnico o todas las recientes para Admin",
)
async def sync_pull(
    q: Optional[str] = Query(
        default = None,
        description = "Búsqueda directa en servidor por folio, cliente, marca, modelo, serie, ID, CCA o DVE.",
    ),
    since: Optional[Union[datetime, str]] = Query(
        default = None,
        description = "Timestamp del último sync exitoso (ISO 8601).",
    ),
    tecnico_id: Optional[str] = Query(None, description="ID numérico del técnico (opcional)"),
    tecnico_nombre: Optional[str] = Query(None, description="Nombre o filtro de técnico (opcional)"),
    updated_after: Optional[str] = Query(None, description="Alias de since (opcional)"),
    limit: Optional[int] = Query(None, ge=1, le=2000, description="Límite máximo de registros"),
    db          = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Descarga de Órdenes de Servicio para Android / sincronización Offline-First:
    - Admin / Jefe / Gerente / Superadmin / Logística / Recepción: recibe TODAS las órdenes recientes
      de todos los técnicos ordenadas por fecha DESC, id DESC (sin filtrar por tecnico_id).
    - Técnico de campo: recibe únicamente sus órdenes asignadas (os.id_tecnico).
    - Parámetro opcional ?q= permite búsqueda directa en PostgreSQL sin restricción de since.
    """
    import unicodedata
    from datetime import timedelta
    from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
    await _ensure_email_columns(db)

    def _norm_role(r: str) -> str:
        if not r:
            return ""
        nfkd = unicodedata.normalize('NFKD', str(r))
        return "".join(c for c in nfkd if not unicodedata.combining(c)).lower().strip()

    role       = str(current_user.get("role", "")).strip()
    role_raw_l = role.lower().strip()
    role_norm  = _norm_role(role)
    id_tecnico = current_user.get("id_tecnico") or current_user.get("id")

    username_clean = str(current_user.get("username", "")).strip().lower()
    _ADMIN_EXACT = {"admin", "administrador", "superadmin", "jefe", "gerente", "direccion", "gerencia", "logistica", "recepcion"}
    is_admin = (
        role_raw_l in _ADMIN_EXACT
        or role_norm in _ADMIN_EXACT
        or any(ar in role_norm for ar in ("admin", "superadmin", "gerencia", "jefe", "gerente", "logist", "recep"))
        or username_clean == "ivancolin1207"
    )

    q_clean = str(q).strip() if q and str(q).strip() else None

    # [FIX-422] Parseo tolerante de since / updated_after (ignorado cuando se busca con ?q=)
    raw_date = None if q_clean else (updated_after or since)
    since_dt: Optional[datetime] = None
    if raw_date is not None:
        if isinstance(raw_date, datetime):
            since_dt = raw_date
        elif isinstance(raw_date, str) and raw_date.strip():
            try:
                clean_s = raw_date.strip().replace("Z", "+00:00")
                since_dt = datetime.fromisoformat(clean_s)
            except Exception:
                try:
                    from email.utils import parsedate_to_datetime
                    since_dt = parsedate_to_datetime(raw_date.strip())
                except Exception:
                    logger.warning("[SYNC PULL] Fecha since no reconocible '%s', ignorando filtro temporal", raw_date)
                    since_dt = None

    if since_dt is not None and since_dt.tzinfo is not None:
        since_dt = since_dt.astimezone(timezone.utc).replace(tzinfo=None)
    # Margen de seguridad de 12h para absorber diferencias entre relojes naive UTC-6 (Windows) y UTC (Render)
    since_safe = (since_dt - timedelta(hours=12)) if (since_dt and since_dt.year > 2000) else None

    effective_limit = int(limit) if (limit and limit > 0) else int(settings.SYNC_MAX_BATCH_SIZE)

    _SELECT_INNER = """
        SELECT DISTINCT ON (os.folio_os)
            os.id,
            os.fecha AS _fecha_sort,
            os.folio_os,
            COALESCE(os.tipo_documento, 'OS') AS tipo_documento,
            os.id_tecnico,
            os.id_cliente,
            os.sucursal_id,
            COALESCE(os.estado,    'PROCESO') AS estado,
            COALESCE(os.estatus, os.estado, 'Proceso') AS estatus,
            (COALESCE(os.pdf_generado, FALSE)
               OR COALESCE(os.pdf_url, '') <> ''
               OR COALESCE(os.pdf_path, '') <> ''
               OR COALESCE(os.pdf_b64, '') <> '') AS has_pdf,
            COALESCE(os.modalidad, 'DIGITAL') AS modalidad,
            os.fecha::text AS fecha,
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
            COALESCE(os.id_equipo::text, '') AS id_indicador,
            COALESCE(os.numero_cca, '') AS numero_cca,
            COALESCE(os.numero_dve, '') AS numero_dve,
            os.holograma_anterior,
            os.holograma_actualizado,
            os.valor_repetibilidad, os.valor_excentricidad,
            COALESCE(os.aplica_excentricidad, true)  AS aplica_excentricidad,
            COALESCE(os.motivo_no_excentricidad, '') AS motivo_no_excentricidad,
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
            COALESCE(os.id_lote, '')                AS id_lote,
            COALESCE(os.rango_lote, '')             AS rango_lote,
            COALESCE(
                cl.razon_social,
                NULLIF(TRIM(os.cliente), ''),
                CASE WHEN os.folio_os ~* '^OSOCC-' THEN COALESCE(NULLIF(TRIM(os.ubicacion), ''), 'Stock / Taller Básculas PESA') ELSE '' END
            ) AS cliente,
            COALESCE(
                cl.razon_social,
                NULLIF(TRIM(os.cliente), ''),
                CASE WHEN os.folio_os ~* '^OSOCC-' THEN COALESCE(NULLIF(TRIM(os.ubicacion), ''), 'Stock / Taller Básculas PESA') ELSE '' END
            ) AS cliente_nombre,
            COALESCE(suc.direccion, cl.direccion, '') AS direccion,
            COALESCE(suc.direccion, cl.direccion, '') AS direccion_cliente,
            COALESCE(suc.nombre_sucursal, '') AS sucursal,
            COALESCE(suc.nombre_sucursal, '') AS sucursal_nombre,
            """ + _TIPO_SERVICIO_SQL + """ AS tipo_servicio,
            COALESCE(tc.nombre_completo, '') AS tecnico,
            COALESCE(tc.nombre_completo, '') AS tecnico_nombre,
            ce.codigo                        AS clase_exactitud_codigo,
            COALESCE(ti.nombre,          '') AS tipo_instrumento,
            NULL::text                       AS pdf_b64,
            NULL::text                       AS firma_tecnico_descargada,
            COALESCE(os.firma_tecnico, os.firma_tecnico_b64, '') AS firma_tecnico,
            COALESCE(os.firma_cliente, os.firma_cliente_b64, '') AS firma_cliente,
            COALESCE(os.firma_tecnico_b64, os.firma_tecnico, '') AS firma_tecnico_b64,
            COALESCE(os.firma_cliente_b64, os.firma_cliente, '') AS firma_cliente_b64,
            COALESCE(os.nombre_ing, os.firma_cliente_nombre, '') AS nombre_ing,
            COALESCE(os.puesto_ing, '') AS puesto_ing,
            COALESCE(os.firma_cliente_nombre, os.nombre_ing, '') AS firma_cliente_nombre,
            COALESCE(os.dictamen, '') AS dictamen,
            'kg'                             AS unidad_medida,
            COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status,
            os.fecha_descarga_tablet,
            os.fecha_subida_servidor,
            os.fecha_apertura_admin,
            (CASE 
                WHEN (COALESCE(os.pdf_b64, '') <> '' 
                      OR COALESCE(os.pdf_base64, '') <> '' 
                      OR COALESCE(os.has_pdf, false) = true 
                      OR (COALESCE(os.pdf_url, '') <> '' AND os.pdf_url NOT LIKE '%/api/v1/os/%')) 
                THEN true 
                ELSE false 
             END) AS has_pdf_db,
            COALESCE(NULLIF(os.correo_destino, ''), os.correo_cliente, '') AS correo_cliente,
            COALESCE(NULLIF(os.correo_destino, ''), os.correo_cliente, '') AS correo_destino,
            COALESCE(NULLIF(os.correo_cc, ''), 'recepcion@basculaspesa.com.mx') AS correo_cc,
            COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS email_enviado,
            COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS correo_enviado,
            COALESCE(os.fecha_envio_correo, os.fecha_envio_email) AS fecha_envio_email,
            COALESCE(os.fecha_envio_correo, os.fecha_envio_email) AS fecha_envio_correo_raw,
            COALESCE(os.motivo_cancelacion, '') AS motivo_cancelacion,
            COALESCE(os.cancelada_por, '') AS cancelada_por,
            os.fecha_cancelacion::text AS fecha_cancelacion,
            COALESCE(os.sin_correo_cliente, FALSE) AS sin_correo_cliente,
            COALESCE(os.motivo_sin_correo, '') AS motivo_sin_correo,
            CASE
                WHEN COALESCE(os.pdf_b64,  '') <> ''
                  OR COALESCE(os.pdf_base64, '') <> ''
                  OR (COALESCE(os.pdf_url,  '') <> '' AND os.pdf_url NOT LIKE '%/api/v1/os/%')
                  OR (COALESCE(os.pdf_path, '') <> '' AND os.pdf_path NOT LIKE '%.tmp%')
                THEN '/api/v1/os/' || os.folio_os || '/pdf'
                ELSE NULL
            END AS pdf_url
        FROM ordenes_servicio os
        LEFT JOIN (SELECT DISTINCT ON (id) id, razon_social, direccion FROM cat_clientes ORDER BY id) cl ON os.id_cliente = cl.id
        LEFT JOIN cat_tipo_servicio    ts ON os.id_tipo_servicio    = ts.id
        LEFT JOIN cat_tecnicos         tc ON os.id_tecnico          = tc.id
        LEFT JOIN cat_clase_exactitud  ce ON os.id_clase_exactitud  = ce.id
        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
        LEFT JOIN (SELECT DISTINCT ON (id) id, nombre_sucursal, direccion FROM cliente_sucursales ORDER BY id) suc ON os.sucursal_id = suc.id
    """

    def _build_q_clause(param_index: int) -> str:
        return (
            f"("
            f"os.folio_os ILIKE ${param_index} "
            f"OR COALESCE(cl.razon_social, '') ILIKE ${param_index} "
            f"OR COALESCE(os.cliente, '') ILIKE ${param_index} "
            f"OR COALESCE(suc.nombre_sucursal, '') ILIKE ${param_index} "
            f"OR COALESCE(suc.direccion, '') ILIKE ${param_index} "
            f"OR COALESCE(tc.nombre_completo, '') ILIKE ${param_index} "
            f"OR COALESCE(os.marca, '') ILIKE ${param_index} "
            f"OR COALESCE(os.modelo, '') ILIKE ${param_index} "
            f"OR COALESCE(os.ns, '') ILIKE ${param_index} "
            f"OR COALESCE(os.id_equipo::text, '') ILIKE ${param_index} "
            f"OR COALESCE(os.indicador_id, '') ILIKE ${param_index} "
            f"OR COALESCE(os.ubicacion, '') ILIKE ${param_index} "
            f"OR COALESCE(os.numero_cca, '') ILIKE ${param_index} "
            f"OR COALESCE(os.numero_dve, '') ILIKE ${param_index} "
            f"OR COALESCE(os.id_lote, '') ILIKE ${param_index} "
            f"OR COALESCE(os.datos_tecnicos_json, '') ILIKE ${param_index}"
            f")"
        )

    param_tecnico_id: Optional[int] = None
    if tecnico_id is not None and str(tecnico_id).strip().isdigit():
        param_tecnico_id = int(str(tecnico_id).strip())

    param_tecnico_nombre: Optional[str] = None
    if tecnico_nombre is not None and str(tecnico_nombre).strip():
        param_tecnico_nombre = str(tecnico_nombre).strip()

    try:
        from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
        await _ensure_email_columns(db)
        if is_admin:
            where_admin = [
                "(os.estado IS NULL OR UPPER(TRIM(os.estado)) NOT IN ('ELIMINADO', 'ELIMINADA'))",
                "(os.estatus IS NULL OR UPPER(TRIM(os.estatus)) NOT IN ('ELIMINADO', 'ELIMINADA'))",
            ]
            params_admin: list = []

            if param_tecnico_nombre:
                params_admin.append(f"%{param_tecnico_nombre.lower()}%")
                idx = len(params_admin)
                where_admin.append(f"(LOWER(tc.nombre_completo) LIKE ${idx} OR LOWER(tc.usuario) LIKE ${idx} OR LOWER(COALESCE(os.cliente, '')) LIKE ${idx})")
            elif param_tecnico_id:
                params_admin.append(param_tecnico_id)
                idx = len(params_admin)
                where_admin.append(f"os.id_tecnico = ${idx}")

            if q_clean:
                params_admin.append(f"%{q_clean}%")
                where_admin.append(_build_q_clause(len(params_admin)))
            elif since_safe is not None:
                params_admin.append(since_safe)
                idx = len(params_admin)
                where_admin.append(f"(os.updated_at >= ${idx}::timestamp OR os.created_at >= ${idx}::timestamp)")

            params_admin.append(effective_limit)
            query_sql = f"""
                SELECT * FROM (
                    {_SELECT_INNER}
                    WHERE {" AND ".join(where_admin)}
                    ORDER BY os.folio_os, os.id DESC
                ) AS dedup_os
                ORDER BY dedup_os._fecha_sort DESC NULLS LAST, dedup_os.id DESC
                LIMIT ${len(params_admin)}
            """
            rows = await db.fetch(query_sql, *params_admin)
            logger.info(
                "Sync PULL [ADMIN %s (rol=%s, q=%r)]: %d OS ordenadas por fecha DESC, id DESC",
                current_user.get("username"), role, q_clean, len(rows),
            )
        else:
            username_jwt = str(current_user.get("username") or "").strip()
            nombre_jwt   = str(current_user.get("nombre_completo") or current_user.get("nombre") or username_jwt).strip()

            if param_tecnico_id and id_tecnico and int(id_tecnico) != param_tecnico_id:
                logger.warning(
                    "[SYNC PULL] Técnico %s pidió tecnico_id=%s ajeno — ignorado.",
                    username_jwt, param_tecnico_id,
                )

            if not id_tecnico and username_jwt:
                tec_lookup = await db.fetchrow(
                    "SELECT id, nombre_completo FROM cat_tecnicos WHERE LOWER(TRIM(usuario)) = LOWER(TRIM($1)) LIMIT 1",
                    username_jwt,
                )
                if tec_lookup:
                    id_tecnico = int(tec_lookup["id"])
                    if not nombre_jwt:
                        nombre_jwt = str(tec_lookup["nombre_completo"] or "")

            if not id_tecnico:
                logger.warning("[SYNC PULL] Usuario %s no tiene id_tecnico asociado — retornando 0 órdenes.", username_jwt)
                return []

            where_clauses = [
                "os.id_tecnico = $1",
                "(os.estado IS NULL OR UPPER(TRIM(os.estado)) NOT IN ('ELIMINADO', 'ELIMINADA'))",
                "(os.estatus IS NULL OR UPPER(TRIM(os.estatus)) NOT IN ('ELIMINADO', 'ELIMINADA'))",
            ]
            params: list = [int(id_tecnico)]

            if q_clean:
                params.append(f"%{q_clean}%")
                where_clauses.append(_build_q_clause(len(params)))
            elif since_safe is not None:
                params.append(since_safe)
                idx = len(params)
                where_clauses.append(f"(os.updated_at >= ${idx}::timestamp OR os.created_at >= ${idx}::timestamp)")

            params.append(effective_limit)
            query_sql = f"""
                SELECT * FROM (
                    {_SELECT_INNER}
                    WHERE {" AND ".join(where_clauses)}
                    ORDER BY os.folio_os, os.id DESC
                ) AS dedup_os
                ORDER BY dedup_os._fecha_sort DESC NULLS LAST, dedup_os.id DESC
                LIMIT ${len(params)}
            """

            rows = await db.fetch(query_sql, *params)
            logger.info(
                "Sync PULL [TECNICO id=%s user=%s q=%r]: %d OS encontradas",
                id_tecnico, username_jwt, q_clean, len(rows),
            )

        # ── Trazabilidad Estado 2: Doble palomita gris (Recibida en Tablet) ──────
        pulled_folios = [r["folio_os"] for r in rows if r.get("folio_os")]
        if not is_admin and pulled_folios:
            try:
                await db.execute(
                    """
                    UPDATE ordenes_servicio
                    SET sync_check_status = 'RECIBIDA_TABLET',
                        fecha_descarga_tablet = COALESCE(fecha_descarga_tablet, NOW())
                    WHERE folio_os = ANY($1)
                      AND (sync_check_status IS NULL OR sync_check_status = 'ASIGNADA')
                    """,
                    pulled_folios,
                )
                logger.info(
                    "[SYNC PULL] %d OS marcadas como RECIBIDA_TABLET para usuario %s",
                    len(pulled_folios), username_jwt,
                )
            except Exception as e_pull_tr:
                logger.warning("[SYNC PULL] Error actualizando trazabilidad RECIBIDA_TABLET: %s", e_pull_tr)

        upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
        resultado = []
        for r in rows:
            try:
                d = dict(r)
                d.pop("_fecha_sort", None)
                folio = (d.get("folio_os") or "").strip()

                # Comprobar si realmente existe un archivo binario en base de datos o en disco del servidor
                has_pdf_binary = bool(
                    d.get("has_pdf_db") or
                    (d.get("pdf_b64") and len(str(d["pdf_b64"]).strip()) > 100) or
                    (folio and os.path.exists(os.path.join(upload_dir, f"{folio}.pdf")))
                )

                # Comprobar si cuenta con captura finalizada (firmas, dictamen, pruebas metrologicas, o datos tecnicos)
                has_capture = bool(
                    (d.get("firma_tecnico") and len(str(d["firma_tecnico"]).strip()) > 20) or
                    (d.get("firma_cliente") and len(str(d["firma_cliente"]).strip()) > 20) or
                    (d.get("valor_repetibilidad") is not None) or
                    (d.get("valor_excentricidad") is not None) or
                    (d.get("dictamen") and str(d["dictamen"]).strip().upper() not in ("", "PENDIENTE")) or
                    (d.get("datos_tecnicos_json") and str(d["datos_tecnicos_json"]).strip() not in ("{}", "null", ""))
                )

                tiene_terminacion_real = has_pdf_binary or has_capture

                # Regla Estricta: Si no existe binario en disco ni BD, has_pdf es False y pdf_url es None
                if has_pdf_binary:
                    d["has_pdf"] = True
                    d["pdf_url"] = f"/api/v1/os/{folio}/pdf"
                else:
                    d["has_pdf"] = False
                    d["pdf_url"] = None

                # Si no se ha capturado en campo ni existe PDF generado, su estatus debe ser 'Asignada' o 'En Proceso'
                # (respetando estrictamente órdenes CANCELADA)
                estatus_actual = str(d.get("estatus") or d.get("estado") or "").strip().upper()
                estado_actual_col = str(d.get("estado") or "").strip().upper()
                if estatus_actual in ("CANCELADA", "CANCELADO") or estado_actual_col in ("CANCELADA", "CANCELADO"):
                    d["estatus"] = "CANCELADA"
                    d["estado"] = "CANCELADA"
                elif not tiene_terminacion_real:
                    if estatus_actual in ("CERRADO", "CERRADA", "COMPLETADO", "COMPLETADA", "COMPLETADA_DIGITAL", "COMPLETADA_FISICA", "FIRMADA", "ESCANEADA"):
                        d["estatus"] = "Asignada"
                        d["estado"] = "PROCESO"
                        if d.get("sync_check_status") in ("ENVIADA", "SUBIDA_SERVIDOR"):
                            d["sync_check_status"] = "ASIGNADA"

                if not is_admin and d.get("sync_check_status") == "ASIGNADA":
                    d["sync_check_status"] = "RECIBIDA_TABLET"
                d.pop("has_pdf_db", None)

                # Extraer partidas/refacciones y campos de instrumento de datos_tecnicos_json para entrega directa a la tablet
                raw_dt = d.get("datos_tecnicos_json")
                partidas_list = None
                if raw_dt:
                    try:
                        dt_obj = json.loads(raw_dt) if isinstance(raw_dt, str) else raw_dt
                        if isinstance(dt_obj, dict):
                            partidas_list = dt_obj.get("partidas") or dt_obj.get("refacciones") or dt_obj.get("items")
                            if not d.get("tipo_instrumento") and dt_obj.get("tipo_instrumento"):
                                d["tipo_instrumento"] = str(dt_obj.get("tipo_instrumento"))
                            if dt_obj.get("aplica_excentricidad") is not None:
                                d["aplica_excentricidad"] = bool(dt_obj.get("aplica_excentricidad"))
                            for str_key in ("marca", "modelo", "ns", "serie", "ubicacion", "id_equipo", "numero_cca", "numero_dve", "motivo_no_excentricidad"):
                                if not d.get(str_key) and dt_obj.get(str_key):
                                    d[str_key] = str(dt_obj.get(str_key))
                            if not d.get("id_equipo") and dt_obj.get("id_indicador"):
                                d["id_equipo"] = str(dt_obj.get("id_indicador"))
                            if not d.get("id_indicador") and d.get("id_equipo"):
                                d["id_indicador"] = str(d.get("id_equipo"))
                            if not d.get("numero_cca") and dt_obj.get("cca"):
                                d["numero_cca"] = str(dt_obj.get("cca"))
                            if not d.get("numero_dve") and dt_obj.get("folio_dve"):
                                d["numero_dve"] = str(dt_obj.get("folio_dve"))
                    except Exception:
                        pass
                d["partidas"] = partidas_list
                d["refacciones"] = partidas_list

                raw_fec_mail = d.pop("fecha_envio_correo_raw", None) or d.get("fecha_envio_email")
                fec_mail_local = formatear_fecha_hora_mexico(raw_fec_mail)
                d["fecha_envio_correo"] = fec_mail_local or None
                if fec_mail_local and not d.get("fecha_envio_email"):
                    d["fecha_envio_email"] = fec_mail_local

                resultado.append(OSCompleta(**d))
            except Exception as e_row:
                logger.warning("[SYNC PULL] Error serializando OS %s: %s", r.get("folio_os"), e_row)

        return resultado

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[SYNC ERROR] Falla en sincronización: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code = status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail      = f"Error en servidor: {str(e)}",
        )




@router.post(
    "/push",
    response_model = PushResponse,
    summary        = "Subir cambios de la tablet al servidor",
)
@router.post(
    "/sync",
    response_model = PushResponse,
    summary        = "Subir cambios de la tablet al servidor (alias)",
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
    try:
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

        from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
        from pesa_api.core.security import tiene_visibilidad_global
        await _ensure_email_columns(db)
        is_admin = tiene_visibilidad_global(current_user)

        # Verificar que la OS pertenece al técnico autenticado
        if not is_admin and row["id_tecnico"] != id_tecnico:
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

        # Si la tablet declara la orden Cerrada o Cancelada explícitamente
        if (not estado_protegido
                and ((payload.estatus or "").strip().upper() in ("CANCELADA", "CANCELADO")
                     or (payload.nuevo_estado or "").strip().upper() in ("CANCELADA", "CANCELADO"))):
            nuevo_estado = "CANCELADA"
        elif (not estado_protegido
                and not payload.parcial_instrumento
                and (payload.estatus or "").strip().upper() in ("CERRADO", "CERRADA", "COMPLETADO", "COMPLETADA")):
            nuevo_estado = "COMPLETADA_DIGITAL"
        elif (not estado_protegido
              and (payload.parcial_instrumento
                   or (payload.nuevo_estado or "").strip().upper() in ("EN_PROCESO", "PROCESO", "ASIGNADA"))
              and str(row["estado"] or "").strip().upper() not in ("COMPLETADA", "COMPLETADA_DIGITAL", "CERRADO", "CERRADA", "ESCANEADA", "FIRMADA")):
            nuevo_estado = "EN_PROCESO" if (payload.nuevo_estado or "").strip().upper() != "ASIGNADA" else "ASIGNADA"

        _CERRADOS = {"COMPLETADA", "COMPLETADA_DIGITAL", "CERRADO", "CERRADA", "ESCANEADA", "FIRMADA"}
        if str(nuevo_estado or "").upper() in ("CANCELADA", "CANCELADO"):
            nuevo_estatus = "CANCELADA"
        elif str(nuevo_estado or "").upper() in _CERRADOS:
            nuevo_estatus = "Cerrado"
        elif str(nuevo_estado or "").upper() == "ASIGNADA":
            nuevo_estatus = "Asignada"
        elif str(nuevo_estado or "").upper() in ("EN_PROCESO", "PROCESO"):
            nuevo_estatus = "En Proceso"
        else:
            nuevo_estatus = None

        if payload.serie and not payload.ns:
            payload.ns = payload.serie

        # Resolver clase de exactitud (si viene el código, buscar el ID)
        id_clase = row["id_clase_exactitud"]
        if payload.clase_exactitud_codigo:
            clase_row = await db.fetchrow(
                "SELECT id FROM cat_clase_exactitud WHERE codigo = $1",
                payload.clase_exactitud_codigo,
            )
            if clase_row:
                id_clase = clase_row["id"]

        # Resolver ID de equipo efectivo enviado desde la tablet
        effective_id_equipo = (payload.id_equipo or payload.id_indicador or payload.no_identificacion or None)
        if effective_id_equipo:
            effective_id_equipo = effective_id_equipo.strip()

        # Actualizar OS en el servidor
        # [FIX] Primer intento con sync_version, sync_at, device_id, pdf_b64, unidad_medida.
        # Si alguna columna no existe (BD sin migrar), reintenta sin ellas.
        try:
            upd_status = await db.execute(
                """
                UPDATE ordenes_servicio SET
                    estado                = $1,
                    estatus               = COALESCE($21, estatus),
                    modalidad             = COALESCE($22, modalidad),
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
                    firma_tecnico         = COALESCE($13, firma_tecnico),
                    firma_tecnico_b64     = COALESCE($13, firma_tecnico_b64),
                    firma_cliente         = COALESCE($14, firma_cliente),
                    firma_cliente_b64     = COALESCE($14, firma_cliente_b64),
                    nombre_ing            = COALESCE($15, nombre_ing),
                    puesto_ing            = COALESCE($16, puesto_ing),
                    firma_cliente_nombre  = COALESCE($17, firma_cliente_nombre),
                    dictamen              = COALESCE($18, dictamen),
                    correo_cliente        = COALESCE($23, correo_cliente),
                    sync_status           = 'SINCRONIZADO',
                    sync_version          = COALESCE(sync_version, 0) + 1,
                    sync_at               = NOW(),
                    device_id             = $19,
                    sync_check_status     = CASE
                        WHEN $11 IS NOT NULL OR $1 IN ('COMPLETADA', 'COMPLETADA_DIGITAL') THEN 'SUBIDA_SERVIDOR'
                        WHEN sync_check_status = 'AUDITADA_ADMIN' THEN 'AUDITADA_ADMIN'
                        ELSE COALESCE(sync_check_status, 'RECIBIDA_TABLET')
                    END,
                    fecha_subida_servidor = CASE
                        WHEN $11 IS NOT NULL OR $1 IN ('COMPLETADA', 'COMPLETADA_DIGITAL') THEN COALESCE(fecha_subida_servidor, NOW())
                        ELSE fecha_subida_servidor
                    END,
                    updated_at            = NOW()
                WHERE id = $20
                """,
                nuevo_estado,
                payload.observaciones,
                payload.valor_repetibilidad,
                payload.valor_excentricidad,
                id_clase,
                payload.marca, payload.modelo, payload.ns, payload.ubicacion,
                effective_id_equipo,
                payload.pdf_b64,        # $11
                payload.unidad_medida,  # $12
                payload.firma_tecnico,  # $13
                payload.firma_cliente,  # $14
                payload.nombre_ing or payload.firma_cliente_nombre,  # $15
                payload.puesto_ing,     # $16
                payload.firma_cliente_nombre or payload.nombre_ing,  # $17
                payload.dictamen,       # $18
                payload.device_id,      # $19
                os_id,                  # $20
                nuevo_estatus,          # $21
                payload.modalidad,      # $22
                payload.correo_cliente, # $23
            )
        except Exception as e_full:
            logger.warning("UPDATE con sync_version falló (%s) — reintentando sin columnas opcionales", e_full)
            # Fallback sin sync_version / sync_at / device_id (BD sin migración)
            upd_status = await db.execute(
                """
                UPDATE ordenes_servicio SET
                    estado               = $1,
                    observaciones        = COALESCE($2, observaciones),
                    valor_repetibilidad  = COALESCE($3, valor_repetibilidad),
                    valor_excentricidad  = COALESCE($4, valor_excentricidad),
                    id_clase_exactitud   = COALESCE($5, id_clase_exactitud),
                    marca                = COALESCE($6, marca),
                    modelo               = COALESCE($7, modelo),
                    ns                   = COALESCE($8, ns),
                    ubicacion            = COALESCE($9, ubicacion),
                    id_equipo            = COALESCE($10, id_equipo),
                    firma_tecnico        = COALESCE($11, firma_tecnico),
                    firma_tecnico_b64    = COALESCE($11, firma_tecnico_b64),
                    firma_cliente        = COALESCE($12, firma_cliente),
                    firma_cliente_b64    = COALESCE($12, firma_cliente_b64),
                    nombre_ing           = COALESCE($13, nombre_ing),
                    puesto_ing           = COALESCE($14, puesto_ing),
                    firma_cliente_nombre = COALESCE($15, firma_cliente_nombre),
                    dictamen             = COALESCE($16, dictamen),
                    estatus              = COALESCE($18, estatus),
                    sync_status          = 'SINCRONIZADO',
                    updated_at           = NOW()
                WHERE id = $17
                """,
                nuevo_estado,
                payload.observaciones,
                payload.valor_repetibilidad,
                payload.valor_excentricidad,
                id_clase,
                payload.marca, payload.modelo, payload.ns, payload.ubicacion,
                effective_id_equipo,
                payload.firma_tecnico,
                payload.firma_cliente,
                payload.nombre_ing or payload.firma_cliente_nombre,
                payload.puesto_ing,
                payload.firma_cliente_nombre or payload.nombre_ing,
                payload.dictamen,
                os_id,
                nuevo_estatus,
            )

        # Nunca devolver 200 si PostgreSQL no registró el cambio (p.ej. id NULL):
        # la tablet marcaría 'Enviada' mientras macOS sigue viendo 'Proceso'.
        if str(upd_status or "").strip().endswith(" 0"):
            logger.error("[SYNC PUSH] UPDATE afectó 0 filas para %s (id=%s)", payload.folio_os, os_id)
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"OS {payload.folio_os!r} no se pudo actualizar en el servidor",
            )

        if any(v is not None for v in (
            payload.correo_destino, payload.correo_cliente,
            payload.sin_correo_cliente, payload.motivo_sin_correo,
            payload.motivo_cancelacion, payload.cancelada_por,
        )):
            try:
                corr_eff = (payload.correo_destino or payload.correo_cliente or "").strip() or None
                await db.execute(
                    """
                    UPDATE ordenes_servicio SET
                        correo_destino     = COALESCE($1, correo_destino),
                        correo_cliente     = COALESCE($1, correo_cliente),
                        sin_correo_cliente = COALESCE($2, sin_correo_cliente),
                        motivo_sin_correo  = COALESCE($3, motivo_sin_correo),
                        motivo_cancelacion = COALESCE($4, motivo_cancelacion),
                        cancelada_por      = COALESCE($5, cancelada_por),
                        fecha_cancelacion  = CASE WHEN $4 IS NOT NULL THEN COALESCE(fecha_cancelacion, NOW()) ELSE fecha_cancelacion END
                    WHERE id = $6
                    """,
                    corr_eff,
                    payload.sin_correo_cliente,
                    payload.motivo_sin_correo,
                    payload.motivo_cancelacion,
                    payload.cancelada_por,
                    os_id,
                )
            except Exception as e_mc:
                logger.warning("[SYNC PUSH] Error guardando correo/cancelación para %s: %s", payload.folio_os, e_mc)

        # Actualizar fecha real de realización enviada por la tablet al finalizar servicio
        if payload.datos_tecnicos_json or payload.datos_captura:
            try:
                raw_json_str = (
                    json.dumps(payload.datos_tecnicos_json, ensure_ascii=False)
                    if isinstance(payload.datos_tecnicos_json, dict)
                    else str(payload.datos_tecnicos_json or payload.datos_captura)
                )
                await db.execute(
                    "UPDATE ordenes_servicio SET datos_tecnicos_json = $1 WHERE id = $2",
                    raw_json_str, os_id,
                )
            except Exception as e_dtj:
                logger.warning("[SYNC PUSH] Error guardando datos_tecnicos_json para %s: %s", payload.folio_os, e_dtj)

        if any(v is not None for v in (
            payload.alcance_max, payload.capacidad_maxima,
            payload.div_minima, payload.division_minima,
            payload.cliente, payload.tipo_instrumento,
            payload.numero_cca, payload.cca,
            payload.numero_dve, payload.folio_dve,
            payload.aplica_excentricidad, payload.motivo_no_excentricidad,
            payload.holograma_anterior, payload.holograma_actualizado,
        )):
            try:
                import re as _re
                cap_v = payload.alcance_max if payload.alcance_max is not None else payload.capacidad_maxima
                div_v = payload.div_minima if payload.div_minima is not None else payload.division_minima
                cca_raw = payload.numero_cca if payload.numero_cca is not None else payload.cca
                dve_raw = payload.numero_dve if payload.numero_dve is not None else payload.folio_dve
                cca_v = "" if (cca_raw is not None and _re.match(r"^(CCA|DVE)\.\d{2}\.?$", str(cca_raw).strip(), flags=_re.I)) else cca_raw
                dve_v = "" if (dve_raw is not None and _re.match(r"^(CCA|DVE)\.\d{2}\.?$", str(dve_raw).strip(), flags=_re.I)) else dve_raw
                await db.execute(
                    """
                    UPDATE ordenes_servicio SET
                        alcance_max             = COALESCE($1, alcance_max),
                        capacidad_maxima        = COALESCE($1, capacidad_maxima),
                        div_minima              = COALESCE($2, div_minima),
                        division_minima         = COALESCE($2, division_minima),
                        cliente                 = COALESCE($3, cliente),
                        tipo_instrumento        = COALESCE($4, tipo_instrumento),
                        numero_cca              = COALESCE($5, numero_cca),
                        numero_dve              = COALESCE($6, numero_dve),
                        aplica_excentricidad    = COALESCE($7, aplica_excentricidad),
                        motivo_no_excentricidad = COALESCE($8, motivo_no_excentricidad),
                        holograma_anterior      = COALESCE($9, holograma_anterior),
                        holograma_actualizado   = COALESCE($10, holograma_actualizado)
                    WHERE id = $11
                    """,
                    cap_v, div_v, payload.cliente, payload.tipo_instrumento,
                    cca_v, dve_v, payload.aplica_excentricidad, payload.motivo_no_excentricidad,
                    payload.holograma_anterior, payload.holograma_actualizado, os_id,
                )
            except Exception as e_ext:
                logger.warning("[SYNC PUSH] Error guardando campos extra de equipo para %s: %s", payload.folio_os, e_ext)

        fecha_ejecucion_raw = (payload.fecha or payload.fecha_servicio or "").strip()
        if fecha_ejecucion_raw:
            fecha_iso = fecha_ejecucion_raw[:10]
            try:
                from datetime import date as _date
                fecha_dt = _date.fromisoformat(fecha_iso)
                await db.execute(
                    "UPDATE ordenes_servicio SET fecha = $1, updated_at = NOW() WHERE id = $2",
                    fecha_dt, os_id,
                )
            except Exception:
                try:
                    await db.execute(
                        "UPDATE ordenes_servicio SET fecha = $1, updated_at = NOW() WHERE id = $2",
                        fecha_iso, os_id,
                    )
                except Exception as e_fecha:
                    logger.warning("[SYNC PUSH] No se pudo actualizar fecha de OS %s: %s", payload.folio_os, e_fecha)

        if payload.fecha_cierre or nuevo_estado in ("COMPLETADA", "COMPLETADA_DIGITAL", "Cerrado", "CERRADO"):
            try:
                await db.execute(
                    "UPDATE ordenes_servicio SET fecha_cierre = COALESCE(fecha_cierre, NOW()) WHERE id = $1",
                    os_id,
                )
            except Exception:
                pass

        # Upsert de pruebas metrológicas
        await _upsert_pruebas(db, os_id, payload)

        # Si viene el PDF en Base64, guardarlo en el almacenamiento de Render
        if payload.pdf_b64:
            try:
                import os
                import base64
                upload_dir = os.environ.get("UPLOAD_DIR", "uploads")
                os.makedirs(upload_dir, exist_ok=True)
                p_filename = f"{payload.folio_os}.pdf"
                p_filepath = os.path.join(upload_dir, p_filename)
                p_bytes = base64.b64decode(payload.pdf_b64)
                with open(p_filepath, "wb") as pf:
                    pf.write(p_bytes)
                await db.execute(
                    """
                    UPDATE ordenes_servicio 
                    SET pdf_url = $1, pdf_path = $2, pdf_b64 = $4,
                        pdf_generado = TRUE,
                        sync_check_status = CASE 
                            WHEN sync_check_status = 'AUDITADA_ADMIN' THEN 'AUDITADA_ADMIN' 
                            ELSE 'SUBIDA_SERVIDOR' 
                        END,
                        fecha_subida_servidor = COALESCE(fecha_subida_servidor, NOW()),
                        updated_at = NOW()
                    WHERE id = $3
                    """,
                    f"/uploads/{p_filename}", p_filepath, os_id, payload.pdf_b64,
                )
                logger.info("[SYNC PUSH] PDF guardado en disco y PostgreSQL para %s (%d bytes)", payload.folio_os, len(p_bytes))
                # Disparar envío automático de correo vía Gmail SMTP
                try:
                    import asyncio
                    from pesa_api.core.email_service import enviar_email_orden
                    asyncio.create_task(enviar_email_orden(None, payload.folio_os, correo_override=payload.correo_cliente, auto=True))
                    logger.info("[SYNC PUSH] Envío de correo programado para %s", payload.folio_os)
                except Exception as e_em:
                    logger.warning("[SYNC PUSH] Error programando correo: %s", e_em)
            except Exception as e_pdf_disk:
                logger.warning("[SYNC PUSH] Error guardando PDF en disco: %s", e_pdf_disk)

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

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[SYNC ERROR] Falla en sincronización push: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code = status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail      = f"Error en servidor: {str(e)}",
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
    try:
        id_tecnico = current_user.get("id_tecnico")

        row = await db.fetchrow(
            "SELECT id, id_tecnico, estado FROM ordenes_servicio WHERE folio_os = $1",
            folio_os,
        )
        if row is None:
            raise HTTPException(status_code=404, detail=f"OS {folio_os!r} no encontrada")

        from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
        from pesa_api.core.security import tiene_visibilidad_global
        await _ensure_email_columns(db)
        is_admin = tiene_visibilidad_global(current_user)

        if not is_admin and row["id_tecnico"] != id_tecnico:
            raise HTTPException(status_code=403, detail="OS no asignada a este usuario")
        if row["estado"] in ("CANCELADA", "COMPLETADA"):
            raise HTTPException(status_code=400, detail=f"OS en estado {row['estado']!r}, no se pueden añadir firmas")

        f_tec = payload.firma_tecnico or payload.firma_tecnico_png
        f_cli = payload.firma_cliente or payload.firma_cliente_png
        nom_ing = payload.nombre_ing or payload.firma_cliente_nombre
        puesto_ing = payload.puesto_ing
        correo_cli = payload.correo_cliente

        if correo_cli and str(correo_cli).strip():
            try:
                await db.execute(
                    "UPDATE ordenes_servicio SET correo_cliente = $1 WHERE id = $2",
                    str(correo_cli).strip(), row["id"],
                )
            except Exception:
                pass

        # [FIX] Intenta con sync_version y sync_at; si no existen, usa fallback
        try:
            await db.execute(
                """
                UPDATE ordenes_servicio SET
                    firma_tecnico        = COALESCE($1, firma_tecnico),
                    firma_tecnico_b64    = COALESCE($1, firma_tecnico_b64),
                    firma_cliente        = COALESCE($2, firma_cliente),
                    firma_cliente_b64    = COALESCE($2, firma_cliente_b64),
                    nombre_ing           = COALESCE($3, nombre_ing),
                    puesto_ing           = COALESCE($4, puesto_ing),
                    firma_cliente_nombre = COALESCE($3, firma_cliente_nombre),
                    estado               = 'FIRMADA',
                    sync_version         = COALESCE(sync_version, 0) + 1,
                    sync_at              = NOW(),
                    updated_at           = NOW()
                WHERE id = $5
                """,
                f_tec,
                f_cli,
                nom_ing,
                puesto_ing,
                row["id"],
            )
        except Exception as e_firmas:
            logger.warning("UPDATE firmas con sync_version falló (%s) — reintentando sin columnas opcionales", e_firmas)
            await db.execute(
                """
                UPDATE ordenes_servicio SET
                    firma_tecnico        = COALESCE($1, firma_tecnico),
                    firma_tecnico_b64    = COALESCE($1, firma_tecnico_b64),
                    firma_cliente        = COALESCE($2, firma_cliente),
                    firma_cliente_b64    = COALESCE($2, firma_cliente_b64),
                    nombre_ing           = COALESCE($3, nombre_ing),
                    puesto_ing           = COALESCE($4, puesto_ing),
                    firma_cliente_nombre = COALESCE($3, firma_cliente_nombre),
                    estado               = 'FIRMADA',
                    updated_at           = NOW()
                WHERE id = $5
                """,
                f_tec,
                f_cli,
                nom_ing,
                puesto_ing,
                row["id"],
            )

        logger.info("Firmas subidas para folio=%s por tecnico_id=%s", folio_os, id_tecnico)
        return {
            "detail":       "Firmas registradas. Estado actualizado a FIRMADA.",
            "folio_os":     folio_os,
            "nuevo_estado": "FIRMADA",
        }

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[SYNC ERROR] Falla en upload_firmas: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code = status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail      = f"Error en servidor: {str(e)}",
        )


@router.get(
    "/folio-lock",
    response_model = FolioLockResponse,
    summary        = "Reservar el siguiente folio para uso offline",
)
async def folio_lock(
    tipo:         str         = Query(..., pattern="^(OS|RMA|RE|OSOB|OSOCC|LV|LP)$"),
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
        "SELECT generate_folio($1::VARCHAR, $2::SMALLINT)",
        tipo, anio,
    )
    if tipo.upper() in ("OSOB", "OSOCC") and folio:
        try:
            parts = str(folio).split("-")
            if len(parts) == 3:
                folio = f"{tipo.upper()}-{parts[1]}-{int(parts[2]):03d}"
        except Exception:
            pass
    logger.info(
        "Folio reservado offline: %s por usuario=%s",
        folio, current_user["username"]
    )
    return FolioLockResponse(folio=folio, tipo=tipo)


OSCompleta.model_rebuild()
