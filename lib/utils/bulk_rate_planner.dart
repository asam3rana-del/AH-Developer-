import '../models/product.dart';
import 'rate_margin.dart';

/// Kis rate ka bulk lagana hai: retail ya wholesale (dono ke fields alag hain).
enum BulkRateTarget { retail, wholesale }

/// Bulk rate kaise nikalna hai: asal rate se % kam, ya Rs kam.
enum BulkRateRule { percentOff, amountOff }

/// Ek product ki tabdeeli ka preview (rate PRIMARY unit par, minQty main unit mein — product screen jaisa).
class BulkRateRow {
  final Product product;
  final double baseRate;
  final double oldBulkPrice;
  final double oldMinQty;
  final double newBulkPrice;
  final double newMinQty;
  const BulkRateRow({
    required this.product,
    required this.baseRate,
    required this.oldBulkPrice,
    required this.oldMinQty,
    required this.newBulkPrice,
    required this.newMinQty,
  });
}

class BulkRatePlan {
  final List<BulkRateRow> rows;

  /// Asal (retail/wholesale) rate 0 hai — us se bulk nikal nahi sakta.
  final int skippedNoBase;

  /// Naya bulk rate 0 ya asal rate se zyada/barabar nikla.
  final int skippedInvalid;

  /// "Sirf wo jin ka bulk set nahi" on tha aur is ka pehle se set hai.
  final int skippedAlreadySet;
  const BulkRatePlan(this.rows, {this.skippedNoBase = 0, this.skippedInvalid = 0, this.skippedAlreadySet = 0});
}

double baseRateFor(Product p, BulkRateTarget t) => t == BulkRateTarget.retail ? p.salePrice : p.wholesalePrice;
double bulkPriceOf(Product p, BulkRateTarget t) => t == BulkRateTarget.retail ? p.bulkPrice : p.wholesaleBulkPrice;
double bulkMinQtyOf(Product p, BulkRateTarget t) => t == BulkRateTarget.retail ? p.bulkMinQty : p.wholesaleBulkMinQty;

bool _inScope(Product p, String? category) => category == null || p.category.trim() == category.trim();

/// Bulk rate nikalna: naya = asal - (value% ya value Rs). [roundToRupee] par nazdeek ke poore rupay tak.
double computeBulkRate(double base, BulkRateRule rule, double value, {bool roundToRupee = true}) {
  final raw = rule == BulkRateRule.percentOff ? base * (1 - value / 100.0) : base - value;
  final r = roundToRupee ? raw.roundToDouble() : (raw * 100).round() / 100.0;
  return r;
}

/// Sab (ya ek category ki) products par bulk rate lagane ka plan. Kuch badalta nahi — sirf preview banata hai.
BulkRatePlan planBulkRates({
  required List<Product> products,
  required BulkRateTarget target,
  required double minQty,
  required BulkRateRule rule,
  required double value,
  String? category,
  bool onlyUnset = true,
  bool roundToRupee = true,
}) {
  if (minQty <= 0 || value <= 0 || (rule == BulkRateRule.percentOff && value >= 100)) {
    return const BulkRatePlan([]);
  }
  final rows = <BulkRateRow>[];
  var noBase = 0, invalid = 0, already = 0;
  for (final p in products) {
    if (!_inScope(p, category)) continue;
    final base = baseRateFor(p, target);
    if (base <= 0) {
      noBase++;
      continue;
    }
    if (onlyUnset && bulkPriceOf(p, target) > 0 && bulkMinQtyOf(p, target) > 0) {
      already++;
      continue;
    }
    final nb = computeBulkRate(base, rule, value, roundToRupee: roundToRupee);
    if (nb <= 0 || nb >= base) {
      invalid++;
      continue;
    }
    rows.add(BulkRateRow(
      product: p,
      baseRate: base,
      oldBulkPrice: bulkPriceOf(p, target),
      oldMinQty: bulkMinQtyOf(p, target),
      newBulkPrice: nb,
      newMinQty: minQty,
    ));
  }
  return BulkRatePlan(rows, skippedNoBase: noBase, skippedInvalid: invalid, skippedAlreadySet: already);
}

/// Bulk rate HATANE ka plan: jin products ka bulk set hai unka bulk 0 (newBulkPrice = 0, newMinQty = 0).
BulkRatePlan planClearBulkRates({
  required List<Product> products,
  required BulkRateTarget target,
  String? category,
}) {
  final rows = <BulkRateRow>[];
  for (final p in products) {
    if (!_inScope(p, category)) continue;
    final bp = bulkPriceOf(p, target), bq = bulkMinQtyOf(p, target);
    if (bp <= 0 && bq <= 0) continue;
    rows.add(BulkRateRow(
        product: p,
        baseRate: baseRateFor(p, target),
        oldBulkPrice: bp,
        oldMinQty: bq,
        newBulkPrice: 0,
        newMinQty: 0));
  }
  return BulkRatePlan(rows);
}

/// Shopkeeper rate ka ek product ka preview (sab rate PRIMARY unit par).
class ShopkeeperRateRow {
  final Product product;

  /// Wholesale rate (jis se kaat kar shopkeeper rate nikla).
  final double baseRate;
  final double oldRate;
  final double newRate;

  /// Naya rate cost se kam hai (sirf warning, rukta nahi).
  final bool belowCost;
  const ShopkeeperRateRow({
    required this.product,
    required this.baseRate,
    required this.oldRate,
    required this.newRate,
    required this.belowCost,
  });
}

class ShopkeeperRatePlan {
  final List<ShopkeeperRateRow> rows;

  /// Wholesale rate 0 hai — us se shopkeeper rate nikal nahi sakta.
  final int skippedNoBase;

  /// Naya rate 0 ya wholesale se zyada/barabar nikla.
  final int skippedInvalid;

  /// "Sirf wo jin ka shopkeeper rate set nahi" on tha aur pehle se set hai.
  final int skippedAlreadySet;
  const ShopkeeperRatePlan(this.rows, {this.skippedNoBase = 0, this.skippedInvalid = 0, this.skippedAlreadySet = 0});

  int get belowCostCount => rows.where((r) => r.belowCost).length;
}

/// Sab (ya ek category ki) products ka Shopkeeper rate = Wholesale rate - (value% ya value Rs).
/// Kuch badalta nahi — sirf preview banata hai.
ShopkeeperRatePlan planShopkeeperRates({
  required List<Product> products,
  required BulkRateRule rule,
  required double value,
  String? category,
  bool onlyUnset = true,
  bool roundToRupee = true,
}) {
  if (value <= 0 || (rule == BulkRateRule.percentOff && value >= 100)) {
    return const ShopkeeperRatePlan([]);
  }
  final rows = <ShopkeeperRateRow>[];
  var noBase = 0, invalid = 0, already = 0;
  for (final p in products) {
    if (!_inScope(p, category)) continue;
    final base = p.wholesalePrice;
    if (base <= 0) {
      noBase++;
      continue;
    }
    if (onlyUnset && p.shopkeeperPrice > 0) {
      already++;
      continue;
    }
    final nr = computeBulkRate(base, rule, value, roundToRupee: roundToRupee);
    if (nr <= 0 || nr >= base) {
      invalid++;
      continue;
    }
    rows.add(ShopkeeperRateRow(
      product: p,
      baseRate: base,
      oldRate: p.shopkeeperPrice,
      newRate: nr,
      belowCost: isBelowCost(nr, p.cost),
    ));
  }
  return ShopkeeperRatePlan(rows, skippedNoBase: noBase, skippedInvalid: invalid, skippedAlreadySet: already);
}
