import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/sale.dart';
import 'package:ah_developer_kiryana_store/services/sale_draft.dart';
import 'package:ah_developer_kiryana_store/utils/bill_text.dart';
import 'package:ah_developer_kiryana_store/utils/sale_cart.dart';
import 'package:ah_developer_kiryana_store/utils/stock_touch_policy.dart';

// 1 Carton = 4 Dozen = 48 Pcs. Primary rate Rs 600 / Carton.
const _juice = Product(
  barcode: 'b3',
  name: 'Juice',
  unit: 'Carton',
  secondaryUnit: 'Dozen',
  secondaryUnitQty: 4,
  tertiaryUnit: 'Pcs',
  tertiaryUnitQty: 12,
  cost: 480,
  salePrice: 600,
  wholesalePrice: 540,
  stock: 480,
);

SaleLine _line(String barcode, double qty, String unit, double price) => SaleLine(
      itemName: barcode,
      barcode: barcode,
      qty: qty,
      unit: unit,
      unitPrice: price,
      cost: 0,
      amount: qty * price,
    );

SaleItem _item(String barcode, double qty, String unit, double price, {double factor = 0}) => SaleItem(
      invoice: 'INV1',
      barcode: barcode,
      product: barcode,
      qty: qty,
      unit: unit,
      unitPrice: price,
      cost: 0,
      amount: qty * price,
      conversionFactor: factor,
    );

