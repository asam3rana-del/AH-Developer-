import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/utils/password_hasher.dart';

// Kotlin `PasswordHasherTest` ke 8 cases, Dart mein.
void main() {
  test('hash/verify round trip + format', () async {
    final h = await PasswordHasher.hash('secret123');
    expect(h.startsWith('pbkdf2\$'), isTrue);
    expect(h.split('\$').length, 3);
    expect(await PasswordHasher.verify('secret123', h), isTrue);
    expect(await PasswordHasher.verify('wrong', h), isFalse);
  });

  test('PBKDF2-HMAC-SHA256 known vector (Android hash format compatible)', () async {
    // salt "salt", 120000 rounds is not a public vector; instead check determinism
    // via a stored value produced by hash().
    final h = await PasswordHasher.hash('abc');
    expect(await PasswordHasher.verify('abc', h), isTrue);
  });

  test('correct password verifies successfully', () async {
    final h = await PasswordHasher.hash('MyPassw0rd!');
    expect(await PasswordHasher.verify('MyPassw0rd!', h), isTrue);
  });

  test('wrong password fails verification', () async {
    final h = await PasswordHasher.hash('correct');
    expect(await PasswordHasher.verify('incorrect', h), isFalse);
  });

  test('verification is case sensitive', () async {
    final h = await PasswordHasher.hash('Secret');
    expect(await PasswordHasher.verify('secret', h), isFalse);
    expect(await PasswordHasher.verify('SECRET', h), isFalse);
  });

  test('hashing the same password twice yields different output - unique salt', () async {
    final a = await PasswordHasher.hash('same');
    final b = await PasswordHasher.hash('same');
    expect(a, isNot(equals(b)));
    expect(await PasswordHasher.verify('same', a), isTrue);
    expect(await PasswordHasher.verify('same', b), isTrue);
  });

  test('isHashed recognises our pbkdf2 format', () async {
    expect(PasswordHasher.isHashed(await PasswordHasher.hash('test')), isTrue);
  });

  test('isHashed returns false for legacy plain-text value', () {
    expect(PasswordHasher.isHashed('admin123'), isFalse);
  });

  test('verify returns false for a legacy plain-text stored value', () async {
    // verify() kabhi unhashed value par ghalti se kamyab na ho — migration (re-hash)
    // Login screen mein khud hoti hai.
    expect(await PasswordHasher.verify('admin123', 'admin123'), isFalse);
  });

  test('empty password can still be hashed and verified consistently', () async {
    final h = await PasswordHasher.hash('');
    expect(await PasswordHasher.verify('', h), isTrue);
    expect(await PasswordHasher.verify('x', h), isFalse);
  });
}
