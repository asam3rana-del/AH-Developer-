
import 'package:sqflite/sqflite.dart';

import '../db/maintenance_sync.dart';
import 'sync_queue_dao.dart';
import 'sync_queue_helper.dart';
import 'sync_types.dart';

/// Kotlin `SyncApi.applyServerChanges()` ka HISSA 2 — sales, purchases, expenses, payments,
/// cashTransactions, units, categories, zakatYears, zakatPayments, returns, stockMovements,
/// shellCustomers, shellTransactions, shopEmptyShellLogs, appSettings, cashRegisters.
/// (Hissa 1 — customers/suppliers/products/users — `sync_apply.dart` mein.)
///
/// Tarteeb Kotlin jaisi hi: parent pehle (zakat year -> zakat payment, shell customer -> shell txn,
/// customers/suppliers (hissa 1) -> sales/purchases/payments).
///
/// FARQ (Flutter schema): sales/purchases/sale_items/purchase_items par `saleUid/lineUid/purchaseUid`
/// columns nahi (Kotlin ke P2 uid) — pull unhein ignore karta hai. payments par `partyServerId` column
/// nahi — party pull par `partyServerId` se local id resolve hoti hai, phir sirf `partyId` mehfooz.
/// Purchases par Flutter ke extra columns (`dueDate`, `supplierInvoiceNo`) server doc mein hon to
/// wahi, warna local wali qeemat barqarar (Kotlin pull unhein jaanta hi nahi tha).

double? _d(Object? v) => v is num ? v.toDouble() : null;
int? _i(Object? v) => v is num ? v.toInt() : null;
String? _s(Object? v) => v is String ? v : null;
double _dbl(Object? v) => v is num ? v.toDouble() : 0.0;
String _f2(num v) => v.toStringAsFixed(2);

Future<Map<String, Object?>?> _findBy(
    DatabaseExecutor db, String table, String col, Object value) async {
  final rows = await db.query(table, where: '$col = ?', whereArgs: [value], limit: 1);
  return rows.isEmpty ? null : rows.first;
}

Future<void> _conflict(DatabaseExecutor db, String reference, String details) =>
    logMaintenanceAudit(
      db,
      username: 'sync',
      action: 'sync_conflict',
      reference: reference,
      details: details,
    );

/// Hissa 2 ki sab collections — ek hi transaction (`db` = txn) mein, Kotlin ki tarteeb par.
Future<void> applyRestOfServerChanges(
  DatabaseExecutor db,
  PullResult c, {
  required int Function() nowMs,
}) async {
  await applySales(db, c.sales, nowMs: nowMs);
  await applyPurchases(db, c.purchases, nowMs: nowMs);
  await applyExpenses(db, c.expenses, nowMs: nowMs);
  await applyPayments(db, c.payments, nowMs: nowMs);
  await applyCashTransactions(db, c.cashTransactions, nowMs: nowMs);
  await applyUnits(db, c.units);
  await applyCategories(db, c.categories);
  await applyZakatYears(db, c.zakatYears, nowMs: nowMs);
  await applyZakatPayments(db, c.zakatPayments, nowMs: nowMs);
  await applyReturns(db, c.returns, nowMs: nowMs);
  await applyStockMovements(db, c.stockMovements, nowMs: nowMs);
  await applyShellCustomers(db, c.shellCustomers, nowMs: nowMs);
  await applyShellTransactions(db, c.shellTransactions, nowMs: nowMs);
  await applyShopEmptyShellLogs(db, c.shopEmptyShellLogs, nowMs: nowMs);
  await applyAppSettings(db, c.appSettings);
  await applyCashRegisters(db, c.cashRegisters);
}

// -------------------------------------------------------------------- sales

