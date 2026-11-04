// lib/screens/observaciones_bascula_screen.dart
// Pantalla Digital Homologada 1:1 con el Formato Oficial:
// "FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS" (OSOB-26-001)
//
// Secciones exactas e inalterables:
//   SECCIÓN 1. Datos del Cliente y del Equipo
//   SECCIÓN 2. Checklist de Inspección Física y Mecánica (Puntos 1 al 14 en A, B y C)
//   SECCIÓN 3. Pruebas Rápidas de Funcionamiento
//   SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones
//   SECCIÓN 5. Firmas de Conformidad

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

class ObservacionesBasculaScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  const ObservacionesBasculaScreen({super.key, required this.orden});

  @override
  State<ObservacionesBasculaScreen> createState() => _ObservacionesBasculaScreenState();
}

class _ObservacionesBasculaScreenState extends State<ObservacionesBasculaScreen> {
  static const Color _pesaRed = Color(0xFFB81D24);
  static const Color _pesaDark = Color(0xFF1D1D1F);

  static const Map<int, String> _checklistLabels = {
    1: 'Charola / Plato / Cubierta (Sin golpes, deformaciones ni corrosión)',
    2: 'Estructura inferior / Chasis (Soldaduras íntegras, sin fracturas ni óxido severo)',
    3: 'Patas niveladoras (Completas, roscas en buen estado, gomas antiderrapantes firmes)',
    4: 'Nivelación - Gota / Burbuja (Burbuja centrada y nivel visible sin daños)',
    5: 'Topes de sobrecarga y laterales (Con holgura adecuada, sin rozamiento ni obstrucciones)',
    6: 'Limpieza general (Libre de residuos, polvo acumulado, humedad o fauna nociva bajo el plato)',
    7: 'Celda(s) de carga (Sin golpes visibles, corrosión, humedad ni deformación)',
    8: 'Cableado y blindaje (Sin cortes, empalmes improvisados ni aplastamiento; prensaestopas firmes)',
    9: 'Caja suma (Sellada herméticamente, sin sulfatación en bornes ni humedad)',
    10: 'Carcasa y soporte / columna (Fijación firme, sellos en buen estado)',
    11: 'Display / Pantalla (Segmentos o píxeles completos, retroiluminación funcional)',
    12: 'Teclado / Botonera (Membrana íntegra sin perforaciones, respuesta táctil correcta)',
    13: 'Alimentación / Batería (Cable de poder/eliminador sin daños; retención de carga en batería)',
    14: 'Puertos de comunicación (RS-232 / USB / Ethernet / Wi-Fi operando correctamente)',
  };

  // Cabecera de control
  final _ordenServicioRefCtrl = TextEditingController();

  // SECCIÓN 1: Datos del Cliente y del Equipo (100% editables)
  final _clienteCtrl = TextEditingController();
  final _plantaCtrl = TextEditingController();
  final _idTagCtrl = TextEditingController();
  final _marcaCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController();
  final _serieCtrl = TextEditingController();
  final _capMaxCtrl = TextEditingController();
  final _divMinCtrl = TextEditingController();
  final _tipoInstOtroCtrl = TextEditingController();
  String _tipoInstrumento = 'Mesa'; // 'Mesa' | 'Camionera' | 'Colgante' | 'Tolva' | 'Tanque' | 'Otro'

  // SECCIÓN 2: Checklist 1..14
  final Map<int, String> _chkEstado = {for (int i = 1; i <= 14; i++) i: 'B'};
  late final Map<int, TextEditingController> _chkObsCtrls;

  // SECCIÓN 3: Pruebas Rápidas de Funcionamiento
  String _estabCeroEstado = 'Cumple'; // 'Cumple' | 'No cumple'
  final _estabCeroComCtrl = TextEditingController();

  String _retornoCeroEstado = 'Cumple';
  final _retornoCeroComCtrl = TextEditingController();

  String _excentricidadEstado = 'Cumple';
  final _excentricidadDifCtrl = TextEditingController();

  String _repetibilidadEstado = 'Cumple';
  final _repetibilidadCargaCtrl = TextEditingController();

  String _exactitudEstado = 'Cumple';
  String _exactitudReqAjuste = 'No'; // 'Sí' | 'No'

  // SECCIÓN 4: Diagnóstico General, Observaciones y Refacciones
  final _obsTecnicasCtrl = TextEditingController();
  final _refaccionesCtrl = TextEditingController();
  bool _accLimpieza = true;
  bool _accNivelacion = false;
  bool _accAjustePeso = false;
  bool _accRevElectrica = false;
  String _dictamenEstado = 'OPERATIVO'; // 'OPERATIVO' | 'OPERATIVO CON OBSERVACIONES' | 'FUERA DE SERVICIO'

