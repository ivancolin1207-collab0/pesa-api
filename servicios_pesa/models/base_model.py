"""
Repositorio base abstracto.
Todos los modelos heredan de esta clase para garantizar un contrato
consistente de operaciones CRUD.
"""
from abc import ABC, abstractmethod
from typing import Any, Optional

from database.connection import db_pool


class BaseRepository(ABC):
    """
    Clase base para todos los repositorios de datos.
    Provee helpers para operaciones comunes sobre la BD.
    """

    # Subclases deben definir el nombre de la tabla
    TABLE: str = ""

    # ── Operaciones Abstractas ────────────────────────────────────────────────

    @abstractmethod
    def get_all(self) -> list[dict]:
        """Retorna todos los registros activos."""
        ...

    @abstractmethod
    def get_by_id(self, record_id: int) -> Optional[dict]:
        """Retorna un registro por su ID primario."""
        ...

    @abstractmethod
    def create(self, data: dict) -> dict:
        """Crea un nuevo registro y retorna el registro creado."""
        ...

    @abstractmethod
    def update(self, record_id: int, data: dict) -> dict:
        """Actualiza un registro existente."""
        ...

    @abstractmethod
    def delete(self, record_id: int) -> bool:
        """Elimina (o desactiva) un registro. Retorna True si fue exitoso."""
        ...

    # ── Helpers Protegidos ────────────────────────────────────────────────────

    def _fetch_one(self, sql: str, params: tuple = ()) -> Optional[dict]:
        """Ejecuta un SELECT y retorna una sola fila."""
        return db_pool.execute_one(sql, params)

    def _fetch_all(self, sql: str, params: tuple = ()) -> list[dict]:
        """Ejecuta un SELECT y retorna todas las filas."""
        return db_pool.execute_all(sql, params)

    def _write(self, sql: str, params: tuple = (), returning: bool = True) -> Optional[dict]:
        """Ejecuta un INSERT/UPDATE/DELETE."""
        return db_pool.execute_write(sql, params, returning=returning)

    def _exists(self, record_id: int) -> bool:
        """Verifica si un registro existe por ID."""
        if not self.TABLE:
            raise NotImplementedError("TABLE no definido en la subclase")
        row = self._fetch_one(
            f"SELECT 1 FROM {self.TABLE} WHERE id = %s", (record_id,)
        )
        return row is not None
