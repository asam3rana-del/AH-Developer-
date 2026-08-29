import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/customer_repository.dart';
import '../db/product_repository.dart';
import '../db/sale_repository.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../theme/app_colors.dart';
import '../utils/discount_calculator.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';

class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  final _customerCtrl = TextEditingController();
  final _itemCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();

  DateTime _saleDate = DateTime.now();
  bool _isWholesale = false;
  Product? _pickedProduct;
  String _selectedUnit = '';
  final List<SaleLine> _lines = [];
  bool _saving = false;

  @override
  void dispose() {
    _customerCtrl.dispose();
    _itemCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _discountCtrl.dispose();
    _paidCtrl.dispose();
    super.dispose();
  }

  double get _subtotal => _lines.fold(0.0, (sum, l) => sum + l.amount);

  BillTotals get _totals => DiscountCalculator.compute(
        _subtotal,
        double.tryParse(_discountCtrl.text.trim()) ?? 0.0,
        double.tryParse(_paidCtrl.text.trim()) ?? 0.0,
      );

  List<String> _unitOptionsFor(Product p) => p.unitLadder().map((t) => t.unit).toList();

  void _onProductPicked(Product p) {
    setState(() {
      _pickedProduct = p;
      _itemCtrl.text = p.name;
      _selectedUnit = p.unit;
      _refillAutoPrice();
    });
  }

  void _refillAutoPrice() {
    final p = _pickedProduct;
    if (p == null) return;
    final basePrice = _isWholesale ? p.wholesalePrice : p.salePrice;
    final unit = _selectedUnit.isEmpty ? p.unit : _selectedUnit;
    final price = p.fromPrimaryUnitRate(basePrice, unit);
    _priceCtrl.text = price > 0 ? price.toStringAsFixed(2) : '';
  }

  void _addLine() {
    final name = _itemCtrl.text.trim();
    final product = _pickedProduct;
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0.0;

    if (product == null || name.isEmpty) {
      _toast('Ye item product list mein nahi hai');
      return;
    }
    if (qty <= 0) {
      _toast('Quantity theek se likhen');
      return;
    }

    final unit = _selectedUnit.isEmpty ? product.unit : _selectedUnit;
    final neededSmallest = product.toSmallestUnits(qty, unit);

    if (!product.isValidSmallestQty(neededSmallest)) {
      _toast('Qty ($qty $unit) whole ${product.smallestUnitName()} mein convert nahi hoti');
      return;
    }

    final alreadyInCartSmallest = _lines
        .where((l) => l.barcode == product.barcode)
        .fold<double>(0, (sum, l) => sum + product.toSmallestUnits(l.qty, l.unit));
    final availableForThisAdd = product.stock - alreadyInCartSmallest;

    if (availableForThisAdd < neededSmallest) {
      _toast('Stock kam hai — "${product.name}" mein sirf ${_trimNum(availableForThisAdd)} ${product.smallestUnitName()} bacha hai');
      return;
    }

    final factor = product.smallestUnitFactor();
    final costPerSmallest = factor > 0 ? product.cost / factor : product.cost;
    final costForThisLine = costPerSmallest * neededSmallest;

    setState(() {
      _lines.add(SaleLine(
        itemName: name,
        barcode: product.barcode,
        qty: qty,
        unit: unit,
        unitPrice: price,
        cost: costForThisLine,
        amount: qty * price,
      ));
      _itemCtrl.clear();
      _qtyCtrl.clear();
      _priceCtrl.clear();
      _pickedProduct = null;
      _selectedUnit = '';
    });
  }

  void _removeLine(int index) => setState(() => _lines.removeAt(index));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _saleDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _saleDate = picked);
  }

  Future<void> _save() async {
    if (_lines.isEmpty) {
      _toast('Kam az kam ek item add karen');
      return;
    }

    final totals = _totals;
    if (totals.due > 0.009 && _customerCtrl.text.trim().isEmpty) {
      _toast('Due amount ke liye Customer zaroori hai');
      return;
    }

    setState(() => _saving = true);
    try {
      final invoice = await SaleRepository.instance.saveSale(
        lines: _lines,
        customerName: _customerCtrl.text.trim(),
        discountInput: double.tryParse(_discountCtrl.text.trim()) ?? 0.0,
        paidInput: double.tryParse(_paidCtrl.text.trim()) ?? 0.0,
        saleType: _isWholesale ? 'wholesale' : 'retail',
        saleDateMillis: _saleDate.millisecondsSinceEpoch,
      );
      if (!mounted) return;
      _toast('Sale saved: $invoice');
      setState(() {
        _lines.clear();
        _customerCtrl.clear();
        _discountCtrl.clear();
        _paidCtrl.clear();
        _saleDate = DateTime.now();
      });
    } catch (e) {
      _toast('Could not save sale: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const PremiumHeader(title: 'New Sale', subtitle: 'Stock Out / Customer Bill'),
                    _buildTopRow(),
                    _buildCustomerCard(),
                    _buildItemEntryCard(),
                    _buildLinesList(),
                    _buildTotalsCard(),
                  ],
                ),
              ),
            ),
            _buildSaveBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRow() {
    return PremiumCard(
      accentTop: AppColors.blue,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                const BadgeIcon(emoji: '📅', color: AppColors.blue, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('DATE', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: AppColors.blue)),
                      GestureDetector(
                        onTap: _pickDate,
                        child: Text(DateFormat('dd MMM yyyy').format(_saleDate),
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: AppColors.textDark)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(30), border: Border.all(color: AppColors.border)),
            child: ToggleButtons(
              isSelected: [!_isWholesale, _isWholesale],
              borderRadius: BorderRadius.circular(30),
              selectedColor: Colors.white,
              fillColor: AppColors.teal,
              color: AppColors.textMuted,
              constraints: const BoxConstraints(minHeight: 36, minWidth: 72),
              onPressed: (i) => setState(() {
                _isWholesale = i == 1;
                _refillAutoPrice();
              }),
              children: const [Text('Retail'), Text('Wholesale')],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerCard() {
    return PremiumCard(
      accentTop: AppColors.purple,
      child: StreamBuilder<List<Customer>>(
        stream: CustomerRepository.instance.watchAll(),
        builder: (context, snapshot) {
          final customers = snapshot.data ?? const <Customer>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionLabel(emoji: '🧑‍🤝‍🧑', label: 'Customer (optional unless on credit)', accent: AppColors.purple),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                child: Autocomplete<String>(
                  optionsBuilder: (text) {
                    if (text.text.isEmpty) return customers.map((c) => c.name);
                    return customers.map((c) => c.name).where((n) => n.toLowerCase().contains(text.text.toLowerCase()));
                  },
                  onSelected: (v) => _customerCtrl.text = v,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    controller.text = _customerCtrl.text;
                    controller.addListener(() => _customerCtrl.text = controller.text);
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(hintText: 'Walk-in customer — leave blank if fully paid', border: InputBorder.none, isDense: true),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildItemEntryCard() {
    return PremiumCard(
      accentTop: AppColors.amber,
      child: StreamBuilder<List<Product>>(
        stream: ProductRepository.instance.watchAll(),
        builder: (context, snapshot) {
          final products = snapshot.data ?? const <Product>[];
          final unitOptions = _pickedProduct != null ? _unitOptionsFor(_pickedProduct!) : <String>['pcs'];
          final unitValue = unitOptions.contains(_selectedUnit) ? _selectedUnit : unitOptions.first;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionLabel(emoji: '➕', label: 'Add Item', accent: AppColors.amber),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                child: Autocomplete<Product>(
                  displayStringForOption: (p) => p.name,
                  optionsBuilder: (text) {
                    if (text.text.isEmpty) return const Iterable<Product>.empty();
                    return products.where((p) => p.name.toLowerCase().contains(text.text.toLowerCase()));
                  },
                  onSelected: _onProductPicked,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    controller.text = _itemCtrl.text;
                    controller.addListener(() => _itemCtrl.text = controller.text);
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(hintText: 'Search a product to sell', border: InputBorder.none, isDense: true),
                    );
                  },
                ),
              ),
              if (_pickedProduct != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(
                    'In stock: ${_pickedProduct!.formatStockBreakdown()}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PremiumLabeledField(emoji: '🔢', label: 'Quantity', accent: AppColors.amber, controller: _qtyCtrl, hint: '0'),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                    child: DropdownButton<String>(
                      value: unitValue,
                      underline: const SizedBox.shrink(),
                      items: unitOptions.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _selectedUnit = v;
                          _refillAutoPrice();
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '💵', label: 'Unit Price (auto-filled, editable)', accent: AppColors.teal, controller: _priceCtrl),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: GradientButton(
                  label: 'Add to Bill',
                  emoji: '✚',
                  start: AppColors.teal,
                  end: AppColors.tealDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  onTap: _addLine,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLinesList() {
    if (_lines.isEmpty) return const SizedBox.shrink();
    return PremiumCard(
      accentTop: AppColors.navy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '🧾', label: 'Bill Items', accent: AppColors.navy),
          ..._lines.asMap().entries.map((entry) {
            final i = entry.key;
            final line = entry.value;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(line.itemName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDark)),
                        Text('${_trimNum(line.qty)} ${line.unit}  ×  ${line.unitPrice.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                  Text(line.amount.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.teal)),
                  IconButton(icon: const Icon(Icons.close, size: 18, color: AppColors.red), onPressed: () => _removeLine(i)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTotalsCard() {
    final totals = _totals;
    return PremiumCard(
      accentTop: AppColors.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '💰', label: 'Billing', accent: AppColors.purple),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Subtotal', style: TextStyle(color: AppColors.textMuted)),
              Text(totals.subtotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDark)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(emoji: '➖', label: 'Discount', accent: AppColors.orange, controller: _discountCtrl, onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDark)),
              Text(totals.total.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: AppColors.navy)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(emoji: '💵', label: 'Paid Amount', accent: AppColors.purple, controller: _paidCtrl, onChanged: (_) => setState(() {})),
          if (totals.due > 0.009)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Due: ${totals.due.toStringAsFixed(2)} — customer required', style: const TextStyle(color: AppColors.red, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(color: AppColors.cardWhite, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -3))]),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _saving ? 'SAVING…' : 'SAVE SALE',
            emoji: '💾',
            start: AppColors.navy,
            end: AppColors.navyLight,
            radius: 16,
            padding: const EdgeInsets.symmetric(vertical: 18),
            onTap: _saving ? () {} : _save,
          ),
        ),
      ),
    );
  }
}
