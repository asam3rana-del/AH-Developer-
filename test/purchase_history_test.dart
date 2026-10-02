import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/purchase_history_repository.dart';
import 'package:ah_developer_kiryana_store/utils/bill_text.dart';

PurchaseHistoryRow row(String bill, String sup, double total, double paid, {String status = 'active', int at = 1}) =>
    PurchaseHistoryRow(billNo: bill, supplierName: sup, total: total, paid: paid, createdAt: at, status: status);

const lines = [
  ReturnableLine(itemId: 1, name: 'Rice', unit: 'kg', qty: 10),
  ReturnableLine(itemId: 2, name: 'Oil', unit: 'ltr', qty: 5),
];

void main() {
  group('summary', () {
    test('returned bills are NOT counted; due never negative', () {
      final s = summarizePurchases([
        row('P1', 'Ali', 1000, 400),
        row('P2', 'Bilal', 500, 700), // overpaid => due 0, total still counts
        row('P3', 'Ali', 900, 0, status: 'returned'),
      ]);
      expect(s.totalPurchases, 1500);
      expect(s.totalDue, 600);
    });

    test('due getter clamps at 0', () {
      expect(row('P', 'x', 100, 250).due, 0);
      expect(row('P', 'x', 100, 30).due, 70);
    });
  });

  test('search matches bill no OR supplier, case-insensitive; blank = all', () {
    final rows = [row('PUR-Sep26-0001', 'Ali Traders', 1, 0), row('PUR-Sep26-0002', 'Cash Purchase', 1, 0)];
    expect(filterPurchaseRows(rows, 'ali').length, 1);
    expect(filterPurchaseRows(rows, '0002').single.supplierName, 'Cash Purchase');
    expect(filterPurchaseRows(rows, '  ').length, 2);
  });

  group('parseReturnRequest (Kotlin dialog validation)', () {
    test('blank and 0 are skipped, valid qty kept', () {
      final r = parseReturnRequest(lines, {1: '3', 2: '0'});
      expect(r.error, isNull);
      expect(r.quantities, {1: 3.0});
    });

    test('nothing entered => error', () {
      expect(parseReturnRequest(lines, {1: '', 2: ' '}).error, isNotNull);
    });

    test('more than purchased => error', () {
      final r = parseReturnRequest(lines, {1: '10.5'});
      expect(r.error, contains('can\'t exceed'));
      expect(r.quantities, isEmpty);
    });

    test('exactly the purchased qty is allowed; junk / negative => error', () {
      expect(parseReturnRequest(lines, {1: '10'}).quantities, {1: 10.0});
      expect(parseReturnRequest(lines, {1: 'abc'}).error, isNotNull);
      expect(parseReturnRequest(lines, {1: '-2'}).error, isNotNull);
    });
  });

  test('returnedLineAmount scales line amount by returned share', () {
    expect(returnedLineAmount(lineQty: 10, lineAmount: 1000, unitCost: 100, returnQty: 3), 300);
    expect(returnedLineAmount(lineQty: 0, lineAmount: 0, unitCost: 50, returnQty: 2), 100);
    expect(returnedLineAmount(lineQty: 10, lineAmount: 1000, unitCost: 100, returnQty: 10), 1000);
  });

  group('purchase bill text', () {
    test('shows supplier, lines, totals and DUE only when unpaid', () {
      final t = buildPurchaseBillText(
        shopName: 'Shop',
        billNo: 'PUR-Sep26-0001',
        date: DateTime(2026, 9, 29, 10, 30),
        supplier: 'Ali',
        lines: [(name: 'Rice', qty: 10, unit: 'kg', unitCost: 100, amount: 1000)],
        subtotal: 1000,
        discount: 0,
        total: 1000,
        paid: 400,
      );
      expect(t, contains('PURCHASE BILL'));
      expect(t, contains('Supplier: Ali'));
      expect(t, contains('10 kg x 100.00'));
      expect(t, contains('DUE'));
      final paidOff = buildPurchaseBillText(
        shopName: 'Shop',
        billNo: 'B',
        date: DateTime(2026, 9, 29),
        supplier: '',
        lines: const [],
        subtotal: 0,
        discount: 0,
        total: 100,
        paid: 100,
      );
      expect(paidOff, isNot(contains('DUE')));
      expect(paidOff, contains('Cash Purchase'));
    });

    test('share text has balance', () {
      final t = buildPurchaseShareText(supplier: 'Ali', billNo: 'B1', total: 500, balance: 120, date: DateTime(2026, 9, 29));
      expect(t, contains('Balance: Rs 120.00'));
      expect(t, contains('29 Sep 2026'));
    });
  });
}
