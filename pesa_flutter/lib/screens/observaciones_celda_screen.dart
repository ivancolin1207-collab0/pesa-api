// lib/screens/observaciones_celda_screen.dart
// Pantalla Digital Homologada 1:1 con el Formato Oficial:
// "FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA" (OSOCC-26-001)
//
// Secciones exactas e inalterables (1 Celda Unitaria):
//   SECCIÓN 1. DATOS DE IDENTIFICACIÓN DE LA CELDA
//   SECCIÓN 2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA (Puntos 1 al 6)
//   SECCIÓN 3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA) (12 parámetros)
//   SECCIÓN 4. DICTAMEN TÉCNICO Y OBSERVACIONES
//   SECCIÓN 5. FIRMAS DE RESPONSABILIDAD

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/pdf_service.dart';
import '../services/sync_service.dart';
import '../widgets/nombre_recibe.dart';
import '../widgets/signature_shield.dart';

class ObservacionesCeldaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const ObservacionesCeldaScreen({super.key, required this.orden});

  @override
  State<ObservacionesCeldaScreen> createState() => _ObservacionesCeldaScreenState();
}

class _ObservacionesCeldaScreenState extends State<ObservacionesCeldaScreen> {
  static const Color _pesaRed = Color(0xFFB81D24);
  static const Color _pesaDark = Color(0xFF1D1D1F);
  static const Color _osoccBlue = Color(0xFF0284C7);

  static const Map<int, String> _checklistLabels = {
    1: 'Cuerpo metálico / Deformación',
    2: 'Roscas, barrenos y apoyos mecánicos',
    3: 'Sellos herméticos y encapsulado de galgas',
    4: 'Integridad del cable (sin cortes, aplastamientos ni empalmes)',
    5: 'Prensaestopas / Salida de cable',
    6: 'Evidencia de corrosión, humedad o sobrecarga térmica',
  };

  static const List<Map<String, String>> _pruebasElectricasSpec = [
    {'idx': '1', 'key': 'exc_pos_exc_neg', 'label': 'Excitación Exc+ / Exc-', 'unidad': 'Ohms'},
    {'idx': '2', 'key': 'sig_pos_sig_neg', 'label': 'Resistencia Sig+ / Sig-', 'unidad': 'Ohms'},
    {'idx': '3', 'key': 'exc_pos_sig_pos', 'label': 'Resistencia Exc+ / Sig+', 'unidad': 'Ohms'},
    {'idx': '4', 'key': 'exc_pos_sig_neg', 'label': 'Resistencia Exc+ / Sig-', 'unidad': 'Ohms'},
    {'idx': '5', 'key': 'exc_neg_sig_pos', 'label': 'Resistencia Exc- / Sig+', 'unidad': 'Ohms'},
    {'idx': '6', 'key': 'exc_neg_sig_neg', 'label': 'Resistencia Exc- / Sig-', 'unidad': 'Ohms'},
    {'idx': '7', 'key': 'sig_neg_mas_exc_pos', 'label': 'Resistencia Sig- + Exc+', 'unidad': 'Ohms'},
    {'idx': '8', 'key': 'sig_neg_mas_exc_neg', 'label': 'Resistencia Sig- + Exc-', 'unidad': 'Ohms'},
    {'idx': '9', 'key': 'exc_neg_pos_sig_pos', 'label': 'Resistencia Exc-+ / Sig+', 'unidad': 'Ohms'},
    {'idx': '10', 'key': 'exc_neg_pos_sig_neg', 'label': 'Resistencia Exc-+ / Sig-', 'unidad': 'Ohms'},
    {'idx': '11', 'key': 'senal_salida_mv', 'label': 'Señal de Salida (Milivoltaje)', 'unidad': 'mV'},
    {'idx': '12', 'key': 'resistencia_aislamiento', 'label': 'Resistencia de Aislamiento', 'unidad': 'MΩ'},
  ];

  // Cabecera de control
  final _ordenServicioRefCtrl = TextEditingController();
  String _destinoTipo = 'Stock'; // 'Cliente' | 'Stock'

  // SECCIÓN 1: Datos de Identificación de la Celda
  final _clienteDestinoCtrl = TextEditingController(text: 'Stock / Taller Básculas PESA');
  final _marcaCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController();
  final _serieCtrl = TextEditingController();
  final _capMaxCtrl = TextEditingController();
  String _unidadCap = 'kg'; // 'kg' | 'lb' | 't'
  final _sensibilidadCtrl = TextEditingController();
  final _resistenciaNomCtrl = TextEditingController();

  // Configuración de Cables / Colores
  final _colorExcPosCtrl = TextEditingController(text: 'Rojo');
  final _colorExcNegCtrl = TextEditingController(text: 'Negro');
  final _colorSigPosCtrl = TextEditingController(text: 'Verde');
  final _colorSigNegCtrl = TextEditingController(text: 'Blanco');
  final _colorBlindajeCtrl = TextEditingController(text: 'Malla');
  String _senseOption = 'No'; // 'Sí' | 'No'

  // SECCIÓN 2: Inspección Física y Mecánica (1..6)
  final Map<int, String> _chkEstado = {for (int i = 1; i <= 6; i++) i: 'B'};
  late final Map<int, TextEditingController> _chkObsCtrls;

  // SECCIÓN 3: Pruebas y Mediciones Eléctricas Unitarias (1..12)
  late final Map<int, TextEditingController> _pruebasValorCtrls;
  late final Map<int, FocusNode> _pruebasFocusNodes;
  final Map<int, String> _pruebasEstado = {
    for (int i = 1; i <= 11; i++) i: 'OK',
    12: '> 5000 MΩ (OK)',
  };

  // SECCIÓN 4: Dictamen Técnico y Observaciones
  final _obsTecnicasCtrl = TextEditingController();
  String _dictamenEstado = 'OPERATIVA'; // 'OPERATIVA' | 'REPARABLE' | 'DAÑADA'

  // SECCIÓN 5: Firmas de Responsabilidad
  final _tecNombreCtrl = TextEditingController();
  final _tecPuestoCtrl = TextEditingController(text: 'Técnico Especialista');
  final _cliNombreCtrl = TextEditingController();
  final _cliPuestoCtrl = TextEditingController();

  List<String> _contactosSugeridos = [];

