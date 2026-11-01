import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/credit_override_policy.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// "Only admin/manager can Save Anyway": default OFF = nothing changes; ON = a cashier cannot override.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  Future<void> setUpDb({required bool managersOnly}) async {
    SharedPreferences.setMockInitialValues({CreditOverridePolicy.prefKey: managersOnly});
    tempDir = await Directory.systemTemp.createTemp('ah_credit_override_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    await db.insert('customers', {
      'name': 'Ali', 'phone': '', 'creditLimit': 100.0, 'openingBalance': 0.0, 'balance': 0.0,
      'stuckBalance': 0.0, 'updatedAt': now, 'dirty': 1,
    });
    final product = Product(
        barcode: 'rice', name: 'Rice', category: 'General', unit: 'pcs', cost: 50, salePrice: 100, stock: 10, openingStock: 10);
    await db.insert('products', product.toMap());
    await StockLedger.logOpeningStock(db, 'rice', 10, unitCost: 50, now: now);
  }

  tearDown(() async {
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  Future<String> overLimitSale({required bool override}) => SaleRepository.instance.saveSale(
        lines: [
          SaleLine(itemName: 'Rice', barcode: 'rice', qty: 2, unit: 'pcs', unitPrice: 100, cost: 100, amount: 200),
        ],
        customerName: 'Ali',
        discountInput: 0,
        paidInput: 0,
        saleType: 'retail',
        saleDateMillis: now,
        overrideCreditLimit: override,
      );

  test('default (OFF): cashier can still Save Anyway - behaviour unchanged', () async {
    await setUpDb(managersOnly: false);
    Session.username = 'c1';
    Session.role = 'cashier';
    expect(await CreditOverridePolicy.currentUserMayOverride(), isTrue);
    expect(await overLimitSale(override: true), isNotEmpty);
    expect(await db.query('sales'), hasLength(1));
  });

  test('ON: cashier override is refused and nothing is written', () async {
    await setUpDb(managersOnly: true);
    Session.username = 'c1';
    Session.role = 'cashier';
    expect(await CreditOverridePolicy.currentUserMayOverride(), isFalse);
    await expectLater(overLimitSale(override: true), throwsA(isA<ArgumentError>()));
    expect(await db.query('sales'), isEmpty);
  });

  test('ON: without override the normal credit-limit exception still fires for a cashier', () async {
    await setUpDb(managersOnly: true);
    Session.username = 'c1';
    Session.role = 'cashier';
    await expectLater(overLimitSale(override: false), throwsA(isA<SaleCreditLimitException>()));
  });

  for (final role in ['manager', 'admin']) {
    test('ON: $role may still Save Anyway', () async {
      await setUpDb(managersOnly: true);
      Session.username = 'u-$role';
      Session.role = role;
      expect(await CreditOverridePolicy.currentUserMayOverride(), isTrue);
      expect(await overLimitSale(override: true), isNotEmpty);
      expect(await db.query('sales'), hasLength(1));
    });
  }
}
