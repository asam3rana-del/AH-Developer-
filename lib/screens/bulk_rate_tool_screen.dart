import 'package:flutter/material.dart';

import '../db/product_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/bulk_rate_planner.dart';
import '../utils/loc.dart';

/// Bulk Rate Tool: sab products (ya ek category) par ek saath Retail ya Wholesale BULK RATE lagao ya hatao.
/// Rate asal rate se % ya Rs kam; min qty (main unit) sab par ek jaisi. Pehle preview, phir confirm.
/// Ek transaction mein save + sync_queue (har product doosre devices par bhi jata hai).
class BulkRateToolScreen extends StatefulWidget {
  const BulkRateToolScreen({super.key});

  @override
  State<BulkRateToolScreen> createState() => _BulkRateToolScreenState();
}

class _BulkRateToolScreenState extends State<BulkRateToolScreen> {
  final _minQty = TextEditingController();
  final _value = TextEditingController();
  List<Product> _products = [];
  bool _loading = true;
  bool _saving = false;

  BulkRateTarget _target = BulkRateTarget.retail;
  BulkRateRule _rule = BulkRateRule.percentOff;
  bool _clearMode = false;
  bool _onlyUnset = true;
  bool _roundToRupee = true;
  String? _category;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _minQty.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await ProductRepository.instance.listAll();
      if (!mounted) return;
      setState(() {
        _products = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(Loc.t('Could not load products: $e', 'پروڈکٹس لوڈ نہیں ہو سکیں: $e'));
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  List<String> get _categories {
    final set = <String>{};
    for (final p in _products) {
      final c = p.category.trim();
      if (c.isNotEmpty) set.add(c);
    }
    return set.toList()..sort();
  }

  BulkRatePlan get _plan {
    if (_clearMode) {
      return planClearBulkRates(products: _products, target: _target, category: _category);
    }
    return planBulkRates(
      products: _products,
      target: _target,
      minQty: double.tryParse(_minQty.text.trim()) ?? 0,
      rule: _rule,
      value: double.tryParse(_value.text.trim()) ?? 0,
      category: _category,
      onlyUnset: _onlyUnset,
      roundToRupee: _roundToRupee,
    );
  }

  static String _n(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _apply(BulkRatePlan plan) async {
    if (plan.rows.isEmpty || _saving) return;
    final tName = _target == BulkRateTarget.retail ? Loc.t('Retail', 'پرچون') : Loc.t('Wholesale', 'تھوک');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_clearMode ? Loc.t('Remove bulk rates?', 'بلک ریٹ ہٹائیں؟') : Loc.t('Apply bulk rates?', 'بلک ریٹ لگائیں؟')),
        content: Text(_clearMode
            ? Loc.t('$tName bulk rate ${plan.rows.length} products se hata diya jayega.',
                '$tName بلک ریٹ ${plan.rows.length} پروڈکٹس سے ہٹا دیا جائے گا۔')
            : Loc.t('$tName bulk rate ${plan.rows.length} products par lagega. Ye sab devices par sync hoga.',
                '$tName بلک ریٹ ${plan.rows.length} پروڈکٹس پر لگے گا۔ یہ تمام ڈیوائسز پر سنک ہوگا۔')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Confirm', 'تصدیق'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final n = await ProductRepository.instance.applyBulkRates(plan.rows, _target);
      await _load();
      if (!mounted) return;
      _toast(Loc.t('Done: $n products updated', 'مکمل: $n پروڈکٹس اپڈیٹ ہوئیں'));
    } catch (e) {
      if (!mounted) return;
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _chips<T>(List<(T, String)> options, T selected, void Function(T) onTap) => Wrap(
        spacing: 8,
        children: [
          for (final o in options)
            ChoiceChip(label: Text(o.$2), selected: o.$1 == selected, onSelected: (_) => setState(() => onTap(o.$1))),
        ],
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: ThemeManager.palette.textMuted)),
      );

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: ThemeManager.palette.fieldFill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      );

  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 12),
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
                child: Text(Loc.t('Bulk Rate Tool', 'بلک ریٹ ٹول'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t('Set (or remove) bulk rate on many products at once. Preview first, then confirm.',
                    'کئی پروڈکٹس پر ایک ساتھ بلک ریٹ لگائیں یا ہٹائیں۔ پہلے پریویو، پھر تصدیق۔'),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _previewRow(BulkRateRow r) {
    final p = ThemeManager.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.product.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.textDark)),
            Text(
                _clearMode
                    ? '${Loc.t('Now', 'ابھی')}: ${_n(r.oldBulkPrice)} @ ${_n(r.oldMinQty)}+'
                    : '${Loc.t('Rate', 'ریٹ')} ${_n(r.baseRate)}  →  ${_n(r.newBulkPrice)}  (${_n(r.newMinQty)}+)',
                style: TextStyle(fontSize: 12, color: p.textMuted)),
          ]),
        ),
        if (!_clearMode && r.oldBulkPrice > 0)
          Text('${Loc.t('was', 'پہلے')} ${_n(r.oldBulkPrice)}', style: TextStyle(fontSize: 11.5, color: p.amber)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final plan = _loading ? const BulkRatePlan([]) : _plan;
    final cats = _categories;
    final inputReady = _clearMode || ((double.tryParse(_minQty.text.trim()) ?? 0) > 0 && (double.tryParse(_value.text.trim()) ?? 0) > 0);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(14), children: [
          _header(),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text(Loc.t('Loading…', 'لوڈ ہو رہا ہے…'), style: TextStyle(color: p.textMuted))),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.cardWhite,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _label(Loc.t('FOR WHICH RATE', 'کس ریٹ کے لیے')),
                _chips<BulkRateTarget>([
                  (BulkRateTarget.retail, Loc.t('Retail', 'پرچون')),
                  (BulkRateTarget.wholesale, Loc.t('Wholesale', 'تھوک')),
                ], _target, (v) => _target = v),
                _label(Loc.t('ACTION', 'عمل')),
                _chips<bool>([
                  (false, Loc.t('Set bulk rate', 'بلک ریٹ لگاؤ')),
                  (true, Loc.t('Remove bulk rate', 'بلک ریٹ ہٹاؤ')),
                ], _clearMode, (v) => _clearMode = v),
                if (!_clearMode) ...[
                  _label(Loc.t('BULK MIN QTY (main unit)', 'بلک کم از کم مقدار (مین یونٹ)')),
                  _field(_minQty, 'e.g. 10'),
                  _label(Loc.t('BULK RATE = RATE MINUS', 'بلک ریٹ = ریٹ منفی')),
                  _chips<BulkRateRule>([
                    (BulkRateRule.percentOff, Loc.t('% off', '٪ کم')),
                    (BulkRateRule.amountOff, Loc.t('Rs off', 'روپے کم')),
                  ], _rule, (v) => _rule = v),
                  const SizedBox(height: 8),
                  _field(_value, _rule == BulkRateRule.percentOff ? 'e.g. 2' : 'e.g. 40'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(Loc.t('Only products without bulk rate', 'صرف جن کا بلک ریٹ سیٹ نہیں'), style: TextStyle(fontSize: 13, color: p.textDark)),
                    value: _onlyUnset,
                    onChanged: (v) => setState(() => _onlyUnset = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(Loc.t('Round to whole rupee', 'پورے روپے تک راؤنڈ'), style: TextStyle(fontSize: 13, color: p.textDark)),
                    value: _roundToRupee,
                    onChanged: (v) => setState(() => _roundToRupee = v),
                  ),
                ],
                _label(Loc.t('CATEGORY', 'کیٹیگری')),
                DropdownButtonFormField<String?>(
                  value: _category,
                  isExpanded: true,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: p.fieldFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text(Loc.t('All products', 'تمام پروڈکٹس'))),
                    for (final c in cats) DropdownMenuItem<String?>(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _category = v),
                ),
              ]),
            ),
          if (!_loading) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.cardWhite,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  inputReady
                      ? Loc.t('${plan.rows.length} products will change', '${plan.rows.length} پروڈکٹس تبدیل ہوں گی')
                      : Loc.t('Fill min qty and discount to see preview', 'پریویو کے لیے مقدار اور رعایت بھریں'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark),
                ),
                if (inputReady && (plan.skippedNoBase + plan.skippedInvalid + plan.skippedAlreadySet) > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      [
                        if (plan.skippedNoBase > 0) Loc.t('${plan.skippedNoBase} skipped (rate is 0)', '${plan.skippedNoBase} چھوڑی (ریٹ 0)'),
                        if (plan.skippedAlreadySet > 0) Loc.t('${plan.skippedAlreadySet} skipped (bulk already set)', '${plan.skippedAlreadySet} چھوڑی (بلک پہلے سے سیٹ)'),
                        if (plan.skippedInvalid > 0) Loc.t('${plan.skippedInvalid} skipped (bulk rate would be 0 or not lower)', '${plan.skippedInvalid} چھوڑی (بلک ریٹ 0 یا کم نہیں)'),
                      ].join(' • '),
                      style: TextStyle(fontSize: 12, color: p.textMuted),
                    ),
                  ),
                if (inputReady) ...[
                  const Divider(height: 20),
                  for (final r in plan.rows.take(60)) _previewRow(r),
                  if (plan.rows.length > 60)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(Loc.t('…and ${plan.rows.length - 60} more', '…اور ${plan.rows.length - 60} مزید'),
                          style: TextStyle(fontSize: 12, color: p.textMuted)),
                    ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _clearMode ? p.red : p.teal,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: (_saving || !inputReady || plan.rows.isEmpty) ? null : () => _apply(plan),
                    icon: Icon(_clearMode ? Icons.delete_outline : Icons.check, size: 18),
                    label: Text(
                        _clearMode ? Loc.t('REMOVE BULK RATES', 'بلک ریٹ ہٹائیں') : Loc.t('APPLY TO ALL', 'سب پر لگائیں'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                  ),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}
