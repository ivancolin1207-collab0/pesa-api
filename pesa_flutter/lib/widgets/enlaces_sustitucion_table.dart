import 'package:flutter/material.dart';
import '../services/metrology_helper.dart';

class EnlacesSustitucionTable extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  final Widget? footer;
  final double? divMin;
  final int numEnlaces;

  const EnlacesSustitucionTable({
    super.key,
    required this.rows,
    required this.onChanged,
    this.footer,
    this.divMin,
    this.numEnlaces = 5,
  });

  @override
  State<EnlacesSustitucionTable> createState() => _EnlacesSustitucionTableState();
}

class _EnlacesSustitucionTableState extends State<EnlacesSustitucionTable> {
  static const Color _kRed = Color(0xFFC8102E);
  late List<TextEditingController> _pesasCtrls;
  late List<TextEditingController> _aguaCtrls;
  late List<TextEditingController> _aguaPesasCtrls;
  late List<TextEditingController> _indicacionCtrls;
  late List<TextEditingController> _regresoCtrls;

  @override
  void initState() {
    super.initState();
    final n = widget.numEnlaces;
    _pesasCtrls = List.generate(n, (i) => TextEditingController(text: i < widget.rows.length ? formatMetrologicalString(widget.rows[i]['pesas'], widget.divMin) : ''));
    _aguaCtrls = List.generate(n, (i) => TextEditingController(text: i < widget.rows.length ? formatMetrologicalString(widget.rows[i]['agua'], widget.divMin) : ''));
    _aguaPesasCtrls = List.generate(n, (i) => TextEditingController(text: i < widget.rows.length ? formatMetrologicalString(widget.rows[i]['agua_pesas'], widget.divMin) : ''));
    _indicacionCtrls = List.generate(n, (i) => TextEditingController(text: i < widget.rows.length ? formatMetrologicalString(widget.rows[i]['indicacion'] ?? widget.rows[i]['lectura_inicial'], widget.divMin) : ''));
    _regresoCtrls = List.generate(n, (i) => TextEditingController(text: i < widget.rows.length ? formatMetrologicalString(widget.rows[i]['regreso'] ?? widget.rows[i]['lectura_final'], widget.divMin) : ''));

    for (final c in [..._pesasCtrls, ..._aguaCtrls, ..._aguaPesasCtrls, ..._indicacionCtrls, ..._regresoCtrls]) {
      c.addListener(_notify);
    }
  }

  void _notify() => widget.onChanged(_serialize());

  List<Map<String, dynamic>> _serialize() {
    return List.generate(widget.numEnlaces, (i) {
      final pesas = double.tryParse(_pesasCtrls[i].text.trim().replaceAll(',', '.'));
      final indicacion = double.tryParse(_indicacionCtrls[i].text.trim().replaceAll(',', '.'));
      double? err;
      if (indicacion != null && pesas != null) {
        err = indicacion - pesas; // Error = Indicación - Carga Nominal
      }

      return {
        'pesas': _pesasCtrls[i].text.trim(),
        'agua': _aguaCtrls[i].text.trim(),
        'agua_pesas': _aguaPesasCtrls[i].text.trim(),
        'indicacion': _indicacionCtrls[i].text.trim(),
        'regreso': _regresoCtrls[i].text.trim(),
        'error': err != null ? err.toStringAsFixed(getDecimalsFromD(widget.divMin)) : null,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  'ENLACES DE SUSTITUCIÓN',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _kRed, letterSpacing: 1),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 700,
                child: Table(
                  border: TableBorder.all(color: Colors.grey.shade200),
                  columnWidths: const {
                    0: FlexColumnWidth(0.5),
                    1: FlexColumnWidth(1),
                    2: FlexColumnWidth(1),
                    3: FlexColumnWidth(1),
                    4: FlexColumnWidth(1),
                    5: FlexColumnWidth(1),
                    6: FlexColumnWidth(1),
                  },
                  children: [
                    _hdr(['N', 'PESAS', 'AGUA', 'AGUA + PESAS', 'INDICACIÓN', 'REGRESO', 'ERROR']),
                    for (int i = 0; i < widget.numEnlaces; i++) _row(i),
                  ],
                ),
              ),
            ),
            if (widget.footer != null) ...[const SizedBox(height: 20), widget.footer!],
          ],
        ),
      ),
    );
  }

  TableRow _hdr(List<String> l) => TableRow(
    decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
    children: l.map((s) => Padding(padding: const EdgeInsets.all(8), child: Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)))).toList(),
  );

  TableRow _row(int i) {
    final pesas = double.tryParse(_pesasCtrls[i].text.trim().replaceAll(',', '.'));
    final indicacion = double.tryParse(_indicacionCtrls[i].text.trim().replaceAll(',', '.'));
    double? err;
    if (indicacion != null && pesas != null) err = indicacion - pesas;
    
    return TableRow(
      decoration: BoxDecoration(color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9)),
      children: [
        Padding(padding: const EdgeInsets.all(8), child: Text('', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11))),
        _input(_pesasCtrls[i]),
        _input(_aguaCtrls[i]),
        _input(_aguaPesasCtrls[i]),
        _input(_indicacionCtrls[i]),
        _input(_regresoCtrls[i]),
        Padding(padding: const EdgeInsets.all(8), child: Text(err != null ? err.toStringAsFixed(getDecimalsFromD(widget.divMin)) : '-', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: err != null ? (err.abs() > (widget.divMin ?? 0) * 3 ? Colors.red : Colors.green) : Colors.black87))),
      ],
    );
  }

  Widget _input(TextEditingController c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: SizedBox(
      height: 28,
      child: TextField(
        controller: c,
        textAlign: TextAlign.center,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: _kRed, width: 1.5)),
        ),
      ),
    ),
  );
}
