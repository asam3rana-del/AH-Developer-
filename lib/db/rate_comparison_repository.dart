import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';

/// Ek purchase line ka normalized rate (product ke PRIMARY unit par).
class RateEntry {
  final int supplierId;
  final String supplierName;
  final double rate;
  final int date;
  const RateEntry(this.supplierId, this.supplierName, this.rate, this.date);
}

/// RateComparisonActivity.SupplierRateRow.
class SupplierRateRow {
  final int supplierId;
  final String supplierName;
  final double lastRate;
  final int lastDate;
  final double minRate;
  final double maxRate;
  final int timesPurchased;
  const SupplierRateRow({
    required this.supplierId,
    required this.supplierName,
    required this.lastRate,
    required this.lastDate,
    required this.minRate,
    required this.maxRate,
    required this.timesPurchased,
  });
}

/// Pure function (Kotlin `loadComparison` ka grouping hissa): supplier ke hisaab se
/// group, last = sab se naye purchase ka rate, phir lastRate ke hisaab se sasta pehle.
List<SupplierRateRow> buildSupplierRateRows(List<RateEntry> entries) {
  final bySupplier = <int, List<RateEntry>>{};
  for (final e in entries) {
    bySupplier.putIfAbsent(e.supplierId, () => []).add(e);
  }
  final rows = <SupplierRateRow>[];
  bySupplier.forEach((id, list) {
    var mostRecent = list.first;
    var lo = list.first.rate;
    var hi = list.first.rate;
    for (final e in list) {
      if (e.date > mostRecent.date) mostRecent = e; // Kotlin maxByOrNull: barabar par pehli
      if (e.rate < lo) lo = e.rate;
      if (e.rate > hi) hi = e.rate;
    }
    rows.add(SupplierRateRow(
      supplierId: id,
      supplierName: mostRecent.supplierName,
      lastRate: mostRecent.rate,
      lastDate: mostRecent.date,
      minRate: lo,
      maxRate: hi,
      timesPurchased: list.length,
    ));
  });
  rows.sort((a, b) => a.lastRate.compareTo(b.lastRate));
  return rows;
}

/// Kotlin RateComparisonActivity ka data hissa. Purchase-side data hai, is liye
/// sirf admin/manager (cashier ke liye query hi nahi chalti).
class RateComparisonRepository {
  RateComparisonRepository._();
  static final RateComparisonRepository instance = RateComparisonRepository._();

  Future<List<SupplierRateRow>> compare(Product product) async {
    if (!Session.isAdminOrManager) return const [];
    final db = await AppDatabase.instance.database;
    // Kotlin purchasesBySupplier() jaisa: sirf supplier wali purchases (Cash Purchase
    // ki supplierId NULL hoti hai), status filter nahi (Kotlin bhi nahi lagata).
    final rows = await db.rawQuery('''
      SELECT s.id AS supplierId, s.name AS supplierName, pi.unit AS unit,
             pi.unitCost AS unitCost, p.createdAt AS createdAt
      FROM purchase_items pi
      JOIN purchases p ON pi.billNo = p.billNo
      JOIN suppliers s ON s.id = p.supplierId
      WHERE pi.barcode = ?
    ''', [product.barcode]);

    final entries = rows.map((m) {
      final unit = ((m['unit'] as String?) ?? '').trim();
      final unitForRate = unit.isEmpty ? product.unit : unit;
      final normalized = product.toPrimaryUnitRate((m['unitCost'] as num).toDouble(), unitForRate);
      return RateEntry(
        (m['supplierId'] as num).toInt(),
        m['supplierName'] as String,
        normalized,
        (m['createdAt'] as num).toInt(),
      );
    }).toList();
    return buildSupplierRateRows(entries);
  }
}
