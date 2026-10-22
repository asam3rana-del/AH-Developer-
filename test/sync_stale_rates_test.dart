import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/sync/sync_push_plan.dart';

int day(int d, [int h = 10]) => DateTime(2026, 10, d, h).millisecondsSinceEpoch;

void main() {
  Map<String, Object?> payload(int ratesAt, double sale) => {
        'name': 'Hard supari',
        'unit': 'kg',
        'salePrice': sale,
        'wholesalePrice': sale * 0.96,
        'shopkeeperPrice': 0,
        'ratesAt': ratesAt,
      };

  test('purani rate wala device cloud ki nayi rate overwrite nahi karta', () {
    final out = withoutStaleRates(payload(day(10), 3400), {'ratesAt': day(22, 13)});
    expect(out.containsKey('salePrice'), isFalse);
    expect(out.containsKey('wholesalePrice'), isFalse);
    expect(out.containsKey('shopkeeperPrice'), isFalse);
    expect(out.containsKey('ratesAt'), isFalse);
    expect(out['name'], 'Hard supari');
    expect(out['unit'], 'kg');
  });

  test('nayi ya barabar rate chali jati hai', () {
    final p = payload(day(22, 13), 4100);
    expect(withoutStaleRates(p, {'ratesAt': day(22, 9)}), p);
    expect(withoutStaleRates(p, {'ratesAt': day(10)}), p);
  });

  test('same din ka farq rate nahi rokta (din ke hisab se compare)', () {
    final p = payload(day(22, 8), 4100);
    expect(withoutStaleRates(p, {'ratesAt': day(22, 15)}), p);
  });

  test('purane doc / payload mein ratesAt na ho to kuch nahi badalta', () {
    final p = payload(day(10), 3400);
    expect(withoutStaleRates(p, null), p);
    expect(withoutStaleRates(p, {'name': 'x'}), p);
    expect(withoutStaleRates(p, {'ratesAt': 0}), p);
    final noRates = {'name': 'a', 'salePrice': 1.0};
    expect(withoutStaleRates(noRates, {'ratesAt': day(22)}), noRates);
  });
}
