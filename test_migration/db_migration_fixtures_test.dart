import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/db/app_database.dart';

/// Database migration tests, part 3 (improvement plan, P0 #4): REAL old database files.
///
/// test/fixtures/legacy_v1.db, legacy_v4.db, legacy_v5.db, legacy_v10.db, legacy_v12.db, legacy_v13.db, legacy_v14.db, legacy_v15.db, legacy_v18.db, legacy_v25.db, legacy_v29.db and legacy_v32.db are built by tools/make_legacy_fixtures.py from the CREATE
/// statements of twelve OLDER COMMITS of this repo (schema v1 = the very first Flutter build, v4, v5, v10, v12, v13, v14, v15, v18, v25, v29, v32), not
/// from the current migration code. So a mistake in _onUpgrade cannot hide behind the test's own rewind logic.
/// Rows are demo data, not a customer's file; a real customer file should be added the same way.
///
/// Per fixture: open it through AppDatabase (real _onUpgrade), then require user_version == current, integrity
/// ok, no FK violations, schema identical to a fresh install, and every value that existed in the old file
/// unchanged (old columns only; new columns get their defaults).
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('migration_fixture_');
    await databaseFactory.setDatabasesPath(dir.path);
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, List<String>>> schemaOf(dynamic db) async {
    final out = <String, List<String>>{};
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    for (final t in tables) {
      final name = t['name'] as String;
      final info = await db.rawQuery('PRAGMA table_info($name)');
      out[name] = [
        for (final c in info) '${c['name']}|${c['type']}|${c['notnull']}|${c['dflt_value']}|${c['pk']}',
      ]..sort();
    }
    final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    out['__indexes__'] = [for (final i in idx) i['name'] as String];
    return out;
  }

  Future<Map<String, List<Map<String, Object?>>>> allRows(dynamic db) async {
    final out = <String, List<Map<String, Object?>>>{};
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    for (final t in tables) {
      final name = t['name'] as String;
      final List rows = await db.rawQuery('SELECT * FROM $name ORDER BY rowid');
      out[name] = [for (final r in rows) Map<String, Object?>.from(r as Map)];
    }
    return out;
  }

  /// Schema of a brand-new install, measured in its own directory.
  Future<Map<String, List<String>>> freshSchema() async {
    final fresh = await Directory.systemTemp.createTemp('migration_fresh_');
    await databaseFactory.setDatabasesPath(fresh.path);
    final db = await AppDatabase.instance.database;
    final s = await schemaOf(db);
    await AppDatabase.instance.close();
    await fresh.delete(recursive: true);
    await databaseFactory.setDatabasesPath(dir.path);
    return s;
  }

  for (final f in [(file: 'legacy_v1.db', version: 1), (file: 'legacy_v4.db', version: 4), (file: 'legacy_v5.db', version: 5), (file: 'legacy_v10.db', version: 10), (file: 'legacy_v12.db', version: 12), (file: 'legacy_v13.db', version: 13), (file: 'legacy_v14.db', version: 14), (file: 'legacy_v15.db', version: 15), (file: 'legacy_v18.db', version: 18), (file: 'legacy_v25.db', version: 25), (file: 'legacy_v29.db', version: 29), (file: 'legacy_v32.db', version: 32)]) {
    test('real file ${f.file} (schema v${f.version}) -> v${AppDatabase.schemaVersion}', () async {
      final src = File('test/fixtures/${f.file}');
      expect(src.existsSync(), isTrue, reason: 'run tools/make_legacy_fixtures.py and commit the .db files');

      final expectedSchema = await freshSchema();

      final target = File(await AppDatabase.instance.databasePath);
      await target.parent.create(recursive: true);
      await src.copy(target.path);

      // what the old file really contains (opened raw: no upgrade)
      final raw = await databaseFactory.openDatabase(target.path, options: OpenDatabaseOptions(readOnly: true));
      final oldVer = await raw.rawQuery('PRAGMA user_version');
      expect(oldVer.first.values.first, f.version);
      final before = await allRows(raw);
      expect(before['products'], hasLength(3));
      await raw.close();

      final db = await AppDatabase.instance.database; // runs the real _onUpgrade
      final ver = await db.rawQuery('PRAGMA user_version');
      expect(ver.first.values.first, AppDatabase.schemaVersion);
      expect((await db.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await schemaOf(db), equals(expectedSchema));

      // every old value survives (compare only columns the old file had)
      final after = await allRows(db);
      before.forEach((table, oldRows) {
        expect(after.containsKey(table), isTrue, reason: 'table $table disappeared');
        // sync_queue is checked separately below: the v11 ledger backfill legitimately enqueues rows.
        if (table == 'sync_queue') return;
        expect(after[table]!.length, oldRows.length, reason: '$table row count');
        for (var i = 0; i < oldRows.length; i++) {
          oldRows[i].forEach((col, v) {
            expect(after[table]![i][col], v, reason: '$table row $i column $col');
          });
        }
      });

      // old queue rows survive; new ones appear only from the v11 opening-stock backfill (one per ledger row)
      final oldQueue = before['sync_queue'] ?? [];
      final newQueue = after['sync_queue'] ?? [];
      expect(newQueue.take(oldQueue.length).toList(), oldQueue, reason: 'old sync_queue rows changed');
      final added = newQueue.skip(oldQueue.length).toList();
      if (f.version < 11) {
        expect([for (final r in added) r['entityType']], ['stock_movement', 'stock_movement']);
        expect([for (final r in added) r['operation']], ['upsert', 'upsert']);
      } else {
        expect(added, isEmpty, reason: 'upgrade must not enqueue anything new');
      }

      // money must be exactly as in the old file
      expect((await db.query('customers', where: "name='Ali'")).single['balance'], 750.0);
      expect((await db.query('customers', where: "name='Bilal'")).single['balance'], -120.5);
      expect((await db.query('suppliers')).single['balance'], 3000.0);

      if (f.version < 11) {
        // v11 ledger backfill: P1 (12.5) and P3 (40) get one opening row, zero-stock P2 none
        final ledger = await db.rawQuery(
            'SELECT barcode, SUM(qty) AS s, COUNT(*) AS n FROM stock_movements GROUP BY barcode ORDER BY barcode');
        expect([for (final r in ledger) r['barcode']], ['P1', 'P3']);
        expect([for (final r in ledger) (r['s'] as num).toDouble()], [12.5, 40.0]);
        expect([for (final r in ledger) r['n']], [1, 1]);
      }
    });
  }
}
