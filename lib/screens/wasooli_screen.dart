import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart' show DueRemindersRepository;
import '../db/wasooli_repository.dart';
import '../models/due_followup.dart';
import '../models/wasooli_plan.dart';
import '../services/collection_actions.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/party_avatar.dart';
import 'followup_sheets.dart' show showFollowUpTimeline;
import 'wasooli_sheets.dart';

/// Wasooli ek page: "Aaj kis se lena hai".
///  * Upar: Aaj wasool / Late ka jor.
///  * Filter: Sab | Late | Aaj | Is hafta.
///  * Har party: naam, baqi, EK tareekh (laal Late / narangi Aaj / hara Aage), 3 button.
/// Party par tap => [WasooliPartyScreen] (abhi ka wada numayan, purane wade kati hui line mein).

const _lateFg = Color(0xFFB91C1C), _lateBg = Color(0xFFFDE8E8);
const _todayFg = Color(0xFF9A3412), _todayBg = Color(0xFFFFEDD5);
const _laterFg = Color(0xFF166534), _laterBg = Color(0xFFDCFCE7);
const _green = Color(0xFF15803D);
const _blue = Color(0xFF1D4ED8);
const _muted = Color(0xFF4B5563);

(Color, Color) urgencyColors(WasooliUrgency u) => switch (u) {
      WasooliUrgency.late => (_lateFg, _lateBg),
      WasooliUrgency.today => (_todayFg, _todayBg),
      WasooliUrgency.later => (_laterFg, _laterBg),
    };

String kindLabel(WasooliDateKind k) => switch (k) {
      WasooliDateKind.promise => Loc.t('promise', 'وعدہ'),
      WasooliDateKind.qist => Loc.t('installment', 'قسط'),
      WasooliDateKind.payDay => Loc.t('payment day', 'ادائیگی کا دن'),
      WasooliDateKind.bill => Loc.t('bill due', 'بل'),
      WasooliDateKind.followUp => Loc.t('follow-up', 'رابطہ'),
      WasooliDateKind.dispute => Loc.t('dispute', 'جھگڑا'),
    };

/// Chip ki ibarat: "11 days late", "Today", "20 Nov · in 4 days".
String urgencyChip(WasooliRow r) {
  final d = r.days;
  switch (r.urgency) {
    case WasooliUrgency.late:
      return Loc.t(d == 1 ? '1 day late' : '$d days late', 'لیٹ · $d دن');
    case WasooliUrgency.today:
      return Loc.t('Today', 'آج');
    case WasooliUrgency.later:
      return Loc.t(
        '${wasooliDate(r.date)} · ${d == 1 ? 'tomorrow' : 'in $d days'}',
        'آگے · ${wasooliDate(r.date)} (${d == 1 ? 'کل' : '$d دن'})',
      );
  }
}

/// Chip ke saath chhoti baat: "bill due 6 Nov", "promise Rs 5,000", "installment Rs 3,000".
String urgencyNote(WasooliRow r) {
  final amt = r.amount > 0 ? ' ${wasooliRs(r.amount)}' : '';
  if (r.kind == WasooliDateKind.dispute) return Loc.t('dispute — talk it through', 'جھگڑا');
  if (r.urgency == WasooliUrgency.late) {
    return Loc.t('${kindLabel(r.kind)}$amt was ${wasooliDate(r.date)}', '${kindLabel(r.kind)}$amt ${wasooliDate(r.date)} تھا');
  }
  return '${kindLabel(r.kind)}$amt';
}

class WasooliScreen extends StatefulWidget {
  final WasooliFilter initialFilter;
  const WasooliScreen({super.key, this.initialFilter = WasooliFilter.all});

  @override
  State<WasooliScreen> createState() => _WasooliScreenState();
}

