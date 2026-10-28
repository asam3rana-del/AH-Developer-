import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/return_entry.dart';
import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

void main() {
  ReturnEntry e(int id, double a, {int d = 0, String note = ''}) => ReturnEntry(id: id, amount: a, date: d, note: note);

  group('ReturnLogRow', () {
    test('JSON round trip; kharab text => khali', () {
      final log = logAddGiven(const [], 'loan', e(1, 500, d: 10, note: 'x'), atMillis: 99);
      final back = decodeReturnLog(encodeReturnLog(log));
      expect(back.single.type, kLogGiven);
      expect(back.single.amount, 500);
      expect(back.single.date, 10);
      expect(back.single.entryId, 1);
      expect(decodeReturnLog('not json'), isEmpty);
      expect(decodeReturnLog(''), isEmpty);
      expect(encodeReturnLog(const []), '');
    });

    test('balanceEffect: loan +, amanat -, wasooli / hatana ulta', () {
      ReturnLogRow r(String type, String kind, double a) => ReturnLogRow(id: 1, type: type, kind: kind, amount: a);
      expect(r(kLogGiven, 'loan', 100).balanceEffect, 100);
      expect(r(kLogRecovered, 'loan', 40).balanceEffect, -40);
      expect(r(kLogRemoved, 'loan', 60).balanceEffect, -60);
      expect(r(kLogAdjusted, 'loan', -10).balanceEffect, -10);
      expect(r(kLogGiven, 'amanat', 100).balanceEffect, -100);
      expect(r(kLogRecovered, 'amanat', 40).balanceEffect, 40);
      expect(r(kLogAdjusted, 'amanat', 10).balanceEffect, -10);
    });
  });

  group('ledger hamesha entries se milta hai', () {
    test('add + settle (FIFO) + edit + delete', () {
      var entries = <ReturnEntry>[];
      var log = <ReturnLogRow>[];

      // add 1000 + 500
      for (final x in [e(1, 1000, d: 1), e(2, 500, d: 2)]) {
        entries = [...entries, x];
        log = logAddGiven(log, 'loan', x, atMillis: 5);
      }
      expect(logGap('loan', entries, log), 0);

      // settle 1200
      final out = settleEntriesFifo(entries, 1200);
      entries = out.remaining;
      log = logRecovered(log, 'loan', out.settled, atMillis: 6);
      expect(returnEntriesTotal(entries), 300);
      expect(logGap('loan', entries, log), 0);
      expect(returnLogNet(log), 300);

      // edit remaining entry 300 -> 450
      final old = entries.single;
      final upd = old.copyWith(amount: 450, note: 'badla');
      log = logEditEntry(log, 'loan', old, upd, atMillis: 7);
      entries = [upd];
      expect(logGap('loan', entries, log), 0);
      expect(log.where((r) => r.type == kLogAdjusted).single.amount, 150);

      // date / note-only edit: adjusted row nahi banti, given row ka note badalta hai
      final upd2 = upd.copyWith(note: 'phir');
      final before = log.length;
      log = logEditEntry(log, 'loan', upd, upd2, atMillis: 8);
      expect(log.length, before);
      expect(log.firstWhere((r) => r.entryId == 2 && r.type == kLogGiven).note, 'phir');
      entries = [upd2];

      // delete
      log = logRemoveEntry(log, 'loan', entries.single, atMillis: 9);
      entries = [];
      expect(logGap('loan', entries, log), 0);
      expect(returnLogNet(log), 0);
    });

    test('amanat ka ledger bhi milta hai', () {
      final x = e(1, 800, d: 1);
      var log = logAddGiven(const [], 'amanat', x);
      log = logRecovered(log, 'amanat', 300, atMillis: 2);
      final left = [x.copyWith(amount: 500)];
      expect(signedReturnTotal('amanat', left), -500);
      expect(returnLogNet(log), -500);
      expect(logGap('amanat', left, log), 0);
    });
  });

  group('backfill / untracked row', () {
    test('purani entries se given rows', () {
      final log = backfillReturnLog('loan', [e(1, 100, d: 3), e(2, 50, d: 4)]);
      expect(log.map((r) => r.amount), [100, 50]);
      expect(log.map((r) => r.entryId), [1, 2]);
      expect(logGap('loan', [e(1, 100), e(2, 50)], log), 0);
    });

    test('log entries se na mile => ek untracked adjusted row, kul balance se milta hai', () {
      final entries = [e(1, 700)];
      final log = [const ReturnLogRow(id: 1, type: kLogGiven, kind: 'loan', amount: 500)];
      final rows = ledgerLogRows('loan', entries, log);
      expect(rows.length, 2);
      expect(rows.last.id, -1);
      expect(rows.last.type, kLogAdjusted);
      expect(returnLogNet(rows), 700);
      // amanat mein bhi
      final rowsA = ledgerLogRows('amanat', [e(1, 700)], [const ReturnLogRow(id: 1, type: kLogGiven, kind: 'amanat', amount: 500)]);
      expect(returnLogNet(rowsA), -700);
    });

    test('log poora ho to koi extra row nahi', () {
      final entries = [e(1, 100)];
      final log = backfillReturnLog('loan', entries);
      expect(ledgerLogRows('loan', entries, log).length, 1);
    });
  });

  group('Customer / sync', () {
    test('returnLog toMap / fromMap / copyWith / payload', () {
      final log = encodeReturnLog(backfillReturnLog('loan', [e(1, 5)]));
      final c = Customer(name: 'A', returnLog: log);
      expect(Customer.fromMap(c.toMap()).returnLog, log);
      expect(c.copyWith(name: 'B').returnLog, log);
      expect(const Customer(name: 'A').toMap().containsKey('returnLog'), false);
      expect(Customer.fromMap({'id': 1, 'name': 'A'}).returnLog, '');
      expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A', 'returnLog': log})['returnLog'], log);
      expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A'})['returnLog'], '');
    });
  });

  group('TxEntry filter', () {
    test('Loan rows sirf Loan chip / All mein; Bills / Payments mein nahi', () {
      final loan = TxEntry(
        createdAt: 5,
        isPayment: false,
        searchText: 'loan given 500',
        loan: const ReturnLogRow(id: 1, type: kLogGiven, kind: 'loan', amount: 500),
      );
      final pay = const TxEntry(createdAt: 4, isPayment: true, searchText: 'payment');
      final bill = const TxEntry(createdAt: 3, isPayment: false, searchText: 'sale');
      final all = [loan, pay, bill];
      expect(filterTxEntries(all, TxFilter.all, '').length, 3);
      expect(filterTxEntries(all, TxFilter.bills, ''), [bill]);
      expect(filterTxEntries(all, TxFilter.payments, ''), [pay]);
      expect(filterTxEntries(all, TxFilter.loan, ''), [loan]);
      expect(filterTxEntries(all, TxFilter.all, 'given').single, loan);
      expect(loan.amount, 500);
    });
  });
}
