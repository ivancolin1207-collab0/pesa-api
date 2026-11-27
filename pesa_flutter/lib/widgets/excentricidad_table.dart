// lib/widgets/excentricidad_table.dart — Tabla táctil de Excentricidad
// v3.2: Secciones dinámicas (+/- Sección para Camionera/Ferrocarril) + Cálculo tolerante de Error (L. Inicial ?? 0)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/metrology_helper.dart';
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';

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
  /// Tipo de instrumento no apto seleccionado ('Grúa', 'Patín', 'Tanque', 'Tolva', 'Silo')
  final String? motivoNoExcentricidad;
  /// Callback cuando el técnico selecciona el motivo/instrumento no apto
  final ValueChanged<String>? onMotivoNoChanged;
  /// Callback cuando el técnico cambia la geometría
  final ValueChanged<String>? onGeometriaChanged;
  /// Callback cuando el técnico cambia el número de secciones (camionera)
  final ValueChanged<int>? onNumSeccionesChanged;

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
    this.motivoNoExcentricidad,
    this.onMotivoNoChanged,
    this.onGeometriaChanged,
    this.onNumSeccionesChanged,
  });

  @override
  State<ExcentricidadTable> createState() => _ExcentricidadTableState();
}

class _ExcentricidadTableState extends State<ExcentricidadTable>
    with AutomaticKeepAliveClientMixin {
  late String _geometriaActual;
  late int _numPos;
  late List<String> _posLabels;
  late TextEditingController _cargaCtrl;
  late List<TextEditingController> _inicialCtrls;
  late List<TextEditingController> _finalCtrls;
  bool _userEditedCarga = false;

  static String _normalizarGeometria(String? geo, String? tipo) {
    if (geo != null && geo.trim().isNotEmpty) {
      final g = geo.toLowerCase().trim();
      if (g.contains('camion') || g.contains('ferro') || g.contains('puente')) return 'Camionera';
      if (g.contains('circ')) return 'Circular';
      if (g.contains('plat') || g.contains('cuad')) return 'Plataforma';
    }
    return getGeometriaPorDefecto(tipo);
  }

  bool get _isCamioneraOrFerro => _geometriaActual == 'Camionera';

  @override
  bool get wantKeepAlive => true; // Evita destrucción al cambiar de pestaña

  @override
  void initState() {
    super.initState();
    _geometriaActual = _normalizarGeometria(widget.geometria, widget.tipoInstrumento);
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
            ? formatMetrologicalString(widget.rows[i]['lectura_inicial'], widget.divMin)
            : ''));

    _finalCtrls = List.generate(_numPos, (i) => TextEditingController(
        text: i < widget.rows.length
            ? formatMetrologicalString(widget.rows[i]['lectura_final'], widget.divMin)
            : ''));
  }

  @override
  void didUpdateWidget(ExcentricidadTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si la geometría del padre cambió explícitamente y es distinta a la actual
    if (widget.geometria != null && widget.geometria != oldWidget.geometria) {
      final norm = _normalizarGeometria(widget.geometria, widget.tipoInstrumento);
      if (norm != _geometriaActual) {
        _geometriaActual = norm;
        _determinarPosiciones();
        _ajustarControladores();
      }
    }

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

  void _onGeometriaSelected(String nuevaGeo) {
    if (_geometriaActual == nuevaGeo) return;
    setState(() {
      _geometriaActual = nuevaGeo;
      _determinarPosiciones();
      _ajustarControladores();
    });
    widget.onGeometriaChanged?.call(_geometriaActual);
    if (_isCamioneraOrFerro) {
      widget.onNumSeccionesChanged?.call(_numPos);
    }
    _notify();
  }

  void _setNumSecciones(int n) {
    if (n == _numPos || n < 2 || n > 50) return;
    setState(() {
      _numPos = n;
      _posLabels = List.generate(_numPos, (i) => 'Sección ${i + 1}');
      _ajustarControladores();
    });
    widget.onNumSeccionesChanged?.call(_numPos);
    _notify();
  }

  void _ajustarControladores() {
    while (_inicialCtrls.length < _numPos) {
      _inicialCtrls.add(TextEditingController());
      _finalCtrls.add(TextEditingController());
    }
    while (_inicialCtrls.length > _numPos) {
      final initC = _inicialCtrls.removeLast();
      initC.dispose();
      final finC = _finalCtrls.removeLast();
      finC.dispose();
    }
  }

  void _determinarPosiciones() {
    if (_isCamioneraOrFerro) {
      int sec = widget.numSecciones ?? 0;
      if (sec <= 0 && widget.rows.length >= 2) sec = widget.rows.length;
      if (sec <= 0 && widget.numCeldas > 0) sec = widget.numCeldas ~/ 2;
      if (sec < 4) sec = 4; // Por defecto exactamente 4 secciones
      _numPos = sec.clamp(2, 50);
      _posLabels = List.generate(_numPos, (i) => 'Sección ${i + 1}');
    } else if (_geometriaActual == 'Circular') {
      _numPos = 5;
      _posLabels = const ['Centro', 'Norte', 'Este', 'Sur', 'Oeste'];
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
    widget.onNumSeccionesChanged?.call(_numPos);
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
    widget.onNumSeccionesChanged?.call(_numPos);
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
      final error = calcularErrorExcentricidad(
        fin: fin,
        ini: ini,
        carga: carga,
        isCamionera: _isCamioneraOrFerro,
      );
      return {
        'posicion_id':     i + 1,
        'posicion_nombre': i < _posLabels.length ? _posLabels[i] : 'Sección ${i + 1}',
        'carga':           carga,
        'lectura_inicial': ini,
        'lectura_final':   fin,
        'error':           error,
        'decimales':       dec,
        'geometria':       _geometriaActual,
        'num_secciones':   _numPos,
        'valido_d':        isValidDivMin(carga, widget.divMin) &&
                           (ini == null || isValidDivMin(ini, widget.divMin)) &&
                           isValidDivMin(fin, widget.divMin),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // requerido por AutomaticKeepAliveClientMixin
    final c = PesaColors.of(context);
    if (!widget.aplicaExcentricidad) {
      final selMotivo = inferirMotivoNoExcentricidad(
        widget.motivoNoExcentricidad,
        widget.tipoInstrumento,
      );
      const opciones = <Map<String, dynamic>>[
        {'key': 'Grúa',   'sub': 'Báscula de grúa / colgante',     'icon': Icons.precision_manufacturing_outlined},
        {'key': 'Patín',  'sub': 'Patín hidráulico / transpaleta', 'icon': Icons.rv_hookup_outlined},
        {'key': 'Tanque', 'sub': 'Báscula tipo tanque',            'icon': Icons.propane_tank_outlined},
        {'key': 'Tolva',  'sub': 'Báscula tipo tolva',             'icon': Icons.filter_alt_outlined},
        {'key': 'Silo',   'sub': 'Báscula tipo silo',              'icon': Icons.factory_outlined},
      ];
      return Padding(
        padding: EdgeInsets.all(isCoverScreen(context) ? 12 : 16),
        child: Card(
          elevation: 0,
          color: c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: c.borderStrong, width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.block, size: 24, color: c.brandAccent),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'NO APLICA PRUEBA DE EXCENTRICIDAD',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Selecciona el tipo de instrumento por el cual no aplica la prueba:',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: opciones.map((opt) {
                    final String k = opt['key'] as String;
                    final String sub = opt['sub'] as String;
                    final IconData ic = opt['icon'] as IconData;
                    final bool active = selMotivo.toLowerCase() == k.toLowerCase();
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => widget.onMotivoNoChanged?.call(k),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: isCoverScreen(context) ? 142 : 154,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: active ? c.surfaceMuted : c.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: active ? c.brandAccent : c.borderStrong,
                            width: active ? 1.8 : 1.0,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(ic, size: 26, color: active ? c.brandAccent : c.textSecondary),
                            const SizedBox(height: 4),
                            Text(
                              k,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: active ? c.brandAccent : c.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 10, color: c.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
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

    final configColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Selector de Geometría de Excentricidad ──────────────────────
        Card(
          elevation: 0,
          color: c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: c.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.architecture_outlined, color: c.brandAccent, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Geometría de Excentricidad',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.surfaceMuted,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.borderStrong),
                      ),
                      child: Text(
                        _isCamioneraOrFerro ? '$_numPos Secciones' : '5 Puntos',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildGeometryOption(
                      label: 'Plataforma (Cuadrada)',
                      icon: Icons.crop_square,
                      value: 'Plataforma',
                      selected: _geometriaActual == 'Plataforma',
                      c: c,
                      onTap: () => _onGeometriaSelected('Plataforma'),
                    ),
                    _buildGeometryOption(
                      label: 'Circular',
                      icon: Icons.circle_outlined,
                      value: 'Circular',
                      selected: _geometriaActual == 'Circular',
                      c: c,
                      onTap: () => _onGeometriaSelected('Circular'),
                    ),
                    _buildGeometryOption(
                      label: 'Camionera (Secciones)',
                      icon: Icons.view_column_outlined,
                      value: 'Camionera',
                      selected: _geometriaActual == 'Camionera',
                      c: c,
                      onTap: () => _onGeometriaSelected('Camionera'),
                    ),
                  ],
                ),
                if (_isCamioneraOrFerro) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Text(
                        'Secciones:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.textSecondary),
                      ),
                      for (final n in [3, 4, 5, 6])
                        ChoiceChip(
                          label: Text('$n sec', style: TextStyle(
                            fontSize: 11,
                            fontWeight: _numPos == n ? FontWeight.bold : FontWeight.normal,
                            color: _numPos == n ? Colors.white : c.textPrimary,
                          )),
                          selected: _numPos == n,
                          showCheckmark: false,
                          selectedColor: _kRed,
                          backgroundColor: c.surface,
                          side: BorderSide(color: _numPos == n ? _kRed : c.border),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          visualDensity: VisualDensity.compact,
                          onSelected: (selected) {
                            if (selected) _setNumSecciones(n);
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // ── Campo Único: Carga de Prueba (kg) ─────────────────────────────
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
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.scale_outlined, color: c.brandAccent, size: 19),
                        const SizedBox(width: 8),
                        Text(
                          'Carga de Prueba (kg)',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    if (widget.divMin != null)
                      Text(
                        'd = ${widget.divMin} ($dec dec.)',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: c.textSecondary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Focus(
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
                    textAlign: TextAlign.center,
                    onChanged: (val) {
                      _userEditedCarga = true;
                      final raw = val.trim().replaceAll(',', '.');
                      final double? valor = double.tryParse(raw);
                      if (valor == null) return;
                      _notify();
                      if (mounted) setState(() {});
                    },
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: cargaInvalida ? c.dotRed : c.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '0.${'0' * dec}',
                      hintStyle: TextStyle(color: c.textTertiary, fontSize: 13),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: cargaInvalida ? c.dotRed : c.borderStrong),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: cargaInvalida ? c.dotRed : c.borderStrong),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: c.brandAccent, width: 1.8),
                      ),
                      fillColor: c.isDark ? c.surfaceElevated : c.surface,
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                ),
                if (cargaInvalida) ...[
                  const SizedBox(height: 6),
                  Text(
                    divMinErrorMsg(widget.divMin),
                    style: TextStyle(color: c.dotRed, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    final tableCard = Card(
      elevation: 0,
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: Padding(
        padding: EdgeInsets.all(isCoverScreen(context) ? 12 : 16),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  'EXCENTRICIDAD',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: c.brandAccent,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  'Error = L. Final - Carga',
                  style: TextStyle(fontSize: 10.5, color: c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Table(
              border: TableBorder.all(color: c.border),
              columnWidths: const {
                0: FlexColumnWidth(1.6),
                1: FlexColumnWidth(1.8),
                2: FlexColumnWidth(1.8),
                3: FlexColumnWidth(1.5),
              },
              children: [
                _hdr(['POSICIÓN', 'L. INICIAL', 'L. FINAL', 'ERROR'], c),
                for (int i = 0; i < _numPos; i++)
                  _row(i, _posLabels, dec, c),
              ],
            ),

            // ── Controles de Secciones Dinámicas para Camionera / Ferrocarril ─
            if (_isCamioneraOrFerro) ...[
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_numPos > 2)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: c.brandAccent,
                        side: BorderSide(color: c.brandAccent),
                        minimumSize: const Size(0, 42),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      icon: const Icon(Icons.remove_circle_outline, size: 16),
                      label: const Text('Quitar Sección', style: TextStyle(fontSize: 12)),
                      onPressed: _eliminarSeccion,
                    ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kRed,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.add_circle_outline, size: 16),
                    label: const Text('Agregar Sección',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: _agregarSeccion,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.all(isCoverScreen(context) ? 12 : 16),
      child: FoldableTwoColumn(
        firstFlex: 4,
        secondFlex: 6,
        horizontalGap: 14,
        verticalGap: 14,
        first: configColumn,
        second: tableCard,
      ),
    );
  }

  TableRow _hdr(List<String> labels, PesaPalette c) => TableRow(
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

  TableRow _row(int i, List<String> posLabels, int dec, PesaPalette c) {
    final ini = double.tryParse(_inicialCtrls[i].text.trim().replaceAll(',', '.'));
    final fin = double.tryParse(_finalCtrls[i].text.trim().replaceAll(',', '.'));
    final carga = double.tryParse(_cargaCtrl.text.trim().replaceAll(',', '.')) ?? 0.0;
    final err = calcularErrorExcentricidad(
      fin: fin,
      ini: ini,
      carga: carga,
      isCamionera: _isCamioneraOrFerro,
    );

    final posLabel = i < posLabels.length ? posLabels[i] : 'Sección ${i + 1}';
    final Color altBg = c.isDark ? const Color(0xFF222226) : const Color(0xFFF9F9F9);

    return TableRow(
      decoration: BoxDecoration(
        color: i % 2 == 0 ? c.surface : altBg,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(
            posLabel,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: c.textPrimary),
          ),
        ),
        _inputField(_inicialCtrls[i], dec, c),
        _inputField(_finalCtrls[i], dec, c),
        Padding(
          padding: const EdgeInsets.all(4),
          child: err == null
              ? Center(
                  child: Text('—', style: TextStyle(color: c.textSecondary, fontSize: 12)))
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

  Widget _inputField(TextEditingController ctrl, int dec, PesaPalette c) {
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
            hintText: dec == 0 ? '0' : '0.${'0' * dec}',
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

  Widget _buildGeometryOption({
    required String label,
    required IconData icon,
    required String value,
    required bool selected,
    required PesaPalette c,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.surfaceMuted : c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? c.brandAccent : c.borderStrong,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : icon,
              size: 16,
              color: selected ? c.brandAccent : c.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                color: selected ? c.brandAccent : c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}