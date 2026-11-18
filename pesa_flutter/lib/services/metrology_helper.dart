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
  'sin cca',
  'sin dve',
  'pendiente',
  'cca.26.xxxx',
  'dve.26.xxxx',
  'cca.26.xxxxx',
  'dve.26.xxxxx',
};

/// Limpia un número regulatorio (CCA o DVE), descartando valores nulos, prefijos vacíos
/// como 'CCA.26.' / 'DVE.26.' o máscaras placeholder como 'CCA.26.XXXXX'.
String limpiarNumeroRegulatorio(dynamic rawVal) {
  if (rawVal == null) return '';
  final s = rawVal.toString().trim();
  if (s.isEmpty) return '';
  if (_kValoresOmitirEtiqueta.contains(s.toLowerCase())) return '';
  if (RegExp(r'^(CCA|DVE)\.\d{2}\.?$', caseSensitive: false).hasMatch(s)) {
    return '';
  }
  if (RegExp(r'(?:^|[.\-\s])x{2,}(?:$|[.\-\s])', caseSensitive: false).hasMatch(s) ||
      RegExp(r'\.x+$', caseSensitive: false).hasMatch(s)) {
    return '';
  }
  return s;
}

Map<String, dynamic> _extraerMapaDatosTecnicos(Map<String, dynamic> orden) {
  final extra = <String, dynamic>{};
  for (final jkey in const [
    'datos_json',
    'datos_tecnicos_json',
    'datos_captura',
    'payload_json',
    'mediciones_json',
    'metrologia_data',
    'detalle_json',
    'raw_data',
  ]) {
    final rawDt = orden[jkey];
    if (rawDt is Map<String, dynamic>) {
      extra.addAll(rawDt);
    } else if (rawDt is Map) {
      extra.addAll(Map<String, dynamic>.from(rawDt));
    } else if (rawDt is String && rawDt.trim().startsWith('{')) {
      try {
        final dec = jsonDecode(rawDt);
        if (dec is Map) {
          extra.addAll(Map<String, dynamic>.from(dec));
        }
      } catch (_) {}
    }
  }
  return extra;
}

/// Extractor universal de CCA y DVE desde todas las llaves posibles de BD y JSONs anidados:
/// `(numero_cca, num_cca, cca, no_cca, certificado_cca, folio_cca)` y
/// `(numero_dve, num_dve, dve, no_dve, dictamen_dve, folio_dve)`.
(String, String) extraerCcaDve(Map<String, dynamic> orden) {
  final extra = _extraerMapaDatosTecnicos(orden);
  final fuente = <String, dynamic>{...extra};
  orden.forEach((k, v) {
    if (v != null && v.toString().trim().isNotEmpty) {
      fuente[k] = v;
    } else if (!fuente.containsKey(k)) {
      fuente[k] = v;
    }
  });

  String cca = '';
  for (final key in const [
    'numero_cca',
    'num_cca',
    'cca',
    'no_cca',
    'certificado_cca',
    'folio_cca',
  ]) {
    final clean = limpiarNumeroRegulatorio(fuente[key]);
    if (clean.isNotEmpty) {
      cca = clean;
      break;
    }
  }

  String dve = '';
  for (final key in const [
    'numero_dve',
    'num_dve',
    'dve',
    'no_dve',
    'dictamen_dve',
    'folio_dve',
  ]) {
    final clean = limpiarNumeroRegulatorio(fuente[key]);
    if (clean.isNotEmpty) {
      dve = clean;
      break;
    }
  }
  if (dve.isEmpty) {
    final rawDivVer = fuente['div_verificacion']?.toString().trim() ?? '';
    if (rawDivVer.toUpperCase().startsWith('DVE')) {
      dve = limpiarNumeroRegulatorio(rawDivVer);
    }
  }

  return (cca, dve);
}

/// Extrae el Número CCA limpio desde la orden o cualquiera de sus JSONs anidados.
String extraerNumeroCca(Map<String, dynamic> orden) => extraerCcaDve(orden).$1;

/// Extrae el Número DVE (Dictamen de Verificación) limpio desde la orden o cualquiera de sus JSONs anidados.
String extraerNumeroDve(Map<String, dynamic> orden) => extraerCcaDve(orden).$2;

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

