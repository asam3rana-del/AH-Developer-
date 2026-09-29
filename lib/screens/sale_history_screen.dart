import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../db/sale_history_repository.dart';
import '../db/sale_repository.dart';
import '../db/user_repository.dart';
import '../models/sale.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/bill_text.dart';
import '../utils/loc.dart';
import 'sale_screen.dart';

/// Mirrors SaleHistoryActivity.kt.
///
/// Saare purane sales, customer ke hisaab se group. Summary cards (Total Sales / Total Returned),
/// customer search, bill par tap = items expand, Print (dobara bill), Edit / Return / Delete.
///
/// Role: Kotlin mein sab dekh sakte hain. Flutter mein: profit sirf admin (data layer bhi check karta
/// hai — cashier ke liye cost load hi nahi hota); Edit / Return / Delete sirf admin
/// (SaleRepository dobara check karta hai).
///
/// Farq (Kotlin se): Material icons; Print = text Bill Preview (Copy) — Bluetooth Phase 12 mein.
class SaleHistoryScreen extends StatefulWidget {
  const SaleHistoryScreen({super.key});

  @override
  State<SaleHistoryScreen> createState() => _SaleHistoryScreenState();
}

class _SaleHistoryScreenState extends State<SaleHistoryScreen> with WidgetsBindingObserver {
  final _repo = SaleHistoryRepository.instance;
  final _search = TextEditingController();
  final _dateFmt = DateFormat('dd MMM yyyy, hh:mm a');

  bool _loading = true;
  List<SaleWithCustomer> _all = const [];
  List<SaleGroup> _groups = const [];
  Map<String, double> _profits = const {};
  SaleHistorySummary _summary = const SaleHistorySummary(0, 0);
  String _query = '';

  final Set<String> _expanded = {};
  final Map<String, List<SaleItem>> _items = {};

