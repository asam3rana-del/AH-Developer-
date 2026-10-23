import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';

DueBill bill(String id, {int? partyId = 1, double total = 100, double paid = 0, int createdAt = 1, bool isSale = true}) => DueBill(
      id: id,
      partyId: partyId,
      partyName: 'Ali',
      partyPhone: '',
      total: total,
      paid: paid,
      dueDate: 0,
      createdAt: createdAt,
      isSale: isSale,
    );

void main() {
  group('capDueByBalance', () {
    test('balance 0 (payment ho chuki, bill se link nahi) => bill list se nikal jata hai', () {
      final out = capDueByBalance([bill('A', total: 4160, paid: 260)], {1: 0.0});
      expect(out, isEmpty);
    });

    test('balance bills ke kul ke barabar ya zyada => kuch nahi katta', () {
      final out = capDueByBalance([bill('A', total: 100), bill('B', total: 50, createdAt: 2)], {1: 150.0});
      expect(out.map((b) => b.due).toList()..sort(), [50.0, 100.0]);
      final more = capDueByBalance([bill('A', total: 100)], {1: 900.0});
      expect(more.single.due, 100.0);
    });

    test('balance kam ho to sab se purane bill se katta hai (FIFO), naya bill poora rehta hai', () {
      final out = capDueByBalance([
        bill('NEW', total: 300, createdAt: 3),
        bill('OLD', total: 100, createdAt: 1),
        bill('MID', total: 200, createdAt: 2),
      ], {1: 350.0});
      // kul 600, balance 350 => 250 katta hai: OLD (100) poora, MID se 150, NEW poora.
      final byId = {for (final b in out) b.id: b.due};
      expect(byId.containsKey('OLD'), isFalse);
      expect(byId['MID'], 50.0);
      expect(byId['NEW'], 300.0);
    });

    test('negative balance (advance) => sab bills ada maane jate hain', () {
      expect(capDueByBalance([bill('A', total: 500)], {1: -100.0}), isEmpty);
    });

    test('Walk-in (partyId null) aur balances mein na milne wali party jaisi hain waisi rehti hai', () {
      final out = capDueByBalance([bill('W', partyId: null, total: 7900), bill('X', partyId: 9, total: 60)], {1: 0.0});
      expect(out.map((b) => b.id).toSet(), {'W', 'X'});
    });

    test('alag alag party ek doosre ko nahi katti', () {
      final out = capDueByBalance([bill('A', partyId: 1, total: 100), bill('B', partyId: 2, total: 100)], {1: 0.0, 2: 100.0});
      expect(out.map((b) => b.id).toList(), ['B']);
    });

    test('summarizeDue kata hua hisaab dikhata hai', () {
      final out = capDueByBalance([bill('A', total: 4160, paid: 260)], {1: 260.0});
      expect(summarizeDue(out).totalDue, 260.0);
    });
  });

  group('addUnbilledBalance (Party Dashboard payable se mel)', () {
    test('bill ke baghair opening balance wala supplier "Previous balance" row ke saath aata hai', () {
      final out = addUnbilledBalance(const [], {5: (name: 'Usman', phone: '0300', closing: 800.0, createdAt: 0)});
      expect(out.single.isBalance, isTrue);
      expect(out.single.due, 800.0);
      expect(out.single.partyName, 'Usman');
    });
    test('bills + opening: bills ke upar ka hissa alag row', () {
      final bills = [bill('B1', partyId: 5, total: 300, isSale: false)];
      final out = addUnbilledBalance(bills, {5: (name: 'Usman', phone: '', closing: 1000.0, createdAt: 0)});
      expect(out.length, 2);
      expect(out.firstWhere((b) => b.isBalance).due, 700.0);
      expect(summarizeDue(out).totalDue, 1000.0);
    });
    test('closing <= bills ya <= 0 => koi extra row nahi', () {
      final bills = [bill('B1', partyId: 5, total: 300, isSale: false)];
      expect(addUnbilledBalance(bills, {5: (name: 'U', phone: '', closing: 300.0, createdAt: 0)}).length, 1);
      expect(addUnbilledBalance(const [], {5: (name: 'U', phone: '', closing: -50.0, createdAt: 0)}), isEmpty);
      expect(addUnbilledBalance(const [], {5: (name: 'U', phone: '', closing: 0.0, createdAt: 0)}), isEmpty);
    });
    test('customer (isSale: true): opening/stuck wala receivable bhi aata hai', () {
      final out = addUnbilledBalance(const [], {3: (name: 'Ali', phone: '', closing: 500.0, createdAt: 0)}, isSale: true);
      expect(out.single.isBalance && out.single.isSale, isTrue);
      expect(out.single.due, 500.0);
      expect(reminderMessage(out.single), contains('aapke hisab mein Rs 500'));
    });
    test('balance row ka WhatsApp message bill number nahi likhta', () {
      final out = addUnbilledBalance(const [], {5: (name: 'Usman', phone: '', closing: 800.0, createdAt: 0)});
      expect(reminderMessage(out.single), contains('Rs 800'));
      expect(reminderMessage(out.single), isNot(contains('Bill ')));
    });
  });
}
