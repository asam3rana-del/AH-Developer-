import 'package:flutter/material.dart';

import '../db/reports_repository.dart';
import '../theme/theme_manager.dart';
import '../utils/loc.dart';
import 'balance_sheet_screen.dart';
import 'due_reminders_screen.dart';
import 'history_screen.dart';
import 'inventory_insights_screen.dart';
import 'monthly_screen.dart';
import 'daily_bills_screen.dart';
import 'party_reports_screen.dart';
import 'payments_screen.dart';
import 'rate_comparison_screen.dart';
import 'stock_audit_screen.dart';
import 'stock_movement_screen.dart';
import 'stock_report_screen.dart';
import '../widgets/role_guard.dart';
import '../services/permissions.dart';
import '../widgets/permission_guard.dart';

/// Mirrors ReportsActivity.kt.
///
/// Reports hub (sirf reports: sale & purchase / party / stock / financial) + neeche period filter (Today / This Week / This Month /
/// All Time) ke saath summary cards (Purchases / Returns / Number of Sales; Total Sales, Profit aur Expenses
/// alag card nahi — woh Profit & Loss statement mein hi hain), Profit & Loss statement, Top Products aur Daily Sales.
///
/// Access: Permissions (role ke default + admin ke per-user override); ReportsRepository.load dobara check karta hai.
///
/// Farq (Kotlin se):
///  * Har row / section admin ke diye hue per-user access (Permissions) se dikhta hai; admin ko sab.
///  * Action tools ab yahan nahi: Stock Adjustment / Stock Taking / Fix Bill Cost = Items screen, Cash Register = Cash & Bank,
///    Zakat = Settings.
///  * Stock/Insights ki sab rows ab chalti hain (Reorder / Damage / Margin / Movers = ek row "Inventory Insights", andar 4 tab).
///  * "Today" ka end agla midnight (DST-safe); hafta Monday se (Kotlin mein locale ka firstDayOfWeek).
///  * Purchase History row manager ko dikhti hai magar screen admin-only hai (RoleGuard message).
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const PermissionGuard(anyOf: Permissions.reportKeys, child: _ReportsBody());
}

class _ReportsBody extends StatefulWidget {
  const _ReportsBody();

  @override
  State<_ReportsBody> createState() => _ReportsBodyState();
}

class _ReportsBodyState extends State<_ReportsBody> {
  final _repo = ReportsRepository.instance;

  ReportPeriod _period = ReportPeriod.today;
  ReportData? _data;
  String? _error;
  int _loadSeq = 0;
  bool _started = false;

  AppPalette get _p => ThemeManager.palette;
  String _rs(double v) => 'Rs ${v.round()}';
  String _qty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  @override
  void initState() {
    super.initState();
    if (_showSummary) _load();
    // Admin ne dusre device par rules badle hon to sync ke baad yahan nazar aa jayen.
    Permissions.refresh().then((_) {
      if (!mounted) return;
      setState(() {});
      if (_showSummary && !_started) _load();
    });
  }

  bool _can(String key) => Permissions.can(key);
  bool _anyOf(List<String> keys) => Permissions.canAny(keys);
  bool get _showSummary => Permissions.can('reports_summary');

  /// Jin screens ka apna guard nahi (sab roles ke liye khuli hain) un ke liye hub se guard lagta hai.
  void _openG(String key, Widget screen) => _open(PermissionGuard(permission: key, child: screen));

