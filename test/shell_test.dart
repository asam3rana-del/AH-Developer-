import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/shell_repository.dart';
import 'package:ah_developer_kiryana_store/models/shell.dart';

ShellCustomer c(String name, {String phone = '', int owed = 0}) =>
    ShellCustomer(name: name, phone: phone, shellsOwed: owed, createdAt: 0);

void main() {
  group('issue / return maths', () {
    test('issue adds, return subtracts', () {
      expect(applyIssueReturn(owed: 2, isIssue: true, qty: 3), 5);
      expect(applyIssueReturn(owed: 5, isIssue: false, qty: 5), 0);
      expect(applyIssueReturn(owed: 5, isIssue: false, qty: 2), 3);
    });

    test('return more than owed is rejected; new customer cannot return', () {
      expect(() => applyIssueReturn(owed: 2, isIssue: false, qty: 3), throwsArgumentError);
      expect(() => applyIssueReturn(owed: 0, isIssue: false, qty: 1), throwsArgumentError);
    });

    test('qty must be positive', () {
      expect(() => applyIssueReturn(owed: 0, isIssue: true, qty: 0), throwsArgumentError);
      expect(() => applyIssueReturn(owed: 0, isIssue: true, qty: -1), throwsArgumentError);
    });
  });

  group('shop stock', () {
    test('delta sign by reason', () {
      expect(shopStockDelta(shopAdd, 4), 4);
      expect(shopStockDelta(shopRemove, 4), -4);
      expect(shopStockDelta(shopRefill, 4), -4);
    });

    test('cannot remove more than current stock', () {
      expect(shopStockCanApply(current: 5, delta: -5), isTrue);
      expect(shopStockCanApply(current: 5, delta: -6), isFalse);
      expect(shopStockCanApply(current: 0, delta: 3), isTrue);
    });
  });

  group('search', () {
    final all = [c('Ali Khan', phone: '0300-111'), c('bilal', phone: '0321-999'), c('Sara')];
    test('empty query returns all', () => expect(filterShellCustomers(all, '  ').length, 3));
    test('name is case-insensitive', () => expect(filterShellCustomers(all, 'ALI').map((e) => e.name), ['Ali Khan']));
    test('phone matches', () => expect(filterShellCustomers(all, '0321').map((e) => e.name), ['bilal']));
    test('no match', () => expect(filterShellCustomers(all, 'zzz'), isEmpty));
  });

  test('model map round trip', () {
    final t = ShellTransaction(customerId: 1, type: shellIssue, qty: 3, note: 'n', createdAt: 5);
    final back = ShellTransaction.fromMap({...t.toMap(), 'id': 9});
    expect((back.id, back.customerId, back.qty, back.isIssue, back.note), (9, 1, 3, true, 'n'));
    final l = ShopEmptyShellLog.fromMap(const ShopEmptyShellLog(delta: -2, reason: shopRefill, createdAt: 1).toMap());
    expect((l.delta, l.reason), (-2, shopRefill));
  });
}
