import 'package:flutter/material.dart';

import '../db/category_unit_repository.dart';
import '../db/product_repository.dart';
import '../models/category_unit.dart' as models;
import '../models/product.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../utils/rate_list_export.dart';
import '../widgets/premium_header.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/unit_dialog.dart';
import '../theme/theme_manager.dart';
import '../services/session.dart';
import '../widgets/role_guard.dart';

class ProductScreen extends StatefulWidget {
  /// Items screen se edit: is barcode ka product form mein khul jata hai
  /// (Kotlin ProductActivity.EXTRA_EDIT_BARCODE).
  final String? editBarcode;
  const ProductScreen({super.key, this.editBarcode});

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _tagCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  final _wholesaleCtrl = TextEditingController();
  final _bulkPriceCtrl = TextEditingController();
  final _bulkQtyCtrl = TextEditingController();
  final _wBulkPriceCtrl = TextEditingController();
  final _wBulkQtyCtrl = TextEditingController();
  final _saleCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _reorderCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  String _primaryUnit = 'pcs';
  String _secondaryUnit = 'None';
  double _secondaryQty = 0.0;
  String _tertiaryUnit = 'None';
  double _tertiaryQty = 0.0;
  // Manual default-unit choices (-1 = Auto), set from the unit dialog.
  int _defaultUnitIndex = -1;
  int _quickSaleDefaultUnitIndex = -1;
  String _openingStockUnit = 'pcs';

  Product? _editing;
  String _search = '';
  bool _showList = false;
  String? _justSavedBarcode;

