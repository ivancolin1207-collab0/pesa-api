// lib/screens/catalogos_screen.dart — Gestión Corporativa de Catálogos (Admin CRUD + Solo Lectura Técnicos)
// Clientes (+ Sucursales/Direcciones CRUD) | Técnicos | Tipos de Servicio | Tipos de Instrumento
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/local_db_service.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/pesa_components.dart';

class CatalogosScreen extends StatefulWidget {
  const CatalogosScreen({super.key});

  @override
  State<CatalogosScreen> createState() => _CatalogosScreenState();
}

class _CatalogosScreenState extends State<CatalogosScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final GlobalKey<_ClientesCrudTabState> _clientesKey = GlobalKey();
  final GlobalKey<_SimpleCatalogTabState> _tecnicosKey = GlobalKey();
  final GlobalKey<_SimpleCatalogTabState> _serviciosKey = GlobalKey();
  final GlobalKey<_SimpleCatalogTabState> _instrumentosKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _sincronizarTodo() async {
    try {
      final adminData = await ApiService.instance.getAdminCatalogos();
      if (adminData != null && adminData.isNotEmpty) {
        await LocalDbService.instance.guardarCatalogosAdmin(adminData);
      }
      await _clientesKey.currentState?.reload();
      await _tecnicosKey.currentState?.reload();
      await _serviciosKey.currentState?.reload();
      await _instrumentosKey.currentState?.reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: PesaColors.textPrimary,
            content: Text('Catálogos actualizados desde servidor'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: PesaColors.brand,
            content: Text('Error al sincronizar catálogos: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final bool isAdmin = auth.isAdmin;
    final media = MediaQuery.of(context);
    final bool isWide = media.size.width >= 600;

    return AppShell(
      currentRoute: '/catalogos',
      child: Scaffold(
        backgroundColor: PesaColors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                decoration: const BoxDecoration(
                  color: PesaColors.surface,
                  border: Border(bottom: BorderSide(color: PesaColors.border)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (!isWide)
                          IconButton(
                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                            icon: const Icon(Icons.menu_rounded, color: PesaColors.textPrimary),
                            tooltip: 'Menú principal',
                            onPressed: () => AppShell.toggleMenu(context),
                          ),
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: PesaColors.brand,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.folder_copy_outlined, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Catálogos del Sistema',
                                style: TextStyle(
                                  color: PesaColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 17,
                                ),
                              ),
                              Text(
                                isAdmin
                                    ? 'Administración de clientes, sucursales, técnicos y servicios'
                                    : 'Consulta de clientes, sucursales, técnicos y servicios',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: PesaColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          tooltip: 'Actualizar catálogos',
                          onPressed: _sincronizarTodo,
                          icon: const Icon(Icons.sync_rounded, color: PesaColors.textPrimary),
                        ),
                        if (isAdmin)
                          IconButton(
                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                            tooltip: 'Nuevo documento / asignar orden',
                            onPressed: () => context.push('/nuevo-doc'),
                            icon: const Icon(Icons.post_add_rounded, color: PesaColors.brand),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TabBar(
                      controller: _tabController,
                      isScrollable: !isWide,
                      labelColor: PesaColors.brand,
                      unselectedLabelColor: PesaColors.textSecondary,
                      indicatorColor: PesaColors.brand,
                      indicatorWeight: 2.5,
                      labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                      unselectedLabelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                      tabs: const [
                        Tab(text: 'Clientes y Sucursales'),
                        Tab(text: 'Técnicos'),
                        Tab(text: 'Servicios'),
                        Tab(text: 'Instrumentos'),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _ClientesCrudTab(key: _clientesKey, isAdmin: isAdmin),
                    _SimpleCatalogTab(
                      key: _tecnicosKey,
                      tipo: 'tecnicos',
                      emptyLabel: 'Sin técnicos registrados',
                      icon: Icons.engineering_outlined,
                    ),
                    _SimpleCatalogTab(
                      key: _serviciosKey,
                      tipo: 'servicios',
                      emptyLabel: 'Sin tipos de servicio registrados',
                      icon: Icons.build_outlined,
                    ),
                    _SimpleCatalogTab(
                      key: _instrumentosKey,
                      tipo: 'instrumentos',
                      emptyLabel: 'Sin tipos de instrumento registrados',
                      icon: Icons.scale_outlined,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClientesCrudTab extends StatefulWidget {
  final bool isAdmin;
  const _ClientesCrudTab({super.key, required this.isAdmin});

  @override
  State<_ClientesCrudTab> createState() => _ClientesCrudTabState();
}

class _ClientesCrudTabState extends State<_ClientesCrudTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _clientes = [];
  bool _loading = true;
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> reload({bool forceRemote = false}) async {
    if (mounted) setState(() => _loading = true);
    try {
      var local = await LocalDbService.instance.getCatalogoClientes();
      if (forceRemote || local.isEmpty) {
        final adminData = await ApiService.instance.getAdminCatalogos();
        if (adminData != null && adminData.isNotEmpty) {
          await LocalDbService.instance.guardarCatalogosAdmin(adminData);
          local = await LocalDbService.instance.getCatalogoClientes();
        }
      }
      if (mounted) {
        setState(() {
          _clientes = local;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _abrirFormCliente([Map<String, dynamic>? existente]) async {
    final bool editing = existente != null;
    final razonCtrl = TextEditingController(
      text: (existente?['razon_social'] ?? existente?['nombre'] ?? '').toString(),
    );
    final rfcCtrl = TextEditingController(text: (existente?['rfc'] ?? '').toString());
    final telCtrl = TextEditingController(text: (existente?['telefono'] ?? '').toString());
    final dirCtrl = TextEditingController(text: (existente?['direccion'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: PesaColors.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: PesaColors.border),
          ),
          title: Text(
            editing ? 'Editar Cliente' : 'Nuevo Cliente',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: 460,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: razonCtrl,
                      decoration: const InputDecoration(labelText: 'Razón Social *'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Razón social obligatoria' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: rfcCtrl,
                      decoration: const InputDecoration(labelText: 'RFC (opcional)'),
                      textCapitalization: TextCapitalization.characters,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: telCtrl,
                      decoration: const InputDecoration(labelText: 'Teléfono'),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: dirCtrl,
                      decoration: const InputDecoration(labelText: 'Dirección Fiscal / Matriz'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(dlgCtx).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      setDlgState(() => saving = true);
                      try {
                        if (editing) {
                          final cid = int.tryParse('${existente['id']}') ?? 0;
                          await ApiService.instance.actualizarCliente(
                            cid,
                            razonSocial: razonCtrl.text,
                            rfc: rfcCtrl.text,
                            telefono: telCtrl.text,
                            direccion: dirCtrl.text,
                          );
                        } else {
                          await ApiService.instance.crearCliente(
                            razonSocial: razonCtrl.text,
                            rfc: rfcCtrl.text,
                            telefono: telCtrl.text,
                            direccion: dirCtrl.text,
                          );
                        }
                        if (mounted) Navigator.of(dlgCtx).pop();
                        await reload(forceRemote: true);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: PesaColors.textPrimary,
                              content: Text(editing ? 'Cliente actualizado' : 'Cliente registrado correctamente'),
                            ),
                          );
                        }
                      } catch (e) {
                        setDlgState(() => saving = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: PesaColors.brand,
                              content: Text('Error: $e'),
                            ),
                          );
                        }
                      }
                    },
              child: Text(saving ? 'Guardando...' : 'Guardar Cliente'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _abrirSucursalesCliente(Map<String, dynamic> cliente) async {
    final int clienteId = int.tryParse('${cliente['id']}') ?? 0;
    final String clienteNom = (cliente['razon_social'] ?? cliente['nombre'] ?? '').toString();
    if (clienteId <= 0) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PesaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) => _SucursalesSheet(
        clienteId: clienteId,
        clienteNombre: clienteNom,
        isAdmin: widget.isAdmin,
        onChanged: () => reload(forceRemote: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _clientes
        : _clientes.where((c) {
            final nom = (c['razon_social'] ?? c['nombre'] ?? '').toString().toLowerCase();
            final rfc = (c['rfc'] ?? '').toString().toLowerCase();
            final dir = (c['direccion'] ?? '').toString().toLowerCase();
            return nom.contains(q) || rfc.contains(q) || dir.contains(q);
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Buscar cliente, RFC o dirección...',
                    prefixIcon: const Icon(Icons.search_rounded, color: PesaColors.textSecondary, size: 20),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close, size: 18),
                          )
                        : null,
                  ),
                ),
              ),
              if (widget.isAdmin) ...[
                const SizedBox(width: 10),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => _abrirFormCliente(),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Nuevo Cliente'),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: PesaColors.brand))
              : filtered.isEmpty
                  ? PesaEmptyState(
                      icon: Icons.business_outlined,
                      title: 'Sin clientes coincidentes',
                      subtitle: widget.isAdmin
                          ? 'Crea un nuevo cliente o sincroniza desde el servidor.'
                          : 'Sincroniza catálogos para actualizar el directorio.',
                    )
                  : RefreshIndicator(
                      color: PesaColors.brand,
                      onRefresh: () => reload(forceRemote: true),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, idx) {
                          final c = filtered[idx];
                          final nom = (c['razon_social'] ?? c['nombre'] ?? '—').toString();
                          final rfc = (c['rfc'] ?? '').toString().trim();
                          final tel = (c['telefono'] ?? '').toString().trim();
                          final dir = (c['direccion'] ?? '').toString().trim();
                          final sucs = (c['sucursales'] as List?) ?? const [];

                          return PesaCard(
                            onTap: () => _abrirSucursalesCliente(c),
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        nom,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: PesaColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: [
                                          if (rfc.isNotEmpty)
                                            PesaStatusBadge(label: 'RFC: $rfc'),
                                          if (tel.isNotEmpty)
                                            PesaStatusBadge(label: 'Tel: $tel'),
                                          PesaStatusBadge(
                                            label: '${sucs.length} sucursal(es)',
                                            dotColor: sucs.isNotEmpty
                                                ? PesaColors.dotGreen
                                                : PesaColors.dotNeutral,
                                          ),
                                        ],
                                      ),
                                      if (dir.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          dir,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: PesaColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (widget.isAdmin) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                    tooltip: 'Editar cliente',
                                    onPressed: () => _abrirFormCliente(c),
                                    icon: const Icon(Icons.edit_outlined, color: PesaColors.textSecondary, size: 20),
                                  ),
                                ],
                                IconButton(
                                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                  tooltip: 'Ver / administrar sucursales',
                                  onPressed: () => _abrirSucursalesCliente(c),
                                  icon: const Icon(Icons.location_on_outlined, color: PesaColors.brand, size: 20),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

class _SucursalesSheet extends StatefulWidget {
  final int clienteId;
  final String clienteNombre;
  final bool isAdmin;
  final Future<void> Function() onChanged;

  const _SucursalesSheet({
    required this.clienteId,
    required this.clienteNombre,
    required this.isAdmin,
    required this.onChanged,
  });

  @override
  State<_SucursalesSheet> createState() => _SucursalesSheetState();
}

class _SucursalesSheetState extends State<_SucursalesSheet> {
  List<Map<String, dynamic>> _sucs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSucursales();
  }

  Future<void> _loadSucursales() async {
    if (mounted) setState(() => _loading = true);
    try {
      final remote = await ApiService.instance.getSucursalesCliente(widget.clienteId);
      if (mounted) {
        setState(() {
          _sucs = remote;
          _loading = false;
        });
      }
      return;
    } catch (_) {}
    final local = await LocalDbService.instance.getCatalogoSucursales(
      clienteId: widget.clienteId,
      clienteNombre: widget.clienteNombre,
    );
    if (mounted) {
      setState(() {
        _sucs = local;
        _loading = false;
      });
    }
  }

  Future<void> _abrirFormSucursal([Map<String, dynamic>? existente]) async {
    final editing = existente != null;
    final nomCtrl = TextEditingController(
      text: (existente?['nombre_sucursal'] ?? existente?['nombre'] ?? '').toString(),
    );
    final dirCtrl = TextEditingController(text: (existente?['direccion'] ?? '').toString());
    final conCtrl = TextEditingController(text: (existente?['contacto_nombre'] ?? '').toString());
    final telCtrl = TextEditingController(text: (existente?['contacto_telefono'] ?? '').toString());
    final formKey = GlobalKey<FormState>();
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: PesaColors.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: PesaColors.border),
          ),
          title: Text(editing ? 'Editar Sucursal / Planta' : 'Nueva Sucursal / Planta'),
          content: SizedBox(
            width: 440,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nomCtrl,
                      decoration: const InputDecoration(labelText: 'Nombre Sucursal / Planta *'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Nombre requerido' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: dirCtrl,
                      decoration: const InputDecoration(labelText: 'Dirección Completa *'),
                      maxLines: 2,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Dirección requerida' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: conCtrl,
                      decoration: const InputDecoration(labelText: 'Contacto en Planta'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: telCtrl,
                      decoration: const InputDecoration(labelText: 'Teléfono de Contacto'),
                      keyboardType: TextInputType.phone,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(dlgCtx).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      setDlgState(() => saving = true);
                      try {
                        if (editing) {
                          final sid = int.tryParse('${existente['id']}') ?? 0;
                          await ApiService.instance.actualizarSucursal(
                            widget.clienteId,
                            sid,
                            nombreSucursal: nomCtrl.text,
                            direccion: dirCtrl.text,
                            contactoNombre: conCtrl.text,
                            contactoTelefono: telCtrl.text,
                          );
                        } else {
                          await ApiService.instance.crearSucursal(
                            widget.clienteId,
                            nombreSucursal: nomCtrl.text,
                            direccion: dirCtrl.text,
                            contactoNombre: conCtrl.text,
                            contactoTelefono: telCtrl.text,
                          );
                        }
                        if (mounted) Navigator.of(dlgCtx).pop();
                        await _loadSucursales();
                        await widget.onChanged();
                      } catch (e) {
                        setDlgState(() => saving = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              backgroundColor: PesaColors.brand,
                              content: Text('Error: $e'),
                            ),
                          );
                        }
                      }
                    },
              child: Text(saving ? 'Guardando...' : 'Guardar Sucursal'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sucursales y Plantas',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: PesaColors.textPrimary,
                          ),
                        ),
                        Text(
                          widget.clienteNombre,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: PesaColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.isAdmin)
                    ElevatedButton.icon(
                      onPressed: () => _abrirFormSucursal(),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Nueva'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Flexible(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: PesaColors.brand))
                    : _sucs.isEmpty
                        ? const PesaEmptyState(
                            icon: Icons.location_off_outlined,
                            title: 'Sin sucursales registradas',
                            subtitle: 'Agrega una dirección o planta operativa para este cliente.',
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _sucs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, idx) {
                              final s = _sucs[idx];
                              final nom = (s['nombre_sucursal'] ?? s['nombre'] ?? 'Sucursal').toString();
                              final dir = (s['direccion'] ?? '').toString();
                              final con = (s['contacto_nombre'] ?? '').toString();
                              return PesaCard(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            nom,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13.5,
                                              color: PesaColors.textPrimary,
                                            ),
                                          ),
                                          if (dir.isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              dir,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: PesaColors.textSecondary,
                                              ),
                                            ),
                                          ],
                                          if (con.isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              'Contacto: $con',
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                color: PesaColors.textTertiary,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (widget.isAdmin && s['id'] != null)
                                      IconButton(
                                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                        onPressed: () => _abrirFormSucursal(s),
                                        icon: const Icon(Icons.edit_outlined, size: 19, color: PesaColors.textSecondary),
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
}

class _SimpleCatalogTab extends StatefulWidget {
  final String tipo;
  final String emptyLabel;
  final IconData icon;

  const _SimpleCatalogTab({
    super.key,
    required this.tipo,
    required this.emptyLabel,
    required this.icon,
  });

  @override
  State<_SimpleCatalogTab> createState() => _SimpleCatalogTabState();
}

class _SimpleCatalogTabState extends State<_SimpleCatalogTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (mounted) setState(() => _loading = true);
    List<Map<String, dynamic>> rows = [];
    try {
      if (widget.tipo == 'tecnicos') {
        rows = await LocalDbService.instance.getCatalogoTecnicos();
      } else if (widget.tipo == 'servicios') {
        rows = await LocalDbService.instance.getCatalogoTiposServicio();
      } else {
        rows = await LocalDbService.instance.getCatalogoTiposInstrumento();
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _items = rows;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: PesaColors.brand));
    }
    if (_items.isEmpty) {
      return PesaEmptyState(
        icon: widget.icon,
        title: widget.emptyLabel,
        subtitle: 'Sincroniza catálogos para actualizar registros del servidor.',
      );
    }

    return RefreshIndicator(
      color: PesaColors.brand,
      onRefresh: reload,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, idx) {
          final item = _items[idx];
          if (widget.tipo == 'tecnicos') {
            final nombre = (item['nombre'] ?? item['nombre_completo'] ?? '—').toString();
            final usuario = (item['usuario'] ?? item['username'] ?? '').toString();
            final rol = (item['rol'] ?? 'Técnico').toString();
            final activo = item['activo'] == true || item['activo'] == 1 || item['activo'] == null;
            return PesaCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nombre,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: PesaColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Usuario: $usuario · Rol: $rol',
                          style: const TextStyle(
                            fontSize: 12,
                            color: PesaColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PesaStatusBadge(
                    label: activo ? 'Activo' : 'Inactivo',
                    dotColor: activo ? PesaColors.dotGreen : PesaColors.dotNeutral,
                  ),
                ],
              ),
            );
          }

          final nombre = (item['nombre'] ?? '—').toString();
          final desc = (item['descripcion'] ?? '').toString().trim();
          return PesaCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nombre,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: PesaColors.textPrimary,
                  ),
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: const TextStyle(
                      fontSize: 12,
                      color: PesaColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
