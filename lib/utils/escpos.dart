import 'dart:typed_data';

/// ESC/POS helpers (Kotlin PrinterHelper ke constants + bitmapToEscPosRasterChunks).
/// Bluetooth/USB printer ko data bhejne ki raftar. Sasti 58mm printers ka buffer chhota hota hai:
/// data tez aaye to bytes raste mein gir jate hain, printer raster command ka beech bhool jata hai
/// aur baqi bytes text samajh kar Chinese/CJK jaisa kachra chhap deta hai.
/// `safe` = chhoti strips + lambe pause (Kotlin PrinterHelper ke "agla qadam" wale values).
class PrintPacing {
  final int stripHeightPx;
  final int minDelayMs;
  final double msPerRow;
  final int pieceBytes;
  final int pieceGapMs;
  const PrintPacing({
    required this.stripHeightPx,
    required this.minDelayMs,
    required this.msPerRow,
    required this.pieceBytes,
    required this.pieceGapMs,
  });

  /// Pehle wale (Kotlin FIX 5) values.
  static const normal = PrintPacing(stripHeightPx: 24, minDelayMs: 200, msPerRow: 10, pieceBytes: 128, pieceGapMs: 20);

  /// Garbled / Chinese print ke liye: 16px strips, 64-byte tukde, lambe pause.
  static const safe = PrintPacing(stripHeightPx: 16, minDelayMs: 300, msPerRow: 14, pieceBytes: 64, pieceGapMs: 35);

  int delayFor(int stripHeight) {
    final scaled = (stripHeight * msPerRow).toInt();
    return scaled > minDelayMs ? scaled : minDelayMs;
  }
}

class EscPos {
  EscPos._();

  static final Uint8List init = Uint8List.fromList([0x1B, 0x40]);
  // 1 line feed + GS V 1 (partial cut) — Kotlin FEED_AND_CUT.
  static final Uint8List feedAndCut = Uint8List.fromList([0x0A, 0x1D, 0x56, 0x01]);

  /// Kotlin `printText` payload: init + plain text + feed/cut. Text sirf ASCII (English) chhapta hai —
  /// baqi characters '?' ban jate hain (Kotlin UTF-8 bhejta tha jo zyadatar thermal printers par kachra chhapta hai).
  /// Urdu / unicode ke liye raster print (receipt_renderer) use hota hai.
  static Uint8List textPayload(String text) {
    final out = <int>[...init];
    for (final u in text.replaceAll('\r\n', '\n').codeUnits) {
      if (u == 0x0A || (u >= 0x20 && u <= 0x7E)) {
        out.add(u);
      } else if (u == 0x09) {
        out.add(0x20);
      } else {
        out.add(0x3F);
      }
    }
    out.addAll(feedAndCut);
    return Uint8List.fromList(out);
  }

  /// Kotlin `testPrint` ka plain-text slip (32 columns, 58mm).
  static String testText({String shopName = '', String connection = 'BLUETOOTH'}) {
    final name = shopName.trim().isEmpty ? 'IBTISAAM Kiryana Store' : shopName.trim();
    return '================================\n'
        '       TEST PRINT - 58mm\n'
        '================================\n'
        '$name\n'
        'Printer connected successfully.\n'
        'Connection: $connection\n'
        '--------------------------------\n\n\n';
  }

  static const int defaultDotsWidth = 384;
  static const int minDotsWidth = 256;
  static const int maxDotsWidth = 576;

  // Pacing (Kotlin FIX 5 values — chhoti strips, lambe pause).
  static const int maxStripHeightPx = 24;
  static const int minInterChunkDelayMs = 200;
  static const double msPerStripRow = 10;
  static const int settleDelayMs = 150;
  static const int btWritePieceBytes = 128;
  static const int btWritePieceGapMs = 20;
  // Connect ke baad printer ko tayyar hone ka waqt, aur aakhri feed/cut ke baad socket band karne se pehle
  // ka intezar — warna connection foran band hone par printer ke buffer ka baqi bill (neeche ka hissa) kat jata hai.
  static const int connectSettleDelayMs = 500;
  static const int closeDrainDelayMs = 1500;

