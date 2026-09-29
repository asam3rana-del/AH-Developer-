
import 'app_database.dart';
import '../sync/sync_queue_helper.dart';

/// Ports the data side of DueRemindersActivity.kt + SaleDao.dueSales()/setDueDate() +
/// PurchaseDao.duePurchases()/setDueDate() (Database.kt). UI: lib/screens/due_reminders_screen.dart.
///
/// Maths PURE functions mein hai ([dueBucket], [summarizeDue], [whatsAppDigits], [reminderMessage],
/// [overdueCustomerStatus]) taake bina DB ke test ho sake — test/due_reminders_test.dart.
///
/// Rules (Kotlin):
///  * Sirf `status = 'active'` bills jin par abhi paisa baqi ho ((total - paid) > 0.009).
///  * Jis bill par date set nahi (dueDate = 0) wo bhi dikhta hai (sab se neeche, gray) — kuch chhupta nahi.
///  * Sort: date wale pehle (purani date pehle), phir "date nahi" wale; barabar par createdAt.
///  * Date badalne par `dirty = 1`, `updatedAt`, AUR sync_queue mein entry (Kotlin FIX: warna date
///    doosri device par kabhi nahi jati).
///  * Sale edit par dueDate reset nahi hoti (SaleRepository.saveSale original.dueDate carry karta hai).

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Kotlin badge: OVERDUE / DUE TODAY / DUE SOON (3 din ke andar) / UPCOMING / No date set.
enum DueBucket { noDate, overdue, dueToday, dueSoon, upcoming }

