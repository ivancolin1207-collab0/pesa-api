#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
importar_certificados.py
========================
Script de migracion: lee todos los PDFs de certificados de calibracion
en la carpeta de origen, extrae datos estructurados con expresiones
regulares y los importa a la base de datos PostgreSQL (cat_clientes,
cliente_sucursales, cliente_equipos).

Reglas de insercion:
  - Clientes: UPSERT por razon social exacta (UNIQUE constraint)
  - Sucursales: UPSERT por (cliente_id, direccion completa).
  - Equipos: UPSERT por (sucursal_id, numero_serie) -- nunca duplicados.
    Si el numero de serie es "Sin Serie", se usa la Identificacion como
    discriminador alternativo.

Uso:
    python importar_certificados.py
    python importar_certificados.py --dry-run   # sin escribir a BD
    python importar_certificados.py --verbose   # mostrar detalles
"""

import argparse
import logging
import os
import re
import sys
import glob
from dataclasses import dataclass
from datetime import datetime
from typing import Optional

import pdfplumber
import psycopg2
from psycopg2.extras import RealDictCursor

# Configuracion ---------------------------------------------------------------

CARPETA_CERTIFICADOS = r"C:\Users\ivan1\OneDrive\Escritorio\Proyecto Pesa ERP\f\Sistema\Certificados"

DB_CONFIG = {
    "host":     "localhost",
    "port":     5432,
    "database": "servicios_pesa",
    "user":     "pesa_app",
    "password": os.getenv("PESA_DB_PASSWORD", ""),
    "connect_timeout": 10,
    "options":  "-c search_path=public",
}

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "importar_certificados.log")

# Logging setup ---------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
logger = logging.getLogger("importar_certificados")


# Estructuras de datos --------------------------------------------------------

@dataclass
class DatosExtraidos:
    archivo: str = ""
    razon_social: str = ""
    direccion: str = ""
    ciudad: str = ""
    estado: str = ""
    telefono: str = ""
    descripcion: str = ""
    marca: str = ""
    modelo: str = ""
    serie: str = ""
    identificacion: str = ""
    capacidad_max: str = ""
    division_min: str = ""
    ubicacion: str = ""
    numero_certificado: str = ""
    fecha_calibracion: str = ""

    @property
    def direccion_completa(self) -> str:
        partes = []
        if self.direccion:
            partes.append(self.direccion.strip())
        if self.ciudad:
            partes.append(self.ciudad.strip())
        if self.estado:
            partes.append(self.estado.strip())
        return ", ".join(partes) if partes else ""

    @property
    def es_valido(self) -> bool:
        return bool(self.razon_social and (self.serie or self.identificacion))


# Extraccion de texto ---------------------------------------------------------

def _buscar(patron: str, texto: str, grupo: int = 1, flags: int = 0) -> str:
    m = re.search(patron, texto, flags | re.IGNORECASE)
    if m:
        return m.group(grupo).strip()
    return ""


def _texto_pdf(pdf_path: str) -> str:
    try:
        with pdfplumber.open(pdf_path) as pdf:
            page = pdf.pages[0]
            return (page.extract_text() or "").replace("\r\n", "\n").replace("\r", "\n")
    except Exception as exc:
        logger.warning("  [ERROR PDF] %s: %s", os.path.basename(pdf_path), exc)
        return ""


def extraer_datos(pdf_path: str) -> Optional[DatosExtraidos]:
    texto = _texto_pdf(pdf_path)
    if not texto:
        return None

    d = DatosExtraidos(archivo=os.path.basename(pdf_path))

    # Cliente
    d.razon_social   = _buscar(r"Raz[o\xf3]n\s+social\s*:\s*(.+?)(?:\n|$)",   texto)
    d.direccion      = _buscar(r"Direcci[o\xf3]n\s*:\s*(.+?)(?:\n|$)",          texto)
    d.ciudad         = _buscar(r"Ciudad\s*:\s*(.+?)\s+Estado\s*:",               texto)
    d.estado         = _buscar(r"Estado\s*:\s*(.+?)(?:\s+Tel[e\xe9]fono\s*:|$)", texto)
    d.telefono       = _buscar(r"Tel[e\xe9]fono\s*:\s*(\S+)",                    texto)

    # Instrumento
    d.descripcion    = _buscar(r"Descripci[o\xf3]n\s*:\s*(.+?)(?:\n|$)",        texto)
    d.marca          = _buscar(r"Marca\s*:\s*(.+?)\s+M[a\xe1]x\s*:",            texto)
    d.capacidad_max  = _buscar(r"M[a\xe1]x\s*:\s*(.+?)(?:\n|$)",                texto)
    d.modelo         = _buscar(r"Modelo\s*:\s*(.+?)\s+Divisi[o\xf3]n\s+M[i\xed]nima\s*:", texto)
    d.division_min   = _buscar(r"Divisi[o\xf3]n\s+M[i\xed]nima\s*:\s*(.+?)(?:\n|$)", texto)
    d.serie          = _buscar(r"Serie\s*:\s*(.+?)\s+Ubicaci[o\xf3]n\s*:",      texto)
    d.ubicacion      = _buscar(r"Ubicaci[o\xf3]n\s*:\s*(.+?)(?:\n|$)",          texto)
    d.identificacion = _buscar(r"Identificaci[o\xf3]n\s*:\s*(.+?)(?:\n|$)",     texto)
    d.numero_certificado = _buscar(r"N[u\xfa]mero\s+de\s+certificado\s*:\s*(\S+)", texto)
    d.fecha_calibracion  = _buscar(r"Fecha\s+de\s+recepci[o\xf3]n\s+y\s+calibraci[o\xf3]n\s*:\s*(\S+)", texto)

    # Normalizar "Sin Serie"
    if d.serie.lower() in ("sin serie", "sin s/n", "s/n", "n/a", "na", "-"):
        d.serie = ""

    return d


# Funciones de base de datos --------------------------------------------------

def obtener_o_crear_cliente(cur, razon_social: str) -> int:
    cur.execute(
        "INSERT INTO cat_clientes (razon_social, activo) VALUES (%s, TRUE) "
        "ON CONFLICT (razon_social) DO NOTHING RETURNING id",
        (razon_social,)
    )
    row = cur.fetchone()
    if row:
        return row["id"]
    cur.execute("SELECT id FROM cat_clientes WHERE razon_social = %s", (razon_social,))
    return cur.fetchone()["id"]


def obtener_o_crear_sucursal(cur, cliente_id: int, direccion: str) -> int:
    nombre = (direccion[:148] if len(direccion) > 148 else direccion) or "Planta Principal"
    cur.execute(
        "INSERT INTO cliente_sucursales (cliente_id, nombre_sucursal, direccion, activo) "
        "VALUES (%s, %s, %s, TRUE) "
        "ON CONFLICT (cliente_id, nombre_sucursal) DO NOTHING RETURNING id",
        (cliente_id, nombre, direccion)
    )
    row = cur.fetchone()
    if row:
        return row["id"]
    cur.execute(
        "SELECT id FROM cliente_sucursales WHERE cliente_id = %s AND nombre_sucursal = %s",
        (cliente_id, nombre)
    )
    return cur.fetchone()["id"]


def upsert_equipo(cur, sucursal_id: int, datos: DatosExtraidos) -> tuple:
    num_serie = datos.serie if datos.serie else f"ID:{datos.identificacion}"
    cur.execute(
        """
        INSERT INTO cliente_equipos (
            sucursal_id, numero_serie, id_indicador_equipo,
            marca, modelo, capacidad_maxima, division_minima, ubicacion_interna, activo
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE)
        ON CONFLICT (sucursal_id, numero_serie) DO UPDATE SET
            id_indicador_equipo = COALESCE(EXCLUDED.id_indicador_equipo, cliente_equipos.id_indicador_equipo),
            marca               = COALESCE(EXCLUDED.marca,               cliente_equipos.marca),
            modelo              = COALESCE(EXCLUDED.modelo,              cliente_equipos.modelo),
            capacidad_maxima    = COALESCE(EXCLUDED.capacidad_maxima,    cliente_equipos.capacidad_maxima),
            division_minima     = COALESCE(EXCLUDED.division_minima,     cliente_equipos.division_minima),
            ubicacion_interna   = COALESCE(EXCLUDED.ubicacion_interna,   cliente_equipos.ubicacion_interna),
            updated_at          = NOW()
        RETURNING id, (xmax = 0) AS es_nuevo
        """,
        (
            sucursal_id, num_serie,
            datos.identificacion or None,
            datos.marca or None,
            datos.modelo or None,
            datos.capacidad_max or None,
            datos.division_min or None,
            datos.ubicacion or None,
        )
    )
    row = cur.fetchone()
    return row["id"], bool(row["es_nuevo"])


# Procesamiento principal -----------------------------------------------------

def procesar_todos(dry_run: bool = False, verbose: bool = False) -> None:
    pdfs = sorted(glob.glob(
        os.path.join(CARPETA_CERTIFICADOS, "**", "*.pdf"),
        recursive=True
    ))

    total = len(pdfs)
    procesados = omitidos = errores = 0
    clientes_nuevos = sucursales_nuevas = equipos_nuevos = equipos_act = 0

    logger.info("=" * 70)
    logger.info("IMPORTADOR DE CERTIFICADOS DE CALIBRACION - Basculas PESA")
    logger.info("Inicio    : %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    logger.info("Carpeta   : %s", CARPETA_CERTIFICADOS)
    logger.info("PDFs      : %d", total)
    logger.info("DRY-RUN   : %s", dry_run)
    logger.info("=" * 70)

    conn = None
    if not dry_run:
        try:
            conn = psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)
            conn.autocommit = False
            logger.info("[OK] Conexion a PostgreSQL establecida")
        except Exception as exc:
            logger.error("[ERROR] No se pudo conectar a PostgreSQL: %s", exc)
            sys.exit(1)

    cache_clientes: dict = {}
    cache_sucursales: dict = {}
    cache_clientes_nuevos: set = set()

    try:
        for i, pdf_path in enumerate(pdfs, 1):
            nombre = os.path.basename(pdf_path)

            datos = extraer_datos(pdf_path)

            if datos is None or not datos.es_valido:
                if verbose:
                    logger.info("  [OMITIDO] %s", nombre)
                omitidos += 1
                continue

            if verbose:
                logger.info(
                    "  [%d/%d] %s | %s | S/N: %s | ID: %s",
                    i, total, nombre[:60],
                    datos.razon_social[:35],
                    datos.serie or "(sin serie)",
                    datos.identificacion
                )

            if dry_run:
                procesados += 1
                continue

            try:
                cur = conn.cursor()

                # 1. Cliente
                if datos.razon_social not in cache_clientes:
                    cli_id = obtener_o_crear_cliente(cur, datos.razon_social)
                    if cli_id not in cache_clientes_nuevos:
                        clientes_nuevos += 1
                        cache_clientes_nuevos.add(cli_id)
                    cache_clientes[datos.razon_social] = cli_id
                cli_id = cache_clientes[datos.razon_social]

                # 2. Sucursal
                suc_key = (cli_id, datos.direccion_completa)
                if suc_key not in cache_sucursales:
                    suc_id = obtener_o_crear_sucursal(cur, cli_id, datos.direccion_completa)
                    cache_sucursales[suc_key] = suc_id
                suc_id = cache_sucursales[suc_key]

                # 3. Equipo
                _, es_nuevo = upsert_equipo(cur, suc_id, datos)
                if es_nuevo:
                    equipos_nuevos += 1
                else:
                    equipos_act += 1

                conn.commit()
                procesados += 1

                # Mostrar progreso cada 100
                if procesados % 100 == 0:
                    logger.info(
                        "  ... %d procesados, %d equipos nuevos, %d actualizados",
                        procesados, equipos_nuevos, equipos_act
                    )

            except Exception as exc_inner:
                conn.rollback()
                logger.error("  [ERROR] %s : %s", nombre, exc_inner)
                errores += 1

        # Reporte final
        logger.info("")
        logger.info("=" * 70)
        logger.info("RESUMEN FINAL")
        logger.info("=" * 70)
        logger.info("  PDFs encontrados          : %d", total)
        logger.info("  Certificados procesados   : %d", procesados)
        logger.info("  Omitidos (sin datos)      : %d", omitidos)
        logger.info("  Errores                   : %d", errores)
        if not dry_run:
            logger.info("  ----------------------------------------")
            logger.info("  [BD] Clientes creados     : %d", clientes_nuevos)
            logger.info("  [BD] Sucursales creadas   : %d", len(cache_sucursales) - (len(cache_sucursales) - sucursales_nuevas))
            logger.info("  [BD] Equipos NUEVOS       : %d", equipos_nuevos)
            logger.info("  [BD] Equipos ACTUALIZADOS : %d", equipos_act)
        else:
            logger.info("  [DRY-RUN] No se escribio nada a la BD.")
        logger.info("=" * 70)
        logger.info("Fin: %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

    finally:
        if conn:
            conn.close()
            logger.info("[OK] Conexion cerrada.")


# Entry point -----------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Importa certificados de calibracion PDF a PostgreSQL."
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=False,
        help="Procesa los PDFs y muestra el log pero NO escribe en BD.",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", default=False,
        help="Muestra el detalle de cada PDF procesado.",
    )
    args = parser.parse_args()
    procesar_todos(dry_run=args.dry_run, verbose=args.verbose)
