import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/stock_audit_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

Product prod(String name, String barcode, double stock, {String tag = ''}) =>
    Product(barcode: barcode, name: name, stock: stock, searchTag: tag);

void main() {
  group('buildAuditRows', () {
    test('match karne wale products list mein nahi aate', () {
      final rows = buildAuditRows([prod('Salt', 'a', 10)], {'a': 10});
      expect(rows, isEmpty);
    });

    test('farq: stock ledger se zyada => diff +ve', () {
      final rows = buildAuditRows([prod('Salt', 'a', 12)], {'a': 10});
      expect(rows.single.diff, 2);
      expect(rows.single.ledgerStock, 10);
    });

    test('farq: stock ledger se kam => diff -ve', () {
      final rows = buildAuditRows([prod('Salt', 'a', 7)], {'a': 10});
      expect(rows.single.diff, -3);
    });

    test('ledger mein row hi nahi => ledger stock 0, poora stock farq', () {
      final rows = buildAuditRows([prod('Rice', 'r', 5)], {});
      expect(rows.single.ledgerStock, 0);
      expect(rows.single.diff, 5);
    });

    test('stock 0 aur ledger mein kuch nahi => mismatch nahi', () {
      expect(buildAuditRows([prod('New', 'n', 0)], {}), isEmpty);
    });

    test('epsilon (0.01) ke andar ka farq nazar-andaaz', () {
      expect(buildAuditRows([prod('A', 'a', 10.005)], {'a': 10}), isEmpty);
      expect(buildAuditRows([prod('A', 'a', 10.02)], {'a': 10}), hasLength(1));
    });

    test('sab se bara |farq| pehle', () {
      final rows = buildAuditRows(
        [prod('Small', 's', 11), prod('Big', 'b', 0), prod('Mid', 'm', 14)],
        {'s': 10, 'b': 20, 'm': 10},
      );
      expect(rows.map((r) => r.product.barcode).toList(), ['b', 'm', 's']);
    });
  });

  group('filterAuditRows', () {
    final rows = buildAuditRows(
      [prod('Basmati Rice', 'r', 5, tag: 'chawal'), prod('Sugar', 's', 3)],
      {},
    );

    test('query khali = sab', () => expect(filterAuditRows(rows, ' ').length, 2));
    test('naam se', () => expect(filterAuditRows(rows, 'rice').single.product.barcode, 'r'));
    test('searchTag se', () => expect(filterAuditRows(rows, 'chawal').single.product.barcode, 'r'));
    test('koi match nahi', () => expect(filterAuditRows(rows, 'zzz'), isEmpty));
  });
}
