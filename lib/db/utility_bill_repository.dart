import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor, Sqflite;

import '../models/misc_entities.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';
import 'expense_repository.dart';

/// Utility Bills: bijli, gas, pani, internet, mobile jaise mahana bills ki list, due date aur payment.
///
/// - Har bill ki ek `dueDay` (1-31). Jis mahine mein wo din nahi (jaise 31 Feb) wahan aakhri din.
/// - Ek bill ka ek mahina (`YYYY-MM`) sirf ek baar pay hota hai.
/// - Payment par chahein to Expense + Cash/Bank OUT bhi banta hai (category "Utility Bills"); payment undo
///   karne par wo Expense aur cash row bhi hat'ti hai.
/// - Reminder: due se ek din pehle, due wale din, aur guzarne ke baad roz (BillReminderService).
///
/// Maths PURE functions mein hai ([billDueDate], [billStatus], [reminderStage]) taake bina DB ke test ho sake —
/// test/utility_bill_test.dart. Bills aur payments sab devices par sync hote hain (`serverId` + `updatedAt`);
/// payment ki id (bill + mahina) khud pehchan hai, is liye do device ek hi mahina pay karein to cloud par ek hi payment.

const billKinds = <String>['electricity', 'gas', 'water', 'internet', 'phone', 'other'];
const billExpenseCategory = 'Utility Bills';

String _two(int v) => v.toString().padLeft(2, '0');

/// `2026-10`
String billMonthKey(int year, int month) => '$year-${_two(month)}';

/// DateTime se `YYYY-MM`.
String billMonthOf(DateTime d) => billMonthKey(d.year, d.month);

/// [year]/[month] ka agla mahina (month 12 ke baad agla saal).
({int year, int month}) billNextMonth(int year, int month) =>
    month == 12 ? (year: year + 1, month: 1) : (year: year, month: month + 1);

({int year, int month}) billPrevMonth(int year, int month) =>
    month == 1 ? (year: year - 1, month: 12) : (year: year, month: month - 1);

/// Is mahine ki due tarikh (din ki shuruaat, local). `dueDay` mahine se bara ho to aakhri din.
DateTime billDueDate(int dueDay, int year, int month) {
  final last = DateTime(year, month + 1, 0).day;
  final d = dueDay < 1 ? 1 : (dueDay > last ? last : dueDay);
  return DateTime(year, month, d);
}

DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// a - b, poore dinon mein (DST ke 23/25 ghante wale din se bhi ghalat nahi hota).
int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;

class BillStatus {
  /// Jis mahine (`YYYY-MM`) ka yeh status hai.
  final String month;
  final DateTime due;
  final bool paid;

  /// due - aaj, din mein. Manfi = due date guzar chuki.
  final int daysLeft;
  const BillStatus({required this.month, required this.due, required this.paid, required this.daysLeft});

  bool get overdue => !paid && daysLeft < 0;
  bool get dueToday => !paid && daysLeft == 0;
  bool get dueTomorrow => !paid && daysLeft == 1;
}

