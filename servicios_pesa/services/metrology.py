"""
services/metrology.py — Utilidades metrológicas OIML R 76 / NOM-010-SCFI
Servicios PESA v2.5

Funciones compartidas entre captura_digital_dialog y batch_generator_widget:
    • decimals_from_d  — calcula decimales exactos desde la división mínima d
    • fmt              — formatea un valor numérico con la resolución de d
    • fmt_patron       — formatea el valor patrón sin ceros sobrantes
    • calc_emt         — calcula el Error Máximo Tolerado (EMT) según OIML R 76
"""
from __future__ import annotations
import math
import re


# ──────────────────────────────────────────────────────────────────────────────
# HELPERS DE CONVERSIÓN
# ──────────────────────────────────────────────────────────────────────────────

def parse_d(text: str) -> float | None:
    """
    Extrae el valor numérico de una cadena de texto de división mínima.

    Ejemplos:
        "0.001"     → 0.001
        "0.001 kg"  → 0.001
        "50 g"      → 0.05   (convierte g → kg automáticamente)
        "1 lb"      → None   (unidad desconocida)
    """
    if not text:
        return None
    text = text.strip()

    # Buscar número (entero o decimal)
    m = re.search(r'[\d]+(?:[.,][\d]+)?', text)
    if not m:
        return None

    valor_str = m.group(0).replace(',', '.')
    try:
        valor = float(valor_str)
    except ValueError:
        return None

    # Detectar unidad
    unidad = text[m.end():].strip().lower()
    if 'g' in unidad and 'k' not in unidad:
        valor = valor / 1000.0   # gramos → kilogramos
    elif 'lb' in unidad or 'lbf' in unidad:
        return None  # libras no soportadas aquí

    return valor if valor > 0 else None


def decimals_from_d(d: float) -> int:
    """
    Calcula el número de decimales necesarios para representar el valor de d.

    Regla: contar los decimales del número d.
        d = 1       → 0 decimales  (ej. 20, 21)
        d = 0.1     → 1 decimal    (ej. 5.1)
        d = 0.01    → 2 decimales  (ej. 5.01)
        d = 0.001   → 3 decimales  (ej. 5.001)
        d = 0.0001  → 4 decimales  (ej. 5.0001)
    """
    if d <= 0:
        return 4  # fallback seguro
    if d >= 1:
        return 0
    # Usar log10 para evitar errores de punto flotante
    return max(0, math.ceil(-math.log10(d)))


def fmt(value: float | None, d: float, *, zero_as_empty: bool = False) -> str:
    """
    Formatea un valor numérico con exactamente los decimales que indica d.

    Args:
        value:        El valor a formatear.
        d:            División mínima del instrumento (en las mismas unidades).
        zero_as_empty: Si True y value es 0, retorna '' en lugar de '0.000'.

    Returns:
        Cadena formateada con exactamente decimals_from_d(d) decimales.
        '' si value es None.
    """
    if value is None:
        return ''
    if zero_as_empty and value == 0.0:
        return ''
    decimals = decimals_from_d(d)
    return f'{value:.{decimals}f}'


def fmt_patron(value: float | None) -> str:
    """
    Formatea el valor de una masa patrón sin ceros decimales sobrantes.

    Regla de negocio:
        5.0    → '5'
        2.5    → '2.5'
        0.5    → '0.5'
        5.001  → '5.001'
        None   → ''
    """
    if value is None:
        return ''
    # Verificar si es entero exacto
    if value == math.floor(value):
        return str(int(value))
    # Formatear con g (elimina ceros trailing) pero sin notación científica
    formatted = f'{value:.10g}'
    return formatted


# ──────────────────────────────────────────────────────────────────────────────
# CÁLCULO DE EMT (OIML R 76 / NOM-010-SCFI)
# ──────────────────────────────────────────────────────────────────────────────

# Tablas de límites por clase (fracción de e)
# Formato: lista de (límite_superior_en_múltiplos_de_e, factor_e)
_EMT_TABLA = {
    # Clase I (precisión): umbrales muy altos
    1: [(50_000, 0.5), (200_000, 1.0), (float('inf'), 1.5)],
    # Clase II (fina): uso en joyería, farmacia
    2: [(500, 0.5), (2_000, 1.0), (10_000, 1.5), (float('inf'), 2.0)],
    # Clase III (media / comercio e industria):
    3: [(500, 1.0), (2_000, 2.0), (10_000, 3.0), (float('inf'), 3.0)],
    # Clase IIII (ordinaria):
    4: [(50, 1.0), (200, 2.0), (1_000, 3.0), (float('inf'), 3.0)],
}


def calc_emt(carga_kg: float, e_kg: float, clase: int = 3) -> float:
    """
    Calcula el Error Máximo Tolerado (EMT) según OIML R 76 / NOM-010-SCFI.

    Args:
        carga_kg:  Carga nominal aplicada en kg.
        e_kg:      Intervalo de escala de verificación (e) en kg.
                   Si no se conoce e por separado, usar el mismo valor de d.
        clase:     Clase metrológica del instrumento (1, 2, 3 o 4).
                   Por defecto 3 (más común en báscula comercial/industrial).

    Returns:
        EMT como valor positivo en kg. El error real debe estar en [-EMT, +EMT].

    Ejemplo Clase III, e=0.001 kg, m=5 kg:
        m/e = 5000 → supera 2000e → factor 3 → EMT = 3 × 0.001 = 0.003 kg
    """
    if e_kg <= 0 or carga_kg < 0:
        return e_kg  # fallback seguro: ±1e

    tabla = _EMT_TABLA.get(clase, _EMT_TABLA[3])
    multiplos = carga_kg / e_kg

    for limite, factor in tabla:
        if multiplos <= limite:
            return round(factor * e_kg, 10)

    # Fallback: último factor
    return round(tabla[-1][1] * e_kg, 10)


