import 'package:flutter/material.dart';

import '../db/product_repository.dart';
import '../models/product.dart';
import '../utils/loc.dart';
import '../utils/sale_cart.dart';
import '../theme/theme_manager.dart';

/// Mirrors BulkDefaultUnitActivity.kt — ek waqt mein ek product: 2+ unit tiers wale
/// products jin ka default sale unit abhi manual set nahi. Auto jo chunta hai wahi
/// pehle se highlight hota hai; "Save & Next" us ko confirm karta hai, ya doosra chip chunein.
/// Auto chip par Save = kuch likhna nahi (product Auto par hi rehta hai).
/// Sab roles ke liye nahi — dashboard par admin-only (Product screen jaisa) RoleGuard ke saath.
class BulkDefaultUnitScreen extends StatefulWidget {
  const BulkDefaultUnitScreen({super.key});

  @override
  State<BulkDefaultUnitScreen> createState() => _BulkDefaultUnitScreenState();
}

class _BulkDefaultUnitScreenState extends State<BulkDefaultUnitScreen> {
  List<Product> _queue = [];
  int _total = 0;
  bool _loading = true;
  bool _saving = false;
  int _chosen = -1; // -1 = Auto, 0/1/2 = tier

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ProductRepository.instance.needingDefaultUnitReview();
      if (!mounted) return;
      setState(() {
        _queue = list;
        _total = list.length;
        _loading = false;
        _chosen = list.isEmpty ? -1 : autoDefaultUnitIndexFor(list.first);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(Loc.t('Could not load products: $e', 'پروڈکٹس لوڈ نہیں ہو سکیں: $e'));
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveAndNext() async {
    if (_queue.isEmpty || _saving) return;
    final current = _queue.first;
    setState(() => _saving = true);
    try {
      if (_chosen != -1) {
        await ProductRepository.instance.setDefaultUnitIndex(current.barcode, _chosen);
      }
      if (!mounted) return;
      setState(() {
        _queue = _queue.sublist(1);
        _chosen = _queue.isEmpty ? -1 : autoDefaultUnitIndexFor(_queue.first);
      });
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? ThemeManager.palette.navyInk : ThemeManager.palette.cardWhite,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: ThemeManager.palette.navyInk),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: selected ? Colors.white : ThemeManager.palette.navyInk)),
        ),
      );

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
                child: Text(Loc.t('Default Sale Unit', 'ڈیفالٹ سیل یونٹ'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t(
                  'Products with more than one unit already have a suggestion picked for you below — tap Save & Next to confirm it, or pick a different unit first. One product at a time, no need to open each one from Items.',
                  'ایک سے زیادہ یونٹ والی پروڈکٹس کے لیے نیچے پہلے سے تجویز چنی گئی ہے — تصدیق کے لیے Save & Next دبائیں، یا پہلے دوسرا یونٹ چنیں۔ ایک وقت میں ایک پروڈکٹ۔',
                ),
                style: TextStyle(color: ThemeManager.palette.headerSubtitleColor, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _card(Product p) {
    final tiers = saleUnitChoices(p);
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
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip('Auto', _chosen == -1, () => setState(() => _chosen = -1)),
            for (var i = 0; i < tiers.length; i++) _chip(tiers[i], _chosen == i, () => setState(() => _chosen = i)),
          ]),
          const SizedBox(height: 16),
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
              label: Text(Loc.t('SAVE & NEXT', 'محفوظ کریں اور اگلا'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
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
                Text(Loc.t('All products reviewed', 'تمام پروڈکٹس دیکھ لی گئیں'), style: TextStyle(fontSize: 14, color: ThemeManager.palette.textMuted)),
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
