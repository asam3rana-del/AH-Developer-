import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_followup_repository.dart';
import '../db/due_reminders_repository.dart';
import '../models/due_followup.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';
import '../widgets/party_avatar.dart';
import '../widgets/permission_guard.dart';
import '../services/collection_actions.dart';
import 'followup_sheets.dart';

/// Mirrors DueRemindersActivity.kt.
///
/// Har party ka EK card (us ke saare baqi bills jama, ek hi reminder) + upar search box (naam / phone / invoice).
/// Ek bill wali party: card tap => date picker; kai bills: card tap => bills ki list (har bill ki date alag badal sakti hai).
/// Pehle har credit / partially-paid bill ek jagah tha, due date ke hisaab se. Card tap => date picker
/// (checkout mein date field nahi chahiye). Date wale pehle; "date nahi" wale bhi dikhte hain (gray)
/// taake baqi paisa kabhi chhupe nahi. Call + WhatsApp reminder (wa.me) party ke phone par.
///
/// Role: admin + manager. Kotlin mein ye Reports ke andar hai (ReportsActivity role check karti hai);
/// RoleGuard screen ke andar bhi hai. Cashier ko sirf Party Dashboard ka Overdue badge / Party
/// Transaction ka Overdue stat dikhta hai.
///
/// Farq (Kotlin se): Material icons; WhatsApp `url_launcher` se (externalApplication).
class DueRemindersScreen extends StatelessWidget {
  /// Home card ke tile (Collect today / Late / Promise broken) isi filter ke sath yahan kholte hain.
  final FollowUpFilter initialFilter;
  const DueRemindersScreen({super.key, this.initialFilter = FollowUpFilter.all});

  @override
  Widget build(BuildContext context) =>
      PermissionGuard(permission: 'due_reminders', child: _DueRemindersBody(initialFilter: initialFilter));
}

class _DueRemindersBody extends StatefulWidget {
  final FollowUpFilter initialFilter;
  const _DueRemindersBody({this.initialFilter = FollowUpFilter.all});

  @override
  State<_DueRemindersBody> createState() => _DueRemindersBodyState();
}

class _DueRemindersBodyState extends State<_DueRemindersBody> with WidgetsBindingObserver {
  final _repo = DueRemindersRepository.instance;
  bool _purchases = false;
  bool _loading = true;
  List<DueBill> _bills = const [];
  Map<int, int> _defaultDays = const {}; // customerId => default due-days (sirf Sales tab)
  final _search = TextEditingController();
  String _query = '';

  // Follow-up log (sirf Sales tab): party id => entries (nayi pehle), filter, mahine ka khulasa.
  Map<int, List<DueFollowUp>> _followUps = const {};
  FollowUpMonthStats? _monthStats;
  FollowUpFilter _filter = FollowUpFilter.all;

  // WhatsApp / call ke baad app wapas aane par "kya hua?" poochne ke liye (khud ban'ne wali entry ki id).
  int? _pendingFollowUpId;
  bool _askingResult = false;

  final _dateFmt = DateFormat('d MMM yyyy');

  AppPalette get _p => ThemeManager.palette;
  Color get _primary => _p.flatPurpleFg;
  Color get _amber => _p.flatAmberFg;
  Color get _red => _p.red;
  Color get _teal => _p.flatTealFg;

