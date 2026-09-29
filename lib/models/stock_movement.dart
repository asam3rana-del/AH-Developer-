/// Dart port of `data class StockMovement` (Database.kt, table `stock_movements`).
///
/// Append-only ledger: har stock badalne wali cheez (sale, purchase, return, edit, delete,
/// opening stock) ek row likhti hai. `qty` SIGNED hai (sale negative, purchase positive) aur
/// PRODUCT ki SMALLEST unit mein. `cost` us waqt ka product.cost (primary unit ka rate,
/// Product.cost jaisa) — isi ek table se Stock History aur Cost History dono chalti hain.
class StockMovement {
  final int? id;
  final String barcode;
  final String type;
  final double qty;
  final String unit;
  final double cost;
  final String reference;
  final String note;
  final int createdAt;
  final String? serverId;
  final int updatedAt;
  final bool dirty;

  const StockMovement({
    this.id,
    required this.barcode,
    required this.type,
    required this.qty,
    this.unit = '',
    this.cost = 0.0,
    this.reference = '',
    this.note = '',
    required this.createdAt,
    this.serverId,
    this.updatedAt = 0,
    this.dirty = true,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'barcode': barcode,
        'type': type,
        'qty': qty,
        'unit': unit,
        'cost': cost,
        'reference': reference,
        'note': note,
        'createdAt': createdAt,
        'serverId': serverId,
        'updatedAt': updatedAt,
        'dirty': dirty ? 1 : 0,
      };

  factory StockMovement.fromMap(Map<String, Object?> m) => StockMovement(
        id: m['id'] as int?,
        barcode: m['barcode'] as String,
        type: m['type'] as String,
        qty: (m['qty'] as num).toDouble(),
        unit: (m['unit'] as String?) ?? '',
        cost: ((m['cost'] as num?) ?? 0).toDouble(),
        reference: (m['reference'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num).toInt(),
        serverId: m['serverId'] as String?,
        updatedAt: ((m['updatedAt'] as num?) ?? 0).toInt(),
        dirty: ((m['dirty'] as num?) ?? 1) != 0,
      );
}

/// `type` ki qismein — Kotlin StockMovementActivity.typeLabel() / SyncQueueHelper call sites jaisi.
class MovementType {
  MovementType._();
  static const purchase = 'PURCHASE';
  static const purchaseEdit = 'PURCHASE_EDIT';
  static const purchaseReversal = 'PURCHASE_REVERSAL';
  static const purchaseItemDelete = 'PURCHASE_ITEM_DELETE';
  static const purchaseReturn = 'PURCHASE_RETURN';
  static const sale = 'SALE';
  static const saleEdit = 'SALE_EDIT';
  static const saleEditReversal = 'SALE_EDIT_REVERSAL';
  static const saleReversal = 'SALE_REVERSAL';
  static const saleItemDelete = 'SALE_ITEM_DELETE';
  static const openingStock = 'OPENING_STOCK';
  static const damage = 'DAMAGE';
  static const adjustment = 'ADJUSTMENT';
  static const stockTake = 'STOCK_TAKE';
  static const auditReconcile = 'AUDIT_RECONCILE';

  /// Cost History sirf wo types jo Product.cost hila sakti hain (sale kabhi cost nahi badalti).
  /// Kotlin StockMovementDao.costHistoryForProduct().
  static const costAffecting = <String>[
    purchase,
    purchaseEdit,
    purchaseReversal,
    purchaseItemDelete,
    openingStock,
  ];
}
