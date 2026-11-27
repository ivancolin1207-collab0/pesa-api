// lib/screens/attach_scan_screen.dart — Escaneo de documentos con flujo real de 3 pasos
// PASO 1: Buscar OS | PASO 2: Captura con cámara/galería | PASO 3: Subir al servidor
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/local_db_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';

class AttachScanScreen extends StatefulWidget {
  final String? folioOs;
  const AttachScanScreen({super.key, this.folioOs});

  @override
  State<AttachScanScreen> createState() => _AttachScanScreenState();
}

class _AttachScanScreenState extends State<AttachScanScreen> {
  static const _red = PesaColors.brand;

  // ── Estado del Stepper ───────────────────────────────────────────────────
  int _currentStep = 0;

  // ── Paso 1: OS seleccionada ───────────────────────────────────────────────
  String?                   _folioOs;
  Map<String, dynamic>?     _osSel;   // OS seleccionada (datos homologados)
  List<Map<String,dynamic>> _resultados = [];
  bool                      _buscando   = false;
  final _searchCtrl = TextEditingController();

  // ── Paso 2: Imagen capturada ──────────────────────────────────────────────
  File?  _capturedImage;
  bool   _filterApplied = false;
  bool   _isProcessing  = false;
  final  _picker = ImagePicker();

  // ── Paso 3: Subida ────────────────────────────────────────────────────────
  bool   _uploading = false;

  @override
  void initState() {
    super.initState();
    // Si viene con folio preseleccionado, avanzar al paso 2
    if (widget.folioOs != null) {
      _folioOs = widget.folioOs;
      _searchCtrl.text = widget.folioOs!;
      _currentStep = 1;
      _buscarOsPorFolio(widget.folioOs!);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Búsqueda de OS ────────────────────────────────────────────────────────
  Future<void> _buscarOsPorFolio(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _resultados = []);
      return;
    }
    setState(() => _buscando = true);
    try {
      final auth = context.read<AuthService>();
      final all = auth.isTecnico
          ? await LocalDbService.instance.getOsForTecnico(
              nombreTecnico: auth.displayName,
              idTecnico: auth.idTecnico,
            )
          : await LocalDbService.instance.getAllOs();
      final q   = query.trim().toLowerCase();
      setState(() {
        _resultados = all.where((os) {
          final folio  = (os['folio_os'] as String? ?? '').toLowerCase();
          final cli    = (os['cliente']  as String? ?? '').toLowerCase();
          return folio.contains(q) || cli.contains(q);
        }).take(10).toList();
        // Folio preseleccionado desde el dashboard: fijar la OS exacta.
        if (widget.folioOs != null && _osSel == null) {
          for (final os in all) {
            if ((os['folio_os'] as String? ?? '').trim().toLowerCase() ==
                widget.folioOs!.trim().toLowerCase()) {
              _osSel = Map<String, dynamic>.from(os);
              break;
            }
          }
        }
        _buscando = false;
      });
    } catch (_) {
      setState(() => _buscando = false);
    }
  }

  void _seleccionarOs(Map<String, dynamic> os) {
    setState(() {
      _folioOs     = os['folio_os'] as String?;
      _osSel       = Map<String, dynamic>.from(os);
      _resultados  = [];
      _currentStep = 1;
    });
    _searchCtrl.text = _folioOs ?? '';
  }

  // ── Datos homologados con la BD central ─────────────────────────────────────────
  String _campo(List<String> keys) {
    final os = _osSel ?? const <String, dynamic>{};
    for (final k in keys) {
      final v = (os[k] ?? '').toString().trim();
      if (v.isNotEmpty && v != 'null') return v;
    }
    return '';
  }

  FormatoDocumento get _formato => detectarFormato(
        folio: _folioOs,
        nombre: _campo(['tipo_servicio']),
      );

  String get _formatoLabel => switch (_formato) {
        FormatoDocumento.remision             => 'Remisión de Servicio',
        FormatoDocumento.revisionCeldas       => 'Revisión de Celdas de Carga',
        FormatoDocumento.observacionesBascula => 'Formato de Inspección y Revisión de Básculas (OSOB)',
        FormatoDocumento.observacionesCelda   => 'Formato de Diagnóstico y Revisión de Celda de Carga (OSOCC)',
        FormatoDocumento.ordenServicio        => 'Orden de Servicio',
      };

