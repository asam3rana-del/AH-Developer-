import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/category_unit_repository.dart';
import '../db/items_repository.dart';
import '../db/product_repository.dart';
import '../models/category_unit.dart' as models;
import '../models/product.dart';
import '../services/session.dart';
import '../utils/loc.dart';
import '../utils/rate_list_csv.dart';
import '../widgets/premium_header.dart';
import '../widgets/role_guard.dart';
import 'bulk_default_unit_screen.dart';
import 'bulk_missing_rates_screen.dart';
import 'bulk_translate_screen.dart';
import 'product_screen.dart';
import '../theme/theme_manager.dart';

enum _Tab { products, categories, units }

/// Mirrors ItemsActivity.kt — "Items" hub: Products / Categories / Units tabs, har tab
/// ka apna search + "＋ Add ..." button. Categories mein row tap karke us category ke
/// products (Edit / Change Category / Delete) dekhe ja sakte hain; category rename/delete bhi.
/// Sab roles dekh sakte hain (Kotlin dashboard tile par koi gate nahi). Farq: cashier ko Purchase Price nahi
/// dikhta/load hota; add/edit/delete/rename/bulk tools sirf admin (PORTING_PLAN: Products admin-only).
///
/// "Import" (Rate List CSV): admin-only, file_picker se CSV chun kar unit/wholesale/retail/2nd+3rd unit
/// Code (barcode) ke hisaab se lagti hain (`lib/utils/rate_list_csv.dart`, `ItemsRepository.importRateList`).
/// "Translate" = BulkTranslateScreen (Phase 13; Duplicate Unit Fix + Merge Duplicate Products bhi wahin).
class ItemsScreen extends StatefulWidget {
  const ItemsScreen({super.key});

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  _Tab _tab = _Tab.products;
  List<Product> _products = [];
  List<models.Category> _categories = [];
  List<models.UnitType> _units = [];
  String _query = '';
  bool get _admin => Session.isAdmin;
  bool get _canSeeCost => Session.isAdminOrManager;
  String? _openCategory; // null = list; '' = "Items Not in Any Category"
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final p = await ProductRepository.instance.listAll();
    final c = await CategoryRepository.instance.listAll();
    final u = await UnitRepository.instance.listAll();
    if (!mounted) return;
    setState(() {
      _products = productsForRole(p, Session.role);
      _categories = c;
      _units = u;
    });
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  void _switchTab(_Tab t) {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _tab = t;
      _openCategory = null;
      _query = '';
    });
  }

  void _closeCategoryDetail() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _openCategory = null;
      _query = '';
    });
  }

  String get _hint {
    if (_tab == _Tab.categories && _openCategory != null) {
      final n = _openCategory!.isEmpty ? kNoCategoryLabel : _openCategory!;
      return Loc.t('Search Items in "$n"', 'اس "$n" میں آئٹم تلاش کریں');
    }
    switch (_tab) {
      case _Tab.products:
        return Loc.t('Search Items by Name or Code', 'نام یا کوڈ سے آئٹم تلاش کریں');
      case _Tab.categories:
        return Loc.t('Search Category', 'کیٹیگری تلاش کریں');
      case _Tab.units:
        return Loc.t('Search Unit', 'یونٹ تلاش کریں');
    }
  }

  String get _fabLabel {
    if (_tab == _Tab.categories && _openCategory != null) return Loc.t('＋  Add Product', '＋  پروڈکٹ شامل کریں');
    switch (_tab) {
      case _Tab.products:
        return Loc.t('＋  Add Product', '＋  پروڈکٹ شامل کریں');
      case _Tab.categories:
        return Loc.t('＋  Add Category', '＋  کیٹیگری شامل کریں');
      case _Tab.units:
        return Loc.t('＋  Add Unit', '＋  یونٹ شامل کریں');
    }
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) _loadAll();
  }

  void _openProduct(Product p) {
    if (!_admin) return;
    _push(RoleGuard(allowed: const {'admin'}, child: ProductScreen(editBarcode: p.barcode)));
  }

  void _onFab() {
    if (!_admin) return;
    if (_tab == _Tab.categories && _openCategory == null) {
      _promptAddCategory();
      return;
    }
    if (_tab == _Tab.units) {
      _promptAddUnit();
      return;
    }
    _push(const RoleGuard(allowed: {'admin'}, child: ProductScreen()));
  }

  // ---------- dialogs ----------
  Future<String?> _askText(String title, String okLabel, {String initial = ''}) {
    final c = TextEditingController(text: initial);
    c.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(c.text.trim()), child: Text(okLabel)),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String msg, String okLabel) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(okLabel, style: TextStyle(color: ThemeManager.palette.red)),
          ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _promptAddCategory() async {
    final v = await _askText(Loc.t('New Category', 'نئی کیٹیگری'), Loc.t('Add', 'شامل کریں'));
    if (v == null || v.isEmpty) return;
    await ItemsRepository.instance.addCategory(v);
    await _loadAll();
  }

  Future<void> _promptEditCategory(models.Category c) async {
    final v = await _askText(Loc.t('Rename Category', 'کیٹیگری کا نام بدلیں'), Loc.t('Save', 'محفوظ کریں'), initial: c.name);
    if (v == null || v.isEmpty || v == c.name) return;
    await ItemsRepository.instance.renameCategory(c.name, v);
    await _loadAll();
    _toast(Loc.t('Category renamed', 'کیٹیگری کا نام بدل گیا'));
  }

  Future<void> _confirmDeleteCategory(models.Category c, int count) async {
    final msg = count > 0
        ? Loc.t('"${c.name}" has $count item(s). Deleting it will move them to "$kNoCategoryLabel". Continue?',
            '"${c.name}" میں $count آئٹم ہیں۔ حذف کرنے پر وہ "$kNoCategoryLabel" میں چلے جائیں گے۔ جاری رکھیں؟')
        : Loc.t('Delete "${c.name}"? This cannot be undone.', '"${c.name}" حذف کریں؟ یہ واپس نہیں ہو سکتا۔');
    if (!await _confirm(Loc.t('Delete Category', 'کیٹیگری حذف کریں'), msg, Loc.t('Delete', 'حذف کریں'))) return;
    await ItemsRepository.instance.deleteCategory(c.name);
    await _loadAll();
    _toast(Loc.t('Category deleted', 'کیٹیگری حذف ہو گئی'));
  }

  Future<void> _promptChangeCategory(Product p) async {
    final options = <String>[kNoCategoryLabel, ..._categories.map((c) => c.name)];
    final idx = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(Loc.t('Move "${p.name}" to', '"${p.name}" کو منتقل کریں')),
        children: [
          for (var i = 0; i < options.length; i++)
            SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(i), child: Text(options[i])),
        ],
      ),
    );
    if (idx == null) return;
    final newCat = idx == 0 ? '' : options[idx];
    await ItemsRepository.instance.moveProductToCategory(p.barcode, newCat);
    await _loadAll();
    _toast(Loc.t('"${p.name}" moved to ${newCat.isEmpty ? kNoCategoryLabel : newCat}',
        '"${p.name}" ${newCat.isEmpty ? kNoCategoryLabel : newCat} میں منتقل ہو گئی'));
  }

  Future<void> _confirmDeleteProduct(Product p) async {
    if (!await _confirm(Loc.t('Delete Product', 'پروڈکٹ حذف کریں'),
        Loc.t('Delete "${p.name}"? This cannot be undone.', '"${p.name}" حذف کریں؟ یہ واپس نہیں ہو سکتا۔'), Loc.t('Delete', 'حذف کریں'))) return;
    await ItemsRepository.instance.deleteProduct(p.barcode);
    await _loadAll();
    _toast(Loc.t('Product deleted', 'پروڈکٹ حذف ہو گئی'));
  }

  Future<void> _promptAddUnit() async {
    final v = await _askText(Loc.t('New Unit', 'نیا یونٹ'), Loc.t('Add', 'شامل کریں'));
    if (v == null || v.isEmpty) return;
    await ItemsRepository.instance.addUnit(v);
    await _loadAll();
  }

  Future<void> _confirmDeleteUnit(models.UnitType u) async {
    if (!await _confirm(Loc.t('Delete Unit', 'یونٹ حذف کریں'),
        Loc.t('Delete "${u.name}"? This cannot be undone.', '"${u.name}" حذف کریں؟ یہ واپس نہیں ہو سکتا۔'), Loc.t('Delete', 'حذف کریں'))) return;
    await ItemsRepository.instance.deleteUnit(u.name);
    await _loadAll();
    _toast(Loc.t('Unit deleted', 'یونٹ حذف ہو گیا'));
  }

  // ---------- UI pieces ----------
  /// Kotlin importRateListCsv: file chuno -> parse -> apply -> "Updated N product(s)".
  Future<void> _importRateList() async {
    if (!_admin) return;
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) return _toast(Loc.t('Could not read file', 'فائل پڑھی نہیں جا سکی'));
      final rows = parseRateListCsv(utf8.decode(bytes, allowMalformed: true));
      if (rows.isEmpty) return _toast(Loc.t('File has no product rows', 'فائل میں کوئی پروڈکٹ نہیں'));
      final r = await ItemsRepository.instance.importRateList(rows);
      await _loadAll();
      _toast(rateListImportMessage(r.updated, r.notFound));
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  Widget _pill(String label, IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(color: ThemeManager.palette.headerBadgeOverlay, borderRadius: BorderRadius.circular(30)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 13, color: Colors.white),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
            ]),
          ),
        ),
      );

  Widget _actionsBar() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: ThemeManager.palette.navy, borderRadius: BorderRadius.circular(18)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _pill(Loc.t('Rate List', 'ریٹ لسٹ'), Icons.description_outlined,
                () => _push(const RoleGuard(allowed: {'admin'}, child: BulkMissingRatesScreen()))),
            if (_admin) _pill(Loc.t('Import', 'امپورٹ'), Icons.undo, _importRateList),
            _pill(Loc.t('Translate', 'ترجمہ'), Icons.language,
                () => _push(const RoleGuard(allowed: {'admin'}, child: BulkTranslateScreen()))),
            _pill(Loc.t('Units', 'یونٹس'), Icons.straighten,
                () => _push(const RoleGuard(allowed: {'admin'}, child: BulkDefaultUnitScreen()))),
          ]),
        ),
      );

  Widget _tabButton(String label, _Tab t) {
    final sel = _tab == t;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _switchTab(t),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: sel ? ThemeManager.palette.navy : Colors.transparent, borderRadius: BorderRadius.circular(10)),
          child: Center(
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: sel ? Colors.white : ThemeManager.palette.textMuted)),
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child, VoidCallback? onTap, EdgeInsets padding = const EdgeInsets.fromLTRB(20, 16, 20, 16)}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Ink(
            padding: padding,
            decoration: BoxDecoration(
              color: ThemeManager.palette.cardWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ThemeManager.palette.border),
            ),
            child: child,
          ),
        ),
      );

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text(t, style: TextStyle(color: ThemeManager.palette.textMuted))),
      );

  Widget _priceCol(String label, double v) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted)),
          Text('Rs ${v.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
        ]),
      );

  Widget _countBadge(int n) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        decoration: BoxDecoration(color: ThemeManager.palette.navy, borderRadius: BorderRadius.circular(20)),
        child: Text('$n', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.white)),
      );

  Widget _smallBtn(String label, IconData icon, Color c, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(30)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
          ]),
        ),
      );

  // ---------- tab bodies ----------
  List<Widget> _productsBody() {
    final list = filterProducts(_products, _query);
    if (list.isEmpty) return [_empty(Loc.t('No products found', 'کوئی پروڈکٹ نہیں ملی'))];
    return [
      for (final p in list)
        _card(
          onTap: () => _openProduct(p),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
            if (p.category.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(color: ThemeManager.palette.navy, borderRadius: BorderRadius.circular(16)),
                  child: Text(p.category, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                _priceCol(Loc.t('Sale Price', 'سیل قیمت'), p.salePrice),
                if (_canSeeCost) _priceCol(Loc.t('Purchase Price', 'خرید قیمت'), p.cost),
              ]),
            ),
          ]),
        ),
    ];
  }

  List<Widget> _categoriesBody() {
    final rows = buildCategoryRows(_products, _categories, _query);
    if (rows.isEmpty) return [_empty(Loc.t('No category found', 'کوئی کیٹیگری نہیں ملی'))];
    return [
      for (final r in rows)
        _card(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 18),
          onTap: () {
            _search.clear();
            setState(() {
              _openCategory = r.uncategorized ? '' : r.name;
              _query = '';
            });
          },
          child: Row(children: [
            Expanded(child: Text(r.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
            _countBadge(r.count),
            if (!r.uncategorized && _admin) ...[
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 18, color: ThemeManager.palette.textMuted),
                onPressed: () => _promptEditCategory(_categories.firstWhere((c) => c.name == r.name)),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 18, color: ThemeManager.palette.textMuted),
                onPressed: () => _confirmDeleteCategory(_categories.firstWhere((c) => c.name == r.name), r.count),
              ),
            ] else
              const SizedBox(width: 12),
          ]),
        ),
    ];
  }

  List<Widget> _categoryDetailBody() {
    final name = _openCategory!;
    final display = name.isEmpty ? kNoCategoryLabel : name;
    final inCat = _products.where((p) => categoryKey(p) == name).toList();
    final list = filterProducts(inCat, _query).where((p) => _query.trim().isEmpty || p.matchesQuery(_query.trim())).toList();
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: InkWell(
          onTap: _closeCategoryDetail,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.chevron_left, size: 18, color: ThemeManager.palette.navyInk),
              Text(Loc.t('Categories', 'کیٹیگریز'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: ThemeManager.palette.navyInk)),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 16),
        child: Text(display, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
      ),
      if (list.isEmpty)
        _empty(inCat.isEmpty
            ? Loc.t('No items in this category', 'اس کیٹیگری میں کوئی آئٹم نہیں')
            : Loc.t('No matching item found', 'کوئی مماثل آئٹم نہیں ملا'))
      else
        for (final p in list)
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.bar_chart, size: 12, color: ThemeManager.palette.textMuted),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text('${Loc.t('Stock', 'اسٹاک')}: ${p.formatStockBreakdown()}',
                        style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  _priceCol(Loc.t('Sale Price', 'سیل قیمت'), p.salePrice),
                  if (_canSeeCost) _priceCol(Loc.t('Purchase Price', 'خرید قیمت'), p.cost),
                ]),
              ),
              if (_admin)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _smallBtn(Loc.t('Edit', 'ترمیم'), Icons.edit, ThemeManager.palette.navyInk, () => _openProduct(p)),
                  _smallBtn(Loc.t('Change Category', 'کیٹیگری بدلیں'), Icons.repeat, ThemeManager.palette.teal, () => _promptChangeCategory(p)),
                  _smallBtn(Loc.t('Delete', 'حذف'), Icons.delete, ThemeManager.palette.red, () => _confirmDeleteProduct(p)),
                ]),
              ),
            ]),
          ),
    ];
  }

  List<Widget> _unitsBody() {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty ? _units : _units.where((u) => u.name.toLowerCase().contains(q)).toList();
    if (list.isEmpty) return [_empty(Loc.t('No unit found', 'کوئی یونٹ نہیں ملا'))];
    return [
      for (final u in list)
        _card(
          padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
          child: Row(children: [
            Expanded(child: Text(u.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark))),
            if (_admin) _smallBtn(Loc.t('Delete', 'حذف'), Icons.delete, ThemeManager.palette.red, () => _confirmDeleteUnit(u)),
          ]),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final inDetail = _tab == _Tab.categories && _openCategory != null;
    final body = switch (_tab) {
      _Tab.products => _productsBody(),
      _Tab.categories => inDetail ? _categoryDetailBody() : _categoriesBody(),
      _Tab.units => _unitsBody(),
    };
    return PopScope(
      canPop: !inDetail,
      onPopInvoked: (didPop) {
        if (!didPop && inDetail) _closeCategoryDetail();
      },
      child: Scaffold(
        backgroundColor: ThemeManager.palette.bg,
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: !_admin ? null : FloatingActionButton.extended(
          backgroundColor: ThemeManager.palette.red,
          foregroundColor: Colors.white,
          onPressed: _onFab,
          label: Text(_fabLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(children: [
              PremiumHeader(
                title: Loc.t('Items', 'آئٹمز'),
                subtitle: Loc.t('Products, Categories & Units', 'پروڈکٹس، کیٹیگریز اور یونٹس'),
              ),
              if (_admin) _actionsBar(),
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: ThemeManager.palette.cardWhite,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ThemeManager.palette.border),
                ),
                child: Row(children: [
                  _tabButton(Loc.t('PRODUCTS', 'پروڈکٹس'), _Tab.products),
                  _tabButton(Loc.t('CATEGORIES', 'کیٹیگریز'), _Tab.categories),
                  _tabButton(Loc.t('UNITS', 'یونٹس'), _Tab.units),
                ]),
              ),
              Container(
                margin: const EdgeInsets.only(bottom: 18),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: ThemeManager.palette.fieldFill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ThemeManager.palette.border),
                ),
                child: Row(children: [
                  Icon(Icons.search, size: 15, color: ThemeManager.palette.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      style: TextStyle(color: ThemeManager.palette.textDark),
                      decoration: InputDecoration(border: InputBorder.none, hintText: _hint, hintStyle: TextStyle(color: ThemeManager.palette.textMuted)),
                      onChanged: (v) {
                        _debounce?.cancel();
                        _debounce = Timer(const Duration(milliseconds: 200), () {
                          if (mounted) setState(() => _query = v.trim());
                        });
                      },
                    ),
                  ),
                ]),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 110),
                  children: body,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
