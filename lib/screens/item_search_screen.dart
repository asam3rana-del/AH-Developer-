import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/item_rate_repository.dart';
import '../db/product_repository.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../utils/loc.dart';
import '../widgets/rate_edit_sheet.dart';
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

class _ItemDetail {
  final Product product;
  final List<ItemSaleRecord> sales;
  final List<ItemPurchaseRecord> purchases; // cashier => hamesha khali
  const _ItemDetail(this.product, this.sales, this.purchases);
}

class _ItemSearchScreenState extends State<ItemSearchScreen> {
  final _search = TextEditingController();
  List<Product> _products = [];
  _ItemDetail? _detail;
  bool _loadingDetail = false;
  bool _showCost = false;
  bool _showAllPurchases = false;

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
    setState(() { _loadingDetail = true; _showCost = false; _showAllPurchases = false; });
    final repo = ItemRateRepository.instance;
    final sales = await repo.saleRecordsForItem(p.barcode);
    final purchases = _canSeeCost ? await repo.purchaseRecordsForItem(p.barcode) : <ItemPurchaseRecord>[];
    if (!mounted) return;
    setState(() { _detail = _ItemDetail(p, sales, purchases); _loadingDetail = false; });
  }

  /// Admin: rate card se hi Retail/Wholesale/Shopkeeper rate badlein, phir list + detail dobara load.
  Future<void> _editRates(Product p) async {
    final saved = await showRateEditSheet(context, p);
    if (!saved || !mounted) return;
    final list = await ProductRepository.instance.listAll();
    if (!mounted) return;
    setState(() => _products = list);
    final match = list.where((x) => x.barcode == p.barcode);
    if (match.isNotEmpty) await _open(match.first);
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
        Row(children: [
          Expanded(
            child: Text(Loc.t('SALE RATE', 'سیل ریٹ'),
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.tealDark)),
          ),
          if (Session.isAdmin)
            IconButton(
              tooltip: Loc.t('Edit rates', 'ریٹ تبدیل کریں'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(Icons.edit, size: 18, color: ThemeManager.palette.tealDark),
              onPressed: () => _editRates(p),
            ),
        ]),
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
        const SizedBox(height: 14),
        Text(Loc.t('SHOPKEEPER RATE', 'دکاندار ریٹ'),
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.blue)),
        const SizedBox(height: 6),
        if (p.shopkeeperPrice > 0)
          Wrap(spacing: 22, runSpacing: 6, children: [
            for (final t in tiers)
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(t.unit, style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
                Text('Rs ${_fmtRate(p.fromPrimaryUnitRate(p.shopkeeperPrice, t.unit))}',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: ThemeManager.palette.blue)),
              ])
          ])
        else
          Text(
              Loc.t('Not set — Wholesale rate is used', 'سیٹ نہیں — ہول سیل ریٹ لگتا ہے'),
              style: TextStyle(fontSize: 12.5, color: ThemeManager.palette.textMuted)),
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

  /// Last cost (sab se naya purchase), primary unit mein. Records newest-first.
  double? _lastCost(Product p, List<ItemPurchaseRecord> recs) {
    if (recs.isEmpty) return null;
    final r = recs.first;
    return p.toPrimaryUnitRate(r.unitCost, r.unit.trim().isEmpty ? p.unit : r.unit);
  }

  Widget _costSection(_ItemDetail d) {
    final p = d.product;
    // Cost summary: Last cost aur maujooda sale rate par munafa (primary unit mein).
    final lastCost = _lastCost(p, d.purchases);
    final extra = <Widget>[];
    if (lastCost != null) {
      extra.add(_statRow(Loc.t('Last Cost', 'آخری لاگت'), 'Rs ${lastCost.toStringAsFixed(2)} / ${p.unit}', ThemeManager.palette.orange));
      if (lastCost > 0 && p.salePrice > 0) {
        final margin = p.salePrice - lastCost;
        final pct = margin / lastCost * 100;
        extra.add(_statRow(Loc.t('Profit Margin', 'منافع'),
            '${margin >= 0 ? '+' : ''}Rs ${margin.toStringAsFixed(2)} / ${p.unit}  (${pct.toStringAsFixed(1)}%)',
            margin >= 0 ? ThemeManager.palette.teal : const Color(0xFFD9534F)));
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
