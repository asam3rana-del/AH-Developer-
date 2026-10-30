import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/reports_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Audit (2026-10-30) fixes:
///  * bill-linked payment se kam total par edit rok diya jata hai (paise chupke se gayab na hon)
///  * sale return ka amount bill total (discount / rounding ke baad) ke barabar
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
    tempDir = await Directory.systemTemp.createTemp('ah_sale_edit_return_audit_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'audit-test-admin';
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

  Future<void> addProduct() async {
    final product = Product(
      barcode: 'rice',
      name: 'Rice',
      category: 'General',
      unit: 'pcs',
      cost: 50,
      salePrice: 100,
      stock: 10,
      openingStock: 10,
    );
    await db.insert('products', product.toMap());
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

  double num_(Map<String, Object?> row, String key) => (row[key] as num).toDouble();

  test('edit below the amount already received through linked payments is refused, nothing changes', () async {
    final customerId = await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(2, 100)],
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 0,
      saleType: 'retail',
      saleDateMillis: now,
    );
    await PaymentRepository.instance.save(
      isCustomer: true,
      partyId: customerId,
      partyName: 'Ali',
      amount: 150,
      method: 'Cash',
      note: '',
      dateMillis: now + 1,
      billRef: invoice,
    );

    await expectLater(
      SaleRepository.instance.saveSale(
        lines: [line(1, 100)], // total 100 < 150 pehle hi mil chuke
        customerName: 'Ali',
        discountInput: 0,
        paidInput: 150,
        saleType: 'retail',
        saleDateMillis: now,
        editInvoice: invoice,
      ),
      throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains('linked payment'))),
    );

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(num_(sale, 'total'), 200);
    expect(num_(sale, 'paid'), 150);
    expect(num_((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 50);
    expect(num_((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single, 'stock'), 8);

    // Total linked payment se kam na ho to edit chalta hai.
    await SaleRepository.instance.saveSale(
      lines: [line(1, 150)], // total 150 == mil chuke
      customerName: 'Ali',
      discountInput: 0,
      paidInput: 150,
      saleType: 'retail',
      saleDateMillis: now,
      editInvoice: invoice,
    );
    final edited = (await db.query('sales', where: 'invoice=?', whereArgs: [invoice])).single;
    expect(num_(edited, 'total'), 150);
    expect(num_(edited, 'paid'), 150);
    expect(num_((await db.query('customers', where: 'id=?', whereArgs: [customerId])).single, 'balance'), 0);
  });

  test('sale return amount equals the bill total after discount, across several lines', () async {
    await addCustomer('Ali');
    await addProduct();
    final invoice = await SaleRepository.instance.saveSale(
      lines: [line(1, 33), line(1, 34)], // subtotal 67
      customerName: 'Ali',
      discountInput: 10, // total 57
      paidInput: 0,
      saleType: 'retail',
      saleDateMillis: now,
    );

    await SaleRepository.instance.returnSale(invoice);

    final returns = await db.query('returns', where: 'reference=?', whereArgs: [invoice]);
    expect(returns.length, 2);
    final sum = returns.fold<double>(0, (t, r) => t + num_(r, 'amount'));
    expect(sum, closeTo(57, 0.001));
    final report = await ReportsRepository.instance.load(allTime);
    expect(report.saleReturns, closeTo(57, 0.001));
  });
}
