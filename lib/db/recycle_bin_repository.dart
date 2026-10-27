import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/product.dart';
import '../models/purchase.dart';
import '../models/sale.dart';
import '../models/stock_movement.dart' show MovementType;
import '../services/session.dart';
import '../sync/branch_config_store.dart';
import '../sync/sync_queue_helper.dart';
import '../utils/stock_touch_policy.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'payment_repository.dart';
import 'product_repository.dart';
import 'sale_repository.dart';
import 'stock_ledger.dart';
import 'supplier_repository.dart';

/// Snapshot: `{tableName: [row, row...]}` ko JSON text mein (bin ki `dataJson` column).
String encodeBinRows(Map<String, List<Map<String, Object?>>> rows) =>
    jsonEncode({for (final e in rows.entries) e.key: e.value});

/// [encodeBinRows] ka ulta. Kharab / khali text, ya galat shape par khali map (kabhi throw nahi).
Map<String, List<Map<String, Object?>>> decodeBinRows(String text) {
  try {
    final d = jsonDecode(text);
    if (d is! Map) return {};
    final out = <String, List<Map<String, Object?>>>{};
    d.forEach((k, v) {
      if (k is! String || v is! List) return;
      out[k] = [
        for (final r in v)
          if (r is Map) Map<String, Object?>.from(r)
      ];
    });
    return out;
  } catch (_) {
    return {};
  }
}

/// Restore na ho sakne ki wajah (user ko dikhane layak paigham). Entry bin mein hi rehti hai.
class RecycleBinException implements Exception {
  final String message;
  const RecycleBinException(this.message);
  @override
  String toString() => message;
}

class RecycleBinEntry {
  final int id;
  final String kind;
  final String refKey;
  final String title;
  final String subtitle;
  final double amount;
  final String deletedBy;
  final int deletedAt;
  final String dataJson;

  const RecycleBinEntry({
    required this.id,
    required this.kind,
    required this.refKey,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.deletedBy,
    required this.deletedAt,
    required this.dataJson,
  });

  factory RecycleBinEntry.fromMap(Map<String, Object?> m) => RecycleBinEntry(
        id: (m['id'] as num).toInt(),
        kind: (m['kind'] as String?) ?? '',
        refKey: (m['refKey'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        subtitle: (m['subtitle'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0.0,
        deletedBy: (m['deletedBy'] as String?) ?? '',
        deletedAt: (m['deletedAt'] as num?)?.toInt() ?? 0,
        dataJson: (m['dataJson'] as String?) ?? '{}',
      );

  Map<String, List<Map<String, Object?>>> get rows => decodeBinRows(dataJson);
}

/// Recycle Bin: delete par poora snapshot (record + uske saath hatne wali rows) bin mein; admin restore par
/// record, stock / balance / cash sab wapas aur cloud ko `_restore` upsert (tombstone hat jata hai).
///
/// Snapshot delete wali hi transaction mein [record] se likha jata hai (delete fail => snapshot bhi nahi).
class RecycleBinRepository {
  RecycleBinRepository._();
  static final RecycleBinRepository instance = RecycleBinRepository._();

  static const kindSale = 'sale';
  static const kindPurchase = 'purchase';
  static const kindExpense = 'expense';
  static const kindPayment = 'payment';
  static const kindCustomer = 'customer';
  static const kindSupplier = 'supplier';
  static const kindProduct = 'product';
  static const kindWorker = 'worker';

  /// Delete hooks yahan snapshot likhte hain (apni delete transaction ke andar).
  static Future<void> record(
    DatabaseExecutor ex, {
    required String kind,
    required String refKey,
    required String title,
    String subtitle = '',
    double amount = 0,
    required Map<String, List<Map<String, Object?>>> rows,
  }) async {
    await ex.insert('recycle_bin', {
      'kind': kind,
      'refKey': refKey,
      'title': title,
      'subtitle': subtitle,
      'amount': amount,
      'deletedBy': Session.username ?? 'unknown',
      'deletedAt': DateTime.now().millisecondsSinceEpoch,
      'dataJson': encodeBinRows(rows),
    });
  }

  void _requireAdmin() {
    if (!Session.isAdmin) throw StateError('Sirf Admin ye action kar sakta hai');
  }

  Future<List<RecycleBinEntry>> list({String? kind}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'recycle_bin',
      where: kind == null ? null : 'kind = ?',
      whereArgs: kind == null ? null : [kind],
      orderBy: 'deletedAt DESC, id DESC',
    );
    return rows.map(RecycleBinEntry.fromMap).toList();
  }

  Future<int> count() async {
    final db = await AppDatabase.instance.database;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM recycle_bin')) ?? 0;
  }

  /// Hamesha ke liye hatao (admin).
  Future<void> purge(int id) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    await db.delete('recycle_bin', where: 'id = ?', whereArgs: [id]);
  }

  /// Poora bin khali (admin).
  Future<void> purgeAll() async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    await db.delete('recycle_bin');
  }

  // ------------------------------------------------------------------ restore

  Future<void> restore(int id) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    final found = await db.query('recycle_bin', where: 'id = ?', whereArgs: [id], limit: 1);
    if (found.isEmpty) throw const RecycleBinException('Ye entry bin mein nahi mili');
    final entry = RecycleBinEntry.fromMap(found.first);
    final data = entry.rows;
    if (data.isEmpty) throw const RecycleBinException('Is entry ka data kharab hai, restore nahi ho sakta');

    try {
      // Zone nishan: is dauran queue hone wale har upsert par `_restore` lagta hai (SyncQueueHelper.enqueue).
      await runZoned(
        () => db.transaction((txn) async {
          switch (entry.kind) {
            case kindSale:
              await _restoreSale(txn, data);
              break;
            case kindPurchase:
              await _restorePurchase(txn, data);
              break;
            case kindExpense:
              await _restoreExpense(txn, data);
              break;
            case kindPayment:
              await _restorePayment(txn, data);
              break;
            case kindCustomer:
              await _restoreCustomer(txn, data);
              break;
            case kindSupplier:
              await _restoreSupplier(txn, data);
              break;
            case kindProduct:
              await _restoreProduct(txn, data);
              break;
            case kindWorker:
              await _restoreWorker(txn, data);
              break;
            default:
              throw RecycleBinException('Is qism (${entry.kind}) ka restore abhi mumkin nahi');
          }
          await txn.delete('recycle_bin', where: 'id = ?', whereArgs: [id]);
        }),
        zoneValues: {SyncQueueHelper.kRestoreZoneKey: true},
      );
    } on DatabaseException catch (e) {
      // Transaction roll back ho chuki; entry bin mein hi hai.
      throw RecycleBinException('Restore nahi ho saka (record pehle se maujood ya data mismatch): $e');
    }

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
    await SaleRepository.instance.refreshAfterRestore();
  }

