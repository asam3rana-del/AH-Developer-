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
import 'package:ah_developer_kiryana_store/sync/device_tag.dart';

/// Audit (2026-10-30) fixes: invoice number mein device tag, aur Quick Sale total poore rupee par.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DeviceTag.init();
    tempDir = await Directory.systemTemp.createTemp('ah_invoice_quick_round_');
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

  test('invoice number ends with this device tag and keeps the MMyy prefix', () {
    final invoice = SaleRepository.instance.nextInvoiceNumber(now);
    expect(invoice, matches(RegExp(r'^1026\d{8}-[0-9A-Z]{4}$')));
    expect(invoice.endsWith('-${DeviceTag.current}'), isTrue);
  });

  test('quick sale total is rounded to the whole rupee and stock, paid and amount agree', () async {
    final product = Product(
      barcode: 'rice',
      name: 'Rice',
      category: 'General',
      unit: 'kg',
      cost: 50,
      salePrice: 99,
      stock: 10,
      openingStock: 10,
    );
    await db.insert('products', product.toMap());
    await StockLedger.logOpeningStock(db, 'rice', 10, unitCost: 50, now: now);

    final result = await SaleRepository.instance
        .saveQuickSale(product: product, qty: 2.5, price: 99, unit: 'kg', customerName: '');

    final sale = (await db.query('sales', where: 'invoice=?', whereArgs: [result.invoice])).single;
    expect((sale['total'] as num).toDouble(), 248); // 2.5 x 99 = 247.5 -> 248
    expect((sale['paid'] as num).toDouble(), 248);
    final item = (await db.query('sale_items', where: 'invoice=?', whereArgs: [result.invoice])).single;
    expect((item['amount'] as num).toDouble(), 248);
    expect((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single['stock'], 7.5);
  });
}
