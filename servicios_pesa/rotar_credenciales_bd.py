"""
rotar_credenciales_bd.py — Rotación coordinada de la contraseña de PostgreSQL (Render).

NO contiene secretos: lee la contraseña ACTUAL de servicios_pesa/.env y la NUEVA
de servicios_pesa/rotacion_pendiente.env (ignorado por Git, permisos 600).

Uso:
    ../.venv/bin/python rotar_credenciales_bd.py            # simulación (no cambia nada)
    ../.venv/bin/python rotar_credenciales_bd.py --aplicar  # rota y actualiza los .env

Con --aplicar:
  1. ALTER ROLE <usuario actual> WITH PASSWORD '<nueva>' en PostgreSQL.
  2. Verifica que la nueva contraseña conecta.
  3. Actualiza PESA_DB_PASSWORD / DATABASE_URL en todos los .env locales
     (respaldo .env.bak-<fecha> de cada uno) y PESA_JWT_SECRET en pesa_api/.env.
  4. Imprime los valores exactos que hay que pegar en Render → pesa-api → Environment.
Si el paso 2 falla, revierte la contraseña a la anterior y no toca ningún archivo.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

import psycopg2
from psycopg2 import sql
from dotenv import dotenv_values

AQUI = Path(__file__).resolve().parent
RAIZ = AQUI.parent
PENDIENTE = AQUI / "rotacion_pendiente.env"

# .env locales que deben quedar con la nueva contraseña
ENV_FILES = [
    RAIZ / ".env",
    AQUI / ".env",
    AQUI / ".env.production",
    RAIZ / "pesa_api" / ".env",
    RAIZ / "Ejecutables" / "Windows" / ".env",
    Path.home() / "Library" / "Application Support" / "PesaServicios" / ".env",
]


def _mask(s: str) -> str:
    return (s[:3] + "…" + s[-2:]) if s and len(s) > 6 else "***"


def _conectar(host, port, db, user, pwd):
    return psycopg2.connect(host=host, port=port, dbname=db, user=user,
                            password=pwd, sslmode="require", connect_timeout=30)


def _reemplazar(texto: str, viejo: str, nuevo: str, jwt: str | None) -> tuple[str, int]:
    n = 0
    lineas = []
    for ln in texto.splitlines(keepends=True):
        orig = ln
        if re.match(r"\s*PESA_DB_PASSWORD\s*=", ln):
            ln = re.sub(r"=.*", "=" + nuevo, ln.rstrip("\r\n")) + ("\n" if orig.endswith("\n") else "")
        elif re.match(r"\s*DATABASE_URL\s*=", ln) and viejo and f":{viejo}@" in ln:
            ln = ln.replace(f":{viejo}@", f":{nuevo}@")
        elif jwt and re.match(r"\s*PESA_JWT_SECRET\s*=", ln):
            ln = re.sub(r"=.*", "=" + jwt, ln.rstrip("\r\n")) + ("\n" if orig.endswith("\n") else "")
        n += ln != orig
        lineas.append(ln)
    return "".join(lineas), n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--aplicar", action="store_true", help="Ejecuta la rotación real")
    args = ap.parse_args()

    actual = dotenv_values(AQUI / ".env")
    host = actual.get("PESA_DB_HOST", "")
    port = int(actual.get("PESA_DB_PORT") or 5432)
    db = actual.get("PESA_DB_NAME", "pesa_db")
    user = actual.get("PESA_DB_USER", "")
    viejo = actual.get("PESA_DB_PASSWORD", "")

    if not PENDIENTE.exists():
        print(f"ERROR: falta {PENDIENTE.name}")
        return 1
    pend = dotenv_values(PENDIENTE)
    nuevo = (pend.get("NEW_DB_PASSWORD") or "").strip()
    jwt = (pend.get("NEW_JWT_SECRET") or "").strip() or None
    if not re.fullmatch(r"[A-Za-z0-9]{24,}", nuevo):
        print("ERROR: NEW_DB_PASSWORD debe ser alfanumérica de 24+ caracteres")
        return 1

    print(f"Servidor : {host}:{port}/{db}  usuario={user}")
    print(f"Actual   : {_mask(viejo)}   Nueva: {_mask(nuevo)}")

    with _conectar(host, port, db, user, viejo) as c, c.cursor() as cur:
        cur.execute("SELECT current_user, rolcanlogin FROM pg_roles WHERE rolname = current_user")
        rol, login = cur.fetchone()
    print(f"Conexión con credencial actual: OK (rol={rol}, login={login})")

    objetivos = [p for p in ENV_FILES if p.exists()]
    for p in objetivos:
        _, n = _reemplazar(p.read_text(encoding="utf-8"), viejo, nuevo, jwt if p.parent.name == "pesa_api" else None)
        print(f"  {'actualizaría' if not args.aplicar else 'actualizará'} {n} línea(s): {p}")

    if not args.aplicar:
        print("\nSIMULACIÓN: no se cambió nada. Ejecuta con --aplicar para rotar.")
        return 0

    # 1) Rotar en PostgreSQL
    c = _conectar(host, port, db, user, viejo)
    c.autocommit = True
    with c.cursor() as cur:
        cur.execute(sql.SQL("ALTER ROLE {} WITH PASSWORD {}").format(sql.Identifier(rol), sql.Literal(nuevo)))
    print("ALTER ROLE: OK")

    # 2) Verificar; si falla, revertir
    try:
        _conectar(host, port, db, user, nuevo).close()
        print("Conexión con la NUEVA contraseña: OK")
    except Exception as e:
        print(f"!!! La nueva contraseña no conecta ({e}); revirtiendo…")
        with c.cursor() as cur:
            cur.execute(sql.SQL("ALTER ROLE {} WITH PASSWORD {}").format(sql.Identifier(rol), sql.Literal(viejo)))
        return 1
    finally:
        c.close()

    # 3) Actualizar .env locales (con respaldo)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    for p in objetivos:
        shutil.copy2(p, p.with_name(p.name + f".bak-{ts}"))
        txt, _ = _reemplazar(p.read_text(encoding="utf-8"), viejo, nuevo, jwt if p.parent.name == "pesa_api" else None)
        p.write_text(txt, encoding="utf-8")
        print(f"  actualizado: {p}")

    interno = host.split(".")[0]
    print("\n================ PEGAR EN RENDER → pesa-api → Environment ================")
    print(f"DATABASE_URL=postgresql://{user}:{nuevo}@{interno}/{db}")
    if jwt:
        print(f"PESA_JWT_SECRET={jwt}")
    print("Guarda los cambios (Render redepliega solo). Externa equivalente:")
    print(f"postgresql://{user}:{nuevo}@{host}:{port}/{db}?sslmode=require")
    print("=========================================================================")
    PENDIENTE.rename(PENDIENTE.with_name(f"rotacion_aplicada-{ts}.env"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
