import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/sale_repository.dart';
import 'package:ah_developer_kiryana_store/db/stock_ledger.dart';
import 'package:ah_developer_kiryana_store/models/product.dart';
import 'package:ah_developer_kiryana_store/services/credit_guard.dart';
import 'package:ah_developer_kiryana_store/services/session.dart';

/// Server-side (cross-device) credit pre-check: the sale flow must
///  * stop BEFORE anything is written when the server says "blocked",
///  * keep working on the local check when the server is unreachable (fail-open),
///  * not call the server for cash bills or when the cashier already confirmed "Save Anyway".
class _FakeGuard extends CreditGuard {
  _FakeGuard(this.result) : super();
  final CreditCheckResult result;
  final calls = <Map<String, Object?>>[];

  @override
  Future<CreditCheckResult> reserve({
    required String customerId,
    required double amount,
    required String reservationId,
  }) async {
    calls.add({'customerId': customerId, 'amount': amount, 'reservationId': reservationId});
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('ah_credit_guard_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'credit-guard-admin';
    Session.role = 'admin';
    await db.insert('customers', {
      'name': 'Ali',
      'phone': '',
      'creditLimit': 1000.0, // local check would allow a Rs 200 bill
      'openingBalance': 0.0,
      'balance': 0.0,
      'stuckBalance': 0.0,
      'updatedAt': now,
      'dirty': 1,
    });
    final product = Product(
        barcode: 'rice', name: 'Rice', category: 'General', unit: 'pcs', cost: 50, salePrice: 100, stock: 10, openingStock: 10);
    await db.insert('products', product.toMap());
    await StockLedger.logOpeningStock(db, 'rice', 10, unitCost: 50, now: now);
  });

  tearDown(() async {
    CreditGuard.instance = const CreditGuard();
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  SaleLine line(double qty, double rate) => SaleLine(
      itemName: 'Rice', barcode: 'rice', qty: qty, unit: 'pcs', unitPrice: rate, cost: qty * 50, amount: qty * rate);

  Future<String> creditSale({bool override = false, double paid = 0}) => SaleRepository.instance.saveSale(
        lines: [line(2, 100)],
        customerName: 'Ali',
        discountInput: 0,
        paidInput: paid,
        saleType: 'retail',
        saleDateMillis: now,
        overrideCreditLimit: override,
      );

  test('server says blocked => SaleCreditLimitException with the server numbers, nothing written', () async {
    final fake = _FakeGuard(const CreditCheckResult(CreditCheckStatus.blocked, creditLimit: 1000, projected: 1150));
    CreditGuard.instance = fake;

    await expectLater(
      creditSale(),
      throwsA(isA<SaleCreditLimitException>()
          .having((e) => e.creditLimit, 'creditLimit', 1000)
          .having((e) => e.projectedBalance, 'projected', 1150)),
    );

    expect(fake.calls, hasLength(1));
    expect(fake.calls.single['amount'], 200.0);
    expect((fake.calls.single['reservationId'] as String).startsWith('sale:'), isTrue);
    expect(await db.query('sales'), isEmpty);
    expect((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single['stock'], 10);
  });

  test('server unreachable (unavailable) => sale still saves on the local check', () async {
    final fake = _FakeGuard(CreditCheckResult.unavailable);
    CreditGuard.instance = fake;

    final invoice = await creditSale();

    expect(invoice, isNotEmpty);
    expect(fake.calls, hasLength(1));
    expect(await db.query('sales'), hasLength(1));
  });

  test('cash bill (no due) never calls the server', () async {
    final fake = _FakeGuard(const CreditCheckResult(CreditCheckStatus.blocked, creditLimit: 1, projected: 999));
    CreditGuard.instance = fake;

    await creditSale(paid: 200);

    expect(fake.calls, isEmpty);
    expect(await db.query('sales'), hasLength(1));
  });

  test('"Save Anyway" (override) skips the server check', () async {
    final fake = _FakeGuard(const CreditCheckResult(CreditCheckStatus.blocked, creditLimit: 1, projected: 999));
    CreditGuard.instance = fake;

    await creditSale(override: true);

    expect(fake.calls, isEmpty);
    expect(await db.query('sales'), hasLength(1));
  });

  test('quick sale on credit: server blocked => exception before stock changes', () async {
    final fake = _FakeGuard(const CreditCheckResult(CreditCheckStatus.blocked, creditLimit: 1000, projected: 1200));
    CreditGuard.instance = fake;
    final product = Product.fromMap((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single);

    await expectLater(
      SaleRepository.instance.saveQuickSale(product: product, qty: 2, price: 100, unit: 'pcs', customerName: 'Ali'),
      throwsA(isA<SaleCreditLimitException>()),
    );

    expect(fake.calls.single['amount'], 200.0);
    expect((await db.query('products', where: 'barcode=?', whereArgs: ['rice'])).single['stock'], 10);
  });

  test('guard is OFF by default (no calls, no cloud access)', () async {
    expect(await const CreditGuard().isEnabled(), isFalse);
    final r = await const CreditGuard().reserve(customerId: 'c1', amount: 10, reservationId: 'r1');
    expect(r.status, CreditCheckStatus.unavailable);
  });
}
