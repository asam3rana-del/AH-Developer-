import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/due_reminders_repository.dart';
import 'due_alert_service.dart';
import 'session.dart';

/// Roz ek notification: Amanat / Loan parties jin ki wapsi ki tarikh AAJ hai ya guzar chuki
/// (`Customer.kind` + `returnDate`). Tap par Amanat / Loan screen khulti hai.
///
/// * [alertHour] baje ke baad, din mein ek baar (stamp SharedPreferences mein). Foreground (app khulte
///   waqt) aur Android WorkManager (backup_background.dart) dono [checkAndNotify] chalate hain.
/// * Due alert ka on/off ([DueAlertService.keyEnabled]) isi par bhi lagta hai.
/// * Amanat / Loan screen sirf admin / manager ki hai, is liye background isolate mein bhi session
///   padh kar sirf admin / manager login hone par notification dikhti hai.
/// * Sirf Android; koi bhi ghalti app ko nahi rokti.
class ReturnAlertService {
  ReturnAlertService._();

  static const keyLastDate = 'return_alert_last_date';
  static const alertHour = 10; // subah 10 baje ke baad
  static const _channelId = 'return_alerts';
  static const _notificationId = 7302;

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Notification dikhao (agar koi tarikh aa chuki ho). true = dikhayi gayi.
  static Future<bool> checkAndNotify({DateTime? now, bool force = false}) async {
    if (!DueAlertService.supported) return false;
    try {
      final t = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!force) {
        if (prefs.getBool(DueAlertService.keyEnabled) == false) return false;
        if (t.hour < alertHour) return false;
        if (prefs.getString(keyLastDate) == _dateKey(t)) return false;
      }
      // Background isolate mein Session load nahi hota; role yahin se.
      await Session.load();
      if (!Session.isLoggedIn || !Session.isAdminOrManager) return false;
      final due = returnDueNow(
        await DueRemindersRepository.instance.returnReminders(),
        nowMillis: t.millisecondsSinceEpoch,
      );
      if (due.isEmpty) return false;

      await DueAlertService.init();
      await DueAlertService.plugin.show(
        _notificationId,
        'Deposit / Loan returns',
        returnAlertBody(due, nowMillis: t.millisecondsSinceEpoch),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Deposit / Loan reminders',
            channelDescription: 'Reminders for deposit return and loan repayment dates',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: DueAlertService.returnPayload,
      );
      await prefs.setString(keyLastDate, _dateKey(t));
      return true;
    } catch (_) {
      return false;
    }
  }
}
