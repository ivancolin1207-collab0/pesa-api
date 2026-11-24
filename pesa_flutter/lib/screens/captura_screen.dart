// lib/screens/captura_screen.dart — Captura metrológica digital interactiva
// v4.0: Lógica condicional estricta NOM-010-SCFI-2020 (lookup dual ID+nombre)
//       DVE dentro de sección Inspección · Precarga completa desde OS backend
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../services/metrology_helper.dart';
import '../theme/pesa_theme.dart';
import '../widgets/pesa_components.dart';
import '../widgets/repetibilidad_table.dart';
import '../widgets/excentricidad_table.dart';
import '../widgets/exactitud_table.dart';
import '../widgets/enlaces_sustitucion_table.dart';
import '../widgets/nombre_recibe.dart';
import '../widgets/sync_check_badge.dart';
import 'remision_captura_screen.dart';
import 'revision_bascula_screen.dart';
import 'levantamiento_proyecto_screen.dart';
import 'levantamiento_metrologico_screen.dart';
import 'observaciones_bascula_screen.dart';
import 'observaciones_celda_screen.dart';

class CalibracionAjusteScreen extends StatelessWidget {
  final Map<String, dynamic> orden;
  const CalibracionAjusteScreen({super.key, required this.orden});

  @override
  Widget build(BuildContext context) {
    final String folioUpper = (orden['folio'] ?? orden['folio_os'] ?? orden['folio_rma'] ?? '').toString().trim().toUpperCase();
    final String tipoDocUpper = (orden['tipo_documento'] ?? '').toString().trim().toUpperCase();
    final String tipoUpper = (orden['tipo_servicio'] ?? '').toString().trim().toUpperCase();

    if (folioUpper.startsWith('OSOCC-') ||
        tipoDocUpper == 'OSOCC' ||
        tipoUpper.contains('OSOCC') ||
        tipoUpper.contains('OBSERVACIONES CELDA') ||
        (tipoUpper.contains('DIAGNOSTICO') && tipoUpper.contains('CELDA')) ||
        (tipoUpper.contains('DIAGNÓSTICO') && tipoUpper.contains('CELDA'))) {
      return ObservacionesCeldaScreen(orden: orden);
    }
    if (folioUpper.startsWith('OSOB-') ||
        tipoDocUpper == 'OSOB' ||
        tipoUpper.contains('OSOB') ||
        tipoUpper.contains('OBSERVACION') ||
        (!folioUpper.startsWith('OS-') &&
            !folioUpper.startsWith('RMA-') &&
            !folioUpper.startsWith('RE-') &&
            (tipoUpper.contains('INSPECCION') || tipoUpper.contains('INSPECCIÓN')))) {
      return ObservacionesBasculaScreen(orden: orden);
    }
    final osId = orden['local_id'] as int? ?? 0;
    return CapturaScreen(osId: osId, osData: orden);
  }
}

// ── Constantes de estilo ───────────────────────────────────────────────────
const _kRed  = Color(0xFFC8102E);
const _kDark = Color(0xFF1A1A2E);

// Tipos de instrumento que metrológicamente aplican excentricidad.
const _kExcInstrumentos = {
  'Báscula de plataforma',
  'Báscula camionera',
  'Báscula de ferrocarril',
  'Báscula tolva',
  'Báscula circular',
};

class CapturaScreen extends StatefulWidget {
  final int osId;
  final Map<String, dynamic> osData;
  const CapturaScreen({super.key, required this.osId, required this.osData});

  @override
  State<CapturaScreen> createState() => _CapturaScreenState();
}

