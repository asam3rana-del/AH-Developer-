import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';
import '../widgets/permission_guard.dart';

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
  const DueRemindersScreen({super.key});

  @override
  Widget build(BuildContext context) => const PermissionGuard(permission: 'due_reminders', child: _DueRemindersBody());
}

class _DueRemindersBody extends StatefulWidget {
  const _DueRemindersBody();

  @override
  State<_DueRemindersBody> createState() => _DueRemindersBodyState();
}

class _DueRemindersBodyState extends State<_DueRemindersBody> with WidgetsBindingObserver {
  final _repo = DueRemindersRepository.instance;
  bool _purchases = false;
  bool _loading = true;
  List<DueBill> _bills = const [];
  final _search = TextEditingController();
  String _query = '';

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
    if (state == AppLifecycleState.resumed) _load(showSpinner: false);
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    final list = _purchases ? await _repo.duePurchases() : await _repo.dueSales();
    if (!mounted) return;
    setState(() {
      _bills = list;
      _loading = false;
    });
  }

  /// tab: 0 = Sales, 1 = Purchases.
  void _setTab(int tab) {
    final purchases = tab == 1;
    if (_purchases == purchases) return;
    _purchases = purchases;
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

  Future<void> _whatsApp(DueParty g) async {
    try {
      // Ek bill => us bill ka message; kai bills / previous balance => ek hi message poore total ke saath.
      final single = g.bills.length == 1 && !g.bills.first.isBalance ? g.bills.first : null;
      final uri = single != null ? whatsAppUri(single) : whatsAppUri(g.toTotalBill());
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast('WhatsApp nahi khul saka. Installed hai?');
    }
  }

  Future<void> _call(DueParty g) async {
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: g.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
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
    final groups = groupDueByParty(_bills).where((g) => dueMatches(g, _query)).toList();
    final shown = [for (final g in groups) ...g.bills];
    final summary = summarizeDue(shown);
    final overdueParties = groups.where((g) => g.hasOverdue()).length;
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
              else if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Text(Loc.t('No match for "${_query.trim()}"', '"${_query.trim()}" نہیں ملا'),
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _p.textMuted)),
                )
              else
                ...[
                  for (final g in groups) _partyCard(g),
                ],
            ],
          ),
        ),
      ),
    );
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

  Widget _partyCard(DueParty g) {
    final multi = g.bills.length > 1;
    final one = g.bills.first;
    final (badgeText, badgeColor) = _badge(dueBucket(g.earliestDue));
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
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.partyName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
                ]),
              ),
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
                ]),
              ),
              if (multi) Icon(Icons.chevron_right, color: _p.textMuted),
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
