import '../db/purchase_history_repository.dart' show PurchaseHistoryRow;

/// Ek mahine ki purchases (Purchase History → "Delete a month").
class PurchaseMonth {
  final int year;
  final int month;
  final List<PurchaseHistoryRow> rows;
  const PurchaseMonth(this.year, this.month, this.rows);

  int get count => rows.length;
  double get total => rows.fold(0.0, (a, r) => a + r.total);
  String get key => '$year-${month.toString().padLeft(2, '0')}';
}

/// Bills ko mahine ke hisaab se (local waqt), naya mahina pehle. PURE — test/purchase_month_test.dart.
List<PurchaseMonth> groupPurchasesByMonth(Iterable<PurchaseHistoryRow> rows) {
  final map = <String, List<PurchaseHistoryRow>>{};
  final ym = <String, (int, int)>{};
  for (final r in rows) {
    final d = DateTime.fromMillisecondsSinceEpoch(r.createdAt);
    final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
    (map[k] ??= []).add(r);
    ym[k] = (d.year, d.month);
  }
  final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final k in keys) PurchaseMonth(ym[k]!.$1, ym[k]!.$2, map[k]!)];
}
