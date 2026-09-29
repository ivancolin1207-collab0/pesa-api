// lib/screens/attach_scan_screen.dart — Escaneo de documentos con flujo real de 3 pasos
// PASO 1: Buscar OS | PASO 2: Captura con cámara/galería | PASO 3: Subir al servidor
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/local_db_service.dart';
import '../widgets/app_shell.dart';

class AttachScanScreen extends StatefulWidget {
  final String? folioOs;
  const AttachScanScreen({super.key, this.folioOs});

  @override
  State<AttachScanScreen> createState() => _AttachScanScreenState();
}

class _AttachScanScreenState extends State<AttachScanScreen> {
  static const _red    = Color(0xFFC8102E);
  static const _border = Color(0xFFE5E7EB);
  static const _bg     = Color(0xFFF9FAFB);

  // ── Estado del Stepper ───────────────────────────────────────────────────
  int _currentStep = 0;

  // ── Paso 1: OS seleccionada ───────────────────────────────────────────────
  String?                   _folioOs;
  int?                      _osId;
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
        _buscando = false;
      });
    } catch (_) {
      setState(() => _buscando = false);
    }
  }

  void _seleccionarOs(Map<String, dynamic> os) {
    setState(() {
      _folioOs     = os['folio_os'] as String?;
      _osId        = os['local_id'] as int?;
      _resultados  = [];
      _currentStep = 1;
    });
    _searchCtrl.text = _folioOs ?? '';
  }

  // ── Cámara ────────────────────────────────────────────────────────────────
  Future<void> _captureFromCamera() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
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
        imageQuality: 90,
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

    try {
      await ApiService.instance.uploadEscaneo(
        _osId ?? 0,
        _capturedImage!,
        _folioOs!,
      );
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Row(children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Escaneo adjuntado'),
            ]),
            content: Text(
              'El documento fue subido exitosamente a la orden $_folioOs.\n'
              'Se actualizará en el servidor en la próxima sincronización.',
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
                    _osId          = null;
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
    return AppShell(
      currentRoute: '/escaneo',
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            // Header
            _buildHeader(),
            // Indicador de pasos
            _buildStepIndicator(),
            // Contenido del paso actual
            Expanded(child: _buildCurrentStep()),
          ]),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
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
          const Text('Adjuntar Escaneo',
              style: TextStyle(color: Color(0xFF111827),
                  fontWeight: FontWeight.w800, fontSize: 17)),
          Text(
            _folioOs != null
                ? 'Folio seleccionado: $_folioOs'
                : 'Digitaliza documentos físicos de servicio',
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 11),
          ),
        ])),
      ]),
    );
  }

  Widget _buildStepIndicator() {
    final steps = ['Buscar OS', 'Capturar', 'Adjuntar'];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
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
              color: _currentStep > i ? _red : const Color(0xFFE5E7EB),
            )),
        ],
      ]),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0: return _buildStep1();
      case 1: return _buildStep2();
      case 2: return _buildStep3();
      default: return _buildStep1();
    }
  }

  // ── PASO 1: Buscar OS ─────────────────────────────────────────────────────
  Widget _buildStep1() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Paso 1 — Buscar Orden de Servicio',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        const SizedBox(height: 6),
        const Text('Escribe el folio o nombre del cliente',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
        // Campo de búsqueda
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Ej: OS-26-001 o nombre del cliente...',
            prefixIcon: const Icon(Icons.search, color: Color(0xFF9CA3AF)),
            suffixIcon: _buscando
                ? const Padding(padding: EdgeInsets.all(12),
                    child: SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: _red)))
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _red, width: 2)),
            filled: true,
            fillColor: Colors.white,
          ),
          onChanged: _buscarOsPorFolio,
        ),
        const SizedBox(height: 12),
        // Resultados
        if (_resultados.isNotEmpty)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _border),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
                    blurRadius: 8, offset: const Offset(0, 2))],
              ),
              child: ListView.separated(
                itemCount: _resultados.length,
                separatorBuilder: (_, __) => const Divider(height: 1,
                    color: _border),
                itemBuilder: (ctx, i) {
                  final os = _resultados[i];
                  return ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.assignment_outlined,
                          size: 18, color: _red),
                    ),
                    title: Text(os['folio_os'] ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w700,
                            fontSize: 13, color: _red)),
                    subtitle: Text(
                        '${os['cliente'] ?? ''} · ${os['fecha'] ?? ''}',
                        style: const TextStyle(fontSize: 11,
                            color: Color(0xFF6B7280))),
                    trailing: const Icon(Icons.chevron_right,
                        color: Color(0xFF9CA3AF)),
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
              Icon(Icons.search_off, size: 48, color: Colors.grey.shade300),
              const SizedBox(height: 12),
              const Text('Sin resultados. Intenta con otro folio.',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)),
            ]),
          ),
      ]),
    );
  }

  // ── PASO 2: Capturar imagen ───────────────────────────────────────────────
  Widget _buildStep2() {
    if (_capturedImage == null) {
      // Vista de captura
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(20)),
              child: const Icon(Icons.document_scanner, size: 56, color: _red),
            ),
            const SizedBox(height: 20),
            const Text('Paso 2 — Capturar Documento',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: Color(0xFF111827))),
            const SizedBox(height: 6),
            Text('OS seleccionada: $_folioOs',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
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
                  foregroundColor: const Color(0xFF374151),
                  side: const BorderSide(color: _border),
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
                    color: Colors.green.shade600,
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
          color: Colors.white,
          child: Row(children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _border),
                foregroundColor: const Color(0xFF374151),
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
                side: BorderSide(color: _filterApplied ? Colors.green : _border),
                foregroundColor: _filterApplied
                    ? Colors.green : const Color(0xFF374151),
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
  Widget _buildStep3() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        // Resumen
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            const Text('Resumen del escaneo',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                    color: Color(0xFF111827))),
            const SizedBox(height: 12),
            _SummaryRow(icon: Icons.assignment_outlined,
                label: 'Orden de Servicio', value: _folioOs ?? '—'),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.insert_drive_file_outlined,
                label: 'Archivo', value: _capturedImage?.path.split('/').last ?? '—'),
            const SizedBox(height: 8),
            _SummaryRow(icon: Icons.auto_fix_high,
                label: 'Filtro escáner',
                value: _filterApplied ? 'Aplicado ✓' : 'Sin filtro'),
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
        const Spacer(),
        // Botones
        Row(children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _border),
              foregroundColor: const Color(0xFF374151),
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
                    ? Colors.grey.shade400 : _red,
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
                _uploading ? 'Subiendo...' : 'Adjuntar y Marcar como Escaneada',
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
    final color = isDone || isActive
        ? const Color(0xFFC8102E)
        : const Color(0xFFD1D5DB);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: isDone ? const Color(0xFFC8102E)
              : isActive ? const Color(0xFFFEE2E2)
              : const Color(0xFFF3F4F6),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: Center(child: isDone
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : Text('$number', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: color))),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(
          fontSize: 10, color: color, fontWeight:
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
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 16, color: const Color(0xFF9CA3AF)),
    const SizedBox(width: 8),
    Text('$label: ', style: const TextStyle(fontSize: 12,
        color: Color(0xFF6B7280))),
    Expanded(child: Text(value, style: const TextStyle(fontSize: 12,
        fontWeight: FontWeight.w600, color: Color(0xFF111827)),
        overflow: TextOverflow.ellipsis)),
  ]);
}
