import 'package:flutter/material.dart';

import '../db/user_repository.dart';
import '../models/misc_entities.dart';
import '../services/app_lock.dart';
import '../services/biometric.dart';
import '../services/session.dart';
import '../theme/app_colors.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';
import 'dashboard_screen.dart';

/// Mirrors LoginActivity.kt (password + "none" login method + pehli dafa admin setup).
/// Login methods: password, none, fingerprint, both (local_auth). TODO(Phase 10): OTP / phone link.
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

  bool _loading = true;
  bool _setupMode = false;
  bool _busy = false;
  bool _showPass = false;
  bool _fingerprintOnly = false;
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
    final last = await _repo.getSetting('last_username');
    if (last != null) _user.text = last;
    // "Fingerprint Only": pehle kabhi login na hua ho to password lena zaroori; warna prompt khud khule.
    if (method == 'fingerprint' && last != null && last.isNotEmpty) {
      setState(() { _fingerprintOnly = true; _loading = false; });
      _triggerFingerprintUnlock();
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
      return setState(() { _busy = false; _error = Loc.t('Invalid login', 'غلط لاگ اِن'); });
    }
    await _repo.setSetting('last_username', user!.username);
    final method = await _repo.getSetting('login_method') ?? 'password';
    if (method == 'both') {
      await _requireFingerprintThenProceed(user);
    } else {
      await _completeLogin(user);
    }
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

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  InputDecoration _dec(String label, IconData icon, {Widget? suffix}) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.textMuted),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppColors.fieldFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
      );

  Widget _fingerprintPanel() => Column(children: [
        const Icon(Icons.fingerprint, size: 72, color: AppColors.teal),
        const SizedBox(height: 8),
        Text(Loc.t('Verify with your fingerprint', 'اپنی فنگر پرنٹ سے تصدیق کریں'), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
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
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AppColors.navy, AppColors.navyLight]),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircleAvatar(radius: 40, backgroundColor: Colors.white, child: Icon(Icons.lock, size: 36, color: AppColors.navy)),
                  const SizedBox(height: 16),
                  const Text('AH Developer — Kiryana Store', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_setupMode ? Loc.t('First-time setup', 'پہلی دفعہ سیٹ اپ') : Loc.t('Sign in to continue', 'جاری رکھنے کے لیے لاگ اِن کریں'),
                      style: const TextStyle(color: AppColors.headerSubtitle)),
                  const SizedBox(height: 26),
                  Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(children: [
                        if (_fingerprintOnly) _fingerprintPanel(),
                        if (!_fingerprintOnly) ...[
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
                          Text(_error!, style: const TextStyle(color: AppColors.red)),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: AppColors.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                            onPressed: _busy ? null : (_setupMode ? _createAdmin : _login),
                            child: _busy
                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(_setupMode ? Loc.t('Create Admin Account', 'ایڈمن اکاؤنٹ بنائیں') : Loc.t('Login', 'لاگ اِن')),
                          ),
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
