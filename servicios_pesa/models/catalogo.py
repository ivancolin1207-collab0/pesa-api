"""
Repositorios de catálogos: Clientes, Técnicos, Tipos de Servicio,
Tipos de Instrumento y Clases de Exactitud.
"""
import logging
from typing import Optional

from database.connection import db_pool
from models.base_model import BaseRepository

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
class ClienteRepository(BaseRepository):
    """CRUD para cat_clientes."""
    TABLE = "cat_clientes"

    def get_all(self, solo_activos: bool = True) -> list[dict]:
        """Retorna clientes. Tolera activo=NULL (registros legacy) tratándolos como activos."""
        sql = "SELECT * FROM cat_clientes"
        if solo_activos:
            # activo IS NOT FALSE incluye TRUE y NULL (compatibilidad con rows legacy sin activo)
            sql += " WHERE activo IS NOT FALSE"
        sql += " ORDER BY razon_social"
        return self._fetch_all(sql)

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            "SELECT * FROM cat_clientes WHERE id = %s", (record_id,)
        )

    def search(self, term: str) -> list[dict]:
        return self._fetch_all(
            """
            SELECT * FROM cat_clientes
            WHERE activo IS NOT FALSE AND (
                razon_social ILIKE %s
            )
            ORDER BY razon_social LIMIT 50
            """,
            (f"%{term}%",),
        )

    def create(self, data: dict) -> dict:
        """Crea un nuevo cliente. Requiere razon_social no vacío."""
        razon_social = (data.get("razon_social") or "").strip()
        if not razon_social:
            raise ValueError("La Razón Social es obligatoria y no puede estar vacía.")
        direccion = (data.get("direccion") or "").strip()

        row = self._write(
            """
            INSERT INTO cat_clientes (
                razon_social, direccion, activo
            ) VALUES (
                %(razon_social)s, %(direccion)s, TRUE
            )
            RETURNING *
            """,
            {"razon_social": razon_social, "direccion": direccion},
            returning=True,
        )
        if row is None:
            raise RuntimeError(
                "El INSERT se ejecutó pero el servidor no retornó el registro creado. "
                "Verifica que la tabla cat_clientes tenga PRIMARY KEY en la columna 'id'."
            )
        logger.info("ClienteRepository.create: id=%s razon_social=%s", row.get('id'), razon_social)
        return dict(row)

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE cat_clientes SET
                razon_social   = %(razon_social)s,
                direccion      = %(direccion)s
            WHERE id = %(id)s
            RETURNING *
            """,
            {"id": record_id, "razon_social": data.get("razon_social", ""), "direccion": data.get("direccion", "")},
            returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        """Soft delete: desactiva el cliente."""
        result = self._write(
            "UPDATE cat_clientes SET activo = FALSE WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None

    def hard_delete(self, cliente_id: int) -> bool:
        """
        Eliminación definitiva de un cliente y toda su jerarquía.
        Lanza ValueError si el cliente tiene órdenes de servicio vinculadas.
        """
        from psycopg2.extras import RealDictCursor
        with db_pool.transaction() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Verificar OS vinculadas
                cur.execute(
                    "SELECT COUNT(*) AS n FROM ordenes_servicio WHERE id_cliente = %s",
                    (cliente_id,)
                )
                n_os = cur.fetchone()["n"]
                if n_os > 0:
                    raise ValueError(
                        f"No se puede eliminar: el cliente tiene {n_os} órden(es) de servicio en el historial."
                    )
                # Eliminar equipos -> sucursales -> cliente en cascada
                cur.execute(
                    """
                    DELETE FROM cliente_equipos
                    WHERE sucursal_id IN (
                        SELECT id FROM cliente_sucursales WHERE cliente_id = %s
                    )
                    """, (cliente_id,)
                )
                cur.execute(
                    "DELETE FROM cliente_sucursales WHERE cliente_id = %s", (cliente_id,)
                )
                cur.execute(
                    "DELETE FROM cat_clientes WHERE id = %s", (cliente_id,)
                )
        return True

    def merge(self, canonico_id: int, dup_ids: list) -> dict:
        """
        Fusiona los clientes duplicados (dup_ids) en el cliente canónico.

        Para cada sucursal de los duplicados:
          - Si el canónico ya tiene una sucursal con el mismo nombre_sucursal,
            la sucursal duplicada se desactiva (omitida) — sus equipos se mueven
            a la sucursal canónica homónima.
          - Si no existe conflicto, se reasigna directamente al canónico.

        Retorna un resumen {'sucursales_movidas': N, 'sucursales_omitidas': K,
                            'os_actualizadas': M}.
        """
        from psycopg2.extras import RealDictCursor
        stats = {
            "sucursales_movidas":  0,
            "sucursales_omitidas": 0,
            "os_actualizadas":     0,
        }
        with db_pool.transaction() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:

                # ── Obtener nombres de sucursales ya existentes en el canónico ──
                cur.execute(
                    """
                    SELECT id, LOWER(TRIM(nombre_sucursal)) AS nombre_norm
                    FROM cliente_sucursales
                    WHERE cliente_id = %s AND activo = TRUE
                    """,
                    (canonico_id,)
                )
                existentes = {row["nombre_norm"]: row["id"] for row in cur.fetchall()}

                # ── Procesar cada duplicado sucursal a sucursal ────────────────
                for dup_id in dup_ids:
                    cur.execute(
                        """
                        SELECT id, nombre_sucursal, LOWER(TRIM(nombre_sucursal)) AS nombre_norm
                        FROM cliente_sucursales
                        WHERE cliente_id = %s AND activo = TRUE
                        """,
                        (dup_id,)
                    )
                    sucursales_dup = cur.fetchall()

                    for suc in sucursales_dup:
                        nombre_norm = suc["nombre_norm"]

                        if nombre_norm in existentes:
                            # ── Conflicto: mover equipos a la sucursal canónica homónima
                            suc_canonico_id = existentes[nombre_norm]
                            cur.execute(
                                """
                                SELECT id, numero_serie
                                FROM cliente_equipos
                                WHERE sucursal_id = %s AND activo = TRUE
                                """,
                                (suc["id"],)
                            )
                            equipos_dup = cur.fetchall()
                            for eq in equipos_dup:
                                cur.execute(
                                    "SELECT id FROM cliente_equipos WHERE sucursal_id = %s AND numero_serie = %s",
                                    (suc_canonico_id, eq["numero_serie"])
                                )
                                if cur.fetchone() is None:
                                    cur.execute(
                                        "UPDATE cliente_equipos SET sucursal_id = %s WHERE id = %s",
                                        (suc_canonico_id, eq["id"])
                                    )
                            # Desactivar sucursal duplicada
                            cur.execute(
                                "UPDATE cliente_sucursales SET activo = FALSE WHERE id = %s",
                                (suc["id"],)
                            )
                            stats["sucursales_omitidas"] += 1
                        else:
                            # ── Sin conflicto: reasignar al canónico ──────────
                            cur.execute(
                                "UPDATE cliente_sucursales SET cliente_id = %s WHERE id = %s",
                                (canonico_id, suc["id"])
                            )
                            existentes[nombre_norm] = suc["id"]
                            stats["sucursales_movidas"] += 1

                # ── Reasignar Órdenes de Servicio ─────────────────────────────
                cur.execute(
                    "UPDATE ordenes_servicio SET id_cliente = %s WHERE id_cliente = ANY(%s)",
                    (canonico_id, list(dup_ids))
                )
                cur.execute(
                    "SELECT COUNT(*) AS n FROM ordenes_servicio WHERE id_cliente = %s",
                    (canonico_id,)
                )
                stats["os_actualizadas"] = cur.fetchone()["n"]

                # ── Desactivar los clientes duplicados ────────────────────────
                cur.execute(
                    "UPDATE cat_clientes SET activo = FALSE WHERE id = ANY(%s)",
                    (list(dup_ids),)
                )
        return stats


# ── Roles permitidos en el sistema PESA ──────────────────────────────────────
ROLES_PESA = [
    "Administrador",
    "Logística",
    "Recepción",
    "Técnico",
    "Técnico Calibrador",
    "Técnico Inspector",
]

# Roles cuyo titular ejecuta servicios en campo (aparecen en el selector de OS)
ROLES_OPERATIVOS = {"Técnico", "Técnico Calibrador", "Técnico Inspector"}


def _hash_password(plain: str) -> str:
    """
    Hashea la contraseña con SHA-256 (hexdigest).
    Mismo algoritmo que LoginDialog._hash_pw() para garantizar compatibilidad.
    Sin dependencias externas — no usa bcrypt.
    """
    import hashlib
    return hashlib.sha256(plain.encode("utf-8")).hexdigest()


# ══════════════════════════════════════════════════════════════════════════════
class TecnicoRepository(BaseRepository):
    """CRUD para cat_tecnicos, incluyendo gestión de rol y contraseña."""
    TABLE = "cat_tecnicos"

    def get_all(self, solo_activos: bool = True) -> list[dict]:
        sql = "SELECT * FROM cat_tecnicos"
        if solo_activos:
            sql += " WHERE activo = TRUE"
        sql += " ORDER BY nombre_completo"
        return self._fetch_all(sql)

    def get_operativos(self) -> list[dict]:
        """
        Retorna solo los técnicos con roles operativos de campo.
        Usa la función SQL fn_tecnicos_operativos() si está disponible.
        """
        try:
            return self._fetch_all("SELECT * FROM fn_tecnicos_operativos()")
        except Exception:
            # Fallback en caso de que la función no exista aún
            return self._fetch_all(
                "SELECT id, nombre_completo, rol FROM cat_tecnicos "
                "WHERE activo = TRUE AND rol IN %s ORDER BY nombre_completo",
                (tuple(ROLES_OPERATIVOS),),
            )

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            "SELECT * FROM cat_tecnicos WHERE id = %s", (record_id,)
        )

    def create(self, data: dict) -> dict:
        """
        Crea un técnico en cat_tecnicos y asigna su contraseña si fue provista.
        Incluye la columna 'roles' (JSON) para soporte multi-rol.
        Si la columna no existe aún, el fallback escribe solo 'rol'.
        """
        roles_json = data.get("roles") or None    # JSON string: '["Técnico", "Técnico Calibrador"]'
        params = {
            "nombre_completo": data.get("nombre_completo") or "",
            "usuario":         data.get("usuario") or "",
            "rol":             data.get("rol") or "Técnico",
            "roles":           roles_json,
            "telefono":        data.get("telefono"),
            "email":           data.get("email"),
        }

        pwd = data.get("password")
        if pwd:
            params["password_hash"] = _hash_password(pwd)
            query_with_roles = """
                INSERT INTO cat_tecnicos (nombre_completo, usuario, rol, roles, password_hash, telefono, email)
                VALUES (%(nombre_completo)s, %(usuario)s, %(rol)s, %(roles)s, %(password_hash)s, %(telefono)s, %(email)s)
                RETURNING *
            """
            query_without_roles = """
                INSERT INTO cat_tecnicos (nombre_completo, usuario, rol, password_hash, telefono, email)
                VALUES (%(nombre_completo)s, %(usuario)s, %(rol)s, %(password_hash)s, %(telefono)s, %(email)s)
                RETURNING *
            """
        else:
            query_with_roles = """
                INSERT INTO cat_tecnicos (nombre_completo, usuario, rol, roles, telefono, email)
                VALUES (%(nombre_completo)s, %(usuario)s, %(rol)s, %(roles)s, %(telefono)s, %(email)s)
                RETURNING *
            """
            query_without_roles = """
                INSERT INTO cat_tecnicos (nombre_completo, usuario, rol, telefono, email)
                VALUES (%(nombre_completo)s, %(usuario)s, %(rol)s, %(telefono)s, %(email)s)
                RETURNING *
            """

        # Intentar con columna 'roles'; si no existe, fallback sin ella
        try:
            row = self._write(query_with_roles, params, returning=True)
        except Exception as e:
            if "roles" in str(e).lower() or "no existe la columna" in str(e).lower():
                logger.warning("Columna 'roles' no disponible, usando fallback: %s", e)
                row = self._write(query_without_roles, params, returning=True)
            else:
                raise
        return dict(row) if row else {}

    def update(self, record_id: int, data: dict) -> dict:
        """
        Actualiza un técnico en la base de datos (cat_tecnicos).
        Incluye la columna 'roles' (JSON) si existe; fallback si no.
        Si data contiene 'password' (no vacío), incluye password_hash en la actualización.
        """
        roles_json = data.get("roles") or None
        params = {
            "id":              record_id,
            "nombre_completo": data.get("nombre_completo") or "",
            "usuario":         data.get("usuario") or "",
            "rol":             data.get("rol") or "Técnico",
            "roles":           roles_json,
            "telefono":        data.get("telefono"),
            "email":           data.get("email"),
        }

        pwd = data.get("password")
        if pwd:
            params["password_hash"] = _hash_password(pwd)
            query_with_roles = """
                UPDATE cat_tecnicos SET
                    nombre_completo = %(nombre_completo)s,
                    usuario         = %(usuario)s,
                    rol             = %(rol)s,
                    roles           = %(roles)s,
                    password_hash   = %(password_hash)s,
                    telefono        = %(telefono)s,
                    email           = %(email)s
                WHERE id = %(id)s
                RETURNING *
            """
            query_without_roles = """
                UPDATE cat_tecnicos SET
                    nombre_completo = %(nombre_completo)s,
                    usuario         = %(usuario)s,
                    rol             = %(rol)s,
                    password_hash   = %(password_hash)s,
                    telefono        = %(telefono)s,
                    email           = %(email)s
                WHERE id = %(id)s
                RETURNING *
            """
        else:
            query_with_roles = """
                UPDATE cat_tecnicos SET
                    nombre_completo = %(nombre_completo)s,
                    usuario         = %(usuario)s,
                    rol             = %(rol)s,
                    roles           = %(roles)s,
                    telefono        = %(telefono)s,
                    email           = %(email)s
                WHERE id = %(id)s
                RETURNING *
            """
            query_without_roles = """
                UPDATE cat_tecnicos SET
                    nombre_completo = %(nombre_completo)s,
                    usuario         = %(usuario)s,
                    rol             = %(rol)s,
                    telefono        = %(telefono)s,
                    email           = %(email)s
                WHERE id = %(id)s
                RETURNING *
            """

        try:
            row = self._write(query_with_roles, params, returning=True)
        except Exception as e:
            if "roles" in str(e).lower() or "no existe la columna" in str(e).lower():
                logger.warning("Columna 'roles' no disponible, usando fallback: %s", e)
                row = self._write(query_without_roles, params, returning=True)
            else:
                raise
        return dict(row) if row else {}


    def delete(self, record_id: int) -> bool:
        result = self._write(
            "UPDATE cat_tecnicos SET activo = FALSE WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None

    def upsert_usuario(self, id_tecnico: int, username: str, plain_password: str, rol: str = "Técnico") -> None:
        """
        Almacena la contraseña hasheada y el rol directamente en cat_tecnicos.
        Si en el futuro existe la tabla 'usuarios', también la actualiza,
        pero cat_tecnicos es siempre la fuente de verdad.
        """
        pwd_hash = _hash_password(plain_password)

        # ── Siempre actualizar cat_tecnicos (tabla principal) ─────────────────
        self._write(
            """
            UPDATE cat_tecnicos SET
                password_hash = %(pwd_hash)s,
                rol           = %(rol)s,
                usuario       = %(username)s
            WHERE id = %(id_tecnico)s
            """,
            {"pwd_hash": pwd_hash, "rol": rol, "username": username, "id_tecnico": id_tecnico},
        )

        # ── Actualizar 'usuarios' solo si la tabla existe (instalaciones futuras) ─
        try:
            self._write(
                """
                DO $$ BEGIN
                  IF EXISTS (
                      SELECT 1 FROM information_schema.tables
                      WHERE table_schema = 'public' AND table_name = 'usuarios'
                  ) THEN
                      INSERT INTO usuarios (id_tecnico, username, nombre_completo, password_hash, rol)
                      SELECT %(id_tecnico)s, %(username)s, t.nombre_completo, %(pwd_hash)s, %(rol)s
                      FROM cat_tecnicos t WHERE t.id = %(id_tecnico)s
                      ON CONFLICT (username) DO UPDATE SET
                          password_hash = EXCLUDED.password_hash,
                          rol           = EXCLUDED.rol;
                  END IF;
                END; $$
                """,
                {"id_tecnico": id_tecnico, "username": username, "pwd_hash": pwd_hash, "rol": rol},
            )
        except Exception as exc_u:
            logger.debug("upsert_usuario: tabla 'usuarios' no disponible (%s), ignorado.", exc_u)

    def set_password(self, id_tecnico: int, plain_password: str) -> None:
        """
        Actualiza la contraseña del técnico en cat_tecnicos.
        (La tabla 'usuarios' no existe en este esquema; todo va en cat_tecnicos.)
        """
        pwd_hash = _hash_password(plain_password)
        self._write(
            "UPDATE cat_tecnicos SET password_hash = %s WHERE id = %s",
            (pwd_hash, id_tecnico),
        )
        logger.debug("set_password: contraseña actualizada para id_tecnico=%d", id_tecnico)


# ══════════════════════════════════════════════════════════════════════════════
class CatalogoGenericoRepository(BaseRepository):
    """
    Repositorio genérico para catálogos simples (nombre + descripción).
    Reutilizado por TipoServicio, TipoInstrumento, etc.
    """

    def get_all(self, solo_activos: bool = True) -> list[dict]:
        sql = f"SELECT * FROM {self.TABLE}"
        if solo_activos:
            # Tolera activo IS NULL tratándolos como activos (compatibilidad legacy)
            sql += " WHERE activo IS NOT FALSE"
        sql += " ORDER BY nombre"
        return self._fetch_all(sql)

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            f"SELECT * FROM {self.TABLE} WHERE id = %s", (record_id,)
        )

    def create(self, data: dict) -> dict:
        nombre = (data.get("nombre") or "").strip()
        if not nombre:
            raise ValueError("El nombre es obligatorio.")
        descripcion = (data.get("descripcion") or "").strip()
        if not descripcion:
            descripcion = nombre

        row = self._write(
            f"""
            INSERT INTO {self.TABLE} (nombre, descripcion, activo)
            VALUES (%(nombre)s, %(descripcion)s, TRUE)
            RETURNING *
            """,
            {"nombre": nombre, "descripcion": descripcion},
            returning=True,
        )
        return dict(row) if row else {}

    def update(self, record_id: int, data: dict) -> dict:
        data["id"] = record_id
        if "descripcion" in data and not data["descripcion"]:
            data["descripcion"] = data.get("nombre") or ""
        row = self._write(
            f"""
            UPDATE {self.TABLE} SET nombre = %(nombre)s, descripcion = %(descripcion)s
            WHERE id = %(id)s
            RETURNING *
            """,
            data, returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        result = self._write(
            f"UPDATE {self.TABLE} SET activo = FALSE WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None


class TipoServicioRepository(CatalogoGenericoRepository):
    TABLE = "cat_tipo_servicio"


class TipoInstrumentoRepository(CatalogoGenericoRepository):
    TABLE = "cat_tipo_instrumento"

    def get_all(self, solo_activos: bool = True) -> list[dict]:
        sql = "SELECT id, nombre, descripcion, activo FROM cat_tipo_instrumento"
        if solo_activos:
            sql += " WHERE activo IS NOT FALSE"
        sql += " ORDER BY nombre ASC"
        return self._fetch_all(sql)

    def create(self, data: dict) -> dict:
        nombre = (data.get("nombre") or "").strip()
        if not nombre:
            raise ValueError("El nombre del tipo de instrumento es obligatorio.")
        descripcion = (data.get("descripcion") or "").strip()
        if not descripcion:
            descripcion = nombre  # Opcional: si está vacío, asigna el mismo nombre

        with db_pool.transaction() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO cat_tipo_instrumento (nombre, descripcion, activo)
                    VALUES (%s, %s, true)
                    RETURNING id, nombre, descripcion, activo
                    """,
                    (nombre, descripcion),
                )
                row = cur.fetchone()
            conn.commit()

        logger.info("TipoInstrumentoRepository.create: id=%s nombre=%s", row[0] if row else None, nombre)
        return {"id": row[0], "nombre": row[1], "descripcion": row[2], "activo": row[3]} if row else {}


