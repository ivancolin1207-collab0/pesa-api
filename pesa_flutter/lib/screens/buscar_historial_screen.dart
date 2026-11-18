// lib/screens/buscar_historial_screen.dart — Buscador e Historial Dinámico de Órdenes e Instrumentos
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/local_db_service.dart';
import '../services/metrology_helper.dart';
import '../services/sync_service.dart';
import '../widgets/app_shell.dart';
import 'os_list_screen.dart';

class BuscarHistorialScreen extends StatefulWidget {
  const BuscarHistorialScreen({super.key});

  @override
  State<BuscarHistorialScreen> createState() => _BuscarHistorialScreenState();
}

class _BuscarHistorialScreenState extends State<BuscarHistorialScreen> {
  static const _red = Color(0xFFB81D24);
  static const _border = Color(0xFFE5E7EB);
  static const _bg = Color(0xFFF9FAFB);

  final _searchCtrl = TextEditingController();
  String _query = '';
  String _filtroFormato = 'TODOS';
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthService>();
      final usuario = AuthService.usuarioActual;
      final isAdmin = auth.isAdmin || (usuario != null && usuario.isAdmin);
      final isTecnico = !isAdmin && (auth.isTecnico || (usuario != null && usuario.isTecnico));
      final rows = isTecnico
          ? await LocalDbService.instance.getOsForTecnico(
              nombreTecnico: usuario?.nombre ?? auth.displayName,
              idTecnico: usuario?.id ?? auth.idTecnico,
            )
          : await LocalDbService.instance.getAllOs();
      if (mounted) {
        setState(() {
          _all = rows.map((e) => Map<String, dynamic>.from(e)).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = LocalDbService.normalizarTexto(_query);
    return _all.where((os) {
      final folio = (os['folio_os'] ?? os['folio'] ?? '').toString().toUpperCase().trim();
      if (_filtroFormato != 'TODOS') {
        final td = (os['tipo_documento'] ?? '').toString().toUpperCase().trim();
        if (td != _filtroFormato && !folio.startsWith('$_filtroFormato-')) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      final etiq = LocalDbService.normalizarTexto(construirEtiquetaInstrumento(os));
      final cca = LocalDbService.normalizarTexto(extraerNumeroCca(os));
      final dve = LocalDbService.normalizarTexto(extraerNumeroDve(os));
      if (etiq.contains(q) || cca.contains(q) || dve.contains(q)) return true;
      for (final k in const [
        'cliente', 'sucursal', 'direccion', 'tecnico',
        'tipo_servicio', 'marca', 'modelo', 'ns', 'id_equipo', 'ubicacion',
      ]) {
        if (LocalDbService.normalizarTexto((os[k] ?? '').toString()).contains(q)) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  Future<void> _abrirPdfDirecto(Map<String, dynamic> os) async {
    final folio = (os['folio_os'] ?? os['folio'] ?? '').toString().trim();
    if (folio.isEmpty) return;
    String? path = (os['pdf_path_local'] ?? '').toString().trim();
    if (path.isEmpty || !File(path).existsSync()) {
      path = await LocalDbService.instance.resolvePdfPathFromDisk(folio);
    }
    if (path == null || !File(path).existsSync()) {
      try {
        path = await ApiService.instance.downloadPdf(
          '/api/v1/ordenes/$folio/download-pdf',
          targetFileName: '$folio.pdf',
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF no disponible para $folio ($e)'), backgroundColor: _red),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final res = await OpenFilex.open(path);
    if ((res.type == ResultType.noAppToOpen || res.type == ResultType.error) && mounted) {
      context.push('/pdf-viewer', extra: {
        'pdfPath': path,
        'pdfBytes': File(path).readAsBytesSync(),
        'folio': folio,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final isMobile = media.size.width < 768 && media.orientation != Orientation.landscape;
    final rows = _filtered;

    return AppShell(
      currentRoute: '/historial',
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _border)),
                ),
                child: Column(
                  children: [
                    Row(children: [
                      if (isMobile)
                        IconButton(
                          icon: const Icon(Icons.menu_rounded, color: Color(0xFF111827)),
                          onPressed: () => AppShell.toggleMenu(context),
                        ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _red,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.manage_search_rounded, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Buscar / Historial de Equipos y Órdenes',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                            ),
                            Text(
                              '${rows.length} de ${_all.length} registros · Búsqueda por Folio, Marca, Modelo, S/N, ID, CCA o DVE',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Sincronizar y actualizar',
                        icon: const Icon(Icons.sync_rounded),
                        onPressed: () async {
                          await context.read<SyncService>().performSync();
                          await _load();
                        },
                      ),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Buscar folio, Rice Lake, modelo, serie, ID indicador, CCA.26, DVE.26, cliente...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 17),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _query = '');
                                },
                              )
                            : null,
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF3F4F6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final fmt in const ['TODOS', 'OS', 'OSOB', 'OSOCC', 'RMA', 'RE', 'LP', 'LV'])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(fmt, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                                selected: _filtroFormato == fmt,
                                selectedColor: _red,
                                labelStyle: TextStyle(
                                  color: _filtroFormato == fmt ? Colors.white : const Color(0xFF374151),
                                ),
                                onSelected: (_) => setState(() => _filtroFormato = fmt),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: _red))
                    : rows.isEmpty
                        ? const Center(
                            child: Text(
                              'Sin coincidencias en el historial',
                              style: TextStyle(color: Color(0xFF6B7280)),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: rows.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (ctx, i) {
                              final os = rows[i];
                              final folioTxt = (os['folio_os'] ?? os['folio'] ?? '—').toString().trim();
                              final specs = construirEspecificacionesInstrumento(os);
                              final cca = extraerNumeroCca(os);
                              final dve = extraerNumeroDve(os);
                              final fecha = (os['fecha'] ?? '').toString().split('T').first;
                              final est = (os['estatus'] ?? os['estado'] ?? '').toString().toUpperCase();
                              final cerrada = est.contains('CERRAD') ||
                                  est.contains('COMPLET') ||
                                  os['has_pdf'] == 1 ||
                                  (os['pdf_path_local'] ?? '').toString().isNotEmpty;

                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: _border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            folioTxt.isNotEmpty ? folioTxt : '—',
                                            style: const TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF111827),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          fecha,
                                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                                        ),
                                      ],
                                    ),
                                    if (cca.isNotEmpty || dve.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          if (cca.isNotEmpty)
                                            _pill(
                                              cca.toUpperCase().startsWith('CCA') ? cca : 'CCA $cca',
                                              const Color(0xFF3730A3),
                                              const Color(0xFFEEF2FF),
                                            ),
                                          if (dve.isNotEmpty)
                                            _pill(
                                              dve.toUpperCase().startsWith('DVE') ? dve : 'DVE $dve',
                                              const Color(0xFF065F46),
                                              const Color(0xFFECFDF5),
                                            ),
                                        ],
                                      ),
                                    ],
                                    if (specs.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        specs,
                                        softWrap: true,
                                        maxLines: 3,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF4B5563),
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 5),
                                    Text(
                                      [
                                        if ((os['cliente'] ?? '').toString().isNotEmpty) os['cliente'],
                                        if ((os['sucursal'] ?? '').toString().isNotEmpty) os['sucursal'],
                                        if ((os['tecnico'] ?? '').toString().isNotEmpty) 'Téc: ${os['tecnico']}',
                                      ].join(' • '),
                                      softWrap: true,
                                      maxLines: 3,
                                      style: const TextStyle(fontSize: 12, color: Color(0xFF374151), height: 1.3),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (cerrada)
                                          OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              visualDensity: VisualDensity.compact,
                                              foregroundColor: const Color(0xFF1D4ED8),
                                            ),
                                            onPressed: () => _abrirPdfDirecto(os),
                                            icon: const Icon(Icons.picture_as_pdf_outlined, size: 15),
                                            label: const Text('Ver PDF', style: TextStyle(fontSize: 11.5)),
                                          ),
                                        const SizedBox(width: 8),
                                        ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            visualDensity: VisualDensity.compact,
                                            backgroundColor: cerrada ? const Color(0xFFF57C00) : _red,
                                            foregroundColor: Colors.white,
                                          ),
                                          onPressed: () async {
                                            await navegarCapturaSegunTipo(context, Map<String, dynamic>.from(os));
                                            await _load();
                                          },
                                          icon: Icon(cerrada ? Icons.edit_note_rounded : Icons.edit, size: 15),
                                          label: Text(
                                            cerrada ? 'Abrir / Editar' : 'Capturar Equipo',
                                            style: const TextStyle(fontSize: 11.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
        child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg)),
      );
}
