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
  static int _fails = 0;

  /// 2 dafa fingerprint fail hone par agli dafa device PIN/pattern/password bhi qubool (lockout se bachao).
  static Future<bool> authenticate({required String reason}) async {
    final allowDeviceCredential = _fails >= 2;
    AppLock.instance.suspendLock = true; // prompt ke apne lifecycle events lock arm na karein
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(biometricOnly: !allowDeviceCredential, stickyAuth: true),
      );
      _fails = ok ? 0 : _fails + 1;
      return ok;
    } on PlatformException {
      _fails++;
      return false;
    } finally {
      AppLock.instance.suspendLock = false;
    }
  }

  /// Sirf phone ka PIN / pattern / password (ya fingerprint) — "Forgot password" ke liye.
  static Future<bool> authenticateDeviceOwner({required String reason}) async {
    AppLock.instance.suspendLock = true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } on PlatformException {
      return false;
    } finally {
      AppLock.instance.suspendLock = false;
    }
  }
}
