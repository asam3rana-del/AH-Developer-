
import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../models/product.dart';
import '../models/purchase.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'party_transaction_repository.dart'
    show InsufficientStockException, purchaseItemSmallestQty, reconcilePaid, reversePurchaseLineCost;
import '../models/stock_movement.dart' show MovementType;
import 'product_repository.dart';
import 'stock_ledger.dart';
import 'supplier_repository.dart';
import '../sync/sync_queue_helper.dart';

/// Ports the data side of PurchaseHistoryActivity.kt + PurchaseDao.allPurchases() (Database.kt) +
/// RoomPurchaseRepository.deletePurchase(). UI: lib/screens/purchase_history_screen.dart.
///
/// Maths PURE functions mein hai ([summarizePurchases], [filterPurchaseRows], [parseReturnRequest],
/// [returnedLineAmount]) taake bina DB ke test ho sake — test/purchase_history_test.dart.
///
/// Rules (Kotlin):
///  * Sab bills naya pehle; supplier na ho to naam 'Cash Purchase'.
///  * Total Purchases / Total Due = sirf active (returned nahi): due = (total - paid) kam az kam 0.
///  * Badge DUE / PAID sirf active bill par.
///  * Return = har line ki qty chun kar (partial). Sirf wahi qty stock/cost/supplier balance se nikalti hai.
///    Sab lines poori return => bill 'returned' + cash/payment reversal (purani whole-bill return jaisa).
///  * Stock purchase ke baad kam ho chuka ho (bik gaya) to return/delete rok diya jata hai.
///  * Delete = stock+cost wapas, supplier balance (overpaid bhi) wapas, bill/items/payments/cash + sync_queue.
///  * Return/Delete sirf admin (data layer par bhi check).

/// Kotlin `PurchaseWithSupplier` + paid.
class PurchaseHistoryRow {
  final String billNo;
  final String supplierName;
  final double total;
  final double paid;
  final int createdAt;
  final String status;

  const PurchaseHistoryRow({
    required this.billNo,
    required this.supplierName,
    required this.total,
    required this.paid,
    required this.createdAt,
    required this.status,
  });

  bool get isActive => status == 'active';
  bool get isReturned => status == 'returned';

  /// Kotlin `(total - paid).coerceAtLeast(0.0)`.
  double get due => (total - paid) < 0 ? 0.0 : (total - paid);
}

class PurchaseHistorySummary {
  final double totalPurchases;
  final double totalDue;
  const PurchaseHistorySummary(this.totalPurchases, this.totalDue);
}

/// Returned bill ka total na asli kharcha hai na asli qarza — sirf non-returned gine jate hain.
PurchaseHistorySummary summarizePurchases(List<PurchaseHistoryRow> rows) {
  double total = 0, due = 0;
  for (final r in rows) {
    if (r.isReturned) continue;
    total += r.total;
    due += r.due;
  }
  return PurchaseHistorySummary(total, due);
}

/// Bill number ya supplier naam (case-insensitive); khali = sab.
List<PurchaseHistoryRow> filterPurchaseRows(List<PurchaseHistoryRow> rows, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rows;
  return rows.where((r) => r.billNo.toLowerCase().contains(q) || r.supplierName.toLowerCase().contains(q)).toList();
}

/// Return dialog ki ek line: kitni khareedi gayi thi.
class ReturnableLine {
  final int itemId;
  final String name;
  final String unit;
  final double qty;
  const ReturnableLine({required this.itemId, required this.name, required this.unit, required this.qty});
}

class ReturnRequest {
  final Map<int, double> quantities; // itemId -> return qty (> 0)
  final String? error;
  const ReturnRequest(this.quantities, this.error);
}

