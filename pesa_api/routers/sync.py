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
from typing   import Optional, Union

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
    id_tecnico:            Optional[int]   = None
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
    firma_cliente_nombre: Optional[str] = None
    dictamen:             Optional[str] = None


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


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("", response_model=list[OSCompleta], summary="Sincronización de OS (alias de /pull)", tags=["Sincronización Offline"])
@router.get("/", response_model=list[OSCompleta], include_in_schema=False)
@router.get(
    "/pull",
    response_model = list[OSCompleta],
    summary        = "Descargar OS asignadas al técnico (Tablet → Servidor)",
)
async def sync_pull(
    since: Optional[Union[datetime, str]] = Query(
        default = None,
        description = "Timestamp del último sync exitoso (ISO 8601). Se retornan solo OS modificadas después de este tiempo.",
    ),
    tecnico_id: Optional[str] = Query(None, description="ID numérico del técnico (opcional)"),
    tecnico_nombre: Optional[str] = Query(None, description="Nombre o filtro de técnico (opcional)"),
    updated_after: Optional[str] = Query(None, description="Alias de since (opcional)"),
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
    Acepta parámetros opcionales tecnico_id, tecnico_nombre, updated_after sin romper con 422.
    """
    import unicodedata

    def _norm_role(r: str) -> str:
        if not r:
            return ""
        nfkd = unicodedata.normalize('NFKD', str(r))
        return "".join(c for c in nfkd if not unicodedata.combining(c)).lower().strip()

    role       = str(current_user.get("role", "")).strip()
    role_norm  = _norm_role(role)
    id_tecnico = current_user.get("id_tecnico") or current_user.get("id")

    # Solo roles expresamente de control y administración ven todas las órdenes
    _ADMIN_ROLES = {"admin", "administrador", "superadmin", "direccion", "gerencia"}
    is_admin   = any(ar in role_norm for ar in _ADMIN_ROLES)

    # [FIX-422] Parseo tolerante de since / updated_after (evita HTTP 422 si el formato difiere)
    raw_date = updated_after or since
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

    # ── SELECT blindado con COALESCE en todos los campos de texto ─────────────
    # Garantiza que ningún NULL en órdenes físicas rompa la validación Pydantic.
    # [FIX-DUPLICADOS] SELECT DISTINCT ON garantiza una sola fila por folio_os.
    # El JOIN con cliente_sucursales puede multiplicar filas si hay varias sucursales
    # por cliente, o si el técnico coincide tanto por id como por nombre en el WHERE.
    _SELECT = """
        SELECT DISTINCT ON (os.folio_os)
            os.folio_os,
            os.id_tecnico,
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
            COALESCE(os.id_lote, '')                AS id_lote,
            COALESCE(os.rango_lote, '')             AS rango_lote,
            COALESCE(cl.razon_social, os.cliente, '') AS cliente,
            COALESCE(cl.razon_social, os.cliente, '') AS cliente_nombre,
            COALESCE(cl.direccion,       '') AS direccion_cliente,
            COALESCE(suc.nombre_sucursal, '') AS sucursal_nombre,
            COALESCE(ts.nombre, os.tipo_servicio, '') AS tipo_servicio,
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

    # ── DIAGNÓSTICO COMPLETO EN RENDER LOGS ─────────────────────────────────
    logger.info(
        "[SYNC PULL] ===== DIAGNÓSTICO INICIO =====\n"
        "  current_user completo: %s\n"
        "  id_tecnico=%s | role=%s | is_admin=%s\n"
        "  since=%s",
        dict(current_user), id_tecnico, role, is_admin, since,
    )
    print(
        f"[SYNC PULL DIAG] id={current_user.get('id')} "
        f"username={current_user.get('username')} "
        f"nombre_completo={current_user.get('nombre_completo')} "
        f"role={role} id_tecnico={id_tecnico} is_admin={is_admin}"
    )

    # Parametros opcionales procesados de forma flexible
    param_tecnico_id: Optional[int] = None
    if tecnico_id is not None and str(tecnico_id).strip().isdigit():
        param_tecnico_id = int(str(tecnico_id).strip())

    param_tecnico_nombre: Optional[str] = None
    if tecnico_nombre is not None and str(tecnico_nombre).strip():
        param_tecnico_nombre = str(tecnico_nombre).strip()

    try:
        if is_admin:
            where_admin = ["(os.estado IS NULL OR UPPER(TRIM(os.estado)) != 'CANCELADA')"]
            params_admin = []

            if param_tecnico_nombre:
                params_admin.append(f"%{param_tecnico_nombre.lower()}%")
                idx = len(params_admin)
                where_admin.append(f"(LOWER(tc.nombre_completo) LIKE ${idx} OR LOWER(tc.usuario) LIKE ${idx} OR LOWER(COALESCE(os.cliente, '')) LIKE ${idx})")
            elif param_tecnico_id:
                params_admin.append(param_tecnico_id)
                idx = len(params_admin)
                where_admin.append(f"os.id_tecnico = ${idx}")

            if since_dt and since_dt.year > 2000:
                params_admin.append(since_dt)
                idx = len(params_admin)
                where_admin.append(f"os.updated_at >= ${idx}::timestamp")

            params_admin.append(settings.SYNC_MAX_BATCH_SIZE)
            query_sql = _SELECT + f"""
                WHERE {" AND ".join(where_admin)}
                ORDER BY os.folio_os DESC, os.updated_at DESC
                LIMIT ${len(params_admin)}
            """
            rows = await db.fetch(query_sql, *params_admin)
            logger.info(
                "Sync PULL [ADMIN %s (rol=%s)]: %d OS DISTINTAS",
                current_user.get("username"), role, len(rows),
            )
        else:
            # Técnico: ÚNICAMENTE sus propias órdenes asignadas por id_tecnico exacto
            username_jwt = str(current_user.get("username") or "").strip()
            nombre_jwt   = str(current_user.get("nombre_completo") or current_user.get("nombre") or username_jwt).strip()

            if param_tecnico_id:
                if not id_tecnico or id_tecnico == param_tecnico_id:
                    id_tecnico = param_tecnico_id

            # [FIX-DEFENSIVO] Si id_tecnico es None o inválido, buscarlo en BD por username o param_tecnico_nombre
            if not id_tecnico and (username_jwt or param_tecnico_nombre):
                busq = param_tecnico_nombre or username_jwt
                tec_lookup = await db.fetchrow(
                    "SELECT id, nombre_completo FROM cat_tecnicos WHERE LOWER(TRIM(usuario)) = LOWER(TRIM($1)) OR LOWER(TRIM(nombre_completo)) LIKE LOWER(TRIM($2))",
                    username_jwt, f"%{busq}%",
                )
                if tec_lookup:
                    id_tecnico = int(tec_lookup["id"])
                    if not nombre_jwt:
                        nombre_jwt = str(tec_lookup["nombre_completo"] or "")

            if not id_tecnico:
                logger.warning("[SYNC PULL] Usuario %s no tiene id_tecnico asociado — retornando 0 órdenes.", username_jwt)
                return []

            # REGLA DE NEGOCIO ESTRICTA:
            # Filtrar EXCLUSIVAMENTE por os.id_tecnico = :id_tecnico
            where_clauses = [
                "os.id_tecnico = $1",
                "(os.estado IS NULL OR UPPER(TRIM(os.estado)) NOT IN ('CANCELADA', 'ELIMINADO', 'ELIMINADA'))",
            ]
            params = [int(id_tecnico)]

            # Filtro since si aplica
            if since_dt and since_dt.year > 2000:
                params.append(since_dt)
                where_clauses.append(f"os.updated_at >= ${len(params)}::timestamp")

            params.append(settings.SYNC_MAX_BATCH_SIZE)
            query_sql = _SELECT + f"""
                WHERE {" AND ".join(where_clauses)}
                ORDER BY os.folio_os DESC, os.updated_at DESC
                LIMIT ${len(params)}
            """

            logger.info(
                "[SYNC PULL SQL QUERY - STRICT TECNICO %s (id=%s)]:\n%s\nPARAMS: %s",
                username_jwt, id_tecnico, query_sql, params,
            )

            rows = await db.fetch(query_sql, *params)

            logger.info(
                "Sync PULL [TECNICO id=%s user=%s nombre=%s]: %d OS encontradas",
                id_tecnico, username_jwt, nombre_jwt, len(rows),
            )
            print(
                f"[SYNC PULL RESULT] id_tecnico={id_tecnico} username={username_jwt} "
                f"nombre='{nombre_jwt}' -> {len(rows)} OS encontradas"
            )

            # Diagnóstico extra si no se encontró nada
            if len(rows) == 0:
                try:
                    # Contar cuántas OS hay sin filtro de técnico
                    total_os = await db.fetchval(
                        "SELECT COUNT(*) FROM ordenes_servicio WHERE UPPER(TRIM(COALESCE(estado,''))) != 'CANCELADA'"
                    )
                    # Buscar si existe el técnico en cat_tecnicos
                    tec_check = await db.fetchrow(
                        "SELECT id, nombre_completo, usuario, activo FROM cat_tecnicos WHERE id = $1 OR LOWER(usuario) = LOWER($2)",
                        id_tecnico or -1, username_jwt,
                    )
                    # Buscar OS con JOIN por nombre via cat_tecnicos
                    nombre_param = f"%{nombre_jwt.lower()}%" if nombre_jwt else "%"
                    os_por_nombre = await db.fetchval(
                        """
                        SELECT COUNT(*) FROM ordenes_servicio os
                        JOIN cat_tecnicos t ON t.id = os.id_tecnico
                        WHERE LOWER(t.nombre_completo) ILIKE $1 OR LOWER(t.usuario) ILIKE $1
                        """,
                        nombre_param,
                    )
                    # Buscar OS por id_tecnico directo
                    os_por_id = await db.fetchval(
                        "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico = $1",
                        id_tecnico or -1,
                    )
                    # OS por id_tecnico sin el filtro de since
                    os_por_id_sin_since = await db.fetchval(
                        "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico = $1 AND UPPER(TRIM(COALESCE(estado,''))) != 'CANCELADA'",
                        id_tecnico or -1,
                    )
                    # OS con id_tecnico NULL (huérfanas)
                    os_null_tecnico = await db.fetchval(
                        "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico IS NULL AND UPPER(TRIM(COALESCE(estado,''))) != 'CANCELADA'"
                    )
                    # since podría estar bloqueando
                    os_bloqueadas_since = await db.fetchval(
                        "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico = $1 AND updated_at < $2::timestamp",
                        id_tecnico or -1, since,
                    ) if since and since.year > 2000 else 0
                    logger.warning(
                        "[SYNC PULL CERO RESULTADOS] DIAGNÓSTICO:\n"
                        "  Total OS no canceladas en BD: %s\n"
                        "  OS con id_tecnico=%s (con filtro since): %s\n"
                        "  OS con id_tecnico=%s (SIN filtro since): %s\n"
                        "  OS BLOQUEADAS por filtro since (%s): %s\n"
                        "  OS con id_tecnico NULL (huerfanas): %s\n"
                        "  OS con tecnico ILIKE '%s': %s\n"
                        "  Registro en cat_tecnicos: %s",
                        total_os, id_tecnico, os_por_id,
                        id_tecnico, os_por_id_sin_since,
                        since, os_bloqueadas_since,
                        os_null_tecnico,
                        nombre_jwt, os_por_nombre,
                        dict(tec_check) if tec_check else "NO ENCONTRADO",
                    )
                    print(
                        f"[SYNC PULL CERO] total_os={total_os} | "
                        f"os_by_id={os_por_id} | os_by_id_sin_since={os_por_id_sin_since} | "
                        f"os_bloqueadas_since={os_bloqueadas_since} | "
                        f"os_null_id_tecnico={os_null_tecnico} | "
                        f"os_by_nombre={os_por_nombre} | "
                        f"cat_tecnico={dict(tec_check) if tec_check else 'NO_ENCONTRADO'}"
                    )
                except Exception as e_diag:
                    # El bloque de diagnóstico NUNCA debe romper la respuesta principal
                    logger.warning("[SYNC PULL] Error en bloque diagnóstico (ignorado): %s", e_diag)

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

        resultado = []
        for r in rows:
            d = dict(r)
            if not is_admin and d.get("sync_check_status") == "ASIGNADA":
                d["sync_check_status"] = "RECIBIDA_TABLET"
            resultado.append(OSCompleta(**d))

        return resultado

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
                firma_tecnico         = COALESCE($13, firma_tecnico),
                firma_tecnico_b64     = COALESCE($13, firma_tecnico_b64),
                firma_cliente         = COALESCE($14, firma_cliente),
                firma_cliente_b64     = COALESCE($14, firma_cliente_b64),
                nombre_ing            = COALESCE($15, nombre_ing),
                puesto_ing            = COALESCE($16, puesto_ing),
                firma_cliente_nombre  = COALESCE($17, firma_cliente_nombre),
                dictamen              = COALESCE($18, dictamen),
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
            payload.id_equipo,
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
        )
    except Exception as e_full:
        logger.warning("UPDATE con sync_version falló (%s) — reintentando sin columnas opcionales", e_full)
        # Fallback sin sync_version / sync_at / device_id (BD sin migración)
        await db.execute(
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
            payload.id_equipo,
            payload.firma_tecnico,
            payload.firma_cliente,
            payload.nombre_ing or payload.firma_cliente_nombre,
            payload.puesto_ing,
            payload.firma_cliente_nombre or payload.nombre_ing,
            payload.dictamen,
            os_id,
        )

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

    f_tec = payload.firma_tecnico or payload.firma_tecnico_png
    f_cli = payload.firma_cliente or payload.firma_cliente_png
    nom_ing = payload.nombre_ing or payload.firma_cliente_nombre
    puesto_ing = payload.puesto_ing

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
