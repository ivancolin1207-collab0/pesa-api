"""
Repositorio de Revisiones de Báscula (RE) — v2.
Incluye CRUD completo para todas las secciones del Reporte:
inspección visual, lecturas de Ohms, funcionalidad y periféricos.
"""
import logging
from typing import Optional
from database.connection import db_pool
from models.base_model import BaseRepository

logger = logging.getLogger(__name__)


class RevisionBasculaRepository(BaseRepository):
    TABLE = "revisiones_bascula"

    # ── Consultas ─────────────────────────────────────────────────────────────

    def get_all(self, estado: Optional[str] = None) -> list[dict]:
        if estado:
            return self._fetch_all(
                "SELECT * FROM v_revisiones_bascula WHERE estado=%s ORDER BY fecha DESC,id DESC",
                (estado,)
            )
        return self._fetch_all("SELECT * FROM v_revisiones_bascula ORDER BY fecha DESC,id DESC")

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one("SELECT * FROM v_revisiones_bascula WHERE id=%s", (record_id,))

    def get_by_folio(self, folio: str) -> Optional[dict]:
        return self._fetch_one("SELECT * FROM v_revisiones_bascula WHERE folio_re=%s", (folio,))

    def get_celdas(self, revision_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_celdas_carga WHERE id_revision=%s ORDER BY celda_num",
            (revision_id,)
        )

    def get_inspeccion(self, revision_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_inspeccion_visual WHERE id_revision=%s ORDER BY punto_num",
            (revision_id,)
        )

    def get_perifericos(self, revision_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_perifericos WHERE id_revision=%s ORDER BY id",
            (revision_id,)
        )

    # ── Creación completa (transacción atómica) ────────────────────────────────

    def create_full(self, data: dict) -> dict:
        """
        Crea el reporte completo en una transacción:
        - Cabecera revisiones_bascula  (+ folio atómico)
        - det_celdas_carga             (Ohms + funcionalidad)
        - det_inspeccion_visual        (9 puntos)
        - det_perifericos              (5 ítems)

        Args:
            data: {
                fecha, id_cliente, id_tecnico, tipo_bascula, num_celdas,
                horario, contacto_nombre, contacto_telefono, contacto_correo,
                obs_cables_conectores, obs_generales, observaciones,
                estatus_revision,
                celdas:      [{ exc_plus_minus, sig_plus_minus, sig_plus_exc_plus,
                                sig_minus_exc_minus, resistencia_entrada, resistencia_salida,
                                funciona, obs_funcionalidad }],
                inspeccion:  [{ punto_num, descripcion, cumple, observacion }],
                perifericos: [{ tipo, descripcion, cumple, observacion }],
            }
        Returns:
            Dict con id, folio_re, estado, created_at
        """
        from datetime import datetime
        anio = data.get("anio") or datetime.now().year

        with db_pool.transaction() as conn:
            from psycopg2.extras import RealDictCursor
            cur = conn.cursor(cursor_factory=RealDictCursor)

            # 1. Folio atómico
            cur.execute(
                "SELECT generate_folio(%s::varchar, %s::smallint) AS folio",
                ("RE", anio)
            )
            folio = cur.fetchone()["folio"]

            # 2. Cabecera — intenta con campos v15; si falla por columna faltante, repite sin ellos
            _INSERT_V15 = """
                INSERT INTO revisiones_bascula (
                    folio_re, fecha, id_cliente, id_tecnico,
                    tipo_bascula, num_celdas, horario,
                    contacto_nombre, contacto_telefono, contacto_correo,
                    obs_cables_conectores, obs_generales, observaciones,
                    estatus_revision,
                    sucursal_id, equipo_catalogo_id,
                    marca, modelo, numero_serie,
                    id_indicador_equipo, ubicacion_interna
                ) VALUES (
                    %(folio_re)s, %(fecha)s, %(id_cliente)s, %(id_tecnico)s,
                    %(tipo_bascula)s, %(num_celdas)s, %(horario)s,
                    %(contacto_nombre)s, %(contacto_telefono)s, %(contacto_correo)s,
                    %(obs_cables_conectores)s, %(obs_generales)s, %(observaciones)s,
                    %(estatus_revision)s,
                    %(sucursal_id)s, %(equipo_catalogo_id)s,
                    %(marca)s, %(modelo)s, %(numero_serie)s,
                    %(id_indicador_equipo)s, %(ubicacion_interna)s
                )
                RETURNING id, folio_re, estado, created_at
            """
            _INSERT_BASE = """
                INSERT INTO revisiones_bascula (
                    folio_re, fecha, id_cliente, id_tecnico,
                    tipo_bascula, num_celdas, horario,
                    contacto_nombre, contacto_telefono, contacto_correo,
                    obs_cables_conectores, obs_generales, observaciones,
                    estatus_revision
                ) VALUES (
                    %(folio_re)s, %(fecha)s, %(id_cliente)s, %(id_tecnico)s,
                    %(tipo_bascula)s, %(num_celdas)s, %(horario)s,
                    %(contacto_nombre)s, %(contacto_telefono)s, %(contacto_correo)s,
                    %(obs_cables_conectores)s, %(obs_generales)s, %(observaciones)s,
                    %(estatus_revision)s
                )
                RETURNING id, folio_re, estado, created_at
            """
            _params = {
                "folio_re":             folio,
                "fecha":                data.get("fecha"),
                "id_cliente":           data.get("id_cliente"),
                "id_tecnico":           data.get("id_tecnico"),
                "tipo_bascula":         data.get("tipo_bascula"),
                "num_celdas":           data.get("num_celdas", 4),
                "horario":              data.get("horario"),
                "contacto_nombre":      data.get("contacto_nombre"),
                "contacto_telefono":    data.get("contacto_telefono"),
                "contacto_correo":      data.get("contacto_correo"),
                "obs_cables_conectores":data.get("obs_cables_conectores"),
                "obs_generales":        data.get("obs_generales"),
                "observaciones":        data.get("observaciones"),
                "estatus_revision":     data.get("estatus_revision", "PENDIENTE"),
                # Campos v15 (pueden ser None si aún no existe la migración)
                "sucursal_id":          data.get("sucursal_id"),
                "equipo_catalogo_id":   data.get("equipo_catalogo_id"),
                "marca":                data.get("marca"),
                "modelo":               data.get("modelo"),
                "numero_serie":         data.get("numero_serie"),
                "id_indicador_equipo":  data.get("id_indicador_equipo"),
                "ubicacion_interna":    data.get("ubicacion_interna"),
            }
            try:
                cur.execute(_INSERT_V15, _params)
            except Exception as col_exc:
                # Columnas v15 aún no existen en BD — reintentar con INSERT base
                conn.rollback()
                logger.warning("columnas v15 no disponibles, usando INSERT base: %s", col_exc)
                # Re-generar folio (rollback lo perdió)
                cur2 = conn.cursor(cursor_factory=RealDictCursor)
                cur2.execute(
                    "SELECT generate_folio(%s::varchar, %s::smallint) AS folio",
                    ("RE", anio)
                )
                folio = cur2.fetchone()["folio"]
                _params["folio_re"] = folio
                cur2.execute(_INSERT_BASE, _params)
                cur = cur2
            row = cur.fetchone()
            rev_id = row["id"]

            # 3. Celdas (Ohms + funcionalidad)
            for idx, celda in enumerate(data.get("celdas", []), start=1):
                cur.execute(
                    """
                    INSERT INTO det_celdas_carga (
                        id_revision, celda_num,
                        signal_mv, excitacion_v, estado_fisico, cable_ok, observacion,
                        exc_plus_minus, sig_plus_minus, sig_plus_exc_plus,
                        sig_minus_exc_minus, resistencia_entrada, resistencia_salida,
                        funciona, obs_funcionalidad
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s,
                        %s, %s, %s, %s, %s, %s, %s, %s
                    )
                    ON CONFLICT (id_revision, celda_num) DO UPDATE SET
                        exc_plus_minus      = EXCLUDED.exc_plus_minus,
                        sig_plus_minus      = EXCLUDED.sig_plus_minus,
                        sig_plus_exc_plus   = EXCLUDED.sig_plus_exc_plus,
                        sig_minus_exc_minus = EXCLUDED.sig_minus_exc_minus,
                        resistencia_entrada = EXCLUDED.resistencia_entrada,
                        resistencia_salida  = EXCLUDED.resistencia_salida,
                        funciona            = EXCLUDED.funciona,
                        obs_funcionalidad   = EXCLUDED.obs_funcionalidad
                    """,
                    (
                        rev_id, idx,
                        celda.get("signal_mv"), celda.get("excitacion_v"),
                        celda.get("estado_fisico"), celda.get("cable_ok", True),
                        celda.get("observacion"),
                        celda.get("exc_plus_minus"),
                        celda.get("sig_plus_minus"),
                        celda.get("sig_plus_exc_plus"),
                        celda.get("sig_minus_exc_minus"),
                        celda.get("resistencia_entrada"),
                        celda.get("resistencia_salida"),
                        celda.get("funciona", True),
                        celda.get("obs_funcionalidad"),
                    )
                )

            # 4. Inspección visual
            for item in data.get("inspeccion", []):
                cur.execute(
                    """
                    INSERT INTO det_inspeccion_visual
                        (id_revision, punto_num, descripcion, cumple, observacion)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (id_revision, punto_num) DO UPDATE SET
                        cumple      = EXCLUDED.cumple,
                        observacion = EXCLUDED.observacion
                    """,
                    (rev_id,
                     item["punto_num"], item["descripcion"],
                     item.get("cumple"), item.get("observacion"))
                )

            # 5. Periféricos
            for item in data.get("perifericos", []):
                cur.execute(
                    """
                    INSERT INTO det_perifericos
                        (id_revision, tipo, descripcion, cumple, observacion)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (id_revision, tipo) DO UPDATE SET
                        cumple      = EXCLUDED.cumple,
                        observacion = EXCLUDED.observacion
                    """,
                    (rev_id,
                     item["tipo"], item.get("descripcion", ""),
                     item.get("cumple"), item.get("observacion"))
                )

        logger.info(f"Revisión completa creada: {folio}")
        return dict(row)

    # ── Otros CRUD ────────────────────────────────────────────────────────────

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE revisiones_bascula SET
                fecha         = %(fecha)s,
                id_cliente    = %(id_cliente)s,
                id_tecnico    = %(id_tecnico)s,
                tipo_bascula  = %(tipo_bascula)s,
                num_celdas    = %(num_celdas)s,
                observaciones = %(observaciones)s,
                estatus_revision = %(estatus_revision)s
            WHERE id = %(id)s
            RETURNING id, folio_re, estado, updated_at
            """,
            {**data, "id": record_id}, returning=True
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        result = self._write(
            "UPDATE revisiones_bascula SET estado='CANCELADA' WHERE id=%s RETURNING id",
            (record_id,), returning=True
        )
        return result is not None

    # Alias para satisfacer BaseRepository abstracto
    def create(self, data: dict) -> dict:
        return self.create_full(data)


revision_bascula_repo = RevisionBasculaRepository()
