import '../db/user_repository.dart';

/// Dukaan ke "paisa kahan bhejein" ki tafseel (Raast ID / JazzCash / Easypaisa / bank IBAN), jo har WhatsApp
/// wasooli yaad-dahani ke neeche khud jur jati hai — customer dukaan aaye baghair foran bhej sake.
///
/// `app_settings` mein key [settingKey]; sync hoti hai (SyncQueueHelper.syncedAppSettingKeys), is liye ek phone
/// par likhi to sab phones ke reminders mein aati hai.
class PaymentInfo {
  PaymentInfo._();

  static const settingKey = 'payment_info';

  static Future<String> load() async {
    try {
      return (await UserRepository.instance.getSetting(settingKey))?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> save(String value) => UserRepository.instance.setSetting(settingKey, value.trim());

  /// Message ke neeche judne wala hissa. Khali [info] => khali string (kuch nahi jurta).
  static String block(String info) {
    final t = info.trim();
    if (t.isEmpty) return '';
    return 'Payment yahan bhej sakte hain / ادائیگی یہاں بھیج سکتے ہیں:\n$t';
  }

  /// [uri] wa.me link ho to us ke `text` ke neeche [block] jor do. Doosra link / khali info => wahi [uri].
  static Uri appendToWhatsApp(Uri uri, String info) {
    final extra = block(info);
    if (extra.isEmpty) return uri;
    if (uri.host != 'wa.me') return uri;
    final text = uri.queryParameters['text'] ?? '';
    final merged = text.trim().isEmpty ? extra : '$text\n\n$extra';
    return Uri.parse('${uri.scheme}://${uri.host}${uri.path}?text=${Uri.encodeComponent(merged)}');
  }

  /// Saved info parh kar jor do (fail ho to [uri] waisa hi — reminder kabhi na ruke).
  static Future<Uri> withSaved(Uri uri) async => appendToWhatsApp(uri, await load());
}