/// Din ki shuruaat (00:00 local). Kotlin startOfToday().
int startOfDayMillis(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// Kotlin: today/tomorrow/in3Days `today + N * 24h` istemal karta hai; yahan calendar-din se
/// (DST wale din par bhi sahi). Normal dinon mein nateeja bilkul wahi.
DueBucket dueBucket(int dueDate, {int? nowMillis}) {
  if (dueDate <= 0) return DueBucket.noDate;
  final now = DateTime.fromMillisecondsSinceEpoch(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  final today = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final tomorrow = DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch;
  final in3Days = DateTime(now.year, now.month, now.day + 3).millisecondsSinceEpoch;
  if (dueDate < today) return DueBucket.overdue;
  if (dueDate < tomorrow) return DueBucket.dueToday;
  if (dueDate < in3Days) return DueBucket.dueSoon;
  return DueBucket.upcoming;
}

/// Ek bill jo abhi baqi hai (DueSale / DuePurchase).
class DueBill {
  final String id; // invoice / billNo
  final int? partyId;
  final String partyName;
  final String partyPhone;
  final double total;
  final double paid;
  final int dueDate;
  final int createdAt;
  final bool isSale;
  const DueBill({
    required this.id,
    required this.partyId,
    required this.partyName,
    required this.partyPhone,
    required this.total,
    required this.paid,
    required this.dueDate,
    required this.createdAt,
    required this.isSale,
  });
  double get due => total - paid;
}

/// Kotlin renderSummary(): overdue = dueDate in 1 until today; totalDue = sum(total - paid).
({int overdue, double totalDue}) summarizeDue(Iterable<DueBill> bills, {int? nowMillis}) {
  final today = startOfDayMillis(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  var overdue = 0;
  var totalDue = 0.0;
  for (final b in bills) {
    if (b.dueDate > 0 && b.dueDate < today) overdue++;
    totalDue += b.due;
  }
  return (overdue: overdue, totalDue: totalDue);
}

/// Kotlin ORDER BY (dueDate = 0) ASC, dueDate ASC, createdAt ASC.
List<DueBill> sortDueBills(Iterable<DueBill> bills) {
  final list = bills.toList();
  list.sort((a, b) {
    final aNo = a.dueDate == 0 ? 1 : 0;
    final bNo = b.dueDate == 0 ? 1 : 0;
    if (aNo != bNo) return aNo.compareTo(bNo);
    final byDue = a.dueDate.compareTo(b.dueDate);
    if (byDue != 0) return byDue;
    return a.createdAt.compareTo(b.createdAt);
  });
  return list;
}

/// Party Dashboard ka badge (sirf customers): aaj tak ki date wali sale kisi customer ki ho to
/// OVERDUE (agar koi aaj se pehle ki) warna DUE TODAY. Kotlin: `dueDate in 1 until tomorrow`.
enum PartyDueStatus { overdue, dueToday }

Map<int, PartyDueStatus> overdueCustomerStatus(Iterable<DueBill> sales, {int? nowMillis}) {
  final now = DateTime.fromMillisecondsSinceEpoch(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  final today = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final tomorrow = DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch;
  final byCustomer = <int, List<DueBill>>{};
  for (final s in sales) {
    final id = s.partyId;
    if (id == null || s.dueDate <= 0 || s.dueDate >= tomorrow) continue;
    (byCustomer[id] ??= []).add(s);
  }
  return {
    for (final e in byCustomer.entries)
      e.key: e.value.any((s) => s.dueDate < today) ? PartyDueStatus.overdue : PartyDueStatus.dueToday,
  };
}

/// Kotlin sendWhatsAppReminder(): sirf digits; 0 se shuru => 92 (Pakistan); 92 ke baghair aur
/// <= 10 digits => 92 lagao. Khali number => ''.
String whatsAppDigits(String phone) {
  var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '';
  if (digits.startsWith('0')) {
    digits = '92${digits.substring(1)}';
  } else if (!digits.startsWith('92') && digits.length <= 10) {
    digits = '92$digits';
  }
  return digits;
}

/// Kotlin message (Roman Urdu, jaisa Android mein hai). Rs poore rupay (%.0f).
String reminderMessage(DueBill b) {
  final rs = b.due.toStringAsFixed(0);
  return b.isSale
      ? 'Assalam o Alaikum ${b.partyName}, aapka bill (Invoice ${b.id}) mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karein. Shukriya!'
      : 'Assalam o Alaikum ${b.partyName}, humare bill (Bill ${b.id}) mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karenge. Shukriya!';
}

Uri whatsAppUri(DueBill b) {
  final digits = whatsAppDigits(b.partyPhone);
  return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(reminderMessage(b))}');
}

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

class DueRemindersRepository {
  DueRemindersRepository._();
  static final DueRemindersRepository instance = DueRemindersRepository._();

  /// SaleDao.dueSales(): customer nahi to 'Walk-in'.
  Future<List<DueBill>> dueSales() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT s.invoice AS id, s.customerId AS partyId,
             COALESCE(c.name, 'Walk-in') AS partyName, COALESCE(c.phone, '') AS partyPhone,
             s.total AS total, s.paid AS paid, s.dueDate AS dueDate, s.createdAt AS createdAt
      FROM sales s LEFT JOIN customers c ON c.id = s.customerId
      WHERE s.status = 'active' AND (s.total - s.paid) > 0.009
    ''');
    return sortDueBills(rows.map((m) => _fromRow(m, true)));
  }

  /// PurchaseDao.duePurchases(): supplier nahi to 'Cash Purchase'.
  Future<List<DueBill>> duePurchases() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT pu.billNo AS id, pu.supplierId AS partyId,
             COALESCE(su.name, 'Cash Purchase') AS partyName, COALESCE(su.phone, '') AS partyPhone,
             pu.total AS total, pu.paid AS paid, pu.dueDate AS dueDate, pu.createdAt AS createdAt
      FROM purchases pu LEFT JOIN suppliers su ON su.id = pu.supplierId
      WHERE pu.status = 'active' AND (pu.total - pu.paid) > 0.009
    ''');
    return sortDueBills(rows.map((m) => _fromRow(m, false)));
  }

  DueBill _fromRow(Map<String, Object?> m, bool isSale) => DueBill(
        id: m['id'] as String,
        partyId: (m['partyId'] as num?)?.toInt(),
        partyName: (m['partyName'] as String?) ?? '',
        partyPhone: (m['partyPhone'] as String?) ?? '',
        total: (m['total'] as num).toDouble(),
        paid: (m['paid'] as num).toDouble(),
        dueDate: (m['dueDate'] as num?)?.toInt() ?? 0,
        createdAt: (m['createdAt'] as num).toInt(),
        isSale: isSale,
      );

  /// Party Dashboard badge ke liye (customers only).
  Future<Map<int, PartyDueStatus>> customerDueStatus() async => overdueCustomerStatus(await dueSales());

  /// Date set / badalna. Ek transaction: dueDate + updatedAt + dirty, phir POORI row sync_queue mein
  /// (Kotlin FIX: sirf dirty=1 kaafi nahi, kisi ko scan nahi karta). `dueDateMillis` din ki shuruaat.
  Future<bool> setDueDate({required bool isSale, required String id, required int dueDateMillis}) async {
    final db = await AppDatabase.instance.database;
    final table = isSale ? 'sales' : 'purchases';
    final key = isSale ? 'invoice' : 'billNo';
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final n = await txn.update(
        table,
        {'dueDate': startOfDayMillis(dueDateMillis), 'updatedAt': now, 'dirty': 1},
        where: '$key = ?',
        whereArgs: [id],
      );
      if (n == 0) return false; // bill ab nahi rahi (delete ho gayi)
      if (isSale) {
        await SyncQueueHelper.enqueueSale(txn, id);
      } else {
        await SyncQueueHelper.enqueuePurchase(txn, id);
      }
      return true;
    });
  }
}
