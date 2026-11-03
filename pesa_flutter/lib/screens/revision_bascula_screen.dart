// lib/screens/revision_bascula_screen.dart
// Pantalla Digital Homologada 1:1 con el Formato Físico Oficial:
// "FICHA TECNICA DIAGNOSTICA — REVISION DE CELDAS DE CARGA Y BASCULA (RE)"
// Secciones:
//   1. Datos del Cliente
//   2. Datos del Equipo / Indicador + Celdas de Carga + Selector de Número de Celdas (1..12)
//   3. Lecturas Sin Carga — N Celdas (Ohms / mV) — 11 filas oficiales al 100% de ancho
//   4. Funcionalidad de Celdas e Indicador (Indicador/Display + Estado Individual de Celdas + Cables/Conectores)
//   5. Observaciones y Firmas (Nombre de quien recibe obligatorio y vacío por defecto)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';

import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/pdf_service.dart';
import '../services/sync_service.dart';
import '../widgets/nombre_recibe.dart';

class RevisionBasculaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const RevisionBasculaScreen({super.key, required this.orden});

  @override
  State<RevisionBasculaScreen> createState() => _RevisionBasculaScreenState();
}

class _RevisionBasculaScreenState extends State<RevisionBasculaScreen> {
  static const Color _pesaRed = Color(0xFFB71C1C);
  static const Color _pesaDark = Color(0xFF1C1C1C);
  static const Color _pesaSlate = Color(0xFF2D2D2D);

  /// 11 filas exactas del formato físico oficial (Sección 3)
  static const List<List<String>> _ohmsParams = [
    ['A', 'Excitacion Exc+ / Exc-', 'Ohms'],
    ['B', 'Resistencia Sig+ / Sig-', 'Ohms'],
    ['C', 'Resistencia Exc+ / Sig+', 'Ohms'],
    ['D', 'Resistencia Exc+ / Sig-', 'Ohms'],
    ['E', 'Resistencia Exc- / Sig+', 'Ohms'],
    ['F', 'Resistencia Exc- / Sig-', 'Ohms'],
    ['G', 'Resistencia Sig- + Exc+', 'Ohms'],
    ['H', 'Resistencia Sig- + Exc-', 'Ohms'],
    ['I', 'Resistencia Exc-+ / Sig+', 'Ohms'],
    ['J', 'Resistencia Exc-+ / Sig-', 'Ohms'],
    ['K', 'Señal de Salida (Milivoltaje)', 'mV'],
  ];

  static const List<String> _baseIndicadorItems = [
    'Indicador de Peso',
    'Teclado / Botones',
    'Luminosidad / Display',
    'Convertidor Analogico',
    'Caja Sumadora',
  ];

  // Controladores Sección 1 y 2 (Equipo / Indicador / Celdas)
  final _marcaIndCtrl = TextEditingController();
  final _modeloIndCtrl = TextEditingController();
  final _serieIndCtrl = TextEditingController();
  final _idIndCtrl = TextEditingController();
  final _capMaxCtrl = TextEditingController();
  final _divMinCtrl = TextEditingController();
  final _ubicacionCtrl = TextEditingController();

  final _celdaAMarcaCtrl = TextEditingController();
  final _celdaAModeloCtrl = TextEditingController();
  final _celdaACapCtrl = TextEditingController();

  String _tipoEstructura = 'PLATAFORMA';
  int _numCeldas = 4; // Soportando 1 a 12 celdas

  // Sección 3: Matriz 11 filas x 12 columnas máximas de TextEditingControllers
  late final List<List<TextEditingController>> _ohmsCtrls;

  // Sección 4: Funcionalidad de Celdas e Indicador
  final Map<String, bool> _funcIndicador = {};
  late final List<String> _estadoCeldas; // 'OK' | 'Falla' | '' para hasta 12 celdas
  String _estadoCables = 'OK';
  String _estadoConectores = 'OK';

  // Sección 5: Observaciones y Firmas
  final _observacionesCtrl = TextEditingController();
  final _nombreReceptorCtrl = TextEditingController();
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

  Map<String, dynamic> _datosCombinados = {};

