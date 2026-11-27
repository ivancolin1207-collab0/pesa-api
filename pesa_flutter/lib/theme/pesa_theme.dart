// lib/theme/pesa_theme.dart
// Sistema de Diseño Dual Apple Minimalista (Claro / Oscuro / Automático del Sistema)
// Básculas PESA — Flutter Android & Samsung Galaxy Z Fold8 Ultra (v4.0.5)
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Paleta semántica resuelta dinámicamente para Modo Claro o Modo Nocturno (Apple Dark).
class PesaPalette {
  final bool isDark;
  final Color canvas;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceMuted;
  final Color surfaceHover;
  final Color tableHeader;
  final Color border;
  final Color borderStrong;
  final Color divider;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color brand;
  final Color brandHover;
  final Color brandPressed;
  final Color brandAccent;
  final Color dotGreen;
  final Color dotAmber;
  final Color dotRed;
  final Color dotNeutral;

  const PesaPalette({
    required this.isDark,
    required this.canvas,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceMuted,
    required this.surfaceHover,
    required this.tableHeader,
    required this.border,
    required this.borderStrong,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brand,
    required this.brandHover,
    required this.brandPressed,
    required this.brandAccent,
    required this.dotGreen,
    required this.dotAmber,
    required this.dotRed,
    required this.dotNeutral,
  });

  /// Paleta Apple Minimalista Claro
  static const PesaPalette light = PesaPalette(
    isDark: false,
    canvas: Color(0xFFF5F5F7),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFF2F2F7),
    surfaceMuted: Color(0xFFF2F2F7),
    surfaceHover: Color(0xFFE5E5EA),
    tableHeader: Color(0xFFFBFBFD),
    border: Color(0xFFE5E5EA),
    borderStrong: Color(0xFFD2D2D7),
    divider: Color(0xFFF2F2F7),
    textPrimary: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF6E6E73),
    textTertiary: Color(0xFF8E8E93),
    brand: Color(0xFFC8102E),
    brandHover: Color(0xFFA60D26),
    brandPressed: Color(0xFF880B20),
    brandAccent: Color(0xFFC8102E),
    dotGreen: Color(0xFF34C759),
    dotAmber: Color(0xFFFF9500),
    dotRed: Color(0xFFC8102E),
    dotNeutral: Color(0xFF6E6E73),
  );

  /// Paleta Oficial Apple Dark — Básculas PESA
  static const PesaPalette dark = PesaPalette(
    isDark: true,
    canvas: Color(0xFF121214),
    surface: Color(0xFF1C1C1E),
    surfaceElevated: Color(0xFF2C2C2E),
    surfaceMuted: Color(0xFF2C2C2E),
    surfaceHover: Color(0xFF323236),
    tableHeader: Color(0xFF2C2C2E),
    border: Color(0xFF38383A),
    borderStrong: Color(0xFF38383A),
    divider: Color(0xFF38383A),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0xFF98989D),
    textTertiary: Color(0xFF636366),
    brand: Color(0xFFC8102E),
    brandHover: Color(0xFFA60D26),
    brandPressed: Color(0xFF880B20),
    brandAccent: Color(0xFFF03E55),
    dotGreen: Color(0xFF30D158),
    dotAmber: Color(0xFFFF9F0A),
    dotRed: Color(0xFFFF453A),
    dotNeutral: Color(0xFF98989D),
  );

  /// Alias ergonómicos de paleta para todas las pantallas
  Color get elevated => surfaceElevated;
  Color get hover => surfaceHover;
  Color get tableHead => tableHeader;
  Color get brandSoft => isDark ? const Color(0x33F03E55) : const Color(0xFFFCE8E9);

  /// Superficie y tinta blindadas para áreas de firma y PDF (siempre blanco + negro).
  Color get signatureCanvas => PesaColors.signatureCanvas;
  Color get signatureInk => PesaColors.signatureInk;
}

class PesaColors {
  PesaColors._();

  /// Resuelve dinámicamente la paleta según el `Brightness` del `Theme` activo.
  static PesaPalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? PesaPalette.dark
        : PesaPalette.light;
  }

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  // Blindaje obligatorio para pads de firma y PDFs
  static const Color signatureCanvas = Color(0xFFFFFFFF);
  static const Color signatureInk = Color(0xFF000000);

  // Tokens constantes base (compatibilidad y modo claro)
  static const Color canvas = Color(0xFFF5F5F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceMuted = Color(0xFFF2F2F7);
  static const Color tableHeader = Color(0xFFFBFBFD);

  static const Color border = Color(0xFFE5E5EA);
  static const Color borderStrong = Color(0xFFD2D2D7);
  static const Color divider = Color(0xFFF2F2F7);

  static const Color textPrimary = Color(0xFF1D1D1F);
  static const Color textSecondary = Color(0xFF6E6E73);
  static const Color textTertiary = Color(0xFF8E8E93);

  // Único acento corporativo Básculas PESA
  static const Color brand = Color(0xFFC8102E);
  static const Color brandHover = Color(0xFFA60D26);
  static const Color brandPressed = Color(0xFF880B20);
  static const Color brandAccentDark = Color(0xFFF03E55);

  // Tokens Apple Dark de referencia directa
  static const Color darkCanvas = Color(0xFF121214);
  static const Color darkSurface = Color(0xFF1C1C1E);
  static const Color darkElevated = Color(0xFF2C2C2E);
  static const Color darkHover = Color(0xFF323236);
  static const Color darkBorder = Color(0xFF38383A);
  static const Color darkTextPrimary = Color(0xFFF5F5F7);
  static const Color darkTextSecondary = Color(0xFF98989D);
  static const Color darkTextTertiary = Color(0xFF636366);

  // Puntos semánticos discretos
  static const Color dotGreen = Color(0xFF34C759);
  static const Color dotAmber = Color(0xFFFF9500);
  static const Color dotRed = Color(0xFFC8102E);
  static const Color dotNeutral = Color(0xFF6E6E73);

  static const Color dotGreenDark = Color(0xFF30D158);
  static const Color dotAmberDark = Color(0xFFFF9F0A);
  static const Color dotRedDark = Color(0xFFFF453A);
}

