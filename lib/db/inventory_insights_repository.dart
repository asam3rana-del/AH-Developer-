import '../models/product.dart';
import '../models/stock_movement.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'stock_report_repository.dart' show costPerSmallestUnit;

/// Ports the data side of InventoryInsightsActivity.kt — 4 reports: Reorder, Damage/Loss, Margin, Movers.
///
/// Maths PURE functions mein hai — test/inventory_insights_test.dart.
/// Role: admin/manager (cost data dikhta hai). Repository dobara check karta hai.

class InventoryInsightsException implements Exception {
  final String message;
  const InventoryInsightsException(this.message);
  @override
  String toString() => message;
}

// ───────────────────────── Reorder ─────────────────────────

/// Kotlin `lowStock().filter { reorderLevel > 0 }.sortedBy { name.lowercase() }`:
/// `stock <= reorderLevel` aur reorderLevel > 0 (jis ka level set nahi wo yahan nahi aata).
List<Product> reorderCandidates(List<Product> all) {
  final out = all.where((p) => p.reorderLevel > 0.0 && p.stock <= p.reorderLevel).toList();
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Kotlin: reorder level ka DOUBLE tak wapas bharo, kam az kam level tak (smallest unit mein).
/// `(level*2 - stock).coerceAtLeast(level - stock)`.
double suggestedReorderQty(Product p) {
  final toDouble = p.reorderLevel * 2 - p.stock;
  final toLevel = p.reorderLevel - p.stock;
  return toDouble > toLevel ? toDouble : toLevel;
}

// ───────────────────────── Damage / Loss ─────────────────────────

/// Kotlin FIX: movement.qty smallest unit mein, movement.cost primary unit ka rate — isliye cost ko
/// product ki CURRENT smallestUnitFactor se taqseem karte hain (product delete ho gaya ho to raw cost).
double damageLossValue(StockMovement m, Product? p) {
  final factor = p?.smallestUnitFactor() ?? 0.0;
  final perSmallest = factor > 0 ? m.cost / factor : m.cost;
  return m.qty.abs() * perSmallest;
}

double totalDamageLoss(List<StockMovement> movements, Map<String, Product> products) =>
    movements.fold(0.0, (a, m) => a + damageLossValue(m, products[m.barcode]));

// ───────────────────────── Margin ─────────────────────────

/// Kotlin marginPercent(): (sale - cost) / sale * 100, sale <= 0 par 0.
double marginPercent(Product p) => p.salePrice > 0.0 ? ((p.salePrice - p.cost) / p.salePrice) * 100.0 : 0.0;

/// Sirf salePrice > 0 wale products (Kotlin loadProfit filter).
List<Product> pricedProducts(List<Product> all) => all.where((p) => p.salePrice > 0.0).toList();

double averageMargin(List<Product> priced) =>
    priced.isEmpty ? 0.0 : priced.fold(0.0, (a, p) => a + marginPercent(p)) / priced.length;

int lowMarginCount(List<Product> priced, {double threshold = 10.0}) => priced.where((p) => marginPercent(p) < threshold).length;

/// Sabse kam margin pehle (sabse actionable). Barabar margin par asal order barqarar (stable).
List<Product> sortByMarginAsc(List<Product> priced) {
  final idx = {for (var i = 0; i < priced.length; i++) priced[i]: i};
  final out = [...priced];
  out.sort((a, b) {
    final c = marginPercent(a).compareTo(marginPercent(b));
    return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
  });
  return out;
}

/// 0 = red (< 10%), 1 = amber (< 25%), 2 = teal.
int marginBand(double margin) => margin < 10.0 ? 0 : (margin < 25.0 ? 1 : 2);

// ───────────────────────── Movers ─────────────────────────

class ItemMovementRow {
  final String barcode;
  final String name;
  final double qty;
  final double amount;
  const ItemMovementRow(this.barcode, this.name, this.qty, this.amount);
}

/// Har product ke liye ek row (bikri na ho to 0) — Kotlin loadMovers().
List<ItemMovementRow> buildMovementRows(List<Product> products, Map<String, ({double qty, double amount})> movement) => [
      for (final p in products)
        ItemMovementRow(p.barcode, p.name, movement[p.barcode]?.qty ?? 0.0, movement[p.barcode]?.amount ?? 0.0),
    ];

List<ItemMovementRow> _stableSort(List<ItemMovementRow> rows, int Function(ItemMovementRow, ItemMovementRow) cmp) {
  final idx = {for (var i = 0; i < rows.length; i++) rows[i]: i};
  final out = [...rows];
  out.sort((a, b) {
    final c = cmp(a, b);
    return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
  });
  return out;
}

/// Sab se zyada bikne wale (top 15, sirf qty > 0).
List<ItemMovementRow> fastMovers(List<ItemMovementRow> rows, {int limit = 15}) =>
    _stableSort(rows, (a, b) => b.qty.compareTo(a.qty)).take(limit).where((r) => r.qty > 0).toList();

/// Sab se kam bikne wale (top 15, zero-sale wale pehle).
List<ItemMovementRow> slowMovers(List<ItemMovementRow> rows, {int limit = 15}) =>
    _stableSort(rows, (a, b) => a.qty.compareTo(b.qty)).take(limit).toList();

double totalUnitsSold(List<ItemMovementRow> rows) => rows.fold(0.0, (a, r) => a + r.qty);

// ───────────────────────── Item history (Margin drill-down) ─────────────────────────

class ItemHistoryRow {
  final bool isSale;
  final String party;
  final double qty;
  final String unit;
  final double rate;
  final int createdAt;
  const ItemHistoryRow(this.isSale, this.party, this.qty, this.unit, this.rate, this.createdAt);
}

/// Sale + purchase mila kar, naya pehle.
List<ItemHistoryRow> mergeItemHistory(List<ItemHistoryRow> sales, List<ItemHistoryRow> purchases) {
  final all = [...sales, ...purchases];
  final idx = {for (var i = 0; i < all.length; i++) all[i]: i};
  all.sort((a, b) {
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
  });
  return all;
}

class InventoryInsightsRepository {
  InventoryInsightsRepository._();
  static final InventoryInsightsRepository instance = InventoryInsightsRepository._();

  void _guard() {
    if (!Session.isAdminOrManager) {
      throw const InventoryInsightsException('Inventory Insights sirf Admin/Manager dekh sakta hai');
    }
  }

  Future<List<Product>> loadProducts() async {
    _guard();
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// Kotlin damageBetween(): type='DAMAGE', [start, end], naya pehle.
  Future<List<StockMovement>> damageBetween(int start, int end) async {
    _guard();
    final db = await AppDatabase.instance.database;
    final rows = await db.query('stock_movements',
        where: "type='DAMAGE' AND createdAt BETWEEN ? AND ?", whereArgs: [start, end], orderBy: 'createdAt DESC, id DESC');
    return rows.map(StockMovement.fromMap).toList();
  }

  /// Kotlin itemMovementBetween(): returned sales bahar, barcode ke hisaab se qty + amount.
  Future<Map<String, ({double qty, double amount})>> itemMovementBetween(int start, int end) async {
    _guard();
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT si.barcode AS barcode, COALESCE(SUM(si.qty),0) AS totalQty, COALESCE(SUM(si.amount),0) AS totalAmount
      FROM sale_items si JOIN sales s ON si.invoice = s.invoice
      WHERE s.createdAt BETWEEN ? AND ? AND s.status != 'returned'
      GROUP BY si.barcode
    ''', [start, end]);
    return {
      for (final r in rows)
        r['barcode'] as String: (qty: (r['totalQty'] as num).toDouble(), amount: (r['totalAmount'] as num).toDouble()),
    };
  }

  /// Is item ki har sale aur purchase (Kotlin saleRecordsForItem + purchaseRecordsForItem), naya pehle.
  Future<List<ItemHistoryRow>> itemHistory(String barcode) async {
    _guard();
    final db = await AppDatabase.instance.database;
    final sales = await db.rawQuery('''
      SELECT COALESCE((SELECT name FROM customers WHERE customers.id = s.customerId), 'Walk-in') AS party,
             si.qty AS qty, si.unit AS unit, si.unitPrice AS rate, s.createdAt AS createdAt
      FROM sale_items si JOIN sales s ON si.invoice = s.invoice
      WHERE si.barcode = ? ORDER BY s.createdAt DESC
    ''', [barcode]);
    final purchases = await db.rawQuery('''
      SELECT COALESCE((SELECT name FROM suppliers WHERE suppliers.id = p.supplierId), 'Cash Purchase') AS party,
             pi.qty AS qty, pi.unit AS unit, pi.unitCost AS rate, p.createdAt AS createdAt
      FROM purchase_items pi JOIN purchases p ON pi.billNo = p.billNo
      WHERE pi.barcode = ? ORDER BY p.createdAt DESC
    ''', [barcode]);
    ItemHistoryRow map(Map<String, Object?> r, bool isSale) => ItemHistoryRow(
          isSale,
          (r['party'] as String?) ?? '',
          (r['qty'] as num).toDouble(),
          (r['unit'] as String?) ?? '',
          (r['rate'] as num).toDouble(),
          (r['createdAt'] as num).toInt(),
        );
    return mergeItemHistory([for (final r in sales) map(r, true)], [for (final r in purchases) map(r, false)]);
  }
}
