import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/services/app_update.dart';

void main() {
  const body = '''
{
  "android": {"version": "1.1.0", "build": 40, "url": "https://github.com/x/hanna-updates/releases/download/b40/app-release.apk", "notes": "Naqd sale"},
  "windows": {"version": "1.1.0", "build": 40, "url": "http://insecure.example/x.zip"},
  "min_build": 30
}''';

  test('parses the platform entry; https only', () {
    final a = parseUpdateInfo(body, 'android')!;
    expect(a.version, '1.1.0');
    expect(a.build, 40);
    expect(a.notes, 'Naqd sale');
    expect(a.minBuild, 30);
    expect(parseUpdateInfo(body, 'windows'), isNull); // http link nahi
    expect(parseUpdateInfo(body, 'ios'), isNull);
    expect(parseUpdateInfo('not json', 'android'), isNull);
    expect(parseUpdateInfo('[]', 'android'), isNull);
  });

  test('newer / required', () {
    final a = parseUpdateInfo(body, 'android')!;
    expect(a.newerThan(39), isTrue);
    expect(a.newerThan(40), isFalse);
    expect(a.requiredFor(25), isTrue);
    expect(a.requiredFor(35), isFalse);
    expect(a.requiredFor(40), isFalse);
  });
}
