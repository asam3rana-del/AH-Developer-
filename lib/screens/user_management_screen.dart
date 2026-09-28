import 'package:flutter/material.dart';

import '../db/user_repository.dart';
import '../models/misc_entities.dart';
import '../services/biometric.dart';
import '../services/session.dart';
import '../theme/app_colors.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';

/// Mirrors UserManagementActivity.kt — Admin-only, pehle admin ka password verify.
/// Lock: fingerprint pehle khud khulta hai, password hamesha fallback. TODO(Phase 10): sync queue.
class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const RoleGuard(allowed: {'admin'}, child: _UserManagementBody());
}

class _UserManagementBody extends StatefulWidget {
  const _UserManagementBody();

  @override
  State<_UserManagementBody> createState() => _UserManagementBodyState();
}

class _UserManagementBodyState extends State<_UserManagementBody> {
  static const _roles = ['admin', 'manager', 'cashier'];
  final _repo = UserRepository.instance;

  bool _unlocked = false;
  final _lockPass = TextEditingController();
  String? _lockError;

  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String _role = 'cashier';

  List<User> _users = [];

  @override
  void initState() {
    super.initState();
    _tryFingerprint();
  }

  /// Lock screen dikhte hi fingerprint prompt (Kotlin tryLockFingerprint). Fail/cancel par password field hi rehta hai.
  Future<void> _tryFingerprint({bool manual = false}) async {
    if (!await Biometric.isAvailable()) {
      if (manual) _toast(Loc.t('No fingerprint set up on this device', 'اس ڈیوائس پر فنگر پرنٹ سیٹ نہیں'));
      return;
    }
    final ok = await Biometric.authenticate(reason: Loc.t('Show your fingerprint to open Manage Users', 'یوزرز کھولنے کے لیے اپنی فنگر پرنٹ دکھائیں'));
    if (!mounted) return;
    if (ok) {
      setState(() { _unlocked = true; _lockError = null; });
      _reload();
    } else if (manual) {
      _toast(Loc.t('Fingerprint not matched, try again or enter password', 'فنگر پرنٹ میچ نہیں ہوا، دوبارہ کوشش کریں یا پاس ورڈ لکھیں'));
    }
  }

