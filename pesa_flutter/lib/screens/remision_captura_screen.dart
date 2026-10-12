// lib/screens/remision_captura_screen.dart
// Pantalla de Remisión Digital (RMA) — Captura de Refacciones y Firmas Obligatorias.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../widgets/nombre_recibe.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signature/signature.dart';

import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/rma_pdf_service.dart';
import '../widgets/signature_shield.dart';

class RemisionCapturaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;

  const RemisionCapturaScreen({super.key, required this.orden});

  @override
  State<RemisionCapturaScreen> createState() => _RemisionCapturaScreenState();
}

class _PartidaItem {
  final TextEditingController cantidadCtrl;
  final TextEditingController parteCtrl;
  final TextEditingController descCtrl;
  final TextEditingController serieCtrl;

  _PartidaItem({
    String cantidad = '1',
    String parte = '',
    String desc = '',
    String serie = '',
  })  : cantidadCtrl = TextEditingController(text: cantidad),
        parteCtrl = TextEditingController(text: parte),
        descCtrl = TextEditingController(text: desc),
        serieCtrl = TextEditingController(text: serie);

  void dispose() {
    cantidadCtrl.dispose();
    parteCtrl.dispose();
    descCtrl.dispose();
    serieCtrl.dispose();
  }

  Map<String, dynamic> toMap() => {
        'cantidad': cantidadCtrl.text.trim(),
        'numero_parte': parteCtrl.text.trim(),
        'descripcion': descCtrl.text.trim(),
        'numero_serie': serieCtrl.text.trim(),
      };
}

