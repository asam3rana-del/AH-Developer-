/// Customer ki "payment ka din" — jis din us ke paas paisa hota hai (tankhwah wala: mahine ki 1 tareekh;
/// dihari wala: har Juma). Wasooli Autopilot usi din us customer ko aaj ki list mein upar le aata hai.
///
/// customers.paySchedule (TEXT, DB v37), sync hota hai. Format:
///   ''      = set nahi
///   'w:N'   = har hafte, N = 1 (Monday) .. 7 (Sunday)   — Juma = 'w:5'
///   'm:N'   = har mahine ki N tareekh (1..31; chhote mahine mein aakhri din)
/// Ghalat / anjaan value = set nahi (kabhi crash nahi). Sab PURE — test/pay_schedule_test.dart.
class PaySchedule {
  final bool weekly;
  final int day;
  const PaySchedule._(this.weekly, this.day);

  static PaySchedule? parse(String raw) {
    final m = RegExp(r'^([wm]):(\d{1,2})$').firstMatch(raw.trim());
    if (m == null) return null;
    final weekly = m.group(1) == 'w';
    final d = int.parse(m.group(2)!);
    if (weekly && (d < 1 || d > 7)) return null;
    if (!weekly && (d < 1 || d > 31)) return null;
    return PaySchedule._(weekly, d);
  }

  static String weeklyOn(int weekday) => 'w:$weekday';
  static String monthlyOn(int dayOfMonth) => 'm:$dayOfMonth';

  /// [date] is customer ka payment din hai?
  bool isOn(DateTime date) {
    if (weekly) return date.weekday == day;
    final lastDay = DateTime(date.year, date.month + 1, 0).day;
    return date.day == (day > lastDay ? lastDay : day);
  }
}

/// Seedha string se (Autopilot / repository ke liye).
bool isPayDay(String raw, DateTime date) => PaySchedule.parse(raw)?.isOn(date) ?? false;

const _weekdaysEn = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _weekdaysUr = ['پیر', 'منگل', 'بدھ', 'جمعرات', 'جمعہ', 'ہفتہ', 'اتوار'];

/// Dikhane ke liye. [urdu] false => English.
String payScheduleLabel(String raw, {required bool urdu}) {
  final s = PaySchedule.parse(raw);
  if (s == null) return urdu ? 'مقرر نہیں' : 'Not set';
  if (s.weekly) return urdu ? 'ہر ${_weekdaysUr[s.day - 1]}' : 'Every ${_weekdaysEn[s.day - 1]}';
  return urdu ? 'ہر مہینے کی ${s.day} تاریخ' : 'Every month on the ${s.day}';
}

/// Edit dialog ke options: '' + 7 din + mahine ki aam tareekhen.
const List<String> payScheduleChoices = [
  '',
  'w:5', 'w:1', 'w:2', 'w:3', 'w:4', 'w:6', 'w:7',
  'm:1', 'm:5', 'm:7', 'm:10', 'm:15', 'm:20', 'm:25', 'm:31',
];
