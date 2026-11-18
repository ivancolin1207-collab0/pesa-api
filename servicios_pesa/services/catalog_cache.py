# -*- coding: utf-8 -*-
"""
services/catalog_cache.py — Caché asíncrono en memoria + SQLite para catálogos ERP.
Permite apertura instantánea (< 50 ms) de formularios y selectores sin congelar el hilo GUI.
"""
from __future__ import annotations

import logging
import threading
from typing import Any

from PyQt6.QtCore import QObject, QThread, pyqtSignal

logger = logging.getLogger(__name__)


class _CatalogWarmupWorker(QThread):
    """Descarga en segundo plano clientes, sucursales, técnicos, servicios y consecutivos."""

    finished_data = pyqtSignal(dict)

    def run(self) -> None:
        payload: dict[str, Any] = {}
        try:
            from database.connection import db_pool
            if db_pool is None:
                return
            conn = db_pool.get_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id, COALESCE(razon_social, ''), COALESCE(direccion, ''), COALESCE(rfc, ''), COALESCE(email, '') "
                        "FROM cat_clientes WHERE activo IS NOT FALSE ORDER BY razon_social"
                    )
                    payload["clientes"] = cur.fetchall()

                    cur.execute(
                        "SELECT id, cliente_id, COALESCE(nombre_sucursal, ''), COALESCE(direccion, '') "
                        "FROM cliente_sucursales WHERE activo IS NOT FALSE ORDER BY nombre_sucursal"
                    )
                    suc_map: dict[int, list[tuple]] = {}
                    for sid, cid, snom, sdir in cur.fetchall():
                        if cid is not None:
                            suc_map.setdefault(int(cid), []).append((sid, snom, sdir))
                    payload["sucursales_by_cliente"] = suc_map

                    cur.execute(
                        "SELECT id, COALESCE(nombre_completo, '') FROM cat_tecnicos "
                        "WHERE activo = TRUE ORDER BY nombre_completo"
                    )
                    payload["tecnicos"] = cur.fetchall()

                    cur.execute("SELECT id, COALESCE(nombre, '') FROM cat_tipo_servicio ORDER BY nombre")
                    payload["tipos_servicio"] = cur.fetchall()

                    try:
                        cur.execute("SELECT id, COALESCE(nombre, '') FROM cat_tipo_instrumento ORDER BY id")
                        payload["tipos_instrumento"] = cur.fetchall()
                    except Exception:
                        conn.rollback()
                        payload["tipos_instrumento"] = []

                    try:
                        cur.execute(
                            """
                            SELECT UPPER(COALESCE(tipo_documento, 'OS')), COALESCE(MAX(consecutivo), 0)
                            FROM ordenes_servicio
                            WHERE EXTRACT(YEAR FROM fecha) = EXTRACT(YEAR FROM CURRENT_DATE)
                            GROUP BY UPPER(COALESCE(tipo_documento, 'OS'))
                            """
                        )
                        payload["max_consecutivos"] = {str(k): int(v or 0) for k, v in cur.fetchall()}
                    except Exception:
                        conn.rollback()
                        payload["max_consecutivos"] = {}
            finally:
                db_pool.release_connection(conn)
        except Exception as exc:
            logger.debug("[CatalogCache] Warmup remoto omitido: %s", exc)
            return

        self.finished_data.emit(payload)


