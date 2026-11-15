/// Mirrors `data class Payment` (table: payments, PK: id autoincrement).
class Payment {
  final int? id;
  final String reference;
  final String partyType;
  final int? partyId;
  final double amount;
  final String method;
  final String note;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  /// Bill (sale invoice / purchase billNo) this payment is linked to; '' = general
  /// (Kotlin Payment.billReference, DB v5).
  final String billReference;

  const Payment({
    this.id,
    required this.reference,
    required this.partyType,
    this.partyId,
    required this.amount,
    required this.method,
    this.note = '',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
    this.billReference = '',
  });

  Payment copyWith({
    double? amount,
    String? method,
    String? note,
    int? createdAt,
    int? updatedAt,
    bool? dirty,
    String? billReference,
  }) =>
      Payment(
        id: id,
        reference: reference,
        partyType: partyType,
        partyId: partyId,
        amount: amount ?? this.amount,
        method: method ?? this.method,
        note: note ?? this.note,
        createdAt: createdAt ?? this.createdAt,
        serverId: serverId,
        updatedAt: updatedAt ?? this.updatedAt,
        dirty: dirty ?? this.dirty,
        billReference: billReference ?? this.billReference,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'reference': reference,
        'partyType': partyType,
        'partyId': partyId,
        'amount': amount,
        'method': method,
        'note': note,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
        'billReference': billReference,
      };

  factory Payment.fromMap(Map<String, Object?> m) => Payment(
        id: m['id'] as int?,
        reference: m['reference'] as String,
        partyType: m['partyType'] as String,
        partyId: m['partyId'] as int?,
        amount: (m['amount'] as num).toDouble(),
        method: m['method'] as String,
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
        billReference: (m['billReference'] as String?) ?? '',
      );
}

/// Mirrors `data class ReturnLine` (table: returns, PK: id autoincrement).
class ReturnLine {
  final int? id;
  final String reference;
  final String type;
  final String barcode;
  final double qty;
  final double amount;
  final int createdAt;

  const ReturnLine({
    this.id,
    required this.reference,
    required this.type,
    required this.barcode,
    required this.qty,
    required this.amount,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'reference': reference,
        'type': type,
        'barcode': barcode,
        'qty': qty,
        'amount': amount,
        'createdAt': createdAt,
      };

  factory ReturnLine.fromMap(Map<String, Object?> m) => ReturnLine(
        id: m['id'] as int?,
        reference: m['reference'] as String,
        type: m['type'] as String,
        barcode: m['barcode'] as String,
        qty: (m['qty'] as num).toDouble(),
        amount: (m['amount'] as num).toDouble(),
        createdAt: (m['createdAt'] as num).toInt(),
      );
}

/// Mirrors `data class User` (table: users, PK: username).
class User {
  final String username;
  final String displayName;
  final String role;
  final String passwordHash;
  final bool active;
  final String phone;

  const User({
    required this.username,
    required this.displayName,
    required this.role,
    required this.passwordHash,
    this.active = true,
    this.phone = '',
  });

  Map<String, Object?> toMap() => {
        'username': username,
        'displayName': displayName,
        'role': role,
        'passwordHash': passwordHash,
        'active': active ? 1 : 0,
        'phone': phone,
      };

  factory User.fromMap(Map<String, Object?> m) => User(
        username: m['username'] as String,
        displayName: m['displayName'] as String,
        role: m['role'] as String,
        passwordHash: m['passwordHash'] as String,
        active: (m['active'] as int?) != 0,
        phone: (m['phone'] as String?) ?? '',
      );
}

/// Mirrors `data class Expense` (table: expenses, PK: id autoincrement).
class Expense {
  final int? id;
  final String category;
  final String description;
  final double amount;

