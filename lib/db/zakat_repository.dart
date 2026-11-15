
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/product.dart';
import '../models/zakat.dart';
import '../services/session.dart';
import '../utils/hijri.dart';
import 'app_database.dart';
import 'balance_sheet_repository.dart' show stockValueAtCost;
import 'expense_repository.dart';
import 'user_repository.dart';
import '../sync/sync_queue_helper.dart';

/// Ports ZakatActivity.kt + ZakatDao: Ramadan-to-Ramadan Zakat year,
/// (cash + bank + stock at cost + receivables - payables) x 2.5%, payments
/// (all at once or instalments) and an editable 12-month plan.
///
/// The maths lives in PURE functions (below) so it can be unit-tested — see
/// test/zakat_test.dart. Admin / Manager only (screen has a RoleGuard and the
/// repository re-checks, because it reads cost data).

const double zakatRate = 0.025;

/// Standard estimate. Negative net assets => nothing payable (never < 0).
double zakatPayable(double netAssets) => netAssets > 0 ? netAssets * zakatRate : 0.0;

double netZakatableAssets({
  required double cashInHand,
  required double bankBalance,
  required double stockValue,
  required double receivables,
  required double payables,
}) =>
    cashInHand + bankBalance + stockValue + receivables - payables;

/// 1 Ramadan of Hijri [hijriYear] (local midnight).
DateTime ramadanStart(int hijriYear) => islamicToDateTime(hijriYear, 9, 1);

/// Most recent 1 Ramadan on/before [now] up to the following 1 Ramadan.
({DateTime start, DateTime end}) currentRamadanBracket(DateTime now) {
  final y = hijriYearOf(now);
  var start = ramadanStart(y);
  if (start.isAfter(now)) start = ramadanStart(y - 1);
  final end = ramadanStart(hijriYearOf(start) + 1);
  return (start: start, end: end);
}

/// Even 12 slices of [start, end) (~29.5 days each). Month [m] is 1..12.
int monthStartMillis(int startMs, int endMs, int m) => startMs + ((endMs - startMs) * (m - 1) ~/ 12);
int monthEndMillis(int startMs, int endMs, int m) => startMs + ((endMs - startMs) * m ~/ 12);

const islamicMonthNames = <(String, String)>[
  ('Ramadan', 'رمضان'),
  ('Shawwal', 'شوال'),
  ("Dhul-Qa'dah", 'ذوالقعدہ'),
  ('Dhul-Hijjah', 'ذوالحجہ'),
  ('Muharram', 'محرم'),
  ('Safar', 'صفر'),
  ("Rabi' al-Awwal", 'ربیع الاول'),
  ("Rabi' al-Thani", 'ربیع الثانی'),
  ('Jumada al-Awwal', 'جمادی الاولیٰ'),
  ('Jumada al-Thani', 'جمادی الثانی'),
  ('Rajab', 'رجب'),
  ("Sha'ban", 'شعبان'),
];

