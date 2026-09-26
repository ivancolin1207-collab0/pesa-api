// lib/screens/placeholder_screen.dart — Pantalla temporal para módulos en desarrollo
import 'package:flutter/material.dart';
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
    return AppShell(
      currentRoute: route,
      child: Scaffold(
        backgroundColor: const Color(0xFFF9FAFB),
        body: Column(children: [
        // Header corporativo
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 44, 20, 16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFC8102E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(
                  color: Color(0xFF111827),
                  fontWeight: FontWeight.w800, fontSize: 17)),
              Text(description ?? 'Módulo en sincronización',
                  style: const TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
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
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 56, color: const Color(0xFFC8102E)),
            ),
            const SizedBox(height: 20),
            Text(title,
                style: const TextStyle(fontSize: 18,
                    fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 8),
            Text(
              description ?? 'Este módulo estará disponible próximamente.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.sync, size: 14, color: Color(0xFF6B7280)),
                SizedBox(width: 6),
                Text('Módulo en sincronización',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ]),
            ),
          ],
        ))),
        ]),
      ),
    );
  }
}
