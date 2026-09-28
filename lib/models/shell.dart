/// Mirrors ShellCustomer / ShellTransaction / ShopEmptyShellLog from Database.kt.

class ShellCustomer {
  final int? id;
  final String name;
  final String phone;
  final int shellsOwed;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const ShellCustomer({
    this.id,
    required this.name,
    this.phone = '',
    this.shellsOwed = 0,
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'shellsOwed': shellsOwed,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory ShellCustomer.fromMap(Map<String, Object?> m) => ShellCustomer(
        id: m['id'] as int?,
        name: m['name'] as String,
        phone: (m['phone'] as String?) ?? '',
        shellsOwed: (m['shellsOwed'] as num?)?.toInt() ?? 0,
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// type: 'ISSUE' (filled given, shell owed) or 'RETURN' (empty shell handed back).
class ShellTransaction {
  final int? id;
  final int customerId;
  final String type;
  final int qty;
  final String note;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const ShellTransaction({
    this.id,
    required this.customerId,
    required this.type,
    required this.qty,
    this.note = '',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  bool get isIssue => type == 'ISSUE';

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'customerId': customerId,
        'type': type,
        'qty': qty,
        'note': note,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory ShellTransaction.fromMap(Map<String, Object?> m) => ShellTransaction(
        id: m['id'] as int?,
        customerId: (m['customerId'] as num).toInt(),
        type: m['type'] as String,
        qty: (m['qty'] as num).toInt(),
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Signed delta log of the shop's OWN empty shells.
/// reason: MANUAL_ADD, MANUAL_REMOVE, CUSTOMER_RETURN, SENT_FOR_REFILL.
class ShopEmptyShellLog {
  final int? id;
  final int delta;
  final String reason;
  final String note;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const ShopEmptyShellLog({
    this.id,
    required this.delta,
    required this.reason,
    this.note = '',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'delta': delta,
        'reason': reason,
        'note': note,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory ShopEmptyShellLog.fromMap(Map<String, Object?> m) => ShopEmptyShellLog(
        id: m['id'] as int?,
        delta: (m['delta'] as num).toInt(),
        reason: m['reason'] as String,
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}
