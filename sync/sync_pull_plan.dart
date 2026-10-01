import 'sync_push_plan.dart' show asMillis;
import 'sync_types.dart';

/// SyncApi.pull ka SAAF hissa (Firestore ke baghair) — Kotlin `pull()` ke aakhri hisse.

/// Pull har baar checkpoint se itna pichhe se shuru hota hai (late-push / thora clock farq ke docs na chhoote).
/// Apply idempotent hai, is liye dobara pull nuqsan nahi karta.
const int pullOverlapMs = 2 * 60 * 1000;

/// Kotlin `pull()` ki tarteeb mein 20 collections (Firestore naam).
const List<String> pullCollections = [
  'customers',
  'suppliers',
  'products',
  'users',
  'sales',
  'purchases',
  'payments',
  'expenses',
  'cash_transactions',
  'units',
  'categories',
  'zakat_years',
  'zakat_payments',
  'returns',
  'stock_movements',
  'app_settings',
  'cash_register',
  'shell_customers',
  'shell_transactions',
  'shop_empty_shell_log',
];

/// Har collection ke documents (`byCollection[collectionName]`) se `PullResult` banao.
/// `serverTime` = sab documents mein sab se bara numeric `updatedAt` (kam az kam `since`) — agli pull
/// ka checkpoint. `updatedAt` ke baghair document checkpoint ko nahi badhata (Kotlin `?: continue`).
PullResult assemblePullResult(Map<String, List<SyncDoc>> byCollection, int since) {
  List<SyncDoc> of(String c) => byCollection[c] ?? const [];
  var maxUpdatedAt = since;
  for (final c in pullCollections) {
    for (final d in of(c)) {
      final t = asMillis(d['updatedAt']);
      if (t != null && t > maxUpdatedAt) maxUpdatedAt = t;
    }
  }
  return PullResult(
    customers: of('customers'),
    suppliers: of('suppliers'),
    products: of('products'),
    users: of('users'),
    sales: of('sales'),
    purchases: of('purchases'),
    payments: of('payments'),
    expenses: of('expenses'),
    cashTransactions: of('cash_transactions'),
    units: of('units'),
    categories: of('categories'),
    zakatYears: of('zakat_years'),
    zakatPayments: of('zakat_payments'),
    returns: of('returns'),
    stockMovements: of('stock_movements'),
    appSettings: of('app_settings'),
    cashRegisters: of('cash_register'),
    shellCustomers: of('shell_customers'),
    shellTransactions: of('shell_transactions'),
    shopEmptyShellLogs: of('shop_empty_shell_log'),
    serverTime: maxUpdatedAt,
  );
}

/// Kotlin `SyncApi.BRANCH_SCOPED_COLLECTIONS` — ghalat/foreign branchId cleanup (count/delete) in hi
/// collections par chalta hai. Jaan boojh kar `users` (login/permission data) aur shell_* shamil NAHI
/// (Kotlin jaisa).
const List<String> branchScopedCollections = [
  'customers',
  'suppliers',
  'products',
  'sales',
  'purchases',
  'payments',
  'expenses',
  'cash_transactions',
  'units',
  'categories',
  'zakat_years',
  'zakat_payments',
  'returns',
  'stock_movements',
  'app_settings',
  'cash_register',
];

/// Firestore batch delete ka hissa (limit 500 se neeche) — Kotlin `.limit(400)`.
const int branchCleanupBatchSize = 400;
