// lib/widgets/captura_firma_tecnico_dialog.dart
// Diálogo modal para captura de firma del técnico (una sola vez al iniciar sesión).
// Se muestra automáticamente tras login exitoso si el técnico no tiene firma guardada.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';
import '../services/firma_tecnico_service.dart';
import '../services/sync_service.dart';
import 'package:provider/provider.dart';

class CapturFirmaTecnicoDialog extends StatefulWidget {
  final String username;
  final String nombreCompleto;
  final int    idTecnico;   // 0 = no disponible, solo guarda local

  const CapturFirmaTecnicoDialog({
    super.key,
    required this.username,
    required this.nombreCompleto,
    this.idTecnico = 0,
  });

  /// Muestra el diálogo y retorna true si la firma fue guardada exitosamente.
  /// Si el usuario cancela, retorna false. SOLO guarda localmente.
  static Future<bool> mostrar(
    BuildContext context, {
    required String username,
    required String nombreCompleto,
    int idTecnico = 0,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // No se puede cerrar sin firmar
      builder: (_) => CapturFirmaTecnicoDialog(
        username: username,
        nombreCompleto: nombreCompleto,
        idTecnico: idTecnico,
      ),
    );
    return result ?? false;
  }

  /// Muestra el diálogo BLOQUEANTE y sincroniza la firma al servidor Render.
  /// El técnico NO puede pasar al dashboard sin trazar su firma.
  /// [idTecnico] es el ID en cat_tecnicos (del JWT). Si es 0, solo guarda local.
  static Future<bool> mostrarConSync(
    BuildContext context, {
    required String username,
    required String nombreCompleto,
    required int    idTecnico,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // BLOQUEANTE: no se puede saltar
      builder: (_) => CapturFirmaTecnicoDialog(
        username:       username,
        nombreCompleto: nombreCompleto,
        idTecnico:      idTecnico,
      ),
    );
    return result ?? false;
  }

  @override
  State<CapturFirmaTecnicoDialog> createState() =>
      _CapturFirmaTecnicoDialogState();
}

class _CapturFirmaTecnicoDialogState extends State<CapturFirmaTecnicoDialog> {
  final _ctrl = SignatureController(
    penStrokeWidth: 3,
    penColor: const Color(0xFF1D1D1F),
  );
  bool _saving = false;

  static const _red = Color(0xFFC8102E);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onGuardar() async {
    if (_ctrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor dibuja tu firma antes de continuar'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final Uint8List? pngBytes = await _ctrl.toPngBytes();
      if (pngBytes != null) {
        final base64Firma = base64Encode(pngBytes);
        // Guardar local + sincronizar al servidor si hay idTecnico válido
        if (widget.idTecnico > 0) {
          final ok = await FirmaTecnicoService.instance.saveAndSyncFirma(
            widget.username,
            base64Firma,
            widget.idTecnico,
          );
          debugPrint('[FirmaDialog] Sync al servidor: ${ok ? "OK" : "Solo local"}');
          // [FIX] Mostrar error si el servidor no pudo guardar la firma
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Firma guardada localmente, pero no se pudo sincronizar al servidor. '
                  'Verifica tu conexión e intenta de nuevo.',
                ),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 5),
              ),
            );
          }
        } else {
          await FirmaTecnicoService.instance.saveFirma(
            widget.username,
            base64Firma,
          );
        }
      }
      if (mounted) {
        Navigator.of(context).pop(true);
        // [FIX] Disparar sync automático para descargar órdenes inmediatamente
        // después de guardar la firma (el técnico ya está habilitado en el servidor).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            context.read<SyncService>().performSync();
            debugPrint('[FirmaDialog] Sync automatico post-firma iniciado');
          } catch (_) {}
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al guardar la firma: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Encabezado
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.draw, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Captura de Firma del Técnico',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      widget.nombreCompleto.isNotEmpty
                          ? widget.nombreCompleto
                          : widget.username,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),

            // Descripción
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, color: Colors.blue.shade700, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Esta firma se guardará y se usará automáticamente en todos '
                    'tus servicios. Solo necesitas firmar una vez.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),

            // Canvas de firma
            const Text(
              'Dibuja tu firma:',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(
                    color: _ctrl.isNotEmpty ? _red : Colors.grey.shade300,
                    width: _ctrl.isNotEmpty ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Stack(children: [
                    Signature(
                      controller: _ctrl,
                      backgroundColor: Colors.white,
                    ),
                    if (_ctrl.isEmpty)
                      const Center(
                        child: Text(
                          'Firme aquí con su dedo o lápiz',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFFD0D0D0),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Botón limpiar
            OutlinedButton.icon(
              onPressed: () => setState(_ctrl.clear),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Limpiar y volver a firmar'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 16),

            // Botón guardar
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _saving ? null : _onGuardar,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ))
                  : const Icon(Icons.save_outlined),
              label: Text(
                _saving ? 'Guardando...' : 'Guardar y Continuar',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
