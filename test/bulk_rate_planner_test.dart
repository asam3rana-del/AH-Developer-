import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/bulk_rate_planner.dart';

Product _p(String b, {double sale = 0, double wholesale = 0, double bulk = 0, double bulkQty = 0, String cat = 'A'}) =>
    Product(barcode: b, name: b, category: cat, salePrice: sale, wholesalePrice: wholesale, bulkPrice: bulk, bulkMinQty: bulkQty);

void main() {
  test('percent off retail, rounds to rupee', () {
    final plan = planBulkRates(
      products: [_p('a', sale: 2420)],
      target: BulkRateTarget.retail,
      minQty: 10,
      rule: BulkRateRule.percentOff,
      value: 2,
    );
    expect(plan.rows.single.newBulkPrice, 2372);
    expect(plan.rows.single.newMinQty, 10);
  });

  test('skips zero base, already set, and invalid result', () {
    final plan = planBulkRates(
      products: [_p('nobase'), _p('set', sale: 100, bulk: 90, bulkQty: 5), _p('big', sale: 50)],
      target: BulkRateTarget.retail,
      minQty: 5,
      rule: BulkRateRule.amountOff,
      value: 60,
    );
    expect(plan.rows, isEmpty);
    expect(plan.skippedNoBase, 1);
    expect(plan.skippedAlreadySet, 1);
    expect(plan.skippedInvalid, 1);
  });

  test('wholesale uses wholesale fields and category filter', () {
    final plan = planBulkRates(
      products: [_p('x', wholesale: 200, cat: 'A'), _p('y', wholesale: 200, cat: 'B')],
      target: BulkRateTarget.wholesale,
      minQty: 3,
      rule: BulkRateRule.amountOff,
      value: 10,
      category: 'B',
    );
    expect(plan.rows.map((r) => r.product.barcode), ['y']);
    expect(plan.rows.single.newBulkPrice, 190);
  });

  test('clear plan only picks products with bulk set', () {
    final plan = planClearBulkRates(
      products: [_p('a', sale: 10), _p('b', sale: 10, bulk: 9, bulkQty: 2)],
      target: BulkRateTarget.retail,
    );
    expect(plan.rows.map((r) => r.product.barcode), ['b']);
    expect(plan.rows.single.newBulkPrice, 0);
  });

  test('invalid input gives empty plan', () {
    final plan = planBulkRates(
      products: [_p('a', sale: 100)],
      target: BulkRateTarget.retail,
      minQty: 0,
      rule: BulkRateRule.percentOff,
      value: 5,
    );
    expect(plan.rows, isEmpty);
  });
}
