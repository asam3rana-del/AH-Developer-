import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';

Payment pay(
  int id, {
  String type = 'customer',
  int? partyId = 1,
  String ref = 'BILL-1',
  double amount = 100.0,
  int updatedAt = 0,
  int createdAt = 1,
}) =>
    Payment(
      id: id,
      reference: ref,
      partyType: type,
      partyId: partyId,
      amount: amount,
      method: 'cash',
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

void main() {
  group('closing / colour direction', () {
    test('closing = opening + running + stuck', () {
      expect(partyClosing(opening: 100, running: 50, stuck: 25), 175);
      expect(partyClosing(opening: 100, running: -40), 60);
    });

    test('customer: negative closing means shop gives; supplier: positive means shop gives', () {
      expect(partyIsGive(isCustomer: true, closing: -10), isTrue);
      expect(partyIsGive(isCustomer: true, closing: 10), isFalse);
      expect(partyIsGive(isCustomer: false, closing: 10), isTrue);
      expect(partyIsGive(isCustomer: false, closing: -10), isFalse);
      expect(partyIsGive(isCustomer: true, closing: 0), isFalse);
      expect(partyIsGive(isCustomer: false, closing: 0), isFalse);
    });

    test('Dues only ignores float noise but counts a stuck-only balance', () {
      expect(partyHasDue(opening: 0, running: 0), isFalse);
      expect(partyHasDue(opening: 100, running: -100), isFalse);
      expect(partyHasDue(opening: 0.1 + 0.2, running: -0.3), isFalse);
      expect(partyHasDue(opening: 0, running: 0.02), isTrue);
      expect(partyHasDue(opening: 0, running: 0, stuck: 500), isTrue);
    });
  });

  group('search', () {
    test('matches name or phone, case-insensitive, trimmed', () {
      expect(partyMatchesQuery('Arfan Brothers', '0300-123', 'arfan'), isTrue);
      expect(partyMatchesQuery('Arfan Brothers', '0300-123', '  BROTH '), isTrue);
      expect(partyMatchesQuery('Arfan Brothers', '0300-123', '0300'), isTrue);
      expect(partyMatchesQuery('Arfan Brothers', '0300-123', 'xyz'), isFalse);
    });

    test('empty / blank query matches everyone', () {
      expect(partyMatchesQuery('Ali', '', ''), isTrue);
      expect(partyMatchesQuery('Ali', '', '   '), isTrue);
    });
  });

  group('ledger balance (shared with Balance Sheet)', () {
    test('trueBalance / drift use the same PartyLedger', () {
      const bills = [(id: 'I1', status: 'active', total: 100.0, paid: 40.0)];
      const drifted = PartyLedger(partyId: 7, storedBalance: 0.0, bills: bills, payments: []);
      const correct = PartyLedger(partyId: 7, storedBalance: 60.0, bills: bills, payments: []);
      expect(trueBalance(drifted), 60);
      expect(countBalanceDrift([drifted, correct]), 1);
    });

    test('a payment already inside a bill is not subtracted twice', () {
      const l = PartyLedger(
        storedBalance: 0.0,
        bills: [(id: 'I1', status: 'active', total: 100.0, paid: 40.0)],
        payments: [
          (reference: 'I1', billReference: '', amount: 40.0), // bill-embedded
          (reference: 'manual-x', billReference: 'I1', amount: 10.0), // linked to the bill
          (reference: 'manual-y', billReference: '', amount: 5.0), // standalone
        ],
      );
      expect(trueBalance(l), 55); // 60 owed - 5 standalone
    });
  });

  group('Cleanup Payments (duplicate groups)', () {
    test('keeps the newest row per (type, party, reference); biggest loss first', () {
      final all = [
        pay(1, updatedAt: 10),
        pay(2, updatedAt: 30),
        pay(3, updatedAt: 20),
        pay(4, ref: 'BILL-2', amount: 500), // single row -> not a duplicate
        pay(5, partyId: 2), // same reference, different party -> not grouped
        pay(6, partyId: null), // no party -> ignored
        pay(9, partyId: null),
        pay(7, type: 'supplier', partyId: 9, ref: 'B9', amount: 300, updatedAt: 1),
        pay(8, type: 'supplier', partyId: 9, ref: 'B9', amount: 300, updatedAt: 1),
      ];
      final groups = groupDuplicatePayments(all, customerNames: {1: 'Ali'}, supplierNames: const {});

      expect(groups.length, 2);

      // Supplier group (removes Rs 300) comes before the customer group (removes Rs 200).
      expect(groups[0].partyType, 'supplier');
      expect(groups[0].partyName, '#9'); // unknown name falls back to #id
      expect(groups[0].keep.id, 8); // tie on updatedAt/createdAt -> highest id
      expect(groups[0].remove.map((p) => p.id), [7]);

      expect(groups[1].partyName, 'Ali');
      expect(groups[1].keep.id, 2); // updatedAt 30 is the newest
      expect(groups[1].remove.map((p) => p.id).toSet(), {1, 3});
      expect(groups[1].removeTotal, 200);
    });

    test('no duplicates -> empty list', () {
      expect(groupDuplicatePayments([pay(1), pay(2, ref: 'X')], customerNames: const {}, supplierNames: const {}),
          isEmpty);
    });
  });

  group('Cleanup Orphaned', () {
    test('only bill-embedded rows whose bill is gone; manual and unknown types are safe', () {
      final all = [
        pay(1, ref: 'INV-1'), // sale exists
        pay(2, ref: 'INV-GONE'), // orphan customer payment
        pay(3, type: 'supplier', ref: 'BILL-GONE'), // orphan supplier payment
        pay(4, type: 'supplier', ref: 'BILL-1'), // purchase exists
        pay(5, ref: 'manual-customer-1-123'), // manual payment, never an orphan
        pay(6, type: 'other', ref: 'X'), // unknown type
      ];
      final orphans = pickOrphanedPayments(all, saleInvoices: {'INV-1'}, purchaseBillNos: {'BILL-1'});
      expect(orphans.map((p) => p.id), [2, 3]);
    });
  });

  group('Customer model (stuck balance)', () {
    test('totalPayable includes stuck; map round-trips; old rows default to 0', () {
      const c = Customer(id: 3, name: 'Ali', openingBalance: 100, balance: 50, stuckBalance: 25, serverId: 's1');
      expect(c.totalPayable, 175);
      expect(c.hasStuck, isTrue);
      expect(c.toMap()['stuckBalance'], 25);

      final old = Customer.fromMap({'id': 1, 'name': 'Old', 'dirty': 1}); // pre-v9 row: no stuckBalance
      expect(old.stuckBalance, 0);
      expect(old.hasStuck, isFalse);
    });

    test('copyWith keeps id and serverId', () {
      const c = Customer(id: 3, name: 'Ali', serverId: 's1', stuckBalance: 10);
      final d = c.copyWith(name: 'Ali K', openingBalance: 5);
      expect(d.id, 3);
      expect(d.serverId, 's1');
      expect(d.stuckBalance, 10);
      expect(d.name, 'Ali K');
      expect(d.openingBalance, 5);
    });

    test('Supplier copyWith keeps id and serverId', () {
      const s = Supplier(id: 4, name: 'Arfan', serverId: 'sv');
      final t = s.copyWith(phone: '0300');
      expect(t.id, 4);
      expect(t.serverId, 'sv');
      expect(t.phone, '0300');
    });
  });
}
