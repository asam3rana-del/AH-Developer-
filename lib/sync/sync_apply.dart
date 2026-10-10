import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/maintenance_sync.dart';
import '../utils/password_hasher.dart';
import 'sync_apply_rest.dart';
import 'sync_push_plan.dart' show decodePayload;
import 'sync_queue_dao.dart';
import 'sync_types.dart';

/// Kotlin `SyncApi.applyServerChanges()` — pull ki hui changes local tables mein merge.
///
/// HISSA 1 (yahan): customers, suppliers, products, users. HISSA 2 (`sync_apply_rest.dart`): sales,
/// purchases, expenses, payments, cash_transactions, units, categories, zakat_*, returns, stock_movements,
/// shell_*, app_settings, cash_register. Dono ek hi transaction mein, Kotlin ki tarteeb par.
///
/// FARQ: sab kuch EK transaction mein (Kotlin har DAO call alag) — beech mein ghalti ho to kuch nahi
/// likha jata, checkpoint nahi barhta, agli sync wohi dobara lagati hai.

typedef PasswordHashFn = Future<String> Function(String plain);

double? _d(Object? v) => v is num ? v.toDouble() : null;
int? _i(Object? v) => v is num ? v.toInt() : null;
String? _s(Object? v) => v is String ? v : null;
double _dbl(Object? v) => v is num ? v.toDouble() : 0.0;

Future<void> applyServerChangesToDb(
  Database db,
  PullResult changes, {
  PasswordHashFn? hashPassword,
  int Function()? nowMs,
}) async {
  final hasher = hashPassword ?? PasswordHasher.hash;
  final clock = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
  await db.transaction((txn) async {
    await applyCustomers(txn, changes.customers, nowMs: clock);
    await applySuppliers(txn, changes.suppliers, nowMs: clock);
    await applyProducts(txn, changes.products, nowMs: clock);
    await applyUsers(txn, changes.users, hashPassword: hasher);
    await applyRestOfServerChanges(txn, changes, nowMs: clock);
    await relinkOrphanedParties(txn);
  });
}

/// Pull par jis payment/sale/purchase ki party us waqt local DB mein nahi thi, uski `partyServerId` /
/// `customerServerId` / `supplierServerId` mehfooz hai — party ab aa chuki ho to link jod do.
/// Sirf link jodta hai; balance NAHI chhoota (server ka balance us row ka asar pehle se rakhta hai).
/// Idempotent: har pull ke aakhir mein chalta hai, jori hui rows dobara nahi chhoti.
Future<void> relinkOrphanedParties(DatabaseExecutor db) async {
  await db.execute(
      'UPDATE payments SET partyId = (SELECT c.id FROM customers c WHERE c.serverId = payments.partyServerId) '
      "WHERE partyId IS NULL AND partyType = 'customer' AND partyServerId IS NOT NULL AND partyServerId != '' "
      'AND EXISTS (SELECT 1 FROM customers c WHERE c.serverId = payments.partyServerId)');
  await db.execute(
      'UPDATE payments SET partyId = (SELECT s.id FROM suppliers s WHERE s.serverId = payments.partyServerId) '
      "WHERE partyId IS NULL AND partyType = 'supplier' AND partyServerId IS NOT NULL AND partyServerId != '' "
      'AND EXISTS (SELECT 1 FROM suppliers s WHERE s.serverId = payments.partyServerId)');
  await db.execute(
      'UPDATE sales SET customerId = (SELECT c.id FROM customers c WHERE c.serverId = sales.customerServerId) '
      "WHERE customerId IS NULL AND customerServerId IS NOT NULL AND customerServerId != '' "
      'AND EXISTS (SELECT 1 FROM customers c WHERE c.serverId = sales.customerServerId)');
  await db.execute(
      'UPDATE purchases SET supplierId = (SELECT s.id FROM suppliers s WHERE s.serverId = purchases.supplierServerId) '
      "WHERE supplierId IS NULL AND supplierServerId IS NOT NULL AND supplierServerId != '' "
      'AND EXISTS (SELECT 1 FROM suppliers s WHERE s.serverId = purchases.supplierServerId)');
}

/// Abhi tak queue mein baithe (bheje na gaye) local deltas — pull ke server snapshot ke UPAR lagte hain,
/// warna offline sale/purchase queue tak pahunchne se pehle pull mein gayab ho jata. Har retryCount ki
/// entries ginti hain (stuck entry ka asar local total se ghaib na ho).
Future<double> pendingDelta(
    SyncQueueDao q, String entityType, String entityId, String operation) async {
  var sum = 0.0;
  for (final row in await q.pendingForEntityAnyRetry(entityType, entityId, operation)) {
    try {
      sum += _d(decodePayload(row.payloadJson)['delta']) ?? 0.0;
    } catch (_) {/* kharab payload = 0 (Kotlin runCatching) */}
  }
  return sum;
}

