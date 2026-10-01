import 'package:flutter_test/flutter_test.dart';
import 'package:ah_developer_kiryana_store/utils/bill_text.dart';

void main() {
  test('sale bill text shows Prev/Net balance only when netBalance given', () {
    String build({double? net}) => buildSaleBillText(
          shopName: 'Shop',
          invoice: 'INV1',
          date: DateTime(2026, 9, 26),
          customer: 'Ali',
          lines: const [],
          subtotal: 4160,
          discount: 0,
          total: 4160,
          paid: 260,
          netBalance: net,
        );
    expect(build(), isNot(contains('Prev Balance')));
    // Prev = net - due: bill ke waqt 0 tha, due 3900 => Net 3900.
    final t = build(net: 3900);
    expect(t, contains('Prev Balance'));
    expect(RegExp(r'Prev Balance\s+0\.00').hasMatch(t), isTrue);
    expect(RegExp(r'Net Balance\s+3900\.00').hasMatch(t), isTrue);
  });
}
