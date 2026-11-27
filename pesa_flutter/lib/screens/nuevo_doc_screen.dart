// lib/screens/nuevo_doc_screen.dart — Asistente de Generación de Formatos en 4 Pasos (Paridad 1:1 Windows)
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/metrology_helper.dart';
import '../services/sync_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/cliente_correo_poka_yoke.dart';

class _InstrumentoDraft {
  bool expanded = true;
  final TextEditingController marcaCtrl = TextEditingController();
  final TextEditingController modeloCtrl = TextEditingController();
  final TextEditingController serieCtrl = TextEditingController();
  final TextEditingController idEquipoCtrl = TextEditingController();
  final TextEditingController capacidadCtrl = TextEditingController();
  final TextEditingController divisionCtrl = TextEditingController();
  final TextEditingController ubicacionCtrl = TextEditingController();
  final TextEditingController ccaCtrl = TextEditingController();
  final TextEditingController dveDivCtrl = TextEditingController();
  final TextEditingController dveNumCtrl = TextEditingController();
  final TextEditingController holoAntCtrl = TextEditingController();
  final TextEditingController holoActCtrl = TextEditingController();

  final FocusNode marcaFocus = FocusNode();
  final FocusNode modeloFocus = FocusNode();
  final FocusNode serieFocus = FocusNode();
  final FocusNode idEquipoFocus = FocusNode();

  int? tipoInstId;
  String tipoInstNombre = 'Báscula de plataforma';
  bool aplicaExcentricidad = true;
  int puntosExcentricidad = 5;
  int puntosExactitud = 5;
  String geometriaPuntos = 'Libre';
  int numSecciones = 4;
  String motivoNoExcentricidad = 'Tanque';
  bool aplicaEnlacesSustitucion = false;
  int cantidadEnlaces = 3;
  String inicialCalibrador = 'Ninguna';

  void dispose() {
    marcaCtrl.dispose();
    modeloCtrl.dispose();
    serieCtrl.dispose();
    idEquipoCtrl.dispose();
    capacidadCtrl.dispose();
    divisionCtrl.dispose();
    ubicacionCtrl.dispose();
    ccaCtrl.dispose();
    dveDivCtrl.dispose();
    dveNumCtrl.dispose();
    holoAntCtrl.dispose();
    holoActCtrl.dispose();
    marcaFocus.dispose();
    modeloFocus.dispose();
    serieFocus.dispose();
    idEquipoFocus.dispose();
  }

  void limpiarRegulatorios({required bool allowCca, required bool allowDve}) {
    if (!allowCca) {
      inicialCalibrador = 'Ninguna';
      ccaCtrl.clear();
    }
    if (!allowDve) {
      dveDivCtrl.clear();
      dveNumCtrl.clear();
      holoAntCtrl.clear();
      holoActCtrl.clear();
    }
  }

  String? _geoCode() {
    final g = geometriaPuntos.toLowerCase();
    if (g.contains('cuadrada')) return 'cuadrada';
    if (g.contains('circular')) return 'circular';
    if (g.contains('camionera')) return 'camionera';
    return null;
  }

  Map<String, dynamic> toPayload({
    required bool allowCca,
    required bool allowDve,
  }) {
    final divNorm = formatearDivisionMinima(divisionCtrl.text);
    final ccaClean = allowCca ? limpiarNumeroRegulatorio(ccaCtrl.text) : '';
    final dveClean = allowDve ? limpiarNumeroRegulatorio(dveNumCtrl.text) : '';
    final dveDiv = allowDve ? dveDivCtrl.text.trim() : '';
    final holoAnt = allowDve ? holoAntCtrl.text.trim() : '';
    final holoAct = allowDve ? holoActCtrl.text.trim() : '';
    final ini = (allowCca && inicialCalibrador != 'Ninguna') ? inicialCalibrador : '';

    final bool enlacesActivos = !aplicaExcentricidad && aplicaEnlacesSustitucion;
    final int? nEnlaces = enlacesActivos ? cantidadEnlaces : null;
    final String motivo = aplicaExcentricidad ? '' : motivoNoExcentricidad;
    final String? geo = aplicaExcentricidad ? _geoCode() : null;
    final int filasExc = aplicaExcentricidad
        ? (geo == 'camionera'
            ? (puntosExcentricidad > numSecciones ? puntosExcentricidad : numSecciones)
            : puntosExcentricidad)
        : 1;

    return <String, dynamic>{
      if (tipoInstId != null && tipoInstId! > 0) 'id_tipo_instrumento': tipoInstId,
      if (tipoInstNombre.trim().isNotEmpty) 'tipo_instrumento': tipoInstNombre.trim(),
      if (marcaCtrl.text.trim().isNotEmpty) 'marca': marcaCtrl.text.trim(),
      if (modeloCtrl.text.trim().isNotEmpty) 'modelo': modeloCtrl.text.trim(),
      if (serieCtrl.text.trim().isNotEmpty) 'serie': serieCtrl.text.trim(),
      if (serieCtrl.text.trim().isNotEmpty) 'ns': serieCtrl.text.trim(),
      if (idEquipoCtrl.text.trim().isNotEmpty) 'id_indicador': idEquipoCtrl.text.trim(),
      if (idEquipoCtrl.text.trim().isNotEmpty) 'id_equipo': idEquipoCtrl.text.trim(),
      if (capacidadCtrl.text.trim().isNotEmpty) 'capacidad_maxima': capacidadCtrl.text.trim(),
      if (divNorm.isNotEmpty) 'division_minima': divNorm,
      if (ubicacionCtrl.text.trim().isNotEmpty) 'ubicacion': ubicacionCtrl.text.trim(),
      'aplica_excentricidad': aplicaExcentricidad,
      if (!aplicaExcentricidad) ...{
        'motivo_no_excentricidad': motivo,
        'motivo_no_aplica': motivo,
        'tipo_no_apto': motivo,
        'tipo_no_aplica_exc': motivo.toLowerCase(),
      },
      'puntos_excentricidad': puntosExcentricidad,
      'filas_excentricidad': filasExc,
      'puntos_apoyo': filasExc,
      'puntos_exactitud': puntosExactitud,
      'pts_exactitud': puntosExactitud,
      'filas_exactitud': puntosExactitud,
      if (geo != null) 'geometria_plataforma': geo,
      if (geo != null) 'geometria_puntos': geometriaPuntos,
      if (geo == 'camionera') 'num_secciones': numSecciones,
      'aplica_cargas_sustitucion': enlacesActivos,
      'aplica_enlaces_sustitucion': enlacesActivos,
      'aplica_sustitucion': enlacesActivos,
      'usa_sustitucion': enlacesActivos,
      'es_enlace_sustitucion': enlacesActivos,
      'es_sustitucion': enlacesActivos,
      'cantidad_enlaces': enlacesActivos ? (nEnlaces ?? 3) : 0,
      'num_enlaces_sustitucion': enlacesActivos ? (nEnlaces ?? 3) : 0,
      'num_enlaces': enlacesActivos ? (nEnlaces ?? 3) : 0,
      if (ini.isNotEmpty) 'inicial_calibrador': ini,
      if (ccaClean.isNotEmpty) 'numero_cca': ccaClean,
      if (dveDiv.isNotEmpty) 'dve': dveDiv,
      if (dveClean.isNotEmpty) 'numero_dve': dveClean,
      if (holoAnt.isNotEmpty) 'holograma_anterior': holoAnt,
      if (holoAct.isNotEmpty) 'holograma_actualizado': holoAct,
    };
  }
}

class NuevoDocScreen extends StatefulWidget {
  const NuevoDocScreen({super.key});

  @override
  State<NuevoDocScreen> createState() => _NuevoDocScreenState();
}

class _NuevoDocScreenState extends State<NuevoDocScreen> {
  static const _red = PesaColors.brand;

  static const _defaultTiposInst = <String>[
    'Báscula de plataforma',
    'Báscula tipo tanque',
    'Báscula camionera / puente',
    'Báscula tipo tolva',
    'Báscula tipo silo',
    'Báscula colgante / grúa',
    'Báscula patín / transpaleta',
    'Báscula mostrador / analítica',
  ];

  static const _motivosNoAplica = <String>[
    'Tanque',
    'Tolva',
    'Silo',
    'Grúa',
    'Patín',
  ];

  static const _geometriasOpciones = <String>[
    'Libre',
    'Plataforma Cuadrada',
    'Plataforma Circular',
    'Camionera',
  ];

