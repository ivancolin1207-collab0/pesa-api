// lib/widgets/exactitud_table.dart — Tabla táctil de Exactitud
// v3.0: Validación estricta de división mínima (d / e) en Nominal, Inicial y Final
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';
import '../theme/pesa_theme.dart';

class ExactitudTable extends StatefulWidget {
  final int numPuntos;
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  /// División mínima en kg — controla decimales y validación de múltiplos
  final double? divMin;
  /// Widget opcional al final de la tabla (ej. observaciones + dictamen + botón a firmas)
  final Widget? footer;

  const ExactitudTable({
    super.key,
    required this.numPuntos,
    required this.rows,
    required this.onChanged,
    this.divMin,
    this.footer,
  });

  @override
  State<ExactitudTable> createState() => _ExactitudTableState();
}

class _ExactitudTableState extends State<ExactitudTable>
    with AutomaticKeepAliveClientMixin {
  late List<TextEditingController> _nomCtrls, _initCtrls, _finalCtrls;

  @override
  bool get wantKeepAlive => true; // Evita destrucción al cambiar de pestaña

  @override
  void initState() {
    super.initState();
    final n = widget.numPuntos.clamp(1, 20);
    _nomCtrls = List.generate(
        n,
        (i) => TextEditingController(
            text: i < widget.rows.length
                ? formatMetrologicalString(widget.rows[i]['valor_nominal'], widget.divMin)
                : ''));
    _initCtrls = List.generate(
        n,
        (i) => TextEditingController(
            text: i < widget.rows.length
                ? formatMetrologicalString(widget.rows[i]['lectura_inicial'], widget.divMin)
                : ''));
    _finalCtrls = List.generate(
        n,
        (i) => TextEditingController(
            text: i < widget.rows.length
                ? formatMetrologicalString(widget.rows[i]['lectura_final'], widget.divMin)
                : ''));
    for (final c in [..._nomCtrls, ..._initCtrls, ..._finalCtrls]) {
      c.addListener(_notify);
    }
  }

  @override
  void didUpdateWidget(ExactitudTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.divMin != widget.divMin) {
      _reformatAllControllers();
    }
  }

  void _reformatAllControllers() {
    for (final c in [..._nomCtrls, ..._initCtrls, ..._finalCtrls]) {
      if (c.text.trim().isNotEmpty) {
        c.text = formatMetrologicalString(c.text, widget.divMin);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [..._nomCtrls, ..._initCtrls, ..._finalCtrls]) {
      c.dispose();
    }
    super.dispose();
  }

  void _notify() => widget.onChanged(_serialize());

  List<Map<String, dynamic>> _serialize() {
    final dec = getDecimalsFromD(widget.divMin);
    return List.generate(widget.numPuntos.clamp(1, 20), (i) {
      final nom = double.tryParse(_nomCtrls[i].text.trim().replaceAll(',', '.'));
      final ini = double.tryParse(_initCtrls[i].text.trim().replaceAll(',', '.'));
      final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
      // ERROR = L.Final - Valor Nominal (exactitud)
      double? error;
      if (fin != null && nom != null) {
        error = fin - nom;
      }
      return {
        'posicion_id':    i + 1,
        'punto_id':       i + 1,
        'valor_nominal':  nom,
        'lectura_inicial': ini,
        'lectura_final':  fin,
        'error':          error,
        'decimales':      dec,
        'valido_d':       isValidDivMin(nom, widget.divMin) &&
                          isValidDivMin(ini, widget.divMin) &&
                          isValidDivMin(fin, widget.divMin),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // requerido por AutomaticKeepAliveClientMixin
    final c = PesaColors.of(context);
    final dec = getDecimalsFromD(widget.divMin);
    final Color errorFill = c.isDark ? const Color(0xFF34181D) : const Color(0xFFFFEBEE);

    // Revisar si hay campos inválidos
    bool hayCamposInvalidos = false;
    final n = widget.numPuntos.clamp(1, 20);
    for (int i = 0; i < n; i++) {
      final nom = double.tryParse(_nomCtrls[i].text.trim().replaceAll(',', '.'));
      final ini = double.tryParse(_initCtrls[i].text.trim().replaceAll(',', '.'));
      final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
      if (nom != null && !isValidDivMin(nom, widget.divMin)) hayCamposInvalidos = true;
      if (ini != null && !isValidDivMin(ini, widget.divMin)) hayCamposInvalidos = true;
      if (fin != null && !isValidDivMin(fin, widget.divMin)) hayCamposInvalidos = true;
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hayCamposInvalidos)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: errorFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.dotRed.withValues(alpha: 0.65)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: c.dotRed, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      divMinErrorMsg(widget.divMin),
                      style: TextStyle(color: c.dotRed, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Card(
            elevation: 0,
            color: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: c.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        'EXACTITUD',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: c.brandAccent,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'd = ${widget.divMin != null ? formatMetrologicalValue(widget.divMin, widget.divMin) : '?'}\n($dec decimales)',
                        style: TextStyle(fontSize: 10, color: c.textSecondary),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Table(
                    border: TableBorder.all(color: c.border),
                    columnWidths: const {
                      0: FlexColumnWidth(0.8),
                      1: FlexColumnWidth(1.8),
                      2: FlexColumnWidth(1.8),
                      3: FlexColumnWidth(1.8),
                      4: FlexColumnWidth(1.5),
                    },
                    children: [
                      _hdr(['N', 'VALOR NOMINAL', 'L. INICIAL', 'L. FINAL', 'ERROR'], c),
                      for (int i = 0; i < n; i++)
                        _row(i, dec, c),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (widget.footer != null) ...[
            const SizedBox(height: 20),
            widget.footer!,
          ],
        ],
      ),
    );
  }

  TableRow _hdr(List<String> l, PesaPalette c) => TableRow(
    decoration: BoxDecoration(color: c.isDark ? c.surfaceElevated : const Color(0xFF1C1C1E)),
    children: l.map((s) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        s,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: c.isDark ? c.textPrimary : Colors.white,
        ),
      ),
    )).toList(),
  );

  TableRow _row(int i, int dec, PesaPalette c) {
    final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
    final nom = double.tryParse(_nomCtrls[i].text.trim().replaceAll(',', '.'));
    double? err;
    if (fin != null && nom != null) {
      err = fin - nom;
    }
    final Color altBg = c.isDark ? const Color(0xFF222226) : const Color(0xFFF9F9F9);

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? c.surface : altBg,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '${i + 1}',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.textPrimary),
          ),
        ),
        _inp(_nomCtrls[i], dec, c, hint: 'Nominal'),
        _inp(_initCtrls[i], dec, c, hint: 'Inicial'),
        _inp(_finalCtrls[i], dec, c, hint: 'Final'),
        Padding(
          padding: const EdgeInsets.all(4),
          child: err == null
              ? Center(
                  child: Text('—', style: TextStyle(color: c.textSecondary, fontSize: 13)))
              : Text(
                  formatMetrologicalValue(err, widget.divMin),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: err.abs() > (widget.divMin ?? 0.001)
                        ? c.brandAccent
                        : c.dotGreen,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _inp(TextEditingController ctrl, int dec, PesaPalette c, {String? hint}) {
    final val = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
    final invalido = val != null && !isValidDivMin(val, widget.divMin);
    final Color errorFill = c.isDark ? const Color(0xFF34181D) : const Color(0xFFFFEBEE);

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus && ctrl.text.trim().isNotEmpty) {
            double? n = double.tryParse(ctrl.text.replaceAll(',', '.'));
            if (n != null) ctrl.text = formatMetrologicalValue(n, widget.divMin);
            setState(() {});
          }
        },
        child: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.,\-]'))
          ],
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: invalido ? c.dotRed : c.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint ?? (dec == 0 ? '0' : '0.${'0' * dec}'),
            hintStyle: TextStyle(color: c.textTertiary, fontSize: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? c.dotRed : c.borderStrong,
                width: invalido ? 1.5 : 1,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? c.dotRed : c.borderStrong,
                width: invalido ? 1.5 : 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? c.dotRed : c.brandAccent,
                width: 2,
              ),
            ),
            fillColor: invalido ? errorFill : (c.isDark ? c.surfaceElevated : c.surface),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
        ),
      ),
    );
  }
}