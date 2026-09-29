// lib/widgets/excentricidad_table.dart — Tabla táctil de Excentricidad
// v3.2: Secciones dinámicas (+/- Sección para Camionera/Ferrocarril) + Cálculo tolerante de Error (L. Inicial ?? 0)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';

const _kRed = Color(0xFFC8102E);

class ExcentricidadTable extends StatefulWidget {
  final int numCeldas;
  final int? numSecciones;
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  /// División mínima en kg — controla decimales y validación de múltiplos
  final double? divMin;
  /// Tipo de geometría: 'circular', 'camionera', o 'plataforma' (rectangular/cuadrada)
  final String? geometria;
  /// Tipo de instrumento para inferencia adicional si la geometría no está definida
  final String? tipoInstrumento;
  /// Si Logística definió que aplica o no excentricidad
  final bool aplicaExcentricidad;

  const ExcentricidadTable({
    super.key,
    required this.numCeldas,
    this.numSecciones,
    required this.rows,
    required this.onChanged,
    this.divMin,
    this.geometria,
    this.tipoInstrumento,
    this.aplicaExcentricidad = true,
  });

  @override
  State<ExcentricidadTable> createState() => _ExcentricidadTableState();
}

class _ExcentricidadTableState extends State<ExcentricidadTable> {
  late int _numPos;
  late List<String> _posLabels;
  late TextEditingController _cargaCtrl;
  late List<TextEditingController> _inicialCtrls;
  late List<TextEditingController> _finalCtrls;
  bool _userEditedCarga = false;

  bool get _isCamioneraOrFerro {
    final geo = (widget.geometria ?? '').toLowerCase();
    final tipo = (widget.tipoInstrumento ?? '').toLowerCase();
    return geo.contains('camionera') ||
        tipo.contains('camionera') ||
        geo.contains('ferrocarril') ||
        tipo.contains('ferrocarril') ||
        geo.contains('puente') ||
        tipo.contains('puente') ||
        geo.contains('ferrovi') ||
        tipo.contains('ferrovi');
  }

  @override
  void initState() {
    super.initState();
    _determinarPosiciones();

    // Carga de Prueba: único campo global
    String cargaInicial = '';
    if (widget.rows.isNotEmpty) {
      final c = widget.rows.first['carga'];
      if (c != null && c.toString().isNotEmpty) {
        final dVal = double.tryParse(c.toString().replaceAll(',', '.'));
        cargaInicial = (dVal != null) ? formatearCargaSugerida(dVal, divMin: widget.divMin) : c.toString();
      }
    }
    _cargaCtrl = TextEditingController(text: cargaInicial);

    // Lecturas iniciales y finales (una por posición)
    _inicialCtrls = List.generate(_numPos, (i) => TextEditingController(
        text: i < widget.rows.length
            ? widget.rows[i]['lectura_inicial']?.toString() ?? ''
            : ''));

    _finalCtrls = List.generate(_numPos, (i) => TextEditingController(
        text: i < widget.rows.length
            ? widget.rows[i]['lectura_final']?.toString() ?? ''
            : ''));
  }

