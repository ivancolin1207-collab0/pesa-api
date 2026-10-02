// lib/widgets/error_reporte_dialog.dart
// Diálogo amigable que se muestra al técnico cuando falla la captura digital
// en modalidad Híbrido. Reporta el error al servidor y ofrece continuar en papel.
import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// Muestra un diálogo amigable al técnico cuando falla la sincronización digital.
/// Reporta automáticamente el incidente al servidor (para auditoría de admin).
/// Retorna true si el técnico decide continuar en formato físico.
Future<bool> mostrarDialogoErrorTecnico(
  BuildContext context, {
  required String errorMensaje,
  required String folio,
  required String tecnico,
  String? stackTrace,
}) async {
  // Reportar al servidor en background (no bloquear UI)
  ApiService.instance.registrarErrorTecnico(
    errorMensaje: errorMensaje,
    folio: folio,
    tecnico: tecnico,
    stackTrace: stackTrace,
  ).then((ok) {
    debugPrint('[ErrorDialog] Reporte a servidor: ${ok ? "OK" : "FAIL"}');
  });

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Error en Captura Digital',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ocurrió un error al procesar la captura digital.',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            'Detalle técnico: $errorMensaje',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'El reporte técnico ha sido enviado automáticamente a Administración.',
                    style: TextStyle(fontSize: 12, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Puedes continuar llenando la orden en tu formato físico de respaldo.',
            style: TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Reintentar Digital'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade700,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Continuar en Papel'),
        ),
      ],
    ),
  );

  return result ?? false;
}
