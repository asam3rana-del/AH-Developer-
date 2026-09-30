import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors CrashHandler.kt — phone-only crash debugging (no logcat / computer).
/// Har uncaught error ka stack trace + waqt SharedPreferences mein save hota hai;
/// agli dafa Dashboard khulne par "App crashed last time" dialog dikhata hai.
class CrashHandler {
  CrashHandler._();

  static const _key = 'last_crash_text';
  static bool _installed = false;

  /// main() mein sab se pehle (runApp se pehle) ek baar.
  static void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _save('Flutter framework', details.exception, details.stack);
      // Pehle wala handler (console / red screen) phir bhi chale.
      if (previousFlutterHandler != null) {
        previousFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _save('Async / platform', error, stack);
      // Agar pehle koi handler tha to wahi faisla kare; warna 'handled' na maanein.
      return previousPlatformHandler?.call(error, stack) ?? false;
    };
  }

  /// Kotlin: "CRASH at <stamp>\nThread: ...\n\n<stack trace>".
  static String format(String source, Object error, StackTrace? stack, DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final stamp = '${two(at.day)}/${two(at.month)}/${at.year} '
        '${two(h12)}:${two(at.minute)}:${two(at.second)} ${at.hour >= 12 ? 'PM' : 'AM'}';
    return 'CRASH at $stamp\nThread: $source\n\n$error\n${stack ?? ''}';
  }

  static void _save(String source, Object error, StackTrace? stack) {
    try {
      final text = format(source, error, stack, DateTime.now());
      // Fire-and-forget: crash handler khud kabhi throw na kare.
      SharedPreferences.getInstance().then((p) => p.setString(_key, text)).catchError((_) => false);
    } catch (_) {}
  }

  /// Saved crash text, ya null agar crash nahi hua.
  static Future<String?> getLastCrash() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString(_key);
    return (t == null || t.isEmpty) ? null : t;
  }

  static Future<void> clearLastCrash() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  /// Dialog mein sirf shuru ka hissa (Kotlin: 3000 chars).
  static String preview(String text) =>
      text.length > 3000 ? '${text.substring(0, 3000)}\n\n…(truncated, use Share for full text)' : text;
}
