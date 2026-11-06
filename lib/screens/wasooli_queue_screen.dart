import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/collection_autopilot_repository.dart';
import '../db/due_followup_repository.dart';
import '../models/collection_autopilot.dart';
import '../models/due_followup.dart';
import '../services/collection_actions.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/party_avatar.dart';
import '../widgets/permission_guard.dart';
import '../widgets/premium_header.dart';

/// Wasooli Autopilot screen: aaj jin late / pending parties ko yaad dilana hai unki list, aur ek bara
/// "Agla bhejo" button — har tap par agli party ka WhatsApp khulta hai (message party ki halat ke hisaab se)
/// aur follow-up log mein khud entry banti hai, taake wo party aaj ke liye DONE ho jaye.
/// Malik 20 parties ko 2-3 minute mein nipta sakta hai; notification se seedha yahin aate hain.
///
/// Notification (DueAlertService) isi queue se banti hai, is liye jo yahan ho chuka wo shaam ki yaad-dihani
/// mein dobara nahi aata.
class WasooliQueueScreen extends StatelessWidget {
  const WasooliQueueScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const PermissionGuard(permission: 'due_reminders', child: _QueueBody());
}

class _QueueBody extends StatefulWidget {
  const _QueueBody();

  @override
  State<_QueueBody> createState() => _QueueBodyState();
}

class _QueueBodyState extends State<_QueueBody> with WidgetsBindingObserver {
  bool _loading = true;
  bool _busy = false;
  AutopilotDay _day = AutopilotDay.empty;

  AppPalette get _p => ThemeManager.palette;

