"""
pesa_api/routers/auth.py — Endpoints de autenticación JWT.

POST /auth/login   → Retorna access_token + refresh_token
POST /auth/refresh → Renueva el access_token con el refresh_token
GET  /auth/me      → Perfil del usuario autenticado
POST /auth/logout  → Invalida el refresh_token en BD
"""
from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel

from pesa_api.core.database import get_db
from pesa_api.core.security import (
    verify_password, create_access_token, create_refresh_token,
    decode_token, get_current_user,
)

router = APIRouter()


# ── Schemas ────────────────────────────────────────────────────────────────────

class TokenResponse(BaseModel):
    access_token:  str
    refresh_token: str
    token_type:    str = "bearer"
    role:          str
    nombre:        str
    id_tecnico:    int | None = None


class RefreshRequest(BaseModel):
    refresh_token: str


class UserProfile(BaseModel):
    id:              int
    username:        str
    nombre_completo: str
    role:            str
    id_tecnico:      int | None


# ── Helper ────────────────────────────────────────────────────────────────────

def _hash_token(token: str) -> str:
    """SHA256 del refresh token para almacenarlo en BD sin texto plano."""
    return hashlib.sha256(token.encode()).hexdigest()


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post(
    "/login",
    response_model = TokenResponse,
    summary        = "Iniciar sesión y obtener tokens JWT",
)
async def login(
    form: OAuth2PasswordRequestForm = Depends(),
    db   = Depends(get_db),
) -> TokenResponse:
    """
    Autentica al usuario verificando la contraseña bcrypt directamente en PostgreSQL
    (mismo mecanismo que la app de escritorio).

    Retorna access_token (8h) y refresh_token (7d).
    """
    row = await db.fetchrow(
        """
        SELECT u.id, u.username, u.nombre_completo, u.password_hash,
               u.activo, u.id_tecnico, r.nombre AS role
        FROM usuarios u
        JOIN roles r ON u.id_rol = r.id
        WHERE u.username = $1
        """,
        form.username,
    )

    # Verificar existencia y contraseña (bcrypt)
    if row is None or not row["activo"]:
        raise HTTPException(
            status_code = status.HTTP_401_UNAUTHORIZED,
            detail      = "Credenciales incorrectas",
        )

    if not verify_password(form.password, row["password_hash"]):
        raise HTTPException(
            status_code = status.HTTP_401_UNAUTHORIZED,
            detail      = "Credenciales incorrectas",
        )

    # Generar tokens
    access  = create_access_token({"sub": str(row["id"]), "role": row["role"]})
    refresh = create_refresh_token(row["id"])

    # Almacenar hash del refresh token e actualizar ultimo_login
    await db.execute(
        """
        UPDATE usuarios
        SET token_refresh_hash = $1, ultimo_login = $2
        WHERE id = $3
        """,
        _hash_token(refresh),
        datetime.now(timezone.utc),
        row["id"],
    )

    return TokenResponse(
        access_token  = access,
        refresh_token = refresh,
        role          = row["role"],
        nombre        = row["nombre_completo"],
        id_tecnico    = row["id_tecnico"],
    )


@router.post(
    "/refresh",
    response_model = TokenResponse,
    summary        = "Renovar access token con refresh token",
)
async def refresh_token_endpoint(
    body: RefreshRequest,
    db   = Depends(get_db),
) -> TokenResponse:
    """
    Valida el refresh token y emite un nuevo par de tokens.
    El refresh token anterior queda invalidado (rotación de tokens).
    """
    try:
        payload = decode_token(body.refresh_token)
        if payload.get("type") != "refresh":
            raise ValueError("tipo inválido")
        user_id = int(payload["sub"])
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token inválido")

    row = await db.fetchrow(
        """
        SELECT u.id, u.username, u.nombre_completo, u.token_refresh_hash,
               u.activo, u.id_tecnico, r.nombre AS role
        FROM usuarios u JOIN roles r ON u.id_rol = r.id
        WHERE u.id = $1
        """,
        user_id,
    )

    if (
        row is None
        or not row["activo"]
        or row["token_refresh_hash"] != _hash_token(body.refresh_token)
    ):
        raise HTTPException(
            status_code = status.HTTP_401_UNAUTHORIZED,
            detail      = "Refresh token inválido o ya utilizado",
        )

    # Rotar tokens
    access  = create_access_token({"sub": str(row["id"]), "role": row["role"]})
    refresh = create_refresh_token(row["id"])

    await db.execute(
        "UPDATE usuarios SET token_refresh_hash = $1 WHERE id = $2",
        _hash_token(refresh), row["id"],
    )

    return TokenResponse(
        access_token  = access,
        refresh_token = refresh,
        role          = row["role"],
        nombre        = row["nombre_completo"],
        id_tecnico    = row["id_tecnico"],
    )


@router.get(
    "/me",
    response_model = UserProfile,
    summary        = "Obtener perfil del usuario autenticado",
)
async def me(current_user: dict = Depends(get_current_user)) -> UserProfile:
    """Retorna los datos del usuario dueño del token JWT."""
    return UserProfile(**current_user)


@router.post("/logout", summary="Cerrar sesión e invalidar refresh token")
async def logout(
    current_user: dict = Depends(get_current_user),
    db = Depends(get_db),
):
    """Invalida el refresh token almacenado en BD."""
    await db.execute(
        "UPDATE usuarios SET token_refresh_hash = NULL WHERE id = $1",
        current_user["id"],
    )
    return {"detail": "Sesión cerrada exitosamente"}
