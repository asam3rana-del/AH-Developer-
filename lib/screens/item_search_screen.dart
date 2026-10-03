import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/item_rate_repository.dart';
import '../db/product_repository.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Mirrors ItemSearchActivity.kt (spec: docs/specs/item_rate_search.md).
/// Screen ka naam: "Rate Search". Sale rates sab ko; cost sirf admin/manager ko
/// "Show cost" ke peeche (cashier ke liye purchase data load hi nahi hota).
class ItemSearchScreen extends StatefulWidget {
  final String? preselectBarcode;
  const ItemSearchScreen({super.key, this.preselectBarcode});

  @override
  State<ItemSearchScreen> createState() => _ItemSearchScreenState();
}

class _SupplierSummary {
  final String supplier;
  final double lastRate;
  final String lastUnit;
  final double primaryLastRate;
  final double avgRate;
  final int purchaseCount;
  final int lastPurchaseAt;
  final double? prevPrimaryRate;
  const _SupplierSummary(this.supplier, this.lastRate, this.lastUnit, this.primaryLastRate, this.avgRate,
      this.purchaseCount, this.lastPurchaseAt, this.prevPrimaryRate);
}

class _ItemDetail {
  final Product product;
  final List<ItemSaleRecord> sales;
  final List<ItemPurchaseRecord> purchases; // cashier => hamesha khali
  const _ItemDetail(this.product, this.sales, this.purchases);
}

class _ItemSearchScreenState extends State<ItemSearchScreen> {
  static const _staleRateDays = 30;

  final _search = TextEditingController();
  List<Product> _products = [];
  _ItemDetail? _detail;
  bool _loadingDetail = false;
  bool _showCost = false;
  bool _showAllPurchases = false;
  bool _showAllSuppliers = false;

