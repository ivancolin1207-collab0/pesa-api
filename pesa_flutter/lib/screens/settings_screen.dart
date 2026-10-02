// lib/screens/settings_screen.dart — Pantalla de Ajustes de Red y Perfil
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/config_service.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';

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
    setState(() {});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final cfg = ConfigService.instance;
    await cfg.setServerUrl(_urlCtrl.text);
    await cfg.setConnTimeout(int.tryParse(_connCtrl.text) ?? 8);
    await cfg.setSyncTimeout(int.tryParse(_syncCtrl.text) ?? 30);
    // Aplicar en caliente
    ApiService.instance.setBaseUrl(_urlCtrl.text);
    ApiService.instance.setTimeouts(
      connTimeout: Duration(seconds: int.tryParse(_connCtrl.text) ?? 8),
      syncTimeout: Duration(seconds: int.tryParse(_syncCtrl.text) ?? 30),
    );
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuracion guardada'), backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() { _testing = true; _testResult = ''; });
    // Ping directo al endpoint de sync para verificar conectividad
    try {
      final resp = await ApiService.instance
          .syncPull(since: DateTime(2000))
          .timeout(const Duration(seconds: 5));
      setState(() => _testResult = 'Servidor alcanzable (${resp.length} OS en servidor)');
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SocketException') || msg.contains('Connection refused')) {
        setState(() => _testResult = 'No se pudo alcanzar el servidor. Verifique la IP y que la laptop este encendida.');
      } else if (msg.contains('Timeout') || msg.contains('TimeoutException')) {
        setState(() => _testResult = 'Tiempo de espera agotado. Servidor no responde en ${_connCtrl.text}s.');
      } else if (msg.contains('401') || msg.contains('403') || msg.contains('login')) {
        setState(() => _testResult = 'Servidor alcanzable (requiere autenticacion).');
      } else {
        setState(() => _testResult = 'Resultado: $msg');
      }
    }
    setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ajustes de Conexion'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await ConfigService.instance.resetToDefaults();
              await _loadConfig();
            },
            icon: const Icon(Icons.restore, color: Colors.white),
            label: const Text('Restablecer', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Servidor Central (laptop PESA)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL del Servidor',
                hintText: 'https://pesa-api-za9i.onrender.com',
                prefixIcon: Icon(Icons.dns),
                border: OutlineInputBorder(),
                helperText: 'URL de producción en Render (o IP local en red Wi-Fi)',
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _connCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Timeout conexion (seg)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _syncCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Timeout sincronizacion (seg)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 24),
            Row(children: [
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: const Text('Guardar'),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find),
                label: const Text('Probar conexion'),
              ),
            ]),
            if (_testResult.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _testResult.contains('alcanzable')
                      ? Colors.green.shade50 : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _testResult.contains('alcanzable')
                        ? Colors.green : Colors.orange),
                ),
                child: Row(children: [
                  Icon(
                    _testResult.contains('alcanzable')
                        ? Icons.check_circle : Icons.warning,
                    color: _testResult.contains('alcanzable')
                        ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_testResult)),
                ]),
              ),
            ],
            const Spacer(),
            const Divider(),

            // ── Sección: Firma del Técnico ───────────────────────────────────
            const Text('Mi Firma de Técnico',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _tieneFirma ? Colors.green.shade50 : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _tieneFirma ? Colors.green.shade300 : Colors.orange.shade300,
                ),
              ),
              child: Row(children: [
                Icon(
                  _tieneFirma ? Icons.verified : Icons.draw_outlined,
                  color: _tieneFirma ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _tieneFirma
                        ? 'Tienes una firma guardada. Se usará automáticamente en cada servicio.'
                        : 'No tienes firma registrada. Se te pedirá firmar al iniciar sesión.',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final auth     = context.read<AuthService>();
                final username = auth.username ?? '';
                final nombre   = auth.nombreCompleto ?? username;
                // Eliminar firma actual para forzar re-captura
                await FirmaTecnicoService.instance.deleteFirma(username);
                if (!mounted) return;
                await CapturFirmaTecnicoDialog.mostrar(
                  context,
                  username: username,
                  nombreCompleto: nombre,
                );
                await _checkFirma();
              },
              icon: const Icon(Icons.draw),
              label: Text(_tieneFirma ? 'Actualizar mi firma' : 'Registrar mi firma'),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const Text(
              'Nota: La app funciona completamente en modo offline.\n'
              'La sincronizacion ocurre automaticamente cuando detecta\n'
              'que el servidor esta disponible en la red.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
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
