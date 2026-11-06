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


String formatoMilesEspacio(dynamic valor) {
  if (valor == null) return '';
  String txt = valor.toString().trim();
  if (txt.isEmpty) return '';

  // Manejar posibles sufijos (ej. '80000 kg')
  final RegExp regExp = RegExp(r'^([-+]?[0-9,.]+)\s*(.*)$');
  final match = regExp.firstMatch(txt);
  if (match == null) return txt;

  String numPart = match.group(1)!;
  String sufijo = match.group(2) ?? '';

  String res = numPart;
  if (numPart.contains('.')) {
    var partes = numPart.split('.');
    String entera = partes[0].replaceAll(',', '').replaceAll(' ', '');
    String decimal = partes[1];
    int? entNum = int.tryParse(entera);
    if (entNum != null) {
      String entFmt = entNum.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]} ',
      );
      res = '$entFmt.$decimal';
    }
  } else {
    String entera = numPart.replaceAll(',', '').replaceAll(' ', '');
    int? entNum = int.tryParse(entera);
    if (entNum != null) {
      res = entNum.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]} ',
      );
    }
  }

  return sufijo.isNotEmpty ? '$res $sufijo' : res;
}

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
    final String folioCheck = (osData['folio_os'] ?? osData['folio'] ?? '').toString().trim().toUpperCase();
    final String tipoDocCheck = (osData['tipo_documento'] ?? '').toString().trim().toUpperCase();
    if (folioCheck.startsWith('OSOCC-') || tipoDocCheck == 'OSOCC') {
      return generarPdfObservacionesCelda(
        osData: osData,
        firmaTecBase64: firmaTecBase64,
        firmaCliBase64: firmaCliBase64,
      );
    }
    if (folioCheck.startsWith('OSOB-') || tipoDocCheck == 'OSOB') {
      return generarPdfObservacionesBascula(
        osData: osData,
        firmaTecBase64: firmaTecBase64,
        firmaCliBase64: firmaCliBase64,
      );
    }

    final String fechaEjecucionHoy = DateTime.now().toIso8601String().substring(0, 10);
    osData['fecha_creacion_logistica'] ??= osData['fecha'];
    osData['fecha'] = fechaEjecucionHoy;
    osData['fecha_servicio'] = fechaEjecucionHoy;
    osData['fecha_cierre'] ??= DateTime.now().toIso8601String();

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
    final String folioCheck = (osData['folio_os'] ?? osData['folio'] ?? '').toString().trim().toUpperCase();
    final String tipoDocCheck = (osData['tipo_documento'] ?? '').toString().trim().toUpperCase();
    if (folioCheck.startsWith('OSOCC-') || tipoDocCheck == 'OSOCC') {
      return buildPdfObservacionesCeldaBytes(
        osData: osData,
        firmaTecBase64: firmaTecBase64,
        firmaCliBase64: firmaCliBase64,
      );
    }
    if (folioCheck.startsWith('OSOB-') || tipoDocCheck == 'OSOB') {
      return buildPdfObservacionesBasculaBytes(
        osData: osData,
        firmaTecBase64: firmaTecBase64,
        firmaCliBase64: firmaCliBase64,
      );
    }

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
    final cliente = _s(os, 'cliente', _s(os, 'cliente_nombre', _s(os, 'razon_social', ''))).trim();
    final ubicacionEquipo = _s(os, 'ubicacion', _s(os, 'area', _s(os, 'ubicacion_equipo', ''))).trim();

    // Separar estrictamente la Dirección de la Planta de la Ubicación física del instrumento:
    // Campo DIRECCIÓN / PLANTA del membrete: NUNCA usar 'ubicacion', 'area' o 'ubicacion_equipo'.
    String dirVal = '';
    for (final k in [
      'sucursal',
      'planta_direccion',
      'direccion',
      'domicilio',
      'planta',
      'direccion_cliente',
      'sucursal_nombre',
      'sucursal_direccion',
      'planta_nombre',
    ]) {
      final v = os[k]?.toString().trim();
      if (v != null && v.isNotEmpty && v != '-' && v.toLowerCase() != 'null') {
        if (ubicacionEquipo.isNotEmpty && v.toLowerCase() == ubicacionEquipo.toLowerCase()) {
          continue;
        }
        dirVal = v;
        break;
      }
    }

    // Si sucursal no está en el registro o coincide con ubicación interna, fallback de cliente
    if (dirVal.isEmpty || (ubicacionEquipo.isNotEmpty && dirVal.toLowerCase() == ubicacionEquipo.toLowerCase())) {
      if (cliente.toLowerCase().contains('mar bran')) {
        dirVal = 'Carretera el Jaral del Progreso- Cortazar km 4.3 C.P. 38470, Jaral del Progreso, Guanajuato';
      } else {
        dirVal = 'Domicilio conocido';
      }
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _labelValueRow('CLIENTE:', cliente.isNotEmpty ? cliente : 'Cliente General'),
        pw.SizedBox(height: 1),
        _labelValueRow('DIRECCIÓN / PLANTA:', dirVal),
      ],
    );
  }

  pw.Widget _labelValueRow(String label, String value) => pw.Row(children: [
    pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold,
        color: _redBright)),
    pw.SizedBox(width: 4),
    pw.Expanded(
      child: pw.Text(
        (value.isNotEmpty && value != '-') ? value : 'Domicilio conocido',
        style: const pw.TextStyle(fontSize: 8),
      ),
    ),
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
    final ubic   = _s(os, 'ubicacion', _s(os, 'area', _s(os, 'ubicacion_equipo', '')));
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
        _FD('CAPACIDAD MÁXIMA', cap.isNotEmpty ? formatoMilesEspacio(cap.toLowerCase().endsWith(unidad.toLowerCase()) ? cap : '$cap $unidad') : '', 0.28),
        _FD('DIVISIÓN MÍNIMA', div.isNotEmpty ? formatoMilesEspacio(div.toLowerCase().endsWith(unidad.toLowerCase()) ? div : '$div $unidad') : '', 0.24),
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
    // Evaluación ESTRICTA: el tipo se toma SOLO de tipo_instrumento (no de un
    // motivo_no_aplica='Tanque' heredado) y la bandera SOLO de aplica_sustitucion
    // (fallback usa_sustitucion si no existe). es_sustitucion / es_enlace_sustitucion
    // pueden quedar 'pegadas' tras cambiar el tipo en captura y ya no se consideran.
    final bool esTanque = (osData['tipo_instrumento']?.toString().toLowerCase().contains('tanque') ?? false);
    final rawSust = osData.containsKey('aplica_sustitucion') && osData['aplica_sustitucion'] != null
        ? osData['aplica_sustitucion']
        : osData['usa_sustitucion'];
    final String sSust = rawSust?.toString().trim().toUpperCase() ?? '';
    final bool aplicaSustitucion = rawSust == true || rawSust == 1 ||
        sSust == '1' || sSust == 'TRUE' || sSust == 'SI' || sSust == 'SÍ';
    // Plataforma (no Tanque) sin sustitución explícita ⇒ tabla tradicional.
    final bool esSustitucion = esTanque || aplicaSustitucion;

    if (esSustitucion) {
      final sustitutosRaw = osData['sustitutos'] ?? osData['elementos_sustitucion'];
      List<Map<String, dynamic>> validSustitutos = [];
      if (sustitutosRaw is List) {
        for (final item in sustitutosRaw) {
          if (item is Map) {
            final p = _toNum(item['peso']);
            final n = _s(item as Map<String, dynamic>, 'sustituto', _s(item, 'nombre', ''));
            if (p != null && p > 0) {
              validSustitutos.add({
                'sustituto': n.isNotEmpty ? n : 'Sustituto ${validSustitutos.length + 1}',
                'peso': p
              });
            }
          }
        }
      }
      if (validSustitutos.isEmpty && osData['peso_sustituto'] != null) {
        final p = _toNum(osData['peso_sustituto']);
        if (p != null && p > 0) {
          validSustitutos.add({'sustituto': 'Sustituto 1', 'peso': p});
        }
      }
      // FÍSICO: si aplica Sustituto (bandera o lista configurada), tabla en blanco.
      bool flagSust(dynamic v) =>
          v == true || v == 1 || ['1', 'true', 'si', 'sí'].contains(v?.toString().trim().toLowerCase());
      final bool sustitutoFisicoBlanco = validSustitutos.isEmpty &&
          _esFormatoFisico(osData, tieneDatos: false) &&
          (flagSust(osData['aplica_sustituto']) ||
              flagSust(osData['usa_sustituto']) ||
              flagSust(osData['tiene_sustituto']) ||
              (sustitutosRaw is List && sustitutosRaw.isNotEmpty));
      final bool tieneSustitutos = validSustitutos.isNotEmpty || sustitutoFisicoBlanco;

      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Col izquierda (200 pt): Repetibilidad + Excentricidad No Apto (Tanque) + Sustituto (si existe)
          pw.SizedBox(
            width: 200,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _buildRepetibilidadTable(repRows, osData, divMin),
                pw.SizedBox(height: 5),
                _buildNoAplicaTanqueBox(),
                if (tieneSustitutos) ...[
                  pw.SizedBox(height: 5),
                  _buildSustitutoTable(validSustitutos, osData, divMin,
                      enBlanco: sustitutoFisicoBlanco,
                      filasBlanco: sustitutosRaw is List ? sustitutosRaw.length : 0),
                ],
              ],
            ),
          ),
          pw.SizedBox(width: 8),
          // Col derecha: Exactitud con sustitución (7 columnas)
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _buildExactitudSustitucionTable(exacRows, osData, divMin),
              ],
            ),
          ),
        ],
      );
    }

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
              (aplExc || (!esTanque && motivoNo.toLowerCase().contains('tanque')))
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
  // NO APTO TANQUE (EXCENTRICIDAD)
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildNoAplicaTanqueBox() {
    const borderColor = PdfColor.fromInt(0xFFFFCCCC);
    const bgColor = PdfColor.fromInt(0xFFFFF8F8);
    const iconColor = PdfColor.fromInt(0xFFC8102E);
    const textColor = PdfColor.fromInt(0xFF7A0010);
    const subColor = PdfColor.fromInt(0xFF555555);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          height: 14,
          color: borderColor,
          child: pw.Center(
            child: pw.Text(
              'EXCENTRICIDAD',
              style: pw.TextStyle(fontSize: 7.0, fontWeight: pw.FontWeight.bold, color: textColor),
            ),
          ),
        ),
        pw.Container(
          height: 61,
          decoration: pw.BoxDecoration(
            color: bgColor,
            border: pw.Border.all(color: borderColor, width: 1.0),
          ),
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.SizedBox(
                width: 32,
                height: 25,
                child: pw.CustomPaint(painter: _dibujarTanque),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'INSTRUMENTO NO APTO PARA PRUEBA DE EXCENTRICIDAD',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: iconColor),
              ),
              pw.SizedBox(height: 1.5),
              pw.Text(
                'Báscula tipo: Tanque — pesaje de carga estática',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 5.5, fontStyle: pw.FontStyle.italic, color: subColor),
              ),
              pw.SizedBox(height: 1),
              pw.Text(
                'No aplica prueba de excentricidad.',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 5.5, fontStyle: pw.FontStyle.italic, color: subColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TABLA SUSTITUTO / PESO (Solo si peso > 0)
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildSustitutoTable(
      List<Map<String, dynamic>> sustitutos, Map<String, dynamic> os, int dec,
      {bool enBlanco = false, int filasBlanco = 0}) {
    const hdrColor = PdfColor.fromInt(0xFFD9E2F3);
    const borderColor = PdfColor.fromInt(0xFF333333);
    const rowH = 13.0;
    const hdrH = 14.0;

    double totalPeso = 0;
    for (final s in sustitutos) {
      final p = _toNum(s['peso']) ?? 0;
      totalPeso += p;
    }

    final displayRows = List<Map<String, dynamic>>.from(sustitutos);
    final int minRows = enBlanco && filasBlanco > 4 ? filasBlanco : 4;
    while (displayRows.length < minRows) {
      displayRows.add({});
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          height: hdrH,
          decoration: pw.BoxDecoration(
            color: hdrColor,
            border: pw.Border.all(color: borderColor, width: 0.5),
          ),
          child: pw.Row(
            children: [
              pw.Expanded(
                flex: 70,
                child: pw.Center(
                  child: pw.Text('SUSTITUTO',
                      style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black)),
                ),
              ),
              pw.Container(width: 0.5, color: borderColor, height: hdrH),
              pw.Expanded(
                flex: 30,
                child: pw.Center(
                  child: pw.Text('PESO',
                      style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black)),
                ),
              ),
            ],
          ),
        ),
        ...displayRows.map((r) {
          final nom = (r['sustituto'] ?? '').toString();
          final pesoNum = _toNum(r['peso']);
          final pesoStr = pesoNum != null ? formatoMilesEspacio(_fmtDec(pesoNum, dec)) : '';
          return pw.Container(
            height: rowH,
            decoration: const pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border(
                left: pw.BorderSide(color: borderColor, width: 0.5),
                right: pw.BorderSide(color: borderColor, width: 0.5),
                bottom: pw.BorderSide(color: borderColor, width: 0.5),
              ),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  flex: 70,
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 4),
                    child: pw.Align(
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Text(nom, style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.black)),
                    ),
                  ),
                ),
                pw.Container(width: 0.5, color: borderColor, height: rowH),
                pw.Expanded(
                  flex: 30,
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.only(right: 4),
                    child: pw.Align(
                      alignment: pw.Alignment.centerRight,
                      child: pw.Text(pesoStr, style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.black)),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        pw.Container(
          height: rowH,
          decoration: const pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border(
              left: pw.BorderSide(color: borderColor, width: 0.5),
              right: pw.BorderSide(color: borderColor, width: 0.5),
              bottom: pw.BorderSide(color: borderColor, width: 0.5),
            ),
          ),
          child: pw.Row(
            children: [
              pw.Expanded(
                flex: 70,
                child: pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 4),
                  child: pw.Align(
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Text('TOTAL',
                        style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black)),
                  ),
                ),
              ),
              pw.Container(width: 0.5, color: borderColor, height: rowH),
              pw.Expanded(
                flex: 30,
                child: pw.Padding(
                  padding: const pw.EdgeInsets.only(right: 4),
                  child: pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Text(enBlanco ? '' : formatoMilesEspacio(_fmtDec(totalPeso, dec)),
                        style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: PdfColors.black)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // TABLA EXACTITUD CON SUSTITUCIÓN (7 COLUMNAS)
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildExactitudSustitucionTable(
      List<Map<String, dynamic>> rows, Map<String, dynamic> os, int dec) {
    const hdrColor = PdfColor.fromInt(0xFF1C1C1C);
    const borderColor = PdfColor.fromInt(0xFF333333);
    const rowH = 14.0;
    const hdrH = 15.0;

    // Renglones con datos capturados por el técnico
    final puntosValidos = rows.where((p) {
      final pesas = p['pesas']?.toString().trim() ?? '';
      final agua  = p['agua']?.toString().trim() ?? '';
      final ind   = (p['indicacion'] ?? p['lectura_inicial'])?.toString().trim() ?? '';
      return pesas.isNotEmpty || agua.isNotEmpty || ind.isNotEmpty;
    }).toList();

    // ── Bifurcación FÍSICO vs DIGITAL ──
    // FÍSICO: NUNCA omitir renglones; exactamente N filas configuradas (en blanco).
    // DIGITAL: omitir renglones que el técnico dejó vacíos.
    final bool esFisico = _esFormatoFisico(os, tieneDatos: puntosValidos.isNotEmpty);
    final List<Map<String, dynamic>> display;
    if (esFisico) {
      final int nCfg = _numEnlacesConfigurados(os, rows.length);
      display = List<Map<String, dynamic>>.generate(
          nCfg, (i) => i < rows.length ? rows[i] : <String, dynamic>{});
    } else {
      display = puntosValidos.isNotEmpty
          ? puntosValidos
          : (rows.isNotEmpty ? [rows.first] : <Map<String, dynamic>>[]);
    }

    final colWidths = [
      0.06, // N
      0.15, // PESAS
      0.15, // AGUA
      0.20, // AGUA + PESAS
      0.16, // INDICACIÓN
      0.14, // REGRESO
      0.14, // ERROR
    ];

    final headers = ['N', 'PESAS', 'AGUA', 'AGUA + PESAS', 'INDICACIÓN', 'REGRESO', 'ERROR'];

    double maxErr = 0;
    for (final r in display) {
      final p = _toNum(r['pesas']);
      final a = _toNum(r['agua']);
      double? ap = _toNum(r['agua_pesas']);
      if (ap == null && (p != null || a != null)) {
        ap = (p ?? 0) + (a ?? 0);
      }
      final ind = _toNum(r['indicacion'] ?? r['lectura_inicial']);
      double? err;
      if (ind != null && ap != null) {
        err = ind - ap;
      } else if (r['error'] != null) {
        err = _toNum(r['error']);
      }
      if (err != null && err.abs() > maxErr) {
        maxErr = err.abs();
      }
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          height: hdrH,
          color: hdrColor,
          child: pw.Row(
            children: headers.asMap().entries.map((e) {
              final w = colWidths[e.key];
              return pw.Expanded(
                flex: (w * 100).toInt(),
                child: pw.Center(
                  child: pw.Text(
                    e.value,
                    style: pw.TextStyle(
                      fontSize: 6.5,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        ...display.asMap().entries.map((e) {
          final idx = e.key;
          final r = e.value;
          final n = '${idx + 1}';
          final p = _toNum(r['pesas']);
          final a = _toNum(r['agua']);
          double? ap = _toNum(r['agua_pesas']);
          if (ap == null && (p != null || a != null)) {
            ap = (p ?? 0) + (a ?? 0);
          }
          final ind = _toNum(r['indicacion'] ?? r['lectura_inicial']);
          final reg = _toNum(r['regreso'] ?? r['lectura_final']);
          double? err;
          if (ind != null && ap != null) {
            err = ind - ap;
          } else if (r['error'] != null) {
            err = _toNum(r['error']);
          }

          final bool hasData = p != null || a != null || ind != null || ap != null;

          final vals = [
            n,
            p != null ? formatoMilesEspacio(_fmtDec(p, dec)) : '',
            a != null ? formatoMilesEspacio(_fmtDec(a, dec)) : '',
            ap != null ? formatoMilesEspacio(_fmtDec(ap, dec)) : '',
            ind != null ? formatoMilesEspacio(_fmtDec(ind, dec)) : '',
            reg != null ? formatoMilesEspacio(_fmtDec(reg, dec)) : '',
            err != null ? formatoMilesEspacio(_fmtDec(err, dec)) : (hasData && !esFisico ? '0' : ''),
          ];

          return pw.Container(
            height: rowH,
            decoration: pw.BoxDecoration(
              color: idx % 2 == 1 ? const PdfColor.fromInt(0xFFF9F9F9) : PdfColors.white,
              border: const pw.Border(
                left: pw.BorderSide(color: borderColor, width: 0.4),
                right: pw.BorderSide(color: borderColor, width: 0.4),
                bottom: pw.BorderSide(color: borderColor, width: 0.4),
              ),
            ),
            child: pw.Row(
              children: vals.asMap().entries.map((ve) {
                final cIdx = ve.key;
                final val = ve.value;
                final w = colWidths[cIdx];
                return pw.Expanded(
                  flex: (w * 100).toInt(),
                  child: pw.Container(
                    decoration: pw.BoxDecoration(
                      border: cIdx > 0
                          ? const pw.Border(left: pw.BorderSide(color: borderColor, width: 0.3))
                          : null,
                    ),
                    child: pw.Center(
                      child: pw.Text(
                        val,
                        style: pw.TextStyle(
                          fontSize: 7.0,
                          fontWeight: cIdx == 0 ? pw.FontWeight.bold : pw.FontWeight.normal,
                          color: PdfColors.black,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }),
        pw.Container(
          height: rowH,
          decoration: const pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border(
              left: pw.BorderSide(color: borderColor, width: 0.4),
              right: pw.BorderSide(color: borderColor, width: 0.4),
              bottom: pw.BorderSide(color: borderColor, width: 0.4),
            ),
          ),
          child: pw.Row(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 6),
                child: pw.Text(
                  'ERROR MÁXIMO ENCONTRADO:',
                  style: pw.TextStyle(fontSize: 7.0, fontWeight: pw.FontWeight.bold, color: PdfColors.black),
                ),
              ),
              pw.Spacer(),
              pw.Padding(
                padding: const pw.EdgeInsets.only(right: 6),
                child: pw.Text(
                  esFisico && maxErr == 0 ? '' : formatoMilesEspacio(_fmtDec(maxErr, dec)),
                  style: pw.TextStyle(fontSize: 7.0, fontWeight: pw.FontWeight.bold, color: PdfColors.black),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// FÍSICO si la modalidad es explícitamente física / impresión en blanco,
  /// o si no es DIGITAL explícito y no hay capturas (plantilla para imprimir).
  bool _esFormatoFisico(Map<String, dynamic> os, {required bool tieneDatos}) {
    final m = (os['modalidad']?.toString() ?? '')
        .trim()
        .toLowerCase()
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o');
    bool flag(dynamic v) =>
        v == true || v == 1 || ['1', 'true', 'si', 'sí'].contains(v?.toString().trim().toLowerCase());
    final explicito = ['fisico', 'impresion', 'blanco', 'calca'].contains(m) ||
        flag(os['es_formato_fisico']) ||
        flag(os['es_impresion_en_blanco']);
    return explicito || (m != 'digital' && !tieneDatos);
  }

  int _numEnlacesConfigurados(Map<String, dynamic> os, int fallbackLen) {
    for (final k in ['num_enlaces_sustitucion', 'num_enlaces', 'pts_exactitud']) {
      final v = int.tryParse(os[k]?.toString() ?? '');
      if (v != null && v > 0) return v;
    }
    return fallbackLen > 0 ? fallbackLen : 6;
  }

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
  // 8. OBSERVACIONES — ajuste multilínea dinámico sin cortes
  // ══════════════════════════════════════════════════════════════════════════
  pw.Widget _buildObservaciones(Map<String, dynamic> orden) {
    final String obsTexto = (orden['observaciones'] ?? orden['observaciones_tecnico'] ?? '').toString().trim();
    final double obsFontSize = obsTexto.length > 350
        ? 6.8
        : (obsTexto.length > 200 ? 7.5 : 8.5);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('OBSERVACIONES'),
        pw.SizedBox(height: 2),
        pw.Container(
          width: double.infinity,
          constraints: const pw.BoxConstraints(minHeight: 38),
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
          ),
          child: pw.Text(
            obsTexto.isEmpty ? 'Sin observaciones adicionales.' : obsTexto,
            style: pw.TextStyle(
              fontSize: obsFontSize,
              lineSpacing: 1.5,
            ),
            softWrap: true,
            textAlign: pw.TextAlign.left,
          ),
        ),
      ],
    );
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
    final d = v is num ? v.toDouble() : double.tryParse(v.toString().replaceAll(',', '.').replaceAll(' ', ''));
    final raw = d == null ? v.toString() : d.toStringAsFixed(dec);
    return formatoMilesEspacio(raw);
  }


  double? _toNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim().replaceAll(',', '.').replaceAll(' ', '');
    return double.tryParse(s);
  }

  bool _parseBool(dynamic v) {
    if (v == null) return true;
    if (v is bool) return v;
    if (v is int) return v != 0;
    final s = v.toString().trim().toUpperCase();
    return s != 'NO' && s != 'FALSE' && s != '0' && s != 'N';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // GENERADOR DE PDF OFICIAL — REVISIÓN DE CELDAS DE CARGA Y BÁSCULA (RE)
  // Homologado 1:1 con servicios_pesa/services/re_pdf_generator.py
  // ══════════════════════════════════════════════════════════════════════════
  static const List<List<String>> ohmsParamsOficiales = [
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

  Future<String> generarPdfRevisionCeldas({
    required Map<String, dynamic> rvData,
    required int numCeldas,
    required List<List<String>> lecturasOhms,
    required Map<String, bool> funcIndicador,
    required List<String> estadoCeldas,
    required String estadoCables,
    required String estadoConectores,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final String fechaEjecucionHoy = DateTime.now().toIso8601String().substring(0, 10);
    rvData['fecha_creacion_logistica'] ??= rvData['fecha'];
    rvData['fecha'] = fechaEjecucionHoy;
    rvData['fecha_servicio'] = fechaEjecucionHoy;
    rvData['fecha_cierre'] ??= DateTime.now().toIso8601String();

    final bytes = await buildPdfRevisionCeldasBytes(
      rvData: rvData,
      numCeldas: numCeldas,
      lecturasOhms: lecturasOhms,
      funcIndicador: funcIndicador,
      estadoCeldas: estadoCeldas,
      estadoCables: estadoCables,
      estadoConectores: estadoConectores,
      firmaTecBase64: firmaTecBase64,
      firmaCliBase64: firmaCliBase64,
    );

    final dir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${dir.path}/pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }
    final folio = _s(rvData, 'folio_os', _s(rvData, 'folio_re', 'RE')).trim();
    final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filePath = '${pdfDir.path}/$safeFolio.pdf';
    await _writeAtomic(File(filePath), bytes);

    try {
      final legacyDir = Directory('${dir.path}/Pesa_PDFs');
      if (!await legacyDir.exists()) await legacyDir.create(recursive: true);
      await _writeAtomic(File('${legacyDir.path}/$safeFolio.pdf'), bytes);
    } catch (_) {}

    return filePath;
  }

  Future<Uint8List> buildPdfRevisionCeldasBytes({
    required Map<String, dynamic> rvData,
    required int numCeldas,
    required List<List<String>> lecturasOhms,
    required Map<String, bool> funcIndicador,
    required List<String> estadoCeldas,
    required String estadoCables,
    required String estadoConectores,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final folio = _s(rvData, 'folio_os', _s(rvData, 'folio_re', '—'));
    final doc = pw.Document(
      title: 'RE — $folio',
      author: 'Servicios PESA',
      subject: 'Ficha Tecnica Diagnostica — Revision de Celdas de Carga y Bascula',
      creator: 'PESA Tablet App v3',
    );

    pw.ImageProvider? logoPesa;
    pw.ImageProvider? logoRl;
    for (final p in ['Img/logo_pesa.png', 'assets/logo_pesa.png']) {
      try {
        final b = await rootBundle.load(p);
        logoPesa = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }
    for (final p in ['Img/RiceLake.png', 'assets/RiceLake.png']) {
      try {
        final b = await rootBundle.load(p);
        logoRl = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }

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

    final int n = numCeldas.clamp(1, 12);
    const redRe = PdfColor.fromInt(0xFFCC1F1F);
    const darkHdr = PdfColor.fromInt(0xFF1C1C1C);
    const grayHdr = PdfColor.fromInt(0xFF2D2D2D);
    const grayLt = PdfColor.fromInt(0xFFF5F5F5);
    const grayMed = PdfColor.fromInt(0xFFCCCCCC);
    const grayDk = PdfColor.fromInt(0xFF888888);

    String pick(List<String> keys, [String def = '']) {
      for (final k in keys) {
        final v = rvData[k];
        if (v != null && v.toString().trim().isNotEmpty && v.toString().trim() != 'null') {
          return v.toString().trim();
        }
      }
      return def;
    }

    pw.Widget buildSectionBar(int numSec, String title) {
      return pw.Container(
        height: 16,
        margin: const pw.EdgeInsets.only(top: 2, bottom: 2),
        color: darkHdr,
        padding: const pw.EdgeInsets.symmetric(horizontal: 5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              width: 12,
              height: 12,
              decoration: const pw.BoxDecoration(color: redRe, shape: pw.BoxShape.circle),
              child: pw.Center(
                child: pw.Text(
                  '$numSec',
                  style: pw.TextStyle(color: _white, fontSize: 7.5, fontWeight: pw.FontWeight.bold),
                ),
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Text(
              title.toUpperCase(),
              style: pw.TextStyle(color: _white, fontSize: 8.5, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      );
    }

    pw.Widget buildCheckbox(bool checked) {
      return pw.Container(
        width: 7,
        height: 7,
        decoration: pw.BoxDecoration(
          color: checked ? darkHdr : _white,
          border: pw.Border.all(color: _black, width: 0.7),
        ),
        child: checked
            ? pw.Center(
                child: pw.Text(
                  'X',
                  style: pw.TextStyle(color: _white, fontSize: 5.5, fontWeight: pw.FontWeight.bold),
                ),
              )
            : null,
      );
    }

    final indItems = <String>[
      'Indicador de Peso',
      'Teclado / Botones',
      'Luminosidad / Display',
      'Convertidor Analogico',
      'Caja Sumadora',
      for (int k = 1; k <= n; k++) 'Potenciometro $k',
    ];
    final int maxFuncRows = indItems.length > n ? indItems.length : n;
    final double funcRowH = maxFuncRows > 9 ? (108.0 / maxFuncRows).clamp(8.5, 12.0) : 11.5;

    final clienteVal = pick(['cliente', 'razon_social']);
    final direccionVal = pick([
      'direccion',
      'sucursal_direccion',
      'direccion_planta',
      'cliente_direccion',
      'sucursal',
    ]);
    final marcaInd = pick(['indicador_marca', 'marca', 'instrumento_marca']);
    final modeloInd = pick(['indicador_modelo', 'modelo', 'instrumento_modelo']);
    final serieInd = pick(['indicador_serie', 'ns', 'serie', 'numero_serie', 'instrumento_serie']);
    final idInd = pick(['indicador_id', 'id_indicador', 'id_equipo', 'instrumento_id']);
    final capMax = pick(['cap_maxima', 'capacidad_maxima', 'alcance_max', 'instrumento_capacidad']);
    final divMin = pick(['div_minima', 'division_minima', 'instrumento_division']);
    final ubicacion = pick(['ubicacion', 'ubicacion_interna', 'planta']);

    final celdaAMarca = pick(['celda_a_marca', 'marca_celda'], marcaInd);
    final celdaAModelo = pick(['celda_a_modelo', 'modelo_celda'], modeloInd);
    final celdaACap = pick(['celda_a_capacidad', 'capacidad_celda'], capMax);
    final celdaACant = pick(['celda_a_cantidad'], '$n');
    final mixtas = rvData['celdas_mixtas'] == true || rvData['celdas_mixtas'] == 1;
    final celdaBMarca = pick(['celda_b_marca']);
    final celdaBModelo = pick(['celda_b_modelo']);
    final celdaBCap = pick(['celda_b_capacidad']);
    final celdaBCant = pick(['celda_b_cantidad']);

    final fechaStr = pick(['fecha', 'fecha_servicio'], DateTime.now().toIso8601String().substring(0, 10));
    final obsTxt = pick(['observaciones', 'observaciones_tecnico']);
    final tecnicoRaw = pick(['tecnico_nombre', 'tecnico']);
    final tecnicoTxt = ['sin asignar', 'none', 'null'].contains(tecnicoRaw.toLowerCase()) ? '' : tecnicoRaw;
    final recRaw = pick(['firma_cliente_nombre', 'nombre_quien_recibe', 'nombre_receptor', 'nombre_ing']);
    final recTxt = (recRaw.toLowerCase() == clienteVal.toLowerCase()) ? '' : recRaw;

    pw.Widget buildLabeledLine(String label, String val) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('$label:', style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold, color: grayDk)),
            pw.SizedBox(height: 1),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.only(bottom: 1.5),
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(color: grayMed, width: 0.5)),
              ),
              child: pw.Text(
                val.isNotEmpty ? val : ' ',
                style: const pw.TextStyle(fontSize: 7.5, color: _black),
              ),
            ),
          ],
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(20, 15, 20, 15),
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // ── ENCABEZADO OFICIAL ─────────────────────────────────────────
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 95,
                    height: 32,
                    child: logoPesa != null
                        ? pw.Image(logoPesa, fit: pw.BoxFit.contain)
                        : pw.Container(
                            color: redRe,
                            child: pw.Center(
                              child: pw.Text('BASCULAS PESA',
                                  style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                            ),
                          ),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text('FICHA TECNICA DIAGNOSTICA',
                            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _black)),
                        pw.SizedBox(height: 2),
                        pw.Text('REVISION DE CELDAS DE CARGA Y BASCULA',
                            style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: grayDk)),
                        pw.SizedBox(height: 1),
                        pw.Text('PESAJE SISTEMAS Y AUTOMATIZACION',
                            style: const pw.TextStyle(fontSize: 6.5, color: grayDk)),
                      ],
                    ),
                  ),
                  pw.SizedBox(
                    width: 110,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                      children: [
                        pw.SizedBox(
                          height: 18,
                          child: logoRl != null
                              ? pw.Image(logoRl, fit: pw.BoxFit.contain)
                              : pw.Center(
                                  child: pw.Text('RICE LAKE',
                                      style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                                ),
                        ),
                        pw.SizedBox(height: 3),
                        pw.Container(
                          height: 28,
                          decoration: pw.BoxDecoration(
                            border: pw.Border.all(color: redRe, width: 1.5),
                          ),
                          child: pw.Column(
                            children: [
                              pw.Container(
                                height: 11,
                                width: double.infinity,
                                color: redRe,
                                child: pw.Center(
                                  child: pw.Text('FOLIO / RE',
                                      style: pw.TextStyle(color: _white, fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
                                ),
                              ),
                              pw.Expanded(
                                child: pw.Center(
                                  child: pw.Text(folio,
                                      style: pw.TextStyle(color: redRe, fontSize: 11, fontWeight: pw.FontWeight.bold)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                children: [
                  pw.Text('FECHA: ', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _black)),
                  pw.Container(
                    width: 150,
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(bottom: pw.BorderSide(color: _black, width: 0.6)),
                    ),
                    child: pw.Text(fechaStr, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),

              // ── SECCIÓN 1: DATOS DEL CLIENTE ───────────────────────────────
              buildSectionBar(1, 'DATOS DEL CLIENTE'),
              buildLabeledLine('RAZON SOCIAL / CLIENTE', clienteVal),
              buildLabeledLine('DIRECCION COMPLETA', direccionVal),

              // ── SECCIÓN 2: DATOS DEL EQUIPO / INDICADOR ────────────────────
              buildSectionBar(2, 'DATOS DEL EQUIPO / INDICADOR'),
              pw.Row(
                children: [
                  pw.Expanded(flex: 23, child: buildLabeledLine('MARCA INDICADOR', marcaInd)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(flex: 27, child: buildLabeledLine('MODELO INDICADOR', modeloInd)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(flex: 25, child: buildLabeledLine('No. DE SERIE', serieInd)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(flex: 25, child: buildLabeledLine('ID INDICADOR', idInd)),
                ],
              ),
              pw.Row(
                children: [
                  pw.Expanded(flex: 25, child: buildLabeledLine('CAPACIDAD MAX.', capMax)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(flex: 25, child: buildLabeledLine('DIVISION MIN. (d)', divMin)),
                  pw.SizedBox(width: 6),
                  pw.Expanded(flex: 50, child: buildLabeledLine('UBICACION', ubicacion)),
                ],
              ),
              pw.SizedBox(height: 2),
              // Subtabla CELDAS DE CARGA
              pw.Container(
                height: 13,
                color: grayHdr,
                padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('CELDAS DE CARGA',
                        style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                    pw.Text(mixtas ? 'ARREGLO MIXTO (A + B)' : 'HOMOGENEO',
                        style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
              pw.Container(
                height: 11,
                color: darkHdr,
                child: pw.Row(
                  children: [
                    pw.Expanded(flex: 10, child: pw.Center(child: pw.Text('TIPO', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))),
                    pw.Expanded(flex: 26, child: pw.Center(child: pw.Text('MARCA', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))),
                    pw.Expanded(flex: 30, child: pw.Center(child: pw.Text('MODELO', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))),
                    pw.Expanded(flex: 20, child: pw.Center(child: pw.Text('CAPACIDAD INDIV.', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))),
                    pw.Expanded(flex: 14, child: pw.Center(child: pw.Text('CANTIDAD', style: pw.TextStyle(color: _white, fontSize: 6, fontWeight: pw.FontWeight.bold)))),
                  ],
                ),
              ),
              pw.Container(
                height: 12,
                decoration: pw.BoxDecoration(
                  color: _white,
                  border: pw.Border.all(color: grayMed, width: 0.3),
                ),
                child: pw.Row(
                  children: [
                    pw.Expanded(flex: 10, child: pw.Center(child: pw.Text(mixtas ? 'Tipo A' : 'Unico', style: const pw.TextStyle(fontSize: 6.8)))),
                    pw.Expanded(flex: 26, child: pw.Center(child: pw.Text(celdaAMarca.isNotEmpty ? celdaAMarca : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                    pw.Expanded(flex: 30, child: pw.Center(child: pw.Text(celdaAModelo.isNotEmpty ? celdaAModelo : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                    pw.Expanded(flex: 20, child: pw.Center(child: pw.Text(celdaACap.isNotEmpty ? celdaACap : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                    pw.Expanded(flex: 14, child: pw.Center(child: pw.Text(celdaACant, style: pw.TextStyle(fontSize: 6.8, fontWeight: pw.FontWeight.bold)))),
                  ],
                ),
              ),
              if (mixtas)
                pw.Container(
                  height: 12,
                  decoration: pw.BoxDecoration(
                    color: grayLt,
                    border: pw.Border.all(color: grayMed, width: 0.3),
                  ),
                  child: pw.Row(
                    children: [
                      pw.Expanded(flex: 10, child: pw.Center(child: pw.Text('Tipo B', style: const pw.TextStyle(fontSize: 6.8)))),
                      pw.Expanded(flex: 26, child: pw.Center(child: pw.Text(celdaBMarca.isNotEmpty ? celdaBMarca : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                      pw.Expanded(flex: 30, child: pw.Center(child: pw.Text(celdaBModelo.isNotEmpty ? celdaBModelo : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                      pw.Expanded(flex: 20, child: pw.Center(child: pw.Text(celdaBCap.isNotEmpty ? celdaBCap : '—', style: const pw.TextStyle(fontSize: 6.8)))),
                      pw.Expanded(flex: 14, child: pw.Center(child: pw.Text(celdaBCant.isNotEmpty ? celdaBCant : '—', style: pw.TextStyle(fontSize: 6.8, fontWeight: pw.FontWeight.bold)))),
                    ],
                  ),
                ),
              // Diagrama de Estructura con Celdas de Carga
              pw.SizedBox(height: 3),
              () {
                final rawEst = pick(['tipo_estructura', 'tipo_instrumento', 'tipo_equipo'], 'PLATAFORMA').toUpperCase();
                final isCamionera = rawEst.contains('CAMION') || n >= 6;
                final isTolva = rawEst.contains('TOLVA') || rawEst.contains('TANQUE') || rawEst.contains('SILO');
                final estLabel = isCamionera
                    ? 'CAMIONERA'
                    : (isTolva ? 'TOLVA / TANQUE' : 'PLATAFORMA');
                final secCount = (int.tryParse(pick(['secciones_camionera'], '')) ?? (n ~/ 2)).clamp(2, 6);
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    pw.Container(
                      height: 11,
                      color: darkHdr,
                      padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Text(
                        'DIAGRAMA DE ESTRUCTURA — $estLabel',
                        style: pw.TextStyle(color: _white, fontSize: 6.5, fontWeight: pw.FontWeight.bold),
                      ),
                    ),
                    pw.Container(
                      height: 46,
                      decoration: pw.BoxDecoration(
                        color: grayLt,
                        border: pw.Border.all(color: grayMed, width: 0.4),
                      ),
                      child: pw.Center(
                        child: isCamionera
                            ? pw.Container(
                                width: 250,
                                height: 32,
                                decoration: pw.BoxDecoration(
                                  color: _white,
                                  border: pw.Border.all(color: darkHdr, width: 1.2),
                                ),
                                child: pw.Row(
                                  mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                                  children: List.generate(secCount, (sIdx) {
                                    return pw.Expanded(
                                      child: pw.Container(
                                        decoration: pw.BoxDecoration(
                                          border: sIdx < secCount - 1
                                              ? const pw.Border(right: pw.BorderSide(color: grayDk, width: 0.7))
                                              : null,
                                        ),
                                        child: pw.Column(
                                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                          children: [
                                            pw.Row(
                                              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                              children: [
                                                pw.Container(
                                                  width: 9,
                                                  height: 9,
                                                  color: redRe,
                                                  child: pw.Center(
                                                    child: pw.Text('C',
                                                        style: pw.TextStyle(
                                                            color: _white, fontSize: 5, fontWeight: pw.FontWeight.bold)),
                                                  ),
                                                ),
                                                if (sIdx == secCount - 1)
                                                  pw.Container(
                                                    width: 9,
                                                    height: 9,
                                                    color: redRe,
                                                    child: pw.Center(
                                                      child: pw.Text('C',
                                                          style: pw.TextStyle(
                                                              color: _white, fontSize: 5, fontWeight: pw.FontWeight.bold)),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            pw.Text('Sec ${sIdx + 1}', style: const pw.TextStyle(fontSize: 6, color: darkHdr)),
                                            pw.Row(
                                              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                              children: [
                                                pw.Container(
                                                  width: 9,
                                                  height: 9,
                                                  color: redRe,
                                                  child: pw.Center(
                                                    child: pw.Text('C',
                                                        style: pw.TextStyle(
                                                            color: _white, fontSize: 5, fontWeight: pw.FontWeight.bold)),
                                                  ),
                                                ),
                                                if (sIdx == secCount - 1)
                                                  pw.Container(
                                                    width: 9,
                                                    height: 9,
                                                    color: redRe,
                                                    child: pw.Center(
                                                      child: pw.Text('C',
                                                          style: pw.TextStyle(
                                                              color: _white, fontSize: 5, fontWeight: pw.FontWeight.bold)),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              )
                            : pw.Container(
                                width: 92,
                                height: 34,
                                decoration: pw.BoxDecoration(
                                  color: _white,
                                  border: pw.Border.all(color: darkHdr, width: 1.2),
                                ),
                                child: pw.Column(
                                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                  children: [
                                    pw.Row(
                                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                      children: [
                                        pw.Container(
                                          width: 10,
                                          height: 10,
                                          decoration: pw.BoxDecoration(
                                            color: const PdfColor.fromInt(0xFFFEE2E2),
                                            border: pw.Border.all(color: redRe, width: 0.8),
                                          ),
                                          child: pw.Center(
                                            child: pw.Text('C',
                                                style: pw.TextStyle(
                                                    color: redRe, fontSize: 5.5, fontWeight: pw.FontWeight.bold)),
                                          ),
                                        ),
                                        pw.Container(
                                          width: 10,
                                          height: 10,
                                          decoration: pw.BoxDecoration(
                                            color: const PdfColor.fromInt(0xFFFEE2E2),
                                            border: pw.Border.all(color: redRe, width: 0.8),
                                          ),
                                          child: pw.Center(
                                            child: pw.Text('C',
                                                style: pw.TextStyle(
                                                    color: redRe, fontSize: 5.5, fontWeight: pw.FontWeight.bold)),
                                          ),
                                        ),
                                      ],
                                    ),
                                    pw.Text(estLabel, style: const pw.TextStyle(fontSize: 6.2, color: darkHdr)),
                                    pw.Row(
                                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                      children: [
                                        pw.Container(
                                          width: 10,
                                          height: 10,
                                          decoration: pw.BoxDecoration(
                                            color: const PdfColor.fromInt(0xFFFEE2E2),
                                            border: pw.Border.all(color: redRe, width: 0.8),
                                          ),
                                          child: pw.Center(
                                            child: pw.Text('C',
                                                style: pw.TextStyle(
                                                    color: redRe, fontSize: 5.5, fontWeight: pw.FontWeight.bold)),
                                          ),
                                        ),
                                        pw.Container(
                                          width: 10,
                                          height: 10,
                                          decoration: pw.BoxDecoration(
                                            color: const PdfColor.fromInt(0xFFFEE2E2),
                                            border: pw.Border.all(color: redRe, width: 0.8),
                                          ),
                                          child: pw.Center(
                                            child: pw.Text('C',
                                                style: pw.TextStyle(
                                                    color: redRe, fontSize: 5.5, fontWeight: pw.FontWeight.bold)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              }(),

              // ── SECCIÓN 3: LECTURAS SIN CARGA — N CELDAS (OHMS / MV) ───────
              buildSectionBar(3, 'LECTURAS SIN CARGA — $n CELDA${n > 1 ? 'S' : ''}  (OHMS / MV)'),
              pw.Container(
                height: 13,
                color: darkHdr,
                child: pw.Row(
                  children: [
                    pw.SizedBox(
                      width: 118,
                      child: pw.Padding(
                        padding: const pw.EdgeInsets.only(left: 4),
                        child: pw.Align(
                          alignment: pw.Alignment.centerLeft,
                          child: pw.Text('PARAMETRO ELECTRICO',
                              style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                        ),
                      ),
                    ),
                    pw.SizedBox(
                      width: 28,
                      child: pw.Center(
                        child: pw.Text('UND',
                            style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                      ),
                    ),
                    for (int cIdx = 0; cIdx < n; cIdx++)
                      pw.Expanded(
                        child: pw.Center(
                          child: pw.Text('C-${cIdx + 1}',
                              style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                        ),
                      ),
                  ],
                ),
              ),
              for (int rIdx = 0; rIdx < ohmsParamsOficiales.length; rIdx++)
                pw.Container(
                  height: 11,
                  decoration: pw.BoxDecoration(
                    color: rIdx.isEven ? grayLt : _white,
                    border: pw.Border.all(color: grayMed, width: 0.25),
                  ),
                  child: pw.Row(
                    children: [
                      pw.Container(
                        width: 118,
                        padding: const pw.EdgeInsets.only(left: 3),
                        alignment: pw.Alignment.centerLeft,
                        decoration: const pw.BoxDecoration(
                          border: pw.Border(right: pw.BorderSide(color: grayMed, width: 0.25)),
                        ),
                        child: pw.Text(ohmsParamsOficiales[rIdx][1],
                            style: const pw.TextStyle(fontSize: 6.5, color: _black)),
                      ),
                      pw.Container(
                        width: 28,
                        alignment: pw.Alignment.center,
                        decoration: const pw.BoxDecoration(
                          border: pw.Border(right: pw.BorderSide(color: grayMed, width: 0.25)),
                        ),
                        child: pw.Text(ohmsParamsOficiales[rIdx][2],
                            style: pw.TextStyle(fontSize: 6.3, fontWeight: pw.FontWeight.bold, color: grayDk)),
                      ),
                      for (int cIdx = 0; cIdx < n; cIdx++)
                        pw.Expanded(
                          child: pw.Container(
                            alignment: pw.Alignment.center,
                            decoration: const pw.BoxDecoration(
                              border: pw.Border(right: pw.BorderSide(color: grayMed, width: 0.25)),
                            ),
                            child: () {
                              final v = (rIdx < lecturasOhms.length && cIdx < lecturasOhms[rIdx].length)
                                  ? lecturasOhms[rIdx][cIdx].trim()
                                  : '';
                              if (v.isNotEmpty) {
                                return pw.Text(v,
                                    style: pw.TextStyle(fontSize: 6.8, fontWeight: pw.FontWeight.bold, color: _black));
                              }
                              return pw.Container(
                                margin: const pw.EdgeInsets.symmetric(horizontal: 4),
                                height: 0.5,
                                color: const PdfColor.fromInt(0xFFDDDDDD),
                              );
                            }(),
                          ),
                        ),
                    ],
                  ),
                ),

              // ── SECCIÓN 4: FUNCIONALIDAD DE CELDAS E INDICADOR ─────────────
              buildSectionBar(4, 'FUNCIONALIDAD DE CELDAS E INDICADOR'),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // Columna Izquierda: INDICADOR / DISPLAY
                  pw.Expanded(
                    flex: 48,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                      children: [
                        pw.Container(
                          height: 14,
                          color: grayHdr,
                          padding: const pw.EdgeInsets.only(left: 4),
                          alignment: pw.Alignment.centerLeft,
                          child: pw.Text('INDICADOR / DISPLAY',
                              style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                        ),
                        for (int i = 0; i < maxFuncRows; i++)
                          if (i < indItems.length)
                            pw.Container(
                              height: funcRowH,
                              padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                              decoration: pw.BoxDecoration(
                                color: i.isEven ? const PdfColor.fromInt(0xFFF8F9FA) : _white,
                                border: pw.Border.all(color: grayMed, width: 0.25),
                              ),
                              child: pw.Row(
                                children: [
                                  buildCheckbox(funcIndicador[indItems[i]] == true),
                                  pw.SizedBox(width: 5),
                                  pw.Text(indItems[i], style: const pw.TextStyle(fontSize: 6.5, color: _black)),
                                ],
                              ),
                            )
                          else
                            pw.SizedBox(height: funcRowH),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 8),
                  // Columna Derecha: ESTADO INDIVIDUAL DE CELDAS
                  pw.Expanded(
                    flex: 52,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                      children: [
                        pw.Container(
                          height: 14,
                          color: grayHdr,
                          padding: const pw.EdgeInsets.only(left: 4),
                          alignment: pw.Alignment.centerLeft,
                          child: pw.Text('ESTADO INDIVIDUAL DE CELDAS',
                              style: pw.TextStyle(color: _white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                        ),
                        for (int i = 0; i < maxFuncRows; i++)
                          if (i < n)
                            pw.Container(
                              height: funcRowH,
                              padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                              decoration: pw.BoxDecoration(
                                color: i.isEven ? const PdfColor.fromInt(0xFFF8F9FA) : _white,
                                border: pw.Border.all(color: grayMed, width: 0.25),
                              ),
                              child: pw.Row(
                                children: [
                                  pw.SizedBox(
                                    width: 42,
                                    child: pw.Text('Celda ${i + 1}:',
                                        style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _black)),
                                  ),
                                  buildCheckbox(i < estadoCeldas.length && estadoCeldas[i].toUpperCase() == 'OK'),
                                  pw.SizedBox(width: 3),
                                  pw.Text('OK', style: const pw.TextStyle(fontSize: 6.5, color: _black)),
                                  pw.SizedBox(width: 14),
                                  buildCheckbox(i < estadoCeldas.length && estadoCeldas[i].toUpperCase() == 'FALLA'),
                                  pw.SizedBox(width: 3),
                                  pw.Text('Falla', style: const pw.TextStyle(fontSize: 6.5, color: _black)),
                                ],
                              ),
                            )
                          else
                            pw.SizedBox(height: funcRowH),
                      ],
                    ),
                  ),
                ],
              ),
              // Barra inferior Cables y Conectores
              pw.Container(
                height: 13,
                padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                decoration: pw.BoxDecoration(
                  color: const PdfColor.fromInt(0xFFF8F9FA),
                  border: pw.Border.all(color: grayMed, width: 0.25),
                ),
                child: pw.Row(
                  children: [
                    pw.Text('Cables:', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _black)),
                    pw.SizedBox(width: 8),
                    buildCheckbox(estadoCables.toUpperCase() == 'OK'),
                    pw.SizedBox(width: 3),
                    pw.Text('OK', style: const pw.TextStyle(fontSize: 6.5)),
                    pw.SizedBox(width: 10),
                    buildCheckbox(estadoCables.toUpperCase() == 'FALLA'),
                    pw.SizedBox(width: 3),
                    pw.Text('Falla', style: const pw.TextStyle(fontSize: 6.5)),
                    pw.SizedBox(width: 32),
                    pw.Text('Conectores:', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _black)),
                    pw.SizedBox(width: 8),
                    buildCheckbox(estadoConectores.toUpperCase() == 'OK'),
                    pw.SizedBox(width: 3),
                    pw.Text('OK', style: const pw.TextStyle(fontSize: 6.5)),
                    pw.SizedBox(width: 10),
                    buildCheckbox(estadoConectores.toUpperCase() == 'FALLA'),
                    pw.SizedBox(width: 3),
                    pw.Text('Falla', style: const pw.TextStyle(fontSize: 6.5)),
                  ],
                ),
              ),

              // ── SECCIÓN 5: OBSERVACIONES Y FIRMAS ──────────────────────────
              buildSectionBar(5, 'OBSERVACIONES Y FIRMAS'),
              () {
                final String obsTexto = obsTxt.trim();
                final double obsFontSize = obsTexto.length > 350
                    ? 6.8
                    : (obsTexto.length > 200 ? 7.5 : 8.5);
                return pw.Container(
                  width: double.infinity,
                  constraints: const pw.BoxConstraints(minHeight: 38),
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: pw.BoxDecoration(
                    color: grayLt,
                    border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('OBSERVACIONES:',
                          style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold, color: grayDk)),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        obsTexto.isEmpty ? 'Sin observaciones adicionales.' : obsTexto,
                        style: pw.TextStyle(
                          fontSize: obsFontSize,
                          lineSpacing: 1.5,
                          color: _black,
                        ),
                        softWrap: true,
                        textAlign: pw.TextAlign.left,
                      ),
                    ],
                  ),
                );
              }(),
              pw.SizedBox(height: 6),
              pw.Row(
                children: [
                  pw.Expanded(
                    child: _firmaBox('TECNICO RESPONSABLE', tecnicoTxt, firmaTecImg),
                  ),
                  pw.SizedBox(width: 36),
                  pw.Expanded(
                    child: _firmaBox('FIRMA CLIENTE', recTxt, firmaCliImg),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS (OSOB-26-XXX)
  // ══════════════════════════════════════════════════════════════════════════

  Future<String> generarPdfObservacionesBascula({
    required Map<String, dynamic> osData,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final String fechaEjecucionHoy = DateTime.now().toIso8601String().substring(0, 10);
    osData['fecha_creacion_logistica'] ??= osData['fecha'];
    osData['fecha'] = fechaEjecucionHoy;
    osData['fecha_servicio'] = fechaEjecucionHoy;
    osData['fecha_cierre'] ??= DateTime.now().toIso8601String();

    final bytes = await buildPdfObservacionesBasculaBytes(
      osData: osData,
      firmaTecBase64: firmaTecBase64,
      firmaCliBase64: firmaCliBase64,
    );

    final dir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${dir.path}/pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }
    final folio = _s(osData, 'folio_os', _s(osData, 'folio', 'OSOB-26-001')).trim();
    final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName = '$safeFolio.pdf';
    final filePath = '${pdfDir.path}/$fileName';
    await _writeAtomic(File(filePath), bytes);

    try {
      final legacyDir = Directory('${dir.path}/Pesa_PDFs');
      if (!await legacyDir.exists()) await legacyDir.create(recursive: true);
      await _writeAtomic(File('${legacyDir.path}/$fileName'), bytes);
    } catch (_) {}

    return filePath;
  }

  Future<Uint8List> buildPdfObservacionesBasculaBytes({
    required Map<String, dynamic> osData,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final folio = _s(osData, 'folio_os', _s(osData, 'folio', 'OSOB-26-001'));
    final doc = pw.Document(
      title: 'FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS - $folio',
      author: 'Servicios PESA',
      subject: 'Formato de Inspección y Revisión de Básculas (OSOB)',
      creator: 'PESA Tablet App v3',
    );

    pw.ImageProvider? logoPesa;
    pw.ImageProvider? logoRl;
    for (final p in ['Img/logo_pesa.png', 'assets/logo_pesa.png']) {
      try {
        final b = await rootBundle.load(p);
        logoPesa = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }
    for (final p in ['Img/RiceLake.png', 'assets/RiceLake.png']) {
      try {
        final b = await rootBundle.load(p);
        logoRl = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }

    pw.ImageProvider? firmaTecImg;
    pw.ImageProvider? firmaCliImg;
    final rawTec = firmaTecBase64 ?? _s(osData, 'firma_tecnico', _s(osData, 'firma_tecnico_b64', ''));
    final rawCli = firmaCliBase64 ?? _s(osData, 'firma_cliente', _s(osData, 'firma_receptor_b64', ''));
    if (rawTec.isNotEmpty) {
      try {
        final clean = rawTec.contains(',') ? rawTec.split(',').last : rawTec;
        firmaTecImg = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }
    if (rawCli.isNotEmpty) {
      try {
        final clean = rawCli.contains(',') ? rawCli.split(',').last : rawCli;
        firmaCliImg = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }

    // Fecha de finalización en formato DD / MM / 2026
    String fechaRaw = _s(osData, 'fecha', _s(osData, 'fecha_servicio', ''));
    String fechaFmt = '';
    if (fechaRaw.length >= 10 && fechaRaw.contains('-')) {
      final parts = fechaRaw.substring(0, 10).split('-');
      if (parts.length == 3) {
        fechaFmt = '${parts[2]} / ${parts[1]} / ${parts[0]}';
      }
    }
    if (fechaFmt.isEmpty) {
      final now = DateTime.now();
      fechaFmt = '${now.day.toString().padLeft(2, '0')} / ${now.month.toString().padLeft(2, '0')} / ${now.year}';
    }

    final ordenServicioRef = _s(osData, 'orden_servicio_ref', _s(osData, 'orden_servicio', '_______________'));

    // Datos Sección 1
    final cliente = _s(osData, 'cliente', _s(osData, 'razon_social', ''));
    final planta = _s(osData, 'ubicacion', _s(osData, 'sucursal', _s(osData, 'direccion', '')));
    final idTag = _s(osData, 'id_equipo', _s(osData, 'id_indicador', _s(osData, 'indicador_id', '')));
    final marca = _s(osData, 'marca', _s(osData, 'equipo_marca', ''));
    final modelo = _s(osData, 'modelo', _s(osData, 'equipo_modelo', ''));
    final serie = _s(osData, 'serie', _s(osData, 'ns', _s(osData, 'numero_serie', '')));
    final capMax = formatoMilesEspacio(_s(osData, 'capacidad_maxima', _s(osData, 'alcance_max', _s(osData, 'cap_maxima', ''))));
    final divMin = formatoMilesEspacio(_s(osData, 'division_minima', _s(osData, 'div_minima', '')));
    final tipoInst = _s(osData, 'tipo_instrumento', '').toLowerCase();
    final tipoInstOtro = _s(osData, 'tipo_instrumento_otro', '');

    final isMesa = tipoInst.contains('mesa') || tipoInst.contains('mostrador') || tipoInst.contains('banco');
    final isCam = tipoInst.contains('camion');
    final isColg = tipoInst.contains('colg') || tipoInst.contains('grua') || tipoInst.contains('grúa');
    final isTolva = tipoInst.contains('tolva');
    final isTanque = tipoInst.contains('tanque') || tipoInst.contains('silo');
    final isOtro = tipoInstOutroCheck(tipoInst, tipoInstOtro, isMesa, isCam, isColg, isTolva, isTanque);
    final txtOtro = tipoInstOtro.isNotEmpty
        ? tipoInstOtro
        : (isOtro && !tipoInst.contains('otro') ? _s(osData, 'tipo_instrumento', '') : '_________________');

    // Datos Sección 2 (Checklist 1..14)
    final Map<String, dynamic> checklistRaw = (osData['checklist_inspeccion'] is Map)
        ? Map<String, dynamic>.from(osData['checklist_inspeccion'] as Map)
        : {};

    String chkEst(int idx) {
      final item = checklistRaw['$idx'] ?? checklistRaw[idx];
      if (item is Map) return (item['estado'] ?? '').toString().trim().toUpperCase();
      return _s(osData, 'chk_${idx}_estado', '').toUpperCase();
    }

    String chkObs(int idx) {
      final item = checklistRaw['$idx'] ?? checklistRaw[idx];
      if (item is Map) return (item['observaciones'] ?? '').toString().trim();
      return _s(osData, 'chk_${idx}_obs', '');
    }

    // Datos Sección 3 (Pruebas Rápidas)
    final Map<String, dynamic> pruebasRaw = (osData['pruebas_rapidas'] is Map)
        ? Map<String, dynamic>.from(osData['pruebas_rapidas'] as Map)
        : {};

    Map<String, dynamic> prMap(String key) {
      final v = pruebasRaw[key];
      if (v is Map) return Map<String, dynamic>.from(v);
      return {};
    }

    // Datos Sección 4 (Diagnóstico General, Observaciones y Refacciones)
    final String obsTecnicas = _s(osData, 'observaciones', _s(osData, 'observaciones_tecnicas', ''));
    final String refaccionesTxt = _s(osData, 'refacciones_requeridas', _s(osData, 'refacciones_adicionales', ''));

    final dynamic accRaw = osData['acciones_realizadas'];
    bool hasAccion(String key, String keyword) {
      if (accRaw is Map) {
        final v = accRaw[key];
        if (v != null) return v == true || v.toString().toLowerCase() == 'true' || v.toString() == '1';
      } else if (accRaw is List) {
        return accRaw.any((e) => e.toString().toLowerCase().contains(keyword) || e.toString().toLowerCase() == key);
      } else if (accRaw is String) {
        return accRaw.toLowerCase().contains(keyword) || accRaw.toLowerCase().contains(key);
      }
      return false;
    }

    final accLimp = hasAccion('limpieza', 'limpieza');
    final accNiv = hasAccion('nivelacion', 'nivelac');
    final accAj = hasAccion('ajuste_peso', 'ajuste');
    final accElec = hasAccion('revision_electrica', 'eléctric') || hasAccion('revision_electrica', 'electric');

    final dictamenUp = _s(osData, 'dictamen_estado', _s(osData, 'dictamen', '')).toUpperCase();
    final isOpObs = dictamenUp.contains('OBSERVACION');
    final isFuera = dictamenUp.contains('FUERA') || dictamenUp == 'NO APTO';
    final isOp = !isOpObs && !isFuera && (dictamenUp.contains('OPERATIVO') || dictamenUp == 'APTO');

    // Datos Sección 5 (Firmas)
    final tecNombre = _s(osData, 'tecnico', _s(osData, 'tecnico_nombre', ''));
    final tecPuesto = _s(osData, 'puesto_tecnico', 'Técnico de Servicio');
    final cliNombre = _s(osData, 'nombre_receptor', _s(osData, 'firma_cliente_nombre', _s(osData, 'nombre_ing', '')));
    final cliPuesto = _s(osData, 'puesto_receptor', _s(osData, 'area_puesto_cliente', _s(osData, 'puesto_ing', '')));

    pw.Widget secHeader(String title) => pw.Container(
          width: double.infinity,
          color: _dark,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          child: pw.Text(
            title,
            style: pw.TextStyle(color: _white, fontSize: 7.2, fontWeight: pw.FontWeight.bold),
          ),
        );

    pw.Widget subCatHeader(String title) => pw.Container(
          width: double.infinity,
          color: const PdfColor.fromInt(0xFFEAEAEA),
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 1.8),
          child: pw.Text(
            title,
            style: pw.TextStyle(color: _red, fontSize: 6.5, fontWeight: pw.FontWeight.bold),
          ),
        );

    String markBox(bool active, [String inner = 'X']) {
      if (inner == 'X') return active ? '[ X ]' : '[   ]';
      return active ? '[X $inner]' : '[ $inner ]';
    }

    pw.Widget buildChecklistRow(int num, String label) {
      final est = chkEst(num);
      final obs = chkObs(num);
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
        decoration: pw.BoxDecoration(
          color: num.isEven ? const PdfColor.fromInt(0xFFF9FAFB) : _white,
          border: pw.Border(
            bottom: const pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            left: const pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            right: const pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
          ),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              flex: 52,
              child: pw.Text(
                '$num. $label',
                style: const pw.TextStyle(fontSize: 5.8, color: _black),
              ),
            ),
            pw.SizedBox(
              width: 112,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(markBox(est == 'B', 'B'),
                      style: pw.TextStyle(fontSize: 5.6, fontWeight: est == 'B' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'B' ? _redBright : _black)),
                  pw.Text(markBox(est == 'R', 'R'),
                      style: pw.TextStyle(fontSize: 5.6, fontWeight: est == 'R' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'R' ? _redBright : _black)),
                  pw.Text(markBox(est == 'M', 'M'),
                      style: pw.TextStyle(fontSize: 5.6, fontWeight: est == 'M' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'M' ? _redBright : _black)),
                  pw.Text(markBox(est == 'N/A' || est == 'NA', 'N/A'),
                      style: pw.TextStyle(fontSize: 5.6, fontWeight: (est == 'N/A' || est == 'NA') ? pw.FontWeight.bold : pw.FontWeight.normal, color: (est == 'N/A' || est == 'NA') ? _redBright : _black)),
                ],
              ),
            ),
            pw.SizedBox(width: 4),
            pw.Expanded(
              flex: 28,
              child: pw.Text(
                '| Observaciones: ${obs.isNotEmpty ? obs : "_________________"}',
                style: const pw.TextStyle(fontSize: 5.6, color: _grayD),
              ),
            ),
          ],
        ),
      );
    }

    pw.Widget buildPruebaRow({
      required String label,
      required String key,
      required String extraLabel,
      required String extraKey,
      bool isExactitud = false,
    }) {
      final m = prMap(key);
      final est = (m['estado'] ?? _s(osData, '${key}_estado', '')).toString().toUpperCase();
      final cumple = est == 'CUMPLE' || est == 'SI' || est == 'SÍ' || est == 'OK';
      final noCumple = est == 'NO CUMPLE' || est == 'NO' || est == 'FALLA';
      final extraVal = (m[extraKey] ?? _s(osData, '${key}_$extraKey', '')).toString().trim();

      String rightText;
      if (isExactitud) {
        final reqUp = extraVal.toUpperCase();
        final reqSi = reqUp == 'SI' || reqUp == 'SÍ' || reqUp == 'TRUE' || reqUp == '1';
        final reqNo = reqUp == 'NO' || reqUp == 'FALSE' || reqUp == '0';
        rightText = '| Requiere ajuste: ${markBox(reqSi)} Sí   ${markBox(reqNo)} No';
      } else {
        rightText = '| $extraLabel: ${extraVal.isNotEmpty ? extraVal : "_________________"}';
      }

      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            left: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            right: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
          ),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(
              flex: 36,
              child: pw.Text('- $label:', style: pw.TextStyle(fontSize: 6.0, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(
              width: 118,
              child: pw.Text(
                '${markBox(cumple)} Cumple   ${markBox(noCumple)} No cumple',
                style: const pw.TextStyle(fontSize: 5.8),
              ),
            ),
            pw.Expanded(
              flex: 38,
              child: pw.Text(rightText, style: const pw.TextStyle(fontSize: 5.8, color: _grayD)),
            ),
          ],
        ),
      );
    }

    pw.Widget buildAdaptiveMultilineBox(String label, String rawText) {
      final String obsTexto = rawText.trim();
      final double obsFontSize = obsTexto.length > 350
          ? 6.8
          : (obsTexto.length > 200 ? 7.5 : 8.5);
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold, color: _black),
          ),
          pw.SizedBox(height: 1.5),
          pw.Container(
            width: double.infinity,
            constraints: const pw.BoxConstraints(minHeight: 38),
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
            ),
            child: pw.Text(
              obsTexto.isEmpty ? 'Sin observaciones adicionales.' : obsTexto,
              style: pw.TextStyle(
                fontSize: obsFontSize,
                lineSpacing: 1.5,
              ),
              softWrap: true,
              textAlign: pw.TextAlign.left,
            ),
          ),
        ],
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(22, 14, 22, 14),
        build: (ctx) => [
          // Cabecera con logos y título oficial
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              _logoBox(logoPesa, 'BP BÁSCULAS PESA', 95, 28),
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      'FORMATO DE INSPECCIÓN Y REVISIÓN DE BÁSCULAS',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: _red),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Folio: $folio | Fecha: $fechaFmt | Orden de Servicio: ${ordenServicioRef.isEmpty ? "_______________" : ordenServicioRef}',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 7.2, fontWeight: pw.FontWeight.bold, color: _dark),
                    ),
                  ],
                ),
              ),
              _logoBox(logoRl, 'RICE LAKE', 85, 28),
            ],
          ),
          pw.SizedBox(height: 4),

          // ── SECCIÓN 1. Datos del Cliente y del Equipo ─────────────────────
          secHeader('SECCIÓN 1. Datos del Cliente y del Equipo'),
          pw.Container(
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(children: [
                  pw.Expanded(child: pw.Text('Cliente / Empresa: $cliente', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text('Planta / Ubicación: $planta', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold))),
                ]),
                pw.SizedBox(height: 2),
                pw.Row(children: [
                  pw.Expanded(child: pw.Text('ID Interno / Tag: $idTag', style: const pw.TextStyle(fontSize: 6.3))),
                  pw.Expanded(child: pw.Text('Marca: $marca', style: const pw.TextStyle(fontSize: 6.3))),
                  pw.Expanded(child: pw.Text('Modelo: $modelo', style: const pw.TextStyle(fontSize: 6.3))),
                  pw.Expanded(child: pw.Text('Número de Serie: $serie', style: const pw.TextStyle(fontSize: 6.3))),
                ]),
                pw.SizedBox(height: 2),
                pw.Row(children: [
                  pw.Expanded(child: pw.Text('Capacidad Máx. (Max): $capMax', style: const pw.TextStyle(fontSize: 6.3))),
                  pw.Expanded(child: pw.Text('División Mínima (d / e): $divMin', style: const pw.TextStyle(fontSize: 6.3))),
                ]),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Tipo de Instrumento:  ${markBox(isMesa)} Mesa   ${markBox(isCam)} Camionera   ${markBox(isColg)} Colgante   ${markBox(isTolva)} Tolva   ${markBox(isTanque)} Tanque   ${markBox(isOtro)} Otro (especifique): $txtOtro',
                  style: const pw.TextStyle(fontSize: 6.2),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 3),

          // ── SECCIÓN 2. Checklist de Inspección Física y Mecánica ──────────
          secHeader('SECCIÓN 2. Checklist de Inspección Física y Mecánica'),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            color: const PdfColor.fromInt(0xFFF5F5F7),
            child: pw.Text(
              'Instrucción: Marcar con una "X" el estado actual de cada componente (B = Bueno / Operativo, R = Regular / Requiere ajuste o limpieza, M = Malo / Requiere reemplazo, N/A = No aplica).',
              style: pw.TextStyle(fontSize: 5.7, fontStyle: pw.FontStyle.italic, color: _grayD),
            ),
          ),
          subCatHeader('A) Estructura y Receptor de Carga'),
          buildChecklistRow(1, 'Charola / Plato / Cubierta (Sin golpes, deformaciones ni corrosión)'),
          buildChecklistRow(2, 'Estructura inferior / Chasis (Soldaduras íntegras, sin fracturas ni óxido severo)'),
          buildChecklistRow(3, 'Patas niveladoras (Completas, roscas en buen estado, gomas antiderrapantes firmes)'),
          buildChecklistRow(4, 'Nivelación - Gota / Burbuja (Burbuja centrada y nivel visible sin daños)'),
          buildChecklistRow(5, 'Topes de sobrecarga y laterales (Con holgura adecuada, sin rozamiento ni obstrucciones)'),
          buildChecklistRow(6, 'Limpieza general (Libre de residuos, polvo acumulado, humedad o fauna nociva bajo el plato)'),
          subCatHeader('B) Celdas y Transmisión'),
          buildChecklistRow(7, 'Celda(s) de carga (Sin golpes visibles, corrosión, humedad ni deformación)'),
          buildChecklistRow(8, 'Cableado y blindaje (Sin cortes, empalmes improvisados ni aplastamiento; prensaestopas firmes)'),
          buildChecklistRow(9, 'Caja suma (Sellada herméticamente, sin sulfatación en bornes ni humedad)'),
          subCatHeader('C) Indicador y Electrónica'),
          buildChecklistRow(10, 'Carcasa y soporte / columna (Fijación firme, sellos en buen estado)'),
          buildChecklistRow(11, 'Display / Pantalla (Segmentos o píxeles completos, retroiluminación funcional)'),
          buildChecklistRow(12, 'Teclado / Botonera (Membrana íntegra sin perforaciones, respuesta táctil correcta)'),
          buildChecklistRow(13, 'Alimentación / Batería (Cable de poder/eliminador sin daños; retención de carga en batería)'),
          buildChecklistRow(14, 'Puertos de comunicación (RS-232 / USB / Ethernet / Wi-Fi operando correctamente)'),
          pw.SizedBox(height: 3),

          // ── SECCIÓN 3. Pruebas Rápidas de Funcionamiento ──────────────────
          secHeader('SECCIÓN 3. Pruebas Rápidas de Funcionamiento'),
          buildPruebaRow(label: 'Estabilidad de Cero al encendido', key: 'estabilidad_cero', extraLabel: 'Comentarios', extraKey: 'comentarios'),
          buildPruebaRow(label: 'Retorno a Cero tras descarga', key: 'retorno_cero', extraLabel: 'Comentarios', extraKey: 'comentarios'),
          buildPruebaRow(label: 'Prueba de Excentricidad (Esquinas)', key: 'excentricidad', extraLabel: 'Dif. máx. detectada', extraKey: 'dif_max'),
          buildPruebaRow(label: 'Repetibilidad de lectura', key: 'repetibilidad', extraLabel: 'Carga de prueba', extraKey: 'carga_prueba'),
          buildPruebaRow(label: 'Exactitud preliminar de pesaje', key: 'exactitud', extraLabel: 'Requiere ajuste', extraKey: 'requiere_ajuste', isExactitud: true),
          pw.SizedBox(height: 3),

          // ── SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones ───
          secHeader('SECCIÓN 4. Diagnóstico General, Observaciones y Refacciones'),
          pw.SizedBox(height: 2),
          buildAdaptiveMultilineBox('- Observaciones técnicas y hallazgos detallados:', obsTecnicas),
          pw.SizedBox(height: 2.5),
          pw.Text('- Acciones realizadas durante la revisión:', style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1.5),
          pw.Row(children: [
            pw.Expanded(child: pw.Text('  ${markBox(accLimp)} Limpieza superficial e interna', style: const pw.TextStyle(fontSize: 5.9))),
            pw.Expanded(child: pw.Text('  ${markBox(accNiv)} Nivelación de patas y ajuste de topes', style: const pw.TextStyle(fontSize: 5.9))),
          ]),
          pw.SizedBox(height: 1),
          pw.Row(children: [
            pw.Expanded(child: pw.Text('  ${markBox(accAj)} Ajuste de peso (calibración interna / ajuste con masa patrón)', style: const pw.TextStyle(fontSize: 5.9))),
            pw.Expanded(child: pw.Text('  ${markBox(accElec)} Revisión eléctrica y reapriete de conexiones', style: const pw.TextStyle(fontSize: 5.9))),
          ]),
          pw.SizedBox(height: 2.5),
          buildAdaptiveMultilineBox('- Refacciones o servicios adicionales requeridos:', refaccionesTxt),
          pw.SizedBox(height: 2.5),
          pw.Text('- Dictamen de Estado Operativo del Equipo:', style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1),
          pw.Text('  ${markBox(isOp)} OPERATIVO (Apto para uso normal / Listo para calibración)',
              style: pw.TextStyle(fontSize: 5.9, fontWeight: isOp ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text('  ${markBox(isOpObs)} OPERATIVO CON OBSERVACIONES (Funciona, pero requiere mantenimiento preventivo/correctivo pronto)',
              style: pw.TextStyle(fontSize: 5.9, fontWeight: isOpObs ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text('  ${markBox(isFuera)} FUERA DE SERVICIO (No apto para uso hasta reparación)',
              style: pw.TextStyle(fontSize: 5.9, fontWeight: isFuera ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.SizedBox(height: 3),

          // ── SECCIÓN 5. Firmas de Conformidad ──────────────────────────────
          secHeader('SECCIÓN 5. Firmas de Conformidad'),
          pw.SizedBox(height: 3),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.6)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Realizó Revisión (Técnico)', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _red)),
                      pw.SizedBox(height: 2),
                      pw.Text('Nombre: $tecNombre', style: const pw.TextStyle(fontSize: 6.2)),
                      pw.Text('Puesto: $tecPuesto', style: const pw.TextStyle(fontSize: 6.2)),
                      pw.SizedBox(height: 2),
                      pw.SizedBox(
                        height: 32,
                        width: double.infinity,
                        child: firmaTecImg != null
                            ? pw.Center(child: pw.Image(firmaTecImg, fit: pw.BoxFit.contain))
                            : pw.SizedBox(),
                      ),
                      pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey600),
                      pw.Center(child: pw.Text('Firma', style: const pw.TextStyle(fontSize: 5.8, color: _grayD))),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(width: 14),
              pw.Expanded(
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.6)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Recibió de Conformidad (Cliente / Usuario)', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _red)),
                      pw.SizedBox(height: 2),
                      pw.Text('Nombre: $cliNombre', style: const pw.TextStyle(fontSize: 6.2)),
                      pw.Text('Área / Puesto: $cliPuesto', style: const pw.TextStyle(fontSize: 6.2)),
                      pw.SizedBox(height: 2),
                      pw.SizedBox(
                        height: 32,
                        width: double.infinity,
                        child: firmaCliImg != null
                            ? pw.Center(child: pw.Image(firmaCliImg, fit: pw.BoxFit.contain))
                            : pw.SizedBox(),
                      ),
                      pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey600),
                      pw.Center(child: pw.Text('Firma', style: const pw.TextStyle(fontSize: 5.8, color: _grayD))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }

  bool tipoInstOutroCheck(
    String tipoInst,
    String tipoInstOtro,
    bool isMesa,
    bool isCam,
    bool isColg,
    bool isTolva,
    bool isTanque,
  ) {
    if (tipoInst.contains('otro') || tipoInstOtro.isNotEmpty) return true;
    if (tipoInst.isNotEmpty && !isMesa && !isCam && !isColg && !isTolva && !isTanque) return true;
    return false;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA (OSOCC-26-001)
  // ══════════════════════════════════════════════════════════════════════════
  Future<String> generarPdfObservacionesCelda({
    required Map<String, dynamic> osData,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final String fechaEjecucionHoy = DateTime.now().toIso8601String().substring(0, 10);
    osData['fecha_creacion_logistica'] ??= osData['fecha'];
    osData['fecha'] = fechaEjecucionHoy;
    osData['fecha_servicio'] = fechaEjecucionHoy;
    osData['fecha_cierre'] ??= DateTime.now().toIso8601String();

    final bytes = await buildPdfObservacionesCeldaBytes(
      osData: osData,
      firmaTecBase64: firmaTecBase64,
      firmaCliBase64: firmaCliBase64,
    );

    final dir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${dir.path}/pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }
    final folio = _s(osData, 'folio_os', _s(osData, 'folio', 'OSOCC-26-001')).trim();
    final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final fileName = '$safeFolio.pdf';
    final filePath = '${pdfDir.path}/$fileName';
    await _writeAtomic(File(filePath), bytes);

    try {
      final legacyDir = Directory('${dir.path}/Pesa_PDFs');
      if (!await legacyDir.exists()) await legacyDir.create(recursive: true);
      await _writeAtomic(File('${legacyDir.path}/$fileName'), bytes);
    } catch (_) {}

    return filePath;
  }

  Future<Uint8List> buildPdfObservacionesCeldaBytes({
    required Map<String, dynamic> osData,
    String? firmaTecBase64,
    String? firmaCliBase64,
  }) async {
    final folio = _s(osData, 'folio_os', _s(osData, 'folio', 'OSOCC-26-001'));
    final doc = pw.Document(
      title: 'FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA - $folio',
      author: 'Servicios PESA',
      subject: 'Formato de Diagnóstico y Revisión de Celda de Carga (OSOCC)',
      creator: 'PESA Tablet App v3',
    );

    pw.ImageProvider? logoPesa;
    pw.ImageProvider? logoRl;
    for (final p in ['Img/logo_pesa.png', 'assets/logo_pesa.png']) {
      try {
        final b = await rootBundle.load(p);
        logoPesa = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }
    for (final p in ['Img/RiceLake.png', 'assets/RiceLake.png']) {
      try {
        final b = await rootBundle.load(p);
        logoRl = pw.MemoryImage(b.buffer.asUint8List());
        break;
      } catch (_) {}
    }

    pw.ImageProvider? firmaTecImg;
    pw.ImageProvider? firmaCliImg;
    final rawTec = firmaTecBase64 ?? _s(osData, 'firma_tecnico', _s(osData, 'firma_tecnico_b64', ''));
    final rawCli = firmaCliBase64 ?? _s(osData, 'firma_cliente', _s(osData, 'firma_receptor_b64', ''));
    if (rawTec.isNotEmpty) {
      try {
        final clean = rawTec.contains(',') ? rawTec.split(',').last : rawTec;
        firmaTecImg = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }
    if (rawCli.isNotEmpty) {
      try {
        final clean = rawCli.contains(',') ? rawCli.split(',').last : rawCli;
        firmaCliImg = pw.MemoryImage(base64Decode(clean));
      } catch (_) {}
    }

    String fechaRaw = _s(osData, 'fecha', _s(osData, 'fecha_servicio', ''));
    String fechaFmt = '';
    if (fechaRaw.length >= 10 && fechaRaw.contains('-')) {
      final parts = fechaRaw.substring(0, 10).split('-');
      if (parts.length == 3) {
        fechaFmt = '${parts[2]} / ${parts[1]} / ${parts[0]}';
      }
    }
    if (fechaFmt.isEmpty) {
      final now = DateTime.now();
      fechaFmt = '${now.day.toString().padLeft(2, '0')} / ${now.month.toString().padLeft(2, '0')} / ${now.year}';
    }

    final refOrden = _s(osData, 'orden_servicio_ref', _s(osData, 'ref_orden', _s(osData, 'orden_servicio', '_______________')));
    final destinoRaw = _s(osData, 'destino_celda', _s(osData, 'destino_tipo', '')).toLowerCase();
    final clienteDest = _s(osData, 'cliente_destino', _s(osData, 'cliente', _s(osData, 'razon_social', 'Stock / Taller Básculas PESA')));

    final bool isStock = destinoRaw.contains('stock') ||
        destinoRaw.contains('laboratorio') ||
        destinoRaw.contains('interno') ||
        clienteDest.toLowerCase().contains('stock / taller') ||
        clienteDest.toLowerCase().contains('laboratorio de celdas');
    final bool isCliente = !isStock;

    final marca = _s(osData, 'marca', _s(osData, 'equipo_marca', ''));
    final modelo = _s(osData, 'modelo', _s(osData, 'equipo_modelo', ''));
    final serie = _s(osData, 'serie', _s(osData, 'ns', _s(osData, 'numero_serie', '')));
    final capNom = _s(osData, 'capacidad_nominal', _s(osData, 'instrumento_capacidad', _s(osData, 'capacidad_maxima', _s(osData, 'alcance_max', ''))));
    final sensNom = _s(osData, 'sensibilidad_nominal', _s(osData, 'sensibilidad_mv_v', ''));
    final resNom = _s(osData, 'resistencia_nominal', _s(osData, 'resistencia_entrada_salida', ''));

    final Map<String, dynamic> cablesRaw = (osData['configuracion_cables'] is Map)
        ? Map<String, dynamic>.from(osData['configuracion_cables'] as Map)
        : {};
    final cExcP = (cablesRaw['exc_pos'] ?? 'Rojo').toString().trim();
    final cExcN = (cablesRaw['exc_neg'] ?? 'Negro').toString().trim();
    final cSigP = (cablesRaw['sig_pos'] ?? 'Verde').toString().trim();
    final cSigN = (cablesRaw['sig_neg'] ?? 'Blanco').toString().trim();
    final cBlind = (cablesRaw['blindaje'] ?? 'Malla').toString().trim();
    final cSense = (cablesRaw['sense'] ?? 'No').toString().trim();

    final Map<String, dynamic> chkRaw = (osData['checklist_celda'] is Map)
        ? Map<String, dynamic>.from(osData['checklist_celda'] as Map)
        : {};
    String chkEst(int idx) {
      final it = chkRaw['$idx'] ?? chkRaw[idx];
      if (it is Map) return (it['estado'] ?? '').toString().trim().toUpperCase();
      return '';
    }
    String chkObs(int idx) {
      final it = chkRaw['$idx'] ?? chkRaw[idx];
      if (it is Map) return (it['observaciones'] ?? '').toString().trim();
      return '';
    }

    final Map<String, dynamic> prRaw = (osData['pruebas_electricas_celda'] is Map)
        ? Map<String, dynamic>.from(osData['pruebas_electricas_celda'] as Map)
        : {};

    final String obsTecnicas = _s(osData, 'observaciones', _s(osData, 'observaciones_tecnicas', ''));
    final String dictamenUp = _s(osData, 'dictamen_celda', _s(osData, 'dictamen_estado', _s(osData, 'dictamen', 'OPERATIVA'))).toUpperCase();
    final bool isRep = dictamenUp.contains('REPARABLE');
    final bool isDan = dictamenUp.contains('DAÑAD') || dictamenUp.contains('DANAD') || dictamenUp.contains('DESCALIBRADA') || dictamenUp.contains('FUERA');
    final bool isOp = !isRep && !isDan;

    final tecNombre = _s(osData, 'tecnico', _s(osData, 'tecnico_nombre', ''));
    final tecPuesto = _s(osData, 'puesto_tecnico', 'Técnico Especialista');
    final cliNombre = _s(osData, 'nombre_receptor', _s(osData, 'firma_cliente_nombre', _s(osData, 'nombre_ing', '')));
    final cliPuesto = _s(osData, 'puesto_receptor', _s(osData, 'area_puesto_cliente', _s(osData, 'puesto_ing', '')));

    String markBox(bool active, [String inner = 'X']) {
      if (inner == 'X') return active ? '[ X ]' : '[   ]';
      return active ? '[X $inner]' : '[ $inner ]';
    }

    pw.Widget secHeader(String title) => pw.Container(
          width: double.infinity,
          color: _dark,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          child: pw.Text(
            title,
            style: pw.TextStyle(color: _white, fontSize: 7.4, fontWeight: pw.FontWeight.bold),
          ),
        );

    pw.Widget buildChecklistCeldaRow(int num, String label) {
      final est = chkEst(num);
      final obs = chkObs(num);
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: pw.BoxDecoration(
          color: num.isEven ? const PdfColor.fromInt(0xFFF9FAFB) : _white,
          border: const pw.Border(
            bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            left: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            right: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
          ),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(
              flex: 48,
              child: pw.Text('$num. $label', style: const pw.TextStyle(fontSize: 6.2, color: _black)),
            ),
            pw.SizedBox(
              width: 118,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(markBox(est == 'B', 'B'), style: pw.TextStyle(fontSize: 6.0, fontWeight: est == 'B' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'B' ? _redBright : _black)),
                  pw.Text(markBox(est == 'R', 'R'), style: pw.TextStyle(fontSize: 6.0, fontWeight: est == 'R' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'R' ? _redBright : _black)),
                  pw.Text(markBox(est == 'M', 'M'), style: pw.TextStyle(fontSize: 6.0, fontWeight: est == 'M' ? pw.FontWeight.bold : pw.FontWeight.normal, color: est == 'M' ? _redBright : _black)),
                  pw.Text(markBox(est == 'N/A' || est == 'NA', 'N/A'), style: pw.TextStyle(fontSize: 6.0, fontWeight: (est == 'N/A' || est == 'NA') ? pw.FontWeight.bold : pw.FontWeight.normal, color: (est == 'N/A' || est == 'NA') ? _redBright : _black)),
                ],
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Expanded(
              flex: 30,
              child: pw.Text('| Obs: ${obs.isNotEmpty ? obs : "_________________"}', style: const pw.TextStyle(fontSize: 6.0, color: _grayD)),
            ),
          ],
        ),
      );
    }

    const List<Map<String, String>> prSpec = [
      {'idx': '1', 'key': 'exc_pos_exc_neg', 'label': 'Excitación Exc+ / Exc-', 'und': 'Ohms'},
      {'idx': '2', 'key': 'sig_pos_sig_neg', 'label': 'Resistencia Sig+ / Sig-', 'und': 'Ohms'},
      {'idx': '3', 'key': 'exc_pos_sig_pos', 'label': 'Resistencia Exc+ / Sig+', 'und': 'Ohms'},
      {'idx': '4', 'key': 'exc_pos_sig_neg', 'label': 'Resistencia Exc+ / Sig-', 'und': 'Ohms'},
      {'idx': '5', 'key': 'exc_neg_sig_pos', 'label': 'Resistencia Exc- / Sig+', 'und': 'Ohms'},
      {'idx': '6', 'key': 'exc_neg_sig_neg', 'label': 'Resistencia Exc- / Sig-', 'und': 'Ohms'},
      {'idx': '7', 'key': 'sig_neg_mas_exc_pos', 'label': 'Resistencia Sig- + Exc+', 'und': 'Ohms'},
      {'idx': '8', 'key': 'sig_neg_mas_exc_neg', 'label': 'Resistencia Sig- + Exc-', 'und': 'Ohms'},
      {'idx': '9', 'key': 'exc_neg_pos_sig_pos', 'label': 'Resistencia Exc-+ / Sig+', 'und': 'Ohms'},
      {'idx': '10', 'key': 'exc_neg_pos_sig_neg', 'label': 'Resistencia Exc-+ / Sig-', 'und': 'Ohms'},
      {'idx': '11', 'key': 'senal_salida_mv', 'label': 'Señal de Salida (Milivoltaje)', 'und': 'mV'},
      {'idx': '12', 'key': 'resistencia_aislamiento', 'label': 'Resistencia de Aislamiento', 'und': 'MΩ'},
    ];

    pw.Widget buildPruebaElecRow(Map<String, String> spec) {
      final int idx = int.parse(spec['idx']!);
      final String key = spec['key']!;
      final dynamic it = prRaw['$idx'] ?? prRaw[idx] ?? prRaw[key];
      String valMed = '';
      String estStr = '';
      if (it is Map) {
        valMed = (it['valor'] ?? it['valor_medido'] ?? '').toString().trim();
        estStr = (it['estado'] ?? '').toString().trim().toUpperCase();
      }
      final bool isFail = estStr.contains('FALLA') || estStr.contains('FUGA');
      final bool isOk = !isFail && estStr.isNotEmpty;
      final String estadoTxt = idx == 12
          ? '${markBox(isOk)} > 5000 MΩ (OK)   ${markBox(isFail)} Fuga'
          : '${markBox(isOk)} OK   ${markBox(isFail)} Falla';

      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: pw.BoxDecoration(
          color: idx.isEven ? const PdfColor.fromInt(0xFFF9FAFB) : _white,
          border: const pw.Border(
            bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            left: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
            right: pw.BorderSide(color: PdfColor.fromInt(0xFFDCDCDC), width: 0.35),
          ),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(
              flex: 42,
              child: pw.Text('$idx. ${spec['label']}', style: const pw.TextStyle(fontSize: 6.2)),
            ),
            pw.SizedBox(
              width: 42,
              child: pw.Text(spec['und']!, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 6.1, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Expanded(
              flex: 24,
              child: pw.Text(
                valMed.isNotEmpty ? valMed : '____________',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 6.3, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.Expanded(
              flex: 34,
              child: pw.Text(
                estadoTxt,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 6.0),
              ),
            ),
          ],
        ),
      );
    }

    final double obsFontSize = obsTecnicas.length > 350 ? 6.8 : (obsTecnicas.length > 200 ? 7.5 : 8.5);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(22, 14, 22, 14),
        build: (ctx) => [
          // Cabecera con logos y título oficial
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              _logoBox(logoPesa, 'BP BÁSCULAS PESA', 95, 28),
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      'FORMATO DE DIAGNÓSTICO Y REVISIÓN DE CELDA DE CARGA',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 10.2, fontWeight: pw.FontWeight.bold, color: _red),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Folio: $folio | Fecha: $fechaFmt | Ref. / Orden: ${refOrden.isEmpty ? "_______________" : refOrden} | Destino: ${markBox(isCliente)} Cliente   ${markBox(isStock)} Stock / Laboratorio Interno',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 6.8, fontWeight: pw.FontWeight.bold, color: _dark),
                    ),
                  ],
                ),
              ),
              _logoBox(logoRl, 'RICE LAKE', 85, 28),
            ],
          ),
          pw.SizedBox(height: 5),

          // ── 1. DATOS DE IDENTIFICACIÓN DE LA CELDA ────────────────────────
          secHeader('1. DATOS DE IDENTIFICACIÓN DE LA CELDA'),
          pw.Container(
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Cliente / Destino: $clienteDest', style: pw.TextStyle(fontSize: 6.8, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 2.5),
                pw.Row(children: [
                  pw.Expanded(child: pw.Text('Marca: $marca', style: const pw.TextStyle(fontSize: 6.5))),
                  pw.Expanded(child: pw.Text('Modelo: $modelo', style: const pw.TextStyle(fontSize: 6.5))),
                  pw.Expanded(child: pw.Text('Número de Serie: $serie', style: const pw.TextStyle(fontSize: 6.5))),
                ]),
                pw.SizedBox(height: 2.5),
                pw.Row(children: [
                  pw.Expanded(child: pw.Text('Capacidad Nominal (Max): $capNom', style: const pw.TextStyle(fontSize: 6.5))),
                  pw.Expanded(child: pw.Text('Sensibilidad Nominal: ${sensNom.isNotEmpty ? "$sensNom mV/V" : ""}', style: const pw.TextStyle(fontSize: 6.5))),
                  pw.Expanded(child: pw.Text('Resistencia Nominal Ent./Sal.: ${resNom.isNotEmpty ? "$resNom Ohms" : ""}', style: const pw.TextStyle(fontSize: 6.5))),
                ]),
                pw.SizedBox(height: 2.5),
                pw.Text(
                  'Configuración de Cables / Colores: [ Exc+: $cExcP | Exc-: $cExcN | Sig+: $cSigP | Sig-: $cSigN | Blindaje: $cBlind | Sense: $cSense ]',
                  style: const pw.TextStyle(fontSize: 6.3),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 4),

          // ── 2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA ───────────────────
          secHeader('2. INSPECCIÓN FÍSICA Y MECÁNICA DE LA CELDA (Criterio: [ B ] Bueno   [ R ] Regular   [ M ] Malo   [ N/A ])'),
          buildChecklistCeldaRow(1, 'Cuerpo metálico / Deformación'),
          buildChecklistCeldaRow(2, 'Roscas, barrenos y apoyos mecánicos'),
          buildChecklistCeldaRow(3, 'Sellos herméticos y encapsulado de galgas'),
          buildChecklistCeldaRow(4, 'Integridad del cable (sin cortes, aplastamientos ni empalmes)'),
          buildChecklistCeldaRow(5, 'Prensaestopas / Salida de cable'),
          buildChecklistCeldaRow(6, 'Evidencia de corrosión, humedad o sobrecarga térmica'),
          pw.SizedBox(height: 4),

          // ── 3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA) ──────
          secHeader('3. PRUEBAS Y MEDICIONES ELÉCTRICAS UNITARIAS (SIN CARGA)'),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            color: const PdfColor.fromInt(0xFFEAEAEA),
            child: pw.Row(
              children: [
                pw.Expanded(flex: 42, child: pw.Text('PARÁMETRO ELÉCTRICO', style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold, color: _red))),
                pw.SizedBox(width: 42, child: pw.Text('UND', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold, color: _red))),
                pw.Expanded(flex: 24, child: pw.Text('VALOR MEDIDO', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold, color: _red))),
                pw.Expanded(flex: 34, child: pw.Text('ESTADO (OK / FALLA)', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 6.2, fontWeight: pw.FontWeight.bold, color: _red))),
              ],
            ),
          ),
          for (final spec in prSpec) buildPruebaElecRow(spec),
          pw.SizedBox(height: 4),

          // ── 4. DICTAMEN TÉCNICO Y OBSERVACIONES ───────────────────────────
          secHeader('4. DICTAMEN TÉCNICO Y OBSERVACIONES'),
          pw.SizedBox(height: 2),
          pw.Text('Observaciones Técnicas y Diagnóstico:', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1.5),
          pw.Container(
            width: double.infinity,
            constraints: const pw.BoxConstraints(minHeight: 38),
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.6)),
            child: pw.Text(
              obsTecnicas.isEmpty ? 'Sin observaciones adicionales.' : obsTecnicas,
              style: pw.TextStyle(fontSize: obsFontSize, lineSpacing: 1.5),
              softWrap: true,
              textAlign: pw.TextAlign.left,
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Text('Dictamen Final de la Celda:', style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 1.5),
          pw.Text(
            '  ${markBox(isOp)} OPERATIVA / EN TOLERANCIA (Apta para instalación o calibración)',
            style: pw.TextStyle(fontSize: 6.2, fontWeight: isOp ? pw.FontWeight.bold : pw.FontWeight.normal),
          ),
          pw.Text(
            '  ${markBox(isRep)} REPARABLE (Requiere reemplazo de cable, conector o reapriete)',
            style: pw.TextStyle(fontSize: 6.2, fontWeight: isRep ? pw.FontWeight.bold : pw.FontWeight.normal),
          ),
          pw.Text(
            '  ${markBox(isDan)} DAÑADA / DESCALIBRADA (Sobrecarga, galgas abiertas o fuga - FUERA DE SERVICIO)',
            style: pw.TextStyle(fontSize: 6.2, fontWeight: isDan ? pw.FontWeight.bold : pw.FontWeight.normal),
          ),
          pw.SizedBox(height: 4),

          // ── 5. FIRMAS DE RESPONSABILIDAD ──────────────────────────────────
          secHeader('5. FIRMAS DE RESPONSABILIDAD'),
          pw.SizedBox(height: 3),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.6)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Evaluó / Técnico Responsable', style: pw.TextStyle(fontSize: 6.6, fontWeight: pw.FontWeight.bold, color: _red)),
                      pw.SizedBox(height: 2),
                      pw.Text('Nombre: $tecNombre', style: const pw.TextStyle(fontSize: 6.3)),
                      pw.Text('Puesto: $tecPuesto', style: const pw.TextStyle(fontSize: 6.3)),
                      pw.SizedBox(height: 2),
                      pw.SizedBox(
                        height: 34,
                        width: double.infinity,
                        child: firmaTecImg != null
                            ? pw.Center(child: pw.Image(firmaTecImg, fit: pw.BoxFit.contain))
                            : pw.SizedBox(),
                      ),
                      pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey600),
                      pw.Center(child: pw.Text('Firma', style: const pw.TextStyle(fontSize: 5.8, color: _grayD))),
                    ],
                  ),
                ),
              ),
              pw.SizedBox(width: 14),
              pw.Expanded(
                child: pw.Container(
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.6)),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Recibió / Almacén o Cliente', style: pw.TextStyle(fontSize: 6.6, fontWeight: pw.FontWeight.bold, color: _red)),
                      pw.SizedBox(height: 2),
                      pw.Text('Nombre: $cliNombre', style: const pw.TextStyle(fontSize: 6.3)),
                      pw.Text('Puesto: $cliPuesto', style: const pw.TextStyle(fontSize: 6.3)),
                      pw.SizedBox(height: 2),
                      pw.SizedBox(
                        height: 34,
                        width: double.infinity,
                        child: firmaCliImg != null
                            ? pw.Center(child: pw.Image(firmaCliImg, fit: pw.BoxFit.contain))
                            : pw.SizedBox(),
                      ),
                      pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey600),
                      pw.Center(child: pw.Text('Firma', style: const pw.TextStyle(fontSize: 5.8, color: _grayD))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return doc.save();
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

/// Vector dibujo Tanque para recuadro No Aplica Excentricidad
void _dibujarTanque(PdfGraphics c, PdfPoint size) {
  final cx = size.x / 2;
  final cy = size.y / 2 - 1;
  const col = PdfColor.fromInt(0xFFC8102E);
  const fillCol = PdfColor.fromInt(0xFFFFE5E5);

  c.saveContext();
  c.setStrokeColor(col);
  c.setFillColor(fillCol);
  c.setLineWidth(1.0);

  // Cuerpo cilíndrico
  c.drawRect(cx - 8, cy - 4, 16, 12);
  c.fillPath();
  c.drawRect(cx - 8, cy - 4, 16, 12);
  c.strokePath();

  // Tapa superior elipse
  c.drawEllipse(cx, cy + 8, 8, 2.5);
  c.strokePath();

  // Fondo inferior elipse
  c.drawEllipse(cx, cy - 4, 8, 2);
  c.strokePath();

  // 3 patas de soporte con celdas de carga
  c.setLineWidth(1.2);
  for (final dx in [-7.0, 0.0, 7.0]) {
    c.moveTo(cx + dx, cy - 4);
    c.lineTo(cx + dx - 1.5, cy - 9);
    c.strokePath();
    c.moveTo(cx + dx, cy - 4);
    c.lineTo(cx + dx + 1.5, cy - 9);
    c.strokePath();
    c.moveTo(cx + dx - 2.5, cy - 9);
    c.lineTo(cx + dx + 2.5, cy - 9);
    c.strokePath();
  }

  // Tubo superior de entrada
  c.setLineWidth(1.5);
  c.moveTo(cx, cy + 10.5);
  c.lineTo(cx, cy + 14);
  c.strokePath();
  c.setLineWidth(1.0);
  c.moveTo(cx - 3, cy + 14);
  c.lineTo(cx + 3, cy + 14);
  c.strokePath();

  c.restoreContext();
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
