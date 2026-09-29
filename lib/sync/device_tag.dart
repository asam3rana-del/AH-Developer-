import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Kotlin `DeviceTag.kt`. Har installation ka chhota random tag (4 hex/alnum, UPPERCASE) jo
/// Firestore document IDs mein mila diya jata hai, taake ek hi branch ke do devices ki
/// customer/supplier/expense/cash IDs aapas mein takra kar ek dusre ko overwrite na karein.
///
/// Pehli baar app chalne par ban kar SharedPreferences ("device_prefs" / "device_tag") mein
/// mehfooz hota hai; `init()` ke baad `DeviceTag.current` synchronously mil jata hai.
class DeviceTag {
  DeviceTag._();

  static const String prefsKey = 'device_prefs.device_tag';

  /// Fallback sirf tab jab `init()` abhi nahi chala (Kotlin jaisa "0000").
  static String _cached = '0000';

  static String get current => _cached;

  /// main() mein sab se pehle (Kotlin `PosApplication.onCreate()` ka pehla kaam). Dobara
  /// bulane par bhi mehfooz.
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    var tag = p.getString(prefsKey);
    if (tag == null || tag.isEmpty) {
      tag = generate();
      await p.setString(prefsKey, tag);
    }
    _cached = tag;
  }

  /// UUID ke pehle 4 akhsar (dashes ke baghair), UPPERCASE — Kotlin jaisa.
  static String generate() =>
      const Uuid().v4().replaceAll('-', '').substring(0, 4).toUpperCase();
}
