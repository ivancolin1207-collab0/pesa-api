"""
seed.py — Sembrado de datos iniciales para Servicios PESA.

Inserta los usuarios/roles mínimos si no existen en la BD.
Se llama automáticamente desde main.py tras conectar a PostgreSQL.

Uso manual:
    python servicios_pesa/database/seed.py
"""
from __future__ import annotations
import hashlib
import json
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def _sha256(text: str) -> str:
    """SHA-256 hex digest — mismo algoritmo que LoginDialog._hash_pw()."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ─── Usuarios a sembrar ────────────────────────────────────────────────────────
# Añade aquí cualquier usuario inicial. Si ya existe (ON CONFLICT), solo
# actualiza la contraseña y activo=TRUE sin tocar otros campos.
_DEFAULT_USERS = [
    {
        "nombre_completo": "Iván Colín",
        "usuario":         "ivancolin1207",
        "password":        "131019",
        "rol":             "Administrador",
        "roles":           ["Administrador"],
    },
]


def sembrar_usuarios(conn) -> list[str]:
    """
    Inserta/actualiza los usuarios por defecto en cat_tecnicos.

    Args:
        conn: Conexión psycopg2 ya abierta y activa.

    Returns:
        Lista de nombres de usuario procesados.
    """
    procesados: list[str] = []

    with conn.cursor() as cur:
        # Verificar qué columnas existen en cat_tecnicos
        cur.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name   = 'cat_tecnicos'
            """
        )
        columnas = {row[0] for row in cur.fetchall()}
        tiene_roles   = "roles"  in columnas
        tiene_pwdhash = "password_hash" in columnas

        if not tiene_pwdhash:
            logger.warning("seed: cat_tecnicos no tiene password_hash — no se puede sembrar.")
            return []

        for user in _DEFAULT_USERS:
            usuario   = user["usuario"]
            pwd_hash  = _sha256(user["password"])
            rol       = user["rol"]
            roles_json = json.dumps(user["roles"]) if tiene_roles else None

            try:
                if tiene_roles:
                    cur.execute(
                        """
                        INSERT INTO cat_tecnicos
                            (nombre_completo, usuario, password_hash, rol, roles, activo)
                        VALUES (%s, %s, %s, %s, %s, TRUE)
                        ON CONFLICT (usuario) DO UPDATE
                        SET password_hash = EXCLUDED.password_hash,
                            rol           = EXCLUDED.rol,
                            roles         = EXCLUDED.roles,
                            activo        = TRUE
                        RETURNING id, usuario, rol
                        """,
                        (user["nombre_completo"], usuario, pwd_hash, rol, roles_json),
                    )
                else:
                    cur.execute(
                        """
                        INSERT INTO cat_tecnicos
                            (nombre_completo, usuario, password_hash, rol, activo)
                        VALUES (%s, %s, %s, %s, TRUE)
                        ON CONFLICT (usuario) DO UPDATE
                        SET password_hash = EXCLUDED.password_hash,
                            rol           = EXCLUDED.rol,
                            activo        = TRUE
                        RETURNING id, usuario, rol
                        """,
                        (user["nombre_completo"], usuario, pwd_hash, rol),
                    )

                row = cur.fetchone()
                if row:
                    logger.info(
                        "seed: usuario id=%s '%s' (%s) sembrado OK",
                        row[0], row[1], row[2],
                    )
                    procesados.append(usuario)

            except Exception as exc:
                logger.error("seed: error sembrando '%s': %s", usuario, exc)
                conn.rollback()
                continue

        conn.commit()

    return procesados


def run_seed() -> bool:
    """
    Conecta a la BD y ejecuta el sembrado.
    Retorna True si el sembrado completó sin errores, False si falló.
    """
    _root = Path(__file__).resolve().parent.parent
    if str(_root) not in sys.path:
        sys.path.insert(0, str(_root))

    try:
        from database.connection import db_pool
        db_pool.initialize()
        conn = db_pool.get_connection()
        try:
            procesados = sembrar_usuarios(conn)
            print(f"[SEED] Usuarios sembrados: {procesados or 'ninguno nuevo'}")
            return True
        finally:
            db_pool.release_connection(conn)
    except Exception as exc:
        logger.error("seed: fallo al conectar/sembrar — %s", exc)
        print(f"[SEED ERROR] {exc}")
        return False


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    ok = run_seed()
    sys.exit(0 if ok else 1)
