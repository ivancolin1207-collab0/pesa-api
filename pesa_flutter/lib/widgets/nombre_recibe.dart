// lib/widgets/nombre_recibe.dart — Regla universal: el nombre de quien recibe es obligatorio
// en TODOS los formatos (OS, Remisiones RMA, Levantamientos LP/LV, Revisiones).
// La firma del cliente es opcional (puede no poder firmar en pantalla).
import 'package:flutter/material.dart';

const String kMsgNombreRecibeObligatorio = 'Debe ingresar el nombre del responsable que recibe';

/// Validador para TextFormField: mínimo 3 caracteres y no debe ser razón social.
String? validarNombreRecibe(String? v) {
  final t = (v ?? '').trim();
  if (t.isEmpty || t.length < 3) return kMsgNombreRecibeObligatorio;
  if (esRazonSocialEmpresa(t)) {
    return 'Debe ser el nombre de una persona, no la razón social de la empresa';
  }
  return null;
}

/// Devuelve true si el nombre es válido; si no, muestra el aviso y devuelve false.
bool exigirNombreRecibe(BuildContext context, String nombreRecibe, {String? clienteEmpresa}) {
  final t = nombreRecibe.trim();
  if (t.isEmpty || t.length < 3) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('⚠️ Es obligatorio ingresar el nombre de la persona que recibe el servicio.'),
        backgroundColor: Colors.redAccent,
      ),
    );
    return false;
  }
  if (esRazonSocialEmpresa(t, clienteEmpresa)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('⚠️ Ingrese el nombre de la persona que recibe (Ingeniero / Responsable), no la razón social de la empresa.'),
        backgroundColor: Colors.redAccent,
      ),
    );
    return false;
  }
  return true;
}

/// Verifica si un texto corresponde a una razón social o empresa en lugar de persona
bool esRazonSocialEmpresa(String? texto, [String? clienteEmpresa]) {
  if (texto == null) return false;
  final t = texto.trim().toLowerCase();
  if (t.isEmpty) return false;
  if (clienteEmpresa != null && clienteEmpresa.trim().isNotEmpty) {
    final c = clienteEmpresa.trim().toLowerCase();
    if (t == c || c.contains(t) || t.contains(c)) return true;
  }
  return t.contains('s.a.') ||
         t.contains('de c.v.') ||
         t.contains('s. de r.l.') ||
         t.contains('s de rl') ||
         t.contains('sociedad anonima') ||
         t.contains('corporativo') ||
         t.contains('industrial') ||
         t.contains('s.a.p.i.');
}

/// Memoria de sesión en lotes para reutilizar el responsable en órdenes hermanas con 1 toque
class LoteSession {
  static final Map<String, String> _ultimoResponsablePorLote = {};
  static final Map<String, String> _ultimoPuestoPorLote = {};

  static String? getUltimoResponsable(String? loteId) {
    if (loteId == null || loteId.trim().isEmpty) return null;
    return _ultimoResponsablePorLote[loteId.trim()];
  }

  static String? getUltimoPuesto(String? loteId) {
    if (loteId == null || loteId.trim().isEmpty) return null;
    return _ultimoPuestoPorLote[loteId.trim()];
  }

  static void registrarResponsable(String? loteId, String nombre, {String? puesto}) {
    if (loteId == null || loteId.trim().isEmpty || nombre.trim().isEmpty) return;
    _ultimoResponsablePorLote[loteId.trim()] = nombre.trim();
    if (puesto != null && puesto.trim().isNotEmpty) {
      _ultimoPuestoPorLote[loteId.trim()] = puesto.trim();
    }
  }
}
