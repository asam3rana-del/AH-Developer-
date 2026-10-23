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
}
