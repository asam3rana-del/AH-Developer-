import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/cost_backfill.dart';

void main() {
  PendingLine line(int id, {double cost = 100, double pendingQty = 10, double pendingEst = 100, String log = ''}) =>
      PendingLine(
        id: id,
        invoice: 'INV$id',
        cost: cost,
        pendingQty: pendingQty,
        pendingEst: pendingEst,
        backfillLog: log,
      );

  group('CostBackfill.pendingForSale', () {
    test('stock poora ho to pending nahi', () {
      final p = CostBackfill.pendingForSale(needed: 10, stockBefore: 50, costPerSmallest: 10, lineCost: 100);
      expect(p.pendingQty, 0);
      expect(p.pendingEst, 0);
    });

    test('stock kam: sirf na dhaka hissa pending', () {
      final p = CostBackfill.pendingForSale(needed: 10, stockBefore: 4, costPerSmallest: 10, lineCost: 100);
      expect(p.pendingQty, closeTo(6, 1e-9));
      expect(p.pendingEst, closeTo(60, 1e-9));
    });

    test('minus stock: poori line pending', () {
      final p = CostBackfill.pendingForSale(needed: 10, stockBefore: -3, costPerSmallest: 10, lineCost: 100);
      expect(p.pendingQty, 10);
      expect(p.pendingEst, 100);
    });

    test('product cost 0: poori line pending', () {
      final p = CostBackfill.pendingForSale(needed: 10, stockBefore: 50, costPerSmallest: 0, lineCost: 0);
      expect(p.pendingQty, 10);
      expect(p.pendingEst, 0);
    });
  });

  group('planBackfill / planReverse', () {
    test('poori pending qty purchase rate se bhar jati hai', () {
      final r = planBackfill([line(1, cost: 118, pendingEst: 118)], billNo: 'B1', smallestQty: 10, ratePerSmallest: 10);
      expect(r, hasLength(1));
      expect(r.first.cost, closeTo(100, 1e-9));
      expect(r.first.pendingQty, 0);
      expect(r.first.pendingEst, 0);
    });

    test('aadhi qty cover: baaqi pending rehti hai', () {
      final r = planBackfill([line(1)], billNo: 'B1', smallestQty: 4, ratePerSmallest: 12);
      expect(r.first.cost, closeTo(108, 1e-9));
      expect(r.first.pendingQty, closeTo(6, 1e-9));
      expect(r.first.pendingEst, closeTo(60, 1e-9));
    });

    test('purani sale pehle bharti hai, extra qty agli line par', () {
      final r = planBackfill([line(1, pendingQty: 3, pendingEst: 30, cost: 30), line(2)],
          billNo: 'B1', smallestQty: 5, ratePerSmallest: 10);
      expect(r.map((e) => e.id), [1, 2]);
      expect(r[0].pendingQty, 0);
      expect(r[1].pendingQty, closeTo(8, 1e-9));
    });

    test('purchase qty pending se zyada ho to sirf pending bharti hai', () {
      final r = planBackfill([line(1, pendingQty: 2, pendingEst: 20, cost: 20)],
          billNo: 'B1', smallestQty: 50, ratePerSmallest: 10);
      expect(r.single.pendingQty, 0);
      expect(r.single.cost, closeTo(20, 1e-9));
    });

    test('reverse: cost aur pending bilkul pehle jaisi', () {
      final applied = planBackfill([line(1)], billNo: 'B1', smallestQty: 4, ratePerSmallest: 12).single;
      final back = planReverse([
        PendingLine(
          id: 1,
          invoice: 'INV1',
          cost: applied.cost,
          pendingQty: applied.pendingQty,
          pendingEst: applied.pendingEst,
          backfillLog: applied.backfillLog,
        )
      ], billNo: 'B1')
          .single;
      expect(back.cost, closeTo(100, 1e-9));
      expect(back.pendingQty, closeTo(10, 1e-9));
      expect(back.pendingEst, closeTo(100, 1e-9));
      expect(back.backfillLog, '');
    });

    test('reverse sirf usi bill ki entry hatata hai', () {
      final a = planBackfill([line(1)], billNo: 'B1', smallestQty: 4, ratePerSmallest: 12).single;
      final b = planBackfill([
        PendingLine(
            id: 1,
            invoice: 'INV1',
            cost: a.cost,
            pendingQty: a.pendingQty,
            pendingEst: a.pendingEst,
            backfillLog: a.backfillLog)
      ], billNo: 'B2', smallestQty: 3, ratePerSmallest: 20)
          .single;
      final back = planReverse([
        PendingLine(
            id: 1,
            invoice: 'INV1',
            cost: b.cost,
            pendingQty: b.pendingQty,
            pendingEst: b.pendingEst,
            backfillLog: b.backfillLog)
      ], billNo: 'B1')
          .single;
      // B1 ki 4 units wapas pending (3 B2 se bhari rahin).
      expect(back.pendingQty, closeTo(7, 1e-9));
      expect(decodeBackfillLog(back.backfillLog).single['b'], 'B2');
    });

    test('pending nahi hai to kuch nahi badalta', () {
      final r = planBackfill([line(1, pendingQty: 0, pendingEst: 0)], billNo: 'B1', smallestQty: 5, ratePerSmallest: 10);
      expect(r, isEmpty);
    });
  });

  test('scaledPendingColumns: qty double ho to pending bhi double', () {
    final m = scaledPendingColumns(pendingQty: 3, pendingEst: 30, backfillLog: '', ratio: 2);
    expect(m['pendingQty'], 6);
    expect(m['pendingEst'], 60);
  });
}