class _CapturaScreenState extends State<CapturaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  Map<String, dynamic> _os = {};

  // ── Reglas metrológicas (formato/folio → nombre → ID) ─────────────────────────
  static int? _intOrNull(dynamic v) =>
      v is int ? v : int.tryParse(v?.toString() ?? '');

  ServiceRules get _rules => getRules(
    id: _intOrNull(_os['id_tipo_servicio']) ?? _intOrNull(_os['tipo_servicio_id']),
    nombre: _os['tipo_servicio']?.toString(),
    folio: (_os['folio_os'] ?? widget.osData['folio_os'])?.toString(),
  );

  /// CCA (+ Inicial J/I/A) solo si el tipo contiene "Calibración" o "CCA".
  bool get _aplicaCCA => _rules.tieneCalibracion;
  /// DVE + Hologramas solo si el tipo contiene "DVE", "Inspección" o "Verificación".
  bool get _aplicaDVE => _rules.tieneInspeccion;

  String get _anioDosDigitos => (DateTime.now().year % 100).toString().padLeft(2, '0');
  String get _prefijoCca => "CCA.$_anioDosDigitos.";
  String get _prefijoDve => "DVE.$_anioDosDigitos.";
  String get _prefijoActivo {
    final bool esDve = (!_rules.tieneCalibracion && _rules.tieneInspeccion) ||
        (_os['tipo_servicio']?.toString().toLowerCase().contains('dve') ?? false);
    return esDve ? _prefijoDve : _prefijoCca;
  }

  // Valores efectivos: CCA y DVE son números regulatorios independientes;
  // si cualquiera fue capturado se conserva en SQLite, servidor y PDF.
  String get _ccaEf       => limpiarNumeroRegulatorio(_ccaCtrl.text);
  String get _numeroDveEf => limpiarNumeroRegulatorio(_numeroDveCtrl.text);
  bool   get _jEf         => (_aplicaCCA || _ccaEf.isNotEmpty) && _jChecked;
  bool   get _iEf         => (_aplicaCCA || _ccaEf.isNotEmpty) && _iChecked;
  bool   get _aEf         => (_aplicaCCA || _ccaEf.isNotEmpty) && _aChecked;
  String get _dveEf       => _aplicaDVE ? _divVerCtrl.text.trim() : '';
  String get _holoAntEf   => (_aplicaDVE || _numeroDveEf.isNotEmpty) ? _holoAntCtrl.text.trim() : '';
  String get _holoActEf   => (_aplicaDVE || _numeroDveEf.isNotEmpty) ? _holoActCtrl.text.trim() : '';

  /// Carga de sustitución OPCIONAL: solo aplica si el técnico eligió "Sí"
  /// y capturó un valor > 0. Vacío / 0 / "No" ⇒ aplica_sustitucion = false.
  double? get _pesoSustituto {
    final v = double.tryParse(_masaPatronCtrl.text.trim().replaceAll(',', '.'));
    return (v != null && v > 0) ? v : null;
  }
  double? get _factorSustituto {
    final v = double.tryParse(_factorSustCtrl.text.trim().replaceAll(',', '.'));
    return (v != null && v > 0) ? v : null;
  }
  bool get _hasValidSustitutos {
    for (final s in _sustitutosRows) {
      final p = double.tryParse((s['peso'] ?? '').toString().replaceAll(',', '.').replaceAll(' ', ''));
      if (p != null && p > 0) return true;
    }
    return false;
  }
  bool get _aplicaSustitucion =>
      _usaSustitucion && (_hasValidSustitutos || _pesoSustituto != null || _factorSustituto != null);

  // ── Controladores Paso 0 — Instrumento ───────────────────────────────────
  final _marcaCtrl      = TextEditingController();
  final _modeloCtrl     = TextEditingController();
  final _marcaFocusNode    = FocusNode();
  final _modeloFocusNode   = FocusNode();
  final _nsFocusNode       = FocusNode();
  final _idEquipoFocusNode = FocusNode();
  List<String> _marcasSugeridas  = [];
  List<String> _modelosSugeridos = [];
  List<Map<String, dynamic>> _historialInstrumentos = [];
  bool _savingParcial = false;
  final _nsCtrl         = TextEditingController();
  final _idEquipoCtrl   = TextEditingController();
  final _capMaxCtrl     = TextEditingController();
  final _divMinCtrl     = TextEditingController();
  final _divVerCtrl     = TextEditingController(); // Div. Verificación (e) en kg
  final _ubicCtrl       = TextEditingController();
  final _ccaCtrl        = TextEditingController(); // Número CCA independiente (ej. CCA.26.02163)
  final _numeroDveCtrl  = TextEditingController(); // Número DVE independiente (ej. DVE.26.00412)
  final _holoAntCtrl    = TextEditingController();
  final _holoActCtrl    = TextEditingController();
  final _masaPatronCtrl = TextEditingController();
  final _factorSustCtrl = TextEditingController();

  String? _tipoInstrumento;
  String  _funcionamiento = 'Electrónico'; // nuevo campo
  int     _puntosApoyo    = 4;               // nuevo campo
  String  _unidadMedida   = 'kg';            // selector 'kg' o 'g'
  String  _geometriaExcentricidad = 'Plataforma'; // Plataforma | Circular | Camionera
  int     _numSeccionesExc = 4;              // para Camionera (3, 4, 5, 6...)
  bool    _jChecked = false, _iChecked = false, _aChecked = false;
  bool    _usaSustitucion = false;
  bool?   _aplExcOverride;  // null = auto-determinar por instrumento
  String  _motivoNoExcentricidad = 'Tolva'; // Grúa | Patín | Tanque | Tolva | Silo

  // ── Lecturas de medición ─────────────────────────────────────────────────
  List<Map<String, dynamic>> _repRows  = [];
  List<Map<String, dynamic>> _excRows  = [];
  List<Map<String, dynamic>> _exacRows = [];
  List<Map<String, dynamic>> _sustitutosRows = [];
  final _obsCtrl                = TextEditingController();
  final _obsFocusNode           = FocusNode();
  final _firmaClienteNombreCtrl = TextEditingController();  // nombre cliente — obligatorio
  final _firmaClienteFocusNode  = FocusNode();
  List<String> _contactosSugeridos = [];
  double? _cargaRepAutoCalculada;
  double? _cargaExcAutoCalculada;
  String _dictamen = 'APTO';
  bool   _saving   = false;
  bool   _permitirSalida = false;
  bool   _dataLoaded = false;
  int    _dataVersion = 0;
  bool   _mostrarErroresInstrumento = false;

  static const _tiposInstrumento = [
    'Báscula de plataforma',
    'Báscula camionera',
    'Báscula de ferrocarril',
    'Báscula tolva',
    'Báscula colgante / grúa',
    'Patín hidráulico',
    'Báscula tipo tanque',
    'Báscula tipo silo',
    'Báscula analítica',
    'Báscula de piso',
    'Báscula de mostrador',
    'Báscula circular',
    'Pesa patrón',
    'Tanque / Silo',
    'Otro',
  ];

  // ──────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _os = Map<String, dynamic>.from(widget.osData);
    _divMinCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _precargaCampos();
    _normalizarTipoServicio(); // garantiza que id_tipo_servicio nunca quede null si hay nombre
    _loadLocalData();
    _cargarMarcasModelos();
  }

  Future<void> _cargarMarcasModelos() async {
    try {
      final marcas = await LocalDbService.instance.getMarcas();
      final modelos = await LocalDbService.instance.getModelos(marca: _marcaCtrl.text.trim());
      final hist = await LocalDbService.instance.getHistorialInstrumentos(
        clienteId: _intOrNull(_os['id_cliente']),
        cliente: (_os['cliente'] ?? _os['cliente_nombre'])?.toString(),
        sucursalId: _intOrNull(_os['sucursal_id']),
        sucursal: (_os['sucursal'] ?? _os['direccion'])?.toString(),
      );
      if (mounted) {
        setState(() {
          _marcasSugeridas = marcas;
          _modelosSugeridos = modelos;
          _historialInstrumentos = hist;
        });
      }
    } catch (e) {
      debugPrint('[Captura] Error cargando marcas/modelos/historial sugeridos: $e');
    }
  }

  void _aplicarInstrumentoDelHistorial(Map<String, dynamic> inst) {
    setState(() {
      final m = (inst['marca'] ?? '').toString().trim();
      final mod = (inst['modelo'] ?? '').toString().trim();
      final ser = (inst['serie'] ?? inst['ns'] ?? '').toString().trim();
      final idEq = (inst['id_indicador'] ?? inst['id_equipo'] ?? '').toString().trim();
      final cap = (inst['capacidad_maxima'] ?? '').toString().replaceAll(RegExp(r'[^0-9.]'), '').trim();
      final div = formatearDivisionMinima(inst['division_minima']).replaceAll(RegExp(r'[^0-9.]'), '').trim();
      final ubic = (inst['ubicacion'] ?? '').toString().trim();
      final tInst = _normalizarNombreTipoInstrumento(inst['tipo_instrumento']?.toString());

      if (m.isNotEmpty) {
        _marcaCtrl.text = m;
        _os['marca'] = m;
      }
      if (mod.isNotEmpty) {
        _modeloCtrl.text = mod;
        _os['modelo'] = mod;
      }
      if (ser.isNotEmpty) {
        _nsCtrl.text = ser;
        _os['ns'] = ser;
      }
      if (idEq.isNotEmpty) {
        _idEquipoCtrl.text = idEq;
        _os['id_equipo'] = idEq;
      }
      if (cap.isNotEmpty) {
        _capMaxCtrl.text = cap;
      }
      if (div.isNotEmpty) {
        _divMinCtrl.text = div;
      }
      if (ubic.isNotEmpty) {
        _ubicCtrl.text = ubic;
        _os['ubicacion'] = ubic;
      }
      if (tInst != null && tInst.isNotEmpty) {
        _tipoInstrumento = tInst;
        _os['tipo_instrumento'] = tInst;
        _aplicarParametrosPostTipoInstrumento();
      }
      _actualizarCargasSugeridas(force: false);
    });
    if (_marcaCtrl.text.trim().isNotEmpty) {
      _actualizarModelosParaMarca(_marcaCtrl.text.trim());
    }
  }

  Future<void> _guardarEquipoSinFinalizar() async {
    if (_savingParcial) return;
    _guardarDatosInstrumento();
    final folio = (_os['folio_os'] ?? widget.osData['folio_os'] ?? widget.osId.toString()).toString().trim();
    if (folio.isEmpty) return;

    setState(() => _savingParcial = true);
    try {
      final divNorm = formatearDivisionMinima(_divMinCtrl.text.trim());
      final payloadParcial = <String, dynamic>{
        'marca': _marcaCtrl.text.trim(),
        'modelo': _modeloCtrl.text.trim(),
        'serie': _nsCtrl.text.trim(),
        'ns': _nsCtrl.text.trim(),
        'id_indicador': _idEquipoCtrl.text.trim(),
        'id_equipo': _idEquipoCtrl.text.trim(),
        'capacidad_maxima': _capMaxCtrl.text.trim(),
        'division_minima': divNorm,
        'ubicacion': _ubicCtrl.text.trim(),
        'tipo_instrumento': _tipoInstrumento ?? '',
        'numero_cca': _ccaEf,
        'numero_dve': _numeroDveEf,
        'aplica_excentricidad': _aplExc,
        'motivo_no_excentricidad': _aplExc ? '' : _motivoNoExcentricidad,
      };

      await _guardarBorrador(mostrarSnackbar: false);
      bool onlineOk = false;
      if (mounted) {
        onlineOk = await context.read<SyncService>().guardarYSincronizarInstrumentoParcial(
              folio,
              payloadParcial,
              localId: widget.osId,
            );
      } else {
        await LocalDbService.instance.guardarInstrumentoParcialLocal(
          folio,
          payloadParcial,
          localId: widget.osId,
          encolarSync: true,
        );
      }
      await _cargarMarcasModelos();

      if (mounted) {
        final etiq = construirEtiquetaInstrumento({
          'folio_os': folio,
          ...payloadParcial,
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: onlineOk ? const Color(0xFF15803D) : const Color(0xFF1D4ED8),
            duration: const Duration(seconds: 3),
            content: Text(
              onlineOk
                  ? 'Equipo guardado y sincronizado (orden sigue En Proceso): $etiq'
                  : 'Equipo guardado localmente (se sincronizará al conectar): $etiq',
            ),
          ),
        );
      }
    } catch (e) {
      _showError('No se pudo guardar temporalmente el equipo: $e');
    } finally {
      if (mounted) setState(() => _savingParcial = false);
    }
  }

  /// Diagnóstico del tipo de servicio. Ya NO reescribe `id_tipo_servicio`:
  /// la numeración local no debe viajar al servidor y el nombre/folio tienen
  /// prioridad sobre el ID (hay IDs inconsistentes en PostgreSQL).
  void _normalizarTipoServicio() {
    final r = _rules;
    debugPrint('[Captura] TipoServicio → folio=${_os['folio_os']}  '
        'nombre="${_os['tipo_servicio'] ?? ''}"  id=${_os['id_tipo_servicio']}  '
        '→ formato=${r.formato.name}  CCA=${r.tieneCalibracion}  DVE=${r.tieneInspeccion}');
  }

  Future<void> _actualizarModelosParaMarca(String marca) async {
    try {
      final modelos = await LocalDbService.instance.getModelos(marca: marca.trim());
      if (mounted) {
        setState(() {
          _modelosSugeridos = modelos;
        });
      }
    } catch (e) {
      debugPrint('[Captura] Error actualizando modelos sugeridos: $e');
    }
  }

  /// Precarga TODOS los campos del instrumento con datos que ya vienen
  /// asignados desde Logística / Backend al crear la OS.
  void _precargaCampos() {
    _marcaCtrl.text      = _str('marca');
    _modeloCtrl.text     = _str('modelo');
    // ns / serie: varios alias posibles
    _nsCtrl.text         = _str('ns').isNotEmpty ? _str('ns') : _str('serie');
    _idEquipoCtrl.text   = _str('id_equipo').isNotEmpty ? _str('id_equipo') : _str('id_indicador');
    _ubicCtrl.text       = _str('ubicacion');

    final rawCca = extraerNumeroCca(_os);
    if (rawCca.isNotEmpty) {
      _ccaCtrl.text = rawCca;
    } else if (_aplicaCCA) {
      _ccaCtrl.text = _prefijoCca;
    } else {
      _ccaCtrl.text = '';
    }
    _ccaCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _ccaCtrl.text.length));

    final rawNumDve = extraerNumeroDve(_os);
    if (rawNumDve.isNotEmpty) {
      _numeroDveCtrl.text = rawNumDve;
    } else if (_aplicaDVE && !_aplicaCCA) {
      _numeroDveCtrl.text = _prefijoDve;
    } else {
      _numeroDveCtrl.text = '';
    }
    _numeroDveCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _numeroDveCtrl.text.length));

    _holoAntCtrl.text    = _str('holograma_anterior');
    _holoActCtrl.text    = _str('holograma_actualizado');

    // Capacidad máxima, división mínima y tipo de instrumento prellenados desde logística
    dynamic dj;
    if (_os['datos_tecnicos_json'] != null) {
      try {
        dj = _os['datos_tecnicos_json'] is String
            ? jsonDecode(_os['datos_tecnicos_json'])
            : _os['datos_tecnicos_json'];
      } catch (_) {}
    }

    final max = _os['capacidad_maxima'] ?? _os['alcance_max'] ?? _os['capacidad_max'] ?? _os['cap_max'] ??
                (dj is Map ? (dj['capacidad_maxima'] ?? dj['alcance_max'] ?? dj['capacidad_max']) : null);
    final div = _os['division_minima']  ?? _os['div_minima'] ?? _os['division'] ?? _os['div_min'] ??
                (dj is Map ? (dj['division_minima'] ?? dj['div_minima'] ?? dj['division']) : null);
    final dve = _os['div_verificacion'] ?? (dj is Map ? dj['div_verificacion'] : null);

    if (max != null && max.toString().trim().isNotEmpty) {
      final s = max.toString().replaceAll(RegExp(r'[^0-9.]'), '').trim();
      _capMaxCtrl.text = s;
    } else {
      final capStr = _str('instrumento_capacidad');
      _capMaxCtrl.text = capStr.isNotEmpty
          ? capStr.replaceAll(RegExp(r'[^0-9.]'), '').trim()
          : '';
    }

    if (div != null && div.toString().trim().isNotEmpty) {
      final s = formatearDivisionMinima(div).replaceAll(RegExp(r'[^0-9.]'), '').trim();
      _divMinCtrl.text = s;
    } else {
      final divStr = _str('instrumento_division');
      _divMinCtrl.text = divStr.isNotEmpty
          ? formatearDivisionMinima(divStr).replaceAll(RegExp(r'[^0-9.]'), '').trim()
          : '';
    }
    _divVerCtrl.text = dve != null ? dve.toString() : '';

    // Tipo de instrumento prellenado desde logística (o null si viene vacío para captura manual)
    final tiRaw = _str('tipo_instrumento').isNotEmpty
        ? _str('tipo_instrumento')
        : (_str('tipo_bascula').isNotEmpty
            ? _str('tipo_bascula')
            : (dj is Map ? (dj['tipo_instrumento'] ?? dj['tipo_bascula'])?.toString() : ''));

    _tipoInstrumento = _normalizarNombreTipoInstrumento(tiRaw);
    _aplicarParametrosPostTipoInstrumento();
  }

  String? _normalizarNombreTipoInstrumento(String? tiRaw) {
    if (tiRaw == null || tiRaw.trim().isEmpty) return null;
    final ti = tiRaw.trim();
    if (_tiposInstrumento.contains(ti)) return ti;
    final tiLower = ti.toLowerCase();
    for (final item in _tiposInstrumento) {
      if (item.toLowerCase() == tiLower) return item;
    }
    if (tiLower.contains('tanque') && tiLower.contains('silo')) {
      return 'Tanque / Silo';
    } else if (tiLower.contains('silo')) {
      return 'Báscula tipo silo';
    } else if (tiLower.contains('tanque')) {
      return 'Báscula tipo tanque';
    } else if (tiLower.contains('patin') || tiLower.contains('patín') || tiLower.contains('transpaleta')) {
      return 'Patín hidráulico';
    } else if (tiLower.contains('camion') || tiLower.contains('puente')) {
      return 'Báscula camionera';
    } else if (tiLower.contains('ferrocarril') || tiLower.contains('ferrovi')) {
      return 'Báscula de ferrocarril';
    } else if (tiLower.contains('plataforma')) {
      return 'Báscula de plataforma';
    } else if (tiLower.contains('circular')) {
      return 'Báscula circular';
    } else if (tiLower.contains('tolva')) {
      return 'Báscula tolva';
    } else if (tiLower.contains('colgante') || tiLower.contains('grúa') || tiLower.contains('grua')) {
      return 'Báscula colgante / grúa';
    } else if (tiLower.contains('analit') || tiLower.contains('analít')) {
      return 'Báscula analítica';
    } else if (tiLower.contains('piso')) {
      return 'Báscula de piso';
    } else if (tiLower.contains('mostrador')) {
      return 'Báscula de mostrador';
    } else if (tiLower.contains('patron') || tiLower.contains('patrón')) {
      return 'Pesa patrón';
    }
    return _tiposInstrumento.contains(ti) ? ti : null;
  }

  void _aplicarParametrosPostTipoInstrumento() {

    // Nuevos campos: Funcionamiento y Puntos de Apoyo
    final func = _str('funcionamiento');
    if (func.isNotEmpty) _funcionamiento = func;
    final pa = _os['puntos_apoyo'];
    if (pa != null && pa != 0 && pa != '') {
      _puntosApoyo = (pa is int) ? pa : int.tryParse(pa.toString()) ?? getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 4);
    } else {
      _puntosApoyo = getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 4);
    }

    // Geometría de excentricidad y secciones
    final rawGeo = _str('geometria_excentricidad').isNotEmpty
        ? _str('geometria_excentricidad')
        : _str('geometria_plataforma');
    if (rawGeo.isNotEmpty) {
      final g = rawGeo.toLowerCase().trim();
      if (g.contains('camion') || g.contains('ferro') || g.contains('puente')) {
        _geometriaExcentricidad = 'Camionera';
      } else if (g.contains('circ')) {
        _geometriaExcentricidad = 'Circular';
      } else {
        _geometriaExcentricidad = 'Plataforma';
      }
    } else {
      _geometriaExcentricidad = getGeometriaPorDefecto(_tipoInstrumento);
    }

    final nSec = _os['num_secciones'] ?? _os['secciones_camionera'];
    if (nSec != null) {
      _numSeccionesExc = (nSec is int) ? nSec : int.tryParse(nSec.toString()) ?? 4;
    } else if (_geometriaExcentricidad == 'Camionera') {
      _numSeccionesExc = 4;
    }
    _os['geometria_excentricidad'] = _geometriaExcentricidad;
    _os['geometria_plataforma']    = _geometriaExcentricidad;
    _os['num_secciones']           = _numSeccionesExc;
    _os['secciones_camionera']     = _numSeccionesExc;

    // JIA — pueden venir como bool o int (SQLite)
    _jChecked = _asBool(_os['jia_j']);
    _iChecked = _asBool(_os['jia_i']);
    _aChecked = _asBool(_os['jia_a']);

    // Unidad de medida (kg / g)
    final u = _str('unidad_medida').toLowerCase();
    if (u == 'kg' || u == 'g') {
      _unidadMedida = u;
    }

    // Carga de sustitución: herencia estricta desde Logística o Tanque
    final tLowInit = (_tipoInstrumento ?? '').toLowerCase();
    final bool isTanque = tLowInit.contains('tanque');
    final bool isSilo   = tLowInit.contains('silo') && !isTanque;
    final bool isColg   = tLowInit.contains('colgante') || tLowInit.contains('grúa') || tLowInit.contains('grua') || tLowInit.contains('gancho');
    final bool isPatin  = tLowInit.contains('patin') || tLowInit.contains('patín') || tLowInit.contains('transpaleta');
    final bool isTolva  = tLowInit.contains('tolva');

    _usaSustitucion = _asBool(_os['usa_sustitucion']) ||
                      _asBool(_os['es_sustitucion']) ||
                      _asBool(_os['es_enlace_sustitucion']) ||
                      _asBool(_os['aplica_sustitucion']) ||
                      isTanque;

    final rawMotivoInit = (_os['motivo_no_excentricidad'] ??
        _os['tipo_no_apto'] ??
        _os['motivo_no_aplica'] ??
        _os['tipo_no_aplica_exc'])?.toString();
    _motivoNoExcentricidad = inferirMotivoNoExcentricidad(rawMotivoInit, _tipoInstrumento);

    if (isTanque || isSilo || isColg || isPatin || isTolva) {
      _aplExcOverride = false;
      _os['aplica_excentricidad'] = false;
      _motivoNoExcentricidad = isTanque
          ? 'Tanque'
          : isSilo
              ? 'Silo'
              : isColg
                  ? 'Grúa'
                  : isPatin
                      ? 'Patín'
                      : 'Tolva';
      _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
      _os['tipo_no_apto']            = _motivoNoExcentricidad;
      _os['motivo_no_aplica']        = _motivoNoExcentricidad;
      _os['tipo_no_aplica_exc']      = _motivoNoExcentricidad.toLowerCase();
    } else if (tLowInit.contains('plataforma') ||
               tLowInit.contains('camion') ||
               tLowInit.contains('puente') ||
               tLowInit.contains('ferro')) {
      _aplExcOverride = true;
      _os['aplica_excentricidad'] = true;
      _os['motivo_no_excentricidad'] = '';
      _os['tipo_no_apto'] = '';
      _os['motivo_no_aplica'] = '';
      _os['tipo_no_aplica_exc'] = null;
    }

    if (_os['sustitutos'] is List) {
      _sustitutosRows = List<Map<String, dynamic>>.from(
        (_os['sustitutos'] as List).map((x) => Map<String, dynamic>.from(x as Map)),
      );
    }
  }

  /// Determina si aplica excentricidad:
  ///   1. Override manual / dinámico del técnico (`_aplExcOverride`)
  ///   2. Flag asignado por Logística (`aplica_excentricidad`)
  ///   3. Inferencia por tipo de instrumento (Tanque y Colgante no aplican por defecto)
  bool get _aplExc {
    if (_aplExcOverride != null) return _aplExcOverride!;
    final tipoLow = (_tipoInstrumento ?? '').toLowerCase();
    if (tipoLow.contains('tanque') || tipoLow.contains('silo') ||
        tipoLow.contains('colgante') || tipoLow.contains('grúa') ||
        tipoLow.contains('grua') || tipoLow.contains('gancho') ||
        tipoLow.contains('patin') || tipoLow.contains('patín') ||
        tipoLow.contains('tolva')) {
      return false;
    }
    if (tipoLow.contains('plataforma') || tipoLow.contains('camion') ||
        tipoLow.contains('puente') || tipoLow.contains('ferro') ||
        tipoLow.contains('piso')) {
      return true;
    }
    final raw = _os['aplica_excentricidad'];
    if (raw != null) {
      if (raw is bool)   return raw;
      if (raw is int)    return raw == 1;
      if (raw is String) {
        final s = raw.toLowerCase().trim();
        return s == '1' || s == 'true' || s == 'si' || s == 'sí';
      }
    }
    // Inferir por tipo de instrumento
    if (_tipoInstrumento != null) {
      return _kExcInstrumentos.contains(_tipoInstrumento);
    }
    return true; // default conservador: sí aplica
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _firmaClienteFocusNode.dispose();
    _obsFocusNode.dispose();
    _marcaFocusNode.dispose();
    _modeloFocusNode.dispose();
    _nsFocusNode.dispose();
    _idEquipoFocusNode.dispose();
    for (final c in [
      _marcaCtrl, _modeloCtrl, _nsCtrl, _idEquipoCtrl,
      _capMaxCtrl, _divMinCtrl, _divVerCtrl, _ubicCtrl,
      _ccaCtrl, _numeroDveCtrl, _holoAntCtrl, _holoActCtrl,
      _masaPatronCtrl, _factorSustCtrl, _obsCtrl,
      _firmaClienteNombreCtrl,
    ]) { c.dispose(); }
    super.dispose();
  }

  // ── Utilidades metrológicas OIML R 76 ─────────────────────────────────

  /// Parsea d desde el texto del controlador (soporta 'kg' y 'g').
  double? get _dValue {
    final raw = _divMinCtrl.text.trim().replaceAll(',', '.');
    final match = RegExp(r'[\d]+(?:[.][\d]+)?').firstMatch(raw);
    if (match == null) return null;
    final v = double.tryParse(match.group(0) ?? '');
    if (v == null || v <= 0) return null;
    // Si la cadena contiene 'g' pero NO 'kg', convertir gramos a kg
    final unit = raw.substring(match.end).trim().toLowerCase();
    return (unit.contains('g') && !unit.contains('k')) ? v / 1000 : v;
  }

  Future<void> _loadLocalData() async {
    final folio = (_os['folio_os'] ?? widget.osData['folio_os'] ?? widget.osId.toString()).toString().trim();

    // 1. Cargar borrador persistido indexado por folio (ej. draft_OS-26-570)
    final draft = await LocalDbService.instance.getDraft(folio);
    if (draft != null) {
      debugPrint('[Captura] Rehidratando formulario desde borrador para $folio');
      if (mounted) {
        setState(() {
          if (draft['marca'] != null && draft['marca'].toString().isNotEmpty) {
            _marcaCtrl.text = draft['marca'].toString();
            _os['marca'] = _marcaCtrl.text;
          }
          if (draft['modelo'] != null && draft['modelo'].toString().isNotEmpty) {
            _modeloCtrl.text = draft['modelo'].toString();
            _os['modelo'] = _modeloCtrl.text;
          }
          if (draft['ns'] != null && draft['ns'].toString().isNotEmpty) {
            _nsCtrl.text = draft['ns'].toString();
            _os['ns'] = _nsCtrl.text;
          }
          if (draft['id_equipo'] != null && draft['id_equipo'].toString().isNotEmpty) {
            _idEquipoCtrl.text = draft['id_equipo'].toString();
            _os['id_equipo'] = _idEquipoCtrl.text;
          }
          if (draft['ubicacion'] != null && draft['ubicacion'].toString().isNotEmpty) {
            _ubicCtrl.text = draft['ubicacion'].toString();
            _os['ubicacion'] = _ubicCtrl.text;
          }
          if (draft['cap_max'] != null && draft['cap_max'].toString().isNotEmpty) {
            _capMaxCtrl.text = draft['cap_max'].toString();
            _os['alcance_max'] = _capMaxCtrl.text;
          }
          if (draft['div_min'] != null && draft['div_min'].toString().isNotEmpty) {
            _divMinCtrl.text = formatearDivisionMinima(draft['div_min']).replaceAll(RegExp(r'[^0-9.]'), '').trim();
            _os['div_minima'] = _divMinCtrl.text;
          }
          if (draft['div_ver'] != null && draft['div_ver'].toString().isNotEmpty) {
            _divVerCtrl.text = draft['div_ver'].toString();
            _os['div_verificacion'] = _divVerCtrl.text;
          }
          final draftCca = extraerNumeroCca(draft);
          if (draftCca.isNotEmpty) {
            _ccaCtrl.text = draftCca;
            _os['numero_cca'] = draftCca;
          }
          final draftDve = extraerNumeroDve(draft);
          if (draftDve.isNotEmpty) {
            _numeroDveCtrl.text = draftDve;
            _os['numero_dve'] = draftDve;
          }
          if (draft['holograma_anterior'] != null && draft['holograma_anterior'].toString().isNotEmpty) {
            _holoAntCtrl.text = draft['holograma_anterior'].toString();
            _os['holograma_anterior'] = _holoAntCtrl.text;
          }
          if (draft['holograma_actualizado'] != null && draft['holograma_actualizado'].toString().isNotEmpty) {
            _holoActCtrl.text = draft['holograma_actualizado'].toString();
            _os['holograma_actualizado'] = _holoActCtrl.text;
          }
          if (draft['observaciones'] != null && draft['observaciones'].toString().isNotEmpty) {
            _obsCtrl.text = draft['observaciones'].toString();
            _os['observaciones'] = _obsCtrl.text;
          }
          if (draft['firma_cliente_nombre'] != null && draft['firma_cliente_nombre'].toString().isNotEmpty) {
            _firmaClienteNombreCtrl.text = draft['firma_cliente_nombre'].toString();
            _os['firma_cliente_nombre'] = _firmaClienteNombreCtrl.text;
          }
          if (draft['masa_patron'] != null && draft['masa_patron'].toString().isNotEmpty) {
            _masaPatronCtrl.text = draft['masa_patron'].toString();
          }
          if (draft['factor_sustitucion'] != null && draft['factor_sustitucion'].toString().isNotEmpty) {
            _factorSustCtrl.text = draft['factor_sustitucion'].toString();
          }
          if (draft['tipo_instrumento'] != null && draft['tipo_instrumento'].toString().trim().isNotEmpty) {
            _tipoInstrumento = _normalizarNombreTipoInstrumento(draft['tipo_instrumento'].toString());
            _os['tipo_instrumento'] = _tipoInstrumento ?? '';
          }
          if (draft['funcionamiento'] != null && draft['funcionamiento'].toString().isNotEmpty) {
            _funcionamiento = draft['funcionamiento'].toString();
            _os['funcionamiento'] = _funcionamiento;
          }
          if (draft['puntos_apoyo'] != null) {
            _puntosApoyo = int.tryParse(draft['puntos_apoyo'].toString()) ?? _puntosApoyo;
            _os['puntos_apoyo'] = _puntosApoyo;
          }
          if (draft['jia_j'] != null) _jChecked = draft['jia_j'] == true;
          if (draft['jia_i'] != null) _iChecked = draft['jia_i'] == true;
          if (draft['jia_a'] != null) _aChecked = draft['jia_a'] == true;
          if (draft['aplica_excentricidad'] != null) {
            final tLowDraft = (_tipoInstrumento ?? '').toLowerCase();
            if (tLowDraft.contains('plataforma') || tLowDraft.contains('camion') ||
                tLowDraft.contains('puente') || tLowDraft.contains('ferro')) {
              _aplExcOverride = true;
              _os['aplica_excentricidad'] = true;
            } else {
              _aplExcOverride = draft['aplica_excentricidad'] == true;
            }
          }
          final rawMotDraft = (draft['motivo_no_excentricidad'] ??
              draft['tipo_no_apto'] ??
              draft['motivo_no_aplica'] ??
              draft['tipo_no_aplica_exc'])?.toString();
          if (rawMotDraft != null && rawMotDraft.trim().isNotEmpty) {
            _motivoNoExcentricidad = inferirMotivoNoExcentricidad(rawMotDraft, _tipoInstrumento);
            _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
            _os['tipo_no_apto'] = _motivoNoExcentricidad;
            _os['motivo_no_aplica'] = _motivoNoExcentricidad;
            _os['tipo_no_aplica_exc'] = _motivoNoExcentricidad.toLowerCase();
          }
          if (draft['usa_sustitucion'] != null) {
            _usaSustitucion = draft['usa_sustitucion'] == true;
          }
          if (draft['sustitutos'] is List) {
            _sustitutosRows = List<Map<String, dynamic>>.from(
              (draft['sustitutos'] as List).map((x) => Map<String, dynamic>.from(x as Map)),
            );
          }
          if (draft['unidad_medida'] != null && draft['unidad_medida'].toString().isNotEmpty) {
            _unidadMedida = draft['unidad_medida'].toString();
            _os['unidad_medida'] = _unidadMedida;
          }
          if (draft['dictamen'] != null) {
            _dictamen = draft['dictamen'].toString();
          }
          if (draft['geometria_excentricidad'] != null || draft['geometria_plataforma'] != null) {
            final geo = (draft['geometria_excentricidad'] ?? draft['geometria_plataforma']).toString();
            if (geo.isNotEmpty) {
              final g = geo.toLowerCase();
              if (g.contains('camion') || g.contains('ferro') || g.contains('puente')) {
                _geometriaExcentricidad = 'Camionera';
              } else if (g.contains('circ')) {
                _geometriaExcentricidad = 'Circular';
              } else {
                _geometriaExcentricidad = 'Plataforma';
              }
              _os['geometria_excentricidad'] = _geometriaExcentricidad;
              _os['geometria_plataforma'] = _geometriaExcentricidad;
            }
          }
          if (draft['num_secciones'] != null || draft['secciones_camionera'] != null) {
            _numSeccionesExc = int.tryParse((draft['num_secciones'] ?? draft['secciones_camionera']).toString()) ?? _numSeccionesExc;
            _os['num_secciones'] = _numSeccionesExc;
            _os['secciones_camionera'] = _numSeccionesExc;
          }

          if (draft['rep_rows'] is List && (draft['rep_rows'] as List).isNotEmpty) {
            _repRows = (draft['rep_rows'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          }
          if (draft['exc_rows'] is List && (draft['exc_rows'] as List).isNotEmpty) {
            _excRows = (draft['exc_rows'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          }
          if (draft['exac_rows'] is List && (draft['exac_rows'] as List).isNotEmpty) {
            _exacRows = (draft['exac_rows'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          }
        });
      }
    } else {
      // 2. Fallback: cargar desde SQLite ordenes_servicio
      final saved = (widget.osId > 0
              ? await LocalDbService.instance.getOs(widget.osId)
              : null) ??
          (folio.isNotEmpty
              ? await LocalDbService.instance.getOsByFolio(folio)
              : null);
      if (saved != null && mounted) {
        const instrumentKeys = {
          'marca', 'modelo', 'ns', 'serie', 'id_equipo', 'ubicacion',
          'tipo_instrumento', 'alcance_max', 'div_minima',
          'instrumento_capacidad', 'instrumento_division',
          'aplica_excentricidad', 'usa_sustitucion', 'datos_tecnicos_json',
        };
        setState(() {
          for (final k in saved.keys) {
            if (instrumentKeys.contains(k) || (saved[k] != null && saved[k] != '')) {
              _os[k] = saved[k];
            }
          }
          if (saved['unidad_medida'] != null && saved['unidad_medida'].toString().isNotEmpty) {
            _unidadMedida = saved['unidad_medida'].toString();
            _os['unidad_medida'] = _unidadMedida;
          }
          _obsCtrl.text = saved['observaciones'] ?? _obsCtrl.text;
          try {
            if (saved['rep_json'] != null && saved['rep_json'] != '')
              _repRows = (_jsonSafe(saved['rep_json']) as List).cast<Map<String, dynamic>>();
            if (saved['exc_json'] != null && saved['exc_json'] != '')
              _excRows = (_jsonSafe(saved['exc_json']) as List).cast<Map<String, dynamic>>();
            if (saved['exac_json'] != null && saved['exac_json'] != '')
              _exacRows = (_jsonSafe(saved['exac_json']) as List).cast<Map<String, dynamic>>();
          } catch (_) {}
          _precargaCampos();
        });
      }
    }

    // 3. Contactos históricos para autocompletado y memoria por planta/cliente
    final String cliente = (_os['cliente'] ?? _os['cliente_nombre'] ?? widget.osData['cliente'] ?? '').toString();
    final String planta  = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? widget.osData['direccion'] ?? '').toString();
    final contactos = await LocalDbService.instance.getContactosPlanta(cliente: cliente, planta: planta);
    final filtered = contactos.where((c) => !esRazonSocialEmpresa(c, cliente)).toList();

    if (mounted) {
      setState(() {
        _contactosSugeridos = filtered;
        // Nombre de quien recibe debe comenzar VACÍO y no precargar razón social de la empresa
        if (esRazonSocialEmpresa(_firmaClienteNombreCtrl.text, cliente)) {
          _firmaClienteNombreCtrl.text = '';
          _os['firma_cliente_nombre'] = '';
        }
      });
    }

    // 4. Calcular cargas sugeridas si rep_rows o exc_rows aún no tienen valor
    final bool repVacia = _repRows.isEmpty || (_repRows.first['valor'] == null || _repRows.first['valor'] == 0);
    final bool excVacia = _excRows.isEmpty || (_excRows.first['carga'] == null || _excRows.first['carga'] == 0);
    if (repVacia || excVacia) {
      _actualizarCargasSugeridas(force: false);
    }

    if (mounted) {
      setState(() {
        _dataLoaded = true;
        _dataVersion++;
      });
    }
  }

  /// Calcula y sugiere automáticamente las cargas de prueba de Repetibilidad y Excentricidad
  /// al cambiar o ingresar la Capacidad Máxima del instrumento.
  void _actualizarCargasSugeridas({bool force = false}) {
    final raw = _capMaxCtrl.text.trim().replaceAll(',', '.');
    final capMax = double.tryParse(raw);
    if (capMax == null || capMax <= 0) return;

    final d = _dValue;
    final cargaRep = calcularCargaSugeridaRepetibilidad(capMax, divMin: d, unidad: _unidadMedida);
    final cargaExc = calcularCargaSugeridaExcentricidad(capMax, divMin: d, unidad: _unidadMedida);
    final cargaRepStr = formatearCargaSugerida(cargaRep, divMin: d, capMax: capMax);
    final cargaExcStr = formatearCargaSugerida(cargaExc, divMin: d, capMax: capMax);
    final cargaRepNum = double.tryParse(cargaRepStr) ?? cargaRep;
    final cargaExcNum = double.tryParse(cargaExcStr) ?? cargaExc;

    // 1. Repetibilidad (>= 50% Cap. Máx): propagar a los 3 renglones
    if (_repRows.isEmpty) {
      _repRows = List.generate(3, (i) => {
        'posicion_id':     i + 1,
        'valor':           cargaRepNum,
        'valor_kg':        cargaRepNum,
        'lectura_inicial': null,
        'lectura_final':   null,
        'error':           null,
        'valido_d':        true,
      });
    } else {
      _repRows = _repRows.map((r) {
        final m = Map<String, dynamic>.from(r);
        final prevCarga = double.tryParse((m['valor'] ?? m['valor_kg'] ?? '').toString().replaceAll(',', '.'));
        if (force || prevCarga == null || prevCarga == 0 || _cargaRepAutoCalculada == prevCarga) {
          m['valor'] = cargaRepNum;
          m['valor_kg'] = cargaRepNum;
          if (m['lectura_final'] != null) {
            final fin = double.tryParse(m['lectura_final']?.toString() ?? '');
            if (fin != null) {
              m['error'] = fin - cargaRepNum;
            }
          }
        }
        return m;
      }).toList();
    }
    _cargaRepAutoCalculada = cargaRepNum;

    // 2. Excentricidad (>= 1/3 Cap. Máx): colocar en campo Carga de Prueba SOLO si no ha sido editada activamente
    final nSecRaw = _os['num_secciones'] ?? _os['secciones'] ?? _os['num_secciones_camionera'];
    final nSec = (nSecRaw is int) ? nSecRaw : int.tryParse(nSecRaw?.toString() ?? '') ?? 4;
    final isCam = (_tipoInstrumento ?? '').toLowerCase().contains('camion') || (_tipoInstrumento ?? '').toLowerCase().contains('ferro');
    final numPos = isCam ? nSec.clamp(2, 50) : 5;

    final bool excYaEditada = _excRows.any((r) =>
        r['lectura_inicial'] != null ||
        r['lectura_final'] != null ||
        (r['carga'] != null && r['carga'] != 0 && r['carga'] != _cargaExcAutoCalculada));

    if (!excYaEditada) {
      if (_excRows.isEmpty) {
        _excRows = List.generate(numPos, (i) => {
          'posicion_id': i + 1,
          'carga': cargaExcNum,
          'lectura_inicial': null,
          'lectura_final': null,
          'error': null,
          'valido_d': true,
        });
      } else {
        _excRows = _excRows.map((r) {
          final m = Map<String, dynamic>.from(r);
          final prevCarga = double.tryParse((m['carga'] ?? '').toString().replaceAll(',', '.'));
          if (force || prevCarga == null || prevCarga == 0 || _cargaExcAutoCalculada == prevCarga) {
            m['carga'] = cargaExcNum;
            if (m['lectura_final'] != null) {
              final fin = double.tryParse(m['lectura_final']?.toString() ?? '');
              if (fin != null) {
                m['error'] = fin - cargaExcNum;
              }
            }
          }
          return m;
        }).toList();
      }
      _cargaExcAutoCalculada = cargaExcNum;
    }

    _dataVersion++;
    if (mounted) setState(() {});
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_dataLoaded) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F5F7),
        body: Center(
          child: CircularProgressIndicator(color: _kRed),
        ),
      );
    }

    final docData = _os.isNotEmpty ? _os : widget.osData;
    final String folioUpper = (docData['folio'] ?? docData['folio_os'] ?? docData['folio_rma'] ?? '').toString().trim().toUpperCase();
    final String tipoDocUpper = (docData['tipo_documento'] ?? '').toString().trim().toUpperCase();
    final String tipoUpper = (docData['tipo_servicio'] ?? '').toString().trim().toUpperCase();

    // 0. PRIMERA CONDICIÓN EXPLÍCITA: OSOCC (Formato de Diagnóstico y Revisión de Celda de Carga)
    if (folioUpper.startsWith('OSOCC-') ||
        tipoDocUpper == 'OSOCC' ||
        tipoUpper.contains('OSOCC') ||
        tipoUpper.contains('OBSERVACIONES CELDA') ||
        (tipoUpper.contains('DIAGNOSTICO') && tipoUpper.contains('CELDA')) ||
        (tipoUpper.contains('DIAGNÓSTICO') && tipoUpper.contains('CELDA'))) {
      return ObservacionesCeldaScreen(orden: docData);
    } else if (folioUpper.startsWith('OSOB-') ||
        tipoDocUpper == 'OSOB' ||
        tipoUpper.contains('OSOB') ||
        tipoUpper.contains('OBSERVACION') ||
        (!folioUpper.startsWith('OS-') &&
            !folioUpper.startsWith('RMA-') &&
            !folioUpper.startsWith('RE-') &&
            (tipoUpper.contains('INSPECCION') || tipoUpper.contains('INSPECCIÓN')))) {
      return ObservacionesBasculaScreen(orden: docData);
    } else if (folioUpper.startsWith('RMA-') ||
        tipoDocUpper == 'RMA' ||
        tipoUpper.contains('REMISI') ||
        tipoUpper.contains('REFACCI')) {
      return RemisionCapturaScreen(orden: docData);
    } else if (folioUpper.startsWith('RE-') ||
        tipoDocUpper == 'RE' ||
        (!folioUpper.startsWith('OS-') && tipoUpper.contains('REVISI'))) {
      return RevisionBasculaScreen(orden: docData);
    } else if (folioUpper.startsWith('LP-') ||
        tipoDocUpper == 'LP' ||
        tipoUpper.contains('PROYECTO')) {
      return LevantamientoProyectoScreen(orden: docData);
    } else if (folioUpper.startsWith('LV-') ||
        tipoDocUpper == 'LV' ||
        tipoUpper.contains('METROL')) {
      return LevantamientoMetrologicoScreen(orden: docData);
    }

    final folio   = _os['folio_os'] ?? widget.osId.toString();
    final nPuntos = (_os['num_puntos_exactitud'] as int?) ?? 10;
    final nCeldas = _os['num_celdas_camionera'] is int
        ? _os['num_celdas_camionera'] as int
        : int.tryParse(_os['num_celdas_camionera']?.toString() ?? '0') ?? 0;

    return PopScope(
      canPop: _permitirSalida,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _permitirSalida) return;
        await _mostrarDialogoSalida(context);
      },
      child: SafeArea(
        bottom: false,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          backgroundColor: PesaColors.canvas,
          appBar: AppBar(
            backgroundColor: PesaColors.surface,
            foregroundColor: PesaColors.textPrimary,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () async {
                await _mostrarDialogoSalida(context);
              },
            ),
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                folio,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16.5,
                  color: PesaColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _os['cliente'] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: PesaColors.textSecondary),
              ),
            ]),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _guardarBorrador(mostrarSnackbar: true),
                  child: PesaDraftIndicator(saving: _saving || _savingParcial),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: SyncCheckBadge(
                    status: (_os['sync_check_status'] as String?) ?? 'RECIBIDA_TABLET',
                    showLabel: true,
                    fontSize: 11,
                    iconSize: 13,
                  ),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(88),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(height: 1, color: PesaColors.divider),
                  PesaStepProgressBar(
                    currentStep: _tabCtrl.index + 1,
                    totalSteps: 4,
                    stepLabel: const [
                      'Paso 1 de 4 · Datos del Equipo',
                      'Paso 2 de 4 · Repetibilidad',
                      'Paso 3 de 4 · Excentricidad',
                      'Paso 4 de 4 · Exactitud y Cierre',
                    ][_tabCtrl.index.clamp(0, 3)],
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      color: PesaColors.surface,
                      border: Border(
                        top: BorderSide(color: PesaColors.divider),
                        bottom: BorderSide(color: PesaColors.border),
                      ),
                    ),
                    child: TabBar(
                      controller: _tabCtrl,
                      indicatorColor: _kRed,
                      indicatorWeight: 2.5,
                      labelColor: _kRed,
                      unselectedLabelColor: PesaColors.textSecondary,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                      tabs: const [
                        Tab(text: '1. Equipo'),
                        Tab(text: '2. Repetibilidad'),
                        Tab(text: '3. Excentricidad'),
                        Tab(text: '4. Exactitud'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          body: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildTabInstrumento(),
              _buildRepetibilidadTab(),
              _buildExcentricidadTab(nCeldas),
              _buildExactitudTab(nPuntos, folio),
            ],
          ),
        ),
      ),
    );
  }

  // ── Tab 0: Datos del Instrumento ──────────────────────────────────────────
  Widget _buildTabInstrumento() {
    final rules = _rules;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Banner: tipo de servicio + badges condicionales ────────────────
        _ServicioBanner(rules: rules, tipoServicioNombre: _os['tipo_servicio'] as String?),
        const SizedBox(height: 16),

        // ── Identificación del instrumento (con autocompletado de historial) ─
        Row(
          children: [
            const Expanded(child: _SectionTitle('Identificación del Instrumento')),
            if (_historialInstrumentos.isNotEmpty)
              PesaStatusBadge(
                label: 'Autocompletado (${_historialInstrumentos.length} eq.)',
                dotColor: PesaColors.dotGreen,
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _EquipoHistorialAutocomplete(
            label: 'Marca',
            ctrl: _marcaCtrl,
            focusNode: _marcaFocusNode,
            fieldKey: 'marca',
            historial: _historialInstrumentos,
            fallbackStrings: _marcasSugeridas,
            hint: 'Rice Lake, Mettler...',
            required: true,
            hasError: _mostrarErroresInstrumento && _marcaCtrl.text.trim().isEmpty,
            onChanged: (val) {
              _actualizarModelosParaMarca(val);
              if (_mostrarErroresInstrumento) setState(() {});
            },
            onSelectedInstrument: _aplicarInstrumentoDelHistorial,
          )),
          const SizedBox(width: 12),
          Expanded(child: _EquipoHistorialAutocomplete(
            label: 'Modelo',
            ctrl: _modeloCtrl,
            focusNode: _modeloFocusNode,
            fieldKey: 'modelo',
            historial: _historialInstrumentos,
            fallbackStrings: _modelosSugeridos,
            hint: '920i-4A, IND560...',
            required: true,
            hasError: _mostrarErroresInstrumento && _modeloCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
            onSelectedInstrument: _aplicarInstrumentoDelHistorial,
          )),
          const SizedBox(width: 12),
          Expanded(child: _EquipoHistorialAutocomplete(
            label: 'N° de Serie',
            ctrl: _nsCtrl,
            focusNode: _nsFocusNode,
            fieldKey: 'serie',
            historial: _historialInstrumentos,
            fallbackStrings: const [],
            hint: '1318400062',
            onSelectedInstrument: _aplicarInstrumentoDelHistorial,
          )),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _EquipoHistorialAutocomplete(
            label: 'ID Indicador / Equipo',
            ctrl: _idEquipoCtrl,
            focusNode: _idEquipoFocusNode,
            fieldKey: 'id_indicador',
            historial: _historialInstrumentos,
            fallbackStrings: const [],
            hint: 'Trailer A, Báscula 3...',
            required: true,
            hasError: _mostrarErroresInstrumento && _idEquipoCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
            onSelectedInstrument: _aplicarInstrumentoDelHistorial,
          )),
          const SizedBox(width: 12),
          Expanded(child: _Field(
            'Ubicación',
            _ubicCtrl,
            hint: 'Taller, Planta Norte...',
            required: true,
            hasError: _mostrarErroresInstrumento && _ubicCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
          )),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _tipoInstrumento,
          decoration: _kInputDeco('Tipo de Instrumento'),
          hint: const Text('Seleccionar...', style: TextStyle(fontSize: 13)),
          items: _tiposInstrumento.map((t) =>
              DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (v) => setState(() {
            _tipoInstrumento = v;
            _os['tipo_instrumento'] = v;
            final vLow = (v ?? '').toLowerCase();
            final isSilo     = vLow.contains('silo') && !vLow.contains('tanque');
            final isTanque   = vLow.contains('tanque');
            final isColgante = vLow.contains('colgante') || vLow.contains('grúa') || vLow.contains('grua') || vLow.contains('gancho');
            final isPatin    = vLow.contains('patin') || vLow.contains('patín') || vLow.contains('transpaleta');
            final isTolva    = vLow.contains('tolva');

            if (isTanque || isSilo) {
              _usaSustitucion = isTanque;
              _aplExcOverride = false;
              _os['aplica_excentricidad'] = false;
              _motivoNoExcentricidad = isSilo ? 'Silo' : 'Tanque';
              _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
              _os['tipo_no_apto']            = _motivoNoExcentricidad;
              _os['motivo_no_aplica']        = _motivoNoExcentricidad;
              _os['tipo_no_aplica_exc']      = _motivoNoExcentricidad.toLowerCase();
              _os['usa_sustitucion'] = isTanque;
              _os['es_sustitucion'] = isTanque;
              _os['es_enlace_sustitucion'] = isTanque;
            } else if (isColgante || isPatin || isTolva) {
              _usaSustitucion = false;
              _aplExcOverride = false;
              _os['aplica_excentricidad'] = false;
              _motivoNoExcentricidad = isColgante
                  ? 'Grúa'
                  : isPatin
                      ? 'Patín'
                      : 'Tolva';
              _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
              _os['tipo_no_apto']            = _motivoNoExcentricidad;
              _os['motivo_no_aplica']        = _motivoNoExcentricidad;
              _os['tipo_no_aplica_exc']      = _motivoNoExcentricidad.toLowerCase();
              _os['usa_sustitucion'] = false;
              _os['aplica_sustitucion'] = false;
              _os['es_sustitucion'] = false;
              _os['es_enlace_sustitucion'] = false;
            } else {
              // Cualquier instrumento que sí aplica excentricidad:
              _usaSustitucion = false;
              _aplExcOverride = true;
              _os['aplica_excentricidad'] = true;
              _os['motivo_no_excentricidad'] = '';
              _os['tipo_no_apto'] = '';
              _os['motivo_no_aplica'] = '';
              _os['tipo_no_aplica_exc'] = null;
              _os['usa_sustitucion'] = false;
              _os['aplica_sustitucion'] = false;
              _os['es_sustitucion'] = false;
              _os['es_enlace_sustitucion'] = false;
            }

            _puntosApoyo = getPuntosApoyoPorDefecto(v, fallback: (_puntosApoyo > 1 ? _puntosApoyo : 5));
            if (_aplExc && _puntosApoyo < 4) {
              _puntosApoyo = (vLow.contains('camion') || vLow.contains('ferro') || vLow.contains('puente')) ? 4 : 5;
            }
            _os['puntos_apoyo'] = _puntosApoyo;
            _geometriaExcentricidad = getGeometriaPorDefecto(v);
            _os['geometria_excentricidad'] = _geometriaExcentricidad;
            _os['geometria_plataforma']    = _geometriaExcentricidad;
            if (_geometriaExcentricidad == 'Camionera' && _numSeccionesExc < 2) {
              _numSeccionesExc = 4;
            }
            _os['num_secciones']       = _numSeccionesExc;
            _os['secciones_camionera'] = _numSeccionesExc;

            if (_aplExc) {
              final numPos = _geometriaExcentricidad == 'Camionera' ? _numSeccionesExc.clamp(2, 50) : 5;
              if (_excRows.isEmpty) {
                _excRows = List.generate(numPos, (i) => {
                  'posicion_id': i + 1,
                  'carga': _cargaExcAutoCalculada,
                  'lectura_inicial': null,
                  'lectura_final': null,
                  'error': null,
                  'valido_d': true,
                });
              }
              _actualizarCargasSugeridas(force: false);
            }
            _dataVersion++;
          }),
        ),
        const SizedBox(height: 16),

        // ── Parámetros metrológicos base (Cap + Div + Unidad) ────────
        _SectionTitle('Parámetros Metrológicos'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            flex: 3,
            child: _NumField(
              'Capacidad Máx. ($_unidadMedida) *',
              _capMaxCtrl,
              hasError: _mostrarErroresInstrumento && _capMaxCtrl.text.trim().isEmpty,
              onChanged: (_) {
                _actualizarCargasSugeridas();
                if (_mostrarErroresInstrumento) setState(() {});
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: _NumField(
              'División Mín. ($_unidadMedida) *',
              _divMinCtrl,
              hasError: _mostrarErroresInstrumento && _divMinCtrl.text.trim().isEmpty,
              onChanged: (_) {
                _actualizarCargasSugeridas();
                if (_mostrarErroresInstrumento) setState(() {});
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              value: _unidadMedida,
              decoration: _kInputDeco('Unidad'),
              items: const [
                DropdownMenuItem(value: 'kg', child: Text('kg', style: TextStyle(fontWeight: FontWeight.bold))),
                DropdownMenuItem(value: 'g',  child: Text('g',  style: TextStyle(fontWeight: FontWeight.bold))),
              ],
              onChanged: (v) => setState(() {
                _unidadMedida = v ?? 'kg';
                _os['unidad_medida'] = _unidadMedida;
                _dataVersion++;
                _actualizarCargasSugeridas();
              }),
            ),
          ),
        ]),
        const SizedBox(height: 12),

        // ¿Aplica Excentricidad? — SIEMPRE editable por el técnico en campo
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: _aplExc
                  ? _kRed.withValues(alpha: 0.35)
                  : Colors.grey.shade200)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  _aplExc ? Icons.center_focus_strong : Icons.center_focus_weak,
                  color: _aplExc ? _kRed : Colors.grey,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '¿Aplica Excentricidad?',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _aplExc
                            ? 'Sí — Prueba de excentricidad habilitada en pestaña Excentricidad'
                            : 'No — Prueba de excentricidad omitida (puedes activarla si aplica)',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                SegmentedButton<bool>(
                  key: const Key('captura_excentricidad_selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('No')),
                    ButtonSegment(value: true,  label: Text('Sí')),
                  ],
                  selected: {_aplExc},
                  onSelectionChanged: (s) => setState(() {
                    final nuevoVal = s.first;
                    _aplExcOverride = nuevoVal;
                    _os['aplica_excentricidad'] = nuevoVal;
                    if (nuevoVal) {
                      _os['motivo_no_excentricidad'] = '';
                      _os['tipo_no_apto'] = '';
                      _os['motivo_no_aplica'] = '';
                      _os['tipo_no_aplica_exc'] = null;
                      if (_puntosApoyo < 4) {
                        _puntosApoyo = getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 5);
                        if (_puntosApoyo < 4) _puntosApoyo = 5;
                        _os['puntos_apoyo'] = _puntosApoyo;
                      }
                      _geometriaExcentricidad = getGeometriaPorDefecto(_tipoInstrumento);
                      _os['geometria_excentricidad'] = _geometriaExcentricidad;
                      _os['geometria_plataforma']    = _geometriaExcentricidad;
                      if (_geometriaExcentricidad == 'Camionera' && _numSeccionesExc < 2) {
                        _numSeccionesExc = 4;
                      }
                      _os['num_secciones']       = _numSeccionesExc;
                      _os['secciones_camionera'] = _numSeccionesExc;
                      final numPos = _geometriaExcentricidad == 'Camionera' ? _numSeccionesExc.clamp(2, 50) : 5;
                      if (_excRows.isEmpty) {
                        _excRows = List.generate(numPos, (i) => {
                          'posicion_id': i + 1,
                          'carga': _cargaExcAutoCalculada,
                          'lectura_inicial': null,
                          'lectura_final': null,
                          'error': null,
                          'valido_d': true,
                        });
                      }
                      _actualizarCargasSugeridas(force: false);
                    } else {
                      _motivoNoExcentricidad = inferirMotivoNoExcentricidad(_motivoNoExcentricidad, _tipoInstrumento);
                      _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
                      _os['tipo_no_apto']            = _motivoNoExcentricidad;
                      _os['motivo_no_aplica']        = _motivoNoExcentricidad;
                      _os['tipo_no_aplica_exc']      = _motivoNoExcentricidad.toLowerCase();
                    }
                    _dataVersion++;
                  }),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
        ),
        if (!_aplExc) ...[
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: const Color(0xFFFFF8F8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Color(0xFFFFCCCC), width: 1.2),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.category_outlined, size: 18, color: _kRed),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Motivo / Tipo de Instrumento No Apto para Excentricidad *',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kRed),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const <Map<String, dynamic>>[
                      {'key': 'Grúa',   'sub': 'Báscula de grúa / colgante',     'icon': Icons.precision_manufacturing_outlined},
                      {'key': 'Patín',  'sub': 'Patín hidráulico / transpaleta', 'icon': Icons.rv_hookup_outlined},
                      {'key': 'Tanque', 'sub': 'Báscula tipo tanque',            'icon': Icons.propane_tank_outlined},
                      {'key': 'Tolva',  'sub': 'Báscula tipo tolva',             'icon': Icons.filter_alt_outlined},
                      {'key': 'Silo',   'sub': 'Báscula tipo silo',              'icon': Icons.factory_outlined},
                    ].map((opt) {
                      final String k = opt['key'] as String;
                      final String sub = opt['sub'] as String;
                      final IconData ic = opt['icon'] as IconData;
                      final bool active = _motivoNoExcentricidad.toLowerCase() == k.toLowerCase();
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() {
                          _motivoNoExcentricidad = k;
                          _os['motivo_no_excentricidad'] = k;
                          _os['tipo_no_apto']            = k;
                          _os['motivo_no_aplica']        = k;
                          _os['tipo_no_aplica_exc']      = k.toLowerCase();
                          _dataVersion++;
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: active ? _kRed.withValues(alpha: 0.12) : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: active ? _kRed : Colors.grey.shade300,
                              width: active ? 1.6 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(ic, size: 18, color: active ? _kRed : Colors.grey.shade700),
                              const SizedBox(width: 6),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    k,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: active ? _kRed : const Color(0xFF1D1D1F),
                                    ),
                                  ),
                                  Text(
                                    sub,
                                    style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),

        // ── Sección Números Regulatorios Independientes (CCA y DVE) ───────
        _SectionTitle('Números Regulatorios (CCA y/o DVE)'),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _Field(
              'Número CCA',
              _ccaCtrl,
              hint: '${_prefijoCca}02163',
              required: rules.tieneCalibracion,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Field(
              'Número DVE',
              _numeroDveCtrl,
              hint: '${_prefijoDve}00412',
              required: rules.tieneInspeccion && !rules.tieneCalibracion,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
            ),
          ),
        ]),
        if (rules.tieneCalibracion) ...[
          const SizedBox(height: 10),
          const Text('Inicial del Calibrador (NOM-010-SCFI-2020):',
              style: TextStyle(fontSize: 12, color: Color(0xFF374151),
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(children: [
            _JiaToggle('J', _jChecked, (v) => setState(() => _jChecked = v)),
            const SizedBox(width: 8),
            _JiaToggle('I', _iChecked, (v) => setState(() => _iChecked = v)),
            const SizedBox(width: 8),
            _JiaToggle('A', _aChecked, (v) => setState(() => _aChecked = v)),
            const SizedBox(width: 12),
            Flexible(child: Text(
              _jChecked ? 'Jefe Laboratorio'
                  : _iChecked ? 'Inspector EMA'
                  : _aChecked ? 'Auxiliar'
                  : '— Sin selección',
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              overflow: TextOverflow.ellipsis,
            )),
          ]),
        ],
        const SizedBox(height: 16),

        // ── CASO C/D: Sección Inspección + DVE (solo si incluye Inspección) ─
        if (rules.tieneInspeccion) ...[
          _SectionTitle('Inspección / Verificación Metrológica'),
          const SizedBox(height: 10),
          _NumField('Div. Verificación e (kg)', _divVerCtrl),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _Field('Holograma Anterior', _holoAntCtrl,
                hint: '2025-XXXX', required: true)),
            const SizedBox(width: 12),
            Expanded(child: _Field('Holograma Actualizado', _holoActCtrl,
                hint: '2026-XXXX', required: true)),
          ]),
          const SizedBox(height: 16),
        ],

        // ── Cargas de sustitución — COMPLETAMENTE OPCIONAL ─────────────────
        // "No" o campos vacíos ⇒ se omite la sección y la exactitud se valida
        // solo con pesas patrón directas (sin error ni bloqueo de guardado/PDF).
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: _usaSustitucion
                  ? _kRed.withValues(alpha: 0.35)
                  : Colors.grey.shade200)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.swap_horiz, color: _usaSustitucion ? _kRed : Colors.grey),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '¿Aplica cargas de sustitución?',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Si eliges "Sí", se habilita la tabla de cargas de sustitución en la pestaña de Exactitud.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                SegmentedButton<bool>(
                  key: const Key('captura_sustitucion_selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('No')),
                    ButtonSegment(value: true,  label: Text('Sí')),
                  ],
                  selected: {_usaSustitucion},
                  onSelectionChanged: (s) => setState(() {
                    _usaSustitucion = s.first;
                    _dataVersion++;
                  }),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Nuevos campos: Funcionamiento y Puntos de Apoyo ────────────────────
        _SectionTitle('Parámetros del Instrumento'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _funcionamiento,
              decoration: _kInputDeco('Funcionamiento'),
              items: ['Electrónico', 'Mecánico', 'Electromecánico']
                  .map((f) => DropdownMenuItem(value: f, child: Text(f, style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (v) => setState(() => _funcionamiento = v ?? _funcionamiento),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('Puntos de Apoyo',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                ),
                Row(children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    color: _kRed,
                    onPressed: () => setState(() {
                      if (_puntosApoyo > 1) {
                        _puntosApoyo--;
                        _os['puntos_apoyo'] = _puntosApoyo;
                      }
                    }),
                  ),
                  Text('$_puntosApoyo',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    color: _kRed,
                    onPressed: () => setState(() {
                      if (_puntosApoyo < 30) {
                        _puntosApoyo++;
                        _os['puntos_apoyo'] = _puntosApoyo;
                      }
                    }),
                  ),
                ]),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 20),

        // ── Botón Guardar Datos de Equipo (Sin Finalizar) ──────────────────
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1D4ED8),
              backgroundColor: const Color(0xFFEFF6FF),
              side: const BorderSide(color: Color(0xFF93C5FD), width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _savingParcial ? null : _guardarEquipoSinFinalizar,
            icon: _savingParcial
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)),
                  )
                : const Icon(Icons.cloud_upload_outlined, size: 19),
            label: Text(
              _savingParcial
                  ? 'Guardando y sincronizando equipo...'
                  : 'Guardar Datos de Equipo (Sin Finalizar)',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // ── Botón continuar a mediciones ───────────────────────────────────
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              _guardarDatosInstrumento();
              _tabCtrl.animateTo(1);
            },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continuar → Mediciones',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  // ── Tab 1: Repetibilidad ──────────────────────────────────────────────────
  Widget _buildRepetibilidadTab() {
    return RepetibilidadTable(
      key: ValueKey('rep_${_dataVersion}_$_dValue'),
      rows: _repRows,
      divMin: _dValue,
      onChanged: (r) => _repRows = r,
      footer: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kRed,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
          icon: const Icon(Icons.arrow_forward),
          label: Text(
            _aplExc
                ? 'Continuar con Prueba de Excentricidad →'
                : 'Continuar con Prueba de Exactitud →',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          onPressed: () {
            _guardarBorrador(mostrarSnackbar: false);
            if (_aplExc) {
              _tabCtrl.animateTo(2); // Excentricidad
            } else {
              _tabCtrl.animateTo(3); // Exactitud
            }
          },
        ),
      ),
    );
  }

  // ── Tab 2: Excentricidad ──────────────────────────────────────────────────
  Widget _buildExcentricidadTab(int nCeldas) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: const BoxDecoration(
              color: PesaColors.surface,
              border: Border(bottom: BorderSide(color: PesaColors.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              PesaSemanticDot(
                color: _aplExc ? PesaColors.dotGreen : PesaColors.dotAmber,
                size: 6,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(
                _aplExc
                    ? 'Prueba de Excentricidad activa — captura los valores de cada posición.'
                    : 'Excentricidad marcada como No Aplica.',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: PesaColors.textPrimary,
                ),
              )),
              if (!_aplExc)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _aplExcOverride = true;
                    _os['aplica_excentricidad'] = true;
                    _os['motivo_no_aplica'] = '';
                    _os['tipo_no_aplica_exc'] = null;
                    if (_puntosApoyo < 4) {
                      _puntosApoyo = getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 5);
                      if (_puntosApoyo < 4) _puntosApoyo = 5;
                      _os['puntos_apoyo'] = _puntosApoyo;
                    }
                    _geometriaExcentricidad = getGeometriaPorDefecto(_tipoInstrumento);
                    _os['geometria_excentricidad'] = _geometriaExcentricidad;
                    _os['geometria_plataforma']    = _geometriaExcentricidad;
                    if (_geometriaExcentricidad == 'Camionera' && _numSeccionesExc < 2) {
                      _numSeccionesExc = 4;
                    }
                    _os['num_secciones']       = _numSeccionesExc;
                    _os['secciones_camionera'] = _numSeccionesExc;
                    final numPos = _geometriaExcentricidad == 'Camionera' ? _numSeccionesExc.clamp(2, 50) : 5;
                    if (_excRows.isEmpty) {
                      _excRows = List.generate(numPos, (i) => {
                        'posicion_id': i + 1,
                        'carga': _cargaExcAutoCalculada,
                        'lectura_inicial': null,
                        'lectura_final': null,
                        'error': null,
                        'valido_d': true,
                      });
                    }
                    _actualizarCargasSugeridas(force: false);
                    _dataVersion++;
                  }),
                  icon: const Icon(Icons.lock_open, size: 15, color: _kRed),
                  label: const Text('Habilitar Excentricidad',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kRed)),
                ),
            ]),
          ),
          ExcentricidadTable(
            key: ValueKey('exc_${_dataVersion}_${_aplExc}_${_tipoInstrumento}_${_geometriaExcentricidad}_${_motivoNoExcentricidad}_$_dValue'),
            numCeldas: nCeldas,
            numSecciones: _numSeccionesExc,
            rows: _excRows,
            divMin: _dValue,
            geometria: _geometriaExcentricidad,
            tipoInstrumento: _tipoInstrumento,
            aplicaExcentricidad: _aplExc,
            motivoNoExcentricidad: _motivoNoExcentricidad,
            onMotivoNoChanged: (mot) {
              setState(() {
                _motivoNoExcentricidad = mot;
                _os['motivo_no_excentricidad'] = mot;
                _os['tipo_no_apto']            = mot;
                _os['motivo_no_aplica']        = mot;
                _os['tipo_no_aplica_exc']      = mot.toLowerCase();
              });
            },
            onGeometriaChanged: (geo) {
              setState(() {
                _geometriaExcentricidad = geo;
                _os['geometria_excentricidad'] = geo;
                _os['geometria_plataforma']    = geo;
                final gLow = geo.toLowerCase();
                if (gLow.contains('plataforma') || gLow.contains('camion')) {
                  _aplExcOverride = true;
                  _os['aplica_excentricidad'] = true;
                  _os['motivo_no_aplica'] = '';
                  _os['tipo_no_aplica_exc'] = null;
                }
              });
            },
            onNumSeccionesChanged: (sec) {
              setState(() {
                _numSeccionesExc = sec;
                _os['num_secciones']       = sec;
                _os['secciones_camionera'] = sec;
              });
            },
            onChanged: (r) => _excRows = r,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.arrow_forward),
                label: const Text(
                  'Continuar con Prueba de Exactitud →',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                onPressed: () {
                  _guardarBorrador(mostrarSnackbar: false);
                  _tabCtrl.animateTo(3); // Exactitud
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab 3: Exactitud (Fin de las pruebas) ──────────────────────────────────
  Widget _buildExactitudTab(int nPuntos, String folio) {
    if (_usaSustitucion) {
      return EnlacesSustitucionTable(
        key: ValueKey('exac_${_dataVersion}_$_dValue'),
        numEnlaces: 5,
        rows: _exacRows,
        divMin: _dValue,
        sustitutos: _sustitutosRows,
        unidadMedida: _unidadMedida,
        onChanged: (r) => _exacRows = r,
        onSustitutosChanged: (s) => _sustitutosRows = s,
        footer: _buildExactitudFooter(folio),
      );
    }
    return ExactitudTable(
      key: ValueKey('exac_${_dataVersion}_$_dValue'),
      numPuntos: nPuntos,
      rows: _exacRows,
      divMin: _dValue,
      onChanged: (r) => _exacRows = r,
      footer: _buildExactitudFooter(folio),
    );
  }

  // ── Footer de Exactitud: Observaciones del Servicio + Dictamen + Botón a Firmas ──
  Widget _buildExactitudFooter(String folio) {
    final nombreVacio = _firmaClienteNombreCtrl.text.trim().isEmpty;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.notes, color: _kRed, size: 20),
                SizedBox(width: 8),
                Text(
                  'Observaciones del Servicio',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _obsCtrl,
              focusNode: _obsFocusNode,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Ingrese observaciones metrológicas o detalles del servicio...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                contentPadding: EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text(
                  'Dictamen: ',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                    color: Colors.white,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _dictamen,
                      items: ['APTO', 'NO APTO', 'CONDICIONADO']
                          .map((d) => DropdownMenuItem(value: d, child: Text(d, style: const TextStyle(fontWeight: FontWeight.bold))))
                          .toList(),
                      onChanged: (v) => setState(() => _dictamen = v!),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Nombre del cliente receptor
            RawAutocomplete<String>(
              textEditingController: _firmaClienteNombreCtrl,
              focusNode: _firmaClienteFocusNode,
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (_contactosSugeridos.isEmpty) return const Iterable<String>.empty();
                if (textEditingValue.text.isEmpty) return _contactosSugeridos;
                return _contactosSugeridos.where((c) =>
                    c.toLowerCase().contains(textEditingValue.text.toLowerCase()));
              },
              onSelected: (String selection) {
                setState(() {
                  _firmaClienteNombreCtrl.text = selection;
                });
              },
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    labelText: 'Nombre de quien recibe / Conforme Cliente *',
                    labelStyle: const TextStyle(
                        color: Color(0xFFC8102E), fontWeight: FontWeight.w600),
                    hintText: 'Nombre completo del receptor (ej. Janeth Lopez)',
                    border: OutlineInputBorder(
                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                        borderSide: BorderSide(
                            color: nombreVacio
                                ? const Color(0xFFC8102E)
                                : Colors.grey.shade300)),
                    focusedBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                        borderSide:
                            BorderSide(color: Color(0xFFC8102E), width: 2)),
                    isDense: true,
                    prefixIcon: const Icon(Icons.person_outline,
                        color: Color(0xFFC8102E), size: 18),
                    suffixIcon: _contactosSugeridos.isNotEmpty
                        ? PopupMenuButton<String>(
                            icon: const Icon(Icons.arrow_drop_down, color: Color(0xFFC8102E)),
                            tooltip: 'Contactos registrados para esta planta',
                            onSelected: (val) {
                              setState(() {
                                _firmaClienteNombreCtrl.text = val;
                              });
                            },
                            itemBuilder: (context) => _contactosSugeridos.map((c) => PopupMenuItem(
                              value: c,
                              child: Row(
                                children: [
                                  const Icon(Icons.history, size: 16, color: Colors.grey),
                                  const SizedBox(width: 8),
                                  Text(c, style: const TextStyle(fontSize: 13)),
                                ],
                              ),
                            )).toList(),
                          )
                        : null,
                  ),
                  maxLines: 1,
                  onChanged: (_) => setState(() {}),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200, maxWidth: 350),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (context, i) {
                          final opt = options.elementAt(i);
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.person, size: 16, color: Color(0xFFC8102E)),
                            title: Text(opt, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            subtitle: const Text('Contacto registrado en planta', style: TextStyle(fontSize: 10, color: Colors.grey)),
                            onTap: () => onSelected(opt),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
            if (_contactosSugeridos.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.history, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  const Text('Historial planta: ',
                      style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _contactosSugeridos.map((contacto) {
                          final isSelected = _firmaClienteNombreCtrl.text.trim().toLowerCase() == contacto.toLowerCase();
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: isSelected ? const Color(0xFFFFEBEE) : Colors.grey.shade100,
                              side: BorderSide(color: isSelected ? const Color(0xFFC8102E) : Colors.grey.shade300),
                              avatar: Icon(Icons.person, size: 12, color: isSelected ? const Color(0xFFC8102E) : Colors.grey.shade700),
                              label: Text(contacto, style: TextStyle(fontSize: 11, color: isSelected ? const Color(0xFFC8102E) : Colors.black87, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                              onPressed: () {
                                setState(() {
                                  _firmaClienteNombreCtrl.text = contacto;
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
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A7F64),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 3,
                ),
                icon: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.draw_outlined),
                label: const Text('Continuar a Firmas →',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                onPressed: _saving ? null : () => _irAFirma(folio),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Lógica de guardado ────────────────────────────────────────────────────

  void _guardarDatosInstrumento() {
    final rules = _rules;
    _os['marca']                 = _marcaCtrl.text.trim();
    _os['modelo']                = _modeloCtrl.text.trim();
    // Persistir combinación de marca y modelo en catálogo local SQLite
    LocalDbService.instance.saveMarcaModelo(_marcaCtrl.text, _modeloCtrl.text);
    _os['ns']                    = _nsCtrl.text.trim();
    _os['serie']                 = _nsCtrl.text.trim();
    _os['id_equipo']             = _idEquipoCtrl.text.trim();
    _os['id_indicador']          = _idEquipoCtrl.text.trim();
    _os['ubicacion']             = _ubicCtrl.text.trim();
    _os['tipo_instrumento']      = _tipoInstrumento;
    _os['jia_j']                 = _jEf;
    _os['jia_i']                 = _iEf;
    _os['jia_a']                 = _aEf;
    final divNorm = formatearDivisionMinima(_divMinCtrl.text.trim());
    if (_divMinCtrl.text.trim() != divNorm && divNorm.isNotEmpty) {
      _divMinCtrl.text = divNorm;
    }
    _os['aplica_excentricidad']  = _aplExc;
    if (_aplExc) {
      _os['motivo_no_excentricidad'] = '';
      _os['tipo_no_apto']            = '';
      _os['motivo_no_aplica']        = '';
      _os['tipo_no_aplica_exc']      = null;
    } else {
      _motivoNoExcentricidad = inferirMotivoNoExcentricidad(_motivoNoExcentricidad, _tipoInstrumento);
      _os['motivo_no_excentricidad'] = _motivoNoExcentricidad;
      _os['tipo_no_apto']            = _motivoNoExcentricidad;
      _os['motivo_no_aplica']        = _motivoNoExcentricidad;
      _os['tipo_no_aplica_exc']      = _motivoNoExcentricidad.toLowerCase();
    }
    _os['usa_sustitucion']       = _aplicaSustitucion;
    _os['aplica_sustitucion']    = _aplicaSustitucion;
    _os['funcionamiento']        = _funcionamiento;
    _os['puntos_apoyo']          = _puntosApoyo;
    _os['geometria_excentricidad'] = _geometriaExcentricidad;
    _os['geometria_plataforma']    = _geometriaExcentricidad;
    _os['num_secciones']           = _numSeccionesExc;
    _os['secciones_camionera']     = _numSeccionesExc;
    _os['unidad_medida']         = _unidadMedida;
    _os['capacidad_max']         = _capMaxCtrl.text.trim();
    _os['division_minima']       = divNorm;

    // Números regulatorios independientes CCA y DVE: se preservan siempre que se capturen
    final ccaClean = _ccaEf;
    final numDveClean = _numeroDveEf;
    _os['numero_cca'] = ccaClean;
    _os['cca']        = ccaClean;
    _os['cca_aplica'] = rules.tieneCalibracion || ccaClean.isNotEmpty;
    _os['numero_dve'] = numDveClean;
    _os['folio_dve']  = numDveClean;

    if (rules.tieneInspeccion || numDveClean.isNotEmpty) {
      _os['holograma_anterior']    = _holoAntCtrl.text.trim();
      _os['holograma_actualizado'] = _holoActCtrl.text.trim();
      _os['div_verificacion']      = double.tryParse(_divVerCtrl.text.replaceAll(',', '.'));
    } else {
      _os['holograma_anterior']    = '';
      _os['holograma_actualizado'] = '';
      _os['holograma_nuevo']       = '';
      _os['div_ver']               = '';
      _os['div_verificacion']      = null;
    }
    // Sustitución opcional: vacío / 0 / "No" ⇒ aplica_sustitucion=false, peso=null.
    if (_aplicaSustitucion) {
      _os['masa_patron_disponible'] = _pesoSustituto;
      _os['peso_sustituto']         = _pesoSustituto;
      _os['factor_sustitucion']     = _factorSustituto;
    } else {
      _os['masa_patron_disponible'] = null;
      _os['peso_sustituto']         = null;
      _os['factor_sustitucion']     = null;
    }
    _os['sustitutos']             = _sustitutosRows;
    _os['aplica_sustituto']       = _hasValidSustitutos;

    final maxV = double.tryParse(_capMaxCtrl.text.replaceAll(',', '.'));
    final divV = double.tryParse(_divMinCtrl.text.replaceAll(',', '.'));
    if (maxV != null) _os['alcance_max'] = maxV;
    if (divV != null) _os['div_minima']  = divV;
    // Nombre del cliente — siempre persiste en el mapa
    _os['firma_cliente_nombre'] = _firmaClienteNombreCtrl.text.trim();
  }

  Future<void> _mostrarDialogoSalida(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.save_outlined, color: Color(0xFFC8102E), size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '¿Guardar en borrador?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          '¿Deseas guardar en borrador antes de salir?\n\n'
          '• [Sí, Guardar Borrador]: Guarda tu avance localmente y sale.\n'
          '• [No]: Descarta los cambios no guardados y sale.\n'
          '• [Cancelar]: Permanece en la pantalla de captura.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop(); // Cierra únicamente el modal
            },
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop(); // Cierra el modal
              _permitirSalida = true;
              if (context.mounted) {
                Navigator.of(context).pop(); // Sale sin persistir cambios
              }
            },
            child: const Text('No (Descartar)', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A7F64),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              await _guardarBorrador(mostrarSnackbar: false);
              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop(); // Cierra el modal
              }
              _permitirSalida = true;
              if (context.mounted) {
                Navigator.of(context).pop(); // Sale al Dashboard con datos guardados
              }
            },
            child: const Text('Sí, Guardar Borrador'),
          ),
        ],
      ),
    );
  }

  Future<void> _guardarBorrador({bool mostrarSnackbar = true}) async {
    _guardarDatosInstrumento();
    final rules = _rules;
    final folio = (_os['folio_os'] ?? widget.osData['folio_os'] ?? widget.osId.toString()).toString().trim();
    setState(() => _saving = true);
    try {
      final draftMap = <String, dynamic>{
        'folio_os':              folio,
        'marca':                 _marcaCtrl.text.trim(),
        'modelo':                _modeloCtrl.text.trim(),
        'ns':                    _nsCtrl.text.trim(),
        'serie':                 _nsCtrl.text.trim(),
        'id_equipo':             _idEquipoCtrl.text.trim(),
        'id_indicador':          _idEquipoCtrl.text.trim(),
        'ubicacion':             _ubicCtrl.text.trim(),
        'cap_max':               _capMaxCtrl.text.trim(),
        'capacidad_max':         _capMaxCtrl.text.trim(),
        'div_min':               formatearDivisionMinima(_divMinCtrl.text.trim()),
        'division_minima':       formatearDivisionMinima(_divMinCtrl.text.trim()),
        'div_ver':               _dveEf,
        'div_verificacion':      _dveEf,
        'folio_dve':             _numeroDveEf,
        'numero_dve':            _numeroDveEf,
        'numero_cca':            _ccaEf,
        'cca':                   _ccaEf,
        'cca_aplica':            rules.tieneCalibracion || _ccaEf.isNotEmpty,
        'calibrado_por':         _os['calibrado_por'] ?? 'PESA BÁSCULAS',
        'holograma_anterior':    _holoAntEf,
        'holograma_actualizado': _holoActEf,
        'holograma_nuevo':       _holoActEf,
        'tipo_instrumento':      _tipoInstrumento,
        'funcionamiento':        _funcionamiento,
        'puntos_apoyo':          _puntosApoyo,
        'geometria_excentricidad': _geometriaExcentricidad,
        'geometria_plataforma':    _geometriaExcentricidad,
        'num_secciones':           _numSeccionesExc,
        'secciones_camionera':     _numSeccionesExc,
        'unidad_medida':         _unidadMedida,
        'jia_j':                 _jEf,
        'jia_i':                 _iEf,
        'jia_a':                 _aEf,
        'aplica_excentricidad':  _aplExc,
        'apl_exc_override':      _aplExcOverride,
        'motivo_no_excentricidad': _aplExc ? '' : _motivoNoExcentricidad,
        'tipo_no_apto':            _aplExc ? '' : _motivoNoExcentricidad,
        'motivo_no_aplica':        _aplExc ? '' : _motivoNoExcentricidad,
        'tipo_no_aplica_exc':      _aplExc ? null : _motivoNoExcentricidad.toLowerCase(),
        'usa_sustitucion':       _usaSustitucion,
        'aplica_sustituto':      _hasValidSustitutos,
        'sustitutos':            _sustitutosRows,
        'masa_patron':           _masaPatronCtrl.text.trim(),
        'factor_sustitucion':    _factorSustCtrl.text.trim(),
        'rep_rows':              _repRows,
        'exc_rows':              _excRows,
        'exac_rows':             _exacRows,
        'observaciones':         _obsCtrl.text.trim(),
        'firma_cliente_nombre':  _firmaClienteNombreCtrl.text.trim(),
        'dictamen':              _dictamen,
      };

      await LocalDbService.instance.saveDraft(folio, draftMap);

      await LocalDbService.instance.saveLecturas(
        localId:              widget.osId,
        repRows:              _repRows,
        excRows:              _excRows,
        exacRows:             _exacRows,
        observaciones:        _obsCtrl.text.trim(),
        firmaClienteNombre:   _firmaClienteNombreCtrl.text.trim(),
        isDraft:              true,
        instrumentData:       _os,
        unidadMedida:         _unidadMedida,
      );

      // Guardar contacto asociado a la planta/cliente para memoria futura
      final nomCli = _firmaClienteNombreCtrl.text.trim();
      if (nomCli.isNotEmpty) {
        final cli = (_os['cliente'] ?? _os['cliente_nombre'] ?? widget.osData['cliente'] ?? '').toString();
        final pla = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? widget.osData['direccion'] ?? '').toString();
        LocalDbService.instance.saveContactoPlanta(cliente: cli, planta: pla, nombreContacto: nomCli);
      }
      if (mounted && mostrarSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Borrador guardado ✓'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('[Captura] Error guardando borrador: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _irAFirma(String folio) async {
    _guardarDatosInstrumento();
    final rules = _rules;

    // ── CANDADO POR FORMATO ────────────────────────────────────────────────
    //  • Orden de Servicio: 6 campos obligatorios del instrumento.
    //  • Revisión de Celdas: solo identificación del instrumento.
    //  • Remisión: solo datos comerciales/operativos (sin candado metrológico).
    final List<String> faltantes = [];
    if (!rules.esRemision) {
      if (_marcaCtrl.text.trim().isEmpty)    faltantes.add('Marca');
      if (_modeloCtrl.text.trim().isEmpty)   faltantes.add('Modelo');
      if (_idEquipoCtrl.text.trim().isEmpty) faltantes.add('ID Indicador / Equipo');
    }
    if (!rules.esRemision && !rules.esRevisionCeldas) {
      if (_capMaxCtrl.text.trim().isEmpty)   faltantes.add('Capacidad Máxima');
      if (_divMinCtrl.text.trim().isEmpty)   faltantes.add('División Mínima (d)');
      if (_ubicCtrl.text.trim().isEmpty)     faltantes.add('Ubicación');
    }

    if (faltantes.isNotEmpty) {
      setState(() => _mostrarErroresInstrumento = true);
      _tabCtrl.animateTo(0);
      await _mostrarDialogoCandadoInstrumento(faltantes);
      return;
    }

    // ── Validaciones metrológicas de división mínima (d) ───────────────
    // La exactitud se valida solo con las cargas patrón capturadas; la
    // sustitución (opcional) no interviene en esta validación.
    final d = rules.esRemision ? null : _dValue;
    if (d != null && d > 0) {
      for (int i = 0; i < _repRows.length; i++) {
        final r = _repRows[i];
        for (final k in ['valor_kg', 'lectura_inicial', 'lectura_final']) {
          final s = r[k]?.toString().trim() ?? '';
          if (s.isEmpty) continue;
          final v = double.tryParse(s.replaceAll(',', '.'));
          if (v != null && v > 0 && !isValidDivMin(v, d)) {
            _tabCtrl.animateTo(1);
            _showError('Repetibilidad (Fila ${i + 1}): El valor $v debe ser múltiplo de la división mínima ($d).');
            return;
          }
        }
      }
      if (_aplExc) {
        for (int i = 0; i < _excRows.length; i++) {
          final r = _excRows[i];
          for (final k in ['carga_kg', 'carga', 'lectura_inicial', 'lectura_final']) {
            final s = r[k]?.toString().trim() ?? '';
            if (s.isEmpty) continue;
            final v = double.tryParse(s.replaceAll(',', '.'));
            if (v != null && v > 0 && !isValidDivMin(v, d)) {
              _tabCtrl.animateTo(2);
              _showError('Excentricidad (${r['posicion'] ?? r['posicion_nombre'] ?? 'Pos ${i + 1}'}): El valor $v debe ser múltiplo de la división mínima ($d).');
              return;
            }
          }
        }
      }
      for (int i = 0; i < _exacRows.length; i++) {
        final r = _exacRows[i];
        for (final k in ['carga_patron', 'lectura_subida', 'lectura_bajada']) {
          final s = r[k]?.toString().trim() ?? '';
          if (s.isEmpty) continue;
          final v = double.tryParse(s.replaceAll(',', '.'));
          if (v != null && v > 0 && !isValidDivMin(v, d)) {
            _tabCtrl.animateTo(3);
            _showError('Exactitud (Punto ${i + 1}): El valor $v debe ser múltiplo de la división mínima ($d).');
            return;
          }
        }
      }
    }

    // ── Validaciones obligatorias de servicio (solo si la sección aplica) ──
    //  !_aplicaCCA → se omiten "Número de CCA" e "Inicial del Calibrador".
    //  !_aplicaDVE → se omiten "División de Verificación" y hologramas.
    if (_aplicaCCA && _ccaEf.isEmpty) {
      _tabCtrl.animateTo(0);
      _showError('Ingresa el Número de CCA completo (ej: ${_prefijoCca}001).');
      return;
    }
    if (_aplicaDVE && !_aplicaCCA && _numeroDveEf.isEmpty) {
      _tabCtrl.animateTo(0);
      _showError('Ingresa el Número de DVE completo (ej: ${_prefijoDve}001).');
      return;
    }
    if (_aplicaDVE && _holoAntCtrl.text.trim().isEmpty) {
      _tabCtrl.animateTo(0);
      _showError('El Holograma Anterior es obligatorio para este tipo de servicio.');
      return;
    }
    if (_aplicaCCA && rules.pideInicialJia && !_jChecked && !_iChecked && !_aChecked) {
      _tabCtrl.animateTo(0);
      _showError('Selecciona la Inicial del Calibrador (J, I o A).');
      return;
    }

    // Nombre del cliente — si no se ingresó, usar el cliente de la OS para no bloquear
    String nombreCliente = _firmaClienteNombreCtrl.text.trim();
    if (nombreCliente.isEmpty) {
      nombreCliente = _os['cliente']?.toString().trim() ?? 'Cliente en Sitio';
      if (nombreCliente.isEmpty) nombreCliente = 'Cliente en Sitio';
      _firmaClienteNombreCtrl.text = nombreCliente;
      _showInfo('Se asignó "$nombreCliente" como receptor.');
    }

    await _guardarBorrador(mostrarSnackbar: false);

    final nomCli = _firmaClienteNombreCtrl.text.trim();
    if (nomCli.isNotEmpty) {
      final cli = (_os['cliente'] ?? _os['cliente_nombre'] ?? widget.osData['cliente'] ?? '').toString();
      final pla = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? widget.osData['direccion'] ?? '').toString();
      LocalDbService.instance.saveContactoPlanta(cliente: cli, planta: pla, nombreContacto: nomCli);
    }

    final String fechaActual = (_os['fecha'] != null && _os['fecha'].toString().isNotEmpty && _os['fecha'].toString() != 'null')
        ? _os['fecha'].toString().split(' ')[0]
        : DateTime.now().toIso8601String().substring(0, 10);
    final String clienteFinal = (_os['cliente'] ?? _os['cliente_nombre'] ?? _os['razon_social'] ?? '').toString();
    String direccionFinal = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? _os['sucursal_nombre'] ?? '').toString().trim();
    if (direccionFinal.isEmpty || direccionFinal == '-') {
      final histDir = await LocalDbService.instance.getDireccionCliente(clienteFinal);
      if (histDir != null && histDir.isNotEmpty) {
        direccionFinal = histDir;
      }
    }

    if (mounted) {
      context.push('/firma/${widget.osId}', extra: {
        ..._os,
        'folio_os':              folio,
        'tecnico':               _os['tecnico'] ?? '',
        'tecnico_nombre':        _os['tecnico_nombre'] ?? _os['tecnico'] ?? '',
        'cliente':               clienteFinal,
        'cliente_nombre':        clienteFinal,
        'direccion':             direccionFinal,
        'direccion_cliente':     direccionFinal,
        'sucursal':              _os['sucursal'] ?? direccionFinal,
        'fecha':                 fechaActual,
        'fecha_servicio':        fechaActual,
        'rep_rows':              _repRows,
        'exc_rows':              _excRows,
        'exac_rows':             _exacRows,
        'observaciones':         _obsCtrl.text.trim(),
        'firma_cliente_nombre':  nombreCliente,
        'nombre_ing':            nombreCliente,
        'dictamen':              _dictamen,
        'jia_j':                 _jEf,
        'jia_i':                 _iEf,
        'jia_a':                 _aEf,
        'marca':                 _marcaCtrl.text.trim(),
        'equipo_marca':          _marcaCtrl.text.trim(),
        'modelo':                _modeloCtrl.text.trim(),
        'equipo_modelo':         _modeloCtrl.text.trim(),
        'ns':                    _nsCtrl.text.trim(),
        'serie':                 _nsCtrl.text.trim(),
        'equipo_ns':             _nsCtrl.text.trim(),
        'id_equipo':             _idEquipoCtrl.text.trim(),
        'id_indicador':          _idEquipoCtrl.text.trim(),
        'ubicacion':             _ubicCtrl.text.trim(),
        'equipo_ubicacion':      _ubicCtrl.text.trim(),
        'capacidad_max':         _capMaxCtrl.text.trim(),
        'alcance_max':           _capMaxCtrl.text.trim(),
        'equipo_alcance':        _capMaxCtrl.text.trim(),
        'division_minima':       formatearDivisionMinima(_divMinCtrl.text.trim()),
        'div_minima':            formatearDivisionMinima(_divMinCtrl.text.trim()),
        'equipo_division':       formatearDivisionMinima(_divMinCtrl.text.trim()),
        'div_verificacion':      _dveEf,
        'div_ver':               _dveEf,
        'folio_dve':             _numeroDveEf,
        'numero_dve':            _numeroDveEf,
        'numero_cca':            _ccaEf,
        'cca':                   _ccaEf,
        'cca_aplica':            _aplicaCCA || _ccaEf.isNotEmpty,
        'aplica_cca':            _aplicaCCA || _ccaEf.isNotEmpty,
        'aplica_dve':            _aplicaDVE || _numeroDveEf.isNotEmpty,
        'calibrado_por':         _os['calibrado_por'] ?? 'PESA BÁSCULAS',
        'unidad_medida':         _unidadMedida,
        'holograma_anterior':    _holoAntEf,
        'holograma_actualizado': _holoActEf,
        'holograma_nuevo':       _holoActEf,
        'usa_sustitucion':       _aplicaSustitucion,
        'aplica_sustitucion':    _aplicaSustitucion,
        'aplica_sustituto':      _hasValidSustitutos,
        'sustitutos':            _sustitutosRows,
        'peso_sustituto':        _aplicaSustitucion ? _pesoSustituto : null,
        'factor_sustitucion':    _aplicaSustitucion ? _factorSustituto : null,
        'tipo_instrumento':      _tipoInstrumento ?? '',
        'tipo_servicio':         _os['tipo_servicio'] ?? '',
        'funcionamiento':        _funcionamiento,
        'puntos_apoyo':          _puntosApoyo,
        'geometria_excentricidad': _geometriaExcentricidad,
        'geometria_plataforma':    _geometriaExcentricidad,
        'num_secciones':           _numSeccionesExc,
        'secciones_camionera':     _numSeccionesExc,
        'aplica_excentricidad':  _aplExc,
        'motivo_no_excentricidad': _aplExc ? '' : _motivoNoExcentricidad,
        'tipo_no_apto':            _aplExc ? '' : _motivoNoExcentricidad,
        'motivo_no_aplica':        _aplExc ? '' : _motivoNoExcentricidad,
        'tipo_no_aplica_exc':      _aplExc ? null : _motivoNoExcentricidad.toLowerCase(),
      });
    }
  }

  Future<void> _mostrarDialogoCandadoInstrumento(List<String> faltantes) async {
    final listaStr = faltantes.map((f) => '• $f').join('\n');
    _showError('Faltan datos obligatorios del instrumento: ${faltantes.join(", ")}');
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: _kRed, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Datos Obligatorios Incompletos',
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
              backgroundColor: _kRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Completar Datos'),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 4),
    ));
  }

  void _showInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF2563EB),
      duration: const Duration(seconds: 3),
    ));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _str(String k) => _os[k]?.toString() ?? '';
  bool _asBool(dynamic v) {
    if (v == null)   return false;
    if (v is bool)   return v;
    if (v is int)    return v == 1;
    if (v is String) {
      final s = v.toLowerCase();
      return s == '1' || s == 'true' || s == 'si' || s == 'sí';
    }
    return false;
  }
  dynamic _jsonSafe(String s) {
    try { return jsonDecode(s); } catch (_) { return []; }
  }
}

