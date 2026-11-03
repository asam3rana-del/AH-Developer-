import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sync/cloud_config_store.dart';

/// Secure staff cloud login (backend: functions/src/index.ts `staffLogin`).
///
/// OPT-IN: default OFF. Jab tak Settings mein "Secure staff cloud login" on nahi hota, app pehle ki tarah
/// chalti hai (local login + anonymous sync). On karne se pehle backend + App Check staging mein test karein
/// (docs/STAFF_AUTH_BACKEND_SETUP.md). Cloud rules `firestore.staff-claims.rules` abhi bhi deploy na karein
/// jab tak cashier sale server-side na ho.
///
/// ON hone par:
///  * password login ke baad `staffLogin` callable -> custom token -> Firebase sign-in (verified claims).
///  * Cloud sync kabhi anonymous sign-in par wapas nahi girta; staff sign-in na ho to sync "not signed in" dikhata hai.
///  * Local login phir bhi chalta hai (offline POS), lekin cloud sirf verified staff session se.
/// `pushSyncOp` nakaam hone ki qism (SyncApi inhein Sync*Exception mein badalta hai).
enum StaffPushFailure {
  /// Internet / server tak nahi pahunch saka / session khatam: entry pending rahe, failure na ginein.
  offline,

  /// Server ne role / branch ki wajah se mana kiya (permission-denied).
  denied,

  /// Server ne entry hi ghalat maani (invalid-argument ...): ye entry khud theek karni hogi.
  rejected,
}

class StaffPushException implements Exception {
  final StaffPushFailure kind;
  final String message;
  const StaffPushException(this.kind, this.message);
  @override
  String toString() => message;
}

class StaffAuth {
  StaffAuth._();

  static const _prefKey = 'staff_cloud_auth_enabled';
  static const _userKey = 'staff_cloud_auth_user';
  static const _roles = ['admin', 'manager', 'cashier'];

  /// Aakhri sign-in ka masla (UI/toast ke liye); khali = theek.
  static String lastError = '';

