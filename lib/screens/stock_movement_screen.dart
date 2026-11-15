import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/product_repository.dart';
import '../db/stock_ledger.dart';
import '../models/product.dart';
import '../models/stock_movement.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';

enum StockMovementMode { stock, cost }

/// Mirrors StockMovementActivity.kt — ek hi screen dono ke liye: "Stock History" (har movement) aur
/// "Cost History" (sirf wo types jo Product.cost hila sakti hain, Kotlin EXTRA_MODE = stock / cost).
///
/// Flow: product search list -> product par tap -> uski movements (naya pehle). Back = wapas product list.
/// Role: admin/manager (Reports ke andar; movements mein cost hai, cashier ko nahi milta).
///
/// Farq (Kotlin se): Material icons; movement row par running "ledger total" nahi (Stock Audit ka kaam).
class StockMovementScreen extends StatelessWidget {
  final StockMovementMode mode;

  /// Diya ho to product list chhod kar seedha usi ki history khulti hai (Stock Audit card tap).
  final String? initialBarcode;
  const StockMovementScreen({super.key, this.mode = StockMovementMode.stock, this.initialBarcode});

  @override
  Widget build(BuildContext context) => RoleGuard(
        allowed: const {'admin', 'manager'},
        child: _StockMovementBody(mode: mode, initialBarcode: initialBarcode),
      );
}

class _StockMovementBody extends StatefulWidget {
  final StockMovementMode mode;
  final String? initialBarcode;
  const _StockMovementBody({required this.mode, this.initialBarcode});

  @override
  State<_StockMovementBody> createState() => _StockMovementBodyState();
}

class _StockMovementBodyState extends State<_StockMovementBody> {
  final _search = TextEditingController();
  final _dateFmt = DateFormat('dd MMM yyyy, hh:mm a');

  List<Product>? _products;
  Product? _selected;
  List<StockMovement>? _movements;
  String? _error;

