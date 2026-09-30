import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/session.dart';
import '../sync/branch_config_store.dart';
import '../sync/cloud_config_store.dart';
import '../sync/settings_sync.dart';
import '../sync/sync_worker.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Kotlin `SettingsSync.kt` ka UI: "Sync Now" (live status dot), long-press tools, "Cloud Sync Setup",
/// "Sync History". Logic `lib/sync/settings_sync.dart` mein (test: `test/settings_sync_test.dart`).
///
/// Roles: Sync Now aur Sync History sab ko; Cloud Sync Setup aur long-press repair/cleanup tools
/// sirf admin ko (PORTING_PLAN role rule — Kotlin Settings mein ye sab admin ki screen hai).
class SyncSection extends StatefulWidget {
  const SyncSection({super.key});

  @override
  State<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<SyncSection> {
  SyncStatus? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await SettingsSync.status();
    if (mounted) setState(() => _status = s);
  }

  void _toast(String m, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      duration: Duration(seconds: long ? 5 : 3),
    ));
  }

  Future<bool> _confirm(String title, String message, {String? okLabel}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(okLabel ?? Loc.t('Continue', 'جاری رکھیں'))),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _info(String title, String message) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  // ------------------------------------------------------------ Sync Now

  /// Kotlin `onSyncNowClicked`.
  Future<void> _syncNow() async {
    if (!await SettingsSync.isOnline()) {
      _toast(Loc.t('No internet connection', 'انٹرنیٹ کنکشن نہیں'));
      await _refresh();
      return;
    }
    _toast(Loc.t('Syncing…', 'سنک ہو رہا ہے…'));
    final summary = await SettingsSync.syncNow();
    if (summary != null) _toast(summary, long: true);
    await _refresh();
  }

  // -------------------------------------------------- long-press tools

  Future<void> _showMore() async {
    if (!SettingsSync.requireAdmin(Session.role)) {
      _toast(Loc.t('Only Admin can use these tools', 'یہ ٹولز صرف ایڈمن استعمال کر سکتا ہے'));
      return;
    }
    final which = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(Loc.t('Sync Now — more options', 'Sync Now — مزید آپشنز'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ListTile(
              leading: const Icon(Icons.history),
              title: Text(Loc.t('Resync from a date/time (pull)', 'تاریخ/وقت سے دوبارہ سنک (پل)')),
              onTap: () => Navigator.pop(ctx, 0)),
          ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(Loc.t('Force full push — resend ALL local data (push)', 'فل پش — سارا لوکل ڈیٹا دوبارہ بھیجیں')),
              onTap: () => Navigator.pop(ctx, 1)),
          ListTile(
              leading: const Icon(Icons.event_repeat),
              title: Text(Loc.t('Fix back-dated Purchase/Sale cash entries', 'پرانی تاریخ کی کیش انٹریز ٹھیک کریں')),
              onTap: () => Navigator.pop(ctx, 2)),
          ListTile(
              leading: const Icon(Icons.calculate_outlined),
              title: Text(Loc.t('Recalculate party balances (Customers/Suppliers)', 'پارٹی بیلنس دوبارہ حساب کریں')),
              onTap: () => Navigator.pop(ctx, 3)),
          ListTile(
              leading: Icon(Icons.delete_sweep_outlined, color: ThemeManager.palette.red),
              title: Text(Loc.t('Delete cloud data with a wrong Branch ID (admin cleanup)', 'غلط برانچ آئی ڈی کا کلاؤڈ ڈیٹا حذف کریں'),
                  style: TextStyle(color: ThemeManager.palette.red)),
              onTap: () => Navigator.pop(ctx, 4)),
        ]),
      ),
    );
    switch (which) {
      case 0:
        return _resyncFrom();
      case 1:
        return _forceFullPush();
      case 2:
        return _fixBackdatedCash();
      case 3:
        return _recalculateBalances();
      case 4:
        return _deleteByWrongBranch();
    }
  }

  Future<void> _resyncFrom() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (day == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now));
    if (t == null || !mounted) return;
    final from = DateTime(day.year, day.month, day.day, t.hour, t.minute);
    await SettingsSync.resyncFrom(from);
    _toast(Loc.t('Resyncing from ${formatSyncTime(from.millisecondsSinceEpoch)}…',
        '${formatSyncTime(from.millisecondsSinceEpoch)} سے دوبارہ سنک…'), long: true);
    await _syncNow();
  }

  Future<void> _forceFullPush() async {
    final ok = await _confirm(
      Loc.t('Force full push?', 'فل پش کریں؟'),
      Loc.t(
        "This will send ALL of this device's local data (customers, products, sales, purchases, payments, expenses, "
            'cash transactions, users, units, categories, zakat, returns, shop settings) to the cloud again — it will '
            "OVERWRITE what is currently there. Use only when this device's data is the correct one and the cloud data "
            'is old/wrong. Continue?',
        'یہ اس ڈیوائس کا سارا لوکل ڈیٹا دوبارہ کلاؤڈ پر بھیجے گا اور وہاں موجود ڈیٹا اوور رائٹ ہو جائے گا۔ صرف تب '
            'استعمال کریں جب اس ڈیوائس کا ڈیٹا درست ہو اور کلاؤڈ کا پرانا/غلط۔ جاری رکھیں؟',
      ),
    );
    if (!ok || !mounted) return;
    _toast(Loc.t('Queuing all local data…', 'سارا لوکل ڈیٹا قطار میں…'));
    await SettingsSync.forceFullPush();
    await _syncNow();
  }

  Future<void> _fixBackdatedCash() async {
    final ok = await _confirm(
      Loc.t('Fix back-dated cash entries?', 'پرانی تاریخ کی کیش انٹریز ٹھیک کریں؟'),
      Loc.t(
        'For Purchases/Sales that were back-dated, this checks their Cash Register entry and sets it to the '
            "bill's real date (where it still sits on today's date by mistake). Other entries (payments, Quick Sale, "
            'cash in/out) are not touched. Continue?',
        'جو خرید/فروخت پرانی تاریخ میں بنی، ان کی کیش رجسٹر انٹری چیک کر کے بل کی اصل تاریخ پر کر دے گا (جہاں غلطی سے آج کی '
            'تاریخ پر ہے)۔ باقی انٹریز (پیمنٹس، کوئیک سیل، کیش ان/آؤٹ) کو نہیں چھیڑے گا۔ جاری رکھیں؟',
      ),
    );
    if (!ok || !mounted) return;
    _toast(Loc.t('Checking cash entries…', 'کیش انٹریز چیک ہو رہی ہیں…'));
    final fixed = await SettingsSync.fixBackdatedCash();
    _toast(
      fixed > 0
          ? Loc.t('$fixed cash entries fixed.', '$fixed کیش انٹریز کی تاریخ ٹھیک کر دی گئی۔')
          : Loc.t('No wrong-date entries found — all fine.', 'کوئی غلط تاریخ والی انٹری نہیں ملی — سب ٹھیک ہے۔'),
      long: true,
    );
    await _syncNow();
  }

  Future<void> _recalculateBalances() async {
    final ok = await _confirm(
      Loc.t('Recalculate party balances?', 'پارٹی بیلنس دوبارہ حساب کریں؟'),
      Loc.t(
        "Recomputes every Customer/Supplier balance from their own sale/purchase bills and payments, and corrects "
            'any stored balance that does not match. Opening balance is not touched. Continue?',
        'ہر کسٹمر/سپلائر کا بیلنس ان کے اپنے سیل/پرچیز بلز اور پیمنٹس سے دوبارہ گنے گا، اور جہاں محفوظ بیلنس میل نہ کھائے '
            'اسے ٹھیک کر دے گا۔ اوپننگ بیلنس کو نہیں چھیڑے گا۔ جاری رکھیں؟',
      ),
    );
    if (!ok || !mounted) return;
    _toast(Loc.t('Checking party balances…', 'پارٹی بیلنس چیک ہو رہے ہیں…'));
    final r = await SettingsSync.recalculatePartyBalances();
    if (!mounted) return;
    final total = r.customersFixed + r.suppliersFixed;
    if (total == 0) {
      _toast(Loc.t('No mismatch found — all balances are already correct.', 'کوئی فرق نہیں ملا — سب بیلنس پہلے سے ٹھیک ہیں۔'),
          long: true);
    } else {
      await _info(
        Loc.t('$total balance(s) corrected', '$total بیلنس ٹھیک کر دیے گئے'),
        Loc.t('Customers: ${r.customersFixed}\nSuppliers: ${r.suppliersFixed}',
            'کسٹمرز: ${r.customersFixed}\nسپلائرز: ${r.suppliersFixed}'),
      );
    }
    if (mounted) await _syncNow();
  }

  Future<void> _deleteByWrongBranch() async {
    if (!SettingsSync.requireAdmin(Session.role)) return;
    final ctrl = TextEditingController();
    final badId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete cloud data by Branch ID', 'برانچ آئی ڈی کے مطابق کلاؤڈ ڈیٹا حذف')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t(
              "This deletes ONLY the data of the Branch ID you type here — this device's own branch is never touched. "
                  'The branch_members and users collections are not touched either. First it only SCANS (nothing is '
                  'deleted); you delete only after seeing the counts.\n\nType the wrong Branch ID:',
              'یہ صرف اسی برانچ آئی ڈی کا ڈیٹا حذف کرے گا جو آپ یہاں لکھیں گے — اس ڈیوائس کی اپنی برانچ کو ہاتھ نہیں لگایا '
                  'جائے گا۔ branch_members اور users بھی نہیں چھیڑی جائیں گی۔ پہلے صرف SCAN ہوگا (کچھ حذف نہیں)، گنتی دیکھ کر '
                  'آپ تصدیق کریں گے تب ہی حذف ہوگا۔\n\nغلط برانچ آئی ڈی لکھیں:',
            )),
            const SizedBox(height: 10),
            TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'e.g. dusri-branch', border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(Loc.t('Scan', 'اسکین'))),
        ],
      ),
    );
    ctrl.dispose();
    if (badId == null || !mounted) return;
    final err = SettingsSync.checkWrongBranchInput(badId);
    if (err != null) {
      _toast(err, long: true);
      return;
    }
    _toast(Loc.t('Scanning…', 'اسکین ہو رہا ہے…'));
    final counts = await SettingsSync.scanWrongBranch(badId);
    if (!mounted) return;
    if (counts.isEmpty) {
      _toast(Loc.t('No document found for "${badId.trim()}".', '"${badId.trim()}" کا کوئی دستاویز نہیں ملا۔'), long: true);
      return;
    }
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    final go = await _confirm(
      Loc.t('$total document(s) found — delete?', '$total دستاویز ملے — حذف کریں؟'),
      Loc.t('Branch ID "${badId.trim()}":\n\n${SettingsSync.countsSummary(counts)}\n\nThis is permanent and cannot be undone. Continue?',
          'برانچ آئی ڈی "${badId.trim()}":\n\n${SettingsSync.countsSummary(counts)}\n\nیہ مستقل ہے، واپس نہیں آ سکتا۔ جاری رکھیں؟'),
      okLabel: Loc.t('Delete', 'حذف'),
    );
    if (!go || !mounted) return;
    _toast(Loc.t('Deleting…', 'حذف ہو رہا ہے…'));
    final deleted = await SettingsSync.deleteWrongBranch(badId);
    if (!mounted) return;
    final n = deleted.values.fold<int>(0, (a, b) => a + b);
    await _info(
      Loc.t('$n document(s) deleted', '$n دستاویز حذف ہو گئے'),
      deleted.isEmpty ? Loc.t('Nothing was deleted.', 'کچھ حذف نہیں ہوا۔') : SettingsSync.countsSummary(deleted),
    );
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final admin = SettingsSync.requireAdmin(Session.role);
    final s = _status;
    final Color dot = s == null
        ? ThemeManager.palette.textMuted
        : s.needsSetup
            ? ThemeManager.palette.amber
            : s.kind == SyncStatusKind.connected
                ? ThemeManager.palette.teal
                : ThemeManager.palette.red;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.sync, color: ThemeManager.palette.navyInk),
            const SizedBox(width: 8),
            Text(Loc.t('Cloud Sync', 'کلاؤڈ سنک'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _syncNow,
            onLongPress: _showMore,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                ValueListenableBuilder<bool>(
                  valueListenable: SyncWorker.instance.isRunning,
                  builder: (_, running, __) => running
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Icon(Icons.sync, color: ThemeManager.palette.teal),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Sync Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Icon(Icons.circle, size: 9, color: dot),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(s?.label ?? '…', style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
                      ),
                    ]),
                  ]),
                ),
                if (admin) Icon(Icons.more_horiz, color: ThemeManager.palette.textMuted),
              ]),
            ),
          ),
          if (admin) ...[
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cloud_outlined, color: ThemeManager.palette.navyInk),
              title: const Text('Cloud Sync Setup'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await showDialog<void>(context: context, builder: (_) => const CloudSyncSetupDialog());
                await _refresh();
              },
            ),
          ],
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.receipt_long_outlined, color: ThemeManager.palette.navyInk),
            title: const Text('Sync History'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(context: context, builder: (_) => const SyncHistoryDialog()),
          ),
        ]),
      ),
    );
  }
}