/// Construye la línea estructurada de especificaciones del instrumento sin el folio:
///   `Marca · Modelo · SN: {serie} · ID: {idEquipo} · Ubic: {ubicacion}`
/// omitiendo vacíos o placeholders ('sin id', 'sin modelo', 'sin serie', etc.).
String construirEspecificacionesInstrumento(Map<String, dynamic> orden) {
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

  final marca = pickField(['marca', 'equipo_marca', 'indicador_marca']);
  final modelo = pickField(['modelo', 'equipo_modelo', 'indicador_modelo']);
  final serie = pickField(['serie', 'ns', 'numero_serie']);
  final idEquipo = pickField(['id_indicador', 'id_equipo', 'indicador_id', 'id_interno', 'tag']);
  final ubicacion = pickField(['ubicacion', 'ubicacion_equipo', 'area']);

  final partes = <String>[];
  if (marca.isNotEmpty) partes.add(marca);
  if (modelo.isNotEmpty) partes.add(modelo);
  if (serie.isNotEmpty) partes.add('SN: $serie');
  if (idEquipo.isNotEmpty) partes.add('ID: $idEquipo');
  if (ubicacion.isNotEmpty) partes.add('Ubic: $ubicacion');

  return partes.join(' · ');
}

/// Extrae los metadatos limpios de equipo y folios regulatorios de una orden
/// para garantizar que el servidor tenga los datos actualizados antes del correo.
Map<String, dynamic> extraerMetaCorreoOrden(Map<String, dynamic> orden) {
  const invalidos = {
    '', 'none', 'null', 'sin id', 'sin modelo', 'sin serie', 'sin marca',
    'n/a', 'na', '--', '-', 's-id', 's/id', 'por definir',
  };
  final dt = _extraerMapaDatosTecnicos(orden);

  String pick(List<String> keys) {
    for (final k in keys) {
      final v = (orden[k] ?? '').toString().trim();
      if (v.isNotEmpty && !invalidos.contains(v.toLowerCase())) return v;
    }
    for (final k in keys) {
      final v = (dt[k] ?? '').toString().trim();
      if (v.isNotEmpty && !invalidos.contains(v.toLowerCase())) return v;
    }
    return '';
  }

  final folio = (orden['folio'] ?? orden['folio_os'] ?? '').toString().trim();
  final marca = pick(['marca', 'equipo_marca', 'indicador_marca']);
  final modelo = pick(['modelo', 'equipo_modelo', 'indicador_modelo']);
  final idInd = pick(['id_indicador', 'id_equipo', 'indicador_id', 'no_identificacion', 'id_interno', 'tag']);
  final cca = extraerNumeroCca(orden);
  final dve = extraerNumeroDve(orden);

  return <String, dynamic>{
    'folio': folio,
    'folio_os': folio,
    if (marca.isNotEmpty) 'marca': marca,
    if (modelo.isNotEmpty) 'modelo': modelo,
    if (idInd.isNotEmpty) 'id_indicador': idInd,
    if (idInd.isNotEmpty) 'id_equipo': idInd,
    if (cca.isNotEmpty) 'numero_cca': cca,
    if (dve.isNotEmpty) 'numero_dve': dve,
  };
}

