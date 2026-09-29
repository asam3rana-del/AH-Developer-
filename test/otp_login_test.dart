import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/services/otp_login.dart';
import 'package:ah_developer_kiryana_store/utils/password_hasher.dart';

User _u(String name, {String phone = '', bool active = true, String hash = 'x'}) => User(
      username: name,
      displayName: name,
      role: 'cashier',
      passwordHash: hash,
      active: active,
      phone: phone,
    );

/// Phase 10: Phone OTP login ka logic (Kotlin LoginActivity `verifyAndLogin` /
/// `askPasswordBeforeFirstPhoneLink`). Firebase wala hissa (PhoneOtpAuth) device par dekhein.
void main() {
  group('resolveOtpUser', () {
    test('phone kisi active user se linked => seedha login', () {
      final a = _u('ali', phone: '+923001234567');
      final r = resolveOtpUser(byPhone: a, activeUsers: [a, _u('bilal')]);
      expect(r.kind, OtpOutcomeKind.login);
      expect(r.user?.username, 'ali');
    });

    test('linked user inactive ho to login nahi', () {
      final a = _u('ali', phone: '+923001234567', active: false);
      final r = resolveOtpUser(byPhone: a, activeUsers: [_u('bilal'), _u('sara')]);
      expect(r.kind, OtpOutcomeKind.notLinked);
      expect(r.user, isNull);
    });

    test('phone linked nahi + sirf ek active user => password puchh kar link', () {
      final only = _u('admin');
      final r = resolveOtpUser(byPhone: null, activeUsers: [only]);
      expect(r.kind, OtpOutcomeKind.linkNeedsPassword);
      expect(r.user?.username, 'admin');
    });

    test('phone linked nahi + kayi users => notLinked (koi account khud-ba-khud nahi bandhta)', () {
      final r = resolveOtpUser(byPhone: null, activeUsers: [_u('a'), _u('b')]);
      expect(r.kind, OtpOutcomeKind.notLinked);
    });

    test('koi active user nahi => notLinked', () {
      expect(resolveOtpUser(byPhone: null, activeUsers: const []).kind, OtpOutcomeKind.notLinked);
    });
  });

  group('verifyLinkPassword', () {
    test('hashed password: sahi true, ghalat false', () async {
      final h = await PasswordHasher.hash('secret123');
      final u = _u('admin', hash: h);
      expect(await verifyLinkPassword(u, 'secret123'), isTrue);
      expect(await verifyLinkPassword(u, 'wrong'), isFalse);
      expect(await verifyLinkPassword(u, ''), isFalse);
    });

    test('purani plain-text password barabari se', () async {
      final u = _u('admin', hash: 'plain1');
      expect(await verifyLinkPassword(u, 'plain1'), isTrue);
      expect(await verifyLinkPassword(u, 'plain2'), isFalse);
    });
  });

  group('input checks', () {
    test('OTP code 6 hindson ka (trim ke baad)', () {
      expect(isValidOtpCode('123456'), isTrue);
      expect(isValidOtpCode(' 123456 '), isTrue);
      expect(isValidOtpCode('12345'), isFalse);
      expect(isValidOtpCode('1234567'), isFalse);
      expect(isValidOtpCode(''), isFalse);
    });

    test('phone khali na ho', () {
      expect(isPhoneEntered('+923001234567'), isTrue);
      expect(isPhoneEntered('   '), isFalse);
      expect(isPhoneEntered(''), isFalse);
    });
  });

  test('OtpException.toString sirf message deta hai', () {
    expect(const OtpException('boom').toString(), 'boom');
  });
}
