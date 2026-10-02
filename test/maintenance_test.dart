import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/bulk_translate_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/duplicate_unit_fix.dart';
import 'package:ah_developer_kiryana_store/utils/merge_duplicate_products.dart';

Product p(
  String barcode,
  String name, {
  double stock = 0,
  double opening = 0,
  String unit = 'pcs',
  int unitSize = 1,
  String secondary = '',
  double secondaryQty = 0,
  int updatedAt = 0,
}) =>
    Product(
      barcode: barcode,
      name: name,
      stock: stock,
      openingStock: opening,
      unit: unit,
      unitSize: unitSize,
      secondaryUnit: secondary,
      secondaryUnitQty: secondaryQty,
      updatedAt: updatedAt,
    );

void main() {
  group('dedupedUnitName (Duplicate Unit Fix)', () {
    test('newline / space / mixed case doharai => ek lafz', () {
      expect(dedupedUnitName('Box\nBox'), 'Box');
      expect(dedupedUnitName('Box Box'), 'Box');
      expect(dedupedUnitName('Pcs  Pcs'), 'Pcs');
      expect(dedupedUnitName('box   BOX'), 'box'); // pehle wale ka casing
      expect(dedupedUnitName('  Box\r\nBox  '), 'Box');
    });

    test('saaf ya alag lafz => null (chhoda jata hai)', () {
      expect(dedupedUnitName('Box'), isNull);
      expect(dedupedUnitName('Big Box'), isNull);
      expect(dedupedUnitName('Box Box Box'), isNull);
      expect(dedupedUnitName(''), isNull);
      expect(dedupedUnitName('   '), isNull);
    });

    test('Urdu doharai bhi pakdi jati hai', () {
      expect(dedupedUnitName('کلو\nکلو'), 'کلو');
    });
  });

  group('looksUrdu / urduValues (Bulk Translate)', () {
    test('sirf Urdu/Arabic script', () {
      expect(looksUrdu('چینی'), isTrue);
      expect(looksUrdu('Sugar چینی'), isTrue);
      expect(looksUrdu('Sugar'), isFalse);
      expect(looksUrdu(''), isFalse);
    });

    test('urduValues: duplicate hatate, English/khali chhorte, sorted', () {
      final r = urduValues(['کلو', 'Kg', 'کلو', '  ', 'بوری', '']);
      expect(r.length, 2);
      expect(r.contains('کلو'), isTrue);
      expect(r.contains('بوری'), isTrue);
      expect(r.contains('Kg'), isFalse);
      final sorted = List.of(r)..sort();
      expect(r, sorted);
    });
  });

  group('planProductMerge (Merge Duplicate Products)', () {
    test('same naam + same unit => ek group, sab se taaza keeper, stock jama', () {
      final plan = planProductMerge([
        p('1', 'Rice', stock: 10, opening: 4, updatedAt: 100),
        p('2', 'rice ', stock: 5, opening: 1, updatedAt: 300), // naam trim/case-insensitive
        p('3', 'RICE', stock: 2, opening: 0, updatedAt: 200),
      ]);
      expect(plan.groups.length, 1);
      final g = plan.groups.first;
      expect(g.keeper.barcode, '2');
      expect(g.losers.map((x) => x.barcode).toSet(), {'1', '3'});
      expect(g.combinedStock, 17);
      expect(g.combinedOpeningStock, 5);
      expect(plan.productsToRemove, 2);
      expect(plan.skippedUnitMismatch, 0);
    });

    test('updatedAt barabar => list mein pehla keeper', () {
      final plan = planProductMerge([
        p('1', 'Tea', updatedAt: 50),
        p('2', 'Tea', updatedAt: 50),
      ]);
      expect(plan.groups.single.keeper.barcode, '1');
    });

    test('naam same lekin unit alag => merge nahi, skipped count', () {
      final plan = planProductMerge([
        p('1', 'Oil', unit: 'Bottle', stock: 3),
        p('2', 'Oil', unit: 'Litre', stock: 4),
      ]);
      expect(plan.isEmpty, isTrue);
      expect(plan.skippedUnitMismatch, 1);
    });

    test('secondary unit / qty bhi unit-config ka hissa hai', () {
      final plan = planProductMerge([
        p('1', 'Soap', secondary: 'Box', secondaryQty: 12),
        p('2', 'Soap', secondary: 'Box', secondaryQty: 24),
        p('3', 'Soap', secondary: 'Box', secondaryQty: 24),
      ]);
      expect(plan.groups.length, 1);
      expect(plan.groups.single.all.map((x) => x.barcode).toSet(), {'2', '3'});
      expect(plan.skippedUnitMismatch, 1); // barcode 1 alag setup
    });

    test('unit ke aage/peechhe ki space se farq nahi parta', () {
      final plan = planProductMerge([
        p('1', 'Salt', unit: 'Pcs'),
        p('2', 'Salt', unit: ' Pcs '),
      ]);
      expect(plan.groups.length, 1);
    });

    test('khali naam wali products kabhi merge nahi hoti', () {
      final plan = planProductMerge([p('1', ''), p('2', '   ')]);
      expect(plan.isEmpty, isTrue);
    });

    test('alag naam ya akeli product => kuch nahi', () {
      final plan = planProductMerge([p('1', 'Rice'), p('2', 'Sugar')]);
      expect(plan.isEmpty, isTrue);
      expect(plan.skippedUnitMismatch, 0);
    });

    test('do alag duplicate groups + ek mismatch', () {
      final plan = planProductMerge([
        p('1', 'A'), p('2', 'A'),
        p('3', 'B'), p('4', 'B'), p('5', 'B'),
        p('6', 'C', unit: 'Kg'), p('7', 'C', unit: 'g'),
      ]);
      expect(plan.groups.length, 2);
      expect(plan.productsToRemove, 3);
      expect(plan.skippedUnitMismatch, 1);
    });
  });
}
