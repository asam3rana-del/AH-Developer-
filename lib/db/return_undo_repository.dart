import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/stock_movement.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'product_repository.dart';
import 'stock_ledger.dart';

/// Return "undo": galti se return ho jaye to wapas pehli halat par le aana.
///
/// Tareeqa (mehfooz): return ke waqt bill ki POORI halat ka snapshot (bill row, items, payments, cash rows,
/// mutasir products ka stock/cost delta, party ka balance delta) `return_undo` table mein JSON ki soorat
/// mehfooz hota hai (sirf isi device par, cloud par nahi). Undo par:
///  * bill, items, payments, cash rows HOO-BA-HOO wapas,
///  * stock aur balance par return ne jo delta lagaya tha uska ULTA,
///  * product cost snapshot wali value par,
///  * is return ki `returns` rows aur cash reversal hata diye jate hain,
///  * aur sab cloud par bhi sync ho jata hai (dono phone).
///
/// Sirf FULL return (poora bill 'returned') par undo milta hai — tab items salamat hote hain. Undo foran
/// karna behtar hai (naye sale/purchase se pehle).
class ReturnUndoRepository {
  ReturnUndoRepository._();
  static final ReturnUndoRepository instance = ReturnUndoRepository._();

  static const createSql = '''
      CREATE TABLE IF NOT EXISTS return_undo (
        ref TEXT NOT NULL,
        type TEXT NOT NULL,
        payload TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        PRIMARY KEY (ref, type)
      )
  ''';

  // -------------------------------------------------------- capture (return ke andar)

