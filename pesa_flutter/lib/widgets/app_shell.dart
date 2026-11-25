// lib/widgets/app_shell.dart — Layout shell adaptativo Samsung Galaxy Z Fold8 Ultra & Tablet
// Pantalla externa (< 600dp): Barra inferior corporativa + Drawer de perfil/overflow
// Pantalla desplegada (>= 600dp): NavigationRail compacto (72dp) expandible a barra lateral (232dp)
// Mantiene un ÚNICO árbol de Scaffold/Row para que widget.child NUNCA se desmonte al plegar/desplegar.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/sync_service.dart';
import '../theme/foldable_layout.dart';

// ── Tokens Apple Minimalist (iOS / iPadOS v3.3.1) — Básculas PESA ───────────
const _red        = Color(0xFFC8102E);
const _redLight   = Color(0xFFF2F2F7);
const _sidebarBg  = Color(0xFFFFFFFF);
const _sidebarW   = 232.0;
const _railW      = 72.0;
const _textActive = Color(0xFFC8102E);
const _textInact  = Color(0xFF6E6E73);
const _divider    = Color(0xFFE5E5EA);
const _bgGeneral  = Color(0xFFF5F5F7);

/// Items del menú lateral — todos los roles
const _navItemsAll = [
  _NavItem(icon: Icons.dashboard_outlined,        label: 'Dashboard',          shortLabel: 'Órdenes',   route: '/os'),
  _NavItem(icon: Icons.add_box_outlined,          label: 'Generar Formatos',   shortLabel: 'Generar',   route: '/nuevo-doc'),
  _NavItem(icon: Icons.history_outlined,          label: 'Buscar / Historial', shortLabel: 'Historial', route: '/historial'),
  _NavItem(icon: Icons.document_scanner_outlined, label: 'Adjuntar Escaneo',   shortLabel: 'Escaneo',   route: '/escaneo'),
  _NavItem(icon: Icons.draw_outlined,             label: 'Mi Firma',           shortLabel: 'Mi Firma',  route: '/mi-firma'),
  _NavItem(icon: Icons.category_outlined,         label: 'Catálogos',          shortLabel: 'Catálogos', route: '/catalogos'),
  _NavItem(icon: Icons.settings_outlined,         label: 'Configuración',      shortLabel: 'Ajustes',   route: '/settings'),
];

const _adminOnlyLabels = {'Generar Formatos', 'Generar / Asignar'};
const _adminOnlyRoutes = {'/catalogos', '/settings', '/nuevo-doc'};
const _tecnicoOnlyRoutes = {'/mi-firma'};

bool _isTecnicoRole(String? role) {
  if (role == null || role.isEmpty) return false;
  if (UsuarioActual.esRolAdmin(role)) return false;
  final r = AuthService.normalizeRole(role);
  return r == 'tecnico' ||
      r == 'servicio' ||
      r == 'calibrador' ||
      r == 'inspector' ||
      r == 'operativo';
}

List<_NavItem> _navItemsForRole(String? role, [String? username]) {
  final isAdmin = UsuarioActual.esRolAdmin(role, username);
  if (isAdmin) {
    return _navItemsAll
        .where((i) => !_tecnicoOnlyRoutes.contains(i.route))
        .toList();
  }
  final isTecnico = _isTecnicoRole(role);
  if (isTecnico) {
    return _navItemsAll
        .where((i) =>
            !_adminOnlyRoutes.contains(i.route) &&
            !_adminOnlyLabels.contains(i.label))
        .toList();
  }
  return _navItemsAll
      .where((i) => !_tecnicoOnlyRoutes.contains(i.route))
      .toList();
}

class _NavItem {
  final IconData icon;
  final String label;
  final String shortLabel;
  final String route;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.shortLabel,
    required this.route,
  });
}

class AppShell extends StatefulWidget {
  final Widget child;
  final String currentRoute;
  const AppShell({super.key, required this.child, required this.currentRoute});

  /// Abre el Drawer en pantalla externa (< 600dp) o alterna Rail compacto ↔ Sidebar expandido (>= 600dp)
  static void toggleMenu(BuildContext context) {
    final shell = context.findAncestorStateOfType<_AppShellState>();
    if (shell != null) {
      shell.alternarMenu();
      return;
    }
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.hasDrawer) {
      if (scaffold.isDrawerOpen) {
        Navigator.of(context).pop();
      } else {
        scaffold.openDrawer();
      }
    }
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  StreamSubscription? _sessionSub;
  bool _isSidebarExpanded = false;
  bool _sidebarAutoAjustado = false;
  bool _usaDrawer = false;
  final GlobalKey<ScaffoldState> _shellScaffoldKey = GlobalKey<ScaffoldState>();

  void alternarMenu() {
    if (_usaDrawer) {
      final s = _shellScaffoldKey.currentState;
      if (s == null) return;
      if (s.isDrawerOpen) {
        s.closeDrawer();
      } else {
        s.openDrawer();
      }
    } else {
      toggleSidebar();
    }
  }

