import 'package:firebase_auth/firebase_auth.dart' hide User;

import '../models/misc_entities.dart';
import '../sync/cloud_config_store.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';

/// Kotlin `LoginActivity.kt` ka "Phone OTP" hissa (login_method == "otp"): Firebase Phone Auth se OTP
/// verify hone ke baad us phone number se local `User` dhoondh kar login.
///
/// Do hisse:
///  * saaf logic (test: `test/otp_login_test.dart`): [resolveOtpUser], [verifyLinkPassword], [isValidOtpCode]
///  * [PhoneOtpAuth]: Firebase `verifyPhoneNumber` / `signInWithCredential` ka patla wrapper.
///
/// FARQ (Kotlin se): Kotlin default `FirebaseAuth.getInstance()` istemal karta hai; Flutter mein wahi
/// app jo sync ke liye chalti hai ([CloudConfigStore.firebaseApp]: admin ki custom config, warna build ka
/// default). Cloud project na ho to OTP nahi chal sakta — saaf message milta hai (password se login karein).

/// OTP verify hone ke baad kya karna hai.
enum OtpOutcomeKind {
  /// Phone kisi active staff se link hai => seedha login.
  login,

  /// Phone kisi se link nahi magar sirf ek active user hai => us ka password ek baar puchho, phir link.
  /// (Kotlin SECURITY FIX: sirf OTP ki milkiyat se naya number kisi admin account se na bandhe.)
  linkNeedsPassword,

  /// Phone kisi se link nahi aur link karne wala akela user bhi nahi.
  notLinked,
}

class OtpResolution {
  final OtpOutcomeKind kind;
  final User? user;
  const OtpResolution(this.kind, [this.user]);
}

/// Kotlin `verifyAndLogin` ka faisla. [byPhone] = `findByPhone(phone)` (active=1), [activeUsers] = active users.
OtpResolution resolveOtpUser({required User? byPhone, required List<User> activeUsers}) {
  if (byPhone != null && byPhone.active) return OtpResolution(OtpOutcomeKind.login, byPhone);
  if (activeUsers.length == 1) return OtpResolution(OtpOutcomeKind.linkNeedsPassword, activeUsers.first);
  return const OtpResolution(OtpOutcomeKind.notLinked);
}

/// Kotlin `askPasswordBeforeFirstPhoneLink` ki jaanch: hashed ho to hash se, purani plain-text ho to barabari.
Future<bool> verifyLinkPassword(User user, String typed) async {
  if (PasswordHasher.isHashed(user.passwordHash)) return PasswordHasher.verify(typed, user.passwordHash);
  return user.passwordHash == typed;
}

/// Kotlin: `code.length == 6`.
bool isValidOtpCode(String code) => code.trim().length == 6;

/// Login screen mein phone khali na ho.
bool isPhoneEntered(String phone) => phone.trim().isNotEmpty;

class OtpException implements Exception {
  final String message;
  const OtpException(this.message);
  @override
  String toString() => message;
}

/// Firebase Phone Auth (Kotlin `PhoneAuthProvider.verifyPhoneNumber` + `signInWithCredential`).
class PhoneOtpAuth {
  PhoneOtpAuth._();
  static final PhoneOtpAuth instance = PhoneOtpAuth._();

  /// Kotlin `setTimeout(60, SECONDS)`.
  static const Duration timeout = Duration(seconds: 60);

  Future<FirebaseAuth> _auth() async {
    final app = await CloudConfigStore.firebaseApp();
    if (app == null) {
      throw OtpException(Loc.t(
        'Cloud project is not set up on this device — OTP login needs it. Login with password and set it up in Settings > Cloud Sync Setup.',
        'اس ڈیوائس پر کلاؤڈ پراجیکٹ سیٹ نہیں — OTP لاگ اِن کے لیے ضروری ہے۔ پاس ورڈ سے لاگ اِن کریں اور Settings > Cloud Sync Setup میں سیٹ کریں۔',
      ));
    }
    return FirebaseAuth.instanceFor(app: app);
  }

  /// OTP bhejo. [onCodeSent] => verificationId; [onAutoVerified] => Android auto-retrieval (Kotlin
  /// `onVerificationCompleted`); [onFailed] => `Failed: <msg>`.
  Future<void> sendCode(
    String phone, {
    required void Function(String verificationId) onCodeSent,
    required void Function(PhoneAuthCredential credential) onAutoVerified,
    required void Function(String message) onFailed,
  }) async {
    final auth = await _auth();
    await auth.verifyPhoneNumber(
      phoneNumber: phone.trim(),
      timeout: timeout,
      verificationCompleted: onAutoVerified,
      verificationFailed: (e) => onFailed(e.message ?? e.code),
      codeSent: (verificationId, _) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  PhoneAuthCredential credentialFor(String verificationId, String smsCode) =>
      PhoneAuthProvider.credential(verificationId: verificationId, smsCode: smsCode.trim());

  /// Kotlin `auth.signInWithCredential(credential)`: theek to true, warna false ("OTP galat hai").
  Future<bool> signIn(PhoneAuthCredential credential) async {
    try {
      final auth = await _auth();
      await auth.signInWithCredential(credential);
      return true;
    } on OtpException {
      rethrow;
    } catch (_) {
      return false;
    }
  }
}