  /// Clamp + 8 ka multiple (raster row poore bytes).
  static int normalizeDotsWidth(int? requested) {
    final w = (requested ?? defaultDotsWidth).clamp(minDotsWidth, maxDotsWidth);
    return w - (w % 8);
  }

  static int interChunkDelayMs(int stripHeightPx) {
    final scaled = (stripHeightPx * msPerStripRow).toInt();
    return scaled > minInterChunkDelayMs ? scaled : minInterChunkDelayMs;
  }

  /// "Compatible" mode: GS v 0 ki jagah purana ESC * 33 (24-dot bit image) — har strip 24 rows ki,
  /// ESC 3 24 (line spacing = 24 dots) + ESC * 33 nL nH + data + LF. Zyadatar sasti 58mm printers
  /// isi ko behtar samajhte hain. Height 24 ke multiple tak safed pattiyon se bhari jati hai.
  static List<({Uint8List bytes, int stripHeight})> bitImageChunks(
    Uint8List rgba,
    int width,
    int height, {
    int threshold = 215,
  }) {
    const strip = 24;
    final chunks = <({Uint8List bytes, int stripHeight})>[];
    for (var y0 = 0; y0 < height; y0 += strip) {
      final out = Uint8List(3 + 5 + width * 3 + 1);
      out.setAll(0, [0x1B, 0x33, strip]); // ESC 3 24
      out.setAll(3, [0x1B, 0x2A, 33, width & 0xFF, (width >> 8) & 0xFF]); // ESC * 33 nL nH
      for (var x = 0; x < width; x++) {
        for (var k = 0; k < 3; k++) {
          var b = 0;
          for (var i = 0; i < 8; i++) {
            final y = y0 + k * 8 + i;
            if (y >= height) continue;
            final p = (y * width + x) * 4;
            final a = rgba[p + 3];
            final lum = a == 0 ? 255.0 : rgba[p] * 0.3 + rgba[p + 1] * 0.59 + rgba[p + 2] * 0.11;
            if (lum < threshold) b |= 1 << (7 - i);
          }
          out[8 + x * 3 + k] = b;
        }
      }
      out[out.length - 1] = 0x0A; // LF — line print + 24 dots feed
      chunks.add((bytes: out, stripHeight: strip));
    }
    return chunks;
  }

  /// [rgba] = width*height*4 bytes (dart:ui rawRgba). Luminance < [threshold] => black dot.
  /// Return: (GS v 0 command bytes, strip height) list.
  static List<({Uint8List bytes, int stripHeight})> rasterChunks(
    Uint8List rgba,
    int width,
    int height, {
    int threshold = 215,
    int maxStripHeight = maxStripHeightPx,
  }) {
    final bytesPerRow = (width + 7) ~/ 8;
    final chunks = <({Uint8List bytes, int stripHeight})>[];
    var y = 0;
    while (y < height) {
      final strip = (height - y) < maxStripHeight ? (height - y) : maxStripHeight;
      final out = Uint8List(8 + bytesPerRow * strip);
      out.setAll(0, [
        0x1D, 0x76, 0x30, 0x00,
        bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
        strip & 0xFF, (strip >> 8) & 0xFF,
      ]);
      for (var row = 0; row < strip; row++) {
        final src = (y + row) * width * 4;
        for (var x = 0; x < width; x++) {
          final p = src + x * 4;
          final a = rgba[p + 3];
          // Transparent = white paper.
          final lum = a == 0 ? 255.0 : rgba[p] * 0.3 + rgba[p + 1] * 0.59 + rgba[p + 2] * 0.11;
          if (lum < threshold) {
            final idx = 8 + row * bytesPerRow + (x >> 3);
            out[idx] = out[idx] | (1 << (7 - (x & 7)));
          }
        }
      }
      chunks.add((bytes: out, stripHeight: strip));
      y += strip;
    }
    return chunks;
  }
}
