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
from typing import Any, Dict, List, Optional, Union

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, UploadFile, Request, status
from pydantic import BaseModel

from pesa_api.core.config import settings
from pesa_api.core.database import get_db
from pesa_api.core.security import (
    get_current_user,
    get_optional_user,
    id_tecnico_de,
    require_roles,
    tiene_visibilidad_global,
    verificar_acceso_os,
)

logger = logging.getLogger("pesa_api.catalogos")
router = APIRouter()


# ── Schemas ────────────────────────────────────────────────────────────────────

class ClienteOut(BaseModel):
    id:                 int
    nombre:             str        # alias de razon_social
    razon_social:       str
    correo:             Optional[str] = ""
    email:              Optional[str] = ""
    correos_frecuentes: List[str] = []
    rfc:                Optional[str] = None
    telefono:           Optional[str] = None
    direccion:          Optional[str] = None
    activo:             bool = True
    sucursales:         List[Dict[str, Any]] = []


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
    tipo:                    str = "Individual"   # Individual | Lote
    modalidad:               str = "Digital"      # Digital | Físico
    tipo_documento:          Optional[str] = None # OS | RMA | RE | OSOB | OSOCC | LV | LP
    id_cliente:              Optional[int] = None
    sucursal_id:             Optional[int] = None
    sucursal:                Optional[str] = None
    direccion:               Optional[str] = None
    id_tecnico:              Optional[int] = None
    id_tipo_servicio:        Optional[int] = None
    id_tipo_instrumento:     Optional[int] = None
    tipo_instrumento:        Optional[str] = None
    fecha:                   Optional[str] = None
    observaciones:           Optional[str] = None
    cantidad:                int = 1              # Solo para lote
    # Datos parciales o completos del instrumento (asignación temporal o completa)
    marca:                   Optional[str] = None
    modelo:                  Optional[str] = None
    serie:                   Optional[str] = None
    ns:                      Optional[str] = None
    id_indicador:            Optional[str] = None
    id_equipo:               Optional[str] = None
    capacidad_maxima:        Optional[Union[float, str]] = None
    division_minima:         Optional[Union[float, str]] = None
    ubicacion:               Optional[str] = None
    numero_cca:              Optional[str] = None
    numero_dve:              Optional[str] = None
    aplica_excentricidad:    Optional[bool] = True
    motivo_no_excentricidad: Optional[str] = None
    unidad_medida:           Optional[str] = "kg"
    correo_destino:          Optional[str] = None
    correo_cliente:          Optional[str] = None


class ActualizarInstrumentoBody(BaseModel):
    marca:                   Optional[str] = None
    modelo:                  Optional[str] = None
    serie:                   Optional[str] = None
    ns:                      Optional[str] = None
    id_indicador:            Optional[str] = None
    id_equipo:               Optional[str] = None
    capacidad_maxima:        Optional[Union[float, str]] = None
    alcance_max:             Optional[Union[float, str]] = None
    division_minima:         Optional[Union[float, str]] = None
    div_minima:              Optional[Union[float, str]] = None
    ubicacion:               Optional[str] = None
    tipo_instrumento:        Optional[str] = None
    numero_cca:              Optional[str] = None
    cca:                     Optional[str] = None
    numero_dve:              Optional[str] = None
    folio_dve:               Optional[str] = None
    aplica_excentricidad:    Optional[bool] = None
    motivo_no_excentricidad: Optional[str] = None
    unidad_medida:           Optional[str] = None
    holograma_anterior:      Optional[str] = None
    holograma_actualizado:   Optional[str] = None
    sucursal_id:             Optional[int] = None
    estatus:                 Optional[str] = None
    correo_destino:          Optional[str] = None
    correo_cliente:          Optional[str] = None
    sin_correo_cliente:      Optional[bool] = None
    motivo_sin_correo:       Optional[str] = None


def _limpiar_num_reg(val: Optional[str]) -> str:
    import re
    s = str(val or "").strip()
    if not s or s.lower() in {"none", "null", "n/a", "na", "--", "-"}:
        return ""
    if re.match(r"^(CCA|DVE)\.\d{2}\.?$", s, flags=re.IGNORECASE):
        return ""
    return s


def _norm_div_min_str(raw_val) -> str:
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


def _parse_float_opt(raw_val) -> Optional[float]:
    if raw_val is None:
        return None
    import re
    s = str(raw_val).strip()
    if not s:
        return None
    m = re.match(r"^([+-]?\d+(?:[.,]\d+)?)", s)
    if not m:
        return None
    try:
        return float(m.group(1).replace(",", "."))
    except ValueError:
        return None


def _construir_etiqueta_instrumento_dict(orden: dict) -> str:
    folio = str(orden.get("folio") or orden.get("folio_os") or "").strip()
    invalidos = {"", "none", "null", "sin id", "sin modelo", "sin serie", "n/a", "na", "--"}
    partes = [folio] if folio else []
    for aliases in (
        ("marca",),
        ("modelo",),
        ("serie", "ns"),
        ("id_indicador", "id_equipo"),
        ("ubicacion",),
    ):
        val = ""
        for k in aliases:
            cand = str(orden.get(k) or "").strip()
            if cand and cand.lower() not in invalidos:
                val = cand
                break
        if val:
            partes.append(val)
    return " - ".join(partes)


# ── Catálogos ──────────────────────────────────────────────────────────────────

_EMAIL_VALID_RE = None


def _extraer_correos_validos_lista(raw_val: Any) -> list[str]:
    """Extrae correos válidos deduplicados separando por coma/punto y coma y excluyendo remitentes internos."""
    global _EMAIL_VALID_RE
    import re
    if _EMAIL_VALID_RE is None:
        _EMAIL_VALID_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")
    if not raw_val:
        return []
    partes = re.split(r"[,;\s]+", str(raw_val).strip())
    excluidos = {
        "ivancolin1207@gmail.com",
        "recepcion@basculaspesa.com.mx",
    }
    vistos: set[str] = set()
    salida: list[str] = []
    for p in partes:
        cand = p.strip().strip("<>\"'()")
        low = cand.lower()
        if not cand or low in excluidos or low.startswith("pendiente"):
            continue
        if _EMAIL_VALID_RE.match(cand) and low not in vistos:
            vistos.add(low)
            salida.append(cand)
    return salida


