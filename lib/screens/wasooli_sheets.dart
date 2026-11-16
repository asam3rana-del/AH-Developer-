import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/due_followup_repository.dart';
import '../models/due_followup.dart';
import '../models/wasooli_plan.dart';
import '../services/collection_actions.dart';
import '../utils/loc.dart';

/// Wasooli ki do chhoti sheets:
///  * [askBaqiKabDega] — payment ke baad: "Baqi Rs X kab dega?" (Kal / 3 din / 1 hafta / Mahine ke aakhir / koi aur).
///  * [showRabtaSheet] — call / WhatsApp ke baad ek sawal: Paisa mila / Wada kiya / Nahi mila.

const _blue = Color(0xFF1D4ED8);
const _blueInk = Color(0xFF1E3A8A);
const _green = Color(0xFF15803D);
const _red = Color(0xFFB91C1C);

String wasooliRs(double v) {
  final n = v.round().abs();
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return 'Rs ${v < 0 ? '-' : ''}$b';
}

const _monthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String wasooliDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.day} ${_monthsShort[d.month - 1]}';
}

/// Tareekh chunne wala hissa (jaldi buttons + "Koi aur tareekh"). [onPick] chuni hui tareekh (din ki shuruaat).
class _QuickDates extends StatelessWidget {
  final int? selected;
  final ValueChanged<int> onPick;
  const _QuickDates({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final options = <(String, String)>[
      ('kal', Loc.t('Kal', 'کل')),
      ('3din', Loc.t('3 din', '3 دن')),
      ('hafta', Loc.t('1 hafta', '1 ہفتہ')),
      ('mahina', Loc.t('Mahine ke aakhir', 'مہینے کے آخر')),
    ];
    final quick = {for (final o in options) o.$1: startOfDay(quickPromiseDate(o.$1))};
    final custom = selected != null && !quick.values.contains(selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.6,
          children: [
            for (final o in options)
              _choice(
                label: o.$2,
                on: selected == quick[o.$1],
                onTap: () => onPick(quick[o.$1]!),
              ),
          ],
        ),
        TextButton.icon(
          style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: _blue, minimumSize: const Size(0, 44)),
          icon: const Icon(Icons.calendar_month_outlined, size: 20),
          label: Text(custom
              ? '${Loc.t('Tareekh', 'تاریخ')}: ${wasooliDate(selected!)}'
              : Loc.t('Koi aur tareekh…', 'کوئی اور تاریخ…')),
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: DateTime(now.year, now.month, now.day + 1),
              firstDate: DateTime(now.year, now.month, now.day),
              lastDate: DateTime(now.year + 1, now.month, now.day),
            );
            if (d != null) onPick(DateTime(d.year, d.month, d.day).millisecondsSinceEpoch);
          },
        ),
      ],
    );
  }

  Widget _choice({required String label, required bool on, required VoidCallback onTap}) => Material(
        color: on ? _blue : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? _blue : const Color(0xFFBFDBFE)),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: on ? Colors.white : _blueInk)),
          ),
        ),
      );
}

int startOfDay(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

Widget _handle() => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(2)),
      ),
    );

ShapeBorder get _sheetShape => const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)));

