"""
pesa_api/routers/admin_router.py
Endpoints de administración y mantenimiento de datos.
  POST /api/v1/admin/fix-tecnicos  → Reasigna órdenes de Alan Guevara a id_tecnico=8
  GET  /api/v1/admin/check-ordenes → Diagnóstico: cuántas órdenes tiene cada técnico
"""
from __future__ import annotations

import logging
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import get_current_user, require_roles

router = APIRouter()
logger = logging.getLogger("pesa_api.admin")


class FixTecnicosResponse(BaseModel):
    ordenes_actualizadas: int
    detalle: str


class DiagOrdenesRow(BaseModel):
    id_tecnico: int | None
    nombre: str
    total_ordenes: int


# ---------------------------------------------------------------------------
# POST /api/v1/admin/fix-tecnicos
# ---------------------------------------------------------------------------
@router.post(
    "/fix-tecnicos",
    response_model=FixTecnicosResponse,
    summary="Reasignar órdenes de Alan Guevara (id=8) — solo las suyas",
)
async def fix_tecnicos(
    db=Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "administrador", "logistica")),
):
    """
    Vincula al id_tecnico=8 (Alan Guevara / Daikki19) todas las órdenes que:
      1. Tienen id_tecnico que apunta a cat_tecnicos.nombre_completo ILIKE '%alan guevara%'
      2. Tienen id_tecnico = NULL o 0 Y folio_os >= 'OS-26-550' (periodo probable)
      3. Están en la lista de folios conocidos de Alan Guevara

    Solo accesible para administradores y logística.
    """
    try:
        # 1. Reasignar por nombre en cat_tecnicos que contenga 'alan guevara'
        #    (cubre el caso donde el id_tecnico apunta a un registro diferente
        #     pero el nombre en cat_tecnicos es de Alan)
        result_nombre = await db.execute(
            """
            UPDATE ordenes_servicio os
            SET id_tecnico = 8,
                updated_at  = NOW()
            FROM cat_tecnicos tc
            WHERE tc.id = os.id_tecnico
              AND LOWER(tc.nombre_completo) ILIKE '%alan%'
              AND os.id_tecnico != 8
            """,
        )

        # 2. Reasignar por folios conocidos / rango de folio de Alan Guevara
        #    OS-26-550 en adelante que tengan id_tecnico NULL o 0
        result_null = await db.execute(
            """
            UPDATE ordenes_servicio
            SET id_tecnico = 8,
                updated_at  = NOW()
            WHERE (id_tecnico IS NULL OR id_tecnico = 0)
              AND (
                folio_os >= 'OS-26-550'
                OR folio_os LIKE 'OS-26-6%'
                OR folio_os LIKE 'OS-26-7%'
              )
            """,
        )

        # 3. Folios específicos asignados a Alan Guevara manualmente
        folios_alan = [
            'OS-26-550', 'OS-26-551', 'OS-26-552', 'OS-26-553', 'OS-26-554',
            'OS-26-555', 'OS-26-600', 'OS-26-601', 'OS-26-602', 'OS-26-610',
            'OS-26-620', 'OS-26-629', 'OS-26-630', 'OS-26-639', 'OS-26-640',
            'OS-26-641', 'OS-26-642', 'OS-26-643', 'OS-26-644', 'OS-26-645',
            'RMA-26-630',
        ]
        result_folios = await db.execute(
            """
            UPDATE ordenes_servicio
            SET id_tecnico = 8,
                updated_at  = NOW()
            WHERE folio_os = ANY($1::text[])
              AND (id_tecnico IS NULL OR id_tecnico != 8)
            """,
            folios_alan,
        )

        # Contar OS finales asignadas a id=8
        total_alan = await db.fetchval(
            "SELECT COUNT(*) FROM ordenes_servicio WHERE id_tecnico = 8 AND UPPER(TRIM(COALESCE(estado,''))) != 'CANCELADA'"
        )

        def _parse_count(r: str) -> int:
            try:
                return int(r.split()[-1])
            except Exception:
                return 0

        actualizadas = (
            _parse_count(result_nombre)
            + _parse_count(result_null)
            + _parse_count(result_folios)
        )

        detalle = (
            f"Por nombre alan en cat_tecnicos: {_parse_count(result_nombre)} | "
            f"Por folio>=OS-26-550 sin técnico: {_parse_count(result_null)} | "
            f"Por folios específicos: {_parse_count(result_folios)} | "
            f"Total OS activas de Alan (id=8): {total_alan}"
        )

        logger.info(
            "[ADMIN fix-tecnicos] %s — ejecutado por %s",
            detalle, current_user.get("username"),
        )
        print(f"[ADMIN fix-tecnicos] {detalle}")

        return FixTecnicosResponse(
            ordenes_actualizadas=actualizadas,
            detalle=detalle,
        )

    except Exception as exc:
        logger.error("[ADMIN fix-tecnicos] Error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al reasignar técnicos: {exc}",
        ) from exc



