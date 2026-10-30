import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mirrors BackupPasswordStore.kt — backup password Keystore (Android) / Keychain (iOS)
/// mein; plain SharedPreferences mein kabhi nahi.
///
/// Ye password device-local store hota hai. Doosre phone par restore ke liye owner ko
/// password khud likh kar rakhna hoga — restore screen wahan password poochti hai.
/// Keystore se password parha nahi ja saka (reinstall / phone change / OS update ke baad stale Keystore).
/// Is waqt naya password NAHI banta — warna purane saare backups khulne se rah jate.
class BackupPasswordUnavailableException implements Exception {
  final String message;
  const BackupPasswordUnavailableException([
    this.message = 'Backup password phone ke Keystore se parha nahi ja saka. '
        'Naya password nahi banaya gaya taake purane backups na bigdein. '
        'Backup password screen se apna likha hua password dobara set karein.',
  ]);
  @override
  String toString() => message;
}

class BackupPasswordStore {
  BackupPasswordStore._();

  static const _keyPassword = 'backup_password_enc';
  static const _chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  static const minLength = 8;

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyAck = 'backup_password_ack';

  /// Maujuda password. Naya random password SIRF tab banta hai jab Keystore sahi chal raha ho
  /// aur password waqai maujood na ho (pehli dafa). Read fail ho to [BackupPasswordUnavailableException].
  static Future<String> getOrCreate() async {
    String? existing;
    try {
      existing = await _storage.read(key: _keyPassword);
    } catch (_) {
      throw const BackupPasswordUnavailableException();
    }
    if (existing != null && existing.isNotEmpty) return existing;
    final pass = generateRandomPassword();
    await _storage.write(key: _keyPassword, value: pass);
    return pass;
  }

  /// Sirf parhta hai (kabhi naya nahi banata). Maujood na ho ya read fail ho => null.
  static Future<String?> peek() async {
    try {
      final v = await _storage.read(key: _keyPassword);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Kya owner ne password dekh kar "maine likh liya" confirm kar diya hai?
  static Future<bool> isAcknowledged() async {
    try {
      return await _storage.read(key: _keyAck) == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> markAcknowledged() async {
    try {
      await _storage.write(key: _keyAck, value: '1');
    } catch (_) {}
  }

  static Future<void> setPassword(String newPassword) async {
    if (newPassword.length < minLength) {
      throw ArgumentError('Backup password must be at least $minLength characters.');
    }
    await _storage.write(key: _keyPassword, value: newPassword);
    await markAcknowledged(); // owner ne khud likha hai
  }

  static String generateRandomPassword([int length = 16]) {
    final r = Random.secure();
    return List.generate(length, (_) => _chars[r.nextInt(_chars.length)]).join();
  }
}
