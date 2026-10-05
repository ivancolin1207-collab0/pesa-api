// lib/services/pdf_service.dart — PDF Toma de Datos PESA
// v3 — Homologación exacta con plantilla física oficial (imagen de referencia).
// Formato: Letter, UNA SOLA PÁGINA.
// Columna izquierda: Repetibilidad + Excentricidad
// Columna derecha:   Exactitud + Diagrama 3-paneles
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'metrology_helper.dart';
import 'tipo_servicio_rules.dart' as tsr;

class PdfService {
  static final PdfService instance = PdfService._();
  PdfService._();

  // ── Paleta institucional PESA ─────────────────────────────────────────────
  // Rojo PESA para sub-headers de tablas (idéntico a la plantilla física)
  static const _red      = PdfColor.fromInt(0xFFB22222); // Rojo institucional
  static const _redBright= PdfColor.fromInt(0xFFC8102E); // Rojo más vivo (folio/labels)
  static const _redBg    = PdfColor.fromInt(0xFFFFEEEE);
  static const _dark     = PdfColor.fromInt(0xFF1C1C1C); // Encabezados sección (negro)
  static const _gray     = PdfColor.fromInt(0xFF777777);
  static const _grayD    = PdfColor.fromInt(0xFF555555);
  static const _grayL    = PdfColor.fromInt(0xFFCCCCCC);
  static const _grayBg   = PdfColor.fromInt(0xFFF2F2F2);
  static const _white    = PdfColors.white;
  static const _black    = PdfColors.black;