/// Controlador reactivo ligero para Modo Claro / Oscuro / Automático del Sistema.
/// - Valor predeterminado obligatorio en primer inicio: `ThemeMode.system`.
/// - Persistencia local en `SharedPreferences` (`pesa_theme_mode`).
class ThemeController extends ValueNotifier<ThemeMode> {
  static final ThemeController instance = ThemeController._();
  static const String _prefKey = 'pesa_theme_mode';

  ThemeController._() : super(ThemeMode.system);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      value = _decode(saved);
    } catch (_) {
      value = ThemeMode.system;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (value != mode) {
      value = mode;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, _encode(mode));
    } catch (_) {}
  }

  /// Alterna en 1 toque entre Modo Claro y Modo Oscuro respetando el estado efectivo actual.
  Future<void> toggleLightDark(BuildContext context) async {
    final currentlyDark = Theme.of(context).brightness == Brightness.dark;
    await setMode(currentlyDark ? ThemeMode.light : ThemeMode.dark);
  }

  void resetForTest([ThemeMode mode = ThemeMode.system]) {
    value = mode;
  }

  static ThemeMode _decode(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

class PesaTheme {
  PesaTheme._();

  static const TextStyle tabularNumber = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static ThemeData get lightTheme => _buildTheme(PesaPalette.light);

  static ThemeData get darkTheme => _buildTheme(PesaPalette.dark);

  static ThemeData _buildTheme(PesaPalette p) {
    final brightness = p.isDark ? Brightness.dark : Brightness.light;
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: p.isDark ? p.brandAccent : p.brand,
      onPrimary: Colors.white,
      primaryContainer: p.surfaceElevated,
      onPrimaryContainer: p.textPrimary,
      secondary: p.textPrimary,
      onSecondary: p.isDark ? p.canvas : Colors.white,
      secondaryContainer: p.surfaceElevated,
      onSecondaryContainer: p.textPrimary,
      surface: p.surface,
      onSurface: p.textPrimary,
      surfaceContainerHighest: p.surfaceElevated,
      onSurfaceVariant: p.textSecondary,
      outline: p.borderStrong,
      outlineVariant: p.border,
      error: p.dotRed,
      onError: Colors.white,
    );

    final inputFill = p.isDark ? p.surfaceElevated : p.surface;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      cardColor: p.surface,
      dividerColor: p.divider,
      hoverColor: p.surfaceHover,
      highlightColor: p.surfaceHover,
      visualDensity: VisualDensity.standard,
      textTheme: (p.isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme).apply(
        bodyColor: p.textPrimary,
        displayColor: p.textPrimary,
      ),
      iconTheme: IconThemeData(color: p.textPrimary),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.border, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.surface,
        foregroundColor: p.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: p.textPrimary),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.brandAccent,
        unselectedLabelColor: p.textSecondary,
        indicatorColor: p.brandAccent,
        dividerColor: p.border,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: TextStyle(color: p.textTertiary, fontSize: 14),
        labelStyle: TextStyle(color: p.textSecondary, fontSize: 13),
        helperStyle: TextStyle(color: p.textSecondary, fontSize: 12),
        prefixIconColor: p.textSecondary,
        suffixIconColor: p.textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.brandAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.dotRed, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.dotRed, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: p.surfaceElevated,
          disabledForegroundColor: p.textTertiary,
          elevation: 0,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: p.isDark ? p.surfaceElevated : p.surface,
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.borderStrong),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.brandAccent,
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.isDark ? p.surfaceElevated : p.surface,
        selectedColor: p.brand,
        disabledColor: p.surfaceMuted,
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: p.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.surfaceElevated,
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? p.brandAccent : p.textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? p.brandAccent : p.textSecondary,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.surfaceElevated,
        selectedIconTheme: IconThemeData(color: p.brandAccent, size: 22),
        unselectedIconTheme: IconThemeData(color: p.textSecondary, size: 22),
        selectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: p.brandAccent,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(
          color: p.textSecondary,
          fontSize: 13.5,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: 520),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.isDark ? p.surfaceElevated : p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: p.border),
        ),
        textStyle: TextStyle(color: p.textPrimary, fontSize: 13),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(p.isDark ? p.surfaceElevated : p.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.brand : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: p.borderStrong, width: 1.5),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.white : p.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? p.brand : p.surfaceElevated,
        ),
        trackOutlineColor: WidgetStatePropertyAll(p.border),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.isDark ? p.surfaceElevated : p.textPrimary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: p.isDark ? BorderSide(color: p.border) : BorderSide.none,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
