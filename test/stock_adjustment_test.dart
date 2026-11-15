import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/stock_adjustment_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

Product prod(String name, {double stock = 10, String barcode = 'b', String category = '', String tag = '', String unit = 'pcs'}) =>
    Product(barcode: barcode, name: name, stock: stock, category: category, searchTag: tag, unit: unit);

void main() {
  group('adjustmentDelta / adjustmentType', () {
    test('damage = negative', () => expect(adjustmentDelta(AdjustmentKind.damage, 3), -3));
    test('correction remove = negative', () => expect(adjustmentDelta(AdjustmentKind.correctionRemove, 3), -3));
    test('correction add = positive', () => expect(adjustmentDelta(AdjustmentKind.correctionAdd, 3), 3));
    test('type: damage => DAMAGE, baqi ADJUSTMENT', () {
      expect(adjustmentType(AdjustmentKind.damage), 'DAMAGE');
      expect(adjustmentType(AdjustmentKind.correctionAdd), 'ADJUSTMENT');
      expect(adjustmentType(AdjustmentKind.correctionRemove), 'ADJUSTMENT');
    });
  });

  group('validateAdjustment', () {
    final p = prod('Eggs', stock: 10);

    test('null / 0 / negative qty rad', () {
      expect(validateAdjustment(p, AdjustmentKind.damage, null), isNotNull);
      expect(validateAdjustment(p, AdjustmentKind.damage, 0), isNotNull);
      expect(validateAdjustment(p, AdjustmentKind.correctionAdd, -1), isNotNull);
    });

    test('theek qty manzoor', () {
      expect(validateAdjustment(p, AdjustmentKind.damage, 4), isNull);
      expect(validateAdjustment(p, AdjustmentKind.correctionAdd, 4), isNull);
    });

    test('poora stock nikalna manzoor (barabar)', () {
      expect(validateAdjustment(p, AdjustmentKind.damage, 10), isNull);
    });

    test('stock se zyada kam karna rad — damage aur correction-remove dono', () {
      expect(validateAdjustment(p, AdjustmentKind.damage, 11), isNotNull);
      expect(validateAdjustment(p, AdjustmentKind.correctionRemove, 11), isNotNull);
    });

    test('stock se zyada BADHANA rad nahi', () {
      expect(validateAdjustment(p, AdjustmentKind.correctionAdd, 500), isNull);
    });

    test('piece item mein fraction rad', () {
      expect(validateAdjustment(p, AdjustmentKind.damage, 1.5), isNotNull);
    });

    test('gram item mein fraction manzoor', () {
      final g = prod('Rice', stock: 1000, unit: 'Gram');
      expect(validateAdjustment(g, AdjustmentKind.damage, 250.5), isNull);
    });
  });

  group('searchProductsForAdjustment', () {
    final all = [
      prod('Basmati Rice', barcode: 'P100', category: 'Grocery'),
      prod('Sunlight Soap', barcode: 'P200', category: 'Cleaning', tag: 'sabun'),
    ];

    test('khali query = kuch nahi (browse nahi)', () {
      expect(searchProductsForAdjustment(all, ''), isEmpty);
      expect(searchProductsForAdjustment(all, '   '), isEmpty);
    });

    test('naam / category / barcode / searchTag', () {
      expect(searchProductsForAdjustment(all, 'rice').single.barcode, 'P100');
      expect(searchProductsForAdjustment(all, 'clean').single.barcode, 'P200');
      expect(searchProductsForAdjustment(all, 'p2').single.barcode, 'P200');
      expect(searchProductsForAdjustment(all, 'sabun').single.barcode, 'P200');
    });

    test('koi match nahi', () => expect(searchProductsForAdjustment(all, 'zzz'), isEmpty));
  });
}