  // ---- helpers

  List<Map<String, Object?>> _rows(Map<String, List<Map<String, Object?>>> d, String t) => d[t] ?? const [];

  Map<String, Object?>? _meta(Map<String, List<Map<String, Object?>>> d) {
    final m = _rows(d, 'meta');
    return m.isEmpty ? null : m.first;
  }

  Future<void> _assertAbsent(DatabaseExecutor ex, String table, String col, Object? value, String what) async {
    if (value == null) return;
    final r = await ex.query(table, where: '$col = ?', whereArgs: [value], limit: 1);
    if (r.isNotEmpty) throw RecycleBinException('$what pehle se maujood hai, dobara restore nahi ho sakta');
  }

  Future<void> _insertAll(DatabaseExecutor ex, String table, List<Map<String, Object?>> rows) async {
    for (final r in rows) {
      await ex.insert(table, Map<String, Object?>.from(r));
    }
  }

  Future<void> _enqueueCashRows(DatabaseExecutor ex, List<Map<String, Object?>> cash) async {
    for (final c in cash) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) await SyncQueueHelper.enqueueCashTransaction(ex, id);
    }
  }

  // ---- sale

  Future<void> _restoreSale(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final saleRows = _rows(d, 'sales');
    if (saleRows.isEmpty) throw const RecycleBinException('Bill ka data nahi mila');
    final saleMap = saleRows.first;
    final sale = Sale.fromMap(saleMap);
    await _assertAbsent(txn, 'sales', 'invoice', sale.invoice, 'Ye bill');
    final itemRows = _rows(d, 'sale_items');
    final alreadyReturned = (_meta(d)?['alreadyReturned'] as num?) == 1;

    // Pehle check: stock kam ho to kuch bhi change na ho (returned bill ka stock pehle hi wapas ja chuka).
    final need = <String, double>{};
    final names = <String, String>{};
    if (!alreadyReturned) {
      for (final r in itemRows) {
        final si = SaleItem.fromMap(r);
        final pr = await txn.query('products', where: 'barcode = ?', whereArgs: [si.barcode], limit: 1);
        if (pr.isEmpty) continue; // item delete ho chuka: sirf bill wapas aayega.
        final qty = saleItemSmallestQty(si, Product.fromMap(pr.first));
        need[si.barcode] = (need[si.barcode] ?? 0) + qty;
        names[si.barcode] = (pr.first['name'] as String?) ?? si.barcode;
      }
      final short = <String>[];
      for (final e in need.entries) {
        final have = ((await txn.query('products', columns: ['stock'], where: 'barcode = ?', whereArgs: [e.key]))
                .first['stock'] as num)
            .toDouble();
        if (have + 0.0001 < e.value) short.add('${names[e.key]} (stock $have, chahiye ${e.value})');
      }
      if (short.isNotEmpty) {
        throw RecycleBinException('Stock kam hai, bill restore nahi ho sakta: ${short.join(', ')}');
      }
    }

    await txn.insert('sales', Map<String, Object?>.from(saleMap));
    await _insertAll(txn, 'sale_items', itemRows);
    await _insertAll(txn, 'payments', _rows(d, 'payments'));
    await _insertAll(txn, 'cash_transactions', _rows(d, 'cash_transactions'));

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!alreadyReturned) {
      for (final r in itemRows) {
        final si = SaleItem.fromMap(r);
        final pr = await txn.query('products', where: 'barcode = ?', whereArgs: [si.barcode], limit: 1);
        if (pr.isEmpty) continue;
        final qty = saleItemSmallestQty(si, Product.fromMap(pr.first));
        await txn.rawUpdate(
          'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [qty, now, si.barcode],
        );
        await SyncQueueHelper.enqueueStockDelta(txn, si.barcode, -qty);
        await StockLedger.log(txn,
            barcode: si.barcode, type: MovementType.sale, signedQty: -qty, reference: sale.invoice, now: now);
      }
      final outstanding = sale.total - sale.paid;
      final cid = sale.customerId;
      if (cid != null && outstanding.abs() > 0.009) {
        final exists = await txn.query('customers', columns: ['id'], where: 'id = ?', whereArgs: [cid], limit: 1);
        if (exists.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE customers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
            [outstanding, now, cid],
          );
          await SyncQueueHelper.enqueueBalanceDelta(txn, customer: true, partyId: cid, delta: outstanding);
        }
      }
    }

    await SyncQueueHelper.enqueueSale(txn, sale.invoice);
    for (final p in _rows(d, 'payments')) {
      final pid = (p['id'] as num?)?.toInt();
      if (pid != null) await SyncQueueHelper.enqueuePayment(txn, pid);
    }
    await _enqueueCashRows(txn, _rows(d, 'cash_transactions'));
  }

  // ---- purchase

  Future<void> _restorePurchase(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final bills = _rows(d, 'purchases');
    if (bills.isEmpty) throw const RecycleBinException('Purchase ka data nahi mila');
    final purchase = Purchase.fromMap(bills.first);
    await _assertAbsent(txn, 'purchases', 'billNo', purchase.billNo, 'Ye purchase bill');
    final alreadyReturned = (_meta(d)?['alreadyReturned'] as num?) == 1;

    await txn.insert('purchases', Map<String, Object?>.from(bills.first));
    await _insertAll(txn, 'purchase_items', _rows(d, 'purchase_items'));
    await _insertAll(txn, 'payments', _rows(d, 'payments'));
    await _insertAll(txn, 'cash_transactions', _rows(d, 'cash_transactions'));

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!alreadyReturned) {
      // Delete ne jitna stock nikala tha utna wapas; cost sirf tab pehle wali jab us ke baad badli na ho.
      for (final fx in _rows(d, 'stock_effects')) {
        final barcode = fx['barcode'] as String;
        final removed = (fx['removed'] as num?)?.toDouble() ?? 0.0;
        final costBefore = (fx['costBefore'] as num?)?.toDouble();
        final costAfter = (fx['costAfter'] as num?)?.toDouble();
        final pr = await txn.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
        if (pr.isEmpty) continue; // item delete ho chuka: sirf bill wapas aayega.
        final curCost = (pr.first['cost'] as num?)?.toDouble() ?? 0.0;
        final restoreCost = costBefore != null && costAfter != null && (curCost - costAfter).abs() < 0.0001;
        await txn.rawUpdate(
          restoreCost
              ? 'UPDATE products SET stock = stock + ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?'
              : 'UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          restoreCost ? [removed, costBefore, now, barcode] : [removed, now, barcode],
        );
        if (removed > 0) {
          await SyncQueueHelper.enqueueStockDelta(txn, barcode, removed);
          await StockLedger.log(txn,
              barcode: barcode,
              type: MovementType.purchase,
              signedQty: removed,
              reference: purchase.billNo,
              unitCost: restoreCost ? costBefore : curCost,
              now: now);
        }
        await SyncQueueHelper.enqueueProduct(txn, barcode);
      }
      final outstanding = purchase.total - purchase.paid;
      final sid = purchase.supplierId;
      if (sid != null && outstanding.abs() > 0.009) {
        final exists = await txn.query('suppliers', columns: ['id'], where: 'id = ?', whereArgs: [sid], limit: 1);
        if (exists.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE suppliers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
            [outstanding, now, sid],
          );
          await SyncQueueHelper.enqueueBalanceDelta(txn, customer: false, partyId: sid, delta: outstanding);
        }
      }
    }

    await SyncQueueHelper.enqueuePurchase(txn, purchase.billNo);
    for (final p in _rows(d, 'payments')) {
      final pid = (p['id'] as num?)?.toInt();
      if (pid != null) await SyncQueueHelper.enqueuePayment(txn, pid);
    }
    await _enqueueCashRows(txn, _rows(d, 'cash_transactions'));
  }

  // ---- expense

  Future<void> _restoreExpense(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final ex = _rows(d, 'expenses');
    if (ex.isEmpty) throw const RecycleBinException('Kharche ka data nahi mila');
    await _assertAbsent(txn, 'expenses', 'id', ex.first['id'], 'Ye kharcha');
    await _insertAll(txn, 'expenses', ex);
    await _insertAll(txn, 'cash_transactions', _rows(d, 'cash_transactions'));
    final id = (ex.first['id'] as num?)?.toInt();
    if (id != null) await SyncQueueHelper.enqueueExpense(txn, id);
    await _enqueueCashRows(txn, _rows(d, 'cash_transactions'));
  }

  // ---- payment

  Future<void> _restorePayment(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final pays = _rows(d, 'payments');
    final meta = _meta(d);
    if (pays.isEmpty || meta == null) throw const RecycleBinException('Payment ka data nahi mila');
    for (final p in pays) {
      await _assertAbsent(txn, 'payments', 'id', p['id'], 'Ye payment');
    }
    await _insertAll(txn, 'payments', pays);
    await _insertAll(txn, 'cash_transactions', _rows(d, 'cash_transactions'));

    final isCustomer = (meta['isCustomer'] as num?) == 1;
    final partyId = (meta['partyId'] as num?)?.toInt();
    final amount = (meta['amount'] as num?)?.toDouble() ?? 0.0;
    final billRef = (meta['billReference'] as String?) ?? '';
    await PaymentRepository.instance.reapplyRestored(txn,
        isCustomer: isCustomer, partyId: partyId, amount: amount, billReference: billRef);

    for (final p in pays) {
      final pid = (p['id'] as num?)?.toInt();
      if (pid != null) await SyncQueueHelper.enqueuePayment(txn, pid);
    }
    await _enqueueCashRows(txn, _rows(d, 'cash_transactions'));
  }

  // ---- parties

  Future<void> _restoreCustomer(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final rows = _rows(d, 'customers');
    if (rows.isEmpty) throw const RecycleBinException('Customer ka data nahi mila');
    await _assertAbsent(txn, 'customers', 'id', rows.first['id'], 'Ye customer');
    await _insertAll(txn, 'customers', rows);
    final id = (rows.first['id'] as num?)?.toInt();
    if (id != null) await SyncQueueHelper.enqueueCustomer(txn, id);
  }

  Future<void> _restoreSupplier(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final rows = _rows(d, 'suppliers');
    if (rows.isEmpty) throw const RecycleBinException('Supplier ka data nahi mila');
    await _assertAbsent(txn, 'suppliers', 'id', rows.first['id'], 'Ye supplier');
    await _insertAll(txn, 'suppliers', rows);
    final id = (rows.first['id'] as num?)?.toInt();
    if (id != null) await SyncQueueHelper.enqueueSupplier(txn, id);
  }

  // ---- product

  Future<void> _restoreProduct(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final rows = _rows(d, 'products');
    if (rows.isEmpty) throw const RecycleBinException('Item ka data nahi mila');
    final barcode = rows.first['barcode'] as String;
    await _assertAbsent(txn, 'products', 'barcode', barcode, 'Ye item (barcode)');
    await _insertAll(txn, 'products', rows);
    await SyncQueueHelper.enqueueProduct(txn, barcode);
    // Cloud ka doc tombstone tha: stock ka ABSOLUTE set (naya doc "ghost" na bane, stock sahi ho).
    final stock = (rows.first['stock'] as num?)?.toDouble() ?? 0.0;
    await SyncQueueHelper.enqueue(txn, 'product', barcode, 'set_stock', {
      'stock': stock,
      'updatedAt': SyncQueueHelper.nowMs(),
      'branchId': BranchConfigStore.current,
    });
  }

  // ---- worker

  Future<void> _restoreWorker(Transaction txn, Map<String, List<Map<String, Object?>>> d) async {
    final rows = _rows(d, 'workers');
    if (rows.isEmpty) throw const RecycleBinException('Worker ka data nahi mila');
    await _assertAbsent(txn, 'workers', 'id', rows.first['id'], 'Ye worker');
    await _insertAll(txn, 'workers', rows);
    final id = (rows.first['id'] as num?)?.toInt();
    if (id == null) return;
    final att = _rows(d, 'worker_attendance');
    await _insertAll(txn, 'worker_attendance', att);
    await SyncQueueHelper.enqueueWorker(txn, id);
    for (final a in att) {
      await SyncQueueHelper.enqueueWorkerAttendance(txn, id, a['day'] as String);
    }
  }
}
