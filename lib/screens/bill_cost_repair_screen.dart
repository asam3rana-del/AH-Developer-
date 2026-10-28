import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/bill_cost_repair_repository.dart';
import '../utils/loc.dart';

/// Admin tool: purani bills ki ghalat (inflated) cost theek karo — unit ladder badalne ke baad ban jati hai.
class BillCostRepairScreen extends StatefulWidget {
  const BillCostRepairScreen({super.key});

  @override
  State<BillCostRepairScreen> createState() => _BillCostRepairScreenState();
}

class _BillCostRepairScreenState extends State<BillCostRepairScreen> {
  CostRepairPlan? _plan;
  final Set<int> _selected = {};
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
      final plan = await BillCostRepairRepository.instance.buildPlan();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _selected
          ..clear()
          ..addAll(plan.lines.map((l) => l.itemId));
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

  List<CostRepairLine> get _chosen => [
        for (final l in _plan?.lines ?? const <CostRepairLine>[])
          if (_selected.contains(l.itemId)) l,
      ];

  Future<void> _apply() async {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    final gain = chosen.fold<double>(0, (a, l) => a + l.profitGain);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Cost theek karen?', 'لاگت درست کریں؟')),
        content: Text(Loc.t(
          '${chosen.length} lines ki cost badlegi aur profit Rs ${gain.toStringAsFixed(0)} behtar hoga. '
              'Bills sab devices par sync hongi.',
          '${chosen.length} لائنوں کی لاگت بدلے گی اور منافع Rs ${gain.toStringAsFixed(0)} بہتر ہوگا۔ '
              'بلز تمام ڈیوائسز پر سنک ہوں گے۔',
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
      final n = await BillCostRepairRepository.instance.apply(chosen);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('$n lines theek ho gayin', '$n لائنیں درست ہو گئیں'))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final fmt = DateFormat('dd MMM yyyy');
    return Scaffold(
      appBar: AppBar(title: Text(Loc.t('Fix Bill Cost', 'بل کی لاگت درست کریں'))),
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
                            'Wo bill lines jin ki cost sale amount se bohat zyada hai (unit badalne ki ghalti). '
                                'Naya cost = qty x product ki maujooda cost.\n'
                                'Mili: ${plan.lines.length}  |  Chhori (check karen): ${plan.skipped.length}',
                            'وہ بل لائنیں جن کی لاگت سیل رقم سے بہت زیادہ ہے (یونٹ بدلنے کی غلطی)۔ '
                                'نئی لاگت = مقدار x پروڈکٹ کی موجودہ لاگت۔\n'
                                'ملیں: ${plan.lines.length}  |  چھوڑی (چیک کریں): ${plan.skipped.length}',
                          )),
                        ),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final l in plan.lines)
                                CheckboxListTile(
                                  dense: true,
                                  value: _selected.contains(l.itemId),
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _selected.add(l.itemId);
                                    } else {
                                      _selected.remove(l.itemId);
                                    }
                                  }),
                                  title: Text('${l.productName}  (${l.qty.toStringAsFixed(l.qty % 1 == 0 ? 0 : 2)} ${l.unit})'),
                                  subtitle: Text(
                                    '${l.party}  |  ${fmt.format(DateTime.fromMillisecondsSinceEpoch(l.createdAt))}  |  #${l.invoice}\n'
                                    'Sale Rs ${l.amount.toStringAsFixed(0)}',
                                  ),
                                  isThreeLine: true,
                                  secondary: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text('Rs ${l.oldCost.toStringAsFixed(0)}',
                                          style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.red)),
                                      Text('Rs ${l.newCost.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              if (plan.skipped.isNotEmpty) ...[
                                const Divider(),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                  child: Text(Loc.t('Chhori hui lines', 'چھوڑی ہوئی لائنیں'),
                                      style: const TextStyle(fontWeight: FontWeight.w600)),
                                ),
                                for (final s in plan.skipped)
                                  ListTile(
                                    dense: true,
                                    title: Text('${s.productName}  #${s.invoice}'),
                                    subtitle: Text(s.reason),
                                  ),
                              ],
                              if (plan.lines.isEmpty && plan.skipped.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Center(child: Text(Loc.t('Koi shak wali line nahi mili', 'کوئی مشکوک لائن نہیں ملی'))),
                                ),
                            ],
                          ),
                        ),
                        SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _selected.isEmpty ? null : _apply,
                                child: Text(Loc.t('Apply (${_selected.length} lines)', 'لاگو کریں (${_selected.length} لائنیں)')),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
