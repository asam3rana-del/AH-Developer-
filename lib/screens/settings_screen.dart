import 'package:flutter/material.dart';

import '../db/user_repository.dart';
import '../models/misc_entities.dart';
import '../services/app_lock.dart';
import '../services/biometric.dart';
import '../services/printer_service.dart';
import '../services/usb_printer.dart';
import '../utils/escpos.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/password_hasher.dart';
import '../widgets/menu_row.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';
import '../widgets/sync_section.dart';
import 'backup_export_screen.dart';
import 'cash_screen.dart';
import 'expense_screen.dart';
import 'items_screen.dart';
import 'login_screen.dart';
import 'party_dashboard_screen.dart';
import 'purchase_screen.dart';
import 'reports_screen.dart';
import 'sale_screen.dart';
import 'shell_ledger_screen.dart';
import 'user_management_screen.dart';

/// Receipt footer / address / currency / tax fields Kotlin mein user ke kehne par hata di gayi thin — yahan bhi nahi
/// (stored receipt_footer value print par ab bhi parha jata hai, jaisa Kotlin mein).
/// Mirrors SettingsActivity.kt (pehla hissa): Shop Info, Login method, Update Login,
/// Language, Manage Users, Logout.
/// Login method: password / fingerprint / both / none. Dark mode switch.
/// Printer (Phase 12) done — Bluetooth 58/80mm. Cloud Sync (Phase 10): `SyncSection` (Sync Now / Setup / History).
/// OTP login (Phase 10): login method 'otp'. Backup row: BackupExportScreen (admin/manager).
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
  String _headerShop = 'My Shop'; // Kotlin loadHeaderShopName: saved shop_name, warna "My Shop"
  String _printerName = '';
  int _dots = EscPos.defaultDotsWidth;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _shopName.text = await _repo.getSetting('shop_name') ?? '';
    _shopPhone.text = await _repo.getSetting('shop_phone') ?? '';
    if (_shopName.text.trim().isNotEmpty) _headerShop = _shopName.text.trim();
    final pr = await PrinterService.instance.selected();
    _printerName = pr?.name ?? '';
    _dots = await PrinterService.instance.dotsWidth();
    final m = await _repo.getSetting('login_method') ?? 'password';
    if (mounted) setState(() => _loginMethod = const ['none', 'fingerprint', 'both', 'otp'].contains(m) ? m : 'password');
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveShop() async {
    await _repo.setSetting('shop_name', _shopName.text.trim());
    await _repo.setSetting('shop_phone', _shopPhone.text.trim());
    if (_shopName.text.trim().isNotEmpty && mounted) setState(() => _headerShop = _shopName.text.trim());
    _toast(Loc.t('Settings saved', 'سیٹنگز محفوظ ہو گئیں'));
  }


  // ------------------------------------------------------------------ Printer

  Future<void> _selectPrinter() async {
    final svc = PrinterService.instance;
    if (PrinterService.isDesktop) return _selectDesktopPrinter();
    if (!PrinterService.supported) return _toast(Loc.t('Printing needs Android, iOS or Windows', 'پرنٹنگ کے لیے اینڈرائیڈ، آئی او ایس یا ونڈوز چاہیے'));
    // Bluetooth (paired) + Android par jude hue USB printers — ek hi list.
    final bluetooth = <PrinterInfo>[];
    final btGranted = await svc.hasPermission();
    if (btGranted) bluetooth.addAll(await svc.pairedPrinters());
    final usb = await UsbPrinter.list();
    if (!mounted) return;
    if (bluetooth.isEmpty && usb.isEmpty) {
      if (!btGranted && !UsbPrinter.supported) {
        return _toast(Loc.t('Bluetooth permission dein, phir dobara SELECT PRINTER dabayein', 'بلوٹوتھ کی اجازت دیں، پھر دوبارہ دبائیں'));
      }
      return _toast(Loc.t(
          'Koi printer nahi mila. Bluetooth printer ko phone ki Bluetooth Settings se pair karein, ya USB printer cable se jodein.',
          'کوئی پرنٹر نہیں ملا۔ بلوٹوتھ پرنٹر جوڑیں یا یو ایس بی کیبل لگائیں۔'));
    }
    final picked = await showDialog<PrinterInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Select Printer', 'پرنٹر منتخب کریں')),
        children: [
          for (final d in bluetooth) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text('🔵  ${d.name}')),
          for (final u in usb)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, PrinterInfo('USB ${u.name}', u.address)),
              child: Text('🔌  USB: ${u.name}'),
            ),
        ],
      ),
    );
    if (picked == null) return;
    // USB: ijazat abhi le lein taake pehli print par dialog na aaye.
    final id = UsbPrinter.parse(picked.mac);
    if (id != null && !await UsbPrinter.requestPermission(id.vid, id.pid)) {
      return _toast(Loc.t('USB ki ijazat nahi mili — Allow dabayein', 'یو ایس بی کی اجازت نہیں ملی'));
    }
    await svc.savePrinter(picked.name, picked.mac);
    if (mounted) setState(() => _printerName = picked.name);
    _toast(Loc.t('Printer saved: ${picked.name}', 'پرنٹر محفوظ: ${picked.name}'));
  }

  /// Windows: installed printers ki list + "Network printer (IP)".
  Future<void> _selectDesktopPrinter() async {
    final svc = PrinterService.instance;
    List<PrinterInfo> installed = [];
    try {
      installed = await svc.systemPrinters();
    } catch (_) {}
    if (!mounted) return;
    const networkMarker = PrinterInfo('__network__', '');
    final picked = await showDialog<PrinterInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Select Printer', 'پرنٹر منتخب کریں')),
        children: [
          for (final d in installed)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text('🖨  ${d.name}')),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, networkMarker),
            child: Text(Loc.t('🌐  Network printer (IP address)…', '🌐  نیٹ ورک پرنٹر (IP)…')),
          ),
        ],
      ),
    );
    if (picked == null) return;
    if (picked.name != networkMarker.name) {
      await svc.savePrinter(picked.name, picked.mac);
      if (mounted) setState(() => _printerName = picked.name);
      return _toast(Loc.t('Printer saved: ${picked.name}', 'پرنٹر محفوظ: ${picked.name}'));
    }
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Network printer', 'نیٹ ورک پرنٹر')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '192.168.1.50  (ya 192.168.1.50:9100)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(Loc.t('Save', 'محفوظ'))),
        ],
      ),
    );
    ctrl.dispose();
    if (input == null) return;
    final addr = PrinterService.tcpAddress(input);
    if (addr == null) {
      return _toast(Loc.t('IP address theek nahi (misaal: 192.168.1.50 ya 192.168.1.50:9100)', 'IP ایڈریس درست نہیں'));
    }
    final label = 'Network ${addr.substring(PrinterService.tcpPrefix.length)}';
    await svc.savePrinter(label, addr);
    if (mounted) setState(() => _printerName = label);
    _toast(Loc.t('Printer saved: $label', 'پرنٹر محفوظ: $label'));
  }

  Future<void> _testPrint() async {
    if (_testing) return;
    setState(() => _testing = true);
    final err = await PrinterService.instance.testPrint(shopName: _shopName.text.trim().isEmpty ? 'My Shop' : _shopName.text.trim());
    if (!mounted) return;
    setState(() => _testing = false);
    _toast(err ?? Loc.t('Test print sent', 'ٹیسٹ پرنٹ بھیج دیا'));
  }

  Future<void> _testPrintText() async {
    if (_testing) return;
    setState(() => _testing = true);
    final err = await PrinterService.instance.testPrintText(shopName: _shopName.text.trim());
    if (!mounted) return;
    setState(() => _testing = false);
    _toast(err ?? Loc.t('Plain text test sent', 'سادہ ٹیکسٹ ٹیسٹ بھیج دیا'));
  }

  Future<void> _pickWidth() async {
    final options = [384, 448, 512, 576];
    final labels = {
      384: '384 dots — standard 58mm (recommended)',
      448: '448 dots',
      512: '512 dots',
      576: '576 dots — 80mm printer',
    };
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Print Width', 'پرنٹ چوڑائی')),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o),
              child: Text('${o == _dots ? '● ' : '○ '}${labels[o]}'),
            ),
        ],
      ),
    );
    if (v == null) return;
    await PrinterService.instance.saveDotsWidth(v);
    if (mounted) setState(() => _dots = v);
    _toast(Loc.t('Print width $v dots saved. TEST PRINT karke check karein.', 'چوڑائی $v محفوظ۔ ٹیسٹ پرنٹ کر کے دیکھیں۔'));
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
            Row(children: [Icon(icon, color: ThemeManager.palette.navyInk), const SizedBox(width: 8), Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))]),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _tf(TextEditingController c, String label, {bool obscure = false, bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c, obscureText: obscure, enabled: enabled,
          decoration: InputDecoration(labelText: label, filled: true, fillColor: ThemeManager.palette.fieldFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        ),
      );

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// Kotlin SettingsActivity ke upar wali link rows (Parties, Items, Reports, Sale, Purchase, Expense,
  /// Cash & Bank, Shell Ledger) — usi tarteeb mein; role gates Dashboard ke barabar.
  List<Widget> _linkRows() {
    final p = ThemeManager.palette;
    Widget row(IconData icon, String en, String ur, Widget screen, {Color? color}) => MenuRow(
          icon: icon,
          label: Loc.t(en, ur),
          iconColor: color ?? p.teal,
          chevronIcon: Icons.chevron_right,
          showChevron: true,
          onTap: () => _open(screen),
        );
    return [
      row(Icons.people_outline, 'Parties', 'پارٹیز', const PartyDashboardScreen()),
      row(Icons.list_alt, 'Items', 'آئٹمز', const ItemsScreen()),
      if (Session.isAdminOrManager) row(Icons.trending_up, 'Reports', 'رپورٹس', const ReportsScreen()),
      row(Icons.receipt_outlined, 'Sale', 'سیل', const SaleScreen()),
      if (Session.isAdmin)
        row(Icons.shopping_cart_outlined, 'Purchase', 'خریداری',
            const RoleGuard(allowed: {'admin'}, child: PurchaseScreen())),
      row(Icons.business_center_outlined, 'Expense', 'اخراجات', const ExpenseScreen(), color: p.navyInk),
      row(Icons.account_balance_outlined, 'Cash & Bank', 'کیش اور بینک', const CashScreen(), color: p.navyInk),
      row(Icons.inventory_2_outlined, 'Shell Ledger', 'شیل لیجر', const ShellLedgerScreen(), color: p.navyInk),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final admin = Session.isAdmin;
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      appBar: AppBar(backgroundColor: ThemeManager.palette.navy, foregroundColor: Colors.white, title: Text(Loc.t('Settings', 'سیٹنگز'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        PremiumHeader(title: _headerShop, subtitle: Loc.t('POINT OF SALE', 'پوائنٹ آف سیل')),
        ..._linkRows(),
        const SizedBox(height: 6),
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
            RadioListTile<String>(
              value: 'otp', groupValue: _loginMethod, onChanged: (v) => _setLoginMethod(v!),
              title: Text(Loc.t('OTP (Phone Number)', 'OTP (فون نمبر)')),
              subtitle: Text(Loc.t('Needs Cloud Sync Setup; staff phone in Manage Users', 'Cloud Sync Setup ضروری؛ اسٹاف کا فون Manage Users میں')),
            ),
          ]),
        _card(Loc.t('My Login', 'میرا لاگ اِن'), Icons.person, [
          _tf(TextEditingController(text: Session.username ?? ''), Loc.t('Current Username', 'موجودہ یوزر نیم'), enabled: false),
          _tf(_newUsername, Loc.t('New Username', 'نیا یوزر نیم')),
          _tf(_newPassword, Loc.t('New Password', 'نیا پاس ورڈ'), obscure: true),
          FilledButton(onPressed: _updateLogin, child: Text(Loc.t('UPDATE LOGIN', 'لاگ اِن اپڈیٹ کریں'))),
        ]),
        _card(
          PrinterService.isDesktop
              ? Loc.t('Printer Setup (Windows / Network)', 'پرنٹر سیٹ اپ (ونڈوز / نیٹ ورک)')
              : Loc.t('Printer Setup (58mm Bluetooth)', 'پرنٹر سیٹ اپ (58mm بلوٹوتھ)'),
          Icons.print,
          [
          Row(children: [
            Icon(Icons.circle, size: 12, color: _printerName.isEmpty ? ThemeManager.palette.red : ThemeManager.palette.teal),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_printerName.isEmpty
                  ? Loc.t('No printer selected', 'کوئی پرنٹر منتخب نہیں')
                  : Loc.t('Selected: $_printerName', 'منتخب: $_printerName')),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _selectPrinter, child: Text(Loc.t('SELECT PRINTER', 'پرنٹر منتخب کریں')))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(onPressed: _testing ? null : _testPrint, child: Text(Loc.t('TEST PRINT', 'ٹیسٹ پرنٹ')))),
          ]),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _pickWidth,
            child: Text(Loc.t('PRINT WIDTH: $_dots (garbled print? try 384)', 'پرنٹ چوڑائی: $_dots')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _testing ? null : _testPrintText,
            child: Text(Loc.t('PLAIN TEXT TEST (English only)', 'سادہ ٹیکسٹ ٹیسٹ (صرف انگریزی)')),
          ),
        ]),
        // Kotlin Settings mein Backup/Export row (BackupExportScreen ka apna RoleGuard admin/manager).
        if (Session.isAdminOrManager)
          _card(Loc.t('Backup & Export', 'بیک اپ اور ایکسپورٹ'), Icons.save_outlined, [
            Text(Loc.t('Encrypted backup, restore, CSV / PDF export', 'انکرپٹڈ بیک اپ، ریسٹور، CSV / PDF ایکسپورٹ')),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupExportScreen())),
              child: Text(Loc.t('OPEN BACKUP & EXPORT', 'بیک اپ اور ایکسپورٹ کھولیں')),
            ),
          ]),
        const SyncSection(),
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
          icon: Icon(Icons.logout, color: ThemeManager.palette.red),
          label: Text(Loc.t('Logout', 'لاگ آؤٹ'), style: TextStyle(color: ThemeManager.palette.red)),
        ),
      ]),
    );
  }
}
