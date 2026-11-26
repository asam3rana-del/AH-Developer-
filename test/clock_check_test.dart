import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/sync/clock_check.dart';

/// Ghadi ki jaanch: server (Google HTTPS `Date`) se 1 ghante se zyada farq = sync band, saaf paigham.
void main() {
  const server = 1764000000000; // koi bhi tay waqt
  late int device;

  setUp(() {
    ClockCheck.resetForTest();
    device = server;
    ClockCheck.deviceNow = () => device;
    ClockCheck.serverNow = () async => server;
  });
  tearDown(() {
    ClockCheck.resetForTest();
    ClockCheck.deviceNow = () => DateTime.now().millisecondsSinceEpoch;
  });

  test('sahi ghadi (ya thora farq) => koi masla nahi', () async {
    expect(await ClockCheck.problem(), isNull);
    ClockCheck.resetForTest();
    device = server + 50 * 60 * 1000; // 50 minute aage
    expect(await ClockCheck.problem(), isNull);
  });

  test('ghadi aage (2030 jaisi) => sync band, "aage" likha', () async {
    device = server + 4 * 365 * 24 * 3600 * 1000;
    final m = await ClockCheck.problem();
    expect(m, isNotNull);
    expect(m, contains('aage'));
  });

  test('ghadi 13 ghante peeche (PC wala masla) => sync band, "peeche" likha', () async {
    device = server - 13 * 3600 * 1000;
    final m = await ClockCheck.problem();
    expect(m, contains('13 ghante peeche'));
  });

  test('net nahi / header nahi => rokte nahi', () async {
    ClockCheck.serverNow = () async => null;
    device = server + 10 * 24 * 3600 * 1000;
    expect(await ClockCheck.problem(), isNull);
  });

  test('ghalat ghadi theek karne ke baad agli jaanch foran dobara naapti hai', () async {
    device = server - 13 * 3600 * 1000;
    expect(await ClockCheck.problem(), isNotNull);
    device = server; // user ne ghadi theek ki
    expect(await ClockCheck.problem(), isNull);
  });

  test('sahi naap 30 minute yaad: har sync par network nahi', () async {
    var calls = 0;
    ClockCheck.serverNow = () async {
      calls++;
      return server;
    };
    await ClockCheck.problem();
    await ClockCheck.problem();
    expect(calls, 1);
  });
}
