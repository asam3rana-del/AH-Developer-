import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/inventory_insights_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/stock_movement.dart';

Product prod(String name,
        {double stock = 10, String barcode = 'b', double reorder = 0, double cost = 0, double sale = 0, String unit = 'pcs'}) =>
    Product(barcode: barcode, name: name, stock: stock, reorderLevel: reorder, cost: cost, salePrice: sale, unit: unit);

StockMovement dmg(String barcode, double qty, double cost) =>
    StockMovement(barcode: barcode, type: 'DAMAGE', qty: qty, unit: 'pcs', cost: cost, createdAt: 1);

void main() {
  group('reorderCandidates / suggestedReorderQty', () {
    test('stock <= level aur level > 0, naam ke hisaab se', () {
      final all = [
        prod('Zeera', barcode: 'z', stock: 2, reorder: 5),
        prod('Atta', barcode: 'a', stock: 5, reorder: 5), // barabar = low
        prod('Chawal', barcode: 'c', stock: 9, reorder: 5), // theek
        prod('NoLevel', barcode: 'n', stock: 0, reorder: 0), // level set nahi
      ];
      expect(reorderCandidates(all).map((p) => p.barcode), ['a', 'z']);
    });

    test('tajweez = level ka double - stock', () {
      expect(suggestedReorderQty(prod('x', stock: 2, reorder: 5)), 8);
    });

    test('stock level ke barabar: double - stock = level', () {
      expect(suggestedReorderQty(prod('x', stock: 5, reorder: 5)), 5);
    });

    test('stock zero', () => expect(suggestedReorderQty(prod('x', stock: 0, reorder: 5)), 10));
  });

  group('damageLossValue', () {
    test('single unit: |qty| * cost', () {
      expect(damageLossValue(dmg('a', -3, 20), prod('A', barcode: 'a')), 60);
    });

    test('product delete ho gaya: raw cost', () {
      expect(damageLossValue(dmg('gone', -2, 7), null), 14);
    });

    test('totalDamageLoss jodta hai', () {
      final products = {'a': prod('A', barcode: 'a')};
      expect(totalDamageLoss([dmg('a', -1, 10), dmg('a', -2, 10)], products), 30);
    });

    test('khali list = 0', () => expect(totalDamageLoss(const [], const {}), 0));
  });

  group('margin', () {
    test('marginPercent', () {
      expect(marginPercent(prod('x', cost: 80, sale: 100)), 20);
      expect(marginPercent(prod('x', cost: 120, sale: 100)), -20);
    });

    test('sale <= 0 par 0', () => expect(marginPercent(prod('x', cost: 50, sale: 0)), 0));

    test('pricedProducts sirf salePrice > 0', () {
      expect(pricedProducts([prod('a', sale: 0), prod('b', sale: 5)]).map((p) => p.name), ['b']);
    });

    test('averageMargin / lowMarginCount', () {
      final priced = [prod('a', cost: 95, sale: 100), prod('b', cost: 50, sale: 100), prod('c', cost: 91, sale: 100)];
      expect(averageMargin(priced), closeTo((5 + 50 + 9) / 3, 1e-9));
      expect(lowMarginCount(priced), 2);
      expect(averageMargin(const []), 0);
    });

    test('sortByMarginAsc: kam margin pehle, barabar par asal order', () {
      final a = prod('a', barcode: 'a', cost: 50, sale: 100);
      final b = prod('b', barcode: 'b', cost: 90, sale: 100);
      final c = prod('c', barcode: 'c', cost: 50, sale: 100);
      expect(sortByMarginAsc([a, b, c]).map((p) => p.barcode), ['b', 'a', 'c']);
    });

    test('marginBand: <10 red, <25 amber, warna teal', () {
      expect(marginBand(9.9), 0);
      expect(marginBand(10), 1);
      expect(marginBand(24.9), 1);
      expect(marginBand(25), 2);
    });
  });

  group('movers', () {
    final products = [
      prod('A', barcode: 'a'),
      prod('B', barcode: 'b'),
      prod('C', barcode: 'c'),
      prod('D', barcode: 'd'),
    ];
    final rows = buildMovementRows(products, {
      'a': (qty: 5, amount: 500),
      'b': (qty: 20, amount: 900),
      'c': (qty: 5, amount: 100),
    });

    test('har product ki row, bikri na ho to 0', () {
      expect(rows.length, 4);
      expect(rows.last.qty, 0);
      expect(rows.last.amount, 0);
    });

    test('fast: qty ghatti hui, qty > 0 sirf, barabar par asal order', () {
      expect(fastMovers(rows).map((r) => r.barcode), ['b', 'a', 'c']);
    });

    test('slow: zero pehle', () {
      expect(slowMovers(rows).map((r) => r.barcode), ['d', 'a', 'c', 'b']);
    });

    test('limit', () {
      expect(fastMovers(rows, limit: 2).map((r) => r.barcode), ['b', 'a']);
      expect(slowMovers(rows, limit: 1).single.barcode, 'd');
    });

    test('koi bikri nahi: fast khali, slow phir bhi dikhta hai', () {
      final none = buildMovementRows(products, const {});
      expect(fastMovers(none), isEmpty);
      expect(slowMovers(none).length, 4);
      expect(totalUnitsSold(none), 0);
    });

    test('totalUnitsSold', () => expect(totalUnitsSold(rows), 30));
  });

  group('mergeItemHistory', () {
    test('sale + purchase mila kar naya pehle', () {
      final sales = [ItemHistoryRow(true, 'Ali', 1, 'pcs', 10, 100), ItemHistoryRow(true, 'Walk-in', 2, 'pcs', 10, 300)];
      final purchases = [ItemHistoryRow(false, 'Sup', 50, 'pcs', 7, 200)];
      final m = mergeItemHistory(sales, purchases);
      expect(m.map((r) => r.createdAt), [300, 200, 100]);
      expect(m[1].isSale, isFalse);
    });

    test('khali', () => expect(mergeItemHistory(const [], const []), isEmpty));
  });
}
