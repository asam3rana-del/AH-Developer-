import 'dart:async';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../models/product.dart';
import 'app_database.dart';
import 'stock_ledger.dart';
import '../sync/sync_queue_helper.dart';

/// Dart port of ProductDao (Database.kt). Room's `Flow<List<Product>>` is
/// mirrored here with a broadcast StreamController that re-queries and
/// re-emits every time the table changes — call [_notify] after any write.
class ProductRepository {
  ProductRepository._();
  static final ProductRepository instance = ProductRepository._();

  final _controller = StreamController<List<Product>>.broadcast();
  bool _primed = false;

  /// Mirrors `@Query("SELECT * FROM products ORDER BY name") fun all(): Flow<List<Product>>`.
  Stream<List<Product>> watchAll() {
    if (!_primed) {
      _primed = true;
      _notify();
    }
    return _controller.stream;
  }

  Future<void> _notify() async {
    final rows = await listAll();
    if (!_controller.isClosed) _controller.add(rows);
  }

  /// Call after another repository writes to `products` directly (e.g. a
  /// purchase bumping stock/cost in the same transaction) so this screen's
  /// stream picks up the change immediately.
  Future<void> refresh() => _notify();

  Future<List<Product>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// Mirrors `find(code): Product?`.
  Future<Product?> find(String barcode) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  /// Mirrors `upsert(p: Product)` (OnConflictStrategy.REPLACE).
  ///
  /// [isNew] = true (naya product) aur stock != 0 ho to usi transaction mein OPENING_STOCK ledger
  /// row bhi likhta hai (Kotlin enqueueProductOpeningStock). Edit par stock ledger se nahi chhedta.
  Future<void> upsert(Product product, {bool isNew = false}) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.insert('products', product.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      // Kotlin ProductActivity save: SyncQueueHelper.enqueue(product) — productJson mein "stock" nahi
      // hota (conflict-safe sync), is liye naye product ki opening stock alag increment_stock se jati hai.
      await SyncQueueHelper.enqueueProduct(txn, product.barcode);
      if (isNew && product.stock != 0) {
        await SyncQueueHelper.enqueueStockDelta(txn, product.barcode, product.stock);
        await StockLedger.logOpeningStock(txn, product.barcode, product.stock);
      }
    });
    await _notify();
  }

  /// Mirrors `delete(p: Product)`.
  Future<void> delete(Product product) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete('products', where: 'barcode=?', whereArgs: [product.barcode]);
      // Kotlin confirmDeleteProduct: enqueue(product, "delete") — server par tombstone.
      await SyncQueueHelper.enqueueDelete(txn, 'product', SyncQueueHelper.productEntityId({'barcode': product.barcode}));
    });
    await _notify();
  }

  // ---------- Bulk review queues (BulkDefaultUnitActivity / BulkMissingRatesActivity) ----------

  /// productsNeedingDefaultUnitReview(): 2+ tiers, koi manual default abhi nahi.
  Future<List<Product>> needingDefaultUnitReview() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products',
        where: "secondaryUnit != '' AND defaultUnitIndex = -1", orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// productsWithMissingRates(): Retail ya Wholesale abhi 0.
  Future<List<Product>> withMissingRates() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products',
        where: 'salePrice <= 0 OR wholesalePrice <= 0', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// updateDefaultUnitIndex + enqueueProduct, ek transaction mein.
  Future<void> setDefaultUnitIndex(String barcode, int index) => _updateAndEnqueue(
        barcode, {'defaultUnitIndex': index});

  /// updateRatesReview + enqueueProduct, ek transaction mein. Rates PRIMARY unit par.
  Future<void> setRates(String barcode, {required double salePrice, required double wholesalePrice}) =>
      _updateAndEnqueue(barcode, {'salePrice': salePrice, 'wholesalePrice': wholesalePrice});

  /// Party Dashboard "Edit Rates": cost + retail + wholesale, sab PRIMARY unit par + sync_queue,
  /// ek transaction mein (Kotlin: productDao().upsert + SyncQueueHelper.enqueueProduct).
  Future<void> setAllRates(String barcode,
          {required double cost, required double salePrice, required double wholesalePrice}) =>
      _updateAndEnqueue(barcode, {'cost': cost, 'salePrice': salePrice, 'wholesalePrice': wholesalePrice});

  Future<void> _updateAndEnqueue(String barcode, Map<String, Object?> changes) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update('products', {...changes, 'dirty': 1, 'updatedAt': now},
          where: 'barcode=?', whereArgs: [barcode]);
      await SyncQueueHelper.enqueueProduct(txn, barcode);
    });
    await _notify();
  }

  void dispose() => _controller.close();
}