  final _sigClienteCtrl = SignatureController(
    penStrokeWidth: 2.5,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );
  final _sigTecnicoCtrl = SignatureController(
    penStrokeWidth: 2.5,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  Uint8List? _firmaTecPre;
  bool _usarFirmaPre = false;
  bool _guardando = false;
  bool _cargandoInicial = true;
  bool _finalizadaExitosamente = false;
  Timer? _autoSaveDebounce;

  Map<String, dynamic> _datosCombinados = {};

  @override
  void initState() {
    super.initState();
    _chkObsCtrls = {
      for (int i = 1; i <= 6; i++) i: TextEditingController(),
    };
    _pruebasValorCtrls = {
      for (int i = 1; i <= 12; i++) i: TextEditingController(),
    };
    _pruebasFocusNodes = {
      for (int i = 1; i <= 12; i++) i: FocusNode(),
    };
    _registrarListenersAutoGuardado();
    _cargarDatos();
  }

  void _registrarListenersAutoGuardado() {
    final ctrls = <TextEditingController>[
      _ordenServicioRefCtrl,
      _clienteDestinoCtrl,
      _marcaCtrl,
      _modeloCtrl,
      _serieCtrl,
      _capMaxCtrl,
      _sensibilidadCtrl,
      _resistenciaNomCtrl,
      _colorExcPosCtrl,
      _colorExcNegCtrl,
      _colorSigPosCtrl,
      _colorSigNegCtrl,
      _colorBlindajeCtrl,
      ..._chkObsCtrls.values,
      ..._pruebasValorCtrls.values,
      _obsTecnicasCtrl,
      _tecNombreCtrl,
      _tecPuestoCtrl,
      _cliNombreCtrl,
      _cliPuestoCtrl,
    ];
    for (final c in ctrls) {
      c.addListener(_programarAutoGuardado);
    }
  }

  void _programarAutoGuardado() {
    if (_cargandoInicial || _finalizadaExitosamente) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 350), () {
      guardarBorrador();
    });
  }

  String _pickFromMap(Map<String, dynamic> m, List<String> keys, [String def = '']) {
    for (final k in keys) {
      final v = m[k];
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty && s.toLowerCase() != 'null' && s.toLowerCase() != 'none') {
          return s;
        }
      }
    }
    return def;
  }

  Future<Map<String, dynamic>?> obtenerBorrador(String folio) async {
    if (folio.isEmpty) return null;
    try {
      final db = await LocalDbService.instance.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS borradores_captura (
          folio_os TEXT PRIMARY KEY,
          draft_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      final rows = await db.query(
        'borradores_captura',
        where: 'folio_os = ?',
        whereArgs: [folio],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final rawDraftStr = (rows.first['draft_json'] ?? '').toString();
        if (rawDraftStr.isNotEmpty) {
          final draft = Map<String, dynamic>.from(jsonDecode(rawDraftStr) as Map);
          final bool esCorrupto =
              (draft.containsKey('partidas') || draft.containsKey('items')) &&
              !draft.containsKey('pruebas_electricas_celda') &&
              !draft.containsKey('checklist_celda');
          if (esCorrupto) {
            await eliminarBorrador(folio);
            return null;
          }
          return draft;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> eliminarBorrador(String folio) async {
    if (folio.isEmpty) return;
    try {
      await LocalDbService.instance.deleteDraft(folio);
    } catch (_) {}
  }

  Future<void> _cargarDatos() async {
    final prefs = await SharedPreferences.getInstance();
    final b64 = prefs.getString('firma_tecnico_b64');
    if (b64 != null && b64.isNotEmpty) {
      try {
        final clean = b64.contains(',') ? b64.split(',').last : b64;
        _firmaTecPre = base64Decode(clean);
        _usarFirmaPre = true;
      } catch (_) {}
    }

    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? '').toString().trim();
    final Map<String, dynamic> merged = Map<String, dynamic>.from(widget.orden);

    if (folio.isNotEmpty) {
      try {
        final dbRow = await LocalDbService.instance.getOsByFolio(folio);
        if (dbRow != null) {
          for (final entry in dbRow.entries) {
            if (entry.value != null && entry.value.toString().trim().isNotEmpty) {
              merged[entry.key] = entry.value;
            }
          }
        }
      } catch (_) {}
    }

    void unpackJsonField(dynamic rawJson) {
      if (rawJson == null) return;
      try {
        final Map<String, dynamic> parsed = rawJson is String
            ? Map<String, dynamic>.from(jsonDecode(rawJson) as Map)
            : Map<String, dynamic>.from(rawJson as Map);
        if (parsed['equipos'] is List && (parsed['equipos'] as List).isNotEmpty) {
          final firstEq = parsed['equipos'][0];
          if (firstEq is Map) {
            for (final e in firstEq.entries) {
              if (e.value != null && e.value.toString().trim().isNotEmpty) {
                merged.putIfAbsent(e.key.toString(), () => e.value);
              }
            }
          }
        }
        for (final e in parsed.entries) {
          if (e.value != null && e.value.toString().trim().isNotEmpty) {
            merged[e.key] = e.value;
          }
        }
      } catch (_) {}
    }

    unpackJsonField(widget.orden['datos_tecnicos_json']);
    unpackJsonField(merged['datos_tecnicos_json']);

    final Map<String, dynamic>? loadedDraft = await obtenerBorrador(folio);
    if (loadedDraft != null) {
      for (final e in loadedDraft.entries) {
        if (e.value != null) {
          merged[e.key] = e.value;
        }
      }
    }

    _datosCombinados = merged;

    String pickField(List<String> keys, [String def = '']) {
      if (loadedDraft != null) {
        for (final k in keys) {
          if (loadedDraft.containsKey(k) && loadedDraft[k] != null) {
            final s = loadedDraft[k].toString().trim();
            if (s.toLowerCase() != 'null' && s.toLowerCase() != 'none') {
              return s;
            }
          }
        }
      }
      return _pickFromMap(merged, keys, def);
    }

    // Cabecera
    _ordenServicioRefCtrl.text = pickField(['orden_servicio_ref', 'ref_orden', 'orden_servicio']);

    final destRaw = pickField(['destino_celda', 'destino_tipo', 'destino']);
    final cliVal = pickField([
      'cliente_destino',
      'cliente',
      'razon_social',
      'cliente_nombre',
      'ubicacion',
    ]);
    if (destRaw.toLowerCase().contains('stock') ||
        destRaw.toLowerCase().contains('laboratorio') ||
        destRaw.toLowerCase().contains('interno') ||
        cliVal.toLowerCase().contains('stock / taller') ||
        cliVal.toLowerCase().contains('laboratorio de celdas') ||
        cliVal.isEmpty) {
      _destinoTipo = 'Stock';
    } else {
      _destinoTipo = 'Cliente';
    }

    // Sección 1
    _clienteDestinoCtrl.text = cliVal.isNotEmpty ? cliVal : 'Stock / Taller Básculas PESA';
    _marcaCtrl.text = pickField(['marca', 'equipo_marca', 'instrumento_marca']);
    _modeloCtrl.text = pickField(['modelo', 'equipo_modelo', 'instrumento_modelo']);
    _serieCtrl.text = pickField(['serie', 'ns', 'numero_serie', 'equipo_ns']);

    final rawCap = pickField(['capacidad_nominal', 'capacidad_maxima', 'alcance_max', 'instrumento_capacidad']);
    final rawUni = pickField(['unidad_capacidad', 'unidad_medida', 'unidad'], 'kg').toLowerCase();
    if (['kg', 'lb', 't'].contains(rawUni)) {
      _unidadCap = rawUni;
    }
    _capMaxCtrl.text = rawCap.replaceAll(RegExp(r'\s*(kg|lb|t)$', caseSensitive: false), '').trim();

    _sensibilidadCtrl.text = pickField(['sensibilidad_nominal', 'sensibilidad_mv_v', 'sensibilidad']);
    _resistenciaNomCtrl.text = pickField(['resistencia_nominal', 'resistencia_entrada_salida', 'impedancia']);

    final rawCables = merged['configuracion_cables'];
    if (rawCables is Map) {
      _colorExcPosCtrl.text = (rawCables['exc_pos'] ?? 'Rojo').toString().trim();
      _colorExcNegCtrl.text = (rawCables['exc_neg'] ?? 'Negro').toString().trim();
      _colorSigPosCtrl.text = (rawCables['sig_pos'] ?? 'Verde').toString().trim();
      _colorSigNegCtrl.text = (rawCables['sig_neg'] ?? 'Blanco').toString().trim();
      _colorBlindajeCtrl.text = (rawCables['blindaje'] ?? 'Malla').toString().trim();
      final sVal = (rawCables['sense'] ?? 'No').toString().trim().toLowerCase();
      _senseOption = (sVal == 'si' || sVal == 'sí' || sVal == 'true') ? 'Sí' : 'No';
    }

    // Sección 2: Checklist 1..6
    final rawChk = merged['checklist_celda'] ?? merged['checklist_inspeccion'];
    if (rawChk is Map) {
      for (int i = 1; i <= 6; i++) {
        final item = rawChk['$i'] ?? rawChk[i];
        if (item is Map) {
          final est = (item['estado'] ?? 'B').toString().trim().toUpperCase();
          if (['B', 'R', 'M', 'N/A'].contains(est)) {
            _chkEstado[i] = est;
          }
          _chkObsCtrls[i]?.text = (item['observaciones'] ?? '').toString().trim();
        }
      }
    }

    // Sección 3: Pruebas eléctricas 1..12
    final rawPruebas = merged['pruebas_electricas_celda'] ?? merged['pruebas_electricas'];
    if (rawPruebas is Map) {
      for (final spec in _pruebasElectricasSpec) {
        final int idx = int.parse(spec['idx']!);
        final String key = spec['key']!;
        final item = rawPruebas['$idx'] ?? rawPruebas[idx] ?? rawPruebas[key];
        if (item is Map) {
          _pruebasValorCtrls[idx]?.text = (item['valor'] ?? item['valor_medido'] ?? '').toString().trim();
          final estRaw = (item['estado'] ?? '').toString().trim();
          if (idx == 12) {
            _pruebasEstado[12] = estRaw.toLowerCase().contains('fuga') || estRaw.toLowerCase().contains('falla')
                ? 'Fuga'
                : '> 5000 MΩ (OK)';
          } else {
            _pruebasEstado[idx] = estRaw.toLowerCase().contains('falla') ? 'Falla' : 'OK';
          }
        }
      }
    }

    // Sección 4: Dictamen Técnico y Observaciones
    _obsTecnicasCtrl.text = pickField(['observaciones', 'observaciones_tecnicas', 'observaciones_tecnico']);
    final rawDict = pickField(['dictamen_celda', 'dictamen_estado', 'dictamen'], 'OPERATIVA').toUpperCase();
    if (rawDict.contains('REPARABLE')) {
      _dictamenEstado = 'REPARABLE';
    } else if (rawDict.contains('DAÑAD') || rawDict.contains('DANAD') || rawDict.contains('DESCALIBRADA') || rawDict.contains('FUERA')) {
      _dictamenEstado = 'DAÑADA';
    } else {
      _dictamenEstado = 'OPERATIVA';
    }

    // Sección 5: Firmas
    String tecNom = pickField(['tecnico', 'tecnico_nombre']);
    if (tecNom.isEmpty && mounted) {
      try {
        final auth = context.read<AuthService>();
        tecNom = auth.nombreCompleto ?? auth.username ?? '';
      } catch (_) {}
    }
    _tecNombreCtrl.text = tecNom;
    _tecPuestoCtrl.text = pickField(['puesto_tecnico'], 'Técnico Especialista');

    final clienteNombre = _clienteDestinoCtrl.text.trim();
    for (final k in ['nombre_receptor', 'firma_cliente_nombre', 'nombre_quien_recibe', 'nombre_ing']) {
      final v = (merged[k] ?? '').toString().trim();
      if (v.isNotEmpty && !esRazonSocialEmpresa(v, clienteNombre)) {
        _cliNombreCtrl.text = v;
        break;
      }
    }
    _cliPuestoCtrl.text = pickField(['puesto_receptor', 'area_puesto_cliente', 'puesto_ing']);

    try {
      final cs = await LocalDbService.instance.getContactosPlanta(
        cliente: clienteNombre,
        planta: clienteNombre,
      );
      if (mounted) {
        setState(() {
          _contactosSugeridos = cs.where((c) => !esRazonSocialEmpresa(c, clienteNombre)).toList();
        });
      }
    } catch (_) {}

    if (_firmaTecPre == null) {
      try {
        String username = (merged['tecnico_username'] ?? '').toString();
        int idTec = int.tryParse('${merged['id_tecnico'] ?? ''}') ?? 0;
        if (mounted) {
          final auth = context.read<AuthService>();
          if (username.isEmpty) username = auth.username ?? '';
          if (idTec <= 0) idTec = auth.idTecnico ?? 0;
        }
        final savedFirmaTec = await FirmaTecnicoService.instance.getFirma(username, idTecnico: idTec);
        if (savedFirmaTec != null && savedFirmaTec.isNotEmpty) {
          final clean = savedFirmaTec.contains(',') ? savedFirmaTec.split(',').last : savedFirmaTec;
          _firmaTecPre = base64Decode(clean);
          _usarFirmaPre = true;
        }
      } catch (_) {}
    }

    _cargandoInicial = false;
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _construirPayload({
    String? fechaEjecucionHoy,
    String? firmaTecB64,
    String? firmaCliB64,
    String? correoCliente,
  }) {
    final checklistMap = <String, Map<String, String>>{};
    for (int i = 1; i <= 6; i++) {
      checklistMap['$i'] = {
        'estado': _chkEstado[i] ?? 'B',
        'observaciones': _chkObsCtrls[i]?.text.trim() ?? '',
      };
    }

    final pruebasMap = <String, Map<String, String>>{};
    for (final spec in _pruebasElectricasSpec) {
      final int idx = int.parse(spec['idx']!);
      final String key = spec['key']!;
      final entry = {
        'parametro': spec['label']!,
        'unidad': spec['unidad']!,
        'valor': _pruebasValorCtrls[idx]?.text.trim() ?? '',
        'estado': _pruebasEstado[idx] ?? 'OK',
      };
      pruebasMap['$idx'] = entry;
      pruebasMap[key] = entry;
    }

    final cablesMap = <String, String>{
      'exc_pos': _colorExcPosCtrl.text.trim(),
      'exc_neg': _colorExcNegCtrl.text.trim(),
      'sig_pos': _colorSigPosCtrl.text.trim(),
      'sig_neg': _colorSigNegCtrl.text.trim(),
      'blindaje': _colorBlindajeCtrl.text.trim(),
      'sense': _senseOption,
    };

    final capNum = _capMaxCtrl.text.trim();
    final capConUnidad = capNum.isNotEmpty ? '$capNum $_unidadCap' : '';

    final payload = Map<String, dynamic>.from(_datosCombinados);
    payload['tipo_documento'] = 'OSOCC';
    payload['tipo_servicio'] = 'Formato de Diagnóstico y Revisión de Celda de Carga';
    payload['orden_servicio_ref'] = _ordenServicioRefCtrl.text.trim();
    payload['ref_orden'] = _ordenServicioRefCtrl.text.trim();
    payload['destino_celda'] = _destinoTipo;

    // Sección 1
    final cliDest = _clienteDestinoCtrl.text.trim().isNotEmpty
        ? _clienteDestinoCtrl.text.trim()
        : 'Stock / Taller Básculas PESA';
    payload['cliente_destino'] = cliDest;
    payload['cliente'] = cliDest;
    payload['razon_social'] = cliDest;
    payload['ubicacion'] = cliDest;
    payload['marca'] = _marcaCtrl.text.trim();
    payload['modelo'] = _modeloCtrl.text.trim();
    payload['serie'] = _serieCtrl.text.trim();
    payload['ns'] = _serieCtrl.text.trim();
    payload['numero_serie'] = _serieCtrl.text.trim();
    payload['id_equipo'] = _serieCtrl.text.trim();
    payload['capacidad_nominal'] = capConUnidad;
    payload['capacidad_maxima'] = capNum;
    payload['alcance_max'] = capNum;
    payload['instrumento_capacidad'] = capConUnidad;
    payload['unidad_capacidad'] = _unidadCap;
    payload['unidad_medida'] = _unidadCap;
    payload['sensibilidad_nominal'] = _sensibilidadCtrl.text.trim();
    payload['resistencia_nominal'] = _resistenciaNomCtrl.text.trim();
    payload['configuracion_cables'] = cablesMap;
    payload['tipo_instrumento'] = 'Celda de Carga';

    // Sección 2, 3, 4
    payload['checklist_celda'] = checklistMap;
    payload['pruebas_electricas_celda'] = pruebasMap;
    payload['observaciones'] = _obsTecnicasCtrl.text.trim();
    payload['observaciones_tecnicas'] = _obsTecnicasCtrl.text.trim();
    payload['observaciones_tecnico'] = _obsTecnicasCtrl.text.trim();
    payload['dictamen_celda'] = _dictamenEstado;
    payload['dictamen_estado'] = _dictamenEstado;
    payload['dictamen'] = _dictamenEstado;

    // Sección 5
    payload['tecnico'] = _tecNombreCtrl.text.trim();
    payload['tecnico_nombre'] = _tecNombreCtrl.text.trim();
    payload['puesto_tecnico'] = _tecPuestoCtrl.text.trim();
    payload['nombre_receptor'] = _cliNombreCtrl.text.trim();
    payload['firma_cliente_nombre'] = _cliNombreCtrl.text.trim();
    payload['nombre_ing'] = _cliNombreCtrl.text.trim();
    payload['puesto_receptor'] = _cliPuestoCtrl.text.trim();
    payload['puesto_ing'] = _cliPuestoCtrl.text.trim();

    if (correoCliente != null && correoCliente.isNotEmpty) {
      payload['correo_cliente'] = correoCliente;
    }

    if (fechaEjecucionHoy != null) {
      payload['fecha_creacion_logistica'] ??= payload['fecha'];
      payload['fecha'] = fechaEjecucionHoy;
      payload['fecha_servicio'] = fechaEjecucionHoy;
      payload['fecha_cierre'] = DateTime.now().toIso8601String();
    }
    if (firmaTecB64 != null && firmaTecB64.isNotEmpty) {
      payload['firma_tecnico'] = firmaTecB64;
      payload['firma_tecnico_b64'] = firmaTecB64;
    }
    if (firmaCliB64 != null && firmaCliB64.isNotEmpty) {
      payload['firma_cliente'] = firmaCliB64;
      payload['firma_receptor_b64'] = firmaCliB64;
    }
    return payload;
  }

  Future<void> guardarBorrador() async {
    if (_cargandoInicial || _finalizadaExitosamente) return;
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? '').toString().trim();
    if (folio.isEmpty) return;
    try {
      final payload = _construirPayload();
      final jsonStr = jsonEncode(payload);
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final db = await LocalDbService.instance.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS borradores_captura (
          folio_os TEXT PRIMARY KEY,
          draft_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.rawInsert(
        'INSERT OR REPLACE INTO borradores_captura (folio_os, draft_json, updated_at) VALUES (?, ?, ?)',
        [folio, jsonStr, nowIso],
      );
      await db.rawUpdate(
        '''UPDATE ordenes_servicio
           SET marca = ?,
               modelo = ?,
               ns = ?,
               id_equipo = ?,
               alcance_max = ?,
               ubicacion = ?,
               observaciones = ?,
               dictamen = ?,
               datos_tecnicos_json = ?
           WHERE folio_os = ? OR folio = ?''',
        [
          _marcaCtrl.text.trim(),
          _modeloCtrl.text.trim(),
          _serieCtrl.text.trim(),
          _serieCtrl.text.trim(),
          _capMaxCtrl.text.trim(),
          _clienteDestinoCtrl.text.trim(),
          _obsTecnicasCtrl.text.trim(),
          _dictamenEstado,
          jsonStr,
          folio,
          folio,
        ],
      );
      try {
        widget.orden.addAll(payload);
        widget.orden['datos_tecnicos_json'] = jsonStr;
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _finalizar() async {
    final esStock = _destinoTipo == 'Stock';
    final cliente = _clienteDestinoCtrl.text.trim();
    final nombreReceptor = _cliNombreCtrl.text.trim();

    if (!esStock) {
      if (!exigirNombreRecibe(context, nombreReceptor, clienteEmpresa: cliente)) {
        return;
      }
      if (_sigClienteCtrl.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('La firma de recibido del cliente es obligatoria cuando el destino es Cliente.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
    }

    final tieneFirmaTec = (_usarFirmaPre && _firmaTecPre != null) || _sigTecnicoCtrl.isNotEmpty;
    if (!tieneFirmaTec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta la firma del técnico responsable que evaluó la celda.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'OSOCC-26-001').toString().trim();
    final loteId = _pickFromMap(_datosCombinados, ['id_lote', 'lote']);
    final bool esLote = loteId.isNotEmpty;
    String correoCapturado = _pickFromMap(_datosCombinados, ['correo_cliente', 'email_cliente']);

    if (!esLote && !esStock) {
      final emailCtrl = TextEditingController(text: correoCapturado);
      final bool? capturo = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.mark_email_read_rounded, color: _osoccBlue, size: 26),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Envío de Diagnóstico de Celda por Correo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ingresa el correo electrónico del cliente para enviar el Formato de Diagnóstico y Revisión de Celda de Carga:',
                style: TextStyle(fontSize: 13, color: Color(0xFF374151), height: 1.4),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Correo del Cliente',
                  hintText: 'cliente@empresa.com',
                  prefixIcon: const Icon(Icons.email_outlined, color: _osoccBlue),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'CC obligatorio: recepcion@basculaspesa.com.mx',
                style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                emailCtrl.clear();
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Omitir correo'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _osoccBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );

      if (capturo != true) return;
      correoCapturado = emailCtrl.text.trim();

      if (correoCapturado.isNotEmpty) {
        if (!mounted) return;
        final bool? confirmado = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Row(
              children: [
                Icon(Icons.outgoing_mail, color: _osoccBlue, size: 26),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Confirmar Envío de Correo',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Text(
              'Se enviará el formato $folio al correo $correoCapturado con copia a recepcion@basculaspesa.com.mx, ¿desea continuar?',
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _osoccBlue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Sí, continuar'),
              ),
            ],
          ),
        );
        if (confirmado != true) return;
      }
    }

    setState(() => _guardando = true);
    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final sigCliBytes = _sigClienteCtrl.isNotEmpty ? await _sigClienteCtrl.toPngBytes() : null;
      final Uint8List? sigTecBytes =
          (_usarFirmaPre && _firmaTecPre != null) ? _firmaTecPre : await _sigTecnicoCtrl.toPngBytes();

      final String? firmaCliB64 = sigCliBytes != null ? base64Encode(sigCliBytes) : null;
      final String? firmaTecB64 = sigTecBytes != null ? base64Encode(sigTecBytes) : null;

      final String fechaEjecucionHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String fechaCierreIso = DateTime.now().toIso8601String();

      final payload = _construirPayload(
        fechaEjecucionHoy: fechaEjecucionHoy,
        firmaTecB64: firmaTecB64,
        firmaCliB64: firmaCliB64,
        correoCliente: correoCapturado,
      );

      widget.orden['fecha_creacion_logistica'] ??= widget.orden['fecha'];
      widget.orden['fecha'] = fechaEjecucionHoy;
      widget.orden['fecha_servicio'] = fechaEjecucionHoy;
      widget.orden['fecha_cierre'] = fechaCierreIso;

      await LocalDbService.instance.actualizarFechaEjecucionAlFinalizar(
        folio,
        fechaEjecucionHoy,
        localId: localId,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );

      final pdfPath = await PdfService.instance.generarPdfObservacionesCelda(
        osData: payload,
        firmaTecBase64: firmaTecB64,
        firmaCliBase64: firmaCliB64,
      );

      final pdfBytes = await File(pdfPath).readAsBytes();
      final pdfB64 = base64Encode(pdfBytes);
      final datosJsonStr = jsonEncode(payload);

      await LocalDbService.instance.saveDraft(folio, {
        ...payload,
        'pdf_path': pdfPath,
        'estado': 'FINALIZADA',
      });
      _finalizadaExitosamente = true;

      if (nombreReceptor.isNotEmpty) {
        await LocalDbService.instance.saveContactoPlanta(
          cliente: cliente,
          planta: cliente,
          nombreContacto: nombreReceptor,
        );
        if (loteId.isNotEmpty) {
          LoteSession.registrarResponsable(loteId, nombreReceptor, puesto: _cliPuestoCtrl.text.trim());
        }
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: firmaTecB64 ?? '',
        firmaCliBase64: firmaCliB64 ?? '',
        nombreIng: nombreReceptor,
        puestoIng: _cliPuestoCtrl.text.trim(),
        correoCliente: correoCapturado.isNotEmpty ? correoCapturado : null,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );

      try {
        final db = await LocalDbService.instance.database;
        await db.rawUpdate(
          '''UPDATE ordenes_servicio
             SET fecha = ?,
                 cliente = ?,
                 marca = ?,
                 modelo = ?,
                 ns = ?,
                 id_equipo = ?,
                 alcance_max = ?,
                 ubicacion = ?,
                 observaciones = ?,
                 dictamen = ?,
                 tipo_documento = 'OSOCC',
                 tipo_servicio = 'Formato de Diagnóstico y Revisión de Celda de Carga',
                 correo_cliente = ?,
                 datos_tecnicos_json = ?
             WHERE folio_os = ? OR folio = ?''',
          [
            fechaEjecucionHoy,
            _clienteDestinoCtrl.text.trim(),
            _marcaCtrl.text.trim(),
            _modeloCtrl.text.trim(),
            _serieCtrl.text.trim(),
            _serieCtrl.text.trim(),
            _capMaxCtrl.text.trim(),
            _clienteDestinoCtrl.text.trim(),
            _obsTecnicasCtrl.text.trim(),
            _dictamenEstado,
            correoCapturado,
            datosJsonStr,
            folio,
            folio,
          ],
        );
      } catch (_) {}

      final connResults = await Connectivity().checkConnectivity();
      final isOnline = connResults.any((r) => r != ConnectivityResult.none);

      bool subio = false;
      if (isOnline) {
        try {
          subio = await ApiService.instance.uploadPdf(
            folio,
            File(pdfPath),
            osId: localId,
            data: {
              ...payload,
              'tipo_documento': 'OSOCC',
              'fecha': fechaEjecucionHoy,
              'fecha_servicio': fechaEjecucionHoy,
              'fecha_cierre': fechaCierreIso,
              'correo_cliente': correoCapturado,
              'datos_tecnicos_json': datosJsonStr,
            },
          );
        } catch (_) {}
      }

      await LocalDbService.instance.savePdfPath(
        localId,
        pdfPath,
        folio: folio,
        pdfB64: pdfB64,
        isOnline: isOnline,
        uploadOk: subio,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );

      if (subio && correoCapturado.isNotEmpty) {
        await LocalDbService.instance.updateEmailStatus(
          folio,
          enviado: true,
          correo: correoCapturado,
        );
      }

      if (mounted) {
        try {
          context.read<SyncService>().updateLocalOrder(folio, {
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'cliente': _clienteDestinoCtrl.text.trim(),
            'marca': _marcaCtrl.text.trim(),
            'modelo': _modeloCtrl.text.trim(),
            'ns': _serieCtrl.text.trim(),
            'id_equipo': _serieCtrl.text.trim(),
            'alcance_max': _capMaxCtrl.text.trim(),
            'ubicacion': _clienteDestinoCtrl.text.trim(),
            'pdf_path_local': pdfPath,
            'datos_tecnicos_json': datosJsonStr,
            'correo_cliente': correoCapturado,
            'email_enviado': (subio && correoCapturado.isNotEmpty) ? 1 : 0,
            'estado': 'COMPLETADA_DIGITAL',
            'estatus': 'Cerrado',
            'sync_check_status': subio ? 'SUBIDA_SERVIDOR' : 'PENDIENTE_SUBIDA',
            'sync_status': subio ? 'SINCRONIZADO' : 'PENDIENTE',
            'needs_push': subio ? 0 : 1,
          });
          if (isOnline) {
            context.read<SyncService>().performSync();
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() => _guardando = false);
        _mostrarDialogoExito(pdfPath, folio, subio, correoCapturado);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al finalizar formato $folio: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _mostrarDialogoExito(String pdfPath, String folio, bool subio, String correo) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Diagnóstico de Celda Finalizado',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Folio: $folio', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              subio
                  ? 'El PDF oficial fue generado y sincronizado con el servidor central.'
                  : 'El PDF oficial fue guardado localmente y se sincronizará al conectar a internet.',
              style: const TextStyle(fontSize: 13),
            ),
            if (correo.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Correo destinatario: $correo\nCC: recepcion@basculaspesa.com.mx',
                style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => OpenFilex.open(pdfPath),
            icon: const Icon(Icons.picture_as_pdf_outlined, color: _pesaRed),
            label: const Text('Abrir PDF', style: TextStyle(color: _pesaRed)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _osoccBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(true);
            },
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _ordenServicioRefCtrl.dispose();
    _clienteDestinoCtrl.dispose();
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _serieCtrl.dispose();
    _capMaxCtrl.dispose();
    _sensibilidadCtrl.dispose();
    _resistenciaNomCtrl.dispose();
    _colorExcPosCtrl.dispose();
    _colorExcNegCtrl.dispose();
    _colorSigPosCtrl.dispose();
    _colorSigNegCtrl.dispose();
    _colorBlindajeCtrl.dispose();
    for (final c in _chkObsCtrls.values) {
      c.dispose();
    }
    for (final c in _pruebasValorCtrls.values) {
      c.dispose();
    }
    for (final f in _pruebasFocusNodes.values) {
      f.dispose();
    }
    _obsTecnicasCtrl.dispose();
    _tecNombreCtrl.dispose();
    _tecPuestoCtrl.dispose();
    _cliNombreCtrl.dispose();
    _cliPuestoCtrl.dispose();
    _sigClienteCtrl.dispose();
    _sigTecnicoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'OSOCC-26-001').toString();
    final fechaRaw = (widget.orden['fecha'] ?? DateFormat('dd/MM/yyyy').format(DateTime.now())).toString();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await guardarBorrador();
        if (context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F7),
        appBar: AppBar(
          backgroundColor: _pesaDark,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Guardar borrador y volver',
            onPressed: () async {
              await guardarBorrador();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, letterSpacing: 0.2),
              ),
              Text(
                'Folio: $folio  •  Fecha: $fechaRaw',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFFE0F2FE)),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: _guardando
                  ? null
                  : () async {
                      await guardarBorrador();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Borrador de celda guardado localmente.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
              icon: const Icon(Icons.save_outlined, color: Colors.white, size: 18),
              label: const Text('Borrador', style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
        body: _cargandoInicial
            ? const Center(child: CircularProgressIndicator(color: _osoccBlue))
            : ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 32),
                children: [
                  _buildHeaderControlCard(folio, fechaRaw),
                  const SizedBox(height: 12),
                  _buildSeccion1Card(),
                  const SizedBox(height: 12),
                  _buildSeccion2Card(),
                  const SizedBox(height: 12),
                  _buildSeccion3Card(),
                  const SizedBox(height: 12),
                  _buildSeccion4Card(),
                  const SizedBox(height: 12),
                  _buildSeccion5Card(),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _pesaRed,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 2,
                      ),
                      onPressed: _guardando ? null : _finalizar,
                      icon: _guardando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.assignment_turned_in_rounded),
                      label: Text(
                        _guardando
                            ? 'Generando PDF Oficial...'
                            : 'Finalizar y Generar PDF Oficial (OSOCC)',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {String? subtitle}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _pesaDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFFBAE6FD),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeaderControlCard(String folio, String fecha) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFBAE6FD), width: 1.4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF7DD3FC)),
                  ),
                  child: Text(
                    'FOLIO: $folio',
                    style: const TextStyle(
                      color: _osoccBlue,
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Fecha: $fecha',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'OSOCC DIGITAL (1 CELDA)',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: _osoccBlue,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildTextField(
                    _ordenServicioRefCtrl,
                    'Ref. / Orden',
                    hint: 'Opcional (ej. OS-26-750)',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Destino:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _pesaDark),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Stock / Laboratorio Interno'),
                            selected: _destinoTipo == 'Stock',
                            selectedColor: const Color(0xFFE0F2FE),
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: _destinoTipo == 'Stock' ? FontWeight.bold : FontWeight.normal,
                              color: _destinoTipo == 'Stock' ? _osoccBlue : Colors.black87,
                            ),
                            onSelected: (_) {
                              setState(() {
                                _destinoTipo = 'Stock';
                                if (_clienteDestinoCtrl.text.trim().isEmpty) {
                                  _clienteDestinoCtrl.text = 'Stock / Taller Básculas PESA';
                                }
                              });
                              _programarAutoGuardado();
                            },
                          ),
                          ChoiceChip(
                            label: const Text('Cliente'),
                            selected: _destinoTipo == 'Cliente',
                            selectedColor: const Color(0xFFE0F2FE),
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: _destinoTipo == 'Cliente' ? FontWeight.bold : FontWeight.normal,
                              color: _destinoTipo == 'Cliente' ? _osoccBlue : Colors.black87,
                            ),
                            onSelected: (_) {
                              setState(() {
                                _destinoTipo = 'Cliente';
                              });
                              _programarAutoGuardado();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeccion1Card() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('1. DATOS DE IDENTIFICACIÓN DE LA CELDA'),
            const SizedBox(height: 12),
            _buildTextField(
              _clienteDestinoCtrl,
              'Cliente / Destino',
              hint: 'Stock / Taller Básculas PESA o Razón Social del Cliente',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildTextField(_marcaCtrl, 'Marca')),
                const SizedBox(width: 10),
                Expanded(child: _buildTextField(_modeloCtrl, 'Modelo')),
                const SizedBox(width: 10),
                Expanded(child: _buildTextField(_serieCtrl, 'Número de Serie')),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildTextField(
                    _capMaxCtrl,
                    'Capacidad Nominal (Max)',
                    hint: 'Ej. 50000',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: DropdownButtonFormField<String>(
                    value: _unidadCap,
                    decoration: InputDecoration(
                      labelText: 'Unidad',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'kg', child: Text('kg')),
                      DropdownMenuItem(value: 'lb', child: Text('lb')),
                      DropdownMenuItem(value: 't', child: Text('t')),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _unidadCap = v);
                        _programarAutoGuardado();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _buildTextField(
                    _sensibilidadCtrl,
                    'Sensibilidad Nominal (mV/V)',
                    hint: 'Ej. 2.0 mV/V, 3.0 mV/V',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _buildTextField(
                    _resistenciaNomCtrl,
                    'Resistencia Nominal Ent./Sal. (Ohms)',
                    hint: 'Ej. 350 Ω / 700 Ω',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Configuración de Cables / Colores:',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _pesaDark),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildTextField(_colorExcPosCtrl, 'Exc+')),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(_colorExcNegCtrl, 'Exc-')),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(_colorSigPosCtrl, 'Sig+')),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(_colorSigNegCtrl, 'Sig-')),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(_colorBlindajeCtrl, 'Blindaje')),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<String>(
                    value: _senseOption,
                    decoration: InputDecoration(
                      labelText: 'Sense',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'No', child: Text('No')),
                      DropdownMenuItem(value: 'Sí', child: Text('Sí')),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _senseOption = v);
                        _programarAutoGuardado();
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeccion2Card() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader(
              '2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA',
              subtitle: 'Criterio: [B] Bueno  [R] Regular  [M] Malo  [N/A]',
            ),
            const SizedBox(height: 10),
            for (int i = 1; i <= 6; i++) _buildChecklistRow(i, _checklistLabels[i]!),
          ],
        ),
      ),
    );
  }

  Widget _buildChecklistRow(int numPt, String label) {
    final currentVal = _chkEstado[numPt] ?? 'B';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: numPt.isEven ? const Color(0xFFF9FAFB) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  '$numPt. $label',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _pesaDark),
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 6,
                children: ['B', 'R', 'M', 'N/A'].map((opt) {
                  final selected = currentVal == opt;
                  Color activeColor = _osoccBlue;
                  if (opt == 'B') activeColor = const Color(0xFF15803D);
                  if (opt == 'R') activeColor = const Color(0xFFB45309);
                  if (opt == 'M') activeColor = _pesaRed;
                  return InkWell(
                    onTap: () {
                      setState(() => _chkEstado[numPt] = opt);
                      _programarAutoGuardado();
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? activeColor : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected ? activeColor : const Color(0xFFD1D5DB),
                        ),
                      ),
                      child: Text(
                        opt,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: selected ? Colors.white : const Color(0xFF374151),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: TextField(
              controller: _chkObsCtrls[numPt],
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Obs. punto $numPt (opcional)',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeccion3Card() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader(
              '3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA)',
              subtitle: '1 Celda Unitaria',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      'PARÁMETRO ELÉCTRICO',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                  SizedBox(
                    width: 55,
                    child: Text(
                      'UND',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      'VALOR MEDIDO',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      'ESTADO (OK / FALLA)',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            for (final spec in _pruebasElectricasSpec) _buildPruebaElectricaRow(spec),
          ],
        ),
      ),
    );
  }

  Widget _buildPruebaElectricaRow(Map<String, String> spec) {
    final int idx = int.parse(spec['idx']!);
    final String label = spec['label']!;
    final String unidad = spec['unidad']!;
    final List<String> opciones = idx == 12 ? ['> 5000 MΩ (OK)', 'Fuga'] : ['OK', 'Falla'];
    final String currentEst = _pruebasEstado[idx] ?? opciones.first;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: idx.isEven ? const Color(0xFFF9FAFB) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              '$idx. $label',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _pesaDark),
            ),
          ),
          SizedBox(
            width: 55,
            child: Text(
              unidad,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4B5563)),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _pruebasValorCtrls[idx],
                  focusNode: _pruebasFocusNodes[idx],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  textInputAction: idx < 12 ? TextInputAction.next : TextInputAction.done,
                  onSubmitted: (_) {
                    if (idx < 12) {
                      _pruebasFocusNodes[idx + 1]?.requestFocus();
                    } else {
                      FocusScope.of(context).unfocus();
                    }
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: 'Valor ($unidad)',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              children: opciones.map((opt) {
                final bool selected = currentEst == opt;
                final bool isFail = opt.toLowerCase().contains('falla') || opt.toLowerCase().contains('fuga');
                final Color activeColor = isFail ? _pesaRed : const Color(0xFF15803D);
                return InkWell(
                  onTap: () {
                    setState(() => _pruebasEstado[idx] = opt);
                    _programarAutoGuardado();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: selected ? activeColor : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: selected ? activeColor : const Color(0xFFD1D5DB),
                      ),
                    ),
                    child: Text(
                      opt,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: selected ? Colors.white : const Color(0xFF374151),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeccion4Card() {
    final dictamenOptions = [
      {
        'val': 'OPERATIVA',
        'label': 'OPERATIVA / EN TOLERANCIA (Apta para instalación o calibración)',
        'color': const Color(0xFF15803D),
      },
      {
        'val': 'REPARABLE',
        'label': 'REPARABLE (Requiere reemplazo de cable, conector o reapriete)',
        'color': const Color(0xFFB45309),
      },
      {
        'val': 'DAÑADA',
        'label': 'DAÑADA / DESCALIBRADA (Sobrecarga, galgas abiertas o fuga - FUERA DE SERVICIO)',
        'color': _pesaRed,
      },
    ];

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('4. DICTAMEN TÉCNICO Y OBSERVACIONES'),
            const SizedBox(height: 12),
            const Text(
              'Observaciones Técnicas y Diagnóstico:',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _pesaDark),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _obsTecnicasCtrl,
              maxLines: 4,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Detalle el diagnóstico eléctrico y físico de la celda de carga...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.all(10),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Dictamen Final de la Celda:',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _pesaDark),
            ),
            const SizedBox(height: 6),
            for (final opt in dictamenOptions)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: _dictamenEstado == opt['val']
                      ? (opt['color'] as Color).withValues(alpha: 0.1)
                      : const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _dictamenEstado == opt['val']
                        ? (opt['color'] as Color)
                        : const Color(0xFFE5E7EB),
                    width: _dictamenEstado == opt['val'] ? 1.5 : 1,
                  ),
                ),
                child: RadioListTile<String>(
                  dense: true,
                  value: opt['val'] as String,
                  groupValue: _dictamenEstado,
                  activeColor: opt['color'] as Color,
                  title: Text(
                    opt['label'] as String,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _dictamenEstado == opt['val'] ? FontWeight.bold : FontWeight.w500,
                      color: _dictamenEstado == opt['val'] ? (opt['color'] as Color) : _pesaDark,
                    ),
                  ),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _dictamenEstado = v);
                      _programarAutoGuardado();
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeccion5Card() {
    final esStock = _destinoTipo == 'Stock';
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('5. FIRMAS DE RESPONSABILIDAD'),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Columna Técnico
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Evaluó / Técnico Responsable',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _pesaDark),
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(_tecNombreCtrl, 'Nombre del Técnico'),
                        const SizedBox(height: 8),
                        _buildTextField(_tecPuestoCtrl, 'Puesto'),
                        const SizedBox(height: 10),
                        if (_firmaTecPre != null && _usarFirmaPre) ...[
                          Container(
                            height: 120,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFD1D5DB)),
                            ),
                            child: Image.memory(_firmaTecPre!, fit: BoxFit.contain),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => setState(() => _usarFirmaPre = false),
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: const Text('Firmar manualmente', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                        ] else ...[
                          Container(
                            height: 120,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFD1D5DB)),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SignatureGestureShield(
                                child: Signature(
                                  controller: _sigTecnicoCtrl,
                                  height: 120,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => _sigTecnicoCtrl.clear(),
                              icon: const Icon(Icons.clear, size: 16),
                              label: const Text('Limpiar firma', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Columna Recibió / Almacén o Cliente
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          esStock
                              ? 'Recibió / Almacén o Laboratorio (Opcional en Stock)'
                              : 'Recibió / Cliente (Obligatorio)',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _pesaDark),
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          _cliNombreCtrl,
                          esStock ? 'Nombre de quien recibe (opcional)' : 'Nombre de quien recibe *',
                        ),
                        if (_contactosSugeridos.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: _contactosSugeridos.take(4).map((c) {
                              return ActionChip(
                                label: Text(c, style: const TextStyle(fontSize: 11)),
                                onPressed: () {
                                  setState(() => _cliNombreCtrl.text = c);
                                  _programarAutoGuardado();
                                },
                              );
                            }).toList(),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _buildTextField(_cliPuestoCtrl, 'Puesto / Área'),
                        const SizedBox(height: 10),
                        Container(
                          height: 120,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFD1D5DB)),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SignatureGestureShield(
                              child: Signature(
                                controller: _sigClienteCtrl,
                                height: 120,
                                backgroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _sigClienteCtrl.clear(),
                            icon: const Icon(Icons.clear, size: 16),
                            label: const Text('Limpiar firma', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController ctrl,
    String label, {
    String? hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
