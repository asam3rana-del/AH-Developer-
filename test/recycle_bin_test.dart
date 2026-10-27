import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/expense_repository.dart';
import 'package:ah_developer_kiryana_store/db/party_repository.dart';
import 'package:ah_developer_kiryana_store/db/payment_repository.dart';
import 'package:ah_developer_kiryana_store/db/product_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_history_repository.dart';
import 'package:ah_developer_kiryana_store/db/purchase_repository.dart';
import 'package:ah_developer_kiryana_store/db/recycle_bin_repository.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/db/worker_repository.dart';
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/models/sale.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Recycle Bin: delete par snapshot, restore par stock / balance / cash wapas, sync mein `_restore` upsert.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;
  final bin = RecycleBinRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_recycle_bin_');
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

  Future<double> stockOf(String barcode) async =>
      ((await db.query('products', where: 'barcode = ?', whereArgs: [barcode])).first['stock'] as num).toDouble();
  Future<double> balanceOf(int id) async =>
      ((await db.query('customers', where: 'id = ?', whereArgs: [id])).first['balance'] as num).toDouble();
  Future<int> countOf(String table) async => (await db.query(table)).length;

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

  Future<void> addRice({double stock = 10}) async {
    await db.insert(
        'products',
        Product(barcode: 'rice', name: 'Rice', category: 'General', unit: 'pcs', cost: 50, salePrice: 100, stock: stock, openingStock: stock)
            .toMap());
    await StockLedger.logOpeningStock(db, 'rice', stock, unitCost: 50, now: now);
  }

  Future<String> creditSale() => SaleRepository.instance.saveSale(
        lines: [SaleLine(itemName: 'Rice', barcode: 'rice', qty: 2, unit: 'pcs', unitPrice: 100, cost: 50, amount: 200)],
        customerName: 'Ali',
        discountInput: 50,
        paidInput: 0,
        saleType: 'retail',
        saleDateMillis: now,
      );

  Future<bool> restoreFlagged(String entityType) async {
    final rows = await db.query('sync_queue', where: "entityType = ? AND operation = 'upsert'", whereArgs: [entityType]);
    return rows.any((r) => (jsonDecode(r['payloadJson'] as String) as Map)['_restore'] == true);
  }

  group('snapshot encode/decode', () {
    test('round trip', () {
      final rows = <String, List<Map<String, Object?>>>{
        'sales': [
          {'invoice': 'A1', 'total': 200.5, 'customerId': null}
        ],
        'sale_items': [
          {'id': 1, 'qty': 2.0},
          {'id': 2, 'qty': 3.0},
        ],
      };
      final back = decodeBinRows(encodeBinRows(rows));
      expect(back['sales']!.single['invoice'], 'A1');
      expect(back['sales']!.single['total'], 200.5);
      expect(back['sales']!.single['customerId'], isNull);
      expect(back['sale_items']!.length, 2);
    });

    test('kharab ya khali text par khali map', () {
      expect(decodeBinRows(''), isEmpty);
      expect(decodeBinRows('not json'), isEmpty);
      expect(decodeBinRows('[1,2]'), isEmpty);
      expect(decodeBinRows(jsonEncode({'x': 5})), isEmpty);
    });
  });

  group('delete -> bin -> restore', () {
    test('sale: stock, customer balance aur bill wapas', () async {
      final customerId = await addCustomer('Ali');
      await addRice();
      final invoice = await creditSale();
      final stockAfterSale = await stockOf('rice');
      final balanceAfterSale = await balanceOf(customerId);
      expect(stockAfterSale, 8);
      expect(balanceAfterSale, greaterThan(0));

      await SaleRepository.instance.deleteSale(invoice);
      expect(await stockOf('rice'), 10);
      expect(await balanceOf(customerId), 0);
      expect(await db.query('sales', where: 'invoice = ?', whereArgs: [invoice]), isEmpty);
      final entries = await bin.list();
      expect(entries.length, 1);
      expect(entries.single.kind, RecycleBinRepository.kindSale);
      expect(entries.single.title, contains(invoice));

      await bin.restore(entries.single.id);
      expect(await stockOf('rice'), stockAfterSale);
      expect(await balanceOf(customerId), balanceAfterSale);
      expect(await db.query('sales', where: 'invoice = ?', whereArgs: [invoice]), hasLength(1));
      expect(await db.query('sale_items', where: 'invoice = ?', whereArgs: [invoice]), hasLength(1));
      expect(await bin.list(), isEmpty);
      expect(await restoreFlagged('sale'), isTrue);
      // delete ka pending tombstone hat gaya (restore ke baad cloud par delete nahi jana chahiye).
      expect(await db.query('sync_queue', where: "entityType = 'sale' AND operation = 'delete' AND syncedAt IS NULL"), isEmpty);
    });

    test('sale: stock kam ho to restore rukta hai aur kuch nahi badalta', () async {
      await addCustomer('Ali');
      await addRice();
      final invoice = await creditSale();
      await SaleRepository.instance.deleteSale(invoice);
      await db.update('products', {'stock': 1.0}, where: 'barcode = ?', whereArgs: ['rice']); // bik gaya

      final id = (await bin.list()).single.id;
      await expectLater(bin.restore(id), throwsA(isA<RecycleBinException>()));
      expect(await stockOf('rice'), 1);
      expect(await db.query('sales', where: 'invoice = ?', whereArgs: [invoice]), isEmpty);
      expect(await bin.list(), hasLength(1), reason: 'restore fail => entry bin mein hi rahe');
    });

    test('sirf admin restore / purge kar sakta hai', () async {
      await addCustomer('Ali');
      await addRice();
      final invoice = await creditSale();
      await SaleRepository.instance.deleteSale(invoice);
      final id = (await bin.list()).single.id;

      Session.role = 'cashier';
      await expectLater(bin.restore(id), throwsA(isA<StateError>()));
      await expectLater(bin.purge(id), throwsA(isA<StateError>()));
      Session.role = 'admin';
      expect(await bin.list(), hasLength(1));
      await bin.purge(id);
      expect(await bin.list(), isEmpty);
    });

    test('purchase: stock, supplier balance aur bill wapas', () async {
      await addRice();
      final billNo = await PurchaseRepository.instance.savePurchase(
        supplierName: 'Sup',
        lines: [
          const PurchaseLine(
              itemName: 'Rice', barcode: 'rice', qty: 5, unit: 'pcs', rate: 40, amount: 200,
              retailRate: 100, wholesaleRate: 90, shopkeeperRate: 95),
        ],
        amountPaid: 0,
        purchaseDateMillis: now,
      );
      Future<double> supplierBalance() async =>
          ((await db.query('suppliers')).single['balance'] as num).toDouble();
      expect(await stockOf('rice'), 15);
      final balanceAfter = await supplierBalance();
      expect(balanceAfter, greaterThan(0));

      await PurchaseHistoryRepository.instance.deletePurchase(billNo);
      expect(await stockOf('rice'), 10);
      expect(await supplierBalance(), 0);
      expect(await db.query('purchases', where: 'billNo = ?', whereArgs: [billNo]), isEmpty);
      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindPurchase);
      expect(entries.single.title, contains(billNo));

      await bin.restore(entries.single.id);
      expect(await stockOf('rice'), 15);
      expect(await supplierBalance(), balanceAfter);
      expect(await db.query('purchases', where: 'billNo = ?', whereArgs: [billNo]), hasLength(1));
      expect(await db.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo]), hasLength(1));
      expect(await bin.list(), isEmpty);
      expect(await restoreFlagged('purchase'), isTrue);
    });

    test('expense: cash OUT row bhi wapas', () async {
      await ExpenseRepository.instance.save(amount: 120, category: 'Tea', method: 'cash');
      final cashBefore = await countOf('cash_transactions');
      expect(cashBefore, greaterThan(0));
      final expense = Expense.fromMap((await db.query('expenses')).single);

      await ExpenseRepository.instance.delete(expense);
      expect(await countOf('expenses'), 0);
      expect(await countOf('cash_transactions'), 0);
      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindExpense);

      await bin.restore(entries.single.id);
      expect(await countOf('expenses'), 1);
      expect(await countOf('cash_transactions'), cashBefore);
      expect(await restoreFlagged('expense'), isTrue);
    });

    test('payment: party balance aur cash wapas', () async {
      final customerId = await addCustomer('Ali');
      await db.update('customers', {'balance': 500.0}, where: 'id = ?', whereArgs: [customerId]);
      await PaymentRepository.instance.save(
          isCustomer: true, partyId: customerId, partyName: 'Ali', amount: 200, method: 'cash', note: '', dateMillis: now);
      final balanceAfterPay = await balanceOf(customerId);
      expect(balanceAfterPay, 300);
      final cashBefore = await countOf('cash_transactions');
      final payment = Payment.fromMap((await db.query('payments')).single);

      await PaymentRepository.instance.delete(payment: payment, isCustomer: true);
      expect(await balanceOf(customerId), 500);
      expect(await countOf('payments'), 0);

      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindPayment);
      await bin.restore(entries.single.id);
      expect(await balanceOf(customerId), balanceAfterPay);
      expect(await countOf('payments'), 1);
      expect(await countOf('cash_transactions'), cashBefore);
    });

    test('customer: purani id ke saath wapas', () async {
      final customerId = await addCustomer('Ali');
      final customer = Customer.fromMap((await db.query('customers')).single);
      await PartyRepository.instance.deleteCustomer(customer);
      expect(await countOf('customers'), 0);

      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindCustomer);
      expect(entries.single.title, 'Ali');
      await bin.restore(entries.single.id);
      final back = await db.query('customers');
      expect(back.single['id'], customerId);
      expect(back.single['name'], 'Ali');
      expect(await restoreFlagged('customer'), isTrue);
    });

    test('item (product): row aur stock wapas, cloud stock set_stock se', () async {
      await addRice(stock: 7);
      final product = Product.fromMap((await db.query('products')).single);
      await ProductRepository.instance.delete(product);
      expect(await countOf('products'), 0);

      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindProduct);
      await bin.restore(entries.single.id);
      expect(await stockOf('rice'), 7);
      expect(await restoreFlagged('product'), isTrue);
      final setStock = await db.query('sync_queue', where: "entityType = 'product' AND operation = 'set_stock'");
      expect(setStock, isNotEmpty);
    });

    test('worker: hazri samet wapas', () async {
      final workerId = await db.insert('workers', {
        'name': 'Bilal',
        'phone': '',
        'payType': 'monthly',
        'rate': 30000.0,
        'active': 1,
        'createdAt': now,
        'updatedAt': now,
      });
      await db.insert('worker_attendance', {'workerId': workerId, 'day': '2026-10-01', 'status': 'P', 'updatedAt': now});

      await WorkerRepository.instance.deleteWorker(workerId);
      expect(await countOf('workers'), 0);
      expect(await countOf('worker_attendance'), 0);

      final entries = await bin.list();
      expect(entries.single.kind, RecycleBinRepository.kindWorker);
      await bin.restore(entries.single.id);
      expect((await db.query('workers')).single['id'], workerId);
      expect(await countOf('worker_attendance'), 1);
      expect(await restoreFlagged('worker'), isTrue);
    });

    test('restore dobara: wahi record pehle se ho to saaf paigham', () async {
      final customerId = await addCustomer('Ali');
      final customer = Customer.fromMap((await db.query('customers')).single);
      await PartyRepository.instance.deleteCustomer(customer);
      // Wahi id wala record kisi tarah wapas aa gaya.
      await db.insert('customers', {
        'id': customerId,
        'name': 'Ali',
        'phone': '',
        'creditLimit': 0.0,
        'openingBalance': 0.0,
        'balance': 0.0,
        'stuckBalance': 0.0,
        'updatedAt': now,
        'dirty': 1,
      });
      final id = (await bin.list()).single.id;
      await expectLater(bin.restore(id), throwsA(isA<RecycleBinException>()));
      expect(await bin.list(), hasLength(1));
    });
  });
}
