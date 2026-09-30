import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'sync_repository.dart';

/// Ek sync run ka natija — Kotlin `Result.success/failure(workDataOf(KEY_SUMMARY ...))`.
class SyncOutcome {
  /// Kotlin: `result.pulledOk` => success, warna failure.
  final bool success;

  /// `SyncResult.summary()` jaisi ek line (ya "Sync failed: ...").
  final String summary;
  final SyncResult? result;

  const SyncOutcome({required this.success, required this.summary, this.result});
}

/// Kotlin `SyncWorker.kt` (WorkManager CoroutineWorker). Sab sync (periodic, network wapas aane par,
/// manual "Sync Now") isi ek jagah se guzarte hain, kisi screen ke lifecycle se bandhe baghair.
///
/// FARQ (Kotlin se) — `workmanager` plugin ke baghair, BackupScheduler jaisa:
///  * Periodic sync sirf jab app zinda ho (screen par ya background mein): har 5 min ka Timer, app
///    dobara khulne (resumed) par agar pichli sync 1 min se purani ho, aur background jate (paused)
///    waqt pending changes bhejne ke liye. Poori tarah band app ke liye WorkManager/BGTaskScheduler baad mein.
///  * Kotlin ka `NetworkType.CONNECTED` constraint: offline hone par sync chalti hi nahi (warna push
///    fail hoke retryCount 10 tak pohanch kar entries "stuck" ho jayen). Yahan `isOnline` check se wohi.
///  * `syncNowOnce` (Kotlin REPLACE): Dart mein chalti hui sync cancel nahi hoti, is liye chalti hui
///    khatam hone ka intezar karke TAAZA run hota hai (nayi pending rows samet). `triggerNow` (KEEP):
///    agar sync chal rahi hai to no-op — RESOURCE_EXHAUSTED retry-storm wali FIX.
class SyncWorker {
  SyncWorker._();
  static final SyncWorker instance = SyncWorker._();

  /// App khula (ya background mein zinda) ho to har 5 min sync. (Kotlin WorkManager 15 min tha, par
  /// Flutter mein background service nahi, is liye app zinda hone ke dauran zyada baar chalate hain.
  /// Sync sirf badli hui cheezein push/pull karti hai, is liye quota par bhaari nahi.)
  static const Duration periodicInterval = Duration(minutes: 5);

  /// App wapas saamne aane par: pichli sync is se purani ho to turant sync.
  static const Duration resumeMinGap = Duration(minutes: 1);

  /// App background mein jate waqt: pending changes turant bhejne ke liye, bas itna gap zaroori
  /// (baar-baar home/back dabane par sync ki bauchhaar na ho).
  static const Duration pauseMinGap = Duration(seconds: 30);

  /// Asli sync (tests badalte hain).
  @visibleForTesting
  Future<SyncResult> Function() runSync = SyncRepository.syncNow;

  /// Internet hai? (Kotlin constraint `NetworkType.CONNECTED`.)
  @visibleForTesting
  Future<bool> Function() isOnline = () async {
    final r = await Connectivity().checkConnectivity();
    return r.any((e) => e != ConnectivityResult.none);
  };

  @visibleForTesting
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// UI ke liye: sync chal rahi hai? (Settings "Sync Now" spinner.)
  final ValueNotifier<bool> isRunning = ValueNotifier<bool>(false);

  /// UI ke liye: aakhri khatam hui sync ka natija (Kotlin `observeManualSync` ka `isFinished` + KEY_SUMMARY).
  final ValueNotifier<SyncOutcome?> lastOutcome = ValueNotifier<SyncOutcome?>(null);

  Timer? _timer;
  _LifecycleHook? _hook;
  Future<SyncOutcome>? _inFlight;
  int _lastFinishedAt = 0;

  bool get isScheduled => _timer != null;
  int get lastFinishedAt => _lastFinishedAt;