// ── Widget: Banner de tipo de servicio ────────────────────────────────────
class _ServicioBanner extends StatelessWidget {
  final ServiceRules rules;
  final String?      tipoServicioNombre;
  const _ServicioBanner({required this.rules, this.tipoServicioNombre});

  @override
  Widget build(BuildContext context) {
    final nombreReal = (tipoServicioNombre ?? '').trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: rules.sinTipo ? const Color(0xFF94A3B8) : const Color(0xFFE2E8F0)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(rules.sinTipo ? Icons.warning_amber_rounded : Icons.rule, size: 18,
            color: rules.sinTipo ? const Color(0xFFC8102E) : _kRed),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tipo de Servicio: ${rules.etiquetaLarga}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A)),
            ),
            if (nombreReal.isNotEmpty && nombreReal != rules.etiquetaLarga)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Asignado por logística: $nombreReal',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
              ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              if (rules.esRemision)
                const _Badge('Remisión — solo datos operativos', Color(0xFF0F172A)),
              if (rules.esRevisionCeldas)
                const _Badge('Revisión de Celdas', Color(0xFF0F172A)),
              if (rules.tieneCalibracion)
                const _Badge('CCA requerido', Color(0xFF0F172A)),
              if (rules.tieneInspeccion)
                const _Badge('Hologramas + DVE', Color(0xFF0F172A)),
              if (rules.sinTipo)
                const _Badge('Sin tipo — sincroniza antes de capturar', Color(0xFF334155))
              else if (rules.esSoloAjuste && !rules.esRemision && !rules.esRevisionCeldas)
                const _Badge('Solo Ajuste — sin CCA ni DVE', Color(0xFF475569)),
            ]),
          ],
        )),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color  color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      border: Border.all(color: const Color(0xFFCBD5E1)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: TextStyle(fontSize: 10, color: color,
        fontWeight: FontWeight.w700)),
  );
}

