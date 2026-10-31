import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Database migration tests (improvement plan, P0 #4).
///
/// Method: a fresh install (v34, via AppDatabase._onCreate) is the reference. For each start version N we
///   1. seed business data into the fresh DB and record its full schema + rows,
///   2. close it and "rewind" the file to look like schema vN (drop everything added by migrations > N,
///      PRAGMA user_version = N),
///   3. re-open through AppDatabase, which runs the real _onUpgrade,
///   4. require: user_version == 34, integrity_check ok, no FK violations, schema identical to a fresh
///      install, and every seeded row unchanged.
///
/// Limits (be honest): rewinding is derived from the migration code, not from real old database files, so
/// it proves "the upgrade steps rebuild the current schema without losing rows", not "a real v20 file from a
/// customer's phone upgrades". Starting versions below 20 are not covered here.
///
/// Runs via: flutter test test_migration  (separate CI job, see .github/workflows/migration-tests.yml)
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('migration_');
    await databaseFactory.setDatabasesPath(dir.path);
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  // ---- what each migration step added (version -> things to remove when rewinding below it) ----
  final steps = <_Step>[
    _Step(34, columns: {'users': ['permissions']}),
    _Step(33, columns: {'sale_items': ['pendingQty', 'pendingEst', 'backfillLog']}),
    _Step(32, columns: {'customers': ['returnLog']}),
    _Step(31, columns: {'customers': ['returnEntries']}),
    _Step(30, tables: ['recycle_bin']),
    _Step(29, columns: {'customers': ['kind', 'returnDate']}),
    _Step(27, tables: ['utility_bill_payments', 'utility_bills']),
    _Step(25, tables: ['shop_rent_ledger', 'shop_rent_terms', 'shop_rents']),
    _Step(23, tables: ['worker_salary_payments', 'worker_advances', 'worker_attendance', 'workers']),
    _Step(22, columns: {'customers': ['dueDays']}),
    _Step(21, columns: {'purchase_items': ['shopkeeperRate']}),
  ];

  Future<void> rewindTo(String path, int version) async {
    final raw = await databaseFactory.openDatabase(path); // foreign_keys OFF by default
    for (final s in steps.where((s) => s.version > version)) {
      for (final t in s.tables) {
        await raw.execute('DROP TABLE IF EXISTS $t');
      }
      for (final e in s.columns.entries) {
        for (final c in e.value) {
          await raw.execute('ALTER TABLE ${e.key} DROP COLUMN $c');
        }
      }
    }
    await raw.execute('PRAGMA user_version = $version');
    await raw.close();
  }

  Future<void> seed(dynamic db, {required bool withReturnEntries}) async {
    final entries = withReturnEntries
        ? jsonEncode([
            {'id': 1, 'amount': 500.0, 'date': 1700000000000, 'returnDate': 0, 'note': 'loan one'},
            {'id': 2, 'amount': 250.0, 'date': 1700100000000, 'returnDate': 0, 'note': ''},
          ])
        : '';
    await db.insert('products', {
      'barcode': 'P1', 'name': 'Rice 5kg', 'cost': 900.0, 'salePrice': 1000.0, 'stock': 12.5,
    });
    await db.insert('products', {
      'barcode': 'P2', 'name': 'Sugar', 'cost': 150.0, 'salePrice': 170.0, 'stock': 40.0,
    });
    await db.insert('customers', {
      'name': 'Ali', 'phone': '0300', 'balance': 750.0, 'kind': withReturnEntries ? 'loan' : '',
      'returnEntries': entries,
    });
    await db.insert('customers', {'name': 'Bilal', 'balance': -120.5});
    await db.insert('suppliers', {'name': 'Wholesaler', 'balance': 3000.0});
    await db.insert('sales', {
      'invoice': 'INV-1', 'customerId': 1, 'subtotal': 2000.0, 'discount': 50.0, 'tax': 0.0,
      'total': 1950.0, 'paid': 1000.0, 'paymentMethod': 'cash', 'createdAt': 1700000000000,
    });
    await db.insert('sale_items', {
      'invoice': 'INV-1', 'barcode': 'P1', 'product': 'Rice 5kg', 'qty': 2.0, 'unit': 'pcs',
      'unitPrice': 1000.0, 'cost': 900.0, 'amount': 2000.0,
    });
    await db.insert('payments', {
      'reference': 'INV-1', 'partyType': 'customer', 'partyId': 1, 'amount': 1000.0,
      'method': 'cash', 'createdAt': 1700000000000,
    });
    await db.insert('purchases', {
      'billNo': 'PB-1', 'supplierId': 1, 'total': 4500.0, 'paid': 1500.0, 'createdAt': 1700000000000,
    });
    await db.insert('purchase_items', {
      'billNo': 'PB-1', 'barcode': 'P1', 'qty': 5.0, 'unitCost': 900.0, 'amount': 4500.0,
    });
    await db.insert('expenses', {
      'category': 'Rent', 'description': 'Shop', 'amount': 20000.0, 'createdAt': 1700000000000,
    });
    await db.insert('users', {
      'username': 'owner', 'displayName': 'Owner', 'role': 'admin', 'passwordHash': 'x',
    });
  }

  const dataTables = [
    'products', 'customers', 'suppliers', 'sales', 'sale_items', 'payments',
    'purchases', 'purchase_items', 'expenses', 'users', 'categories', 'units',
  ];

  /// table -> sorted "column|type|notnull|default|pk" lines, plus index names.
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

  Future<Map<String, List<String>>> rowsOf(dynamic db, {Set<String> skipColumns = const {}}) async {
    final out = <String, List<String>>{};
    for (final t in dataTables) {
      final rows = await db.rawQuery('SELECT * FROM $t ORDER BY rowid');
      out[t] = [
        for (final r in rows)
          jsonEncode(Map.fromEntries(
              (r.entries.where((e) => !skipColumns.contains('$t.${e.key}')).toList()
                    ..sort((a, b) => a.key.compareTo(b.key)))
                  .map((e) => MapEntry(e.key, e.value)))),
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

  test('fresh install: schema version, integrity, default seed rows', () async {
    final db = await AppDatabase.instance.database;
    await expectHealthy(db);
    expect(AppDatabase.schemaVersion, 34);
    expect((await db.query('categories')).map((r) => r['name']), contains('General'));
    expect((await db.query('units')).map((r) => r['name']), contains('pcs'));
  });

  for (final start in [20, 29, 31, 33]) {
    test('upgrade v$start -> v${AppDatabase.schemaVersion}: schema == fresh install, no rows lost', () async {
      final withEntries = start == 31; // returnEntries exists from v31; v32 backfills returnLog from it
      var db = await AppDatabase.instance.database;
      await seed(db, withReturnEntries: withEntries);
      final freshSchema = await schemaOf(db);
      final before = await rowsOf(db, skipColumns: {'customers.returnLog'});
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
      expect(await rowsOf(db, skipColumns: {'customers.returnLog'}), equals(before));

      if (withEntries) {
        final ali = (await db.query('customers', where: "name = 'Ali'")).single;
        expect(ali['balance'], 750.0); // v32 backfill must not touch the balance
        expect((ali['returnLog'] as String).isNotEmpty, isTrue);
      }
    });
  }

  test('upgrade is idempotent: re-running onUpgrade steps on a current DB changes nothing', () async {
    var db = await AppDatabase.instance.database;
    await seed(db, withReturnEntries: false);
    final schema = await schemaOf(db);
    final rows = await rowsOf(db);
    final path = await AppDatabase.instance.databasePath;
    await AppDatabase.instance.close();

    // Pretend an interrupted/duplicated upgrade: label the DB v33 while it already has v34 columns.
    final raw = await databaseFactory.openDatabase(path);
    await raw.execute('PRAGMA user_version = 33');
    await raw.close();

    db = await AppDatabase.instance.database;
    await expectHealthy(db);
    expect(await schemaOf(db), equals(schema));
    expect(await rowsOf(db), equals(rows));
  });
}

class _Step {
  final int version;
  final Map<String, List<String>> columns;
  final List<String> tables;
  _Step(this.version, {this.columns = const {}, this.tables = const []});
}