Future<void> _conflict(DatabaseExecutor db, String reference, String was, String now) =>
    logMaintenanceAudit(
      db,
      username: 'sync',
      action: 'sync_conflict',
      reference: reference,
      details:
          'Your unsynced edit ("$was") was overwritten by a newer cloud update ("$now").',
    );

// ---------------------------------------------------------------- customers

Future<void> applyCustomers(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    if (row['_deleted'] == true) {
      final sid = _s(row['serverId']);
      if (sid != null) await _deleteFirst(db, 'customers', 'serverId', sid);
      continue;
    }
    final serverId = _s(row['serverId']);
    final name = _s(row['name']);
    if (serverId == null || name == null) continue;
    final phone = _s(row['phone']) ?? '';
    final balance = _d(row['balance']) ?? 0.0;
    final creditLimit = _d(row['creditLimit']) ?? 0.0;
    final openingBalance = _d(row['openingBalance']) ?? 0.0;
    // Purani build ka doc (stuckBalance nahi) => apna stuck amount na todo.
    final stuckRemote = _d(row['stuckBalance']);
    // Rate-type: purane doc mein na ho to local tag na todo.
    final rateRemote = row.containsKey('rateType') ? (_s(row['rateType']) ?? '') : null;
    final serverUpdatedAt = _i(row['updatedAt']) ?? nowMs();
    final localPending = await pendingDelta(q, 'customer', serverId, 'increment_balance');
    // 2-device FIX: is device ka apna naam/phone edit abhi push nahi hua => server ki purani copy se
    // overwrite na karo.
    final customerUpsertPending =
        (await q.pendingForEntityAnyRetry('customer', serverId, 'upsert')).isNotEmpty;
    if (customerUpsertPending) {
      // BALANCE FIX: pending naam/phone edit ki wajah se poora row skip NAHI hona chahiye — warna doosre
      // device ka balance update hamesha ke liye kho jata hai (checkpoint aage barh jata hai, ye doc
      // dobara pull nahi hota). Sirf balance apply karo; naam/phone/limit local hi rahein.
      final local = await _findBy(db, 'customers', 'serverId', serverId);
      if (local != null) {
        await db.update(
          'customers',
          {'balance': balance + localPending},
          where: 'id = ?',
          whereArgs: [local['id']],
        );
      }
      continue;
    }

    final existing = await _findBy(db, 'customers', 'serverId', serverId);
    if (existing != null) {
      if (existing['dirty'] == 1 && (existing['name'] != name || existing['phone'] != phone)) {
        await _conflict(db, 'customer:$serverId', '${existing['name']} / ${existing['phone']}', '$name / $phone');
      }
      await db.update(
        'customers',
        {
          'name': name,
          'phone': phone,
          'balance': balance + localPending,
          'creditLimit': creditLimit,
          'openingBalance': openingBalance,
          'stuckBalance': stuckRemote ?? _dbl(existing['stuckBalance']),
          if (rateRemote != null) 'rateType': rateRemote,
          'updatedAt': serverUpdatedAt,
          'dirty': localPending != 0.0 ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [existing['id']],
      );
    } else {
      await db.insert('customers', {
        'name': name,
        'phone': phone,
        'balance': balance + localPending,
        'creditLimit': creditLimit,
        'openingBalance': openingBalance,
        'stuckBalance': stuckRemote ?? 0.0,
        if (rateRemote != null) 'rateType': rateRemote,
        'serverId': serverId,
        'updatedAt': serverUpdatedAt,
        'dirty': localPending != 0.0 ? 1 : 0,
      });
    }
  }
}

// ---------------------------------------------------------------- suppliers

