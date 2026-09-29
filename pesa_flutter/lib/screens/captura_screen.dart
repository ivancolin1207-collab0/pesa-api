// lib/screens/captura_screen.dart — Captura metrológica digital interactiva
// v4.0: Lógica condicional estricta NOM-010-SCFI-2020 (lookup dual ID+nombre)
//       DVE dentro de sección Inspección · Precarga completa desde OS backend
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../services/local_db_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../services/metrology_helper.dart';
import '../widgets/repetibilidad_table.dart';
import '../widgets/excentricidad_table.dart';
import '../widgets/exactitud_table.dart';
import '../widgets/sync_check_badge.dart';

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

  // ── Reglas metrológicas (lookup dual ID + nombre) ─────────────────────────
  ServiceRules get _rules => getRules(
    id: _os['id_tipo_servicio'] as int?
        ?? _os['tipo_servicio_id'] as int?,
    nombre: _os['tipo_servicio'] as String?,
  );

  // ── Controladores Paso 0 — Instrumento ───────────────────────────────────
  final _marcaCtrl      = TextEditingController();
  final _modeloCtrl     = TextEditingController();
  final _nsCtrl         = TextEditingController();
  final _idEquipoCtrl   = TextEditingController();
  final _capMaxCtrl     = TextEditingController();
  final _divMinCtrl     = TextEditingController();
  final _divVerCtrl     = TextEditingController(); // DVE — solo en Inspección
  final _ubicCtrl       = TextEditingController();
  final _ccaCtrl        = TextEditingController();
  final _holoAntCtrl    = TextEditingController();
  final _holoActCtrl    = TextEditingController();
  final _masaPatronCtrl = TextEditingController();
  final _factorSustCtrl = TextEditingController();

  String? _tipoInstrumento;
  String  _funcionamiento = 'Electrónico'; // nuevo campo
  int     _puntosApoyo    = 4;               // nuevo campo
  String  _unidadMedida   = 'kg';            // selector 'kg' o 'g'
  bool    _jChecked = false, _iChecked = false, _aChecked = false;
  bool    _usaSustitucion = false;
  bool?   _aplExcOverride;  // null = auto-determinar por instrumento

  // ── Lecturas de medición ─────────────────────────────────────────────────
  List<Map<String, dynamic>> _repRows  = [];
  List<Map<String, dynamic>> _excRows  = [];
  List<Map<String, dynamic>> _exacRows = [];
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
    _os = Map<String, dynamic>.from(widget.osData);
    _precargaCampos();
    _loadLocalData();
  }

  /// Precarga TODOS los campos del instrumento con datos que ya vienen
  /// asignados desde Logística / Backend al crear la OS.
  void _precargaCampos() {
    _marcaCtrl.text      = _str('marca');
    _modeloCtrl.text     = _str('modelo');
    // ns / serie: varios alias posibles
    _nsCtrl.text         = _str('ns').isNotEmpty ? _str('ns') : _str('serie');
    _idEquipoCtrl.text   = _str('id_equipo');
    _ubicCtrl.text       = _str('ubicacion');
    _ccaCtrl.text        = _str('numero_cca');
    _holoAntCtrl.text    = _str('holograma_anterior');
    _holoActCtrl.text    = _str('holograma_actualizado');

    // Capacidad máxima — fallback a string si numérico es null
    final max = _os['alcance_max'] ?? _os['capacidad_maxima'];
    final div = _os['div_minima']  ?? _os['division_minima'];
    final dve = _os['div_verificacion'];
    if (max != null) {
      _capMaxCtrl.text = max.toString();
    } else {
      // Fallback: instrumento_capacidad puede ser "75000 kg"
      final capStr = _str('instrumento_capacidad');
      if (capStr.isNotEmpty) {
        _capMaxCtrl.text = capStr.replaceAll(RegExp(r'[^0-9.]'), '').trim();
      }
    }
    if (div != null) {
      _divMinCtrl.text = div.toString();
    } else {
      final divStr = _str('instrumento_division');
      if (divStr.isNotEmpty) {
        _divMinCtrl.text = divStr.replaceAll(RegExp(r'[^0-9.]'), '').trim();
      }
    }
    if (dve != null) _divVerCtrl.text = dve.toString();

    // Tipo de instrumento
    final ti = _str('tipo_instrumento');
    if (ti.isNotEmpty && _tiposInstrumento.contains(ti)) {
      _tipoInstrumento = ti;
    } else if (ti.toLowerCase().contains('camion') ||
               ti.toLowerCase().contains('puente')) {
      _tipoInstrumento = 'Báscula camionera';
    } else if (ti.toLowerCase().contains('ferrocarril') ||
               ti.toLowerCase().contains('ferrovi')) {
      _tipoInstrumento = 'Báscula de ferrocarril';
    } else if (ti.toLowerCase().contains('plataforma')) {
      _tipoInstrumento = 'Báscula de plataforma';
    } else if (ti.toLowerCase().contains('circular')) {
      _tipoInstrumento = 'Báscula circular';
    } else if (ti.toLowerCase().contains('tolva')) {
      _tipoInstrumento = 'Báscula tolva';
    }

    // Nuevos campos: Funcionamiento y Puntos de Apoyo
    final func = _str('funcionamiento');
    if (func.isNotEmpty) _funcionamiento = func;
    final pa = _os['puntos_apoyo'];
    if (pa != null && pa != 0 && pa != '') {
      _puntosApoyo = (pa is int) ? pa : int.tryParse(pa.toString()) ?? getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 4);
    } else {
      _puntosApoyo = getPuntosApoyoPorDefecto(_tipoInstrumento, fallback: 4);
    }

    // Secciones para camionera — guardadas en SQLite, disponibles vía _os map
    // No hay una variable _nSecciones local; la consumen los widgets hijos.

    // JIA — pueden venir como bool o int (SQLite)
    _jChecked = _asBool(_os['jia_j']);
    _iChecked = _asBool(_os['jia_i']);
    _aChecked = _asBool(_os['jia_a']);

    // Unidad de medida (kg / g)
    final u = _str('unidad_medida').toLowerCase();
    if (u == 'kg' || u == 'g') {
      _unidadMedida = u;
    }

    // Carga de sustitución: herencia estricta desde Logística
    _usaSustitucion = _asBool(_os['usa_sustitucion']) ||
                      _asBool(_os['es_sustitucion']) ||
                      _asBool(_os['es_enlace_sustitucion']);
  }

  /// Determina si aplica excentricidad:
  ///   1. Flag asignado por Logística (`aplica_excentricidad`)
  ///   2. Override manual si aplicara
  ///   3. Inferencia por tipo de instrumento
  bool get _aplExc {
    final raw = _os['aplica_excentricidad'];
    if (raw != null) {
      if (raw is bool)   return raw;
      if (raw is int)    return raw == 1;
      if (raw is String) {
        final s = raw.toLowerCase().trim();
        return s == '1' || s == 'true' || s == 'si' || s == 'sí';
      }
    }
    if (_aplExcOverride != null) return _aplExcOverride!;
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
    for (final c in [
      _marcaCtrl, _modeloCtrl, _nsCtrl, _idEquipoCtrl,
      _capMaxCtrl, _divMinCtrl, _divVerCtrl, _ubicCtrl,
      _ccaCtrl, _holoAntCtrl, _holoActCtrl,
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
            _divMinCtrl.text = draft['div_min'].toString();
            _os['div_minima'] = _divMinCtrl.text;
          }
          if (draft['div_ver'] != null && draft['div_ver'].toString().isNotEmpty) {
            _divVerCtrl.text = draft['div_ver'].toString();
            _os['div_verificacion'] = _divVerCtrl.text;
          }
          if (draft['numero_cca'] != null && draft['numero_cca'].toString().isNotEmpty) {
            _ccaCtrl.text = draft['numero_cca'].toString();
            _os['numero_cca'] = _ccaCtrl.text;
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
          if (draft['tipo_instrumento'] != null && draft['tipo_instrumento'].toString().isNotEmpty) {
            _tipoInstrumento = draft['tipo_instrumento'].toString();
            _os['tipo_instrumento'] = _tipoInstrumento;
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
            _aplExcOverride = draft['aplica_excentricidad'] == true;
          }
          if (draft['usa_sustitucion'] != null) {
            _usaSustitucion = draft['usa_sustitucion'] == true;
          }
          if (draft['unidad_medida'] != null && draft['unidad_medida'].toString().isNotEmpty) {
            _unidadMedida = draft['unidad_medida'].toString();
            _os['unidad_medida'] = _unidadMedida;
          }
          if (draft['dictamen'] != null) {
            _dictamen = draft['dictamen'].toString();
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
        setState(() {
          for (final k in saved.keys) {
            if (saved[k] != null && saved[k] != '') _os[k] = saved[k];
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
        });
        _precargaCampos();
      }
    }

    // 3. Contactos históricos para autocompletado y memoria por planta/cliente
    final String cliente = (_os['cliente'] ?? _os['cliente_nombre'] ?? widget.osData['cliente'] ?? '').toString();
    final String planta  = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? widget.osData['direccion'] ?? '').toString();
    final contactos = await LocalDbService.instance.getContactosPlanta(cliente: cliente, planta: planta);

    if (mounted) {
      setState(() {
        _contactosSugeridos = contactos;
        if (_firmaClienteNombreCtrl.text.trim().isEmpty && contactos.isNotEmpty) {
          _firmaClienteNombreCtrl.text = contactos.first;
          _os['firma_cliente_nombre'] = contactos.first;
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

    final folio   = _os['folio_os'] ?? widget.osId.toString();
    final nPuntos = (_os['num_puntos_exactitud'] as int?) ?? 10;
    final nCeldas = _os['num_celdas_camionera'] is int
        ? _os['num_celdas_camionera'] as int
        : int.tryParse(_os['num_celdas_camionera']?.toString() ?? '0') ?? 0;
    final bottom  = MediaQuery.of(context).viewPadding.bottom;

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
          backgroundColor: const Color(0xFFF5F5F7),
          appBar: AppBar(
            backgroundColor: _kDark,
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () async {
                await _mostrarDialogoSalida(context);
              },
            ),
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(folio, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              Text(_os['cliente'] ?? '',
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 14),
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
            bottom: TabBar(
              controller: _tabCtrl,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              tabs: const [
                Tab(text: 'Instrumento',   icon: Icon(Icons.scale,              size: 16)),
                Tab(text: 'Repetibilidad', icon: Icon(Icons.repeat,             size: 16)),
                Tab(text: 'Excentricidad', icon: Icon(Icons.center_focus_weak,  size: 16)),
                Tab(text: 'Exactitud',     icon: Icon(Icons.straighten,         size: 16)),
              ],
            ),
          ),
          body: Builder(
            builder: (ctx) {
              final isKeyboardOpen = MediaQuery.of(ctx).viewInsets.bottom > 100;
              final bool editingObs = _firmaClienteFocusNode.hasFocus || _obsFocusNode.hasFocus;

              return Column(children: [
                Expanded(
                  child: TabBarView(
                    controller: _tabCtrl,
                    children: [
                      _buildTabInstrumento(),
                      RepetibilidadTable(
                        key: ValueKey('rep_$_dataVersion'),
                        rows: _repRows,
                        divMin: _dValue,
                        onChanged: (r) => _repRows = r,
                      ),
                      _buildExcentricidadTab(nCeldas),
                      ExactitudTable(
                        key: ValueKey('exac_$_dataVersion'),
                        numPuntos: nPuntos,
                        rows: _exacRows,
                        divMin: _dValue,
                        onChanged: (r) => _exacRows = r,
                      ),
                    ],
                  ),
                ),
                if (!isKeyboardOpen || editingObs) _buildObsPanel(),
                if (!isKeyboardOpen)
                  Padding(
                    padding: EdgeInsets.only(bottom: bottom > 0 ? bottom : 16),
                    child: _buildActionBar(folio),
                  ),
              ]);
            },
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

        // ── Identificación del instrumento (siempre visible) ───────────────
        _SectionTitle('Identificación del Instrumento'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _Field(
            'Marca',
            _marcaCtrl,
            hint: 'METTLER TOLEDO',
            required: true,
            hasError: _mostrarErroresInstrumento && _marcaCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
          )),
          const SizedBox(width: 12),
          Expanded(child: _Field(
            'Modelo',
            _modeloCtrl,
            hint: 'IND560',
            required: true,
            hasError: _mostrarErroresInstrumento && _modeloCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
          )),
          const SizedBox(width: 12),
          Expanded(child: _Field('N° de Serie', _nsCtrl, hint: 'B215004321')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _Field(
            'ID Indicador / Equipo',
            _idEquipoCtrl,
            hint: 'Trailer A, Báscula 3...',
            required: true,
            hasError: _mostrarErroresInstrumento && _idEquipoCtrl.text.trim().isEmpty,
            onChanged: (_) { if (_mostrarErroresInstrumento) setState(() {}); },
          )),
          const SizedBox(width: 12),
          Expanded(child: _Field(
            'Ubicación',
            _ubicCtrl,
            hint: 'Planta Norte',
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
            _puntosApoyo = getPuntosApoyoPorDefecto(v, fallback: _puntosApoyo);
            _os['puntos_apoyo'] = _puntosApoyo;
            _dataVersion++;
            // Recalcular excentricidad si no hay override manual
            if (_aplExcOverride == null) setState(() {});
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

        // ¿Aplica Excentricidad? — Solo lectura preestablecido desde Logística
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade200)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                            ? 'Sí — Configurado por Logística'
                            : 'No — Configurado por Logística',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _aplExc ? const Color(0xFFFEE2E2) : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _aplExc ? _kRed.withValues(alpha: 0.3) : Colors.grey.shade300,
                    ),
                  ),
                  child: Text(
                    _aplExc ? 'SÍ APLICA' : 'NO APLICA',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _aplExc ? _kRed : Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── CASO B: Sección CCA (solo si incluye Calibración) ─────────────
        if (rules.tieneCalibracion) ...[
          _SectionTitle('Certificado de Calibración Acreditada (CCA)'),
          const SizedBox(height: 10),
          _Field('Número de CCA', _ccaCtrl,
              hint: 'CCA.26.001', required: true),
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
          const SizedBox(height: 16),
        ],

        // ── CASO C/D: Sección Inspección + DVE (solo si incluye Inspección) ─
        if (rules.tieneInspeccion) ...[
          _SectionTitle('Inspección / Verificación Metrológica'),
          const SizedBox(height: 10),
          // DVE va AQUÍ — dentro del bloque condicional de Inspección
          _NumField('DVE — Div. Verificación (kg)', _divVerCtrl),
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

        // ── Cargas de sustitución (solo si Logística la activó) ───────────
        if (_usaSustitucion) ...[
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.grey.shade200)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz, color: _kRed),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Carga de Sustitución',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Activada por Logística (cap. máx. excede patrón disponible)',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _kRed.withValues(alpha: 0.3)),
                    ),
                    child: const Text(
                      'ACTIVA',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _kRed),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _NumField('Masa Patrón Disponible ($_unidadMedida)', _masaPatronCtrl)),
            const SizedBox(width: 12),
            Expanded(child: _NumField('Factor Sustitución',          _factorSustCtrl)),
          ]),
          const SizedBox(height: 16),
        ],

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
        const SizedBox(height: 24),

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

  // ── Tab 2: Excentricidad ──────────────────────────────────────────────────
  Widget _buildExcentricidadTab(int nCeldas) {
    final nSecRaw = _os['num_secciones'] ?? _os['secciones'] ?? _os['num_secciones_camionera'];
    final nSec = (nSecRaw is int) ? nSecRaw : int.tryParse(nSecRaw?.toString() ?? '');
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: _aplExc ? Colors.green.shade50 : Colors.orange.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(_aplExc ? Icons.check_circle_outline : Icons.info_outline,
                  size: 16,
                  color: _aplExc ? Colors.green.shade700 : Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(child: Text(
                _aplExc
                    ? 'Excentricidad asignada por Logística — captura los valores de cada posición.'
                    : 'Excentricidad omitida por Logística. Marcada como No Aplica.',
                style: TextStyle(fontSize: 12,
                    color: _aplExc ? Colors.green.shade800 : Colors.orange.shade800),
              )),
            ]),
          ),
          ExcentricidadTable(
            key: ValueKey('exc_${_dataVersion}_$_tipoInstrumento'),
            numCeldas: nCeldas,
            numSecciones: nSec,
            rows: _excRows,
            divMin: _dValue,
            geometria: _os['geometria_plataforma'] as String?,
            tipoInstrumento: _tipoInstrumento,
            aplicaExcentricidad: _aplExc,
            onChanged: (r) => _excRows = r,
          ),
        ],
      ),
    );
  }

  // ── Panel observaciones + Nombre Cliente (obligatorio) ────────────────────
  Widget _buildObsPanel() {
    final nombreVacio = _firmaClienteNombreCtrl.text.trim().isEmpty;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: TextField(
            controller: _obsCtrl,
            focusNode: _obsFocusNode,
            decoration: const InputDecoration(
              labelText: 'Observaciones',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8))),
              isDense: true,
            ),
            maxLines: 1,
          )),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _dictamen,
            items: ['APTO', 'NO APTO', 'CONDICIONADO']
                .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                .toList(),
            onChanged: (v) => setState(() => _dictamen = v!),
          ),
        ]),
        const SizedBox(height: 8),
        // Nombre del cliente — OBLIGATORIO en Android y Windows con memoria y autocompletado por planta
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
          const SizedBox(height: 6),
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
      ]),
    );
  }

  // ── Barra de acciones ─────────────────────────────────────────────────────
  Widget _buildActionBar(String folio) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
      ),
      child: Row(children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.save_outlined),
          label: const Text('Guardar Borrador'),
          onPressed: () => _guardarBorrador(mostrarSnackbar: true),
        ),
        const Spacer(),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A7F64),
            disabledBackgroundColor: const Color(0xFF1A7F64),
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white,
            minimumSize: const Size(180, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: _saving
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.draw_outlined),
          label: const Text('Continuar → Firma',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          onPressed: _saving ? null : () => _irAFirma(folio),
        ),
      ]),
    );
  }

  // ── Lógica de guardado ────────────────────────────────────────────────────

  void _guardarDatosInstrumento() {
    final rules = _rules;
    _os['marca']                 = _marcaCtrl.text.trim();
    _os['modelo']                = _modeloCtrl.text.trim();
    _os['ns']                    = _nsCtrl.text.trim();
    _os['serie']                 = _nsCtrl.text.trim();
    _os['id_equipo']             = _idEquipoCtrl.text.trim();
    _os['id_indicador']          = _idEquipoCtrl.text.trim();
    _os['ubicacion']             = _ubicCtrl.text.trim();
    _os['tipo_instrumento']      = _tipoInstrumento;
    _os['jia_j']                 = _jChecked;
    _os['jia_i']                 = _iChecked;
    _os['jia_a']                 = _aChecked;
    _os['aplica_excentricidad']  = _aplExc;
    _os['usa_sustitucion']       = _usaSustitucion;
    _os['funcionamiento']        = _funcionamiento;
    _os['puntos_apoyo']          = _puntosApoyo;
    _os['unidad_medida']         = _unidadMedida;
    _os['capacidad_max']         = _capMaxCtrl.text.trim();
    _os['division_minima']       = _divMinCtrl.text.trim();

    // Solo guardar campos condicionales si aplican según las reglas activas
    if (rules.tieneCalibracion) {
      _os['numero_cca'] = _ccaCtrl.text.trim();
      _os['cca_aplica'] = true;
    }
    if (rules.tieneInspeccion) {
      _os['holograma_anterior']    = _holoAntCtrl.text.trim();
      _os['holograma_actualizado'] = _holoActCtrl.text.trim();
      _os['div_verificacion']      = double.tryParse(_divVerCtrl.text) ?? 0;
    }
    if (_usaSustitucion) {
      _os['masa_patron_disponible'] = double.tryParse(_masaPatronCtrl.text) ?? 0;
      _os['factor_sustitucion']     = double.tryParse(_factorSustCtrl.text) ?? 0;
    }

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
        'div_min':               _divMinCtrl.text.trim(),
        'division_minima':       _divMinCtrl.text.trim(),
        'div_ver':               _divVerCtrl.text.trim(),
        'numero_cca':            _ccaCtrl.text.trim(),
        'cca_aplica':            rules.tieneCalibracion || _ccaCtrl.text.trim().isNotEmpty,
        'calibrado_por':         _os['calibrado_por'] ?? 'PESA BÁSCULAS',
        'holograma_anterior':    _holoAntCtrl.text.trim(),
        'holograma_actualizado': _holoActCtrl.text.trim(),
        'tipo_instrumento':      _tipoInstrumento,
        'funcionamiento':        _funcionamiento,
        'puntos_apoyo':          _puntosApoyo,
        'unidad_medida':         _unidadMedida,
        'jia_j':                 _jChecked,
        'jia_i':                 _iChecked,
        'jia_a':                 _aChecked,
        'aplica_excentricidad':  _aplExc,
        'apl_exc_override':      _aplExcOverride,
        'usa_sustitucion':       _usaSustitucion,
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

    // ── CANDADO METROLÓGICO: 6 CAMPOS OBLIGATORIOS DEL INSTRUMENTO ─────────
    final List<String> faltantes = [];
    if (_marcaCtrl.text.trim().isEmpty)    faltantes.add('Marca');
    if (_modeloCtrl.text.trim().isEmpty)   faltantes.add('Modelo');
    if (_idEquipoCtrl.text.trim().isEmpty) faltantes.add('ID Indicador / Equipo');
    if (_capMaxCtrl.text.trim().isEmpty)   faltantes.add('Capacidad Máxima');
    if (_divMinCtrl.text.trim().isEmpty)   faltantes.add('División Mínima (d)');
    if (_ubicCtrl.text.trim().isEmpty)     faltantes.add('Ubicación');

    if (faltantes.isNotEmpty) {
      setState(() => _mostrarErroresInstrumento = true);
      _tabCtrl.animateTo(0);
      await _mostrarDialogoCandadoInstrumento(faltantes);
      return;
    }

    // ── Validaciones metrológicas de división mínima (d) ───────────────
    final d = _dValue;
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

    // ── Validaciones obligatorias de servicio ───────────────────────────
    if (rules.tieneCalibracion && _ccaCtrl.text.trim().isEmpty) {
      _tabCtrl.animateTo(0);
      _showError('El Número de CCA es obligatorio para este tipo de servicio.');
      return;
    }
    if (rules.tieneInspeccion && _holoAntCtrl.text.trim().isEmpty) {
      _tabCtrl.animateTo(0);
      _showError('El Holograma Anterior es obligatorio para este tipo de servicio.');
      return;
    }
    if (rules.pideInicialJia && !_jChecked && !_iChecked && !_aChecked) {
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
    final String direccionFinal = (_os['direccion'] ?? _os['direccion_cliente'] ?? _os['sucursal'] ?? _os['planta'] ?? _os['sucursal_nombre'] ?? '').toString();

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
        'jia_j':                 _jChecked,
        'jia_i':                 _iChecked,
        'jia_a':                 _aChecked,
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
        'division_minima':       _divMinCtrl.text.trim(),
        'div_minima':            _divMinCtrl.text.trim(),
        'equipo_division':       _divMinCtrl.text.trim(),
        'div_verificacion':      _divVerCtrl.text.trim(),
        'numero_cca':            _ccaCtrl.text.trim(),
        'cca_aplica':            rules.tieneCalibracion || _ccaCtrl.text.trim().isNotEmpty,
        'calibrado_por':         _os['calibrado_por'] ?? 'PESA BÁSCULAS',
        'unidad_medida':         _unidadMedida,
        'holograma_anterior':    _holoAntCtrl.text.trim(),
        'holograma_actualizado': _holoActCtrl.text.trim(),
        'tipo_instrumento':      _tipoInstrumento ?? '',
        'tipo_servicio':         _os['tipo_servicio'] ?? '',
        'funcionamiento':        _funcionamiento,
        'puntos_apoyo':          _puntosApoyo,
        'aplica_excentricidad':  _aplExc,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.rule, size: 18, color: _kRed),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tipo de Servicio: ${tipoServicioNombre ?? rules.nombre}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              // Solo mostrar badges de lo que APLICA
              if (rules.tieneCalibracion)
                _Badge('CCA requerido', const Color(0xFF1D4ED8)),
              if (rules.tieneInspeccion)
                _Badge('Hologramas + DVE', const Color(0xFF7C3AED)),
              if (rules.esSoloAjuste)
                _Badge('Solo Ajuste', Colors.grey),
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
      color: color.withValues(alpha: 0.1),
      border: Border.all(color: color.withValues(alpha: 0.4)),
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

class _Field extends StatelessWidget {
  final String                  label;
  final TextEditingController   ctrl;
  final String?                 hint;
  final bool                    required;
  final bool                    hasError;
  final ValueChanged<String>?   onChanged;
  const _Field(
    this.label,
    this.ctrl, {
    this.hint,
    this.required = false,
    this.hasError = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    onChanged: onChanged,
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