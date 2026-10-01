import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/sync/sync_apply.dart';
import 'package:ah_developer_kiryana_store/sync/sync_pull_plan.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_dao.dart';
import 'package:ah_developer_kiryana_store/sync/sync_types.dart';

/// Phase 10: applyServerChanges HISSA 2 — sales, purchases, expenses, payments, cash_transactions, units,
/// categories, zakat, returns, stock_movements, shell, app_settings, cash_register.
Future<String> _fakeHash(String p) async => 'hash($p)';

const _sync = 'updatedAt INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1';

Future<Database> _memDb() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  Future<void> x(String sql) => db.execute(sql);
  await x('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', creditLimit REAL NOT NULL DEFAULT 0, openingBalance REAL NOT NULL DEFAULT 0,
    balance REAL NOT NULL DEFAULT 0, stuckBalance REAL NOT NULL DEFAULT 0, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE suppliers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', openingBalance REAL NOT NULL DEFAULT 0, balance REAL NOT NULL DEFAULT 0,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE products (barcode TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0, salePrice REAL NOT NULL DEFAULT 0,
    stock REAL NOT NULL DEFAULT 0, reorderLevel REAL NOT NULL DEFAULT 0, expiry TEXT NOT NULL DEFAULT '',
    unit TEXT NOT NULL DEFAULT 'pcs', unitSize INTEGER NOT NULL DEFAULT 1, unitNote TEXT NOT NULL DEFAULT '',
    secondaryUnit TEXT NOT NULL DEFAULT '', secondaryUnitQty REAL NOT NULL DEFAULT 0,
    wholesalePrice REAL NOT NULL DEFAULT 0, openingStock REAL NOT NULL DEFAULT 0,
    tertiaryUnit TEXT NOT NULL DEFAULT '', tertiaryUnitQty REAL NOT NULL DEFAULT 0,
    $_sync, searchTag TEXT NOT NULL DEFAULT '',
    defaultUnitIndex INTEGER NOT NULL DEFAULT -1, quickSaleDefaultUnitIndex INTEGER NOT NULL DEFAULT -1)''');
  await x('''CREATE TABLE users (username TEXT PRIMARY KEY NOT NULL, displayName TEXT NOT NULL,
    role TEXT NOT NULL, passwordHash TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
    phone TEXT NOT NULL DEFAULT '')''');
  await x('''CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL,
    action TEXT NOT NULL, reference TEXT NOT NULL DEFAULT '', details TEXT NOT NULL DEFAULT '',
    createdAt INTEGER NOT NULL)''');
  await x('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
    entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
    syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  await x('''CREATE TABLE sales (invoice TEXT PRIMARY KEY NOT NULL, customerId INTEGER, subtotal REAL NOT NULL,
    discount REAL NOT NULL, tax REAL NOT NULL, total REAL NOT NULL, paid REAL NOT NULL,
    paymentMethod TEXT NOT NULL, saleType TEXT NOT NULL DEFAULT 'retail', createdAt INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active', $_sync, dueDate INTEGER NOT NULL DEFAULT 0, customerServerId TEXT)''');
  await x('''CREATE TABLE sale_items (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice TEXT NOT NULL,
    barcode TEXT NOT NULL, product TEXT NOT NULL, qty REAL NOT NULL, unit TEXT NOT NULL DEFAULT '',
    unitPrice REAL NOT NULL, cost REAL NOT NULL, amount REAL NOT NULL, conversionFactor REAL NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE purchases (billNo TEXT PRIMARY KEY NOT NULL, supplierId INTEGER, total REAL NOT NULL,
    paid REAL NOT NULL, createdAt INTEGER NOT NULL, subtotal REAL NOT NULL DEFAULT 0,
    discount REAL NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'active', $_sync,
    dueDate INTEGER NOT NULL DEFAULT 0, supplierInvoiceNo TEXT NOT NULL DEFAULT '', supplierServerId TEXT)''');
  await x('''CREATE TABLE purchase_items (id INTEGER PRIMARY KEY AUTOINCREMENT, billNo TEXT NOT NULL,
    barcode TEXT NOT NULL, qty REAL NOT NULL, unitCost REAL NOT NULL, amount REAL NOT NULL,
    unit TEXT NOT NULL DEFAULT '', conversionFactor REAL NOT NULL DEFAULT 0, itemName TEXT NOT NULL DEFAULT '',
    retailRate REAL NOT NULL DEFAULT 0, wholesaleRate REAL NOT NULL DEFAULT 0)''');
  await x('''CREATE TABLE payments (id INTEGER PRIMARY KEY AUTOINCREMENT, reference TEXT NOT NULL,
    partyType TEXT NOT NULL, partyId INTEGER, amount REAL NOT NULL, method TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync,
    billReference TEXT NOT NULL DEFAULT '', partyServerId TEXT)''');
  await x('''CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL,
    description TEXT NOT NULL, amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash',
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE cash_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
    method TEXT NOT NULL, amount REAL NOT NULL, reason TEXT NOT NULL DEFAULT '',
    reference TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('CREATE TABLE units (name TEXT PRIMARY KEY NOT NULL)');
  await x('CREATE TABLE categories (name TEXT PRIMARY KEY NOT NULL)');
  await x('''CREATE TABLE returns (id INTEGER PRIMARY KEY AUTOINCREMENT, reference TEXT NOT NULL,
    type TEXT NOT NULL, barcode TEXT NOT NULL, qty REAL NOT NULL, amount REAL NOT NULL,
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE stock_movements (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT NOT NULL,
    type TEXT NOT NULL, qty REAL NOT NULL, unit TEXT NOT NULL DEFAULT '', cost REAL NOT NULL DEFAULT 0,
    reference TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE zakat_years (id INTEGER PRIMARY KEY AUTOINCREMENT, startDate INTEGER NOT NULL,
    endDate INTEGER NOT NULL, assetsSnapshot REAL NOT NULL, totalPayable REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'Rs', calendarType TEXT NOT NULL DEFAULT 'islamic',
    createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('''CREATE TABLE zakat_payments (id INTEGER PRIMARY KEY AUTOINCREMENT, zakatYearId INTEGER NOT NULL,
    amount REAL NOT NULL, method TEXT NOT NULL DEFAULT 'cash', note TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT '', paymentDate INTEGER NOT NULL, createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shell_customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    phone TEXT NOT NULL DEFAULT '', shellsOwed INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shell_transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, customerId INTEGER NOT NULL,
    type TEXT NOT NULL, qty INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL,
    serverId TEXT, $_sync)''');
  await x('''CREATE TABLE shop_empty_shell_log (id INTEGER PRIMARY KEY AUTOINCREMENT, delta INTEGER NOT NULL,
    reason TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, serverId TEXT, $_sync)''');
  await x('CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
  await x('''CREATE TABLE cash_register (date TEXT PRIMARY KEY NOT NULL, openingCash REAL NOT NULL DEFAULT 0,
    closingCash REAL NOT NULL DEFAULT 0, openingBank REAL NOT NULL DEFAULT 0,
    closingBank REAL NOT NULL DEFAULT 0, closed INTEGER NOT NULL DEFAULT 0)''');
  return db;
}

Future<void> _apply(Database db, PullResult r) =>
    applyServerChangesToDb(db, r, hashPassword: _fakeHash, nowMs: () => 5000);

Future<void> _queue(Database db, String type, String id, String op, {String payload = '{}'}) =>
    SyncQueueDao(db).enqueue(SyncQueueEntry(
        entityType: type, entityId: id, operation: op, payloadJson: payload, createdAt: 1));

void main() {
  sqfliteFfiInit();
  late Database db;
  setUp(() async => db = await _memDb());
  tearDown(() => db.close());

  group('sales', () {
    test('naya sale + items; customerServerId se local customer; dirty=0', () async {
      await db.insert('customers', {'name': 'Ali', 'serverId': 'c1'});
      await _apply(db, PullResult(sales: [
        {
          'invoice': 'S1', 'customerServerId': 'c1', 'subtotal': 100, 'discount': 10, 'total': 90, 'paid': 40,
          'paymentMethod': 'cash', 'createdAt': 777, 'updatedAt': 900, 'dueDate': 12345,
          'items': [
            {'barcode': 'b1', 'product': 'Soap', 'qty': 2, 'unit': 'pcs', 'unitPrice': 50, 'cost': 40, 'amount': 100,
             'conversionFactor': 1},
            {'product': 'no barcode'},
          ],
        },
        {'noInvoice': true},
      ]));
      final s = (await db.query('sales')).single;
      expect(s['customerId'], 1);
      expect(s['total'], 90.0);
      expect(s['tax'], 0.0);
      expect(s['createdAt'], 777);
      expect(s['updatedAt'], 900);
      expect(s['dirty'], 0);
      expect(s['dueDate'], 12345);
      final items = await db.query('sale_items');
      expect(items.length, 1);
      expect(items.single['product'], 'Soap');
      expect(items.single['conversionFactor'], 1.0);
    });

    test('dobara pull: items badal jate hain (duplicate nahi); items khali ho to purane barqarar', () async {
      final doc = {
        'invoice': 'S1', 'total': 10, 'paid': 10, 'items': [
          {'barcode': 'b1', 'qty': 1, 'unitPrice': 10, 'amount': 10},
        ],
      };
      await _apply(db, PullResult(sales: [doc]));
      await _apply(db, PullResult(sales: [
        {...doc, 'items': [
          {'barcode': 'b2', 'qty': 3, 'unitPrice': 5, 'amount': 15},
        ]}
      ]));
      expect((await db.query('sale_items')).map((r) => r['barcode']), ['b2']);
      await _apply(db, PullResult(sales: [{'invoice': 'S1', 'total': 20, 'paid': 20, 'items': []}]));
      expect((await db.query('sale_items')).map((r) => r['barcode']), ['b2']);
      expect((await db.query('sales')).single['total'], 20.0);
    });

    test('server doc mein dueDate na ho to local dueDate barqarar', () async {
      await db.insert('sales', {
        'invoice': 'S1', 'subtotal': 0.0, 'discount': 0.0, 'tax': 0.0, 'total': 5.0, 'paid': 0.0,
        'paymentMethod': 'cash', 'createdAt': 1, 'dueDate': 999,
      });
      await _apply(db, PullResult(sales: [{'invoice': 'S1', 'total': 6, 'paid': 0}]));
      expect((await db.query('sales')).single['dueDate'], 999);
    });

    test('pending local edit: pull skip + total/paid farq par sync_conflict audit', () async {
      await db.insert('sales', {
        'invoice': 'S1', 'subtotal': 0.0, 'discount': 0.0, 'tax': 0.0, 'total': 500.0, 'paid': 100.0,
        'paymentMethod': 'cash', 'createdAt': 1,
      });
      await _queue(db, 'sale', 'sale:S1', 'upsert');
      await _apply(db, PullResult(sales: [{'invoice': 'S1', 'total': 300, 'paid': 100}]));
      expect((await db.query('sales')).single['total'], 500.0);
      final a = await db.query('audit');
      expect(a.length, 1);
      expect(a.single['action'], 'sync_conflict');
      expect(a.single['reference'], 'sale:S1');
      expect(a.single['details'], contains('Rs 500.00'));
      expect(a.single['details'], contains('Rs 300.00'));
    });

    test('pending edit par same-value pull: skip lekin audit nahi', () async {
      await db.insert('sales', {
        'invoice': 'S1', 'subtotal': 0.0, 'discount': 0.0, 'tax': 0.0, 'total': 500.0, 'paid': 100.0,
        'paymentMethod': 'cash', 'createdAt': 1,
      });
      await _queue(db, 'sale', 'sale:S1', 'upsert');
      await _apply(db, PullResult(sales: [{'invoice': 'S1', 'total': 500, 'paid': 100}]));
      expect(await db.query('audit'), isEmpty);
    });

    test('tombstone: sale + items hatti hain; pending edit ho to bachti hai + audit', () async {
      for (final inv in ['S1', 'S2']) {
        await db.insert('sales', {
          'invoice': inv, 'subtotal': 0.0, 'discount': 0.0, 'tax': 0.0, 'total': 5.0, 'paid': 0.0,
          'paymentMethod': 'cash', 'createdAt': 1,
        });
        await db.insert('sale_items', {
          'invoice': inv, 'barcode': 'b', 'product': 'p', 'qty': 1.0, 'unitPrice': 5.0, 'cost': 1.0, 'amount': 5.0,
        });
      }
      await _queue(db, 'sale', 'sale:S2', 'upsert');
      await _apply(db, PullResult(sales: [
        {'invoice': 'S1', '_deleted': true},
        {'invoice': 'S2', '_deleted': true},
      ]));
      expect((await db.query('sales')).map((r) => r['invoice']), ['S2']);
      expect((await db.query('sale_items')).map((r) => r['invoice']), ['S2']);
      final a = await db.query('audit');
      expect(a.single['reference'], 'sale:S2');
      expect(a.single['details'], contains('kept your local copy'));
    });
  });

  group('purchases', () {
    test('naya bill + items (itemName/rates); supplierServerId se local supplier', () async {
      await db.insert('suppliers', {'name': 'Deen', 'serverId': 's1'});
      await _apply(db, PullResult(purchases: [
        {
          'billNo': 'P1', 'supplierServerId': 's1', 'total': 200, 'paid': 50, 'subtotal': 210, 'discount': 10,
          'createdAt': 55, 'updatedAt': 66,
          'items': [
            {'barcode': 'b1', 'qty': 4, 'unitCost': 50, 'amount': 200, 'unit': 'ctn', 'conversionFactor': 12,
             'itemName': 'Soap', 'retailRate': 70, 'wholesaleRate': 60},
          ],
        },
      ]));
      final p = (await db.query('purchases')).single;
      expect(p['supplierId'], 1);
      expect(p['dirty'], 0);
      expect(p['supplierInvoiceNo'], '');
      final it = (await db.query('purchase_items')).single;
      expect(it['itemName'], 'Soap');
      expect(it['retailRate'], 70.0);
      expect(it['conversionFactor'], 12.0);
    });

    test('Flutter-only columns (dueDate, supplierInvoiceNo) doc mein na hon to local barqarar', () async {
      await db.insert('purchases', {
        'billNo': 'P1', 'total': 1.0, 'paid': 0.0, 'createdAt': 1, 'dueDate': 42, 'supplierInvoiceNo': 'INV-9',
      });
      await _apply(db, PullResult(purchases: [{'billNo': 'P1', 'total': 2, 'paid': 0}]));
      final p = (await db.query('purchases')).single;
      expect(p['total'], 2.0);
      expect(p['dueDate'], 42);
      expect(p['supplierInvoiceNo'], 'INV-9');
    });

    test('pending edit delete ko rokta hai (audit); warna delete', () async {
      for (final b in ['P1', 'P2']) {
        await db.insert('purchases', {'billNo': b, 'total': 9.0, 'paid': 1.0, 'createdAt': 1});
        await db.insert('purchase_items',
            {'billNo': b, 'barcode': 'x', 'qty': 1.0, 'unitCost': 9.0, 'amount': 9.0});
      }
      await _queue(db, 'purchase', 'purchase:P2', 'upsert');
      await _apply(db, PullResult(purchases: [
        {'billNo': 'P1', '_deleted': true},
        {'billNo': 'P2', '_deleted': true},
      ]));
      expect((await db.query('purchases')).map((r) => r['billNo']), ['P2']);
      expect((await db.query('purchase_items')).map((r) => r['billNo']), ['P2']);
      expect((await db.query('audit')).single['reference'], 'purchase:P2');
    });
  });

  group('expenses / payments / cash', () {
    test('expense: insert, update (id wohi), method default cash, tombstone, serverId ke baghair skip', () async {
      await _apply(db, PullResult(expenses: [
        {'serverId': 'e1', 'category': 'Rent', 'description': 'Aug', 'amount': 100, 'createdAt': 10},
        {'category': 'NoId'},
        {'serverId': 'e2'},
      ]));
      var e = (await db.query('expenses')).single;
      expect(e['method'], 'cash');
      expect(e['dirty'], 0);
      expect(e['updatedAt'], 10);
      await _apply(db, PullResult(expenses: [
        {'serverId': 'e1', 'category': 'Rent', 'amount': 150, 'method': 'bank', 'createdAt': 10, 'updatedAt': 20},
      ]));
      e = (await db.query('expenses')).single;
      expect(e['id'], 1);
      expect(e['amount'], 150.0);
      expect(e['method'], 'bank');
      await _apply(db, PullResult(expenses: [{'serverId': 'e1', '_deleted': true}]));
      expect(await db.query('expenses'), isEmpty);
    });

    test('payment: partyServerId se SAHI local party (raw id ignore); purana doc raw id; tombstone', () async {
      // Is device par customer id=1 "A", id=2 "B". Doosre device ka partyId=1 asal mein B (serverId cB) hai.
      await db.insert('customers', {'name': 'A', 'serverId': 'cA'});
      await db.insert('customers', {'name': 'B', 'serverId': 'cB'});
      await _apply(db, PullResult(payments: [
        {'serverId': 'p1', 'reference': 'S1', 'partyType': 'customer', 'partyId': 1, 'partyServerId': 'cB',
         'amount': 50, 'method': 'cash', 'createdAt': 5},
        {'serverId': 'p2', 'reference': 'S2', 'partyType': 'customer', 'partyId': 2, 'amount': 10, 'method': 'cash',
         'createdAt': 6},
        {'serverId': 'p3', 'reference': 'S3', 'partyType': 'customer', 'partyServerId': 'nobody', 'partyId': 1,
         'amount': 1, 'method': 'cash', 'createdAt': 7},
      ]));
      final rows = {for (final r in await db.query('payments')) r['serverId']: r};
      expect(rows['p1']!['partyId'], 2); // B
      expect(rows['p2']!['partyId'], 2); // legacy raw
      expect(rows['p3']!['partyId'], isNull); // serverId diya par party nahi mili => galat party nahi
      await _apply(db, PullResult(payments: [{'serverId': 'p1', '_deleted': true}]));
      expect((await db.query('payments')).length, 2);
    });

    test('payment supplier partyType supplier table se resolve', () async {
      await db.insert('suppliers', {'name': 'X', 'serverId': 'sX'});
      await _apply(db, PullResult(payments: [
        {'serverId': 'p1', 'reference': 'P1', 'partyType': 'supplier', 'partyServerId': 'sX', 'amount': 5,
         'method': 'cash', 'billReference': 'P1', 'createdAt': 1},
      ]));
      final p = (await db.query('payments')).single;
      expect(p['partyId'], 1);
      expect(p['billReference'], 'P1');
    });

    test('party baad mein aaye => payment/sale/purchase relink; balance nahi badalta', () async {
      // Pehli pull: payment/sale/purchase aaye par party abhi local DB mein nahi.
      await _apply(db, PullResult(
        payments: [
          {'serverId': 'p1', 'reference': 'manual-customer-9-1', 'partyType': 'customer', 'partyServerId': 'cLate',
           'amount': 30, 'method': 'cash', 'createdAt': 1},
          {'serverId': 'p2', 'reference': 'manual-supplier-4-1', 'partyType': 'supplier', 'partyServerId': 'sLate',
           'amount': 70, 'method': 'cash', 'createdAt': 2},
        ],
        sales: [
          {'invoice': 'S9', 'customerServerId': 'cLate', 'subtotal': 100, 'total': 100, 'paid': 0,
           'paymentMethod': 'cash', 'createdAt': 1},
        ],
        purchases: [
          {'billNo': 'P9', 'supplierServerId': 'sLate', 'total': 200, 'paid': 0, 'createdAt': 1},
        ],
      ));
      expect((await db.query('payments')).every((r) => r['partyId'] == null), isTrue);
      expect((await db.query('sales')).single['customerId'], isNull);
      expect((await db.query('purchases')).single['supplierId'], isNull);
      // Portable pehchan mehfooz hai.
      expect((await db.query('sales')).single['customerServerId'], 'cLate');
      expect((await db.query('purchases')).single['supplierServerId'], 'sLate');

      // Doosri pull: sirf party docs (balance server ka total).
      await _apply(db, PullResult(
        customers: [
          {'serverId': 'cLate', 'name': 'Late C', 'balance': 70, 'updatedAt': 10},
        ],
        suppliers: [
          {'serverId': 'sLate', 'name': 'Late S', 'balance': 130, 'updatedAt': 10},
        ],
      ));
      final cId = (await db.query('customers')).single['id'];
      final sId = (await db.query('suppliers')).single['id'];
      final pays = {for (final r in await db.query('payments')) r['serverId']: r};
      expect(pays['p1']!['partyId'], cId);
      expect(pays['p2']!['partyId'], sId);
      expect((await db.query('sales')).single['customerId'], cId);
      expect((await db.query('purchases')).single['supplierId'], sId);
      // Relink balance nahi chhoota.
      expect((await db.query('customers')).single['balance'], 70);
      expect((await db.query('suppliers')).single['balance'], 130);

      // Idempotent: dobara chalane se kuch nahi badalta.
      await relinkOrphanedParties(db);
      expect((await db.query('payments')).where((r) => r['partyId'] != null).length, 2);
    });

    test('cash transaction: insert/update/tombstone', () async {
      await _apply(db, PullResult(cashTransactions: [
        {'serverId': 'c1', 'type': 'IN', 'method': 'cash', 'amount': 20, 'reason': 'sale', 'reference': 'S1',
         'createdAt': 3},
        {'serverId': 'c2'},
      ]));
      expect((await db.query('cash_transactions')).length, 1);
      await _apply(db, PullResult(cashTransactions: [
        {'serverId': 'c1', 'type': 'OUT', 'amount': 25, 'createdAt': 3, 'updatedAt': 9},
      ]));
      final c = (await db.query('cash_transactions')).single;
      expect(c['type'], 'OUT');
      expect(c['amount'], 25.0);
      await _apply(db, PullResult(cashTransactions: [{'serverId': 'c1', '_deleted': true}]));
      expect(await db.query('cash_transactions'), isEmpty);
    });
  });

  group('units / categories', () {
    test('insert-if-missing, dobara pull duplicate nahi, tombstone', () async {
      await _apply(db, PullResult(units: [{'name': 'ctn'}, {'name': 'ctn'}, {'x': 1}],
          categories: [{'name': 'Soap'}]));
      expect((await db.query('units')).length, 1);
      expect((await db.query('categories')).length, 1);
      await _apply(db, PullResult(units: [{'name': 'ctn', '_deleted': true}],
          categories: [{'name': 'Soap', '_deleted': true}]));
      expect(await db.query('units'), isEmpty);
      expect(await db.query('categories'), isEmpty);
    });
  });

  group('zakat', () {
    test('year pehle, payment parent se linked; parent na ho to payment skip', () async {
      await _apply(db, PullResult(
        zakatPayments: [
          {'serverId': 'zp0', 'zakatYearServerId': 'missing', 'amount': 1},
        ],
      ));
      expect(await db.query('zakat_payments'), isEmpty);

      await _apply(db, PullResult(
        // Payments pehle aayein, phir bhi year pehle lagta hai (ek hi call).
        zakatPayments: [
          {'serverId': 'zp1', 'zakatYearServerId': 'zy1', 'amount': 500, 'method': 'cash', 'createdAt': 20},
        ],
        zakatYears: [
          {'serverId': 'zy1', 'startDate': 100, 'endDate': 200, 'assetsSnapshot': 9000, 'totalPayable': 225,
           'createdAt': 10},
          {'serverId': 'zy2'}, // startDate/endDate nahi => skip
        ],
      ));
      final y = (await db.query('zakat_years')).single;
      expect(y['currency'], 'Rs');
      expect(y['calendarType'], 'islamic');
      final p = (await db.query('zakat_payments')).single;
      expect(p['zakatYearId'], y['id']);
      expect(p['paymentDate'], 20); // createdAt par fallback
      expect(p['dirty'], 0);
    });

    test('tombstone kuch nahi karta (Kotlin jaisa)', () async {
      await _apply(db, PullResult(zakatYears: [
        {'serverId': 'zy1', 'startDate': 1, 'endDate': 2, 'assetsSnapshot': 1, 'totalPayable': 1},
      ]));
      await _apply(db, PullResult(zakatYears: [{'serverId': 'zy1', '_deleted': true}]));
      expect((await db.query('zakat_years')).length, 1);
    });
  });

  group('returns / stock movements', () {
    test('return: idempotent (dobara pull duplicate nahi)', () async {
      final doc = {'serverId': 'r1', 'reference': 'S1', 'type': 'sale', 'barcode': 'b1', 'qty': 2, 'amount': 20,
        'createdAt': 5};
      await _apply(db, PullResult(returns: [doc]));
      await _apply(db, PullResult(returns: [doc]));
      final r = (await db.query('returns')).single;
      expect(r['dirty'], 0);
      expect(r['serverId'], 'r1');
    });

    test('stock movement: naya insert; apni unclaimed row claim (duplicate nahi); qty ke baghair skip', () async {
      await db.insert('stock_movements', {
        'barcode': 'b1', 'type': 'PURCHASE', 'qty': 2160.0, 'reference': 'P1', 'createdAt': 100, 'dirty': 1,
      });
      await _apply(db, PullResult(stockMovements: [
        {'serverId': 'm1', 'barcode': 'b1', 'type': 'PURCHASE', 'qty': 2160, 'reference': 'P1', 'createdAt': 100,
         'updatedAt': 300},
        {'serverId': 'm2', 'barcode': 'b2', 'type': 'SALE', 'qty': -3, 'unit': 'pcs', 'cost': 4, 'reference': 'S1',
         'note': 'n', 'createdAt': 110},
        {'serverId': 'm3', 'barcode': 'b3', 'type': 'SALE'},
      ]));
      final rows = await db.query('stock_movements', orderBy: 'id');
      expect(rows.length, 2);
      expect(rows[0]['serverId'], 'm1');
      expect(rows[0]['updatedAt'], 300);
      expect(rows[0]['dirty'], 1); // claim sirf serverId/updatedAt (Kotlin copy)
      expect(rows[1]['serverId'], 'm2');
      expect(rows[1]['dirty'], 0);
      // Dobara wahi pull => kuch nahi badla.
      await _apply(db, PullResult(stockMovements: [
        {'serverId': 'm1', 'barcode': 'b1', 'type': 'PURCHASE', 'qty': 2160, 'reference': 'P1', 'createdAt': 100},
      ]));
      expect((await db.query('stock_movements')).length, 2);
    });

    test('doosri serverId wali row claim nahi hoti (naya insert)', () async {
      await db.insert('stock_movements', {
        'barcode': 'b1', 'type': 'SALE', 'qty': -1.0, 'reference': 'S1', 'createdAt': 5, 'serverId': 'mine',
      });
      await _apply(db, PullResult(stockMovements: [
        {'serverId': 'other', 'barcode': 'b1', 'type': 'SALE', 'qty': -1, 'reference': 'S1', 'createdAt': 5},
      ]));
      expect((await db.query('stock_movements')).length, 2);
    });
  });

  group('shell ledger', () {
    test('customer create/update; transaction customerServerId se link; log idempotent', () async {
      await _apply(db, PullResult(
        shellTransactions: [
          {'serverId': 't1', 'customerServerId': 'sc1', 'type': 'GIVE', 'qty': 6, 'createdAt': 2},
          {'serverId': 't2', 'customerServerId': 'ghost', 'type': 'GIVE', 'qty': 1},
        ],
        shellCustomers: [
          {'serverId': 'sc1', 'name': 'Bilal', 'shellsOwed': 6, 'createdAt': 1},
        ],
        shopEmptyShellLogs: [
          {'serverId': 'l1', 'delta': -6, 'reason': 'GIVE', 'createdAt': 2},
          {'serverId': 'l2', 'delta': 1},
        ],
      ));
      final c = (await db.query('shell_customers')).single;
      expect(c['shellsOwed'], 6);
      final t = (await db.query('shell_transactions')).single;
      expect(t['customerId'], c['id']);
      expect(t['qty'], 6);
      expect((await db.query('shop_empty_shell_log')).length, 1);

      await _apply(db, PullResult(
        shellCustomers: [
          {'serverId': 'sc1', 'name': 'Bilal K', 'shellsOwed': 2, 'createdAt': 1, 'updatedAt': 9},
        ],
        shellTransactions: [
          {'serverId': 't1', 'customerServerId': 'sc1', 'type': 'GIVE', 'qty': 6},
        ],
        shopEmptyShellLogs: [
          {'serverId': 'l1', 'delta': -6, 'reason': 'GIVE'},
        ],
      ));
      final c2 = (await db.query('shell_customers')).single;
      expect(c2['name'], 'Bilal K');
      expect(c2['shellsOwed'], 2);
      expect(c2['id'], c['id']);
      expect((await db.query('shell_transactions')).length, 1);
      expect((await db.query('shop_empty_shell_log')).length, 1);
    });
  });

  group('app settings / cash register', () {
    test('app setting: set; pending upsert wali key skip; value ke baghair skip', () async {
      await db.insert('app_settings', {'key': 'shop_name', 'value': 'Mine'});
      await _queue(db, 'app_setting', 'shop_name', 'upsert');
      await _apply(db, PullResult(appSettings: [
        {'key': 'shop_name', 'value': 'Theirs'},
        {'key': 'shop_phone', 'value': '0300'},
        {'key': 'currency'},
      ]));
      final m = {for (final r in await db.query('app_settings')) r['key']: r['value']};
      expect(m, {'shop_name': 'Mine', 'shop_phone': '0300'});
    });

    test('cash register: upsert by date; kisi bhi pending op (create_if_absent) par skip', () async {
      await _queue(db, 'cash_register', '2026-09-28', 'create_if_absent');
      await _apply(db, PullResult(cashRegisters: [
        {'date': '2026-09-28', 'openingCash': 500, 'closed': true},
        {'date': '2026-09-29', 'openingCash': 700, 'closingCash': 900, 'openingBank': 10, 'closingBank': 20,
         'closed': true},
        {'openingCash': 1},
      ]));
      final rows = await db.query('cash_register');
      expect(rows.length, 1);
      expect(rows.single['date'], '2026-09-29');
      expect(rows.single['closingCash'], 900.0);
      expect(rows.single['closed'], 1);
      // Dobara (closed false) => replace.
      await _apply(db, PullResult(cashRegisters: [
        {'date': '2026-09-29', 'openingCash': 700, 'closed': false},
      ]));
      final r = (await db.query('cash_register')).single;
      expect(r['closed'], 0);
      expect(r['closingCash'], 0.0);
    });
  });

  group('ek transaction', () {
    test('hissa 2 ke beech mein ghalti => hissa 1 bhi nahi likha (checkpoint nahi barhta)', () async {
      await db.execute('DROP TABLE zakat_years'); // hissa 2 ka ek table gayab
      await expectLater(
        _apply(db, PullResult(
          customers: [{'serverId': 'c1', 'name': 'Ali'}],
          zakatYears: [
            {'serverId': 'zy1', 'startDate': 1, 'endDate': 2},
          ],
        )),
        throwsA(anything),
      );
      expect(await db.query('customers'), isEmpty);
    });
  });

  test('branchScopedCollections: 16, users/shell nahi', () {
    expect(branchScopedCollections.length, 16);
    expect(branchScopedCollections.contains('users'), isFalse);
    expect(branchScopedCollections.contains('shell_customers'), isFalse);
    expect(branchCleanupBatchSize, lessThan(500));
  });
}
