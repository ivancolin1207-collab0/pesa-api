// lib/widgets/app_shell.dart — Layout shell con sidebar corporativo BLANCO (light theme) y modo colapsable
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/sync_service.dart';

// ── Tokens corporativos light ───────────────────────────────────────────────
const _red         = Color(0xFFB81D24);
const _redLight    = Color(0xFFFEE2E2); // fondo ítem activo
const _sidebarBg   = Colors.white;
const _sidebarW    = 220.0;
const _textActive  = Color(0xFFB81D24);
const _textInact   = Color(0xFF4B5563);
const _divider     = Color(0xFFE5E7EB);
const _bgGeneral   = Color(0xFFF9FAFB);

/// Items del menú lateral — todos los roles
const _navItemsAll = [
  _NavItem(icon: Icons.dashboard_outlined,        label: 'Dashboard General',   route: '/os'),
  _NavItem(icon: Icons.add_circle_outline,        label: '+ Generar / Asignar', route: '/nuevo-doc'),
  _NavItem(icon: Icons.description_outlined,      label: 'Generar Formatos',    route: '/nuevo-doc'),
  _NavItem(icon: Icons.history_outlined,          label: 'Buscar / Historial',  route: '/historial'),
  _NavItem(icon: Icons.document_scanner_outlined, label: 'Adjuntar Escaneo',    route: '/escaneo'),
  _NavItem(icon: Icons.draw_outlined,             label: 'Mi Firma',            route: '/mi-firma'),
  _NavItem(icon: Icons.category_outlined,         label: 'Catálogos',           route: '/catalogos'),
  _NavItem(icon: Icons.settings_outlined,         label: 'Configuración',       route: '/settings'),
];

/// Labels de ítems exclusivos de administrador (nunca visibles para técnicos)
const _adminOnlyLabels = {'Generar Formatos', '+ Generar / Asignar'};

/// Rutas que solo admin puede ver
const _adminOnlyRoutes = {'/catalogos', '/settings', '/nuevo-doc'};

/// Items visibles SOLO para técnicos (ocultos para admin)
const _tecnicoOnlyRoutes = {'/mi-firma'};

/// Determina si un rol corresponde a un técnico operativo de campo
bool _isTecnicoRole(String? role) {
  if (role == null || role.isEmpty) return false;
  final r = role.toLowerCase().trim()
      .replaceAll('é', 'e')
      .replaceAll('á', 'a')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u');
  return r.contains('tec') ||
         r == 'servicio' ||
         r == 'calibrador' ||
         r == 'inspector' ||
         r == 'operativo';
}

/// Devuelve los items del menú filtrados según el rol del usuario
List<_NavItem> _navItemsForRole(String? role) {
  final isTecnico = _isTecnicoRole(role);
  if (isTecnico) {
    // Los técnicos NUNCA ven ítems de admin ni las rutas admin
    return _navItemsAll
        .where((i) =>
            !_adminOnlyRoutes.contains(i.route) &&
            !_adminOnlyLabels.contains(i.label))
        .toList();
  }
  // Admin / Logística / Recepción: todo excepto ítems exclusivos de técnico
  return _navItemsAll
      .where((i) => !_tecnicoOnlyRoutes.contains(i.route))
      .toList();
}

class _NavItem {
  final IconData icon;
  final String   label;
  final String   route;
  const _NavItem({required this.icon, required this.label, required this.route});
}

enum _SidebarMode { expanded, collapsed, hidden }

/// Shell principal — sidebar permanente/colapsable/ocultable en landscape/tablet, Drawer nativo en móvil
class AppShell extends StatefulWidget {
  final Widget child;
  final String currentRoute;
  const AppShell({super.key, required this.child, required this.currentRoute});

  /// Dispara la apertura del Drawer nativo (móvil) o alterna el estado del menú (tablet/desktop)
  static void toggleMenu(BuildContext context) {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.hasDrawer) {
      if (scaffold.isDrawerOpen) {
        Navigator.of(context).pop();
      } else {
        scaffold.openDrawer();
      }
    } else {
      final state = context.findAncestorStateOfType<_AppShellState>();
      if (state != null) {
        state._cycleSidebarMode();
      }
    }
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  StreamSubscription? _sessionSub;
  _SidebarMode _sidebarMode = _SidebarMode.expanded;

