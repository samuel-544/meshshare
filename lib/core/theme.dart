import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MeshShare visual language: a near-black, card-based dark UI with a single
/// warm copper accent taken from the app mark's gradient. Everything else is
/// monochrome — copper is reserved for primary actions, active states, links
/// and progress.
abstract final class MeshColors {
  static const bg = Color(0xFF0A0A0B); // app background
  static const surface = Color(0xFF141417); // cards
  static const surfaceHigh = Color(0xFF1C1C20); // inputs, elevated rows
  static const surfaceHigher = Color(0xFF26262B); // menus, snackbars
  static const outline = Color(0xFF2A2A30); // hairlines, borders

  static const text = Color(0xFFF3F3F4); // primary text
  static const textDim = Color(0xFF9A9AA2); // secondary text
  static const textFaint = Color(0xFF63636B); // tertiary / disabled

  static const copper = Color(0xFFDBA982); // primary accent
  static const copperInk = Color(0xFF1A130C); // text/icons on copper
  static const copperMuted = Color(0xFF3A2E24); // copper-tinted container
  static const steel = Color(0xFF8FA3B8); // the mark's cool end

  static const danger = Color(0xFFE5807A);
  static const success = Color(0xFF7FB894);

  /// The mark gradient — cool steel to warm copper.
  static const markGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [steel, copper],
  );
}

ThemeData buildMeshTheme() {
  const cs = ColorScheme.dark(
    primary: MeshColors.copper,
    onPrimary: MeshColors.copperInk,
    primaryContainer: MeshColors.copperMuted,
    onPrimaryContainer: MeshColors.copper,
    secondary: MeshColors.steel,
    onSecondary: MeshColors.copperInk,
    surface: MeshColors.bg,
    onSurface: MeshColors.text,
    surfaceContainerLowest: MeshColors.bg,
    surfaceContainerLow: MeshColors.surface,
    surfaceContainer: MeshColors.surface,
    surfaceContainerHigh: MeshColors.surfaceHigh,
    surfaceContainerHighest: MeshColors.surfaceHigher,
    onSurfaceVariant: MeshColors.textDim,
    outline: MeshColors.outline,
    outlineVariant: MeshColors.outline,
    error: MeshColors.danger,
    onError: MeshColors.copperInk,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: cs,
    scaffoldBackgroundColor: MeshColors.bg,
    canvasColor: MeshColors.bg,
    splashFactory: InkRipple.splashFactory,
  );

  TextStyle t(
    double size,
    FontWeight weight, {
    double spacing = 0,
    double height = 1.3,
    Color color = MeshColors.text,
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    letterSpacing: spacing,
    height: height,
    color: color,
  );

  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          displayLarge: t(36, FontWeight.w800, spacing: -1.2, height: 1.02),
          displayMedium: t(30, FontWeight.w800, spacing: -1.0, height: 1.05),
          displaySmall: t(25, FontWeight.w700, spacing: -0.6, height: 1.1),
          headlineMedium: t(23, FontWeight.w700, spacing: -0.5),
          headlineSmall: t(20, FontWeight.w700, spacing: -0.3),
          titleLarge: t(18, FontWeight.w700, spacing: -0.2),
          titleMedium: t(15.5, FontWeight.w600),
          titleSmall: t(13.5, FontWeight.w600, color: MeshColors.textDim),
          bodyLarge: t(15, FontWeight.w400, height: 1.45),
          bodyMedium: t(13.5, FontWeight.w400, height: 1.45, color: MeshColors.textDim),
          bodySmall: t(12, FontWeight.w400, color: MeshColors.textFaint),
          labelLarge: t(15, FontWeight.w600, spacing: 0.1),
          labelMedium: t(12.5, FontWeight.w600, spacing: 0.4, color: MeshColors.textDim),
        )
        .apply(bodyColor: MeshColors.text, displayColor: MeshColors.text),

    appBarTheme: const AppBarTheme(
      backgroundColor: MeshColors.bg,
      foregroundColor: MeshColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: MeshColors.bg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: MeshColors.text,
      ),
    ),

    cardTheme: CardThemeData(
      color: MeshColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: MeshColors.outline),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MeshColors.copper,
        foregroundColor: MeshColors.copperInk,
        disabledBackgroundColor: MeshColors.surfaceHigh,
        disabledForegroundColor: MeshColors.textFaint,
        minimumSize: const Size.fromHeight(54),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape: const StadiumBorder(),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: MeshColors.copper,
        foregroundColor: MeshColors.copperInk,
        elevation: 0,
        minimumSize: const Size.fromHeight(54),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: MeshColors.text,
        side: const BorderSide(color: MeshColors.outline),
        minimumSize: const Size.fromHeight(54),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: MeshColors.copper,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: MeshColors.copper,
      foregroundColor: MeshColors.copperInk,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MeshColors.surfaceHigh,
      hintStyle: const TextStyle(color: MeshColors.textFaint, fontSize: 14.5),
      prefixIconColor: MeshColors.textDim,
      suffixIconColor: MeshColors.textDim,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: MeshColors.copper, width: 1.4),
      ),
    ),

    listTileTheme: const ListTileThemeData(
      iconColor: MeshColors.textDim,
      textColor: MeshColors.text,
      tileColor: Colors.transparent,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),

    dividerTheme: const DividerThemeData(
      color: MeshColors.outline,
      thickness: 1,
      space: 1,
    ),

    iconTheme: const IconThemeData(color: MeshColors.textDim),
    primaryIconTheme: const IconThemeData(color: MeshColors.text),

    chipTheme: ChipThemeData(
      backgroundColor: MeshColors.surfaceHigh,
      side: const BorderSide(color: MeshColors.outline),
      labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: MeshColors.surfaceHigher,
      contentTextStyle: const TextStyle(color: MeshColors.text, fontSize: 13.5),
      actionTextColor: MeshColors.copper,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: MeshColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: MeshColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: MeshColors.text,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: MeshColors.copper,
      linearTrackColor: MeshColors.surfaceHigh,
      circularTrackColor: MeshColors.surfaceHigh,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? MeshColors.copper
            : MeshColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? MeshColors.copperMuted
            : MeshColors.surfaceHigh,
      ),
      trackOutlineColor: WidgetStateProperty.all(MeshColors.outline),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: MeshColors.surfaceHigher,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: MeshColors.text, fontSize: 12),
    ),
  );
}
