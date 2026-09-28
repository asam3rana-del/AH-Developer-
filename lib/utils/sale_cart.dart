import '../db/sale_repository.dart' show SaleLine;
import '../models/product.dart';

/// Dart port of the pure (non-UI) helpers in SaleCart.kt.
///
/// IMPORTANT — unit order: Sale/Quick Sale show a product's units in the
/// Kotlin order (primary first): `[unit, secondaryUnit, tertiaryUnit]`.
/// `Product.defaultUnitIndex` / `quickSaleDefaultUnitIndex` index INTO THAT
/// LIST. This is NOT the same order as `Product.unitLadder()` (smallest
/// first), so never use `unitLadder()[index]` for these indices.

/// Category whose 2-tier products default to the primary unit (SaleActivity
/// .BEVERAGE_CATEGORY in Kotlin).
const String kBeverageCategory = 'Beverages';

/// Units a product can be sold in, in Sale-screen order (primary first).
/// Mirrors `onItemPicked()` / `qsUnitsFor()` in Kotlin.
List<String> saleUnitChoices(Product p) {
  final choices = <String>[p.unit];
  if (p.secondaryUnit.isNotEmpty) {
    choices.add(p.secondaryUnit);
    if (p.tertiaryUnit.isNotEmpty && p.tertiaryUnitQty > 0) {
      choices.add(p.tertiaryUnit);
    }
  }
  return choices;
}

/// 1, 2 or 3 — how many units [saleUnitChoices] returns.
int saleTierCount(Product p) => saleUnitChoices(p).length;

/// Automatic pick (no manual override). Mirrors `autoDefaultUnitIndexFor()`.
///  * 1-tier  -> 0 (only unit)
///  * 3-tier  -> 1 (secondary)
///  * 2-tier  -> 0 for Beverages, otherwise 1
int autoDefaultUnitIndexFor(Product p) {
  final hasSecondary = p.secondaryUnit.isNotEmpty;
  final hasTertiary = hasSecondary && p.tertiaryUnit.isNotEmpty && p.tertiaryUnitQty > 0;

  if (!hasSecondary) return 0;
  if (hasTertiary) return 1;

  final isBeverage = p.category.toLowerCase() == kBeverageCategory.toLowerCase();
  return isBeverage ? 0 : 1;
}

/// Default unit index for the normal Sale screen: the shopkeeper's manual
/// choice wins when it is still valid for the product's current tier count,
/// otherwise Auto. Mirrors `defaultUnitIndexFor()`.
int defaultUnitIndexFor(Product p) {
  final tierCount = saleTierCount(p);
  if (p.defaultUnitIndex >= 0 && p.defaultUnitIndex < tierCount) {
    return p.defaultUnitIndex;
  }
  return autoDefaultUnitIndexFor(p);
}

/// Same as [defaultUnitIndexFor] but reads the Quick Sale-specific override.
/// Mirrors `quickSaleDefaultUnitIndexFor()`.
int quickSaleDefaultUnitIndexFor(Product p) {
  final tierCount = saleTierCount(p);
  if (p.quickSaleDefaultUnitIndex >= 0 && p.quickSaleDefaultUnitIndex < tierCount) {
    return p.quickSaleDefaultUnitIndex;
  }
  return autoDefaultUnitIndexFor(p);
}

/// Default unit NAME for a product (Sale screen).
String defaultUnitFor(Product p) => saleUnitChoices(p)[defaultUnitIndexFor(p)];

/// Default unit NAME for a product (Quick Sale dialog).
String quickSaleDefaultUnitFor(Product p) => saleUnitChoices(p)[quickSaleDefaultUnitIndexFor(p)];

/// Result of [repriceLinesForSaleType].
class RepriceResult {
  final List<SaleLine> lines;
  final bool changed;
  const RepriceResult(this.lines, this.changed);
}

