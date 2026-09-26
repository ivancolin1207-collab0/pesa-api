// lib/screens/pdf_viewer_screen.dart
// Visor integrado de PDF para revisión local de órdenes de servicio y certificados.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

class PdfViewerScreen extends StatelessWidget {
  final String? pdfPath;
  final Uint8List? pdfBytes;
  final String folio;

  const PdfViewerScreen({
    super.key,
    this.pdfPath,
    this.pdfBytes,
    required this.folio,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1D1D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1D1D1F),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Documento: $folio',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const Text(
              'Visor local integrado de reporte de servicio',
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ],
        ),
      ),
      body: pdfBytes != null
          ? PdfPreview(
              build: (format) async => pdfBytes!,
              canChangeOrientation: false,
              canChangePageFormat: false,
              canDebug: false,
              allowPrinting: true,
              allowSharing: true,
              pdfFileName: '$folio.pdf',
              loadingWidget: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
              scrollViewDecoration: const BoxDecoration(
                color: Color(0xFF2C2C2E),
              ),
            )
          : FutureBuilder<bool>(
              future: pdfPath != null ? File(pdfPath!).exists() : Future.value(false),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Colors.white));
                }
                if (snapshot.hasError || snapshot.data != true || pdfPath == null) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 54),
                        const SizedBox(height: 12),
                        const Text(
                          'No se encontró el archivo PDF localmente',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          pdfPath ?? 'Ruta no especificada',
                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Regresar'),
                        ),
                      ],
                    ),
                  );
                }

                return PdfPreview(
                  build: (format) async => await File(pdfPath!).readAsBytes(),
                  canChangeOrientation: false,
                  canChangePageFormat: false,
                  canDebug: false,
                  allowPrinting: true,
                  allowSharing: true,
                  pdfFileName: '$folio.pdf',
                  loadingWidget: const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  scrollViewDecoration: const BoxDecoration(
                    color: Color(0xFF2C2C2E),
                  ),
                );
              },
            ),
    );
  }
}
