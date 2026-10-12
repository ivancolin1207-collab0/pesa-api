// lib/screens/levantamiento_metrologico_screen.dart
// Formulario específico para Levantamiento Metrológico y Logística de Pesas (LV).
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../widgets/nombre_recibe.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:signature/signature.dart';

import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../widgets/signature_shield.dart';

class LevantamientoMetrologicoScreen extends StatefulWidget {
  final Map<String, dynamic> orden;

  const LevantamientoMetrologicoScreen({super.key, required this.orden});

  @override
  State<LevantamientoMetrologicoScreen> createState() => _LevantamientoMetrologicoScreenState();
}

class _LevantamientoMetrologicoScreenState extends State<LevantamientoMetrologicoScreen> {
  static const Color _red = Color(0xFFC8102E);
  static const Color _dark = Color(0xFF1A1A2E);

  final _pesoTotalCtrl = TextEditingController();
  final _clasePesasCtrl = TextEditingController();
  final _maniobraCtrl = TextEditingController();
  final _accesibilidadCtrl = TextEditingController();
  final _inventarioBasculasCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  bool _errNombreRecibe = false;

  final SignatureController _ctrlFirmaCli = SignatureController(penStrokeWidth: 3, penColor: Colors.black);

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final o = widget.orden;
    _pesoTotalCtrl.text = (o['peso_patron_total'] ?? '5,000 kg').toString();
    _clasePesasCtrl.text = (o['clase_pesas'] ?? 'M1').toString();
    _maniobraCtrl.text = (o['maniobra'] ?? 'Camión grúa PESA').toString();
    _nombreClienteCtrl.text = (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _observacionesCtrl.text = (o['observaciones'] ?? '').toString();
  }

  @override
  void dispose() {
    _pesoTotalCtrl.dispose();
    _clasePesasCtrl.dispose();
    _maniobraCtrl.dispose();
    _accesibilidadCtrl.dispose();
    _inventarioBasculasCtrl.dispose();
    _observacionesCtrl.dispose();
    _nombreClienteCtrl.dispose();
    _ctrlFirmaCli.dispose();
    super.dispose();
  }

  Future<void> _finalizarLV() async {
    final nombre = _nombreClienteCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombre)) {
      setState(() => _errNombreRecibe = true);
      return;
    }

    setState(() => _saving = true);

    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? 'LV-00-000').toString();

      final pdf = pw.Document(title: 'Levantamiento Metrológico - $folio');
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(36),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('BÁSCULAS PESA — LEVANTAMIENTO METROLÓGICO (LV)', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xFFC8102E))),
                  pw.Text('FOLIO: $folio', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.Divider(color: PdfColors.grey),
              pw.Text('Cliente: ${widget.orden['cliente'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 10),
              pw.Text('LOGÍSTICA DE PESAS PATRÓN:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Masa Total Requerida: ${_pesoTotalCtrl.text} | Clase: ${_clasePesasCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
              pw.Text('Transporte / Maniobra: ${_maniobraCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 10),
              pw.Text('ACCESIBILIDAD Y SEGURIDAD:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text(_accesibilidadCtrl.text.isNotEmpty ? _accesibilidadCtrl.text : 'Acceso libre para camión y personal.', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 10),
              pw.Text('INVENTARIO DE BÁSCULAS A CALIBRAR:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text(_inventarioBasculasCtrl.text.isNotEmpty ? _inventarioBasculasCtrl.text : 'Pendiente inspección en sitio.', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 10),
              pw.Text('OBSERVACIONES:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text(_observacionesCtrl.text, style: const pw.TextStyle(fontSize: 9)),
              pw.Spacer(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  pw.Column(children: [
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Metrólogo Responsable', style: const pw.TextStyle(fontSize: 8)),
                  ]),
                  pw.Column(children: [
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Conforme: $nombre', style: const pw.TextStyle(fontSize: 8)),
                  ]),
                ],
              ),
            ],
          ),
        ),
      );

      final pdfBytes = await pdf.save();
      final dir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${dir.path}/pdfs');
      if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
      final pdfPath = '${pdfDir.path}/$folio.pdf';
      final file = File(pdfPath);
      await file.writeAsBytes(pdfBytes, flush: true);

      String? fCliB64;
      if (_ctrlFirmaCli.isNotEmpty) {
        final b = await _ctrlFirmaCli.toPngBytes();
        if (b != null) fCliB64 = base64Encode(b);
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: '',
        firmaCliBase64: fCliB64 ?? '',
        nombreIng: nombre,
      );

      bool subio = false;
      try {
        subio = await ApiService.instance.uploadPdf(folio, file, osId: localId);
      } catch (_) {}

      await LocalDbService.instance.savePdfPath(
        localId,
        pdfPath,
        folio: folio,
        pdfB64: base64Encode(pdfBytes),
        isOnline: subio,
        uploadOk: subio,
      );

      if (mounted) {
        setState(() => _saving = false);
        OpenFilex.open(pdfPath);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: _red, content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio_os'] ?? 'LV-00-000').toString();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _dark,
        foregroundColor: Colors.white,
        title: Text('Levantamiento Metrológico ($folio)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: _red, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
            onPressed: _saving ? null : _finalizarLV,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Finalizar Levantamiento Metrológico', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(controller: _pesoTotalCtrl, decoration: const InputDecoration(labelText: 'Masa Patrón Total Requerida', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _clasePesasCtrl, decoration: const InputDecoration(labelText: 'Clase de Exactitud de Pesas (M1 / F1)', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _maniobraCtrl, decoration: const InputDecoration(labelText: 'Tipo de Transporte y Maniobra (Camión Grúa / Montacargas)', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _accesibilidadCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Accesibilidad a Báscula y Permisos de Seguridad', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _inventarioBasculasCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Inventario Preliminar de Básculas a Calibrar', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _observacionesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones Metrológicas del Sitio', border: OutlineInputBorder())),
          const SizedBox(height: 14),
          const Text('FIRMA DE CONFORMIDAD', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
          const SizedBox(height: 6),
          TextFormField(controller: _nombreClienteCtrl, onChanged: (_) { if (_errNombreRecibe) setState(() => _errNombreRecibe = false); }, decoration: InputDecoration(labelText: 'Nombre del Responsable en Planta *', errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null, border: const OutlineInputBorder())),
          const SizedBox(height: 8),
          Container(
            height: 160,
            decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(8)),
            child: SignatureGestureShield(child: Signature(controller: _ctrlFirmaCli, backgroundColor: Colors.white)),
          ),
        ],
      ),
    );
  }
}
