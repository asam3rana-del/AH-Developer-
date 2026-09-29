import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/sync/sync_apply.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_dao.dart';
import 'package:ah_developer_kiryana_store/sync/sync_types.dart';

/// Phase 10: pull assemble + applyServerChanges hissa 1 (customers / suppliers / products / users).
/// Hissa 2 (sales ... cashRegisters): test/sync_apply_rest_test.dart.
Future<String> _fakeHash(String p) async => 'hash($p)';

Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', creditLimit REAL NOT NULL DEFAULT 0, openingBalance REAL NOT NULL DEFAULT 0,
    balance REAL NOT NULL DEFAULT 0, stuckBalance REAL NOT NULL DEFAULT 0, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', openingBalance REAL NOT NULL DEFAULT 0, balance REAL NOT NULL DEFAULT 0,
    serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE products (barcode TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0, salePrice REAL NOT NULL DEFAULT 0,
    stock REAL NOT NULL DEFAULT 0, reorderLevel REAL NOT NULL DEFAULT 0, expiry TEXT NOT NULL DEFAULT '',
    unit TEXT NOT NULL DEFAULT 'pcs', unitSize INTEGER NOT NULL DEFAULT 1, unitNote TEXT NOT NULL DEFAULT '',
    secondaryUnit TEXT NOT NULL DEFAULT '', secondaryUnitQty REAL NOT NULL DEFAULT 0,
    wholesalePrice REAL NOT NULL DEFAULT 0, openingStock REAL NOT NULL DEFAULT 0,
    tertiaryUnit TEXT NOT NULL DEFAULT '', tertiaryUnitQty REAL NOT NULL DEFAULT 0,
    updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1, searchTag TEXT NOT NULL DEFAULT '',
    defaultUnitIndex INTEGER NOT NULL DEFAULT -1, quickSaleDefaultUnitIndex INTEGER NOT NULL DEFAULT -1)''');
  await db.execute('''CREATE TABLE users (username TEXT PRIMARY KEY NOT NULL, displayName TEXT NOT NULL,
    role TEXT NOT NULL, passwordHash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
    phone TEXT NOT NULL DEFAULT '')''');
  await db.execute('''CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL,
    action TEXT NOT NULL, reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL)''');
  await db.execute('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
    entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
    syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  return db;
}

Future<void> _apply(Database db, PullResult r) =>
    applyServerChangesToDb(db, r, hashPassword: _fakeHash, nowMs: () => 5000);

Future<void> _queue(Database db, String type, String id, String op, String payload,
    {int retry = 0, int? synced}) async {
  await SyncQueueDao(db).enqueue(SyncQueueEntry(
      entityType: type, entityId: id, operation: op, payloadJson: payload, createdAt: 1,
      retryCount: retry, syncedAt: synced));
}

void main() {
  sqfliteFfiInit();
  late Database db;
  setUp(() async => db = await _memDb());
  tearDown(() => db.close());

  group('assemblePullResult', () {
    test('collection -> field; serverTime = sab se bara updatedAt (kam az kam since)', () {
      final r = assemblePullResult({
        'customers': [{'updatedAt': 100}, {'updatedAt': 250.0}],
        'cash_register': [{'updatedAt': 300, 'date': 'd'}],
        'shop_empty_shell_log': [{'updatedAt': 90}],
        'products': [{'noUpdatedAt': 1}], // checkpoint nahi badhata
      }, 200);
      expect(r.customers.length, 2);
      expect(r.cashRegisters.single['date'], 'd');
      expect(r.shopEmptyShellLogs.length, 1);
      expect(r.products.length, 1);
      expect(r.serverTime, 300);
      expect(assemblePullResult({}, 200).serverTime, 200);
      expect(assemblePullResult({'sales': [{'updatedAt': 5}]}, 200).serverTime, 200);
      expect(pullCollections.length, 20);
    });
  });

  group('customers', () {
    test('naya insert; naam/serverId ke baghair skip', () async {
      await _apply(db, PullResult(customers: [
        {'serverId': 'c1', 'name': 'Ali', 'phone': '0300', 'balance': 100, 'creditLimit': 500, 'openingBalance': 10,
         'stuckBalance': 7, 'updatedAt': 900},
        {'serverId': 'c2'},
        {'name': 'NoId'},
      ]));
      final rows = await db.query('customers');
      expect(rows.length, 1);
      expect(rows.single['name'], 'Ali');
      expect(rows.single['balance'], 100.0);
      expect(rows.single['stuckBalance'], 7.0);
      expect(rows.single['updatedAt'], 900);
      expect(rows.single['dirty'], 0);
    });

    test('maujood row update (id wohi); stuckBalance na aaye to apna barqarar', () async {
      await db.insert('customers', {'name': 'Old', 'phone': '1', 'serverId': 'c1', 'stuckBalance': 42.0, 'dirty': 0});
      await _apply(db, PullResult(customers: [
        {'serverId': 'c1', 'name': 'New', 'phone': '2', 'balance': 5, 'updatedAt': 800},
      ]));
      final r = (await db.query('customers')).single;
      expect(r['id'], 1);
      expect(r['name'], 'New');
      expect(r['stuckBalance'], 42.0);
      expect(r['balance'], 5.0);
    });

    test('pending increment_balance server balance ke UPAR lagta hai (stuck entry bhi), dirty=1', () async {
      await _queue(db, 'customer', 'c1', 'increment_balance', '{"delta":30}');
      await _queue(db, 'customer', 'c1', 'increment_balance', '{"delta":-5}', retry: 10);
      await _queue(db, 'customer', 'c1', 'increment_balance', '{"delta":999}', synced: 1); // bhej di gayi
      await _queue(db, 'customer', 'c1', 'increment_balance', 'kharab-json');
      await _apply(db, PullResult(customers: [
        {'serverId': 'c1', 'name': 'Ali', 'balance': 100, 'updatedAt': 1},
      ]));
      final r = (await db.query('customers')).single;
      expect(r['balance'], 125.0);
      expect(r['dirty'], 1);
    });

    test('pending upsert (apna naam edit) => pull skip, local edit salamat', () async {
      await db.insert('customers', {'name': 'My edit', 'serverId': 'c1', 'dirty': 1});
      await _queue(db, 'customer', 'c1', 'upsert', '{}');
      await _apply(db, PullResult(customers: [
        {'serverId': 'c1', 'name': 'Server old', 'updatedAt': 1},
      ]));
      expect((await db.query('customers')).single['name'], 'My edit');
      expect(await db.query('audit'), isEmpty);
    });

    test('dirty + naam badla => sync_conflict audit', () async {
      await db.insert('customers', {'name': 'Mine', 'phone': '9', 'serverId': 'c1', 'dirty': 1});
      await _apply(db, PullResult(customers: [
        {'serverId': 'c1', 'name': 'Theirs', 'phone': '8', 'updatedAt': 1},
      ]));
      final a = (await db.query('audit')).single;
      expect(a['action'], 'sync_conflict');
      expect(a['reference'], 'customer:c1');
      expect(a['details'], contains('Mine / 9'));
      expect(a['details'], contains('Theirs / 8'));
    });

    test('_deleted => serverId se hat jata hai', () async {
      await db.insert('customers', {'name': 'A', 'serverId': 'c1'});
      await db.insert('customers', {'name': 'B', 'serverId': 'c2'});
      await _apply(db, PullResult(customers: [{'serverId': 'c1', '_deleted': true}]));
      expect((await db.query('customers')).single['name'], 'B');
    });
  });

  group('suppliers', () {
    test('naya supplier: pending delta NAHI lagta, dirty=0, updatedAt=abhi (Kotlin jaisa)', () async {
      await _queue(db, 'supplier', 's1', 'increment_balance', '{"delta":50}');
      await _apply(db, PullResult(suppliers: [
        {'serverId': 's1', 'name': 'Deen', 'balance': 200, 'openingBalance': 3, 'updatedAt': 1},
      ]));
      final r = (await db.query('suppliers')).single;
      expect(r['balance'], 200.0);
      expect(r['dirty'], 0);
      expect(r['updatedAt'], 5000);
    });

    test('maujood supplier: pending delta lagta hai; pending rename skip', () async {
      await db.insert('suppliers', {'name': 'Cash Purchase', 'serverId': 's1', 'dirty': 0});
      await _queue(db, 'supplier', 's1', 'increment_balance', '{"delta":50}');
      await _apply(db, PullResult(suppliers: [
        {'serverId': 's1', 'name': 'Deen & Bros', 'balance': 200, 'updatedAt': 7},
      ]));
      var r = (await db.query('suppliers')).single;
      expect(r['name'], 'Deen & Bros');
      expect(r['balance'], 250.0);
      expect(r['dirty'], 1);

      await _queue(db, 'supplier', 's1', 'upsert', '{}');
      await _apply(db, PullResult(suppliers: [
        {'serverId': 's1', 'name': 'Reverted', 'updatedAt': 8},
      ]));
      r = (await db.query('suppliers')).single;
      expect(r['name'], 'Deen & Bros'); // rename wapas nahi hua
    });

    test('_deleted', () async {
      await db.insert('suppliers', {'name': 'A', 'serverId': 's1'});
      await _apply(db, PullResult(suppliers: [{'serverId': 's1', '_deleted': true}]));
      expect(await db.query('suppliers'), isEmpty);
    });
  });

  group('products', () {
    Map<String, Object?> doc(Map<String, Object?> extra) =>
        {'barcode': '111', 'name': 'Rice', 'salePrice': 100, 'updatedAt': 10, ...extra};

    test('naya product defaults ke saath; stock = server + pending', () async {
      await _queue(db, 'product', '111', 'increment_stock', '{"delta":-2}');
      await _apply(db, PullResult(products: [doc({'stock': 20, 'unit': 'kg', 'searchTag': 'chawal'})]));
      final r = (await db.query('products')).single;
      expect(r['stock'], 18.0);
      expect(r['dirty'], 1);
      expect(r['unit'], 'kg');
      expect(r['searchTag'], 'chawal');
      expect(r['defaultUnitIndex'], -1);
      expect(r['openingStock'], 0.0);
    });

    test('doc mein stock na ho => local stock barqarar (+ pending)', () async {
      await db.insert('products', {'barcode': '111', 'name': 'Rice', 'stock': 40.0, 'openingStock': 8.0, 'dirty': 0});
      await _queue(db, 'product', '111', 'increment_stock', '{"delta":5}');
      await _apply(db, PullResult(products: [doc({})]));
      final r = (await db.query('products')).single;
      expect(r['stock'], 45.0);
      expect(r['openingStock'], 8.0); // untouched
      expect(r['salePrice'], 100.0);
    });

    test('pending upsert => skip; sirf pending increment_stock rukta nahi', () async {
      await db.insert('products', {'barcode': '111', 'name': 'Mine', 'salePrice': 1.0, 'dirty': 1});
      await _queue(db, 'product', '111', 'upsert', '{}');
      await _apply(db, PullResult(products: [doc({'name': 'Theirs'})]));
      expect((await db.query('products')).single['name'], 'Mine');
    });

    test('dirty + qeemat badli => conflict audit; delete barcode se', () async {
      await db.insert('products', {'barcode': '111', 'name': 'Rice', 'salePrice': 90.0, 'dirty': 1});
      await _apply(db, PullResult(products: [doc({'salePrice': 100})]));
      final a = (await db.query('audit')).single;
      expect(a['reference'], 'product:111');
      expect(a['details'], contains('Rice / 90.0'));
      expect(a['details'], contains('Rice / 100.0'));
      await _apply(db, PullResult(products: [{'barcode': '111', '_deleted': true}]));
      expect(await db.query('products'), isEmpty);
    });
  });

  group('users', () {
    test('naya user: random (hashed) password, role default cashier, active default true', () async {
      await _apply(db, PullResult(users: [
        {'username': 'sara', 'displayName': 'Sara'},
        {'username': 'x'}, // displayName nahi => skip
      ]));
      final r = (await db.query('users')).single;
      expect(r['role'], 'cashier');
      expect(r['active'], 1);
      expect(r['passwordHash'], startsWith('hash('));
    });

    test('maujood user: password hash nahi chhoota; active bool; delete', () async {
      await db.insert('users', {'username': 'sara', 'displayName': 'Old', 'role': 'cashier',
        'passwordHash': 'KEEP', 'active': 1, 'phone': ''});
      await _apply(db, PullResult(users: [
        {'username': 'sara', 'displayName': 'Sara K', 'role': 'manager', 'phone': '03', 'active': false},
      ]));
      var r = (await db.query('users')).single;
      expect(r['passwordHash'], 'KEEP');
      expect(r['displayName'], 'Sara K');
      expect(r['role'], 'manager');
      expect(r['active'], 0);
      await _apply(db, PullResult(users: [{'username': 'sara', '_deleted': true}]));
      expect(await db.query('users'), isEmpty);
    });
  });

  test('sab ek transaction: beech mein ghalti => kuch nahi likha', () async {
    // products table hata do => applyProducts throw; customers wali insert bhi wapas honi chahiye.
    await db.execute('DROP TABLE products');
    await expectLater(
      _apply(db, PullResult(
        customers: [{'serverId': 'c1', 'name': 'Ali'}],
        products: [{'barcode': '1', 'name': 'x'}],
      )),
      throwsA(anything),
    );
    expect(await db.query('customers'), isEmpty);
  });
}
