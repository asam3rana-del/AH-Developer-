import 'package:flutter/material.dart';

import 'theme_manager.dart';

/// Hanna Software Series ka "premium" design system — poori app (67 screens) ek hi jagah se:
/// navy (#0B2545) + gold (#F5B841) brand, gol konay, saaf borders, bold buttons, floating snackbars.
///
/// Sirf shape / rang / typography — kisi button ya field ki unchai (size) nahi badli,
/// taa ke purani screens ka layout na toote. Jo screen apna style deti hai wo waise hi rehta hai.
class AppTheme {
  AppTheme._();

  /// Hanna brand gold (app icon ka barcode).
  static const gold = Color(0xFFF5B841);

  static ThemeData build(AppPalette p, bool dark) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    final primary = dark ? p.navyInk : p.navy;
    final scheme = ColorScheme.fromSeed(seedColor: p.navy, brightness: brightness).copyWith(
      primary: primary,
      onPrimary: dark ? p.navy : Colors.white,
      secondary: p.teal,
      tertiary: gold,
      surface: p.cardWhite,
      onSurface: p.textDark,
      onSurfaceVariant: p.textMuted,
      surfaceContainerLowest: p.cardWhite,
      surfaceContainerLow: p.cardWhite,
      surfaceContainer: p.cardWhite,
      surfaceContainerHigh: p.cardWhite,
      surfaceContainerHighest: p.fieldFill,
      outline: p.textMuted,
      outlineVariant: p.border,
      error: p.red,
    );

    final r12 = BorderRadius.circular(12);
    final r14 = BorderRadius.circular(14);
    final shape12 = RoundedRectangleBorder(borderRadius: r12);
    const btnText = TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2);
    // Dark mode mein navy button background ke saath gum ho jata — wahan halka navy.
    final btnBg = dark ? p.navyLight : p.navy;

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.cardWhite,
      dividerColor: p.border,
      fontFamily: 'Roboto',
      visualDensity: VisualDensity.standard,
    );

    final text = base.textTheme.apply(bodyColor: p.textDark, displayColor: p.textDark).copyWith(
          titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: p.textDark),
          titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: p.textDark),
          titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: p.textDark),
          labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        );

    return base.copyWith(
      textTheme: text,

      // Cards: safed, halka border, gol konay — shadow nahi (saaf "flat premium").
      cardTheme: CardThemeData(
        color: p.cardWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.border)),
      ),

      // Input boxes: gol konay (outline). SIRF `border` — enabled/focused colors Flutter khud state se deta hai,
      // aur jo field `border: InputBorder.none` deti hai (28 jagah) wo bina line ke hi rehti hai.
      // `filled` jaan boojh kar nahi: bina-border fields ke peeche rang ka dabba aa jata.
      inputDecorationTheme: InputDecorationThemeData(
        border: OutlineInputBorder(borderRadius: r12),
        floatingLabelStyle: TextStyle(color: p.navyInk, fontWeight: FontWeight.w700),
        hintStyle: TextStyle(color: p.textMuted.withValues(alpha: 0.85)),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: btnBg,
          foregroundColor: Colors.white,
          shape: shape12,
          textStyle: btnText,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: shape12, textStyle: btnText, elevation: 0),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.navyInk,
          side: BorderSide(color: p.border, width: 1.3),
          shape: shape12,
          textStyle: btnText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.navyInk, shape: shape12, textStyle: btnText),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: btnBg,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.cardWhite,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titleTextStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: p.textDark),
        contentTextStyle: TextStyle(fontSize: 14.5, height: 1.4, color: p.textDark),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.cardWhite,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.cardWhite,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.cardWhite,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: r14, side: BorderSide(color: p.border)),
        textStyle: TextStyle(color: p.textDark, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? p.navyLight : p.navy,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
        actionTextColor: gold,
        shape: RoundedRectangleBorder(borderRadius: r14),
        elevation: 4,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: p.navy, borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        waitDuration: const Duration(milliseconds: 400),
      ),

      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: p.border),
        backgroundColor: p.cardWhite,
        selectedColor: p.flatBlueBg,
        labelStyle: TextStyle(color: p.textDark, fontWeight: FontWeight.w600),
        checkmarkColor: p.flatBlueFg,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.navyInk,
        titleTextStyle: TextStyle(color: p.textDark, fontSize: 15, fontWeight: FontWeight.w600),
        subtitleTextStyle: TextStyle(color: p.textMuted, fontSize: 12.5),
        shape: shape12,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.teal : null),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.teal : null),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.teal : null),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.teal : null),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.teal, linearTrackColor: p.border),
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      tabBarTheme: TabBarThemeData(
        labelColor: p.navyInk,
        unselectedLabelColor: p.textMuted,
        indicatorColor: gold,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: const TextStyle(fontWeight: FontWeight.w800),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        dividerColor: p.border,
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(p.fieldFill),
        headingTextStyle: TextStyle(color: p.textDark, fontWeight: FontWeight.w800, fontSize: 13),
        dataTextStyle: TextStyle(color: p.textDark, fontSize: 13),
        dividerThickness: 1,
      ),
      // PC: patla, gol, halka scrollbar.
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(8),
        thumbColor: WidgetStatePropertyAll(p.textMuted.withValues(alpha: 0.45)),
      ),
    );
  }
}
