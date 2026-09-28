/// Mirrors ZakatYear / ZakatPayment / ZakatMonthPlan from Database.kt.

/// One Zakat year (Ramadan-to-Ramadan): asset snapshot + 2.5% payable.
class ZakatYear {
  final int? id;
  final int startDate;
  final int endDate;
  final double assetsSnapshot;
  final double totalPayable;
  final String currency;
  final String calendarType; // 'islamic' | 'gregorian'
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const ZakatYear({
    this.id,
    required this.startDate,
    required this.endDate,
    required this.assetsSnapshot,
    required this.totalPayable,
    this.currency = 'Rs',
    this.calendarType = 'islamic',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  ZakatYear copyWith({
    double? assetsSnapshot,
    double? totalPayable,
    String? currency,
    String? calendarType,
    int? updatedAt,
  }) =>
      ZakatYear(
        id: id,
        startDate: startDate,
        endDate: endDate,
        assetsSnapshot: assetsSnapshot ?? this.assetsSnapshot,
        totalPayable: totalPayable ?? this.totalPayable,
        currency: currency ?? this.currency,
        calendarType: calendarType ?? this.calendarType,
        createdAt: createdAt,
        serverId: serverId,
        updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        dirty: true,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'startDate': startDate,
        'endDate': endDate,
        'assetsSnapshot': assetsSnapshot,
        'totalPayable': totalPayable,
        'currency': currency,
        'calendarType': calendarType,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory ZakatYear.fromMap(Map<String, Object?> m) => ZakatYear(
        id: m['id'] as int?,
        startDate: (m['startDate'] as num).toInt(),
        endDate: (m['endDate'] as num).toInt(),
        assetsSnapshot: (m['assetsSnapshot'] as num).toDouble(),
        totalPayable: (m['totalPayable'] as num).toDouble(),
        currency: (m['currency'] as String?) ?? 'Rs',
        calendarType: (m['calendarType'] as String?) ?? 'islamic',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// A partial or full payment against a [ZakatYear].
class ZakatPayment {
  final int? id;
  final int zakatYearId;
  final double amount;
  final String method; // 'cash' | 'bank'
  final String note;
  final String category; // '' | cash | gold | silver | business | livestock | crops | other
  final int paymentDate;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const ZakatPayment({
    this.id,
    required this.zakatYearId,
    required this.amount,
    required this.method,
    this.note = '',
    this.category = '',
    required this.paymentDate,
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'zakatYearId': zakatYearId,
        'amount': amount,
        'method': method,
        'note': note,
        'category': category,
        'paymentDate': paymentDate,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory ZakatPayment.fromMap(Map<String, Object?> m) => ZakatPayment(
        id: m['id'] as int?,
        zakatYearId: (m['zakatYearId'] as num).toInt(),
        amount: (m['amount'] as num).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        note: (m['note'] as String?) ?? '',
        category: (m['category'] as String?) ?? '',
        paymentDate: (m['paymentDate'] as num).toInt(),
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Customised payable amount + note for month 1..12 of a [ZakatYear].
class ZakatMonthPlan {
  final int? id;
  final int zakatYearId;
  final int monthIndex;
  final double payableAmount;
  final String note;
  final int createdAt;
  final int updatedAt;

  const ZakatMonthPlan({
    this.id,
    required this.zakatYearId,
    required this.monthIndex,
    required this.payableAmount,
    this.note = '',
    required this.createdAt,
    this.updatedAt = 0,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'zakatYearId': zakatYearId,
        'monthIndex': monthIndex,
        'payableAmount': payableAmount,
        'note': note,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'dirty': 1,
      };

  factory ZakatMonthPlan.fromMap(Map<String, Object?> m) => ZakatMonthPlan(
        id: m['id'] as int?,
        zakatYearId: (m['zakatYearId'] as num).toInt(),
        monthIndex: (m['monthIndex'] as num).toInt(),
        payableAmount: (m['payableAmount'] as num).toDouble(),
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );
}
