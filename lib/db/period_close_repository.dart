import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';

/// Optional Month Close. Koi mahina tab hi band hota hai jab user khud "Close Month" dabaye;
/// warna kuch bhi lock nahi hota. Band mahine ke bills / returns / expenses / payments edit-delete
/// nahi ho sakte (naye bills aaj ki date par hi bante hain, unpar asar nahi). Admin "Reopen" kar sakta hai.
///
/// SYNC: close / reopen sync queue mein jata hai (app_settings key `month_close:<yyyy-MM>`), is liye dusre
/// device par bhi wohi mahina band / khul jata hai. Last-write-wins (naya action jeetta hai).

class PeriodClosedException implements Exception {
  final String periodKey;
  const PeriodClosedException(this.periodKey);
  @override
  String toString() =>
      'Ye mahina ($periodKey) band (closed) hai. Pehle Monthly screen se "Reopen" karein, phir badlav karein.';
}

class PeriodClose {
  final String periodKey;
  final int closedAt;
  final String closedBy;
  final double saleTotal;
  final double purchaseTotal;
  final double expenseTotal;
  final String note;
  const PeriodClose({
    required this.periodKey,
    required this.closedAt,
    required this.closedBy,
    required this.saleTotal,
    required this.purchaseTotal,
    required this.expenseTotal,
    this.note = '',
  });

  double get net => saleTotal - purchaseTotal;
  double get profitAfterExpenses => saleTotal - purchaseTotal - expenseTotal;

  factory PeriodClose.fromMap(Map<String, Object?> m) => PeriodClose(
        periodKey: m['periodKey'] as String,
        closedAt: (m['closedAt'] as num).toInt(),
        closedBy: (m['closedBy'] as String?) ?? '',
        saleTotal: (m['saleTotal'] as num?)?.toDouble() ?? 0,
        purchaseTotal: (m['purchaseTotal'] as num?)?.toDouble() ?? 0,
        expenseTotal: (m['expenseTotal'] as num?)?.toDouble() ?? 0,
        note: (m['note'] as String?) ?? '',
      );
}

/// 'yyyy-MM' (device ki local date; Monthly screen ke groupPeriods jaisa).
String periodKeyOf(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

class PeriodCloseRepository {
  PeriodCloseRepository._();
  static final PeriodCloseRepository instance = PeriodCloseRepository._();

  /// Kisi bhi repository ke mutating method (transaction ke andar ya bahar) se: mahina band ho to throw.
  static Future<void> assertOpen(DatabaseExecutor ex, int millis) async {
    final key = periodKeyOf(millis);
    final rows = await ex.query('period_closes', columns: ['periodKey'], where: 'periodKey = ?', whereArgs: [key], limit: 1);
    if (rows.isNotEmpty) throw PeriodClosedException(key);
  }

  void _guard() {
    if (!Session.isAdmin) throw StateError('Sirf Admin month close / reopen kar sakta hai');
  }

  /// Band mahinon ki keys (Monthly screen par 🔒 dikhane ke liye).
  Future<Map<String, PeriodClose>> closedMap() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('period_closes');
    return {for (final r in rows) (r['periodKey'] as String): PeriodClose.fromMap(r)};
  }

  /// Mahina band: us waqt ke Sale / Purchase / Expense figures save hote hain.
  Future<PeriodClose> close(String periodKey, {String note = ''}) async {
    _guard();
    final y = int.parse(periodKey.substring(0, 4));
    final m = int.parse(periodKey.substring(5, 7));
    final from = DateTime(y, m, 1).millisecondsSinceEpoch;
    final to = DateTime(y, m + 1, 1).millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;
    late PeriodClose result;
    await db.transaction((txn) async {
      final exists = await txn.query('period_closes', where: 'periodKey = ?', whereArgs: [periodKey], limit: 1);
      if (exists.isNotEmpty) throw StateError('Ye mahina pehle hi band hai');
      Future<double> sum(String sql) async {
        final r = await txn.rawQuery(sql, [from, to]);
        return (r.first['t'] as num?)?.toDouble() ?? 0.0;
      }

      final sale = await sum("SELECT COALESCE(SUM(total),0) AS t FROM sales WHERE status != 'returned' AND createdAt >= ? AND createdAt < ?");
      final pur = await sum("SELECT COALESCE(SUM(total),0) AS t FROM purchases WHERE status != 'returned' AND createdAt >= ? AND createdAt < ?");
      final exp = await sum('SELECT COALESCE(SUM(amount),0) AS t FROM expenses WHERE createdAt >= ? AND createdAt < ?');
      final now = DateTime.now().millisecondsSinceEpoch;
      final by = Session.username ?? '';
      await txn.insert('period_closes', {
        'periodKey': periodKey,
        'closedAt': now,
        'closedBy': by,
        'saleTotal': sale,
        'purchaseTotal': pur,
        'expenseTotal': exp,
        'note': note,
      });
      await txn.insert('audit', {
        'username': by,
        'action': 'MONTH_CLOSE',
        'reference': periodKey,
        'details': 'Sale $sale | Purchase $pur | Expense $exp',
        'createdAt': now,
      });
      await SyncQueueHelper.enqueueAppSetting(
          txn,
          SyncQueueHelper.monthCloseKey(periodKey),
          jsonEncode({
            'closed': true,
            'closedAt': now,
            'closedBy': by,
            'saleTotal': sale,
            'purchaseTotal': pur,
            'expenseTotal': exp,
            'note': note,
          }));
      result = PeriodClose(
          periodKey: periodKey, closedAt: now, closedBy: by, saleTotal: sale, purchaseTotal: pur, expenseTotal: exp, note: note);
    });
    return result;
  }

  Future<void> reopen(String periodKey) async {
    _guard();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete('period_closes', where: 'periodKey = ?', whereArgs: [periodKey]);
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.insert('audit', {
        'username': Session.username ?? '',
        'action': 'MONTH_REOPEN',
        'reference': periodKey,
        'details': '',
        'createdAt': now,
      });
      await SyncQueueHelper.enqueueAppSetting(
          txn, SyncQueueHelper.monthCloseKey(periodKey), jsonEncode({'closed': false, 'reopenedAt': now}));
    });
  }
}
