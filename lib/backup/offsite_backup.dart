import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/due_alert_service.dart';
import 'backup_helper.dart';

/// Phone se BAHAR backup (phone gum / kharab / chori ho to data bache).
///
/// Backup roz phone par khud banta hai (12 PM / 9 PM) — lekin agar sirf phone par hai to phone ke saath hi
/// jata hai. Is liye: raat 9 baje ke baad (din mein ek dafa) notification "Aaj ka backup bahar bhejein";
/// tap => sab se naya backup share sheet mein (WhatsApp "Message yourself" / Drive / Gmail). Koi naya package
/// ya kharcha nahi. Kisi bhi raste se backup share ho ([BackupHelper.shareBackup]) to [markShared] —
/// phir us din reminder nahi aata. Faisla PURE [shouldRemindOffsite] mein — test/offsite_backup_test.dart.
///
/// YAAD RAHE: backup encrypted hai — naye phone par restore ke liye Backup Password chahiye. Password
/// kahin likh kar rakhein (Backup screen > Backup Password).
class OffsiteBackup {
  OffsiteBackup._();

  static const keyLastShared = 'offsite_backup_last_shared_ms';
  static const keyLastReminder = 'offsite_backup_last_reminder_date';
  static const remindHour = 21; // raat ka backup (9 PM) ban'ne ke baad
  static const payload = 'backup_share';
  static const _notificationId = 7304;
  static const _channelId = 'backup_alerts';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<void> markShared({DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(keyLastShared, (now ?? DateTime.now()).millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// 0 = kabhi nahi.
  static Future<int> lastSharedMillis() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return p.getInt(keyLastShared) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Background (WorkManager) aur foreground dono se. true = notification dikhayi.
  static Future<bool> checkAndNotify({DateTime? now}) async {
    if (!_supported) return false;
    try {
      final t = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!shouldRemindOffsite(
        now: t,
        lastSharedMillis: prefs.getInt(keyLastShared) ?? 0,
        lastReminderDate: prefs.getString(keyLastReminder),
      )) {
        return false;
      }
      if ((await BackupHelper.listBackups()).isEmpty) return false; // bhejne ko kuch nahi
      final days = daysSinceShared(prefs.getInt(keyLastShared) ?? 0, now: t);
      final body = offsiteReminderBody(days);
      await DueAlertService.init();
      await DueAlertService.plugin.show(
        _notificationId,
        'Backup phone se bahar bhejein',
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Backup reminders',
            channelDescription: 'Roz backup WhatsApp / Drive par bhejne ki yaad dihani',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
        payload: payload,
      );
      await prefs.setString(keyLastReminder, _dateKey(t));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Notification tap: sab se naya backup share karo. true = share sheet khula.
  static Future<bool> shareLatest() async {
    try {
      final files = await BackupHelper.listBackups();
      if (files.isEmpty) return false;
      return BackupHelper.shareBackup(files.first);
    } catch (_) {
      return false;
    }
  }
}

/// Kitne poore din se bahar nahi gaya. Kabhi nahi => -1.
int daysSinceShared(int lastSharedMillis, {DateTime? now}) {
  if (lastSharedMillis <= 0) return -1;
  final n = now ?? DateTime.now();
  return n.difference(DateTime.fromMillisecondsSinceEpoch(lastSharedMillis)).inDays;
}

/// Raat [OffsiteBackup.remindHour] ke baad, din mein ek dafa, agar pichle ~20 ghante mein share nahi hua.
bool shouldRemindOffsite({required DateTime now, required int lastSharedMillis, String? lastReminderDate}) {
  if (now.hour < OffsiteBackup.remindHour) return false;
  final today =
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  if (lastReminderDate == today) return false;
  if (lastSharedMillis > 0 && now.millisecondsSinceEpoch - lastSharedMillis < 20 * 3600 * 1000) return false;
  return true;
}

String offsiteReminderBody(int days) {
  final since = days < 0
      ? 'Abhi tak kabhi backup phone se bahar nahi gaya.'
      : days == 0
          ? 'Aaj ka naya backup tayyar hai.'
          : 'Aakhri dafa $days din pehle bahar bheja tha.';
  return '$since Tap karein aur WhatsApp (apne number) / Google Drive par bhej dein — phone gum ho to data bacha rahe.';
}
