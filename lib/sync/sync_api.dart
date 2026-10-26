import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/maintenance_sync.dart';
import '../models/misc_entities.dart';
import '../utils/qty_math.dart';
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
        await auth.signInAnonymously().timeout(const Duration(seconds: 20));
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
    // Branch/cloud/sign-in nahi mil saka (aksar internet nahi => anonymous sign-in fail): ye is entry ki
    // ghalti nahi — retryCount na barhao, push rok do (pull saaf wajah batayega).
    if (fs == null) {
      throw const SyncOfflineException('Cloud not reachable (sign-in failed, no branch code or no cloud project)');
    }
    final localDb = await openDb();
    try {
      final collection = collectionFor(entry.entityType);
      if (collection == null) throw SyncPushException('Unknown entity type: ${entry.entityType}');
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
              tx.set(docRef, {...tombstone(entry.entityId, deleteAt, branch), 'pushedAt': deleteAt}, SetOptions(merge: true));
            }
          });
          break;

        case 'create_if_absent':
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          final createPushedAt = nowMs();
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            if (canCreateIfAbsent(exists: snap.exists, data: snap.data())) {
              tx.set(docRef, {...st.map, 'pushedAt': createPushedAt}, SetOptions(merge: true));
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
          var diagSkipped = false;
          num? diagBefore;
          double? diagNew;
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            diagBefore = snap.data()?['stock'] as num?;
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
            diagSkipped = plan.skip;
            if (plan.skip) return;
            // STOCK FIX: pehle yahan FieldValue.increment + SetOptions(mergeFields) tha — cloud par updatedAt/appliedOps
            // to badalte the magar stock/balance WAHI rehta tha (har stock take ka +250 cloud par zaya ho jata tha,
            // phir pull local stock ko purani cloud value par wapas kar deta). Ab transaction ke andar padhi hui
            // maujooda value + delta seedha likhte hain. Transaction conflict par khud dobara chalta hai, isliye
            // do device ek saath badlein to bhi increment jaisa hi safe hai.
            final curRaw = snap.data()?[plan.incrementField];
            final cur = curRaw is num ? curRaw.toDouble() : 0.0;
            diagNew = plan.incrementField == 'stock' ? roundQty(cur + plan.delta) : cur + plan.delta;
            final write = <String, Object?>{
              plan.incrementField: diagNew,
              ...plan.otherFields,
              'pushedAt': ts,
            };
            tx.set(docRef, write, SetOptions(mergeFields: plan.mergeFields));
          });
          // STOCK DIAGNOSTIC: har product stock increment ka natija Sync History mein.
          if (entry.entityType == 'product') {
            await logMaintenanceAudit(localDb,
                username: 'sync',
                action: 'stock_inc_push',
                reference: 'product:${entry.entityId}',
                details: 'queue#${entry.id} delta $delta cloudBefore ${diagBefore ?? 'n/a'} cloudWritten ${diagNew ?? 'n/a'} skipped $diagSkipped');
          }
          break;

        case 'set_stock':
          // ABSOLUTE stock (increment nahi): cloud ka total is device ke total par. Naya/tombstone doc ho
          // to seed fields bhi (bina naam ka ghost doc na bane). updatedAt push ke waqt ka, taake doosre
          // devices ka pull ye doc dobara utha le.
          final setStock = (decodePayload(entry.payloadJson)['stock'] as num?)?.toDouble() ?? 0.0;
          final setTs = nowMs();
          // STOCK DIAGNOSTIC: cloud ka stock absolute set hone se pehle purani cloud value likho.
          num? prevCloud;
          try {
            prevCloud = (await docRef.get()).data()?['stock'] as num?;
          } catch (_) {}
          await logMaintenanceAudit(localDb,
              username: 'sync',
              action: 'cloud_stock_set',
              reference: '${entry.entityType}:${entry.entityId}',
              details: 'cloud stock ${prevCloud ?? 'n/a'} -> $setStock (set_stock push)');
          final setSeed = await loadSeedFields(localDb,
              entityType: entry.entityType, entityId: entry.entityId);
          await fs.runTransaction((tx) async {
            final snap = await tx.get(docRef);
            final isNew = !snap.exists || snap.data()?['_deleted'] == true;
            tx.set(
              docRef,
              <String, Object?>{
                'stock': setStock,
                'updatedAt': setTs,
                'pushedAt': setTs,
                'branchId': branch,
                if (isNew) ...{'serverId': entry.entityId, '_deleted': false, ...setSeed},
              },
              SetOptions(merge: true),
            );
          });
          break;

        default:
          // upsert & baaki: last-write-wins; der se aane wali entry naye cloud edit ko nahi todti.
          final st = stampPayload(decodePayload(entry.payloadJson), branch, nowMs());
          // pushedAt = cloud par pahunchne ka waqt. updatedAt (last-write-wins ke liye) banne ke waqt ka
          // rehta hai; der se (offline ke baad) aane wali entry ko doosre devices pushedAt se pull karte hain.
          final upsertPushedAt = nowMs();
          var skippedStale = false;
          int? skippedServerAt;
          await fs.runTransaction((tx) async {
            skippedStale = false;
            final snap = await tx.get(docRef);
            // Stale-check sirf upsert ki apni clock (upsertAt) se — increment_stock ka updatedAt bump isay na roke.
            final serverUpdatedAt = upsertClock(snap.data());
            if (shouldApplyUpsert(st.incomingUpdatedAt, serverUpdatedAt)) {
              tx.set(
                  docRef,
                  {...st.map, 'upsertAt': st.incomingUpdatedAt, 'pushedAt': upsertPushedAt},
                  SetOptions(merge: true));
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
      // Internet nahi => failure ginti mein nahi; entry pending rahe gi (SyncRepository push rok deta hai).
      if (e is SyncOfflineException || e is SyncPermissionDeniedException) rethrow;
      if (isNetworkError(e)) throw SyncOfflineException(_messageOf(e));
      if (isQuotaError(e)) {
        await logMaintenanceAudit(localDb,
            username: 'sync', action: 'sync_quota_exhausted', reference: '${entry.entityType}:${entry.entityId}', details: _messageOf(e));
        throw SyncOfflineException('Firestore quota khatam — baad mein dobara try hoga: ${_messageOf(e)}');
      }
      final denied = isPermissionDenied(e);
      final msg = denied ? permissionDeniedMessage() : _messageOf(e);
      await logMaintenanceAudit(
        localDb,
        username: 'sync',
        action: 'sync_push_failed',
        reference: '${entry.entityType}:${entry.entityId}',
        details: _messageOf(e),
      );
      if (denied) throw SyncPermissionDeniedException(msg);
      throw SyncPushException(msg);
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
      final overlap = stockPullCollections.contains(collection) ? stockPullOverlapMs : pullOverlapMs;
      final threshold = since > overlap ? since - overlap : 0;
      final snap = await fs
          .collection(collection)
          .where('branchId', isEqualTo: branch)
          .where('updatedAt', isGreaterThan: threshold)
          .get(const GetOptions(source: Source.server));
      final byId = <String, SyncDoc>{for (final d in snap.docs) d.id: Map<String, Object?>.from(d.data())};

      // Der se push hui entries (device offline tha): unka updatedAt purana hota hai, isliye upar wali
      // query unhein miss karti hai. pushedAt (cloud par aane ka waqt) se unhein bhi uthao.
      // Index (branchId+pushedAt) deploy na ho to ye query fail hogi — tab purana behavior (sirf updatedAt).
      try {
        final late = await fs
            .collection(collection)
            .where('branchId', isEqualTo: branch)
            .where('pushedAt', isGreaterThan: threshold)
            .get(const GetOptions(source: Source.server));
        for (final d in late.docs) {
          byId.putIfAbsent(d.id, () => Map<String, Object?>.from(d.data()));
        }
      } catch (_) {
        // pushedAt index abhi deploy nahi hua (firebase/firestore.indexes.json) — updatedAt wali pull chalti rahe.
      }
      return MapEntry(collection, byId.values.toList());
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
