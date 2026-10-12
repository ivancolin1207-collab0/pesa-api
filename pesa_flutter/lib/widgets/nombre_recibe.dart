// lib/widgets/nombre_recibe.dart — Regla universal: el nombre de quien recibe es obligatorio
// en TODOS los formatos (OS, Remisiones RMA, Levantamientos LP/LV, Revisiones).
// La firma del cliente es opcional (puede no poder firmar en pantalla).
import 'package:flutter/material.dart';

const String kMsgNombreRecibeObligatorio = 'Debe ingresar el nombre del responsable que recibe';

/// Validador para TextFormField: mínimo 3 caracteres.
String? validarNombreRecibe(String? v) {
  final t = (v ?? '').trim();
  if (t.isEmpty || t.length < 3) return kMsgNombreRecibeObligatorio;
  return null;
}

/// Devuelve true si el nombre es válido; si no, muestra el aviso y devuelve false.
bool exigirNombreRecibe(BuildContext context, String nombreRecibe) {
  if (validarNombreRecibe(nombreRecibe) == null) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('⚠️ Es obligatorio ingresar el nombre de la persona que recibe el servicio.'),
      backgroundColor: Colors.redAccent,
    ),
  );
  return false;
}
