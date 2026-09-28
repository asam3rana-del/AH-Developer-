/// Mirrors `data class Sale` (table: sales, PK: invoice).
class Sale {
  final String invoice;
  final int? customerId;
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final double paid;
  final String paymentMethod;
  final String saleType;
  final int createdAt;
  final String status;
  final int updatedAt;
  final bool dirty;

  const Sale({
    required this.invoice,
    this.customerId,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.total,
    required this.paid,
    required this.paymentMethod,
    this.saleType = 'retail',
    required this.createdAt,
    this.status = 'active',
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        'invoice': invoice,
        'customerId': customerId,
        'subtotal': subtotal,
        'discount': discount,
        'tax': tax,
        'total': total,
        'paid': paid,
        'paymentMethod': paymentMethod,
        'saleType': saleType,
        'createdAt': createdAt,
        'status': status,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory Sale.fromMap(Map<String, Object?> m) => Sale(
        invoice: m['invoice'] as String,
        customerId: m['customerId'] as int?,
        subtotal: (m['subtotal'] as num).toDouble(),
        discount: (m['discount'] as num).toDouble(),
        tax: (m['tax'] as num).toDouble(),
        total: (m['total'] as num).toDouble(),
        paid: (m['paid'] as num).toDouble(),
        paymentMethod: m['paymentMethod'] as String,
        saleType: (m['saleType'] as String?) ?? 'retail',
        createdAt: (m['createdAt'] as num).toInt(),
        status: (m['status'] as String?) ?? 'active',
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        dirty: (m['dirty'] as int?) == 1,
      );
}

/// Mirrors `data class SaleItem` (table: sale_items, PK: id autoincrement).
/// qty is a double (fractional-qty support), matching the Kotlin migration.
class SaleItem {
  final int? id;
  final String invoice;
  final String barcode;
  final String product;
  final double qty;
  final String unit;
  final double unitPrice;
  final double cost;
  final double amount;

  const SaleItem({
    this.id,
    required this.invoice,
    required this.barcode,
    required this.product,
    required this.qty,
    this.unit = '',
    required this.unitPrice,
    required this.cost,
    required this.amount,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'invoice': invoice,
        'barcode': barcode,
        'product': product,
        'qty': qty,
        'unit': unit,
        'unitPrice': unitPrice,
        'cost': cost,
        'amount': amount,
      };

  factory SaleItem.fromMap(Map<String, Object?> m) => SaleItem(
        id: m['id'] as int?,
        invoice: m['invoice'] as String,
        barcode: m['barcode'] as String,
        product: m['product'] as String,
        qty: (m['qty'] as num).toDouble(),
        unit: (m['unit'] as String?) ?? '',
        unitPrice: (m['unitPrice'] as num).toDouble(),
        cost: (m['cost'] as num).toDouble(),
        amount: (m['amount'] as num).toDouble(),
      );
}
