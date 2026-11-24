// lib/screens/nuevo_doc_screen.dart — Creación y Asignación Completa de Formatos (Paridad Admin APK/.exe)
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/metrology_helper.dart';
import '../services/sync_service.dart';
import '../widgets/app_shell.dart';

class NuevoDocScreen extends StatefulWidget {
  const NuevoDocScreen({super.key});

  @override
  State<NuevoDocScreen> createState() => _NuevoDocScreenState();
}

class _NuevoDocScreenState extends State<NuevoDocScreen> {
  static const _red = Color(0xFFB81D24);
  static const _border = Color(0xFFE5E7EB);
  static const _bg = Color(0xFFF9FAFB);

  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _loadingCat = true;
  bool _syncingCat = false;
  String? _error;

  // ── Catálogos completos sincronizados ─────────────────────────────────────
  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _sucursalesCliente = [];
  List<Map<String, dynamic>> _tecnicos = [];
  List<Map<String, dynamic>> _tiposServ = [];
  List<Map<String, dynamic>> _tiposInst = [];
  List<Map<String, dynamic>> _historialInstrumentos = [];

  // ── Valores del formulario ────────────────────────────────────────────────
  String _tipoDoc = 'OS'; // OS | RMA | RE | LP | LV | OSOB | OSOCC
  String _tipo = 'Individual'; // Individual | Lote
  String _modalidad = 'Digital'; // Digital | Físico

  int? _clienteId;
  String _clienteNombre = '';
  int? _sucursalId;
  int? _tecnicoId;
  int? _tipoServId;
  int? _tipoInstId;
  String _tipoInstNombre = '';
  bool _aplicaExcentricidad = true;
  String _motivoNoExcentricidad = 'Tolva';

  final _sucursalCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();
  final _observCtrl = TextEditingController();
  final _cantidadCtrl = TextEditingController(text: '2');
  final _fechaCtrl = TextEditingController(
    text: DateTime.now().toIso8601String().split('T')[0],
  );

