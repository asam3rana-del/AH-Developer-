import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'license_codec.dart';
import 'license_config.dart';

enum LicenseStatus {
  /// Theek key, muddat baqi (ya lifetime).
  active,

  /// Key nahi, muft din baqi.
  trial,

  /// Key ki muddat khatam.
  expired,

  /// Muft din khatam, key nahi.
  trialOver,

  /// Hanna Solutions ne online band kiya.
  blocked,

  /// Device ki tareekh peeche ki gayi (muddat lambi karne ki koshish) — tareekh theek karein.
  clockTampered,
}

class LicenseState {
  const LicenseState(this.status, {this.license, this.daysLeft, this.keyProblem});
  final LicenseStatus status;
  final LicensePayload? license;

  /// trial / active (lifetime nahi) mein baqi din. Lifetime => null.
  final int? daysLeft;

  /// Saved key ghalat / kisi aur device ki thi (trial phir bhi chal sakta hai).
  final String? keyProblem;

  bool get usable => status == LicenseStatus.active || status == LicenseStatus.trial;

  /// Jald khatam: upar yaad-dihani.
  bool get expiringSoon => usable && daysLeft != null && daysLeft! <= LicenseConfig.warnDays;
}

/// Hanna POS license: offline Ed25519 key (Device ID se bandhi) + trial + (optional) Hanna Solutions ke
/// Firebase se online band/key. Sab faisle [state] mein; UI (LicenseGate / LicenseScreen) usi ko sunta hai.
class LicenseService with WidgetsBindingObserver {
  LicenseService._();
  static final LicenseService instance = LicenseService._();

  final ValueNotifier<LicenseState> state = ValueNotifier(const LicenseState(LicenseStatus.trial));

  String _deviceCode = '';
  Uint8List _deviceBytes = Uint8List(10);
  String get deviceCode => _deviceCode;

  Timer? _timer;
  bool _started = false;

