"""
tipo_servicio_rules.py — Reglas de negocio por tipo de servicio metrológico
Servicios PESA v2.3

Define qué campos son obligatorios / visibles según el tipo de servicio
seleccionado en una Orden de Servicio.

Base normativa: NOM-010-SCFI-2020 y requisitos de acreditación EMA.

Matriz de reglas (basada en cat_tipo_servicio):
  ID | Nombre                             | CCA | Holo Ant. | Holo Act.
  ---|------------------------------------|-----|-----------|----------
   1 | Calibración                        |  ✅ |     ❌    |     ❌
   2 | Ajuste                             |  ❌ |     ❌    |     ❌
   3 | Inspección                         |  ❌ |     ✅    |     ✅
   4 | Calibración + Ajuste               |  ✅ |     ❌    |     ❌
   5 | Calibración + Inspección           |  ✅ |     ✅    |     ✅
   6 | Ajuste + Inspección                |  ❌ |     ✅    |     ✅
   7 | Calibración + Ajuste + Inspección  |  ✅ |     ✅    |     ✅

Regla CCA e Inicial J/I/A (NOM-010-SCFI-2020):
  El Número de Certificado de Calibración Acreditado (CCA) y la inicial
  del calibrador (J, I o A) son OBLIGATORIOS únicamente cuando el servicio
  incluye componente de Calibración. Para servicios de Ajuste o Inspección
  puros, estos campos deben omitirse completamente en el PDF y en la Tablet.

Uso:
    from services.tipo_servicio_rules import get_rules, pide_cca, pide_inicial_jia

    rules = get_rules(id_tipo_servicio=4)
    # rules = ServiceRules(pide_cca=True, pide_holograma_anterior=False, ...)

    if pide_cca(4):
        # mostrar campo Número CCA
        ...

    if pide_inicial_jia(6):  # False — Ajuste + Inspección puro
        # mostrar casillas J / I / A
        ...
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class ServiceRules:
    """Reglas de campos para un tipo de servicio dado."""
    tipo_servicio_id:          int
    nombre:                    str
    pide_cca:                  bool   # Número de CCA / Certificado de Calibración Acreditado
    pide_holograma_anterior:   bool   # Número de holograma que se retira
    pide_holograma_actualizado: bool  # Número de holograma nuevo que se coloca

    @property
    def tiene_calibracion(self) -> bool:
        return self.pide_cca

    @property
    def tiene_inspeccion(self) -> bool:
        """True si el servicio incluye componente de Inspección (implica hologramas)."""
        return self.pide_holograma_anterior  # Las dos van juntas siempre

    @property
    def tiene_ajuste(self) -> bool:
        """True si el servicio incluye componente de Ajuste."""
        return self.tipo_servicio_id not in (1, 3)

    @property
    def requiere_signatario_ema(self) -> bool:
        """True si el servicio requiere un técnico con acreditación EMA para el CCA."""
        return self.pide_cca


# ── Tabla de reglas por ID de tipo de servicio ────────────────────────────────
# Los IDs 1-4 corresponden a cat_tipo_servicio en PostgreSQL y al fallback del UI:
#   1 = Ajuste
#   2 = Ajuste e Inspección
#   3 = Ajuste y Calibración
#   4 = Ajuste, Calibración e Inspección
#
#  Matriz de campos:
#   ID | Nombre                             | CCA | Holo Ant. | Holo Act.
#   ---|------------------------------------|-----|-----------|----------
#    1 | Ajuste                             |  ❌ |     ❌    |     ❌
#    2 | Ajuste e Inspección                |  ❌ |     ✅    |     ✅
#    3 | Ajuste y Calibración               |  ✅ |     ❌    |     ❌
#    4 | Ajuste, Calibración e Inspección   |  ✅ |     ✅    |     ✅
_RULES: dict[int, ServiceRules] = {
    # ── IDs canónicos del negocio (usados por el batch_generator y BD) ──
    1: ServiceRules(
        tipo_servicio_id=1,
        nombre="Ajuste",
        pide_cca=False,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
    2: ServiceRules(
        tipo_servicio_id=2,
        nombre="Ajuste e Inspección",
        pide_cca=False,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
    3: ServiceRules(
        tipo_servicio_id=3,
        nombre="Ajuste y Calibración",
        pide_cca=True,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
    4: ServiceRules(
        tipo_servicio_id=4,
        nombre="Ajuste, Calibración e Inspección",
        pide_cca=True,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
    # ── Aliases históricos (IDs del esquema anterior) ────────────────────
    5: ServiceRules(
        tipo_servicio_id=5,
        nombre="Calibración + Inspección",
        pide_cca=True,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
    6: ServiceRules(
        tipo_servicio_id=6,
        nombre="Ajuste + Inspección",
        pide_cca=False,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
    7: ServiceRules(
        tipo_servicio_id=7,
        nombre="Calibración + Ajuste + Inspección",
        pide_cca=True,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
}

# Reglas por defecto si el tipo no está registrado (más permisivo: muestra todo)
_DEFAULT_RULES = ServiceRules(
    tipo_servicio_id=0,
    nombre="(desconocido)",
    pide_cca=True,
    pide_holograma_anterior=True,
    pide_holograma_actualizado=True,
)

# IDs de tipos que incluyen componente de calibración (para filtros RBAC Calibrador)
IDS_CON_CALIBRACION: frozenset[int] = frozenset(
    r.tipo_servicio_id for r in _RULES.values() if r.tiene_calibracion
)  # {1, 4, 5, 7}

# IDs de tipos que incluyen componente de inspección (para filtros RBAC Inspector)
IDS_CON_INSPECCION: frozenset[int] = frozenset(
    r.tipo_servicio_id for r in _RULES.values() if r.tiene_inspeccion
)  # {3, 5, 6, 7}


# ── API pública ───────────────────────────────────────────────────────────────

def get_rules(id_tipo_servicio: Optional[int]) -> ServiceRules:
    """
    Retorna las reglas de negocio para el tipo de servicio indicado.
    Si el ID no existe en el mapa (None o desconocido), retorna _DEFAULT_RULES
    que muestra todos los campos (comportamiento más permisivo).
    """
    if id_tipo_servicio is None:
        return _DEFAULT_RULES
    return _RULES.get(int(id_tipo_servicio), _DEFAULT_RULES)


def get_rules_by_nombre(nombre_tipo: str) -> ServiceRules:
    """
    Retorna las reglas buscando por el nombre del tipo de servicio.
    Búsqueda case-insensitive. Retorna _DEFAULT_RULES si no hay coincidencia.

    Ejemplo:
        rules = get_rules_by_nombre("Ajuste + Inspección")
        # → ServiceRules(pide_cca=False, pide_holograma_anterior=True, ...)
    """
    nombre_lower = (nombre_tipo or "").strip().lower()
    for rule in _RULES.values():
        if rule.nombre.lower() == nombre_lower:
            return rule
    return _DEFAULT_RULES


def pide_cca(id_tipo_servicio: Optional[int]) -> bool:
    """True si el tipo de servicio requiere capturar el Número de CCA."""
    return get_rules(id_tipo_servicio).pide_cca


def pide_holograma_anterior(id_tipo_servicio: Optional[int]) -> bool:
    """True si el tipo de servicio requiere registrar el holograma anterior."""
    return get_rules(id_tipo_servicio).pide_holograma_anterior


def pide_holograma_actualizado(id_tipo_servicio: Optional[int]) -> bool:
    """True si el tipo de servicio requiere registrar el holograma nuevo."""
    return get_rules(id_tipo_servicio).pide_holograma_actualizado


def pide_inicial_jia(id_tipo_servicio: Optional[int]) -> bool:
    """
    True si el tipo de servicio requiere capturar la Inicial del Calibrador
    (casillas J / I / A en la Ficha Técnica del Instrumento).

    Es un alias semántico de pide_cca() conforme a NOM-010-SCFI-2020:
    la inicial del calibrador y el Número CCA son co-dependientes —
    ambos aparecen si y solo si el servicio incluye Calibración.

    Uso en PDF y Tablet:
        if pide_inicial_jia(tipo_id):
            # mostrar casillas [ ] J  [ ] I  [ ] A
        else:
            # omitir la fila J/I/A y ajustar espacio vertical
    """
    return get_rules(id_tipo_servicio).pide_cca


def campos_equipo_visibles(id_tipo_servicio: Optional[int]) -> dict[str, bool]:
    """
    Retorna un dict con la visibilidad de cada campo de la sección 'Datos del Equipo'
    en el PDF y en los formularios digitales.

    Ejemplo:
        campos = campos_equipo_visibles(4)
        # {'cca': True, 'holograma_anterior': False, 'holograma_actualizado': False}
    """
    rules = get_rules(id_tipo_servicio)
    return {
        "cca":                  rules.pide_cca,
        "holograma_anterior":   rules.pide_holograma_anterior,
        "holograma_actualizado": rules.pide_holograma_actualizado,
    }


def get_all_rules() -> dict[int, ServiceRules]:
    """Retorna la tabla completa de reglas (útil para depuración / tests)."""
    return dict(_RULES)