  // ── Datos opcionales / parciales de instrumento ───────────────────────────
  final _marcaCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController();
  final _serieCtrl = TextEditingController();
  final _idEquipoCtrl = TextEditingController();
  final _capacidadCtrl = TextEditingController();
  final _divisionCtrl = TextEditingController();
  final _ubicacionCtrl = TextEditingController();
  final _ccaCtrl = TextEditingController();
  final _dveCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCatalogos();
  }

  @override
  void dispose() {
    _sucursalCtrl.dispose();
    _direccionCtrl.dispose();
    _observCtrl.dispose();
    _cantidadCtrl.dispose();
    _fechaCtrl.dispose();
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _serieCtrl.dispose();
    _idEquipoCtrl.dispose();
    _capacidadCtrl.dispose();
    _divisionCtrl.dispose();
    _ubicacionCtrl.dispose();
    _ccaCtrl.dispose();
    _dveCtrl.dispose();
    super.dispose();
  }

  void _salir([bool creado = false]) {
    if (context.canPop()) {
      context.pop(creado);
    } else {
      context.go('/os');
    }
  }

  Future<void> _loadCatalogos({bool forceRemote = false}) async {
    final db = LocalDbService.instance;
    if (forceRemote) {
      setState(() => _syncingCat = true);
    }

    try {
      // 1. Carga local instantánea desde SQLite
      final localCli = await db.getCatalogoClientes();
      final localTec = await db.getCatalogoTecnicos();
      final localTs = await db.getCatalogoTiposServicio();
      final localTi = await db.getCatalogoTiposInstrumento();
      final localHist = await db.getHistorialInstrumentos(
        clienteId: _clienteId,
        cliente: _clienteNombre,
      );

      if (mounted && (localCli.isNotEmpty || localTec.isNotEmpty)) {
        setState(() {
          _clientes = localCli;
          _tecnicos = localTec;
          _tiposServ = localTs;
          _tiposInst = localTi;
          _historialInstrumentos = localHist;
          _loadingCat = false;
        });
      }

      // 2. Sincronizar desde /api/admin/catalogos en segundo plano (o forzado)
      final remote = await ApiService.instance.getAdminCatalogos();
      if (remote != null && remote.isNotEmpty) {
        await db.guardarCatalogosAdmin(remote);
        final freshCli = await db.getCatalogoClientes();
        final freshTec = await db.getCatalogoTecnicos();
        final freshTs = await db.getCatalogoTiposServicio();
        final freshTi = await db.getCatalogoTiposInstrumento();
        final freshHist = await db.getHistorialInstrumentos(
          clienteId: _clienteId,
          cliente: _clienteNombre,
          sucursalId: _sucursalId,
          sucursal: _sucursalCtrl.text,
        );
        if (mounted) {
          setState(() {
            _clientes = freshCli;
            _tecnicos = freshTec;
            _tiposServ = freshTs;
            _tiposInst = freshTi;
            _historialInstrumentos = freshHist;
            _loadingCat = false;
            _error = null;
          });
        }
        if (_clienteId != null) {
          await _cargarSucursalesDeCliente(_clienteId!, _clienteNombre, autoSelectFirst: false);
        }
      } else if (mounted) {
        setState(() => _loadingCat = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingCat = false;
          if (_clientes.isEmpty) {
            _error = 'No se pudieron sincronizar catálogos remotos ($e). Verifica tu conexión.';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _syncingCat = false);
    }
  }

  Future<void> _cargarSucursalesDeCliente(
    int clienteId,
    String clienteNombre, {
    bool autoSelectFirst = true,
  }) async {
    final sucs = await LocalDbService.instance.getCatalogoSucursales(
      clienteId: clienteId,
      clienteNombre: clienteNombre,
    );
    final hist = await LocalDbService.instance.getHistorialInstrumentos(
      clienteId: clienteId,
      cliente: clienteNombre,
    );
    if (!mounted) return;
    setState(() {
      _sucursalesCliente = sucs;
      _historialInstrumentos = hist;
      if (autoSelectFirst) {
        if (sucs.isNotEmpty) {
          final first = sucs.first;
          _sucursalId = first['id'] as int?;
          final nom = (first['nombre'] ?? '').toString().trim();
          final dir = (first['direccion'] ?? '').toString().trim();
          _sucursalCtrl.text = nom.isNotEmpty ? nom : dir;
          _direccionCtrl.text = dir.isNotEmpty ? dir : nom;
        } else {
          _sucursalId = null;
          _sucursalCtrl.clear();
          _direccionCtrl.clear();
        }
      }
    });
  }

  Future<void> _refrescarHistorialEquipo() async {
    final hist = await LocalDbService.instance.getHistorialInstrumentos(
      clienteId: _clienteId,
      cliente: _clienteNombre,
      sucursalId: _sucursalId,
      sucursal: _sucursalCtrl.text.trim(),
    );
    if (mounted) {
      setState(() => _historialInstrumentos = hist);
    }
  }

  void _aplicarInstrumentoSugerido(Map<String, dynamic> inst) {
    setState(() {
      final m = (inst['marca'] ?? '').toString().trim();
      final mod = (inst['modelo'] ?? '').toString().trim();
      final ser = (inst['serie'] ?? inst['ns'] ?? '').toString().trim();
      final idEq = (inst['id_indicador'] ?? inst['id_equipo'] ?? '').toString().trim();
      final cap = (inst['capacidad_maxima'] ?? '').toString().trim();
      final div = formatearDivisionMinima(inst['division_minima']);
      final ubic = (inst['ubicacion'] ?? '').toString().trim();
      final tInst = (inst['tipo_instrumento'] ?? '').toString().trim();

      if (m.isNotEmpty) _marcaCtrl.text = m;
      if (mod.isNotEmpty) _modeloCtrl.text = mod;
      if (ser.isNotEmpty) _serieCtrl.text = ser;
      if (idEq.isNotEmpty) _idEquipoCtrl.text = idEq;
      if (cap.isNotEmpty) _capacidadCtrl.text = cap;
      if (div.isNotEmpty) _divisionCtrl.text = div;
      if (ubic.isNotEmpty) _ubicacionCtrl.text = ubic;
      if (tInst.isNotEmpty) {
        _tipoInstNombre = tInst;
        final matchTi = _tiposInst.where(
          (t) => (t['nombre'] ?? '').toString().toLowerCase() == tInst.toLowerCase(),
        );
        if (matchTi.isNotEmpty) {
          _tipoInstId = matchTi.first['id'] as int?;
          final ap = matchTi.first['aplica_excentricidad'];
          _aplicaExcentricidad = ap == null || ap == 1 || ap == true;
          if (!_aplicaExcentricidad) {
            _motivoNoExcentricidad = inferirMotivoNoExcentricidad(null, tInst);
          }
        }
      }
    });
  }

  Future<void> _abrirBuscadorClientes() async {
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _ClienteSearchSheet(clientes: _clientes),
    );
    if (selected != null) {
      final cid = int.tryParse('${selected['id'] ?? 0}') ?? 0;
      final cnom = (selected['nombre'] ?? selected['razon_social'] ?? '').toString().trim();
      setState(() {
        _clienteId = cid;
        _clienteNombre = cnom;
      });
      await _cargarSucursalesDeCliente(cid, cnom, autoSelectFirst: true);
    }
  }

  Future<void> _submit() async {
    if (_clienteId == null || _clienteNombre.isEmpty) {
      setState(() => _error = 'Selecciona un cliente del catálogo.');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final int cantidad = _tipo == 'Lote'
          ? (int.tryParse(_cantidadCtrl.text.trim()) ?? 2)
          : 1;

      final ccaClean = limpiarNumeroRegulatorio(_ccaCtrl.text);
      final dveClean = limpiarNumeroRegulatorio(_dveCtrl.text);
      final divNorm = formatearDivisionMinima(_divisionCtrl.text);

      final payload = <String, dynamic>{
        'tipo_documento': _tipoDoc,
        'tipo': _tipo,
        'cantidad': cantidad,
        'modalidad': _modalidad,
        'id_cliente': _clienteId,
        'sucursal_id': _sucursalId,
        'sucursal': _sucursalCtrl.text.trim(),
        'direccion': _direccionCtrl.text.trim().isNotEmpty
            ? _direccionCtrl.text.trim()
            : _sucursalCtrl.text.trim(),
        'id_tecnico': _tecnicoId,
        if (_tipoServId != null && _tipoServId! > 0) 'id_tipo_servicio': _tipoServId,
        if (_tipoInstId != null && _tipoInstId! > 0) 'id_tipo_instrumento': _tipoInstId,
        if (_tipoInstNombre.isNotEmpty) 'tipo_instrumento': _tipoInstNombre,
        'observaciones': _observCtrl.text.trim(),
        'estado': 'ASIGNADA',
        'fecha': _fechaCtrl.text.trim(),
        // Datos de instrumento (completos o parciales: ej. solo Marca y Modelo)
        if (_marcaCtrl.text.trim().isNotEmpty) 'marca': _marcaCtrl.text.trim(),
        if (_modeloCtrl.text.trim().isNotEmpty) 'modelo': _modeloCtrl.text.trim(),
        if (_serieCtrl.text.trim().isNotEmpty) 'serie': _serieCtrl.text.trim(),
        if (_idEquipoCtrl.text.trim().isNotEmpty) 'id_indicador': _idEquipoCtrl.text.trim(),
        if (_capacidadCtrl.text.trim().isNotEmpty) 'capacidad_maxima': _capacidadCtrl.text.trim(),
        if (divNorm.isNotEmpty) 'division_minima': divNorm,
        if (_ubicacionCtrl.text.trim().isNotEmpty) 'ubicacion': _ubicacionCtrl.text.trim(),
        if (ccaClean.isNotEmpty) 'numero_cca': ccaClean,
        if (dveClean.isNotEmpty) 'numero_dve': dveClean,
        'aplica_excentricidad': _aplicaExcentricidad,
        if (!_aplicaExcentricidad) 'motivo_no_excentricidad': _motivoNoExcentricidad,
      };

      final result = await ApiService.instance.crearOrden(payload);

      // Insertar inmediatamente en SQLite local y refrescar Dashboard en vivo
      final rawOrdenes = (result['ordenes'] as List?) ?? const [];
      if (rawOrdenes.isNotEmpty) {
        final listaMap = rawOrdenes
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        await LocalDbService.instance.insertOrdenesBatch(listaMap);
      } else {
        final folioRes = (result['folio_os'] ?? result['folio'] ?? '').toString().trim();
        if (folioRes.isNotEmpty && !folioRes.contains(' ')) {
          final tecRow = _tecnicos.where((t) => t['id'] == _tecnicoId);
          final tecNombre = tecRow.isNotEmpty
              ? (tecRow.first['nombre'] ?? tecRow.first['nombre_completo'] ?? '').toString()
              : '';
          await LocalDbService.instance.insertOrdenesBatch([
            {
              ...payload,
              'folio_os': folioRes,
              'cliente': _clienteNombre,
              'tecnico': tecNombre,
            }
          ]);
        }
      }

      if (mounted) {
        try {
          await context.read<SyncService>().cargarOrdenes();
        } catch (_) {}
      }

      if (mounted) {
        final folio = result['folio_os'] ?? result['folio'] ?? 'asignada';
        await showDialog<void>(
          context: context,
          builder: (dlgCtx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Row(children: [
              Icon(Icons.check_circle_rounded, color: Colors.green, size: 26),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Servicio Creado y Asignado',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ]),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El formato fue registrado en PostgreSQL y sincronizado inmediatamente en el dispositivo.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF374151)),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.assignment_turned_in, color: _red, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Folio(s): $folio',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: _red,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  Navigator.pop(dlgCtx);
                  _salir(true);
                },
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error al asignar servicio: $e';
          _loading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isMobile = media.size.width < 768 && media.orientation != Orientation.landscape;

    return AppShell(
      currentRoute: '/nuevo-doc',
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            // Header
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _border)),
              ),
              child: Row(children: [
                if (isMobile)
                  IconButton(
                    icon: const Icon(Icons.menu_rounded, color: Color(0xFF111827), size: 24),
                    tooltip: 'Menú principal',
                    onPressed: () => AppShell.toggleMenu(context),
                  ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _red,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.assignment_add, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Generar y Asignar Formatos (Admin)',
                        style: TextStyle(
                          color: Color(0xFF111827),
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'OS, RMA, RE, LP, LV, OSOB y OSOCC • Catálogo completo sincronizado',
                        style: TextStyle(color: Color(0xFF6B7280), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF374151),
                    side: const BorderSide(color: _border),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  onPressed: _syncingCat ? null : () => _loadCatalogos(forceRemote: true),
                  icon: _syncingCat
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: _red),
                        )
                      : const Icon(Icons.sync_rounded, size: 16),
                  label: Text(
                    isMobile ? 'Catálogos' : 'Sincronizar Catálogos',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                  onPressed: () => _salir(false),
                ),
              ]),
            ),
            Expanded(
              child: _loadingCat
                  ? const Center(child: CircularProgressIndicator(color: _red))
                  : _buildForm(),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildForm() {
    const docs = [
      {'key': 'OS', 'label': 'Orden de Servicio (OS)'},
      {'key': 'RMA', 'label': 'Remisión Material (RMA)'},
      {'key': 'RE', 'label': 'Revisión Báscula (RE)'},
      {'key': 'LP', 'label': 'Levantamiento Proy. (LP)'},
      {'key': 'LV', 'label': 'Levantamiento Met. (LV)'},
      {'key': 'OSOB', 'label': 'Observaciones Báscula (OSOB)'},
      {'key': 'OSOCC', 'label': 'Observaciones Celda (OSOCC)'},
    ];

    final bool pideTipoServicio = _tipoDoc == 'OS';

    // Previsualización en vivo del identificador dinámico compuesto
    final etiquetaPreview = construirEtiquetaInstrumento({
      'folio_os': '$_tipoDoc-26-XXX',
      'marca': _marcaCtrl.text,
      'modelo': _modeloCtrl.text,
      'serie': _serieCtrl.text,
      'id_indicador': _idEquipoCtrl.text,
      'ubicacion': _ubicacionCtrl.text,
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ── 1. Selector de los 7 Formatos ───────────────────────────────
            const _SectionTitle('1. Formato a Generar'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in docs)
                  ChoiceChip(
                    label: Text(
                      '${d['key']} — ${d['label']!.split(' (').first}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _tipoDoc == d['key'] ? Colors.white : const Color(0xFF374151),
                      ),
                    ),
                    selected: _tipoDoc == d['key'],
                    selectedColor: _red,
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _tipoDoc == d['key'] ? _red : _border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onSelected: (val) {
                      if (val) setState(() => _tipoDoc = d['key']!);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // ── 2. Cantidad y Modalidad ─────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('2. Tipo de Asignación'),
                      const SizedBox(height: 8),
                      Row(children: [
                        for (final t in ['Individual', 'Lote'])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _RadioCard(
                                label: t,
                                icon: t == 'Individual'
                                    ? Icons.assignment_outlined
                                    : Icons.layers_outlined,
                                selected: _tipo == t,
                                onTap: () => setState(() => _tipo = t),
                              ),
                            ),
                          ),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('3. Modalidad'),
                      const SizedBox(height: 8),
                      Row(children: [
                        for (final m in ['Digital', 'Físico'])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _RadioCard(
                                label: m,
                                icon: m == 'Digital'
                                    ? Icons.tablet_android_rounded
                                    : Icons.print_outlined,
                                selected: _modalidad == m,
                                onTap: () => setState(() => _modalidad = m),
                              ),
                            ),
                          ),
                      ]),
                    ],
                  ),
                ),
              ],
            ),

            if (_tipo == 'Lote') ...[
              const SizedBox(height: 12),
              _InputField(
                label: 'Cantidad de formatos consecutivos en el lote',
                controller: _cantidadCtrl,
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 2) return 'Mínimo 2 formatos para un lote';
                  if (n > 100) return 'Máximo 100 formatos por lote';
                  return null;
                },
              ),
            ],

            const SizedBox(height: 20),

            // ── 4. Cliente con buscador completo ────────────────────────────
            Row(children: [
              const _SectionTitle('4. Cliente / Razón Social'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                ),
                child: Text(
                  '${_clientes.length} en catálogo',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            InkWell(
              onTap: _abrirBuscadorClientes,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _clienteId != null ? const Color(0xFF9CA3AF) : _border,
                  ),
                ),
                child: Row(children: [
                  const Icon(Icons.business_rounded, size: 19, color: _red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _clienteNombre.isNotEmpty
                          ? _clienteNombre
                          : 'Buscar y seleccionar cliente del catálogo...',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: _clienteNombre.isNotEmpty ? FontWeight.w700 : FontWeight.w400,
                        color: _clienteNombre.isNotEmpty
                            ? const Color(0xFF111827)
                            : const Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                  const Icon(Icons.search_rounded, size: 20, color: Color(0xFF6B7280)),
                ]),
              ),
            ),

            const SizedBox(height: 16),

            // ── 5. Direcciones / Sucursales dinámicas del cliente ───────────
            Row(children: [
              const _SectionTitle('5. Sucursal / Dirección de Planta'),
              if (_sucursalesCliente.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: Text(
                    '${_sucursalesCliente.length} dirección(es) registrada(s)',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 8),
            if (_sucursalesCliente.isNotEmpty) ...[
              SizedBox(
                height: 66,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _sucursalesCliente.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, idx) {
                    final s = _sucursalesCliente[idx];
                    final sNom = (s['nombre'] ?? '').toString().trim();
                    final sDir = (s['direccion'] ?? '').toString().trim();
                    final isSelected = (_sucursalId != null && s['id'] == _sucursalId) ||
                        (_sucursalCtrl.text.trim() == sNom && _direccionCtrl.text.trim() == sDir);
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _sucursalId = s['id'] as int?;
                          _sucursalCtrl.text = sNom.isNotEmpty ? sNom : sDir;
                          _direccionCtrl.text = sDir.isNotEmpty ? sDir : sNom;
                        });
                        _refrescarHistorialEquipo();
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 260,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected ? _red : _border,
                            width: isSelected ? 1.8 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: 15,
                                color: isSelected ? _red : const Color(0xFF6B7280),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  sNom.isNotEmpty ? sNom : 'Planta / Dirección',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isSelected ? _red : const Color(0xFF111827),
                                  ),
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check_circle, size: 15, color: _red),
                            ]),
                            if (sDir.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                sDir,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Expanded(
                child: _InputField(
                  label: 'Sucursal / Planta',
                  controller: _sucursalCtrl,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _InputField(
                  label: 'Dirección completa de planta',
                  controller: _direccionCtrl,
                ),
              ),
            ]),

            const SizedBox(height: 16),

            // ── 6. Técnico Asignado y Fecha ─────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('6. Técnico Asignado'),
                      const SizedBox(height: 8),
                      _CatalogDropdown(
                        hint: 'Seleccionar técnico...',
                        items: _tecnicos,
                        labelKeys: const ['nombre', 'nombre_completo'],
                        idKey: 'id',
                        value: _tecnicoId,
                        onChanged: (v) => setState(() => _tecnicoId = v),
                        validator: (v) => v == null ? 'Selecciona un técnico asignado' : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('Fecha Programada'),
                      const SizedBox(height: 8),
                      _InputField(
                        label: 'YYYY-MM-DD',
                        controller: _fechaCtrl,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── 7. Tipo de Servicio ─────────────────────────────────────────
            _SectionTitle(
              pideTipoServicio
                  ? '7. Tipo de Servicio'
                  : '7. Tipo de Servicio (Opcional para $_tipoDoc)',
            ),
            const SizedBox(height: 8),
            _CatalogDropdown(
              hint: 'Seleccionar tipo de servicio...',
              items: _tiposServ,
              labelKeys: const ['nombre'],
              idKey: 'id',
              value: _tipoServId,
              onChanged: (v) => setState(() => _tipoServId = v),
              validator: pideTipoServicio
                  ? (v) => v == null ? 'Selecciona el tipo de servicio' : null
                  : null,
            ),

            const SizedBox(height: 22),

            // ── 8. Datos de Equipo / Instrumento (Opcional o Parcial + Autocompletado + CCA/DVE)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.scale_rounded, size: 19, color: _red),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '8. Datos del Instrumento y Números Regulatorios (Opcional / Parcial)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111827),
                            ),
                          ),
                          Text(
                            'Puedes capturar todo el equipo, solo Marca/Modelo parcial, o dejarlo para campo. Autocompleta desde el historial del cliente.',
                            style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                          ),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // Vista previa en vivo de la etiqueta dinámica compuesta
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Identificador en lista:',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        Text(
                          etiquetaPreview,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        if (limpiarNumeroRegulatorio(_ccaCtrl.text).isNotEmpty)
                          _RegBadge(
                            prefix: 'CCA',
                            value: limpiarNumeroRegulatorio(_ccaCtrl.text),
                            color: const Color(0xFF111827),
                            bg: const Color(0xFFF8FAFC),
                          ),
                        if (limpiarNumeroRegulatorio(_dveCtrl.text).isNotEmpty)
                          _RegBadge(
                            prefix: 'DVE',
                            value: limpiarNumeroRegulatorio(_dveCtrl.text),
                            color: const Color(0xFF111827),
                            bg: const Color(0xFFF8FAFC),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Tipo de instrumento
                  _CatalogDropdown(
                    hint: 'Tipo de instrumento (opcional)...',
                    items: _tiposInst,
                    labelKeys: const ['nombre'],
                    idKey: 'id',
                    value: _tipoInstId,
                    onChanged: (v) {
                      final match = _tiposInst.where((t) => t['id'] == v);
                      setState(() {
                        _tipoInstId = v;
                        if (match.isNotEmpty) {
                          _tipoInstNombre = (match.first['nombre'] ?? '').toString();
                          final ap = match.first['aplica_excentricidad'];
                          _aplicaExcentricidad = ap == null || ap == 1 || ap == true;
                          if (!_aplicaExcentricidad) {
                            _motivoNoExcentricidad =
                                inferirMotivoNoExcentricidad(null, _tipoInstNombre);
                          }
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),

                  // Marca + Modelo con Autocomplete de historial
                  Row(children: [
                    Expanded(
                      child: _InstrumentoAutocompleteField(
                        label: 'Marca',
                        controller: _marcaCtrl,
                        historial: _historialInstrumentos,
                        fieldKey: 'marca',
                        onChanged: (_) => setState(() {}),
                        onSelectedInstrument: _aplicarInstrumentoSugerido,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InstrumentoAutocompleteField(
                        label: 'Modelo',
                        controller: _modeloCtrl,
                        historial: _historialInstrumentos,
                        fieldKey: 'modelo',
                        onChanged: (_) => setState(() {}),
                        onSelectedInstrument: _aplicarInstrumentoSugerido,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // Serie + ID Indicador con Autocomplete de historial
                  Row(children: [
                    Expanded(
                      child: _InstrumentoAutocompleteField(
                        label: 'N° de Serie (S/N)',
                        controller: _serieCtrl,
                        historial: _historialInstrumentos,
                        fieldKey: 'serie',
                        onChanged: (_) => setState(() {}),
                        onSelectedInstrument: _aplicarInstrumentoSugerido,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InstrumentoAutocompleteField(
                        label: 'ID Indicador / Equipo',
                        controller: _idEquipoCtrl,
                        historial: _historialInstrumentos,
                        fieldKey: 'id_indicador',
                        onChanged: (_) => setState(() {}),
                        onSelectedInstrument: _aplicarInstrumentoSugerido,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // Capacidad + División Mínima + Ubicación
                  Row(children: [
                    Expanded(
                      child: _InputField(
                        label: 'Capacidad Máxima',
                        controller: _capacidadCtrl,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InputField(
                        label: 'División Mínima',
                        controller: _divisionCtrl,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InputField(
                        label: 'Ubicación / Área',
                        controller: _ubicacionCtrl,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // Números Regulatorios independientes: CCA y DVE
                  Row(children: [
                    Expanded(
                      child: _InputField(
                        label: 'Número CCA (ej. CCA.26.02163)',
                        controller: _ccaCtrl,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InputField(
                        label: 'Número DVE (ej. DVE.26.00412)',
                        controller: _dveCtrl,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),

                  // Switch Aplica Excentricidad + Selector Motivo No Apto
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    activeColor: _red,
                    title: const Text(
                      'Aplica Prueba de Excentricidad',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    value: _aplicaExcentricidad,
                    onChanged: (v) => setState(() => _aplicaExcentricidad = v),
                  ),
                  if (!_aplicaExcentricidad) ...[
                    const Text(
                      'Instrumento especial no apto para excentricidad:',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final m in kTiposNoAptosExcentricidad)
                          ChoiceChip(
                            label: Text(m, style: const TextStyle(fontSize: 12)),
                            selected: _motivoNoExcentricidad == m,
                            selectedColor: _red,
                            labelStyle: TextStyle(
                              color: _motivoNoExcentricidad == m
                                  ? Colors.white
                                  : const Color(0xFF374151),
                              fontWeight: FontWeight.w600,
                            ),
                            onSelected: (sel) {
                              if (sel) setState(() => _motivoNoExcentricidad = m);
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── 9. Observaciones ────────────────────────────────────────────
            const _SectionTitle('9. Observaciones e Instrucciones'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _observCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Instrucciones especiales para el técnico en campo...',
                hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _red, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),

            const SizedBox(height: 28),

            // ── Botón Asignar y Notificar a Servidor ────────────────────────
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _loading ? Colors.grey.shade400 : _red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                onPressed: _loading ? null : _submit,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
                label: Text(
                  _loading ? 'Creando y asignando...' : 'Crear y Asignar Formato(s)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── Buscador modal de Clientes ─────────────────────────────────────────────

class _ClienteSearchSheet extends StatefulWidget {
  final List<Map<String, dynamic>> clientes;
  const _ClienteSearchSheet({required this.clientes});

  @override
  State<_ClienteSearchSheet> createState() => _ClienteSearchSheetState();
}

class _ClienteSearchSheetState extends State<_ClienteSearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final qNorm = LocalDbService.normalizarTexto(_query);
    final filtered = _query.trim().isEmpty
        ? widget.clientes
        : widget.clientes.where((c) {
            final nom = LocalDbService.normalizarTexto(
              (c['nombre'] ?? c['razon_social'] ?? '').toString(),
            );
            final rfc = LocalDbService.normalizarTexto((c['rfc'] ?? '').toString());
            final dir = LocalDbService.normalizarTexto((c['direccion'] ?? '').toString());
            return nom.contains(qNorm) || rfc.contains(qNorm) || dir.contains(qNorm);
          }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.80,
      minChildSize: 0.50,
      maxChildSize: 0.94,
      builder: (ctx, scrollCtrl) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.business_rounded, color: Color(0xFFB81D24)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Seleccionar Cliente (${filtered.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Buscar por razón social, nombre comercial, RFC o dirección...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFFF3F4F6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'Sin coincidencias en el catálogo de clientes',
                        style: TextStyle(color: Color(0xFF6B7280)),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollCtrl,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final c = filtered[i];
                        final nom = (c['nombre'] ?? c['razon_social'] ?? '').toString();
                        final rfc = (c['rfc'] ?? '').toString().trim();
                        final sucs = (c['sucursales'] as List?) ?? const [];
                        final dir = (c['direccion'] ?? '').toString().trim();
                        return ListTile(
                          dense: true,
                          title: Text(
                            nom,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                          ),
                          subtitle: Text(
                            [
                              if (rfc.isNotEmpty) 'RFC: $rfc',
                              if (sucs.isNotEmpty) '${sucs.length} planta(s)/dirección(es)',
                              if (dir.isNotEmpty) dir,
                            ].join(' • '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => Navigator.pop(ctx, c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Autocomplete inteligente para campos de instrumento ────────────────────

class _InstrumentoAutocompleteField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final List<Map<String, dynamic>> historial;
  final String fieldKey;
  final ValueChanged<String>? onChanged;
  final ValueChanged<Map<String, dynamic>> onSelectedInstrument;

  const _InstrumentoAutocompleteField({
    required this.label,
    required this.controller,
    required this.historial,
    required this.fieldKey,
    required this.onSelectedInstrument,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Map<String, dynamic>>(
      textEditingController: controller,
      focusNode: FocusNode(),
      displayStringForOption: (opt) => (opt[fieldKey] ?? '').toString(),
      optionsBuilder: (TextEditingValue tev) {
        final q = LocalDbService.normalizarTexto(tev.text);
        if (historial.isEmpty) return const Iterable<Map<String, dynamic>>.empty();
        final matches = historial.where((inst) {
          final valField = (inst[fieldKey] ?? '').toString().trim();
          if (valField.isEmpty) return false;
          if (q.isEmpty) return (inst['_prio'] as int? ?? 3) <= 1;
          final blob = LocalDbService.normalizarTexto(
            '${inst['marca']} ${inst['modelo']} ${inst['serie']} ${inst['id_indicador']} ${inst['ubicacion']}',
          );
          return blob.contains(q);
        }).take(18);
        return matches;
      },
      onSelected: onSelectedInstrument,
      fieldViewBuilder: (ctx, textCtrl, focusNode, onSubmit) {
        return TextFormField(
          controller: textCtrl,
          focusNode: focusNode,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.bolt_rounded, size: 16, color: Color(0xFF9CA3AF)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFC8102E), width: 2),
            ),
            filled: true,
            fillColor: Colors.white,
          ),
        );
      },
      optionsViewBuilder: (ctx, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 420),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final opt = options.elementAt(i);
                  final titulo = [
                    opt['marca'],
                    opt['modelo'],
                    if ((opt['serie'] ?? '').toString().isNotEmpty) 'SN: ${opt['serie']}',
                    if ((opt['id_indicador'] ?? '').toString().isNotEmpty) 'ID: ${opt['id_indicador']}',
                  ].where((e) => e != null && e.toString().trim().isNotEmpty).join(' • ');
                  final sub = [
                    if ((opt['ubicacion'] ?? '').toString().isNotEmpty) opt['ubicacion'],
                    if ((opt['capacidad_maxima'] ?? '').toString().isNotEmpty)
                      'Cap: ${opt['capacidad_maxima']}',
                    if ((opt['cliente'] ?? '').toString().isNotEmpty) opt['cliente'],
                  ].join(' · ');
                  return ListTile(
                    dense: true,
                    title: Text(
                      titulo,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                    subtitle: sub.isNotEmpty
                        ? Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)))
                        : null,
                    onTap: () => onSelected(opt),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RegBadge extends StatelessWidget {
  final String prefix;
  final String value;
  final Color color;
  final Color bg;

  const _RegBadge({
    required this.prefix,
    required this.value,
    required this.color,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$prefix: $value',
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

// ── Widgets auxiliares ─────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF374151),
          letterSpacing: 0.3,
        ),
      );
}

class _RadioCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _RadioCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFC8102E);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFEE2E2) : Colors.white,
          border: Border.all(
            color: selected ? red : const Color(0xFFE5E7EB),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: selected ? red : const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? red : const Color(0xFF374151),
              ),
            ),
          ),
          if (selected) const Icon(Icons.check_circle, size: 16, color: red),
        ]),
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;

  const _InputField({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        validator: validator,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFC8102E), width: 2),
          ),
          filled: true,
          fillColor: Colors.white,
        ),
      );
}

class _CatalogDropdown extends StatelessWidget {
  final String hint;
  final List<Map<String, dynamic>> items;
  final List<String> labelKeys;
  final String idKey;
  final int? value;
  final ValueChanged<int?> onChanged;
  final String? Function(int?)? validator;

  const _CatalogDropdown({
    required this.hint,
    required this.items,
    required this.labelKeys,
    required this.idKey,
    required this.value,
    required this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    final validIds = items.map((e) => int.tryParse('${e[idKey] ?? ''}')).whereType<int>().toSet();
    final safeValue = (value != null && validIds.contains(value)) ? value : null;

    return DropdownButtonFormField<int>(
      value: safeValue,
      isExpanded: true,
      hint: Text(
        hint,
        style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
      ),
      validator: validator != null ? (v) => validator!(v) : null,
      decoration: InputDecoration(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFC8102E), width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      items: items.map((item) {
        final id = int.tryParse('${item[idKey] ?? 0}') ?? 0;
        String label = '—';
        for (final k in labelKeys) {
          final v = item[k]?.toString().trim() ?? '';
          if (v.isNotEmpty) {
            label = v;
            break;
          }
        }
        return DropdownMenuItem<int>(
          value: id,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}
