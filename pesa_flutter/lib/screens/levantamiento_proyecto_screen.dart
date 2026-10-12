// lib/screens/levantamiento_proyecto_screen.dart
// Formulario específico para Levantamiento de Proyecto (LP) — Formato Físico Oficial.
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

class LevantamientoProyectoScreen extends StatefulWidget {
  final Map<String, dynamic> orden;

  const LevantamientoProyectoScreen({super.key, required this.orden});

  @override
  State<LevantamientoProyectoScreen> createState() => _LevantamientoProyectoScreenState();
}

class _LevantamientoProyectoScreenState extends State<LevantamientoProyectoScreen> {
  static const Color _red = Color(0xFFC8102E);
  static const Color _dark = Color(0xFF1A1A2E);

  final _tipoProyectoCtrl = TextEditingController();
  final _dimensionesCtrl = TextEditingController();
  final _obraCivilCtrl = TextEditingController();
  final _alimentacionCtrl = TextEditingController();
  final _distanciaCasetaCtrl = TextEditingController();
  final _requerimientosCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  bool _errNombreRecibe = false;

  final SignatureController _ctrlFirmaTec = SignatureController(penStrokeWidth: 3, penColor: Colors.black);
  final SignatureController _ctrlFirmaCli = SignatureController(penStrokeWidth: 3, penColor: Colors.black);

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final o = widget.orden;
    _tipoProyectoCtrl.text = (o['tipo_proyecto'] ?? 'Instalación de Báscula').toString();
    _nombreClienteCtrl.text = (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _observacionesCtrl.text = (o['observaciones'] ?? '').toString();
  }

  @override
  void dispose() {
    _tipoProyectoCtrl.dispose();
    _dimensionesCtrl.dispose();
    _obraCivilCtrl.dispose();
    _alimentacionCtrl.dispose();
    _distanciaCasetaCtrl.dispose();
    _requerimientosCtrl.dispose();
    _observacionesCtrl.dispose();
    _nombreClienteCtrl.dispose();
    _ctrlFirmaTec.dispose();
    _ctrlFirmaCli.dispose();
    super.dispose();
  }

  Future<void> _finalizarLP() async {
    final nombre = _nombreClienteCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombre)) {
      setState(() => _errNombreRecibe = true);
      return;
    }

    setState(() => _saving = true);

    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? 'LP-00-000').toString();

      final pdf = pw.Document(title: 'Levantamiento de Proyecto - $folio');
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
                  pw.Text('BÁSCULAS PESA — LEVANTAMIENTO DE PROYECTO', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xFFC8102E))),
                  pw.Text('FOLIO: $folio', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.Divider(color: PdfColors.grey),
              pw.Text('Cliente: ${widget.orden['cliente'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
              pw.Text('Tipo de Proyecto: ${_tipoProyectoCtrl.text}', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 10),
              pw.Text('CONDICIONES DEL SITIO:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Dimensiones: ${_dimensionesCtrl.text} | Obra Civil: ${_obraCivilCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
              pw.Text('Alimentación Eléctrica: ${_alimentacionCtrl.text} | Distancia a Caseta: ${_distanciaCasetaCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 10),
              pw.Text('REQUERIMIENTOS Y OBSERVACIONES:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text(_requerimientosCtrl.text, style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 6),
              pw.Text(_observacionesCtrl.text, style: const pw.TextStyle(fontSize: 9)),
              pw.Spacer(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  pw.Column(children: [
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Técnico / Ingeniero PESA', style: const pw.TextStyle(fontSize: 8)),
                  ]),
                  pw.Column(children: [
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Recibido por: $nombre', style: const pw.TextStyle(fontSize: 8)),
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

      String? fTecB64;
      if (_ctrlFirmaTec.isNotEmpty) {
        final b = await _ctrlFirmaTec.toPngBytes();
        if (b != null) fTecB64 = base64Encode(b);
      } else {
        final username = (widget.orden['tecnico_username'] ?? widget.orden['tecnico'] ?? '').toString();
        final saved = await FirmaTecnicoService.instance.getFirma(username);
        if (saved != null && saved.isNotEmpty) {
          fTecB64 = saved;
        }
      }

      String? fCliB64;
      if (_ctrlFirmaCli.isNotEmpty) {
        final b = await _ctrlFirmaCli.toPngBytes();
        if (b != null) fCliB64 = base64Encode(b);
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: fTecB64 ?? '',
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
    final folio = (widget.orden['folio_os'] ?? 'LP-00-000').toString();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _dark,
        foregroundColor: Colors.white,
        title: Text('Levantamiento de Proyecto ($folio)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: _red, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
            onPressed: _saving ? null : _finalizarLP,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Finalizar Levantamiento de Proyecto', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(controller: _tipoProyectoCtrl, decoration: const InputDecoration(labelText: 'Tipo de Proyecto / Alcance', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _dimensionesCtrl, decoration: const InputDecoration(labelText: 'Dimensiones / Espacio Disponible', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _obraCivilCtrl, decoration: const InputDecoration(labelText: 'Estado de Obra Civil (Fosa / Sobresuelo / Rampa)', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _alimentacionCtrl, decoration: const InputDecoration(labelText: 'Alimentación Eléctrica / Tierra Física', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _distanciaCasetaCtrl, decoration: const InputDecoration(labelText: 'Distancia a Caseta de Control', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _requerimientosCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Requerimientos Especiales del Cliente', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextFormField(controller: _observacionesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones y Recomendaciones', border: OutlineInputBorder())),
          const SizedBox(height: 14),
          const Text('FIRMA DEL CLIENTE / ENCARGADO DE PLANTA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
          const SizedBox(height: 6),
          TextFormField(controller: _nombreClienteCtrl, onChanged: (_) { if (_errNombreRecibe) setState(() => _errNombreRecibe = false); }, decoration: InputDecoration(labelText: 'Nombre del Responsable *', errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null, border: const OutlineInputBorder())),
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
