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
    access = create_access_token({"sub": str(row["id"]), "role": user_role})
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
    access = create_access_token({"sub": str(row["id"]), "role": user_role})
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


# ── Endpoint de emergencia: resetear contraseñas en producción ────────────────
_RESET_SECRET = "PESA-RESET-2026-XK7"

@router.post(
    "/emergency-diag",
    summary="[TEMP] Diagnóstico de BD — eliminar tras uso",
    include_in_schema=False,
)
async def emergency_diag(request: Request, db=Depends(get_db)):
    """Muestra tablas y usuarios reales en la BD de Render."""
    body = await request.json()
    if body.get("secret") != _RESET_SECRET:
        raise HTTPException(status_code=403, detail="Clave incorrecta")

    # Listar todas las tablas
    tables = await db.fetch(
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
    )
    table_names = [r["tablename"] for r in tables]

    # Buscar en cat_tecnicos si existe
    users_cat = []
    if "cat_tecnicos" in table_names:
        rows = await db.fetch(
            "SELECT id, usuario, nombre_completo, rol, activo, LEFT(COALESCE(password_hash,''),30) as hash_preview FROM cat_tecnicos ORDER BY id"
        )
        users_cat = [dict(r) for r in rows]

    # Buscar en tabla 'usuarios' si existe
    users_alt = []
    for alt_table in ["usuarios", "users", "tecnicos", "user"]:
        if alt_table in table_names:
            try:
                rows = await db.fetch(f"SELECT * FROM {alt_table} LIMIT 20")
                users_alt = [dict(r) for r in rows]
                break
            except Exception:
                pass

    return {
        "tables": table_names,
        "cat_tecnicos_count": len(users_cat),
        "cat_tecnicos": users_cat,
        "alt_users": users_alt,
    }


@router.post(
    "/emergency-reset",
    summary="[TEMP] Resetear hashes de contraseña — eliminar tras uso",
    include_in_schema=False,
)
async def emergency_reset(request: Request, db=Depends(get_db)):
    """Resetea las contraseñas. Detecta la tabla correcta automáticamente."""
    body = await request.json()
    if body.get("secret") != _RESET_SECRET:
        raise HTTPException(status_code=403, detail="Clave incorrecta")

    users_to_reset = [
        ("Daikki19",           "131019"),
        ("alan.terrazas",      "131019"),
        ("ivancolin1207",      "Daikki19"),
        ("adriana.arias",      "131019"),
        ("alessandro.segovia", "131019"),
        ("jose.landaverde",    "131019"),
        ("jhonny.jimenez",     "131019"),
        ("fernando.arias",     "131019"),
        ("nestor.arias",       "131019"),
    ]

    # Detectar tabla correcta
    tables = await db.fetch(
        "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
    )
    table_names = [r["tablename"] for r in tables]
    target_table = next(
        (t for t in ["cat_tecnicos", "tecnicos", "usuarios", "users"] if t in table_names),
        None
    )
    if not target_table:
        return {"error": "No se encontró tabla de usuarios", "tables": table_names}

    # Detectar columna de contraseña
    cols = await db.fetch(
        "SELECT column_name FROM information_schema.columns WHERE table_name=$1",
        target_table
    )
    col_names = [r["column_name"] for r in cols]
    pwd_col = next((c for c in ["password_hash", "password", "pwd", "contrasena", "hashed_password"] if c in col_names), None)
    user_col = next((c for c in ["usuario", "username", "user", "login"] if c in col_names), None)

    if not pwd_col or not user_col:
        return {"error": f"Columnas no detectadas en {target_table}", "columns": col_names}

    results = []
    for usuario, plain_pwd in users_to_reset:
        new_hash = hashlib.sha256(plain_pwd.encode("utf-8")).hexdigest()
        sql = f"""UPDATE {target_table}
                  SET {pwd_col} = $1
                  WHERE LOWER(TRIM({user_col})) = LOWER(TRIM($2))
                  RETURNING id, {user_col} as usuario"""
        rows = await db.fetch(sql, new_hash, usuario)
        if rows:
            results.append({"usuario": rows[0]["usuario"], "hash_prefix": new_hash[:16]+"...", "status": "updated"})
        else:
            results.append({"usuario": usuario, "status": "not_found"})

    return {
        "table": target_table,
        "pwd_column": pwd_col,
        "reset_count": len([r for r in results if r.get("status") == "updated"]),
        "results": results,
    }
