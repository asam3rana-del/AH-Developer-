import '../utils/loc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import 'cloud_config_store.dart';
import 'sync_queue_dao.dart';
import 'sync_types.dart';

/// Kotlin `SyncRepository.kt` — SyncApi (Firestore) ko local DB se jorta hai.
/// `SyncRepository.syncNow()` ek poora cycle chalata hai:
///   1. sync_queue ki har pending row Firestore par PUSH
///   2. pichli kamyab sync ke baad server par jo badla, PULL
///   3. pulled changes local tables mein APPLY
class SyncRepository {
  SyncRepository._();

  static const String prefsLastSync = 'sync_prefs.last_sync_time';

  /// Push ki had per cycle (Kotlin `pending(limit = 200)`).
  static const int pushBatchLimit = 200;

  /// Synced rows itne purani hon to hata di jati hain (7 din).
  static const int pruneAfterMs = 7 * 24 * 60 * 60 * 1000;

  /// Asli backend (SyncApi) — main() mein set hota hai. Tests fake dete hain.
  static SyncBackend? backend;

  /// "Cloud set up hai?" — default: custom config ya build ka default Firebase app. Tests badalte hain.
  static Future<bool> Function() isCloudReady =
      () async => (await CloudConfigStore.firebaseApp()) != null;

  /// Pull ke baad ka safai kaam (Kotlin `SyncQueueHelper.mergeOwnDuplicateExpenses(db)`); SyncQueueHelper
  /// port hone par yahan jurega. Kabhi sync nahi rokta — throw bhi kare to nazar-andaz.
  static Future<void> Function(Database db)? afterApply;

  /// Local DB kholne ka tareeqa — tests in-memory DB dete hain.
  static Future<Database> Function() openDb = () => AppDatabase.instance.database;

  /// Test ke liye clock.
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// Pull ka checkpoint `timestampMillis` par wapas — agli syncNow() us waqt ke baad ka sab dobara pull
  /// karegi (Settings "Sync Now" long-press > "Resync from a specific time"). Push queue ko nahi chhoota.
  static Future<void> resetSyncCheckpoint(int timestampMillis) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(prefsLastSync, timestampMillis);
  }

  static Future<int> lastSyncTime() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(prefsLastSync) ?? 0;
  }

  static Future<SyncResult> syncNow() async {
    // Kotlin FIX (multi-tenant): koi Firebase project hi nahi => saaf batao, chupke na chalo.
    if (!await isCloudReady()) {
      return SyncResult(
        pushedCount: 0,
        failedCount: 0,
        pulledOk: false,
        error: 'Cloud sync not set up — add your project in Settings > Cloud Sync Setup',
      );
    }
    final api = backend;
    if (api == null) {
      return SyncResult(
          pushedCount: 0, failedCount: 0, pulledOk: false, error: 'Sync backend not initialised');
    }

    final db = await openDb();
    final queue = SyncQueueDao(db);

    var pushed = 0;
    var failed = 0;
    String? pushBlocked; // server ne push rad kiya (permission denied) — retryCount nahi barhta

    // ---- 1. PUSH ----
    // Pehle quota ki wajah se stuck hui entries wapas pending (quota reset ho chuka ho sakta hai).
    await queue.resetQuotaStuck();
    final pending = await queue.pending(limit: pushBatchLimit);
    for (final entry in pending) {
      var ok = false;
      var offline = false;
      String error = 'push failed';
      try {
        // Timeout: koi push (Firestore transaction / sign-in) atak jaye to poori sync hamesha ke liye na ruke.
        ok = await api.push(entry).timeout(const Duration(seconds: 45));
      } catch (e) {
        ok = false; // ek entry ka crash poori sync na roke
        if (e is SyncPermissionDeniedException || api.isPermissionDenied(e)) {
          // Security rules ka masla poori queue ka hai: retryCount na barhao (warna rules theek hone se
          // pehle sab entries 10 baar fail ho kar stuck ho jati hain), baqi bhi abhi na bhejo.
          pushBlocked = e is SyncPermissionDeniedException ? e.message : api.permissionDeniedMessage();
          break;
        }
        offline = isNetworkError(e);
        // Quota khatam: user ko Sync Now ke natije mein saaf dikhao (chup chap "Already up to date" nahi).
        if (e is SyncOfflineException && looksLikeQuotaMessage(e.message)) pushBlocked = e.message;
        // Push kisi bhi wajah se ruka (sign-in / network / server): asli wajah Sync Now ke natije mein dikhao.
        if (offline) pushBlocked ??= error.length > 200 ? error.substring(0, 200) : error;
        error = _messageOf(e);
        if (error.length > 300) error = error.substring(0, 300);
      }
      if (offline) {
        // Internet nahi: retryCount na barhao, baqi entries bhi abhi na bhejo (agli sync par chalengi).
        break;
      }
      if (ok) {
        await queue.markSynced(entry.id!);
        pushed++;
      } else {
        // Asli wajah lastError mein (Sync History / stuck list mein dikhti hai).
        await queue.markFailed(entry.id!, error);
        failed++;
      }
    }

    // ---- 2. PULL ----
    final p = await SharedPreferences.getInstance();
    final since = p.getInt(prefsLastSync) ?? 0;

    final pullStartedAt = nowMs();
    final PullResult changes;
    try {
      changes = await api.pull(since).timeout(const Duration(seconds: 90));
    } on BranchNotConfiguredException catch (e) {
      return SyncResult(
          pushedCount: pushed, failedCount: failed, pulledOk: false, error: pushBlocked ?? e.message);
    } catch (e) {
      final msg = api.isPermissionDenied(e)
          ? api.permissionDeniedMessage()
          : isNetworkError(e)
              ? Loc.t(
                  'Cloud is not reachable right now (no/slow internet or Firebase temporarily down). Your data is safe on this device and will sync automatically — try Sync again in a minute. If it keeps happening: try mobile data instead of Wi-Fi, and check Firebase status.',
                  'کلاؤڈ ابھی دستیاب نہیں (انٹرنیٹ نہیں/سست یا Firebase عارضی بند)۔ آپ کا ڈیٹا اس ڈیوائس پر محفوظ ہے اور خود سنک ہو جائے گا — ایک منٹ بعد دوبارہ Sync کریں۔ بار بار ہو تو Wi-Fi کی جگہ موبائل ڈیٹا آزمائیں۔',
                )
              : _messageOf(e);
      return SyncResult(pushedCount: pushed, failedCount: failed, pulledOk: false, error: msg);
    }

    // ---- 3. APPLY ----
    await api.applyServerChanges(db, changes);
    final repair = afterApply;
    if (repair != null) {
      try {
        await repair(db);
      } catch (_) {/* sync kabhi nahi rukti */}
    }

    // CLOCK-SKEW FIX: kisi device ki clock aage ho to uska updatedAt checkpoint ko future mein le jata tha aur
    // baqi devices ke docs skip hote the. Checkpoint kabhi is pull ke start se aage nahi.
    final checkpoint = changes.serverTime < pullStartedAt ? changes.serverTime : pullStartedAt;
    await p.setInt(prefsLastSync, checkpoint);

    // Safai: 7 din se purani synced queue rows.
    await queue.pruneSynced(nowMs() - pruneAfterMs);

    return SyncResult(
      pushedCount: pushed,
      failedCount: failed,
      pulledOk: true,
      pushError: pushBlocked,
      customersReceived: changes.customers.length,
      suppliersReceived: changes.suppliers.length,
      productsReceived: changes.products.length,
      salesReceived: changes.sales.length,
      purchasesReceived: changes.purchases.length,
      expensesReceived: changes.expenses.length,
      cashTxReceived: changes.cashTransactions.length,
      unitsReceived: changes.units.length,
      categoriesReceived: changes.categories.length,
      zakatReceived: changes.zakatYears.length + changes.zakatPayments.length,
      returnsReceived: changes.returns.length,
      appSettingsReceived: changes.appSettings.length,
      cashRegistersReceived: changes.cashRegisters.length,
      workersReceived: changes.workers.length +
          changes.workerAttendance.length +
          changes.workerAdvances.length +
          changes.workerSalaryPayments.length +
          changes.shopRents.length +
          changes.shopRentEntries.length +
          changes.utilityBills.length +
          changes.utilityBillPayments.length,
    );
  }

  static String _messageOf(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }
}