/// Payment ke baad: "Baqi Rs X kab dega?" Tareekh (din ki shuruaat) ya 0 = "abhi nahi". null = band kar di.
Future<int?> askBaqiKabDega(BuildContext context, {required String partyName, required double remaining}) {
  int? picked; // sheet ke rebuild (keyboard / rotation) par bhi chuni hui tareekh rahe
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: _sheetShape,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _handle(),
                Text(partyName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(Loc.t('Payment save ho gayi', 'ادائیگی محفوظ ہو گئی'),
                    style: const TextStyle(fontSize: 14, color: _green, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(Loc.t('Baqi ${wasooliRs(remaining)} kab dega?', 'باقی ${wasooliRs(remaining)} کب دے گا؟'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _blueInk)),
                      const SizedBox(height: 10),
                      _QuickDates(selected: picked, onPick: (d) => setS(() => picked = d)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: const Color(0xFF101C4A)),
                  onPressed: picked == null ? null : () => Navigator.pop(ctx, picked),
                  child: Text(Loc.t('Wada save karo', 'وعدہ محفوظ کریں'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  onPressed: () => Navigator.pop(ctx, 0),
                  child: Text(Loc.t('Abhi tareekh nahi — sirf payment', 'ابھی تاریخ نہیں — صرف ادائیگی')),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Rabta ke baad ek sawal. [method] = call / whatsapp / note. true = kuch save hua.
Future<bool> showRabtaSheet(
  BuildContext context, {
  required WasooliRow row,
  String method = FollowUpMethod.call,
}) async {
  final partyId = row.party.partyId;
  if (partyId == null) return false;
  final choice = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: _sheetShape,
    builder: (ctx) => _RabtaSheet(row: row, method: method),
  );
  if (choice == 'paid' && context.mounted) {
    return receiveFromParty(context, partyId: partyId, partyName: row.party.partyName, due: row.total);
  }
  return choice == 'saved';
}

class _RabtaSheet extends StatefulWidget {
  final WasooliRow row;
  final String method;
  const _RabtaSheet({required this.row, required this.method});

  @override
  State<_RabtaSheet> createState() => _RabtaSheetState();
}

class _RabtaSheetState extends State<_RabtaSheet> {
  String? _mode; // 'promise' | null
  int? _date;
  final _amount = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(String outcome) async {
    final id = widget.row.party.partyId!;
    setState(() => _saving = true);
    try {
      final tomorrow = quickPromiseDate('kal');
      await DueFollowUpRepository.instance.add(
        partyId: id,
        partyName: widget.row.party.partyName,
        method: widget.method,
        outcome: outcome,
        amount: outcome == FollowUpOutcome.promised ? (double.tryParse(_amount.text.trim()) ?? 0) : 0,
        promiseDate: outcome == FollowUpOutcome.promised ? (_date ?? 0) : 0,
        // Nahi mila => kal phir list mein.
        nextFollowUp: outcome == FollowUpOutcome.noAnswer ? tomorrow : 0,
        note: outcome == FollowUpOutcome.noAnswer ? 'Nahi mila' : '',
      );
      if (mounted) Navigator.pop(context, 'saved');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _big(String label, Color fg, Color border, Color bg, VoidCallback? onTap) => Expanded(
        child: SizedBox(
          height: 64,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              side: BorderSide(color: border, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: _saving ? null : onTap,
            child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final promise = _mode == 'promise';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 12, 18, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _handle(),
              Text(r.party.partyName, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('${Loc.t('Baqi', 'باقی')} ${wasooliRs(r.total)} · ${Loc.t('Kya hua?', 'کیا ہوا؟')}',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF4B5563))),
              const SizedBox(height: 16),
              Row(children: [
                _big(Loc.t('Paisa mila', 'پیسے ملے'), const Color(0xFF166534), _green, const Color(0xFFF0FDF4),
                    () => Navigator.pop(context, 'paid')),
                const SizedBox(width: 8),
                _big(Loc.t('Wada kiya', 'وعدہ کیا'), _blue, promise ? _blue : const Color(0xFFD1D5DB),
                    promise ? const Color(0xFFEFF6FF) : Colors.white, () => setState(() => _mode = 'promise')),
                const SizedBox(width: 8),
                _big(Loc.t('Nahi mila', 'نہیں ملا'), _red, const Color(0xFFD1D5DB), Colors.white,
                    () => _save(FollowUpOutcome.noAnswer)),
              ]),
              if (promise) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(Loc.t('Kab dega?', 'کب دے گا؟'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _blueInk)),
                      const SizedBox(height: 10),
                      _QuickDates(selected: _date, onPick: (d) => setState(() => _date = d)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _amount,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                        decoration: InputDecoration(
                          labelText: Loc.t('Kitna dega (khali = poora baqi)', 'کتنا دے گا (خالی = پورا باقی)'),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: const Color(0xFF101C4A)),
                  onPressed: _saving || _date == null ? null : () => _save(FollowUpOutcome.promised),
                  child: Text(Loc.t('Wada save karo', 'وعدہ محفوظ کریں'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
