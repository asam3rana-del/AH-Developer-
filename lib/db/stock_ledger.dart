import 'package:sqflite/sqflite.dart';

import '../models/product.dart';
import '../models/stock_movement.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';

/// Kotlin SyncQueueHelper.logMovement() / recordAuditReconciliation() ka Dart port.
///
/// Har jagah jo `products.stock` badalti hai (sale, purchase, return, edit, delete, opening stock)
/// usi transaction mein [StockLedger.log] bulati hai — isliye ledger aur stock kabhi alag nahi hote
/// (transaction fail => dono roll back). Ledger row ki sync_queue entry bhi wahi likhi jati hai
/// (entityType `stock_movement`, id `stock_movement:<DeviceTag>-<id>`, SyncQueueHelper.stockMovementPayload).
class StockLedger {
  StockLedger._();

  /// Ek movement likhta hai. [signedQty] SMALLEST unit mein, +ve = stock badha, -ve = ghata.
  /// [unitCost] do agar caller ne product ka NAYA cost pehle hi nikal liya (purchase wale sab),
  /// warna product ka maujooda cost istemal hota hai (sale kabhi cost nahi badalti).
  /// `signedQty == 0` par kuch nahi likhta, sirf [allowZero] ho to (purchase ka rate-only edit: qty wahi,
  /// cost badla — Cost History mein dikhna chahiye).
  ///
  /// Product row abhi bhi maujood na ho (delete ho chuka) to unit khali aur cost 0 — Kotlin jaisa.
  static Future<void> log(
    DatabaseExecutor ex, {
    required String barcode,
    required String type,
    required double signedQty,
    String reference = '',
    double? unitCost,
    String note = '',
    int? now,
    bool allowZero = false,
  }) async {
    if (signedQty == 0 && !allowZero) return;
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    final rows = await ex.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
    final p = rows.isEmpty ? null : Product.fromMap(rows.first);
    final row = StockMovement(
      barcode: barcode,
      type: type,
      qty: signedQty,
      unit: p?.smallestUnitName() ?? '',
      cost: unitCost ?? p?.cost ?? 0.0,
      reference: reference,
      note: note,
      createdAt: ts,
      updatedAt: ts,
    );
    final id = await ex.insert('stock_movements', row.toMap());
    // serverId-preferred entity id (`stock_movement:<DeviceTag>-<id>`) + Android payload shape.
    await SyncQueueHelper.enqueueStockMovement(ex, id);
  }

  /// Naye product ki shuruati quantity (Kotlin enqueueProductOpeningStock).
  static Future<void> logOpeningStock(DatabaseExecutor ex, String barcode, double qty, {double? unitCost, int? now}) =>
      log(ex, barcode: barcode, type: MovementType.openingStock, signedQty: qty, unitCost: unitCost, now: now);

  /// Stock Audit "Reconcile": Product.stock ko HAATH NAHI lagata, sirf ledger ko us tak le aata hai
  /// (Kotlin recordAuditReconciliation). [qty] = product.stock - ledger sum.
  static Future<void> logAuditReconciliation(DatabaseExecutor ex, String barcode, double qty, {String note = ''}) =>
      log(ex, barcode: barcode, type: MovementType.auditReconcile, signedQty: qty, note: note);

  /// Pehli baar (DB v11) — jo products mein pehle se stock hai unka ledger shuru karta hai, taake
  /// "ledger sum == product.stock" shuru se sahi ho aur Stock Audit fazool drift na dikhaye.
  static Future<void> backfillOpening(DatabaseExecutor db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query('products', where: 'stock != 0');
    // NOTE: onUpgrade pehle se ek transaction ke andar chalta hai — yahan db.transaction() NAHI
    // (sqflite mein deadlock hota hai); seedha executor par likhte hain.
    for (final r in rows) {
      final p = Product.fromMap(r);
      await log(db,
          barcode: p.barcode,
          type: MovementType.openingStock,
          signedQty: p.stock,
          note: 'Ledger shuru hone par maujooda stock',
          now: now);
    }
  }

  /// Stock/Cost History ka data — pure SQL, koi role check nahi (screen RoleGuard mein hai).
  static Future<List<StockMovement>> forProduct(String barcode, {bool costOnly = false}) async {
    final db = await AppDatabase.instance.database;
    final rows = costOnly
        ? await db.query('stock_movements',
            where: 'barcode=? AND type IN (${List.filled(MovementType.costAffecting.length, '?').join(',')})',
            whereArgs: [barcode, ...MovementType.costAffecting],
            orderBy: 'createdAt DESC, id DESC')
        : await db.query('stock_movements',
            where: 'barcode=?', whereArgs: [barcode], orderBy: 'createdAt DESC, id DESC');
    return rows.map(StockMovement.fromMap).toList();
  }
}

/// Kotlin StockMovementActivity.formatQtyValue(): 3 decimal tak round, poora ho to integer.
String formatMovementQty(double qty) {
  final rounded = (qty * 1000).round() / 1000.0;
  return rounded == rounded.floorToDouble() ? rounded.toInt().toString() : rounded.toString();
}

/// Ledger ka jod (signed qty) — Stock Audit isi ko Product.stock se milata hai.
double ledgerSum(Iterable<StockMovement> movements) => movements.fold(0.0, (a, m) => a + m.qty);

bool isCostAffecting(String type) => MovementType.costAffecting.contains(type);

/// Product picker ka filter — Kotlin renderProductList(): naam/searchTag (matchesQuery), category, barcode.
List<Product> filterMovementProducts(List<Product> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all
      .where((p) => p.matchesQuery(q) || p.category.toLowerCase().contains(q) || p.barcode.toLowerCase().contains(q))
      .toList();
}
