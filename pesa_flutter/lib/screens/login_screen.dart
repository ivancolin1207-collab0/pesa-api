// lib/screens/login_screen.dart — Pantalla de Login PESA Tablet
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/config_service.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form     = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _urlCtrl  = TextEditingController();
  bool _loading      = false;
  bool _showUrl      = false;
  bool _rememberMe   = true;
  bool _loginedOffline = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Cargar la URL persistida (por defecto Render si es primera ejecución)
    ConfigService.instance.getServerUrl().then((url) {
      if (mounted) setState(() => _urlCtrl.text = url);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFC8102E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.scale, color: Colors.white, size: 48),
                    ),
                    const SizedBox(height: 20),
                    Text('Servicios PESA',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800)),
                    Text('Panel de Técnico',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey)),
                    const SizedBox(height: 28),

                    // Usuario
                    TextFormField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Usuario',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10))),
                      ),
                      validator: (v) => (v?.isEmpty ?? true) ? 'Requerido' : null,
                    ),
                    const SizedBox(height: 14),

                    // Contraseña
                    TextFormField(
                      controller: _passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10))),
                      ),
                      validator: (v) => (v?.isEmpty ?? true) ? 'Requerida' : null,
                    ),

                    // URL servidor (oculto por defecto)
                    if (_showUrl) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'URL del servidor',
                          prefixIcon: Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(10))),
                          helperText: 'Ej: http://192.168.1.100:8000',
                        ),
                      ),
                    ],

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _loginedOffline
                              ? Colors.blue.shade50
                              : Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _loginedOffline
                                  ? Colors.blue.shade300
                                  : Colors.orange.shade300),
                        ),
                        child: Text(_error!,
                            style: TextStyle(
                                color: _loginedOffline
                                    ? Colors.blue.shade800
                                    : Colors.orange.shade800,
                                fontSize: 13)),
                      ),
                    ],

                    // Checkbox: Recordar sesión
                    Row(children: [
                      Checkbox(
                        value: _rememberMe,
                        activeColor: const Color(0xFFC8102E),
                        onChanged: (v) => setState(() => _rememberMe = v ?? true),
                      ),
                      const Text('Recordar sesión',
                          style: TextStyle(fontSize: 13)),
                    ]),
                    const SizedBox(height: 8),

                    // Botón principal
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFC8102E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _loading ? null : _onLogin,
                        child: _loading
                            ? const SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Iniciar Sesión',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // [FIX-OFFLINE] Acceso directo sin conexión al servidor
                    // El técnico entra a las órdenes guardadas en SQLite local.
                    // La sincronización ocurrirá automáticamente al detectar red.
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey.shade700,
                          side: BorderSide(color: Colors.grey.shade400),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.wifi_off, size: 18),
                        label: const Text('Continuar sin conexión',
                            style: TextStyle(fontSize: 14)),
                        onPressed: _loading ? null : _onOfflineAccess,
                      ),
                    ),

                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() => _showUrl = !_showUrl),
                      child: Text(_showUrl ? 'Ocultar configuración' : 'Configurar servidor'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onLogin() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; _error = null; _loginedOffline = false; });

    final username = _userCtrl.text.trim();
    final password = _passCtrl.text.trim();

    // Guardar URL si el usuario la cambió
    final urlIngresada = _urlCtrl.text.trim();
    if (urlIngresada.isNotEmpty) {
      ApiService.instance.setBaseUrl(urlIngresada);
      await ConfigService.instance.setServerUrl(urlIngresada);
    }

    try {
      debugPrint('[LOGIN] Intentando contra: ${ApiService.instance.baseUrl}');

      // Mostrar aviso de "Conectando..." tras 3 segundos de espera
      final warmupTimer = Future<void>.delayed(const Duration(seconds: 3)).then((_) {
        if (mounted && _loading) {
          setState(() => _error =
            '🔄 Conectando con el servidor... Por favor espera.');
        }
      });

      // Intento online con reintentos (3 intentos, 5s entre cada uno)
      String? errorMsg;
      for (int intento = 1; intento <= 3; intento++) {
        errorMsg = await ApiService.instance.login(username, password);
        if (errorMsg == null) break;          // éxito
        if (!mounted) return;

        // Si es error de credenciales (401) no reintentamos
        final es401 = errorMsg.contains('401') ||
                      errorMsg.contains('incorrectas') ||
                      errorMsg.contains('denegado');
        if (es401) break;

        if (intento < 3) {
          setState(() => _error =
            '🔄 Intento $intento/3 — Reintentando en 5s...\n$errorMsg');
          await Future<void>.delayed(const Duration(seconds: 5));
          if (!mounted) return;
        }
      }

      // Cancelar indicador de warmup (ya no relevante)
      warmupTimer.ignore();

      if (!mounted) return;

      if (errorMsg == null) {
        // Login online exitoso
        final auth   = context.read<AuthService>();
        final role   = ApiService.instance.userRole ?? 'tecnico';
        final nombre = ApiService.instance.lastNombre;
        // Extraer id_tecnico del JWT para firma de perfil y sync
        final idTecnico = ApiService.instance.lastIdTecnico;

        await auth.setSession(username, role,
            nombreCompleto: nombre, idTecnico: idTecnico);
        // Guardar hash para futuros logins offline
        await auth.saveOfflineCredentials(username, password, role,
            nombreCompleto: nombre);

        debugPrint('[LOGIN] \u2705 Sesión online — user: $username | rol: $role | idTec: $idTecnico');

        // ── BLOQUEO POR FIRMA ────────────────────────────────────────
        // Para roles técnicos: verificar si tienen firma local.
        final esTecnico = auth.isTecnico;

        if (esTecnico && mounted) {
          final tieneFirma = await auth.verificarFirmaEnServidor();
          if (!tieneFirma && mounted) {
            // MODAL BLOQUEANTE: no navega hasta que el técnico firme
            final firmada = await CapturFirmaTecnicoDialog.mostrarConSync(
              context,
              username:       username,
              nombreCompleto: nombre ?? username,
              idTecnico:      idTecnico ?? (username.toLowerCase() == 'daikki19' ? 8 : 0),
            );
            debugPrint('[LOGIN] Firma capturada en modal: $firmada');
          }
        }

        if (mounted) context.go('/os');
      } else {
        // Online falló — intentar offline
        await _tryOfflineFallback(username, password, errorMsg);
      }
    } catch (unexpectedError) {
      debugPrint('[LOGIN] ❌ Error inesperado: $unexpectedError');
      // También intentar offline en errores de red
      await _tryOfflineFallback(username, password,
          'Sin conexión al servidor: $unexpectedError');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Intenta login offline con hash SHA-256 cuando el servidor no responde.
  Future<void> _tryOfflineFallback(
      String username, String password, String originalError) async {
    if (!mounted) return;
    final auth = context.read<AuthService>();
    final offlineError = await auth.loginOffline(username, password);
    if (offlineError == null) {
      // Offline login exitoso
      setState(() {
        _loginedOffline = true;
        _error = '⚠️ MODO OFFLINE — Trabajando con datos locales. '
                 'Sincronización automática al restaurar conexión.';
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) context.go('/os');
    } else {
      setState(() => _error = '$originalError\n\nAcceso offline: $offlineError');
    }
  }

  /// Acceso offline: navega a la lista de órdenes sin verificar credenciales.
  /// Todas las órdenes en SQLite local estarán disponibles para consultar y editar.
  void _onOfflineAccess() {
    if (mounted) context.go('/os');
  }
}