/// Bill ka abhi ka status.
///
/// Pichla mahina pehle dekhte hain (agar bill us waqt maujood tha aur pay nahi hua to OVERDUE), phir is mahine ka.
/// Dono pay hain (ya bill is mahine ki due date ke baad bana) to agle unpaid mahine ka countdown / paid status dikhta hai.
/// [paidMonths]: jin mahinon (`YYYY-MM`) ki payment ho chuki.
BillStatus billStatus({
  required int dueDay,
  required int createdAtMs,
  required Set<String> paidMonths,
  required DateTime now,
}) {
  final today = _dayStart(now);
  final created = _dayStart(DateTime.fromMillisecondsSinceEpoch(createdAtMs));
  final prev = billPrevMonth(now.year, now.month);
  final next = billNextMonth(now.year, now.month);

  BillStatus unpaidFor(int y, int m) {
    final due = billDueDate(dueDay, y, m);
    return BillStatus(month: billMonthKey(y, m), due: due, paid: false, daysLeft: _daysBetween(due, today));
  }

  // 1) pichla mahina: bill tab maujood tha (due date bill banne se pehle ki nahi) aur pay nahi hua.
  final prevDue = billDueDate(dueDay, prev.year, prev.month);
  if (!prevDue.isBefore(created) && !paidMonths.contains(billMonthKey(prev.year, prev.month))) {
    return unpaidFor(prev.year, prev.month);
  }
  // 2) is mahine ka.
  final thisKey = billMonthKey(now.year, now.month);
  final thisDue = billDueDate(dueDay, now.year, now.month);
  if (paidMonths.contains(thisKey)) {
    return BillStatus(month: thisKey, due: thisDue, paid: true, daysLeft: _daysBetween(thisDue, today));
  }
  if (!thisDue.isBefore(created)) return unpaidFor(now.year, now.month);
  // 3) bill is mahine ki due date ke baad bana: agla mahina.
  return unpaidFor(next.year, next.month);
}

/// Reminder ka marhala: `pre` (ek din pehle), `due` (aaj), `over` (guzar chuki; roz), warna null.
String? reminderStage(BillStatus s) {
  if (s.paid) return null;
  if (s.daysLeft == 1) return 'pre';
  if (s.daysLeft == 0) return 'due';
  if (s.daysLeft < 0) return 'over';
  return null;
}

