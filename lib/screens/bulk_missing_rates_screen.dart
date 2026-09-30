import 'package:flutter/material.dart';

import '../db/product_repository.dart';
import '../models/product.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Mirrors BulkMissingRatesActivity.kt — un products ki queue jin ka Retail ya
/// Wholesale rate abhi 0 hai. Ek waqt mein ek: dono field pehle se bhari (jo set hai),
/// jo kam hai woh bhar kar Save & Next. Har rate ke oopar unit chips: us unit mein rate
/// likhein, save par PRIMARY unit mein convert (toPrimaryUnitRate) hota hai.
/// Kotlin ki tarah dono fields save hoti hain (set wali mein typo bhi theek ho sakta hai).
class BulkMissingRatesScreen extends StatefulWidget {
  const BulkMissingRatesScreen({super.key});

  @override
  State<BulkMissingRatesScreen> createState() => _BulkMissingRatesScreenState();
}

class _BulkMissingRatesScreenState extends State<BulkMissingRatesScreen> {
  final _retail = TextEditingController();
  final _wholesale = TextEditingController();
  List<Product> _queue = [];
  int _total = 0;
  bool _loading = true;
  bool _saving = false;
  String _retailUnit = '';
  String _wholesaleUnit = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retail.dispose();
    _wholesale.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await ProductRepository.instance.withMissingRates();
      if (!mounted) return;
      setState(() {
        _queue = list;
        _total = list.length;
        _loading = false;
      });
      _fillCurrent();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(Loc.t('Could not load products: $e', 'پروڈکٹس لوڈ نہیں ہو سکیں: $e'));
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  static String trimNum(double v) => v == 0.0 ? '' : (v == v.truncateToDouble() ? v.toInt().toString() : v.toString());

  static String formatConvertedRate(double v) {
    if (v <= 0.0) return '';
    final rounded = (v * 100).round() / 100.0;
    return rounded == rounded.truncateToDouble() ? rounded.toInt().toString() : rounded.toStringAsFixed(2);
  }

  static List<String> unitOptionsFor(Product p) {
    final opts = <String>[p.unit];
    if (p.secondaryUnit.trim().isNotEmpty) opts.add(p.secondaryUnit);
    if (p.tertiaryUnit.trim().isNotEmpty) opts.add(p.tertiaryUnit);
    final seen = <String>{};
    return opts.where(seen.add).toList(); // distinct
  }

  /// Rates hamesha primary unit par store hote hain, is liye har product primary chip se shuru.
  void _fillCurrent() {
    if (_queue.isEmpty) return;
    final p = _queue.first;
    setState(() {
      _retailUnit = p.unit;
      _wholesaleUnit = p.unit;
      _retail.text = trimNum(p.salePrice);
      _wholesale.text = trimNum(p.wholesalePrice);
    });
  }

  void _switchUnit(Product p, TextEditingController c, String from, String to, void Function(String) set) {
    if (from == to) return;
    final typed = double.tryParse(c.text.trim()) ?? 0.0;
    if (typed > 0) {
      final primary = p.toPrimaryUnitRate(typed, from);
      c.text = formatConvertedRate(p.fromPrimaryUnitRate(primary, to));
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    }
    setState(() => set(to));
  }

