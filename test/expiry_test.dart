import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/expiry.dart';

void main() {
  final now = DateTime(2026, 11, 12, 20, 0);

  test('Parses stored and hand-written formats', () {
    expect(parseExpiry('2027-01-15'), DateTime(2027, 1, 15));
    expect(parseExpiry('15/01/2027'), DateTime(2027, 1, 15));
    expect(parseExpiry('5-1-2027'), DateTime(2027, 1, 5));
    expect(parseExpiry('02/2027'), DateTime(2027, 2, 28)); // mahine ka aakhri din
    expect(parseExpiry(''), isNull);
    expect(parseExpiry('kal'), isNull);
    expect(parseExpiry('2027-02-31'), isNull); // ghalat tareekh
  });

  test('Storage format round-trips', () {
    final d = DateTime(2027, 3, 4);
    expect(formatExpiryForStorage(d), '2027-03-04');
    expect(parseExpiry(formatExpiryForStorage(d)), d);
  });

  test('Days left and status', () {
    expect(daysUntilExpiry(DateTime(2026, 11, 12), now: now), 0);
    expect(daysUntilExpiry(DateTime(2026, 11, 11), now: now), -1);
    expect(expiryStatusOf(-1), ExpiryStatus.expired);
    expect(expiryStatusOf(0), ExpiryStatus.soon);
    expect(expiryStatusOf(expiryWarnDays), ExpiryStatus.soon);
    expect(expiryStatusOf(expiryWarnDays + 1), ExpiryStatus.ok);
  });

  test('List: only stocked items that are expired / expiring, soonest first', () {
    final list = buildExpiryList([
      const Product(barcode: 'a', name: 'Doodh', stock: 5, expiry: '2026-11-20'),
      const Product(barcode: 'b', name: 'Ghee', stock: 2, expiry: '2026-11-01'),
      const Product(barcode: 'c', name: 'Chawal', stock: 9, expiry: '2027-06-01'), // door hai
      const Product(barcode: 'd', name: 'Biscuit', stock: 0, expiry: '2026-11-01'), // stock nahi
      const Product(barcode: 'e', name: 'Sabun', stock: 3), // expiry nahi
    ], now: now);
    expect(list.map((r) => r.product.name).toList(), ['Ghee', 'Doodh']);
    expect(list.first.status, ExpiryStatus.expired);
    expect(list.last.status, ExpiryStatus.soon);
  });
}
