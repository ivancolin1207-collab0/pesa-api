// lib/screens/captura_screen.dart — Captura metrológica digital interactiva
// v4.0: Lógica condicional estricta NOM-010-SCFI-2020 (lookup dual ID+nombre)
//       DVE dentro de sección Inspección · Precarga completa desde OS backend
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../services/local_db_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../widgets/repetibilidad_table.dart';
import '../widgets/excentricidad_table.dart';
import '../widgets/exactitud_table.dart';

// ── Constantes de estilo ───────────────────────────────────────────────────
const _kRed  = Color(0xFFC8102E);
const _kDark = Color(0xFF1A1A2E);

// Tipos de instrumento que metrológicamente aplican excentricidad.
const _kExcInstrumentos = {
  'Báscula de plataforma',
  'Báscula camionera',
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
  String  _funcionamiento = 'Electr\u00f3nico'; // nuevo campo
  int     _puntosApoyo    = 4;               // nuevo campo
  bool    _jChecked = false, _iChecked = false, _aChecked = false;
  bool    _usaSustitucion = false;
  bool?   _aplExcOverride;  // null = auto-determinar por instrumento

  // ── Lecturas de medición ─────────────────────────────────────────────────
  List<Map<String, dynamic>> _repRows  = [];
  List<Map<String, dynamic>> _excRows  = [];
  List<Map<String, dynamic>> _exacRows = [];
  final _obsCtrl                = TextEditingController();
  final _firmaClienteNombreCtrl = TextEditingController();  // nombre cliente — obligatorio
  String _dictamen = 'APTO';
  bool   _saving   = false;

  static const _tiposInstrumento = [
    'Báscula de plataforma',
    'Báscula camionera',
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
    } else if (ti.toLowerCase().contains('camionera') ||
               ti.toLowerCase().contains('puente')) {
      _tipoInstrumento = 'Camionera';
    }

    // Nuevos campos: Funcionamiento y Puntos de Apoyo
    final func = _str('funcionamiento');
    if (func.isNotEmpty) _funcionamiento = func;
    final pa = _os['puntos_apoyo'];
    if (pa != null) _puntosApoyo = (pa is int) ? pa : int.tryParse(pa.toString()) ?? 4;

    // Secciones para camionera — guardadas en SQLite, disponibles vía _os map
    // No hay una variable _nSecciones local; la consumen los widgets hijos.

    // JIA — pueden venir como bool o int (SQLite)
    _jChecked = _asBool(_os['jia_j']);
    _iChecked = _asBool(_os['jia_i']);
    _aChecked = _asBool(_os['jia_a']);
  }

  /// Determina si aplica excentricidad:
  ///   1. Override manual del técnico (tiene prioridad)
  ///   2. Flag del backend (`aplica_excentricidad`)
  ///   3. Inferencia por tipo de instrumento
  bool get _aplExc {
    if (_aplExcOverride != null) return _aplExcOverride!;
    final raw = _os['aplica_excentricidad'];
    if (raw != null) {
      if (raw is bool)   return raw;
      if (raw is int)    return raw == 1;
      if (raw is String) {
        final s = raw.toLowerCase();
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

  /// Calcula decimales exactos a partir del valor d (división mínima).
  static int _decimalsFromD(double d) {
    if (d <= 0) return 4;
    if (d >= 1) return 0;
    int dec = 0;
    double v = d;
    while (v < 1.0 && dec < 10) { v *= 10; dec++; }
    return dec;
  }

  /// Calcula el EMT según OIML R 76 Clase III.
  ///   0 ≤ m ≤ 500e → ±1e
  ///   500e < m ≤ 2000e → ±2e
  ///   2000e < m ≤ 10000e → ±3e
  static double _calcEmt(double cargaKg, double eKg) {
    if (eKg <= 0) return eKg;
    final m = cargaKg / eKg;
    if (m <= 500)   return eKg;
    if (m <= 2000)  return 2 * eKg;
    if (m <= 10000) return 3 * eKg;
    return 3 * eKg;
  }

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
    final saved = await LocalDbService.instance.getOs(widget.osId);
    if (saved == null) return;
    setState(() {
      // Combinar: datos del servidor + override local (local gana en valores de lectura)
      for (final k in saved.keys) {
        if (saved[k] != null && saved[k] != '') _os[k] = saved[k];
      }
      _obsCtrl.text = saved['observaciones'] ?? _obsCtrl.text;
      try {
        if (saved['rep_json']  != null && saved['rep_json']  != '')
          _repRows  = (_jsonSafe(saved['rep_json'])  as List).cast<Map<String, dynamic>>();
        if (saved['exc_json']  != null && saved['exc_json']  != '')
          _excRows  = (_jsonSafe(saved['exc_json'])  as List).cast<Map<String, dynamic>>();
        if (saved['exac_json'] != null && saved['exac_json'] != '')
          _exacRows = (_jsonSafe(saved['exac_json']) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    });
    _precargaCampos();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final folio   = _os['folio_os'] ?? widget.osId.toString();
    final nPuntos = (_os['num_puntos_exactitud'] as int?) ?? 10;
    final nCeldas = _os['num_celdas_camionera'] is int
        ? _os['num_celdas_camionera'] as int
        : int.tryParse(_os['num_celdas_camionera']?.toString() ?? '0') ?? 0;
    final bottom  = MediaQuery.of(context).viewPadding.bottom;

    return SafeArea(
      bottom: false,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: const Color(0xFFF5F5F7),
        appBar: AppBar(
          backgroundColor: _kDark,
          foregroundColor: Colors.white,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(folio, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            Text(_os['cliente'] ?? '',
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ]),
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
        body: Column(children: [
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildTabInstrumento(),
                RepetibilidadTable(
                  rows: _repRows,
                  divMin: _dValue,
                  onChanged: (r) => setState(() => _repRows = r),
                ),
                _buildExcentricidadTab(nCeldas),
                ExactitudTable(
                  numPuntos: nPuntos,
                  rows: _exacRows,
                  divMin: _dValue,
                  onChanged: (r) => setState(() => _exacRows = r),
                ),
              ],
            ),
          ),
          _buildObsPanel(),
          Padding(
            padding: EdgeInsets.only(bottom: bottom > 0 ? bottom : 16),
            child: _buildActionBar(folio),
          ),
        ]),
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
          Expanded(child: _Field('Marca',    _marcaCtrl,  hint: 'METTLER TOLEDO')),
          const SizedBox(width: 12),
          Expanded(child: _Field('Modelo',   _modeloCtrl, hint: 'IND560')),
          const SizedBox(width: 12),
          Expanded(child: _Field('N° de Serie', _nsCtrl,  hint: 'B215004321')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _Field('ID Indicador / Equipo', _idEquipoCtrl,
              hint: 'Trailer A, Báscula 3...')),
          const SizedBox(width: 12),
          Expanded(child: _Field('Ubicación', _ubicCtrl, hint: 'Planta Norte')),
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
            // Recalcular excentricidad si no hay override manual
            if (_aplExcOverride == null) setState(() {});
          }),
        ),
        const SizedBox(height: 16),

        // ── Parámetros metrológicos base (Cap + Div — SIN DVE aquí) ────────
        _SectionTitle('Parámetros Metrológicos'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _NumField('Capacidad Máx. (kg)', _capMaxCtrl)),
          const SizedBox(width: 12),
          Expanded(child: _NumField('División Mín. (kg)',  _divMinCtrl)),
        ]),
        const SizedBox(height: 12),

        // ¿Aplica Excentricidad? — siempre visible (switch manual)
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade200)),
          child: SwitchListTile(
            title: const Text('¿Aplica Excentricidad?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              _aplExc
                  ? 'Sí — se capturarán puntos de exc.'
                  : 'No — no aplica para este instrumento.',
              style: const TextStyle(fontSize: 11),
            ),
            value: _aplExc,
            activeColor: _kRed,
            onChanged: (v) => setState(() => _aplExcOverride = v),
            secondary: Icon(
              _aplExc ? Icons.center_focus_strong : Icons.center_focus_weak,
              color: _aplExc ? _kRed : Colors.grey,
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

        // ── Cargas de sustitución (condicional a capacidad) ────────────────
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade200)),
          child: SwitchListTile(
            title: const Text('¿Usa Carga de Sustitución?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'Activa cuando la cap. máx. excede la masa patrón disponible.',
              style: TextStyle(fontSize: 11),
            ),
            value: _usaSustitucion,
            activeColor: _kRed,
            onChanged: (v) => setState(() => _usaSustitucion = v),
          ),
        ),
        if (_usaSustitucion) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _NumField('Masa Patrón Disponible (kg)', _masaPatronCtrl)),
            const SizedBox(width: 12),
            Expanded(child: _NumField('Factor Sustitución',          _factorSustCtrl)),
          ]),
        ],
        const SizedBox(height: 24),

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
                    onPressed: () => setState(() { if (_puntosApoyo > 1) _puntosApoyo--; }),
                  ),
                  Text('$_puntosApoyo',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    color: _kRed,
                    onPressed: () => setState(() { if (_puntosApoyo < 12) _puntosApoyo++; }),
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
    return Column(children: [
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
                ? 'Excentricidad activada — captura los valores de cada punto.'
                : 'Excentricidad desactivada. Actívala en la pestaña Instrumento.',
            style: TextStyle(fontSize: 12,
                color: _aplExc ? Colors.green.shade800 : Colors.orange.shade800),
          )),
          TextButton(
            onPressed: () => setState(() => _aplExcOverride = !_aplExc),
            child: Text(_aplExc ? 'Desactivar' : 'Activar',
                style: TextStyle(fontSize: 11,
                    color: _aplExc ? Colors.red.shade700 : Colors.green.shade700)),
          ),
        ]),
      ),
      Expanded(child: _aplExc
          ? ExcentricidadTable(
              numCeldas: nCeldas,
              rows: _excRows,
              divMin: _dValue,
              geometria: _os['geometria_plataforma'] as String?,
              onChanged: (r) => setState(() => _excRows = r),
            )
          : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.center_focus_weak, size: 48, color: Colors.grey.shade300),
              const SizedBox(height: 8),
              Text('Excentricidad no aplica para esta orden.',
                  style: TextStyle(color: Colors.grey.shade500)),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => setState(() => _aplExcOverride = true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _kRed, foregroundColor: Colors.white),
                child: const Text('Habilitar manualmente'),
              ),
            ]))),
    ]);
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
        // Nombre del cliente — OBLIGATORIO en Android y Windows
        TextField(
          controller: _firmaClienteNombreCtrl,
          decoration: InputDecoration(
            labelText: 'Nombre de quien recibe / Conforme Cliente *',
            labelStyle: const TextStyle(
                color: Color(0xFFC8102E), fontWeight: FontWeight.w600),
            hintText: 'Nombre completo del receptor',
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
          ),
          maxLines: 1,
          onChanged: (_) => setState(() {}), // rebuild para actualizar borde
        ),
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
          onPressed: _saving ? null : _guardarBorrador,
        ),
        const Spacer(),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A7F64),
            foregroundColor: Colors.white,
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
    _os['id_equipo']             = _idEquipoCtrl.text.trim();
    _os['ubicacion']             = _ubicCtrl.text.trim();
    _os['tipo_instrumento']      = _tipoInstrumento;
    _os['jia_j']                 = _jChecked;
    _os['jia_i']                 = _iChecked;
    _os['jia_a']                 = _aChecked;
    _os['aplica_excentricidad']  = _aplExc;
    _os['usa_sustitucion']       = _usaSustitucion;
    // Nuevos campos
    _os['funcionamiento']        = _funcionamiento;
    _os['puntos_apoyo']          = _puntosApoyo;

    // Solo guardar campos condicionales si aplican según las reglas activas
    if (rules.tieneCalibracion) {
      _os['numero_cca'] = _ccaCtrl.text.trim();
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

    final maxV = double.tryParse(_capMaxCtrl.text);
    final divV = double.tryParse(_divMinCtrl.text);
    if (maxV != null) _os['alcance_max'] = maxV;
    if (divV != null) _os['div_minima']  = divV;
    // Nombre del cliente — siempre persiste en el mapa
    _os['firma_cliente_nombre'] = _firmaClienteNombreCtrl.text.trim();
  }

  Future<void> _guardarBorrador() async {
    _guardarDatosInstrumento();
    setState(() => _saving = true);
    await LocalDbService.instance.saveLecturas(
      localId:              widget.osId,
      repRows:              _repRows,
      excRows:              _excRows,
      exacRows:             _exacRows,
      observaciones:        _obsCtrl.text.trim(),
      firmaClienteNombre:   _firmaClienteNombreCtrl.text.trim(),
    );
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Borrador guardado ✓'),
            backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _irAFirma(String folio) async {
    _guardarDatosInstrumento();
    final rules = _rules;

    // ── Validaciones obligatorias ─────────────────────────────────────────
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
    // Nombre del cliente es obligatorio en Android (firma sólo posible en Windows)
    if (_firmaClienteNombreCtrl.text.trim().isEmpty) {
      _showError('El nombre de quien recibe es obligatorio.');
      return;
    }

    await _guardarBorrador();

    if (mounted) {
      context.push('/firma/${widget.osId}', extra: {
        'folio_os':              folio,
        'tecnico':               _os['tecnico'] ?? '',
        'cliente':               _os['cliente'] ?? '',
        'rep_rows':              _repRows,
        'exc_rows':              _excRows,
        'exac_rows':             _exacRows,
        'observaciones':         _obsCtrl.text.trim(),
        'firma_cliente_nombre':  _firmaClienteNombreCtrl.text.trim(),
        'dictamen':              _dictamen,
        'jia_j':                 _jChecked,
        'jia_i':                 _iChecked,
        'jia_a':                 _aChecked,
        'marca':                 _marcaCtrl.text.trim(),
        'modelo':                _modeloCtrl.text.trim(),
        'ns':                    _nsCtrl.text.trim(),
        'numero_cca':            _ccaCtrl.text.trim(),
        'holograma_anterior':    _holoAntCtrl.text.trim(),
        'holograma_actualizado': _holoActCtrl.text.trim(),
        'tipo_instrumento':      _tipoInstrumento ?? '',
        'tipo_servicio':         _os['tipo_servicio'] ?? '',
        'funcionamiento':        _funcionamiento,
        'puntos_apoyo':          _puntosApoyo,
        'div_minima':            _dValue,
      });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 4),
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
  const _Field(this.label, this.ctrl, {this.hint, this.required = false});

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    decoration: _kInputDeco(label + (required ? ' *' : ''), hint: hint),
    style: const TextStyle(fontSize: 13),
  );
}

class _NumField extends StatelessWidget {
  final String                  label;
  final TextEditingController   ctrl;
  const _NumField(this.label, this.ctrl);

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: ctrl,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
    decoration: _kInputDeco(label),
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

InputDecoration _kInputDeco(String label, {String? hint}) => InputDecoration(
  labelText: label,
  hintText:  hint,
  hintStyle: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 12),
  border:         OutlineInputBorder(borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
  focusedBorder:  OutlineInputBorder(borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _kRed, width: 2)),
  isDense:    true,
  filled:     true,
  fillColor:  Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
);