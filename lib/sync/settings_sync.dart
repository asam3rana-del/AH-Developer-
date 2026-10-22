import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/party_repository.dart';
import '../utils/loc.dart';
import 'branch_config_store.dart';
import 'cloud_config_store.dart';
import 'sync_api.dart';
import 'sync_queue_dao.dart';
import 'sync_queue_helper.dart';
import 'sync_repository.dart';
import 'sync_worker.dart';

/// Kotlin `SettingsSync.kt` — Settings ka Cloud Sync hissa. Yahan sirf LOGIC hai (widget nahi), taake
/// test ho sake; UI `lib/widgets/sync_section.dart` mein hai.
///
/// Kotlin functions ka nakshaa:
///  * `isNetworkConnected` / `refreshSyncStatus`  => [SettingsSync.isOnline], [computeSyncStatus], [SettingsSync.status]
///  * `onSyncNowClicked`                          => [SettingsSync.syncNow] (SyncWorker.syncNowOnce)
///  * `showResyncFromDialog`                      => [SettingsSync.resyncFrom]
///  * `resyncAllLocalDataClicked`                 => [SettingsSync.forceFullPush]
///  * `fixBackdatedCashTransactionDatesClicked`   => [SettingsSync.fixBackdatedCash]
///  * `recalculatePartyBalancesClicked`           => [SettingsSync.recalculatePartyBalances]
///  * `showDeleteByWrongBranchIdDialog`           => [SettingsSync.scanWrongBranch] / [SettingsSync.deleteWrongBranch]
///  * `openSyncHistoryDialog`                     => [SettingsSync.loadHistory] / [SettingsSync.clearHistory] / [SettingsSync.retryStuck]
///  * `openCloudSyncSetupDialog`                  => [validateCloudSetup], [SettingsSync.saveCloudSetup], [SettingsSync.disconnect]
///
/// FARQ (Kotlin se, jaan boojh kar):
///  * `recalculatePartyBalances` Flutter mein `PartyRepository.recalculateBalances()` hai (party screen ke
///    saath pehle port hui) — result mein sirf ginti (customers/suppliers fixed) hai, har party ka
///    "Rs old -> Rs new" nahi.
///  * Admin-only cleanup (ghalat Branch ID ka data delete) aur Cloud Sync Setup UI mein bhi `admin` tak
///    mehdood hain (PORTING_PLAN role rule), aur yahan bhi [SettingsSync.requireAdmin] se.

// ------------------------------------------------------------------ status

enum SyncStatusKind { notSetUp, branchMissing, connected, offline }

/// Kotlin `refreshSyncStatus` ka nateeja: dot ka rang (amber/teal/red) + likhai.
class SyncStatus {
  final SyncStatusKind kind;
  const SyncStatus(this.kind);

  /// true => amber, `connected` => teal, `offline` => red.
  bool get needsSetup => kind == SyncStatusKind.notSetUp || kind == SyncStatusKind.branchMissing;

  String get label {
    switch (kind) {
      case SyncStatusKind.notSetUp:
        return Loc.t('Not set up — tap Cloud Sync Setup', 'سیٹ اپ نہیں — Cloud Sync Setup دبائیں');
      case SyncStatusKind.branchMissing:
        return Loc.t('Branch Code missing — tap Cloud Sync Setup', 'برانچ کوڈ نہیں — Cloud Sync Setup دبائیں');
      case SyncStatusKind.connected:
        return Loc.t('Connected', 'کنیکٹڈ');
      case SyncStatusKind.offline:
        return Loc.t('Offline', 'آف لائن');
    }
  }
}

/// Kotlin `refreshSyncStatus` ki tarteeb: pehle cloud project, phir branch code, phir internet.
SyncStatus computeSyncStatus({
  required bool cloudConfigured,
  required bool branchConfigured,
  required bool online,
}) {
  if (!cloudConfigured) return const SyncStatus(SyncStatusKind.notSetUp);
  if (!branchConfigured) return const SyncStatus(SyncStatusKind.branchMissing);
  return SyncStatus(online ? SyncStatusKind.connected : SyncStatusKind.offline);
}

