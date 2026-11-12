import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../db/unit_cost.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../theme/theme_manager.dart';
import '../utils/expiry.dart';
import '../utils/loc.dart';

/// Expiry report: jo maal expire ho chuka ya [expiryWarnDays] din mein hone wala hai (sirf jis ka stock hai).
/// Pehle sab se pehle wala. Admin / Manager ko cost par qeemat bhi (kitna nuqsan ho sakta hai).
/// Expiry Items screen mein har product par lagti hai (products.expiry).
class ExpiryReportScreen extends StatefulWidget {
  const ExpiryReportScreen({super.key});

  @override
  State<ExpiryReportScreen> createState() => _ExpiryReportScreenState();
}

class _ExpiryReportScreenState extends State<ExpiryReportScreen> {
  List<ExpiryRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await AppDatabase.instance.database;
      final products = (await db.query('products')).map(Product.fromMap).toList();
      final rows = buildExpiryList(products);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  double _value(Product p) => p.stock * costPerSmallestOf(p.cost, p.smallestUnitFactor());

  String _rs(double v) => 'Rs ${v.round()}';

  String _when(ExpiryRow r) {
    if (r.daysLeft < 0) {
      return Loc.t('Expired ${-r.daysLeft} day(s) ago', '${-r.daysLeft} دن پہلے ایکسپائر');
    }
    if (r.daysLeft == 0) return Loc.t('Expires today', 'آج ایکسپائر');
    return Loc.t('${r.daysLeft} day(s) left', '${r.daysLeft} دن باقی');
  }

  @override
  Widget build(BuildContext context) {
    final p = ThemeManager.palette;
    final rows = _rows;
    final showCost = Session.isAdminOrManager;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.navy,
        foregroundColor: Colors.white,
        title: Text(Loc.t('Expiry Report', 'ایکسپائری رپورٹ')),
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : rows == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    _summary(p, rows, showCost),
                    const SizedBox(height: 12),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          Loc.t(
                            'Nothing expired or expiring in the next $expiryWarnDays days.\n\n'
                                'Set an expiry date on an item: Items → edit → Expiry date.',
                            'اگلے $expiryWarnDays دن میں کچھ ایکسپائر نہیں ہو رہا۔\n\n'
                                'آئٹم پر ایکسپائری لگائیں: Items ← ترمیم ← Expiry date۔',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.textMuted),
                        ),
                      ),
                    for (final r in rows) _row(p, r, showCost),
                  ]),
                ),
    );
  }

  Widget _summary(AppPalette p, List<ExpiryRow> rows, bool showCost) {
    final expired = rows.where((r) => r.status == ExpiryStatus.expired).toList();
    final soon = rows.where((r) => r.status == ExpiryStatus.soon).toList();
    double sum(List<ExpiryRow> l) => l.fold(0.0, (a, r) => a + _value(r.product));
    Widget box(String title, int count, double value, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.cardWhite, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 12, color: p.textMuted)),
              const SizedBox(height: 4),
              Text('$count', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
              if (showCost) Text(_rs(value), style: TextStyle(fontSize: 12.5, color: color)),
            ]),
          ),
        );
    return Row(children: [
      box(Loc.t('Expired', 'ایکسپائر ہو چکا'), expired.length, sum(expired), p.red),
      const SizedBox(width: 10),
      box(Loc.t('Within $expiryWarnDays days', '$expiryWarnDays دن کے اندر'), soon.length, sum(soon), p.amber),
    ]);
  }

  Widget _row(AppPalette p, ExpiryRow r, bool showCost) {
    final color = r.status == ExpiryStatus.expired ? p.red : p.amber;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.product.name, style: TextStyle(fontWeight: FontWeight.bold, color: p.textDark)),
            const SizedBox(height: 2),
            Text(r.product.formatStockBreakdown(), style: TextStyle(fontSize: 12, color: p.textMuted)),
            const SizedBox(height: 2),
            Text('${DateFormat('dd MMM yyyy').format(r.expiry)} • ${_when(r)}',
                style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
          ]),
        ),
        if (showCost) Text(_rs(_value(r.product)), style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}
