"""
Repositorio de Órdenes de Servicio.
Maneja CRUD completo de OS incluyendo las tablas de detalle metrológico
dentro de transacciones atómicas.
"""
import json
import logging
from typing import Optional

from database.connection import db_pool
from models.base_model import BaseRepository
from models.folio_manager import FolioManager

logger = logging.getLogger(__name__)


_V_OS_QUERY = """
    SELECT 
        os.*,
        cl.razon_social AS cliente,
        cl.direccion AS direccion_cliente,
        su.nombre_sucursal AS sucursal_nombre,
        su.direccion AS sucursal_direccion,
        ts.nombre AS tipo_servicio,
        tc.nombre_completo AS tecnico,
        tc.nombre_completo AS tecnico_nombre,
        ti.nombre AS tipo_instrumento,
        ce.codigo AS clase_exactitud_codigo,
        ce.nombre AS clase_exactitud_nombre,
        ce.simbolo AS clase_exactitud_simbolo,
        adj.nombre_archivo AS archivo_escaneado,
        adj.ruta_completa AS ruta_escaneado,
        adj.fecha_adjunto
    FROM ordenes_servicio os
    LEFT JOIN cat_clientes cl ON os.id_cliente = cl.id
    LEFT JOIN cliente_sucursales su ON os.sucursal_id = su.id
    LEFT JOIN cat_tipo_servicio ts ON os.id_tipo_servicio = ts.id
    LEFT JOIN cat_tecnicos tc ON os.id_tecnico = tc.id
    LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
    LEFT JOIN cat_clase_exactitud ce ON os.id_clase_exactitud = ce.id
    LEFT JOIN adjuntos_os adj ON os.id = adj.id_os
"""

