import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/purchase.dart';
import 'app_database.dart';
import 'product_repository.dart';
import 'supplier_repository.dart';

/// One line the user has added to the purchase before saving — mirrors
/// `data class PurchaseLine` in PurchaseActivity.kt.
class PurchaseLine {
  final String itemName;
  final String? barcode;
  final double qty;
  final String unit;
  final double rate;
  final double amount;

  const PurchaseLine({
    required this.itemName,
    required this.barcode,
    required this.qty,
    required this.unit,
    required this.rate,
    required this.amount,
  });
}

class PurchaseRepository {
  PurchaseRepository._();
  static final PurchaseRepository instance = PurchaseRepository._();

  /// Mirrors `genBillNo()`: PUR-<MonYY>-0001, incrementing per month.
  Future<String> nextBillNo() async {
    final db = await AppDatabase.instance.database;
    final prefix = 'PUR-${DateFormat('MMMyy').format(DateTime.now())}-';
    final rows = await db.query('purchases', columns: ['billNo']);
    final existing = rows.map((r) => r['billNo'] as String).toSet();
    var seq = existing.where((b) => b.startsWith(prefix)).length + 1;
    var candidate = '$prefix${seq.toString().padLeft(4, '0')}';
    while (existing.contains(candidate)) {
      seq++;
      candidate = '$prefix${seq.toString().padLeft(4, '0')}';
    }
    return candidate;
  }

  Future<List<Purchase>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('purchases', orderBy: 'createdAt DESC');
    return rows.map(Purchase.fromMap).toList();
  }

  /// Mirrors `proceedSave()`: creates the supplier if new, inserts the
  /// purchase + items, bumps each product's stock and recalculates its
  /// weighted-average cost, updates the supplier's outstanding balance, and
  /// records a payment + cash transaction if anything was paid — all inside
  /// one transaction so a crash partway through can't leave stock, cost, and
  /// balance out of sync with the purchase record.
  Future<String> savePurchase({
    required String supplierName,
    required List<PurchaseLine> lines,
    required double amountPaid,
    required int purchaseDateMillis,
    String paymentMethod = 'Cash',
  }) async {
    if (supplierName.trim().isEmpty) {
      throw ArgumentError('Supplier name is required');
    }
    if (lines.isEmpty) {
      throw ArgumentError('Add at least one item');
    }

    final subtotal = lines.fold<double>(0, (sum, l) => sum + l.amount);
    final grandTotal = subtotal.roundToDouble().clamp(0.0, double.infinity);
    final paid = amountPaid.roundToDouble().clamp(0.0, grandTotal);

    final db = await AppDatabase.instance.database;
    final suppliers = await SupplierRepository.instance.listAll();
    final supplier = suppliers
        .where((s) => s.name.toLowerCase() == supplierName.trim().toLowerCase())
        .firstOrNull;
    int? supplierId = supplier?.id;

    final billNo = await nextBillNo();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      if (supplierId == null) {
        supplierId = await txn.insert('suppliers', {
          'name': supplierName.trim(),
          'phone': '',
          'openingBalance': 0.0,
          'balance': 0.0,
          'updatedAt': now,
          'dirty': 1,
        });
      }

      final purchase = Purchase(
        billNo: billNo,
        supplierId: supplierId,
        total: grandTotal,
        paid: paid,
        createdAt: purchaseDateMillis,
        subtotal: subtotal,
        discount: 0.0,
        updatedAt: now,
      );
      await txn.insert('purchases', purchase.toMap());

      for (final line in lines) {
        await txn.insert('purchase_items', {
          'billNo': billNo,
          'barcode': line.barcode ?? '',
          'qty': line.qty,
          'unitCost': line.rate,
          'amount': line.amount,
          'unit': line.unit,
        });
      }

      await _enqueueSync(txn, 'purchase', billNo, 'create', {
        'billNo': billNo,
        'supplierId': supplierId,
        'total': grandTotal,
        'paid': paid,
        'itemCount': lines.length,
      });

      // Stock + weighted-average cost per line — mirrors the Kotlin logic
      // exactly: newCost = (oldStock*oldCost + boughtQty*boughtRatePerUnit)
      // / (oldStock + boughtQty), all in smallest-unit terms.
      for (final line in lines) {
        final barcode = line.barcode;
        if (barcode == null || barcode.isEmpty) continue;

        final beforeRows = await txn.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
        if (beforeRows.isEmpty) continue;
        final before = Product.fromMap(beforeRows.first);

        final purchasedSmallest = before.toSmallestUnits(line.qty, line.unit);
        if (!before.isValidSmallestQty(purchasedSmallest)) {
          throw StateError(
            '"${before.name}" ke liye qty (${line.qty} ${line.unit}) whole ${before.smallestUnitName()} mein convert nahi hoti — qty check karen.',
          );
        }

        final oldStockSmallest = before.stock;
        double newCost = before.cost;
        if (purchasedSmallest > 0) {
          final factor = before.smallestUnitFactor();
          final oldCostPerSmallest = factor > 0 ? before.cost / factor : before.cost;
          final purchaseRatePerSmallest = line.amount / purchasedSmallest;
          final newCostPerSmallest = oldStockSmallest <= 0
              ? purchaseRatePerSmallest
              : ((oldStockSmallest * oldCostPerSmallest) + (purchasedSmallest * purchaseRatePerSmallest)) /
                  (oldStockSmallest + purchasedSmallest);
          newCost = newCostPerSmallest * factor;
        }

        await txn.rawUpdate(
          'UPDATE products SET stock = stock + ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [purchasedSmallest, newCost, now, barcode],
        );
      }

      final outstanding = grandTotal - paid;
      if (supplierId != null && outstanding > 0) {
        await txn.rawUpdate(
          'UPDATE suppliers SET balance = balance + ?, dirty = 1 WHERE id = ?',
          [outstanding, supplierId],
        );
      }

      if (supplierId != null && paid > 0) {
        final payment = Payment(
          reference: billNo,
          partyType: 'supplier',
          partyId: supplierId,
          amount: paid,
          method: paymentMethod,
          note: 'Purchase payment',
          createdAt: now,
        );
        await txn.insert('payments', payment.toMap());
        await _enqueueSync(txn, 'payment', billNo, 'create', payment.toMap());
      }

      if (paid > 0) {
        final cashTx = CashTransaction(
          type: 'OUT',
          method: paymentMethod.toLowerCase(),
          amount: paid,
          reason: 'Purchase',
          reference: billNo,
          createdAt: now,
        );
        final cashTxId = await txn.insert('cash_transactions', cashTx.toMap());
        await _enqueueSync(txn, 'cash_transaction', cashTxId.toString(), 'create', cashTx.toMap());
      }
    });

    // Refresh reactive streams so the Product/Supplier screens immediately
    // reflect the new stock, cost, and balances written above (those were
    // raw SQL writes inside the transaction, bypassing each repository's
    // own notify-on-write).
    await ProductRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
    return billNo;
  }

  Future<void> _enqueueSync(
    Transaction txn,
    String entityType,
    String entityId,
    String operation,
    Map<String, Object?> payload,
  ) async {
    // Mirrors SyncQueueHelper.enqueue() — one row per pending change, picked
    // up by whatever background sync worker you wire up against Firestore.
    await txn.insert('sync_queue', {
      'entityType': entityType,
      'entityId': entityId,
      'operation': operation,
      'payloadJson': payload.toString(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'retryCount': 0,
    });
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