  // SECCIÓN 5: Firmas de Conformidad
  final _tecNombreCtrl = TextEditingController();
  final _tecPuestoCtrl = TextEditingController(text: 'Técnico de Servicio');
  final _cliNombreCtrl = TextEditingController(); // Vacío por defecto y obligatorio
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
      for (int i = 1; i <= 14; i++) i: TextEditingController(),
    };
    _registrarListenersAutoGuardado();
    _cargarDatos();
  }

  void _registrarListenersAutoGuardado() {
    final ctrls = <TextEditingController>[
      _ordenServicioRefCtrl,
      _clienteCtrl,
      _plantaCtrl,
      _idTagCtrl,
      _marcaCtrl,
      _modeloCtrl,
      _serieCtrl,
      _capMaxCtrl,
      _divMinCtrl,
      _tipoInstOtroCtrl,
      ..._chkObsCtrls.values,
      _estabCeroComCtrl,
      _retornoCeroComCtrl,
      _excentricidadDifCtrl,
      _repetibilidadCargaCtrl,
      _obsTecnicasCtrl,
      _refaccionesCtrl,
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
      _guardarBorradorLocal();
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

    Map<String, dynamic>? loadedDraft;
    if (folio.isNotEmpty) {
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
            final bool esBorradorRmaCorrupto =
                (draft.containsKey('partidas') || draft.containsKey('items')) &&
                !draft.containsKey('checklist_inspeccion');
            if (esBorradorRmaCorrupto) {
              await LocalDbService.instance.deleteDraft(folio);
            } else {
              loadedDraft = draft;
              for (final e in draft.entries) {
                if (e.value != null) {
                  merged[e.key] = e.value;
                }
              }
            }
          }
        }
      } catch (_) {}
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
    _ordenServicioRefCtrl.text = pickField(['orden_servicio_ref', 'orden_servicio']);

    // Sección 1
    _clienteCtrl.text = pickField(['cliente', 'razon_social', 'cliente_nombre']);
    _plantaCtrl.text = pickField(['ubicacion', 'sucursal', 'direccion', 'planta']);
    _idTagCtrl.text = pickField(['id_equipo', 'id_indicador', 'indicador_id', 'equipo_id']);
    _marcaCtrl.text = pickField(['marca', 'equipo_marca', 'instrumento_marca']);
    _modeloCtrl.text = pickField(['modelo', 'equipo_modelo', 'instrumento_modelo']);
    _serieCtrl.text = pickField(['serie', 'ns', 'numero_serie', 'equipo_ns']);
    _capMaxCtrl.text = pickField(['capacidad_maxima', 'alcance_max', 'cap_maxima', 'instrumento_capacidad']);
    _divMinCtrl.text = pickField(['division_minima', 'div_minima', 'instrumento_division']);

    final rawTipoInst = pickField(['tipo_instrumento'], 'Mesa');
    final tl = rawTipoInst.toLowerCase();
    if (tl.contains('mesa') || tl.contains('mostrador') || tl.contains('banco')) {
      _tipoInstrumento = 'Mesa';
    } else if (tl.contains('camion')) {
      _tipoInstrumento = 'Camionera';
    } else if (tl.contains('colg') || tl.contains('grua') || tl.contains('grúa')) {
      _tipoInstrumento = 'Colgante';
    } else if (tl.contains('tolva')) {
      _tipoInstrumento = 'Tolva';
    } else if (tl.contains('tanque') || tl.contains('silo')) {
      _tipoInstrumento = 'Tanque';
    } else {
      _tipoInstrumento = 'Otro';
      _tipoInstOtroCtrl.text = _pickFromMap(merged, ['tipo_instrumento_otro'], rawTipoInst == 'Otro' ? '' : rawTipoInst);
    }
    if (_pickFromMap(merged, ['tipo_instrumento_otro']).isNotEmpty) {
      _tipoInstOtroCtrl.text = _pickFromMap(merged, ['tipo_instrumento_otro']);
    }

    // Sección 2: Checklist
    final rawChk = merged['checklist_inspeccion'];
    if (rawChk is Map) {
      for (int i = 1; i <= 14; i++) {
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

    // Sección 3: Pruebas Rápidas
    final rawPruebas = merged['pruebas_rapidas'];
    if (rawPruebas is Map) {
      void loadPr(String key, void Function(String est, String extra) apply) {
        final m = rawPruebas[key];
        if (m is Map) {
          final estRaw = (m['estado'] ?? 'Cumple').toString().trim();
          final est = estRaw.toLowerCase().contains('no') ? 'No cumple' : 'Cumple';
          final extra = (m['comentarios'] ?? m['dif_max'] ?? m['carga_prueba'] ?? m['requiere_ajuste'] ?? '').toString().trim();
          apply(est, extra);
        }
      }

      loadPr('estabilidad_cero', (est, extra) {
        _estabCeroEstado = est;
        _estabCeroComCtrl.text = extra;
      });
      loadPr('retorno_cero', (est, extra) {
        _retornoCeroEstado = est;
        _retornoCeroComCtrl.text = extra;
      });
      loadPr('excentricidad', (est, extra) {
        _excentricidadEstado = est;
        _excentricidadDifCtrl.text = extra;
      });
      loadPr('repetibilidad', (est, extra) {
        _repetibilidadEstado = est;
        _repetibilidadCargaCtrl.text = extra;
      });
      loadPr('exactitud', (est, extra) {
        _exactitudEstado = est;
        _exactitudReqAjuste = (extra.toLowerCase() == 'sí' || extra.toLowerCase() == 'si') ? 'Sí' : 'No';
      });
    }

    // Sección 4: Diagnóstico General, Observaciones y Refacciones
    _obsTecnicasCtrl.text = _pickFromMap(merged, ['observaciones', 'observaciones_tecnicas', 'observaciones_tecnico']);
    _refaccionesCtrl.text = _pickFromMap(merged, ['refacciones_requeridas', 'refacciones_adicionales']);

    final rawAcc = merged['acciones_realizadas'];
    if (rawAcc is Map) {
      _accLimpieza = rawAcc['limpieza'] == true;
      _accNivelacion = rawAcc['nivelacion'] == true;
      _accAjustePeso = rawAcc['ajuste_peso'] == true;
      _accRevElectrica = rawAcc['revision_electrica'] == true;
    } else if (rawAcc is List) {
      final listLower = rawAcc.map((e) => e.toString().toLowerCase()).toList();
      _accLimpieza = listLower.any((s) => s.contains('limpieza'));
      _accNivelacion = listLower.any((s) => s.contains('nivelac'));
      _accAjustePeso = listLower.any((s) => s.contains('ajuste'));
      _accRevElectrica = listLower.any((s) => s.contains('eléctric') || s.contains('electric'));
    }

    final rawDict = _pickFromMap(merged, ['dictamen_estado', 'dictamen'], 'OPERATIVO').toUpperCase();
    if (rawDict.contains('OBSERVACION')) {
      _dictamenEstado = 'OPERATIVO CON OBSERVACIONES';
    } else if (rawDict.contains('FUERA') || rawDict == 'NO APTO') {
      _dictamenEstado = 'FUERA DE SERVICIO';
    } else {
      _dictamenEstado = 'OPERATIVO';
    }

    // Sección 5: Firmas
    String tecNom = _pickFromMap(merged, ['tecnico', 'tecnico_nombre']);
    if (tecNom.isEmpty && mounted) {
      try {
        final auth = context.read<AuthService>();
        tecNom = auth.nombreCompleto ?? auth.username ?? '';
      } catch (_) {}
    }
    _tecNombreCtrl.text = tecNom;
    _tecPuestoCtrl.text = _pickFromMap(merged, ['puesto_tecnico'], 'Técnico de Servicio');

    final clienteNombre = _clienteCtrl.text.trim();
    for (final k in ['nombre_receptor', 'firma_cliente_nombre', 'nombre_quien_recibe', 'nombre_ing']) {
      final v = (merged[k] ?? '').toString().trim();
      if (v.isNotEmpty && !esRazonSocialEmpresa(v, clienteNombre)) {
        _cliNombreCtrl.text = v;
        break;
      }
    }
    _cliPuestoCtrl.text = _pickFromMap(merged, ['puesto_receptor', 'area_puesto_cliente', 'puesto_ing']);

    // Contactos sugeridos de planta
    try {
      final cs = await LocalDbService.instance.getContactosPlanta(
        cliente: clienteNombre,
        planta: _plantaCtrl.text.trim(),
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
    for (int i = 1; i <= 14; i++) {
      checklistMap['$i'] = {
        'estado': _chkEstado[i] ?? 'B',
        'observaciones': _chkObsCtrls[i]?.text.trim() ?? '',
      };
    }

    final pruebasMap = <String, Map<String, String>>{
      'estabilidad_cero': {
        'estado': _estabCeroEstado,
        'comentarios': _estabCeroComCtrl.text.trim(),
      },
      'retorno_cero': {
        'estado': _retornoCeroEstado,
        'comentarios': _retornoCeroComCtrl.text.trim(),
      },
      'excentricidad': {
        'estado': _excentricidadEstado,
        'dif_max': _excentricidadDifCtrl.text.trim(),
      },
      'repetibilidad': {
        'estado': _repetibilidadEstado,
        'carga_prueba': _repetibilidadCargaCtrl.text.trim(),
      },
      'exactitud': {
        'estado': _exactitudEstado,
        'requiere_ajuste': _exactitudReqAjuste,
      },
    };

    final accionesMap = <String, bool>{
      'limpieza': _accLimpieza,
      'nivelacion': _accNivelacion,
      'ajuste_peso': _accAjustePeso,
      'revision_electrica': _accRevElectrica,
    };

    final payload = Map<String, dynamic>.from(_datosCombinados);
    payload['tipo_documento'] = 'OSOB';
    payload['tipo_servicio'] = 'Formato de Inspección y Revisión de Básculas';
    payload['orden_servicio_ref'] = _ordenServicioRefCtrl.text.trim();
    payload['orden_servicio'] = _ordenServicioRefCtrl.text.trim();

    // Sección 1
    payload['cliente'] = _clienteCtrl.text.trim();
    payload['razon_social'] = _clienteCtrl.text.trim();
    payload['ubicacion'] = _plantaCtrl.text.trim();
    payload['sucursal'] = _plantaCtrl.text.trim();
    payload['id_equipo'] = _idTagCtrl.text.trim();
    payload['id_indicador'] = _idTagCtrl.text.trim();
    payload['indicador_id'] = _idTagCtrl.text.trim();
    payload['marca'] = _marcaCtrl.text.trim();
    payload['modelo'] = _modeloCtrl.text.trim();
    payload['serie'] = _serieCtrl.text.trim();
    payload['ns'] = _serieCtrl.text.trim();
    payload['numero_serie'] = _serieCtrl.text.trim();
    payload['capacidad_maxima'] = _capMaxCtrl.text.trim();
    payload['alcance_max'] = _capMaxCtrl.text.trim();
    payload['instrumento_capacidad'] = _capMaxCtrl.text.trim();
    payload['division_minima'] = _divMinCtrl.text.trim();
    payload['div_minima'] = _divMinCtrl.text.trim();
    payload['instrumento_division'] = _divMinCtrl.text.trim();
    payload.remove('indicador_marca_modelo');
    payload['tipo_instrumento'] = _tipoInstrumento;
    payload['tipo_instrumento_otro'] = _tipoInstOtroCtrl.text.trim();

    // Sección 2, 3, 4
    payload['checklist_inspeccion'] = checklistMap;
    payload['pruebas_rapidas'] = pruebasMap;
    payload['observaciones'] = _obsTecnicasCtrl.text.trim();
    payload['observaciones_tecnicas'] = _obsTecnicasCtrl.text.trim();
    payload['observaciones_tecnico'] = _obsTecnicasCtrl.text.trim();
    payload['acciones_realizadas'] = accionesMap;
    payload['refacciones_requeridas'] = _refaccionesCtrl.text.trim();
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

  Future<void> _guardarBorradorLocal() async {
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
               div_minima = ?,
               ubicacion = ?,
               observaciones = ?,
               dictamen = ?,
               datos_tecnicos_json = ?
           WHERE folio_os = ? OR folio = ?''',
        [
          _marcaCtrl.text.trim(),
          _modeloCtrl.text.trim(),
          _serieCtrl.text.trim(),
          _idTagCtrl.text.trim(),
          _capMaxCtrl.text.trim(),
          _divMinCtrl.text.trim(),
          _plantaCtrl.text.trim(),
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

  Future<void> _guardarBorradorSilencioso() => _guardarBorradorLocal();

  Future<void> _finalizar() async {
    final cliente = _clienteCtrl.text.trim();
    final nombreReceptor = _cliNombreCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombreReceptor, clienteEmpresa: cliente)) {
      return;
    }

    if (_sigClienteCtrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La firma de conformidad del cliente / usuario es obligatoria.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final tieneFirmaTec = (_usarFirmaPre && _firmaTecPre != null) || _sigTecnicoCtrl.isNotEmpty;
    if (!tieneFirmaTec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta la firma del técnico que realizó la revisión.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final folio = (widget.orden['folio_os'] ?? widget.orden['folio'] ?? 'OSOB-26-001').toString().trim();
    final loteId = _pickFromMap(_datosCombinados, ['id_lote', 'lote']);
    final bool esLote = loteId.isNotEmpty;
    String correoCapturado = _pickFromMap(_datosCombinados, ['correo_cliente', 'email_cliente']);

    if (!esLote) {
      final emailCtrl = TextEditingController(text: correoCapturado);
      final bool? capturo = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.mark_email_read_rounded, color: _pesaRed, size: 26),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Envío de Formato por Correo',
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
                'Ingresa el correo electrónico del cliente para enviar el Formato de Inspección y Revisión de Básculas:',
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
                  prefixIcon: const Icon(Icons.email_outlined, color: _pesaRed),
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
                backgroundColor: _pesaRed,
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
                Icon(Icons.outgoing_mail, color: _pesaRed, size: 26),
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
                  backgroundColor: _pesaRed,
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
      final sigCliBytes = await _sigClienteCtrl.toPngBytes();
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

      final pdfPath = await PdfService.instance.generarPdfObservacionesBascula(
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

      await LocalDbService.instance.saveContactoPlanta(
        cliente: cliente,
        planta: _plantaCtrl.text.trim(),
        nombreContacto: nombreReceptor,
      );
      if (loteId.isNotEmpty) {
        LoteSession.registrarResponsable(loteId, nombreReceptor, puesto: _cliPuestoCtrl.text.trim());
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
                 div_minima = ?,
                 ubicacion = ?,
                 observaciones = ?,
                 dictamen = ?,
                 tipo_documento = 'OSOB',
                 tipo_servicio = 'Formato de Inspección y Revisión de Básculas',
                 correo_cliente = ?,
                 datos_tecnicos_json = ?
             WHERE folio_os = ? OR folio = ?''',
          [
            fechaEjecucionHoy,
            _clienteCtrl.text.trim(),
            _marcaCtrl.text.trim(),
            _modeloCtrl.text.trim(),
            _serieCtrl.text.trim(),
            _idTagCtrl.text.trim(),
            _capMaxCtrl.text.trim(),
            _divMinCtrl.text.trim(),
            _plantaCtrl.text.trim(),
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
              'tipo_documento': 'OSOB',
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
            'cliente': _clienteCtrl.text.trim(),
            'marca': _marcaCtrl.text.trim(),
            'modelo': _modeloCtrl.text.trim(),
            'ns': _serieCtrl.text.trim(),
            'id_equipo': _idTagCtrl.text.trim(),
            'alcance_max': _capMaxCtrl.text.trim(),
            'div_minima': _divMinCtrl.text.trim(),
            'ubicacion': _plantaCtrl.text.trim(),
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
                'Formato OSOB Finalizado',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('El formato $folio (Inspección y Revisión de Básculas) fue generado y firmado exitosamente.'),
            const SizedBox(height: 8),
            if (correo.isNotEmpty)
              Text(
                subio
                    ? '✓ Enviado a $correo (CC: recepcion@basculaspesa.com.mx).'
                    : '⏳ Correo en cola ($correo) — se enviará automáticamente al detectar conexión.',
                style: TextStyle(
                  fontSize: 12,
                  color: subio ? Colors.green.shade800 : Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
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
    _autoSaveDebounce?.cancel();
    _ordenServicioRefCtrl.dispose();
    _clienteCtrl.dispose();
    _plantaCtrl.dispose();
    _idTagCtrl.dispose();
    _marcaCtrl.dispose();
    _modeloCtrl.dispose();
    _serieCtrl.dispose();
    _capMaxCtrl.dispose();
    _divMinCtrl.dispose();
    _tipoInstOtroCtrl.dispose();
    for (final ctrl in _chkObsCtrls.values) {
      ctrl.dispose();
    }
    _estabCeroComCtrl.dispose();
    _retornoCeroComCtrl.dispose();
    _excentricidadDifCtrl.dispose();
    _repetibilidadCargaCtrl.dispose();
    _obsTecnicasCtrl.dispose();
    _refaccionesCtrl.dispose();
    _tecNombreCtrl.dispose();
    _tecPuestoCtrl.dispose();
    _cliNombreCtrl.dispose();
    _cliPuestoCtrl.dispose();
    _sigClienteCtrl.dispose();
    _sigTecnicoCtrl.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI PRINCIPAL
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final folio = (widget.orden['folio'] ?? widget.orden['folio_os'] ?? 'OSOB-26-001').toString().trim();
    final now = DateTime.now();
    final fechaHoyFmt = '${now.day.toString().padLeft(2, '0')} / ${now.month.toString().padLeft(2, '0')} / ${now.year}';

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        await _guardarBorradorLocal();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3F4F6),
        appBar: AppBar(
          backgroundColor: _pesaDark,
          foregroundColor: Colors.white,
          elevation: 2,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              await _guardarBorradorLocal();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Inspección y Revisión ($folio)',
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS · $fechaHoyFmt',
                    style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _pesaRed,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white38, width: 0.8),
              ),
              child: const Text(
                'OSOB DIGITAL',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await _guardarBorradorSilencioso();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Borrador OSOB guardado localmente'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.save_outlined, color: Colors.white, size: 18),
            label: const Text('Borrador', style: TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildControlHeaderCard(folio, fechaHoyFmt),
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
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _pesaRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 3,
                ),
                onPressed: _guardando ? null : _finalizar,
                icon: _guardando
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Icon(Icons.verified_rounded, size: 22),
                label: Text(
                  _guardando
                      ? 'GENERANDO PDF Y SINCRONIZANDO...'
                      : 'FINALIZAR Y GENERAR FORMATO ($folio)',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.4),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildSectionTitleBanner(String title, {Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: _pesaDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildControlHeaderCard(String folio, String fechaHoyFmt) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    'FOLIO: $folio',
                    style: const TextStyle(
                      color: _pesaRed,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFCE8E9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _pesaRed, width: 0.8),
                  ),
                  child: const Text(
                    'OSOB DIGITAL',
                    style: TextStyle(
                      color: _pesaRed,
                      fontWeight: FontWeight.bold,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            Wrap(
              spacing: 18,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Fecha: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    Text(fechaHoyFmt, style: const TextStyle(fontSize: 13)),
                  ],
                ),
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _ordenServicioRefCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Orden de Servicio',
                      hintText: 'Ej. OS-26-700',
                      isDense: true,
                      border: OutlineInputBorder(),
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

  // ── SECCIÓN 1: Datos del Cliente y del Equipo ─────────────────────────────
  Widget _buildSeccion1Card() {
    const tipos = ['Mesa', 'Camionera', 'Colgante', 'Tolva', 'Tanque', 'Otro'];
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitleBanner('SECCIÓN 1. Datos del Cliente y del Equipo'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bool isWide = constraints.maxWidth >= 560;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isWide) ...[
                      Row(
                        children: [
                          Expanded(child: _textInput('Cliente / Empresa', _clienteCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _textInput('Planta / Ubicación', _plantaCtrl)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _textInput('ID Interno / Tag', _idTagCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _textInput('Marca', _marcaCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _textInput('Modelo', _modeloCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _textInput('Número de Serie', _serieCtrl)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _textInput('Capacidad Máx. (Max)', _capMaxCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _textInput('División Mínima (d / e)', _divMinCtrl)),
                        ],
                      ),
                    ] else ...[
                      _textInput('Cliente / Empresa', _clienteCtrl),
                      const SizedBox(height: 10),
                      _textInput('Planta / Ubicación', _plantaCtrl),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _textInput('ID Interno / Tag', _idTagCtrl)),
                          const SizedBox(width: 8),
                          Expanded(child: _textInput('Marca', _marcaCtrl)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _textInput('Modelo', _modeloCtrl)),
                          const SizedBox(width: 8),
                          Expanded(child: _textInput('Número de Serie', _serieCtrl)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _textInput('Capacidad Máx. (Max)', _capMaxCtrl)),
                          const SizedBox(width: 8),
                          Expanded(child: _textInput('División Mínima (d / e)', _divMinCtrl)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'Tipo de Instrumento:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: tipos.map((t) {
                        final sel = _tipoInstrumento == t;
                        return ChoiceChip(
                          label: Text(t == 'Otro' ? 'Otro (especifique)' : t),
                          selected: sel,
                          selectedColor: const Color(0xFFFCE8E9),
                          labelStyle: TextStyle(
                            color: sel ? _pesaRed : Colors.black87,
                            fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                          ),
                          onSelected: (_) {
                            setState(() => _tipoInstrumento = t);
                            _programarAutoGuardado();
                          },
                        );
                      }).toList(),
                    ),
                    if (_tipoInstrumento == 'Otro') ...[
                      const SizedBox(height: 8),
                      _textInput('Especifique', _tipoInstOtroCtrl),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── SECCIÓN 2: Checklist de Inspección Física y Mecánica ──────────────────
  Widget _buildSeccion2Card() {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitleBanner(
            'SECCIÓN 2. Checklist de Inspección Física y Mecánica',
            trailing: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () {
                setState(() {
                  for (int i = 1; i <= 14; i++) {
                    _chkEstado[i] = 'B';
                  }
                });
                _programarAutoGuardado();
              },
              icon: const Icon(Icons.done_all, size: 16, color: Colors.greenAccent),
              label: const Text('Marcar todos B', style: TextStyle(fontSize: 11.5)),
            ),
          ),
          Container(
            color: const Color(0xFFF9FAFB),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: const Text(
              'Instrucción: Marcar con una "X" el estado actual de cada componente (B = Bueno / Operativo, R = Regular / Requiere ajuste o limpieza, M = Malo / Requiere reemplazo, N/A = No aplica).',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Color(0xFF4B5563)),
            ),
          ),
          _buildSubcategoryBar('A) Estructura y Receptor de Carga'),
          for (int i = 1; i <= 6; i++) _buildChecklistItemWidget(i),
          _buildSubcategoryBar('B) Celdas y Transmisión'),
          for (int i = 7; i <= 9; i++) _buildChecklistItemWidget(i),
          _buildSubcategoryBar('C) Indicador y Electrónica'),
          for (int i = 10; i <= 14; i++) _buildChecklistItemWidget(i),
        ],
      ),
    );
  }

  Widget _buildSubcategoryBar(String title) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFE5E7EB),
      child: Text(
        title,
        style: const TextStyle(color: _pesaRed, fontWeight: FontWeight.bold, fontSize: 12.5),
      ),
    );
  }

  Widget _buildChecklistItemWidget(int num) {
    final label = _checklistLabels[num] ?? '';
    final cur = _chkEstado[num] ?? 'B';
    const opts = ['B', 'R', 'M', 'N/A'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: num.isEven ? const Color(0xFFF9FAFB) : Colors.white,
        border: const Border(bottom: BorderSide(color: Color(0xFFE5E7EB), width: 0.8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$num. $label',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _pesaDark),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Wrap(
                spacing: 6,
                children: opts.map((op) {
                  final active = cur == op;
                  return InkWell(
                    onTap: () {
                      setState(() => _chkEstado[num] = op);
                      _programarAutoGuardado();
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: active ? _pesaRed : Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: active ? _pesaRed : Colors.grey.shade400),
                      ),
                      child: Text(
                        '[ $op ]',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: active ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _chkObsCtrls[num],
                  decoration: const InputDecoration(
                    labelText: 'Observaciones',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── SECCIÓN 3: Pruebas Rápidas de Funcionamiento ──────────────────────────
  Widget _buildSeccion3Card() {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitleBanner('SECCIÓN 3. Pruebas Rápidas de Funcionamiento'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _buildPruebaRapidaItem(
                  label: 'Estabilidad de Cero al encendido',
                  estado: _estabCeroEstado,
                  onChangedEstado: (v) {
                    setState(() => _estabCeroEstado = v);
                    _programarAutoGuardado();
                  },
                  extraField: _textInput('Comentarios', _estabCeroComCtrl),
                ),
                const Divider(height: 16),
                _buildPruebaRapidaItem(
                  label: 'Retorno a Cero tras descarga',
                  estado: _retornoCeroEstado,
                  onChangedEstado: (v) {
                    setState(() => _retornoCeroEstado = v);
                    _programarAutoGuardado();
                  },
                  extraField: _textInput('Comentarios', _retornoCeroComCtrl),
                ),
                const Divider(height: 16),
                _buildPruebaRapidaItem(
                  label: 'Prueba de Excentricidad (Esquinas)',
                  estado: _excentricidadEstado,
                  onChangedEstado: (v) {
                    setState(() => _excentricidadEstado = v);
                    _programarAutoGuardado();
                  },
                  extraField: _textInput('Dif. máx. detectada', _excentricidadDifCtrl),
                ),
                const Divider(height: 16),
                _buildPruebaRapidaItem(
                  label: 'Repetibilidad de lectura',
                  estado: _repetibilidadEstado,
                  onChangedEstado: (v) {
                    setState(() => _repetibilidadEstado = v);
                    _programarAutoGuardado();
                  },
                  extraField: _textInput('Carga de prueba', _repetibilidadCargaCtrl),
                ),
                const Divider(height: 16),
                _buildPruebaRapidaItem(
                  label: 'Exactitud preliminar de pesaje',
                  estado: _exactitudEstado,
                  onChangedEstado: (v) {
                    setState(() => _exactitudEstado = v);
                    _programarAutoGuardado();
                  },
                  extraField: Row(
                    children: [
                      const Text('Requiere ajuste: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('Sí'),
                        selected: _exactitudReqAjuste == 'Sí',
                        selectedColor: const Color(0xFFFCE8E9),
                        onSelected: (_) {
                          setState(() => _exactitudReqAjuste = 'Sí');
                          _programarAutoGuardado();
                        },
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('No'),
                        selected: _exactitudReqAjuste == 'No',
                        selectedColor: const Color(0xFFFCE8E9),
                        onSelected: (_) {
                          setState(() => _exactitudReqAjuste = 'No');
                          _programarAutoGuardado();
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

  Widget _buildPruebaRapidaItem({
    required String label,
    required String estado,
    required ValueChanged<String> onChangedEstado,
    required Widget extraField,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('• $label:', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: [
            ChoiceChip(
              label: const Text('Cumple'),
              selected: estado == 'Cumple',
              selectedColor: Colors.green.shade100,
              labelStyle: TextStyle(
                color: estado == 'Cumple' ? Colors.green.shade900 : Colors.black87,
                fontWeight: estado == 'Cumple' ? FontWeight.bold : FontWeight.normal,
              ),
              onSelected: (_) => onChangedEstado('Cumple'),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('No cumple'),
              selected: estado == 'No cumple',
              selectedColor: const Color(0xFFFCE8E9),
              labelStyle: TextStyle(
                color: estado == 'No cumple' ? _pesaRed : Colors.black87,
                fontWeight: estado == 'No cumple' ? FontWeight.bold : FontWeight.normal,
              ),
              onSelected: (_) => onChangedEstado('No cumple'),
            ),
            const SizedBox(width: 14),
            Expanded(child: extraField),
          ],
        ),
      ],
    );
  }

  // ── SECCIÓN 4: Diagnóstico General, Observaciones y Refacciones ───────────
  Widget _buildSeccion4Card() {
    const dictamenes = [
      ('OPERATIVO', 'OPERATIVO (Apto para uso normal / Listo para calibración)'),
      ('OPERATIVO CON OBSERVACIONES', 'OPERATIVO CON OBSERVACIONES (Funciona, pero requiere mantenimiento preventivo/correctivo pronto)'),
      ('FUERA DE SERVICIO', 'FUERA DE SERVICIO (No apto para uso hasta reparación)'),
    ];

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitleBanner('SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Observaciones técnicas y hallazgos detallados:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _obsTecnicasCtrl,
                  minLines: 3,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Capture todas las observaciones técnicas y hallazgos detallados (se expande automáticamente sin cortar texto)...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Acciones realizadas durante la revisión:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _pesaRed,
                  title: const Text('Limpieza superficial e interna'),
                  value: _accLimpieza,
                  onChanged: (v) {
                    setState(() => _accLimpieza = v ?? false);
                    _programarAutoGuardado();
                  },
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _pesaRed,
                  title: const Text('Nivelación de patas y ajuste de topes'),
                  value: _accNivelacion,
                  onChanged: (v) {
                    setState(() => _accNivelacion = v ?? false);
                    _programarAutoGuardado();
                  },
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _pesaRed,
                  title: const Text('Ajuste de peso (calibración interna / ajuste con masa patrón)'),
                  value: _accAjustePeso,
                  onChanged: (v) {
                    setState(() => _accAjustePeso = v ?? false);
                    _programarAutoGuardado();
                  },
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _pesaRed,
                  title: const Text('Revisión eléctrica y reapriete de conexiones'),
                  value: _accRevElectrica,
                  onChanged: (v) {
                    setState(() => _accRevElectrica = v ?? false);
                    _programarAutoGuardado();
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  'Refacciones o servicios adicionales requeridos:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _refaccionesCtrl,
                  minLines: 2,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Especifique refacciones o servicios adicionales requeridos...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Dictamen de Estado Operativo del Equipo:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                for (final d in dictamenes)
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: _pesaRed,
                    value: d.$1,
                    groupValue: _dictamenEstado,
                    title: Text(
                      d.$2,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: _dictamenEstado == d.$1 ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _dictamenEstado = v);
                        _programarAutoGuardado();
                      }
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── SECCIÓN 5: Firmas de Conformidad ──────────────────────────────────────
  Widget _buildSeccion5Card() {
    Widget buildTecBox() {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Realizó Revisión (Técnico)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _pesaRed),
            ),
            const SizedBox(height: 8),
            _textInput('Nombre', _tecNombreCtrl),
            const SizedBox(height: 8),
            _textInput('Puesto', _tecPuestoCtrl),
            const SizedBox(height: 8),
            if (_usarFirmaPre && _firmaTecPre != null)
              Container(
                height: 110,
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Column(
                  children: [
                    Expanded(child: Image.memory(_firmaTecPre!, fit: BoxFit.contain)),
                    TextButton.icon(
                      onPressed: () => setState(() => _usarFirmaPre = false),
                      icon: const Icon(Icons.edit, size: 14),
                      label: const Text('Firmar manualmente', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  Container(
                    height: 110,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SignatureGestureShield(
                        child: Signature(
                          controller: _sigTecnicoCtrl,
                          height: 110,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _sigTecnicoCtrl.clear(),
                      icon: const Icon(Icons.refresh, size: 15),
                      label: const Text('Limpiar firma técnico', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
    }

    Widget buildCliBox() {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recibió de Conformidad (Cliente / Usuario)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _pesaRed),
            ),
            const SizedBox(height: 8),
            _textInput('Nombre * (Obligatorio)', _cliNombreCtrl),
            if (_contactosSugeridos.isNotEmpty) ...[
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _contactosSugeridos.map((c) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(c, style: const TextStyle(fontSize: 11)),
                        onPressed: () => setState(() => _cliNombreCtrl.text = c),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 8),
            _textInput('Área / Puesto', _cliPuestoCtrl),
            const SizedBox(height: 8),
            Container(
              height: 110,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade400),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SignatureGestureShield(
                  child: Signature(
                    controller: _sigClienteCtrl,
                    height: 110,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _sigClienteCtrl.clear(),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Limpiar firma cliente', style: TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitleBanner('SECCIÓN 5. Firmas de Conformidad'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 560) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: buildTecBox()),
                      const SizedBox(width: 12),
                      Expanded(child: buildCliBox()),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buildTecBox(),
                    const SizedBox(height: 12),
                    buildCliBox(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _textInput(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: const OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 12.5),
    );
  }
}
