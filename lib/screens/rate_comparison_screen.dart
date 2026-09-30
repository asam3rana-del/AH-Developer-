import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/product_repository.dart';
import '../db/rate_comparison_repository.dart';
import '../models/product.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Mirrors RateComparisonActivity.kt — ek product chun kar dekhein kaun sa supplier
/// sab se sasta rate deta hai (Last / Lowest / Highest, kitni dafa liya).
/// Rates product ke PRIMARY unit par normalize hote hain (toPrimaryUnitRate), is liye
/// Ctn aur pcs mein hui purchases bhi fair compare hoti hain.
/// Sirf admin/manager (RoleGuard ke saath use karein; repository bhi cashier ko khali deta hai).
class RateComparisonScreen extends StatefulWidget {
  const RateComparisonScreen({super.key});

  @override
  State<RateComparisonScreen> createState() => _RateComparisonScreenState();
}

class _RateComparisonScreenState extends State<RateComparisonScreen> {
  final _search = TextEditingController();
  List<Product> _all = [];
  Product? _selected;
  bool _loading = false;
  String? _error;
  List<SupplierRateRow> _rows = [];

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
    final list = await ProductRepository.instance.listAll();
    if (!mounted) return;
    setState(() => _all = list);
  }

  Future<void> _select(Product p) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _selected = p;
      _loading = true;
      _error = null;
      _rows = [];
    });
    try {
      final rows = await RateComparisonRepository.instance.compare(p);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _change() {
    setState(() {
      _selected = null;
      _rows = [];
      _error = null;
    });
  }

  // ---------- pieces ----------
  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.fromLTRB(8, 18, 18, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ThemeManager.palette.navy, ThemeManager.palette.navyLight],
          ),
        ),
        child: Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('⚖️  ${Loc.t('Rate Comparison', 'ریٹ کا موازنہ')}',
                  style: const TextStyle(color: Colors.white, fontSize: 18.5, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(
                Loc.t('See which supplier gives the best rate', 'دیکھیں کون سا سپلائر بہترین ریٹ دیتا ہے'),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 11),
              ),
            ]),
          ),
        ]),
      );

  Widget _hint(String msg) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 14, 6, 14),
        child: Text(msg, style: TextStyle(fontSize: 12.5, color: ThemeManager.palette.textMuted)),
      );

  Widget _picker() {
    final q = _search.text.trim();
    final filtered = q.isEmpty ? <Product>[] : _all.where((p) => p.matchesQuery(q)).take(20).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: ThemeManager.palette.cardWhite,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: ThemeManager.palette.border),
        ),
        child: Row(children: [
          const Text('🔍  ', style: TextStyle(fontSize: 15)),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 14.5, color: ThemeManager.palette.textDark),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: Loc.t('Search a product to compare rates…', 'موازنے کے لیے پروڈکٹ تلاش کریں…'),
                hintStyle: TextStyle(color: ThemeManager.palette.textMuted),
              ),
            ),
          ),
        ]),
      ),
      if (q.isEmpty)
        _hint(Loc.t('Start typing a product name above to see its supplier rates.',
            'اوپر پروڈکٹ کا نام لکھنا شروع کریں تاکہ اس کے سپلائر ریٹ نظر آئیں۔'))
      else if (filtered.isEmpty)
        _hint(Loc.t('No matching products', 'کوئی مماثل پروڈکٹ نہیں ملی'))
      else
        for (final p in filtered)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _select(p),
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: ThemeManager.palette.cardWhite,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ThemeManager.palette.border),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(p.name,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
                  ),
                  Text(p.category, style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted)),
                ]),
              ),
            ),
          ),
    ]);
  }

  Widget _statChip(String label, String value, Color accent) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ThemeManager.palette.fieldFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ThemeManager.palette.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textMuted)),
          const SizedBox(height: 3),
          Text(value, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: accent)),
        ]),
      );

  Widget _rowCard(SupplierRateRow r, bool isBest) {
    final fmtDate = DateFormat('dd MMM yyyy');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isBest ? ThemeManager.palette.savedHighlightBg : ThemeManager.palette.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isBest ? ThemeManager.palette.teal : ThemeManager.palette.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r.supplierName,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isBest ? ThemeManager.palette.teal : ThemeManager.palette.textDark)),
          ),
          if (isBest)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(color: ThemeManager.palette.teal, borderRadius: BorderRadius.circular(30)),
              child: Text('✅  ${Loc.t('Best Rate', 'بہترین ریٹ')}',
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
        ]),
        Divider(height: 24, color: ThemeManager.palette.border),
        Row(children: [
          Expanded(child: _statChip(Loc.t('Last Rate', 'آخری ریٹ'), r.lastRate.toStringAsFixed(2), isBest ? ThemeManager.palette.teal : ThemeManager.palette.textDark)),
          const SizedBox(width: 10),
          Expanded(child: _statChip(Loc.t('Lowest', 'کم ترین'), r.minRate.toStringAsFixed(2), ThemeManager.palette.teal)),
          const SizedBox(width: 10),
          Expanded(child: _statChip(Loc.t('Highest', 'زیادہ ترین'), r.maxRate.toStringAsFixed(2), ThemeManager.palette.red)),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 12, left: 2),
          child: Text(
            Loc.t(
              'Purchased ${r.timesPurchased} time(s)  •  Last on ${fmtDate.format(DateTime.fromMillisecondsSinceEpoch(r.lastDate))}',
              '${r.timesPurchased} بار خریدا گیا  •  آخری بار ${fmtDate.format(DateTime.fromMillisecondsSinceEpoch(r.lastDate))}',
            ),
            style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
          ),
        ),
      ]),
    );
  }

  Widget _comparison(Product p) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text('📦  ${p.name}',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textDark)),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: _change,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(color: ThemeManager.palette.textMuted, borderRadius: BorderRadius.circular(30)),
            child: Text('✕  ${Loc.t('Change', 'تبدیل کریں')}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 0, 14),
        child: Text(
          Loc.t('Rates shown per ${p.unit} (converted from any unit that was purchased)',
              'ریٹ فی ${p.unit} دکھایا گیا ہے (جس بھی یونٹ میں خریدا گیا اسے تبدیل کر کے)'),
          style: TextStyle(fontSize: 11.5, color: ThemeManager.palette.textMuted),
        ),
      ),
      if (_loading)
        _hint(Loc.t('Loading purchase history…', 'خریداری کی تاریخ لوڈ ہو رہی ہے…'))
      else if (_error != null)
        _hint(Loc.t('Could not load rate history: $_error', 'ریٹ کی تاریخ لوڈ نہیں ہو سکی: $_error'))
      else if (_rows.isEmpty)
        _hint(Loc.t('No purchase history found for this product yet from any supplier.',
            'اس پروڈکٹ کی کسی بھی سپلائر سے کوئی خریداری کی تاریخ نہیں ملی۔'))
      else
        for (final r in _rows) _rowCard(r, r.supplierId == _rows.first.supplierId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _header(),
            if (_selected == null) _picker() else _comparison(_selected!),
          ],
        ),
      ),
    );
  }
}
