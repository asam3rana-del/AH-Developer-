import 'package:flutter/material.dart';

import '../db/items_repository.dart' show filterProducts;
import '../db/product_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/rate_edit_sheet.dart';

/// Items → "Shop Rate" pill (admin): products ki list jis mein Wholesale aur Shopkeeper rate saath dikhte hain.
/// Product tap karein → rate sheet khulti hai (Shopkeeper field par focus), jahan se rate set/badal sakte hain.
/// Shopkeeper rate khali = bill par Wholesale rate lagta hai. "Not set" chip sirf wo products dikhata hai
/// jin ka shopkeeper rate abhi set nahi (lekin Wholesale rate maujood ho).
class ShopRateScreen extends StatefulWidget {
  const ShopRateScreen({super.key});

  @override
  State<ShopRateScreen> createState() => _ShopRateScreenState();
}

class _ShopRateScreenState extends State<ShopRateScreen> {
  final _search = TextEditingController();
  List<Product> _all = [];
  bool _loading = true;
  bool _onlyNotSet = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await ProductRepository.instance.listAll();
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
    });
  }

  Future<void> _edit(Product p) async {
    final saved = await showRateEditSheet(context, p, focusShopkeeper: true);
    if (saved) await _load();
  }

  static String _fmt(double v) {
    final r = (v * 100).round() / 100.0;
    return r == r.truncateToDouble() ? r.toInt().toString() : r.toStringAsFixed(2);
  }

  List<Product> get _visible {
    var list = filterProducts(_all, _query);
    if (_onlyNotSet) list = list.where((p) => p.shopkeeperPrice <= 0 && p.wholesalePrice > 0).toList();
    return list;
  }

  Widget _header() => Container(
        margin: const EdgeInsets.fromLTRB(14, 14, 14, 12),
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
                child: Text(Loc.t('Shop Rate', 'دکاندار ریٹ'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t('Tap a product to set its Shopkeeper rate. Empty = Wholesale rate is used on the bill.',
                    'دکاندار ریٹ لگانے کے لیے پروڈکٹ دبائیں۔ خالی = بل پر ہول سیل ریٹ لگے گا۔'),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _row(Product p) {
    final pal = ThemeManager.palette;
    final set = p.shopkeeperPrice > 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: pal.cardWhite,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: pal.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _edit(p),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: pal.textDark)),
                const SizedBox(height: 6),
                Wrap(spacing: 18, runSpacing: 4, children: [
                  Text('${Loc.t('Wholesale', 'ہول سیل')}: ${p.wholesalePrice > 0 ? 'Rs ${_fmt(p.wholesalePrice)}' : '—'}',
                      style: TextStyle(fontSize: 12.5, color: pal.textMuted)),
                  Text(
                      '${Loc.t('Shop', 'دکاندار')}: ${set ? 'Rs ${_fmt(p.shopkeeperPrice)}' : Loc.t('Not set', 'سیٹ نہیں')}',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.bold, color: set ? pal.blue : pal.textMuted)),
                ]),
                Text('${Loc.t('per', 'فی')} ${p.unit}', style: TextStyle(fontSize: 11, color: pal.textMuted)),
              ]),
            ),
            Icon(Icons.edit, size: 18, color: pal.tealDark),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = ThemeManager.palette;
    final list = _loading ? const <Product>[] : _visible;
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(children: [
          _header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: Loc.t('Search product…', 'پروڈکٹ تلاش کریں…'),
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: pal.fieldFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text(Loc.t('All', 'سب')), selected: !_onlyNotSet, onSelected: (_) => setState(() => _onlyNotSet = false)),
                ChoiceChip(
                    label: Text(Loc.t('Not set', 'سیٹ نہیں')),
                    selected: _onlyNotSet,
                    onSelected: (_) => setState(() => _onlyNotSet = true)),
              ]),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(child: Text(Loc.t('No products found', 'کوئی پروڈکٹ نہیں ملی'), style: TextStyle(color: pal.textMuted)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                        itemCount: list.length,
                        itemBuilder: (_, i) => _row(list[i]),
                      ),
          ),
        ]),
      ),
    );
  }
}
