import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/backup/backup_helper.dart';
import 'package:ah_developer_kiryana_store/backup/backup_password_store.dart';
import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Backup / restore drill, part 2 (improvement plan, P1 #7): restoring an OLDER-schema database (real legacy fixtures)
/// and a clean-install restore on a "different device". NOT YET RUN - lives outside test/ so a failure cannot
/// block release builds.
///
/// Real AppDatabase + real BackupHelper (VACUUM INTO snapshot, AES-GCM encrypt + verify, restore). Only the
/// platform plugins are faked: path_provider (temp folder) and flutter_secure_storage (in-memory map).
///
/// Covers: backup -> wipe/modify -> restore returns EXACT original rows; wrong password, missing password,
/// corrupted file and non-database file all fail AND leave the live database untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late Directory dir;
  final secure = <String, String>{};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('backup_drill_');
    secure.clear();
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(pathChannel, (call) async => dir.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
          return null;
        case 'delete':
          secure.remove(key);
          return null;
        case 'containsKey':
          return secure.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secure);
        case 'deleteAll':
          secure.clear();
          return null;
      }
      return null;
    });
    await AppDatabase.instance.close();
    await databaseFactory.setDatabasesPath(p(dir, 'db'));
    await Directory(p(dir, 'db')).create(recursive: true);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  const tables = [
    'products', 'customers', 'suppliers', 'sales', 'sale_items', 'payments',
    'purchases', 'purchase_items', 'expenses', 'cash_transactions', 'users',
  ];

  Future<Map<String, List<String>>> snapshot() async {
    final db = await AppDatabase.instance.database;
    final out = <String, List<String>>{};
    for (final t in tables) {
      final rows = await db.rawQuery('SELECT * FROM $t ORDER BY rowid');
      out[t] = [
        for (final r in rows)
          jsonEncode(Map.fromEntries(r.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))),
      ];
    }
    return out;
  }

  Future<void> seed() async {
    final db = await AppDatabase.instance.database;
    await db.insert('products', {'barcode': 'P1', 'name': 'Rice', 'cost': 900.0, 'salePrice': 1000.0, 'stock': 8.0});
    await db.insert('products', {'barcode': 'P2', 'name': 'Sugar', 'cost': 150.0, 'salePrice': 170.0, 'stock': 40.5});
    await db.insert('customers', {'name': 'Ali', 'balance': 750.0});
    await db.insert('suppliers', {'name': 'Wholesaler', 'balance': 3000.0});
    await db.insert('sales', {
      'invoice': 'INV-1', 'customerId': 1, 'subtotal': 2000.0, 'discount': 0.0, 'tax': 0.0,
      'total': 2000.0, 'paid': 1250.0, 'paymentMethod': 'cash', 'createdAt': 1700000000000,
    });
    await db.insert('sale_items', {
      'invoice': 'INV-1', 'barcode': 'P1', 'product': 'Rice', 'qty': 2.0, 'unit': 'pcs',
      'unitPrice': 1000.0, 'cost': 900.0, 'amount': 2000.0,
    });
    await db.insert('payments', {
      'reference': 'INV-1', 'partyType': 'customer', 'partyId': 1, 'amount': 1250.0,
      'method': 'cash', 'createdAt': 1700000000000,
    });
    await db.insert('purchases', {
      'billNo': 'PB-1', 'supplierId': 1, 'total': 4500.0, 'paid': 1500.0, 'createdAt': 1700000000000,
    });
    await db.insert('purchase_items', {
      'billNo': 'PB-1', 'barcode': 'P1', 'qty': 5.0, 'unitCost': 900.0, 'amount': 4500.0,
    });
    await db.insert('expenses', {'category': 'Rent', 'description': 'Live-only rent', 'amount': 20000.0, 'createdAt': 1700000000000});
    await db.insert('cash_transactions', {'type': 'IN', 'method': 'Cash', 'amount': 1250.0, 'createdAt': 1700000000000});
    await db.insert('users', {'username': 'owner', 'displayName': 'Owner', 'role': 'admin', 'passwordHash': 'x'});
  }

  /// Make the live database clearly different from the backed-up state.
  Future<void> mutate() async {
    final db = await AppDatabase.instance.database;
    await db.delete('sale_items');
    await db.delete('sales');
    await db.delete('payments');
    await db.update('products', {'stock': 0.0});
    await db.update('customers', {'balance': 0.0});
    await db.insert('expenses', {'category': 'Junk', 'description': 'after backup', 'amount': 1.0, 'createdAt': 1});
  }

  Future<File> makeBackupCopy() async {
    final f = await BackupHelper.backupNow();
    expect(f, isNotNull, reason: 'backupNow failed: ${BackupHelper.lastError}');
    expect(await f!.exists(), isTrue);
    // Copy elsewhere: a restore makes a safety backup that may reuse the same file name within one minute.
    final copy = File(p(dir, 'picked_${DateTime.now().microsecondsSinceEpoch}.ibbackup'));
    return f.copy(copy.path);
  }

  Future<File> legacyCopy(String name) async {
    final src = File('test/fixtures/$name');
    expect(src.existsSync(), isTrue, reason: 'missing fixture $name');
    return src.copy(p(dir, 'picked_$name'));
  }

  Future<void> expectRestoredAndMigrated(String fixture) async {
    await seed(); // live database exists => restore must take its safety backup first
    final picked = await legacyCopy(fixture);
    final ok = await BackupHelper.restore(picked);
    expect(ok, isTrue, reason: 'restore of $fixture failed: ${BackupHelper.lastError}');

    final db = await AppDatabase.instance.database; // opens the restored file => real _onUpgrade
    expect((await db.rawQuery('PRAGMA user_version')).single.values.single, AppDatabase.schemaVersion);
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(await db.query('products'), hasLength(3), reason: 'products of the old file');
    expect((await db.query('customers', where: "name='Ali'")).single['balance'], 750.0);
    expect((await db.query('customers', where: "name='Bilal'")).single['balance'], -120.5);
    expect((await db.query('suppliers')).single['balance'], 3000.0);
    expect(await db.query('expenses', where: "description = 'Live-only rent'"), isEmpty, reason: 'rows of the previous live data are gone');
    // The legacy fixtures carry their own expense ('Rent' / 'Shop'), so it must be present after the restore.
    expect(await db.query('expenses', where: "description = 'Shop'"), hasLength(1), reason: 'expense of the old file');
  }

  test('older-schema backup v10 is restored and then migrated to the current schema with its data intact', () async {
    await expectRestoredAndMigrated('legacy_v10.db');
  });

  test('older-schema backup v25 is restored and then migrated to the current schema with its data intact', () async {
    await expectRestoredAndMigrated('legacy_v25.db');
  });

  test('older-schema backup v32 is restored and then migrated to the current schema with its data intact', () async {
    await expectRestoredAndMigrated('legacy_v32.db');
  });

  test('the very first schema (v1): either restored and migrated, or refused cleanly with the live database untouched', () async {
    await seed();
    final before = await snapshot();
    final picked = await legacyCopy('legacy_v1.db');
    final ok = await BackupHelper.restore(picked);
    if (!ok) {
      expect(BackupHelper.lastError, isNotNull);
      expect(await snapshot(), equals(before), reason: 'a refused restore must not touch the live database');
    } else {
      final db = await AppDatabase.instance.database;
      expect((await db.rawQuery('PRAGMA user_version')).single.values.single, AppDatabase.schemaVersion);
      expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
      expect(await db.query('products'), hasLength(3));
    }
  });

  test('a backup from a NEWER app version is refused and the live database is untouched', () async {
    await seed();
    final before = await snapshot();
    final newer = File(p(dir, 'from_the_future.db'));
    final tmp = await databaseFactory.openDatabase(newer.path, options: OpenDatabaseOptions(singleInstance: false));
    await tmp.execute('CREATE TABLE products (barcode TEXT)');
    await tmp.execute('PRAGMA user_version = ${AppDatabase.schemaVersion + 50}');
    await tmp.close();

    final ok = await BackupHelper.restore(newer);
    expect(ok, isFalse);
    expect(BackupHelper.lastError, contains('naye version'));
    expect(await snapshot(), equals(before));
  });

  test('clean install on another device: no database, no saved password, restore with the password from the backup', () async {
    await seed();
    final original = await snapshot();
    final backup = await makeBackupCopy();
    final password = await BackupPasswordStore.peek();
    expect(password, isNotNull);

    // "New phone": the old database file and the old secure storage do not exist here.
    await AppDatabase.instance.close();
    for (final f in Directory(p(dir, 'db')).listSync().whereType<File>()) {
      await f.delete();
    }
    secure.clear();

    final ok = await BackupHelper.restore(backup, pass: password);
    expect(ok, isTrue, reason: 'clean-install restore failed: ${BackupHelper.lastError}');
    expect(await snapshot(), equals(original));
    final db = await AppDatabase.instance.database;
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}

String p(Directory d, String name) => '${d.path}${Platform.pathSeparator}$name';
