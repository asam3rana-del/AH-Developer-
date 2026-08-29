class BillTotals {
  final double subtotal;
  final double discount;
  final double total;
  final double paid;
  final double due;

  const BillTotals({
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    required this.due,
  });
}

/// Dart port of `object DiscountCalculator` — the single source of truth for
/// how discount/paid/due are clamped, shared by the Sale screen (and later
/// its edit flow) exactly as in the Kotlin app.
class DiscountCalculator {
  DiscountCalculator._();

  static BillTotals compute(double subtotal, double discountInput, double paidInput) {
    final safeSubtotal = subtotal < 0 ? 0.0 : subtotal;
    final discount = discountInput.clamp(0.0, safeSubtotal);
    final total = (safeSubtotal - discount) < 0 ? 0.0 : (safeSubtotal - discount);
    final paid = paidInput.clamp(0.0, total);
    final due = (total - paid) < 0 ? 0.0 : (total - paid);
    return BillTotals(subtotal: safeSubtotal, discount: discount, total: total, paid: paid, due: due);
  }
}
