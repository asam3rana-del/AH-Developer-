import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/day_book_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';

DayBookSaleRow sale(String inv, double total, double paid, {String status = 'active', int at = 1000}) =>
    DayBookSaleRow(invoice: inv, customerName: 'Ali', total: total, paid: paid, createdAt: at, status: status);

DayBookPurchaseRow purchase(String bill, double total, double paid, {String status = 'active', int at = 1000}) =>
    DayBookPurchaseRow(billNo: bill, supplierName: 'Sup', total: total, paid: paid, createdAt: at, status: status);

CashTransaction cash(String type, double amt, {String ref = '', int at = 1000}) =>
    CashTransaction(type: type, method: 'cash', amount: amt, reference: ref, createdAt: at);

DayBookData build({
  List<DayBookSaleRow> sales = const [],
  List<DayBookPurchaseRow> purchases = const [],
  List<Expense> expenses = const [],
  List<CashTransaction> cashTx = const [],
  Map<String, double> linked = const {},
}) =>
    buildDayBook(sales: sales, purchases: purchases, expenses: expenses, cashTx: cashTx, linkedPaidByBill: linked);

void main() {
  test('sale paid + purchase paid + expense => cash in/out/net', () {
    final d = build(
      sales: [sale('INV-1', 1000, 600)],
      purchases: [purchase('B-1', 500, 500)],
      expenses: [const Expense(category: 'Tea', description: '', amount: 50, createdAt: 1000)],
    );
    expect(d.summary.totalSales, 1000);
    expect(d.summary.totalPurchases, 500);
    expect(d.summary.cashIn, 600);
    expect(d.summary.cashOut, 500);
    expect(d.summary.cashOutWithExpenses, 550);
    expect(d.summary.net, 600 - 500 - 50);
    expect(d.entries.length, 3);
  });

  test('returned bills are listed but excluded from totals', () {
    final d = build(sales: [sale('INV-1', 1000, 1000, status: 'returned')]);
    expect(d.entries.length, 1);
    expect(d.entries.first.subtitle, contains('RETURNED'));
    expect(d.summary.totalSales, 0);
    expect(d.summary.cashIn, 0);
  });

  test('due shown on partly paid bill', () {
    final d = build(sales: [sale('INV-1', 1000, 400)]);
    expect(d.entries.first.subtitle, contains('Due Rs 600'));
  });

  test('payment linked to a bill is not counted twice', () {
    // Bill paid = 500, of which 200 came from a linked payment that ALSO has its own manual cash row today.
    final d = build(
      sales: [sale('INV-1', 1000, 500)],
      cashTx: [cash('IN', 200, ref: 'manual-customer-1-999')],
      linked: {'INV-1': 200},
    );
    expect(d.summary.cashIn, 500); // 300 own + 200 manual, not 700
  });

  test('linked amount larger than paid never goes negative', () {
    final d = build(sales: [sale('INV-1', 1000, 100)], linked: {'INV-1': 300});
    expect(d.summary.cashIn, 0);
  });

  test('cash rows tied to a bill are hidden; blank / manual- / return: are shown', () {
    final d = build(cashTx: [
      cash('IN', 10, ref: 'INV-1'), // represented by the sale row
      cash('IN', 20, ref: ''),
      cash('OUT', 30, ref: 'manual-supplier-2-1'),
      cash('OUT', 40, ref: 'return:INV-9'),
    ]);
    expect(d.entries.length, 3);
    expect(d.summary.cashIn, 20);
    expect(d.summary.cashOut, 70);
  });

  test('entries are newest first', () {
    final d = build(
      sales: [sale('A', 1, 1, at: 100)],
      purchases: [purchase('B', 1, 1, at: 300)],
      cashTx: [cash('IN', 5, at: 200)],
    );
    expect(d.entries.map((e) => e.time).toList(), [300, 200, 100]);
  });

  test('dayBounds covers exactly local midnight to next midnight', () {
    final (s, e) = DayBookRepository.dayBounds(DateTime(2026, 3, 8, 15, 30));
    expect(s, DateTime(2026, 3, 8).millisecondsSinceEpoch);
    expect(e, DateTime(2026, 3, 9).millisecondsSinceEpoch);
  });
}
