/// Mirrors `data class Customer` (table: customers, PK: id autoincrement).
class Customer {
  final int? id;
  final String name;
  final String phone;
  final double creditLimit;
  final double openingBalance;

  /// STORED running balance (sync ke liye). Screens par dikhane ke liye
  /// `PartyRepository.liveCustomerBalances()` istemal karein — ye field drift kar sakta hai.
  final double balance;

  /// Kotlin "Stuck Balance": purana ruka hua amount jo daily sale ke saath nahi hilta.
  /// Sirf admin/manager set kar sakte hain (data layer bhi check karta hai). 0 = koi nahi.
  final double stuckBalance;

  /// Is customer ka rate-type: '' (bill ke sale type ke mutabiq) | 'retail' | 'wholesale' | 'shopkeeper'.
  final String rateType;
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
    this.stuckBalance = 0.0,
    this.rateType = '',
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  /// Kotlin `Customer.totalPayable()` — STORED balance ke saath. Screens live balance se
  /// `partyClosing(...)` (party_repository.dart) istemal karein.
  double get totalPayable => openingBalance + balance + stuckBalance;
  bool get hasStuck => stuckBalance != 0.0;

  Customer copyWith({
    String? name,
    String? phone,
    double? creditLimit,
    double? openingBalance,
    double? balance,
    double? stuckBalance,
    String? rateType,
    int? updatedAt,
    bool? dirty,
  }) =>
      Customer(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        creditLimit: creditLimit ?? this.creditLimit,
        openingBalance: openingBalance ?? this.openingBalance,
        balance: balance ?? this.balance,
        stuckBalance: stuckBalance ?? this.stuckBalance,
        rateType: rateType ?? this.rateType,
        serverId: serverId,
        updatedAt: updatedAt ?? this.updatedAt,
        dirty: dirty ?? this.dirty,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'phone': phone,
        'creditLimit': creditLimit,
        'openingBalance': openingBalance,
        'balance': balance,
        'stuckBalance': stuckBalance,
        'rateType': rateType,
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
        stuckBalance: (m['stuckBalance'] as num?)?.toDouble() ?? 0.0,
        rateType: (m['rateType'] as String?) ?? '',
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

  /// STORED running balance — screens live balance istemal karein (see [Customer.balance]).
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

  Supplier copyWith({
    String? name,
    String? phone,
    double? openingBalance,
    double? balance,
    int? updatedAt,
    bool? dirty,
  }) =>
      Supplier(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        openingBalance: openingBalance ?? this.openingBalance,
        balance: balance ?? this.balance,
        serverId: serverId,
        updatedAt: updatedAt ?? this.updatedAt,
        dirty: dirty ?? this.dirty,
      );

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
