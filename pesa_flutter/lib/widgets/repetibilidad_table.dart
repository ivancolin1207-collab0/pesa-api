// lib/widgets/repetibilidad_table.dart — Tabla táctil de Repetibilidad
// v3.0: Carga única propagada + validación estricta de división mínima (d)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';
import '../theme/pesa_theme.dart';

class RepetibilidadTable extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  /// División mínima en kg — controla decimales y validación de múltiplos
  final double? divMin;
  /// Widget opcional al final de la tabla (ej. botón de avance)
  final Widget? footer;

  const RepetibilidadTable({
    super.key,
    required this.rows,
    required this.onChanged,
    this.divMin,
    this.footer,
  });

  @override
  State<RepetibilidadTable> createState() => _RepetibilidadTableState();
}

class _RepetibilidadTableState extends State<RepetibilidadTable>
    with AutomaticKeepAliveClientMixin {
  late TextEditingController _cargaCtrl;
  late List<_RepRow> _rows;
  bool _userEditedCarga = false;

  @override
  bool get wantKeepAlive => true; // Evita destrucción al cambiar de pestaña

  @override
  void initState() {
    super.initState();
    // Extraer carga única previa si existe
    String cargaPrevia = '';
    if (widget.rows.isNotEmpty) {
      final v = widget.rows.first['valor'] ?? widget.rows.first['valor_kg'];
      if (v != null && v.toString().isNotEmpty) {
        final dVal = double.tryParse(v.toString().replaceAll(',', '.'));
        cargaPrevia = (dVal != null) ? formatearCargaSugerida(dVal, divMin: widget.divMin) : v.toString();
      }
    }

    _cargaCtrl = TextEditingController(text: cargaPrevia);

    // 3 repeticiones estándar
    _rows = List.generate(3, (i) {
      final saved = i < widget.rows.length ? widget.rows[i] : null;
      return _RepRow(
        inicialCtrl: TextEditingController(
            text: formatMetrologicalString(saved?['lectura_inicial'], widget.divMin)),
        finalCtrl: TextEditingController(
            text: formatMetrologicalString(saved?['lectura_final'], widget.divMin)),
      );
    });
  }

  @override
  void didUpdateWidget(RepetibilidadTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_userEditedCarga) return;

    if (widget.rows.isNotEmpty) {
      final v = widget.rows.first['valor'] ?? widget.rows.first['valor_kg'];
      if (v != null && v.toString().isNotEmpty) {
        final dVal = double.tryParse(v.toString().replaceAll(',', '.'));
        if (dVal != null) {
          final formatted = formatearCargaSugerida(dVal, divMin: widget.divMin);
          if (_cargaCtrl.text.trim() != formatted &&
              (_cargaCtrl.text.trim().isEmpty || _cargaCtrl.text == '0' || _cargaCtrl.text == '0.0')) {
            _cargaCtrl.text = formatted;
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _cargaCtrl.dispose();
    for (final r in _rows) {
      r.inicialCtrl.dispose();
      r.finalCtrl.dispose();
    }
    super.dispose();
  }

  void _notify() => widget.onChanged(_serialize());

  List<Map<String, dynamic>> _serialize() {
    final cleanCarga = _cargaCtrl.text.trim().replaceAll(',', '.');
    final carga = double.tryParse(cleanCarga) ?? 0.0;
    final dec = decimalsFromDivMin(widget.divMin);

    return _rows.asMap().entries.map((e) {
      final iniRaw = e.value.inicialCtrl.text.trim().replaceAll(',', '.');
      final finRaw = e.value.finalCtrl.text.trim().replaceAll(',', '.');
      final ini = double.tryParse(iniRaw);
      final fin = double.tryParse(finRaw);
      double? error;
      if (fin != null) {
        error = fin - carga;
      }
      return {
        'posicion_id':    e.key + 1,
        'valor':          carga,
        'valor_kg':       carga,
        'lectura_inicial': ini,
        'lectura_final':  fin,
        'error':          error,
        'decimales':      dec,
        'valido_d':       isValidDivMin(carga, widget.divMin) &&
                          (ini == null || isValidDivMin(ini, widget.divMin)) &&
                          isValidDivMin(fin, widget.divMin),
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // requerido por AutomaticKeepAliveClientMixin
    final c = PesaColors.of(context);
    final dec = decimalsFromDivMin(widget.divMin);
    final cargaVal = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.'));
    final cargaInvalida = cargaVal != null && !isValidDivMin(cargaVal, widget.divMin);

    // Revisar si hay algún campo inválido en las repeticiones
    bool hayCamposInvalidos = cargaInvalida;
    for (final r in _rows) {
      final ini = double.tryParse(r.inicialCtrl.text.trim().replaceAll(',', '.'));
      final fin = double.tryParse(r.finalCtrl.text.trim().replaceAll(',', '.'));
      if (ini != null && !isValidDivMin(ini, widget.divMin)) hayCamposInvalidos = true;
      if (fin != null && !isValidDivMin(fin, widget.divMin)) hayCamposInvalidos = true;
    }

    final Color errorFill = c.isDark ? const Color(0xFF34181D) : const Color(0xFFFFEBEE);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Campo ÚNICO de Carga de Prueba ─────────────────────────────────
          Card(
            elevation: 0,
            color: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: cargaInvalida ? c.dotRed : c.border,
                width: cargaInvalida ? 1.5 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.fitness_center, color: c.brandAccent, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Carga de Prueba (kg):',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textPrimary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Focus(
                          onFocusChange: (hasFocus) {
                            if (!hasFocus && _cargaCtrl.text.trim().isNotEmpty) {
                              final raw = _cargaCtrl.text.trim().replaceAll(',', '.');
                              final double? n = double.tryParse(raw);
                              if (n != null) {
                                final formatted = formatMetrologicalValue(n, widget.divMin);
                                if (_cargaCtrl.text != formatted) {
                                  _cargaCtrl.text = formatted;
                                }
                              }
                              _notify();
                              if (mounted) setState(() {});
                            }
                          },
                          child: TextField(
                            controller: _cargaCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.next,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))
                            ],
                            textAlign: TextAlign.center,
                            onChanged: (val) {
                              _userEditedCarga = true;
                              final raw = val.trim().replaceAll(',', '.');
                              final double? valor = double.tryParse(raw);
                              if (valor == null) {
                                return;
                              }
                              _notify();
                              if (mounted) setState(() {});
                            },
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: cargaInvalida ? c.dotRed : c.brandAccent,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '0.${'0' * dec}',
                              hintStyle: TextStyle(color: c.textTertiary),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cargaInvalida ? c.dotRed : c.brandAccent,
                                  width: 1.5,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cargaInvalida ? c.dotRed : c.borderStrong,
                                  width: 1.2,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cargaInvalida ? c.dotRed : c.brandAccent,
                                  width: 2,
                                ),
                              ),
                              fillColor: cargaInvalida ? errorFill : (c.isDark ? c.surfaceElevated : c.surface),
                              filled: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Propagada a los 3 puntos\n(d=${widget.divMin ?? '?'})',
                          style: TextStyle(fontSize: 10, color: c.textSecondary),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  if (cargaInvalida)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 32),
                      child: Text(
                        divMinErrorMsg(widget.divMin),
                        style: TextStyle(color: c.dotRed, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Alerta global si hay valores con división mínima incorrecta ───
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

          // ── Tabla de Repeticiones ─────────────────────────────────────────
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'REPETIBILIDAD',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: c.brandAccent,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Captura únicamente lecturas inicial y final',
                        style: TextStyle(fontSize: 10, color: c.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Table(
                    border: TableBorder.all(color: c.border),
                    columnWidths: const {
                      0: FlexColumnWidth(0.8),
                      1: FlexColumnWidth(1.6),
                      2: FlexColumnWidth(1.8),
                      3: FlexColumnWidth(1.8),
                      4: FlexColumnWidth(1.5),
                    },
                    children: [
                      _headerRow(['N', 'CARGA (kg)', 'L. INICIAL', 'L. FINAL', 'ERROR'], c),
                      for (int i = 0; i < _rows.length; i++)
                        _dataRow(i, dec, c),
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

  TableRow _headerRow(List<String> labels, PesaPalette c) => TableRow(
    decoration: BoxDecoration(color: c.isDark ? c.surfaceElevated : const Color(0xFF1C1C1E)),
    children: labels.map((l) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        l,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: c.isDark ? c.textPrimary : Colors.white,
        ),
      ),
    )).toList(),
  );

  TableRow _dataRow(int i, int dec, PesaPalette c) {
    final fin = double.tryParse(_rows[i].finalCtrl.text.trim().replaceAll(',', '.'));
    final carga = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.')) ?? 0.0;
    double? err;
    if (fin != null) {
      err = fin - carga;
    }

    final cargaTxt = _cargaCtrl.text.trim().isNotEmpty ? _cargaCtrl.text.trim() : '—';
    final Color altBg = c.isDark ? const Color(0xFF222226) : const Color(0xFFF9F9F9);

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? c.surface : altBg,
      ),
      children: [
        _cell(Text(
          '${i + 1}',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.textPrimary),
        )),
        // Columna de carga nominal propagada (solo lectura / informativa)
        _cell(
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            child: Text(
              cargaTxt,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: c.textPrimary,
              ),
            ),
          ),
        ),
        _cellInput(_rows[i].inicialCtrl, dec, c, hint: dec == 0 ? '0' : '0.${'0' * dec}'),
        _cellInput(_rows[i].finalCtrl, dec, c, hint: dec == 0 ? '0' : '0.${'0' * dec}'),
        _cell(err == null
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
              )),
      ],
    );
  }

  Widget _cell(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: child,
  );

  Widget _cellInput(TextEditingController ctrl, int dec, PesaPalette c, {String? hint}) {
    final val = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
    final invalido = val != null && !isValidDivMin(val, widget.divMin);
    final Color errorFill = c.isDark ? const Color(0xFF34181D) : const Color(0xFFFFEBEE);

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus && ctrl.text.trim().isNotEmpty) {
            final raw = ctrl.text.trim().replaceAll(',', '.');
            final double? n = double.tryParse(raw);
            if (n != null) {
              final formatted = formatMetrologicalValue(n, widget.divMin);
              if (ctrl.text != formatted) {
                ctrl.text = formatted;
              }
            }
            _notify();
            if (mounted) setState(() {});
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
          onChanged: (val) {
            final raw = val.trim().replaceAll(',', '.');
            final double? valor = double.tryParse(raw);
            if (valor == null) {
              return;
            }
            _notify();
            if (mounted) setState(() {});
          },
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: invalido ? c.dotRed : c.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint ?? '0.${'0' * dec}',
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

class _RepRow {
  final TextEditingController inicialCtrl;
  final TextEditingController finalCtrl;
  _RepRow({
    required this.inicialCtrl,
    required this.finalCtrl,
  });
}