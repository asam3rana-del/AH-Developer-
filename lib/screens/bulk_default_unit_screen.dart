import 'package:flutter/material.dart';

import '../db/product_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart';

/// Mirrors BulkDefaultUnitActivity.kt + extra: Default Sale Unit AUR Quick Sale Unit, jab chahen badlein.
///  * "Review" tab: purani ek-ek product wali queue (jin ka Sale unit abhi manual set nahi) — Save & Next.
///  * "All Products" tab: 2+ unit wali SAB products; category chips + search; har product par Sale / Quick Sale
///    chip dabate hi foran save (Auto = wapas automatic). "Apply to shown" se poori category ek saath.
/// Admin-only (items_screen RoleGuard).
class BulkDefaultUnitScreen extends StatefulWidget {
  const BulkDefaultUnitScreen({super.key});

  @override
  State<BulkDefaultUnitScreen> createState() => _BulkDefaultUnitScreenState();
}

class _BulkDefaultUnitScreenState extends State<BulkDefaultUnitScreen> {
  List<Product> _all = [];
  List<Product> _queue = []; // Review tab
  int _queueTotal = 0;
  bool _loading = true;
  bool _saving = false;
  int _tab = 0; // 0 = Review, 1 = All Products
  String? _category; // null = sab
  String _search = '';
  int _chosenSale = -1; // Review card: -1 = Auto
  int _chosenQuick = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await ProductRepository.instance.multiUnitProducts();
      if (!mounted) return;
      final queue = all.where((p) => p.defaultUnitIndex == -1).toList();
      setState(() {
        _all = all;
        _queue = queue;
        _queueTotal = queue.length;
        _loading = false;
        if (queue.isEmpty) _tab = 1;
        _resetChosen();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(Loc.t('Could not load products: $e', 'پروڈکٹس لوڈ نہیں ہو سکیں: $e'));
    }
  }

