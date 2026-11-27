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
import '../services/metrology_helper.dart';
import '../services/pdf_service.dart';
import '../services/sync_service.dart';
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';
import '../widgets/cliente_correo_poka_yoke.dart';
import '../widgets/nombre_recibe.dart';
import '../widgets/signature_shield.dart';
import 'pdf_preview_aprobacion_screen.dart';

class RevisionBasculaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const RevisionBasculaScreen({super.key, required this.orden});

  @override
  State<RevisionBasculaScreen> createState() => _RevisionBasculaScreenState();
}

class _RevisionBasculaScreenState extends State<RevisionBasculaScreen> {
  static const Color _pesaRed = PesaColors.brand;

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
  final _correoCtrl = ClienteCorreoController();
  List<String> _contactosSugeridos = [];

  // BLINDAJE DE FIRMA: tinta negra (#000000) fija sobre fondo blanco (#FFFFFF) incluso en Dark Mode
  final _sigClienteCtrl = SignatureController(
    penStrokeWidth: 2.5,
    penColor: PesaColors.signatureInk,
    exportPenColor: PesaColors.signatureInk,
    exportBackgroundColor: PesaColors.signatureCanvas,
  );
  final _sigTecnicoCtrl = SignatureController(
    penStrokeWidth: 2.5,
    penColor: PesaColors.signatureInk,
    exportPenColor: PesaColors.signatureInk,
    exportBackgroundColor: PesaColors.signatureCanvas,
  );

  Uint8List? _firmaTecPre;
  bool _usarFirmaPre = false;
  bool _guardando = false;
  bool _vistaPreviaAprobada = false;
  final GlobalKey _firmaSectionKey = GlobalKey();
  bool _guardandoParcial = false;

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
    _divMinCtrl.text = formatearDivisionMinima(_pickFromMap(merged, [
      'div_minima',
      'division_minima',
      'instrumento_division',
      'division',
    ]));
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

    await _correoCtrl.inicializarDesdeOrden(_datosCombinados);
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
    if (_correoCtrl.correoParaGuardar.isNotEmpty) {
      payload['correo_cliente'] = _correoCtrl.correoParaGuardar;
      payload['correo_destino'] = _correoCtrl.correoParaGuardar;
    }
    payload['sin_correo_cliente'] = _correoCtrl.sinCorreoCliente;
    if (_correoCtrl.motivoSinCorreoEfectivo.isNotEmpty) {
      payload['motivo_sin_correo'] = _correoCtrl.motivoSinCorreoEfectivo;
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

  Future<void> _guardarBorradorSilencioso() async {
    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? '').toString().trim();
    if (folio.isEmpty) return;
    try {
      final payload = _construirPayloadRevision();
      await LocalDbService.instance.saveDraft(folio, payload);
    } catch (_) {}
  }