class _WasooliScreenState extends State<WasooliScreen> with WidgetsBindingObserver {
  WasooliDay? _day;
  late WasooliFilter _filter = widget.initialFilter;
  final _search = TextEditingController();
  String _q = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  // Call / WhatsApp se wapas aane par list taaza.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final d = await WasooliRepository.instance.load();
      if (mounted) setState(() {
        _day = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _call(WasooliRow r) async {
    final phone = r.party.partyPhone.trim();
    if (phone.isEmpty) {
      _toast(Loc.t('No phone number for this party', 'اس پارٹی کا فون نمبر نہیں'));
    } else {
      try {
        final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
        if (!ok) throw Exception();
      } catch (_) {
        _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
      }
    }
    if (!mounted) return;
    // Call ke baad (ya bina number) seedha ek sawal: kya hua?
    await showRabtaSheet(context, row: r, method: FollowUpMethod.call);
    await _load();
  }

  Future<void> _whatsApp(WasooliRow r) async {
    await sendReminderTo(context, r.party);
    await _load();
  }

  Future<void> _paid(WasooliRow r) async {
    final id = r.party.partyId;
    if (id == null) return;
    await receiveFromParty(context, partyId: id, partyName: r.party.partyName, due: r.total);
    await _load();
  }

  Future<void> _open(WasooliRow r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WasooliPartyScreen(row: r)));
    await _load();
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final day = _day;
    if (day == null) {
      return Center(
        child: _error == null ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    final rows = [
      for (final r in day.rows)
        if (wasooliMatches(_filter, r) && (_q.isEmpty || r.party.partyName.toLowerCase().contains(_q) || r.party.partyPhone.contains(_q)))
          r,
    ];
    final s = day.summary;
    final counts = {
      for (final f in WasooliFilter.values) f: day.rows.where((r) => wasooliMatches(f, r)).length,
    };
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              color: p.navy,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(child: _tile(Loc.t('Collect today', 'آج وصول'), wasooliRs(s.todayTotal), Loc.t('${s.todayCount} parties', '${s.todayCount} پارٹی'), const Color(0xFFDBE2FF))),
                    const SizedBox(width: 10),
                    Expanded(child: _tile(Loc.t('Late', 'لیٹ'), wasooliRs(s.lateTotal), Loc.t('${s.lateCount} parties', '${s.lateCount} پارٹی'), const Color(0xFFFFD4D4))),
                  ]),
                  if (day.collectedToday > 0) ...[
                    const SizedBox(height: 8),
                    Text('${Loc.t('Received today', 'آج ملا')}: ${wasooliRs(day.collectedToday)}',
                        style: const TextStyle(color: Color(0xFFBBF7D0), fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _filterChip(WasooliFilter.all, Loc.t('All', 'سب'), p.navy, counts),
                  _filterChip(WasooliFilter.late, Loc.t('Late', 'لیٹ'), _lateFg, counts),
                  _filterChip(WasooliFilter.today, Loc.t('Today', 'آج'), _todayFg, counts),
                  _filterChip(WasooliFilter.week, Loc.t('This week', 'اس ہفتے'), const Color(0xFF374151), counts),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: Loc.t('Party name / phone', 'پارٹی کا نام / فون'),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          if (rows.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(Loc.t('No parties in this list', 'اس فہرست میں کوئی پارٹی نہیں'),
                      style: const TextStyle(color: _muted, fontSize: 15)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _card(rows[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(String label, String value, String sub, Color tint) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: tint)),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            Text(sub, style: TextStyle(fontSize: 12, color: tint)),
          ],
        ),
      );

  Widget _filterChip(WasooliFilter f, String label, Color color, Map<WasooliFilter, int> counts) {
    final on = _filter == f;
    final n = counts[f] ?? 0;
    return ChoiceChip(
      selected: on,
      showCheckmark: false,
      label: Text(f == WasooliFilter.all ? label : '$label $n'),
      labelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: on ? Colors.white : color),
      selectedColor: color,
      backgroundColor: Colors.white,
      side: BorderSide(color: on ? color : const Color(0xFFD1D5DB)),
      shape: const StadiumBorder(),
      onSelected: (_) => setState(() => _filter = f),
    );
  }

  Widget _card(WasooliRow r) {
    final (fg, bg) = urgencyColors(r.urgency);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(r),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  PartyAvatar(isCustomer: true, partyId: r.party.partyId, name: r.party.partyName, radius: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(r.party.partyName,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Text(wasooliRs(r.total), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                    child: Text(urgencyChip(r), style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  Text(urgencyNote(r), style: const TextStyle(fontSize: 13, color: _muted)),
                  if (r.brokenCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: _todayBg, borderRadius: BorderRadius.circular(8)),
                      child: Text(Loc.t('broken ${r.brokenCount}x', '${r.brokenCount} دفعہ ٹوٹا'),
                          style: const TextStyle(color: Color(0xFF7C2D12), fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  if (r.touchedToday)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle, size: 15, color: _green),
                      const SizedBox(width: 3),
                      Text(Loc.t('contacted today', 'آج بات ہوئی'), style: const TextStyle(fontSize: 12, color: _green)),
                    ]),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _outline(Loc.t('Call', 'کال'), Icons.call_outlined, () => _call(r))),
                const SizedBox(width: 8),
                Expanded(child: _outline(Loc.t('WhatsApp', 'واٹس ایپ'), Icons.chat_outlined, () => _whatsApp(r))),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _green,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => _paid(r),
                      child: Text(Loc.t('Received', 'پیسے ملے'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _outline(String label, IconData icon, VoidCallback onTap) => SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF111827),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            side: const BorderSide(color: Color(0xFFD1D5DB)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
}

/// Ek party: sab se upar "Abhi ka wada" (ya agli tareekh) bari dabbi mein; purane wade kati hui line mein.
class WasooliPartyScreen extends StatefulWidget {
  final WasooliRow row;
  const WasooliPartyScreen({super.key, required this.row});

  @override
  State<WasooliPartyScreen> createState() => _WasooliPartyScreenState();
}

class _WasooliPartyScreenState extends State<WasooliPartyScreen> {
  late WasooliRow _r = widget.row;
  bool _gone = false; // poora ada => list se nikal gayi

  Future<void> _reload() async {
    final id = _r.party.partyId;
    if (id == null) return;
    final fresh = await WasooliRepository.instance.row(id);
    if (!mounted) return;
    setState(() {
      if (fresh == null) {
        _gone = true;
      } else {
        _r = fresh;
      }
    });
  }

  Future<void> _call() async {
    final phone = _r.party.partyPhone.trim();
    if (phone.isNotEmpty) {
      try {
        await launchUrl(Uri(scheme: 'tel', path: phone));
      } catch (_) {}
    }
    if (!mounted) return;
    await showRabtaSheet(context, row: _r, method: FollowUpMethod.call);
    await _reload();
  }

  Future<void> _whatsApp() async {
    await sendReminderTo(context, _r.party);
    await _reload();
  }

  Future<void> _paid() async {
    final id = _r.party.partyId;
    if (id == null) return;
    await receiveFromParty(context, partyId: id, partyName: _r.party.partyName, due: _r.total);
    await _reload();
  }

  Future<void> _rabta() async {
    await showRabtaSheet(context, row: _r, method: FollowUpMethod.note);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final r = _r;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        title: Text(r.party.partyName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          if (r.party.partyId != null)
            IconButton(
              tooltip: Loc.t('Full history', 'پوری تاریخ'),
              icon: const Icon(Icons.history),
              onPressed: () async {
                await showFollowUpTimeline(context, partyId: r.party.partyId!, partyName: r.party.partyName, totalDue: r.total);
                await _reload();
              },
            ),
        ],
      ),
      body: _gone
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(Loc.t('All clear — nothing due', 'پورا حساب صاف — کچھ باقی نہیں'),
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _green)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(children: [
                  PartyAvatar(isCustomer: true, partyId: r.party.partyId, name: r.party.partyName, radius: 32),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(Loc.t('Due', 'باقی'), style: const TextStyle(fontSize: 13, color: _muted)),
                      Text(wasooliRs(r.total), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                _mainCard(r),
                const SizedBox(height: 12),
                _termRow(r),
                const SizedBox(height: 12),
                _history(r),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: _btn(Loc.t('Call', 'کال'), _call)),
                  const SizedBox(width: 10),
                  Expanded(child: _btn(Loc.t('WhatsApp', 'واٹس ایپ'), _whatsApp)),
                ]),
                const SizedBox(height: 10),
                _btn(Loc.t('Log contact (promise / no answer)', 'رابطہ لکھیں (وعدہ / نہیں ملا)'), _rabta),
                const SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _green, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: _paid,
                    child: Text(Loc.t('Received', 'پیسے ملے'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) => SizedBox(
        height: 52,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF111827),
            backgroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFFD1D5DB)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: onTap,
          child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ),
      );

  /// Customer ki udhaar muddat (din). Isi se naye udhaar bill par due date khud lagti hai.
  Widget _termRow(WasooliRow r) {
    final d = r.dueDays;
    final label = d > 0
        ? Loc.t('Pays in ~$d days', '~$d دن میں ادائیگی')
        : Loc.t('No payment term set', 'ادائیگی مدت مقرر نہیں');
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _setTerm,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            const Icon(Icons.event_repeat_outlined, size: 20, color: _muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(Loc.t('Payment term', 'ادائیگی کی مدت'),
                    style: const TextStyle(fontSize: 12, color: _muted)),
                Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ]),
            ),
            Text(Loc.t('Change', 'تبدیل'), style: const TextStyle(fontSize: 14, color: _blue, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  /// Exact din likhwao (short time ke liye, jaise 2-3 din).
  Future<int?> _askDays() async {
    final ctrl = TextEditingController(text: _r.dueDays > 0 ? _r.dueDays.toString() : '');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('How many days?', 'کتنے دن؟')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: Loc.t('e.g. 3', 'مثلاً 3'), suffixText: Loc.t('days', 'دن')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (int.tryParse(ctrl.text.trim()) ?? 0).clamp(0, 365)),
            child: Text(Loc.t('OK', 'ٹھیک')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }

  /// Tareekh chuno; term = aaj se us din tak ke din (kam se kam 1).
  Future<int?> _askDateAsDays() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: today.add(const Duration(days: 7)),
      firstDate: today.add(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
      helpText: Loc.t('When will they usually pay?', 'عموماً کب ادائیگی کرے گا؟'),
    );
    if (picked == null) return null;
    return DateTime(picked.year, picked.month, picked.day).difference(today).inDays.clamp(1, 365);
  }

  Future<void> _setTerm() async {
    final id = _r.party.partyId;
    if (id == null) return;
    // Short (2-7 din) se le kar 3 month tak; ya exact din likho; ya date pick karo (aaj se din gin lega).
    final presets = <int>[3, 5, 7, 10, 15, 30, 45, 60, 90];
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(Loc.t('After how long does this party pay?', 'یہ پارٹی کتنے دن بعد ادائیگی کرتی ہے؟'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(Loc.t('New credit bills get this due date automatically.', 'نئے ادھار بل پر یہی مدت خود لگے گی۔'),
                style: const TextStyle(fontSize: 13, color: _muted)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in presets)
                ChoiceChip(
                  selected: _r.dueDays == d,
                  label: Text(d % 30 == 0 ? Loc.t('${d ~/ 30} month${d == 30 ? '' : 's'}', '${d ~/ 30} ماہ') : Loc.t('$d days', '$d دن')),
                  onSelected: (_) => Navigator.pop(ctx, d),
                ),
              ChoiceChip(
                selected: _r.dueDays == 0,
                label: Text(Loc.t('No term', 'کوئی مدت نہیں')),
                onSelected: (_) => Navigator.pop(ctx, 0),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(Loc.t('Exact days', 'دن لکھیں')),
                  onPressed: () async {
                    final d = await _askDays();
                    if (d != null && ctx.mounted) Navigator.pop(ctx, d);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(Loc.t('Pick a date', 'تاریخ چنیں')),
                  onPressed: () async {
                    final d = await _askDateAsDays();
                    if (d != null && ctx.mounted) Navigator.pop(ctx, d);
                  },
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    if (chosen == null) return;
    final repo = DueRemindersRepository.instance;
    final ok = await repo.setCustomerDueDays(id, chosen);
    if (!mounted) return;
    if (!ok) return;

    // Purane baqi bills par purani (chhoti) due date lagi hoti hai — poochho ke un par bhi nayi muddat laga dein,
    // warna wo late dikhte rehte hain.
    final open = await repo.openBillCount(id);
    if (mounted && open > 0 && chosen > 0) {
      final apply = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('Apply to current bills too?', 'موجودہ بلوں پر بھی لگائیں؟')),
          content: Text(Loc.t(
            'This party has $open unpaid bill(s). Set their due date to bill date + $chosen days as well?\n\n'
                'Otherwise only new bills use the term, and old bills keep showing late.',
            'اس پارٹی کے $open بل باقی ہیں۔ ان کی ڈیو ڈیٹ بھی بل کی تاریخ + $chosen دن کر دیں؟\n\n'
                'ورنہ صرف نئے بلوں پر مدت لگے گی اور پرانے بل لیٹ دکھتے رہیں گے۔',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Only new bills', 'صرف نئے بل'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Yes, update', 'ہاں، بدلیں'))),
          ],
        ),
      );
      if (apply == true) await repo.applyTermToOpenBills(id, chosen);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(chosen > 0
          ? Loc.t('Payment term set: $chosen days', 'ادائیگی مدت: $chosen دن')
          : Loc.t('Payment term removed', 'ادائیگی مدت ہٹا دی')),
    ));
    await _reload();
  }

  /// Sab se ahem dabbi: wada ho to "ABHI KA WADA", warna "AGLI TAREEKH".
  Widget _mainCard(WasooliRow r) {
    final (fg, _) = urgencyColors(r.urgency);
    final isPromise = r.hasPromise;
    final border = isPromise && r.urgency == WasooliUrgency.later ? _blue : fg;
    final title = isPromise
        ? (r.urgency == WasooliUrgency.late ? Loc.t('PROMISE BROKEN', 'وعدہ ٹوٹا') : Loc.t('CURRENT PROMISE', 'ابھی کا وعدہ'))
        : Loc.t('NEXT DATE', 'اگلی تاریخ');
    final when = switch (r.urgency) {
      WasooliUrgency.late => Loc.t('${r.days} days late', '${r.days} دن گزرے'),
      WasooliUrgency.today => Loc.t('today', 'آج'),
      WasooliUrgency.later => r.days == 1 ? Loc.t('tomorrow', 'کل') : Loc.t('in ${r.days} days', '${r.days} دن باقی'),
    };
    final promise = r.state.promise;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: border, letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 10,
            children: [
              Text(wasooliDate(r.date), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(when, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: border)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isPromise
                ? '${r.amount > 0 ? wasooliRs(r.amount) : Loc.t('Full amount', 'پورا باقی')} ${Loc.t('promised', 'دینے کا وعدہ')}'
                    '${promise != null ? ' · ${Loc.t('made on ${wasooliDate(promise.createdAt)}', '${wasooliDate(promise.createdAt)} کو کیا')}' : ''}'
                : '${kindLabel(r.kind)}${r.amount > 0 ? ' · ${wasooliRs(r.amount)}' : ''}',
            style: const TextStyle(fontSize: 15, color: Color(0xFF374151)),
          ),
          if (isPromise && r.urgency == WasooliUrgency.late) ...[
            const SizedBox(height: 6),
            Text(Loc.t('Contact them and get a new promise', 'رابطہ کر کے نیا وعدہ لیں'),
                style: const TextStyle(fontSize: 13, color: _lateFg, fontWeight: FontWeight.w600)),
          ],
          if (r.brokenCount > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: _todayBg, borderRadius: BorderRadius.circular(8)),
              child: Text(Loc.t('Promise broken ${r.brokenCount}x', '${r.brokenCount} دفعہ وعدہ ٹوٹا'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF7C2D12), fontWeight: FontWeight.w700)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _history(WasooliRow r) {
    final lines = <Widget>[];
    for (final e in r.entries.take(8)) {
      final isPastPromise = r.pastPromises.contains(e);
      final isNow = identical(e, r.state.promise);
      String text;
      String tag = '';
      Color tagColor = _muted;
      var struck = false;
      if (e.promiseDate > 0 && e.outcome != FollowUpOutcome.sent) {
        text = '${Loc.t('Promise', 'وعدہ')} ${wasooliDate(e.promiseDate)}${e.outcome == FollowUpOutcome.promised && e.amount > 0 ? ' · ${wasooliRs(e.amount)}' : ''}';
        if (e.outcome == FollowUpOutcome.partial && e.amount > 0) text = '${wasooliRs(e.amount)} ${Loc.t('received', 'ملا')} · $text';
        if (isNow) {
          tag = Loc.t('current', 'ابھی');
          tagColor = _blue;
        } else if (isPastPromise) {
          struck = true;
          tag = e.promiseDate < r.today ? Loc.t('old', 'پرانا') : Loc.t('replaced', 'بدلا');
        }
      } else if (e.outcome == FollowUpOutcome.paid || e.outcome == FollowUpOutcome.partial) {
        text = '${wasooliDate(e.createdAt)} · ${e.amount > 0 ? wasooliRs(e.amount) : ''} ${Loc.t('received', 'ملا')}';
        tag = Loc.t('payment', 'پیسے');
        tagColor = _green;
      } else if (e.outcome == FollowUpOutcome.noAnswer) {
        text = '${wasooliDate(e.createdAt)} · ${Loc.t('No answer', 'نہیں ملا')}';
      } else if (e.outcome == FollowUpOutcome.sent) {
        text = '${wasooliDate(e.createdAt)} · ${e.method == FollowUpMethod.whatsapp ? 'WhatsApp' : Loc.t('Call', 'کال')}';
      } else {
        text = '${wasooliDate(e.createdAt)} · ${e.note.isEmpty ? e.outcome : e.note}';
      }
      lines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: 14,
                  color: struck ? const Color(0xFF6B7280) : const Color(0xFF374151),
                  decoration: struck ? TextDecoration.lineThrough : null,
                )),
          ),
          if (tag.isNotEmpty) Text(tag, style: TextStyle(fontSize: 13, color: tagColor, fontWeight: FontWeight.w600)),
        ]),
      ));
    }
    for (final b in r.party.bills.where((b) => !b.isAdvance).take(5)) {
      final label = b.isBalance
          ? Loc.t('Previous balance', 'پچھلا باقی')
          : '${Loc.t('Bill', 'بل')} ${wasooliDate(b.createdAt)}${b.dueDate > 0 ? ' · due ${wasooliDate(b.dueDate)}' : ''}';
      lines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)))),
          Text(wasooliRs(b.due), style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
        ]),
      ));
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(Loc.t('History', 'پچھلا حساب'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _muted)),
          const SizedBox(height: 6),
          ...lines,
        ],
      ),
    );
  }
}
