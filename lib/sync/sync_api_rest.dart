import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/maintenance_sync.dart';
import '../models/misc_entities.dart';
import '../utils/loc.dart';
import '../utils/qty_math.dart';
import 'branch_config_store.dart';
import 'cloud_config_store.dart';
import 'device_tag.dart';
import 'firestore_rest.dart';
import 'sync_apply.dart';
import 'sync_pull_plan.dart';
import 'sync_push_plan.dart';
import 'sync_seed_fields.dart';
import 'sync_types.dart';

/// PC (Windows) ka sync backend — [SyncApi] (mobile, Firebase SDK) ki hoo-ba-hoo naqal, magar Firestore
/// tak [FirestoreRest] (REST, koi native code nahi) se. Faisle wahi saaf functions karte hain
/// (`sync_push_plan.dart`, `sync_pull_plan.dart`, `sync_apply.dart`) — is liye PC aur mobile ka data ek jaisa
/// likha / parha jata hai: last-write-wins, tombstone delete, stock / balance increment `appliedOps` ke saath,
/// `pushedAt` se der wali entries.
///
/// FARQ: secure staff mode (callable functions) PC par nahi — PC par "Staff cloud login" OFF rakhein.
class RestSyncApi implements SyncBackend, SyncHeartbeat {
  RestSyncApi._();
  static final RestSyncApi instance = RestSyncApi._();

  FirestoreRest get _fs => FirestoreRest.instance;

  Future<Database> Function() openDb = () => AppDatabase.instance.database;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  @override
  bool isPermissionDenied(Object e) => e is RestFirebaseException && e.code == 'permission-denied';

  @override
  String permissionDeniedMessage() => Loc.t(
        "Cloud sync was rejected by the server (permission denied) — add this PC's Device ID to branch_members in Firebase (Settings > Cloud Sync Setup shows it), or re-check Cloud Sync Setup.",
        'کلاؤڈ سنک سرور نے مسترد کر دیا (اجازت نہیں) — اس کمپیوٹر کی Device ID کو Firebase میں branch_members میں شامل کریں (Settings > Cloud Sync Setup میں نظر آتی ہے)، یا Cloud Sync Setup دوبارہ دیکھیں۔',
      );

  /// Is PC ki Device ID (REST anonymous UID) — pehli sync se pehle null.
  Future<String?> currentUid() => _fs.currentUid();

  /// Aakhri [_ready] na ho saka to wajah.
  String connectIssue = '';

  /// Branch + project + sign-in tayyar? Na ho to false aur [connectIssue] mein wajah.
  Future<bool> _ready() async {
    connectIssue = '';
    if (!BranchConfigStore.isConfigured()) {
      connectIssue = Loc.t(
        'Branch Code is empty — open Settings > Cloud Sync Setup and save a Branch Code.',
        'برانچ کوڈ خالی ہے — Settings > Cloud Sync Setup میں برانچ کوڈ محفوظ کریں۔',
      );
      return false;
    }
    final cfg = await CloudConfigStore.get();
    if (cfg == null) {
      connectIssue = Loc.t(
        'Firebase project is not set — open Settings > Cloud Sync Setup and enter the Firebase project details.',
        'Firebase پراجیکٹ سیٹ نہیں — Settings > Cloud Sync Setup میں Firebase پراجیکٹ کی تفصیل درج کریں۔',
      );
      return false;
    }
    try {
      await _fs.idToken();
      return true;
    } catch (e) {
      final code = e is RestFirebaseException ? e.code : '';
      if (code == 'operation-not-allowed' || code == 'admin-restricted-operation') {
        connectIssue = Loc.t(
          'Anonymous sign-in is OFF in Firebase — Firebase Console > Authentication > Sign-in method > turn on Anonymous.',
          'Firebase میں Anonymous سائن اِن بند ہے — Firebase Console > Authentication > Sign-in method میں Anonymous آن کریں۔',
        );
      } else if (isNetworkError(e)) {
        connectIssue = Loc.t(
          'No internet (or too slow) — sync will retry when the connection is back.',
          'انٹرنیٹ نہیں (یا بہت سست) — کنکشن آنے پر سنک دوبارہ کوشش کرے گا۔',
        );
      } else {
        connectIssue = Loc.t(
          'Sign-in failed (${code.isEmpty ? e.toString() : code}) — check the API key / project in Cloud Sync Setup.',
          'سائن اِن ناکام (${code.isEmpty ? e.toString() : code}) — Cloud Sync Setup میں API key / پراجیکٹ چیک کریں۔',
        );
      }
      return false;
    }
  }

