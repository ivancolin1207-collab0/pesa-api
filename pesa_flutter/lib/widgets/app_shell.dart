// lib/widgets/app_shell.dart — Layout shell con sidebar corporativo BLANCO (light theme)
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

// ── Tokens corporativos light ───────────────────────────────────────────────
const _red         = Color(0xFFC8102E);
const _redLight    = Color(0xFFFEE2E2); // fondo ítem activo
const _sidebarBg   = Colors.white;
const _sidebarW    = 220.0;
const _textActive  = Color(0xFFC8102E);
const _textInact   = Color(0xFF4B5563);
const _divider     = Color(0xFFE5E7EB);
const _bgGeneral   = Color(0xFFF9FAFB);

/// Items del menú lateral — todos los roles
const _navItemsAll = [
  _NavItem(icon: Icons.dashboard_outlined,        label: 'Dashboard',          route: '/os'),
  _NavItem(icon: Icons.description_outlined,      label: 'Generar Formatos',   route: '/formatos'),
  _NavItem(icon: Icons.history_outlined,          label: 'Buscar / Historial', route: '/historial'),
  _NavItem(icon: Icons.document_scanner_outlined, label: 'Adjuntar Escaneo',   route: '/escaneo'),
  _NavItem(icon: Icons.draw_outlined,             label: 'Mi Firma',           route: '/mi-firma'),
  _NavItem(icon: Icons.category_outlined,         label: 'Catálogos',          route: '/catalogos'),
  _NavItem(icon: Icons.settings_outlined,         label: 'Configuración',      route: '/settings'),
];

/// Items visibles solo para admin/logistica/recepcion (ocultos para técnicos)
const _adminOnlyRoutes = {'/catalogos', '/settings', '/formatos'};

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
    // Para técnicos: sin admin-only, pero CON tecnico-only
    return _navItemsAll
        .where((i) => !_adminOnlyRoutes.contains(i.route))
        .toList();
  }
  // Para admin/logistica: sin tecnico-only
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

/// Shell principal — sidebar permanente en landscape, Drawer en portrait
class AppShell extends StatefulWidget {
  final Widget child;
  final String currentRoute;
  const AppShell({super.key, required this.child, required this.currentRoute});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  StreamSubscription? _sessionSub;

  @override
  void initState() {
    super.initState();
    // Escuchar evento de sesión expirada (401) y redirigir a /login
    _sessionSub = sessionExpiredEvents.stream.listen((_) {
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
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      return Scaffold(
        backgroundColor: _bgGeneral,
        body: Row(children: [
          // Sidebar permanente
          Container(
            width: _sidebarW,
            color: Colors.white,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: _divider)),
            ),
            child: _SidebarContent(currentRoute: widget.currentRoute),
          ),
          // Contenido principal
          Expanded(
            child: Container(color: _bgGeneral, child: widget.child),
          ),
        ]),
      );
    } else {
      // Portrait: drawer
      return Scaffold(
        backgroundColor: _bgGeneral,
        drawer: Drawer(
          backgroundColor: Colors.white,
          child: _SidebarContent(currentRoute: widget.currentRoute),
        ),
        body: widget.child,
      );
    }
  }
}

// ── Contenido del sidebar ───────────────────────────────────────────────────
class _SidebarContent extends StatelessWidget {
  final String currentRoute;
  const _SidebarContent({required this.currentRoute});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        // ── Brand ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: _red, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.scale, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Servicios PESA',
                  style: TextStyle(color: Color(0xFF111827),
                      fontWeight: FontWeight.w800, fontSize: 14)),
              Text('v3.1.2',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 10)),
            ]),
          ]),
        ),
        const Divider(color: _divider, height: 1),

        // ── Label MENÚ ───────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('MENÚ', style: TextStyle(
                color: Colors.grey.shade400, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          ),
        ),

        // ── Ítems ────────────────────────────────────────────────────────
        Builder(builder: (ctx) {
          final auth = ctx.watch<AuthService>();
          final items = _navItemsForRole(auth.role);
          return Column(
            children: items.map((item) =>
              _NavTile(item: item, isActive: currentRoute.startsWith(item.route))
            ).toList(),
          );
        }),

        const Spacer(),
        const Divider(color: _divider, height: 1),

        // ── Perfil usuario ───────────────────────────────────────────────
        _UserProfile(),
      ]),
    );
  }
}

// ── Nav tile ────────────────────────────────────────────────────────────────
class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool     isActive;
  const _NavTile({required this.item, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        if (!isActive) context.go(item.route);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? _redLight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          // Indicador rojo lateral izquierdo cuando activo
          if (isActive)
            Container(width: 3, height: 18, margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: _red,
                    borderRadius: BorderRadius.circular(2))),
          Icon(item.icon, size: 18,
              color: isActive ? _textActive : _textInact),
          const SizedBox(width: 8),
          Text(item.label, style: TextStyle(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              color: isActive ? _textActive : _textInact)),
        ]),
      ),
    );
  }
}

// ── Perfil usuario ──────────────────────────────────────────────────────────
class _UserProfile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth     = context.watch<AuthService>();
    // displayName prioriza nombre_completo sobre username
    final nombre   = auth.displayName;
    final rol      = auth.role ?? 'Técnico';
    // initials calculadas por AuthService (máx 2 letras)
    final initials = auth.initials;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      child: Row(children: [
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