// ── Widgets de formulario ─────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800,
          color: Color(0xFF374151), letterSpacing: 0.5));
}

class _EquipoHistorialAutocomplete extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final FocusNode focusNode;
  final String fieldKey;
  final List<Map<String, dynamic>> historial;
  final List<String> fallbackStrings;
  final String? hint;
  final bool required;
  final bool hasError;
  final ValueChanged<String>? onChanged;
  final ValueChanged<Map<String, dynamic>> onSelectedInstrument;

  const _EquipoHistorialAutocomplete({
    required this.label,
    required this.ctrl,
    required this.focusNode,
    required this.fieldKey,
    required this.historial,
    required this.fallbackStrings,
    required this.onSelectedInstrument,
    this.hint,
    this.required = false,
    this.hasError = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Map<String, dynamic>>(
      textEditingController: ctrl,
      focusNode: focusNode,
      displayStringForOption: (opt) => (opt[fieldKey] ?? '').toString(),
      optionsBuilder: (TextEditingValue tev) {
        final q = LocalDbService.normalizarTexto(tev.text);
        final out = <Map<String, dynamic>>[];
        final seen = <String>{};

        for (final inst in historial) {
          final v = (inst[fieldKey] ?? '').toString().trim();
          if (v.isEmpty) continue;
          final blob = LocalDbService.normalizarTexto(
            '${inst['marca']} ${inst['modelo']} ${inst['serie']} ${inst['id_indicador']} ${inst['ubicacion']}',
          );
          if (q.isEmpty || blob.contains(q)) {
            final key = '${inst['marca']}|${inst['modelo']}|${inst['serie']}|${inst['id_indicador']}|${inst['ubicacion']}'.toLowerCase();
            if (seen.add(key)) out.add(inst);
          }
          if (out.length >= 16) break;
        }

        if (out.length < 16 && fallbackStrings.isNotEmpty) {
          for (final s in fallbackStrings) {
            final st = s.trim();
            if (st.isEmpty) continue;
            if (q.isEmpty || LocalDbService.normalizarTexto(st).contains(q)) {
              final key = '$fieldKey:$st'.toLowerCase();
              if (seen.add(key)) {
                out.add({fieldKey: st});
              }
            }
            if (out.length >= 16) break;
          }
        }
        return out;
      },
      onSelected: (Map<String, dynamic> selection) {
        final v = (selection[fieldKey] ?? '').toString().trim();
        if (v.isNotEmpty) ctrl.text = v;
        onSelectedInstrument(selection);
      },
      optionsViewBuilder: (context, onSelect, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6.0,
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF3F4F6)),
                itemBuilder: (BuildContext context, int index) {
                  final opt = options.elementAt(index);
                  final titleParts = [
                    opt['marca'],
                    opt['modelo'],
                    if ((opt['serie'] ?? '').toString().trim().isNotEmpty) 'SN: ${opt['serie']}',
                    if ((opt['id_indicador'] ?? '').toString().trim().isNotEmpty) 'ID: ${opt['id_indicador']}',
                  ].where((e) => e != null && e.toString().trim().isNotEmpty).join(' • ');
                  final subParts = [
                    if ((opt['ubicacion'] ?? '').toString().trim().isNotEmpty) opt['ubicacion'],
                    if ((opt['capacidad_maxima'] ?? '').toString().trim().isNotEmpty) 'Cap: ${opt['capacidad_maxima']}',
                    if ((opt['division_minima'] ?? '').toString().trim().isNotEmpty) 'd: ${opt['division_minima']}',
                  ].join(' · ');

                  return InkWell(
                    onTap: () => onSelect(opt),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titleParts.isNotEmpty ? titleParts : (opt[fieldKey] ?? '').toString(),
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.black87),
                          ),
                          if (subParts.isNotEmpty)
                            Text(
                              subParts,
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
      fieldViewBuilder: (context, controller, fNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: fNode,
          onChanged: onChanged,
          decoration: _kInputDeco(label + (required ? ' *' : ''), hint: hint, hasError: hasError),
          style: const TextStyle(fontSize: 13),
        );
      },
    );
  }
}