  @override
  void didUpdateWidget(ExcentricidadTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si el técnico ya interactuó o editó la carga de prueba, NUNCA sobreescribir ni resetear
    if (_userEditedCarga) return;

    if (widget.rows.isNotEmpty) {
      final c = widget.rows.first['carga'];
      if (c != null && c.toString().isNotEmpty) {
        final dVal = double.tryParse(c.toString().replaceAll(',', '.'));
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

  void _determinarPosiciones() {
    final geo = (widget.geometria ?? '').toLowerCase();
    final tipo = (widget.tipoInstrumento ?? '').toLowerCase();
    final bool isCam = _isCamioneraOrFerro;
    final bool isCircular = geo.contains('circular') || tipo.contains('circular');

    if (isCam) {
      int sec = widget.rows.length;
      if (sec < 2) {
        sec = widget.numSecciones ?? 0;
        if (sec <= 0 && widget.numCeldas > 0) sec = widget.numCeldas ~/ 2;
        if (sec < 4) sec = 4; // Por defecto exactamente 4 secciones (Sección 1 a 4)
      }
      _numPos = sec.clamp(2, 50);
      _posLabels = List.generate(_numPos, (i) => 'Sección ${i + 1}');
    } else if (isCircular) {
      _numPos = 5;
      _posLabels = const ['Centro', 'Lado 1', 'Lado 2', 'Lado 3', 'Lado 4'];
    } else {
      // Plataforma Cuadrada / Rectangular
      _numPos = 5;
      _posLabels = const ['Centro', 'Esquina 1', 'Esquina 2', 'Esquina 3', 'Esquina 4'];
    }
  }

  void _agregarSeccion() {
    setState(() {
      _numPos++;
      _posLabels.add('Sección $_numPos');
      _inicialCtrls.add(TextEditingController());
      _finalCtrls.add(TextEditingController());
    });
    _notify();
  }

  void _eliminarSeccion() {
    if (_numPos <= 2) return;
    setState(() {
      _numPos--;
      _posLabels.removeLast();
      final initC = _inicialCtrls.removeLast();
      initC.dispose();
      final finC = _finalCtrls.removeLast();
      finC.dispose();
    });
    _notify();
  }

  @override
  void dispose() {
    _cargaCtrl.dispose();
    for (final c in _inicialCtrls) {
      c.dispose();
    }
    for (final c in _finalCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _notify() => widget.onChanged(_serialize());

  List<Map<String, dynamic>> _serialize() {
    final cleanCarga = _cargaCtrl.text.trim().replaceAll(',', '.');
    final carga = double.tryParse(cleanCarga) ?? 0.0;
    final dec = decimalsFromDivMin(widget.divMin);

    return List.generate(_numPos, (i) {
      final iniText = i < _inicialCtrls.length ? _inicialCtrls[i].text.trim().replaceAll(',', '.') : '';
      final finText = i < _finalCtrls.length ? _finalCtrls[i].text.trim().replaceAll(',', '.') : '';
      final ini = double.tryParse(iniText);
      final fin = double.tryParse(finText);
      double? error;
      if (fin != null) {
        error = fin - carga;
      }
      return {
        'posicion_id':     i + 1,
        'posicion_nombre': i < _posLabels.length ? _posLabels[i] : 'Sección ${i + 1}',
        'carga':           carga,
        'lectura_inicial': ini,
        'lectura_final':   fin,
        'error':           error,
        'decimales':       dec,
        'valido_d':        isValidDivMin(carga, widget.divMin) &&
                           (ini == null || isValidDivMin(ini, widget.divMin)) &&
                           isValidDivMin(fin, widget.divMin),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.aplicaExcentricidad) {
      return Center(
        child: Card(
          elevation: 0,
          color: Colors.orange.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.orange.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block, size: 48, color: Colors.orange.shade700),
                const SizedBox(height: 12),
                const Text(
                  'Prueba de Excentricidad No Aplica',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1D1D1F),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Logística o el tipo de instrumento definió que esta prueba no es requerida.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final dec = decimalsFromDivMin(widget.divMin);
    final cargaVal = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.'));
    final cargaInvalida = cargaVal != null && !isValidDivMin(cargaVal, widget.divMin);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Campo Único: Carga de Prueba (kg) ─────────────────────────────
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
                      const Icon(Icons.scale_outlined, color: _kRed, size: 20),
                      const SizedBox(width: 12),
                      const Text(
                        'Carga de Prueba (kg):',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1D1D1F),
                        ),
                      ),
                      const Spacer(),
                      if (widget.divMin != null)
                        Text(
                          'd = ${widget.divMin} ($dec decimales)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Focus(
                    onFocusChange: (hasFocus) {
                      if (!hasFocus && _cargaCtrl.text.trim().isNotEmpty) {
                        final raw = _cargaCtrl.text.trim().replaceAll(',', '.');
                        final double? n = double.tryParse(raw);
                        if (n != null) {
                          final formatted = n.toStringAsFixed(dec);
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
                        fontWeight: FontWeight.bold,
                        color: cargaInvalida ? Colors.red : const Color(0xFF1D1D1F),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '0.${'0' * dec}',
                        hintStyle: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: cargaInvalida ? Colors.red : Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: cargaInvalida ? Colors.red : Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: cargaInvalida ? Colors.red : _kRed, width: 2),
                        ),
                        fillColor: cargaInvalida ? const Color(0xFFFFEBEE) : Colors.white,
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                  if (cargaInvalida) ...[
                    const SizedBox(height: 6),
                    Text(
                      divMinErrorMsg(widget.divMin),
                      style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Tabla de Posiciones ───────────────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        'EXCENTRICIDAD',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: _kRed,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Error = (L. Final - L. Inicial) - Carga',
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Table(
                    border: TableBorder.all(color: Colors.grey.shade200),
                    columnWidths: const {
                      0: FlexColumnWidth(1.6),
                      1: FlexColumnWidth(1.8),
                      2: FlexColumnWidth(1.8),
                      3: FlexColumnWidth(1.5),
                    },
                    children: [
                      _hdr(['POSICIÓN', 'L. INICIAL', 'L. FINAL', 'ERROR']),
                      for (int i = 0; i < _numPos; i++)
                        _row(i, _posLabels, dec),
                    ],
                  ),

                  // ── Controles de Secciones Dinámicas para Camionera / Ferrocarril ─
                  if (_isCamioneraOrFerro) ...[
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (_numPos > 2)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.shade700,
                              side: BorderSide(color: Colors.red.shade200),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            ),
                            icon: const Icon(Icons.remove_circle_outline, size: 16),
                            label: const Text('Eliminar Última Sección', style: TextStyle(fontSize: 12)),
                            onPressed: _eliminarSeccion,
                          ),
                        if (_numPos > 2) const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A7F64),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.add_circle_outline, size: 16),
                          label: const Text('+ Agregar Sección',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: _agregarSeccion,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  TableRow _hdr(List<String> labels) => TableRow(
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

  TableRow _row(int i, List<String> posLabels, int dec) {
    final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
    final carga = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.')) ?? 0.0;

    double? err;
    if (fin != null) {
      err = fin - carga;
    }

    final posLabel = i < posLabels.length ? posLabels[i] : 'Sección ${i + 1}';

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? Colors.white : const Color(0xFFF9F9F9),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(
            posLabel,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
        _inputField(_inicialCtrls[i], dec),
        _inputField(_finalCtrls[i], dec),
        Padding(
          padding: const EdgeInsets.all(4),
          child: err == null
              ? const Center(
                  child: Text('—', style: TextStyle(color: Colors.grey, fontSize: 12)))
              : Text(
                  err.toStringAsFixed(dec),
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

  Widget _inputField(TextEditingController c, int dec) {
    final val = double.tryParse(c.text.trim().replaceAll(',', '.'));
    final invalido = val != null && !isValidDivMin(val, widget.divMin);

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus && c.text.trim().isNotEmpty) {
            final raw = c.text.trim().replaceAll(',', '.');
            final double? n = double.tryParse(raw);
            if (n != null) {
              final formatted = n.toStringAsFixed(dec);
              if (c.text != formatted) {
                c.text = formatted;
              }
            }
            _notify();
            if (mounted) setState(() {});
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
            hintText: '0.${'0' * dec}',
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