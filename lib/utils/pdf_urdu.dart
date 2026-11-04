import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/widgets.dart' as pw;

/// PDF mein Urdu (Noto Nastaliq) — `pdf` library font ke GSUB jorne ke qaide nahi chalati, is liye
/// har huroof alag alag chhapte the. Hal: Urdu wala text Flutter ke TextPainter (jo Noto Nastaliq ko
/// sahi jorta hai, bilkul screen jaisa) se tasveer bana kar PDF mein lagate hain.
///
/// Istemal (do pass):
///   1. widgets banate waqt `UrduPdf.widget(...)` — jo text abhi render nahi hua use yaad rakh leta hai
///      (null lautata hai, caller plain `pw.Text` lagaye).
///   2. `await UrduPdf.flush()` — yaad rakhe hue sab text tasveer bana leta hai.
///   3. widgets dobara banayein — ab `widget(...)` tasveer wala widget deta hai.
class UrduPdf {
  UrduPdf._();

  static const String family = 'NotoNastaliqUrdu';
  // Tasveer _scale x bari banti hai, PDF mein chhoti dikhti hai => saaf. 3x kaafi saaf hai aur 4x se kam RAM leta hai.
  // Lean mode (RAM kam padne par dobara koshish): 2x.
  static const double _normalScale = 3;
  static const double _leanScale = 2;
  static double _scale = _normalScale;

  /// Ek tasveer ke pixel is se zyada hon to wo text tasveer nahi banta (aam pw.Text par chhoot jata hai) —
  /// ek ajeeb lamba text poori RAM na kha jaye.
  static const int _maxPixels = 1500000;

  /// true => 2x tasveerein (kam RAM). Scale badalne par purani tasveerein hata di jati hain.
  static void setLean(bool lean) {
    final next = lean ? _leanScale : _normalScale;
    if (next == _scale) return;
    _scale = next;
    _cache.clear();
    _pending.clear();
  }

  /// Yaad rakhi hui tasveerein chhor do (RAM wapas).
  static void clearCache() {
    _cache.clear();
    _pending.clear();
  }
  static final RegExp _urdu = RegExp(r'[\u0590-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]');

  static bool hasUrdu(String s) => _urdu.hasMatch(s);

  static final Map<String, _Rendered> _cache = {};
  static final Map<String, _Req> _pending = {};

  static String _key(String t, double size, int argb, bool bold) => '$size|$argb|$bold|$t';

  /// Urdu na ho to null (caller `pw.Text` lagaye). Urdu ho to tasveer wala widget, ya (abhi render nahi hua)
  /// null aur text pending list mein.
  static pw.Widget? widget(String text, {required double fontSize, required int argb, bool bold = false}) {
    final t = text.trim();
    if (t.isEmpty || !hasUrdu(t)) return null;
    final k = _key(t, fontSize, argb, bold);
    final r = _cache[k];
    if (r == null) {
      _pending[k] = _Req(t, fontSize, argb, bold);
      return null;
    }
    final rtl = _isRtlFirst(t);
    return pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      child: pw.Image(r.image, width: r.width / r.scale, height: r.height / r.scale),
    );
  }

  static bool _isRtlFirst(String t) {
    for (final u in t.runes) {
      if (u < 0x80) {
        final isLetter = (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
        if (isLetter) return false;
        continue;
      }
      if (_urdu.hasMatch(String.fromCharCode(u))) return true;
    }
    return false;
  }

  /// Pending text ki tasveerein bana kar cache mein rakh deta hai.
  static Future<void> flush() async {
    final todo = Map<String, _Req>.of(_pending);
    _pending.clear();
    for (final e in todo.entries) {
      try {
        final r = await _render(e.value).timeout(const Duration(seconds: 5));
        if (r != null) _cache[e.key] = r;
      } catch (_) {
        // render na ho paye to caller ka plain text rehta hai.
      }
    }
  }

  static Future<_Rendered?> _render(_Req q) async {
    final rtl = _isRtlFirst(q.text);
    final tp = TextPainter(
      text: TextSpan(
        text: q.text,
        style: TextStyle(
          color: ui.Color(q.argb),
          fontSize: q.fontSize * _scale,
          fontWeight: q.bold ? FontWeight.w700 : FontWeight.w400,
          fontFamily: family,
          fontFamilyFallback: const ['Roboto'],
        ),
      ),
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    )..layout();
    final pad = 2.0 * _scale;
    final w = (tp.width + pad * 2).ceil();
    final h = (tp.height + pad * 2).ceil();
    if (w * h > _maxPixels) return null;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    tp.paint(canvas, ui.Offset(pad, pad));
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) return null;
    return _Rendered(pw.MemoryImage(data.buffer.asUint8List()), w.toDouble(), h.toDouble(), _scale);
  }
}

class _Req {
  final String text;
  final double fontSize;
  final int argb;
  final bool bold;
  const _Req(this.text, this.fontSize, this.argb, this.bold);
}

class _Rendered {
  final pw.MemoryImage image;
  final double width, height;
  final double scale;
  const _Rendered(this.image, this.width, this.height, this.scale);
}