  /// Drawer the expense was paid from: 'cash' or 'bank' (DB v6, Kotlin Expense.method).
  final String method;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const Expense({
    this.id,
    required this.category,
    required this.description,
    required this.amount,
    this.method = 'cash',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'category': category,
        'description': description,
        'amount': amount,
        'method': method,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory Expense.fromMap(Map<String, Object?> m) => Expense(
        id: m['id'] as int?,
        category: m['category'] as String,
        description: m['description'] as String,
        amount: (m['amount'] as num).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Mirrors `data class CashTransaction` (table: cash_transactions, PK: id autoincrement).
class CashTransaction {
  final int? id;
  final String type;
  final String method;
  final double amount;
  final String reason;
  final String reference;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const CashTransaction({
    this.id,
    required this.type,
    required this.method,
    required this.amount,
    this.reason = '',
    this.reference = '',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'type': type,
        'method': method,
        'amount': amount,
        'reason': reason,
        'reference': reference,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory CashTransaction.fromMap(Map<String, Object?> m) => CashTransaction(
        id: m['id'] as int?,
        type: m['type'] as String,
        method: m['method'] as String,
        amount: (m['amount'] as num).toDouble(),
        reason: (m['reason'] as String?) ?? '',
        reference: (m['reference'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Mirrors `data class CashRegister` (table: cash_register, PK: date).
class CashRegister {
  final String date;
  final double openingCash;
  final double closingCash;
  final double openingBank;
  final double closingBank;
  final bool closed;

  const CashRegister({
    required this.date,
    this.openingCash = 0.0,
    this.closingCash = 0.0,
    this.openingBank = 0.0,
    this.closingBank = 0.0,
    this.closed = false,
  });

  Map<String, Object?> toMap() => {
        'date': date,
        'openingCash': openingCash,
        'closingCash': closingCash,
        'openingBank': openingBank,
        'closingBank': closingBank,
        'closed': closed ? 1 : 0,
      };

  factory CashRegister.fromMap(Map<String, Object?> m) => CashRegister(
        date: m['date'] as String,
        openingCash: (m['openingCash'] as num?)?.toDouble() ?? 0.0,
        closingCash: (m['closingCash'] as num?)?.toDouble() ?? 0.0,
        openingBank: (m['openingBank'] as num?)?.toDouble() ?? 0.0,
        closingBank: (m['closingBank'] as num?)?.toDouble() ?? 0.0,
        closed: (m['closed'] as int?) == 1,
      );
}

/// Mirrors `data class AppSetting` (table: app_settings, PK: key).
class AppSetting {
  final String key;
  final String value;
  const AppSetting(this.key, this.value);
  Map<String, Object?> toMap() => {'key': key, 'value': value};
  factory AppSetting.fromMap(Map<String, Object?> m) =>
      AppSetting(m['key'] as String, m['value'] as String);
}

/// Mirrors `data class SyncQueueEntry` (table: sync_queue, PK: id autoincrement).
/// Same enqueue+trigger pattern used across the Kotlin app's SyncQueueHelper.
class SyncQueueEntry {
  final int? id;
  final String entityType;
  final String entityId;
  final String operation;
  final String payloadJson;
  final int createdAt;
  final int? syncedAt;
  final int retryCount;
  final String? lastError;

  const SyncQueueEntry({
    this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.createdAt,
    this.syncedAt,
    this.retryCount = 0,
    this.lastError,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'entityType': entityType,
        'entityId': entityId,
        'operation': operation,
        'payloadJson': payloadJson,
        'createdAt': createdAt,
        'syncedAt': syncedAt,
        'retryCount': retryCount,
        'lastError': lastError,
      };

  factory SyncQueueEntry.fromMap(Map<String, Object?> m) => SyncQueueEntry(
        id: m['id'] as int?,
        entityType: m['entityType'] as String,
        entityId: m['entityId'] as String,
        operation: m['operation'] as String,
        payloadJson: m['payloadJson'] as String,
        createdAt: (m['createdAt'] as num).toInt(),
        syncedAt: m['syncedAt'] as int?,
        retryCount: (m['retryCount'] as num?)?.toInt() ?? 0,
        lastError: m['lastError'] as String?,
      );
}
