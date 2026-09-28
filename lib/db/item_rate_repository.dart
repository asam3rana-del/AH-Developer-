import '../services/session.dart';
import 'app_database.dart';

/// ItemSaleRecord / ItemPurchaseRecord (Database.kt) ke read models.
class ItemSaleRecord {
  final String customerName;
  final double qty;
  final String unit;
  final double unitPrice;
  final int createdAt;
  const ItemSaleRecord(this.customerName, this.qty, this.unit, this.unitPrice, this.createdAt);
}

class ItemPurchaseRecord {
  final String supplierName;
  final double qty;
  final String unit;
  final double unitCost;
  final int createdAt;
  const ItemPurchaseRecord(this.supplierName, this.qty, this.unit, this.unitCost, this.createdAt);
}

/// saleRecordsForItem / purchaseRecordsForItem (SaleDao / PurchaseDao).
class ItemRateRepository {
  ItemRateRepository._();
  static final ItemRateRepository instance = ItemRateRepository._();

  /// Sab roles ke liye. Newest first.
  Future<List<ItemSaleRecord>> saleRecordsForItem(String barcode) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE((SELECT name FROM customers WHERE customers.id = s.customerId), 'Walk-in') AS customerName,
             si.qty AS qty, si.unit AS unit, si.unitPrice AS unitPrice, s.createdAt AS createdAt
      FROM sale_items si JOIN sales s ON si.invoice = s.invoice
      WHERE si.barcode = ?
      ORDER BY s.createdAt DESC
    ''', [barcode]);
    return rows
        .map((m) => ItemSaleRecord(
              m['customerName'] as String,
              (m['qty'] as num).toDouble(),
              (m['unit'] as String?) ?? '',
              (m['unitPrice'] as num).toDouble(),
              (m['createdAt'] as num).toInt(),
            ))
        .toList();
  }

  /// Cost data: cashier ke liye query hi nahi chalti (data layer par role check),
  /// sirf UI hide karna kaafi nahi. Newest first.
  Future<List<ItemPurchaseRecord>> purchaseRecordsForItem(String barcode) async {
    if (!Session.isAdminOrManager) return const [];
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE((SELECT name FROM suppliers WHERE suppliers.id = p.supplierId), 'Cash Purchase') AS supplierName,
             pi.qty AS qty, pi.unit AS unit, pi.unitCost AS unitCost, p.createdAt AS createdAt
      FROM purchase_items pi JOIN purchases p ON pi.billNo = p.billNo
      WHERE pi.barcode = ?
      ORDER BY p.createdAt DESC
    ''', [barcode]);
    return rows
        .map((m) => ItemPurchaseRecord(
              m['supplierName'] as String,
              (m['qty'] as num).toDouble(),
              (m['unit'] as String?) ?? '',
              (m['unitCost'] as num).toDouble(),
              (m['createdAt'] as num).toInt(),
            ))
        .toList();
  }
}
