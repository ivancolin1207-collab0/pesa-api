// lib/services/metrology_helper.dart
// Funciones auxiliares de cálculo y validación metrológica (OIML R 76 / NOM-010-SCFI)
import 'dart:convert';

/// Retorna el número de decimales adecuado a partir de la división mínima d (OIML R 76).
/// - Si d es entero o >= 1 (ej. d = 1, 2, 5, 10, 20, 50 kg) -> 0 decimales (ej. 1000, 2000, 5990)
/// - Si d tiene decimales (ej. d = 0.1, 0.2, 0.5 kg) -> 1 decimal (ej. 1000.0)
/// - Si d = 0.01 kg -> 2 decimales (ej. 1000.00)
/// - Si d = 0.001 kg -> 3 decimales (ej. 1.000)
int getDecimalsFromD(double? d) {
  if (d == null || d <= 0) return 0;
  if (d >= 1.0) return 0;
  final str = d.toString();
  if (str.contains('e-') || str.contains('E-')) {
    final exp = int.tryParse(str.split(RegExp(r'[eE]-'))[1]);
    if (exp != null) return exp;
  }
  if (str.contains('.')) {
    return str.split('.')[1].length;
  }
  return 0;
}

/// Formatea un valor numérico metrológico (Valor Nominal, Lectura Inicial,
/// Lectura Final, Error) dinámicamente según la división mínima d.
String formatMetrologicalValue(double? val, double? d) {
  if (val == null) return '';
  if (d == null || d <= 0) {
    if ((val - val.roundToDouble()).abs() < 1e-6) return val.round().toString();
    return val.toString();
  }
  final decimals = getDecimalsFromD(d);
  return val.toStringAsFixed(decimals);
}

/// Convierte y formatea dinámicamente cualquier entrada (String, double, num)
/// según la división mínima d.
String formatMetrologicalString(dynamic val, double? d) {
  if (val == null) return '';
  final str = val.toString().trim();
  if (str.isEmpty) return '';
  final dVal = double.tryParse(str.replaceAll(',', '.'));
  if (dVal == null) return str;
  return formatMetrologicalValue(dVal, d);
}

/// Calcula el número de decimales adecuado a partir de la división mínima d.
int decimalsFromDivMin(double? d) => getDecimalsFromD(d);

/// Calcula el error metrológico en la prueba de Excentricidad.
/// - Si es camionera o rectangular por secciones: estrictamente Error = L. FINAL - Carga de Prueba.
/// - En general: Error = L. FINAL - Carga de Prueba
/// - Corrección de cero residual: solo si |L. INICIAL| < (Carga * 0.10) y no es camionera:
///   Error = (L. FINAL - L. INICIAL) - Carga
double? calcularErrorExcentricidad({
  required double? fin,
  required double? ini,
  required double? carga,
  bool isCamionera = false,
}) {
  if (fin == null || carga == null) return null;
  if (isCamionera) {
    return fin - carga;
  }
  if (ini != null && ini != 0 && ini.abs() < (carga * 0.10)) {
    return (fin - ini) - carga;
  }
  return fin - carga;
}

/// Determina la geometría de excentricidad por defecto a partir del tipo de instrumento.
/// - "Camionera": si contiene camionera, ferrocarril, puente, ffcc, ferrovi
/// - "Circular": si contiene circular
/// - "Plataforma": para el resto (plataforma, piso, mostrador, colgante, tolva, etc.)
String getGeometriaPorDefecto(String? tipoInstrumento) {
  if (tipoInstrumento == null || tipoInstrumento.trim().isEmpty) return 'Plataforma';
  final t = tipoInstrumento.toLowerCase().trim();
  if (t.contains('camionera') ||
      t.contains('ferrocarril') ||
      t.contains('puente') ||
      t.contains('ffcc') ||
      t.contains('ferrovi')) {
    return 'Camionera';
  }
  if (t.contains('circular')) {
    return 'Circular';
  }
  return 'Plataforma';
}

/// Valida si un valor numérico es un múltiplo exacto de la división mínima d,
/// considerando tolerancia por redondeo flotante IEEE 754.
bool isValidDivMin(double? val, double? d) {
  if (val == null || d == null || d <= 0) return true;
  final double k = (val / d).abs();
  final double diff = (k - k.roundToDouble()).abs();
  return diff < 1e-4;
}

