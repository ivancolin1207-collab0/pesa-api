// lib/screens/mi_firma_screen.dart
// Pantalla de gestión de firma personal del técnico con estética industrial Básculas PESA.
// Persiste localmente (SecureStorage/archivo) y sincroniza vía PUT/POST /api/v1/usuarios/{id}/firma.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';
import '../widgets/pesa_components.dart';
import '../widgets/signature_shield.dart';

class MiFirmaScreen extends StatefulWidget {
  const MiFirmaScreen({super.key});
  @override
  State<MiFirmaScreen> createState() => _MiFirmaScreenState();
}

class _MiFirmaScreenState extends State<MiFirmaScreen> {
  final SignatureController _ctrl = SignatureController(
    penStrokeWidth: 3.2,
    penColor: PesaColors.textPrimary,
    exportPenColor: PesaColors.textPrimary,
    exportBackgroundColor: Colors.transparent,
  );

  bool _cargando = false;
  bool _guardando = false;
  bool _isSigning = false;
  String? _firmaActual;
  String? _statusMsg;
  bool _statusIsError = false;

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
      final auth = context.read<AuthService>();
      final username = auth.username ?? '';
      final idTec = auth.idTecnico ?? 0;
      final firma = await FirmaTecnicoService.instance.getFirma(
        username,
        idTecnico: idTec,
      );
      if (mounted) setState(() => _firmaActual = firma);
    } catch (e) {
      debugPrint('[MiFirma] Error cargando firma: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _guardarFirma() async {
    if (_guardando) return;
    if (_ctrl.isEmpty || _ctrl.points.length < 2) {
      setState(() {
        _statusIsError = true;
        _statusMsg = 'Traza tu firma completa en el recuadro antes de guardar.';
      });
      return;
    }

    setState(() {
      _guardando = true;
      _statusMsg = null;
      _statusIsError = false;
    });

    try {
      final auth = context.read<AuthService>();
      final username = auth.username ?? '';
      final idTec = auth.idTecnico ?? 0;

      Uint8List? bytes = await _ctrl.toPngBytes(width: 560, height: 220);
      bytes ??= await _ctrl.toPngBytes();
      if (bytes == null || bytes.lengthInBytes < 64) {
        throw Exception('No se pudo exportar la firma como imagen PNG.');
      }

      final b64 = base64Encode(bytes);

      // 1. Persistencia local garantizada
      await FirmaTecnicoService.instance.saveFirma(
        username,
        b64,
        idTecnico: idTec,
      );

      // 2. Persistencia en PostgreSQL / Render
      bool serverOk = false;
      String? syncErr;
      if (idTec > 0 && ApiService.instance.isAuthenticated) {
        try {
          serverOk = await ApiService.instance.guardarFirmaPerfil(idTec, b64);
        } catch (e) {
          syncErr = e.toString().replaceFirst('Exception: ', '');
          debugPrint('[MiFirma] Error sync servidor: $syncErr');
        }
      }

      if (!mounted) return;
      setState(() {
        _firmaActual = b64;
        _ctrl.clear();
        _statusIsError = !serverOk && syncErr != null;
        _statusMsg = serverOk
            ? 'Firma guardada correctamente y sincronizada con el servidor.'
            : (syncErr != null
                ? 'Firma guardada en dispositivo. Error al sincronizar: $syncErr'
                : 'Firma guardada correctamente en el dispositivo.');
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: (!serverOk && syncErr != null)
              ? PesaColors.dotAmber
              : PesaColors.textPrimary,
          content: const Text(
            'Firma guardada correctamente',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMsg = 'Error al guardar la firma: ${e.toString().replaceFirst('Exception: ', '')}';
        });
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _abrirModalFirma() async {
    final auth = context.read<AuthService>();
    final bytes = await CapturFirmaTecnicoDialog.capturarBytes(
      context,
      username: auth.username ?? '',
      nombreCompleto: auth.nombreCompleto ?? auth.username ?? 'Técnico',
      idTecnico: auth.idTecnico ?? 0,
      permitirCancelar: true,
    );
    if (bytes != null && bytes.isNotEmpty && mounted) {
      setState(() {
        _firmaActual = base64Encode(bytes);
        _statusIsError = false;
        _statusMsg = 'Firma guardada correctamente y actualizada en tu perfil.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final media = MediaQuery.of(context);
    final bool isWide = media.size.width >= 600;

    return AppShell(
      currentRoute: '/mi-firma',
      child: Scaffold(
        backgroundColor: PesaColors.canvas,
        appBar: isWide
            ? null
            : AppBar(
                backgroundColor: PesaColors.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.menu_rounded, color: PesaColors.textPrimary),
                  tooltip: 'Menú principal',
                  onPressed: () => AppShell.toggleMenu(context),
                ),
                title: const Text('Mi Firma Digital'),
              ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SingleChildScrollView(
                physics: _isSigning
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(auth, isWide),
                    const SizedBox(height: 16),
                    _buildFirmaActual(),
                    const SizedBox(height: 16),
                    _buildCanvas(),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Limpiar'),
                              onPressed: _guardando
                                  ? null
                                  : () => setState(() {
                                        _ctrl.clear();
                                        _statusMsg = null;
                                      }),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              icon: _guardando
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: Text(
                                _guardando ? 'Guardando...' : 'Guardar y Sincronizar',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              onPressed: _guardando ? null : _guardarFirma,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_statusMsg != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: _statusIsError
                              ? const Color(0xFFFFF5F6)
                              : PesaColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _statusIsError ? PesaColors.brand : PesaColors.borderStrong,
                          ),
                        ),
                        child: Row(
                          children: [
                            PesaSemanticDot(
                              color: _statusIsError
                                  ? PesaColors.brand
                                  : PesaColors.dotGreen,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _statusMsg!,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _statusIsError
                                      ? PesaColors.brand
                                      : PesaColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AuthService auth, bool isWide) {
    return PesaCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: PesaColors.brand,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.draw_outlined, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Mi Firma Digital',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: PesaColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  auth.nombreCompleto ?? auth.username ?? 'Técnico',
                  style: const TextStyle(
                    fontSize: 13,
                    color: PesaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (isWide)
            OutlinedButton.icon(
              onPressed: _abrirModalFirma,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Modal amplio'),
            ),
        ],
      ),
    );
  }

  Widget _buildFirmaActual() {
    Uint8List? previewBytes;
    if (_firmaActual != null && _firmaActual!.isNotEmpty) {
      try {
        final clean = _firmaActual!.contains(',')
            ? _firmaActual!.split(',').last.trim()
            : _firmaActual!.trim();
        previewBytes = base64Decode(clean);
      } catch (_) {}
    }

    return PesaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined, size: 16, color: PesaColors.textSecondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Firma Registrada en Perfil',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: PesaColors.textPrimary,
                  ),
                ),
              ),
              PesaStatusBadge(
                label: previewBytes != null ? 'Activa' : 'Sin registro',
                dotColor: previewBytes != null ? PesaColors.dotGreen : PesaColors.dotAmber,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_cargando)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(color: PesaColors.brand),
              ),
            )
          else if (previewBytes != null)
            Container(
              width: double.infinity,
              height: 112,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: PesaColors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: PesaColors.border),
              ),
              child: Image.memory(
                previewBytes,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Text(
                    'No se pudo decodificar la vista previa. Registra tu firma abajo.',
                    style: TextStyle(color: PesaColors.textSecondary, fontSize: 12),
                  ),
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              decoration: BoxDecoration(
                color: PesaColors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: PesaColors.border),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PesaSemanticDot(color: PesaColors.dotAmber),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Sin firma registrada — traza tu firma en el recuadro inferior.',
                      style: TextStyle(
                        color: PesaColors.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    return PesaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_outlined, size: 16, color: PesaColors.textSecondary),
              const SizedBox(width: 8),
              const Text(
                'Nueva Firma',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: PesaColors.textPrimary,
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => PesaStatusBadge(
                  label: _ctrl.isNotEmpty ? 'Trazo listo' : 'Pendiente',
                  dotColor: _ctrl.isNotEmpty ? PesaColors.dotGreen : PesaColors.dotNeutral,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Container(
              height: 196,
              decoration: BoxDecoration(
                color: PesaColors.surface,
                border: Border.all(
                  color: _ctrl.isNotEmpty ? PesaColors.brand : PesaColors.borderStrong,
                  width: _ctrl.isNotEmpty ? 1.5 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      child: CustomPaint(painter: _MiFirmaGuidePainter()),
                    ),
                    SignatureGestureShield(
                      onSigningChanged: (v) {
                        if (mounted && v != _isSigning) {
                          setState(() => _isSigning = v);
                        }
                      },
                      child: Signature(
                        controller: _ctrl,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                    if (_ctrl.isEmpty)
                      const IgnorePointer(
                        child: Center(
                          child: Text(
                            'Firma aquí con el dedo o lápiz',
                            style: TextStyle(
                              fontSize: 14,
                              color: PesaColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'La firma guardada se aplica automáticamente al cerrar órdenes de servicio y generar PDFs.',
            style: TextStyle(fontSize: 11.5, color: PesaColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MiFirmaGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = PesaColors.border
      ..strokeWidth = 1.0;
    final y = size.height * 0.74;
    canvas.drawLine(Offset(20, y), Offset(size.width - 20, y), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
