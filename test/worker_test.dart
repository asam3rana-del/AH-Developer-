import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/worker_repository.dart';

void main() {
  test('din/mahine ki chabi', () {
    expect(workerDayKey(DateTime(2026, 10, 5)), '2026-10-05');
    expect(workerMonthKey(2026, 3), '2026-03');
    expect(daysInMonth(2026, 2), 28);
    expect(daysInMonth(2028, 2), 29);
    expect(daysInMonth(2026, 10), 31);
  });

  test('hazri ginti: khali din alag', () {
    final c = attendanceCounts({1: 'P', 2: 'A', 3: 'H', 4: 'L', 5: 'P'}, 2026, 10);
    expect(c.present, 2);
    expect(c.absent, 1);
    expect(c.half, 1);
    expect(c.paidLeave, 1);
    expect(c.unmarked, 26);
  });

  test('monthly: gair-hazri aur aadhe din ki katauti, khali din hazir', () {
    // 31 din ka mahina, 31000 salary => 1000 roz. 2 gair-hazir + 1 aadha = 2.5 din = 2500 katauti.
    final c = attendanceCounts({1: 'A', 2: 'A', 3: 'H', 4: 'L'}, 2026, 10);
    final r = computeEarned(payType: workerMonthly, rate: 31000, year: 2026, month: 10, counts: c);
    expect(r.deduction, 2500);
    expect(r.earned, 28500);
    expect(r.days, 2.5);
  });

  test('monthly: koi chhutti nahi to poori salary; katauti salary se zyada nahi', () {
    final none = attendanceCounts({}, 2026, 10);
    expect(computeEarned(payType: workerMonthly, rate: 20000, year: 2026, month: 10, counts: none).earned, 20000);
    final all = attendanceCounts({for (var d = 1; d <= 31; d++) d: 'A'}, 2026, 10);
    final r = computeEarned(payType: workerMonthly, rate: 20000, year: 2026, month: 10, counts: all);
    expect(r.earned, 0);
    expect(r.deduction, 20000);
  });

  test('daily: sirf likhe hue hazir/paid chhutti/aadhe din ginay jate hain', () {
    final c = attendanceCounts({1: 'P', 2: 'P', 3: 'H', 4: 'L', 5: 'A'}, 2026, 10);
    final r = computeEarned(payType: workerDaily, rate: 800, year: 2026, month: 10, counts: c);
    expect(r.days, 3.5);
    expect(r.earned, 2800);
    expect(r.deduction, 0);
  });

  test('daily: kuch na likha ho to kamai 0', () {
    final r = computeEarned(payType: workerDaily, rate: 800, year: 2026, month: 10, counts: attendanceCounts({}, 2026, 10));
    expect(r.earned, 0);
  });
}
