/// Mirrors `data class Purchase` (table: purchases, PK: billNo).
class Purchase {
  final String billNo;
  final int? supplierId;
  final double total;
  final double paid;
  final int createdAt;
  final double subtotal;
  final double discount;
  final String status;
  final int updatedAt;
  final bool dirty;

  /// Supplier ko payment ki date (millis). 0 = set nahi (Kotlin Purchase.dueDate, DB v10).
  final int dueDate;

  /// Supplier ka apna invoice / bill number (Kotlin Purchase.supplierInvoiceNo, DB v12). '' = nahi likha.
  final String supplierInvoiceNo;

  const Purchase({
    required this.billNo,
    this.supplierId,
    required this.total,
    required this.paid,
    required this.createdAt,
    this.subtotal = 0.0,
    this.discount = 0.0,
    this.status = 'active',
    this.updatedAt = 0,
    this.dirty = true,
    this.dueDate = 0,
    this.supplierInvoiceNo = '',
  });

  Map<String, Object?> toMap() => {
        'billNo': billNo,
        'supplierId': supplierId,
        'total': total,
        'paid': paid,
        'createdAt': createdAt,
        'subtotal': subtotal,
        'discount': discount,
        'status': status,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
        'dueDate': dueDate,
        'supplierInvoiceNo': supplierInvoiceNo,
      };

  factory Purchase.fromMap(Map<String, Object?> m) => Purchase(
        billNo: m['billNo'] as String,
        supplierId: m['supplierId'] as int?,
        total: (m['total'] as num).toDouble(),
        paid: (m['paid'] as num).toDouble(),
        createdAt: (m['createdAt'] as num).toInt(),
        subtotal: (m['subtotal'] as num?)?.toDouble() ?? 0.0,
        discount: (m['discount'] as num?)?.toDouble() ?? 0.0,
        status: (m['status'] as String?) ?? 'active',
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
        dueDate: (m['dueDate'] as num?)?.toInt() ?? 0,
        supplierInvoiceNo: (m['supplierInvoiceNo'] as String?) ?? '',
      );
}

/// Mirrors `data class PurchaseItem` (table: purchase_items, PK: id autoincrement).
class PurchaseItem {
  final int? id;
  final String billNo;
  final String barcode;
  final double qty;
  final double unitCost;
  final double amount;
  final String unit;

  /// Khareed ke waqt ka "smallest units per 1 [unit]" (DB v12). Baad mein product ki unit ladder badal bhi
  /// jaye to edit / return / delete wahi qty nikalte hain. 0 = purani row (maujuda ladder istemal hogi).
  final double conversionFactor;

  /// Khareed ke waqt ka item naam (snapshot). '' = purani row (live product naam).
  final String itemName;

  /// Purchase ke waqt set kiye gaye Retail / Wholesale rate (0 = product ka rate nahi badla).
  final double retailRate;
  final double wholesaleRate;

  const PurchaseItem({
    this.id,
    required this.billNo,
    required this.barcode,
    required this.qty,
    required this.unitCost,
    required this.amount,
    this.unit = '',
    this.conversionFactor = 0.0,
    this.itemName = '',
    this.retailRate = 0.0,
    this.wholesaleRate = 0.0,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'billNo': billNo,
        'barcode': barcode,
        'qty': qty,
        'unitCost': unitCost,
        'amount': amount,
        'unit': unit,
        'conversionFactor': conversionFactor,
        'itemName': itemName,
        'retailRate': retailRate,
        'wholesaleRate': wholesaleRate,
      };

  factory PurchaseItem.fromMap(Map<String, Object?> m) => PurchaseItem(
        id: m['id'] as int?,
        billNo: m['billNo'] as String,
        barcode: m['barcode'] as String,
        qty: (m['qty'] as num).toDouble(),
        unitCost: (m['unitCost'] as num).toDouble(),
        amount: (m['amount'] as num).toDouble(),
        unit: (m['unit'] as String?) ?? '',
        conversionFactor: (m['conversionFactor'] as num?)?.toDouble() ?? 0.0,
        itemName: (m['itemName'] as String?) ?? '',
        retailRate: (m['retailRate'] as num?)?.toDouble() ?? 0.0,
        wholesaleRate: (m['wholesaleRate'] as num?)?.toDouble() ?? 0.0,
      );
}
