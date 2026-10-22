import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/utility_bill_repository.dart';
import 'due_alert_service.dart';

/// Utility Bills ki reminder notification.
///
/// Har bill ke liye (agar uska reminder on ho aur is mahine ka pay na hua ho):
///  * `pre`  — due date se ek din pehle ("kal due hai"),
///  * `due`  — due wale din ("aaj due hai"),
///  * `over` — due guzarne ke baad roz ek baar ("due guzar chuki").
/// Har marhala ek bill + mahine ke liye sirf ek baar (SharedPreferences mein stamp); `over` din mein ek baar.
///
/// [reminderHour] baje ke baad dikhti hai. Foreground (app khulte waqt) aur Android WorkManager (har 15 min,
/// backup_background.dart) dono [checkAndNotify] chalate hain. Sirf Android; koi bhi ghalti app ko nahi rokti.
class BillReminderService {
  BillReminderService._();

  static const reminderHour = 9; // subah 9 baje ke baad
  static const _channelId = 'bill_reminders';
  static const _baseId = 7400;

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static String _stampKey(int billId) => 'bill_reminder_last_$billId';

  /// Stamp: `<mahina>|<marhala>` (over ke liye `<mahina>|over<aaj ki tarikh>`).
  static String stampFor(BillStatus s, String stage, DateTime now) =>
      '${s.month}|${stage == 'over' ? 'over${_dateKey(now)}' : stage}';

  static String _title(UtilityBill b, String stage) {
    switch (stage) {
      case 'pre':
        return '${b.name} ka bill kal due hai';
      case 'due':
        return '${b.name} ka bill aaj due hai';
      default:
        return '${b.name} ka bill due guzar chuka hai';
    }
  }

  static String _body(BillView v, String stage) {
    final amt = v.suggestedAmount > 0 ? ' (takreeban Rs ${v.suggestedAmount.toStringAsFixed(0)})' : '';
    final d = v.status.due;
    final date = '${d.day}/${d.month}/${d.year}';
    switch (stage) {
      case 'pre':
        return 'Kal $date ko due hai$amt. Pay karke app mein "Paid" kar dein.';
      case 'due':
        return 'Aaj due date hai$amt. Pay karke app mein "Paid" kar dein.';
      default:
        return '${-v.status.daysLeft} din pehle due thi$amt. Jaldi pay karein.';
    }
  }

  /// Zaroorat ke mutabiq notifications dikhao. Kitni dikhayi gayin wo wapas.
  static Future<int> checkAndNotify({DateTime? now, bool force = false}) async {
    if (!DueAlertService.supported) return 0;
    try {
      final t = now ?? DateTime.now();
      if (!force && t.hour < reminderHour) return 0;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final views = await UtilityBillRepository.instance.views(now: t);
      var shown = 0;
      await DueAlertService.init();
      for (final v in views) {
        final id = v.bill.id;
        if (id == null || !v.bill.reminder) continue;
        final stage = reminderStage(v.status);
        if (stage == null) continue;
        final stamp = stampFor(v.status, stage, t);
        if (prefs.getString(_stampKey(id)) == stamp) continue;
        await DueAlertService.plugin.show(
          _baseId + (id % 1000),
          _title(v.bill, stage),
          _body(v, stage),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              'Bill reminders',
              channelDescription: 'Utility bills (bijli, gas, pani, internet) ki due date ki yaad dihani',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          payload: DueAlertService.billsPayload,
        );
        await prefs.setString(_stampKey(id), stamp);
        shown++;
      }
      return shown;
    } catch (_) {
      return 0;
    }
  }

  /// Android 13+ par notification ki ijazat maango (Utility Bills screen kholne par ek baar).
  static Future<void> requestPermission() async {
    if (!DueAlertService.supported) return;
    try {
      await DueAlertService.init();
      await DueAlertService.plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }
}
