// lib/screens/mi_firma_screen.dart
// Pantalla de gestión de firma personal del técnico.
// Muestra la firma actual, permite actualizarla y sincronizarla con Render.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/firma_tecnico_service.dart';
import '../widgets/app_shell.dart';

class MiFirmaScreen extends StatefulWidget {
  const MiFirmaScreen({super.key});
  @override
  State<MiFirmaScreen> createState() => _MiFirmaScreenState();
}

class _MiFirmaScreenState extends State<MiFirmaScreen> {
  static const _red = Color(0xFFC8102E);

  final _ctrl = SignatureController(
    penStrokeWidth: 3,
    penColor: const Color(0xFF1D1D1F),
  );

  bool    _cargando    = false;
  bool    _guardando   = false;
  String? _firmaActual;   // base64 de la firma guardada
  String? _msg;           // mensaje de estado

  @override
  void initState() {
    super.initState();
    _cargarFirmaActual();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _cargarFirmaActual() async {
    setState(() => _cargando = true);
    try {
      final auth     = context.read<AuthService>();
      final username = auth.username ?? '';
      final firma    = await FirmaTecnicoService.instance.getFirma(username);
      if (mounted) setState(() => _firmaActual = firma);
    } catch (e) {
      debugPrint('[MiFirma] Error cargando firma: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _guardarFirma() async {
    if (_ctrl.isEmpty) {
      setState(() => _msg = '⚠ Traza tu firma en el área blanca antes de guardar.');
      return;
    }

    setState(() { _guardando = true; _msg = null; });

    try {
      final auth     = context.read<AuthService>();
      final username = auth.username ?? '';
      final idTec    = auth.idTecnico ?? 0;

      final Uint8List? bytes = await _ctrl.toPngBytes();
      if (bytes == null) throw Exception('No se pudo exportar la firma como imagen.');

      final b64 = base64Encode(bytes);

      // 1. Guardar localmente en SecureStorage
      await FirmaTecnicoService.instance.saveFirma(username, b64);

      // 2. Sincronizar con Render si hay conexión y id de técnico
      bool serverOk = false;
      if (idTec > 0 && ApiService.instance.isAuthenticated) {
        try {
          serverOk = await FirmaTecnicoService.instance.saveAndSyncFirma(
              username, b64, idTec);
        } catch (e) {
          debugPrint('[MiFirma] Error sync servidor: $e');
        }
      }

      if (mounted) {
        setState(() {
          _firmaActual = b64;
          _ctrl.clear();
          _msg = serverOk
              ? '✅ Firma guardada y sincronizada con el servidor de Render.'
              : '✅ Firma guardada localmente. Se sincronizará al reconectar.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _msg = '❌ Error al guardar firma: $e');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return AppShell(
      currentRoute: '/mi-firma',
      child: Scaffold(
        backgroundColor: const Color(0xFFF9FAFB),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Encabezado ──────────────────────────────────────────
                _buildHeader(auth),
                const SizedBox(height: 24),

                // ── Firma actual ────────────────────────────────────────
                _buildFirmaActual(),
                const SizedBox(height: 24),

                // ── Canvas para nueva firma ─────────────────────────────
                _buildCanvas(),
                const SizedBox(height: 16),

                // ── Botones ─────────────────────────────────────────────
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Limpiar'),
                      onPressed: () => setState(_ctrl.clear),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      icon: _guardando
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.save_alt, size: 18),
                      label: Text(
                        _guardando ? 'Guardando...' : 'Guardar y Sincronizar',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: _guardando ? null : _guardarFirma,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ]),

                // ── Mensaje de estado ────────────────────────────────────
                if (_msg != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _msg!.contains('✅')
                          ? Colors.green.shade50
                          : _msg!.contains('⚠')
                              ? Colors.orange.shade50
                              : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _msg!.contains('✅')
                            ? Colors.green.shade300
                            : _msg!.contains('⚠')
                                ? Colors.orange.shade300
                                : Colors.red.shade300,
                      ),
                    ),
                    child: Text(
                      _msg!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _msg!.contains('✅')
                            ? Colors.green.shade800
                            : _msg!.contains('⚠')
                                ? Colors.orange.shade800
                                : Colors.red.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AuthService auth) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _red,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.draw, color: Colors.white, size: 26),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Mi Firma Digital',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827))),
          Text(
            auth.nombreCompleto ?? auth.username ?? 'Técnico',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildFirmaActual() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.verified_user, size: 16, color: Color(0xFF6B7280)),
            const SizedBox(width: 6),
            const Text('Firma Actual Registrada',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          ]),
          const SizedBox(height: 12),
          if (_cargando)
            const Center(child: CircularProgressIndicator(color: _red))
          else if (_firmaActual != null && _firmaActual!.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: Image.memory(
                  base64Decode(_firmaActual!),
                  height: 100,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text(
                    'Error al mostrar firma. Registra una nueva.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Sin firma registrada — traza tu firma abajo',
                    style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                  ),
                ],
              ),
            ),
        ]),
      ),
    );
  }

  Widget _buildCanvas() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.edit, size: 16, color: Color(0xFF6B7280)),
            const SizedBox(width: 6),
            const Text('Nueva Firma',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const Spacer(),
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _ctrl.isNotEmpty
                      ? Colors.green.shade100
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _ctrl.isNotEmpty ? '✓ Lista' : 'Pendiente',
                  style: TextStyle(
                    fontSize: 11,
                    color: _ctrl.isNotEmpty
                        ? Colors.green.shade700
                        : Colors.grey,
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Container(
              height: 180,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: _ctrl.isNotEmpty ? _red : Colors.grey.shade300,
                  width: _ctrl.isNotEmpty ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Stack(children: [
                  Signature(controller: _ctrl, backgroundColor: Colors.white),
                  if (_ctrl.isEmpty)
                    const Center(
                      child: Text(
                        'Firma aquí con el dedo o lápiz',
                        style: TextStyle(
                          fontSize: 15,
                          color: Color(0xFFD0D0D0),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Traza tu firma. Esta se usará para firmar automáticamente las órdenes de servicio.',
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ]),
      ),
    );
  }
}
