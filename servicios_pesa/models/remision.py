"""
Repositorio de Remisiones (RMA).
Gestiona CRUD de remisiones con sus ítems de material
en transacciones atómicas.
"""
import logging
from typing import Optional
from database.connection import db_pool
from models.base_model import BaseRepository

logger = logging.getLogger(__name__)


class RemisionRepository(BaseRepository):
    TABLE = "remisiones"

    # ── Consultas ─────────────────────────────────────────────────────────────
    def get_all(self, estado: Optional[str] = None) -> list[dict]:
        if estado:
            return self._fetch_all(
                "SELECT * FROM v_remisiones WHERE estado=%s ORDER BY fecha DESC,id DESC",
                (estado,)
            )
        return self._fetch_all("SELECT * FROM v_remisiones ORDER BY fecha DESC,id DESC")

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one("SELECT * FROM v_remisiones WHERE id=%s", (record_id,))

    def get_by_folio(self, folio: str) -> Optional[dict]:
        return self._fetch_one("SELECT * FROM v_remisiones WHERE folio_rma=%s", (folio,))

    def get_items(self, remision_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_remision_items WHERE id_remision=%s ORDER BY num_item",
            (remision_id,)
        )

    # ── Creación ──────────────────────────────────────────────────────────────
    def create(self, data: dict) -> dict:
        """
        Crea una Remisión con sus ítems en una transacción.
        data['items']: list[dict] con campos descripcion, cantidad, unidad,
                       num_serie, observacion
        """
        from datetime import datetime
        anio = data.get("anio") or datetime.now().year

        with db_pool.transaction() as conn:
            from psycopg2.extras import RealDictCursor
            cur = conn.cursor(cursor_factory=RealDictCursor)

            # 1. Generar folio RMA atómico
            cur.execute(
                "SELECT generate_folio(%s::varchar, %s::smallint) AS folio",
                ("RMA", anio)
            )
            folio = cur.fetchone()["folio"]

            # 2. Insertar cabecera — intenta con sucursal_id (v15); fallback sin él
            _params_rma = {
                "folio_rma":     folio,
                "fecha":         data.get("fecha"),
                "id_cliente":    data.get("id_cliente"),
                "id_tecnico":    data.get("id_tecnico"),
                "sucursal_id":   data.get("sucursal_id"),
                "observaciones": data.get("observaciones"),
            }
            try:
                cur.execute(
                    """
                    INSERT INTO remisiones (folio_rma, fecha, id_cliente, id_tecnico, sucursal_id, observaciones)
                    VALUES (%(folio_rma)s, %(fecha)s, %(id_cliente)s, %(id_tecnico)s, %(sucursal_id)s, %(observaciones)s)
                    RETURNING id, folio_rma, estado, created_at
                    """,
                    _params_rma
                )
            except Exception as col_exc:
                conn.rollback()
                logger.warning("sucursal_id no disponible en remisiones, usando INSERT base: %s", col_exc)
                # Re-generar folio tras rollback
                cur2 = conn.cursor(cursor_factory=RealDictCursor)
                cur2.execute(
                    "SELECT generate_folio(%s::varchar, %s::smallint) AS folio",
                    ("RMA", anio)
                )
                folio = cur2.fetchone()["folio"]
                _params_rma["folio_rma"] = folio
                cur2.execute(
                    """
                    INSERT INTO remisiones (folio_rma, fecha, id_cliente, id_tecnico, observaciones)
                    VALUES (%(folio_rma)s, %(fecha)s, %(id_cliente)s, %(id_tecnico)s, %(observaciones)s)
                    RETURNING id, folio_rma, estado, created_at
                    """,
                    _params_rma
                )
                cur = cur2
            row = cur.fetchone()
            rem_id = row["id"]

            # 3. Insertar ítems
            for idx, item in enumerate(data.get("items", []), start=1):
                if item.get("descripcion"):
                    cur.execute(
                        """
                        INSERT INTO det_remision_items
                            (id_remision, num_item, descripcion, cantidad, unidad, num_serie, observacion)
                        VALUES (%s, %s, %s, %s, %s, %s, %s)
                        """,
                        (rem_id, idx,
                         item["descripcion"],
                         item.get("cantidad") or 1,
                         item.get("unidad") or "PZA",
                         item.get("num_serie"),
                         item.get("observacion"))
                    )

        logger.info(f"Remisión creada: {folio}")
        return dict(row)

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE remisiones SET
                fecha         = %(fecha)s,
                id_cliente    = %(id_cliente)s,
                id_tecnico    = %(id_tecnico)s,
                observaciones = %(observaciones)s
            WHERE id = %(id)s
            RETURNING id, folio_rma, estado, updated_at
            """,
            {**data, "id": record_id}, returning=True
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        result = self._write(
            "UPDATE remisiones SET estado='CANCELADA' WHERE id=%s RETURNING id",
            (record_id,), returning=True
        )
        return result is not None

    def get_estadisticas(self) -> dict:
        rows = self._fetch_all("SELECT estado, COUNT(*) AS total FROM remisiones GROUP BY estado")
        return {r["estado"]: int(r["total"]) for r in rows}


remision_repo = RemisionRepository()
