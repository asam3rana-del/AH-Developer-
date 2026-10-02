import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/db/items_repository.dart';
import 'package:ah_developer_kiryana_store/models/category_unit.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

void main() {
  const products = [
    Product(barcode: '111', name: 'Rice', category: 'Grocery'),
    Product(barcode: '222', name: 'Sugar', category: 'Grocery', searchTag: 'cheeni'),
    Product(barcode: '333', name: 'Soap', category: ''),
    Product(barcode: '444', name: 'Tea', category: '   '), // blank == uncategorized
  ];
  const cats = [Category('Grocery'), Category('Empty')];

  test('first row is "Items Not in Any Category" and blank categories count there', () {
    final rows = buildCategoryRows(products, cats, '');
    expect(rows.first.name, kNoCategoryLabel);
    expect(rows.first.uncategorized, isTrue);
    expect(rows.first.count, 2);
    expect(rows[1].name, 'Grocery');
    expect(rows[1].count, 2);
    expect(rows[2].count, 0);
  });

  test('category search is case-insensitive on the name', () {
    final rows = buildCategoryRows(products, cats, 'groc');
    expect(rows.map((r) => r.name), ['Grocery']);
  });

  test('product search matches name, searchTag or barcode', () {
    expect(filterProducts(products, 'cheeni').map((p) => p.barcode), ['222']);
    expect(filterProducts(products, '333').map((p) => p.barcode), ['333']);
    expect(filterProducts(products, '').length, 4);
    expect(filterProducts(products, 'zzz'), isEmpty);
  });

  test('categoryKey treats blank as empty', () {
    expect(categoryKey(products[3]), '');
    expect(categoryKey(products[0]), 'Grocery');
  });

  test('productsForRole: cashier ko cost zero, admin/manager ko asal', () {
    const withCost = [Product(barcode: '1', name: 'Rice', cost: 90, salePrice: 100)];
    expect(productsForRole(withCost, 'cashier').first.cost, 0);
    expect(productsForRole(withCost, 'cashier').first.salePrice, 100);
    expect(productsForRole(withCost, 'manager').first.cost, 90);
    expect(productsForRole(withCost, 'admin').first.cost, 90);
  });

  test('requireItemsAdmin: non-admin par throw', () {
    Session.role = 'cashier';
    expect(requireItemsAdmin, throwsStateError);
    Session.role = 'manager';
    expect(requireItemsAdmin, throwsStateError);
    Session.role = 'admin';
    expect(requireItemsAdmin, returnsNormally);
    Session.role = 'cashier';
  });
}
