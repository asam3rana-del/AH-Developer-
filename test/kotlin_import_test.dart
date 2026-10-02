import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/backup/kotlin_import.dart';
import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Kotlin (Room v48) backup -> Flutter DB import. Source DB Room jaisi banai jati hai:
/// `room_master_table`, user_version 48, aur extra columns (saleUid / lineUid / partyServerId).
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String kotlinPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kt_import_');
    await databaseFactory.setDatabasesPath(dir.path);
    await AppDatabase.instance.close();
    kotlinPath = '${dir.path}/kotlin_room.db';

    final k = await databaseFactory.openDatabase(kotlinPath);
    await k.execute('CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)');
    await k.execute('PRAGMA user_version = 48');
    await k.execute('''CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
      phone TEXT NOT NULL, creditLimit REAL NOT NULL, openingBalance REAL NOT NULL, balance REAL NOT NULL,
      serverId TEXT, updatedAt INTEGER NOT NULL, dirty INTEGER NOT NULL, stuckBalance REAL NOT NULL)''');
    await k.execute('''CREATE TABLE sales (invoice TEXT PRIMARY KEY NOT NULL, customerId INTEGER, subtotal REAL NOT NULL,
      discount REAL NOT NULL, tax REAL NOT NULL, total REAL NOT NULL, paid REAL NOT NULL, paymentMethod TEXT NOT NULL,
      saleType TEXT NOT NULL, createdAt INTEGER NOT NULL, status TEXT NOT NULL, updatedAt INTEGER NOT NULL,
      dirty INTEGER NOT NULL, dueDate INTEGER NOT NULL DEFAULT 0, saleUid TEXT NOT NULL DEFAULT '')''');
    await k.execute('''CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)''');
    await k.insert('customers', {
      'id': 7, 'name': 'Ali', 'phone': '0300', 'creditLimit': 5000.0, 'openingBalance': 100.0,
      'balance': 250.5, 'serverId': 'srv-7', 'updatedAt': 11, 'dirty': 0, 'stuckBalance': 40.0,
    });
    await k.insert('sales', {
      'invoice': 'INV-1', 'customerId': 7, 'subtotal': 300.0, 'discount': 0.0, 'tax': 0.0, 'total': 300.0,
      'paid': 50.0, 'paymentMethod': 'cash', 'saleType': 'retail', 'createdAt': 1000, 'status': 'active',
      'updatedAt': 11, 'dirty': 1, 'dueDate': 0, 'saleUid': 'uid-1',
    });
    await k.insert('app_settings', {'key': 'shop_name', 'value': 'IBTISAAM'});
    await k.insert('app_settings', {'key': 'printer_mac', 'value': 'AA:BB'});
    await k.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  test('Room DB pehchani jati hai, Flutter DB nahi', () async {
    expect(await KotlinBackupImporter.isRoomDatabase(kotlinPath), isTrue);
    final live = await AppDatabase.instance.database;
    expect(await KotlinBackupImporter.isRoomDatabase(live.path), isFalse);
  });

  test('data copy: id, balance, stuckBalance, serverId, dirty jyon ke tyon; extra columns ignore', () async {
    final live = await AppDatabase.instance.database;
    final report = await KotlinBackupImporter.importInto(live, kotlinPath);

    final c = (await live.query('customers')).single;
    expect(c['id'], 7);
    expect(c['balance'], 250.5);
    expect(c['stuckBalance'], 40.0);
    expect(c['serverId'], 'srv-7');
    expect(c['dirty'], 0);

    final s = (await live.query('sales')).single;
    expect(s['invoice'], 'INV-1');
    expect(s['customerId'], 7);
    expect(s['paid'], 50.0);
    expect(s.containsKey('saleUid'), isFalse);

    expect(report.copied['customers'], 1);
    expect(report.copied['sales'], 1);
    expect(report.dirtyRows, 1); // sirf sale dirty thi
  });

  test('device-specific settings copy nahi hoti, shop_name hoti hai', () async {
    final live = await AppDatabase.instance.database;
    await KotlinBackupImporter.importInto(live, kotlinPath);
    final keys = (await live.query('app_settings')).map((r) => r['key']).toSet();
    expect(keys, contains('shop_name'));
    expect(keys, isNot(contains('printer_mac')));
  });

  test('purana Flutter data replace hota hai aur sync_queue saaf', () async {
    final live = await AppDatabase.instance.database;
    await live.insert('customers', {'name': 'Purana', 'phone': ''});
    await live.insert('sync_queue', {
      'entityType': 'customer', 'entityId': '1', 'operation': 'upsert', 'payloadJson': '{}', 'createdAt': 1,
    });
    await KotlinBackupImporter.importInto(live, kotlinPath);
    expect((await live.query('customers')).map((r) => r['name']), ['Ali']);
    expect(await live.query('sync_queue'), isEmpty);
  });
}