  static String _messageOf(Object e) {
    if (e is RestFirebaseException) return e.message.isEmpty ? e.code : e.message;
    final s = e.toString();
    return s.isEmpty ? 'unknown error' : s;
  }

  // ---------------------------------------------------------------- PUSH

  @override
  Future<bool> push(SyncQueueEntry entry) async {
    if (!await _ready()) {
      throw SyncOfflineException(
          connectIssue.isEmpty ? 'Cloud not reachable (sign-in failed, no branch code or no cloud project)' : connectIssue);
    }
    final localDb = await openDb();
    try {
      final collection = collectionFor(entry.entityType);
      if (collection == null) throw SyncPushException('Unknown entity type: ${entry.entityType}');
      final id = entry.entityId;
      final branch = BranchConfigStore.current;

      switch (entry.operation) {
        case 'delete':
          final deleteAt = nowMs();
          await _fs.runTransaction((tx) async {
            final snap = await tx.get(collection, id);
            final serverUpdatedAt = asMillis(snap.data()?['updatedAt']);
            if (shouldApplyDelete(deleteAt, serverUpdatedAt)) {
              tx.set(collection, id, {...tombstone(id, deleteAt, branch), 'pushedAt': deleteAt}, merge: true);
            }
          });
          break;

        case 'create_if_absent':
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          final createPushedAt = nowMs();
          await _fs.runTransaction((tx) async {
            final snap = await tx.get(collection, id);
            if (canCreateIfAbsent(exists: snap.exists, data: snap.data())) {
              tx.set(collection, id, {...st.map, 'pushedAt': createPushedAt}, merge: true);
            }
          });
          break;

        case 'increment_stock':
        case 'increment_balance':
          final map = decodePayload(entry.payloadJson);
          final delta = (map['delta'] as num?)?.toDouble() ?? 0.0;
          final opId = buildOpId(DeviceTag.current, entry.id, entry.createdAt);
          final ts = nowMs();
          final seed = await loadSeedFields(localDb, entityType: entry.entityType, entityId: id);
          var diagSkipped = false;
          num? diagBefore;
          double? diagNew;
          await _fs.runTransaction((tx) async {
            diagSkipped = false;
            final snap = await tx.get(collection, id);
            diagBefore = snap.data()?['stock'] as num?;
            final plan = planIncrement(
              exists: snap.exists,
              data: snap.data(),
              operation: entry.operation,
              delta: delta,
              updatedAtValue: ts,
              branchId: branch,
              opId: opId,
              nowTs: ts,
              entityId: id,
              seedFields: seed,
            );
            diagSkipped = plan.skip;
            if (plan.skip) return;
            final curRaw = snap.data()?[plan.incrementField];
            final cur = curRaw is num ? curRaw.toDouble() : 0.0;
            diagNew = plan.incrementField == 'stock' ? roundQty(cur + plan.delta) : cur + plan.delta;
            tx.set(
              collection,
              id,
              <String, Object?>{plan.incrementField: diagNew, ...plan.otherFields, 'pushedAt': ts},
              mergeFields: [...plan.mergeFields, 'pushedAt'],
            );
          });
          if (entry.entityType == 'product') {
            await logMaintenanceAudit(localDb,
                username: 'sync',
                action: 'stock_inc_push',
                reference: 'product:$id',
                details: 'queue#${entry.id} delta $delta cloudBefore ${diagBefore ?? 'n/a'} cloudWritten ${diagNew ?? 'n/a'} skipped $diagSkipped (pc)');
          }
          break;

        case 'set_stock':
          final setStock = (decodePayload(entry.payloadJson)['stock'] as num?)?.toDouble() ?? 0.0;
          final setTs = nowMs();
          num? prevCloud;
          try {
            prevCloud = (await _fs.getDoc(collection, id)).data()?['stock'] as num?;
          } catch (_) {}
          await logMaintenanceAudit(localDb,
              username: 'sync',
              action: 'cloud_stock_set',
              reference: '${entry.entityType}:$id',
              details: 'cloud stock ${prevCloud ?? 'n/a'} -> $setStock (set_stock push, pc)');
          final setSeed = await loadSeedFields(localDb, entityType: entry.entityType, entityId: id);
          await _fs.runTransaction((tx) async {
            final snap = await tx.get(collection, id);
            final isNew = !snap.exists || snap.data()?['_deleted'] == true;
            tx.set(
              collection,
              id,
              <String, Object?>{
                'stock': setStock,
                'updatedAt': setTs,
                'pushedAt': setTs,
                'branchId': branch,
                if (isNew) ...{'serverId': id, '_deleted': false, ...setSeed},
              },
              merge: true,
            );
          });
          break;

        default:
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          final upsertPushedAt = nowMs();
          var skippedStale = false;
          int? skippedServerAt;
          await _fs.runTransaction((tx) async {
            skippedStale = false;
            final snap = await tx.get(collection, id);
            final serverUpdatedAt = upsertClock(snap.data());
            if (shouldApplyUpsert(st.incomingUpdatedAt, serverUpdatedAt)) {
              tx.set(collection, id, {...st.map, 'upsertAt': st.incomingUpdatedAt, 'pushedAt': upsertPushedAt},
                  merge: true);
            } else {
              skippedStale = true;
              skippedServerAt = serverUpdatedAt;
            }
          });
          if (skippedStale) {
            await logMaintenanceAudit(
              localDb,
              username: 'sync',
              action: 'sync_push_skipped_stale',
              reference: '${entry.entityType}:$id',
              details: 'Local ${st.incomingUpdatedAt} < cloud $skippedServerAt — cloud ki nayi value rakhi gayi.',
            );
          }
      }
      return true;
    } catch (e) {
      if (e is SyncOfflineException || e is SyncPermissionDeniedException) rethrow;
      if (isNetworkError(e)) throw SyncOfflineException(_messageOf(e));
      if (isQuotaError(e)) {
        await logMaintenanceAudit(localDb,
            username: 'sync',
            action: 'sync_quota_exhausted',
            reference: '${entry.entityType}:${entry.entityId}',
            details: _messageOf(e));
        throw SyncOfflineException('Firestore quota khatam — baad mein dobara try hoga: ${_messageOf(e)}');
      }
      final denied = isPermissionDenied(e);
      final msg = denied ? permissionDeniedMessage() : _messageOf(e);
      await logMaintenanceAudit(localDb,
          username: 'sync',
          action: 'sync_push_failed',
          reference: '${entry.entityType}:${entry.entityId}',
          details: '${_messageOf(e)} (pc)');
      if (denied) throw SyncPermissionDeniedException(msg);
      throw SyncPushException(msg);
    }
  }

