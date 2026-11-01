import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Sale partial return: sirf chuni hui qty stock mein wapas, total/paid/customer balance sirf utna kam,
/// refund cash-OUT; poori qty = poori bill return (status 'returned').
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_sale_partial_return_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'partial-return-admin';
    Session.role = 'admin';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  double n(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  Future<int> addCustomer(String name) => db.insert('customers', {
        'name': name,
        'phone': '',
        'creditLimit': 0.0,
        'openingBalance': 0.0,
        'balance': 0.0,
        'stuckBalance': 0.0,
        'updatedAt': now,
        'dirty': 1,
      });

  Future<void> addProduct() async {
    await db.insert(
        'products',
        Product(
          barcode: 'rice',
          name: 'Rice',
          category: 'General',
          unit: 'pcs',
          cost: 50,
          salePrice: 100,
          stock: 10,
          openingStock: 10,
        ).toMap());
    await StockLedger.logOpeningStock(db, 'rice', 10, unitCost: 50, now: now);
  }

  SaleLine line(double qty, double rate) => SaleLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        unitPrice: rate,
        cost: qty * 50,
        amount: qty * rate,
      );

  test('partial return: stock, total, paid, customer balance and refund move by the returned part only', () async {
    final customerId = await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(4, 100)], // total 400
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 300, // due 100
      saleType: 'retail',
      saleDateMillis: now,
    );
    final itemId = n((await db.query('sale_items', where: 'invoice=?', whereArgs: [invoice])).single, 'id').toInt();

    await SaleRepository.instance.returnSaleItems(invoice, {itemId: 1});

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(sale['status'], 'active');
    expect(n(sale, 'total'), closeTo(300, 0.001));
    expect(n(sale, 'paid'), closeTo(300, 0.001)); // 300 <= new total, no refund
    final item = (await db.query('sale_items', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(n(item, 'qty'), closeTo(3, 0.001));
    expect(n(item, 'amount'), closeTo(300, 0.001));
    expect(n(item, 'cost'), closeTo(150, 0.001));
    expect(n((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), closeTo(7, 0.001));
    // Due 100 -> 0 (return 100 ne baqaya khatam kiya).
    expect(n((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), closeTo(0, 0.001));
    final rets = await db.query('returns', where: 'reference=?', whereArgs: [invoice]);
    expect(rets.single['type'], 'sale');
    expect(n(rets.single, 'amount'), closeTo(100, 0.001));
  });

  test('partial return refunds the part of paid that now exceeds the bill', () async {
    await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(4, 100)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 400,
      saleType: 'retail',
      saleDateMillis: now,
    );
    final itemId = n((await db.query('sale_items', where: 'invoice=?', whereArgs: [invoice])).single, 'id').toInt();

    await SaleRepository.instance.returnSaleItems(invoice, {itemId: 2});

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(n(sale, 'total'), closeTo(200, 0.001));
    expect(n(sale, 'paid'), closeTo(200, 0.001));
    final out = await db.query('cash_transactions', where: "reference=? AND type='OUT'", whereArgs: ['return:$invoice']);
    expect(out.fold<double>(0, (t, r) => t + n(r, 'amount')), closeTo(200, 0.001));
  });

  test('returning every line in full falls back to the whole-bill return', () async {
    await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(2, 100)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 200,
      saleType: 'retail',
      saleDateMillis: now,
    );
    final itemId = n((await db.query('sale_items', where: 'invoice=?', whereArgs: [invoice])).single, 'id').toInt();

    await SaleRepository.instance.returnSaleItems(invoice, {itemId: 2});

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(sale['status'], 'returned');
    expect(n((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), closeTo(10, 0.001));
  });

  test('cashier cannot do a partial return', () async {
    await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(2, 100)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 200,
      saleType: 'retail',
      saleDateMillis: now,
    );
    Session.role = 'cashier';
    await expectLater(SaleRepository.instance.returnSaleItems(invoice, {1: 1}), throwsA(anything));
  });
}
