import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/due_reminders_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';

/// Mirrors DueRemindersActivity.kt.
///
/// Har credit / partially-paid bill ek jagah, due date ke hisaab se. Card tap => date picker
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
  Widget build(BuildContext context) => const RoleGuard(allowed: {'admin', 'manager'}, child: _DueRemindersBody());
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

  final _dateFmt = DateFormat('d MMM yyyy');

  AppPalette get _p => ThemeManager.palette;
  Color get _primary => _p.flatPurpleFg;
  Color get _amber => _p.flatAmberFg;
  Color get _red => _p.red;
  Color get _teal => _p.flatTealFg;

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

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

  void _setTab(bool purchases) {
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

  Future<void> _whatsApp(DueBill b) async {
    try {
      final ok = await launchUrl(whatsAppUri(b), mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast('WhatsApp nahi khul saka. Installed hai?');
    }
  }

  Future<void> _call(DueBill b) async {
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: b.partyPhone.trim()));
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) _toast(Loc.t('Could not open the dialer', 'ڈائلر نہیں کھل سکا'));
    }
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final summary = summarizeDue(_bills);
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
              _summaryCard(Icons.warning_amber_rounded, Loc.t('Overdue', 'میعاد گزری'), '${summary.overdue}', _red),
              _summaryCard(Icons.account_balance_wallet_outlined, Loc.t('Total outstanding', 'کل بقایا'), _rs(summary.totalDue), _amber),
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
              else
                for (final b in _bills) _billCard(b),
            ],
          ),
        ),
      ),
    );
  }

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
        pill(Loc.t('Sales (Customers)', 'سیلز (کسٹمرز)'), !_purchases, () => _setTab(false)),
        const SizedBox(width: 12),
        pill(Loc.t('Purchases (Suppliers)', 'خریداری (سپلائرز)'), _purchases, () => _setTab(true)),
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

  Widget _billCard(DueBill b) {
    final (badgeText, badgeColor) = _badge(dueBucket(b.dueDate));
    final hasPhone = b.partyPhone.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDeco(),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _pickDate(b),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.partyName, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                  const SizedBox(height: 2),
                  Text(b.id, style: TextStyle(fontSize: 11.5, color: _p.textMuted)),
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
                  Text('${_rs(b.due)}  ${Loc.t('due', 'واجب الادا')}',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _primary)),
                  const SizedBox(height: 2),
                  Text(
                    b.dueDate > 0
                        ? '${Loc.t('Due: ', 'تاریخ: ')}${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(b.dueDate))}'
                        : Loc.t('Tap to set a due date', 'تاریخ طے کرنے کے لیے دبائیں'),
                    style: TextStyle(fontSize: 11.5, color: _p.textMuted),
                  ),
                ]),
              ),
              if (hasPhone) ...[
                _circleButton(Icons.send, const Color(0xFF25D366), const Color(0xFFDDF6E8), () => _whatsApp(b)),
                const SizedBox(width: 10),
                _circleButton(Icons.phone, _primary, _p.flatPurpleBg, () => _call(b)),
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
