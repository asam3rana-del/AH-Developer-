
import 'app_database.dart';
import '../models/misc_entities.dart' show CashTransaction;
import '../sync/device_tag.dart';
import '../models/party.dart';
import '../models/return_entry.dart';
import 'customer_repository.dart';
import 'party_repository.dart';
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

  /// true => ye koi bill nahi, party ka baqi ledger balance hai jo kisi bill se nahi juda (opening
  /// balance / purana hisaab) — Party Dashboard ke "Payable" mein ginta hai, is liye yahan bhi dikhta hai.
  /// `id` mein party ka naam nahi, sirf label hota hai; date set nahi ho sakti.
  final bool isBalance;

  /// true => ulta hisaab: dukaan ko is party ko dena hai (customer ka advance / supplier ko dena nahi, balki
  /// customer ke negative closing). Party Dashboard ke total se mel ke liye dikhta hai; reminder bhejne ke liye nahi.
  final bool isAdvance;
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
    this.isBalance = false,
    this.isAdvance = false,
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

/// FIX: payment bill se link na ho tab bhi payment ho chuki hoti hai — party ka `balance` ghat jata hai
/// magar bill ka `paid` wahi rehta hai, is liye bill baqi dikhta rehta tha (Due Reminders / overdue badge).
/// Ab har party ke bills ka kul baqi us party ke asli `balance` se zyada nahi dikhta: jo hissa balance se
/// zyada hai wo "ada ho chuka" maana jata hai aur SAB SE PURANE bills se kata jata hai (FIFO — bina link wali
/// payment purane bill ko pehle chukati hai). Sirf dikhane ka hisaab hai — DB / sync mein kuch nahi badalta.
/// `balances` mein na milne wali party (ya partyId null: Walk-in) ke bills jaise hain waise rehte hain.
/// Balance mein opening balance bhi hota hai, is liye balance bills ke kul se bara ho to kuch nahi katta
/// (sirf zyada dikhane se bachata hai, kam nahi dikhata).
List<DueBill> capDueByBalance(Iterable<DueBill> bills, Map<int, double> balances) {
  final out = <DueBill>[];
  final byParty = <int, List<DueBill>>{};
  for (final b in bills) {
    final id = b.partyId;
    if (id == null || !balances.containsKey(id)) {
      out.add(b);
    } else {
      (byParty[id] ??= []).add(b);
    }
  }
  for (final e in byParty.entries) {
    final balance = balances[e.key]!;
    final owed = balance > 0 ? balance : 0.0;
    final list = e.value.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var excess = list.fold<double>(0.0, (sum, b) => sum + b.due) - owed;
    for (final b in list) {
      if (excess <= 0.009) {
        out.add(b);
        continue;
      }
      final cut = b.due < excess ? b.due : excess;
      excess -= cut;
      final left = b.due - cut;
      if (left > 0.009) {
        out.add(DueBill(
          id: b.id,
          partyId: b.partyId,
          partyName: b.partyName,
          partyPhone: b.partyPhone,
          total: b.total,
          paid: b.total - left,
          dueDate: b.dueDate,
          createdAt: b.createdAt,
          isSale: b.isSale,
          isBalance: b.isBalance,
          isAdvance: b.isAdvance,
        ));
      }
    }
  }
  return sortDueBills(out);
}

