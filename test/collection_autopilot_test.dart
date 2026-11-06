import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/collection_autopilot.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';

// 15 Mar 2026, 14:30 local.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;
int at(int d, int h) => DateTime(2026, 3, d, h).millisecondsSinceEpoch;

DueFollowUp fu(
  int createdAt, {
  int partyId = 1,
  String method = FollowUpMethod.whatsapp,
  String outcome = FollowUpOutcome.sent,
  int promise = 0,
  int next = 0,
}) =>
    DueFollowUp(
      id: createdAt,
      partyId: partyId,
      partyName: 'Ali',
      method: method,
      outcome: outcome,
      promiseDate: promise,
      nextFollowUp: next,
      createdAt: createdAt,
    );

DueParty party({int id = 1, String name = 'Ali', double total = 1000, int dueDate = 0, int createdAt = 1}) {
  final b = DueBill(
    id: 'b$id',
    partyId: id,
    partyName: name,
    partyPhone: '0300',
    total: total,
    paid: 0,
    dueDate: dueDate,
    createdAt: createdAt,
    isSale: true,
  );
  return groupDueByParty([b]).first;
}

void main() {
  test('late party jis se kabhi baat nahi hui => TODO', () {
    final q = buildAutopilot([party(dueDate: day(1))], {}, nowMillis: now);
    expect(q.todo.length, 1);
    expect(q.todo.first.neverTouched, true);
    expect(q.todo.first.reason, TouchReason.late);
    expect(q.done, isEmpty);
  });

  test('aaj WhatsApp bhej diya => DONE, TODO se nikal gayi', () {
    final q = buildAutopilot([party(dueDate: day(1))], {1: [fu(at(15, 9))]}, nowMillis: now);
    expect(q.todo, isEmpty);
    expect(q.done.length, 1);
    expect(q.done.first.touchesToday, 1);
    expect(q.isClear, true);
  });

  test('late party: 1 din pehle baat => WAITING, 3 din pehle => TODO', () {
    final p = party(dueDate: day(10));
    final w = buildAutopilot([p], {1: [fu(at(14, 10))]}, nowMillis: now);
    expect(w.todo, isEmpty);
    expect(w.waiting.length, 1);
    expect(w.waiting.first.daysUntilTouch, 2);
    final t = buildAutopilot([p], {1: [fu(at(12, 10))]}, nowMillis: now);
    expect(t.todo.length, 1);
  });

  test('30+ din purana baqi => gap 2 din', () {
    expect(touchGapDays(oldestDays: 40, broken: false), 2);
    expect(touchGapDays(oldestDays: 5, broken: false), 3);
    expect(touchGapDays(oldestDays: 40, broken: true), 1);
  });

  test('dispute wali party roz nahi satayi jati', () {
    final q = buildAutopilot(
      [party(dueDate: day(1))],
      {1: [fu(at(5, 10), outcome: FollowUpOutcome.dispute)]},
      nowMillis: now,
    );
    expect(q.todo, isEmpty);
    expect(q.waiting.length, 1);
  });

  test('toota wada TODO mein sab se upar', () {
    final q = buildAutopilot(
      [party(id: 1, name: 'Ali', total: 100, dueDate: day(1)), party(id: 2, name: 'Bilal', total: 5000, dueDate: day(1))],
      {2: [fu(at(8, 10), partyId: 2, outcome: FollowUpOutcome.promised, promise: day(10))]},
      nowMillis: now,
    );
    expect(q.todo.first.party.partyName, 'Bilal');
    expect(q.todo.first.reason, TouchReason.brokenPromise);
    expect(q.brokenCount, 1);
  });

  test('sirf note likhna koshish nahi ginta', () {
    expect(isTouch(fu(at(15, 9), method: FollowUpMethod.note, outcome: FollowUpOutcome.note)), false);
    expect(isTouch(fu(at(15, 9))), true);
    final q = buildAutopilot(
      [party(dueDate: day(1))],
      {1: [fu(at(15, 9), method: FollowUpMethod.note, outcome: FollowUpOutcome.note)]},
      nowMillis: now,
    );
    expect(q.todo.length, 1);
  });

  test('notification matn: baqi + ho chuka + aaj ki wasooli', () {
    final q = buildAutopilot(
      [party(id: 1, name: 'Ali', dueDate: day(1)), party(id: 2, name: 'Bilal', dueDate: day(1))],
      {2: [fu(at(15, 9), partyId: 2)]},
      nowMillis: now,
    );
    final body = autopilotNotificationBody(q, collectedToday: 2500, paymentsToday: 2);
    expect(body, contains('1 parties ko yaad dilana baqi'));
    expect(body, contains('1 ko aaj bhej diya'));
    expect(body, contains('Rs 2500'));
    expect(body, contains('Ali'));
  });

  test('koi party nahi => khali queue', () {
    final q = buildAutopilot([], {}, nowMillis: now);
    expect(q.planned, 0);
    expect(q.isClear, true);
  });
}
