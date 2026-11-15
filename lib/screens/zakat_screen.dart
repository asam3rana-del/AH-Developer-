import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/zakat_repository.dart';
import '../models/zakat.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors ZakatActivity.kt — Ramadan-to-Ramadan Zakat tracker.
/// Admin / Manager only (wrapped in RoleGuard by the dashboard; the repository
/// re-checks too).
///
/// Every action goes through [_guard] (single re-entrancy lock, never nested),
/// so a double tap can't start two dialogs or save a payment twice.
class ZakatScreen extends StatefulWidget {
  const ZakatScreen({super.key});

  @override
  State<ZakatScreen> createState() => _ZakatScreenState();
}

typedef _YearInput = ({double assets, String currency, String calendar});

class _ZakatScreenState extends State<ZakatScreen> {
  static const _currencies = ['Rs', 'PKR', r'$', 'SAR', 'AED', '\u00A3', '\u20AC'];
  static final _fmt = DateFormat('dd MMM yyyy');

  ZakatSnapshot? _snap;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _guard(_reload);
  }

  Future<void> _reload() async {
    try {
      final s = await ZakatRepository.instance.load();
      if (!mounted) return;
      setState(() {
        _snap = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Runs [action] once at a time; errors become a toast.
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } catch (e) {
      if (mounted) _toast(e is ArgumentError ? '${e.message}' : e.toString());
    } finally {
      _busy = false;
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  String _money(String cur, double v) => '$cur ${v.toStringAsFixed(0)}';

  // ------------------------------------------------------------------ actions

  Future<void> _startOrRecalculate({required bool recalc}) async {
    final snap = _snap!;
    final b = snap.bracket;
    final f = await ZakatRepository.instance.autoFigures();
    final cur = snap.active?.currency ?? await ZakatRepository.instance.defaultCurrency();
    if (!mounted) return;
    final input = await _yearDialog(
      title: recalc ? Loc.t('Recalculate This Year', 'اس سال کا دوبارہ حساب') : Loc.t('Confirm Zakat Year', 'زکوٰۃ سال کی تصدیق کریں'),
      hint: Loc.t(
          'Auto-calculated from Cash + Bank + Stock + Receivables \u2212 Payables. Adjust if needed:',
          'نقدی + بینک + اسٹاک + قابل وصول \u2212 قابل ادائیگی سے خودکار حساب۔ ضرورت ہو تو درست کریں:'),
      initialAssets: f.net > 0 ? f.net : 0,
      initialCurrency: cur,
      initialCalendar: snap.active?.calendarType ?? 'islamic',
      okLabel: recalc ? Loc.t('Update', 'تازہ کریں') : Loc.t('Start', 'شروع کریں'),
    );
    if (input == null) return;
    await ZakatRepository.instance.startOrRecalculateYear(
      start: b.start,
      end: b.end,
      assets: input.assets,
      currency: input.currency,
      calendarType: input.calendar,
    );
    if (mounted) _toast(recalc ? Loc.t('Zakat year updated', 'زکوٰۃ سال تازہ ہو گیا') : Loc.t('Zakat year started', 'زکوٰۃ سال شروع ہو گیا'));
    await _reload();
  }

  Future<void> _editYear(ZakatYear y) async {
    final input = await _yearDialog(
      title: Loc.t('Edit Zakat Year', 'زکوٰۃ سال میں ترمیم'),
      hint: Loc.t('Correct the saved Net Zakatable Assets for this year:', 'اس سال کے محفوظ شدہ خالص زکوٰۃ کے قابل اثاثے درست کریں:'),
      initialAssets: y.assetsSnapshot,
      initialCurrency: y.currency,
      initialCalendar: y.calendarType,
      okLabel: Loc.t('Save', 'محفوظ کریں'),
    );
    if (input == null) return;
    await ZakatRepository.instance.updateYear(y, assets: input.assets, currency: input.currency, calendarType: input.calendar);
    if (mounted) _toast(Loc.t('Zakat year updated', 'زکوٰۃ سال تازہ ہو گیا'));
    await _reload();
  }

  Future<void> _payRemainingInFull(ZakatYear y, double remaining) async {
    await ZakatRepository.instance.savePayment(
      year: y,
      amount: remaining,
      method: 'cash',
      note: Loc.t('Full remaining balance', 'مکمل باقی رقم'),
      urdu: Loc.isUrdu,
    );
    if (mounted) _toast(Loc.t('Payment saved', 'ادائیگی محفوظ ہو گئی'));
    await _reload();
  }

  Future<void> _recordPayment(ZakatYear y, double remaining) async {
    final r = await _paymentDialog(y, remaining);
    if (r == null) return;
    await ZakatRepository.instance.savePayment(
      year: y,
      amount: r.amount,
      method: r.method,
      note: r.note,
      category: r.category,
      paymentDate: r.date,
      urdu: Loc.isUrdu,
    );
    if (mounted) _toast(Loc.t('Payment saved', 'ادائیگی محفوظ ہو گئی'));
    await _reload();
  }

  Future<void> _editMonth(ZakatYear y, ZakatMonthRow row) async {
    final label = zakatMonthLabel(y, row.month, urdu: Loc.isUrdu);
    final amountC = TextEditingController(text: row.payable.toStringAsFixed(0));
    final noteC = TextEditingController(text: row.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Edit Month', 'ماہ میں ترمیم')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: amountC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: InputDecoration(labelText: Loc.t('Payable Amount for this month', 'اس ماہ کی قابل ادا رقم')),
            ),
            TextField(controller: noteC, decoration: InputDecoration(labelText: Loc.t('Description / Note (optional)', 'تفصیل / نوٹ (اختیاری)'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Save', 'محفوظ کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    final amt = double.tryParse(amountC.text.trim());
    if (amt == null || amt < 0) {
      _toast(Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
      return;
    }
    await ZakatRepository.instance.saveMonthPlan(y, row.month, amt, noteC.text, row.plan);
    if (mounted) _toast(Loc.t('Month updated', 'ماہ تازہ ہو گیا'));
    await _reload();
  }

  // ------------------------------------------------------------------ dialogs

  Future<_YearInput?> _yearDialog({
    required String title,
    required String hint,
    required double initialAssets,
    required String initialCurrency,
    required String initialCalendar,
    required String okLabel,
  }) {
    final assetsC = TextEditingController(text: initialAssets.toStringAsFixed(0));
    final preset = _currencies.contains(initialCurrency);
    var currency = preset ? initialCurrency : 'Custom';
    final customC = TextEditingController(text: preset ? '' : initialCurrency);
    var calendar = initialCalendar;
    String? err;
    return showDialog<_YearInput>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(hint, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              TextField(
                controller: assetsC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: InputDecoration(labelText: Loc.t('Net Zakatable Assets', 'خالص زکوٰۃ کے قابل اثاثے'), errorText: err),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: currency,
                decoration: InputDecoration(labelText: Loc.t('Currency', 'کرنسی')),
                items: [for (final c in [..._currencies, 'Custom']) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setD(() => currency = v ?? 'Rs'),
              ),
              if (currency == 'Custom')
                TextField(controller: customC, decoration: InputDecoration(labelText: Loc.t('Custom currency symbol/code', 'اپنی کرنسی لکھیں'))),
              const SizedBox(height: 12),
              Text(Loc.t('Monthly breakdown shows', 'ماہانہ تفصیل میں دکھائیں'), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'islamic', label: Text(Loc.t('Islamic', 'اسلامی'))),
                  ButtonSegment(value: 'gregorian', label: Text(Loc.t('Gregorian', 'عیسوی'))),
                ],
                selected: {calendar},
                onSelectionChanged: (s) => setD(() => calendar = s.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                final a = double.tryParse(assetsC.text.trim());
                if (a == null || !a.isFinite || a < 0) {
                  setD(() => err = Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
                  return;
                }
                final cur = currency == 'Custom' ? (customC.text.trim().isEmpty ? 'Rs' : customC.text.trim()) : currency;
                Navigator.pop(ctx, (assets: a, currency: cur, calendar: calendar));
              },
              child: Text(okLabel),
            ),
          ],
        );
      }),
    );
  }

  Future<({double amount, String method, String category, String note, DateTime date})?> _paymentDialog(ZakatYear y, double remaining) {
    final amountC = TextEditingController();
    final noteC = TextEditingController();
    var method = 'cash';
    var category = '';
    var date = DateTime.now();
    String? err;
    return showDialog<({double amount, String method, String category, String note, DateTime date})>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(Loc.t('Record Zakat Payment', 'زکوٰۃ ادائیگی درج کریں')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: amountC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: InputDecoration(
                  labelText: Loc.t('Amount (remaining: ${_money(y.currency, remaining)})', 'رقم (باقی: ${_money(y.currency, remaining)})'),
                  errorText: err,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: method,
                decoration: InputDecoration(labelText: Loc.t('Paid from', 'کہاں سے ادا')),
                items: [
                  DropdownMenuItem(value: 'cash', child: Text(Loc.t('Cash', 'نقد'))),
                  DropdownMenuItem(value: 'bank', child: Text(Loc.t('Bank', 'بینک'))),
                ],
                onChanged: (v) => setD(() => method = v ?? 'cash'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: category,
                decoration: InputDecoration(labelText: Loc.t('Category (optional)', 'کیٹیگری (اختیاری)')),
                items: [for (final c in zakatCategories) DropdownMenuItem(value: c.$1, child: Text(Loc.t(c.$2, c.$3)))],
                onChanged: (v) => setD(() => category = v ?? ''),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text('${Loc.t('Payment Date', 'ادائیگی کی تاریخ')}: ${_fmt.format(date)}'),
                onPressed: () async {
                  final today = DateTime.now();
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime.fromMillisecondsSinceEpoch(y.startDate),
                    lastDate: DateTime(today.year, today.month, today.day),
                  );
                  if (picked != null) setD(() => date = picked);
                },
              ),
              TextField(controller: noteC, decoration: InputDecoration(labelText: Loc.t('Note (optional)', 'نوٹ (اختیاری)'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
            TextButton(
              onPressed: () {
                final a = double.tryParse(amountC.text.trim());
                if (a == null || !a.isFinite || a <= 0) {
                  setD(() => err = Loc.t('Enter a valid amount', 'صحیح رقم لکھیں'));
                  return;
                }
                Navigator.pop(ctx, (amount: a, method: method, category: category, note: noteC.text.trim(), date: date));
              },
              child: Text(Loc.t('Save', 'محفوظ کریں')),
            ),
          ],
        );
      }),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final snap = _snap;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: TextStyle(color: p.red))))
              : snap == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () => _guard(_reload),
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 32), children: [
                        if (snap.active == null) _startCard(p, snap, recalc: false) else ..._activeSections(p, snap),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 4, 6, 20),
                          child: Text(
                            Loc.t(
                              'Note: this uses a standard estimate (cash + bank + stock at cost + receivables \u2212 payables) \u00D7 2.5%. Year dates use the tabular Hijri calendar and can differ by a day or two from moon sighting. Confirm anything business-specific with your own mufti/scholar, especially Nisab and stock valuation.',
                              'نوٹ: یہ ایک عام تخمینہ استعمال کرتا ہے (نقدی + بینک + اسٹاک لاگت پر + قابل وصول \u2212 قابل ادائیگی) \u00D7 2.5%\u06D4 سال کی تاریخیں جدولی ہجری کیلنڈر سے ہیں، چاند کی رؤیت سے ایک دو دن مختلف ہو سکتی ہیں۔ کاروبار سے متعلق تفصیلات، خاص طور پر نصاب اور اسٹاک کی قیمت، اپنے مفتی/عالم سے تصدیق کر لیں۔',
                            ),
                            style: TextStyle(fontSize: 11.5, color: p.textMuted),
                          ),
                        ),
                      ]),
                    ),
        ),
      ]),
    );
  }

  List<Widget> _activeSections(AppPalette p, ZakatSnapshot s) {
    final y = s.active!;
    return [
      _activeCard(p, y, s.paid),
      const SizedBox(height: 16),
      _monthsCard(p, y, s.months),
      const SizedBox(height: 16),
      _historyCard(p, y, s.payments),
      const SizedBox(height: 16),
      _startCard(p, s, recalc: true),
    ];
  }

  Widget _header(AppPalette p) => Container(
        color: p.navy,
        padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
            child: const Icon(Icons.volunteer_activism, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Zakat', 'زکوٰۃ'), style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
              Text(Loc.t('Ramadan to Ramadan \u2022 auto-calculated', 'رمضان تا رمضان \u2022 خودکار حساب'),
                  style: TextStyle(color: p.headerSubtitleColor, fontSize: 11)),
            ]),
          ),
        ]),
      );

  BoxDecoration _card(AppPalette p, {Color? stroke}) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: stroke ?? p.border),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      );

  Widget _pill(String label, Color color, VoidCallback onTap) => Material(
        color: color,
        borderRadius: BorderRadius.circular(30),
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Center(child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
          ),
        ),
      );

  Widget _startCard(AppPalette p, ZakatSnapshot s, {required bool recalc}) {
    final b = s.bracket;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _card(p, stroke: recalc ? p.border : p.amber),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          recalc ? Loc.t('Recalculate this Zakat year', 'اس زکوٰۃ سال کا دوبارہ حساب') : Loc.t('No active Zakat year', 'کوئی فعال زکوٰۃ سال نہیں'),
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark),
        ),
        Padding(
          padding: EdgeInsets.only(top: 4, bottom: recalc ? 4 : 14),
          child: Text('${_fmt.format(b.start)} \u2014 ${_fmt.format(b.end)}', style: TextStyle(fontSize: 12.5, color: p.textMuted)),
        ),
        if (recalc)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              Loc.t('Updates this year\'s assets and payable. Recorded payments and monthly notes are kept.',
                  'اس سال کے اثاثے اور واجب رقم تازہ ہوں گے۔ درج شدہ ادائیگیاں اور ماہانہ نوٹ محفوظ رہیں گے۔'),
              style: TextStyle(fontSize: 11.5, color: p.textMuted),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: _pill(
            recalc ? Loc.t('Recalculate Assets', 'اثاثوں کا دوبارہ حساب') : Loc.t('Calculate & Start This Year', 'حساب لگائیں اور سال شروع کریں'),
            p.flatPurpleFg,
            () => _guard(() => _startOrRecalculate(recalc: recalc)),
          ),
        ),
      ]),
    );
  }

  Widget _amountRow(AppPalette p, String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 13.5, color: p.textMuted))),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _activeCard(AppPalette p, ZakatYear y, double paid) {
    final remaining = (y.totalPayable - paid) < 0 ? 0.0 : y.totalPayable - paid;
    final pct = y.totalPayable > 0 ? (paid / y.totalPayable).clamp(0.0, 1.0) : 0.0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _card(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${_fmt.format(DateTime.fromMillisecondsSinceEpoch(y.startDate))} \u2014 ${_fmt.format(DateTime.fromMillisecondsSinceEpoch(y.endDate))}',
                style: TextStyle(fontSize: 12, color: p.textMuted)),
          ),
          TextButton.icon(
            onPressed: () => _guard(() => _editYear(y)),
            icon: Icon(Icons.edit, size: 14, color: p.flatPurpleFg),
            label: Text(Loc.t('Edit', 'ترمیم'), style: TextStyle(color: p.flatPurpleFg, fontWeight: FontWeight.bold)),
          ),
        ]),
        _amountRow(p, Loc.t('Net Zakatable Assets', 'خالص زکوٰۃ کے قابل اثاثے'), _money(y.currency, y.assetsSnapshot), p.textDark),
        _amountRow(p, Loc.t('Total Zakat Payable', 'کل زکوٰۃ ادا کرنی ہے'), _money(y.currency, y.totalPayable), p.flatPurpleFg),
        _amountRow(p, Loc.t('Paid So Far', 'اب تک ادا شدہ'), _money(y.currency, paid), p.teal),
        _amountRow(p, Loc.t('Remaining', 'باقی رقم'), _money(y.currency, remaining), remaining > 0 ? p.red : p.teal),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: pct, minHeight: 8, color: p.teal, backgroundColor: p.border)),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 14),
          child: Text('${(pct * 100).toStringAsFixed(0)}% ${Loc.t('paid', 'ادا شدہ')}', style: TextStyle(fontSize: 11, color: p.textMuted)),
        ),
        if (remaining > 0.0)
          Row(children: [
            Expanded(child: _pill(Loc.t('Record Payment', 'ادائیگی درج کریں'), p.flatPurpleFg, () => _guard(() => _recordPayment(y, remaining)))),
            const SizedBox(width: 10),
            Expanded(child: _pill(Loc.t('Pay Remaining in Full', 'باقی مکمل ادا کریں'), p.teal, () => _guard(() => _payRemainingInFull(y, remaining)))),
          ])
        else
          Text('\u2705 ${Loc.t('Fully paid for this year', 'اس سال کی مکمل ادائیگی ہو چکی ہے')}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.teal)),
      ]),
    );
  }

  Widget _monthsCard(AppPalette p, ZakatYear y, List<ZakatMonthRow> rows) {
    final planned = rows.fold<double>(0, (a, r) => a + r.payable);
    final paid = rows.fold<double>(0, (a, r) => a + r.paid);
    final rem = (planned - paid) < 0 ? 0.0 : planned - paid;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _card(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('Monthly Breakdown', 'ماہانہ تفصیل'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(Loc.t('Tap a month to set its amount and add a note', 'رقم مقرر کرنے اور نوٹ لکھنے کے لیے ماہ پر ٹیپ کریں'),
              style: TextStyle(fontSize: 12, color: p.textMuted)),
        ),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _guard(() => _editMonth(y, r)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: p.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(r.covered ? Icons.check_circle : Icons.edit, size: 15, color: r.covered ? p.teal : p.textMuted),
                    const SizedBox(width: 6),
                    Expanded(child: Text(zakatMonthLabel(y, r.month, urdu: Loc.isUrdu), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.textDark))),
                    Text(_money(y.currency, r.payable), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.flatPurpleFg)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(child: Text('${Loc.t('Paid: ', 'ادا شدہ: ')}${_money(y.currency, r.paid)}', style: TextStyle(fontSize: 11.5, color: p.teal))),
                    Text('${Loc.t('Remaining: ', 'باقی: ')}${_money(y.currency, r.remaining)}', style: TextStyle(fontSize: 11.5, color: r.remaining > 0 ? p.red : p.teal)),
                  ]),
                  if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(r.note, style: TextStyle(fontSize: 11.5, color: p.textMuted))),
                ]),
              ),
            ),
          ),
        const Divider(),
        Text(Loc.t('Year-End Totals (from monthly schedule)', 'سالانہ مجموعہ (ماہانہ شیڈول سے)'),
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textDark)),
        _amountRow(p, Loc.t('Total Planned Payable', 'کل مقررہ رقم'), _money(y.currency, planned), p.flatPurpleFg),
        _amountRow(p, Loc.t('Total Paid (this schedule)', 'کل ادا شدہ'), _money(y.currency, paid), p.teal),
        _amountRow(p, Loc.t('Remaining (this schedule)', 'باقی رقم'), _money(y.currency, rem), p.red),
      ]),
    );
  }

  Widget _historyCard(AppPalette p, ZakatYear y, List<ZakatPayment> payments) {
    String catLabel(String key) {
      for (final c in zakatCategories) {
        if (c.$1 == key) return Loc.t(c.$2, c.$3);
      }
      return '';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _card(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('Payment History', 'ادائیگی کی تاریخ'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
        const SizedBox(height: 10),
        if (payments.isEmpty)
          Text(Loc.t('No payments recorded yet', 'ابھی تک کوئی ادائیگی درج نہیں'), style: TextStyle(fontSize: 12.5, color: p.textMuted))
        else
          for (final pay in payments)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(_fmt.format(DateTime.fromMillisecondsSinceEpoch(pay.paymentDate)), style: TextStyle(fontSize: 12, color: p.textMuted))),
                  Text(_money(y.currency, pay.amount), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.teal)),
                ]),
                Builder(builder: (_) {
                  final meta = [
                    if (pay.method.isNotEmpty) pay.method.toUpperCase(),
                    if (pay.category.isNotEmpty && catLabel(pay.category).isNotEmpty) catLabel(pay.category),
                    if (pay.note.isNotEmpty) pay.note,
                  ];
                  return meta.isEmpty ? const SizedBox.shrink() : Text(meta.join('  \u2022  '), style: TextStyle(fontSize: 11.5, color: p.textMuted));
                }),
              ]),
            ),
      ]),
    );
  }
}
