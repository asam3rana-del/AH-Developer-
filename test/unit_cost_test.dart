import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/unit_cost.dart';
import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart';

/// Cost per smallest unit ek hi jagah (unit_cost.dart) se — carton/dozen wale items par
/// cost kabhi factor guna ziyada nahi aani chahiye.
void main() {
  group('costPerSmallestOf', () {
    test('primary-unit cost is divided by the smallest-unit factor', () {
      expect(costPerSmallestOf(1200, 12), 100);
      expect(costPerSmallestOf(194000, 1000), 194);
    });

    test('factor 1 keeps the cost; factor <= 0 or NaN falls back to the raw cost', () {
      expect(costPerSmallestOf(50, 1), 50);
      expect(costPerSmallestOf(50, 0), 50);
      expect(costPerSmallestOf(50, -3), 50);
      expect(costPerSmallestOf(50, double.nan), 50);
    });

    test('a broken cost (NaN / infinite / negative) never reaches a bill: it is 0', () {
      expect(costPerSmallestOf(double.nan, 12), 0);
      expect(costPerSmallestOf(double.infinity, 12), 0);
      expect(costPerSmallestOf(-5, 12), 0);
    });
  });

  test('purchase / reverse-purchase cost maths still agree with the helper', () {
    // 10 smallest in stock at cost 100 per carton of 10 (=10 each); buy 10 more for 200 (=20 each) => avg 15 each => 150 per carton.
    final c = addPurchaseLineCost(
        productCost: 100, productStock: 10, factor: 10, addedSmallestQty: 10, lineAmount: 200);
    expect(c, closeTo(150, 1e-9));
  });
}
