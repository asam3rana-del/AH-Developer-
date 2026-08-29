/// Mirrors `data class Customer` (table: customers, PK: id autoincrement).
class Customer {
  final int? id;
  final String name;
  final String phone;
  final double creditLimit;
  final double openingBalance;
  final double balance;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const Customer({
    this.id,
    required this.name,
    this.phone = '',
    this.creditLimit = 0.0,
    this.openingBalance = 0.0,
    this.balance = 0.0,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'creditLimit': creditLimit,
        'openingBalance': openingBalance,
        'balance': balance,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory Customer.fromMap(Map<String, Object?> m) => Customer(
        id: m['id'] as int?,
        name: m['name'] as String,
        phone: (m['phone'] as String?) ?? '',
        creditLimit: (m['creditLimit'] as num?)?.toDouble() ?? 0.0,
        openingBalance: (m['openingBalance'] as num?)?.toDouble() ?? 0.0,
        balance: (m['balance'] as num?)?.toDouble() ?? 0.0,
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Mirrors `data class Supplier` (table: suppliers, PK: id autoincrement).
class Supplier {
  final int? id;
  final String name;
  final String phone;
  final double openingBalance;
  final double balance;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const Supplier({
    this.id,
    required this.name,
    this.phone = '',
    this.openingBalance = 0.0,
    this.balance = 0.0,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'openingBalance': openingBalance,
        'balance': balance,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory Supplier.fromMap(Map<String, Object?> m) => Supplier(
        id: m['id'] as int?,
        name: m['name'] as String,
        phone: (m['phone'] as String?) ?? '',
        openingBalance: (m['openingBalance'] as num?)?.toDouble() ?? 0.0,
        balance: (m['balance'] as num?)?.toDouble() ?? 0.0,
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}