  /// main() mein ek baar (Kotlin `schedulePeriodic`, `ExistingPeriodicWorkPolicy.KEEP`): dobara
  /// bulane par duplicate ya restart nahi hota.
  void schedulePeriodic() {
    if (_timer != null) return;
    _timer = Timer.periodic(periodicInterval, (_) => triggerNow());
    _hook = _LifecycleHook(_onResumed, _onPaused);
    WidgetsBinding.instance.addObserver(_hook!);
  }

  void cancelPeriodic() {
    _timer?.cancel();
    _timer = null;
    final h = _hook;
    if (h != null) WidgetsBinding.instance.removeObserver(h);
    _hook = null;
  }

  void _onResumed() {
    // Wapas aane par: pichli sync 1 min se purani ho to abhi sync (doosri device ka naya data foran aaye).
    if (nowMs() - _lastFinishedAt >= resumeMinGap.inMilliseconds) triggerNow();
  }

  void _onPaused() {
    // Back / Home dabane par app band nahi hoti, par Android jaldi isay sula deta hai — is se pehle
    // pending changes bhej do (aur taaza data le lo), taake background mein bhi sync na ruke.
    if (nowMs() - _lastFinishedAt >= pauseMinGap.inMilliseconds) triggerNow();
  }

  /// Kotlin `triggerNow` (KEEP): NetworkMonitor / SyncQueueHelper (enqueue ke baad) yahan se. Sync
  /// pehle se chal rahi ho ya internet na ho to kuch nahi karta.
  Future<void> triggerNow() async {
    if (_inFlight != null) return;
    if (!await isOnline()) return;
    if (_inFlight != null) return; // await ke dauran koi aur shuru kar chuka
    await _start();
  }

  /// Kotlin `syncNowOnce` (REPLACE) — "Sync Now" button / login ke baad. Chalti hui sync khatam hone
  /// ke baad taaza run; natija `SyncOutcome` mein (aur `lastOutcome` mein).
  Future<SyncOutcome> syncNowOnce() async {
    while (_inFlight != null) {
      await _inFlight;
    }
    if (!await isOnline()) {
      // Kotlin WorkManager connected hone tak rukta; yahan foran batao. Queue mehfooz hai —
      // NetworkMonitor internet wapas aane par khud sync chalayega.
      final o = const SyncOutcome(
          success: false,
          summary: 'Sync failed: no internet connection (will sync automatically when back online)');
      lastOutcome.value = o;
      return o;
    }
    if (_inFlight != null) return syncNowOnce(); // await ke dauran doosri sync shuru ho gayi
    return _start();
  }

  Future<SyncOutcome> _start() {
    final f = _doWork().whenComplete(() {
      _inFlight = null;
      _lastFinishedAt = nowMs();
      isRunning.value = false;
    });
    _inFlight = f;
    return f;
  }

  /// Kotlin `doWork()`: syncNow chalao; koi bhi exception => "Sync failed: <msg>".
  Future<SyncOutcome> _doWork() async {
    isRunning.value = true;
    SyncOutcome outcome;
    try {
      final r = await runSync();
      outcome = SyncOutcome(success: r.pulledOk, summary: r.summary(), result: r);
    } catch (e, st) {
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      // Firebase plugin ki ghalti ([core/...]) mein andar ki jagah bhi dikhao — dhoondne mein aasani.
      if (msg.contains('[core/')) {
        final where = st
            .toString()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.contains('package:'))
            .take(3)
            .join(' | ');
        if (where.isNotEmpty) msg = '$msg  @ $where';
      }
      outcome = SyncOutcome(success: false, summary: 'Sync failed: $msg');
    }
    lastOutcome.value = outcome;
    return outcome;
  }
}

class _LifecycleHook with WidgetsBindingObserver {
  final VoidCallback onResumed;
  final VoidCallback onPaused;
  _LifecycleHook(this.onResumed, this.onPaused);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      onPaused();
    }
  }
}
