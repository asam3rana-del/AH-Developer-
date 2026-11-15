import 'package:flutter/material.dart';

import '../db/stock_taking_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/numeric_keypad.dart';
import '../widgets/role_guard.dart';

/// Mirrors StockTakingActivity.kt — physical inventory count: poori list mein dhoondo / scroll karo,
/// har item ke saamne shelf par asal gintee likho, phir variance summary dekh kar confirm karo.
///
/// Usool (Kotlin jaise):
///  * KHALI field = "aaj nahi gina" (0 nahi) — sirf jin ki gintee likhi wahi chuute hain.
///  * Gintee product ki SMALLEST unit mein (Product.stock ki basis) — row par unit ka naam likha hai.
///  * Search se list filter hone par likhi hui ginti gum nahi hoti (controller barcode ke hisaab se).
///  * Confirm = sab lines + `STOCK_TAKE` ledger rows + sync_queue ek transaction mein + ek audit entry.
///
/// Role: admin/manager (Reports ke andar). Kotlin mein check nahi tha, magar stock badalti hai.
///
/// Farq (Kotlin se): negative gintee aur piece-based item mein fraction rad (galat data stock mein nahi jata);
/// custom NumericKeypad (Kotlin `useNumericKeypad`) NumericKeypadField se; role repository mein bhi check.
class StockTakingScreen extends StatelessWidget {
  const StockTakingScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(
        allowed: {'admin', 'manager'},
        child: _StockTakingBody(),
      );
}

class _StockTakingBody extends StatefulWidget {
  const _StockTakingBody();

  @override
  State<_StockTakingBody> createState() => _StockTakingBodyState();
}

class _StockTakingBodyState extends State<_StockTakingBody> {
  final _repo = StockTakingRepository.instance;
  final _search = TextEditingController();
  final _note = TextEditingController();

  /// barcode -> gintee ka controller. Filtering se row rebuild hoti hai, controller nahi — isliye ginti bachi rehti hai.
  final Map<String, TextEditingController> _counts = {};

  List<Product>? _all;
  String? _error;
  bool _saving = false;

