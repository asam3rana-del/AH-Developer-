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
Future<void> initDesktopDatabase() async {
  if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'databases'));
  if (!await dir.exists()) await dir.create(recursive: true);
  await databaseFactory.setDatabasesPath(dir.path);
}
