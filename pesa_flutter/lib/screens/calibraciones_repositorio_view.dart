// lib/screens/calibraciones_repositorio_view.dart
// Repositorio de Calibraciones (Histórico / PDFs) — SOLO LECTURA.
// Visible únicamente para supervisión metrológica (Alan Guevara ID 8 / admins).
// No permite Rehacer, Reset ni Capturar: solo [Ver PDF] y [Descargar].
// Nunca escribe en `ordenes_servicio` (usa la tabla local `calibraciones_consulta`).
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/metrology_helper.dart';
import '../services/pdf_storage_service.dart';
import '../theme/pesa_theme.dart';

const _kBrand = PesaColors.brand;

class CalibracionesRepositorioView extends StatefulWidget {
  const CalibracionesRepositorioView({super.key});

  @override
  State<CalibracionesRepositorioView> createState() => _CalibracionesRepositorioViewState();
}

class _CalibracionesRepositorioViewState extends State<CalibracionesRepositorioView> {
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _aviso;
  String _query = '';
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _cargarLocal().then((_) => _refrescarServidor());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v);
    });
  }

  Future<void> _cargarLocal() async {
    try {
      final rows = await LocalDbService.instance.getCalibracionesFinalizadasConsulta();
      final filtrados = rows.where((r) {
        final tipo = (r['tipo_servicio'] ?? '').toString().toLowerCase();
        return tipo.contains('calibraci');
      }).toList();
      if (!mounted) return;
      setState(() {
        _all = filtrados;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _aviso = 'No se pudo leer la caché local: $e';
      });
    }
  }

  Future<void> _refrescarServidor() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final rows = await ApiService.instance
          .getCalibracionesConsulta()
          .timeout(const Duration(seconds: 35));
      await LocalDbService.instance.guardarCalibracionesConsulta(rows);
      _aviso = null;
      await _cargarLocal();
    } on HttpException catch (e) {
      final msg = e.message;
      if (msg.contains('404')) {
        _aviso = 'API pendiente de actualizar en el servidor. Mostrando caché local.';
      } else if (msg.contains('403')) {
        _aviso = 'Tu usuario no tiene permiso de consulta del repositorio.';
      } else {
        _aviso = 'Servidor no disponible ($msg). Mostrando caché local.';
      }
    } on TimeoutException {
      _aviso = 'Tiempo de espera agotado. Mostrando caché local.';
    } on SocketException {
      _aviso = 'Sin conexión. Mostrando caché local.';
    } catch (e) {
      _aviso = 'No se pudo actualizar: $e';
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final base = _all.where((r) {
      final tipo = (r['tipo_servicio'] ?? '').toString().toLowerCase();
      return tipo.contains('calibraci');
    }).toList();
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((r) {
      final hay = [
        construirEtiquetaInstrumento(r),
        extraerNumeroCca(r),
        extraerNumeroDve(r),
        r['folio_os'], r['cliente'], r['sucursal'], r['tecnico'], r['tipo_servicio'], r['fecha'],
      ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
      return hay.contains(q);
    }).toList();
  }

  String _fmtFecha(dynamic raw) {
    final s = (raw ?? '').toString();
    if (s.isEmpty) return '—';
    final d = DateTime.tryParse(s);
    if (d == null) return s.length > 10 ? s.substring(0, 10) : s;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _safe(String folio) => folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  /// Obtiene una ruta local válida del PDF (caché en disco o descarga del servidor).
  /// Solo lectura: no modifica `ordenes_servicio`.
  Future<String?> _obtenerPdfLocal(Map<String, dynamic> row) async {
    final folio = (row['folio_os'] ?? '').toString().trim();
    if (folio.isEmpty) return null;

    bool valido(String? p) =>
        p != null && p.isNotEmpty && File(p).existsSync() && File(p).lengthSync() > 500;

    final cached = (row['pdf_path_local'] ?? '').toString();
    if (valido(cached)) return cached;

    final doc = await getApplicationDocumentsDirectory();
    final safe = _safe(folio);
    for (final c in [
      '${doc.path}/pdfs/$safe.pdf',
      '${doc.path}/Pesa_PDFs/$safe.pdf',
      '${doc.path}/PESA_Tablet/PDF_OS/$safe.pdf',
    ]) {
      if (valido(c)) {
        await LocalDbService.instance.setCalibracionPdfPath(folio, c);
        return c;
      }
    }

    final path = await ApiService.instance.downloadPdf(
      '/api/v1/ordenes/$folio/download-pdf',
      targetFileName: '$safe.pdf',
    );
    if (valido(path)) {
      await LocalDbService.instance.setCalibracionPdfPath(folio, path);
      row['pdf_path_local'] = path;
      return path;
    }
    return null;
  }

  Future<void> _verPdf(Map<String, dynamic> row) async {
    final folio = (row['folio_os'] ?? '').toString();
    if (_busy.contains(folio)) return;
    setState(() => _busy.add(folio));
    try {
      final path = await _obtenerPdfLocal(row);
      if (!mounted) return;
      if (path == null) {
        _snack('PDF de $folio no disponible en el servidor.', error: true);
        return;
      }
      bool usarVisor = false;
      try {
        final res = await OpenFilex.open(path);
        usarVisor = res.type == ResultType.noAppToOpen || res.type == ResultType.error;
      } catch (_) {
        usarVisor = true;
      }
      if (usarVisor && mounted) {
        context.push('/pdf-viewer', extra: {
          'pdfPath': path,
          'pdfBytes': File(path).readAsBytesSync(),
          'folio': folio,
        });
      }
    } catch (e) {
      if (mounted) _snack('No se pudo abrir el PDF de $folio: ${_limpia(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(folio));
    }
  }

  Future<void> _descargar(Map<String, dynamic> row) async {
    final folio = (row['folio_os'] ?? '').toString();
    if (_busy.contains(folio)) return;
    setState(() => _busy.add(folio));
    try {
      final path = await _obtenerPdfLocal(row);
      if (!mounted) return;
      if (path == null) {
        _snack('PDF de $folio no disponible en el servidor.', error: true);
        return;
      }
      await PdfStorageService.instance.exportToDownloads(
        folio: folio,
        cliente: row['cliente']?.toString(),
        tipoServicio: row['tipo_servicio']?.toString(),
        osData: row,
        sourcePdfPath: path,
        context: context,
      );
    } catch (e) {
      if (mounted) _snack('No se pudo descargar $folio: ${_limpia(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(folio));
    }
  }

  String _limpia(Object e) =>
      e.toString().replaceAll('Exception: ', '').replaceAll('HttpException: ', '');

  void _snack(String msg, {bool error = false}) {
    final c = PesaColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: error ? _kBrand : (c.isDark ? c.elevated : PesaColors.textPrimary),
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final mobile = c.maxWidth < 650;
      final rows = _filtered;
      return Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 16 : 20, 8, mobile ? 16 : 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(mobile),
            if (_aviso != null) _avisoBanner(),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: _kBrand))
                  : rows.isEmpty
                      ? _vacio()
                      : (mobile ? _listaMobile(rows) : _tabla(rows)),
            ),
          ],
        ),
      );
    });
  }

  Widget _header(bool mobile) {
    final p = PesaColors.of(context);
    final titulo = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: p.surfaceMuted,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.verified_outlined, color: p.brandAccent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Repositorio de Calibraciones',
                  style: TextStyle(color: p.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
              Text('Histórico / PDFs · Solo lectura · ${_all.length} órdenes concluidas',
                  style: TextStyle(color: p.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        IconButton(
          key: const Key('calib_repo_refresh'),
          tooltip: 'Actualizar desde servidor',
          onPressed: _refreshing ? null : _refrescarServidor,
          icon: _refreshing
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _kBrand))
              : Icon(Icons.refresh_rounded, color: p.textPrimary),
        ),
      ],
    );

    final buscador = SizedBox(
      width: mobile ? double.infinity : 320,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: TextField(
          key: const Key('calib_repo_search'),
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          style: TextStyle(fontSize: 13, color: p.textPrimary),
          decoration: InputDecoration(
            hintText: 'Buscar folio, cliente, técnico…',
            prefixIcon: Icon(Icons.search, size: 18, color: p.textSecondary),
            isDense: true,
            filled: true,
            fillColor: p.elevated,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.borderStrong),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.borderStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.brandAccent, width: 1.5),
            ),
          ),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: mobile
          ? Column(children: [titulo, const SizedBox(height: 12), buscador])
          : Row(children: [Expanded(child: titulo), const SizedBox(width: 12), buscador]),
    );
  }

  Widget _avisoBanner() {
    final p = PesaColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: p.isDark ? p.elevated : const Color(0xFFFFF7E6),
        border: Border.all(
          color: p.isDark ? p.dotAmber.withValues(alpha: 0.45) : const Color(0xFFF5C26B),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(Icons.info_outline, size: 16, color: p.isDark ? p.dotAmber : const Color(0xFFB7791F)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _aviso!,
            style: TextStyle(fontSize: 12, color: p.isDark ? p.textPrimary : const Color(0xFF7A4F01)),
          ),
        ),
      ]),
    );
  }

  Widget _vacio() {
    final p = PesaColors.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder_off_outlined, size: 48, color: p.textSecondary.withValues(alpha: 0.6)),
        const SizedBox(height: 8),
        Text(
          _query.isEmpty
              ? 'Sin calibraciones concluidas en caché.\nPulsa actualizar para consultar el servidor.'
              : 'Sin resultados para "$_query".',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.textSecondary, fontSize: 13),
        ),
      ]),
    );
  }

  static const _cols = <(String, int)>[
    ('FOLIO / INSTRUMENTO', 4),
    ('FECHA', 2),
    ('CLIENTE', 4),
    ('TÉCNICO EJECUTOR', 3),
    ('TIPO SERVICIO', 3),
    ('ACCIONES', 4),
  ];

  Widget _tabla(List<Map<String, dynamic>> rows) {
    final p = PesaColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: p.tableHead,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: _cols
                .map((c) => Expanded(
                      flex: c.$2,
                      child: Text(c.$1,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: p.textSecondary)),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: _kBrand,
            onRefresh: _refrescarServidor,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
              itemBuilder: (_, i) => _filaTabla(rows[i]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _filaTabla(Map<String, dynamic> r) {
    final p = PesaColors.of(context);
    final cell = TextStyle(fontSize: 12.5, color: p.textPrimary);
    final folio = (r['folio_os'] ?? '').toString();
    final cca = extraerNumeroCca(r);
    final dve = extraerNumeroDve(r);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Builder(
              builder: (context) {
                final specs = construirEspecificacionesInstrumento(r);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          folio,
                          style: cell.copyWith(fontWeight: FontWeight.w800, fontSize: 12, color: p.textPrimary),
                        ),
                        if (cca.isNotEmpty) _chipReg('CCA', cca, p.textPrimary, p.surfaceMuted, p.borderStrong),
                        if (dve.isNotEmpty) _chipReg('DVE', dve, p.textPrimary, p.surfaceMuted, p.borderStrong),
                      ],
                    ),
                    if (specs.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        specs,
                        softWrap: true,
                        maxLines: 3,
                        style: cell.copyWith(fontSize: 11, color: p.textSecondary, height: 1.3),
                      ),
                    ],
                    if (formatearInfoEnvioCorreo(r).isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: p.surfaceMuted,
                          border: Border(
                            left: BorderSide(color: p.textPrimary, width: 3),
                            top: BorderSide(color: p.border),
                            right: BorderSide(color: p.border),
                            bottom: BorderSide(color: p.border),
                          ),
                        ),
                        child: Text(
                          formatearInfoEnvioCorreo(r),
                          softWrap: true,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: p.textSecondary,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
        Expanded(flex: 2, child: Text(_fmtFecha(r['fecha']), style: cell)),
        Expanded(
          flex: 4,
          child: Text((r['cliente'] ?? '—').toString(),
              style: cell, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 3,
          child: Row(children: [
            Icon(Icons.engineering_outlined, size: 14, color: p.textSecondary),
            const SizedBox(width: 4),
            Expanded(
              child: Text((r['tecnico'] ?? '—').toString(),
                  style: cell, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
        Expanded(
          flex: 3,
          child: Text((r['tipo_servicio'] ?? '—').toString(),
              style: cell.copyWith(color: p.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 4,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _acciones(r, compact: false),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _chipReg(String pfx, String val, Color fg, Color bg, Color border) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: border),
        ),
        child: Text(
          val.toUpperCase().startsWith(pfx.toUpperCase()) ? val : '$pfx: $val',
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: fg),
        ),
      );

  Widget _listaMobile(List<Map<String, dynamic>> rows) {
    final p = PesaColors.of(context);
    return RefreshIndicator(
      color: _kBrand,
      onRefresh: _refrescarServidor,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final r = rows[i];
          final folioCard = (r['folio_os'] ?? r['folio'] ?? '—').toString().trim();
          final specsCard = construirEspecificacionesInstrumento(r);
          final cca = extraerNumeroCca(r);
          final dve = extraerNumeroDve(r);
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(
                    folioCard.isNotEmpty ? folioCard : '—',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: p.textPrimary),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_fmtFecha(r['fecha']), style: TextStyle(fontSize: 12, color: p.textSecondary)),
              ]),
              if (cca.isNotEmpty || dve.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (cca.isNotEmpty) _chipReg('CCA', cca, p.textPrimary, p.surfaceMuted, p.borderStrong),
                    if (dve.isNotEmpty) _chipReg('DVE', dve, p.textPrimary, p.surfaceMuted, p.borderStrong),
                  ],
                ),
              ],
              if (specsCard.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  specsCard,
                  softWrap: true,
                  maxLines: 3,
                  style: TextStyle(fontSize: 12, color: p.textSecondary, height: 1.35),
                ),
              ],
              const SizedBox(height: 4),
              Text((r['cliente'] ?? '—').toString(), style: TextStyle(fontSize: 13, color: p.textPrimary)),
              const SizedBox(height: 2),
              Text('Técnico: ${(r['tecnico'] ?? '—')}',
                  style: TextStyle(fontSize: 12, color: p.textSecondary)),
              Text((r['tipo_servicio'] ?? '—').toString(),
                  style: TextStyle(fontSize: 12, color: p.textSecondary)),
              if (formatearInfoEnvioCorreo(r).isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: p.surfaceMuted,
                    border: Border(
                      left: BorderSide(color: p.textPrimary, width: 3),
                      top: BorderSide(color: p.border),
                      right: BorderSide(color: p.border),
                      bottom: BorderSide(color: p.border),
                    ),
                  ),
                  child: Text(
                    formatearInfoEnvioCorreo(r),
                    softWrap: true,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: p.textSecondary,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _acciones(r, compact: true),
            ]),
          );
        },
      ),
    );
  }

  /// ÚNICAS acciones permitidas: Ver PDF y Descargar (solo lectura).
  Widget _acciones(Map<String, dynamic> r, {required bool compact}) {
    final p = PesaColors.of(context);
    final folio = (r['folio_os'] ?? '').toString();
    final busy = _busy.contains(folio);
    final tienePdf = r['tiene_pdf'] == 1 ||
        r['tiene_pdf'] == true ||
        (r['pdf_path_local'] ?? '').toString().isNotEmpty;

    final btnStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      minimumSize: const Size(0, 32),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

    final botones = [
      OutlinedButton.icon(
        key: Key('calib_ver_pdf_$folio'),
        style: btnStyle.copyWith(
          foregroundColor: WidgetStatePropertyAll(p.textPrimary),
          side: WidgetStatePropertyAll(BorderSide(color: p.borderStrong)),
        ),
        onPressed: busy ? null : () => _verPdf(r),
        icon: busy
            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: _kBrand))
            : Icon(Icons.picture_as_pdf_outlined, size: 15, color: p.brandAccent),
        label: const Text('Ver PDF'),
      ),
      const SizedBox(width: 6),
      OutlinedButton.icon(
        key: Key('calib_descargar_$folio'),
        style: btnStyle.copyWith(
          foregroundColor: WidgetStatePropertyAll(p.textPrimary),
          side: WidgetStatePropertyAll(BorderSide(color: p.borderStrong)),
        ),
        onPressed: busy ? null : () => _descargar(r),
        icon: Icon(Icons.download_outlined, size: 15, color: p.textPrimary),
        label: const Text('Descargar'),
      ),
      if (!tienePdf) ...[
        const SizedBox(width: 6),
        Tooltip(
          message: 'El servidor no reporta PDF para esta orden; se intentará descargar igualmente.',
          child: Text('Sin PDF en servidor',
              style: TextStyle(fontSize: 10.5, color: p.dotAmber, fontStyle: FontStyle.italic)),
        ),
      ],
    ];

    if (compact) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: botones,
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: botones,
        ),
      ),
    );
  }
}
