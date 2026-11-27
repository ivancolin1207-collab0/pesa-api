// lib/screens/levantamiento_metrologico_screen.dart
// Formulario específico para Levantamiento Metrológico y Logística de Pesas (LV).
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

class LevantamientoMetrologicoScreen extends StatefulWidget {
  final Map<String, dynamic> orden;

  const LevantamientoMetrologicoScreen({super.key, required this.orden});

  @override
  State<LevantamientoMetrologicoScreen> createState() => _LevantamientoMetrologicoScreenState();
}

class _LevantamientoMetrologicoScreenState extends State<LevantamientoMetrologicoScreen> {
  static const Color _red = PesaColors.brand;

  final _pesoTotalCtrl = TextEditingController();
  final _clasePesasCtrl = TextEditingController();
  final _maniobraCtrl = TextEditingController();
  final _accesibilidadCtrl = TextEditingController();
  final _inventarioBasculasCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();
  final _nombreClienteCtrl = TextEditingController();
  bool _errNombreRecibe = false;

  // BLINDAJE DE FIRMA: tinta negra (#000000) fija sobre fondo blanco (#FFFFFF) incluso en Dark Mode
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
    _pesoTotalCtrl.text = (o['peso_patron_total'] ?? '5,000 kg').toString();
    _clasePesasCtrl.text = (o['clase_pesas'] ?? 'M1').toString();
    _maniobraCtrl.text = (o['maniobra'] ?? 'Camión grúa PESA').toString();
    _nombreClienteCtrl.text = (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _observacionesCtrl.text = (o['observaciones'] ?? '').toString();
    _correoCtrl.inicializarDesdeOrden(o);
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
    _correoCtrl.dispose();
    super.dispose();
  }

  Future<Uint8List> _construirPdfLVBytes({
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
            pw.SizedBox(height: 3),
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
                  pw.Text('Metrólogo Responsable', style: const pw.TextStyle(fontSize: 8)),
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
                    modoPreviewSinFirma ? 'Conforme (Cliente)' : 'Conforme: $nombre',
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

  Future<void> _abrirVistaPreviaLV() async {
    setState(() => _saving = true);
    try {
      final folio = (widget.orden['folio_os'] ?? 'LV-00-000').toString();
      final fechaHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final username = (widget.orden['tecnico_username'] ?? widget.orden['tecnico'] ?? '').toString();
      final fTecB64 = await FirmaTecnicoService.instance.getFirma(username);

      final previewBytes = await _construirPdfLVBytes(
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
        tipoDocumento: 'Levantamiento Metrológico (LV)',
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

  Future<void> _finalizarLV() async {
    if (!_vistaPreviaAprobada) {
      await _abrirVistaPreviaLV();
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
      final folio = (widget.orden['folio_os'] ?? 'LV-00-000').toString();

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

      final username = (widget.orden['tecnico_username'] ?? widget.orden['tecnico'] ?? '').toString();
      final fTecB64 = await FirmaTecnicoService.instance.getFirma(username);

      String? fCliB64;
      if (_ctrlFirmaCli.isNotEmpty) {
        final b = await _ctrlFirmaCli.toPngBytes();
        if (b != null) fCliB64 = base64Encode(b);
      }

      await LocalDbService.instance.invalidarPdfLocal(folio);

      final pdfBytes = await _construirPdfLVBytes(
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

      final String loteIdLv = (widget.orden['id_lote'] ?? widget.orden['lote'] ?? '').toString().trim();
      final String correoCapturado = await _correoCtrl.persistirEnOrdenYLote(
        folio: folio,
        loteId: loteIdLv,
        ordenMutable: ordenMutable,
      );
      if (loteIdLv.isNotEmpty && nombre.isNotEmpty) {
        LoteSession.registrarResponsable(loteIdLv, nombre);
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: '',
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
            'tipo_documento': 'LV',
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
    final folio = (widget.orden['folio_os'] ?? 'LV-00-000').toString();

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
        title: Text('Levantamiento Metrológico ($folio)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: c.textPrimary)),
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
                        onPressed: _saving ? null : _abrirVistaPreviaLV,
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
                          onPressed: (_saving || !_correoCtrl.isValido) ? null : _finalizarLV,
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
                    onPressed: _saving ? null : _abrirVistaPreviaLV,
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
                TextFormField(controller: _pesoTotalCtrl, decoration: const InputDecoration(labelText: 'Masa Patrón Total Requerida', border: OutlineInputBorder())),
                TextFormField(controller: _clasePesasCtrl, decoration: const InputDecoration(labelText: 'Clase de Exactitud de Pesas (M1 / F1)', border: OutlineInputBorder())),
                TextFormField(controller: _maniobraCtrl, decoration: const InputDecoration(labelText: 'Tipo de Transporte y Maniobra (Camión Grúa / Montacargas)', border: OutlineInputBorder())),
                TextFormField(controller: _accesibilidadCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Accesibilidad a Báscula y Permisos de Seguridad', border: OutlineInputBorder())),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(controller: _inventarioBasculasCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Inventario Preliminar de Básculas a Calibrar', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextFormField(controller: _observacionesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Observaciones Metrológicas del Sitio', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            Text('FIRMA DE CONFORMIDAD', key: _firmaSectionKey, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary)),
            const SizedBox(height: 8),
            TextFormField(controller: _nombreClienteCtrl, onChanged: (_) { if (_errNombreRecibe) setState(() => _errNombreRecibe = false); }, decoration: InputDecoration(labelText: 'Nombre del Responsable en Planta *', errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null, border: const OutlineInputBorder())),
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
