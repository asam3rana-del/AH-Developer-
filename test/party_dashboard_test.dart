import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/party_dashboard_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

PartyRow customer(String name, double closing, {int? at, double stuck = 0.0, int id = 1}) =>
    PartyRow(id: id, name: name, phone: '', closing: closing, isCustomer: true, stuck: stuck, lastActivityAt: at);

PartyRow supplier(String name, double closing, {int? at, int id = 1}) =>
    PartyRow(id: id, name: name, phone: '', closing: closing, isCustomer: false, lastActivityAt: at);

void main() {
  group("You'll Get / You'll Give totals (Kotlin FIX: customer aur supplier ka sign ULTA)", () {
    test('customer > 0 => Get, customer < 0 => Give', () {
      final t = partyTotals([customer('A', 500), customer('B', -200)]);
      expect(t.toGet, 500);
      expect(t.toGive, 200);
    });

    test('supplier > 0 => Give, supplier < 0 => Get', () {
      final t = partyTotals([supplier('S1', 700), supplier('S2', -50)]);
      expect(t.toGive, 700);
      expect(t.toGet, 50);
    });

    test('mixed list + settled party kuch nahi jorti', () {
      final t = partyTotals([customer('A', 100), supplier('S', 40), customer('Z', 0), supplier('Y', -10)]);
      expect(t.toGet, 110); // 100 (customer) + 10 (supplier credit)
      expect(t.toGive, 40);
    });

    test('khali list', () {
      final t = partyTotals(const []);
      expect(t.toGet, 0);
      expect(t.toGive, 0);
    });
  });

  group('party filter', () {
    final rows = [
      customer('Ali', 300), // receivable
      customer('Bilal', -80), // payable (shop owes customer)
      supplier('Cash Co', 900), // payable
      supplier('Dawood', -25), // receivable (supplier owes shop)
      customer('Zero', 0.001), // settled
    ];

    test('receivable / payable settled ko bahar rakhte hain', () {
      final rec = filterPartyRows(rows, PartyFilter.receivable, '').map((r) => r.name).toList();
      final pay = filterPartyRows(rows, PartyFilter.payable, '').map((r) => r.name).toList();
      expect(rec, ['Ali', 'Dawood']);
      expect(pay, ['Bilal', 'Cash Co']);
    });

    test('customers / suppliers only', () {
      expect(filterPartyRows(rows, PartyFilter.customers, '').length, 3);
      expect(filterPartyRows(rows, PartyFilter.suppliers, '').length, 2);
    });

    test('naam search case-insensitive + filter saath', () {
      expect(filterPartyRows(rows, PartyFilter.all, 'ALI').map((r) => r.name), ['Ali']);
      expect(filterPartyRows(rows, PartyFilter.payable, 'co').map((r) => r.name), ['Cash Co']);
      expect(filterPartyRows(rows, PartyFilter.receivable, 'co'), isEmpty);
    });
  });

  group('sortPartyRows', () {
    test('naya len-den pehle, phir jis ka len-den nahi wo naam ke hisaab se', () {
      final sorted = sortPartyRows([
        customer('Zed', 0),
        customer('Old', 10, at: 100),
        customer('alpha', 0),
        supplier('New', 5, at: 900),
      ]).map((r) => r.name).toList();
      expect(sorted, ['New', 'Old', 'alpha', 'Zed']);
    });
  });

  group('PartyRow', () {
    test('isGive / isSettled', () {
      expect(customer('a', -1).isGive, isTrue);
      expect(customer('a', 1).isGive, isFalse);
      expect(supplier('s', 1).isGive, isTrue);
      expect(supplier('s', -1).isGive, isFalse);
      expect(customer('a', 0.004).isSettled, isTrue);
      expect(customer('a', 0.01).isSettled, isFalse);
    });
  });

  group('filterTxRows', () {
    const sale = TxRow(reference: 'INV-1', partyName: 'Ali Traders', amount: 100, createdAt: 3, isSale: true, status: 'active');
    const purchase =
        TxRow(reference: 'INV-1', partyName: 'Cash Purchase', amount: 50, createdAt: 2, isSale: false, status: 'returned');
    final rows = [sale, purchase];
    final index = {
      'S:INV-1': ['Basmati Rice rice chawal'],
      'P:INV-1': ['Sugar cheeni'],
    };

    test('khali query => sab', () {
      expect(filterTxRows(rows, '  ', index), rows);
    });

    test('party ke naam se', () {
      expect(filterTxRows(rows, 'ali', index), [sale]);
    });

    test('item ke naam / searchTag se, har lafz zaroori', () {
      expect(filterTxRows(rows, 'chawal', index), [sale]);
      expect(filterTxRows(rows, 'cash sugar', index), [purchase]); // party + item lafz milkar
      expect(filterTxRows(rows, 'ali sugar', index), isEmpty);
    });

    test('invoice aur billNo ek jaisa ho to bhi items alag (S: / P: key)', () {
      expect(sale.key, 'S:INV-1');
      expect(purchase.key, 'P:INV-1');
      expect(filterTxRows(rows, 'sugar', index), [purchase]);
    });

    test('isReturned', () {
      expect(sale.isReturned, isFalse);
      expect(purchase.isReturned, isTrue);
    });
  });

  group('filterItemAggs', () {
    const aloo = Product(barcode: '1', name: 'آلو', searchTag: 'Aloo Potato');
    const pyaz = Product(barcode: '2', name: 'پیاز', searchTag: 'Pyaz Onion');
    final rows = [const ItemAgg(product: aloo, soldQty: 3), const ItemAgg(product: pyaz)];

    test('name + searchTag, har lafz', () {
      expect(filterItemAggs(rows, ''), rows);
      expect(filterItemAggs(rows, 'potato').map((r) => r.product.barcode), ['1']);
      expect(filterItemAggs(rows, 'onion pyaz').map((r) => r.product.barcode), ['2']);
      expect(filterItemAggs(rows, 'potato onion'), isEmpty);
    });
  });
}