async def obtener_clientes_con_sucursales_reales(
    db,
    activo: Optional[bool] = True,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """
    Consulta exactamente las tablas reales de PostgreSQL usadas por el .exe de Windows
    (cat_clientes + cliente_sucursales), deduplicando registros repetidos y garantizando
    que cada cliente incluya sus llaves estándar:
      {id, nombre, razon_social, correo, email, rfc, telefono, direccion, activo, sucursales}
    y cada sucursal incluya:
      {id, sucursal_id, cliente_id, cliente_nombre, nombre, nombre_sucursal, planta,
       direccion, correo, contacto, contacto_nombre, telefono, contacto_telefono, activo}.
    Si un cliente tiene dirección en cat_clientes.direccion y no está repetida en
    cliente_sucursales, se incorpora automáticamente a su lista `sucursales`.
    """
    if activo is True:
        where_cli = "WHERE activo IS NOT FALSE"
    elif activo is False:
        where_cli = "WHERE activo = FALSE"
    else:
        where_cli = ""

    try:
        rows_cli = await db.fetch(
            f"""
            SELECT DISTINCT ON (id)
                   id,
                   COALESCE(razon_social, '')   AS razon_social,
                   COALESCE(direccion, '')      AS direccion,
                   COALESCE(municipio, '')      AS municipio,
                   COALESCE(estado_rep, '')     AS estado_rep,
                   COALESCE(codigo_postal, '')  AS codigo_postal,
                   COALESCE(telefono, '')       AS telefono,
                   COALESCE(email, '')          AS email,
                   COALESCE(rfc, '')            AS rfc,
                   COALESCE(contacto_nombre,'') AS contacto_nombre,
                   COALESCE(activo, TRUE)       AS activo
            FROM cat_clientes
            {where_cli}
            ORDER BY id ASC
            """
        )
    except Exception as exc_cli:
        logger.warning("[CLIENTES] Fallback consulta cat_clientes: %s", exc_cli)
        rows_cli = await db.fetch(
            f"""
            SELECT DISTINCT ON (id)
                   id,
                   COALESCE(razon_social, '') AS razon_social,
                   COALESCE(direccion, '')    AS direccion,
                   '' AS municipio, '' AS estado_rep, '' AS codigo_postal,
                   COALESCE(telefono, '')     AS telefono,
                   '' AS email,
                   COALESCE(rfc, '')          AS rfc,
                   '' AS contacto_nombre,
                   COALESCE(activo, TRUE)     AS activo
            FROM cat_clientes
            {where_cli}
            ORDER BY id ASC
            """
        )

    # Agrupar clientes por razon_social normalizada (igual que batch_generator_widget.py en Windows)
    # conservando el mapeo de todos los IDs duplicados hacia el cliente canónico.
    canonical_by_norm: dict[str, dict[str, Any]] = {}
    id_to_canonical_id: dict[int, int] = {}

    for r in rows_cli:
        cid = int(r["id"])
        razon = str(r["razon_social"] or "").strip()
        if not razon:
            continue
        norm_name = " ".join(razon.lower().split())

        dir_base = str(r["direccion"] or "").strip()
        muni = str(r["municipio"] or "").strip()
        edo = str(r["estado_rep"] or "").strip()
        cp = str(r["codigo_postal"] or "").strip()
        if not dir_base and (muni or edo or cp):
            dir_base = ", ".join(p for p in (muni, edo, f"C.P. {cp}" if cp else "") if p)

        correo_c = str(r["email"] or "").strip()
        rfc_c = str(r["rfc"] or "").strip()
        tel_c = str(r["telefono"] or "").strip()
        cont_c = str(r["contacto_nombre"] or "").strip()

        if norm_name not in canonical_by_norm:
            canonical_by_norm[norm_name] = {
                "id": cid,
                "nombre": razon,
                "razon_social": razon,
                "correo": correo_c,
                "email": correo_c,
                "rfc": rfc_c,
                "telefono": tel_c,
                "direccion": dir_base,
                "contacto_nombre": cont_c,
                "activo": bool(r["activo"]),
                "_all_dirs": [dir_base] if dir_base else [],
                "sucursales": [],
            }
            id_to_canonical_id[cid] = cid
        else:
            canon = canonical_by_norm[norm_name]
            id_to_canonical_id[cid] = int(canon["id"])
            if not canon["correo"] and correo_c:
                canon["correo"] = correo_c
                canon["email"] = correo_c
            if not canon["rfc"] and rfc_c:
                canon["rfc"] = rfc_c
            if not canon["telefono"] and tel_c:
                canon["telefono"] = tel_c
            if not canon["direccion"] and dir_base:
                canon["direccion"] = dir_base
            if dir_base and dir_base not in canon["_all_dirs"]:
                canon["_all_dirs"].append(dir_base)

    canon_by_id: dict[int, dict[str, Any]] = {int(c["id"]): c for c in canonical_by_norm.values()}
    seen_suc_per_cli: dict[int, set[tuple[str, str]]] = {cid: set() for cid in canon_by_id}
    flat_sucursales: list[dict[str, Any]] = []

    try:
        rows_suc = await db.fetch(
            """
            SELECT DISTINCT ON (cs.id)
                   cs.id,
                   cs.cliente_id,
                   COALESCE(cs.nombre_sucursal, '')   AS nombre_sucursal,
                   COALESCE(cs.direccion, '')         AS direccion,
                   COALESCE(cs.contacto_nombre, '')   AS contacto_nombre,
                   COALESCE(cs.contacto_telefono, '') AS contacto_telefono,
                   COALESCE(cs.email, '')             AS email,
                   COALESCE(cs.activo, TRUE)          AS activo
            FROM cliente_sucursales cs
            WHERE cs.activo IS NOT FALSE
            ORDER BY cs.id ASC
            """
        )
    except Exception:
        try:
            rows_suc = await db.fetch(
                """
                SELECT DISTINCT ON (cs.id)
                       cs.id,
                       cs.cliente_id,
                       COALESCE(cs.nombre_sucursal, '')   AS nombre_sucursal,
                       COALESCE(cs.direccion, '')         AS direccion,
                       COALESCE(cs.contacto_nombre, '')   AS contacto_nombre,
                       COALESCE(cs.contacto_telefono, '') AS contacto_telefono,
                       '' AS email,
                       COALESCE(cs.activo, TRUE)          AS activo
                FROM cliente_sucursales cs
                WHERE cs.activo IS NOT FALSE
                ORDER BY cs.id ASC
                """
            )
        except Exception as exc_s2:
            logger.warning("[CLIENTES] Error consultando cliente_sucursales: %s", exc_s2)
            rows_suc = []

    for rs in rows_suc:
        raw_cid = rs["cliente_id"]
        if raw_cid is None:
            continue
        target_cid = id_to_canonical_id.get(int(raw_cid), int(raw_cid))
        cli_obj = canon_by_id.get(target_cid)
        cli_nom = str(cli_obj["razon_social"]) if cli_obj else ""

        snom = str(rs["nombre_sucursal"] or "").strip()
        sdir = str(rs["direccion"] or "").strip()
        if not snom and not sdir:
            continue
        effective_nom = snom or sdir
        effective_dir = sdir or snom
        dedup_key = (effective_nom.lower(), effective_dir.lower())
        if target_cid in seen_suc_per_cli and dedup_key in seen_suc_per_cli[target_cid]:
            continue
        seen_suc_per_cli.setdefault(target_cid, set()).add(dedup_key)

        scorr = str(rs["email"] or (cli_obj["correo"] if cli_obj else "") or "").strip()
        scont = str(rs["contacto_nombre"] or "").strip()
        stel = str(rs["contacto_telefono"] or "").strip()
        sid = int(rs["id"])

        suc_entry = {
            "id": sid,
            "sucursal_id": sid,
            "cliente_id": target_cid,
            "cliente_nombre": cli_nom,
            "nombre": effective_nom,
            "nombre_sucursal": effective_nom,
            "planta": effective_nom,
            "direccion": effective_dir,
            "correo": scorr,
            "contacto": scont,
            "contacto_nombre": scont,
            "telefono": stel,
            "contacto_telefono": stel,
            "activo": bool(rs["activo"]),
        }
        flat_sucursales.append(suc_entry)
        if cli_obj is not None:
            cli_obj["sucursales"].append(suc_entry)

    # Incluir direcciones guardadas directamente en cat_clientes.direccion cuando no existan ya en cliente_sucursales
    for cid, cli_obj in canon_by_id.items():
        existing_dirs = {
            str(s.get("direccion") or "").strip().lower()
            for s in cli_obj["sucursales"]
            if str(s.get("direccion") or "").strip()
        } | {
            str(s.get("nombre") or "").strip().lower()
            for s in cli_obj["sucursales"]
            if str(s.get("nombre") or "").strip()
        }
        for idx_d, d_txt in enumerate(cli_obj.pop("_all_dirs", [])):
            d_clean = d_txt.strip()
            if not d_clean or d_clean.lower() in existing_dirs:
                continue
            existing_dirs.add(d_clean.lower())
            planta_lbl = "Matriz / Principal" if idx_d == 0 and not cli_obj["sucursales"] else d_clean
            fallback_suc = {
                "id": None,
                "sucursal_id": None,
                "cliente_id": cid,
                "cliente_nombre": cli_obj["razon_social"],
                "nombre": d_clean if len(d_clean) <= 80 else planta_lbl,
                "nombre_sucursal": planta_lbl,
                "planta": planta_lbl,
                "direccion": d_clean,
                "correo": cli_obj["correo"],
                "contacto": cli_obj.get("contacto_nombre", ""),
                "contacto_nombre": cli_obj.get("contacto_nombre", ""),
                "telefono": cli_obj["telefono"],
                "contacto_telefono": cli_obj["telefono"],
                "activo": True,
            }
            cli_obj["sucursales"].append(fallback_suc)
            flat_sucursales.append(fallback_suc)

        cli_obj["sucursales"].sort(key=lambda s: str(s.get("nombre") or "").lower())

    # Enriquecer clientes y sucursales con correos_frecuentes reales deduplicados
    # (cat_clientes.email + cliente_sucursales.email + últimos correos enviados en ordenes_servicio)
    hist_por_cid: dict[int, list[str]] = {}
    hist_por_nom: dict[str, list[str]] = {}
    hist_por_suc: dict[int, list[str]] = {}
    try:
        rows_hist_mail = await db.fetch(
            """
            SELECT id_cliente,
                   sucursal_id,
                   COALESCE(TRIM(cliente), '') AS cliente_txt,
                   COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) AS correo_raw
            FROM ordenes_servicio
            WHERE COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) LIKE '%@%'
            ORDER BY fecha_envio_correo DESC NULLS LAST, updated_at DESC NULLS LAST, id DESC
            LIMIT 1500
            """
        )
        for rm in rows_hist_mail:
            validos = _extraer_correos_validos_lista(rm["correo_raw"])
            if not validos:
                continue
            raw_c = rm["id_cliente"]
            if raw_c is not None:
                c_canon = id_to_canonical_id.get(int(raw_c), int(raw_c))
                lst_c = hist_por_cid.setdefault(c_canon, [])
                for em in validos:
                    if em.lower() not in {x.lower() for x in lst_c} and len(lst_c) < 8:
                        lst_c.append(em)
            c_txt = " ".join(str(rm["cliente_txt"] or "").lower().split())
            if c_txt:
                lst_n = hist_por_nom.setdefault(c_txt, [])
                for em in validos:
                    if em.lower() not in {x.lower() for x in lst_n} and len(lst_n) < 8:
                        lst_n.append(em)
            raw_s = rm["sucursal_id"]
            if raw_s is not None:
                sid_m = int(raw_s)
                lst_s = hist_por_suc.setdefault(sid_m, [])
                for em in validos:
                    if em.lower() not in {x.lower() for x in lst_s} and len(lst_s) < 6:
                        lst_s.append(em)
    except Exception as exc_hm:
        logger.debug("[CLIENTES] Historial de correos frecuentes omitido: %s", exc_hm)

    for cid, cli_obj in canon_by_id.items():
        frec_cli: list[str] = []
        seen_frec: set[str] = set()

        def _push_mail(val_str: Any):
            for em in _extraer_correos_validos_lista(val_str):
                if em.lower() not in seen_frec and len(frec_cli) < 8:
                    seen_frec.add(em.lower())
                    frec_cli.append(em)

        _push_mail(cli_obj.get("correo"))
        for s in cli_obj["sucursales"]:
            _push_mail(s.get("correo"))
        for em in hist_por_cid.get(cid, []):
            _push_mail(em)
        norm_c = " ".join(str(cli_obj.get("razon_social") or "").lower().split())
        for em in hist_por_nom.get(norm_c, []):
            _push_mail(em)

        cli_obj["correos_frecuentes"] = frec_cli
        if not cli_obj.get("correo") and frec_cli:
            cli_obj["correo"] = frec_cli[0]
            cli_obj["email"] = frec_cli[0]

        for s in cli_obj["sucursales"]:
            frec_s: list[str] = []
            seen_s: set[str] = set()
            for em in _extraer_correos_validos_lista(s.get("correo")):
                if em.lower() not in seen_s:
                    seen_s.add(em.lower())
                    frec_s.append(em)
            sid_v = s.get("id")
            if sid_v is not None:
                for em in hist_por_suc.get(int(sid_v), []):
                    if em.lower() not in seen_s and len(frec_s) < 6:
                        seen_s.add(em.lower())
                        frec_s.append(em)
            for em in frec_cli:
                if em.lower() not in seen_s and len(frec_s) < 6:
                    seen_s.add(em.lower())
                    frec_s.append(em)
            s["correos_frecuentes"] = frec_s
            if not s.get("correo") and frec_s:
                s["correo"] = frec_s[0]

    clientes_sorted = sorted(canon_by_id.values(), key=lambda c: str(c["razon_social"]).lower())
    flat_sucursales.sort(key=lambda s: (str(s.get("cliente_nombre") or "").lower(), str(s.get("nombre") or "").lower()))
    return clientes_sorted, flat_sucursales


@router.get(
    "/clientes/{cliente_id}/correos",
    summary="Obtener correos frecuentes deduplicados de un cliente/sucursal",
    tags=["Catálogos"],
)
async def obtener_correos_frecuentes_cliente(
    cliente_id: int,
    sucursal_id: Optional[int] = None,
    cliente_nombre: Optional[str] = None,
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Devuelve la lista deduplicada de correos frecuentes del cliente (cat_clientes.email,
    cliente_sucursales.email y los últimos correos enviados en ordenes_servicio).
    """
    from pesa_api.core.email_service import _ensure_email_columns
    await _ensure_email_columns(db)

    vistos: set[str] = set()
    frecuentes: list[str] = []

    def _agregar(raw_v: Any):
        for em in _extraer_correos_validos_lista(raw_v):
            if em.lower() not in vistos and len(frecuentes) < 10:
                vistos.add(em.lower())
                frecuentes.append(em)

    razon_lookup = (cliente_nombre or "").strip()
    if cliente_id > 0:
        try:
            r_cli = await db.fetchrow(
                "SELECT COALESCE(razon_social, '') AS razon_social, COALESCE(email, '') AS email FROM cat_clientes WHERE id = $1 LIMIT 1",
                cliente_id,
            )
            if r_cli:
                if not razon_lookup and r_cli["razon_social"]:
                    razon_lookup = str(r_cli["razon_social"]).strip()
                if sucursal_id is None:
                    _agregar(r_cli["email"])
        except Exception:
            pass

    if sucursal_id and sucursal_id > 0:
        try:
            r_suc = await db.fetchrow(
                "SELECT COALESCE(email, '') AS email FROM cliente_sucursales WHERE id = $1 LIMIT 1",
                sucursal_id,
            )
            if r_suc:
                _agregar(r_suc["email"])
            rows_os_suc = await db.fetch(
                """
                SELECT COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) AS correo
                FROM ordenes_servicio
                WHERE sucursal_id = $1
                  AND COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) LIKE '%@%'
                ORDER BY fecha_envio_correo DESC NULLS LAST, updated_at DESC NULLS LAST, id DESC
                LIMIT 20
                """,
                sucursal_id,
            )
            for rs in rows_os_suc:
                _agregar(rs["correo"])
        except Exception:
            pass

    if cliente_id > 0:
        try:
            r_cli2 = await db.fetchrow("SELECT COALESCE(email, '') AS email FROM cat_clientes WHERE id = $1 LIMIT 1", cliente_id)
            if r_cli2:
                _agregar(r_cli2["email"])
            rows_sucs = await db.fetch(
                "SELECT COALESCE(email, '') AS email FROM cliente_sucursales WHERE cliente_id = $1 AND activo IS NOT FALSE",
                cliente_id,
            )
            for rs in rows_sucs:
                _agregar(rs["email"])
            rows_os_cli = await db.fetch(
                """
                SELECT COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) AS correo
                FROM ordenes_servicio
                WHERE id_cliente = $1
                  AND COALESCE(NULLIF(TRIM(correo_destino), ''), NULLIF(TRIM(correo_cliente), '')) LIKE '%@%'
                ORDER BY fecha_envio_correo DESC NULLS LAST, updated_at DESC NULLS LAST, id DESC
                LIMIT 30
                """,
                cliente_id,
            )
            for ro in rows_os_cli:
                _agregar(ro["correo"])
        except Exception:
            pass

    if razon_lookup:
        try:
            rows_os_nom = await db.fetch(
                """
                SELECT COALESCE(NULLIF(TRIM(os.correo_destino), ''), NULLIF(TRIM(os.correo_cliente), '')) AS correo
                FROM ordenes_servicio os
                LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
                WHERE (LOWER(TRIM(COALESCE(os.cliente, ''))) = LOWER(TRIM($1))
                       OR LOWER(TRIM(COALESCE(cl.razon_social, ''))) = LOWER(TRIM($1)))
                  AND COALESCE(NULLIF(TRIM(os.correo_destino), ''), NULLIF(TRIM(os.correo_cliente), '')) LIKE '%@%'
                ORDER BY os.fecha_envio_correo DESC NULLS LAST, os.updated_at DESC NULLS LAST, os.id DESC
                LIMIT 30
                """,
                razon_lookup,
            )
            for rn in rows_os_nom:
                _agregar(rn["correo"])
        except Exception:
            pass

    return {
        "cliente_id": cliente_id,
        "cliente": razon_lookup,
        "correos_frecuentes": frecuentes,
        "correo_principal": frecuentes[0] if frecuentes else "",
    }


@router.get(
    "/clientes",
    response_model=list[ClienteOut],
    summary="Listar clientes con sus direcciones y sucursales",
    tags=["Catálogos"],
)
async def listar_clientes(
    activo: Optional[bool] = True,
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    """
    Retorna todos los clientes de cat_clientes junto con sus sucursales/direcciones
    reales de cliente_sucursales y cat_clientes.direccion.
    """
    try:
        clientes_list, _ = await obtener_clientes_con_sucursales_reales(db, activo=activo)
        return clientes_list
    except Exception as exc:
        logger.error("[GET /clientes] Error al consultar clientes+direcciones: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=500,
            detail=f"Error al consultar catálogo de clientes: {exc}",
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
        SELECT DISTINCT ON (id)
               id,
               nombre_completo,
               COALESCE(usuario, '') AS usuario,
               rol,
               COALESCE(activo, TRUE) AS activo
        FROM cat_tecnicos
        WHERE activo IS NOT FALSE
        ORDER BY id, nombre_completo ASC
        """
    )
    return sorted([dict(r) for r in rows], key=lambda r: str(r.get("nombre_completo") or "").lower())


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
        SELECT DISTINCT ON (id) id, nombre, descripcion
        FROM cat_tipo_servicio
        ORDER BY id ASC
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
    try:
        rows = await db.fetch(
            "SELECT DISTINCT ON (id) id, nombre, descripcion FROM cat_tipo_instrumento ORDER BY id, nombre ASC"
        )
    except Exception:
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
    return sorted([dict(r) for r in rows], key=lambda r: str(r.get("nombre") or "").lower())


