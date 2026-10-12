import hashlib
import hmac
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import (
    verify_password,
    create_access_token,
    create_refresh_token,
    decode_token,
    get_current_user,
)

import logging
import re

logger = logging.getLogger("pesa_api.auth")

router = APIRouter()

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    role: str
    nombre: str
    id_tecnico: Optional[int] = None
    # Perfil completo (v3.1.20+78)
    id: Optional[int] = None
    usuario: Optional[str] = None
    rol: Optional[str] = None
    firma_digital: Optional[str] = None

class RefreshRequest(BaseModel):
    refresh_token: str

class UserProfile(BaseModel):
    id: int
    username: str
    nombre_completo: str
    role: str
    id_tecnico: Optional[int] = None

def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()

_SHA256_HEX = re.compile(r"^[0-9a-fA-F]{64}$")


def normalizar_usuario(raw) -> str:
    """'  Alan. Terrazas ' → 'alan.terrazas'.

    Los teclados Android insertan mayúscula y espacio tras el punto; ningún
    usuario de cat_tecnicos contiene espacios, así que se eliminan todos.
    """
    return re.sub(r"\s+", "", str(raw or "")).lower()


def _check_password(plain_password: str, stored: str) -> bool:
    """Verifica la contraseña soportando los formatos de almacenamiento existentes.

    Orden de verificación:
      1. SHA-256 hexdigest (formato principal en cat_tecnicos)
      2. bcrypt / passlib (hashes que empiezan con $2a$ / $2b$ / $2y$)
      3. Texto plano (migraciones antiguas) — SOLO si lo almacenado no es un
         hash; así el propio hash nunca sirve como contraseña (pass-the-hash).
    """
    if not stored or not plain_password:
        return False

    plain_clean  = plain_password.strip()
    stored_clean = stored.strip()
    if not plain_clean or not stored_clean:
        return False

    # 1. SHA-256 — formato estándar en cat_tecnicos
    if _SHA256_HEX.match(stored_clean):
        sha256_attempt = hashlib.sha256(plain_clean.encode('utf-8')).hexdigest()
        return hmac.compare_digest(sha256_attempt.lower(), stored_clean.lower())

    # 2. bcrypt / passlib
    if stored_clean.startswith("$2"):
        try:
            return verify_password(plain_clean, stored_clean)
        except Exception:
            return False

    # 3. Texto plano (contraseñas no migradas)
    # TODO(security): migrar estos registros a bcrypt/argon2 y eliminar este camino.
    return hmac.compare_digest(plain_clean, stored_clean)


# Búsqueda insensible a mayúsculas y espacios (también internos) del usuario.
# to_jsonb(t) tolera instalaciones donde las columnas legacy no existen.
SQL_LOGIN = """
    SELECT t.id, t.usuario, t.nombre_completo, t.password_hash, t.activo, t.rol,
           to_jsonb(t)->>'password'      AS password_legacy,
           to_jsonb(t)->>'firma_digital' AS firma_digital
    FROM cat_tecnicos t
    WHERE LOWER(REGEXP_REPLACE(COALESCE(t.usuario, ''), '\\s', '', 'g')) = $1
       OR LOWER(TRIM(COALESCE(t.email, ''))) = $1
    ORDER BY (LOWER(REGEXP_REPLACE(COALESCE(t.usuario, ''), '\\s', '', 'g')) = $1) DESC,
             t.activo DESC NULLS LAST, t.id
    LIMIT 1
"""

SQL_REFRESH = "SELECT id, usuario, nombre_completo, activo, rol FROM cat_tecnicos WHERE id = $1"

_CRED_INVALIDAS = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Credenciales incorrectas",
)

