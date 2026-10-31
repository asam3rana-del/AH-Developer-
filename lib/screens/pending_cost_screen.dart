import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/pending_cost_repository.dart';
import '../utils/loc.dart';

/// Admin tool: "cost pending" bill lines (profit abhi "andaza") ko product ki maujooda cost se pakka karo.
/// Purchase aane par ye khud hota hai; ye un lines ke liye hai jin ki product cost baad mein likhi gayi.
class PendingCostScreen extends StatefulWidget {
  const PendingCostScreen({super.key});

  @override
  State<PendingCostScreen> createState() => _PendingCostScreenState();
}

class _PendingCostScreenState extends State<PendingCostScreen> {
  List<PendingCostLine> _lines = const [];
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
      final lines = await PendingCostRepository.instance.listPending();
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _selected
          ..clear()
          ..addAll(lines.where((l) => l.fillable).map((l) => l.itemId));
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

  List<PendingCostLine> get _chosen => [for (final l in _lines) if (_selected.contains(l.itemId)) l];

  String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _apply() async {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    final change = totalCostChange(chosen);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Pending cost bharen?', 'باقی لاگت بھریں؟')),
        content: Text(Loc.t(
          '${chosen.length} lines ki cost product ki maujooda cost se pakki hogi. '
              'Total cost Rs ${change.abs().toStringAsFixed(0)} ${change >= 0 ? 'barhegi (profit kam)' : 'kam hogi (profit behtar)'}. '
              'Bills sab devices par sync hongi.',
          '${chosen.length} لائنوں کی لاگت پروڈکٹ کی موجودہ لاگت سے پکی ہو جائے گی۔ '
              'کل لاگت Rs ${change.abs().toStringAsFixed(0)} ${change >= 0 ? 'بڑھے گی (منافع کم)' : 'کم ہوگی (منافع بہتر)'}۔ '
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
      final n = await PendingCostRepository.instance.apply(_selected);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Loc.t('$n lines pakki ho gayin', '$n لائنیں پکی ہو گئیں'))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd MMM yyyy');
    final fillable = _lines.where((l) => l.fillable).length;
    return Scaffold(
      appBar: AppBar(title: Text(Loc.t('Pending Cost', 'باقی لاگت'))),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(Loc.t(
                        'Wo bill lines jin ki asal cost abhi purchase se nahi bhari (profit "andaza" hai). '
                            'Product ki cost likhi ho to yahan se pakki kar sakte hain; warna purchase aane par khud bhar jayegi.\n'
                            'Kul: ${_lines.length}  |  Bhar sakti hain: $fillable',
                        'وہ بل لائنیں جن کی اصل لاگت ابھی خریداری سے نہیں بھری (منافع "اندازہ" ہے)۔ '
                            'پروڈکٹ کی لاگت لکھی ہو تو یہاں سے پکی کر سکتے ہیں؛ ورنہ خریداری آنے پر خود بھر جائے گی۔\n'
                            'کل: ${_lines.length}  |  بھر سکتی ہیں: $fillable',
                      )),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final l in _lines)
                            CheckboxListTile(
                              dense: true,
                              value: _selected.contains(l.itemId),
                              onChanged: l.fillable
                                  ? (v) => setState(() {
                                        if (v == true) {
                                          _selected.add(l.itemId);
                                        } else {
                                          _selected.remove(l.itemId);
                                        }
                                      })
                                  : null,
                              title: Text('${l.productName}  (${_n(l.pendingQty)} ${l.smallestUnit})'),
                              subtitle: Text(
                                '${l.party}  |  ${fmt.format(DateTime.fromMillisecondsSinceEpoch(l.createdAt))}  |  #${l.invoice}\n'
                                '${l.fillable ? '' : Loc.t('Product ki cost 0 hai — pehle cost likhen', 'پروڈکٹ کی لاگت 0 ہے — پہلے لاگت لکھیں')}',
                              ),
                              isThreeLine: true,
                              secondary: l.fillable
                                  ? Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text('Rs ${l.pendingEst.toStringAsFixed(0)}',
                                            style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey)),
                                        Text('Rs ${l.newPendingCost.toStringAsFixed(0)}',
                                            style: const TextStyle(fontWeight: FontWeight.w600)),
                                      ],
                                    )
                                  : null,
                            ),
                          if (_lines.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Center(child: Text(Loc.t('Koi pending cost nahi', 'کوئی باقی لاگت نہیں'))),
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
