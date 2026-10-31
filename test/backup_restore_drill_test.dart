import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/backup/backup_helper.dart';
import 'package:ah_developer_kiryana_store/backup/backup_password_store.dart';
import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Backup / restore drill (improvement plan, P1 #7). NOT YET RUN - lives outside test/ so a failure cannot
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
    await db.insert('expenses', {'category': 'Rent', 'description': 'Shop', 'amount': 20000.0, 'createdAt': 1700000000000});
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

  test('backup is encrypted and needs a password', () async {
    await seed();
    final f = await makeBackupCopy();
    expect(await BackupHelper.needsPassword(f), isTrue);
    final head = await f.openRead(0, 4).first;
    expect(String.fromCharCodes(head), 'IBB1');
  });

  test('restore returns the exact original rows and removes later changes', () async {
    await seed();
    final original = await snapshot();
    final backup = await makeBackupCopy();
    final password = await BackupPasswordStore.peek();
    expect(password, isNotNull);

    await mutate();
    expect(await snapshot(), isNot(equals(original)));

    final ok = await BackupHelper.restore(backup, pass: password);
    expect(ok, isTrue, reason: 'restore failed: ${BackupHelper.lastError}');

    final restored = await snapshot();
    expect(restored, equals(original));
    final db = await AppDatabase.instance.database;
    expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('wrong password: restore fails and the live database is untouched', () async {
    await seed();
    final backup = await makeBackupCopy();
    await mutate();
    final before = await snapshot();

    final ok = await BackupHelper.restore(backup, pass: 'definitely-wrong-password');
    expect(ok, isFalse);
    expect(BackupHelper.lastError, isNotNull);
    expect(await snapshot(), equals(before));
  });

  test('missing password: restore is refused and the live database is untouched', () async {
    await seed();
    final backup = await makeBackupCopy();
    await mutate();
    final before = await snapshot();

    final ok = await BackupHelper.restore(backup);
    expect(ok, isFalse);
    expect(BackupHelper.lastError, 'Password chahiye');
    expect(await snapshot(), equals(before));
  });

  test('corrupted backup file: restore fails and the live database is untouched', () async {
    await seed();
    final backup = await makeBackupCopy();
    final password = await BackupPasswordStore.peek();
    final bytes = await backup.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 0xFF; // flip one byte in the middle of the ciphertext
    await backup.writeAsBytes(bytes);
    await mutate();
    final before = await snapshot();

    final ok = await BackupHelper.restore(backup, pass: password);
    expect(ok, isFalse);
    expect(await snapshot(), equals(before));
  });

  test('a file that is not a database: restore fails and the live database is untouched', () async {
    await seed();
    final junk = File(p(dir, 'not_a_backup.db'));
    await junk.writeAsBytes(List<int>.generate(2048, (i) => i % 251));
    final before = await snapshot();

    final ok = await BackupHelper.restore(junk);
    expect(ok, isFalse);
    expect(await snapshot(), equals(before));
  });
}

String p(Directory d, String name) => '${d.path}${Platform.pathSeparator}$name';
