import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_seed_fields.dart';

/// Phase 10: SyncApi.push ke SAAF faisle (Firestore ke baghair) + seedFields. Asli Firestore
/// transactions device par test hongi (Firebase project chahiye).
void main() {
  sqfliteFfiInit();

  group('collectionFor / ops', () {
    test('20 entity types Kotlin jaise; anjaan => null', () {
      expect(pushCollections.length, 20);
      expect(collectionFor('customer'), 'customers');
      expect(collectionFor('cash_transaction'), 'cash_transactions');
      expect(collectionFor('cash_register'), 'cash_register');
      expect(collectionFor('shop_empty_shell_log'), 'shop_empty_shell_log');
      expect(collectionFor('return'), 'returns');
      expect(collectionFor('nonsense'), isNull);
    });

    test('increment field / op', () {
      expect(isIncrementOp('increment_stock'), isTrue);
      expect(isIncrementOp('increment_balance'), isTrue);
      expect(isIncrementOp('upsert'), isFalse);
      expect(incrementFieldFor('increment_stock'), 'stock');
      expect(incrementFieldFor('increment_balance'), 'balance');
    });
  });

  group('upsert / delete / create_if_absent', () {
    test('stampPayload: branch hamesha maujooda, updatedAt payload ka warna now', () {
      final a = stampPayload({'name': 'x', 'branchId': 'OLD', 'updatedAt': 500}, 'NEW', 9000);
      expect(a.map['branchId'], 'NEW');
      expect(a.map['updatedAt'], 500);
      expect(a.incomingUpdatedAt, 500);
      final b = stampPayload({'name': 'x'}, 'NEW', 9000);
      expect(b.incomingUpdatedAt, 9000);
      expect(b.map['updatedAt'], 9000);
      final c = stampPayload({'updatedAt': 12.0}, 'B', 1); // JSON double
      expect(c.incomingUpdatedAt, 12);
    });

    test('last-write-wins: barabar ya naya laagu, purana nahi; server par updatedAt nahi => laagu', () {
      expect(shouldApplyUpsert(100, 100), isTrue);
      expect(shouldApplyUpsert(101, 100), isTrue);
      expect(shouldApplyUpsert(99, 100), isFalse);
      expect(shouldApplyUpsert(1, null), isTrue);
      expect(shouldApplyDelete(100, 100), isTrue);
      expect(shouldApplyDelete(99, 100), isFalse);
      expect(shouldApplyDelete(0, null), isTrue);
    });

    test('tombstone shakl', () {
      expect(tombstone('customer:AB12-3', 777, 'MAIN'),
          {'serverId': 'customer:AB12-3', '_deleted': true, 'updatedAt': 777, 'branchId': 'MAIN'});
    });

    test('create_if_absent: na ho ya tombstone ho => likho; maujood => skip', () {
      expect(canCreateIfAbsent(exists: false, data: null), isTrue);
      expect(canCreateIfAbsent(exists: true, data: {'_deleted': true}), isTrue);
      expect(canCreateIfAbsent(exists: true, data: {'opening': 1}), isFalse);
      expect(canCreateIfAbsent(exists: true, data: {'_deleted': false}), isFalse);
    });

    test('decodePayload: object chahiye', () {
      expect(decodePayload('{"a":1,"b":"x"}'), {'a': 1, 'b': 'x'});
      expect(() => decodePayload('[1]'), throwsFormatException);
    });
  });

  group('increment plan', () {
    const day = 24 * 60 * 60 * 1000;

    test('opId format', () {
      expect(buildOpId('AB12', 7, 123456), 'AB12-7-123456');
    });

    test('opId pehle se laga hua => skip (retry dobara nahi lagta)', () {
      final p = planIncrement(
        exists: true,
        data: {'appliedOps': {'AB12-7-1': 5000}},
        operation: 'increment_balance',
        delta: 10,
        updatedAtValue: 1,
        branchId: 'B',
        opId: 'AB12-7-1',
        nowTs: 6000,
        entityId: 'customer:AB12-1',
        seedFields: {'name': 'Ali'},
      );
      expect(p.skip, isTrue);
    });

    test('maujood doc: sirf increment + updatedAt + branchId + appliedOps (identity nahi)', () {
      final p = planIncrement(
        exists: true,
        data: {'name': 'Ali', 'appliedOps': <String, Object?>{}},
        operation: 'increment_stock',
        delta: -3.5,
        updatedAtValue: 42,
        branchId: 'B',
        opId: 'T-1-9',
        nowTs: 1000,
        entityId: '111',
        seedFields: {'name': 'Ali'},
      );
      expect(p.skip, isFalse);
      expect(p.incrementField, 'stock');
      expect(p.delta, -3.5);
      expect(p.mergeFields, ['stock', 'updatedAt', 'branchId', 'appliedOps']);
      expect(p.otherFields['updatedAt'], 42);
      expect(p.otherFields['branchId'], 'B');
      expect(p.otherFields['appliedOps'], {'T-1-9': 1000});
      expect(p.otherFields.containsKey('name'), isFalse);
      expect(p.otherFields.containsKey('serverId'), isFalse);
    });

    test('naya doc: serverId + seed fields (ghost doc nahi banta)', () {
      final p = planIncrement(
        exists: false,
        data: null,
        operation: 'increment_balance',
        delta: 500,
        updatedAtValue: 1,
        branchId: 'B',
        opId: 'T-2-9',
        nowTs: 1000,
        entityId: 'customer:T-2',
        seedFields: {'name': 'Ali', 'phone': '0300'},
      );
      expect(p.incrementField, 'balance');
      expect(p.otherFields['serverId'], 'customer:T-2');
      expect(p.otherFields['name'], 'Ali');
      expect(p.otherFields['phone'], '0300');
      expect(p.otherFields.containsKey('_deleted'), isFalse);
      expect(p.mergeFields, containsAll(['balance', 'serverId', 'name', 'phone']));
    });

    test('tombstone wala doc "naya" hai: _deleted=false bhi likha jata hai', () {
      final p = planIncrement(
        exists: true,
        data: {'_deleted': true},
        operation: 'increment_stock',
        delta: 1,
        updatedAtValue: 1,
        branchId: 'B',
        opId: 'T-3-9',
        nowTs: 1000,
        entityId: 'P1',
        seedFields: {'name': 'Rice'},
      );
      expect(p.otherFields['_deleted'], false);
      expect(p.otherFields['serverId'], 'P1');
      expect(p.mergeFields, containsAll(['_deleted', 'serverId', 'name']));
    });

    test('pruneAppliedOps: 30 din se purani hatin, 999 tak, naya opId shamil', () {
      final now = 100 * day;
      final applied = <String, Object?>{
        'old': now - 31 * day,
        'edge': now - 30 * day,
        'recent': now - day,
        'junk': 'x',
      };
      final kept = pruneAppliedOps(applied, 'new', now);
      expect(kept.keys.toSet(), {'edge', 'recent', 'new'});
      expect(kept['new'], now);

      final many = <String, Object?>{for (var i = 0; i < 1200; i++) 'op$i': now - 1000 + i};
      final k2 = pruneAppliedOps(many, 'fresh', now);
      expect(k2.length, 1000);
      expect(k2.containsKey('fresh'), isTrue);
      expect(k2.containsKey('op0'), isFalse); // sab se purani gayi
      expect(k2.containsKey('op1199'), isTrue);
    });

    test('localIdFromOwnEntityId', () {
      expect(localIdFromOwnEntityId('customer:AB12-42', 'customer:', 'AB12'), 42);
      expect(localIdFromOwnEntityId('customer:ZZ99-42', 'customer:', 'AB12'), isNull);
      expect(localIdFromOwnEntityId('customer:AB12-x', 'customer:', 'AB12'), isNull);
      expect(localIdFromOwnEntityId('supplier:AB12-5', 'customer:', 'AB12'), isNull);
    });
  });

  group('loadSeedFields (sqflite)', () {
    late Database db;
    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, phone TEXT,
        creditLimit REAL, openingBalance REAL, balance REAL, stuckBalance REAL, serverId TEXT,
        updatedAt INTEGER, dirty INTEGER)''');
      await db.execute('''CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, phone TEXT,
        openingBalance REAL, balance REAL, serverId TEXT, updatedAt INTEGER, dirty INTEGER)''');
      await db.execute('''CREATE TABLE products (barcode TEXT PRIMARY KEY, name TEXT, category TEXT, cost REAL,
        salePrice REAL, stock REAL, reorderLevel REAL, expiry TEXT, unit TEXT, unitSize INTEGER, unitNote TEXT,
        secondaryUnit TEXT, secondaryUnitQty REAL, wholesalePrice REAL, tertiaryUnit TEXT, tertiaryUnitQty REAL,
        defaultUnitIndex INTEGER, quickSaleDefaultUnitIndex INTEGER, searchTag TEXT)''');
    });
    tearDown(() => db.close());

    test('customer serverId se mila', () async {
      await db.insert('customers', {
        'name': 'Ali', 'phone': '0300', 'creditLimit': 5000.0, 'openingBalance': 100.0,
        'balance': 250.0, 'stuckBalance': 7.0, 'serverId': 'customer:AB12-1',
      });
      final s = await loadSeedFields(db, entityType: 'customer', entityId: 'customer:AB12-1', deviceTag: 'AB12');
      expect(s, {
        'name': 'Ali', 'phone': '0300', 'creditLimit': 5000.0, 'openingBalance': 100.0, 'stuckBalance': 7.0,
      });
      expect(s.containsKey('balance'), isFalse); // incremented field kabhi seed nahi
    });

    test('serverId khali/purana: entityId se local id nikal kar dhoondta hai aur serverId theek karta hai', () async {
      await db.insert('suppliers', {'name': 'Bashir', 'phone': '0311', 'openingBalance': 9.0, 'balance': 0.0});
      final s = await loadSeedFields(db, entityType: 'supplier', entityId: 'supplier:AB12-1', deviceTag: 'AB12');
      expect(s, {'name': 'Bashir', 'phone': '0311', 'openingBalance': 9.0});
      final row = (await db.query('suppliers')).single;
      expect(row['serverId'], 'supplier:AB12-1');
    });

    test('kisi aur device ki ID + serverId nahi => khali (guess nahi)', () async {
      await db.insert('customers', {'name': 'Ali', 'phone': '', 'balance': 0.0});
      expect(await loadSeedFields(db, entityType: 'customer', entityId: 'customer:ZZ99-1', deviceTag: 'AB12'), isEmpty);
    });

    test('product barcode se, 17 fields', () async {
      await db.insert('products', {
        'barcode': '111', 'name': 'Rice', 'category': 'Grocery', 'cost': 90.0, 'salePrice': 100.0, 'stock': 5.0,
        'reorderLevel': 2.0, 'expiry': '', 'unit': 'kg', 'unitSize': 1, 'unitNote': '', 'secondaryUnit': 'bag',
        'secondaryUnitQty': 50.0, 'wholesalePrice': 95.0, 'tertiaryUnit': '', 'tertiaryUnitQty': 0.0,
        'defaultUnitIndex': -1, 'quickSaleDefaultUnitIndex': 0, 'searchTag': 'chawal',
      });
      final s = await loadSeedFields(db, entityType: 'product', entityId: '111');
      expect(s.length, 17);
      expect(s['name'], 'Rice');
      expect(s['searchTag'], 'chawal');
      expect(s.containsKey('stock'), isFalse);
      expect(await loadSeedFields(db, entityType: 'product', entityId: 'nope'), isEmpty);
      expect(await loadSeedFields(db, entityType: 'expense', entityId: 'x'), isEmpty);
    });
  });
}