def emt_para_fila(carga_kg: float | None, d: float | None, clase: int = 3) -> float | None:
    """
    Wrapper conveniente: dado el valor de carga y la división d,
    retorna el EMT en kg o None si los datos son insuficientes.
    """
    if carga_kg is None or d is None or carga_kg < 0 or d <= 0:
        return None
    return calc_emt(carga_kg, d, clase=clase)


# ──────────────────────────────────────────────────────────────────────────────
# DETECCIÓN AUTOMÁTICA DE CLASE METROLÓGICA (OIML R 76 / NOM-010-SCFI)
# ──────────────────────────────────────────────────────────────────────────────

# Límites del número de divisiones n = Max / d por clase
# OIML R 76-1:2006 Tabla 1
_N_RANGES = {
    # clase: (n_min, n_max)
    1: (50_000,  float('inf')),  # Clase I  — alta precisión
    2: (100,     100_000),       # Clase II — fina (joyería, farmacia)
    3: (100,     10_000),        # Clase III — media (comercio / industria)
    4: (100,     1_000),         # Clase IIII — ordinaria (grúas, silos)
}

# Límites de d mínimo permitido por clase (en kg)
_D_MIN = {
    1: 0.001e-3,   # 0.001 mg
    2: 0.001e-3,   # 0.001 mg
    3: 0.1e-3,     # 0.1 g = 0.0001 kg
    4: 5e-3,       # 5 g   = 0.005 kg
}


def detectar_clase(max_kg: float, d_kg: float) -> int:
    """
    Infiere la clase metrológica OIML R 76 más restrictiva posible
    a partir de la capacidad máxima (Max) y la división mínima (d).

    Criterio: n = Max / d  → se asigna la clase más alta que contenga n.

    Reglas de prioridad (de más exigente a menos):
        Clase I   → n > 50 000
        Clase II  → 100 ≤ n ≤ 100 000  (y d ≥ 0.001 mg)
        Clase III → 100 ≤ n ≤ 10 000   (más común en báscula comercial)
        Clase IV  → 100 ≤ n ≤ 1 000

    Args:
        max_kg: Capacidad máxima del instrumento en kg.
        d_kg:   División mínima en kg.

    Returns:
        Número de clase: 1, 2, 3 o 4. Por defecto 3 si no se puede determinar.
    """
    if max_kg <= 0 or d_kg <= 0:
        return 3  # fallback seguro

    n = max_kg / d_kg

    # Clase I: alta precisión (n > 50 000)
    if n > 50_000:
        return 1

    # Clase II: fina (100 ≤ n ≤ 100 000 y d ≥ límite mínimo)
    if 100 <= n <= 100_000 and d_kg >= _D_MIN[2]:
        # Solo Clase II si d es muy pequeño (joyería / farmacia)
        # Heurística práctica: si d < 0.01 kg → Clase II candidate
        if d_kg < 0.01:
            return 2

    # Clase III: comercio e industria general (100 ≤ n ≤ 10 000)
    if 100 <= n <= 10_000:
        return 3

    # Clase IV: ordinaria (n ≤ 1 000)
    if n <= 1_000:
        return 4

    # n entre 1 000 y 10 000 pero no cubierto → Clase III
    return 3


def clase_label(clase: int) -> str:
    """
    Retorna la etiqueta oficial de la clase metrológica para mostrar en UI y PDF.
    Sin paréntesis OIML para mantener limpieza en el encabezado del reporte.

    Ejemplos:
        clase_label(1) → 'Clase I'
        clase_label(3) → 'Clase III'
    """
    nombres = {
        1: 'Clase I',
        2: 'Clase II',
        3: 'Clase III',
        4: 'Clase IIII',
    }
    return nombres.get(clase, f'Clase {clase}')



def clase_desde_os(os_data: dict) -> int:
    """
    Obtiene la clase metrológica de los datos de la OS.
    Prioridad:
        1. Campo 'clase_exactitud' explícito (int 1–4 o str 'I'/'II'/'III'/'IIII')
        2. Inferencia automática desde 'alcance_max' y 'div_minima'
        3. Fallback: Clase III

    Args:
        os_data: Diccionario de datos de la OS.

    Returns:
        int: 1, 2, 3 o 4.
    """
    # 1. Campo explícito
    raw = os_data.get('clase_exactitud')
    if raw is not None:
        if isinstance(raw, int) and raw in (1, 2, 3, 4):
            return raw
        if isinstance(raw, str):
            mapping = {'I': 1, 'II': 2, 'III': 3, 'IIII': 4, '1': 1, '2': 2, '3': 3, '4': 4}
            found = mapping.get(raw.strip().upper())
            if found:
                return found

    # 2. Inferencia automática
    try:
        max_kg = float(os_data.get('alcance_max') or 0)
        d_kg   = float(os_data.get('div_minima')  or 0)
        if max_kg > 0 and d_kg > 0:
            return detectar_clase(max_kg, d_kg)
    except (ValueError, TypeError):
        pass

    # 3. Fallback
    return 3
