import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

/// Training / Demo dukaan.
///
/// On hone par app ek ALAG database file kholti hai (asal dukaan ki file ko haath nahi lagta), cloud sync
/// band rehta hai (demo ki entries kabhi asal cloud / doosre phone par nahi jaatin), aur backup / restore
/// band (demo ka backup asal backups mein na mile, na demo ka backup asal par restore ho).
///
/// Sirf foreground app [init] karti hai. Background isolates (WorkManager backup / sync) [init] nahi
/// karte, is liye wahan [enabled] hamesha false = asal DB. Yani demo chalte waqt bhi asal dukaan ka
/// background backup / sync apni jagah theek chalta rahe.
class DemoMode {
  DemoMode._();

  static const prefKey = 'demo_mode_enabled';

  /// Demo dukaan ki apni DB file (asal: AppDatabase ka `_dbName`).
  static const demoDbFileName = 'ah_developer_demo_shop.db';

  /// UI (banner, MaterialApp key) is ko sunti hai.
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get enabled => notifier.value;

  /// App start par, DB khulne se PEHLE.
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    notifier.value = p.getBool(prefKey) ?? false;
  }

  /// Flag badalta hai. DB band / session saaf karna caller ka kaam ([switchTo] dekhein UI mein).
  static Future<void> setEnabled(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefKey, on);
    notifier.value = on;
  }

  /// Is waqt kaunsi DB file kholni hai.
  static String dbFileName(String liveFileName) => enabled ? demoDbFileName : liveFileName;

  static const syncBlockedMessage = 'Demo mode: cloud sync band hai (demo ki entries asal dukaan mein nahi jaatin)';
  static const backupBlockedMessage = 'Demo mode: backup / restore band hai — pehle Settings se Demo band karein';
}