# ---------------------------------------------------------------------------
# GET /api/v1/admin/check-ordenes
# ---------------------------------------------------------------------------
@router.get(
    "/check-ordenes",
    summary="Diagnóstico: conteo de órdenes por técnico",
)
async def check_ordenes(
    db=Depends(get_db),
    current_user: dict = Depends(require_roles("admin", "administrador", "logistica")),
):
    """
    Retorna cuántas órdenes tiene asignadas cada técnico en la BD.
    Útil para verificar que el fix-tecnicos funcionó correctamente.
    """
    rows = await db.fetch(
        """
        SELECT
            os.id_tecnico,
            COALESCE(tc.nombre_completo, 'SIN TÉCNICO') AS nombre,
            COUNT(os.id) AS total_ordenes
        FROM ordenes_servicio os
        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
        WHERE os.estado NOT IN ('CANCELADA')
        GROUP BY os.id_tecnico, tc.nombre_completo
        ORDER BY total_ordenes DESC
        """,
    )
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# GET /api/admin/catalogos y /api/v1/admin/catalogos
# ---------------------------------------------------------------------------
def _fmt_div_min_str(raw_val) -> str:
    if raw_val is None:
        return ""
    import re
    s = str(raw_val).strip()
    if not s:
        return ""
    m = re.match(r"^([+-]?\d+(?:[.,]\d+)?)\s*(.*)$", s)
    if not m:
        return s
    try:
        val = float(m.group(1).replace(",", "."))
    except ValueError:
        return s
    unidad = m.group(2).strip()
    limpio = f"{val:.6f}".rstrip("0").rstrip(".")
    return f"{limpio} {unidad}".strip() if unidad else limpio


