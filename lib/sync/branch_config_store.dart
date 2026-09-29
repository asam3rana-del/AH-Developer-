import 'package:shared_preferences/shared_preferences.dart';

/// Kotlin `BranchConfigStore.kt`. Runtime par set hone wala Branch Code (Settings > Cloud
/// Sync Setup), compile-time BuildConfig.BRANCH_ID ki jagah.
///
/// SECURITY: yeh code khud access nahi deta — sirf jo documents yeh device push karta hai unpar
/// stamp hota hai aur pull() local filter karta hai. Asli access control Firestore ke
/// `branch_members/{uid}` + security rules mein hai; ghalat code par Firestore permission-denied
/// deta hai.
///
/// `init()` app start par ek baar; phir `current` synchronously (DeviceTag jaisa).
class BranchConfigStore {
  BranchConfigStore._();

  static const String keyBranchId = 'branch_config_prefs.branch_id';

  static final RegExp _valid = RegExp(r'^[A-Za-z0-9_-]{2,50}$');

  static String _cached = '';

  /// Khali string = abhi configure nahi hua (koi sync nahi).
  static String get current => _cached;

  static bool isConfigured() => isValid(_cached);

  /// Firestore path mein '/' nahi ho sakta: sirf A-Z a-z 0-9 _ - (2-50 akhsar).
  static bool isValid(String branchId) => _valid.hasMatch(branchId.trim());

  /// Purani installation ka branch barqarar; nayi ko Settings mein chunna hoga
  /// (compile-time fallback jaan boojh kar nahi).
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final stored = p.getString(keyBranchId)?.trim();
    _cached = (stored != null && isValid(stored)) ? stored : '';
  }

  /// Ghalat code par [ArgumentError] (Kotlin `require`) — wohi message.
  static Future<void> set(String branchId) async {
    final trimmed = branchId.trim();
    if (!isValid(trimmed)) {
      throw ArgumentError(
          'Branch Code must be 2-50 characters and contain only A-Z, a-z, 0-9, _ or -.');
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(keyBranchId, trimmed);
    _cached = trimmed;
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(keyBranchId);
    _cached = '';
  }
}
