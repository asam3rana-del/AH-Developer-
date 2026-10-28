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

  /// Default payment muddat (din). 0 = set nahi. Sale mein udhaar bill par due date = bill date + dueDays.
  final int dueDays;

  /// Party ki qism: '' (normal customer) | 'amanat' (customer ne paisa amanat rakhwaya) | 'loan'
  /// (dukan ne cash udhar diya). Sirf label / reminders ke liye — balance ka hisaab pehle jaisa hi hai.
  final String kind;

  /// Amanat wapas karne / udhar wapas aane ki tarikh (din ki shuruaat, millis). 0 = set nahi.
  final int returnDate;

  /// Amanat / Loan ki alag alag entries (JSON text, dekhein models/return_entry.dart). '' = koi nahi.
  final String returnEntries;

  /// Amanat / Loan ki history (given / recovered / adjusted rows, JSON text, dekhein models/return_entry.dart).
  /// Sirf party ledger / statement mein dikhane ke liye; balance isse nahi badalta. '' = koi nahi.
  final String returnLog;
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
    this.dueDays = 0,
    this.kind = '',
    this.returnDate = 0,
    this.returnEntries = '',
    this.returnLog = '',
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  bool get isAmanat => kind == 'amanat';
  bool get isLoan => kind == 'loan';

  /// Return date set hai aur party amanat/loan hai => reminder mein aayegi.
  bool get hasReturnReminder => (isAmanat || isLoan) && returnDate > 0;

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
    int? dueDays,
    String? kind,
    int? returnDate,
    String? returnEntries,
    String? returnLog,
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
        dueDays: dueDays ?? this.dueDays,
        kind: kind ?? this.kind,
        returnDate: returnDate ?? this.returnDate,
        returnEntries: returnEntries ?? this.returnEntries,
        returnLog: returnLog ?? this.returnLog,
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
        'dueDays': dueDays,
        'kind': kind,
        'returnDate': returnDate,
        // Khali ho to key hi nahi: purane schema / edit par DB ki maujooda entries na mitein.
        if (returnEntries.isNotEmpty) 'returnEntries': returnEntries,
        if (returnLog.isNotEmpty) 'returnLog': returnLog,
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
        dueDays: (m['dueDays'] as num?)?.toInt() ?? 0,
        kind: (m['kind'] as String?) ?? '',
        returnDate: (m['returnDate'] as num?)?.toInt() ?? 0,
        returnEntries: (m['returnEntries'] as String?) ?? '',
        returnLog: (m['returnLog'] as String?) ?? '',
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
