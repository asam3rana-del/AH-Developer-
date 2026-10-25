import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/utility_bill_repository.dart';
import '../services/bill_reminder_service.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Utility Bills: bijli, gas, pani, internet, mobile ke mahana bills — due date, "Paid" ka nishan aur
/// reminder (ek din pehle + due din, BillReminderService). Sirf Admin/Manager (Settings mein row aur RoleGuard).

String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
String _rs(double v) => 'Rs ${_plain(v)}';

void _toast(BuildContext c, String m) => ScaffoldMessenger.of(c)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(m)));

String _err(Object e) {
  if (e is StateError) return e.message;
  if (e is ArgumentError) return '${e.message}';
  return e.toString();
}

BoxDecoration _card(AppPalette p, [double r = 16]) => BoxDecoration(
      color: p.cardWhite,
      borderRadius: BorderRadius.circular(r),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
    );

InputDecoration _deco(AppPalette p, String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: p.textMuted),
      filled: true,
      fillColor: p.fieldFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.teal)),
    );

Widget _header(BuildContext context, AppPalette p, String title, String subtitle) {
  return Container(
    color: p.navy,
    padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 8, 14),
    child: Row(children: [
      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
          Text(subtitle, style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
        ]),
      ),
    ]),
  );
}

String _kindLabel(String k) {
  switch (k) {
    case 'electricity':
      return Loc.t('Electricity', 'بجلی');
    case 'gas':
      return Loc.t('Gas', 'گیس');
    case 'water':
      return Loc.t('Water', 'پانی');
    case 'internet':
      return Loc.t('Internet', 'انٹرنیٹ');
    case 'phone':
      return Loc.t('Mobile / Phone', 'موبائل / فون');
    default:
      return Loc.t('Other', 'دیگر');
  }
}

IconData _kindIcon(String k) {
  switch (k) {
    case 'electricity':
      return Icons.bolt;
    case 'gas':
      return Icons.local_fire_department_outlined;
    case 'water':
      return Icons.water_drop_outlined;
    case 'internet':
      return Icons.wifi;
    case 'phone':
      return Icons.phone_android;
    default:
      return Icons.receipt_long_outlined;
  }
}

String _dateLabel(DateTime d) => DateFormat('d MMM yyyy').format(d);

({String text, Color color}) _statusChip(BillStatus s) {
  if (s.paid) return (text: Loc.t('Paid', 'ادا شدہ'), color: ThemeManager.palette.teal);
  if (s.overdue) {
    return (text: Loc.t('Overdue ${-s.daysLeft}d', '${-s.daysLeft} دن لیٹ'), color: ThemeManager.palette.red);
  }
  if (s.dueToday) return (text: Loc.t('Due today', 'آج آخری تاریخ'), color: ThemeManager.palette.red);
  if (s.dueTomorrow) return (text: Loc.t('Due tomorrow', 'کل آخری تاریخ'), color: ThemeManager.palette.amber);
  if (s.daysLeft <= 5) return (text: Loc.t('In ${s.daysLeft} days', '${s.daysLeft} دن باقی'), color: ThemeManager.palette.amber);
  return (text: Loc.t('In ${s.daysLeft} days', '${s.daysLeft} دن باقی'), color: ThemeManager.palette.textMuted);
}

class UtilityBillsScreen extends StatefulWidget {
  const UtilityBillsScreen({super.key});

  @override
  State<UtilityBillsScreen> createState() => _UtilityBillsScreenState();
}

