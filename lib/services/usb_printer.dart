import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android USB (host mode) thermal printer — Kotlin PrinterHelper ka USB hissa.
/// Plugin nahi: MainActivity mein MethodChannel "ah_developer/usb" (tools/android_fix.sh likhta hai).
/// Address format: `usb:<vendorId>:<productId>` (deviceName replug par badal jata hai, vid:pid nahi).
class UsbPrinterInfo {
  final int vid;
  final int pid;
  final String name;
  const UsbPrinterInfo(this.vid, this.pid, this.name);

  String get address => UsbPrinter.address(vid, pid);
}

class UsbPrinter {
  UsbPrinter._();
  static const _channel = MethodChannel('ah_developer/usb');
  static const prefix = 'usb:';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static bool isUsb(String addr) => addr.startsWith(prefix);

  static String address(int vid, int pid) => '$prefix$vid:$pid';

  /// `usb:1155:22304` => (1155, 22304). Ghalat format => null.
  static ({int vid, int pid})? parse(String addr) {
    if (!isUsb(addr)) return null;
    final parts = addr.substring(prefix.length).split(':');
    if (parts.length != 2) return null;
    final vid = int.tryParse(parts[0]);
    final pid = int.tryParse(parts[1]);
    if (vid == null || pid == null || vid < 0 || pid < 0) return null;
    return (vid: vid, pid: pid);
  }

  /// Jude hue USB devices jin mein bulk OUT endpoint ho (printer).
  static Future<List<UsbPrinterInfo>> list() async {
    if (!supported) return [];
    try {
      final raw = await _channel.invokeListMethod<Map>('list') ?? [];
      return [
        for (final m in raw)
          UsbPrinterInfo(m['vid'] as int, m['pid'] as int, (m['name'] as String?) ?? 'USB printer'),
      ];
    } catch (e) {
      debugPrint('usb list failed: $e');
      return [];
    }
  }

  /// System "Allow app to access USB device" dialog (pehle se mili ho to seedha true).
  static Future<bool> requestPermission(int vid, int pid) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('permission', {'vid': vid, 'pid': pid}) ?? false;
    } catch (e) {
      debugPrint('usb permission failed: $e');
      return false;
    }
  }

  static Future<bool> open(int vid, int pid) async {
    try {
      return await _channel.invokeMethod<bool>('open', {'vid': vid, 'pid': pid}) ?? false;
    } catch (e) {
      debugPrint('usb open failed: $e');
      return false;
    }
  }

  /// Kotlin side 4096-byte tukron mein bulkTransfer karta hai.
  static Future<bool> write(Uint8List bytes) async {
    try {
      return await _channel.invokeMethod<bool>('write', {'bytes': bytes}) ?? false;
    } catch (e) {
      debugPrint('usb write failed: $e');
      return false;
    }
  }

  static Future<void> close() async {
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
  }
}
