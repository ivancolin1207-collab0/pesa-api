// lib/screens/revision_bascula_screen.dart
import 'dart:convert';
import 'dart:io';
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
import '../widgets/signature_shield.dart';

class RevisionBasculaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const RevisionBasculaScreen({super.key, required this.orden});

  @override
  State<RevisionBasculaScreen> createState() => _RevisionBasculaScreenState();
}

class _RevisionBasculaScreenState extends State<RevisionBasculaScreen> {
  static const Color _red = Color(0xFFC8102E);
  static const Color _dark = Color(0xFF1A1A2E);

  // Controladores de equipo
  final _marcaCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController();
  final _serieCtrl = TextEditingController();
  final _capacidadCtrl = TextEditingController();
  final _divisionCtrl = TextEditingController();
  final _ubicacionCtrl = TextEditingController();

  // Controladores de diagnóstico
  final _diagnosticoCtrl = TextEditingController();
  final _observacionesCtrl = TextEditingController();

  // Controladores de firmas
  final _nombreReceptorCtrl = TextEditingController();
  bool _errNombreRecibe = false;
  final _puestoReceptorCtrl = TextEditingController();

  final SignatureController _ctrlFirmaCli = SignatureController(
    penStrokeWidth: 3,
    penColor: const Color(0xFF1D1D1F),
  );

  bool _saving = false;
  
  int _puntosApoyo = 4;
  
  // Inspección Visual
  bool _chkCajaSuma = true;
  bool _chkTopesLongitudinales = true;
  bool _chkTopesTransversales = true;
  bool _chkEstadoCables = true;

  // Celdas data
  List<Map<String, dynamic>> _celdasData = [];

  String? _firmaTecnicoB64;

  @override
  void initState() {
    super.initState();
    _puntosApoyo = int.tryParse(widget.orden['puntos_apoyo']?.toString() ?? '4') ?? 4;
    _initCeldas();
    _cargarDatos();
  }
  
  void _initCeldas() {
    _celdasData = List.generate(_puntosApoyo, (i) => {
      'capacidad': TextEditingController(),
      'serie': TextEditingController(),
      'mv_cero': TextEditingController(),
      'mv_carga': TextEditingController(),
      'resistencia': TextEditingController(),
    });
  }

  @override
  void dispose() {
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _serieCtrl.dispose();
    _capacidadCtrl.dispose();
    _divisionCtrl.dispose();
    _ubicacionCtrl.dispose();
    _diagnosticoCtrl.dispose();
    _observacionesCtrl.dispose();
    _nombreReceptorCtrl.dispose();
    _puestoReceptorCtrl.dispose();
    _ctrlFirmaCli.dispose();
    for (var row in _celdasData) {
      row['capacidad'].dispose();
      row['serie'].dispose();
      row['mv_cero'].dispose();
      row['mv_carga'].dispose();
      row['resistencia'].dispose();
    }
    super.dispose();
  }

  Future<void> _cargarDatos() async {
    final o = widget.orden;
    _marcaCtrl.text = (o['marca'] ?? '').toString();
    _modeloCtrl.text = (o['modelo'] ?? '').toString();
    _serieCtrl.text = (o['serie'] ?? o['numero_serie'] ?? '').toString();
    _capacidadCtrl.text = (o['capacidad_max'] ?? o['capacidad'] ?? '').toString();
    _divisionCtrl.text = (o['division_min'] ?? o['d'] ?? '').toString();
    _ubicacionCtrl.text = (o['ubicacion'] ?? o['planta'] ?? '').toString();
    _observacionesCtrl.text = (o['observaciones'] ?? '').toString();
    _nombreReceptorCtrl.text = (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _puestoReceptorCtrl.text = (o['puesto_ing'] ?? '').toString();
    
    // Load pre-saved tech signature
    _firmaTecnicoB64 = (o['firma_tecnico_descargada'] ?? o['firma_tecnico'])?.toString();
    if (_firmaTecnicoB64 == null || _firmaTecnicoB64!.isEmpty) {
       final username = (o['tecnico_username'] ?? o['tecnico'] ?? '').toString();
       _firmaTecnicoB64 = await FirmaTecnicoService.instance.getFirma(username);
    }
    if (mounted) setState(() {});
  }

  Future<void> _finalizarRevision() async {
    final nombreReceptor = _nombreReceptorCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombreReceptor)) {
      setState(() => _errNombreRecibe = true);
      return;
    }

    String? fCliB64;
    if (_ctrlFirmaCli.isNotEmpty) {
      final b = await _ctrlFirmaCli.toPngBytes();
      if (b != null) fCliB64 = base64Encode(b);
    }
    // Firma del cliente OPCIONAL (si no puede firmar en pantalla); el nombre es obligatorio.

