import '../services/session.dart';
import 'app_database.dart';

/// Ports the data side of ReportsActivity.kt (`loadReport`).
///
/// Admin / Manager only: [ReportsRepository.load] dobara role check karta hai
/// (screen bhi RoleGuard mein hai) kyunke ye cost / profit data padhta hai.
/// Maths PURE functions mein hai ([reportRangeFor], [buildProfitLoss]) — test/reports_test.dart.

enum ReportPeriod { today, week, month, allTime }

/// Inclusive [start, end] in epoch millis (SQL `BETWEEN`, jaise Kotlin).
class ReportRange {
  final int start;
  final int end;
  const ReportRange(this.start, this.end);
}

/// Kotlin setRangeToday/ThisWeek/ThisMonth/AllTime.
/// Farq: "Today" ka end agla midnight - 1ms (DST-safe; Kotlin `+24h` ka end bhi shamil tha).
/// Hafta Monday se shuru (Kotlin `Calendar.firstDayOfWeek` locale par chalta hai).
ReportRange reportRangeFor(ReportPeriod period, DateTime now) {
  final midnight = DateTime(now.year, now.month, now.day);
  switch (period) {
    case ReportPeriod.today:
      final next = DateTime(now.year, now.month, now.day + 1);
      return ReportRange(midnight.millisecondsSinceEpoch, next.millisecondsSinceEpoch - 1);
    case ReportPeriod.week:
      final monday = DateTime(now.year, now.month, now.day - (now.weekday - DateTime.monday));
      return ReportRange(monday.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    case ReportPeriod.month:
      return ReportRange(DateTime(now.year, now.month, 1).millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    case ReportPeriod.allTime:
      return ReportRange(0, now.millisecondsSinceEpoch);
  }
}

/// Profit & Loss card: Revenue - COGS = Gross; Gross - Expenses = Net.
class ProfitLoss {
  final double revenue;
  final double cogs;
  final double expenses;
  const ProfitLoss(this.revenue, this.cogs, this.expenses);

  double get grossProfit => revenue - cogs;
  double get netProfit => grossProfit - expenses;
  bool get isLoss => netProfit < 0;
}

ProfitLoss buildProfitLoss({required double sales, required double cogs, required double expenses}) =>
    ProfitLoss(sales, cogs, expenses);

class TopProductRow {
  final String product;
  final double totalQty;
  const TopProductRow(this.product, this.totalQty);
}

class DailySalesRow {
  final String day;
  final double total;
  const DailySalesRow(this.day, this.total);
}

class ReportData {
  final double totalSales;
  final double totalProfit;
  final double totalPurchases;
  final double totalExpenses;
  final double saleReturns;
  final double purchaseReturns;
  final int saleCount;
  final ProfitLoss pl;
  final List<TopProductRow> topProducts;
  final List<DailySalesRow> dailySales;

  const ReportData({
    required this.totalSales,
    required this.totalProfit,
    required this.totalPurchases,
    required this.totalExpenses,
    required this.saleReturns,
    required this.purchaseReturns,
    required this.saleCount,
    required this.pl,
    required this.topProducts,
    required this.dailySales,
  });
}

class ReportsRepository {
  ReportsRepository._();
  static final ReportsRepository instance = ReportsRepository._();

  Future<ReportData> load(ReportRange r) async {
    if (!Session.isAdminOrManager) {
      throw StateError('Sirf Admin/Manager is screen ko access kar sakta hai');
    }
    final db = await AppDatabase.instance.database;
    final args = [r.start, r.end];

    Future<double> scalar(String sql, List<Object?> a) async {
      final rows = await db.rawQuery(sql, a);
      if (rows.isEmpty) return 0.0;
      return ((rows.first.values.first) as num?)?.toDouble() ?? 0.0;
    }

    final totalSales = await scalar(
        "SELECT COALESCE(SUM(total),0) FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args);
    // Kotlin profitBetween: sale.total (discount ke baad) - us bill ka COGS.
    final totalProfit = await scalar(
        'SELECT COALESCE(SUM(s.total - (SELECT COALESCE(SUM(si.cost),0) FROM sale_items si WHERE si.invoice = s.invoice)),0) '
        "FROM sales s WHERE s.createdAt BETWEEN ? AND ? AND s.status!='returned'",
        args);
    final totalPurchases = await scalar(
        "SELECT COALESCE(SUM(total),0) FROM purchases WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args);
    final totalExpenses =
        await scalar('SELECT COALESCE(SUM(amount),0) FROM expenses WHERE createdAt BETWEEN ? AND ?', args);
    final saleCount = (await scalar(
            "SELECT COUNT(*) FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args))
        .toInt();
    final saleReturns = await scalar(
        "SELECT COALESCE(SUM(amount),0) FROM returns WHERE type='sale' AND createdAt BETWEEN ? AND ?", args);
    final purchaseReturns = await scalar(
        "SELECT COALESCE(SUM(amount),0) FROM returns WHERE type='purchase' AND createdAt BETWEEN ? AND ?", args);
    final cogs = await scalar(
        'SELECT COALESCE(SUM(si.cost),0) FROM sale_items si JOIN sales s ON si.invoice=s.invoice '
        "WHERE s.createdAt BETWEEN ? AND ? AND s.status!='returned'",
        args);

    final top = await db.rawQuery(
        'SELECT product, SUM(qty) as totalQty FROM sale_items WHERE invoice IN '
        "(SELECT invoice FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned') "
        'GROUP BY product ORDER BY totalQty DESC LIMIT 5',
        args);
    final daily = await db.rawQuery(
        "SELECT strftime('%Y-%m-%d', createdAt/1000, 'unixepoch', 'localtime') as day, COALESCE(SUM(total),0) as total "
        "FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned' GROUP BY day ORDER BY day",
        args);

    return ReportData(
      totalSales: totalSales,
      totalProfit: totalProfit,
      totalPurchases: totalPurchases,
      totalExpenses: totalExpenses,
      saleReturns: saleReturns,
      purchaseReturns: purchaseReturns,
      saleCount: saleCount,
      pl: buildProfitLoss(sales: totalSales, cogs: cogs, expenses: totalExpenses),
      topProducts: [
        for (final m in top) TopProductRow((m['product'] ?? '') as String, ((m['totalQty'] as num?) ?? 0).toDouble())
      ],
      dailySales: [
        for (final m in daily) DailySalesRow((m['day'] ?? '') as String, ((m['total'] as num?) ?? 0).toDouble())
      ],
    );
  }
}