  bool get _isCost => widget.mode == StockMovementMode.cost;
  AppPalette get _p => ThemeManager.palette;

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
    try {
      final list = await ProductRepository.instance.listAll();
      if (!mounted) return;
      setState(() {
        _products = list;
        _error = null;
      });
      final want = widget.initialBarcode;
      if (want != null && _selected == null) {
        final hit = list.where((p) => p.barcode == want);
        if (hit.isNotEmpty) await _select(hit.first);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _select(Product p) async {
    setState(() {
      _selected = p;
      _movements = null;
    });
    try {
      final rows = await StockLedger.forProduct(p.barcode, costOnly: _isCost);
      if (!mounted || _selected?.barcode != p.barcode) return;
      setState(() => _movements = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _back() {
    if (_selected != null) {
      setState(() {
        _selected = null;
        _movements = null;
      });
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String get _title => _isCost ? Loc.t('Cost History', 'لاگت کی تاریخ') : Loc.t('Stock History', 'اسٹاک کی تاریخ');

  String get _subtitle => _selected != null
      ? _selected!.name
      : _isCost
          ? Loc.t("How a product's cost changed over time", 'پروڈکٹ کی لاگت وقت کے ساتھ کیسے بدلی')
          : Loc.t('Every purchase, sale & adjustment', 'ہر خریداری، سیل اور ایڈجسٹمنٹ');

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return PopScope(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
            children: [
              _header(p),
              if (_selected == null) ...[
                _searchBox(p),
                const SizedBox(height: 14),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red)),
                )
              else if (_selected == null)
                ..._productList(p)
              else
                ..._movementList(p),
            ],
          ),
        ),
      ),
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
          IconButton(icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: _back),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: _isCost ? p.flatTealBg : p.flatBlueBg, shape: BoxShape.circle),
            child: Icon(_isCost ? Icons.trending_up : Icons.inventory_2,
                color: _isCost ? p.flatTealFg : p.flatBlueFg, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(_subtitle, style: TextStyle(fontSize: 11, color: p.textMuted)),
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
                hintText: Loc.t('Search item…', 'آئٹم تلاش کریں…'),
                hintStyle: TextStyle(color: p.textMuted),
              ),
            ),
          ),
        ]),
      );

  List<Widget> _productList(AppPalette p) {
    final all = _products;
    if (all == null) return const [Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))];
    final filtered = filterMovementProducts(all, _search.text);
    if (filtered.isEmpty) return [_emptyText(p, Loc.t('No items found', 'کوئی آئٹم نہیں ملا'))];
    return [
      for (final pr in filtered)
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _select(pr),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: _box(p, 16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pr.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
                  if (pr.category.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(pr.category, style: TextStyle(fontSize: 12, color: p.textMuted)),
                  ],
                ]),
              ),
              Icon(Icons.chevron_right, color: p.textMuted),
            ]),
          ),
        ),
    ];
  }

  List<Widget> _movementList(AppPalette p) {
    final rows = _movements;
    if (rows == null) return const [Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))];
    if (rows.isEmpty) return [_emptyText(p, Loc.t('No movements recorded yet', 'ابھی تک کوئی ریکارڈ نہیں'))];
    return [for (final m in rows) _movementCard(p, m)];
  }

  Widget _emptyText(AppPalette p, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text(text, style: TextStyle(fontSize: 13, color: p.textMuted))),
      );

  /// Kotlin typeLabel(): (label, accent).
  (String, Color) _typeLabel(AppPalette p, String type) {
    switch (type) {
      case MovementType.purchase:
        return (Loc.t('PURCHASE', 'خریداری'), p.flatTealFg);
      case MovementType.purchaseEdit:
        return (Loc.t('PURCHASE EDIT', 'خریداری میں ترمیم'), p.flatTealFg);
      case MovementType.purchaseReversal:
        return (Loc.t('PURCHASE REVERSED', 'خریداری واپس'), p.flatAmberFg);
      case MovementType.purchaseItemDelete:
        return (Loc.t('PURCHASE ITEM DELETED', 'خریداری آئٹم حذف'), p.red);
      case MovementType.purchaseReturn:
        return (Loc.t('PURCHASE RETURNED', 'خریداری واپس'), p.red);
      case MovementType.sale:
        return (Loc.t('SALE', 'سیل'), p.flatPurpleFg);
      case MovementType.saleEdit:
        return (Loc.t('SALE EDIT', 'سیل میں ترمیم'), p.flatPurpleFg);
      case MovementType.saleEditReversal:
        return (Loc.t('SALE EDIT (OLD REVERSED)', 'سیل ترمیم (پرانا واپس)'), p.flatAmberFg);
      case MovementType.saleReversal:
        return (Loc.t('SALE RETURNED/DELETED', 'سیل واپس/حذف'), p.flatAmberFg);
      case MovementType.saleItemDelete:
        return (Loc.t('SALE ITEM DELETED', 'سیل آئٹم حذف'), p.red);
      case MovementType.openingStock:
        return (Loc.t('OPENING STOCK', 'ابتدائی اسٹاک'), p.flatPurpleFg);
      case MovementType.damage:
        return (Loc.t('DAMAGE / LOSS', 'نقصان'), p.red);
      case MovementType.adjustment:
        return (Loc.t('ADJUSTMENT', 'ایڈجسٹمنٹ'), p.flatAmberFg);
      case MovementType.stockTake:
        return (Loc.t('STOCK TAKE', 'اسٹاک گنتی'), p.flatPurpleFg);
      case MovementType.auditReconcile:
        return (Loc.t('AUDIT FIX', 'آڈٹ درستگی'), p.flatTealFg);
      default:
        return (type, p.textMuted);
    }
  }

  Widget _movementCard(AppPalette p, StockMovement m) {
    final (label, accent) = _typeLabel(p, m.type);
    final positive = m.qty >= 0;
    final qtyText = '${positive ? '+' : ''}${formatMovementQty(m.qty)}${m.unit.isNotEmpty ? ' ${m.unit}' : ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: _box(p, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(8)),
            child: Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
          const Spacer(),
          Text(qtyText,
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: positive ? p.flatTealFg : p.red)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text('${Loc.t('Cost: ', 'لاگت: ')}Rs ${m.cost.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 13, color: p.textDark)),
          ),
          if (m.reference.isNotEmpty) Text('# ${m.reference}', style: TextStyle(fontSize: 12, color: p.textMuted)),
        ]),
        if (m.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(m.note, style: TextStyle(fontSize: 12, color: p.textMuted)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(m.createdAt)),
              style: TextStyle(fontSize: 11.5, color: p.textMuted)),
        ),
      ]),
    );
  }
}