/// Mensaje estándar de error cuando un valor no cumple con los saltos de división mínima.
String divMinErrorMsg(double? d) {
  if (d == null || d <= 0) return 'El valor debe ser múltiplo de la división mínima';
  final dec = getDecimalsFromD(d);
  return 'El valor debe ser múltiplo de la división mínima (ej. saltos de ${d.toStringAsFixed(dec)})';
}

/// Asigna los puntos de apoyo por defecto según el tipo de instrumento seleccionado.
/// Modificable manualmente por el técnico con (-) / (+).
int getPuntosApoyoPorDefecto(String? tipoInstrumento, {int fallback = 4}) {
  if (tipoInstrumento == null || tipoInstrumento.trim().isEmpty) return fallback;
  final t = tipoInstrumento.toLowerCase().trim();
  if (t.contains('plataforma') || t.contains('piso')) return 5;
  if (t.contains('camionera') || t.contains('puente')) return 8;
  if (t.contains('ferrocarril') || t.contains('ferrovi')) return 8;
  if (t.contains('tolva')) return 3;
  if (t.contains('colgante') || t.contains('grúa') || t.contains('grua')) return 1;
  if (t.contains('analítica') || t.contains('analitica')) return 1;
  if (t.contains('mostrador')) return 1;
  if (t.contains('tanque') || t.contains('silo')) return 4;
  return fallback;
}

/// Sugiere la carga de prueba para Repetibilidad (>= 50% de Capacidad Máxima).
/// Redondea hacia arriba a un valor comercial/estándar de pesas patrón.
/// Ejemplos:
/// - Capacidad = 6.8 kg -> 50% = 3.4 kg -> sugerir 4.000 kg
/// - Capacidad = 1000 kg -> 50% = 500 kg -> sugerir 500 kg
double calcularCargaSugeridaRepetibilidad(double capMax, {double? divMin, String unidad = 'kg'}) {
  if (capMax <= 0) return 0;
  final double base = capMax * 0.50;
  return _redondearCargaComercial(base, capMax, unidad: unidad, divMin: divMin, esExcentricidad: false);
}

/// Sugiere la carga de prueba para Excentricidad (>= 1/3 de Capacidad Máxima).
/// Redondea hacia arriba a valor entero o múltiplo práctico de pesas comerciales (20 kg).
/// Ejemplos:
/// - Capacidad = 6.8 kg -> 1/3 = 2.266 kg -> sugerir 3.000 kg
/// - Capacidad = 1000 kg -> 1/3 = 333.33 kg -> redondear al múltiplo superior (sugerir 340 kg)
double calcularCargaSugeridaExcentricidad(double capMax, {double? divMin, String unidad = 'kg'}) {
  if (capMax <= 0) return 0;
  final double base = capMax / 3.0;
  return _redondearCargaComercial(base, capMax, unidad: unidad, divMin: divMin, esExcentricidad: true);
}

double _redondearCargaComercial(
  double base,
  double capMax, {
  required String unidad,
  double? divMin,
  required bool esExcentricidad,
}) {
  final u = unidad.toLowerCase().trim();
  if (u == 'g') {
    if (capMax >= 1000) {
      const double step = 50.0;
      return (base / step).ceil() * step;
    } else if (capMax >= 100) {
      const double step = 10.0;
      return (base / step).ceil() * step;
    } else if (capMax >= 10) {
      const double step = 1.0;
      return (base / step).ceil() * step;
    } else {
      final double step = (divMin != null && divMin > 0) ? divMin : 0.1;
      return (base / step).ceil() * step;
    }
  }

  // Unidad en kg:
  if (capMax >= 500) {
    // Básculas industriales, camioneras, tolvas, etc.
    // Pesas patrón comerciales estándar de 20 kg (NOM-010-SCFI / OIML R 111)
    // 333.33 -> 340 kg; 500 -> 500 kg
    const double step = 20.0;
    return (base / step).ceil() * step;
  } else if (capMax >= 100) {
    const double step = 10.0;
    return (base / step).ceil() * step;
  } else if (capMax >= 20) {
    const double step = 5.0;
    return (base / step).ceil() * step;
  } else if (capMax >= 1) {
    // Básculas comerciales / mostrador / analíticas (ej. 6.8 kg)
    // Carga redondeada al entero superior en kg
    // Repetibilidad: 3.4 -> 4.0 kg; Excentricidad: 2.266 -> 3.0 kg
    const double step = 1.0;
    return (base / step).ceil() * step;
  } else {
    // Menor a 1 kg en unidad kg
    final double step = (divMin != null && divMin > 0) ? divMin : 0.05;
    return (base / step).ceil() * step;
  }
}

