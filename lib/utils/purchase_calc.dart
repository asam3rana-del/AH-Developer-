/// Purchase screen ki pure (bina UI / DB) calculations — test/purchase_screen_test.dart mein test hoti hain.

enum MarginLevel { none, loss, low, ok }

/// Kotlin `updateMarginWarning()` ("10/10 Purchase screen" item #15).
class PurchaseMargin {
  final MarginLevel level;

  /// sale rate - purchase rate (dono product ki main / primary unit basis par).
  final double margin;
  final double marginPct;
  final double salePrice;

  const PurchaseMargin(this.level, this.margin, this.marginPct, this.salePrice);

  static const none = PurchaseMargin(MarginLevel.none, 0, 0, 0);
}

/// Aaj ka purchase rate product ke MAUJUDA sale rate ka munafa khata hai ya ulta kar deta hai:
///  * sale rate ya purchase rate 0  -> koi warning nahi
///  * margin <= 0                   -> loss (surkh)
///  * margin < 10% of sale rate     -> low (peela)
///  * warna                         -> ok (hara, sirf info)
PurchaseMargin purchaseMargin({required double salePriceMain, required double purchaseRateMain}) {
  if (salePriceMain <= 0 || purchaseRateMain <= 0) return PurchaseMargin.none;
  final margin = salePriceMain - purchaseRateMain;
  final pct = (margin / salePriceMain) * 100.0;
  final level = margin <= 0
      ? MarginLevel.loss
      : pct < 10.0
          ? MarginLevel.low
          : MarginLevel.ok;
  return PurchaseMargin(level, margin, pct, salePriceMain);
}

/// Bill ka total poore rupee par: .50 ya us se zyada => upar (106.50 -> 107), .50 se kam => neeche (106.49 -> 106).
double roundBillTotal(double subtotal) => subtotal.roundToDouble();

/// Rate/qty text field ke liye: "12" nahi "12.00" (2 decimals), 0 = khali.
String rateText(double v) => v <= 0 ? '' : v.toStringAsFixed(2);

/// Qty text: "3" not "3.0".
String qtyText(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
