import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/bulk_rate_planner.dart';
import 'package:ah_developer_kiryana_store/utils/rate_list_export.dart';
import 'package:ah_developer_kiryana_store/utils/rate_margin.dart';

Product _p(String b, {double cost = 0, double wholesale = 0, double shopkeeper = 0, String cat = 'A'}) =>
    Product(barcode: b, name: b, category: cat, cost: cost, wholesalePrice: wholesale, shopkeeperPrice: shopkeeper);

void main() {
  group('isBelowCost', () {
    test('rate cost se kam', () => expect(isBelowCost(90, 100), isTrue));
    test('rate cost ke barabar/zyada', () {
      expect(isBelowCost(100, 100), isFalse);
      expect(isBelowCost(120, 100), isFalse);
    });
    test('cost ya rate 0 => warning nahi', () {
      expect(isBelowCost(50, 0), isFalse);
      expect(isBelowCost(0, 100), isFalse);
    });
  });

  group('planShopkeeperRates', () {
    test('wholesale minus %, rupay tak round', () {
      final plan = planShopkeeperRates(
        products: [_p('a', wholesale: 2420)],
        rule: BulkRateRule.percentOff,
        value: 2,
      );
      expect(plan.rows.single.newRate, 2372); // 2420 * 0.98 = 2371.6
      expect(plan.rows.single.baseRate, 2420);
    });

    test('Rs off, category filter', () {
      final plan = planShopkeeperRates(
        products: [_p('x', wholesale: 100, cat: 'A'), _p('y', wholesale: 200, cat: 'B')],
        rule: BulkRateRule.amountOff,
        value: 10,
        category: 'B',
      );
      expect(plan.rows.map((r) => r.product.barcode), ['y']);
      expect(plan.rows.single.newRate, 190);
    });

    test('wholesale 0 skip, pehle se set skip (onlyUnset), onlyUnset off to overwrite', () {
      final products = [_p('a'), _p('b', wholesale: 100, shopkeeper: 95), _p('c', wholesale: 100)];
      final plan = planShopkeeperRates(products: products, rule: BulkRateRule.percentOff, value: 5);
      expect(plan.rows.map((r) => r.product.barcode), ['c']);
      expect(plan.skippedNoBase, 1);
      expect(plan.skippedAlreadySet, 1);

      final all = planShopkeeperRates(products: products, rule: BulkRateRule.percentOff, value: 5, onlyUnset: false);
      expect(all.rows.map((r) => r.product.barcode), ['b', 'c']);
      expect(all.rows.first.oldRate, 95);
    });

    test('cost se kam rate par belowCost flag (rukta nahi)', () {
      final plan = planShopkeeperRates(
        products: [_p('a', cost: 99, wholesale: 100), _p('b', cost: 50, wholesale: 100)],
        rule: BulkRateRule.percentOff,
        value: 5, // 95
      );
      expect(plan.rows.length, 2);
      expect(plan.rows[0].belowCost, isTrue); // 95 < 99
      expect(plan.rows[1].belowCost, isFalse);
      expect(plan.belowCostCount, 1);
    });

    test('invalid input => khali plan', () {
      expect(planShopkeeperRates(products: [_p('a', wholesale: 100)], rule: BulkRateRule.percentOff, value: 0).rows, isEmpty);
      expect(planShopkeeperRates(products: [_p('a', wholesale: 100)], rule: BulkRateRule.percentOff, value: 100).rows, isEmpty);
    });
  });

  test('rate list export mein Shopkeeper Rate aakhri column', () {
    final csv = buildRateListCsv([
      Product(barcode: 'B1', name: 'Rice', unit: 'Kg', wholesalePrice: 100, salePrice: 120, shopkeeperPrice: 95),
      Product(barcode: 'B2', name: 'Salt', unit: 'Kg', wholesalePrice: 10, salePrice: 12),
    ]);
    final lines = csv.replaceFirst('\uFEFF', '').trim().split('\n');
    expect(lines.first.endsWith('Shopkeeper Rate'), isTrue);
    expect(lines[1].endsWith(',95'), isTrue);
    expect(lines[2].endsWith(','), isTrue); // set nahi => khali
  });
}