  bool get _canSeeCost => Session.isAdminOrManager;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    final list = await ProductRepository.instance.listAll();
    if (!mounted) return;
    setState(() => _products = list);
    final pre = widget.preselectBarcode;
    if (pre != null) {
      final match = list.where((p) => p.barcode == pre);
      if (match.isNotEmpty) {
        _search.text = match.first.name;
        _open(match.first);
      }
    }
  }

  Future<void> _open(Product p) async {
    setState(() { _loadingDetail = true; _showCost = false; _showAllSuppliers = false; _showAllPurchases = false; });
    final repo = ItemRateRepository.instance;
    final sales = await repo.saleRecordsForItem(p.barcode);
    final purchases = _canSeeCost ? await repo.purchaseRecordsForItem(p.barcode) : <ItemPurchaseRecord>[];
    if (!mounted) return;
    setState(() { _detail = _ItemDetail(p, sales, purchases); _loadingDetail = false; });
  }

  // ---------- rate formatting ----------
  String _fmtRate(double v) => v % 1.0 == 0.0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// "Ctn Rs 2880  •  Dzn Rs 720  •  Pcs Rs 60" (bara unit pehle).
  String _tierRateLine(Product p, double primaryRate) => p.unitLadder().reversed
      .map((t) => '${t.unit} Rs ${_fmtRate(p.fromPrimaryUnitRate(primaryRate, t.unit))}')
      .join('  •  ');

  // ---------- UI pieces ----------
  Widget _card({required Widget child, Color? border, Color? fill, VoidCallback? onTap}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: fill ?? ThemeManager.palette.cardWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border ?? ThemeManager.palette.border),
            ),
            child: child,
          ),
        ),
      );

  Widget _sectionHeader(String label, Color c, String subtitle) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: c)),
          Text(subtitle, style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
        ]),
      );

  Widget _emptyRow(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(t, style: TextStyle(color: ThemeManager.palette.textMuted)),
      );

  Widget _statRow(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, color: ThemeManager.palette.textMuted))),
          Flexible(child: Text(value, textAlign: TextAlign.end, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color))),
        ]),
      );

  // ---------- results list ----------
  Widget _results() {
    final q = _search.text.trim();
    if (q.isEmpty) return const SizedBox.shrink();
    final matches = _products.where((p) => p.matchesQuery(q)).take(15).toList();
    if (matches.isEmpty) {
      return Padding(padding: const EdgeInsets.all(8), child: Text(Loc.t('No matching item', 'کوئی آئٹم نہیں ملا'), style: TextStyle(color: ThemeManager.palette.textMuted)));
    }
    return Column(children: [
      for (final p in matches)
        _card(
          onTap: () => _open(p),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(p.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
              Text('${Loc.t('Stock', 'اسٹاک')}: ${p.formatStockBreakdown()}', style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
            ]),
            const SizedBox(height: 6),
            Text(
              p.salePrice > 0 ? _tierRateLine(p, p.salePrice) : Loc.t('Sale rate not set', 'سیل ریٹ سیٹ نہیں'),
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.salePrice > 0 ? ThemeManager.palette.teal : ThemeManager.palette.textMuted),
            ),
          ]),
        ),
    ]);
  }

  // ---------- detail ----------
  Widget _saleRateCard(Product p) {
    final tiers = p.unitLadder().reversed.toList();
    return _card(
      border: ThemeManager.palette.teal,
      fill: ThemeManager.palette.savedHighlightBg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('SALE RATE', 'سیل ریٹ'), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.tealDark)),
        const SizedBox(height: 8),
        if (p.salePrice <= 0)
          Text(Loc.t('Sale rate not set', 'سیل ریٹ سیٹ نہیں'), style: TextStyle(color: ThemeManager.palette.textMuted))
        else
          Wrap(spacing: 22, runSpacing: 8, children: [
            for (final t in tiers)
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(t.unit, style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
                Text('Rs ${_fmtRate(p.fromPrimaryUnitRate(p.salePrice, t.unit))}',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ThemeManager.palette.teal)),
              ]),
          ]),
        if (p.wholesalePrice > 0) ...[
          const SizedBox(height: 14),
          Text(Loc.t('WHOLESALE RATE', 'ہول سیل ریٹ'),
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.orange)),
          const SizedBox(height: 6),
          Wrap(spacing: 22, runSpacing: 6, children: [
            for (final t in tiers)
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(t.unit, style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
                Text('Rs ${_fmtRate(p.fromPrimaryUnitRate(p.wholesalePrice, t.unit))}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ThemeManager.palette.orange)),
              ]),
          ]),
        ],
      ]),
    );
  }

  Widget _quickSummary(_ItemDetail d) {
    final p = d.product;
    final last = d.sales.isEmpty ? null : d.sales.first;
    return _card(
      border: ThemeManager.palette.navyInk,
      fill: const Color(0xFFF0F4FA),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Loc.t('QUICK SUMMARY', 'خلاصہ'), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk)),
        const SizedBox(height: 10),
        _statRow(Loc.t('Current Stock', 'موجودہ اسٹاک'), p.formatStockBreakdown(), ThemeManager.palette.navyInk),
        if (last != null)
          _statRow(Loc.t('Last Sold At', 'آخری فروخت ریٹ'),
              'Rs ${last.unitPrice.toStringAsFixed(2)} / ${last.unit.isEmpty ? p.unit : last.unit}', ThemeManager.palette.teal),
      ]),
    );
  }

  Widget _rateRow({required String party, required String qtyLabel, required double rate, required String unit,
      required int createdAt, required Color color, required bool isLatest, required Product p}) {
    final date = DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(createdAt));
    return _card(
      border: isLatest ? color : ThemeManager.palette.border,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(party, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
          Text('Rs ${rate.toStringAsFixed(2)} / $unit', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ]),
        const SizedBox(height: 2),
        Text('$qtyLabel  •  $date', style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
        if (isLatest)
          Text(Loc.t('LATEST', 'تازہ ترین'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  String _qty(double q) => q % 1.0 == 0.0 ? q.toStringAsFixed(0) : q.toString();

  List<Widget> _collapsible(List<Widget> rows, bool expanded, VoidCallback toggle, Color color) {
    if (rows.length <= 3) return rows;
    final shown = expanded ? rows : rows.take(3).toList();
    return [
      ...shown,
      TextButton(
        onPressed: toggle,
        child: Text(expanded ? Loc.t('Show less', 'کم دکھائیں') : Loc.t('Show ${rows.length - 3} more', '${rows.length - 3} مزید دکھائیں'),
            style: TextStyle(color: color)),
      ),
    ];
  }

  List<_SupplierSummary> _supplierSummaries(Product p, List<ItemPurchaseRecord> records) {
    if (records.isEmpty) return const [];
    final by = <String, List<ItemPurchaseRecord>>{};
    for (final r in records) {
      by.putIfAbsent(r.supplierName, () => []).add(r); // records pehle se newest-first
    }
    String u(ItemPurchaseRecord r) => r.unit.trim().isEmpty ? p.unit : r.unit;
    final out = <_SupplierSummary>[];
    by.forEach((supplier, recs) {
      final lastUnit = u(recs.first);
      final lastRate = recs.first.unitCost;
      final primaryLast = p.toPrimaryUnitRate(lastRate, lastUnit);
      final prim = recs.map((r) => p.toPrimaryUnitRate(r.unitCost, u(r))).toList();
      // Ghalat unit/rate wali entry (jaise Bag ka rate Gram unit mein) average ko arbon tak le jati thi:
      // median se 10x door wali entries average se bahar rakhi jati hain (history mein wo dikhti rehti hain).
      final sorted = [...prim]..sort();
      final median = sorted[sorted.length ~/ 2];
      final sane = median > 0 ? prim.where((x) => x >= median / 10 && x <= median * 10).toList() : prim;
      final used = sane.isEmpty ? prim : sane;
      final avgPrimary = used.reduce((a, b) => a + b) / used.length;
      out.add(_SupplierSummary(
        supplier, lastRate, lastUnit, primaryLast, p.fromPrimaryUnitRate(avgPrimary, lastUnit), recs.length,
        recs.first.createdAt,
        recs.length > 1 ? p.toPrimaryUnitRate(recs[1].unitCost, u(recs[1])) : null,
      ));
    });
    out.sort((a, b) => a.primaryLastRate.compareTo(b.primaryLastRate));
    return out;
  }

  Widget _supplierRow(_SupplierSummary s, bool isBest, double? savingsPrimary, int days, Product p) {
    final savings = savingsPrimary == null ? null : p.fromPrimaryUnitRate(savingsPrimary, s.lastUnit);
    final prev = s.prevPrimaryRate;
    return _card(
      border: isBest ? ThemeManager.palette.navyInk : ThemeManager.palette.border,
      fill: isBest ? const Color(0xFFEAF2FF) : ThemeManager.palette.cardWhite,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s.supplier, style: TextStyle(fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
          if (isBest)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: ThemeManager.palette.navy, borderRadius: BorderRadius.circular(20)),
              child: Text(Loc.t('BEST RATE', 'بہترین ریٹ'), style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold)),
            ),
          if (prev != null && s.primaryLastRate > prev) Text('▲ ', style: TextStyle(color: ThemeManager.palette.orange)),
          if (prev != null && s.primaryLastRate < prev) Text('▼ ', style: TextStyle(color: ThemeManager.palette.teal)),
          Text('Rs ${s.lastRate.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold, color: isBest ? ThemeManager.palette.navyInk : ThemeManager.palette.textDark)),
        ]),
        Text('${s.lastUnit}', style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
        const SizedBox(height: 4),
        Text(
          '${Loc.t('Last rate', 'آخری ریٹ')}  •  ${Loc.t('Avg', 'اوسط')} Rs ${s.avgRate.toStringAsFixed(2)} / ${s.purchaseCount} ${Loc.t('purchase(s)', 'خریداری')}',
          style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
        ),
        if (isBest && savings != null && savings > 0)
          Text('Rs ${savings.toStringAsFixed(2)} ${Loc.t('cheaper than the next best rate', 'اگلے بہترین ریٹ سے سستا')}',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.teal)),
        if (days >= _staleRateDays)
          Text('⚠ ${Loc.t('Rate may be outdated — last bought $days days ago', 'ریٹ پرانا ہو سکتا ہے — آخری خریداری $days دن پہلے')}',
              style: TextStyle(fontSize: 11, color: ThemeManager.palette.orange)),
      ]),
    );
  }

  Widget _costSection(_ItemDetail d) {
    final p = d.product;
    final summaries = _supplierSummaries(p, d.purchases);
    final best = summaries.isEmpty ? null : summaries.first;
    final last = d.sales.isEmpty ? null : d.sales.first;
    final now = DateTime.now().millisecondsSinceEpoch;

    double? savingsPrimary;
    if (summaries.isNotEmpty) {
      final distinct = summaries.map((s) => s.primaryLastRate).toSet().toList()..sort();
      if (distinct.length > 1) savingsPrimary = distinct[1] - distinct[0];
    }

    // Best purchase rate + profit margin (quick-summary ki cost wali lines)
    final extra = <Widget>[];
    if (best != null) {
      extra.add(_statRow(Loc.t('Best Purchase Rate', 'بہترین خریداری ریٹ'),
          'Rs ${best.lastRate.toStringAsFixed(2)} / ${best.lastUnit}  (${best.supplier})', ThemeManager.palette.orange));
      if (last != null) {
        final saleUnit = last.unit.trim().isEmpty ? p.unit : last.unit;
        final costInSaleUnit = p.fromPrimaryUnitRate(best.primaryLastRate, saleUnit);
        if (costInSaleUnit > 0) {
          final margin = last.unitPrice - costInSaleUnit;
          final pct = margin / costInSaleUnit * 100;
          extra.add(_statRow(Loc.t('Profit Margin', 'منافع'),
              '${margin >= 0 ? '+' : ''}Rs ${margin.toStringAsFixed(2)} / $saleUnit  (${pct.toStringAsFixed(1)}%)',
              margin >= 0 ? ThemeManager.palette.teal : const Color(0xFFD9534F)));
        }
      }
    }

    final purchaseRows = <Widget>[
      for (var i = 0; i < d.purchases.length; i++)
        _rateRow(
          party: d.purchases[i].supplierName,
          qtyLabel: '${_qty(d.purchases[i].qty)} ${d.purchases[i].unit.trim().isEmpty ? p.unit : d.purchases[i].unit}',
          rate: d.purchases[i].unitCost,
          unit: d.purchases[i].unit.trim().isEmpty ? p.unit : d.purchases[i].unit,
          createdAt: d.purchases[i].createdAt,
          color: ThemeManager.palette.orange,
          isLatest: i == 0,
          p: p,
        ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (extra.isNotEmpty) _card(child: Column(children: extra)),
      _sectionHeader(Loc.t('Compare Suppliers', 'سپلائرز کا موازنہ'), ThemeManager.palette.navyInk,
          Loc.t('Each supplier\'s last rate — cheapest first', 'ہر سپلائر کا آخری ریٹ — سب سے سستا اوپر')),
      if (summaries.isEmpty)
        _emptyRow(Loc.t('No supplier data yet for this item', 'اس آئٹم کا سپلائر ڈیٹا نہیں'))
      else
        ..._collapsible(
          [
            for (final s in summaries)
              _supplierRow(s, s.primaryLastRate == summaries.first.primaryLastRate, savingsPrimary,
                  ((now - s.lastPurchaseAt) / (1000 * 60 * 60 * 24)).floor(), p),
          ],
          _showAllSuppliers,
          () => setState(() => _showAllSuppliers = !_showAllSuppliers),
          ThemeManager.palette.navyInk,
        ),
      _sectionHeader(Loc.t('Purchase Rate History', 'خریداری ریٹ کی تاریخ'), ThemeManager.palette.orange,
          Loc.t('Newest first', 'نیا پہلے')),
      if (purchaseRows.isEmpty)
        _emptyRow(Loc.t('No purchases of this item yet', 'اس آئٹم کی کوئی خریداری نہیں'))
      else
        ..._collapsible(purchaseRows, _showAllPurchases, () => setState(() => _showAllPurchases = !_showAllPurchases), ThemeManager.palette.orange),
    ]);
  }

  Widget _detailView(_ItemDetail d) {
    final p = d.product;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton(onPressed: () => setState(() => _detail = null), icon: const Icon(Icons.arrow_back)),
        Expanded(child: Text(p.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
      ]),
      _saleRateCard(p),
      _quickSummary(d),
      // Cost: sirf admin/manager, default band.
      if (_canSeeCost) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => setState(() => _showCost = !_showCost),
          style: OutlinedButton.styleFrom(
            foregroundColor: ThemeManager.palette.orange,
            side: BorderSide(color: ThemeManager.palette.orange),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(_showCost ? '${Loc.t('Hide cost', 'لاگت چھپائیں')} ▴' : '${Loc.t('Show cost', 'لاگت دکھائیں')} ▾',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 10),
        if (_showCost) _costSection(d),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      appBar: AppBar(backgroundColor: ThemeManager.palette.navy, foregroundColor: Colors.white, title: Text(Loc.t('Rate Search', 'ریٹ سرچ'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_detail == null) ...[
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: Loc.t('Type item name…', 'آئٹم کا نام لکھیں…'),
                filled: true,
                fillColor: ThemeManager.palette.cardWhite,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: ThemeManager.palette.border)),
              ),
            ),
            const SizedBox(height: 12),
            if (_loadingDetail) const Center(child: CircularProgressIndicator()) else _results(),
          ] else
            _detailView(_detail!),
        ],
      ),
    );
  }
}