  // ── API pública ───────────────────────────────────────────────────────────
  Future<String> generarPdfFinal({
    required Map<String, dynamic> osData,
    required List<Map<String, dynamic>> repRows,
    required List<Map<String, dynamic>> excRows,
    required List<Map<String, dynamic>> exacRows,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final bytes = await buildPdfBytes(
      osData: osData, repRows: repRows, excRows: excRows, exacRows: exacRows,
      firmaTecBase64: firmaTecBase64, firmaCliBase64: firmaCliBase64,
    );
    return _saveToDisk(osData, bytes);
  }

  /// Construye el PDF en memoria (sin guardarlo). Útil para pruebas locales.
  Future<Uint8List> buildPdfBytes({
    required Map<String, dynamic> osData,
    required List<Map<String, dynamic>> repRows,
    required List<Map<String, dynamic>> excRows,
    required List<Map<String, dynamic>> exacRows,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final doc = pw.Document(
      title:   'Toma de Datos - ${osData['folio_os'] ?? ''}',
      author:  'Servicios PESA',
      subject: 'Orden de Servicio Metrológica',
      creator: 'PESA Tablet App v3',
    );

    // Cargar logos
    pw.ImageProvider? logoPesa;
    pw.ImageProvider? logoRl;
    for (final p in ['Img/logo_pesa.png', 'assets/logo_pesa.png']) {
      try { final b = await rootBundle.load(p); logoPesa = pw.MemoryImage(b.buffer.asUint8List()); break; }
      catch (_) {}
    }
    for (final p in ['Img/RiceLake.png', 'assets/RiceLake.png']) {
      try { final b = await rootBundle.load(p); logoRl = pw.MemoryImage(b.buffer.asUint8List()); break; }
      catch (_) {}
    }

    // Firmas
    pw.ImageProvider? firmaTecImg;
    pw.ImageProvider? firmaCliImg;
    if (firmaTecBase64 != null && firmaTecBase64.isNotEmpty) {
      try {
        final raw = firmaTecBase64.contains(',') ? firmaTecBase64.split(',').last : firmaTecBase64;
        firmaTecImg = pw.MemoryImage(base64Decode(raw));
      } catch (_) {}
    }
    if (firmaCliBase64 != null && firmaCliBase64.isNotEmpty) {
      try {
        final raw = firmaCliBase64.contains(',') ? firmaCliBase64.split(',').last : firmaCliBase64;
        firmaCliImg = pw.MemoryImage(base64Decode(raw));
      } catch (_) {}
    }

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(26, 12, 26, 12),
      build: (ctx) => _buildPage(
        osData: osData, repRows: repRows, excRows: excRows, exacRows: exacRows,
        logoPesa: logoPesa, logoRl: logoRl,
        firmaTec: firmaTecImg, firmaCli: firmaCliImg,
      ),
    ));

    final bytes = await doc.save();
    return bytes;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LAYOUT PRINCIPAL
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildPage({
    required Map<String, dynamic> osData,
    required List<Map<String, dynamic>> repRows,
    required List<Map<String, dynamic>> excRows,
    required List<Map<String, dynamic>> exacRows,
    pw.ImageProvider? logoPesa,
    pw.ImageProvider? logoRl,
    pw.ImageProvider? firmaTec,
    pw.ImageProvider? firmaCli,
  }) {
    final aplExc   = _parseBool(osData['aplica_excentricidad']);
    final motivoNo = _s(osData, 'motivo_no_aplica', '');
    final leyenda  = _s(osData, 'leyenda_excentricidad',
        'El tipo de instrumento no es apto para realizar prueba de excentricidad.');
    final divMin   = _parseDivMin(osData);
    final rawGeo   = (_s(osData, 'geometria_excentricidad', '').isNotEmpty)
        ? _s(osData, 'geometria_excentricidad', '')
        : _s(osData, 'geometria_plataforma', '');
    final geo      = (rawGeo.isNotEmpty)
        ? rawGeo.toLowerCase().trim()
        : getGeometriaPorDefecto(_s(osData, 'tipo_instrumento', '')).toLowerCase();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        // 1. Logos izq/der
        _buildLogosRow(logoPesa, logoRl),
        pw.SizedBox(height: 2),
        // 2. Título grande centrado + folio
        _buildTituloFolio(osData),
        pw.SizedBox(height: 4),
        // 3. FECHA
        _buildFecha(osData),
        pw.SizedBox(height: 2),
        // 4. Cliente + Dirección
        _buildClienteDir(osData),
        pw.SizedBox(height: 3),
        // 5. Grid de instrumento
        _buildEquipo(osData),
        pw.SizedBox(height: 3),
        // 6. "PRUEBAS METROLÓGICAS"
        _sectionTitle('PRUEBAS METROLÓGICAS'),
        pw.SizedBox(height: 3),
        // 7. Tablas 2-columnas
        _buildPruebas2Col(
          osData: osData, repRows: repRows, excRows: excRows, exacRows: exacRows,
          aplExc: aplExc, motivoNo: motivoNo, leyenda: leyenda,
          divMin: divMin, geo: geo,
        ),
        pw.SizedBox(height: 4),
        // 8. Observaciones
        _buildObservaciones(osData),
        pw.SizedBox(height: 5),
        // 9. Firmas
        _buildFirmas(osData, firmaTec, firmaCli),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 1. LOGOS — izquierda y derecha
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildLogosRow(pw.ImageProvider? logoPesa, pw.ImageProvider? logoRl) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        _logoBox(logoPesa, 'BP BÁSCULAS PESA', 120, 38),
        _logoBox(logoRl, 'RICE LAKE', 100, 38),
      ],
    );
  }

  pw.Widget _logoBox(pw.ImageProvider? img, String placeholder, double w, double h) {
    if (img != null) {
      return pw.SizedBox(width: w, height: h,
          child: pw.Image(img, fit: pw.BoxFit.contain));
    }
    return pw.Container(width: w, height: h,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _grayL, width: 0.5)),
      child: pw.Center(child: pw.Text('[ $placeholder ]',
          style: pw.TextStyle(fontSize: 6, color: _gray))));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 2. TÍTULO "TOMA DE DATOS" + FOLIO
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildTituloFolio(Map<String, dynamic> os) {
    final folio = _s(os, 'folio_os', '');
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        // Área superior limpia entre el logo y el recuadro rojo
        pw.Expanded(
          child: pw.SizedBox(),
        ),
        pw.SizedBox(width: 8),
        // Recuadro folio — rojo
        pw.Container(
          width: 115, height: 46,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _redBright, width: 1.5)),
          child: pw.Column(children: [
            pw.Container(
              width: double.infinity, height: 16, color: _redBright,
              child: pw.Center(child: pw.Text('FOLIO / OS',
                  style: pw.TextStyle(color: _white, fontSize: 7,
                      fontWeight: pw.FontWeight.bold))),
            ),
            pw.Expanded(child: pw.Center(
              child: pw.Text(folio,
                  style: pw.TextStyle(color: _redBright,
                      fontSize: folio.length <= 10 ? 13 : 9,
                      fontWeight: pw.FontWeight.bold)),
            )),
          ]),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 3. FECHA
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildFecha(Map<String, dynamic> os) {
    String fecha = _s(os, 'fecha', _s(os, 'fecha_servicio', ''));
    if (fecha.isEmpty || fecha == 'null') {
      fecha = DateTime.now().toIso8601String().substring(0, 10);
    } else if (fecha.length > 10) {
      fecha = fecha.substring(0, 10);
    }
    return pw.Row(children: [
      pw.Text('FECHA: ', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _redBright)),
      pw.Text(fecha, style: const pw.TextStyle(fontSize: 8)),
    ]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 4. CLIENTE + DIRECCIÓN
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildClienteDir(Map<String, dynamic> os) {
    final cliente   = _s(os, 'cliente', _s(os, 'cliente_nombre', _s(os, 'razon_social', '')));
    final direccion = _s(os, 'direccion', _s(os, 'direccion_cliente', _s(os, 'sucursal', _s(os, 'planta', _s(os, 'sucursal_direccion', '')))));
    return pw.Column(children: [
      _labelValueRow('CLIENTE:', cliente),
      pw.SizedBox(height: 1),
      _labelValueRow('DIRECCIÓN:', direccion),
    ]);
  }

  pw.Widget _labelValueRow(String label, String value) => pw.Row(children: [
    pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold,
        color: _redBright)),
    pw.SizedBox(width: 4),
    pw.Expanded(child: pw.Text(value.isNotEmpty ? value : '-', style: const pw.TextStyle(fontSize: 8))),
  ]);

  // ══════════════════════════════════════════════════════════════════════════
  // 5. GRID INSTRUMENTO
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildEquipo(Map<String, dynamic> os) {
    final marca  = _s(os, 'marca', _s(os, 'equipo_marca', ''));
    final modelo = _s(os, 'modelo', _s(os, 'equipo_modelo', ''));
    final ns     = _s(os, 'ns', _s(os, 'serie', _s(os, 'equipo_ns', '')));
    final idEq   = _s(os, 'id_equipo', _s(os, 'id_indicador', ''));
    final tipo   = _s(os, 'tipo_instrumento', _s(os, 'tipo_receptor', ''));
    final func   = _s(os, 'funcionamiento', 'Electrónico');
    final ubic   = _s(os, 'ubicacion', '');
    final cap    = _s(os, 'alcance_max', _s(os, 'capacidad_max', _s(os, 'cap_max', _s(os, 'capacidad_maxima', ''))));
    final div    = _s(os, 'div_minima', _s(os, 'division_minima', _s(os, 'div_min', '')));
    final unidad = _s(os, 'unidad_medida', 'kg');
    final apoyo  = _s(os, 'puntos_apoyo', '4');
    final cca      = _s(os, 'numero_cca', _s(os, 'cca', _s(os, 'numeroCca', '')));
    final folioDve = _s(os, 'folio_dve', _s(os, 'numero_dve', _s(os, 'div_verificacion', _s(os, 'div_ver', _s(os, 'folioDve', _s(os, 'numeroDve', ''))))));
    final holoAnt  = _s(os, 'holograma_anterior', _s(os, 'hologramaAnterior', ''));
    final holoNue  = _s(os, 'holograma_actualizado', _s(os, 'holograma_nuevo', _s(os, 'hologramaNuevo', '')));

    // Reglas por tipo de servicio real (nombre → ID). Si la OS llegó sin tipo,
    // solo se imprime lo que efectivamente fue capturado. Nunca se imprime "N/A".
    final rules = tsr.getRules(
      id: int.tryParse('${os['id_tipo_servicio'] ?? ''}'),
      nombre: (os['tipo_servicio'] ?? os['tipo_servicio_nombre'])?.toString(),
      folio: os['folio']?.toString(),
    );
    final bool mostrarCca = rules.pideCca || (rules.sinTipo && cca.isNotEmpty);
    final bool mostrarDve = rules.pideDve ||
        (rules.sinTipo && (folioDve.isNotEmpty || holoAnt.isNotEmpty || holoNue.isNotEmpty));

    final j = os['jia_j'] == true || os['inicial_calibrador'] == 'J';
    final i = os['jia_i'] == true || os['inicial_calibrador'] == 'I';
    final a = os['jia_a'] == true || os['inicial_calibrador'] == 'A';

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _equipoRow([_FD('MARCA', marca, 0.28), _FD('MODELO', modelo, 0.36), _FD('SERIE / N/S', ns, 0.36)]),
      _equipoRow([_FD('ID INDICADOR / EQUIPO', idEq, 0.30), _FD('TIPO DE INSTRUMENTO', tipo, 0.36), _FD('FUNCIONAMIENTO', func, 0.34)]),
      _equipoRow([
        _FD('CAPACIDAD MÁXIMA', cap.isNotEmpty ? '$cap $unidad' : '', 0.28),
        _FD('DIVISIÓN MÍNIMA', div.isNotEmpty ? '$div $unidad' : '', 0.24),
        _FD('PUNTOS DE APOYO', apoyo, 0.18),
        _FD('UBICACIÓN', ubic, 0.30),
      ]),
      // Renglón CCA + casillas J I A — solo si el servicio incluye Calibración
      if (mostrarCca)
        _equipoJiaRow(cca: cca, j: j, i: i, a: a),
      // Renglón DVE + hologramas — solo si el servicio incluye Inspección / DVE
      if (mostrarDve)
        _equipoRow([
          _FD('FOLIO DVE', folioDve, 0.34),
          _FD('HOLO. ANTERIOR', holoAnt, 0.33),
          _FD('HOLO. NUEVO', holoNue, 0.33),
        ]),
    ]);
  }

  pw.Widget _equipoJiaRow({
    required String cca,
    required bool j,
    required bool i,
    required bool a,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _grayL, width: 0.3))),
      child: pw.Row(
        children: [
          pw.Expanded(
            flex: 40,
            child: pw.Row(children: [
              pw.Text('NÚMERO CCA: ', style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold)),
              pw.Expanded(child: pw.Text(cca, style: const pw.TextStyle(fontSize: 7.5))),
            ]),
          ),
          pw.Expanded(
            flex: 60,
            child: pw.Row(
              children: [
                _jiaBox('J', j),
                pw.SizedBox(width: 8),
                _jiaBox('I', i),
                pw.SizedBox(width: 8),
                _jiaBox('A', a),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 5.1 FILA JIA (Solo para Calibración o Inspección — Oculto en Ajuste puro)
  //     La visibilidad se decide en _buildEquipo con tipo_servicio_rules.
  // ══════════════════════════════════════════════════════════════════════════

  pw.Widget _jiaBox(String code, bool marked) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(
          width: 8, height: 8,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: marked ? _redBright : _gray, width: 0.8),
            color: marked ? _redBright : _white,
          ),
          child: marked
              ? pw.Center(child: pw.Text('X', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))
              : null,
        ),
        pw.SizedBox(width: 4),
        pw.Text(code, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: marked ? _redBright : _black)),
      ],
    );
  }

  pw.Widget _equipoRow(List<_FD> fields) => pw.Row(
    children: fields.map((f) => pw.Expanded(
      flex: (f.w * 100).round(),
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _grayL, width: 0.3))),
        child: pw.Row(children: [
          pw.Text('${f.lbl}: ', style: pw.TextStyle(fontSize: 6.5,
              fontWeight: pw.FontWeight.bold)),
          pw.Expanded(child: pw.Text(f.val, style: const pw.TextStyle(fontSize: 7))),
        ]),
      ),
    )).toList(),
  );

  // ══════════════════════════════════════════════════════════════════════════
  // 6. SECCIÓN TÍTULO
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _sectionTitle(String text) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold,
          color: _redBright)),
      pw.Container(height: 0.8, color: _redBright),
    ],
  );

  // ══════════════════════════════════════════════════════════════════════════
  // 7. PRUEBAS 2-COLUMNAS
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildPruebas2Col({
    required Map<String, dynamic> osData,
    required List<Map<String, dynamic>> repRows,
    required List<Map<String, dynamic>> excRows,
    required List<Map<String, dynamic>> exacRows,
    required bool aplExc,
    required String motivoNo,
    required String leyenda,
    required int divMin,
    required String geo,
  }) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Col izquierda (52%): Repetibilidad + Excentricidad
        pw.Expanded(
          flex: 52,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _buildRepetibilidadTable(repRows, osData, divMin),
              pw.SizedBox(height: 5),
              aplExc
                  ? _buildExcentricidadTable(excRows, osData, divMin)
                  : _buildNoAplicaBox(motivoNo, leyenda),
            ],
          ),
        ),
        pw.SizedBox(width: 6),
        // Col derecha (48%): Exactitud + Diagrama 3-paneles
        pw.Expanded(
          flex: 48,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _buildExactitudTable(exacRows, osData, divMin),
              pw.SizedBox(height: 5),
              _buildDiagrama3Paneles(osData, geo),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // REPETIBILIDAD — 5 columnas: N | CARGA | L. INICIAL | L. FINAL | ERROR
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildRepetibilidadTable(
      List<Map<String, dynamic>> rows, Map<String, dynamic> os, int dec) {
    final display = List<Map<String, dynamic>>.from(rows);
    while (display.length < 3) display.add({});
    final u = (os['unidad_medida'] ?? 'kg').toString().trim().isNotEmpty
        ? (os['unidad_medida'] ?? 'kg').toString().trim() : 'kg';

    final double? cargaGlobal = _toNum(os['valor_repetibilidad'] ?? os['carga_repetibilidad']);

    // Calcular error máximo: Error = L. Final - Carga
    double maxErr = 0;
    for (final r in display) {
      final carga = _toNum(r['valor'] ?? r['valor_kg'] ?? r['carga']) ?? cargaGlobal;
      final fin   = _toNum(r['lectura_final']);
      if (fin != null && carga != null) {
        final err = fin - carga;
        if (err.abs() > maxErr) maxErr = err.abs();
      }
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        // Header oscuro
        _tblHeader('REPETIBILIDAD'),
        // Sub-header ROJO con 5 columnas
        pw.Row(children: [
          _redHdrCell('N',                0.08),
          _redHdrCell('CARGA ($u)',       0.22),
          _redHdrCell('L. INICIAL ($u)',  0.24),
          _redHdrCell('L. FINAL ($u)',    0.24),
          _redHdrCell('ERROR ($u)',       0.22),
        ]),
        // Filas de datos
        ...display.asMap().entries.map((e) {
          final r     = e.value;
          final carga = _toNum(r['valor'] ?? r['valor_kg'] ?? r['carga']) ?? cargaGlobal;
          final ini   = _toNum(r['lectura_inicial']);
          final fin   = _toNum(r['lectura_final']);
          double? err;
          if (fin != null && carga != null) {
            err = fin - carga;
          }
          return _dataRow([
            carga != null ? '${e.key + 1}' : '',
            carga != null ? _fmtDec(carga, dec) : '',
            ini != null ? _fmtDec(ini, dec) : (fin != null || carga != null ? '/' : ''),
            fin != null ? _fmtDec(fin, dec) : '',
            err != null ? _fmtDec(err, dec) : '',
          ], [0.08, 0.22, 0.24, 0.24, 0.22], e.key % 2 == 1);
        }),
        // Footer Error Máximo
        _errMaxRow('ERROR MÁXIMO ENCONTRADO:', _fmtDec(maxErr, dec)),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ══════════════════════════════════════════════════════════════════════════
  // EXACTITUD — 5 columnas: N | NOMINAL | L. INICIAL | L. FINAL | ERROR
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildExactitudTable(
      List<Map<String, dynamic>> rows, Map<String, dynamic> os, int dec) {
    // Filtrar únicamente los puntos capturados (recorte dinámico)
    final validRows = rows.where((r) {
      final nom = _toNum(r['valor_nominal'] ?? r['carga_patron'] ?? r['carga']);
      final fin = _toNum(r['lectura_final'] ?? r['lectura_subida'] ?? r['lectura']);
      final ini = _toNum(r['lectura_inicial']);
      return nom != null || fin != null || ini != null;
    }).toList();

    // Si se capturaron puntos (ej. 5), recortar dinámicamente. Si está vacía, mostrar 5 filas base.
    final display = validRows.isNotEmpty
        ? validRows
        : List.generate(5, (_) => <String, dynamic>{});
    final u = (os['unidad_medida'] ?? 'kg').toString().trim().isNotEmpty
        ? (os['unidad_medida'] ?? 'kg').toString().trim() : 'kg';

    // Encabezado con clase — limpio con guión ASCII
    final claseRaw = _s(os, 'clase_exactitud', '');
    final claseClean = claseRaw.isNotEmpty
        ? claseRaw.replaceAll(RegExp(r'\s*\(.*?\)'), '').trim()
        : 'Clase III';
    final titulo = 'EXACTITUD - $claseClean';

    double maxErr = 0;
    for (final r in display) {
      final nom = _toNum(r['valor_nominal'] ?? r['carga_patron'] ?? r['carga']);
      final fin = _toNum(r['lectura_final'] ?? r['lectura_subida'] ?? r['lectura']);
      double? err;
      if (fin != null && nom != null) {
        err = fin - nom;
      } else if (r['error'] != null) {
        err = _toNum(r['error']);
      }
      if (err != null && err.abs() > maxErr) maxErr = err.abs();
    }

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _tblHeader(titulo),
      pw.Row(children: [
        _redHdrCell('N',                0.08),
        _redHdrCell('NOMINAL ($u)',     0.22),
        _redHdrCell('L. INICIAL ($u)',  0.245),
        _redHdrCell('L. FINAL ($u)',    0.245),
        _redHdrCell('ERROR ($u)',       0.21),
      ]),
      ...display.asMap().entries.map((e) {
        final r   = e.value;
        final nom = _toNum(r['valor_nominal'] ?? r['carga_patron'] ?? r['carga']);
        final fin = _toNum(r['lectura_final'] ?? r['lectura_subida'] ?? r['lectura']);
        final ini = _toNum(r['lectura_inicial']);
        double? err;
        if (fin != null && nom != null) {
          err = fin - nom;
        } else if (r['error'] != null) {
          err = _toNum(r['error']);
        }
        return _dataRow([
          nom != null || fin != null ? '${e.key + 1}' : '',
          nom != null ? _fmtDec(nom, dec) : '',
          ini != null ? _fmtDec(ini, dec) : (fin != null || nom != null ? '/' : ''),
          fin != null ? _fmtDec(fin, dec) : '',
          err != null ? _fmtDec(err, dec) : '',
        ], [0.08, 0.22, 0.245, 0.245, 0.21], e.key % 2 == 1);
      }),
      _errMaxRow('ERROR MÁXIMO ENCONTRADO:', _fmtDec(maxErr, dec)),
    ]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EXCENTRICIDAD — 4 columnas: POSICION | L. INICIAL | L. FINAL | ERROR
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildExcentricidadTable(
      List<Map<String, dynamic>> rows, Map<String, dynamic> os, int dec) {
    final rawGeo = (_s(os, 'geometria_excentricidad', '').isNotEmpty)
        ? _s(os, 'geometria_excentricidad', '')
        : _s(os, 'geometria_plataforma', '');
    final tipo = _s(os, 'tipo_instrumento', '').toLowerCase();
    final effectiveGeo = rawGeo.isNotEmpty
        ? rawGeo.toLowerCase().trim()
        : getGeometriaPorDefecto(tipo).toLowerCase();

    final bool isCam = effectiveGeo.contains('camion') ||
        effectiveGeo.contains('ferro') ||
        tipo.contains('camion') ||
        tipo.contains('puente') ||
        tipo.contains('ferro');
    final bool isCirc = !isCam && (effectiveGeo.contains('circ') || tipo.contains('circ'));

    int nSec = int.tryParse(os['num_secciones']?.toString() ?? '') ??
               int.tryParse(os['secciones_camionera']?.toString() ?? '') ??
               int.tryParse(os['filas_excentricidad']?.toString() ?? '') ??
               (rows.length >= 2 ? rows.length : 4);
    if (nSec <= 0) nSec = 4;

    List<String> labels;
    if (isCam) {
      labels = List.generate(nSec, (i) => 'Sección ${i + 1}');
    } else if (isCirc) {
      labels = const ['Centro', 'Norte', 'Este', 'Sur', 'Oeste'];
    } else {
      labels = const ['Centro', 'Esquina 1', 'Esquina 2', 'Esquina 3', 'Esquina 4'];
    }

    final display = List<Map<String, dynamic>>.from(rows);
    while (display.length < labels.length) display.add({});
    final u = (os['unidad_medida'] ?? 'kg').toString().trim().isNotEmpty
        ? (os['unidad_medida'] ?? 'kg').toString().trim() : 'kg';

    final double? cargaGlobal = _toNum(
      os['valor_excentricidad'] ??
      os['carga_prueba_excentricidad'] ??
      os['carga_excentricidad']
    );

    double maxErr = 0;
    for (final r in display) {
      final carga = _toNum(r['carga'] ?? r['carga_kg']) ?? cargaGlobal;
      final ini   = _toNum(r['lectura_inicial']);
      final fin   = _toNum(r['lectura_final']);
      double? err = calcularErrorExcentricidad(
        fin: fin,
        ini: ini,
        carga: carga,
        isCamionera: isCam,
      );
      if (err == null && isCam && fin != null && carga != null) {
        err = fin - carga;
      } else if (err == null && !isCam && r['error'] != null) {
        err = _toNum(r['error']);
      }
      if (err != null && err.abs() > maxErr) maxErr = err.abs();
    }

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _tblHeader('EXCENTRICIDAD'),
      pw.Row(children: [
        _redHdrCell('POSICION',           0.28),
        _redHdrCell('L. INICIAL ($u)',    0.24),
        _redHdrCell('L. FINAL ($u)',      0.24),
        _redHdrCell('ERROR ($u)',         0.24),
      ]),
      ...display.asMap().entries.map((e) {
        final r     = e.value;
        final ini   = _toNum(r['lectura_inicial']);
        final fin   = _toNum(r['lectura_final']);
        final carga = _toNum(r['carga'] ?? r['carga_kg']) ?? cargaGlobal;
        final lbl   = e.key < labels.length ? labels[e.key] : 'Pos ${e.key + 1}';

        double? err = calcularErrorExcentricidad(
          fin: fin,
          ini: ini,
          carga: carga,
          isCamionera: isCam,
        );
        if (err == null && isCam && fin != null && carga != null) {
          err = fin - carga;
        } else if (err == null && !isCam && r['error'] != null) {
          err = _toNum(r['error']);
        }

        return _dataRow([
          lbl,
          ini != null ? _fmtDec(ini, dec) : (fin != null || carga != null ? '/' : ''),
          fin != null ? _fmtDec(fin, dec) : '',
          err != null ? _fmtDec(err, dec) : '',
        ], [0.28, 0.24, 0.24, 0.24], e.key % 2 == 1);
      }),
      _errMaxRow('ERROR MÁXIMO ENCONTRADO:', _fmtDec(maxErr, dec)),
    ]);
  }


  // ══════════════════════════════════════════════════════════════════════════
  // NO APLICA EXCENTRICIDAD
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildNoAplicaBox(String motivoNo, String leyenda) {
    final tipo = motivoNo.isNotEmpty ? motivoNo : 'instrumento especial';
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _tblHeader('EXCENTRICIDAD'),
      pw.Container(
        height: 65,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _red, width: 0.7),
          color: _redBg,
        ),
        child: pw.Center(child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text('NO APLICA PRUEBA DE EXCENTRICIDAD',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold,
                    color: _redBright)),
            pw.SizedBox(height: 3),
            pw.Text('Instrumento tipo: $tipo',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 6.5, color: _black)),
            pw.SizedBox(height: 2),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6),
              child: pw.Text(leyenda, textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: 5.5, fontStyle: pw.FontStyle.italic,
                      color: _gray)),
            ),
          ],
        )),
      ),
    ]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DIAGRAMA 3-PANELES (Plataforma / Circular / Camionera) — fiel a imagen
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildDiagrama3Paneles(Map<String, dynamic> os, String geo) {
    final tipo = _s(os, 'tipo_instrumento', '').toLowerCase();
    final rawGeo = (_s(os, 'geometria_excentricidad', '').isNotEmpty)
        ? _s(os, 'geometria_excentricidad', '')
        : (_s(os, 'geometria_plataforma', '').isNotEmpty
            ? _s(os, 'geometria_plataforma', '')
            : geo);
    final g = rawGeo.toLowerCase().trim();

    // Regla de detección estricta y mutuamente excluyente
    final bool isCam = g.contains('camion') ||
        g.contains('ferro') ||
        tipo.contains('camion') ||
        tipo.contains('puente') ||
        tipo.contains('ferro');
    final bool isCirc = !isCam && (g.contains('circ') || tipo.contains('circ'));
    final bool isPlat = !isCam && !isCirc;

    int nSec = int.tryParse(os['num_secciones']?.toString() ?? '') ??
               int.tryParse(os['secciones_camionera']?.toString() ?? '') ??
               int.tryParse(os['filas_excentricidad']?.toString() ?? '') ??
               (os['exc_rows'] is List && (os['exc_rows'] as List).isNotEmpty ? (os['exc_rows'] as List).length : 4);
    if (nSec <= 0) nSec = 4;

    // Posiciones de puntos como fracciones de ancho/alto (para Stack overlay)
    // Panel Plataforma: 1 Centro, 2 Sup-Izq, 3 Sup-Der, 4 Inf-Der, 5 Inf-Izq
    // Panel Circular:   1 Centro, 2 Norte, 3 Este, 4 Sur, 5 Oeste
    // Panel Camionera:  secciones longitudinales numeradas

    pw.Widget panelPlataforma() => pw.Stack(
      children: [
        pw.Positioned.fill(child: pw.CustomPaint(painter: _dibujarPlataforma)),
        // REGLA METROLÓGICA (5 PUNTOS EXACTOS):
        pw.Positioned.fill(child: pw.Center(child: _dotLabel('1', active: isPlat))),
        pw.Positioned(left: 1,  top: 1,     child: _dotLabel('2', active: isPlat)),
        pw.Positioned(right: 1, top: 1,     child: _dotLabel('3', active: isPlat)),
        pw.Positioned(right: 1, bottom: 1,  child: _dotLabel('4', active: isPlat)),
        pw.Positioned(left: 1,  bottom: 1,  child: _dotLabel('5', active: isPlat)),
      ],
    );

    pw.Widget panelCircular() => pw.Stack(
      children: [
        pw.Positioned.fill(child: pw.CustomPaint(painter: _dibujarCircular)),
        // REGLA METROLÓGICA (5 PUNTOS EXACTOS):
        pw.Positioned.fill(child: pw.Center(child: _dotLabel('1', active: isCirc))),
        pw.Positioned(top: 1,    left: 0, right: 0, child: pw.Center(child: _dotLabel('2', active: isCirc))),
        pw.Positioned(right: 1,  top: 0, bottom: 0, child: pw.Center(child: _dotLabel('3', active: isCirc))),
        pw.Positioned(bottom: 1, left: 0, right: 0, child: pw.Center(child: _dotLabel('4', active: isCirc))),
        pw.Positioned(left: 1,   top: 0, bottom: 0, child: pw.Center(child: _dotLabel('5', active: isCirc))),
      ],
    );

    // Panel Camionera — Secciones longitudinales numeradas
    pw.Widget panelCamionera() {
      final int count = (nSec >= 2 && nSec <= 6) ? nSec : 4;
      const topLetters = ['a', 'c', 'e', 'g', 'i', 'k'];
      const botLetters = ['b', 'd', 'f', 'h', 'j', 'l'];

      return pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          // Letras superiores
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
            children: List.generate(count, (i) => pw.Text(
              i < topLetters.length ? topLetters[i] : '',
              style: pw.TextStyle(
                fontSize: 4.5,
                fontWeight: pw.FontWeight.bold,
                color: isCam ? _black : _grayD,
              ),
            )),
          ),
          pw.SizedBox(height: 1),
          // Celdas con números de sección
          pw.Container(
            height: 22,
            margin: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.Row(
              children: List.generate(count, (i) {
                final String label = (count == nSec)
                    ? '${i + 1}'
                    : (i == count - 1 ? 'N' : '${i + 1}');
                return pw.Expanded(
                  child: pw.Container(
                    margin: const pw.EdgeInsets.symmetric(horizontal: 0.5),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(
                        color: isCam ? const PdfColor.fromInt(0xFFB22222) : const PdfColor.fromInt(0xFFAAAAAA),
                        width: isCam ? 0.7 : 0.4,
                      ),
                      color: isCam ? const PdfColor.fromInt(0xFFFFF0F2) : const PdfColor.fromInt(0xFFF8F8F8),
                    ),
                    child: pw.Center(
                      child: pw.Text(
                        label,
                        style: pw.TextStyle(
                          fontSize: 6,
                          fontWeight: pw.FontWeight.bold,
                          color: isCam ? const PdfColor.fromInt(0xFFB22222) : const PdfColor.fromInt(0xFF666666),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          pw.SizedBox(height: 1),
          // Letras inferiores
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
            children: List.generate(count, (i) => pw.Text(
              i < botLetters.length ? botLetters[i] : '',
              style: pw.TextStyle(
                fontSize: 4.5,
                fontWeight: pw.FontWeight.bold,
                color: isCam ? _black : _grayD,
              ),
            )),
          ),
        ],
      );
    }

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _tblHeader('POSICIONES DE EXCENTRICIDAD'),
      pw.Container(
        height: 82,
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _grayL, width: 0.4)),
        child: pw.Row(children: [
          // Panel 1: Plataforma
          pw.Expanded(child: pw.Column(children: [
            pw.Expanded(child: panelPlataforma()),
            _checkboxRow('Plataforma', isPlat),
          ])),
          pw.Container(width: 0.4, color: _grayL),
          // Panel 2: Circular
          pw.Expanded(child: pw.Column(children: [
            pw.Expanded(child: panelCircular()),
            _checkboxRow('Circular', isCirc),
          ])),
          pw.Container(width: 0.4, color: _grayL),
          // Panel 3: Camionera (secciones)
          pw.Expanded(child: pw.Column(children: [
            pw.Expanded(child: panelCamionera()),
            _checkboxRow('Camionera ($nSec Sec.)', isCam),
          ])),
        ]),
      ),
    ]);
  }

  /// Punto numerado para overlay en diagrama
  pw.Widget _dotLabel(String n, {bool active = true}) => pw.Container(
    width: 10, height: 10,
    decoration: pw.BoxDecoration(
      shape: pw.BoxShape.circle,
      color: active ? const PdfColor.fromInt(0xFFB22222) : const PdfColor.fromInt(0xFFAAAAAA),
    ),
    child: pw.Center(child: pw.Text(n,
        style: pw.TextStyle(fontSize: 5, fontWeight: pw.FontWeight.bold,
            color: PdfColors.white))),
  );

  pw.Widget _checkboxRow(String label, bool checked) => pw.Container(
    height: 14,
    child: pw.Center(
      child: pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Container(
            width: 8, height: 8,
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _black, width: 0.6),
              color: _white,
            ),
            child: checked
                ? pw.Center(child: pw.Text('X', style: pw.TextStyle(
                    fontSize: 5.5, fontWeight: pw.FontWeight.bold, color: _redBright)))
                : null,
          ),
          pw.SizedBox(width: 2),
          pw.Text(label, style: const pw.TextStyle(fontSize: 5.5)),
        ],
      ),
    ),
  );

  // ══════════════════════════════════════════════════════════════════════════
  // 8. OBSERVACIONES — con líneas horizontales pautadas
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildObservaciones(Map<String, dynamic> os) {
    final obs     = _s(os, 'observaciones', '');
    const nLineas = 3;
    const lineH   = 11.0;

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      _sectionTitle('OBSERVACIONES'),
      pw.SizedBox(height: 2),
      // Área pautada — únicamente texto de observaciones sin dictamen
      ...List.generate(nLineas, (i) => pw.Container(
        height: lineH,
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _grayL, width: 0.5))),
        child: i == 0 && obs.isNotEmpty
            ? pw.Padding(
                padding: const pw.EdgeInsets.only(left: 3, bottom: 2),
                child: pw.Text(
                  obs,
                  style: const pw.TextStyle(fontSize: 7.5)),
              )
            : null,
      )),
    ]);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 9. FIRMAS
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildFirmas(Map<String, dynamic> os,
      pw.ImageProvider? firmaTec, pw.ImageProvider? firmaCli) {
    final tecnico = _s(os, 'tecnico_nombre', _s(os, 'tecnico', 'Alan Guevara'));
    final cliente = _s(os, 'nombre_ing', _s(os, 'firma_cliente_nombre', _s(os, 'nombre_responsable', '')));
    final puesto  = _s(os, 'puesto_ing', '');
    final subCli  = puesto.isNotEmpty ? '$puesto\nNOMBRE Y FIRMA' : 'NOMBRE Y FIRMA';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: _firmaBox('TECNICO RESPONSABLE', tecnico, firmaTec),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: _firmaBox('CLIENTE', cliente, firmaCli, subtitle: subCli),
        ),
      ],
    );
  }

  pw.Widget _firmaBox(String titulo, String nombre, pw.ImageProvider? img,
      {String? subtitle}) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Container(
            height: 42,
            width: double.infinity,
            child: img != null
                ? pw.Center(
                    child: pw.Image(img, fit: pw.BoxFit.contain),
                  )
                : pw.SizedBox.expand(),
          ),
          pw.Container(height: 0.7, color: _black),
          pw.SizedBox(height: 3),
          pw.Text(titulo, textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold,
                  color: _redBright)),
          if (nombre.isNotEmpty)
            pw.Text(nombre, textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 7)),
          if (subtitle != null)
            pw.Text(subtitle, textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 6.5, color: _gray)),
        ]),
      );

  // ══════════════════════════════════════════════════════════════════════════
  // WIDGETS AUXILIARES DE TABLA
  // ══════════════════════════════════════════════════════════════════════════

  /// Encabezado oscuro de sección (negro)
  pw.Widget _tblHeader(String text) => pw.Container(
    width: double.infinity,
    color: _dark,
    padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
    child: pw.Text(text, textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold,
            color: _white)),
  );

  /// Celda de sub-header ROJA (fiel a imagen oficial)
  pw.Widget _redHdrCell(String text, double flex) => pw.Expanded(
    flex: (flex * 100).round(),
    child: pw.Container(
      color: _red,
      padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
      child: pw.Center(child: pw.Text(text, textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 5.5, fontWeight: pw.FontWeight.bold,
              color: _white))),
    ),
  );

  /// Fila de datos
  pw.Widget _dataRow(List<String> cells, List<double> widths, bool gray) =>
      pw.Container(
        color: gray ? _grayBg : _white,
        child: pw.Row(
          children: cells.asMap().entries.map((e) {
            final isDiag = e.value == '/';
            return pw.Expanded(
              flex: (widths[e.key] * 100).round(),
              child: pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border(
                    right: pw.BorderSide(color: _grayL, width: 0.3),
                    bottom: pw.BorderSide(color: _grayL, width: 0.3),
                  )),
                padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 2.5),
                child: pw.Center(child: pw.Text(e.value,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: isDiag ? 7.5 : 6.5,
                      color: isDiag ? _gray : _black,
                      fontStyle: isDiag ? pw.FontStyle.italic : pw.FontStyle.normal,
                    ))),
              ),
            );
          }).toList(),
        ),
      );

  /// Fila footer con "ERROR MÁXIMO ENCONTRADO:"
  pw.Widget _errMaxRow(String label, String val) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    decoration: pw.BoxDecoration(
      color: _white,
      border: pw.Border.all(color: _grayL, width: 0.4)),
    child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(label, style: pw.TextStyle(fontSize: 6.5,
          fontWeight: pw.FontWeight.bold)),
      pw.Text(val, style: pw.TextStyle(fontSize: 7,
          fontWeight: pw.FontWeight.bold, color: _redBright)),
    ]),
  );

  // ══════════════════════════════════════════════════════════════════════════
  // GUARDAR EN DISCO
  // ══════════════════════════════════════════════════════════════════════════
  /// Escribe a un temporal y lo renombra sobre el destino: si la escritura
  /// falla, el PDF existente permanece intacto (nunca se borra antes).
  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true, mode: FileMode.write);
    try {
      await tmp.rename(target.path);
    } catch (_) {
      await target.writeAsBytes(bytes, flush: true, mode: FileMode.write);
      try { await tmp.delete(); } catch (_) {}
    }
  }

  Future<String> _saveToDisk(Map<String, dynamic> osData, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${dir.path}/pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }

    final folio = _s(osData, 'folio_os', _s(osData, 'folio', 'OS')).trim();
    final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName = safeFolio.startsWith('OS-') ? '$safeFolio.pdf' : 'OS-$safeFolio.pdf';
    final filePath = '${pdfDir.path}/$fileName';
    final file = File(filePath);
    await _writeAtomic(file, bytes);

    // Guardar también copia en Pesa_PDFs para compatibilidad con versiones previas
    try {
      final legacyDir = Directory('${dir.path}/Pesa_PDFs');
      if (!await legacyDir.exists()) await legacyDir.create(recursive: true);
      await _writeAtomic(File('${legacyDir.path}/$fileName'), bytes);
    } catch (_) {}

    return filePath;
  }

  /// Guarda bytes de PDF directamente en el directorio seguro 'pdfs/OS-{folio}.pdf'
  Future<String> guardarPdfEnDisco(String folio, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${dir.path}/pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }
    final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName = safeFolio.startsWith('OS-') ? '$safeFolio.pdf' : 'OS-$safeFolio.pdf';
    final file = File('${pdfDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true, mode: FileMode.write);
    return file.path;
  }

  Future<void> abrirPdf(String path) async {
    await Printing.sharePdf(
      bytes: await File(path).readAsBytes(),
      filename: path.split('/').last,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UTILIDADES
  // ══════════════════════════════════════════════════════════════════════════
  String _s(Map<String, dynamic> os, String key, [String fallback = '']) {
    final v = os[key];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    return fallback;
  }

  int _parseDivMin(Map<String, dynamic> os) {
    final raw = _s(os, 'div_minima', _s(os, 'division_minima', ''));
    if (raw.isEmpty) return 0;
    final d = double.tryParse(raw.replaceAll(',', '.'));
    return getDecimalsFromD(d);
  }

  String _fmtDec(dynamic v, int dec) {
    if (v == null) return '';
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    return d == null ? v.toString() : d.toStringAsFixed(dec);
  }


  double? _toNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim().replaceAll(',', '.');
    return double.tryParse(s);
  }

  bool _parseBool(dynamic v) {
    if (v == null) return true;
    if (v is bool) return v;
    if (v is int) return v != 0;
    final s = v.toString().trim().toUpperCase();
    return s != 'NO' && s != 'FALSE' && s != '0' && s != 'N';
  }
}