  AppPalette get _p => ThemeManager.palette;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    for (final c in _counts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.loadProducts();
      if (!mounted) return;
      setState(() {
        _all = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  TextEditingController _controllerFor(String barcode) => _counts.putIfAbsent(barcode, () => TextEditingController());

  /// Sirf wo entries jin mein kuch likha hai (barcode -> text).
  Map<String, String> get _entered => {
        for (final e in _counts.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text,
      };

  void _toast(String m, {bool long = false}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: long ? 4 : 2)));

  BoxDecoration _box(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

  // ───────────────────────── review & save ─────────────────────────

  Future<void> _reviewAndSave() async {
    if (_saving) return;
    final entered = _entered;
    if (countedItems(entered) == 0) {
      _toast(Loc.t('Count at least one item', 'کم از کم ایک آئٹم گنیں'));
      return;
    }

    final Map<String, Product> latest;
    try {
      latest = await _repo.loadLatestByBarcode();
    } catch (e) {
      if (mounted) _toast(e.toString(), long: true);
      return;
    }
    if (!mounted) return;

    final bad = firstInvalidCount(entered, latest);
    if (bad != null) {
      _toast(bad, long: true);
      return;
    }

    final variances = buildVariances(entered, latest);
    if (variances.isEmpty) {
      _toast(Loc.t('No difference — everything matches system stock', 'کوئی فرق نہیں — سب سسٹم اسٹاک سے میچ کرتا ہے'),
          long: true);
      return;
    }

    final summary = stockTakeSummaryText(
      variances,
      header: Loc.t('item(s) have a variance:', 'آئٹمز میں فرق ہے:'),
      impactLabel: Loc.t('Estimated value impact:', 'قدر پر اثر:'),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _p.cardWhite,
        title: Text(Loc.t('Confirm Stock Take', 'اسٹاک گنتی کی تصدیق کریں'), style: TextStyle(color: _p.textDark)),
        content: SingleChildScrollView(child: Text(summary, style: TextStyle(fontSize: 13.5, color: _p.textDark))),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(Loc.t('Confirm & Save', 'تصدیق کریں'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _commit(variances);
  }

  Future<void> _commit(List<StockTakeVariance> variances) async {
    setState(() => _saving = true);
    try {
      await _repo.commit(variances, note: _note.text);
      if (!mounted) return;
      for (final c in _counts.values) {
        c.clear();
      }
      _note.clear();
      setState(() => _saving = false);
      _toast(Loc.t('Stock take saved', 'اسٹاک گنتی محفوظ ہو گئی'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.toString(), long: true);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final all = _all;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red))))
            : all == null
                ? const Center(child: CircularProgressIndicator())
                : _content(p, all),
      ),
    );
  }

  Widget _content(AppPalette p, List<Product> all) {
    final filtered = filterStockTakeProducts(all, _search.text);
    final counted = countedItems(_entered);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _header(p),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text(
              counted == 0
                  ? Loc.t('0 items counted', '0 آئٹم گنے گئے')
                  : '$counted ${Loc.t('item(s) counted so far', 'آئٹم اب تک گنے گئے')}',
              style: TextStyle(fontSize: 12.5, color: p.textMuted),
            ),
          ),
          _searchBox(p),
          const SizedBox(height: 16),
        ]),
      ),
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Text(Loc.t('No items found', 'کوئی آئٹم نہیں ملا'), style: TextStyle(fontSize: 13, color: p.textMuted)))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: filtered.length,
                itemBuilder: (_, i) => _row(p, filtered[i]),
              ),
      ),
      _footer(p),
    ]);
  }

  Widget _header(AppPalette p) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(8, 14, 16, 14),
        decoration: _box(p, 22),
        child: Row(children: [
          IconButton(icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: p.flatBlueBg, shape: BoxShape.circle),
            child: Icon(Icons.checklist, color: p.flatBlueFg, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Stock Taking', 'اسٹاک گنتی'),
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(Loc.t('Physical count vs system stock', 'اصل گنتی بمقابلہ سسٹم اسٹاک'),
                  style: TextStyle(fontSize: 11, color: p.textMuted)),
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
                hintText: Loc.t('Search item or category…', 'آئٹم یا کیٹیگری تلاش کریں…'),
                hintStyle: TextStyle(color: p.textMuted),
              ),
            ),
          ),
        ]),
      );

  Widget _row(AppPalette p, Product pr) {
    final unit = pr.smallestUnitName();
    return Container(
      key: ValueKey(pr.barcode),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: _box(p, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pr.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 3),
            Text('${Loc.t('System: ', 'سسٹم: ')}${pr.formatStockBreakdown()}',
                style: TextStyle(fontSize: 12, color: p.textMuted)),
            const SizedBox(height: 2),
            Text(Loc.t('Count in $unit', 'گنتی $unit میں'), style: TextStyle(fontSize: 11, color: p.textMuted)),
          ]),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 92,
          child: NumericKeypadField(
            controller: _controllerFor(pr.barcode),
            allowDecimal: true,
            label: '${pr.name} — ${Loc.t('Counted', 'گنتی')} ($unit)',
            style: TextStyle(fontSize: 14, color: p.textDark),
            decoration: InputDecoration(
              isDense: true,
              hintText: Loc.t('Counted', 'گنتی'),
              hintStyle: TextStyle(color: p.textMuted),
              filled: true,
              fillColor: p.fieldFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.border)),
            ),
            onChanged: (_) => setState(() {}),
            onDone: () => setState(() {}),
          ),
        ),
      ]),
    );
  }

  Widget _footer(AppPalette p) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.border))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _note,
            style: TextStyle(color: p.textDark),
            decoration: InputDecoration(
              hintText: Loc.t('Note for this count (optional)', 'اس گنتی کے لیے نوٹ (اختیاری)'),
              hintStyle: TextStyle(color: p.textMuted),
              filled: true,
              fillColor: p.fieldFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _reviewAndSave,
              style: FilledButton.styleFrom(
                backgroundColor: p.flatPurpleFg,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(Loc.t('Review & Save Stock Take', 'جائزہ لیں اور محفوظ کریں'),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
        ]),
      );
}
