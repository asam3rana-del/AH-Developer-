import 'package:flutter/material.dart';

import '../backup/backup_helper.dart';
import '../db/bulk_translate_repository.dart';
import '../models/product.dart';
import '../theme/app_colors.dart';
import '../utils/duplicate_unit_fix.dart';
import '../utils/loc.dart';
import '../utils/merge_duplicate_products.dart';

/// Mirrors BulkTranslateActivity.kt — Urdu -> English ek dafa ka tool.
/// Categories / Units: har Urdu value ek baar, saamne English field; "Save" master table aur har product
/// (category / unit / secondaryUnit / tertiaryUnit) mein ek saath badal deta hai.
/// Items (search tags): ek waqt mein ek naam, "Save & Next" foran agla dikhata hai
/// (ek se zyada English naam comma se, e.g. "sugar, chini").
///
/// Maintenance cards (Phase 13): "Fix Duplicate Unit Names" (DuplicateUnitFix.kt) aur
/// "Merge Duplicate Products" (MergeDuplicateProductsFix.kt — preview dikha kar, backup ke baad).
/// Sirf admin — Items screen se RoleGuard ke saath khulta hai.
class BulkTranslateScreen extends StatefulWidget {
  const BulkTranslateScreen({super.key});

  @override
  State<BulkTranslateScreen> createState() => _BulkTranslateScreenState();
}

class _BulkTranslateScreenState extends State<BulkTranslateScreen> {
  final Map<String, TextEditingController> _catFields = {};
  final Map<String, TextEditingController> _unitFields = {};
  final TextEditingController _itemTag = TextEditingController();

  List<String> _untaggedQueue = [];
  int _untaggedTotal = 0;

