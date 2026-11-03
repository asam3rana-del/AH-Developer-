import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_followup_repository.dart';
import '../models/due_followup.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Dashboard ka "Aaj ki Wasooli" card: aaj kis se paisa mangna hai, kitna overdue hai, toote wade, aur sab se
/// zaroori [CollectionFocus.top] parties (1 tap Call / WhatsApp). Card dabane par Due Reminders khulti hai.
///
/// Data dashboard ki taraf se aata hai ([DueFollowUpRepository.todaysFocus]); call / WhatsApp ke baad
/// [onChanged] chalta hai taake dashboard card dobara load kare.
class TodaysCollectionCard extends StatelessWidget {
  final CollectionFocus focus;
  final VoidCallback onOpen;
  final VoidCallback onChanged;
  const TodaysCollectionCard({super.key, required this.focus, required this.onOpen, required this.onChanged});

  AppPalette get _p => ThemeManager.palette;

  String _rs(double v) => 'Rs ${v.round()}';

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _whatsApp(BuildContext context, PartyFocus f) async {
    final id = f.party.partyId;
    try {
      final entries = id == null ? const <DueFollowUp>[] : await DueFollowUpRepository.instance.forParty(id);
      final ok = await launchUrl(reminderUriFor(f.party, entries), mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
      if (id != null) {
        await DueFollowUpRepository.instance
            .add(partyId: id, partyName: f.party.partyName, method: FollowUpMethod.whatsapp, outcome: FollowUpOutcome.sent);
        onChanged();
      }
    } catch (_) {
      if (context.mounted) _toast(context, 'WhatsApp nahi khul saka. Installed hai?');
    }
  }

  Future<void> _call(BuildContext context, PartyFocus f) async {
    final id = f.party.partyId;
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: f.party.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
      if (id != null) {
        await DueFollowUpRepository.instance
            .add(partyId: id, partyName: f.party.partyName, method: FollowUpMethod.call, outcome: FollowUpOutcome.sent);
        onChanged();
      }
    } catch (_) {
      if (context.mounted) _toast(context, Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
  }

  (String, Color) _reason(PartyFocus f) {
    final st = f.state;
    final fmt = DateFormat('d MMM');
    if (st.promiseBroken) {
      final amt = st.promise!.amount > 0 ? ' ${_rs(st.promise!.amount)}' : '';
      final d = fmt.format(DateTime.fromMillisecondsSinceEpoch(st.promise!.promiseDate));
      return (Loc.t('Promise broken: $d$amt', 'وعدہ ٹوٹا: $d$amt'), _p.red);
    }
    if (st.promiseToday) return (Loc.t('Promised for today', 'آج کا وعدہ'), _p.flatAmberFg);
    if (st.followUpDue) return (Loc.t('Follow-up due today', 'آج فالو اپ کا دن'), _p.flatAmberFg);
    if (f.oldestOverdueDays > 0) {
      return (Loc.t('${f.oldestOverdueDays} days overdue', '${f.oldestOverdueDays} دن سے بقایا'), _p.red);
    }
    return (Loc.t('Overdue', 'میعاد گزری'), _p.red);
  }

  Widget _stat(String label, String value, Color color) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _round(IconData icon, Color fg, Color bg, VoidCallback onTap) => InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: 17, color: fg),
        ),
      );

  Widget _row(BuildContext context, PartyFocus f) {
    final (reason, color) = _reason(f);
    final hasPhone = f.party.partyPhone.trim().isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.party.partyName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
              Text('${_rs(f.total)} • $reason',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
            ]),
          ),
          if (hasPhone) ...[
            _round(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(context, f)),
            const SizedBox(width: 8),
            _round(Icons.phone, _p.flatPurpleFg, _p.flatPurpleBg, () => _call(context, f)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = focus;
    final hot = f.actionCount > 0 || f.brokenCount > 0;
    final accent = f.isEmpty ? _p.flatTealFg : (hot ? _p.red : _p.flatAmberFg);
    return Material(
      color: _p.cardWhite,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: hot ? _p.red.withOpacity(0.5) : _p.border, width: hot ? 1.4 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onOpen,
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: accent.withOpacity(0.14), shape: BoxShape.circle),
                child: Icon(f.isEmpty ? Icons.check_circle_outline : Icons.payments_outlined, size: 19, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(Loc.t("Today's collection", 'آج کی وصولی'),
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: _p.textDark)),
              ),
              Text(Loc.t('Open', 'کھولیں'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.flatPurpleFg)),
              Icon(Icons.chevron_right, color: _p.flatPurpleFg),
            ]),
          ),
          const SizedBox(height: 10),
          if (f.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(Loc.t('Nothing to collect — all credit is paid', 'کوئی بقایا نہیں — سب ادا ہو چکا'),
                  style: TextStyle(fontSize: 13, color: _p.textMuted)),
            )
          else ...[
            Row(children: [
              _stat(Loc.t('Follow up today', 'آج فالو اپ'),
                  f.actionCount == 0 ? Loc.t('Nobody', 'کوئی نہیں') : '${f.actionCount} • ${_rs(f.actionAmount)}',
                  f.actionCount == 0 ? _p.flatTealFg : _p.red),
              const SizedBox(width: 10),
              _stat(Loc.t('Overdue', 'میعاد گزری'),
                  f.overdueCount == 0 ? Loc.t('None', 'کوئی نہیں') : '${f.overdueCount} • ${_rs(f.overdueAmount)}',
                  f.overdueCount == 0 ? _p.flatTealFg : _p.flatAmberFg),
            ]),
            if (f.brokenCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(Loc.t('${f.brokenCount} broken promise(s)', '${f.brokenCount} وعدے ٹوٹے'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.red)),
              ),
            if (f.top.isNotEmpty) ...[
              const Divider(height: 18),
              for (final p in f.top) _row(context, p),
            ],
          ],
        ]),
      ),
    );
  }
}
