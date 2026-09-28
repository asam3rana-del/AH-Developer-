import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/cash_register_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';

void main() {
  test('date key is yyyy-MM-dd and round-trips', () {
    expect(registerDateKey(DateTime(2026, 9, 8)), '2026-09-08');
    expect(registerDateKey(DateTime(2026, 12, 31, 23, 59)), '2026-12-31');
    expect(parseRegisterDateKey('2026-09-08'), DateTime(2026, 9, 8));
    expect(parseRegisterDateKey('garbage'), isNull);
  });

  test('date keys sort like dates (lastClosedBefore relies on it)', () {
    final keys = ['2026-10-01', '2026-09-30', '2025-12-31']..sort();
    expect(keys, ['2025-12-31', '2026-09-30', '2026-10-01']);
  });

  test('expected closing = opening + in - out', () {
    expect(registerExpected(opening: 1000, totalIn: 500, totalOut: 200), 1300);
  });

  test('exact till: both differences are zero', () {
    const r = CashRegister(date: '2026-09-28', openingCash: 1000, openingBank: 5000, closingCash: 1300, closingBank: 5100, closed: true);
    const f = RegisterFlows(cashIn: 500, cashOut: 200, bankIn: 300, bankOut: 200);
    final fig = registerFigures(r, f);
    expect(fig.expectedCash, 1300);
    expect(fig.expectedBank, 5100);
    expect(registerIsMatch(fig.diffCash), isTrue);
    expect(registerIsMatch(fig.diffBank), isTrue);
    expect(registerIsMatch(fig.totalDiff), isTrue);
  });

  test('shortage is negative, excess is positive', () {
    const f = RegisterFlows(cashIn: 100);
    const short = CashRegister(date: 'd', openingCash: 0, closingCash: 90, closed: true);
    const over = CashRegister(date: 'd', openingCash: 0, closingCash: 110, closed: true);
    expect(registerFigures(short, f).diffCash, -10);
    expect(registerFigures(over, f).diffCash, 10);
  });

  test('match tolerance is under one paisa', () {
    expect(registerIsMatch(0.009), isTrue);
    expect(registerIsMatch(-0.009), isTrue);
    expect(registerIsMatch(0.01), isFalse);
  });

  test('history total diff adds both drawers (Kotlin behaviour)', () {
    const r = CashRegister(date: 'd', openingCash: 0, openingBank: 0, closingCash: 90, closingBank: 10, closed: true);
    final fig = registerFigures(r, const RegisterFlows(cashIn: 100, bankIn: 0));
    expect(fig.diffCash, -10);
    expect(fig.diffBank, 10);
    expect(fig.totalDiff, 0); // shows "Matched" in Kotlin's history row
  });

  test('CashRegister model round-trips closed flag', () {
    const r = CashRegister(date: '2026-09-28', openingCash: 1, closed: true);
    expect(CashRegister.fromMap(r.toMap()).closed, isTrue);
    expect(CashRegister.fromMap(const CashRegister(date: 'x').toMap()).closed, isFalse);
  });
}
