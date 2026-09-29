import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/monthly_repository.dart';

int ms(int y, int m, int d) => DateTime(y, m, d, 12).millisecondsSinceEpoch;

void main() {
  final sales = [
    BillRow(1, ms(2026, 9, 3), 100),
    BillRow(2, ms(2026, 9, 20), 50),
    BillRow(1, ms(2026, 8, 5), 200),
    BillRow(null, ms(2025, 12, 31), 10), // walk-in
  ];
  final purchases = [
    BillRow(7, ms(2026, 9, 1), 80),
    BillRow(8, ms(2026, 7, 9), 500),
  ];

  group('selectEntries', () {
    test('koi filter nahi = sab bill totals', () {
      final r = selectEntries(allSales: sales, allPurchases: purchases);
      expect(sumAmounts(r.sales), 360);
      expect(sumAmounts(r.purchases), 580);
    });

    test('customer chuna => sirf uski sales, purchase side khali', () {
      final r = selectEntries(allSales: sales, allPurchases: purchases, party: const PartyOption(1, 'Ali', true));
      expect(sumAmounts(r.sales), 300);
      expect(r.purchases, isEmpty);
    });

    test('supplier chuna => sirf uski purchases, sale side khali', () {
      final r = selectEntries(allSales: sales, allPurchases: purchases, party: const PartyOption(7, 'Sup', false));
      expect(sumAmounts(r.purchases), 80);
      expect(r.sales, isEmpty);
    });

    test('customer id supplier id se nahi milti (alag side)', () {
      // customer id 7 ki koi sale nahi; supplier 7 ki purchase alag side par hai
      final r = selectEntries(allSales: sales, allPurchases: purchases, party: const PartyOption(7, 'X', true));
      expect(sumAmounts(r.sales), 0);
      expect(r.purchases, isEmpty);
    });

    test('item filter = qty * rate', () {
      final r = selectEntries(
        allSales: sales,
        allPurchases: purchases,
        itemSales: [ItemLine(1, ms(2026, 9, 3), 2, 30), ItemLine(2, ms(2026, 9, 4), 1, 15)],
        itemPurchases: [ItemLine(7, ms(2026, 9, 1), 10, 4)],
      );
      expect(sumAmounts(r.sales), 75);
      expect(sumAmounts(r.purchases), 40);
    });

    test('item + customer filter', () {
      final r = selectEntries(
        allSales: sales,
        allPurchases: purchases,
        itemSales: [ItemLine(1, ms(2026, 9, 3), 2, 30), ItemLine(2, ms(2026, 9, 4), 1, 15)],
        itemPurchases: [ItemLine(7, ms(2026, 9, 1), 10, 4)],
        party: const PartyOption(2, 'Bilal', true),
      );
      expect(sumAmounts(r.sales), 15);
      expect(r.purchases, isEmpty);
    });

    test('item hai magar us ki koi sale nahi => khali', () {
      final r = selectEntries(allSales: sales, allPurchases: purchases, itemSales: const [], itemPurchases: const []);
      expect(r.sales, isEmpty);
      expect(r.purchases, isEmpty);
    });
  });

  group('groupPeriods', () {
    final e = selectEntries(allSales: sales, allPurchases: purchases);

    test('mahine: naya pehle, dono taraf ki keys milti hain', () {
      final m = groupPeriods(e.sales, e.purchases, GroupMode.month);
      expect(m.map((x) => x.key).toList(), ['2026-09', '2026-08', '2026-07', '2025-12']);
      expect(m.first.sale, 150);
      expect(m.first.purchase, 80);
      expect(m.first.net, 70);
      // July mein sirf purchase
      expect(m[2].sale, 0);
      expect(m[2].purchase, 500);
      expect(m[2].net, -500);
    });

    test('mahine ka label', () {
      final m = groupPeriods(e.sales, e.purchases, GroupMode.month);
      expect(m.first.label, 'September 2026');
    });

    test('saal ke hisaab se', () {
      final y = groupPeriods(e.sales, e.purchases, GroupMode.year);
      expect(y.map((x) => x.key).toList(), ['2026', '2025']);
      expect(y.first.sale, 350);
      expect(y.first.purchase, 580);
      expect(y.first.label, '2026');
      expect(y.last.sale, 10);
    });

    test('khali input => khali list', () {
      expect(groupPeriods(const [], const [], GroupMode.month), isEmpty);
    });
  });
}
