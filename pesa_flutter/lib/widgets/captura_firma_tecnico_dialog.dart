// lib/widgets/captura_firma_tecnico_dialog.dart
// Diálogo modal corporativo para captura y persistencia confiable de firma digital del técnico.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/sync_service.dart';
import '../theme/pesa_theme.dart';
import 'signature_shield.dart';

class CapturFirmaTecnicoDialog extends StatefulWidget {
  final String username;
  final String nombreCompleto;
  final int idTecnico; // 0 = guarda local únicamente si no existe perfil remoto
  final bool permitirCancelar;
  final bool sincronizarServidor;

  const CapturFirmaTecnicoDialog({
    super.key,
    required this.username,
    required this.nombreCompleto,
    this.idTecnico = 0,
    this.permitirCancelar = false,
    this.sincronizarServidor = true,
  });

  /// Captura la firma en un modal reutilizable y retorna los bytes PNG exportados
  /// (mínimo 480x192px transparente), o null si el usuario cancela.
  static Future<Uint8List?> capturarBytes(
    BuildContext context, {
    required String username,
    required String nombreCompleto,
    int idTecnico = 0,
    bool permitirCancelar = true,
    bool sincronizarServidor = true,
  }) async {
    return showDialog<Uint8List?>(
      context: context,
      barrierDismissible: permitirCancelar,
      builder: (_) => PopScope(
        canPop: permitirCancelar,
        child: CapturFirmaTecnicoDialog(
          username: username,
          nombreCompleto: nombreCompleto,
          idTecnico: idTecnico,
          permitirCancelar: permitirCancelar,
          sincronizarServidor: sincronizarServidor,
        ),
      ),
    );
  }

  /// Muestra el diálogo (opcional o bloqueante) y retorna true si la firma
  /// se capturó, validó y persistió sin error.
  static Future<bool> mostrar(
    BuildContext context, {
    required String username,
    required String nombreCompleto,
    int idTecnico = 0,
    bool permitirCancelar = false,
  }) async {
    final res = await capturarBytes(
      context,
      username: username,
      nombreCompleto: nombreCompleto,
      idTecnico: idTecnico,
      permitirCancelar: permitirCancelar,
      sincronizarServidor: true,
    );
    return res != null && res.isNotEmpty;
  }

  /// Muestra el diálogo bloqueante tras login y sincroniza con Render.
  static Future<bool> mostrarConSync(
    BuildContext context, {
    required String username,
    required String nombreCompleto,
    required int idTecnico,
    bool permitirCancelar = false,
  }) async {
    final res = await capturarBytes(
      context,
      username: username,
      nombreCompleto: nombreCompleto,
      idTecnico: idTecnico,
      permitirCancelar: permitirCancelar,
      sincronizarServidor: true,
    );
    return res != null && res.isNotEmpty;
  }

  @override
  State<CapturFirmaTecnicoDialog> createState() =>
      _CapturFirmaTecnicoDialogState();
}

class _CapturFirmaTecnicoDialogState extends State<CapturFirmaTecnicoDialog> {
  final SignatureController _ctrl = SignatureController(
    penStrokeWidth: 3.2,
    penColor: PesaColors.textPrimary,
    exportPenColor: PesaColors.textPrimary,
    exportBackgroundColor: Colors.transparent,
  );
  bool _saving = false;
  String? _errorMsg;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onGuardar() async {
    if (_saving) return;
    if (_ctrl.isEmpty || _ctrl.points.length < 2) {
      setState(() {
        _errorMsg = 'Traza tu firma completa sobre la línea guía antes de guardar.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _errorMsg = null;
    });

    try {
      Uint8List? pngBytes = await _ctrl.toPngBytes(width: 560, height: 220);
      pngBytes ??= await _ctrl.toPngBytes();
      if (pngBytes == null || pngBytes.lengthInBytes < 64) {
        throw Exception('No se pudo exportar el lienzo de firma como PNG.');
      }

      final base64Firma = base64Encode(pngBytes);

      // 1. Persistencia local garantizada en dispositivo + BD local
      await FirmaTecnicoService.instance.saveFirma(
        widget.username,
        base64Firma,
        idTecnico: widget.idTecnico,
      );

      // 2. Persistencia en PostgreSQL / Render cuando hay sesión + idTecnico
      bool syncWarning = false;
      String? syncDetail;
      if (widget.sincronizarServidor &&
          widget.idTecnico > 0 &&
          ApiService.instance.isAuthenticated) {
        try {
          await ApiService.instance.guardarFirmaPerfil(
            widget.idTecnico,
            base64Firma,
          );
        } catch (e) {
          syncWarning = true;
          syncDetail = e.toString().replaceFirst('Exception: ', '');
          debugPrint('[FirmaDialog] Error sync servidor: $syncDetail');
        }
      }

      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop<Uint8List>(pngBytes);

      messenger?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: syncWarning ? PesaColors.dotAmber : PesaColors.textPrimary,
          content: Text(
            syncWarning
                ? 'Firma guardada en el dispositivo; pendiente sincronizar con servidor ($syncDetail)'
                : 'Firma guardada correctamente',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          context.read<SyncService>().performSync();
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = widget.nombreCompleto.trim().isNotEmpty
        ? widget.nombreCompleto.trim()
        : widget.username;

    return Dialog(
      backgroundColor: PesaColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: PesaColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: PesaColors.brand,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.draw_outlined, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Firma Digital del Técnico',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: PesaColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: PesaColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.permitirCancelar && !_saving)
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop<Uint8List?>(null),
                      icon: const Icon(Icons.close, color: PesaColors.textSecondary),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: PesaColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: PesaColors.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_user_outlined, color: PesaColors.brand, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Esta firma se inserta automáticamente en tus órdenes de servicio y PDFs oficiales.',
                        style: TextStyle(
                          fontSize: 12,
                          color: PesaColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Traza tu firma en el recuadro',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: PesaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) {
                  final hasInk = _ctrl.isNotEmpty;
                  return Container(
                    height: 196,
                    decoration: BoxDecoration(
                      color: PesaColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: hasInk ? PesaColors.brand : PesaColors.borderStrong,
                        width: hasInk ? 1.5 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          IgnorePointer(
                            child: CustomPaint(painter: _GuideLinePainter()),
                          ),
                          SignatureGestureShield(
                            child: Signature(
                              controller: _ctrl,
                              backgroundColor: Colors.transparent,
                            ),
                          ),
                          if (!hasInk)
                            const IgnorePointer(
                              child: Center(
                                child: Text(
                                  'Firme sobre la línea',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: PesaColors.textTertiary,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (_errorMsg != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF5F6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: PesaColors.brand),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: PesaColors.brand, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMsg!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: PesaColors.brand,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                  _ctrl.clear();
                                  _errorMsg = null;
                                }),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Limpiar'),
                      ),
                    ),
                  ),
                  if (widget.permitirCancelar) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop<Uint8List?>(null),
                          child: const Text('Cancelar'),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: PesaColors.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _saving ? null : _onGuardar,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_rounded, size: 18),
                        label: Text(
                          _saving ? 'Guardando...' : 'Guardar Firma',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = PesaColors.border
      ..strokeWidth = 1.0;
    final y = size.height * 0.74;
    canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