class UtilityBill {
  final int? id;
  final String name;
  final String kind;
  final int dueDay;
  final double avgAmount;
  final bool reminder;
  final bool active;
  final int createdAt;
  const UtilityBill({
    this.id,
    required this.name,
    this.kind = 'other',
    required this.dueDay,
    this.avgAmount = 0,
    this.reminder = true,
    this.active = true,
    this.createdAt = 0,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind,
        'dueDay': dueDay,
        'avgAmount': avgAmount,
        'reminder': reminder ? 1 : 0,
        'active': active ? 1 : 0,
        'createdAt': createdAt,
      };

  factory UtilityBill.fromMap(Map<String, Object?> m) => UtilityBill(
        id: (m['id'] as num?)?.toInt(),
        name: (m['name'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'other',
        dueDay: ((m['dueDay'] as num?) ?? 1).toInt(),
        avgAmount: ((m['avgAmount'] as num?) ?? 0).toDouble(),
        reminder: ((m['reminder'] as num?) ?? 1) != 0,
        active: ((m['active'] as num?) ?? 1) != 0,
        createdAt: ((m['createdAt'] as num?) ?? 0).toInt(),
      );
}

class BillPayment {
  final int id;
  final int billId;
  final String month;
  final double amount;
  final String method;
  final String note;
  final int? expenseId;
  final int paidAt;
  const BillPayment({
    required this.id,
    required this.billId,
    required this.month,
    required this.amount,
    required this.method,
    required this.note,
    required this.expenseId,
    required this.paidAt,
  });

  factory BillPayment.fromMap(Map<String, Object?> m) => BillPayment(
        id: (m['id'] as num).toInt(),
        billId: (m['billId'] as num).toInt(),
        month: (m['month'] as String?) ?? '',
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        note: (m['note'] as String?) ?? '',
        expenseId: (m['expenseId'] as num?)?.toInt(),
        paidAt: ((m['paidAt'] as num?) ?? 0).toInt(),
      );
}

/// List ki ek row: bill + uska status + aakhri payment.
class BillView {
  final UtilityBill bill;
  final BillStatus status;
  final double? lastAmount;
  const BillView({required this.bill, required this.status, this.lastAmount});

  /// Payment dialog mein pehle se bharne wali raqam: aakhri payment, warna average.
  double get suggestedAmount => lastAmount ?? bill.avgAmount;
}

/// Urgent pehle: overdue (zyada purana pehle), phir due date ke hisab se unpaid, aakhir mein paid.
int compareBillViews(BillView a, BillView b) {
  if (a.status.paid != b.status.paid) return a.status.paid ? 1 : -1;
  final c = a.status.due.compareTo(b.status.due);
  if (c != 0) return c;
  return a.bill.name.toLowerCase().compareTo(b.bill.name.toLowerCase());
}

class UtilityBillRepository {
  UtilityBillRepository._();
  static final UtilityBillRepository instance = UtilityBillRepository._();

  void _requireStaff() {
    if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can manage utility bills');
  }

  Future<List<UtilityBill>> list({bool activeOnly = false}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('utility_bills',
        where: activeOnly ? 'active = 1' : null, orderBy: 'active DESC, dueDay ASC, name COLLATE NOCASE ASC');
    return rows.map(UtilityBill.fromMap).toList();
  }

  Future<int> save(UtilityBill b) async {
    _requireStaff();
    final name = b.name.trim();
    if (name.isEmpty) throw ArgumentError('Bill name is required');
    if (b.dueDay < 1 || b.dueDay > 31) throw ArgumentError('Due day must be between 1 and 31');
    if (!b.avgAmount.isFinite || b.avgAmount < 0) throw ArgumentError('Invalid amount');
    if (!billKinds.contains(b.kind)) throw ArgumentError('Invalid bill type');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = UtilityBill(
      id: b.id,
      name: name,
      kind: b.kind,
      dueDay: b.dueDay,
      avgAmount: b.avgAmount,
      reminder: b.reminder,
      active: b.active,
      createdAt: b.createdAt == 0 ? now : b.createdAt,
    ).toMap()
      ..['updatedAt'] = now;
    return db.transaction((txn) async {
      final int id;
      if (b.id == null) {
        id = await txn.insert('utility_bills', map);
      } else {
        await txn.update('utility_bills', map, where: 'id = ?', whereArgs: [b.id]);
        id = b.id!;
      }
      await SyncQueueHelper.enqueueUtilityBill(txn, id);
      return id;
    });
  }

  /// Bill hatao. Uski payment history bhi hat'ti hai; payment ke saath bani Expense jaisi hai waisi rehti hai.
  Future<void> deleteBill(int billId) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('utility_bills', where: 'id = ?', whereArgs: [billId], limit: 1);
      if (rows.isEmpty) return;
      // Entity ids row delete se PEHLE (doosre device se aaye bill/payment ki asal serverId na khoye).
      final billEid = SyncQueueHelper.utilityBillEntityId(Map<String, Object?>.from(rows.first));
      for (final p in await txn.query('utility_bill_payments', where: 'billId = ?', whereArgs: [billId])) {
        final eid = await SyncQueueHelper.utilityBillPaymentEntityIdFor(txn, p['id'] as int);
        if (eid != null) await SyncQueueHelper.enqueueDelete(txn, 'utility_bill_payment', eid);
      }
      await txn.delete('utility_bill_payments', where: 'billId = ?', whereArgs: [billId]);
      await txn.delete('utility_bills', where: 'id = ?', whereArgs: [billId]);
      await SyncQueueHelper.enqueueDelete(txn, 'utility_bill', billEid);
    });
  }

  Future<Set<String>> paidMonths(int billId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('utility_bill_payments', columns: ['month'], where: 'billId = ?', whereArgs: [billId]);
    return rows.map((r) => r['month'] as String).toSet();
  }

  Future<List<BillPayment>> payments(int billId, {int limit = 24}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('utility_bill_payments',
        where: 'billId = ?', whereArgs: [billId], orderBy: 'month DESC', limit: limit);
    return rows.map(BillPayment.fromMap).toList();
  }

  static const _syncBackfillKey = 'utility_bill_sync_backfilled';

