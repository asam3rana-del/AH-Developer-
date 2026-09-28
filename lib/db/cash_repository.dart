import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/misc_entities.dart';
import 'app_database.dart';
import 'day_book_repository.dart';
import 'expense_repository.dart' show ExpenseRepository;

/// Ports CashActivity.kt (saveEntry / loadTodayTotals / loadTransactions).
///
/// [planCashEntry] is a PURE function so the Kotlin rules can be unit-tested
/// (test/cash_test.dart) without a database.

class CashCategories {
  CashCategories._();

  static const nonExpense = 'Non-expense (Withdrawal / Transfer)';
  static const miscellaneous = 'Miscellaneous';

  /// Same list and order as Kotlin `expenseCategories`.
  static const all = <String>[
    'Food Authority License Fees',
    'Utility Bills',
    'Wages',
    'Fuel Expense',
    'Pick up Maintenance',
    'Fines',
    'Rent',
    'Income Tax Fees',
    miscellaneous,
    nonExpense,
  ];
}

/// What one tap on CASH IN / CASH OUT will write.
class CashEntryPlan {
  /// true => a real Expense + its linked cash row (Cash Out under a category).
  final bool createsExpense;

  /// Reason of the plain cash row (used only when [createsExpense] is false).
  final String cashReason;

  /// Description stored on the Expense (used only when [createsExpense] is true).
  final String expenseDescription;

  const CashEntryPlan({
    required this.createsExpense,
    required this.cashReason,
    required this.expenseDescription,
  });
}

/// [type] is 'IN' | 'OUT'. Category matters ONLY for OUT and never for
/// [CashCategories.nonExpense] (owner withdrawal / bank transfer = plain cash
/// movement, no Expense, so profit is not reduced).
CashEntryPlan planCashEntry({
  required String type,
  required String category,
  required String misc,
  required String note,
}) {
  final cat = category.trim();
  final m = misc.trim();
  final n = note.trim();
  final isExpense = type == 'OUT' && cat.isNotEmpty && cat != CashCategories.nonExpense;

  final reason = StringBuffer();
  if (isExpense) {
    reason.write(cat);
    if (cat == CashCategories.miscellaneous && m.isNotEmpty) {
      if (reason.isNotEmpty) reason.write(' - ');
      reason.write(m);
    }
  }
  if (n.isNotEmpty) {
    if (reason.isNotEmpty) reason.write(' | ');
    reason.write(n);
  }

  final desc = StringBuffer();
  if (cat == CashCategories.miscellaneous && m.isNotEmpty) desc.write(m);
  if (n.isNotEmpty) {
    if (desc.isNotEmpty) desc.write(' | ');
    desc.write(n);
  }

  return CashEntryPlan(
    createsExpense: isExpense,
    cashReason: reason.toString(),
    expenseDescription: desc.toString(),
  );
}

class CashTotals {
  final double cashIn;
  final double cashOut;
  const CashTotals(this.cashIn, this.cashOut);
}

class CashRepository {
  CashRepository._();
  static final CashRepository instance = CashRepository._();

  Future<void> _enqueue(Transaction txn, String type, String id, String op, Map<String, Object?> payload) =>
      txn.insert('sync_queue', {
        'entityType': type,
        'entityId': id,
        'operation': op,
        'payloadJson': jsonEncode(payload),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'retryCount': 0,
      });

  /// Saves one Cash In / Cash Out. Everything runs in ONE transaction.
  ///
  /// A Cash Out under a real category creates the Expense AND its linked cash
  /// row (reference `expense:<id>`, reason `Expense: <category>`), exactly like
  /// ExpenseActivity.saveExpense(), so Reports / Balance Sheet profit count it.
  /// `expense:` is not blank / `manual-` / `return:`, so Day Book shows it once
  /// (as the expense row) and not twice.
  ///
  /// TODO(Phase 10): reference/entityId should use DeviceTag like Kotlin
  /// (`expense:<device>-<id>`); until then it is `expense:<id>`.
  Future<void> save({
    required String type,
    required double amount,
    required String method,
    required String category,
    String misc = '',
    String note = '',
  }) async {
    if (type != 'IN' && type != 'OUT') throw ArgumentError('type must be IN or OUT');
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');

    final plan = planCashEntry(type: type, category: category, misc: misc, note: note);
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;

    await db.transaction((txn) async {
      if (plan.createsExpense) {
        // Same code path as the Expense screen (ExpenseRepository), so the
        // Expense + linked cash OUT row can never be written two different ways.
        await ExpenseRepository.insertExpenseWithCash(
          txn,
          category: category.trim(),
          description: plan.expenseDescription,
          amount: amount,
          method: method,
          now: now,
        );
      } else {
        final cash = CashTransaction(
          type: type,
          method: method,
          amount: amount,
          reason: plan.cashReason,
          createdAt: now,
          updatedAt: now,
        );
        final cashId = await txn.insert('cash_transactions', cash.toMap());
        await _enqueue(txn, 'cash_transaction', '$cashId', 'create', {...cash.toMap(), 'id': cashId});
      }
    });
  }

  /// Today's Cash In / Cash Out (cash + bank together), same as Kotlin
  /// loadTodayTotals — every cash row of today, including sale/purchase ones.
  Future<CashTotals> todayTotals() async {
    final db = await AppDatabase.instance.database;
    final (start, end) = DayBookRepository.dayBounds(DateTime.now());
    final rows = await db.rawQuery(
      'SELECT type, COALESCE(SUM(amount), 0) AS total FROM cash_transactions '
      'WHERE createdAt >= ? AND createdAt < ? GROUP BY type',
      [start, end],
    );
    double inTotal = 0, outTotal = 0;
    for (final r in rows) {
      final v = (r['total'] as num).toDouble();
      if (r['type'] == 'IN') inTotal = v;
      if (r['type'] == 'OUT') outTotal = v;
    }
    return CashTotals(inTotal, outTotal);
  }

  /// Newest first (Kotlin shows the latest 50).
  Future<List<CashTransaction>> recent({int limit = 50}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('cash_transactions', orderBy: 'createdAt DESC, id DESC', limit: limit);
    return rows.map(CashTransaction.fromMap).toList();
  }
}
