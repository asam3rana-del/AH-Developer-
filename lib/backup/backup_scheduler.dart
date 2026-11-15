import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_background.dart';
import 'backup_helper.dart';

/// Mirrors BackupScheduler.kt — automatic offline backups:
///  1. ~12:00 PM checkpoint   2. ~9:00 PM checkpoint   3. app background / band hone par
/// Har checkpoint din mein ek baar. App-close trigger [BackupHelper.backupIfDue] (30 min throttle).
///
/// Android par band app ke liye asli WorkManager: `BackupBackground.schedule()` (backup_background.dart,
/// `workmanager` plugin) har 15 min `checkCheckpoints` chalata hai. Timer + resume wali cheez
/// ab fallback hai (iOS / Windows / jab OEM background kaam rok de).
class BackupScheduler with WidgetsBindingObserver {
  BackupScheduler._();
  static final BackupScheduler instance = BackupScheduler._();

  static const _keyLastNoon = 'auto_backup_last_noon_backup_date';
  static const _keyLastNight = 'auto_backup_last_night_backup_date';
  static const checkInterval = Duration(minutes: 15);

  Timer? _timer;
  bool _registered = false;

  /// `main()` mein ek baar (Kotlin `register(app)` + `scheduleDailyCheckpoints`).
  void register() {
    if (_registered) return;
    _registered = true;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(checkInterval, (_) => checkCheckpoints());
    checkCheckpoints();
    BackupBackground.schedule(); // Kotlin scheduleDailyCheckpoints (Android only, KEEP)
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_registered) WidgetsBinding.instance.removeObserver(this);
    _registered = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkCheckpoints();
    } else if (state == AppLifecycleState.paused) {
      // Kuch bhi nazar nahi aa raha — app minimize/close (Kotlin `startedCount <= 0`).
      _runBackup();
    }
  }

  /// Noon (12:00+) aur 9 PM (21:00+) ke checkpoint, har ek din mein ek baar.
  Future<void> checkCheckpoints({DateTime? now}) async {
    try {
      final t = now ?? DateTime.now();
      final today = DateFormat('yyyy-MM-dd').format(t);
      final prefs = await SharedPreferences.getInstance();
      // Background isolate (WorkManager) ne stamp likha ho to foreground ko bhi dikhe (aur ulta).
      await prefs.reload();

      final noonDue = t.hour >= 12 && prefs.getString(_keyLastNoon) != today;
      final nightDue = t.hour >= 21 && prefs.getString(_keyLastNight) != today;
      if (!noonDue && !nightDue) return;

      // Dono ek saath due hon (jaise sham ko pehli baar app khula) to ek hi backup, dono stamp.
      final file = await BackupHelper.backupNow();
      if (file == null) return; // fail / DB nahi — agli check par dobara koshish
      if (noonDue) await prefs.setString(_keyLastNoon, today);
      if (nightDue) await prefs.setString(_keyLastNight, today);
    } catch (_) {
      // Scheduler kabhi app crash na kare.
    }
  }

  Future<void> _runBackup() async {
    try {
      await BackupHelper.backupIfDue(minGapMinutes: 30);
    } catch (_) {}
  }
}
