// lib/screens/pdf_preview_aprobacion_screen.dart
// Pantalla obligatoria de Vista Previa del PDF (Sin Firma del Cliente)
// Estándar Apple Minimalista Industrial Básculas PESA — Claro / Oscuro + Z Fold8 Ultra.
// El PDF se renderiza siempre como hoja blanca con tinta negra rodeado por el canvas del tema (#121214 en oscuro).

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../theme/pesa_theme.dart';

class PdfPreviewAprobacionScreen extends StatelessWidget {
  final String folio;
  final Uint8List pdfBytes;
  final String? tipoDocumento;
  final String? subtitulo;
  final Widget? customPreviewBody;

  const PdfPreviewAprobacionScreen({
    super.key,
    required this.folio,
    required this.pdfBytes,
    this.tipoDocumento,
    this.subtitulo,
    this.customPreviewBody,
  });

  static Future<bool> mostrar(
    BuildContext context, {
    required String folio,
    required Uint8List pdfBytes,
    String? tipoDocumento,
    String? subtitulo,
  }) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => PdfPreviewAprobacionScreen(
          folio: folio,
          pdfBytes: pdfBytes,
          tipoDocumento: tipoDocumento,
          subtitulo: subtitulo,
        ),
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final screenW = MediaQuery.of(context).size.width;
    final isCompact = screenW < 540;
    final cleanFolio = folio.trim().isEmpty ? 'BORRADOR' : folio.trim();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pop(false);
        }
      },
      child: Scaffold(
        backgroundColor: c.canvas,
        appBar: AppBar(
          backgroundColor: c.surface,
          foregroundColor: c.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          toolbarHeight: isCompact ? 64 : 60,
          leading: IconButton(
            tooltip: 'Volver a corregir',
            icon: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: c.textPrimary),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          titleSpacing: 4,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Vista Previa para Revisión del Cliente — $cleanFolio',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isCompact ? 14 : 15.5,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.surfaceMuted,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: c.borderStrong, width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 6,
                          height: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.dotAmber,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Sin firma del cliente',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (tipoDocumento != null && tipoDocumento!.trim().isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        tipoDocumento!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, thickness: 1, color: c.border),
          ),
        ),
        body: Column(
          children: [
            // Banner informativo sobrio
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 14 : 24,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(
                  bottom: BorderSide(color: c.border, width: 1),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.verified_user_outlined,
                      size: 16,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      subtitulo?.trim().isNotEmpty == true
                          ? subtitulo!.trim()
                          : 'Revisa las pruebas, resultados y datos del instrumento con el cliente. '
                              'Al confirmar conformidad pasarás a validar el correo y recabar su firma para emitir el PDF final.',
                      style: TextStyle(
                        fontSize: isCompact ? 12 : 12.5,
                        color: c.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Visor interactivo del PDF (hoja blanca rodeada por canvas #121214 en oscuro)
            Expanded(
              child: customPreviewBody ??
                  PdfPreview(
                    build: (format) async => pdfBytes,
                    useActions: false,
                    allowPrinting: false,
                    allowSharing: false,
                    canChangeOrientation: false,
                    canChangePageFormat: false,
                    canDebug: false,
                    pdfFileName: '${cleanFolio}_VISTA_PREVIA_SIN_FIRMA.pdf',
                    loadingWidget: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: c.brandAccent),
                          const SizedBox(height: 12),
                          Text(
                            'Preparando vista previa del documento...',
                            style: TextStyle(
                              fontSize: 13,
                              color: c.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    scrollViewDecoration: BoxDecoration(color: c.canvas),
                  ),
            ),

            // Barra inferior fija con 2 acciones claras (>= 48dp touch targets)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(
                  top: BorderSide(color: c.border, width: 1),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 14 : 24,
                    vertical: 12,
                  ),
                  child: isCompact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildAprobarButton(context, c),
                            const SizedBox(height: 8),
                            _buildVolverButton(context, c),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: _buildVolverButton(context, c),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: _buildAprobarButton(context, c),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVolverButton(BuildContext context, PesaPalette c) {
    return SizedBox(
      height: 50,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.of(context).pop(false),
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text(
          'Volver a Corregir',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          backgroundColor: c.isDark ? c.surfaceElevated : c.surface,
          side: BorderSide(color: c.borderStrong, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );
  }

  Widget _buildAprobarButton(BuildContext context, PesaPalette c) {
    return SizedBox(
      height: 50,
      child: ElevatedButton.icon(
        onPressed: () => Navigator.of(context).pop(true),
        icon: const Icon(Icons.draw_outlined, size: 18),
        label: const Text(
          'Estoy de Acuerdo — Pasar a Firmar',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: c.brand,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      ),
    );
  }
}