  // ---------------------------------------------------------------- HEARTBEAT

  @override
  Future<String> readHeartbeat() async {
    if (!await _ready()) throw StateError('cloud not ready');
    final branch = BranchConfigStore.current;
    if (branch.trim().isEmpty) throw StateError('no branch');
    final d = await _fs.getDoc(heartbeatCollection, branch);
    if (!d.exists) return '';
    final m = d.data() ?? const {};
    return '${m['at']}|${m['n']}';
  }

  @override
  Future<void> bumpHeartbeat() async {
    if (!await _ready()) return;
    final branch = BranchConfigStore.current;
    if (branch.trim().isEmpty) return;
    final project = await _fs.projectId();
    await _fs.commit([
      _fs.updateWrite(project, heartbeatCollection, branch, {
        'branchId': branch,
        'at': nowMs(),
        'n': DateTime.now().microsecondsSinceEpoch % 1000000007,
      }),
    ]);
  }

  // ---------------------------------------------------------------- PULL

  @override
  Future<PullResult> pull(int since) async {
    final branch = BranchConfigStore.current;
    if (branch.trim().isEmpty) {
      throw BranchNotConfiguredException(Loc.t(
        'No branch code is configured on this device — open Settings > Cloud Sync Setup and save a branch code before syncing.',
        'اس ڈیوائس پر برانچ کوڈ سیٹ نہیں ہے — Sync سے پہلے Settings > Cloud Sync Setup میں برانچ کوڈ محفوظ کریں۔',
      ));
    }
    if (!await _ready()) {
      throw Exception(connectIssue.isNotEmpty
          ? connectIssue
          : Loc.t(
              'Could not connect to the cloud — check internet and Cloud Sync Setup, then try again.',
              'کلاؤڈ سے رابطہ نہیں ہو سکا — انٹرنیٹ اور Cloud Sync Setup چیک کر کے دوبارہ کوشش کریں۔',
            ));
    }

    var lateFailed = false;
    Future<MapEntry<String, List<SyncDoc>>> load(String collection) async {
      final overlap = stockPullCollections.contains(collection) ? stockPullOverlapMs : pullOverlapMs;
      final threshold = since > overlap ? since - overlap : 0;
      final docs = await _fs.query(collection, [
        RestFilter('branchId', 'EQUAL', branch),
        RestFilter('updatedAt', 'GREATER_THAN', threshold),
      ]);
      final byId = <String, SyncDoc>{for (final d in docs) d.id: Map<String, Object?>.from(d.data() ?? const {})};
      try {
        final late = await _fs.query(collection, [
          RestFilter('branchId', 'EQUAL', branch),
          RestFilter('pushedAt', 'GREATER_THAN', threshold),
        ]);
        for (final d in late) {
          byId.putIfAbsent(d.id, () => Map<String, Object?>.from(d.data() ?? const {}));
        }
      } catch (e) {
        if (isNetworkError(e)) rethrow;
        final code = e is RestFirebaseException ? e.code : '';
        PullDiagnostics.lateQueryFailed.add(collection);
        final n = PullDiagnostics.lateQueryFailed.length;
        final which = n == 1 ? '"$collection"' : '$n collections (e.g. "$collection")';
        PullDiagnostics.lateQueryIssue = code == 'failed-precondition'
            ? 'pushedAt index missing for $which — deploy firebase/firestore.indexes.json'
            : 'late-push query failed for $which: $e';
        lateFailed = true;
      }
      return MapEntry(collection, byId.values.toList());
    }

    final skipDenied = await _cashierSkipsDenied();
    Future<MapEntry<String, List<SyncDoc>>> loadSafe(String collection) async {
      try {
        return await load(collection);
      } on RestFirebaseException catch (e) {
        if (skipDenied && e.code == 'permission-denied') return MapEntry(collection, <SyncDoc>[]);
        rethrow;
      }
    }

    lateFailed = false;
    PullDiagnostics.lateQueryFailed.clear();
    // 4-4 collections ek saath (sab ek saath = kamzor internet par timeouts; ek ek = 90 sec se zyada).
    final loaded = <MapEntry<String, List<SyncDoc>>>[];
    const batch = 4;
    for (var i = 0; i < pullCollections.length; i += batch) {
      final end = i + batch < pullCollections.length ? i + batch : pullCollections.length;
      loaded.addAll(await Future.wait([for (final c in pullCollections.sublist(i, end)) loadSafe(c)]));
    }
    if (!lateFailed) PullDiagnostics.lateQueryIssue = '';
    return assemblePullResult(Map.fromEntries(loaded), since);
  }

