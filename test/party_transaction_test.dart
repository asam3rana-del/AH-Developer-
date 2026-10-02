import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';

// PartyTransactionActivity.kt ke PURE hisaab ka test (DB / UI ke bagair).
// Numbers haath se nikaale gaye hain, taake Android ke saath mel khayen.

Payment _pay(String ref, {String billRef = '', double amount = 10}) => Payment(
      reference: ref,
      partyType: 'customer',
      partyId: 1,
      amount: amount,
      method: 'cash',
      createdAt: 1,
      billReference: billRef,
    );

void main() {
  group('computePartyTxStats', () {
    test('running = outstanding(active bills) - unlinked standalone payments; closing adds opening + stuck', () {
      final st = computePartyTxStats(
        bills: [
          (total: 100.0, paid: 40.0, status: 'active', createdAt: 10, dueDate: 0),
          (total: 50.0, paid: 50.0, status: 'active', createdAt: 30, dueDate: 0),
          (total: 30.0, paid: 0.0, status: 'returned', createdAt: 20, dueDate: 0), // returned: kuch baqi nahi
        ],
        standalone: [
          (amount: 20.0, billReference: ''),
          (amount: 10.0, billReference: 'INV1'), // linked => bill ke paid mein pehle se
        ],
        opening: 5,
        stuck: 15,
        creditLimit: 500,
      );
      expect(st.totalAmount, 180);
      expect(st.totalPaid, 110); // 90 (bills) + 20 (unlinked)
      expect(st.running, 40); // 60 - 20
      expect(st.daily, 45);
      expect(st.closing, 60);
      expect(st.lastActivityAt, 30);
      expect(st.creditLimit, 500);
    });

    test('overdue counts only active, past-due, still-owing bills', () {
      final st = computePartyTxStats(
        bills: [
          (total: 100.0, paid: 40.0, status: 'active', createdAt: 1, dueDate: 1000), // 60 overdue
          (total: 80.0, paid: 80.0, status: 'active', createdAt: 2, dueDate: 1000), // fully paid
          (total: 70.0, paid: 0.0, status: 'returned', createdAt: 3, dueDate: 1000), // returned
          (total: 90.0, paid: 0.0, status: 'active', createdAt: 4, dueDate: 5000), // not due yet
          (total: 20.0, paid: 0.0, status: 'active', createdAt: 5, dueDate: 0), // no due date
        ],
        standalone: const [],
        opening: 0,
        nowMillis: 2000,
      );
      expect(st.overdue, 60);
    });

    test('empty party: zeros and no last activity', () {
      final st = computePartyTxStats(bills: const [], standalone: const [], opening: 0);
      expect(st.closing, 0);
      expect(st.lastActivityAt, isNull);
    });
  });

  test('standalonePayments drops rows whose reference is one of the party\'s own bills', () {
    final all = [_pay('manual-1'), _pay('BILL7'), _pay('manual-2', billRef: 'BILL7')];
    final out = standalonePayments(all, {'BILL7'});
    expect(out.map((p) => p.reference), ['manual-1', 'manual-2']);
  });

  group('filterTxEntries', () {
    final entries = [
      const TxEntry(createdAt: 3, isPayment: false, searchText: '01 jan 2026 sale 100.0'),
      const TxEntry(createdAt: 2, isPayment: true, searchText: '02 jan 2026 payment received cash ali 50.0'),
      const TxEntry(createdAt: 1, isPayment: false, searchText: '03 jan 2026 sale 75.5'),
    ];
    test('chips', () {
      expect(filterTxEntries(entries, TxFilter.all, '').length, 3);
      expect(filterTxEntries(entries, TxFilter.bills, '').length, 2);
      expect(filterTxEntries(entries, TxFilter.payments, '').single.createdAt, 2);
    });
    test('search is case-insensitive and combines with the chip', () {
      expect(filterTxEntries(entries, TxFilter.all, '  ALI ').single.isPayment, isTrue);
      expect(filterTxEntries(entries, TxFilter.bills, 'ali'), isEmpty);
      expect(filterTxEntries(entries, TxFilter.bills, '75.5').single.createdAt, 1);
    });
  });

  group('reconcilePaid', () {
    test('caps paid at the new total, never raises it, never negative', () {
      expect(reconcilePaid(100, 60), 60);
      expect(reconcilePaid(40, 60), 40);
      expect(reconcilePaid(40, -5), 0);
    });
  });

  group('purchase line cost (weighted average)', () {
    test('add then reverse the same line returns the original cost', () {
      final added = addPurchaseLineCost(
          productCost: 5, productStock: 10, factor: 1, addedSmallestQty: 10, lineAmount: 70); // (50+70)/20
      expect(added, 6);
      final back = reversePurchaseLineCost(
          productCost: added, productStock: 20, factor: 1, itemAmount: 70, smallestQtyToRemove: 10);
      expect(back, closeTo(5, 1e-9));
    });

    test('works per smallest unit when factor > 1 (cost is stored per primary unit)', () {
      // 1 dozen = 12 pieces; cost per dozen 60 => 5 per piece.
      final added = addPurchaseLineCost(
          productCost: 60, productStock: 12, factor: 12, addedSmallestQty: 12, lineAmount: 84); // 7/piece
      expect(added, closeTo(72, 1e-9)); // 6/piece * 12
    });

    test('first purchase into empty stock takes the line rate; removing everything leaves cost 0', () {
      expect(addPurchaseLineCost(productCost: 9, productStock: 0, factor: 1, addedSmallestQty: 4, lineAmount: 40), 10);
      expect(
          reversePurchaseLineCost(
              productCost: 10, productStock: 4, factor: 1, itemAmount: 40, smallestQtyToRemove: 4),
          0);
    });

    test('zero qty leaves cost untouched', () {
      expect(reversePurchaseLineCost(productCost: 8, productStock: 3, factor: 1, itemAmount: 5, smallestQtyToRemove: 0), 8);
      expect(addPurchaseLineCost(productCost: 8, productStock: 3, factor: 1, addedSmallestQty: 0, lineAmount: 5), 8);
    });
  });
}
