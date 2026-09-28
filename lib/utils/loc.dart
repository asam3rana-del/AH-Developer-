import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors Loc.kt — chhota sa English/Urdu helper.
/// Istemal: `Loc.t('Item Name', 'آئٹم کا نام')`
/// Zabaan badalne par [language] notifier fire hota hai, aur MaterialApp
/// dobara build hota hai (Android ke bar-khilaf live refresh milta hai).
class Loc {
  Loc._();

  static const _key = 'language';
  static final ValueNotifier<String> language = ValueNotifier<String>('en');

  static bool get isUrdu => language.value == 'ur';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    language.value = p.getString(_key) ?? 'en';
  }

  static Future<void> setLanguage(String lang) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, lang);
    language.value = lang;
  }

  /// [urdu] agar Urdu chuni ho, warna [english].
  static String t(String english, String urdu) => isUrdu ? urdu : english;
}
