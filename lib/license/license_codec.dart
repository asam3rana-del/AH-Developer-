import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// License key ka format — tools/license_tool.py ke bilkul mutabiq (wahan badlein to yahan bhi).
///
/// Key = "HP1-" + base32(16 byte payload + 64 byte Ed25519 signature), 4-4 harf ke group.
/// payload: [0] version=1, [1] plan, [2..3] expiry din (2024-01-01 se, big-endian; 0 = lifetime),
/// [4..5] issue din, [6..15] device ke 10 byte (Device ID).
enum LicensePlan { lifetime, yearly, monthly, days }

LicensePlan? planFromByte(int b) => switch (b) {
      1 => LicensePlan.lifetime,
      2 => LicensePlan.yearly,
      3 => LicensePlan.monthly,
      4 => LicensePlan.days,
      _ => null,
    };

class LicensePayload {
  const LicensePayload({required this.plan, required this.expiryDay, required this.issueDay, required this.device});
  final LicensePlan plan;

  /// 2024-01-01 se din; 0 = lifetime. Is din se license band (aakhri chalne wala din = expiryDay - 1).
  final int expiryDay;
  final int issueDay;

  /// Device ke 10 byte.
  final Uint8List device;

  bool get isLifetime => expiryDay == 0;
}

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// RFC 4648 base32, bina '='.
String base32Encode(List<int> data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final byte in data) {
    buffer = (buffer << 8) | (byte & 0xff);
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

/// Ulta. Space / dash / chhote harf chalte hain; aam ghalti 0→O, 1→I, 8→B theek. Ghalat harf => null.
Uint8List? base32Decode(String text) {
  final t = text.toUpperCase().replaceAll('0', 'O').replaceAll('1', 'I').replaceAll('8', 'B');
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in t.split('')) {
    if (!RegExp(r'[A-Z0-9]').hasMatch(ch)) continue; // dash, space, newline
    final v = _alphabet.indexOf(ch);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
      buffer &= (1 << bits) - 1;
    }
  }
  return Uint8List.fromList(out);
}

String groupCode(String s, [int n = 4]) {
  final parts = <String>[];
  for (var i = 0; i < s.length; i += n) {
    parts.add(s.substring(i, i + n > s.length ? s.length : i + n));
  }
  return parts.join('-');
}

/// 10 byte -> "ABCD-EFGH-IJKL-MNOP".
String deviceCodeFromBytes(List<int> bytes) => groupCode(base32Encode(bytes));

/// Device ID text -> 10 byte (ghalat => null).
Uint8List? deviceBytesFromCode(String code) {
  final b = base32Decode(code);
  return (b == null || b.length != 10) ? null : b;
}

final _epoch = DateTime.utc(2024, 1, 1);

/// Mahalli (device ki) tareekh -> 2024-01-01 se din.
int dayNumber(DateTime local) => DateTime.utc(local.year, local.month, local.day).difference(_epoch).inDays;

DateTime dateFromDay(int day) => _epoch.add(Duration(days: day));

/// Key text -> (payload, signature bytes). Format ghalat => null (signature abhi check nahi).
({Uint8List payload, Uint8List signature})? splitKey(String key) {
  var k = key.trim().toUpperCase();
  if (k.startsWith('HP1')) k = k.substring(3);
  final raw = base32Decode(k);
  if (raw == null || raw.length != 80) return null;
  return (payload: Uint8List.sublistView(raw, 0, 16), signature: Uint8List.sublistView(raw, 16, 80));
}

LicensePayload? parsePayload(Uint8List p) {
  if (p.length != 16 || p[0] != 1) return null;
  final plan = planFromByte(p[1]);
  if (plan == null) return null;
  return LicensePayload(
    plan: plan,
    expiryDay: (p[2] << 8) | p[3],
    issueDay: (p[4] << 8) | p[5],
    device: Uint8List.fromList(p.sublist(6, 16)),
  );
}

/// Key ka signature [publicKey] (32 byte Ed25519) se theek ho to payload, warna null.
Future<LicensePayload?> verifyLicenseKey(String key, List<int> publicKey) async {
  final parts = splitKey(key);
  if (parts == null) return null;
  final payload = parsePayload(parts.payload);
  if (payload == null) return null;
  try {
    final ok = await Ed25519().verify(
      parts.payload,
      signature: Signature(parts.signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
    return ok ? payload : null;
  } catch (_) {
    return null;
  }
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
