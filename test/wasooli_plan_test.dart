import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/due_reminders_repository.dart';
import 'package:ah_developer_kiryana_store/models/due_followup.dart';
import 'package:ah_developer_kiryana_store/models/wasooli_plan.dart';

// 16 Nov 2026, 10:00.
final now = DateTime(2026, 11, 16, 10).millisecondsSinceEpoch;
int day(int m, int d) => DateTime(2026, m, d).millisecondsSinceEpoch;
int at(int m, int d, [int h = 12]) => DateTime(2026, m, d, h).millisecondsSinceEpoch;

DueParty party({int dueDate = 0, int createdAt = 0, double total = 10000}) => DueParty(
      partyId: 1,
      partyName: 'Zulfiqar',
      partyPhone: '0300',
      isSale: true,
      bills: [
        DueBill(
          id: 'S1',
          partyId: 1,
          partyName: 'Zulfiqar',
          partyPhone: '0300',
          total: total,
          paid: 0,
          dueDate: dueDate,
          createdAt: createdAt == 0 ? at(10, 29) : createdAt,
          isSale: true,
        ),
      ],
    );

DueFollowUp f(int createdAt, String outcome, {int promiseDate = 0, double amount = 0, int next = 0}) =>
    DueFollowUp(partyId: 1, outcome: outcome, promiseDate: promiseDate, amount: amount, nextFollowUp: next, createdAt: createdAt);

void main() {
  test('bill due date guzri => Late, din ginti', () {
    final r = buildWasooliRow(party(dueDate: day(11, 5)), const [], nowMillis: now);
    expect(r.urgency, WasooliUrgency.late);
    expect(r.kind, WasooliDateKind.bill);
    expect(r.days, 11);
  });

  test('naya wada (aage) bill ki late tareekh par bhari: Aage, wada', () {
    final r = buildWasooliRow(
      party(dueDate: day(11, 5)),
      [
        f(at(11, 6), FollowUpOutcome.promised, promiseDate: day(11, 13), amount: 5000),
        f(at(11, 16, 9), FollowUpOutcome.promised, promiseDate: day(11, 20), amount: 5000),
      ],
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.later);
    expect(r.kind, WasooliDateKind.promise);
    expect(r.date, day(11, 20));
    expect(r.days, 4);
    expect(r.amount, 5000);
    // Purana (13 Nov) wada kati hui line mein.
    expect(r.pastPromises.map((e) => e.promiseDate), [day(11, 13)]);
  });

  test('wada toota => Late aur ginti', () {
    final r = buildWasooliRow(
      party(dueDate: day(11, 20)),
      [f(at(11, 10), FollowUpOutcome.promised, promiseDate: day(11, 13))],
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.late);
    expect(r.kind, WasooliDateKind.promise);
    expect(r.days, 3);
    expect(r.brokenCount, 1);
  });

  test('thori payment + baqi ka wada: wada = poora baqi (mili raqam nahi)', () {
    final r = buildWasooliRow(
      party(dueDate: day(11, 5)),
      [f(at(11, 16, 9), FollowUpOutcome.partial, promiseDate: day(11, 19), amount: 2000)],
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.later);
    expect(r.kind, WasooliDateKind.promise);
    expect(r.amount, 0);
    expect(r.touchedToday, isTrue);
  });

  test('aaj ka wada => Aaj', () {
    final r = buildWasooliRow(
      party(dueDate: day(11, 30)),
      [f(at(11, 12), FollowUpOutcome.promised, promiseDate: day(11, 16))],
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.today);
  });

  test('bina-date bill: 7 din baad late, us se pehle Aage', () {
    final young = buildWasooliRow(party(createdAt: at(11, 12)), const [], nowMillis: now);
    expect(young.urgency, WasooliUrgency.later);
    expect(young.date, day(11, 19));
    final old = buildWasooliRow(party(createdAt: at(11, 1)), const [], nowMillis: now);
    expect(old.urgency, WasooliUrgency.late);
  });

  test('purane chukaye hue qarz ka toota wada naye bill par laagu nahi', () {
    final r = buildWasooliRow(
      party(dueDate: day(11, 22), createdAt: at(11, 15)),
      [f(at(10, 1), FollowUpOutcome.promised, promiseDate: day(10, 5))],
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.later);
    expect(r.kind, WasooliDateKind.bill);
    expect(r.brokenCount, 0);
  });

  test('tarteeb: Late (zyada din pehle) -> Aaj -> Aage', () {
    final a = buildWasooliRow(party(dueDate: day(11, 14)), const [], nowMillis: now); // late 2
    final b = buildWasooliRow(party(dueDate: day(11, 1)), const [], nowMillis: now); // late 15
    final c = buildWasooliRow(party(dueDate: day(11, 16)), const [], nowMillis: now); // aaj
    final d = buildWasooliRow(party(dueDate: day(11, 25)), const [], nowMillis: now); // aage
    final s = sortWasooli([d, c, a, b]);
    expect(s, [b, a, c, d]);
    final sum = summarizeWasooli(s);
    expect(sum.lateCount, 2);
    expect(sum.todayCount, 1);
  });

  test('purane bill ka chhota bacha hissa (Rs 60) party ko late nahi banata', () {
    // 7 Nov ka bill: Rs 60 bache; 12 Nov ka naya udhaar Rs 28,550 (due 19 Nov).
    final p = DueParty(partyId: 1, partyName: 'Akbar', partyPhone: '0312', isSale: true, bills: [
      DueBill(id: 'S1', partyId: 1, partyName: 'Akbar', partyPhone: '0312', total: 32060, paid: 32000,
          dueDate: day(11, 7), createdAt: at(10, 31), isSale: true),
      DueBill(id: 'S2', partyId: 1, partyName: 'Akbar', partyPhone: '0312', total: 28550, paid: 0,
          dueDate: day(11, 19), createdAt: at(11, 12), isSale: true),
    ]);
    final r = buildWasooliRow(
      p,
      [f(at(11, 1), FollowUpOutcome.promised, promiseDate: day(11, 5))], // purane qarz ka wada
      nowMillis: now,
    );
    expect(r.urgency, WasooliUrgency.later);
    expect(r.date, day(11, 19));
    expect(r.brokenCount, 0);
    expect(r.total, 28610);
  });

  test('bina-date bill par customer ki muddat laagu (7 nahi, 60 din)', () {
    final r = buildWasooliRow(party(createdAt: at(11, 1)), const [], nowMillis: now, customerDueDays: 60);
    expect(r.urgency, WasooliUrgency.later);
    expect(r.date, day(12, 31)); // 1 Nov + 60 din
    expect(r.dueDays, 60);
  });

  test('jaldi tareekhen', () {
    expect(quickPromiseDate('kal', nowMillis: now), day(11, 17));
    expect(quickPromiseDate('3din', nowMillis: now), day(11, 19));
    expect(quickPromiseDate('hafta', nowMillis: now), day(11, 23));
    expect(quickPromiseDate('mahina', nowMillis: now), day(11, 30));
    expect(quickPromiseDate('mahina', nowMillis: at(11, 30)), day(12, 31));
  });
}
