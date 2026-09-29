
import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/misc_entities.dart';
import 'app_database.dart';
import 'cash_repository.dart' show planCashEntry;
import '../sync/device_tag.dart';
import '../sync/sync_queue_helper.dart';

/// Ports ExpenseActivity.kt (saveExpense / confirmDeleteExpense / loadTotals /
/// loadExpenses). Expense + its linked Cash OUT row are ALWAYS written and
/// deleted together in ONE transaction (Kotlin audit #4), so Cash in Hand and
/// the expense list can never disagree.

/// Expense screen categories — same list and order as Kotlin ExpenseActivity.
/// (CashActivity has its own, slightly different list: no Salaries/Zakat, plus
/// "Non-expense" — see CashCategories.)
class ExpenseCategories {
  ExpenseCategories._();
  static const miscellaneous = 'Miscellaneous';
  static const all = <String>[
    'Food Authority License Fees',
    'Utility Bills',
    'Wages',
    'Salaries',
    'Fuel Expense',
    'Pick up Maintenance',
    'Fines',
    'Rent',
    'Income Tax Fees',
    'Zakat',
    miscellaneous,
  ];
}

class ExpenseTotals {
  final double today;
  final double month;
  const ExpenseTotals(this.today, this.month);
}

/// Cash row reason: "Expense" or "Expense: <category>".
String expenseCashReason(String category) => 'Expense${category.isNotEmpty ? ': $category' : ''}';

/// PURANA (legacy) reference: sirf local id (`expense:7`). Do devices par dono ke paas expense #7 hota hai,
/// is liye naye rows ab [expenseCashReference] use karte hain; yeh sirf purani rows ki safai ke liye hai.
String legacyExpenseCashReference(int expenseId) => 'expense:$expenseId';

/// Reference jo cash OUT row ko uske expense se bandhta hai (delete isi se dhoondta hai).
/// Kotlin `SyncQueueHelper.expenseEntityId(savedExpense)`: serverId ho to wahi, warna
/// `expense:<DeviceTag>-<id>` — device-unique, taake ek device ka delete doosre ka cash-out na uraye.
String expenseCashReference(int expenseId, {String? serverId}) =>
    SyncQueueHelper.expenseEntityId({'id': expenseId, 'serverId': serverId});

class ExpenseRepository {
  ExpenseRepository._();
  static final ExpenseRepository instance = ExpenseRepository._();

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  static Future<void> _enqueue(Transaction txn, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(txn, type, id, op, payload);

  /// Inserts the Expense AND its linked cash OUT row (+ both sync entries)
  /// inside the caller's transaction. Shared by the Expense screen and by
  /// Cash Out under a category (CashRepository.save).
  static Future<int> insertExpenseWithCash(
    Transaction txn, {
    required String category,
    required String description,
    required double amount,
    required String method,
    required int now,
    int? createdAt, // backdated entries (e.g. Zakat paid on an earlier date)
  }) async {
    final expense = Expense(
      category: category,
      description: description,
      amount: amount,
      method: method,
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
    final expenseId = await txn.insert('expenses', expense.toMap());
    await _enqueue(txn, 'expense', '$expenseId', 'create', {...expense.toMap(), 'id': expenseId});

    final cash = CashTransaction(
      type: 'OUT',
      method: method,
      amount: amount,
      reason: expenseCashReason(category),
      reference: expenseCashReference(expenseId),
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
    final cashId = await txn.insert('cash_transactions', cash.toMap());
    await _enqueue(txn, 'cash_transaction', '$cashId', 'create', {...cash.toMap(), 'id': cashId});
    return expenseId;
  }

  Future<void> save({
    required double amount,
    required String category,
    required String method,
    String misc = '',
    String note = '',
  }) async {
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');
    final cat = category.trim();
    // Same description rule as Kotlin: (Miscellaneous ? misc) + " | " + note.
    final description = planCashEntry(type: 'OUT', category: cat, misc: misc, note: note).expenseDescription;
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await insertExpenseWithCash(txn, category: cat, description: description, amount: amount, method: method, now: now);
    });
  }

  /// Deletes the expense, queues its delete, and removes the matching cash OUT
  /// row(s) so Cash in Hand is not understated forever — all in ONE transaction.
  Future<void> delete(Expense e) async {
    final id = e.id;
    if (id == null) return;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      // Entity id (serverId-preferred) row delete se PEHLE — doosre device se aayi row ki asal id na khoye.
      final eid = await SyncQueueHelper.entityIdFor(txn, 'expense', '$id');
      await txn.delete('expenses', where: 'id = ?', whereArgs: [id]);
      await SyncQueueHelper.enqueueDelete(txn, 'expense', eid);

      await SyncQueueHelper.deleteCashTransactionsByReference(txn, expenseCashReference(id, serverId: e.serverId));
      // Purani rows (is fix se pehle) `expense:<localId>` use karti thin — yeh format sirf usi expense ke liye
      // mehfooz hai jo isi device par bana (Kotlin `madeHere`).
      final madeHere = e.serverId == null || e.serverId!.startsWith('expense:${DeviceTag.current}-');
      if (madeHere) {
        await SyncQueueHelper.deleteCashTransactionsByReference(txn, legacyExpenseCashReference(id));
      }
    });
  }

  /// Today's and this month's expense totals (Kotlin loadTotals). Upper bound is
  /// exclusive, so an expense at exactly midnight is counted once.
  Future<ExpenseTotals> totals({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final dayStart = DateTime(n.year, n.month, n.day);
    final dayEnd = DateTime(n.year, n.month, n.day + 1);
    final monthStart = DateTime(n.year, n.month, 1);
    final monthEnd = DateTime(n.year, n.month + 1, 1);
    final db = await AppDatabase.instance.database;

    Future<double> sum(DateTime a, DateTime b) async {
      final r = await db.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM expenses WHERE createdAt >= ? AND createdAt < ?',
        [a.millisecondsSinceEpoch, b.millisecondsSinceEpoch],
      );
      return (r.first['t'] as num).toDouble();
    }

    return ExpenseTotals(await sum(dayStart, dayEnd), await sum(monthStart, monthEnd));
  }

  /// Newest first (Kotlin shows the latest 50).
  Future<List<Expense>> recent({int limit = 50}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('expenses', orderBy: 'createdAt DESC, id DESC', limit: limit);
    return rows.map(Expense.fromMap).toList();
  }
}
