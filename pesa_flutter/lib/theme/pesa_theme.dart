// lib/theme/pesa_theme.dart
// Sistema de Diseño Apple Minimalista (iOS / iPadOS) — Básculas PESA (Flutter Android & Z Fold8 Ultra)
import 'package:flutter/material.dart';

class PesaColors {
  PesaColors._();

  // Superficies y fondos (Apple System Gray 6 & Pure White)
  static const Color canvas = Color(0xFFF5F5F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceMuted = Color(0xFFF2F2F7);
  static const Color tableHeader = Color(0xFFFBFBFD);

  // Bordes y divisores ultrafinos
  static const Color border = Color(0xFFE5E5EA);
  static const Color borderStrong = Color(0xFFD2D2D7);
  static const Color divider = Color(0xFFF2F2F7);

  // Tipografía Apple Anthracite & Neutral Gray
  static const Color textPrimary = Color(0xFF1D1D1F);
  static const Color textSecondary = Color(0xFF6E6E73);
  static const Color textTertiary = Color(0xFF8E8E93);

  // Único acento corporativo Básculas PESA
  static const Color brand = Color(0xFFC8102E);
  static const Color brandHover = Color(0xFFA60D26);
  static const Color brandPressed = Color(0xFF880B20);

  // Puntos semánticos discretos (6dp dentro de cápsulas #F2F2F7)
  static const Color dotGreen = Color(0xFF34C759);
  static const Color dotAmber = Color(0xFFFF9500);
  static const Color dotRed = Color(0xFFC8102E);
  static const Color dotNeutral = Color(0xFF6E6E73);
}

class PesaTheme {
  PesaTheme._();

  static const TextStyle tabularNumber = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: PesaColors.brand,
      primary: PesaColors.brand,
      onPrimary: Colors.white,
      secondary: PesaColors.textPrimary,
      onSecondary: Colors.white,
      surface: PesaColors.surface,
      onSurface: PesaColors.textPrimary,
      error: PesaColors.brand,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: PesaColors.canvas,
      canvasColor: PesaColors.canvas,
      cardColor: PesaColors.surface,
      dividerColor: PesaColors.divider,
      visualDensity: VisualDensity.standard,
      cardTheme: CardThemeData(
        color: PesaColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: PesaColors.border, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: PesaColors.surface,
        foregroundColor: PesaColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: PesaColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: PesaColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: PesaColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: const TextStyle(color: PesaColors.textTertiary, fontSize: 14),
        labelStyle: const TextStyle(color: PesaColors.textSecondary, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: PesaColors.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: PesaColors.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: PesaColors.brand, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: PesaColors.brand, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: PesaColors.brand, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: PesaColors.brand,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: PesaColors.surface,
          foregroundColor: PesaColors.textPrimary,
          side: const BorderSide(color: PesaColors.borderStrong),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: PesaColors.brand,
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: PesaColors.surface,
        selectedColor: PesaColors.brand,
        disabledColor: PesaColors.surfaceMuted,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: PesaColors.textPrimary,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: PesaColors.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: PesaColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: PesaColors.surfaceMuted,
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? PesaColors.brand : PesaColors.textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? PesaColors.brand : PesaColors.textSecondary,
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: PesaColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: PesaColors.border),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: PesaColors.surface,
        surfaceTintColor: Colors.transparent,
        constraints: BoxConstraints(maxWidth: 520),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: PesaColors.surface,
        indicatorColor: PesaColors.surfaceMuted,
        selectedIconTheme: const IconThemeData(color: PesaColors.brand, size: 22),
        unselectedIconTheme: const IconThemeData(color: PesaColors.textSecondary, size: 22),
        selectedLabelTextStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: PesaColors.brand,
        ),
        unselectedLabelTextStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: PesaColors.textSecondary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: PesaColors.textPrimary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dividerTheme: const DividerThemeData(
        color: PesaColors.divider,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
