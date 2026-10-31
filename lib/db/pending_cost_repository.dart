import '../models/product.dart';
import '../services/permissions.dart';
import '../services/session.dart';
import '../sync/sync_worker.dart';
import 'app_database.dart';
import 'cost_backfill.dart';
import 'stock_report_repository.dart' show costPerSmallestUnit;

/// Admin tool: "cost pending" sale lines (minus stock / product cost 0 par bechi gayi, asal cost purchase se
/// abhi nahi bhari) ko product ki MAUJUDA cost se bharna. Purchase aane par ye khud hota hai
/// ([CostBackfill.apply]); ye un lines ke liye hai jin ki product cost baad mein haath se likhi gayi.

class PendingCostLine {
  final int itemId;
  final String invoice;
  final int createdAt;
  final String party;
  final String productName;
  final String smallestUnit;
  final double pendingQty; // smallest units
  final double pendingEst; // jo andaza abhi cost mein shamil hai
  final double ratePerSmallest; // product ki maujooda cost / smallest unit (0 = abhi cost nahi likhi)
  const PendingCostLine({
    required this.itemId,
    required this.invoice,
    required this.createdAt,
    required this.party,
    required this.productName,
    required this.smallestUnit,
    required this.pendingQty,
    required this.pendingEst,
    required this.ratePerSmallest,
  });

  /// Product ki cost likhi ho to bhar sakte hain.
  bool get fillable => ratePerSmallest > 0;

  double get newPendingCost => pendingQty * ratePerSmallest;

  /// Naya - purana andaza: positive => cost barhegi (profit kam), negative => profit behtar.
  double get costChange => newPendingCost - pendingEst;
}

/// Maths (pure): total cost change un lines ka jo [lines] mein fillable hain.
double totalCostChange(Iterable<PendingCostLine> lines) =>
    lines.where((l) => l.fillable).fold<double>(0.0, (a, l) => a + l.costChange);

class PendingCostException implements Exception {
  final String message;
  const PendingCostException(this.message);
  @override
  String toString() => message;
}

class PendingCostRepository {
  PendingCostRepository._();
  static final PendingCostRepository instance = PendingCostRepository._();

  void _requireAdmin() {
    if (!Permissions.can('fix_bill_cost')) throw const PendingCostException('Sirf Admin ye action kar sakta hai');
  }

  /// Sab pending lines (purani pehle). Fillable wali pehle, "product cost 0" wali baad mein.
  Future<List<PendingCostLine>> listPending() async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    final products = {
      for (final r in await db.query('products')) (r['barcode'] as String): Product.fromMap(r),
    };
    final rows = await db.rawQuery(
      'SELECT si.id AS id, si.invoice AS invoice, si.barcode AS barcode, si.product AS product, '
      'si.pendingQty AS pendingQty, si.pendingEst AS pendingEst, s.createdAt AS at, c.name AS party '
      'FROM sale_items si JOIN sales s ON s.invoice = si.invoice '
      'LEFT JOIN customers c ON c.id = s.customerId '
      "WHERE si.pendingQty > ? AND s.status = 'active' ORDER BY s.createdAt ASC, si.id ASC",
      [kPendingEpsilon],
    );
    final out = <PendingCostLine>[];
    for (final r in rows) {
      final p = products[r['barcode'] as String];
      out.add(PendingCostLine(
        itemId: (r['id'] as num).toInt(),
        invoice: r['invoice'] as String,
        createdAt: (r['at'] as num).toInt(),
        party: ((r['party'] as String?) ?? '').trim().isEmpty ? 'Walk-in' : (r['party'] as String).trim(),
        productName: (r['product'] as String?) ?? '',
        smallestUnit: p?.smallestUnitName() ?? '',
        pendingQty: (r['pendingQty'] as num).toDouble(),
        pendingEst: (r['pendingEst'] as num?)?.toDouble() ?? 0.0,
        ratePerSmallest: p == null ? 0.0 : costPerSmallestUnit(p),
      ));
    }
    out.sort((a, b) => (a.fillable == b.fillable) ? 0 : (a.fillable ? -1 : 1));
    return out;
  }

  /// Chuni lines product ki cost se bharo, bills sync queue mein. Kitni lines badli wapas deta hai.
  Future<int> apply(Set<int> itemIds) async {
    _requireAdmin();
    if (itemIds.isEmpty) throw const PendingCostException('Koi line nahi chuni');
    final db = await AppDatabase.instance.database;
    final n = await db.transaction((txn) => CostBackfill.fillFromProductCost(txn, ids: itemIds));
    try {
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': 'pending_cost_fill',
        'reference': 'lines=$n',
        'details': 'product cost se pending lines bhari gayin',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Audit kabhi save nahi rokta.
    }
    if (n > 0) {
      try {
        await SyncWorker.instance.triggerNow();
      } catch (_) {}
    }
    return n;
  }
}