  /// Return ki mutation se PEHLE bulao. Bill + items + payments + cash + products (pre stock/cost) + party balance.
  static Future<ReturnUndoPre> capture(DatabaseExecutor txn, {required String type, required String ref}) async {
    final isSale = type == 'sale';
    final billTable = isSale ? 'sales' : 'purchases';
    final itemTable = isSale ? 'sale_items' : 'purchase_items';
    final refCol = isSale ? 'invoice' : 'billNo';

    final billRows = await txn.query(billTable, where: '$refCol = ?', whereArgs: [ref], limit: 1);
    final bill = billRows.isEmpty ? <String, Object?>{} : Map<String, Object?>.from(billRows.first);
    final items = [
      for (final r in await txn.query(itemTable, where: '$refCol = ?', whereArgs: [ref])) Map<String, Object?>.from(r),
    ];
    final payments = [
      for (final r in await txn.query('payments', where: 'reference = ? OR billReference = ?', whereArgs: [ref, ref]))
        Map<String, Object?>.from(r),
    ];
    // Cash rows: bill ki apni, linked payments ki apni (reference = payment ka reference), aur return/ reversal
    // ki rows (reference = 'return:<bill-ya-payment-ref>'). Sab ko ek saath capture/restore karna zaroori hai
    // warna undo ke baad cash book mein duplicate / orphan entries reh jati hain.
    final cashRefs = <String>{ref, 'return:$ref'};
    for (final pay in payments) {
      final pref = (pay['reference'] as String?) ?? '';
      if (pref.isNotEmpty) {
        cashRefs.add(pref);
        cashRefs.add('return:$pref');
      }
    }
    final cash = <Map<String, Object?>>[];
    for (final cr in cashRefs) {
      for (final r in await txn.query('cash_transactions', where: 'reference = ?', whereArgs: [cr])) {
        cash.add(Map<String, Object?>.from(r));
      }
    }

    final barcodes = {for (final it in items) (it['barcode'] as String?) ?? ''}..remove('');
    final preStock = <String, double>{};
    final preCost = <String, double>{};
    for (final bc in barcodes) {
      final pr = await txn.query('products', columns: ['stock', 'cost'], where: 'barcode = ?', whereArgs: [bc], limit: 1);
      if (pr.isNotEmpty) {
        preStock[bc] = ((pr.first['stock'] as num?) ?? 0).toDouble();
        preCost[bc] = ((pr.first['cost'] as num?) ?? 0).toDouble();
      }
    }

    final partyId = isSale ? bill['customerId'] as int? : bill['supplierId'] as int?;
    var balBefore = 0.0;
    if (partyId != null) {
      final pt = isSale ? 'customers' : 'suppliers';
      final br = await txn.query(pt, columns: ['balance'], where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (br.isNotEmpty) balBefore = ((br.first['balance'] as num?) ?? 0).toDouble();
    }

    return ReturnUndoPre._(
      type: type,
      ref: ref,
      isSale: isSale,
      bill: bill,
      items: items,
      payments: payments,
      cash: cash,
      preStock: preStock,
      preCost: preCost,
      partyId: partyId,
      balanceBefore: balBefore,
      at: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Return ki saari mutation ke BAAD bulao. Deltas (stock, balance) nikaal kar snapshot likhta hai.
  static Future<void> commit(DatabaseExecutor txn, ReturnUndoPre pre) async {
    if (pre.bill.isEmpty) return; // kuch snapshot karne ko nahi
    final products = <Map<String, Object?>>[];
    for (final bc in pre.preStock.keys) {
      final pr = await txn.query('products', columns: ['stock', 'cost'], where: 'barcode = ?', whereArgs: [bc], limit: 1);
      final postStock = pr.isEmpty ? pre.preStock[bc]! : ((pr.first['stock'] as num?) ?? 0).toDouble();
      final postCost = pr.isEmpty ? (pre.preCost[bc] ?? 0) : ((pr.first['cost'] as num?) ?? 0).toDouble();
      products.add({
        'barcode': bc,
        'stockDelta': postStock - pre.preStock[bc]!, // return ne stock itna badla (sale: +, purchase: -)
        'costBefore': pre.preCost[bc] ?? 0,
        'costAfter': postCost, // undo cost sirf tab restore kare jab beech mein kisi aur ne cost na badli ho
      });
    }

    var balAfter = pre.balanceBefore;
    if (pre.partyId != null) {
      final pt = pre.isSale ? 'customers' : 'suppliers';
      final br = await txn.query(pt, columns: ['balance'], where: 'id = ?', whereArgs: [pre.partyId], limit: 1);
      if (br.isNotEmpty) balAfter = ((br.first['balance'] as num?) ?? 0).toDouble();
    }

    final payload = {
      'type': pre.type,
      'ref': pre.ref,
      'at': pre.at,
      'bill': pre.bill,
      'items': pre.items,
      'payments': pre.payments,
      'cash': pre.cash,
      'party': {
        'isCustomer': pre.isSale,
        'id': pre.partyId,
        'balanceDelta': balAfter - pre.balanceBefore,
      },
      'products': products,
    };

    await txn.insert(
      'return_undo',
      {'ref': pre.ref, 'type': pre.type, 'payload': jsonEncode(payload), 'createdAt': pre.at},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // -------------------------------------------------------- undo

  /// Is bill ka undo mojood hai?
  Future<bool> hasUndo(String ref, String type) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('return_undo', where: 'ref = ? AND type = ?', whereArgs: [ref, type], limit: 1);
    return r.isNotEmpty;
  }

  /// Is type ke jin bills ka undo mojood hai unke refs (history screen list ke liye).
  Future<Set<String>> undoableRefs(String type) async {
    final db = await AppDatabase.instance.database;
    final r = await db.query('return_undo', columns: ['ref'], where: 'type = ?', whereArgs: [type]);
    return {for (final row in r) row['ref'] as String};
  }

  /// Return wapas. true = ho gaya.
  Future<bool> undo(String ref, String type) async {
    final db = await AppDatabase.instance.database;
    final snap = await db.query('return_undo', where: 'ref = ? AND type = ?', whereArgs: [ref, type], limit: 1);
    if (snap.isEmpty) return false;
    final p = jsonDecode(snap.first['payload'] as String) as Map<String, Object?>;
    final isSale = (p['type'] as String?) == 'sale';
    final billTable = isSale ? 'sales' : 'purchases';
    final itemTable = isSale ? 'sale_items' : 'purchase_items';
    final refCol = isSale ? 'invoice' : 'billNo';
    final at = (p['at'] as num?)?.toInt() ?? 0;

    await db.transaction((txn) async {
      // 1. Is return ki `returns` rows (snapshot ke waqt ya baad banin) hatao — cloud par bhi.
      final retRows = await txn.query('returns',
          columns: ['id'], where: 'reference = ? AND createdAt >= ?', whereArgs: [ref, at]);
      for (final r in retRows) {
        await SyncQueueHelper.enqueueDelete(txn, 'return', '${r['id']}');
      }
      await txn.delete('returns', where: 'reference = ? AND createdAt >= ?', whereArgs: [ref, at]);

      // 2. Payments: maujooda is bill ke hatao (deletePaymentRow khud DB se hataati + cloud delete), phir snapshot wale wapas.
      final curPays = await txn.query('payments', where: 'reference = ? OR billReference = ?', whereArgs: [ref, ref]);
      for (final pay in curPays) {
        await SyncQueueHelper.deletePaymentRow(txn, Map<String, Object?>.from(pay));
      }
      for (final pay in (p['payments'] as List).cast<Map<String, Object?>>()) {
        final m = Map<String, Object?>.from(pay)..['dirty'] = 1;
        await txn.insert('payments', m, conflictAlgorithm: ConflictAlgorithm.replace);
        final id = m['id'];
        if (id is int) await SyncQueueHelper.enqueuePayment(txn, id);
      }

      // 3. Cash rows: bill + linked payments + reversal (sab references) ke maujooda rows hatao, phir snapshot
      //    wale hoo-ba-hoo wapas. Warna linked-payment ki cash duplicate / orphan reh jati.
      final snapCash = (p['cash'] as List).cast<Map<String, Object?>>();
      final cashRefs = <String>{ref, 'return:$ref'};
      for (final c in snapCash) {
        final cref = (c['reference'] as String?) ?? '';
        if (cref.isNotEmpty) cashRefs.add(cref);
      }
      for (final cr in cashRefs) {
        await SyncQueueHelper.deleteCashTransactionsByReference(txn, cr);
      }
      for (final c in snapCash) {
        final m = Map<String, Object?>.from(c)..['dirty'] = 1;
        await txn.insert('cash_transactions', m, conflictAlgorithm: ConflictAlgorithm.replace);
        final id = m['id'];
        if (id is int) await SyncQueueHelper.enqueueCashTransaction(txn, id);
      }

      // 4. Bill row + items hoo-ba-hoo wapas.
      await txn.delete(itemTable, where: '$refCol = ?', whereArgs: [ref]);
      for (final it in (p['items'] as List).cast<Map<String, Object?>>()) {
        await txn.insert(itemTable, Map<String, Object?>.from(it), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final bill = Map<String, Object?>.from(p['bill'] as Map)..['dirty'] = 1;
      await txn.delete(billTable, where: '$refCol = ?', whereArgs: [ref]);
      await txn.insert(billTable, bill, conflictAlgorithm: ConflictAlgorithm.replace);
      if (isSale) {
        await SyncQueueHelper.enqueueSale(txn, ref);
      } else {
        await SyncQueueHelper.enqueuePurchase(txn, ref);
      }

      // 5. Products: stock par return ke delta ka ULTA (+ stock_movements ledger), cost mehfoot tareeqe se.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final pr in (p['products'] as List).cast<Map<String, Object?>>()) {
        final bc = pr['barcode'] as String;
        final stockDelta = ((pr['stockDelta'] as num?) ?? 0).toDouble();
        final costBefore = ((pr['costBefore'] as num?) ?? 0).toDouble();
        final costAfter = (pr['costAfter'] as num?)?.toDouble();
        // Cost sirf tab restore karo jab return ke baad se cost badli NAHI (warna beech ki nayi purchase ki
        // cost mit jati). costAfter purane snapshot mein na ho (purani snapshot), to purana rawaiya: restore.
        final cur = await txn.query('products', columns: ['cost'], where: 'barcode = ?', whereArgs: [bc], limit: 1);
        final curCost = cur.isEmpty ? null : ((cur.first['cost'] as num?) ?? 0).toDouble();
        final restoreCost = costAfter == null || curCost == null || (curCost - costAfter).abs() < 0.01;
        if (restoreCost) {
          await txn.rawUpdate('UPDATE products SET stock = stock - ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
              [stockDelta, costBefore, nowMs, bc]);
        } else {
          // Beech mein cost badal chuki — sirf stock ulta karo, cost ko haath na lagao.
          await txn.rawUpdate('UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
              [stockDelta, nowMs, bc]);
        }
        if (stockDelta != 0) {
          await SyncQueueHelper.enqueueStockDelta(txn, bc, -stockDelta);
          // stock_movements ledger bhi, taake product.stock aur ledger milते rahein (RETURN_UNDO).
          await StockLedger.log(txn,
              barcode: bc, type: MovementType.returnUndo, signedQty: -stockDelta, reference: ref, now: nowMs);
        }
        await SyncQueueHelper.enqueueProduct(txn, bc);
      }

      // 6. Party balance par return ke delta ka ULTA.
      final party = p['party'] as Map<String, Object?>;
      final partyId = party['id'] as int?;
      final balanceDelta = ((party['balanceDelta'] as num?) ?? 0).toDouble();
      if (partyId != null && balanceDelta != 0) {
        final isCustomer = party['isCustomer'] == true;
        final pt = isCustomer ? 'customers' : 'suppliers';
        await txn.rawUpdate(
          'UPDATE $pt SET balance = balance - ?, dirty = 1, updatedAt = ? WHERE id = ?',
          [balanceDelta, DateTime.now().millisecondsSinceEpoch, partyId],
        );
        await SyncQueueHelper.enqueueBalanceDelta(txn, customer: isCustomer, partyId: partyId, delta: -balanceDelta);
      }

      // 7. Snapshot khatam.
      await txn.delete('return_undo', where: 'ref = ? AND type = ?', whereArgs: [ref, type]);
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    return true;
  }
}

/// Return ke andar capture ka natija (commit tak sambhal kar rakho).
class ReturnUndoPre {
  final String type;
  final String ref;
  final bool isSale;
  final Map<String, Object?> bill;
  final List<Map<String, Object?>> items;
  final List<Map<String, Object?>> payments;
  final List<Map<String, Object?>> cash;
  final Map<String, double> preStock;
  final Map<String, double> preCost;
  final int? partyId;
  final double balanceBefore;
  final int at;

  const ReturnUndoPre._({
    required this.type,
    required this.ref,
    required this.isSale,
    required this.bill,
    required this.items,
    required this.payments,
    required this.cash,
    required this.preStock,
    required this.preCost,
    required this.partyId,
    required this.balanceBefore,
    required this.at,
  });
}