/// Party Dashboard ke "Payable (You'll Give)" / "Receivable (You'll Get)" se mel (supplier: isSale=false,
/// customer: isSale=true; dono mein closing > 0 matlab baqi paisa): jis supplier ka live closing > 0 hai (dukaan ne dena hai)
/// us ka kul baqi yahan dikhna chahiye. Bills (cap ke baad) se jo hissa na dhaka ho (opening balance / bina bill
/// wala purana hisaab) wo ek alag "Previous balance" row ban kar aata hai. Bills ka kul closing se zyada nahi
/// hota (cap), is liye row kabhi negative nahi banti. `closings` = supplier id -> (naam, phone, closing).
List<DueBill> addUnbilledBalance(
  Iterable<DueBill> bills,
  Map<int, ({String name, String phone, double closing, int createdAt})> closings, {
  bool isSale = false,
}) {
  final billed = <int, double>{};
  for (final b in bills) {
    final id = b.partyId;
    if (id != null) billed[id] = (billed[id] ?? 0.0) + b.due;
  }
  final out = bills.toList();
  for (final e in closings.entries) {
    final rest = e.value.closing - (billed[e.key] ?? 0.0);
    if (e.value.closing <= 0.009 || rest <= 0.009) continue;
    out.add(DueBill(
      id: 'Previous balance',
      partyId: e.key,
      partyName: e.value.name,
      partyPhone: e.value.phone,
      total: rest,
      paid: 0.0,
      dueDate: 0,
      createdAt: e.value.createdAt,
      isSale: isSale,
      isBalance: true,
    ));
  }
  return sortDueBills(out);
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

/// Party Dashboard ke total (Payable = supplier > 0 + customer < 0, Receivable = customer > 0 + supplier < 0) se
/// poora mel khane ke liye: ULTE sign wali parties ke rows. `isSale` = jin parties ke rows ban rahe hain wo
/// customers hain (true) ya suppliers (false). Customer closing < 0 / supplier closing < 0 => "advance" (dukaan
/// ne dena / lena ulta hai); rows `isAdvance` hote hain aur unhe reminder nahi bheja jata.
List<DueBill> oppositeSignRows(
  Map<int, ({String name, String phone, double closing, int createdAt})> closings, {
  required bool isSale,
}) =>
    [
      for (final e in closings.entries)
        if (e.value.closing < -0.009)
          DueBill(
            id: 'Advance',
            partyId: e.key,
            partyName: e.value.name,
            partyPhone: e.value.phone,
            total: -e.value.closing,
            paid: 0.0,
            dueDate: 0,
            createdAt: e.value.createdAt,
            isSale: isSale,
            isBalance: true,
            isAdvance: true,
          ),
    ];

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

/// Party ke kul baqi (Party Dashboard jaisa): us party ki sab non-advance rows (bills + previous balance) ka jod.
/// Walk-in (partyId null) ka total nahi banta.
Map<int, double> partyDueTotals(Iterable<DueBill> bills) {
  final out = <int, double>{};
  for (final b in bills) {
    final id = b.partyId;
    if (id == null || b.isAdvance) continue;
    out[id] = (out[id] ?? 0.0) + b.due;
  }
  return out;
}

/// Ek party ke SAARE baqi bills ek jagah (Due Reminders mein ek card, har bill ka alag nahi).
/// Walk-in / Cash Purchase (partyId null) ka har bill apna alag group rehta hai (koi ek party nahi).
class DueParty {
  final int? partyId;
  final String partyName;
  final String partyPhone;
  final bool isSale;
  final List<DueBill> bills;
  const DueParty({
    required this.partyId,
    required this.partyName,
    required this.partyPhone,
    required this.isSale,
    required this.bills,
  });

  /// Group ki pehchan (advance rows alag, taake bills mein na milen).
  String get key => '${partyId ?? 'x${bills.first.id}'}:${isAdvance ? 'a' : 'b'}';

  double get total => bills.fold<double>(0.0, (a, b) => a + b.due);

  /// Sirf advance wali row(s): reminder nahi bhejna.
  bool get isAdvance => bills.isNotEmpty && bills.every((b) => b.isAdvance);

  /// Asli bills ki ginti ("Previous balance" / advance rows nahi).
  int get billCount => bills.where((b) => !b.isBalance && !b.isAdvance).length;

  bool get hasBalanceRow => bills.any((b) => b.isBalance && !b.isAdvance);

  /// Jin asli bills par date nahi.
  int get undatedCount => bills.where((b) => !b.isBalance && !b.isAdvance && b.dueDate == 0).length;

  /// Sab se purani (overdue ho to) ya sab se qareeb date. 0 = kisi bill par date nahi.
  int get earliestDue {
    var m = 0;
    for (final b in bills) {
      if (b.isBalance || b.dueDate <= 0) continue;
      if (m == 0 || b.dueDate < m) m = b.dueDate;
    }
    return m;
  }

  int get earliestCreated => bills.map((b) => b.createdAt).reduce((a, b) => a < b ? a : b);

  bool hasOverdue({int? nowMillis}) {
    final today = startOfDayMillis(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
    return bills.any((b) => b.dueDate > 0 && b.dueDate < today);
  }

  /// Poore group ka ek hi reminder: total ke saath (WhatsApp message "aapke hisab mein Rs X baaki hai").
  DueBill toTotalBill() => DueBill(
        id: 'Total',
        partyId: partyId,
        partyName: partyName,
        partyPhone: partyPhone,
        total: total,
        paid: 0.0,
        dueDate: earliestDue,
        createdAt: earliestCreated,
        isSale: isSale,
        isBalance: true,
      );
}

/// Bills ko party ke hisaab se jama karo. Sort: date wale pehle (sab se purani/qareeb date pehle),
/// phir "date nahi" wale (purane bill pehle); barabar par naam.
List<DueParty> groupDueByParty(Iterable<DueBill> bills) {
  final map = <String, List<DueBill>>{};
  final order = <String>[];
  for (final b in bills) {
    final k = b.partyId == null ? 'x${b.id}' : '${b.partyId}:${b.isAdvance ? 'a' : 'b'}';
    if (!map.containsKey(k)) order.add(k);
    (map[k] ??= []).add(b);
  }
  final out = <DueParty>[
    for (final k in order)
      DueParty(
        partyId: map[k]!.first.partyId,
        partyName: map[k]!.first.partyName,
        partyPhone: map[k]!.first.partyPhone,
        isSale: map[k]!.first.isSale,
        bills: sortDueBills(map[k]!),
      ),
  ];
  out.sort((a, b) {
    final ae = a.earliestDue, be = b.earliestDue;
    final aNo = ae == 0 ? 1 : 0, bNo = be == 0 ? 1 : 0;
    if (aNo != bNo) return aNo.compareTo(bNo);
    if (ae != be) return ae.compareTo(be);
    final c = a.earliestCreated.compareTo(b.earliestCreated);
    return c != 0 ? c : a.partyName.toLowerCase().compareTo(b.partyName.toLowerCase());
  });
  return out;
}

/// Search: naam, phone (sirf digits se bhi) ya kisi bhi bill ka invoice / bill number. Khali => sab.
bool dueMatches(DueParty g, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (g.partyName.toLowerCase().contains(q)) return true;
  final qd = q.replaceAll(RegExp(r'[^0-9]'), '');
  if (qd.isNotEmpty && g.partyPhone.replaceAll(RegExp(r'[^0-9]'), '').contains(qd)) return true;
  return g.bills.any((b) => !b.isBalance && !b.isAdvance && b.id.toLowerCase().contains(q));
}

/// Kotlin message (Roman Urdu, jaisa Android mein hai). Rs poore rupay (%.0f).
/// [partyTotal]: party ka kul baqi. "Previous balance" wali row ka reminder bhi poora balance batata hai
/// (warna party ko sirf bina-bill hissa, jaise 35350, likha jata tha jab ke asal balance 75866 hota).
String reminderMessage(DueBill b, {double? partyTotal}) {
  final rs = (b.isBalance && partyTotal != null ? partyTotal : b.due).toStringAsFixed(0);
  if (b.isBalance && b.isSale) {
    return 'Assalam o Alaikum ${b.partyName}, aapke hisab mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karein. Shukriya!';
  }
  if (b.isBalance) {
    return 'Assalam o Alaikum ${b.partyName}, humare hisab mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karenge. Shukriya!';
  }
  return b.isSale
      ? 'Assalam o Alaikum ${b.partyName}, aapka bill (Invoice ${b.id}) mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karein. Shukriya!'
      : 'Assalam o Alaikum ${b.partyName}, humare bill (Bill ${b.id}) mein Rs $rs abhi baaki hai. Barah-e-karam jald ada karenge. Shukriya!';
}

Uri whatsAppUri(DueBill b, {double? partyTotal}) {
  final digits = whatsAppDigits(b.partyPhone);
  return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(reminderMessage(b, partyTotal: partyTotal))}');
}

/// Amanat / Loan party ka reminder (Customer.kind + returnDate). `closing` = LIVE party balance
/// (opening + ledger + stuck), sirf dikhane ke liye.
class ReturnReminder {
  final int partyId;
  final String partyName;
  final String partyPhone;
  final String kind; // 'amanat' | 'loan'
  final int returnDate; // 0 = set nahi
  final double closing;

  /// Customer ka opening balance (entries is mein jama hoti hain) aur alag alag entries.
  final double opening;
  final List<ReturnEntry> entries;

  const ReturnReminder({
    required this.partyId,
    required this.partyName,
    required this.partyPhone,
    required this.kind,
    required this.returnDate,
    required this.closing,
    this.opening = 0,
    this.entries = const [],
  });

  bool get isAmanat => kind == 'amanat';

  /// Entries ka kul (musbat) — kitni baar kitna liya / diya.
  double get entriesTotal => entries.fold<double>(0.0, (a, e) => a + e.amount);

  /// Entries ke bahar ka (purana / opening) hissa, musbat amount. 0 = koi nahi.
  double get baseAmount {
    final base = opening - signedReturnTotal(kind, entries);
    return base.abs() < 0.009 ? 0.0 : base.abs();
  }
}

enum ReturnEntryResult { ok, notFound, kindMismatch, invalidAmount, nothingToSettle }

/// Sort: date wale pehle (purani date pehle), phir "date nahi" wale (naam se).
List<ReturnReminder> sortReturnReminders(List<ReturnReminder> list) {
  final out = [...list];
  out.sort((a, b) {
    final aNo = a.returnDate <= 0, bNo = b.returnDate <= 0;
    if (aNo != bNo) return aNo ? 1 : -1;
    final c = a.returnDate.compareTo(b.returnDate);
    return c != 0 ? c : a.partyName.toLowerCase().compareTo(b.partyName.toLowerCase());
  });
  return out;
}

/// English message: amanat (deposit) => "time to return your deposit", loan => "loan repayment is due".
String returnReminderMessage(ReturnReminder r) {
  return r.isAmanat
      ? 'Assalam o Alaikum ${r.partyName}, it is time to return your deposit. Please contact us. Thank you!'
      : 'Assalam o Alaikum ${r.partyName}, your loan repayment is due. Please pay as soon as possible. Thank you!';
}

Uri returnWhatsAppUri(ReturnReminder r) {
  final digits = whatsAppDigits(r.partyPhone);
  return Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(returnReminderMessage(r))}');
}

