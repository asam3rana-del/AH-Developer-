import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ah_developer_kiryana_store/services/crash_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('format mirrors Kotlin CRASH header (12-hour stamp)', () {
    final t = CrashHandler.format('Flutter framework', StateError('boom'), null, DateTime(2026, 9, 30, 15, 4, 9));
    expect(t.startsWith('CRASH at 30/09/2026 03:04:09 PM\nThread: Flutter framework'), isTrue);
    expect(t.contains('boom'), isTrue);
  });

  test('preview truncates past 3000 chars', () {
    expect(CrashHandler.preview('a' * 10), 'a' * 10);
    expect(CrashHandler.preview('a' * 3500).contains('truncated'), isTrue);
  });

  test('getLastCrash / clearLastCrash round trip', () async {
    SharedPreferences.setMockInitialValues({'last_crash_text': 'CRASH x'});
    expect(await CrashHandler.getLastCrash(), 'CRASH x');
    await CrashHandler.clearLastCrash();
    expect(await CrashHandler.getLastCrash(), isNull);
  });
}
