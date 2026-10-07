import 'package:flutter/material.dart';

import '../db/monthly_repository.dart';
import '../db/period_close_repository.dart';
import '../services/session.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';

/// Mirrors MonthlySalesPurchaseActivity.kt — "Sale vs Purchase — Month/Year".
///
/// Monthly / Yearly chips, optional Party (customer/supplier) aur Item filter (suggestions),
/// Total Sale / Total Purchase cards aur har period ka Sale / Purchase / Net.
///
/// Role: admin + manager (RoleGuard + MonthlyRepository check; purchase amounts cost data hain).
///
/// Farq (Kotlin se): party id se match hoti hai (naam se nahi); item lines mein returned bills shamil nahi;
/// item suggestions `matchesQuery` (name + searchTag) se; header rang `palette.teal`.
class MonthlyScreen extends StatelessWidget {
  const MonthlyScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const RoleGuard(allowed: {'admin', 'manager'}, child: _MonthlyBody());
}

class _MonthlyBody extends StatefulWidget {
  const _MonthlyBody();

  @override
  State<_MonthlyBody> createState() => _MonthlyBodyState();
}

class _MonthlyBodyState extends State<_MonthlyBody> {
  final _repo = MonthlyRepository.instance;
  final _partyCtl = TextEditingController();
  final _itemCtl = TextEditingController();

  GroupMode _mode = GroupMode.month;
  MonthlyBase? _base;
  String? _error;

  PartyOption? _party;
  Product? _item;
  List<PartyOption> _partySug = const [];
  List<Product> _itemSug = const [];

  List<PeriodTotals> _monthly = const [];
  List<PeriodTotals> _yearly = const [];
  double _totalSale = 0;
  double _totalPurchase = 0;
  int _seq = 0;
  Map<String, PeriodClose> _closed = const {};

