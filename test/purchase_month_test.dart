import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/purchase_history_repository.dart';
import 'package:ah_developer_kiryana_store/utils/purchase_month.dart';

PurchaseHistoryRow row(String bill, DateTime at, double total) => PurchaseHistoryRow(
      billNo: bill,
      supplierName: 'Asim',
      total: total,
      paid: total,
      createdAt: at.millisecondsSinceEpoch,
      status: 'active',
    );

void main() {
  test('Groups bills by local month, newest month first, with count and total', () {
    final months = groupPurchasesByMonth([
      row('A1', DateTime(2026, 8, 1, 0, 5), 1000),
      row('A2', DateTime(2026, 8, 31, 23, 50), 500),
      row('S1', DateTime(2026, 9, 1, 0, 1), 200),
      row('J1', DateTime(2026, 7, 31, 23, 59), 50),
    ]);
    expect(months.map((m) => m.key).toList(), ['2026-09', '2026-08', '2026-07']);
    final aug = months[1];
    expect(aug.count, 2);
    expect(aug.total, 1500);
    expect(aug.rows.map((r) => r.billNo).toSet(), {'A1', 'A2'});
  });

  test('Same month in different years stays separate', () {
    final months = groupPurchasesByMonth([
      row('X', DateTime(2025, 8, 10), 1),
      row('Y', DateTime(2026, 8, 10), 1),
    ]);
    expect(months.map((m) => m.key).toList(), ['2026-08', '2025-08']);
  });

  test('No bills: no months', () {
    expect(groupPurchasesByMonth(const []), isEmpty);
  });
}
