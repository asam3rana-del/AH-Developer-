import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/purchase.dart';
import 'package:ah_developer_kiryana_store/models/sale.dart';

// 15 Mar 2026, 14:30 local — din ke beech ka waqt.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

DueBill bill(String id, {int? partyId = 1, double total = 100, double paid = 0, int dueDate = 0, int createdAt = 1, bool isSale = true, String phone = '', String name = 'Ali'}) =>
    DueBill(
      id: id,
      partyId: partyId,
      partyName: name,
      partyPhone: phone,
      total: total,
      paid: paid,
      dueDate: dueDate,
      createdAt: createdAt,
      isSale: isSale,
    );

void main() {
  group('dueBucket (Kotlin badge)', () {
    test('0 / negative => no date set', () {
      expect(dueBucket(0, nowMillis: now), DueBucket.noDate);
      expect(dueBucket(-5, nowMillis: now), DueBucket.noDate);
    });
    test('kal ya pehle => overdue; aaj => due today; 1-2 din baad => due soon; 3+ => upcoming', () {
      expect(dueBucket(day(14), nowMillis: now), DueBucket.overdue);
      expect(dueBucket(day(1), nowMillis: now), DueBucket.overdue);
      expect(dueBucket(day(15), nowMillis: now), DueBucket.dueToday);
      expect(dueBucket(day(16), nowMillis: now), DueBucket.dueSoon);
      expect(dueBucket(day(17), nowMillis: now), DueBucket.dueSoon);
      expect(dueBucket(day(18), nowMillis: now), DueBucket.upcoming);
      expect(dueBucket(day(30), nowMillis: now), DueBucket.upcoming);
    });
    test('aaj ki date 00:00 par ho to overdue nahi, due today hai (din ke beech mein bhi)', () {
      final late = DateTime(2026, 3, 15, 23, 59).millisecondsSinceEpoch;
      expect(dueBucket(day(15), nowMillis: late), DueBucket.dueToday);
    });
  });

  group('summary', () {
    test('overdue = date guzri hui (0 nahi ginti); totalDue = sab ka baqi', () {
      final s = summarizeDue([
        bill('A', total: 100, paid: 40, dueDate: day(10)), // overdue, 60
        bill('B', total: 50, dueDate: day(15)), // aaj — overdue nahi, 50
        bill('C', total: 30, paid: 10), // date nahi, 20
      ], nowMillis: now);
      expect(s.overdue, 1);
      expect(s.totalDue, 130);
    });
    test('khali list', () {
      final s = summarizeDue(const [], nowMillis: now);
      expect(s.overdue, 0);
      expect(s.totalDue, 0);
    });
  });

  group('sort (ORDER BY dueDate=0, dueDate, createdAt)', () {
    test('date wale pehle (purani pehle), date nahi wale aakhir mein createdAt se', () {
      final out = sortDueBills([
        bill('none-new', createdAt: 9),
        bill('later', dueDate: day(20), createdAt: 1),
        bill('none-old', createdAt: 2),
        bill('sooner-b', dueDate: day(10), createdAt: 5),
        bill('sooner-a', dueDate: day(10), createdAt: 3),
      ]);
      expect([for (final b in out) b.id], ['sooner-a', 'sooner-b', 'later', 'none-old', 'none-new']);
    });
  });

  group('Party Dashboard badge (customers)', () {
    test('aaj se purani date => overdue; sirf aaj => due today; kal ya baad ki => badge nahi', () {
      final m = overdueCustomerStatus([
        bill('1', partyId: 1, dueDate: day(10)),
        bill('2', partyId: 2, dueDate: day(15)),
        bill('3', partyId: 3, dueDate: day(16)),
        bill('4', partyId: 4, dueDate: 0),
      ], nowMillis: now);
      expect(m[1], PartyDueStatus.overdue);
      expect(m[2], PartyDueStatus.dueToday);
      expect(m.containsKey(3), isFalse);
      expect(m.containsKey(4), isFalse);
    });
    test('ek customer ki do sales: koi ek bhi purani ho to overdue', () {
      final m = overdueCustomerStatus([
        bill('1', partyId: 7, dueDate: day(15)),
        bill('2', partyId: 7, dueDate: day(3)),
      ], nowMillis: now);
      expect(m[7], PartyDueStatus.overdue);
    });
    test('walk-in (customer nahi) ignore', () {
      expect(overdueCustomerStatus([bill('1', partyId: null, dueDate: day(1))], nowMillis: now), isEmpty);
    });
  });

  group('WhatsApp', () {
    test('digits: 0 => 92, 10 digit => 92 lagao, 92 wala jyon ka tyon, alphabets/symbols hatao', () {
      expect(whatsAppDigits('0300-1234567'), '923001234567');
      expect(whatsAppDigits('3001234567'), '923001234567');
      expect(whatsAppDigits('+92 300 1234567'), '923001234567');
      expect(whatsAppDigits('923001234567'), '923001234567');
      expect(whatsAppDigits(''), '');
      expect(whatsAppDigits('abc'), '');
    });
    test('message sale vs purchase, Rs poore rupay', () {
      final s = bill('INV1', total: 1500.6, paid: 500, name: 'Ali');
      expect(reminderMessage(s),
          'Assalam o Alaikum Ali, aapka bill (Invoice INV1) mein Rs 1001 abhi baaki hai. Barah-e-karam jald ada karein. Shukriya!');
      final p = bill('B9', total: 200, isSale: false, name: 'Usman');
      expect(reminderMessage(p),
          'Assalam o Alaikum Usman, humare bill (Bill B9) mein Rs 200 abhi baaki hai. Barah-e-karam jald ada karenge. Shukriya!');
    });
    test('uri wa.me + encoded text', () {
      final u = whatsAppUri(bill('INV1', total: 10, phone: '0300-1234567'));
      expect(u.host, 'wa.me');
      expect(u.path, '/923001234567');
      expect(u.queryParameters['text'], contains('INV1'));
    });
  });

  group('startOfDayMillis', () {
    test('din ke beech ka waqt 00:00 ban jata hai', () {
      expect(startOfDayMillis(now), day(15));
      expect(startOfDayMillis(day(15)), day(15));
    });
  });

  group('models keep dueDate', () {
    test('Sale round-trip + purani row (column nahi) => 0', () {
      final s = Sale(
        invoice: 'I', subtotal: 1, discount: 0, tax: 0, total: 1, paid: 0,
        paymentMethod: 'cash', createdAt: 1, dueDate: 12345,
      );
      expect(Sale.fromMap(s.toMap()).dueDate, 12345);
      final legacy = s.toMap()..remove('dueDate');
      expect(Sale.fromMap(legacy).dueDate, 0);
    });
    test('Purchase round-trip', () {
      final p = Purchase(billNo: 'B', total: 1, paid: 0, createdAt: 1, dueDate: 999);
      expect(Purchase.fromMap(p.toMap()).dueDate, 999);
      expect(Purchase.fromMap(p.toMap()..remove('dueDate')).dueDate, 0);
    });
  });
}
