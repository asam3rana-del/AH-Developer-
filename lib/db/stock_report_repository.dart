import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';

/// Ports the data side of StockReportActivity.kt.
///
/// Maths PURE functions mein hai — test/stock_report_test.dart. Kotlin FIX (same as Balance Sheet):
/// `stock` smallest unit mein hai, `cost` / `salePrice` primary unit ke rate — isliye value =
/// stock * (rate / smallestUnitFactor), kabhi stock * rate nahi.
///
/// Role: Kotlin mein Low Stock dashboard tile sab ko dikhta hai, isliye screen sab roles ke liye khuli hai.
/// Cashier ko cost data nahi milta: [StockReportRepository.load] cashier ke liye `cost` zero kar deta hai
/// (PORTING_PLAN: cost sirf admin/manager) aur screen cost cards/values chhupati hai.

double costPerSmallestUnit(Product p) {
  final factor = p.smallestUnitFactor();
  return factor > 0 ? p.cost / factor : p.cost;
}

double salePerSmallestUnit(Product p) {
  final factor = p.smallestUnitFactor();
  return factor > 0 ? p.salePrice / factor : p.salePrice;
}

/// Kotlin: `stock <= reorderLevel` (reorderLevel 0 aur stock 0 bhi low hai).
bool isLowStock(Product p) => p.stock <= p.reorderLevel;

double stockCostValue(Product p) => p.stock * costPerSmallestUnit(p);

class StockSummary {
  final int totalProducts;
  final int lowStockCount;
  final double costValue;
  final double saleValue;
  const StockSummary(this.totalProducts, this.lowStockCount, this.costValue, this.saleValue);
}

StockSummary summarizeStock(List<Product> products) => StockSummary(
      products.length,
      products.where(isLowStock).length,
      products.fold(0.0, (a, p) => a + stockCostValue(p)),
      products.fold(0.0, (a, p) => a + p.stock * salePerSmallestUnit(p)),
    );

/// Kotlin renderList: query khali ya matchesQuery (name + searchTag) YA category YA barcode mein;
/// `lowOnly` ho to sirf low stock.
List<Product> filterStock(List<Product> all, String query, {bool lowOnly = false}) {
  final q = query.trim().toLowerCase();
  var out = all.where((p) =>
      q.isEmpty || p.matchesQuery(q) || p.category.toLowerCase().contains(q) || p.barcode.toLowerCase().contains(q));
  if (lowOnly) out = out.where(isLowStock);
  return out.toList();
}

class StockReportRepository {
  StockReportRepository._();
  static final StockReportRepository instance = StockReportRepository._();

  /// Naam ke hisaab se (case-insensitive). Cashier ke liye cost = 0 (data layer par bhi rok).
  Future<List<Product>> load() async {
    final db = await AppDatabase.instance.database;
    final products = (await db.query('products')).map(Product.fromMap).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (Session.isAdminOrManager) return products;
    return [for (final p in products) p.copyWith(cost: 0.0)];
  }
}
