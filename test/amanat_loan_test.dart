import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

ReturnReminder rr(String name, {String kind = 'amanat', int date = 0}) => ReturnReminder(
      partyId: 1,
      partyName: name,
      partyPhone: '03001234567',
      kind: kind,
      returnDate: date,
      closing: 0,
    );

void main() {
  group('Customer kind / returnDate', () {
    test('defaults: normal customer, no reminder', () {
      const c = Customer(name: 'Ali');
      expect(c.kind, '');
      expect(c.returnDate, 0);
      expect(c.isAmanat, false);
      expect(c.isLoan, false);
      expect(c.hasReturnReminder, false);
    });

    test('toMap / fromMap round-trip', () {
      final c = Customer(id: 3, name: 'Ali', kind: 'loan', returnDate: day(20));
      final back = Customer.fromMap(c.toMap());
      expect(back.kind, 'loan');
      expect(back.returnDate, day(20));
      expect(back.isLoan, true);
      expect(back.hasReturnReminder, true);
    });

    test('purani row (kind/returnDate column nahi) => defaults', () {
      final c = Customer.fromMap({'id': 1, 'name': 'Ali'});
      expect(c.kind, '');
      expect(c.returnDate, 0);
    });

    test('amanat bina date => reminder nahi; normal customer par date ho to bhi nahi', () {
      expect(const Customer(name: 'A', kind: 'amanat').hasReturnReminder, false);
      expect(Customer(name: 'A', returnDate: day(5)).hasReturnReminder, false);
    });

    test('copyWith kind/returnDate badalta hai, baqi nahi', () {
      final c = Customer(id: 1, name: 'A', dueDays: 7).copyWith(kind: 'amanat', returnDate: day(9));
      expect(c.kind, 'amanat');
      expect(c.returnDate, day(9));
      expect(c.dueDays, 7);
      expect(c.copyWith(name: 'B').kind, 'amanat');
    });

    test('sync payload mein kind + returnDate jata hai (null => default)', () {
      final p = SyncQueueHelper.customerPayload({'id': 1, 'name': 'A', 'kind': 'loan', 'returnDate': 123});
      expect(p['kind'], 'loan');
      expect(p['returnDate'], 123);
      final q = SyncQueueHelper.customerPayload({'id': 2, 'name': 'B'});
      expect(q['kind'], '');
      expect(q['returnDate'], 0);
    });
  });

  group('return reminders', () {
    test('sort: date wale pehle (purani pehle), phir date nahi wale naam se', () {
      final sorted = sortReturnReminders([
        rr('Zaid'),
        rr('Bilal', date: day(20)),
        rr('Asif'),
        rr('Chand', date: day(5)),
      ]);
      expect(sorted.map((r) => r.partyName).toList(), ['Chand', 'Bilal', 'Asif', 'Zaid']);
    });

    test('message amanat vs loan', () {
      expect(returnReminderMessage(rr('Ali')), contains('amanat'));
      expect(returnReminderMessage(rr('Ali', kind: 'loan')), contains('udhar'));
    });

    test('whatsapp uri', () {
      final u = returnWhatsAppUri(rr('Ali'));
      expect(u.host, 'wa.me');
      expect(u.path, '/923001234567');
    });
  });
}