// ----------------------------------------------------------- cloud setup

/// Cloud Sync Setup form ki jaanch (Kotlin `Save` button). Ghalti ho to message (Loc), warna null.
/// Project ID / API Key / App ID zaroori; Storage Bucket optional; Branch Code 2-50 `[A-Za-z0-9_-]`.
String? validateCloudSetup({
  required String projectId,
  required String apiKey,
  required String appId,
  required String branchId,
}) {
  if (projectId.trim().isEmpty || apiKey.trim().isEmpty || appId.trim().isEmpty) {
    return Loc.t('Project ID, API Key and App ID are required', 'Project ID، API Key اور App ID ضروری ہیں');
  }
  if (!BranchConfigStore.isValid(branchId)) {
    return Loc.t('Branch Code must be 2-50 characters: A-Z, 0-9, _ or -',
        'برانچ کوڈ 2-50 حروف کا ہو: A-Z، 0-9، _ یا -');
  }
  return null;
}

/// Kotlin P1 security (item #4): asli Branch badalna (pehle se configured code se mukhtalif) tab tak
/// mana jab tak sync queue khali na ho — SyncApi.push har queued record par PUSH ke waqt ka
/// `BranchConfigStore.current` lagata hai, is liye offline records naye branch mein chale jate.
/// Pehli baar setup (branch abhi configured nahi) ya wahi code dobara save => guard nahi.
bool isRealBranchChange({required bool branchConfigured, required String oldBranch, required String newBranch}) =>
    branchConfigured && newBranch.trim() != oldBranch;

/// Save ka faisla: seedha save, ya pending records ki wajah se roka gaya.
class CloudSetupDecision {
  final bool blocked;
  final int pending;
  const CloudSetupDecision._(this.blocked, this.pending);
  const CloudSetupDecision.allow() : this._(false, 0);
  const CloudSetupDecision.blockedBy(int pending) : this._(true, pending);
}

CloudSetupDecision decideCloudSetupSave({
  required bool branchConfigured,
  required String oldBranch,
  required String newBranch,
  required int pendingCount,
}) {
  if (!isRealBranchChange(branchConfigured: branchConfigured, oldBranch: oldBranch, newBranch: newBranch)) {
    return const CloudSetupDecision.allow();
  }
  return pendingCount > 0 ? CloudSetupDecision.blockedBy(pendingCount) : const CloudSetupDecision.allow();
}

// ----------------------------------------------------------- audit rows

/// Kotlin `SimpleDateFormat("dd MMM, hh:mm a")` (intl ke baghair) — jaise `05 Mar, 09:07 PM`.
String formatSyncTime(int ms) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}, '
      '${h12.toString().padLeft(2, '0')}:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// Sync History ki ek qatar (Kotlin `Audit` row).
class AuditEntry {
  final int id;
  final String username;
  final String action;
  final String reference;
  final String details;
  final int createdAt;
  const AuditEntry({
    required this.id,
    required this.username,
    required this.action,
    required this.reference,
    required this.details,
    required this.createdAt,
  });

  factory AuditEntry.fromMap(Map<String, Object?> m) => AuditEntry(
        id: (m['id'] as num?)?.toInt() ?? 0,
        username: (m['username'] as String?) ?? '',
        action: (m['action'] as String?) ?? '',
        reference: (m['reference'] as String?) ?? '',
        details: (m['details'] as String?) ?? '',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );

  bool get isConflict => action == 'sync_conflict';
  bool get isPushFailure => action == 'sync_push_failed';

  /// Kotlin: conflict/failure ke saath `— reference`, baqi sirf reference.
  String get title {
    if (isConflict) return Loc.t('Conflict — $reference', 'ٹکراؤ — $reference');
    if (isPushFailure) return Loc.t('Push failed — $reference', 'پش ناکام — $reference');
    return reference;
  }
}

