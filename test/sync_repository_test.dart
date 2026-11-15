import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_dao.dart';
import 'package:ah_developer_kiryana_store/sync/sync_repository.dart';
import 'package:ah_developer_kiryana_store/sync/sync_types.dart';

/// Phase 10: SyncQueueDao + SyncRepository.syncNow (push -> pull -> apply), Kotlin SyncRepository jaisa.
class FakeBackend implements SyncBackend {
  final Set<String> failIds;
  Object? pullError;
  PullResult result;
  final pushed = <String>[];
  int? pulledSince;
  int applied = 0;

  FakeBackend({this.failIds = const {}, PullResult? result})
      : result = result ?? PullResult(serverTime: 5000);

  @override
  Future<bool> push(SyncQueueEntry entry) async {
    if (failIds.contains(entry.entityId)) return false;
    pushed.add(entry.entityId);
    return true;
  }

  @override
  Future<PullResult> pull(int since) async {
    pulledSince = since;
    if (pullError != null) throw pullError!;
    return result;
  }

  @override
  Future<void> applyServerChanges(Database db, PullResult changes) async => applied++;

  @override
  bool isPermissionDenied(Object e) => e is StateError;

  @override
  String permissionDeniedMessage() => 'denied!';
}

Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE sync_queue (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entityType TEXT NOT NULL, entityId TEXT NOT NULL, operation TEXT NOT NULL,
      payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL, syncedAt INTEGER,
      retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)
  ''');
  return db;
}

SyncQueueEntry _e(String id, {int at = 1, String type = 'customer', String op = 'upsert', int? synced, int retry = 0}) =>
    SyncQueueEntry(
        entityType: type, entityId: id, operation: op, payloadJson: '{}', createdAt: at, syncedAt: synced, retryCount: retry);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('SyncQueueDao', () {
    late Database db;
    late SyncQueueDao q;
    setUp(() async {
      db = await _memDb();
      q = SyncQueueDao(db);
    });
    tearDown(() => db.close());

    test('pending: purani pehle, synced aur retry>=10 bahar, limit', () async {
      await q.enqueue(_e('b', at: 20));
      await q.enqueue(_e('a', at: 10));
      await q.enqueue(_e('done', at: 5, synced: 99));
      await q.enqueue(_e('stuck', at: 6, retry: 10));
      expect((await q.pending()).map((e) => e.entityId), ['a', 'b']);
      expect((await q.pending(limit: 1)).single.entityId, 'a');
      expect((await q.stuck()).single.entityId, 'stuck');
    });

    test('markFailed retry badhata hai; 10 ke baad pending se nikal kar stuck; resetRetry wapas', () async {
      final id = await q.enqueue(_e('x'));
      for (var i = 0; i < 10; i++) {
        await q.markFailed(id, 'boom');
      }
      expect(await q.pending(), isEmpty);
      final st = (await q.stuck()).single;
      expect(st.retryCount, 10);
      expect(st.lastError, 'boom');
      await q.resetRetry(id);
      final back = (await q.pending()).single;
      expect(back.retryCount, 0);
      expect(back.lastError, isNull);
      await q.markFailed(id, 'e');
      for (var i = 0; i < 9; i++) {
        await q.markFailed(id, 'e');
      }
      await q.resetAllStuck();
      expect((await q.pending()).single.retryCount, 0);
    });

    test('pendingForEntity vs AnyRetry vs pendingCountForEntity', () async {
      await q.enqueue(_e('p1', type: 'supplier', op: 'delta', at: 1));
      await q.enqueue(_e('p1', type: 'supplier', op: 'delta', at: 2, retry: 10));
      await q.enqueue(_e('p1', type: 'supplier', op: 'upsert', at: 3));
      await q.enqueue(_e('p1', type: 'supplier', op: 'delta', at: 4, synced: 50));
      expect((await q.pendingForEntity('supplier', 'p1', 'delta')).length, 1);
      expect((await q.pendingForEntityAnyRetry('supplier', 'p1', 'delta')).length, 2);
      expect(await q.pendingCountForEntity('supplier', 'p1'), 3);
      expect(await q.pendingCount(), 3);
    });

    test('pruneSynced sirf purani synced rows hatata hai', () async {
      await q.enqueue(_e('old', synced: 100));
      await q.enqueue(_e('new', synced: 900));
      await q.enqueue(_e('unsynced'));
      await q.pruneSynced(500);
      final rows = await db.query('sync_queue', orderBy: 'entityId');
      expect(rows.map((r) => r['entityId']), ['new', 'unsynced']);
    });
  });

  group('SyncRepository.syncNow', () {
    late Database db;
    late SyncQueueDao q;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = await _memDb();
      q = SyncQueueDao(db);
      SyncRepository.openDb = () async => db;
      SyncRepository.isCloudReady = () async => true;
      SyncRepository.afterApply = null;
      SyncRepository.nowMs = () => 10 * 24 * 60 * 60 * 1000;
    });
    tearDown(() async {
      SyncRepository.backend = null;
      await db.close();
    });

    test('cloud set up nahi => saaf paighaam, kuch push/pull nahi', () async {
      SyncRepository.isCloudReady = () async => false;
      final fake = FakeBackend();
      SyncRepository.backend = fake;
      final r = await SyncRepository.syncNow();
      expect(r.pulledOk, isFalse);
      expect(r.error, startsWith('Cloud sync not set up'));
      expect(fake.pulledSince, isNull);
    });

    test('push: kamyab markSynced, nakaam markFailed("push failed"); phir pull + apply + checkpoint', () async {
      await q.enqueue(_e('ok1', at: 1));
      await q.enqueue(_e('bad', at: 2));
      await q.enqueue(_e('ok2', at: 3));
      final fake = FakeBackend(failIds: {'bad'}, result: PullResult(customers: [{}, {}], sales: [{}], serverTime: 7777));
      SyncRepository.backend = fake;
      final r = await SyncRepository.syncNow();
      expect(fake.pushed, ['ok1', 'ok2']);
      expect(r.pushedCount, 2);
      expect(r.failedCount, 1);
      expect(r.pulledOk, isTrue);
      expect(r.customersReceived, 2);
      expect(r.salesReceived, 1);
      expect(fake.applied, 1);
      expect(fake.pulledSince, 0);
      expect(await SyncRepository.lastSyncTime(), 7777);
      final left = await q.pending();
      expect(left.single.entityId, 'bad');
      expect(left.single.retryCount, 1);
      expect(left.single.lastError, 'push failed');
      expect(r.summary(), 'Sent 2, received 3, 1 failed');
    });

    test('agli sync pichla checkpoint istemal karti hai; resetSyncCheckpoint pull ko pichhe karta hai', () async {
      final fake = FakeBackend(result: PullResult(serverTime: 9000));
      SyncRepository.backend = fake;
      await SyncRepository.syncNow();
      await SyncRepository.syncNow();
      expect(fake.pulledSince, 9000);
      await SyncRepository.resetSyncCheckpoint(1234);
      await SyncRepository.syncNow();
      expect(fake.pulledSince, 1234);
    });

    test('branch code nahi => pulledOk false, checkpoint/apply nahi, push phir bhi hua', () async {
      await q.enqueue(_e('a'));
      final fake = FakeBackend()..pullError = const BranchNotConfiguredException('no branch');
      SyncRepository.backend = fake;
      final r = await SyncRepository.syncNow();
      expect(r.pulledOk, isFalse);
      expect(r.error, 'no branch');
      expect(r.pushedCount, 1);
      expect(fake.applied, 0);
      expect(await SyncRepository.lastSyncTime(), 0);
      expect(r.summary(), 'Sync failed: no branch');
    });

    test('permission denied => backend ka insaani paighaam; doosri ghalti => uska text', () async {
      final fake = FakeBackend()..pullError = StateError('x');
      SyncRepository.backend = fake;
      expect((await SyncRepository.syncNow()).error, 'denied!');
      fake.pullError = Exception('no internet');
      expect((await SyncRepository.syncNow()).error, 'no internet');
    });

    test('purani (7 din+) synced rows saaf, taaza rahin; afterApply ka crash sync nahi rokta', () async {
      final now = 10 * 24 * 60 * 60 * 1000;
      await q.enqueue(_e('old', synced: now - 8 * 24 * 60 * 60 * 1000));
      await q.enqueue(_e('fresh', synced: now - 60 * 1000));
      SyncRepository.afterApply = (_) async => throw StateError('repair failed');
      SyncRepository.backend = FakeBackend();
      final r = await SyncRepository.syncNow();
      expect(r.pulledOk, isTrue);
      final ids = (await db.query('sync_queue')).map((e) => e['entityId']).toList();
      expect(ids, ['fresh']);
    });

    test('summary: kuch nahi => Already up to date', () {
      expect(const SyncResult(pushedCount: 0, failedCount: 0, pulledOk: true).summary(), 'Already up to date');
    });
  });
}