  Future<void> _load() async {
    _started = true;
    final seq = ++_loadSeq;
    setState(() {
      _data = null;
      _error = null;
    });
    try {
      final d = await _repo.load(reportRangeFor(_period, DateTime.now()));
      if (!mounted || seq != _loadSeq) return;
      setState(() => _data = d);
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _error = e.toString());
    }
  }

  void _setPeriod(ReportPeriod p) {
    if (p == _period) return;
    setState(() => _period = p);
    _load();
  }

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  String get _periodLabel {
    switch (_period) {
      case ReportPeriod.today:
        return Loc.t('SHOWING: TODAY', 'دکھایا جا رہا ہے: آج');
      case ReportPeriod.week:
        return Loc.t('SHOWING: THIS WEEK', 'دکھایا جا رہا ہے: اس ہفتے');
      case ReportPeriod.month:
        return Loc.t('SHOWING: THIS MONTH', 'دکھایا جا رہا ہے: اس مہینے');
      case ReportPeriod.allTime:
        return Loc.t('SHOWING: ALL TIME', 'دکھایا جا رہا ہے: تمام وقت');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
          children: [
            _header(p),
            if (_anyOf(const ['sale_history', 'purchase_history', 'daily_bills', 'monthly', 'rate_comparison']))
              _section(p, Loc.t('Sale & purchase reports', 'سیل اور خریداری رپورٹس')),
            if (_can('sale_history'))
              _row(p, Loc.t('Sale History', 'سیل کی تاریخ'), Loc.t('View all sale transactions', 'تمام سیل لین دین دیکھیں'),
                  p.flatBlueFg, () => _openG('sale_history', const HistoryScreen(mode: HistoryMode.sales))),
            if (_can('purchase_history'))
              _row(p, Loc.t('Purchase History', 'خریداری کی تاریخ'),
                  Loc.t('View all purchase transactions', 'تمام خریداری لین دین دیکھیں'), const Color(0xFF993C1D),
                  () => _open(const HistoryScreen(mode: HistoryMode.purchases))),
            if (_can('daily_bills'))
              _row(p, Loc.t('Daily Bills', 'روزانہ بلز'),
                  Loc.t('Har customer ka din ka ek bill + balance', 'ہر کسٹمر کا دن کا ایک بل اور بیلنس'), p.flatTealFg,
                  () => _open(const DailyBillsScreen())),
            if (_can('monthly'))
              _row(p, Loc.t('Sale vs Purchase — Month/Year', 'سیل بمقابلہ خریداری — مہینہ/سال'),
                  Loc.t('Total sale & purchase, broken down by month or year', 'کل سیل اور خریداری، مہینہ یا سال کے مطابق'),
                  p.flatBlueFg, () => _open(const MonthlyScreen())),
            if (_can('rate_comparison'))
              _row(p, Loc.t('Rate Comparison', 'ریٹ کا موازنہ'),
                  Loc.t('Compare supplier rates per item', 'فی آئٹم سپلائرز کے ریٹ کا موازنہ'), p.flatTealFg,
                  () => _openG('rate_comparison', const RateComparisonScreen())),
            if (_anyOf(const ['party_reports', 'payments_report', 'due_reminders']))
              _section(p, Loc.t('Party reports', 'پارٹی رپورٹس')),
            if (_can('party_reports'))
              _row(p, Loc.t('Party Reports', 'پارٹی رپورٹس'),
                  Loc.t('Customer & supplier balances', 'کسٹمر اور سپلائر کا بیلنس'), p.flatBlueFg,
                  () => _open(const PartyReportsScreen())),
            if (_can('payments_report'))
              _row(p, Loc.t('Payments Report', 'ادائیگیوں کی رپورٹ'),
                  Loc.t('Payments received vs made, by period', 'ادائیگیاں وصول اور ادا، مدت کے مطابق'), p.flatTealFg,
                  () => _openG('payments_report', const PaymentsScreen())),
            if (_can('due_reminders'))
              _row(p, Loc.t('Due Date Reminders', 'ادائیگی کی یاد دہانی'),
                  Loc.t('Credit sales still owed, by due date', 'ادھار سیلز جو واجب الادا ہیں'), p.flatBlueFg,
                  () => _open(const DueRemindersScreen())),
            if (_anyOf(const ['stock_report', 'stock_history', 'cost_history', 'stock_audit', 'inventory_insights']))
              _section(p, Loc.t('Stock reports', 'اسٹاک رپورٹس')),
            if (_can('stock_report'))
              _row(p, Loc.t('Stock Report', 'اسٹاک رپورٹ'), Loc.t('Current inventory levels', 'موجودہ انوینٹری کی سطح'),
                  p.flatAmberFg, () => _openG('stock_report', const StockReportScreen())),
            if (_can('stock_history'))
              _row(p, Loc.t('Stock History', 'اسٹاک کی تاریخ'),
                  Loc.t('Every purchase, sale & adjustment per item', 'ہر آئٹم کی خریداری، سیل اور ایڈجسٹمنٹ'),
                  p.flatBlueFg, () => _open(const StockMovementScreen(mode: StockMovementMode.stock))),
            if (_can('cost_history'))
              _row(p, Loc.t('Cost History', 'لاگت کی تاریخ'),
                  Loc.t("How a product's cost changed over time", 'پروڈکٹ کی لاگت وقت کے ساتھ کیسے بدلی'),
                  p.flatTealFg, () => _open(const StockMovementScreen(mode: StockMovementMode.cost))),
            if (_can('stock_audit'))
              _row(p, Loc.t('Stock Audit', 'اسٹاک آڈٹ'),
                  Loc.t("Find products where stock doesn't match its own history", 'وہ پروڈکٹس جن کا اسٹاک اپنی تاریخ سے میچ نہیں کرتا'),
                  p.red, () => _open(const StockAuditScreen())),
            // Reorder / Damage / Margin / Movers ek hi screen ke 4 tab hain — pehle 4 alag rows thin (duplicate).
            if (_can('inventory_insights'))
              _row(p, Loc.t('Inventory Insights', 'انوینٹری تجزیہ'),
                  Loc.t('Reorder, Damage / Loss, Profit Margin & Fast / Slow Movers', 'دوبارہ آرڈر، نقصان، منافع اور تیز / سست چلنے والے'),
                  p.flatAmberFg, () => _open(const InventoryInsightsScreen(initialMode: InsightsMode.reorder))),
            if (_can('balance_sheet')) ...[
              _section(p, Loc.t('Financial reports', 'مالیاتی رپورٹس')),
              _row(p, Loc.t('Balance Sheet', 'بیلنس شیٹ'), Loc.t('Assets, liabilities & capital', 'اثاثے، واجبات اور سرمایہ'),
                  p.flatTealFg, () => _openG('balance_sheet', const BalanceSheetScreen())),
            ],
            if (_showSummary) ...[
              const SizedBox(height: 4),
              _filterBar(p),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 14, 0, 6),
                child: Text(_periodLabel,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: p.textMuted)),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.red)),
                )
              else if (_data == null)
                const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()))
              else
                ..._results(p, _data!),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- header / rows ----------
  Widget _header(AppPalette p) => Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.fromLTRB(8, 14, 16, 14),
        decoration: _box(p, 22),
        child: Row(children: [
          IconButton(
              icon: Icon(Icons.arrow_back, color: p.textDark), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: p.flatBlueBg, shape: BoxShape.circle),
            child: Icon(Icons.bar_chart, color: p.flatBlueFg, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Loc.t('Reports', 'رپورٹس'),
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: p.textDark)),
              const SizedBox(height: 4),
              Text(Loc.t('Sales, stock & financial overview', 'سیل، اسٹاک اور مالیاتی جائزہ'),
                  style: TextStyle(fontSize: 11, color: p.textMuted)),
            ]),
          ),
        ]),
      );

  BoxDecoration _box(AppPalette p, double r) => BoxDecoration(
        color: p.cardWhite,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: p.border),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))],
      );

  Widget _section(AppPalette p, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
        child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
      );

  Widget _row(AppPalette p, String title, String subtitle, Color accent, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            decoration: _box(p, 18),
            child: Row(children: [
              Container(width: 4, height: 34, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: p.textDark)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
                ]),
              ),
              Icon(Icons.chevron_right, color: p.textMuted),
            ]),
          ),
        ),
      );

  Widget _filterBar(AppPalette p) {
    Widget pill(String label, ReportPeriod v) {
      final active = _period == v;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _setPeriod(v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: active ? p.flatBlueFg : Colors.transparent, borderRadius: BorderRadius.circular(10)),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: active ? Colors.white : p.textMuted)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
          color: p.cardWhite, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        pill(Loc.t('Today', 'آج'), ReportPeriod.today),
        pill(Loc.t('This Week', 'اس ہفتے'), ReportPeriod.week),
        pill(Loc.t('This Month', 'اس مہینے'), ReportPeriod.month),
        pill(Loc.t('All Time', 'تمام وقت'), ReportPeriod.allTime),
      ]),
    );
  }

  // ---------- results ----------
  List<Widget> _results(AppPalette p, ReportData d) => [
        _summary(p, Icons.receipt_long, Loc.t('Total Purchases', 'کل خریداری'), _rs(d.totalPurchases), p.flatAmberFg, p.flatAmberBg),
        _summary(p, Icons.undo, Loc.t('Sale Returns', 'سیل کی واپسی'), _rs(d.saleReturns), p.flatPinkFg, p.flatPinkBg),
        _summary(p, Icons.undo, Loc.t('Purchase Returns', 'خریداری کی واپسی'), _rs(d.purchaseReturns), p.flatTealFg, p.flatTealBg),
        _summary(p, Icons.tag, Loc.t('Number of Sales', 'سیلز کی تعداد'), '${d.saleCount}', p.flatBlueFg, p.flatBlueBg),
        const SizedBox(height: 10),
        _profitLoss(p, d.pl),
        const SizedBox(height: 14),
        _listCard(
          p,
          Loc.t('Top Products', 'ٹاپ پروڈکٹس'),
          d.topProducts.isEmpty ? Loc.t('No sales in this period', 'اس مدت میں کوئی سیل نہیں ہوئی') : null,
          [for (final t in d.topProducts) _rowText(p, t.product, '${_qty(t.totalQty)} ${Loc.t('sold', 'فروخت شدہ')}')],
        ),
        const SizedBox(height: 14),
        _listCard(
          p,
          Loc.t('Daily Sales', 'روزانہ سیل'),
          d.dailySales.isEmpty ? Loc.t('No data', 'کوئی ڈیٹا نہیں') : null,
          [for (final s in d.dailySales) _rowText(p, s.day, _rs(s.total))],
        ),
      ];

  Widget _summary(AppPalette p, IconData icon, String label, String value, Color accent, Color tint) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        decoration: _box(p, 18),
        child: Row(children: [
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 18)),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: p.textMuted)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: accent)),
            ]),
          ),
        ]),
      );

  Widget _profitLoss(AppPalette p, ProfitLoss pl) {
    final netColor = pl.isLoss ? p.red : p.flatTealFg;
    Widget line(String label, double amount, Color color, {bool bold = false, bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: big ? 15 : 13.5,
                      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                      color: bold ? p.textDark : p.textMuted)),
            ),
            Text(_rs(amount),
                style: TextStyle(
                    fontSize: big ? 16 : 13.5, fontWeight: bold ? FontWeight.bold : FontWeight.normal, color: color)),
          ]),
        );
    Widget divider() => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Divider(height: 2, color: p.border));

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: _box(p, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.bar_chart, size: 15, color: p.textDark),
          const SizedBox(width: 8),
          Text(Loc.t('Profit & Loss Statement', 'منافع اور نقصان کا بیان'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
        ]),
        const SizedBox(height: 14),
        line(Loc.t('Sales Revenue', 'سیل کی آمدنی'), pl.revenue, p.textDark),
        line(Loc.t('(-) Cost of Goods Sold', '(-) فروخت شدہ سامان کی لاگت'), pl.cogs, p.red),
        divider(),
        line(Loc.t('Gross Profit', 'مجموعی منافع'), pl.grossProfit, p.flatBlueFg, bold: true),
        const SizedBox(height: 4),
        if (pl.otherIncome != 0)
          line(Loc.t('(+) Other Income (Rent Received etc.)', '(+) دیگر آمدنی (کرایہ وصول وغیرہ)'), pl.otherIncome,
              p.flatTealFg),
        line(Loc.t('(-) Operating Expenses', '(-) آپریٹنگ اخراجات'), pl.expenses, p.red),
        divider(),
        line(pl.isLoss ? Loc.t('Net Loss', 'خالص نقصان') : Loc.t('Net Profit', 'خالص منافع'), pl.netProfit, netColor,
            bold: true, big: true),
      ]),
    );
  }

  Widget _listCard(AppPalette p, String title, String? emptyMsg, List<Widget> rows) => Container(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        decoration: _box(p, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: p.textDark)),
          const SizedBox(height: 8),
          if (emptyMsg != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(emptyMsg, style: TextStyle(fontSize: 13, color: p.textMuted)))
          else
            ...rows,
        ]),
      );

  Widget _rowText(AppPalette p, String left, String right) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(children: [
          Expanded(child: Text(left, style: TextStyle(fontSize: 14, color: p.textDark))),
          Text(right, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: p.flatBlueFg)),
        ]),
      );
}