/// Sync History ka poora manzar: atke hue (10 baar fail) items + audit ki taaza qataren.
class SyncHistory {
  final int stuckCount;
  final List<AuditEntry> entries;
  const SyncHistory({required this.stuckCount, required this.entries});
}

// ----------------------------------------------------------- the actions

/// Kotlin Settings ke sync actions. Sab `static` aur inject-able (test ke liye `openDb`, `isOnline`).
class SettingsSync {
  SettingsSync._();

  /// Kotlin `AuditDao.recent()` — `LIMIT 300`.
  static const int historyLimit = 300;

  static Future<Database> Function() openDb = () => AppDatabase.instance.database;

  static Future<bool> Function() isOnline = () async {
    final r = await Connectivity().checkConnectivity();
    return r.any((c) => c != ConnectivityResult.none);
  };

  static Future<bool> Function() cloudConfigured = () async => (await CloudConfigStore.firebaseApp()) != null;

  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  // ---- status

  static Future<SyncStatus> status() async => computeSyncStatus(
        cloudConfigured: await cloudConfigured(),
        branchConfigured: BranchConfigStore.isConfigured(),
        online: await isOnline(),
      );

  // ---- Sync Now

  /// Kotlin `onSyncNowClicked`: internet nahi => `null` (caller "No internet connection" dikhaye);
  /// warna sync chalao aur natija ka summary lautao ("Sync complete" jab summary khali ho).
  static Future<String?> syncNow() async {
    if (!await isOnline()) return null;
    final o = await SyncWorker.instance.syncNowOnce();
    if (o.summary.isNotEmpty) return o.summary;
    return o.success ? 'Sync complete' : 'Sync failed';
  }

  /// Kotlin `showResyncFromDialog`: pull checkpoint [from] par wapas (sirf pull badalta hai, push queue
  /// nahi). Sync chalana caller ka kaam (Kotlin `onSyncNowClicked()`).
  static Future<void> resyncFrom(DateTime from) => SyncRepository.resetSyncCheckpoint(from.millisecondsSinceEpoch);

  // ---- one-off repairs (har ek ke baad caller Sync Now chalata hai, Kotlin jaisa)

  /// Kotlin `resyncAllLocalDataClicked`.
  static Future<void> forceFullPush() async {
    final db = await openDb();
    await SyncQueueHelper.resyncAllLocalData(db);
  }

  /// Cloud par har product ka stock is device ke stock jaisa (absolute). Kitne products queue hue.
  static Future<int> pushStockToCloud() async {
    final db = await openDb();
    return SyncQueueHelper.enqueueStockSetAll(db);
  }

  /// Kotlin `fixBackdatedCashTransactionDatesClicked` — kitni cash entries theek hui.
  static Future<int> fixBackdatedCash() async {
    final db = await openDb();
    return SyncQueueHelper.fixBackdatedCashTransactionDates(db);
  }

  /// Kotlin `recalculatePartyBalancesClicked`: `PartyRepository.recalculateBalances()` (aik hi copy —
  /// party screen wala). Balance sync delta ke zariye nahi, poora snapshot queue hota hai, is liye
  /// caller ke baad Sync Now chalaye.
  static Future<RecalcResult> recalculatePartyBalances() => PartyRepository.instance.recalculateBalances();

  // ---- ghalat Branch ID ka cloud data (admin cleanup)

  /// Admin ke ilawa koi nahi (PORTING_PLAN role rule) — UI ke ilawa data layer par bhi.
  static bool requireAdmin(String role) => role == 'admin';

  /// Scan se pehle ki jaanch: khali / is device ki apni branch => message, warna null.
  static String? checkWrongBranchInput(String input) {
    final bad = input.trim();
    if (bad.isEmpty) return Loc.t('Branch ID is required.', 'برانچ آئی ڈی لکھنا ضروری ہے۔');
    if (bad == BranchConfigStore.current) {
      return Loc.t("This is this device's own Branch ID — cancelled.", 'یہ تو اس ڈیوائس کی اپنی برانچ آئی ڈی ہے — منسوخ۔');
    }
    return null;
  }

