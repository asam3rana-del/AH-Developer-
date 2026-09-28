import '../db/sale_repository.dart' show SaleLine;
import '../models/product.dart';
import '../models/sale.dart';

/// Dart port of StockTouchPolicy.saleEditDiff() (StockTouchPolicy.kt).
///
/// When a saved sale is edited, ONLY the lines the cashier actually changed
/// (or added) may touch stock. A line left exactly as it was is skipped on
/// both sides — no reverse, no re-deduct — otherwise its stock drifts a
/// little on every edit whenever the unit ladder changed since the sale.
///
/// Lines are matched as a multiset on `barcode|qty|unit|rate` (6 decimals),
/// index-based so two identical lines on one bill are handled correctly.
class SaleEditDiff {
  /// Original bill rows that no longer appear as-is — only THESE give their
  /// stock back.
  final List<SaleItem> itemsToReverse;

  /// Indices (into the edited `lines`) of new/modified lines — only THESE are
  /// stock-checked and deducted again.
  final Set<int> changedLineIndices;

  /// For every line left completely alone, the original row it matches — so
  /// its frozen `conversionFactor` can be carried over.
  final Map<int, SaleItem> unchangedOriginalByIndex;

  const SaleEditDiff(this.itemsToReverse, this.changedLineIndices, this.unchangedOriginalByIndex);
}

String _key(String barcode, double qty, String unit, double rate) =>
    '$barcode|${qty.toStringAsFixed(6)}|$unit|${rate.toStringAsFixed(6)}';

SaleEditDiff saleEditDiff(List<SaleLine> lines, List<SaleItem> originalItems) {
  final remaining = List<SaleItem>.of(originalItems);
  final changed = <int>{};
  final unchanged = <int, SaleItem>{};
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final k = _key(l.barcode, l.qty, l.unit, l.unitPrice);
    final at = remaining.indexWhere((o) => _key(o.barcode, o.qty, o.unit, o.unitPrice) == k);
    if (at >= 0) {
      unchanged[i] = remaining.removeAt(at);
    } else {
      changed.add(i);
    }
  }
  return SaleEditDiff(remaining, changed, unchanged);
}

/// How many smallest units a STORED sale row represents. Uses the factor
/// frozen at sale time; only falls back to the product's CURRENT ladder for
/// old rows that never captured one (factor == 0). Mirrors
/// `SaleItem.smallestQty(product)` in Database.kt.
double saleItemSmallestQty(SaleItem item, Product? product) {
  if (item.conversionFactor > 0) return item.qty * item.conversionFactor;
  if (product == null) return item.qty;
  return product.toSmallestUnits(item.qty, item.unit.isEmpty ? product.unit : item.unit);
}
