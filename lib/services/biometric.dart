import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'app_lock.dart';

/// Android `BiometricManager` / `BiometricPrompt` (BIOMETRIC_STRONG) ka Flutter roop (local_auth).
class Biometric {
  Biometric._();
  static final LocalAuthentication _auth = LocalAuthentication();

  /// Device par fingerprint/face enrolled hai? (Kotlin: canAuthenticate == BIOMETRIC_SUCCESS)
  static Future<bool> isAvailable() async {
    try {
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  /// true = match hua. Cancel / fail / error par false.
  static Future<bool> authenticate({required String reason}) async {
    AppLock.instance.suspendLock = true; // prompt ke apne lifecycle events lock arm na karein
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } on PlatformException {
      return false;
    } finally {
      AppLock.instance.suspendLock = false;
    }
  }
}