  static const _modalidadesDef = <Map<String, String>>[
    {
      'key': 'Digital',
      'badge': 'DIGITAL',
      'title': 'Digital — Tablet',
      'desc': 'Captura en campo desde app móvil con firma digital y sincronización automática.',
    },
    {
      'key': 'Físico',
      'badge': 'FÍSICO',
      'title': 'Físico — Impresión',
      'desc': 'Genera PDF para impresión en papel carbón con escaneo posterior del firmado.',
    },
    {
      'key': 'Híbrido',
      'badge': 'HÍBRIDO',
      'title': 'Híbrido — Digital + Físico',
      'desc': 'Genera PDF imprimible y habilita captura digital simultánea en tablet.',
    },
  ];

  static const _tiposDocDef = <Map<String, String>>[
    {
      'code': 'OS',
      'title': 'Orden de Servicio',
      'desc': 'Calibración, ajuste e inspección de instrumentos.',
    },
    {
      'code': 'RMA',
      'title': 'Remisión de Material',
      'desc': 'Traslado de equipos o refacciones para servicio.',
    },
    {
      'code': 'RE',
      'title': 'Revisión de Báscula',
      'desc': 'Verificación de celdas de carga y básculas.',
    },
    {
      'code': 'LP',
      'title': 'Levantamiento de Proyecto',
      'desc': 'Levantamiento técnico de campo y proyectos.',
    },
    {
      'code': 'LV',
      'title': 'Levantamiento Metrológico',
      'desc': 'Pre-visita, básculas y logística de pesas patrón.',
    },
    {
      'code': 'OSOB',
      'title': 'Observaciones',
      'desc': 'Formato de inspección y revisión de básculas.',
    },
    {
      'code': 'OSOCC',
      'title': 'Observaciones Celda',
      'desc': 'Diagnóstico unitario de celdas (Stock o Cliente).',
    },
  ];

  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _loadingCat = true;
  bool _syncingCat = false;
  bool _loadingFolio = true;
  String? _error;
  String _folioOrigen = '';

  // ── Catálogos sincronizados ───────────────────────────────────────────────
  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _sucursalesCliente = [];
  List<Map<String, dynamic>> _tecnicos = [];
  List<Map<String, dynamic>> _tiposServ = [];
  List<Map<String, dynamic>> _tiposInst = [];
  List<Map<String, dynamic>> _historialInstrumentos = [];
  List<String> _correosFrecuentes = [];

  // ── Estado Paso 1 y 2 ─────────────────────────────────────────────────────
  String _modalidad = 'Digital';
  String _tipoDoc = 'OS';

  // ── Estado Paso 3 ─────────────────────────────────────────────────────────
  int? _clienteId;
  String _clienteNombre = '';
  int? _sucursalId;
  int? _tecnicoId;
  int? _tipoServId;
  int _cantidad = 1;

  final _sucursalCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();
  final _correoCtrl = TextEditingController();
  final _observCtrl = TextEditingController();
  final _fechaCtrl = TextEditingController(
    text: DateTime.now().toIso8601String().split('T')[0],
  );
  final _folioInicialCtrl = TextEditingController();

  final List<_InstrumentoDraft> _equipos = [_InstrumentoDraft()];

  ServiceRules get _activeRules {
    String? srvNombre;
    if (_tipoServId != null) {
      final hit = _tiposServ.where((t) => int.tryParse('${t['id']}') == _tipoServId);
      if (hit.isNotEmpty) {
        srvNombre = (hit.first['nombre'] ?? '').toString();
      }
    }
    final folioRef = _folioInicialCtrl.text.trim().isNotEmpty
        ? _folioInicialCtrl.text.trim()
        : '$_tipoDoc-26-1';
    return getRules(
      id: _tipoServId,
      nombre: srvNombre,
      folio: folioRef,
    );
  }

  String get _ctaLabel {
    if (_loading) return 'Generando y asignando...';
    if (_modalidad == 'Físico') return 'Generar e Imprimir PDF';
    if (_modalidad == 'Híbrido') return 'Generar Híbrido (PDF + Tablet)';
    return 'Asignar y Sincronizar a Tablet';
  }

  @override
  void initState() {
    super.initState();
    _loadCatalogos();
    _cargarSiguienteFolio(_tipoDoc);
  }

  @override
  void dispose() {
    _sucursalCtrl.dispose();
    _direccionCtrl.dispose();
    _correoCtrl.dispose();
    _observCtrl.dispose();
    _fechaCtrl.dispose();
    _folioInicialCtrl.dispose();
    for (final eq in _equipos) {
      eq.dispose();
    }
    super.dispose();
  }

  void _salir([bool creado = false]) {
    if (context.canPop()) {
      context.pop(creado);
    } else {
      context.go('/os');
    }
  }

  void _ajustarCantidadEquipos(int nuevaCantidad) {
    final clamped = nuevaCantidad.clamp(1, 50);
    setState(() {
      _cantidad = clamped;
      while (_equipos.length < clamped) {
        _equipos.add(_InstrumentoDraft());
      }
      while (_equipos.length > clamped) {
        final removed = _equipos.removeLast();
        removed.dispose();
      }
    });
  }

  void _reiniciarFormulario() {
    setState(() {
      _modalidad = 'Digital';
      _tipoDoc = 'OS';
      _clienteId = null;
      _clienteNombre = '';
      _sucursalId = null;
      _tecnicoId = null;
      _tipoServId = null;
      _sucursalesCliente = [];
      _historialInstrumentos = [];
      _correosFrecuentes = [];
      _sucursalCtrl.clear();
      _direccionCtrl.clear();
      _correoCtrl.clear();
      _observCtrl.clear();
      _fechaCtrl.text = DateTime.now().toIso8601String().split('T')[0];
      _error = null;
      for (final eq in _equipos) {
        eq.dispose();
      }
      _equipos
        ..clear()
        ..add(_InstrumentoDraft());
      _cantidad = 1;
    });
    _cargarSiguienteFolio('OS');
  }

  Future<void> _cargarSiguienteFolio(String tipo) async {
    if (mounted) {
      setState(() {
        _loadingFolio = true;
      });
    }
    Map<String, dynamic>? resp;
    try {
      resp = await ApiService.instance.getSiguienteFolio(tipo);
    } catch (_) {}

    if (resp == null || (resp['folio_inicial'] ?? '').toString().trim().isEmpty) {
      try {
        resp = await LocalDbService.instance.calcularSiguienteFolioLocal(tipo);
      } catch (_) {}
    }

    if (!mounted) return;
    final folioStr = (resp?['folio_inicial'] ?? '').toString().trim();
    final origen = (resp?['origen'] ?? '').toString() == 'offline_sqlite'
        ? 'Offline (SQLite)'
        : 'Consecutivo en vivo';
    setState(() {
      if (folioStr.isNotEmpty) {
        _folioInicialCtrl.text = folioStr;
      } else {
        final yy = (DateTime.now().year % 100).toString().padLeft(2, '0');
        final suffix = (tipo == 'OSOB' || tipo == 'OSOCC') ? '001' : '1';
        _folioInicialCtrl.text = '$tipo-$yy-$suffix';
      }
      _folioOrigen = origen;
      _loadingFolio = false;
    });
  }

  String? _calcularRangoPreview() {
    if (_cantidad <= 1) return null;
    final raw = _folioInicialCtrl.text.trim().toUpperCase();
    final parts = raw.split('-');
    if (parts.length < 3) return null;
    final numPart = parts.last;
    final startNum = int.tryParse(numPart);
    if (startNum == null) return null;
    final endNum = startNum + _cantidad - 1;
    final prefix = parts.sublist(0, parts.length - 1).join('-');
    final endStr = (_tipoDoc == 'OSOB' || _tipoDoc == 'OSOCC' || (numPart.startsWith('0') && numPart.length >= 3))
        ? endNum.toString().padLeft(3, '0')
        : endNum.toString();
    return '$raw al $prefix-$endStr ($_cantidad formatos)';
  }

