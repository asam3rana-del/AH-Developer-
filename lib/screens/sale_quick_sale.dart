import 'package:flutter/material.dart';

import '../models/party.dart';
import '../models/product.dart';
import '../utils/stock_policy.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart';
import '../widgets/autocomplete_options.dart';
import '../theme/theme_manager.dart';

/// What the Quick Sale dialog hands back when the cashier taps SAVE.
/// The caller saves it (SaleRepository.saveQuickSale) so it can also handle
/// the credit-limit confirm and re-submit the same request — mirrors
/// SaleActivity.PendingQuickSale in Kotlin.
class QuickSaleRequest {
  final Product product;
  final double qty;
  final double price;
  final String unit;
  final String customerName;

  const QuickSaleRequest({
    required this.product,
    required this.qty,
    required this.price,
    required this.unit,
    required this.customerName,
  });
}

/// Dart port of SaleQuickSale.kt (single-item fast checkout dialog).
///
/// [topNames] = best sellers of the last 30 days; they are listed first.
/// Uses the SYSTEM keyboard on purpose (the Kotlin dialog does too — the
/// custom NumericKeypad is not used on the Sale screens).
Future<QuickSaleRequest?> showQuickSaleDialog(
  BuildContext context, {
  required List<Product> products,
  required List<Customer> customers,
  required List<String> topNames,
}) {
  return showDialog<QuickSaleRequest>(
    context: context,
    builder: (_) => _QuickSaleDialog(products: products, customers: customers, topNames: topNames),
  );
}

class _QuickSaleDialog extends StatefulWidget {
  final List<Product> products;
  final List<Customer> customers;
  final List<String> topNames;

  const _QuickSaleDialog({required this.products, required this.customers, required this.topNames});

  @override
  State<_QuickSaleDialog> createState() => _QuickSaleDialogState();
}

class _QuickSaleDialogState extends State<_QuickSaleDialog> {
  final _itemCtrl = TextEditingController();
  final _itemFocus = FocusNode();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _customerCtrl = TextEditingController();
  final _customerFocus = FocusNode();

  Product? _selected;
  String _unit = '';
  // Rate per PRIMARY unit of whatever the cashier last typed, so switching
  // the unit re-converts their own rate instead of snapping back to the
  // standard one. Only updated from user typing (onChanged), never from the
  // programmatic price fill, so rounding can't drift.
  double _lastMainPrice = 0.0;
  String? _error;

  late final List<Product> _ordered = _orderProducts();

  List<Product> _orderProducts() {
    final byName = <String, Product>{};
    for (final p in widget.products) {
      byName.putIfAbsent(p.name.toLowerCase(), () => p);
    }
    final result = <Product>[];
    final seen = <String>{};
    for (final n in widget.topNames) {
      final p = byName[n.toLowerCase()];
      if (p != null && seen.add(p.name.toLowerCase())) result.add(p);
    }
    for (final p in widget.products) {
      if (seen.add(p.name.toLowerCase())) result.add(p);
    }
    return result;
  }

  @override
  void dispose() {
    _itemCtrl.dispose();
    _itemFocus.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _customerCtrl.dispose();
    _customerFocus.dispose();
    super.dispose();
  }

  Product? _findByName(String typed) {
    final t = typed.trim().toLowerCase();
    if (t.isEmpty) return null;
    for (final p in widget.products) {
      if (p.name.toLowerCase() == t) return p;
    }
    return null;
  }

  void _select(Product p) {
    setState(() {
      _selected = p;
      _lastMainPrice = 0.0;
      _unit = quickSaleDefaultUnitFor(p);
      if (_qtyCtrl.text.trim().isEmpty) _qtyCtrl.text = '1';
      _fillPrice();
      _error = null;
    });
  }

  void _fillPrice() {
    final p = _selected;
    if (p == null) return;
    final base = _lastMainPrice > 0 ? _lastMainPrice : p.salePrice;
    final price = p.fromPrimaryUnitRate(base, _unit);
    _priceCtrl.text = price > 0 ? price.toStringAsFixed(2) : '';
  }

  double get _qty => double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
  double get _price => double.tryParse(_priceCtrl.text.trim()) ?? 0.0;