  static Future<bool> isEnabled() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefKey, v);
    if (!v) await signOut();
  }

  /// true = Firebase par verified staff (non-anonymous, valid claims) sign-in maujood hai.
  static Future<bool> hasVerifiedSession() async {
    try {
      final app = await CloudConfigStore.firebaseApp();
      if (app == null) return false;
      final user = FirebaseAuth.instanceFor(app: app).currentUser;
      if (user == null || user.isAnonymous) return false;
      final c = (await user.getIdTokenResult()).claims ?? const <String, dynamic>{};
      return c['active'] == true &&
          c['staffId'] is String &&
          c['branchId'] is String &&
          _roles.contains(c['role']);
    } catch (_) {
      return false;
    }
  }

  /// Password login ke baad: staffLogin -> custom token -> sign-in -> claims verify. Kabhi throw nahi karta.
  /// Kamyab = true. Nakaam => [lastError] mein wajah; local login phir bhi chal sakta hai.
  static Future<bool> signIn(String username, String password) async {
    lastError = '';
    try {
      final app = await CloudConfigStore.firebaseApp();
      if (app == null) {
        lastError = 'Firebase project is not set (Cloud Sync Setup).';
        return false;
      }
      // Functions enforceAppCheck: true => App Check zaroori.
      await FirebaseAppCheck.instanceFor(app: app).activate(
        androidProvider: kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
        appleProvider: kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
      );
      final res = await FirebaseFunctions.instanceFor(app: app)
          .httpsCallable('staffLogin')
          .call<Map<Object?, Object?>>({'username': username.trim(), 'password': password})
          .timeout(const Duration(seconds: 25));
      final token = res.data['customToken'];
      if (token is! String || token.isEmpty) {
        lastError = 'Server did not return a sign-in token.';
        return false;
      }
      await FirebaseAuth.instanceFor(app: app).signInWithCustomToken(token).timeout(const Duration(seconds: 20));
      // Authorization sirf verified token claims par — callable ke jawab par nahi.
      if (!await hasVerifiedSession()) {
        await signOut();
        lastError = 'Signed-in token has no valid staff claims.';
        return false;
      }
      try {
        (await SharedPreferences.getInstance()).setString(_userKey, username.trim().toLowerCase());
      } catch (_) {}
      return true;
    } on FirebaseFunctionsException catch (e) {
      lastError = e.code == 'resource-exhausted'
          ? 'Too many attempts. Try again later.'
          : e.code == 'unauthenticated'
              ? 'Cloud staff account not found or password mismatch.'
              : 'Cloud login failed (${e.code}).';
      return false;
    } on TimeoutException {
      lastError = 'Cloud login timed out (check internet).';
      return false;
    } catch (e) {
      lastError = 'Cloud login failed: $e';
      return false;
    }
  }

  /// true = verified cloud session maujood hai AUR wo isi [username] ka hai (OTP / fingerprint / no-password
  /// login ke baad pata chalta hai ke cloud password poochna hai ya nahi).
  static Future<bool> hasSessionFor(String username) async {
    if (!await hasVerifiedSession()) return false;
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_userKey) == username.trim().toLowerCase();
    } catch (_) {
      return false;
    }
  }

  static Future<FirebaseFunctions?> _functions() async {
    final app = await CloudConfigStore.firebaseApp();
    if (app == null) {
      lastError = 'Firebase project is not set (Cloud Sync Setup).';
      return null;
    }
    await FirebaseAppCheck.instanceFor(app: app).activate(
      androidProvider: kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
      appleProvider: kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
    );
    return FirebaseFunctions.instanceFor(app: app);
  }

  static String _callableError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'resource-exhausted':
        return 'Too many attempts. Try again later.';
      case 'unauthenticated':
        return 'Current cloud password is wrong.';
      case 'permission-denied':
        return e.message ?? 'Not allowed.';
      case 'invalid-argument':
      case 'failed-precondition':
        return e.message ?? 'Invalid request.';
      default:
        return 'Cloud request failed (${e.code}).';
    }
  }

  /// Apna cloud password badlo (purana password server par check hota hai), phir naye password se dobara sign-in.
  /// Local password alag rehta hai — pehle local wala badlein. Kabhi throw nahi karta; nakaam => [lastError].
  static Future<bool> changeMyPassword(String username, String oldPassword, String newPassword) async {
    lastError = '';
    try {
      final f = await _functions();
      if (f == null) return false;
      await f
          .httpsCallable('changeMyPassword')
          .call<Object?>({'oldPassword': oldPassword, 'newPassword': newPassword})
          .timeout(const Duration(seconds: 25));
      // Server refresh tokens revoke karta hai: naye password se foran dobara sign-in.
      return await signIn(username, newPassword);
    } on FirebaseFunctionsException catch (e) {
      lastError = _callableError(e);
      return false;
    } on TimeoutException {
      lastError = 'Cloud request timed out (check internet).';
      return false;
    } catch (e) {
      lastError = 'Cloud request failed: $e';
      return false;
    }
  }

  /// Sirf admin: apni branch mein staff account banao / role / active / password badlo (server check karta hai).
  /// Naye account ke liye [password] zaroori hai. Kabhi throw nahi karta; nakaam => [lastError].
  static Future<bool> adminSetAccount({
    required String username,
    required String role,
    required bool active,
    String? password,
  }) async {
    lastError = '';
    try {
      final f = await _functions();
      if (f == null) return false;
      await f.httpsCallable('adminSetStaffAccount').call<Object?>({
        'username': username.trim(),
        'role': role,
        'active': active,
        if (password != null) 'password': password,
      }).timeout(const Duration(seconds: 25));
      return true;
    } on FirebaseFunctionsException catch (e) {
      lastError = _callableError(e);
      return false;
    } on TimeoutException {
      lastError = 'Cloud request timed out (check internet).';
      return false;
    } catch (e) {
      lastError = 'Cloud request failed: $e';
      return false;
    }
  }

  /// Verified token se role (`admin|manager|cashier`); verified session na ho to null.
  static Future<String?> currentRole() async {
    try {
      final app = await CloudConfigStore.firebaseApp();
      if (app == null) return null;
      final user = FirebaseAuth.instanceFor(app: app).currentUser;
      if (user == null || user.isAnonymous) return null;
      final c = (await user.getIdTokenResult()).claims ?? const <String, dynamic>{};
      final ok = c['active'] == true && c['staffId'] is String && c['branchId'] is String;
      final r = c['role'];
      return ok && r is String && _roles.contains(r) ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// Secure mode mein cashier ki sync entry server (`pushSyncOp`) se lagti hai: branch / role server khud claims
  /// se leta hai, client ka bheja hua nahi. Kamyab = normal return; nakaam => [StaffPushException].
  static Future<void> pushOp({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    String? opId,
    Map<String, Object?> seedFields = const {},
  }) async {
    try {
      final f = await _functions();
      if (f == null) throw StaffPushException(StaffPushFailure.offline, lastError);
      await f.httpsCallable('pushSyncOp').call<Object?>({
        'entityType': entityType,
        'entityId': entityId,
        'operation': operation,
        'payload': payload,
        if (opId != null) 'opId': opId,
        if (seedFields.isNotEmpty) 'seedFields': seedFields,
      }).timeout(const Duration(seconds: 30));
    } on StaffPushException {
      rethrow;
    } on FirebaseFunctionsException catch (e) {
      final msg = e.message ?? e.code;
      switch (e.code) {
        case 'unavailable':
        case 'deadline-exceeded':
        case 'resource-exhausted':
        case 'internal':
          throw StaffPushException(StaffPushFailure.offline, 'Cloud not reachable ($msg)');
        case 'unauthenticated':
          throw const StaffPushException(StaffPushFailure.offline,
              'Secure cloud session expired — log in again with your password while online.');
        case 'permission-denied':
          throw StaffPushException(StaffPushFailure.denied, msg);
        default:
          throw StaffPushException(StaffPushFailure.rejected, msg);
      }
    } on TimeoutException {
      throw const StaffPushException(StaffPushFailure.offline, 'Cloud request timed out (check internet).');
    }
  }

  /// Logout / switch user / feature off: cloud session khatam.
  static Future<void> signOut() async {
    try {
      final app = await CloudConfigStore.firebaseApp();
      if (app != null) await FirebaseAuth.instanceFor(app: app).signOut();
    } catch (_) {}
    try {
      (await SharedPreferences.getInstance()).remove(_userKey);
    } catch (_) {}
  }

  /// Logout par: sirf tab cloud signOut jab feature on ho (off ho to purana anonymous session na chhedein).
  static Future<void> signOutIfEnabled() async {
    if (await isEnabled()) await signOut();
  }
}