void main() {
  group('saleEditDiff (edit only touches stock of changed lines)', () {
    test('nothing edited -> nothing reversed, nothing re-deducted', () {
      final d = saleEditDiff(
        [_line('a', 2, 'Pcs', 10), _line('b', 1, 'Dozen', 50)],
        [_item('a', 2, 'Pcs', 10), _item('b', 1, 'Dozen', 50)],
      );
      expect(d.itemsToReverse, isEmpty);
      expect(d.changedLineIndices, isEmpty);
      expect(d.unchangedOriginalByIndex.keys, {0, 1});
    });

    test('one qty changed -> only that original row is reversed', () {
      final d = saleEditDiff(
        [_line('a', 3, 'Pcs', 10), _line('b', 1, 'Dozen', 50)],
        [_item('a', 2, 'Pcs', 10), _item('b', 1, 'Dozen', 50)],
      );
      expect(d.changedLineIndices, {0});
      expect(d.itemsToReverse.map((e) => e.barcode), ['a']);
      expect(d.unchangedOriginalByIndex.keys, {1});
    });

    test('added line is changed; removed original row is reversed', () {
      final d = saleEditDiff(
        [_line('a', 2, 'Pcs', 10), _line('c', 1, 'Pcs', 5)],
        [_item('a', 2, 'Pcs', 10), _item('b', 1, 'Pcs', 7)],
      );
      expect(d.changedLineIndices, {1});
      expect(d.itemsToReverse.map((e) => e.barcode), ['b']);
    });

    test('two identical lines are paired one-to-one', () {
      final d = saleEditDiff(
        [_line('a', 1, 'Pcs', 10), _line('a', 1, 'Pcs', 10)],
        [_item('a', 1, 'Pcs', 10)],
      );
      expect(d.unchangedOriginalByIndex.length, 1);
      expect(d.changedLineIndices.length, 1);
      expect(d.itemsToReverse, isEmpty);
    });

    test('rate change counts as changed', () {
      final d = saleEditDiff([_line('a', 2, 'Pcs', 12)], [_item('a', 2, 'Pcs', 10)]);
      expect(d.changedLineIndices, {0});
      expect(d.itemsToReverse.length, 1);
    });
  });

  group('saleItemSmallestQty (frozen conversion factor)', () {
    test('uses the factor frozen at sale time, not the current ladder', () {
      // Sold 2 Dozen when 1 Dozen was 10 Pcs; ladder now says 12.
      expect(saleItemSmallestQty(_item('b3', 2, 'Dozen', 50, factor: 10), _juice), 20);
    });

    test('old row without a factor falls back to the current ladder', () {
      expect(saleItemSmallestQty(_item('b3', 2, 'Dozen', 50), _juice), 24);
    });

    test('blank stored unit means the primary unit', () {
      expect(saleItemSmallestQty(_item('b3', 1, '', 600), _juice), 48);
    });

    test('product gone and no factor -> qty as-is', () {
      expect(saleItemSmallestQty(_item('x', 5, 'Pcs', 1), null), 5);
    });
  });

  group('Rs (amount) mode', () {
    test('qty is amount / rate rounded to 3 decimals', () {
      expect(qtyFromAmount(100, 30), 3.333);
      expect(qtyFromAmount(150, 50), 3.0);
    });

    test('missing amount or rate gives null', () {
      expect(qtyFromAmount(0, 30), isNull);
      expect(qtyFromAmount(100, 0), isNull);
      expect(qtyFromAmount(-5, 30), isNull);
    });
  });

  group('customerRateFor', () {
    test('last rate per Dozen becomes the same rate per Dozen', () {
      final s = customerRateFor(_juice, lastUnitPrice: 50, lastUnit: 'Dozen', chosenUnit: 'Dozen');
      expect(s, isNotNull);
      expect(s!.primaryRate, closeTo(200, 1e-9)); // Rs 200 / Carton
      expect(s.priceInChosenUnit, closeTo(50, 1e-9));
    });

    test('is re-expressed when another unit is chosen', () {
      final s = customerRateFor(_juice, lastUnitPrice: 50, lastUnit: 'Dozen', chosenUnit: 'Pcs');
      expect(s!.priceInChosenUnit, closeTo(200 / 48, 1e-9));
    });

    test('blank last unit means the primary unit', () {
      final s = customerRateFor(_juice, lastUnitPrice: 550, lastUnit: '', chosenUnit: 'Carton');
      expect(s!.primaryRate, 550);
      expect(s.priceInChosenUnit, 550);
    });

    test('non-positive rate gives no suggestion', () {
      expect(customerRateFor(_juice, lastUnitPrice: 0, lastUnit: 'Carton', chosenUnit: 'Carton'), isNull);
    });
  });

  group('sale draft', () {
    test('round trip keeps the bill', () {
      final d = SaleDraft(
        customer: 'Ali',
        isWholesale: true,
        discount: '10',
        paid: '50',
        pendingItemName: 'Juice',
        pendingQty: '2',
        pendingPrice: '99.5',
        lines: [
          const SaleLine(
            itemName: 'Juice',
            barcode: 'b3',
            qty: 1.5,
            unit: 'Dozen',
            unitPrice: 50,
            cost: 40,
            amount: 75,
            mainUnit: 'Carton',
            secondaryUnit: 'Dozen',
            secondaryUnitQty: 4,
            tertiaryUnit: 'Pcs',
            tertiaryUnitQty: 12,
          ),
        ],
      );
      final back = decodeSaleDraft(encodeSaleDraft(d))!;
      expect(back.customer, 'Ali');
      expect(back.isWholesale, isTrue);
      expect(back.discount, '10');
      expect(back.paid, '50');
      expect(back.pendingItemName, 'Juice');
      expect(back.pendingQty, '2');
      expect(back.pendingPrice, '99.5');
      expect(back.lines.length, 1);
      expect(back.lines.first.qty, 1.5);
      expect(back.lines.first.unit, 'Dozen');
      expect(back.lines.first.tertiaryUnitQty, 12);
    });

    test('corrupt or wrong-shaped data is ignored, never thrown', () {
      expect(decodeSaleDraft('not json'), isNull);
      expect(decodeSaleDraft('[]'), isNull);
      expect(decodeSaleDraft('{"lines": "x"}')!.lines, isEmpty);
    });

    test('hasContent is false only for an empty bill', () {
      expect(const SaleDraft().hasContent, isFalse);
      expect(const SaleDraft(isWholesale: true, discount: '5').hasContent, isFalse);
      expect(const SaleDraft(customer: 'Ali').hasContent, isTrue);
      expect(const SaleDraft(pendingQty: '3').hasContent, isTrue);
      expect(SaleDraft(lines: [_line('a', 1, 'Pcs', 1)]).hasContent, isTrue);
    });
  });

  group('buildSaleBillText', () {
    final text = buildSaleBillText(
      shopName: 'Test Store',
      invoice: '0926123',
      date: DateTime(2026, 9, 28, 13, 5),
      customer: '',
      lines: [_line('Rice', 2, 'kg', 150.5)],
      subtotal: 301,
      discount: 1,
      total: 300,
      paid: 100,
    );

    test('has header, item row and totals', () {
      expect(text, contains('Test Store'));
      expect(text, contains('Invoice: 0926123'));
      expect(text, contains('Customer: Walk-in'));
      expect(text, contains('2 kg x 150.50'));
      expect(text, contains('301.00'));
      expect(text, contains('Discount'));
      expect(text, contains('TOTAL'));
      expect(text, contains('DUE'));
    });

    test('no line is wider than the paper', () {
      for (final l in text.split('\n')) {
        expect(l.length, lessThanOrEqualTo(32), reason: l);
      }
    });
  });
}