@router.post(
    "/login",
    response_model=TokenResponse,
    summary="Iniciar sesión y obtener tokens JWT",
)
async def login(
    request: Request,
    db=Depends(get_db),
) -> TokenResponse:
    # TODO(security): agregar rate limiting por IP/usuario (p. ej. slowapi) en /auth/login.
    content_type = request.headers.get("content-type", "")

    username = None
    password = None

    if "application/json" in content_type:
        try:
            body = await request.json()
            username = body.get("username") or body.get("usuario")
            password = body.get("password") or body.get("contrasena")
        except Exception:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="JSON mal formado",
            )
    else:
        form = await request.form()
        username = form.get("username") or form.get("usuario")
        password = form.get("password") or form.get("contrasena")

    if not username or not password:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Faltan credenciales (usuario y contrasena obligatorios)",
        )

    clean_user = normalizar_usuario(username)
    clean_pass = str(password).strip()
    if not clean_user or not clean_pass or len(clean_user) > 150 or len(clean_pass) > 256:
        raise _CRED_INVALIDAS

    try:
        row = await db.fetchrow(SQL_LOGIN, clean_user)
    except Exception as exc:
        # Nunca 500 en login: error de BD → 503 genérico (detalle solo en logs).
        logger.error("[LOGIN] Error consultando cat_tecnicos: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Servicio de autenticación no disponible. Intenta en unos segundos.",
        )

    if row is None or not row["activo"]:
        logger.info("[LOGIN] Rechazado (usuario inexistente o inactivo): %s", clean_user)
        raise _CRED_INVALIDAS

    stored_hash = (row["password_hash"] or "").strip()
    if stored_hash:
        ok = _check_password(clean_pass, stored_hash)
    else:
        # Hash pendiente de migrar: validar contra la credencial legacy del propio
        # usuario. No existe contraseña "por defecto" (fail-closed).
        ok = _check_password(clean_pass, row["password_legacy"] or "")

    if not ok:
        logger.info("[LOGIN] Rechazado (contraseña inválida): %s", clean_user)
        raise _CRED_INVALIDAS

    user_role = str(row["rol"] or "tecnico")
    usuario   = str(row["usuario"] or clean_user).strip()
    nombre    = str(row["nombre_completo"] or usuario).strip()
    access = create_access_token({
        "sub":        str(row["id"]),
        "id":         row["id"],          # [FIX] ID numérico explícito para Flutter
        "role":       user_role,
        "id_tecnico": row["id"],          # Compatibilidad backward
        "username":   usuario,
        "nombre":     nombre,             # [FIX] nombre explícito para sync_pull y Flutter
    })
    refresh = create_refresh_token(row["id"])

    firma = (row["firma_digital"] or "").strip() or None
    logger.info("[LOGIN] OK: %s (id=%s, rol=%s)", usuario, row["id"], user_role)
    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        role=user_role,
        nombre=nombre,
        id_tecnico=row["id"],
        id=row["id"],
        usuario=usuario,
        rol=user_role,
        firma_digital=firma,
    )


@router.post(
    "/refresh",
    response_model=TokenResponse,
    summary="Renovar access token con refresh token",
)
async def refresh_token_endpoint(
    body: RefreshRequest,
    db=Depends(get_db),
) -> TokenResponse:
    payload = decode_token(body.refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Refresh token inválido o expirado",
        )

    user_id = int(payload["sub"])
    row = await db.fetchrow(SQL_REFRESH, user_id)

    if not row or not row["activo"]:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Usuario no encontrado o inactivo",
        )

    user_role = str(row["rol"] or "tecnico")
    usuario   = str(row["usuario"] or "").strip()
    nombre    = str(row["nombre_completo"] or usuario).strip()
    access = create_access_token({
        "sub":        str(row["id"]),
        "id":         row["id"],          # [FIX] ID numérico explícito
        "role":       user_role,
        "id_tecnico": row["id"],          # Compatibilidad backward
        "username":   usuario,
        "nombre":     nombre,             # [FIX] nombre explícito
    })
    refresh = create_refresh_token(row["id"])

    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        role=user_role,
        nombre=nombre,
        id_tecnico=row["id"],
        id=row["id"],
        usuario=usuario,
        rol=user_role,
    )

@router.get(
    "/me",
    response_model=UserProfile,
    summary="Obtener perfil del usuario autenticado",
)
async def get_me(current_user=Depends(get_current_user)):
    return UserProfile(
        id=current_user["id"],
        username=current_user.get("username", ""),
        nombre_completo=current_user.get("nombre_completo", ""),
        role=current_user.get("role", "tecnico"),
        id_tecnico=current_user.get("id_tecnico"),
    )

@router.post(
    "/logout",
    summary="Cerrar sesión e invalidar refresh token",
)
async def logout(current_user=Depends(get_current_user)):
    return {"detail": "Sesión cerrada exitosamente"}
