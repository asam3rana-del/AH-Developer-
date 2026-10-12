import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/daily_bills_repository.dart';
import 'package:ah_developer_kiryana_store/db/party_reports_repository.dart';
import 'package:ah_developer_kiryana_store/db/rent_repository.dart';

void main() {
  test('rent invoice: ek din + ek customer = ek hi invoice', () {
    expect(rentInvoice(5, DateTime(2026, 10, 2)), 'RENT-20261002-5');
    expect(isRentInvoice('RENT-20261002-5'), isTrue);
    expect(isRentInvoice('1026123456'), isFalse);
  });

  test('missingRentDays: shuru din se aaj tak sab din (dono shamil)', () {
    final d = missingRentDays(
        start: DateTime(2026, 10, 10), today: DateTime(2026, 10, 12), customerId: 1, existing: const {});
    expect(d, [DateTime(2026, 10, 10), DateTime(2026, 10, 11), DateTime(2026, 10, 12)]);
  });

  test('missingRentDays: bana hua (ya chhutti wala returned) din dobara nahi banta', () {
    final d = missingRentDays(
      start: DateTime(2026, 10, 10),
      today: DateTime(2026, 10, 12),
      customerId: 1,
      existing: {rentInvoice(1, DateTime(2026, 10, 10)), rentInvoice(1, DateTime(2026, 10, 11))},
    );
    expect(d, [DateTime(2026, 10, 12)]);
  });

  test('missingRentDays: mahine ki hadd paar karta hai, aur shuru aaj ke baad ho to kuch nahi', () {
    final d = missingRentDays(
        start: DateTime(2026, 10, 30), today: DateTime(2026, 11, 2), customerId: 1, existing: const {});
    expect(d.length, 4);
    expect(d.last, DateTime(2026, 11, 2));
    expect(missingRentDays(start: DateTime(2026, 10, 13), today: DateTime(2026, 10, 12), customerId: 1, existing: const {}),
        isEmpty);
  });

  test('Daily Bill: rent bill "Daily Rent" item ke saath dikhta hai aur balance mein judta hai', () {
    final day = DateTime(2026, 10, 12);
    final s = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final e = DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch;
    final p = buildDailyParty(
      id: 1,
      name: 'Service',
      opening: 0,
      bills: [
        ReportBill(id: rentInvoice(1, DateTime(2026, 10, 11)), total: 150, paid: 0, createdAt: s - 86400000 + 1000),
        ReportBill(id: rentInvoice(1, day), total: 150, paid: 0, createdAt: s + 1000),
      ],
      payments: const [],
      dayStart: s,
      dayEnd: e,
    )!;
    expect(p.previousBalance, 150);
    expect(p.billCount, 1);
    expect(p.bills.first.items.single.product, 'Daily Rent');
    expect(p.closingBalance, 300);
  });

  test('Chhutti: returned rent bill balance aur Daily Bill se bahar', () {
    final day = DateTime(2026, 10, 12);
    final s = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final e = DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch;
    final p = buildDailyParty(
      id: 1,
      name: 'Service',
      opening: 0,
      bills: [ReportBill(id: rentInvoice(1, day), total: 150, paid: 0, createdAt: s + 1000, status: 'returned')],
      payments: const [],
      dayStart: s,
      dayEnd: e,
    );
    expect(p, isNull);
  });
}
