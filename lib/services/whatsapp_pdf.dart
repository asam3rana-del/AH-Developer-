import 'dart:io';

import 'package:flutter/services.dart';

/// PDF seedha customer ke WhatsApp chat mein (number par) khol deta hai — bas "Send" dabana hota hai.
/// Plugin nahi: MainActivity mein MethodChannel "ah_developer/wa" (tools/android_fix.sh likhta hai).
/// Sirf Android. WhatsApp na ho / channel na ho / koi bhi masla => false, aur caller aam share sheet kholta hai.
class WhatsAppPdf {
  WhatsAppPdf._();

  static const MethodChannel channel = MethodChannel('ah_developer/wa');

  /// [digits] = poora international number bina `+` (jaise 923001234567). Chat khul gayi => true.
  static Future<bool> send(File pdf, String digits, {String text = ''}) async {
    if (!Platform.isAndroid || digits.isEmpty) return false;
    try {
      final ok = await channel.invokeMethod<bool>('sendPdf', <String, String>{
        'path': pdf.path,
        'digits': digits,
        'text': text,
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
