import 'package:flutter/material.dart';

import '../db/stock_adjustment_repository.dart';
import '../models/product.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import '../widgets/role_guard.dart';

/// Mirrors StockAdjustmentActivity.kt — item dhoondo, phir "Damage / Loss" (hamesha stock ghatata hai,
/// Damage/Loss report ko feed karta hai) ya "Correction" (+ ya -, recount / entry ki ghalti) darj karo.
///
/// Khali search kuch nahi dikhata (Kotlin jaisa: ye tez, soch-samajh kar ki gayi adjustment hai, browse nahi).
/// Qty product ki SMALLEST unit mein. Save = stock + ledger + sync_queue ek transaction mein.
///
/// Role: admin/manager (Reports ke andar).
///
/// Farq (Kotlin se): piece-based item mein fraction reject; kam karne par stock kaafi na ho to saaf message
/// (SQL guard ke saath); dialog band hone se pehle save ka natija dikhta hai (galti par dialog khula rehta hai).
class StockAdjustmentScreen extends StatelessWidget {
  const StockAdjustmentScreen({super.key});

  @override
  Widget build(BuildContext context) => const RoleGuard(
        allowed: {'admin', 'manager'},
        child: _StockAdjustmentBody(),
      );
}

class _StockAdjustmentBody extends StatefulWidget {
  const _StockAdjustmentBody();

  @override
  State<_StockAdjustmentBody> createState() => _StockAdjustmentBodyState();
}

class _StockAdjustmentBodyState extends State<_StockAdjustmentBody> {
  final _repo = StockAdjustmentRepository.instance;
  final _search = TextEditingController();

  List<Product>? _all;
  String? _error;

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

  void _toast(String m, {bool long = false}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: long ? 4 : 2)));

  BoxDecoration _box(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

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
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
                    children: [_header(p), _searchBox(p), const SizedBox(height: 16), ..._results(p, all)],
                  ),
      ),
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
            child: Icon(Icons.build, color: p.red, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Stock Adjustment', 'اسٹاک ایڈجسٹمنٹ'),
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(Loc.t('Log damage, loss, or a manual correction', 'نقصان یا خودکار درستگی درج کریں'),
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

  List<Widget> _results(AppPalette p, List<Product> all) {
    if (_search.text.trim().isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(
            child: Text(Loc.t('Search for an item to adjust its stock', 'اسٹاک ایڈجسٹ کرنے کے لیے آئٹم تلاش کریں'),
                style: TextStyle(fontSize: 13, color: p.textMuted)),
          ),
        ),
      ];
    }
    final filtered = searchProductsForAdjustment(all, _search.text);
    if (filtered.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(child: Text(Loc.t('No items found', 'کوئی آئٹم نہیں ملا'), style: TextStyle(fontSize: 13, color: p.textMuted))),
        ),
      ];
    }
    return [
      for (final pr in filtered)
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openDialog(pr),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: _box(p, 18),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pr.name, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
                  const SizedBox(height: 3),
                  Text('${Loc.t('Current stock: ', 'موجودہ اسٹاک: ')}${pr.formatStockBreakdown()}',
                      style: TextStyle(fontSize: 12.5, color: p.textMuted)),
                ]),
              ),
              Icon(Icons.chevron_right, color: p.textMuted),
            ]),
          ),
        ),
    ];
  }

  Future<void> _openDialog(Product product) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustDialog(product: product, palette: _p, repo: _repo),
    );
    if (saved == true) {
      if (mounted) _toast(Loc.t('Stock updated', 'اسٹاک اپ ڈیٹ ہو گیا'));
      await _load();
    }
  }
}

class _AdjustDialog extends StatefulWidget {
  final Product product;
  final AppPalette palette;
  final StockAdjustmentRepository repo;
  const _AdjustDialog({required this.product, required this.palette, required this.repo});

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _qty = TextEditingController();
  final _note = TextEditingController();
  bool _isDamage = true;
  bool _isPlus = true;
  bool _saving = false;
  String? _err;

  AdjustmentKind get _kind =>
      _isDamage ? AdjustmentKind.damage : (_isPlus ? AdjustmentKind.correctionAdd : AdjustmentKind.correctionRemove);

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final qty = double.tryParse(_qty.text.trim());
    final err = validateAdjustment(widget.product, _kind, qty);
    if (err != null) {
      setState(() => _err = err);
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await widget.repo.save(widget.product.barcode, _kind, qty!, note: _note.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _err = e.toString();
        });
      }
    }
  }

  Widget _chip(String label, bool selected, Color color, VoidCallback onTap, {IconData? icon}) {
    final p = widget.palette;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? color : p.cardWhite,
            border: selected ? null : Border.all(color: p.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 14, color: selected ? Colors.white : color), const SizedBox(width: 6)],
            Flexible(
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: selected ? Colors.white : p.textMuted)),
            ),
          ]),
        ),
      ),
    );
  }

  InputDecoration _field(String hint) {
    final p = widget.palette;
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: p.fieldFill,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.border)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final pr = widget.product;
    final unit = pr.smallestUnitName();
    return AlertDialog(
      backgroundColor: p.cardWhite,
      title: Text(pr.name, style: TextStyle(color: p.textDark)),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${Loc.t('Current stock: ', 'موجودہ اسٹاک: ')}${pr.formatStockBreakdown()}',
              style: TextStyle(fontSize: 13, color: p.textMuted)),
          const SizedBox(height: 16),
          Row(children: [
            _chip(Loc.t('Damage / Loss', 'نقصان'), _isDamage, p.red, () => setState(() => _isDamage = true),
                icon: Icons.warning_amber),
            _chip(Loc.t('Correction', 'درستگی'), !_isDamage, p.flatPurpleFg, () => setState(() => _isDamage = false),
                icon: Icons.edit),
          ]),
          if (!_isDamage) ...[
            const SizedBox(height: 12),
            Row(children: [
              _chip('+ ${Loc.t('Add stock', 'اسٹاک بڑھائیں')}', _isPlus, p.flatTealFg, () => setState(() => _isPlus = true)),
              _chip('− ${Loc.t('Remove stock', 'اسٹاک کم کریں')}', !_isPlus, p.flatAmberFg, () => setState(() => _isPlus = false)),
            ]),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(color: p.textDark),
            decoration: _field(Loc.t('Quantity (in $unit)', 'مقدار ($unit)')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            style: TextStyle(color: p.textDark),
            decoration: _field(Loc.t('Reason / note (optional)', 'وجہ / نوٹ (اختیاری)')),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_err!, style: TextStyle(fontSize: 12.5, color: p.red)),
            ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(Loc.t('Cancel', 'منسوخ کریں')),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(Loc.t('Save', 'محفوظ کریں')),
        ),
      ],
    );
  }
}
