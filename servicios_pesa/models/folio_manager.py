"""
Gestor de folios anuales.
Encapsula la lógica de generación de folios consecutivos e inalterables,
delegando la atomicidad a la función PostgreSQL generate_folio().
"""
import logging
from datetime import datetime
from typing import Optional

from database.connection import db_pool
from config import FOLIO_TIPOS

logger = logging.getLogger(__name__)


class FolioManager:
    """
    Gestiona la generación de folios garantizando:
    - Consecutividad: nunca hay saltos en la numeración
    - Unicidad: nunca se repite un folio en el mismo año
    - Seguridad multi-cliente: la función PostgreSQL usa INSERT ON CONFLICT
      que es inherentemente atómica sin necesidad de locking explícito

    Formato: TIPO-AA-N
    Ejemplos: OS-26-443 | RMA-26-12 | RE-26-5
    """

    @staticmethod
    def get_next_folio(tipo: str, anio: Optional[int] = None) -> str:
        """
        Genera el siguiente folio consecutivo para el tipo y año dados.

        Args:
            tipo: Tipo de folio ('OS', 'RMA', 'RE').
            anio: Año para el folio (por defecto: año actual).

        Returns:
            Folio formateado, ej: 'OS-26-443'.

        Raises:
            ValueError: Si el tipo de folio no es válido.
            DatabaseConnectionError: Si hay problemas de conexión.
        """
        tipo = tipo.upper()
        if tipo not in FOLIO_TIPOS:
            raise ValueError(
                f"Tipo de folio inválido: '{tipo}'. "
                f"Valores válidos: {list(FOLIO_TIPOS.keys())}"
            )

        if anio is None:
            anio = datetime.now().year

        logger.debug(f"Generando folio para tipo={tipo}, año={anio}")

        row = db_pool.execute_one(
            # La función espera CHAR/VARCHAR + SMALLINT → cast explícito
            "SELECT generate_folio(%s::varchar, %s::smallint) AS folio",
            (tipo, anio),
        )

        if row is None or not row.get("folio"):
            raise RuntimeError(
                f"La función generate_folio() no retornó un valor para tipo={tipo}, año={anio}"
            )

        folio = row["folio"]
        logger.info(f"Folio generado: {folio}")
        return folio

    @staticmethod
    def get_current_consecutivo(tipo: str, anio: Optional[int] = None) -> int:
        """
        Consulta el último consecutivo asignado SIN generar uno nuevo.
        Útil para mostrar cuántas OS hay en el año.

        Args:
            tipo: Tipo de folio ('OS', 'RMA', 'RE').
            anio: Año a consultar (por defecto: año actual).

        Returns:
            Último consecutivo asignado (0 si ninguno aún).
        """
        if anio is None:
            anio = datetime.now().year

        row = db_pool.execute_one(
            """
            SELECT COALESCE(ultimo_consecutivo, 0) AS consecutivo
            FROM control_folios
            WHERE tipo_folio = %s AND anio = %s
            """,
            (tipo.upper(), anio),
        )
        return int(row["consecutivo"]) if row else 0

    @staticmethod
    def get_resumen_folios() -> list[dict]:
        """
        Retorna el resumen de todos los folios por tipo y año.
        Útil para la pantalla de administración.
        """
        return db_pool.execute_all(
            """
            SELECT
                tipo_folio,
                anio,
                ultimo_consecutivo,
                updated_at
            FROM control_folios
            ORDER BY tipo_folio, anio DESC
            """
        )

    @staticmethod
    def parse_folio(folio: str) -> dict:
        """
        Descompone un folio en sus partes.

        Args:
            folio: Ej. 'OS-26-443'

        Returns:
            {'tipo': 'OS', 'anio_corto': '26', 'consecutivo': 443}
        """
        parts = folio.split("-")
        if len(parts) != 3:
            raise ValueError(f"Formato de folio inválido: '{folio}'")
        return {
            "tipo": parts[0],
            "anio_corto": parts[1],
            "consecutivo": int(parts[2]),
        }


# Instancia conveniente para uso directo
folio_manager = FolioManager()
