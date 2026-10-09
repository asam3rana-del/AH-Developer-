import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/utils/stock_policy.dart';

void main() {
  test('shortWarning shows the minus stock after the sale', () {
    final w = StockPolicy.shortWarning('Sugar', 2, 5, 'kg');
    expect(w.contains('Sugar'), true);
    expect(w.contains('-3'), true);
  });

  test('short stock is allowed by default', () {
    expect(StockPolicy.allowShortStock, true);
  });
}