  /// Sync aane se pehle bane bills/payments (serverId nahi) EK baar queue mein daal do taake doosre devices par bhi
  /// pahunchen. Flag local-only app setting hai (synced keys mein nahi). Doosre device se aayi rows (serverId wali)
  /// dobara push nahi hoti.
  Future<void> _backfillSync(DatabaseExecutor ex) async {
    final done = await ex.query('app_settings', where: 'key = ?', whereArgs: [_syncBackfillKey], limit: 1);
    if (done.isNotEmpty) return;
    await SyncQueueHelper.enqueueAllUtilityBills(ex, onlyUnsynced: true);
    await ex.insert('app_settings', {'key': _syncBackfillKey, 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Screen / reminder ke liye: har (active) bill ka status. Urgent pehle.
  ///
  /// [backfillSync] sirf screen (foreground) se true: purane bills ko ek baar sync queue mein daalna DeviceTag/branch
  /// chahta hai jo background isolate (reminder) mein set nahi hote.
  Future<List<BillView>> views({DateTime? now, bool activeOnly = true, bool backfillSync = false}) async {
    final t = now ?? DateTime.now();
    final db = await AppDatabase.instance.database;
    if (backfillSync) await _backfillSync(db);
    final bills = await list(activeOnly: activeOnly);
    final out = <BillView>[];
    for (final b in bills) {
      final id = b.id;
      if (id == null) continue;
      final paid = await paidMonths(id);
      final last = await db.query('utility_bill_payments',
          columns: ['amount'], where: 'billId = ?', whereArgs: [id], orderBy: 'month DESC', limit: 1);
      out.add(BillView(
        bill: b,
        status: billStatus(dueDay: b.dueDay, createdAtMs: b.createdAt, paidMonths: paid, now: t),
        lastAmount: last.isEmpty ? null : (last.first['amount'] as num).toDouble(),
      ));
    }
    out.sort(compareBillViews);
    return out;
  }

  /// Bill pay karo. [recordExpense] true ho to Expense + cash/bank OUT bhi bante hain (ek hi transaction mein).
  Future<void> pay({
    required UtilityBill bill,
    required String month,
    required double amount,
    required String method,
    String note = '',
    bool recordExpense = true,
  }) async {
    _requireStaff();
    final id = bill.id;
    if (id == null) throw ArgumentError('Bill not saved');
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(month)) throw ArgumentError('Invalid month');
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final dup = Sqflite.firstIntValue(await txn.rawQuery(
              'SELECT COUNT(*) FROM utility_bill_payments WHERE billId = ? AND month = ?', [id, month])) ??
          0;
      if (dup > 0) throw StateError('This month is already paid');
      int? expenseId;
      if (recordExpense) {
        expenseId = await ExpenseRepository.insertExpenseWithCash(
          txn,
          category: billExpenseCategory,
          description: '${bill.name} | $month',
          amount: amount,
          method: method,
          now: now,
        );
      }
      final paymentId = await txn.insert('utility_bill_payments', {
        'billId': id,
        'month': month,
        'amount': amount,
        'method': method,
        'note': note.trim(),
        'expenseId': expenseId,
        'paidAt': now,
        'updatedAt': now,
      });
      await SyncQueueHelper.enqueueUtilityBillPayment(txn, paymentId);
    });
  }

  /// Payment undo (galti se "paid" ho gaya). Saath bani Expense + cash row bhi hat'ti hai (agar abhi maujood ho).
  Future<void> undoPayment(int paymentId) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('utility_bill_payments', where: 'id = ?', whereArgs: [paymentId], limit: 1);
      if (rows.isEmpty) return;
      final expenseId = (rows.first['expenseId'] as num?)?.toInt();
      if (expenseId != null) {
        final ex = await txn.query('expenses', where: 'id = ?', whereArgs: [expenseId], limit: 1);
        if (ex.isNotEmpty) await ExpenseRepository.deleteInTxn(txn, Expense.fromMap(ex.first));
      }
      // Entity id row delete se PEHLE (doosre device se aayi payment ki asal serverId na khoye).
      final eid = await SyncQueueHelper.utilityBillPaymentEntityIdFor(txn, paymentId);
      await txn.delete('utility_bill_payments', where: 'id = ?', whereArgs: [paymentId]);
      if (eid != null) await SyncQueueHelper.enqueueDelete(txn, 'utility_bill_payment', eid);
    });
  }
}