  void toggleSidebar() {
    setState(() {
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  @override
  void initState() {
    super.initState();
    _sessionSub = sessionExpiredEvents.stream.listen((_) async {
      if (!mounted) return;

      final refreshed = await ApiService.instance.silentRefresh();
      if (refreshed) {
        debugPrint('[AppShell] silentRefresh OK — sesión recuperada');
        return;
      }

      try {
        const st = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );
        final savedUser = await st.read(key: 'pesa_username');
        final savedPass = await st.read(key: 'pesa_cred_pass');
        if (savedUser != null && savedPass != null && savedUser.isNotEmpty) {
          final err = await ApiService.instance.login(savedUser, savedPass);
          if (err == null) {
            debugPrint('[AppShell] Auto-relogin OK para $savedUser');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Sesión renovada automáticamente.'),
                  backgroundColor: Color(0xFF16A34A),
                  duration: Duration(seconds: 3),
                ),
              );
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('[AppShell] Error en auto-relogin: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sesión expirada. Por favor inicia sesión nuevamente.'),
            backgroundColor: Color(0xFFC8102E),
            duration: Duration(seconds: 4),
          ),
        );
        context.go('/login');
      }
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool coverMode = isCoverScreen(context);
    final bool wideMode = isWideScreen(context);
    _usaDrawer = coverMode;

    // En tablets muy anchas (>= 960dp) iniciar expandido; en Z Fold desplegado (600-959dp)
    // iniciar en NavigationRail compacto (72dp) para maximizar el área Master–Detail.
    if (!_sidebarAutoAjustado) {
      _sidebarAutoAjustado = true;
      _isSidebarExpanded = wideMode;
    }

    final auth = context.watch<AuthService>();
    final bool isTec = !auth.isAdmin && _isTecnicoRole(auth.role);
    final List<_NavItem> bottomItems = isTec
        ? const [
            _NavItem(icon: Icons.dashboard_outlined,        label: 'Dashboard', shortLabel: 'Órdenes',   route: '/os'),
            _NavItem(icon: Icons.history_outlined,          label: 'Historial', shortLabel: 'Historial', route: '/historial'),
            _NavItem(icon: Icons.document_scanner_outlined, label: 'Escaneo',   shortLabel: 'Escaneo',   route: '/escaneo'),
            _NavItem(icon: Icons.draw_outlined,             label: 'Mi Firma',  shortLabel: 'Mi Firma',  route: '/mi-firma'),
          ]
        : const [
            _NavItem(icon: Icons.dashboard_outlined, label: 'Dashboard', shortLabel: 'Órdenes',   route: '/os'),
            _NavItem(icon: Icons.add_box_outlined,   label: 'Generar',   shortLabel: 'Generar',   route: '/nuevo-doc'),
            _NavItem(icon: Icons.history_outlined,   label: 'Historial', shortLabel: 'Historial', route: '/historial'),
            _NavItem(icon: Icons.category_outlined,  label: 'Catálogos', shortLabel: 'Catálogos', route: '/catalogos'),
          ];
    int selectedIdx = bottomItems.indexWhere((i) => widget.currentRoute.startsWith(i.route));
    if (selectedIdx < 0) selectedIdx = 0;

    // ÚNICO Scaffold + Row persistente → widget.child mantiene 100% su State al plegar/desplegar el Z Fold.
    return Scaffold(
      key: _shellScaffoldKey,
      backgroundColor: _bgGeneral,
      drawer: coverMode
          ? Drawer(
              backgroundColor: Colors.white,
              child: _SidebarContent(
                currentRoute: widget.currentRoute,
                collapsed: false,
              ),
            )
          : null,
      body: SafeArea(
        bottom: !coverMode,
        child: Row(
          children: [
            if (!coverMode)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                width: _isSidebarExpanded ? _sidebarW : _railW,
                decoration: const BoxDecoration(
                  color: _sidebarBg,
                  border: Border(right: BorderSide(color: _divider)),
                ),
                child: _SidebarContent(
                  currentRoute: widget.currentRoute,
                  collapsed: !_isSidebarExpanded,
                  onToggle: toggleSidebar,
                ),
              ),
            Expanded(
              child: Container(
                color: _bgGeneral,
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: coverMode
          ? Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: _divider, width: 1)),
              ),
              child: SafeArea(
                top: false,
                child: NavigationBar(
                  selectedIndex: selectedIdx,
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  indicatorColor: _redLight,
                  height: 62,
                  onDestinationSelected: (idx) {
                    final target = bottomItems[idx].route;
                    if (!widget.currentRoute.startsWith(target)) {
                      context.go(target);
                    }
                  },
                  destinations: bottomItems
                      .map((item) => NavigationDestination(
                            icon: Icon(item.icon, size: 22),
                            selectedIcon: Icon(item.icon, size: 22, color: _red),
                            label: item.shortLabel,
                          ))
                      .toList(),
                ),
              ),
            )
          : null,
    );
  }
}

// ── Contenido del NavigationRail / Sidebar expandible ──────────────────────────
class _SidebarContent extends StatelessWidget {
  final String currentRoute;
  final bool collapsed;
  final VoidCallback? onToggle;

  const _SidebarContent({
    required this.currentRoute,
    this.collapsed = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        // ── Brand + Toggle Rail/Sidebar ────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(collapsed ? 8 : 14, 14, collapsed ? 8 : 14, 12),
          child: collapsed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: onToggle,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _red,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.scale, color: Colors.white, size: 20),
                      ),
                    ),
                    if (onToggle != null) ...[
                      const SizedBox(height: 6),
                      Tooltip(
                        message: 'Expandir menú',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: onToggle,
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.chevron_right_rounded,
                                color: Color(0xFF6B7280), size: 18),
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.scale, color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 9),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Básculas PESA',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(0xFF111827),
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                          ),
                          Text(
                            'Sistema Metrológico',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Color(0xFF6B7280), fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    if (onToggle != null)
                      IconButton(
                        icon: const Icon(Icons.menu_open_rounded,
                            color: Color(0xFF6B7280), size: 20),
                        tooltip: 'Compactar menú',
                        onPressed: onToggle,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
        ),
        const Divider(color: _divider, height: 1),

        // ── Label MENÚ ─────────────────────────────────────────────────────
        if (!collapsed)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'MENÚ',
                style: TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          )
        else
          const SizedBox(height: 8),

