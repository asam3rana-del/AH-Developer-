/// Split Payment helpers — port of the pure parts of SaleUseCases.kt's
/// SaveSaleUseCase (cleanPayments / effectivePaidInput / method label).
///
/// One bill can be paid across several methods, e.g. Rs 300 Cash + Rs 200
/// Bank. The (method, amount) rows are the source of truth whenever a split
/// is active; the single "Paid Amount" box and the Cash/Bank picker are then
/// ignored.
library;

class PayEntry {
  final String method; // 'Cash' | 'Bank'
  final double amount;
  const PayEntry(this.method, this.amount);

  @override
  bool operator ==(Object other) =>
      other is PayEntry && other.method == method && other.amount == amount;

  @override
  int get hashCode => Object.hash(method, amount);

  @override
  String toString() => '$method Rs ${amount.toStringAsFixed(0)}';
}

/// Rows with a real amount only (Kotlin: `filter { it.second > 0.009 }`).
List<PayEntry> cleanPayments(List<PayEntry> payments) =>
    payments.where((p) => p.amount > 0.009).toList();

/// The split rows' sum is the real paid amount whenever a split is in play;
/// [paidInput] is trusted only when there is no split.
double effectivePaidInput(List<PayEntry> payments, double paidInput) {
  final clean = cleanPayments(payments);
  if (clean.isEmpty) return paidInput;
  return clean.fold<double>(0.0, (sum, p) => sum + p.amount);
}

/// Label stored in `sales.paymentMethod`.
///  - nothing paid            -> 'credit'
///  - 2+ rows                 -> distinct methods joined, entry order kept
///                               ("Cash + Bank"; Cash twice stays "Cash")
///  - 1 row                   -> that row's method
///  - no split rows           -> [singleMethod] (the picker's value)
String paymentMethodLabel({
  required double paid,
  required List<PayEntry> payments,
  required String singleMethod,
}) {
  if (paid <= 0.009) return 'credit';
  final clean = cleanPayments(payments);
  if (clean.length >= 2) {
    final seen = <String>[];
    for (final p in clean) {
      if (!seen.contains(p.method)) seen.add(p.method);
    }
    return seen.join(' + ');
  }
  if (clean.length == 1) return clean.first.method;
  return singleMethod;
}

/// "Cash Rs 300  +  Bank Rs 200" (summary line under the Paid box).
String splitBreakdown(List<PayEntry> payments) =>
    payments.map((p) => '${p.method} Rs ${p.amount.toStringAsFixed(0)}').join('  +  ');

/// Amount text for a field: "300" not "300.0".
String plainAmount(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

/// Same customer / same total / same calendar day as a bill already saved —
/// SaleActivity.checkDuplicateAndProceedSale's match rule (no time window;
/// [candidateDate]/[targetDate] are compared by calendar day only).
bool isDuplicateSale({
  required String candidateCustomer,
  required double candidateTotal,
  required DateTime candidateDate,
  required String wantedCustomer, // '' means walk-in
  required double wantedTotal,
  required DateTime wantedDate,
}) {
  String norm(String c) => (c.trim().isEmpty ? 'walk-in' : c.trim()).toLowerCase();
  final sameDay = candidateDate.year == wantedDate.year &&
      candidateDate.month == wantedDate.month &&
      candidateDate.day == wantedDate.day;
  return sameDay &&
      norm(candidateCustomer) == norm(wantedCustomer) &&
      (candidateTotal - wantedTotal).abs() < 0.005;
}