/// Formatea un valor numérico de carga según los decimales adecuados.
/// - Si capMax < 20 (ej. 6.8 kg): 3 decimales ("4.000", "3.000")
/// - Si la carga es entera exacta (ej. 500, 340): sin decimales superfluos ("500", "340")
String formatearCargaSugerida(double carga, {double? divMin, double? capMax}) {
  if (carga <= 0) return '';
  final dec = getDecimalsFromD(divMin);

  // Básculas de precisión / pequeñas (capMax < 20, ej. 6.8 kg) y con d con decimales
  if (capMax != null && capMax < 20 && (divMin == null || divMin < 1)) {
    final d = (divMin != null && divMin > 0) ? dec : 3;
    return carga.toStringAsFixed(d);
  }

  // Si divMin está definido (>= 1 o < 1), usar regla estricta metrológica
  if (divMin != null && divMin > 0) {
    return formatMetrologicalValue(carga, divMin);
  }

  // Si es un entero exacto (ej. 500, 340)
  if ((carga - carga.roundToDouble()).abs() < 1e-4) {
    return carga.round().toString();
  }

  return carga.toStringAsFixed(dec);
}

/// Normaliza el texto de división mínima eliminando ceros insignificantes a la derecha
/// (ej. '0.020 kg' -> '0.02 kg', '0.100' -> '0.1', '5.00' -> '5') sin alterar la precisión numérica.
String formatearDivisionMinima(dynamic rawDiv) {
  if (rawDiv == null) return '';
  final str = rawDiv.toString().trim();
  if (str.isEmpty) return '';
  final match = RegExp(r'^([+-]?\d+(?:[.,]\d+)?)\s*(.*)$').firstMatch(str);
  if (match == null) return str;
  final numStr = match.group(1)!.replaceAll(',', '.');
  final unidad = match.group(2)!.trim();
  final val = double.tryParse(numStr);
  if (val == null) return str;
  // Eliminar ceros insignificantes a la derecha (0.020 -> 0.02, 0.100 -> 0.1, 1.00 -> 1)
  final String limpio = val.toStringAsFixed(6).replaceAll(RegExp(r'\.?0+$'), '');
  return unidad.isNotEmpty ? '$limpio $unidad' : limpio;
}

/// Opciones oficiales de tipo de instrumento no apto para prueba de excentricidad.
const List<String> kTiposNoAptosExcentricidad = [
  'Grúa',
  'Patín',
  'Tanque',
  'Tolva',
  'Silo',
];

/// Infiere o normaliza el motivo/tipo de instrumento no apto ('Grúa', 'Patín', 'Tanque', 'Tolva', 'Silo')
/// a partir del motivo explícito o del tipo de instrumento seleccionado.
String inferirMotivoNoExcentricidad(String? rawMotivo, [String? tipoInstrumento]) {
  for (final src in [rawMotivo, tipoInstrumento]) {
    if (src == null || src.trim().isEmpty) continue;
    final s = src.toLowerCase().trim();
    if (s.contains('grua') || s.contains('grúa') || s.contains('colgante') || s.contains('gancho')) {
      return 'Grúa';
    }
    if (s.contains('patin') || s.contains('patín') || s.contains('transpaleta')) {
      return 'Patín';
    }
    if (s.contains('silo')) {
      return 'Silo';
    }
    if (s.contains('tanque')) {
      return 'Tanque';
    }
    if (s.contains('tolva')) {
      return 'Tolva';
    }
  }
  if (rawMotivo != null && rawMotivo.trim().isNotEmpty) {
    return rawMotivo.trim();
  }
  return 'Tolva';
}

const Set<String> _kValoresOmitirEtiqueta = {
  '',
  '-',
  '--',
  'none',
  'null',
  'n/a',
  'na',
  's/n',
  'sn',
  'sin id',
  'sin modelo',
  'sin serie',
  'sin marca',
  'sin ubicacion',
  'sin ubicación',
  'por definir',
};

