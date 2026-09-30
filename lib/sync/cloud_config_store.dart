import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kotlin `CloudConfig` data class.
class CloudConfig {
  final String projectId;
  final String apiKey;
  final String appId;
  final String storageBucket;

  const CloudConfig({
    required this.projectId,
    required this.apiKey,
    required this.appId,
    this.storageBucket = '',
  });

  @override
  bool operator ==(Object other) =>
      other is CloudConfig &&
      other.projectId == projectId &&
      other.apiKey == apiKey &&
      other.appId == appId &&
      other.storageBucket == storageBucket;

  @override
  int get hashCode => Object.hash(projectId, apiKey, appId, storageBucket);
}

/// Kotlin `CloudConfigStore.kt`. Shop owner apna Firebase project Settings mein text ki
/// surat mein daalta hai (build mein baked google-services ki jagah), taake alag alag
/// dukandaron ka data ek shared database mein na jaye.
///
/// Kuch enter nahi kiya + build mein default Firebase app bhi nahi => sync bilkul band
/// (offline single-device POS). Default app (agar `Firebase.initializeApp` main() mein chala
/// ho) sirf fallback hai — Kotlin ki `FirebaseApp.getInstance()` jaisa.
class CloudConfigStore {
  CloudConfigStore._();

  static const String _kProjectId = 'cloud_config_prefs.project_id';
  static const String _kApiKey = 'cloud_config_prefs.api_key';
  static const String _kAppId = 'cloud_config_prefs.app_id';
  static const String _kStorageBucket = 'cloud_config_prefs.storage_bucket';

  /// Custom FirebaseApp ka naam (default app se takrata nahi).
  static const String customAppName = 'custom_cloud';

  /// Jo config admin ne is device par enter ki (agar ki).
  static Future<CloudConfig?> get() async {
    final p = await SharedPreferences.getInstance();
    final projectId = p.getString(_kProjectId);
    final apiKey = p.getString(_kApiKey);
    final appId = p.getString(_kAppId);
    if (projectId == null || apiKey == null || appId == null) return null;
    return CloudConfig(
      projectId: projectId,
      apiKey: apiKey,
      appId: appId,
      storageBucket: p.getString(_kStorageBucket) ?? '',
    );
  }

  static Future<bool> isConfigured() async => (await get()) != null;

  static Future<void> save(CloudConfig config) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kProjectId, config.projectId.trim());
    await p.setString(_kApiKey, config.apiKey.trim());
    await p.setString(_kAppId, config.appId.trim());
    await p.setString(_kStorageBucket, config.storageBucket.trim());
  }

  /// Custom config hata do (build ka default, agar hai, wapas istemal hoga).
  /// Kotlin `prefs.clear()` — sirf isi store ki 4 keys.
  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kProjectId, _kApiKey, _kAppId, _kStorageBucket]) {
      await p.remove(k);
    }
  }

  /// Is waqt sync ko kaun se options istemal karne chahiye: admin ki apni config, warna
  /// build ka default. Dono nahi => null ("sync set up nahi", Firestore se baat na karein).
  static Future<FirebaseOptions?> effectiveOptions() async {
    final c = await get();
    if (c != null) return toOptions(c);
    try {
      return Firebase.app().options;
    } catch (_) {
      return null;
    }
  }

  static bool _sameOptions(FirebaseOptions a, FirebaseOptions b) =>
      a.projectId == b.projectId && a.appId == b.appId && a.apiKey == b.apiKey;

  /// Sync ke liye asli FirebaseApp. Custom config hone par pehle [DEFAULT] app isi config se banta hai
  /// (Firebase plugins kabhi kabhi andar se [DEFAULT] maangte hain — "[core/no-app] No Firebase App
  /// '[DEFAULT]'" isi se aata tha). Agar [DEFAULT] kisi aur config par ban chuka (config badli) to alag
  /// naam ("custom_cloud") ka app. Kuch nahi to null (sync skip karein).
  static Future<FirebaseApp?> firebaseApp() async {
    final custom = await get();
    if (custom == null) {
      try {
        return Firebase.app();
      } catch (_) {
        return null;
      }
    }
    final opts = toOptions(custom);

    FirebaseApp? def;
    try {
      def = Firebase.app();
    } catch (_) {}
    if (def != null && _sameOptions(def.options, opts)) return def;

    // [DEFAULT] abhi bana hi nahi => is config se banao.
    if (def == null) {
      try {
        return await Firebase.initializeApp(options: opts);
      } catch (_) {
        try {
          final d = Firebase.app();
          if (_sameOptions(d.options, opts)) return d;
        } catch (_) {}
      }
    }

    // [DEFAULT] kisi aur config par (ya ban nahi saka) => alag naam ka app; purani config ka ho to badlo.
    try {
      final named = Firebase.app(customAppName);
      if (_sameOptions(named.options, opts)) return named;
      await named.delete();
    } catch (_) {}
    return Firebase.initializeApp(name: customAppName, options: opts);
  }

  /// App ID ("1:675436217091:android:...") mein dusra hissa project number = messagingSenderId.
  static String senderIdFromAppId(String appId) {
    final m = RegExp(r'^\d+:(\d+):').firstMatch(appId.trim());
    return m?.group(1) ?? '';
  }

  static FirebaseOptions toOptions(CloudConfig c) => FirebaseOptions(
        apiKey: c.apiKey,
        appId: c.appId,
        messagingSenderId: senderIdFromAppId(c.appId),
        projectId: c.projectId,
        storageBucket: c.storageBucket.isEmpty ? null : c.storageBucket,
      );
}

/// `google-services.json` (Firebase Console se / Kotlin app ki `app/google-services.json`) ka text parh kar
/// Project ID, API Key, App ID aur Storage Bucket nikalta hai — taake lambi values tablet par type na karni paren.
/// Ghalat / khali / adhoora JSON => null.
CloudConfig? parseGoogleServicesJson(String text) {
  try {
    final d = json.decode(text.trim());
    if (d is! Map) return null;
    final info = d['project_info'];
    final clients = d['client'];
    if (info is! Map || clients is! List || clients.isEmpty) return null;
    final projectId = (info['project_id'] ?? '').toString().trim();
    final bucket = (info['storage_bucket'] ?? '').toString().trim();
    for (final c in clients) {
      if (c is! Map) continue;
      final ci = c['client_info'];
      final keys = c['api_key'];
      if (ci is! Map || keys is! List || keys.isEmpty) continue;
      final appId = (ci['mobilesdk_app_id'] ?? '').toString().trim();
      final key = (keys.first is Map ? (keys.first as Map)['current_key'] : '').toString().trim();
      if (projectId.isEmpty || appId.isEmpty || key.isEmpty) continue;
      return CloudConfig(projectId: projectId, apiKey: key, appId: appId, storageBucket: bucket);
    }
  } catch (_) {}
  return null;
}
