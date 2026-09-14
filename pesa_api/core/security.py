"""
pesa_api/core/security.py — JWT, bcrypt y dependencias de autenticación.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt
from jose import JWTError, jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

from pesa_api.core.config   import settings
from pesa_api.core.database import get_db

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")

# ─── Hashing ─────────────────────────────────────────────────────────────────

def hash_password(plain: str) -> str:
    """Genera hash bcrypt de la contraseña."""
    return bcrypt.hashpw(plain.encode(), bcrypt.gensalt(rounds=12)).decode()


def verify_password(plain: str, hashed: str) -> bool:
    """Verifica contraseña contra hash bcrypt."""
    return bcrypt.checkpw(plain.encode(), hashed.encode())


# ─── JWT ─────────────────────────────────────────────────────────────────────

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    payload = data.copy()
    expire  = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=settings.JWT_EXPIRE_MINUTES)
    )
    payload.update({"exp": expire, "type": "access"})
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)


def create_refresh_token(user_id: int) -> str:
    payload = {
        "sub":  str(user_id),
        "type": "refresh",
        "exp":  datetime.now(timezone.utc) + timedelta(days=settings.REFRESH_EXPIRE_DAYS),
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)


def decode_token(token: str) -> dict:
    """Decodifica y valida un JWT. Lanza JWTError si es inválido."""
    return jwt.decode(token, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])


# ─── Dependencias FastAPI ─────────────────────────────────────────────────────

async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db          = Depends(get_db),
) -> dict:
    """
    Dependency: valida el JWT y retorna el usuario activo desde la BD.
    Inyectable en cualquier endpoint protegido.
    """
    credentials_exc = HTTPException(
        status_code = status.HTTP_401_UNAUTHORIZED,
        detail      = "Token inválido o expirado",
        headers     = {"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_token(token)
        user_id = int(payload.get("sub", 0))
        role    = payload.get("role", "")
        if not user_id or not role:
            raise credentials_exc
    except JWTError:
        raise credentials_exc

    row = await db.fetchrow(
        """
        SELECT u.id, u.username, u.nombre_completo, u.activo,
               u.id_tecnico, r.nombre AS role
        FROM usuarios u JOIN roles r ON u.id_rol = r.id
        WHERE u.id = $1 AND u.activo = TRUE
        """,
        user_id,
    )
    if row is None:
        raise credentials_exc

    return dict(row)


def require_roles(*roles: str):
    """
    Dependency factory para restringir endpoint a roles específicos.

    Uso:
        @router.get("/admin-only")
        async def endpoint(user = Depends(require_roles("admin", "logistica"))):
            ...
    """
    async def _inner(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user["role"] not in roles:
            raise HTTPException(
                status_code = status.HTTP_403_FORBIDDEN,
                detail      = f"Acceso denegado. Roles permitidos: {list(roles)}",
            )
        return current_user
    return _inner
