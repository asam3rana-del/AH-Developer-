import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/stock_taking_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

Product prod(String name,
        {double stock = 10, String barcode = 'b', String category = '', String tag = '', String unit = 'pcs', double cost = 0}) =>
    Product(barcode: barcode, name: name, stock: stock, category: category, searchTag: tag, unit: unit, cost: cost);

void main() {
  group('formatStockTakeQty', () {
    test('poora number integer', () => expect(formatStockTakeQty(5), '5'));
    test('fraction 2 decimal', () => expect(formatStockTakeQty(2.5), '2.50'));
    test('manfi', () => expect(formatStockTakeQty(-3), '-3'));
  });

  group('stockTakeValueImpact', () {
    test('single unit: delta * cost', () {
      expect(stockTakeValueImpact(prod('Eggs', cost: 20), 3), 60);
      expect(stockTakeValueImpact(prod('Eggs', cost: 20), -2), -40);
    });
  });

  group('countedItems', () {
    test('sirf number wali entries', () {
      expect(countedItems({'a': '5', 'b': '', 'c': 'abc', 'd': ' 2.5 ', 'e': '0'}), 3);
    });
    test('khali map', () => expect(countedItems({}), 0));
  });

  group('validateCount', () {
    final p = prod('Eggs');
    test('null (gina nahi) theek', () => expect(validateCount(p, null), isNull));
    test('0 theek — asal gintee zero', () => expect(validateCount(p, 0), isNull));
    test('manfi rad', () => expect(validateCount(p, -1), isNotNull));
    test('piece item mein fraction rad', () => expect(validateCount(p, 1.5), isNotNull));
    test('poori gintee theek', () => expect(validateCount(p, 8), isNull));
  });

  group('buildVariances', () {
    final eggs = prod('Eggs', barcode: 'e', stock: 10);
    final milk = prod('Milk', barcode: 'm', stock: 5);
    final latest = {'e': eggs, 'm': milk};

    test('farq wali line banti hai, delta = counted - system', () {
      final v = buildVariances({'e': '8'}, latest);
      expect(v.length, 1);
      expect(v.first.delta, -2);
      expect(v.first.counted, 8);
    });

    test('barabar gintee = koi variance nahi', () {
      expect(buildVariances({'e': '10', 'm': '5'}, latest), isEmpty);
    });

    test('khali / non-number / unknown barcode chhod diye jate hain', () {
      expect(buildVariances({'e': '', 'm': 'x', 'zzz': '4'}, latest), isEmpty);
    });

    test('0 gintee = asal variance (stock -> 0)', () {
      final v = buildVariances({'m': '0'}, latest);
      expect(v.single.delta, -5);
    });

    test('order entry ka order; barhta hua delta +ve', () {
      final v = buildVariances({'m': '9', 'e': '7'}, latest);
      expect(v.map((x) => x.product.barcode), ['m', 'e']);
      expect(v.first.delta, 4);
    });

    test('bohot chhota farq (<= 0.0001) nazar-andaz', () {
      expect(buildVariances({'e': '10.00005'}, latest), isEmpty);
    });
  });

  group('firstInvalidCount', () {
    final latest = {'e': prod('Eggs', barcode: 'e')};
    test('manfi', () => expect(firstInvalidCount({'e': '-2'}, latest), isNotNull));
    test('theek', () => expect(firstInvalidCount({'e': '3'}, latest), isNull));
    test('unknown barcode ignore', () => expect(firstInvalidCount({'x': '-2'}, latest), isNull));
  });

  group('filterStockTakeProducts', () {
    final all = [
      prod('Basmati Rice', barcode: '111', category: 'Grain'),
      prod('Sugar', barcode: '222', category: 'Sweet', tag: 'cheeni'),
    ];
    test('khali query = sab', () => expect(filterStockTakeProducts(all, '  ').length, 2));
    test('naam', () => expect(filterStockTakeProducts(all, 'rice').single.name, 'Basmati Rice'));
    test('category', () => expect(filterStockTakeProducts(all, 'sweet').single.name, 'Sugar'));
    test('barcode', () => expect(filterStockTakeProducts(all, '222').single.name, 'Sugar'));
    test('searchTag', () => expect(filterStockTakeProducts(all, 'cheeni').single.name, 'Sugar'));
  });

  group('session id / notes / summary', () {
    test('stockTakeSessionId format', () {
      expect(stockTakeSessionId(DateTime(2026, 9, 29, 3, 7, 5)), 'ST260929030705');
    });

    test('line note', () {
      expect(stockTakeLineNote(10, 8, ''), 'system=10 counted=8');
      expect(stockTakeLineNote(10, 8.5, ' shelf 2 '), 'system=10 counted=8.50 — shelf 2');
    });

    test('summary: 15 line cap + more + total', () {
      final vs = [
        for (var i = 0; i < 17; i++)
          StockTakeVariance(prod('P$i', barcode: 'b$i', stock: 10, cost: 2), 9, -1),
      ];
      final s = stockTakeSummaryText(vs, header: 'item(s) have a variance:', impactLabel: 'Estimated value impact:');
      expect(s.startsWith('17 item(s) have a variance:'), isTrue);
      expect(s.contains('P14: 10 \u2192 9 (-1)'), isTrue);
      expect(s.contains('P15'), isFalse);
      expect(s.contains('… +2 more'), isTrue);
      expect(s.contains('Estimated value impact: Rs.-34'), isTrue);
    });

    test('summary: + sign for increase', () {
      final s = stockTakeSummaryText([StockTakeVariance(prod('Eggs', stock: 4), 6, 2)], header: 'h', impactLabel: 'i');
      expect(s.contains('Eggs: 4 \u2192 6 (+2)'), isTrue);
    });
  });
}