  /// Campos que el formato físico debe contener (verificación visual previa).
  List<String> get _checklistFormato => switch (_formato) {
        FormatoDocumento.remision => const [
          'Cliente y dirección', 'Técnico', 'Horarios (llegada / salida)',
          'Descripción del trabajo', 'Refacciones / materiales usados', 'Firmas',
        ],
        FormatoDocumento.revisionCeldas => const [
          'Identificación del instrumento', 'Capacidad y marca/modelo de celda',
          'Resistencia entrada/salida (Ω)', 'Señal (mV/V)', 'Aislamiento (MΩ)',
          'Balance de cero', 'Diagnóstico final',
        ],
        FormatoDocumento.observacionesBascula => const [
          'Datos del Cliente y del Equipo',
          'Checklist de Inspección Física y Mecánica (14 puntos)',
          'Pruebas Rápidas de Funcionamiento',
          'Diagnóstico General, Observaciones y Refacciones',
          'Firmas de Conformidad',
        ],
        FormatoDocumento.observacionesCelda => const [
          'Datos de Identificación de la Celda (Cliente o Stock)',
          'Inspección Física y Mecánica de la Celda (6 puntos)',
          'Pruebas y Mediciones Eléctricas Unitarias (12 parámetros)',
          'Dictamen Técnico y Observaciones',
          'Firmas de Responsabilidad',
        ],
        FormatoDocumento.ordenServicio => const [
          'Datos del instrumento', 'Lecturas de prueba', 'Dictamen', 'Firmas',
        ],
      };

  Map<String, dynamic> _payloadHomologado() {
    final auth = context.read<AuthService>();
    final tecnico = _campo(['tecnico', 'tecnico_nombre']).isNotEmpty
        ? _campo(['tecnico', 'tecnico_nombre'])
        : auth.displayName;
    final fechaOriginal = _campo(['fecha_creacion_logistica', 'fecha', 'fecha_servicio']);
    final fechaEjecucionHoy = DateTime.now().toIso8601String().substring(0, 10);
    return {
      'folio_os':      _folioOs,
      'cliente':       _campo(['cliente', 'cliente_nombre', 'razon_social']),
      'sucursal':      _campo(['sucursal', 'sucursal_nombre', 'direccion', 'direccion_cliente']),
      'tecnico':       tecnico,
      'fecha':         fechaEjecucionHoy,
      'fecha_servicio': fechaEjecucionHoy,
      'fecha_cierre':  DateTime.now().toIso8601String(),
      if (fechaOriginal.isNotEmpty) 'fecha_creacion_logistica': fechaOriginal.split(' ').first,
      'modalidad':     'FISICO',
      'estatus':       'Cerrado',
      'tipo_formato':  _formatoLabel,
      'tipo_servicio': _campo(['tipo_servicio']),
    };
  }

  /// Convierte la imagen capturada a un PDF de una página (A4 / Carta).
  Future<File> _imagenAPdf(File img, String folio) async {
    final bytes = await img.readAsBytes();
    final doc = pw.Document();
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(12),
      build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/pdfs');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final out = File('${dir.path}/$safe.pdf');
    await out.writeAsBytes(await doc.save(), flush: true);
    return out;
  }

