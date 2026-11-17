import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../db/reports_repository.dart' show ReportPeriod, reportRangeFor;
import '../db/returns_report_repository.dart';
import '../db/user_repository.dart';
import '../services/permissions.dart';
import '../theme/theme_manager.dart';
import '../utils/bill_text.dart';
import '../utils/loc.dart';

/// Ek return event (ek bill ki ek dafa ki wapsi) ki saari lines — "bill" ki tarah dekhne / share ke liye.
class _ReturnBatch {
  final String reference;
  final String type;
  final String partyName;
  final int createdAt;
  final List<ReturnReportRow> lines;
  const _ReturnBatch(this.reference, this.type, this.partyName, this.createdAt, this.lines);

  double get total => lines.fold(0.0, (a, r) => a + r.amount);
}

List<_ReturnBatch> groupReturnBatches(List<ReturnReportRow> rows) {
  final map = <String, List<ReturnReportRow>>{};
  final order = <String>[];
  for (final r in rows) {
    final key = '${r.reference}|${r.createdAt}';
    (map[key] ??= (order..add(key), <ReturnReportRow>[]).$2).add(r);
  }
  return [
    for (final k in order)
      _ReturnBatch(map[k]!.first.reference, map[k]!.first.type, map[k]!.first.partyName, map[k]!.first.createdAt, map[k]!),
  ];
}

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
                      : Builder(builder: (_) {
                          final batches = groupReturnBatches(rows);
                          return ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                            itemCount: batches.length,
                            itemBuilder: (_, i) => _batchTile(batches[i]),
                          );
                        }),
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

  /// Ek return event ka card — dusre bills ki tarah, tap par poori receipt (Share / Copy).
  Widget _batchTile(_ReturnBatch b) {
    final p = _p;
    final items = b.lines.map((l) => l.itemName).take(3).join(', ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: p.cardWhite, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.border)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _viewReceipt(b),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.partyName, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.textDark)),
                  const SizedBox(height: 2),
                  Text('${b.lines.length} ${Loc.t('item(s)', 'آئٹم')}: $items${b.lines.length > 3 ? '…' : ''}',
                      style: TextStyle(fontSize: 12, color: p.textMuted), maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text('${b.reference}  •  ${_dateFmt.format(DateTime.fromMillisecondsSinceEpoch(b.createdAt))}',
                      style: TextStyle(fontSize: 11, color: p.textMuted)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.receipt_long, size: 14, color: p.navy),
                    const SizedBox(width: 4),
                    Text(Loc.t('View receipt', 'رسید دیکھیں'), style: TextStyle(fontSize: 12, color: p.navy, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              Text('- ${_rs(b.total)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.red)),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _viewReceipt(_ReturnBatch b) async {
    final repo = UserRepository.instance;
    final shopName = (await repo.getSetting('shop_name')) ?? '';
    final shopOwner = (await repo.getSetting('shop_owner')) ?? '';
    final shopPhone = (await repo.getSetting('shop_phone')) ?? '';
    final date = DateTime.fromMillisecondsSinceEpoch(b.createdAt);
    final String text;
    if (b.type == 'sale') {
      text = buildSaleReturnText(
        shopName: shopName,
        shopOwner: shopOwner,
        shopPhone: shopPhone,
        invoice: b.reference,
        date: date,
        customer: b.partyName,
        lines: [
          for (final l in b.lines)
            (name: l.itemName, qty: l.qty, unit: l.unit, rate: l.qty > 0 ? l.amount / l.qty : l.amount, amount: l.amount),
        ],
        returnedTotal: b.total,
      );
    } else {
      text = buildPurchaseReturnText(
        shopName: shopName,
        shopOwner: shopOwner,
        shopPhone: shopPhone,
        billNo: b.reference,
        date: date,
        supplier: b.partyName,
        lines: [
          for (final l in b.lines)
            (name: l.itemName, qty: l.qty, unit: l.unit, unitCost: l.qty > 0 ? l.amount / l.qty : l.amount, amount: l.amount),
        ],
        returnedTotal: b.total,
      );
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Loc.t('Return receipt', 'واپسی کی رسید')),
        content: SingleChildScrollView(
          child: Container(
            width: double.maxFinite,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: _p.bg, borderRadius: BorderRadius.circular(8)),
            child: Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(Loc.t('Copy', 'کاپی')),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
          FilledButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: Text(Loc.t('Share', 'شیئر')),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await Share.share(text);
              } catch (_) {
                await Clipboard.setData(ClipboardData(text: text));
              }
            },
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(Loc.t('Close', 'بند کریں'))),
        ],
      ),
    );
  }
}