/// Limpia un número regulatorio (CCA o DVE), descartando valores nulos o prefijos vacíos
/// como 'CCA.26.' o 'DVE.26.' sin dígitos finales.
String limpiarNumeroRegulatorio(dynamic rawVal) {
  if (rawVal == null) return '';
  final s = rawVal.toString().trim();
  if (s.isEmpty) return '';
  if (_kValoresOmitirEtiqueta.contains(s.toLowerCase())) return '';
  if (RegExp(r'^(CCA|DVE)\.\d{2}\.?$', caseSensitive: false).hasMatch(s)) {
    return '';
  }
  return s;
}

Map<String, dynamic> _extraerMapaDatosTecnicos(Map<String, dynamic> orden) {
  final rawDt = orden['datos_tecnicos_json'] ?? orden['datos_captura'];
  if (rawDt is Map<String, dynamic>) return rawDt;
  if (rawDt is Map) return Map<String, dynamic>.from(rawDt);
  if (rawDt is String && rawDt.trim().isNotEmpty) {
    try {
      final dec = jsonDecode(rawDt);
      if (dec is Map) return Map<String, dynamic>.from(dec);
    } catch (_) {}
  }
  return const {};
}

/// Extrae el Número CCA limpio desde la orden o su datos_tecnicos_json.
String extraerNumeroCca(Map<String, dynamic> orden) {
  for (final key in ['numero_cca', 'cca', 'folio_cca']) {
    final clean = limpiarNumeroRegulatorio(orden[key]);
    if (clean.isNotEmpty) return clean;
  }
  final dt = _extraerMapaDatosTecnicos(orden);
  for (final key in ['numero_cca', 'cca', 'folio_cca']) {
    final clean = limpiarNumeroRegulatorio(dt[key]);
    if (clean.isNotEmpty) return clean;
  }
  return '';
}

/// Extrae el Número DVE (Dictamen de Verificación) limpio desde la orden o su datos_tecnicos_json.
String extraerNumeroDve(Map<String, dynamic> orden) {
  for (final key in ['numero_dve', 'folio_dve']) {
    final clean = limpiarNumeroRegulatorio(orden[key]);
    if (clean.isNotEmpty) return clean;
  }
  // Compatibilidad con registros donde folio DVE alfanumérico quedó en div_verificacion
  final rawDivVer = orden['div_verificacion']?.toString().trim() ?? '';
  if (rawDivVer.toUpperCase().startsWith('DVE')) {
    final clean = limpiarNumeroRegulatorio(rawDivVer);
    if (clean.isNotEmpty) return clean;
  }
  final dt = _extraerMapaDatosTecnicos(orden);
  for (final key in ['numero_dve', 'folio_dve']) {
    final clean = limpiarNumeroRegulatorio(dt[key]);
    if (clean.isNotEmpty) return clean;
  }
  return '';
}

/// Construye dinámicamente el identificador compuesto del instrumento:
/// `FOLIO - MARCA - MODELO - SN - ID - UBICACIÓN`
/// omitiendo campos vacíos, null, 'sin id', 'sin modelo', 'sin serie', etc.
String construirEtiquetaInstrumento(Map<String, dynamic> orden) {
  final dt = _extraerMapaDatosTecnicos(orden);

  String pickField(List<String> keys) {
    for (final k in keys) {
      final v = orden[k];
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty && !_kValoresOmitirEtiqueta.contains(s.toLowerCase())) {
          return s;
        }
      }
    }
    for (final k in keys) {
      final v = dt[k];
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty && !_kValoresOmitirEtiqueta.contains(s.toLowerCase())) {
          return s;
        }
      }
    }
    return '';
  }

  final folio = (orden['folio_os'] ?? orden['folio'] ?? '').toString().trim();
  final marca = pickField(['marca']);
  final modelo = pickField(['modelo']);
  final serie = pickField(['serie', 'ns', 'numero_serie']);
  final idEquipo = pickField(['id_indicador', 'id_equipo', 'tag']);
  final ubicacion = pickField(['ubicacion', 'ubicacion_equipo', 'area']);

  final partes = <String>[];
  if (folio.isNotEmpty) partes.add(folio);

  for (final cand in [marca, modelo, serie, idEquipo, ubicacion]) {
    if (cand.isEmpty) continue;
    if (partes.any((p) => p.toLowerCase() == cand.toLowerCase())) continue;
    partes.add(cand);
  }

  return partes.join(' - ');
}