class _AutocompleteField extends StatelessWidget {
  final String                label;
  final TextEditingController ctrl;
  final FocusNode             focusNode;
  final List<String>          suggestions;
  final String?               hint;
  final bool                  required;
  final bool                  hasError;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSelected;

  const _AutocompleteField({
    required this.label,
    required this.ctrl,
    required this.focusNode,
    required this.suggestions,
    this.hint,
    this.required = false,
    this.hasError = false,
    this.onChanged,
    this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: ctrl,
      focusNode: focusNode,
      optionsBuilder: (TextEditingValue textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) {
          return suggestions.take(15);
        }
        return suggestions
            .where((s) => s.toLowerCase().contains(query))
            .take(15);
      },
      onSelected: (String selection) {
        ctrl.text = selection;
        onSelected?.call(selection);
      },
      optionsViewBuilder: (context, onSelect, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6.0,
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF3F4F6)),
                itemBuilder: (BuildContext context, int index) {
                  final String option = options.elementAt(index);
                  return InkWell(
                    onTap: () => onSelect(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Text(
                        option,
                        style: const TextStyle(fontSize: 13, color: Colors.black87),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
      fieldViewBuilder: (context, controller, fNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: fNode,
          onChanged: onChanged,
          decoration: _kInputDeco(label + (required ? ' *' : ''), hint: hint, hasError: hasError),
          style: const TextStyle(fontSize: 13),
        );
      },
    );
  }
}

/// Formateador que protege el prefijo del Certificado de Calibración o Dictamen (ej. "CCA.26." / "DVE.26.")
class CcaDvePrefixFormatter extends TextInputFormatter {
  final String defaultPrefix;

