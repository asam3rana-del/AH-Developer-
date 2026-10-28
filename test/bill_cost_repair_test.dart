import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/bill_cost_repair_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

void main() {
  group('isSuspiciousLineCost', () {
    test('cost sale se bohat zyada = shak', () {
      expect(isSuspiciousLineCost(194000, 45786), isTrue);
    });
    test('normal margin = theek', () {
      expect(isSuspiciousLineCost(900, 1000), isFalse);
      expect(isSuspiciousLineCost(1000, 1000), isFalse);
    });
    test('thora loss (1.5x se kam) shak nahi', () {
      expect(isSuspiciousLineCost(1400, 1000), isFalse);
    });
    test('chhoti raqam par rounding shor nahi', () {
      expect(isSuspiciousLineCost(30, 10), isFalse);
    });
    test('cost 0 ya nan shak nahi', () {
      expect(isSuspiciousLineCost(0, 100), isFalse);
      expect(isSuspiciousLineCost(double.nan, 100), isFalse);
    });
  });

  group('repairedLineCost', () {
    // Outer (primary) = 10 dabbi; cost per outer Rs 2360.
    final p = Product(
      barcode: 'c',
      name: 'Capstan',
      stock: 0,
      cost: 2360,
      salePrice: 2500,
      unit: 'outer',
      secondaryUnit: 'dabbi',
      secondaryUnitQty: 10,
    );

    test('1 outer = poori cost', () {
      expect(repairedLineCost(p, 1, 'outer', 10), 2360);
    });
    test('3 dabbi = 3/10 cost', () {
      expect(repairedLineCost(p, 3, 'dabbi', 1), 708);
    });
    test('stored factor 0 ho to ladder se', () {
      expect(repairedLineCost(p, 1, 'outer', 0), 2360);
    });
  });
}
