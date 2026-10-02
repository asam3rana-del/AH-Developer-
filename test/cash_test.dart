import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/cash_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';

void main() {
  test('Cash Out under a real category creates an Expense', () {
    final p = planCashEntry(type: 'OUT', category: 'Rent', misc: '', note: 'Shop rent');
    expect(p.createsExpense, isTrue);
    expect(p.expenseDescription, 'Shop rent');
  });

  test('Non-expense Cash Out is a plain cash movement (no Expense)', () {
    final p = planCashEntry(type: 'OUT', category: CashCategories.nonExpense, misc: '', note: 'Owner withdrawal');
    expect(p.createsExpense, isFalse);
    expect(p.cashReason, 'Owner withdrawal'); // category is NOT written into the reason
  });

  test('Cash In ignores the category completely', () {
    final p = planCashEntry(type: 'IN', category: 'Rent', misc: 'x', note: 'Owner capital');
    expect(p.createsExpense, isFalse);
    expect(p.cashReason, 'Owner capital');
  });

  test('Miscellaneous joins description and note', () {
    final p = planCashEntry(type: 'OUT', category: CashCategories.miscellaneous, misc: ' Broom ', note: 'urgent');
    expect(p.createsExpense, isTrue);
    expect(p.expenseDescription, 'Broom | urgent');
    expect(p.cashReason, 'Miscellaneous - Broom | urgent');
  });

  test('Miscellaneous with no description', () {
    final p = planCashEntry(type: 'OUT', category: CashCategories.miscellaneous, misc: '', note: '');
    expect(p.expenseDescription, '');
    expect(p.cashReason, 'Miscellaneous');
  });

  test('description of a non-misc category ignores stray misc text', () {
    final p = planCashEntry(type: 'OUT', category: 'Wages', misc: 'leftover', note: '');
    expect(p.expenseDescription, '');
  });

  test('category list matches Kotlin (10 items, non-expense last)', () {
    expect(CashCategories.all.length, 10);
    expect(CashCategories.all.last, CashCategories.nonExpense);
    expect(CashCategories.all.first, 'Food Authority License Fees');
  });

  test('Expense.method defaults to cash and round-trips', () {
    final e = Expense(category: 'Rent', description: '', amount: 5, createdAt: 1, method: 'bank');
    expect(Expense.fromMap(e.toMap()).method, 'bank');
    final old = Expense.fromMap({'category': 'Rent', 'description': '', 'amount': 5, 'createdAt': 1});
    expect(old.method, 'cash'); // rows from before DB v6
  });
}
