import 'dart:io';

import 'package:flutter/services.dart';

/// Kotlin `BackupHelper.copyToDownloads` — backup ki ek extra copy public
/// `Downloads/<folder>` mein (Android 10+ par MediaStore, isliye storage permission nahi chahiye).
///
/// Plugin ki jagah chhota native MethodChannel (`tools/android_fix.sh` MainActivity.kt mein likhta hai).
/// Best-effort: channel maujood na ho (iOS / Windows / background isolate jahan Activity ka engine nahi)
/// ya copy fail ho to sirf `false` milta hai — asal backup par koi asar nahi (Kotlin bhi yahi karta hai).
class DownloadsCopy {
  DownloadsCopy._();

  static const MethodChannel channel = MethodChannel('ah_developer/downloads');

  /// [source] ko `Downloads/[folder]/[fileName]` mein copy karta hai. Kamyab => true.
  /// [fileName] na de to source ka apna naam. [android] sirf tests ke liye.
  static Future<bool> copy(
    File source, {
    required String folder,
    String? fileName,
    bool? android,
  }) async {
    if (!(android ?? Platform.isAndroid)) return false;
    try {
      final name = fileName ?? source.uri.pathSegments.last;
      final ok = await channel.invokeMethod<bool>('copyToDownloads', <String, String>{
        'path': source.path,
        'fileName': name,
        'folder': folder,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
