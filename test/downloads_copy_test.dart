import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/backup/downloads_copy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(DownloadsCopy.channel, null));

  test('channel ko path, fileName aur folder milte hain', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(DownloadsCopy.channel, (call) async {
      seen = call;
      return true;
    });
    final ok = await DownloadsCopy.copy(File('/tmp/x/backup_1.ibbackup'),
        folder: 'IBTISAAM POS Backups', android: true);
    expect(ok, isTrue);
    expect(seen!.method, 'copyToDownloads');
    expect(seen!.arguments, {
      'path': '/tmp/x/backup_1.ibbackup',
      'fileName': 'backup_1.ibbackup',
      'folder': 'IBTISAAM POS Backups',
    });
  });

  test('channel na ho (MissingPlugin) => false, crash nahi', () async {
    final ok = await DownloadsCopy.copy(File('/tmp/a.ibbackup'), folder: 'F', android: true);
    expect(ok, isFalse);
  });

  test('native error / false => false', () async {
    messenger.setMockMethodCallHandler(DownloadsCopy.channel, (call) async {
      throw PlatformException(code: 'fail');
    });
    expect(await DownloadsCopy.copy(File('/tmp/a'), folder: 'F', android: true), isFalse);
    messenger.setMockMethodCallHandler(DownloadsCopy.channel, (call) async => false);
    expect(await DownloadsCopy.copy(File('/tmp/a'), folder: 'F', android: true), isFalse);
  });

  test('Android ke ilawa koi channel call nahi', () async {
    var called = false;
    messenger.setMockMethodCallHandler(DownloadsCopy.channel, (call) async {
      called = true;
      return true;
    });
    expect(await DownloadsCopy.copy(File('/tmp/a'), folder: 'F', android: false), isFalse);
    expect(called, isFalse);
  });
}
