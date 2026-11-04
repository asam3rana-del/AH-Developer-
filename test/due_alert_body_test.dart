import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_followup_repository.dart';
import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/services/due_alert_service.dart';

// 15 Mar 2026, 14:30 local.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

DueParty party(int id, double total, int due) => DueParty(
      partyId: id,
      partyName: 'P$id',
      partyPhone: '0300',
      isSale: true,
      bills: [
        DueBill(
            id: 'I$id',
            partyId: id,
            partyName: 'P$id',
            partyPhone: '0300',
            total: total,
            paid: 0,
            dueDate: due,
            createdAt: 1,
            isSale: true),
      ],
    );

void main() {
  test('notification ka matan: aaj ki due date wali parties', () {
    final f = buildCollectionFocus([party(1, 1000, day(15))], const {}, nowMillis: now);
    expect(DueAlertService.bodyFor(f), contains('Aaj 1 parties se Rs 1000 lena hai'));
  });

  test('notification ka matan: follow-up ke saath aaj ki due date bhi', () {
    final f = buildCollectionFocus([party(1, 1000, day(15)), party(2, 500, day(10))], const {}, nowMillis: now);
    final body = DueAlertService.bodyFor(f);
    expect(body, contains('1 overdue (Rs 500)'));
    expect(body, contains('Aaj 1 parties se Rs 1000 lena hai'));
  });
}
