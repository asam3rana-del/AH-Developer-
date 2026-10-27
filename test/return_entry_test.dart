import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/return_entry.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

void main() {
  group('ReturnEntry', () {
    test('encode / decode round-trip', () {
      final list = [
        ReturnEntry(id: 1, amount: 500, date: day(1), returnDate: day(10), note: 'a'),
        ReturnEntry(id: 2, amount: 250.5, date: day(5)),
      ];
      final back = decodeReturnEntries(encodeReturnEntries(list));
      expect(back.length, 2);
      expect(back[0].amount, 500);
      expect(back[0].returnDate, day(10));
      expect(back[0].note, 'a');
      expect(back[1].amount, 250.5);
      expect(back[1].returnDate, 0);
    });

    test('khali / kharab text => khali list', () {
      expect(decodeReturnEntries(null), isEmpty);
      expect(decodeReturnEntries(''), isEmpty);
      expect(decodeReturnEntries('not json'), isEmpty);
      expect(decodeReturnEntries('{"a":1}'), isEmpty);
      expect(decodeReturnEntries('[1,{"id":3,"amount":9}]').length, 1);
      expect(encodeReturnEntries(const []), '');
    });

    test('signed: amanat minus, loan plus', () {
      expect(signedReturnAmount('amanat', 100), -100);
      expect(signedReturnAmount('loan', 100), 100);
      final l = [const ReturnEntry(id: 1, amount: 100), const ReturnEntry(id: 2, amount: 50)];
      expect(signedReturnTotal('amanat', l), -150);
      expect(signedReturnTotal('loan', l), 150);
    });

    test('next id aur sab se pehli wapsi ki tarikh', () {
      expect(nextReturnEntryId(const []), 1);
      final l = [
        ReturnEntry(id: 4, amount: 1, returnDate: day(20)),
        ReturnEntry(id: 2, amount: 1, returnDate: day(9)),
        const ReturnEntry(id: 3, amount: 1),
      ];
      expect(nextReturnEntryId(l), 5);
      expect(earliestReturnDate(l), day(9));
      expect(earliestReturnDate(const [ReturnEntry(id: 1, amount: 1)]), 0);
    });
  });

  group('Customer.returnEntries', () {
    test('toMap sirf tab key deta hai jab entries hon; fromMap wapas deta hai', () {
      expect(const Customer(name: 'A').toMap().containsKey('returnEntries'), false);
      final c = Customer(name: 'A', returnEntries: encodeReturnEntries([const ReturnEntry(id: 1, amount: 5)]));
      final back = Customer.fromMap({...c.toMap(), 'name': 'A'});
      expect(decodeReturnEntries(back.returnEntries).single.amount, 5);
      expect(c.copyWith(name: 'B').returnEntries, c.returnEntries);
      expect(Customer.fromMap({'id': 1, 'name': 'A'}).returnEntries, '');
    });

    test('sync payload mein returnEntries jata hai', () {
      final p = SyncQueueHelper.customerPayload({'id': 1, 'name': 'A', 'returnEntries': '[]x'});
      expect(p['returnEntries'], '[]x');
      expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A'})['returnEntries'], '');
    });
  });

  group('ReturnReminder entries', () {
    test('entriesTotal aur baseAmount', () {
      final r = ReturnReminder(
        partyId: 1,
        partyName: 'Ali',
        partyPhone: '',
        kind: 'loan',
        returnDate: 0,
        closing: 0,
        opening: 1300,
        entries: const [ReturnEntry(id: 1, amount: 500), ReturnEntry(id: 2, amount: 300)],
      );
      expect(r.entriesTotal, 800);
      expect(r.baseAmount, 500); // 1300 - 800
      final none = ReturnReminder(partyId: 1, partyName: 'A', partyPhone: '', kind: 'amanat', returnDate: 0, closing: 0, opening: -700);
      expect(none.baseAmount, 700);
      final exact = ReturnReminder(
          partyId: 1, partyName: 'A', partyPhone: '', kind: 'amanat', returnDate: 0, closing: 0, opening: -100, entries: const [ReturnEntry(id: 1, amount: 100)]);
      expect(exact.baseAmount, 0);
    });
  });
}
