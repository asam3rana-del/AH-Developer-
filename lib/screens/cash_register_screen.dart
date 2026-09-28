import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/cash_register_repository.dart';
import '../models/misc_entities.dart';
import '../theme/theme_manager.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';

/// Mirrors CashRegisterActivity.kt — daily till: OPEN with an opening
/// cash/bank balance (carried forward from the last CLOSED register), watch
/// today's Cash/Bank In/Out against an Expected Closing, CLOSE against the
/// counted amounts (shortage/excess confirm), REOPEN, plus register history.
/// All roles (same as Kotlin — it has no role check).
class CashRegisterScreen extends StatefulWidget {
  const CashRegisterScreen({super.key});

  @override
  State<CashRegisterScreen> createState() => _CashRegisterScreenState();
}

class _CashRegisterScreenState extends State<CashRegisterScreen> {
  final _openCash = TextEditingController();
  final _openBank = TextEditingController();
  final _countCash = TextEditingController();
  final _countBank = TextEditingController();

  TodayRegister? _today;
  List<RegisterHistoryRow> _history = const [];
  bool _busy = false; // double-tap guard

  static final _moneyFilter = FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'));

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _openCash.dispose();
    _openBank.dispose();
    _countCash.dispose();
    _countBank.dispose();
    super.dispose();
  }

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  Future<void> _refresh() async {
    final today = await CashRegisterRepository.instance.loadToday();
    final history = await CashRegisterRepository.instance.history();
    if (!mounted) return;
    final reg = today.register;
    if (reg == null) {
      _openCash.text = today.carryCash != 0 ? today.carryCash.toStringAsFixed(2) : '';
      _openBank.text = today.carryBank != 0 ? today.carryBank.toStringAsFixed(2) : '';
    } else if (!reg.closed) {
      // Counted amounts start at the expected figure (Kotlin), so an exact
      // till closes with one tap.
      _countCash.text = registerExpected(opening: reg.openingCash, totalIn: today.flows.cashIn, totalOut: today.flows.cashOut)
          .toStringAsFixed(2);
      _countBank.text = registerExpected(opening: reg.openingBank, totalIn: today.flows.bankIn, totalOut: today.flows.bankOut)
          .toStringAsFixed(2);
    }
    setState(() {
      _today = today;
      _history = history;
    });
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- actions ----
  Future<void> _open() => _guard(() async {
        final oc = parseMoneyOrWarn(context, _openCash.text, 'Opening Cash', 'ابتدائی کیش');
        if (oc == null) return;
        final ob = parseMoneyOrWarn(context, _openBank.text, 'Opening Bank', 'ابتدائی بینک');
        if (ob == null) return;
        final inserted = await CashRegisterRepository.instance
            .open(dateKey: _today!.dateKey, openingCash: oc, openingBank: ob);
        if (!mounted) return;
        _toast(inserted
            ? Loc.t('Register opened', 'رجسٹر کھل گیا')
            : Loc.t("Today's register is already opened on another device", 'آج کا رجسٹر کسی اور ڈیوائس پر پہلے ہی کھل چکا ہے'));
        await _refresh();
      });

  Future<void> _reopen(CashRegister reg) => _guard(() async {
        await CashRegisterRepository.instance.reopen(reg.date);
        await _refresh();
      });

  Future<void> _editOpening(CashRegister reg) async {
    final p = ThemeManager.palette;
    final cash = TextEditingController(text: reg.openingCash.toStringAsFixed(2));
    final bank = TextEditingController(text: reg.openingBank.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Edit Opening Balance', 'ابتدائی بیلنس میں ترمیم')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(p, cash, Loc.t('Opening Cash', 'ابتدائی کیش')),
          const SizedBox(height: 12),
          _field(p, bank, Loc.t('Opening Bank', 'ابتدائی بینک')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    // Kotlin: an unreadable field keeps the old value.
    final oc = double.tryParse(cash.text.trim()) ?? reg.openingCash;
    final ob = double.tryParse(bank.text.trim()) ?? reg.openingBank;
    await _guard(() async {
      await CashRegisterRepository.instance.editOpening(reg.date, openingCash: oc, openingBank: ob);
      await _refresh();
    });
  }

  Future<void> _confirmClose(CashRegister reg) async {
    final ac = double.tryParse(_countCash.text.trim());
    final ab = double.tryParse(_countBank.text.trim());
    if (ac == null || ab == null) {
      _toast(Loc.t('Enter valid amounts', 'صحیح رقم درج کریں'));
      return;
    }
    if (_busy) return;
    final (freshCash, freshBank) = await CashRegisterRepository.instance.freshExpected(reg);
    if (!mounted) return;

    String label(double d) {
      if (registerIsMatch(d)) return Loc.t('Exact match', 'بالکل درست');
      if (d > 0) return '${Loc.t('Excess', 'زائد')} ${_rs(d)}';
      return '${Loc.t('Shortage', 'کمی')} ${_rs(-d)}';
    }

    final msg = '${Loc.t('Cash', 'کیش')}: ${label(ac - freshCash)}\n${Loc.t('Bank', 'بینک')}: ${label(ab - freshBank)}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Confirm Close', 'بند کرنے کی تصدیق کریں')),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Confirm', 'تصدیق کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      await CashRegisterRepository.instance.close(reg.date, countedCash: ac, countedBank: ab);
      if (!mounted) return;
      _toast(Loc.t('Register closed', 'رجسٹر بند ہو گیا'));
      await _refresh();
    });
  }

  // ---- build ----
  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final today = _today;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: today == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 16),
                      child: Text(DateFormat('dd MMM yyyy').format(DateTime.now()),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.textMuted)),
                    ),
                    if (today.register == null)
                      _notOpened(p)
                    else if (!today.register!.closed) ...[
                      _openCard(p, today.register!, today.flows),
                      _closeCard(p, today.register!),
                    ] else
                      _closedCard(p, today.register!, today.flows),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(Loc.t('REGISTER HISTORY', 'رجسٹر کی تاریخ'),
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
                    ),
                    const SizedBox(height: 10),
                    if (_history.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(Loc.t('No register history yet', 'ابھی کوئی رجسٹر ریکارڈ نہیں'),
                            style: TextStyle(color: p.textMuted)),
                      )
                    else
                      for (final h in _history) _historyRow(p, h),
                  ],
                ),
        ),
      ]),
    );
  }

  Widget _header(AppPalette p) {
    return Container(
      color: p.navy,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
          child: const Icon(Icons.point_of_sale, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Loc.t('Cash Register', 'کیش رجسٹر'),
                style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
            Text(Loc.t('Daily till open & close', 'روزانہ کیش رجسٹر کھولنا / بند کرنا'),
                style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  BoxDecoration _cardDeco(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 3))],
      );

  Widget _card(AppPalette p, List<Widget> children) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(22),
        decoration: _cardDeco(p, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _sectionLabel(AppPalette p, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
      );

  Widget _badge(String text, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      );

  Widget _statRow(AppPalette p, String label, String value, [Color? valueColor]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: p.textMuted))),
          Text(value, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: valueColor ?? p.textDark)),
        ]),
      );

  Widget _divider(AppPalette p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1, color: p.border),
      );

  InputDecoration _fieldDeco(AppPalette p, String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: p.textMuted),
        filled: true,
        fillColor: p.fieldFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.teal)),
      );

  Widget _field(AppPalette p, TextEditingController c, String hint) => TextField(
        controller: c,
        style: TextStyle(color: p.textDark),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [_moneyFilter],
        decoration: _fieldDeco(p, hint),
      );

  Widget _btn(String label, Color color, VoidCallback onTap, {bool outlined = false, Color? textColor}) => SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: outlined ? ThemeManager.palette.cardWhite : color,
            foregroundColor: textColor ?? Colors.white,
            disabledBackgroundColor: color.withOpacity(0.5),
            disabledForegroundColor: Colors.white70,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: outlined ? BorderSide(color: color) : BorderSide.none,
            ),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      );

  Color _diffColor(AppPalette p, double d) =>
      registerIsMatch(d) ? p.teal : (d < 0 ? p.red : p.flatTealFg);

  String _signed(double d) => '${d >= 0 ? '+' : ''}${_rs(d)}';

  Widget _notOpened(AppPalette p) {
    final carried = _today!.carryCash != 0 || _today!.carryBank != 0;
    return _card(p, [
      _badge(Loc.t('NOT OPENED', 'نہیں کھلا'), p.textMuted),
      _sectionLabel(p, Loc.t('Opening Balance', 'افتتاحی بیلنس')),
      _field(p, _openCash, Loc.t('Opening Cash', 'ابتدائی کیش')),
      const SizedBox(height: 14),
      _field(p, _openBank, Loc.t('Opening Bank', 'ابتدائی بینک')),
      const SizedBox(height: 14),
      if (carried)
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 14),
          child: Text(Loc.t('Carried forward from last closing', 'پچھلی بندش سے منتقل شدہ'),
              style: TextStyle(fontSize: 11, color: p.textMuted)),
        ),
      _btn(Loc.t('OPEN REGISTER', 'رجسٹر کھولیں'), p.flatTealFg, _open),
    ]);
  }

  Widget _openCard(AppPalette p, CashRegister reg, RegisterFlows f) {
    final expCash = registerExpected(opening: reg.openingCash, totalIn: f.cashIn, totalOut: f.cashOut);
    final expBank = registerExpected(opening: reg.openingBank, totalIn: f.bankIn, totalOut: f.bankOut);
    final green = p.flatTealFg;
    return _card(p, [
      _badge(Loc.t('OPEN', 'کھلا ہوا'), green),
      _statRow(p, Loc.t('Opening Cash', 'ابتدائی کیش'), _rs(reg.openingCash)),
      _statRow(p, Loc.t('Opening Bank', 'ابتدائی بینک'), _rs(reg.openingBank)),
      _divider(p),
      _statRow(p, Loc.t('Cash In (today)', 'آج کیش ان'), '+ ${_rs(f.cashIn)}', green),
      _statRow(p, Loc.t('Cash Out (today)', 'آج کیش آؤٹ'), '- ${_rs(f.cashOut)}', p.red),
      _statRow(p, Loc.t('Bank In (today)', 'آج بینک ان'), '+ ${_rs(f.bankIn)}', green),
      _statRow(p, Loc.t('Bank Out (today)', 'آج بینک آؤٹ'), '- ${_rs(f.bankOut)}', p.red),
      _divider(p),
      _statRow(p, Loc.t('Expected Closing Cash', 'متوقع اختتامی کیش'), _rs(expCash), p.navy),
      _statRow(p, Loc.t('Expected Closing Bank', 'متوقع اختتامی بینک'), _rs(expBank), p.navy),
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: InkWell(
          onTap: _busy ? null : () => _editOpening(reg),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.edit, size: 13, color: p.teal),
              const SizedBox(width: 6),
              Text(Loc.t('Edit opening balance', 'ابتدائی بیلنس میں ترمیم کریں'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: p.teal)),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _closeCard(AppPalette p, CashRegister reg) => _card(p, [
        _sectionLabel(p, Loc.t('Close Register', 'رجسٹر بند کریں')),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 14),
          child: Text(
              Loc.t("Enter actual counted amounts to close today's register", 'بند کرنے کے لیے اصل گنی گئی رقم درج کریں'),
              style: TextStyle(fontSize: 12, color: p.textMuted)),
        ),
        _field(p, _countCash, Loc.t('Counted Cash', 'گنا گیا کیش')),
        const SizedBox(height: 14),
        _field(p, _countBank, Loc.t('Counted Bank', 'گنا گیا بینک')),
        const SizedBox(height: 14),
        _btn(Loc.t('CLOSE REGISTER', 'رجسٹر بند کریں'), p.red, () => _confirmClose(reg)),
      ]);

  Widget _closedCard(AppPalette p, CashRegister reg, RegisterFlows f) {
    final fig = registerFigures(reg, f);
    return _card(p, [
      _badge(Loc.t('CLOSED', 'بند'), p.textMuted),
      _statRow(p, Loc.t('Opening Cash', 'ابتدائی کیش'), _rs(reg.openingCash)),
      _statRow(p, Loc.t('Opening Bank', 'ابتدائی بینک'), _rs(reg.openingBank)),
      _divider(p),
      _statRow(p, Loc.t('Expected Closing Cash', 'متوقع اختتامی کیش'), _rs(fig.expectedCash)),
      _statRow(p, Loc.t('Counted Closing Cash', 'گنا گیا اختتامی کیش'), _rs(reg.closingCash)),
      _statRow(p, Loc.t('Cash Difference', 'کیش فرق'), _signed(fig.diffCash), _diffColor(p, fig.diffCash)),
      _divider(p),
      _statRow(p, Loc.t('Expected Closing Bank', 'متوقع اختتامی بینک'), _rs(fig.expectedBank)),
      _statRow(p, Loc.t('Counted Closing Bank', 'گنا گیا اختتامی بینک'), _rs(reg.closingBank)),
      _statRow(p, Loc.t('Bank Difference', 'بینک فرق'), _signed(fig.diffBank), _diffColor(p, fig.diffBank)),
      const SizedBox(height: 18),
      _btn(Loc.t('REOPEN REGISTER', 'رجسٹر دوبارہ کھولیں'), p.navy, () => _reopen(reg), outlined: true, textColor: p.navy),
    ]);
  }

  Widget _historyRow(AppPalette p, RegisterHistoryRow h) {
    final r = h.register;
    String diffText = Loc.t('In Progress', 'جاری ہے');
    Color diffColor = p.textMuted;
    final fig = h.figures;
    if (fig != null) {
      final d = fig.totalDiff;
      diffText = registerIsMatch(d)
          ? Loc.t('Matched', 'درست')
          : (d > 0 ? '+Rs ${d.toStringAsFixed(2)}' : '-Rs ${(-d).toStringAsFixed(2)}');
      diffColor = _diffColor(p, d);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: _cardDeco(p, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(r.date, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.textDark))),
          Text(diffText, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: diffColor)),
        ]),
        const SizedBox(height: 4),
        Text(
          '${Loc.t('Open', 'کھلا')}: Rs ${r.openingCash.toStringAsFixed(2)} / ${r.openingBank.toStringAsFixed(2)}   '
          '${Loc.t('Close', 'بند')}: Rs ${r.closingCash.toStringAsFixed(2)} / ${r.closingBank.toStringAsFixed(2)}',
          style: TextStyle(fontSize: 11.5, color: p.textMuted),
        ),
      ]),
    );
  }
}