  String _rs(double v) => 'Rs ${v.round()}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(showSpinner: false);
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner && mounted) setState(() => _loading = true);
    AutopilotDay day = AutopilotDay.empty;
    try {
      day = await CollectionAutopilotRepository.instance.today();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _day = day;
      _loading = false;
    });
  }

  bool _hasPhone(AutopilotItem e) => e.party.partyPhone.trim().isNotEmpty;

  Future<void> _whatsApp(AutopilotItem e) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await sendReminderTo(context, e.party);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load(showSpinner: false);
  }

  Future<void> _call(AutopilotItem e) async {
    final id = e.party.partyId;
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: e.party.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
      if (id != null) {
        await DueFollowUpRepository.instance
            .add(partyId: id, partyName: e.party.partyName, method: FollowUpMethod.call, outcome: FollowUpOutcome.sent);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'))));
      }
    }
    if (mounted) await _load(showSpinner: false);
  }

  Future<void> _received(AutopilotItem e) async {
    final id = e.party.partyId;
    if (id == null) return;
    final saved = await receiveFromParty(context, partyId: id, partyName: e.party.partyName, due: e.total);
    if (saved && mounted) await _load(showSpinner: false);
  }

  (String, Color) _reason(AutopilotItem e) {
    switch (e.reason) {
      case TouchReason.brokenPromise:
        return (Loc.t('Promise broken', 'وعدہ ٹوٹا'), _p.red);
      case TouchReason.promiseToday:
        return (Loc.t('Promised for today', 'آج کا وعدہ'), _p.flatAmberFg);
      case TouchReason.followUpDue:
        return (Loc.t('Follow-up due today', 'آج فالو اپ کا دن'), _p.flatAmberFg);
      case TouchReason.dueToday:
        return (Loc.t('Due today', 'آج ادائیگی کا دن'), _p.flatAmberFg);
      case TouchReason.late:
        return e.oldestDays > 0
            ? (Loc.t('${e.oldestDays} days late', '${e.oldestDays} دن لیٹ'), _p.red)
            : (Loc.t('Late', 'لیٹ'), _p.red);
    }
  }

  String _contactText(AutopilotItem e) {
    final d = e.daysSinceTouch;
    if (d == null) return Loc.t('Never contacted', 'ابھی تک بات نہیں ہوئی');
    if (d == 0) return Loc.t('Contacted today', 'آج بات ہو چکی');
    return Loc.t('Last contact $d day(s) ago', 'آخری بات $d دن پہلے');
  }

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

  Widget _row(AutopilotItem e, {bool actions = true}) {
    final (reason, color) = _reason(e);
    final id = e.party.partyId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        PartyAvatar(isCustomer: true, partyId: id, name: e.party.partyName, radius: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.party.partyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
            Text('${_rs(e.total)} • $reason',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
            Text(_hasPhone(e) ? _contactText(e) : Loc.t('No phone number', 'فون نمبر نہیں'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: _p.textMuted)),
          ]),
        ),
        if (actions) ...[
          if (_hasPhone(e)) ...[
            _round(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(e)),
            const SizedBox(width: 8),
            _round(Icons.phone, _p.flatPurpleFg, _p.flatPurpleBg, () => _call(e)),
            const SizedBox(width: 8),
          ],
          _round(Icons.check, _p.flatTealFg, _p.flatTealBg, () => _received(e)),
        ],
      ]),
    );
  }

  Widget _card({required Widget child, Color? border}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border ?? _p.border),
        ),
        child: child,
      );

  Widget _progressCard(AutopilotQueue q) {
    final planned = q.planned;
    final doneN = q.done.length;
    final frac = planned == 0 ? 1.0 : doneN / planned;
    final collected = _day.collectedToday;
    return _card(
      border: q.isClear ? _p.flatTealFg.withOpacity(0.5) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          planned == 0
              ? Loc.t('Nobody needs a reminder today', 'آج کسی کو یاد دہانی کی ضرورت نہیں')
              : q.isClear
                  ? Loc.t('All reminders done for today', 'آج کی سب یاد دہانیاں ہو گئیں')
                  : Loc.t('$doneN of $planned reminders done today', 'آج $planned میں سے $doneN یاد دہانیاں ہو گئیں'),
          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: frac.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: _p.border,
            valueColor: AlwaysStoppedAnimation<Color>(q.isClear ? _p.flatTealFg : _p.flatAmberFg),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: Text(
              Loc.t('Collected today', 'آج وصول ہوا'),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.textMuted),
            ),
          ),
          Text(
            '${_rs(collected)}${_day.paymentsToday > 0 ? '  (${_day.paymentsToday})' : ''}',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: collected > 0 ? _p.flatTealFg : _p.textMuted),
          ),
        ]),
        if (q.todo.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: Text(
                Loc.t('Still to remind', 'یاد دہانی باقی'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _p.textMuted),
              ),
            ),
            Text('${q.todo.length} • ${_rs(q.todoAmount)}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _p.red)),
          ]),
        ],
      ]),
    );
  }

  Widget _nextButton(AutopilotQueue q) {
    final next = q.todo.where(_hasPhone).toList();
    if (next.isEmpty) return const SizedBox.shrink();
    final e = next.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: _busy ? null : () => _whatsApp(e),
          icon: const Icon(Icons.send),
          label: Text(
            Loc.t('Send next: ${e.party.partyName} (${_rs(e.total)})', 'اگلا بھیجیں: ${e.party.partyName} (${_rs(e.total)})'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
        child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
      );

  @override
  Widget build(BuildContext context) {
    final q = _day.queue;
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(backgroundColor: _p.navy, foregroundColor: Colors.white, elevation: 0),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(showSpinner: false),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 30),
            children: [
              PremiumHeader(
                title: Loc.t('Collection Autopilot', 'وصولی آٹو پائلٹ'),
                subtitle: Loc.t('Who to remind today — one tap each', 'آج کس کو یاد دلانا ہے — ایک ٹیپ میں'),
              ),
              if (_loading)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
              else ...[
                _progressCard(q),
                _nextButton(q),
                if (q.todo.isNotEmpty) ...[
                  _sectionTitle(Loc.t('TO REMIND TODAY (${q.todo.length})', 'آج یاد دلانا ہے (${q.todo.length})')),
                  _card(child: Column(children: [for (final e in q.todo) _row(e)])),
                ],
                if (q.done.isNotEmpty) ...[
                  _sectionTitle(Loc.t('DONE TODAY (${q.done.length})', 'آج ہو چکا (${q.done.length})')),
                  _card(child: Column(children: [for (final e in q.done) _row(e, actions: false)])),
                ],
                if (q.waiting.isNotEmpty) ...[
                  _sectionTitle(Loc.t('WAITING (${q.waiting.length})', 'انتظار میں (${q.waiting.length})')),
                  _card(
                    child: Column(children: [
                      for (final e in q.waiting)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            Expanded(
                              child: Text(e.party.partyName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _p.textDark)),
                            ),
                            Text(
                              e.state.dispute
                                  ? Loc.t('Dispute', 'تنازع')
                                  : Loc.t('again in ${e.daysUntilTouch} day(s)', '${e.daysUntilTouch} دن بعد پھر'),
                              style: TextStyle(fontSize: 11.5, color: _p.textMuted),
                            ),
                            const SizedBox(width: 10),
                            Text(_rs(e.total),
                                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
                          ]),
                        ),
                    ]),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
