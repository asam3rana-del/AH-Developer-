import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';
import '../services/due_alert_service.dart';
import '../utils/loc.dart';

/// App ke andar "naya update aaya hai" (Play Store ke baghair). Hanna Installment se laya gaya (docs/UPDATES.md).
///
/// Hanna Solutions ek public file rakhta hai ([AppInfo.updateUrl], tafseel docs/UPDATES.md):
/// ```json
/// {
///   "android": {"version": "1.0.0", "build": 31, "url": "https://.../app-release.apk", "notes": "Kya naya hai"},
///   "windows": {"version": "1.0.0", "build": 31, "url": "https://.../Hanna-POS-Setup.exe", "sha256": "...", "notes": ""},
///   "min_build": 0
/// }
/// ```
/// App ka apna build ([AppInfo.build], CI ka run number) is se chhota ho to Home par dialog; Download = browser mein
/// link (Android khud install poochta hai — purani app ke upar, data aur license wahi). `min_build` se chhota build ho
/// to dialog band nahi hota (zaroori update). Har 6 ghante mein ek dafa check; internet na ho to chup.
/// Hifazat: Android sirf usi signing key wali APK ko update maanta hai — koi aur link de bhi de to install nahi hogi.
class UpdateInfo {
  final String version;
  final int build;
  final String url;
  final String notes;

  /// Is build se purani app ko update lazmi.
  final int minBuild;

  /// (Ikhtiyari) file ka SHA-256 — PC installer download ke baad milaya jata hai.
  final String sha256;
  const UpdateInfo({required this.version, required this.build, required this.url, this.notes = '', this.minBuild = 0, this.sha256 = ''});

  /// PC: link Setup (.exe) ka hai to app khud download karke chala sakti hai.
  bool get isWindowsInstaller => url.toLowerCase().split('?').first.endsWith('.exe');
  bool get isApk => url.toLowerCase().split('?').first.endsWith('.apk');

  bool newerThan(int current) => build > current;
  bool requiredFor(int current) => current < minBuild && build > current;
}

/// PURE (test hota hai). [platform]: 'android' / 'windows' / 'ios'. Ghalat / adhuri file = null.
UpdateInfo? parseUpdateInfo(String body, String platform) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return null;
    final m = j[platform];
    if (m is! Map) return null;
    final build = m['build'];
    final url = m['url'];
    if (build is! num || url is! String || !url.startsWith('https://')) return null;
    final minBuild = m['min_build'] ?? j['min_build'];
    return UpdateInfo(
      version: '${m['version'] ?? ''}',
      build: build.toInt(),
      url: url,
      notes: '${m['notes'] ?? ''}',
      minBuild: minBuild is num ? minBuild.toInt() : 0,
      sha256: '${m['sha256'] ?? ''}'.trim().toLowerCase(),
    );
  } catch (_) {
    return null;
  }
}

class AppUpdate {
  AppUpdate._();

  static const _kLast = 'app_update_last_check';
  static const _every = Duration(hours: 6);
  static bool _showing = false;

  /// Chalta hua update download: null = kuch nahi, warna 0..1 (0 = shuru, size pata nahi).
  /// Download screen / dialog se azad hai — user back kare, doosri app khole, phir bhi chalta rehta hai.
  static final ValueNotifier<double?> downloading = ValueNotifier<double?>(null);
  static bool get busy => downloading.value != null;
  static bool _cancel = false;

  /// Download poora hua magar app us waqt peeche thi (Android peeche se installer kholne nahi deta):
  /// app wapas saamne aate hi installer khulega.
  static String? _readyApk;
  static _UpdateLifecycle? _lifecycle;

  static const _appChannel = MethodChannel('ah_developer/app');
  static const _notifId = 7401;
  static const _notifChannel = 'app_update';

  /// Home par back: update chal raha ho to app band nahi, sirf peeche (download na toote).
  static Future<void> moveAppToBack() async {
    try {
      await _appChannel.invokeMethod<void>('moveToBack');
    } catch (_) {}
  }

  /// CI build number (local / purani build par 0).
  static int get currentBuild => int.tryParse(AppInfo.build) ?? 0;

  static String? get _platform {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    return null;
  }