  void _save() {
    // Resolve by the TYPED name (like Kotlin) so editing the name after a
    // pick can never sell the previously picked product by mistake.
    final product = _findByName(_itemCtrl.text);
    if (product == null) {
      setState(() => _error = 'Ye item product list mein nahi hai');
      return;
    }
    final qty = _qty;
    if (qty <= 0) {
      setState(() => _error = 'Quantity theek se likhen');
      return;
    }
    final unit = (_selected != null && _selected!.barcode == product.barcode && _unit.isNotEmpty)
        ? _unit
        : quickSaleDefaultUnitFor(product);
    final typedPrice = double.tryParse(_priceCtrl.text.trim());
    // Blank rate -> the product's standard rate converted into the chosen unit.
    final price = typedPrice ?? product.fromPrimaryUnitRate(product.salePrice, unit);

    final needed = product.toSmallestUnits(qty, unit);
    if (product.stock < needed && !StockPolicy.allowShortStock) {
      setState(() => _error =
          'Stock kam hai (available: ${formatQty(product.stock)} ${product.smallestUnitName()})');
      return;
    }

    Navigator.of(context).pop(QuickSaleRequest(
      product: product,
      qty: qty,
      price: price,
      unit: unit,
      customerName: _customerCtrl.text.trim(),
    ));
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: ThemeManager.palette.cardWhite,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ThemeManager.palette.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ThemeManager.palette.border)),
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted)),
      );

  @override
  Widget build(BuildContext context) {
    final p = _selected;
    final units = p != null ? saleUnitChoices(p) : const <String>['pcs'];
    final unitValue = units.contains(_unit) ? _unit : units.first;
    final total = _qty * _price;

    return AlertDialog(
      title: Text(Loc.t('Quick Sale', 'فوری سیل')),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(Loc.t('Item Name', 'آئٹم کا نام')),
              RawAutocomplete<Product>(
                textEditingController: _itemCtrl,
                focusNode: _itemFocus,
                displayStringForOption: (o) => o.name,
                optionsBuilder: (value) {
                  if (value.text.trim().isEmpty) return _ordered;
                  return _ordered.where((o) => o.matchesQuery(value.text));
                },
                onSelected: _select,
                fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textInputAction: TextInputAction.next,
                  decoration: _dec(Loc.t('Type to search…', 'تلاش کے لیے لکھیں…')),
                  onSubmitted: (v) {
                    final match = _findByName(v);
                    if (match != null) _select(match);
                  },
                ),
                optionsViewBuilder: (context, onSelected, options) =>
                    autocompleteOptionsView<Product>(context, onSelected, options, (o) => o.name),
              ),
              if (p != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 2),
                  child: Text(
                    Loc.t('Available: ${formatQty(availableInUnit(p, unitValue))} $unitValue',
                        'دستیاب: ${formatQty(availableInUnit(p, unitValue))} $unitValue'),
                    style: TextStyle(fontSize: 12, color: ThemeManager.palette.teal),
                  ),
                ),
              const SizedBox(height: 12),
              _label(Loc.t('Unit', 'یونٹ')),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: ThemeManager.palette.cardWhite, borderRadius: BorderRadius.circular(12), border: Border.all(color: ThemeManager.palette.border)),
                child: DropdownButton<String>(
                  value: unitValue,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                  onChanged: p == null
                      ? null
                      : (v) {
                          if (v == null) return;
                          setState(() {
                            _unit = v;
                            _fillPrice();
                          });
                        },
                ),
              ),
              const SizedBox(height: 12),
              _label(Loc.t('Quantity', 'مقدار')),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.next,
                      decoration: _dec('1'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => setState(() {
                      final next = _qty + 1;
                      _qtyCtrl.text = formatQty(next);
                    }),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: ThemeManager.palette.teal, shape: BoxShape.circle),
                      child: const Text('+', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _label(Loc.t('Rate', 'ریٹ')),
              TextField(
                controller: _priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.next,
                decoration: _dec(Loc.t('Auto-filled, editable', 'خودکار، قابل ترمیم')),
                onChanged: (v) {
                  final sel = _selected;
                  if (sel != null) {
                    _lastMainPrice = sel.toPrimaryUnitRate(double.tryParse(v.trim()) ?? 0.0, unitValue);
                  }
                  setState(() {});
                },
              ),
              const SizedBox(height: 12),
              _label(Loc.t('Customer (blank = Cash Sale)', 'کسٹمر (خالی = کیش سیل)')),
              RawAutocomplete<String>(
                textEditingController: _customerCtrl,
                focusNode: _customerFocus,
                optionsBuilder: (value) {
                  final q = value.text.trim().toLowerCase();
                  if (q.isEmpty) return const Iterable<String>.empty();
                  return widget.customers.map((c) => c.name).where((n) => n.toLowerCase().contains(q));
                },
                fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: _dec(Loc.t('Blank = Cash, Name = Credit', 'خالی = کیش، نام = ادھار')),
                ),
                optionsViewBuilder: (context, onSelected, options) =>
                    autocompleteOptionsView<String>(context, onSelected, options, (o) => o),
              ),
              const SizedBox(height: 12),
              Text('${Loc.t('Total', 'ٹوٹل')}: Rs ${total.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: ThemeManager.palette.red, fontSize: 12.5, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(Loc.t('Cancel', 'منسوخ'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal),
          onPressed: _save,
          child: Text(Loc.t('SAVE', 'محفوظ کریں')),
        ),
      ],
    );
  }
}
