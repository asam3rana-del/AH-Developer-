import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/due_followup_repository.dart';
import '../models/due_followup.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Due Reminders ke follow-up sheets: nateeja likhna ([showFollowUpSheet]) aur party ki poori timeline
/// ([showFollowUpTimeline]). Data: lib/db/due_followup_repository.dart, logic: lib/models/due_followup.dart.

String followUpOutcomeLabel(String outcome) {
  switch (outcome) {
    case FollowUpOutcome.sent:
      return Loc.t('Sent (no result yet)', 'بھیجا (نتیجہ نہیں لکھا)');
    case FollowUpOutcome.paid:
      return Loc.t('Paid', 'ادا کر دیا');
    case FollowUpOutcome.promised:
      return Loc.t('Promised', 'وعدہ کیا');
    case FollowUpOutcome.partial:
      return Loc.t('Part payment', 'کچھ ادا کیا');
    case FollowUpOutcome.noAnswer:
      return Loc.t('No answer', 'جواب نہیں');
    case FollowUpOutcome.refused:
      return Loc.t('Refused / excuse', 'انکار / بہانہ');
    case FollowUpOutcome.dispute:
      return Loc.t('Dispute', 'تنازع');
    default:
      return Loc.t('Note', 'نوٹ');
  }
}

String followUpMethodLabel(String method) {
  switch (method) {
    case FollowUpMethod.whatsapp:
      return 'WhatsApp';
    case FollowUpMethod.call:
      return Loc.t('Call', 'کال');
    case FollowUpMethod.visit:
      return Loc.t('Visit', 'ملاقات');
    case FollowUpMethod.sms:
      return 'SMS';
    default:
      return Loc.t('Note', 'نوٹ');
  }
}

IconData followUpMethodIcon(String method) {
  switch (method) {
    case FollowUpMethod.whatsapp:
      return Icons.send;
    case FollowUpMethod.call:
      return Icons.phone;
    case FollowUpMethod.visit:
      return Icons.directions_walk;
    case FollowUpMethod.sms:
      return Icons.sms_outlined;
    default:
      return Icons.edit_note;
  }
}

int _plusDays(int n) {
  final d = DateTime.now();
  return DateTime(d.year, d.month, d.day + n).millisecondsSinceEpoch;
}

/// Nateeja likhne ki sheet. [existing] ho (jaise khud ban'ne wali "sent" entry) to wahi entry update hoti hai,
/// warna nayi entry ([method] ke saath). true = kuch save hua.
Future<bool> showFollowUpSheet(
  BuildContext context, {
  required int partyId,
  required String partyName,
  DueFollowUp? existing,
  String method = FollowUpMethod.note,
  double suggestedAmount = 0,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ThemeManager.palette.cardWhite,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => _FollowUpSheet(
      partyId: partyId,
      partyName: partyName,
      existing: existing,
      method: method,
      suggestedAmount: suggestedAmount,
    ),
  );
  return saved == true;
}

class _FollowUpSheet extends StatefulWidget {
  final int partyId;
  final String partyName;
  final DueFollowUp? existing;
  final String method;
  final double suggestedAmount;
  const _FollowUpSheet({
    required this.partyId,
    required this.partyName,
    required this.existing,
    required this.method,
    required this.suggestedAmount,
  });

  @override
  State<_FollowUpSheet> createState() => _FollowUpSheetState();
}

