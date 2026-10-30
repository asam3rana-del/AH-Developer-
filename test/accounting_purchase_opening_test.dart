import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/balance_sheet_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Audit (2026-10-30) P1 ke baaki hisse:
///  * Purchase -> supplier balance -> stock -> cost (weighted average)
///  * Opening balances (customer + supplier) -> balance sheet receivables / payables
/// `accounting_reconciliation_test.dart` jaisa setup (asli AppDatabase schema, temp folder).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_accounting_purchase_opening_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'accounting-test-admin';
    Session.role = 'admin';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  Future<int> addCustomer(String name, {double openingBalance = 0}) => db.insert('customers', {
        'name': name,
        'phone': '',
        'creditLimit': 0.0,
        'openingBalance': openingBalance,
        // App opening balance alag column mein rakhta hai; stored `balance` sirf bills - payments hai.
        'balance': 0.0,
        'stuckBalance': 0.0,
        'updatedAt': now,
        'dirty': 1,
      });

  Future<int> addSupplier(String name, {double openingBalance = 0}) => db.insert('suppliers', {
        'name': name,
        'phone': '',
        'openingBalance': openingBalance,
        'balance': 0.0,
        'updatedAt': now,
        'dirty': 1,
      });

  Future<void> addProduct({double stock = 10, double cost = 50}) async {
    final product = Product(
      barcode: 'rice',
      name: 'Rice',
      category: 'General',
      unit: 'pcs',
      cost: cost,
      salePrice: 100,
      stock: stock,
      openingStock: stock,
    );
    await db.insert('products', product.toMap());
    if (stock != 0) await StockLedger.logOpeningStock(db, 'rice', stock, unitCost: cost, now: now);
  }

  PurchaseLine purchaseLine({required double qty, required double rate}) => PurchaseLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        rate: rate,
        amount: qty * rate,
      );

  SaleLine saleLine({required double qty, required double rate, required double totalCost}) => SaleLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        unitPrice: rate,
        cost: totalCost,
        amount: qty * rate,
      );

  double num_(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  Future<Map<String, Object?>> product() async =>
      (await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single;

  Future<double> supplierBalance(int id) async =>
      num_((await db.query('suppliers', where: 'id=?', whereArgs: [id])).single, 'balance');

  Future<double> customerBalance(int id) async =>
      num_((await db.query('customers', where: 'id=?', whereArgs: [id])).single, 'balance');

  Future<double> cashTotal(String type) async =>
      num_((await db.rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM cash_transactions WHERE type=?', [type])).single, 't');

  Future<double> ledgerTotal() async =>
      num_((await db.rawQuery('SELECT COALESCE(SUM(qty),0) AS t FROM stock_movements WHERE barcode=?', ['rice'])).single, 't');

  test('purchase: stock, weighted-average cost, supplier due, cash-out and stock ledger agree', () async {
    final supplierId = await addSupplier('Bashir Traders');
    await addProduct(stock: 10, cost: 50); // purani value 10 x 50 = 500

    final billNo = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders',
      lines: [purchaseLine(qty: 10, rate: 70)], // nayi value 700
      amountPaid: 300,
      purchaseDateMillis: now,
      paymentMethod: 'Cash',
    );

    final p = await product();
    expect(num_(p, 'stock'), 20);
    // Weighted average: (500 + 700) / 20 = 60.
    expect(num_(p, 'cost'), closeTo(60, 0.001));

    final bill = (await db.query('purchases', where: 'billNo=?', whereArgs: [billNo])).single;
    expect(num_(bill, 'total'), 700);
    expect(num_(bill, 'paid'), 300);
    expect(await supplierBalance(supplierId), 400); // 700 - 300
    expect(await cashTotal('OUT'), 300);
    expect(await cashTotal('IN'), 0);
    expect(await ledgerTotal(), num_(p, 'stock'));

    final sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.payables, 400);
    expect(sheet.figures.stockValue, closeTo(1200, 0.001)); // 20 x 60
    expect(sheet.suppliersDrifted, 0);
    expect(sheet.customersDrifted, 0);
  });

  test('purchase then sale: profit uses the weighted cost, stock and ledger stay equal', () async {
    final customerId = await addCustomer('Ali');
    await addSupplier('Bashir Traders');
    await addProduct(stock: 10, cost: 50);

    await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders',
      lines: [purchaseLine(qty: 10, rate: 70)],
      amountPaid: 700,
      purchaseDateMillis: now,
      paymentMethod: 'Cash',
    );
    final costPerUnit = num_(await product(), 'cost'); // 60

    await SaleRepository.instance.saveSale(
      lines: [saleLine(qty: 5, rate: 100, totalCost: 5 * costPerUnit)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 200,
      saleType: 'retail',
      saleDateMillis: now,
    );

    expect(num_(await product(), 'stock'), 15);
    expect(await ledgerTotal(), 15);
    expect(await customerBalance(customerId), 300); // 500 - 200

    final sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.receivables, 300);
    expect(sheet.figures.payables, 0);
    expect(sheet.figures.stockValue, closeTo(900, 0.001)); // 15 x 60
    expect(sheet.figures.netProfit, closeTo(200, 0.001)); // 500 sale - 300 cost
    expect(sheet.figures.totalAssets, closeTo(sheet.figures.totalLiabilitiesAndCapital, 0.001));
    expect(sheet.customersDrifted, 0);
    expect(sheet.suppliersDrifted, 0);
  });

  test('opening balances: customer + supplier carry into balance sheet along with new bills', () async {
    final customerId = await addCustomer('Ali', openingBalance: 100); // Ali ne hamein dene hain
    final supplierId = await addSupplier('Bashir Traders', openingBalance: 200); // hamein dene hain
    await addProduct(stock: 10, cost: 50);

    // Opening balances ke saath hi koi bill na ho to bhi balance sheet mein aate hain.
    var sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.receivables, 100);
    expect(sheet.figures.payables, 200);
    expect(sheet.customersDrifted, 0);
    expect(sheet.suppliersDrifted, 0);

    await SaleRepository.instance.saveSale(
      lines: [saleLine(qty: 4, rate: 100, totalCost: 200)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 50,
      saleType: 'retail',
      saleDateMillis: now,
    );
    await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders',
      lines: [purchaseLine(qty: 10, rate: 70)],
      amountPaid: 300,
      purchaseDateMillis: now,
      paymentMethod: 'Cash',
    );

    // Stored balance = sirf naye bills - payments (opening alag); balance sheet closing = opening + balance.
    expect(await customerBalance(customerId), 350); // 400 - 50
    expect(await supplierBalance(supplierId), 400); // 700 - 300

    sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.receivables, 450);
    expect(sheet.figures.payables, 600);
    expect(sheet.customersDrifted, 0);
    expect(sheet.suppliersDrifted, 0);
    expect(await ledgerTotal(), num_(await product(), 'stock'));
  });
}
