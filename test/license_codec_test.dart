import 'dart:convert';

import 'package:ah_developer_kiryana_store/license/license_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ye keys `tools/license_tool.py` (Python) ne TEST private key (bytes 0..31) se banayi hain —
/// Dart aur Python ka format / signature ek jaisa rahe (asal key yahan nahi).
const _testPub = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const _device = 'AEBA-GBAF-AYDQ-QCIK'; // bytes 1..10
const _yearly =
    'HP1-AEBA-LDQE-EEAQ-EAYE-AUDA-OCAJ-BL3R-WV53-2NUO-M53W-2YV7-KY54-SEA4-SSRP-GVC4-JBNQ-C4DZ-WUYA-FR2P-35U7-F5KJ-OU7O-LZKG-XZW6-WWI3-XZNY-SKP3-WIMG-EYMV-F6G4-I5SR-CNQE';
const _lifetime =
    'HP1-AEAQ-AAAE-EEAQ-EAYE-AUDA-OCAJ-BJQQ-LVTQ-GYGU-CMP2-TABW-OQNC-TKGP-H5D2-6R7M-O3WZ-CCN6-VSYT-O5AL-OPVF-PUJO-E3WE-KNCM-QWVU-P5P6-5NWL-SHH7-HII5-RLCF-BCKW-ZYQH-P4YO';
const _otherDevice =
    'HP1-AEBQ-LDQE-EEEQ-SCIJ-BEEQ-SCIJ-BHCI-RQXN-NOE3-ZJ6H-SBVM-LFGN-3FF4-QWQR-B7NS-DKKG-WISL-3WV7-AMKS-NIDJ-TEK5-5RGL-ZM6S-XS7K-UCRM-2Q35-EJ7D-7GPR-D2SJ-HD7X-CJL3-H7IG';

void main() {
  final pub = base64.decode(_testPub);

  test('base32 Python jaisa', () {
    expect(base32Encode(utf8.encode('Hanna POS!')), 'JBQW43TBEBIE6UZB');
    expect(utf8.decode(base32Decode('jbqw-43tb ebie-6uzb')!), 'Hanna POS!');
    expect(deviceCodeFromBytes(List<int>.generate(10, (i) => i + 1)), _device);
    expect(deviceBytesFromCode(_device), List<int>.generate(10, (i) => i + 1));
    expect(deviceBytesFromCode('ABC'), isNull);
  });

  test('din ka hisaab Python jaisa (2024-01-01 se)', () {
    expect(dayNumber(DateTime(2024, 1, 1)), 0);
    expect(dayNumber(DateTime(2026, 11, 23, 23, 59)), 1057);
    expect(dayNumber(DateTime(2027, 11, 23)), 1422);
    expect(dateFromDay(1422), DateTime.utc(2027, 11, 23));
  });

  test('saalana key theek padhi jati hai', () async {
    final l = await verifyLicenseKey(_yearly, pub);
    expect(l, isNotNull);
    expect(l!.plan, LicensePlan.yearly);
    expect(l.expiryDay, 1422);
    expect(l.issueDay, 1057);
    expect(l.isLifetime, isFalse);
    expect(sameBytes(l.device, deviceBytesFromCode(_device)!), isTrue);
  });

  test('lifetime key; chhote harf / space / bina HP1 bhi chalti hai', () async {
    final l = await verifyLicenseKey(_lifetime.toLowerCase().replaceAll('-', ' ').replaceFirst('hp1 ', ''), pub);
    expect(l, isNotNull);
    expect(l!.plan, LicensePlan.lifetime);
    expect(l.isLifetime, isTrue);
  });

  test('dusre device ki key: signature theek magar device alag', () async {
    final l = await verifyLicenseKey(_otherDevice, pub);
    expect(l, isNotNull);
    expect(l!.plan, LicensePlan.monthly);
    expect(sameBytes(l.device, deviceBytesFromCode(_device)!), isFalse);
  });

  test('chhedi hui key / ghalat public key / kachra => null', () async {
    // Expiry badal kar lambi karne ki koshish (ek harf badla).
    final tampered = _yearly.replaceRange(9, 10, _yearly[9] == 'L' ? 'M' : 'L');
    expect(await verifyLicenseKey(tampered, pub), isNull);
    final wrongPub = List<int>.from(pub)..[0] ^= 1;
    expect(await verifyLicenseKey(_yearly, wrongPub), isNull);
    expect(await verifyLicenseKey('HP1-ABCD', pub), isNull);
    expect(await verifyLicenseKey('', pub), isNull);
    expect(await verifyLicenseKey('hello world 9999', pub), isNull);
  });
}
