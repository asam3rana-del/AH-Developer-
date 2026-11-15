import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/shell_repository.dart';
import '../models/shell.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors ShellLedgerActivity.kt — Bottle Shell Ledger (filled bottles given,
/// empty shells returned, plus the shop's own empty-shell stock). All roles.
class ShellLedgerScreen extends StatefulWidget {
  const ShellLedgerScreen({super.key});

  @override
  State<ShellLedgerScreen> createState() => _ShellLedgerScreenState();
}

class _ShellLedgerScreenState extends State<ShellLedgerScreen> {
  static final _dt = DateFormat('dd MMM, hh:mm a');
  final _search = TextEditingController();
  ShellSummary? _sum;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _guard(_reload);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final s = await ShellRepository.instance.summary();
    if (mounted) setState(() => _sum = s);
  }

  /// One action at a time (no double-save from a double tap).
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } catch (e) {
      if (mounted) _toast(e is ArgumentError ? '${e.message}' : (e is StateError ? e.message : e.toString()));
    } finally {
      _busy = false;
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  String _reason(String key) {
    for (final r in shopReasonLabels) {
      if (r.$1 == key) return Loc.t(r.$2, r.$3);
    }
    return key;
  }

  // ---------------------------------------------------------------- dialogs

  Future<void> _issueReturn(ShellCustomer? prefill) async {
    final p = ThemeManager.palette;
    final nameC = TextEditingController(text: prefill?.name ?? '');
    final phoneC = TextEditingController(text: prefill?.phone ?? '');
    final qtyC = TextEditingController();
    final noteC = TextEditingController();
    var isIssue = true;
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(Loc.t('Issue / Return Shell', 'شیل اجرا / واپسی')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: nameC,
                enabled: prefill == null,
                decoration: InputDecoration(labelText: Loc.t('Customer name', 'کسٹمر کا نام')),
              ),
              if (prefill == null)
                TextField(
                  controller: phoneC,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: Loc.t('Phone (optional)', 'فون (اختیاری)')),
                ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _chip(p, Loc.t('ISSUE (gave filled)', 'اجرا (بھری دی)'), isIssue, p.red, () => setD(() => isIssue = true))),
                const SizedBox(width: 8),
                Expanded(child: _chip(p, Loc.t('RETURN (shell back)', 'واپسی (شیل واپس)'), !isIssue, p.teal, () => setD(() => isIssue = false))),
              ]),
              TextField(
                controller: qtyC,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: Loc.t('Quantity (shells)', 'تعداد (شیلز)'), errorText: err),
              ),
              TextField(controller: noteC, decoration: InputDecoration(labelText: Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
              if (prefill != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('${prefill.name} ${Loc.t('currently owes', 'فی الحال واجب')} ${prefill.shellsOwed}',
                      style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                final q = int.tryParse(qtyC.text.trim());
                if (nameC.text.trim().isEmpty) {
                  setD(() => err = Loc.t('Enter a customer name', 'کسٹمر کا نام درج کریں'));
                } else if (q == null || q <= 0) {
                  setD(() => err = Loc.t('Enter a valid quantity', 'درست تعداد درج کریں'));
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: Text(Loc.t('Save', 'محفوظ کریں')),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    await ShellRepository.instance.saveIssueReturn(
      name: nameC.text,
      phone: phoneC.text,
      isIssue: isIssue,
      qty: int.parse(qtyC.text.trim()),
      note: noteC.text,
    );
    if (mounted) _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
    await _reload();
  }

  Future<void> _shopStock() async {
    final p = ThemeManager.palette;
    final qtyC = TextEditingController();
    final noteC = TextEditingController();
    var reason = shopAdd;
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(Loc.t('Shop Empty Shell Stock', 'دکان کا خالی شیل اسٹاک')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _chip(p, Loc.t('+ Add', '+ شامل'), reason == shopAdd, p.teal, () => setD(() => reason = shopAdd))),
                const SizedBox(width: 6),
                Expanded(child: _chip(p, Loc.t('\u2212 Remove', '\u2212 نکالیں'), reason == shopRemove, p.red, () => setD(() => reason = shopRemove))),
                const SizedBox(width: 6),
                Expanded(child: _chip(p, Loc.t('Sent for Refill', 'ری فل کے لیے بھیجی'), reason == shopRefill, p.amber, () => setD(() => reason = shopRefill))),
              ]),
              TextField(
                controller: qtyC,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: Loc.t('Quantity (shells)', 'تعداد (شیلز)'), errorText: err),
              ),
              TextField(controller: noteC, decoration: InputDecoration(labelText: Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                final q = int.tryParse(qtyC.text.trim());
                if (q == null || q <= 0) {
                  setD(() => err = Loc.t('Enter a valid quantity', 'درست تعداد درج کریں'));
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: Text(Loc.t('Save', 'محفوظ کریں')),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await ShellRepository.instance.saveShopStock(reason: reason, qty: int.parse(qtyC.text.trim()), note: noteC.text);
    } on StateError {
      if (mounted) _toast(Loc.t('Not enough shop stock to remove that much', 'اتنی مقدار نکالنے کے لیے اسٹاک کافی نہیں'));
      return;
    }
    if (mounted) _toast(Loc.t('Saved', 'محفوظ ہو گیا'));
    await _reload();
  }

  Future<void> _customerDetail(ShellCustomer c) async {
    final p = ThemeManager.palette;
    final hist = await ShellRepository.instance.history(c.id!);
    if (!mounted) return;
    final again = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c.name),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            Text('${Loc.t('Currently owes: ', 'فی الحال واجب: ')}${c.shellsOwed}',
                style: TextStyle(fontWeight: FontWeight.bold, color: c.shellsOwed > 0 ? p.red : p.teal)),
            const SizedBox(height: 12),
            if (hist.isEmpty)
              Text(Loc.t('No transactions yet', 'ابھی کوئی لین دین نہیں'), style: TextStyle(color: p.textMuted))
            else
              for (final t in hist)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${t.isIssue ? '+ ' : '\u2212 '}${t.qty} ${t.isIssue ? Loc.t('Issued', 'اجرا') : Loc.t('Returned', 'واپس')}${t.note.isNotEmpty ? ' (${t.note})' : ''}',
                        style: TextStyle(fontSize: 12.5, color: t.isIssue ? p.red : p.teal),
                      ),
                    ),
                    Text(_dt.format(DateTime.fromMillisecondsSinceEpoch(t.createdAt)), style: TextStyle(fontSize: 10.5, color: p.textMuted)),
                  ]),
                ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Close', 'بند کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Issue / Return', 'اجرا / واپسی'))),
        ],
      ),
    );
    if (again == true) await _issueReturn(c);
  }

  Future<void> _shopHistory() async {
    final p = ThemeManager.palette;
    final hist = await ShellRepository.instance.shopHistory();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Shop Stock History', 'دکان اسٹاک کی تاریخ')),
        content: SizedBox(
          width: double.maxFinite,
          child: hist.isEmpty
              ? Text(Loc.t('No shop stock entries yet', 'ابھی کوئی دکان اسٹاک انٹری نہیں'), style: TextStyle(color: p.textMuted))
              : ListView(shrinkWrap: true, children: [
                  for (final l in hist)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            '${l.delta >= 0 ? '+' : ''}${l.delta}  ${_reason(l.reason)}${l.note.isNotEmpty ? ' (${l.note})' : ''}',
                            style: TextStyle(fontSize: 12.5, color: l.delta >= 0 ? p.teal : p.red),
                          ),
                        ),
                        Text(_dt.format(DateTime.fromMillisecondsSinceEpoch(l.createdAt)), style: TextStyle(fontSize: 10.5, color: p.textMuted)),
                      ]),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں')))],
      ),
    );
  }

  // ---------------------------------------------------------------- UI

  Widget _chip(AppPalette p, String label, bool on, Color color, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: on ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: on ? null : Border.all(color: p.border),
          ),
          child: Center(
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: on ? Colors.white : p.textMuted))),
        ),
      );

  Widget _statCard(AppPalette p, IconData icon, String label, int value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.cardWhite,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 18, backgroundColor: color.withOpacity(0.14), child: Icon(icon, size: 18, color: color)),
              const SizedBox(width: 8),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.textMuted))),
            ]),
            const SizedBox(height: 10),
            Text('$value', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      );

  Widget _btn(String label, Color color, VoidCallback onTap) => Expanded(
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final s = _sum;
    final all = s?.customers ?? const <ShellCustomer>[];
    final list = filterShellCustomers(all, _search.text);
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        Container(
          color: p.navy,
          padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
          child: Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
              child: const Icon(Icons.repeat, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(Loc.t('Bottle Shell Ledger', 'بوتل شیل لیجر'), style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
                Text(Loc.t('Filled bottles given & shells returned', 'دی گئی بھری بوتلیں اور واپس شیل'),
                    style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: s == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 32), children: [
                  Row(children: [
                    _statCard(p, Icons.people, Loc.t('Owed by Customers', 'کسٹمرز پر واجب'), s.owedTotal, p.red),
                    const SizedBox(width: 12),
                    _statCard(p, Icons.inventory_2, Loc.t('Shop Empty Stock', 'دکان کا خالی اسٹاک'), s.shopStock, p.teal),
                  ]),
                  const SizedBox(height: 18),
                  Row(children: [
                    _btn(Loc.t('ISSUE / RETURN', 'اجرا / واپسی'), p.navy, () => _guard(() => _issueReturn(null))),
                    const SizedBox(width: 12),
                    _btn(Loc.t('SHOP STOCK', 'دکان اسٹاک'), p.teal, () => _guard(_shopStock)),
                  ]),
                  const SizedBox(height: 22),
                  Text(Loc.t('CUSTOMERS', 'کسٹمرز'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: Loc.t('Search customer name or phone\u2026', 'کسٹمر کا نام یا فون تلاش کریں\u2026'),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      filled: true,
                      fillColor: p.fieldFill,
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.teal)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          all.isEmpty ? Loc.t('No shell customers yet', 'ابھی کوئی شیل کسٹمر نہیں') : Loc.t('No matches', 'کوئی نتیجہ نہیں'),
                          style: TextStyle(color: p.textMuted),
                        ),
                      ),
                    )
                  else
                    for (final c in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _guard(() => _customerDetail(c)),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: p.cardWhite,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
                            ),
                            child: Row(children: [
                              CircleAvatar(radius: 19, backgroundColor: p.navy.withOpacity(0.1), child: Icon(Icons.person, size: 17, color: p.navy)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(c.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                                  if (c.phone.isNotEmpty) Text(c.phone, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                                ]),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(color: c.shellsOwed > 0 ? p.red : p.teal, borderRadius: BorderRadius.circular(20)),
                                child: Text('${c.shellsOwed} ${Loc.t('owed', 'واجب')}',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12.5)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => _guard(_shopHistory),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(children: [
                        Icon(Icons.history, size: 14, color: p.teal),
                        const SizedBox(width: 6),
                        Text(Loc.t('Shop Stock History', 'دکان اسٹاک کی تاریخ'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: p.teal)),
                      ]),
                    ),
                  ),
                ]),
        ),
      ]),
    );
  }
}