String zakatMonthLabel(ZakatYear y, int m, {required bool urdu}) {
  if (y.calendarType == 'gregorian') {
    return DateFormat('MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(monthStartMillis(y.startDate, y.endDate, m)));
  }
  if (m >= 1 && m <= 12) {
    final n = islamicMonthNames[m - 1];
    return urdu ? n.$2 : n.$1;
  }
  return urdu ? 'ماہ $m' : 'Month $m';
}

/// (payment category key, English, Urdu). '' = no category.
const zakatCategories = <(String, String, String)>[
  ('', 'No category', 'کوئی کیٹیگری نہیں'),
  ('cash', 'Cash / Bank', 'نقدی / بینک'),
  ('gold', 'Gold', 'سونا'),
  ('silver', 'Silver', 'چاندی'),
  ('business', 'Business Stock', 'کاروباری مال'),
  ('livestock', 'Livestock', 'مویشی'),
  ('crops', 'Crops / Produce', 'فصل / پیداوار'),
  ('other', 'Other', 'دیگر'),
];

/// Expense description: "Zakat payment (01 Mar 2026 — 08 Feb 2027) | note".
String zakatPaymentDescription({
  required int startMs,
  required int endMs,
  required String note,
  required bool urdu,
}) {
  final f = DateFormat('dd MMM yyyy');
  final range = '${f.format(DateTime.fromMillisecondsSinceEpoch(startMs))} \u2014 ${f.format(DateTime.fromMillisecondsSinceEpoch(endMs))}';
  final base = '${urdu ? 'زکوٰۃ کی ادائیگی' : 'Zakat payment'} ($range)';
  final n = note.trim();
  return n.isEmpty ? base : '$base | $n';
}

class ZakatAutoFigures {
  final double cashInHand, bankBalance, stockValue, receivables, payables;
  const ZakatAutoFigures(this.cashInHand, this.bankBalance, this.stockValue, this.receivables, this.payables);
  double get net => netZakatableAssets(
      cashInHand: cashInHand, bankBalance: bankBalance, stockValue: stockValue, receivables: receivables, payables: payables);
}

class ZakatMonthRow {
  final int month;
  final double payable, paid;
  final String note;
  final ZakatMonthPlan? plan;
  const ZakatMonthRow(this.month, this.payable, this.paid, this.note, this.plan);
  bool get covered => paid >= payable - 0.5;
  double get remaining => (payable - paid) < 0 ? 0 : payable - paid;
}

class ZakatSnapshot {
  final ZakatYear? active; // null => no active year (start one)
  final double paid;
  final List<ZakatPayment> payments;
  final List<ZakatMonthRow> months;
  final ({DateTime start, DateTime end}) bracket;
  const ZakatSnapshot(this.active, this.paid, this.payments, this.months, this.bracket);
}

class ZakatRepository {
  ZakatRepository._();
  static final ZakatRepository instance = ZakatRepository._();

  static void _requireAccess() {
    if (!Session.isAdminOrManager) {
      throw StateError('Sirf Admin/Manager is screen ko access kar sakta hai');
    }
  }

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  static Future<void> _enqueue(Transaction txn, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(txn, type, id, op, payload);

  Future<String> defaultCurrency() async {
    final v = (await UserRepository.instance.getSetting('currency'))?.trim() ?? '';
    return v.isEmpty ? 'Rs' : v;
  }

  /// Newest year; on equal startDate the later-created row wins.
  Future<ZakatYear?> latestYear() async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('zakat_years', orderBy: 'startDate DESC, id DESC', limit: 1);
    return r.isEmpty ? null : ZakatYear.fromMap(r.first);
  }

  Future<ZakatSnapshot> load({DateTime? now}) async {
    _requireAccess();
    final n = now ?? DateTime.now();
    final bracket = currentRamadanBracket(n);
    final year = await latestYear();
    if (year == null || n.millisecondsSinceEpoch >= year.endDate) {
      return ZakatSnapshot(null, 0, const [], const [], bracket);
    }
    final db = await AppDatabase.instance.database;
    final payRows = await db.query('zakat_payments',
        where: 'zakatYearId = ?', whereArgs: [year.id], orderBy: 'paymentDate DESC, id DESC');
    final payments = payRows.map(ZakatPayment.fromMap).toList();
    final paid = payments.fold<double>(0, (a, p) => a + p.amount);

    final planRows = await db.query('zakat_month_plans', where: 'zakatYearId = ?', whereArgs: [year.id]);
    final plans = {for (final r in planRows.map(ZakatMonthPlan.fromMap)) r.monthIndex: r};
    final defaultMonthly = year.totalPayable / 12.0;
    final months = <ZakatMonthRow>[];
    for (var m = 1; m <= 12; m++) {
      final s = monthStartMillis(year.startDate, year.endDate, m);
      final e = monthEndMillis(year.startDate, year.endDate, m);
      final paidM = payments.where((p) => p.paymentDate >= s && p.paymentDate < e).fold<double>(0, (a, p) => a + p.amount);
      final plan = plans[m];
      months.add(ZakatMonthRow(m, plan?.payableAmount ?? defaultMonthly, paidM, plan?.note ?? '', plan));
    }
    return ZakatSnapshot(year, paid, payments, months, bracket);
  }

  /// Cash + bank + stock (at cost) + receivables - payables, from live data.
  Future<ZakatAutoFigures> autoFigures() async {
    _requireAccess();
    final db = await AppDatabase.instance.database;
    Future<double> scalar(String sql, [List<Object?>? args]) async {
      final r = await db.rawQuery(sql, args);
      if (r.isEmpty) return 0.0;
      return ((r.first.values.first) as num?)?.toDouble() ?? 0.0;
    }

    Future<double> total(String type, String method) =>
        scalar('SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type=? AND method=?', [type, method]);

    final products = (await db.query('products')).map(Product.fromMap).toList();
    return ZakatAutoFigures(
      await total('IN', 'cash') - await total('OUT', 'cash'),
      await total('IN', 'bank') - await total('OUT', 'bank'),
      stockValueAtCost(products),
      await scalar('SELECT COALESCE(SUM(balance),0) FROM customers WHERE balance>0'),
      await scalar('SELECT COALESCE(SUM(balance),0) FROM suppliers WHERE balance>0'),
    );
  }

  /// Starts the year for [bracket], or — if that year already exists — updates
  /// its assets/currency/calendar IN PLACE. Never inserts a second year with the
  /// same start date, so recalculating can't orphan already-recorded payments.
  Future<void> startOrRecalculateYear({
    required DateTime start,
    required DateTime end,
    required double assets,
    required String currency,
    required String calendarType,
  }) async {
    _requireAccess();
    if (!assets.isFinite || assets < 0) throw ArgumentError('Enter a valid amount');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query('zakat_years',
          where: 'startDate = ?', whereArgs: [start.millisecondsSinceEpoch], orderBy: 'id DESC', limit: 1);
      if (rows.isNotEmpty) {
        final updated = ZakatYear.fromMap(rows.first)
            .copyWith(assetsSnapshot: assets, totalPayable: zakatPayable(assets), currency: currency, calendarType: calendarType);
        await txn.update('zakat_years', updated.toMap(), where: 'id = ?', whereArgs: [updated.id]);
        await _enqueue(txn, 'zakat_year', '${updated.id}', 'update', updated.toMap());
      } else {
        final y = ZakatYear(
          startDate: start.millisecondsSinceEpoch,
          endDate: end.millisecondsSinceEpoch,
          assetsSnapshot: assets,
          totalPayable: zakatPayable(assets),
          currency: currency,
          calendarType: calendarType,
          createdAt: now,
          updatedAt: now,
        );
        final id = await txn.insert('zakat_years', y.toMap());
        await _enqueue(txn, 'zakat_year', '$id', 'create', {...y.toMap(), 'id': id});
      }
    });
  }

  /// Edit a saved year's assets / currency / calendar (payable recalculated).
  Future<void> updateYear(ZakatYear year, {required double assets, required String currency, required String calendarType}) async {
    _requireAccess();
    if (!assets.isFinite || assets < 0) throw ArgumentError('Enter a valid amount');
    final db = await AppDatabase.instance.database;
    final updated = year.copyWith(assetsSnapshot: assets, totalPayable: zakatPayable(assets), currency: currency, calendarType: calendarType);
    await db.transaction((txn) async {
      await txn.update('zakat_years', updated.toMap(), where: 'id = ?', whereArgs: [year.id]);
      await _enqueue(txn, 'zakat_year', '${year.id}', 'update', updated.toMap());
    });
  }

  /// ONE transaction: ZakatPayment + mirrored Expense("Zakat") + cash OUT row +
  /// sync entries, so Cash in Hand, P&L and the Zakat paid total never disagree
  /// (Kotlin audit #5).
  Future<void> savePayment({
    required ZakatYear year,
    required double amount,
    required String method,
    String note = '',
    String category = '',
    DateTime? paymentDate,
    bool urdu = false,
  }) async {
    _requireAccess();
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Enter a valid amount');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final when = (paymentDate ?? DateTime.now()).millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final payment = ZakatPayment(
        zakatYearId: year.id!,
        amount: amount,
        method: method,
        note: note.trim(),
        category: category,
        paymentDate: when,
        createdAt: now,
        updatedAt: now,
      );
      final pid = await txn.insert('zakat_payments', payment.toMap());
      await _enqueue(txn, 'zakat_payment', '$pid', 'create', {
        ...payment.toMap(),
        'id': pid,
        'zakatYearServerId': year.serverId ?? 'zakat_year:${year.id}',
      });
      await ExpenseRepository.insertExpenseWithCash(
        txn,
        category: 'Zakat',
        description: zakatPaymentDescription(startMs: year.startDate, endMs: year.endDate, note: note, urdu: urdu),
        amount: amount,
        method: method,
        now: now,
        createdAt: when,
      );
    });
  }

  Future<void> saveMonthPlan(ZakatYear year, int month, double amount, String note, ZakatMonthPlan? existing) async {
    _requireAccess();
    if (!amount.isFinite || amount < 0) throw ArgumentError('Enter a valid amount');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing != null) {
      final u = ZakatMonthPlan(
        id: existing.id,
        zakatYearId: existing.zakatYearId,
        monthIndex: existing.monthIndex,
        payableAmount: amount,
        note: note.trim(),
        createdAt: existing.createdAt,
        updatedAt: now,
      );
      await db.update('zakat_month_plans', u.toMap(), where: 'id = ?', whereArgs: [existing.id]);
    } else {
      final p = ZakatMonthPlan(
          zakatYearId: year.id!, monthIndex: month, payableAmount: amount, note: note.trim(), createdAt: now, updatedAt: now);
      await db.insert('zakat_month_plans', p.toMap());
    }
  }
}
