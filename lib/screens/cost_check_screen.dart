import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/cost_check_repository.dart';
import '../utils/loc.dart';
import 'bill_cost_repair_screen.dart';

/// Admin tool: jin products ki average cost aakhri purchase rate se bohat door hai (kharab purchases
/// delete/edit hone se), unki cost aakhri purchase rate par lagao.
class CostCheckScreen extends StatefulWidget {
  const CostCheckScreen({super.key});

  @override
  State<CostCheckScreen> createState() => _CostCheckScreenState();
}

class _CostCheckScreenState extends State<CostCheckScreen> {
  List<CostCheckRow> _rows = const [];
  final Set<String> _selected = {};
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
      final rows = await CostCheckRepository.instance.scan();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selected
          ..clear()
          ..addAll(rows.map((r) => r.product.barcode));
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

  String _rs(double v) => v.toStringAsFixed(v >= 100 ? 0 : 2);

  Future<void> _apply() async {
    final chosen = {
      for (final r in _rows)
        if (_selected.contains(r.product.barcode)) r.product.barcode: r.lastRate,
    };
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = await CostCheckRepository.instance.applyCosts(chosen);
      if (!mounted) return;
      final goRepair = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(Loc.t('$n items ki cost theek ho gayi', '$n آئٹمز کی لاگت درست ہو گئی')),
          content: Text(Loc.t(
            'Ab se nayi sales sahi cost par banengi.\n\n'
                'Purani bills jin par ghalat (zyada) cost lagi thi, unhein "Fix Bill Cost" se theek karen?',
            'اب سے نئی سیلز درست لاگت پر بنیں گی۔\n\n'
                'پرانے بلز جن پر غلط (زیادہ) لاگت لگی تھی، انہیں "Fix Bill Cost" سے درست کریں؟',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Loc.t('Baad mein', 'بعد میں'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Loc.t('Fix Bill Cost', 'بل کی لاگت'))),
          ],
        ),
      );
      if (!mounted) return;
      if (goRepair == true) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BillCostRepairScreen()));
      }
      if (mounted) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd MMM yyyy');
    return Scaffold(
      appBar: AppBar(title: Text(Loc.t('Cost Check', 'لاگت چیک'))),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(Loc.t(
                      'Wo items jin ki average cost aakhri purchase rate se bohat zyada ya kam hai '
                          '(aksar purani kharab purchases delete/edit karne se). Inki wajah se sale par loss dikhta hai.\n'
                          'Apply = cost aakhri purchase rate par.  Mile: ${_rows.length}',
                      'وہ آئٹمز جن کی اوسط لاگت آخری خریداری ریٹ سے بہت زیادہ یا کم ہے '
                          '(اکثر پرانی خراب خریداریاں ڈیلیٹ/ایڈٹ کرنے سے)۔ ان کی وجہ سے سیل پر نقصان دکھتا ہے۔\n'
                          'لاگو = لاگت آخری خریداری ریٹ پر۔  ملے: ${_rows.length}',
                    )),
                  ),
                  Expanded(
                    child: _rows.isEmpty
                        ? Center(child: Text(Loc.t('Sab items ki cost theek hai', 'تمام آئٹمز کی لاگت درست ہے')))
                        : ListView(children: [
                            for (final r in _rows)
                              CheckboxListTile(
                                dense: true,
                                value: _selected.contains(r.product.barcode),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(r.product.barcode);
                                  } else {
                                    _selected.remove(r.product.barcode);
                                  }
                                }),
                                title: Text(r.product.name),
                                subtitle: Text(
                                  '${Loc.t('Aakhri purchase', 'آخری خریداری')}: ${fmt.format(DateTime.fromMillisecondsSinceEpoch(r.lastAt))}'
                                  '  |  ${r.product.unit}',
                                ),
                                secondary: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('Rs ${_rs(r.avg)}',
                                        style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.red)),
                                    Text('Rs ${_rs(r.lastRate)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                          ]),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _selected.isEmpty ? null : _apply,
                          child: Text(Loc.t('Apply (${_selected.length} items)', 'لاگو کریں (${_selected.length} آئٹمز)')),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }
}
