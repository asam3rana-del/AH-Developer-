import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/stock_movement.dart';

Product prod(String name, {String barcode = 'b', String category = '', String tag = ''}) =>
    Product(barcode: barcode, name: name, category: category, searchTag: tag);

StockMovement mv(String type, double qty, {int at = 0}) =>
    StockMovement(barcode: 'b', type: type, qty: qty, createdAt: at);

void main() {
  group('StockMovement map', () {
    test('toMap/fromMap round trip', () {
      const m = StockMovement(
        id: 7,
        barcode: 'P1',
        type: MovementType.purchase,
        qty: 24,
        unit: 'pcs',
        cost: 120.5,
        reference: 'PUR-1',
        note: 'x',
        createdAt: 1000,
        serverId: 'stock_movement:7',
        updatedAt: 1001,
        dirty: false,
      );
      final back = StockMovement.fromMap(m.toMap());
      expect(back.id, 7);
      expect(back.barcode, 'P1');
      expect(back.type, 'PURCHASE');
      expect(back.qty, 24);
      expect(back.unit, 'pcs');
      expect(back.cost, 120.5);
      expect(back.reference, 'PUR-1');
      expect(back.serverId, 'stock_movement:7');
      expect(back.dirty, false);
    });

    test('id null ho to map mein id nahi (autoincrement)', () {
      expect(mv('SALE', -1).toMap().containsKey('id'), false);
    });

    test('fromMap: khali/null columns ke default', () {
      final m = StockMovement.fromMap({'barcode': 'b', 'type': 'SALE', 'qty': -2, 'createdAt': 5});
      expect(m.unit, '');
      expect(m.cost, 0);
      expect(m.reference, '');
      expect(m.dirty, true);
    });
  });

  group('cost history types', () {
    test('sirf purchase-wali + opening cost hila sakti hain', () {
      for (final t in ['PURCHASE', 'PURCHASE_EDIT', 'PURCHASE_REVERSAL', 'PURCHASE_ITEM_DELETE', 'OPENING_STOCK']) {
        expect(isCostAffecting(t), true, reason: t);
      }
    });

    test('sale / return / adjustment cost nahi badalti', () {
      for (final t in ['SALE', 'SALE_EDIT', 'SALE_REVERSAL', 'PURCHASE_RETURN', 'DAMAGE', 'ADJUSTMENT', 'STOCK_TAKE']) {
        expect(isCostAffecting(t), false, reason: t);
      }
    });
  });

  group('formatMovementQty', () {
    test('poora number integer ki tarah', () {
      expect(formatMovementQty(24), '24');
      expect(formatMovementQty(-3), '-3');
      expect(formatMovementQty(0), '0');
    });

    test('3 decimal tak round', () {
      expect(formatMovementQty(1.5), '1.5');
      expect(formatMovementQty(0.12349), '0.123');
      expect(formatMovementQty(2.0004), '2');
    });
  });

  group('ledgerSum', () {
    test('signed qty ka jod: opening + purchase - sale', () {
      final list = [mv('OPENING_STOCK', 10), mv('PURCHASE', 24), mv('SALE', -6), mv('SALE_REVERSAL', 2)];
      expect(ledgerSum(list), 30);
    });

    test('khali list = 0', () => expect(ledgerSum(const []), 0));
  });

  group('filterMovementProducts', () {
    final all = [
      prod('Basmati Rice', barcode: 'P100', category: 'Grocery'),
      prod('Sunlight Soap', barcode: 'P200', category: 'Cleaning', tag: 'sabun'),
    ];

    test('query khali = sab', () => expect(filterMovementProducts(all, '  ').length, 2));

    test('naam se', () => expect(filterMovementProducts(all, 'rice').single.barcode, 'P100'));

    test('category se', () => expect(filterMovementProducts(all, 'clean').single.barcode, 'P200'));

    test('barcode se', () => expect(filterMovementProducts(all, 'p2').single.barcode, 'P200'));

    test('searchTag se', () => expect(filterMovementProducts(all, 'sabun').single.barcode, 'P200'));

    test('koi match nahi', () => expect(filterMovementProducts(all, 'zzz'), isEmpty));
  });
}
