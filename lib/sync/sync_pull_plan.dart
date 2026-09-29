import 'sync_push_plan.dart' show asMillis;
import 'sync_types.dart';

/// SyncApi.pull ka SAAF hissa (Firestore ke baghair) — Kotlin `pull()` ke aakhri hisse.

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