  CcaDvePrefixFormatter({required this.defaultPrefix});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final matchOld = RegExp(r'^(CCA|DVE)\.\d{2}\.').firstMatch(oldValue.text);
    final matchNew = RegExp(r'^(CCA|DVE)\.\d{2}\.').firstMatch(newValue.text);

    String prefix = defaultPrefix;
    if (matchOld != null) {
      prefix = matchOld.group(0)!;
    } else if (matchNew != null) {
      prefix = matchNew.group(0)!;
    }

    if (newValue.text.isEmpty) {
      return TextEditingValue(
        text: prefix,
        selection: TextSelection.collapsed(offset: prefix.length),
      );
    }

    if (newValue.text.startsWith(prefix)) {
      if (newValue.selection.baseOffset < prefix.length) {
        return newValue.copyWith(
          selection: TextSelection.collapsed(offset: prefix.length),
        );
      }
      return newValue;
    }

    String cleanContent = newValue.text.toUpperCase();
    if (cleanContent.startsWith('CCA') || cleanContent.startsWith('DVE')) {
      cleanContent = cleanContent.replaceFirst(RegExp(r'^(CCA|DVE)(\.\d{0,2})?\.?'), '');
    }
    if (cleanContent.isEmpty) {
      if (oldValue.text.startsWith(prefix) &&
          oldValue.text.length > prefix.length &&
          oldValue.selection.baseOffset > prefix.length) {
        cleanContent = oldValue.text.substring(prefix.length);
      }
    }