  static Future<UpdateInfo?> fetch() async {
    final plat = _platform;
    if (plat == null || AppInfo.updateUrl.isEmpty) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse(AppInfo.updateUrl).replace(queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch ~/ 60000}'});
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      if (body.length > 20000) return null;
      return parseUpdateInfo(body, plat);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Home khulne par: 6 ghante mein ek dafa, chup chaap. Local build (0) par kuch nahi.
  static Future<void> checkOnStart(BuildContext context) async {
    final cur = currentBuild;
    if (cur <= 0 || _showing) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLast) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < _every.inMilliseconds && now >= last) return;
      final info = await fetch();
      if (info == null) return; // internet nahi: agli dafa phir
      await prefs.setInt(_kLast, now);
      if (!info.newerThan(cur) || !context.mounted) return;
      await _dialog(context, info, required: info.requiredFor(cur));
    } catch (_) {
      // update check kabhi app na roke
    }
  }

  /// Settings > About > "Check for update".
  static Future<void> checkNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(Loc.t('Checking for update...', 'اپڈیٹ دیکھ رہے ہیں...'))));
    final info = await fetch();
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    final cur = currentBuild;
    if (info == null) {
      messenger.showSnackBar(
          SnackBar(content: Text(Loc.t('Could not check (internet?). Try again later.', 'چیک نہیں ہو سکا (انٹرنیٹ؟)۔ بعد میں دوبارہ کوشش کریں۔'))));
      return;
    }
    if (!info.newerThan(cur)) {
      messenger.showSnackBar(SnackBar(
          content: Text(Loc.t('You have the latest version (build $cur).', 'آپ کے پاس نیا ورژن ہے (build $cur)۔'))));
      return;
    }
    await _dialog(context, info, required: info.requiredFor(cur));
  }

  static Future<void> _dialog(BuildContext context, UpdateInfo info, {required bool required}) async {
    _showing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: !required,
        builder: (ctx) => PopScope(
          canPop: !required,
          child: AlertDialog(
            icon: const Icon(Icons.system_update, size: 36),
            title: Text(required
                ? Loc.t('Update required', 'اپڈیٹ ضروری ہے')
                : Loc.t('New update available', 'نیا اپڈیٹ آ گیا ہے')),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${AppInfo.appName} ${info.version} (build ${info.build})', style: const TextStyle(fontWeight: FontWeight.bold)),
                if (info.notes.trim().isNotEmpty) ...[const SizedBox(height: 8), Text(info.notes.trim())],
                const SizedBox(height: 10),
                Text(
                  Loc.t('Install it over the current app. Do NOT uninstall — your data and license stay.',
                      'موجودہ ایپ کے اوپر انسٹال کریں۔ ان انسٹال نہ کریں — ڈیٹا اور لائسنس وہی رہیں گے۔'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ]),
            ),
            actions: [
              if (!required) TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Later', 'بعد میں'))),
              FilledButton.icon(
                icon: const Icon(Icons.system_update_alt),
                label: Text(Loc.t('Update now', 'ابھی اپڈیٹ کریں')),
                onPressed: () async {
                  if (busy) {
                    Navigator.pop(ctx);
                    _showProgress(context);
                    return;
                  }
                  if (!kIsWeb && Platform.isWindows && info.isWindowsInstaller) {
                    // PC: Setup khud download + chala do (purani app band, nayi lag kar khud khulti hai; data wahi).
                    Navigator.pop(ctx);
                    await _installWindows(context, info);
                    return;
                  }
                  if (!kIsWeb && Platform.isAndroid && info.isApk) {
                    // Mobile: APK app ke andar download (Downloads mein nahi), phir seedha Android ka "Update" parda.
                    Navigator.pop(ctx);
                    await _installAndroid(context, info);
                    return;
                  }
                  final ok = await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication);
                  if (!ok && ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(info.url)));
                  }
                  if (!required && ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      );
    } finally {
      _showing = false;
    }
  }

  /// Progress dialog (sirf dikhawa): "Background mein" / back = dialog band, download chalta rahe; "Cancel" = rok do.
  static void _showProgress(BuildContext context) {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<double?>(
        valueListenable: downloading,
        builder: (_, v, __) {
          if (v == null) {
            // Download khatam / ruk gaya: dialog khud band.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted && Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
            });
          }
          return AlertDialog(
            title: Text(Loc.t('Downloading update...', 'اپڈیٹ ڈاؤن لوڈ ہو رہا ہے...')),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: (v ?? 0) > 0 ? v : null),
              const SizedBox(height: 8),
              Text((v ?? 0) > 0 ? '${((v ?? 0) * 100).round()}%' : ''),
              const SizedBox(height: 8),
              Text(
                Loc.t('You can go back or use other apps — the update keeps downloading. It will ask to install when ready.',
                    'آپ واپس جا سکتے ہیں یا کوئی اور ایپ استعمال کر سکتے ہیں — اپڈیٹ ڈاؤن لوڈ ہوتا رہے گا۔ تیار ہونے پر انسٹال پوچھے گا۔'),
                style: const TextStyle(fontSize: 12.5),
              ),
            ]),
            actions: [
              TextButton(
                onPressed: () {
                  _cancel = true;
                  Navigator.pop(ctx);
                },
                child: Text(Loc.t('Cancel', 'منسوخ')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(Loc.t('Run in background', 'پیچھے چلنے دیں')),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Android notification: download ka progress (ya "tayyar — install ke liye dabayein").
  static Future<void> _notify(String title, String body, {int? percent}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await DueAlertService.init();
      await DueAlertService.plugin.show(
        _notifId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _notifChannel,
            'App update',
            channelDescription: 'Hanna POS update download',
            importance: percent == null ? Importance.high : Importance.low,
            priority: percent == null ? Priority.high : Priority.low,
            onlyAlertOnce: true,
            ongoing: percent != null,
            autoCancel: percent == null,
            showProgress: percent != null,
            maxProgress: 100,
            progress: percent ?? 0,
            indeterminate: percent != null && percent <= 0,
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _clearNotify() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await DueAlertService.plugin.cancel(_notifId);
    } catch (_) {}
  }

  /// Update file app ke apne temp folder mein download — screen se azad (back / doosri app par bhi chalta rahe;
  /// Android par app ko SyncKeepAlive ki foreground service zinda rakhti hai). SHA-256 mile to milao.
  /// Kamyab => file; Cancel => null; ghalti => throw.
  static Future<File?> _download(BuildContext context, UpdateInfo info, String fileName) async {
    _cancel = false;
    downloading.value = 0;
    _showProgress(context);
    await _notify(Loc.t('Downloading update...', 'اپڈیٹ ڈاؤن لوڈ ہو رہا ہے...'), '${AppInfo.appName} build ${info.build}', percent: 0);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      final req = await client.getUrl(Uri.parse(info.url));
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final sink = file.openWrite();
      var got = 0;
      var lastPct = -1;
      final hashSink = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(hashSink);
      await for (final chunk in res) {
        if (_cancel) break;
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (total > 0) {
          downloading.value = got / total;
          final pct = (got * 100 ~/ total);
          if (pct >= lastPct + 5) {
            lastPct = pct;
            await _notify(Loc.t('Downloading update...', 'اپڈیٹ ڈاؤن لوڈ ہو رہا ہے...'), '$pct%', percent: pct);
          }
        }
      }
      await sink.close();
      hasher.close();
      if (_cancel) {
        try {
          await file.delete();
        } catch (_) {}
        await _clearNotify();
        return null;
      }
      if (total > 0 && got != total) {
        try {
          await file.delete();
        } catch (_) {}
        throw const HttpException('Download incomplete (internet dropped)');
      }
      if (info.sha256.isNotEmpty && hashSink.value?.toString() != info.sha256) {
        try {
          await file.delete();
        } catch (_) {}
        throw const FormatException('Downloaded file does not match (sha256) — not installed.');
      }
      return file;
    } catch (_) {
      await _clearNotify();
      rethrow;
    } finally {
      client.close(force: true);
      downloading.value = null;
    }
  }

  static Future<void> _failed(BuildContext context, UpdateInfo info, Object e) async {
    if (!context.mounted) {
      await _notify(Loc.t('Update failed', 'اپڈیٹ ناکام'), Loc.t('Open the app and try again.', 'ایپ کھول کر دوبارہ کوشش کریں۔'));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(Loc.t('Update failed: $e — download it from the link instead.', 'اپڈیٹ ناکام: $e — لنک سے ڈاؤن لوڈ کریں۔'))));
    await launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication);
  }

  /// PC auto-update: Setup.exe temp mein (progress ke saath), SHA-256 mile to milao, phir chup chaap install
  /// (`/VERYSILENT`) — installer purani app band karta hai, nayi files lagata hai aur app dobara kholta hai.
  /// Data (AppData / Documents) aur license wahi rehte hain.
  static Future<void> _installWindows(BuildContext context, UpdateInfo info) async {
    try {
      final file = await _download(context, info, 'Hanna-POS-Setup-${info.build}.exe');
      if (file == null) return;
      await Process.start(
        file.path,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      exit(0); // installer purani app ki files badal sake
    } catch (e) {
      await _failed(context, info, e);
    }
  }

  /// Mobile auto-update: APK app ke apne cache folder mein (Downloads mein kuch nahi), phir Android ka "Update"
  /// parda. User beech mein back kare / doosri app khole to download chalta rehta hai; tayyar hone par app saamne
  /// ho to foran installer, warna notification "install ke liye dabayein" aur app khulte hi installer.
  /// Android bina tasdeeq ke install nahi karne deta — aakhir mein ek "Update" dabana zaroori hai.
  static Future<void> _installAndroid(BuildContext context, UpdateInfo info) async {
    _lifecycle ??= _UpdateLifecycle()..attach();
    try {
      try {
        final dir = await getTemporaryDirectory();
        for (final f in dir.listSync()) {
          if (f is File && f.path.endsWith('.apk') && f.path.contains('hanna-pos-update-')) f.deleteSync();
        }
      } catch (_) {}
      final file = await _download(context, info, 'hanna-pos-update-${info.build}.apk');
      if (file == null) return;
      final front = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (front) {
        await _clearNotify();
        await _openInstaller(file.path);
      } else {
        _readyApk = file.path;
        await _notify(Loc.t('Update ready', 'اپڈیٹ تیار ہے'),
            Loc.t('Tap to install ${AppInfo.appName} build ${info.build}', '${AppInfo.appName} build ${info.build} انسٹال کرنے کے لیے دبائیں'));
      }
    } catch (e) {
      await _failed(context, info, e);
    }
  }

  static Future<void> _openInstaller(String path) async {
    final r = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) throw Exception(r.message.isEmpty ? r.type.name : r.message);
  }

  /// App wapas saamne: tayyar APK ho to installer.
  static Future<void> _onResumed() async {
    final path = _readyApk;
    if (path == null) return;
    _readyApk = null;
    await _clearNotify();
    try {
      if (File(path).existsSync()) await _openInstaller(path);
    } catch (_) {}
  }
}

class _UpdateLifecycle with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) AppUpdate._onResumed();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
