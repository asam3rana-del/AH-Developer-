import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import 'app_database.dart';

/// UserDao + AppSettingDao (Kotlin) ka Flutter roop.
/// TODO(Phase 10): har upsert par SyncQueueHelper.enqueueUser.
class UserRepository {
  UserRepository._();
  static final UserRepository instance = UserRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<User?> find(String username) async {
    final rows = await (await _db).query('users', where: 'username = ?', whereArgs: [username], limit: 1);
    return rows.isEmpty ? null : User.fromMap(rows.first);
  }

  Future<List<User>> all() async {
    final rows = await (await _db).query('users', orderBy: 'username');
    return rows.map(User.fromMap).toList();
  }

  Future<void> upsert(User u) async {
    await (await _db).insert('users', u.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String username) async {
    await (await _db).delete('users', where: 'username = ?', whereArgs: [username]);
  }

  /// Username badalna: naya upsert + purana delete ek transaction mein.
  Future<void> rename(User old, User updated) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('users', updated.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      if (updated.username != old.username) {
        await txn.delete('users', where: 'username = ?', whereArgs: [old.username]);
      }
    });
  }

  Future<void> insertAudit(String username, String action, String reference, String details) async {
    await (await _db).insert('audit', {
      'username': username,
      'action': action,
      'reference': reference,
      'details': details,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<String?> getSetting(String key) async {
    final rows = await (await _db).query('app_settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await (await _db).insert('app_settings', AppSetting(key, value).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
