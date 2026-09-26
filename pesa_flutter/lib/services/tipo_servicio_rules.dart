// lib/services/tipo_servicio_rules.dart
// Puerto Dart de servicios_pesa/services/tipo_servicio_rules.py
// Matriz de reglas NOM-010-SCFI-2020 — idéntica al sistema de Windows.
//
// Lookup DUAL: por ID numérico O por nombre de texto normalizado.
// La OS puede traer `id_tipo_servicio` (int) o `tipo_servicio` (String).
// Ambos caminos se resuelven a las mismas reglas.
//
// CASOS DE NEGOCIO:
//   Caso A — Solo Ajuste / Mantenimiento:   CCA❌  Holo❌  DVE❌
//   Caso B — Calibración + Ajuste (CCA):    CCA✅  Holo❌  DVE❌
//   Caso C — Ajuste e Inspección:           CCA❌  Holo✅  DVE✅
//   Caso D — Mixto (CCA + Inspección):      CCA✅  Holo✅  DVE✅

import 'package:flutter/foundation.dart';

class ServiceRules {
  final int    tipoServicioId;
  final String nombre;
  final bool   pideCca;
  final bool   pideHologramaAnterior;
  final bool   pideHologramaActualizado;

  const ServiceRules({
    required this.tipoServicioId,
    required this.nombre,
    required this.pideCca,
    required this.pideHologramaAnterior,
    required this.pideHologramaActualizado,
  });

  // ── Propiedades derivadas ─────────────────────────────────────────────────

  /// True si el tipo incluye Calibración (requiere CCA).
  bool get tieneCalibracion    => pideCca;

  /// True si incluye Inspección (requiere hologramas + DVE).
  bool get tieneInspeccion     => pideHologramaAnterior;

  /// La Inicial J/I/A co-depende del CCA (NOM-010-SCFI-2020).
  bool get pideInicialJia      => pideCca;

  /// DVE aparece junto a los hologramas — solo en Inspección.
  bool get pideDve             => pideHologramaAnterior;

  /// Solo ajuste/mantenimiento: ningún campo metrológico adicional.
  bool get esSoloAjuste        => !pideCca && !pideHologramaAnterior;

  @override
  String toString() =>
      'ServiceRules(id=$tipoServicioId, nombre=$nombre, '
      'cca=$pideCca, holo=$pideHologramaAnterior, dve=$pideDve)';
}

// ── Tabla canónica de reglas (por ID numérico BD) ─────────────────────────
//
//   1 = Ajuste (Solo Ajuste / Mantenimiento)             → Caso A
//   2 = Ajuste e Inspección                              → Caso C
//   3 = Ajuste y Calibración (Calibración + Ajuste)      → Caso B
//   4 = Ajuste, Calibración e Inspección (Mixto)         → Caso D
//   5 = Calibración + Inspección                         → Caso D
//   6 = Ajuste + Inspección                              → Caso C
//   7 = Calibración + Ajuste + Inspección                → Caso D

const Map<int, ServiceRules> _kRulesById = {
  // ── Caso A: Solo Ajuste ─────────────────────────────────────────────────
  1: ServiceRules(
    tipoServicioId: 1,
    nombre: 'Ajuste',
    pideCca: false,
    pideHologramaAnterior: false,
    pideHologramaActualizado: false,
  ),
  // ── Caso C: Ajuste + Inspección ─────────────────────────────────────────
  2: ServiceRules(
    tipoServicioId: 2,
    nombre: 'Ajuste e Inspección',
    pideCca: false,
    pideHologramaAnterior: true,
    pideHologramaActualizado: true,
  ),
  // ── Caso B: Calibración + Ajuste (solo CCA, sin hologramas) ─────────────
  3: ServiceRules(
    tipoServicioId: 3,
    nombre: 'Ajuste y Calibración',
    pideCca: true,
    pideHologramaAnterior: false,   // ← CRÍTICO: sin hologramas ni DVE
    pideHologramaActualizado: false,
  ),
  // ── Caso D: Mixto Completo ───────────────────────────────────────────────
  4: ServiceRules(
    tipoServicioId: 4,
    nombre: 'Ajuste, Calibración e Inspección',
    pideCca: true,
    pideHologramaAnterior: true,
    pideHologramaActualizado: true,
  ),
  5: ServiceRules(
    tipoServicioId: 5,
    nombre: 'Calibración + Inspección',
    pideCca: true,
    pideHologramaAnterior: true,
    pideHologramaActualizado: true,
  ),
  6: ServiceRules(
    tipoServicioId: 6,
    nombre: 'Ajuste + Inspección',
    pideCca: false,
    pideHologramaAnterior: true,
    pideHologramaActualizado: true,
  ),
  7: ServiceRules(
    tipoServicioId: 7,
    nombre: 'Calibración + Ajuste + Inspección',
    pideCca: true,
    pideHologramaAnterior: true,
    pideHologramaActualizado: true,
  ),
};

