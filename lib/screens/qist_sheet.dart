import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/qist_repository.dart';
import '../models/qist_plan.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Customer ka qist plan: bana hua ho to har qist ki halat (ada / adhoori / late / aane wali); na ho to
/// admin / manager naya bana sakta hai. Payments pehle jaisi "Paisa mila" se — khud qiston par lagti hain.
Future<void> showQistSheet(BuildContext context, {required int customerId, required String name, required double due}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ThemeManager.palette.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _QistSheet(customerId: customerId, name: name, due: due),
    );

class _QistSheet extends StatefulWidget {
  final int customerId;
  final String name;
  final double due;
  const _QistSheet({required this.customerId, required this.name, required this.due});

  @override
  State<_QistSheet> createState() => _QistSheetState();
}

class _QistSheetState extends State<_QistSheet> {
  static const _counts = [2, 3, 4, 5, 6, 8, 10, 12];
  static const _intervals = [7, 15, 30];

  QistStatus? _status;
  bool _loading = true;
  bool _busy = false;

  final _total = TextEditingController();
  int _count = 4;
  int _every = 30;
  late DateTime _first;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _first = DateTime(n.year, n.month, n.day + 7);
    _total.text = widget.due > 0 ? widget.due.round().toString() : '';
    _load();
  }

  @override
  void dispose() {
    _total.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await QistRepository.instance.status(widget.customerId);
    if (mounted) {
      setState(() {
        _status = s;
        _loading = false;
      });
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _rs(double v) => 'Rs ${NumberFormat('#,##0').format(v.round())}';
  String _date(int millis) => DateFormat('dd MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(millis));
  String _everyLabel(int d) => d == 7
      ? Loc.t('Weekly', 'ہر ہفتے')
      : d == 15
          ? Loc.t('Every 15 days', 'ہر 15 دن')
          : Loc.t('Monthly (30 days)', 'ہر مہینے (30 دن)');

  Future<void> _create() async {
    final total = double.tryParse(_total.text.trim()) ?? 0;
    if (total <= 0) {
      _toast(Loc.t('Enter the plan amount', 'پلان کی رقم لکھیں'));
      return;
    }
    final plan = QistPlan(
      total: total,
      count: _count,
      firstDate: _first.millisecondsSinceEpoch,
      everyDays: _every,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _busy = true);
    try {
      await QistRepository.instance.savePlan(widget.customerId, plan);
      _toast(Loc.t('Installment plan saved', 'قسط پلان محفوظ ہو گیا'));
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Remove installment plan?', 'قسط پلان ہٹائیں؟')),
        content: Text(Loc.t('Payments stay as they are; only the schedule is removed.',
            'ادائیگیاں ویسی ہی رہیں گی؛ صرف شیڈول ہٹے گا۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Remove', 'ہٹائیں'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await QistRepository.instance.savePlan(widget.customerId, null);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${Loc.t('Installments', 'قسطیں')} — ${widget.name}',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: p.textDark)),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_status != null)
            ..._planView(p, _status!)
          else
            ..._createForm(p),
        ]),
      ),
    );
  }

  List<Widget> _planView(AppPalette p, QistStatus s) {
    final plan = s.plan;
    final today = DateTime.now();
    final todayMs = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
    var left = s.paid;
    final rows = <Widget>[];
    for (var i = 0; i < plan.count; i++) {
      final amt = plan.amountOf(i);
      final covered = left >= amt - 0.009 ? amt : (left < 0 ? 0.0 : left);
      left -= covered;
      final rem = amt - covered;
      final date = plan.dateOf(i);
      final String state;
      final Color color;
      if (rem <= 0.009) {
        state = Loc.t('Paid', 'ادا');
        color = p.teal;
      } else if (date < todayMs) {
        state = covered > 0.009 ? Loc.t('Late (part paid)', 'لیٹ (کچھ ادا)') : Loc.t('Late', 'لیٹ');
        color = p.red;
      } else if (date == todayMs) {
        state = Loc.t('Due today', 'آج');
        color = p.amber;
      } else {
        state = Loc.t('Upcoming', 'آنے والی');
        color = p.textMuted;
      }
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 34, child: Text('${i + 1}.', style: TextStyle(color: p.textMuted))),
          Expanded(child: Text(_date(date), style: TextStyle(color: p.textDark))),
          Text(_rs(amt), style: TextStyle(color: p.textDark)),
          const SizedBox(width: 10),
          SizedBox(width: 92, child: Text(state, textAlign: TextAlign.end, style: TextStyle(color: color, fontSize: 12.5))),
        ]),
      ));
    }
    return [
      Text(
        '${_rs(plan.total)} • ${plan.count} ${Loc.t('installments', 'قسطیں')} • ${_everyLabel(plan.everyDays)}\n'
        '${Loc.t('Received since plan', 'پلان کے بعد وصول')}: ${_rs(s.paid)} • ${Loc.t('Remaining', 'باقی')}: ${_rs(s.remaining)}',
        style: TextStyle(color: p.textMuted, fontSize: 12.5),
      ),
      if (s.overdue > 0.009) ...[
        const SizedBox(height: 8),
        Text('${Loc.t('Late amount', 'لیٹ رقم')}: ${_rs(s.overdue)}',
            style: TextStyle(color: p.red, fontWeight: FontWeight.bold)),
      ],
      if (s.completed) ...[
        const SizedBox(height: 8),
        Text(Loc.t('All installments paid ✓', 'تمام قسطیں ادا ✓'), style: TextStyle(color: p.teal, fontWeight: FontWeight.bold)),
      ],
      const SizedBox(height: 10),
      ...rows,
      const SizedBox(height: 12),
      Text(
        Loc.t('Record money with "Payment Received" as usual — it is applied to the installments in order.',
            'رقم پہلے کی طرح "Payment Received" سے درج کریں — خود ترتیب سے قسطوں پر لگے گی۔'),
        style: TextStyle(color: p.textMuted, fontSize: 11.5),
      ),
      if (Session.isAdminOrManager) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _remove,
          child: Text(Loc.t('REMOVE PLAN', 'پلان ہٹائیں'), style: TextStyle(color: p.red)),
        ),
      ],
    ];
  }

  List<Widget> _createForm(AppPalette p) {
    if (!Session.isAdminOrManager) {
      return [
        Text(Loc.t('No installment plan. Only admin or manager can make one.',
            'کوئی قسط پلان نہیں۔ صرف ایڈمن یا مینیجر بنا سکتا ہے۔'),
            style: TextStyle(color: p.textMuted)),
      ];
    }
    final total = double.tryParse(_total.text.trim()) ?? 0;
    final preview = total > 0
        ? QistPlan(total: total, count: _count, firstDate: _first.millisecondsSinceEpoch, everyDays: _every, createdAt: 0)
        : null;
    return [
      TextField(
        controller: _total,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: Loc.t('Plan amount (Rs)', 'پلان کی رقم (روپے)'),
          helperText: Loc.t('Current due: ${_rs(widget.due)}', 'موجودہ بقایا: ${_rs(widget.due)}'),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _count,
            decoration: InputDecoration(labelText: Loc.t('Installments', 'قسطیں'), border: const OutlineInputBorder()),
            items: [for (final c in _counts) DropdownMenuItem(value: c, child: Text('$c'))],
            onChanged: (v) => setState(() => _count = v ?? _count),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _every,
            isExpanded: true,
            decoration: InputDecoration(labelText: Loc.t('Every', 'ہر'), border: const OutlineInputBorder()),
            items: [for (final d in _intervals) DropdownMenuItem(value: d, child: Text(_everyLabel(d)))],
            onChanged: (v) => setState(() => _every = v ?? _every),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        icon: const Icon(Icons.event),
        label: Text('${Loc.t('First installment', 'پہلی قسط')}: ${DateFormat('dd MMM yyyy').format(_first)}'),
        onPressed: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: _first,
            firstDate: DateTime.now().subtract(const Duration(days: 1)),
            lastDate: DateTime.now().add(const Duration(days: 366)),
          );
          if (picked != null && mounted) setState(() => _first = picked);
        },
      ),
      if (preview != null) ...[
        const SizedBox(height: 8),
        Text(
          '$_count× ${_rs(preview.amountOf(0))}'
          '${preview.amountOf(_count - 1) != preview.amountOf(0) ? ' (${Loc.t('last', 'آخری')} ${_rs(preview.amountOf(_count - 1))})' : ''}'
          ' • ${Loc.t('last on', 'آخری')} ${_date(preview.dateOf(_count - 1))}',
          style: TextStyle(color: p.textMuted, fontSize: 12.5),
        ),
      ],
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: Text(Loc.t('SAVE PLAN', 'پلان محفوظ کریں')),
      ),
    ];
  }
}
