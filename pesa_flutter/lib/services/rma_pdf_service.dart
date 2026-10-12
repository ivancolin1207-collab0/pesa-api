// lib/services/rma_pdf_service.dart
// Generador de PDF oficial — Remisión de Material (RMA).
// Diseño fiel al formato físico de calca de Básculas PESA y Rice Lake.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class RmaPdfService {
  static const PdfColor _red = PdfColor.fromInt(0xFFCC1F1F);
  static const PdfColor _darkHdr = PdfColor.fromInt(0xFF1C1C1C);
  static const PdfColor _grayMed = PdfColor.fromInt(0xFFCCCCCC);
  static const PdfColor _grayDark = PdfColor.fromInt(0xFF888888);
  static const PdfColor _grayGrid = PdfColor.fromInt(0xFFDDDDDD);

  static Future<Uint8List> generate({
    required Map<String, dynamic> rmaData,
    required List<Map<String, dynamic>> items,
    String? firmaTecBase64,
    String? firmaCliBase64,
    String? observaciones,
  }) async {
    final doc = pw.Document(
      title: 'Remision de Material - ${rmaData['folio_os'] ?? rmaData['folio_rma'] ?? 'RMA'}',
      author: 'Servicios PESA',
    );

    // Cargar logotipos desde assets
    pw.MemoryImage? logoPesa;
    pw.MemoryImage? logoRiceLake;
    try {
      final pesaBytes = await rootBundle.load('Img/logo_pesa.png');
      logoPesa = pw.MemoryImage(pesaBytes.buffer.asUint8List());
    } catch (_) {}

    try {
      final rlBytes = await rootBundle.load('Img/RiceLake.png');
      logoRiceLake = pw.MemoryImage(rlBytes.buffer.asUint8List());
    } catch (_) {}

    // Cargar firmas
    pw.MemoryImage? imgFirmaTec;
    if (firmaTecBase64 != null && firmaTecBase64.isNotEmpty) {
      try {
        final clean = firmaTecBase64.contains(',') ? firmaTecBase64.split(',').last : firmaTecBase64;
        imgFirmaTec = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }

    pw.MemoryImage? imgFirmaCli;
    if (firmaCliBase64 != null && firmaCliBase64.isNotEmpty) {
      try {
        final clean = firmaCliBase64.contains(',') ? firmaCliBase64.split(',').last : firmaCliBase64;
        imgFirmaCli = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }

    final folio = (rmaData['folio_os'] ?? rmaData['folio_rma'] ?? 'RMA-00-000').toString();
    final fecha = (rmaData['fecha'] ?? DateTime.now().toString().substring(0, 10)).toString();
    final cliente = (rmaData['cliente'] ?? rmaData['cliente_nombre'] ?? rmaData['razon_social'] ?? '').toString();
    final direccion = (rmaData['direccion'] ?? rmaData['sucursal_direccion'] ?? rmaData['sucursal'] ?? '').toString();
    final tecnico = (rmaData['tecnico'] ?? rmaData['tecnico_nombre'] ?? '').toString();
    final clienteNombre = (rmaData['firma_cliente_nombre'] ?? rmaData['nombre_ing'] ?? 'NOMBRE Y FIRMA').toString();
    final clientePuesto = (rmaData['puesto_ing'] ?? '').toString();

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.symmetric(horizontal: 36, vertical: 18),
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // 1. Logos
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (logoPesa != null)
                    pw.Image(logoPesa, width: 150, height: 40, fit: pw.BoxFit.contain)
                  else
                    pw.Text('BÁSCULAS PESA', style: pw.TextStyle(color: _red, fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  if (logoRiceLake != null)
                    pw.Image(logoRiceLake, width: 140, height: 40, fit: pw.BoxFit.contain)
                  else
                    pw.Text('RICE LAKE', style: pw.TextStyle(color: _darkHdr, fontSize: 12, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Container(height: 0.5, color: _grayMed),
              pw.SizedBox(height: 6),

              // 2. Título y Folio RMA
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text(
                          'REMISIÓN DE MATERIAL',
                          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.black),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'PESAJE SISTEMAS Y AUTOMATIZACIÓN',
                          style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _grayDark),
                        ),
                      ],
                    ),
                  ),
                  pw.Container(
                    width: 140,
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: _red, width: 2),
                    ),
                    child: pw.Column(
                      children: [
                        pw.Container(
                          width: double.infinity,
                          color: _red,
                          padding: const pw.EdgeInsets.symmetric(vertical: 2),
                          alignment: pw.Alignment.center,
                          child: pw.Text(
                            'FOLIO / RMA',
                            style: pw.TextStyle(color: PdfColors.white, fontSize: 7.5, fontWeight: pw.FontWeight.bold),
                          ),
                        ),
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(vertical: 4),
                          alignment: pw.Alignment.center,
                          child: pw.Text(
                            folio,
                            style: pw.TextStyle(
                              color: _red,
                              fontSize: folio.length <= 11 ? 14 : 11,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),

              // 3. Barra de Fecha y Datos del Cliente
              pw.Row(
                children: [
                  pw.Text('FECHA: ', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                  pw.Text(fecha, style: const pw.TextStyle(fontSize: 8)),
                ],
              ),
              pw.SizedBox(height: 4),
              _buildInfoRow('CLIENTE:', cliente),
              _buildInfoRow('DIRECCIÓN:', direccion),
              pw.SizedBox(height: 8),

              // 4. Encabezado de la tabla
              pw.Text(
                'ENTREGA DE REFACCIONES / MATERIALES',
                style: pw.TextStyle(color: _red, fontSize: 9, fontWeight: pw.FontWeight.bold),
              ),
              pw.Container(height: 1, color: _red, margin: const pw.EdgeInsets.only(top: 2, bottom: 4)),

              // 5. Tabla de Refacciones / Partidas
              _buildItemsTable(items),

              // 6. Observaciones (si existen)
              if (observaciones != null && observaciones.trim().isNotEmpty) ...[
                pw.SizedBox(height: 6),
                pw.Container(
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: _grayMed, width: 0.5),
                    color: PdfColors.grey100,
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('OBSERVACIONES:', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _red)),
                      pw.SizedBox(height: 2),
                      pw.Text(observaciones.trim(), style: const pw.TextStyle(fontSize: 7)),
                    ],
                  ),
                ),
              ],

              pw.Spacer(),

              // 7. Firmas Obligatorias
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  // Técnico
                  pw.Container(
                    width: 200,
                    child: pw.Column(
                      children: [
                        pw.Container(
                          height: 48,
                          alignment: pw.Alignment.bottomCenter,
                          child: imgFirmaTec != null
                              ? pw.Image(imgFirmaTec, height: 44, fit: pw.BoxFit.contain)
                              : pw.SizedBox(),
                        ),
                        pw.Container(height: 0.8, color: _grayDark),
                        pw.SizedBox(height: 3),
                        pw.Text('ENTREGADO POR', style: pw.TextStyle(color: _red, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 2),
                        pw.Text(tecnico.isNotEmpty ? tecnico : 'TÉCNICO ASIGNADO', style: const pw.TextStyle(fontSize: 7)),
                      ],
                    ),
                  ),

                  // Cliente
                  pw.Container(
                    width: 200,
                    child: pw.Column(
                      children: [
                        pw.Container(
                          height: 48,
                          alignment: pw.Alignment.bottomCenter,
                          child: imgFirmaCli != null
                              ? pw.Image(imgFirmaCli, height: 44, fit: pw.BoxFit.contain)
                              : pw.SizedBox(),
                        ),
                        pw.Container(height: 0.8, color: _grayDark),
                        pw.SizedBox(height: 3),
                        pw.Text('RECIBIDO DE CONFORMIDAD', style: pw.TextStyle(color: _red, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          clientePuesto.isNotEmpty ? '$clienteNombre ($clientePuesto)' : clienteNombre,
                          style: const pw.TextStyle(fontSize: 7),
                          textAlign: pw.TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 12),

              // 8. Barra inferior del pie de página
              pw.Container(
                height: 20,
                color: _darkHdr,
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.Text('438 154 8258', style: pw.TextStyle(color: PdfColors.white, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                    pw.Text('www.basculaspesa.com.mx', style: pw.TextStyle(color: PdfColors.white, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Querétaro, México', style: pw.TextStyle(color: PdfColors.white, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  static pw.Widget _buildInfoRow(String label, String value) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _grayMed, width: 0.5)),
      ),
      padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
      child: pw.Row(
        children: [
          pw.SizedBox(
            width: 65,
            child: pw.Text(label, style: pw.TextStyle(color: _red, fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Expanded(
            child: pw.Text(value.isNotEmpty ? value : '—', style: const pw.TextStyle(fontSize: 7.5)),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildItemsTable(List<Map<String, dynamic>> items) {
    const minRows = 8;
    final rowCount = items.length > minRows ? items.length : minRows;

    return pw.Table(
      border: pw.TableBorder.all(color: _grayGrid, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(48),   // Cantidad
        1: pw.FixedColumnWidth(85),   // No. Parte
        2: pw.FlexColumnWidth(2.2),   // Descripción
        3: pw.FlexColumnWidth(1.8),   // No. Serie
      },
      children: [
        // Header
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _darkHdr),
          children: [
            _th('CANTIDAD'),
            _th('NUMERO DE PARTE'),
            _th('DESCRIPCIÓN'),
            _th('NUMERO DE SERIE'),
          ],
        ),
        // Data rows
        for (int i = 0; i < rowCount; i++)
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: i % 2 == 1 ? PdfColors.grey100 : PdfColors.white,
            ),
            children: [
              _td(i < items.length ? (items[i]['cantidad'] ?? items[i]['cant'] ?? '').toString() : '', align: pw.TextAlign.center),
              _td(i < items.length ? (items[i]['no_parte'] ?? items[i]['numero_parte'] ?? items[i]['n_parte'] ?? items[i]['parte'] ?? '').toString() : ''),
              _td(i < items.length ? (items[i]['descripcion'] ?? items[i]['desc'] ?? '').toString() : ''),
              _td(i < items.length ? (items[i]['serie'] ?? items[i]['numero_serie'] ?? items[i]['no_serie'] ?? '').toString() : ''),
            ],
          ),
      ],
    );
  }

  static pw.Widget _th(String text) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      alignment: pw.Alignment.center,
      child: pw.Text(
        text,
        style: pw.TextStyle(color: PdfColors.white, fontSize: 7, fontWeight: pw.FontWeight.bold),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  static pw.Widget _td(String text, {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
      child: pw.Text(
        text,
        style: const pw.TextStyle(fontSize: 7.5),
        textAlign: align,
      ),
    );
  }
}
