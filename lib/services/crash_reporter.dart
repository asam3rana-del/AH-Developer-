import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../sync/branch_config_store.dart';
import '../sync/device_tag.dart';
import '../sync/sync_api.dart';
import 'demo_mode.dart';

/// Crash ki khabar developer tak — Firebase Crashlytics ke BAGHAIR.
///
/// Crashlytics kyun nahi: us ko Android build mein Gradle plugin + bundled google-services.json chahiye; ye
/// app har dukaan ka Firebase project runtime par (Cloud Sync Setup) leti hai, aur build ID ke baghair
/// Crashlytics app start par hi ruk sakta hai. Is liye maujooda [CrashHandler] (har crash ka stack trace
/// phone par) ko do raste diye:
///  1. Cloud Sync juda ho to agli launch par crash text Firestore `crash_reports` mein (rules: sirf create,
///     branch member, <= 8000 chars) — developer Firebase Console mein dekhta hai.
///  2. Crash dialog mein "Send to developer" — WhatsApp par seedha support number.
/// Demo mode mein upload nahi. Ek hi crash do dafa upload nahi hota (fingerprint prefs mein).
class CrashReporter {
  CrashReporter._();

  static const _keyUploaded = 'crash_report_uploaded_fp';
  static const maxChars = 7900;

  /// Firestore field ki hadd ke andar.
  static String clip(String text, [int max = maxChars]) => text.length <= max ? text : text.substring(0, max);

  /// Text ka mustaqil fingerprint (String.hashCode par bharosa nahi).
  static String fingerprint(String text) {
    var h = 0x811c9dc5;
    for (final c in text.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return '${text.length}-$h';
  }

  /// true = upload ho gaya. Kabhi throw nahi karta; offline / sync nahi / pehle ho chuka => false.
  static Future<bool> uploadIfNew(String text) async {
    if (DemoMode.enabled || text.trim().isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final fp = fingerprint(text);
      if (prefs.getString(_keyUploaded) == fp) return false;
      final db = await SyncApi.instance.firestoreFor();
      if (db == null) return false;
      final uid = await SyncApi.instance.currentUid();
      if (uid == null) return false;
      await db.collection('crash_reports').add({
        'text': clip(text),
        'at': DateTime.now().millisecondsSinceEpoch,
        'device': DeviceTag.current,
        'branchId': BranchConfigStore.current,
        'app': AppInfo.appName,
        'uid': uid,
      }).timeout(const Duration(seconds: 15));
      await prefs.setString(_keyUploaded, fp);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Crash dialog ka "Send to developer": WhatsApp support number par (lamba text kaat kar).
  static Uri whatsAppUri(String text) => Uri.parse(
      'https://wa.me/${AppInfo.supportWhatsAppIntl}?text=${Uri.encodeComponent('${AppInfo.appName} crash report\n\n${clip(text, 3000)}')}');
}
