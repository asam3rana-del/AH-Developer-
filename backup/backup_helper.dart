import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../sync/device_tag.dart';
import '../sync/sync_repository.dart';
import 'backup_crypto.dart';
import 'downloads_copy.dart';
import 'backup_password_store.dart';
import 'kotlin_import.dart';

/// Mirrors BackupHelper.kt — live SQLite DB ka encrypted backup / safe restore.
///
/// * Backup: `IBTISAAM_<deviceTag>_backup_<yyyy-MM-dd_HH-mm>.ibbackup` (IBB1 AES-GCM,
///   Android jaisa format), app ke apne folder `IBTISAAM POS Backups` mein.
/// * Restore: temp file -> decrypt/copy -> SQLite header + schema check -> tabhi live DB badalti hai
///   (Kotlin audit #3 fix). Ghalat password / kharab file par live DB bilkul nahi chhuti.
/// * Purane "IBAKV001" (AES-CBC) aur plain `.db` backups bhi restore ho jate hain.
///
/// Farq (Kotlin se):
///  * Public Downloads ki extra copy `DownloadsCopy` (chhota native MediaStore channel, MainActivity mein
///    `tools/android_fix.sh` se) — sirf jab app screen par ho (WorkManager ke background isolate mein
///    channel nahi hota, wahan copy chhod di jati hai). Share button hamesha kaam karta hai.
///  * Restore se pehle (agar live DB maujood ho) ek safety backup ban-ta hai; wo na bane to restore ruk jata hai.
///  * Restore ke waqt schema check: zaroori tables ho + `user_version` is app se naya na ho.
class BackupHelper {
  BackupHelper._();

  static String? lastError;

  /// Kotlin app ka backup import hua ho to uska khulasa (UI "Restore complete" mein dikhata hai); warna null.
  static String? lastImportSummary;

  static const folderName = 'IBTISAAM POS Backups';
  static const backupExtension = 'ibbackup';
  static const _lastBackupKey = 'backup_throttle_last_backup_at_millis';

  // Kotlin `SQLITE_HEADER`: "SQLite format 3\u0000"
  static const List<int> _sqliteHeader = [
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];

  /// Restore ke baad app is DB ko chala sake — in tables ka hona zaroori hai.
  static const _requiredTables = <String>{
    'products', 'customers', 'suppliers', 'sales', 'sale_items', 'purchases',
    'purchase_items', 'payments', 'expenses', 'cash_transactions', 'users',
  };

  static bool _busy = false;

  /// Backup ya restore chal raha ho to true (scheduler dobara na chalaye).
  static bool get isBusy => _busy;

  // ---------------- device tag ----------------

  /// Kotlin `DeviceTag.current` — sync wala hi tag (pehle yahan alag random tag banta tha).
  /// `init()` dobara bulana safe hai; background isolate mein bhi sahi tag milta hai.
  static Future<String> deviceTag() async {
    await DeviceTag.init();
    return DeviceTag.current;
  }

  // ---------------- folders / listing ----------------

