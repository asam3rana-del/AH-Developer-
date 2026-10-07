import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ah_developer_kiryana_store/models/misc_entities.dart';
import 'package:ah_developer_kiryana_store/sync/sync_apply_rest.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_helper.dart';
import 'package:ah_developer_kiryana_store/sync/sync_queue_dao.dart';

/// Month Close sync: `month_close:<yyyy-MM>` app_setting <-> local `period_closes`.
void main() {
  sqfliteFfiInit();
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
    await db.execute('''CREATE TABLE period_closes (periodKey TEXT PRIMARY KEY NOT NULL, closedAt INTEGER NOT NULL,
      closedBy TEXT NOT NULL DEFAULT '', saleTotal REAL NOT NULL DEFAULT 0, purchaseTotal REAL NOT NULL DEFAULT 0,
      expenseTotal REAL NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '')''');
    await db.execute('''CREATE TABLE sync_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT NOT NULL,
      entityId TEXT NOT NULL, operation TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt INTEGER NOT NULL,
      syncedAt INTEGER, retryCount INTEGER NOT NULL DEFAULT 0, lastError TEXT)''');
  });
  tearDown(() => db.close());

  test('close => queue mein app_setting upsert; anjaan key khamosh', () async {
    await SyncQueueHelper.enqueueAppSetting(db, SyncQueueHelper.monthCloseKey('2026-09'), '{"closed":true}');
    await SyncQueueHelper.enqueueAppSetting(db, 'printer_name', 'x');
    final q = await db.query('sync_queue');
    expect(q.length, 1);
    expect(q.single['entityType'], 'app_setting');
    expect(q.single['entityId'], 'month_close:2026-09');
    expect(q.single['operation'], 'upsert');
  });

  test('pull: closed:true => period_closes row (app_settings mein nahi); closed:false => Reopen', () async {
    await applyAppSettings(db, [
      {
        'key': 'month_close:2026-09',
        'value': '{"closed":true,"closedAt":111,"closedBy":"admin","saleTotal":1000,"purchaseTotal":400,"expenseTotal":50,"note":"ok"}',
      },
    ]);
    final r = (await db.query('period_closes')).single;
    expect(r['periodKey'], '2026-09');
    expect(r['closedAt'], 111);
    expect(r['closedBy'], 'admin');
    expect(r['saleTotal'], 1000.0);
    expect(r['note'], 'ok');
    expect(await db.query('app_settings'), isEmpty);

    await applyAppSettings(db, [
      {'key': 'month_close:2026-09', 'value': '{"closed":false,"reopenedAt":222}'},
    ]);
    expect(await db.query('period_closes'), isEmpty);
  });

  test('pending local month_close upsert par pull skip; kharab key/JSON skip', () async {
    await SyncQueueDao(db).enqueue(SyncQueueEntry(
        entityType: 'app_setting', entityId: 'month_close:2026-08', operation: 'upsert', payloadJson: '{}', createdAt: 1));
    await applyAppSettings(db, [
      {'key': 'month_close:2026-08', 'value': '{"closed":true,"closedAt":1}'},
      {'key': 'month_close:garbage', 'value': '{"closed":true,"closedAt":1}'},
      {'key': 'month_close:2026-07', 'value': 'not json'},
    ]);
    expect(await db.query('period_closes'), isEmpty);
  });
}
