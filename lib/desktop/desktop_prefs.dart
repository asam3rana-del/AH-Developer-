import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PC (Windows / Linux / macOS) ki apni settings: text ka size aur sidebar chhota/bara.
/// Phone / tablet par in ka koi asar nahi (sab `isDesktop` ke peeche).
class DesktopPrefs {
  DesktopPrefs._();

  static bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Is se chauri window par sidebar + PC layout; tang window (ya phone) par purana mobile layout.
  static const double shellMinWidth = 1000;

  /// Bohat bari screen (1920+) par content is se zyada nahi khinchta — beech mein rehta hai.
  static const double maxContentWidth = 1480;

  /// Dashboard / screens apna PC layout is chaurai (content area) se upar dikhate hain.
  static const double wideLayoutMin = 940;

  /// Text size ke qadam (Ctrl + / Ctrl - / Ctrl 0).
  static const List<double> textScales = [0.85, 0.9, 1.0, 1.1, 1.2, 1.3, 1.45];

  static final ValueNotifier<double> textScale = ValueNotifier<double>(1.0);
  static final ValueNotifier<bool> sidebarCollapsed = ValueNotifier<bool>(false);

  static const _kScale = 'desktop_text_scale';
  static const _kCollapsed = 'desktop_sidebar_collapsed';

  /// Dashboard / screen ke liye: PC hai aur content area kaafi chaura hai.
  static bool wide(double contentWidth) => isDesktop && contentWidth >= wideLayoutMin;

  static Future<void> load() async {
    if (!isDesktop) return;
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getDouble(_kScale) ?? 1.0;
      textScale.value = textScales.contains(s) ? s : 1.0;
      sidebarCollapsed.value = p.getBool(_kCollapsed) ?? false;
    } catch (_) {}
  }

  static Future<void> setTextScale(double v) async {
    textScale.value = v;
    try {
      (await SharedPreferences.getInstance()).setDouble(_kScale, v);
    } catch (_) {}
  }

  static Future<void> zoom(int step) async {
    if (step == 0) return setTextScale(1.0);
    final i = textScales.indexOf(textScale.value);
    final next = ((i < 0 ? textScales.indexOf(1.0) : i) + step).clamp(0, textScales.length - 1);
    await setTextScale(textScales[next]);
  }

  static Future<void> setSidebarCollapsed(bool v) async {
    sidebarCollapsed.value = v;
    try {
      (await SharedPreferences.getInstance()).setBool(_kCollapsed, v);
    } catch (_) {}
  }

  static String scaleLabel(double v) => '${(v * 100).round()}%';
}
