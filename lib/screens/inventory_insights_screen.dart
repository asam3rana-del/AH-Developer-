import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/inventory_insights_repository.dart';
import '../db/reports_repository.dart' show ReportPeriod, reportRangeFor;
import '../models/product.dart';
import '../models/stock_movement.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';

/// Mirrors InventoryInsightsActivity.kt — 4 reports ek tab switcher ke peeche:
/// Reorder Suggestions, Damage / Loss, Profit Margin per Item, Fast / Slow Movers.
/// Reports hub `initialMode` se batata hai ke kaunsa tab pehle khule; baad mein tab badal sakte hain.
///
/// Role: admin/manager (RoleGuard + repository check) — cost/margin data hai.
///
/// Farq (Kotlin se): period Monday se shuru (reportRangeFor); Margin drill-down dialog mein wahi sale+purchase
/// history; Movers ki qty Kotlin jaisi hi (sale_items.qty jo unit mein bechi gayi, unit-normalize nahi).
enum InsightsMode { reorder, damage, profit, movers }

class InventoryInsightsScreen extends StatelessWidget {
  final InsightsMode initialMode;
  const InventoryInsightsScreen({super.key, this.initialMode = InsightsMode.reorder});

  @override
  Widget build(BuildContext context) => RoleGuard(
        allowed: const {'admin', 'manager'},
        child: _InsightsBody(initialMode: initialMode),
      );
}

class _InsightsBody extends StatefulWidget {
  final InsightsMode initialMode;
  const _InsightsBody({required this.initialMode});

  @override
  State<_InsightsBody> createState() => _InsightsBodyState();
}

class _InsightsBodyState extends State<_InsightsBody> {
  final _repo = InventoryInsightsRepository.instance;
  final _dateFmt = DateFormat('d MMM, h:mm a');
  final _dateFmtLong = DateFormat('d MMM yyyy, h:mm a');

  late InsightsMode _mode = widget.initialMode;
  ReportPeriod _period = ReportPeriod.month;

  bool _loading = true;
  String? _error;
  int _loadToken = 0;

