import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/day_book_repository.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'purchase_screen.dart';
import 'sale_screen.dart';

/// Mirrors DayBookActivity.kt — one day's sales, purchases, expenses and
/// manual cash entries, with Cash In / Cash Out / Net for that day.
///
/// Roles: all (Day Book shows no cost/profit data). Tap-to-open on a sale or purchase row
/// is admin only (it opens the saved-sale / saved-purchase editor, same rule as History).
class DayBookScreen extends StatefulWidget {
  const DayBookScreen({super.key});

  @override
  State<DayBookScreen> createState() => _DayBookScreenState();
}

class _DayBookScreenState extends State<DayBookScreen> {
  DateTime _day = DateTime.now();
  DayBookData? _data;
  String? _error;
  int _loadToken = 0; // a slow load for an old date must not overwrite a newer one

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _error = null;
    });
    try {
      final d = await DayBookRepository.instance.loadDay(_day);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _data = d;
      });
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  void _shiftDay(int delta) {
    _day = DateTime(_day.year, _day.month, _day.day + delta);
    _load();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked == null || !mounted) return;
    _day = DateTime(picked.year, picked.month, picked.day);
    _load();
  }

  bool get _isToday {
    final n = DateTime.now();
    return _day.year == n.year && _day.month == n.month && _day.day == n.day;
  }

  bool _canOpen(DayBookEntry e) =>
      (e.refType == 'sale' || e.refType == 'purchase') && e.refId != null && Session.isAdmin;

  Future<void> _open(DayBookEntry e) async {
    if (!_canOpen(e)) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => e.refType == 'purchase' ? PurchaseScreen(editBillNo: e.refId) : SaleScreen(editInvoice: e.refId)));
    if (mounted) _load(); // the bill may have been edited / returned / deleted
  }

  IconData _icon(DayBookKind k) {
    switch (k) {
      case DayBookKind.sale:
        return Icons.shopping_cart_outlined;
      case DayBookKind.purchase:
        return Icons.inventory_2_outlined;
      case DayBookKind.expense:
        return Icons.account_balance_wallet_outlined;
      case DayBookKind.cashIn:
        return Icons.trending_up;
      case DayBookKind.cashOut:
        return Icons.trending_down;
    }
  }

  String _rs0(double v) => 'Rs ${v.toStringAsFixed(0)}';

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final data = _data;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(
        children: [
          _header(p),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _dateChip(p),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red)),
                    )
                  else if (data == null)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 60), child: Center(child: CircularProgressIndicator()))
                  else ...[
                    _summary(p, data.summary),
                    const SizedBox(height: 10),
                    _netCard(p, data.summary.net),
                    Text(Loc.t('TRANSACTIONS', 'لین دین'),
                        style: TextStyle(fontSize: 12, letterSpacing: 0.5, fontWeight: FontWeight.bold, color: p.textMuted)),
                    const SizedBox(height: 10),
                    if (data.entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                          child: Text(Loc.t('No transactions on this day', 'اس دن کوئی لین دین نہیں'),
                              style: TextStyle(fontSize: 13, color: p.textMuted)),
                        ),
                      )
                    else
                      for (final e in data.entries) _entryTile(p, e),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Header colour is p.teal (not flatTealFg): in dark mode flatTealFg is a pale
  // mint and white title text would be unreadable on it.
  Widget _header(AppPalette p) {
    Widget circleBtn(IconData icon, VoidCallback onTap) => InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        );
    return Container(
      color: p.teal,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 10, 16, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: p.headerBadgeOverlay, shape: BoxShape.circle),
            child: const Icon(Icons.menu_book, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(Loc.t('Day Book', 'روزنامچہ'),
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          circleBtn(Icons.chevron_left, () => _shiftDay(-1)),
          const SizedBox(width: 10),
          circleBtn(Icons.chevron_right, () => _shiftDay(1)),
        ],
      ),
    );
  }

  Widget _dateChip(AppPalette p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: p.cardWhite,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: p.border),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.calendar_today, size: 15, color: p.teal),
                  const SizedBox(width: 10),
                  Text(DateFormat('dd MMM yyyy, EEEE').format(_day),
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                  Text('  \u203A', style: TextStyle(fontSize: 13, color: p.teal)),
                ]),
              ),
            ),
            if (!_isToday)
              TextButton(
                onPressed: () {
                  final n = DateTime.now();
                  _day = DateTime(n.year, n.month, n.day);
                  _load();
                },
                child: Text(Loc.t('Today', 'آج'), style: TextStyle(color: p.teal, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _cardDeco(AppPalette p, double radius) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6, offset: const Offset(0, 2))],
      );

  Widget _statCard(AppPalette p, IconData icon, String label, double value, Color accent) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDeco(p, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: p.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.textMuted)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(_rs0(value), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accent)),
        ]),
      ),
    );
  }

  Widget _summary(AppPalette p, DayBookSummary s) {
    final green = p.flatTealFg;
    return Column(children: [
      Row(children: [
        _statCard(p, Icons.shopping_cart_outlined, Loc.t('Sales', 'سیل'), s.totalSales, green),
        const SizedBox(width: 16),
        _statCard(p, Icons.inventory_2_outlined, Loc.t('Purchases', 'خریداری'), s.totalPurchases, p.flatAmberFg),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        _statCard(p, Icons.trending_up, Loc.t('Cash In', 'کیش ان'), s.cashIn, green),
        const SizedBox(width: 16),
        _statCard(p, Icons.trending_down, Loc.t('Cash Out', 'کیش آؤٹ'), s.cashOutWithExpenses, p.red),
      ]),
    ]);
  }

  Widget _netCard(AppPalette p, double net) {
    final label = _isToday
        ? Loc.t('Net Cash Flow (Today)', 'خالص کیش فلو (آج)')
        : Loc.t('Net Cash Flow (This Day)', 'خالص کیش فلو (اس دن)');
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: _cardDeco(p, 18),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted))),
        Text('Rs ${net.toStringAsFixed(2)}',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: net >= 0 ? p.flatTealFg : p.red)),
      ]),
    );
  }

  Widget _entryTile(AppPalette p, DayBookEntry e) {
    final color = e.isInflow ? p.flatTealFg : p.red;
    final tile = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco(p, 16),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
          child: Icon(_icon(e.kind), color: color, size: 18),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 3),
            Text(e.subtitle, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
            const SizedBox(height: 3),
            Text(DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(e.time)),
                style: TextStyle(fontSize: 10.5, color: p.textMuted)),
          ]),
        ),
        const SizedBox(width: 8),
        Text('${e.isInflow ? '+' : '-'} ${_rs0(e.amount)}',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
    if (!_canOpen(e)) return tile;
    return InkWell(borderRadius: BorderRadius.circular(16), onTap: () => _open(e), child: tile);
  }
}