  void _cycleSidebarMode() {
    setState(() {
      switch (_sidebarMode) {
        case _SidebarMode.expanded:
          _sidebarMode = _SidebarMode.collapsed;
          break;
        case _SidebarMode.collapsed:
          _sidebarMode = _SidebarMode.hidden;
          break;
        case _SidebarMode.hidden:
          _sidebarMode = _SidebarMode.expanded;
          break;
      }
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
    final media = MediaQuery.of(context);
    final isTabletOrDesktop = media.size.width >= 768 || media.orientation == Orientation.landscape;

    if (isTabletOrDesktop) {
      final double width = switch (_sidebarMode) {
        _SidebarMode.expanded  => _sidebarW,
        _SidebarMode.collapsed => 64.0,
        _SidebarMode.hidden    => 0.0,
      };

      return Scaffold(
        backgroundColor: _bgGeneral,
        drawer: Drawer(
          backgroundColor: Colors.white,
          child: _SidebarContent(
            currentRoute: widget.currentRoute,
            collapsed: false,
          ),
        ),
        body: Row(children: [
          if (_sidebarMode != _SidebarMode.hidden)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              width: width,
              color: _sidebarBg,
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: _divider)),
              ),
              child: ClipRect(
                child: OverflowBox(
                  maxWidth: _sidebarW,
                  minWidth: _sidebarW,
                  alignment: Alignment.topLeft,
                  child: _SidebarContent(
                    currentRoute: widget.currentRoute,
                    collapsed: _sidebarMode == _SidebarMode.collapsed,
                    onToggle: _cycleSidebarMode,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Container(color: _bgGeneral, child: widget.child),
          ),
        ]),
      );
    } else {
      return Scaffold(
        backgroundColor: _bgGeneral,
        drawer: Drawer(
          backgroundColor: Colors.white,
          child: _SidebarContent(
            currentRoute: widget.currentRoute,
            collapsed: false,
          ),
        ),
        body: widget.child,
      );
    }
  }
}

// ── Contenido del sidebar ───────────────────────────────────────────────────
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
        // ── Brand + Hamburguesa ─────────────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(collapsed ? 8 : 14, 16, collapsed ? 8 : 14, 14),
          child: Row(
            mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              if (onToggle != null)
                IconButton(
                  icon: const Icon(Icons.menu_rounded, color: Color(0xFF374151), size: 22),
                  tooltip: collapsed ? 'Expandir menú' : 'Contraer menú',
                  onPressed: onToggle,
                ),
              if (!collapsed) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _red, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.scale, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Servicios PESA',
                        style: TextStyle(color: Color(0xFF111827),
                            fontWeight: FontWeight.w800, fontSize: 13.5)),
                    Text('ERP Metrológico',
                        style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 9.5)),
                  ]),
                ),
              ],
            ],
          ),
        ),
        const Divider(color: _divider, height: 1),

        // ── Label MENÚ ───────────────────────────────────────────────────
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('MENÚ', style: TextStyle(
                  color: Colors.grey.shade400, fontSize: 9,
                  fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            ),
          ),
        if (collapsed) const SizedBox(height: 8),

        // ── Ítems ────────────────────────────────────────────────────────
        Builder(builder: (ctx) {
          final auth = ctx.watch<AuthService>();
          final items = _navItemsForRole(auth.role);
          return Column(
            children: items.map((item) =>
              _NavTile(
                item: item,
                isActive: currentRoute.startsWith(item.route),
                collapsed: collapsed,
              )
            ).toList(),
          );
        }),

        const Spacer(),
        const Divider(color: _divider, height: 1),

        // ── Perfil usuario ───────────────────────────────────────────────
        _UserProfile(collapsed: collapsed),
      ]),
    );
  }
}

// ── Nav tile ────────────────────────────────────────────────────────────────
class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool     isActive;
  final bool     collapsed;
  const _NavTile({
    required this.item,
    required this.isActive,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      onTap: () {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        if (!isActive) context.go(item.route);
      },
      child: Container(
        margin: EdgeInsets.fromLTRB(collapsed ? 6 : 8, 3, collapsed ? 6 : 8, 3),
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 8 : 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? _redLight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            if (isActive && !collapsed)
              Container(width: 3, height: 18, margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(color: _red,
                      borderRadius: BorderRadius.circular(2))),
            Icon(item.icon, size: 20,
                color: isActive ? _textActive : _textInact),
            if (!collapsed) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(item.label, style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    color: isActive ? _textActive : _textInact)),
              ),
            ],
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

  @override
  Widget build(BuildContext context) {
    final auth     = context.watch<AuthService>();
    final nombre   = auth.displayName;
    final rol      = auth.role ?? 'Técnico';
    final initials = auth.initials;

    return Padding(
      padding: EdgeInsets.fromLTRB(collapsed ? 6 : 12, 10, collapsed ? 6 : 12, 16),
      child: collapsed
          ? Center(
              child: Tooltip(
                message: '$nombre ($rol)',
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: _red,
                  child: Text(initials,
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w800, fontSize: 11)),
                ),
              ),
            )
          : Row(children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: _red,
                child: Text(initials,
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w800, fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nombre, style: const TextStyle(
                    color: Color(0xFF111827), fontWeight: FontWeight.w600, fontSize: 12),
                    overflow: TextOverflow.ellipsis),
                Text(_cap(rol), style: const TextStyle(
                    color: Color(0xFF6B7280), fontSize: 10)),
              ])),
              IconButton(
                icon: const Icon(Icons.logout, size: 17, color: Color(0xFF9CA3AF)),
                tooltip: 'Cerrar Sesión',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Cerrar Sesión'),
                      content: const Text('¿Confirmas que deseas cerrar sesión?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar')),
                        ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: _red, foregroundColor: Colors.white),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Salir')),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    await context.read<AuthService>().logout();
                    context.go('/login');
                  }
                },
              ),
            ]),
    );
  }

  String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
}