// ══════════════════════════════════════════════════════════════════════════
// PAINTERS GEOMÉTRICOS — solo formas, sin drawString (no accesible en pdf 3.x closures)
// Los números se superponen como pw.Text vía pw.Stack en los widgets padre.
// ══════════════════════════════════════════════════════════════════════════

/// Panel 1: Plataforma — rectángulo con diagonales X (sin círculos; se superponen con pw.Stack)
void _dibujarPlataforma(PdfGraphics c, PdfPoint size) {
  final w = size.x;
  final h = size.y;
  const dark = PdfColor.fromInt(0xFF444444);
  const fill = PdfColor.fromInt(0xFFF0F0F0);
  const line = PdfColor.fromInt(0xFFBBBBBB);

  const padX = 6.0;
  const padY = 6.0;
  final rx = padX, ry = padY;
  final rw = w - 2 * padX, rh = h - 2 * padY;

  c.setFillColor(fill);
  c.setStrokeColor(dark);
  c.setLineWidth(0.9);
  c.drawRect(rx, ry, rw, rh);
  c.fillPath();
  c.drawRect(rx, ry, rw, rh);
  c.strokePath();

  c.setStrokeColor(line);
  c.setLineWidth(0.5);
  c.moveTo(rx, ry);        c.lineTo(rx + rw, ry + rh); c.strokePath();
  c.moveTo(rx + rw, ry);   c.lineTo(rx, ry + rh);      c.strokePath();
}

