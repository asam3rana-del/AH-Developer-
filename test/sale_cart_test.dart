import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/sale_hold_recall.dart';
import 'package:ah_developer_kiryana_store/utils/sale_cart.dart';

// Sale-screen unit order is primary-first: [unit, secondaryUnit, tertiaryUnit].
Product _oneTier() => const Product(barcode: 'b1', name: 'Rice', unit: 'kg');

Product _twoTier({String category = 'General', int idx = -1, int qsIdx = -1}) => Product(
      barcode: 'b2',
      name: 'Biscuit',
      category: category,
      unit: 'Carton',
      secondaryUnit: 'Pcs',
      secondaryUnitQty: 24,
      defaultUnitIndex: idx,
      quickSaleDefaultUnitIndex: qsIdx,
    );

Product _threeTier({int idx = -1, int qsIdx = -1}) => Product(
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
      defaultUnitIndex: idx,
      quickSaleDefaultUnitIndex: qsIdx,
    );

SaleLine _line(Product p, String unit, double qty, double price) => SaleLine(
      itemName: p.name,
      barcode: p.barcode,
      qty: qty,
      unit: unit,
      unitPrice: price,
      cost: 0,
      amount: qty * price,
      mainUnit: p.unit,
      secondaryUnit: p.secondaryUnit,
      secondaryUnitQty: p.secondaryUnitQty,
      tertiaryUnit: p.tertiaryUnit,
      tertiaryUnitQty: p.tertiaryUnitQty,
    );

