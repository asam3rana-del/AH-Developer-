import 'package:flutter/material.dart';

import '../db/category_unit_repository.dart';
import '../db/product_repository.dart';
import '../models/category_unit.dart' as models;
import '../models/product.dart';
import '../theme/app_colors.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/unit_dialog.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key});

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  final _wholesaleCtrl = TextEditingController();
  final _saleCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _reorderCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  String _primaryUnit = 'pcs';
  String _secondaryUnit = 'None';
  double _secondaryQty = 0.0;
  String _tertiaryUnit = 'None';
  double _tertiaryQty = 0.0;
  String _openingStockUnit = 'pcs';

  Product? _editing;
  String _search = '';
  bool _showList = false;
  String? _justSavedBarcode;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _costCtrl.dispose();
    _wholesaleCtrl.dispose();
    _saleCtrl.dispose();
    _stockCtrl.dispose();
    _reorderCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---- Unit ladder helpers (mirrors draftProduct()/openingStockToSmallest()) ----

  Product _draftProduct({double stockValue = 0.0}) => Product(
        barcode: '',
        name: '',
        stock: stockValue,
        unit: _primaryUnit,
        secondaryUnit: _secondaryUnit == 'None' ? '' : _secondaryUnit,
        secondaryUnitQty: _secondaryQty,
        tertiaryUnit: _tertiaryUnit == 'None' ? '' : _tertiaryUnit,
        tertiaryUnitQty: _tertiaryQty,
      );

  double _openingStockToSmallest(double qty, String unit) {
    if (qty <= 0) return 0.0;
    return _draftProduct().toSmallestUnits(qty, unit);
  }

  List<String> _currentUnitOptions() {
    final result = <String>[_primaryUnit];
    if (_secondaryUnit != 'None' && _secondaryUnit.isNotEmpty && !result.contains(_secondaryUnit)) {
      result.add(_secondaryUnit);
    }
    if (_tertiaryUnit != 'None' && _tertiaryUnit.isNotEmpty && !result.contains(_tertiaryUnit)) {
      result.add(_tertiaryUnit);
    }
    return result;
  }

  String get _selectUnitLabel {
    final b = StringBuffer('📏 $_primaryUnit');
    if (_secondaryUnit != 'None') b.write(' / $_secondaryUnit');
    if (_tertiaryUnit != 'None') b.write(' / $_tertiaryUnit');
    return b.toString();
  }

  String get _stockPreview {
    final q = double.tryParse(_stockCtrl.text.trim()) ?? 0.0;
    if (q <= 0) return '';
    final smallest = _openingStockToSmallest(q, _openingStockUnit);
    final draft = _draftProduct(stockValue: smallest);
    return 'Stored stock: ${_trimNum(smallest)} ${draft.smallestUnitName()}  •  Display: ${draft.formatStockBreakdown()}';
  }

  // ---- Actions ----

  Future<void> _openUnitDialog() async {
    final units = await UnitRepository.instance.listAll();
    if (!mounted) return;
    final result = await showUnitDialog(
      context,
      knownUnits: units.map((u) => u.name).toList(),
      initialPrimary: _primaryUnit,
      initialSecondary: _secondaryUnit,
      initialSecondaryQty: _secondaryQty,
      initialTertiary: _tertiaryUnit,
      initialTertiaryQty: _tertiaryQty,
    );
    if (result == null) return;

    for (final u in [result.primaryUnit, result.secondaryUnit, result.tertiaryUnit]) {
      if (u != 'None' && u.trim().isNotEmpty) {
        final exists = units.any((e) => e.name.toLowerCase() == u.toLowerCase());
        if (!exists) await UnitRepository.instance.insert(models.UnitType(u));
      }
    }

    setState(() {
      _primaryUnit = result.primaryUnit;
      _secondaryUnit = result.secondaryUnit;
      _secondaryQty = result.secondaryQty;
      _tertiaryUnit = result.tertiaryUnit;
      _tertiaryQty = result.tertiaryQty;
      if (_openingStockUnit.isEmpty || _openingStockUnit == _primaryUnit) {
        _openingStockUnit = _primaryUnit;
      }
      if (!_currentUnitOptions().contains(_openingStockUnit)) {
        _openingStockUnit = _primaryUnit;
      }
    });
  }

  void _loadForEdit(Product p) {
    setState(() {
      _editing = p;
      _nameCtrl.text = p.name;
      _categoryCtrl.text = p.category;
      _primaryUnit = p.unit.isEmpty ? 'pcs' : p.unit;
      _secondaryUnit = p.secondaryUnit.isEmpty ? 'None' : p.secondaryUnit;
      _secondaryQty = p.secondaryUnitQty;
      _tertiaryUnit = p.tertiaryUnit.isEmpty ? 'None' : p.tertiaryUnit;
      _tertiaryQty = p.tertiaryUnitQty;
      _openingStockUnit = _primaryUnit;
      _costCtrl.text = p.cost > 0 ? p.cost.toString() : '';
      _wholesaleCtrl.text = p.wholesalePrice > 0 ? p.wholesalePrice.toString() : '';
      _saleCtrl.text = p.salePrice > 0 ? p.salePrice.toString() : '';
      _reorderCtrl.text = p.reorderLevel > 0 ? _trimNum(p.reorderLevel) : '';
      _stockCtrl.text = _trimNum(p.stock);
    });
  }

  void _clearForm() {
    setState(() {
      _nameCtrl.clear();
      _categoryCtrl.clear();
      _costCtrl.clear();
      _wholesaleCtrl.clear();
      _saleCtrl.clear();
      _stockCtrl.clear();
      _reorderCtrl.clear();
      _primaryUnit = 'pcs';
      _secondaryUnit = 'None';
      _secondaryQty = 0.0;
      _tertiaryUnit = 'None';
      _tertiaryQty = 0.0;
      _openingStockUnit = 'pcs';
      _editing = null;
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('Product Name is required');
      return;
    }
    if (_primaryUnit.trim().isEmpty) {
      _toast('Select a unit');
      return;
    }
    if (_secondaryUnit != 'None' && (_secondaryUnit == _primaryUnit || _secondaryQty <= 0)) {
      _toast('Secondary unit/conversion is invalid');
      return;
    }
    if (_tertiaryUnit != 'None' &&
        (_secondaryUnit == 'None' || _tertiaryUnit == _secondaryUnit || _tertiaryQty <= 0)) {
      _toast('Tertiary unit/conversion is invalid');
      return;
    }

    final existing = _editing;
    final barcode = existing?.barcode ?? 'P${DateTime.now().millisecondsSinceEpoch}';
    final category = _categoryCtrl.text.trim().isEmpty ? 'General' : _categoryCtrl.text.trim();

    double resolvedStock;
    double resolvedOpeningStock;
    if (existing != null) {
      resolvedStock = existing.stock;
      resolvedOpeningStock = existing.openingStock;
    } else {
      final openingQty = double.tryParse(_stockCtrl.text.trim()) ?? 0.0;
      resolvedStock = _openingStockToSmallest(openingQty, _openingStockUnit);
      resolvedOpeningStock = resolvedStock;
    }

    if (existing == null) {
      final probe = _draftProduct(stockValue: resolvedStock);
      if (!probe.isValidSmallestQty(resolvedStock)) {
        _toast('Opening stock does not convert to a whole ${probe.smallestUnitName()}');
        return;
      }
    }

    final product = Product(
      barcode: barcode,
      name: name,
      category: category,
      cost: double.tryParse(_costCtrl.text.trim()) ?? 0.0,
      salePrice: double.tryParse(_saleCtrl.text.trim()) ?? 0.0,
      wholesalePrice: double.tryParse(_wholesaleCtrl.text.trim()) ?? 0.0,
      stock: resolvedStock,
      openingStock: resolvedOpeningStock,
      unit: _primaryUnit,
      secondaryUnit: _secondaryUnit == 'None' ? '' : _secondaryUnit,
      secondaryUnitQty: _secondaryUnit == 'None' ? 0.0 : _secondaryQty,
      tertiaryUnit: _tertiaryUnit == 'None' ? '' : _tertiaryUnit,
      tertiaryUnitQty: _tertiaryUnit == 'None' ? 0.0 : _tertiaryQty,
      reorderLevel: (double.tryParse(_reorderCtrl.text.trim()) ?? 0.0).clamp(0.0, double.infinity),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      dirty: true,
    );

    final categories = await CategoryRepository.instance.listAll();
    if (category != 'General' && !categories.any((c) => c.name.toLowerCase() == category.toLowerCase())) {
      await CategoryRepository.instance.insert(models.Category(category));
    }

    await ProductRepository.instance.upsert(product);
    // TODO: enqueue into your sync_queue table + trigger the sync worker here,
    // mirroring SyncQueueHelper.enqueue()/.trigger() in the Kotlin app, once
    // the Firestore sync layer is wired up for this screen.

    _toast(existing != null ? 'Product updated' : 'Product saved');
    _justSavedBarcode = barcode;
    _clearForm();
  }

  Future<void> _confirmDelete(Product product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text('Delete "${product.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ProductRepository.instance.delete(product);
    // TODO: enqueue a "delete" sync_queue entry here, mirroring the Kotlin
    // confirmDeleteProduct()'s SyncQueueHelper.enqueue(..., "delete", "{}").

    if (_editing?.barcode == product.barcode) _clearForm();
    _toast('Product deleted');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  List<Product> _filter(List<Product> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((p) => p.name.toLowerCase().contains(q) || p.category.toLowerCase().contains(q)).toList();
  }

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
                    PremiumHeader(
                      title: 'Add / Edit Product',
                      subtitle: 'Inventory Management',
                      actionLabel: 'View List',
                      actionEmoji: '📋',
                      onActionTap: () => setState(() => _showList = true),
                    ),
                    _buildTitleRow(),
                    const SizedBox(height: 10),
                    _buildNameCard(),
                    _buildCategoryCard(),
                    _buildPricingCard(),
                    const SizedBox(height: 4),
                    if (_showList) _buildProductsSection(),
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

  Widget _buildTitleRow() {
    final isEditing = _editing != null;
    return Row(
      children: [
        Expanded(
          child: Text(
            isEditing ? '✏️  Editing: ${_editing!.name}' : '✚  New Product',
            style: const TextStyle(color: AppColors.teal, fontSize: 14.5, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isEditing) ...[
          GradientButton(
            label: 'Delete',
            emoji: '🗑️',
            start: AppColors.red,
            end: AppColors.redDark,
            onTap: () => _confirmDelete(_editing!),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _clearForm,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(color: AppColors.textMuted, borderRadius: BorderRadius.circular(30)),
              child: const Text('✕  Cancel Edit', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNameCard() {
    return PremiumCard(
      accentTop: AppColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel(emoji: '🏷️', label: 'Product Name', accent: AppColors.teal),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.fieldFill,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border, width: 1.2),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: AppColors.textDark),
                    decoration: InputDecoration(
                      hintText: 'Product Name',
                      hintStyle: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.normal),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                GradientButton(
                  label: 'Select Unit',
                  emoji: '📏',
                  start: AppColors.teal,
                  end: AppColors.tealDark,
                  onTap: _openUnitDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard() {
    return PremiumCard(
      accentTop: AppColors.purple,
      child: StreamBuilder<List<models.Category>>(
        stream: CategoryRepository.instance.watchAll(),
        builder: (context, snapshot) {
          final categories = snapshot.data ?? const <models.Category>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionLabel(emoji: '🗂️', label: 'Category', accent: AppColors.purple),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.fieldFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: Autocomplete<String>(
                  optionsBuilder: (text) {
                    if (text.text.isEmpty) return categories.map((c) => c.name);
                    return categories.map((c) => c.name).where((n) => n.toLowerCase().contains(text.text.toLowerCase()));
                  },
                  onSelected: (v) => _categoryCtrl.text = v,
                  fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                    controller.text = _categoryCtrl.text;
                    controller.addListener(() => _categoryCtrl.text = controller.text);
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      style: const TextStyle(fontSize: 15, color: AppColors.textDark),
                      decoration: InputDecoration(
                        hintText: 'Type or pick a category',
                        hintStyle: TextStyle(color: AppColors.textMuted),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => _promptAddCategory(categories),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Text('✚  Add New Category', style: TextStyle(color: AppColors.teal, fontSize: 12.5, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _promptAddCategory(List<models.Category> existing) async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Category'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await CategoryRepository.instance.insert(models.Category(value));
    _toast('Category added');
  }

  Widget _buildPricingCard() {
    return PremiumCard(
      accentTop: AppColors.amber,
      child: StreamBuilder<List<models.UnitType>>(
        stream: UnitRepository.instance.watchAll(),
        builder: (context, snapshot) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionLabel(emoji: '💰', label: 'Pricing', accent: AppColors.amber),
              PremiumLabeledField(emoji: '🛒', label: 'Purchase Rate', accent: AppColors.amber, controller: _costCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '📦', label: 'Wholesale Sale Rate', accent: AppColors.blue, controller: _wholesaleCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '🏪', label: 'Retail Sale Rate', accent: AppColors.teal, controller: _saleCtrl),
              const SizedBox(height: 12),
              _buildOpeningStockRow(),
              if (_stockPreview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 6),
                  child: Text(_stockPreview, style: const TextStyle(color: AppColors.teal, fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              if (_editing != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8, left: 6),
                  child: Text(
                    'Stock is locked while editing — change it via Purchase/Sale instead.',
                    style: TextStyle(color: AppColors.amber, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 12),
              PremiumLabeledField(
                emoji: '⚠️',
                label: 'Reorder Level (smallest unit)',
                accent: AppColors.red,
                controller: _reorderCtrl,
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6, left: 6),
                child: Text(
                  'Alert when stock falls to/below this many smallest units (e.g. pcs). Leave 0 for no alert.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOpeningStockRow() {
    final options = _currentUnitOptions();
    final dropdownValue = options.contains(_openingStockUnit) ? _openingStockUnit : options.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.2),
      ),
      child: Row(
        children: [
          const BadgeIcon(emoji: '🔢', color: AppColors.navy),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('OPENING STOCK', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: AppColors.navy, letterSpacing: 0.3)),
                TextField(
                  controller: _stockCtrl,
                  enabled: _editing == null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textDark),
                  decoration: InputDecoration(hintText: '0', hintStyle: TextStyle(color: AppColors.textMuted), border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                ),
              ],
            ),
          ),
          DropdownButton<String>(
            value: dropdownValue,
            underline: const SizedBox.shrink(),
            items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
            onChanged: _editing != null
                ? null
                : (v) {
                    if (v != null) setState(() => _openingStockUnit = v);
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildProductsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        const SectionLabel(emoji: '🗃️', label: 'Products', accent: AppColors.navy),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: AppColors.cardWhite,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: AppColors.border, width: 1.2),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 1))],
          ),
          child: Row(
            children: [
              const Text('🔍  '),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText: 'Search products by name or category…',
                    hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 14.5),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (_search.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() {
                    _searchCtrl.clear();
                    _search = '';
                  }),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('✕', style: TextStyle(color: AppColors.textMuted, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
        StreamBuilder<List<Product>>(
          stream: ProductRepository.instance.watchAll(),
          builder: (context, snapshot) {
            final all = snapshot.data ?? const <Product>[];
            final list = _filter(all);
            if (list.isEmpty) {
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 30),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.cardWhite,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border, width: 1.2),
                ),
                child: const Column(
                  children: [
                    Text('🔍', style: TextStyle(fontSize: 26)),
                    SizedBox(height: 10),
                    Text('No matching products', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                  ],
                ),
              );
            }
            return Column(
              children: list.map((p) => _ProductCard(
                    product: p,
                    isJustSaved: p.barcode == _justSavedBarcode,
                    onEdit: () => _loadForEdit(p),
                    onDelete: () => _confirmDelete(p),
                  )).toList(),
            );
          },
        ),
        const SizedBox(height: 24),
      ],
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
            label: _editing != null ? 'UPDATE PRODUCT' : 'SAVE PRODUCT',
            emoji: '💾',
            start: AppColors.navy,
            end: AppColors.navyLight,
            radius: 16,
            padding: const EdgeInsets.symmetric(vertical: 18),
            onTap: _save,
          ),
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final Product product;
  final bool isJustSaved;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ProductCard({required this.product, required this.isJustSaved, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final accent = isJustSaved ? AppColors.teal : AppColors.navy;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isJustSaved ? AppColors.savedHighlightBg : AppColors.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isJustSaved ? AppColors.teal : AppColors.border, width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [accent, isJustSaved ? AppColors.tealDark : AppColors.navyLight]),
                ),
                child: Text(
                  product.name.trim().isNotEmpty ? product.name.trim()[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isJustSaved ? '✓ ${product.name}' : product.name,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: isJustSaved ? AppColors.teal : AppColors.textDark),
                    ),
                    Text(product.category, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppColors.teal, AppColors.tealDark]),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text('📊 ${product.formatStockBreakdown()}', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _priceChip('🛒', 'Purchase', product.cost, AppColors.textMuted)),
              const SizedBox(width: 6),
              Expanded(child: _priceChip('📦', 'Wholesale', product.wholesalePrice, AppColors.blue)),
              const SizedBox(width: 6),
              Expanded(child: _priceChip('🏪', 'Retail', product.salePrice, AppColors.teal)),
            ],
          ),
          if (product.secondaryUnit.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
              child: Text(
                '📏 1 ${product.unit} = ${_trimNum(product.secondaryUnitQty)} ${product.secondaryUnit}'
                '${product.tertiaryUnit.isNotEmpty && product.tertiaryUnitQty > 0 ? "   •   1 ${product.secondaryUnit} = ${_trimNum(product.tertiaryUnitQty)} ${product.tertiaryUnit}" : ""}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: GradientButton(
                  label: 'Edit',
                  emoji: '✏️',
                  start: AppColors.navy,
                  end: AppColors.navyLight,
                  onTap: onEdit,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GradientButton(
                  label: 'Delete',
                  emoji: '🗑️',
                  start: AppColors.red,
                  end: AppColors.redDark,
                  onTap: onDelete,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _priceChip(String emoji, String label, double value, Color accent) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.fieldFill, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$emoji $label', style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: AppColors.textMuted)),
          const SizedBox(height: 3),
          Text(value.toStringAsFixed(2), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: accent)),
        ],
      ),
    );
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}
