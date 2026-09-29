import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';

/// Kotlin `SyncQueueDao` (Database.kt) — `sync_queue` table. `DatabaseExecutor` leta hai, is liye
/// `db` aur `txn` dono par chalta hai (SyncQueueHelper enqueue aksar kisi transaction ke andar hoti hai).
class SyncQueueDao {
  final DatabaseExecutor db;
  const SyncQueueDao(this.db);

  /// Auto-retry ki had: is se zyada baar fail hui entry "stuck" hai, sirf manual Retry Now se
  /// dobara chalti hai (Kotlin FIX "risk-free POS" — ek kharab entry har sync par na ubhre).
  static const int maxAutoRetries = 10;

  Future<int> enqueue(SyncQueueEntry e) {
    final m = e.toMap()..remove('id');
    return db.insert('sync_queue', m);
  }

  /// Bheji jaani wali entries, purani pehle. `retryCount < 10`.
  Future<List<SyncQueueEntry>> pending({int limit = 50}) async {
    final rows = await db.query(
      'sync_queue',
      where: 'syncedAt IS NULL AND retryCount < ?',
      whereArgs: [maxAutoRetries],
      orderBy: 'createdAt ASC',
      limit: limit,
    );
    return rows.map(SyncQueueEntry.fromMap).toList();
  }

  Future<List<SyncQueueEntry>> pendingForEntity(
      String entityType, String entityId, String operation) async {
    final rows = await db.query(
      'sync_queue',
      where: 'syncedAt IS NULL AND retryCount < ? AND entityType = ? AND entityId = ? AND operation = ?',
      whereArgs: [maxAutoRetries, entityType, entityId, operation],
      orderBy: 'createdAt ASC',
    );
    return rows.map(SyncQueueEntry.fromMap).toList();
  }

  /// Kotlin FIX (leaking payable): har retryCount ki unsynced entries ginta hai — stuck entry ka
  /// balance/stock delta pull ke baad local total se gayab na ho.
  Future<List<SyncQueueEntry>> pendingForEntityAnyRetry(
      String entityType, String entityId, String operation) async {
    final rows = await db.query(
      'sync_queue',
      where: 'syncedAt IS NULL AND entityType = ? AND entityId = ? AND operation = ?',
      whereArgs: [entityType, entityId, operation],
      orderBy: 'createdAt ASC',
    );
    return rows.map(SyncQueueEntry.fromMap).toList();
  }

  /// Kisi bhi operation/retryCount ki unsynced entries — pull kisi anpushed local edit ko
  /// purani server copy se overwrite na kare.
  Future<int> pendingCountForEntity(String entityType, String entityId) async {
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_queue WHERE syncedAt IS NULL AND entityType = ? AND entityId = ?',
      [entityType, entityId],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<void> markSynced(int id, {int? ts}) => db.update(
        'sync_queue',
        {'syncedAt': ts ?? DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> markFailed(int id, String err) => db.rawUpdate(
        'UPDATE sync_queue SET retryCount = retryCount + 1, lastError = ? WHERE id = ?',
        [err, id],
      );

  /// `before` se purani synced rows hata do (table hamesha na barhe).
  Future<void> pruneSynced(int before) => db.delete(
        'sync_queue',
        where: 'syncedAt IS NOT NULL AND syncedAt < ?',
        whereArgs: [before],
      );

  Future<int> pendingCount() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM sync_queue WHERE syncedAt IS NULL');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 10 baar fail ho kar ruki hui entries (Settings > Sync History mein dikhti hain).
  Future<List<SyncQueueEntry>> stuck() async {
    final rows = await db.query(
      'sync_queue',
      where: 'syncedAt IS NULL AND retryCount >= ?',
      whereArgs: [maxAutoRetries],
      orderBy: 'createdAt ASC',
    );
    return rows.map(SyncQueueEntry.fromMap).toList();
  }

  /// "Retry Now": ek stuck entry dobara pending.
  Future<void> resetRetry(int id) => db.update(
        'sync_queue',
        {'retryCount': 0, 'lastError': null},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> resetAllStuck() => db.rawUpdate(
      'UPDATE sync_queue SET retryCount = 0, lastError = NULL WHERE syncedAt IS NULL AND retryCount >= ?',
      [maxAutoRetries]);
}