  @override
  void initState() {
    super.initState();
    final b = widget.editBarcode;
    if (b != null) {
      ProductRepository.instance.find(b).then((p) {
        if (p != null && mounted) _loadForEdit(p);
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _tagCtrl.dispose();
    _costCtrl.dispose();
    _wholesaleCtrl.dispose();
    _bulkPriceCtrl.dispose();
    _bulkQtyCtrl.dispose();
    _wBulkPriceCtrl.dispose();
    _wBulkQtyCtrl.dispose();
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

  String get _stockPreview {
    // Edit mode: stock field mein SMALLEST unit ki mehfooz ginti hoti hai — use dobara "naya qty"
    // samajh kar convert nahi karna (7000 gram ko 7000 Kg bana deta tha). Kotlin
    // updateOpeningStockPreview() jaisa: sirf asal maujooda stock dikhao.
    final existing = _editing;
    if (existing != null) {
      return Loc.t('Current stock: ${existing.formatStockBreakdown()}',
          'موجودہ اسٹاک: ${existing.formatStockBreakdown()}');
    }
    final q = double.tryParse(_stockCtrl.text.trim()) ?? 0.0;
    if (q <= 0) return '';
    final smallest = _openingStockToSmallest(q, _openingStockUnit);
    final draft = _draftProduct(stockValue: smallest);
    return Loc.t(
      'Stored stock: ${_trimNum(smallest)} ${draft.smallestUnitName()}  •  Display: ${draft.formatStockBreakdown()}',
      'محفوظ اسٹاک: ${_trimNum(smallest)} ${draft.smallestUnitName()}  •  ڈسپلے: ${draft.formatStockBreakdown()}',
    );
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
      initialDefaultUnitIndex: _defaultUnitIndex,
      initialQuickSaleDefaultUnitIndex: _quickSaleDefaultUnitIndex,
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
      _defaultUnitIndex = result.defaultUnitIndex;
      _quickSaleDefaultUnitIndex = result.quickSaleDefaultUnitIndex;
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
      _tagCtrl.text = p.searchTag;
      _primaryUnit = p.unit.isEmpty ? 'pcs' : p.unit;
      _secondaryUnit = p.secondaryUnit.isEmpty ? 'None' : p.secondaryUnit;
      _secondaryQty = p.secondaryUnitQty;
      _tertiaryUnit = p.tertiaryUnit.isEmpty ? 'None' : p.tertiaryUnit;
      _tertiaryQty = p.tertiaryUnitQty;
      _defaultUnitIndex = p.defaultUnitIndex;
      _quickSaleDefaultUnitIndex = p.quickSaleDefaultUnitIndex;
      _openingStockUnit = _primaryUnit;
      _costCtrl.text = p.cost > 0 ? p.cost.toString() : '';
      _wholesaleCtrl.text = p.wholesalePrice > 0 ? p.wholesalePrice.toString() : '';
      _bulkPriceCtrl.text = p.bulkPrice > 0 ? p.bulkPrice.toString() : '';
      _bulkQtyCtrl.text = p.bulkMinQty > 0 ? _trimNum(p.bulkMinQty) : '';
      _wBulkPriceCtrl.text = p.wholesaleBulkPrice > 0 ? p.wholesaleBulkPrice.toString() : '';
      _wBulkQtyCtrl.text = p.wholesaleBulkMinQty > 0 ? _trimNum(p.wholesaleBulkMinQty) : '';
      _saleCtrl.text = p.salePrice > 0 ? p.salePrice.toString() : '';
      _reorderCtrl.text = p.reorderLevel > 0 ? _trimNum(p.reorderLevel) : '';
      _stockCtrl.text = _trimNum(p.stock);
    });
  }

  void _clearForm() {
    setState(() {
      _nameCtrl.clear();
      _categoryCtrl.clear();
      _tagCtrl.clear();
      _costCtrl.clear();
      _wholesaleCtrl.clear();
      _bulkPriceCtrl.clear();
      _bulkQtyCtrl.clear();
      _wBulkPriceCtrl.clear();
      _wBulkQtyCtrl.clear();
      _saleCtrl.clear();
      _stockCtrl.clear();
      _reorderCtrl.clear();
      _primaryUnit = 'pcs';
      _secondaryUnit = 'None';
      _secondaryQty = 0.0;
      _tertiaryUnit = 'None';
      _tertiaryQty = 0.0;
      _defaultUnitIndex = -1;
      _quickSaleDefaultUnitIndex = -1;
      _openingStockUnit = 'pcs';
      _editing = null;
    });
  }

  Future<void> _save({bool confirmedDuplicate = false}) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast(Loc.t('Product Name is required', 'پروڈکٹ کا نام ضروری ہے'));
      return;
    }

    // Kotlin "Possible Duplicate Item": same naam (case-insensitive) ka doosra product ho to confirm.
    if (!confirmedDuplicate) {
      final all = await ProductRepository.instance.listAll();
      if (!mounted) return;
      Product? dupe;
      for (final p in all) {
        if (p.name.toLowerCase() == name.toLowerCase() && p.barcode != _editing?.barcode) {
          dupe = p;
          break;
        }
      }
      if (dupe != null) {
        final d = dupe;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(Loc.t('Possible Duplicate Item', 'ممکنہ ڈپلیکیٹ آئٹم')),
            content: Text(Loc.t(
              'An item named "${d.name}" already exists (stock: ${_trimNum(d.stock)} ${d.unit}).\n\n'
                  'Saving this as a new item will make two products with the same name, which can cause the wrong one to be picked during Sale/Purchase.\n\n'
                  'Save this one anyway?',
              '"${d.name}" نام کا آئٹم پہلے سے موجود ہے (اسٹاک: ${_trimNum(d.stock)} ${d.unit})۔\n\n'
                  'اسے نئے آئٹم کے طور پر محفوظ کرنے سے ایک ہی نام کے دو پروڈکٹس بن جائیں گے، جس سے Sale/Purchase کے دوران غلط آئٹم منتخب ہو سکتا ہے۔\n\n'
                  'پھر بھی محفوظ کریں؟',
            )),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
              TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(Loc.t('Save Anyway', 'پھر بھی محفوظ کریں'))),
            ],
          ),
        );
        if (ok != true) return;
        if (!mounted) return;
      }
    }

    if (_primaryUnit.trim().isEmpty) {
      _toast(Loc.t('Select a unit', 'یونٹ منتخب کریں'));
      return;
    }
    if (_secondaryUnit != 'None' && (_secondaryUnit == _primaryUnit || _secondaryQty <= 0)) {
      _toast(Loc.t('Secondary unit/conversion is invalid', 'ثانوی یونٹ یا conversion غلط ہے'));
      return;
    }
    if (_tertiaryUnit != 'None' &&
        (_secondaryUnit == 'None' || _tertiaryUnit == _secondaryUnit || _tertiaryQty <= 0)) {
      _toast(Loc.t('Tertiary unit/conversion is invalid', 'تیسرے یونٹ یا conversion غلط ہے'));
      return;
    }

    final existing = _editing;
    final barcode = existing?.barcode ?? 'P${DateTime.now().millisecondsSinceEpoch}';
    final category = _categoryCtrl.text.trim().isEmpty ? 'General' : _categoryCtrl.text.trim();

    double resolvedStock;
    double resolvedOpeningStock;
    if (existing != null) {
      // Unit ladder badli ho to purana stock naye smallest unit mein rescale (Kotlin unit-ladder rescale FIX).
      final r = rescaleStockForLadderChange(existing, _draftProduct());
      resolvedStock = r.stock;
      resolvedOpeningStock = r.openingStock;
    } else {
      final openingQty = parseMoneyOrWarn(context, _stockCtrl.text, 'Opening Stock', 'ابتدائی اسٹاک');
      if (openingQty == null) return;
      resolvedStock = _openingStockToSmallest(openingQty, _openingStockUnit);
      resolvedOpeningStock = resolvedStock;
    }

    if (existing == null) {
      final probe = _draftProduct(stockValue: resolvedStock);
      if (!probe.isValidSmallestQty(resolvedStock)) {
        _toast(Loc.t(
          'Opening stock does not convert to a whole ${probe.smallestUnitName()}',
          'ابتدائی اسٹاک ${probe.smallestUnitName()} کی مکمل تعداد میں تبدیل نہیں ہوتا',
        ));
        return;
      }
    }

    // Khali = 0, lekin ghalat text (jaise "12abc") save rok kar batata hai — chupke 0 nahi banta.
    final costVal = parseMoneyOrWarn(context, _costCtrl.text, 'Cost Price', 'لاگت قیمت');
    if (costVal == null) return;
    final saleVal = parseMoneyOrWarn(context, _saleCtrl.text, 'Sale Price', 'فروخت قیمت');
    if (saleVal == null) return;
    final wholesaleVal = parseMoneyOrWarn(context, _wholesaleCtrl.text, 'Wholesale Price', 'ہول سیل قیمت');
    if (wholesaleVal == null) return;
    final bulkPriceVal = parseMoneyOrWarn(context, _bulkPriceCtrl.text, 'Bulk Rate', 'بلک قیمت');
    if (bulkPriceVal == null) return;
    final bulkQtyVal = parseMoneyOrWarn(context, _bulkQtyCtrl.text, 'Bulk Min Qty', 'بلک کم از کم مقدار');
    if (bulkQtyVal == null) return;
    final wBulkPriceVal = parseMoneyOrWarn(context, _wBulkPriceCtrl.text, 'Wholesale Bulk Rate', 'تھوک بلک قیمت');
    if (wBulkPriceVal == null) return;
    final wBulkQtyVal = parseMoneyOrWarn(context, _wBulkQtyCtrl.text, 'Wholesale Bulk Min Qty', 'تھوک بلک کم از کم مقدار');
    if (wBulkQtyVal == null) return;

    final product = Product(
      barcode: barcode,
      name: name,
      category: category,
      searchTag: _tagCtrl.text.trim(),
      cost: costVal,
      salePrice: saleVal,
      wholesalePrice: wholesaleVal,
      bulkPrice: bulkPriceVal,
      bulkMinQty: bulkQtyVal,
      wholesaleBulkPrice: wBulkPriceVal,
      wholesaleBulkMinQty: wBulkQtyVal,
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
      // Manual default-unit choices (unit dialog). Loaded from the product on
      // edit, so saving never silently resets them.
      defaultUnitIndex: _defaultUnitIndex,
      quickSaleDefaultUnitIndex: _quickSaleDefaultUnitIndex,
    );

    try {
      final categories = await CategoryRepository.instance.listAll();
      // CategoryRepository.insert ab sync queue mein bhi likhta hai (Kotlin enqueueCategory).
      if (category != 'General' && !categories.any((c) => c.name.toLowerCase() == category.toLowerCase())) {
        await CategoryRepository.instance.insert(models.Category(category));
      }

      await ProductRepository.instance.upsert(product, isNew: existing == null);
      // Sync: ProductRepository.upsert khud sync_queue mein likhta hai (Kotlin enqueue + opening stock delta).

      if (!mounted) return;
      _toast(existing != null
          ? Loc.t('Product updated', 'پروڈکٹ اپ ڈیٹ ہو گئی')
          : Loc.t('Product saved', 'پروڈکٹ محفوظ ہو گئی'));
      _justSavedBarcode = barcode;
      _clearForm();
    } catch (e) {
      if (!mounted) return;
      _toast('Could not save product: $e');
    }
  }

  Future<void> _confirmDelete(Product product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Delete Product', 'پروڈکٹ حذف کریں')),
        content: Text(Loc.t(
          'Delete "${product.name}"? This cannot be undone.',
          '"${product.name}" کو حذف کریں؟ یہ واپس نہیں ہو سکتا۔',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(Loc.t('Delete', 'حذف کریں'), style: TextStyle(color: ThemeManager.palette.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ProductRepository.instance.delete(product);
      // Sync: ProductRepository.delete khud "delete" (tombstone) queue karta hai.
      if (!mounted) return;
      if (_editing?.barcode == product.barcode) _clearForm();
      _toast(Loc.t('Product deleted', 'پروڈکٹ حذف ہو گئی'));
    } catch (e) {
      if (!mounted) return;
      _toast('Could not delete product: $e');
    }
  }

  /// Kotlin exportRateListCsv(): sab products ki Rate List CSV -> Downloads copy + spreadsheet app mein open.
  Future<void> _exportRateList() async {
    try {
      final all = await ProductRepository.instance.listAll();
      if (all.isEmpty) {
        if (mounted) _toast(Loc.t('No products to export', 'کوئی پروڈکٹ موجود نہیں'));
        return;
      }
      await exportRateList(all);
    } catch (e) {
      if (mounted) _toast(Loc.t('Export failed', 'ایکسپورٹ ناکام'));
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  List<Product> _filter(List<Product> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((p) => p.matchesQuery(q) || p.category.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Kotlin ProductActivity jaisa: screen ke andar bhi role check (callers ke RoleGuard par bharosa nahi).
    if (!Session.isAdmin) return const RoleGuard(allowed: {'admin'}, child: SizedBox());
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
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
                      title: Loc.t('Add / Edit Product', 'پروڈکٹ شامل / تبدیل کریں'),
                      subtitle: Loc.t('Inventory Management', 'انوینٹری مینجمنٹ'),
                      iconActions: [
                        PremiumHeaderIcon(
                          icon: Icons.description_outlined,
                          tooltip: Loc.t('Export Rate List', 'ریٹ لسٹ ایکسپورٹ کریں'),
                          onTap: _exportRateList,
                        ),
                      ],
                      actionLabel: Loc.t('View List', 'فہرست دیکھیں'),
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
            isEditing
                ? Loc.t('✏️  Editing: ${_editing!.name}', '✏️  ترمیم: ${_editing!.name}')
                : Loc.t('✚  New Product', '✚  نیا پروڈکٹ'),
            style: TextStyle(color: ThemeManager.palette.teal, fontSize: 14.5, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isEditing) ...[
          GradientButton(
            label: Loc.t('Delete', 'حذف کریں'),
            emoji: '🗑️',
            start: ThemeManager.palette.red,
            end: ThemeManager.palette.redDark,
            onTap: () => _confirmDelete(_editing!),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _clearForm,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(color: ThemeManager.palette.textMuted, borderRadius: BorderRadius.circular(30)),
              child: Text(Loc.t('✕  Cancel Edit', '✕  ترمیم منسوخ'), style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNameCard() {
    return PremiumCard(
      accentTop: ThemeManager.palette.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(emoji: '🏷️', label: Loc.t('Product Name', 'پروڈکٹ کا نام'), accent: ThemeManager.palette.teal),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: ThemeManager.palette.fieldFill,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ThemeManager.palette.border, width: 1.2),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark),
                    decoration: InputDecoration(
                      hintText: Loc.t('Product Name', 'پروڈکٹ کا نام'),
                      hintStyle: TextStyle(color: ThemeManager.palette.textMuted, fontWeight: FontWeight.normal),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                GradientButton(
                  label: Loc.t('Select Unit', 'یونٹ منتخب کریں'),
                  emoji: '📏',
                  start: ThemeManager.palette.teal,
                  end: ThemeManager.palette.tealDark,
                  onTap: _openUnitDialog,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tagCtrl,
            decoration: InputDecoration(
              hintText: Loc.t('English search tag (optional) — e.g. Aloo Bukhara', 'انگریزی سرچ ٹیگ (اختیاری) — مثلاً Aloo Bukhara'),
              hintStyle: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 13),
              filled: true,
              fillColor: ThemeManager.palette.fieldFill,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: ThemeManager.palette.border)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard() {
    return PremiumCard(
      accentTop: ThemeManager.palette.purple,
      child: StreamBuilder<List<models.Category>>(
        stream: CategoryRepository.instance.watchAll(),
        builder: (context, snapshot) {
          final categories = snapshot.data ?? const <models.Category>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionLabel(emoji: '🗂️', label: Loc.t('Category', 'کیٹیگری'), accent: ThemeManager.palette.purple),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: ThemeManager.palette.fieldFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ThemeManager.palette.border, width: 1.2),
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
                      style: TextStyle(fontSize: 15, color: ThemeManager.palette.textDark),
                      decoration: InputDecoration(
                        hintText: Loc.t('Type or pick a category', 'کیٹیگری لکھیں یا چنیں'),
                        hintStyle: TextStyle(color: ThemeManager.palette.textMuted),
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
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Text(Loc.t('✚  Add New Category', '✚  نئی کیٹیگری'), style: TextStyle(color: ThemeManager.palette.teal, fontSize: 12.5, fontWeight: FontWeight.bold)),
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
        title: Text(Loc.t('New Category', 'نئی کیٹیگری')),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: Text(Loc.t('Add', 'شامل کریں'))),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await CategoryRepository.instance.insert(models.Category(value));
    _toast(Loc.t('Category added', 'کیٹیگری شامل ہو گئی'));
  }

  Widget _buildPricingCard() {
    return PremiumCard(
      accentTop: ThemeManager.palette.amber,
      child: StreamBuilder<List<models.UnitType>>(
        stream: UnitRepository.instance.watchAll(),
        builder: (context, snapshot) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionLabel(emoji: '💰', label: Loc.t('Pricing', 'قیمتیں'), accent: ThemeManager.palette.amber),
              PremiumLabeledField(emoji: '🛒', label: Loc.t('Purchase Rate', 'خریداری کی قیمت'), accent: ThemeManager.palette.amber, controller: _costCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '📦', label: Loc.t('Wholesale Sale Rate', 'تھوک فروخت کی قیمت'), accent: ThemeManager.palette.blue, controller: _wholesaleCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '🏪', label: Loc.t('Retail Sale Rate', 'پرچون فروخت کی قیمت'), accent: ThemeManager.palette.teal, controller: _saleCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '🧺', label: Loc.t('Bulk Rate (retail, optional)', 'بلک قیمت (پرچون، اختیاری)'), accent: ThemeManager.palette.blue, controller: _bulkPriceCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '📏', label: Loc.t('Bulk Min Qty (main unit)', 'بلک کم از کم مقدار (مین یونٹ)'), accent: ThemeManager.palette.blue, controller: _bulkQtyCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '📦', label: Loc.t('Wholesale Bulk Rate (optional)', 'تھوک بلک قیمت (اختیاری)'), accent: ThemeManager.palette.blue, controller: _wBulkPriceCtrl),
              const SizedBox(height: 12),
              PremiumLabeledField(emoji: '📏', label: Loc.t('Wholesale Bulk Min Qty (main unit)', 'تھوک بلک کم از کم مقدار (مین یونٹ)'), accent: ThemeManager.palette.blue, controller: _wBulkQtyCtrl),
              const SizedBox(height: 12),
              _buildOpeningStockRow(),
              if (_stockPreview.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 6),
                  child: Text(_stockPreview, style: TextStyle(color: ThemeManager.palette.teal, fontSize: 11.5, fontWeight: FontWeight.bold)),
                ),
              if (_editing != null)
                Padding(
                  padding: EdgeInsets.only(top: 8, left: 6),
                  child: Text(
                    Loc.t('Stock is locked while editing — change it via Purchase/Sale instead.', 'ترمیم کے دوران اسٹاک لاک ہے — اسٹاک تبدیل کرنے کے لیے Purchase/Sale استعمال کریں۔'),
                    style: TextStyle(color: ThemeManager.palette.amber, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 12),
              PremiumLabeledField(
                emoji: '⚠️',
                label: Loc.t('Reorder Level (smallest unit)', 'ری آرڈر لیول (سب سے چھوٹی یونٹ)'),
                accent: ThemeManager.palette.red,
                controller: _reorderCtrl,
              ),
              Padding(
                padding: EdgeInsets.only(top: 6, left: 6),
                child: Text(
                  Loc.t('Alert when stock falls to/below this many smallest units (e.g. pcs). Leave 0 for no alert.', 'جب اسٹاک اس تعداد (سب سے چھوٹی یونٹ) تک یا کم ہو جائے تو الرٹ کریں۔ الرٹ نہ چاہیے تو 0 رہنے دیں۔'),
                  style: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 11),
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
        color: ThemeManager.palette.fieldFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ThemeManager.palette.border, width: 1.2),
      ),
      child: Row(
        children: [
          BadgeIcon(emoji: '🔢', color: ThemeManager.palette.navyInk),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Loc.t('OPENING STOCK', 'ابتدائی اسٹاک'), style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk, letterSpacing: 0.3)),
                TextField(
                  controller: _stockCtrl,
                  enabled: _editing == null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark),
                  decoration: InputDecoration(hintText: '0', hintStyle: TextStyle(color: ThemeManager.palette.textMuted), border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
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
        SectionLabel(emoji: '🗃️', label: Loc.t('Products', 'پروڈکٹس'), accent: ThemeManager.palette.navyInk),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: ThemeManager.palette.cardWhite,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: ThemeManager.palette.border, width: 1.2),
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
                    hintText: Loc.t('Search products by name or category…', 'نام یا کیٹیگری سے پروڈکٹ تلاش کریں…'),
                    hintStyle: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 14.5),
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
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('✕', style: TextStyle(color: ThemeManager.palette.textMuted, fontWeight: FontWeight.bold)),
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
                  color: ThemeManager.palette.cardWhite,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ThemeManager.palette.border, width: 1.2),
                ),
                child: Column(
                  children: [
                    Text('🔍', style: TextStyle(fontSize: 26)),
                    SizedBox(height: 10),
                    Text(Loc.t('No matching products', 'کوئی مماثل پروڈکٹ نہیں ملی'), style: TextStyle(color: ThemeManager.palette.textMuted, fontSize: 13)),
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
        color: ThemeManager.palette.cardWhite,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          child: GradientButton(
            label: _editing != null
                ? Loc.t('UPDATE PRODUCT', 'پروڈکٹ اپ ڈیٹ کریں')
                : Loc.t('SAVE PRODUCT', 'پروڈکٹ محفوظ کریں'),
            emoji: '💾',
            start: ThemeManager.palette.navy,
            end: ThemeManager.palette.navyLight,
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
    final accent = isJustSaved ? ThemeManager.palette.teal : ThemeManager.palette.navyInk;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isJustSaved ? ThemeManager.palette.savedHighlightBg : ThemeManager.palette.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isJustSaved ? ThemeManager.palette.teal : ThemeManager.palette.border, width: 1.2),
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
                  gradient: LinearGradient(colors: [accent, isJustSaved ? ThemeManager.palette.tealDark : ThemeManager.palette.navyLight]),
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
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: isJustSaved ? ThemeManager.palette.teal : ThemeManager.palette.textDark),
                    ),
                    Text(product.category, style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [ThemeManager.palette.teal, ThemeManager.palette.tealDark]),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text('📊 ${product.formatStockBreakdown()}', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: ThemeManager.palette.border),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _priceChip('🛒', Loc.t('Purchase', 'خریداری'), product.cost, ThemeManager.palette.textMuted)),
              const SizedBox(width: 6),
              Expanded(child: _priceChip('📦', Loc.t('Wholesale', 'تھوک'), product.wholesalePrice, ThemeManager.palette.blue)),
              const SizedBox(width: 6),
              Expanded(child: _priceChip('🏪', Loc.t('Retail', 'پرچون'), product.salePrice, ThemeManager.palette.teal)),
            ],
          ),
          if (product.secondaryUnit.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: ThemeManager.palette.fieldFill, borderRadius: BorderRadius.circular(10), border: Border.all(color: ThemeManager.palette.border)),
              child: Text(
                '📏 1 ${product.unit} = ${_trimNum(product.secondaryUnitQty)} ${product.secondaryUnit}'
                '${product.tertiaryUnit.isNotEmpty && product.tertiaryUnitQty > 0 ? "   •   1 ${product.secondaryUnit} = ${_trimNum(product.tertiaryUnitQty)} ${product.tertiaryUnit}" : ""}',
                style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: GradientButton(
                  label: Loc.t('Edit', 'ترمیم کریں'),
                  emoji: '✏️',
                  start: ThemeManager.palette.navy,
                  end: ThemeManager.palette.navyLight,
                  onTap: onEdit,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GradientButton(
                  label: Loc.t('Delete', 'حذف کریں'),
                  emoji: '🗑️',
                  start: ThemeManager.palette.red,
                  end: ThemeManager.palette.redDark,
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
      decoration: BoxDecoration(color: ThemeManager.palette.fieldFill, borderRadius: BorderRadius.circular(12), border: Border.all(color: ThemeManager.palette.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$emoji $label', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textMuted)),
          const SizedBox(height: 3),
          Text(value.toStringAsFixed(2), style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: accent)),
        ],
      ),
    );
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}
