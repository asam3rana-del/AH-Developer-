import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/reports_repository.dart' show ReportPeriod, reportRangeFor;
import '../db/returns_report_repository.dart';
import '../services/permissions.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';

/// Returns Report: Sale Returns / Purchase Returns ki line-wise list (bill, party, item, qty, amount) + total.
/// Period: Today / This Week / This Month / All Time (Reports hub jaisa).
class ReturnsReportScreen extends StatefulWidget {
  const ReturnsReportScreen({super.key});

  @override
  State<ReturnsReportScreen> createState() => _ReturnsReportScreenState();
}

class _ReturnsReportScreenState extends State<ReturnsReportScreen> {
  final _dateFmt = DateFormat('dd MMM yyyy, hh:mm a');
  late String _type = Permissions.can('sale_history') ? 'sale' : 'purchase';
  ReportPeriod _period = ReportPeriod.month;
  List<ReturnReportRow>? _rows;
  String? _error;
  int _seq = 0;

  AppPalette get _p => ThemeManager.palette;
  String _rs(double v) => 'Rs ${v.round()}';
  String _qty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _rows = null;
      _error = null;
    });
    try {
      final rows = await ReturnsReportRepository.instance.load(_type, reportRangeFor(_period, DateTime.now()));
      if (!mounted || seq != _seq) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = '$e');
    }
  }

  Widget _pill(String label, bool active, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: active ? _p.navy : Colors.transparent, borderRadius: BorderRadius.circular(10)),
            child: Text(label,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: active ? Colors.white : _p.textMuted)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final rows = _rows;
    final canSale = Permissions.can('sale_history');
    final canPurchase = Permissions.can('purchase_history');
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        title: Text(Loc.t('Returns Report', 'واپسی رپورٹ'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(children: [
            if (canSale) _pill(Loc.t('Sale Returns', 'سیل واپسی'), _type == 'sale', () => _switch('sale')),
            if (canPurchase) _pill(Loc.t('Purchase Returns', 'خریداری واپسی'), _type == 'purchase', () => _switch('purchase')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            _pill(Loc.t('Today', 'آج'), _period == ReportPeriod.today, () => _setPeriod(ReportPeriod.today)),
            _pill(Loc.t('Week', 'ہفتہ'), _period == ReportPeriod.week, () => _setPeriod(ReportPeriod.week)),
            _pill(Loc.t('Month', 'مہینہ'), _period == ReportPeriod.month, () => _setPeriod(ReportPeriod.month)),
            _pill(Loc.t('All', 'سب'), _period == ReportPeriod.allTime, () => _setPeriod(ReportPeriod.allTime)),
          ]),
        ),
        if (rows != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: p.cardWhite, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.border)),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('${Loc.t('Total returned', 'کل واپسی')} (${rows.length})',
                    style: TextStyle(fontSize: 13, color: p.textMuted)),
                Text(_rs(returnsTotal(rows)), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: p.red)),
              ]),
            ),
          ),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: TextStyle(color: p.red))))
              : rows == null
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                      ? Center(child: Text(Loc.t('No returns in this period.', 'اس مدت میں کوئی واپسی نہیں۔'), style: TextStyle(color: p.textMuted)))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                          itemCount: rows.length,
                          itemBuilder: (_, i) => _tile(rows[i]),
                        ),
        ),
      ]),
    );
  }

  void _switch(String t) {
    if (t == _type) return;
    _type = t;
    _load();
  }

  void _setPeriod(ReportPeriod v) {
    if (v == _period) return;
    _period = v;
    _load();
  }

  Widget _tile(ReturnReportRow r) {
    final p = _p;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: p.cardWhite, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.border)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.itemName, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 2),
            Text('${_qty(r.qty)}${r.unit.isEmpty ? '' : ' ${r.unit}'}  •  ${r.partyName}',
                style: TextStyle(fontSize: 12, color: p.textMuted)),
            Text('${r.reference}  •  ${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(r.createdAt))}',
                style: TextStyle(fontSize: 11, color: p.textMuted)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(_rs(r.amount), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.red)),
      ]),
    );
  }
}