/// Panel 2: Circular — elipse con cruz central (sin círculos; se superponen con pw.Stack)
void _dibujarCircular(PdfGraphics c, PdfPoint size) {
  final w = size.x;
  final h = size.y;
  const dark = PdfColor.fromInt(0xFF444444);
  const fill = PdfColor.fromInt(0xFFF0F0F0);
  const line = PdfColor.fromInt(0xFFBBBBBB);

  final cx = w / 2, cy = h / 2;
  const padX = 6.0;
  const padY = 6.0;
  final rx = (w - 2 * padX) / 2;
  final ry = (h - 2 * padY) / 2;

  c.setFillColor(fill);
  c.setStrokeColor(dark);
  c.setLineWidth(0.9);
  c.drawEllipse(cx, cy, rx, ry);
  c.fillPath();
  c.drawEllipse(cx, cy, rx, ry);
  c.strokePath();

  c.setStrokeColor(line);
  c.setLineWidth(0.5);
  c.moveTo(cx - rx, cy); c.lineTo(cx + rx, cy); c.strokePath();
  c.moveTo(cx, cy - ry); c.lineTo(cx, cy + ry); c.strokePath();
}

// ══════════════════════════════════════════════════════════════════════════
// MODELO AUXILIAR
// ══════════════════════════════════════════════════════════════════════════
class _FD {
  final String lbl;
  final String val;
  final double w;
  const _FD(this.lbl, this.val, this.w);
}
