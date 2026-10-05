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
import '../services/pdf_storage_service.dart';

const _kMetroPurple = Color(0xFF5B3FD6);
const _kMetroBlue   = Color(0xFF1E5AA8);
const _kBorder      = Color(0xFFE5E5EA);
const _kTextPrim    = Color(0xFF1D1D1F);
const _kTextSec     = Color(0xFF86868B);
const _kTableHead   = Color(0xFFF1EEFC);

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
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _cargarLocal().then((_) => _refrescarServidor());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarLocal() async {
    try {
      final rows = await LocalDbService.instance.getCalibracionesFinalizadasConsulta();
      if (!mounted) return;
      setState(() {
        _all = rows;
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
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((r) {
      final hay = [
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? const Color(0xFFC8102E) : _kMetroBlue,
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final mobile = c.maxWidth < 650;
      final rows = _filtered;
      return Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 12 : 24, 8, mobile ? 12 : 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(mobile),
            if (_aviso != null) _avisoBanner(),
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: _kMetroPurple))
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
    final titulo = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.verified_outlined, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Repositorio de Calibraciones',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
              Text('Histórico / PDFs · Solo lectura · ${_all.length} órdenes concluidas',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.refresh_rounded, color: Colors.white),
        ),
      ],
    );

    final buscador = SizedBox(
      height: 40,
      width: mobile ? double.infinity : 320,
      child: TextField(
        key: const Key('calib_repo_search'),
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Buscar folio, cliente, técnico…',
          prefixIcon: const Icon(Icons.search, size: 18),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_kMetroPurple, _kMetroBlue],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: _kMetroPurple.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: mobile
          ? Column(children: [titulo, const SizedBox(height: 10), buscador])
          : Row(children: [Expanded(child: titulo), const SizedBox(width: 12), buscador]),
    );
  }

  Widget _avisoBanner() => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          border: Border.all(color: const Color(0xFFF5C26B)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 16, color: Color(0xFFB7791F)),
          const SizedBox(width: 8),
          Expanded(child: Text(_aviso!, style: const TextStyle(fontSize: 12, color: Color(0xFF7A4F01)))),
        ]),
      );

  Widget _vacio() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.folder_off_outlined, size: 48, color: _kTextSec.withValues(alpha: 0.6)),
          const SizedBox(height: 8),
          Text(
            _query.isEmpty
                ? 'Sin calibraciones concluidas en caché.\nPulsa actualizar para consultar el servidor.'
                : 'Sin resultados para "$_query".',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _kTextSec, fontSize: 13),
          ),
        ]),
      );

  static const _cols = <(String, int)>[
    ('FOLIO OS', 2),
    ('FECHA', 2),
    ('CLIENTE', 4),
    ('TÉCNICO EJECUTOR', 3),
    ('TIPO SERVICIO', 4),
    ('ACCIONES', 4),
  ];

  Widget _tabla(List<Map<String, dynamic>> rows) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kMetroPurple.withValues(alpha: 0.35), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: _kTableHead,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: _cols
                .map((c) => Expanded(
                      flex: c.$2,
                      child: Text(c.$1,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: _kMetroPurple)),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: _kMetroPurple,
            onRefresh: _refrescarServidor,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: _kBorder),
              itemBuilder: (_, i) => _filaTabla(rows[i]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _filaTabla(Map<String, dynamic> r) {
    const cell = TextStyle(fontSize: 12.5, color: _kTextPrim);
    final folio = (r['folio_os'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: Text(folio, style: cell.copyWith(fontWeight: FontWeight.w700)),
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
            const Icon(Icons.engineering_outlined, size: 14, color: _kMetroBlue),
            const SizedBox(width: 4),
            Expanded(
              child: Text((r['tecnico'] ?? '—').toString(),
                  style: cell, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
        Expanded(
          flex: 4,
          child: Text((r['tipo_servicio'] ?? '—').toString(),
              style: cell.copyWith(color: _kTextSec), maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Expanded(flex: 4, child: _acciones(r, compact: false)),
      ]),
    );
  }

  Widget _listaMobile(List<Map<String, dynamic>> rows) {
    return RefreshIndicator(
      color: _kMetroPurple,
      onRefresh: _refrescarServidor,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final r = rows[i];
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: const Border(left: BorderSide(color: _kMetroPurple, width: 4),
                  top: BorderSide(color: _kBorder),
                  right: BorderSide(color: _kBorder),
                  bottom: BorderSide(color: _kBorder)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text((r['folio_os'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const Spacer(),
                Text(_fmtFecha(r['fecha']), style: const TextStyle(fontSize: 12, color: _kTextSec)),
              ]),
              const SizedBox(height: 4),
              Text((r['cliente'] ?? '—').toString(), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 2),
              Text('Técnico: ${(r['tecnico'] ?? '—')}',
                  style: const TextStyle(fontSize: 12, color: _kMetroBlue)),
              Text((r['tipo_servicio'] ?? '—').toString(),
                  style: const TextStyle(fontSize: 12, color: _kTextSec)),
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
    final folio = (r['folio_os'] ?? '').toString();
    final busy = _busy.contains(folio);
    final tienePdf = r['tiene_pdf'] == 1 ||
        r['tiene_pdf'] == true ||
        (r['pdf_path_local'] ?? '').toString().isNotEmpty;

    final btnStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      minimumSize: const Size(0, 34),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: Key('calib_ver_pdf_$folio'),
          style: btnStyle.copyWith(
            foregroundColor: const WidgetStatePropertyAll(_kMetroPurple),
            side: const WidgetStatePropertyAll(BorderSide(color: _kMetroPurple)),
          ),
          onPressed: busy ? null : () => _verPdf(r),
          icon: busy
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('📄', style: TextStyle(fontSize: 13)),
          label: const Text('Ver PDF'),
        ),
        OutlinedButton.icon(
          key: Key('calib_descargar_$folio'),
          style: btnStyle.copyWith(
            foregroundColor: const WidgetStatePropertyAll(_kMetroBlue),
            side: const WidgetStatePropertyAll(BorderSide(color: _kMetroBlue)),
          ),
          onPressed: busy ? null : () => _descargar(r),
          icon: const Text('📥', style: TextStyle(fontSize: 13)),
          label: const Text('Descargar'),
        ),
        if (!tienePdf)
          const Tooltip(
            message: 'El servidor no reporta PDF para esta orden; se intentará descargar igualmente.',
            child: Text('Sin PDF en servidor',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFB7791F), fontStyle: FontStyle.italic)),
          ),
      ],
    );
  }
}
