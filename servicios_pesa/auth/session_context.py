"""
session_context.py — Contexto de sesión global RBAC para Servicios PESA v3.0

Soporte multi-rol: un usuario puede tener múltiples perfiles simultáneos.
Los permisos y módulos de navegación se calculan como la UNIÓN de todos los roles.

Uso:
    from auth.session_context import session

    # Después del login con un solo rol:
    session.set(user_id=1, username="ana", nombre_completo="Ana López",
                roles=["Técnico", "Técnico Calibrador"])

    # En cualquier widget:
    if session.has_role('logistica'):
        ...
    if session.can('crear_os'):
        ...
    print(session.roles)      # ['servicio']  — lista interna normalizada
    print(session.role)       # 'servicio'    — rol principal (primero de la lista)
"""
from __future__ import annotations
from datetime import datetime
from typing import Optional, Union


# ─── Mapa de normalización: strings de BD → claves internas ──────────────────
_ROLE_NORMALIZE: dict[str, str] = {
    # BD → clave interna RBAC
    "administrador":        "admin",
    "admin":                "admin",
    "logistica":            "logistica",
    "logística":            "logistica",
    "logistico":            "logistica",
    "recepcion":            "recepcion",
    "recepción":            "recepcion",
    "tecnico":              "servicio",
    "técnico":              "servicio",
    # Roles especializados — MANTIENEN su propia clave interna
    # para poder diferenciar permisos de vista de OS calibración/inspección
    "tecnico calibrador":   "calibrador",
    "técnico calibrador":   "calibrador",
    "tecnico inspector":    "inspector",
    "técnico inspector":    "inspector",
    "calibrador":           "calibrador",
    "inspector":            "inspector",
    "servicio":             "servicio",
}


def normalize_role(raw: str) -> str:
    """
    Convierte el string de rol tal como viene de la BD o del formulario
    al identificador interno del sistema RBAC.

    Ejemplos:
        "Administrador" → "admin"
        "Logística"     → "logistica"
        "Técnico"       → "servicio"
        "Recepción"     → "recepcion"

    Si no reconoce el valor, retorna "servicio" como rol más restrictivo.
    """
    key = raw.strip().lower()
    return _ROLE_NORMALIZE.get(key, "servicio")


# ─── Permisos por rol ─────────────────────────────────────────────────────────
# Define qué operaciones puede hacer cada rol.
# Las claves son strings de permiso usados en session.can(...)
_ROLE_PERMISSIONS: dict[str, set[str]] = {
    "admin": {
        # Acceso total
        "ver_dashboard",
        "crear_os", "editar_os", "cancelar_os", "ver_todas_os",
        "crear_rma", "editar_rma", "cancelar_rma", "ver_todas_rma",
        "crear_re", "editar_re", "cancelar_re", "ver_todas_re",
        "adjuntar_escaneo", "descargar_escaneo",
        "ver_catalogos", "editar_catalogos",
        "ver_usuarios", "crear_usuarios", "editar_usuarios",
        "ver_entrega_semanal", "validar_entrega_semanal",
        "ver_reportes", "exportar_reportes",
        "configuracion",
        "ver_firmas_digitales",
        "asignar_tecnico",
        "modo_fisico", "modo_digital",
    },
    "logistica": {
        "ver_dashboard",
        "crear_os", "editar_os", "ver_todas_os",
        "crear_rma", "editar_rma", "ver_todas_rma",
        "crear_re", "editar_re", "ver_todas_re",
        "adjuntar_escaneo", "descargar_escaneo",
        "asignar_tecnico",
        "modo_fisico", "modo_digital",
        "ver_entrega_semanal",
        "ver_catalogos",
        "ver_reportes",
    },
    "servicio": {
        # Técnico de campo: ve sus propias OS asignadas
        "ver_dashboard",
        "ver_os_propias", "editar_os_propias",
        "ver_rma_propias",
        "ver_re_propias",
        "adjuntar_escaneo",
        "ver_firmas_digitales",
        "generar_entrega_semanal",
    },
    "calibrador": {
        # Técnico Calibrador: ve sus OS propias + OS de Calibración completadas
        # que le corresponden para iniciar la etapa de laboratorio
        "ver_dashboard",
        "ver_os_propias", "editar_os_propias",
        "ver_rma_propias",
        "adjuntar_escaneo",
        "ver_firmas_digitales",
        "generar_entrega_semanal",
        "ver_os_calibracion",          # permiso especial: OS de calibración completadas
        "descargar_escaneo",           # puede descargar el PDF de la OS finalizada
    },
    "inspector": {
        # Técnico Inspector: ve sus OS propias + OS con componente de Inspección
        "ver_dashboard",
        "ver_os_propias", "editar_os_propias",
        "ver_rma_propias",
        "adjuntar_escaneo",
        "ver_firmas_digitales",
        "generar_entrega_semanal",
        "ver_os_inspeccion",           # permiso especial: OS con inspección completadas
        "descargar_escaneo",           # puede descargar el PDF para emitir dictamen
    },
    "recepcion": {
        "ver_dashboard",
        "ver_todas_os",    # Solo lectura de estado
        "ver_entrega_semanal",
        "validar_entrega_semanal",
        "ver_catalogos",
    },
}