  String _rs(double v) => 'Rs ${v.round()}';

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  // Kotlin onResume: kahin aur payment hone se bill list se nikal sakti hai.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(showSpinner: false);
      _askPendingResult();
    }
  }

  /// WhatsApp / dialer se wapas aane par us entry ka nateeja poochho (sheet band karne par entry "sent" hi rehti hai).
  Future<void> _askPendingResult() async {
    final id = _pendingFollowUpId;
    if (id == null || _askingResult || !mounted) return;
    _pendingFollowUpId = null;
    _askingResult = true;
    try {
      final e = await DueFollowUpRepository.instance.byId(id);
      if (e == null || !mounted) return;
      double due = 0;
      for (final g in groupDueByParty(_bills)) {
        if (g.partyId == e.partyId && !g.isAdvance) due = g.total;
      }
      await showFollowUpSheet(context,
          partyId: e.partyId, partyName: e.partyName, existing: e, method: e.method, suggestedAmount: due);
      if (mounted) await _load(showSpinner: false);
    } finally {
      _askingResult = false;
    }
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    final list = _purchases ? await _repo.duePurchases() : await _repo.dueSales();
    final defaults = _purchases ? const <int, int>{} : await _repo.customerDueDaysMap();
    // Follow-up data fail ho jaye to bhi list dikhe (follow-up sirf upar ki madad hai).
    var followUps = const <int, List<DueFollowUp>>{};
    FollowUpMonthStats? stats;
    if (!_purchases) {
      try {
        followUps = await DueFollowUpRepository.instance.allByParty(backfillSync: true);
        final n = DateTime.now();
        stats = await DueFollowUpRepository.instance.monthStats(n.year, n.month);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _bills = list;
      _defaultDays = defaults;
      _followUps = followUps;
      _monthStats = stats;
      _loading = false;
    });
  }

  /// tab: 0 = Sales, 1 = Purchases.
  void _setTab(int tab) {
    final purchases = tab == 1;
    if (_purchases == purchases) return;
    _purchases = purchases;
    _filter = FollowUpFilter.all;
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- actions -----------------------------------------------------------

  Future<void> _pickDate(DueBill b) async {
    if (b.isBalance) return; // bill nahi, ledger balance — date store karne ki jagah nahi
    final initial = b.dueDate > 0 ? DateTime.fromMillisecondsSinceEpoch(b.dueDate) : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    final ok = await _repo.setDueDate(
      isSale: b.isSale,
      id: b.id,
      dueDateMillis: DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    if (!ok) _toast(Loc.t('This bill no longer exists', 'یہ بل اب موجود نہیں'));
    await _load(showSpinner: false);
  }

  /// Party ke saare baqi bills ki date ek saath (quick chips) + customer ki default muddat (din) badalna.
  Future<void> _bulkDates(DueParty g) async {
    final partyId = g.partyId;
    if (partyId == null) return;
    var days = _purchases ? 0 : (_defaultDays[partyId] ?? 0);
    var onlyUndated = g.undatedCount > 0 && g.undatedCount < g.billCount;
    final daysCtrl = TextEditingController(text: days > 0 ? '$days' : '');
    // Ek action chuna jata hai => sheet band => neeche apply hota hai.
    final action = await showModalBottomSheet<({int? fixedFromNow, int? pickedMillis, bool byBillDate, bool pick})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget chip(String label, VoidCallback onTap) => ActionChip(
                label: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _primary)),
                backgroundColor: _p.flatPurpleBg,
                side: BorderSide.none,
                onPressed: onTap,
              );
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(g.partyName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text(
                      '${g.billCount} ${Loc.t('bills', 'بل')} • ${_rs(g.total)} ${Loc.t('due', 'واجب الادا')}',
                      style: TextStyle(fontSize: 12, color: _p.textMuted)),
                  const SizedBox(height: 14),
                  Text(Loc.t('Set due date for all bills', 'سب بلوں کی تاریخ طے کریں'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final n in const [7, 15, 30])
                      chip(Loc.t('Today + $n days', 'آج + $n دن'),
                          () => Navigator.pop(ctx, (fixedFromNow: n, pickedMillis: null, byBillDate: false, pick: false))),
                    chip(Loc.t('Pick a date…', 'تاریخ چنیں…'),
                        () => Navigator.pop(ctx, (fixedFromNow: null, pickedMillis: null, byBillDate: false, pick: true))),
                    if (days > 0)
                      chip(Loc.t('Bill date + $days days', 'بل کی تاریخ + $days دن'),
                          () => Navigator.pop(ctx, (fixedFromNow: null, pickedMillis: null, byBillDate: true, pick: false))),
                  ]),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: onlyUndated,
                    onChanged: g.undatedCount == 0 ? null : (v) => setLocal(() => onlyUndated = v),
                    title: Text(Loc.t('Only bills without a date', 'صرف وہ بل جن پر تاریخ نہیں'),
                        style: TextStyle(fontSize: 13, color: _p.textDark)),
                  ),
                  if (!_purchases) ...[
                    const Divider(height: 22),
                    Text(Loc.t('Default payment term (days)', 'ڈیفالٹ ادائیگی کی مدت (دن)'),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _p.textDark)),
                    const SizedBox(height: 2),
                    Text(Loc.t('New credit bills of this customer get date = bill date + these days.',
                        'اس کسٹمر کے نئے ادھار بل کی تاریخ = بل کی تاریخ + یہ دن۔'),
                        style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: daysCtrl,
                          keyboardType: TextInputType.number,
                          style: TextStyle(color: _p.textDark),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: Loc.t('0 = not set', '0 = طے نہیں'),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: () async {
                          final v = clampDueDays(int.tryParse(daysCtrl.text.trim()) ?? 0);
                          final ok = await _repo.setCustomerDueDays(partyId, v);
                          if (!ctx.mounted) return;
                          setLocal(() => days = ok ? v : days);
                          if (!mounted) return;
                          _toast(ok
                              ? Loc.t('Default term saved: $v days', 'ڈیفالٹ مدت محفوظ: $v دن')
                              : Loc.t('Customer not found', 'کسٹمر نہیں ملا'));
                          await _load(showSpinner: false);
                        },
                        child: Text(Loc.t('Save term', 'مدت محفوظ کریں')),
                      ),
                    ]),
                  ],
                ]),
              ),
            ),
          );
        },
      ),
    );
    daysCtrl.dispose();
    if (action == null || !mounted) return;

    int? millis;
    int? byDays;
    if (action.pick) {
      final picked = await showDatePicker(
        context: context,
        initialDate: g.earliestDue > 0 ? DateTime.fromMillisecondsSinceEpoch(g.earliestDue) : DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null || !mounted) return;
      millis = DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch;
    } else if (action.byBillDate) {
      byDays = days;
    } else {
      final n = DateTime.now();
      millis = DateTime(n.year, n.month, n.day + action.fixedFromNow!).millisecondsSinceEpoch;
    }
    final changed = await _repo.setDueDateForParty(
      isSale: !_purchases,
      partyId: partyId,
      dueDateMillis: millis,
      days: byDays,
      onlyUndated: onlyUndated,
    );
    if (!mounted) return;
    _toast(Loc.t('Date set on $changed bill(s)', '$changed بل پر تاریخ طے ہو گئی'));
    await _load(showSpinner: false);
  }

  FollowUpState _stateOf(DueParty g) {
    final id = g.partyId;
    if (_purchases || id == null || g.isAdvance) return followUpState(const <DueFollowUp>[]);
    return followUpState(_followUps[id] ?? const <DueFollowUp>[]);
  }

  /// Aaj pehle hi WhatsApp gaya ho to dobara bhejne se pehle poochho.
  Future<bool> _confirmResend(DueParty g) async {
    final id = g.partyId;
    if (_purchases || id == null) return true;
    final list = _followUps[id] ?? const <DueFollowUp>[];
    final today = startOfDayMillis(DateTime.now().millisecondsSinceEpoch);
    final sentToday = list.any((e) => e.method == FollowUpMethod.whatsapp && e.createdAt >= today);
    if (!sentToday) return true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Already sent today', 'آج پہلے ہی بھیجا جا چکا ہے')),
        content: Text(Loc.t('${g.partyName} already got a WhatsApp reminder today. Send again?',
            '${g.partyName} کو آج پہلے ہی واٹس ایپ یاد دہانی بھیجی جا چکی ہے۔ دوبارہ بھیجیں؟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('No', 'نہیں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Send again', 'دوبارہ بھیجیں'))),
        ],
      ),
    );
    return yes == true;
  }

  /// Reminder ka matn: pehli baar wahi purana naram message; baad mein (ya wada toota ho to) shiddat badhti hai.
  Uri _reminderUri(DueParty g) {
    final id = g.partyId;
    if (_purchases || id == null) {
      final single = g.bills.length == 1 && !g.bills.first.isBalance ? g.bills.first : null;
      return single != null ? whatsAppUri(single) : whatsAppUri(g.toTotalBill());
    }
    return reminderUriFor(g, _followUps[id] ?? const <DueFollowUp>[]);
  }

  /// Bheji / ki hui koshish ki entry banao (nateeja baad mein poochha jata hai).
  Future<void> _logAttempt(DueParty g, String method) async {
    final id = g.partyId;
    if (_purchases || id == null) return;
    try {
      _pendingFollowUpId = await DueFollowUpRepository.instance
          .add(partyId: id, partyName: g.partyName, method: method, outcome: FollowUpOutcome.sent);
    } catch (_) {
      _pendingFollowUpId = null;
    }
  }

  Future<void> _whatsApp(DueParty g) async {
    if (!await _confirmResend(g)) return;
    try {
      final ok = await launchUrl(_reminderUri(g), mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
      await _logAttempt(g, FollowUpMethod.whatsapp);
    } catch (_) {
      if (mounted) _toast('WhatsApp nahi khul saka. Installed hai?');
    }
  }

  Future<void> _call(DueParty g) async {
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: g.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
      await _logAttempt(g, FollowUpMethod.call);
    } catch (_) {
      if (mounted) _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
  }

  /// Home card ke tick wala hi kaam: payment likho, phir list dobara load.
  Future<void> _receive(DueParty g) async {
    final id = g.partyId;
    if (id == null) return;
    final saved = await receiveFromParty(context, partyId: id, partyName: g.partyName, due: g.total);
    if (saved && mounted) await _load(showSpinner: false);
  }

  Future<void> _openTimeline(DueParty g) async {
    final id = g.partyId;
    if (id == null) return;
    await showFollowUpTimeline(context, partyId: id, partyName: g.partyName, totalDue: g.total);
    if (mounted) await _load(showSpinner: false);
  }

  /// Party ke saare bills ki list (har bill ki date alag badalne ke liye). Date badalne ke baad list dobara khulti hai.
  Future<void> _openBills(String key) async {
    final matches = groupDueByParty(_bills).where((g) => g.key == key);
    if (matches.isEmpty || !mounted) return;
    final g = matches.first;
    final picked = await showModalBottomSheet<DueBill>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _p.cardWhite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            children: [
              Text(g.partyName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _p.textDark)),
              const SizedBox(height: 2),
              Text('${_rs(g.total)} ${Loc.t('due', 'واجب الادا')} • ${Loc.t('Tap a bill to set its date', 'تاریخ طے کرنے کے لیے بل دبائیں')}',
                  style: TextStyle(fontSize: 12, color: _p.textMuted)),
              const SizedBox(height: 10),
              for (final b in g.bills) _billRow(ctx, b),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _pickDate(picked);
    if (mounted) await _openBills(key);
  }

  Widget _billRow(BuildContext ctx, DueBill b) {
    final (badgeText, badgeColor) = _badge(dueBucket(b.dueDate));
    final title = b.isAdvance
        ? Loc.t('Advance', 'ایڈوانس')
        : b.isBalance
            ? Loc.t('Previous balance (no bill)', 'پچھلا بقایا (بل کے بغیر)')
            : b.id;
    final dateText = b.isBalance
        ? ''
        : b.dueDate > 0
            ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(b.dueDate))
            : Loc.t('Tap to set a due date', 'تاریخ طے کرنے کے لیے دبائیں');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: b.isBalance ? null : () => Navigator.pop(ctx, b),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
              if (dateText.isNotEmpty) Text(dateText, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
            ]),
          ),
          Text(_rs(b.due), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _primary)),
          const SizedBox(width: 10),
          if (!b.isBalance)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(8)),
              child: Text(badgeText, style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
        ]),
      ),
    );
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Search ke baad jo parties bachin, summary un ki (taake kisi ek customer ka total saaf nazar aaye).
    final matched = groupDueByParty(_bills).where((g) => dueMatches(g, _query)).toList();
    final states = {for (final g in matched) g.key: _stateOf(g)};
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final filtered = _filter == FollowUpFilter.all || _purchases
        ? matched
        : matched.where((g) => partyMatchesFilter(_filter, g, states[g.key]!, nowMillis: nowMs)).toList();
    final groups = _purchases ? filtered : _orderByFollowUp(filtered, states);
    final shown = [for (final g in matched) ...g.bills];
    final summary = summarizeDue(shown);
    final overdueParties = matched.where((g) => g.hasOverdue() || g.hasStaleUndated()).length;
    // Walk-in / Cash Purchase (party nahi) Party Dashboard ke total mein nahi ginte — alag dikhate hain taake
    // "Total outstanding" Dashboard ke You'll get / You'll give se mel khaye.
    final noParty = shown.where((b) => b.partyId == null).fold<double>(0.0, (a, b) => a + b.due);
    final partyTotal = summary.totalDue - noParty;
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
                title: Loc.t('Due Date Reminders', 'ادائیگی کی یاد دہانی'),
                subtitle: _purchases
                    ? Loc.t('Purchases still owed, by due date', 'خریداری جو ابھی واجب الادا ہے')
                    : Loc.t('Credit sales still owed, by due date', 'ادھار سیلز جو ابھی واجب الادا ہیں'),
              ),
              _tabs(),
              _searchBox(),
              _summaryCard(Icons.warning_amber_rounded, Loc.t('Overdue', 'میعاد گزری'), '$overdueParties', _red),
              if (!_purchases && !_loading && _bills.isNotEmpty) ..._followUpSummary(matched, states),
              _summaryCard(Icons.account_balance_wallet_outlined, Loc.t('Total outstanding', 'کل بقایا'), _rs(partyTotal), _amber),
              if (noParty > 0.009)
                _summaryCard(
                    Icons.person_off_outlined,
                    _purchases
                        ? Loc.t('Cash purchases (no supplier) — not in Party Dashboard', 'کیش خریداری (سپلائر نہیں) — پارٹی ڈیش بورڈ میں شامل نہیں')
                        : Loc.t('Walk-in (no customer) — not in Party Dashboard', 'واک اِن (کسٹمر نہیں) — پارٹی ڈیش بورڈ میں شامل نہیں'),
                    _rs(noParty),
                    _p.textMuted),
              const SizedBox(height: 6),
              if (_loading)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
              else if (_bills.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    _purchases
                        ? Loc.t('Nothing outstanding — all purchases are paid off', 'کوئی بقایا نہیں — تمام خریداری ادا ہو چکی ہے')
                        : Loc.t('Nothing outstanding — all credit sales are paid off', 'کوئی بقایا نہیں — تمام ادھار سیلز ادا ہو چکی ہیں'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: _p.textMuted),
                  ),
                )
              else if (matched.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Text(Loc.t('No match for "${_query.trim()}"', '"${_query.trim()}" نہیں ملا'),
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _p.textMuted)),
                )
              else ...[
                if (!_purchases) _filterChips(matched, states),
                if (!_purchases && _filter != FollowUpFilter.all && groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10, left: 4),
                    child: Text(
                        '${_filterLabel(_filter)}: ${groups.length} ${Loc.t('parties', 'پارٹیاں')} • ${_rs(groups.fold<double>(0, (a, g) => a + g.total))}',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
                  ),
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 30),
                    child: Text(Loc.t('No party in this filter', 'اس فلٹر میں کوئی پارٹی نہیں'),
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _p.textMuted)),
                  ),
                for (final g in groups) _partyCard(g, states[g.key]!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Follow-up ki tarteeb: toota wada, aaj karna hai, aam, wada pe, dispute. Barabar par pehle wali tarteeb.
  List<DueParty> _orderByFollowUp(List<DueParty> list, Map<String, FollowUpState> states) {
    final idx = {for (var i = 0; i < list.length; i++) list[i].key: i};
    final out = [...list];
    out.sort((a, b) {
      final r = followUpRank(states[a.key]!).compareTo(followUpRank(states[b.key]!));
      return r != 0 ? r : idx[a.key]!.compareTo(idx[b.key]!);
    });
    return out;
  }

  String _filterLabel(FollowUpFilter f) {
    switch (f) {
      case FollowUpFilter.all:
        return Loc.t('All', 'سب');
      case FollowUpFilter.focus:
        return Loc.t("Today's collection", 'آج کی وصولی');
      case FollowUpFilter.collectToday:
        return Loc.t('Collect today', 'آج لینا ہے');
      case FollowUpFilter.late:
        return Loc.t('Late', 'لیٹ');
      case FollowUpFilter.today:
        return Loc.t('Do today', 'آج کرنا ہے');
      case FollowUpFilter.brokenPromise:
        return Loc.t('Promise broken', 'وعدہ ٹوٹا');
      case FollowUpFilter.onPromise:
        return Loc.t('On a promise', 'وعدے پر');
      case FollowUpFilter.neverContacted:
        return Loc.t('Not contacted', 'بات نہیں ہوئی');
      case FollowUpFilter.dispute:
        return Loc.t('Dispute', 'تنازع');
    }
  }

  Widget _filterChips(List<DueParty> matched, Map<String, FollowUpState> states) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    int count(FollowUpFilter f) => matched.where((g) => partyMatchesFilter(f, g, states[g.key]!, nowMillis: nowMs)).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final f in FollowUpFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f == FollowUpFilter.all ? _filterLabel(f) : '${_filterLabel(f)} (${count(f)})',
                    style: const TextStyle(fontSize: 12.5)),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ]),
      ),
    );
  }

  /// "Aaj karna hai" aur mahine ka follow-up khulasa.
  List<Widget> _followUpSummary(List<DueParty> matched, Map<String, FollowUpState> states) {
    var actionParties = 0;
    var actionAmount = 0.0;
    var broken = 0;
    for (final g in matched) {
      if (g.isAdvance || g.partyId == null) continue;
      final st = states[g.key]!;
      if (st.needsActionToday) {
        actionParties++;
        actionAmount += g.total;
      }
      if (st.promiseBroken) broken++;
    }
    final m = _monthStats;
    return [
      _summaryCard(
        Icons.today_outlined,
        Loc.t('To follow up today', 'آج فالو اپ کرنا ہے'),
        actionParties == 0 ? Loc.t('Nobody', 'کوئی نہیں') : '$actionParties • ${_rs(actionAmount)}',
        actionParties == 0 ? _teal : _red,
      ),
      if (broken > 0) _summaryCard(Icons.error_outline, Loc.t('Broken promises', 'ٹوٹے ہوئے وعدے'), '$broken', _red),
      if (m != null && m.total > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: _cardDeco(),
          child: Text(
            Loc.t(
              'This month: ${m.total} follow-ups (${m.whatsapp} WhatsApp, ${m.calls} calls) • ${m.promises} promises • '
                  '${m.paidOrPartial} payments noted${m.recorded > 0 ? ' (${_rs(m.recorded)})' : ''}',
              'اس مہینے: ${m.total} فالو اپ (${m.whatsapp} واٹس ایپ، ${m.calls} کال) • ${m.promises} وعدے • '
                  '${m.paidOrPartial} ادائیگیاں نوٹ${m.recorded > 0 ? ' (${_rs(m.recorded)})' : ''}',
            ),
            style: TextStyle(fontSize: 12, color: _p.textMuted),
          ),
        ),
    ];
  }

  /// Card par "aakhri baat / wada / agla follow-up" ki ek line + us ka rang.
  (String, Color)? _followUpLine(DueParty g, FollowUpState st) {
    if (_purchases || g.isAdvance || g.partyId == null) return null;
    final fmt = DateFormat('d MMM');
    String day(int ms) => fmt.format(DateTime.fromMillisecondsSinceEpoch(ms));
    if (st.never) return (Loc.t('No contact yet', 'ابھی تک بات نہیں ہوئی'), _p.textMuted);
    final parts = <String>[];
    final d = st.daysSinceContact(DateTime.now().millisecondsSinceEpoch) ?? 0;
    final lastMethod = followUpMethodLabel(st.last!.method);
    parts.add(d == 0
        ? Loc.t('Last: today ($lastMethod)', 'آخری بات: آج ($lastMethod)')
        : Loc.t('Last: $d d ago ($lastMethod)', 'آخری بات: $d دن پہلے ($lastMethod)'));
    var color = _p.textMuted;
    if (st.dispute) {
      parts.add(Loc.t('Dispute', 'تنازع'));
      color = _amber;
    } else if (st.promise != null) {
      final amt = st.promise!.amount > 0 ? ' ${_rs(st.promise!.amount)}' : '';
      parts.add(st.promiseBroken
          ? Loc.t('Promise broken: ${day(st.promise!.promiseDate)}$amt', 'وعدہ ٹوٹا: ${day(st.promise!.promiseDate)}$amt')
          : Loc.t('Promise: ${day(st.promise!.promiseDate)}$amt', 'وعدہ: ${day(st.promise!.promiseDate)}$amt'));
      color = st.promiseBroken ? _red : _teal;
    } else if (st.nextFollowUp > 0) {
      parts.add(Loc.t('Next: ${day(st.nextFollowUp)}', 'اگلا: ${day(st.nextFollowUp)}'));
      if (st.followUpDue) color = _red;
    }
    return (parts.join(' • '), color);
  }

  Widget _searchBox() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _search,
          style: TextStyle(color: _p.textDark),
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: Loc.t('Search name, phone or invoice', 'نام، فون یا انوائس تلاش کریں'),
            hintStyle: TextStyle(color: _p.textMuted, fontSize: 13),
            prefixIcon: Icon(Icons.search, color: _p.textMuted),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.close, color: _p.textMuted),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
            filled: true,
            fillColor: _p.cardWhite,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _p.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _p.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _primary)),
          ),
        ),
      );

  Widget _tabs() {
    Widget pill(String label, bool selected, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? _primary : _p.cardWhite,
                borderRadius: BorderRadius.circular(14),
                border: selected ? null : Border.all(color: _p.border),
              ),
              child: Text(label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: selected ? Colors.white : _p.textMuted)),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        pill(Loc.t('Sales', 'سیلز'), !_purchases, () => _setTab(0)),
        const SizedBox(width: 8),
        pill(Loc.t('Purchases', 'خریداری'), _purchases, () => _setTab(1)),
      ]),
    );
  }

  Widget _summaryCard(IconData icon, String label, String value, Color accent) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: _cardDeco(),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: accent.withOpacity(0.14), shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: _p.textMuted)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: accent)),
          ]),
        ]),
      );

  BoxDecoration _cardDeco() => BoxDecoration(
        color: _p.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _p.border),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1))],
      );

  (String, Color) _badge(DueBucket k) {
    switch (k) {
      case DueBucket.noDate:
        return (Loc.t('No date set', 'تاریخ طے نہیں'), _p.textMuted);
      case DueBucket.overdue:
        return (Loc.t('OVERDUE', 'میعاد گزر گئی'), _red);
      case DueBucket.dueToday:
        return (Loc.t('DUE TODAY', 'آج واجب الادا'), _red);
      case DueBucket.dueSoon:
        return (Loc.t('DUE SOON', 'جلد واجب الادا'), _amber);
      case DueBucket.upcoming:
        return (Loc.t('UPCOMING', 'آنے والا'), _teal);
    }
  }

  Widget _partyCard(DueParty g, FollowUpState st) {
    final multi = g.bills.length > 1;
    final one = g.bills.first;
    var (badgeText, badgeColor) = _badge(dueBucket(g.earliestDue));
    // Bill par tareekh nahi par aaj follow-up / wada hai => "No date set" ki jagah wahi dikhao jo home card kehta hai.
    if (!_purchases && !g.isAdvance && dueBucket(g.earliestDue) == DueBucket.noDate && !st.promiseBroken) {
      if (st.promiseToday) {
        (badgeText, badgeColor) = (Loc.t('PROMISE TODAY', 'آج کا وعدہ'), _amber);
      } else if (st.followUpDue) {
        (badgeText, badgeColor) = (Loc.t('FOLLOW-UP TODAY', 'آج فالو اپ'), _amber);
      }
    }
    final hasPhone = g.partyPhone.trim().isNotEmpty;
    final canRemind = !g.isAdvance; // advance wali party ko "paisa do" ka reminder nahi bhejna
    final onlyBalance = !multi && one.isBalance;

    String subtitle;
    if (g.isAdvance) {
      subtitle = g.isSale
          ? Loc.t('Customer advance (you owe them)', 'کسٹمر ایڈوانس (آپ کو دینا ہے)')
          : Loc.t('Advance paid to supplier (they owe you)', 'سپلائر کو ایڈوانس (انہیں دینا ہے)');
    } else if (onlyBalance) {
      subtitle = Loc.t('Previous balance (no bill)', 'پچھلا بقایا (بل کے بغیر)');
    } else if (multi) {
      subtitle = '${g.billCount} ${Loc.t('bills', 'بل')}${g.hasBalanceRow ? ' + ${Loc.t('previous balance', 'پچھلا بقایا')}' : ''}';
    } else {
      subtitle = one.id;
    }

    String dateLine;
    if (g.isAdvance || onlyBalance) {
      dateLine = g.isAdvance
          ? ''
          : g.isSale
              ? Loc.t('Receivable in Party Dashboard', 'پارٹی ڈیش بورڈ میں وصولی')
              : Loc.t('Payable in Party Dashboard', 'پارٹی ڈیش بورڈ میں قابل ادائیگی');
    } else if (g.earliestDue > 0) {
      final label = !multi ? Loc.t('Due: ', 'تاریخ: ') : g.hasOverdue() ? Loc.t('Oldest due: ', 'سب سے پرانی: ') : Loc.t('Next due: ', 'اگلی تاریخ: ');
      dateLine = '$label${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(g.earliestDue))}';
      if (multi && g.undatedCount > 0) dateLine += ' • ${g.undatedCount} ${Loc.t('without date', 'بغیر تاریخ')}';
    } else {
      dateLine = multi ? Loc.t('Tap to set dates', 'تاریخیں طے کرنے کے لیے دبائیں') : Loc.t('Tap to set a due date', 'تاریخ طے کرنے کے لیے دبائیں');
    }
    final defDays = g.partyId == null ? 0 : (_defaultDays[g.partyId!] ?? 0);
    if (!g.isAdvance && !onlyBalance && defDays > 0) {
      dateLine += '${dateLine.isEmpty ? '' : ' • '}${Loc.t('Term', 'مدت')}: $defDays ${Loc.t('days', 'دن')}';
    }
    final canBulk = !g.isAdvance && !onlyBalance && g.partyId != null;
    final followUpLine = _followUpLine(g, st);
    final canTrack = !_purchases && !g.isAdvance && g.partyId != null;

    VoidCallback? onTap;
    if (multi) {
      onTap = () => _openBills(g.key);
    } else if (!one.isBalance) {
      onTap = () => _pickDate(one);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDeco(),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PartyAvatar(
                isCustomer: !_purchases,
                partyId: g.partyId,
                name: g.partyName,
                radius: 19,
                onTap: g.partyId == null
                    ? null
                    : () => showPartyPhotoSheet(context, isCustomer: !_purchases, partyId: g.partyId!),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.partyName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                ]),
              ),
              if (st.promiseBroken) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: _red.withOpacity(0.14), borderRadius: BorderRadius.circular(8)),
                  child: Text(Loc.t('PROMISE BROKEN', 'وعدہ ٹوٹا'),
                      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: _red)),
                ),
                const SizedBox(width: 6),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(8)),
                child: Text(badgeText, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${_rs(g.total)}  ${Loc.t('due', 'واجب الادا')}',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _primary)),
                  if (dateLine.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(dateLine, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                  ],
                  if (followUpLine != null) ...[
                    const SizedBox(height: 2),
                    Text(followUpLine.$1,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: followUpLine.$2)),
                  ],
                ]),
              ),
              if (multi) Icon(Icons.chevron_right, color: _p.textMuted),
              if (canTrack) ...[
                Tooltip(
                  message: Loc.t('Payment received', 'رقم وصول'),
                  child: _circleButton(Icons.check, _teal, _p.flatTealBg, () => _receive(g)),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: Loc.t('Follow-up history / add note', 'فالو اپ ہسٹری / نوٹ'),
                  child: _circleButton(Icons.history, _teal, _p.flatTealBg, () => _openTimeline(g)),
                ),
                const SizedBox(width: 10),
              ],
              if (canBulk) ...[
                Tooltip(
                  message: Loc.t('Set dates for all bills', 'سب بلوں کی تاریخ'),
                  child: _circleButton(Icons.event_available, _amber, _p.flatAmberBg, () => _bulkDates(g)),
                ),
                const SizedBox(width: 10),
              ],
              if (hasPhone) ...[
                if (canRemind) ...[
                  _circleButton(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(g)),
                  const SizedBox(width: 10),
                ],
                _circleButton(Icons.phone, _primary, _p.flatPurpleBg, () => _call(g)),
              ],
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon, Color fg, Color bg, VoidCallback onTap) => InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: fg),
        ),
      );
}
