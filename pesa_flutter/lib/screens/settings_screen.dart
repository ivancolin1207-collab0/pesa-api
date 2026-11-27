// lib/screens/settings_screen.dart — Pantalla de Ajustes (Apariencia, Red y Firma)
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/config_service.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../theme/pesa_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';
import '../widgets/pesa_components.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl     = TextEditingController();
  final _connCtrl    = TextEditingController();
  final _syncCtrl    = TextEditingController();
  bool  _saving      = false;
  bool  _testing     = false;
  bool  _tieneFirma  = false;
  String _testResult = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _checkFirma();
  }

  Future<void> _checkFirma() async {
    final auth     = context.read<AuthService>();
    final username = auth.username ?? '';
    final tiene    = await FirmaTecnicoService.instance.tieneFirma(username);
    if (mounted) setState(() => _tieneFirma = tiene);
  }

  Future<void> _loadConfig() async {
    final cfg = ConfigService.instance;
    _urlCtrl.text  = await cfg.getServerUrl();
    _connCtrl.text = (await cfg.getConnTimeout()).toString();
    _syncCtrl.text = (await cfg.getSyncTimeout()).toString();
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final cfg = ConfigService.instance;
    await cfg.setServerUrl(_urlCtrl.text);
    await cfg.setConnTimeout(int.tryParse(_connCtrl.text) ?? 8);
    await cfg.setSyncTimeout(int.tryParse(_syncCtrl.text) ?? 30);
    ApiService.instance.setBaseUrl(_urlCtrl.text);
    ApiService.instance.setTimeouts(
      connTimeout: Duration(seconds: int.tryParse(_connCtrl.text) ?? 8),
      syncTimeout: Duration(seconds: int.tryParse(_syncCtrl.text) ?? 30),
    );
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuración guardada')),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    try {
      final resp = await ApiService.instance
          .syncPull(since: DateTime(2000))
          .timeout(const Duration(seconds: 5));
      setState(() => _testResult = 'Servidor alcanzable (${resp.length} OS en servidor)');
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SocketException') || msg.contains('Connection refused')) {
        setState(() => _testResult = 'No se pudo alcanzar el servidor. Verifique la URL o conexión de red.');
      } else if (msg.contains('Timeout') || msg.contains('TimeoutException')) {
        setState(() => _testResult = 'Tiempo de espera agotado. Servidor no responde en ${_connCtrl.text}s.');
      } else if (msg.contains('401') || msg.contains('403') || msg.contains('login')) {
        setState(() => _testResult = 'Servidor alcanzable (requiere autenticación).');
      } else {
        setState(() => _testResult = 'Resultado: $msg');
      }
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final isCompact = MediaQuery.of(context).size.width < 600;

    return AppShell(
      currentRoute: '/settings',
      child: Scaffold(
        backgroundColor: c.canvas,
        appBar: AppBar(
          leading: isCompact
              ? IconButton(
                  icon: Icon(Icons.menu_rounded, color: c.textPrimary),
                  onPressed: () => AppShell.toggleMenu(context),
                )
              : null,
          automaticallyImplyLeading: false,
          title: const Text('Configuración'),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await ConfigService.instance.resetToDefaults();
                await _loadConfig();
              },
              icon: Icon(Icons.restore, size: 18, color: c.brandAccent),
              label: Text('Restablecer', style: TextStyle(color: c.brandAccent)),
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, thickness: 1, color: c.border),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 1. Apariencia (Automático | Claro | Oscuro) ──────────
                  PesaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              c.isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                              size: 20,
                              color: c.brandAccent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Apariencia',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: c.textPrimary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Automático sigue en vivo el tema Claro/Oscuro de la tablet. '
                          'Los pads de firma, PDFs y correos siempre conservan fondo blanco y tinta negra.',
                          style: TextStyle(fontSize: 12.5, color: c.textSecondary, height: 1.35),
                        ),
                        const SizedBox(height: 14),
                        ValueListenableBuilder<ThemeMode>(
                          valueListenable: ThemeController.instance,
                          builder: (_, currentMode, __) => PesaSegmentedSelector<ThemeMode>(
                            options: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
                            selected: currentMode,
                            labelBuilder: (m) {
                              switch (m) {
                                case ThemeMode.system:
                                  return 'Automático';
                                case ThemeMode.light:
                                  return 'Claro';
                                case ThemeMode.dark:
                                  return 'Oscuro';
                              }
                            },
                            onChanged: (m) => ThemeController.instance.setMode(m),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── 2. Servidor Central / Red ────────────────────────────
                  PesaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Servidor Central (PESA API)',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _urlCtrl,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'URL del Servidor',
                            hintText: 'https://pesa-api-za9i.onrender.com',
                            prefixIcon: Icon(Icons.dns_outlined),
                            helperText: 'URL de producción en Render (o IP local en red Wi-Fi)',
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _connCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Timeout conexión (seg)',
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: TextField(
                                controller: _syncCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Timeout sync (seg)',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.save_outlined, size: 18),
                              label: const Text('Guardar'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _testing ? null : _testConnection,
                              icon: _testing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.wifi_find_outlined, size: 18),
                              label: const Text('Probar conexión'),
                            ),
                          ],
                        ),
                        if (_testResult.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: c.surfaceMuted,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _testResult.contains('alcanzable') ? c.dotGreen : c.dotRed,
                              ),
                            ),
                            child: Row(
                              children: [
                                PesaSemanticDot(
                                  color: _testResult.contains('alcanzable') ? c.dotGreen : c.dotAmber,
                                  size: 8,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _testResult,
                                    style: TextStyle(fontSize: 13, color: c.textPrimary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── 3. Firma del Técnico ─────────────────────────────────
                  PesaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mi Firma de Técnico',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: c.surfaceMuted,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            children: [
                              PesaSemanticDot(
                                color: _tieneFirma ? c.dotGreen : c.dotAmber,
                                size: 8,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _tieneFirma
                                      ? 'Tienes una firma guardada. Se usará automáticamente en cada servicio.'
                                      : 'No tienes firma registrada. Se te pedirá firmar al iniciar sesión.',
                                  style: TextStyle(fontSize: 13, color: c.textPrimary),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final auth      = context.read<AuthService>();
                            final username  = auth.username ?? '';
                            final nombre    = auth.nombreCompleto ?? username;
                            final idTecnico = auth.idTecnico ?? 0;
                            if (!mounted) return;
                            final guardada = await CapturFirmaTecnicoDialog.mostrar(
                              context,
                              username: username,
                              nombreCompleto: nombre,
                              idTecnico: idTecnico,
                              permitirCancelar: true,
                            );
                            if (guardada && mounted) {
                              await _checkFirma();
                            }
                          },
                          icon: const Icon(Icons.draw_outlined, size: 18),
                          label: Text(_tieneFirma ? 'Actualizar mi firma' : 'Registrar mi firma'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Nota: La app funciona completamente en modo offline. '
                    'La sincronización ocurre automáticamente cuando detecta '
                    'que el servidor está disponible en la red.',
                    style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _connCtrl.dispose();
    _syncCtrl.dispose();
    super.dispose();
  }
}
