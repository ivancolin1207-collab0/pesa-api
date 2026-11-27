import 'package:flutter/material.dart';
import '../services/metrology_helper.dart';
import '../services/pdf_service.dart';
import '../theme/pesa_theme.dart';

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

    pCtrl.addListener(() => _onPesasOrAguaChanged(_pesasCtrls.indexOf(pCtrl)));
    aCtrl.addListener(() => _onPesasOrAguaChanged(_aguaCtrls.indexOf(aCtrl)));
    apCtrl.addListener(() => _onAguaPesasChanged(_aguaPesasCtrls.indexOf(apCtrl)));
    indCtrl.addListener(() => _onIndicacionChanged(_indicacionCtrls.indexOf(indCtrl)));
    regCtrl.addListener(() => _onRegresoChanged(_regresoCtrls.indexOf(regCtrl)));

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
    if (_isAutoCalculating || i < 0 || i >= _pesasCtrls.length) return;
    _isAutoCalculating = true;

    final p = _parseDouble(_pesasCtrls[i].text);
    final a = _parseDouble(_aguaCtrls[i].text);

    if (p != null || a != null) {
      final ap = (p ?? 0.0) + (a ?? 0.0);
      _aguaPesasCtrls[i].text = formatearErrorSinCeros(ap);
    } else {
      _aguaPesasCtrls[i].text = '';
    }

    _isAutoCalculating = false;
    setState(() {});
    _notify();
  }

  void _onAguaPesasChanged(int i) {
    if (_isAutoCalculating || i < 0 || i >= _aguaPesasCtrls.length) return;
    setState(() {});
    _notify();
  }

  void _onIndicacionChanged(int i) {
    if (_isAutoCalculating || i < 0 || i >= _indicacionCtrls.length) return;
    setState(() {});
    _notify();
  }

  void _onRegresoChanged(int i) {
    if (_isAutoCalculating || i < 0 || i >= _regresoCtrls.length) return;
    setState(() {});
    _notify();
  }

  double? _calcularErrorFila(int i) {
    final p = _parseDouble(_pesasCtrls[i].text);
    final a = _parseDouble(_aguaCtrls[i].text);
    double? ap = _parseDouble(_aguaPesasCtrls[i].text);
    if (p != null && a != null) {
      ap = p + a;
    } else if (ap == null && (p != null || a != null)) {
      ap = (p ?? 0.0) + (a ?? 0.0);
    }
    final ind = _parseDouble(_indicacionCtrls[i].text);
    final reg = _parseDouble(_regresoCtrls[i].text);
    return calcularErrorSustitucion(
      pesas: p,
      agua: a,
      indicacion: ind,
      regreso: reg,
      aguaMasPesasOverride: (p != null && a != null) ? null : ap,
    );
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
    return List.generate(_pesasCtrls.length, (i) {
      final p = _parseDouble(_pesasCtrls[i].text);
      final a = _parseDouble(_aguaCtrls[i].text);
      double? ap = _parseDouble(_aguaPesasCtrls[i].text);
      if (p != null && a != null) {
        ap = p + a;
      } else if (ap == null && (p != null || a != null)) {
        ap = (p ?? 0.0) + (a ?? 0.0);
      }
      final err = _calcularErrorFila(i);

      return {
        'punto_id': i + 1,
        'pesas': _pesasCtrls[i].text.trim(),
        'agua': _aguaCtrls[i].text.trim(),
        'agua_pesas': ap != null ? formatearErrorSinCeros(ap) : _aguaPesasCtrls[i].text.trim(),
        'indicacion': _indicacionCtrls[i].text.trim(),
        'regreso': _regresoCtrls[i].text.trim(),
        'error': err != null ? formatearErrorSinCeros(err) : null,
        // Compatibilidad con campos estándar
        'valor_nominal': ap != null ? formatearErrorSinCeros(ap) : _pesasCtrls[i].text.trim(),
        'lectura_inicial': _indicacionCtrls[i].text.trim(),
        'lectura_final': _regresoCtrls[i].text.trim(),
      };
    });
  }

  double _calcularMaxError() {
    double maxErr = 0;
    for (int i = 0; i < _pesasCtrls.length; i++) {
      final err = _calcularErrorFila(i);
      if (err != null) {
        final absErr = err.abs();
        if (absErr > maxErr) maxErr = absErr;
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
    final c = PesaColors.of(context);
    final maxErr = _calcularMaxError();
    final dec = getDecimalsFromD(widget.divMin);
    final maxErrStr = formatoMilesEspacio(formatearErrorSinCeros(maxErr));
    final totalSustituto = _calcularTotalSustituto();
    final Color altBg = c.isDark ? const Color(0xFF222226) : const Color(0xFFF9F9F9);

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
              color: c.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: c.border),
              ),
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.layers, size: 20, color: c.brandAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'MATERIALES / PESOS SUSTITUTOS',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: c.brandAccent, letterSpacing: 0.5),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _addSustituto,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Agregar sustituto', style: TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: c.surfaceElevated,
                            foregroundColor: c.textPrimary,
                            side: BorderSide(color: c.borderStrong),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Si no se capturan sustitutos con peso > 0, este recuadro se oculta y elimina automáticamente del PDF final.',
                      style: TextStyle(fontSize: 11, color: c.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    if (_sustNombreCtrls.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: c.border),
                        ),
                        child: Text(
                          'No hay sustitutos registrados. Presiona "+ Agregar sustituto" para capturar materiales.',
                          style: TextStyle(fontSize: 12, color: c.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else ...[
                      Table(
                        border: TableBorder.all(color: c.border, width: 0.8),
                        columnWidths: const {
                          0: FlexColumnWidth(2.5),
                          1: FlexColumnWidth(2.0),
                          2: FlexColumnWidth(0.8),
                        },
                        children: [
                          TableRow(
                            decoration: BoxDecoration(color: c.surfaceElevated),
                            children: [
                              Padding(padding: const EdgeInsets.all(8), child: Text('SUSTITUTO', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c.textPrimary))),
                              Padding(padding: const EdgeInsets.all(8), child: Text('PESO', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c.textPrimary))),
                              Padding(padding: const EdgeInsets.all(8), child: Text('ACCIONES', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c.textPrimary))),
                            ],
                          ),
                          for (int i = 0; i < _sustNombreCtrls.length; i++)
                            TableRow(
                              decoration: BoxDecoration(color: i % 2 == 0 ? c.surface : altBg),
                              children: [
                                _sustInput(_sustNombreCtrls[i], c, hint: 'Ej. Agua 1, Bloque A', isNum: false),
                                _sustInput(_sustPesoCtrls[i], c, hint: '0.00', isNum: true),
                                IconButton(
                                  icon: Icon(Icons.delete_outline, size: 18, color: c.dotRed),
                                  onPressed: () => _removeSustituto(i),
                                  tooltip: 'Eliminar',
                                ),
                              ],
                            ),
                          TableRow(
                            decoration: BoxDecoration(color: c.surfaceElevated),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text('TOTAL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: c.textPrimary)),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  formatoMilesEspacio(dec > 0 ? totalPesoStr(dec, totalSustituto) : totalSustituto.round().toString()),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.brandAccent),
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
            color: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: c.border),
            ),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'EXACTITUD — CARGAS DE SUSTITUCIÓN',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: c.brandAccent, letterSpacing: 0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _addPoint,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Agregar punto', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kRed,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: Table(
                      border: TableBorder.all(color: c.border, width: 0.8),
                      columnWidths: const {
                        0: FlexColumnWidth(0.8), // N
                        1: FlexColumnWidth(2.0), // PESAS
                        2: FlexColumnWidth(2.0), // AGUA
                        3: FlexColumnWidth(2.0), // AGUA + PESAS
                        4: FlexColumnWidth(2.0), // INDICACIÓN
                        5: FlexColumnWidth(2.0), // REGRESO
                        6: FlexColumnWidth(1.8), // ERROR
                        7: FlexColumnWidth(0.6), // ACCIONES
                      },
                      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                      children: [
                        _hdr(['N', 'PESAS', 'AGUA', 'AGUA + PESAS', 'INDICACIÓN', 'REGRESO', 'ERROR', ''], c),
                        for (int i = 0; i < _pesasCtrls.length; i++) _row(i, c),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Footer con Error Máximo Encontrado
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: c.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        Text(
                          'ERROR MÁXIMO ENCONTRADO:',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.textPrimary),
                        ),
                        const Spacer(),
                        Text(
                          maxErrStr,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            color: maxErr > 0 ? c.brandAccent : c.dotGreen,
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

  TableRow _hdr(List<String> l, PesaPalette c) => TableRow(
        decoration: BoxDecoration(color: c.isDark ? c.surfaceElevated : const Color(0xFF1C1C1E)),
        children: l
            .map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Text(
                    s,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c.isDark ? c.textPrimary : Colors.white),
                  ),
                ))
            .toList(),
      );

  TableRow _row(int i, PesaPalette c) {
    final err = _calcularErrorFila(i);
    final errStr = err != null
        ? formatoMilesEspacio(formatearErrorSinCeros(err))
        : '—';

    final key = i < _rowKeys.length ? _rowKeys[i] : null;
    final fns = i < _rowFocusNodes.length ? _rowFocusNodes[i] : null;
    final Color altBg = c.isDark ? const Color(0xFF222226) : const Color(0xFFF9F9F9);

    return TableRow(
      decoration: BoxDecoration(color: i % 2 == 0 ? c.surface : altBg),
      children: [
        Container(
          key: key,
          padding: const EdgeInsets.all(8),
          alignment: Alignment.center,
          child: Text('${i + 1}', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.textPrimary)),
        ),
        _input(_pesasCtrls[i], c, focusNode: fns != null ? fns[0] : null, onTap: () => _scrollToRow(i)),
        _input(_aguaCtrls[i], c, focusNode: fns != null ? fns[1] : null, onTap: () => _scrollToRow(i)),
        _input(_aguaPesasCtrls[i], c, hint: 'Auto', focusNode: fns != null ? fns[2] : null, onTap: () => _scrollToRow(i)),
        _input(_indicacionCtrls[i], c, focusNode: fns != null ? fns[3] : null, onTap: () => _scrollToRow(i)),
        _input(_regresoCtrls[i], c, focusNode: fns != null ? fns[4] : null, onTap: () => _scrollToRow(i)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            errStr,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: err != null ? (err.abs() > 0 ? c.brandAccent : c.dotGreen) : c.textSecondary,
            ),
          ),
        ),
        if (_pesasCtrls.length > 5)
          IconButton(
            icon: Icon(Icons.remove_circle_outline, size: 18, color: c.textSecondary),
            onPressed: () => _removePoint(i),
            tooltip: 'Eliminar punto',
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  Widget _input(
    TextEditingController ctrl,
    PesaPalette c, {
    String? hint,
    FocusNode? focusNode,
    VoidCallback? onTap,
  }) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SizedBox(
          height: 38,
          child: TextField(
            controller: ctrl,
            focusNode: focusNode,
            onTap: onTap,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 11, color: c.textTertiary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              filled: true,
              fillColor: c.isDark ? c.surfaceElevated : c.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.borderStrong)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.borderStrong)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.brandAccent, width: 1.5)),
            ),
          ),
        ),
      );

  Widget _sustInput(TextEditingController ctrl, PesaPalette c, {required String hint, required bool isNum}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SizedBox(
          height: 32,
          child: TextField(
            controller: ctrl,
            textAlign: isNum ? TextAlign.right : TextAlign.left,
            keyboardType: isNum ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 11, color: c.textTertiary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              filled: true,
              fillColor: c.isDark ? c.surfaceElevated : c.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: c.borderStrong)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: c.borderStrong)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: c.brandAccent, width: 1.5)),
            ),
          ),
        ),
      );
}
