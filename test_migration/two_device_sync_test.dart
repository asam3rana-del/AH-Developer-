import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/sync/sync_apply.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_dao.dart';
import 'package:ah_developer_kiryana_store/sync/sync_repository.dart';
import 'package:ah_developer_kiryana_store/sync/sync_types.dart';

/// Multi-device sync tests (improvement plan P1 #6): TWO phones, each with its own local database and its own
/// sync checkpoint, talking to ONE in-memory "cloud". Everything except Firestore itself is the real code:
/// SyncRepository.syncNow (push loop, retry rules, pull, checkpoint), SyncQueueDao, the push decisions
/// (planIncrement / stampPayload / shouldApplyUpsert) and applyServerChangesToDb (pending deltas on top of cloud).
/// NOT YET RUN - lives outside test/ so a failure cannot block release builds.
Future<String> _fakeHash(String p) async => 'hash($p)';

const _sync = 'updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1';

Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
  await x('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', creditLimit REAL NOT NULL DEFAULT 0, openingBalance REAL NOT NULL DEFAULT 0,
    balance REAL NOT NULL DEFAULT 0, stuckBalance REAL NOT NULL DEFAULT 0, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', openingBalance REAL NOT NULL DEFAULT 0, balance REAL NOT NULL DEFAULT 0,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE products (barcode TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0, salePrice REAL NOT NULL DEFAULT 0,
    stock REAL NOT NULL DEFAULT 0, reorderLevel REAL NOT NULL DEFAULT 0, expiry TEXT NOT NULL DEFAULT '',
    unit TEXT NOT NULL DEFAULT 'pcs', unitSize INTEGER NOT NULL DEFAULT 1, unitNote TEXT NOT NULL DEFAULT '',
    secondaryUnit TEXT NOT NULL DEFAULT '', secondaryUnitQty REAL NOT NULL DEFAULT 0,
    wholesalePrice REAL NOT NULL DEFAULT 0, openingStock REAL NOT NULL DEFAULT 0,
    tertiaryUnit TEXT NOT NULL DEFAULT '', tertiaryUnitQty REAL NOT NULL DEFAULT 0,
    $_sync, searchTag TEXT NOT NULL DEFAULT '',
    defaultUnitIndex INTEGER NOT NULL DEFAULT -1, quickSaleDefaultUnitIndex INTEGER NOT NULL DEFAULT -1)''');
  await x('''CREATE TABLE users (username TEXT PRIMARY KEY NOT NULL, displayName TEXT NOT NULL,
    role TEXT NOT NULL, passwordHash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
    phone TEXT NOT NULL DEFAULT '', permissions TEXT NOT NULL DEFAULT '')''');
  await x('''CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL,
    action TEXT NOT NULL, reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL)''');
  await x('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
    entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
    syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  await x('''CREATE TABLE sales (invoice TEXT PRIMARY KEY NOT NULL, customerId INTEGER, subtotal REAL NOT NULL,
    discount REAL NOT NULL, tax REAL NOT NULL, total REAL NOT NULL, paid REAL NOT NULL,
    paymentMethod TEXT NOT NULL, saleType TEXT NOT NULL DEFAULT 'retail', createdAt INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active', $_sync, dueDate INTEGER NOT NULL DEFAULT 0, customerServerId TEXT)''');
  await x('''CREATE TABLE sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice TEXT NOT NULL,
    barcode TEXT NOT NULL, product TEXT NOT NULL, qty REAL NOT NULL, unit TEXT NOT NULL DEFAULT '',
    unitPrice REAL NOT NULL, cost REAL NOT NULL, amount REAL NOT NULL, conversionFactor REAL NOT NULL DEFAULT 0,
    pendingQty REAL NOT NULL DEFAULT 0, pendingEst REAL NOT NULL DEFAULT 0, backfillLog TEXT NOT NULL DEFAULT '')''');
  await x('''CREATE TABLE purchases (billNo TEXT PRIMARY KEY NOT NULL, supplierId INTEGER, total REAL NOT NULL,
    paid REAL NOT NULL, createdAt INTEGER NOT NULL, subtotal REAL NOT NULL DEFAULT 0,
    discount REAL NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'active', $_sync,
    dueDate INTEGER NOT NULL DEFAULT 0, supplierInvoiceNo TEXT NOT NULL DEFAULT '', supplierServerId TEXT)''');
  await x('''CREATE TABLE purchase_items (id INTEGER PRIMARY KEY AUTOINCREMENT, billNo TEXT NOT NULL,
    barcode TEXT NOT NULL, qty REAL NOT NULL, unitCost REAL NOT NULL, amount REAL NOT NULL,
    unit TEXT NOT NULL DEFAULT '', conversionFactor REAL NOT NULL DEFAULT 0, itemName TEXT NOT NULL DEFAULT '',
    retailRate REAL NOT NULL DEFAULT 0, wholesaleRate REAL NOT NULL DEFAULT 0,
    shopkeeperRate REAL NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT, reference TEXT NOT NULL,
    partyType TEXT NOT NULL, partyId INTEGER, amount REAL NOT NULL, method TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync,
    billReference TEXT NOT NULL DEFAULT '', partyServerId TEXT)''');
  await x('''CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
    description TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE cash_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
    method TEXT NOT NULL, amount REAL NOT NULL, reason TEXT NOT NULL DEFAULT '',
    reference TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('CREATE TABLE units (name TEXT PRIMARY KEY NOT NULL)');
  await x('CREATE TABLE categories (name TEXT PRIMARY KEY NOT NULL)');
  await x('''CREATE TABLE returns (id INTEGER PRIMARY KEY AUTOINCREMENT, reference TEXT NOT NULL,
    type TEXT NOT NULL, barcode TEXT NOT NULL, qty REAL NOT NULL, amount REAL NOT NULL,
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE stock_movements (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT NOT NULL,
    type TEXT NOT NULL, qty REAL NOT NULL, unit TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0,
    reference TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE zakat_years (id INTEGER PRIMARY KEY AUTOINCREMENT, startDate INTEGER NOT NULL,
    endDate INTEGER NOT NULL, assetsSnapshot REAL NOT NULL, totalPayable REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'Rs', calendarType TEXT NOT NULL DEFAULT 'islamic',
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE zakat_payments (id INTEGER PRIMARY KEY AUTOINCREMENT, zakatYearId INTEGER NOT NULL,
    amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash', note TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT '', paymentDate INTEGER NOT NULL, createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shell_customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', shellsOwed INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shell_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, customerId INTEGER NOT NULL,
    type TEXT NOT NULL, qty INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shop_empty_shell_log (id INTEGER PRIMARY KEY AUTOINCREMENT, delta INTEGER NOT NULL,
    reason TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shop_rents (id INTEGER PRIMARY KEY AUTOINCREMENT, shopName TEXT NOT NULL,
    landlord TEXT NOT NULL DEFAULT '', phone TEXT NOT NULL DEFAULT '', dueDay INTEGER NOT NULL DEFAULT 1,
    startYm TEXT NOT NULL, autoApply INTEGER NOT NULL DEFAULT 1, active INTEGER NOT NULL DEFAULT 1,
    note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL DEFAULT 0, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE shop_rent_terms (shopId INTEGER NOT NULL, fromYm TEXT NOT NULL,
    monthlyRent REAL NOT NULL, PRIMARY KEY (shopId, fromYm))''');
  await x('''CREATE TABLE shop_rent_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, shopId INTEGER NOT NULL,
    kind TEXT NOT NULL, ym TEXT NOT NULL DEFAULT '', amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    note TEXT NOT NULL DEFAULT '', expenseId INTEGER, cashId INTEGER, createdAt INTEGER NOT NULL DEFAULT 0,
    serverId TEXT, expenseServerId TEXT, cashServerId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0)''');
  await x("CREATE UNIQUE INDEX index_shop_rent_charge ON shop_rent_ledger (shopId, ym) WHERE kind = 'charge'");
  await x('CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
  await x('''CREATE TABLE cash_register (date TEXT PRIMARY KEY NOT NULL, openingCash REAL NOT NULL DEFAULT 0,
    closingCash REAL NOT NULL DEFAULT 0, openingBank REAL NOT NULL DEFAULT 0,
    closingBank REAL NOT NULL DEFAULT 0, closed INTEGER NOT NULL DEFAULT 0)''');
  return db;
}

/// Virtual clock (ms). Every sync moves it forward one minute, so the pull overlap window re-delivers recent
/// documents on later syncs exactly like production does (apply must be idempotent).
int _clock = 2000000000000;

/// One in-memory cloud shared by all phones.
class FakeCloud {
  final Map<String, Map<String, Map<String, Object?>>> docs = {};
  static const branch = 'b1';

  void seed(String collection, String id, Map<String, Object?> doc) {
    docs.putIfAbsent(collection, () => {})[id] = {...doc, 'updatedAt': _clock, 'branchId': branch, '_deleted': false};
  }

  Map<String, Object?>? doc(String collection, String id) => docs[collection]?[id];
  double number(String collection, String id, String field) => (doc(collection, id)![field] as num).toDouble();
}

class Phone {
  final String tag;
  final Database db;
  int checkpoint = 0;
  bool online = true;
  bool loseNextReply = false;
  bool pushDown = false; // pushes fail, pulls still work
  Phone(this.tag, this.db);
}

class PhoneBackend implements SyncBackend {
  final FakeCloud cloud;
  final Phone phone;
  PhoneBackend(this.cloud, this.phone);

  @override
  Future<bool> push(SyncQueueEntry entry) async {
    if (!phone.online || phone.pushDown) throw const SyncOfflineException('no internet');
    final collection = collectionFor(entry.entityType);
    if (collection == null) throw SyncPushException('Unknown entity type: ${entry.entityType}');
    final col = cloud.docs.putIfAbsent(collection, () => {});
    final snap = col[entry.entityId];
    final ts = _clock;
    switch (entry.operation) {
      case 'increment_stock':
      case 'increment_balance':
        final delta = (decodePayload(entry.payloadJson)['delta'] as num).toDouble();
        final plan = planIncrement(
          exists: snap != null,
          data: snap,
          operation: entry.operation,
          delta: delta,
          updatedAtValue: ts,
          branchId: FakeCloud.branch,
          opId: buildOpId(phone.tag, entry.id, entry.createdAt),
          nowTs: ts,
          entityId: entry.entityId,
          seedFields: const {},
        );
        if (!plan.skip) {
          final cur = (snap?[plan.incrementField] as num?)?.toDouble() ?? 0.0;
          col[entry.entityId] = {...?snap, plan.incrementField: cur + plan.delta, ...plan.otherFields, 'pushedAt': ts};
        }
      case 'upsert':
        final st = stampPayload(decodePayload(entry.payloadJson), FakeCloud.branch, ts);
        if (shouldApplyUpsert(st.incomingUpdatedAt, upsertClock(snap))) {
          col[entry.entityId] = {...?snap, ...st.map, 'upsertAt': st.incomingUpdatedAt, 'pushedAt': ts};
        }
      case 'delete':
        if (shouldApplyDelete(ts, asMillis(snap?['updatedAt']))) {
          col[entry.entityId] = {...?snap, ...tombstone(entry.entityId, ts, FakeCloud.branch), 'pushedAt': ts};
        }
      default:
        return false;
    }
    if (phone.loseNextReply) {
      phone.loseNextReply = false;
      // The cloud APPLIED it, but the phone never heard back (dropped connection after the write).
      throw TimeoutException('reply lost');
    }
    return true;
  }

  @override
  Future<PullResult> pull(int since) async {
    if (!phone.online) throw const SyncOfflineException('no internet');
    final byCollection = <String, List<SyncDoc>>{};
    cloud.docs.forEach((collection, rows) {
      final overlap = stockPullCollections.contains(collection) ? stockPullOverlapMs : pullOverlapMs;
      for (final d in rows.values) {
        final t = asMillis(d['updatedAt']) ?? 0;
        if (t > since - overlap) byCollection.putIfAbsent(collection, () => []).add({...d});
      }
    });
    return assemblePullResult(byCollection, since, nowMs: _clock);
  }

  @override
  Future<void> applyServerChanges(Database db, PullResult changes) =>
      applyServerChangesToDb(db, changes, hashPassword: _fakeHash, nowMs: () => _clock);

  @override
  bool isPermissionDenied(Object e) => false;

  @override
  String permissionDeniedMessage() => 'denied';
}

Future<SyncResult> _syncPhone(FakeCloud cloud, Phone p) async {
  _clock += 60000;
  SyncRepository.openDb = () async => p.db;
  SyncRepository.backend = PhoneBackend(cloud, p);
  await SyncRepository.resetSyncCheckpoint(p.checkpoint);
  final r = await SyncRepository.syncNow();
  p.checkpoint = await SyncRepository.lastSyncTime();
  return r;
}

/// A bill on this phone: local balance/stock change + the queue entry the app writes for it.
Future<void> _billCustomer(Phone p, double amount) async {
  await p.db.rawUpdate('UPDATE customers SET balance = balance + ? WHERE serverId = ?', [amount, 'C1']);
  await SyncQueueDao(p.db).enqueue(SyncQueueEntry(
    entityType: 'customer',
    entityId: 'C1',
    operation: 'increment_balance',
    payloadJson: jsonEncode({'delta': amount, 'updatedAt': _clock, 'branchId': FakeCloud.branch}),
    createdAt: _clock++,
  ));
}

Future<void> _sellProduct(Phone p, double qty) async {
  await p.db.rawUpdate('UPDATE products SET stock = stock - ? WHERE barcode = ?', [qty, 'P1']);
  await SyncQueueDao(p.db).enqueue(SyncQueueEntry(
    entityType: 'product',
    entityId: 'P1',
    operation: 'increment_stock',
    payloadJson: jsonEncode({'delta': -qty, 'updatedAt': _clock, 'branchId': FakeCloud.branch}),
    createdAt: _clock++,
  ));
}

Future<double> _balance(Phone p) async =>
    ((await p.db.query('customers', where: 'serverId = ?', whereArgs: ['C1'])).single['balance'] as num).toDouble();

Future<double> _stock(Phone p) async =>
    ((await p.db.query('products', where: 'barcode = ?', whereArgs: ['P1'])).single['stock'] as num).toDouble();

Future<int> _pendingCount(Phone p) async => (await SyncQueueDao(p.db).pending()).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeCloud cloud;
  late Phone a;
  late Phone b;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _clock = 2000000000000;
    SyncRepository.isCloudReady = () async => true;
    SyncRepository.afterApply = null;
    SyncRepository.nowMs = () => _clock;
    cloud = FakeCloud()
      ..seed('customers', 'C1', {'serverId': 'C1', 'name': 'Ali', 'phone': '', 'balance': 1000.0})
      ..seed('products', 'P1', {'serverId': 'P1', 'barcode': 'P1', 'name': 'Rice', 'stock': 10.0});
    a = Phone('AAAA', await _memDb());
    b = Phone('BBBB', await _memDb());
    // Both phones start in sync with the cloud.
    await _syncPhone(cloud, a);
    await _syncPhone(cloud, b);
    expect(await _balance(a), 1000);
    expect(await _balance(b), 1000);
    expect(await _stock(a), 10);
    expect(await _stock(b), 10);
  });

  tearDown(() async {
    SyncRepository.backend = null;
    await a.db.close();
    await b.db.close();
  });

  test('two phones bill the same customer while offline: after syncing, cloud and both phones agree (opening + both bills)', () async {
    a.online = false;
    b.online = false;
    await _billCustomer(a, 100);
    await _billCustomer(b, 50);
    expect(await _balance(a), 1100);
    expect(await _balance(b), 1050);

    a.online = true;
    await _syncPhone(cloud, a);
    b.online = true;
    await _syncPhone(cloud, b);
    await _syncPhone(cloud, a);

    expect(cloud.number('customers', 'C1', 'balance'), 1150);
    expect(await _balance(a), 1150);
    expect(await _balance(b), 1150);
    expect(await _pendingCount(a), 0);
    expect(await _pendingCount(b), 0);
  });

  test('two phones sell the same product while offline: stock is cloud 10 - 2 - 3 = 5 everywhere', () async {
    a.online = false;
    b.online = false;
    await _sellProduct(a, 2);
    await _sellProduct(b, 3);

    a.online = true;
    b.online = true;
    await _syncPhone(cloud, a);
    await _syncPhone(cloud, b);
    await _syncPhone(cloud, a);

    expect(cloud.number('products', 'P1', 'stock'), 5);
    expect(await _stock(a), 5);
    expect(await _stock(b), 5);
  });

  test('offline phone keeps its bill with retryCount 0, then it is counted exactly once after reconnecting', () async {
    b.online = false;
    await _billCustomer(b, 70);
    final failed = await _syncPhone(cloud, b);
    expect(failed.pulledOk, isFalse);
    final stuck = (await SyncQueueDao(b.db).pending()).single;
    expect(stuck.retryCount, 0, reason: 'offline must not use up the retries');
    expect(await _balance(b), 1070, reason: 'the bill stays on the phone while offline');

    await _billCustomer(a, 30);
    await _syncPhone(cloud, a);
    expect(cloud.number('customers', 'C1', 'balance'), 1030);

    b.online = true;
    await _syncPhone(cloud, b);
    await _syncPhone(cloud, a);

    expect(cloud.number('customers', 'C1', 'balance'), 1100);
    expect(await _balance(a), 1100);
    expect(await _balance(b), 1100);
  });

  test('cloud applied the push but the reply was lost: the retry does not add the bill twice', () async {
    await _billCustomer(a, 100);
    a.loseNextReply = true;
    await _syncPhone(cloud, a);
    expect(cloud.number('customers', 'C1', 'balance'), 1100, reason: 'the cloud did apply it once');
    expect(await _pendingCount(a), 1, reason: 'the phone never heard back, so it still thinks it is pending');

    await _syncPhone(cloud, a); // retry of the same queue entry
    expect(cloud.number('customers', 'C1', 'balance'), 1100, reason: 'same opId must be skipped');
    expect(await _pendingCount(a), 0);

    await _syncPhone(cloud, b);
    expect(await _balance(a), 1100);
    expect(await _balance(b), 1100);
  });

  test('syncing again and again changes nothing (apply is idempotent while the pull window overlaps)', () async {
    await _billCustomer(a, 100);
    await _sellProduct(a, 2);
    await _billCustomer(b, 25);
    for (var i = 0; i < 3; i++) {
      await _syncPhone(cloud, a);
      await _syncPhone(cloud, b);
    }
    expect(cloud.number('customers', 'C1', 'balance'), 1125);
    expect(cloud.number('products', 'P1', 'stock'), 8);
    expect(await _balance(a), 1125);
    expect(await _balance(b), 1125);
    expect(await _stock(a), 8);
    expect(await _stock(b), 8);
  });

  test('phone with an unsent bill pulls the other phone\'s bill first: cloud + own pending, nothing lost, nothing doubled', () async {
    await _billCustomer(b, 40);
    await _billCustomer(a, 100);
    await _syncPhone(cloud, a);
    expect(cloud.number('customers', 'C1', 'balance'), 1100);

    b.pushDown = true; // B can pull but not push
    await _syncPhone(cloud, b);
    expect(await _balance(b), 1140, reason: 'cloud 1100 + own pending 40');
    expect(await _pendingCount(b), 1);

    b.pushDown = false;
    await _syncPhone(cloud, b);
    expect(cloud.number('customers', 'C1', 'balance'), 1140);
    expect(await _balance(b), 1140);

    await _syncPhone(cloud, a);
    expect(await _balance(a), 1140);
  });
}