/// Wapsi ki tarikh AAJ ya guzar chuki wali Amanat / Loan parties (tarikh set ho). Purani pehle.
/// Roz ki notification (`ReturnAlertService`) isi se tay hoti hai; tarikh na ho to notification nahi.
List<ReturnReminder> returnDueNow(List<ReturnReminder> all, {required int nowMillis}) {
  final d = DateTime.fromMillisecondsSinceEpoch(nowMillis);
  final tomorrow = DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch;
  return sortReturnReminders([
    for (final r in all)
      if (r.returnDate > 0 && r.returnDate < tomorrow) r,
  ]);
}

/// Notification ka matan: kitni parties, pehle 3 ke naam, aur kitni ki tarikh guzar chuki.
String returnAlertBody(List<ReturnReminder> due, {required int nowMillis}) {
  final today = startOfDayMillis(nowMillis);
  final overdue = due.where((r) => r.returnDate < today).length;
  final names = due.take(3).map((r) => r.partyName).join(', ');
  final more = due.length > 3 ? ' +${due.length - 3}' : '';
  final b = StringBuffer('${due.length} Deposit/Loan return dates are due: $names$more');
  if (overdue > 0) b.write(' ($overdue overdue)');
  b.write('. Tap to view.');
  return b.toString();
}

