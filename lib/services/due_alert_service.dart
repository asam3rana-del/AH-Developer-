import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/offsite_backup.dart';
import '../db/collection_autopilot_repository.dart';
import '../db/due_followup_repository.dart';
import '../models/collection_autopilot.dart';
import '../screens/collection_hub_screen.dart';
import '../screens/amanat_loan_screen.dart';
import '../screens/utility_bills_screen.dart';
import 'app_lock.dart';

/// Roz notification: "Aaj ki wasooli" — sab se zaroori parties ke naam aur raqam ke saath. Tap karne par Due
/// Reminders screen khulti hai jahan har party ke liye 1 tap WhatsApp / call aur follow-up record hai.
///
/// * Customers ki baaki sales + follow-up log ([DueFollowUpRepository.todaysFocus]) dekhta hai: toote wade,
///   aaj ke follow-up, overdue.
/// * Subah: din mein ek baar, [alertHour] baje ke baad. Shaam: [eveningHour] baje ke baad dobara, sirf tab jab
///   abhi bhi aaj ka kaam (follow-up / toota wada) baqi ho (ya subah wali ja hi na saki ho). Foreground (app
///   khulte waqt) aur Android WorkManager (har 15 min, backup_background.dart) dono yahi [checkAndNotify]
///   chalate hain; "aaj ho chuka" ke stamps SharedPreferences mein hain.
/// * Sirf Android; baaki platforms par kuch nahi karta. Koi bhi ghalti app ko nahi rokti.
class DueAlertService {
  DueAlertService._();

  static const keyEnabled = 'due_alert_enabled'; // default: on
  static const keyLastDate = 'due_alert_last_date';
  static const keyLastEveningDate = 'due_alert_last_evening_date';
  static const alertHour = 10; // subah 10 baje ke baad
  static const eveningHour = 18; // shaam 6 baje ke baad
  static const _payload = 'due_reminders';

  /// Autopilot notification ka payload (tap par Wasooli Queue screen khulti hai).
  static const queuePayload = 'wasooli_queue';
  static const _channelId = 'due_alerts';

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// BillReminderService isi plugin se notification dikhati hai (ek hi init / tap handler).
  static FlutterLocalNotificationsPlugin get plugin => _plugin;
  static bool get supported => _supported;

  /// `onTap` sirf foreground isolate mein dena hai (screen kholne ke liye).
  static Future<void> init({bool withTap = false}) async {
    if (!_supported || _inited) return;
    await _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: withTap ? (r) => _open(r.payload) : null,
    );
    _inited = true;
  }

  /// App band thi aur notification se khuli — pehla frame ke baad Due Reminders kholo.
  static Future<void> handleLaunch() async {
    if (!_supported) return;
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d?.didNotificationLaunchApp == true) _open(d?.notificationResponse?.payload);
    } catch (_) {}
  }

  static void _open(String? payload) {
    // Roz ka "backup bahar bhejein" reminder: seedha sab se naye backup ki share sheet.
    if (payload == OffsiteBackup.payload) {
      WidgetsBinding.instance.addPostFrameCallback((_) => OffsiteBackup.shareLatest());
      return;
    }
    if (payload != _payload && payload != queuePayload && payload != billsPayload && payload != returnPayload) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLock.navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => payload == queuePayload
            ? const CollectionHubScreen(initialTab: 0)
            : payload == billsPayload
            ? const UtilityBillsScreen()
            : payload == returnPayload
                ? const AmanatLoanScreen()
                : const CollectionHubScreen(initialTab: 1),
      ));
    });
  }

  /// Utility Bills notification ka payload (tap par Utility Bills screen khulti hai).
  static const billsPayload = 'utility_bills';

  /// Amanat / Loan wapsi notification ka payload (tap par Amanat / Loan screen khulti hai).
  static const returnPayload = 'amanat_loan';

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static String _rs(double v) => 'Rs ${v.round()}';

  /// Notification ka matn (pure — test ke liye). Sab se zaroori parties ke naam samet.
  static String bodyFor(CollectionFocus f) {
    final head = StringBuffer();
    if (f.actionCount > 0) {
      head.write('Aaj ${f.actionCount} parties par follow-up (${_rs(f.actionAmount)})');
      if (f.dueTodayCount > 0) head.write(' • ${f.dueTodayCount} ki aaj due date (${_rs(f.dueTodayAmount)})');
    } else if (f.dueTodayCount > 0) {
      head.write('Aaj ${f.dueTodayCount} parties se ${_rs(f.dueTodayAmount)} lena hai');
    } else {
      head.write('${f.totalParties} parties ka ${_rs(f.totalDue)} baaki hai');
    }
    if (f.overdueCount > 0) head.write(' • ${f.overdueCount} overdue (${_rs(f.overdueAmount)})');
    if (f.brokenCount > 0) head.write(' • ${f.brokenCount} wada toota');
    if (f.top.isNotEmpty) {
      head.write('. Pehle: ');
      head.write(f.top.map((p) => '${p.party.partyName} ${_rs(p.total)}').join(', '));
    }
    head.write('. Tap karke WhatsApp / call karein.');
    return head.toString();
  }

  /// Din mein notification dikhao (subah + zaroorat par shaam). true = dikhayi gayi.
  static Future<bool> checkAndNotify({DateTime? now, bool force = false}) async {
    if (!_supported) return false;
    try {
      final t = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final today = _dateKey(t);
      final evening = t.hour >= eveningHour;
      final morningDone = prefs.getString(keyLastDate) == today;
      if (!force) {
        if (prefs.getBool(keyEnabled) == false) return false;
        if (t.hour < alertHour) return false;
        if (evening) {
          if (prefs.getString(keyLastEveningDate) == today) return false;
        } else if (morningDone) {
          return false;
        }
      }
      // Autopilot queue: jin ko aaj reminder bhejna baqi hai. Jo party aaj ho chuki wo dobara nahi aati.
      final day = await CollectionAutopilotRepository.instance.today(nowMillis: t.millisecondsSinceEpoch);
      final q = day.queue;
      if (q.todo.isEmpty) return false;
      final body = autopilotNotificationBody(q, collectedToday: day.collectedToday, paymentsToday: day.paymentsToday);

      await init();
      await _plugin.show(
        7301,
        evening && morningDone ? 'Aaj ki wasooli abhi baaki hai' : 'Aaj ki wasooli',
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Due reminders',
            channelDescription: 'Jin parties ne payment nahi di, roz yaad dihani',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
        payload: queuePayload,
      );
      await prefs.setString(evening ? keyLastEveningDate : keyLastDate, today);
      if (evening) await prefs.setString(keyLastDate, today);
      return true;
    } catch (_) {
      return false;
    }
  }
}
