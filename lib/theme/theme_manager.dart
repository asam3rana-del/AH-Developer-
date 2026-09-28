import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors ThemeManager.kt — poori app ka ek hi palette (light ya dark).
/// Naye/migrate hone wale screens `ThemeManager.palette` se rang lein;
/// purane screens abhi `AppColors` (static light) par hain, jab tak unhe migrate na kiya jaye.
@immutable
class AppPalette {
  final Color bg, cardWhite, navy, teal, red, textDark, textMuted, border, amber, fieldFill;
  final Color headerSubtitleColor, headerBadgeOverlay, savedHighlightBg;

  // Flat-minimal design system: har category ka soft "chip" background + matching icon/text rang.
  final Color flatPurpleBg, flatPurpleFg, flatCoralBg, flatCoralFg, flatBlueBg, flatBlueFg;
  final Color flatPinkBg, flatPinkFg, flatTealBg, flatTealFg, flatAmberBg, flatAmberFg;

  const AppPalette({
    required this.bg, required this.cardWhite, required this.navy, required this.teal, required this.red,
    required this.textDark, required this.textMuted, required this.border, required this.amber,
    required this.fieldFill, required this.headerSubtitleColor, required this.headerBadgeOverlay,
    required this.savedHighlightBg,
    required this.flatPurpleBg, required this.flatPurpleFg, required this.flatCoralBg, required this.flatCoralFg,
    required this.flatBlueBg, required this.flatBlueFg, required this.flatPinkBg, required this.flatPinkFg,
    required this.flatTealBg, required this.flatTealFg, required this.flatAmberBg, required this.flatAmberFg,
  });
}

class ThemeManager {
  ThemeManager._();

  static const _keyDarkMode = 'dark_mode';

  // Khatabook-style ledger palette (Kotlin LIGHT).
  static const light = AppPalette(
    bg: Color(0xFFF4F5F9), cardWhite: Color(0xFFFFFFFF), navy: Color(0xFF0D1B4C), teal: Color(0xFF0F9B8E),
    red: Color(0xFFE5484D), textDark: Color(0xFF14162B), textMuted: Color(0xFF7C8798), border: Color(0xFFE7E9F2),
    amber: Color(0xFFFF8A00), fieldFill: Color(0xFFF4F5F9), headerSubtitleColor: Color(0xFFAEB8E0),
    headerBadgeOverlay: Color(0x33FFFFFF), savedHighlightBg: Color(0xFFE9FBF9),
    flatPurpleBg: Color(0xFFE7E9FB), flatPurpleFg: Color(0xFF2D3796),
    flatCoralBg: Color(0xFFFDEAE3), flatCoralFg: Color(0xFFC1440E),
    flatBlueBg: Color(0xFFE3ECFE), flatBlueFg: Color(0xFF1450C7),
    flatPinkBg: Color(0xFFFBEAF0), flatPinkFg: Color(0xFF993556),
    flatTealBg: Color(0xFFDFF6EC), flatTealFg: Color(0xFF0A8A4E),
    flatAmberBg: Color(0xFFFFEFD9), flatAmberFg: Color(0xFFB85C00),
  );

  static const dark = AppPalette(
    bg: Color(0xFF0B0F1E), cardWhite: Color(0xFF161B2E), navy: Color(0xFF0D1B4C), teal: Color(0xFF14B8A6),
    red: Color(0xFFF0666B), textDark: Color(0xFFEAEFF7), textMuted: Color(0xFF8B95A8), border: Color(0xFF262C42),
    amber: Color(0xFFFF9E33), fieldFill: Color(0xFF161D2C), headerSubtitleColor: Color(0xFFAEB8E0),
    headerBadgeOverlay: Color(0x33FFFFFF), savedHighlightBg: Color(0xFF12332F),
    flatPurpleBg: Color(0xFF2C2F7A), flatPurpleFg: Color(0xFFC7CBF6),
    flatCoralBg: Color(0xFF6E2E10), flatCoralFg: Color(0xFFF6C4A9),
    flatBlueBg: Color(0xFF0E3A78), flatBlueFg: Color(0xFFBAD3F8),
    flatPinkBg: Color(0xFF72243E), flatPinkFg: Color(0xFFF4C0D1),
    flatTealBg: Color(0xFF0A4A34), flatTealFg: Color(0xFF8FE7C0),
    flatAmberBg: Color(0xFF5C3A05), flatAmberFg: Color(0xFFFFC26A),
  );

  /// MaterialApp is par listen karta hai — toggle par poori app dobara banti hai.
  static final ValueNotifier<bool> isDark = ValueNotifier<bool>(false);

  static AppPalette get palette => isDark.value ? dark : light;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    isDark.value = p.getBool(_keyDarkMode) ?? false;
  }

  static Future<void> setDarkMode(bool enabled) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_keyDarkMode, enabled);
    isDark.value = enabled;
  }

  /// Current setting ulat kar naya value wapas deta hai.
  static Future<bool> toggleDarkMode() async {
    final v = !isDark.value;
    await setDarkMode(v);
    return v;
  }
}
