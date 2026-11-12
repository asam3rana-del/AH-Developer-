import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';
import 'package:ah_developer_kiryana_store/services/credit_risk.dart';

// 15 Mar 2026, 14:30 local.
final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;
int day(int m, int d) => DateTime(2026, m, d).millisecondsSinceEpoch;

DueBill bill({double total = 1000, double paid = 0, int dueDate = 0, int createdAt = 0, bool isBalance = false, bool isAdvance = false}) =>
    DueBill(
      id: 'INV',
      partyId: 1,
      partyName: 'Ali',
      partyPhone: '0300',
      total: total,
      paid: paid,
      dueDate: dueDate,
      createdAt: createdAt == 0 ? day(3, 10) : createdAt,
      isSale: true,
      isBalance: isBalance,
      isAdvance: isAdvance,
    );

void main() {
  test('No bills, no promises: not risky', () {
    final r = creditRiskFor(bills: const [], entries: const [], nowMillis: now);
    expect(r.risky, isFalse);
  });

  test('Due date passed: late amount and days', () {
    final r = creditRiskFor(bills: [bill(total: 2000, paid: 500, dueDate: day(3, 5))], entries: const [], nowMillis: now);
    expect(r.lateAmount, 1500);
    expect(r.maxDaysLate, 10);
    expect(r.risky, isTrue);
  });

  test('Due today or later is not late', () {
    final r = creditRiskFor(
        bills: [bill(dueDate: day(3, 15)), bill(dueDate: day(3, 20))], entries: const [], nowMillis: now);
    expect(r.risky, isFalse);
  });

  test('No due date: late only after $creditRiskAgeDays days', () {
    final fresh = creditRiskFor(bills: [bill(createdAt: day(3, 1))], entries: const [], nowMillis: now);
    expect(fresh.risky, isFalse);
    final old = creditRiskFor(bills: [bill(createdAt: day(1, 15))], entries: const [], nowMillis: now);
    expect(old.risky, isTrue);
    expect(old.maxDaysLate, 59 - creditRiskAgeDays); // 15 Jan -> 15 Mar = 59 din
  });

  test('Opening balance rows and advances are ignored', () {
    final r = creditRiskFor(
      bills: [bill(createdAt: day(1, 1), isBalance: true), bill(dueDate: day(3, 1), isAdvance: true)],
      entries: const [],
      nowMillis: now,
    );
    expect(r.risky, isFalse);
  });

  test('Broken promise is risky even with no late bill', () {
    final e = DueFollowUp(
      partyId: 1,
      method: FollowUpMethod.call,
      outcome: FollowUpOutcome.promised,
      promiseDate: day(3, 12),
      createdAt: day(3, 10),
    );
    final r = creditRiskFor(bills: const [], entries: [e], nowMillis: now);
    expect(r.promiseBroken, isTrue);
    expect(r.risky, isTrue);
  });
}
