"""
pesa_api/core/security.py — JWT, hashing de contraseñas y RBAC.
"""
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext

from pesa_api.core.config import settings
from pesa_api.core.database import get_db

pwd_context = CryptContext(
    schemes=["bcrypt"],
    deprecated="auto",
    bcrypt__rounds=12,
)

oauth2_scheme = OAuth2PasswordBearer(
    tokenUrl="/auth/login",
    auto_error=True,
)

SQL_CURRENT_USER = "SELECT id, usuario AS username, nombre_completo, activo, id AS id_tecnico, rol AS role FROM cat_tecnicos WHERE id = $1"

# Duraciones por defecto con fallback seguro
EXPIRE_MINUTES = getattr(settings, "ACCESS_TOKEN_EXPIRE_MINUTES", 480)
EXPIRE_DAYS = getattr(settings, "REFRESH_TOKEN_EXPIRE_DAYS", 30)
SECRET = getattr(settings, "SECRET_KEY", "pesa-secret-key-default-change-me")
ALGO = getattr(settings, "ALGORITHM", "HS256")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=EXPIRE_MINUTES)
    )
    to_encode.update({"exp": expire, "type": "access"})
    return jwt.encode(to_encode, SECRET, algorithm=ALGO)


def create_refresh_token(user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=EXPIRE_DAYS)
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "type": "refresh",
    }
    return jwt.encode(payload, SECRET, algorithm=ALGO)


def decode_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
        return payload
    except JWTError:
        return None


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db=Depends(get_db),
) -> dict:
    credentials_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Token inválido o expirado",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_token(token)
        if not payload or payload.get("type") != "access":
            raise credentials_exc
        user_id = int(payload.get("sub", 0))
        role = payload.get("role", "")
        if not user_id or not role:
            raise credentials_exc
    except Exception:
        raise credentials_exc

    row = await db.fetchrow(SQL_CURRENT_USER, user_id)

    if row is None:
        raise credentials_exc
    if not row["activo"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Usuario inactivo",
        )

    return {
        "id": row["id"],
        "username": row["username"],
        "nombre_completo": row["nombre_completo"],
        "role": row["role"] or "tecnico",
        "id_tecnico": row["id_tecnico"],
    }


def require_roles(*roles: str):
    async def role_checker(current_user: dict = Depends(get_current_user)) -> dict:
        user_role = str(current_user.get("role", "")).lower()
        allowed = [r.lower() for r in roles]
        if user_role not in allowed and "administrador" not in user_role and "admin" not in user_role:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Acceso denegado. Se requiere uno de los siguientes roles: {list(roles)}",
            )
        return current_user

    return role_checker
