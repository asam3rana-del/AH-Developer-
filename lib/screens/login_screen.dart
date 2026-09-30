import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart' show PhoneAuthCredential;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../db/user_repository.dart';
import '../models/misc_entities.dart';
import '../services/app_lock.dart';
import '../services/biometric.dart';
import '../services/otp_login.dart';
import '../services/session.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';
import 'dashboard_screen.dart';
import '../theme/theme_manager.dart';

/// Mirrors LoginActivity.kt (password + "none" login method + pehli dafa admin setup).
/// Login methods: password, none, fingerprint, both (local_auth), otp (Firebase Phone Auth — `lib/services/otp_login.dart`).
/// OTP: phone kisi active staff se link ho to seedha login; warna akela active user ho to us ka password ek baar
/// puch kar phone link (Kotlin SECURITY FIX). Cloud project na ho to OTP nahi chal sakta => password fields wapas.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _repo = UserRepository.instance;
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  final _otpPhone = TextEditingController();
  final _otpCode = TextEditingController();

  bool _loading = true;
  bool _setupMode = false;
  bool _busy = false;
  bool _showPass = false;
  bool _fingerprintOnly = false;
  bool _otpMode = false;
  String? _verificationId;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppLock.instance.enterLoginScreen();
    _init();
  }

  @override
  void dispose() {
    AppLock.instance.leaveLoginScreen();
    _name.dispose();
    _user.dispose();
    _pass.dispose();
    _confirm.dispose();
    _otpPhone.dispose();
    _otpCode.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final seeded = await _repo.getSetting('admin_seeded');
    if (seeded == null) {
      setState(() { _setupMode = true; _loading = false; });
      return;
    }
    // "none" mode: session ho to login skip (logout ke baad loop na bane).
    final method = await _repo.getSetting('login_method') ?? 'password';
    if (method == 'none' && Session.isLoggedIn) {
      _goMain();
      return;
    }
    // Data restore/import ke baad password khatam: 'skip_login'=1 ho to seedha andar (admin ya last user).
    if (await _repo.getSetting('skip_login') == '1') {
      final users = await _repo.activeUsers();
      final lastU = await _repo.getSetting('last_username');
      User? pick;
      for (final u in users) { if (lastU != null && u.username.toLowerCase() == lastU.toLowerCase()) pick = u; }
      pick ??= users.where((u) => u.role == 'admin').isNotEmpty ? users.firstWhere((u) => u.role == 'admin') : (users.isNotEmpty ? users.first : null);
      if (pick != null) {
        await Session.start(pick);
        _goMain();
        return;
      }
    }
    final last = await _repo.getSetting('last_username');
    if (last != null) _user.text = last;
    // "Fingerprint Only": pehle kabhi login na hua ho to password lena zaroori; warna prompt khud khule.
    if (method == 'fingerprint' && last != null && last.isNotEmpty) {
      setState(() { _fingerprintOnly = true; _loading = false; });
      _triggerFingerprintUnlock();
      return;
    }
    // "OTP (Phone Number)": sirf phone/OTP wala panel (Kotlin applyLoginMethod "otp").
    // Phone OTP sirf Android / iOS par (Firebase Phone Auth desktop par nahi) — desktop par password.
    if (method == 'otp' && (kIsWeb || Platform.isAndroid || Platform.isIOS)) {
      setState(() { _otpMode = true; _loading = false; });
      return;
    }
    setState(() => _loading = false);
  }

  void _goMain() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const DashboardScreen()));
  }

  Future<void> _createAdmin() async {
    final displayName = _name.text.trim();
    final username = _user.text.trim();
    final password = _pass.text;
    final err = displayName.isEmpty
        ? Loc.t('Enter your name', 'اپنا نام لکھیں')
        : username.isEmpty
            ? Loc.t('Enter a username', 'یوزر نیم لکھیں')
            : username.contains(' ')
                ? Loc.t('Username must not contain spaces', 'یوزر نیم میں خالی جگہ نہیں ہونی چاہیے')
                : password.length < 6
                    ? Loc.t('Password must be at least 6 characters', 'پاس ورڈ کم از کم 6 حروف کا ہو')
                    : password != _confirm.text
                        ? Loc.t('Passwords do not match', 'دونوں پاس ورڈ مماثل نہیں')
                        : null;
    if (err != null) return setState(() => _error = err);

    setState(() { _busy = true; _error = null; });
    if (await _repo.find(username) != null) {
      return setState(() { _busy = false; _error = Loc.t('Username already exists', 'یہ یوزر نیم پہلے سے موجود ہے'); });
    }
    final admin = User(
      username: username,
      displayName: displayName,
      role: 'admin',
      passwordHash: await PasswordHasher.hash(password),
    );
    await _repo.upsert(admin);
    await _repo.setSetting('admin_seeded', '1');
    await _repo.setSetting('last_username', username);
    await Session.start(admin);
    _goMain();
  }

  Future<void> _login() async {
    setState(() { _busy = true; _error = null; });
    final username = _user.text.trim();
    final typed = _pass.text;
    final user = await _repo.find(username);

    var ok = false;
    if (user != null && user.active) {
      if (PasswordHasher.isHashed(user.passwordHash)) {
        ok = await PasswordHasher.verify(typed, user.passwordHash);
        // Keyboard autocorrect aksar aakhir mein space laga deta hai — ek dafa trim kar ke bhi try.
        if (!ok && typed != typed.trim()) ok = await PasswordHasher.verify(typed.trim(), user.passwordHash);
      } else if (user.passwordHash == typed) {
        ok = true; // purani plain-text — ek dafa qubool, phir hash mein badal do
        await _repo.upsert(User(
          username: user.username,
          displayName: user.displayName,
          role: user.role,
          passwordHash: await PasswordHasher.hash(typed),
          active: user.active,
          phone: user.phone,
        ));
      }
    }
    if (!ok) {
      final msg = user == null
          ? Loc.t('User not found: "$username"', 'یوزر نہیں ملا: "$username"')
          : !user.active
              ? Loc.t('This user is inactive', 'یہ یوزر غیر فعال ہے')
              : Loc.t('Wrong password', 'پاس ورڈ غلط ہے');
      return setState(() { _busy = false; _error = msg; });
    }
    await _repo.setSetting('last_username', user!.username);
    final method = await _repo.getSetting('login_method') ?? 'password';
    if (method == 'both') {
      await _requireFingerprintThenProceed(user);
    } else {
      await _completeLogin(user);
    }
  }

  /// Forgot password: phone ka PIN/pattern se owner verify -> naya password + login method "password".
  Future<void> _forgotPassword() async {
    final username = _user.text.trim();
    if (username.isEmpty) {
      return setState(() => _error = Loc.t('Enter your username first', 'پہلے یوزر نیم لکھیں'));
    }
    final user = await _repo.find(username);
    if (user == null) {
      return setState(() => _error = Loc.t('User not found: "$username"', 'یوزر نہیں ملا: "$username"'));
    }
    final owner = await Biometric.authenticateDeviceOwner(
        reason: Loc.t('Verify with phone PIN / pattern to reset password', 'پاس ورڈ ری سیٹ کے لیے فون کا پن / پیٹرن ڈالیں'));
    if (!owner) {
      return setState(() => _error = Loc.t('Phone verification failed', 'فون ویریفکیشن ناکام'));
    }
    if (!mounted) return;
    final c = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${Loc.t('New password', 'نیا پاس ورڈ')} — ${user.username}'),
        content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: Loc.t('At least 6 characters', 'کم از کم 6 حروف'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ'))),
        ],
      ),
    );
    final newPass = c.text.trim();
    if (go != true) return;
    if (newPass.length < 6) {
      return setState(() => _error = Loc.t('Password must be at least 6 characters', 'پاس ورڈ کم از کم 6 حروف کا ہو'));
    }
    await _repo.upsert(User(
      username: user.username,
      displayName: user.displayName,
      role: user.role,
      passwordHash: await PasswordHasher.hash(newPass),
      active: true,
      phone: user.phone,
    ));
    await _repo.setSetting('login_method', 'password');
    await _repo.insertAudit(user.username, 'password_reset', user.username, 'Reset from login screen via device PIN');
    if (!mounted) return;
    setState(() { _pass.text = newPass; _error = null; _showPass = true; });
    _toast(Loc.t('Password reset. Tap Login.', 'پاس ورڈ ری سیٹ ہو گیا۔ لاگ اِن دبائیں۔'));
  }

  Future<void> _completeLogin(User user) async {
    await Session.start(user);
    _goMain();
  }

  /// "Both" mode: password ke baad fingerprint bhi verify.
  Future<void> _requireFingerprintThenProceed(User user) async {
    if (!await Biometric.isAvailable()) {
      _toast(Loc.t('No fingerprint set up on this device, logging in with password',
          'اس ڈیوائس پر فنگر پرنٹ سیٹ نہیں، پاس ورڈ سے لاگ اِن ہو رہا ہے'));
      return _completeLogin(user);
    }
    final ok = await Biometric.authenticate(reason: Loc.t('Show your fingerprint to complete login', 'لاگ اِن مکمل کرنے کے لیے اپنی فنگر پرنٹ دکھائیں'));
    if (!ok) {
      if (mounted) setState(() { _busy = false; _error = Loc.t('Fingerprint not verified', 'فنگر پرنٹ ویریفائی نہیں ہوا'); });
      return;
    }
    await _completeLogin(user);
  }

  /// "Fingerprint Only": aakhri login wale user ke liye prompt.
  Future<void> _triggerFingerprintUnlock() async {
    final last = await _repo.getSetting('last_username');
    if (last == null || last.isEmpty) {
      _toast(Loc.t('Login with password the first time', 'پہلی دفعہ پاس ورڈ سے لاگ اِن کریں'));
      return;
    }
    final user = await _repo.find(last);
    if (user == null || !user.active) {
      _toast(Loc.t('User not found, login with password', 'یوزر نہیں ملا، پاس ورڈ سے لاگ اِن کریں'));
      if (mounted) setState(() => _fingerprintOnly = false);
      return;
    }
    if (!await Biometric.isAvailable()) {
      _toast(Loc.t('No fingerprint set up on this device', 'اس ڈیوائس پر فنگر پرنٹ سیٹ نہیں'));
      if (mounted) setState(() => _fingerprintOnly = false); // lockout se bachao: password fields wapas
      return;
    }
    final ok = await Biometric.authenticate(reason: Loc.t('Show your fingerprint to login', 'لاگ اِن کے لیے اپنی فنگر پرنٹ دکھائیں'));
    if (!ok) {
      _toast(Loc.t('Fingerprint not verified, try again', 'فنگر پرنٹ میچ نہیں ہوا، دوبارہ کوشش کریں'));
      return;
    }
    await _completeLogin(user);
  }

  // ---- Phone OTP (Kotlin sendOtpBtn / verifyOtpBtn / verifyAndLogin) ----

  Future<void> _sendOtp() async {
    final phone = _otpPhone.text.trim();
    if (!isPhoneEntered(phone)) {
      _toast(Loc.t('Enter phone number', 'فون نمبر درج کریں'));
      return;
    }
    try {
      await PhoneOtpAuth.instance.sendCode(
        phone,
        onCodeSent: (id) {
          if (!mounted) return;
          setState(() { _verificationId = id; _error = null; });
          _toast(Loc.t('OTP sent', 'OTP بھیج دیا گیا'));
        },
        onAutoVerified: (cred) => _verifyAndLogin(cred, phone),
        onFailed: (msg) => _toast('Failed: $msg'),
      );
    } on OtpException catch (e) {
      // Cloud project hi nahi => OTP kabhi nahi chalega; lockout se bachao: password fields wapas.
      if (mounted) setState(() { _otpMode = false; _error = e.message; });
    }
  }

  Future<void> _verifyOtp() async {
    final id = _verificationId;
    if (id == null) return;
    final code = _otpCode.text.trim();
    if (!isValidOtpCode(code)) {
      _toast(Loc.t('Enter the 6-digit code', '6 ہندسوں کا کوڈ درج کریں'));
      return;
    }
    await _verifyAndLogin(PhoneOtpAuth.instance.credentialFor(id, code), _otpPhone.text.trim());
  }

  /// Firebase se OTP verify hone ke baad us phone se local User dhoondh kar login complete karo.
  Future<void> _verifyAndLogin(PhoneAuthCredential cred, String phone) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (!await PhoneOtpAuth.instance.signIn(cred)) {
        _toast(Loc.t('Wrong OTP', 'OTP غلط ہے'));
        return;
      }
      final r = resolveOtpUser(byPhone: await _repo.findByPhone(phone), activeUsers: await _repo.activeUsers());
      switch (r.kind) {
        case OtpOutcomeKind.login:
          await _repo.setSetting('last_username', r.user!.username);
          await _completeLogin(r.user!);
        case OtpOutcomeKind.linkNeedsPassword:
          await _askPasswordBeforeFirstPhoneLink(r.user!, phone);
        case OtpOutcomeKind.notLinked:
          _toast(Loc.t('This number is not linked to any staff. Add it in Settings > Manage Users.',
              'یہ نمبر کسی اسٹاف سے لنک نہیں۔ Settings > Manage Users میں شامل کروائیں۔'));
      }
    } on OtpException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Kotlin `askPasswordBeforeFirstPhoneLink`: sirf OTP ki milkiyat se naya number admin se na bandhe.
  Future<void> _askPasswordBeforeFirstPhoneLink(User user, String phone) async {
    final field = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Link phone to account', 'فون کو اکاؤنٹ سے لنک کریں')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(Loc.t('OTP verified. For security, also verify ${user.displayName}\'s current password.',
              'OTP ویریفائی ہو گیا۔ سیکیورٹی کے لیے ${user.displayName} کا موجودہ پاس ورڈ بھی ویریفائی کریں۔')),
          const SizedBox(height: 10),
          TextField(
            controller: field,
            obscureText: true,
            decoration: InputDecoration(hintText: Loc.t('${user.displayName} password', '${user.displayName} کا پاس ورڈ')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, field.text), child: Text(Loc.t('Verify', 'ویریفائی'))),
        ],
      ),
    );
    // field.dispose() jaan boojh kar nahi: dialog band hone ki animation abhi controller use kar rahi hoti hai
    // (dispose se "used after being disposed" crash aata hai) — GC khud saaf kar dega.
    if (typed == null) return;
    if (!await verifyLinkPassword(user, typed)) {
      _toast(Loc.t('Wrong password — phone not linked', 'پاس ورڈ غلط ہے — فون لنک نہیں ہوا'));
      return;
    }
    final linked = User(
      username: user.username,
      displayName: user.displayName,
      role: user.role,
      passwordHash: user.passwordHash,
      active: user.active,
      phone: phone,
    );
    await _repo.upsert(linked);
    await _repo.setSetting('last_username', linked.username);
    _toast(Loc.t('Phone linked to account.', 'فون اکاؤنٹ سے لنک ہو گیا۔'));
    await _completeLogin(linked);
  }

  Widget _otpPanel() => Column(children: [
        TextField(
          controller: _otpPhone,
          keyboardType: TextInputType.phone,
          decoration: _dec(Loc.t('Phone (+92XXXXXXXXXX)', 'فون (+92XXXXXXXXXX)'), Icons.phone_outlined),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: _busy ? null : _sendOtp,
            child: Text(_verificationId == null ? Loc.t('SEND OTP', 'OTP بھیجیں') : Loc.t('RESEND OTP', 'دوبارہ OTP بھیجیں')),
          ),
        ),
        if (_verificationId != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _otpCode,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onSubmitted: (_) => _verifyOtp(),
            decoration: _dec(Loc.t('6-digit code', '6 ہندسوں کا کوڈ'), Icons.pin_outlined),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.navy, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              onPressed: _busy ? null : _verifyOtp,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(Loc.t('VERIFY & LOGIN', 'ویریفائی اور لاگ اِن')),
            ),
          ),
        ],
      ]);

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  InputDecoration _dec(String label, IconData icon, {Widget? suffix}) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: ThemeManager.palette.textMuted),
        suffixIcon: suffix,
        filled: true,
        fillColor: ThemeManager.palette.fieldFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: ThemeManager.palette.border)),
      );

  Widget _fingerprintPanel() => Column(children: [
        Icon(Icons.fingerprint, size: 72, color: ThemeManager.palette.teal),
        const SizedBox(height: 8),
        Text(Loc.t('Verify with your fingerprint', 'اپنی فنگر پرنٹ سے تصدیق کریں'), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            onPressed: _triggerFingerprintUnlock,
            icon: const Icon(Icons.fingerprint),
            label: Text(Loc.t('FINGERPRINT', 'فنگر پرنٹ')),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [ThemeManager.palette.navy, ThemeManager.palette.navyLight]),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircleAvatar(radius: 40, backgroundColor: Colors.white, child: Icon(Icons.lock, size: 36, color: ThemeManager.palette.navyInk)),
                  const SizedBox(height: 16),
                  const Text('AH Developer — Kiryana Store', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_setupMode ? Loc.t('First-time setup', 'پہلی دفعہ سیٹ اپ') : Loc.t('Sign in to continue', 'جاری رکھنے کے لیے لاگ اِن کریں'),
                      style: TextStyle(color: ThemeManager.palette.headerSubtitleColor)),
                  const SizedBox(height: 26),
                  Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(children: [
                        if (_fingerprintOnly) _fingerprintPanel(),
                        if (_otpMode) _otpPanel(),
                        if (!_fingerprintOnly && !_otpMode) ...[
                        if (_setupMode) ...[
                          TextField(controller: _name, decoration: _dec(Loc.t('Your name', 'آپ کا نام'), Icons.person_outline)),
                          const SizedBox(height: 12),
                        ],
                        TextField(controller: _user, autocorrect: false, decoration: _dec(Loc.t('Username', 'یوزر نیم'), Icons.badge_outlined)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pass,
                          obscureText: !_showPass,
                          onSubmitted: (_) => _setupMode ? null : _login(),
                          decoration: _dec(Loc.t('Password', 'پاس ورڈ'), Icons.lock_outline,
                              suffix: IconButton(
                                icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                                onPressed: () => setState(() => _showPass = !_showPass),
                              )),
                        ),
                        if (_setupMode) ...[
                          const SizedBox(height: 12),
                          TextField(controller: _confirm, obscureText: !_showPass, decoration: _dec(Loc.t('Confirm password', 'پاس ورڈ دوبارہ'), Icons.lock_outline)),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: TextStyle(color: ThemeManager.palette.red)),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                            onPressed: _busy ? null : (_setupMode ? _createAdmin : _login),
                            child: _busy
                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(_setupMode ? Loc.t('Create Admin Account', 'ایڈمن اکاؤنٹ بنائیں') : Loc.t('Login', 'لاگ اِن')),
                          ),
                        ),
                        if (!_setupMode)
                          TextButton(
                            onPressed: _busy ? null : _forgotPassword,
                            child: Text(Loc.t('Forgot password? Reset with phone PIN', 'پاس ورڈ بھول گئے؟ فون پن سے ری سیٹ')),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
