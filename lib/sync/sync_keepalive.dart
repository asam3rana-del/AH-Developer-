import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android par app minimize / back karne ke baad bhi sync chalti rahe.
///
/// Masla: Android background app ko kuch der baad "freeze" kar deta hai, is liye Dart ka 5-minute
/// Timer (SyncWorker) ruk jata tha. Hal: ek chhoti si "foreground service" (notification ke saath) jo
/// process ko zinda rakhti hai. Sync ka asli kaam wahi purana SyncWorker karta hai — service sirf
/// process ko sone nahi deti. Sirf Android par; iOS / Windows par kuch nahi karta.
///
/// Koi bhi ghalti (permission, plugin) app ko nahi rokti — bas keep-alive band rehta hai.
class SyncKeepAlive {
  SyncKeepAlive._();

  static bool _started = false;

  static Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'sync_keepalive',
          channelName: 'Cloud Sync',
          channelDescription: 'App band hone ke baad bhi data sync chalta rahe',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      // Android 13+: notification ki ijazat (na mile to bhi service chalti hai).
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) {
        _started = true;
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 4711,
        notificationTitle: 'Kiryana Store',
        notificationText: 'Cloud sync chal raha hai',
      );
      _started = true;
    } catch (_) {
      // keep-alive optional hai; app normal chalti rahe.
    }
  }

  static Future<void> stop() async {
    if (!_started || !Platform.isAndroid) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    _started = false;
  }
}
