import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/app_info.dart';
import 'package:ah_developer_kiryana_store/services/crash_reporter.dart';

void main() {
  test('clip keeps reports under the Firestore rule limit', () {
    final long = 'x' * 20000;
    expect(CrashReporter.clip(long).length, CrashReporter.maxChars);
    expect(CrashReporter.maxChars, lessThanOrEqualTo(8000));
    expect(CrashReporter.clip('short'), 'short');
  });

  test('fingerprint is stable and changes with the text', () {
    expect(CrashReporter.fingerprint('CRASH A'), CrashReporter.fingerprint('CRASH A'));
    expect(CrashReporter.fingerprint('CRASH A'), isNot(CrashReporter.fingerprint('CRASH B')));
  });

  test('WhatsApp link goes to the support number with a short text', () {
    final u = CrashReporter.whatsAppUri('E' * 10000);
    expect(u.host, 'wa.me');
    expect(u.path, '/${AppInfo.supportWhatsAppIntl}');
    expect(u.queryParameters['text']!.length, lessThan(3200));
    expect(u.queryParameters['text'], startsWith('${AppInfo.appName} crash report'));
  });
}
