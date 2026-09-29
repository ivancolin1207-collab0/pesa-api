// lib/widgets/repetibilidad_table.dart — Tabla táctil de Repetibilidad
// v3.0: Carga única propagada + validación estricta de división mínima (d)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';

const _kRed = Color(0xFFC8102E);

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

class _RepetibilidadTableState extends State<RepetibilidadTable> {
  late TextEditingController _cargaCtrl;
  late List<_RepRow> _rows;
  bool _userEditedCarga = false;

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

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Campo ÚNICO de Carga de Prueba ─────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: cargaInvalida ? Colors.red : Colors.grey.shade200,
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
                      const Icon(Icons.fitness_center, color: _kRed, size: 20),
                      const SizedBox(width: 12),
                      const Text(
                        'Carga de Prueba (kg):',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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
                                // No calcular ni romper, dejar en estado transitorio
                                return;
                              }
                              _notify();
                              if (mounted) setState(() {});
                            },
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: cargaInvalida ? Colors.red : _kRed,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '0.${'0' * dec}',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cargaInvalida ? Colors.red : _kRed,
                                  width: 1.5,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                  color: cargaInvalida ? Colors.red : _kRed,
                                  width: 2,
                                ),
                              ),
                              fillColor: cargaInvalida ? const Color(0xFFFFEBEE) : Colors.white,
                              filled: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Propagada a los 3 puntos\n(d=${widget.divMin ?? '?'})',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                  if (cargaInvalida)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 32),
                      child: Text(
                        divMinErrorMsg(widget.divMin),
                        style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w600),
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

          // ── Tabla de Repeticiones ─────────────────────────────────────────
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text(
                        'REPETIBILIDAD',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: _kRed,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Captura únicamente lecturas inicial y final',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Table(
                    border: TableBorder.all(color: Colors.grey.shade200),
                    columnWidths: const {
                      0: FlexColumnWidth(0.8),
                      1: FlexColumnWidth(1.6),
                      2: FlexColumnWidth(1.8),
                      3: FlexColumnWidth(1.8),
                      4: FlexColumnWidth(1.5),
                    },
                    children: [
                      _headerRow(['N', 'CARGA (kg)', 'L. INICIAL', 'L. FINAL', 'ERROR']),
                      for (int i = 0; i < _rows.length; i++)
                        _dataRow(i, dec),
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

  TableRow _headerRow(List<String> labels) => TableRow(
    decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
    children: labels.map((l) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        l,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    )).toList(),
  );

  TableRow _dataRow(int i, int dec) {
    final fin = double.tryParse(_rows[i].finalCtrl.text.trim().replaceAll(',', '.'));
    final carga = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.')) ?? 0.0;
    double? err;
    if (fin != null) {
      err = fin - carga;
    }

    final cargaTxt = _cargaCtrl.text.trim().isNotEmpty ? _cargaCtrl.text.trim() : '—';

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9),
      ),
      children: [
        _cell(Text(
          '${i + 1}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        )),
        // Columna de carga nominal propagada (solo lectura / informativa)
        _cell(
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            child: Text(
              cargaTxt,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Color(0xFF1D1D1F),
              ),
            ),
          ),
        ),
        _cellInput(_rows[i].inicialCtrl, dec, hint: dec == 0 ? '0' : '0.${'0' * dec}'),
        _cellInput(_rows[i].finalCtrl, dec, hint: dec == 0 ? '0' : '0.${'0' * dec}'),
        _cell(err == null
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
              )),
      ],
    );
  }

  Widget _cell(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: child,
  );

  Widget _cellInput(TextEditingController ctrl, int dec, {String? hint}) {
    final val = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
    final invalido = val != null && !isValidDivMin(val, widget.divMin);

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
              // No calcular ni romper, dejar en estado transitorio
              return;
            }
            _notify();
            if (mounted) setState(() {});
          },
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: invalido ? Colors.red : Colors.black87,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint ?? '0.${'0' * dec}',
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

class _RepRow {
  final TextEditingController inicialCtrl;
  final TextEditingController finalCtrl;
  _RepRow({
    required this.inicialCtrl,
    required this.finalCtrl,
  });
}