// ===================================================================== Sync History

/// Kotlin `openSyncHistoryDialog`: pehle atke hue items (Retry Now), phir audit ki taaza qataren
/// (conflict / push failed numaya), aur "Clear History".
class SyncHistoryDialog extends StatefulWidget {
  const SyncHistoryDialog({super.key});

  @override
  State<SyncHistoryDialog> createState() => _SyncHistoryDialogState();
}

class _SyncHistoryDialogState extends State<SyncHistoryDialog> {
  SyncHistory? _h;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await SettingsSync.loadHistory();
    if (mounted) setState(() => _h = h);
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    return AlertDialog(
      title: const Text('Sync History'),
      content: SizedBox(
        width: double.maxFinite,
        child: h == null
            ? const Padding(padding: EdgeInsets.all(12), child: Text('Loading…'))
            : ListView(shrinkWrap: true, children: [
                if (h.stuckCount > 0)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ThemeManager.palette.amber.withOpacity(0.12),
                      border: Border.all(color: ThemeManager.palette.amber),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Icon(Icons.warning_amber_rounded, color: ThemeManager.palette.amber, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          Loc.t('${h.stuckCount} item(s) stopped after failing 10 times',
                              '${h.stuckCount} آئٹم 10 بار ناکام ہو کر رک گئے'),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ThemeManager.palette.amber),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.amber),
                        onPressed: () async {
                          await SettingsSync.retryStuck();
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(Loc.t('Will retry on the next Sync Now', 'اگلی Sync Now پر دوبارہ کوشش ہوگی'))));
                        },
                        child: Text(Loc.t('Retry Now', 'ابھی دوبارہ')),
                      ),
                    ]),
                  ),
                if (h.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(Loc.t('No sync activity or conflict recorded yet.', 'ابھی تک کوئی سنک سرگرمی یا ٹکراؤ ریکارڈ نہیں ہوا۔'),
                        style: TextStyle(color: ThemeManager.palette.textMuted)),
                  ),
                for (final e in h.entries) _row(e),
              ]),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await SettingsSync.clearHistory();
            if (!context.mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(Loc.t('Sync history cleared', 'سنک ہسٹری صاف ہو گئی'))));
          },
          child: const Text('Clear History'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Close', 'بند کریں'))),
      ],
    );
  }

  Widget _row(AuditEntry e) {
    final flagged = e.isConflict || e.isPushFailure;
    final color = e.isConflict ? ThemeManager.palette.amber : (e.isPushFailure ? ThemeManager.palette.red : ThemeManager.palette.textMuted);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: flagged ? ThemeManager.palette.amber.withOpacity(0.08) : ThemeManager.palette.cardWhite,
        border: Border.all(color: ThemeManager.palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (e.isConflict) Icon(Icons.warning_amber_rounded, size: 14, color: color),
          if (e.isPushFailure) Icon(Icons.close, size: 14, color: color),
          if (flagged) const SizedBox(width: 5),
          Expanded(child: Text(e.title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: color))),
        ]),
        if (e.details.trim().isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(e.details, style: const TextStyle(fontSize: 11.5))),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(formatSyncTime(e.createdAt), style: TextStyle(fontSize: 10.5, color: ThemeManager.palette.textMuted)),
        ),
      ]),
    );
  }
}

