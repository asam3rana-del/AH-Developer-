
import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../models/product.dart';
import '../models/purchase.dart';
import '../models/sale.dart';
import '../services/session.dart';
import '../utils/stock_touch_policy.dart' show saleItemSmallestQty;
import '../models/stock_movement.dart' show MovementType;
import 'app_database.dart';
import 'customer_repository.dart';
import 'stock_ledger.dart';
import 'supplier_repository.dart';
import '../sync/sync_queue_helper.dart';

/// Ports the data/logic half of PartyTransactionActivity.kt.
///
/// Payments (save / edit / delete) already live in `payment_repository.dart`; yahan:
///  * ek party ki bills + standalone payments ka load ([load]) aur stat-grid / balance card
///    ka PURE hisaab ([computePartyTxStats]) — test/party_transaction_test.dart.
///  * Billed Items dialog ke item edit / delete (sale + purchase) — har ek DB transaction mein
///    (stock, bill total/paid, party balance, cash, sync_queue) — Kotlin FIX #8/#9.
///  * party rename.
///
/// Rules: item edit/delete sirf admin (yahan data layer par bhi check, PORTING_PLAN §1).
/// Supplier (purchase) data cashier ko load nahi hota.

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

enum TxFilter { all, bills, payments }

/// Ek row: bill (sale / purchase) ya standalone payment.
class TxEntry {
  final int createdAt;
  final bool isPayment;
  final String searchText;
  final Sale? sale;
  final Purchase? purchase;
  final Payment? payment;
  const TxEntry({
    required this.createdAt,
    required this.isPayment,
    required this.searchText,
    this.sale,
    this.purchase,
    this.payment,
  });

  double get amount => sale?.total ?? purchase?.total ?? payment?.amount ?? 0.0;
  String get status => sale?.status ?? purchase?.status ?? 'active';
}

/// Kotlin renderEntries(): chip filter + search (lowercase `contains`) — memory mein, DB hit nahi.
List<TxEntry> filterTxEntries(List<TxEntry> all, TxFilter filter, String query) {
  final q = query.trim().toLowerCase();
  return all.where((e) {
    final ok = switch (filter) {
      TxFilter.all => true,
      TxFilter.bills => !e.isPayment,
      TxFilter.payments => e.isPayment,
    };
    return ok && (q.isEmpty || e.searchText.contains(q));
  }).toList();
}

/// Sirf asli standalone payments (Kotlin FIX): jinka `reference` kisi apni bill ka id ho
/// (savePurchase ka "Purchase payment" row) wo bill ke `paid` mein pehle se hai — dobara na ginein.
List<Payment> standalonePayments(Iterable<Payment> all, Set<String> ownBillIds) =>
    all.where((p) => !ownBillIds.contains(p.reference)).toList();

typedef TxBill = ({double total, double paid, String status, int createdAt, int dueDate});
typedef TxPay = ({double amount, String billReference});

class PartyTxStats {
  final double totalAmount; // Total Sales / Purchases (sab status)
  final double totalPaid; // bills ka paid + standalone (unlinked) payments
  final double overdue;
  final double creditLimit; // 0 = No Limit (supplier ke liye hamesha 0)
  final int? lastActivityAt;
  final double opening;
  final double stuck;

  /// Non-returned bills ka outstanding minus standalone payments (drift-free live ledger).
  final double running;
  const PartyTxStats({
    required this.totalAmount,
    required this.totalPaid,
    required this.overdue,
    required this.creditLimit,
    required this.lastActivityAt,
    required this.opening,
    required this.stuck,
    required this.running,
  });

  /// Daily Payable (stuck se pehle).
  double get daily => opening + running;

  /// Headline "You'll Get / You'll Give" figure = daily + stuck.
  double get closing => opening + running + stuck;
}