  Future<void> _saveAndNext() async {
    if (_queue.isEmpty || _saving) return;
    final current = _queue.first;
    final r = parseMoneyOrWarn(context, _retail.text, 'Retail Price', 'خوردہ قیمت');
    if (r == null) return;
    final w = parseMoneyOrWarn(context, _wholesale.text, 'Wholesale Price', 'ہول سیل قیمت');
    if (w == null) return;
    setState(() => _saving = true);
    try {
      final retail = r > 0 ? current.toPrimaryUnitRate(r, _retailUnit) : 0.0;
      final wholesale = w > 0 ? current.toPrimaryUnitRate(w, _wholesaleUnit) : 0.0;
      await ProductRepository.instance.setRates(current.barcode, salePrice: retail, wholesalePrice: wholesale);
      if (!mounted) return;
      setState(() => _queue = _queue.sublist(1));
      _fillCurrent();
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _unitChips(Product p, TextEditingController c, String selected, void Function(String) set) {
    final opts = unitOptionsFor(p);
    if (opts.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final u in opts)
          InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: () => _switchUnit(p, c, selected, u, set),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: u == selected ? ThemeManager.palette.teal : ThemeManager.palette.cardWhite,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: ThemeManager.palette.teal),
              ),
              child: Text(u, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: u == selected ? Colors.white : ThemeManager.palette.teal)),
            ),
          ),
      ]),
    );
  }

  Widget _rateField(String label, bool missing, Product p, TextEditingController c, String unit, void Function(String) set) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ThemeManager.palette.textMuted))),
          if (missing)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: ThemeManager.palette.amber, borderRadius: BorderRadius.circular(8)),
              child: const Text('MISSING', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
        ]),
        _unitChips(p, c, unit, set),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: ThemeManager.palette.fieldFill,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ThemeManager.palette.border),
          ),
          child: TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
            style: TextStyle(fontSize: 15, color: ThemeManager.palette.textDark),
            decoration: const InputDecoration(border: InputBorder.none, hintText: '0.00'),
          ),
        ),
      ]);

  Widget _costPanel(Product p) {
    Widget row(String l, String v, {bool bold = false}) => Row(children: [
          Expanded(child: Text(l, style: TextStyle(fontSize: 12.5, color: ThemeManager.palette.textMuted))),
          Text(v, style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: ThemeManager.palette.textDark)),
        ]);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ThemeManager.palette.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        row(Loc.t('Purchase Rate (Cost)', 'خریداری ریٹ (لاگت)'), 'Rs ${p.cost.toStringAsFixed(2)} / ${p.unit}', bold: true),
        const SizedBox(height: 6),
        row(Loc.t('Primary Unit', 'بنیادی یونٹ'), p.unit),
        if (p.secondaryUnit.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          row(Loc.t('Secondary Unit', 'ثانوی یونٹ'),
              p.secondaryUnit + (p.secondaryUnitQty > 0 ? ' (1 ${p.secondaryUnit} = ${trimNum(p.secondaryUnitQty)} ${p.unit})' : '')),
        ],
        if (p.tertiaryUnit.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          row(Loc.t('Tertiary Unit', 'تیسرا یونٹ'),
              p.tertiaryUnit + (p.tertiaryUnitQty > 0 ? ' (1 ${p.tertiaryUnit} = ${trimNum(p.tertiaryUnitQty)} ${p.unit})' : '')),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            unitOptionsFor(p).length > 1
                ? Loc.t('Tap a unit chip above Retail/Wholesale to enter that rate in whichever unit is easiest — it converts automatically.',
                    'خوردہ/ہول سیل کے اوپر یونٹ چپ دبائیں اور جس یونٹ میں آسان ہو ریٹ لکھیں — خود بخود تبدیل ہو جاتا ہے۔')
                : Loc.t('Enter Retail/Wholesale below per ${p.unit} (the primary unit).',
                    'خوردہ/ہول سیل نیچے فی ${p.unit} (بنیادی یونٹ) لکھیں۔'),
            style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
          ),
        ),
      ]),
    );
  }

  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 20),
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
                child: Text(Loc.t('Missing Rates', 'غائب ریٹ'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t("Only products missing a Retail or Wholesale rate show up here. Fill in what's missing and tap Save & Next — one product at a time, no spreadsheet needed.",
                    'یہاں صرف وہ پروڈکٹس آتی ہیں جن کا خوردہ یا ہول سیل ریٹ نہیں۔ جو کم ہو بھریں اور Save & Next دبائیں — ایک وقت میں ایک پروڈکٹ۔'),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _card(Product p) {
    final done = _total - _queue.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text('${done + 1} ${Loc.t('of', 'از')} $_total', style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
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
            padding: const EdgeInsets.only(top: 3),
            child: Text(p.category.isEmpty ? 'General' : p.category, style: TextStyle(fontSize: 12, color: ThemeManager.palette.textMuted)),
          ),
          const SizedBox(height: 12),
          _costPanel(p),
          const SizedBox(height: 16),
          _rateField(Loc.t('RETAIL RATE (SALE PRICE)', 'خوردہ ریٹ (سیل پرائس)'), p.salePrice <= 0, p, _retail, _retailUnit,
              (u) => _retailUnit = u),
          const SizedBox(height: 16),
          _rateField(Loc.t('WHOLESALE RATE', 'ہول سیل ریٹ'), p.wholesalePrice <= 0, p, _wholesale, _wholesaleUnit,
              (u) => _wholesaleUnit = u),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: ThemeManager.palette.teal,
                padding: const EdgeInsets.symmetric(vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _saving ? null : _saveAndNext,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('SAVE & NEXT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
            ),
          ),
        ]),
      ),
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
          else if (_queue.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(Loc.t('Every product has both rates set', 'ہر پروڈکٹ کے دونوں ریٹ سیٹ ہیں'),
                    style: TextStyle(fontSize: 14, color: ThemeManager.palette.textMuted)),
                const SizedBox(width: 6),
                Icon(Icons.check, size: 16, color: ThemeManager.palette.teal),
              ]),
            )
          else
            _card(_queue.first),
        ]),
      ),
    );
  }
}
