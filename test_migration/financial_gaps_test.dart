import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_history_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';
import 'package:ah_developer_kiryana_store/utils/split_payment.dart';

/// Financial regression GAP tests (improvement plan P1 #5): sale edit / delete / return-then-delete / double
/// return, purchase edit / delete. Same setup as test/financial_regression_integration_test.dart.
/// NOT YET RUN - lives outside test/ so a failure cannot block release builds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    // PurchaseRepository.nextBillNo() DeviceTag.init() ke zariye SharedPreferences use karta hai.
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_financial_regression_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'financial-test-admin';
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
        'balance': openingBalance,
        'stuckBalance': 0.0,
        'updatedAt': now,
        'dirty': 1,
      });

  Future<int> addSupplier(String name, {double openingBalance = 0}) => db.insert('suppliers', {
        'name': name,
        'phone': '',
        'openingBalance': openingBalance,
        'balance': openingBalance,
        'updatedAt': now,
        'dirty': 1,
      });

  Future<void> addProduct({String barcode = 'rice', double stock = 10, double cost = 50}) async {
    final product = Product(
      barcode: barcode,
      name: 'Rice',
      category: 'General',
      unit: 'pcs',
      cost: cost,
      salePrice: 100,
      stock: stock,
      openingStock: stock,
    );
    await db.insert('products', product.toMap());
    if (stock != 0) await StockLedger.logOpeningStock(db, barcode, stock, unitCost: cost, now: now);
  }

  SaleLine saleLine({double qty = 2, double rate = 100, double cost = 50}) => SaleLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        unitPrice: rate,
        cost: cost,
        amount: qty * rate,
      );

  PurchaseLine purchaseLine({double qty = 2, double rate = 50}) => PurchaseLine(
        itemName: 'Rice',
        barcode: 'rice',
        qty: qty,
        unit: 'pcs',
        rate: rate,
        amount: qty * rate,
      );

  double numValue(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  Future<double> stockOf(String barcode) async =>
      numValue((await db.query('products', where: 'barcode=?', whereArgs: [barcode])).single, 'stock');

  Future<double> ledgerOf(String barcode) async => numValue(
      (await db.rawQuery('SELECT COALESCE(SUM(qty),0) AS total FROM stock_movements WHERE barcode=?', [barcode]))
          .single,
      'total');

  Future<double> balanceOf(String table, int id) async =>
      numValue((await db.query(table, where: 'id=?', whereArgs: [id])).single, 'balance');

  Future<double> cashIn() async => numValue(
      (await db.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE type='IN'")).single,
      'total');

  Future<String> sellToAli({double qty = 2, double paid = 100}) => SaleRepository.instance.saveSale(
        lines: [saleLine(qty: qty)],
        customerName: 'Ali',
        discountInput: 0,
        paidInput: paid,
        saleType: 'retail',
        saleDateMillis: now,
      );

  test('sale edit (qty 2 -> 5): one bill, stock, customer due, cash and ledger all follow the new bill', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await sellToAli(qty: 2, paid: 100);
    expect(await stockOf('rice'), 8);
    expect(await balanceOf('customers', customerId), 100);

    final edited = await SaleRepository.instance.saveSale(
      lines: [saleLine(qty: 5)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: now,
      editInvoice: invoice,
    );

    final sales = await db.query('sales');
    expect(sales.length, 1, reason: 'edit must not create a second bill');
    expect(numValue((await db.query('sales', where: 'invoice=?', whereArgs: [edited])).single, 'total'), 500);
    expect(await stockOf('rice'), 5);
    expect(await balanceOf('customers', customerId), 400);
    expect(await cashIn(), 100, reason: 'cash book must equal paid, not paid x2');
    expect(await ledgerOf('rice'), 5);
  });

  test('sale delete: stock, customer due, cash, payments and items are fully reversed', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await sellToAli(qty: 2, paid: 100);

    await SaleRepository.instance.deleteSale(invoice);

    expect(await db.query('sales'), isEmpty);
    expect(await db.query('sale_items'), isEmpty);
    expect(await stockOf('rice'), 10);
    expect(await balanceOf('customers', customerId), 0);
    expect(await cashIn(), 0);
    expect(await ledgerOf('rice'), 10);
  });

  test('sale return then delete does not reverse stock or due a second time', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await sellToAli(qty: 2, paid: 100);

    await SaleRepository.instance.returnSale(invoice);
    expect(await stockOf('rice'), 10);
    expect(await balanceOf('customers', customerId), 0);

    await SaleRepository.instance.deleteSale(invoice);
    expect(await stockOf('rice'), 10, reason: 'stock must not go above the original 10');
    expect(await balanceOf('customers', customerId), 0, reason: 'due must not go negative');
    expect(await ledgerOf('rice'), 10);
  });

  test('returning the same sale twice is refused and changes nothing', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await sellToAli(qty: 2, paid: 100);

    await SaleRepository.instance.returnSale(invoice);
    await expectLater(SaleRepository.instance.returnSale(invoice), throwsA(isA<ArgumentError>()));

    expect(await stockOf('rice'), 10);
    expect(await balanceOf('customers', customerId), 0);
    expect(await ledgerOf('rice'), 10);
  });

  test('purchase edit (qty 2 -> 4): one bill, stock, supplier payable and ledger follow the new bill', () async {
    await addProduct(stock: 10);
    final billNo = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Sup',
      lines: [purchaseLine(qty: 2)],
      amountPaid: 0,
      purchaseDateMillis: now,
    );
    final supplierId = (await db.query('suppliers', where: 'name=?', whereArgs: ['Sup'])).single['id'] as int;
    expect(await stockOf('rice'), 12);
    expect(await balanceOf('suppliers', supplierId), 100);

    final edited = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Sup',
      lines: [purchaseLine(qty: 4)],
      amountPaid: 0,
      purchaseDateMillis: now,
      editBillNo: billNo,
    );

    expect((await db.query('purchases')).length, 1, reason: 'edit must not create a second bill');
    expect(numValue((await db.query('purchases', where: 'billNo=?', whereArgs: [edited])).single, 'total'), 200);
    expect(await stockOf('rice'), 14);
    expect(await balanceOf('suppliers', supplierId), 200);
    expect(await ledgerOf('rice'), 14);
  });

  test('purchase delete: stock, supplier payable, items and cash are reversed', () async {
    await addProduct(stock: 10);
    final billNo = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Sup',
      lines: [purchaseLine(qty: 2)],
      amountPaid: 40,
      purchaseDateMillis: now,
    );
    final supplierId = (await db.query('suppliers', where: 'name=?', whereArgs: ['Sup'])).single['id'] as int;
    expect(await balanceOf('suppliers', supplierId), 60);

    await PurchaseHistoryRepository.instance.deletePurchase(billNo);

    expect(await db.query('purchases'), isEmpty);
    expect(await db.query('purchase_items'), isEmpty);
    expect(await stockOf('rice'), 10);
    expect(await balanceOf('suppliers', supplierId), 0);
    expect(await ledgerOf('rice'), 10);
    final cashOut = await db.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE type='OUT'");
    expect(numValue(cashOut.single, 'total'), 0);
  });
}
