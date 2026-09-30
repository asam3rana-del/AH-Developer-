import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'backup_scheduler.dart';

/// Kotlin `BackupCheckpointWorker` (WorkManager, har 15 min) ka Flutter jor.
/// App band / swipe-out hone par bhi Android 12 PM / 9 PM checkpoint check chalata hai.
///
/// * Sirf Android (Kotlin app bhi Android hi hai). iOS / Windows / web par kuch nahi karta —
///   wahan purana Timer + resume wala BackupScheduler kaam karta rahta hai.
/// * `ExistingWorkPolicy.keep` — har app start par register karna safe hai (duplicate nahi banta).
/// * Ek din mein ek checkpoint ka stamp SharedPreferences mein hai; foreground aur background
///   dono isi stamp ko dekhte hain (`BackupScheduler.checkCheckpoints` pehle `prefs.reload()` karta hai).
class BackupBackground {
  BackupBackground._();

  static const uniqueName = 'grocery_pos_backup_checkpoints'; // Kotlin WORK_NAME
  static const taskName = 'backup_checkpoint_check';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// `main()` mein ek baar (Kotlin `scheduleDailyCheckpoints`). Fail ho to app chalti rahe.
  static Future<void> schedule() async {
    if (!_supported) return;
    try {
      await Workmanager().initialize(backupCallbackDispatcher, isInDebugMode: false);
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: BackupScheduler.checkInterval, // 15 min = Android ka minimum
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
    } catch (_) {
      // Plugin na ho / OEM battery policy — foreground Timer fallback maujood hai.
    }
  }
}

/// Background isolate ka entry point. Top-level + `vm:entry-point` zaroori hai.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      // Naye isolate mein DB / prefs / secure storage foreground jaise hi khulte hain
      // (sqflite path file-based hai, isliye wahi live DB milti hai).
      await BackupScheduler.instance.checkCheckpoints();
      return true;
    } catch (_) {
      return false; // Kotlin Result.retry()
    }
  });
}
