import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/rate_list_csv.dart';
import 'package:ah_developer_kiryana_store/utils/rate_list_export.dart';

/// Kotlin ProductUnitConversionTest.kt ka Dart version + Phase 0/1 fixes
/// (isFractionalUnit, formatStockBreakdown, ladder rescale, rate list CSV).
Product product({
  String unit = 'Carton',
  String secondaryUnit = '',
  double secondaryUnitQty = 0.0,
  String tertiaryUnit = '',
  double tertiaryUnitQty = 0.0,
  double stock = 0.0,
  double openingStock = 0.0,
}) =>
    Product(
      barcode: 'TEST123',
      name: 'Test Product',
      unit: unit,
      secondaryUnit: secondaryUnit,
      secondaryUnitQty: secondaryUnitQty,
      tertiaryUnit: tertiaryUnit,
      tertiaryUnitQty: tertiaryUnitQty,
      stock: stock,
      openingStock: openingStock,
    );

void main() {
  group('unitLadder', () {
    test('single tier', () {
      final l = product(unit: 'Piece').unitLadder();
      expect(l.length, 1);
      expect(l[0].unit, 'Piece');
      expect(l[0].smallestPerUnit, 1.0);
    });

    test('two tier: 1 Carton = 10 Box', () {
      final l = product(secondaryUnit: 'Box', secondaryUnitQty: 10).unitLadder();
      expect(l.map((t) => t.unit).toList(), ['Box', 'Carton']);
      expect(l[1].smallestPerUnit, 10.0);
    });

    test('three tier: 1 Carton = 10 Box, 1 Box = 12 Pcs', () {
      final l = product(secondaryUnit: 'Box', secondaryUnitQty: 10, tertiaryUnit: 'Pcs', tertiaryUnitQty: 12)
          .unitLadder();
      expect(l.map((t) => t.unit).toList(), ['Pcs', 'Box', 'Carton']);
      expect(l.map((t) => t.smallestPerUnit).toList(), [1.0, 12.0, 120.0]);
    });

    test('tertiary without secondary degrades to single tier', () {
      expect(product(tertiaryUnit: 'Pcs', tertiaryUnitQty: 12).unitLadder().length, 1);
    });
  });

  group('toSmallestUnits / fromSmallestUnits', () {
    final three = product(secondaryUnit: 'Box', secondaryUnitQty: 10, tertiaryUnit: 'Pcs', tertiaryUnitQty: 12);

    test('three tier conversion', () {
      expect(three.toSmallestUnits(2, 'Carton'), 240.0);
      expect(three.toSmallestUnits(3, 'Box'), 36.0);
      expect(three.toSmallestUnits(5, 'Pcs'), 5.0);
    });

    test('case and whitespace insensitive', () {
      final p = product(secondaryUnit: 'Box', secondaryUnitQty: 10);
      expect(p.toSmallestUnits(2, '  box '), 2.0);
      expect(p.toSmallestUnits(2, 'BOX'), 2.0);
    });

    test('unknown unit falls back to primary factor', () {
      expect(product(secondaryUnit: 'Box', secondaryUnitQty: 10).toSmallestUnits(1, 'Dabbi'), 10.0);
    });

    test('round trip', () {
      final s = three.toSmallestUnits(2.5, 'Box');
      expect(three.fromSmallestUnits(s, 'Box'), closeTo(2.5, 0.0001));
    });
  });

  group('isFractionalUnit / isValidSmallestQty', () {
    test('piece unit: whole only', () {
      final p = product(unit: 'Piece');
      expect(p.isValidSmallestQty(5.0), isTrue);
      expect(p.isValidSmallestQty(5.5), isFalse);
    });

    test('gram smallest unit allows fractions', () {
      final p = product(unit: 'Kg', secondaryUnit: 'Gram', secondaryUnitQty: 1000);
      expect(p.isFractionalUnit(), isTrue);
      expect(p.isValidSmallestQty(250.5), isTrue);
    });

    test('Kotlin list: kg, litre, tola, maund bhi fractional', () {
      for (final u in ['kg', 'Kg', 'litre', 'Liter', 'l', 'tola', 'Maund', 'ml', 'gm']) {
        expect(product(unit: u).isFractionalUnit(), isTrue, reason: u);
      }
      expect(product(unit: 'pcs').isFractionalUnit(), isFalse);
    });

    test('kg product accepts 0.5', () {
      expect(product(unit: 'Kg').isValidSmallestQty(0.5), isTrue);
    });
  });

  group('formatStockBreakdown', () {
    test('single tier', () {
      expect(product(unit: 'pcs', stock: 7).formatStockBreakdown(), '7 pcs');
    });

    test('three tier: 1 carton 2 box 1 pcs', () {
      final p = product(
          secondaryUnit: 'box', secondaryUnitQty: 10, tertiaryUnit: 'pcs', tertiaryUnitQty: 12, stock: 120 + 24 + 1);
      expect(p.formatStockBreakdown(), '1 Carton 2 box 1 pcs');
    });

    test('zero stock shows SMALLEST unit (Kotlin)', () {
      final p = product(secondaryUnit: 'box', secondaryUnitQty: 10, tertiaryUnit: 'pcs', tertiaryUnitQty: 12);
      expect(p.formatStockBreakdown(), '0 pcs');
    });

    test('float noise trimmed to 3 decimals', () {
      final p = product(unit: 'Kg', secondaryUnit: 'Gram', secondaryUnitQty: 1000, stock: 0.30000000000000004);
      expect(p.formatStockBreakdown(), '0.3 Gram');
    });

    test('fractional smallest leftover kept', () {
      final p = product(unit: 'Kg', secondaryUnit: 'Gram', secondaryUnitQty: 1000, stock: 1500.5);
      expect(p.formatStockBreakdown(), '1 Kg 500.5 Gram');
    });
  });

  group('rescaleStockForLadderChange (unit-ladder rescale bug)', () {
    test('ladder unchanged => stock untouched', () {
      final e = product(secondaryUnit: 'Box', secondaryUnitQty: 10, stock: 37, openingStock: 50);
      final r = rescaleStockForLadderChange(e, e);
      expect(r.changed, isFalse);
      expect(r.stock, 37.0);
      expect(r.openingStock, 50.0);
    });

    test('Petti stock 6 + new ladder 1 Petti = 12 Tray = 30 Pcs => 6 Petti stays 6 Petti', () {
      final e = product(unit: 'Petti', stock: 6, openingStock: 6);
      final d = product(
          unit: 'Petti', secondaryUnit: 'Tray', secondaryUnitQty: 12, tertiaryUnit: 'Pcs', tertiaryUnitQty: 30);
      final r = rescaleStockForLadderChange(e, d);
      expect(r.changed, isTrue);
      expect(r.stock, 6 * 360.0);
      expect(r.openingStock, 6 * 360.0);
      expect(d.formatStockBreakdown().isNotEmpty, isTrue);
    });

    test('secondary conversion qty change rescales', () {
      final e = product(secondaryUnit: 'Box', secondaryUnitQty: 10, stock: 20); // 2 Carton
      final d = product(secondaryUnit: 'Box', secondaryUnitQty: 12);
      expect(rescaleStockForLadderChange(e, d).stock, 24.0); // still 2 Carton
    });
  });

  group('rate list CSV export', () {
    test('Code column pehla, BOM, naam se sorted, import wapas parh leta hai', () {
      final a = Product(barcode: 'B2', name: 'Zeera', category: 'Masala', unit: 'Kg', wholesalePrice: 100, salePrice: 120.5);
      final b = Product(
        barcode: 'B1',
        name: 'aata "Fine"',
        category: 'Grocery',
        unit: 'Bori',
        wholesalePrice: 10,
        salePrice: 12,
        secondaryUnit: 'Kg',
        secondaryUnitQty: 20,
      );
      final csv = buildRateListCsv([a, b]);
      expect(csv.startsWith('\uFEFF'), isTrue);
      final rows = parseRateListCsv(csv);
      expect(rows.length, 2);
      expect(rows[0].barcode, 'B1'); // 'aata' pehle
      expect(rows[0].secondaryUnit, 'Kg');
      expect(rows[0].secondaryUnitQty, 20.0);
      expect(rows[1].barcode, 'B2');
      expect(rows[1].retail, 120.5);
      expect(rows[1].unit, 'Kg');
    });
  });
}