  Future<void> _loadCatalogos({bool forceRemote = false}) async {
    final db = LocalDbService.instance;
    if (forceRemote && mounted) {
      setState(() => _syncingCat = true);
    }

    try {
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
    final sucsLocal = await LocalDbService.instance.getCatalogoSucursales(
      clienteId: clienteId,
      clienteNombre: clienteNombre,
    );

    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    void addSuc(Map raw) {
      final m = Map<String, dynamic>.from(raw);
      final nom = (m['nombre'] ?? m['nombre_sucursal'] ?? m['planta'] ?? m['sucursal'] ?? '').toString().trim();
      final dir = (m['direccion'] ?? '').toString().trim();
      if (nom.isEmpty && dir.isEmpty) return;
      final key = '${nom.toLowerCase()}|${dir.toLowerCase()}';
      if (!seen.add(key)) return;
      merged.add({
        ...m,
        'id': int.tryParse('${m['id'] ?? m['sucursal_id'] ?? ''}'),
        'nombre': nom.isNotEmpty ? nom : dir,
        'planta': (m['planta'] ?? (nom.isNotEmpty ? nom : dir)).toString().trim(),
        'direccion': dir.isNotEmpty ? dir : nom,
        'correo': (m['correo'] ?? m['email'] ?? '').toString().trim(),
      });
    }

    for (final s in sucsLocal) {
      addSuc(s);
    }
    final cliMatch = _clientes.where((c) => int.tryParse('${c['id'] ?? 0}') == clienteId);
    if (cliMatch.isNotEmpty) {
      final cObj = cliMatch.first;
      final nested = (cObj['sucursales'] as List?) ?? (cObj['direcciones'] as List?) ?? const [];
      for (final s in nested.whereType<Map>()) {
        addSuc(s);
      }
      final dirFiscal = (cObj['direccion'] ?? '').toString().trim();
      if (dirFiscal.isNotEmpty) {
        addSuc({
          'id': null,
          'cliente_id': clienteId,
          'nombre': dirFiscal.length <= 80 ? dirFiscal : 'Matriz / Principal',
          'planta': 'Matriz / Principal',
          'direccion': dirFiscal,
          'correo': (cObj['correo'] ?? cObj['email'] ?? '').toString().trim(),
        });
      }
    }

    if (merged.isEmpty && clienteId > 0) {
      try {
        final remoteSucs = await ApiService.instance.getSucursalesCliente(clienteId);
        for (final s in remoteSucs) {
          addSuc(s);
        }
      } catch (_) {}
    }

    final hist = await LocalDbService.instance.getHistorialInstrumentos(
      clienteId: clienteId,
      cliente: clienteNombre,
    );
    final correos = await LocalDbService.instance.getCorreosFrecuentesCliente(
      clienteId: clienteId,
      clienteNombre: clienteNombre,
      sucursalId: merged.isNotEmpty ? merged.first['id'] as int? : null,
    );

    if (!mounted) return;
    setState(() {
      _sucursalesCliente = merged;
      _historialInstrumentos = hist;
      _correosFrecuentes = correos;
      if (autoSelectFirst) {
        if (merged.isNotEmpty) {
          final first = merged.first;
          _sucursalId = first['id'] as int?;
          final nom = (first['nombre'] ?? '').toString().trim();
          final dir = (first['direccion'] ?? '').toString().trim();
          _sucursalCtrl.text = nom.isNotEmpty ? nom : dir;
          _direccionCtrl.text = dir.isNotEmpty ? dir : nom;
          final cSuc = (first['correo'] ?? '').toString().trim();
          if (_correoCtrl.text.trim().isEmpty && esCorreoClienteValido(cSuc)) {
            _correoCtrl.text = cSuc;
          } else if (_correoCtrl.text.trim().isEmpty && correos.isNotEmpty) {
            _correoCtrl.text = correos.first;
          }
        } else {
          _sucursalId = null;
          _sucursalCtrl.clear();
          _direccionCtrl.clear();
          if (_correoCtrl.text.trim().isEmpty && correos.isNotEmpty) {
            _correoCtrl.text = correos.first;
          }
        }
      }
    });
  }

  Future<void> _abrirBuscadorClientes() async {
    final selected = await showFoldableBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _ClienteSearchSheet(clientes: _clientes),
    );
    if (selected != null) {
      final cid = int.tryParse('${selected['id'] ?? 0}') ?? 0;
      final cnom = (selected['nombre'] ?? selected['razon_social'] ?? '').toString().trim();
      setState(() {
        _clienteId = cid;
        _clienteNombre = cnom;
        _correoCtrl.clear();
      });
      await _cargarSucursalesDeCliente(cid, cnom, autoSelectFirst: true);
    }
  }

