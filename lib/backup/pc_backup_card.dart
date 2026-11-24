import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../screens/backup_export_screen.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'backup_helper.dart';
import 'pc_backup_mirror.dart';

/// Settings (sirf Windows, admin): "Backup ki copy — dusri drive". Folder, aakhri copy, badlo / abhi copy / kholo.
class PcBackupCard extends StatefulWidget {
  const PcBackupCard({super.key});

  @override
  State<PcBackupCard> createState() => _PcBackupCardState();
}

class _PcBackupCardState extends State<PcBackupCard> {
  String? _folder;
  bool _off = false;
  DateTime? _last;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    PcBackupMirror.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    PcBackupMirror.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final off = await PcBackupMirror.isOff();
    final folder = await PcBackupMirror.folder();
    final last = await PcBackupMirror.lastCopyAt();
    final err = await PcBackupMirror.lastError();
    if (!mounted) return;
    setState(() {
      _off = off;
      _folder = folder;
      _last = last;
      _error = err;
    });
  }

  void _toast(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  Future<void> _choose() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: Loc.t('Choose a folder on another drive (D:, E: …)', 'دوسری ڈرائیو (D:, E: …) پر فولڈر چنیں'),
    );
    if (path == null || path.isEmpty) return;
    await PcBackupMirror.setFolder(path);
    if (PcBackupMirror.isOnSystemDrive(path)) {
      _toast(Loc.t('This folder is on the Windows drive (C:) — choose another drive for safety.',
          'یہ فولڈر ونڈوز والی ڈرائیو (C:) پر ہے — حفاظت کے لیے دوسری ڈرائیو چنیں۔'));
    }
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    final f = await BackupHelper.backupNow();
    if (!mounted) return;
    setState(() => _busy = false);
    if (f == null) {
      _toast('${Loc.t('Backup failed', 'بیک اپ نہیں بنا')}: ${BackupHelper.lastError ?? ''}');
      return;
    }
    await _load();
    _toast(_error == null && _folder != null
        ? Loc.t('Backup saved and copied to $_folder', 'بیک اپ بن گیا اور $_folder میں کاپی ہو گیا')
        : Loc.t('Backup saved (copy to other drive failed)', 'بیک اپ بن گیا (دوسری ڈرائیو پر کاپی نہیں ہوا)'));
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final folder = _folder;
    final risky = folder == null || PcBackupMirror.isOnSystemDrive(folder);
    final Color fg = _off || risky || _error != null ? p.red : p.flatTealFg;
    final Color bg = _off || risky || _error != null ? p.red.withValues(alpha: 0.10) : p.flatTealBg;
    final String status;
    if (_off) {
      status = Loc.t('Copy to other drive is OFF', 'دوسری ڈرائیو پر کاپی بند ہے');
    } else if (folder == null) {
      status = Loc.t('No other drive found — choose a folder (D:, E:, or a USB)', 'کوئی دوسری ڈرائیو نہیں ملی — فولڈر چنیں (D:، E: یا USB)');
    } else if (PcBackupMirror.isOnSystemDrive(folder)) {
      status = Loc.t('Folder is on the Windows drive — choose another drive', 'فولڈر ونڈوز والی ڈرائیو پر ہے — دوسری ڈرائیو چنیں');
    } else {
      status = Loc.t('Every backup is also copied here', 'ہر بیک اپ یہاں بھی کاپی ہوتا ہے');
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.save_as_outlined, color: p.navyInk),
          const SizedBox(width: 10),
          Expanded(
            child: Text(Loc.t('Backup copy — other drive (PC)', 'بیک اپ کی کاپی — دوسری ڈرائیو (PC)'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: p.textDark)),
          ),
          Switch(value: !_off, onChanged: (v) => PcBackupMirror.setOff(!v)),
        ]),
        const SizedBox(height: 6),
        Text(
          Loc.t('If Windows gets corrupted or is reinstalled, drive C: is wiped. A copy on D: / E: stays safe.',
              'ونڈوز خراب ہو یا دوبارہ انسٹال ہو تو C: ڈرائیو صاف ہو جاتی ہے۔ D: / E: پر کاپی محفوظ رہتی ہے۔'),
          style: TextStyle(fontSize: 12.5, color: p.textMuted),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(status, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
            if (folder != null && !_off) ...[
              const SizedBox(height: 4),
              SelectableText(folder, style: TextStyle(color: p.textDark, fontFamily: 'monospace', fontSize: 13)),
            ],
            if (_last != null && !_off) ...[
              const SizedBox(height: 4),
              Text('${Loc.t('Last copy', 'آخری کاپی')}: ${DateFormat('dd/MM/yyyy hh:mm a').format(_last!)}',
                  style: TextStyle(color: p.textMuted, fontSize: 12.5)),
            ],
            if (_error != null && !_off) ...[
              const SizedBox(height: 4),
              Text('${Loc.t('Last copy failed', 'آخری کاپی نہیں ہوئی')}: $_error',
                  style: TextStyle(color: p.red, fontSize: 12.5)),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          OutlinedButton.icon(
            onPressed: _choose,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(Loc.t('Change folder', 'فولڈر بدلیں')),
          ),
          FilledButton.icon(
            onPressed: _busy || _off ? null : _backupNow,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.backup_outlined, size: 18),
            label: Text(Loc.t('Backup now', 'ابھی بیک اپ')),
          ),
          if (folder != null && !_off)
            TextButton.icon(
              onPressed: PcBackupMirror.openFolder,
              icon: const Icon(Icons.launch, size: 18),
              label: Text(Loc.t('Open folder', 'فولڈر کھولیں')),
            ),
        ]),
        const SizedBox(height: 10),
        Text(
          Loc.t('Important: backups are locked with your backup password. Write it down — on a new Windows you need it to restore.',
              'اہم: بیک اپ آپ کے بیک اپ پاسورڈ سے بند ہوتے ہیں۔ اسے لکھ لیں — نئی ونڈوز پر ریسٹور کے لیے یہی چاہیے۔'),
          style: TextStyle(fontSize: 12.5, color: p.flatAmberFg, fontWeight: FontWeight.w600),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BackupExportScreen())),
            child: Text(Loc.t('See backup password / restore', 'بیک اپ پاسورڈ دیکھیں / ریسٹور')),
          ),
        ),
      ]),
    );
  }
}
