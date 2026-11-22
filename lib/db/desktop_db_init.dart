import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows / Linux par sqflite ki jagah FFI SQLite. Android / iOS par kuch nahi karta.
///
/// Zaroori: sqflite_common_ffi ka default folder `.dart_tool/...` (current directory) hota hai — installed
/// app mein wo likhne layak nahi / badalta rehta hai, data gum ho sakta hai. Isliye DB ko user ke
/// AppData (getApplicationSupportDirectory) mein rakhte hain: `%APPDATA%\\<company>\\<app>\\databases`.
///
/// Windows par `<company>\\<app>` exe ke Runner.rc (CompanyName / ProductName) se aata hai. CI ab
/// `Hanna Solutions\\Hanna POS` likhta hai; pehle ke builds `com.example\\ah_developer_kiryana_store` the.
/// Purana folder mile aur naya khaali ho to pehli dafa purana data (DB + settings) copy kar lete hain.
Future<void> initDesktopDatabase() async {
  if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final base = await getApplicationSupportDirectory();
  if (Platform.isWindows) await _migrateLegacyWindowsData(base);
  final dir = Directory(p.join(base.path, 'databases'));
  if (!await dir.exists()) await dir.create(recursive: true);
  await databaseFactory.setDatabasesPath(dir.path);
}

/// Purane (com.example) AppData folder se ek dafa copy. Purana folder mitaya nahi jata (backup ke taur par).
/// Fail ho to app phir bhi khule — bas khaali naya folder istemal hoga.
Future<void> _migrateLegacyWindowsData(Directory base) async {
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return;
    final legacy = Directory(p.join(appData, 'com.example', 'ah_developer_kiryana_store'));
    if (p.equals(p.normalize(legacy.path), p.normalize(base.path))) return;
    if (!await legacy.exists()) return;
    if (!await Directory(p.join(legacy.path, 'databases')).exists()) return;
    // Naye folder mein DB pehle se ho to kuch na chhero (kabhi overwrite nahi).
    if (await Directory(p.join(base.path, 'databases')).exists()) return;
    await _copyDir(legacy, base);
  } catch (_) {}
}

Future<void> _copyDir(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final e in from.list(recursive: false, followLinks: false)) {
    final target = p.join(to.path, p.basename(e.path));
    if (e is Directory) {
      await _copyDir(e, Directory(target));
    } else if (e is File) {
      if (!await File(target).exists()) await e.copy(target);
    }
  }
}
