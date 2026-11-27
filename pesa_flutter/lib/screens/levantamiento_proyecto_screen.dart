// lib/screens/levantamiento_proyecto_screen.dart
// Formulario específico para Levantamiento de Proyecto (LP) — Formato Físico Oficial.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../widgets/nombre_recibe.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:signature/signature.dart';

import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';
import '../widgets/cliente_correo_poka_yoke.dart';
import '../widgets/signature_shield.dart';
import 'pdf_preview_aprobacion_screen.dart';

class LevantamientoProyectoScreen extends StatefulWidget {
  final Map<String, dynamic> orden;

  const LevantamientoProyectoScreen({super.key, required this.orden});

  @override
  State<LevantamientoProyectoScreen> createState() => _LevantamientoProyectoScreenState();
}

class _LevantamientoProyectoScreenState extends State<LevantamientoProyectoScreen> {
  static const Color _red = PesaColors.brand;

  final _tipoProyectoCtrl = TextEditingController();
  final _dimensionesCtrl = TextEditingController();
  final _obraCivilCtrl = TextEditingController();
  final _alimentacionCtrl = TextEditingController();
  final _distanciaCasetaCtrl = TextEditingController();
  final _requerimientosCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  bool _errNombreRecibe = false;

  // BLINDAJE DE FIRMA: tinta negra (#000000) fija sobre fondo blanco (#FFFFFF) incluso en Dark Mode
  final SignatureController _ctrlFirmaTec = SignatureController(
    penStrokeWidth: 3,
    penColor: PesaColors.signatureInk,
    exportPenColor: PesaColors.signatureInk,
  );
  final SignatureController _ctrlFirmaCli = SignatureController(
    penStrokeWidth: 3,
    penColor: PesaColors.signatureInk,
    exportPenColor: PesaColors.signatureInk,
  );
  late final ClienteCorreoController _correoCtrl = ClienteCorreoController();

  bool _saving = false;
  bool _vistaPreviaAprobada = false;
  final GlobalKey _firmaSectionKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final o = widget.orden;
    _tipoProyectoCtrl.text = (o['tipo_proyecto'] ?? 'Instalación de Báscula').toString();
    _nombreClienteCtrl.text = (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _observacionesCtrl.text = (o['observaciones'] ?? '').toString();
    _correoCtrl.inicializarDesdeOrden(o);
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
    _correoCtrl.dispose();
    super.dispose();
  }

