import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/ladder_rate_plan.dart';

// Capstan: ctn = 50 outer, outer = 10 dabbi (1 ctn = 500 dabbi). Naya ladder: outer = 10 dabbi.
Product _old({double cost = 118000, double sale = 125000, double bulkQty = 0}) => Product(
      barcode: 'P1',
      name: 'Capstan',
      cost: cost,
      salePrice: sale,
      wholesalePrice: 121000,
      shopkeeperPrice: 120000,
      bulkMinQty: bulkQty,
      unit: 'ctn',
      secondaryUnit: 'outer',
      secondaryUnitQty: 50,
      tertiaryUnit: 'dabbi',
      tertiaryUnitQty: 10,
    );

Product _newLadder(Product base, {double? cost, double? sale}) => base.copyWith(
      cost: cost,
      salePrice: sale,
      unit: 'outer',
      secondaryUnit: 'dabbi',
      secondaryUnitQty: 10,
      tertiaryUnit: '',
      tertiaryUnitQty: 0,
    );

void main() {
  group('LadderRatePlan', () {
    test('ctn hata kar outer/dabbi: cost aur rates / 50', () {
      final old = _old();
      final plan = LadderRatePlan.build(old, _newLadder(old))!;
      expect(plan.convertible, isTrue);
      final applied = plan.apply(_newLadder(old));
      expect(applied.cost, 2360);
      expect(applied.salePrice, 2500);
      expect(applied.wholesalePrice, 2420);
      expect(applied.shopkeeperPrice, 2400);
    });

    test('bulk min qty ulti taraf (1 ctn = 50 outer)', () {
      final old = _old(bulkQty: 1);
      final plan = LadderRatePlan.build(old, _newLadder(old))!;
      expect(plan.apply(_newLadder(old)).bulkMinQty, 50);
    });

    test('jo rate user ne form mein khud badli wo nahi chhedi jati', () {
      final old = _old();
      final draft = _newLadder(old, sale: 2600); // user ne retail khud likha
      final plan = LadderRatePlan.build(old, draft)!;
      final applied = plan.apply(draft);
      expect(applied.salePrice, 2600);
      expect(applied.cost, 2360);
      expect(plan.changes.any((c) => c.labelEn == 'Retail sale rate'), isFalse);
    });

    test('ladder na badli to plan nahi', () {
      final old = _old();
      expect(LadderRatePlan.build(old, old.copyWith(name: 'Capstan Red')), isNull);
    });

    test('sab se chhoti unit badli to convertible false', () {
      final old = _old();
      final draft = old.copyWith(
        unit: 'ctn',
        secondaryUnit: 'outer',
        secondaryUnitQty: 50,
        tertiaryUnit: 'pack',
        tertiaryUnitQty: 10,
      );
      final plan = LadderRatePlan.build(old, draft)!;
      expect(plan.convertible, isFalse);
      expect(plan.changes, isEmpty);
    });

    test('primary ki ginti barabar ho to rates wahi (plan null)', () {
      final old = _old();
      final draft = old.copyWith(
        unit: 'box',
        secondaryUnit: 'outer',
        secondaryUnitQty: 50,
        tertiaryUnit: 'dabbi',
        tertiaryUnitQty: 10,
      );
      expect(LadderRatePlan.build(old, draft), isNull);
    });
  });
}