// ---------------------------------------------------------------------------
// DB
// ---------------------------------------------------------------------------

class DueRemindersRepository {
  DueRemindersRepository._();
  static final DueRemindersRepository instance = DueRemindersRepository._();

  Future<Map<int, ({String name, String phone, double closing, int createdAt})>> _customerClosings() async {
    final db = await AppDatabase.instance.database;
    // LIVE closing (Party Dashboard jaisa: opening + ledger + stuck) — stored `balance` drift kar sakta hai.
    final live = await PartyRepository.instance.liveCustomerBalances();
    final out = <int, ({String name, String phone, double closing, int createdAt})>{};
    for (final r in await db.rawQuery('SELECT id, name, phone, openingBalance, stuckBalance FROM customers')) {
      final id = (r['id'] as num).toInt();
      out[id] = (
        name: (r['name'] as String?) ?? '',
        phone: (r['phone'] as String?) ?? '',
        closing: partyClosing(
          opening: ((r['openingBalance'] as num?) ?? 0).toDouble(),
          running: live[id] ?? 0.0,
          stuck: ((r['stuckBalance'] as num?) ?? 0).toDouble(),
        ),
        createdAt: 0,
      );
    }
    return out;
  }

  Future<Map<int, ({String name, String phone, double closing, int createdAt})>> _supplierClosings() async {
    final db = await AppDatabase.instance.database;
    final live = await PartyRepository.instance.liveSupplierBalances();
    final out = <int, ({String name, String phone, double closing, int createdAt})>{};
    for (final r in await db.rawQuery('SELECT id, name, phone, openingBalance FROM suppliers')) {
      final id = (r['id'] as num).toInt();
      out[id] = (
        name: (r['name'] as String?) ?? '',
        phone: (r['phone'] as String?) ?? '',
        closing: partyClosing(opening: ((r['openingBalance'] as num?) ?? 0).toDouble(), running: live[id] ?? 0.0),
        createdAt: 0,
      );
    }
    return out;
  }