/// Kotlin loadTransactions() ka hisaab. `dueDate` 0 = date set nahi => overdue mein nahi ginti.
PartyTxStats computePartyTxStats({
  required List<TxBill> bills,
  required List<TxPay> standalone,
  required double opening,
  double stuck = 0.0,
  double creditLimit = 0.0,
  int? nowMillis,
}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  var total = 0.0, paidOnBills = 0.0, overdue = 0.0, outstanding = 0.0;
  int? last;
  for (final b in bills) {
    total += b.total;
    paidOnBills += b.paid;
    final active = b.status != 'returned';
    final due = b.total - b.paid;
    if (active) outstanding += due;
    if (active && b.dueDate > 0 && b.dueDate < now && due > 0.009) overdue += due;
    if (last == null || b.createdAt > last) last = b.createdAt;
  }
  // Bill se linked payment pehle hi bill ke `paid` mein hai — dobara na ginein (Kotlin FIX audit).
  final paymentsSum = standalone.where((p) => p.billReference.isEmpty).fold<double>(0, (a, p) => a + p.amount);
  return PartyTxStats(
    totalAmount: total,
    totalPaid: paidOnBills + paymentsSum,
    overdue: overdue,
    creditLimit: creditLimit,
    lastActivityAt: last,
    opening: opening,
    stuck: stuck,
    running: outstanding - paymentsSum,
  );
}

/// Bill ka `paid` naye total se upar nahi ja sakta (kam hi hota hai, kabhi barhta nahi).
double reconcilePaid(double oldPaid, double newTotal) => oldPaid.clamp(0.0, newTotal < 0 ? 0.0 : newTotal).toDouble();

/// Ek purchase line ko product ki weighted-average cost se nikalna (Kotlin reversePurchaseLineCost).
/// [factor] = `product.smallestUnitFactor()`; qty smallest units mein.
double reversePurchaseLineCost({
  required double productCost,
  required double productStock,
  required double factor,
  required double itemAmount,
  required double smallestQtyToRemove,
}) {
  if (smallestQtyToRemove <= 0) return productCost;
  final costPerSmallest = factor > 0 ? productCost / factor : productCost;
  final newStock = productStock - smallestQtyToRemove;
  final valueBefore = productStock * costPerSmallest;
  final valueAfter = (valueBefore - itemAmount) < 0 ? 0.0 : (valueBefore - itemAmount);
  final newCostPerSmallest = newStock > 0 ? valueAfter / newStock : 0.0;
  return newCostPerSmallest * factor;
}

/// Ek naya/edit shuda purchase line cost mein milana (Kotlin addPurchaseLineCost).
/// [productStock] / [productCost] wo hon jo is line ke ADD hone se theek pehle hain.
double addPurchaseLineCost({
  required double productCost,
  required double productStock,
  required double factor,
  required double addedSmallestQty,
  required double lineAmount,
}) {
  if (addedSmallestQty <= 0) return productCost;
  final oldPer = factor > 0 ? productCost / factor : productCost;
  final ratePer = lineAmount / addedSmallestQty;
  final newPer = productStock <= 0
      ? ratePer
      : ((productStock * oldPer) + (addedSmallestQty * ratePer)) / (productStock + addedSmallestQty);
  return newPer * factor;
}

