// lib/services/metrology_helper.dart
// Funciones auxiliares de cálculo y validación metrológica (OIML R 76 / NOM-010-SCFI)

/// Calcula el número de decimales adecuado a partir de la división mínima d.
int decimalsFromDivMin(double? d) {
  if (d == null || d <= 0) return 3;
  if (d >= 1) return 0;
  int dec = 0;
  double v = d;
  while (v < 1.0 && dec < 10) {
    v *= 10;
    dec++;
  }
  return dec;
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
  final dec = decimalsFromDivMin(d);
  return 'El valor debe ser múltiplo de la división mínima (ej. saltos de ${d.toStringAsFixed(dec)})';
}
