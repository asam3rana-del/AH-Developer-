import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/services/permissions.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

void main() {
  tearDown(() {
    Session.role = 'cashier';
    Session.permissions = '';
  });

  test('role defaults match the old hard-coded rules', () {
    expect(Permissions.defaultFor('manager', 'stock_audit'), isTrue);
    expect(Permissions.defaultFor('cashier', 'stock_audit'), isFalse);
    expect(Permissions.defaultFor('manager', 'purchase_history'), isFalse);
    expect(Permissions.defaultFor('manager', 'fix_bill_cost'), isFalse);
    expect(Permissions.defaultFor('cashier', 'cash_register'), isTrue);
    expect(Permissions.defaultFor('admin', 'fix_bill_cost'), isTrue);
  });

  test('admin overrides can grant a cashier and deny a manager', () {
    Session.role = 'cashier';
    Session.permissions = Permissions.encode({'stock_audit': true});
    expect(Permissions.can('stock_audit'), isTrue);
    expect(Permissions.can('balance_sheet'), isFalse);

    Session.role = 'manager';
    Session.permissions = Permissions.encode({'stock_adjustment': false});
    expect(Permissions.can('stock_adjustment'), isFalse);
    expect(Permissions.can('stock_taking'), isTrue);
  });

  test('admin can never be locked out', () {
    Session.role = 'admin';
    Session.permissions = Permissions.encode({'zakat': false});
    expect(Permissions.can('zakat'), isTrue);
  });

  test('bad or empty permission text means no overrides', () {
    expect(Permissions.parse(''), isEmpty);
    expect(Permissions.parse('not json'), isEmpty);
    expect(Permissions.parse('[1,2]'), isEmpty);
    expect(Permissions.encode({}), '');
  });

  test('canAnyReport follows the granted report rows', () {
    Session.role = 'cashier';
    Session.permissions = '';
    expect(Permissions.canAnyReport(), isFalse);
    Session.permissions = Permissions.encode({'stock_report': true});
    expect(Permissions.canAnyReport(), isTrue);
  });
}
