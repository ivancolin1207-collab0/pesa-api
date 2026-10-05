// lib/services/tipo_servicio_rules.dart
// Puerto Dart de servicios_pesa/services/tipo_servicio_rules.py
// Matriz de reglas NOM-010-SCFI-2020.
//
// v3.1.20+75 — REGLA ESTRICTA (sin modo permisivo):
//   • CCA (+ Inicial J/I/A) SOLO si el tipo contiene "Calibración" o "CCA".
//   • DVE + Hologramas     SOLO si el tipo contiene "DVE", "Inspección" o "Verificación".
//   • "Ajuste" / "Mantenimiento" / tipos desconocidos → sin CCA ni DVE.
//   • Formatos físicos Remisión (RMA / Entrega Refacciones) y Revisión de
//     Celdas (RE / Revisión) → nunca piden CCA ni DVE.
//
// Resolución: 1) formato por folio/nombre  2) nombre de texto  3) ID numérico.
// El nombre tiene prioridad sobre el ID porque en PostgreSQL existen órdenes
// con id_tipo_servicio inconsistente con su texto (p. ej. RMA con id 4).
//
// CASOS DE NEGOCIO:
//   Caso A — Solo Ajuste / Mantenimiento:   CCA❌  Holo❌  DVE❌
//   Caso B — Calibración (+ Ajuste):        CCA✅  Holo❌  DVE❌
//   Caso C — Inspección (+ Ajuste):         CCA❌  Holo✅  DVE✅
//   Caso D — Calibración + Inspección:      CCA✅  Holo✅  DVE✅

import 'package:flutter/foundation.dart';

/// Formato del documento según folio / tipo de servicio.
enum FormatoDocumento { ordenServicio, remision, revisionCeldas }

class ServiceRules {
  final int    tipoServicioId;
  final String nombre;
  final bool   pideCca;
  final bool   pideHologramaAnterior;
  final bool   pideHologramaActualizado;
  final FormatoDocumento formato;

  const ServiceRules({
    required this.tipoServicioId,
    required this.nombre,
    required this.pideCca,
    required this.pideHologramaAnterior,
    required this.pideHologramaActualizado,
    this.formato = FormatoDocumento.ordenServicio,
  });

  // ── Propiedades derivadas ─────────────────────────────────────────────────

  /// True si el tipo incluye Calibración (requiere CCA).
  bool get tieneCalibracion    => pideCca;

  /// True si incluye Inspección / Verificación (requiere hologramas + DVE).
  bool get tieneInspeccion     => pideHologramaAnterior;

  /// La Inicial J/I/A co-depende del CCA (NOM-010-SCFI-2020).
  bool get pideInicialJia      => pideCca;

  /// DVE aparece junto a los hologramas — solo en Inspección / Verificación.
  bool get pideDve             => pideHologramaAnterior;

  /// Solo ajuste/mantenimiento: ningún campo metrológico adicional.
  bool get esSoloAjuste        => !pideCca && !pideHologramaAnterior;

  bool get esRemision          => formato == FormatoDocumento.remision;
  bool get esRevisionCeldas    => formato == FormatoDocumento.revisionCeldas;

  /// True si la OS llegó sin tipo de servicio (ni nombre ni ID).
  bool get sinTipo             => tipoServicioId == 0 && formato == FormatoDocumento.ordenServicio;

  bool get _mencionaAjuste {
    final n = _normalize(nombre);
    return n.contains('ajuste') || n.contains('mantenim');
  }

  /// Etiqueta corta homologada para badges de Dashboard (tablet / escritorio).
  ///   CCA + DVE · DVE + Ajuste · CCA + Ajuste · Ajuste
  String get etiquetaCorta {
    if (esRemision) return 'Remisión';
    if (esRevisionCeldas) return 'Revisión';
    if (sinTipo) return 'Sin tipo';
    if (pideCca && pideDve) return 'CCA + DVE';
    if (pideCca) return _mencionaAjuste ? 'CCA + Ajuste' : 'CCA';
    if (pideDve) return _mencionaAjuste ? 'DVE + Ajuste' : 'DVE';
    return 'Ajuste';
  }