class _UtilityBillsScreenState extends State<UtilityBillsScreen> {
  List<BillView> _views = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
    BillReminderService.requestPermission();
  }

  Future<void> _reload() async {
    final v = await UtilityBillRepository.instance.views(backfillSync: true);
    if (!mounted) return;
    setState(() {
      _views = v;
      _loaded = true;
    });
  }

  Future<void> _addOrEdit([UtilityBill? existing]) async {
    final b = await showDialog<UtilityBill>(context: context, builder: (_) => _BillForm(existing: existing));
    if (b == null) return;
    try {
      await UtilityBillRepository.instance.save(b);
      await _reload();
      // Naya bill ya due din badla: reminder agle check par khud aa jayega.
      BillReminderService.checkAndNotify();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _pay(BillView v) async {
    final r = await showDialog<_PayResult>(context: context, builder: (_) => _PayDialog(view: v));
    if (r == null) return;
    try {
      await UtilityBillRepository.instance.pay(
        bill: v.bill,
        month: v.status.month,
        amount: r.amount,
        method: r.method,
        note: r.note,
        recordExpense: r.recordExpense,
      );
      await _reload();
      if (mounted) _toast(context, Loc.t('${v.bill.name} marked as paid', '${v.bill.name} ادا شدہ نشان ہو گیا'));
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _delete(UtilityBill b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(Loc.t('Delete bill?', 'بل ہٹائیں؟')),
        content: Text(Loc.t('"${b.name}" and its payment history will be removed. Expenses already recorded stay as they are.',
            '"${b.name}" اور اس کی ادائیگی کی ہسٹری ہٹ جائے گی۔ جو اخراجات پہلے لکھے جا چکے وہ ویسے ہی رہیں گے۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(Loc.t('Delete', 'ہٹائیں'))),
        ],
      ),
    );
    if (ok != true || b.id == null) return;
    try {
      await UtilityBillRepository.instance.deleteBill(b.id!);
      await _reload();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _history(UtilityBill b) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ThemeManager.palette.cardWhite,
      builder: (_) => _HistorySheet(bill: b),
    );
    await _reload();
  }

  void _actions(BillView v) {
    final p = ThemeManager.palette;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardWhite,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(Loc.t('Payment history', 'ادائیگی کی ہسٹری')),
            onTap: () {
              Navigator.pop(c);
              _history(v.bill);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(Loc.t('Edit bill', 'بل ایڈٹ کریں')),
            onTap: () {
              Navigator.pop(c);
              _addOrEdit(v.bill);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: ThemeManager.palette.red),
            title: Text(Loc.t('Delete bill', 'بل ہٹائیں'), style: TextStyle(color: ThemeManager.palette.red)),
            onTap: () {
              Navigator.pop(c);
              _delete(v.bill);
            },
          ),
        ]),
      ),
    );
  }

  Widget _summary(AppPalette p) {
    final pending = _views.where((v) => !v.status.paid).toList();
    final overdue = pending.where((v) => v.status.overdue).length;
    final due = pending.fold<double>(0, (a, v) => a + v.suggestedAmount);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      padding: const EdgeInsets.all(16),
      decoration: _card(p),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('To pay', 'ادا کرنے ہیں'), style: TextStyle(color: p.textMuted, fontSize: 12)),
            const SizedBox(height: 4),
            Text('${pending.length}', style: TextStyle(color: p.textDark, fontSize: 22, fontWeight: FontWeight.bold)),
          ]),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Overdue', 'لیٹ'), style: TextStyle(color: p.textMuted, fontSize: 12)),
            const SizedBox(height: 4),
            Text('$overdue',
                style: TextStyle(
                    color: overdue > 0 ? ThemeManager.palette.red : p.textDark, fontSize: 22, fontWeight: FontWeight.bold)),
          ]),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Approx. total', 'تقریباً کل'), style: TextStyle(color: p.textMuted, fontSize: 12)),
            const SizedBox(height: 4),
            Text(_rs(due), style: TextStyle(color: p.textDark, fontSize: 18, fontWeight: FontWeight.bold)),
          ]),
        ),
      ]),
    );
  }

  Widget _tile(AppPalette p, BillView v) {
    final chip = _statusChip(v.status);
    final b = v.bill;
    final subtitle = v.status.paid
        ? Loc.t('${_kindLabel(b.kind)} • due day ${b.dueDay}', '${_kindLabel(b.kind)} • آخری تاریخ ${b.dueDay}')
        : Loc.t('${_kindLabel(b.kind)} • due ${_dateLabel(v.status.due)}',
            '${_kindLabel(b.kind)} • آخری تاریخ ${_dateLabel(v.status.due)}');
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      decoration: _card(p),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _actions(v),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: chip.color.withOpacity(0.12),
              child: Icon(_kindIcon(b.kind), color: chip.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.name, style: TextStyle(color: p.textDark, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: p.textMuted, fontSize: 12)),
                const SizedBox(height: 6),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: chip.color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text(chip.text, style: TextStyle(color: chip.color, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ),
                  if (!b.reminder) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.notifications_off_outlined, size: 15, color: p.textMuted),
                  ],
                  if (v.suggestedAmount > 0) ...[
                    const Spacer(),
                    Text(_rs(v.suggestedAmount), style: TextStyle(color: p.textDark, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ]),
            ),
            if (!v.status.paid) ...[
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: p.teal, padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: () => _pay(v),
                child: Text(Loc.t('Pay', 'ادا کریں')),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Scaffold(
      backgroundColor: p.bg,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.teal,
        foregroundColor: Colors.white,
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: Text(Loc.t('Add Bill', 'بل شامل کریں')),
      ),
      body: Column(children: [
        _header(context, p, Loc.t('Utility Bills', 'یوٹیلیٹی بلز'),
            Loc.t('Monthly bills, due dates and reminders', 'ماہانہ بل، آخری تاریخ اور ریمائنڈر')),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _views.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          Loc.t('No bills yet. Add electricity, gas, water, internet... with their due day, and you will be reminded a day before.',
                              'ابھی کوئی بل نہیں۔ بجلی، گیس، پانی، انٹرنیٹ... آخری تاریخ کے ساتھ شامل کریں، ایک دن پہلے ریمائنڈر آئے گا۔'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.textMuted, fontSize: 15),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 100),
                        children: [_summary(p), for (final v in _views) _tile(p, v)],
                      ),
                    ),
        ),
      ]),
    );
  }
}