// ===================================================================== Cloud Sync Setup

/// Kotlin `openCloudSyncSetupDialog`: admin apne Firebase project ki 4 values + is device ka Branch Code
/// dalta hai; Device ID (Firebase UID) copy kar ke Firebase console wale ko de sakta hai
/// (`branch_members/{uid}` banane ke liye). Asli Branch badalna pending records ho to mana (P1 security).
class CloudSyncSetupDialog extends StatefulWidget {
  const CloudSyncSetupDialog({super.key});

  @override
  State<CloudSyncSetupDialog> createState() => _CloudSyncSetupDialogState();
}

class _CloudSyncSetupDialogState extends State<CloudSyncSetupDialog> {
  final _projectId = TextEditingController();
  final _apiKey = TextEditingController();
  final _appId = TextEditingController();
  final _bucket = TextEditingController();
  final _branch = TextEditingController();
  bool _hasExisting = false;
  bool _loaded = false;
  String? _uid;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_projectId, _apiKey, _appId, _bucket, _branch]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Clipboard mein google-services.json ho to 4 fields khud bhar do (Branch Code alag rehta hai).
  Future<void> _pasteGoogleServices() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final cfg = parseGoogleServicesJson(data?.text ?? '');
    if (!mounted) return;
    if (cfg == null) {
      return _toast(Loc.t('Clipboard mein google-services.json nahi mili — poora text copy karke dobara try karein',
          'کلپ بورڈ میں google-services.json نہیں ملی — پورا متن کاپی کر کے دوبارہ کوشش کریں'));
    }
    setState(() {
      _projectId.text = cfg.projectId;
      _apiKey.text = cfg.apiKey;
      _appId.text = cfg.appId;
      _bucket.text = cfg.storageBucket;
    });
    _toast(Loc.t('Fields filled — now enter Branch Code and Save', 'فیلڈز بھر گئیں — اب برانچ کوڈ لکھیں اور محفوظ کریں'));
  }

  Future<void> _load() async {
    final existing = await CloudConfigStore.get();
    final uid = await SettingsSync.deviceId();
    if (!mounted) return;
    setState(() {
      _hasExisting = existing != null;
      _projectId.text = existing?.projectId ?? '';
      _apiKey.text = existing?.apiKey ?? '';
      _appId.text = existing?.appId ?? '';
      _bucket.text = existing?.storageBucket ?? '';
      _branch.text = BranchConfigStore.current;
      _uid = uid;
      _loaded = true;
    });
  }

  void _toast(String m, {bool long = false}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: long ? 5 : 3)));

  Future<void> _pendingDialog(String message, {String? extraLabel, VoidCallback? extra}) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Pending offline records', 'آف لائن ریکارڈز باقی ہیں')),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
            if (extraLabel != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  extra?.call();
                },
                child: Text(extraLabel),
              ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                SettingsSync.trigger();
              },
              child: const Text('Sync Now'),
            ),
          ],
        ),
      );

  Future<void> _save() async {
    if (_busy) return;
    final projectId = _projectId.text.trim();
    final apiKey = _apiKey.text.trim();
    final appId = _appId.text.trim();
    final bucket = _bucket.text.trim();
    final branch = _branch.text.trim();
    final err = validateCloudSetup(projectId: projectId, apiKey: apiKey, appId: appId, branchId: branch);
    if (err != null) {
      _toast(err, long: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final oldBranch = BranchConfigStore.current;
      final decision = decideCloudSetupSave(
        branchConfigured: BranchConfigStore.isConfigured(),
        oldBranch: oldBranch,
        newBranch: branch,
        pendingCount: await SettingsSync.pendingCount(),
      );
      if (!mounted) return;
      if (decision.blocked) {
        await _pendingDialog(Loc.t(
          "This device still has ${decision.pending} record(s) waiting to sync for branch '$oldBranch'. They must sync "
              'before changing the branch, otherwise they would go to the wrong branch.\n\nTry "Sync Now" first, then '
              'save the Branch Code again once everything has synced.',
          "اس ڈیوائس پر ابھی ${decision.pending} ریکارڈ برانچ '$oldBranch' کے لیے سنک ہونے باقی ہیں۔ برانچ بدلنے سے پہلے انہیں "
              'سنک کرنا ضروری ہے، ورنہ یہ غلط برانچ میں چلے جائیں گے۔\n\nپہلے "Sync Now" آزمائیں، سب سنک ہو جائے تو برانچ کوڈ دوبارہ محفوظ کریں۔',
        ));
        return;
      }
      await SettingsSync.saveCloudSetup(
          projectId: projectId, apiKey: apiKey, appId: appId, storageBucket: bucket, branchId: branch);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(Loc.t('Cloud project connected — now try Sync Now', 'کلاؤڈ پراجیکٹ جڑ گیا — اب Sync Now آزمائیں'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      Future<void> doIt() async {
        await SettingsSync.disconnect();
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(Loc.t('Cloud project and Branch Code disconnected', 'کلاؤڈ پراجیکٹ اور برانچ کوڈ الگ ہو گئے'))));
      }

      final pending = await SettingsSync.pendingCount();
      if (!mounted) return;
      if (pending > 0) {
        await _pendingDialog(
          Loc.t(
            'This device still has $pending record(s) waiting to sync. Sync them before disconnecting, otherwise they '
                'may later go to the wrong branch.',
            'اس ڈیوائس پر ابھی $pending ریکارڈ سنک ہونے باقی ہیں۔ الگ کرنے سے پہلے انہیں سنک کر لیں، ورنہ یہ بعد میں غلط برانچ '
                'میں جا سکتے ہیں۔',
          ),
          extraLabel: Loc.t('Disconnect Anyway', 'پھر بھی الگ کریں'),
          extra: () => doIt(),
        );
      } else {
        await doIt();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: c,
          maxLines: 1,
          decoration: InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud Sync Setup'),
      content: SizedBox(
        width: double.maxFinite,
        child: !_loaded
            ? const Padding(padding: EdgeInsets.all(12), child: Text('Loading…'))
            : SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    Loc.t(
                      'Firebase Console → Project Settings → General → Your apps → Config shows these 4 values. Leave them empty '
                          "to go back to this build's default project (if any).",
                      'Firebase Console → Project Settings → General → Your apps → Config میں یہ 4 ویلیوز ملیں گی۔ خالی چھوڑنے پر '
                          'اس بلڈ کا ڈیفالٹ پراجیکٹ (اگر ہو) استعمال ہوگا۔',
                    ),
                    style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pasteGoogleServices,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: Text(Loc.t('Paste google-services.json', 'google-services.json پیسٹ کریں')),
                  ),
                  Text(
                    Loc.t('Copy the full text of google-services.json (e.g. from the Kotlin app repo: app/google-services.json), then tap this button.',
                        'google-services.json کا پورا متن کاپی کریں (مثلاً Kotlin ایپ ریپو: app/google-services.json)، پھر یہ بٹن دبائیں۔'),
                    style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
                  ),
                  _field('Project ID', _projectId),
                  _field('API Key', _apiKey),
                  _field('App ID', _appId),
                  _field('Storage Bucket', _bucket),
                  const SizedBox(height: 14),
                  Text(
                    Loc.t(
                      "This device's Branch Code — different for each branch, like \"main-branch\" or \"dusri-branch\". All devices "
                          'that share one branch must use the same code.',
                      'اس ڈیوائس کا برانچ کوڈ — ہر برانچ کا الگ، جیسے "main-branch" یا "dusri-branch"۔ ایک ہی برانچ کا ڈیٹا شیئر '
                          'کرنے والے سب ڈیوائسز کا کوڈ ایک جیسا ہونا چاہیے۔',
                    ),
                    style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
                  ),
                  _field('Branch Code', _branch),
                  const SizedBox(height: 14),
                  Text(
                    Loc.t('Device ID (share with admin so this device can be approved for branch access)',
                        'ڈیوائس آئی ڈی (ایڈمن کو دیں تاکہ یہ ڈیوائس برانچ رسائی کے لیے منظور ہو سکے)'),
                    style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(
                      child: SelectableText(
                        _uid ?? Loc.t('Save first — the ID appears after the first sync attempt', 'پہلے محفوظ کریں — پہلی سنک کوشش کے بعد آئی ڈی یہاں آئے گی'),
                        style: TextStyle(fontSize: 12.5, color: _uid != null ? ThemeManager.palette.textDark : ThemeManager.palette.textMuted),
                      ),
                    ),
                    if (_uid != null)
                      TextButton(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _uid!));
                          if (mounted) _toast(Loc.t('Device ID copied', 'ڈیوائس آئی ڈی کاپی ہو گئی'));
                        },
                        child: const Text('Copy'),
                      ),
                  ]),
                ]),
              ),
      ),
      actions: [
        if (_hasExisting) TextButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ'))),
        FilledButton(onPressed: _busy || !_loaded ? null : _save, child: Text(Loc.t('Save', 'محفوظ کریں'))),
      ],
    );
  }
}
