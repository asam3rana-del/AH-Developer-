import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Bluetooth thermal printer — Kotlin PrinterHelper jaisa SEEDHA RFCOMM socket.
/// Plugin (print_bluetooth_thermal) se bhejne par tasveer wale bill tukron mein / adhure chhapte the,
/// jabke Kotlin app isi printer par theek chhapti thi. MainActivity mein MethodChannel "ah_developer/bt"
/// (tools/android_fix.sh likhta hai). Delays printer_service.dart mein hain, yahan sirf connect / write / close.
/// Channel maujood na ho (purani build, iOS) to null lautta hai aur caller plugin par wapas chala jata hai.
class BtPrinter {
  BtPrinter._();
  static const _channel = MethodChannel('ah_developer/bt');
  static bool _missing = false;

  static bool get available => !kIsWeb && Platform.isAndroid && !_missing;

  /// true/false = jawab; null = native channel hai hi nahi.
  static Future<bool?> connect(String mac) async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<bool>('connect', {'mac': mac}) ?? false;
    } on MissingPluginException {
      _missing = true;
      return null;
    } catch (e) {
      debugPrint('bt connect failed: $e');
      return false;
    }
  }

  static Future<bool?> write(Uint8List bytes) async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<bool>('write', {'bytes': bytes}) ?? false;
    } on MissingPluginException {
      _missing = true;
      return null;
    } catch (e) {
      debugPrint('bt write failed: $e');
      return false;
    }
  }

  static Future<void> close() async {
    if (!available) return;
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
  }
}