  Future<void> _reload() async {
    final u = await _repo.all();
    if (mounted) setState(() => _users = u);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  bool _isLastActiveAdmin(User u) =>
      u.role == 'admin' && u.active && _users.where((x) => x.role == 'admin' && x.active).length <= 1;

  // ---------- lock ----------
  Future<void> _verify() async {
    final typed = _lockPass.text;
    if (typed.isEmpty) return setState(() => _lockError = Loc.t('Enter password', 'پاس ورڈ لکھیں'));
    final me = await _repo.find(Session.username ?? '');
    final ok = me != null && PasswordHasher.isHashed(me.passwordHash)
        ? await PasswordHasher.verify(typed, me.passwordHash)
        : (me != null && me.passwordHash == typed);
    if (!ok) return setState(() => _lockError = Loc.t('Wrong password', 'غلط پاس ورڈ'));
    setState(() { _unlocked = true; _lockError = null; });
    _reload();
  }

  // ---------- save ----------
  Future<void> _save() async {
    final username = _username.text.trim();
    final name = _displayName.text.trim();
    final pass = _password.text;
    if (username.isEmpty || name.isEmpty || pass.isEmpty) {
      return _toast(Loc.t('All fields are required', 'تمام فیلڈز ضروری ہیں'));
    }
    if (username.contains(' ')) return _toast(Loc.t('Username must not contain spaces', 'یوزر نیم میں خالی جگہ نہیں ہونی چاہیے'));
    if (pass.length < 6) return _toast(Loc.t('Password must be at least 6 characters', 'پاس ورڈ کم از کم 6 حروف کا ہو'));

    // Safety: apna ya aakhri active admin ka role kam na ho.
    final existing = await _repo.find(username);
    if (existing != null && existing.role == 'admin' && _role != 'admin' && _isLastActiveAdmin(existing)) {
      return _toast(Loc.t('Cannot change the last active admin', 'آخری ایکٹو ایڈمن کو تبدیل نہیں کیا جا سکتا'));
    }
    await _repo.upsert(User(
      username: username,
      displayName: name,
      role: _role,
      passwordHash: await PasswordHasher.hash(pass),
      active: existing?.active ?? true,
      phone: _phone.text.trim(),
    ));
    _toast(Loc.t('User saved', 'یوزر محفوظ ہو گیا'));
    _username.clear(); _displayName.clear(); _phone.clear(); _password.clear();
    _reload();
  }

  // ---------- row actions ----------
  Future<void> _resetPassword(User u) async {
    final c = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${Loc.t('Reset Password', 'پاس ورڈ ری سیٹ')} — ${u.displayName}'),
        content: TextField(controller: c, obscureText: true, decoration: InputDecoration(hintText: Loc.t('New password', 'نیا پاس ورڈ'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Reset', 'ری سیٹ'))),
        ],
      ),
    );
    if (go != true) return;
    if (c.text.length < 8) return _toast(Loc.t('Password must be at least 8 characters', 'پاس ورڈ کم از کم 8 حروف کا ہو'));
    await _repo.upsert(User(
      username: u.username, displayName: u.displayName, role: u.role,
      passwordHash: await PasswordHasher.hash(c.text), active: u.active, phone: u.phone,
    ));
    // Hash device-local rehta hai; sirf audit mein likhte hain.
    await _repo.insertAudit(Session.username ?? 'admin', 'password_reset', u.username, 'Password reset locally by admin');
    _toast(Loc.t('Password reset (on this device)', 'پاس ورڈ ری سیٹ ہو گیا (اس ڈیوائس پر)'));
  }

  Future<bool> _confirm(String title, String msg, String okLabel) async =>
      (await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(msg),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(okLabel)),
          ],
        ),
      )) == true;

  Future<void> _toggleActive(User u) async {
    if (u.username == Session.username || _isLastActiveAdmin(u)) {
      return _toast(Loc.t('You cannot deactivate yourself or the last active admin', 'آپ خود کو یا آخری ایکٹو ایڈمن کو غیر فعال نہیں کر سکتے'));
    }
    final turningOff = u.active;
    final ok = await _confirm(
      '${turningOff ? Loc.t('Deactivate', 'غیر فعال کریں') : Loc.t('Activate', 'فعال کریں')} ${u.displayName}?',
      u.username,
      turningOff ? Loc.t('Deactivate', 'غیر فعال کریں') : Loc.t('Activate', 'فعال کریں'),
    );
    if (!ok) return;
    await _repo.upsert(User(
      username: u.username, displayName: u.displayName, role: u.role,
      passwordHash: u.passwordHash, active: !u.active, phone: u.phone,
    ));
    _toast(!u.active ? Loc.t('User activated', 'یوزر فعال ہو گیا') : Loc.t('User deactivated', 'یوزر غیر فعال ہو گیا'));
    _reload();
  }

  Future<void> _delete(User u) async {
    if (u.username == Session.username || _isLastActiveAdmin(u)) {
      return _toast(Loc.t('You cannot delete yourself or the last active admin', 'آپ خود کو یا آخری ایکٹو ایڈمن کو حذف نہیں کر سکتے'));
    }
    final ok = await _confirm(Loc.t('Delete User?', 'یوزر حذف کریں؟'), '${u.displayName} (${u.username})', Loc.t('Delete', 'حذف'));
    if (!ok) return;
    await _repo.delete(u.username);
    _toast(Loc.t('User deleted', 'یوزر حذف ہو گیا'));
    _reload();
  }

  // ---------- UI ----------
  Color _roleColor(String r) => r == 'admin' ? AppColors.red : r == 'manager' ? AppColors.blue : AppColors.teal;

  Widget _field(TextEditingController c, String label, {bool obscure = false, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: type,
          decoration: InputDecoration(
            labelText: label, filled: true, fillColor: AppColors.fieldFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return Scaffold(
        appBar: AppBar(backgroundColor: AppColors.navy, foregroundColor: Colors.white),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, size: 52, color: AppColors.navy),
                const SizedBox(height: 10),
                Text(Loc.t('Manage Users Locked', 'یوزرز لاک ہیں'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text(Loc.t('Verify to continue', 'جاری رکھنے کے لیے تصدیق کریں'), style: const TextStyle(color: AppColors.textMuted)),
                const SizedBox(height: 18),
                _field(_lockPass, Loc.t('Enter your password', 'اپنا پاس ورڈ لکھیں'), obscure: true),
                if (_lockError != null) Text(_lockError!, style: const TextStyle(color: AppColors.red)),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: FilledButton(onPressed: _verify, child: Text(Loc.t('Unlock', 'کھولیں')))),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: OutlinedButton.icon(
                  onPressed: () => _tryFingerprint(manual: true),
                  icon: const Icon(Icons.fingerprint),
                  label: Text(Loc.t('VERIFY WITH FINGERPRINT', 'فنگر پرنٹ سے تصدیق')),
                )),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.navy, foregroundColor: Colors.white, title: Text(Loc.t('Manage Users', 'یوزرز'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        PremiumHeader(
          title: Loc.t('Manage Users', 'یوزرز'),
          subtitle: Loc.t('Add, update, or remove staff logins', 'اسٹاف لاگ اِن شامل، اپڈیٹ یا حذف کریں'),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Add / Update User', 'یوزر شامل / اپڈیٹ'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              _field(_username, Loc.t('Username', 'یوزر نیم')),
              _field(_displayName, Loc.t('Display Name', 'نام')),
              _field(_phone, Loc.t('Phone (+92XXXXXXXXXX) — for OTP login', 'فون (+92XXXXXXXXXX)'), type: TextInputType.phone),
              _field(_password, Loc.t('Password', 'پاس ورڈ'), obscure: true),
              DropdownButtonFormField<String>(
                value: _role,
                decoration: InputDecoration(labelText: Loc.t('Role', 'کردار')),
                items: [for (final r in _roles) DropdownMenuItem(value: r, child: Text(r[0].toUpperCase() + r.substring(1)))],
                onChanged: (v) => setState(() => _role = v ?? _role),
              ),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: Text(Loc.t('Save User', 'محفوظ کریں')))),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Text(Loc.t('All Users', 'تمام یوزرز'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (_users.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(Loc.t('No users', 'کوئی یوزر نہیں'))),
        for (final u in _users)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${u.displayName}  (${u.username})', style: const TextStyle(fontWeight: FontWeight.bold)),
                if (u.phone.isNotEmpty) Text(u.phone, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  Chip(label: Text(u.role[0].toUpperCase() + u.role.substring(1)), labelStyle: TextStyle(color: _roleColor(u.role), fontSize: 11)),
                  Chip(label: Text(u.active ? Loc.t('Active', 'فعال') : Loc.t('Inactive', 'غیر فعال')),
                      labelStyle: TextStyle(color: u.active ? AppColors.teal : AppColors.textMuted, fontSize: 11)),
                ]),
                Wrap(spacing: 8, children: [
                  TextButton.icon(onPressed: () => _resetPassword(u), icon: const Icon(Icons.key, size: 16), label: Text(Loc.t('Reset PW', 'پاس ورڈ ری سیٹ'))),
                  TextButton(onPressed: () => _toggleActive(u), child: Text(u.active ? Loc.t('Deactivate', 'غیر فعال') : Loc.t('Activate', 'فعال'))),
                  TextButton(onPressed: () => _delete(u), child: Text(Loc.t('Delete', 'حذف'), style: const TextStyle(color: AppColors.red))),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}
