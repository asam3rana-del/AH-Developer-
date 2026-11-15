import '../models/sale.dart';
import '../services/session.dart';
import 'app_database.dart';

/// Ports the data side of SaleHistoryActivity.kt + SaleDao.allSales()/allSaleProfits()
/// (Database.kt). UI: lib/screens/sale_history_screen.dart.
///
/// Maths PURE functions mein hai ([groupSalesByCustomer], [summarizeSales], [filterGroups]) taake
/// bina DB ke test ho sake — test/sale_history_test.dart.
///
/// Rules (Kotlin):
///  * Customer ke hisaab se group; sab se recent active customer pehle; group ke andar naya bill pehle.
///  * Total Sales = returned ke bina; Total Returned = sirf returned bills.
///  * Bill-wise profit sirf admin ko: `total - SUM(sale_items.cost)`; returned bill ka profit nahi.
///  * Customer header ka profit = uske bills ke profit ka jama (returned = 0).

/// Kotlin `SaleWithCustomer` — display-only join (customer naam ke saath).
class SaleWithCustomer {
  final String invoice;
  final String customerName;
  final double total;
  final double paid;
  final String paymentMethod;
  final int createdAt;
  final String status;

  const SaleWithCustomer({
    required this.invoice,
    required this.customerName,
    required this.total,
    this.paid = 0,
    required this.paymentMethod,
    required this.createdAt,
    required this.status,
  });

  bool get isReturned => status == 'returned';
}

class SaleGroup {
  final String customerName;
  final List<SaleWithCustomer> sales; // naya bill pehle
  const SaleGroup(this.customerName, this.sales);

  int get lastActiveAt => sales.map((s) => s.createdAt).fold(0, (a, b) => a > b ? a : b);
  double get total => sales.fold(0.0, (a, s) => a + s.total);
  double profit(Map<String, double> profits) => sales.fold(0.0, (a, s) => a + (profits[s.invoice] ?? 0.0));
}

class SaleHistorySummary {
  final double totalSales;
  final double totalReturned;
  const SaleHistorySummary(this.totalSales, this.totalReturned);
}

/// Customer ke hisaab se group: sab se recent active customer pehle, andar naya bill pehle.
List<SaleGroup> groupSalesByCustomer(List<SaleWithCustomer> sales) {
  final byName = <String, List<SaleWithCustomer>>{};
  for (final s in sales) {
    byName.putIfAbsent(s.customerName, () => []).add(s);
  }
  final groups = byName.entries.map((e) {
    final list = [...e.value]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return SaleGroup(e.key, list);
  }).toList()
    ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
  return groups;
}

/// Khatabook-style cards: active bills = Total Sales, returned = Total Returned.
SaleHistorySummary summarizeSales(List<SaleWithCustomer> sales) {
  double sold = 0, returned = 0;
  for (final s in sales) {
    if (s.isReturned) {
      returned += s.total;
    } else {
      sold += s.total;
    }
  }
  return SaleHistorySummary(sold, returned);
}

/// Customer naam par search (case-insensitive, khali = sab).
List<SaleGroup> filterGroups(List<SaleGroup> groups, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groups;
  return groups.where((g) => g.customerName.toLowerCase().contains(q)).toList();
}

class SaleHistoryRepository {
  SaleHistoryRepository._();
  static final SaleHistoryRepository instance = SaleHistoryRepository._();

  /// Kotlin allSales(): customerId null / gum ho to 'Walk-in'.
  Future<List<SaleWithCustomer>> allSales() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT invoice,
             COALESCE((SELECT name FROM customers WHERE customers.id = sales.customerId), 'Walk-in') AS customerName,
             total, paid, paymentMethod, createdAt, status
      FROM sales ORDER BY createdAt DESC
    ''');
    return rows
        .map((r) => SaleWithCustomer(
              invoice: r['invoice'] as String,
              customerName: r['customerName'] as String,
              total: (r['total'] as num).toDouble(),
              paid: (r['paid'] as num?)?.toDouble() ?? 0,
              paymentMethod: (r['paymentMethod'] as String?) ?? '',
              createdAt: (r['createdAt'] as num).toInt(),
              status: (r['status'] as String?) ?? 'active',
            ))
        .toList();
  }

  /// Kotlin allSaleProfits(): sirf admin ke liye; cashier/manager ko khali map (cost data load hi nahi hota).
  Future<Map<String, double>> saleProfits() async {
    if (!Session.isAdmin) return const {};
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT s.invoice AS invoice,
             (s.total - COALESCE((SELECT SUM(si.cost) FROM sale_items si WHERE si.invoice = s.invoice), 0)) AS profit
      FROM sales s WHERE s.status != 'returned'
    ''');
    return {for (final r in rows) r['invoice'] as String: (r['profit'] as num).toDouble()};
  }

  Future<List<SaleItem>> itemsForInvoice(String invoice) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sale_items', where: 'invoice = ?', whereArgs: [invoice]);
    return rows.map(SaleItem.fromMap).toList();
  }

  Future<Sale?> findSale(String invoice) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sales', where: 'invoice = ?', whereArgs: [invoice], limit: 1);
    return rows.isEmpty ? null : Sale.fromMap(rows.first);
  }
}
