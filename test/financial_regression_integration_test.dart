import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';
import 'package:ah_developer_kiryana_store/utils/split_payment.dart';

/// Real AppDatabase schema in an isolated temp directory using sqflite_common_ffi.
/// Existing unit tests are intentionally left untouched.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
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

  test('sale -> linked customer receipt: stock, paid, due, cash and ledger reconcile', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);

    final invoice = await SaleRepository.instance.saveSale(
      lines: [saleLine()],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: now,
    );

    expect(numValue((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), 8);
    expect(numValue((await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single, 'total'), 200);
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 100);

    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 40,
      method: 'Cash',
      note: 'part payment',
      dateMillis: now + 1000,
      billRef: invoice,
    );

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(numValue(sale, 'paid'), 140);
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 60);
    final cash = await db.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE type='IN'");
    expect(numValue(cash.single, 'total'), 140);
    final ledger = await db.rawQuery('SELECT COALESCE(SUM(qty),0) AS total FROM stock_movements WHERE barcode=?', ['rice']);
    expect(numValue(ledger.single, 'total'), 8);
  });

  test('purchase -> supplier payment: stock, payable, paid and cash-out reconcile', () async {
    final supplierId = await addSupplier('Bashir Traders');
    await addProduct(stock: 0);

    final billNo = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders',
      lines: [purchaseLine()],
      amountPaid: 40,
      purchaseDateMillis: now,
      paymentMethod: 'Cash',
    );

    expect(numValue((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), 2);
    expect(numValue((await db.query('suppliers', where: 'id=?', whereArgs: [supplierId])).single, 'balance'), 60);

    await PaymentRepository.instance.save(
      isCustomer: false,
      partyId: supplierId,
      partyName: 'Bashir Traders',
      amount: 20,
      method: 'Cash',
      note: 'part payment',
      dateMillis: now + 1000,
      billRef: billNo,
    );

    expect(numValue((await db.query('purchases', where: 'billNo=?', whereArgs: [billNo])).single, 'paid'), 60);
    expect(numValue((await db.query('suppliers', where: 'id=?', whereArgs: [supplierId])).single, 'balance'), 40);
    final cash = await db.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE type='OUT'");
    expect(numValue(cash.single, 'total'), 60);
    final ledger = await db.rawQuery('SELECT COALESCE(SUM(qty),0) AS total FROM stock_movements WHERE barcode=?', ['rice']);
    expect(numValue(ledger.single, 'total'), 2);
  });

  test('linked payment save -> update -> delete reverses party, bill and cash exactly', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await SaleRepository.instance.saveSale(
      lines: [saleLine()], customerName: 'Ali', discountInput: 0, paidInput: 0,
      saleType: 'retail', saleDateMillis: now,
    );

    await PaymentRepository.instance.save(
      isCustomer: true, partyId: customerId, partyName: 'Ali', amount: 50,
      method: 'Cash', note: '', dateMillis: now, billRef: invoice,
    );
    var sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(numValue(sale, 'paid'), 50);
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 150);

    var payment = Payment.fromMap((await db.query('payments', where: 'billReference=?', whereArgs: [invoice])).single);
    await PaymentRepository.instance.update(
      original: payment, isCustomer: true, partyName: 'Ali', newAmount: 70,
      newMethod: 'Bank', newNote: 'updated', newDateMillis: now + 1, newBillRef: invoice,
    );
    sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(numValue(sale, 'paid'), 70);
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 130);
    payment = Payment.fromMap((await db.query('payments', where: 'billReference=?', whereArgs: [invoice])).single);
    expect(payment.amount, 70);
    expect(payment.method, 'Bank');

    await PaymentRepository.instance.delete(payment: payment, isCustomer: true);
    sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(numValue(sale, 'paid'), 0);
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 200);
    expect(await db.query('payments', where: 'billReference=?', whereArgs: [invoice]), isEmpty);
    expect(await db.query('cash_transactions', where: 'reference=?', whereArgs: [payment.reference]), isEmpty);
  });

  test('sale edit refuses customer reassignment while a bill-linked payment exists', () async {
    final oldCustomerId = await addCustomer('Ali');
    await addCustomer('Bilal');
    await addProduct(stock: 10);
    final invoice = await SaleRepository.instance.saveSale(
      lines: [saleLine()], customerName: 'Ali', discountInput: 0, paidInput: 100,
      saleType: 'retail', saleDateMillis: now,
    );
    await PaymentRepository.instance.save(
      isCustomer: true, partyId: oldCustomerId, partyName: 'Ali', amount: 50,
      method: 'Cash', note: '', dateMillis: now + 1, billRef: invoice,
    );

    await expectLater(
      SaleRepository.instance.saveSale(
        lines: [saleLine()], customerName: 'Bilal', discountInput: 0, paidInput: 150,
        saleType: 'retail', saleDateMillis: now, editInvoice: invoice,
      ),
      throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains('Linked payment'))),
    );
    expect((await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single['customerId'], oldCustomerId);
    expect((await db.query('payments', where: 'billReference=?', whereArgs: [invoice])).length, 1);
  });

  test('purchase edit refuses supplier reassignment while a bill-linked payment exists', () async {
    final oldSupplierId = await addSupplier('Bashir Traders');
    await addSupplier('New Supplier');
    await addProduct(stock: 0);
    final billNo = await PurchaseRepository.instance.savePurchase(
      supplierName: 'Bashir Traders', lines: [purchaseLine()], amountPaid: 40,
      purchaseDateMillis: now, paymentMethod: 'Cash',
    );
    await PaymentRepository.instance.save(
      isCustomer: false, partyId: oldSupplierId, partyName: 'Bashir Traders', amount: 20,
      method: 'Cash', note: '', dateMillis: now + 1, billRef: billNo,
    );

    await expectLater(
      PurchaseRepository.instance.savePurchase(
        supplierName: 'New Supplier', lines: [purchaseLine()], amountPaid: 60,
        purchaseDateMillis: now, editBillNo: billNo,
      ),
      throwsA(isA<PurchaseSaveException>().having((e) => e.message, 'message', contains('Linked payment'))),
    );
    expect((await db.query('purchases', where: 'billNo=?', whereArgs: [billNo])).single['supplierId'], oldSupplierId);
    expect((await db.query('payments', where: 'billReference=?', whereArgs: [billNo])).length, 1);
  });

  test('sale rejects NaN and infinity before any database write', () async {
    await addProduct(stock: 10);
    await expectLater(
      SaleRepository.instance.saveSale(
        lines: [saleLine(qty: double.nan)], customerName: 'Ali', discountInput: 0,
        paidInput: 0, saleType: 'retail', saleDateMillis: now,
      ),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      SaleRepository.instance.saveSale(
        lines: [saleLine()], customerName: 'Ali', discountInput: 0,
        paidInput: double.infinity, saleType: 'retail', saleDateMillis: now,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await db.query('sales'), isEmpty);
    expect(numValue((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), 10);
  });

  test('purchase rejects non-finite amounts before any database write', () async {
    await addProduct(stock: 0);
    await expectLater(
      PurchaseRepository.instance.savePurchase(
        supplierName: 'Bashir Traders', lines: [purchaseLine(qty: double.infinity)],
        amountPaid: 0, purchaseDateMillis: now,
      ),
      throwsA(isA<PurchaseSaveException>()),
    );
    await expectLater(
      PurchaseRepository.instance.savePurchase(
        supplierName: 'Bashir Traders', lines: [purchaseLine()],
        amountPaid: double.nan, purchaseDateMillis: now,
      ),
      throwsA(isA<PurchaseSaveException>()),
    );
    expect(await db.query('purchases'), isEmpty);
    expect(numValue((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), 0);
  });

  test('payment rejects NaN, infinity and zero without changing balances', () async {
    final customerId = await addCustomer('Ali', openingBalance: 100);
    for (final amount in [double.nan, double.infinity, 0.0]) {
      await expectLater(
        PaymentRepository.instance.save(
          isCustomer: true, partyId: customerId, partyName: 'Ali', amount: amount,
          method: 'Cash', note: '', dateMillis: now,
        ),
        throwsA(isA<ArgumentError>()),
      );
    }
    expect(numValue((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 100);
    expect(await db.query('payments'), isEmpty);
    expect(await db.query('cash_transactions'), isEmpty);
  });

  test('split payment cash rows equal paid total, not bill total', () async {
    await addCustomer('Ali');
    await addProduct(stock: 10);
    final invoice = await SaleRepository.instance.saveSale(
      lines: [saleLine()], customerName: 'Ali', discountInput: 0, paidInput: 500,
      payments: const [PayEntry('Cash', 300), PayEntry('Bank', 200)],
      saleType: 'retail', saleDateMillis: now,
    );
    final rows = await db.rawQuery(
      "SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE reference=? AND type='IN'",
      [invoice],
    );
    expect(numValue(rows.single, 'total'), 200); // paid is clamped to the Rs 200 bill total
  });
}
