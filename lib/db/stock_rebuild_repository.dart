import '../models/product.dart';
import 'app_database.dart';
import 'stock_taking_repository.dart';

/// Ek martaba ka tool: jin products ki September mein purchase hui unka stock
///   = September ki purchase (smallest unit) - us product ki PEHLI September purchase ke baad ki sales
/// par set karna. Baad mein stock normal sale/purchase se chalta rahe.
///
/// Sirf `active` sale/purchase gine jate hain (returned sale bahar). Natija manfi ho to 0 par rok diya jata hai.
/// Jin products ki September mein purchase nahi, unhe haath nahi lagaya jata.
/// Apply `StockTakingRepository.commit` se hota hai: ledger (STOCK_TAKE) + stock DELTA sync.
class StockRebuildLine {
  final Product product;
  final double purchased; // September purchase, smallest unit
  final double soldAfter; // pehli Sep purchase ke baad ki sales, smallest unit
  final double target; // clamp(purchased - soldAfter, 0)
  final bool clamped;
  const StockRebuildLine(this.product, this.purchased, this.soldAfter, this.target, this.clamped);
}

class StockRebuildPlan {
  final DateTime from;
  final DateTime to;
  final List<StockRebuildLine> lines; // sirf wo jin ka stock badlega
  final int unchanged;
  final int skippedInvalid; // piece-wale item jahan natija fraction aaya
  const StockRebuildPlan(this.from, this.to, this.lines, this.unchanged, this.skippedInvalid);
}

double _smallest(Product p, double qty, String unit, double frozenFactor) {
  if (frozenFactor > 0) return qty * frozenFactor;
  return p.toSmallestUnits(qty, unit);
}

class StockRebuildRepository {
  StockRebuildRepository._();
  static final StockRebuildRepository instance = StockRebuildRepository._();

  static DateTime defaultMonthStart() {
    final now = DateTime.now();
    return DateTime(now.month >= 9 ? now.year : now.year - 1, 9, 1);
  }

  Future<StockRebuildPlan> buildPlan({DateTime? monthStart}) async {
    final from = monthStart ?? defaultMonthStart();
    final to = DateTime(from.year, from.month + 1, 1);
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;

    final products = {
      for (final r in await db.query('products')) (r['barcode'] as String): Product.fromMap(r),
    };

    // September ki purchases: barcode -> (smallest total, pehli purchase ka waqt).
    final purchased = <String, double>{};
    final firstAt = <String, int>{};
    final pRows = await db.rawQuery(
      "SELECT pi.barcode AS barcode, pi.qty AS qty, pi.unit AS unit, pi.conversionFactor AS cf, p.createdAt AS at "
      "FROM purchase_items pi JOIN purchases p ON p.billNo = pi.billNo "
      "WHERE p.status != 'returned' AND p.createdAt >= ? AND p.createdAt < ? AND pi.barcode != ''",
      [fromMs, toMs],
    );
    for (final r in pRows) {
      final bc = r['barcode'] as String;
      final p = products[bc];
      if (p == null) continue;
      final qty = (r['qty'] as num).toDouble();
      final cf = (r['cf'] as num?)?.toDouble() ?? 0.0;
      purchased[bc] = (purchased[bc] ?? 0) + _smallest(p, qty, (r['unit'] as String?) ?? '', cf);
      final at = (r['at'] as num).toInt();
      if (!firstAt.containsKey(bc) || at < firstAt[bc]!) firstAt[bc] = at;
    }

    // Un products ki sales jo pehli September purchase ya us ke baad hui.
    final sold = <String, double>{};
    if (firstAt.isNotEmpty) {
      final sRows = await db.rawQuery(
        "SELECT si.barcode AS barcode, si.qty AS qty, si.unit AS unit, si.conversionFactor AS cf, s.createdAt AS at "
        "FROM sale_items si JOIN sales s ON s.invoice = si.invoice "
        "WHERE s.status != 'returned' AND s.createdAt >= ?",
        [fromMs],
      );
      for (final r in sRows) {
        final bc = r['barcode'] as String;
        final start = firstAt[bc];
        final p = products[bc];
        if (start == null || p == null) continue;
        if ((r['at'] as num).toInt() < start) continue;
        final qty = (r['qty'] as num).toDouble();
        final cf = (r['cf'] as num?)?.toDouble() ?? 0.0;
        sold[bc] = (sold[bc] ?? 0) + _smallest(p, qty, (r['unit'] as String?) ?? '', cf);
      }
    }

    final lines = <StockRebuildLine>[];
    var unchanged = 0;
    var invalid = 0;
    for (final e in purchased.entries) {
      final p = products[e.key]!;
      final raw = e.value - (sold[e.key] ?? 0);
      final clamped = raw < 0;
      final target = ((clamped ? 0.0 : raw) * 1000).roundToDouble() / 1000;
      if (!p.isValidSmallestQty(target)) {
        invalid++;
        continue;
      }
      if ((target - p.stock).abs() <= 0.0001) {
        unchanged++;
        continue;
      }
      lines.add(StockRebuildLine(p, e.value, sold[e.key] ?? 0, target, clamped));
    }
    lines.sort((a, b) => a.product.name.compareTo(b.product.name));
    return StockRebuildPlan(from, to, lines, unchanged, invalid);
  }

  /// Plan ko lagao (Admin/Manager). Session id wapas deta hai.
  Future<String> apply(StockRebuildPlan plan) {
    final variances = [
      for (final l in plan.lines) StockTakeVariance(l.product, l.target, l.target - l.product.stock),
    ];
    return StockTakingRepository.instance.commit(variances, note: 'Stock rebuild from Sep purchases');
  }
}
