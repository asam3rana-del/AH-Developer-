import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/sync_apply.dart' show relinkOrphanedParties;
import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

/// Due Reminders follow-up sync: enqueue (payload + entity id + party serverId) aur pull apply
/// (insert / update / tombstone / pending edit / purani copy / party baad mein aana).
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
  await x('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', balance REAL NOT NULL DEFAULT 0, serverId TEXT)''');
  await x('''CREATE TABLE due_followups (id INTEGER PRIMARY KEY AUTOINCREMENT, partyId INTEGER NOT NULL,
    partyName TEXT NOT NULL DEFAULT '', method TEXT NOT NULL DEFAULT 'note', outcome TEXT NOT NULL DEFAULT 'note',
    amount REAL NOT NULL DEFAULT 0, promiseDate INTEGER NOT NULL DEFAULT 0, nextFollowUp INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '', staff TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL DEFAULT 0, serverId TEXT, partyServerId TEXT)''');
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

  Map<String, Object?> doc(String serverId, {String? partySid, String outcome = 'promised', int updatedAt = 10, Map<String, Object?> extra = const {}}) => {
        'serverId': serverId,
        'partyServerId': partySid,
        'partyName': 'Zulafqar Fruit Shop',
        'method': 'call',
        'outcome': outcome,
        'amount': 5000,
        'promiseDate': 1700000000000,
        'nextFollowUp': 1700086400000,
        'note': 'kal dega',
        'staff': 'admin',
        'createdAt': 7,
        'updatedAt': updatedAt,
        ...extra,
      };

  group('collections', () {
    test('push + pull + branch cleanup mein due_followups', () {
      expect(collectionFor('due_followup'), 'due_followups');
      expect(pullCollections.contains('due_followups'), isTrue);
      expect(branchScopedCollections.contains('due_followups'), isTrue);
      final r = assemblePullResult({
        'due_followups': [{'serverId': 'f', 'updatedAt': 70}],
      }, 0);
      expect(r.dueFollowups.length, 1);
      expect(r.serverTime, 70);
    });
  });

  group('enqueue', () {
    test('enqueueDueFollowup: payload, party serverId aur row par serverId', () async {
      final cid = await db.insert('customers', {'name': 'Zulafqar', 'serverId': 'customer:AB-3'});
      final id = await db.insert('due_followups', {
        'partyId': cid, 'partyName': 'Zulafqar', 'method': 'whatsapp', 'outcome': 'promised', 'amount': 2500.0,
        'promiseDate': 1700000000000, 'nextFollowUp': 1700086400000, 'note': 'Friday', 'staff': 'admin', 'createdAt': 7,
      });
      await SyncQueueHelper.enqueueDueFollowup(db, id);
      final q = await _queue(db);
      expect(q.single['entityType'], 'due_followup');
      expect(q.single['operation'], 'upsert');
      final p = _payload(q.single);
      expect(p['partyServerId'], 'customer:AB-3');
      expect(p['method'], 'whatsapp');
      expect(p['outcome'], 'promised');
      expect(p['amount'], 2500);
      expect(p['promiseDate'], 1700000000000);
      expect(p['nextFollowUp'], 1700086400000);
      expect(p['branchId'], 'main-branch');
      expect(p['_deleted'], false);
      expect(p.containsKey('partyId'), isFalse); // local id doosre device par bekaar
      final row = (await db.query('due_followups')).single;
      expect(row['serverId'], q.single['entityId']);
      expect(row['partyServerId'], 'customer:AB-3');
    });

    test('party par serverId nahi => party ki apni (customer:<tag>-<id>) id jati hai', () async {
      final cid = await db.insert('customers', {'name': 'Naya'});
      final id = await db.insert('due_followups', {'partyId': cid, 'createdAt': 7});
      await SyncQueueHelper.enqueueDueFollowup(db, id);
      final p = _payload((await _queue(db)).single);
      expect((p['partyServerId'] as String).startsWith('customer:'), isTrue);
      expect((p['partyServerId'] as String).endsWith('-$cid'), isTrue);
    });

    test('doosre device se aayi entry edit ho to wahi serverId (duplicate doc nahi)', () async {
      final id = await db.insert('due_followups', {'partyId': 1, 'createdAt': 7, 'serverId': 'due_followup:XY-5'});
      await SyncQueueHelper.enqueueDueFollowup(db, id);
      expect((await _queue(db)).single['entityId'], 'due_followup:XY-5');
      expect(await SyncQueueHelper.dueFollowupEntityIdFor(db, id), 'due_followup:XY-5');
    });

    test('enqueueAllDueFollowups(onlyUnsynced): serverId wali dobara push nahi', () async {
      await db.insert('due_followups', {'partyId': 1, 'createdAt': 1, 'serverId': 'due_followup:X-1'});
      await db.insert('due_followups', {'partyId': 1, 'createdAt': 2});
      await SyncQueueHelper.enqueueAllDueFollowups(db, onlyUnsynced: true);
      expect((await _queue(db)).length, 1);
      await SyncQueueHelper.enqueueAllDueFollowups(db);
      expect((await _queue(db)).length, 3); // pehli ek + ab 2 nayi (queue dedupe nahi karti)
    });

    test('enqueueDelete + legacy adapter: due_followup type pehchana jata hai', () async {
      await SyncQueueHelper.enqueueDelete(db, 'due_followup', 'due_followup:X-9');
      final q = await _queue(db);
      expect(q.single['operation'], 'delete');
      expect(collectionFor(q.single['entityType'] as String), 'due_followups');
    });
  });

  group('apply', () {
    test('nayi entry insert: party serverId se local customer se judti hai', () async {
      final cid = await db.insert('customers', {'name': 'Zulafqar', 'serverId': 'customer:AB-3'});
      await applyDueFollowups(db, [doc('due_followup:AB-1', partySid: 'customer:AB-3')], nowMs: () => 5000);
      final row = (await db.query('due_followups')).single;
      expect(row['partyId'], cid);
      expect(row['partyServerId'], 'customer:AB-3');
      expect(row['serverId'], 'due_followup:AB-1');
      expect(row['outcome'], 'promised');
      expect(row['method'], 'call');
      expect(row['amount'], 5000.0);
      expect(row['promiseDate'], 1700000000000);
      expect(row['nextFollowUp'], 1700086400000);
      expect(row['createdAt'], 7);
      expect(row['updatedAt'], 10);
    });

    test('anjaan method / outcome => note; serverId ya createdAt ke baghair doc chhod diya jata hai', () async {
      await applyDueFollowups(db, [
        doc('due_followup:A-1', extra: {'method': 'pigeon', 'outcome': 'weird'}),
        {'partyServerId': 'x', 'createdAt': 1},
        {'serverId': 'due_followup:A-2'},
      ], nowMs: () => 5000);
      final rows = await db.query('due_followups');
      expect(rows.length, 1);
      expect(rows.single['method'], 'note');
      expect(rows.single['outcome'], 'note');
    });

    test('dobara apply (pull overlap) idempotent: ek hi row', () async {
      final d = doc('due_followup:AB-1');
      await applyDueFollowups(db, [d], nowMs: () => 5000);
      await applyDueFollowups(db, [d], nowMs: () => 5000);
      expect((await db.query('due_followups')).length, 1);
    });

    test('naya nateeja (update) lagta hai; purani cloud copy naye local ko nahi dabati', () async {
      await applyDueFollowups(db, [doc('due_followup:AB-1', updatedAt: 10)], nowMs: () => 5000);
      await applyDueFollowups(db, [doc('due_followup:AB-1', updatedAt: 20, outcome: 'paid')], nowMs: () => 5000);
      var row = (await db.query('due_followups')).single;
      expect(row['outcome'], 'paid');
      expect(row['updatedAt'], 20);
      await applyDueFollowups(db, [doc('due_followup:AB-1', updatedAt: 15, outcome: 'refused')], nowMs: () => 5000);
      row = (await db.query('due_followups')).single;
      expect(row['outcome'], 'paid'); // purani (15) copy ne 20 ko nahi dabaya
    });

    test('is device ka unpushed edit cloud ki copy se overwrite nahi hota', () async {
      await applyDueFollowups(db, [doc('due_followup:AB-1', updatedAt: 10)], nowMs: () => 5000);
      final id = (await db.query('due_followups')).single['id'] as int;
      await db.update('due_followups', {'outcome': 'partial'}, where: 'id = ?', whereArgs: [id]);
      await SyncQueueHelper.enqueueDueFollowup(db, id); // pending upsert
      await applyDueFollowups(db, [doc('due_followup:AB-1', updatedAt: 99, outcome: 'refused')], nowMs: () => 5000);
      expect((await db.query('due_followups')).single['outcome'], 'partial');
    });

    test('tombstone (_deleted) entry hata deta hai; pending edit ho to nahi', () async {
      await applyDueFollowups(db, [doc('due_followup:AB-1'), doc('due_followup:AB-2')], nowMs: () => 5000);
      await applyDueFollowups(db, [{'serverId': 'due_followup:AB-1', '_deleted': true, 'updatedAt': 30}], nowMs: () => 5000);
      var rows = await db.query('due_followups');
      expect(rows.map((r) => r['serverId']).toList(), ['due_followup:AB-2']);
      // AB-2 par is device ka pending edit => cloud ka delete abhi na lage
      final id = rows.single['id'] as int;
      await SyncQueueHelper.enqueueDueFollowup(db, id);
      await applyDueFollowups(db, [{'serverId': 'due_followup:AB-2', '_deleted': true, 'updatedAt': 40}], nowMs: () => 5000);
      rows = await db.query('due_followups');
      expect(rows.length, 1);
    });

    test('party abhi nahi aayi => partyId 0; party aane par relinkOrphanedParties jod deta hai', () async {
      await applyDueFollowups(db, [doc('due_followup:AB-1', partySid: 'customer:AB-3')], nowMs: () => 5000);
      var row = (await db.query('due_followups')).single;
      expect(row['partyId'], 0);
      expect(row['partyServerId'], 'customer:AB-3');
      final cid = await db.insert('customers', {'name': 'Zulafqar', 'serverId': 'customer:AB-3'});
      // relink payments / sales / purchases bhi chalata hai: un tables ke baghair is test mein sirf follow-up wala hissa dekhna hai
      await db.execute('CREATE TABLE payments (id INTEGER PRIMARY KEY, partyId INTEGER, partyType TEXT, partyServerId TEXT)');
      await db.execute('CREATE TABLE sales (id INTEGER PRIMARY KEY, customerId INTEGER, customerServerId TEXT)');
      await db.execute('CREATE TABLE purchases (id INTEGER PRIMARY KEY, supplierId INTEGER, supplierServerId TEXT)');
      await db.execute('CREATE TABLE suppliers (id INTEGER PRIMARY KEY, serverId TEXT)');
      await relinkOrphanedParties(db);
      row = (await db.query('due_followups')).single;
      expect(row['partyId'], cid);
      // jori hui row dobara nahi chhoti
      await relinkOrphanedParties(db);
      expect((await db.query('due_followups')).single['partyId'], cid);
    });
  });
}
