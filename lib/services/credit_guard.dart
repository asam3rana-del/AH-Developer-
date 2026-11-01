import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/cloud_config_store.dart';

enum CreditCheckStatus { allowed, blocked, unavailable }

class CreditCheckResult {
  final CreditCheckStatus status;
  final double? creditLimit;
  final double? projected;
  const CreditCheckResult(this.status, {this.creditLimit, this.projected});
  static const unavailable = CreditCheckResult(CreditCheckStatus.unavailable);
}

/// Cross-device credit-limit pre-check (backend: functions/src/index.ts `reserveCredit`).
///
/// OPT-IN: default OFF (Settings > "Server credit-limit check"). Jab OFF ho to app bilkul pehle jaisi chalti hai.
/// ON hone par, credit bill save karne se pehle (agar internet + cloud sign-in ho) server se poocha jata hai ke
/// doosre devices ki pending bills mila kar bhi limit ke andar hai ya nahi.
///
/// FAIL-OPEN: offline / sign-in nahi / timeout / server error => [CreditCheckStatus.unavailable] aur sale
/// local check ke saath chalti rahti hai (dukaan ki sale internet par depend nahi karni chahiye). Yani offline
/// device par cross-device guarantee NAHI hai — docs/SERVER_CREDIT_CHECK.md dekhein.
class CreditGuard {
  const CreditGuard();

  static const prefKey = 'server_credit_check_enabled';
  static const _timeout = Duration(seconds: 4);

  /// Tests apna fake lagate hain.
  static CreditGuard instance = const CreditGuard();

  Future<bool> isEnabled() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(prefKey, v);
  }

  /// Kabhi throw nahi karta. [customerId] = cloud document id (`SyncQueueHelper.customerEntityId`).
  /// [reservationId] ek hi save ki dobara koshish par wahi rahe (server double-count nahi karta).
  Future<CreditCheckResult> reserve({
    required String customerId,
    required double amount,
    required String reservationId,
  }) async {
    try {
      if (!await isEnabled()) return CreditCheckResult.unavailable;
      final app = await CloudConfigStore.firebaseApp();
      if (app == null) return CreditCheckResult.unavailable;
      // Naya sign-in shuru nahi karte: sync ka apna session hi kaafi hai; nahi to fail-open.
      if (FirebaseAuth.instanceFor(app: app).currentUser == null) return CreditCheckResult.unavailable;
      final res = await FirebaseFunctions.instanceFor(app: app)
          .httpsCallable('reserveCredit')
          .call<Map<Object?, Object?>>({
        'customerId': customerId,
        'amount': amount,
        'reservationId': reservationId,
      }).timeout(_timeout);
      final d = res.data;
      double? n(Object? v) => v is num ? v.toDouble() : null;
      if (d['allowed'] == false) {
        return CreditCheckResult(CreditCheckStatus.blocked,
            creditLimit: n(d['creditLimit']), projected: n(d['projected']));
      }
      if (d['allowed'] == true) return const CreditCheckResult(CreditCheckStatus.allowed);
      return CreditCheckResult.unavailable;
    } catch (_) {
      return CreditCheckResult.unavailable;
    }
  }
}
