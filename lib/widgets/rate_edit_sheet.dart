import 'package:flutter/material.dart';

import '../db/product_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/input_validation.dart';
import '../utils/loc.dart';
import 'rate_margin_dialog.dart';

/// Admin ke liye quick rate edit: Retail / Wholesale / Shopkeeper ek hi jagah.
/// Unit chips: jis unit mein likhna aasaan ho likhein, save par PRIMARY unit mein convert hota hai.
/// Wapas `true` agar save hua. Cost se kam rate par "Save anyway?" poochta hai.
Future<bool> showRateEditSheet(BuildContext context, Product product, {bool focusShopkeeper = false}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RateEditSheet(product: product, focusShopkeeper: focusShopkeeper),
  );
  return saved == true;
}

class _RateEditSheet extends StatefulWidget {
  final Product product;
  final bool focusShopkeeper;
  const _RateEditSheet({required this.product, this.focusShopkeeper = false});

  @override
  State<_RateEditSheet> createState() => _RateEditSheetState();
}

class _RateEditSheetState extends State<_RateEditSheet> {
  final _retail = TextEditingController();
  final _wholesale = TextEditingController();
  final _shopkeeper = TextEditingController();
  late String _unit;
  bool _saving = false;

  Product get _p => widget.product;

  static String _fmt(double v) {
    if (v <= 0.0) return '';
    final rounded = (v * 100).round() / 100.0;
    return rounded == rounded.truncateToDouble() ? rounded.toInt().toString() : rounded.toStringAsFixed(2);
  }

  List<String> get _unitOptions {
    final seen = <String>{};
    return _p.unitLadder().reversed.map((t) => t.unit).where(seen.add).toList(); // bara unit pehle
  }

  @override
  void initState() {
    super.initState();
    _unit = _p.unit;
    _retail.text = _fmt(_p.salePrice);
    _wholesale.text = _fmt(_p.wholesalePrice);
    _shopkeeper.text = _fmt(_p.shopkeeperPrice);
  }

  @override
  void dispose() {
    _retail.dispose();
    _wholesale.dispose();
    _shopkeeper.dispose();
    super.dispose();
  }

  void _switchUnit(String to) {
    if (to == _unit) return;
    for (final c in [_retail, _wholesale, _shopkeeper]) {
      final typed = double.tryParse(c.text.trim()) ?? 0.0;
      if (typed > 0) c.text = _fmt(_p.fromPrimaryUnitRate(_p.toPrimaryUnitRate(typed, _unit), to));
    }
    setState(() => _unit = to);
  }

  Future<void> _save() async {
    if (_saving) return;
    final r = parseMoneyOrWarn(context, _retail.text, 'Retail Price', 'خوردہ قیمت');
    if (r == null) return;
    final w = parseMoneyOrWarn(context, _wholesale.text, 'Wholesale Price', 'ہول سیل قیمت');
    if (w == null) return;
    final sk = parseMoneyOrWarn(context, _shopkeeper.text, 'Shopkeeper Price', 'دکاندار قیمت');
    if (sk == null) return;
    final retail = r > 0 ? _p.toPrimaryUnitRate(r, _unit) : 0.0;
    final wholesale = w > 0 ? _p.toPrimaryUnitRate(w, _unit) : 0.0;
    final shopkeeper = sk > 0 ? _p.toPrimaryUnitRate(sk, _unit) : 0.0;
    if (!await confirmBelowCost(context, product: _p, retail: retail, wholesale: wholesale, shopkeeper: shopkeeper)) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await ProductRepository.instance
          .setRates(_p.barcode, salePrice: retail, wholesalePrice: wholesale, shopkeeperPrice: shopkeeper);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'))));
    }
  }

  Widget _field(String label, TextEditingController c, {String? hint, bool autofocus = false}) {
    final pal = ThemeManager.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: pal.textMuted)),
        if (hint != null) Text(hint, style: TextStyle(fontSize: 10.5, color: pal.textMuted)),
        const SizedBox(height: 4),
        TextField(
          controller: c,
          autofocus: autofocus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
          decoration: InputDecoration(
            hintText: '0.00',
            filled: true,
            fillColor: pal.fieldFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = ThemeManager.palette;
    final opts = _unitOptions;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_p.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: pal.textDark)),
          const SizedBox(height: 2),
          Text(Loc.t('Edit rates', 'ریٹ تبدیل کریں'), style: TextStyle(fontSize: 12, color: pal.textMuted)),
          if (opts.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final u in opts)
                  ChoiceChip(label: Text(u), selected: u == _unit, onSelected: (_) => _switchUnit(u)),
              ]),
            )
          else
            const SizedBox(height: 10),
          _field(Loc.t('RETAIL RATE (per $_unit)', 'خوردہ ریٹ (فی $_unit)'), _retail),
          _field(Loc.t('WHOLESALE RATE (per $_unit)', 'ہول سیل ریٹ (فی $_unit)'), _wholesale),
          _field(Loc.t('SHOPKEEPER RATE (per $_unit, optional)', 'دکاندار ریٹ (فی $_unit، اختیاری)'), _shopkeeper,
              autofocus: widget.focusShopkeeper,
              hint: Loc.t('Empty = Wholesale rate is used.', 'خالی = ہول سیل ریٹ لگے گا۔')),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: pal.teal,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save, size: 18),
              label: Text(Loc.t('SAVE', 'محفوظ کریں'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }
}
