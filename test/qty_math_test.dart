import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/utils/qty_math.dart';

void main() {
  test('float noise: 0.1 + 0.2 stock se 0.3 nikalna allowed hai', () {
    final stock = 0.1 + 0.2; // 0.30000000000000004
    expect(stock >= 0.3, isTrue);
    expect(0.3 >= stock, isFalse); // plain compare ghalat "kam" batata hai
    expect(hasEnoughStock(0.3, stock), isTrue);
    expect(hasEnoughStock(stock, 0.3), isTrue);
  });

  test('asli kami pakri jati hai', () {
    expect(hasEnoughStock(1.0, 1.001), isFalse);
    expect(hasEnoughStock(0, 1), isFalse);
    expect(hasEnoughStock(5, 5), isTrue);
  });

  test('roundQty noise saaf karta hai magar 3-decimal qty nahi todta', () {
    expect(roundQty(0.1 + 0.2), 0.3);
    expect(roundQty(10 - 9.7), 0.3);
    expect(roundQty(2.125), 2.125);
    expect(roundQty(-0.0000001), 0.0);
  });
}
