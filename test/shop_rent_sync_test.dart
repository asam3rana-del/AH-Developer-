import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

/// Shop Rents sync: enqueue (payload + entity id) aur pull apply (insert / terms / link / tombstone / conflict).
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
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
  await x('''CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
    description TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    createdAt INTEGER NOT NULL, serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1)''');
  await x('CREATE TABLE cash_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, serverId TEXT)');
  await x('''CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL,
    action TEXT NOT NULL, reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL)''');
  await x('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
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

  Future<void> addShop(String serverId, {Map<String, Object?>? terms}) => applyShopRents(db, [
        {
          'serverId': serverId,
          'shopName': 'Shop A',
          'landlord': 'Malik',
          'startYm': '2026-10',
          'dueDay': 5,
          'terms': terms ?? {'2026-10': 15000},
          'updatedAt': 10,
        }
      ], nowMs: () => 5000);

  group('collections', () {
    test('push + pull mein shop_rents / shop_rent_ledger', () {
      expect(collectionFor('shop_rent'), 'shop_rents');
      expect(collectionFor('shop_rent_entry'), 'shop_rent_ledger');
      expect(pullCollections.contains('shop_rents'), isTrue);
      expect(pullCollections.contains('shop_rent_ledger'), isTrue);
      expect(branchScopedCollections.contains('shop_rents'), isTrue);
      expect(branchScopedCollections.contains('shop_rent_ledger'), isTrue);
      final r = assemblePullResult({
        'shop_rents': [{'serverId': 's', 'updatedAt': 50}],
        'shop_rent_ledger': [{'serverId': 'e', 'updatedAt': 60}],
      }, 0);
      expect(r.shopRents.length, 1);
      expect(r.shopRentEntries.length, 1);
      expect(r.serverTime, 60);
    });
  });

  group('entity ids', () {
    test('charge ki id dukaan + mahina (har device par ek jaisi); baqi _own', () {
      expect(SyncQueueHelper.shopRentChargeEntityId('shop_rent:AB-1', '2026-10'), 'shop_rent_charge:shop_rent:AB-1|2026-10');
      expect(
          SyncQueueHelper.shopRentEntryEntityId({'id': 1, 'kind': 'charge', 'ym': '2026-10'}, 'shop_rent:AB-1'),
          'shop_rent_charge:shop_rent:AB-1|2026-10');
      final pay = SyncQueueHelper.shopRentEntryEntityId({'id': 7, 'kind': 'payment', 'ym': '2026-10'}, 'shop_rent:AB-1');
      expect(pay.startsWith('shop_rent_entry:'), isTrue);
      expect(pay.endsWith('-7'), isTrue);
      expect(SyncQueueHelper.shopRentEntityId({'id': 2, 'serverId': 'shop_rent:XY-9'}), 'shop_rent:XY-9');
    });
  });

  group('enqueue', () {
    test('enqueueShopRent: terms payload mein, row par serverId', () async {
      final id = await db.insert('shop_rents', {'shopName': 'Shop A', 'startYm': '2026-10', 'createdAt': 7});
      await db.insert('shop_rent_terms', {'shopId': id, 'fromYm': '2026-10', 'monthlyRent': 15000.0});
      await db.insert('shop_rent_terms', {'shopId': id, 'fromYm': '2027-10', 'monthlyRent': 16500.0});
      await SyncQueueHelper.enqueueShopRent(db, id);
      final q = await _queue(db);
      expect(q.single['entityType'], 'shop_rent');
      expect(q.single['operation'], 'upsert');
      final p = _payload(q.single);
      expect(p['shopName'], 'Shop A');
      expect(p['terms'], {'2026-10': 15000, '2027-10': 16500});
      expect(p['branchId'], 'main-branch');
      expect(p['_deleted'], false);
      expect((await db.query('shop_rents')).single['serverId'], q.single['entityId']);
    });

    test('enqueueShopRentEntry: charge ki id mahine wali; payment expense serverId se judti hai', () async {
      final sid = await db.insert('shop_rents', {'shopName': 'Shop A', 'startYm': '2026-10'});
      await SyncQueueHelper.enqueueShopRent(db, sid);
      final shopSid = (await db.query('shop_rents')).single['serverId'] as String;

      final cid = await db.insert('shop_rent_ledger', {'shopId': sid, 'kind': 'charge', 'ym': '2026-10', 'amount': 15000.0});
      await SyncQueueHelper.enqueueShopRentEntry(db, cid);
      final eid = await db.insert('expenses', {
        'category': 'Rent', 'description': 'x', 'amount': 15000.0, 'createdAt': 1, 'serverId': 'expense:T-1',
      });
      final pid = await db.insert('shop_rent_ledger',
          {'shopId': sid, 'kind': 'payment', 'ym': '2026-10', 'amount': 15000.0, 'expenseId': eid});
      await SyncQueueHelper.enqueueShopRentEntry(db, pid);

      final q = (await _queue(db)).where((r) => r['entityType'] == 'shop_rent_entry').toList();
      expect(q.length, 2);
      expect(q[0]['entityId'], 'shop_rent_charge:$shopSid|2026-10');
      expect(_payload(q[0])['shopServerId'], shopSid);
      expect(_payload(q[1])['kind'], 'payment');
      expect(_payload(q[1])['expenseServerId'], 'expense:T-1');
      expect(await SyncQueueHelper.shopRentEntryEntityIdFor(db, cid), 'shop_rent_charge:$shopSid|2026-10');
    });

    test('enqueueAllShopRents(onlyUnsynced): jin par serverId hai unhein dobara push nahi karta', () async {
      final a = await db.insert('shop_rents', {'shopName': 'Old', 'startYm': '2026-10', 'serverId': 'shop_rent:X-1'});
      final b = await db.insert('shop_rents', {'shopName': 'Local', 'startYm': '2026-10'});
      await db.insert('shop_rent_ledger',
          {'shopId': a, 'kind': 'charge', 'ym': '2026-10', 'amount': 1.0, 'serverId': 'shop_rent_charge:shop_rent:X-1|2026-10'});
      await db.insert('shop_rent_ledger', {'shopId': b, 'kind': 'charge', 'ym': '2026-10', 'amount': 2.0});
      await SyncQueueHelper.enqueueAllShopRents(db, onlyUnsynced: true);
      final q = await _queue(db);
      expect(q.length, 2); // sirf Local dukaan + uska charge
      expect(q.map((r) => r['entityType']).toSet(), {'shop_rent', 'shop_rent_entry'});
      expect(_payload(q.first)['shopName'], 'Local');
    });
  });

  group('apply: shop_rents', () {
    test('insert + terms; dobara aane par terms badal jate hain; tombstone par ledger samet hat jati hai', () async {
      await addShop('shop_rent:T-1');
      var shop = (await db.query('shop_rents')).single;
      expect(shop['shopName'], 'Shop A');
      expect(shop['dueDay'], 5);
      expect(shop['serverId'], 'shop_rent:T-1');
      expect((await db.query('shop_rent_terms')).single['monthlyRent'], 15000.0);

      await addShop('shop_rent:T-1', terms: {'2026-10': 15000, '2027-10': 16500});
      expect((await db.query('shop_rents')).length, 1);
      expect((await db.query('shop_rent_terms')).length, 2);

      await applyShopRentEntries(db, [
        {'serverId': 'shop_rent_charge:shop_rent:T-1|2026-10', 'shopServerId': 'shop_rent:T-1', 'kind': 'charge', 'ym': '2026-10', 'amount': 15000},
      ], nowMs: () => 5000);
      expect((await db.query('shop_rent_ledger')).length, 1);

      await applyShopRents(db, [
        {'serverId': 'shop_rent:T-1', '_deleted': true}
      ], nowMs: () => 5000);
      expect(await db.query('shop_rents'), isEmpty);
      expect(await db.query('shop_rent_terms'), isEmpty);
      expect(await db.query('shop_rent_ledger'), isEmpty);
    });

    test('is device ki anpushed tabdeeli server copy se overwrite nahi hoti', () async {
      await addShop('shop_rent:T-1');
      await db.update('shop_rents', {'shopName': 'Edited here'});
      await db.insert('sync_queue', {
        'entityType': 'shop_rent', 'entityId': 'shop_rent:T-1', 'operation': 'upsert',
        'payloadJson': '{}', 'createdAt': 1,
      });
      await addShop('shop_rent:T-1');
      expect((await db.query('shop_rents')).single['shopName'], 'Edited here');
    });
  });

  group('apply: shop_rent_ledger', () {
    Map<String, Object?> doc(String id, String kind, {String ym = '2026-10', Map<String, Object?>? extra}) => {
          'serverId': id,
          'shopServerId': 'shop_rent:T-1',
          'kind': kind,
          'ym': ym,
          'amount': 1000,
          'createdAt': 9,
          ...?extra,
        };

    test('is device par usi mahine ka charge (alag id) adopt hota hai, duplicate nahi banta', () async {
      await addShop('shop_rent:T-1');
      final sid = (await db.query('shop_rents')).single['id'] as int;
      await db.insert('shop_rent_ledger', {'shopId': sid, 'kind': 'charge', 'ym': '2026-10', 'amount': 15000.0});
      await applyShopRentEntries(db, [doc('shop_rent_charge:shop_rent:T-1|2026-10', 'charge', extra: {'amount': 16500})],
          nowMs: () => 5000);
      final rows = await db.query('shop_rent_ledger');
      expect(rows.length, 1);
      expect(rows.single['amount'], 16500.0);
      expect(rows.single['serverId'], 'shop_rent_charge:shop_rent:T-1|2026-10');
    });

    test('payment: expense serverId se link; expense baad mein aaye to agli pull par link ho jata hai', () async {
      await addShop('shop_rent:T-1');
      final payment = doc('shop_rent_entry:A-1', 'payment', extra: {'expenseServerId': 'expense:A-5'});
      await applyShopRentEntries(db, [payment], nowMs: () => 5000);
      var row = (await db.query('shop_rent_ledger')).single;
      expect(row['expenseId'], isNull);
      expect(row['expenseServerId'], 'expense:A-5');

      await db.insert('expenses',
          {'category': 'Rent', 'description': 'x', 'amount': 1000.0, 'createdAt': 1, 'serverId': 'expense:A-5'});
      await applyShopRentEntries(db, const [], nowMs: () => 5000);
      row = (await db.query('shop_rent_ledger')).single;
      expect(row['expenseId'], 1);
    });

    test('ek mahine ka doosra applied: chhod diya jata hai, audit mein sync_conflict', () async {
      await addShop('shop_rent:T-1');
      await applyShopRentEntries(db, [doc('shop_rent_entry:A-1', 'applied')], nowMs: () => 5000);
      await applyShopRentEntries(db, [doc('shop_rent_entry:B-1', 'applied')], nowMs: () => 5000);
      expect((await db.query('shop_rent_ledger')).length, 1);
      expect((await db.query('audit', where: 'action = ?', whereArgs: ['sync_conflict'])).length, 1);
    });

    test('dukaan na mile to entry chhod di jati hai; tombstone se entry hat jati hai', () async {
      await applyShopRentEntries(db, [doc('shop_rent_entry:A-1', 'payment')], nowMs: () => 5000);
      expect(await db.query('shop_rent_ledger'), isEmpty);
      await addShop('shop_rent:T-1');
      await applyShopRentEntries(db, [doc('shop_rent_entry:A-1', 'payment')], nowMs: () => 5000);
      expect((await db.query('shop_rent_ledger')).length, 1);
      await applyShopRentEntries(db, [
        {'serverId': 'shop_rent_entry:A-1', '_deleted': true}
      ], nowMs: () => 5000);
      expect(await db.query('shop_rent_ledger'), isEmpty);
    });
  });
}
