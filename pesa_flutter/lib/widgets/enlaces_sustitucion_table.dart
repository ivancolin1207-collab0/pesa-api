import 'package:flutter/material.dart';
import '../services/metrology_helper.dart';
import '../services/pdf_service.dart';

class EnlacesSustitucionTable extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  final Widget? footer;
  final double? divMin;
  final int numEnlaces;
  final List<Map<String, dynamic>>? sustitutos;
  final ValueChanged<List<Map<String, dynamic>>>? onSustitutosChanged;
  final String unidadMedida;

  const EnlacesSustitucionTable({
    super.key,
    required this.rows,
    required this.onChanged,
    this.footer,
    this.divMin,
    this.numEnlaces = 5,
    this.sustitutos,
    this.onSustitutosChanged,
    this.unidadMedida = 'kg',
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

  late List<Map<String, dynamic>> _sustitutosList;
  late List<TextEditingController> _sustNombreCtrls;
  late List<TextEditingController> _sustPesoCtrls;

  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _rowKeys = [];
  final List<List<FocusNode>> _rowFocusNodes = [];

  bool _isAutoCalculating = false;

  @override
  void initState() {
    super.initState();
    final n = widget.rows.length >= 5 ? widget.rows.length : widget.numEnlaces;

    _pesasCtrls = [];
    _aguaCtrls = [];
    _aguaPesasCtrls = [];
    _indicacionCtrls = [];
    _regresoCtrls = [];

    for (int i = 0; i < n; i++) {
      _initRowControllers(i < widget.rows.length ? widget.rows[i] : null);
    }

    _initSustitutos();
  }

  void _initSustitutos() {
    _sustitutosList = widget.sustitutos != null
        ? List<Map<String, dynamic>>.from(widget.sustitutos!)
        : [];
    _sustNombreCtrls = [];
    _sustPesoCtrls = [];

    for (final s in _sustitutosList) {
      final nomCtrl = TextEditingController(text: s['sustituto']?.toString() ?? '');
      final pesoCtrl = TextEditingController(text: s['peso']?.toString() ?? '');
      nomCtrl.addListener(_notifySustitutos);
      pesoCtrl.addListener(_notifySustitutos);
      _sustNombreCtrls.add(nomCtrl);
      _sustPesoCtrls.add(pesoCtrl);
    }
  }

  void _initRowControllers(Map<String, dynamic>? initialData) {
    final pesas = initialData != null ? (initialData['pesas']?.toString() ?? '') : '';
    final agua = initialData != null ? (initialData['agua']?.toString() ?? '') : '';
    final aguaPesas = initialData != null ? (initialData['agua_pesas']?.toString() ?? '') : '';
    final ind = initialData != null ? (initialData['indicacion'] ?? initialData['lectura_inicial'])?.toString() ?? '' : '';
    final reg = initialData != null ? (initialData['regreso'] ?? initialData['lectura_final'])?.toString() ?? '' : '';

    final pCtrl = TextEditingController(text: pesas);
    final aCtrl = TextEditingController(text: agua);
    final apCtrl = TextEditingController(text: aguaPesas);
    final indCtrl = TextEditingController(text: ind);
    final regCtrl = TextEditingController(text: reg);

    final idx = _pesasCtrls.length;
    _rowKeys.add(GlobalKey());

    final fnP = FocusNode();
    final fnA = FocusNode();
    final fnAP = FocusNode();
    final fnI = FocusNode();
    final fnR = FocusNode();
    final fns = [fnP, fnA, fnAP, fnI, fnR];
    for (final fn in fns) {
      fn.addListener(() {
        if (fn.hasFocus) {
          Future.delayed(const Duration(milliseconds: 250), () => _scrollToRow(idx));
        }
      });
    }
    _rowFocusNodes.add(fns);

    pCtrl.addListener(() => _onPesasOrAguaChanged(idx));
    aCtrl.addListener(() => _onPesasOrAguaChanged(idx));
    apCtrl.addListener(() => _onAguaPesasChanged(idx));
    indCtrl.addListener(() => _onIndicacionChanged(idx));
    regCtrl.addListener(_notify);

    _pesasCtrls.add(pCtrl);
    _aguaCtrls.add(aCtrl);
    _aguaPesasCtrls.add(apCtrl);
    _indicacionCtrls.add(indCtrl);
    _regresoCtrls.add(regCtrl);
  }

  void _scrollToRow(int index) {
    if (!mounted || index < 0 || index >= _rowKeys.length) return;
    final ctx = _rowKeys[index].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPesasOrAguaChanged(int i) {
    if (_isAutoCalculating || i >= _pesasCtrls.length) return;
    _isAutoCalculating = true;

    final p = _parseDouble(_pesasCtrls[i].text);
    final a = _parseDouble(_aguaCtrls[i].text);

    if (p != null || a != null) {
      final ap = (p ?? 0.0) + (a ?? 0.0);
      final dec = getDecimalsFromD(widget.divMin);
      _aguaPesasCtrls[i].text = dec > 0 ? ap.toStringAsFixed(dec) : (ap == ap.roundToDouble() ? ap.round().toString() : ap.toString());
    }

    _isAutoCalculating = false;
    setState(() {});
    _notify();
  }

  void _onAguaPesasChanged(int i) {
    if (_isAutoCalculating || i >= _aguaPesasCtrls.length) return;
    setState(() {});
    _notify();
  }

  void _onIndicacionChanged(int i) {
    if (_isAutoCalculating || i >= _indicacionCtrls.length) return;
    setState(() {});
    _notify();
  }

  double? _parseDouble(String s) {
    final clean = s.trim().replaceAll(',', '.').replaceAll(' ', '');
    if (clean.isEmpty) return null;
    return double.tryParse(clean);
  }

  void _addPoint() {
    setState(() {
      _initRowControllers(null);
    });
    _notify();
  }

  void _removePoint(int i) {
    if (_pesasCtrls.length <= 5) return;
    setState(() {
      _pesasCtrls[i].dispose();
      _aguaCtrls[i].dispose();
      _aguaPesasCtrls[i].dispose();
      _indicacionCtrls[i].dispose();
      _regresoCtrls[i].dispose();

      _pesasCtrls.removeAt(i);
      _aguaCtrls.removeAt(i);
      _aguaPesasCtrls.removeAt(i);
      _indicacionCtrls.removeAt(i);
      _regresoCtrls.removeAt(i);

      if (i < _rowFocusNodes.length) {
        for (final fn in _rowFocusNodes[i]) {
          fn.dispose();
        }
        _rowFocusNodes.removeAt(i);
      }
      if (i < _rowKeys.length) {
        _rowKeys.removeAt(i);
      }
    });
    _notify();
  }

  void _addSustituto() {
    setState(() {
      final nomCtrl = TextEditingController(text: 'Sustituto ${_sustNombreCtrls.length + 1}');
      final pesoCtrl = TextEditingController(text: '');
      nomCtrl.addListener(_notifySustitutos);
      pesoCtrl.addListener(_notifySustitutos);
      _sustNombreCtrls.add(nomCtrl);
      _sustPesoCtrls.add(pesoCtrl);
      _sustitutosList.add({'sustituto': nomCtrl.text, 'peso': ''});
    });
    _notifySustitutos();
  }

  void _removeSustituto(int i) {
    setState(() {
      _sustNombreCtrls[i].dispose();
      _sustPesoCtrls[i].dispose();
      _sustNombreCtrls.removeAt(i);
      _sustPesoCtrls.removeAt(i);
      _sustitutosList.removeAt(i);
    });
    _notifySustitutos();
  }

  void _notifySustitutos() {
    final list = <Map<String, dynamic>>[];
    for (int i = 0; i < _sustNombreCtrls.length; i++) {
      list.add({
        'sustituto': _sustNombreCtrls[i].text.trim(),
        'peso': _sustPesoCtrls[i].text.trim(),
      });
    }
    _sustitutosList = list;
    if (widget.onSustitutosChanged != null) {
      widget.onSustitutosChanged!(list);
    }
  }

  void _notify() => widget.onChanged(_serialize());

  List<Map<String, dynamic>> _serialize() {
    final dec = getDecimalsFromD(widget.divMin);
    return List.generate(_pesasCtrls.length, (i) {
      final p = _parseDouble(_pesasCtrls[i].text);
      final a = _parseDouble(_aguaCtrls[i].text);
      double? ap = _parseDouble(_aguaPesasCtrls[i].text);
      if (ap == null && (p != null || a != null)) {
        ap = (p ?? 0.0) + (a ?? 0.0);
      }
      final ind = _parseDouble(_indicacionCtrls[i].text);
      double? err;
      if (ind != null && ap != null) {
        err = ind - ap; // ERROR = INDICACIÓN - (AGUA + PESAS)
      }

      return {
        'punto_id': i + 1,
        'pesas': _pesasCtrls[i].text.trim(),
        'agua': _aguaCtrls[i].text.trim(),
        'agua_pesas': _aguaPesasCtrls[i].text.trim(),
        'indicacion': _indicacionCtrls[i].text.trim(),
        'regreso': _regresoCtrls[i].text.trim(),
        'error': err != null ? (dec > 0 ? err.toStringAsFixed(dec) : err.round().toString()) : null,
        // Compatibilidad con campos estándar
        'valor_nominal': ap != null ? (dec > 0 ? ap.toStringAsFixed(dec) : ap.round().toString()) : _pesasCtrls[i].text.trim(),
        'lectura_inicial': _indicacionCtrls[i].text.trim(),
        'lectura_final': _regresoCtrls[i].text.trim(),
      };
    });
  }

  double _calcularMaxError() {
    double maxErr = 0;
    for (int i = 0; i < _pesasCtrls.length; i++) {
      final p = _parseDouble(_pesasCtrls[i].text);
      final a = _parseDouble(_aguaCtrls[i].text);
      double? ap = _parseDouble(_aguaPesasCtrls[i].text);
      if (ap == null && (p != null || a != null)) {
        ap = (p ?? 0.0) + (a ?? 0.0);
      }
      final ind = _parseDouble(_indicacionCtrls[i].text);
      if (ind != null && ap != null) {
        final err = (ind - ap).abs();
        if (err > maxErr) maxErr = err;
      }
    }
    return maxErr;
  }

  double _calcularTotalSustituto() {
    double tot = 0;
    for (final c in _sustPesoCtrls) {
      final v = _parseDouble(c.text);
      if (v != null && v > 0) tot += v;
    }
    return tot;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final fns in _rowFocusNodes) {
      for (final fn in fns) {
        fn.dispose();
      }
    }
    for (final c in [..._pesasCtrls, ..._aguaCtrls, ..._aguaPesasCtrls, ..._indicacionCtrls, ..._regresoCtrls]) {
      c.dispose();
    }
    for (final c in [..._sustNombreCtrls, ..._sustPesoCtrls]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxErr = _calcularMaxError();
    final dec = getDecimalsFromD(widget.divMin);
    final maxErrStr = formatoMilesEspacio(dec > 0 ? maxErr.toStringAsFixed(dec) : maxErr.round().toString());
    final totalSustituto = _calcularTotalSustituto();

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Card de Cargas de Sustitución (Sustituto / Peso) ──
          if (widget.onSustitutosChanged != null || _sustitutosList.isNotEmpty) ...[
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.layers, size: 20, color: _kRed),
                        const SizedBox(width: 8),
                        const Text(
                          'MATERIALES / PESOS SUSTITUTOS',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _kRed, letterSpacing: 0.5),
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: _addSustituto,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Agregar sustituto', style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD9E2F3),
                            foregroundColor: const Color(0xFF1D4ED8),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Si no se capturan sustitutos con peso > 0, este recuadro se oculta y elimina automáticamente del PDF final.',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 10),
                    if (_sustNombreCtrls.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Text(
                          'No hay sustitutos registrados. Presiona "+ Agregar sustituto" para capturar materiales.',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                        ),
                      )
                    else ...[
                      Table(
                        border: TableBorder.all(color: Colors.grey.shade300, width: 0.5),
                        columnWidths: const {
                          0: FlexColumnWidth(2.5),
                          1: FlexColumnWidth(2.0),
                          2: FlexColumnWidth(0.8),
                        },
                        children: [
                          const TableRow(
                            decoration: BoxDecoration(color: Color(0xFFD9E2F3)),
                            children: [
                              Padding(padding: EdgeInsets.all(8), child: Text('SUSTITUTO', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.black))),
                              Padding(padding: EdgeInsets.all(8), child: Text('PESO', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.black))),
                              Padding(padding: EdgeInsets.all(8), child: Text('ACCIONES', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.black))),
                            ],
                          ),
                          for (int i = 0; i < _sustNombreCtrls.length; i++)
                            TableRow(
                              decoration: BoxDecoration(color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9)),
                              children: [
                                _sustInput(_sustNombreCtrls[i], hint: 'Ej. Agua 1, Bloque A', isNum: false),
                                _sustInput(_sustPesoCtrls[i], hint: '0.00', isNum: true),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                  onPressed: () => _removeSustituto(i),
                                  tooltip: 'Eliminar',
                                ),
                              ],
                            ),
                          TableRow(
                            decoration: const BoxDecoration(color: Color(0xFFF3F4F6)),
                            children: [
                              const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text('TOTAL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black)),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  formatoMilesEspacio(dec > 0 ? totalPesoStr(dec, totalSustituto) : totalSustituto.round().toString()),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _kRed),
                                ),
                              ),
                              const SizedBox.shrink(),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],

          // ── Card Tabla Exactitud con Cargas de Sustitución ──
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        'EXACTITUD — CARGAS DE SUSTITUCIÓN',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _kRed, letterSpacing: 0.5),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        onPressed: _addPoint,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Agregar punto', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kRed,
                          foregroundColor: Colors.white,
                          elevation: 1,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 760,
                      child: Table(
                        border: TableBorder.all(color: Colors.grey.shade300, width: 0.5),
                        columnWidths: const {
                          0: FlexColumnWidth(0.5), // N
                          1: FlexColumnWidth(1.2), // PESAS
                          2: FlexColumnWidth(1.2), // AGUA
                          3: FlexColumnWidth(1.4), // AGUA + PESAS
                          4: FlexColumnWidth(1.3), // INDICACIÓN
                          5: FlexColumnWidth(1.2), // REGRESO
                          6: FlexColumnWidth(1.1), // ERROR
                          7: FlexColumnWidth(0.5), // ACCIONES
                        },
                        children: [
                          _hdr(['N', 'PESAS', 'AGUA', 'AGUA + PESAS', 'INDICACIÓN', 'REGRESO', 'ERROR', '']),
                          for (int i = 0; i < _pesasCtrls.length; i++) _row(i),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Footer con Error Máximo Encontrado
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'ERROR MÁXIMO ENCONTRADO:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black87),
                        ),
                        const Spacer(),
                        Text(
                          maxErrStr,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            color: maxErr > 0 ? _kRed : Colors.green.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.footer != null) ...[const SizedBox(height: 20), widget.footer!],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String totalPesoStr(int dec, double val) => val.toStringAsFixed(dec);

  TableRow _hdr(List<String> l) => TableRow(
        decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
        children: l
            .map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Text(
                    s,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ))
            .toList(),
      );

  TableRow _row(int i) {
    final p = _parseDouble(_pesasCtrls[i].text);
    final a = _parseDouble(_aguaCtrls[i].text);
    double? ap = _parseDouble(_aguaPesasCtrls[i].text);
    if (ap == null && (p != null || a != null)) {
      ap = (p ?? 0.0) + (a ?? 0.0);
    }
    final ind = _parseDouble(_indicacionCtrls[i].text);

    double? err;
    if (ind != null && ap != null) {
      err = ind - ap; // ERROR = INDICACIÓN - (AGUA + PESAS)
    }

    final dec = getDecimalsFromD(widget.divMin);
    final errStr = err != null
        ? formatoMilesEspacio(dec > 0 ? err.toStringAsFixed(dec) : err.round().toString())
        : '—';

    final key = i < _rowKeys.length ? _rowKeys[i] : null;
    final fns = i < _rowFocusNodes.length ? _rowFocusNodes[i] : null;

    return TableRow(
      decoration: BoxDecoration(color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9)),
      children: [
        Container(
          key: key,
          padding: const EdgeInsets.all(8),
          child: Text('${i + 1}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11)),
        ),
        _input(_pesasCtrls[i], focusNode: fns != null ? fns[0] : null, onTap: () => _scrollToRow(i)),
        _input(_aguaCtrls[i], focusNode: fns != null ? fns[1] : null, onTap: () => _scrollToRow(i)),
        _input(_aguaPesasCtrls[i], hint: 'Auto', focusNode: fns != null ? fns[2] : null, onTap: () => _scrollToRow(i)),
        _input(_indicacionCtrls[i], focusNode: fns != null ? fns[3] : null, onTap: () => _scrollToRow(i)),
        _input(_regresoCtrls[i], focusNode: fns != null ? fns[4] : null, onTap: () => _scrollToRow(i)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            errStr,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 11,
              color: err != null ? (err.abs() > (widget.divMin ?? 0) * 3 ? _kRed : Colors.green.shade700) : Colors.black87,
            ),
          ),
        ),
        if (_pesasCtrls.length > 5)
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 16, color: Colors.grey),
            onPressed: () => _removePoint(i),
            tooltip: 'Eliminar punto',
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  Widget _input(
    TextEditingController c, {
    String? hint,
    FocusNode? focusNode,
    VoidCallback? onTap,
  }) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SizedBox(
          height: 30,
          child: TextField(
            controller: c,
            focusNode: focusNode,
            onTap: onTap,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 10, color: Colors.grey.shade400),
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

  Widget _sustInput(TextEditingController c, {required String hint, required bool isNum}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SizedBox(
          height: 32,
          child: TextField(
            controller: c,
            textAlign: isNum ? TextAlign.right : TextAlign.left,
            keyboardType: isNum ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
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
