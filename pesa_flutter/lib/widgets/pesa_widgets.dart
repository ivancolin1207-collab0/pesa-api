// lib/widgets/pesa_widgets.dart
// Punto único de exportación e instanciación de componentes corporativos Básculas PESA.
export 'pesa_components.dart';
export 'captura_firma_tecnico_dialog.dart';

import 'package:flutter/material.dart';
import '../theme/pesa_theme.dart';
import 'captura_firma_tecnico_dialog.dart';
import 'pesa_components.dart';

typedef PesaSignatureModal = CapturFirmaTecnicoDialog;
typedef PesaStatusDot = PesaSemanticDot;

/// Campo de entrada corporativo estandarizado (>= 48dp táctil, radio 8dp).
class PesaInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final int maxLines;

  const PesaInput({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
    this.validator,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      validator: validator,
      maxLines: maxLines,
      style: const TextStyle(fontSize: 14, color: PesaColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
      ),
    );
  }
}

/// Toast flotante corporativo uniforme Básculas PESA.
class PesaToast {
  PesaToast._();

  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? PesaColors.brand : PesaColors.textPrimary,
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
