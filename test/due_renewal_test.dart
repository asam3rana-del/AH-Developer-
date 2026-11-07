import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/due_renewal.dart';

int d(int day, [int month = 3]) => DateTime(2026, month, day).millisecondsSinceEpoch;

void main() {
  final now = DateTime(2026, 3, 15, 14, 30).millisecondsSinceEpoch;

  test('customer ki default muddat pehle', () {
    expect(renewedDueDate(nowMillis: now, oldDue: d(10), createdAt: d(1), customerDays: 15), d(30));
  });

  test('warna bill ki apni muddat (due - bill date)', () {
    // 1 Mar ko bill, 11 Mar due => 10 din muddat => aaj (15 Mar) + 10 = 25 Mar
    expect(renewedDueDate(nowMillis: now, oldDue: d(11), createdAt: d(1)), d(25));
  });

  test('muddat 3..30 mein rakhi jati hai', () {
    expect(billTermDays(d(1), d(2)), 1);
    expect(renewedDueDate(nowMillis: now, oldDue: d(2), createdAt: d(1)), d(18)); // 3 din
    expect(renewedDueDate(nowMillis: now, oldDue: d(1, 6), createdAt: d(1)), d(1, 6)); // aage hi hai
  });

  test('muddat pata na ho to 7 din', () {
    expect(renewedDueDate(nowMillis: now, oldDue: d(10), createdAt: 0), d(22));
  });

  test('date set nahi to kuch nahi badla, aur date kabhi peeche nahi', () {
    expect(renewedDueDate(nowMillis: now, oldDue: 0, createdAt: d(1)), 0);
    expect(renewedDueDate(nowMillis: now, oldDue: d(28), createdAt: d(1), customerDays: 3), d(28));
  });
}
