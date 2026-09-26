// lib/screens/catalogos_screen.dart — Gestión de catálogos con 4 tabs
// Clientes | Técnicos | Tipos de Servicio | Tipos de Instrumento
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/app_shell.dart';

class CatalogosScreen extends StatefulWidget {
  const CatalogosScreen({super.key});

  @override
  State<CatalogosScreen> createState() => _CatalogosScreenState();
}

class _CatalogosScreenState extends State<CatalogosScreen>
    with SingleTickerProviderStateMixin {
  static const _red    = Color(0xFFC8102E);
  static const _border = Color(0xFFE5E7EB);
  static const _bg     = Color(0xFFF9FAFB);

  late TabController _tabController;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => _currentTab = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      currentRoute: '/catalogos',
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            // Header
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _border)),
              ),
              child: Column(children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: _red, borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.category_outlined,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Catálogos',
                        style: TextStyle(color: Color(0xFF111827),
                            fontWeight: FontWeight.w800, fontSize: 17)),
                    Text('Gestión de clientes, técnicos y tipos de servicio',
                        style: TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
                  ])),
                ]),
                const SizedBox(height: 12),
                // TabBar
                TabBar(
                  controller: _tabController,
                  labelColor: _red,
                  unselectedLabelColor: const Color(0xFF6B7280),
                  indicatorColor: _red,
                  indicatorWeight: 2.5,
                  labelStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700),
                  unselectedLabelStyle: const TextStyle(fontSize: 12),
                  tabs: const [
                    Tab(text: 'Clientes'),
                    Tab(text: 'Técnicos'),
                    Tab(text: 'Tipos Servicio'),
                    Tab(text: 'Tipos Instrumento'),
                  ],
                ),
              ]),
            ),
            // TabBarView
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _CatalogTab(
                    endpoint: '/api/v1/clientes',
                    columns: const ['nombre', 'rfc', 'telefono'],
                    headers: const ['Nombre', 'RFC', 'Teléfono'],
                    emptyLabel: 'Sin clientes registrados',
                  ),
                  _CatalogTab(
                    endpoint: '/api/v1/tecnicos',
                    columns: const ['nombre_completo', 'usuario', 'rol', 'activo'],
                    headers: const ['Nombre', 'Usuario', 'Rol', 'Activo'],
                    emptyLabel: 'Sin técnicos registrados',
                    formatCell: (col, val) {
                      if (col == 'activo') {
                        final active = val == true || val == 1 || val == 'true';
                        return active ? '✓ Activo' : '✗ Inactivo';
                      }
                      return val?.toString() ?? '—';
                    },
                  ),
                  _CatalogTab(
                    endpoint: '/api/v1/tipos-servicio',
                    columns: const ['nombre', 'descripcion'],
                    headers: const ['Tipo de Servicio', 'Descripción'],
                    emptyLabel: 'Sin tipos de servicio',
                  ),
                  _CatalogTab(
                    endpoint: '/api/v1/tipos-instrumento',
                    columns: const ['nombre', 'descripcion'],
                    headers: const ['Tipo de Instrumento', 'Descripción'],
                    emptyLabel: 'Sin tipos de instrumento',
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Tab de catálogo genérico ──────────────────────────────────────────────
class _CatalogTab extends StatefulWidget {
  final String          endpoint;
  final List<String>    columns;
  final List<String>    headers;
  final String          emptyLabel;
  final String Function(String col, dynamic val)? formatCell;

  const _CatalogTab({
    required this.endpoint,
    required this.columns,
    required this.headers,
    required this.emptyLabel,
    this.formatCell,
  });

  @override
  State<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends State<_CatalogTab>
    with AutomaticKeepAliveClientMixin {
  static const _red    = Color(0xFFC8102E);
  static const _border = Color(0xFFE5E7EB);
  static const _th     = Color(0xFFF3F4F6);

  List<Map<String, dynamic>> _items = [];
  bool   _loading = true;
  String _error   = '';

  @override
  bool get wantKeepAlive => true; // Mantener datos al cambiar de tab

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final data = await ApiService.instance.getCatalogo(widget.endpoint);
      if (mounted) setState(() { _items = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() {
        _error   = 'Error al cargar datos: $e';
        _loading = false;
      });
    }
  }

  String _formatValue(String col, dynamic val) {
    if (widget.formatCell != null) return widget.formatCell!(col, val);
    return val?.toString() ?? '—';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _red));
    }

    if (_error.isNotEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
        const SizedBox(height: 12),
        Text(_error, style: const TextStyle(color: Color(0xFF6B7280),
            fontSize: 13), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
              backgroundColor: _red, foregroundColor: Colors.white),
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Reintentar'),
        ),
      ]));
    }

    if (_items.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        Text(widget.emptyLabel,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
      ]));
    }

    return RefreshIndicator(
      color: _red,
      onRefresh: _load,
      child: Column(children: [
        // Encabezado de tabla
        Container(
          color: _th,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _border)),
          ),
          child: Row(children: [
            for (final h in widget.headers)
              Expanded(child: Text(h.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: Color(0xFF374151), letterSpacing: 0.6))),
          ]),
        ),
        // Filas
        Expanded(
          child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (ctx, i) {
              final item   = _items[i];
              final isEven = i % 2 == 0;
              return Container(
                color: isEven ? Colors.white : const Color(0xFFFAFAFA),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _border)),
                ),
                child: Row(children: [
                  for (final col in widget.columns)
                    Expanded(child: Text(
                      _formatValue(col, item[col]),
                      style: TextStyle(
                        fontSize: 12,
                        color: col == widget.columns.first
                            ? const Color(0xFF111827)
                            : const Color(0xFF6B7280),
                        fontWeight: col == widget.columns.first
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    )),
                ]),
              );
            },
          ),
        ),
        // Footer: total de registros
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _border)),
          ),
          child: Row(children: [
            Text('${_items.length} registros',
                style: const TextStyle(fontSize: 11,
                    color: Color(0xFF9CA3AF))),
            const Spacer(),
            Text('Última actualización: ${_formatNow()}',
                style: const TextStyle(fontSize: 10,
                    color: Color(0xFF9CA3AF))),
          ]),
        ),
      ]),
    );
  }

  String _formatNow() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }
}
