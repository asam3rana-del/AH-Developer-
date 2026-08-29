import 'package:flutter/material.dart';

/// Mirrors ThemeManager.palette() from the Kotlin app (ProductActivity.kt /
/// ThemeManager.kt) so the Flutter version keeps the same "premium" look —
/// navy header, teal accents, amber/blue/purple per-card accents.
class AppColors {
  AppColors._();

  static const bg = Color(0xFFF4F6F8);
  static const cardWhite = Color(0xFFFFFFFF);
  static const navy = Color(0xFF0B2545);
  static const navyLight = Color(0xFF173863);
  static const teal = Color(0xFF0F9B8E);
  static const tealDark = Color(0xFF0C8F8A);
  static const red = Color(0xFFE5484D);
  static const redDark = Color(0xFFC93B40);
  static const blue = Color(0xFF3B82F6);
  static const orange = Color(0xFFF5A524);
  static const purple = Color(0xFF8B5CF6);
  static const textDark = Color(0xFF0B2545);
  static const textMuted = Color(0xFF7C8798);
  static const border = Color(0xFFE3E8EE);
  static const amber = Color(0xFFF5A524);

  static const fieldFill = Color(0xFFFAFBFC);
  static const headerSubtitle = Color(0xFF9FB4CC);
  static const headerBadgeOverlay = Color(0x33FFFFFF);
  static const savedHighlightBg = Color(0xFFE9FBF9);

  /// Lightens a color toward white — used for two-tone gradient accent
  /// strips, matching fadeHex() in ProductActivity.kt.
  static Color fade(Color c) => Color.lerp(c, Colors.white, 0.5)!;

  /// Darkens a color slightly — used as the second stop of gradient badges
  /// and buttons, matching fadeHexDark() in ProductActivity.kt.
  static Color fadeDark(Color c) => Color.lerp(c, Colors.black, 0.18)!;
}
