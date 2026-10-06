import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart';

import '../utils/receipt_lines.dart';

/// ReceiptLine list -> raw RGBA bitmap (Kotlin renderReceiptLines). TextPainter Urdu/Arabic ki
/// shaping + RTL khud sambhalta hai (Kotlin ko iske liye alag "Arabic boost" chahiye tha).
class ReceiptImage {
  final Uint8List rgba;
  final int width;
  final int height;
  ReceiptImage(this.rgba, this.width, this.height);
}

const _padX = 6.0;
const _rowPadV = 7.0;
const _cellPadH = 8.0;

bool _isRtl(String s) => RegExp(r'[\u0590-\u08FF\uFB50-\uFEFF]').hasMatch(s);

TextPainter _tp(String text, double size, {bool bold = false, TextAlign align = TextAlign.start, double? maxWidth, int? maxLines}) {
  final rtl = _isRtl(text);
  final p = TextPainter(
    text: TextSpan(
      text: text,
      // Urdu: bundled Noto Nastaliq (pubspec fonts) — device ke system font par bharosa nahi.
      // Nastaliq ki apni lambi line-height hoti hai, is liye height null.
      style: TextStyle(
        color: const Color(0xFF000000),
        fontSize: rtl ? size * 0.95 : size,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
        height: rtl ? null : 1.25,
        fontFamily: rtl ? 'NotoNastaliqUrdu' : null,
      ),
    ),
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  );
  p.layout(minWidth: 0, maxWidth: maxWidth ?? double.infinity);
  return p;
}

Future<ReceiptImage> renderReceipt(List<ReceiptLine> lines, {double fontSizePx = 26, int dotsWidth = 384}) async {
  final w = dotsWidth.toDouble();
  final inner = w - _padX * 2;
  final ops = <void Function(Canvas c, double y)>[];
  final heights = <double>[];

  void add(double h, void Function(Canvas c, double y) draw) {
    heights.add(h);
    ops.add(draw);
  }

  final tableFont = fontSizePx * 0.88;
  // Columns: item 40%, qty 20%, rate 17%, amount 23%.
  final cw = [inner * 0.40, inner * 0.20, inner * 0.17, inner * 0.23];

  for (final l in lines) {
    switch (l) {
      case RlCenter():
        final p = _tp(l.text, fontSizePx, bold: l.bold, align: TextAlign.center, maxWidth: inner);
        add(p.height + (l.tight ? 2 : 6), (c, y) => p.paint(c, Offset(_padX + (inner - p.width) / 2, y)));
      case RlLeft():
        final p = _tp(l.text, fontSizePx, maxWidth: inner);
        final rtl = _isRtl(l.text);
        add(p.height + 4, (c, y) => p.paint(c, Offset(rtl ? _padX + inner - p.width : _padX, y)));
      case RlTwoCol():
        final r = _tp(l.right, fontSizePx, bold: l.bold);
        final lp = _tp(l.left, fontSizePx, bold: l.bold, maxWidth: inner - r.width - 8);
        final h = (lp.height > r.height ? lp.height : r.height) + 4;
        add(h, (c, y) {
          lp.paint(c, Offset(_padX, y));
          r.paint(c, Offset(_padX + inner - r.width, y));
        });
      case RlItemRow():
        final hdr = l.header;
        final cells = [l.name, l.qty, l.rate, l.amount];
        final tps = <TextPainter>[];
        for (var i = 0; i < 4; i++) {
          tps.add(_tp(cells[i], tableFont, bold: hdr, maxWidth: cw[i] - _cellPadH, maxLines: i == 0 ? 3 : 1,
              align: i == 0 ? TextAlign.start : TextAlign.right));
        }
        var h = 0.0;
        for (final t in tps) {
          if (t.height > h) h = t.height;
        }
        h += _rowPadV;
        add(h, (c, y) {
          var x = _padX;
          for (var i = 0; i < 4; i++) {
            final t = tps[i];
            final dx = i == 0 ? x : x + cw[i] - _cellPadH / 2 - t.width;
            t.paint(c, Offset(dx, y + _rowPadV / 2));
            x += cw[i];
          }
          if (hdr) {
            c.drawLine(Offset(_padX, y + h - 1), Offset(_padX + inner, y + h - 1), Paint()..color = const Color(0xFF000000)..strokeWidth = 2);
          }
        });
      case RlBlank():
        add(l.heightPx.toDouble(), (c, y) {});
      case RlDivider():
        add(12, (c, y) {
          final paint = Paint()..color = const Color(0xFF000000)..strokeWidth = 2;
          for (var x = _padX; x < _padX + inner; x += 10) {
            c.drawLine(Offset(x, y + 6), Offset(math.min(x + 5, _padX + inner), y + 6), paint);
          }
        });
    }
  }

  final total = heights.fold<double>(0, (s, h) => s + h) + 16;
  final rec = PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, total), Paint()..color = const Color(0xFFFFFFFF));
  var y = 8.0;
  for (var i = 0; i < ops.length; i++) {
    ops[i](canvas, y);
    y += heights[i];
  }
  final img = await rec.endRecording().toImage(dotsWidth, total.ceil());
  final data = await img.toByteData(format: ImageByteFormat.rawRgba);
  final result = ReceiptImage(data!.buffer.asUint8List(), img.width, img.height);
  img.dispose();
  return result;
}