  List<Product> _products = const [];
  Map<String, Product> _byBarcode = const {};
  List<StockMovement> _damage = const [];
  Map<String, ({double qty, double amount})> _movement = const {};

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final products = await _repo.loadProducts();
      var damage = const <StockMovement>[];
      var movement = const <String, ({double qty, double amount})>{};
      if (_mode == InsightsMode.damage || _mode == InsightsMode.movers) {
        final r = reportRangeFor(_period, DateTime.now());
        if (_mode == InsightsMode.damage) damage = await _repo.damageBetween(r.start, r.end);
        if (_mode == InsightsMode.movers) movement = await _repo.itemMovementBetween(r.start, r.end);
      }
      if (!mounted || token != _loadToken) return;
      setState(() {
        _products = products;
        _byBarcode = {for (final p in products) p.barcode: p};
        _damage = damage;
        _movement = movement;
        _loading = false;
      });
    } catch (e) {
      if (mounted && token == _loadToken) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _setMode(InsightsMode m) {
    if (m == _mode) return;
    _mode = m;
    _load();
  }

  void _setPeriod(ReportPeriod p) {
    if (p == _period) return;
    _period = p;
    _load();
  }

  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  BoxDecoration _box(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

  // ───────────────────────── build ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
          children: [
            _header(p),
            _tabs(p),
            if (_mode == InsightsMode.damage || _mode == InsightsMode.movers) _periods(p),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red)),
              )
            else if (_loading)
              const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator()))
            else
              ..._body(p),
          ],
        ),
      ),
    );
  }

  ({IconData icon, String title, String sub}) get _headerInfo {
    switch (_mode) {
      case InsightsMode.reorder:
        return (
          icon: Icons.shopping_bag_outlined,
          title: Loc.t('Reorder Suggestions', 'دوبارہ آرڈر تجاویز'),
          sub: Loc.t('Items at or below their reorder level', 'آئٹمز جو دوبارہ آرڈر کی سطح پر یا نیچے ہیں')
        );
      case InsightsMode.damage:
        return (
          icon: Icons.warning_amber,
          title: Loc.t('Damage / Loss Report', 'نقصان کی رپورٹ'),
          sub: Loc.t('Stock logged as damaged or lost', 'خراب یا ضائع ہونے والا اسٹاک')
        );
      case InsightsMode.profit:
        return (
          icon: Icons.trending_up,
          title: Loc.t('Profit Margin per Item', 'فی آئٹم منافع'),
          sub: Loc.t('Sale price vs cost, item by item', 'سیل پرائس بمقابلہ لاگت')
        );
      case InsightsMode.movers:
        return (
          icon: Icons.timer_outlined,
          title: Loc.t('Fast / Slow Movers', 'تیز / سست چلنے والے'),
          sub: Loc.t('Which items sell, and which sit on the shelf', 'کون سے آئٹم بکتے ہیں')
        );
    }
  }

  Widget _header(AppPalette p) {
    final h = _headerInfo;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(8, 14, 16, 14),
      decoration: _box(p, 22),
      child: Row(children: [
        IconButton(icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: () => Navigator.of(context).maybePop()),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(color: p.flatPurpleBg, shape: BoxShape.circle),
          child: Icon(h.icon, color: p.flatPurpleFg, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(h.title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 4),
            Text(h.sub, style: TextStyle(fontSize: 11, color: p.textMuted)),
          ]),
        ),
      ]),
    );
  }

  Widget _pillRow(AppPalette p, List<(String, bool, VoidCallback)> items, {double fontSize = 12}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: p.cardWhite, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          for (final it in items)
            Expanded(
              child: GestureDetector(
                onTap: it.$3,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: it.$2 ? p.flatPurpleFg : null, borderRadius: BorderRadius.circular(10)),
                  alignment: Alignment.center,
                  child: Text(it.$1,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold, color: it.$2 ? Colors.white : p.textMuted)),
                ),
              ),
            ),
        ]),
      );

  Widget _tabs(AppPalette p) => _pillRow(p, [
        (Loc.t('Reorder', 'دوبارہ آرڈر'), _mode == InsightsMode.reorder, () => _setMode(InsightsMode.reorder)),
        (Loc.t('Damage', 'نقصان'), _mode == InsightsMode.damage, () => _setMode(InsightsMode.damage)),
        (Loc.t('Margin', 'منافع'), _mode == InsightsMode.profit, () => _setMode(InsightsMode.profit)),
        (Loc.t('Movers', 'چلن'), _mode == InsightsMode.movers, () => _setMode(InsightsMode.movers)),
      ]);

  Widget _periods(AppPalette p) => _pillRow(p, [
        (Loc.t('Today', 'آج'), _period == ReportPeriod.today, () => _setPeriod(ReportPeriod.today)),
        (Loc.t('This Week', 'اس ہفتے'), _period == ReportPeriod.week, () => _setPeriod(ReportPeriod.week)),
        (Loc.t('This Month', 'اس مہینے'), _period == ReportPeriod.month, () => _setPeriod(ReportPeriod.month)),
        (Loc.t('All Time', 'تمام وقت'), _period == ReportPeriod.allTime, () => _setPeriod(ReportPeriod.allTime)),
      ], fontSize: 11.5);

  // ───────────────────────── shared small views ─────────────────────────

  Widget _summaryCard(AppPalette p, IconData icon, String label, String value, Color accent, Color tint) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: _box(p, 18),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            child: Icon(icon, size: 19, color: accent),
          ),
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

  Widget _rowCard(AppPalette p,
      {required String title,
      required String subtitle,
      required String rightTop,
      required Color rightTopColor,
      required String rightBottom,
      VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: _box(p, 18),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                const SizedBox(height: 3),
                Text(subtitle, style: TextStyle(fontSize: 12, color: p.textMuted)),
              ]),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(rightTop, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: rightTopColor)),
              const SizedBox(height: 2),
              Text(rightBottom, style: TextStyle(fontSize: 10.5, color: p.textMuted)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _empty(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: p.textMuted))),
      );

  Widget _sectionLabel(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.textMuted)),
      );

  Widget _note(AppPalette p, String text) =>
      Padding(padding: const EdgeInsets.fromLTRB(4, 4, 4, 12), child: Text(text, style: TextStyle(fontSize: 12.5, color: p.textMuted)));

  // ───────────────────────── tabs ─────────────────────────

  List<Widget> _body(AppPalette p) {
    switch (_mode) {
      case InsightsMode.reorder:
        return _reorder(p);
      case InsightsMode.damage:
        return _damageTab(p);
      case InsightsMode.profit:
        return _profit(p);
      case InsightsMode.movers:
        return _movers(p);
    }
  }

  List<Widget> _reorder(AppPalette p) {
    final low = reorderCandidates(_products);
    return [
      _summaryCard(p, Icons.warning_amber, Loc.t('Items to reorder', 'دوبارہ آرڈر کرنے والے آئٹمز'), '${low.length}', p.red, p.flatCoralBg),
      if (low.isEmpty)
        _empty(p, Loc.t('Nothing needs reordering right now', 'ابھی کچھ بھی دوبارہ آرڈر کرنے کی ضرورت نہیں'))
      else
        for (final pr in low)
          _rowCard(
            p,
            title: pr.name,
            subtitle: '${Loc.t('Current: ', 'موجودہ: ')}${pr.formatStockBreakdown()}  •  '
                '${Loc.t('Reorder level: ', 'دوبارہ آرڈر کی سطح: ')}${pr.reorderLevel.toStringAsFixed(0)} ${pr.smallestUnitName()}',
            rightTop: '+${suggestedReorderQty(pr).toStringAsFixed(0)} ${pr.smallestUnitName()}',
            rightTopColor: p.flatAmberFg,
            rightBottom: Loc.t('suggested', 'تجویز کردہ'),
          ),
    ];
  }

  List<Widget> _damageTab(AppPalette p) {
    final total = totalDamageLoss(_damage, _byBarcode);
    return [
      _summaryCard(p, Icons.money_off, Loc.t('Total loss value', 'کل نقصان کی مالیت'), _rs(total), p.red, p.flatCoralBg),
      _summaryCard(p, Icons.inventory_2_outlined, Loc.t('Entries logged', 'درج اندراجات'), '${_damage.length}', p.flatAmberFg, p.flatAmberBg),
      if (_damage.isEmpty)
        _empty(p, Loc.t('No damage/loss logged for this period', 'اس مدت میں کوئی نقصان درج نہیں'))
      else
        for (final m in _damage)
          _rowCard(
            p,
            title: _byBarcode[m.barcode]?.name ?? m.barcode,
            subtitle: '${m.note.trim().isNotEmpty ? '${m.note}  •  ' : ''}${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(m.createdAt))}',
            rightTop: '-${m.qty.abs().toStringAsFixed(0)} ${m.unit}',
            rightTopColor: p.red,
            rightBottom: _rs(damageLossValue(m, _byBarcode[m.barcode])),
          ),
    ];
  }

  List<Widget> _profit(AppPalette p) {
    final priced = pricedProducts(_products);
    return [
      _summaryCard(p, Icons.trending_up, Loc.t('Average margin', 'اوسط منافع'), '${averageMargin(priced).toStringAsFixed(1)}%', p.flatTealFg, p.flatTealBg),
      _summaryCard(p, Icons.warning_amber, Loc.t('Under 10% margin', '10% سے کم منافع'), '${lowMarginCount(priced)}', p.red, p.flatCoralBg),
      if (priced.isEmpty)
        _empty(p, Loc.t('No priced items yet', 'ابھی کوئی قیمت والا آئٹم نہیں'))
      else
        for (final pr in sortByMarginAsc(priced))
          Builder(builder: (_) {
            final margin = marginPercent(pr);
            final color = [p.red, p.flatAmberFg, p.flatTealFg][marginBand(margin)];
            return _rowCard(
              p,
              title: pr.name,
              subtitle: '${Loc.t('Cost: ', 'لاگت: ')}${_rs(pr.cost)}   ${Loc.t('Sale: ', 'سیل: ')}${_rs(pr.salePrice)}',
              rightTop: '${margin.toStringAsFixed(1)}%',
              rightTopColor: color,
              rightBottom: Loc.t('margin', 'منافع'),
              onTap: () => _showItemHistory(pr),
            );
          }),
    ];
  }

  List<Widget> _movers(AppPalette p) {
    final rows = buildMovementRows(_products, _movement);
    final fast = fastMovers(rows);
    final slow = slowMovers(rows);
    return [
      _summaryCard(p, Icons.local_fire_department, Loc.t('Units sold this period', 'اس مدت میں فروخت شدہ یونٹس'),
          totalUnitsSold(rows).toStringAsFixed(0), p.flatTealFg, p.flatTealBg),
      _sectionLabel(p, Loc.t('FAST MOVERS', 'تیز چلنے والے')),
      if (fast.isEmpty) _note(p, Loc.t('No sales in this period yet', 'اس مدت میں ابھی کوئی سیل نہیں')),
      for (final r in fast)
        _rowCard(p,
            title: r.name,
            subtitle: _rs(r.amount),
            rightTop: r.qty.toStringAsFixed(0),
            rightTopColor: p.flatTealFg,
            rightBottom: Loc.t('sold', 'فروخت')),
      const SizedBox(height: 14),
      _sectionLabel(p, Loc.t('SLOW MOVERS', 'سست چلنے والے')),
      for (final r in slow)
        _rowCard(p,
            title: r.name,
            subtitle: r.qty == 0 ? Loc.t('No sales this period', 'اس مدت میں کوئی سیل نہیں') : _rs(r.amount),
            rightTop: r.qty.toStringAsFixed(0),
            rightTopColor: r.qty == 0 ? p.red : p.flatAmberFg,
            rightBottom: Loc.t('sold', 'فروخت')),
    ];
  }

  // ───────────────────────── margin drill-down ─────────────────────────

  Future<void> _showItemHistory(Product pr) async {
    final List<ItemHistoryRow> rows;
    try {
      rows = await _repo.itemHistory(pr.barcode);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!mounted) return;
    final p = _p;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardWhite,
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pr.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: p.textDark)),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 18),
                child: Text(
                  '${Loc.t('Cost: ', 'لاگت: ')}${_rs(pr.cost)}   ${Loc.t('Sale: ', 'سیل: ')}${_rs(pr.salePrice)}   •   '
                  '${marginPercent(pr).toStringAsFixed(1)}% ${Loc.t('margin', 'منافع')}',
                  style: TextStyle(fontSize: 12.5, color: p.textMuted),
                ),
              ),
              if (rows.isEmpty)
                _note(p, Loc.t('No sale/purchase history found for this item.', 'اس آئٹم کی کوئی سیل/خریداری کی تاریخ نہیں ملی۔'))
              else
                for (final r in rows) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${r.isSale ? Loc.t('Sale', 'سیل') : Loc.t('Purchase', 'خریداری')} • ${r.party}',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: r.isSale ? p.flatTealFg : p.flatPurpleFg)),
                          const SizedBox(height: 2),
                          Text(_dateFmtLong.format(DateTime.fromMillisecondsSinceEpoch(r.createdAt)),
                              style: TextStyle(fontSize: 11, color: p.textMuted)),
                        ]),
                      ),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${r.qty.toStringAsFixed(0)} ${r.unit}', style: TextStyle(fontSize: 12.5, color: p.textMuted)),
                        Text(_rs(r.rate),
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: r.isSale ? p.flatTealFg : p.flatPurpleFg)),
                      ]),
                    ]),
                  ),
                  Divider(height: 1, color: p.border),
                ],
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(Loc.t('Close', 'بند کریں')))],
      ),
    );
  }
}
