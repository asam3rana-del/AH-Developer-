import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'stock_ledger.dart';

/// Ports the data side of StockAuditActivity.kt.
///
/// Idea: har product ka `stock` HAMESHA apni stock_movements ledger ke jod ke barabar hona chahiye.
/// Farq = kisi ne ledger ke bahar se stock badla (sync race, purani unit-ladder edit, direct write).
/// Maths PURE functions mein hai — test/stock_audit_test.dart.

/// Kotlin EPSILON: float/rounding noise se zara upar. "Kaafi qareeb" wali business tolerance nahi.
const double kAuditEpsilon = 0.01;

class AuditRow {
  final Product product;
  final double ledgerStock;

  /// product.stock - ledgerStock (smallest unit). +ve = app ke paas ledger se zyada stock.
  final double diff;
  const AuditRow(this.product, this.ledgerStock, this.diff);
}

/// Kotlin loadAudit(): jin ka |stock - ledger| > epsilon, sab se bara farq pehle.
/// Ledger mein jis product ka koi row nahi uska ledger stock 0.
List<AuditRow> buildAuditRows(List<Product> products, Map<String, double> ledgerSums,
    {double epsilon = kAuditEpsilon}) {
  final rows = <AuditRow>[];
  for (final p in products) {
    final ledger = ledgerSums[p.barcode] ?? 0.0;
    final diff = p.stock - ledger;
    if (diff.abs() > epsilon) rows.add(AuditRow(p, ledger, diff));
  }
  rows.sort((a, b) => b.diff.abs().compareTo(a.diff.abs()));
  return rows;
}

/// Kotlin renderRows filter: query khali = sab, warna matchesQuery (naam + searchTag).
List<AuditRow> filterAuditRows(List<AuditRow> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all.where((r) => r.product.matchesQuery(q)).toList();
}

class AuditResult {
  final List<AuditRow> mismatches;
  final int totalChecked;
  const AuditResult(this.mismatches, this.totalChecked);
}

class StockAuditRepository {
  StockAuditRepository._();
  static final StockAuditRepository instance = StockAuditRepository._();

  void _requireAdminOrManager() {
    if (!Session.isAdminOrManager) {
      throw StateError('Stock Audit sirf Admin/Manager ke liye hai');
    }
  }

  Future<AuditResult> load() async {
    _requireAdminOrManager();
    final db = await AppDatabase.instance.database;
    final products = (await db.query('products', orderBy: 'name COLLATE NOCASE ASC')).map(Product.fromMap).toList();
    final sums = <String, double>{};
    for (final r in await db.rawQuery('SELECT barcode, SUM(qty) AS total FROM stock_movements GROUP BY barcode')) {
      sums[r['barcode'] as String] = ((r['total'] as num?) ?? 0).toDouble();
    }
    return AuditResult(buildAuditRows(products, sums), products.length);
  }

  /// Kotlin recordAuditReconciliation() — Product.stock ko HAATH NAHI lagata (jo abhi bik raha hai wahi
  /// sahi maana jata hai), sirf ledger mein ek AUDIT_RECONCILE row jo farq band kar de.
  /// Sab rows ek hi transaction mein: ya sab fix, ya koi nahi. Kitni fix hui wapas deta hai.
  Future<int> reconcile(List<AuditRow> rows, {required String note}) async {
    _requireAdminOrManager();
    if (rows.isEmpty) return 0;
    final db = await AppDatabase.instance.database;
    var n = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        await StockLedger.logAuditReconciliation(txn, r.product.barcode, r.diff, note: note);
        n++;
      }
    });
    return n;
  }
}
