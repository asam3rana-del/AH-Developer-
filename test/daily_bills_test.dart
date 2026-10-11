import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/daily_bills_repository.dart';
import 'package:ah_developer_kiryana_store/db/party_reports_repository.dart';

ReportBill bill(String id, double total, double paid, int t) =>
    ReportBill(id: id, total: total, paid: paid, createdAt: t);

void main() {
  const day = 1000;
  const end = 2000;

  test('pichla balance + aaj ki sales - aaj ki payment = aaj ka balance', () {
    final p = buildDailyParty(
      id: 1,
      name: 'Asad',
      openingPlusStuck: 100000,
      bills: [
        bill('old', 5000, 0, 500), // pichla din: balance +5000
        bill('S1', 1000, 0, 1100),
        bill('S2', 1500, 500, 1200),
      ],
      payments: [const ReportPayment(reference: 'manual-1', amount: 2000, createdAt: 1900)],
      dayStart: day,
      dayEnd: end,
    )!;
    expect(p.previousBalance, 105000);
    expect(p.salesTotal, 2500);
    expect(p.billCount, 2);
    expect(p.receivedTotal, 2500); // 500 bill mein + 2000 alag
    expect(p.closingBalance, 105000 + 1000 + 1000 - 2000);
  });

  test('us din kuch nahi to null; returned bill shamil nahi', () {
    expect(
        buildDailyParty(id: 1, name: 'A', openingPlusStuck: 0, bills: [bill('x', 10, 0, 50)], payments: const [], dayStart: day, dayEnd: end),
        isNull);
    final p = buildDailyParty(
      id: 1,
      name: 'A',
      openingPlusStuck: 0,
      bills: [
        const ReportBill(id: 'r', total: 999, paid: 0, createdAt: 1100, status: 'returned'),
        bill('ok', 100, 0, 1200),
      ],
      payments: const [],
      dayStart: day,
      dayEnd: end,
    )!;
    expect(p.billCount, 1);
    expect(p.closingBalance, 100);
  });

  test('text bill mein pichla balance aur aaj ka balance hai', () {
    final p = buildDailyParty(
      id: 1,
      name: 'Asad',
      openingPlusStuck: 50,
      bills: [bill('S1', 100, 0, 1100)],
      payments: const [],
      dayStart: day,
      dayEnd: end,
      itemsByInvoice: {
        'S1': [const DayBillItem(product: 'Rice', qty: 2, unit: 'kg', unitPrice: 50, amount: 100)],
      },
    )!;
    final t = dailyBillText(p, DateTime(2026, 10, 11));
    expect(t.contains('Pichla balance: Rs 50'), isTrue);
    expect(t.contains('Rice'), isTrue);
    expect(t.contains('Aaj ka balance: Rs 150'), isTrue);
  });
}
