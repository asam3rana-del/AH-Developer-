import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/rate_comparison_repository.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

void main() {
  test('groups by supplier, last = newest purchase, sorted cheapest last-rate first', () {
    final rows = buildSupplierRateRows(const [
      RateEntry(1, 'Ali Traders', 250, 100),
      RateEntry(1, 'Ali Traders', 240, 300), // newest for Ali
      RateEntry(1, 'Ali Traders', 260, 200),
      RateEntry(2, 'Bilal & Co', 235, 150),
    ]);
    expect(rows.map((r) => r.supplierName), ['Bilal & Co', 'Ali Traders']); // 235 < 240
    final ali = rows.last;
    expect(ali.lastRate, 240);
    expect(ali.lastDate, 300);
    expect(ali.minRate, 240);
    expect(ali.maxRate, 260);
    expect(ali.timesPurchased, 3);
  });

  test('empty history gives no rows', () {
    expect(buildSupplierRateRows(const []), isEmpty);
  });

  test('rates in different units normalize to the primary unit before comparing', () {
    const p = Product(barcode: 'b2', name: 'Biscuit', unit: 'Carton', secondaryUnit: 'Pcs', secondaryUnitQty: 24);
    // Rs 10 per Pcs == Rs 240 per Carton; Rs 245 per Carton is dearer.
    expect(p.toPrimaryUnitRate(10, 'Pcs'), 240);
    expect(p.toPrimaryUnitRate(245, 'Carton'), 245);
    final rows = buildSupplierRateRows([
      RateEntry(1, 'A', p.toPrimaryUnitRate(10, 'Pcs'), 1),
      RateEntry(2, 'B', p.toPrimaryUnitRate(245, 'Carton'), 1),
    ]);
    expect(rows.first.supplierName, 'A');
  });
}