class ClaseExactitudRepository(BaseRepository):
    """Catálogo fijo de clases de exactitud (solo lectura en producción)."""
    TABLE = "cat_clase_exactitud"

    def get_all(self, **kwargs) -> list[dict]:
        return self._fetch_all(
            "SELECT * FROM cat_clase_exactitud ORDER BY orden_display"
        )

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            "SELECT * FROM cat_clase_exactitud WHERE id = %s", (record_id,)
        )

    def create(self, data: dict) -> dict:
        raise NotImplementedError("Catálogo de clases de exactitud es fijo.")

    def update(self, record_id: int, data: dict) -> dict:
        raise NotImplementedError("Catálogo de clases de exactitud es fijo.")

    def delete(self, record_id: int) -> bool:
        raise NotImplementedError("Catálogo de clases de exactitud es fijo.")



# ══════════════════════════════════════════════════════════════════════════════
class EquipoRepository(BaseRepository):
    """
    CRUD para cat_equipos.
    Clave compuesta: (id_cliente, id_equipo_interno).

    El trigger fn_sync_cat_equipos() actualiza este catálogo automáticamente
    al guardar una OS. EquipoRepository se usa para autocompletar formularios
    y para el registro manual desde Logística.
    """
    TABLE = "cat_equipos"

    def get_all(self, id_cliente: int = None) -> list[dict]:
        """Retorna todos los equipos, opcionalmente filtrados por cliente."""
        if id_cliente is not None:
            return self._fetch_all(
                "SELECT * FROM cat_equipos WHERE id_cliente = %s ORDER BY id_equipo_interno",
                (id_cliente,),
            )
        return self._fetch_all("SELECT * FROM cat_equipos ORDER BY id_cliente, id_equipo_interno")

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one("SELECT * FROM cat_equipos WHERE id = %s", (record_id,))

    def lookup(self, id_cliente: int, id_equipo_interno: str) -> Optional[dict]:
        """
        Busca un equipo por (id_cliente, id_equipo_interno).
        Retorna el dict o None si no existe.
        Llama a la función SQL fn_buscar_equipo_por_cliente para aprovechar el índice GIN.
        """
        row = self._fetch_one(
            "SELECT * FROM fn_buscar_equipo_por_cliente(%s, %s)",
            (id_cliente, id_equipo_interno),
        )
        return dict(row) if row else None

    def ids_de_cliente(self, id_cliente: int) -> list[str]:
        """
        Retorna la lista de id_equipo_interno para el QCompleter.
        Llama a fn_equipos_de_cliente.
        """
        rows = self._fetch_all(
            "SELECT * FROM fn_equipos_de_cliente(%s)", (id_cliente,)
        )
        return [r.get("id_equipo_interno", "") for r in rows if r.get("id_equipo_interno")]

    def upsert(self, id_cliente: int, id_equipo_interno: str, data: dict) -> dict:
        """
        Inserta o actualiza un equipo en el catálogo.
        Retorna el registro resultante.
        Los campos en blanco (None) no sobreescriben valores existentes
        (gracias al COALESCE en el trigger, aquí hacemos lo mismo en Python).
        """
        row = self._write(
            """
            INSERT INTO cat_equipos (
                id_cliente, id_equipo_interno,
                marca, modelo, ns,
                alcance_max, div_minima, ubicacion
            ) VALUES (
                %(id_cliente)s, %(id_equipo_interno)s,
                %(marca)s, %(modelo)s, %(ns)s,
                %(alcance_max)s, %(div_minima)s, %(ubicacion)s
            )
            ON CONFLICT (id_cliente, id_equipo_interno) DO UPDATE SET
                marca      = COALESCE(EXCLUDED.marca,      cat_equipos.marca),
                modelo     = COALESCE(EXCLUDED.modelo,     cat_equipos.modelo),
                ns         = COALESCE(EXCLUDED.ns,         cat_equipos.ns),
                alcance_max= COALESCE(EXCLUDED.alcance_max,cat_equipos.alcance_max),
                div_minima = COALESCE(EXCLUDED.div_minima, cat_equipos.div_minima),
                ubicacion  = COALESCE(EXCLUDED.ubicacion,  cat_equipos.ubicacion),
                updated_at = NOW()
            RETURNING *
            """,
            {
                "id_cliente":          id_cliente,
                "id_equipo_interno":   id_equipo_interno,
                "marca":               data.get("equipo_marca")   or data.get("marca"),
                "modelo":              data.get("equipo_modelo")  or data.get("modelo"),
                "ns":                  data.get("equipo_ns")      or data.get("ns"),
                "alcance_max":         _to_numeric(data.get("equipo_alcance") or data.get("alcance_max")),
                "div_minima":          _to_numeric(data.get("equipo_division") or data.get("div_minima")),
                "ubicacion":           data.get("equipo_ubicacion") or data.get("ubicacion"),
            },
            returning=True,
        )
        return dict(row) if row else {}

    def create(self, data: dict) -> dict:
        return self.upsert(
            data["id_cliente"], data["id_equipo_interno"], data
        )

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE cat_equipos SET
                marca      = %(marca)s,
                modelo     = %(modelo)s,
                ns         = %(ns)s,
                alcance_max= %(alcance_max)s,
                div_minima = %(div_minima)s,
                ubicacion  = %(ubicacion)s,
                updated_at = NOW()
            WHERE id = %(id)s
            RETURNING *
            """,
            {**data, "id": record_id},
            returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        result = self._write(
            "DELETE FROM cat_equipos WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None


def _to_numeric(value) -> Optional[float]:
    """Convierte un string de medida ('500 kg', '50 g') a float, o None."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    import re
    match = re.search(r"[\d.,]+", str(value).replace(",", "."))
    return float(match.group()) if match else None


