import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/utility_bill_repository.dart';

int ms(int y, int m, int d) => DateTime(y, m, d).millisecondsSinceEpoch;

void main() {
  test('due date: chhote mahine mein aakhri din', () {
    expect(billDueDate(31, 2026, 2), DateTime(2026, 2, 28));
    expect(billDueDate(31, 2028, 2), DateTime(2028, 2, 29));
    expect(billDueDate(30, 2026, 4), DateTime(2026, 4, 30));
    expect(billDueDate(10, 2026, 10), DateTime(2026, 10, 10));
  });

  test('mahine ki chabi aur agla/pichla mahina', () {
    expect(billMonthKey(2026, 3), '2026-03');
    expect(billNextMonth(2026, 12), (year: 2027, month: 1));
    expect(billPrevMonth(2026, 1), (year: 2025, month: 12));
  });

  test('is mahine ka bill pay nahi hua: din baaki', () {
    final s = billStatus(
      dueDay: 25,
      createdAtMs: ms(2026, 1, 1),
      paidMonths: {'2026-09'},
      now: DateTime(2026, 10, 22, 10),
    );
    expect(s.month, '2026-10');
    expect(s.paid, false);
    expect(s.daysLeft, 3);
    expect(reminderStage(s), isNull);
  });

  test('ek din pehle / due din / guzar chuki: reminder ke marhale', () {
    BillStatus at(int day) => billStatus(
          dueDay: 25,
          createdAtMs: ms(2026, 1, 1),
          paidMonths: {'2026-09'},
          now: DateTime(2026, 10, day, 9),
        );
    expect(reminderStage(at(24)), 'pre');
    expect(at(24).dueTomorrow, true);
    expect(reminderStage(at(25)), 'due');
    expect(at(25).dueToday, true);
    expect(reminderStage(at(27)), 'over');
    expect(at(27).overdue, true);
    expect(at(27).daysLeft, -2);
  });

  test('pay ho gaya to reminder nahi', () {
    final s = billStatus(
      dueDay: 25,
      createdAtMs: ms(2026, 1, 1),
      paidMonths: {'2026-09', '2026-10'},
      now: DateTime(2026, 10, 24, 9),
    );
    expect(s.paid, true);
    expect(reminderStage(s), isNull);
  });

  test('pichle mahine ka bill baaki to wahi overdue dikhta hai', () {
    final s = billStatus(
      dueDay: 5,
      createdAtMs: ms(2026, 1, 1),
      paidMonths: {'2026-08'},
      now: DateTime(2026, 10, 2, 9),
    );
    expect(s.month, '2026-09');
    expect(s.overdue, true);
    expect(s.daysLeft, -27);
  });

  test('bill is mahine ki due date ke baad bana: agla mahina, purana overdue nahi', () {
    final s = billStatus(
      dueDay: 5,
      createdAtMs: ms(2026, 10, 20),
      paidMonths: {},
      now: DateTime(2026, 10, 22, 9),
    );
    expect(s.month, '2026-11');
    expect(s.paid, false);
    expect(s.daysLeft, 14);
  });

  test('saal badalne par: December ka bill, January mein check', () {
    final s = billStatus(
      dueDay: 28,
      createdAtMs: ms(2025, 1, 1),
      paidMonths: {'2025-11'},
      now: DateTime(2026, 1, 3, 9),
    );
    expect(s.month, '2025-12');
    expect(s.overdue, true);
  });

  test('stamp: ek bill + mahina + marhala ek hi baar, over roz', () {
    // stampFor BillReminderService mein hai; yahan sirf pure logic ki consistency dekhi.
    final a = billStatus(
        dueDay: 25, createdAtMs: ms(2026, 1, 1), paidMonths: {'2026-09'}, now: DateTime(2026, 10, 24, 9));
    final b = billStatus(
        dueDay: 25, createdAtMs: ms(2026, 1, 1), paidMonths: {'2026-09'}, now: DateTime(2026, 10, 25, 9));
    expect(a.month, b.month);
    expect(reminderStage(a), isNot(reminderStage(b)));
  });

  test('list ki tarteeb: overdue, phir qareeb wali due date, paid aakhir mein', () {
    BillView v(String name, int dueDay, Set<String> paid) => BillView(
          bill: UtilityBill(id: 1, name: name, dueDay: dueDay, createdAt: ms(2026, 1, 1)),
          status: billStatus(dueDay: dueDay, createdAtMs: ms(2026, 1, 1), paidMonths: paid, now: DateTime(2026, 10, 22, 9)),
        );
    final list = [
      v('Paid one', 10, {'2026-09', '2026-10'}),
      v('Later', 28, {'2026-09'}),
      v('Late', 15, {'2026-09'}),
      v('Soon', 24, {'2026-09'}),
    ]..sort(compareBillViews);
    expect(list.map((e) => e.bill.name).toList(), ['Late', 'Soon', 'Later', 'Paid one']);
  });

  test('suggested amount: aakhri payment, warna average', () {
    final b = UtilityBill(id: 1, name: 'LESCO', dueDay: 10, avgAmount: 5000, createdAt: ms(2026, 1, 1));
    final st = billStatus(dueDay: 10, createdAtMs: b.createdAt, paidMonths: {}, now: DateTime(2026, 10, 1));
    expect(BillView(bill: b, status: st).suggestedAmount, 5000);
    expect(BillView(bill: b, status: st, lastAmount: 6200).suggestedAmount, 6200);
  });
}
