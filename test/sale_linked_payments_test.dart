import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/utils/split_payment.dart';

void main() {
  // Kotlin RoomSaleRepository.saveSale(): `linkedToSkip` — bill-linked payments
  // already have their own cash row, so an edited bill must not re-record them.
  group('subtractLinkedPaid', () {
    test('no linked payments -> rows unchanged', () {
      final rows = [const PayEntry('Cash', 300.0), const PayEntry('Bank', 200.0)];
      expect(subtractLinkedPaid(rows, 0.0), rows);
    });

    test('single row: linked amount comes off it', () {
      expect(subtractLinkedPaid([const PayEntry('Cash', 500.0)], 200.0), [const PayEntry('Cash', 300.0)]);
    });

    test('linked amount bigger than first row spills into the next', () {
      final rows = [const PayEntry('Cash', 300.0), const PayEntry('Bank', 200.0)];
      expect(subtractLinkedPaid(rows, 400.0), [const PayEntry('Bank', 100.0)]);
    });

    test('rows fully covered by linked payments are dropped', () {
      expect(subtractLinkedPaid([const PayEntry('Cash', 250.0)], 250.0), isEmpty);
    });

    test('linked amount above total paid just empties the list', () {
      final rows = [const PayEntry('Cash', 100.0), const PayEntry('Bank', 50.0)];
      expect(subtractLinkedPaid(rows, 999.0), isEmpty);
    });

    test('total cash-in + linked == paid (no double counting)', () {
      final rows = [const PayEntry('Cash', 600.0), const PayEntry('Bank', 400.0)];
      const linked = 350.0;
      final cashIn = subtractLinkedPaid(rows, linked).fold<double>(0, (a, r) => a + r.amount);
      expect(cashIn + linked, 1000.0);
    });
  });
}
