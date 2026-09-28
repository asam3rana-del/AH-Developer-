import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Mirrors PasswordHasher.kt — SAME format `pbkdf2$<saltHex>$<hashHex>`
/// (PBKDF2-HMAC-SHA256, 120,000 rounds, 256-bit) taake Android aur Flutter
/// ke users dono apps mein chalein.
class PasswordHasher {
  PasswordHasher._();

  static const _prefix = 'pbkdf2\$';
  static const _iterations = 120000;

  static bool isHashed(String stored) => stored.startsWith(_prefix);

  /// Heavy kaam (120k rounds) alag isolate mein — UI freeze nahi hoti.
  static Future<String> hash(String plain) => compute(_hashSync, plain);

  static Future<bool> verify(String plain, String stored) =>
      compute(_verifySync, [plain, stored]);

  static String _hashSync(String plain) {
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
    return '$_prefix${_toHex(salt)}\$${_toHex(_pbkdf2(plain, salt))}';
  }

  static bool _verifySync(List<String> args) {
    final plain = args[0];
    final stored = args[1];
    if (!isHashed(stored)) return false;
    final parts = stored.substring(_prefix.length).split('\$');
    if (parts.length != 2) return false;
    final actual = _toHex(_pbkdf2(plain, _fromHex(parts[0])));
    return _constantTimeEquals(actual, parts[1]);
  }

  // PBKDF2 with a 32-byte output == exactly one HMAC-SHA256 block.
  static Uint8List _pbkdf2(String password, Uint8List salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final first = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt)
      ..[salt.length + 3] = 1; // block index 1 (big-endian)
    var u = Uint8List.fromList(hmac.convert(first).bytes);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < _iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    return t;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }

  static String _toHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String s) => Uint8List.fromList(
      List<int>.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));
}