class _FollowUpSheetState extends State<_FollowUpSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _outcome = '';
  int _promise = 0;
  int _next = 0;
  bool _saving = false;

  final _dateFmt = DateFormat('d MMM yyyy');

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e == null) {
      _outcome = FollowUpOutcome.note;
    } else {
      _outcome = e.outcome == FollowUpOutcome.sent ? '' : e.outcome;
      _promise = e.promiseDate;
      _next = e.nextFollowUp;
      _note.text = e.note;
      if (e.amount > 0) _amount.text = e.amount.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Nateeja badalne par aam tay-shuda tareekhen (user baad mein badal sakta hai).
  void _choose(String o) {
    setState(() {
      _outcome = o;
      switch (o) {
        case FollowUpOutcome.promised:
          _promise = _promise > 0 ? _promise : _plusDays(1);
          _next = _promise;
        case FollowUpOutcome.partial:
          _promise = 0;
          _next = _plusDays(3);
        case FollowUpOutcome.noAnswer:
          _promise = 0;
          _next = _plusDays(1);
        case FollowUpOutcome.refused:
          _promise = 0;
          _next = _plusDays(3);
        default:
          _promise = 0;
          _next = 0;
      }
    });
  }

  Future<int?> _pickDay(int initial) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial > 0 ? DateTime.fromMillisecondsSinceEpoch(initial) : DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(2100),
    );
    if (picked == null) return null;
    return DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch;
  }

  Future<void> _save() async {
    if (_outcome.isEmpty) {
      _toast(Loc.t('Pick what happened', 'بتائیں کیا ہوا'));
      return;
    }
    final promiseOutcome = _outcome == FollowUpOutcome.promised;
    if (promiseOutcome && _promise <= 0) {
      _toast(Loc.t('Pick the promised date', 'وعدے کی تاریخ چنیں'));
      return;
    }
    setState(() => _saving = true);
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final repo = DueFollowUpRepository.instance;
    final promise = (promiseOutcome || _outcome == FollowUpOutcome.partial) ? _promise : 0;
    final next = _outcome == FollowUpOutcome.paid ? 0 : _next;
    final e = widget.existing;
    try {
      if (e != null && e.id != null) {
        await repo.setResult(
            id: e.id!, outcome: _outcome, amount: amount, promiseDate: promise, nextFollowUp: next, note: _note.text);
      } else {
        await repo.add(
          partyId: widget.partyId,
          partyName: widget.partyName,
          method: widget.method,
          outcome: _outcome,
          amount: amount,
          promiseDate: promise,
          nextFollowUp: next,
          note: _note.text,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(Loc.t('Could not save', 'محفوظ نہیں ہو سکا'));
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _p.textDark)),
      );

  Widget _dayChips(int value, ValueChanged<int> onChanged, {required bool clearable}) {
    Widget chip(String label, VoidCallback onTap) => ActionChip(
          label: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.flatPurpleFg)),
          backgroundColor: _p.flatPurpleBg,
          side: BorderSide.none,
          onPressed: onTap,
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 6, children: [
        chip(Loc.t('Tomorrow', 'کل'), () => onChanged(_plusDays(1))),
        chip(Loc.t('3 days', '3 دن'), () => onChanged(_plusDays(3))),
        chip(Loc.t('7 days', '7 دن'), () => onChanged(_plusDays(7))),
        chip(Loc.t('Pick…', 'تاریخ…'), () async {
          final d = await _pickDay(value);
          if (d != null) onChanged(d);
        }),
        if (clearable && value > 0) chip(Loc.t('Clear', 'ہٹائیں'), () => onChanged(0)),
      ]),
      if (value > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(value)),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.flatTealFg)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final showAmount = _outcome == FollowUpOutcome.paid ||
        _outcome == FollowUpOutcome.partial ||
        _outcome == FollowUpOutcome.promised;
    final showPromise = _outcome == FollowUpOutcome.promised || _outcome == FollowUpOutcome.partial;
    final showNext = _outcome.isNotEmpty && _outcome != FollowUpOutcome.paid;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.partyName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
            const SizedBox(height: 2),
            Text(
              widget.existing != null && widget.existing!.outcome == FollowUpOutcome.sent
                  ? '${followUpMethodLabel(widget.existing!.method)} • ${Loc.t('What happened?', 'کیا ہوا؟')}'
                  : Loc.t('Follow-up note', 'فالو اپ نوٹ'),
              style: TextStyle(fontSize: 12, color: _p.textMuted),
            ),
            _label(Loc.t('Result', 'نتیجہ')),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final o in FollowUpOutcome.choices)
                ChoiceChip(
                  label: Text(followUpOutcomeLabel(o), style: const TextStyle(fontSize: 12.5)),
                  selected: _outcome == o,
                  onSelected: (_) => _choose(o),
                ),
            ]),
            if (showAmount) ...[
              _label(_outcome == FollowUpOutcome.promised
                  ? Loc.t('Promised amount (optional)', 'وعدے کی رقم (اختیاری)')
                  : Loc.t('Amount received (optional)', 'وصول شدہ رقم (اختیاری)')),
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                style: TextStyle(color: _p.textDark),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.suggestedAmount > 0 ? 'Rs ${widget.suggestedAmount.round()}' : 'Rs',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (_outcome == FollowUpOutcome.paid || _outcome == FollowUpOutcome.partial)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    Loc.t('This is only a note. Record the payment itself with "Payment Received".',
                        'یہ صرف نوٹ ہے۔ اصل ادائیگی "ادائیگی وصول" سے درج کریں۔'),
                    style: TextStyle(fontSize: 11.5, color: _p.textMuted),
                  ),
                ),
            ],
            if (showPromise) ...[
              _label(Loc.t('Promised date', 'وعدے کی تاریخ')),
              _dayChips(_promise, (v) => setState(() {
                    _promise = v;
                    if (_outcome == FollowUpOutcome.promised) _next = v;
                  }), clearable: false),
            ],
            if (showNext) ...[
              _label(Loc.t('Next follow-up', 'اگلا فالو اپ')),
              _dayChips(_next, (v) => setState(() => _next = v), clearable: true),
            ],
            _label(Loc.t('Note (optional)', 'نوٹ (اختیاری)')),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              style: TextStyle(color: _p.textDark),
              decoration: InputDecoration(
                isDense: true,
                hintText: Loc.t('e.g. said he will pay on Friday', 'مثلاً: جمعہ کو دینے کا کہا'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(Loc.t('Save', 'محفوظ کریں')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Party ki poori follow-up timeline. [totalDue] sirf upar dikhane ke liye. Band hone par caller screen
/// ko dobara load karna chahiye (entry add / edit / delete ho sakti hai).
Future<void> showFollowUpTimeline(
  BuildContext context, {
  required int partyId,
  required String partyName,
  required double totalDue,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ThemeManager.palette.cardWhite,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => _TimelineSheet(partyId: partyId, partyName: partyName, totalDue: totalDue),
  );
}

class _TimelineSheet extends StatefulWidget {
  final int partyId;
  final String partyName;
  final double totalDue;
  const _TimelineSheet({required this.partyId, required this.partyName, required this.totalDue});

  @override
  State<_TimelineSheet> createState() => _TimelineSheetState();
}

class _TimelineSheetState extends State<_TimelineSheet> {
  List<DueFollowUp> _entries = const [];
  bool _loading = true;

  final _dayFmt = DateFormat('d MMM yyyy');
  final _timeFmt = DateFormat('h:mm a');

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await DueFollowUpRepository.instance.forParty(widget.partyId);
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final ok = await showFollowUpSheet(context,
        partyId: widget.partyId, partyName: widget.partyName, suggestedAmount: widget.totalDue);
    if (ok) {
      await _load();
    }
  }

  Future<void> _edit(DueFollowUp e) async {
    final ok = await showFollowUpSheet(context,
        partyId: widget.partyId,
        partyName: widget.partyName,
        existing: e,
        method: e.method,
        suggestedAmount: widget.totalDue);
    if (ok) {
      await _load();
    }
  }

  Future<void> _delete(DueFollowUp e) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete this entry?', 'یہ اندراج ہٹائیں؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Delete', 'ہٹائیں'))),
        ],
      ),
    );
    if (yes != true || e.id == null) return;
    await DueFollowUpRepository.instance.delete(e.id!);
    await _load();
  }

  Widget _entryRow(DueFollowUp e) {
    final when = DateTime.fromMillisecondsSinceEpoch(e.createdAt);
    final lines = <String>[];
    if (e.amount > 0) lines.add('Rs ${e.amount.round()}');
    if (e.promiseDate > 0) {
      lines.add('${Loc.t('Promise', 'وعدہ')}: ${_dayFmt.format(DateTime.fromMillisecondsSinceEpoch(e.promiseDate))}');
    }
    if (e.nextFollowUp > 0) {
      lines.add('${Loc.t('Next', 'اگلا')}: ${_dayFmt.format(DateTime.fromMillisecondsSinceEpoch(e.nextFollowUp))}');
    }
    final bad = e.outcome == FollowUpOutcome.refused || e.outcome == FollowUpOutcome.noAnswer || e.outcome == FollowUpOutcome.dispute;
    final good = e.outcome == FollowUpOutcome.paid || e.outcome == FollowUpOutcome.partial || e.outcome == FollowUpOutcome.promised;
    final accent = good ? _p.flatTealFg : bad ? _p.red : _p.textMuted;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _edit(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: accent.withOpacity(0.14), shape: BoxShape.circle),
            child: Icon(followUpMethodIcon(e.method), size: 16, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${followUpMethodLabel(e.method)} • ${followUpOutcomeLabel(e.outcome)}',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
              Text(
                '${_dayFmt.format(when)}, ${_timeFmt.format(when)}${e.staff.isEmpty ? '' : ' • ${e.staff}'}',
                style: TextStyle(fontSize: 11.5, color: _p.textMuted),
              ),
              if (lines.isNotEmpty)
                Text(lines.join(' • '), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent)),
              if (e.note.isNotEmpty) Text(e.note, style: TextStyle(fontSize: 12, color: _p.textDark)),
            ]),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 18, color: _p.textMuted),
            onPressed: () => _delete(e),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = promiseRecord(_entries);
    final st = followUpState(_entries);
    return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            children: [
              Text(widget.partyName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
              const SizedBox(height: 2),
              Text('Rs ${widget.totalDue.round()} ${Loc.t('due', 'واجب الادا')}',
                  style: TextStyle(fontSize: 12, color: _p.textMuted)),
              if (rec.made > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    Loc.t('Promises: ${rec.kept} of ${rec.made} kept', 'وعدے: ${rec.made} میں سے ${rec.kept} پورے'),
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: rec.broken > rec.kept ? _p.red : _p.flatTealFg),
                  ),
                ),
              if (st.promiseBroken)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    Loc.t('Promise broken: ${_dayFmt.format(DateTime.fromMillisecondsSinceEpoch(st.promise!.promiseDate))}',
                        'وعدہ ٹوٹ گیا: ${_dayFmt.format(DateTime.fromMillisecondsSinceEpoch(st.promise!.promiseDate))}'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.red),
                  ),
                ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 18),
                label: Text(Loc.t('Add note / result', 'نوٹ / نتیجہ شامل کریں')),
              ),
              const SizedBox(height: 6),
              if (_loading)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(Loc.t('No follow-up recorded yet', 'ابھی کوئی فالو اپ درج نہیں'),
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _p.textMuted)),
                )
              else
                for (final e in _entries) _entryRow(e),
            ],
          ),
        ),
    );
  }
}