  static Future<Map<String, int>> scanWrongBranch(String badId) => SyncApi.instance.countDocsByBranchId(badId.trim());

  static Future<Map<String, int>> deleteWrongBranch(String badId) {
    // Double-check: apni branch kabhi nahi (UI se bach kar aaye to bhi).
    if (badId.trim() == BranchConfigStore.current) return Future.value(<String, int>{});
    return SyncApi.instance.deleteDocsByBranchId(badId.trim());
  }

  /// `"col: n"` har line par (Kotlin `joinToString("\n")`).
  static String countsSummary(Map<String, int> counts) => counts.entries.map((e) => '${e.key}: ${e.value}').join('\n');

  // ---- Sync History

  static Future<SyncHistory> loadHistory() async {
    final db = await openDb();
    var stuck = 0;
    try {
      stuck = (await SyncQueueDao(db).stuck()).length;
    } catch (_) {}
    var rows = <Map<String, Object?>>[];
    try {
      rows = await db.query('audit', orderBy: 'createdAt DESC, id DESC', limit: historyLimit);
    } catch (_) {}
    return SyncHistory(stuckCount: stuck, entries: [for (final r in rows) AuditEntry.fromMap(r)]);
  }

  /// Kotlin `AuditDao.clearAll()` — sirf local diagnostic log (cloud par kabhi nahi jata).
  static Future<void> clearHistory() async {
    final db = await openDb();
    await db.delete('audit');
  }

  /// "Retry Now": 10 baar fail hue items ko agli Sync Now par dobara mauqa.
  static Future<void> retryStuck() async {
    final db = await openDb();
    await SyncQueueDao(db).resetAllStuck();
  }

  // ---- Cloud Sync Setup

  static Future<int> pendingCount() async {
    final db = await openDb();
    return SyncQueueDao(db).pendingCount();
  }

  /// Kotlin `doSave()`.
  static Future<void> saveCloudSetup({
    required String projectId,
    required String apiKey,
    required String appId,
    required String storageBucket,
    required String branchId,
  }) async {
    await CloudConfigStore.save(CloudConfig(
      projectId: projectId,
      apiKey: apiKey,
      appId: appId,
      storageBucket: storageBucket,
    ));
    await BranchConfigStore.set(branchId);
  }

  /// Kotlin Disconnect (pending check ke baad): cloud project aur branch code dono saaf.
  static Future<void> disconnect() async {
    await CloudConfigStore.clear();
    await BranchConfigStore.clear();
  }

  /// Device ID (Firebase anonymous UID) — pehli sync se pehle null.
  static Future<String?> deviceId() => SyncApi.instance.currentUid();

  /// Kotlin `SyncQueueHelper.trigger` (Cloud Setup ke "Sync Now" button ke liye).
  static Future<void> trigger() => SyncWorker.instance.triggerNow();
}

// ----------------------------------------------------------------- wiring

/// Sync ke tamam hisse ek jagah jorta hai (`main()` mein Firebase/DeviceTag/Branch init ke BAAD):
///  * `SyncRepository.backend = SyncApi.instance` (Phase 10 ka aakhri jor — ab Flutter repositories
///    `SyncQueueHelper` se Android-shape payload likhte hain, is liye backend lagana mehfooz hai),
///  * `SyncRepository.afterApply = mergeOwnDuplicateExpenses` (Kotlin `SyncRepository` ka repair hook),
///  * `SyncQueueHelper.onQueued = SyncWorker.triggerNow` (Kotlin `SyncQueueHelper.trigger`).
/// Dobara bulana mehfooz hai.
void installSyncWiring() {
  SyncRepository.backend = SyncApi.instance;
  SyncRepository.afterApply = (db) async {
    await SyncQueueHelper.mergeOwnDuplicateExpenses(db);
  };
  SyncQueueHelper.onQueued = () => SyncWorker.instance.triggerNow();
}
