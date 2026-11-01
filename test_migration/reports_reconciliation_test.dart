import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/balance_sheet_repository.dart';
import 'package:ah_developer_kiryana_store/db/expense_repository.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/db/reports_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Reports / profit milan (go-live P1: "Profit, reports, balance sheet"). NOT YET RUN - lives outside test/ so a
/// failure cannot block release builds.
///
/// Ek poora "mahina": opening balances, purchase (udhaar), do sales (ek par discount), customer payment,
/// supplier payment, expense, aur ek bill ki return. Phir wohi sach teen jagah se milaya jata hai:
/// Profit & Loss report, Balance Sheet, aur kachche tables (cash, stock ledger, party balances).
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
    tempDir = await Directory.systemTemp.createTemp('ah_reports_reconciliation_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'reports-test-admin';
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

  double num_(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  Future<double> scalar(String sql) async =>
      ((await db.rawQuery(sql)).first.values.first as num?)?.toDouble() ?? 0.0;

  test('one month of mixed trading: P&L report, balance sheet and raw tables tell the same story', () async {
    final aliId = await addCustomer('Ali', openingBalance: 100);
    final bilalId = await addCustomer('Bilal');
    final bashirId = await addSupplier('Bashir Traders', openingBalance: 200);

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

    // A. Purchase 10 x 70 = 700, 300 paid in cash => weighted cost (500 + 700) / 20 = 60, supplier owes 400 more.
    await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders',
      lines: [PurchaseLine(itemName: 'Rice', barcode: 'rice', qty: 10, unit: 'pcs', rate: 70, amount: 700)],
      amountPaid: 300,
      purchaseDateMillis: now,
      paymentMethod: 'Cash',
    );

    SaleLine saleLine(double qty) => SaleLine(
          itemName: 'Rice',
          barcode: 'rice',
          qty: qty,
          unit: 'pcs',
          unitPrice: 100,
          cost: qty * 60,
          amount: qty * 100,
        );

    // B. Ali: 5 x 100 = 500, 200 paid.  C. Bilal: 3 x 100 = 300, discount 30 => 270, nothing paid.
    await SaleRepository.instance.saveSale(
      lines: [saleLine(5)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 200,
      saleType: 'retail',
      saleDateMillis: now,
    );
    final bilalInvoice = await SaleRepository.instance.saveSale(
      lines: [saleLine(3)],
      customerName: 'Bilal',
      discountInput: 30,
      paidInput: 0,
      saleType: 'retail',
      saleDateMillis: now,
    );
    expect(num_((await db.query('sales', where: 'invoice=?', whereArgs: [bilalInvoice])).single, 'total'), 270);

    // D. Ali pays 100, E. we pay Bashir 150, F. expense 50.
    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: aliId,
      partyName: 'Ali',
      amount: 100,
      method: 'cash',
      note: '',
      dateMillis: now,
    );
    await PaymentRepository.instance.save(
      isCustomer: false,
      partyId: bashirId,
      partyName: 'Bashir Traders',
      amount: 150,
      method: 'cash',
      note: '',
      dateMillis: now,
    );
    await db.transaction((txn) => ExpenseRepository.insertExpenseWithCash(
          txn,
          category: 'Rent',
          description: 'Shop rent',
          amount: 50,
          method: 'cash',
          now: now,
        ));

    // G. Bilal's bill is returned in full.
    await SaleRepository.instance.returnSale(bilalInvoice);

    // ---- Stock: 10 + 10 - 5 - 3 + 3 = 15, ledger agrees, valued at the weighted cost 60.
    final stock = num_((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock');
    expect(stock, 15);
    expect(await scalar("SELECT COALESCE(SUM(qty),0) FROM stock_movements WHERE barcode='rice'"), stock);

    // ---- Profit & Loss report: only Ali's bill counts (Bilal's was returned).
    final report = await ReportsRepository.instance.load(allTime);
    expect(report.totalSales, 500);
    expect(report.pl.cogs, 300);
    expect(report.pl.grossProfit, 200);
    expect(report.totalExpenses, 50);
    expect(report.pl.netProfit, 150);
    expect(report.saleReturns, 270);

    // ---- Balance sheet agrees with the report and with the party ledgers.
    final sheet = await BalanceSheetRepository.instance.load();
    expect(sheet.figures.netProfit, report.pl.netProfit);
    expect(sheet.figures.stockValue, closeTo(900, 0.001)); // 15 x 60
    expect(sheet.figures.receivables, 300); // Ali: opening 100 + (500 - 200 - 100); Bilal: 0
    expect(sheet.figures.payables, 450); // Bashir: opening 200 + (700 - 300 - 150)
    expect(sheet.customersDrifted, 0);
    expect(sheet.suppliersDrifted, 0);
    expect(sheet.figures.totalAssets, closeTo(sheet.figures.totalLiabilitiesAndCapital, 0.001));

    // ---- Cash + bank on the sheet = every cash row ever written (nothing hidden, nothing double counted).
    final cashIn = await scalar("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='IN'");
    final cashOut = await scalar("SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='OUT'");
    expect(sheet.figures.cashInHand + sheet.figures.bankBalance, closeTo(cashIn - cashOut, 0.001));

    // ---- Stored party balances = bills - payments (opening is separate).
    expect(num_((await db.query('customers', where: 'id=?', whereArgs: [aliId])).single, 'balance'), 200);
    expect(num_((await db.query('customers', where: 'id=?', whereArgs: [bilalId])).single, 'balance'), 0);
    expect(num_((await db.query('suppliers', where: 'id=?', whereArgs: [bashirId])).single, 'balance'), 250);
  });
}
