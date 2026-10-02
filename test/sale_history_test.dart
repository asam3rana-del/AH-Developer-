import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/sale_history_repository.dart';

SaleWithCustomer sale(String inv, String name, double total, int at, {String status = 'active'}) =>
    SaleWithCustomer(invoice: inv, customerName: name, total: total, paymentMethod: 'cash', createdAt: at, status: status);

void main() {
  final sales = [
    sale('A1', 'Ali', 100, 10),
    sale('A2', 'Ali', 250, 30),
    sale('B1', 'Bilal', 400, 50),
    sale('W1', 'Walk-in', 60, 20, status: 'returned'),
  ];

  test('groups by customer, most recently active first, newest bill first inside', () {
    final g = groupSalesByCustomer(sales);
    expect(g.map((x) => x.customerName), ['Bilal', 'Ali', 'Walk-in']);
    expect(g[1].sales.map((s) => s.invoice), ['A2', 'A1']);
    expect(g[1].total, 350);
  });

  test('summary: returned bills are NOT counted in Total Sales', () {
    final s = summarizeSales(sales);
    expect(s.totalSales, 750);
    expect(s.totalReturned, 60);
  });

  test('customer profit = sum of bill profits, returned/unknown = 0', () {
    final g = groupSalesByCustomer(sales);
    final profits = {'A1': 20.0, 'A2': 50.0, 'B1': 90.0};
    expect(g[1].profit(profits), 70);
    expect(g[2].profit(profits), 0);
  });

  test('empty profits map (cashier/manager) gives 0 everywhere', () {
    expect(groupSalesByCustomer(sales).first.profit(const {}), 0);
  });

  test('search filters by customer name, case-insensitive; blank = all', () {
    final g = groupSalesByCustomer(sales);
    expect(filterGroups(g, 'ALI').map((x) => x.customerName), ['Ali']);
    expect(filterGroups(g, '  ').length, 3);
    expect(filterGroups(g, 'zzz'), isEmpty);
  });
}
