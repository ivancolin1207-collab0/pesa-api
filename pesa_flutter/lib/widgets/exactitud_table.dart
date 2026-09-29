// lib/widgets/exactitud_table.dart — Tabla táctil de Exactitud
// v3.0: Validación estricta de división mínima (d / e) en Nominal, Inicial y Final
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';

const _kRed = Color(0xFFC8102E);

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

class _ExactitudTableState extends State<ExactitudTable> {
  late List<TextEditingController> _nomCtrls, _initCtrls, _finalCtrls;

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
    final dec = getDecimalsFromD(widget.divMin);

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
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade300),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      divMinErrorMsg(widget.divMin),
                      style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        'EXACTITUD',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: _kRed,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'd = ${widget.divMin != null ? formatMetrologicalValue(widget.divMin, widget.divMin) : '?'}\n($dec decimales)',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Table(
                    border: TableBorder.all(color: Colors.grey.shade200),
                    columnWidths: const {
                      0: FlexColumnWidth(0.8),
                      1: FlexColumnWidth(1.8),
                      2: FlexColumnWidth(1.8),
                      3: FlexColumnWidth(1.8),
                      4: FlexColumnWidth(1.5),
                    },
                    children: [
                      _hdr(['N', 'VALOR NOMINAL', 'L. INICIAL', 'L. FINAL', 'ERROR']),
                      for (int i = 0; i < n; i++)
                        _row(i, dec),
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

  TableRow _hdr(List<String> l) => TableRow(
    decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
    children: l.map((s) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        s,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    )).toList(),
  );

  TableRow _row(int i, int dec) {
    final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
    final nom = double.tryParse(_nomCtrls[i].text.trim().replaceAll(',', '.'));
    double? err;
    if (fin != null && nom != null) {
      err = fin - nom;
    }

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '${i + 1}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ),
        _inp(_nomCtrls[i], dec, hint: 'Nominal'),
        _inp(_initCtrls[i], dec, hint: 'Inicial'),
        _inp(_finalCtrls[i], dec, hint: 'Final'),
        Padding(
          padding: const EdgeInsets.all(4),
          child: err == null
              ? const Center(
                  child: Text('—', style: TextStyle(color: Colors.grey, fontSize: 13)))
              : Text(
                  formatMetrologicalValue(err, widget.divMin),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: err.abs() > (widget.divMin ?? 0.001)
                        ? _kRed
                        : Colors.green.shade700,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _inp(TextEditingController c, int dec, {String? hint}) {
    final val = double.tryParse(c.text.trim().replaceAll(',', '.'));
    final invalido = val != null && !isValidDivMin(val, widget.divMin);

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus && c.text.trim().isNotEmpty) {
            double? n = double.tryParse(c.text.replaceAll(',', '.'));
            if (n != null) c.text = formatMetrologicalValue(n, widget.divMin);
            setState(() {});
          }
        },
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.,\-]'))
          ],
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: invalido ? Colors.red : Colors.black87,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint ?? (dec == 0 ? '0' : '0.${'0' * dec}'),
            hintStyle: TextStyle(color: Colors.grey.shade300, fontSize: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? Colors.red : Colors.grey.shade300,
                width: invalido ? 1.5 : 1,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? Colors.red : Colors.grey.shade300,
                width: invalido ? 1.5 : 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(
                color: invalido ? Colors.red : _kRed,
                width: 2,
              ),
            ),
            fillColor: invalido ? const Color(0xFFFFEBEE) : Colors.white,
            filled: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
        ),
      ),
    );
  }
}