  /// Etiqueta descriptiva para el banner de captura.
  String get etiquetaLarga {
    if (esRemision) return 'Remisión — sin CCA ni DVE';
    if (esRevisionCeldas) return 'Revisión de Celdas — sin CCA ni DVE';
    if (sinTipo) return 'Tipo de servicio no recibido — sincroniza la orden';
    if (pideCca && pideDve) return 'Calibración + Inspección (CCA + DVE)';
    if (pideCca) return _mencionaAjuste ? 'Calibración + Ajuste (CCA)' : 'Calibración (CCA)';
    if (pideDve) return _mencionaAjuste ? 'Ajuste + Inspección (DVE)' : 'Inspección (DVE)';
    return 'Ajuste — sin CCA ni DVE';
  }

  @override
  String toString() =>
      'ServiceRules(id=$tipoServicioId, nombre=$nombre, formato=${formato.name}, '
      'cca=$pideCca, holo=$pideHologramaAnterior, dve=$pideDve)';
}

// ── Tabla canónica por ID — ALINEADA con cat_tipo_servicio de PostgreSQL ──
//   1 Calibración                         → Caso B
//   2 Ajuste                              → Caso A
//   3 Inspección                          → Caso C
//   4 Calibración + Ajuste                → Caso B
//   5 Calibración + Inspección            → Caso D
//   6 Ajuste + Inspección                 → Caso C
//   7 Calibración + Ajuste + Inspección   → Caso D
//   8 Entrega Refacciones                 → Remisión (sin CCA / DVE)

const Map<int, ServiceRules> _kRulesById = {
  1: ServiceRules(tipoServicioId: 1, nombre: 'Calibración',
      pideCca: true,  pideHologramaAnterior: false, pideHologramaActualizado: false),
  2: ServiceRules(tipoServicioId: 2, nombre: 'Ajuste',
      pideCca: false, pideHologramaAnterior: false, pideHologramaActualizado: false),
  3: ServiceRules(tipoServicioId: 3, nombre: 'Inspección',
      pideCca: false, pideHologramaAnterior: true,  pideHologramaActualizado: true),
  4: ServiceRules(tipoServicioId: 4, nombre: 'Calibración + Ajuste',
      pideCca: true,  pideHologramaAnterior: false, pideHologramaActualizado: false),
  5: ServiceRules(tipoServicioId: 5, nombre: 'Calibración + Inspección',
      pideCca: true,  pideHologramaAnterior: true,  pideHologramaActualizado: true),
  6: ServiceRules(tipoServicioId: 6, nombre: 'Ajuste + Inspección',
      pideCca: false, pideHologramaAnterior: true,  pideHologramaActualizado: true),
  7: ServiceRules(tipoServicioId: 7, nombre: 'Calibración + Ajuste + Inspección',
      pideCca: true,  pideHologramaAnterior: true,  pideHologramaActualizado: true),
  8: ServiceRules(tipoServicioId: 8, nombre: 'Entrega Refacciones',
      pideCca: false, pideHologramaAnterior: false, pideHologramaActualizado: false,
      formato: FormatoDocumento.remision),
};

/// Regla por defecto cuando el tipo es desconocido: ESTRICTA (no exige nada).
const _kDefault = ServiceRules(
  tipoServicioId: 0,
  nombre: '(sin tipo)',
  pideCca: false,
  pideHologramaAnterior: false,
  pideHologramaActualizado: false,
);

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll('á', 'a').replaceAll('é', 'e')
    .replaceAll('í', 'i').replaceAll('ó', 'o')
    .replaceAll('ú', 'u').replaceAll('ü', 'u')
    .replaceAll('ñ', 'n')
    .trim();