  static const _kKey = 'license_key';
  static const _kTrialStart = 'license_trial_start_day';
  static const _kLastSeen = 'license_last_seen_ms';
  static const _kRevoked = 'license_revoked';
  static const _kOnlineAt = 'license_online_check_ms';
  static const _kInstallId = 'license_install_id';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// main() mein runApp se pehle. Dobara bulane par sirf dobara hisaab.
  Future<void> init() async {
    if (!_started) {
      _started = true;
      try {
        await _initDevice();
      } catch (_) {}
      WidgetsBinding.instance.addObserver(this);
      _timer = Timer.periodic(const Duration(hours: 1), (_) => refresh(online: true));
    }
    await evaluate();
    unawaited(checkOnline());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) unawaited(refresh(online: true));
  }

  Future<void> refresh({bool online = false}) async {
    await evaluate();
    if (online) await checkOnline();
  }

  // ----------------------------------------------------------------- device id

  /// Device ID = sha256("hanna-pos-device|" + mashine ki pehchaan) ke pehle 10 byte.
  /// Windows: MachineGuid (reinstall par bhi wahi). Linux: /etc/machine-id. Android/iOS: pehli dafa ka
  /// random ID (secure storage + prefs) — app hata kar dobara lagane par naya ID => nayi key chahiye.
  Future<void> _initDevice() async {
    String? raw;
    if (!kIsWeb && Platform.isWindows) raw = await _windowsMachineGuid();
    if (!kIsWeb && Platform.isLinux) {
      try {
        raw = (await File('/etc/machine-id').readAsString()).trim();
      } catch (_) {}
    }
    if (raw == null || raw.isEmpty) raw = 'install:${await _installId()}';
    final digest = hash.sha256.convert(utf8.encode('hanna-pos-device|$raw')).bytes;
    _deviceBytes = Uint8List.fromList(digest.sublist(0, 10));
    _deviceCode = deviceCodeFromBytes(_deviceBytes);
  }

  Future<String?> _windowsMachineGuid() async {
    try {
      final r = await Process.run('reg', ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid'],
              runInShell: false)
          .timeout(const Duration(seconds: 5));
      final m = RegExp(r'MachineGuid\s+REG_SZ\s+([0-9A-Fa-f-]+)').firstMatch('${r.stdout}');
      return m?.group(1)?.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  Future<String> _installId() async {
    final p = await SharedPreferences.getInstance();
    String? id;
    try {
      id = await _secure.read(key: _kInstallId);
    } catch (_) {}
    id ??= p.getString(_kInstallId);
    if (id == null || id.isEmpty) id = const Uuid().v4();
    await p.setString(_kInstallId, id);
    try {
      await _secure.write(key: _kInstallId, value: id);
    } catch (_) {}
    return id;
  }

  // ----------------------------------------------------------------- hisaab

  Future<String?> _read(SharedPreferences p, String k) async {
    var v = p.getString(k);
    if (v == null || v.isEmpty) {
      try {
        v = await _secure.read(key: k);
      } catch (_) {}
    }
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _write(SharedPreferences p, String k, String? v) async {
    if (v == null) {
      await p.remove(k);
      try {
        await _secure.delete(key: k);
      } catch (_) {}
    } else {
      await p.setString(k, v);
      try {
        await _secure.write(key: k, value: v);
      } catch (_) {}
    }
  }

  Future<void> evaluate() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final today = dayNumber(now);

    // Ghari peeche? (1.5 din ki chhoot — timezone / chhoti ghalti.)
    final lastSeen = int.tryParse(await _read(p, _kLastSeen) ?? '') ?? 0;
    if (lastSeen > 0 && now.millisecondsSinceEpoch < lastSeen - const Duration(hours: 36).inMilliseconds) {
      state.value = const LicenseState(LicenseStatus.clockTampered);
      return;
    }
    if (now.millisecondsSinceEpoch > lastSeen) await _write(p, _kLastSeen, '${now.millisecondsSinceEpoch}');

    if ((await _read(p, _kRevoked)) == '1') {
      state.value = const LicenseState(LicenseStatus.blocked);
      return;
    }

    String? keyProblem;
    final key = await _read(p, _kKey);
    if (key != null) {
      final lic = await _verifyForThisDevice(key);
      if (lic.license != null) {
        final l = lic.license!;
        if (l.isLifetime) {
          state.value = LicenseState(LicenseStatus.active, license: l);
        } else if (today < l.expiryDay) {
          state.value = LicenseState(LicenseStatus.active, license: l, daysLeft: l.expiryDay - today);
        } else {
          state.value = LicenseState(LicenseStatus.expired, license: l, daysLeft: 0);
        }
        return;
      }
      keyProblem = lic.error;
    }

    // Trial: pehli dafa ka din yaad (prefs + secure storage).
    var start = int.tryParse(await _read(p, _kTrialStart) ?? '');
    if (start == null) {
      start = today;
      await _write(p, _kTrialStart, '$today');
    }
    final left = start + LicenseConfig.trialDays - today;
    state.value = left > 0
        ? LicenseState(LicenseStatus.trial, daysLeft: left, keyProblem: keyProblem)
        : LicenseState(LicenseStatus.trialOver, daysLeft: 0, keyProblem: keyProblem);
  }

  Future<({LicensePayload? license, String? error})> _verifyForThisDevice(String key) async {
    final pub = base64.decode(LicenseConfig.publicKeyB64);
    final lic = await verifyLicenseKey(key, pub);
    if (lic == null) return (license: null, error: 'invalid');
    if (!sameBytes(lic.device, _deviceBytes)) return (license: null, error: 'other_device');
    return (license: lic, error: null);
  }

  /// License screen: key daalo. Kamyabi => null; warna wajah ('invalid' / 'other_device' / 'expired').
  Future<String?> activate(String key) async {
    final k = key.trim();
    final r = await _verifyForThisDevice(k);
    if (r.license == null) return r.error;
    final l = r.license!;
    if (!l.isLifetime && dayNumber(DateTime.now()) >= l.expiryDay) return 'expired';
    final p = await SharedPreferences.getInstance();
    await _write(p, _kKey, k);
    await evaluate();
    return null;
  }

  // ----------------------------------------------------------------- online

  bool get onlineConfigured => LicenseConfig.firebaseProjectId.isNotEmpty && LicenseConfig.firebaseApiKey.isNotEmpty;

  /// Hanna Solutions ke Firestore se `licenses/<DEVICEID>`: `blocked: true` => band; `key` => khud activate.
  /// Doc na ho => band nahi. Internet nahi => kuch nahi (offline key chalti rehti hai).
  /// [force] = License screen ka "Online check" (waqt ki hadd nahi).
  Future<bool> checkOnline({bool force = false}) async {
    if (!onlineConfigured || _deviceCode.isEmpty) return false;
    final p = await SharedPreferences.getInstance();
    final last = p.getInt(_kOnlineAt) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force && nowMs - last < Duration(hours: LicenseConfig.onlineCheckHours).inMilliseconds) return false;

    final id = _deviceCode.replaceAll('-', '');
    final uri = Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/${LicenseConfig.firebaseProjectId}/databases/(default)/documents/licenses/$id',
      {'key': LicenseConfig.firebaseApiKey},
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) {
        await _write(p, _kRevoked, null);
      } else if (res.statusCode == 200) {
        final fields = (jsonDecode(body) as Map<String, dynamic>)['fields'] as Map<String, dynamic>? ?? const {};
        final blocked = (fields['blocked'] as Map<String, dynamic>?)?['booleanValue'] == true;
        await _write(p, _kRevoked, blocked ? '1' : null);
        final key = (fields['key'] as Map<String, dynamic>?)?['stringValue'] as String?;
        if (!blocked && key != null && key.trim().isNotEmpty && key.trim() != await _read(p, _kKey)) {
          await activate(key);
        }
      } else {
        return false; // rules / key ka masla — offline hisaab jaisa hai waisa
      }
      await p.setInt(_kOnlineAt, nowMs);
      await evaluate();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
