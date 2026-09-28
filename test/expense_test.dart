import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/cash_repository.dart';
import 'package:ah_developer_kiryana_store/db/expense_repository.dart';

void main() {
  test('Expense category list matches Kotlin (11 items, Misc last)', () {
    expect(ExpenseCategories.all.length, 11);
    expect(ExpenseCategories.all.first, 'Food Authority License Fees');
    expect(ExpenseCategories.all.last, ExpenseCategories.miscellaneous);
    expect(ExpenseCategories.all, containsAll(['Salaries', 'Zakat']));
  });

  test('Expense list differs from Cash list (no Non-expense here)', () {
    expect(ExpenseCategories.all.contains(CashCategories.nonExpense), isFalse);
    expect(CashCategories.all.contains('Salaries'), isFalse);
  });

  test('cash row reason and reference format', () {
    expect(expenseCashReason('Rent'), 'Expense: Rent');
    expect(expenseCashReason(''), 'Expense');
    expect(expenseCashReference(7), 'expense:7');
  });

  test('Expense screen description rule = Cash Out under a category', () {
    final p = planCashEntry(type: 'OUT', category: ExpenseCategories.miscellaneous, misc: ' Broom ', note: 'urgent');
    expect(p.createsExpense, isTrue);
    expect(p.expenseDescription, 'Broom | urgent');
    // Zakat / Salaries are real expenses too (not Non-expense).
    expect(planCashEntry(type: 'OUT', category: 'Zakat', misc: '', note: '').createsExpense, isTrue);
    expect(planCashEntry(type: 'OUT', category: 'Salaries', misc: '', note: '').createsExpense, isTrue);
  });

  test('ExpenseTotals holds today and month', () {
    const t = ExpenseTotals(10, 250);
    expect(t.today, 10);
    expect(t.month, 250);
  });
}
