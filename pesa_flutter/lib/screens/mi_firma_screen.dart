// lib/screens/mi_firma_screen.dart
// Pantalla de gestión de firma personal del usuario/técnico con paridad 1:1 Windows y Render.
// Persiste en SharedPreferences/SecureStorage/PNG y sincroniza vía PUT /api/v1/usuarios/{id}/firma.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
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
    penColor: PesaColors.signatureInk,
    exportPenColor: PesaColors.signatureInk,
    exportBackgroundColor: Colors.transparent,
  );

  bool _cargando = false;
  bool _guardando = false;
  bool _isSigning = false;
  String? _firmaActual;
  int _firmaPreviewRevision = 0;
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
      final idTec = auth.idTecnico ?? AuthService.resolveKnownIdTecnico(username) ?? 0;

      // 1. Carga inmediata local
      var firma = await FirmaTecnicoService.instance.getFirma(
        username,
        idTecnico: idTec,
      );
      if (mounted && firma != null && firma.isNotEmpty) {
        setState(() {
          _firmaActual = firma;
          _firmaPreviewRevision++;
          _cargando = false;
        });
      }

      // 2. Sincronizar desde PostgreSQL / Render en segundo plano para reflejar paridad con Windows
      final cloud = await FirmaTecnicoService.instance.syncFirmaFromCloud(username, idTec);
      if (mounted && cloud != null && cloud.isNotEmpty && cloud != _firmaActual) {
        setState(() {
          _firmaActual = cloud;
          _firmaPreviewRevision++;
        });
      }
    } catch (e) {
      debugPrint('[MiFirma] Error cargando firma: $e');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _mostrarDialogoErrorServidor(String detalle) async {
    if (!mounted) return;
    final c = PesaColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.brandAccent),
        ),
        title: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: c.brandAccent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Error al sincronizar firma con servidor',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
            ),
          ],
        ),
        content: SelectableText(
          'La firma se guardó localmente en este dispositivo, pero el servidor devolvió un error:\n\n$detalle',
          style: TextStyle(fontSize: 13, color: c.textPrimary, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
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
      final username = auth.username ?? AuthService.usuarioActual?.username ?? '';
      final idTec = auth.idTecnico ??
          AuthService.usuarioActual?.id ??
          AuthService.resolveKnownIdTecnico(username) ??
          0;

      Uint8List? bytes = await _ctrl.toPngBytes(width: 560, height: 220);
      bytes ??= await _ctrl.toPngBytes();
      if (bytes == null || bytes.lengthInBytes < 64) {
        throw Exception('No se pudo exportar la firma como imagen PNG.');
      }

      var b64 = base64Encode(bytes);

      // 1. Guardar inmediatamente en almacenamiento local (SharedPreferences + SecureStorage + PNG)
      await FirmaTecnicoService.instance.saveFirma(
        username,
        b64,
        idTecnico: idTec,
      );

      // Actualizar también las órdenes locales del usuario en SQLite
      if (idTec > 0) {
        try {
          final sqldb = await LocalDbService.instance.database;
          await sqldb.rawUpdate(
            'UPDATE ordenes_servicio SET firma_tecnico = ?, firma_tecnico_b64 = ? WHERE id_tecnico = ?',
            [b64, b64, idTec],
          );
        } catch (_) {}
      }

      // 2. Persistir en PostgreSQL / Render enviando Content-Type: application/json + Bearer token
      bool serverOk = false;
      String? syncErr;
      try {
        final confirmedB64 = await ApiService.instance.guardarFirmaPerfilConRespuesta(idTec, b64);
        if (confirmedB64.isNotEmpty) {
          b64 = confirmedB64;
          await FirmaTecnicoService.instance.saveFirma(
            username,
            b64,
            idTecnico: idTec,
          );
        }
        serverOk = true;
      } catch (e) {
        syncErr = e.toString().replaceFirst('Exception: ', '');
        debugPrint('[MiFirma] Error sync servidor: $syncErr');
      }

      if (!mounted) return;
      setState(() {
        _firmaActual = b64;
        _firmaPreviewRevision++;
        _ctrl.clear();
        _statusIsError = !serverOk;
        _statusMsg = serverOk
            ? 'Firma actualizada correctamente en el dispositivo y en el servidor.'
            : 'Guardada localmente, error en servidor: $syncErr';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: serverOk ? 3 : 6),
          backgroundColor: serverOk ? PesaColors.textPrimary : PesaColors.brand,
          content: Text(
            serverOk
                ? 'Firma actualizada y sincronizada con éxito (200 OK)'
                : 'Error en servidor al actualizar firma: $syncErr',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      );

      if (!serverOk && syncErr != null) {
        await _mostrarDialogoErrorServidor(syncErr);
      }
    } catch (e) {
      final errTxt = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMsg = 'Error al guardar la firma: $errTxt';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: PesaColors.brand,
            content: Text(
              'Error al guardar la firma: $errTxt',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _abrirModalFirma() async {
    final auth = context.read<AuthService>();
    final username = auth.username ?? '';
    final bytes = await CapturFirmaTecnicoDialog.capturarBytes(
      context,
      username: username,
      nombreCompleto: auth.nombreCompleto ?? username.ifEmptyFallback('Técnico'),
      idTecnico: auth.idTecnico ?? AuthService.resolveKnownIdTecnico(username) ?? 0,
      permitirCancelar: true,
    );
    if (bytes != null && bytes.isNotEmpty && mounted) {
      setState(() {
        _firmaActual = base64Encode(bytes);
        _firmaPreviewRevision++;
        _statusIsError = false;
        _statusMsg = 'Firma guardada correctamente y actualizada en tu perfil.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final auth = context.watch<AuthService>();
    final media = MediaQuery.of(context);
    final bool isWide = media.size.width >= 600;

    return AppShell(
      currentRoute: '/mi-firma',
      child: Scaffold(
        backgroundColor: c.canvas,
        appBar: isWide
            ? null
            : AppBar(
                backgroundColor: c.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                leading: IconButton(
                  icon: Icon(Icons.menu_rounded, color: c.textPrimary),
                  tooltip: 'Menú principal',
                  onPressed: () => AppShell.toggleMenu(context),
                ),
                title: const Text('Mi Firma Digital'),
                actions: [
                  IconButton(
                    tooltip: 'Recargar firma desde servidor',
                    icon: Icon(Icons.sync_rounded, color: c.textPrimary),
                    onPressed: _cargando ? null : _cargarFirmaActual,
                  ),
                ],
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
                    _buildHeader(c, auth, isWide),
                    const SizedBox(height: 16),
                    _buildFirmaActual(c),
                    const SizedBox(height: 16),
                    _buildCanvas(c),
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
                          color: c.surfaceMuted,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _statusIsError ? c.brandAccent : c.border,
                          ),
                        ),
                        child: Row(
                          children: [
                            PesaSemanticDot(
                              color: _statusIsError ? c.dotRed : c.dotGreen,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _statusMsg!,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _statusIsError ? c.brandAccent : c.textPrimary,
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

  Widget _buildHeader(PesaPalette c, AuthService auth, bool isWide) {
    return PesaCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.brand,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.draw_outlined, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mi Firma Digital',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  auth.nombreCompleto ?? auth.username ?? 'Técnico',
                  style: TextStyle(
                    fontSize: 13,
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (isWide) ...[
            IconButton(
              tooltip: 'Sincronizar desde servidor',
              onPressed: _cargando ? null : _cargarFirmaActual,
              icon: Icon(Icons.sync_rounded, color: c.textPrimary),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: _abrirModalFirma,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Modal amplio'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFirmaActual(PesaPalette c) {
    Uint8List? previewBytes;
    if (_firmaActual != null && _firmaActual!.isNotEmpty) {
      try {
        final clean = FirmaTecnicoService.limpiarBase64(_firmaActual!);
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
              Icon(Icons.verified_user_outlined, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Firma Registrada en Perfil',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: c.textPrimary,
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
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(color: c.brandAccent),
              ),
            )
          else if (previewBytes != null)
            Container(
              width: double.infinity,
              height: 112,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: PesaColors.signatureCanvas, // BLINDAJE: fondo blanco para ver tinta negra
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.borderStrong),
              ),
              child: Image.memory(
                previewBytes,
                key: ValueKey('firma_rev_$_firmaPreviewRevision'),
                gaplessPlayback: false,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Text(
                    'No se pudo decodificar la vista previa. Registra tu firma abajo.',
                    style: TextStyle(color: Color(0xFF6E6E73), fontSize: 12),
                  ),
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              decoration: BoxDecoration(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PesaSemanticDot(color: c.dotAmber),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Sin firma registrada — traza tu firma en el recuadro inferior.',
                      style: TextStyle(
                        color: c.textSecondary,
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

  Widget _buildCanvas(PesaPalette c) {
    return PesaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_outlined, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Nueva Firma',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
                color: PesaColors.signatureCanvas, // BLINDAJE OBLIGATORIO: #FFFFFF siempre
                border: Border.all(
                  color: _ctrl.isNotEmpty ? c.brandAccent : c.borderStrong,
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
                              color: Color(0xFF8E8E93),
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
          Text(
            'La firma guardada se aplica automáticamente al cerrar órdenes de servicio y generar PDFs.',
            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

extension _NonEmptyStrExt on String {
  String ifEmptyFallback(String fallback) => trim().isEmpty ? fallback : this;
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
