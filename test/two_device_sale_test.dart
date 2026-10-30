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
import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';

/// Do devices par ek saath sale (audit 2026-10-30): invoice par device tag hone se ek device ka bill
/// doosre ke bill ko sync par overwrite nahi karta.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Database db;
  final now = DateTime(2026, 10, 30).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DeviceTag.prefsKey, 'AAAA'); // yeh device = A
    await DeviceTag.init();
    tempDir = await Directory.systemTemp.createTemp('ah_two_device_sale_');
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(tempDir.path);
    db = await AppDatabase.instance.database;
    Session.username = 'two-device-test';
    Session.role = 'admin';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    Session.username = null;
    Session.role = 'cashier';
    await tempDir.delete(recursive: true);
  });

  test('same millisecond on two devices gives two different invoice numbers', () {
    const sameMs = 1793342880123; // dono devices par bilkul ek hi lamha
    final a = SaleRepository.instance.nextInvoiceNumber(now, nowMillis: sameMs, deviceTag: 'AAAA');
    final b = SaleRepository.instance.nextInvoiceNumber(now, nowMillis: sameMs, deviceTag: 'BBBB');
    expect(a.split('-').first, b.split('-').first); // 12-digit hissa ek jaisa (purana collision)
    expect(a, isNot(b));
    expect(a, endsWith('-AAAA'));
    expect(b, endsWith('-BBBB'));
  });

  test('quick sale on device A + same-moment sale arriving from device B: both bills stay', () async {
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

    // Device A: apni quick sale.
    final local = await SaleRepository.instance
        .saveQuickSale(product: product, qty: 1, price: 250, unit: 'pcs', customerName: '');
    expect(local.invoice, endsWith('-AAAA'));

    // Device B ka bill usi 12-digit hisse ke saath (purane format mein yahi takkar thi), apne tag ke saath.
    final remoteInvoice = '${local.invoice.split('-').first}-BBBB';
    await applySales(
      db,
      [
        {
          'invoice': remoteInvoice,
          'total': 140,
          'paid': 140,
          'subtotal': 140,
          'discount': 0,
          'paymentMethod': 'cash',
          'saleType': 'retail',
          'createdAt': now,
          'status': 'active',
          'updatedAt': now,
          'items': [
            {'barcode': 'rice', 'product': 'Rice', 'qty': 1, 'unit': 'pcs', 'unitPrice': 140, 'cost': 50, 'amount': 140},
          ],
        }
      ],
      nowMs: () => now,
    );

    final sales = await db.query('sales', orderBy: 'total DESC');
    expect(sales.length, 2);
    expect(sales.map((r) => (r['total'] as num).toDouble()), [250.0, 140.0]);
    expect(sales.map((r) => r['invoice']), [local.invoice, remoteInvoice]);
    // A ke bill ki items ko B ke pull ne chheda nahi.
    final localItems = await db.query('sale_items', where: 'invoice=?', whereArgs: [local.invoice]);
    expect(localItems.length, 1);
    expect((localItems.single['amount'] as num).toDouble(), 250);
  });
}
