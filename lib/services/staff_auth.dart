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
class StaffAuth {
  StaffAuth._();

  static const _prefKey = 'staff_cloud_auth_enabled';
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

  /// Logout / switch user / feature off: cloud session khatam.
  static Future<void> signOut() async {
    try {
      final app = await CloudConfigStore.firebaseApp();
      if (app != null) await FirebaseAuth.instanceFor(app: app).signOut();
    } catch (_) {}
  }

  /// Logout par: sirf tab cloud signOut jab feature on ho (off ho to purana anonymous session na chhedein).
  static Future<void> signOutIfEnabled() async {
    if (await isEnabled()) await signOut();
  }
}
