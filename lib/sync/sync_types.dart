import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';

/// Kotlin `SyncApi.BranchNotConfiguredException`.
class BranchNotConfiguredException implements Exception {
  final String message;
  const BranchNotConfiguredException(this.message);
  @override
  String toString() => message;
}

typedef SyncDoc = Map<String, Object?>;

/// Kotlin `SyncApi.PullResult` — server se aayi hui badli hui documents, collection ke hisaab se.
class PullResult {
  final List<SyncDoc> customers;
  final List<SyncDoc> suppliers;
  final List<SyncDoc> products;
  final List<SyncDoc> users;
  final List<SyncDoc> sales;
  final List<SyncDoc> purchases;
  final List<SyncDoc> payments;
  final List<SyncDoc> expenses;
  final List<SyncDoc> cashTransactions;
  final List<SyncDoc> units;
  final List<SyncDoc> categories;
  final List<SyncDoc> zakatYears;
  final List<SyncDoc> zakatPayments;
  final List<SyncDoc> returns;
  final List<SyncDoc> stockMovements;
  final List<SyncDoc> appSettings;
  final List<SyncDoc> cashRegisters;
  final List<SyncDoc> shellCustomers;
  final List<SyncDoc> shellTransactions;
  final List<SyncDoc> shopEmptyShellLogs;

  /// Agli pull ka checkpoint (ms).
  final int serverTime;

  PullResult({
    this.customers = const [],
    this.suppliers = const [],
    this.products = const [],
    this.users = const [],
    this.sales = const [],
    this.purchases = const [],
    this.payments = const [],
    this.expenses = const [],
    this.cashTransactions = const [],
    this.units = const [],
    this.categories = const [],
    this.zakatYears = const [],
    this.zakatPayments = const [],
    this.returns = const [],
    this.stockMovements = const [],
    this.appSettings = const [],
    this.cashRegisters = const [],
    this.shellCustomers = const [],
    this.shellTransactions = const [],
    this.shopEmptyShellLogs = const [],
    int? serverTime,
  }) : serverTime = serverTime ?? DateTime.now().millisecondsSinceEpoch;
}

/// SyncRepository jis se baat karta hai (Kotlin mein seedha `SyncApi` object). `SyncApi` (agli file)
/// isay implement karegi; tests mein fake lagta hai.
abstract class SyncBackend {
  /// Ek queue entry Firestore par push. true = kamyab.
  Future<bool> push(SyncQueueEntry entry);

  /// `since` ke baad badla hua sab kuch. Branch code na ho => [BranchNotConfiguredException].
  Future<PullResult> pull(int since);

  /// Pull ki hui changes local tables mein (ek merge).
  Future<void> applyServerChanges(Database db, PullResult changes);

  /// Firestore PERMISSION_DENIED?
  bool isPermissionDenied(Object e);

  /// PERMISSION_DENIED ka insaani paighaam (Loc English/Urdu).
  String permissionDeniedMessage();
}
