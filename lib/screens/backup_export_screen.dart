import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../backup/backup_export.dart';
import '../backup/backup_helper.dart';
import '../backup/backup_password_store.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';
import 'login_screen.dart';

/// Mirrors BackupExportActivity.kt (+ BackupHelper ki Backup Now / Restore / Share buttons).
///
/// * Reports export (CSV + PDF, poora ya date range): admin + manager.
/// * Encrypted database backup / password / restore: SIRF admin (backup mein cost, users aur
///   saara data hota hai; restore poora live data badal deta hai).
///
/// Farq (Kotlin se): date range ek `showDateRangePicker` se (do alag dialog nahi); Print =
/// `printing` plugin (system print dialog / Save as PDF).
class BackupExportScreen extends StatelessWidget {
  const BackupExportScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const RoleGuard(allowed: {'admin', 'manager'}, child: _BackupBody());
}

class _BackupBody extends StatefulWidget {
  const _BackupBody();

  @override
  State<_BackupBody> createState() => _BackupBodyState();
}

class _BackupBodyState extends State<_BackupBody> {
  AppPalette get _p => ThemeManager.palette;

  bool _busy = false;
  String _status = '';
  ExportFiles? _files;

  List<File> _backups = [];
  bool _loadingBackups = false;

  bool get _isAdmin => Session.isAdmin;

  @override
  void initState() {
    super.initState();
    if (_isAdmin) _loadBackups();
  }

  // ---------------- helpers ----------------

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadBackups() async {
    setState(() => _loadingBackups = true);
    try {
      final list = await BackupHelper.listBackups();
      if (mounted) setState(() => _backups = list);
    } catch (_) {
      if (mounted) setState(() => _backups = []);
    } finally {
      if (mounted) setState(() => _loadingBackups = false);
    }
  }

  // ---------------- reports export ----------------

