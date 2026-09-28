import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';

void main() {
  const p = Product(barcode: '1', name: 'آلو بخارا', searchTag: 'Aloo Bukhara');

  test('matchesQuery: har lafz name+searchTag mein, koi bhi tarteeb', () {
    expect(p.matchesQuery(''), isTrue);
    expect(p.matchesQuery('aloo'), isTrue);
    expect(p.matchesQuery('bukhara aloo'), isTrue);
    expect(p.matchesQuery('ALOO buk'), isTrue);
    expect(p.matchesQuery('aloo mango'), isFalse);
  });

  test('searchTag map round-trip', () {
    final back = Product.fromMap(p.toMap());
    expect(back.searchTag, 'Aloo Bukhara');
  });
}
