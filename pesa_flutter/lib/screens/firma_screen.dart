// lib/screens/firma_screen.dart
// Captura de DOBLE firma digital (Tecnico + Ingeniero de Planta / Cliente)
// 100% offline — guarda en SQLite local, sincroniza cuando haya red.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../services/pdf_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';

class FirmaScreen extends StatefulWidget {
  final int osId;
  final Map<String, dynamic> capturaData;
  const FirmaScreen({super.key, required this.osId, required this.capturaData});

  @override
  State<FirmaScreen> createState() => _FirmaScreenState();
}

class _FirmaScreenState extends State<FirmaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  // ── Controladores de lienzo ───────────────────────────────────────────────
  final _ctrlTecnico = SignatureController(
      penStrokeWidth: 3, penColor: const Color(0xFF1D1D1F));
  final _ctrlCliente = SignatureController(
      penStrokeWidth: 3, penColor: const Color(0xFF1D1D1F));

  // ── Campos de texto para el ingeniero/cliente ─────────────────────────────
  final _nombreIngCtrl = TextEditingController();
  final _puestoIngCtrl = TextEditingController();
  final _formKey        = GlobalKey<FormState>();

  bool _saving = false;

  // ── Colores del tema PESA ─────────────────────────────────────────────────
  static const _red = Color(0xFFC8102E);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    final initialNombre = widget.capturaData['firma_cliente_nombre'] ?? widget.capturaData['nombre_ing'] ?? '';
    if (initialNombre.toString().isNotEmpty) {
      _nombreIngCtrl.text = initialNombre.toString();
    }
    final initialPuesto = widget.capturaData['puesto_ing'] ?? '';
    if (initialPuesto.toString().isNotEmpty) {
      _puestoIngCtrl.text = initialPuesto.toString();
    }
    _cargarFirmaTecnico();
    _cargarContactosPlanta();
  }

  List<String> _contactosSugeridos = [];

  Future<void> _cargarContactosPlanta() async {
    final cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? '').toString();
    final pla = (widget.capturaData['direccion'] ?? widget.capturaData['sucursal'] ?? '').toString();
    if (cli.isEmpty) return;
    final contacts = await LocalDbService.instance.getContactosPlanta(cliente: cli, planta: pla);
    if (mounted) {
      setState(() {
        _contactosSugeridos = contacts;
        if (_nombreIngCtrl.text.trim().isEmpty && contacts.isNotEmpty) {
          _nombreIngCtrl.text = contacts.first;
        }
      });
    }
  }

  // ── Estado de firma del técnico ────────────────────────────────────────────
  bool    _firmaTecPrecargada = false;  // true = firma cargada desde perfil
  String? _firmaTecBase64Guardada;      // firma guardada en perfil del técnico

  /// Carga la firma persistida del técnico desde SecureStorage.
  /// Si ya existe, se usa automáticamente sin que el técnico firme de nuevo.
  Future<void> _cargarFirmaTecnico() async {
    final auth     = context.read<AuthService>();
    final username = auth.username ?? '';
    final firma    = await FirmaTecnicoService.instance.getFirma(username);
    if (firma != null && firma.isNotEmpty && mounted) {
      setState(() {
        _firmaTecPrecargada   = true;
        _firmaTecBase64Guardada = firma;
      });
    }
  }

  @override
  void dispose() {
    _ctrlTecnico.dispose();
    _ctrlCliente.dispose();
    _nombreIngCtrl.dispose();
    _puestoIngCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final folio = widget.capturaData['folio_os'] as String? ?? 'OS';
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 2,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Firmas — $folio',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            if ((widget.capturaData['cliente'] ?? '').toString().isNotEmpty)
              Text(
                widget.capturaData['cliente'].toString(),
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: const Color(0xFF161626),
            child: TabBar(
              controller: _tabCtrl,
              indicatorColor: _red,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              tabs: const [
                Tab(
                  text: 'Firma Técnico',
                  icon: Icon(Icons.engineering, size: 18),
                ),
                Tab(
                  text: 'Firma Ingeniero / Cliente',
                  icon: Icon(Icons.person_outline, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: true,
        child: Column(
          children: [
            // Resumen de dictamen
            _buildResumenBar(),
            Expanded(
              child: Form(
                key: _formKey,
                child: TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildTabTecnico(),
                    _buildTabCliente(),
                  ],
                ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  // ── Barra de resumen ──────────────────────────────────────────────────────

  Widget _buildResumenBar() {
    final dictamen = widget.capturaData['dictamen'] as String? ?? 'APTO';
    final isApto   = dictamen == 'APTO';
    return Container(
      color: isApto ? Colors.green.shade50 : Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Icon(
          isApto ? Icons.check_circle : Icons.warning_amber,
          color: isApto ? Colors.green : Colors.orange,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Dictamen: $dictamen  |  '
            'Obs: ${_trunc(widget.capturaData['observaciones'] as String? ?? '', 60)}',
            style: TextStyle(
              fontSize: 12,
              color: isApto ? Colors.green.shade800 : Colors.orange.shade800,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }

  // ── Tab 1 — Firma del Tecnico ─────────────────────────────────────────────

  Widget _buildTabTecnico() {
    final tecnico = widget.capturaData['tecnico'] as String? ?? 'Tecnico';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Encabezado
          Row(children: [
            const Icon(Icons.engineering, color: _red),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Firma del Tecnico Metrológico',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  Text(tecnico,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            // Si está precargada mostramos badge OK, si no, el estado del canvas
            _firmaTecPrecargada
                ? _badgePrecargada()
                : _firmaEstadoBadge(_ctrlTecnico),
          ]),
          const SizedBox(height: 12),

          // Si la firma ya está guardada en perfil → mostrar aviso, no canvas
          if (_firmaTecPrecargada) ...[
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade300),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 52),
                  const SizedBox(height: 12),
                  const Text(
                    'Firma del Técnico cargada desde tu perfil',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Se usará tu firma registrada al inicio de sesión.\n'
                    'No es necesario firmar de nuevo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  // Opción para cambiar la firma si el técnico lo desea
                  OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _firmaTecPrecargada    = false;
                      _firmaTecBase64Guardada = null;
                      _ctrlTecnico.clear();
                    }),
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Firmar en esta orden (opcional)'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey.shade700,
                    ),
                  ),
                ]),
              ),
            ),
          ] else ...[
            // Canvas de firma manual
            Expanded(child: _buildCanvas(_ctrlTecnico)),
            const SizedBox(height: 10),
            _buildClearBtn(_ctrlTecnico, 'Tecnico'),
            const SizedBox(height: 4),
            const Text(
              'Firme dentro del area con el lapiz o dedo.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _badgePrecargada() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.verified, size: 12, color: Colors.green),
        SizedBox(width: 4),
        Text(
          'Del perfil',
          style: TextStyle(fontSize: 11, color: Colors.green),
        ),
      ]),
    );
  }

  // ── Tab 2 — Firma del Ingeniero / Cliente ─────────────────────────────────

  Widget _buildTabCliente() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Encabezado
          Row(children: [
            const Icon(Icons.person_outline, color: _red),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Firma del Ingeniero de Planta / Cliente',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            _firmaEstadoBadge(_ctrlCliente),
          ]),
          const SizedBox(height: 12),

          // Campos de nombre y puesto
          Row(children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _nombreIngCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nombre completo *',
                  hintText: 'Ing. Juan Pérez',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Ingresa el nombre del responsable'
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _puestoIngCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Puesto / Cargo',
                  hintText: 'Jefe de Produccion',
                  prefixIcon: Icon(Icons.work_outline),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ]),
          if (_contactosSugeridos.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.history, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                const Text('Contactos registrados en planta: ',
                    style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _contactosSugeridos.map((contacto) {
                        final isSelected = _nombreIngCtrl.text.trim().toLowerCase() == contacto.toLowerCase();
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: isSelected ? const Color(0xFFFFEBEE) : Colors.grey.shade100,
                            side: BorderSide(color: isSelected ? _red : Colors.grey.shade300),
                            avatar: Icon(Icons.person, size: 12, color: isSelected ? _red : Colors.grey.shade700),
                            label: Text(contacto, style: TextStyle(fontSize: 11, color: isSelected ? _red : Colors.black87, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                            onPressed: () {
                              setState(() {
                                _nombreIngCtrl.text = contacto;
                              });
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),

          // Canvas
          Expanded(child: _buildCanvas(_ctrlCliente)),
          const SizedBox(height: 10),
          _buildClearBtn(_ctrlCliente, 'Ingeniero/Cliente'),
          const SizedBox(height: 4),
          const Text(
            'El responsable de la planta firma aqui para confirmar la recepcion del servicio.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ── Widgets reutilizables ─────────────────────────────────────────────────

  Widget _buildCanvas(SignatureController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: ctrl.isNotEmpty ? _red : Colors.grey.shade300,
            width: ctrl.isNotEmpty ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Stack(
            children: [
              Signature(controller: ctrl, backgroundColor: Colors.white),
              // Watermark guia
              if (ctrl.isEmpty)
                const Center(
                  child: Text(
                    'Firme aquí',
                    style: TextStyle(
                      fontSize: 18,
                      color: Color(0xFFD0D0D0),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClearBtn(SignatureController ctrl, String quien) {
    return OutlinedButton.icon(
      onPressed: () => setState(ctrl.clear),
      icon: const Icon(Icons.refresh, size: 16),
      label: Text('Limpiar firma $quien'),
      style: OutlinedButton.styleFrom(foregroundColor: Colors.grey.shade700),
    );
  }


  Widget _firmaEstadoBadge(SignatureController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: ctrl.isNotEmpty ? Colors.green.shade100 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            ctrl.isNotEmpty ? Icons.check : Icons.edit,
            size: 12,
            color: ctrl.isNotEmpty ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 4),
          Text(
            ctrl.isNotEmpty ? 'Lista' : 'Pendiente',
            style: TextStyle(
              fontSize: 11,
              color: ctrl.isNotEmpty ? Colors.green.shade700 : Colors.grey,
            ),
          ),
        ]),
      ),
    );
  }

  // ── Barra de accion final ─────────────────────────────────────────────────

  Widget _buildActionBar() {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + (bottomInset > 0 ? bottomInset : 8)),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, -3))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Indicadores de progreso de firmas
          Row(children: [
            _progressChip('Técnico', _ctrlTecnico),
            const SizedBox(width: 8),
            _progressChip('Ing./Cliente', _ctrlCliente),
          ]),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: _saving
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.picture_as_pdf),
            label: const Text('Finalizar y Generar PDF',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            onPressed: _saving ? null : _onFinalizar,
          ),
        ],
      ),
    );
  }

  Widget _progressChip(String label, SignatureController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => Chip(
        avatar: Icon(
          ctrl.isNotEmpty ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 16,
          color: ctrl.isNotEmpty ? Colors.green : Colors.grey,
        ),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        backgroundColor:
            ctrl.isNotEmpty ? Colors.green.shade50 : Colors.grey.shade100,
      ),
    );
  }

  // ── Logica de finalizacion ────────────────────────────────────────────────

  Future<void> _onFinalizar() async {
    // ── CANDADO METROLÓGICO: 6 CAMPOS OBLIGATORIOS DEL INSTRUMENTO ─────────
    final d = widget.capturaData;
    final marca = (d['marca'] ?? d['equipo_marca'] ?? '').toString().trim();
    final modelo = (d['modelo'] ?? d['equipo_modelo'] ?? '').toString().trim();
    final idEquipo = (d['id_equipo'] ?? d['id_indicador'] ?? '').toString().trim();
    final capMax = (d['capacidad_max'] ?? d['cap_max'] ?? d['alcance_max'] ?? '').toString().trim();
    final divMin = (d['division_minima'] ?? d['div_min'] ?? d['div_minima'] ?? '').toString().trim();
    final ubic = (d['ubicacion'] ?? d['equipo_ubicacion'] ?? '').toString().trim();

    final List<String> faltantesInst = [];
    if (marca.isEmpty)    faltantesInst.add('Marca');
    if (modelo.isEmpty)   faltantesInst.add('Modelo');
    if (idEquipo.isEmpty) faltantesInst.add('ID Indicador / Equipo');
    if (capMax.isEmpty)   faltantesInst.add('Capacidad Máxima');
    if (divMin.isEmpty)   faltantesInst.add('División Mínima (d)');
    if (ubic.isEmpty)     faltantesInst.add('Ubicación');

    if (faltantesInst.isNotEmpty) {
      final listaStr = faltantesInst.map((f) => '• $f').join('\n');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Faltan datos del instrumento: ${faltantesInst.join(", ")}'),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFC8102E), size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Datos del Instrumento Incompletos',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Text(
            'Faltan datos obligatorios del instrumento:\n\n'
            '$listaStr\n\n'
            'Complétalos en la pestaña \'Instrumento\' para poder firmar y generar el documento.',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC8102E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop(); // Regresa a la pantalla de captura
              },
              child: const Text('Volver a Instrumento'),
            ),
          ],
        ),
      );
      return;
    }

    // Validar firma del tecnico:
    // Si está precargada desde perfil → OK. Si no, requiere dibujo en canvas.
    if (!_firmaTecPrecargada && _ctrlTecnico.isEmpty) {
      _tabCtrl.animateTo(0);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('La firma del Técnico es obligatoria'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    // Validar campos del ingeniero / cliente (el nombre es obligatorio siempre)
    if (!_formKey.currentState!.validate()) {
      _tabCtrl.animateTo(1);
      return;
    }

    setState(() => _saving = true);
    String? pdfPath;

    try {
      // 1. Exportar firma tecnico → si vino precargada usar esa, si no exportar canvas
      String tecBase64 = '';
      if (_firmaTecPrecargada && _firmaTecBase64Guardada != null) {
        // Usar firma persistida del perfil
        tecBase64 = _firmaTecBase64Guardada!;
      } else {
        final Uint8List? imgTec = await _ctrlTecnico.toPngBytes();
        tecBase64 = imgTec != null ? base64Encode(imgTec) : '';
        // ── v3.1: Guardar firma de perfil localmente + sincronizar al servidor ──
        // Esto permite que Windows valide la firma del técnico en el login.
        if (tecBase64.isNotEmpty) {
          final auth     = context.read<AuthService>();
          final username = auth.username ?? '';
          final idTec    = auth.idTecnico ?? 0;
          if (idTec > 0) {
            FirmaTecnicoService.instance.saveAndSyncFirma(username, tecBase64, idTec)
                .then((ok) => debugPrint('[Firma] Sync al servidor: ${ok ? "OK" : "WARN (no crítico)"}'));
          } else {
            // Sin ID de técnico: guardar solo localmente
            FirmaTecnicoService.instance.saveFirma(username, tecBase64);
          }
        }
      }

      // 2. Exportar firma cliente (OPCIONAL)
      final Uint8List? imgCli =
          _ctrlCliente.isNotEmpty ? await _ctrlCliente.toPngBytes() : null;
      final cliBase64 = imgCli != null ? base64Encode(imgCli) : '';
      final folio     = widget.capturaData['folio_os'] as String? ?? '';
      final nombreIng = _nombreIngCtrl.text.trim();
      final puestoIng = _puestoIngCtrl.text.trim();

      // Guardar contacto asociado a la planta/cliente para memoria futura
      final cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? '').toString();
      final pla = (widget.capturaData['direccion'] ?? widget.capturaData['sucursal'] ?? '').toString();
      if (nombreIng.isNotEmpty) {
        LocalDbService.instance.saveContactoPlanta(
          cliente: cli,
          planta: pla,
          nombreContacto: nombreIng,
        );
      }

      // 2. Guardar lecturas en SQLite
      final repRows  = _castList(widget.capturaData['rep_rows']);
      final excRows  = _castList(widget.capturaData['exc_rows']);
      final exacRows = _castList(widget.capturaData['exac_rows']);

      // 3. Guardar ambas firmas + nombre/puesto del ingeniero
      await LocalDbService.instance.saveFirmas(
        localId:        widget.osId,
        folio:          folio,
        firmaTecBase64: tecBase64,
        firmaCliBase64: cliBase64,
        nombreIng:      nombreIng,
        puestoIng:      puestoIng,
      );

      // 4. Generar PDF con ambas firmas y nombre del responsable
      final osData = (widget.osId > 0 ? await LocalDbService.instance.getOs(widget.osId) : null)
          ?? (folio.isNotEmpty ? await LocalDbService.instance.getOsByFolio(folio) : null)
          ?? {};
      final enrichedOs = <String, dynamic>{
        ...osData,
        ...widget.capturaData,
        'folio_os':      folio,
        'observaciones': widget.capturaData['observaciones'] ?? '',
        'dictamen':      widget.capturaData['dictamen'] ?? 'APTO',
        'nombre_ing':    nombreIng,
        'puesto_ing':    puestoIng,
        'firma_cliente_nombre': nombreIng,
      };

      await LocalDbService.instance.saveLecturas(
        localId:       widget.osId,
        repRows:       repRows,
        excRows:       excRows,
        exacRows:      exacRows,
        observaciones: widget.capturaData['observaciones'] as String? ?? '',
        dictamen:      widget.capturaData['dictamen'] as String?,
        firmaClienteNombre: nombreIng,
        instrumentData: enrichedOs,
        unidadMedida:  (enrichedOs['unidad_medida'] ?? 'kg').toString(),
      );

      pdfPath = await PdfService.instance.generarPdfFinal(
        osData:         enrichedOs,
        repRows:        repRows,
        excRows:        excRows,
        exacRows:       exacRows,
        firmaTecBase64: tecBase64.isNotEmpty ? tecBase64 : null,
        firmaCliBase64: cliBase64.isNotEmpty ? cliBase64 : null,
      );

      // 5. Leer binario del PDF y guardar Base64 + path en SQLite
      final pdfFile = File(pdfPath);
      String? pdfB64;
      if (await pdfFile.exists()) {
        try {
          final pdfBytes = await pdfFile.readAsBytes();
          pdfB64 = base64Encode(pdfBytes);
        } catch (_) {}
      }

      await LocalDbService.instance.savePdfPath(
        widget.osId,
        pdfPath,
        folio: folio,
        pdfB64: pdfB64,
      );

      // 5.1 Eliminar el borrador local correspondiente al completar la orden
      await LocalDbService.instance.deleteDraft(folio);

      // 6. Subida inmediata a Render si hay conexion (Wi-Fi o red movil)
      bool fueSincronizado = false;
      try {
        final uploadPayload = <String, dynamic>{
          ...enrichedOs,
          'rep_rows': repRows,
          'exc_rows': excRows,
          'exac_rows': exacRows,
          'firma_tecnico': tecBase64,
          'firma_cliente': cliBase64,
        };

        final connResults = await Connectivity().checkConnectivity();
        final isOnline = connResults.any((r) => r != ConnectivityResult.none);
        if (isOnline) {
          debugPrint('[Firma] Red detectada -> Subiendo PDF de inmediato a Render para $folio...');
          if (pdfFile.existsSync()) {
            final uploadOk = await ApiService.instance.uploadPdf(
              folio,
              pdfFile,
              osId: widget.osId,
              data: uploadPayload,
            );
            if (uploadOk) {
              fueSincronizado = true;
              await LocalDbService.instance.markOsSincronizada(
                widget.osId,
                ((enrichedOs['sync_version'] as int? ?? 0) + 1),
                folio: folio,
              );
              debugPrint('[Firma] ✅ Orden $folio sincronizada en SQLite y en Render');
            }
          }
          if (mounted) {
            context.read<SyncService>().performSync();
          }
        } else {
          debugPrint('[Firma] Sin red -> Sync quedara pendiente para cuando conecte a Wi-Fi');
        }
      } catch (syncErr) {
        debugPrint('[Firma] Error en sync automatico al generar PDF: $syncErr');
      }

      // 7. Dialogo de exito
      if (mounted) {
        if (fueSincronizado) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.cloud_done, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Orden y PDF sincronizados con el servidor'),
                ],
              ),
              backgroundColor: Color(0xFF2E7D32),
              duration: Duration(seconds: 4),
            ),
          );
        }

        final localPdfPath = pdfPath;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.check_circle, color: Colors.green, size: 52),
            title: const Text('Servicio Finalizado',
                style: TextStyle(fontWeight: FontWeight.w800)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('El servicio $folio fue guardado correctamente.'),
                if (nombreIng.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.person, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('Recibio: $nombreIng',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  if (puestoIng.isNotEmpty)
                    Text('   $puestoIng',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
                const SizedBox(height: 12),
                if (fueSincronizado)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF81C784)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.cloud_done, color: Color(0xFF2E7D32), size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Orden y PDF sincronizados con el servidor',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B5E20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Text(
                    'Los datos se sincronizaran automaticamente al '
                    'detectar conexion con el servidor.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  if (mounted) context.go('/os');
                },
                child: const Text('Volver a Mis Ordenes'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('Ver PDF'),
                onPressed: () {
                  if (localPdfPath.isNotEmpty) {
                    context.push('/pdf-viewer', extra: {
                      'pdfPath': localPdfPath,
                      'folio': folio,
                    });
                  }
                },
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error al finalizar: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Map<String, dynamic>> _castList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    return [];
  }

  String _trunc(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}\u2026';
}