// ===================================================================== add / edit form

class _BillForm extends StatefulWidget {
  final UtilityBill? existing;
  const _BillForm({this.existing});

  @override
  State<_BillForm> createState() => _BillFormState();
}

class _BillFormState extends State<_BillForm> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _day =
      TextEditingController(text: widget.existing == null ? '' : '${widget.existing!.dueDay}');
  late final TextEditingController _amount = TextEditingController(
      text: (widget.existing?.avgAmount ?? 0) > 0 ? _plain(widget.existing!.avgAmount) : '');
  late String _kind = widget.existing?.kind ?? 'electricity';
  late bool _reminder = widget.existing?.reminder ?? true;
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _day.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final day = int.tryParse(_day.text.trim());
    final amount = _amount.text.trim().isEmpty ? 0.0 : double.tryParse(_amount.text.trim());
    if (name.isEmpty) return setState(() => _error = Loc.t('Enter bill name', 'بل کا نام لکھیں'));
    if (day == null || day < 1 || day > 31) {
      return setState(() => _error = Loc.t('Due day must be 1 to 31', 'آخری تاریخ 1 سے 31 کے درمیان ہو'));
    }
    if (amount == null || amount < 0) return setState(() => _error = Loc.t('Invalid amount', 'رقم درست نہیں'));
    final e = widget.existing;
    Navigator.pop(
      context,
      UtilityBill(
        id: e?.id,
        name: name,
        kind: _kind,
        dueDay: day,
        avgAmount: amount,
        reminder: _reminder,
        active: _active,
        createdAt: e?.createdAt ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return AlertDialog(
      backgroundColor: p.cardWhite,
      title: Text(widget.existing == null ? Loc.t('Add Bill', 'بل شامل کریں') : Loc.t('Edit Bill', 'بل ایڈٹ کریں')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<String>(
            value: _kind,
            decoration: _deco(p, ''),
            dropdownColor: p.cardWhite,
            items: [
              for (final k in billKinds)
                DropdownMenuItem(value: k, child: Row(children: [Icon(_kindIcon(k), size: 18), const SizedBox(width: 8), Text(_kindLabel(k))])),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _kind = v);
            },
          ),
          const SizedBox(height: 10),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: _deco(p, Loc.t('Bill name (e.g. LESCO, SNGPL)', 'بل کا نام (مثلاً LESCO)'))),
          const SizedBox(height: 10),
          TextField(
            controller: _day,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
            decoration: _deco(p, Loc.t('Due day of month (1-31)', 'مہینے کی آخری تاریخ (1-31)')),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: _deco(p, Loc.t('Average amount (optional)', 'اوسط رقم (اختیاری)')),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _reminder,
            onChanged: (v) => setState(() => _reminder = v),
            title: Text(Loc.t('Remind me', 'ریمائنڈر دیں')),
            subtitle: Text(Loc.t('A day before and on the due day', 'ایک دن پہلے اور آخری تاریخ کے دن')),
          ),
          if (widget.existing != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: Text(Loc.t('Active', 'چالو')),
              subtitle: Text(Loc.t('Turn off if you no longer pay this bill', 'اگر یہ بل اب نہیں بھرتے تو بند کر دیں')),
            ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: ThemeManager.palette.red))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ'))),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: p.teal), onPressed: _submit, child: Text(Loc.t('Save', 'محفوظ کریں'))),
      ],
    );
  }
}