  void _resetChosen() {
    if (_queue.isEmpty) {
      _chosenSale = -1;
      _chosenQuick = -1;
      return;
    }
    _chosenSale = autoDefaultUnitIndexFor(_queue.first);
    _chosenQuick = _queue.first.quickSaleDefaultUnitIndex;
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ------------------------------------------------------------ review (ek ek)

  Future<void> _saveAndNext({bool skip = false}) async {
    if (_queue.isEmpty || _saving) return;
    final current = _queue.first;
    setState(() => _saving = true);
    try {
      if (!skip) {
        await ProductRepository.instance.setSaleUnitDefaults(
          current.barcode,
          saleIndex: _chosenSale != -1 ? _chosenSale : null,
          quickIndex: _chosenQuick != -1 ? _chosenQuick : null,
        );
      }
      if (!mounted) return;
      setState(() {
        _queue = _queue.sublist(1);
        _resetChosen();
      });
      if (!skip) await _refreshAllQuietly();
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _refreshAllQuietly() async {
    final all = await ProductRepository.instance.multiUnitProducts();
    if (mounted) setState(() => _all = all);
  }

  // ------------------------------------------------------------ all products

  List<Product> get _shown {
    final q = _search.trim().toLowerCase();
    return _all.where((p) {
      final cat = p.category.isEmpty ? 'General' : p.category;
      if (_category != null && cat != _category) return false;
      if (q.isNotEmpty && !p.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  List<String> get _categories {
    final s = <String>{for (final p in _all) p.category.isEmpty ? 'General' : p.category};
    return s.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<void> _setOne(Product p, {int? sale, int? quick}) async {
    try {
      await ProductRepository.instance.setSaleUnitDefaults(p.barcode, saleIndex: sale, quickIndex: quick);
      if (!mounted) return;
      final updated = p.copyWith(
        defaultUnitIndex: sale ?? p.defaultUnitIndex,
        quickSaleDefaultUnitIndex: quick ?? p.quickSaleDefaultUnitIndex,
      );
      setState(() {
        _all = [for (final x in _all) x.barcode == p.barcode ? updated : x];
        _queue = [for (final x in _queue) x.barcode == p.barcode ? updated : x];
      });
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    }
  }

  Future<void> _applyToShown() async {
    final list = _shown;
    if (list.isEmpty) return;
    int? sale; // null = mat chhedo
    int? quick;
    final label = _category ?? Loc.t('all products', 'تمام پروڈکٹس');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Widget row(String title, int? value, void Function(int?) onPick) {
          final opts = <MapEntry<String, int?>>[
            MapEntry(Loc.t("Don't change", 'نہ بدلیں'), null),
            const MapEntry('Auto', -1),
            MapEntry(Loc.t('1st unit', 'پہلا یونٹ'), 0),
            MapEntry(Loc.t('2nd unit', 'دوسرا یونٹ'), 1),
            MapEntry(Loc.t('3rd unit', 'تیسرا یونٹ'), 2),
          ];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final o in opts) _chip(o.key, value == o.value, () => setD(() => onPick(o.value)), dense: true),
            ]),
          ]);
        }

        return AlertDialog(
          title: Text(Loc.t('Apply to $label (${list.length})', '$label پر لاگو کریں (${list.length})')),
          content: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                Loc.t('e.g. ${saleUnitChoices(list.first).join(' / ')} — 1st = ${list.first.unit}',
                    'مثال: ${saleUnitChoices(list.first).join(' / ')}'),
                style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted),
              ),
              row(Loc.t('Sale unit', 'سیل یونٹ'), sale, (v) => sale = v),
              row(Loc.t('Quick Sale unit', 'کوئیک سیل یونٹ'), quick, (v) => quick = v),
              const SizedBox(height: 10),
              Text(
                Loc.t('Products with fewer units than chosen are skipped.', 'جن میں اتنے یونٹ نہیں وہ چھوڑ دی جائیں گی۔'),
                style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Apply', 'لاگو کریں'))),
          ],
        );
      }),
    );
    if (ok != true) return;
    if (sale == null && quick == null) {
      _toast(Loc.t('Nothing selected to change', 'بدلنے کے لیے کچھ نہیں چنا'));
      return;
    }
    try {
      final r = await ProductRepository.instance.applySaleUnitDefaultsBulk(list, saleIndex: sale, quickIndex: quick);
      _toast(Loc.t('${r.changed} updated, ${r.skipped} skipped', '${r.changed} تبدیل، ${r.skipped} چھوڑی گئیں'));
      await _load();
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    }
  }

  // ------------------------------------------------------------------- widgets

  Widget _chip(String label, bool selected, VoidCallback onTap, {bool dense = false}) => InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: dense ? 12 : 20, vertical: dense ? 7 : 12),
          decoration: BoxDecoration(
            color: selected ? ThemeManager.palette.navyInk : ThemeManager.palette.cardWhite,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: ThemeManager.palette.navyInk),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: dense ? 11.5 : 12.5,
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : ThemeManager.palette.navyInk)),
        ),
      );

  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(8, 18, 22, 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(colors: [ThemeManager.palette.navy, ThemeManager.palette.navyLight]),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(Loc.t('Default Sale & Quick Sale Unit', 'ڈیفالٹ سیل اور کوئیک سیل یونٹ'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t(
                  'Change any time: one product at a time, or a whole category at once. Auto = shop default.',
                  'جب چاہیں بدلیں: ایک ایک پروڈکٹ، یا پوری کیٹیگری ایک ساتھ۔ Auto = خودکار۔',
                ),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _tabs() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(spacing: 8, children: [
          _chip('${Loc.t('Review', 'ریویو')} (${_queue.length})', _tab == 0, () => setState(() => _tab = 0), dense: true),
          _chip('${Loc.t('All Products', 'تمام پروڈکٹس')} (${_all.length})', _tab == 1, () => setState(() => _tab = 1), dense: true),
        ]),
      );

  Widget _unitRow(String title, List<String> tiers, int selected, void Function(int) onPick, {bool dense = false}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, top: 4),
          child: Text(title, style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted, fontWeight: FontWeight.w600)),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('Auto', selected == -1, () => onPick(-1), dense: dense),
          for (var i = 0; i < tiers.length; i++) _chip(tiers[i], selected == i, () => onPick(i), dense: dense),
        ]),
      ]);

  Widget _reviewCard(Product p) {
    final tiers = saleUnitChoices(p);
    final done = _queueTotal - _queue.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text('${done + 1} ${Loc.t('of', 'از')} $_queueTotal', style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
      ),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: ThemeManager.palette.cardWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ThemeManager.palette.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.name, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
          Padding(
            padding: const EdgeInsets.only(top: 3, bottom: 10),
            child: Text(p.category.isEmpty ? 'General' : p.category, style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
          ),
          _unitRow(Loc.t('Sale unit', 'سیل یونٹ'), tiers, _chosenSale, (i) => setState(() => _chosenSale = i)),
          const SizedBox(height: 10),
          _unitRow(Loc.t('Quick Sale unit', 'کوئیک سیل یونٹ'), tiers, _chosenQuick, (i) => setState(() => _chosenQuick = i)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: ThemeManager.palette.teal,
                padding: const EdgeInsets.symmetric(vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _saving ? null : () => _saveAndNext(),
              icon: const Icon(Icons.save, size: 18),
              label: Text(Loc.t('SAVE & NEXT', 'محفوظ کریں اور اگلا'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _saving ? null : () => _saveAndNext(skip: true), child: Text(Loc.t('Skip', 'چھوڑیں'))),
          ),
        ]),
      ),
    ]);
  }

  Widget _reviewTab() {
    if (_queue.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 50),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(Loc.t('All products reviewed', 'تمام پروڈکٹس دیکھ لی گئیں'), style: TextStyle(fontSize: 14, color: ThemeManager.palette.textMuted)),
            const SizedBox(width: 6),
            Icon(Icons.check, size: 16, color: ThemeManager.palette.teal),
          ]),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () => setState(() => _tab = 1),
            child: Text(Loc.t('Change units: All Products', 'یونٹ بدلیں: تمام پروڈکٹس')),
          ),
        ]),
      );
    }
    return _reviewCard(_queue.first);
  }

  Widget _productRow(Product p) {
    final tiers = saleUnitChoices(p);
    final saleNow = defaultUnitFor(p);
    final quickNow = quickSaleDefaultUnitFor(p);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ThemeManager.palette.cardWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ThemeManager.palette.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text('${p.category.isEmpty ? 'General' : p.category} · ${Loc.t('Sale', 'سیل')}: $saleNow · ${Loc.t('Quick', 'کوئیک')}: $quickNow',
              style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted)),
        ),
        _unitRow(Loc.t('Sale unit', 'سیل یونٹ'), tiers, p.defaultUnitIndex, (i) => _setOne(p, sale: i), dense: true),
        const SizedBox(height: 6),
        _unitRow(Loc.t('Quick Sale unit', 'کوئیک سیل یونٹ'), tiers, p.quickSaleDefaultUnitIndex, (i) => _setOne(p, quick: i), dense: true),
      ]),
    );
  }

  Widget _allTab() {
    final shown = _shown;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _chip(Loc.t('All', 'سب'), _category == null, () => setState(() => _category = null), dense: true),
          ),
          for (final c in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(c, _category == c, () => setState(() => _category = c), dense: true),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      TextField(
        onChanged: (v) => setState(() => _search = v),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: Loc.t('Search product', 'پروڈکٹ تلاش کریں'),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: ThemeManager.palette.navyInk,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: shown.isEmpty ? null : _applyToShown,
          icon: const Icon(Icons.done_all, size: 18),
          label: Text(Loc.t('Apply to shown (${shown.length})', 'دکھائی گئی (${shown.length}) پر لاگو کریں'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ),
      ),
      const SizedBox(height: 12),
      if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(child: Text(Loc.t('No products', 'کوئی پروڈکٹ نہیں'), style: TextStyle(color: ThemeManager.palette.textMuted))),
        )
      else
        for (final p in shown) _productRow(p),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(14), children: [
          _header(),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text(Loc.t('Loading…', 'لوڈ ہو رہا ہے…'), style: TextStyle(color: ThemeManager.palette.textMuted))),
            )
          else ...[
            _tabs(),
            if (_tab == 0) _reviewTab() else _allTab(),
          ],
        ]),
      ),
    );
  }
}
