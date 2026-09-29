import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_reports_repository.dart';

ReportBill bill(String id, double total, double paid, int t, {String status = 'completed'}) =>
    ReportBill(id: id, total: total, paid: paid, createdAt: t, status: status);

ReportPayment pay(String ref, double amount, int t, {String billRef = ''}) =>
    ReportPayment(reference: ref, billReference: billRef, amount: amount, createdAt: t);

void main() {
  group('ledger lines', () {
    test('returned bills are excluded', () {
      final lines = buildLedgerLines(
        bills: [bill('S1', 1000, 200, 1), bill('S2', 500, 0, 2, status: 'returned')],
        payments: const [],
      );
      expect(lines.length, 1);
      expect(lines.single.dr, 1000);
      expect(lines.single.cr, 200);
      expect(lines.single.delta, 800);
    });

    test('general payment is pure credit; bill-linked and bill-embedded payments are not double counted', () {
      final lines = buildLedgerLines(
        bills: [bill('S1', 1000, 300, 1), bill('S2', 400, 0, 5, status: 'returned')],
        payments: [
          pay('PAY-1', 200, 3), // general => counted
          pay('X', 100, 4, billRef: 'S1'), // linked => skipped
          pay('S1', 300, 1), // embedded (reference is own bill) => skipped
          pay('S2', 50, 6), // reference is a RETURNED own bill => still skipped (Kotlin ownBillIds)
        ],
      );
      expect(lines.length, 2);
      final res = runLedger(100, lines);
      // opening 100 + (1000-300) - 200 = 600
      expect(res.closing, 600);
      expect(res.rows[1].line.isPayment, isTrue);
      expect(res.rows[1].line.cr, 200);
    });

    test('lines sorted by time, ties keep bills before payments', () {
      final lines = buildLedgerLines(
        bills: [bill('S2', 50, 0, 10), bill('S1', 100, 0, 5)],
        payments: [pay('P', 10, 10)],
      );
      expect([for (final l in lines) l.time], [5, 10, 10]);
      expect(lines[1].isPayment, isFalse);
      expect(lines[2].isPayment, isTrue);
    });

    test('running balance with negative opening (party has advance)', () {
      final res = runLedger(-300, buildLedgerLines(bills: [bill('S1', 100, 0, 1)], payments: const []));
      expect(res.closing, -200);
      expect(res.rows.single.balance, -200);
    });
  });

  group('give/get colour rule', () {
    test('customer negative closing = give; supplier positive = give', () {
      expect(reportIsGive(isCustomer: true, closing: -1), isTrue);
      expect(reportIsGive(isCustomer: true, closing: 1), isFalse);
      expect(reportIsGive(isCustomer: false, closing: 1), isTrue);
      expect(reportIsGive(isCustomer: false, closing: -1), isFalse);
    });
  });

  group('item report', () {
    test('merges same product, sorts by amount desc', () {
      final r = aggregateItems([
        (name: 'Rice', qty: 2.0, amount: 100.0),
        (name: 'Sugar', qty: 1.0, amount: 300.0),
        (name: 'Rice', qty: 3.0, amount: 250.0),
      ]);
      expect([for (final i in r) i.product], ['Sugar', 'Rice']);
      expect(r[1].qty, 5);
      expect(r[1].amount, 350);
    });
  });

  group('payment history', () {
    test('only non-returned bills with paid > 0, newest first', () {
      final e = paymentEntries([
        bill('S1', 100, 50, 1),
        bill('S2', 100, 0, 2),
        bill('S3', 100, 70, 3, status: 'returned'),
        bill('S4', 100, 20, 4),
      ], isCustomer: true);
      expect([for (final x in e) x.amount], [20, 50]);
      expect(e.first.isSale, isTrue);
    });
  });

  group('P&L / summary', () {
    test('customer profit = revenue - cost', () {
      final pl = customerPL(bills: 2, items: [(amount: 500.0, cost: 400.0), (amount: 100.0, cost: 130.0)]);
      expect(pl.revenue, 600);
      expect(pl.cost, 530);
      expect(pl.profit, 70);
      expect(customerPL(bills: 1, items: [(amount: 10.0, cost: 30.0)]).profit, -20);
    });

    test('supplier summary ignores returned bills', () {
      final s = supplierSummary([bill('P1', 1000, 400, 1), bill('P2', 500, 500, 2, status: 'returned')]);
      expect(s.bills, 1);
      expect(s.purchased, 1000);
      expect(s.paid, 400);
      expect(s.due, 600);
    });
  });
}
