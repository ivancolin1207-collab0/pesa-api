// lib/screens/placeholder_screen.dart — Pantalla temporal para módulos en desarrollo
import 'package:flutter/material.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';

class PlaceholderScreen extends StatelessWidget {
  final String title;
  final String route;
  final IconData icon;
  final String? description;

  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.route,
    required this.icon,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return AppShell(
      currentRoute: route,
      child: Scaffold(
        backgroundColor: c.canvas,
        body: Column(children: [
          // Header corporativo
          Container(
            padding: const EdgeInsets.fromLTRB(20, 44, 20, 16),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.brand,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w800, fontSize: 17)),
                Text(description ?? 'Módulo en sincronización',
                    style: TextStyle(color: c.textSecondary, fontSize: 11)),
              ]),
            ]),
          ),
          // Cuerpo
          Expanded(child: Center(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: c.surfaceElevated,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.border),
                ),
                child: Icon(icon, size: 56, color: c.brandAccent),
              ),
              const SizedBox(height: 20),
              Text(title,
                  style: TextStyle(fontSize: 18,
                      fontWeight: FontWeight.w700, color: c.textPrimary)),
              const SizedBox(height: 8),
              Text(
                description ?? 'Este módulo estará disponible próximamente.',
                style: TextStyle(fontSize: 13, color: c.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: c.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.sync, size: 14, color: c.textSecondary),
                  const SizedBox(width: 6),
                  Text('Módulo en sincronización',
                      style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ]),
              ),
            ],
          ))),
        ]),
      ),
    );
  }
}
