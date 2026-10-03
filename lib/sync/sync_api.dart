import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/maintenance_sync.dart';
import '../models/misc_entities.dart';
import '../utils/loc.dart';
import 'branch_config_store.dart';
import 'cloud_config_store.dart';
import 'device_tag.dart';
import 'sync_apply.dart';
import 'sync_pull_plan.dart';
import 'sync_push_plan.dart';
import 'sync_seed_fields.dart';
import 'sync_types.dart';

/// Kotlin `SyncApi.kt` — Firebase Firestore sync layer.
///
/// Collections: customers, suppliers, products(barcode), users, sales, purchases, payments, expenses,
/// cash_transactions, units(name), categories(name), zakat_years, zakat_payments, returns,
/// stock_movements, app_settings(key), cash_register(date), shell_customers, shell_transactions,
/// shop_empty_shell_log — schema Android jaisa (dono apps ek backend).
///
/// STATUS: HEADER + PUSH + PULL + APPLY (hissa 1 + 2, sab 20 collections) + branch cleanup
/// (count/delete) — `SyncApi.kt` mukammal. Wiring `installSyncWiring()` (settings_sync.dart) se main() mein
/// hoti hai: `SyncRepository.backend = SyncApi.instance`, `afterApply = mergeOwnDuplicateExpenses`.
class SyncApi implements SyncBackend {
  SyncApi._();
  static final SyncApi instance = SyncApi._();

  /// Tests badalte hain.
  Future<Database> Function() openDb = () => AppDatabase.instance.database;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  // ---------- helpers (Kotlin ke upar ke hisse) ----------

  /// Kotlin `isPermissionDenied`: Firestore ne security rules ki wajah se rad kiya.
  @override
  bool isPermissionDenied(Object e) => e is FirebaseException && e.code == 'permission-denied';

  /// Kotlin `permissionDeniedMessage` (English/Urdu).
  @override
  String permissionDeniedMessage() => Loc.t(
        "Cloud sync was rejected by the server (permission denied) — check that this device's Firebase project's Security Rules allow signed-in access, or re-check your Cloud Sync Setup in Settings.",
        'کلاؤڈ سنک سرور نے مسترد کر دیا (اجازت نہیں) — چیک کریں کہ اس ڈیوائس کے Firebase پراجیکٹ کے Security Rules سائن اِن رسائی کی اجازت دیتے ہیں، یا Settings میں Cloud Sync Setup دوبارہ دیکھیں۔',
      );

  /// Kotlin `currentUid`: is device ka Firebase (anonymous) UID, agar pehle sign-in ho chuka; kabhi
  /// naya sign-in shuru nahi karta. Cloud Sync Setup "Device ID" dikhane ke liye. FARQ: async (Flutter
  /// mein FirebaseApp async milta hai).
  Future<String?> currentUid() async {
    final app = await CloudConfigStore.firebaseApp();
    if (app == null) return null;
    return FirebaseAuth.instanceFor(app: app).currentUser?.uid;
  }

  /// Kotlin `firestoreFor`: branch configure nahi / cloud project nahi / sign-in nahi ho saka => null
  /// (caller isay "sync nahi ho sakta" samjhe). Anonymous Auth: Firestore rules `request.auth != null`
  /// maangte hain — sirf API key wala koi bhi bahar wala data nahi chhoo sakta.
  Future<FirebaseFirestore?> firestoreFor() async {
    // Branch ke baghair kabhi cloud request nahi (galat/khali tenant mein likhne se bachao).
    if (!BranchConfigStore.isConfigured()) return null;
    final app = await CloudConfigStore.firebaseApp();
    if (app == null) return null;
    final auth = FirebaseAuth.instanceFor(app: app);
    if (auth.currentUser == null) {
      try {
        await auth.signInAnonymously();
      } catch (_) {
        return null;
      }
    }
    return FirebaseFirestore.instanceFor(app: app);
  }

  // ---------- PUSH ----------