/// Kotlin `SyncRepository.SyncResult`.
class SyncResult {
  final int pushedCount;
  final int failedCount;
  final bool pulledOk;
  final int customersReceived;
  final int suppliersReceived;
  final int productsReceived;
  final int salesReceived;
  final int purchasesReceived;
  final int expensesReceived;
  final int cashTxReceived;
  final int unitsReceived;
  final int categoriesReceived;
  final int zakatReceived;
  final int returnsReceived;
  final int appSettingsReceived;
  final int cashRegistersReceived;
  final int workersReceived;
  final String? error;

  /// Push server ne rad kiya (permission denied) lekin pull chal gaya — user ko batana zaroori hai.
  final String? pushError;

  const SyncResult({
    required this.pushedCount,
    required this.failedCount,
    required this.pulledOk,
    this.customersReceived = 0,
    this.suppliersReceived = 0,
    this.productsReceived = 0,
    this.salesReceived = 0,
    this.purchasesReceived = 0,
    this.expensesReceived = 0,
    this.cashTxReceived = 0,
    this.unitsReceived = 0,
    this.categoriesReceived = 0,
    this.zakatReceived = 0,
    this.returnsReceived = 0,
    this.appSettingsReceived = 0,
    this.cashRegistersReceived = 0,
    this.workersReceived = 0,
    this.error,
    this.pushError,
  });

  int get totalReceived =>
      customersReceived +
      suppliersReceived +
      productsReceived +
      salesReceived +
      purchasesReceived +
      expensesReceived +
      cashTxReceived +
      unitsReceived +
      categoriesReceived +
      zakatReceived +
      returnsReceived +
      appSettingsReceived +
      cashRegistersReceived +
      workersReceived;

  /// Settings "Sync Now" ke liye ek line — Kotlin `summary()` jaisi (English).
  String summary() {
    if (!pulledOk) return 'Sync failed: ${error ?? 'unknown error'}';
    final parts = <String>[];
    if (pushedCount > 0) parts.add('sent $pushedCount');
    if (totalReceived > 0) parts.add('received $totalReceived');
    if (failedCount > 0) parts.add('$failedCount failed');
    if (pushError != null) parts.add('push blocked: $pushError');
    if (parts.isEmpty) return 'Already up to date';
    final s = parts.join(', ');
    return s[0].toUpperCase() + s.substring(1);
  }
}
