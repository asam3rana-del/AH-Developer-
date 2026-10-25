import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/party_transaction_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/sale.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Returned sale: stock + customer due returnSale() mein pehle hi ulta ho chuka hota hai.
/// Delete / item edit / item delete se wohi asar dobara nahi lagna chahiye.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_returned_guard_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'admin-test';
    Session.role = 'admin';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  Future<double> stockOf() async =>
      ((await db.query('products', where: 'barcode = ?', whereArgs: ['rice'])).first['stock'] as num).toDouble();
  Future<double> balanceOf(int id) async =>
      ((await db.query('customers', where: 'id = ?', whereArgs: [id])).first['balance'] as num).toDouble();

  /// 10 stock, ek credit sale (2 x 100, paid 50 => due 150) phir return.
  Future<(int, String)> returnedSale() async {
    final customerId = await db.insert('customers', {
      'name': 'Ali',
      'phone': '',
      'creditLimit': 0.0,
      'openingBalance': 0.0,
      'balance': 0.0,
      'stuckBalance': 0.0,
      'updatedAt': now,
      'dirty': 1,
    });
    await db.insert(
        'products',
        const Product(barcode: 'rice', name: 'Rice', category: 'General', unit: 'pcs', cost: 50, salePrice: 100, stock: 10, openingStock: 10)
            .toMap());
    await StockLedger.logOpeningStock(db, 'rice', 10, unitCost: 50, now: now);
    final invoice = await SaleRepository.instance.saveSale(
      lines: [SaleLine(itemName: 'Rice', barcode: 'rice', qty: 2, unit: 'pcs', unitPrice: 100, cost: 50, amount: 200)],
      customerName: 'Ali',
      discountInput: 50,
      paidInput: 0,
      saleType: 'retail',
      saleDateMillis: now,
    );
    await SaleRepository.instance.returnSale(invoice);
    return (customerId, invoice);
  }

  test('returned sale delete: stock aur customer balance dobara nahi badalte', () async {
    final (customerId, invoice) = await returnedSale();
    expect(await stockOf(), 10); // return ke baad poora stock wapas
    expect(await balanceOf(customerId), 0); // return ke baad due ulta

    await SaleRepository.instance.deleteSale(invoice);

    expect(await stockOf(), 10, reason: 'stock do baar wapas nahi aana chahiye');
    expect(await balanceOf(customerId), 0, reason: 'balance do baar ulta nahi hona chahiye');
    expect(await db.query('sales', where: 'invoice = ?', whereArgs: [invoice]), isEmpty);
    expect(await db.query('cash_transactions', where: 'reference IN (?, ?)', whereArgs: [invoice, 'return:$invoice']), isEmpty);
  });

  test('returned sale ka item edit / delete repository par rok diya jata hai', () async {
    final (_, invoice) = await returnedSale();
    final item = (await PartyTransactionRepository.instance.saleItems(invoice)).first;

    await expectLater(
        PartyTransactionRepository.instance.editSaleItem(item: item, newQty: 1, newRate: 100), throwsA(isA<StateError>()));
    await expectLater(PartyTransactionRepository.instance.deleteSaleItem(item), throwsA(isA<StateError>()));
    expect(await stockOf(), 10);
  });
}
