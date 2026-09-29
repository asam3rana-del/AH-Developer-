import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/product_repository.dart';
import '../db/purchase_repository.dart';
import '../db/supplier_repository.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../theme/app_colors.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';

class PurchaseScreen extends StatefulWidget {
  const PurchaseScreen({super.key});

  @override
  State<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends State<PurchaseScreen> {
  final _supplierCtrl = TextEditingController();
  final _itemCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  final _paidCtrl = TextEditingController();

  DateTime _purchaseDate = DateTime.now();
  Product? _pickedProduct;
  String _selectedUnit = '';
  final List<PurchaseLine> _lines = [];
  bool _saving = false;

  @override
  void dispose() {
    _supplierCtrl.dispose();
    _itemCtrl.dispose();
    _qtyCtrl.dispose();
    _rateCtrl.dispose();
    _paidCtrl.dispose();
    super.dispose();
  }

  double get _subtotal => _lines.fold(0.0, (sum, l) => sum + l.amount);

  List<String> _unitOptionsFor(Product p) => p.unitLadder().map((t) => t.unit).toList();

  void _onProductPicked(Product p) {
    setState(() {
      _pickedProduct = p;
      _itemCtrl.text = p.name;
      _selectedUnit = p.unit;
      _rateCtrl.text = p.cost > 0 ? p.cost.toString() : '';
    });
  }

  void _addLine() {
    final name = _itemCtrl.text.trim();
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0.0;
    final rate = double.tryParse(_rateCtrl.text.trim()) ?? 0.0;

    if (name.isEmpty) {
      _toast('Enter or pick an item');
      return;
    }
    if (qty <= 0) {
      _toast('Enter a valid quantity');
      return;
    }
    if (rate <= 0) {
      _toast('Enter a valid rate');
      return;
    }

    final unit = _selectedUnit.isEmpty ? (_pickedProduct?.unit ?? 'pcs') : _selectedUnit;
    final amount = qty * rate;

    setState(() {
      _lines.add(PurchaseLine(
        itemName: name,
        barcode: _pickedProduct?.barcode,
        qty: qty,
        unit: unit,
        rate: rate,
        amount: amount,
      ));
      _itemCtrl.clear();
      _qtyCtrl.clear();
      _rateCtrl.clear();
      _pickedProduct = null;
      _selectedUnit = '';
    });
  }

  void _removeLine(int index) => setState(() => _lines.removeAt(index));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _purchaseDate = picked);
  }

  Future<void> _save() async {
    final party = _supplierCtrl.text.trim();
    if (party.isEmpty) {
      _toast('Supplier name is required');
      return;
    }
    if (_lines.isEmpty) {
      _toast('Add at least one item');
      return;
    }

    final grandTotal = _subtotal.roundToDouble();
    final paidText = _paidCtrl.text.trim();
    final paid = double.tryParse(paidText) ?? 0.0;
    final isPaidEmpty = paidText.isEmpty || paid == 0.0;

    if (isPaidEmpty && grandTotal > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Credit Purchase'),
          content: Text(
            'You have not entered Paid Amount.\nTotal: Rs ${grandTotal.toStringAsFixed(0)}\n\n'
            'This bill will be saved as CREDIT (Udhaar).\nSupplier balance will increase.\n\nAre you sure?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Enter Payment')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Yes, Save as Credit')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() => _saving = true);
    try {
      final billNo = await PurchaseRepository.instance.savePurchase(
        supplierName: party,
        lines: _lines,
        amountPaid: paid,
        purchaseDateMillis: _purchaseDate.millisecondsSinceEpoch,
      );
      if (!mounted) return;
      _toast('Purchase saved: $billNo');
      setState(() {
        _lines.clear();
        _supplierCtrl.clear();
        _paidCtrl.clear();
        _purchaseDate = DateTime.now();
      });
    } catch (e) {
      _toast('Could not save purchase: $e');
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
                    const PremiumHeader(title: 'New Purchase', subtitle: 'Stock In / Supplier Bill'),
                    _buildSupplierCard(),
                    _buildDateCard(),
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

  Widget _buildSupplierCard() {
    return PremiumCard(
      accentTop: AppColors.teal,
      child: StreamBuilder<List<Supplier>>(
        stream: SupplierRepository.instance.watchAll(),
        builder: (context, snapshot) {
          final suppliers = snapshot.data ?? const <Supplier>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionLabel(emoji: '🧾', label: 'Supplier', accent: AppColors.teal),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: Autocomplete<String>(
                  optionsBuilder: (text) {
                    if (text.text.isEmpty) return suppliers.map((s) => s.name);
                    return suppliers.map((s) => s.name).where((n) => n.toLowerCase().contains(text.text.toLowerCase()));
                  },
                  onSelected: (v) => _supplierCtrl.text = v,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    controller.text = _supplierCtrl.text;
                    controller.addListener(() => _supplierCtrl.text = controller.text);
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        hintText: 'Type or pick a supplier — new names are added automatically',
                        border: InputBorder.none,
                        isDense: true,
                      ),
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

  Widget _buildDateCard() {
    return PremiumCard(
      accentTop: AppColors.blue,
      child: Row(
        children: [
          const BadgeIcon(emoji: '📅', color: AppColors.blue, size: 38),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PURCHASE DATE', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: AppColors.blue, letterSpacing: 0.3)),
                Text(DateFormat('dd MMM yyyy').format(_purchaseDate),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textDark)),
              ],
            ),
          ),
          GradientButton(label: 'Change', start: AppColors.blue, end: AppColors.navy, onTap: _pickDate),
        ],
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
                decoration: BoxDecoration(
                  color: AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: Autocomplete<Product>(
                  displayStringForOption: (p) => p.name,
                  optionsBuilder: (text) {
                    if (text.text.isEmpty) return const Iterable<Product>.empty();
                    return products.where((p) => p.matchesQuery(text.text));
                  },
                  onSelected: _onProductPicked,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    controller.text = _itemCtrl.text;
                    controller.addListener(() => _itemCtrl.text = controller.text);
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        hintText: 'Product name — pick from list or type a new one',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PremiumLabeledField(
                      emoji: '🔢',
                      label: 'Quantity',
                      accent: AppColors.amber,
                      controller: _qtyCtrl,
                      hint: '0',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.fieldFill,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border, width: 1.2),
                    ),
                    child: DropdownButton<String>(
                      value: unitValue,
                      underline: const SizedBox.shrink(),
                      items: unitOptions.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _selectedUnit = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '💵', label: 'Rate (per unit)', accent: AppColors.orange, controller: _rateCtrl),
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
                        Text(
                          '${_trimNum(line.qty)} ${line.unit}  ×  ${line.rate.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  Text(line.amount.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.teal)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: AppColors.red),
                    onPressed: () => _removeLine(i),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTotalsCard() {
    return PremiumCard(
      accentTop: AppColors.purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '💰', label: 'Payment', accent: AppColors.purple),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Subtotal', style: TextStyle(color: AppColors.textMuted)),
              Text(_subtotal.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.textDark)),
            ],
          ),
          const SizedBox(height: 12),
          PremiumLabeledField(emoji: '💵', label: 'Paid Amount (leave 0 for credit)', accent: AppColors.purple, controller: _paidCtrl),
        ],
      ),
    );
  }

  Widget _buildSaveBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _saving ? 'SAVING…' : 'SAVE PURCHASE',
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
