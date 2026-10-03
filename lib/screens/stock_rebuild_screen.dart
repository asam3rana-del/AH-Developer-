import 'package:flutter/material.dart';

import '../db/stock_rebuild_repository.dart';
import '../db/stock_taking_repository.dart';
import '../utils/loc.dart';

/// Ek martaba: stock = September ki purchase - uske baad ki sales (sirf Sep purchase wale items).
class StockRebuildScreen extends StatefulWidget {
  const StockRebuildScreen({super.key});

  @override
  State<StockRebuildScreen> createState() => _StockRebuildScreenState();
}

class _StockRebuildScreenState extends State<StockRebuildScreen> {
  StockRebuildPlan? _plan;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await StockRebuildRepository.instance.buildPlan();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || plan.lines.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Stock set karen?', 'اسٹاک سیٹ کریں؟')),
        content: Text(Loc.t(
          '${plan.lines.length} items ka stock badlega aur sab devices par sync hoga. Ye ek martaba ka kaam hai.',
          '${plan.lines.length} آئٹمز کا اسٹاک بدلے گا اور سب ڈیوائسز پر سنک ہوگا۔ یہ ایک بار کا کام ہے۔',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(Loc.t('Cancel', 'منسوخ کریں'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(Loc.t('Apply', 'لاگو کریں'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await StockRebuildRepository.instance.apply(plan);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('Stock set ho gaya', 'اسٹاک سیٹ ہو گیا'))));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: Text(Loc.t('Stock Rebuild (September)', 'اسٹاک ری بلڈ (ستمبر)'))),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : plan == null
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(Loc.t(
                            'Stock = September ki purchase - uske baad ki sales.\n'
                                'Badlega: ${plan.lines.length} items  |  Pehle se theek: ${plan.unchanged}'
                                '${plan.skippedInvalid > 0 ? '  |  Chhore (fraction): ${plan.skippedInvalid}' : ''}',
                            'اسٹاک = ستمبر کی خریداری - اس کے بعد کی سیلز۔\n'
                                'بدلے گا: ${plan.lines.length} آئٹمز  |  پہلے سے ٹھیک: ${plan.unchanged}'
                                '${plan.skippedInvalid > 0 ? '  |  چھوڑے (فریکشن): ${plan.skippedInvalid}' : ''}',
                          )),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: plan.lines.length,
                            itemBuilder: (_, i) {
                              final l = plan.lines[i];
                              final unit = l.product.smallestUnitName();
                              return ListTile(
                                dense: true,
                                title: Text(l.product.name),
                                subtitle: Text(
                                  'Purchase ${formatStockTakeQty(l.purchased)} - Sale ${formatStockTakeQty(l.soldAfter)} $unit'
                                  '${l.clamped ? '  (0 par roka)' : ''}',
                                ),
                                trailing: Text('${formatStockTakeQty(l.product.stock)} → ${formatStockTakeQty(l.target)}'),
                              );
                            },
                          ),
                        ),
                        SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: plan.lines.isEmpty ? null : _apply,
                                child: Text(Loc.t('Apply (ek martaba)', 'لاگو کریں (ایک بار)')),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