  /// Kotlin `push(context, entry)`: ek queue entry Firestore par. true = kamyab. Kisi bhi ghalti par
  /// audit row `sync_push_failed` aur false (SyncRepository markFailed karta hai).
  ///
  /// Operations:
  ///  * `delete` — tombstone (`_deleted:true`), transaction mein, sirf jab deleteAt >= server updatedAt.
  ///  * `create_if_absent` — cash register: pehla likhne wala jeetta hai (doc na ho / tombstone ho).
  ///  * `increment_stock` / `increment_balance` — transaction + `appliedOps` (retry par dobara nahi lagta).
  ///  * baaki (`upsert`...) — last-write-wins merge, branchId hamesha maujooda.
  @override
  Future<bool> push(SyncQueueEntry entry) async {
    final fs = await firestoreFor();
    if (fs == null) return false;
    final localDb = await openDb();
    try {
      final collection = collectionFor(entry.entityType);
      if (collection == null) return false;
      final docRef = fs.collection(collection).doc(entry.entityId);
      final branch = BranchConfigStore.current;

      switch (entry.operation) {
        case 'delete':
          // Clock-skew FIX (Kotlin): tombstone ka faisla server updatedAt se; local action hamesha
          // laagu jab tak server par isse naya na ho.
          final deleteAt = nowMs();
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            final serverUpdatedAt = asMillis(snap.data()?['updatedAt']);
            if (shouldApplyDelete(deleteAt, serverUpdatedAt)) {
              tx.set(docRef, tombstone(entry.entityId, deleteAt, branch), SetOptions(merge: true));
            }
          });
          break;

        case 'create_if_absent':
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            if (canCreateIfAbsent(exists: snap.exists, data: snap.data())) {
              tx.set(docRef, st.map, SetOptions(merge: true));
            }
          });
          break;

        case 'increment_stock':
        case 'increment_balance':
          final map = decodePayload(entry.payloadJson);
          final delta = (map['delta'] as num?)?.toDouble() ?? 0.0;
          final opId = buildOpId(DeviceTag.current, entry.id, entry.createdAt);
          final ts = nowMs();
          // PULL FIX: increment ka updatedAt PUSH ke waqt ka ho (queue banne ke waqt ka nahi) — warna doosra
          // device jiska checkpoint us se aage nikal chuka ho ye balance/stock change kabhi pull nahi karta.
          final updatedAtValue = ts;
          // Transaction ke bahar (local DB async): naye doc ko is device ke record ki pehchan dene ke liye.
          final seed = await loadSeedFields(localDb,
              entityType: entry.entityType, entityId: entry.entityId);
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            final plan = planIncrement(
              exists: snap.exists,
              data: snap.data(),
              operation: entry.operation,
              delta: delta,
              updatedAtValue: updatedAtValue,
              branchId: branch,
              opId: opId,
              nowTs: ts,
              entityId: entry.entityId,
              seedFields: seed,
            );
            if (plan.skip) return;
            final write = <String, Object?>{
              plan.incrementField: FieldValue.increment(plan.delta),
              ...plan.otherFields,
            };
            tx.set(docRef, write, SetOptions(mergeFields: plan.mergeFields));
          });
          break;

        default:
          // upsert & baaki: last-write-wins; der se aane wali entry naye cloud edit ko nahi todti.
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          var skippedStale = false;
          int? skippedServerAt;
          await fs.runTransaction((tx) async {
            skippedStale = false;
            final snap = await tx.get(docRef);
            final serverUpdatedAt = asMillis(snap.data()?['updatedAt']);
            if (shouldApplyUpsert(st.incomingUpdatedAt, serverUpdatedAt)) {
              tx.set(docRef, st.map, SetOptions(merge: true));
            } else {
              skippedStale = true;
              skippedServerAt = serverUpdatedAt;
            }
          });
          // Cloud par is se naya edit pehle se tha: yeh device ka change nahi gaya. Chup chap nahi —
          // audit log mein likho (agla pull cloud ki nayi value le aayega).
          if (skippedStale) {
            await logMaintenanceAudit(
              localDb,
              username: 'sync',
              action: 'sync_push_skipped_stale',
              reference: '${entry.entityType}:${entry.entityId}',
              details: 'Local ${st.incomingUpdatedAt} < cloud $skippedServerAt — cloud ki nayi value rakhi gayi.',
            );
          }
      }
      return true;
    } catch (e) {
      await logMaintenanceAudit(
        localDb,
        username: 'sync',
        action: 'sync_push_failed',
        reference: '${entry.entityType}:${entry.entityId}',
        details: _messageOf(e),
      );
      return false;
    }
  }

  static String _messageOf(Object e) {
    if (e is FirebaseException) return e.message ?? e.code;
    final s = e.toString();
    return s.isEmpty ? 'unknown error' : s;
  }

  // ---------- PULL ----------

  /// Kotlin `pull(context, since)`: is branch ke wo sab documents jin ka `updatedAt > since`, 20
  /// collections se (server se seedha, cache nahi). Cloud project nahi / sign-in nahi ho saka => Exception
  /// (Kotlin mein khali result tha; yahan saaf ghalti taake "Already up to date" jhoota na dikhe).
  ///
  /// FARQ (Kotlin ke comment ki niyyat ke mutabiq): branch code na ho to [BranchNotConfiguredException]
  /// PEHLE — Kotlin mein `firestoreFor` branch na hone par null lauta kar khali (kamyab) result de deta
  /// tha, is liye wo exception kabhi pohanchti hi nahi thi aur user ko "Already up to date" dikhta tha.
  @override
  Future<PullResult> pull(int since) async {
    final branch = BranchConfigStore.current;
    if (branch.trim().isEmpty) {
      throw BranchNotConfiguredException(Loc.t(
        'No branch code is configured on this device — open Settings > Cloud Sync Setup and save a branch code before syncing.',
        'اس ڈیوائس پر برانچ کوڈ سیٹ نہیں ہے — Sync سے پہلے Settings > Cloud Sync Setup میں برانچ کوڈ محفوظ کریں۔',
      ));
    }
    final fs = await firestoreFor();
    if (fs == null) {
      // FIX: pehle yahan khali (kamyab) result jata tha, is liye sign-in fail / cloud na milne par bhi
      // "Already up to date" dikhta tha. Ab saaf ghalti — SyncRepository usay "Sync failed: ..." banata hai.
      throw Exception(Loc.t(
        'Could not connect to the cloud (sign-in failed or cloud project not available) — check internet and Cloud Sync Setup, then try again.',
        'کلاؤڈ سے رابطہ نہیں ہو سکا (سائن اِن ناکام یا کلاؤڈ پراجیکٹ دستیاب نہیں) — انٹرنیٹ اور Cloud Sync Setup چیک کر کے دوبارہ کوشش کریں۔',
      ));
    }

    Future<MapEntry<String, List<SyncDoc>>> load(String collection) async {
      final snap = await fs
          .collection(collection)
          .where('branchId', isEqualTo: branch)
          .where('updatedAt', isGreaterThan: since > pullOverlapMs ? since - pullOverlapMs : 0)
          .get(const GetOptions(source: Source.server));
      return MapEntry(collection, [for (final d in snap.docs) Map<String, Object?>.from(d.data())]);
    }

    final loaded = await Future.wait(pullCollections.map(load));
    return assemblePullResult(Map.fromEntries(loaded), since);
  }

  // ---------- APPLY ----------

  /// Kotlin `applyServerChanges` — logic `sync_apply.dart` (hissa 1) + `sync_apply_rest.dart` (hissa 2).
  @override
  Future<void> applyServerChanges(Database db, PullResult changes) =>
      applyServerChangesToDb(db, changes, nowMs: nowMs);

  // ---------- BRANCH CLEANUP (admin tool) ----------

  /// Kotlin `countDocsByBranchId`: `badBranchId` wale documents har branch-scoped collection mein
  /// (sirf jin mein kuch ho). Kisi collection par ghalti (missing index...) => wo collection chhod do,
  /// baqi ka result dikhao. Branch/cloud nahi => khali map.
  Future<Map<String, int>> countDocsByBranchId(String badBranchId) async {
    final fs = await firestoreFor();
    if (fs == null) return {};
    final result = <String, int>{};
    for (final col in branchScopedCollections) {
      try {
        final snap = await fs.collection(col).where('branchId', isEqualTo: badBranchId).get();
        if (snap.size > 0) result[col] = snap.size;
      } catch (_) {
        // Kotlin jaisa: ek collection ki ghalti poori scan nahi rokti.
      }
    }
    return result;
  }

  /// Kotlin `deleteDocsByBranchId`: `badBranchId` wale sab documents 400-400 ke batch mein delete
  /// (Firestore limit 500). `users` / `branch_members` ko kabhi nahi chhoota. Ghalti par us collection
  /// ki tak ki progress `result` mein rehti hai.
  Future<Map<String, int>> deleteDocsByBranchId(String badBranchId) async {
    final fs = await firestoreFor();
    if (fs == null) return {};
    final result = <String, int>{};
    for (final col in branchScopedCollections) {
      try {
        var deleted = 0;
        while (true) {
          final snap = await fs
              .collection(col)
              .where('branchId', isEqualTo: badBranchId)
              .limit(branchCleanupBatchSize)
              .get();
          if (snap.docs.isEmpty) break;
          final batch = fs.batch();
          for (final d in snap.docs) {
            batch.delete(d.reference);
          }
          await batch.commit();
          deleted += snap.size;
          if (snap.size < branchCleanupBatchSize) break;
        }
        if (deleted > 0) result[col] = deleted;
      } catch (_) {
        // Aage wali collections ka result barqarar.
      }
    }
    return result;
  }
}