/// Regla por defecto cuando el tipo es desconocido.
/// Comportamiento permisivo — muestra todos los campos.
const _kDefault = ServiceRules(
  tipoServicioId: 0,
  nombre: '(desconocido)',
  pideCca: true,
  pideHologramaAnterior: true,
  pideHologramaActualizado: true,
);

// ── Mapa de palabras clave → caso ─────────────────────────────────────────
//
// Se buscan SUBCADENAS en el nombre normalizado (minúsculas, sin acentos).
// Orden de evaluación: Mixto > Calibración > Inspección > Ajuste.
// IMPORTANTE: evaluar en orden de especificidad decreciente.

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll('á', 'a').replaceAll('é', 'e')
    .replaceAll('í', 'i').replaceAll('ó', 'o')
    .replaceAll('ú', 'u').replaceAll('ü', 'u')
    .replaceAll('ñ', 'n')
    .trim();

ServiceRules _resolveByName(String nombre) {
  final n = _normalize(nombre);

  // Caso D — Mixto: contiene calibración E inspección
  final tieneCal  = n.contains('calibra');
  final tieneInsp = n.contains('inspecc') || n.contains('verifica');
  if (tieneCal && tieneInsp) {
    // Calibración + Inspección (± Ajuste) → ID 4 / 5 / 7
    return _kRulesById[4]!;
  }

  // Caso B — Solo Calibración (+ Ajuste, sin Inspección)
  if (tieneCal) {
    return _kRulesById[3]!; // CCA✅ Holo❌ DVE❌
  }

  // Caso C — Inspección / Verificación (sin Calibración)
  if (tieneInsp) {
    return _kRulesById[2]!; // CCA❌ Holo✅ DVE✅
  }

  // Caso A — Solo Ajuste / Mantenimiento
  if (n.contains('ajuste') || n.contains('mantenim')) {
    return _kRulesById[1]!;
  }

  // Desconocido → permisivo
  debugPrint('[PESA TipoServicio] Nombre no reconocido: "$nombre" → usando reglas permisivas');
  return _kDefault;
}

// ── API pública ────────────────────────────────────────────────────────────

/// Resuelve las reglas por ID numérico (campo `id_tipo_servicio`).
/// Si el ID no está en tabla, retorna reglas permisivas.
ServiceRules getRulesById(int? id) {
  if (id == null) return _kDefault;
  return _kRulesById[id] ?? _kDefault;
}

/// Resuelve las reglas por nombre de texto (campo `tipo_servicio`).
/// Busca subcadenas en minúsculas/sin acentos — robusto a variaciones.
ServiceRules getRulesByName(String? nombre) {
  if (nombre == null || nombre.isEmpty) return _kDefault;
  return _resolveByName(nombre);
}

/// Resuelve las reglas usando primero el ID y, si es null, el nombre.
/// Esta es la función principal que debe usar `captura_screen.dart`.
ServiceRules getRules({int? id, String? nombre}) {
  if (id != null) return getRulesById(id);
  if (nombre != null && nombre.isNotEmpty) return getRulesByName(nombre);
  return _kDefault;
}

// Helpers de conveniencia
bool pideCca({int? id, String? nombre})               => getRules(id: id, nombre: nombre).pideCca;
bool pideHologramaAnterior({int? id, String? nombre}) => getRules(id: id, nombre: nombre).pideHologramaAnterior;
bool pideHologramaActualizado({int? id, String? nombre}) => getRules(id: id, nombre: nombre).pideHologramaActualizado;
bool pideInicialJia({int? id, String? nombre})        => getRules(id: id, nombre: nombre).pideInicialJia;
bool pideDve({int? id, String? nombre})               => getRules(id: id, nombre: nombre).pideDve;
