import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/stock_report_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

Product prod(String name,
        {double stock = 0,
        double reorder = 0,
        double cost = 0,
        double sale = 0,
        String category = '',
        String barcode = 'b',
        String tag = '',
        String unit = 'pcs',
        String? secUnit,
        double secQty = 0}) =>
    Product(
      barcode: barcode,
      name: name,
      category: category,
      cost: cost,
      salePrice: sale,
      stock: stock,
      reorderLevel: reorder,
      unit: unit,
      secondaryUnit: secUnit ?? '',
      secondaryUnitQty: secQty,
      searchTag: tag,
    );

void main() {
  group('value per smallest unit', () {
    test('ek unit wala product: rate seedha', () {
      final p = prod('Salt', stock: 10, cost: 20, sale: 25);
      expect(costPerSmallestUnit(p), 20);
      expect(stockCostValue(p), 200);
    });

    test('dozen (12 pcs): cost dozen ka hai, stock pcs mein', () {
      // cost Rs 120 / dozen, stock 24 pcs => 24 * 10 = 240 (24 * 120 nahi)
      final p = prod('Eggs', stock: 24, cost: 120, sale: 144, unit: 'dozen', secUnit: 'pcs', secQty: 12);
      expect(p.smallestUnitFactor(), 12);
      expect(costPerSmallestUnit(p), 10);
      expect(salePerSmallestUnit(p), 12);
      expect(stockCostValue(p), 240);
    });
  });

  group('isLowStock', () {
    test('stock <= reorderLevel', () {
      expect(isLowStock(prod('a', stock: 5, reorder: 5)), true);
      expect(isLowStock(prod('a', stock: 4, reorder: 5)), true);
      expect(isLowStock(prod('a', stock: 6, reorder: 5)), false);
    });

    test('reorderLevel 0 par sirf stock 0 low', () {
      expect(isLowStock(prod('a', stock: 0, reorder: 0)), true);
      expect(isLowStock(prod('a', stock: 1, reorder: 0)), false);
    });
  });

  test('summarizeStock', () {
    final s = summarizeStock([
      prod('a', stock: 10, reorder: 2, cost: 10, sale: 15),
      prod('b', stock: 1, reorder: 2, cost: 100, sale: 130),
    ]);
    expect(s.totalProducts, 2);
    expect(s.lowStockCount, 1);
    expect(s.costValue, 200);
    expect(s.saleValue, 280);
  });

  group('filterStock', () {
    final items = [
      prod('Basmati Rice', category: 'Grains', barcode: '111', tag: 'chawal', stock: 1, reorder: 5),
      prod('Sugar', category: 'Sweet', barcode: '222', stock: 50, reorder: 5),
    ];

    test('khali query = sab', () => expect(filterStock(items, '  ').length, 2));
    test('naam', () => expect(filterStock(items, 'rice').single.name, 'Basmati Rice'));
    test('searchTag', () => expect(filterStock(items, 'chawal').single.name, 'Basmati Rice'));
    test('category', () => expect(filterStock(items, 'sweet').single.name, 'Sugar'));
    test('barcode', () => expect(filterStock(items, '222').single.name, 'Sugar'));
    test('low only', () => expect(filterStock(items, '', lowOnly: true).single.name, 'Basmati Rice'));
    test('low only + query', () => expect(filterStock(items, 'sugar', lowOnly: true), isEmpty));
  });
}
