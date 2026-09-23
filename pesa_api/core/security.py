"""
pesa_api/core/security.py — JWT, hashing de contraseñas y RBAC.
"""
import os
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

# ── Resolución de la clave JWT ────────────────────────────────────────────────
# Fuente única de verdad: settings.JWT_SECRET (que lee PESA_JWT_SECRET del entorno).
# El fallback hardcoded es IDÉNTICO al de config.py para evitar discrepancias
# cuando Render no tiene PESA_JWT_SECRET configurado en Environment Variables.
# [FIX-401] Esta era la causa raíz del bucle 401: dos fallbacks distintos entre
#            config.py y security.py firmaban/validaban con claves diferentes.
_SECRET = settings.JWT_SECRET  # settings.JWT_SECRET = os.getenv("PESA_JWT_SECRET", "CAMBIAR-EN-PRODUCCION-secret-pesa-2026")
_ALGO   = settings.JWT_ALGORITHM
# Access token: 30 días (43,200 min) para técnicos de campo sin conexión frecuente
_ACCESS_MINUTES = int(os.environ.get(
    "PESA_JWT_EXPIRE_MINUTES",
    getattr(settings, "JWT_EXPIRE_MINUTES", 43_200)  # 30 días por defecto
))
# Refresh token: 90 días
_REFRESH_DAYS = int(os.environ.get(
    "PESA_REFRESH_EXPIRE_DAYS",
    getattr(settings, "REFRESH_EXPIRE_DAYS", 90)
))


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    delta = expires_delta if expires_delta is not None else timedelta(minutes=int(_ACCESS_MINUTES))
    expire = datetime.now(timezone.utc) + delta
    to_encode.update({"exp": expire, "type": "access"})
    return jwt.encode(to_encode, _SECRET, algorithm=_ALGO)


def create_refresh_token(user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=int(_REFRESH_DAYS))
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "type": "refresh",
    }
    return jwt.encode(payload, _SECRET, algorithm=_ALGO)


def decode_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(token, _SECRET, algorithms=[_ALGO])
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
        if not user_id:
            raise credentials_exc
        # role puede estar vacío en tokens legacy — se resuelve desde la BD más abajo
        role_from_token = payload.get("role", "")
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

    # Prioridad: rol de BD (siempre actualizado) > rol del token
    db_role = str(row["role"] or "").strip()
    effective_role = db_role if db_role else (str(role_from_token).strip() or "tecnico")

    return {
        "id": row["id"],
        "username": row["username"],
        "nombre_completo": row["nombre_completo"],
        # [FIX-SYNC] Alias 'nombre' para compatibilidad con sync_pull y otros routers
        # que acceden a current_user.get('nombre'). Ambas claves apuntan al mismo valor.
        "nombre": row["nombre_completo"],
        "role": effective_role,
        "id_tecnico": row["id_tecnico"],
    }


# ---------------------------------------------------------------------------
# Normalización robusta de roles — maneja tildes, mayúsculas y espacios
# ---------------------------------------------------------------------------
import unicodedata as _ud

def _normalizar_rol(rol: str) -> str:
    """Convierte rol a forma canónica: sin tildes, lowercase, sin espacios."""
    if not rol:
        return ""
    s = _ud.normalize('NFKD', str(rol)).encode('ASCII', 'ignore').decode('utf-8')
    return s.lower().strip().replace(" ", "_").replace("-", "_")


# Roles que son equivalentes a 'tecnico' para efectos de autorización
_TECNICO_ROLES = frozenset({
    "tecnico", "tecnico_campo", "tecnico_externo", "tecnico_de_campo",
    "servicio", "operativo", "calibrador", "inspector",
    "tecnico_calibrador", "tecnico_inspector",
})

# Mapa de roles normalizados con tildes → canónico
_ROL_MAP = {
    "tecnico":            "tecnico",
    "tecnico_campo":      "tecnico",
    "tecnico_de_campo":   "tecnico",
    "servicio":           "tecnico",
    "operativo":          "tecnico",
    "calibrador":         "tecnico",
    "inspector":          "tecnico",
    "tecnico_calibrador": "tecnico",
    "tecnico_inspector":  "tecnico",
    "admin":              "admin",
    "administrador":      "admin",
    "logistica":          "logistica",
    "recepcion":          "recepcion",
}


def require_roles(*roles: str):
    async def role_checker(current_user: dict = Depends(get_current_user)) -> dict:
        raw_role  = str(current_user.get("role", ""))
        user_role = _normalizar_rol(raw_role)
        # Mapear al rol canónico si existe
        user_role_canon = _ROL_MAP.get(user_role, user_role)

        allowed      = {_normalizar_rol(r) for r in roles}
        allowed_also = {_ROL_MAP.get(r, r) for r in allowed}

        # 1. Rol exacto (normalizado)
        if user_role in allowed or user_role_canon in allowed_also:
            return current_user

        # 2. Admin siempre puede
        if user_role_canon == "admin" or "admin" in user_role:
            return current_user

        # 3. Cualquier variante de técnico es válida cuando se acepta tecnico/servicio
        if user_role in _TECNICO_ROLES and (
            allowed & (_TECNICO_ROLES | {"tecnico", "servicio", "tecnico_campo", "operativo"})
        ):
            return current_user

        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Acceso denegado. Se requiere uno de los siguientes roles: {list(roles)}",
        )

    return role_checker
