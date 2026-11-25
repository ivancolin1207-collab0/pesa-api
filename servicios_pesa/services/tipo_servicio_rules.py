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

    @property
    def pide_dve(self) -> bool:
        """True si el servicio requiere Número DVE / División de Verificación."""
        return self.pide_holograma_anterior

    @property
    def pide_inicial_jia(self) -> bool:
        """True si requiere Inicial J/I/A del calibrador."""
        return self.pide_cca


# ── Tabla de reglas por ID de tipo de servicio (PostgreSQL cat_tipo_servicio) ─
# Priorizamos el nombre normalizado mediante get_rules_by_nombre_o_id().
_RULES: dict[int, ServiceRules] = {
    1: ServiceRules(
        tipo_servicio_id=1,
        nombre="Calibración",
        pide_cca=True,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
    2: ServiceRules(
        tipo_servicio_id=2,
        nombre="Ajuste",
        pide_cca=False,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
    3: ServiceRules(
        tipo_servicio_id=3,
        nombre="Inspección",
        pide_cca=False,
        pide_holograma_anterior=True,
        pide_holograma_actualizado=True,
    ),
    4: ServiceRules(
        tipo_servicio_id=4,
        nombre="Calibración + Ajuste",
        pide_cca=True,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
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
    8: ServiceRules(
        tipo_servicio_id=8,
        nombre="Entrega Refacciones",
        pide_cca=False,
        pide_holograma_anterior=False,
        pide_holograma_actualizado=False,
    ),
}

# Reglas por defecto fail-closed: si el tipo es desconocido/Ajuste no pide CCA ni DVE/Hologramas
_DEFAULT_RULES = ServiceRules(
    tipo_servicio_id=0,
    nombre="Ajuste",
    pide_cca=False,
    pide_holograma_anterior=False,
    pide_holograma_actualizado=False,
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

def get_rules(id_tipo_servicio: Optional[int], nombre_tipo: Optional[str] = None,
              folio: Optional[str] = None) -> ServiceRules:
    """
    Retorna las reglas de negocio estrictas dando prioridad al nombre/folio
    normalizado y usando id_tipo_servicio como respaldo fail-closed.
    """
    if nombre_tipo or folio:
        return get_rules_by_nombre_o_id(nombre=nombre_tipo, id_tipo=id_tipo_servicio, folio=folio)
    if id_tipo_servicio is None:
        return _DEFAULT_RULES
    try:
        return _RULES.get(int(id_tipo_servicio), _DEFAULT_RULES)
    except (TypeError, ValueError):
        return _DEFAULT_RULES


def get_rules_by_nombre(nombre_tipo: str) -> ServiceRules:
    """
    Retorna las reglas evaluando por palabras clave normalizadas (sin tildes ni mayúsculas):
      - CCA/Calibración: 'calibraci' o word 'cca'
      - DVE/Hologramas: 'inspecc', 'verifica' o word 'dve'
    """
    return get_rules_by_nombre_o_id(nombre=nombre_tipo)


def get_rules_by_nombre_o_id(
    nombre: Optional[str] = None,
    id_tipo: Optional[int] = None,
    folio: Optional[str] = None,
) -> ServiceRules:
    """Resuelve ServiceRules unificado por folio -> nombre -> id_tipo -> fail-closed."""
    fmt, cca, dve, _aju = _clasificar(nombre, id_tipo, folio)
    if fmt in ("rma", "re", "osob", "osocc"):
        return ServiceRules(
            tipo_servicio_id=int(id_tipo or 0),
            nombre=str(nombre or fmt.upper()),
            pide_cca=False,
            pide_holograma_anterior=False,
            pide_holograma_actualizado=False,
        )
    if fmt == "sin":
        if id_tipo is not None:
            try:
                return _RULES.get(int(id_tipo), _DEFAULT_RULES)
            except (TypeError, ValueError):
                pass
        return _DEFAULT_RULES
    return ServiceRules(
        tipo_servicio_id=int(id_tipo or 0),
        nombre=str(nombre or _ID_A_NOMBRE_BD.get(int(id_tipo or 0), "Ajuste")),
        pide_cca=cca,
        pide_holograma_anterior=dve,
        pide_holograma_actualizado=dve,
    )


def servicio_incluye_calibracion(nombre: Optional[str] = None, id_tipo: Optional[int] = None,
                                 folio: Optional[str] = None) -> bool:
    return get_rules_by_nombre_o_id(nombre=nombre, id_tipo=id_tipo, folio=folio).pide_cca


def servicio_incluye_inspeccion(nombre: Optional[str] = None, id_tipo: Optional[int] = None,
                                folio: Optional[str] = None) -> bool:
    return get_rules_by_nombre_o_id(nombre=nombre, id_tipo=id_tipo, folio=folio).pide_dve


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


# ── Etiquetas homologadas (Dashboard tablet / escritorio) ─────────────────────
# Clasificación por NOMBRE real (igual que pesa_flutter/lib/services/
# tipo_servicio_rules.dart → _resolveByName). El nombre manda sobre el ID.

def _norm(s: str) -> str:
    s = (s or "").strip().lower()
    for a, b in (("á", "a"), ("é", "e"), ("í", "i"), ("ó", "o"), ("ú", "u"), ("ü", "u"), ("ñ", "n")):
        s = s.replace(a, b)
    return s


_ID_A_NOMBRE_BD = {
    1: "Calibración", 2: "Ajuste", 3: "Inspección", 4: "Calibración + Ajuste",
    5: "Calibración + Inspección", 6: "Ajuste + Inspección",
    7: "Calibración + Ajuste + Inspección", 8: "Entrega Refacciones",
}


def _clasificar(nombre: Optional[str], id_tipo: Optional[int] = None,
                folio: Optional[str] = None) -> tuple[str, bool, bool, bool]:
    """Retorna (formato, cca, dve, ajuste). formato: 'os' | 'osob' | 'osocc' | 'rma' | 're' | 'sin'."""
    import re
    f = (folio or "").strip().upper()
    if f.startswith("OSOCC-"):
        return "osocc", False, False, False
    if f.startswith("OSOB-"):
        return "osob", False, False, False
    if f.startswith("RMA-"):
        return "rma", False, False, False
    if f.startswith("RE-"):
        return "re", False, False, False
    n = _norm(nombre or "")
    if not n and id_tipo:
        try:
            n = _norm(_ID_A_NOMBRE_BD.get(int(id_tipo), ""))
        except (TypeError, ValueError):
            n = ""
    if not n:
        return "sin", False, False, False
    if "osocc" in n or ("observacion" in n and "celda" in n) or ("diagnostico" in n and "celda" in n):
        return "osocc", False, False, False
    if "osob" in n or "observacion" in n or ("inspeccion" in n and "revisi" in n and "bascula" in n):
        return "osob", False, False, False
    if "refacci" in n or "remisi" in n:
        return "rma", False, False, False
    if "revisi" in n or "celda" in n:
        return "re", False, False, False
    cca = "calibra" in n or bool(re.search(r"\bcca\b", n))
    dve = bool(re.search(r"\bdve\b", n)) or "inspecc" in n or "verifica" in n
    aju = "ajuste" in n or "mantenim" in n
    return "os", cca, dve, aju


def etiqueta_corta(nombre: Optional[str], id_tipo: Optional[int] = None,
                   folio: Optional[str] = None) -> str:
    """Calibración + Ajuste + Inspección · Ajuste + Inspección · Calibración + Ajuste · Ajuste
    (CCA = Calibración, DVE = Inspección). También Observaciones · Observaciones Celda · Remisión · Revisión · Sin tipo."""
    fmt, cca, dve, aju = _clasificar(nombre, id_tipo, folio)
    if fmt == "osocc":
        return "Observaciones Celda"
    if fmt == "osob":
        return "Observaciones"
    if fmt == "rma":
        return "Remisión"
    if fmt == "re":
        return "Revisión"
    if fmt == "sin":
        return "Sin tipo"
    partes = []
    if cca:
        partes.append("Calibración")
    if aju or (not cca and not dve):
        partes.append("Ajuste")
    if dve:
        partes.append("Inspección")
    return " + ".join(partes)


def etiqueta_larga(nombre: Optional[str], id_tipo: Optional[int] = None,
                   folio: Optional[str] = None) -> str:
    """Descripción para tooltips / banners (misma redacción que la tablet)."""
    fmt, cca, dve, aju = _clasificar(nombre, id_tipo, folio)
    if fmt == "osocc":
        return "Formato de Diagnóstico y Revisión de Celda de Carga (OSOCC)"
    if fmt == "osob":
        return "Formato de Inspección y Revisión de Básculas (OSOB)"
    if fmt == "rma":
        return "Remisión — sin CCA ni DVE"
    if fmt == "re":
        return "Revisión de Celdas — sin CCA ni DVE"
    if fmt == "sin":
        return "Tipo de servicio no asignado"
    corta = etiqueta_corta(nombre, id_tipo, folio)
    if cca and dve:
        return f"{corta} (CCA + DVE)"
    if cca:
        return f"{corta} (CCA)"
    if dve:
        return f"{corta} (DVE)"
    return "Ajuste — sin CCA ni DVE"