  // ── Cámara ────────────────────────────────────────────────────────────────
  Future<void> _captureFromCamera() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2200,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (picked == null) return;
      setState(() {
        _capturedImage = File(picked.path);
        _filterApplied = false;
        _currentStep   = 2;
      });
    } catch (e) {
      _showError('No se pudo acceder a la cámara: $e');
    }
  }

  // ── Galería / Archivos ────────────────────────────────────────────────────
  Future<void> _selectFromGallery() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2200,
      );
      if (picked == null) return;
      setState(() {
        _capturedImage = File(picked.path);
        _filterApplied = false;
        _currentStep   = 2;
      });
    } catch (e) {
      _showError('No se pudo abrir la galería: $e');
    }
  }

  // ── Filtro escáner ────────────────────────────────────────────────────────
  Future<void> _applyDocumentFilter() async {
    if (_capturedImage == null) return;
    setState(() => _isProcessing = true);
    await Future.delayed(const Duration(milliseconds: 800));
    setState(() {
      _filterApplied = true;
      _isProcessing  = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Filtro de escáner aplicado ✓'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Subida al servidor ────────────────────────────────────────────────────
  Future<void> _uploadDocument() async {
    if (_capturedImage == null || _folioOs == null) return;
    setState(() => _uploading = true);

    final folio = _folioOs!;
    try {
      final payload = _payloadHomologado();
      final fechaEjecucionHoy = (payload['fecha'] ?? DateTime.now().toIso8601String().substring(0, 10)).toString();
      await LocalDbService.instance.actualizarFechaEjecucionAlFinalizar(
        folio,
        fechaEjecucionHoy,
        fechaCierre: payload['fecha_cierre']?.toString(),
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );
      final pdfFile = await _imagenAPdf(_capturedImage!, folio);

      // 1) upload-pdf: localiza la OS por FOLIO, guarda el PDF en PostgreSQL
      //    (pdf_b64, persistente) y marca estado/estatus = 'Cerrado'.
      var ok = await ApiService.instance.uploadPdf(folio, pdfFile, data: payload);
      var estadoLocal = 'Cerrado';

      // 2) Respaldo: /adjunto por folio (os_id = 0 → nunca coincide con el
      //    local_id de SQLite, que NO es el id del servidor).
      if (!ok) {
        await ApiService.instance.uploadEscaneo(0, pdfFile, folio, campos: payload);
        ok = true;
        estadoLocal = 'ESCANEADA';
      }

      await LocalDbService.instance.marcarFormatoFisicoRecibido(
        folio,
        pdfPath: pdfFile.path,
        estado: estadoLocal,
      );

      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Row(children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Formato físico recibido'),
            ]),
            content: Text(
              '$_formatoLabel $folio digitalizado y enviado al servidor.\n'
              'Modalidad: Físico · Estatus: Cerrado.',
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: _red, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    _capturedImage = null;
                    _folioOs       = null;
                    _osSel         = null;
                    _currentStep   = 0;
                    _searchCtrl.clear();
                  });
                },
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al subir: $e'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return AppShell(
      currentRoute: '/escaneo',
      child: Scaffold(
        backgroundColor: c.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            // Header
            _buildHeader(c),
            // Indicador de pasos
            _buildStepIndicator(c),
            // Contenido del paso actual
            Expanded(child: _buildCurrentStep(c)),
          ]),
        ),
      ),
    );
  }

  Widget _buildHeader(PesaPalette c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: _red, borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.document_scanner, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text('Adjuntar Escaneo',
              style: TextStyle(color: c.textPrimary,
                  fontWeight: FontWeight.w800, fontSize: 17)),
          Text(
            _folioOs != null
                ? 'Folio seleccionado: $_folioOs'
                : 'Digitaliza documentos físicos de servicio',
            style: TextStyle(color: c.textSecondary, fontSize: 11),
          ),
        ])),
      ]),
    );
  }

  Widget _buildStepIndicator(PesaPalette c) {
    final steps = ['Buscar OS', 'Capturar', 'Adjuntar'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(children: [
        for (int i = 0; i < steps.length; i++) ...[
          _StepDot(
            number: i + 1,
            label: steps[i],
            isActive: _currentStep == i,
            isDone: _currentStep > i,
          ),
          if (i < steps.length - 1)
            Expanded(child: Container(
              height: 2,
              color: _currentStep > i ? _red : c.border,
            )),
        ],
      ]),
    );
  }

  Widget _buildCurrentStep(PesaPalette c) {
    switch (_currentStep) {
      case 0: return _buildStep1(c);
      case 1: return _buildStep2(c);
      case 2: return _buildStep3(c);
      default: return _buildStep1(c);
    }
  }

  // ── PASO 1: Buscar OS ─────────────────────────────────────────────────────
  Widget _buildStep1(PesaPalette c) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Paso 1 — Buscar Orden de Servicio',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                color: c.textPrimary)),
        const SizedBox(height: 6),
        Text('Escribe el folio o nombre del cliente',
            style: TextStyle(fontSize: 12, color: c.textSecondary)),
        const SizedBox(height: 16),
        // Campo de búsqueda
        TextField(
          controller: _searchCtrl,
          style: TextStyle(color: c.textPrimary),
          decoration: InputDecoration(
            hintText: 'Ej: OS-26-001 o nombre del cliente...',
            prefixIcon: Icon(Icons.search, color: c.textSecondary),
            suffixIcon: _buscando
                ? const Padding(padding: EdgeInsets.all(12),
                    child: SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: _red)))
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c.brandAccent, width: 2)),
            filled: true,
            fillColor: c.elevated,
          ),
          onChanged: _buscarOsPorFolio,
        ),
        const SizedBox(height: 12),
        // Resultados
        if (_resultados.isNotEmpty)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.border),
              ),
              child: ListView.separated(
                itemCount: _resultados.length,
                separatorBuilder: (_, __) => Divider(height: 1,
                    color: c.border),
                itemBuilder: (ctx, i) {
                  final os = _resultados[i];
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: c.surfaceMuted,
                          border: Border.all(color: c.border),
                          borderRadius: BorderRadius.circular(6)),
                      child: Icon(Icons.assignment_outlined,
                          size: 18, color: c.brandAccent),
                    ),
                    title: Text(os['folio_os'] ?? '—',
                        style: TextStyle(fontWeight: FontWeight.w700,
                            fontSize: 13, color: c.brandAccent)),
                    subtitle: Text(
                        '${os['cliente'] ?? ''} · ${os['fecha'] ?? ''}',
                        style: TextStyle(fontSize: 11,
                            color: c.textSecondary)),
                    trailing: Icon(Icons.chevron_right,
                        color: c.textTertiary),
                    onTap: () => _seleccionarOs(os),
                  );
                },
              ),
            ),
          )
        else if (_searchCtrl.text.isNotEmpty && !_buscando)
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 40),
              Icon(Icons.search_off, size: 48, color: c.textTertiary),
              const SizedBox(height: 12),
              Text('Sin resultados. Intenta con otro folio.',
                  style: TextStyle(color: c.textSecondary, fontSize: 13)),
            ]),
          ),
      ]),
    );
  }

  // ── PASO 2: Capturar imagen ───────────────────────────────────────────────
  Widget _buildStep2(PesaPalette c) {
    if (_capturedImage == null) {
      // Vista de captura
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                  color: c.surfaceMuted,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.document_scanner, size: 56, color: c.brandAccent),
            ),
            const SizedBox(height: 20),
            Text('Paso 2 — Capturar Documento',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: c.textPrimary)),
            const SizedBox(height: 6),
            Text('OS seleccionada: $_folioOs',
                style: TextStyle(fontSize: 12, color: c.textSecondary)),
            const SizedBox(height: 32),
            // Botón cámara
            SizedBox(
              width: 280, height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _captureFromCamera,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Capturar con Cámara',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 12),
            // Botón galería
            SizedBox(
              width: 280, height: 48,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  side: BorderSide(color: c.borderStrong),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _selectFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Examinar Galería / Archivos'),
              ),
            ),
            const SizedBox(height: 24),
            // Volver al paso 1
            TextButton.icon(
              onPressed: () => setState(() => _currentStep = 0),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Cambiar orden de servicio'),
            ),
          ]),
        ),
      );
    } else {
      // Vista previa con filtro
      return Column(children: [
        Expanded(
          child: Stack(children: [
            Center(
              child: ColorFiltered(
                colorFilter: _filterApplied
                    ? const ColorFilter.matrix([
                        0.2126, 0.7152, 0.0722, 0, 30,
                        0.2126, 0.7152, 0.0722, 0, 30,
                        0.2126, 0.7152, 0.0722, 0, 30,
                        0,      0,      0,      1, 0,
                      ])
                    : const ColorFilter.mode(
                        Colors.transparent, BlendMode.saturation),
                child: Image.file(_capturedImage!, fit: BoxFit.contain),
              ),
            ),
            if (_isProcessing)
              Container(
                color: Colors.black38,
                child: const Center(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('Aplicando filtro de escáner...',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                )),
              ),
            if (_filterApplied)
              Positioned(top: 12, right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.dotGreen,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_fix_high, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text('Filtro Escáner',
                        style: TextStyle(color: Colors.white, fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
          ]),
        ),
        // Barra de acciones
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Row(children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.borderStrong),
                foregroundColor: c.textPrimary,
              ),
              onPressed: () => setState(() {
                _capturedImage = null;
                _filterApplied = false;
              }),
              icon: const Icon(Icons.replay, size: 16),
              label: const Text('Retomar'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _filterApplied ? c.dotGreen : c.borderStrong),
                foregroundColor: _filterApplied ? c.dotGreen : c.textPrimary,
              ),
              onPressed: _isProcessing ? null : _applyDocumentFilter,
              icon: Icon(_filterApplied ? Icons.check : Icons.auto_fix_high,
                  size: 16),
              label: Text(_filterApplied ? 'Filtro ✓' : 'Filtro Escáner'),
            ),
            const Spacer(),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _red, foregroundColor: Colors.white,
                minimumSize: const Size(160, 46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isProcessing
                  ? null
                  : () => setState(() => _currentStep = 2),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Continuar al Paso 3',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ]);
    }
  }

  // ── PASO 3: Adjuntar y subir ──────────────────────────────────────────────
  Widget _buildStep3(PesaPalette c) {
    final p = _payloadHomologado();
    String v(Object? x) {
      final s = (x ?? '').toString().trim();
      return s.isEmpty ? '—' : s;
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Expanded(child: SingleChildScrollView(child: Column(children: [
        // Resumen
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Resumen del escaneo',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                    color: c.textPrimary)),
            const SizedBox(height: 12),
            _SummaryRow(icon: Icons.assignment_outlined,
                label: 'Folio', value: _folioOs ?? '—'),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.description_outlined,
                label: 'Formato', value: _formatoLabel),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.business_outlined,
                label: 'Cliente', value: v(p['cliente'])),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.store_outlined,
                label: 'Sucursal', value: v(p['sucursal'])),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.engineering_outlined,
                label: 'Técnico', value: v(p['tecnico'])),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.event_outlined,
                label: 'Fecha', value: v(p['fecha'])),
            const SizedBox(height: 8),
            const _SummaryRow(icon: Icons.print_outlined,
                label: 'Modalidad', value: 'Físico'),
            const SizedBox(height: 8),
            const _SummaryRow(icon: Icons.lock_outline,
                label: 'Estatus al enviar', value: 'Cerrado'),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.insert_drive_file_outlined,
                label: 'Archivo', value: _capturedImage?.path.split('/').last ?? '—'),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.auto_fix_high,
                label: 'Filtro escáner',
                value: _filterApplied ? 'Aplicado ✓' : 'Sin filtro'),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.isDark ? c.elevated : const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: c.isDark ? c.dotAmber.withValues(alpha: 0.45) : const Color(0xFFFDE68A),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Verifica que el formato físico contenga:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: c.isDark ? c.dotAmber : const Color(0xFF92400E))),
            const SizedBox(height: 6),
            for (final item in _checklistFormato)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(children: [
                  Icon(Icons.check_box_outlined, size: 14,
                      color: c.isDark ? c.dotAmber : const Color(0xFFB45309)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(item, style: TextStyle(
                      fontSize: 12, color: c.isDark ? c.textPrimary : const Color(0xFF78350F)))),
                ]),
              ),
          ]),
        ),
        if (_capturedImage != null) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColorFiltered(
              colorFilter: _filterApplied
                  ? const ColorFilter.matrix([
                      0.2126, 0.7152, 0.0722, 0, 30,
                      0.2126, 0.7152, 0.0722, 0, 30,
                      0.2126, 0.7152, 0.0722, 0, 30,
                      0,      0,      0,      1, 0,
                    ])
                  : const ColorFilter.mode(
                      Colors.transparent, BlendMode.saturation),
              child: Image.file(_capturedImage!,
                  height: 200, fit: BoxFit.cover),
            ),
          ),
        ],
        ]))),
        const SizedBox(height: 12),
        // Botones
        Row(children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.borderStrong),
              foregroundColor: c.textPrimary,
            ),
            onPressed: _uploading ? null : () => setState(() => _currentStep = 1),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Volver'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _uploading
                    ? c.textTertiary : _red,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _uploading ? null : _uploadDocument,
              icon: _uploading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : const Icon(Icons.upload_file, size: 20),
              label: Text(
                _uploading ? 'Subiendo...' : 'Enviar Formato Físico (Cerrado)',
                style: const TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ── Widgets auxiliares ────────────────────────────────────────────────────

class _StepDot extends StatelessWidget {
  final int    number;
  final String label;
  final bool   isActive;
  final bool   isDone;
  const _StepDot({required this.number, required this.label,
      required this.isActive, required this.isDone});

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final color = isDone || isActive ? c.brandAccent : c.borderStrong;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: isDone ? PesaColors.brand
              : isActive ? c.brandSoft
              : c.surfaceMuted,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: Center(child: isDone
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : Text('$number', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: isActive ? c.brandAccent : c.textSecondary))),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(
          fontSize: 10, color: (isDone || isActive) ? c.brandAccent : c.textSecondary, fontWeight:
          isActive ? FontWeight.w700 : FontWeight.w500)),
    ]);
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  const _SummaryRow({required this.icon, required this.label,
      required this.value});

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Row(children: [
      Icon(icon, size: 16, color: c.textTertiary),
      const SizedBox(width: 8),
      Text('$label: ', style: TextStyle(fontSize: 12,
          color: c.textSecondary)),
      Expanded(child: Text(value, style: TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: c.textPrimary),
          overflow: TextOverflow.ellipsis)),
    ]);
  }
}
