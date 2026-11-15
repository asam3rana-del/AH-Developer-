import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import 'app_database.dart';
import '../sync/sync_queue_helper.dart';

/// UserDao + AppSettingDao (Kotlin) ka Flutter roop.
/// Phase 10: user/app_setting writes SyncQueueHelper se sync_queue mein jaate hain.
class UserRepository {
  UserRepository._();
  static final UserRepository instance = UserRepository._();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<User?> find(String username) async {
    final db = await _db;
    var rows = await db.query('users', where: 'username = ?', whereArgs: [username], limit: 1);
    // Kotlin se aaye users: "Asam" / "asam" ka farq na ho — pehle exact, warna bari/chhoti harf nazar-andaz.
    if (rows.isEmpty && username.isNotEmpty) {
      rows = await db.query('users', where: 'username = ? COLLATE NOCASE', whereArgs: [username], limit: 1);
    }
    return rows.isEmpty ? null : User.fromMap(rows.first);
  }

  /// Kotlin `findByPhone`: `phone = ? AND active = 1` (OTP login). Khali phone kabhi match nahi.
  Future<User?> findByPhone(String phone) async {
    if (phone.trim().isEmpty) return null;
    final rows = await (await _db)
        .query('users', where: 'phone = ? AND active = 1', whereArgs: [phone.trim()], limit: 1);
    return rows.isEmpty ? null : User.fromMap(rows.first);
  }

  /// Kotlin `activeCount` + `soleActiveUserOrNull`: active users (OTP ke pehle phone-link ke liye).
  Future<List<User>> activeUsers() async {
    final rows = await (await _db).query('users', where: 'active = 1', orderBy: 'username');
    return rows.map(User.fromMap).toList();
  }

  Future<List<User>> all() async {
    final rows = await (await _db).query('users', orderBy: 'username');
    return rows.map(User.fromMap).toList();
  }

  /// User row + sync_queue ek transaction mein (Kotlin `SyncQueueHelper.enqueueUser`). passwordHash sync
  /// nahi hota (userPayload mein nahi).
  Future<void> upsert(User u) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('users', u.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      await SyncQueueHelper.enqueueUser(txn, u.username);
    });
  }

  Future<void> delete(String username) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('users', where: 'username = ?', whereArgs: [username]);
      await SyncQueueHelper.enqueueDelete(txn, 'user', SyncQueueHelper.userEntityId(username));
    });
  }

  /// Username badalna: naya upsert + purana delete (tombstone) ek transaction mein.
  Future<void> rename(User old, User updated) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('users', updated.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      await SyncQueueHelper.enqueueUser(txn, updated.username);
      if (updated.username != old.username) {
        await txn.delete('users', where: 'username = ?', whereArgs: [old.username]);
        await SyncQueueHelper.enqueueDelete(txn, 'user', SyncQueueHelper.userEntityId(old.username));
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

  /// Sirf `SyncQueueHelper.syncedAppSettingKeys` (shop_name, receipt_footer ...) queue hoti hain;
  /// baaqi (printer, login_method ...) device-specific hain — enqueueAppSetting unhein chhod deta hai.
  Future<void> setSetting(String key, String value) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('app_settings', AppSetting(key, value).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await SyncQueueHelper.enqueueAppSetting(txn, key, value);
    });
  }
}