  AppPalette get _p => ThemeManager.palette;
  bool get _admin => Session.isAdmin;
  String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';
  String _qty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  // Kotlin onResume: Sale screen se wapas aane par list taza.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(showSpinner: false);
  }

  Future<void> _refresh({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    final all = await _repo.allSales();
    final profits = await _repo.saleProfits();
    if (!mounted) return;
    setState(() {
      _all = all;
      _groups = groupSalesByCustomer(all);
      _profits = profits;
      _summary = summarizeSales(all);
      _items.clear();
      _expanded.removeWhere((inv) => !all.any((s) => s.invoice == inv));
      _loading = false;
    });
    for (final inv in _expanded) {
      _loadItems(inv);
    }
  }

  Future<void> _loadItems(String invoice) async {
    final items = await _repo.itemsForInvoice(invoice);
    if (!mounted) return;
    setState(() => _items[invoice] = items);
  }

  void _toggle(String invoice) {
    setState(() {
      if (!_expanded.add(invoice)) _expanded.remove(invoice);
    });
    if (_expanded.contains(invoice) && !_items.containsKey(invoice)) _loadItems(invoice);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ------------------------------------------------------------------ actions

  Future<void> _edit(SaleWithCustomer s) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleScreen(editInvoice: s.invoice)));
    if (mounted) _refresh(showSpinner: false);
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _return(SaleWithCustomer s) async {
    final ok = await _confirm(
      Loc.t('Return sale', 'سیل واپس'),
      Loc.t('Return this sale? Stock will be added back and any outstanding customer balance from it will be reversed.',
          'یہ سیل واپس کریں؟ اسٹاک واپس جمع ہو گا اور گاہک کا بقایا الٹ دیا جائے گا۔'),
      Loc.t('Return', 'واپس'),
    );
    if (!ok) return;
    try {
      await SaleRepository.instance.returnSale(s.invoice);
      _toast(Loc.t('Sale returned', 'سیل واپس ہو گئی'));
    } catch (e) {
      _toast('$e');
    }
    if (mounted) _refresh(showSpinner: false);
  }

  Future<void> _delete(SaleWithCustomer s) async {
    final ok = await _confirm(
      Loc.t('Delete sale', 'سیل حذف کریں'),
      Loc.t("Delete this sale? This will reverse its stock and customer balance changes. This can't be undone.",
          'یہ سیل حذف کریں؟ اسٹاک اور گاہک کا بقایا الٹ جائے گا۔ یہ واپس نہیں ہو سکتا۔'),
      Loc.t('Delete', 'حذف'),
    );
    if (!ok) return;
    try {
      await SaleRepository.instance.deleteSale(s.invoice);
      _expanded.remove(s.invoice);
      _toast(Loc.t('Sale deleted', 'سیل حذف ہو گئی'));
    } catch (e) {
      _toast('$e');
    }
    if (mounted) _refresh(showSpinner: false);
  }

  /// Kotlin printSale(): DB se poora Sale + items utha kar dobara bill (Bill Preview).
  Future<void> _print(SaleWithCustomer s) async {
    final sale = await _repo.findSale(s.invoice);
    if (sale == null) return;
    final items = _items[s.invoice] ?? await _repo.itemsForInvoice(s.invoice);
    String shopName = '', shopPhone = '';
    try {
      shopName = await UserRepository.instance.getSetting('shop_name') ?? '';
      shopPhone = await UserRepository.instance.getSetting('shop_phone') ?? '';
    } catch (_) {}
    if (!mounted) return;
    final text = buildSaleBillText(
      shopName: shopName,
      shopPhone: shopPhone,
      invoice: sale.invoice,
      date: DateTime.fromMillisecondsSinceEpoch(sale.createdAt),
      customer: s.customerName,
      lines: [
        for (final i in items)
          SaleLine(itemName: i.product, barcode: i.barcode, qty: i.qty, unit: i.unit, unitPrice: i.unitPrice, cost: i.cost, amount: i.amount),
      ],
      subtotal: sale.subtotal,
      discount: sale.discount,
      total: sale.total,
      paid: sale.paid,
      paymentMethod: _methodLabel(sale.paymentMethod),
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Bill Preview', 'بل پری ویو')),
        content: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              _toast(Loc.t('Bill copied', 'بل کاپی ہو گیا'));
            },
            child: Text(Loc.t('Copy', 'کاپی')),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں'))),
        ],
      ),
    );
  }

  String _methodLabel(String m) => m.isEmpty ? '' : m[0].toUpperCase() + m.substring(1);

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final groups = filterGroups(_groups, _query);
    return Scaffold(
      backgroundColor: _p.bg,
      appBar: AppBar(
        backgroundColor: _p.navy,
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(Loc.t('Sale History', 'سیل ہسٹری'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(Loc.t('All past sales, grouped by customer', 'تمام پرانی سیلز، گاہک کے حساب سے'),
              style: TextStyle(fontSize: 11.5, color: _p.headerSubtitleColor)),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleScreen()));
              if (mounted) _refresh(showSpinner: false);
            },
            icon: const Icon(Icons.add, size: 16, color: Colors.white),
            label: Text(Loc.t('New', 'نیا'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                children: [
                  Row(children: [
                    Expanded(child: _summaryCard('↓', Loc.t('Total Sales', 'کل سیل'), _summary.totalSales, _p.teal)),
                    const SizedBox(width: 10),
                    Expanded(child: _summaryCard('↑', Loc.t('Total Returned', 'کل واپسی'), _summary.totalReturned, _p.red)),
                  ]),
                  const SizedBox(height: 14),
                  _searchBox(),
                  const SizedBox(height: 6),
                  if (_all.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20, left: 4),
                      child: Text(Loc.t('No sales yet.', 'ابھی کوئی سیل نہیں۔'), style: TextStyle(fontSize: 14, color: _p.textMuted)),
                    ),
                  for (final g in groups) ..._groupWidgets(g),
                ],
              ),
            ),
    );
  }

  Widget _summaryCard(String arrow, String label, double value, Color accent) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _p.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(arrow, style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: TextStyle(color: _p.textMuted, fontSize: 12.5))),
          ]),
          const SizedBox(height: 6),
          Text(_rs(value), style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _p.textDark)),
        ]),
      );

  Widget _searchBox() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _p.border),
        ),
        child: Row(children: [
          Icon(Icons.search, size: 18, color: _p.navy),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 13.5, color: _p.textDark),
              decoration: InputDecoration(
                hintText: Loc.t('Search customer', 'گاہک تلاش کریں'),
                hintStyle: TextStyle(color: _p.textMuted),
                border: InputBorder.none,
              ),
            ),
          ),
        ]),
      );

  List<Widget> _groupWidgets(SaleGroup g) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(g.customerName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _p.textDark)),
              ),
              Text('${g.sales.length} ${Loc.t('sales', 'سیلز')} · ${_rs(g.total)}', style: TextStyle(fontSize: 12, color: _p.textMuted)),
            ]),
            if (_admin)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${Loc.t('Profit', 'منافع')}: ${_rs(g.profit(_profits))}',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: _p.teal)),
              ),
          ]),
        ),
        for (final s in g.sales) ..._saleWidgets(s),
      ];

  List<Widget> _saleWidgets(SaleWithCustomer s) {
    final profit = _profits[s.invoice];
    Widget icon(IconData i, Color c, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: Icon(i, size: 18, color: c)),
        );
    final items = _items[s.invoice];
    return [
      // Invoice number jaan-boojh kar nahi dikhta — date hi pehchaan hai (Kotlin).
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: _p.cardWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _p.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _toggle(s.invoice),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(s.createdAt)),
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: _p.textDark)),
                  Text(s.isReturned ? Loc.t('Returned', 'واپس') : _methodLabel(s.paymentMethod),
                      style: TextStyle(fontSize: 11, color: _p.textMuted)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_rs(s.total),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: s.isReturned ? _p.red : _p.teal)),
                  if (_admin && profit != null)
                    Text('${Loc.t('Profit', 'منافع')}: ${_rs(profit)}', style: TextStyle(fontSize: 10.5, color: _p.textMuted)),
                ]),
              ),
              icon(Icons.print_outlined, _p.navy, () => _print(s)),
              if (_admin && !s.isReturned) icon(Icons.edit_outlined, _p.teal, () => _edit(s)),
              if (_admin && !s.isReturned) icon(Icons.undo, _p.teal, () => _return(s)),
              if (_admin) icon(Icons.delete_outline, _p.red, () => _delete(s)),
            ]),
          ),
        ),
      ),
      if (_expanded.contains(s.invoice) && items != null)
        if (items.isEmpty)
          _itemLine(Loc.t('No items on this sale.', 'اس سیل میں کوئی آئٹم نہیں۔'), muted: true)
        else
          for (final si in items)
            _itemLine('${si.product}  —  ${_qty(si.qty)} ${si.unit} × Rs ${_qty(si.unitPrice)} = ${_rs(si.amount)}'),
    ];
  }

  Widget _itemLine(String text, {bool muted = false}) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 6),
        child: Text(text, style: TextStyle(fontSize: 12, color: muted ? _p.textMuted : _p.textDark)),
      );
}
