// lib/screens/dashboard_screen.dart — Exportación y utilidades del Dashboard de Servicios PESA
export 'os_list_screen.dart';

/// Función auxiliar de normalización de cadenas (remover diacríticos/acentos y minúsculas)
String normalizarTexto(String texto) {
  var conAcentos = 'ÁÉÍÓÚáéíóúÀÈÌÒÙàèìòùÄËÏÖÜäëïöüÑñ';
  var sinAcentos = 'AEIOUaeiouAEIOUaeiouAEIOUaeiouNn';
  String resultado = texto.trim().toLowerCase();
  for (int i = 0; i < conAcentos.length; i++) {
    resultado = resultado.replaceAll(conAcentos[i], sinAcentos[i]);
  }
  return resultado;
}