  static Future<Directory> backupFolder() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory(); // Android/data/<pkg>/files (permission nahi)
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, folderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// App folder ke backups, sab se naya pehle. Purane plain `.db` bhi shamil.
  static Future<List<File>> listBackups() async {
    final dir = await backupFolder();
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File) {
        final ext = p.extension(e.path).toLowerCase();
        if (ext == '.$backupExtension' || ext == '.db') files.add(e);
      }
    }
    final stamps = <String, DateTime>{};
    for (final f in files) {
      stamps[f.path] = await f.lastModified();
    }
    files.sort((a, b) => stamps[b.path]!.compareTo(stamps[a.path]!));
    return files;
  }

  /// Password chahiye? (sirf header dekhta hai.)
  static Future<bool> needsPassword(File file) async =>
      await BackupCrypto.isEncryptedBackup(file) || await BackupCrypto.isLegacyEncryptedBackup(file);

  // ---------------- backup ----------------

  /// Live DB ka WAL checkpoint kar ke encrypted copy banata hai. Null => fail (dekhein [lastError]).
  static Future<File?> backupNow() async {
    if (_busy) {
      lastError = 'Doosra backup / restore chal raha hai';
      return null;
    }
    _busy = true;
    try {
      return await _backupNowUnlocked();
    } catch (e) {
      lastError = e.toString();
      return null;
    } finally {
      _busy = false;
    }
  }

  static Future<File?> _backupNowUnlocked() async {
    final dbFile = File(await AppDatabase.instance.databasePath);
    if (!await dbFile.exists()) return null;

    // Kotlin FIX: WAL ka data main .db mein aaye, warna taaza entries backup se reh jati hain.
    try {
      await AppDatabase.instance.checkpointWal();
    } catch (_) {}

    final stamp = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final tag = await deviceTag();
    final fileName = 'IBTISAAM_${tag}_backup_$stamp.$backupExtension';
    final password = await BackupPasswordStore.getOrCreate();
    final dest = File(p.join((await backupFolder()).path, fileName));
    await BackupCrypto.encryptFile(dbFile, dest, password);
    // Kotlin copyToDownloads: public Downloads/<folderName> mein extra copy (best-effort, fail par backup theek rehta hai).
    await DownloadsCopy.copy(dest, folder: folderName, fileName: fileName);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastBackupKey, DateTime.now().millisecondsSinceEpoch);
    return dest;
  }

  /// Pichla backup [minGapMinutes] se kam pehle hua ho to skip (null) — app-close trigger ke liye.
  static Future<File?> backupIfDue({int minGapMinutes = 30}) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastBackupKey) ?? 0;
    final gap = minGapMinutes * 60000;
    if (DateTime.now().millisecondsSinceEpoch - last < gap) return null;
    return backupNow();
  }

  /// Backup file ko share sheet (Drive / WhatsApp / Gmail ...) se bhejta hai.
  static Future<bool> shareBackup(File file) async {
    try {
      await Share.shareXFiles([XFile(file.path)], subject: 'IBTISAAM POS backup');
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  // ---------------- restore ----------------

  /// App folder ki file se restore. [pass] encrypted backup ke liye zaroori.
  static Future<bool> restore(File backupFile, {String? pass}) => _restoreGuarded(backupFile, pass);

  /// File picker se chuni file (cache path) se restore — chuni hui file baad mein hata di jati hai.
  static Future<bool> restoreFromPath(String pickedPath, {String? pass}) async {
    final picked = File(pickedPath);
    if (!await picked.exists()) {
      lastError = 'Backup file khul nahi saki';
      return false;
    }
    try {
      return await _restoreGuarded(picked, pass);
    } finally {
      // Sirf cache/temp mein rakhi hui copy hatayein; user ki asal file ko haath nahi lagate.
      final tmp = (await getTemporaryDirectory()).path;
      if (p.isWithin(tmp, pickedPath)) {
        try {
          await picked.delete();
        } catch (_) {}
      }
    }
  }

  static Future<bool> _restoreGuarded(File backupFile, String? pass) async {
    if (_busy) {
      lastError = 'Doosra backup / restore chal raha hai';
      return false;
    }
    _busy = true;
    try {
      return await _restoreSafely(backupFile, pass);
    } catch (e) {
      lastError = e is BackupCryptoException ? e.message : e.toString();
      return false;
    } finally {
      _busy = false;
    }
  }

  static Future<bool> _restoreSafely(File backupFile, String? pass) async {
    lastError = null;
    lastImportSummary = null;
    final dbPath = await AppDatabase.instance.databasePath;
    final dbFile = File(dbPath);
    final temp = File('$dbPath.restore_tmp');
    try {
      final encrypted = await BackupCrypto.isEncryptedBackup(backupFile);
      final legacy = !encrypted && await BackupCrypto.isLegacyEncryptedBackup(backupFile);

      if (encrypted || legacy) {
        if (pass == null || pass.isEmpty) {
          lastError = 'Password chahiye';
          return false;
        }
        if (encrypted) {
          await BackupCrypto.decryptFile(backupFile, temp, pass);
        } else {
          await BackupCrypto.decryptLegacyFile(backupFile, temp, pass);
        }
      } else {
        await backupFile.copy(temp.path);
      }

      if (!await _isValidSqliteDb(temp)) {
        lastError = 'Backup file corrupt hai ya password ghalat hai';
        await _deleteQuietly(temp);
        return false;
      }
      // Kotlin (Room) app ka backup: user_version 48 aur alag columns hain, isliye file badalne ki jagah
      // uska data column-by-column Flutter DB mein copy karte hain (KotlinBackupImporter).
      if (await KotlinBackupImporter.isRoomDatabase(temp.path)) {
        return await _importKotlinBackup(temp, dbFile);
      }

      final schemaError = await _schemaError(temp.path);
      if (schemaError != null) {
        lastError = schemaError;
        await _deleteQuietly(temp);
        return false;
      }

      // Live DB maujood ho to pehle uska encrypted safety backup (na bane to restore ruk jaye).
      if (await dbFile.exists()) {
        _busy = false; // backupNow() apna lock khud leta hai
        final safety = await backupNow();
        _busy = true;
        if (safety == null) {
          lastError = 'Restore se pehle safety backup nahi ban saka: ${lastError ?? ''}'.trim();
          await _deleteQuietly(temp);
          return false;
        }
      }

      // Sab check paas — ab hi live DB band kar ke badalte hain.
      await AppDatabase.instance.close();
      await _deleteQuietly(File('$dbPath-wal'));
      await _deleteQuietly(File('$dbPath-shm'));
      await _deleteQuietly(File('$dbPath-journal'));
      try {
        await temp.rename(dbPath); // same folder => atomic
      } catch (_) {
        await temp.copy(dbPath);
        await _deleteQuietly(temp);
      }
      await _resetSyncCheckpoint();
      return true;
    } catch (e) {
      lastError = e is BackupCryptoException ? e.message : e.toString();
      await _deleteQuietly(temp);
      return false;
    }
  }

  /// Kotlin backup ka data live DB mein copy. Pehle safety backup; import transaction mein — fail => live data same.
  static Future<bool> _importKotlinBackup(File temp, File dbFile) async {
    try {
      if (await dbFile.exists()) {
        _busy = false; // backupNow() apna lock khud leta hai
        final safety = await backupNow();
        _busy = true;
        if (safety == null) {
          lastError = 'Import se pehle safety backup nahi ban saka: ${lastError ?? ''}'.trim();
          await _deleteQuietly(temp);
          return false;
        }
      }
      final live = await AppDatabase.instance.database;
      final report = await KotlinBackupImporter.importInto(live, temp.path);
      lastImportSummary = report.summary();
      // Import ke baad password nahi maanga jayega (user ki request): login skip flag.
      await live.insert('app_settings', {'key': 'skip_login', 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await live.insert('app_settings', {'key': 'admin_seeded', 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await _deleteQuietly(temp);
      await _resetSyncCheckpoint();
      return true;
    } catch (e) {
      lastError = e is KotlinImportException ? e.message : e.toString();
      await _deleteQuietly(temp);
      return false;
    }
  }

  /// Restore/import ke baad pull checkpoint 0: purana data aaya hai, is liye server ka naya data
  /// dobara pull hona chahiye (apply idempotent hai; pending edits ki guards wahi). Fail par nazar-andaz.
  static Future<void> _resetSyncCheckpoint() async {
    try {
      await SyncRepository.resetSyncCheckpoint(0);
    } catch (_) {}
  }

  static Future<bool> _isValidSqliteDb(File file) async {
    try {
      if (await file.length() < _sqliteHeader.length) return false;
      final raf = await file.open();
      try {
        final Uint8List head = await raf.read(_sqliteHeader.length);
        if (head.length != _sqliteHeader.length) return false;
        for (var i = 0; i < head.length; i++) {
          if (head[i] != _sqliteHeader[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Null => theek. Warna insani paighaam. Temp DB read-only khol kar dekhta hai (live DB nahi).
  static Future<String?> _schemaError(String path) async {
    Database? db;
    try {
      db = await openDatabase(path, readOnly: true, singleInstance: false);
      final check = await db.rawQuery('PRAGMA quick_check');
      if (check.isEmpty || check.first.values.first.toString().toLowerCase() != 'ok') {
        return 'Backup ka database kharab hai';
      }
      final ver = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
      if (ver > AppDatabase.schemaVersion) {
        return 'Ye backup is app se naye version ka hai (v$ver) — pehle app update karein [E-KTIMPORT-OFF]';
      }
      final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      final have = rows.map((r) => r['name'].toString()).toSet();
      final missing = _requiredTables.where((t) => !have.contains(t)).toList();
      if (missing.isNotEmpty) {
        return 'Ye backup is app ke database se match nahi karta (missing: ${missing.join(', ')})';
      }
      return null;
    } catch (e) {
      return 'Backup file parhi nahi ja saki: $e';
    } finally {
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