# ── Listar Órdenes de Servicio ──────────────────────────────────────────────────

@router.get(
    "/ordenes",
    summary="Listar órdenes de servicio recientes o buscar con ?q=",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def get_ordenes(
    q: Optional[str] = None,
    tecnico_id: Optional[str] = None,
    tecnico_nombre: Optional[str] = None,
    updated_after: Optional[str] = None,
    since: Optional[str] = None,
    limit: Optional[int] = None,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Retorna órdenes de servicio ordenadas por fecha DESC, id DESC.
    Si es Admin, devuelve todas las órdenes recientes sin filtrar por tecnico_id.
    Soporta ?q= para búsqueda directa por folio, cliente, marca, modelo, serie, CCA o DVE.
    """
    from datetime import datetime, timedelta, timezone
    from pesa_api.core.email_service import _ensure_email_columns, formatear_fecha_hora_mexico
    await _ensure_email_columns(db)

    select_inner = """
        SELECT DISTINCT ON (os.folio_os)
            os.id,
            os.fecha AS _fecha_sort,
            os.folio_os,
            COALESCE(os.tipo_documento, 'OS') AS tipo_documento,
            COALESCE(os.datos_tecnicos_json, '{}') AS datos_tecnicos_json,
            os.id_tecnico,
            os.id_cliente,
            COALESCE(os.estado, 'PROCESO') AS estado,
            COALESCE(os.modalidad, 'DIGITAL') AS modalidad,
            os.fecha::text AS fecha,
            os.observaciones,
            COALESCE(os.marca, '') AS marca,
            COALESCE(os.modelo, '') AS modelo,
            COALESCE(os.ns, '') AS ns,
            COALESCE(os.ns, '') AS serie,
            COALESCE(os.ubicacion, '') AS ubicacion,
            COALESCE(os.alcance_max, 0) AS alcance_max_raw,
            os.alcance_max,
            os.div_minima,
            os.div_verificacion,
            COALESCE(os.id_equipo::text, '') AS id_equipo,
            COALESCE(os.id_equipo::text, '') AS id_indicador,
            COALESCE(os.numero_cca, '') AS numero_cca,
            COALESCE(os.numero_dve, '') AS numero_dve,
            COALESCE(os.motivo_no_excentricidad, '') AS motivo_no_excentricidad,
            COALESCE(os.id_lote, '') AS id_lote,
            COALESCE(os.rango_lote, '') AS rango_lote,
            COALESCE(cs.direccion, cl.direccion, '') AS direccion,
            COALESCE(os.sync_version, 1) AS sync_version,
            COALESCE(os.updated_at, NOW()) AS updated_at,
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
            COALESCE(tc.nombre_completo, '') AS tecnico,
            COALESCE(tc.nombre_completo, '') AS tecnico_nombre,
            os.id_tipo_servicio,
            CASE
                WHEN os.folio_os ~* '^OSOCC-' THEN COALESCE(NULLIF(TRIM(os.tipo_servicio), ''), 'Observaciones Celda')
                ELSE COALESCE(ts.nombre, os.tipo_servicio, '')
            END AS tipo_servicio,
            os.id_tipo_instrumento,
            COALESCE(ti.nombre, '') AS tipo_instrumento,
            COALESCE(os.aplica_excentricidad, true) AS aplica_excentricidad,
            COALESCE(os.filas_excentricidad, 4) AS filas_excentricidad,
            COALESCE(os.num_secciones, 0) AS num_secciones,
            COALESCE(os.secciones_camionera, 0) AS secciones_camionera,
            COALESCE(os.instrumento_capacidad, '') AS instrumento_capacidad,
            COALESCE(os.instrumento_division, '') AS instrumento_division,
            os.sucursal_id,
            COALESCE(cs.nombre_sucursal, '') AS sucursal,
            COALESCE(cs.nombre_sucursal, '') AS sucursal_nombre,
            COALESCE(os.estatus, '') AS estatus,
            COALESCE(os.sync_check_status, 'ASIGNADA') AS sync_check_status,
            COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS correo_enviado,
            COALESCE(os.correo_enviado, os.email_enviado, FALSE) AS email_enviado,
            COALESCE(NULLIF(os.correo_destino, ''), os.correo_cliente, '') AS correo_destino,
            COALESCE(NULLIF(os.correo_destino, ''), os.correo_cliente, '') AS correo_cliente,
            COALESCE(NULLIF(os.correo_cc, ''), 'recepcion@basculaspesa.com.mx') AS correo_cc,
            COALESCE(os.fecha_envio_correo, os.fecha_envio_email) AS fecha_envio_email,
            COALESCE(os.motivo_cancelacion, '') AS motivo_cancelacion,
            COALESCE(os.cancelada_por, '') AS cancelada_por,
            os.fecha_cancelacion::text AS fecha_cancelacion,
            COALESCE(os.sin_correo_cliente, FALSE) AS sin_correo_cliente,
            COALESCE(os.motivo_sin_correo, '') AS motivo_sin_correo,
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
        LEFT JOIN (SELECT DISTINCT ON (id) id, razon_social, direccion FROM cat_clientes ORDER BY id) cl ON os.id_cliente = cl.id
        LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
        LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
        LEFT JOIN (SELECT DISTINCT ON (id) id, nombre_sucursal, direccion FROM cliente_sucursales ORDER BY id) cs ON os.sucursal_id = cs.id
        WHERE (os.estado IS NULL OR UPPER(TRIM(os.estado)) NOT IN ('ELIMINADO', 'ELIMINADA'))
          AND (os.estatus IS NULL OR UPPER(TRIM(os.estatus)) NOT IN ('ELIMINADO', 'ELIMINADA'))
    """
    params: list = []

    role_raw = str(current_user.get("role") or "").strip().lower()
    username_c = str(current_user.get("username") or "").strip().lower()
    is_admin = (
        tiene_visibilidad_global(current_user)
        or role_raw in {"admin", "administrador", "superadmin", "jefe", "gerente", "gerencia", "direccion"}
        or username_c == "ivancolin1207"
    )

    if not is_admin:
        mi_id = id_tecnico_de(current_user)
        if not mi_id:
            return []
        params.append(mi_id)
        select_inner += f" AND os.id_tecnico = ${len(params)}"
        tecnico_nombre = None
        tecnico_id = None

    if tecnico_nombre and str(tecnico_nombre).strip():
        nombre_limpio = f"%{str(tecnico_nombre).strip().lower()}%"
        params.append(nombre_limpio)
        select_inner += f" AND (LOWER(tc.nombre_completo) LIKE ${len(params)} OR LOWER(tc.usuario) LIKE ${len(params)} OR LOWER(COALESCE(os.cliente, '')) LIKE ${len(params)})"
    elif tecnico_id and str(tecnico_id).strip().isdigit():
        params.append(int(str(tecnico_id).strip()))
        select_inner += f" AND os.id_tecnico = ${len(params)}"

    q_clean = str(q).strip() if q and str(q).strip() else None
    if q_clean:
        params.append(f"%{q_clean}%")
        iq = len(params)
        select_inner += (
            f" AND ("
            f"os.folio_os ILIKE ${iq} "
            f"OR COALESCE(cl.razon_social, '') ILIKE ${iq} "
            f"OR COALESCE(os.cliente, '') ILIKE ${iq} "
            f"OR COALESCE(cs.nombre_sucursal, '') ILIKE ${iq} "
            f"OR COALESCE(cs.direccion, '') ILIKE ${iq} "
            f"OR COALESCE(tc.nombre_completo, '') ILIKE ${iq} "
            f"OR COALESCE(os.marca, '') ILIKE ${iq} "
            f"OR COALESCE(os.modelo, '') ILIKE ${iq} "
            f"OR COALESCE(os.ns, '') ILIKE ${iq} "
            f"OR COALESCE(os.id_equipo::text, '') ILIKE ${iq} "
            f"OR COALESCE(os.numero_cca, '') ILIKE ${iq} "
            f"OR COALESCE(os.numero_dve, '') ILIKE ${iq} "
            f"OR COALESCE(os.datos_tecnicos_json, '') ILIKE ${iq}"
            f")"
        )
    else:
        raw_date = updated_after or since
        if raw_date and str(raw_date).strip():
            try:
                clean_s = str(raw_date).strip().replace("Z", "+00:00")
                dt = datetime.fromisoformat(clean_s)
                if dt.tzinfo is not None:
                    dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
                params.append(dt - timedelta(hours=12))
                select_inner += f" AND (os.updated_at >= ${len(params)}::timestamp OR os.created_at >= ${len(params)}::timestamp)"
            except Exception:
                pass

    eff_limit = int(limit) if (limit and int(limit) > 0) else int(settings.SYNC_MAX_BATCH_SIZE)
    params.append(eff_limit)
    full_query = f"""
        SELECT * FROM (
            {select_inner}
            ORDER BY os.folio_os, os.id DESC
        ) AS dedup_os
        ORDER BY dedup_os._fecha_sort DESC NULLS LAST, dedup_os.id DESC
        LIMIT ${len(params)}
    """

    try:
        rows = await db.fetch(full_query, *params)
        resultado = []
        for r in rows:
            d = dict(r)
            d.pop("_fecha_sort", None)
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
            d["numero_cca"] = _limpiar_num_reg(d.get("numero_cca"))
            d["numero_dve"] = _limpiar_num_reg(d.get("numero_dve"))
            d["etiqueta_instrumento"] = _construir_etiqueta_instrumento_dict(d)
            d["fecha_envio_correo"] = formatear_fecha_hora_mexico(d.get("fecha_envio_email")) or None
            d["partidas"] = partidas_list
            d["refacciones"] = partidas_list
            resultado.append(d)
        return resultado
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[ORDENES GET ERROR] Falla al listar órdenes: {str(e)}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error en servidor al obtener órdenes: {e}",
        )


# ── Crear Orden de Servicio ────────────────────────────────────────────────────

@router.post(
    "/ordenes",
    summary="Crear nueva Orden de Servicio desde la tablet (Admin / Técnico)",
    tags=["Catálogos"],
    status_code=status.HTTP_201_CREATED,
)
async def crear_orden(
    body: CrearOrdenBody,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Crea una nueva OS (o lote de OS) directamente desde la tablet con paridad completa
    con el generador de formatos de Windows:
      - Todos los tipos de documento: OS, RMA, RE, LP, LV, OSOB, OSOCC
      - Modalidad: Digital | Físico
      - Individual o Lote (con id_lote y rango_lote)
      - Cliente, Sucursal/Dirección completa y Técnico asignado
      - Datos parciales o completos del instrumento (Marca, Modelo, Serie, ID, Ubicación, CCA, DVE)
    """
    today = date.today()
    year_short = today.strftime("%y")
    fecha_orden = today
    if body.fecha and str(body.fecha).strip():
        try:
            fecha_orden = date.fromisoformat(str(body.fecha).strip()[:10])
        except Exception:
            fecha_orden = today

    # [SEC] Un técnico solo puede crear OS asignadas a sí mismo; Admin/Logística a cualquiera.
    id_tecnico_asignado = body.id_tecnico
    if not tiene_visibilidad_global(current_user):
        id_tecnico_asignado = id_tecnico_de(current_user)

    pref = (body.tipo_documento or "OS").strip().upper()
    if pref not in ("OS", "RMA", "RE", "OSOB", "OSOCC", "LV", "LP"):
        pref = "OS"

    seq_row = await db.fetchrow(
        f"""
        SELECT COALESCE(MAX(
            NULLIF(
                REGEXP_REPLACE(folio_os, '^{pref}-\\d+-', '', 'g'),
                ''
            )::integer
        ), 0) + 1 AS siguiente
        FROM ordenes_servicio
        WHERE folio_os LIKE $1
        """,
        f"{pref}-{year_short}-%"
    )
    siguiente = seq_row["siguiente"] if seq_row else 1

    es_lote = str(body.tipo or "").strip().lower() == "lote" and (body.cantidad or 1) > 1
    cantidad = max(1, body.cantidad) if es_lote else 1
    folios_creados = [f"{pref}-{year_short}-{siguiente + i:03d}" for i in range(cantidad)]

    id_lote_val = f"LOTE-{uuid.uuid4().hex[:10].upper()}" if cantidad > 1 else None
    rango_lote_val = f"{folios_creados[0]} al {folios_creados[-1]}" if cantidad > 1 else None

    modalidad_norm = _normalizar_modalidad(body.modalidad) or "DIGITAL"

    # Resolver nombres de cliente, sucursal y técnico para respuesta enriquecida
    cliente_nom = ""
    cliente_dir = (body.direccion or "").strip()
    sucursal_nom = (body.sucursal or "").strip()
    if body.id_cliente:
        try:
            crow = await db.fetchrow(
                "SELECT razon_social, COALESCE(direccion, '') AS direccion FROM cat_clientes WHERE id = $1",
                body.id_cliente,
            )
            if crow:
                cliente_nom = str(crow["razon_social"] or "")
                if not cliente_dir:
                    cliente_dir = str(crow["direccion"] or "")
        except Exception:
            pass
    if body.sucursal_id:
        try:
            srow = await db.fetchrow(
                "SELECT COALESCE(nombre_sucursal, '') AS nombre_sucursal, COALESCE(direccion, '') AS direccion FROM cliente_sucursales WHERE id = $1",
                body.sucursal_id,
            )
            if srow:
                if not sucursal_nom:
                    sucursal_nom = str(srow["nombre_sucursal"] or "")
                if srow["direccion"]:
                    cliente_dir = str(srow["direccion"])
        except Exception:
            pass

    tecnico_nom = ""
    if id_tecnico_asignado:
        try:
            trow = await db.fetchrow("SELECT nombre_completo FROM cat_tecnicos WHERE id = $1", id_tecnico_asignado)
            if trow:
                tecnico_nom = str(trow["nombre_completo"] or "")
        except Exception:
            pass

    tipo_srv_txt = None
    if pref == "OSOB":
        tipo_srv_txt = "Formato de Inspección y Revisión de Básculas"
    elif pref == "OSOCC":
        tipo_srv_txt = "Formato de Diagnóstico y Revisión de Celda de Carga"
    elif pref == "RMA":
        tipo_srv_txt = "Remisión de Material"
    elif pref == "RE":
        tipo_srv_txt = "Revisión de Báscula"
    elif pref == "LP":
        tipo_srv_txt = "Levantamiento de Proyecto"
    elif pref == "LV":
        tipo_srv_txt = "Levantamiento Metrológico"
    elif body.id_tipo_servicio:
        try:
            ts_row = await db.fetchrow("SELECT nombre FROM cat_tipo_servicio WHERE id = $1", body.id_tipo_servicio)
            if ts_row:
                tipo_srv_txt = str(ts_row["nombre"] or "")
        except Exception:
            pass

    # Instrumento parcial / inicial (solo en Individual o en primera orden si es lote;
    # si es Individual o si envían marca/modelo generales se guardan en la orden)
    marca_in = (body.marca or "").strip() or None
    modelo_in = (body.modelo or "").strip() or None
    serie_in = (body.serie or body.ns or "").strip() or None
    id_eq_in = (body.id_indicador or body.id_equipo or "").strip() or None
    ubic_in = (body.ubicacion or "").strip() or None
    cap_str = str(body.capacidad_maxima).strip() if body.capacidad_maxima is not None and str(body.capacidad_maxima).strip() else None
    div_str = _norm_div_min_str(body.division_minima) if body.division_minima is not None and str(body.division_minima).strip() else None
    cap_num = _parse_float_opt(body.capacidad_maxima)
    div_num = _parse_float_opt(div_str)
    import unicodedata as _ud_cat, re as _re_cat
    _ts_norm_cat = "".join(
        c for c in _ud_cat.normalize("NFKD", str(tipo_srv_txt or "").lower())
        if not _ud_cat.combining(c)
    )
    _permite_cca = pref == "OS" and ("calibraci" in _ts_norm_cat or bool(_re_cat.search(r"\bcca\b", _ts_norm_cat)))
    _permite_dve = pref == "OS" and (
        "inspecc" in _ts_norm_cat
        or "verifica" in _ts_norm_cat
        or bool(_re_cat.search(r"\bdve\b", _ts_norm_cat))
    )
    cca_in = (_limpiar_num_reg(body.numero_cca) or None) if (_permite_cca or not _ts_norm_cat) else None
    dve_in = (_limpiar_num_reg(body.numero_dve) or None) if (_permite_dve or not _ts_norm_cat) else None
    aplica_exc = True if body.aplica_excentricidad is None else bool(body.aplica_excentricidad)
    motivo_no_exc = (body.motivo_no_excentricidad or "").strip() if not aplica_exc else None
    tipo_inst_txt = (body.tipo_instrumento or "").strip() or None
    correo_in_list = _extraer_correos_validos_lista(body.correo_destino or body.correo_cliente)
    correo_in = ", ".join(correo_in_list) if correo_in_list else None

    dt_json_dict = {
        k: v
        for k, v in {
            "marca": marca_in,
            "modelo": modelo_in,
            "serie": serie_in,
            "ns": serie_in,
            "id_indicador": id_eq_in,
            "id_equipo": id_eq_in,
            "capacidad_maxima": cap_str,
            "division_minima": div_str,
            "ubicacion": ubic_in,
            "tipo_instrumento": tipo_inst_txt,
            "numero_cca": cca_in,
            "numero_dve": dve_in,
            "aplica_excentricidad": aplica_exc,
            "motivo_no_excentricidad": motivo_no_exc,
            "direccion": cliente_dir,
            "sucursal": sucursal_nom,
            "unidad_medida": (body.unidad_medida or "kg").strip() or "kg",
            "correo_destino": correo_in,
            "correo_cliente": correo_in,
        }.items()
        if v is not None and v != ""
    }
    dt_json_str = json.dumps(dt_json_dict, ensure_ascii=False) if dt_json_dict else "{}"

    ordenes_creadas = []
    for idx, folio in enumerate(folios_creados):
        consec_num = siguiente + idx
        # En lote, serie e id_equipo únicos no se clonan en las demás tarjetas salvo marca/modelo/ubicacion parciales
        f_serie = serie_in if (cantidad == 1 or idx == 0) else None
        f_ideq = id_eq_in if (cantidad == 1 or idx == 0) else None
        f_cca = cca_in if (cantidad == 1 or idx == 0) else None
        f_dve = dve_in if (cantidad == 1 or idx == 0) else None
        f_dt = dt_json_str if (cantidad == 1 or idx == 0) else json.dumps(
            {k: v for k, v in dt_json_dict.items() if k not in ("serie", "ns", "id_indicador", "id_equipo", "numero_cca", "numero_dve")},
            ensure_ascii=False,
        )

        try:
            await db.execute(
                """
                INSERT INTO ordenes_servicio (
                    folio_os, consecutivo, tipo_documento, tipo_servicio,
                    estado, estatus, modalidad, fecha,
                    id_cliente, cliente, sucursal_id, id_tecnico,
                    id_tipo_servicio, id_tipo_instrumento,
                    marca, modelo, ns, id_equipo, ubicacion,
                    alcance_max, div_minima, instrumento_capacidad, instrumento_division,
                    numero_cca, numero_dve, aplica_excentricidad, motivo_no_excentricidad,
                    id_lote, rango_lote, datos_tecnicos_json,
                    observaciones, sync_check_status, sync_version, updated_at
                ) VALUES (
                    $1, $2, $3, $4,
                    'PROCESO', 'Asignada', $5, $6,
                    $7, $8, $9, $10,
                    $11, $12,
                    $13, $14, $15, $16, $17,
                    $18, $19, $20, $21,
                    $22, $23, $24, $25,
                    $26, $27, $28,
                    $29, 'ASIGNADA', 1, NOW()
                )
                ON CONFLICT (folio_os) DO NOTHING
                """,
                folio,
                consec_num,
                pref,
                tipo_srv_txt,
                modalidad_norm,
                fecha_orden,
                body.id_cliente,
                cliente_nom or None,
                body.sucursal_id,
                id_tecnico_asignado,
                body.id_tipo_servicio,
                body.id_tipo_instrumento,
                marca_in,
                modelo_in,
                f_serie,
                f_ideq,
                ubic_in,
                cap_num,
                div_num,
                cap_str,
                div_str,
                f_cca,
                f_dve,
                aplica_exc,
                motivo_no_exc,
                id_lote_val,
                rango_lote_val,
                f_dt,
                body.observaciones or "",
            )
        except Exception as exc_ins:
            logger.warning("[CREAR ORDEN] INSERT extendido falló (%s), aplicando fallback compatible", exc_ins)
            await db.execute(
                """
                INSERT INTO ordenes_servicio (
                    folio_os, tipo_documento, tipo_servicio, estado, modalidad, fecha,
                    id_cliente, sucursal_id, id_tecnico, id_tipo_servicio,
                    marca, modelo, ns, id_equipo, ubicacion, numero_cca,
                    datos_tecnicos_json, observaciones, sync_version, updated_at
                ) VALUES (
                    $1, $2, $3, 'PROCESO', $4, $5,
                    $6, $7, $8, $9,
                    $10, $11, $12, $13, $14, $15,
                    $16, $17, 1, NOW()
                )
                ON CONFLICT (folio_os) DO NOTHING
                """,
                folio,
                pref,
                tipo_srv_txt,
                modalidad_norm,
                fecha_orden,
                body.id_cliente,
                body.sucursal_id,
                id_tecnico_asignado,
                body.id_tipo_servicio,
                marca_in,
                modelo_in,
                f_serie,
                f_ideq,
                ubic_in,
                f_cca,
                f_dt,
                body.observaciones or "",
            )

        if correo_in:
            try:
                await db.execute(
                    "UPDATE ordenes_servicio SET correo_destino = $1, correo_cliente = $1 WHERE folio_os = $2",
                    correo_in,
                    folio,
                )
            except Exception:
                pass

        orden_dict = {
            "folio_os": folio,
            "folio": folio,
            "tipo_documento": pref,
            "tipo_servicio": tipo_srv_txt or "",
            "id_tipo_servicio": body.id_tipo_servicio,
            "estado": "PROCESO",
            "estatus": "Asignada",
            "modalidad": modalidad_norm,
            "fecha": fecha_orden.isoformat(),
            "id_cliente": body.id_cliente,
            "cliente": cliente_nom,
            "sucursal_id": body.sucursal_id,
            "sucursal": sucursal_nom,
            "direccion": cliente_dir,
            "id_tecnico": id_tecnico_asignado,
            "tecnico": tecnico_nom,
            "correo_destino": correo_in or "",
            "correo_cliente": correo_in or "",
            "marca": marca_in or "",
            "modelo": modelo_in or "",
            "ns": f_serie or "",
            "serie": f_serie or "",
            "id_equipo": f_ideq or "",
            "id_indicador": f_ideq or "",
            "ubicacion": ubic_in or "",
            "alcance_max": cap_num,
            "div_minima": div_num,
            "instrumento_capacidad": cap_str or "",
            "instrumento_division": div_str or "",
            "tipo_instrumento": tipo_inst_txt or "",
            "numero_cca": f_cca or "",
            "numero_dve": f_dve or "",
            "aplica_excentricidad": aplica_exc,
            "motivo_no_excentricidad": motivo_no_exc or "",
            "id_lote": id_lote_val or "",
            "rango_lote": rango_lote_val or "",
            "datos_tecnicos_json": f_dt,
            "observaciones": body.observaciones or "",
            "sync_check_status": "ASIGNADA",
        }
        orden_dict["etiqueta_instrumento"] = _construir_etiqueta_instrumento_dict(orden_dict)
        ordenes_creadas.append(orden_dict)

    if marca_in and modelo_in:
        try:
            await db.execute(
                "INSERT INTO catalogo_marcas_modelos (marca, modelo) VALUES ($1, $2) ON CONFLICT (marca, modelo) DO NOTHING",
                marca_in, modelo_in,
            )
        except Exception:
            pass

    return {
        "folio_os": folios_creados[0],
        "folios": folios_creados,
        "cantidad": cantidad,
        "tipo": body.tipo,
        "modalidad": modalidad_norm,
        "id_lote": id_lote_val,
        "rango_lote": rango_lote_val,
        "ordenes": ordenes_creadas,
    }


# ── Guardado Parcial de Datos de Instrumento (sin cerrar la orden) ────────────

@router.patch(
    "/ordenes/{folio}/instrumento",
    summary="Guardar y sincronizar datos parciales del instrumento sin finalizar la orden",
    tags=["Catálogos", "Órdenes de Servicio"],
)
@router.post(
    "/ordenes/{folio}/instrumento",
    summary="Alias POST para guardar datos parciales del instrumento sin finalizar la orden",
    tags=["Catálogos", "Órdenes de Servicio"],
)
async def actualizar_instrumento_parcial(
    folio: str,
    body: ActualizarInstrumentoBody,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Actualiza únicamente los datos del instrumento y números regulatorios (CCA / DVE)
    manteniendo la orden en estado 'EN_PROCESO' o 'ASIGNADA' (NUNCA la cierra).
    """
    clean_folio = (folio or "").strip()
    row = await db.fetchrow(
        """
        SELECT id, folio_os, id_tecnico, sucursal_id, estado, estatus,
               COALESCE(datos_tecnicos_json, '{}') AS datos_tecnicos_json,
               marca, modelo, ns, id_equipo, ubicacion,
               numero_cca, numero_dve
        FROM ordenes_servicio
        WHERE folio_os = $1 OR id::text = $1
        """,
        clean_folio,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"Orden '{clean_folio}' no encontrada")

    verificar_acceso_os(current_user, row["id_tecnico"])

    actual_id = row["id"]
    actual_folio = row["folio_os"]
    estado_actual = str(row["estado"] or "").strip().upper()
    estatus_actual = str(row["estatus"] or "").strip().upper()

    _ESTADOS_FINALES = {
        "CERRADO", "CERRADA", "COMPLETADA", "COMPLETADO",
        "COMPLETADA_DIGITAL", "COMPLETADA_FISICA", "ESCANEADA", "FIRMADA", "CANCELADA",
    }
    ya_cerrada = estado_actual in _ESTADOS_FINALES or estatus_actual in _ESTADOS_FINALES

    if ya_cerrada:
        nuevo_estado = row["estado"]
        nuevo_estatus = row["estatus"]
    else:
        req_est = str(body.estatus or "").strip().upper()
        if req_est == "ASIGNADA":
            nuevo_estado = "ASIGNADA"
            nuevo_estatus = "Asignada"
        else:
            nuevo_estado = "EN_PROCESO"
            nuevo_estatus = "En Proceso"

    # Resolver valores proporcionados (permitiendo limpiar CCA o DVE si se envía cadena vacía explícita)
    marca_val = body.marca.strip() if body.marca is not None else None
    modelo_val = body.modelo.strip() if body.modelo is not None else None
    serie_raw = body.serie if body.serie is not None else body.ns
    serie_val = serie_raw.strip() if serie_raw is not None else None
    id_ind_raw = body.id_indicador if body.id_indicador is not None else body.id_equipo
    id_ind_val = id_ind_raw.strip() if id_ind_raw is not None else None
    ubic_val = body.ubicacion.strip() if body.ubicacion is not None else None
    tipo_inst_val = body.tipo_instrumento.strip() if body.tipo_instrumento is not None else None

    cap_raw = body.capacidad_maxima if body.capacidad_maxima is not None else body.alcance_max
    cap_str = str(cap_raw).strip() if cap_raw is not None else None
    cap_num = _parse_float_opt(cap_raw)

    div_raw = body.division_minima if body.division_minima is not None else body.div_minima
    div_str = _norm_div_min_str(div_raw) if div_raw is not None else None
    div_num = _parse_float_opt(div_str)

    cca_provided = (body.numero_cca is not None) or (body.cca is not None)
    cca_val = _limpiar_num_reg(body.numero_cca if body.numero_cca is not None else body.cca) if cca_provided else None

    dve_provided = (body.numero_dve is not None) or (body.folio_dve is not None)
    dve_val = _limpiar_num_reg(body.numero_dve if body.numero_dve is not None else body.folio_dve) if dve_provided else None

    aplica_exc_val = body.aplica_excentricidad
    motivo_no_val = body.motivo_no_excentricidad.strip() if body.motivo_no_excentricidad is not None else None
    if aplica_exc_val is True:
        motivo_no_val = ""

    # Fusionar en datos_tecnicos_json existente sin perder mediciones ni otros metadatos
    dt_existing: dict = {}
    try:
        raw_dt = row["datos_tecnicos_json"]
        if isinstance(raw_dt, dict):
            dt_existing = dict(raw_dt)
        elif isinstance(raw_dt, str) and raw_dt.strip():
            parsed = json.loads(raw_dt)
            if isinstance(parsed, dict):
                dt_existing = parsed
    except Exception:
        dt_existing = {}

    merge_updates = {
        "marca": marca_val,
        "modelo": modelo_val,
        "serie": serie_val,
        "ns": serie_val,
        "id_indicador": id_ind_val,
        "id_equipo": id_ind_val,
        "capacidad_maxima": cap_str,
        "division_minima": div_str,
        "ubicacion": ubic_val,
        "tipo_instrumento": tipo_inst_val,
        "aplica_excentricidad": aplica_exc_val,
        "motivo_no_excentricidad": motivo_no_val,
        "unidad_medida": body.unidad_medida,
        "holograma_anterior": body.holograma_anterior,
        "holograma_actualizado": body.holograma_actualizado,
    }
    for k, v in merge_updates.items():
        if v is not None:
            dt_existing[k] = v
    if cca_provided:
        dt_existing["numero_cca"] = cca_val or ""
        dt_existing["cca"] = cca_val or ""
    if dve_provided:
        dt_existing["numero_dve"] = dve_val or ""
        dt_existing["folio_dve"] = dve_val or ""

    dt_json_final = json.dumps(dt_existing, ensure_ascii=False)

    # Resolver id_tipo_instrumento si se proporcionó nombre
    id_tipo_inst = None
    if tipo_inst_val:
        try:
            ti_r = await db.fetchrow(
                "SELECT id FROM cat_tipo_instrumento WHERE LOWER(TRIM(nombre)) = LOWER(TRIM($1)) LIMIT 1",
                tipo_inst_val,
            )
            if ti_r:
                id_tipo_inst = int(ti_r["id"])
        except Exception:
            pass

    try:
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                estado                  = $1,
                estatus                 = $2,
                marca                   = COALESCE($3, marca),
                modelo                  = COALESCE($4, modelo),
                ns                      = COALESCE($5, ns),
                id_equipo               = COALESCE($6, id_equipo),
                ubicacion               = COALESCE($7, ubicacion),
                alcance_max             = COALESCE($8, alcance_max),
                div_minima              = COALESCE($9, div_minima),
                instrumento_capacidad   = COALESCE($10, instrumento_capacidad),
                instrumento_division    = COALESCE($11, instrumento_division),
                id_tipo_instrumento     = COALESCE($12, id_tipo_instrumento),
                numero_cca              = CASE WHEN $13::boolean THEN $14 ELSE numero_cca END,
                numero_dve              = CASE WHEN $15::boolean THEN $16 ELSE numero_dve END,
                aplica_excentricidad    = COALESCE($17, aplica_excentricidad),
                motivo_no_excentricidad = COALESCE($18, motivo_no_excentricidad),
                unidad_medida           = COALESCE($19, unidad_medida),
                holograma_anterior      = COALESCE($20, holograma_anterior),
                holograma_actualizado   = COALESCE($21, holograma_actualizado),
                sucursal_id             = COALESCE($22, sucursal_id),
                datos_tecnicos_json     = $23,
                sync_version            = COALESCE(sync_version, 0) + 1,
                updated_at              = NOW()
            WHERE id = $24
            """,
            nuevo_estado,
            nuevo_estatus,
            marca_val,
            modelo_val,
            serie_val,
            id_ind_val,
            ubic_val,
            cap_num,
            div_num,
            cap_str,
            div_str,
            id_tipo_inst,
            cca_provided,
            cca_val or "",
            dve_provided,
            dve_val or "",
            aplica_exc_val,
            motivo_no_val,
            body.unidad_medida,
            body.holograma_anterior,
            body.holograma_actualizado,
            body.sucursal_id,
            dt_json_final,
            actual_id,
        )
    except Exception as exc_upd:
        logger.warning("[PATCH INSTRUMENTO] UPDATE completo falló (%s), usando fallback compatible", exc_upd)
        await db.execute(
            """
            UPDATE ordenes_servicio SET
                estado              = $1,
                estatus             = $2,
                marca               = COALESCE($3, marca),
                modelo              = COALESCE($4, modelo),
                ns                  = COALESCE($5, ns),
                id_equipo           = COALESCE($6, id_equipo),
                ubicacion           = COALESCE($7, ubicacion),
                alcance_max         = COALESCE($8, alcance_max),
                div_minima          = COALESCE($9, div_minima),
                numero_cca          = CASE WHEN $10::boolean THEN $11 ELSE numero_cca END,
                aplica_excentricidad= COALESCE($12, aplica_excentricidad),
                datos_tecnicos_json = $13,
                updated_at          = NOW()
            WHERE id = $14
            """,
            nuevo_estado,
            nuevo_estatus,
            marca_val,
            modelo_val,
            serie_val,
            id_ind_val,
            ubic_val,
            cap_num,
            div_num,
            cca_provided,
            cca_val or "",
            aplica_exc_val,
            dt_json_final,
            actual_id,
        )

    # Registrar marca/modelo y equipo de sucursal para autocompletado futuro
    eff_marca = marca_val if marca_val is not None else str(row["marca"] or "").strip()
    eff_modelo = modelo_val if modelo_val is not None else str(row["modelo"] or "").strip()
    eff_serie = serie_val if serie_val is not None else str(row["ns"] or "").strip()
    eff_id_ind = id_ind_val if id_ind_val is not None else str(row["id_equipo"] or "").strip()
    eff_ubic = ubic_val if ubic_val is not None else str(row["ubicacion"] or "").strip()
    eff_cca = cca_val if cca_provided else _limpiar_num_reg(row["numero_cca"])
    eff_dve = dve_val if dve_provided else _limpiar_num_reg(row.get("numero_dve") if isinstance(row, dict) else row["numero_dve"])
    eff_suc_id = body.sucursal_id or row["sucursal_id"]

    if eff_marca and eff_modelo:
        try:
            await db.execute(
                "INSERT INTO catalogo_marcas_modelos (marca, modelo) VALUES ($1, $2) ON CONFLICT (marca, modelo) DO NOTHING",
                eff_marca, eff_modelo,
            )
        except Exception:
            pass

    if eff_suc_id and eff_serie:
        try:
            await db.execute(
                """
                INSERT INTO cliente_equipos (
                    sucursal_id, marca, modelo, numero_serie,
                    id_indicador_equipo, ubicacion_interna,
                    capacidad_maxima, division_minima, tipo_instrumento, activo
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE)
                ON CONFLICT (sucursal_id, numero_serie) DO UPDATE SET
                    marca               = COALESCE(NULLIF(EXCLUDED.marca, ''), cliente_equipos.marca),
                    modelo              = COALESCE(NULLIF(EXCLUDED.modelo, ''), cliente_equipos.modelo),
                    id_indicador_equipo = COALESCE(NULLIF(EXCLUDED.id_indicador_equipo, ''), cliente_equipos.id_indicador_equipo),
                    ubicacion_interna   = COALESCE(NULLIF(EXCLUDED.ubicacion_interna, ''), cliente_equipos.ubicacion_interna),
                    capacidad_maxima    = COALESCE(NULLIF(EXCLUDED.capacidad_maxima, ''), cliente_equipos.capacidad_maxima),
                    division_minima     = COALESCE(NULLIF(EXCLUDED.division_minima, ''), cliente_equipos.division_minima),
                    tipo_instrumento    = COALESCE(NULLIF(EXCLUDED.tipo_instrumento, ''), cliente_equipos.tipo_instrumento)
                """,
                eff_suc_id, eff_marca, eff_modelo, eff_serie,
                eff_id_ind, eff_ubic, cap_str, div_str, tipo_inst_val,
            )
        except Exception:
            pass

    resumen = {
        "ok": True,
        "folio_os": actual_folio,
        "folio": actual_folio,
        "estado": nuevo_estado,
        "estatus": nuevo_estatus,
        "marca": eff_marca,
        "modelo": eff_modelo,
        "serie": eff_serie,
        "id_indicador": eff_id_ind,
        "ubicacion": eff_ubic,
        "numero_cca": eff_cca or "",
        "numero_dve": eff_dve or "",
    }
    resumen["etiqueta_instrumento"] = _construir_etiqueta_instrumento_dict(resumen)
    return resumen


# ── Adjuntar escaneo ──────────────────────────────────────────────────────────

def _normalizar_modalidad(valor) -> Optional[str]:
    """'Físico' → 'FISICO'; 'Híbrido' → 'HIBRIDO'; 'Digital' → 'DIGITAL'; otro → None."""
    if valor is None:
        return None
    v = str(valor).strip().upper().replace("Í", "I")
    if v.startswith("FISIC"):
        return "FISICO"
    if v.startswith("HIBRID"):
        return "HIBRIDO"
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
            dt_in = p.get("datos_tecnicos_json")
            dt_map = {}
            if isinstance(dt_in, dict):
                dt_map = dt_in
            elif isinstance(dt_in, str) and dt_in.strip():
                try:
                    dec_dt = json.loads(dt_in)
                    if isinstance(dec_dt, dict):
                        dt_map = dec_dt
                except Exception:
                    pass

            marca_up = str(p.get("marca") or dt_map.get("marca") or "").strip() or None
            modelo_up = str(p.get("modelo") or dt_map.get("modelo") or "").strip() or None
            id_eq_up = str(
                p.get("id_indicador") or p.get("id_equipo") or p.get("indicador_id")
                or dt_map.get("id_indicador") or dt_map.get("id_equipo") or ""
            ).strip() or None
            ns_up = str(p.get("ns") or p.get("serie") or dt_map.get("ns") or dt_map.get("serie") or "").strip() or None
            ubic_up = str(p.get("ubicacion") or dt_map.get("ubicacion") or "").strip() or None
            cca_up = _limpiar_num_reg(
                p.get("numero_cca") or p.get("cca") or dt_map.get("numero_cca") or dt_map.get("cca")
            ) or None
            dve_up = _limpiar_num_reg(
                p.get("numero_dve") or p.get("folio_dve") or dt_map.get("numero_dve") or dt_map.get("folio_dve")
            ) or None

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
                    unidad_medida        = COALESCE($7, unidad_medida),
                    marca                = COALESCE($9, marca),
                    modelo               = COALESCE($10, modelo),
                    id_equipo            = COALESCE($11, id_equipo),
                    indicador_id         = COALESCE($11, indicador_id),
                    ns                   = COALESCE($12, ns),
                    ubicacion            = COALESCE($13, ubicacion),
                    numero_cca           = COALESCE($14, numero_cca),
                    numero_dve           = COALESCE($15, numero_dve)
                WHERE id = $8
                """,
                p.get("observaciones"), p.get("dictamen"),
                p.get("firma_tecnico"), p.get("firma_cliente"),
                p.get("nombre_ing") or p.get("firma_cliente_nombre"), p.get("puesto_ing"),
                p.get("unidad_medida"), actual_id,
                marca_up, modelo_up, id_eq_up, ns_up, ubic_up, cca_up, dve_up,
            )
            if p.get("datos_tecnicos_json"):
                try:
                    dt_str = json.dumps(p["datos_tecnicos_json"], ensure_ascii=False) if isinstance(p["datos_tecnicos_json"], dict) else str(p["datos_tecnicos_json"])
                    await db.execute("UPDATE ordenes_servicio SET datos_tecnicos_json = $1 WHERE id = $2", dt_str, actual_id)
                except Exception as e_dt:
                    logger.warning("[UPLOAD-PDF] No se pudo guardar datos_tecnicos_json: %s", e_dt)
            fecha_raw = str(p.get("fecha") or p.get("fecha_servicio") or "").strip()
            if fecha_raw:
                fecha_iso = fecha_raw[:10]
                try:
                    from datetime import date as _date
                    await db.execute(
                        "UPDATE ordenes_servicio SET fecha = $1 WHERE id = $2",
                        _date.fromisoformat(fecha_iso), actual_id,
                    )
                except Exception:
                    try:
                        await db.execute(
                            "UPDATE ordenes_servicio SET fecha = $1 WHERE id = $2",
                            fecha_iso, actual_id,
                        )
                    except Exception as e_f:
                        logger.warning("[UPLOAD-PDF] No se pudo actualizar fecha: %s", e_f)
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
        asyncio.create_task(enviar_email_orden(None, actual_folio, correo_override=correo_cliente, auto=True))
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
    ordenes_meta: Optional[List[Dict[str, Any]]] = None
    sin_correo_cliente: Optional[bool] = False
    motivo_sin_correo: Optional[str] = None

EnviarEmailBody.model_rebuild()


async def _aplicar_ordenes_meta_previo_correo(db, ordenes_meta: Optional[List[Dict[str, Any]]]) -> None:
    """Sincroniza marca, modelo, id_indicador, numero_cca y numero_dve de 1..N órdenes antes de enviar correo."""
    if not ordenes_meta or not isinstance(ordenes_meta, list):
        return
    for item in ordenes_meta:
        if not isinstance(item, dict):
            continue
        fol = str(item.get("folio") or item.get("folio_os") or "").strip()
        if not fol:
            continue
        marca_v = str(item.get("marca") or "").strip() or None
        modelo_v = str(item.get("modelo") or "").strip() or None
        id_v = str(item.get("id_indicador") or item.get("id_equipo") or item.get("indicador_id") or "").strip() or None
        cca_v = _limpiar_num_reg(item.get("numero_cca") or item.get("cca")) or None
        dve_v = _limpiar_num_reg(item.get("numero_dve") or item.get("folio_dve")) or None
        try:
            await db.execute(
                """
                UPDATE ordenes_servicio SET
                    marca        = COALESCE($1, marca),
                    modelo       = COALESCE($2, modelo),
                    id_equipo    = COALESCE($3, id_equipo),
                    indicador_id = COALESCE($3, indicador_id),
                    numero_cca   = COALESCE($4, numero_cca),
                    numero_dve   = COALESCE($5, numero_dve)
                WHERE folio_os = $6
                """,
                marca_v, modelo_v, id_v, cca_v, dve_v, fol,
            )
        except Exception as e_meta:
            logger.warning("[EMAIL META] No se pudo actualizar meta previa de %s: %s", fol, e_meta)


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
    if body and body.ordenes_meta:
        await _aplicar_ordenes_meta_previo_correo(db, body.ordenes_meta)
    override = body.correo if body else None
    forzar = body.forzar if body else False
    sin_correo = bool(body.sin_correo_cliente) if body else False
    motivo_sc = body.motivo_sin_correo if body else None
    resultado = await enviar_email_orden(
        db,
        folio,
        correo_override=override,
        forzar=forzar,
        sin_correo_cliente=sin_correo,
        motivo_sin_correo=motivo_sc,
    )
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
    if body and body.ordenes_meta:
        await _aplicar_ordenes_meta_previo_correo(db, body.ordenes_meta)
    override = body.correo if body else None
    forzar = body.forzar if body else True
    sin_correo = bool(body.sin_correo_cliente) if body else False
    motivo_sc = body.motivo_sin_correo if body else None
    folios_in = body.folios if (body and body.folios) else None
    if folios_in:
        folios_in = list(dict.fromkeys([str(f).strip() for f in folios_in if str(f).strip()]))

    # Si vienen folios específicos en el body, usarlos directamente para agrupar el lote
    if folios_in and len(folios_in) > 0:
        resultado = await enviar_email_orden(
            db,
            folios_in[0],
            correo_override=override,
            forzar=forzar,
            folios_lista=folios_in,
            sin_correo_cliente=sin_correo,
            motivo_sin_correo=motivo_sc,
        )
        if not resultado.get("ok"):
            raise HTTPException(
                status_code=400,
                detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo del lote",
            )
        return resultado

    row = await db.fetchrow(
        """
        SELECT folio_os FROM ordenes_servicio
        WHERE id_lote = $1
          AND UPPER(TRIM(COALESCE(estatus, ''))) NOT IN ('CANCELADA', 'CANCELADO')
          AND UPPER(TRIM(COALESCE(estado, ''))) NOT IN ('CANCELADA', 'CANCELADO')
        LIMIT 1
        """,
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

    resultado = await enviar_email_orden(
        db,
        row["folio_os"],
        correo_override=override,
        forzar=forzar,
        sin_correo_cliente=sin_correo,
        motivo_sin_correo=motivo_sc,
    )
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
    ordenes_meta: Optional[List[Dict[str, Any]]] = None
    sin_correo_cliente: Optional[bool] = False
    motivo_sin_correo: Optional[str] = None

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
    if body.ordenes_meta:
        await _aplicar_ordenes_meta_previo_correo(db, body.ordenes_meta)
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
            """
            SELECT folio_os FROM ordenes_servicio
            WHERE id_lote = $1
              AND UPPER(TRIM(COALESCE(estatus, ''))) NOT IN ('CANCELADA', 'CANCELADO')
              AND UPPER(TRIM(COALESCE(estado, ''))) NOT IN ('CANCELADA', 'CANCELADO')
            LIMIT 1
            """,
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
        db,
        folio_ref,
        correo_override=body.correo,
        forzar=forzar,
        folios_lista=folios_in,
        sin_correo_cliente=bool(body.sin_correo_cliente),
        motivo_sin_correo=body.motivo_sin_correo,
    )
    if not resultado.get("ok"):
        raise HTTPException(
            status_code=400,
            detail=resultado.get("motivo") or resultado.get("error") or "Error enviando correo",
        )
    return resultado


# ── Cancelar / Descartar orden sobrante y Reactivar orden (Poka-Yoke Lotes) ────

class CancelarOrdenBody(BaseModel):
    motivo: str = "Se asignaron folios de más"
    usuario: Optional[str] = None


class ReactivarOrdenBody(BaseModel):
    usuario: Optional[str] = None


async def ejecutar_cancelar_orden(
    folio: str,
    body: Optional[CancelarOrdenBody],
    db,
    current_user: dict,
) -> dict[str, Any]:
    from datetime import datetime
    from pesa_api.core.email_service import _ensure_email_columns, _obtener_tz_mexico
    await _ensure_email_columns(db)

    clean_folio = (folio or "").strip()
    row = await db.fetchrow(
        """
        SELECT id, folio_os, id_tecnico, COALESCE(estatus, '') AS estatus, COALESCE(estado, '') AS estado
        FROM ordenes_servicio
        WHERE folio_os = $1 OR id::text = $1
        LIMIT 1
        """,
        clean_folio,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"Orden '{clean_folio}' no encontrada")

    verificar_acceso_os(current_user, row["id_tecnico"])

    motivo_txt = ((body.motivo if body else "") or "Se asignaron folios de más").strip()
    if not motivo_txt:
        motivo_txt = "Se asignaron folios de más"
    usuario_txt = (
        (body.usuario if body and body.usuario else None)
        or current_user.get("nombre_completo")
        or current_user.get("nombre")
        or current_user.get("username")
        or "Técnico"
    )
    usuario_txt = str(usuario_txt).strip()

    now_mx = datetime.now(_obtener_tz_mexico())
    now_mx_naive = now_mx.replace(tzinfo=None)
    fecha_mx_fmt = now_mx.strftime("%d/%m/%Y %H:%M")

    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estatus            = 'CANCELADA',
            estado             = 'CANCELADA',
            motivo_cancelacion = $1,
            cancelada_por      = $2,
            fecha_cancelacion  = $3,
            sync_version       = COALESCE(sync_version, 0) + 1,
            updated_at         = NOW()
        WHERE id = $4
        """,
        motivo_txt,
        usuario_txt,
        now_mx_naive,
        row["id"],
    )

    logger.info(
        "[CANCELAR ORDEN] Folio %s marcado como CANCELADA por %s (%s) — consecutivo preservado",
        row["folio_os"], usuario_txt, motivo_txt,
    )
    return {
        "ok": True,
        "folio_os": row["folio_os"],
        "id": row["id"],
        "estatus": "CANCELADA",
        "estado": "CANCELADA",
        "motivo_cancelacion": motivo_txt,
        "cancelada_por": usuario_txt,
        "fecha_cancelacion": fecha_mx_fmt,
    }


async def ejecutar_reactivar_orden(
    folio: str,
    db,
    current_user: dict,
) -> dict[str, Any]:
    from pesa_api.core.email_service import _ensure_email_columns
    await _ensure_email_columns(db)

    role_raw = str(current_user.get("role") or "").strip().lower()
    username_c = str(current_user.get("username") or "").strip().lower()
    es_admin = (
        tiene_visibilidad_global(current_user)
        or role_raw in {"admin", "administrador", "superadmin", "jefe", "gerente", "logistica"}
        or username_c == "ivancolin1207"
    )
    if not es_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Solo un usuario Administrador o Logística puede reactivar una orden cancelada.",
        )

    clean_folio = (folio or "").strip()
    row = await db.fetchrow(
        "SELECT id, folio_os FROM ordenes_servicio WHERE folio_os = $1 OR id::text = $1 LIMIT 1",
        clean_folio,
    )
    if row is None:
        raise HTTPException(status_code=404, detail=f"Orden '{clean_folio}' no encontrada")

    await db.execute(
        """
        UPDATE ordenes_servicio
        SET estatus            = 'Asignada',
            estado             = 'EN_PROCESO',
            motivo_cancelacion = NULL,
            cancelada_por      = NULL,
            fecha_cancelacion  = NULL,
            sync_version       = COALESCE(sync_version, 0) + 1,
            updated_at         = NOW()
        WHERE id = $1
        """,
        row["id"],
    )

    logger.info(
        "[REACTIVAR ORDEN] Folio %s reactivado a EN_PROCESO por %s",
        row["folio_os"], current_user.get("username"),
    )
    return {
        "ok": True,
        "folio_os": row["folio_os"],
        "id": row["id"],
        "estatus": "Asignada",
        "estado": "EN_PROCESO",
    }


