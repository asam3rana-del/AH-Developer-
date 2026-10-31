import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Database migration tests, part 2 (improvement plan, P0 #4): start versions BELOW v20.
///
/// Same method as db_migration_test.dart: fresh install (current schema) is the reference; seed rows,
/// rewind the file to schema vN by undoing every migration step > N, re-open through AppDatabase (real
/// _onUpgrade), then require: user_version == current, integrity ok, no FK violations, schema identical to
/// a fresh install, every seeded row unchanged.
///
/// Extra checks that only matter for old files:
///   - v11 creates stock_movements and backfills one OPENING_STOCK row per product with stock != 0, so
///     ledger sum must equal product.stock after upgrading from < v11.
///   - a larger data set (thousands of rows) from the oldest supported start (v2) upgrades intact.
///
/// Limit (same honesty as part 1): rewinding is derived from the migration code, NOT from real customer
/// files. Real old .db files are still to be added under test/fixtures/ (see report).
///
/// NOTE: v17 has no migration step (version skipped), so it is not a start version here.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('migration_legacy_');
    await databaseFactory.setDatabasesPath(dir.path);
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  // version -> what that migration step added (removed when rewinding to a version below it)
  final steps = <_Step>[
    _Step(34, columns: {'users': ['permissions']}),
    _Step(33, columns: {'sale_items': ['pendingQty', 'pendingEst', 'backfillLog']}),
    _Step(32, columns: {'customers': ['returnLog']}),
    _Step(31, columns: {'customers': ['returnEntries']}),
    _Step(30, tables: ['recycle_bin']),
    _Step(29, columns: {'customers': ['kind', 'returnDate']}),
    _Step(28, columns: {
      'utility_bills': ['serverId'],
      'utility_bill_payments': ['serverId', 'expenseServerId', 'updatedAt'],
    }),
    _Step(27, tables: ['utility_bill_payments', 'utility_bills']),
    _Step(26, columns: {
      'shop_rents': ['serverId', 'updatedAt'],
      'shop_rent_ledger': ['serverId', 'expenseServerId', 'cashServerId', 'updatedAt'],
    }),
    _Step(25, tables: ['shop_rent_ledger', 'shop_rent_terms', 'shop_rents']),
    _Step(24, columns: {
      'workers': ['serverId', 'updatedAt'],
      'worker_attendance': ['updatedAt'],
      'worker_advances': ['serverId', 'updatedAt'],
      'worker_salary_payments': ['serverId', 'expenseServerId', 'updatedAt'],
    }),
    _Step(23, tables: ['worker_salary_payments', 'worker_advances', 'worker_attendance', 'workers']),
    _Step(22, columns: {'customers': ['dueDays']}),
    _Step(21, columns: {'purchase_items': ['shopkeeperRate']}),
    _Step(20, tables: ['customer_rent']),
    _Step(19, columns: {'products': ['ratesAt']}),
    _Step(18, columns: {'products': ['shopkeeperPrice'], 'customers': ['rateType']}),
    _Step(16, columns: {'products': ['wholesaleBulkPrice', 'wholesaleBulkMinQty']}),
    _Step(15, columns: {'products': ['bulkPrice', 'bulkMinQty']}),
    _Step(14, columns: {
      'payments': ['partyServerId'],
      'sales': ['customerServerId'],
      'purchases': ['supplierServerId'],
    }),
    _Step(13, columns: {'returns': ['serverId', 'updatedAt', 'dirty']}),
    _Step(12, columns: {
      'purchases': ['supplierInvoiceNo'],
      'purchase_items': ['conversionFactor', 'itemName', 'retailRate', 'wholesaleRate'],
    }),
    _Step(11, tables: ['stock_movements']),
    _Step(10, columns: {'sales': ['dueDate'], 'purchases': ['dueDate']}),
    _Step(9, columns: {'customers': ['stuckBalance']}),
    _Step(8, tables: ['shell_transactions', 'shell_customers', 'shop_empty_shell_log']),
    _Step(7, tables: ['zakat_payments', 'zakat_years', 'zakat_month_plans']),
    _Step(6, columns: {'expenses': ['method']}),
    _Step(5, columns: {'payments': ['billReference']}),
    _Step(4, columns: {'sale_items': ['conversionFactor']}),
    _Step(3, columns: {'products': ['defaultUnitIndex', 'quickSaleDefaultUnitIndex']}),
  ];

  Future<bool> tableExists(dynamic db, String t) async {
    final r = await db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?", [t]);
    return r.isNotEmpty;
  }

  Future<void> rewindTo(String path, int version) async {
    final raw = await databaseFactory.openDatabase(path); // foreign_keys OFF by default
    // newest first, so column drops on a table happen before that table itself is dropped
    for (final s in steps.where((s) => s.version > version)) {
      for (final e in s.columns.entries) {
        if (!await tableExists(raw, e.key)) continue; // table is dropped by an older step anyway
        for (final c in e.value) {
          final info = await raw.rawQuery('PRAGMA table_info(${e.key})');
          if (info.any((row) => row['name'] == c)) {
            await raw.execute('ALTER TABLE ${e.key} DROP COLUMN $c');
          }
        }
      }
      for (final t in s.tables) {
        await raw.execute('DROP TABLE IF EXISTS $t');
      }
    }
    await raw.execute('PRAGMA user_version = $version');
    await raw.close();
  }

  Future<void> seed(dynamic db, {int products = 2, int sales = 1}) async {
    await db.insert('customers', {'name': 'Ali', 'phone': '0300', 'balance': 750.0});
    await db.insert('customers', {'name': 'Bilal', 'balance': -120.5});
    await db.insert('suppliers', {'name': 'Wholesaler', 'balance': 3000.0});
    await db.insert('users', {
      'username': 'owner', 'displayName': 'Owner', 'role': 'admin', 'passwordHash': 'x',
    });
    await db.insert('expenses', {
      'category': 'Rent', 'description': 'Shop', 'amount': 20000.0, 'createdAt': 1700000000000,
    });
    final batch = db.batch();
    for (var i = 1; i <= products; i++) {
      batch.insert('products', {
        'barcode': 'P$i', 'name': 'Item $i', 'cost': 100.0 + i, 'salePrice': 120.0 + i,
        'stock': i == 2 ? 0.0 : 10.5 + i, // one zero-stock product: must NOT get an opening row
      });
    }
    for (var i = 1; i <= sales; i++) {
      batch.insert('sales', {
        'invoice': 'INV-$i', 'customerId': 1, 'subtotal': 2000.0, 'discount': 50.0, 'tax': 0.0,
        'total': 1950.0, 'paid': 1000.0, 'paymentMethod': 'cash', 'createdAt': 1700000000000 + i,
      });
      batch.insert('sale_items', {
        'invoice': 'INV-$i', 'barcode': 'P1', 'product': 'Item 1', 'qty': 2.0, 'unit': 'pcs',
        'unitPrice': 1000.0, 'cost': 900.0, 'amount': 2000.0,
      });
      batch.insert('payments', {
        'reference': 'INV-$i', 'partyType': 'customer', 'partyId': 1, 'amount': 1000.0,
        'method': 'cash', 'createdAt': 1700000000000 + i,
      });
    }
    batch.insert('purchases', {
      'billNo': 'PB-1', 'supplierId': 1, 'total': 4500.0, 'paid': 1500.0, 'createdAt': 1700000000000,
    });
    batch.insert('purchase_items', {
      'billNo': 'PB-1', 'barcode': 'P1', 'qty': 5.0, 'unitCost': 900.0, 'amount': 4500.0,
    });
    batch.insert('returns', {
      'reference': 'INV-1', 'type': 'sale', 'barcode': 'P1', 'qty': 1.0, 'amount': 1000.0,
      'createdAt': 1700000000000,
    });
    await batch.commit(noResult: true);
  }

  const dataTables = [
    'products', 'customers', 'suppliers', 'sales', 'sale_items', 'payments',
    'purchases', 'purchase_items', 'returns', 'expenses', 'users', 'categories', 'units',
  ];

  Future<Map<String, List<String>>> schemaOf(dynamic db) async {
    final out = <String, List<String>>{};
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    for (final t in tables) {
      final name = t['name'] as String;
      final info = await db.rawQuery('PRAGMA table_info($name)');
      out[name] = [
        for (final c in info) '${c['name']}|${c['type']}|${c['notnull']}|${c['dflt_value']}|${c['pk']}',
      ]..sort();
    }
    final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    out['__indexes__'] = [for (final i in idx) i['name'] as String];
    return out;
  }

  Future<Map<String, List<String>>> rowsOf(dynamic db) async {
    final out = <String, List<String>>{};
    for (final t in dataTables) {
      final List rows = await db.rawQuery('SELECT * FROM $t ORDER BY rowid');
      out[t] = [
        for (final r in rows)
          () {
            final m = Map<String, Object?>.from(r as Map);
            final keys = m.keys.toList()..sort();
            return jsonEncode({for (final k in keys) k: m[k]});
          }(),
      ];
    }
    return out;
  }

  Future<void> expectHealthy(dynamic db) async {
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, AppDatabase.schemaVersion);
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    expect(integrity.single.values.single, 'ok');
    final fk = await db.rawQuery('PRAGMA foreign_key_check');
    expect(fk, isEmpty);
  }

  // every version that has a migration step below v20 (v17 never existed), plus v2 = oldest supported
  for (final start in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19]) {
    test('upgrade v$start -> v${AppDatabase.schemaVersion}: schema == fresh install, no rows lost', () async {
      var db = await AppDatabase.instance.database;
      await seed(db);
      final freshSchema = await schemaOf(db);
      final before = await rowsOf(db);
      final path = await AppDatabase.instance.databasePath;
      await AppDatabase.instance.close();

      await rewindTo(path, start);

      // sanity: the rewind really produced an older schema (otherwise the test proves nothing)
      final old = await databaseFactory.openDatabase(path);
      final oldVer = await old.rawQuery('PRAGMA user_version');
      expect(oldVer.first.values.first, start);
      expect(await schemaOf(old), isNot(equals(freshSchema)));
      await old.close();

      db = await AppDatabase.instance.database; // runs the real _onUpgrade
      await expectHealthy(db);
      expect(await schemaOf(db), equals(freshSchema));
      expect(await rowsOf(db), equals(before));

      // balances are the money that matters most: must be byte-identical after any upgrade
      final ali = (await db.query('customers', where: "name = 'Ali'")).single;
      expect(ali['balance'], 750.0);
      final sup = (await db.query('suppliers')).single;
      expect(sup['balance'], 3000.0);

      if (start < 11) {
        // v11 backfill: one OPENING_STOCK row per product with stock != 0, none for the zero-stock one
        final prods = await db.query('products');
        for (final p in prods) {
          final sum = await db.rawQuery(
              'SELECT COALESCE(SUM(qty),0) AS s, COUNT(*) AS n FROM stock_movements WHERE barcode = ?',
              [p['barcode']]);
          final stock = (p['stock'] as num).toDouble();
          expect((sum.first['s'] as num).toDouble(), stock, reason: '${p['barcode']} ledger sum');
          expect(sum.first['n'], stock == 0 ? 0 : 1, reason: '${p['barcode']} opening rows');
        }
      }
    });
  }

  test('upgrade from v2 with a large data set (2000 products, 1500 sales) keeps every row', () async {
    var db = await AppDatabase.instance.database;
    await seed(db, products: 2000, sales: 1500);
    final before = await rowsOf(db);
    final path = await AppDatabase.instance.databasePath;
    await AppDatabase.instance.close();

    await rewindTo(path, 2);

    final sw = Stopwatch()..start();
    db = await AppDatabase.instance.database;
    sw.stop();
    await expectHealthy(db);
    expect(await rowsOf(db), equals(before));
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)),
        reason: 'upgrade of a mid-size shop DB should not take half a minute');

    // 1999 non-zero-stock products -> 1999 opening rows (P2 is zero stock)
    final n = await db.rawQuery("SELECT COUNT(*) AS n FROM stock_movements");
    expect(n.first['n'], 1999);
  });

  test('upgrade twice in a row (open, close, open) is stable and changes nothing', () async {
    var db = await AppDatabase.instance.database;
    await seed(db);
    final schema = await schemaOf(db);
    final rows = await rowsOf(db);
    final path = await AppDatabase.instance.databasePath;
    await AppDatabase.instance.close();
    await rewindTo(path, 5);

    db = await AppDatabase.instance.database;
    await AppDatabase.instance.close();
    db = await AppDatabase.instance.database; // second open: no upgrade should run

    await expectHealthy(db);
    expect(await schemaOf(db), equals(schema));
    expect(await rowsOf(db), equals(rows));
    // the opening backfill must not run a second time
    final n = await db.rawQuery("SELECT COUNT(*) AS n FROM stock_movements WHERE type = 'OPENING_STOCK'");
    expect(n.first['n'], 1); // only P1 has stock; P2 is zero-stock
  });
}

class _Step {
  final int version;
  final Map<String, List<String>> columns;
  final List<String> tables;
  _Step(this.version, {this.columns = const {}, this.tables = const []});
}
