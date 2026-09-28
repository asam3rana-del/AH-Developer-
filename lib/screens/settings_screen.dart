import 'package:flutter/material.dart';

import '../db/user_repository.dart';
import '../models/misc_entities.dart';
import '../services/app_lock.dart';
import '../services/biometric.dart';
import '../services/session.dart';
import '../theme/app_colors.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';
import '../widgets/premium_header.dart';
import 'login_screen.dart';
import 'user_management_screen.dart';

/// Mirrors SettingsActivity.kt (pehla hissa): Shop Info, Login method, Update Login,
/// Language, Manage Users, Logout.
/// Login method: password / fingerprint / both / none. Dark mode switch.
/// TODO: Printer (Phase 12), Backup (Phase 11), Cloud Sync (Phase 10), OTP login (Phase 10).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _repo = UserRepository.instance;
  final _shopName = TextEditingController();
  final _shopPhone = TextEditingController();
  final _newUsername = TextEditingController();
  final _newPassword = TextEditingController();
  String _loginMethod = 'password';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _shopName.text = await _repo.getSetting('shop_name') ?? '';
    _shopPhone.text = await _repo.getSetting('shop_phone') ?? '';
    final m = await _repo.getSetting('login_method') ?? 'password';
    if (mounted) setState(() => _loginMethod = const ['none', 'fingerprint', 'both'].contains(m) ? m : 'password');
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveShop() async {
    await _repo.setSetting('shop_name', _shopName.text.trim());
    await _repo.setSetting('shop_phone', _shopPhone.text.trim());
    _toast(Loc.t('Settings saved', 'سیٹنگز محفوظ ہو گئیں'));
  }

  Future<void> _setLoginMethod(String m) async {
    // Lockout se bachao: fingerprint wale modes tabhi jab device par fingerprint enrolled ho.
    if ((m == 'fingerprint' || m == 'both') && !await Biometric.isAvailable()) {
      return _toast(Loc.t('No fingerprint set up on this device', 'اس ڈیوائس پر فنگر پرنٹ سیٹ نہیں'));
    }
    await _repo.setSetting('login_method', m);
    AppLock.instance.updateCachedLoginMethod(m);
    if (mounted) setState(() => _loginMethod = m);
  }

  Future<void> _updateLogin() async {
    final current = Session.username ?? '';
    if (current.isEmpty) return _toast(Loc.t('No session, please login again', 'لاگ اِن سیشن نہیں ملا، دوبارہ لاگ اِن کریں'));
    final user = await _repo.find(current);
    if (user == null) return _toast(Loc.t('User not found', 'یوزر نہیں ملا'));

    final newName = _newUsername.text.trim();
    final newPass = _newPassword.text;
    if (newName.contains(' ')) return _toast(Loc.t('Username must not contain spaces', 'یوزر نیم میں خالی جگہ نہیں ہونی چاہیے'));
    if (newPass.isNotEmpty && newPass.length < 6) return _toast(Loc.t('Password must be at least 6 characters', 'پاس ورڈ کم از کم 6 حروف کا ہو'));
    final finalName = newName.isNotEmpty ? newName : user.username;
    if (finalName != user.username && await _repo.find(finalName) != null) {
      return _toast(Loc.t('Username already exists', 'یہ یوزر نیم پہلے سے موجود ہے'));
    }
    final updated = User(
      username: finalName,
      displayName: user.displayName,
      role: user.role,
      passwordHash: newPass.isNotEmpty ? await PasswordHasher.hash(newPass) : user.passwordHash,
      active: true,
      phone: user.phone,
    );
    await _repo.rename(user, updated);
    await Session.start(updated);
    _newUsername.clear();
    _newPassword.clear();
    setState(() {});
    _toast(Loc.t('Login updated', 'لاگ اِن اپڈیٹ ہو گیا'));
  }

  Future<void> _logout() async {
    await Session.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(icon, color: AppColors.navy), const SizedBox(width: 8), Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))]),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _tf(TextEditingController c, String label, {bool obscure = false, bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, obscureText: obscure, enabled: enabled,
          decoration: InputDecoration(labelText: label, filled: true, fillColor: AppColors.fieldFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final admin = Session.isAdmin;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.navy, foregroundColor: Colors.white, title: Text(Loc.t('Settings', 'سیٹنگز'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        PremiumHeader(title: Loc.t('Settings', 'سیٹنگز'), subtitle: '${Session.displayName} • ${Session.role}'),
        if (admin)
          _card(Loc.t('Shop Information', 'دکان کی معلومات'), Icons.store, [
            _tf(_shopName, Loc.t('Shop Name', 'دکان کا نام')),
            _tf(_shopPhone, Loc.t('Phone', 'فون')),
            FilledButton(onPressed: _saveShop, child: Text(Loc.t('SAVE SETTINGS', 'محفوظ کریں'))),
          ]),
        if (admin)
          _card(Loc.t('Login Method', 'لاگ اِن کا طریقہ'), Icons.security, [
            RadioListTile<String>(
              value: 'password', groupValue: _loginMethod, onChanged: (v) => _setLoginMethod(v!),
              title: Text(Loc.t('Password Only', 'صرف پاس ورڈ')),
            ),
            RadioListTile<String>(
              value: 'fingerprint', groupValue: _loginMethod, onChanged: (v) => _setLoginMethod(v!),
              title: Text(Loc.t('Fingerprint Only', 'صرف فنگر پرنٹ')),
            ),
            RadioListTile<String>(
              value: 'both', groupValue: _loginMethod, onChanged: (v) => _setLoginMethod(v!),
              title: Text(Loc.t('Both (Password + Fingerprint)', 'دونوں (پاس ورڈ + فنگر پرنٹ)')),
            ),
            RadioListTile<String>(
              value: 'none', groupValue: _loginMethod, onChanged: (v) => _setLoginMethod(v!),
              title: Text(Loc.t('No Password', 'بغیر پاس ورڈ')),
              subtitle: Text(Loc.t('App opens directly once signed in', 'ایک بار لاگ اِن کے بعد ایپ سیدھی کھلے گی')),
            ),
          ]),
        _card(Loc.t('My Login', 'میرا لاگ اِن'), Icons.person, [
          _tf(TextEditingController(text: Session.username ?? ''), Loc.t('Current Username', 'موجودہ یوزر نیم'), enabled: false),
          _tf(_newUsername, Loc.t('New Username', 'نیا یوزر نیم')),
          _tf(_newPassword, Loc.t('New Password', 'نیا پاس ورڈ'), obscure: true),
          FilledButton(onPressed: _updateLogin, child: Text(Loc.t('UPDATE LOGIN', 'لاگ اِن اپڈیٹ کریں'))),
        ]),
        _card(Loc.t('Appearance', 'ظاہری شکل'), Icons.dark_mode, [
          ValueListenableBuilder<bool>(
            valueListenable: ThemeManager.isDark,
            builder: (_, dark, __) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: dark,
              onChanged: (v) => ThemeManager.setDarkMode(v),
              title: Text(Loc.t('Dark mode', 'ڈارک موڈ')),
            ),
          ),
        ]),
        _card(Loc.t('Language', 'زبان'), Icons.language, [
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'en', label: Text('English')), ButtonSegment(value: 'ur', label: Text('اردو'))],
            selected: {Loc.language.value},
            onSelectionChanged: (s) => Loc.setLanguage(s.first),
          ),
        ]),
        if (admin)
          _card(Loc.t('Users', 'یوزرز'), Icons.people, [
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UserManagementScreen())),
              child: Text(Loc.t('MANAGE USERS', 'یوزرز مینیج کریں')),
            ),
          ]),
        OutlinedButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout, color: AppColors.red),
          label: Text(Loc.t('Logout', 'لاگ آؤٹ'), style: const TextStyle(color: AppColors.red)),
        ),
      ]),
    );
  }
}
