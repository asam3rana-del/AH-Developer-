import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';

/// Workers sync: enqueue (payload + entity id) aur pull apply (insert / last-write-wins / tombstone / conflict).
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
  await x('''CREATE TABLE workers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', payType TEXT NOT NULL DEFAULT 'monthly', rate REAL NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1, createdAt INTEGER NOT NULL DEFAULT 0, serverId TEXT,
    updatedAt INTEGER NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE worker_attendance (workerId INTEGER NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL,
    updatedAt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (workerId, day))''');
  await x('''CREATE TABLE worker_advances (id INTEGER PRIMARY KEY AUTOINCREMENT, workerId INTEGER NOT NULL,
    amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash', note TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL, serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE worker_salary_payments (id INTEGER PRIMARY KEY AUTOINCREMENT, workerId INTEGER NOT NULL,
    month TEXT NOT NULL, earned REAL NOT NULL, advanceCut REAL NOT NULL, net REAL NOT NULL,
    method TEXT NOT NULL DEFAULT 'cash', expenseId INTEGER, expenseServerId TEXT, createdAt INTEGER NOT NULL,
    serverId TEXT, updatedAt INTEGER NOT NULL DEFAULT 0, UNIQUE (workerId, month))''');
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

  Future<void> addWorker(String serverId, {String name = 'Ali'}) =>
      applyWorkers(db, [
        {'serverId': serverId, 'name': name, 'payType': 'monthly', 'rate': 20000, 'updatedAt': 10}
      ], nowMs: () => 5000);

  group('entity ids', () {
    test('worker/advance/salary: serverId ho to wahi, warna type:<tag>-<id>', () {
      expect(SyncQueueHelper.workerEntityId({'id': 3, 'serverId': 'worker:AB12-9'}), 'worker:AB12-9');
      final own = SyncQueueHelper.workerEntityId({'id': 3, 'serverId': null});
      expect(own.startsWith('worker:'), isTrue);
      expect(own.endsWith('-3'), isTrue);
      expect(SyncQueueHelper.workerAdvanceEntityId({'id': 4}).startsWith('worker_advance:'), isTrue);
      expect(SyncQueueHelper.workerSalaryPaymentEntityId({'id': 5}).startsWith('worker_salary_payment:'), isTrue);
    });

    test('hazri ki id: worker + din, har device par ek jaisi', () {
      expect(SyncQueueHelper.workerAttendanceEntityId('worker:AB12-1', '2026-10-05'),
          'worker_attendance:worker:AB12-1|2026-10-05');
    });
  });

  group('enqueue', () {
    test('enqueueWorker: upsert + row par serverId', () async {
      final id = await db.insert('workers', {'name': 'Ali', 'payType': 'daily', 'rate': 800, 'createdAt': 7});
      await SyncQueueHelper.enqueueWorker(db, id);
      final q = await _queue(db);
      expect(q.single['entityType'], 'worker');
      expect(q.single['operation'], 'upsert');
      final p = _payload(q.single);
      expect(p['name'], 'Ali');
      expect(p['payType'], 'daily');
      expect(p['rate'], 800);
      expect(p['branchId'], 'main-branch');
      expect(p['serverId'], q.single['entityId']);
      expect((await db.query('workers')).single['serverId'], q.single['entityId']);
    });

    test('enqueueWorkerAttendance: payload mein _deleted:false; hatane par delete tombstone', () async {
      final wid = await db.insert('workers', {'name': 'Ali', 'rate': 1});
      await SyncQueueHelper.enqueueWorker(db, wid);
      final wsid = (await db.query('workers')).single['serverId'] as String;

      await db.insert('worker_attendance', {'workerId': wid, 'day': '2026-10-05', 'status': 'A', 'updatedAt': 1});
      await SyncQueueHelper.enqueueWorkerAttendance(db, wid, '2026-10-05');
      var q = await _queue(db);
      final up = q.last;
      expect(up['entityType'], 'worker_attendance');
      expect(up['entityId'], 'worker_attendance:$wsid|2026-10-05');
      expect(_payload(up)['status'], 'A');
      expect(_payload(up)['workerServerId'], wsid);
      expect(_payload(up)['_deleted'], false);

      await db.delete('worker_attendance', where: 'workerId = ?', whereArgs: [wid]);
      await SyncQueueHelper.enqueueWorkerAttendanceDelete(db, wid, '2026-10-05');
      q = await _queue(db);
      expect(q.last['operation'], 'delete');
      expect(q.last['entityId'], up['entityId']);
    });

    test('enqueueWorkerAdvance / SalaryPayment: worker ki serverId se jurte hain', () async {
      final wid = await db.insert('workers', {'name': 'Ali', 'rate': 1});
      await SyncQueueHelper.enqueueWorker(db, wid);
      final wsid = (await db.query('workers')).single['serverId'] as String;
      final aid = await db.insert('worker_advances', {'workerId': wid, 'amount': 500, 'createdAt': 3});
      await SyncQueueHelper.enqueueWorkerAdvance(db, aid);
      final pid = await db.insert('worker_salary_payments', {
        'workerId': wid, 'month': '2026-10', 'earned': 100, 'advanceCut': 20, 'net': 80,
        'expenseServerId': 'expense:AB12-1', 'createdAt': 4,
      });
      await SyncQueueHelper.enqueueWorkerSalaryPayment(db, pid);
      final q = await _queue(db);
      final adv = q.firstWhere((r) => r['entityType'] == 'worker_advance');
      final pay = q.firstWhere((r) => r['entityType'] == 'worker_salary_payment');
      expect(_payload(adv)['workerServerId'], wsid);
      expect(_payload(adv)['amount'], 500);
      expect(_payload(pay)['workerServerId'], wsid);
      expect(_payload(pay)['expenseServerId'], 'expense:AB12-1');
      expect(_payload(pay)['month'], '2026-10');
    });

    test('resyncAllLocalData: worker aur uski hazri/advance/salary sab queue mein', () async {
      // resync baqi tables bhi chhoota hai — yahan sirf worker wali entries dekhni hain, is liye chhote tables chahiye.
      for (final t in [
        'customers (id INTEGER PRIMARY KEY, serverId TEXT)',
        'suppliers (id INTEGER PRIMARY KEY, serverId TEXT)',
        'products (barcode TEXT PRIMARY KEY)',
        'users (username TEXT PRIMARY KEY)',
        'sales (invoice TEXT PRIMARY KEY)',
        'purchases (billNo TEXT PRIMARY KEY)',
        'payments (id INTEGER PRIMARY KEY)',
        'cash_transactions (id INTEGER PRIMARY KEY)',
        'units (name TEXT PRIMARY KEY)',
        'categories (name TEXT PRIMARY KEY)',
        'zakat_years (id INTEGER PRIMARY KEY)',
        'zakat_payments (id INTEGER PRIMARY KEY, zakatYearId INTEGER)',
        'returns (id INTEGER PRIMARY KEY)',
        'stock_movements (id INTEGER PRIMARY KEY)',
        'app_settings (key TEXT PRIMARY KEY, value TEXT)',
        'cash_register (date TEXT PRIMARY KEY)',
        'shell_customers (id INTEGER PRIMARY KEY)',
        'shell_transactions (id INTEGER PRIMARY KEY)',
        'shop_empty_shell_log (id INTEGER PRIMARY KEY)',
        'shop_rents (id INTEGER PRIMARY KEY, serverId TEXT)',
        'shop_rent_ledger (id INTEGER PRIMARY KEY, serverId TEXT)',
      ]) {
        await db.execute('CREATE TABLE $t');
      }
      final wid = await db.insert('workers', {'name': 'Ali', 'rate': 1});
      await db.insert('worker_attendance', {'workerId': wid, 'day': '2026-10-01', 'status': 'P'});
      await db.insert('worker_advances', {'workerId': wid, 'amount': 5, 'createdAt': 1});
      await db.insert('worker_salary_payments',
          {'workerId': wid, 'month': '2026-09', 'earned': 1, 'advanceCut': 0, 'net': 1, 'createdAt': 1});
      await db.insert('expenses', {'category': 'Salaries', 'description': 'x', 'amount': 1, 'createdAt': 1});
      await SyncQueueHelper.resyncAllLocalData(db);
      final types = (await _queue(db)).map((r) => r['entityType']).toList();
      expect(types.where((t) => t == 'worker').length, 1);
      expect(types.where((t) => t == 'worker_attendance').length, 1);
      expect(types.where((t) => t == 'worker_advance').length, 1);
      expect(types.where((t) => t == 'worker_salary_payment').length, 1);
    });
  });

  group('apply: worker', () {
    test('naya worker insert; dobara aaye to update (duplicate nahi)', () async {
      await addWorker('worker:T-1');
      await applyWorkers(db, [
        {'serverId': 'worker:T-1', 'name': 'Ali Khan', 'payType': 'daily', 'rate': 900, 'active': 0, 'updatedAt': 20}
      ], nowMs: () => 5000);
      final w = (await db.query('workers')).single;
      expect(w['name'], 'Ali Khan');
      expect(w['payType'], 'daily');
      expect(w['rate'], 900.0);
      expect(w['active'], 0);
      expect(w['serverId'], 'worker:T-1');
    });

    test('is device ki anpushed edit purani server copy se overwrite nahi hoti', () async {
      await addWorker('worker:T-1', name: 'Local Edit');
      await db.insert('sync_queue', {
        'entityType': 'worker', 'entityId': 'worker:T-1', 'operation': 'upsert', 'payloadJson': '{}', 'createdAt': 1,
      });
      await addWorker('worker:T-1', name: 'Old Server Name');
      expect((await db.query('workers')).single['name'], 'Local Edit');
    });

    test('tombstone: worker aur uski hazri hat jati hai', () async {
      await addWorker('worker:T-1');
      await db.insert('worker_attendance', {'workerId': 1, 'day': '2026-10-05', 'status': 'P', 'updatedAt': 1});
      await applyWorkers(db, [
        {'serverId': 'worker:T-1', '_deleted': true, 'updatedAt': 99}
      ], nowMs: () => 5000);
      expect(await db.query('workers'), isEmpty);
      expect(await db.query('worker_attendance'), isEmpty);
    });

    test('tombstone: advance/salary ka hisaab ho to worker nahi hatta (conflict audit)', () async {
      await addWorker('worker:T-1');
      await db.insert('worker_advances', {'workerId': 1, 'amount': 100, 'createdAt': 1});
      await applyWorkers(db, [
        {'serverId': 'worker:T-1', '_deleted': true, 'updatedAt': 99}
      ], nowMs: () => 5000);
      expect((await db.query('workers')).length, 1);
      expect((await db.query('audit')).where((r) => r['action'] == 'sync_conflict').length, 1);
    });

    test('bina naam / tombstone / galat payType', () async {
      await applyWorkers(db, [
        {'serverId': 'a'},
        {'serverId': 'b', 'name': 'B', '_deleted': true},
        {'serverId': 'c', 'name': 'C', 'payType': 'weird'},
      ], nowMs: () => 5000);
      final rows = await db.query('workers');
      expect(rows.length, 1);
      expect(rows.single['payType'], 'monthly');
    });
  });

  group('apply: hazri', () {
    Map<String, Object?> doc(String status, int at, {bool deleted = false}) => {
          'serverId': 'worker_attendance:worker:T-1|2026-10-05',
          'workerServerId': 'worker:T-1',
          'day': '2026-10-05',
          if (!deleted) 'status': status,
          '_deleted': deleted,
          'updatedAt': at,
        };

    Future<String?> status() async {
      final r = await db.query('worker_attendance');
      return r.isEmpty ? null : r.single['status'] as String;
    }

    test('last-write-wins: purani copy naye ko nahi todti', () async {
      await addWorker('worker:T-1');
      await applyWorkerAttendance(db, [doc('P', 100)], nowMs: () => 5000);
      expect(await status(), 'P');
      await applyWorkerAttendance(db, [doc('A', 50)], nowMs: () => 5000);
      expect(await status(), 'P');
      await applyWorkerAttendance(db, [doc('A', 200)], nowMs: () => 5000);
      expect(await status(), 'A');
    });

    test('tombstone: purani local copy hat jati hai, naye local nishan ko nahi', () async {
      await addWorker('worker:T-1');
      await applyWorkerAttendance(db, [doc('P', 200)], nowMs: () => 5000);
      await applyWorkerAttendance(db, [doc('', 150, deleted: true)], nowMs: () => 5000);
      expect(await status(), 'P');
      await applyWorkerAttendance(db, [doc('', 300, deleted: true)], nowMs: () => 5000);
      expect(await status(), isNull);
    });

    test('anjaan worker, galat din ya galat status chhod diye jate hain', () async {
      await addWorker('worker:T-1');
      await applyWorkerAttendance(db, [
        {...doc('P', 1), 'workerServerId': 'worker:ZZ-9'},
        {...doc('P', 1), 'day': 'bad-day'},
        doc('X', 1),
      ], nowMs: () => 5000);
      expect(await db.query('worker_attendance'), isEmpty);
    });

    test('is device ki anpushed hazri na toro', () async {
      await addWorker('worker:T-1');
      await db.insert('worker_attendance', {'workerId': 1, 'day': '2026-10-05', 'status': 'H', 'updatedAt': 1});
      await db.insert('sync_queue', {
        'entityType': 'worker_attendance',
        'entityId': 'worker_attendance:worker:T-1|2026-10-05',
        'operation': 'upsert',
        'payloadJson': '{}',
        'createdAt': 1,
      });
      await applyWorkerAttendance(db, [doc('A', 999)], nowMs: () => 5000);
      expect(await status(), 'H');
    });
  });

  group('apply: advance aur salary', () {
    test('advance insert, dobara aane par duplicate nahi, tombstone par delete', () async {
      await addWorker('worker:T-1');
      final doc = {'serverId': 'worker_advance:T-1', 'workerServerId': 'worker:T-1', 'amount': 500, 'method': 'bank', 'createdAt': 9};
      await applyWorkerAdvances(db, [doc], nowMs: () => 5000);
      await applyWorkerAdvances(db, [doc], nowMs: () => 5000);
      final rows = await db.query('worker_advances');
      expect(rows.length, 1);
      expect(rows.single['amount'], 500.0);
      expect(rows.single['method'], 'bank');
      expect(rows.single['workerId'], 1);
      await applyWorkerAdvances(db, [
        {'serverId': 'worker_advance:T-1', '_deleted': true}
      ], nowMs: () => 5000);
      expect(await db.query('worker_advances'), isEmpty);
    });

    test('salary insert: expense serverId se local expense judti hai; tombstone par delete', () async {
      await addWorker('worker:T-1');
      await db.insert('expenses',
          {'category': 'Salaries', 'description': 'x', 'amount': 100, 'createdAt': 1, 'serverId': 'expense:T-1'});
      final doc = {
        'serverId': 'worker_salary_payment:T-1',
        'workerServerId': 'worker:T-1',
        'month': '2026-10',
        'earned': 100,
        'advanceCut': 20,
        'net': 80,
        'expenseServerId': 'expense:T-1',
        'createdAt': 9,
      };
      await applyWorkerSalaryPayments(db, [doc], nowMs: () => 5000);
      final p = (await db.query('worker_salary_payments')).single;
      expect(p['expenseId'], 1);
      expect(p['expenseServerId'], 'expense:T-1');
      expect(p['net'], 80.0);
      await applyWorkerSalaryPayments(db, [
        {'serverId': 'worker_salary_payment:T-1', '_deleted': true}
      ], nowMs: () => 5000);
      expect(await db.query('worker_salary_payments'), isEmpty);
    });

    test('ek mahine ki do salary: doosri chhod di jati hai, audit mein sync_conflict', () async {
      await addWorker('worker:T-1');
      Map<String, Object?> doc(String id) => {
            'serverId': id,
            'workerServerId': 'worker:T-1',
            'month': '2026-10',
            'earned': 100,
            'advanceCut': 0,
            'net': 100,
            'createdAt': 9,
          };
      await applyWorkerSalaryPayments(db, [doc('worker_salary_payment:A-1')], nowMs: () => 5000);
      await applyWorkerSalaryPayments(db, [doc('worker_salary_payment:B-1')], nowMs: () => 5000);
      expect((await db.query('worker_salary_payments')).length, 1);
      final audit = await db.query('audit', where: 'action = ?', whereArgs: ['sync_conflict']);
      expect(audit.length, 1);
    });
  });

  test('pull plan: 4 Workers collections shamil, result mein sahi jagah', () {
    for (final c in ['workers', 'worker_attendance', 'worker_advances', 'worker_salary_payments']) {
      expect(pullCollections.contains(c), isTrue);
      expect(branchScopedCollections.contains(c), isTrue);
    }
    final r = assemblePullResult({
      'workers': [{'serverId': 'w', 'updatedAt': 50}],
      'worker_attendance': [{'serverId': 'a', 'updatedAt': 60}],
      'worker_advances': [{'serverId': 'd', 'updatedAt': 70}],
      'worker_salary_payments': [{'serverId': 's', 'updatedAt': 80}],
    }, 10, nowMs: 1000);
    expect(r.workers.length, 1);
    expect(r.workerAttendance.length, 1);
    expect(r.workerAdvances.length, 1);
    expect(r.workerSalaryPayments.length, 1);
    expect(r.serverTime, 80);
  });
}
