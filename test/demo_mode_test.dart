import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/dashboard_repository.dart' show syncPendingMessage;
import 'package:ah_developer_kiryana_store/services/demo_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DemoMode.setEnabled(false);
  });

  tearDown(() async => DemoMode.setEnabled(false));

  test('Off by default: real shop file', () async {
    await DemoMode.init();
    expect(DemoMode.enabled, isFalse);
    expect(AppDatabase.databaseFileName, isNot(DemoMode.demoDbFileName));
  });

  test('On: a separate demo file, real file name never returned', () async {
    final real = AppDatabase.databaseFileName;
    await DemoMode.setEnabled(true);
    expect(AppDatabase.databaseFileName, DemoMode.demoDbFileName);
    expect(AppDatabase.databaseFileName, isNot(real));
    await DemoMode.setEnabled(false);
    expect(AppDatabase.databaseFileName, real);
  });

  test('Flag survives restart (prefs)', () async {
    await DemoMode.setEnabled(true);
    DemoMode.notifier.value = false; // naya process jaisa
    await DemoMode.init();
    expect(DemoMode.enabled, isTrue);
  });

  test('No "not yet synced" warning in demo', () async {
    expect(syncPendingMessage(5, urdu: false), isNotNull);
    await DemoMode.setEnabled(true);
    expect(syncPendingMessage(5, urdu: false), isNull);
  });
}
