import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ghalat password / kharab file — UI seedha `message` dikha sakti hai.
class BackupCryptoException implements Exception {
  final String message;
  const BackupCryptoException(this.message);
  @override
  String toString() => message;
}

/// Mirrors BackupCrypto.kt — AES-256-GCM, password se key (PBKDF2-HMAC-SHA256).
///
/// File format (Android ke saath BYTE-FOR-BYTE compatible):
///   [4  bytes] magic "IBB1"
///   [16 bytes] PBKDF2 salt
///   [12 bytes] GCM IV (nonce)
///   [baaqi   ] AES-GCM ciphertext + 16-byte auth tag (end mein)
/// PBKDF2: 120,000 iterations, 256-bit key, password UTF-8.
///
/// Purane Android backups ("IBAKV001", AES-CBC, 100k iterations, IV 16 bytes) sirf
/// restore ke liye [decryptLegacyCbc] se padhe jate hain (Kotlin `decryptFileLegacyCbc`).
///
/// Farq (Kotlin se): poori file memory mein (shop DB chhoti hoti hai) aur PBKDF2 alag
/// isolate mein chalta hai taake UI na atke.
class BackupCrypto {
  BackupCrypto._();

  static const List<int> magic = [0x49, 0x42, 0x42, 0x31]; // "IBB1"
  static const List<int> legacyMagic = [0x49, 0x42, 0x41, 0x4B, 0x56, 0x30, 0x30, 0x31]; // "IBAKV001"
  static const int saltLen = 16;
  static const int ivLen = 12;
  static const int tagLen = 16;
  static const int pbkdf2Iterations = 120000;
  static const int legacyIvLen = 16;
  static const int legacyIterations = 100000;

  static Future<SecretKey> _deriveKey(String password, List<int> salt, int iterations) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static bool _startsWith(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  // ---------------- pure (bytes) API — test ke liye bhi ----------------

  /// [plain] ko [password] se encrypt kar ke poori IBB1 file ke bytes deta hai.
  static Future<Uint8List> encryptBytes(Uint8List plain, String password) async {
    final salt = _randomBytes(saltLen);
    final iv = _randomBytes(ivLen);
    final key = await _deriveKey(password, salt, pbkdf2Iterations);
    final box = await AesGcm.with256bits().encrypt(plain, secretKey: key, nonce: iv);
    final out = BytesBuilder(copy: false)
      ..add(magic)
      ..add(salt)
      ..add(iv)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// IBB1 file ke bytes ko decrypt karta hai. Ghalat password / tamper => [BackupCryptoException].
  static Future<Uint8List> decryptBytes(Uint8List file, String password) async {
    if (!_startsWith(file, magic)) {
      throw const BackupCryptoException('Ye file encrypted IBTISAAM backup nahi hai');
    }
    const headerLen = 4 + saltLen + ivLen;
    if (file.length < headerLen + tagLen) {
      throw const BackupCryptoException('Backup file adhoori ya kharab hai');
    }
    final salt = file.sublist(4, 4 + saltLen);
    final iv = file.sublist(4 + saltLen, headerLen);
    final cipherText = file.sublist(headerLen, file.length - tagLen);
    final tag = file.sublist(file.length - tagLen);
    final key = await _deriveKey(password, salt, pbkdf2Iterations);
    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: iv, mac: Mac(tag)),
        secretKey: key,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const BackupCryptoException('Password ghalat hai ya backup file kharab hai');
    }
  }

  /// Purana "IBAKV001" (AES-CBC) backup — sirf restore ke liye.
  static Future<Uint8List> decryptLegacyCbc(Uint8List file, String password) async {
    const headerLen = 8 + saltLen + legacyIvLen;
    if (!_startsWith(file, legacyMagic) || file.length <= headerLen) {
      throw const BackupCryptoException('Ye file encrypted IBTISAAM backup nahi hai');
    }
    final salt = file.sublist(8, 8 + saltLen);
    final iv = file.sublist(8 + saltLen, headerLen);
    final cipherText = file.sublist(headerLen);
    final key = await _deriveKey(password, salt, legacyIterations);
    try {
      final plain = await AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty).decrypt(
        SecretBox(cipherText, nonce: iv, mac: Mac.empty),
        secretKey: key,
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      // CBC mein auth tag nahi — ghalat password aksar bad padding deta hai.
      throw const BackupCryptoException('Password ghalat hai ya backup file kharab hai');
    }
  }

  // ---------------- file API (Kotlin ke naam) ----------------

  static Future<void> encryptFile(File input, File output, String password) async {
    final plain = await input.readAsBytes();
    final encrypted = await Isolate.run(() => encryptBytes(plain, password));
    await output.writeAsBytes(encrypted, flush: true);
  }

  static Future<void> decryptFile(File input, File output, String password) async {
    final data = await input.readAsBytes();
    final plain = await Isolate.run(() => decryptBytes(data, password));
    await output.writeAsBytes(plain, flush: true);
  }

  static Future<void> decryptLegacyFile(File input, File output, String password) async {
    final data = await input.readAsBytes();
    final plain = await Isolate.run(() => decryptLegacyCbc(data, password));
    await output.writeAsBytes(plain, flush: true);
  }

  /// Sirf header parhta hai — `isEncryptedBackup()` ka barabar (new IBB1).
  static Future<bool> isEncryptedBackup(File file) => _headerMatches(file, magic);

  /// Purana IBAKV001 CBC format.
  static Future<bool> isLegacyEncryptedBackup(File file) => _headerMatches(file, legacyMagic);

  static Future<bool> _headerMatches(File file, List<int> expected) async {
    try {
      final raf = await file.open();
      try {
        final head = await raf.read(expected.length);
        return head.length == expected.length && _startsWith(head, expected);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }
}
