import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/cost_backfill.dart';
import 'package:ah_developer_kiryana_store/db/pending_cost_repository.dart';

PendingCostLine pl({double qty = 10, double est = 100, double rate = 12, int id = 1}) => PendingCostLine(
      itemId: id,
      invoice: 'INV$id',
      createdAt: 1,
      party: 'Ali',
      productName: 'Item',
      smallestUnit: 'pcs',
      pendingQty: qty,
      pendingEst: est,
      ratePerSmallest: rate,
    );

void main() {
  group('PendingCostLine', () {
    test('fillable sirf jab product cost > 0', () {
      expect(pl(rate: 12).fillable, isTrue);
      expect(pl(rate: 0).fillable, isFalse);
    });
    test('newPendingCost / costChange', () {
      final l = pl(qty: 10, est: 100, rate: 12);
      expect(l.newPendingCost, 120);
      expect(l.costChange, 20); // cost barhegi
      expect(pl(qty: 10, est: 150, rate: 12).costChange, -30); // profit behtar
    });
    test('totalCostChange sirf fillable lines ginta hai', () {
      expect(totalCostChange([pl(id: 1), pl(id: 2, est: 0, rate: 0), pl(id: 3, qty: 5, est: 80, rate: 10)]), 20 + (50 - 80));
      expect(totalCostChange(const []), 0);
    });
  });

  group('product cost se backfill (planBackfill + kProductCostTag)', () {
    test('poori pending qty product rate se bhar jati hai, log mein tag', () {
      const line = PendingLine(id: 1, invoice: 'I', cost: 100, pendingQty: 10, pendingEst: 100, backfillLog: '');
      final r = planBackfill([line], billNo: kProductCostTag, smallestQty: 10, ratePerSmallest: 12);
      expect(r, hasLength(1));
      expect(r.first.cost, closeTo(120, 1e-9));
      expect(r.first.pendingQty, 0);
      expect(r.first.pendingEst, 0);
      expect(decodeBackfillLog(r.first.backfillLog).single['b'], kProductCostTag);
    });
    test('purchase bill delete product-cost wali entry wapas pending nahi karti', () {
      const line = PendingLine(id: 1, invoice: 'I', cost: 100, pendingQty: 10, pendingEst: 100, backfillLog: '');
      final filled = planBackfill([line], billNo: kProductCostTag, smallestQty: 10, ratePerSmallest: 12).first;
      final after = planReverse([
        PendingLine(
            id: 1, invoice: 'I', cost: filled.cost, pendingQty: filled.pendingQty, pendingEst: filled.pendingEst, backfillLog: filled.backfillLog),
      ], billNo: 'B7');
      expect(after, isEmpty);
    });
  });
}
