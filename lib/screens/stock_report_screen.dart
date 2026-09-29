import 'package:flutter/material.dart';

import '../db/stock_report_repository.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Mirrors StockReportActivity.kt.
///
/// Summary cards (Total Products / Low Stock / Stock Value Cost / Stock Value Sale), search
/// (naam + searchTag, category, barcode), "LOW STOCK ONLY" toggle, aur har product ka card
/// (LOW badge, stock breakdown, cost value).
///
/// `lowStockOnly: true` = dashboard ka "Low Stock" tile (Kotlin `EXTRA_LOW_STOCK_ONLY`).
///
/// Role: sab roles (dashboard Low Stock tile sab ko dikhta hai). Cashier ko cost data nahi:
/// repository cost zero kar deta hai aur "Stock Value (Cost)" card + row values chhup jate hain.
///
/// Farq (Kotlin se): Material icons; list taza karne ke liye pull-to-refresh.
class StockReportScreen extends StatefulWidget {
  final bool lowStockOnly;
  const StockReportScreen({super.key, this.lowStockOnly = false});

  @override
  State<StockReportScreen> createState() => _StockReportScreenState();
}

class _StockReportScreenState extends State<StockReportScreen> {
  final _repo = StockReportRepository.instance;
  final _search = TextEditingController();

  List<Product>? _all;
  String? _error;
  late bool _lowOnly = widget.lowStockOnly;

  AppPalette get _p => ThemeManager.palette;
  bool get _showCost => Session.isAdminOrManager;
  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.load();
      if (!mounted) return;
      setState(() {
        _all = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final all = _all;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red))))
            : all == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(onRefresh: _load, child: _content(p, all)),
      ),
    );
  }

  Widget _content(AppPalette p, List<Product> all) {
    final s = summarizeStock(all);
    final filtered = filterStock(all, _search.text, lowOnly: _lowOnly);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
      children: [
        _header(p),
        _searchBox(p),
        const SizedBox(height: 14),
        Align(alignment: Alignment.centerLeft, child: _lowToggle(p)),
        const SizedBox(height: 16),
        _summary(p, Icons.inventory_2, Loc.t('Total Products', 'کل آئٹمز'), '${s.totalProducts}', p.flatBlueFg, p.flatBlueBg),
        _summary(p, Icons.warning_amber, Loc.t('Low Stock Items', 'کم اسٹاک آئٹمز'), '${s.lowStockCount}', p.red, p.flatCoralBg),
        if (_showCost)
          _summary(p, Icons.account_balance_wallet, Loc.t('Stock Value (Cost)', 'اسٹاک ویلیو (لاگت)'), _rs(s.costValue), p.flatAmberFg, p.flatAmberBg),
        _summary(p, Icons.trending_up, Loc.t('Stock Value (Sale)', 'اسٹاک ویلیو (سیل)'), _rs(s.saleValue), p.flatTealFg, p.flatTealBg),
        const SizedBox(height: 14),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Center(child: Text(Loc.t('No items found', 'کوئی آئٹم نہیں ملا'), style: TextStyle(fontSize: 13, color: p.textMuted))),
          )
        else
          for (final pr in filtered) _productCard(p, pr),
      ],
    );
  }

  BoxDecoration _box(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

  Widget _header(AppPalette p) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(8, 14, 16, 14),
        decoration: _box(p, 22),
        child: Row(children: [
          IconButton(icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: p.flatBlueBg, shape: BoxShape.circle),
            child: Icon(Icons.inventory_2, color: p.flatBlueFg, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Stock Report', 'اسٹاک رپورٹ'), style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(Loc.t('Current inventory levels', 'موجودہ انوینٹری کی سطح'), style: TextStyle(fontSize: 11, color: p.textMuted)),
            ]),
          ),
        ]),
      );

  Widget _searchBox(AppPalette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: p.fieldFill, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: p.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 14.5, color: p.textDark),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: Loc.t('Search item or category…', 'آئٹم یا کیٹیگری تلاش کریں…'),
                hintStyle: TextStyle(color: p.textMuted),
              ),
            ),
          ),
        ]),
      );

  Widget _lowToggle(AppPalette p) => GestureDetector(
        onTap: () => setState(() => _lowOnly = !_lowOnly),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _lowOnly ? p.red : p.cardWhite,
            border: _lowOnly ? null : Border.all(color: p.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber, size: 15, color: _lowOnly ? Colors.white : p.red),
            const SizedBox(width: 6),
            Text(Loc.t('LOW STOCK ONLY', 'صرف کم اسٹاک'),
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: _lowOnly ? Colors.white : p.textMuted)),
          ]),
        ),
      );

  Widget _summary(AppPalette p, IconData icon, String label, String value, Color accent, Color tint) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        decoration: _box(p, 18),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: tint, shape: BoxShape.circle), child: Icon(icon, color: accent, size: 18)),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: accent)),
            ]),
          ),
        ]),
      );

  Widget _productCard(AppPalette p, Product pr) {
    final low = isLowStock(pr);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: _box(p, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pr.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
              if (pr.category.trim().isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text(pr.category, style: TextStyle(fontSize: 12, color: p.textMuted))),
            ]),
          ),
          if (low)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: p.red, borderRadius: BorderRadius.circular(8)),
              child: Text(Loc.t('LOW', 'کم'), style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text(pr.formatStockBreakdown(),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: low ? p.red : p.textDark)),
          ),
          if (_showCost) Text(_rs(stockCostValue(pr)), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: p.flatBlueFg)),
        ]),
      ]),
    );
  }
}