# ─── Ítems de navegación por rol ─────────────────────────────────────────────
_ROLE_NAV: dict[str, list[str]] = {
    "admin": [
        "dashboard", "lote", "buscar_os",
        "escaneos", "catalogos", "entrega_semanal", "configuracion",
    ],
    "logistica": [
        "dashboard", "lote", "buscar_os",
        "escaneos", "entrega_semanal",
    ],
    "servicio": [
        "dashboard", "buscar_os", "escaneos", "entrega_semanal",
    ],
    # Calibrador: mismo menú que técnico + acceso a buscar OS (para ver calibraciones)
    "calibrador": [
        "dashboard", "buscar_os", "escaneos", "entrega_semanal",
    ],
    # Inspector: mismo menú que técnico + acceso a buscar OS (para ver inspecciones)
    "inspector": [
        "dashboard", "buscar_os", "escaneos", "entrega_semanal",
    ],
    "recepcion": [
        "dashboard", "buscar_os", "entrega_semanal",
    ],
}


# ══════════════════════════════════════════════════════════════════════════════
class SessionContext:
    """
    Singleton que mantiene el estado de la sesión del usuario activo.
    Soporta múltiples roles simultáneos: los permisos son la UNIÓN de todos.

    Atributos públicos (solo lectura):
        user_id          (int)
        username         (str)
        nombre_completo  (str)
        role             (str)       — rol principal (primero de la lista)
        roles            (list[str]) — lista completa de roles internos normalizados
        id_tecnico       (int | None)
        logged_in_at     (datetime | None)
        is_authenticated (bool)
    """

    _instance: Optional["SessionContext"] = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._reset()
        return cls._instance

    def _reset(self) -> None:
        self._user_id:         Optional[int]      = None
        self._username:        str                = ""
        self._nombre_completo: str                = ""
        self._roles:           list[str]          = []   # roles internos normalizados
        self._id_tecnico:      Optional[int]      = None
        self._jwt_token:       Optional[str]      = None
        self._refresh_token:   Optional[str]      = None
        self._logged_in_at:    Optional[datetime] = None
        self._permissions:     set[str]           = set()

    # ── Setters / Auth ────────────────────────────────────────────────────────

    def set(
        self,
        user_id:         int,
        username:        str,
        nombre_completo: str,
        roles:           Union[list[str], str, None] = None,
        role:            Optional[str]               = None,
        id_tecnico:      Optional[int]               = None,
        jwt_token:       Optional[str]               = None,
        refresh_token:   Optional[str]               = None,
    ) -> None:
        """
        Inicializa la sesión tras login exitoso.

        Acepta roles como:
          - lista: ["Logística", "Técnico"] o ["logistica", "servicio"]
          - string único: "Administrador" o "admin"
          - parámetro `role` (backward compat): igual que un string único

        Los strings se normalizan automáticamente a claves internas.
        Los permisos de navegación son la UNIÓN de todos los roles asignados.

        Args:
            user_id:         ID del técnico en cat_tecnicos.
            username:        Nombre de usuario (login).
            nombre_completo: Nombre completo para mostrar en la UI.
            roles:           Lista o string de rol(es).
            role:            Alias singular para retrocompatibilidad.
            id_tecnico:      ID en cat_tecnicos.
            jwt_token:       Access token JWT.
            refresh_token:   Refresh token JWT.
        """
        # Resolver el argumento de roles (acepta list, str o keyword `role`)
        raw_roles: list[str] = []
        if roles is not None:
            raw_roles = [roles] if isinstance(roles, str) else list(roles)
        elif role is not None:
            raw_roles = [role]

        if not raw_roles:
            raw_roles = ["servicio"]  # fallback más restrictivo

        # Normalizar cada rol al identificador interno
        normalized = [normalize_role(r) for r in raw_roles]
        # Eliminar duplicados manteniendo orden
        seen: set[str] = set()
        self._roles = [r for r in normalized if not (r in seen or seen.add(r))]  # type: ignore[func-returns-value]

        self._user_id         = user_id
        self._username        = username
        self._nombre_completo = nombre_completo
        self._id_tecnico      = id_tecnico
        self._jwt_token       = jwt_token
        self._refresh_token   = refresh_token
        self._logged_in_at    = datetime.now()

        # Permisos = unión de todos los roles asignados
        self._permissions = set()
        for r in self._roles:
            self._permissions |= _ROLE_PERMISSIONS.get(r, set())

    def logout(self) -> None:
        """Cierra la sesión y borra todos los datos del contexto."""
        self._reset()

    def update_tokens(self, jwt_token: str, refresh_token: Optional[str] = None) -> None:
        """Actualiza los tokens JWT sin cerrar sesión (refresh flow)."""
        self._jwt_token = jwt_token
        if refresh_token:
            self._refresh_token = refresh_token

    # ── Getters ───────────────────────────────────────────────────────────────

    @property
    def is_authenticated(self) -> bool:
        return self._user_id is not None

    @property
    def user_id(self) -> Optional[int]:
        return self._user_id

    @property
    def username(self) -> str:
        return self._username

    @property
    def nombre_completo(self) -> str:
        return self._nombre_completo

    @property
    def role(self) -> str:
        """Rol principal (primero de la lista). Para backward compat y UI."""
        return self._roles[0] if self._roles else ""

    @property
    def roles(self) -> list[str]:
        """Lista completa de roles internos normalizados."""
        return list(self._roles)

    @property
    def id_tecnico(self) -> Optional[int]:
        return self._id_tecnico

    @property
    def jwt_token(self) -> Optional[str]:
        return self._jwt_token

    @property
    def refresh_token(self) -> Optional[str]:
        return self._refresh_token

    @property
    def logged_in_at(self) -> Optional[datetime]:
        return self._logged_in_at

    # ── RBAC ─────────────────────────────────────────────────────────────────

    def has_role(self, *roles: str) -> bool:
        """
        Retorna True si alguno de los roles del usuario coincide con los indicados.
        Acepta tanto claves internas ('admin') como strings de BD ('Administrador').
        """
        normalized_check = {normalize_role(r) for r in roles}
        return bool(set(self._roles) & normalized_check)

    def can(self, permission: str) -> bool:
        """
        Retorna True si el usuario activo tiene el permiso indicado.
        Se evalúa sobre la UNIÓN de permisos de todos sus roles.

        Ejemplo:
            if session.can('crear_os'):
                btn_nueva_os.setEnabled(True)
        """
        return permission in self._permissions

    def require_role(self, *roles: str) -> None:
        """
        Lanza PermissionError si el usuario NO tiene ninguno de los roles indicados.
        Útil en métodos de backend para doble validación.
        """
        if not self.has_role(*roles):
            raise PermissionError(
                f"Acceso denegado: se requiere uno de los roles {roles}, "
                f"pero el usuario '{self._username}' tiene roles {self._roles}"
            )

    def require_permission(self, permission: str) -> None:
        """Lanza PermissionError si el usuario no tiene el permiso."""
        if not self.can(permission):
            raise PermissionError(
                f"Acceso denegado: permiso requerido '{permission}' "
                f"no disponible para roles {self._roles}"
            )

    # ── Utilidades ────────────────────────────────────────────────────────────

    def nav_items_allowed(self) -> list[str]:
        """
        Retorna la lista de claves de navegación permitidas para el usuario activo.
        Es la UNIÓN de todos los ítems de navegación de todos sus roles,
        manteniendo el orden de aparición (primero los del rol principal).
        Usada por MainWindow para filtrar el sidebar.
        """
        seen: set[str] = set()
        result: list[str] = []
        for r in self._roles:
            for item in _ROLE_NAV.get(r, []):
                if item not in seen:
                    seen.add(item)
                    result.append(item)
        return result

    def __repr__(self) -> str:
        if not self.is_authenticated:
            return "<SessionContext: sin sesión>"
        return (
            f"<SessionContext: usuario={self._username!r} "
            f"roles={self._roles!r} "
            f"autenticado={self.is_authenticated}>"
        )


# ─── Instancia singleton global ────────────────────────────────────────────────
session = SessionContext()
