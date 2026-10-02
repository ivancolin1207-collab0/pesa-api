// lib/screens/login_screen.dart — Pantalla de Login PESA Tablet
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/config_service.dart';
import '../services/local_db_service.dart';
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

  bool _obscurePassword = true;

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
    const carmineRed  = Color(0xFFB81D24);
    const bgGray      = Color(0xFFF5F5F7);
    const cardBorder  = Color(0xFFE5E5EA);
    const fieldBg     = Color(0xFFFAFAFA);
    const fieldBorder = Color(0xFFD1D1D6);
    const subTitleColor = Color(0xFF86868B);
    const textDark    = Color(0xFF1D1D1F);

    return Scaffold(
      backgroundColor: bgGray,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Encabezado: Logotipo vectorial y subtítulo
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: carmineRed,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x33B81D24),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            )
                          ],
                        ),
                        child: const Icon(Icons.scale_rounded, color: Colors.white, size: 40),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'BÁSCULAS PESA',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: textDark,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Ecosistema Metrológico Operativo',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: subTitleColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),

                      // Campo Usuario
                      TextFormField(
                        controller: _userCtrl,
                        style: const TextStyle(fontSize: 14, color: textDark),
                        decoration: InputDecoration(
                          labelText: 'Usuario',
                          labelStyle: const TextStyle(color: subTitleColor, fontSize: 13),
                          prefixIcon: const Icon(Icons.person_outline_rounded, color: subTitleColor, size: 20),
                          filled: true,
                          fillColor: fieldBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: fieldBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: fieldBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: carmineRed, width: 2),
                          ),
                        ),
                        validator: (v) => (v?.isEmpty ?? true) ? 'Requerido' : null,
                      ),
                      const SizedBox(height: 16),

                      // Campo Contraseña con mostrar/ocultar
                      TextFormField(
                        controller: _passCtrl,
                        obscureText: _obscurePassword,
                        style: const TextStyle(fontSize: 14, color: textDark),
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          labelStyle: const TextStyle(color: subTitleColor, fontSize: 13),
                          prefixIcon: const Icon(Icons.lock_outline_rounded, color: subTitleColor, size: 20),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: subTitleColor,
                              size: 20,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          filled: true,
                          fillColor: fieldBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: fieldBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: fieldBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: carmineRed, width: 2),
                          ),
                        ),
                        validator: (v) => (v?.isEmpty ?? true) ? 'Requerida' : null,
                      ),

                      // URL servidor (oculto por defecto)
                      if (_showUrl) ...[
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _urlCtrl,
                          style: const TextStyle(fontSize: 13, color: textDark),
                          decoration: InputDecoration(
                            labelText: 'URL del servidor',
                            labelStyle: const TextStyle(color: subTitleColor, fontSize: 13),
                            prefixIcon: const Icon(Icons.dns_outlined, color: subTitleColor, size: 20),
                            filled: true,
                            fillColor: fieldBg,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: fieldBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: carmineRed, width: 2),
                            ),
                            helperText: 'Ej: https://pesa-api-za9i.onrender.com',
                          ),
                        ),
                      ],

                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _loginedOffline
                                ? const Color(0xFFEFF6FF)
                                : const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: _loginedOffline
                                    ? const Color(0xFFBFDBFE)
                                    : const Color(0xFFFCA5A5)),
                          ),
                          child: Text(_error!,
                              style: TextStyle(
                                  color: _loginedOffline
                                      ? const Color(0xFF1E40AF)
                                      : const Color(0xFF991B1B),
                                  fontSize: 12.5)),
                        ),
                      ],

                      const SizedBox(height: 8),
                      // Checkbox: Recordar sesión
                      Row(children: [
                        Checkbox(
                          value: _rememberMe,
                          activeColor: carmineRed,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          onChanged: (v) => setState(() => _rememberMe = v ?? true),
                        ),
                        const Text('Recordar sesión',
                            style: TextStyle(fontSize: 13, color: textDark)),
                      ]),
                      const SizedBox(height: 12),

                      // Botón principal Iniciar Sesión
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: carmineRed,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _loading ? null : _onLogin,
                          child: _loading
                              ? const SizedBox(
                                  width: 22, height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Text('Iniciar Sesión',
                                  style: TextStyle(
                                      fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Acceso directo sin conexión al servidor
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: textDark,
                            side: const BorderSide(color: fieldBorder),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.wifi_off_rounded, size: 18, color: subTitleColor),
                          label: const Text('Continuar sin conexión',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          onPressed: _loading ? null : _onOfflineAccess,
                        ),
                      ),

                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => setState(() => _showUrl = !_showUrl),
                        child: Text(
                          _showUrl ? 'Ocultar configuración' : 'Configurar servidor',
                          style: const TextStyle(color: subTitleColor, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
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

        // [PRIVACIDAD ESTRICTA] Purga de órdenes de otros técnicos al iniciar sesión
        final esTecnico = auth.isTecnico;
        if (esTecnico) {
          await LocalDbService.instance.purgarOrdenesDeOtrosTecnicos(
            currentIdTecnico: idTecnico,
            currentNombre: nombre,
            isAdmin: false,
          );
        }

        // ── BLOQUEO POR FIRMA ────────────────────────────────────────
        // Para roles técnicos: verificar si tienen firma local.
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
      // [PRIVACIDAD ESTRICTA] Purga offline de órdenes de otros técnicos
      if (auth.isTecnico) {
        await LocalDbService.instance.purgarOrdenesDeOtrosTecnicos(
          currentIdTecnico: auth.idTecnico,
          currentNombre: auth.displayName,
          isAdmin: false,
        );
      }
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