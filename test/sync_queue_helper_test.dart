import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/device_tag.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

/// Phase 10: SyncQueueHelper (Kotlin `SyncQueueHelper.kt`) — entity ids, Android-shape payloads,
/// enqueue* (row + items DB se), balance/stock delta, delete tombstone, legacy adapter, repairs.
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', creditLimit REAL NOT NULL DEFAULT 0, openingBalance REAL NOT NULL DEFAULT 0,
    balance REAL NOT NULL DEFAULT 0, stuckBalance REAL NOT NULL DEFAULT 0, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', openingBalance REAL NOT NULL DEFAULT 0, balance REAL NOT NULL DEFAULT 0,
    serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
    description TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    createdAt INTEGER NOT NULL, serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE cash_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
    method TEXT NOT NULL DEFAULT 'cash', amount REAL NOT NULL, reason TEXT NOT NULL DEFAULT '',
    reference TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1)''');
  await db.execute('''CREATE TABLE sales (invoice TEXT PRIMARY KEY NOT NULL, customerId INTEGER,
    createdAt INTEGER NOT NULL DEFAULT 0)''');
  await db.execute('''CREATE TABLE purchases (billNo TEXT PRIMARY KEY NOT NULL, supplierId INTEGER,
    createdAt INTEGER NOT NULL DEFAULT 0)''');
  await db.execute('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
    entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
    syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  return db;
}

Future<List<Map<String, Object?>>> _queue(Database db) => db.query('sync_queue', orderBy: 'id');

Map<String, Object?> _payload(Map<String, Object?> row) =>
    jsonDecode(row['payloadJson'] as String) as Map<String, Object?>;

void main() {
  sqfliteFfiInit();
  late Database db;

  setUp(() async {
    db = await _memDb();
    SyncQueueHelper.nowMs = () => 1000;
    SyncQueueHelper.branchId = () => 'main-branch';
    SyncQueueHelper.onQueued = null;
  });
  tearDown(() => db.close());

  group('entity ids', () {
    test('serverId ho to wahi, warna type:<tag>-<id>', () {
      final own = SyncQueueHelper.customerEntityId({'id': 7, 'serverId': null});
      expect(own.startsWith('customer:'), isTrue);
      expect(own.endsWith('-7'), isTrue);
      expect(SyncQueueHelper.customerEntityId({'id': 7, 'serverId': 'customer:ABCD-3'}), 'customer:ABCD-3');
      expect(SyncQueueHelper.customerEntityId({'id': 7, 'serverId': '  '}).endsWith('-7'), isTrue);
    });

    test('natural keys', () {
      expect(SyncQueueHelper.saleEntityId('INV-1'), 'sale:INV-1');
      expect(SyncQueueHelper.purchaseEntityId('B-9'), 'purchase:B-9');
      expect(SyncQueueHelper.userEntityId('ali'), 'user:ali');
      expect(SyncQueueHelper.productEntityId({'barcode': '123'}), '123');
      expect(SyncQueueHelper.cashRegisterEntityId('2026-09-29'), '2026-09-29');
      expect(SyncQueueHelper.unitEntityId('kg'), 'kg');
      expect(SyncQueueHelper.categoryEntityId('Rice'), 'Rice');
    });
  });

  group('enqueue', () {
    test('customer upsert: payload Android shape, balance nahi, serverId stamp', () async {
      final id = await db.insert('customers', {'name': 'Ali', 'phone': '0300', 'creditLimit': 500.0, 'balance': 99.0});
      await SyncQueueHelper.enqueueCustomer(db, id);
      final q = await _queue(db);
      expect(q, hasLength(1));
      expect(q.first['entityType'], 'customer');
      expect(q.first['operation'], 'upsert');
      expect(q.first['retryCount'], 0);
      final p = _payload(q.first);
      expect(p['name'], 'Ali');
      expect(p['creditLimit'], 500.0);
      expect(p.containsKey('balance'), isFalse);
      expect(p['branchId'], 'main-branch');
      expect(p['updatedAt'], 1000);
      expect(p['serverId'], q.first['entityId']);
      final row = (await db.query('customers')).first;
      expect(row['serverId'], q.first['entityId']);
    });

    test('pulled row (serverId pehle se) edit => wahi entityId, naya duplicate nahi', () async {
      final id = await db.insert('customers', {'name': 'Sana', 'serverId': 'customer:ZZZZ-4'});
      await SyncQueueHelper.enqueueCustomer(db, id);
      expect((await _queue(db)).first['entityId'], 'customer:ZZZZ-4');
    });

    test('row na mile to kuch queue nahi hota', () async {
      await SyncQueueHelper.enqueueCustomer(db, 999);
      await SyncQueueHelper.enqueueSale(db, 'NOPE');
      expect(await _queue(db), isEmpty);
    });

    test('expense: method aur createdAt payload mein', () async {
      final id = await db.insert(
          'expenses', {'category': 'Rent', 'description': 'Shop', 'amount': 1200.0, 'method': 'bank', 'createdAt': 55});
      await SyncQueueHelper.enqueueExpense(db, id);
      final p = _payload((await _queue(db)).first);
      expect(p['method'], 'bank');
      expect(p['amount'], 1200.0);
      expect(p['createdAt'], 55);
    });
  });

  group('delta + delete', () {
    test('balance delta: increment_balance, sirf delta', () async {
      final id = await db.insert('customers', {'name': 'Ali'});
      await SyncQueueHelper.enqueueBalanceDelta(db, customer: true, partyId: id, delta: -250.5);
      final q = await _queue(db);
      expect(q.first['operation'], 'increment_balance');
      final p = _payload(q.first);
      expect(p['delta'], -250.5);
      expect(p['branchId'], 'main-branch');
    });

    test('zero delta ignore', () async {
      final id = await db.insert('customers', {'name': 'Ali'});
      await SyncQueueHelper.enqueueBalanceDelta(db, customer: true, partyId: id, delta: 0);
      await SyncQueueHelper.enqueueStockDelta(db, '123', 0);
      expect(await _queue(db), isEmpty);
    });

    test('stock delta: entityId = barcode', () async {
      await SyncQueueHelper.enqueueStockDelta(db, '8961', -3);
      final q = (await _queue(db)).first;
      expect(q['entityType'], 'product');
      expect(q['entityId'], '8961');
      expect(q['operation'], 'increment_stock');
    });

    test('deletePaymentsByReference: local delete + har row ka tombstone', () async {
      await db.execute('''CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT, reference TEXT NOT NULL,
        partyType TEXT, partyId INTEGER, amount REAL, serverId TEXT)''');
      await db.insert('payments', {'reference': 'INV-1', 'amount': 10.0, 'serverId': 'payment:AAAA-1'});
      await db.insert('payments', {'reference': 'INV-1', 'amount': 5.0});
      await db.insert('payments', {'reference': 'INV-2', 'amount': 7.0});
      await SyncQueueHelper.deletePaymentsByReference(db, 'INV-1');
      expect(await db.query('payments'), hasLength(1));
      final q = await _queue(db);
      expect(q, hasLength(2));
      expect(q.every((r) => r['operation'] == 'delete' && r['entityType'] == 'payment'), isTrue);
      expect(q.first['entityId'], 'payment:AAAA-1');
    });
  });

  group('enqueueLegacy', () {
    test('sale: invoice se row padhta hai, purani payload ignore', () async {
      await db.insert('sales', {'invoice': 'INV-5', 'customerId': null});
      await db.execute('CREATE TABLE sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice TEXT NOT NULL)');
      await SyncQueueHelper.enqueueLegacy(db, 'sale', 'INV-5', 'create', {'junk': true});
      final q = (await _queue(db)).first;
      expect(q['entityId'], 'sale:INV-5');
      expect(_payload(q).containsKey('junk'), isFalse);
    });

    test('increment_balance customer: numeric id => delta', () async {
      final id = await db.insert('customers', {'name': 'Ali'});
      await SyncQueueHelper.enqueueLegacy(db, 'customer', '$id', 'increment_balance', {'delta': 40.0});
      final q = (await _queue(db)).first;
      expect(q['operation'], 'increment_balance');
      expect(_payload(q)['delta'], 40.0);
    });

    test('delete: maujooda row ki asal serverId', () async {
      final id = await db.insert('customers', {'name': 'Ali', 'serverId': 'customer:QQQQ-2'});
      await SyncQueueHelper.enqueueLegacy(db, 'customer', '$id', 'delete', {});
      final q = (await _queue(db)).first;
      expect(q['operation'], 'delete');
      expect(q['entityId'], 'customer:QQQQ-2');
    });

    test('anjaan type: kuch nahi', () async {
      await SyncQueueHelper.enqueueLegacy(db, 'martian', '1', 'create', {});
      expect(await _queue(db), isEmpty);
    });
  });

  group('trigger debounce', () {
    test('burst mein sirf ek baar onQueued', () async {
      var calls = 0;
      SyncQueueHelper.onQueued = () => calls++;
      SyncQueueHelper.triggerDelay = const Duration(milliseconds: 30);
      await SyncQueueHelper.enqueueStockDelta(db, 'a', 1);
      await SyncQueueHelper.enqueueStockDelta(db, 'b', 1);
      await SyncQueueHelper.enqueueStockDelta(db, 'c', 1);
      expect(calls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(calls, 1);
      SyncQueueHelper.triggerDelay = const Duration(seconds: 2);
    });
  });

  group('repairs', () {
    test('mergeOwnDuplicateExpenses: bina serverId wali twin ko original ki serverId', () async {
      final prefix = 'expense:${DeviceTag.current}-';
      final base = {'category': 'Tea', 'description': 'chai', 'amount': 30.0, 'method': 'cash', 'createdAt': 77};
      await db.insert('expenses', {...base, 'serverId': '${prefix}1', 'updatedAt': 5, 'dirty': 0});
      await db.insert('expenses', {...base, 'updatedAt': 9});
      final merged = await SyncQueueHelper.mergeOwnDuplicateExpenses(db);
      expect(merged, 1);
      final rows = await db.query('expenses');
      expect(rows, hasLength(1));
      expect(rows.first['serverId'], '${prefix}1');
      expect(rows.first['updatedAt'], 9);
      expect(rows.first['dirty'], 0);
    });

    test('fixBackdatedCashTransactionDates: bill ki tareekh, dirty + enqueue', () async {
      await db.insert('sales', {'invoice': 'INV-9', 'createdAt': 100});
      await db.insert('cash_transactions',
          {'type': 'in', 'amount': 50.0, 'reason': 'Sale', 'reference': 'INV-9', 'createdAt': 999});
      await db.insert('cash_transactions',
          {'type': 'in', 'amount': 10.0, 'reason': 'Manual', 'reference': 'x', 'createdAt': 999});
      final fixed = await SyncQueueHelper.fixBackdatedCashTransactionDates(db);
      expect(fixed, 1);
      final rows = await db.query('cash_transactions', orderBy: 'id');
      expect(rows.first['createdAt'], 100);
      expect(rows.first['dirty'], 1);
      expect(rows.last['createdAt'], 999);
      expect((await _queue(db)).where((r) => r['entityType'] == 'cash_transaction'), hasLength(1));
      // Dobara chalane par kuch nahi badalta.
      expect(await SyncQueueHelper.fixBackdatedCashTransactionDates(db), 0);
    });
  });
}