@router.get(
    "/catalogos",
    summary="Catálogos completos para paridad Admin en Android (clientes, sucursales, técnicos e historial de instrumentos)",
)
async def obtener_catalogos_admin(
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Devuelve la lista completa y actualizada de:
    - clientes (con todas sus sucursales/direcciones anidadas)
    - sucursales (lista plana de todas las sucursales/direcciones activas)
    - tecnicos activos
    - tipos_servicio y tipos_instrumento
    - historial_instrumentos (combinaciones únicas de cliente, sucursal, marca, modelo,
      serie, id_indicador, capacidad_maxima, division_minima y ubicacion para autocompletado)
    """
    # 1. Clientes activos
    clientes_list: list[dict] = []
    try:
        rows_cli = await db.fetch(
            """
            SELECT id,
                   razon_social,
                   razon_social AS nombre,
                   COALESCE(rfc, '') AS rfc,
                   COALESCE(telefono, '') AS telefono,
                   COALESCE(direccion, '') AS direccion,
                   COALESCE(activo, TRUE) AS activo
            FROM cat_clientes
            WHERE activo IS NOT FALSE
            ORDER BY razon_social ASC
            """
        )
        clientes_list = [dict(r) for r in rows_cli]
    except Exception:
        rows_cli = await db.fetch(
            """
            SELECT id, razon_social, razon_social AS nombre, COALESCE(direccion, '') AS direccion, COALESCE(activo, TRUE) AS activo
            FROM cat_clientes
            WHERE activo IS NOT FALSE
            ORDER BY razon_social ASC
            """
        )
        clientes_list = [
            {
                "id": r["id"],
                "nombre": r["razon_social"],
                "razon_social": r["razon_social"],
                "rfc": "",
                "telefono": "",
                "direccion": r["direccion"] or "",
                "activo": bool(r["activo"]),
            }
            for r in rows_cli
        ]

    # 2. Sucursales / Direcciones por cliente
    sucursales_list: list[dict] = []
    suc_by_cliente: dict[int, list[dict]] = {}
    try:
        rows_suc = await db.fetch(
            """
            SELECT cs.id,
                   cs.cliente_id,
                   COALESCE(cc.razon_social, '') AS cliente_nombre,
                   COALESCE(cs.nombre_sucursal, '') AS nombre_sucursal,
                   COALESCE(cs.direccion, '') AS direccion,
                   COALESCE(cs.contacto_nombre, '') AS contacto_nombre,
                   COALESCE(cs.contacto_telefono, '') AS contacto_telefono
            FROM cliente_sucursales cs
            LEFT JOIN cat_clientes cc ON cc.id = cs.cliente_id
            WHERE cs.activo IS NOT FALSE
            ORDER BY cc.razon_social ASC, cs.nombre_sucursal ASC
            """
        )
        for r in rows_suc:
            sd = dict(r)
            sucursales_list.append(sd)
            cid = sd.get("cliente_id")
            if cid is not None:
                suc_by_cliente.setdefault(int(cid), []).append(sd)
    except Exception as exc_s:
        logger.warning("[ADMIN catalogos] cliente_sucursales fallback: %s", exc_s)

    for cli in clientes_list:
        cid = int(cli["id"])
        cli["sucursales"] = suc_by_cliente.get(cid, [])

    # 3. Técnicos activos
    tecnicos_list: list[dict] = []
    try:
        rows_tec = await db.fetch(
            """
            SELECT id,
                   nombre_completo,
                   COALESCE(usuario, '') AS usuario,
                   COALESCE(rol, 'Técnico') AS rol,
                   COALESCE(activo, TRUE) AS activo
            FROM cat_tecnicos
            WHERE activo IS NOT FALSE
            ORDER BY nombre_completo ASC
            """
        )
        tecnicos_list = [dict(r) for r in rows_tec]
    except Exception as exc_t:
        logger.warning("[ADMIN catalogos] cat_tecnicos error: %s", exc_t)

    # 4. Tipos de servicio y tipos de instrumento
    tipos_servicio_list: list[dict] = []
    try:
        rows_ts = await db.fetch("SELECT id, nombre, COALESCE(descripcion, '') AS descripcion FROM cat_tipo_servicio ORDER BY id ASC")
        tipos_servicio_list = [dict(r) for r in rows_ts]
    except Exception:
        pass

    tipos_inst_list: list[dict] = []
    try:
        rows_ti = await db.fetch("SELECT id, nombre, COALESCE(descripcion, '') AS descripcion FROM cat_tipo_instrumento ORDER BY nombre ASC")
        tipos_inst_list = [dict(r) for r in rows_ti]
    except Exception:
        pass

    # 5. Historial consolidado de instrumentos (cliente_equipos + ordenes_servicio)
    invalidos = {"", "none", "null", "sin id", "sin modelo", "sin serie", "n/a", "na", "--"}

    def _clean(val) -> str:
        s = str(val or "").strip()
        return "" if s.lower() in invalidos else s

    seen_keys: set[tuple] = set()
    historial: list[dict] = []

    def _add_inst(
        cliente_id, cliente, sucursal_id, sucursal,
        marca, modelo, serie, id_indicador, cap, div, ubicacion, tipo_inst
    ):
        m = _clean(marca)
        mod = _clean(modelo)
        sn = _clean(serie)
        idi = _clean(id_indicador)
        ub = _clean(ubicacion)
        if not (m or mod or sn or idi):
            return
        cid_i = int(cliente_id) if cliente_id is not None and str(cliente_id).isdigit() else None
        sid_i = int(sucursal_id) if sucursal_id is not None and str(sucursal_id).isdigit() else None
        key = (
            cid_i or 0,
            sid_i or 0,
            m.lower(),
            mod.lower(),
            sn.lower(),
            idi.lower(),
        )
        if key in seen_keys:
            return
        seen_keys.add(key)
        cap_s = _clean(cap)
        div_s = _fmt_div_min_str(div) if _clean(div) else ""
        historial.append({
            "cliente_id": cid_i,
            "cliente": _clean(cliente),
            "sucursal_id": sid_i,
            "sucursal": _clean(sucursal),
            "marca": m,
            "modelo": mod,
            "serie": sn,
            "id_indicador": idi,
            "capacidad_maxima": cap_s,
            "division_minima": div_s,
            "ubicacion": ub,
            "tipo_instrumento": _clean(tipo_inst),
        })

    # 5a. Desde cliente_equipos (catálogo maestro por sucursal)
    try:
        rows_eq = await db.fetch(
            """
            SELECT cs.cliente_id,
                   COALESCE(cc.razon_social, '') AS cliente,
                   ce.sucursal_id,
                   COALESCE(cs.nombre_sucursal, '') AS sucursal,
                   COALESCE(ce.marca, '') AS marca,
                   COALESCE(ce.modelo, '') AS modelo,
                   COALESCE(ce.numero_serie, '') AS serie,
                   COALESCE(ce.id_indicador_equipo, '') AS id_indicador,
                   COALESCE(ce.capacidad_maxima::text, '') AS capacidad_maxima,
                   COALESCE(ce.division_minima::text, '') AS division_minima,
                   COALESCE(ce.ubicacion_interna, '') AS ubicacion,
                   COALESCE(ce.tipo_instrumento, '') AS tipo_instrumento
            FROM cliente_equipos ce
            LEFT JOIN cliente_sucursales cs ON cs.id = ce.sucursal_id
            LEFT JOIN cat_clientes cc ON cc.id = cs.cliente_id
            WHERE ce.activo IS NOT FALSE
            ORDER BY ce.id DESC
            LIMIT 2500
            """
        )
        for r in rows_eq:
            _add_inst(
                r["cliente_id"], r["cliente"], r["sucursal_id"], r["sucursal"],
                r["marca"], r["modelo"], r["serie"], r["id_indicador"],
                r["capacidad_maxima"], r["division_minima"], r["ubicacion"], r["tipo_instrumento"],
            )
    except Exception as exc_eq:
        logger.warning("[ADMIN catalogos] cliente_equipos fallback: %s", exc_eq)

    # 5b. Desde ordenes_servicio históricas
    try:
        rows_os_eq = await db.fetch(
            """
            SELECT os.id_cliente AS cliente_id,
                   COALESCE(cc.razon_social, os.cliente, '') AS cliente,
                   os.sucursal_id,
                   COALESCE(cs.nombre_sucursal, '') AS sucursal,
                   COALESCE(os.marca, '') AS marca,
                   COALESCE(os.modelo, '') AS modelo,
                   COALESCE(os.ns, '') AS serie,
                   COALESCE(os.id_equipo::text, '') AS id_indicador,
                   COALESCE(NULLIF(TRIM(os.instrumento_capacidad), ''), os.alcance_max::text, '') AS capacidad_maxima,
                   COALESCE(NULLIF(TRIM(os.instrumento_division), ''), os.div_minima::text, '') AS division_minima,
                   COALESCE(os.ubicacion, '') AS ubicacion,
                   COALESCE(ti.nombre, '') AS tipo_instrumento
            FROM ordenes_servicio os
            LEFT JOIN cat_clientes cc ON cc.id = os.id_cliente
            LEFT JOIN cliente_sucursales cs ON cs.id = os.sucursal_id
            LEFT JOIN cat_tipo_instrumento ti ON ti.id = os.id_tipo_instrumento
            WHERE (COALESCE(TRIM(os.marca), '') <> ''
               OR COALESCE(TRIM(os.modelo), '') <> ''
               OR COALESCE(TRIM(os.ns), '') <> ''
               OR COALESCE(TRIM(os.id_equipo::text), '') <> '')
              AND COALESCE(UPPER(TRIM(os.estado)), '') <> 'CANCELADA'
            ORDER BY os.updated_at DESC NULLS LAST, os.id DESC
            LIMIT 2500
            """
        )
        for r in rows_os_eq:
            _add_inst(
                r["cliente_id"], r["cliente"], r["sucursal_id"], r["sucursal"],
                r["marca"], r["modelo"], r["serie"], r["id_indicador"],
                r["capacidad_maxima"], r["division_minima"], r["ubicacion"], r["tipo_instrumento"],
            )
    except Exception as exc_os_eq:
        logger.warning("[ADMIN catalogos] ordenes_servicio historial fallback: %s", exc_os_eq)

    return {
        "clientes": clientes_list,
        "sucursales": sucursales_list,
        "tecnicos": tecnicos_list,
        "tipos_servicio": tipos_servicio_list,
        "tipos_instrumento": tipos_inst_list,
        "historial_instrumentos": historial,
    }