  Future<Uint8List> _construirPdfLPBytes({
    required String folio,
    required String fechaEjecucionHoy,
    required Map<String, dynamic> ordenMutable,
    required String nombre,
    String? firmaTecB64,
    String? firmaCliB64,
    bool modoPreviewSinFirma = false,
  }) async {
    pw.ImageProvider? imgTec;
    if (firmaTecB64 != null && firmaTecB64.isNotEmpty) {
      try {
        final raw = firmaTecB64.contains(',') ? firmaTecB64.split(',').last : firmaTecB64;
        imgTec = pw.MemoryImage(base64Decode(raw));
      } catch (_) {}
    }
    pw.ImageProvider? imgCli;
    if (!modoPreviewSinFirma && firmaCliB64 != null && firmaCliB64.isNotEmpty) {
      try {
        final raw = firmaCliB64.contains(',') ? firmaCliB64.split(',').last : firmaCliB64;
        imgCli = pw.MemoryImage(base64Decode(raw));
      } catch (_) {}
    }

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
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('FOLIO: $folio', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    pw.Text('FECHA: $fechaEjecucionHoy', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ],
            ),
            pw.Divider(color: PdfColors.grey),
            pw.Text('Cliente: ${ordenMutable['cliente'] ?? ''}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('Fecha de Ejecución: $fechaEjecucionHoy', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('Tipo de Proyecto: ${_tipoProyectoCtrl.text}', style: const pw.TextStyle(fontSize: 10)),
            pw.SizedBox(height: 10),
            pw.Text('CONDICIONES DEL SITIO:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.Text('Dimensiones: ${_dimensionesCtrl.text} | Obra Civil: ${_obraCivilCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
            pw.Text('Alimentación Eléctrica: ${_alimentacionCtrl.text} | Distancia a Caseta: ${_distanciaCasetaCtrl.text}', style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 10),
            pw.Text('REQUERIMIENTOS Y OBSERVACIONES:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            if (_requerimientosCtrl.text.trim().isNotEmpty) ...[
              pw.Text(_requerimientosCtrl.text.trim(), style: const pw.TextStyle(fontSize: 9), softWrap: true),
              pw.SizedBox(height: 6),
            ],
            () {
              final String obsTexto = _observacionesCtrl.text.trim();
              final double obsFontSize = obsTexto.length > 350
                  ? 6.8
                  : (obsTexto.length > 200 ? 7.5 : 8.5);
              return pw.Container(
                width: double.infinity,
                constraints: const pw.BoxConstraints(minHeight: 38),
                padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
                ),
                child: pw.Text(
                  obsTexto.isEmpty ? 'Sin observaciones adicionales.' : obsTexto,
                  style: pw.TextStyle(
                    fontSize: obsFontSize,
                    lineSpacing: 1.5,
                  ),
                  softWrap: true,
                  textAlign: pw.TextAlign.left,
                ),
              );
            }(),
            pw.Spacer(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
              children: [
                pw.Column(children: [
                  pw.Container(
                    width: 160,
                    height: 44,
                    alignment: pw.Alignment.bottomCenter,
                    child: imgTec != null ? pw.Image(imgTec, height: 40, fit: pw.BoxFit.contain) : pw.SizedBox(),
                  ),
                  pw.Container(width: 160, height: 1, color: PdfColors.black),
                  pw.SizedBox(height: 3),
                  pw.Text('Técnico / Ingeniero PESA', style: const pw.TextStyle(fontSize: 8)),
                ]),
                pw.Column(children: [
                  pw.Container(
                    width: 160,
                    height: 44,
                    alignment: modoPreviewSinFirma ? pw.Alignment.center : pw.Alignment.bottomCenter,
                    child: (!modoPreviewSinFirma && imgCli != null)
                        ? pw.Image(imgCli, height: 40, fit: pw.BoxFit.contain)
                        : (modoPreviewSinFirma
                            ? pw.Text(
                                'Pendiente de firma y conformidad del cliente',
                                textAlign: pw.TextAlign.center,
                                style: pw.TextStyle(fontSize: 6.5, fontStyle: pw.FontStyle.italic, color: PdfColors.grey600),
                              )
                            : pw.SizedBox()),
                  ),
                  pw.Container(width: 160, height: 1, color: PdfColors.black),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    modoPreviewSinFirma ? 'Recibido de Conformidad (Cliente)' : 'Recibido por: $nombre',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ]),
              ],
            ),
          ],
        ),
      ),
    );
    return pdf.save();
  }

  Future<void> _abrirVistaPreviaLP() async {
    setState(() => _saving = true);
    try {
      final folio = (widget.orden['folio_os'] ?? 'LP-00-000').toString();
      final fechaHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      String? fTecB64;
      if (_ctrlFirmaTec.isNotEmpty) {
        final b = await _ctrlFirmaTec.toPngBytes();
        if (b != null) fTecB64 = base64Encode(b);
      } else {
        final username = (widget.orden['tecnico_username'] ?? widget.orden['tecnico'] ?? '').toString();
        final saved = await FirmaTecnicoService.instance.getFirma(username);
        if (saved != null && saved.isNotEmpty) fTecB64 = saved;
      }

      final previewBytes = await _construirPdfLPBytes(
        folio: folio,
        fechaEjecucionHoy: fechaHoy,
        ordenMutable: Map<String, dynamic>.from(widget.orden),
        nombre: _nombreClienteCtrl.text.trim(),
        firmaTecB64: fTecB64,
        firmaCliB64: null,
        modoPreviewSinFirma: true,
      );
      if (!mounted) return;
      setState(() => _saving = false);

      final aprobado = await PdfPreviewAprobacionScreen.mostrar(
        context,
        folio: folio,
        pdfBytes: previewBytes,
        tipoDocumento: 'Levantamiento de Proyecto (LP)',
      );
      if (aprobado && mounted) {
        setState(() => _vistaPreviaAprobada = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _firmaSectionKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: _red, content: Text('Error vista previa: $e')));
      }
    }
  }

  Future<void> _finalizarLP() async {
    if (!_vistaPreviaAprobada) {
      await _abrirVistaPreviaLP();
      return;
    }
    final nombre = _nombreClienteCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombre)) {
      setState(() => _errNombreRecibe = true);
      return;
    }
    if (!_correoCtrl.isValido) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: _red, content: Text(kMsgPokaYokeCorreo)),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? 'LP-00-000').toString();

      final String fechaEjecucionHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String fechaCierreIso = DateTime.now().toIso8601String();

      final ordenMutable = Map<String, dynamic>.from(widget.orden);
      ordenMutable['fecha_creacion_logistica'] = ordenMutable['fecha_creacion_logistica'] ?? ordenMutable['fecha'];
      ordenMutable['fecha'] = fechaEjecucionHoy;
      ordenMutable['fecha_servicio'] = fechaEjecucionHoy;
      ordenMutable['fecha_cierre'] = fechaCierreIso;

      widget.orden['fecha'] = fechaEjecucionHoy;
      widget.orden['fecha_servicio'] = fechaEjecucionHoy;
      widget.orden['fecha_cierre'] = fechaCierreIso;

      await LocalDbService.instance.actualizarFechaEjecucionAlFinalizar(
        folio,
        fechaEjecucionHoy,
        localId: localId,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

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

      await LocalDbService.instance.invalidarPdfLocal(folio);

      final pdfBytes = await _construirPdfLPBytes(
        folio: folio,
        fechaEjecucionHoy: fechaEjecucionHoy,
        ordenMutable: ordenMutable,
        nombre: nombre,
        firmaTecB64: fTecB64,
        firmaCliB64: fCliB64,
        modoPreviewSinFirma: false,
      );

      final dir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${dir.path}/pdfs');
      if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
      final pdfPath = '${pdfDir.path}/$folio.pdf';
      final file = File(pdfPath);
      await file.writeAsBytes(pdfBytes, flush: true);

      final String loteIdLp = (widget.orden['id_lote'] ?? widget.orden['lote'] ?? '').toString().trim();
      final String correoCapturado = await _correoCtrl.persistirEnOrdenYLote(
        folio: folio,
        loteId: loteIdLp,
        ordenMutable: ordenMutable,
      );
      if (loteIdLp.isNotEmpty && nombre.isNotEmpty) {
        LoteSession.registrarResponsable(loteIdLp, nombre);
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: fTecB64 ?? '',
        firmaCliBase64: fCliB64 ?? '',
        nombreIng: nombre,
        correoCliente: correoCapturado.isNotEmpty ? correoCapturado : null,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

      bool subio = false;
      try {
        subio = await ApiService.instance.uploadPdf(
          folio,
          file,
          osId: localId,
          data: {
            'tipo_documento': 'LP',
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'observaciones': _observacionesCtrl.text,
            'nombre_ing': nombre,
            'firma_cliente_nombre': nombre,
            'correo_cliente': correoCapturado,
            'correo_destino': correoCapturado,
          },
        );
      } catch (_) {}

      await LocalDbService.instance.savePdfPath(
        localId,
        pdfPath,
        folio: folio,
        pdfB64: base64Encode(pdfBytes),
        isOnline: subio,
        uploadOk: subio,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

      if (mounted) {
        try {
          context.read<SyncService>().updateLocalOrder(folio, {
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'pdf_path_local': pdfPath,
            'estado': 'COMPLETADA_DIGITAL',
            'estatus': 'Cerrado',
            'sync_check_status': subio ? 'SUBIDA_SERVIDOR' : 'PENDIENTE_SUBIDA',
            'sync_status': subio ? 'SINCRONIZADO' : 'PENDIENTE',
          });
        } catch (_) {}
      }

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
    final c = PesaColors.of(context);
    final folio = (widget.orden['folio_os'] ?? 'LP-00-000').toString();

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: c.border),
        ),
        title: Text('Levantamiento de Proyecto ($folio)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: c.textPrimary)),
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _correoCtrl,
        builder: (context, _) => SafeArea(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_vistaPreviaAprobada) ...[
                  ClienteCorreoLockBanner(controller: _correoCtrl),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _abrirVistaPreviaLP,
                        icon: const Icon(Icons.preview_outlined, size: 18),
                        label: const Text('Vista Previa'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textPrimary,
                          side: BorderSide(color: c.borderStrong),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _red,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: (_saving || !_correoCtrl.isValido) ? null : _finalizarLP,
                          icon: const Icon(Icons.check_circle_outline),
                          label: Text(
                            _saving ? 'Generando PDF Final...' : 'Confirmar Firma y Finalizar',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _saving ? null : _abrirVistaPreviaLP,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.preview_outlined),
                    label: Text(
                      _saving ? 'Preparando Vista Previa...' : 'Revisar Vista Previa (Sin Firma)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: SigningScrollLock(
        builder: (ctx, physics, _) => ListView(
          physics: physics,
          padding: EdgeInsets.all(foldableHorizontalPadding(ctx)),
          children: [
            FoldableFormGrid(
              unfoldedColumns: 2,
              spacing: 12,
              runSpacing: 12,
              children: [
                TextFormField(controller: _tipoProyectoCtrl, decoration: const InputDecoration(labelText: 'Tipo de Proyecto / Alcance', border: OutlineInputBorder())),
                TextFormField(controller: _dimensionesCtrl, decoration: const InputDecoration(labelText: 'Dimensiones / Espacio Disponible', border: OutlineInputBorder())),
                TextFormField(controller: _obraCivilCtrl, decoration: const InputDecoration(labelText: 'Estado de Obra Civil (Fosa / Sobresuelo / Rampa)', border: OutlineInputBorder())),
                TextFormField(controller: _alimentacionCtrl, decoration: const InputDecoration(labelText: 'Alimentación Eléctrica / Tierra Física', border: OutlineInputBorder())),
                TextFormField(controller: _distanciaCasetaCtrl, decoration: const InputDecoration(labelText: 'Distancia a Caseta de Control', border: OutlineInputBorder())),
                TextFormField(controller: _requerimientosCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Requerimientos Especiales del Cliente', border: OutlineInputBorder())),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _observacionesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones y Recomendaciones', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            Text('FIRMA DEL CLIENTE / ENCARGADO DE PLANTA', key: _firmaSectionKey, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary)),
            const SizedBox(height: 8),
            TextFormField(controller: _nombreClienteCtrl, onChanged: (_) { if (_errNombreRecibe) setState(() => _errNombreRecibe = false); }, decoration: InputDecoration(labelText: 'Nombre del Responsable *', errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null, border: const OutlineInputBorder())),
            const SizedBox(height: 10),
            ClienteCorreoPokaYokeCard(
              controller: _correoCtrl,
              loteId: (widget.orden['id_lote'] ?? widget.orden['lote'])?.toString(),
            ),
            Container(
              height: 165,
              decoration: BoxDecoration(color: PesaColors.signatureCanvas, border: Border.all(color: c.borderStrong), borderRadius: BorderRadius.circular(8)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SignatureGestureShield(child: Signature(controller: _ctrlFirmaCli, backgroundColor: PesaColors.signatureCanvas)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