  Future<void> _abrirVistaPreviaRe() async {
    final tieneFirmaTec = (_usarFirmaPre && _firmaTecPre != null) || _sigTecnicoCtrl.isNotEmpty;
    if (!tieneFirmaTec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta la firma del técnico responsable antes de mostrar la vista previa.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _guardando = true);
    try {
      final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'RE-LOCAL').toString().trim();
      final Uint8List? sigTecBytes =
          (_usarFirmaPre && _firmaTecPre != null) ? _firmaTecPre : await _sigTecnicoCtrl.toPngBytes();
      final String? firmaTecB64 = sigTecBytes != null ? base64Encode(sigTecBytes) : null;
      final String fechaEjecucionHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final payloadPreview = _construirPayloadRevision(
        fechaEjecucionHoy: fechaEjecucionHoy,
        firmaTecB64: firmaTecB64,
        firmaCliB64: null,
      );
      final funcMap = <String, bool>{};
      for (final item in _currentIndicadorItems) {
        funcMap[item] = _funcIndicador[item] ?? false;
      }

      final previewBytes = await PdfService.instance.buildPdfRevisionCeldasBytes(
        rvData: payloadPreview,
        numCeldas: _numCeldas,
        lecturasOhms: _obtenerMatrizOhms(),
        funcIndicador: funcMap,
        estadoCeldas: List.generate(_numCeldas, (i) => _estadoCeldas[i]),
        estadoCables: _estadoCables,
        estadoConectores: _estadoConectores,
        firmaTecBase64: firmaTecB64,
        firmaCliBase64: null,
        modoPreviewSinFirma: true,
      );
      if (!mounted) return;
      setState(() => _guardando = false);

      final aprobado = await PdfPreviewAprobacionScreen.mostrar(
        context,
        folio: folio,
        pdfBytes: previewBytes,
        tipoDocumento: 'Revisión de Celdas y Báscula (RE)',
      );
      if (aprobado && mounted) {
        setState(() => _vistaPreviaAprobada = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _firmaSectionKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generando vista previa RE: $e'), backgroundColor: _pesaRed),
        );
      }
    }
  }

  Future<void> _finalizar() async {
    if (!_vistaPreviaAprobada) {
      await _abrirVistaPreviaRe();
      return;
    }
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

    if (!_correoCtrl.isValido) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(kMsgPokaYokeCorreo),
          backgroundColor: PesaColors.brand,
        ),
      );
      return;
    }

    setState(() => _guardando = true);
    try {
      final localId = widget.orden['local_id'] as int? ?? 0;
      final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'RE-LOCAL').toString().trim();
      final loteKeyPre = _pickFromMap(_datosCombinados, ['lote_id', 'id_lote', 'lote']);
      final correoCapturado = await _correoCtrl.persistirEnOrdenYLote(
        folio: folio,
        loteId: loteKeyPre,
        ordenMutable: _datosCombinados,
      );

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

      // Invalidar cualquier PDF anterior en caché local antes de emitir el definitivo
      await LocalDbService.instance.invalidarPdfLocal(folio);

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
        modoPreviewSinFirma: false,
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
      final loteKey = _pickFromMap(_datosCombinados, ['lote_id', 'id_lote']);
      if (loteKey.isNotEmpty && loteKey.toLowerCase() != 'null' && loteKey.toLowerCase() != 'none') {
        LoteSession.registrarResponsable(loteKey, nombreReceptor);
      }

      await LocalDbService.instance.saveFirmas(
        localId: localId,
        folio: folio,
        firmaTecBase64: firmaTecB64 ?? '',
        firmaCliBase64: firmaCliB64 ?? '',
        nombreIng: nombreReceptor,
        puestoIng: '',
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
    _correoCtrl.dispose();
    _sigClienteCtrl.dispose();
    _sigTecnicoCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI PRINCIPAL
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
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
      backgroundColor: c.canvas,
      appBar: AppBar(
        backgroundColor: c.surface,
        foregroundColor: c.textPrimary,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: c.border),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ficha Técnica Diagnóstica · $folio',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
            ),
            Text(
              'REVISIÓN DE CELDAS Y BÁSCULA · $cliente',
              style: TextStyle(fontSize: 11, color: c.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Guardar avance local',
            icon: Icon(Icons.save_outlined, color: c.textPrimary),
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
      body: SigningScrollLock(
        builder: (ctx, physics, _) => ListView(
          physics: physics,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            foldableHorizontalPadding(ctx),
            14,
            foldableHorizontalPadding(ctx),
            bottomInset + 36,
          ),
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
            KeyedSubtree(key: _firmaSectionKey, child: _buildSeccion5ObservacionesFirmasCard(cliente)),
            const SizedBox(height: 20),

            // ── BOTÓN VISTA PREVIA → FINALIZAR Y GENERAR PDF OFICIAL ───────────
            AnimatedBuilder(
              animation: _correoCtrl,
              builder: (_, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_vistaPreviaAprobada) ...[
                    ClienteCorreoLockBanner(controller: _correoCtrl),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _guardando ? null : _abrirVistaPreviaRe,
                          icon: const Icon(Icons.preview_outlined, size: 18),
                          label: const Text('Vista Previa'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: c.textPrimary,
                            side: BorderSide(color: c.borderStrong),
                            minimumSize: const Size(0, 52),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 52,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: PesaColors.brand,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: c.surfaceMuted,
                                disabledForegroundColor: c.textTertiary,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: (_guardando || !_correoCtrl.isValido) ? null : _finalizar,
                              icon: _guardando
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                    )
                                  : Icon(!_correoCtrl.isValido ? Icons.lock_outline_rounded : Icons.picture_as_pdf_rounded, size: 20),
                              label: Text(
                                _guardando
                                    ? 'GENERANDO PDF FINAL...'
                                    : 'CONFIRMAR FIRMA Y FINALIZAR',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, letterSpacing: 0.2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: PesaColors.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _guardando ? null : _abrirVistaPreviaRe,
                        icon: _guardando
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                              )
                            : const Icon(Icons.preview_outlined, size: 22),
                        label: Text(
                          _guardando
                              ? 'PREPARANDO VISTA PREVIA...'
                              : 'REVISAR VISTA PREVIA (SIN FIRMA)',
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, letterSpacing: 0.3),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Encabezado numerado estilo formato físico oficial ──────────────────────
  Widget _buildOfficialSectionHeader(int number, String title, {Widget? trailing}) {
    final c = PesaColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.isDark ? c.elevated : PesaColors.textPrimary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
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
    final c = PesaColors.of(context);
    return Card(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
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
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '1. RAZÓN SOCIAL / CLIENTE: $cliente',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: c.textPrimary),
                      ),
                      if (direccion.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'DIRECCIÓN: $direccion',
                          style: TextStyle(fontSize: 11.5, color: c.textSecondary),
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
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.brandAccent.withValues(alpha: 0.45)),
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
                          Icon(Icons.linear_scale, color: c.brandAccent, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'NÚMERO DE CELDAS (PUNTOS DE APOYO):',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary),
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
                                  color: _numCeldas == preset ? Colors.white : c.textPrimary,
                                ),
                              ),
                              selected: _numCeldas == preset,
                              showCheckmark: false,
                              selectedColor: _pesaRed,
                              backgroundColor: c.surface,
                              side: BorderSide(color: _numCeldas == preset ? _pesaRed : c.borderStrong),
                              onSelected: (_) {
                                setState(() => _numCeldas = preset);
                                _guardarBorradorSilencioso();
                              },
                            ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: c.elevated,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: c.borderStrong),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: _numCeldas,
                                dropdownColor: c.surface,
                                style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                                isDense: true,
                                items: List.generate(
                                  12,
                                  (i) => DropdownMenuItem(
                                    value: i + 1,
                                    child: Text('${i + 1} Celdas', style: TextStyle(fontSize: 12.5, color: c.textPrimary)),
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
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'DATOS DE CELDAS DE CARGA',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: c.textSecondary),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _tipoEstructura,
                              dropdownColor: c.surface,
                              isDense: true,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c.brandAccent),
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
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      backgroundColor: c.surface,
                      side: BorderSide(color: c.borderStrong, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _guardandoParcial
                        ? null
                        : () async {
                            final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? '').toString().trim();
                            if (folio.isEmpty) return;
                            setState(() => _guardandoParcial = true);
                            try {
                              await _guardarBorradorSilencioso();
                              final parcial = <String, dynamic>{
                                'marca': _marcaIndCtrl.text.trim(),
                                'modelo': _modeloIndCtrl.text.trim(),
                                'serie': _serieIndCtrl.text.trim(),
                                'ns': _serieIndCtrl.text.trim(),
                                'id_indicador': _idIndCtrl.text.trim(),
                                'id_equipo': _idIndCtrl.text.trim(),
                                'capacidad_maxima': _capMaxCtrl.text.trim(),
                                'division_minima': formatearDivisionMinima(_divMinCtrl.text.trim()),
                                'ubicacion': _ubicacionCtrl.text.trim(),
                                'tipo_instrumento': _tipoEstructura,
                              };
                              final ok = await context.read<SyncService>().guardarYSincronizarInstrumentoParcial(
                                    folio,
                                    parcial,
                                    localId: widget.orden['local_id'] as int?,
                                  );
                              if (mounted) {
                                final etiq = construirEtiquetaInstrumento({'folio_os': folio, ...parcial});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: ok ? const Color(0xFF15803D) : const Color(0xFF1D1D1F),
                                    content: Text(
                                      ok
                                          ? 'Equipo guardado y sincronizado (orden sigue En Proceso): $etiq'
                                          : 'Equipo guardado localmente (se sincronizará al conectar): $etiq',
                                    ),
                                  ),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _guardandoParcial = false);
                            }
                          },
                    icon: _guardandoParcial
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _pesaRed),
                          )
                        : const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Text(
                      _guardandoParcial
                          ? 'Guardando y sincronizando equipo...'
                          : 'Guardar Datos de Equipo (Sin Finalizar)',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
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
    final c = PesaColors.of(context);
    return TextField(
      controller: ctrl,
      scrollPadding: const EdgeInsets.only(bottom: 180),
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
      onChanged: (_) => _guardarBorradorSilencioso(),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 11, color: c.textSecondary),
        isDense: true,
        filled: true,
        fillColor: c.elevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.border)),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TARJETA SECCIÓN 3: LECTURAS SIN CARGA — N CELDAS (OHMS / MV)
  // 11 filas oficiales x C-1..C-N expandida al 100% del ancho
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSeccion3OhmsCard() {
    final p = PesaColors.of(context);
    final sPlural = _numCeldas > 1 ? 'S' : '';
    return Card(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.border),
      ),
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
                          decoration: BoxDecoration(
                            color: p.isDark ? p.elevated : PesaColors.textPrimary,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
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
                              color: r.isEven ? p.surfaceMuted : p.surface,
                              border: Border(
                                left: BorderSide(color: p.border),
                                right: BorderSide(color: p.border),
                                bottom: BorderSide(color: p.border),
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
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: p.textPrimary,
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
                                        color: _ohmsParams[r][2] == 'mV' ? p.brandAccent : p.textSecondary,
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
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: p.textPrimary,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: '—',
                                          hintStyle: TextStyle(color: p.textTertiary, fontSize: 12),
                                          isDense: true,
                                          filled: true,
                                          fillColor: p.elevated,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(5),
                                            borderSide: BorderSide(color: p.border),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(5),
                                            borderSide: BorderSide(color: p.border),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(5),
                                            borderSide: BorderSide(color: p.brandAccent, width: 1.5),
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
    final c = PesaColors.of(context);
    final indItems = _currentIndicadorItems;

    return Card(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
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
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
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
    final c = PesaColors.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: c.isDark ? c.elevated : PesaColors.textSecondary,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
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
              color: i.isEven ? c.surfaceMuted : c.surface,
              child: CheckboxListTile(
                dense: true,
                visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: _pesaRed,
                title: Text(
                  indItems[i],
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textPrimary),
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
    final c = PesaColors.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: c.isDark ? c.elevated : PesaColors.textSecondary,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
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
                color: i.isEven ? c.surfaceMuted : c.surface,
                border: Border(
                  bottom: i < _numCeldas - 1 ? BorderSide(color: c.border) : BorderSide.none,
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
    final c = PesaColors.of(context);
    final isOk = currentValue.toUpperCase() == 'OK';
    final isFalla = currentValue.toUpperCase() == 'FALLA';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged('OK'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isOk ? Colors.green.shade700 : c.elevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isOk ? Colors.green.shade700 : c.borderStrong),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOk ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: isOk ? Colors.white : c.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  'OK',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: isOk ? Colors.white : c.textPrimary,
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
              color: isFalla ? _pesaRed : c.elevated,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: isFalla ? _pesaRed : c.borderStrong),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFalla ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: isFalla ? Colors.white : c.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  'Falla',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: isFalla ? Colors.white : c.textPrimary,
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
    final c = PesaColors.of(context);
    final loteKey = _pickFromMap(_datosCombinados, ['lote_id', 'id_lote']);
    final sugerenciaLote = (loteKey.isNotEmpty && loteKey.toLowerCase() != 'null' && loteKey.toLowerCase() != 'none')
        ? LoteSession.getUltimoResponsable(loteKey)
        : null;
    final mostrarChipLote = sugerenciaLote != null &&
        sugerenciaLote.isNotEmpty &&
        !esRazonSocialEmpresa(sugerenciaLote, cliente) &&
        _nombreReceptorCtrl.text.trim() != sugerenciaLote;

    return Card(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
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
                      avatar: Icon(Icons.person_pin_circle, size: 18, color: c.brandAccent),
                      backgroundColor: c.surfaceMuted,
                      side: BorderSide(color: c.borderStrong),
                      label: Text(
                        'Usar receptor del lote: $sugerenciaLote',
                        style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600),
                      ),
                      onPressed: () {
                        setState(() => _nombreReceptorCtrl.text = sugerenciaLote);
                        _guardarBorradorSilencioso();
                      },
                    ),
                  ),

                // Chips de contactos frecuentes de esta planta
                if (_contactosSugeridos.isNotEmpty) ...[
                  Text(
                    'Contactos frecuentes en planta:',
                    style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _contactosSugeridos
                        .map(
                          (contacto) => ActionChip(
                            label: Text(contacto, style: const TextStyle(fontSize: 12)),
                            onPressed: () {
                              setState(() => _nombreReceptorCtrl.text = contacto);
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

                // Pads de Firma Cliente y Técnico (conciencia de bisagra + 2 cols desplegado)
                FoldableTwoColumn(
                  horizontalGap: 16,
                  verticalGap: 14,
                  first: _buildFirmaClienteBlock(),
                  second: _buildFirmaTecnicoBlock(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirmaClienteBlock() {
    final c = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClienteCorreoPokaYokeCard(
          controller: _correoCtrl,
          loteId: _pickFromMap(_datosCombinados, ['id_lote', 'lote', 'lote_id']),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('FIRMA DEL CLIENTE *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary)),
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
            color: PesaColors.signatureCanvas,
            border: Border.all(color: c.borderStrong),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SignatureGestureShield(
              child: Signature(controller: _sigClienteCtrl, backgroundColor: PesaColors.signatureCanvas),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFirmaTecnicoBlock() {
    final c = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('FIRMA DEL TÉCNICO *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: c.textPrimary)),
            if (_firmaTecPre != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Usar precargada', style: TextStyle(fontSize: 12, color: c.textSecondary)),
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
              color: PesaColors.signatureCanvas,
              border: Border.all(color: c.borderStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(child: Image.memory(_firmaTecPre!, height: 110)),
          )
        else
          Container(
            height: 145,
            decoration: BoxDecoration(
              color: PesaColors.signatureCanvas,
              border: Border.all(color: c.borderStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SignatureGestureShield(
                child: Signature(controller: _sigTecnicoCtrl, backgroundColor: PesaColors.signatureCanvas),
              ),
            ),
          ),
      ],
    );
  }
}
