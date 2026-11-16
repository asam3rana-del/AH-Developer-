import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/collection_autopilot.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';
import 'package:ah_developer_kiryana_store/services/credit_risk.dart';

// 16 Nov 2026, 10:00.
final now = DateTime(2026, 11, 16, 10).millisecondsSinceEpoch;
int at(int m, int d, [int h = 12]) => DateTime(2026, m, d, h).millisecondsSinceEpoch;

DueBill bill(String id, int createdAt, {double total = 1000, bool isBalance = false}) => DueBill(
      id: id,
      partyId: 1,
      partyName: 'Ali LH',
      partyPhone: '0300',
      total: total,
      paid: 0,
      dueDate: 0,
      createdAt: createdAt,
      isSale: true,
      isBalance: isBalance,
    );

// 1 Nov ko wada: 5 Nov tak de dega.
final oldPromise = DueFollowUp(
  id: 1,
  partyId: 1,
  method: FollowUpMethod.call,
  outcome: FollowUpOutcome.promised,
  promiseDate: at(11, 5),
  createdAt: at(11, 1),
);

void main() {
  test('debtSince = oldest remaining bill; a balance row means unknown (0)', () {
    final p = groupDueByParty([bill('B2', at(11, 14)), bill('B1', at(11, 12))]).first;
    expect(p.debtSince, at(11, 12));
    final withOpening = groupDueByParty([bill('B2', at(11, 14)), bill('OB', 0, isBalance: true)]).first;
    expect(withOpening.debtSince, 0);
  });

  test('entriesForCurrentDebt drops contacts from before the current debt', () {
    final newer = DueFollowUp(
        id: 2, partyId: 1, method: FollowUpMethod.whatsapp, outcome: FollowUpOutcome.sent, createdAt: at(11, 15));
    expect(entriesForCurrentDebt([oldPromise, newer], at(11, 14)).map((e) => e.id).toList(), [2]);
    expect(entriesForCurrentDebt([oldPromise, newer], 0).length, 2);
  });

  test('Old debt still open: the old broken promise still counts', () {
    // 1 Oct ka bill abhi bhi baqi (wada usi ke liye tha).
    final p = groupDueByParty([bill('OLD', at(10, 1))]).first;
    final q = buildAutopilot([p], {1: [oldPromise]}, nowMillis: now);
    expect(q.todo.single.reason, TouchReason.brokenPromise);
  });

  test('Paid everything, then bought again: NOT "promise broken" for the new bill', () {
    // Purana sab ada; FIFO ke baad sirf 14 Nov ka naya bill bacha.
    final p = groupDueByParty([bill('NEW', at(11, 14))]).first;
    final q = buildAutopilot([p], {1: [oldPromise]}, nowMillis: now);
    expect(q.todo.where((i) => i.reason == TouchReason.brokenPromise), isEmpty);
  });

  test('Credit warning ignores the old promise once the old debt is cleared', () {
    final r = creditRiskFor(bills: [bill('NEW', at(11, 14))], entries: [oldPromise], nowMillis: now);
    expect(r.promiseBroken, isFalse);
    final stillOld = creditRiskFor(bills: [bill('OLD', at(10, 1))], entries: [oldPromise], nowMillis: now);
    expect(stillOld.promiseBroken, isTrue);
  });
}