        // ── Ítems desplazables si la altura es reducida (ej. modo horizontal) ──
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Builder(builder: (ctx) {
              final auth = ctx.watch<AuthService>();
              final items = _navItemsForRole(auth.role, auth.username);
              return Column(
                children: items
                    .map((item) => _NavTile(
                          item: item,
                          isActive: currentRoute.startsWith(item.route),
                          collapsed: collapsed,
                        ))
                    .toList(),
              );
            }),
          ),
        ),

        const Divider(color: _divider, height: 1),

        // ── Perfil usuario ─────────────────────────────────────────────────
        _UserProfile(collapsed: collapsed),
      ]),
    );
  }
}

// ── Nav tile (NavigationRail compacto o Sidebar completo) ───────────────────
class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool isActive;
  final bool collapsed;
  const _NavTile({
    required this.item,
    required this.isActive,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final tile = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        final scaffold = Scaffold.maybeOf(context);
        if (scaffold != null && scaffold.isDrawerOpen) {
          Navigator.of(context).pop();
        }
        if (!isActive) context.go(item.route);
      },
      child: Container(
        margin: EdgeInsets.fromLTRB(collapsed ? 8 : 8, 3, collapsed ? 8 : 8, 3),
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 4 : 12,
          vertical: collapsed ? 9 : 11,
        ),
        decoration: BoxDecoration(
          color: isActive ? _redLight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isActive
              ? Border.all(color: _divider, width: 1)
              : Border.all(color: Colors.transparent, width: 1),
        ),
        child: collapsed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(item.icon, size: 22, color: isActive ? _textActive : _textInact),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive ? _textActive : _textInact,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  if (isActive)
                    Container(
                      width: 3,
                      height: 18,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Icon(item.icon, size: 20, color: isActive ? _textActive : _textInact),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                        color: isActive ? _textActive : _textInact,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    if (collapsed) {
      return Tooltip(message: item.label, child: tile);
    }
    return tile;
  }
}

// ── Perfil usuario ──────────────────────────────────────────────────────────
class _UserProfile extends StatelessWidget {
  final bool collapsed;
  const _UserProfile({this.collapsed = false});

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showFoldableDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Cerrar Sesión'),
        content: const Text('¿Confirmas que deseas cerrar sesión?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AuthService>().logout();
      if (context.mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final nombre = auth.displayName;
    final rol = auth.role ?? 'Técnico';
    final initials = auth.initials;

    return Padding(
      padding: EdgeInsets.fromLTRB(collapsed ? 6 : 12, 10, collapsed ? 6 : 12, 14),
      child: collapsed
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: '$nombre ($rol)',
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: _red,
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Tooltip(
                  message: 'Cerrar Sesión',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _confirmLogout(context),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.logout, size: 17, color: Color(0xFF9CA3AF)),
                    ),
                  ),
                ),
              ],
            )
          : Row(children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: _red,
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nombre,
                      style: const TextStyle(
                        color: Color(0xFF111827),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _cap(rol),
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.logout, size: 17, color: Color(0xFF9CA3AF)),
                tooltip: 'Cerrar Sesión',
                onPressed: () => _confirmLogout(context),
              ),
            ]),
    );
  }

  String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
}
