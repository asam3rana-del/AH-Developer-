import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mirrors BackupPasswordStore.kt — backup password Keystore (Android) / Keychain (iOS)
/// mein; plain SharedPreferences mein kabhi nahi.
///
/// Ye password device-local store hota hai. Doosre phone par restore ke liye owner ko
/// password khud likh kar rakhna hoga — restore screen wahan password poochti hai.
class BackupPasswordStore {
  BackupPasswordStore._();

  static const _keyPassword = 'backup_password_enc';
  static const _chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  static const minLength = 8;

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Maujuda password, warna naya random 16-char bana kar store karta hai.
  static Future<String> getOrCreate() async {
    try {
      final existing = await _storage.read(key: _keyPassword);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (_) {
      // Keystore kharab / restore ke baad stale — neeche naya password ban jayega (Kotlin jaisa).
    }
    final pass = generateRandomPassword();
    await _storage.write(key: _keyPassword, value: pass);
    return pass;
  }

  static Future<void> setPassword(String newPassword) async {
    if (newPassword.length < minLength) {
      throw ArgumentError('Backup password must be at least $minLength characters.');
    }
    await _storage.write(key: _keyPassword, value: newPassword);
  }

  static String generateRandomPassword([int length = 16]) {
    final r = Random.secure();
    return List.generate(length, (_) => _chars[r.nextInt(_chars.length)]).join();
  }
}
