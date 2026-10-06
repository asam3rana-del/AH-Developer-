import 'dart:async';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../models/product.dart';
import '../utils/bulk_rate_planner.dart' show BulkRateRow, BulkRateTarget;
import 'app_database.dart';
import 'stock_ledger.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'watch_util.dart';

/// Dart port of ProductDao (Database.kt). Room's `Flow<List<Product>>` is
/// mirrored here with a broadcast StreamController that re-queries and
/// re-emits every time the table changes — call [_notify] after any write.
/// Products ke badalne wale kaam sirf admin (Kotlin ProductActivity). UI ke saath data layer par bhi.
void _requireProductAdmin() {
  if (!Session.isAdmin) throw StateError('Only Admin can change products');
}

/// Purchase se bhara jane wala ek product: sirf wohi fields (null = na badlo). Sab PRIMARY unit par.
class PurchaseRateFill {
  final Product product;
  final double? cost;
  final double? salePrice;
  final double? wholesalePrice;
  const PurchaseRateFill(this.product, {this.cost, this.salePrice, this.wholesalePrice});
}

class ProductRepository {
  ProductRepository._();
  static final ProductRepository instance = ProductRepository._();

  final _controller = StreamController<List<Product>>.broadcast();

  /// Mirrors `@Query("SELECT * FROM products ORDER BY name") fun all(): Flow<List<Product>>`.
  /// Har naye subscriber ko PEHLE current list milti hai, phir live updates.
  /// (Pehle sirf pehla subscriber list pata tha — screen dobara khulne par list khali reh jati thi.)
  Stream<List<Product>> watchAll() => watchWithInitial(_controller, listAll);

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
  ///
  /// SYNC FIX (edit, isNew = false): form ke paas product ka purana snapshot hota hai (sale/pull ke
  /// baad stale ho sakta hai) aur `insert(replace)` use seedha DB mein likh deta tha — is se (1) local
  /// stock chupke purani value par chala jata tha aur (2) unit-ladder badalne par rescaled stock ka
  /// koi `increment_stock` delta queue nahi hota tha, to doosre devices par stock alag rehta tha.
  /// Ab edit mein stock hamesha DB ki MAUJOODA value se nikalta hai (ladder badli ho to wahin se
  /// rescale) aur farq ka delta sync queue mein jata hai.
  Future<void> upsert(Product product, {bool isNew = false}) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      var row = product.toMap();
      var stockDelta = 0.0;
      if (!isNew) {
        final cur = await txn.query('products', where: 'barcode=?', whereArgs: [product.barcode], limit: 1);
        if (cur.isNotEmpty) {
          final current = Product.fromMap(cur.first);
          final r = rescaleStockForLadderChange(current, product);
          row = {...row, 'stock': r.stock, 'openingStock': r.openingStock};
          stockDelta = r.stock - current.stock;
        }
      }
      await txn.insert('products', row, conflictAlgorithm: ConflictAlgorithm.replace);
      // Kotlin ProductActivity save: SyncQueueHelper.enqueue(product) — productJson mein "stock" nahi
      // hota (conflict-safe sync), is liye naye product ki opening stock alag increment_stock se jati hai.
      await SyncQueueHelper.enqueueProduct(txn, product.barcode);
      if (isNew && product.stock != 0) {
        await SyncQueueHelper.enqueueStockDelta(txn, product.barcode, product.stock);
        await StockLedger.logOpeningStock(txn, product.barcode, product.stock);
      } else if (!isNew && stockDelta.abs() > 1e-9) {
        await SyncQueueHelper.enqueueStockDelta(txn, product.barcode, stockDelta);
      }
    });
    await _notify();
  }

  /// Mirrors `delete(p: Product)`.
  Future<void> delete(Product product) async {
    _requireProductAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await SyncQueueHelper.assertProductDeletable(txn, product.barcode);
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
  Future<void> setDefaultUnitIndex(String barcode, int index) {
    _requireProductAdmin();
    return _updateAndEnqueue(barcode, {'defaultUnitIndex': index});
  }

  /// updateRatesReview + enqueueProduct, ek transaction mein. Rates PRIMARY unit par.
  Future<void> setRates(String barcode, {required double salePrice, required double wholesalePrice}) {
    _requireProductAdmin();
    return _updateAndEnqueue(barcode, {'salePrice': salePrice, 'wholesalePrice': wholesalePrice});
  }

  /// Party Dashboard "Edit Rates": cost + retail + wholesale, sab PRIMARY unit par + sync_queue,
  /// ek transaction mein (Kotlin: productDao().upsert + SyncQueueHelper.enqueueProduct).
  Future<void> setAllRates(String barcode,
          {required double cost, required double salePrice, required double wholesalePrice}) {
    _requireProductAdmin();
    return _updateAndEnqueue(barcode, {'cost': cost, 'salePrice': salePrice, 'wholesalePrice': wholesalePrice});
  }

  /// Bulk Rate Tool: bohat si products ka bulk rate + min qty ek hi transaction mein (har product sync_queue mein).
  /// Adhoora save nahi hota — koi ek fail ho to sab rollback. Wapas gina hua tabdeel shuda count.
  Future<int> applyBulkRates(List<BulkRateRow> rows, BulkRateTarget target) async {
    _requireProductAdmin();
    if (rows.isEmpty) return 0;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in rows) {
        final changes = target == BulkRateTarget.retail
            ? {'bulkPrice': r.newBulkPrice, 'bulkMinQty': r.newMinQty}
            : {'wholesaleBulkPrice': r.newBulkPrice, 'wholesaleBulkMinQty': r.newMinQty};
        await txn.update('products', {...changes, 'dirty': 1, 'updatedAt': now},
            where: 'barcode=?', whereArgs: [r.product.barcode]);
        await SyncQueueHelper.enqueueProduct(txn, r.product.barcode);
      }
    });
    await _notify();
    return rows.length;
  }

  /// Jin products ka cost / retail / wholesale 0 hai magar purchase bill par likha hua hai: sab se nayi purchase
  /// (date ke hisaab se) ki line se bharne ka plan. Kuch badalta nahi — sirf preview. Jo rate pehle se set hai
  /// us ko kabhi nahi chhoota.
  Future<List<PurchaseRateFill>> planFillFromPurchases() async {
    final db = await AppDatabase.instance.database;
    final products = await listAll();
    final need = {
      for (final p in products)
        if (p.cost <= 0 || p.salePrice <= 0 || p.wholesalePrice <= 0) p.barcode: p
    };
    if (need.isEmpty) return const [];
    final rows = await db.rawQuery(
      'SELECT pi.barcode AS barcode, pi.unit AS unit, pi.unitCost AS unitCost, pi.retailRate AS retailRate, '
      'pi.wholesaleRate AS wholesaleRate FROM purchase_items pi JOIN purchases p ON p.billNo = pi.billNo '
      'ORDER BY p.createdAt DESC, pi.id DESC',
    );
    final cost = <String, double>{}, sale = <String, double>{}, wh = <String, double>{};
    for (final r in rows) {
      final bc = r['barcode'] as String;
      final prod = need[bc];
      if (prod == null) continue;
      final uc = (r['unitCost'] as num?)?.toDouble() ?? 0.0;
      final rr = (r['retailRate'] as num?)?.toDouble() ?? 0.0;
      final wr = (r['wholesaleRate'] as num?)?.toDouble() ?? 0.0;
      if (prod.cost <= 0 && uc > 0 && !cost.containsKey(bc)) {
        cost[bc] = prod.toPrimaryUnitRate(uc, (r['unit'] as String?) ?? prod.unit);
      }
      if (prod.salePrice <= 0 && rr > 0 && !sale.containsKey(bc)) sale[bc] = rr;
      if (prod.wholesalePrice <= 0 && wr > 0 && !wh.containsKey(bc)) wh[bc] = wr;
    }
    final out = <PurchaseRateFill>[];
    for (final bc in {...cost.keys, ...sale.keys, ...wh.keys}) {
      out.add(PurchaseRateFill(need[bc]!, cost: cost[bc], salePrice: sale[bc], wholesalePrice: wh[bc]));
    }
    out.sort((a, b) => a.product.name.toLowerCase().compareTo(b.product.name.toLowerCase()));
    return out;
  }

  /// [planFillFromPurchases] ka plan ek transaction mein lagao (har product sync_queue mein).
  Future<int> applyFillFromPurchases(List<PurchaseRateFill> plan) async {
    _requireProductAdmin();
    if (plan.isEmpty) return 0;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final f in plan) {
        final ch = <String, Object?>{
          if (f.cost != null) 'cost': f.cost,
          if (f.salePrice != null) 'salePrice': f.salePrice,
          if (f.wholesalePrice != null) 'wholesalePrice': f.wholesalePrice,
        };
        if (ch.isEmpty) continue;
        await txn.update('products', {...ch, 'dirty': 1, 'updatedAt': now},
            where: 'barcode=?', whereArgs: [f.product.barcode]);
        await SyncQueueHelper.enqueueProduct(txn, f.product.barcode);
      }
    });
    await _notify();
    return plan.length;
  }

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