/// Retail <-> Wholesale switch: re-rate every line already in the cart against
/// ITS OWN product's retail/wholesale rate, converted to the line's own unit.
/// A line's `cost` is untouched. Lines whose product has no rate configured
/// for the target type (<= 0) or can't be found keep their current price.
/// Mirrors `repriceLinesForSaleType()`.
RepriceResult repriceLinesForSaleType(
  List<SaleLine> lines,
  List<Product> products, {
  required bool isWholesale,
}) {
  if (lines.isEmpty) return RepriceResult(lines, false);
  var changed = false;
  final out = <SaleLine>[];
  for (final line in lines) {
    Product? product;
    for (final p in products) {
      if (p.barcode == line.barcode) {
        product = p;
        break;
      }
    }
    product ??= () {
      for (final p in products) {
        if (p.name.toLowerCase() == line.itemName.toLowerCase()) return p;
      }
      return null;
    }();
    if (product == null) {
      out.add(line);
      continue;
    }
    final basePrice = isWholesale ? product.wholesalePrice : product.salePrice;
    if (basePrice <= 0.0) {
      out.add(line);
      continue;
    }
    final newPrice = product.fromPrimaryUnitRate(basePrice, line.unit);
    if (newPrice == line.unitPrice) {
      out.add(line);
      continue;
    }
    out.add(line.copyWith(unitPrice: newPrice, amount: line.qty * newPrice));
    changed = true;
  }
  return RepriceResult(out, changed);
}

enum MarginLevel { none, loss, low, ok }

class MarginInfo {
  final MarginLevel level;
  final double margin;
  final double marginPct;
  final double costInUnit;
  const MarginInfo(this.level, this.margin, this.marginPct, this.costInUnit);
  static const none = MarginInfo(MarginLevel.none, 0, 0, 0);
}

/// Loss-protection check shown right where the rate is typed. Mirrors
/// `updateMarginWarning()`: no cost or no typed price -> nothing to show;
/// margin <= 0 -> loss; margin < 10% -> low; otherwise ok.
MarginInfo marginFor(Product? product, double typedPrice, String unit) {
  final cost = product?.cost ?? 0.0;
  if (product == null || cost <= 0.0 || typedPrice <= 0.0) return MarginInfo.none;
  final costInUnit = product.fromPrimaryUnitRate(cost, unit);
  final margin = typedPrice - costInUnit;
  final pct = costInUnit > 0 ? (margin / costInUnit) * 100.0 : 0.0;
  final level = margin <= 0
      ? MarginLevel.loss
      : (pct < 10.0 ? MarginLevel.low : MarginLevel.ok);
  return MarginInfo(level, margin, pct, costInUnit);
}

/// Stock of [p] expressed in [unit] (Quick Sale's "Available: x unit").
double availableInUnit(Product p, String unit) {
  final perUnit = p.toSmallestUnits(1.0, unit);
  return perUnit > 0 ? p.stock / perUnit : p.stock;
}

/// "12" instead of "12.0" (Kotlin `formatQty`).
String formatQty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

// ---------------------------------------------------------------- Rs mode

/// Buy-by-amount ("Rs" mode): the shopkeeper types a rupee amount and the
/// quantity is derived from the rate, rounded to 3 decimals. Returns null when
/// either number is missing. Mirrors `addItem()` / `updateItemLineTotal()`.
double? qtyFromAmount(double amount, double price) {
  if (amount <= 0 || price <= 0) return null;
  return (amount / price * 1000).roundToDouble() / 1000.0;
}

// ----------------------------------------------------- Customer's own rate

/// A customer's remembered rate for one item, converted for the unit that is
/// currently chosen.
class CustomerRateSuggestion {
  /// Rate per the product's PRIMARY unit (goes into `lastMainPrice`).
  final double primaryRate;

  /// Same rate expressed in the chosen unit (goes into the price box).
  final double priceInChosenUnit;
  const CustomerRateSuggestion(this.primaryRate, this.priceInChosenUnit);
}

/// Converts the last rate charged to a customer (`lastUnitPrice` per
/// `lastUnit`) into the chosen unit. Null when the result is not positive.
/// Mirrors the maths in `suggestCustomerRate()`.
CustomerRateSuggestion? customerRateFor(
  Product p, {
  required double lastUnitPrice,
  required String lastUnit,
  required String chosenUnit,
}) {
  final primary = p.toPrimaryUnitRate(lastUnitPrice, lastUnit.isEmpty ? p.unit : lastUnit);
  final inChosen = p.fromPrimaryUnitRate(primary, chosenUnit);
  if (inChosen <= 0) return null;
  return CustomerRateSuggestion(primary, inChosen);
}
