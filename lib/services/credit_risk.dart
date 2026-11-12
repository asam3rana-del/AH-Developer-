import '../db/app_database.dart';
import '../db/due_followup_repository.dart';
import '../db/due_reminders_repository.dart';
import '../models/due_followup.dart';

/// Udhaar dene se PEHLE ka khatra: is customer ka purana baqi late hai ya pichla wada toota hai?
///
/// Credit limit (pehle se) sirf "kitna" dekhti hai; ye "kab se" aur "wada" dekhta hai. Sale screen udhaar bill
/// save karne se pehle ye dikhati hai. Saara faisla [creditRiskFor] (PURE) mein — test/credit_risk_test.dart.

/// Jin bills par due date nahi lagi, wo itne din purane hon to "late" gine jate hain.
const int creditRiskAgeDays = 30;

const int _dayMs = 86400000;

class CreditRisk {
  /// Late baqi (due date guzar chuki, ya date nahi aur [creditRiskAgeDays] se purana).
  final double lateAmount;

  /// Sab se purana late bill kitne din late hai.
  final int maxDaysLate;

  /// Aakhri wada (promise) ki tareekh guzar gayi aur paisa nahi aaya.
  final bool promiseBroken;

  const CreditRisk({this.lateAmount = 0, this.maxDaysLate = 0, this.promiseBroken = false});

  static const none = CreditRisk();

  bool get risky => lateAmount > 0.009 || promiseBroken;
}

int _startOfDay(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// [bills] = isi customer ke baqi bills (DueRemindersRepository.dueSales ka hissa).
CreditRisk creditRiskFor({
  required Iterable<DueBill> bills,
  required Iterable<DueFollowUp> entries,
  int? nowMillis,
}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final today = _startOfDay(now);
  var late = 0.0;
  var maxDays = 0;
  for (final b in bills) {
    if (b.isAdvance) continue;
    final due = b.total - b.paid;
    if (due <= 0.009) continue;
    int days;
    if (b.dueDate > 0) {
      days = ((today - _startOfDay(b.dueDate)) / _dayMs).floor();
      if (days <= 0) continue; // aaj ya aage ki date = abhi late nahi
    } else {
      if (b.isBalance || b.createdAt <= 0) continue; // purana khata / bina tareekh: andaza nahi
      days = ((today - _startOfDay(b.createdAt)) / _dayMs).floor() - creditRiskAgeDays;
      if (days <= 0) continue;
    }
    late += due;
    if (days > maxDays) maxDays = days;
  }
  final st = followUpState(entries, nowMillis: now);
  return CreditRisk(lateAmount: late, maxDaysLate: maxDays, promiseBroken: st.promiseBroken);
}

/// Customer ke naam se (sale screen mein naam hi hota hai). Naya / na mila / koi ghalti => [CreditRisk.none]
/// — ye sirf warning hai, sale kabhi is ki wajah se fail nahi honi chahiye.
Future<CreditRisk> loadCreditRiskByName(String customerName) async {
  try {
    final name = customerName.trim();
    if (name.isEmpty) return CreditRisk.none;
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers',
        columns: ['id'], where: 'LOWER(name) = ?', whereArgs: [name.toLowerCase()], limit: 1);
    if (rows.isEmpty) return CreditRisk.none;
    final id = rows.first['id'] as int;
    final bills = (await DueRemindersRepository.instance.dueSales()).where((b) => b.isSale && b.partyId == id);
    final entries = await DueFollowUpRepository.instance.forParty(id);
    return creditRiskFor(bills: bills, entries: entries);
  } catch (_) {
    return CreditRisk.none;
  }
}
