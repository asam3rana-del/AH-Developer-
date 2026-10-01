import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/utils/discount_calculator.dart';

// Kotlin `DiscountCalculatorTest` (test/pricing) ke 10 cases, Dart mein.
void main() {
  group('DiscountCalculator.compute', () {
    test('no discount, full payment - due is zero', () {
      final t = DiscountCalculator.compute(1000, 0, 1000);
      expect(t.subtotal, 1000);
      expect(t.discount, 0);
      expect(t.total, 1000);
      expect(t.paid, 1000);
      expect(t.due, 0);
    });

    test('partial payment leaves a due balance', () {
      final t = DiscountCalculator.compute(1000, 0, 400);
      expect(t.total, 1000);
      expect(t.paid, 400);
      expect(t.due, 600);
    });

    test('discount reduces total correctly', () {
      final t = DiscountCalculator.compute(1000, 100, 900);
      expect(t.discount, 100);
      expect(t.total, 900);
      expect(t.paid, 900);
      expect(t.due, 0);
    });

    test('discount larger than subtotal is clamped to subtotal', () {
      final t = DiscountCalculator.compute(500, 800, 0);
      expect(t.discount, 500);
      expect(t.total, 0);
      expect(t.due, 0);
    });

    test('negative discount input is clamped to zero', () {
      final t = DiscountCalculator.compute(500, -50, 500);
      expect(t.discount, 0);
      expect(t.total, 500);
    });

    test('paid more than total is clamped to total - no negative due', () {
      final t = DiscountCalculator.compute(500, 0, 900);
      expect(t.paid, 500);
      expect(t.due, 0);
    });

    test('negative paid input is clamped to zero', () {
      final t = DiscountCalculator.compute(500, 0, -100);
      expect(t.paid, 0);
      expect(t.due, 500);
    });

    test('negative subtotal is clamped to zero - never a negative bill', () {
      final t = DiscountCalculator.compute(-200, 0, 0);
      expect(t.subtotal, 0);
      expect(t.total, 0);
      expect(t.due, 0);
    });

    test('zero subtotal with zero payment is fully settled', () {
      final t = DiscountCalculator.compute(0, 0, 0);
      expect(t.total, 0);
      expect(t.paid, 0);
      expect(t.due, 0);
    });

    test('full credit sale - nothing paid', () {
      final t = DiscountCalculator.compute(750, 0, 0);
      expect(t.total, 750);
      expect(t.paid, 0);
      expect(t.due, 750);
    });

    test('fully discounted sale has no due (so no customer is needed)', () {
      final t = DiscountCalculator.compute(300, 300, 0);
      expect(t.total, 0);
      expect(t.due, 0);
    });
  });
}
