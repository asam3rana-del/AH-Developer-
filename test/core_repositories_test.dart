import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';
import 'package:ah_developer_kiryana_store/db/category_unit_repository.dart';
import 'package:ah_developer_kiryana_store/db/customer_repository.dart';
import 'package:ah_developer_kiryana_store/db/supplier_repository.dart';
import 'package:ah_developer_kiryana_store/db/user_repository.dart';
import 'package:ah_developer_kiryana_store/models/category_unit.dart' as models;
import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/models/party.dart';

/// Audit (2026-10-01): Customer / Supplier / User / Category / Unit repositories ke apne tests nahi the.
/// Asal AppDatabase (temp folder, sqflite FFI) par — kotlin_import_test.dart jaisa setup.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('core_repo_');
    await databaseFactory.setDatabasesPath(dir.path);
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  Future<int> queued(String type, [String? op]) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sync_queue',
        where: op == null ? 'entityType = ?' : 'entityType = ? AND operation = ?',
        whereArgs: op == null ? [type] : [type, op]);
    return rows.length;
  }

  User user(String name, {String phone = '', bool active = true, String role = 'cashier'}) =>
      User(username: name, displayName: name, role: role, passwordHash: 'h', phone: phone, active: active);

  group('UserRepository', () {
    test('upsert + find (bari/chhoti harf ka farq nahi) aur sync_queue mein user', () async {
      final repo = UserRepository.instance;
      await repo.upsert(user('Asam', role: 'admin'));
      expect((await repo.find('Asam'))?.role, 'admin');
      expect((await repo.find('asam'))?.username, 'Asam');
      expect(await repo.find('nobody'), isNull);
      expect(await queued('user', 'upsert'), 1);
    });

    test('findByPhone sirf ACTIVE user, khali phone kabhi match nahi', () async {
      final repo = UserRepository.instance;
      await repo.upsert(user('a', phone: '+923001111111'));
      await repo.upsert(user('b', phone: '+923002222222', active: false));
      expect((await repo.findByPhone('+923001111111'))?.username, 'a');
      expect(await repo.findByPhone('+923002222222'), isNull);
      expect(await repo.findByPhone(''), isNull);
      expect(await repo.findByPhone('   '), isNull);
    });

    test('activeUsers / all username ke hisaab se', () async {
      final repo = UserRepository.instance;
      await repo.upsert(user('zeeshan'));
      await repo.upsert(user('ali', active: false));
      await repo.upsert(user('bilal'));
      expect((await repo.all()).map((u) => u.username), ['ali', 'bilal', 'zeeshan']);
      expect((await repo.activeUsers()).map((u) => u.username), ['bilal', 'zeeshan']);
    });

    test('rename: naya user + purane ka delete (tombstone) queue mein', () async {
      final repo = UserRepository.instance;
      final old = user('old');
      await repo.upsert(old);
      await repo.rename(old, user('fresh'));
      expect(await repo.find('old'), isNull);
      expect((await repo.find('fresh')), isNotNull);
      expect(await queued('user', 'delete'), 1);
    });

    test('delete: row hat jati hai aur tombstone queue hota hai', () async {
      final repo = UserRepository.instance;
      await repo.upsert(user('gone'));
      await repo.delete('gone');
      expect(await repo.find('gone'), isNull);
      expect(await queued('user', 'delete'), 1);
    });

    test('settings: set/get; sync wali key queue hoti hai, device wali nahi', () async {
      final repo = UserRepository.instance;
      expect(await repo.getSetting('shop_name'), isNull);
      await repo.setSetting('shop_name', 'IBTISAAM');
      await repo.setSetting('printer_mac', 'AA:BB');
      expect(await repo.getSetting('shop_name'), 'IBTISAAM');
      expect(await repo.getSetting('printer_mac'), 'AA:BB');
      await repo.setSetting('shop_name', 'IBTISAAM 2');
      expect(await repo.getSetting('shop_name'), 'IBTISAAM 2');
      expect(await queued('app_setting'), 2); // shop_name x2; printer_mac queue nahi
    });
  });

  group('CustomerRepository', () {
    test('insert id deta hai, listAll naam (bari/chhoti ignore) se sorted', () async {
      final repo = CustomerRepository.instance;
      final id1 = await repo.insert(const Customer(name: 'zafar'));
      final id2 = await repo.insert(const Customer(name: 'Ali'));
      expect(id1, isNot(id2));
      expect((await repo.listAll()).map((c) => c.name), ['Ali', 'zafar']);
    });

    test('addBalance: +udhaar / -payment, dirty = 1', () async {
      final repo = CustomerRepository.instance;
      final id = await repo.insert(const Customer(name: 'Ali', balance: 100, dirty: false));
      await repo.addBalance(id, 250.5);
      await repo.addBalance(id, -50);
      final c = (await repo.listAll()).single;
      expect(c.balance, 300.5);
      expect(c.dirty, isTrue);
    });

    test('watchAll: naye subscriber ko pehle current list milti hai', () async {
      final repo = CustomerRepository.instance;
      await repo.insert(const Customer(name: 'Ali'));
      final first = await repo.watchAll().first;
      expect(first.map((c) => c.name), ['Ali']);
    });
  });

  group('SupplierRepository', () {
    test('insert + sorted list + addBalance', () async {
      final repo = SupplierRepository.instance;
      await repo.insert(const Supplier(name: 'Bashir Traders'));
      final id = await repo.insert(const Supplier(name: 'ahmed Foods', balance: 1000, dirty: false));
      expect((await repo.listAll()).map((s) => s.name), ['ahmed Foods', 'Bashir Traders']);
      await repo.addBalance(id, -400);
      final s = (await repo.listAll()).firstWhere((x) => x.id == id);
      expect(s.balance, 600);
      expect(s.dirty, isTrue);
    });
  });

  group('Category / Unit repositories', () {
    test('category: duplicate ignore, sorted (seed "General" maujood), sync_queue mein', () async {
      final repo = CategoryRepository.instance;
      await repo.insert(const models.Category('Rice'));
      await repo.insert(const models.Category('atta'));
      await repo.insert(const models.Category('Rice')); // duplicate: crash nahi
      final names = (await repo.listAll()).map((c) => c.name).toList();
      expect(names, ['atta', 'General', 'Rice']);
      expect(await queued('category'), greaterThanOrEqualTo(2));
    });

    test('unit: duplicate ignore, sorted (seed "pcs" maujood)', () async {
      final repo = UnitRepository.instance;
      await repo.insert(const models.UnitType('Kg'));
      await repo.insert(const models.UnitType('carton'));
      await repo.insert(const models.UnitType('Kg'));
      final names = (await repo.listAll()).map((u) => u.name).toList();
      expect(names, ['carton', 'Kg', 'pcs']);
    });
  });
}
