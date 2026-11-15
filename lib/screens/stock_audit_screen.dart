import 'package:flutter/material.dart';

import '../db/stock_audit_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';
import 'stock_movement_screen.dart';

/// Mirrors StockAuditActivity.kt — "stock apni history se match nahi karta" wale products ek saath.
///
/// Har mismatch card: System stock (app) / Ledger says (history) / Difference + "Isko fix karo".
/// "Sab mismatches fix karo" = har product ke liye ek AUDIT_RECONCILE ledger entry (confirm dialog ke baad).
/// Fix kabhi live stock nahi badalta — sirf history ko usse milata hai, is liye shop chalte hue bhi safe.
///
/// Role: admin/manager (Reports ke andar).
///
/// Farq (Kotlin se): card tap ab usi product ki Stock History kholta hai (Kotlin generic list kholta tha);
/// negative farq ka breakdown sahi dikhta hai (abs value + sign); fix-all ek transaction mein.
class StockAuditScreen extends StatelessWidget {
  const StockAuditScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(
        allowed: {'admin', 'manager'},
        child: _StockAuditBody(),
      );
}

class _StockAuditBody extends StatefulWidget {
  const _StockAuditBody();

  @override
  State<_StockAuditBody> createState() => _StockAuditBodyState();
}

class _StockAuditBodyState extends State<_StockAuditBody> {
  final _repo = StockAuditRepository.instance;
  final _search = TextEditingController();

  AuditResult? _result;
  String? _error;
  bool _busy = false;

  AppPalette get _p => ThemeManager.palette;

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
    try {
      final r = await _repo.load();
      if (!mounted) return;
      setState(() {
        _result = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(Loc.t('Haan, fix karen', 'جی ہاں'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _fix(List<AuditRow> rows, String note, String doneMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _repo.reconcile(rows, note: note);
      if (!mounted) return;
      _toast(doneMsg);
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _fixAll(List<AuditRow> all) async {
    if (all.isEmpty) return;
    final ok = await _confirm(
      Loc.t('Sab mismatches fix karen?', 'تمام فرق درست کریں؟'),
      Loc.t(
        '${all.length} products ke liye history mein ek adjustment entry add hogi taake wo apne current stock se match ho jaye. Current stock (jo abhi bik raha hai) BILKUL NAHI badlega.',
        '${all.length} پروڈکٹس کی تاریخ میں ایک ایڈجسٹمنٹ اندراج شامل ہوگا تاکہ وہ موجودہ اسٹاک سے میچ ہو جائے۔ موجودہ اسٹاک بالکل تبدیل نہیں ہوگا۔',
      ),
    );
    if (!ok) return;
    await _fix(all, 'Stock Audit — bulk fix',
        Loc.t('${all.length} products fix ho gaye', '${all.length} پروڈکٹس درست ہو گئیں'));
  }

  Future<void> _fixOne(AuditRow r) async {
    final name = r.product.name;
    final ok = await _confirm(
      Loc.t('"$name" fix karen?', '"$name" درست کریں؟'),
      Loc.t(
        'History mein ek adjustment entry add hogi taake ye apne current stock se match ho jaye. Current stock bilkul nahi badlega.',
        'تاریخ میں ایک ایڈجسٹمنٹ اندراج شامل ہوگا تاکہ یہ موجودہ اسٹاک سے میچ ہو جائے۔ موجودہ اسٹاک بالکل تبدیل نہیں ہوگا۔',
      ),
    );
    if (!ok) return;
    await _fix([r], 'Stock Audit — single fix', Loc.t('"$name" fix ho gaya', '"$name" درست ہو گیا'));
  }

  /// Negative stock par Product.formatStockBreakdown floor() ulta deta hai — is liye abs value + sign.
  String _breakdown(Product p, double smallestQty, {bool signed = false}) {
    final text = p.copyWith(stock: smallestQty.abs()).formatStockBreakdown();
    if (smallestQty < 0) return '-$text';
    return signed && smallestQty > 0 ? '+$text' : text;
  }

  BoxDecoration _box(AppPalette p, double r, {Color? borderColor}) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: borderColor ?? p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final r = _result;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red))))
            : r == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(onRefresh: _load, child: _content(p, r)),
      ),
    );
  }

  Widget _content(AppPalette p, AuditResult r) {
    final filtered = filterAuditRows(r.mismatches, _search.text);
    final clean = r.mismatches.isEmpty;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
      children: [
        _header(p),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            clean
                ? Loc.t('✓ Sab ${r.totalChecked} products ka stock apni history se match karta hai.',
                    '✓ تمام ${r.totalChecked} پروڈکٹس کا اسٹاک ان کی تاریخ سے میچ کرتا ہے۔')
                : Loc.t('⚠ ${r.mismatches.length} of ${r.totalChecked} products ka stock apni history se match nahi karta.',
                    '⚠ ${r.mismatches.length} از ${r.totalChecked} پروڈکٹس کا اسٹاک ان کی تاریخ سے میچ نہیں کرتا۔'),
            style: TextStyle(fontSize: 13, color: clean ? p.flatTealFg : p.textMuted),
          ),
        ),
        if (!clean)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : () => _fixAll(r.mismatches),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.flatTealFg,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.build, size: 18),
                label: Text(Loc.t('Sab mismatches fix karo', 'تمام فرق درست کریں'),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        _searchBox(p),
        const SizedBox(height: 14),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                clean ? Loc.t('Koi mismatch nahi mila 🎉', 'کوئی فرق نہیں ملا') : Loc.t('No matching item', 'کوئی آئٹم نہیں ملا'),
                style: TextStyle(fontSize: 13, color: p.textMuted),
              ),
            ),
          )
        else
          for (final row in filtered) _card(p, row),
      ],
    );
  }

  Widget _header(AppPalette p) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(8, 14, 16, 14),
        decoration: _box(p, 22),
        child: Row(children: [
          IconButton(icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: p.flatCoralBg, shape: BoxShape.circle),
            child: Icon(Icons.fact_check, color: p.red, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Stock Audit', 'اسٹاک آڈٹ'), style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(Loc.t('Stock vs its own purchase/sale history', 'اسٹاک بمقابلہ اپنی خریداری/سیل تاریخ'),
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
                hintText: Loc.t('Search item…', 'آئٹم تلاش کریں…'),
                hintStyle: TextStyle(color: p.textMuted),
              ),
            ),
          ),
        ]),
      );

  Widget _stat(AppPalette p, String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: p.textMuted))),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _card(AppPalette p, AuditRow row) {
    final pr = row.product;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => StockMovementScreen(mode: StockMovementMode.stock, initialBarcode: pr.barcode))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        decoration: _box(p, 18, borderColor: p.red),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(pr.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
          const SizedBox(height: 8),
          _stat(p, Loc.t('System stock (app)', 'سسٹم اسٹاک'), _breakdown(pr, pr.stock), p.textDark),
          _stat(p, Loc.t('Ledger says (history)', 'تاریخ کے مطابق'), _breakdown(pr, row.ledgerStock), p.flatTealFg),
          _stat(p, Loc.t('Difference', 'فرق'), _breakdown(pr, row.diff, signed: true), p.red),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _fixOne(row),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.flatTealFg,
                side: BorderSide(color: p.flatTealFg),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(Loc.t('✓ Isko fix karo', '✓ اسے درست کریں'),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }
}