# ─── Instancias singleton ──────────────────────────────────────────────────────
cliente_repo          = ClienteRepository()
tecnico_repo          = TecnicoRepository()
tipo_servicio_repo    = TipoServicioRepository()
tipo_instrumento_repo = TipoInstrumentoRepository()
clase_exactitud_repo  = ClaseExactitudRepository()
equipo_repo           = EquipoRepository()


# ══════════════════════════════════════════════════════════════════════════════
class SucursalRepository(BaseRepository):
    """
    CRUD para cliente_sucursales.
    Jerarquía: cat_clientes → cliente_sucursales → cliente_equipos.
    """
    TABLE = "cliente_sucursales"

    def get_by_cliente(self, cliente_id: int, solo_activas: bool = True) -> list[dict]:
        """Retorna todas las sucursales/plantas del cliente."""
        sql = "SELECT * FROM cliente_sucursales WHERE cliente_id = %s"
        params: list = [cliente_id]
        if solo_activas:
            sql += " AND activo IS NOT FALSE"
        sql += " ORDER BY nombre_sucursal"
        return self._fetch_all(sql, tuple(params))

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            "SELECT * FROM cliente_sucursales WHERE id = %s", (record_id,)
        )

    def get_all(self, solo_activas: bool = True) -> list[dict]:
        sql = "SELECT cs.*, cc.razon_social FROM cliente_sucursales cs " \
              "JOIN cat_clientes cc ON cc.id = cs.cliente_id"
        if solo_activas:
            sql += " WHERE cs.activo IS NOT FALSE"
        sql += " ORDER BY cc.razon_social, cs.nombre_sucursal"
        return self._fetch_all(sql)

    def create(self, data: dict) -> dict:
        nombre = (data.get("nombre_sucursal") or "").strip()
        direccion = (data.get("direccion") or "").strip()
        cliente_id = data.get("cliente_id")
        if not cliente_id:
            raise ValueError("El ID del cliente es obligatorio para registrar una sucursal.")
        if not nombre:
            raise ValueError("El nombre de la sucursal/planta es obligatorio.")

        row = self._write(
            """
            INSERT INTO cliente_sucursales (
                cliente_id, nombre_sucursal, direccion,
                contacto_nombre, contacto_telefono, activo
            ) VALUES (
                %(cliente_id)s, %(nombre_sucursal)s, %(direccion)s,
                %(contacto_nombre)s, %(contacto_telefono)s, TRUE
            )
            RETURNING *
            """,
            {
                "cliente_id":        cliente_id,
                "nombre_sucursal":   nombre,
                "direccion":         direccion,
                "contacto_nombre":   (data.get("contacto_nombre") or "").strip() or None,
                "contacto_telefono": (data.get("contacto_telefono") or "").strip() or None,
            },
            returning=True,
        )
        if not row or not row.get("id"):
            raise RuntimeError("PostgreSQL no devolvió un ID para la nueva sucursal.")
        logger.info("SucursalRepository.create: id=%s nombre=%s cliente_id=%s", row.get("id"), nombre, cliente_id)
        return dict(row)

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE cliente_sucursales SET
                nombre_sucursal   = %(nombre_sucursal)s,
                direccion         = %(direccion)s,
                contacto_nombre   = %(contacto_nombre)s,
                contacto_telefono = %(contacto_telefono)s
            WHERE id = %(id)s
            RETURNING *
            """,
            {
                "id":                record_id,
                "nombre_sucursal":   data.get("nombre_sucursal", ""),
                "direccion":         data.get("direccion", ""),
                "contacto_nombre":   data.get("contacto_nombre"),
                "contacto_telefono": data.get("contacto_telefono"),
            },
            returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        """Soft delete: desactiva la sucursal."""
        result = self._write(
            "UPDATE cliente_sucursales SET activo = FALSE WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None

    def hard_delete(self, sucursal_id: int) -> bool:
        """
        Eliminación definitiva de la sucursal y todos sus equipos del catálogo.
        No bloquea si hay OS (las OS se vinculan al cliente, no a sucursal).
        """
        from psycopg2.extras import RealDictCursor
        with db_pool.transaction() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    "DELETE FROM cliente_equipos WHERE sucursal_id = %s", (sucursal_id,)
                )
                cur.execute(
                    "DELETE FROM cliente_sucursales WHERE id = %s", (sucursal_id,)
                )
        return True

    def merge(self, canonico_id: int, dup_ids: list) -> dict:
        """
        Fusiona las sucursales duplicadas en la sucursal canónica.
        Mueve los equipos (omitiendo los que ya existen por N/S).
        Las OS no se tocan a nivel de sucursal (no existe FK sucursal en OS).
        Retorna {'equipos_movidos': N, 'equipos_omitidos': M}.
        """
        from psycopg2.extras import RealDictCursor
        stats = {"equipos_movidos": 0, "equipos_omitidos": 0}
        with db_pool.transaction() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                for dup_id in dup_ids:
                    # Obtener equipos del duplicado
                    cur.execute(
                        "SELECT id, numero_serie FROM cliente_equipos WHERE sucursal_id = %s AND activo = TRUE",
                        (dup_id,)
                    )
                    equipos = cur.fetchall()
                    for eq in equipos:
                        # Verificar si ya existe en el canónico
                        cur.execute(
                            "SELECT id FROM cliente_equipos WHERE sucursal_id = %s AND numero_serie = %s",
                            (canonico_id, eq["numero_serie"])
                        )
                        existe = cur.fetchone()
                        if existe:
                            stats["equipos_omitidos"] += 1
                        else:
                            cur.execute(
                                "UPDATE cliente_equipos SET sucursal_id = %s WHERE id = %s",
                                (canonico_id, eq["id"])
                            )
                            stats["equipos_movidos"] += 1
                    # Desactivar el duplicado (no actualiza OS — no existe FK de sucursal en OS)
                    cur.execute(
                        "UPDATE cliente_sucursales SET activo = FALSE WHERE id = %s", (dup_id,)
                    )
        return stats


# ══════════════════════════════════════════════════════════════════════════════
class EquipoSucursalRepository(BaseRepository):
    """
    CRUD para cliente_equipos.
    Clave compuesta única: (sucursal_id, numero_serie).

    Métodos clave:
        get_by_sucursal(sucursal_id)         → lista para el sub-tabla de catálogos.
        lookup_by_serie(sucursal_id, ns)     → busca una báscula por serie.
        upsert_from_os(sucursal_id, data)    → auto-INSERT desde sync push.
    """
    TABLE = "cliente_equipos"

    def get_by_sucursal(self, sucursal_id: int, solo_activos: bool = True) -> list[dict]:
        """Retorna todos los equipos de una sucursal/planta."""
        sql = "SELECT * FROM cliente_equipos WHERE sucursal_id = %s"
        params: list = [sucursal_id]
        if solo_activos:
            sql += " AND activo IS NOT FALSE"
        sql += " ORDER BY id_indicador_equipo, numero_serie"
        return self._fetch_all(sql, tuple(params))

    def get_by_id(self, record_id: int) -> Optional[dict]:
        return self._fetch_one(
            "SELECT * FROM cliente_equipos WHERE id = %s", (record_id,)
        )

    def get_all(self, sucursal_id: int = None) -> list[dict]:
        if sucursal_id is not None:
            return self.get_by_sucursal(sucursal_id)
        return self._fetch_all(
            "SELECT * FROM cliente_equipos ORDER BY sucursal_id, numero_serie"
        )

    def lookup_by_serie(self, sucursal_id: int, numero_serie: str) -> Optional[dict]:
        """Busca un equipo por (sucursal_id, numero_serie). Retorna dict o None."""
        row = self._fetch_one(
            "SELECT * FROM cliente_equipos "
            "WHERE sucursal_id = %s AND numero_serie = %s AND activo IS NOT FALSE",
            (sucursal_id, numero_serie),
        )
        return dict(row) if row else None

    def lookup_by_indicador(self, sucursal_id: int, id_indicador: str) -> Optional[dict]:
        """Busca un equipo por (sucursal_id, id_indicador_equipo)."""
        row = self._fetch_one(
            "SELECT * FROM cliente_equipos "
            "WHERE sucursal_id = %s AND id_indicador_equipo = %s AND activo IS NOT FALSE",
            (sucursal_id, id_indicador),
        )
        return dict(row) if row else None

    def create(self, data: dict) -> dict:
        sucursal_id = data.get("sucursal_id")
        numero_serie = (data.get("numero_serie") or "").strip()
        if not sucursal_id:
            raise ValueError("El ID de la sucursal es obligatorio para registrar un equipo.")
        if not numero_serie:
            raise ValueError("El número de serie es obligatorio.")

        prepared = self._prepare_data(data)
        prepared["sucursal_id"] = sucursal_id
        prepared["numero_serie"] = numero_serie

        row = self._write(
            """
            INSERT INTO cliente_equipos (
                sucursal_id, marca, modelo, numero_serie,
                id_indicador_equipo, ubicacion_interna,
                capacidad_maxima, division_minima, tipo_instrumento,
                activo
            ) VALUES (
                %(sucursal_id)s, %(marca)s, %(modelo)s, %(numero_serie)s,
                %(id_indicador_equipo)s, %(ubicacion_interna)s,
                %(capacidad_maxima)s, %(division_minima)s, %(tipo_instrumento)s,
                TRUE
            )
            RETURNING *
            """,
            prepared,
            returning=True,
        )
        if not row or not row.get("id"):
            raise RuntimeError("PostgreSQL no devolvió un ID para el nuevo equipo.")
        logger.info("EquipoSucursalRepository.create: id=%s serie=%s sucursal_id=%s", row.get("id"), numero_serie, sucursal_id)
        return dict(row)

    def update(self, record_id: int, data: dict) -> dict:
        row = self._write(
            """
            UPDATE cliente_equipos SET
                marca               = %(marca)s,
                modelo              = %(modelo)s,
                numero_serie        = %(numero_serie)s,
                id_indicador_equipo = %(id_indicador_equipo)s,
                ubicacion_interna   = %(ubicacion_interna)s,
                capacidad_maxima    = %(capacidad_maxima)s,
                division_minima     = %(division_minima)s,
                tipo_instrumento    = %(tipo_instrumento)s,
                updated_at          = NOW()
            WHERE id = %(id)s
            RETURNING *
            """,
            {**self._prepare_data(data), "id": record_id},
            returning=True,
        )
        return dict(row) if row else {}

    def delete(self, record_id: int) -> bool:
        """Soft delete: desactiva el equipo."""
        result = self._write(
            "UPDATE cliente_equipos SET activo = FALSE WHERE id = %s RETURNING id",
            (record_id,), returning=True,
        )
        return result is not None

    def hard_delete(self, equipo_id: int) -> bool:
        """
        Eliminación definitiva del equipo del catálogo (cliente_equipos).
        Las OS históricas referencian al equipo por número de serie en texto,
        no por FK — por eso la eliminación del catálogo es segura.
        """
        self._write(
            "DELETE FROM cliente_equipos WHERE id = %s",
            (equipo_id,), returning=False,
        )
        return True

    def upsert_from_os(self, sucursal_id: int, data: dict) -> dict:
        """
        Inserta o actualiza un equipo usando la función SQL fn_upsert_equipo_desde_os.
        Usado por el endpoint sync/push para auto-registrar báscula nueva.
        Retorna el dict del equipo resultante (o {} si falla).
        """
        try:
            row = self._fetch_one(
                """
                SELECT fn_upsert_equipo_desde_os(
                    %s, %s, %s, %s, %s, %s, %s, %s, %s
                ) AS equipo_id
                """,
                (
                    sucursal_id,
                    data.get("numero_serie") or data.get("ns", ""),
                    data.get("marca"),
                    data.get("modelo"),
                    data.get("id_indicador_equipo") or data.get("id_equipo"),
                    data.get("ubicacion_interna") or data.get("ubicacion"),
                    data.get("capacidad_maxima") or data.get("alcance_max"),
                    data.get("division_minima") or data.get("div_minima"),
                    data.get("tipo_instrumento"),
                ),
            )
            if row and row.get("equipo_id"):
                return self.get_by_id(row["equipo_id"]) or {}
        except Exception as exc:
            logger.warning("upsert_from_os: función SQL no disponible (%s), usando INSERT directo.", exc)
            # Fallback: INSERT directo
            try:
                row = self._write(
                    """
                    INSERT INTO cliente_equipos (
                        sucursal_id, marca, modelo, numero_serie,
                        id_indicador_equipo, ubicacion_interna,
                        capacidad_maxima, division_minima, tipo_instrumento
                    ) VALUES (
                        %(sucursal_id)s, %(marca)s, %(modelo)s, %(numero_serie)s,
                        %(id_indicador_equipo)s, %(ubicacion_interna)s,
                        %(capacidad_maxima)s, %(division_minima)s, %(tipo_instrumento)s
                    )
                    ON CONFLICT (sucursal_id, numero_serie) DO UPDATE SET
                        marca               = COALESCE(EXCLUDED.marca,               cliente_equipos.marca),
                        modelo              = COALESCE(EXCLUDED.modelo,              cliente_equipos.modelo),
                        id_indicador_equipo = COALESCE(EXCLUDED.id_indicador_equipo, cliente_equipos.id_indicador_equipo),
                        ubicacion_interna   = COALESCE(EXCLUDED.ubicacion_interna,   cliente_equipos.ubicacion_interna),
                        capacidad_maxima    = COALESCE(EXCLUDED.capacidad_maxima,    cliente_equipos.capacidad_maxima),
                        division_minima     = COALESCE(EXCLUDED.division_minima,     cliente_equipos.division_minima),
                        tipo_instrumento    = COALESCE(EXCLUDED.tipo_instrumento,    cliente_equipos.tipo_instrumento),
                        updated_at          = NOW()
                    RETURNING *
                    """,
                    {
                        "sucursal_id":         sucursal_id,
                        "marca":               data.get("marca"),
                        "modelo":              data.get("modelo"),
                        "numero_serie":        data.get("numero_serie") or data.get("ns", ""),
                        "id_indicador_equipo": data.get("id_indicador_equipo") or data.get("id_equipo"),
                        "ubicacion_interna":   data.get("ubicacion_interna") or data.get("ubicacion"),
                        "capacidad_maxima":    str(data.get("capacidad_maxima") or data.get("alcance_max") or ""),
                        "division_minima":     str(data.get("division_minima") or data.get("div_minima") or ""),
                        "tipo_instrumento":    data.get("tipo_instrumento"),
                    },
                    returning=True,
                )
                return dict(row) if row else {}
            except Exception as exc2:
                logger.error("upsert_from_os fallback también falló: %s", exc2)
        return {}

    @staticmethod
    def _prepare_data(data: dict) -> dict:
        return {
            "sucursal_id":         data.get("sucursal_id"),
            "marca":               data.get("marca") or None,
            "modelo":              data.get("modelo") or None,
            "numero_serie":        data.get("numero_serie", ""),
            "id_indicador_equipo": data.get("id_indicador_equipo") or None,
            "ubicacion_interna":   data.get("ubicacion_interna") or None,
            "capacidad_maxima":    data.get("capacidad_maxima") or None,
            "division_minima":     data.get("division_minima") or None,
            "tipo_instrumento":    data.get("tipo_instrumento") or None,
        }


# ─── Singletons adicionales (v13) ─────────────────────────────────────────────
sucursal_repo      = SucursalRepository()
equipo_sucursal_repo = EquipoSucursalRepository()