// ===================================================================== pay dialog

class _PayResult {
  final double amount;
  final String method;
  final String note;
  final bool recordExpense;
  const _PayResult(this.amount, this.method, this.note, this.recordExpense);
}

class _PayDialog extends StatefulWidget {
  final BillView view;
  const _PayDialog({required this.view});

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late final TextEditingController _amount = TextEditingController(
      text: widget.view.suggestedAmount > 0 ? _plain(widget.view.suggestedAmount) : '');
  final TextEditingController _note = TextEditingController();
  String _method = 'cash';
  bool _expense = true;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final a = double.tryParse(_amount.text.trim());
    if (a == null || a <= 0) return setState(() => _error = Loc.t('Enter the amount paid', 'ادا کی گئی رقم لکھیں'));
    Navigator.pop(context, _PayResult(a, _method, _note.text, _expense));
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final v = widget.view;
    return AlertDialog(
      backgroundColor: p.cardWhite,
      title: Text('${v.bill.name} • ${v.status.month}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: _deco(p, Loc.t('Amount paid', 'ادا کی گئی رقم')),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _method,
            decoration: _deco(p, ''),
            dropdownColor: p.cardWhite,
            items: [
              DropdownMenuItem(value: 'cash', child: Text(Loc.t('Cash', 'کیش'))),
              DropdownMenuItem(value: 'bank', child: Text(Loc.t('Bank', 'بینک'))),
            ],
            onChanged: (x) {
              if (x != null) setState(() => _method = x);
            },
          ),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: _deco(p, Loc.t('Note / reference (optional)', 'نوٹ / ریفرنس (اختیاری)'))),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _expense,
            onChanged: (x) => setState(() => _expense = x),
            title: Text(Loc.t('Also record in Expense & Cash', 'اخراجات اور کیش میں بھی لکھیں')),
            subtitle: Text(Loc.t('Turn off if you already entered this payment', 'اگر یہ ادائیگی پہلے لکھ چکے ہیں تو بند کریں')),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: ThemeManager.palette.red))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Loc.t('Cancel', 'منسوخ'))),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: p.teal), onPressed: _submit, child: Text(Loc.t('Mark Paid', 'ادا شدہ'))),
      ],
    );
  }
}

// ===================================================================== history

class _HistorySheet extends StatefulWidget {
  final UtilityBill bill;
  const _HistorySheet({required this.bill});

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  List<BillPayment> _rows = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await UtilityBillRepository.instance.payments(widget.bill.id!);
    if (!mounted) return;
    setState(() {
      _rows = r;
      _loaded = true;
    });
  }

  Future<void> _undo(BillPayment x) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(Loc.t('Undo payment?', 'ادائیگی واپس کریں؟')),
        content: Text(x.expenseId != null
            ? Loc.t('The ${x.month} payment will be removed, along with its Expense and Cash entry.',
                '${x.month} کی ادائیگی ہٹ جائے گی، اس کا اخراجات اور کیش کا اندراج بھی۔')
            : Loc.t('The ${x.month} payment will be removed.', '${x.month} کی ادائیگی ہٹ جائے گی۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(Loc.t('Undo', 'واپس کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await UtilityBillRepository.instance.undoPayment(x.id);
      await _load();
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text('${widget.bill.name} • ${Loc.t('Payment history', 'ادائیگی کی ہسٹری')}',
                style: TextStyle(color: p.textDark, fontSize: 16.5, fontWeight: FontWeight.bold)),
          ),
          if (!_loaded)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_rows.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(Loc.t('No payments yet', 'ابھی کوئی ادائیگی نہیں'), style: TextStyle(color: p.textMuted)))
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final x in _rows)
                  ListTile(
                    title: Text('${x.month}  •  ${_rs(x.amount)}'),
                    subtitle: Text(
                        '${DateFormat('d MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(x.paidAt))} • ${x.method == 'bank' ? Loc.t('Bank', 'بینک') : Loc.t('Cash', 'کیش')}${x.note.isEmpty ? '' : ' • ${x.note}'}'),
                    trailing: IconButton(icon: const Icon(Icons.undo), tooltip: Loc.t('Undo', 'واپس'), onPressed: () => _undo(x)),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
