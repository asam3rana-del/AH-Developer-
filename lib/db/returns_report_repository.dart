import 'app_database.dart';
import 'reports_repository.dart' show ReportRange;

/// Returns Report: `returns` table ki har line (sale ya purchase) date-range ke hisaab se, party / item ke naam ke saath.
/// Partial aur poori dono returns isi table mein aati hain (poori return mein har line ka ek row).
class ReturnReportRow {
  final int id;
  final String reference; // invoice / billNo
  final String type; // 'sale' | 'purchase'
  final String partyName;
  final String itemName;
  final String unit;
  final double qty;
  final double amount;
  final int createdAt;

  const ReturnReportRow({
    required this.id,
    required this.reference,
    required this.type,
    required this.partyName,
    required this.itemName,
    required this.unit,
    required this.qty,
    required this.amount,
    required this.createdAt,
  });
}

double returnsTotal(List<ReturnReportRow> rows) => rows.fold(0.0, (a, r) => a + r.amount);

class ReturnsReportRepository {
  ReturnsReportRepository._();
  static final ReturnsReportRepository instance = ReturnsReportRepository._();

  /// [type] = 'sale' | 'purchase'. Naya pehle.
  Future<List<ReturnReportRow>> load(String type, ReportRange range) async {
    final db = await AppDatabase.instance.database;
    final isSale = type == 'sale';
    final rows = await db.rawQuery('''
      SELECT r.id AS id, r.reference AS reference, r.qty AS qty, r.amount AS amount, r.createdAt AS createdAt,
             COALESCE((SELECT name FROM products WHERE barcode = r.barcode), r.barcode) AS itemName,
             ${isSale ? "COALESCE((SELECT c.name FROM sales s JOIN customers c ON c.id = s.customerId WHERE s.invoice = r.reference), 'Walk-in')" : "COALESCE((SELECT sp.name FROM purchases p JOIN suppliers sp ON sp.id = p.supplierId WHERE p.billNo = r.reference), 'Cash Purchase')"} AS partyName,
             COALESCE((SELECT ${isSale ? 'unit FROM sale_items WHERE invoice' : 'unit FROM purchase_items WHERE billNo'} = r.reference AND barcode = r.barcode LIMIT 1), '') AS unit
      FROM returns r
      WHERE r.type = ? AND r.createdAt BETWEEN ? AND ?
      ORDER BY r.createdAt DESC, r.id DESC
    ''', [type, range.start, range.end]);
    return [
      for (final r in rows)
        ReturnReportRow(
          id: (r['id'] as num).toInt(),
          reference: (r['reference'] as String?) ?? '',
          type: type,
          partyName: (r['partyName'] as String?) ?? '',
          itemName: (r['itemName'] as String?) ?? '',
          unit: (r['unit'] as String?) ?? '',
          qty: (r['qty'] as num?)?.toDouble() ?? 0.0,
          amount: (r['amount'] as num?)?.toDouble() ?? 0.0,
          createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
        ),
    ];
  }
}