Future<void> applySuppliers(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    if (row['_deleted'] == true) {
      final sid = _s(row['serverId']);
      if (sid != null) await _deleteFirst(db, 'suppliers', 'serverId', sid);
      continue;
    }
    final serverId = _s(row['serverId']);
    final name = _s(row['name']);
    if (serverId == null || name == null) continue;
    final phone = _s(row['phone']) ?? '';
    final balance = _d(row['balance']) ?? 0.0;
    final openingBalance = _d(row['openingBalance']) ?? 0.0;
    final serverUpdatedAt = _i(row['updatedAt']) ?? nowMs();
    final localPending = await pendingDelta(q, 'supplier', serverId, 'increment_balance');
    // 2-device FIX (customer jaisa): pending rename ("Cash Purchase" -> asli naam) pull se wapas na ho.
    final supplierUpsertPending =
        (await q.pendingForEntityAnyRetry('supplier', serverId, 'upsert')).isNotEmpty;
    if (supplierUpsertPending) {
      // BALANCE FIX (customer jaisa): pending rename ho to bhi doosre device ka balance apply karo.
      final local = await _findBy(db, 'suppliers', 'serverId', serverId);
      if (local != null) {
        await db.update(
          'suppliers',
          {'balance': balance + localPending},
          where: 'id = ?',
          whereArgs: [local['id']],
        );
      }
      continue;
    }

    final existing = await _findBy(db, 'suppliers', 'serverId', serverId);
    if (existing != null) {
      if (existing['dirty'] == 1 && (existing['name'] != name || existing['phone'] != phone)) {
        await _conflict(db, 'supplier:$serverId', '${existing['name']} / ${existing['phone']}', '$name / $phone');
      }
      await db.update(
        'suppliers',
        {
          'name': name,
          'phone': phone,
          'balance': balance + localPending,
          'openingBalance': openingBalance,
          'updatedAt': serverUpdatedAt,
          'dirty': localPending != 0.0 ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [existing['id']],
      );
    } else {
      // Kotlin jaisa (jaan boojh kar): naye supplier par local pending delta nahi lagta, updatedAt = abhi,
      // dirty = false.
      await db.insert('suppliers', {
        'name': name,
        'phone': phone,
        'balance': balance,
        'openingBalance': openingBalance,
        'serverId': serverId,
        'updatedAt': nowMs(),
        'dirty': 0,
      });
    }
  }
}

// ----------------------------------------------------------------- products