void main() {
  group('saleUnitChoices', () {
    test('primary first, then secondary, then tertiary', () {
      expect(saleUnitChoices(_oneTier()), ['kg']);
      expect(saleUnitChoices(_twoTier()), ['Carton', 'Pcs']);
      expect(saleUnitChoices(_threeTier()), ['Carton', 'Dozen', 'Pcs']);
    });
  });

  group('default unit (Auto)', () {
    test('1-tier -> only unit', () => expect(autoDefaultUnitIndexFor(_oneTier()), 0));
    test('3-tier -> 2nd unit', () => expect(autoDefaultUnitIndexFor(_threeTier()), 1));
    test('2-tier general -> 2nd unit', () => expect(autoDefaultUnitIndexFor(_twoTier()), 1));
    test('2-tier Beverages -> primary (case-insensitive)', () {
      expect(autoDefaultUnitIndexFor(_twoTier(category: 'Beverages')), 0);
      expect(autoDefaultUnitIndexFor(_twoTier(category: 'beverages')), 0);
    });
  });

  group('manual default-unit override', () {
    test('valid override wins over Auto', () {
      expect(defaultUnitIndexFor(_threeTier(idx: 2)), 2);
      expect(defaultUnitFor(_threeTier(idx: 2)), 'Pcs');
      expect(defaultUnitIndexFor(_twoTier(idx: 0)), 0);
    });
    test('-1 falls through to Auto', () => expect(defaultUnitIndexFor(_threeTier()), 1));
    test('out-of-range (product lost a tier) falls through to Auto', () {
      expect(defaultUnitIndexFor(_twoTier(idx: 2)), 1);
      expect(defaultUnitIndexFor(_oneTier().copyWith(defaultUnitIndex: 1)), 0);
    });
    test('quick sale uses its own override, independent of Sale', () {
      final p = _threeTier(idx: 0, qsIdx: 2);
      expect(defaultUnitFor(p), 'Carton');
      expect(quickSaleDefaultUnitFor(p), 'Pcs');
      expect(quickSaleDefaultUnitIndexFor(_threeTier()), 1);
    });
  });

  group('Product map roundtrip keeps default-unit fields', () {
    test('toMap/fromMap', () {
      final p = _threeTier(idx: 2, qsIdx: 0);
      final back = Product.fromMap(p.toMap());
      expect(back.defaultUnitIndex, 2);
      expect(back.quickSaleDefaultUnitIndex, 0);
    });
    test('old rows without the columns read as Auto (-1)', () {
      final m = _threeTier().toMap()
        ..remove('defaultUnitIndex')
        ..remove('quickSaleDefaultUnitIndex');
      final back = Product.fromMap(m);
      expect(back.defaultUnitIndex, -1);
      expect(back.quickSaleDefaultUnitIndex, -1);
    });
    test('copyWith keeps overrides unless changed', () {
      final p = _threeTier(idx: 2, qsIdx: 0).copyWith(name: 'X');
      expect(p.defaultUnitIndex, 2);
      expect(p.quickSaleDefaultUnitIndex, 0);
    });
  });

  group('repriceLinesForSaleType', () {
    test('re-rates each line in its own unit; cost untouched', () {
      final p = _threeTier(); // Carton 600 retail / 540 wholesale; 48 pcs per... ladder Pcs=1
      final lines = [
        SaleLine(
            itemName: p.name, barcode: p.barcode, qty: 2, unit: 'Carton', unitPrice: 600, cost: 77, amount: 1200),
        SaleLine(itemName: p.name, barcode: p.barcode, qty: 12, unit: 'Pcs', unitPrice: 12.5, cost: 5, amount: 150),
      ];
      final r = repriceLinesForSaleType(lines, [p], isWholesale: true);
      expect(r.changed, isTrue);
      expect(r.lines[0].unitPrice, closeTo(540, 1e-9));
      expect(r.lines[0].amount, closeTo(1080, 1e-9));
      expect(r.lines[1].unitPrice, closeTo(540 / 48, 1e-9));
      expect(r.lines[1].amount, closeTo(12 * 540 / 48, 1e-9));
      expect(r.lines[0].cost, 77);
      expect(r.lines[1].cost, 5);
    });

    test('missing wholesale rate leaves the line alone', () {
      final p = _threeTier().copyWith(wholesalePrice: 0);
      final lines = [SaleLine(itemName: p.name, barcode: p.barcode, qty: 1, unit: 'Carton', unitPrice: 600, cost: 0, amount: 600)];
      final r = repriceLinesForSaleType(lines, [p], isWholesale: true);
      expect(r.changed, isFalse);
      expect(r.lines.single.unitPrice, 600);
    });

    test('unknown product keeps its price; empty cart is a no-op', () {
      final lines = [SaleLine(itemName: 'Gone', barcode: 'zzz', qty: 1, unit: 'pcs', unitPrice: 10, cost: 0, amount: 10)];
      expect(repriceLinesForSaleType(lines, const [], isWholesale: true).changed, isFalse);
      expect(repriceLinesForSaleType(const [], [_threeTier()], isWholesale: true).changed, isFalse);
    });

    test('falls back to matching by name when barcode changed', () {
      final p = _threeTier();
      final lines = [SaleLine(itemName: 'JUICE', barcode: 'old', qty: 1, unit: 'Carton', unitPrice: 600, cost: 0, amount: 600)];
      final r = repriceLinesForSaleType(lines, [p], isWholesale: true);
      expect(r.changed, isTrue);
      expect(r.lines.single.unitPrice, closeTo(540, 1e-9));
    });
  });

  group('marginFor', () {
    test('no cost or no price -> none', () {
      expect(marginFor(_oneTier(), 10, 'kg').level, MarginLevel.none);
      expect(marginFor(_threeTier(), 0, 'Carton').level, MarginLevel.none);
      expect(marginFor(null, 10, 'kg').level, MarginLevel.none);
    });
    test('loss / low / ok, with cost converted to the chosen unit', () {
      final p = _threeTier(); // cost 480 per Carton
      expect(marginFor(p, 480, 'Carton').level, MarginLevel.loss);
      expect(marginFor(p, 500, 'Carton').level, MarginLevel.low); // 4.2%
      expect(marginFor(p, 600, 'Carton').level, MarginLevel.ok); // 25%
      // per Pcs: cost 480/48 = 10
      final m = marginFor(p, 9, 'Pcs');
      expect(m.level, MarginLevel.loss);
      expect(m.costInUnit, closeTo(10, 1e-9));
    });
  });

  group('hold / recall encoding', () {
    test('roundtrip keeps header and every line field', () {
      final p = _threeTier();
      final draft = HeldSaleDraft(
        customerName: 'Ali Traders',
        isWholesale: true,
        isCash: false,
        discountText: '50',
        lines: [_line(p, 'Carton', 2, 540), _line(p, 'Pcs', 3.5, 11.25)],
      );
      final back = decodeHold(encodeHold(draft));
      expect(back.customerName, 'Ali Traders');
      expect(back.isWholesale, isTrue);
      expect(back.isCash, isFalse);
      expect(back.discountText, '50');
      expect(back.lines.length, 2);
      final l = back.lines[1];
      expect(l.barcode, 'b3');
      expect(l.itemName, 'Juice');
      expect(l.qty, 3.5);
      expect(l.unit, 'Pcs');
      expect(l.unitPrice, 11.25);
      expect(l.mainUnit, 'Carton');
      expect(l.secondaryUnit, 'Dozen');
      expect(l.secondaryUnitQty, 4);
      expect(l.tertiaryUnit, 'Pcs');
      expect(l.tertiaryUnitQty, 12);
    });

    test('retail / cash defaults and empty customer survive', () {
      final back = decodeHold(encodeHold(const HeldSaleDraft(
        customerName: '',
        isWholesale: false,
        isCash: true,
        discountText: '',
        lines: [],
      )));
      expect(back.customerName, '');
      expect(back.isWholesale, isFalse);
      expect(back.isCash, isTrue);
      expect(back.lines, isEmpty);
    });

    test('heldItemCount counts rows without full decode', () {
      final p = _oneTier();
      final payload = encodeHold(HeldSaleDraft(
        customerName: '',
        isWholesale: false,
        isCash: true,
        discountText: '',
        lines: [_line(p, 'kg', 1, 100), _line(p, 'kg', 2, 100), _line(p, 'kg', 3, 100)],
      ));
      expect(heldItemCount(payload), 3);
      expect(heldItemCount('garbage'), 0);
    });

    test('malformed rows are skipped, not crashed on', () {
      final payload = 'c\u0001Retail\u0001CASH\u00010\u0004a\u0003b\u0003c'; // < 10 fields
      final d = decodeHold(payload);
      expect(d.lines, isEmpty);
      expect(d.customerName, 'c');
    });
  });
}
