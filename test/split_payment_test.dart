import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/utils/split_payment.dart';

void main() {
  group('cleanPayments / effectivePaidInput', () {
    test('drops zero/near-zero rows', () {
      final rows = [const PayEntry('Cash', 0.0), const PayEntry('Bank', 200.0), const PayEntry('Cash', 0.005)];
      expect(cleanPayments(rows), [const PayEntry('Bank', 200.0)]);
    });

    test('empty payments falls back to paidInput', () {
      expect(effectivePaidInput([], 350.0), 350.0);
    });

    test('non-empty payments overrides paidInput with their sum', () {
      final rows = [const PayEntry('Cash', 300.0), const PayEntry('Bank', 200.0)];
      expect(effectivePaidInput(rows, 0.0), 500.0);
    });
  });

  group('paymentMethodLabel', () {
    test('nothing paid -> credit', () {
      expect(paymentMethodLabel(paid: 0.0, payments: [], singleMethod: 'Cash'), 'credit');
    });

    test('no split rows -> the picker value', () {
      expect(paymentMethodLabel(paid: 100.0, payments: [], singleMethod: 'Bank'), 'Bank');
    });

    test('one split row -> that row\'s method', () {
      final rows = [const PayEntry('Bank', 100.0)];
      expect(paymentMethodLabel(paid: 100.0, payments: rows, singleMethod: 'Cash'), 'Bank');
    });

    test('two distinct methods -> joined in entry order', () {
      final rows = [const PayEntry('Cash', 300.0), const PayEntry('Bank', 200.0)];
      expect(paymentMethodLabel(paid: 500.0, payments: rows, singleMethod: 'Cash'), 'Cash + Bank');
    });

    test('same method twice -> stays a single label', () {
      final rows = [const PayEntry('Cash', 100.0), const PayEntry('Cash', 200.0)];
      expect(paymentMethodLabel(paid: 300.0, payments: rows, singleMethod: 'Cash'), 'Cash');
    });
  });

  group('isDuplicateSale', () {
    final day = DateTime(2026, 9, 29, 10, 0);
    final sameDayLater = DateTime(2026, 9, 29, 18, 30);
    final nextDay = DateTime(2026, 9, 30, 10, 0);

    test('same customer, total and calendar day -> duplicate', () {
      expect(
        isDuplicateSale(
          candidateCustomer: 'Ali',
          candidateTotal: 500.0,
          candidateDate: day,
          wantedCustomer: 'ali',
          wantedTotal: 500.0,
          wantedDate: sameDayLater,
        ),
        isTrue,
      );
    });

    test('blank customer matches blank (Walk-in)', () {
      expect(
        isDuplicateSale(
          candidateCustomer: '',
          candidateTotal: 250.0,
          candidateDate: day,
          wantedCustomer: '  ',
          wantedTotal: 250.0,
          wantedDate: day,
        ),
        isTrue,
      );
    });

    test('different day -> not duplicate, no rolling window', () {
      expect(
        isDuplicateSale(
          candidateCustomer: 'Ali',
          candidateTotal: 500.0,
          candidateDate: day,
          wantedCustomer: 'Ali',
          wantedTotal: 500.0,
          wantedDate: nextDay,
        ),
        isFalse,
      );
    });

    test('different total -> not duplicate', () {
      expect(
        isDuplicateSale(
          candidateCustomer: 'Ali',
          candidateTotal: 500.0,
          candidateDate: day,
          wantedCustomer: 'Ali',
          wantedTotal: 501.0,
          wantedDate: day,
        ),
        isFalse,
      );
    });
  });
}