/// Kotlin returnBtn validation: khali/0 = skip, galat/negative = error, khareedi se zyada = error,
/// kam az kam ek line chahiye. [inputs] = itemId -> text.
ReturnRequest parseReturnRequest(List<ReturnableLine> lines, Map<int, String> inputs) {
  final out = <int, double>{};
  String fmt(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
  for (final l in lines) {
    final text = (inputs[l.itemId] ?? '').trim();
    if (text.isEmpty) continue;
    final qty = double.tryParse(text);
    if (qty == null || qty < 0) return ReturnRequest(const {}, 'Enter a valid quantity for "${l.name}"');
    if (qty == 0) continue;
    if (qty > l.qty + 0.0001) {
      return ReturnRequest(const {}, 'Return qty for "${l.name}" can\'t exceed purchased qty (${fmt(l.qty)})');
    }
    out[l.itemId] = qty;
  }
  if (out.isEmpty) return const ReturnRequest({}, 'Enter a return quantity for at least one item');
  return ReturnRequest(out, null);
}

/// Wapas hone wali qty ki raqam: line amount ka hissa (qty 0 ho to unitCost * qty).
double returnedLineAmount({required double lineQty, required double lineAmount, required double unitCost, required double returnQty}) =>
    lineQty > 0 ? lineAmount * (returnQty / lineQty) : unitCost * returnQty;

/// Wapas hone wali qty smallest units mein: bill par jama shuda conversionFactor (DB v12) pehle; sirf purani
/// rows (factor == 0) ke liye product ki maujuda ladder.
double partialSmallestQty(PurchaseItem item, Product? product, double returnQty) {
  if (item.conversionFactor > 0) return returnQty * item.conversionFactor;
  if (product == null) return returnQty;
  return product.toSmallestUnits(returnQty, item.unit.isEmpty ? product.unit : item.unit);
}

class PurchaseHistoryRepository {
  PurchaseHistoryRepository._();
  static final PurchaseHistoryRepository instance = PurchaseHistoryRepository._();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _requireAdmin() {
    if (!Session.isAdmin) throw StateError('Sirf Admin ye action kar sakta hai');
  }

  /// Kotlin allPurchases() + har bill ka `paid`, naya pehle.
  Future<List<PurchaseHistoryRow>> allPurchases() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT billNo,
             COALESCE((SELECT name FROM suppliers WHERE suppliers.id = purchases.supplierId), 'Cash Purchase') AS supplierName,
             total, COALESCE(paid, 0) AS paid, createdAt, status
      FROM purchases ORDER BY createdAt DESC
    ''');
    return rows
        .map((r) => PurchaseHistoryRow(
              billNo: r['billNo'] as String,
              supplierName: r['supplierName'] as String,
              total: (r['total'] as num).toDouble(),
              paid: (r['paid'] as num).toDouble(),
              createdAt: (r['createdAt'] as num).toInt(),
              status: (r['status'] as String?) ?? 'active',
            ))
        .toList();
  }

  Future<Purchase?> findPurchase(String billNo) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
    return r.isEmpty ? null : Purchase.fromMap(r.first);
  }

  Future<List<PurchaseItem>> itemsForBill(String billNo) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo]);
    return r.map(PurchaseItem.fromMap).toList();
  }

  /// Bill ki lines + naam/unit (line par jama shuda naam pehle, purani rows ke liye live product, warna
  /// barcode). Print aur Return dialog dono isi se.
  Future<List<ReturnableLine>> linesForBill(String billNo) async {
    final db = await AppDatabase.instance.database;
    final items = await itemsForBill(billNo);
    final out = <ReturnableLine>[];
    for (final it in items) {
      final pr = await db.query('products', where: 'barcode = ?', whereArgs: [it.barcode], limit: 1);
      final product = pr.isEmpty ? null : Product.fromMap(pr.first);
      out.add(ReturnableLine(
        itemId: it.id ?? -1,
        name: it.itemName.trim().isNotEmpty
            ? it.itemName
            : ((product?.name.isNotEmpty ?? false) ? product!.name : it.barcode),
        unit: it.unit.isNotEmpty ? it.unit : (product?.unit ?? ''),
        qty: it.qty,
      ));
    }
    return out;
  }

  // ------------------------------------------------------------ sync helpers

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  Future<void> _enqueue(DatabaseExecutor ex, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(ex, type, id, op, payload);

  Future<Product?> _product(DatabaseExecutor ex, String barcode) async {
    if (barcode.isEmpty) return null;
    final r = await ex.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    return r.isEmpty ? null : Product.fromMap(r.first);
  }

  Future<void> _enqueueProduct(DatabaseExecutor ex, String barcode) =>
      SyncQueueHelper.enqueueProduct(ex, barcode);

  Future<void> _adjustSupplierBalance(DatabaseExecutor ex, int supplierId, double delta) async {
    await ex.rawUpdate('UPDATE suppliers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
        [delta, _now(), supplierId]);
    await SyncQueueHelper.enqueueBalanceDelta(ex, customer: false, partyId: supplierId, delta: delta);
  }

  Future<void> _deleteCashByReference(DatabaseExecutor ex, String reference) =>
      SyncQueueHelper.deleteCashTransactionsByReference(ex, reference);

  Future<void> _deletePaymentsByReference(DatabaseExecutor ex, String reference) =>
      SyncQueueHelper.deletePaymentsByReference(ex, reference);

  /// Bill se linked payments (billReference == bill) + unki cash rows hatao. Party balance ko haath
  /// nahi lagate (bill ka apna reversal total-paid se pehle hi theek hai).
  Future<void> _voidLinkedPayments(DatabaseExecutor ex, String billRef) async {
    final rows = await ex.query('payments', where: 'billReference = ?', whereArgs: [billRef]);
    for (final p in rows) {
      await _deleteCashByReference(ex, p['reference'] as String);
      await SyncQueueHelper.deletePaymentRow(ex, Map<String, Object?>.from(p));
    }
  }

  /// Kotlin reverseCashByReference: asli cash rows chhoote nahi, nayi dated reversal row
  /// (`return:<ref>`), purane methods ke hisaab se barabar taqseem.
  Future<void> _reverseCash(DatabaseExecutor ex, String reference, double amount, String type, String label) async {
    if (amount <= 0.009) return;
    final rows = await ex.query('cash_transactions', where: 'reference = ?', whereArgs: [reference]);
    if (rows.isEmpty) return;
    final originalTotal = rows.fold<double>(0, (a, r) => a + (r['amount'] as num).toDouble());
    if (originalTotal <= 0.009) return;
    final ratio = (amount / originalTotal).clamp(0.0, 1.0);
    for (final r in rows) {
      final portion = (r['amount'] as num).toDouble() * ratio;
      if (portion <= 0.009) continue;
      final tx = CashTransaction(
        type: type,
        method: (r['method'] as String?) ?? 'cash',
        amount: portion,
        reason: label,
        reference: 'return:$reference',
        createdAt: _now(),
      );
      final id = await ex.insert('cash_transactions', tx.toMap());
      await _enqueue(ex, 'cash_transaction', '$id', 'create', tx.toMap());
    }
  }

  /// Bill chhoti hui: `paid` cap; cash ka dated reversal + purchase ke apne payment row kam.
  Future<double> _reconcilePaidAfterReturn(DatabaseExecutor ex, String reference, double oldPaid, double newTotal) async {
    final newPaid = reconcilePaid(oldPaid, newTotal);
    final delta = newPaid - oldPaid;
    if (delta == 0) return newPaid;
    var remaining = -delta;
    await _reverseCash(ex, reference, remaining, 'IN', 'Purchase Return');
    final pays = await ex.query('payments', where: 'reference = ?', whereArgs: [reference], orderBy: 'createdAt DESC');
    for (final r in pays) {
      if (remaining <= 0) break;
      final amt = (r['amount'] as num).toDouble();
      final cur = amt < 0 ? 0.0 : amt;
      final cut = remaining < cur ? remaining : cur;
      if (cut <= 0) continue;
      await ex.update('payments', {'amount': cur - cut, 'updatedAt': _now(), 'dirty': 1}, where: 'id = ?', whereArgs: [r['id']]);
      final fresh = (await ex.query('payments', where: 'id = ?', whereArgs: [r['id']], limit: 1)).first;
      await _enqueue(ex, 'payment', '${r['id']}', 'update', fresh);
      remaining -= cut;
    }
    return newPaid;
  }

  Future<void> _logAudit(String action, String reference, String details) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': action,
        'reference': reference,
        'details': details,
        'createdAt': _now(),
      });
    } catch (_) {
      // Audit kabhi commit shuda save ko na tode.
    }
  }

  Future<void> _refreshAll() async {
    await ProductRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
  }

  // ---------------------------------------------------------------- Return

  /// Partial purchase return (admin). [requested] = purchase_items.id -> return qty.
  /// Kotlin processPartialReturn(): sirf wahi qty stock/cost/supplier balance se nikalti hai; sab lines
  /// poori return => bill 'returned'. Sab ek transaction mein.
  Future<void> returnItems(String billNo, Map<int, double> requested) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    double returnedTotal = 0;
    await db.transaction((txn) async {
      final pr = await txn.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
      if (pr.isEmpty) throw StateError('Ye bill nahi mila');
      final purchase = Purchase.fromMap(pr.first);
      if (purchase.status == 'returned') throw StateError('Ye purchase pehle hi return ho chuki hai');
      final now = _now();

      for (final e in requested.entries) {
        if (e.value <= 0) continue;
        final ir = await txn.query('purchase_items', where: 'id = ?', whereArgs: [e.key], limit: 1);
        if (ir.isEmpty) continue;
        final item = PurchaseItem.fromMap(ir.first);
        final qty = e.value > item.qty ? item.qty : e.value;
        if (qty <= 0) continue;

        final product = await _product(txn, item.barcode);
        final smallest = partialSmallestQty(item, product, qty);
        final amount = returnedLineAmount(lineQty: item.qty, lineAmount: item.amount, unitCost: item.unitCost, returnQty: qty);

        if (product != null && smallest > 0) {
          if (smallest > product.stock) {
            throw InsufficientStockException(
                '"${product.name}" ka stock is purchase ke baad already kam ho chuka hai (sale ya doosri entry se) — itni miqdaar wapas karna cost ko galat kar dega.');
          }
          final newCost = reversePurchaseLineCost(
            productCost: product.cost,
            productStock: product.stock,
            factor: product.smallestUnitFactor(),
            itemAmount: amount,
            smallestQtyToRemove: smallest,
          );
          await txn.rawUpdate(
              'UPDATE products SET stock = stock - ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
              [smallest, newCost, now, item.barcode]);
          await SyncQueueHelper.enqueueStockDelta(txn, item.barcode, -smallest);
          await StockLedger.log(txn,
              barcode: item.barcode,
              type: MovementType.purchaseReturn,
              signedQty: -smallest,
              reference: billNo,
              unitCost: newCost,
              now: now);
          await _enqueueProduct(txn, item.barcode);
        }

        final ret = ReturnLine(reference: billNo, type: 'purchase', barcode: item.barcode, qty: qty, amount: amount, createdAt: now);
        final retId = await txn.insert('returns', ret.toMap());
        await _enqueue(txn, 'return', '$retId', 'create', ret.toMap());

        final remainingQty = item.qty - qty;
        if (remainingQty <= 0.0001) {
          await txn.delete('purchase_items', where: 'id = ?', whereArgs: [item.id]);
        } else {
          await txn.update('purchase_items', {'qty': remainingQty, 'amount': item.amount - amount}, where: 'id = ?', whereArgs: [item.id]);
        }
        returnedTotal += amount;
      }

      if (returnedTotal <= 0) return;

      final remainingCount =
          Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM purchase_items WHERE billNo = ?', [billNo])) ?? 0;
      final oldOutstanding = purchase.total - purchase.paid;
      final newSubtotal = (purchase.subtotal - returnedTotal) < 0 ? 0.0 : (purchase.subtotal - returnedTotal);
      final newTotal = (purchase.total - returnedTotal) < 0 ? 0.0 : (purchase.total - returnedTotal);

      if (remainingCount == 0) {
        // Poori bill wapas: supplier ka baqaya/advance wapas (overpaid bhi), cash ka dated reversal.
        if (purchase.supplierId != null && oldOutstanding.abs() > 0.009) {
          await _adjustSupplierBalance(txn, purchase.supplierId!, -oldOutstanding);
        }
        await _reverseCash(txn, billNo, purchase.paid, 'IN', 'Purchase Return');
        await _deletePaymentsByReference(txn, billNo);
        await _voidLinkedPayments(txn, billNo);
        // Kotlin FIX: status usi row mein set (alag raw call baad ke update se mit jati thi).
        await txn.update('purchases', {'subtotal': newSubtotal, 'total': newTotal, 'status': 'returned', 'updatedAt': now, 'dirty': 1},
            where: 'billNo = ?', whereArgs: [billNo]);
      } else {
        final newPaid = await _reconcilePaidAfterReturn(txn, billNo, purchase.paid, newTotal);
        await txn.update('purchases', {'subtotal': newSubtotal, 'total': newTotal, 'paid': newPaid, 'updatedAt': now, 'dirty': 1},
            where: 'billNo = ?', whereArgs: [billNo]);
        if (purchase.supplierId != null) {
          final delta = (newTotal - newPaid) - oldOutstanding;
          if (delta != 0.0) await _adjustSupplierBalance(txn, purchase.supplierId!, delta);
        }
      }
      final fresh = (await txn.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1)).first;
      await _enqueue(txn, 'purchase', billNo, 'update', fresh);
    });
    await _refreshAll();
    if (returnedTotal > 0) await _logAudit('purchase_return', billNo, 'returned=$returnedTotal');
  }

  // ---------------------------------------------------------------- Delete

  /// Poori purchase delete (admin): stock+cost wapas, supplier balance (overpaid bhi), bill + items +
  /// payments + cash rows, sab sync_queue ke saath — ek transaction. Stock bik chuka ho to rok deta hai.
  Future<void> deletePurchase(String billNo) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    Purchase? deleted;
    await db.transaction((txn) async {
      final pr = await txn.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
      if (pr.isEmpty) throw StateError('Ye bill nahi mila');
      final purchase = Purchase.fromMap(pr.first);
      final items = (await txn.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo])).map(PurchaseItem.fromMap).toList();
      final now = _now();

      // Returned bill ka stock pehle hi nikal chuka hai — dobara nahi nikalna.
      if (purchase.status != 'returned') {
        for (final it in items) {
          final product = await _product(txn, it.barcode);
          if (product == null) continue;
          final smallest = purchaseItemSmallestQty(it, product);
          final newCost = reversePurchaseLineCost(
            productCost: product.cost,
            productStock: product.stock,
            factor: product.smallestUnitFactor(),
            itemAmount: it.amount,
            smallestQtyToRemove: smallest,
          );
          final n = await txn.rawUpdate(
              'UPDATE products SET stock = stock - ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock >= ?',
              [smallest, newCost, now, it.barcode, smallest]);
          if (n == 0) {
            throw InsufficientStockException(
                '"${product.name}" ka stock is purchase ke baad kam ho chuka hai — delete karne se stock/cost galat ho jayega.');
          }
          await SyncQueueHelper.enqueueStockDelta(txn, it.barcode, -smallest);
          await StockLedger.log(txn,
              barcode: it.barcode,
              type: MovementType.purchaseReversal,
              signedQty: -smallest,
              reference: billNo,
              unitCost: newCost,
              now: now);
          await _enqueueProduct(txn, it.barcode);
        }
        final outstanding = purchase.total - purchase.paid;
        if (purchase.supplierId != null && outstanding.abs() > 0.009) {
          await _adjustSupplierBalance(txn, purchase.supplierId!, -outstanding);
        }
      }

      await txn.delete('purchase_items', where: 'billNo = ?', whereArgs: [billNo]);
      await txn.delete('purchases', where: 'billNo = ?', whereArgs: [billNo]);
      await _deletePaymentsByReference(txn, billNo);
      await _deleteCashByReference(txn, billNo);
      await _voidLinkedPayments(txn, billNo);
      await _enqueue(txn, 'purchase', billNo, 'delete', {'billNo': billNo});
      deleted = purchase;
    });
    await _refreshAll();
    final p = deleted;
    if (p != null) await _logAudit('purchase_delete', billNo, 'total=${p.total} paid=${p.paid} supplierId=${p.supplierId ?? 'cash'}');
  }
}
