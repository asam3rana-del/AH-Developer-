import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/due_reminders_repository.dart';
import '../screens/amanat_loan_screen.dart';
import '../screens/due_reminders_screen.dart';
import '../screens/utility_bills_screen.dart';
import 'app_lock.dart';

/// Roz ek notification: "N parties ne payment nahi di" — tap karne par Due Reminders screen khulti hai
/// jahan har party ke liye 1 tap WhatsApp reminder hai (DueRemindersScreen).
///
/// * Customers ki baaki sales (`dueSales`) dekhta hai; naam/party ke hisab se ginti.
/// * Din mein ek hi baar, [alertHour] baje ke baad. Foreground (app khulte waqt) aur Android WorkManager
///   (har 15 min, backup_background.dart) dono yahi [checkAndNotify] chalate hain; "aaj ho chuka" ka
///   stamp SharedPreferences mein hai.
/// * Sirf Android; baaki platforms par kuch nahi karta. Koi bhi ghalti app ko nahi rokti.
class DueAlertService {
  DueAlertService._();

  static const keyEnabled = 'due_alert_enabled'; // default: on
  static const keyLastDate = 'due_alert_last_date';
  static const alertHour = 10; // subah 10 baje ke baad
  static const _payload = 'due_reminders';
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
    if (payload != _payload && payload != billsPayload && payload != returnPayload) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLock.navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => payload == billsPayload
            ? const UtilityBillsScreen()
            : payload == returnPayload
                ? const AmanatLoanScreen()
                : const DueRemindersScreen(),
      ));
    });
  }

  /// Utility Bills notification ka payload (tap par Utility Bills screen khulti hai).
  static const billsPayload = 'utility_bills';

  /// Amanat / Loan wapsi notification ka payload (tap par Amanat / Loan screen khulti hai).
  static const returnPayload = 'amanat_loan';

  static String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Din mein ek baar notification dikhao (agar baaki wali parties hain). true = dikhayi gayi.
  static Future<bool> checkAndNotify({DateTime? now, bool force = false}) async {
    if (!_supported) return false;
    try {
      final t = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!force) {
        if (prefs.getBool(keyEnabled) == false) return false;
        if (t.hour < alertHour) return false;
        if (prefs.getString(keyLastDate) == _dateKey(t)) return false;
      }
      final bills = await DueRemindersRepository.instance.dueSales();
      final parties = <String>{};
      for (final b in bills) {
        parties.add(b.partyId != null ? 'id${b.partyId}' : b.partyName);
      }
      if (parties.isEmpty) return false;
      final s = summarizeDue(bills, nowMillis: t.millisecondsSinceEpoch);
      final body = StringBuffer('${parties.length} parties ka Rs ${s.totalDue.toStringAsFixed(0)} baaki hai');
      if (s.overdue > 0) body.write(' (${s.overdue} bills ki due date guzar chuki)');
      body.write('. Tap karke WhatsApp reminder bhejein.');

      await init();
      await _plugin.show(
        7301,
        'Payment baaki hai',
        body.toString(),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Due reminders',
            channelDescription: 'Jin parties ne payment nahi di, roz yaad dihani',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: _payload,
      );
      await prefs.setString(keyLastDate, _dateKey(t));
      return true;
    } catch (_) {
      return false;
    }
  }
}
