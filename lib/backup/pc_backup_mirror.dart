import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// PC (Windows): har backup ki ek copy DUSRI drive / partition par (jaise `D:\Hanna POS Backups`),
/// taa ke Windows kharab ho, format ho ya dobara install ho to bhi backup bacha rahe.
///
/// - Asal backup pehle jaisa `Documents\IBTISAAM POS Backups` (C:) mein banta hai; ye sirf extra copy.
/// - Folder na chuna ho to app khud C: (Windows wali drive) ke ilawa pehli drive dhoondti hai (D:, E: …).
/// - Settings › "Backup ki copy (dusri drive)" se folder badal sakte hain.
/// - Sab best-effort: copy fail ho (drive nikal di, jagah nahi) to asal backup par asar nahi.
class PcBackupMirror {
  PcBackupMirror._();

  static const folderName = 'Hanna POS Backups';

  /// Dusri drive par itni copies rakho (purani mitao — drive bhar na jaye).
  static const keepCopies = 60;

  static const _kDir = 'pc_backup_mirror_dir';
  static const _kOff = 'pc_backup_mirror_off';
  static const _kLastAt = 'pc_backup_mirror_last_ms';
  static const _kLastError = 'pc_backup_mirror_last_error';

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Windows wali drive, jaise "C:".
  static String get systemDrive => (Platform.environment['SystemDrive'] ?? 'C:').toUpperCase();

  static bool isOnSystemDrive(String path) => path.toUpperCase().startsWith(systemDrive);

  /// Settings UI ke liye: copy hone par badalta hai.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<bool> isOff() async => (await SharedPreferences.getInstance()).getBool(_kOff) ?? false;

  /// Copy ka folder (chuna hua, warna khud dhoonda hua). Band ya koi drive nahi => null.
  static Future<String?> folder() async {
    if (!supported) return null;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kOff) ?? false) return null;
    final saved = prefs.getString(_kDir);
    if (saved != null && saved.isNotEmpty) return saved;
    final auto = await _autoFolder();
    if (auto != null) await prefs.setString(_kDir, auto);
    return auto;
  }

  /// D: se Z: tak pehli drive (Windows wali ke ilawa) jahan likh sakein.
  static Future<String?> _autoFolder() async {
    final sys = systemDrive.isEmpty ? 'C' : systemDrive[0];
    for (var c = 'D'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final letter = String.fromCharCode(c);
      if (letter == sys) continue;
      final root = '$letter:\\';
      try {
        if (!await Directory(root).exists()) continue;
        final dir = Directory(p.join(root, folderName));
        await dir.create(recursive: true);
        final probe = File(p.join(dir.path, '.write_test'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return dir.path;
      } catch (_) {
        continue; // CD drive / sirf-parhne wali / bharee hui
      }
    }
    return null;
  }

  static Future<void> setFolder(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDir, path);
    await prefs.setBool(_kOff, false);
    changed.value++;
  }

  static Future<void> setOff(bool off) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOff, off);
    changed.value++;
  }

  static Future<DateTime?> lastCopyAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_kLastAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<String?> lastError() async => (await SharedPreferences.getInstance()).getString(_kLastError);

  /// [backup] ki copy folder mein (BackupHelper har kamyab backup ke baad bulata hai). Kamyab => copy ka File.
  static Future<File?> copy(File backup) async {
    if (!supported) return null;
    final prefs = await SharedPreferences.getInstance();
    try {
      final dirPath = await folder();
      if (dirPath == null) return null;
      final dir = Directory(dirPath);
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, p.basename(backup.path)));
      final tmp = File('${dest.path}.part');
      await backup.copy(tmp.path);
      if (await tmp.length() != await backup.length()) {
        await tmp.delete();
        throw const FileSystemException('Copy adhoori rahi');
      }
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
      await _prune(dir);
      await prefs.setInt(_kLastAt, DateTime.now().millisecondsSinceEpoch);
      await prefs.remove(_kLastError);
      changed.value++;
      return dest;
    } catch (e) {
      await prefs.setString(_kLastError, e.toString());
      changed.value++;
      return null;
    }
  }

  /// Purani copies (sirf hamari backup files) [keepCopies] se zyada hon to mitao.
  static Future<void> _prune(Directory dir) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File) {
        final name = p.basename(e.path);
        if (name.startsWith('IBTISAAM_') && name.endsWith('.ibbackup')) files.add(e);
      }
    }
    if (files.length <= keepCopies) return;
    final stamps = <String, DateTime>{};
    for (final f in files) {
      stamps[f.path] = await f.lastModified();
    }
    files.sort((a, b) => stamps[b.path]!.compareTo(stamps[a.path]!));
    for (final f in files.skip(keepCopies)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// Folder Windows Explorer mein kholo.
  static Future<void> openFolder() async {
    final dir = await folder();
    if (dir == null) return;
    try {
      await Process.run('explorer', [dir]);
    } catch (_) {}
  }
}
