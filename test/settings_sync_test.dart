import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/sync/branch_config_store.dart';
import 'package:ah_developer_kiryana_store/sync/settings_sync.dart';
import 'package:ah_developer_kiryana_store/sync/sync_api.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';
import 'package:ah_developer_kiryana_store/sync/sync_repository.dart';
import 'package:ah_developer_kiryana_store/sync/sync_worker.dart';

/// Phase 10: SettingsSync (Kotlin `SettingsSync.kt`) ka logic — status dot, Cloud Setup ki jaanch aur
/// Branch-change guard, Sync History (audit) parhna/saaf karna, Retry Now, Sync Now, wrong-branch input.
/// UI (`lib/widgets/sync_section.dart`) device par dekhein.
Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL,
    action TEXT NOT NULL, reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL)''');
  await db.execute('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
    entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
    syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  return db;
}

Future<void> _q(Database db, {int retry = 0, int? synced, String id = 'x'}) => db.insert('sync_queue', {
      'entityType': 'customer',
      'entityId': id,
      'operation': 'upsert',
      'payloadJson': '{}',
      'createdAt': 1,
      'retryCount': retry,
      'syncedAt': synced,
    });

Future<void> _audit(Database db, String action, String ref, int at, {String details = ''}) => db.insert('audit', {
      'username': 'admin',
      'action': action,
      'reference': ref,
      'details': details,
      'createdAt': at,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchConfigStore.clear();
    db = await _memDb();
    SettingsSync.openDb = () async => db;
    SettingsSync.isOnline = () async => true;
    SettingsSync.cloudConfigured = () async => true;
  });
  tearDown(() => db.close());

  group('computeSyncStatus (Kotlin refreshSyncStatus ki tarteeb)', () {
    test('cloud project nahi => notSetUp (branch/online se qat-e-nazar)', () {
      final s = computeSyncStatus(cloudConfigured: false, branchConfigured: true, online: true);
      expect(s.kind, SyncStatusKind.notSetUp);
      expect(s.needsSetup, isTrue);
      expect(s.label, 'Not set up — tap Cloud Sync Setup');
    });

    test('cloud hai magar branch nahi => branchMissing', () {
      final s = computeSyncStatus(cloudConfigured: true, branchConfigured: false, online: true);
      expect(s.kind, SyncStatusKind.branchMissing);
      expect(s.label, 'Branch Code missing — tap Cloud Sync Setup');
    });

    test('sab theek: online => Connected, warna Offline', () {
      expect(computeSyncStatus(cloudConfigured: true, branchConfigured: true, online: true).label, 'Connected');
      final off = computeSyncStatus(cloudConfigured: true, branchConfigured: true, online: false);
      expect(off.kind, SyncStatusKind.offline);
      expect(off.label, 'Offline');
      expect(off.needsSetup, isFalse);
    });

    test('SettingsSync.status inject kiye hue hooks + BranchConfigStore se', () async {
      expect((await SettingsSync.status()).kind, SyncStatusKind.branchMissing);
      await BranchConfigStore.set('main-branch');
      expect((await SettingsSync.status()).kind, SyncStatusKind.connected);
      SettingsSync.isOnline = () async => false;
      expect((await SettingsSync.status()).kind, SyncStatusKind.offline);
      SettingsSync.cloudConfigured = () async => false;
      expect((await SettingsSync.status()).kind, SyncStatusKind.notSetUp);
    });
  });

  group('validateCloudSetup', () {
    test('Project ID / API Key / App ID zaroori (trim ke baad)', () {
      expect(validateCloudSetup(projectId: '', apiKey: 'k', appId: 'a', branchId: 'main'), isNotNull);
      expect(validateCloudSetup(projectId: 'p', apiKey: '  ', appId: 'a', branchId: 'main'), isNotNull);
      expect(validateCloudSetup(projectId: 'p', apiKey: 'k', appId: '', branchId: 'main'), isNotNull);
    });

    test('Branch Code 2-50 [A-Za-z0-9_-]', () {
      expect(validateCloudSetup(projectId: 'p', apiKey: 'k', appId: 'a', branchId: 'x'), isNotNull);
      expect(validateCloudSetup(projectId: 'p', apiKey: 'k', appId: 'a', branchId: 'a b'), isNotNull);
      expect(validateCloudSetup(projectId: 'p', apiKey: 'k', appId: 'a', branchId: 'main-branch'), isNull);
    });
  });

  group('Branch change guard (P1 security #4)', () {
    test('pehli baar setup / wahi code => guard nahi', () {
      expect(isRealBranchChange(branchConfigured: false, oldBranch: '', newBranch: 'main'), isFalse);
      expect(isRealBranchChange(branchConfigured: true, oldBranch: 'main', newBranch: 'main'), isFalse);
      expect(isRealBranchChange(branchConfigured: true, oldBranch: 'main', newBranch: ' main '), isFalse);
    });

    test('asli change + pending > 0 => blocked, pending 0 => allow', () {
      final blocked = decideCloudSetupSave(branchConfigured: true, oldBranch: 'a1', newBranch: 'b2', pendingCount: 3);
      expect(blocked.blocked, isTrue);
      expect(blocked.pending, 3);
      final ok = decideCloudSetupSave(branchConfigured: true, oldBranch: 'a1', newBranch: 'b2', pendingCount: 0);
      expect(ok.blocked, isFalse);
    });

    test('same branch par pending ho tab bhi allow (Kotlin: sirf real change roka jata hai)', () {
      final d = decideCloudSetupSave(branchConfigured: true, oldBranch: 'a1', newBranch: 'a1', pendingCount: 9);
      expect(d.blocked, isFalse);
    });

    test('pendingCount sirf un-synced rows ginta hai', () async {
      await _q(db, id: 'a');
      await _q(db, id: 'b', synced: 5);
      await _q(db, id: 'c', retry: 10); // atki hui bhi pending hai
      expect(await SettingsSync.pendingCount(), 2);
    });
  });

  group('Sync History', () {
    test('taaza pehle (createdAt DESC), aur AuditEntry ke flags/title', () async {
      await _audit(db, 'sync_conflict', 'sale:INV-1', 100, details: 'total farq');
      await _audit(db, 'sync_push_failed', 'customer:AB-1', 300);
      await _audit(db, 'login', 'admin', 200);
      final h = await SettingsSync.loadHistory();
      expect(h.entries.map((e) => e.createdAt), [300, 200, 100]);
      expect(h.entries[0].isPushFailure, isTrue);
      expect(h.entries[0].title, 'Push failed — customer:AB-1');
      expect(h.entries[1].isConflict, isFalse);
      expect(h.entries[1].title, 'admin');
      expect(h.entries[2].isConflict, isTrue);
      expect(h.entries[2].title, 'Conflict — sale:INV-1');
      expect(h.entries[2].details, 'total farq');
    });

    test('sirf 300 taaza qataren', () async {
      for (var i = 0; i < 305; i++) {
        await _audit(db, 'x', 'r$i', i);
      }
      final h = await SettingsSync.loadHistory();
      expect(h.entries, hasLength(SettingsSync.historyLimit));
      expect(h.entries.first.createdAt, 304);
    });

    test('atke hue items ginte hain aur Retry Now unhein wapas pending karta hai', () async {
      await _q(db, id: 'a', retry: 10);
      await _q(db, id: 'b', retry: 12);
      await _q(db, id: 'c', retry: 3);
      await _q(db, id: 'd', retry: 10, synced: 9); // synced => stuck nahi
      expect((await SettingsSync.loadHistory()).stuckCount, 2);
      await SettingsSync.retryStuck();
      expect((await SettingsSync.loadHistory()).stuckCount, 0);
      final rows = await db.query('sync_queue', where: 'entityId = ?', whereArgs: ['a']);
      expect(rows.first['retryCount'], 0);
    });

    test('Clear History sirf audit saaf karta hai, sync_queue nahi', () async {
      await _audit(db, 'sync_conflict', 'r', 1);
      await _q(db);
      await SettingsSync.clearHistory();
      expect((await SettingsSync.loadHistory()).entries, isEmpty);
      expect(await db.query('sync_queue'), hasLength(1));
    });

    test('khali DB: koi qatar nahi, koi crash nahi', () async {
      final h = await SettingsSync.loadHistory();
      expect(h.entries, isEmpty);
      expect(h.stuckCount, 0);
    });

    test('formatSyncTime: "dd MMM, hh:mm a"', () {
      expect(formatSyncTime(DateTime(2026, 3, 5, 21, 7).millisecondsSinceEpoch), '05 Mar, 09:07 PM');
      expect(formatSyncTime(DateTime(2026, 12, 31, 0, 5).millisecondsSinceEpoch), '31 Dec, 12:05 AM');
      expect(formatSyncTime(DateTime(2026, 9, 29, 12, 0).millisecondsSinceEpoch), '29 Sep, 12:00 PM');
    });
  });

  group('ghalat Branch ID cleanup (admin)', () {
    test('input ki jaanch: khali / apni branch => message, warna null', () async {
      await BranchConfigStore.set('main-branch');
      expect(SettingsSync.checkWrongBranchInput('   '), isNotNull);
      expect(SettingsSync.checkWrongBranchInput('main-branch'), isNotNull);
      expect(SettingsSync.checkWrongBranchInput(' dusri-branch '), isNull);
    });

    test('deleteWrongBranch apni branch par kabhi kuch nahi karta', () async {
      await BranchConfigStore.set('main-branch');
      expect(await SettingsSync.deleteWrongBranch('main-branch'), isEmpty);
    });

    test('sirf admin', () {
      expect(SettingsSync.requireAdmin('admin'), isTrue);
      expect(SettingsSync.requireAdmin('manager'), isFalse);
      expect(SettingsSync.requireAdmin('cashier'), isFalse);
    });

    test('countsSummary: "collection: n" har line par', () {
      expect(SettingsSync.countsSummary({'sales': 3, 'customers': 1}), 'sales: 3\ncustomers: 1');
      expect(SettingsSync.countsSummary({}), '');
    });
  });

  group('Sync Now / Resync from', () {
    final w = SyncWorker.instance;
    setUp(() {
      w.cancelPeriodic();
      w.isOnline = () async => true;
      w.runSync = () async => const SyncResult(pushedCount: 2, failedCount: 0, pulledOk: true);
    });
    tearDown(() => w.cancelPeriodic());

    test('offline => null (UI "No internet connection" dikhaye), sync nahi chalti', () async {
      var ran = 0;
      w.runSync = () async {
        ran++;
        return const SyncResult(pushedCount: 0, failedCount: 0, pulledOk: true);
      };
      SettingsSync.isOnline = () async => false;
      expect(await SettingsSync.syncNow(), isNull);
      expect(ran, 0);
    });

    test('online => SyncWorker.syncNowOnce ka summary', () async {
      expect(await SettingsSync.syncNow(), 'Sent 2');
    });

    test('nakaam sync => "Sync failed: ..." summary', () async {
      w.runSync = () async => const SyncResult(pushedCount: 0, failedCount: 0, pulledOk: false, error: 'boom');
      expect(await SettingsSync.syncNow(), 'Sync failed: boom');
    });

    test('resyncFrom: pull checkpoint us waqt par', () async {
      final t = DateTime(2026, 9, 28, 11, 0);
      await SettingsSync.resyncFrom(t);
      expect(await SyncRepository.lastSyncTime(), t.millisecondsSinceEpoch);
    });
  });

  group('installSyncWiring', () {
    test('backend = SyncApi, afterApply set, onQueued set', () {
      SyncRepository.backend = null;
      SyncRepository.afterApply = null;
      SyncQueueHelper.onQueued = null;
      installSyncWiring();
      expect(SyncRepository.backend, same(SyncApi.instance));
      expect(SyncRepository.afterApply, isNotNull);
      expect(SyncQueueHelper.onQueued, isNotNull);
      SyncQueueHelper.onQueued = null; // doosre tests par asar nahi
    });
  });
}