  Future<void> _runExport(int start, int end, String label) async {
    setState(() {
      _busy = true;
      _files = null;
      _status = Loc.t('Generating backup…', 'بیک اپ تیار ہو رہا ہے…');
    });
    try {
      final files = await BackupExport.run(start, end, label);
      if (!mounted) return;
      setState(() {
        _files = files;
        _status = '${Loc.t('Backup ready', 'بیک اپ تیار ہے')}: ${p.basename(files.pdf.path)}';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '');
      _toast('Backup failed: ${e.toString().isEmpty ? 'unknown error' : e}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fullExport() => _runExport(0, kAllTimeEnd, 'Full');

  Future<void> _rangeExport() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month, now.day)),
      helpText: Loc.t('Select date range', 'دورانیہ منتخب کریں'),
    );
    if (picked == null) return;
    final s = DateTime(picked.start.year, picked.start.month, picked.start.day);
    final e = DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59, 999);
    await _runExport(s.millisecondsSinceEpoch, e.millisecondsSinceEpoch, 'Range');
  }

  Future<void> _open(File f) async {
    final r = await OpenFilex.open(f.path);
    if (r.type != ResultType.done) {
      _toast(Loc.t('No app found to open this file', 'اس فائل کو کھولنے کے لیے کوئی ایپ نہیں ملی'));
    }
  }

  Future<void> _printPdf(File f) async {
    try {
      await Printing.layoutPdf(
        name: p.basenameWithoutExtension(f.path),
        onLayout: (_) => f.readAsBytes(),
      );
    } catch (e) {
      _toast('Print: $e');
    }
  }

  Future<void> _shareBoth(ExportFiles f) async {
    try {
      await Share.shareXFiles([XFile(f.pdf.path), XFile(f.csv.path)],
          subject: Loc.t('Share Backup', 'بیک اپ شیئر کریں'));
    } catch (e) {
      _toast('Share: $e');
    }
  }

  // ---------------- encrypted DB backup ----------------

  Future<void> _backupNow() async {
    if (!_isAdmin) return;
    setState(() => _busy = true);
    final f = await BackupHelper.backupNow();
    if (!mounted) return;
    setState(() => _busy = false);
    if (f == null) {
      _toast('${Loc.t('Backup failed', 'بیک اپ ناکام')}: ${BackupHelper.lastError ?? Loc.t('database not found', 'ڈیٹا بیس نہیں ملا')}');
      return;
    }
    _toast('${Loc.t('Backup saved', 'بیک اپ محفوظ')}: ${p.basename(f.path)}');
    await _loadBackups();
  }

  Future<void> _showPassword() async {
    if (!_isAdmin) return;
    final current = await BackupPasswordStore.getOrCreate();
    if (!mounted) return;
    final ctrl = TextEditingController();
    var reveal = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(Loc.t('Backup password', 'بیک اپ پاسورڈ')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              Loc.t(
                'Write this down and keep it safe. Without it a backup cannot be restored on another phone.',
                'اسے لکھ کر محفوظ رکھیں۔ اس کے بغیر بیک اپ کسی دوسرے فون پر بحال نہیں ہو سکتا۔',
              ),
              style: TextStyle(fontSize: 12.5, color: _p.textMuted),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SelectableText(
                  reveal ? current : '•' * current.length,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setD(() => reveal = !reveal),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              decoration: InputDecoration(
                labelText: Loc.t('New password (min 8 characters)', 'نیا پاسورڈ (کم از کم 8 حروف)'),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں'))),
            TextButton(
              onPressed: () async {
                final v = ctrl.text;
                if (v.length < BackupPasswordStore.minLength) {
                  _toast(Loc.t('Backup password must be at least 8 characters.', 'بیک اپ پاسورڈ کم از کم 8 حروف کا ہو۔'));
                  return;
                }
                await BackupPasswordStore.setPassword(v);
                if (ctx.mounted) Navigator.pop(ctx);
                _toast(Loc.t('Password changed. New backups use it.', 'پاسورڈ بدل گیا۔ نئے بیک اپ اسی سے بنیں گے۔'));
              },
              child: Text(Loc.t('Change', 'بدلیں')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
  }

  Future<void> _restoreFromFile() async {
    if (!_isAdmin) return;
    final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
    final path = res?.files.single.path;
    if (path == null) return;
    await _startRestore(File(path), fromPicker: true);
  }

  Future<void> _startRestore(File file, {bool fromPicker = false}) async {
    if (!_isAdmin) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Restore backup?', 'بیک اپ بحال کریں؟')),
        content: Text(Loc.t(
          'This REPLACES all current data on this device with the backup (${p.basename(file.path)}). '
              'A safety backup of the current data is made first.',
          'یہ اس ڈیوائس کا موجودہ سارا ڈیٹا بیک اپ (${p.basename(file.path)}) سے بدل دے گا۔ پہلے موجودہ ڈیٹا کا حفاظتی بیک اپ بنے گا۔',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _p.red),
            child: Text(Loc.t('Restore', 'بحال کریں')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    String? pass;
    if (await BackupHelper.needsPassword(file)) {
      if (!mounted) return;
      pass = await _askPassword();
      if (pass == null || !mounted) return;
    }

    setState(() => _busy = true);
    final done = fromPicker
        ? await BackupHelper.restoreFromPath(file.path, pass: pass)
        : await BackupHelper.restore(file, pass: pass);
    if (!mounted) return;
    setState(() => _busy = false);

    if (!done) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Restore failed', 'بحالی ناکام')),
          content: Text('${BackupHelper.lastError ?? '-'}\n\n${Loc.t('Your current data was not changed.', 'آپ کا موجودہ ڈیٹا نہیں بدلا۔')}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }

    // Restore ke baad users/session purane ho sakte hain — login par wapas (Kotlin: app restart).
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Restore complete', 'بحالی مکمل')),
        content: Text(Loc.t('Please sign in again.', 'براہِ کرم دوبارہ لاگ اِن کریں۔')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    await Session.clear();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<String?> _askPassword() async {
    final ctrl = TextEditingController();
    final stored = await BackupPasswordStore.getOrCreate();
    if (!mounted) return null;
    var reveal = false;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(Loc.t('Backup password', 'بیک اپ پاسورڈ')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              obscureText: !reveal,
              autofocus: true,
              decoration: InputDecoration(
                labelText: Loc.t('Password of this backup', 'اس بیک اپ کا پاسورڈ'),
                suffixIcon: IconButton(
                  icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setD(() => reveal = !reveal),
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => setD(() => ctrl.text = stored),
                child: Text(Loc.t("Use this device's password", 'اس ڈیوائس کا پاسورڈ استعمال کریں')),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(Loc.t('Continue', 'جاری رکھیں')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (r == null || r.isEmpty) return null;
    return r;
  }

  // ---------------- UI ----------------

  Widget _bigButton(String label, Color color, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : onTap,
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
        ),
      );

  Widget _resultButton(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: _p.textDark,
              side: BorderSide(color: _p.border),
              backgroundColor: _p.cardWhite,
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  Widget _sectionTitle(String t, {String? sub}) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(sub, style: TextStyle(fontSize: 12.5, color: _p.textMuted)),
          ],
        ]),
      );

  String _fmtWhen(File f) {
    try {
      return DateFormat('dd MMM yyyy, hh:mm a').format(f.lastModifiedSync());
    } catch (_) {
      return '';
    }
  }

  Widget _backupRow(File f) {
    final legacy = p.extension(f.path).toLowerCase() == '.db';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _p.border),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.basename(f.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _p.textDark)),
            const SizedBox(height: 2),
            Text(
              '${_fmtWhen(f)}${legacy ? '  •  ${Loc.t('old, not encrypted', 'پرانا، بغیر انکرپشن')}' : ''}',
              style: TextStyle(fontSize: 11.5, color: _p.textMuted),
            ),
          ]),
        ),
        IconButton(
          tooltip: Loc.t('Share', 'شیئر'),
          icon: const Icon(Icons.share_outlined),
          onPressed: _busy
              ? null
              : () async {
                  if (!await BackupHelper.shareBackup(f)) _toast(Loc.t('Could not share backup.', 'بیک اپ شیئر نہیں ہو سکا۔'));
                },
        ),
        IconButton(
          tooltip: Loc.t('Restore', 'بحال کریں'),
          icon: Icon(Icons.restore, color: _p.red),
          onPressed: _busy ? null : () => _startRestore(f),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(
        backgroundColor: _p.navy,
        foregroundColor: Colors.white,
        title: Text(Loc.t('Backup & Reports', 'بیک اپ اور رپورٹس')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _sectionTitle(
              Loc.t('Reports export (CSV + PDF)', 'رپورٹس ایکسپورٹ (CSV + PDF)'),
              sub: Loc.t(
                'Exports Sales, Purchases, Day Book, Customer & Supplier ledgers, Stock, Expenses and Cash into one CSV + one printable PDF.',
                'سیل، خریداری، ڈے بک، کسٹمر اور سپلائر لجر، اسٹاک، اخراجات اور کیش کو ایک CSV + ایک پرنٹ ایبل PDF میں جمع کرتا ہے۔',
              ),
            ),
            _bigButton(Loc.t('📦 Full Backup (All Data)', '📦 مکمل بیک اپ (تمام ڈیٹا)'), _p.flatBlueFg, _fullExport),
            const SizedBox(height: 12),
            _bigButton(Loc.t('📅 Custom Date Range Backup', '📅 درج دورانیہ بیک اپ'), _p.teal, _rangeExport),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(children: [
                  if (_busy) const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
                  Expanded(child: Text(_status, style: TextStyle(fontSize: 12.5, color: _p.textMuted))),
                ]),
              ),
            if (files != null) ...[
              _resultButton(Loc.t('📄 Open PDF', '📄 PDF کھولیں'), () => _open(files.pdf)),
              _resultButton(Loc.t('🖨️ Print PDF', '🖨️ PDF پرنٹ کریں'), () => _printPdf(files.pdf)),
              _resultButton(Loc.t('📊 Open CSV (Excel)', '📊 CSV کھولیں (Excel)'), () => _open(files.csv)),
              _resultButton(Loc.t('🔗 Share Both', '🔗 دونوں شیئر کریں'), () => _shareBoth(files)),
            ],
            if (_isAdmin) ...[
              _sectionTitle(
                Loc.t('Database backup (encrypted)', 'ڈیٹا بیس بیک اپ (انکرپٹڈ)'),
                sub: Loc.t(
                  'Full copy of all data, protected with a password. Restore it here on this or a new phone.',
                  'تمام ڈیٹا کی مکمل کاپی، پاسورڈ سے محفوظ۔ اسی یا نئے فون پر یہیں سے بحال کریں۔',
                ),
              ),
              _bigButton(Loc.t('💾 Backup Now', '💾 ابھی بیک اپ بنائیں'), _p.navy, _backupNow),
              const SizedBox(height: 12),
              _bigButton(Loc.t('🔑 Backup Password', '🔑 بیک اپ پاسورڈ'), _p.flatPurpleFg, _showPassword),
              const SizedBox(height: 12),
              _bigButton(Loc.t('📂 Restore from file…', '📂 فائل سے بحال کریں…'), _p.red, _restoreFromFile),
              _sectionTitle(Loc.t('Saved backups', 'محفوظ بیک اپ')),
              if (_loadingBackups)
                const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
              else if (_backups.isEmpty)
                Text(Loc.t('No backups yet.', 'ابھی کوئی بیک اپ نہیں۔'), style: TextStyle(color: _p.textMuted))
              else
                ..._backups.map(_backupRow),
            ],
          ],
        ),
      ),
    );
  }
}
