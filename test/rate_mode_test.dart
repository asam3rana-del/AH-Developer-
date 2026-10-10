import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/utils/rate_mode.dart';

void main() {
  const rice = Product(barcode: '1', name: 'Rice', salePrice: 120, wholesalePrice: 110, shopkeeperPrice: 104);
  const noShop = Product(barcode: '2', name: 'Sugar', salePrice: 150, wholesalePrice: 140);

  test('basePriceFor picks the rate for each mode', () {
    expect(basePriceFor(rice, RateMode.retail), 120);
    expect(basePriceFor(rice, RateMode.wholesale), 110);
    expect(basePriceFor(rice, RateMode.shopkeeper), 104);
  });

  test('shopkeeper rate falls back to wholesale when not set', () {
    expect(basePriceFor(noShop, RateMode.shopkeeper), 140);
  });

  test('rateModeFromString / rateModeName', () {
    expect(rateModeFromString('shopkeeper'), RateMode.shopkeeper);
    expect(rateModeFromString('Wholesale'), RateMode.wholesale);
    expect(rateModeFromString(''), RateMode.retail);
    expect(rateModeName(RateMode.shopkeeper), 'shopkeeper');
  });

  test('Product and Customer keep the new fields through toMap/fromMap', () {
    expect(Product.fromMap(rice.toMap()).shopkeeperPrice, 104);
    final c = const Customer(name: 'Ali', rateType: 'shopkeeper');
    expect(Customer.fromMap(c.toMap()..['id'] = 1).rateType, 'shopkeeper');
    expect(Customer.fromMap({'id': 2, 'name': 'Old'}).rateType, '');
  });
}