  AppPalette get _p => ThemeManager.palette;
  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _partyCtl.dispose();
    _itemCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final b = await _repo.load();
      if (!mounted) return;
      _base = b;
      await _loadClosed();
      await _apply();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadClosed() async {
    try {
      final m = await PeriodCloseRepository.instance.closedMap();
      if (mounted) setState(() => _closed = m);
    } catch (_) {}
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// Optional: sirf user ke dabane par. Close se pehle confirm; Reopen sirf Admin.
  Future<void> _toggleClose(PeriodTotals t) async {
    final isClosed = _closed.containsKey(t.key);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(isClosed ? Loc.t('Reopen month?', 'مہینہ دوبارہ کھولیں؟') : Loc.t('Close month?', 'مہینہ بند کریں؟')),
        content: Text(isClosed
            ? Loc.t('${t.label} dobara khul jayega aur bills/expenses edit ho sakenge.',
                '${t.label} دوبارہ کھل جائے گا اور بل/خرچے بدلے جا سکیں گے۔')
            : Loc.t(
                '${t.label} ke figures save ho jayenge aur is mahine ke bills, returns, expenses aur payments edit/delete nahi ho sakenge. Admin baad mein Reopen kar sakta hai.',
                '${t.label} کے اعداد محفوظ ہو جائیں گے اور اس مہینے کے بل، واپسی، خرچے اور ادائیگیاں بدلی/حذف نہیں ہو سکیں گی۔ ایڈمن بعد میں دوبارہ کھول سکتا ہے۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(isClosed ? Loc.t('Reopen', 'دوبارہ کھولیں') : Loc.t('Close Month', 'مہینہ بند کریں'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (isClosed) {
        await PeriodCloseRepository.instance.reopen(t.key);
      } else {
        await PeriodCloseRepository.instance.close(t.key);
      }
      await _loadClosed();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _apply() async {
    final base = _base;
    if (base == null) return;
    final seq = ++_seq;
    ItemRecords? rec;
    if (_item != null) {
      try {
        rec = await _repo.itemRecords(_item!.barcode);
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return;
      }
    }
    if (!mounted || seq != _seq) return;
    final sel = selectEntries(
      allSales: base.sales,
      allPurchases: base.purchases,
      itemSales: rec?.sales,
      itemPurchases: rec?.purchases,
      party: _party,
    );
    setState(() {
      _totalSale = sumAmounts(sel.sales);
      _totalPurchase = sumAmounts(sel.purchases);
      _monthly = groupPeriods(sel.sales, sel.purchases, GroupMode.month);
      _yearly = groupPeriods(sel.sales, sel.purchases, GroupMode.year);
    });
  }

  void _clearFilters() {
    _party = null;
    _item = null;
    _partyCtl.clear();
    _itemCtl.clear();
    setState(() {
      _partySug = const [];
      _itemSug = const [];
    });
    _apply();
  }

  String _kind(PartyOption p) => p.isCustomer ? Loc.t('Customer', 'کسٹمر') : Loc.t('Supplier', 'سپلائر');

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final rows = _mode == GroupMode.month ? _monthly : _yearly;
    final hasFilter = _party != null || _item != null;
    final saleLabel = (_party != null && !_party!.isCustomer)
        ? Loc.t('Total Sale (n/a for supplier)', 'کل سیل (سپلائر پر لاگو نہیں)')
        : Loc.t('Total Sale', 'کل سیل');
    final purLabel = (_party != null && _party!.isCustomer)
        ? Loc.t('Total Purchase (n/a for customer)', 'کل خریداری (کسٹمر پر لاگو نہیں)')
        : Loc.t('Total Purchase', 'کل خریداری');

    return Scaffold(
      backgroundColor: p.bg,
      body: Column(children: [
        _header(p),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red))))
              : _base == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 18, 12, 30),
                      children: [
                        Row(children: [
                          _chip(p, Loc.t('Monthly', 'ماہانہ'), GroupMode.month),
                          const SizedBox(width: 8),
                          _chip(p, Loc.t('Yearly', 'سالانہ'), GroupMode.year),
                        ]),
                        const SizedBox(height: 16),
                        _label(p, Loc.t('Filter by Party (customer/supplier)', 'پارٹی کے مطابق (کسٹمر/سپلائر)')),
                        _field(p, _partyCtl, Loc.t('Type a customer or supplier name…', 'کسٹمر یا سپلائر کا نام لکھیں…'), (s) {
                          if (_party != null) {
                            _party = null;
                            _apply();
                          }
                          setState(() => _partySug = suggestParties(_base!.parties, s));
                        }),
                        for (final o in _partySug)
                          _suggestion(p, o.name, _kind(o), () {
                            _party = o;
                            _partyCtl.text = o.name;
                            _partyCtl.selection = TextSelection.collapsed(offset: o.name.length);
                            setState(() => _partySug = const []);
                            _apply();
                          }),
                        const SizedBox(height: 10),
                        _label(p, Loc.t('Filter by Item', 'آئٹم کے مطابق')),
                        _field(p, _itemCtl, Loc.t('Type an item name…', 'آئٹم کا نام لکھیں…'), (s) {
                          if (_item != null) {
                            _item = null;
                            _apply();
                          }
                          setState(() => _itemSug = suggestProducts(_base!.products, s));
                        }),
                        for (final prod in _itemSug)
                          _suggestion(p, prod.name, prod.barcode, () {
                            _item = prod;
                            _itemCtl.text = prod.name;
                            _itemCtl.selection = TextSelection.collapsed(offset: prod.name.length);
                            setState(() => _itemSug = const []);
                            _apply();
                          }),
                        if (hasFilter)
                          InkWell(
                            onTap: _clearFilters,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                              child: Text(
                                [
                                  if (_party != null) '${_kind(_party!)}: ${_party!.name}',
                                  if (_item != null) '${Loc.t('Item', 'آئٹم')}: ${_item!.name}',
                                ].join('  \u2022  ') +
                                    '   \u2715 ${Loc.t('Clear', 'ہٹائیں')}',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.teal),
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        Row(children: [
                          Expanded(child: _summary(p, saleLabel, _rs(_totalSale), p.flatTealFg)),
                          const SizedBox(width: 10),
                          Expanded(child: _summary(p, purLabel, _rs(_totalPurchase), p.red)),
                        ]),
                        const SizedBox(height: 20),
                        if (rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                                child: Text(Loc.t('No sales or purchases found', 'کوئی سیل یا خریداری نہیں ملی'),
                                    style: TextStyle(fontSize: 13, color: p.textMuted))),
                          )
                        else
                          for (final r in rows) _periodRow(p, r),
                      ],
                    ),
        ),
      ]),
    );
  }

  Widget _header(AppPalette p) => Container(
        color: p.teal,
        padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 18),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
            child: const Icon(Icons.bar_chart, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(Loc.t('Sale vs Purchase — Month/Year', 'سیل بمقابلہ خریداری — مہینہ/سال'),
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ),
        ]),
      );

  Widget _chip(AppPalette p, String label, GroupMode m) {
    final active = _mode == m;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _mode = m),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: active ? p.teal : p.fieldFill, borderRadius: BorderRadius.circular(20)),
          child: Text(label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: active ? Colors.white : p.textMuted)),
        ),
      ),
    );
  }

  Widget _label(AppPalette p, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 0, 6),
        child: Text(t, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.textMuted)),
      );

  Widget _field(AppPalette p, TextEditingController c, String hint, ValueChanged<String> onChanged) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: p.fieldFill, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(10)),
        child: TextField(
          controller: c,
          onChanged: onChanged,
          style: TextStyle(fontSize: 14, color: p.textDark),
          decoration: InputDecoration(border: InputBorder.none, hintText: hint, hintStyle: TextStyle(color: p.textMuted)),
        ),
      );

  Widget _suggestion(AppPalette p, String title, String subtitle, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: p.cardWhite, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.textDark)),
              if (subtitle.isNotEmpty) Text(subtitle, style: TextStyle(fontSize: 10.5, color: p.textMuted)),
            ]),
          ),
        ),
      );

  Widget _summary(AppPalette p, String label, String value, Color color) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.cardWhite,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: p.textMuted)),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _periodRow(AppPalette p, PeriodTotals t) {
    final isClosed = _mode == GroupMode.month && _closed.containsKey(t.key);
    Widget col(String label, double v, Color c) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 10.5, color: p.textMuted)),
            const SizedBox(height: 2),
            Text(_rs(v), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: c)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(isClosed ? '\u{1F512} ${t.label}' : t.label,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: p.textDark)),
          ),
          if (_mode == GroupMode.month && Session.isAdmin)
            TextButton(
              onPressed: () => _toggleClose(t),
              child: Text(isClosed ? Loc.t('Reopen', 'دوبارہ کھولیں') : Loc.t('Close Month', 'مہینہ بند کریں'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isClosed ? p.red : p.teal)),
            ),
        ]),
        if (isClosed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                Loc.t('Closed — expenses: ${_rs(_closed[t.key]!.expenseTotal)}', 'بند — خرچے: ${_rs(_closed[t.key]!.expenseTotal)}'),
                style: TextStyle(fontSize: 10.5, color: p.textMuted)),
          ),
        const SizedBox(height: 8),
        Row(children: [
          col(Loc.t('Total Sale', 'کل سیل'), t.sale, p.flatTealFg),
          col(Loc.t('Total Purchase', 'کل خریداری'), t.purchase, p.red),
          col(Loc.t('Net', 'خالص'), t.net, t.net >= 0 ? p.flatTealFg : p.red),
        ]),
      ]),
    );
  }
}