class OrdenServicioRepository(BaseRepository):
    TABLE = "ordenes_servicio"

    # ── Consultas ─────────────────────────────────────────────────────────────

    def get_all(self, estado: Optional[str] = None) -> list[dict]:
        """Retorna todas las OS, opcionalmente filtradas por estado."""
        if estado:
            sql = f"""
                SELECT * FROM ({_V_OS_QUERY}) AS v_ordenes_servicio
                WHERE estado = %s
                ORDER BY fecha DESC, id DESC
            """
            return self._fetch_all(sql, (estado,))
        else:
            return self._fetch_all(
                f"SELECT * FROM ({_V_OS_QUERY}) AS v_ordenes_servicio ORDER BY fecha DESC, id DESC"
            )

    def get_by_id(self, record_id: int) -> Optional[dict]:
        """Retorna una OS completa (datos generales) por su ID."""
        row = self._fetch_one(
            f"SELECT * FROM ({_V_OS_QUERY}) AS v_ordenes_servicio WHERE id = %s", (record_id,)
        )
        if row:
            folio = row.get("folio_os", "")
            if folio.startswith("LP-"):
                lp_data = self._fetch_one(
                    "SELECT * FROM det_levantamiento_proyecto WHERE id_os = %s", (record_id,)
                )
                if lp_data:
                    row["levantamiento_proyecto"] = lp_data
            elif folio.startswith("LV-"):
                lv_data = self._fetch_one(
                    "SELECT * FROM det_levantamiento_metrologico WHERE id_os = %s",
                    (record_id,)
                )
                if lv_data:
                    import json
                    # Deserializar basculas JSONB si viene como string
                    raw = lv_data.get("basculas", [])
                    if isinstance(raw, str):
                        raw = json.loads(raw)
                    lv_data["basculas"] = raw
                    row["levantamiento_metrologico"] = lv_data
        return row

    def get_by_folio(self, folio: str) -> Optional[dict]:
        """Busca una OS por su folio."""
        return self._fetch_one(
            f"SELECT * FROM ({_V_OS_QUERY}) AS v_ordenes_servicio WHERE folio_os = %s", (folio,)
        )

    def search(self, term: str) -> list[dict]:
        """Búsqueda full-text por folio, cliente, marca, modelo, NS."""
        sql = f"""
            SELECT * FROM ({_V_OS_QUERY}) AS v_ordenes_servicio
            WHERE
                folio_os ILIKE %s OR
                cliente ILIKE %s OR
                marca ILIKE %s OR
                modelo ILIKE %s OR
                ns ILIKE %s
            ORDER BY fecha DESC, id DESC
            LIMIT 100
        """
        like = f"%{term}%"
        return self._fetch_all(sql, (like, like, like, like, like))

    # ── Detalle Metrológico ───────────────────────────────────────────────────

    def get_repetibilidad(self, os_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_repetibilidad WHERE id_os = %s ORDER BY posicion_id",
            (os_id,),
        )

    def get_excentricidad(self, os_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_excentricidad WHERE id_os = %s ORDER BY posicion_id",
            (os_id,),
        )

    def get_exactitud(self, os_id: int) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM det_exactitud WHERE id_os = %s ORDER BY punto_id",
            (os_id,),
        )

    # ── Creación ──────────────────────────────────────────────────────────────

    def create(self, data: dict) -> dict:
        """
        Crea una nueva OS completa en una sola transacción:
        1. Genera el folio consecutivo (atómico en BD)
        2. Inserta ordenes_servicio
        3. Inserta filas en det_repetibilidad, det_excentricidad, det_exactitud

        Args:
            data: Diccionario con todos los campos de la OS.
                  Claves especiales:
                    'repetibilidad': list[dict] con posicion_id, lectura_inicial, lectura_final
                    'excentricidad': list[dict]
                    'exactitud':     list[dict] con punto_id, valor_nominal, lecturas

        Returns:
            Diccionario con el registro de OS creado (incluyendo folio_os).
        """
        from datetime import datetime

        anio = data.get("anio") or datetime.now().year

        with db_pool.transaction() as conn:
            with conn.cursor() as cur:
                from psycopg2.extras import RealDictCursor
                cur = conn.cursor(cursor_factory=RealDictCursor)

                if data.get("levantamiento_metrologico"):
                    tipo_folio = "LV"
                elif data.get("levantamiento_proyecto"):
                    tipo_folio = "LP"
                else:
                    tipo_folio = "OS"
                # 1. Generar folio (atómico) — cast a VARCHAR + SMALLINT
                cur.execute("SELECT generate_folio(%s::varchar, %s::smallint) AS folio", (tipo_folio, anio))
                folio = cur.fetchone()["folio"]
                logger.info(f"Folio generado en transacción: {folio}")

                # 2. Insertar OS principal
                # tipo_documento coincide con el tipo de folio (OS, LP, LV)
                tipo_documento = tipo_folio  # 'OS', 'LP' o 'LV'

                cur.execute(
                    """
                    INSERT INTO ordenes_servicio (
                        folio_os, fecha, id_tipo_servicio, id_cliente,
                        marca, modelo, ns, ubicacion,
                        alcance_max, div_minima, div_verificacion, id_equipo,
                        id_tipo_instrumento, numero_cca, holograma_anterior,
                        holograma_actualizado,
                        valor_repetibilidad, valor_excentricidad, id_clase_exactitud,
                        observaciones, id_tecnico, firma_cliente_nombre, estado,
                        tipo_documento, sucursal_id, equipo_catalogo_id
                    ) VALUES (
                        %(folio_os)s, %(fecha)s, %(id_tipo_servicio)s, %(id_cliente)s,
                        %(marca)s, %(modelo)s, %(ns)s, %(ubicacion)s,
                        %(alcance_max)s, %(div_minima)s, %(div_verificacion)s, %(id_equipo)s,
                        %(id_tipo_instrumento)s, %(numero_cca)s, %(holograma_anterior)s,
                        %(holograma_actualizado)s,
                        %(valor_repetibilidad)s, %(valor_excentricidad)s, %(id_clase_exactitud)s,
                        %(observaciones)s, %(id_tecnico)s, %(firma_cliente_nombre)s,
                        COALESCE(%(estado)s, 'PROCESO'),
                        %(tipo_documento)s, %(sucursal_id)s, %(equipo_catalogo_id)s
                    )
                    RETURNING id, folio_os, estado, created_at
                    """,
                    {
                        "folio_os": folio,
                        "fecha": data.get("fecha"),
                        "id_tipo_servicio": data.get("id_tipo_servicio"),
                        "id_cliente": data.get("id_cliente"),
                        "marca": data.get("marca"),
                        "modelo": data.get("modelo"),
                        "ns": data.get("ns"),
                        "ubicacion": data.get("ubicacion"),
                        "alcance_max": data.get("alcance_max"),
                        "div_minima": data.get("div_minima"),
                        "div_verificacion": data.get("div_verificacion"),
                        "id_equipo": data.get("id_equipo"),
                        "id_tipo_instrumento": data.get("id_tipo_instrumento"),
                        "numero_cca": data.get("numero_cca"),
                        "holograma_anterior": data.get("holograma_anterior"),
                        "holograma_actualizado": data.get("holograma_actualizado"),
                        "valor_repetibilidad": data.get("valor_repetibilidad"),
                        "valor_excentricidad": data.get("valor_excentricidad"),
                        "id_clase_exactitud": data.get("id_clase_exactitud"),
                        "observaciones": data.get("observaciones"),
                        "id_tecnico": data.get("id_tecnico"),
                        "firma_cliente_nombre": data.get("firma_cliente_nombre"),
                        "estado": data.get("estado"),
                        "tipo_documento": data.get("tipo_documento") or tipo_documento,
                        "sucursal_id": data.get("sucursal_id"),
                        "equipo_catalogo_id": data.get("equipo_catalogo_id"),
                    },
                )
                os_row = cur.fetchone()
                os_id = os_row["id"]

                # 3. Insertar pruebas de Repetibilidad
                for row in data.get("repetibilidad", []):
                    if row.get("lectura_inicial") is not None or row.get("lectura_final") is not None:
                        cur.execute(
                            """
                            INSERT INTO det_repetibilidad (id_os, posicion_id, lectura_inicial, lectura_final)
                            VALUES (%s, %s, %s, %s)
                            ON CONFLICT (id_os, posicion_id) DO UPDATE
                                SET lectura_inicial = EXCLUDED.lectura_inicial,
                                    lectura_final   = EXCLUDED.lectura_final
                            """,
                            (os_id, row["posicion_id"], row.get("lectura_inicial"), row.get("lectura_final")),
                        )

                # 4. Insertar pruebas de Excentricidad
                for row in data.get("excentricidad", []):
                    if row.get("lectura_inicial") is not None or row.get("lectura_final") is not None:
                        cur.execute(
                            """
                            INSERT INTO det_excentricidad (id_os, posicion_id, lectura_inicial, lectura_final)
                            VALUES (%s, %s, %s, %s)
                            ON CONFLICT (id_os, posicion_id) DO UPDATE
                                SET lectura_inicial = EXCLUDED.lectura_inicial,
                                    lectura_final   = EXCLUDED.lectura_final
                            """,
                            (os_id, row["posicion_id"], row.get("lectura_inicial"), row.get("lectura_final")),
                        )

                # 5. Insertar pruebas de Exactitud
                for row in data.get("exactitud", []):
                    if any(row.get(k) is not None for k in ("valor_nominal", "lectura_inicial", "lectura_final")):
                        cur.execute(
                            """
                            INSERT INTO det_exactitud (id_os, punto_id, valor_nominal, lectura_inicial, lectura_final)
                            VALUES (%s, %s, %s, %s, %s)
                            ON CONFLICT (id_os, punto_id) DO UPDATE
                                SET valor_nominal   = EXCLUDED.valor_nominal,
                                    lectura_inicial = EXCLUDED.lectura_inicial,
                                    lectura_final   = EXCLUDED.lectura_final
                            """,
                            (
                                os_id, row["punto_id"],
                                row.get("valor_nominal"),
                                row.get("lectura_inicial"),
                                row.get("lectura_final"),
                            ),
                        )

                # 6. Insertar Levantamiento de Proyecto
                lp_data = data.get("levantamiento_proyecto")
                if lp_data:
                    import json
                    cur.execute(
                        """
                        INSERT INTO det_levantamiento_proyecto (
                            id_os, tipo_alcance, material, clasificacion_area,
                            senal_comunicacion, puntos_corte, capacidad_estimada,
                            instrumentacion, equipos_maniobra, epp_seguridad,
                            masa_requerida, equipos_dinamicos
                        ) VALUES (
                            %(id_os)s, %(tipo_alcance)s, %(material)s, %(clasificacion_area)s,
                            %(senal_comunicacion)s, %(puntos_corte)s, %(capacidad_estimada)s,
                            %(instrumentacion)s, %(equipos_maniobra)s, %(epp_seguridad)s,
                            %(masa_requerida)s, %(equipos_dinamicos)s
                        )
                        """,
                        {
                            "id_os": os_id,
                            "tipo_alcance": lp_data.get("tipo_alcance"),
                            "material": lp_data.get("material"),
                            "clasificacion_area": lp_data.get("clasificacion_area"),
                            "senal_comunicacion": lp_data.get("senal_comunicacion"),
                            "puntos_corte": lp_data.get("puntos_corte"),
                            "capacidad_estimada": lp_data.get("capacidad_estimada"),
                            "instrumentacion": json.dumps(lp_data.get("instrumentacion", [])),
                            "equipos_maniobra": json.dumps(lp_data.get("equipos_maniobra", [])),
                            "epp_seguridad": json.dumps(lp_data.get("epp_seguridad", [])),
                            "masa_requerida": json.dumps(lp_data.get("masa_requerida", [])),
                            "equipos_dinamicos": json.dumps(lp_data.get("equipos_dinamicos", [])),
                        }
                    )

                # 7. Insertar Levantamiento Metrologico y Logistica de Pesas (LV)
                lv_data = data.get("levantamiento_metrologico")
                if lv_data:
                    import json
                    basculas = lv_data.get("basculas", [])
                    cur.execute(
                        """
                        INSERT INTO det_levantamiento_metrologico (
                            id_os, basculas, pesas_descripcion,
                            acomodo_maniobra, observaciones_generales
                        ) VALUES (
                            %(id_os)s, %(basculas)s, %(pesas_descripcion)s,
                            %(acomodo_maniobra)s, %(observaciones_generales)s
                        )
                        """,
                        {
                            "id_os": os_id,
                            "basculas": json.dumps(basculas),
                            "pesas_descripcion": lv_data.get("pesas_descripcion"),
                            "acomodo_maniobra": lv_data.get("acomodo_maniobra"),
                            "observaciones_generales": lv_data.get("observaciones_generales"),
                        }
                    )
                    # Upsert de básculas al catálogo de equipos de la sucursal
                    sucursal_id = data.get("sucursal_id")
                    if sucursal_id and basculas:
                        self._upsert_basculas_catalogo(cur, sucursal_id, basculas)

                # 8. Guardar snapshot JSON íntegro del payload (datos_tecnicos_json)
                #    Permite reconstruir el PDF sin necesidad de regenerar si ya existe.
                try:
                    snapshot = json.dumps(data, ensure_ascii=False, default=str)
                    cur.execute(
                        "UPDATE ordenes_servicio SET datos_tecnicos_json = %s WHERE id = %s",
                        (snapshot, os_id),
                    )
                except Exception as snap_exc:
                    logger.warning("create: no se pudo guardar datos_tecnicos_json: %s", snap_exc)

        logger.info(f"OS/LP/LV creada exitosamente: ID={os_id}, Folio={folio}")
        return dict(os_row)

    # ── Actualización ─────────────────────────────────────────────────────────

    def update(self, record_id: int, data: dict) -> dict:
        """Actualiza los datos generales de una OS/LP existente."""
        with db_pool.transaction() as conn:
            with conn.cursor() as cur:
                from psycopg2.extras import RealDictCursor
                cur = conn.cursor(cursor_factory=RealDictCursor)
                
                # Derivar tipo_documento desde el folio existente si no viene en data
                tipo_doc_data = data.get("tipo_documento") or ""
                if not tipo_doc_data:
                    cur.execute("SELECT folio_os FROM ordenes_servicio WHERE id = %s", (record_id,))
                    folio_row = cur.fetchone()
                    folio_actual = (folio_row["folio_os"] if folio_row else "") or ""
                    if folio_actual.startswith("LP-"):
                        tipo_doc_data = "LP"
                    elif folio_actual.startswith("LV-"):
                        tipo_doc_data = "LV"
                    elif folio_actual.startswith("RMA-"):
                        tipo_doc_data = "RMA"
                    elif folio_actual.startswith("RE-"):
                        tipo_doc_data = "RE"
                    else:
                        tipo_doc_data = "OS"

                cur.execute(
                    """
                    UPDATE ordenes_servicio SET
                        fecha               = %(fecha)s,
                        id_tipo_servicio    = %(id_tipo_servicio)s,
                        id_cliente          = %(id_cliente)s,
                        marca               = %(marca)s,
                        modelo              = %(modelo)s,
                        ns                  = %(ns)s,
                        ubicacion           = %(ubicacion)s,
                        alcance_max         = %(alcance_max)s,
                        div_minima          = %(div_minima)s,
                        div_verificacion    = %(div_verificacion)s,
                        id_equipo           = %(id_equipo)s,
                        id_tipo_instrumento = %(id_tipo_instrumento)s,
                        numero_cca          = %(numero_cca)s,
                        holograma_anterior  = %(holograma_anterior)s,
                        holograma_actualizado = %(holograma_actualizado)s,
                        valor_repetibilidad = %(valor_repetibilidad)s,
                        valor_excentricidad = %(valor_excentricidad)s,
                        id_clase_exactitud  = %(id_clase_exactitud)s,
                        observaciones       = %(observaciones)s,
                        id_tecnico          = %(id_tecnico)s,
                        firma_cliente_nombre= %(firma_cliente_nombre)s,
                        tipo_documento      = %(tipo_documento)s,
                        sucursal_id         = %(sucursal_id)s,
                        equipo_catalogo_id  = %(equipo_catalogo_id)s,
                        updated_at          = NOW()
                    WHERE id = %(id)s
                    RETURNING id, folio_os, estado, updated_at
                    """,
                    {
                        "fecha":                 data.get("fecha"),
                        "id_tipo_servicio":      data.get("id_tipo_servicio"),
                        "id_cliente":            data.get("id_cliente"),
                        "marca":                 data.get("marca"),
                        "modelo":                data.get("modelo"),
                        "ns":                    data.get("ns"),
                        "ubicacion":             data.get("ubicacion"),
                        "alcance_max":           data.get("alcance_max"),
                        "div_minima":            data.get("div_minima"),
                        "div_verificacion":      data.get("div_verificacion"),
                        "id_equipo":             data.get("id_equipo"),
                        "id_tipo_instrumento":   data.get("id_tipo_instrumento"),
                        "numero_cca":            data.get("numero_cca"),
                        "holograma_anterior":    data.get("holograma_anterior"),
                        "holograma_actualizado": data.get("holograma_actualizado"),
                        "valor_repetibilidad":   data.get("valor_repetibilidad"),
                        "valor_excentricidad":   data.get("valor_excentricidad"),
                        "id_clase_exactitud":    data.get("id_clase_exactitud"),
                        "observaciones":         data.get("observaciones"),
                        "id_tecnico":            data.get("id_tecnico"),
                        "firma_cliente_nombre":  data.get("firma_cliente_nombre"),
                        "tipo_documento":        tipo_doc_data,
                        "sucursal_id":           data.get("sucursal_id"),
                        "equipo_catalogo_id":    data.get("equipo_catalogo_id"),
                        "id":                    record_id,
                    }
                )
                row = cur.fetchone()


                lp_data = data.get("levantamiento_proyecto")
                if lp_data:
                        # Upsert seguro sin ON CONFLICT
                        cur.execute(
                            "SELECT id FROM det_levantamiento_proyecto WHERE id_os = %(id_os)s",
                            {"id_os": record_id}
                        )
                        if cur.fetchone():
                            cur.execute(
                                """
                                UPDATE det_levantamiento_proyecto SET
                                    tipo_alcance = %(tipo_alcance)s, material = %(material)s,
                                    clasificacion_area = %(clasificacion_area)s,
                                    senal_comunicacion = %(senal_comunicacion)s,
                                    puntos_corte = %(puntos_corte)s, capacidad_estimada = %(capacidad_estimada)s,
                                    instrumentacion = %(instrumentacion)s, equipos_maniobra = %(equipos_maniobra)s,
                                    epp_seguridad = %(epp_seguridad)s, masa_requerida = %(masa_requerida)s,
                                    equipos_dinamicos = %(equipos_dinamicos)s
                                WHERE id_os = %(id_os)s
                                """,
                                {
                                    "id_os": record_id,
                                    "tipo_alcance": lp_data.get("tipo_alcance"),
                                    "material": lp_data.get("material"),
                                    "clasificacion_area": lp_data.get("clasificacion_area"),
                                    "senal_comunicacion": lp_data.get("senal_comunicacion"),
                                    "puntos_corte": lp_data.get("puntos_corte"),
                                    "capacidad_estimada": lp_data.get("capacidad_estimada"),
                                    "instrumentacion": json.dumps(lp_data.get("instrumentacion", [])),
                                    "equipos_maniobra": json.dumps(lp_data.get("equipos_maniobra", [])),
                                    "epp_seguridad": json.dumps(lp_data.get("epp_seguridad", [])),
                                    "masa_requerida": json.dumps(lp_data.get("masa_requerida", [])),
                                    "equipos_dinamicos": json.dumps(lp_data.get("equipos_dinamicos", [])),
                                }
                            )
                        else:
                            cur.execute(
                                """
                                INSERT INTO det_levantamiento_proyecto (
                                    id_os, tipo_alcance, material, clasificacion_area,
                                    senal_comunicacion, puntos_corte, capacidad_estimada,
                                    instrumentacion, equipos_maniobra, epp_seguridad,
                                    masa_requerida, equipos_dinamicos
                                ) VALUES (
                                    %(id_os)s, %(tipo_alcance)s, %(material)s, %(clasificacion_area)s,
                                    %(senal_comunicacion)s, %(puntos_corte)s, %(capacidad_estimada)s,
                                    %(instrumentacion)s, %(equipos_maniobra)s, %(epp_seguridad)s,
                                    %(masa_requerida)s, %(equipos_dinamicos)s
                                )
                                """,
                                {
                                    "id_os": record_id,
                                    "tipo_alcance": lp_data.get("tipo_alcance"),
                                    "material": lp_data.get("material"),
                                    "clasificacion_area": lp_data.get("clasificacion_area"),
                                    "senal_comunicacion": lp_data.get("senal_comunicacion"),
                                    "puntos_corte": lp_data.get("puntos_corte"),
                                    "capacidad_estimada": lp_data.get("capacidad_estimada"),
                                    "instrumentacion": json.dumps(lp_data.get("instrumentacion", [])),
                                    "equipos_maniobra": json.dumps(lp_data.get("equipos_maniobra", [])),
                                    "epp_seguridad": json.dumps(lp_data.get("epp_seguridad", [])),
                                    "masa_requerida": json.dumps(lp_data.get("masa_requerida", [])),
                                    "equipos_dinamicos": json.dumps(lp_data.get("equipos_dinamicos", [])),
                                }
                            )

                # LV: Actualizar Levantamiento Metrologico
                lv_data = data.get("levantamiento_metrologico")
                if lv_data:
                    import json
                    basculas = lv_data.get("basculas", [])
                    # Upsert seguro sin ON CONFLICT
                    cur.execute(
                        "SELECT id FROM det_levantamiento_metrologico WHERE id_os = %(id_os)s",
                        {"id_os": record_id}
                    )
                    if cur.fetchone():
                        cur.execute(
                            """
                            UPDATE det_levantamiento_metrologico SET
                                basculas = %(basculas)s, pesas_descripcion = %(pesas_descripcion)s,
                                acomodo_maniobra = %(acomodo_maniobra)s,
                                observaciones_generales = %(observaciones_generales)s,
                                updated_at = NOW()
                            WHERE id_os = %(id_os)s
                            """,
                            {
                                "id_os": record_id,
                                "basculas": json.dumps(basculas),
                                "pesas_descripcion": lv_data.get("pesas_descripcion"),
                                "acomodo_maniobra": lv_data.get("acomodo_maniobra"),
                                "observaciones_generales": lv_data.get("observaciones_generales"),
                            }
                        )
                    else:
                        cur.execute(
                            """
                            INSERT INTO det_levantamiento_metrologico (
                                id_os, basculas, pesas_descripcion,
                                acomodo_maniobra, observaciones_generales
                            ) VALUES (
                                %(id_os)s, %(basculas)s, %(pesas_descripcion)s,
                                %(acomodo_maniobra)s, %(observaciones_generales)s
                            )
                            """,
                            {
                                "id_os": record_id,
                                "basculas": json.dumps(basculas),
                                "pesas_descripcion": lv_data.get("pesas_descripcion"),
                                "acomodo_maniobra": lv_data.get("acomodo_maniobra"),
                                "observaciones_generales": lv_data.get("observaciones_generales"),
                            }
                        )
                    # Upsert equipos al catálogo de la sucursal
                    sucursal_id = data.get("sucursal_id")
                    if sucursal_id and basculas:
                        self._upsert_basculas_catalogo(cur, sucursal_id, basculas)

                # Guardar snapshot JSON íntegro del payload actualizado
                try:
                    snapshot = json.dumps(data, ensure_ascii=False, default=str)
                    cur.execute(
                        "UPDATE ordenes_servicio SET datos_tecnicos_json = %s WHERE id = %s",
                        (snapshot, record_id),
                    )
                except Exception as snap_exc:
                    logger.warning("update: no se pudo guardar datos_tecnicos_json: %s", snap_exc)

        return dict(row) if row else {}

    def _upsert_basculas_catalogo(self, cur, sucursal_id: int, basculas: list) -> None:
        """
        Realiza upsert de cada báscula del levantamiento en cliente_equipos,
        vinculándolas a la sucursal. Usa fn_upsert_equipo_desde_os() de la BD.
        Básculas sin numero_serie se omiten (número de serie es la clave única).
        """
        for bascula in basculas:
            ns = (bascula.get("numero_serie") or "").strip()
            if not ns:
                continue  # Sin serie no hay clave única, omitir
            try:
                cur.execute(
                    "SELECT fn_upsert_equipo_desde_os(%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    (
                        sucursal_id,
                        ns,
                        bascula.get("marca") or None,
                        bascula.get("modelo") or None,
                        bascula.get("id_indicador") or None,
                        bascula.get("ubicacion_interna") or None,
                        bascula.get("capacidad_max") or None,
                        bascula.get("division_min") or None,
                        bascula.get("tipo_instrumento") or None,
                    )
                )
            except Exception as exc:
                logger.warning(
                    "_upsert_basculas_catalogo: error para NS=%s: %s", ns, exc
                )

    def update_pdf_path(self, record_id: int, pdf_path: str) -> None:
        """Actualiza la ruta del PDF generado para una OS (llamar después de generate_os_pdf)."""
        try:
            self._write(
                "UPDATE ordenes_servicio SET pdf_path = %s WHERE id = %s",
                (pdf_path, record_id),
            )
        except Exception as exc:
            logger.warning("update_pdf_path: error para id=%s: %s", record_id, exc)

    def update_estado(self, record_id: int, estado: str) -> bool:
        """Cambia el estado de una OS (PROCESO, CANCELADA, ESCANEADA)."""
        result = self._write(
            "UPDATE ordenes_servicio SET estado = %s WHERE id = %s RETURNING id",
            (estado, record_id),
            returning=True,
        )
        return result is not None

    def delete(self, record_id: int) -> bool:
        """Cancela una OS (soft delete cambiando estado a CANCELADA)."""
        return self.update_estado(record_id, "CANCELADA")

    # ── Estadísticas ──────────────────────────────────────────────────────────

    def get_estadisticas(self) -> dict:
        """Retorna conteos de OS por estado para el dashboard."""
        rows = self._fetch_all(
            """
            SELECT estado, COUNT(*) AS total
            FROM ordenes_servicio
            GROUP BY estado
            """
        )
        return {r["estado"]: int(r["total"]) for r in rows}

    def get_os_para_calibrador(self) -> list[dict]:
        """
        Retorna las OS que tienen componente de Calibración y ya fueron
        completadas/escaneadas por el técnico de campo.
        Visible para usuarios con rol 'calibrador' para iniciar la etapa
        de laboratorio / cálculo.

        Tipos incluidos: Calibración (1), Calibración+Ajuste (4),
                         Calibración+Inspección (5), Cal+Aj+Insp (7).
        """
        from services.tipo_servicio_rules import IDS_CON_CALIBRACION
        ids_list = tuple(IDS_CON_CALIBRACION)
        sql = f"""
            SELECT *
            FROM ({_V_OS_QUERY}) AS v_ordenes_servicio
            WHERE id_tipo_servicio = ANY(%s)
              AND estado IN ('ESCANEADA', 'PROCESO')
            ORDER BY fecha DESC, id DESC
            LIMIT 200
        """
        return self._fetch_all(sql, (list(ids_list),))

    def get_os_para_inspector(self) -> list[dict]:
        """
        Retorna las OS que tienen componente de Inspección y ya fueron
        completadas/escaneadas por el técnico de campo.
        Visible para usuarios con rol 'inspector' para emitir el dictamen.

        Tipos incluidos: Inspección (3), Calibración+Inspección (5),
                         Ajuste+Inspección (6), Cal+Aj+Insp (7).
        """
        from services.tipo_servicio_rules import IDS_CON_INSPECCION
        ids_list = tuple(IDS_CON_INSPECCION)
        sql = """
            SELECT *
            FROM v_ordenes_servicio
            WHERE id_tipo_servicio = ANY(%s)
              AND estado IN ('ESCANEADA', 'PROCESO')
            ORDER BY fecha DESC, id DESC
            LIMIT 200
        """
        return self._fetch_all(sql, (list(ids_list),))


# Instancia singleton
orden_servicio_repo = OrdenServicioRepository()