    setState(() => _saving = true);

    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? 'RE-00-000').toString();

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

      // Generar PDF RE
      final pdf = pw.Document(title: 'Revisión de Báscula - $folio');
      
      final headerColor = PdfColor.fromInt(0xFF1D1D1B);
      final redColor = PdfColor.fromInt(0xFFC8102E);
      
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
                  pw.Text('REVISIÓN DE CELDAS DE CARGA', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: redColor)),
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
              pw.SizedBox(height: 10),
              pw.Text('DATOS DEL INSTRUMENTO:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text('Cliente: ${(ordenMutable['cliente'] ?? '').toString()} | Fecha: $fechaEjecucionHoy', style: const pw.TextStyle(fontSize: 9)),
              pw.Text('Ubicación: ${_ubicacionCtrl.text.trim()}', style: const pw.TextStyle(fontSize: 9)),
              pw.Text('Marca: ${_marcaCtrl.text.trim()} | Modelo: ${_modeloCtrl.text.trim()} | Serie: ${_serieCtrl.text.trim()}', style: const pw.TextStyle(fontSize: 9)),
              pw.Text('Capacidad: ${_capacidadCtrl.text.trim()} | División mínima: ${_divisionCtrl.text.trim()} | Puntos de Apoyo: $_puntosApoyo', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 15),
              
              pw.Text('INSPECCIÓN VISUAL Y FUNCIONAL:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 5),
              pw.Row(
                 mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                 children: [
                    pw.Text('Caja Suma: ${_chkCajaSuma ? 'OK' : 'REVISAR'}', style: const pw.TextStyle(fontSize: 9)),
                    pw.Text('Topes Longitudinales: ${_chkTopesLongitudinales ? 'OK' : 'REVISAR'}', style: const pw.TextStyle(fontSize: 9)),
                 ]
              ),
              pw.Row(
                 mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                 children: [
                    pw.Text('Estado Cables: ${_chkEstadoCables ? 'OK' : 'REVISAR'}', style: const pw.TextStyle(fontSize: 9)),
                    pw.Text('Topes Transversales: ${_chkTopesTransversales ? 'OK' : 'REVISAR'}', style: const pw.TextStyle(fontSize: 9)),
                 ]
              ),
              pw.SizedBox(height: 15),
              
              pw.Text('TABLA TÉCNICA DE CELDAS DE CARGA:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 5),
              pw.Table(
                 border: pw.TableBorder.all(color: PdfColors.grey400),
                 columnWidths: {
                    0: const pw.FlexColumnWidth(0.5),
                    1: const pw.FlexColumnWidth(1),
                    2: const pw.FlexColumnWidth(1.2),
                    3: const pw.FlexColumnWidth(1),
                    4: const pw.FlexColumnWidth(1),
                    5: const pw.FlexColumnWidth(1.2),
                 },
                 children: [
                    pw.TableRow(
                       decoration: pw.BoxDecoration(color: headerColor),
                       children: ['Nº', 'Capacidad', 'Nº Serie', 'mV/V Cero', 'mV/V Carga', 'Resistencia'].map((t) => 
                          pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(t, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)))
                       ).toList(),
                    ),
                    for (int i=0; i<_puntosApoyo; i++)
                       pw.TableRow(
                          children: [
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text('${i + 1}', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(_celdasData[i]['capacidad'].text, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(_celdasData[i]['serie'].text, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(_celdasData[i]['mv_cero'].text, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(_celdasData[i]['mv_carga'].text, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                             pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(_celdasData[i]['resistencia'].text, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
                          ]
                       )
                 ]
              ),
              pw.SizedBox(height: 15),
              
              pw.Text('DIAGNÓSTICO Y OBSERVACIONES:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.Text(_diagnosticoCtrl.text.isNotEmpty ? _diagnosticoCtrl.text : 'Sin fallas mayores detectadas.', style: const pw.TextStyle(fontSize: 9)),
              pw.Spacer(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  pw.Column(children: [
                    _firmaTecnicoB64 != null && _firmaTecnicoB64!.isNotEmpty ? pw.Image(pw.MemoryImage(base64Decode(_firmaTecnicoB64!)), width: 120, height: 60) : pw.SizedBox(height: 60),
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Técnico Responsable', style: const pw.TextStyle(fontSize: 8)),
                  ]),
                  pw.Column(children: [
                    (fCliB64 != null && fCliB64.isNotEmpty) ? pw.Image(pw.MemoryImage(base64Decode(fCliB64)), width: 120, height: 60) : pw.SizedBox(height: 60),
                    pw.Container(width: 160, height: 1, color: PdfColors.black),
                    pw.Text('Recibido por: $nombreReceptor', style: const pw.TextStyle(fontSize: 8)),
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

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: _firmaTecnicoB64 ?? '',
        firmaCliBase64: fCliB64 ?? '',
        nombreIng: nombreReceptor,
        puestoIng: _puestoReceptorCtrl.text.trim(),
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
            'tipo_documento': 'RE',
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'marca': _marcaCtrl.text.trim(),
            'modelo': _modeloCtrl.text.trim(),
            'ns': _serieCtrl.text.trim(),
            'ubicacion': _ubicacionCtrl.text.trim(),
            'observaciones': _diagnosticoCtrl.text.trim(),
            'nombre_ing': nombreReceptor,
            'puesto_ing': _puestoReceptorCtrl.text.trim(),
            'firma_cliente_nombre': nombreReceptor,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: _red, content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio_os'] ?? 'RE-00-000').toString();
    final cliente = (widget.orden['cliente'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _dark,
        foregroundColor: Colors.white,
        title: Text('Revisión Celdas ($folio)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _saving ? null : _finalizarRevision,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Finalizar Revisión de Celdas', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FOLIO: $folio', style: const TextStyle(fontWeight: FontWeight.bold, color: _red)),
                  Text('Cliente: $cliente'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('DATOS DEL INSTRUMENTO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: TextFormField(controller: _marcaCtrl, decoration: const InputDecoration(labelText: 'Marca', isDense: true, border: OutlineInputBorder()))),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _modeloCtrl, decoration: const InputDecoration(labelText: 'Modelo', isDense: true, border: OutlineInputBorder()))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: TextFormField(controller: _serieCtrl, decoration: const InputDecoration(labelText: 'N° de Serie', isDense: true, border: OutlineInputBorder()))),
              const SizedBox(width: 8),
              Expanded(child: TextFormField(controller: _capacidadCtrl, decoration: const InputDecoration(labelText: 'Capacidad Máx.', isDense: true, border: OutlineInputBorder()))),
            ],
          ),
          const SizedBox(height: 16),
          const Text('INSPECCIÓN VISUAL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
          CheckboxListTile(title: const Text('Caja de Sumas'), value: _chkCajaSuma, onChanged: (v) => setState(() => _chkCajaSuma = v ?? false)),
          CheckboxListTile(title: const Text('Topes Longitudinales'), value: _chkTopesLongitudinales, onChanged: (v) => setState(() => _chkTopesLongitudinales = v ?? false)),
          CheckboxListTile(title: const Text('Topes Transversales'), value: _chkTopesTransversales, onChanged: (v) => setState(() => _chkTopesTransversales = v ?? false)),
          CheckboxListTile(title: const Text('Estado de Cables'), value: _chkEstadoCables, onChanged: (v) => setState(() => _chkEstadoCables = v ?? false)),
          const SizedBox(height: 16),
          Row(
             mainAxisAlignment: MainAxisAlignment.spaceBetween,
             children: [
                const Text('TABLA DE CELDAS DE CARGA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
                Row(
                   children: [
                      const Text('Puntos de Apoyo: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      DropdownButton<int>(
                         value: _puntosApoyo,
                         items: [4, 6, 8, 10, 12, 14, 16].map((e) => DropdownMenuItem(value: e, child: Text(e.toString()))).toList(),
                         onChanged: (v) {
                            if (v != null) {
                               setState(() {
                                  _puntosApoyo = v;
                                  _initCeldas();
                               });
                            }
                         }
                      )
                   ]
                )
             ]
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
             scrollDirection: Axis.horizontal,
             child: SizedBox(
                width: 600,
                child: Table(
                   border: TableBorder.all(color: Colors.grey.shade300),
                   columnWidths: const {
                      0: FlexColumnWidth(0.5),
                      1: FlexColumnWidth(1),
                      2: FlexColumnWidth(1),
                      3: FlexColumnWidth(1),
                      4: FlexColumnWidth(1),
                      5: FlexColumnWidth(1),
                   },
                   children: [
                      TableRow(
                         decoration: const BoxDecoration(color: _dark),
                         children: ['Nº', 'Capacidad', 'Nº Serie', 'mV/V Cero', 'mV/V Carga', 'Resistencia Ohms'].map((t) => 
                            Padding(padding: const EdgeInsets.all(8), child: Text(t, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)))
                         ).toList()
                      ),
                      for (int i=0; i<_puntosApoyo; i++)
                         TableRow(
                            children: [
                               Padding(padding: const EdgeInsets.all(8), child: Text('', textAlign: TextAlign.center)),
                               _celdaInput(_celdasData[i]['capacidad']),
                               _celdaInput(_celdasData[i]['serie']),
                               _celdaInput(_celdasData[i]['mv_cero']),
                               _celdaInput(_celdasData[i]['mv_carga']),
                               _celdaInput(_celdasData[i]['resistencia']),
                            ]
                         )
                   ]
                )
             )
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _diagnosticoCtrl,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Diagnóstico y Hallazgos', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const Text('FIRMA DEL CLIENTE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark)),
          const SizedBox(height: 8),
          TextFormField(controller: _nombreReceptorCtrl, onChanged: (_) { if (_errNombreRecibe) setState(() => _errNombreRecibe = false); }, decoration: InputDecoration(labelText: 'Nombre de quien recibe *', errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null, isDense: true, border: const OutlineInputBorder())),
          const SizedBox(height: 6),
          SizedBox(
             height: 180,
             child: SignatureGestureShield(child: Signature(controller: _ctrlFirmaCli, backgroundColor: Colors.white)),
          ),
        ],
      ),
    );
  }
  
  Widget _celdaInput(TextEditingController c) => Padding(
     padding: const EdgeInsets.all(4),
     child: TextField(
        controller: c,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11),
        decoration: InputDecoration(
           isDense: true,
           contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
           border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
        ),
     ),
  );
}
