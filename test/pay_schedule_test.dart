import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/collection_autopilot.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/pay_schedule.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

// 15 Mar 2026 (Sunday), 14:30 local.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int d) => DateTime(2026, 3, d).millisecondsSinceEpoch;

DueParty party({int id = 1, int dueDate = 0, int createdAt = 0}) => groupDueByParty([
      DueBill(
        id: 'b$id',
        partyId: id,
        partyName: 'Ali',
        partyPhone: '0300',
        total: 1000,
        paid: 0,
        dueDate: dueDate,
        createdAt: createdAt == 0 ? day(14) : createdAt,
        isSale: true,
      ),
    ]).first;

void main() {
  group('PaySchedule', () {
    test('parse', () {
      expect(PaySchedule.parse(''), isNull);
      expect(PaySchedule.parse('w:5'), isNotNull);
      expect(PaySchedule.parse('m:31'), isNotNull);
      expect(PaySchedule.parse('w:0'), isNull);
      expect(PaySchedule.parse('w:8'), isNull);
      expect(PaySchedule.parse('m:32'), isNull);
      expect(PaySchedule.parse('friday'), isNull);
    });

    test('weekly: Juma', () {
      expect(isPayDay('w:5', DateTime(2026, 3, 13)), isTrue); // Friday
      expect(isPayDay('w:5', DateTime(2026, 3, 14)), isFalse);
      expect(isPayDay(PaySchedule.weeklyOn(DateTime.sunday), DateTime(2026, 3, 15)), isTrue);
    });

    test('monthly: day, and last day for short months', () {
      expect(isPayDay('m:1', DateTime(2026, 4, 1)), isTrue);
      expect(isPayDay('m:1', DateTime(2026, 4, 2)), isFalse);
      expect(isPayDay('m:31', DateTime(2026, 2, 28)), isTrue); // Feb ka aakhri din
      expect(isPayDay('m:31', DateTime(2026, 3, 30)), isFalse);
      expect(isPayDay(PaySchedule.monthlyOn(31), DateTime(2026, 3, 31)), isTrue);
    });

    test('labels and choices', () {
      expect(payScheduleLabel('w:5', urdu: false), 'Every Friday');
      expect(payScheduleLabel('m:10', urdu: false), 'Every month on the 10');
      expect(payScheduleLabel('', urdu: false), 'Not set');
      for (final c in payScheduleChoices) {
        expect(c.isEmpty || PaySchedule.parse(c) != null, isTrue, reason: c);
      }
    });
  });

  group('Autopilot', () {
    test('Fresh bill, not late: no task normally, TODO on its pay day', () {
      final normal = buildAutopilot([party()], {}, nowMillis: now);
      expect(normal.todo, isEmpty);
      final payDay = buildAutopilot([party()], {}, nowMillis: now, paySchedules: {1: 'w:7'}); // aaj Sunday
      expect(payDay.todo.length, 1);
      expect(payDay.todo.first.reason, TouchReason.payDay);
    });

    test('Not the pay day: unchanged', () {
      final q = buildAutopilot([party()], {}, nowMillis: now, paySchedules: {1: 'w:5'});
      expect(q.todo, isEmpty);
    });

    test('Pay day but already contacted today => done, not todo', () {
      final today = DueFollowUp(
        id: 1,
        partyId: 1,
        method: FollowUpMethod.whatsapp,
        outcome: FollowUpOutcome.sent,
        createdAt: DateTime(2026, 3, 15, 10).millisecondsSinceEpoch,
      );
      final q = buildAutopilot([party()], {1: [today]}, nowMillis: now, paySchedules: {1: 'w:7'});
      expect(q.todo, isEmpty);
      expect(q.done.length, 1);
    });
  });

  group('Customer + sync', () {
    test('model round-trip and clearing', () {
      const c = Customer(name: 'Ali', paySchedule: 'm:1');
      expect(Customer.fromMap({...c.toMap(), 'id': 1}).paySchedule, 'm:1');
      expect(c.copyWith(paySchedule: '').toMap()['paySchedule'], '');
    });

    test('push payload carries it', () {
      expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A', 'paySchedule': 'w:5'})['paySchedule'], 'w:5');
      expect(SyncQueueHelper.customerPayload({'id': 1, 'name': 'A'})['paySchedule'], '');
    });
  });
}