/// Detecta Remisión / Revisión de Celdas por prefijo de folio o por nombre.
FormatoDocumento detectarFormato({String? folio, String? nombre}) {
  final f = (folio ?? '').trim().toUpperCase();
  if (f.startsWith('RMA-')) return FormatoDocumento.remision;
  if (f.startsWith('RE-'))  return FormatoDocumento.revisionCeldas;
  final n = _normalize(nombre ?? '');
  if (n.contains('refacci') || n.contains('remisi')) return FormatoDocumento.remision;
  if (n.contains('revisi') || n.contains('celda'))   return FormatoDocumento.revisionCeldas;
  return FormatoDocumento.ordenServicio;
}

bool _tieneCca(String n) =>
    n.contains('calibra') || RegExp(r'\bcca\b').hasMatch(n);

bool _tieneDve(String n) =>
    RegExp(r'\bdve\b').hasMatch(n) || n.contains('inspecc') || n.contains('verifica');

ServiceRules _resolveByName(String nombre) {
  final n = _normalize(nombre);
  final cca = _tieneCca(n);
  final dve = _tieneDve(n);
  if (!cca && !dve && !(n.contains('ajuste') || n.contains('mantenim'))) {
    debugPrint('[PESA TipoServicio] Nombre no reconocido: "$nombre" → sin CCA/DVE (regla estricta)');
  }
  final id = cca && dve ? 7 : cca ? 4 : dve ? 6 : 2;
  return ServiceRules(
    tipoServicioId: id,
    nombre: nombre,
    pideCca: cca,
    pideHologramaAnterior: dve,
    pideHologramaActualizado: dve,
  );
}

ServiceRules _formatoSinMetrologia(FormatoDocumento formato, String nombre) => ServiceRules(
      tipoServicioId: formato == FormatoDocumento.remision ? 8 : 0,
      nombre: nombre.isNotEmpty
          ? nombre
          : (formato == FormatoDocumento.remision ? 'Remisión de Servicio' : 'Revisión de Celdas'),
      pideCca: false,
      pideHologramaAnterior: false,
      pideHologramaActualizado: false,
      formato: formato,
    );

// ── API pública ────────────────────────────────────────────────────────────

/// Resuelve las reglas por ID numérico (campo `id_tipo_servicio`).
ServiceRules getRulesById(int? id) {
  if (id == null) return _kDefault;
  return _kRulesById[id] ?? _kDefault;
}

/// Resuelve las reglas por nombre de texto (campo `tipo_servicio`).
ServiceRules getRulesByName(String? nombre) {
  if (nombre == null || nombre.trim().isEmpty) return _kDefault;
  final formato = detectarFormato(nombre: nombre);
  if (formato != FormatoDocumento.ordenServicio) {
    return _formatoSinMetrologia(formato, nombre);
  }
  return _resolveByName(nombre);
}

/// Función principal usada por `captura_screen.dart`.
/// Prioridad: formato (folio/nombre) → nombre → ID.
ServiceRules getRules({int? id, String? nombre, String? folio}) {
  final formato = detectarFormato(folio: folio, nombre: nombre);
  if (formato != FormatoDocumento.ordenServicio) {
    return _formatoSinMetrologia(formato, (nombre ?? '').trim());
  }
  if (nombre != null && nombre.trim().isNotEmpty) return _resolveByName(nombre);
  if (id != null) return getRulesById(id);
  return _kDefault;
}

// Helpers de conveniencia
bool pideCca({int? id, String? nombre, String? folio})               => getRules(id: id, nombre: nombre, folio: folio).pideCca;
bool pideHologramaAnterior({int? id, String? nombre, String? folio}) => getRules(id: id, nombre: nombre, folio: folio).pideHologramaAnterior;
bool pideHologramaActualizado({int? id, String? nombre, String? folio}) => getRules(id: id, nombre: nombre, folio: folio).pideHologramaActualizado;
bool pideInicialJia({int? id, String? nombre, String? folio})        => getRules(id: id, nombre: nombre, folio: folio).pideInicialJia;
bool pideDve({int? id, String? nombre, String? folio})               => getRules(id: id, nombre: nombre, folio: folio).pideDve;
