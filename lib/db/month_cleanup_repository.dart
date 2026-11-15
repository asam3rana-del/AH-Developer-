import 'app_database.dart';
import '../services/session.dart';
import 'purchase_history_repository.dart';
import 'sale_repository.dart';

/// Ek mahine (misal August) ke saare Sale aur Purchase bills delete karne ka tool (sirf Admin).
///
/// Har bill ke liye wahi function chalta hai jo History screen ka "Delete" chalata hai
/// (`deleteSale` / `deletePurchase`), is liye har bill ka stock, party balance, cash/payment rows
/// reverse hote hain aur cloud par delete sync hota hai (doosre devices se bhi hat jata hai).
/// Pehle sales (stock wapas), phir purchases (stock/cost wapas) delete hoti hain.
/// Purchase delete `force: true` se chalti hai: agar us purchase ka maal baad mein bik chuka ho to
/// stock 0 se neeche nahi jata (Stock Audit se baad mein check kar len).
class MonthCleanupPreview {
  final int saleCount, purchaseCount;
  final double saleTotal, purchaseTotal;
  final List<String> saleIds, purchaseIds;
  const MonthCleanupPreview(
      {required this.saleCount,
      required this.purchaseCount,
      required this.saleTotal,
      required this.purchaseTotal,
      required this.saleIds,
      required this.purchaseIds});
}

class MonthCleanupResult {
  final int salesDeleted, purchasesDeleted;
  final List<String> failures;
  const MonthCleanupResult(this.salesDeleted, this.purchasesDeleted, this.failures);
}

class MonthCleanupRepository {
  MonthCleanupRepository._();
  static final MonthCleanupRepository instance = MonthCleanupRepository._();

  static (int, int) _range(int year, int month) {
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1, 1).millisecondsSinceEpoch;
    return (start, end);
  }

  Future<MonthCleanupPreview> preview(int year, int month) async {
    final db = await AppDatabase.instance.database;
    final (s, e) = _range(year, month);
    final sales = await db.query('sales',
        columns: ['invoice', 'total'], where: 'createdAt >= ? AND createdAt < ?', whereArgs: [s, e], orderBy: 'createdAt DESC');
    final purchases = await db.query('purchases',
        columns: ['billNo', 'total'], where: 'createdAt >= ? AND createdAt < ?', whereArgs: [s, e], orderBy: 'createdAt DESC');
    double sum(List<Map<String, Object?>> r) => r.fold(0.0, (a, m) => a + ((m['total'] as num?)?.toDouble() ?? 0));
    return MonthCleanupPreview(
      saleCount: sales.length,
      purchaseCount: purchases.length,
      saleTotal: sum(sales),
      purchaseTotal: sum(purchases),
      saleIds: sales.map((m) => m['invoice'] as String).toList(),
      purchaseIds: purchases.map((m) => m['billNo'] as String).toList(),
    );
  }

  Future<MonthCleanupResult> run(int year, int month) async {
    if (!Session.isAdmin) throw StateError('Sirf Admin ye action kar sakta hai');
    final p = await preview(year, month);
    var sd = 0, pd = 0;
    final failures = <String>[];
    for (final id in p.saleIds) {
      try {
        await SaleRepository.instance.deleteSale(id);
        sd++;
      } catch (e) {
        failures.add('Sale $id: $e');
      }
    }
    for (final id in p.purchaseIds) {
      try {
        await PurchaseHistoryRepository.instance.deletePurchase(id, force: true);
        pd++;
      } catch (e) {
        failures.add('Purchase $id: $e');
      }
    }
    return MonthCleanupResult(sd, pd, failures);
  }
}