  /// SaleDao.dueSales(): customer nahi to 'Walk-in'. Party Dashboard ke "Receivable" se mel: customer ke
  /// bills + bina bill ka balance, aur supplier jinhe dukaan ne advance de rakha hai (closing < 0).
  Future<List<DueBill>> dueSales() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT s.invoice AS id, s.customerId AS partyId,
             COALESCE(c.name, 'Walk-in') AS partyName, COALESCE(c.phone, '') AS partyPhone,
             s.total AS total, s.paid AS paid, s.dueDate AS dueDate, s.createdAt AS createdAt
      FROM sales s LEFT JOIN customers c ON c.id = s.customerId
      WHERE s.status = 'active' AND (s.total - s.paid) > 0.009
    ''');
    final closings = await _customerClosings();
    final capped = capDueByBalance(rows.map((m) => _fromRow(m, true)), {for (final e in closings.entries) e.key: e.value.closing});
    return [
      ...addUnbilledBalance(capped, closings, isSale: true),
      ...oppositeSignRows(await _supplierClosings(), isSale: false),
    ];
  }

  /// PurchaseDao.duePurchases(): supplier nahi to 'Cash Purchase'. Party Dashboard ke "Payable" se mel:
  /// supplier ke bills + bina bill ka balance, aur customer jinhe dukaan ne dena hai (closing < 0).
  Future<List<DueBill>> duePurchases() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT pu.billNo AS id, pu.supplierId AS partyId,
             COALESCE(su.name, 'Cash Purchase') AS partyName, COALESCE(su.phone, '') AS partyPhone,
             pu.total AS total, pu.paid AS paid, pu.dueDate AS dueDate, pu.createdAt AS createdAt
      FROM purchases pu LEFT JOIN suppliers su ON su.id = pu.supplierId
      WHERE pu.status = 'active' AND (pu.total - pu.paid) > 0.009
    ''');
    final closings = await _supplierClosings();
    final capped = capDueByBalance(rows.map((m) => _fromRow(m, false)), {for (final e in closings.entries) e.key: e.value.closing});
    return [
      ...addUnbilledBalance(capped, closings),
      ...oppositeSignRows(await _customerClosings(), isSale: true),
    ];
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

  /// Amanat / Loan wali sab customers (date ho ya na ho) — sorted. Kuch chhupta nahi.
  Future<List<ReturnReminder>> returnReminders() async {
    final db = await AppDatabase.instance.database;
    final live = await PartyRepository.instance.liveCustomerBalances();
    final rows = await db.query('customers', where: "kind IN ('amanat','loan')");
    return sortReturnReminders([
      for (final m in rows)
        ReturnReminder(
          partyId: m['id'] as int,
          partyName: (m['name'] as String?) ?? '',
          partyPhone: (m['phone'] as String?) ?? '',
          kind: (m['kind'] as String?) ?? '',
          returnDate: (m['returnDate'] as num?)?.toInt() ?? 0,
          closing: ((m['openingBalance'] as num?)?.toDouble() ?? 0.0) +
              (live[m['id']] ?? 0.0) +
              ((m['stuckBalance'] as num?)?.toDouble() ?? 0.0),
          opening: (m['openingBalance'] as num?)?.toDouble() ?? 0.0,
          entries: decodeReturnEntries(m['returnEntries'] as String?),
        ),
    ]);
  }

  /// Wapsi ki tarikh set / badalna (0 = hatana). Ek transaction + sync_queue (setDueDate jaisa).
  Future<bool> setReturnDate({required int partyId, required int returnDateMillis}) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final n = await txn.update(
        'customers',
        {
          'returnDate': returnDateMillis <= 0 ? 0 : startOfDayMillis(returnDateMillis),
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      if (n == 0) return false;
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      return true;
    });
  }

  /// Amanat / Loan wali parties jin ki tabdeeli abhi sync nahi hui (dirty = 1) — screen par "pending" badge.
  Future<Set<int>> pendingReturnPartyIds() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers',
        columns: ['id'], where: "kind IN ('amanat','loan') AND dirty = 1");
    return {for (final m in rows) m['id'] as int};
  }

  /// Normal customers (kind khali) — "Existing customer" chunne ke liye, naam se sorted.
  Future<List<({int id, String name, String phone})>> normalCustomers() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers',
        columns: ['id', 'name', 'phone'], where: "kind IS NULL OR kind = ''", orderBy: 'name COLLATE NOCASE');
    return [
      for (final m in rows)
        (id: m['id'] as int, name: (m['name'] as String?) ?? '', phone: (m['phone'] as String?) ?? ''),
    ];
  }

  /// "Existing customer" chunne ke liye: SAB customers (pehle se Amanat/Loan wale bhi — unhein dobara
  /// loan/amanat diya ja sakta hai). `kind` khali = normal customer.
  Future<List<({int id, String name, String phone, String kind})>> pickableCustomers() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers', columns: ['id', 'name', 'phone', 'kind'], orderBy: 'name COLLATE NOCASE');
    return [
      for (final m in rows)
        (
          id: m['id'] as int,
          name: (m['name'] as String?) ?? '',
          phone: (m['phone'] as String?) ?? '',
          kind: (m['kind'] as String?) ?? '',
        ),
    ];
  }

  int _day(int millis) => millis <= 0 ? 0 : startOfDayMillis(millis);

  /// Naya loan / amanat (ek aur entry) kisi bhi customer ko. Balance mein jama hota hai (amanat = minus,
  /// loan = plus) aur customer ke saath sync hota hai. Pehle se doosri qism ki ho to [ReturnEntryResult.kindMismatch].
  Future<ReturnEntryResult> addReturnEntry({
    required int partyId,
    required String kind,
    required double amount,
    required int dateMillis,
    required int returnDateMillis,
    String note = '',
  }) async {
    if (!(amount > 0) || !amount.isFinite) return ReturnEntryResult.invalidAmount;
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (rows.isEmpty) return ReturnEntryResult.notFound;
      final cur = rows.first;
      final curKind = (cur['kind'] as String?) ?? '';
      if (curKind.isNotEmpty && curKind != kind) return ReturnEntryResult.kindMismatch;
      final entries = decodeReturnEntries(cur['returnEntries'] as String?);
      final entry = ReturnEntry(
        id: nextReturnEntryId(entries),
        amount: amount,
        date: _day(dateMillis),
        returnDate: _day(returnDateMillis),
        note: note.trim(),
      );
      entries.add(entry);
      final log = logAddGiven(decodeReturnLog(cur['returnLog'] as String?), kind, entry, atMillis: now);
      final earliest = earliestReturnDate(entries);
      await txn.update(
        'customers',
        {
          'kind': kind,
          'openingBalance': ((cur['openingBalance'] as num?)?.toDouble() ?? 0.0) + signedReturnAmount(kind, amount),
          'returnEntries': encodeReturnEntries(entries),
          'returnLog': encodeReturnLog(log),
          if (earliest > 0) 'returnDate': earliest,
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      return ReturnEntryResult.ok;
    });
    await CustomerRepository.instance.refresh();
    return res;
  }

  /// Ek entry ka amount / tarikh / wapsi / note badalna. Amount ka farq balance mein jata hai.
  Future<ReturnEntryResult> editReturnEntry({
    required int partyId,
    required int entryId,
    required double amount,
    required int dateMillis,
    required int returnDateMillis,
    String note = '',
  }) async {
    if (!(amount > 0) || !amount.isFinite) return ReturnEntryResult.invalidAmount;
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (rows.isEmpty) return ReturnEntryResult.notFound;
      final cur = rows.first;
      final kind = (cur['kind'] as String?) ?? '';
      final entries = decodeReturnEntries(cur['returnEntries'] as String?);
      final i = entries.indexWhere((e) => e.id == entryId);
      if (i < 0) return ReturnEntryResult.notFound;
      final old = entries[i];
      entries[i] = old.copyWith(amount: amount, date: _day(dateMillis), returnDate: _day(returnDateMillis), note: note.trim());
      final log = logEditEntry(decodeReturnLog(cur['returnLog'] as String?), kind, old, entries[i], atMillis: now);
      final delta = signedReturnAmount(kind, amount) - signedReturnAmount(kind, old.amount);
      await txn.update(
        'customers',
        {
          'openingBalance': ((cur['openingBalance'] as num?)?.toDouble() ?? 0.0) + delta,
          'returnEntries': encodeReturnEntries(entries),
          'returnLog': encodeReturnLog(log),
          'returnDate': earliestReturnDate(entries),
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      return ReturnEntryResult.ok;
    });
    await CustomerRepository.instance.refresh();
    return res;
  }

  /// Ek entry hatana (galat entry): uska amount balance se wapas nikal jata hai.
  Future<ReturnEntryResult> deleteReturnEntry({required int partyId, required int entryId}) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (rows.isEmpty) return ReturnEntryResult.notFound;
      final cur = rows.first;
      final kind = (cur['kind'] as String?) ?? '';
      final entries = decodeReturnEntries(cur['returnEntries'] as String?);
      final i = entries.indexWhere((e) => e.id == entryId);
      if (i < 0) return ReturnEntryResult.notFound;
      final old = entries.removeAt(i);
      final log = logRemoveEntry(decodeReturnLog(cur['returnLog'] as String?), kind, old, atMillis: now);
      await txn.update(
        'customers',
        {
          'openingBalance': ((cur['openingBalance'] as num?)?.toDouble() ?? 0.0) - signedReturnAmount(kind, old.amount),
          'returnEntries': encodeReturnEntries(entries),
          'returnLog': encodeReturnLog(log),
          if (entries.isNotEmpty) 'returnDate': earliestReturnDate(entries),
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      return ReturnEntryResult.ok;
    });
    await CustomerRepository.instance.refresh();
    return res;
  }

  /// Amanat wapas karna (dukaan paisa deti hai => Cash OUT) / Loan wasool karna (paisa aata hai => Cash IN).
  /// Ek transaction mein: entries FIFO se kam (poori ho to hat jati hai), opening balance 0 ki taraf
  /// (amanat +, loan -), wapsi ki tarikh bachi entries ki sab se purani (koi nahi to 0) aur Cash register
  /// mein ek row (reference `manual-return-entry-<partyId>-<tag>-<ms>`: `manual-` se Day Book mein alag line). Customer + cash
  /// dono sync hote hain. [amount] bachi raqam se zyada ho to bachi raqam tak settle hota hai.
  Future<ReturnEntryResult> settleReturn({
    required int partyId,
    required double amount,
    required String method,
    String note = '',
  }) async {
    if (!(amount > 0) || !amount.isFinite) return ReturnEntryResult.invalidAmount;
    final m = method == 'bank' ? 'bank' : 'cash';
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (rows.isEmpty) return ReturnEntryResult.notFound;
      final cur = rows.first;
      final kind = (cur['kind'] as String?) ?? '';
      if (kind != 'amanat' && kind != 'loan') return ReturnEntryResult.kindMismatch;
      final entries = decodeReturnEntries(cur['returnEntries'] as String?);
      if (entries.isEmpty) return ReturnEntryResult.nothingToSettle;
      final out = settleEntriesFifo(entries, amount);
      if (!(out.settled > 0)) return ReturnEntryResult.nothingToSettle;
      // amanat wapas: balance (minus) upar aata hai; loan wasool: balance (plus) neeche aata hai.
      final delta = -signedReturnAmount(kind, out.settled);
      final log = logRecovered(decodeReturnLog(cur['returnLog'] as String?), kind, out.settled,
          atMillis: now, note: note.trim());
      await txn.update(
        'customers',
        {
          'openingBalance': ((cur['openingBalance'] as num?)?.toDouble() ?? 0.0) + delta,
          'returnEntries': encodeReturnEntries(out.remaining),
          'returnLog': encodeReturnLog(log),
          'returnDate': earliestReturnDate(out.remaining),
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      final name = (cur['name'] as String?) ?? '';
      final isAmanat = kind == 'amanat';
      final n = note.trim();
      final cash = CashTransaction(
        type: isAmanat ? 'OUT' : 'IN',
        method: m,
        amount: out.settled,
        reason: '${isAmanat ? 'Amanat wapas' : 'Loan wasool'}: $name${n.isEmpty ? '' : ' | $n'}',
        reference: 'manual-return-entry-$partyId-${DeviceTag.current}-$now',
        createdAt: now,
        updatedAt: now,
      );
      final cashId = await txn.insert('cash_transactions', cash.toMap());
      await SyncQueueHelper.enqueueCashTransaction(txn, cashId);
      return ReturnEntryResult.ok;
    });
    await CustomerRepository.instance.refresh();
    return res;
  }

  Future<bool> _setKind(int partyId, String kind, int returnDateMillis, {double amount = 0}) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ok = await db.transaction((txn) async {
      // Amount ho to maujooda opening balance mein jama (amanat = minus, loan = plus).
      if (amount != 0) {
        await txn.rawUpdate(
            'UPDATE customers SET openingBalance = COALESCE(openingBalance, 0) + ? WHERE id = ?', [amount, partyId]);
      }
      final n = await txn.update(
        'customers',
        {
          'kind': kind,
          'returnDate': returnDateMillis <= 0 ? 0 : startOfDayMillis(returnDateMillis),
          'updatedAt': now,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      if (n == 0) return false;
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
      return true;
    });
    await CustomerRepository.instance.refresh();
    return ok;
  }

  /// Maujooda customer ko Amanat / Loan tag karna. `amount` (optional) opening balance mein jama hota hai.
  Future<bool> tagParty(
          {required int partyId, required String kind, required int returnDateMillis, double amount = 0}) =>
      _setKind(partyId, kind, returnDateMillis, amount: amount);

  /// Tag hatana => party wapas normal customer. Ledger aur bills jaise hain waise.
  Future<bool> clearReturnTag(int partyId) => _setKind(partyId, '', 0);

  /// Nayi Amanat / Loan party banana. Khali naam => [SavePartyResult.nameRequired].
  /// [amount] (musbat, optional) pehli entry ban jati hai (taareekh + wapsi ki taareekh + note ke saath).
  Future<SavePartyResult> addNewReturnParty({
    required String name,
    required String phone,
    required String kind,
    required int returnDateMillis,
    required double amount,
    int dateMillis = 0,
    String note = '',
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    final entries = <ReturnEntry>[
      if (amount > 0 && amount.isFinite)
        ReturnEntry(id: 1, amount: amount, date: _day(dateMillis), returnDate: _day(returnDateMillis), note: note.trim()),
    ];
    await PartyRepository.instance.saveCustomer(Customer(
      name: trimmed,
      phone: phone.trim(),
      openingBalance: entries.isEmpty ? 0.0 : signedReturnAmount(kind, amount),
      kind: kind,
      returnDate: returnDateMillis <= 0 ? 0 : startOfDayMillis(returnDateMillis),
      returnEntries: encodeReturnEntries(entries),
      returnLog: encodeReturnLog(backfillReturnLog(kind, entries, atMillis: DateTime.now().millisecondsSinceEpoch)),
    ));
    return SavePartyResult.success;
  }

  /// Amanat / Loan party ki details badalna: naam, phone, type, wapsi ki tarikh (0 = hatana).
  /// [baseAmount] (musbat; null = na chhedo) = entries ke bahar ka purana / opening amount — sirf tab badalta hai
  /// jab purani value se alag ho. Type tab hi badalta hai jab party par koi entry na ho.
  /// Ledger / bills nahi chhedta (history naam se rehti hai, jaise Party -> Edit).
  Future<SavePartyResult> editReturnParty({
    required int partyId,
    required String name,
    required String phone,
    required String kind,
    required int returnDateMillis,
    double? baseAmount,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (rows.isEmpty) return;
      final cur = rows.first;
      final curKind = (cur['kind'] as String?) ?? '';
      final entries = decodeReturnEntries(cur['returnEntries'] as String?);
      final useKind = entries.isNotEmpty && curKind.isNotEmpty ? curKind : kind;
      final opening = (cur['openingBalance'] as num?)?.toDouble() ?? 0.0;
      var newOpening = opening;
      if (baseAmount != null && baseAmount >= 0 && baseAmount.isFinite) {
        final base = opening - signedReturnTotal(useKind, entries);
        if ((baseAmount - base.abs()).abs() > 0.009) {
          newOpening = signedReturnTotal(useKind, entries) + signedReturnAmount(useKind, baseAmount);
        }
      }
      await txn.update(
        'customers',
        {
          'name': trimmed,
          'phone': phone.trim(),
          'kind': useKind,
          'openingBalance': newOpening,
          // Entries hon to tarikh unhi se aati hai; warna yahan ki tarikh.
          'returnDate': entries.isNotEmpty
              ? earliestReturnDate(entries)
              : (returnDateMillis <= 0 ? 0 : startOfDayMillis(returnDateMillis)),
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'dirty': 1,
        },
        where: 'id = ?',
        whereArgs: [partyId],
      );
      await SyncQueueHelper.enqueueCustomer(txn, partyId);
    });
    await CustomerRepository.instance.refresh();
    return SavePartyResult.success;
  }

  /// Party delete (is device se + sync tombstone). Purane bills naam ke saath history mein rehte hain.
  Future<void> deleteReturnParty(int partyId) =>
      PartyRepository.instance.deleteCustomer(Customer(id: partyId, name: ''));

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
