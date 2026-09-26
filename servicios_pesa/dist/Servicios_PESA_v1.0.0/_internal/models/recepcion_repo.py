"""
recepcion_repo.py — Repositorio del Módulo de Recepción / Entrega Semanal.

Gestiona la tabla lotes_recepcion y lotes_recepcion_items.
Incluye la lógica de negocio de la REGLA ESTRICTA de entrega impresa.
"""
from __future__ import annotations

import logging
from typing import Optional

from database.connection import db_pool
from models.base_model import BaseRepository

logger = logging.getLogger(__name__)


class RecepcionRepository(BaseRepository):
    TABLE = "lotes_recepcion"

    # ── Consultas ──────────────────────────────────────────────────────────────

    def get_all(
        self,
        fecha_desde: Optional[str] = None,
        fecha_hasta: Optional[str] = None,
    ) -> list[dict]:
        """
        Retorna todos los lotes de recepción ordenados por fecha descendente.
        Opcionalmente filtrados por rango de fechas (formato 'YYYY-MM-DD').
        """
        if fecha_desde and fecha_hasta:
            sql = """
                SELECT * FROM v_recepcion_semanal
                WHERE fecha_asignacion BETWEEN %s AND %s
                ORDER BY fecha_asignacion DESC, id DESC
            """
            return self._fetch_all(sql, (fecha_desde, fecha_hasta))
        elif fecha_desde:
            sql = """
                SELECT * FROM v_recepcion_semanal
                WHERE fecha_asignacion >= %s
                ORDER BY fecha_asignacion DESC, id DESC
            """
            return self._fetch_all(sql, (fecha_desde,))
        else:
            return self._fetch_all(
                "SELECT * FROM v_recepcion_semanal ORDER BY fecha_asignacion DESC, id DESC"
            )

    def get_by_id(self, record_id: int) -> Optional[dict]:
        """Retorna un lote de recepción por su ID."""
        return self._fetch_one(
            "SELECT * FROM v_recepcion_semanal WHERE id = %s", (record_id,)
        )

    def get_by_lote_ref(self, id_lote_ref: str) -> Optional[dict]:
        """Busca el lote de recepción asociado a un id_lote de OS."""
        return self._fetch_one(
            "SELECT * FROM v_recepcion_semanal WHERE id_lote_ref = %s",
            (id_lote_ref,),
        )

    def get_by_fecha(self, fecha: str) -> list[dict]:
        """Retorna todos los lotes de una fecha específica (YYYY-MM-DD)."""
        return self._fetch_all(
            "SELECT * FROM v_recepcion_semanal WHERE fecha_asignacion = %s ORDER BY id",
            (fecha,),
        )

    def get_items(self, id_lote_recepcion: int) -> list[dict]:
        """Retorna los ítems (OS individuales) de un lote de recepción."""
        return self._fetch_all(
            """
            SELECT li.*, os.estado AS estado_os, os.folio_os AS folio_os_os
            FROM lotes_recepcion_items li
            LEFT JOIN ordenes_servicio os ON li.id_os = os.id
            WHERE li.id_lote_recepcion = %s
            ORDER BY li.id
            """,
            (id_lote_recepcion,),
        )

    def get_fechas_disponibles(self, anio: int = None) -> list[str]:
        """Retorna lista de fechas con al menos un lote registrado."""
        if anio:
            sql = """
                SELECT DISTINCT fecha_asignacion::TEXT
                FROM lotes_recepcion
                WHERE EXTRACT(YEAR FROM fecha_asignacion) = %s
                ORDER BY fecha_asignacion DESC
            """
            rows = self._fetch_all(sql, (anio,))
        else:
            rows = self._fetch_all(
                "SELECT DISTINCT fecha_asignacion::TEXT FROM lotes_recepcion ORDER BY fecha_asignacion DESC"
            )
        return [r["fecha_asignacion"] for r in rows]

    # ── Creación ──────────────────────────────────────────────────────────────

    def create(self, data: dict) -> dict:
        """
        Crea un nuevo lote de recepción.

        Args:
            data: Diccionario con campos de lotes_recepcion.
                  Campos opcionales:
                    'items': list[dict] con folio_os e id_os para insertar ítems.

        Returns:
            Diccionario con el registro creado.
        """
        items = data.pop("items", [])

        row = self._write(
            """
            INSERT INTO lotes_recepcion (
                id_lote_ref, fecha_asignacion,
                id_cliente, id_tipo_servicio,
                cantidad_os_asignadas, folios_asignados,
                id_tecnico, tecnicos_adicionales,
                numero_factura, certificados_bs,
                confirmacion_os, check_os_escaneada,
                no_os_realizadas, no_os_en_blanco,
                entrega_impresa_recibida, notas_recepcion
            ) VALUES (
                %(id_lote_ref)s, %(fecha_asignacion)s,
                %(id_cliente)s, %(id_tipo_servicio)s,
                %(cantidad_os_asignadas)s, %(folios_asignados)s,
                %(id_tecnico)s, %(tecnicos_adicionales)s,
                %(numero_factura)s, %(certificados_bs)s,
                %(confirmacion_os)s, COALESCE(%(check_os_escaneada)s, 'PENDIENTE'),
                COALESCE(%(no_os_realizadas)s, 0), COALESCE(%(no_os_en_blanco)s, 0),
                COALESCE(%(entrega_impresa_recibida)s, FALSE), %(notas_recepcion)s
            )
            RETURNING id, fecha_asignacion, created_at
            """,
            {
                "id_lote_ref":               data.get("id_lote_ref"),
                "fecha_asignacion":          data.get("fecha_asignacion"),
                "id_cliente":                data.get("id_cliente"),
                "id_tipo_servicio":          data.get("id_tipo_servicio"),
                "cantidad_os_asignadas":     data.get("cantidad_os_asignadas", 1),
                "folios_asignados":          data.get("folios_asignados"),
                "id_tecnico":               data.get("id_tecnico"),
                "tecnicos_adicionales":      data.get("tecnicos_adicionales"),
                "numero_factura":            data.get("numero_factura"),
                "certificados_bs":           data.get("certificados_bs"),
                "confirmacion_os":           data.get("confirmacion_os"),
                "check_os_escaneada":        data.get("check_os_escaneada"),
                "no_os_realizadas":          data.get("no_os_realizadas", 0),
                "no_os_en_blanco":           data.get("no_os_en_blanco", 0),
                "entrega_impresa_recibida":  data.get("entrega_impresa_recibida", False),
                "notas_recepcion":           data.get("notas_recepcion"),
            },
            returning=True,
        )
        lote_id = dict(row)["id"]

        # Insertar ítems si se proporcionaron
        for item in items:
            self._write(
                """
                INSERT INTO lotes_recepcion_items
                    (id_lote_recepcion, id_os, folio_os, confirmada, impresa_entregada, escaneada, notas)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (id_lote_recepcion, folio_os) DO NOTHING
                """,
                (
                    lote_id,
                    item.get("id_os"),
                    item.get("folio_os", ""),
                    item.get("confirmada"),
                    item.get("impresa_entregada", False),
                    item.get("escaneada"),
                    item.get("notas"),
                ),
                returning=False,
            )

        logger.info("Lote de recepción creado: ID=%d", lote_id)
        return dict(row)

    # ── Actualización ─────────────────────────────────────────────────────────

    def update(self, record_id: int, data: dict) -> dict:
        """
        Actualiza campos de Parte 2 (cierre/recepción) de un lote.
        Los campos de Parte 1 (asignación) también pueden actualizarse
        pero normalmente son solo lectura para el rol 'recepcion'.
        """
        row = self._write(
            """
            UPDATE lotes_recepcion SET
                id_cliente                  = %(id_cliente)s,
                id_tipo_servicio            = %(id_tipo_servicio)s,
                cantidad_os_asignadas       = %(cantidad_os_asignadas)s,
                folios_asignados            = %(folios_asignados)s,
                id_tecnico                  = %(id_tecnico)s,
                tecnicos_adicionales        = %(tecnicos_adicionales)s,
                numero_factura              = %(numero_factura)s,
                certificados_bs             = %(certificados_bs)s,
                confirmacion_os             = %(confirmacion_os)s,
                check_os_escaneada          = COALESCE(%(check_os_escaneada)s, check_os_escaneada),
                no_os_realizadas            = %(no_os_realizadas)s,
                no_os_en_blanco             = %(no_os_en_blanco)s,
                entrega_impresa_recibida    = %(entrega_impresa_recibida)s,
                notas_recepcion             = %(notas_recepcion)s
            WHERE id = %(id)s
            RETURNING id, updated_at, entrega_impresa_recibida
            """,
            {**data, "id": record_id},
            returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        """Elimina un lote de recepción (hard delete — solo para admin)."""
        result = self._write(
            "DELETE FROM lotes_recepcion WHERE id = %s RETURNING id",
            (record_id,),
            returning=True,
        )
        return result is not None

    # ── Campos individuales ───────────────────────────────────────────────────

    def set_entrega_impresa(self, record_id: int, valor: bool) -> bool:
        """
        Marca o desmarca la Entrega Impresa Recibida.
        Retorna True si la actualización fue exitosa.
        """
        result = self._write(
            """
            UPDATE lotes_recepcion
            SET entrega_impresa_recibida = %s
            WHERE id = %s
            RETURNING id
            """,
            (valor, record_id),
            returning=True,
        )
        ok = result is not None
        if ok:
            logger.info(
                "Entrega impresa %s para lote_recepcion ID=%d",
                "MARCADA" if valor else "DESMARCADA",
                record_id,
            )
        return ok

    def set_confirmacion_os(self, record_id: int, valor: Optional[bool]) -> bool:
        """Actualiza la Confirmación de OS (True/False/None)."""
        result = self._write(
            "UPDATE lotes_recepcion SET confirmacion_os = %s WHERE id = %s RETURNING id",
            (valor, record_id),
            returning=True,
        )
        return result is not None

    def set_factura(self, record_id: int, numero_factura: Optional[str]) -> bool:
        """Actualiza el número de factura asociado al lote."""
        result = self._write(
            "UPDATE lotes_recepcion SET numero_factura = %s WHERE id = %s RETURNING id",
            (numero_factura, record_id),
            returning=True,
        )
        return result is not None

    def set_check_escaneada(self, record_id: int, valor: str) -> bool:
        """Actualiza el estado de escaneo: 'OK', 'NA', 'PENDIENTE'."""
        if valor not in ("OK", "NA", "PENDIENTE"):
            raise ValueError(f"Valor inválido para check_os_escaneada: {valor!r}")
        result = self._write(
            "UPDATE lotes_recepcion SET check_os_escaneada = %s WHERE id = %s RETURNING id",
            (valor, record_id),
            returning=True,
        )
        return result is not None

    # ── Regla estricta: Marcar lote como COMPLETADO ───────────────────────────

    def marcar_completado(self, record_id: int) -> dict:
        """
        REGLA ESTRICTA: Marca las OS del lote como COMPLETADA en BD.

        Invoca la función PL/pgSQL `marcar_lote_completado` que:
          1. Verifica que entrega_impresa_recibida = TRUE.
          2. Si no → retorna {'ok': False, 'error': '...'}.
          3. Si sí → actualiza estado de OS a 'COMPLETADA'.

        Returns:
            {'ok': True, 'os_actualizadas': N}  en caso de éxito.
            {'ok': False, 'error': '...'}       si hay bloqueo o error.
        """
        try:
            row = db_pool.execute_one(
                "SELECT marcar_lote_completado(%s) AS resultado",
                (record_id,),
            )
            if row:
                resultado = dict(row["resultado"])
                if resultado.get("ok"):
                    logger.info(
                        "Lote ID=%d marcado COMPLETADO — %d OS actualizadas",
                        record_id,
                        resultado.get("os_actualizadas", 0),
                    )
                else:
                    logger.warning(
                        "Bloqueo al completar lote ID=%d: %s",
                        record_id,
                        resultado.get("error"),
                    )
                return resultado
            return {"ok": False, "error": "Sin respuesta de la base de datos"}
        except Exception as exc:
            logger.exception("Error al ejecutar marcar_lote_completado(%d)", record_id)
            return {"ok": False, "error": str(exc)}

    # ── Estadísticas ──────────────────────────────────────────────────────────

    def get_resumen_semana(self, fecha_inicio: str, fecha_fin: str) -> dict:
        """
        Retorna estadísticas de la semana para el header del widget:
        - Total de lotes
        - Total OS asignadas
        - OS realizadas
        - OS en blanco
        - Lotes con entrega impresa confirmada
        - Lotes con factura pendiente (alerta)
        """
        row = self._fetch_one(
            """
            SELECT
                COUNT(*)                                        AS total_lotes,
                COALESCE(SUM(cantidad_os_asignadas), 0)         AS total_os_asignadas,
                COALESCE(SUM(no_os_realizadas), 0)              AS total_os_realizadas,
                COALESCE(SUM(no_os_en_blanco), 0)               AS total_os_blanco,
                COUNT(*) FILTER (WHERE entrega_impresa_recibida = TRUE)  AS lotes_impresos,
                COUNT(*) FILTER (
                    WHERE numero_factura IS NULL OR TRIM(numero_factura) = ''
                )                                               AS lotes_sin_factura
            FROM lotes_recepcion
            WHERE fecha_asignacion BETWEEN %s AND %s
            """,
            (fecha_inicio, fecha_fin),
        )
        return dict(row) if row else {}


# Instancia singleton
recepcion_repo = RecepcionRepository()
