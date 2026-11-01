import 'package:shared_preferences/shared_preferences.dart';

import 'session.dart';

/// Kya cashier credit-limit se upar ka bill "Save Anyway" se save kar sakta hai?
///
/// Default = HAAN (purana tareeqa, kuch nahi badla). Admin Settings mein "Only admin/manager can Save Anyway"
/// ON kare to cashier ko limit se upar ka bill save karne ke liye admin/manager chahiye (dialog sirf OK dikhata hai
/// aur SaleRepository bhi override ko rok deta hai).
class CreditOverridePolicy {
  static const prefKey = 'credit_override_managers_only';

  static Future<bool> managersOnly() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setManagersOnly(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefKey, v);
  }

  /// Is waqt login user "Save Anyway" kar sakta hai?
  static Future<bool> currentUserMayOverride() async => Session.isAdminOrManager || !await managersOnly();
}