@router.patch(
    "/ordenes/{folio}/cancelar",
    summary="Marcar orden sobrante no utilizada como CANCELADA sin borrar consecutivo",
    tags=["Órdenes de Servicio", "Lotes"],
)
@router.post(
    "/ordenes/{folio}/cancelar",
    include_in_schema=False,
)
async def cancelar_orden_endpoint(
    folio: str,
    body: Optional[CancelarOrdenBody] = Body(default=None),
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await ejecutar_cancelar_orden(folio, body, db, current_user)


@router.patch(
    "/ordenes/{folio}/reactivar",
    summary="Reactivar orden CANCELADA devolviéndola a EN_PROCESO (Solo Admin)",
    tags=["Órdenes de Servicio", "Admin"],
)
@router.post(
    "/ordenes/{folio}/reactivar",
    include_in_schema=False,
)
async def reactivar_orden_endpoint(
    folio: str,
    db=Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    return await ejecutar_reactivar_orden(folio, db, current_user)


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


# ── CRUD Administrativo de Clientes, Sucursales y Asignación de OS ────────────

class ClienteWriteBody(BaseModel):
    razon_social: Optional[str] = None
    nombre:       Optional[str] = None
    rfc:          Optional[str] = None
    telefono:     Optional[str] = None
    correo:       Optional[str] = None
    email:        Optional[str] = None
    direccion:    Optional[str] = None
    activo:       Optional[bool] = True


class SucursalWriteBody(BaseModel):
    nombre_sucursal:   Optional[str] = None
    nombre:            Optional[str] = None
    direccion:         Optional[str] = None
    contacto_nombre:   Optional[str] = None
    contacto_telefono: Optional[str] = None
    contacto_correo:   Optional[str] = None
    activo:            Optional[bool] = True


class AsignarOrdenBody(BaseModel):
    id_tecnico: int
    modalidad:  Optional[str] = None
    estatus:    Optional[str] = None


@router.get(
    "/sucursales",
    summary="Listar todas las sucursales/direcciones activas",
    tags=["Catálogos"],
)
async def listar_todas_sucursales(
    cliente_id: Optional[int] = None,
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    clientes_list, flat_sucs = await obtener_clientes_con_sucursales_reales(db, activo=True)
    if cliente_id is not None:
        for c in clientes_list:
            if int(c["id"]) == int(cliente_id):
                return c["sucursales"]
        return [s for s in flat_sucs if s.get("cliente_id") == int(cliente_id)]
    return flat_sucs


@router.get(
    "/clientes/{cliente_id}/sucursales",
    summary="Listar sucursales de un cliente",
    tags=["Catálogos"],
)
async def listar_sucursales_cliente(
    cliente_id: int,
    db=Depends(get_db),
    _=Depends(get_current_user),
):
    clientes_list, flat_sucs = await obtener_clientes_con_sucursales_reales(db, activo=True)
    for c in clientes_list:
        if int(c["id"]) == int(cliente_id):
            return c["sucursales"]
    return [s for s in flat_sucs if s.get("cliente_id") == int(cliente_id)]


@router.post(
    "/clientes",
    summary="Crear nuevo cliente (Admin)",
    tags=["Catálogos", "Admin"],
    status_code=status.HTTP_201_CREATED,
)
async def crear_cliente(
    body: ClienteWriteBody,
    db=Depends(get_db),
    _=Depends(require_roles("admin", "administrador", "superadmin", "jefe", "gerente", "logistica")),
):
    razon = (body.razon_social or body.nombre or "").strip()
    if not razon:
        raise HTTPException(status_code=400, detail="razon_social es obligatoria")
    rfc_val = (body.rfc or "").strip() or None
    tel_val = (body.telefono or "").strip() or None
    dir_val = (body.direccion or "").strip() or None
    correo_val = (body.correo or body.email or "").strip() or None

    existing = await db.fetchrow(
        "SELECT id, razon_social, COALESCE(rfc,'') AS rfc, COALESCE(telefono,'') AS telefono, COALESCE(direccion,'') AS direccion, COALESCE(activo, TRUE) AS activo "
        "FROM cat_clientes WHERE LOWER(TRIM(razon_social)) = LOWER(TRIM($1)) LIMIT 1",
        razon,
    )
    if existing:
        row = dict(existing)
        row["nombre"] = row["razon_social"]
        return row

    try:
        row = await db.fetchrow(
            """
            INSERT INTO cat_clientes (razon_social, rfc, telefono, correo, direccion, activo)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id, razon_social, COALESCE(rfc,'') AS rfc, COALESCE(telefono,'') AS telefono,
                      COALESCE(correo,'') AS correo, COALESCE(direccion,'') AS direccion, COALESCE(activo, TRUE) AS activo
            """,
            razon, rfc_val, tel_val, correo_val, dir_val,
            True if body.activo is None else bool(body.activo),
        )
    except Exception:
        row = await db.fetchrow(
            """
            INSERT INTO cat_clientes (razon_social, rfc, telefono, direccion, activo)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, razon_social, COALESCE(rfc,'') AS rfc, COALESCE(telefono,'') AS telefono,
                      COALESCE(direccion,'') AS direccion, COALESCE(activo, TRUE) AS activo
            """,
            razon, rfc_val, tel_val, dir_val,
            True if body.activo is None else bool(body.activo),
        )
    out = dict(row)
    out["nombre"] = out["razon_social"]
    # Crear sucursal matriz inicial si se envió dirección
    if dir_val:
        try:
            await db.execute(
                """
                INSERT INTO cliente_sucursales (cliente_id, nombre_sucursal, direccion, activo)
                VALUES ($1, 'Matriz / Principal', $2, TRUE)
                ON CONFLICT DO NOTHING
                """,
                out["id"], dir_val,
            )
        except Exception:
            pass
    return out


@router.put(
    "/clientes/{cliente_id}",
    summary="Actualizar cliente existente (Admin)",
    tags=["Catálogos", "Admin"],
)
async def actualizar_cliente(
    cliente_id: int,
    body: ClienteWriteBody,
    db=Depends(get_db),
    _=Depends(require_roles("admin", "administrador", "superadmin", "jefe", "gerente", "logistica")),
):
    razon = (body.razon_social or body.nombre or "").strip() or None
    row = await db.fetchrow(
        """
        UPDATE cat_clientes
        SET razon_social = COALESCE($1, razon_social),
            rfc          = COALESCE($2, rfc),
            telefono     = COALESCE($3, telefono),
            direccion    = COALESCE($4, direccion),
            activo       = COALESCE($5, activo)
        WHERE id = $6
        RETURNING id, razon_social, COALESCE(rfc,'') AS rfc, COALESCE(telefono,'') AS telefono,
                  COALESCE(direccion,'') AS direccion, COALESCE(activo, TRUE) AS activo
        """,
        razon,
        (body.rfc or "").strip() or None,
        (body.telefono or "").strip() or None,
        (body.direccion or "").strip() or None,
        body.activo,
        cliente_id,
    )
    if not row:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    out = dict(row)
    out["nombre"] = out["razon_social"]
    return out


@router.post(
    "/clientes/{cliente_id}/sucursales",
    summary="Crear sucursal/planta para un cliente (Admin)",
    tags=["Catálogos", "Admin"],
    status_code=status.HTTP_201_CREATED,
)
async def crear_sucursal_cliente(
    cliente_id: int,
    body: SucursalWriteBody,
    db=Depends(get_db),
    _=Depends(require_roles("admin", "administrador", "superadmin", "jefe", "gerente", "logistica")),
):
    nom = (body.nombre_sucursal or body.nombre or "").strip()
    dir_val = (body.direccion or "").strip()
    if not nom and not dir_val:
        raise HTTPException(status_code=400, detail="nombre_sucursal o direccion requerido")
    if not nom:
        nom = dir_val[:80]
    row = await db.fetchrow(
        """
        INSERT INTO cliente_sucursales (
            cliente_id, nombre_sucursal, direccion, contacto_nombre, contacto_telefono, activo
        ) VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id, cliente_id,
                  COALESCE(nombre_sucursal,'') AS nombre_sucursal,
                  COALESCE(direccion,'') AS direccion,
                  COALESCE(contacto_nombre,'') AS contacto_nombre,
                  COALESCE(contacto_telefono,'') AS contacto_telefono,
                  COALESCE(activo, TRUE) AS activo
        """,
        cliente_id,
        nom,
        dir_val or "",
        (body.contacto_nombre or "").strip() or None,
        (body.contacto_telefono or "").strip() or None,
        True if body.activo is None else bool(body.activo),
    )
    return dict(row)


@router.put(
    "/clientes/{cliente_id}/sucursales/{sucursal_id}",
    summary="Actualizar sucursal de un cliente (Admin)",
    tags=["Catálogos", "Admin"],
)
async def actualizar_sucursal_cliente(
    cliente_id: int,
    sucursal_id: int,
    body: SucursalWriteBody,
    db=Depends(get_db),
    _=Depends(require_roles("admin", "administrador", "superadmin", "jefe", "gerente", "logistica")),
):
    nom = (body.nombre_sucursal or body.nombre or "").strip() or None
    row = await db.fetchrow(
        """
        UPDATE cliente_sucursales
        SET nombre_sucursal   = COALESCE($1, nombre_sucursal),
            direccion         = COALESCE($2, direccion),
            contacto_nombre   = COALESCE($3, contacto_nombre),
            contacto_telefono = COALESCE($4, contacto_telefono),
            activo            = COALESCE($5, activo)
        WHERE id = $6 AND cliente_id = $7
        RETURNING id, cliente_id,
                  COALESCE(nombre_sucursal,'') AS nombre_sucursal,
                  COALESCE(direccion,'') AS direccion,
                  COALESCE(contacto_nombre,'') AS contacto_nombre,
                  COALESCE(contacto_telefono,'') AS contacto_telefono,
                  COALESCE(activo, TRUE) AS activo
        """,
        nom,
        (body.direccion or "").strip() or None,
        (body.contacto_nombre or "").strip() or None,
        (body.contacto_telefono or "").strip() or None,
        body.activo,
        sucursal_id,
        cliente_id,
    )
    if not row:
        raise HTTPException(status_code=404, detail="Sucursal no encontrada")
    return dict(row)


@router.patch(
    "/ordenes/{folio}/asignar",
    summary="Reasignar orden de servicio a técnico y/o modalidad (Admin)",
    tags=["Catálogos", "Admin", "Órdenes de Servicio"],
)
@router.post(
    "/ordenes/{folio}/asignar",
    summary="Reasignar orden de servicio a técnico y/o modalidad (Admin alias POST)",
    tags=["Catálogos", "Admin", "Órdenes de Servicio"],
)
async def asignar_orden_admin(
    folio: str,
    body: AsignarOrdenBody,
    db=Depends(get_db),
    _=Depends(require_roles("admin", "administrador", "superadmin", "jefe", "gerente", "logistica")),
):
    clean_folio = (folio or "").strip()
    trow = await db.fetchrow(
        "SELECT id, nombre_completo FROM cat_tecnicos WHERE id = $1",
        body.id_tecnico,
    )
    if not trow:
        raise HTTPException(status_code=404, detail=f"Técnico id={body.id_tecnico} no encontrado")

    mod_norm = _normalizar_modalidad(body.modalidad) if body.modalidad else None
    est_norm = (body.estatus or "").strip() or None
    row = await db.fetchrow(
        """
        UPDATE ordenes_servicio
        SET id_tecnico = $1,
            modalidad  = COALESCE($2, modalidad),
            estatus    = COALESCE($3, estatus),
            updated_at = NOW(),
            sync_version = COALESCE(sync_version, 0) + 1
        WHERE folio_os = $4 OR id::text = $4
        RETURNING id, folio_os, id_tecnico, modalidad, estado, estatus
        """,
        body.id_tecnico,
        mod_norm,
        est_norm,
        clean_folio,
    )
    if not row:
        raise HTTPException(status_code=404, detail=f"Orden {clean_folio} no encontrada")
    out = dict(row)
    out["tecnico"] = str(trow["nombre_completo"] or "")
    out["ok"] = True
    return out


