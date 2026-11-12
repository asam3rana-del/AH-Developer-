import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/collection_autopilot.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/qist_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

int d(int m, int day) => DateTime(2026, m, day).millisecondsSinceEpoch;
int at(int m, int day, int h) => DateTime(2026, m, day, h).millisecondsSinceEpoch;

// 10,000 in 4 monthly-ish (30 din) qisten, pehli 1 April.
final plan = QistPlan(total: 10000, count: 4, firstDate: d(4, 1), everyDays: 30, createdAt: d(3, 20));

void main() {
  test('Amounts: whole rupees, rounding goes to the last one', () {
    final p = QistPlan(total: 1000, count: 3, firstDate: d(4, 1), everyDays: 7, createdAt: 1);
    expect([p.amountOf(0), p.amountOf(1), p.amountOf(2)], [333, 333, 334]);
    expect(p.amountOf(0) + p.amountOf(1) + p.amountOf(2), 1000);
  });

  test('Dates: first + i * everyDays', () {
    expect(plan.dateOf(0), d(4, 1));
    expect(plan.dateOf(1), d(5, 1));
    expect(plan.dateOf(2), d(5, 31));
  });

  test('JSON round-trip; bad JSON = no plan', () {
    final back = QistPlan.fromJson(plan.toJson())!;
    expect(back.total, 10000);
    expect(back.count, 4);
    expect(back.firstDate, plan.firstDate);
    expect(QistPlan.fromJson(''), isNull);
    expect(QistPlan.fromJson('{bad'), isNull);
    expect(QistPlan.fromJson('{"total":0,"count":4,"firstDate":1,"everyDays":7,"createdAt":1}'), isNull);
  });

  test('Before the first date: nothing due, nothing late', () {
    final s = qistStatus(plan, 0, nowMillis: at(3, 25, 12));
    expect(s.dueByToday, 0);
    expect(s.overdue, 0);
    expect(s.nextIndex, 0);
    expect(s.nextDate, d(4, 1));
    expect(qistNeedsTouch(s, nowMillis: at(3, 25, 12)), isFalse);
  });

  test('On the date: needs a reminder, not yet late', () {
    final s = qistStatus(plan, 0, nowMillis: at(4, 1, 12));
    expect(s.overdue, 0);
    expect(qistNeedsTouch(s, nowMillis: at(4, 1, 12)), isTrue);
  });

  test('Payments are applied in order; partial payment leaves the rest late', () {
    final s = qistStatus(plan, 3500, nowMillis: at(5, 10, 12)); // 2 qisten (5,000) due, 3,500 aaye
    expect(s.paidCount, 1);
    expect(s.nextIndex, 1);
    expect(s.nextRemaining, 1500);
    expect(s.overdue, 1500);
    expect(s.remaining, 6500);
    expect(qistNeedsTouch(s, nowMillis: at(5, 10, 12)), isTrue);
  });

  test('Paid ahead: not late, no touch until the next date', () {
    final s = qistStatus(plan, 5000, nowMillis: at(5, 10, 12));
    expect(s.overdue, 0);
    expect(s.nextIndex, 2);
    expect(qistNeedsTouch(s, nowMillis: at(5, 10, 12)), isFalse);
  });

  test('Fully paid = completed', () {
    final s = qistStatus(plan, 10000, nowMillis: at(9, 1, 12));
    expect(s.completed, isTrue);
    expect(s.remaining, 0);
    expect(qistNeedsTouch(s, nowMillis: at(9, 1, 12)), isFalse);
  });

  test('Autopilot: late installment puts the customer in TODO with qistDue', () {
    final party = groupDueByParty([
      DueBill(
        id: 'b1',
        partyId: 1,
        partyName: 'Ali',
        partyPhone: '0300',
        total: 6500,
        paid: 0,
        dueDate: 0,
        createdAt: at(5, 9, 10),
        isSale: true,
      ),
    ]).first;
    final now = at(5, 10, 12);
    final normal = buildAutopilot([party], {}, nowMillis: now);
    expect(normal.todo, isEmpty);
    final q = buildAutopilot([party], {}, nowMillis: now, qist: {1: qistStatus(plan, 3500, nowMillis: now)});
    expect(q.todo.single.reason, TouchReason.qistDue);
  });

  test('Customer model + sync payload carry the plan', () {
    final c = Customer(name: 'Ali', qistPlan: plan.toJson());
    expect(QistPlan.fromJson(Customer.fromMap({...c.toMap(), 'id': 1}).qistPlan)!.count, 4);
    expect(c.copyWith(qistPlan: '').toMap()['qistPlan'], '');
    expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A', 'qistPlan': 'x'})['qistPlan'], 'x');
  });
}
