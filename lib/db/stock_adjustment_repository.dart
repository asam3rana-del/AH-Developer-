
import '../models/product.dart';
import '../models/stock_movement.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'product_repository.dart';
import 'stock_ledger.dart';
import '../sync/sync_queue_helper.dart';

/// Ports the data side of StockAdjustmentActivity.kt.
///
/// Do qismein: "Damage / Loss" (hamesha stock GHATATA hai, type DAMAGE) aur "Correction" (+/-, type
/// ADJUSTMENT — recount ya entry ki ghalti). Qty PRODUCT ki SMALLEST unit mein (Kotlin jaisa).
/// Stock update + ledger row + sync_queue ek hi transaction mein (Kotlin increase/decreaseProductStock).
enum AdjustmentKind { damage, correctionAdd, correctionRemove }

class StockAdjustmentException implements Exception {
  final String message;
  const StockAdjustmentException(this.message);
  @override
  String toString() => message;
}

/// Signed change in smallest units: damage aur correction-remove NEGATIVE, correction-add POSITIVE.
double adjustmentDelta(AdjustmentKind kind, double qty) =>
    kind == AdjustmentKind.correctionAdd ? qty.abs() : -qty.abs();

/// Ledger type: DAMAGE ya ADJUSTMENT.
String adjustmentType(AdjustmentKind kind) =>
    kind == AdjustmentKind.damage ? MovementType.damage : MovementType.adjustment;

/// null = theek, warna wajah. Kotlin sirf qty > 0 dekhta tha; yahan 2 cheezein aur:
///  * piece-based item (smallest unit Piece/Bottle...) mein 1.5 jaisi fraction nahi (Product.isValidSmallestQty);
///  * kam karne par itna stock hona chahiye (Kotlin DAO `decrease` guard).
String? validateAdjustment(Product p, AdjustmentKind kind, double? qty) {
  if (qty == null || qty <= 0) return 'Darust miqdaar likhen';
  if (!p.isValidSmallestQty(qty)) {
    return 'Miqdaar poori ${p.smallestUnitName()} mein honi chahiye (fraction nahi)';
  }
  if (adjustmentDelta(kind, qty) < 0 && qty > p.stock + 1e-9) {
    return 'Itna stock kam karne ke liye kaafi nahi hai (maujooda: ${p.formatStockBreakdown()})';
  }
  return null;
}

/// Kotlin renderList(): query KHALI ho to kuch nahi dikhata (browse nahi, deliberate adjustment),
/// warna naam/searchTag (matchesQuery), category ya barcode.
List<Product> searchProductsForAdjustment(List<Product> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return all
      .where((p) => p.matchesQuery(q) || p.category.toLowerCase().contains(q) || p.barcode.toLowerCase().contains(q))
      .toList();
}

class StockAdjustmentRepository {
  StockAdjustmentRepository._();
  static final StockAdjustmentRepository instance = StockAdjustmentRepository._();

  Future<List<Product>> loadProducts() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// Stock badlo + DAMAGE/ADJUSTMENT ledger row (cost = us waqt ka product.cost) + product sync_queue,
  /// ek transaction mein. Admin/Manager only (role repository mein bhi check hota hai).
  Future<void> save(String barcode, AdjustmentKind kind, double qty, {String note = ''}) async {
    if (!Session.isAdminOrManager) {
      throw const StockAdjustmentException('Stock Adjustment sirf Admin/Manager kar sakta hai');
    }
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
      if (rows.isEmpty) throw const StockAdjustmentException('Product nahi mila');
      final product = Product.fromMap(rows.first);
      final err = validateAdjustment(product, kind, qty);
      if (err != null) throw StockAdjustmentException(err);

      final delta = adjustmentDelta(kind, qty);
      final now = DateTime.now().millisecondsSinceEpoch;
      // Guard SQL mein bhi: do device/tap ek saath ho to stock negative na ho.
      final n = await txn.rawUpdate(
        delta < 0
            ? 'UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock + ? >= 0'
            : 'UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
        delta < 0 ? [delta, now, barcode, delta] : [delta, now, barcode],
      );
      if (n == 0) throw const StockAdjustmentException('Itna stock kam karne ke liye kaafi nahi hai');

      await StockLedger.log(txn,
          barcode: barcode, type: adjustmentType(kind), signedQty: delta, unitCost: product.cost, note: note, now: now);

      await SyncQueueHelper.enqueueStockDelta(txn, barcode, delta);
    });
    await ProductRepository.instance.refresh();
  }
}