    final newText = '$prefix$cleanContent';
    final offset = (newValue.selection.baseOffset < prefix.length)
        ? prefix.length
        : (newValue.selection.baseOffset > newText.length ? newText.length : newValue.selection.baseOffset);

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

class _Field extends StatelessWidget {
  final String                  label;
  final TextEditingController   ctrl;
  final String?                 hint;
  final bool                    required;
  final bool                    hasError;
  final ValueChanged<String>?   onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputType?          keyboardType;
  final TextCapitalization      textCapitalization;
  const _Field(
    this.label,
    this.ctrl, {
    this.hint,
    this.required = false,
    this.hasError = false,
    this.onChanged,
    this.inputFormatters,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    onChanged: onChanged,
    inputFormatters: inputFormatters,
    keyboardType: keyboardType,
    textCapitalization: textCapitalization,
    decoration: _kInputDeco(label + (required ? ' *' : ''), hint: hint, hasError: hasError),
    style: const TextStyle(fontSize: 13),
  );
}

class _NumField extends StatelessWidget {
  final String                  label;
  final TextEditingController   ctrl;
  final ValueChanged<String>?   onChanged;
  final bool                    hasError;
  const _NumField(this.label, this.ctrl, {this.onChanged, this.hasError = false});

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    onChanged: onChanged,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
    decoration: _kInputDeco(label, hasError: hasError),
    style: const TextStyle(fontSize: 13),
  );
}

class _JiaToggle extends StatelessWidget {
  final String             label;
  final bool               val;
  final ValueChanged<bool> onChanged;
  const _JiaToggle(this.label, this.val, this.onChanged);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => onChanged(!val),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: val ? _kRed : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(
          color: val ? Colors.white : Colors.grey.shade700,
          fontWeight: FontWeight.w800, fontSize: 14)),
    ),
  );
}

InputDecoration _kInputDeco(String label, {String? hint, bool hasError = false}) => InputDecoration(
  labelText: label,
  hintText:  hint,
  hintStyle: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 12),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(
      color: hasError ? const Color(0xFFC8102E) : const Color(0xFFE5E7EB),
      width: hasError ? 2.0 : 1.0,
    ),
  ),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(
      color: hasError ? const Color(0xFFC8102E) : const Color(0xFFE5E7EB),
      width: hasError ? 2.0 : 1.0,
    ),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: _kRed, width: 2),
  ),
  isDense:    true,
  filled:     true,
  fillColor:  hasError ? const Color(0xFFFFEBEE) : Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
);