  @override
  void initState() {
    super.initState();
    _ohmsCtrls = List.generate(
      _ohmsParams.length,
      (_) => List.generate(12, (_) => TextEditingController()),
    );
    _estadoCeldas = List.generate(12, (_) => 'OK');
    for (final item in _baseIndicadorItems) {
      _funcIndicador[item] = true;
    }
    for (int k = 1; k <= 12; k++) {
      _funcIndicador['Potenciometro $k'] = true;
    }
    _cargarDatos();
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
    Map<String, dynamic> merged = Map<String, dynamic>.from(widget.orden);

    // 1. Leer fila completa de SQLite si existe
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

    // 2. Desempaquetar datos_tecnicos_json enviado desde logística / escritorio
    void unpackJsonField(dynamic rawJson) {
      if (rawJson == null) return;
      try {
        final Map<String, dynamic> parsed = rawJson is String
            ? Map<String, dynamic>.from(jsonDecode(rawJson) as Map)
            : Map<String, dynamic>.from(rawJson as Map);
        // Si tiene lista 'equipos', extraer primer equipo como respaldo
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

    // 3. Leer borrador local (si el técnico ya había capturado avances)
    if (folio.isNotEmpty) {
      try {
        final draft = await LocalDbService.instance.getDraft(folio);
        if (draft != null) {
          for (final e in draft.entries) {
            if (e.value != null && e.value.toString().trim().isNotEmpty) {
              merged[e.key] = e.value;
            }
          }
        }
      } catch (_) {}
    }

    _datosCombinados = merged;

    // Precargar datos del instrumento/indicador enviados desde logística
    _marcaIndCtrl.text = _pickFromMap(merged, [
      'indicador_marca',
      'marca',
      'instrumento_marca',
      'celda_a_marca',
    ]);
    _modeloIndCtrl.text = _pickFromMap(merged, [
      'indicador_modelo',
      'modelo',
      'instrumento_modelo',
      'celda_a_modelo',
    ]);
    _serieIndCtrl.text = _pickFromMap(merged, [
      'indicador_serie',
      'ns',
      'serie',
      'numero_serie',
      'instrumento_serie',
    ]);
    _idIndCtrl.text = _pickFromMap(merged, [
      'indicador_id',
      'id_indicador',
      'id_equipo',
      'instrumento_id',
    ]);
    _capMaxCtrl.text = _pickFromMap(merged, [
      'cap_maxima',
      'capacidad_maxima',
      'alcance_max',
      'instrumento_capacidad',
      'capacidad',
    ]);
    _divMinCtrl.text = _pickFromMap(merged, [
      'div_minima',
      'division_minima',
      'instrumento_division',
      'division',
    ]);
    _ubicacionCtrl.text = _pickFromMap(merged, [
      'ubicacion',
      'ubicacion_interna',
      'planta',
    ]);

    _celdaAMarcaCtrl.text = _pickFromMap(merged, ['celda_a_marca', 'marca_celda'], _marcaIndCtrl.text);
    _celdaAModeloCtrl.text = _pickFromMap(merged, ['celda_a_modelo', 'modelo_celda'], _modeloIndCtrl.text);
    _celdaACapCtrl.text = _pickFromMap(merged, ['celda_a_capacidad', 'capacidad_celda'], _capMaxCtrl.text);

    final rawEst = _pickFromMap(merged, ['tipo_estructura', 'tipo_instrumento', 'tipo_equipo'], 'PLATAFORMA').toUpperCase();
    if (rawEst.contains('CAMION')) {
      _tipoEstructura = 'CAMIONERA';
    } else if (rawEst.contains('TOLVA') || rawEst.contains('TANQUE') || rawEst.contains('SILO')) {
      _tipoEstructura = 'TOLVA_TANQUE';
    } else {
      _tipoEstructura = 'PLATAFORMA';
    }

    // Número de celdas (puntos_apoyo / num_celdas / celda_a_cantidad + celda_b_cantidad)
    int nCeldas = 4;
    final rawN = _pickFromMap(merged, ['num_celdas', 'puntos_apoyo']);
    if (rawN.isNotEmpty) {
      nCeldas = int.tryParse(rawN) ?? 4;
    } else {
      final nA = int.tryParse(_pickFromMap(merged, ['celda_a_cantidad'], '4')) ?? 4;
      final mixtas = merged['celdas_mixtas'] == true || merged['celdas_mixtas'] == 1;
      final nB = mixtas ? (int.tryParse(_pickFromMap(merged, ['celda_b_cantidad'], '0')) ?? 0) : 0;
      nCeldas = nA + nB;
    }
    _numCeldas = nCeldas.clamp(1, 12);

    // Restaurar lecturas_ohms si existen en borrador o JSON
    final rawOhms = merged['lecturas_ohms'];
    if (rawOhms is List) {
      for (int r = 0; r < rawOhms.length && r < _ohmsParams.length; r++) {
        final row = rawOhms[r];
        if (row is List) {
          for (int c = 0; c < row.length && c < 12; c++) {
            _ohmsCtrls[r][c].text = (row[c] ?? '').toString();
          }
        } else if (row is Map) {
          for (int c = 0; c < 12; c++) {
            final v = row['C-${c + 1}'] ?? row['$c'] ?? row['${c + 1}'];
            if (v != null) _ohmsCtrls[r][c].text = v.toString();
          }
        }
      }
    }

    // Restaurar func_indicador
    final rawFunc = merged['func_indicador'];
    if (rawFunc is Map) {
      for (final e in rawFunc.entries) {
        _funcIndicador[e.key.toString()] = e.value == true || e.value.toString().toUpperCase() == 'TRUE' || e.value.toString() == '1';
      }
    }

    // Restaurar estado_celdas
    final rawEstCeldas = merged['estado_celdas'];
    if (rawEstCeldas is List) {
      for (int i = 0; i < rawEstCeldas.length && i < 12; i++) {
        final v = (rawEstCeldas[i] ?? '').toString().trim();
        if (v.isNotEmpty) {
          _estadoCeldas[i] = v.toUpperCase() == 'FALLA' ? 'Falla' : 'OK';
        }
      }
    } else if (rawEstCeldas is Map) {
      for (int i = 0; i < 12; i++) {
        final v = rawEstCeldas['Celda ${i + 1}'] ?? rawEstCeldas['C-${i + 1}'] ?? rawEstCeldas['$i'];
        if (v != null && v.toString().trim().isNotEmpty) {
          _estadoCeldas[i] = v.toString().trim().toUpperCase() == 'FALLA' ? 'Falla' : 'OK';
        }
      }
    }

    // Restaurar estado_cables y estado_conectores
    final rawCables = _pickFromMap(merged, ['estado_cables']);
    if (rawCables.isNotEmpty) {
      _estadoCables = rawCables.toUpperCase() == 'FALLA' ? 'Falla' : 'OK';
    }
    final rawConect = _pickFromMap(merged, ['estado_conectores']);
    if (rawConect.isNotEmpty) {
      _estadoConectores = rawConect.toUpperCase() == 'FALLA' ? 'Falla' : 'OK';
    }

    // Observaciones
    _observacionesCtrl.text = _pickFromMap(merged, ['observaciones', 'observaciones_tecnico']);

    // Nombre de quien recibe: NUNCA precargar con la razón social del cliente
    final clienteNombre = _pickFromMap(merged, ['cliente', 'razon_social']);
    for (final k in ['nombre_receptor', 'firma_cliente_nombre', 'nombre_quien_recibe', 'recibido_por']) {
      final v = (merged[k] ?? '').toString().trim();
      if (v.isNotEmpty && !esRazonSocialEmpresa(v, clienteNombre)) {
        _nombreReceptorCtrl.text = v;
        break;
      }
    }

    // Contactos frecuentes de planta
    final dirPlanta = _pickFromMap(merged, ['direccion', 'sucursal_direccion', 'direccion_planta', 'sucursal']);
    try {
      final cs = await LocalDbService.instance.getContactosPlanta(
        cliente: clienteNombre,
        planta: dirPlanta,
      );
      if (mounted) {
        setState(() {
          _contactosSugeridos = cs.where((c) => !esRazonSocialEmpresa(c, clienteNombre)).toList();
        });
      }
    } catch (_) {}

    // Firma del técnico desde FirmaTecnicoService si no estaba en SharedPreferences
    if (_firmaTecPre == null) {
      try {
        final username = (merged['tecnico_username'] ?? merged['tecnico'] ?? '').toString();
        final savedFirmaTec = await FirmaTecnicoService.instance.getFirma(username);
        if (savedFirmaTec != null && savedFirmaTec.isNotEmpty) {
          final clean = savedFirmaTec.contains(',') ? savedFirmaTec.split(',').last : savedFirmaTec;
          _firmaTecPre = base64Decode(clean);
          _usarFirmaPre = true;
        }
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  List<String> get _currentIndicadorItems => [
        ..._baseIndicadorItems,
        for (int k = 1; k <= _numCeldas; k++) 'Potenciometro $k',
      ];

  List<List<String>> _obtenerMatrizOhms() {
    return List.generate(
      _ohmsParams.length,
      (r) => List.generate(_numCeldas, (c) => _ohmsCtrls[r][c].text.trim()),
    );
  }

  Map<String, dynamic> _construirPayloadRevision({
    String? fechaEjecucionHoy,
    String? firmaTecB64,
    String? firmaCliB64,
  }) {
    final ohmsMatrix = _obtenerMatrizOhms();
    final funcMap = <String, bool>{};
    for (final item in _currentIndicadorItems) {
      funcMap[item] = _funcIndicador[item] ?? false;
    }
    final celdasEstadoList = List.generate(_numCeldas, (i) => _estadoCeldas[i]);

    final payload = Map<String, dynamic>.from(_datosCombinados);
    payload['tipo_documento'] = 'RE';
    payload['indicador_marca'] = _marcaIndCtrl.text.trim();
    payload['marca'] = _marcaIndCtrl.text.trim();
    payload['indicador_modelo'] = _modeloIndCtrl.text.trim();
    payload['modelo'] = _modeloIndCtrl.text.trim();
    payload['indicador_serie'] = _serieIndCtrl.text.trim();
    payload['ns'] = _serieIndCtrl.text.trim();
    payload['serie'] = _serieIndCtrl.text.trim();
    payload['indicador_id'] = _idIndCtrl.text.trim();
    payload['id_equipo'] = _idIndCtrl.text.trim();
    payload['id_indicador'] = _idIndCtrl.text.trim();
    payload['cap_maxima'] = _capMaxCtrl.text.trim();
    payload['alcance_max'] = _capMaxCtrl.text.trim();
    payload['instrumento_capacidad'] = _capMaxCtrl.text.trim();
    payload['div_minima'] = _divMinCtrl.text.trim();
    payload['instrumento_division'] = _divMinCtrl.text.trim();
    payload['ubicacion'] = _ubicacionCtrl.text.trim();
    payload['celda_a_marca'] = _celdaAMarcaCtrl.text.trim();
    payload['celda_a_modelo'] = _celdaAModeloCtrl.text.trim();
    payload['celda_a_capacidad'] = _celdaACapCtrl.text.trim();
    payload['celda_a_cantidad'] = _numCeldas;
    payload['num_celdas'] = _numCeldas;
    payload['puntos_apoyo'] = _numCeldas;
    payload['tipo_estructura'] = _tipoEstructura;
    payload['lecturas_ohms'] = ohmsMatrix;
    payload['func_indicador'] = funcMap;
    payload['estado_celdas'] = celdasEstadoList;
    payload['estado_cables'] = _estadoCables;
    payload['estado_conectores'] = _estadoConectores;
    payload['observaciones'] = _observacionesCtrl.text.trim();
    payload['observaciones_tecnico'] = _observacionesCtrl.text.trim();
    payload['nombre_receptor'] = _nombreReceptorCtrl.text.trim();
    payload['firma_cliente_nombre'] = _nombreReceptorCtrl.text.trim();
    payload['nombre_quien_recibe'] = _nombreReceptorCtrl.text.trim();

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

  Future<void> _guardarBorradorSilencioso() async {
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? '').toString().trim();
    if (folio.isEmpty) return;
    try {
      final payload = _construirPayloadRevision();
      await LocalDbService.instance.saveDraft(folio, payload);
    } catch (_) {}
  }

  Future<void> _finalizar() async {
    final cliente = _pickFromMap(_datosCombinados, ['cliente', 'razon_social']);
    final nombreReceptor = _nombreReceptorCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombreReceptor, clienteEmpresa: cliente)) {
      return;
    }

    if (_sigClienteCtrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La firma del cliente es obligatoria para finalizar la Revisión de Celdas'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final tieneFirmaTec = (_usarFirmaPre && _firmaTecPre != null) || _sigTecnicoCtrl.isNotEmpty;
    if (!tieneFirmaTec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta la firma del técnico responsable'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _guardando = true);
    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'RE-LOCAL').toString().trim();

      final sigCliBytes = await _sigClienteCtrl.toPngBytes();
      final Uint8List? sigTecBytes =
          (_usarFirmaPre && _firmaTecPre != null) ? _firmaTecPre : await _sigTecnicoCtrl.toPngBytes();

      final String? firmaCliB64 = sigCliBytes != null ? base64Encode(sigCliBytes) : null;
      final String? firmaTecB64 = sigTecBytes != null ? base64Encode(sigTecBytes) : null;

      // Fecha real de ejecución y cierre
      final String fechaEjecucionHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String fechaCierreIso = DateTime.now().toIso8601String();

      final payload = _construirPayloadRevision(
        fechaEjecucionHoy: fechaEjecucionHoy,
        firmaTecB64: firmaTecB64,
        firmaCliB64: firmaCliB64,
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

      final funcMap = <String, bool>{};
      for (final item in _currentIndicadorItems) {
        funcMap[item] = _funcIndicador[item] ?? false;
      }

      // Generar PDF Oficial homologado con el formato físico RE
      final pdfPath = await PdfService.instance.generarPdfRevisionCeldas(
        rvData: payload,
        numCeldas: _numCeldas,
        lecturasOhms: _obtenerMatrizOhms(),
        funcIndicador: funcMap,
        estadoCeldas: List.generate(_numCeldas, (i) => _estadoCeldas[i]),
        estadoCables: _estadoCables,
        estadoConectores: _estadoConectores,
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

      final dirPlanta = _pickFromMap(_datosCombinados, ['direccion', 'sucursal_direccion', 'direccion_planta', 'sucursal']);
      await LocalDbService.instance.saveContactoPlanta(
        cliente: cliente,
        planta: dirPlanta,
        nombreContacto: nombreReceptor,
      );
      final loteKey = _pickFromMap(_datosCombinados, ['lote_id', 'id_lote', 'sucursal_id', 'cliente'], cliente);
      LoteSession.registrarResponsable(loteKey, nombreReceptor);

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: firmaTecB64 ?? '',
        firmaCliBase64: firmaCliB64 ?? '',
        nombreIng: nombreReceptor,
        puestoIng: '',
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );

      try {
        final db = await LocalDbService.instance.database;
        await db.rawUpdate(
          '''UPDATE ordenes_servicio
             SET fecha = ?,
                 marca = ?,
                 modelo = ?,
                 ns = ?,
                 id_equipo = ?,
                 alcance_max = ?,
                 div_minima = ?,
                 ubicacion = ?,
                 observaciones = ?,
                 tipo_documento = 'RE',
                 datos_tecnicos_json = ?
             WHERE folio_os = ? OR folio = ?''',
          [
            fechaEjecucionHoy,
            _marcaIndCtrl.text.trim(),
            _modeloIndCtrl.text.trim(),
            _serieIndCtrl.text.trim(),
            _idIndCtrl.text.trim(),
            _capMaxCtrl.text.trim(),
            _divMinCtrl.text.trim(),
            _ubicacionCtrl.text.trim(),
            _observacionesCtrl.text.trim(),
            datosJsonStr,
            folio,
            folio,
          ],
        );
      } catch (_) {}

      bool subio = false;
      try {
        subio = await ApiService.instance.uploadPdf(
          folio,
          File(pdfPath),
          osId: localId,
          data: {
            ...payload,
            'tipo_documento': 'RE',
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'datos_tecnicos_json': datosJsonStr,
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
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: payload['fecha_creacion_logistica']?.toString(),
      );

      if (mounted) {
        try {
          context.read<SyncService>().updateLocalOrder(folio, {
            'fecha': fechaEjecucionHoy,
            'fecha_servicio': fechaEjecucionHoy,
            'fecha_cierre': fechaCierreIso,
            'marca': _marcaIndCtrl.text.trim(),
            'modelo': _modeloIndCtrl.text.trim(),
            'ns': _serieIndCtrl.text.trim(),
            'id_equipo': _idIndCtrl.text.trim(),
            'alcance_max': _capMaxCtrl.text.trim(),
            'div_minima': _divMinCtrl.text.trim(),
            'ubicacion': _ubicacionCtrl.text.trim(),
            'pdf_path_local': pdfPath,
            'datos_tecnicos_json': datosJsonStr,
            'estado': 'COMPLETADA_DIGITAL',
            'estatus': 'Cerrado',
            'sync_check_status': subio ? 'SUBIDA_SERVIDOR' : 'PENDIENTE_SUBIDA',
            'sync_status': subio ? 'SINCRONIZADO' : 'PENDIENTE',
          });
        } catch (_) {}
      }

      if (mounted) {
        setState(() => _guardando = false);
        _mostrarDialogoExito(pdfPath, folio);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al finalizar Revisión de Celdas: $e'), backgroundColor: Colors.red),
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
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Ficha Diagnóstica RE Finalizada',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
            ),
          ],
        ),
        content: Text(
          'El formato $folio de Revisión de Celdas de Carga y Báscula fue generado y firmado exitosamente.',
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              OpenFilex.open(pdfPath);
            },
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Ver PDF Oficial'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _pesaRed,
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
  void dispose() {
    _marcaIndCtrl.dispose();
    _modeloIndCtrl.dispose();
    _serieIndCtrl.dispose();
    _idIndCtrl.dispose();
    _capMaxCtrl.dispose();
    _divMinCtrl.dispose();
    _ubicacionCtrl.dispose();
    _celdaAMarcaCtrl.dispose();
    _celdaAModeloCtrl.dispose();
    _celdaACapCtrl.dispose();
    for (final row in _ohmsCtrls) {
      for (final ctrl in row) {
        ctrl.dispose();
      }
    }
    _observacionesCtrl.dispose();
    _nombreReceptorCtrl.dispose();
    _sigClienteCtrl.dispose();
    _sigTecnicoCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI PRINCIPAL
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'RE').toString();
    final cliente = _pickFromMap(_datosCombinados, ['cliente', 'razon_social'], 'Cliente');
    final direccion = _pickFromMap(_datosCombinados, [
      'direccion',
      'sucursal_direccion',
      'direccion_planta',
      'cliente_direccion',
      'sucursal',
    ]);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: const Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: _pesaRed,
        foregroundColor: Colors.white,
        elevation: 2,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ficha Técnica Diagnóstica · $folio',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'REVISIÓN DE CELDAS DE CARGA Y BÁSCULA · $cliente',
              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Guardar avance local',
            icon: const Icon(Icons.save_outlined),
            onPressed: () async {
              await _guardarBorradorSilencioso();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Avance guardado localmente'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(14, 14, 14, bottomInset + 36),
        children: [
          // ── SECCIÓN 1 Y 2: CLIENTE, INDICADOR, CELDAS Y SELECTOR N CELDAS ──
          _buildSeccion1y2Card(cliente, direccion),
          const SizedBox(height: 14),

          // ── SECCIÓN 3: LECTURAS SIN CARGA — N CELDAS (OHMS / MV) ───────────
          _buildSeccion3OhmsCard(),
          const SizedBox(height: 14),

          // ── SECCIÓN 4: FUNCIONALIDAD DE CELDAS E INDICADOR ─────────────────
          _buildSeccion4FuncionalidadCard(),
          const SizedBox(height: 14),

          // ── SECCIÓN 5: OBSERVACIONES Y FIRMAS ──────────────────────────────
          _buildSeccion5ObservacionesFirmasCard(cliente),
          const SizedBox(height: 20),

          // ── BOTÓN FINALIZAR Y GENERAR PDF OFICIAL ──────────────────────────
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _pesaRed,
                foregroundColor: Colors.white,
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _guardando ? null : _finalizar,
              icon: _guardando
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Icon(Icons.picture_as_pdf_rounded, size: 24),
              label: Text(
                _guardando
                    ? 'GENERANDO FICHA TÉCNICA PDF...'
                    : 'FINALIZAR REVISIÓN Y GENERAR PDF OFICIAL',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Encabezado numerado estilo formato físico oficial ──────────────────────
  Widget _buildOfficialSectionHeader(int number, String title, {Widget? trailing}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: const BoxDecoration(
        color: _pesaDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(color: _pesaRed, shape: BoxShape.circle),
            child: Center(
              child: Text(
                '$number',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13.5,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TARJETA SECCIONES 1 Y 2: DATOS DEL CLIENTE, EQUIPO / INDICADOR Y N° CELDAS
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSeccion1y2Card(String cliente, String direccion) {
    return Card(
      elevation: 1.5,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildOfficialSectionHeader(2, 'DATOS DEL EQUIPO / INDICADOR Y CELDAS DE CARGA'),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Resumen de Cliente y Dirección (Sección 1)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '1. RAZÓN SOCIAL / CLIENTE: $cliente',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                      ),
                      if (direccion.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'DIRECCIÓN: $direccion',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Selector superior de Número de Celdas (1 a 12)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _pesaRed.withOpacity(0.35)),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.linear_scale, color: _pesaRed, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'NÚMERO DE CELDAS (PUNTOS DE APOYO):',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _pesaDark),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final preset in [1, 2, 3, 4, 6, 8, 10, 12])
                            ChoiceChip(
                              label: Text(
                                '$preset',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _numCeldas == preset ? Colors.white : _pesaDark,
                                ),
                              ),
                              selected: _numCeldas == preset,
                              selectedColor: _pesaRed,
                              backgroundColor: Colors.white,
                              onSelected: (_) {
                                setState(() => _numCeldas = preset);
                                _guardarBorradorSilencioso();
                              },
                            ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.grey.shade400),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: _numCeldas,
                                isDense: true,
                                items: List.generate(
                                  12,
                                  (i) => DropdownMenuItem(
                                    value: i + 1,
                                    child: Text('${i + 1} Celdas', style: const TextStyle(fontSize: 12.5)),
                                  ),
                                ),
                                onChanged: (v) {
                                  if (v != null) {
                                    setState(() => _numCeldas = v);
                                    _guardarBorradorSilencioso();
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Fila 1 de Indicador: Marca, Modelo, Serie, ID Indicador
                Row(
                  children: [
                    Expanded(child: _buildCompactField('MARCA INDICADOR', _marcaIndCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildCompactField('MODELO INDICADOR', _modeloIndCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildCompactField('No. DE SERIE', _serieIndCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildCompactField('ID INDICADOR', _idIndCtrl)),
                  ],
                ),
                const SizedBox(height: 8),

                // Fila 2 de Indicador: Capacidad Máx., División Mín., Ubicación, Estructura
                Row(
                  children: [
                    Expanded(child: _buildCompactField('CAPACIDAD MÁX.', _capMaxCtrl)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildCompactField('DIVISIÓN MÍN. (d)', _divMinCtrl)),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: _buildCompactField('UBICACIÓN', _ubicacionCtrl)),
                  ],
                ),
                const SizedBox(height: 10),

                // Subbloque CELDAS DE CARGA + TIPO DE ESTRUCTURA
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'DATOS DE CELDAS DE CARGA',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: _pesaSlate),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _tipoEstructura,
                              isDense: true,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _pesaRed),
                              items: const [
                                DropdownMenuItem(value: 'PLATAFORMA', child: Text('Estructura: PLATAFORMA')),
                                DropdownMenuItem(value: 'CAMIONERA', child: Text('Estructura: CAMIONERA')),
                                DropdownMenuItem(value: 'TOLVA_TANQUE', child: Text('Estructura: TOLVA / TANQUE')),
                              ],
                              onChanged: (v) {
                                if (v != null) setState(() => _tipoEstructura = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: _buildCompactField('MARCA CELDA', _celdaAMarcaCtrl)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildCompactField('MODELO CELDA', _celdaAModeloCtrl)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildCompactField('CAPACIDAD INDIV.', _celdaACapCtrl)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactField(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      scrollPadding: const EdgeInsets.only(bottom: 180),
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      onChanged: (_) => _guardarBorradorSilencioso(),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 11),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TARJETA SECCIÓN 3: LECTURAS SIN CARGA — N CELDAS (OHMS / MV)
  // 11 filas oficiales x C-1..C-N expandida al 100% del ancho
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSeccion3OhmsCard() {
    final sPlural = _numCeldas > 1 ? 'S' : '';
    return Card(
      elevation: 1.5,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildOfficialSectionHeader(
            3,
            'LECTURAS SIN CARGA — $_numCeldas CELDA$sPlural (OHMS / MV)',
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Si hay 6 o menos celdas se ajusta al 100% del ancho sin scroll horizontal;
                // si hay más de 6 celdas, permite scroll horizontal cómodo manteniendo 100% mínimo.
                const double paramColW = 190.0;
                const double unitColW = 48.0;
                final double availForCells = constraints.maxWidth - paramColW - unitColW;
                final double minCellW = _numCeldas <= 6 ? 68.0 : 76.0;
                final double calcCellW = availForCells / _numCeldas;
                final double cellW = calcCellW > minCellW ? calcCellW : minCellW;
                final double totalTableW = paramColW + unitColW + (cellW * _numCeldas);

                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalTableW < constraints.maxWidth ? constraints.maxWidth : totalTableW,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Encabezado oscuro [PARAMETRO ELECTRICO | UND | C-1 .. C-N]
                        Container(
                          height: 34,
                          decoration: const BoxDecoration(
                            color: _pesaDark,
                            borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: paramColW,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    'PARAMETRO ELECTRICO',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(
                                width: unitColW,
                                child: Center(
                                  child: Text(
                                    'UND',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ),
                              ),
                              for (int c = 0; c < _numCeldas; c++)
                                Expanded(
                                  child: Center(
                                    child: Text(
                                      'C-${c + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // 11 Filas de parámetros eléctricos
                        for (int r = 0; r < _ohmsParams.length; r++)
                          Container(
                            decoration: BoxDecoration(
                              color: r.isEven ? const Color(0xFFF9FAFB) : Colors.white,
                              border: Border(
                                left: BorderSide(color: Colors.grey.shade300),
                                right: BorderSide(color: Colors.grey.shade300),
                                bottom: BorderSide(color: Colors.grey.shade300),
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: paramColW,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: Text(
                                      _ohmsParams[r][1],
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: _pesaDark,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: unitColW,
                                  child: Center(
                                    child: Text(
                                      _ohmsParams[r][2],
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: _ohmsParams[r][2] == 'mV' ? _pesaRed : Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                ),
                                for (int c = 0; c < _numCeldas; c++)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 3),
                                      child: TextField(
                                        controller: _ohmsCtrls[r][c],
                                        keyboardType: const TextInputType.numberWithOptions(
                                          decimal: true,
                                          signed: true,
                                        ),
                                        textInputAction: TextInputAction.next,
                                        scrollPadding: const EdgeInsets.only(bottom: 220),
                                        textAlign: TextAlign.center,
                                        onChanged: (_) => _guardarBorradorSilencioso(),
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: _pesaDark,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: '—',
                                          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                          isDense: true,
                                          filled: true,
                                          fillColor: Colors.white,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(5),
                                            borderSide: BorderSide(color: Colors.grey.shade300),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(5),
                                            borderSide: const BorderSide(color: _pesaRed, width: 1.5),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TARJETA SECCIÓN 4: FUNCIONALIDAD DE CELDAS E INDICADOR
  // Izquierda: INDICADOR / DISPLAY | Derecha: ESTADO INDIVIDUAL DE CELDAS
  // Barra inferior: Cables [OK] [Falla] | Conectores [OK] [Falla]
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSeccion4FuncionalidadCard() {
    final indItems = _currentIndicadorItems;

    return Card(
      elevation: 1.5,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildOfficialSectionHeader(4, 'FUNCIONALIDAD DE CELDAS E INDICADOR'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth >= 620;
                    final colIndicador = _buildIndicadorDisplayBox(indItems);
                    final colCeldas = _buildEstadoIndividualCeldasBox();

                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 48, child: colIndicador),
                          const SizedBox(width: 12),
                          Expanded(flex: 52, child: colCeldas),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        colIndicador,
                        const SizedBox(height: 12),
                        colCeldas,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),

                // Barra inferior: Cables y Conectores
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FA),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Wrap(
                    spacing: 28,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _buildOkFallaSelector(
                        label: 'Cables:',
                        currentValue: _estadoCables,
                        onChanged: (val) {
                          setState(() => _estadoCables = val);
                          _guardarBorradorSilencioso();
                        },
                      ),
                      _buildOkFallaSelector(
                        label: 'Conectores:',
                        currentValue: _estadoConectores,
                        onChanged: (val) {
                          setState(() => _estadoConectores = val);
                          _guardarBorradorSilencioso();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndicadorDisplayBox(List<String> indItems) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const BoxDecoration(
              color: _pesaSlate,
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'INDICADOR / DISPLAY',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                InkWell(
                  onTap: () {
                    final allChecked = indItems.every((k) => _funcIndicador[k] == true);
                    setState(() {
                      for (final k in indItems) {
                        _funcIndicador[k] = !allChecked;
                      }
                    });
                    _guardarBorradorSilencioso();
                  },
                  child: const Text(
                    'Marcar/Desmarcar todo',
                    style: TextStyle(color: Colors.white70, fontSize: 11, decoration: TextDecoration.underline),
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < indItems.length; i++)
            Container(
              color: i.isEven ? const Color(0xFFF8F9FA) : Colors.white,
              child: CheckboxListTile(
                dense: true,
                visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: _pesaRed,
                title: Text(
                  indItems[i],
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                value: _funcIndicador[indItems[i]] ?? false,
                onChanged: (v) {
                  setState(() => _funcIndicador[indItems[i]] = v ?? false);
                  _guardarBorradorSilencioso();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEstadoIndividualCeldasBox() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const BoxDecoration(
              color: _pesaSlate,
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ESTADO INDIVIDUAL DE CELDAS',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                InkWell(
                  onTap: () {
                    setState(() {
                      for (int i = 0; i < _numCeldas; i++) {
                        _estadoCeldas[i] = 'OK';
                      }
                    });
                    _guardarBorradorSilencioso();
                  },
                  child: const Text(
                    'Todas OK',
                    style: TextStyle(color: Colors.white70, fontSize: 11, decoration: TextDecoration.underline),
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < _numCeldas; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: i.isEven ? const Color(0xFFF8F9FA) : Colors.white,
                border: Border(
                  bottom: i < _numCeldas - 1 ? BorderSide(color: Colors.grey.shade200) : BorderSide.none,
                ),
              ),
              child: _buildOkFallaSelector(
                label: 'Celda ${i + 1}:',
                currentValue: _estadoCeldas[i],
                onChanged: (val) {
                  setState(() => _estadoCeldas[i] = val);
                  _guardarBorradorSilencioso();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOkFallaSelector({
    required String label,
    required String currentValue,
    required ValueChanged<String> onChanged,
  }) {
    final isOk = currentValue.toUpperCase() == 'OK';
    final isFalla = currentValue.toUpperCase() == 'FALLA';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _pesaDark),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged('OK'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isOk ? Colors.green.shade700 : Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isOk ? Colors.green.shade700 : Colors.grey.shade400),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOk ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: isOk ? Colors.white : Colors.grey.shade700,
                ),
                const SizedBox(width: 5),
                Text(
                  'OK',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: isOk ? Colors.white : _pesaDark,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged('Falla'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isFalla ? _pesaRed : Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isFalla ? _pesaRed : Colors.grey.shade400),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFalla ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: isFalla ? Colors.white : Colors.grey.shade700,
                ),
                const SizedBox(width: 5),
                Text(
                  'Falla',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: isFalla ? Colors.white : _pesaDark,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TARJETA SECCIÓN 5: OBSERVACIONES Y FIRMAS
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSeccion5ObservacionesFirmasCard(String cliente) {
    final loteKey = _pickFromMap(_datosCombinados, ['lote_id', 'id_lote', 'sucursal_id', 'cliente'], cliente);
    final sugerenciaLote = LoteSession.getUltimoResponsable(loteKey);
    final mostrarChipLote = sugerenciaLote != null &&
        sugerenciaLote.isNotEmpty &&
        !esRazonSocialEmpresa(sugerenciaLote, cliente) &&
        _nombreReceptorCtrl.text.trim() != sugerenciaLote;

    return Card(
      elevation: 1.5,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildOfficialSectionHeader(5, 'OBSERVACIONES Y FIRMAS'),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // OBSERVACIONES
                TextField(
                  controller: _observacionesCtrl,
                  maxLines: 3,
                  scrollPadding: const EdgeInsets.only(bottom: 180),
                  onChanged: (_) => _guardarBorradorSilencioso(),
                  decoration: InputDecoration(
                    labelText: 'OBSERVACIONES DIAGNÓSTICAS',
                    hintText: 'Anote hallazgos sobre celdas, caja sumadora, humedad, blindaje de cables...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 14),

                // Chip de autocompletado si pertenece a un lote
                if (mostrarChipLote)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ActionChip(
                      avatar: const Icon(Icons.person_pin_circle, size: 18, color: Color(0xFF1565C0)),
                      backgroundColor: const Color(0xFFE3F2FD),
                      label: Text(
                        'Usar receptor del lote: $sugerenciaLote',
                        style: const TextStyle(color: Color(0xFF0D47A1), fontWeight: FontWeight.w600),
                      ),
                      onPressed: () {
                        setState(() => _nombreReceptorCtrl.text = sugerenciaLote);
                        _guardarBorradorSilencioso();
                      },
                    ),
                  ),

                // Chips de contactos frecuentes de esta planta
                if (_contactosSugeridos.isNotEmpty) ...[
                  const Text(
                    'Contactos frecuentes en planta:',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _contactosSugeridos
                        .map(
                          (c) => ActionChip(
                            label: Text(c, style: const TextStyle(fontSize: 12)),
                            onPressed: () {
                              setState(() => _nombreReceptorCtrl.text = c);
                              _guardarBorradorSilencioso();
                            },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                ],

                // Nombre de quien recibe (Obligatorio, inicia vacío)
                TextField(
                  controller: _nombreReceptorCtrl,
                  scrollPadding: const EdgeInsets.only(bottom: 180),
                  onChanged: (_) => _guardarBorradorSilencioso(),
                  decoration: InputDecoration(
                    labelText: 'Nombre de quien recibe *',
                    hintText: 'Ej. Ing. Juan Pérez (Persona física que recibe en planta)',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 16),

                // Pads de Firma Cliente y Técnico
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth >= 600;
                    final padCliente = _buildFirmaClienteBlock();
                    final padTecnico = _buildFirmaTecnicoBlock();
                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: padCliente),
                          const SizedBox(width: 16),
                          Expanded(child: padTecnico),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        padCliente,
                        const SizedBox(height: 14),
                        padTecnico,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirmaClienteBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('FIRMA DEL CLIENTE *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            TextButton.icon(
              onPressed: () => _sigClienteCtrl.clear(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Limpiar'),
            ),
          ],
        ),
        Container(
          height: 145,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Signature(controller: _sigClienteCtrl, backgroundColor: Colors.white),
        ),
      ],
    );
  }

  Widget _buildFirmaTecnicoBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('FIRMA DEL TÉCNICO *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            if (_firmaTecPre != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Usar precargada', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: _usarFirmaPre,
                    activeColor: _pesaRed,
                    onChanged: (v) => setState(() => _usarFirmaPre = v),
                  ),
                ],
              )
            else
              TextButton.icon(
                onPressed: () => _sigTecnicoCtrl.clear(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Limpiar'),
              ),
          ],
        ),
        if (_usarFirmaPre && _firmaTecPre != null)
          Container(
            height: 145,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(child: Image.memory(_firmaTecPre!, height: 110)),
          )
        else
          Container(
            height: 145,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Signature(controller: _sigTecnicoCtrl, backgroundColor: Colors.white),
          ),
      ],
    );
  }
}