  Future<void> _crearNuevoClienteInline() async {
    final razonCtrl = TextEditingController();
    final rfcCtrl = TextEditingController();
    final telCtrl = TextEditingController();
    final dirCtrl = TextEditingController();
    final fKey = GlobalKey<FormState>();
    bool saving = false;
    Map<String, dynamic>? created;

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final dc = PesaColors.of(ctx);
          return AlertDialog(
            backgroundColor: dc.surface,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: dc.border),
            ),
            title: Text('Nuevo Cliente', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: dc.textPrimary)),
            content: SizedBox(
              width: 440,
              child: Form(
                key: fKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: razonCtrl,
                        decoration: const InputDecoration(labelText: 'Razón Social *'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: rfcCtrl,
                        decoration: const InputDecoration(labelText: 'RFC (opcional)'),
                        textCapitalization: TextCapitalization.characters,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: telCtrl,
                        decoration: const InputDecoration(labelText: 'Teléfono'),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: dirCtrl,
                        decoration: const InputDecoration(labelText: 'Dirección Principal'),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.of(dlgCtx).pop(),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(fKey.currentState?.validate() ?? false)) return;
                        setDlgState(() => saving = true);
                        try {
                          created = await ApiService.instance.crearCliente(
                            razonSocial: razonCtrl.text,
                            rfc: rfcCtrl.text,
                            telefono: telCtrl.text,
                            direccion: dirCtrl.text,
                          );
                          if (dlgCtx.mounted) Navigator.of(dlgCtx).pop();
                        } catch (e) {
                          setDlgState(() => saving = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: PesaColors.brand,
                                content: Text('Error creando cliente: $e'),
                              ),
                            );
                          }
                        }
                      },
                child: Text(saving ? 'Guardando...' : 'Crear y Seleccionar'),
              ),
            ],
          );
        },
      ),
    );
    razonCtrl.dispose();
    rfcCtrl.dispose();
    telCtrl.dispose();
    dirCtrl.dispose();

    if (created != null && mounted) {
      await _loadCatalogos(forceRemote: true);
      final cid = int.tryParse('${created!['id']}') ?? 0;
      final cnom = (created!['razon_social'] ?? created!['nombre'] ?? '').toString().trim();
      if (cid > 0 && mounted) {
        setState(() {
          _clienteId = cid;
          _clienteNombre = cnom;
        });
        await _cargarSucursalesDeCliente(cid, cnom, autoSelectFirst: true);
      }
    }
  }

  Future<void> _crearNuevaSucursalInline() async {
    final cid = _clienteId;
    if (cid == null) return;
    final nomCtrl = TextEditingController();
    final dirCtrl = TextEditingController();
    final conCtrl = TextEditingController();
    final fKey = GlobalKey<FormState>();
    bool saving = false;
    Map<String, dynamic>? created;

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final dc = PesaColors.of(ctx);
          return AlertDialog(
            backgroundColor: dc.surface,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: dc.border),
            ),
            title: Text(
              'Nueva Sucursal — $_clienteNombre',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: dc.textPrimary),
            ),
            content: SizedBox(
              width: 440,
              child: Form(
                key: fKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: nomCtrl,
                        decoration: const InputDecoration(labelText: 'Nombre Sucursal / Planta *'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: dirCtrl,
                        decoration: const InputDecoration(labelText: 'Dirección Completa *'),
                        maxLines: 2,
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: conCtrl,
                        decoration: const InputDecoration(labelText: 'Contacto en Planta (opcional)'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.of(dlgCtx).pop(),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(fKey.currentState?.validate() ?? false)) return;
                        setDlgState(() => saving = true);
                        try {
                          created = await ApiService.instance.crearSucursal(
                            cid,
                            nombreSucursal: nomCtrl.text,
                            direccion: dirCtrl.text,
                            contactoNombre: conCtrl.text,
                          );
                          if (dlgCtx.mounted) Navigator.of(dlgCtx).pop();
                        } catch (e) {
                          setDlgState(() => saving = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: PesaColors.brand,
                                content: Text('Error creando sucursal: $e'),
                              ),
                            );
                          }
                        }
                      },
                child: Text(saving ? 'Guardando...' : 'Guardar y Seleccionar'),
              ),
            ],
          );
        },
      ),
    );
    nomCtrl.dispose();
    dirCtrl.dispose();
    conCtrl.dispose();

    if (created != null && mounted) {
      await _loadCatalogos(forceRemote: true);
      final sid = int.tryParse('${created!['id']}');
      final snom = (created!['nombre_sucursal'] ?? created!['nombre'] ?? '').toString().trim();
      final sdir = (created!['direccion'] ?? '').toString().trim();
      if (mounted) {
        setState(() {
          _sucursalId = sid;
          _sucursalCtrl.text = snom.isNotEmpty ? snom : sdir;
          _direccionCtrl.text = sdir.isNotEmpty ? sdir : snom;
        });
      }
    }
  }

  void _aplicarReglaTipoInstrumento(_InstrumentoDraft eq, String nombreTipo, int? idTipo) {
    final tLow = nombreTipo.toLowerCase();
    final bool esTanque = tLow.contains('tanque');
    final bool esSilo = tLow.contains('silo') && !esTanque;
    final bool esColgante = tLow.contains('colgante') || tLow.contains('grúa') || tLow.contains('grua') || tLow.contains('gancho');
    final bool esPatin = tLow.contains('patín') || tLow.contains('patin') || tLow.contains('transpaleta');
    final bool esTolva = tLow.contains('tolva');
    final bool esCamionera = tLow.contains('camionera') || tLow.contains('puente') || tLow.contains('ferro');

    setState(() {
      eq.tipoInstNombre = nombreTipo;
      eq.tipoInstId = idTipo;
      if (esTanque) {
        eq.aplicaExcentricidad = false;
        eq.motivoNoExcentricidad = 'Tanque';
        eq.aplicaEnlacesSustitucion = false;
      } else if (esSilo) {
        eq.aplicaExcentricidad = false;
        eq.motivoNoExcentricidad = 'Silo';
      } else if (esColgante) {
        eq.aplicaExcentricidad = false;
        eq.motivoNoExcentricidad = 'Grúa';
      } else if (esPatin) {
        eq.aplicaExcentricidad = false;
        eq.motivoNoExcentricidad = 'Patín';
      } else if (esTolva) {
        eq.aplicaExcentricidad = false;
        eq.motivoNoExcentricidad = 'Tolva';
      } else {
        eq.aplicaExcentricidad = true;
        eq.aplicaEnlacesSustitucion = false;
        if (esCamionera) {
          eq.geometriaPuntos = 'Camionera';
          eq.puntosExcentricidad = 8;
        } else {
          eq.puntosExcentricidad = 5;
        }
      }
    });
  }

  void _aplicarSugerenciaHistorial(_InstrumentoDraft eq, Map<String, dynamic> inst) {
    final m = (inst['marca'] ?? '').toString().trim();
    final mod = (inst['modelo'] ?? '').toString().trim();
    final ser = (inst['serie'] ?? inst['ns'] ?? '').toString().trim();
    final idEq = (inst['id_indicador'] ?? inst['id_equipo'] ?? '').toString().trim();
    final cap = (inst['capacidad_maxima'] ?? '').toString().trim();
    final div = formatearDivisionMinima(inst['division_minima']);
    final ubic = (inst['ubicacion'] ?? '').toString().trim();
    final tInst = (inst['tipo_instrumento'] ?? '').toString().trim();

    setState(() {
      if (m.isNotEmpty) eq.marcaCtrl.text = m;
      if (mod.isNotEmpty) eq.modeloCtrl.text = mod;
      if (ser.isNotEmpty) eq.serieCtrl.text = ser;
      if (idEq.isNotEmpty) eq.idEquipoCtrl.text = idEq;
      if (cap.isNotEmpty) eq.capacidadCtrl.text = cap;
      if (div.isNotEmpty) eq.divisionCtrl.text = div;
      if (ubic.isNotEmpty) eq.ubicacionCtrl.text = ubic;
    });
    if (tInst.isNotEmpty) {
      int? matchId;
      for (final t in _tiposInst) {
        if ((t['nombre'] ?? '').toString().toLowerCase() == tInst.toLowerCase()) {
          matchId = int.tryParse('${t['id']}');
          break;
        }
      }
      _aplicarReglaTipoInstrumento(eq, tInst, matchId);
    }
  }

  List<String> _opcionesTipoInstrumento() {
    final list = <String>[];
    final seen = <String>{};
    for (final t in _tiposInst) {
      final n = (t['nombre'] ?? '').toString().trim();
      if (n.isNotEmpty && seen.add(n.toLowerCase())) list.add(n);
    }
    for (final def in _defaultTiposInst) {
      if (seen.add(def.toLowerCase())) list.add(def);
    }
    return list;
  }

  Future<void> _submit() async {
    if (_clienteId == null || _clienteNombre.isEmpty) {
      setState(() => _error = 'Selecciona un cliente del catálogo antes de generar.');
      return;
    }
    if (_tipoDoc == 'OS' && (_tipoServId == null || _tipoServId! <= 0)) {
      setState(() => _error = 'Selecciona el Tipo de Servicio para la Orden de Servicio.');
      return;
    }
    if (_folioInicialCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Ingresa o consulta el Folio Inicial (Consecutivo).');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final rules = _activeRules;
      final allowCca = _tipoDoc == 'OS' && rules.tieneCalibracion;
      final allowDve = _tipoDoc == 'OS' && rules.tieneInspeccion;

      final equiposPayload = _equipos
          .map((eq) => eq.toPayload(allowCca: allowCca, allowDve: allowDve))
          .toList();
      final eq0 = equiposPayload.first;
      final correoVal = _correoCtrl.text.trim();

      final payload = <String, dynamic>{
        'tipo_documento': _tipoDoc,
        'tipo': _cantidad > 1 ? 'Lote' : 'Individual',
        'cantidad': _cantidad,
        'modalidad': _modalidad,
        'folio_inicial': _folioInicialCtrl.text.trim().toUpperCase(),
        'id_cliente': _clienteId,
        'sucursal_id': _sucursalId,
        'sucursal': _sucursalCtrl.text.trim(),
        'direccion': _direccionCtrl.text.trim().isNotEmpty
            ? _direccionCtrl.text.trim()
            : _sucursalCtrl.text.trim(),
        'id_tecnico': _tecnicoId,
        if (_tipoServId != null && _tipoServId! > 0) 'id_tipo_servicio': _tipoServId,
        'observaciones': _observCtrl.text.trim(),
        'estado': 'ASIGNADA',
        'fecha': _fechaCtrl.text.trim(),
        if (correoVal.isNotEmpty) ...{
          'correo_destino': correoVal,
          'correo_cliente': correoVal,
        },
        ...eq0,
        'equipos': equiposPayload,
      };

      final result = await ApiService.instance.crearOrden(payload);

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
          final tecRow = _tecnicos.where((t) => int.tryParse('${t['id']}') == _tecnicoId);
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
        final folio = result['folio_os'] ?? result['folio'] ?? _folioInicialCtrl.text.trim();
        await showDialog<void>(
          context: context,
          builder: (dlgCtx) {
            final dc = PesaColors.of(dlgCtx);
            return AlertDialog(
              backgroundColor: dc.surface,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: dc.border),
              ),
              title: Row(children: [
                Icon(Icons.check_circle_rounded, color: dc.dotGreen, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Formato(s) Generado(s) y Asignado(s)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: dc.textPrimary),
                  ),
                ),
              ]),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Los folios fueron reservados en PostgreSQL y sincronizados inmediatamente en este dispositivo.',
                    style: TextStyle(fontSize: 13, color: dc.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: dc.surfaceMuted,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: dc.border),
                    ),
                    child: Row(children: [
                      Icon(Icons.assignment_turned_in_outlined, color: dc.brandAccent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Folio(s): $folio',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: dc.brandAccent,
                            fontSize: 14,
                            fontFeatures: const [FontFeature.tabularFigures()],
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
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    Navigator.pop(dlgCtx);
                    _salir(true);
                  },
                  child: const Text('Aceptar'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error al generar y asignar formato: $e';
          _loading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final bool cover = isCoverScreen(context);

    return AppShell(
      currentRoute: '/nuevo-doc',
      child: Scaffold(
        backgroundColor: c.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildTopHeader(cover),
              Expanded(
                child: _loadingCat && _clientes.isEmpty
                    ? const Center(child: CircularProgressIndicator(color: _red))
                    : Form(
                        key: _formKey,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final w = constraints.maxWidth;
                            final pad = w < 600 ? 12.0 : 20.0;
                            return SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(pad, 16, pad, 24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Asistente de Generación de Formatos',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: c.textPrimary,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Completa los pasos guiados para reservar folios y generar o asignar los documentos.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                  if (_error != null) ...[
                                    const SizedBox(height: 12),
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: c.isDark ? const Color(0xFF2D191D) : const Color(0xFFFEF2F2),
                                        border: Border.all(color: c.brandAccent.withValues(alpha: 0.45)),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(Icons.error_outline, color: c.brandAccent, size: 18),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _error!,
                                              style: TextStyle(color: c.brandAccent, fontSize: 12.5, fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 14),
                                  _buildStep1Modalidad(w),
                                  const SizedBox(height: 14),
                                  _buildStep2TipoDocumento(w),
                                  const SizedBox(height: 14),
                                  _buildStep3ParametrosYEquipos(w),
                                  const SizedBox(height: 14),
                                  _buildStep4ConfirmarFolios(w),
                                  const SizedBox(height: 12),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
              _buildStickyFooter(cover),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopHeader(bool cover) {
    final c = PesaColors.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(cover ? 8 : 20, 10, cover ? 12 : 20, 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          if (cover)
            IconButton(
              icon: Icon(Icons.menu_rounded, color: c.textPrimary, size: 22),
              tooltip: 'Menú principal',
              onPressed: () => AppShell.toggleMenu(context),
            ),
          Expanded(
            child: Text(
              'Generar Formatos',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: c.textPrimary,
              side: BorderSide(color: c.border),
              backgroundColor: c.surface,
              padding: EdgeInsets.symmetric(horizontal: cover ? 10 : 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _syncingCat
                ? null
                : () async {
                    await _loadCatalogos(forceRemote: true);
                    await _cargarSiguienteFolio(_tipoDoc);
                  },
            icon: _syncingCat
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red),
                  )
                : const Icon(Icons.sync_rounded, size: 15),
            label: Text(
              cover ? 'Sync' : 'Sincronizar Catálogos',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepCard({
    required int stepNumber,
    required String title,
    required Widget child,
  }) {
    final c = PesaColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: _red,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$stepNumber',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildStep1Modalidad(double width) {
    final int cols = width >= 720 ? 3 : 1;
    return _buildStepCard(
      stepNumber: 1,
      title: 'Modalidad de Trabajo',
      child: _ResponsiveGrid(
        columns: cols,
        spacing: 10,
        runSpacing: 10,
        children: _modalidadesDef.map((m) {
          final key = m['key']!;
          final selected = _modalidad == key;
          return _SelectableOptionCard(
            badge: m['badge']!,
            title: m['title']!,
            subtitle: m['desc']!,
            selected: selected,
            onTap: () => setState(() => _modalidad = key),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStep2TipoDocumento(double width) {
    final int cols = width >= 920 ? 4 : (width >= 520 ? 2 : 1);
    return _buildStepCard(
      stepNumber: 2,
      title: 'Tipo de Documento',
      child: _ResponsiveGrid(
        columns: cols,
        spacing: 10,
        runSpacing: 10,
        children: _tiposDocDef.map((d) {
          final code = d['code']!;
          final selected = _tipoDoc == code;
          return _SelectableOptionCard(
            badge: code,
            title: d['title']!,
            subtitle: d['desc']!,
            selected: selected,
            onTap: () {
              if (_tipoDoc == code) return;
              setState(() {
                _tipoDoc = code;
                if (_tipoDoc != 'OS') {
                  for (final eq in _equipos) {
                    eq.limpiarRegulatorios(allowCca: false, allowDve: false);
                  }
                }
              });
              _cargarSiguienteFolio(code);
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStep3ParametrosYEquipos(double width) {
    final c = PesaColors.of(context);
    final int cols3 = width >= 760 ? 3 : 1;
    final rules = _activeRules;
    final bool allowCca = _tipoDoc == 'OS' && rules.tieneCalibracion;
    final bool allowDve = _tipoDoc == 'OS' && rules.tieneInspeccion;

    return _buildStepCard(
      stepNumber: 3,
      title: 'Parámetros del Formato y Equipos',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Fila 1: Cliente, Sucursal/Planta, Técnico Asignado ────────────
          _ResponsiveGrid(
            columns: cols3,
            spacing: 12,
            runSpacing: 12,
            children: [
              // Cliente
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: _FieldLabel('Cliente / Razón Social *')),
                      InkWell(
                        onTap: _crearNuevoClienteInline,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Text(
                            '+ Nuevo',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.brandAccent),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  InkWell(
                    onTap: _abrirBuscadorClientes,
                    borderRadius: BorderRadius.circular(8),
                    child: InputDecorator(
                      decoration: _inputDeco(
                        context,
                        hint: 'Seleccionar cliente…',
                        suffixIcon: Icon(Icons.search_rounded, size: 18, color: c.textSecondary),
                      ),
                      child: Text(
                        _clienteNombre.isNotEmpty ? _clienteNombre : 'Buscar y seleccionar cliente…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: _clienteNombre.isNotEmpty ? FontWeight.w600 : FontWeight.w400,
                          color: _clienteNombre.isNotEmpty ? c.textPrimary : c.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // Sucursal / Planta
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: _FieldLabel('Sucursal / Planta *')),
                      if (_clienteId != null)
                        InkWell(
                          onTap: _crearNuevaSucursalInline,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Text(
                              '+ Nueva',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.brandAccent),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _sucursalesCliente.isNotEmpty
                      ? DropdownButtonFormField<int>(
                          value: _sucursalesCliente.any((s) => (s['id'] as int?) == _sucursalId)
                              ? _sucursalId
                              : null,
                          isExpanded: true,
                          decoration: _inputDeco(context, hint: 'Seleccionar sucursal…'),
                          items: _sucursalesCliente.asMap().entries.map((entry) {
                            final s = entry.value;
                            final sid = s['id'] as int?;
                            final nom = (s['nombre'] ?? '').toString().trim();
                            final dir = (s['direccion'] ?? '').toString().trim();
                            final lbl = (dir.isNotEmpty && dir != nom) ? '$nom — $dir' : nom;
                            return DropdownMenuItem<int>(
                              value: sid ?? -(entry.key + 1),
                              child: Text(lbl, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                            );
                          }).toList(),
                          onChanged: (val) async {
                            if (val == null) return;
                            Map<String, dynamic>? hit;
                            if (val > 0) {
                              final m = _sucursalesCliente.where((s) => s['id'] == val);
                              if (m.isNotEmpty) hit = m.first;
                            } else {
                              final idx = (-val) - 1;
                              if (idx >= 0 && idx < _sucursalesCliente.length) {
                                hit = _sucursalesCliente[idx];
                              }
                            }
                            if (hit != null) {
                              setState(() {
                                _sucursalId = hit!['id'] as int?;
                                _sucursalCtrl.text = (hit['nombre'] ?? '').toString();
                                _direccionCtrl.text = (hit['direccion'] ?? hit['nombre'] ?? '').toString();
                                final cSuc = (hit['correo'] ?? '').toString().trim();
                                if (esCorreoClienteValido(cSuc)) {
                                  _correoCtrl.text = cSuc;
                                }
                              });
                              final hist = await LocalDbService.instance.getHistorialInstrumentos(
                                clienteId: _clienteId,
                                cliente: _clienteNombre,
                                sucursalId: _sucursalId,
                                sucursal: _sucursalCtrl.text.trim(),
                              );
                              if (mounted) setState(() => _historialInstrumentos = hist);
                            }
                          },
                        )
                      : TextFormField(
                          controller: _sucursalCtrl,
                          decoration: _inputDeco(context, hint: 'Sucursal o dirección de planta'),
                          onChanged: (v) {
                            if (_direccionCtrl.text.trim().isEmpty) {
                              _direccionCtrl.text = v;
                            }
                          },
                        ),
                ],
              ),

              // Técnico Asignado
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FieldLabel('Técnico Asignado *'),
                  const SizedBox(height: 5),
                  _CatalogDropdown(
                    hint: '— Selecciona técnico —',
                    items: _tecnicos,
                    labelKeys: const ['nombre', 'nombre_completo', 'username'],
                    idKey: 'id',
                    value: _tecnicoId,
                    onChanged: (v) => setState(() => _tecnicoId = v),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Fila 2: Tipo de Servicio, Fecha, Cantidad ────────────────────
          _ResponsiveGrid(
            columns: cols3,
            spacing: 12,
            runSpacing: 12,
            children: [
              if (_tipoDoc == 'OS')
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FieldLabel('Tipo de Servicio *'),
                    const SizedBox(height: 5),
                    _CatalogDropdown(
                      hint: '— Selecciona tipo de servicio —',
                      items: _tiposServ,
                      labelKeys: const ['nombre', 'descripcion'],
                      idKey: 'id',
                      value: _tipoServId,
                      onChanged: (v) {
                        setState(() {
                          _tipoServId = v;
                          final r = _activeRules;
                          for (final eq in _equipos) {
                            eq.limpiarRegulatorios(
                              allowCca: r.tieneCalibracion,
                              allowDve: r.tieneInspeccion,
                            );
                          }
                        });
                      },
                    ),
                  ],
                ),

              // Fecha
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FieldLabel('Fecha de Servicio *'),
                  const SizedBox(height: 5),
                  TextFormField(
                    controller: _fechaCtrl,
                    readOnly: true,
                    decoration: _inputDeco(
                      context,
                      hint: 'YYYY-MM-DD',
                      suffixIcon: Icon(Icons.calendar_today_outlined, size: 16, color: c.textSecondary),
                    ),
                    onTap: () async {
                      final init = DateTime.tryParse(_fechaCtrl.text) ?? DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: init,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2035),
                      );
                      if (picked != null && mounted) {
                        setState(() {
                          _fechaCtrl.text = picked.toIso8601String().split('T')[0];
                        });
                      }
                    },
                  ),
                ],
              ),

              // Cantidad (1..50)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FieldLabel('Cantidad de Formatos *'),
                  const SizedBox(height: 5),
                  _CompactIntStepper(
                    value: _cantidad,
                    min: 1,
                    max: 50,
                    suffix: _cantidad == 1 ? 'formato' : 'formatos',
                    onChanged: _ajustarCantidadEquipos,
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Correo del cliente + chips frecuentes ────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FieldLabel('Correo del Cliente (opcional — se arrastra al lote)'),
              const SizedBox(height: 5),
              TextFormField(
                controller: _correoCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: _inputDeco(
                  context,
                  hint: 'calidad@empresa.com',
                  suffixIcon: _correoCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () => setState(() => _correoCtrl.clear()),
                        )
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_correosFrecuentes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _correosFrecuentes.take(5).map((email) {
                    final sel = _correoCtrl.text.trim().toLowerCase() == email.toLowerCase();
                    return ChoiceChip(
                      label: Text(email, style: TextStyle(fontSize: 11.5, color: sel ? Colors.white : c.textPrimary)),
                      selected: sel,
                      showCheckmark: false,
                      selectedColor: _red,
                      backgroundColor: c.surfaceMuted,
                      side: BorderSide(color: sel ? _red : c.border),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (_) => setState(() => _correoCtrl.text = email),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Observaciones / Instrucciones ────────────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FieldLabel('Observaciones / Instrucciones Generales'),
              const SizedBox(height: 5),
              TextFormField(
                controller: _observCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: _inputDeco(
                  context,
                  hint: 'Ej: Se reemplaza el 1100a por otro tanque y se recalibran celdas de carga. Falla en celda N°3 — pendiente revisión.',
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Divider(height: 1, color: c.divider),
          const SizedBox(height: 12),

          // ── Subtítulo de Equipos ─────────────────────────────────────────
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Datos del Instrumento por Equipo  ',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                TextSpan(
                  text: '(todos los campos son opcionales — el técnico puede completarlos en campo)',
                  style: TextStyle(
                    fontSize: 12,
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // ── Tarjetas dinámicas Instrumento 1 .. N ────────────────────────
          for (int i = 0; i < _equipos.length; i++) ...[
            _buildInstrumentoCard(
              index: i,
              eq: _equipos[i],
              width: width,
              allowCca: allowCca,
              allowDve: allowDve,
            ),
            if (i < _equipos.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildInstrumentoCard({
    required int index,
    required _InstrumentoDraft eq,
    required double width,
    required bool allowCca,
    required bool allowDve,
  }) {
    final c = PesaColors.of(context);
    final int cols4 = width >= 840 ? 4 : (width >= 500 ? 2 : 1);
    final int cols3 = width >= 720 ? 3 : 1;
    final tiposList = _opcionesTipoInstrumento();
    final String safeTipoInst = tiposList.contains(eq.tipoInstNombre)
        ? eq.tipoInstNombre
        : tiposList.first;
    final String safeMotivo = _motivosNoAplica.contains(eq.motivoNoExcentricidad)
        ? eq.motivoNoExcentricidad
        : _motivosNoAplica.first;
    final String safeGeo = _geometriasOpciones.contains(eq.geometriaPuntos)
        ? eq.geometriaPuntos
        : _geometriasOpciones.first;

    return Container(
      key: ValueKey('instrumento_card_$index'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header de tarjeta Instrumento N
          InkWell(
            onTap: () => setState(() => eq.expanded = !eq.expanded),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: _red, shape: BoxShape.circle),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: 'Instrumento ${index + 1} ',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                        TextSpan(
                          text: '· (datos opcionales)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Icon(
                  eq.expanded ? Icons.remove_rounded : Icons.add_rounded,
                  size: 18,
                  color: c.textSecondary,
                ),
              ],
            ),
          ),

          if (eq.expanded) ...[
            const SizedBox(height: 12),

            // Fila 1: Marca, Modelo, N° de Serie, ID Indicador / Equipo
            _ResponsiveGrid(
              columns: cols4,
              spacing: 10,
              runSpacing: 10,
              children: [
                _LabeledAutoField(
                  label: 'Marca',
                  hint: 'Marca (ej: METTLER TOLEDO)',
                  controller: eq.marcaCtrl,
                  focusNode: eq.marcaFocus,
                  fieldKey: 'marca',
                  historial: _historialInstrumentos,
                  onSelectedInstrument: (inst) => _aplicarSugerenciaHistorial(eq, inst),
                ),
                _LabeledAutoField(
                  label: 'Modelo',
                  hint: 'Modelo (ej: IND560)',
                  controller: eq.modeloCtrl,
                  focusNode: eq.modeloFocus,
                  fieldKey: 'modelo',
                  historial: _historialInstrumentos,
                  onSelectedInstrument: (inst) => _aplicarSugerenciaHistorial(eq, inst),
                ),
                _LabeledAutoField(
                  label: 'N° de Serie',
                  hint: 'N° de Serie (ej: B215004321)',
                  controller: eq.serieCtrl,
                  focusNode: eq.serieFocus,
                  fieldKey: 'serie',
                  historial: _historialInstrumentos,
                  onSelectedInstrument: (inst) => _aplicarSugerenciaHistorial(eq, inst),
                ),
                _LabeledAutoField(
                  label: 'ID Indicador / Equipo',
                  hint: 'ID Indicador / Equipo (ej: Trailer A)',
                  controller: eq.idEquipoCtrl,
                  focusNode: eq.idEquipoFocus,
                  fieldKey: 'id_indicador',
                  historial: _historialInstrumentos,
                  onSelectedInstrument: (inst) => _aplicarSugerenciaHistorial(eq, inst),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Fila 2: Capacidad Máx., División Mín., Ubicación
            _ResponsiveGrid(
              columns: cols3,
              spacing: 10,
              runSpacing: 10,
              children: [
                _LabeledTextField(
                  label: 'Capacidad Máx.',
                  hint: 'Capacidad Máxima (ej: 500 kg)',
                  controller: eq.capacidadCtrl,
                ),
                _LabeledTextField(
                  label: 'División Mín.',
                  hint: 'División Mínima (ej: 50 g)',
                  controller: eq.divisionCtrl,
                ),
                _LabeledTextField(
                  label: 'Ubicación',
                  hint: 'Ubicación (ej: Planta Norte)',
                  controller: eq.ubicacionCtrl,
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Fila 3: Tipo de Instrumento (ancho completo)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _FieldLabel('Tipo de Instrumento'),
                const SizedBox(height: 5),
                DropdownButtonFormField<String>(
                  key: ValueKey('tipo_inst_$index'),
                  value: safeTipoInst,
                  isExpanded: true,
                  decoration: _inputDeco(context, hint: 'Seleccionar tipo de instrumento…'),
                  items: tiposList
                      .map((t) => DropdownMenuItem<String>(
                            value: t,
                            child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    int? tid;
                    for (final item in _tiposInst) {
                      if ((item['nombre'] ?? '').toString().trim() == v) {
                        tid = int.tryParse('${item['id']}');
                        break;
                      }
                    }
                    _aplicarReglaTipoInstrumento(eq, v, tid);
                  },
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Fila 4: Excentricidad / Exactitud / Geometría o Motivo No Aplica
            if (eq.aplicaExcentricidad)
              _ResponsiveGrid(
                columns: cols4,
                spacing: 10,
                runSpacing: 10,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('¿Aplica Excentricidad?'),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<bool>(
                        key: ValueKey('aplica_exc_$index'),
                        value: eq.aplicaExcentricidad,
                        isExpanded: true,
                        decoration: _inputDeco(context),
                        items: const [
                          DropdownMenuItem(value: true, child: Text('SÍ', style: TextStyle(fontSize: 13.5))),
                          DropdownMenuItem(value: false, child: Text('NO', style: TextStyle(fontSize: 13.5))),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            eq.aplicaExcentricidad = v;
                            if (v) eq.aplicaEnlacesSustitucion = false;
                          });
                        },
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Puntos / Filas Exc.'),
                      const SizedBox(height: 5),
                      _CompactIntStepper(
                        value: eq.puntosExcentricidad,
                        min: 1,
                        max: 20,
                        suffix: 'pos',
                        onChanged: (v) => setState(() => eq.puntosExcentricidad = v),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Pts. Exactitud'),
                      const SizedBox(height: 5),
                      _CompactIntStepper(
                        value: eq.puntosExactitud,
                        min: 1,
                        max: 20,
                        suffix: 'pts',
                        onChanged: (v) => setState(() => eq.puntosExactitud = v),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Geometría / Puntos'),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<String>(
                        key: ValueKey('geo_puntos_$index'),
                        value: safeGeo,
                        isExpanded: true,
                        decoration: _inputDeco(context),
                        items: _geometriasOpciones
                            .map((g) => DropdownMenuItem<String>(
                                  value: g,
                                  child: Text(g, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => eq.geometriaPuntos = v);
                        },
                      ),
                    ],
                  ),
                ],
              )
            else ...[
              _ResponsiveGrid(
                columns: cols3,
                spacing: 10,
                runSpacing: 10,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('¿Aplica Excentricidad?'),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<bool>(
                        key: ValueKey('aplica_exc_$index'),
                        value: eq.aplicaExcentricidad,
                        isExpanded: true,
                        decoration: _inputDeco(context),
                        items: const [
                          DropdownMenuItem(value: true, child: Text('SÍ', style: TextStyle(fontSize: 13.5))),
                          DropdownMenuItem(value: false, child: Text('NO', style: TextStyle(fontSize: 13.5))),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            eq.aplicaExcentricidad = v;
                            if (v) eq.aplicaEnlacesSustitucion = false;
                          });
                        },
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Pts. Exactitud'),
                      const SizedBox(height: 5),
                      _CompactIntStepper(
                        value: eq.puntosExactitud,
                        min: 1,
                        max: 20,
                        suffix: 'pts',
                        onChanged: (v) => setState(() => eq.puntosExactitud = v),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Motivo No Aplica'),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<String>(
                        key: ValueKey('motivo_no_$index'),
                        value: safeMotivo,
                        isExpanded: true,
                        decoration: _inputDeco(context),
                        items: _motivosNoAplica
                            .map((m) => DropdownMenuItem<String>(
                                  value: m,
                                  child: Text(m, style: const TextStyle(fontSize: 13.5)),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            eq.motivoNoExcentricidad = v;
                          });
                        },
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // ── Bloque Calibración por Enlaces de Sustitución — NOM-010-SCFI / OIML R 76 ──
              Container(
                key: ValueKey('enlaces_sustitucion_card_$index'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Calibración por Enlaces de Sustitución  —  NOM-010-SCFI / OIML R 76',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ResponsiveGrid(
                      columns: cols3,
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _FieldLabel('¿Aplica Enlaces de Sustitución?'),
                            const SizedBox(height: 5),
                            DropdownButtonFormField<bool>(
                              key: ValueKey('aplica_enlaces_$index'),
                              value: eq.aplicaEnlacesSustitucion,
                              isExpanded: true,
                              decoration: _inputDeco(context),
                              items: const [
                                DropdownMenuItem(value: true, child: Text('SÍ', style: TextStyle(fontSize: 13.5))),
                                DropdownMenuItem(value: false, child: Text('NO', style: TextStyle(fontSize: 13.5))),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => eq.aplicaEnlacesSustitucion = v);
                              },
                            ),
                          ],
                        ),
                        if (eq.aplicaEnlacesSustitucion)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _FieldLabel('¿Cuántos Enlaces son?'),
                              const SizedBox(height: 5),
                              _CompactIntStepper(
                                key: ValueKey('cantidad_enlaces_$index'),
                                value: eq.cantidadEnlaces,
                                min: 1,
                                max: 10,
                                suffix: 'enlaces',
                                onChanged: (v) => setState(() => eq.cantidadEnlaces = v),
                              ),
                            ],
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              'La carga de pesa patrón la determina el técnico en campo — no se fija aquí.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.textSecondary,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            // Secciones Camionera (si aplicaExcentricidad && geometria == Camionera)
            if (eq.aplicaExcentricidad && eq.geometriaPuntos == 'Camionera') ...[
              const SizedBox(height: 10),
              SizedBox(
                width: width >= 500 ? 220 : double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FieldLabel('Número de Secciones (Camionera)'),
                    const SizedBox(height: 5),
                    _CompactIntStepper(
                      value: eq.numSecciones,
                      min: 2,
                      max: 12,
                      suffix: 'secc.',
                      onChanged: (v) => setState(() => eq.numSecciones = v),
                    ),
                  ],
                ),
              ),
            ],

            // Campos regulatorios condicionales: Calibración (CCA + Inicial)
            if (allowCca) ...[
              const SizedBox(height: 10),
              _ResponsiveGrid(
                columns: width >= 560 ? 2 : 1,
                spacing: 10,
                runSpacing: 10,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Inicial Calibrador'),
                      const SizedBox(height: 5),
                      DropdownButtonFormField<String>(
                        value: eq.inicialCalibrador,
                        isExpanded: true,
                        decoration: _inputDeco(context),
                        items: const ['Ninguna', 'J', 'I', 'A']
                            .map((ini) => DropdownMenuItem(value: ini, child: Text(ini, style: const TextStyle(fontSize: 13.5))))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => eq.inicialCalibrador = v);
                        },
                      ),
                    ],
                  ),
                  _LabeledTextField(
                    label: 'Número CCA',
                    hint: 'Ej: CCA.26.02163',
                    controller: eq.ccaCtrl,
                  ),
                ],
              ),
            ],

            // Campos regulatorios condicionales: Inspección (DVE + Hologramas — EXCLUSIVO Inspección)
            if (allowDve) ...[
              const SizedBox(height: 10),
              _ResponsiveGrid(
                columns: cols4,
                spacing: 10,
                runSpacing: 10,
                children: [
                  _LabeledTextField(
                    label: 'Div. Verificación (DVE)',
                    hint: 'Ej: 50 g',
                    controller: eq.dveDivCtrl,
                  ),
                  _LabeledTextField(
                    label: 'Número DVE',
                    hint: 'Ej: DVE.26.00412',
                    controller: eq.dveNumCtrl,
                  ),
                  _LabeledTextField(
                    label: 'Holograma Anterior',
                    hint: 'Ej: 2025-XXXX',
                    controller: eq.holoAntCtrl,
                  ),
                  _LabeledTextField(
                    label: 'Holograma Actualizado',
                    hint: 'Ej: 2026-XXXX',
                    controller: eq.holoActCtrl,
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildStep4ConfirmarFolios(double width) {
    final c = PesaColors.of(context);
    final rango = _calcularRangoPreview();
    return _buildStepCard(
      stepNumber: 4,
      title: 'Confirmar Folios y Ejecutar',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Folio Inicial (Consecutivo) *',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              SizedBox(
                width: width < 480 ? double.infinity : 220,
                child: TextFormField(
                  key: const Key('folio_inicial_input'),
                  controller: _folioInicialCtrl,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  decoration: _inputDeco(
                    context,
                    hint: _loadingFolio ? 'Consultando…' : 'Ej: OS-26-863',
                    suffixIcon: _loadingFolio
                        ? const Padding(
                            padding: EdgeInsets.all(11),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _red),
                            ),
                          )
                        : IconButton(
                            tooltip: 'Consultar consecutivo en vivo',
                            icon: Icon(Icons.refresh_rounded, size: 17, color: c.textSecondary),
                            onPressed: () => _cargarSiguienteFolio(_tipoDoc),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (_folioOrigen.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _folioOrigen.contains('vivo') ? c.dotGreen : c.dotAmber,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _folioOrigen,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (rango != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Text(
                'Rango de folios a reservar: $rango',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStickyFooter(bool cover) {
    final c = PesaColors.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(cover ? 12 : 20, 10, cover ? 12 : 20, 10 + MediaQuery.of(context).viewPadding.bottom),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: c.textPrimary,
              side: BorderSide(color: c.border),
              backgroundColor: c.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _loading ? null : _reiniciarFormulario,
            child: const Text('Reiniciar', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          if (!cover) ...[
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                _loading
                    ? 'Reservando folios y sincronizando…'
                    : 'Listo para generar y asignar folios.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.dotGreen,
                ),
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: 10),
          Flexible(
            flex: cover ? 2 : 0,
            child: ElevatedButton(
              key: const Key('submit_nuevo_doc_btn'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _loading ? c.textTertiary : _red,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: cover ? 14 : 22, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _loading ? null : _submit,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading) ...[
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      _ctaLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers UI corporativos minimalistas ────────────────────────────────────

InputDecoration _inputDeco(BuildContext context, {String? hint, Widget? suffixIcon}) {
  final c = PesaColors.of(context);
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: c.textTertiary),
    suffixIcon: suffixIcon,
    isDense: true,
    filled: true,
    fillColor: c.isDark ? c.surfaceElevated : c.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.brandAccent, width: 1.6),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: c.textSecondary,
      ),
    );
  }
}

class _LabeledTextField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;

  const _LabeledTextField({
    required this.label,
    required this.hint,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 5),
        TextFormField(
          controller: controller,
          style: TextStyle(fontSize: 13.5, color: c.textPrimary),
          decoration: _inputDeco(context, hint: hint),
        ),
      ],
    );
  }
}

class _LabeledAutoField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String fieldKey;
  final List<Map<String, dynamic>> historial;
  final ValueChanged<Map<String, dynamic>> onSelectedInstrument;

  const _LabeledAutoField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.fieldKey,
    required this.historial,
    required this.onSelectedInstrument,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 5),
        RawAutocomplete<Map<String, dynamic>>(
          textEditingController: controller,
          focusNode: focusNode,
          displayStringForOption: (opt) => (opt[fieldKey] ?? '').toString(),
          optionsBuilder: (TextEditingValue tev) {
            if (historial.isEmpty) return const Iterable<Map<String, dynamic>>.empty();
            final q = LocalDbService.normalizarTexto(tev.text);
            return historial.where((inst) {
              final valField = (inst[fieldKey] ?? '').toString().trim();
              if (valField.isEmpty) return false;
              if (q.isEmpty) return (inst['_prio'] as int? ?? 3) <= 1;
              final blob = LocalDbService.normalizarTexto(
                '${inst['marca']} ${inst['modelo']} ${inst['serie']} ${inst['id_indicador']} ${inst['ubicacion']}',
              );
              return blob.contains(q);
            }).take(14);
          },
          onSelected: onSelectedInstrument,
          fieldViewBuilder: (ctx, textCtrl, fNode, onSubmit) {
            return TextFormField(
              controller: textCtrl,
              focusNode: fNode,
              style: TextStyle(fontSize: 13.5, color: c.textPrimary),
              decoration: _inputDeco(ctx, hint: hint),
            );
          },
          optionsViewBuilder: (ctx, onSelected, options) {
            final oc = PesaColors.of(ctx);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(10),
                color: oc.surface,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220, maxWidth: 360),
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: oc.divider),
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
                        if ((opt['capacidad_maxima'] ?? '').toString().isNotEmpty) 'Cap: ${opt['capacidad_maxima']}',
                      ].join(' · ');
                      return ListTile(
                        dense: true,
                        title: Text(titulo, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: oc.textPrimary)),
                        subtitle: sub.isNotEmpty
                            ? Text(sub, style: TextStyle(fontSize: 11, color: oc.textSecondary))
                            : null,
                        onTap: () => onSelected(opt),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CompactIntStepper extends StatelessWidget {
  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int> onChanged;

  const _CompactIntStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: c.isDark ? c.surfaceElevated : c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 38),
            icon: const Icon(Icons.remove_rounded, size: 17),
            color: value > min ? c.textPrimary : c.textTertiary,
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          Expanded(
            child: Text(
              '$value $suffix',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 38),
            icon: const Icon(Icons.add_rounded, size: 17),
            color: value < max ? c.textPrimary : c.textTertiary,
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _SelectableOptionCard extends StatelessWidget {
  final String badge;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SelectableOptionCard({
    required this.badge,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? c.surfaceMuted : c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? c.brandAccent : c.border,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected ? c.brand : c.surfaceMuted,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: selected ? c.brand : c.border),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : c.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected ? c.brandAccent : c.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: c.textSecondary,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponsiveGrid extends StatelessWidget {
  final int columns;
  final double spacing;
  final double runSpacing;
  final List<Widget> children;

  const _ResponsiveGrid({
    required this.columns,
    required this.spacing,
    required this.runSpacing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (columns <= 1 || children.length <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) SizedBox(height: runSpacing),
          ],
        ],
      );
    }

    final rows = <Widget>[];
    for (int i = 0; i < children.length; i += columns) {
      final rowChildren = <Widget>[];
      for (int c = 0; c < columns; c++) {
        final idx = i + c;
        if (c > 0) rowChildren.add(SizedBox(width: spacing));
        rowChildren.add(
          Expanded(
            child: idx < children.length ? children[idx] : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rowChildren,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _CatalogDropdown extends StatelessWidget {
  final String hint;
  final List<Map<String, dynamic>> items;
  final List<String> labelKeys;
  final String idKey;
  final int? value;
  final ValueChanged<int?> onChanged;

  const _CatalogDropdown({
    required this.hint,
    required this.items,
    required this.labelKeys,
    required this.idKey,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final validIds = items.map((e) => int.tryParse('${e[idKey] ?? ''}')).whereType<int>().toSet();
    final safeValue = (value != null && validIds.contains(value)) ? value : null;

    return DropdownButtonFormField<int>(
      value: safeValue,
      isExpanded: true,
      hint: Text(
        hint,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: c.textTertiary),
      ),
      decoration: _inputDeco(context),
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
            style: const TextStyle(fontSize: 13.5),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}

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
    final c = PesaColors.of(context);
    final qNorm = LocalDbService.normalizarTexto(_query);
    final filtered = _query.trim().isEmpty
        ? widget.clientes
        : widget.clientes.where((cli) {
            final nom = LocalDbService.normalizarTexto(
              (cli['nombre'] ?? cli['razon_social'] ?? '').toString(),
            );
            final rfc = LocalDbService.normalizarTexto((cli['rfc'] ?? '').toString());
            final dir = LocalDbService.normalizarTexto((cli['direccion'] ?? '').toString());
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
              Icon(Icons.business_rounded, color: c.brandAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Seleccionar Cliente (${filtered.length})',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: c.textPrimary),
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
                fillColor: c.surfaceMuted,
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
                  ? Center(
                      child: Text(
                        'Sin coincidencias en el catálogo de clientes',
                        style: TextStyle(color: c.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollCtrl,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: c.divider),
                      itemBuilder: (ctx, i) {
                        final cli = filtered[i];
                        final nom = (cli['nombre'] ?? cli['razon_social'] ?? '').toString();
                        final rfc = (cli['rfc'] ?? '').toString().trim();
                        final sucs = (cli['sucursales'] as List?) ?? const [];
                        final dir = (cli['direccion'] ?? '').toString().trim();
                        return ListTile(
                          dense: true,
                          title: Text(
                            nom,
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: c.textPrimary),
                          ),
                          subtitle: Text(
                            [
                              if (rfc.isNotEmpty) 'RFC: $rfc',
                              if (sucs.isNotEmpty) '${sucs.length} planta(s)/dirección(es)',
                              if (dir.isNotEmpty) dir,
                            ].join(' • '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                          ),
                          trailing: Icon(Icons.chevron_right, size: 18, color: c.textSecondary),
                          onTap: () => Navigator.pop(ctx, cli),
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