Future<void> applyProducts(DatabaseExecutor db, List<SyncDoc> rows, {required int Function() nowMs}) async {
  final q = SyncQueueDao(db);
  for (final row in rows) {
    if (row['_deleted'] == true) {
      final bc = _s(row['barcode']);
      if (bc != null) await db.delete('products', where: 'barcode = ?', whereArgs: [bc]);
      continue;
    }
    final barcode = _s(row['barcode']);
    final name = _s(row['name']);
    if (barcode == null || name == null) continue;
    final category = _s(row['category']) ?? '';
    final cost = _d(row['cost']) ?? 0.0;
    final salePrice = _d(row['salePrice']) ?? 0.0;
    final wholesalePrice = _d(row['wholesalePrice']) ?? 0.0;
    final reorderLevel = _d(row['reorderLevel']) ?? 0.0;
    final expiry = _s(row['expiry']) ?? '';
    final unit = _s(row['unit']) ?? 'pcs';
    final unitSize = _i(row['unitSize']) ?? 1;
    final unitNote = _s(row['unitNote']) ?? '';
    final secondaryUnit = _s(row['secondaryUnit']) ?? '';
    final secondaryUnitQty = _d(row['secondaryUnitQty']) ?? 0.0;
    final tertiaryUnit = _s(row['tertiaryUnit']) ?? '';
    final tertiaryUnitQty = _d(row['tertiaryUnitQty']) ?? 0.0;
    final defaultUnitIndex = _i(row['defaultUnitIndex']) ?? -1;
    final quickSaleDefaultUnitIndex = _i(row['quickSaleDefaultUnitIndex']) ?? -1;
    final searchTag = _s(row['searchTag']) ?? '';
    // Server doc ka "stock" wahi sab devices ke increment_stock ka jama shuda total hai (productJson
    // mein stock jaan boojh kar nahi hota). Doc mein na ho to local stock barqarar.
    final stock = _d(row['stock']);
    final serverUpdatedAt = _i(row['updatedAt']) ?? nowMs();
    final localPendingStock = await pendingDelta(q, 'product', barcode, 'increment_stock');
    // Is device ka "cloud stock = mera stock" abhi push nahi hua => pull local stock ko purani cloud value se
    // overwrite na kare.
    final keepLocalStock = (await q.pendingForEntityAnyRetry('product', barcode, 'set_stock')).isNotEmpty;
    // Sirf pending "upsert" (naam/qeemat) rokta hai — pending increment_stock nahi (warna product sync
    // hamesha atka rahe).
    if ((await q.pendingForEntityAnyRetry('product', barcode, 'upsert')).isNotEmpty) {
      // Naam/qeemat ka apna edit bacha rahe, magar STOCK phir bhi cloud se aaye: purchase (rate set) ya edit ke
      // baad product upsert queue mein atak jaye to pehle is product ka stock hamesha ke liye purana rehta tha.
      if (stock != null && !keepLocalStock) {
        await db.update(
          'products',
          {'stock': stock + localPendingStock, 'dirty': 1},
          where: 'barcode = ?',
          whereArgs: [barcode],
        );
      }
      continue;
    }

    final existing = await _findBy(db, 'products', 'barcode', barcode);
    final common = <String, Object?>{
      'name': name,
      'category': category,
      'cost': cost,
      'salePrice': salePrice,
      'wholesalePrice': wholesalePrice,
      'reorderLevel': reorderLevel,
      'expiry': expiry,
      'unit': unit,
      'unitSize': unitSize,
      'unitNote': unitNote,
      'secondaryUnit': secondaryUnit,
      'secondaryUnitQty': secondaryUnitQty,
      'tertiaryUnit': tertiaryUnit,
      'tertiaryUnitQty': tertiaryUnitQty,
      'defaultUnitIndex': defaultUnitIndex,
      'quickSaleDefaultUnitIndex': quickSaleDefaultUnitIndex,
      'searchTag': searchTag,
      'dirty': localPendingStock != 0.0 ? 1 : 0,
      'updatedAt': serverUpdatedAt,
    };
    // Bulk rate sirf tab lo jab cloud doc mein ho: purane device / Kotlin app ka doc local bulk rate 0 na kar de.
    if (row.containsKey('bulkPrice')) common['bulkPrice'] = _d(row['bulkPrice']) ?? 0.0;
    if (row.containsKey('bulkMinQty')) common['bulkMinQty'] = _d(row['bulkMinQty']) ?? 0.0;
    if (row.containsKey('wholesaleBulkPrice')) common['wholesaleBulkPrice'] = _d(row['wholesaleBulkPrice']) ?? 0.0;
    if (row.containsKey('wholesaleBulkMinQty')) common['wholesaleBulkMinQty'] = _d(row['wholesaleBulkMinQty']) ?? 0.0;
    // Shopkeeper rate: purane device ka doc (field nahi) local rate zero na kare.
    if (row.containsKey('shopkeeperPrice')) common['shopkeeperPrice'] = _d(row['shopkeeperPrice']) ?? 0.0;
    if (existing != null) {
      if (existing['dirty'] == 1 && (existing['name'] != name || _dbl(existing['salePrice']) != salePrice)) {
        await _conflict(db, 'product:$barcode', '${existing['name']} / ${_dbl(existing['salePrice'])}',
            '$name / $salePrice');
      }
      await db.update(
        'products',
        {
          ...common,
          if (!keepLocalStock) 'stock': (stock ?? _dbl(existing['stock'])) + localPendingStock,
        },
        where: 'barcode = ?',
        whereArgs: [barcode],
      );
    } else {
      await db.insert(
        'products',
        {'barcode': barcode, ...common, 'stock': (stock ?? 0.0) + localPendingStock},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

// -------------------------------------------------------------------- users

Future<void> applyUsers(DatabaseExecutor db, List<SyncDoc> rows, {required PasswordHashFn hashPassword}) async {
  for (final row in rows) {
    if (row['_deleted'] == true) {
      final u = _s(row['username']);
      if (u != null) await db.delete('users', where: 'username = ?', whereArgs: [u]);
      continue;
    }
    final username = _s(row['username']);
    final displayName = _s(row['displayName']);
    if (username == null || displayName == null) continue;
    final role = _s(row['role']) ?? 'cashier';
    final phone = _s(row['phone']) ?? '';
    final active = row['active'] is bool ? row['active'] as bool : true;

    final existing = await _findBy(db, 'users', 'username', username);
    if (existing != null) {
      // passwordHash kabhi cloud se nahi aata/badalta.
      await db.update(
        'users',
        {'displayName': displayName, 'role': role, 'phone': phone, 'active': active ? 1 : 0},
        where: 'username = ?',
        whereArgs: [username],
      );
    } else {
      // Naye user ka password cloud par nahi: bekaar random hash — admin ko is device par password set
      // karna hoga.
      await db.insert(
        'users',
        {
          'username': username,
          'displayName': displayName,
          'role': role,
          'passwordHash': await hashPassword(_randomSecret()),
          'active': active ? 1 : 0,
          'phone': phone,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

// ------------------------------------------------------------------ helpers

Future<Map<String, Object?>?> _findBy(DatabaseExecutor db, String table, String col, String value) async {
  final rows = await db.query(table, where: '$col = ?', whereArgs: [value], limit: 1);
  return rows.isEmpty ? null : rows.first;
}

/// Kotlin `findByServerId(..)?.let { delete }` — pehli match hatao.
Future<void> _deleteFirst(DatabaseExecutor db, String table, String col, String value) async {
  final row = await _findBy(db, table, col, value);
  if (row == null) return;
  await db.delete(table, where: 'id = ?', whereArgs: [row['id']]);
}

String _randomSecret() => const Uuid().v4();
