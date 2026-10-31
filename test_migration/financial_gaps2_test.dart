import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/expense_repository.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Financial regression GAP tests, part 2 (improvement plan P1 #5): expense save/delete, opening balance, payment
/// re-assignment between bills. Same setup as financial_gaps_test.dart.
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

  double numValue(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

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


  Future<double> cashOut() async => numValue(
      (await db.rawQuery("SELECT COALESCE(SUM(amount),0) AS total FROM cash_transactions WHERE type='OUT'")).single,
      'total');

  Future<double> billPaid(String invoice) async =>
      numValue((await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single, 'paid');

  Future<String> sellUnpaid({double qty = 2}) => SaleRepository.instance.saveSale(
        lines: [saleLine(qty: qty)],
        customerName: 'Ali',
        discountInput: 0,
        paidInput: 0,
        saleType: 'retail',
        saleDateMillis: now,
      );

  Future<Payment> onlyPayment() async => Payment.fromMap((await db.query('payments')).single);

  test('expense: one row and one cash OUT of the same amount; delete removes both', () async {
    await ExpenseRepository.instance.save(amount: 250, category: 'Fuel Expense', method: 'cash');
    expect((await db.query('expenses')).length, 1);
    expect(numValue((await db.query('expenses')).single, 'amount'), 250);
    expect(await cashOut(), 250);

    final expense = (await ExpenseRepository.instance.recent()).single;
    await ExpenseRepository.instance.delete(expense);
    expect(await db.query('expenses'), isEmpty);
    expect(await cashOut(), 0, reason: 'Cash in Hand must not stay understated after deleting the expense');
  });

  test('expense: zero, negative and unknown-method entries are refused and write nothing', () async {
    await expectLater(ExpenseRepository.instance.save(amount: 0, category: 'Fines', method: 'cash'), throwsA(isA<ArgumentError>()));
    await expectLater(ExpenseRepository.instance.save(amount: -5, category: 'Fines', method: 'cash'), throwsA(isA<ArgumentError>()));
    await expectLater(ExpenseRepository.instance.save(amount: 5, category: 'Fines', method: 'card'), throwsA(isA<ArgumentError>()));
    expect(await db.query('expenses'), isEmpty);
    expect(await cashOut(), 0);
  });

  test('opening balance: sale adds to it, sale edit and sale delete keep it exactly once', () async {
    final customerId = await addCustomer('Ali', openingBalance: 500);
    await addProduct(stock: 10);
    expect(await balanceOf('customers', customerId), 500);

    final invoice = await sellToAli(qty: 2, paid: 100); // bill 200, paid 100 -> +100
    expect(await balanceOf('customers', customerId), 600);

    final edited = await SaleRepository.instance.saveSale(
      lines: [saleLine(qty: 5)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 100,
      saleType: 'retail',
      saleDateMillis: now,
      editInvoice: invoice,
    ); // bill 500, paid 100 -> +400
    expect(await balanceOf('customers', customerId), 900, reason: 'opening 500 + new due 400, opening not doubled or lost');

    await SaleRepository.instance.deleteSale(edited);
    expect(await balanceOf('customers', customerId), 500, reason: 'back to the opening balance only');
    expect(numValue((await db.query('customers')).single, 'openingBalance'), 500);
  });

  test('opening balance: a payment reduces it and delete of the payment restores it', () async {
    final customerId = await addCustomer('Ali', openingBalance: 500);
    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 200,
      method: 'cash',
      note: '',
      dateMillis: now,
    );
    expect(await balanceOf('customers', customerId), 300);
    expect(await cashIn(), 200);

    await PaymentRepository.instance.delete(payment: await onlyPayment(), isCustomer: true);
    expect(await balanceOf('customers', customerId), 500);
    expect(await cashIn(), 0);
  });

  test('payment re-assigned from bill A to bill B: A.paid back, B.paid up, party balance and cash unchanged', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final a = await sellUnpaid(qty: 2); // 200
    final b = await sellUnpaid(qty: 2); // 200
    expect(await balanceOf('customers', customerId), 400);

    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 100,
      method: 'cash',
      note: '',
      dateMillis: now,
      billRef: a,
    );
    expect(await balanceOf('customers', customerId), 300);
    expect(await billPaid(a), 100);

    await PaymentRepository.instance.update(
      original: await onlyPayment(),
      isCustomer: true,
      partyName: 'Ali',
      newAmount: 100,
      newMethod: 'cash',
      newNote: '',
      newDateMillis: now,
      newBillRef: b,
    );
    expect(await billPaid(a), 0);
    expect(await billPaid(b), 100);
    expect(await balanceOf('customers', customerId), 300, reason: 'moving a payment between bills must not change what Ali owes');
    expect(await cashIn(), 100, reason: 'cash book must not record the money twice');
  });

  test('payment bigger than the target bill can take is refused and changes nothing', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final a = await sellUnpaid(qty: 2);
    final b = await sellUnpaid(qty: 2);
    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 100,
      method: 'cash',
      note: '',
      dateMillis: now,
      billRef: a,
    );

    await expectLater(
      PaymentRepository.instance.update(
        original: await onlyPayment(),
        isCustomer: true,
        partyName: 'Ali',
        newAmount: 250, // bill B is only 200
        newMethod: 'cash',
        newNote: '',
        newDateMillis: now,
        newBillRef: b,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await billPaid(a), 100);
    expect(await billPaid(b), 0);
    expect(await balanceOf('customers', customerId), 300);
    expect(await cashIn(), 100);
  });

  test('deleting a bill-linked payment gives back both the bill and the party balance', () async {
    final customerId = await addCustomer('Ali');
    await addProduct(stock: 10);
    final a = await sellUnpaid(qty: 2);
    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 150,
      method: 'cash',
      note: '',
      dateMillis: now,
      billRef: a,
    );
    expect(await billPaid(a), 150);
    expect(await balanceOf('customers', customerId), 50);

    await PaymentRepository.instance.delete(payment: await onlyPayment(), isCustomer: true);
    expect(await billPaid(a), 0);
    expect(await balanceOf('customers', customerId), 200);
    expect(await cashIn(), 0);
  });
}