/// Construye la etiqueta dinámica de correo por equipo:
///   `FOLIO-MARCA-MODELO-ID-CCA-DVE`
/// incluyendo CCA, DVE o ambos si aplican, y omitiendo campos vacíos o placeholders.
String formatearLineaCorreoOrden(Map<String, dynamic> orden) {
  const invalidos = {
    '', 'none', 'null', 'sin id', 'sin modelo', 'sin serie', 'sin marca',
    'n/a', 'na', '--', '-', 's-id', 's/id', 'por definir',
  };
  final meta = extraerMetaCorreoOrden(orden);
  final partes = <String>[];

  final folio = (meta['folio'] ?? '').toString().trim();
  if (folio.isNotEmpty) partes.add(folio);

  for (final campo in ['marca', 'modelo', 'id_indicador']) {
    final val = (meta[campo] ?? '').toString().trim();
    if (val.isNotEmpty && !invalidos.contains(val.toLowerCase())) {
      partes.add(val);
    }
  }

  final cca = (meta['numero_cca'] ?? '').toString().trim();
  if (cca.isNotEmpty && !invalidos.contains(cca.toLowerCase())) {
    partes.add(cca.toUpperCase().startsWith('CCA') ? cca : 'CCA.$cca');
  }

  final dve = (meta['numero_dve'] ?? '').toString().trim();
  if (dve.isNotEmpty && !invalidos.contains(dve.toLowerCase())) {
    partes.add(dve.toUpperCase().startsWith('DVE') ? dve : 'DVE.$dve');
  }

  return partes.join('-');
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _nombreTipoDocumentoCorreo(List<String> folios) {
  final primero = folios.isNotEmpty ? folios.first.trim().toUpperCase() : '';
  if (primero.startsWith('OSOCC-')) return 'Diagnóstico de Celda de Carga';
  if (primero.startsWith('OSOB-')) return 'Inspección de Báscula';
  if (primero.startsWith('RMA-')) return 'Remisión de Material';
  if (primero.startsWith('RE-')) return 'Revisión de Báscula';
  if (primero.startsWith('LP-')) return 'Levantamiento de Proyecto';
  if (primero.startsWith('LV-')) return 'Levantamiento Metrológico';
  return 'Orden de Servicio';
}

int _compararFolioNaturalCorreo(String a, String b) {
  final reg = RegExp(r'(\d+|\D+)');
  final pa = reg.allMatches(a.toUpperCase()).map((m) => m.group(0)!).toList();
  final pb = reg.allMatches(b.toUpperCase()).map((m) => m.group(0)!).toList();
  final len = pa.length < pb.length ? pa.length : pb.length;
  for (int i = 0; i < len; i++) {
    final na = int.tryParse(pa[i]);
    final nb = int.tryParse(pb[i]);
    final cmp = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (cmp != 0) return cmp;
  }
  return pa.length.compareTo(pb.length);
}

/// Construye `(asunto, cuerpoHtml)` con el formato institucional minimalista de Básculas PESA:
/// - Asunto individual: `Orden de Servicio OS-26-810 - Sika Mexicana | Básculas PESA`
/// - Asunto lote (2+):  `Orden de Servicio OS-26-810 a OS-26-811 - Sika Mexicana | Básculas PESA`
/// - Tabla HTML dinámica: columnas fijas `#` | `ID` (solo folio) | `Marca` | `Modelo` | `ID / Equipo`,
///   columnas `CCA` y `DVE` condicionales (ocultas si ninguna orden tiene dato) y celdas vacías en blanco `""`.
(String, String) armarCorreoInstitucional(
  List<Map<String, dynamic>> ordenes,
  String cliente, {
  bool? esLote,
}) {
  final porFolio = <String, Map<String, String>>{};
  final sinFolio = <Map<String, String>>[];

  for (final o in ordenes) {
    final meta = extraerMetaCorreoOrden(o);
    final codigo = formatearLineaCorreoOrden(o);
    final folio = (meta['folio'] ?? '').toString().trim();
    if (codigo.isEmpty && folio.isEmpty) continue;
    final (ccaRaw, dveRaw) = extraerCcaDve(o);
    final ccaFmt = ccaRaw.isNotEmpty
        ? (ccaRaw.toUpperCase().startsWith('CCA') ? ccaRaw : 'CCA.$ccaRaw')
        : '';
    final dveFmt = dveRaw.isNotEmpty
        ? (dveRaw.toUpperCase().startsWith('DVE') ? dveRaw : 'DVE.$dveRaw')
        : '';
    final item = <String, String>{
      'folio': folio,
      'codigo': codigo,
      'marca': (meta['marca'] ?? '').toString().trim(),
      'modelo': (meta['modelo'] ?? '').toString().trim(),
      'id_indicador': (meta['id_indicador'] ?? '').toString().trim(),
      'cca': ccaFmt,
      'dve': dveFmt,
    };
    if (folio.isEmpty) {
      sinFolio.add(item);
    } else {
      final fk = folio.toUpperCase();
      if (!porFolio.containsKey(fk) || codigo.length > (porFolio[fk]!['codigo']?.length ?? 0)) {
        porFolio[fk] = item;
      }
    }
  }

  final ordenadas = porFolio.values.toList()
    ..sort((a, b) => _compararFolioNaturalCorreo(a['folio'] ?? '', b['folio'] ?? ''));
  final filas = <Map<String, String>>[...ordenadas, ...sinFolio];
  final folios = filas
      .map((f) => (f['folio'] ?? '').trim())
      .where((s) => s.isNotEmpty)
      .toList();

  final clienteLimpio = cliente.replaceAll(RegExp(r'[\r\n]+'), ' ').trim().isEmpty
      ? 'Cliente'
      : cliente.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  final clienteEsc = _escapeHtml(clienteLimpio);
  final n = filas.length;
  final loteFlag = esLote ?? (n > 1);
  final tipoTitulo = _nombreTipoDocumentoCorreo(folios);

  final String asunto;
  if (folios.length == 1) {
    asunto = '$tipoTitulo ${folios.first} - $clienteLimpio | Básculas PESA';
  } else if (folios.length >= 2) {
    asunto = '$tipoTitulo ${folios.first} a ${folios.last} - $clienteLimpio | Básculas PESA';
  } else {
    asunto = '$tipoTitulo - $clienteLimpio | Básculas PESA';
  }

  final introHtml = (n > 1 || loteFlag)
      ? 'Hacemos entrega de los reportes digitales correspondientes al <strong>Lote de Servicios ($n ${n == 1 ? "orden" : "órdenes"})</strong>:'
      : 'Hacemos entrega del reporte digital correspondiente al servicio realizado:';
  final cierreHtml = (n > 1 || loteFlag)
      ? 'Adjunto a este correo encontrará cada uno de los certificados y reportes en formato PDF con sus respectivas firmas digitales.'
      : 'Adjunto a este correo encontrará el certificado y reporte en formato PDF con sus respectivas firmas digitales.';

  final bool tieneCca = filas.any((f) => (f['cca'] ?? '').trim().isNotEmpty);
  final bool tieneDve = filas.any((f) => (f['dve'] ?? '').trim().isNotEmpty);

  const thStyle =
      'border: 1px solid #E2E8F0; padding: 9px 12px; background-color: #F8FAFC; color: #0F172A; font-weight: 700; font-size: 12px; text-align: left;';
  const tdBase =
      'border: 1px solid #E2E8F0; padding: 8px 12px; font-size: 12.5px; color: #0F172A; vertical-align: middle;';

  final thCcaHtml = tieneCca ? '<th style="$thStyle text-align: center;">CCA</th>' : '';
  final thDveHtml = tieneDve ? '<th style="$thStyle text-align: center;">DVE</th>' : '';

  final trBuf = StringBuffer();
  for (int i = 0; i < filas.length; i++) {
    final f = filas[i];
    final idx = i + 1;
    final bg = idx.isOdd ? '#FFFFFF' : '#F8FAFC';
    final folioEsc = _escapeHtml(f['folio'] ?? '');
    final marcaEsc = (f['marca'] ?? '').isNotEmpty ? _escapeHtml(f['marca']!) : '';
    final modeloEsc = (f['modelo'] ?? '').isNotEmpty ? _escapeHtml(f['modelo']!) : '';
    final idEsc = (f['id_indicador'] ?? '').isNotEmpty ? _escapeHtml(f['id_indicador']!) : '';

    final tdCcaHtml = tieneCca
        ? '<td style="$tdBase text-align: center;">${(f['cca'] ?? '').isNotEmpty ? '<span style="display:inline-block; background-color:#EEF2FF; color:#3730A3; border:1px solid #C7D2FE; border-radius:4px; padding:2px 6px; font-weight:700; font-size:11.5px;">${_escapeHtml(f['cca']!)}</span>' : ''}</td>'
        : '';
    final tdDveHtml = tieneDve
        ? '<td style="$tdBase text-align: center;">${(f['dve'] ?? '').isNotEmpty ? '<span style="display:inline-block; background-color:#ECFDF5; color:#065F46; border:1px solid #A7F3D0; border-radius:4px; padding:2px 6px; font-weight:700; font-size:11.5px;">${_escapeHtml(f['dve']!)}</span>' : ''}</td>'
        : '';

    trBuf.writeln(
      '<tr style="background-color: $bg;">'
      '<td style="$tdBase text-align: center; font-weight: 700; width: 36px; color: #475569;">$idx</td>'
      '<td style="$tdBase font-weight: 700; color: #C8102E; white-space: nowrap;">$folioEsc</td>'
      '<td style="$tdBase">$marcaEsc</td>'
      '<td style="$tdBase">$modeloEsc</td>'
      '<td style="$tdBase">$idEsc</td>'
      '$tdCcaHtml'
      '$tdDveHtml'
      '</tr>',
    );
  }

  final html = '''
<html>
<body style="font-family: 'Segoe UI', Inter, Arial, sans-serif; color: #0F172A; line-height: 1.5; margin: 0; padding: 16px; background-color: #F8FAFC;">
  <div style="max-width: 880px; margin: 0 auto; background-color: #FFFFFF; border-radius: 8px; overflow: hidden; border: 1px solid #E2E8F0;">
    <div style="background-color: #C8102E; padding: 18px 24px; text-align: left;">
      <h1 style="color: #FFFFFF; margin: 0; font-size: 21px; font-weight: 700; letter-spacing: 0.2px;">Básculas PESA</h1>
    </div>
    <div style="padding: 24px; background-color: #FFFFFF;">
      <p style="margin-top: 0; font-size: 14.5px; color: #0F172A;">Estimado cliente <strong>$clienteEsc</strong>,</p>
      <p style="font-size: 14px; color: #475569;">$introHtml</p>
      <div style="overflow-x: auto; margin: 18px 0;">
        <table style="border-collapse: collapse; width: 100%; border: 1px solid #E2E8F0;">
          <thead>
            <tr>
              <th style="$thStyle text-align: center; width: 36px;">#</th>
              <th style="$thStyle">ID</th>
              <th style="$thStyle">Marca</th>
              <th style="$thStyle">Modelo</th>
              <th style="$thStyle">ID / Equipo</th>
              $thCcaHtml
              $thDveHtml
            </tr>
          </thead>
          <tbody>
            ${trBuf.toString()}
          </tbody>
        </table>
      </div>
      <p style="font-size: 14px; color: #475569;">$cierreHtml</p>
      <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 24px 0;">
      <p style="font-size: 12px; color: #64748B; margin: 0;">
        Este es un correo automático emitido por el sistema institucional de Básculas PESA.<br>
        Para cualquier aclaración o seguimiento, favor de responder con copia a
        <a href="mailto:recepcion@basculaspesa.com.mx" style="color: #C8102E; text-decoration: none; font-weight: 600;">recepcion@basculaspesa.com.mx</a>.
      </p>
    </div>
  </div>
</body>
</html>
''';
  return (asunto, html);
}

/// Convierte cualquier valor de fecha/hora (ISO UTC de Render, ISO con offset o DateTime)
/// a hora local de México/Querétaro (`UTC-6`, `America/Mexico_City`) en formato `DD/MM/YYYY HH:mm`.
String formatearFechaHoraMexico(dynamic rawVal) {
  if (rawVal == null) return '';
  if (rawVal is DateTime) {
    final mx = rawVal.toUtc().subtract(const Duration(hours: 6));
    final dd = mx.day.toString().padLeft(2, '0');
    final mm = mx.month.toString().padLeft(2, '0');
    final yyyy = mx.year.toString().padLeft(4, '0');
    final hh = mx.hour.toString().padLeft(2, '0');
    final min = mx.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }
  final s = rawVal.toString().trim();
  if (s.isEmpty || s.toLowerCase() == 'null' || s.toLowerCase() == 'none') {
    return '';
  }
  if (RegExp(r'^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}$').hasMatch(s)) {
    return s;
  }
  try {
    final norm = s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    final hasExplicitTz = norm.endsWith('Z') ||
        norm.endsWith('z') ||
        RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(norm);
    if (hasExplicitTz) {
      final dt = DateTime.tryParse(norm);
      if (dt != null) {
        final mx = dt.toUtc().subtract(const Duration(hours: 6));
        final dd = mx.day.toString().padLeft(2, '0');
        final mm = mx.month.toString().padLeft(2, '0');
        final yyyy = mx.year.toString().padLeft(4, '0');
        final hh = mx.hour.toString().padLeft(2, '0');
        final min = mx.minute.toString().padLeft(2, '0');
        return '$dd/$mm/$yyyy $hh:$min';
      }
    } else {
      final dtLocal = DateTime.tryParse(norm);
      if (dtLocal != null) {
        final dd = dtLocal.day.toString().padLeft(2, '0');
        final mm = dtLocal.month.toString().padLeft(2, '0');
        final yyyy = dtLocal.year.toString().padLeft(4, '0');
        final hh = dtLocal.hour.toString().padLeft(2, '0');
        final min = dtLocal.minute.toString().padLeft(2, '0');
        return '$dd/$mm/$yyyy $hh:$min';
      }
    }
  } catch (_) {}
  return s;
}

/// Retorna `true` si la orden registra envío de correo confirmado.
bool esCorreoEnviadoOrden(Map<String, dynamic> orden) {
  for (final k in ['correo_enviado', 'email_enviado']) {
    final v = orden[k];
    if (v == 1 || v == true || v == '1' || v == 'true' || v == 'TRUE') {
      return true;
    }
  }
  for (final fk in ['fecha_envio_correo', 'fecha_envio_email']) {
    final fv = (orden[fk] ?? '').toString().trim();
    if (fv.isNotEmpty && fv.toLowerCase() != 'null' && fv.toLowerCase() != 'none') {
      return true;
    }
  }
  return false;
}

bool _esCorreoDestinoValido(String cand) {
  final c = cand.trim();
  if (c.isEmpty) return false;
  final low = c.toLowerCase();
  if (low == 'null' ||
      low == 'none' ||
      low == 'cliente' ||
      low == 'sin registrar' ||
      low == 'destinatario registrado' ||
      low == '-' ||
      low == '—') {
    return false;
  }
  return c.contains('@');
}

/// Construye la etiqueta institucional de trazabilidad de envío de correo:
///   `Enviado el DD/MM/YYYY HH:mm | Para: correo@cliente.com | CC: recepcion@basculaspesa.com.mx`
String formatearInfoEnvioCorreo(Map<String, dynamic> orden) {
  if (!esCorreoEnviadoOrden(orden)) return '';

  String destino = '';
  for (final k in ['correo_destino', 'correo_cliente', 'email_cliente']) {
    final cand = (orden[k] ?? '').toString().trim();
    if (_esCorreoDestinoValido(cand)) {
      destino = cand;
      break;
    }
  }

  String cc = (orden['correo_cc'] ?? '').toString().trim();
  if (cc.isEmpty || cc.toLowerCase() == 'null' || cc.toLowerCase() == 'none') {
    cc = 'recepcion@basculaspesa.com.mx';
  }

  final fechaTxt = formatearFechaHoraMexico(
    orden['fecha_envio_correo'] ?? orden['fecha_envio_email'],
  );

  if (fechaTxt.isNotEmpty && destino.isNotEmpty) {
    return 'Enviado el $fechaTxt | Para: $destino | CC: $cc';
  }
  if (fechaTxt.isNotEmpty) {
    return 'Enviado el $fechaTxt | CC: $cc';
  }
  if (destino.isNotEmpty) {
    return 'Enviado | Para: $destino | CC: $cc';
  }
  return 'Enviado | CC: $cc';
}

/// Construye la etiqueta de trazabilidad de correo para la cabecera de un lote.
String formatearInfoEnvioCorreoLote(List<Map<String, dynamic>> items) {
  if (items.isEmpty) return '';
  final enviados = items.where(esCorreoEnviadoOrden).toList();
  if (enviados.isEmpty) return '';

  String destino = '';
  dynamic fechaRaw;
  String cc = 'recepcion@basculaspesa.com.mx';

  for (final o in enviados) {
    if (destino.isEmpty) {
      for (final k in ['correo_destino', 'correo_cliente', 'email_cliente']) {
        final cand = (o[k] ?? '').toString().trim();
        if (_esCorreoDestinoValido(cand)) {
          destino = cand;
          break;
        }
      }
    }
    final candFecha = o['fecha_envio_correo'] ?? o['fecha_envio_email'];
    if (candFecha != null && candFecha.toString().trim().isNotEmpty) {
      fechaRaw = candFecha;
    }
    final candCc = (o['correo_cc'] ?? '').toString().trim();
    if (candCc.isNotEmpty && candCc.toLowerCase() != 'null' && candCc.toLowerCase() != 'none') {
      cc = candCc;
    }
  }

  if (destino.isEmpty) {
    for (final o in items) {
      for (final k in ['correo_destino', 'correo_cliente', 'email_cliente']) {
        final cand = (o[k] ?? '').toString().trim();
        if (_esCorreoDestinoValido(cand)) {
          destino = cand;
          break;
        }
      }
      if (destino.isNotEmpty) break;
    }
  }

  final base = formatearInfoEnvioCorreo({
    'correo_enviado': 1,
    'correo_destino': destino,
    'correo_cc': cc,
    'fecha_envio_correo': fechaRaw,
  });
  if (base.isEmpty) return '';
  if (enviados.length < items.length) {
    return base.replaceFirst('Enviado', 'Enviado (${enviados.length}/${items.length} OS)');
  }
  return base;
}




