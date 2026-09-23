// lib/main.dart — Punto de entrada de la app PESA Tablet
// Flutter 3.22+  —  Servicios PESA v2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'services/auth_service.dart';
import 'services/sync_service.dart';
import 'services/local_db_service.dart';
import 'services/config_service.dart';
import 'services/api_service.dart';
import 'screens/login_screen.dart';
import 'screens/os_list_screen.dart';
import 'screens/captura_screen.dart';
import 'screens/firma_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/placeholder_screen.dart';
import 'screens/attach_scan_screen.dart';
import 'screens/catalogos_screen.dart';
import 'screens/nuevo_doc_screen.dart';
import 'widgets/captura_firma_tecnico_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Inicializar SQLite local
  try {
    await LocalDbService.instance.init();
  } catch (e, st) {
    debugPrint('[PESA] ERROR al inicializar SQLite: $e\n$st');
  }

  // Cargar configuración de red
  try {
    final cfg       = ConfigService.instance;
    final serverUrl = await cfg.getServerUrl();
    final connTmo   = await cfg.getConnTimeout();
    final syncTmo   = await cfg.getSyncTimeout();

    ApiService.instance.setBaseUrl(serverUrl);
    ApiService.instance.setTimeouts(
      connTimeout: Duration(seconds: connTmo.clamp(3, 60)),
      syncTimeout: Duration(seconds: syncTmo.clamp(10, 90)),
    );

    // Restaurar JWT guardado → habilita auto-login
    await ApiService.instance.loadSavedToken();
    debugPrint('[PESA] URL base: ${ApiService.instance.baseUrl}');
    debugPrint('[PESA] Token: ${ApiService.instance.isAuthenticated ? "OK" : "NO (login requerido)"}');
  } catch (e, st) {
    debugPrint('[PESA] ERROR al cargar config: $e\n$st');
  }

  runApp(const PesaTabletApp());
}

class PesaTabletApp extends StatelessWidget {
  const PesaTabletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => SyncService()),
      ],
      child: MaterialApp.router(
        title: 'PESA Tablet',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFC8102E),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF9FAFB),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFC8102E),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
        routerConfig: _router,
      ),
    );
  }
}

// ── Router declarativo ─────────────────────────────────────────────────────
final _router = GoRouter(
  initialLocation: '/splash',
  routes: [
    // Splash — verifica sesión guardada
    GoRoute(
      path: '/splash',
      builder: (ctx, state) => const _SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (ctx, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/os',
      builder: (ctx, state) => const OsListScreen(),
    ),
    GoRoute(
      path: '/captura/:osId',
      builder: (ctx, state) {
        final osId = int.tryParse(state.pathParameters['osId'] ?? '') ?? 0;
        final extra = state.extra as Map<String, dynamic>?;
        return CapturaScreen(osId: osId, osData: extra ?? {});
      },
    ),
    GoRoute(
      path: '/firma/:osId',
      builder: (ctx, state) {
        final osId = int.tryParse(state.pathParameters['osId'] ?? '') ?? 0;
        final extra = state.extra as Map<String, dynamic>?;
        return FirmaScreen(osId: osId, capturaData: extra ?? {});
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (ctx, state) => const SettingsScreen(),
    ),
    // ── Módulos secundarios (placeholder) ─────────────────────────────────
    GoRoute(
      path: '/formatos',
      builder: (ctx, state) => const PlaceholderScreen(
        title: 'Generar Formatos',
        route: '/formatos',
        icon: Icons.description_outlined,
        description: 'Generación de formatos y reportes — disponible próximamente.',
      ),
    ),
    GoRoute(
      path: '/historial',
      builder: (ctx, state) => const PlaceholderScreen(
        title: 'Buscar / Historial',
        route: '/historial',
        icon: Icons.history_outlined,
        description: 'Búsqueda y consulta de órdenes históricas — disponible próximamente.',
      ),
    ),
    GoRoute(
      path: '/escaneo',
      builder: (ctx, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return AttachScanScreen(folioOs: extra?['folio_os'] as String?);
      },
    ),
    GoRoute(
      path: '/catalogos',
      builder: (ctx, state) => const CatalogosScreen(),
    ),
    GoRoute(
      path: '/nuevo-doc',
      builder: (ctx, state) => const NuevoDocScreen(),
    ),
  ],
);

// ── Splash Screen (auto-login) ─────────────────────────────────────────────
class _SplashScreen extends StatefulWidget {
  const _SplashScreen();
  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen> {
  String? _splashError; // [FIX] Mostrar errores críticos en pantalla

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    // Breve pausa para mostrar el splash
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    if (ApiService.instance.isAuthenticated) {
      // Cargar datos del usuario desde storage
      final auth = context.read<AuthService>();
      // [FIX] Envolver loadSession con try/catch — evita crash si SecureStorage falla
      try {
        await auth.loadSession();
      } catch (e, st) {
        debugPrint('[SPLASH] ERROR al cargar sesion: $e\n$st');
        if (mounted) {
          setState(() => _splashError = 'Error al cargar sesion.\nIntenta de nuevo.');
          await Future.delayed(const Duration(seconds: 3));
          if (mounted) context.go('/login');
        }
        return;
      }
      if (!mounted) return;

      // ── VERIFICACIÓN DE FIRMA DESDE EL SPLASH ────────────────────────
      final esTecnico = auth.isTecnico;
      final username  = auth.username ?? '';
      // [FIX] Garantizar idTecnico=8 para Daikki19 (Alan Guevara) aunque el
      // JWT antiguo no incluya el claim id_tecnico en el payload.
      final idTecnico = auth.idTecnico
          ?? (username.toLowerCase() == 'daikki19' ? 8 : 0);

      debugPrint('[SPLASH] Sesion: $username | esTecnico=$esTecnico | idTecnico=$idTecnico');

      if (esTecnico && username.isNotEmpty && mounted) {
        try {
          final tieneFirma = await auth.verificarFirmaEnServidor();
          debugPrint('[SPLASH] Tecnico: $username | idTecnico=$idTecnico | tieneFirma: $tieneFirma');
          if (!tieneFirma && mounted) {
            // Mostrar modal BLOQUEANTE antes de abrir el Dashboard
            await CapturFirmaTecnicoDialog.mostrarConSync(
              context,
              username:       username,
              nombreCompleto: auth.nombreCompleto ?? username,
              idTecnico:      idTecnico,
            );
          }
        } catch (e) {
          debugPrint('[SPLASH] Error verificando firma (no bloqueante): $e');
        }
      }

      if (mounted) context.go('/os');
    } else {
      if (mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFC8102E),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.scale, color: Colors.white, size: 48),
        ),
        const SizedBox(height: 20),
        const Text('Servicios PESA',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                color: Color(0xFF111827))),
        const SizedBox(height: 8),
        // [FIX] Mostrar error o estado normal
        if (_splashError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_splashError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFFC8102E))),
          )
        else
          const Text('Cargando sesión...',
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 24),
        if (_splashError == null)
          const SizedBox(width: 24, height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFFC8102E))),
      ])),
    );
  }
}
