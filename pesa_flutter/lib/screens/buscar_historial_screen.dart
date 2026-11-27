// lib/screens/buscar_historial_screen.dart — Buscador e Historial Dinámico (Adaptativo Galaxy Z Fold8 Ultra)
import 'dart:async';
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
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/pesa_components.dart';
import 'os_list_screen.dart';

class BuscarHistorialScreen extends StatefulWidget {
  const BuscarHistorialScreen({super.key});

  @override
  State<BuscarHistorialScreen> createState() => _BuscarHistorialScreenState();
}

class _BuscarHistorialScreenState extends State<BuscarHistorialScreen> {
  static const _red = PesaColors.brand;

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  Timer? _remoteSearchDebounce;
  String _query = '';
  String _filtroFormato = 'TODOS';
  List<Map<String, dynamic>> _all = [];
  bool _loading = true;
  bool _searchingRemote = false;
  String? _selectedKey;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sync = context.read<SyncService>();
      if (sync.orders.isEmpty && sync.state != SyncState.syncing) {
        sync.performSync().then((_) {
          if (mounted) _load();
        });
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _remoteSearchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _remoteSearchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _query = v);
    });

    final trimmed = v.trim();
    if (trimmed.length >= 2) {
      _remoteSearchDebounce = Timer(const Duration(milliseconds: 420), () {
        _buscarEnServidor(trimmed);
      });
    } else if (_searchingRemote && mounted) {
      setState(() => _searchingRemote = false);
    }
  }

  Future<void> _buscarEnServidor(String q) async {
    if (!mounted) return;
    setState(() => _searchingRemote = true);
    try {
      final remotos = await ApiService.instance
          .buscarOrdenesServidor(q, limit: 150)
          .timeout(const Duration(seconds: 15));
      if (!mounted || _searchCtrl.text.trim() != q) return;
      if (remotos.isNotEmpty) {
        await LocalDbService.instance.insertOrdenesBatch(remotos);
        await _load(silent: true);
      }
    } catch (e) {
      debugPrint('[BuscarHistorial] Búsqueda remota omitida ($q): $e');
    } finally {
      if (mounted) setState(() => _searchingRemote = false);
    }
  }

  String _rowKey(Map<String, dynamic> os) =>
      (os['folio_os'] ?? os['folio'] ?? os['local_id'] ?? '').toString().trim();

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
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

  bool _isCerrada(Map<String, dynamic> os) {
    final est = (os['estatus'] ?? os['estado'] ?? '').toString().toUpperCase();
    return est.contains('CERRAD') ||
        est.contains('COMPLET') ||
        os['has_pdf'] == 1 ||
        (os['pdf_path_local'] ?? '').toString().isNotEmpty;
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

  Widget _buildHeader(BuildContext context, List<Map<String, dynamic>> rows, bool cover) {
    final c = PesaColors.of(context);
    final sync = context.watch<SyncService>();
    final syncLabel = sync.syncSummaryLabel;
    return Container(
      padding: EdgeInsets.fromLTRB(cover ? 12 : 18, 12, cover ? 12 : 18, 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          Row(children: [
            if (cover)
              IconButton(
                icon: Icon(Icons.menu_rounded, color: c.textPrimary),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => AppShell.toggleMenu(context),
              ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _red,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.manage_search_rounded, color: Colors.white, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Buscar / Historial de Órdenes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                    ),
                  ),
                  Text(
                    '${rows.length} de ${_all.length} registros · $syncLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: c.textPrimary,
                side: BorderSide(color: c.border),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                minimumSize: const Size(0, 40),
              ),
              icon: sync.state == SyncState.syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _red),
                    )
                  : Icon(Icons.sync_rounded, size: 16, color: c.textPrimary),
              label: Text(
                cover ? 'Sincronizar' : 'Sincronizar ahora',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              onPressed: () async {
                final syncSvc = context.read<SyncService>();
                if (syncSvc.state == SyncState.syncing) {
                  syncSvc.forceResetSync();
                }
                await syncSvc.performSync(forceFull: true);
                await _load();
                if (!context.mounted) return;
                final warns = syncSvc.syncWarnings;
                final sc = PesaColors.of(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: warns.isNotEmpty
                        ? PesaColors.brand
                        : (sc.isDark ? sc.elevated : PesaColors.textPrimary),
                    content: Text(
                      warns.isNotEmpty
                          ? 'Sincronización con alertas: ${warns.join(" · ")}'
                          : syncSvc.syncSummaryLabel,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                );
              },
            ),
          ]),
          if (_searchingRemote) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(minHeight: 2, color: _red, backgroundColor: c.surfaceMuted),
          ],
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(color: c.textPrimary),
              decoration: InputDecoration(
                hintText: 'Buscar folio, Rice Lake, modelo, serie, ID, CCA, DVE, cliente…',
                prefixIcon: Icon(Icons.search_rounded, size: 19, color: c.textSecondary),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, size: 17, color: c.textSecondary),
                        onPressed: () {
                          _searchDebounce?.cancel();
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                filled: true,
                fillColor: c.surfaceMuted,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: c.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: c.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: c.brandAccent, width: 1.5),
                ),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  for (final fmt in const ['TODOS', 'OS', 'OSOB', 'OSOCC', 'RMA', 'RE', 'LP', 'LV'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(fmt, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                        selected: _filtroFormato == fmt,
                        showCheckmark: false,
                        selectedColor: _red,
                        backgroundColor: c.surface,
                        side: BorderSide(color: _filtroFormato == fmt ? _red : c.border),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        labelStyle: TextStyle(
                          color: _filtroFormato == fmt ? Colors.white : c.textPrimary,
                        ),
                        onSelected: (_) => setState(() => _filtroFormato = fmt),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListItem(BuildContext context, Map<String, dynamic> os, {required bool isMasterDetail, required bool isSelected}) {
    final c = PesaColors.of(context);
    final folioTxt = (os['folio_os'] ?? os['folio'] ?? '—').toString().trim();
    final specs = construirEspecificacionesInstrumento(os);
    final cca = extraerNumeroCca(os);
    final dve = extraerNumeroDve(os);
    final fecha = (os['fecha'] ?? '').toString().split('T').first;
    final cerrada = _isCerrada(os);
    final infoCorreo = formatearInfoEnvioCorreo(os);

    final cardContent = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelected ? c.surfaceMuted : c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(
            color: isSelected ? c.brandAccent : c.border,
            width: isSelected ? 3.5 : 1,
          ),
          top: BorderSide(color: c.border),
          right: BorderSide(color: c.border),
          bottom: BorderSide(color: c.border),
        ),
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
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PesaStatusBadge(
                label: cerrada ? 'Cerrada' : 'En proceso',
                dotColor: cerrada ? c.dotGreen : c.dotAmber,
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              ),
            ],
          ),
          if (cca.isNotEmpty || dve.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (cca.isNotEmpty)
                  _pill(context, cca.toUpperCase().startsWith('CCA') ? cca : 'CCA $cca'),
                if (dve.isNotEmpty)
                  _pill(context, dve.toUpperCase().startsWith('DVE') ? dve : 'DVE $dve'),
              ],
            ),
          ],
          if (specs.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              specs,
              softWrap: true,
              maxLines: isMasterDetail ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: c.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    if ((os['cliente'] ?? '').toString().isNotEmpty) os['cliente'],
                    if ((os['sucursal'] ?? '').toString().isNotEmpty) os['sucursal'],
                    if ((os['tecnico'] ?? '').toString().isNotEmpty) 'Téc: ${os['tecnico']}',
                  ].join(' · '),
                  softWrap: true,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.textPrimary, height: 1.3),
                ),
              ),
              if (fecha.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  fecha,
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
          if (!isMasterDetail) ...[
            if (infoCorreo.isNotEmpty)
              buildEmailAuditBanner(infoCorreo, margin: const EdgeInsets.only(top: 6)),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (cerrada) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onPressed: () => _abrirPdfDirecto(os),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 15),
                    label: const Text('Ver PDF', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                ],
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    backgroundColor: cerrada
                        ? (c.isDark ? c.elevated : PesaColors.textPrimary)
                        : _red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    await navegarCapturaSegunTipo(context, Map<String, dynamic>.from(os));
                    await _load();
                  },
                  icon: Icon(cerrada ? Icons.edit_note_rounded : Icons.edit, size: 15),
                  label: Text(
                    cerrada ? 'Abrir / Editar' : 'Capturar Equipo',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (!isMasterDetail) return cardContent;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _selectedKey = _rowKey(os)),
      child: cardContent,
    );
  }

  Widget _buildDetailPane(BuildContext context, Map<String, dynamic>? os) {
    final c = PesaColors.of(context);
    if (os == null) {
      return const PesaEmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Selecciona un registro del historial',
        subtitle: 'Toca cualquier orden en el panel izquierdo para inspeccionar su equipo, estado de correo y acciones rápidas.',
      );
    }

    final folioTxt = (os['folio_os'] ?? os['folio'] ?? '—').toString().trim();
    final specs = construirEspecificacionesInstrumento(os);
    final cca = extraerNumeroCca(os);
    final dve = extraerNumeroDve(os);
    final fecha = (os['fecha'] ?? '').toString().split('T').first;
    final cerrada = _isCerrada(os);
    final infoCorreo = formatearInfoEnvioCorreo(os);

    Widget metaItem(String label, String value) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: c.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.isNotEmpty ? value : '—',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PesaCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            folioTxt.isNotEmpty ? folioTxt : '—',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: c.textPrimary,
                              letterSpacing: -0.3,
                            ),
                          ),
                          if (fecha.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              'Fecha de servicio: $fecha',
                              style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                    PesaStatusBadge(
                      label: cerrada ? 'Cerrada' : 'En proceso',
                      dotColor: cerrada ? c.dotGreen : c.dotAmber,
                    ),
                  ],
                ),
                if (cca.isNotEmpty || dve.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (cca.isNotEmpty)
                        _pill(context, cca.toUpperCase().startsWith('CCA') ? cca : 'CCA $cca'),
                      if (dve.isNotEmpty)
                        _pill(context, dve.toUpperCase().startsWith('DVE') ? dve : 'DVE $dve'),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        await navegarCapturaSegunTipo(context, Map<String, dynamic>.from(os));
                        await _load();
                      },
                      icon: Icon(cerrada ? Icons.edit_note_rounded : Icons.edit, size: 17),
                      label: Text(cerrada ? 'Abrir / Editar Captura' : 'Capturar Equipo'),
                    ),
                    if (cerrada)
                      OutlinedButton.icon(
                        onPressed: () => _abrirPdfDirecto(os),
                        icon: const Icon(Icons.picture_as_pdf_outlined, size: 17),
                        label: const Text('Ver PDF Oficial'),
                      ),
                  ],
                ),
                if (infoCorreo.isNotEmpty)
                  buildEmailAuditBanner(infoCorreo, margin: const EdgeInsets.only(top: 14)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PesaCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DATOS DEL SERVICIO Y CLIENTE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: c.textSecondary,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 12),
                FoldableFormGrid(
                  unfoldedColumns: 2,
                  spacing: 14,
                  runSpacing: 12,
                  children: [
                    metaItem('Cliente', (os['cliente'] ?? '').toString().trim()),
                    metaItem('Sucursal / Planta', (os['sucursal'] ?? os['direccion'] ?? '').toString().trim()),
                    metaItem('Técnico asignado', (os['tecnico_nombre'] ?? os['tecnico'] ?? '').toString().trim()),
                    metaItem('Tipo de servicio', (os['tipo_servicio'] ?? '').toString().trim()),
                    metaItem('Modalidad', (os['modalidad'] ?? 'Digital').toString().trim()),
                    metaItem('Folio / Lote', (os['id_lote'] ?? os['lote'] ?? 'Individual').toString().trim()),
                  ],
                ),
              ],
            ),
          ),
          if (specs.isNotEmpty) ...[
            const SizedBox(height: 14),
            PesaCard(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ESPECIFICACIONES DEL INSTRUMENTO',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: c.textSecondary,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    specs,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: c.textPrimary,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final cover = isCoverScreen(context);
    final rows = _filtered;

    Map<String, dynamic>? selectedOs;
    if (!cover && rows.isNotEmpty) {
      if (_selectedKey != null) {
        for (final r in rows) {
          if (_rowKey(r) == _selectedKey) {
            selectedOs = r;
            break;
          }
        }
      }
      selectedOs ??= rows.first;
    }

    final listBody = _loading
        ? const Center(child: CircularProgressIndicator(color: _red))
        : rows.isEmpty
            ? const PesaEmptyState(
                icon: Icons.search_off_rounded,
                title: 'Sin coincidencias en el historial',
                subtitle: 'Prueba con otro folio, cliente, serie, CCA o filtro de formato.',
              )
            : ListView.separated(
                padding: EdgeInsets.all(cover ? 12 : 14),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) {
                  final os = rows[i];
                  final isSel = !cover && selectedOs != null && _rowKey(os) == _rowKey(selectedOs);
                  return _buildListItem(ctx, os, isMasterDetail: !cover, isSelected: isSel);
                },
              );

    return AppShell(
      currentRoute: '/historial',
      child: Scaffold(
        backgroundColor: c.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(context, rows, cover),
              Expanded(
                child: cover
                    ? listBody
                    : FoldableTwoPane(
                        startFraction: 0.42,
                        minStartWidth: 280,
                        maxStartWidth: 440,
                        startPane: listBody,
                        endPane: _buildDetailPane(context, selectedOs),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String label) {
    final c = PesaColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: c.textPrimary,
        ),
      ),
    );
  }
}