class _RemisionCapturaScreenState extends State<RemisionCapturaScreen>
    with SingleTickerProviderStateMixin {
  static const Color _red = Color(0xFFC8102E);
  static const Color _dark = Color(0xFF1A1A2E);

  final List<_PartidaItem> _partidas = [];
  final TextEditingController _observacionesCtrl = TextEditingController();
  final TextEditingController _nombreReceptorCtrl = TextEditingController();
  bool _errNombreRecibe = false;
  final TextEditingController _puestoReceptorCtrl = TextEditingController();

  final SignatureController _ctrlFirmaTecnico = SignatureController(
    penStrokeWidth: 3,
    penColor: const Color(0xFF1D1D1F),
  );
  final SignatureController _ctrlFirmaCliente = SignatureController(
    penStrokeWidth: 3,
    penColor: const Color(0xFF1D1D1F),
  );

  late final TabController _tabFirmasCtrl;
  bool _saving = false;
  Uint8List? _firmaTecnicoExistente;

  @override
  void initState() {
    super.initState();
    _tabFirmasCtrl = TabController(length: 2, vsync: this);
    _cargarDatosIniciales();
  }

  @override
  void dispose() {
    for (final p in _partidas) {
      p.dispose();
    }
    _observacionesCtrl.dispose();
    _nombreReceptorCtrl.dispose();
    _puestoReceptorCtrl.dispose();
    _ctrlFirmaTecnico.dispose();
    _ctrlFirmaCliente.dispose();
    _tabFirmasCtrl.dispose();
    super.dispose();
  }

  void _cargarDatosIniciales() async {
    final o = widget.orden;

    // 1. Cargar observaciones previas
    _observacionesCtrl.text = (o['observaciones'] ?? o['obs'] ?? '').toString();

    // 2. Cargar receptor previo
    _nombreReceptorCtrl.text =
        (o['firma_cliente_nombre'] ?? o['nombre_ing'] ?? '').toString();
    _puestoReceptorCtrl.text = (o['puesto_ing'] ?? '').toString();

    // 3. Cargar refacciones / partidas
    List<dynamic> rawItems = [];
    if (o['items'] is List) {
      rawItems = o['items'] as List;
    } else if (o['refacciones'] is List) {
      rawItems = o['refacciones'] as List;
    } else if (o['partidas'] is List) {
      rawItems = o['partidas'] as List;
    } else if (o['datos_captura'] != null) {
      try {
        final dc = o['datos_captura'] is String
            ? jsonDecode(o['datos_captura'] as String)
            : o['datos_captura'];
        if (dc is Map && dc['items'] is List) {
          rawItems = dc['items'] as List;
        } else if (dc is Map && dc['refacciones'] is List) {
          rawItems = dc['refacciones'] as List;
        }
      } catch (_) {}
    }

    if (rawItems.isNotEmpty) {
      for (final it in rawItems) {
        if (it is Map) {
          _partidas.add(_PartidaItem(
            cantidad: (it['cantidad'] ?? '1').toString(),
            parte: (it['numero_parte'] ?? it['parte'] ?? '').toString(),
            desc: (it['descripcion'] ?? it['desc'] ?? '').toString(),
            serie: (it['numero_serie'] ?? it['serie'] ?? '').toString(),
          ));
        }
      }
    }

    // Si no hay partidas previas, agregamos una vacía por defecto
    if (_partidas.isEmpty) {
      _partidas.add(_PartidaItem());
    }

    // 4. Cargar firma guardada del técnico
    try {
      final username = (o['tecnico_username'] ?? o['tecnico'] ?? '').toString();
      final savedFirmaTec = await FirmaTecnicoService.instance.getFirma(username);
      if (savedFirmaTec != null && savedFirmaTec.isNotEmpty) {
        final clean = savedFirmaTec.contains(',')
            ? savedFirmaTec.split(',').last
            : savedFirmaTec;
        setState(() {
          _firmaTecnicoExistente = base64Decode(clean);
        });
      }
    } catch (_) {}

    // Cargar firmas previas de la orden si existen
    if (o['firma_tecnico'] != null && o['firma_tecnico'].toString().isNotEmpty) {
      try {
        final raw = o['firma_tecnico'].toString().contains(',')
            ? o['firma_tecnico'].toString().split(',').last
            : o['firma_tecnico'].toString();
        setState(() {
          _firmaTecnicoExistente = base64Decode(raw);
        });
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  void _agregarPartida() {
    setState(() {
      _partidas.add(_PartidaItem());
    });
  }

  void _eliminarPartida(int index) {
    if (_partidas.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debe existir al menos una partida.')),
      );
      return;
    }
    setState(() {
      final removed = _partidas.removeAt(index);
      removed.dispose();
    });
  }

  Future<void> _guardarBorrador() async {
    final localId = widget.orden['local_id'] as int? ?? 0;
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio_rma'] ?? '').toString();

    final draft = {
      'items': _partidas.map((p) => p.toMap()).toList(),
      'observaciones': _observacionesCtrl.text.trim(),
      'nombre_ing': _nombreReceptorCtrl.text.trim(),
      'puesto_ing': _puestoReceptorCtrl.text.trim(),
    };

    await LocalDbService.instance.saveDraft(folio, draft);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.teal,
          content: Text('Borrador de Remisión guardado localmente.'),
        ),
      );
    }
  }

  Future<void> _finalizarRemision() async {
    // 1. Validar partidas
    final itemsValidos = _partidas
        .map((p) => p.toMap())
        .where((m) => (m['descripcion'] as String).isNotEmpty)
        .toList();

    if (itemsValidos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _red,
          content: Text('Agrega al menos una partida con descripción.'),
        ),
      );
      return;
    }

    // 2. Validar firma del técnico
    String? firmaTecB64;
    if (_ctrlFirmaTecnico.isNotEmpty) {
      final bytes = await _ctrlFirmaTecnico.toPngBytes();
      if (bytes != null) firmaTecB64 = base64Encode(bytes);
    } else if (_firmaTecnicoExistente != null) {
      firmaTecB64 = base64Encode(_firmaTecnicoExistente!);
    }

    if (firmaTecB64 == null || firmaTecB64.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _red,
          content: Text('La Firma del Técnico Asignado es obligatoria.'),
        ),
      );
      _tabFirmasCtrl.animateTo(0);
      return;
    }

    // 3. Validar receptor y firma del cliente
    final nombreReceptor = _nombreReceptorCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombreReceptor)) {
      setState(() => _errNombreRecibe = true);
      _tabFirmasCtrl.animateTo(1);
      return;
    }

    String? firmaCliB64;
    if (_ctrlFirmaCliente.isNotEmpty) {
      final bytes = await _ctrlFirmaCliente.toPngBytes();
      if (bytes != null) firmaCliB64 = base64Encode(bytes);
    }

    // Firma del cliente/receptor OPCIONAL (si no puede firmar en pantalla); el nombre es obligatorio.

    setState(() => _saving = true);

    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? widget.orden['folio_rma'] ?? 'RMA').toString();

      final rmaData = Map<String, dynamic>.from(widget.orden);
      rmaData['firma_cliente_nombre'] = nombreReceptor;
      rmaData['puesto_ing'] = _puestoReceptorCtrl.text.trim();
      rmaData['observaciones'] = _observacionesCtrl.text.trim();

      // Generar PDF
      final pdfBytes = await RmaPdfService.generate(
        rmaData: rmaData,
        items: itemsValidos,
        firmaTecBase64: firmaTecB64,
        firmaCliBase64: firmaCliB64,
        observaciones: _observacionesCtrl.text.trim(),
      );

      // Guardar PDF en disco local
      final dir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${dir.path}/pdfs');
      if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
      final pdfPath = '${pdfDir.path}/$folio.pdf';
      final file = File(pdfPath);
      await file.writeAsBytes(pdfBytes, flush: true);

      final pdfB64 = base64Encode(pdfBytes);

      // Guardar firmas y estado cerrado en SQLite local
      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: firmaTecB64,
        firmaCliBase64: firmaCliB64 ?? '',
        nombreIng: nombreReceptor,
        puestoIng: _puestoReceptorCtrl.text.trim(),
      );

      // Subir al servidor si hay conexión
      bool subio = false;
      try {
        subio = await ApiService.instance.uploadPdf(
          folio,
          file,
          osId: localId,
          data: {
            'tipo_documento': 'RMA',
            'items': itemsValidos,
            'nombre_receptor': nombreReceptor,
            'puesto_receptor': _puestoReceptorCtrl.text.trim(),
          },
        );
      } catch (_) {}

      await LocalDbService.instance.savePdfPath(
        localId,
        pdfPath,
        folio: folio,
        pdfB64: pdfB64,
        isOnline: subio,
        uploadOk: subio,
      );

      if (mounted) {
        setState(() => _saving = false);
        _mostrarDialogoExito(pdfPath, folio);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: _red, content: Text('Error al generar remisión: $e')),
        );
      }
    }
  }

  void _mostrarDialogoExito(String pdfPath, String folio) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
            SizedBox(width: 8),
            Text('Remisión Finalizada', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'El documento $folio fue generado y firmado exitosamente en formato oficial calca.',
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              OpenFilex.open(pdfPath);
            },
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Ver PDF'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context, true);
            },
            child: const Text('Volver al Listado'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio_rma'] ?? 'RMA').toString();
    final cliente = (widget.orden['cliente'] ?? widget.orden['cliente_nombre'] ?? '').toString();
    final direccion = (widget.orden['direccion'] ?? widget.orden['sucursal'] ?? '').toString();
    final tecnico = (widget.orden['tecnico'] ?? widget.orden['tecnico_nombre'] ?? '').toString();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        backgroundColor: _dark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Remisión de Material ($folio)',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _guardarBorrador,
            icon: const Icon(Icons.save_outlined, color: Colors.white70, size: 18),
            label: const Text('Borrador', style: TextStyle(color: Colors.white70)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, -3)),
            ],
          ),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _saving ? null : _finalizarRemision,
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.assignment_turned_in_rounded),
            label: Text(
              _saving ? 'Generando PDF y Firmando...' : 'Finalizar y Generar PDF Oficial',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Tarjeta de Datos Generales ──────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'FOLIO: $folio',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _red),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'RMA DIGITAL',
                          style: TextStyle(color: _red, fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  _buildMetaRow('Cliente', cliente),
                  const SizedBox(height: 6),
                  _buildMetaRow('Dirección / Sucursal', direccion),
                  const SizedBox(height: 6),
                  _buildMetaRow('Técnico Asignado', tecnico),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección de Refacciones / Partidas ────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'PARTIDAS / REFACCIONES A ENTREGAR',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark, letterSpacing: 0.5),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _dark,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _agregarPartida,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Agregar Partida', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 10),

          ..._partidas.asMap().entries.map((entry) {
            final idx = entry.key;
            final item = entry.value;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Partida #${idx + 1}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _red),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                          onPressed: () => _eliminarPartida(idx),
                          tooltip: 'Eliminar partida',
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 80,
                          child: TextFormField(
                            controller: item.cantidadCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Cant. *',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: item.parteCtrl,
                            decoration: const InputDecoration(
                              labelText: 'N° de Parte (opcional)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: item.descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Descripción del Material / Refacción *',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: item.serieCtrl,
                      decoration: const InputDecoration(
                        labelText: 'N° de Serie (opcional)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),

          // ── Observaciones Generales ─────────────────────────────────────
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OBSERVACIONES GENERALES',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _dark),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _observacionesCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Anotaciones adicionales sobre la entrega, estado de los componentes, etc.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección de Firmas Obligatorias ──────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.draw_rounded, color: _red, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'FIRMAS OBLIGATORIAS DE ENTREGA',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _dark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TabBar(
                    controller: _tabFirmasCtrl,
                    labelColor: _red,
                    unselectedLabelColor: Colors.grey.shade600,
                    indicatorColor: _red,
                    tabs: const [
                      Tab(icon: Icon(Icons.engineering_rounded), text: '1. Técnico Asignado *'),
                      Tab(icon: Icon(Icons.person_pin_rounded), text: '2. Cliente / Receptor *'),
                    ],
                  ),
                  SizedBox(
                    height: 280,
                    child: TabBarView(
                      controller: _tabFirmasCtrl,
                      children: [
                        // Tab Técnico
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Entregado por: ${tecnico.isNotEmpty ? tecnico : "Técnico PESA"}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              const SizedBox(height: 6),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(8),
                                    color: Colors.white,
                                  ),
                                  child: _firmaTecnicoExistente != null && _ctrlFirmaTecnico.isEmpty
                                      ? Stack(
                                          children: [
                                            Center(child: Image.memory(_firmaTecnicoExistente!)),
                                            Positioned(
                                              top: 4,
                                              right: 4,
                                              child: ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.grey.shade200,
                                                  foregroundColor: Colors.black87,
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                ),
                                                onPressed: () {
                                                  setState(() => _firmaTecnicoExistente = null);
                                                },
                                                child: const Text('Re-firmar', style: TextStyle(fontSize: 11)),
                                              ),
                                            ),
                                          ],
                                        )
                                      : SignatureGestureShield(
                                          child: Signature(
                                            controller: _ctrlFirmaTecnico,
                                            backgroundColor: Colors.white,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () => _ctrlFirmaTecnico.clear(),
                                  icon: const Icon(Icons.clear, size: 16),
                                  label: const Text('Limpiar Trazo'),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Tab Cliente
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _nombreReceptorCtrl,
                                      onChanged: (_) {
                                        if (_errNombreRecibe) setState(() => _errNombreRecibe = false);
                                      },
                                      decoration: InputDecoration(
                                        errorText: _errNombreRecibe ? kMsgNombreRecibeObligatorio : null,
                                        labelText: 'Nombre de quien recibe *',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _puestoReceptorCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Puesto / Cargo',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(8),
                                    color: Colors.white,
                                  ),
                                  child: SignatureGestureShield(
                                    child: Signature(
                                      controller: _ctrlFirmaCliente,
                                      backgroundColor: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () => _ctrlFirmaCliente.clear(),
                                  icon: const Icon(Icons.clear, size: 16),
                                  label: const Text('Limpiar Trazo'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Text(
            value.isNotEmpty ? value : '—',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
        ),
      ],
    );
  }
}