class CatalogCache(QObject):
    """Singleton thread-safe con acceso O(1) en memoria para la UI de escritorio."""

    catalogs_updated = pyqtSignal()

    def __init__(self) -> None:
        super().__init__()
        self._lock = threading.RLock()
        self._clientes: list[tuple] = []
        self._sucursales_by_cliente: dict[int, list[tuple]] = {}
        self._tecnicos: list[tuple] = []
        self._tipos_servicio: list[tuple] = []
        self._tipos_instrumento: list[tuple] = []
        self._max_consecutivos: dict[str, int] = {}
        self._equipos_cache: dict[tuple, list[dict]] = {}
        self._worker: _CatalogWarmupWorker | None = None
        self._ready: bool = False
        self._load_sqlite_fallback()

    def _load_sqlite_fallback(self) -> None:
        """Precarga instantánea (< 15 ms) desde SQLite local si existe."""
        try:
            from sync_manager import sync_manager
            if sync_manager is None:
                return
            with sync_manager._get_local_conn() as conn:
                cli = conn.execute(
                    "SELECT id, razon_social, COALESCE(direccion, ''), COALESCE(rfc, ''), '' "
                    "FROM cat_clientes ORDER BY razon_social"
                ).fetchall()
                tec = conn.execute(
                    "SELECT id, nombre_completo FROM cat_tecnicos WHERE activo = 1 ORDER BY nombre_completo"
                ).fetchall()
                srv = conn.execute(
                    "SELECT id, nombre FROM cat_tipo_servicio ORDER BY nombre"
                ).fetchall()
                suc_rows = conn.execute(
                    "SELECT id, id_cliente, COALESCE(nombre_sucursal, ''), COALESCE(direccion, '') "
                    "FROM cliente_sucursales ORDER BY nombre_sucursal"
                ).fetchall()
            suc_map: dict[int, list[tuple]] = {}
            for sid, cid, snom, sdir in suc_rows:
                if cid is not None:
                    suc_map.setdefault(int(cid), []).append((sid, snom, sdir))
            with self._lock:
                if cli:
                    self._clientes = [tuple(r) for r in cli]
                if tec:
                    self._tecnicos = [tuple(r) for r in tec]
                if srv:
                    self._tipos_servicio = [tuple(r) for r in srv]
                if suc_map:
                    self._sucursales_by_cliente = suc_map
        except Exception:
            pass

    def warm_up_async(self) -> None:
        """Dispara refresco asíncrono en segundo plano sin bloquear el hilo principal."""
        if self._worker is not None and self._worker.isRunning():
            return
        self._worker = _CatalogWarmupWorker()
        self._worker.finished_data.connect(self._on_worker_finished)
        self._worker.start()

    def _on_worker_finished(self, data: dict) -> None:
        if not data:
            return
        with self._lock:
            if data.get("clientes") is not None:
                self._clientes = list(data["clientes"])
            if data.get("sucursales_by_cliente") is not None:
                self._sucursales_by_cliente = dict(data["sucursales_by_cliente"])
            if data.get("tecnicos") is not None:
                self._tecnicos = list(data["tecnicos"])
            if data.get("tipos_servicio") is not None:
                self._tipos_servicio = list(data["tipos_servicio"])
            if data.get("tipos_instrumento"):
                self._tipos_instrumento = list(data["tipos_instrumento"])
            if data.get("max_consecutivos"):
                self._max_consecutivos = dict(data["max_consecutivos"])
            self._ready = True
        self.catalogs_updated.emit()

    @property
    def is_ready(self) -> bool:
        return self._ready or bool(self._clientes or self._tecnicos)

    def get_clientes(self) -> list[tuple]:
        with self._lock:
            return list(self._clientes)

    def get_sucursales(self, cliente_id: int) -> list[tuple]:
        with self._lock:
            return list(self._sucursales_by_cliente.get(int(cliente_id), []))

    def get_tecnicos(self) -> list[tuple]:
        with self._lock:
            return list(self._tecnicos)

    def get_tipos_servicio(self) -> list[tuple]:
        with self._lock:
            return list(self._tipos_servicio)

    def get_max_consecutivo(self, tipo_doc: str) -> int:
        with self._lock:
            return int(self._max_consecutivos.get(str(tipo_doc or "OS").upper(), 0))

    def bump_consecutivo(self, tipo_doc: str, nuevo_max: int) -> None:
        key = str(tipo_doc or "OS").upper()
        with self._lock:
            self._max_consecutivos[key] = max(self._max_consecutivos.get(key, 0), int(nuevo_max))

    def get_cached_equipos(self, cliente_id: int | None, sucursal_id: int | None) -> list[dict] | None:
        with self._lock:
            return self._equipos_cache.get((cliente_id, sucursal_id))

    def set_cached_equipos(self, cliente_id: int | None, sucursal_id: int | None, items: list[dict]) -> None:
        with self._lock:
            self._equipos_cache[(cliente_id, sucursal_id)] = list(items)


catalog_cache = CatalogCache()
