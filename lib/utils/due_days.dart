/// Udhaar bill ki default muddat (din) — jab customer ki apni muddat set na ho.
///
/// Pehle: customer par din set na ho to bill par koi date nahi lagti thi aur wo bill "date nahi" ban kar
/// reminders mein kho jata tha. Ab: customer ki muddat > 0 ho to wahi, warna dukaan ki default muddat
/// (Settings > Shop Information, default 7 din). 0 likhne par default band (purana tareeqa).
///
/// PURE functions — test/receivable_aging_test.dart.
const String kDueDaysSetting = 'default_due_days';
const int kFallbackDueDays = 7;
const int kMaxDueDays = 365;

/// Settings ka text -> din. Khali / ghalat => [kFallbackDueDays]; 0 => band; baqi 0..365 mein.
int parseShopDueDays(String? raw) {
  final n = int.tryParse((raw ?? '').trim());
  if (n == null) return kFallbackDueDays;
  if (n < 0) return 0;
  return n > kMaxDueDays ? kMaxDueDays : n;
}

/// Customer ki muddat pehle, warna dukaan ki default.
int effectiveDueDays({required int customerDays, required int shopDays}) => customerDays > 0 ? customerDays : shopDays;
