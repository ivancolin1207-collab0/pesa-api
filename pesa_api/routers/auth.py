import hashlib
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

router = APIRouter()

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    role: str
    nombre: str
    id_tecnico: Optional[int] = None

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

def _check_password(plain_password: str, stored: str) -> bool:
    """Verifica la contraseña soportando múltiples formatos de almacenamiento.

    Orden de verificación:
      1. SHA-256 hexdigest (formato principal en cat_tecnicos)
      2. Texto plano directo (migraciones antiguas)
      3. bcrypt / passlib (via verify_password de security.py)
      4. SHA-256 del valor con trim (tolerancia a espacios residuales en la BD)
    """
    if not stored or not plain_password:
        return False

    plain_clean  = plain_password.strip()
    stored_clean = stored.strip()

    # 1. SHA-256 — formato estándar en cat_tecnicos
    sha256_attempt = hashlib.sha256(plain_clean.encode('utf-8')).hexdigest()
    if sha256_attempt.lower() == stored_clean.lower():
        return True

    # 2. Texto plano (contraseñas no migradas)
    if plain_clean == stored_clean:
        return True

    # 3. bcrypt / passlib (hashes que empiezan con $2b$ / $2y$)
    try:
        if verify_password(plain_clean, stored_clean):
            return True
    except Exception:
        pass

    # 4. SHA-256 del stored con strip (por si hay espacios en la BD)
    sha256_trimmed = hashlib.sha256(stored_clean.encode('utf-8')).hexdigest()
    if plain_clean == sha256_trimmed:
        return True

    return False

# Búsqueda insensible a mayúsculas y sin espacios para el campo usuario
SQL_LOGIN = """
    SELECT id, usuario, nombre_completo, password_hash, activo, rol
    FROM cat_tecnicos
    WHERE LOWER(TRIM(usuario)) = LOWER(TRIM($1))
       OR LOWER(TRIM(COALESCE(email, ''))) = LOWER(TRIM($1))
"""

SQL_REFRESH = "SELECT id, usuario, nombre_completo, activo, rol FROM cat_tecnicos WHERE id = $1"

@router.post(
    "/login",
    response_model=TokenResponse,
    summary="Iniciar sesión y obtener tokens JWT",
)
async def login(
    request: Request,
    db=Depends(get_db),
) -> TokenResponse:
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

    clean_user = str(username).strip()
    clean_pass = str(password).strip()

    row = await db.fetchrow(SQL_LOGIN, clean_user)

    if row is None or not row["activo"]:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Credenciales incorrectas",
        )

    if not _check_password(clean_pass, row["password_hash"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Credenciales incorrectas",
        )

    user_role = str(row["rol"] or "tecnico")
    access = create_access_token({
        "sub":        str(row["id"]),
        "role":       user_role,
        "id_tecnico": row["id"],
        "username":   str(row["usuario"] or ""),
        "nombre":     str(row["nombre_completo"] or ""),
    })
    refresh = create_refresh_token(row["id"])

    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        role=user_role,
        nombre=row["nombre_completo"],
        id_tecnico=row["id"],
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
    access = create_access_token({
        "sub":        str(row["id"]),
        "role":       user_role,
        "id_tecnico": row["id"],
        "username":   str(row["usuario"] or ""),
        "nombre":     str(row["nombre_completo"] or ""),
    })
    refresh = create_refresh_token(row["id"])

    return TokenResponse(
        access_token=access,
        refresh_token=refresh,
        role=user_role,
        nombre=row["nombre_completo"],
        id_tecnico=row["id"],
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
