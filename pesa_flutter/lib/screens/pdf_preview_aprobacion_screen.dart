// lib/screens/pdf_preview_aprobacion_screen.dart
// Pantalla obligatoria de Vista Previa del PDF (Sin Firma del Cliente)
// para revisión de pruebas, lecturas y resultados antes de confirmar correo y firmar.
// Estándar Apple Minimalista Industrial Básculas PESA — Responsive Z Fold8 Ultra.

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

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

  static const Color _kBgCanvas = Color(0xFFF5F5F7);
  static const Color _kSurface = Color(0xFFFFFFFF);
  static const Color _kTextPrimary = Color(0xFF1D1D1F);
  static const Color _kTextSecondary = Color(0xFF6E6E73);
  static const Color _kBorderHairline = Color(0xFFE5E5EA);
  static const Color _kBorderStrong = Color(0xFFD2D2D7);
  static const Color _kPesaRed = Color(0xFFC8102E);

  /// Abre la pantalla de vista previa obligatoria sin firma del cliente.
  /// Retorna `true` únicamente si el cliente aprueba ("Estoy de Acuerdo — Pasar a Firmar");
  /// retorna `false` si decide volver a corregir o cierra la vista.
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
        backgroundColor: _kBgCanvas,
        appBar: AppBar(
          backgroundColor: _kSurface,
          foregroundColor: _kTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          toolbarHeight: isCompact ? 64 : 60,
          leading: IconButton(
            tooltip: 'Volver a corregir',
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: _kTextPrimary),
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
                  color: _kTextPrimary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _kBgCanvas,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _kBorderStrong, width: 0.8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 6,
                          height: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xFFD97706),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Sin firma del cliente',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _kTextPrimary,
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
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: _kTextSecondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, thickness: 1, color: _kBorderHairline),
          ),
        ),
        body: Column(
          children: [
            // Banner informativo sobrio para el cliente
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 14 : 24,
                vertical: 10,
              ),
              decoration: const BoxDecoration(
                color: _kSurface,
                border: Border(
                  bottom: BorderSide(color: _kBorderHairline, width: 1),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.verified_user_outlined,
                      size: 16,
                      color: _kTextSecondary,
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
                        color: _kTextSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Visor interactivo del PDF (zoom + scroll)
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
                    loadingWidget: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: _kPesaRed),
                          SizedBox(height: 12),
                          Text(
                            'Preparando vista previa del documento...',
                            style: TextStyle(
                              fontSize: 13,
                              color: _kTextSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    scrollViewDecoration: const BoxDecoration(color: _kBgCanvas),
                  ),
            ),

            // Barra inferior fija con 2 acciones claras (>= 48dp touch targets)
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: _kSurface,
                border: Border(
                  top: BorderSide(color: _kBorderHairline, width: 1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 12,
                    offset: Offset(0, -3),
                  ),
                ],
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
                            _buildAprobarButton(context),
                            const SizedBox(height: 8),
                            _buildVolverButton(context),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: _buildVolverButton(context),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: _buildAprobarButton(context),
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

  Widget _buildVolverButton(BuildContext context) {
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
          foregroundColor: _kTextPrimary,
          backgroundColor: _kSurface,
          side: const BorderSide(color: _kBorderStrong, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );
  }

  Widget _buildAprobarButton(BuildContext context) {
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
          backgroundColor: _kPesaRed,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      ),
    );
  }
}