  bool? _cashierCache;
  int _cashierCacheAt = 0;

  Future<bool> _cashierSkipsDenied() async {
    final now = nowMs();
    final cached = _cashierCache;
    if (cached != null && now - _cashierCacheAt < 10 * 60 * 1000) return cached;
    try {
      final uid = await _fs.currentUid();
      if (uid == null) return false;
      final snap = await _fs.getDoc('branch_members', uid);
      // Rules (firestore.device-roles.rules) jaisa: role na ho = admin; saaf admin / manager = poora; baaqi sab = cashier.
      final role = snap.data()?['role'];
      final r = role == null ? 'admin' : role.toString().toLowerCase().trim();
      final isCashier = r != 'admin' && r != 'manager';
      _cashierCache = isCashier;
      _cashierCacheAt = now;
      return isCashier;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- APPLY

  @override
  Future<void> applyServerChanges(Database db, PullResult changes) =>
      applyServerChangesToDb(db, changes, nowMs: nowMs);

  // ---------------------------------------------------------------- BRANCH CLEANUP

  Future<Map<String, int>> countDocsByBranchId(String badBranchId) async {
    if (!await _ready()) return {};
    final result = <String, int>{};
    for (final col in branchScopedCollections) {
      try {
        final docs = await _fs.query(col, [RestFilter('branchId', 'EQUAL', badBranchId)]);
        if (docs.isNotEmpty) result[col] = docs.length;
      } catch (_) {}
    }
    return result;
  }

  Future<Map<String, int>> deleteDocsByBranchId(String badBranchId) async {
    if (!await _ready()) return {};
    final project = await _fs.projectId();
    final result = <String, int>{};
    for (final col in branchScopedCollections) {
      try {
        var deleted = 0;
        while (true) {
          final docs = await _fs.query(col, [RestFilter('branchId', 'EQUAL', badBranchId)], limit: branchCleanupBatchSize);
          if (docs.isEmpty) break;
          await _fs.commit([for (final d in docs) _fs.deleteWrite(project, col, d.id)]);
          deleted += docs.length;
          if (docs.length < branchCleanupBatchSize) break;
        }
        if (deleted > 0) result[col] = deleted;
      } catch (_) {}
    }
    return result;
  }

  /// Crash report (crash_reporter.dart) — PC par REST se.
  Future<bool> addCrashReport(Map<String, Object?> doc) async {
    if (!await _ready()) return false;
    await _fs.addDoc('crash_reports', doc).timeout(const Duration(seconds: 15));
    return true;
  }
}
