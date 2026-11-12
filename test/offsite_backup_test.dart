import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/backup/offsite_backup.dart';

void main() {
  final night = DateTime(2026, 11, 12, 21, 30);

  test('Before 9 PM: no reminder', () {
    expect(shouldRemindOffsite(now: DateTime(2026, 11, 12, 20, 59), lastSharedMillis: 0), isFalse);
  });

  test('After 9 PM, never shared: remind', () {
    expect(shouldRemindOffsite(now: night, lastSharedMillis: 0), isTrue);
  });

  test('Only once a day', () {
    expect(shouldRemindOffsite(now: night, lastSharedMillis: 0, lastReminderDate: '2026-11-12'), isFalse);
    expect(shouldRemindOffsite(now: night, lastSharedMillis: 0, lastReminderDate: '2026-11-11'), isTrue);
  });

  test('Shared in the last ~20 hours: no reminder', () {
    final at = DateTime(2026, 11, 12, 8).millisecondsSinceEpoch;
    expect(shouldRemindOffsite(now: night, lastSharedMillis: at), isFalse);
    final yesterday = DateTime(2026, 11, 11, 21).millisecondsSinceEpoch;
    expect(shouldRemindOffsite(now: night, lastSharedMillis: yesterday), isTrue);
  });

  test('Days since shared and message', () {
    expect(daysSinceShared(0, now: night), -1);
    expect(daysSinceShared(DateTime(2026, 11, 9, 21).millisecondsSinceEpoch, now: night), 3);
    expect(offsiteReminderBody(-1), contains('kabhi'));
    expect(offsiteReminderBody(3), contains('3 din'));
  });
}