  bool _loading = true;
  bool _busy = false; // fix / merge / save chal raha hai

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposeFields();
    _itemTag.dispose();
    super.dispose();
  }

  void _disposeFields() {
    for (final c in _catFields.values) {
      c.dispose();
    }
    for (final c in _unitFields.values) {
      c.dispose();
    }
    _catFields.clear();
    _unitFields.clear();
  }

  void _toast(String m, {int seconds = 3}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: seconds)));
  }

  Future<void> _load() async {
    try {
      final v = await BulkTranslateRepository.instance.load();
      if (!mounted) return;
      setState(() {
        _disposeFields();
        for (final c in v.categories) {
          _catFields[c] = TextEditingController();
        }
        for (final u in v.units) {
          _unitFields[u] = TextEditingController();
        }
        _untaggedQueue = List.of(v.untaggedItems);
        _untaggedTotal = v.untaggedItems.length;
        _itemTag.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(Loc.t('Could not load values: $e', 'ویلیوز لوڈ نہیں ہو سکیں: $e'));
    }
  }

  // ---------- Fix Duplicate Unit Names ----------

  Future<void> _runDuplicateUnitFix() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final count = await DuplicateUnitFix.run();
      _toast(
        count > 0
            ? Loc.t('$count unit name(s) fixed across all products', '$count یونٹ نام تمام پروڈکٹس میں ٹھیک ہو گئے')
            : Loc.t('No duplicated unit names found', 'کوئی دوہرا یونٹ نام نہیں ملا'),
      );
      await _load();
    } catch (e) {
      _toast(Loc.t('Could not fix duplicates: $e', 'ٹھیک نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Merge Duplicate Products ----------

  Future<void> _runMerge() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final plan = await MergeDuplicateProducts.preview();
      if (!mounted) return;

      if (plan.isEmpty) {
        _toast(
          plan.skippedUnitMismatch > 0
              ? Loc.t('Nothing to merge safely. ${plan.skippedUnitMismatch} name match(es) have a different unit setup — review manually.',
                  'محفوظ طریقے سے ملانے کو کچھ نہیں۔ ${plan.skippedUnitMismatch} نام ملتے ہیں مگر یونٹ سیٹ اپ مختلف ہے — خود دیکھیں۔')
              : Loc.t('No duplicate products found', 'کوئی دوہری پروڈکٹ نہیں ملی'),
          seconds: 5,
        );
        return;
      }

      final ok = await _confirmMerge(plan);
      if (ok != true || !mounted) return;

      // Merge rows hatata hai — pehle backup (Backup Password wala encrypted).
      final backup = await BackupHelper.backupNow();
      if (backup == null) {
        if (!mounted) return;
        final goOn = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(Loc.t('Backup failed', 'بیک اپ نہیں بن سکا')),
            content: Text(Loc.t(
                'A safety backup could not be created. Merging deletes duplicate product rows. Continue without a backup?',
                'حفاظتی بیک اپ نہیں بن سکا۔ ملانے سے دوہری پروڈکٹ کی قطاریں حذف ہوتی ہیں۔ بیک اپ کے بغیر جاری رکھیں؟')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
              TextButton(onPressed: () => Navigator.pop(c, true), child: Text(Loc.t('Continue', 'جاری رکھیں'))),
            ],
          ),
        );
        if (goOn != true) return;
      }

      final r = await MergeDuplicateProducts.run();
      final msg = StringBuffer(Loc.t('${r.groupsMerged} duplicate item(s) merged', '${r.groupsMerged} دوہری آئٹم ملا دی گئیں'));
      if (r.productsRemoved > 0) {
        msg.write(Loc.t(' (${r.productsRemoved} row(s) removed, stock combined)', ' (${r.productsRemoved} قطاریں ہٹیں، اسٹاک جمع ہوا)'));
      }
      if (r.groupsSkippedUnitMismatch > 0) {
        msg.write(Loc.t('\n${r.groupsSkippedUnitMismatch} name-match(es) skipped — different unit setup, needs manual review',
            '\n${r.groupsSkippedUnitMismatch} نام ملتے ہیں مگر یونٹ سیٹ اپ مختلف — خود دیکھیں'));
      }
      _toast(msg.toString(), seconds: 6);
      await _load();
    } catch (e) {
      _toast(Loc.t('Could not merge: $e', 'ملایا نہیں جا سکا: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmMerge(MergePlan plan) {
    final shown = plan.groups.take(25).toList();
    return showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(Loc.t('Merge duplicate products?', 'دوہری پروڈکٹس ملائیں؟')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            Text(
              Loc.t(
                '${plan.groups.length} item(s): ${plan.productsToRemove} duplicate row(s) will be removed. Stock is added onto the most recently edited row; sale / purchase / return / stock history move to it. Held bills are not changed.',
                '${plan.groups.length} آئٹم: ${plan.productsToRemove} دوہری قطاریں ہٹیں گی۔ اسٹاک سب سے تازہ ایڈٹ ہوئی قطار پر جمع ہوگا؛ سیل / پرچیز / ریٹرن / اسٹاک ہسٹری اسی پر منتقل ہوگی۔ ہولڈ بلز نہیں بدلتے۔',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            for (final g in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.keeper.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                  Text(
                    '${g.all.length} ${Loc.t('rows', 'قطاریں')} → ${g.keeper.copyWith(stock: g.combinedStock).formatStockBreakdown()}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ]),
              ),
            if (plan.groups.length > shown.length)
              Text(Loc.t('…and ${plan.groups.length - shown.length} more', '…اور ${plan.groups.length - shown.length} مزید'),
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            if (plan.skippedUnitMismatch > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  Loc.t('${plan.skippedUnitMismatch} name match(es) skipped — different unit setup.',
                      '${plan.skippedUnitMismatch} نام ملتے ہیں مگر یونٹ سیٹ اپ مختلف — چھوڑ دیے گئے۔'),
                  style: const TextStyle(fontSize: 12, color: AppColors.orange),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(Loc.t('Cancel', 'منسوخ'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.teal),
            onPressed: () => Navigator.pop(c, true),
            child: Text(Loc.t('Backup & Merge', 'بیک اپ اور ملائیں')),
          ),
        ],
      ),
    );
  }

  // ---------- Items (search tags) stepper ----------

  Future<void> _saveItemAndAdvance() async {
    if (_untaggedQueue.isEmpty || _busy) return;
    final tag = _itemTag.text.trim();
    if (tag.isEmpty) {
      _toast(Loc.t('Write the English name first', 'پہلے English لکھیں'), seconds: 2);
      return;
    }
    setState(() => _busy = true);
    try {
      await BulkTranslateRepository.instance.saveItemTag(_untaggedQueue.first, tag);
      if (!mounted) return;
      setState(() {
        _untaggedQueue = _untaggedQueue.sublist(1);
        _itemTag.clear();
      });
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Save categories + units ----------

  Future<void> _saveAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final count = await BulkTranslateRepository.instance.saveTranslations(
        categories: {for (final e in _catFields.entries) e.key: e.value.text},
        units: {for (final e in _unitFields.entries) e.key: e.value.text},
      );
      _toast(
        count > 0
            ? Loc.t('$count value(s) translated across all products', '$count ویلیوز تمام پروڈکٹس میں ترجمہ ہو گئیں')
            : Loc.t('Nothing entered to translate', 'ترجمے کے لیے کچھ نہیں لکھا'),
      );
      if (count > 0 && mounted) Navigator.of(context).maybePop();
    } catch (e) {
      _toast(Loc.t('Could not save: $e', 'محفوظ نہیں ہو سکا: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- UI ----------

  Widget _header() => Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.fromLTRB(8, 18, 22, 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [AppColors.navy, AppColors.navyLight]),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.of(context).maybePop()),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(Loc.t('Bulk Translate', 'بلک ترجمہ'),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 6),
              Text(
                Loc.t(
                  'Type the English name once for each Urdu value — it applies to every product using it. For items, you can type more than one English name separated by a comma (e.g. "sugar, chini").',
                  'ہر اردو ویلیو کا English نام ایک بار لکھیں — یہ ہر متعلقہ پروڈکٹ پر لاگو ہوگا۔ آئٹمز کے لیے کاما سے ایک سے زیادہ English نام لکھ سکتے ہیں (مثلاً "sugar, chini")۔',
                ),
                style: const TextStyle(color: AppColors.headerSubtitle, fontSize: 12),
              ),
            ]),
          ),
        ]),
      );

  Widget _toolCard({
    required IconData icon,
    required String title,
    required String body,
    required String button,
    required VoidCallback onTap,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.teal, width: 1.4),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 16, color: AppColors.teal),
            const SizedBox(width: 6),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textDark))),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 14),
            child: Text(body, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _busy ? null : onTap,
              child: Text(button, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
            ),
          ),
        ]),
      );

  Widget _sectionHeader(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.navy, letterSpacing: 0.4)),
      );

  Widget _valueRow(String old, TextEditingController c) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 1.4),
        ),
        child: Row(children: [
          Expanded(child: Text(old, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textDark))),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('→', style: TextStyle(fontSize: 15, color: AppColors.textMuted))),
          Expanded(
            child: TextField(
              controller: c,
              maxLines: 1,
              keyboardType: TextInputType.visiblePassword, // hamesha Latin keyboard (Kotlin jaisa)
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(hintText: Loc.t('English name', 'English نام'), border: InputBorder.none),
            ),
          ),
        ]),
      );

  Widget _itemStepper() {
    if (_untaggedQueue.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(Loc.t('All items tagged', 'تمام آئٹمز ٹیگ ہو گئیں'), style: const TextStyle(fontSize: 13.5, color: AppColors.textMuted)),
          const SizedBox(width: 6),
          const Icon(Icons.check, size: 16, color: AppColors.teal),
        ]),
      );
    }
    final done = _untaggedTotal - _untaggedQueue.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text('${done + 1} ${Loc.t('of', 'از')} $_untaggedTotal', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      ),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.cardWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_untaggedQueue.first, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold, color: AppColors.textDark)),
          const SizedBox(height: 12),
          TextField(
            controller: _itemTag,
            maxLines: 1,
            keyboardType: TextInputType.visiblePassword,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveItemAndAdvance(),
            decoration: InputDecoration(
              hintText: Loc.t('English name(s), e.g. sugar, chini', 'English نام، مثلاً sugar, chini'),
              filled: true,
              fillColor: AppColors.fieldFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                padding: const EdgeInsets.symmetric(vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _busy ? null : _saveItemAndAdvance,
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
    final catsUnitsEmpty = _catFields.isEmpty && _unitFields.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(14), children: [
          _header(),
          _toolCard(
            icon: Icons.build,
            title: Loc.t('Fix Duplicate Unit Names', 'دوہرے یونٹ نام ٹھیک کریں'),
            body: Loc.t(
              'Cleans up unit fields that got typed twice by accident (e.g. "Box\\nBox" -> "Box") across every product, in every category.',
              'وہ یونٹ فیلڈز ٹھیک کرتا ہے جو غلطی سے دو بار لکھے گئے (مثلاً "Box\\nBox" -> "Box") — ہر کیٹیگری کی ہر پروڈکٹ میں۔',
            ),
            button: 'RUN FIX',
            onTap: _runDuplicateUnitFix,
          ),
          _toolCard(
            icon: Icons.merge_type,
            title: Loc.t('Merge Duplicate Products', 'دوہری پروڈکٹس ملائیں'),
            body: Loc.t(
              'Same item saved under more than one barcode (same name and same unit setup) becomes one product with the stock combined. You see the list first; a backup is made before merging. Run "Fix Duplicate Unit Names" first if unit typos exist.',
              'ایک ہی آئٹم جو ایک سے زیادہ بارکوڈ پر محفوظ ہو (ایک ہی نام اور یونٹ سیٹ اپ) ایک پروڈکٹ بن جاتی ہے اور اسٹاک جمع ہو جاتا ہے۔ پہلے فہرست دکھائی جاتی ہے؛ ملانے سے پہلے بیک اپ بنتا ہے۔ یونٹ کی غلطیاں ہوں تو پہلے "دوہرے یونٹ نام ٹھیک کریں" چلائیں۔',
            ),
            button: Loc.t('PREVIEW & MERGE', 'دیکھیں اور ملائیں'),
            onTap: _runMerge,
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text(Loc.t('Loading…', 'لوڈ ہو رہا ہے…'), style: const TextStyle(color: AppColors.textMuted))),
            )
          else ...[
            if (catsUnitsEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(Loc.t('Nothing left to translate', 'ترجمے کے لیے کچھ باقی نہیں'), style: const TextStyle(fontSize: 14, color: AppColors.textMuted)),
                  const SizedBox(width: 6),
                  const Icon(Icons.check, size: 16, color: AppColors.teal),
                ]),
              ),
            if (_catFields.isNotEmpty) ...[
              _sectionHeader(Loc.t('Categories', 'کیٹیگریز')),
              for (final e in _catFields.entries) _valueRow(e.key, e.value),
              const SizedBox(height: 14),
            ],
            if (_unitFields.isNotEmpty) ...[
              _sectionHeader(Loc.t('Units', 'یونٹس')),
              for (final e in _unitFields.entries) _valueRow(e.key, e.value),
              const SizedBox(height: 14),
            ],
            _sectionHeader(Loc.t('Items (search tags)', 'آئٹمز (سرچ ٹیگ)')),
            _itemStepper(),
            const SizedBox(height: 26),
            if (!catsUnitsEmpty)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.navy,
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _busy ? null : _saveAll,
                  icon: const Icon(Icons.save, size: 18),
                  label: Text(Loc.t('SAVE TRANSLATIONS', 'ترجمے محفوظ کریں'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
                ),
              ),
          ],
        ]),
      ),
    );
  }
}