Future<void> applySales(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    final invoice = _s(row['invoice']);
    if (invoice == null) continue;
    final entityId = 'sale:$invoice';
    final pendingEdit = await q.pendingCountForEntity('sale', entityId) > 0;

    // Kotlin FIX: pending local edit ko doosre device ka delete chupke se na khaye — conflict audit.
    if (row['_deleted'] == true) {
      if (pendingEdit) {
        final local = await _findBy(db, 'sales', 'invoice', invoice);
        if (local != null) {
          await _conflict(
            db,
            'sale:$invoice',
            'A delete for this sale arrived from another device while your unsynced edit '
            '(Rs ${_f2(_dbl(local['total']))}, paid Rs ${_f2(_dbl(local['paid']))}) was still pending — '
            'kept your local copy instead of deleting it. Check this sale and delete it yourself if the delete was correct.',
          );
        }
        continue;
      }
      await db.delete('sale_items', where: 'invoice = ?', whereArgs: [invoice]);
      await db.delete('sales', where: 'invoice = ?', whereArgs: [invoice]);
      continue;
    }

    // Kotlin FIX (name/edit revert): is device ki anpushed edit ko purani server copy se overwrite na karo.
    if (pendingEdit) {
      final local = await _findBy(db, 'sales', 'invoice', invoice);
      final remoteTotal = _d(row['total']) ?? 0.0;
      final remotePaid = _d(row['paid']) ?? 0.0;
      if (local != null &&
          ((_dbl(local['total']) - remoteTotal).abs() > 0.009 ||
              (_dbl(local['paid']) - remotePaid).abs() > 0.009)) {
        await _conflict(
          db,
          'sale:$invoice',
          'Your unsynced edit (Rs ${_f2(_dbl(local['total']))}, paid Rs ${_f2(_dbl(local['paid']))}) is still pending — '
          'an update from another device (Rs ${_f2(remoteTotal)}, paid Rs ${_f2(remotePaid)}) was NOT applied. '
          'Once your edit pushes, re-check this sale against the other device.',
        );
      }
      continue;
    }

    final customerServerId = _s(row['customerServerId']);
    final localCustomerId = customerServerId == null
        ? null
        : (await _findBy(db, 'customers', 'serverId', customerServerId))?['id'];
    final existing = await _findBy(db, 'sales', 'invoice', invoice);
    final now = nowMs();
    await db.insert(
      'sales',
      {
        'invoice': invoice,
        'customerId': localCustomerId,
        'customerServerId': customerServerId,
        'subtotal': _d(row['subtotal']) ?? 0.0,
        'discount': _d(row['discount']) ?? 0.0,
        'tax': 0.0,
        'total': _d(row['total']) ?? 0.0,
        'paid': _d(row['paid']) ?? 0.0,
        'paymentMethod': _s(row['paymentMethod']) ?? 'cash',
        'saleType': _s(row['saleType']) ?? 'retail',
        'createdAt': _i(row['createdAt']) ?? now,
        'status': _s(row['status']) ?? 'active',
        'updatedAt': _i(row['updatedAt']) ?? now,
        'dirty': 0,
        // Reminder date kisi bhi device par set ho sakti hai; server doc mein na ho to local barqarar.
        'dueDate': _i(row['dueDate']) ?? _i(existing?['dueDate']) ?? 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final itemRows = row['items'];
    if (itemRows is List && itemRows.isNotEmpty) {
      final items = <Map<String, Object?>>[];
      for (final im in itemRows) {
        if (im is! Map) continue;
        final barcode = _s(im['barcode']);
        if (barcode == null) continue;
        items.add({
          'invoice': invoice,
          'barcode': barcode,
          'product': _s(im['product']) ?? '',
          'qty': _d(im['qty']) ?? 0.0,
          'unit': _s(im['unit']) ?? '',
          'unitPrice': _d(im['unitPrice']) ?? 0.0,
          'cost': _d(im['cost']) ?? 0.0,
          'amount': _d(im['amount']) ?? 0.0,
          'conversionFactor': _d(im['conversionFactor']) ?? 0.0,
        });
      }
      if (items.isNotEmpty) {
        await db.delete('sale_items', where: 'invoice = ?', whereArgs: [invoice]);
        for (final it in items) {
          await db.insert('sale_items', it);
        }
      }
    }
  }
}

// ---------------------------------------------------------------- purchases

Future<void> applyPurchases(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    final billNo = _s(row['billNo']);
    if (billNo == null) continue;
    final entityId = 'purchase:$billNo';
    final pendingEdit = await q.pendingCountForEntity('purchase', entityId) > 0;

    if (row['_deleted'] == true) {
      if (pendingEdit) {
        final local = await _findBy(db, 'purchases', 'billNo', billNo);
        if (local != null) {
          await _conflict(
            db,
            'purchase:$billNo',
            'A delete for this purchase arrived from another device while your unsynced edit '
            '(Rs ${_f2(_dbl(local['total']))}, paid Rs ${_f2(_dbl(local['paid']))}) was still pending — '
            'kept your local copy instead of deleting it. Check this bill and delete it yourself if the delete was correct.',
          );
        }
        continue;
      }
      await db.delete('purchase_items', where: 'billNo = ?', whereArgs: [billNo]);
      await db.delete('purchases', where: 'billNo = ?', whereArgs: [billNo]);
      continue;
    }

    if (pendingEdit) {
      final local = await _findBy(db, 'purchases', 'billNo', billNo);
      final remoteTotal = _d(row['total']) ?? 0.0;
      final remotePaid = _d(row['paid']) ?? 0.0;
      if (local != null &&
          ((_dbl(local['total']) - remoteTotal).abs() > 0.009 ||
              (_dbl(local['paid']) - remotePaid).abs() > 0.009)) {
        await _conflict(
          db,
          'purchase:$billNo',
          'Your unsynced edit (Rs ${_f2(_dbl(local['total']))}, paid Rs ${_f2(_dbl(local['paid']))}) is still pending — '
          'an update from another device (Rs ${_f2(remoteTotal)}, paid Rs ${_f2(remotePaid)}) was NOT applied. '
          'Once your edit pushes, re-check this bill against the other device.',
        );
      }
      continue;
    }

    final supplierServerId = _s(row['supplierServerId']);
    final localSupplierId = supplierServerId == null
        ? null
        : (await _findBy(db, 'suppliers', 'serverId', supplierServerId))?['id'];
    final existing = await _findBy(db, 'purchases', 'billNo', billNo);
    final now = nowMs();
    await db.insert(
      'purchases',
      {
        'billNo': billNo,
        'supplierId': localSupplierId,
        'supplierServerId': supplierServerId,
        'total': _d(row['total']) ?? 0.0,
        'paid': _d(row['paid']) ?? 0.0,
        'createdAt': _i(row['createdAt']) ?? now,
        'subtotal': _d(row['subtotal']) ?? 0.0,
        'discount': _d(row['discount']) ?? 0.0,
        'status': _s(row['status']) ?? 'active',
        'updatedAt': _i(row['updatedAt']) ?? now,
        'dirty': 0,
        'dueDate': _i(row['dueDate']) ?? _i(existing?['dueDate']) ?? 0,
        'supplierInvoiceNo': _s(row['supplierInvoiceNo']) ?? _s(existing?['supplierInvoiceNo']) ?? '',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final itemRows = row['items'];
    if (itemRows is List && itemRows.isNotEmpty) {
      final items = <Map<String, Object?>>[];
      for (final im in itemRows) {
        if (im is! Map) continue;
        final barcode = _s(im['barcode']);
        if (barcode == null) continue;
        items.add({
          'billNo': billNo,
          'barcode': barcode,
          'qty': _d(im['qty']) ?? 0.0,
          'unitCost': _d(im['unitCost']) ?? 0.0,
          'amount': _d(im['amount']) ?? 0.0,
          'unit': _s(im['unit']) ?? '',
          'conversionFactor': _d(im['conversionFactor']) ?? 0.0,
          // Kotlin FIX: item naam / retail-wholesale rate ka apna snapshot bhi neeche aata hai.
          'itemName': _s(im['itemName']) ?? '',
          'retailRate': _d(im['retailRate']) ?? 0.0,
          'wholesaleRate': _d(im['wholesaleRate']) ?? 0.0,
        });
      }
      if (items.isNotEmpty) {
        await db.delete('purchase_items', where: 'billNo = ?', whereArgs: [billNo]);
        for (final it in items) {
          await db.insert('purchase_items', it);
        }
      }
    }
  }
}

// ----------------------------------------------------------------- expenses

Future<void> applyExpenses(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (row['_deleted'] == true) {
      await db.delete('expenses', where: 'serverId = ?', whereArgs: [serverId]);
      continue;
    }
    final category = _s(row['category']);
    if (category == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'category': category,
      'description': _s(row['description']) ?? '',
      'amount': _d(row['amount']) ?? 0.0,
      // Purani push mein "method" nahi => 'cash' (column ka bhi default yahi).
      'method': _s(row['method']) ?? 'cash',
      'createdAt': createdAt,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'expenses', 'serverId', serverId);
    if (existing != null) {
      await db.update('expenses', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('expenses', {...values, 'serverId': serverId});
    }
  }
}

// ----------------------------------------------------------------- payments

Future<void> applyPayments(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (row['_deleted'] == true) {
      await db.delete('payments', where: 'serverId = ?', whereArgs: [serverId]);
      continue;
    }
    final reference = _s(row['reference']);
    if (reference == null) continue;
    final partyType = _s(row['partyType']) ?? '';
    final rawPartyId = _i(row['partyId']);
    final psid = _s(row['partyServerId']);
    final partyServerId = (psid != null && psid.trim().isNotEmpty) ? psid : null;
    // Kotlin CRITICAL FIX: doosre device ka local id yahan ki kisi aur party ka ho sakta hai — portable
    // partyServerId se sahi local id dhoondo. Sirf purane (partyServerId-less) docs par raw id.
    int? partyId;
    if (partyServerId != null) {
      final table = partyType == 'customer'
          ? 'customers'
          : partyType == 'supplier'
              ? 'suppliers'
              : null;
      partyId = table == null ? null : (await _findBy(db, table, 'serverId', partyServerId))?['id'] as int?;
    } else {
      partyId = rawPartyId;
    }
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'reference': reference,
      'partyType': partyType,
      'partyId': partyId,
      'partyServerId': partyServerId,
      'amount': _d(row['amount']) ?? 0.0,
      'method': _s(row['method']) ?? '',
      'note': _s(row['note']) ?? '',
      'billReference': _s(row['billReference']) ?? '',
      'createdAt': createdAt,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'payments', 'serverId', serverId);
    if (existing != null) {
      await db.update('payments', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('payments', {...values, 'serverId': serverId});
    }
  }
}

// --------------------------------------------------------- cash transactions

Future<void> applyCashTransactions(DatabaseExecutor db, List<SyncDoc> rows,
    {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (row['_deleted'] == true) {
      await db.delete('cash_transactions', where: 'serverId = ?', whereArgs: [serverId]);
      continue;
    }
    final type = _s(row['type']);
    if (type == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'type': type,
      'method': _s(row['method']) ?? '',
      'amount': _d(row['amount']) ?? 0.0,
      'reason': _s(row['reason']) ?? '',
      'reference': _s(row['reference']) ?? '',
      'createdAt': createdAt,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'cash_transactions', 'serverId', serverId);
    if (existing != null) {
      await db.update('cash_transactions', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('cash_transactions', {...values, 'serverId': serverId});
    }
  }
}

// ------------------------------------------------------ units / categories

/// Naam hi key hai — insert-if-missing / delete (aur koi field merge nahi).
Future<void> applyUnits(DatabaseExecutor db, List<SyncDoc> rows) async {
  for (final row in rows) {
    final name = _s(row['name']);
    if (name == null) continue;
    if (row['_deleted'] == true) {
      await db.delete('units', where: 'name = ?', whereArgs: [name]);
      continue;
    }
    await db.insert('units', {'name': name}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

Future<void> applyCategories(DatabaseExecutor db, List<SyncDoc> rows) async {
  for (final row in rows) {
    final name = _s(row['name']);
    if (name == null) continue;
    if (row['_deleted'] == true) {
      await db.delete('categories', where: 'name = ?', whereArgs: [name]);
      continue;
    }
    await db.insert('categories', {'name': name}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

// ------------------------------------------------------------------- zakat

/// Zakat years payments se PEHLE (parent local mein hona chahiye). Kotlin jaisa: tombstone par kuch nahi
/// (UI se year kabhi delete nahi hota).
Future<void> applyZakatYears(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (row['_deleted'] == true) continue;
    final startDate = _i(row['startDate']);
    final endDate = _i(row['endDate']);
    if (startDate == null || endDate == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'startDate': startDate,
      'endDate': endDate,
      'assetsSnapshot': _d(row['assetsSnapshot']) ?? 0.0,
      'totalPayable': _d(row['totalPayable']) ?? 0.0,
      // Purane server doc (currency/calendar se pehle) => Rs / islamic.
      'currency': _s(row['currency']) ?? 'Rs',
      'calendarType': _s(row['calendarType']) ?? 'islamic',
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'zakat_years', 'serverId', serverId);
    if (existing != null) {
      await db.update('zakat_years', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('zakat_years', {...values, 'createdAt': createdAt, 'serverId': serverId});
    }
  }
}

Future<void> applyZakatPayments(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (row['_deleted'] == true) continue; // UI se zakat payment delete nahi hoti.
    final yearServerId = _s(row['zakatYearServerId']);
    if (yearServerId == null) continue;
    // Parent year abhi is device par nahi pohanchi => skip, agli pull mein resolve hogi.
    final localYear = await _findBy(db, 'zakat_years', 'serverId', yearServerId);
    if (localYear == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'zakatYearId': localYear['id'],
      'amount': _d(row['amount']) ?? 0.0,
      'method': _s(row['method']) ?? '',
      'note': _s(row['note']) ?? '',
      'category': _s(row['category']) ?? '',
      'paymentDate': _i(row['paymentDate']) ?? createdAt,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'zakat_payments', 'serverId', serverId);
    if (existing != null) {
      await db.update('zakat_payments', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('zakat_payments', {...values, 'createdAt': createdAt, 'serverId': serverId});
    }
  }
}

// ------------------------------------------------------------------ returns

/// Append-only ledger — pehle se pulled (serverId) ho to kuch nahi.
Future<void> applyReturns(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (await _findBy(db, 'returns', 'serverId', serverId) != null) continue;
    final reference = _s(row['reference']);
    final type = _s(row['type']);
    final barcode = _s(row['barcode']);
    if (reference == null || type == null || barcode == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    await db.insert('returns', {
      'reference': reference,
      'type': type,
      'barcode': barcode,
      'qty': _d(row['qty']) ?? 0.0,
      'amount': _d(row['amount']) ?? 0.0,
      'createdAt': createdAt,
      'serverId': serverId,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    });
  }
}

// ---------------------------------------------------------- stock movements

/// Append-only ledger (Stock + Cost History dono isi table se). Kotlin FIX (duplicate PURCHASE/SALE
/// row): is device ne jo row abhi apni push se pehle likhi thi (serverId abhi nahi laga) usay "claim"
/// karo — dobara INSERT nahi.
Future<void> applyStockMovements(DatabaseExecutor db, List<SyncDoc> rows,
    {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (await _findBy(db, 'stock_movements', 'serverId', serverId) != null) continue;
    final barcode = _s(row['barcode']);
    final type = _s(row['type']);
    final qty = _d(row['qty']);
    if (barcode == null || type == null || qty == null) continue;
    final reference = _s(row['reference']) ?? '';
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final updatedAt = _i(row['updatedAt']) ?? createdAt;

    final unclaimed = await db.query(
      'stock_movements',
      where: 'serverId IS NULL AND barcode = ? AND type = ? AND reference = ? AND qty = ? AND createdAt = ?',
      whereArgs: [barcode, type, reference, qty, createdAt],
      limit: 1,
    );
    if (unclaimed.isNotEmpty) {
      await db.update(
        'stock_movements',
        {'serverId': serverId, 'updatedAt': updatedAt},
        where: 'id = ?',
        whereArgs: [unclaimed.first['id']],
      );
      continue;
    }
    await db.insert('stock_movements', {
      'barcode': barcode,
      'type': type,
      'qty': qty,
      'unit': _s(row['unit']) ?? '',
      'cost': _d(row['cost']) ?? 0.0,
      'reference': reference,
      'note': _s(row['note']) ?? '',
      'createdAt': createdAt,
      'serverId': serverId,
      'updatedAt': updatedAt,
      'dirty': 0,
    });
  }
}

// ------------------------------------------------------------ shell ledger

Future<void> applyShellCustomers(DatabaseExecutor db, List<SyncDoc> rows,
    {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    final name = _s(row['name']);
    if (serverId == null || name == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    final values = <String, Object?>{
      'name': name,
      'phone': _s(row['phone']) ?? '',
      'shellsOwed': _i(row['shellsOwed']) ?? 0,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    };
    final existing = await _findBy(db, 'shell_customers', 'serverId', serverId);
    if (existing != null) {
      await db.update('shell_customers', values, where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await db.insert('shell_customers', {...values, 'createdAt': createdAt, 'serverId': serverId});
    }
  }
}

Future<void> applyShellTransactions(DatabaseExecutor db, List<SyncDoc> rows,
    {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (await _findBy(db, 'shell_transactions', 'serverId', serverId) != null) continue;
    final customerServerId = _s(row['customerServerId']);
    if (customerServerId == null) continue;
    final localCustomer = await _findBy(db, 'shell_customers', 'serverId', customerServerId);
    if (localCustomer == null) continue;
    final type = _s(row['type']);
    final qty = _i(row['qty']);
    if (type == null || qty == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    await db.insert('shell_transactions', {
      'customerId': localCustomer['id'],
      'type': type,
      'qty': qty,
      'note': _s(row['note']) ?? '',
      'createdAt': createdAt,
      'serverId': serverId,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    });
  }
}

Future<void> applyShopEmptyShellLogs(DatabaseExecutor db, List<SyncDoc> rows,
    {required int Function() nowMs}) async {
  for (final row in rows) {
    final serverId = _s(row['serverId']);
    if (serverId == null) continue;
    if (await _findBy(db, 'shop_empty_shell_log', 'serverId', serverId) != null) continue;
    final delta = _i(row['delta']);
    final reason = _s(row['reason']);
    if (delta == null || reason == null) continue;
    final createdAt = _i(row['createdAt']) ?? nowMs();
    await db.insert('shop_empty_shell_log', {
      'delta': delta,
      'reason': reason,
      'note': _s(row['note']) ?? '',
      'createdAt': createdAt,
      'serverId': serverId,
      'updatedAt': _i(row['updatedAt']) ?? createdAt,
      'dirty': 0,
    });
  }
}

// ------------------------------------------------------------- app settings

/// Sirf whitelisted keys push hoti hain (SyncQueueHelper.SYNCED_APP_SETTING_KEYS), is liye yahan filter
/// nahi. Jis key ka apna push abhi pending ho use skip (pull taaza edit ko na kuchle).
Future<void> applyAppSettings(DatabaseExecutor db, List<SyncDoc> rows) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    final key = _s(row['key']);
    if (key == null) continue;
    if ((await q.pendingForEntityAnyRetry('app_setting', key, 'upsert')).isNotEmpty) continue;
    final value = _s(row['value']);
    if (value == null) continue;
    // Purani build ke Month Close docs (`month_close:*`) ab istemal nahi hote — local DB mein na likho.
    if (key.startsWith('month_close:')) continue;
    await db.insert('app_settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ------------------------------------------------------------ cash register

/// `date` hi doc id aur local PK. Tombstone kabhi nahi banta (register delete nahi hota). Is device ka
/// apna open/edit/close/reopen pending ho (kisi bhi operation, `create_if_absent` samet) to skip.
Future<void> applyCashRegisters(DatabaseExecutor db, List<SyncDoc> rows) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    final date = _s(row['date']);
    if (date == null) continue;
    if (await q.pendingCountForEntity('cash_register', date) > 0) continue;
    await db.insert(
      'cash_register',
      {
        'date': date,
        'openingCash': _d(row['openingCash']) ?? 0.0,
        'closingCash': _d(row['closingCash']) ?? 0.0,
        'openingBank': _d(row['openingBank']) ?? 0.0,
        'closingBank': _d(row['closingBank']) ?? 0.0,
        'closed': (row['closed'] is bool && row['closed'] == true) ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
