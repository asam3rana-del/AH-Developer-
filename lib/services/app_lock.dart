import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/user_repository.dart';

/// Mirrors AppLock.kt — jab poori app background mein chali jaye aur Settings > Security
/// "Fingerprint Only" ya "Both" ho, to wapas aane par login screen par bhej deta hai.
///
/// Android ka activity start/stop counter Flutter mein lifecycle (paused -> resumed) se milta hai.
///  * `login_method` memory mein cache hota hai (koi DB race nahi).
///  * Login screen khud is lock ka hissa hai, isliye us dauran arm nahi hota ([onLoginScreen]).
///  * `pendingReauth` SharedPreferences mein bhi rakha jata hai taake process kill hone ke baad
///    bhi re-lock ho (register() isay restore karta hai).
///  * "password" / "none" kabhi re-lock arm nahi karte.
class AppLock with WidgetsBindingObserver {
  AppLock._();
  static final AppLock instance = AppLock._();

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static const _prefKey = 'pending_reauth';

  bool _registered = false;
  bool _pendingReauth = false;
  String _cachedLoginMethod = 'password';
  WidgetBuilder? _loginBuilder;

  /// LoginScreen khuli ho to true (us dauran lock arm/consume nahi hota).
  bool onLoginScreen = false;

  /// Biometric prompt khud paused/resumed events paida kar sakta hai — us dauran ignore karein.
  bool suspendLock = false;

  /// `main()` mein ek dafa. [loginBuilder] wo screen banata hai jahan re-lock par jana hai.
  Future<void> register({required WidgetBuilder loginBuilder}) async {
    if (_registered) return;
    _registered = true;
    _loginBuilder = loginBuilder;

    final p = await SharedPreferences.getInstance();
    _pendingReauth = p.getBool(_prefKey) ?? false;
    _cachedLoginMethod = await UserRepository.instance.getSetting('login_method') ?? 'password';

    WidgetsBinding.instance.addObserver(this);
    // Process kill ke baad fresh start: pehle se armed re-lock ho to pehli frame ke baad login par bhejo.
    if (_pendingReauth) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _relockIfNeeded());
    }
  }

  /// Settings mein login method badalte hi call karein (cache theek rahe).
  void updateCachedLoginMethod(String method) => _cachedLoginMethod = method;

  /// LoginScreen dikhne par: user ab authenticate karne hi wala hai, isliye baqi pending re-lock khatam.
  void enterLoginScreen() {
    onLoginScreen = true;
    _setPending(false);
  }

  void leaveLoginScreen() => onLoginScreen = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (suspendLock) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _armIfNeeded();
        break;
      case AppLifecycleState.resumed:
        _relockIfNeeded();
        break;
      default:
        break;
    }
  }

  void _armIfNeeded() {
    if (onLoginScreen) return;
    if (_cachedLoginMethod == 'fingerprint' || _cachedLoginMethod == 'both') {
      _setPending(true);
    }
  }

  void _relockIfNeeded() {
    if (!_pendingReauth || onLoginScreen) return;
    final nav = navigatorKey.currentState;
    final builder = _loginBuilder;
    if (nav == null || builder == null) return;
    _setPending(false);
    // Saari purani screens hata do taake Back se lock skip na ho.
    nav.pushAndRemoveUntil(MaterialPageRoute(builder: builder), (_) => false);
  }

  void _setPending(bool v) {
    if (_pendingReauth == v) return;
    _pendingReauth = v;
    SharedPreferences.getInstance().then((p) => p.setBool(_prefKey, v));
  }
}