/// Purchase line ki smallest-unit qty. Khareed ke waqt jama shuda conversionFactor pehle (DB v12); sirf
/// purani rows (factor == 0) ke liye product ki MAUJUDA ladder — Kotlin `PurchaseItem.smallestQty(product)`.
double purchaseItemSmallestQty(PurchaseItem item, Product? product) {
  if (item.conversionFactor > 0) return item.qty * item.conversionFactor;
  if (product == null) return item.qty;
  return product.toSmallestUnits(item.qty, item.unit.isEmpty ? product.unit : item.unit);
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Kotlin `InsufficientStockException` — transaction ko saaf tareeqe se rollback karne ke liye.
class InsufficientStockException implements Exception {
  final String message;
  const InsufficientStockException(this.message);
  @override
  String toString() => message;
}

class PartyTxData {
  final double opening;
  final double stuck;
  final double creditLimit;
  final List<Sale> sales;
  final List<Purchase> purchases;
  final List<Payment> payments; // sirf standalone
  const PartyTxData({
    this.opening = 0,
    this.stuck = 0,
    this.creditLimit = 0,
    this.sales = const [],
    this.purchases = const [],
    this.payments = const [],
  });
}

class PartyTransactionRepository {
  PartyTransactionRepository._();
  static final PartyTransactionRepository instance = PartyTransactionRepository._();

  static const _adminOnlyMsg = 'Sirf Admin ye action kar sakta hai';

  void _requireAdmin() {
    if (!Session.isAdmin) throw StateError(_adminOnlyMsg);
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  Future<void> _enqueue(DatabaseExecutor ex, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(ex, type, id, op, payload);

  Future<void> _refreshParties() async {
    await CustomerRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
  }

  // ------------------------------------------------------------------ load

  /// Party ki bills (sab status) + standalone payments + opening/stuck/creditLimit.
  /// Supplier data cashier ko nahi milta (data layer par role check).
  Future<PartyTxData> load({required bool isCustomer, required int partyId}) async {
    if (!isCustomer && !Session.isAdminOrManager) return const PartyTxData();
    final db = await AppDatabase.instance.database;
    var opening = 0.0, stuck = 0.0, credit = 0.0;
    if (isCustomer) {
      final r = await db.query('customers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (r.isNotEmpty) {
        opening = (r.first['openingBalance'] as num?)?.toDouble() ?? 0.0;
        stuck = (r.first['stuckBalance'] as num?)?.toDouble() ?? 0.0;
        credit = (r.first['creditLimit'] as num?)?.toDouble() ?? 0.0;
      }
    } else {
      final r = await db.query('suppliers', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (r.isNotEmpty) opening = (r.first['openingBalance'] as num?)?.toDouble() ?? 0.0;
    }

    final sales = isCustomer
        ? (await db.query('sales', where: 'customerId = ?', whereArgs: [partyId], orderBy: 'createdAt DESC'))
            .map(Sale.fromMap)
            .toList()
        : <Sale>[];
    final purchases = isCustomer
        ? <Purchase>[]
        : (await db.query('purchases', where: 'supplierId = ?', whereArgs: [partyId], orderBy: 'createdAt DESC'))
            .map(Purchase.fromMap)
            .toList();
    final ownIds = isCustomer ? sales.map((s) => s.invoice).toSet() : purchases.map((p) => p.billNo).toSet();
    final payRows = await db.query('payments',
        where: 'partyType = ? AND partyId = ?',
        whereArgs: [isCustomer ? 'customer' : 'supplier', partyId],
        orderBy: 'createdAt DESC');
    final payments = standalonePayments(payRows.map(Payment.fromMap), ownIds);

    return PartyTxData(
      opening: opening,
      stuck: stuck,
      creditLimit: credit,
      sales: sales,
      purchases: purchases,
      payments: payments,
    );
  }

  // ---------------------------------------------------------------- rename

  /// Kotlin saveNewPartyName(): naam badalna + sync_queue. false = party nahi mili.
  Future<bool> renameParty({required bool isCustomer, required int partyId, required String newName}) async {
    final name = newName.trim();
    if (name.isEmpty) throw ArgumentError('Name cannot be empty');
    final db = await AppDatabase.instance.database;
    final table = isCustomer ? 'customers' : 'suppliers';
    var found = false;
    await db.transaction((txn) async {
      final r = await txn.query(table, where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (r.isEmpty) return;
      found = true;
      final now = _now();
      await txn.update(table, {'name': name, 'dirty': 1, 'updatedAt': now}, where: 'id = ?', whereArgs: [partyId]);
      if (isCustomer) {
        await SyncQueueHelper.enqueueCustomer(txn, partyId);
      } else {
        await SyncQueueHelper.enqueueSupplier(txn, partyId);
      }
    });
    if (found) await _refreshParties();
    return found;
  }

  // ------------------------------------------------------------- read helpers

  Future<Sale?> findSale(String invoice) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('sales', where: 'invoice = ?', whereArgs: [invoice], limit: 1);
    return r.isEmpty ? null : Sale.fromMap(r.first);
  }

  Future<Purchase?> findPurchase(String billNo) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
    return r.isEmpty ? null : Purchase.fromMap(r.first);
  }

  Future<List<SaleItem>> saleItems(String invoice) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('sale_items', where: 'invoice = ?', whereArgs: [invoice], orderBy: 'id ASC');
    return r.map(SaleItem.fromMap).toList();
  }

  Future<List<PurchaseItem>> purchaseItems(String billNo) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo], orderBy: 'id ASC');
    return r.map(PurchaseItem.fromMap).toList();
  }

  /// Purchase line ka naam: product ka maujuda naam, warna barcode.
  Future<Map<String, String>> productNames(Iterable<String> barcodes) async {
    final db = await AppDatabase.instance.database;
    final out = <String, String>{};
    for (final b in barcodes.toSet()) {
      final r = await db.query('products', columns: ['name'], where: 'barcode = ?', whereArgs: [b], limit: 1);
      out[b] = r.isEmpty ? b : (r.first['name'] as String);
    }
    return out;
  }

  // ------------------------------------------------------------ shared txn bits

  Future<Product?> _product(DatabaseExecutor ex, String barcode) async {
    final r = await ex.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    return r.isEmpty ? null : Product.fromMap(r.first);
  }

  Future<void> _enqueueProduct(DatabaseExecutor ex, String barcode) =>
      SyncQueueHelper.enqueueProduct(ex, barcode);

  Future<void> _adjustPartyBalance(DatabaseExecutor ex, bool isCustomer, int partyId, double delta) async {
    final table = isCustomer ? 'customers' : 'suppliers';
    await ex.rawUpdate('UPDATE $table SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
        [delta, _now(), partyId]);
    await SyncQueueHelper.enqueueBalanceDelta(ex, customer: isCustomer, partyId: partyId, delta: delta);
  }

  Future<void> _deleteCashByReference(DatabaseExecutor ex, String reference) =>
      SyncQueueHelper.deleteCashTransactionsByReference(ex, reference);

  /// Kotlin reverseCashByReference: asli cash rows chhoote nahi, ek nayi dated reversal row
  /// (`return:<ref>`) banti hai, purane methods ke hisaab se barabar taqseem.
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

  /// Bill ke saath linked payments (billReference == bill) hata do: payment row + uski cash rows.
  /// Party balance ko haath nahi lagate (bill ka apna reversal total-paid se pehle hi theek hai).
  Future<void> _voidLinkedPayments(DatabaseExecutor ex, String billRef) async {
    final rows = await ex.query('payments', where: 'billReference = ?', whereArgs: [billRef]);
    for (final p in rows) {
      await _deleteCashByReference(ex, p['reference'] as String);
      await SyncQueueHelper.deletePaymentRow(ex, Map<String, Object?>.from(p));
    }
  }

  /// Purchase ki apni "Purchase payment" rows (reference == billNo) — poori bill delete par.
  Future<void> _deletePaymentsByReference(DatabaseExecutor ex, String reference) =>
      SyncQueueHelper.deletePaymentsByReference(ex, reference);

  Future<void> _reducePaymentRecords(DatabaseExecutor ex, String reference, double amountToRemove) async {
    var remaining = amountToRemove;
    final rows = await ex.query('payments', where: 'reference = ?', whereArgs: [reference], orderBy: 'createdAt DESC');
    for (final r in rows) {
      if (remaining <= 0) break;
      final amt = (r['amount'] as num).toDouble();
      final reduction = remaining < (amt < 0 ? 0.0 : amt) ? remaining : (amt < 0 ? 0.0 : amt);
      if (reduction <= 0) continue;
      final newAmt = (amt - reduction) < 0 ? 0.0 : (amt - reduction);
      await ex.update('payments', {'amount': newAmt, 'updatedAt': _now(), 'dirty': 1},
          where: 'id = ?', whereArgs: [r['id']]);
      final fresh = (await ex.query('payments', where: 'id = ?', whereArgs: [r['id']], limit: 1)).first;
      await _enqueue(ex, 'payment', '${r['id']}', 'update', fresh);
      remaining -= reduction;
    }
  }

  /// Kotlin reconcilePaidAndCashRecords(): bill chhoti hui to `paid` cap + cash (aur purchase ke
  /// payment records) usi qadar kam. Naya `paid` wapas deta hai.
  Future<double> _reconcilePaidAndCash(
    DatabaseExecutor ex, {
    required String reference,
    required double oldPaid,
    required double newTotal,
    required bool isPurchase,
  }) async {
    final newPaid = reconcilePaid(oldPaid, newTotal);
    final delta = newPaid - oldPaid;
    if (delta == 0) return newPaid;
    final reduction = -delta;
    await _reverseCash(ex, reference, reduction, isPurchase ? 'IN' : 'OUT',
        isPurchase ? 'Purchase Adjustment' : 'Sale Adjustment');
    if (isPurchase) await _reducePaymentRecords(ex, reference, reduction);
    return newPaid;
  }

  Future<void> _writeSale(DatabaseExecutor ex, Sale sale, {required double subtotal, required double total, required double paid}) async {
    await ex.update('sales', {'subtotal': subtotal, 'total': total, 'paid': paid, 'dirty': 1, 'updatedAt': _now()},
        where: 'invoice = ?', whereArgs: [sale.invoice]);
    final fresh = (await ex.query('sales', where: 'invoice = ?', whereArgs: [sale.invoice], limit: 1)).first;
    await _enqueue(ex, 'sale', sale.invoice, 'update', fresh);
  }

  Future<void> _writePurchase(DatabaseExecutor ex, Purchase p, {required double subtotal, required double total, required double paid}) async {
    await ex.update('purchases', {'subtotal': subtotal, 'total': total, 'paid': paid, 'dirty': 1, 'updatedAt': _now()},
        where: 'billNo = ?', whereArgs: [p.billNo]);
    final fresh = (await ex.query('purchases', where: 'billNo = ?', whereArgs: [p.billNo], limit: 1)).first;
    await _enqueue(ex, 'purchase', p.billNo, 'update', fresh);
  }

  // ---------------------------------------------------------------- sale item

  /// Sale ki ek line ki qty/rate badalna. Kotlin applySaleItemEdit(): stock (sirf qty badle to,
  /// bill ke waqt ka frozen factor se), line, bill total/paid, customer balance, cash — ek transaction.
  /// [InsufficientStockException] par sab rollback.
  Future<void> editSaleItem({required SaleItem item, required double newQty, required double newRate}) async {
    _requireAdmin();
    if (item.id == null) throw ArgumentError('Item id missing');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final itemRows = await txn.query('sale_items', where: 'id = ?', whereArgs: [item.id], limit: 1);
      if (itemRows.isEmpty) throw StateError('Item not found');
      final cur = SaleItem.fromMap(itemRows.first);
      final sale = (await findSaleIn(txn, cur.invoice)) ?? (throw StateError('Sale not found'));
      final product = await _product(txn, cur.barcode);
      final oldQty = cur.qty;

      // Purani qty PURANE factor se wapas; nayi MAUJUDA config se. Rate-only edit stock ko nahi chhoota.
      final qtyChanged = (newQty - oldQty).abs() > 1e-9;
      final oldSmallest = saleItemSmallestQty(cur, product);
      final newSmallest = product == null
          ? newQty
          : product.toSmallestUnits(newQty, cur.unit.isEmpty ? product.unit : cur.unit);
      final net = qtyChanged ? newSmallest - oldSmallest : 0.0;

      if (product != null && net != 0) {
        if (net > 0) {
          final rows = await txn.rawUpdate(
              'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock >= ?',
              [net, _now(), cur.barcode, net]);
          if (rows == 0) throw const InsufficientStockException('Not enough stock');
        } else {
          await txn.rawUpdate('UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
              [-net, _now(), cur.barcode]);
        }
        // net > 0 => zyada bika => stock ghata (-net); net < 0 => stock wapas (-net = +ve).
        await SyncQueueHelper.enqueueStockDelta(txn, cur.barcode, -net);
        await StockLedger.log(txn,
            barcode: cur.barcode, type: MovementType.saleEdit, signedQty: -net, reference: cur.invoice);
      }

      final perUnitCost = oldQty != 0 ? cur.cost / oldQty : 0.0;
      final newAmount = newQty * newRate;
      await txn.update(
        'sale_items',
        {
          'qty': newQty,
          'unitPrice': newRate,
          'amount': newAmount,
          'cost': perUnitCost * newQty,
          'conversionFactor': qtyChanged
              ? (product != null ? product.smallestPerUnitOf(cur.unit) : cur.conversionFactor)
              : cur.conversionFactor,
        },
        where: 'id = ?',
        whereArgs: [cur.id],
      );

      final deltaAmount = newAmount - cur.amount;
      final newTotal = sale.total + deltaAmount;
      final newPaid = await _reconcilePaidAndCash(txn,
          reference: sale.invoice, oldPaid: sale.paid, newTotal: newTotal, isPurchase: false);
      await _writeSale(txn, sale, subtotal: sale.subtotal + deltaAmount, total: newTotal, paid: newPaid);

      if (sale.customerId != null) {
        // Balance = total - paid; paid cap hua to wo hissa wapas jorna hai (phantom credit nahi).
        await _adjustPartyBalance(txn, true, sale.customerId!, deltaAmount + (sale.paid - newPaid));
      }
      if (product != null) await _enqueueProduct(txn, cur.barcode);
    });
    await _refreshParties();
  }

  Future<Sale?> findSaleIn(DatabaseExecutor ex, String invoice) async {
    final r = await ex.query('sales', where: 'invoice = ?', whereArgs: [invoice], limit: 1);
    return r.isEmpty ? null : Sale.fromMap(r.first);
  }

  Future<Purchase?> findPurchaseIn(DatabaseExecutor ex, String billNo) async {
    final r = await ex.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
    return r.isEmpty ? null : Purchase.fromMap(r.first);
  }

  /// Sale ki ek line delete. Aakhri line gayi to poori sale (cash + linked payments samet) delete.
  /// true = poori sale delete hui.
  Future<bool> deleteSaleItem(SaleItem item) async {
    _requireAdmin();
    if (item.id == null) throw ArgumentError('Item id missing');
    final db = await AppDatabase.instance.database;
    var deletedWhole = false;
    await db.transaction((txn) async {
      final itemRows = await txn.query('sale_items', where: 'id = ?', whereArgs: [item.id], limit: 1);
      if (itemRows.isEmpty) throw StateError('Item not found');
      final cur = SaleItem.fromMap(itemRows.first);
      final sale = (await findSaleIn(txn, cur.invoice)) ?? (throw StateError('Sale not found'));
      final product = await _product(txn, cur.barcode);

      if (product != null) {
        await txn.rawUpdate('UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
            [saleItemSmallestQty(cur, product), _now(), cur.barcode]);
        await SyncQueueHelper.enqueueStockDelta(txn, cur.barcode, saleItemSmallestQty(cur, product));
        await StockLedger.log(txn,
            barcode: cur.barcode,
            type: MovementType.saleItemDelete,
            signedQty: saleItemSmallestQty(cur, product),
            reference: cur.invoice);
        await _enqueueProduct(txn, cur.barcode);
      }
      await txn.delete('sale_items', where: 'id = ?', whereArgs: [cur.id]);

      final remaining = Sqflite.firstIntValue(await txn
              .rawQuery('SELECT COUNT(*) FROM sale_items WHERE invoice = ?', [sale.invoice])) ??
          0;
      if (remaining == 0) {
        deletedWhole = true;
        await txn.delete('sales', where: 'invoice = ?', whereArgs: [sale.invoice]);
        if (sale.customerId != null) {
          // Sirf outstanding (total-paid) balance par tha; overpaid (negative) advance bhi ulta hota hai.
          final outstanding = sale.total - sale.paid;
          if (outstanding.abs() > 0.009) await _adjustPartyBalance(txn, true, sale.customerId!, -outstanding);
        }
        await _deleteCashByReference(txn, sale.invoice);
        await _voidLinkedPayments(txn, sale.invoice);
        await _enqueue(txn, 'sale', sale.invoice, 'delete', {'invoice': sale.invoice});
      } else {
        final newTotal = sale.total - cur.amount;
        final newPaid = await _reconcilePaidAndCash(txn,
            reference: sale.invoice, oldPaid: sale.paid, newTotal: newTotal, isPurchase: false);
        await _writeSale(txn, sale, subtotal: sale.subtotal - cur.amount, total: newTotal, paid: newPaid);
        if (sale.customerId != null) {
          await _adjustPartyBalance(txn, true, sale.customerId!, -cur.amount + (sale.paid - newPaid));
        }
      }
    });
    await _refreshParties();
    return deletedWhole;
  }

  // ------------------------------------------------------------ purchase item

  /// Purchase line ki qty/rate badalna: stock + weighted-average cost dono theek hote hain
  /// (pehle purani line cost se nikalti hai, phir nayi milti hai).
  Future<void> editPurchaseItem({required PurchaseItem item, required double newQty, required double newRate}) async {
    _requireAdmin();
    if (item.id == null) throw ArgumentError('Item id missing');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final itemRows = await txn.query('purchase_items', where: 'id = ?', whereArgs: [item.id], limit: 1);
      if (itemRows.isEmpty) throw StateError('Item not found');
      final cur = PurchaseItem.fromMap(itemRows.first);
      final purchase = (await findPurchaseIn(txn, cur.billNo)) ?? (throw StateError('Purchase not found'));
      final product = await _product(txn, cur.barcode);

      final qtyChanged = (newQty - cur.qty).abs() > 1e-9;
      final oldSmallest = purchaseItemSmallestQty(cur, product);
      // Unit nahi badalta (sirf qty/rate), is liye bill par jama shuda conversionFactor hi lagta hai —
      // sirf purani rows (factor == 0) mein product ki maujuda ladder.
      final newSmallest = !qtyChanged
          ? oldSmallest
          : (cur.conversionFactor > 0
              ? newQty * cur.conversionFactor
              : (product == null
                  ? newQty
                  : product.toSmallestUnits(newQty, cur.unit.isEmpty ? product.unit : cur.unit)));
      final net = newSmallest - oldSmallest;
      final newAmount = newQty * newRate;

      if (product != null) {
        if (oldSmallest > product.stock) {
          throw const InsufficientStockException(
              "Cannot edit: this item's stock has already been used elsewhere. Use a stock adjustment instead.");
        }
        final factor = product.smallestUnitFactor();
        final costAfterReversal = reversePurchaseLineCost(
            productCost: product.cost,
            productStock: product.stock,
            factor: factor,
            itemAmount: cur.amount,
            smallestQtyToRemove: oldSmallest);
        final finalCost = newSmallest > 0
            ? addPurchaseLineCost(
                productCost: costAfterReversal,
                productStock: product.stock - oldSmallest,
                factor: factor,
                addedSmallestQty: newSmallest,
                lineAmount: newAmount)
            : costAfterReversal;
        final rows = await txn.rawUpdate(
            'UPDATE products SET stock = stock + ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock + ? >= 0',
            [net, finalCost, _now(), cur.barcode, net]);
        if (rows == 0) throw const InsufficientStockException('Not enough stock to reduce');
        await SyncQueueHelper.enqueueStockDelta(txn, cur.barcode, net);
        await StockLedger.log(txn,
            barcode: cur.barcode,
            type: MovementType.purchaseEdit,
            signedQty: net,
            reference: cur.billNo,
            unitCost: finalCost,
            allowZero: true);
      }

      await txn.update('purchase_items', {'qty': newQty, 'unitCost': newRate, 'amount': newAmount},
          where: 'id = ?', whereArgs: [cur.id]);

      final deltaAmount = newAmount - cur.amount;
      final newTotal = purchase.total + deltaAmount;
      final newPaid = await _reconcilePaidAndCash(txn,
          reference: purchase.billNo, oldPaid: purchase.paid, newTotal: newTotal, isPurchase: true);
      await _writePurchase(txn, purchase, subtotal: purchase.subtotal + deltaAmount, total: newTotal, paid: newPaid);

      if (purchase.supplierId != null) {
        await _adjustPartyBalance(txn, false, purchase.supplierId!, deltaAmount + (purchase.paid - newPaid));
      }
      if (product != null) await _enqueueProduct(txn, cur.barcode);
    });
    await _refreshParties();
  }

  /// Purchase ki ek line delete (stock + cost wapas). true = poori purchase delete hui.
  Future<bool> deletePurchaseItem(PurchaseItem item) async {
    _requireAdmin();
    if (item.id == null) throw ArgumentError('Item id missing');
    final db = await AppDatabase.instance.database;
    var deletedWhole = false;
    await db.transaction((txn) async {
      final itemRows = await txn.query('purchase_items', where: 'id = ?', whereArgs: [item.id], limit: 1);
      if (itemRows.isEmpty) throw StateError('Item not found');
      final cur = PurchaseItem.fromMap(itemRows.first);
      final purchase = (await findPurchaseIn(txn, cur.billNo)) ?? (throw StateError('Purchase not found'));
      final product = await _product(txn, cur.barcode);

      if (product != null) {
        final delta = purchaseItemSmallestQty(cur, product);
        final newCost = reversePurchaseLineCost(
            productCost: product.cost,
            productStock: product.stock,
            factor: product.smallestUnitFactor(),
            itemAmount: cur.amount,
            smallestQtyToRemove: delta);
        final rows = await txn.rawUpdate(
            'UPDATE products SET stock = stock - ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock >= ?',
            [delta, newCost, _now(), cur.barcode, delta]);
        if (rows == 0) throw const InsufficientStockException('Cannot delete: stock already used');
        await SyncQueueHelper.enqueueStockDelta(txn, cur.barcode, -delta);
        await StockLedger.log(txn,
            barcode: cur.barcode,
            type: MovementType.purchaseItemDelete,
            signedQty: -delta,
            reference: cur.billNo,
            unitCost: newCost);
        await _enqueueProduct(txn, cur.barcode);
      }
      await txn.delete('purchase_items', where: 'id = ?', whereArgs: [cur.id]);

      final remaining = Sqflite.firstIntValue(await txn
              .rawQuery('SELECT COUNT(*) FROM purchase_items WHERE billNo = ?', [purchase.billNo])) ??
          0;
      if (remaining == 0) {
        deletedWhole = true;
        await txn.delete('purchases', where: 'billNo = ?', whereArgs: [purchase.billNo]);
        if (purchase.supplierId != null) {
          final outstanding = purchase.total - purchase.paid;
          if (outstanding.abs() > 0.009) {
            await _adjustPartyBalance(txn, false, purchase.supplierId!, -outstanding);
          }
        }
        await _deletePaymentsByReference(txn, purchase.billNo);
        await _deleteCashByReference(txn, purchase.billNo);
        await _voidLinkedPayments(txn, purchase.billNo);
        await _enqueue(txn, 'purchase', purchase.billNo, 'delete', {'billNo': purchase.billNo});
      } else {
        final newTotal = purchase.total - cur.amount;
        final newPaid = await _reconcilePaidAndCash(txn,
            reference: purchase.billNo, oldPaid: purchase.paid, newTotal: newTotal, isPurchase: true);
        await _writePurchase(txn, purchase, subtotal: purchase.subtotal - cur.amount, total: newTotal, paid: newPaid);
        if (purchase.supplierId != null) {
          await _adjustPartyBalance(txn, false, purchase.supplierId!, -cur.amount + (purchase.paid - newPaid));
        }
      }
    });
    await _refreshParties();
    return deletedWhole;
  }
}
