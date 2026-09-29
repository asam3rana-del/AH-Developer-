import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Kotlin `NetworkMonitor.kt`. Internet wapas aane par sync trigger karta hai.
///
/// FIX (RESOURCE_EXHAUSTED retry storm): Android mein onAvailable() har network par alag fire
/// hota hai (dual-SIM, WiFi/mobile flap) — ek minute mein kai baar. Har call chalti hui sync
/// ko cancel karke wohi head-of-queue rows dobara push karti thi aur Firestore ka daily write
/// quota minutes mein khatam ho jata tha. Yahan pehla guard: [minIntervalMs] (20 s) ke andar
/// aane wali burst sirf EK sync trigger kare. (Doosra guard SyncWorker.triggerNow ka KEEP
/// policy hai — SyncWorker ke saath.)
class NetworkMonitor {
  NetworkMonitor._();

  static const int minIntervalMs = 20000;

  /// SyncWorker banne par `SyncWorker.triggerNow` yahan jorein (Kotlin ka `SyncWorker.triggerNow`).
  static void Function()? onOnline;

  static StreamSubscription<List<ConnectivityResult>>? _sub;
  static int _lastTriggeredAt = 0;
  static bool _wasOnline = true;

  /// Test ke liye clock.
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// main() mein ek baar (Kotlin `NetworkMonitor.register(this)`). Dobara bulane par purani
  /// subscription hat jati hai.
  static Future<void> register() async {
    await _sub?.cancel();
    final c = Connectivity();
    _wasOnline = _isOnline(await c.checkConnectivity());
    _sub = c.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      // Android onAvailable = "koi network mila"; yahan offline -> online ya naya network.
      if (online) onNetworkAvailable();
      _wasOnline = online;
    });
  }

  static Future<void> unregister() async {
    await _sub?.cancel();
    _sub = null;
  }

  static bool get wasOnline => _wasOnline;

  static bool _isOnline(List<ConnectivityResult> r) =>
      r.any((e) => e != ConnectivityResult.none);

  /// Debounce: `minIntervalMs` se pehle dobara aane wali call ignore. true = sync trigger hui.
  static bool onNetworkAvailable() {
    final now = nowMs();
    if (now - _lastTriggeredAt < minIntervalMs) return false;
    _lastTriggeredAt = now;
    onOnline?.call();
    return true;
  }

  /// Sirf tests ke liye.
  static void resetForTest() {
    _lastTriggeredAt = 0;
    onOnline = null;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
  }
}
