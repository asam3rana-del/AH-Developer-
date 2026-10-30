import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/balance_sheet_repository.dart';
import 'package:ah_developer_kiryana_store/db/expense_repository.dart';
import 'package:ah_developer_kiryana_store/db/reports_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Audit (2026-10-30) P1: sale -> return -> profit, expenses -> balance sheet, aur double-save alert.
/// Asli AppDatabase schema (temp folder, sqflite_common_ffi) — `financial_regression_integration_test.dart` jaisa setup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;
  const allTime = ReportRange(0, 9999999999999);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_accounting_reconciliation_');
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
    await StockLedger.logOpeningStock(db, 'rice', stock, unitCost: cost, now: now);
  }

  /// [totalCost] = is line ki poori cost (sale_items.cost wahi store hota hai jo line mein diya jaye).
  SaleLine line({required double qty, required double rate, required double totalCost}) => SaleLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        unitPrice: rate,
        cost: totalCost,
        amount: qty * rate,
      );

  double num_(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  Future<double> productStock() async =>
      num_((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock');

  Future<double> customerBalance(int id) async =>
      num_((await db.query('customers', where: 'id=?', whereArgs: [id])).single, 'balance');

  Future<double> cashTotal(String type) async =>
      num_((await db.rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM cash_transactions WHERE type=?', [type])).single, 't');

  Future<double> ledgerTotal() async =>
      num_((await db.rawQuery('SELECT COALESCE(SUM(qty),0) AS t FROM stock_movements WHERE barcode=?', ['rice'])).single, 't');

  test('sale -> return: stock, customer due, cash, reports and stock ledger all reverse exactly', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);

    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(qty: 4, rate: 100, totalCost: 200)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: now,
    );

    expect(await productStock(), 6);
    expect(await customerBalance(customerId), 300);
    var report = await ReportsRepository.instance.load(allTime);
    expect(report.totalSales, 400);
    expect(report.totalProfit, 200);
    expect(report.saleCount, 1);
    expect(report.saleReturns, 0);
    expect(await ledgerTotal(), await productStock());

    await SaleRepository.instance.returnSale(invoice);

    expect(await productStock(), 10);
    expect(await customerBalance(customerId), 0);
    expect((await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single['status'], 'returned');
    final returns = await db.query('returns', where: 'reference=?', whereArgs: [invoice]);
    expect(returns.length, 1);
    expect(num_(returns.single, 'amount'), 400);

    report = await ReportsRepository.instance.load(allTime);
    expect(report.totalSales, 0);
    expect(report.totalProfit, 0);
    expect(report.saleCount, 0);
    expect(report.saleReturns, 400);
    expect(report.pl.netProfit, 0);

    // Jo paise liye wahi wapas gaye: cash ka net zero.
    expect(await cashTotal('IN') - await cashTotal('OUT'), 0);
    expect(await ledgerTotal(), await productStock());

    // Dobara return nahi ho sakta, aur kuch badalta nahi.
    await expectLater(SaleRepository.instance.returnSale(invoice), throwsA(isA<ArgumentError>()));
    expect(await productStock(), 10);
    expect(await customerBalance(customerId), 0);
    expect((await db.query('returns', where: 'reference=?', whereArgs: [invoice])).length, 1);
  });

  test('sale + expense: report net profit and balance sheet figures agree', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10, cost: 50);

    await SaleRepository.instance.saveSale(
      lines: [line(qty: 4, rate: 100, totalCost: 200)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: now,
    );
    await db.transaction((txn) => ExpenseRepository.insertExpenseWithCash(
          txn,
          category: 'Rent',
          description: 'Shop rent',
          amount: 50,
          method: 'cash',
          now: now,
        ));

    final report = await ReportsRepository.instance.load(allTime);
    expect(report.totalExpenses, 50);
    expect(report.pl.grossProfit, 200);
    expect(report.pl.netProfit, 150);
    // Cash: 100 sale se aaye, 50 expense mein gaye.
    expect(await cashTotal('IN') - await cashTotal('OUT'), 50);

    final sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.netProfit, report.pl.netProfit);
    expect(sheet.figures.receivables, await customerBalance(customerId));
    expect(sheet.figures.receivables, 300);
    expect(sheet.figures.stockValue, 300); // 6 bache x cost 50
    expect(sheet.customersDrifted, 0);
    expect(sheet.suppliersDrifted, 0);
    // Capital balancing figure hai, is liye yeh formulas ka sanity check hai (asli milan upar ke figures se hota hai).
    expect(sheet.figures.totalAssets, closeTo(sheet.figures.totalLiabilitiesAndCapital, 0.001));
  });

  test('double-save alert: same customer, total and day is flagged; other total or returned bill is not', () async {
    await addCustomer('Ali');
    await addProduct(stock: 10);
    final today = DateTime.now().millisecondsSinceEpoch;

    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(qty: 2, rate: 100, totalCost: 100)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: today,
    );

    final dup = await SaleRepository.instance.findDuplicateSale(customerName: 'Ali', total: 200, saleDateMillis: today);
    expect(dup?.invoice, invoice);
    expect(await SaleRepository.instance.findDuplicateSale(customerName: 'Ali', total: 250, saleDateMillis: today), isNull);
    // Apni hi bill edit karte waqt khud ko duplicate nahi samajhna.
    expect(
      await SaleRepository.instance
          .findDuplicateSale(customerName: 'Ali', total: 200, saleDateMillis: today, excludeInvoice: invoice),
      isNull,
    );

    await SaleRepository.instance.returnSale(invoice);
    expect(await SaleRepository.instance.findDuplicateSale(customerName: 'Ali', total: 200, saleDateMillis: today), isNull);
  });
}
