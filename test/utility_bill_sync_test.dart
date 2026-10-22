import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

/// Utility Bills sync: enqueue (payload + entity id) aur pull apply (insert / update / link / tombstone / conflict).
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
  await x('''CREATE TABLE utility_bills (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'other', dueDay INTEGER NOT NULL, avgAmount REAL NOT NULL DEFAULT 0,
    reminder INTEGER NOT NULL DEFAULT 1, active INTEGER NOT NULL DEFAULT 1, createdAt INTEGER NOT NULL DEFAULT 0,
    updatedAt INTEGER NOT NULL DEFAULT 0, serverId TEXT)''');
  await x('''CREATE TABLE utility_bill_payments (id INTEGER PRIMARY KEY AUTOINCREMENT, billId INTEGER NOT NULL,
    month TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash', note TEXT NOT NULL DEFAULT '',
    expenseId INTEGER, expenseServerId TEXT, paidAt INTEGER NOT NULL, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0, UNIQUE (billId, month))''');
  await x('''CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
    description TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    createdAt INTEGER NOT NULL, serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0,
    dirty INTEGER NOT NULL DEFAULT 1)''');
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

  Future<void> addBill(String serverId, {String name = 'LESCO', int dueDay = 10, String kind = 'electricity'}) =>
      applyUtilityBills(db, [
        {
          'serverId': serverId,
          'name': name,
          'kind': kind,
          'dueDay': dueDay,
          'avgAmount': 5000,
          'reminder': 1,
          'active': 1,
          'createdAt': 7,
          'updatedAt': 10,
        }
      ], nowMs: () => 5000);

  Map<String, Object?> payDoc(String billSid, String month, {String? serverId, String? expenseSid}) => {
        'serverId': serverId ?? 'utility_bill_payment:$billSid|$month',
        'billServerId': billSid,
        'month': month,
        'amount': 5200,
        'method': 'bank',
        'note': 'ref 1',
        'expenseServerId': expenseSid,
        'paidAt': 20,
        'updatedAt': 20,
      };

  group('collections', () {
    test('push + pull mein utility_bills / utility_bill_payments', () {
      expect(collectionFor('utility_bill'), 'utility_bills');
      expect(collectionFor('utility_bill_payment'), 'utility_bill_payments');
      expect(pullCollections.contains('utility_bills'), isTrue);
      expect(pullCollections.contains('utility_bill_payments'), isTrue);
      expect(branchScopedCollections.contains('utility_bills'), isTrue);
      expect(branchScopedCollections.contains('utility_bill_payments'), isTrue);
      final r = assemblePullResult({
        'utility_bills': [{'serverId': 'b', 'updatedAt': 50}],
        'utility_bill_payments': [{'serverId': 'p', 'updatedAt': 60}],
      }, 0);
      expect(r.utilityBills.length, 1);
      expect(r.utilityBillPayments.length, 1);
      expect(r.serverTime, 60);
    });
  });

  group('entity ids', () {
    test('payment ki id bill + mahina (har device par ek jaisi); bill _own', () {
      expect(SyncQueueHelper.utilityBillPaymentEntityId('utility_bill:AB-1', '2026-10'),
          'utility_bill_payment:utility_bill:AB-1|2026-10');
      expect(SyncQueueHelper.utilityBillEntityId({'id': 2, 'serverId': 'utility_bill:XY-9'}), 'utility_bill:XY-9');
      final own = SyncQueueHelper.utilityBillEntityId({'id': 4});
      expect(own.startsWith('utility_bill:'), isTrue);
      expect(own.endsWith('-4'), isTrue);
    });
  });

  group('enqueue', () {
    test('enqueueUtilityBill: payload aur row par serverId', () async {
      final id = await db.insert('utility_bills',
          {'name': 'SNGPL', 'kind': 'gas', 'dueDay': 15, 'avgAmount': 3000.0, 'createdAt': 7});
      await SyncQueueHelper.enqueueUtilityBill(db, id);
      final q = await _queue(db);
      expect(q.single['entityType'], 'utility_bill');
      expect(q.single['operation'], 'upsert');
      final p = _payload(q.single);
      expect(p['name'], 'SNGPL');
      expect(p['kind'], 'gas');
      expect(p['dueDay'], 15);
      expect(p['branchId'], 'main-branch');
      expect(p['_deleted'], false);
      expect((await db.query('utility_bills')).single['serverId'], q.single['entityId']);
    });

    test('payment: bill pehle queue hota hai, id bill+mahina, expense serverId se judti hai', () async {
      final bid = await db.insert('utility_bills', {'name': 'LESCO', 'dueDay': 10, 'createdAt': 7});
      final eid = await db.insert('expenses', {
        'category': 'Utility Bills', 'description': 'x', 'amount': 5200.0, 'createdAt': 1, 'serverId': 'expense:T-1',
      });
      final pid = await db.insert('utility_bill_payments', {
        'billId': bid, 'month': '2026-10', 'amount': 5200.0, 'method': 'cash', 'expenseId': eid, 'paidAt': 20,
      });
      await SyncQueueHelper.enqueueUtilityBillPayment(db, pid);
      final q = await _queue(db);
      expect(q.map((r) => r['entityType']).toList(), ['utility_bill', 'utility_bill_payment']);
      final billSid = (await db.query('utility_bills')).single['serverId'] as String;
      expect(q[1]['entityId'], 'utility_bill_payment:$billSid|2026-10');
      final p = _payload(q[1]);
      expect(p['billServerId'], billSid);
      expect(p['expenseServerId'], 'expense:T-1');
      expect(p['month'], '2026-10');
      expect(await SyncQueueHelper.utilityBillPaymentEntityIdFor(db, pid), 'utility_bill_payment:$billSid|2026-10');
    });

    test('enqueueAllUtilityBills(onlyUnsynced): jin par serverId hai unhein dobara push nahi karta', () async {
      final a = await db.insert('utility_bills', {'name': 'Old', 'dueDay': 1, 'serverId': 'utility_bill:X-1'});
      final b = await db.insert('utility_bills', {'name': 'Local', 'dueDay': 2});
      await db.insert('utility_bill_payments', {
        'billId': a, 'month': '2026-09', 'amount': 1.0, 'paidAt': 1,
        'serverId': 'utility_bill_payment:utility_bill:X-1|2026-09',
      });
      await db.insert('utility_bill_payments', {'billId': b, 'month': '2026-09', 'amount': 2.0, 'paidAt': 1});
      await SyncQueueHelper.enqueueAllUtilityBills(db, onlyUnsynced: true);
      final q = await _queue(db);
      expect(q.length, 2); // sirf Local bill + uski payment
      expect(q.map((r) => r['entityType']).toSet(), {'utility_bill', 'utility_bill_payment'});
      expect(_payload(q.first)['name'], 'Local');
    });
  });

  group('apply: utility_bills', () {
    test('insert, update, anjaan kind => other, dueDay clamp', () async {
      await addBill('utility_bill:T-1');
      var bill = (await db.query('utility_bills')).single;
      expect(bill['name'], 'LESCO');
      expect(bill['kind'], 'electricity');
      expect(bill['dueDay'], 10);
      expect(bill['serverId'], 'utility_bill:T-1');
      expect(bill['createdAt'], 7);

      await addBill('utility_bill:T-1', name: 'LESCO Shop', dueDay: 12);
      expect((await db.query('utility_bills')).length, 1);
      bill = (await db.query('utility_bills')).single;
      expect(bill['name'], 'LESCO Shop');
      expect(bill['dueDay'], 12);

      await addBill('utility_bill:T-2', name: 'Odd', dueDay: 99, kind: 'weird');
      final odd = (await db.query('utility_bills', where: 'serverId = ?', whereArgs: ['utility_bill:T-2'])).single;
      expect(odd['kind'], 'other');
      expect(odd['dueDay'], 31);
    });

    test('is device ki anpushed edit purani cloud copy se overwrite nahi hoti', () async {
      await addBill('utility_bill:T-1');
      await db.update('utility_bills', {'name': 'Mine'});
      await SyncQueueHelper.enqueueDelete(db, 'utility_bill', 'utility_bill:T-1'); // koi bhi pending entry
      await addBill('utility_bill:T-1', name: 'Cloud');
      expect((await db.query('utility_bills')).single['name'], 'Mine');
    });

    test('tombstone: bill aur uski payments hat jati hain, expense nahi', () async {
      await addBill('utility_bill:T-1');
      final eid = await db.insert('expenses',
          {'category': 'Utility Bills', 'description': 'x', 'amount': 5200.0, 'createdAt': 1, 'serverId': 'expense:T-1'});
      await applyUtilityBillPayments(db, [payDoc('utility_bill:T-1', '2026-10', expenseSid: 'expense:T-1')],
          nowMs: () => 5000);
      expect((await db.query('utility_bill_payments')).length, 1);
      await applyUtilityBills(db, [
        {'serverId': 'utility_bill:T-1', '_deleted': true}
      ], nowMs: () => 5000);
      expect(await db.query('utility_bills'), isEmpty);
      expect(await db.query('utility_bill_payments'), isEmpty);
      expect((await db.query('expenses', where: 'id = ?', whereArgs: [eid])).length, 1);
    });
  });

  group('apply: utility_bill_payments', () {
    test('insert: bill aur expense serverId se judte hain; dobara aane par duplicate nahi', () async {
      await addBill('utility_bill:T-1');
      final eid = await db.insert('expenses',
          {'category': 'Utility Bills', 'description': 'x', 'amount': 5200.0, 'createdAt': 1, 'serverId': 'expense:T-1'});
      final doc = payDoc('utility_bill:T-1', '2026-10', expenseSid: 'expense:T-1');
      await applyUtilityBillPayments(db, [doc], nowMs: () => 5000);
      await applyUtilityBillPayments(db, [doc], nowMs: () => 5000);
      final rows = await db.query('utility_bill_payments');
      expect(rows.length, 1);
      expect(rows.single['month'], '2026-10');
      expect(rows.single['amount'], 5200.0);
      expect(rows.single['method'], 'bank');
      expect(rows.single['expenseId'], eid);
      expect(rows.single['expenseServerId'], 'expense:T-1');
      expect(rows.single['serverId'], 'utility_bill_payment:utility_bill:T-1|2026-10');
    });

    test('bill na mile ya mahina ghalat ho to chhod di jati hai', () async {
      await applyUtilityBillPayments(db, [payDoc('utility_bill:NOPE', '2026-10')], nowMs: () => 5000);
      await addBill('utility_bill:T-1');
      await applyUtilityBillPayments(db, [payDoc('utility_bill:T-1', '2026-1x')], nowMs: () => 5000);
      expect(await db.query('utility_bill_payments'), isEmpty);
    });

    test('ek mahine ki doosri payment: chhod di jati hai, audit mein sync_conflict', () async {
      await addBill('utility_bill:T-1');
      final bid = (await db.query('utility_bills')).single['id'];
      await db.insert('utility_bill_payments', {
        'billId': bid, 'month': '2026-10', 'amount': 4800.0, 'paidAt': 1, 'serverId': 'utility_bill_payment:local-id',
      });
      await applyUtilityBillPayments(db, [payDoc('utility_bill:T-1', '2026-10')], nowMs: () => 5000);
      final rows = await db.query('utility_bill_payments');
      expect(rows.length, 1);
      expect(rows.single['amount'], 4800.0);
      expect((await db.query('audit', where: 'action = ?', whereArgs: ['sync_conflict'])).length, 1);
    });

    test('tombstone: payment hat jati hai; is device ka pending undo purani cloud copy se wapas nahi aata', () async {
      await addBill('utility_bill:T-1');
      final sid = 'utility_bill_payment:utility_bill:T-1|2026-10';
      await applyUtilityBillPayments(db, [payDoc('utility_bill:T-1', '2026-10')], nowMs: () => 5000);
      await applyUtilityBillPayments(db, [
        {'serverId': sid, '_deleted': true, 'updatedAt': 30}
      ], nowMs: () => 5000);
      expect(await db.query('utility_bill_payments'), isEmpty);

      // Local undo abhi push nahi hua (pending delete): cloud ki purani payment wapas na aaye.
      await SyncQueueHelper.enqueueDelete(db, 'utility_bill_payment', sid);
      await applyUtilityBillPayments(db, [payDoc('utility_bill:T-1', '2026-10')], nowMs: () => 5000);
      expect(await db.query('utility_bill_payments'), isEmpty);
    });
  });
}
