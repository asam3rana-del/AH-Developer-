import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../utils/pdf_urdu.dart';
import '../utils/slip_pdf_data.dart';

/// [SlipPdfData] ko PDF bana kar share karta hai. Data/raqam sab `utils/slip_pdf_data.dart` mein pehle se
/// likhe hote hain — yahan sirf layout aur file hai. Urdu text `UrduPdf` (Noto Nastaliq tasveer) se chhapta hai.
class SlipPdfService {
  SlipPdfService._();

  static const _teal = PdfColor.fromInt(0xFF0F9B8E);
  static const _navy = PdfColor.fromInt(0xFF2E3242);
  static const _gray = PdfColor.fromInt(0xFF8A90A6);
  static const _line = PdfColor.fromInt(0xFFEEF0F7);

  static pw.Font? _urduFont;

  static Future<pw.Font?> _loadUrduFont() async {
    if (_urduFont != null) return _urduFont;
    for (final path in const [
      'assets/fonts/NotoNaskhArabic-Regular.ttf',
      'assets/fonts/UrduFallback.ttf',
    ]) {
      try {
        _urduFont = pw.Font.ttf(await rootBundle.load(path));
        return _urduFont;
      } catch (_) {}
    }
    return null;
  }

  static PdfColor _color(int? argb) => argb == null ? _navy : PdfColor.fromInt(argb);

  /// Urdu ho to tasveer, warna aam pw.Text.
  static pw.Widget _text(String t, {double size = 10, bool bold = false, int argb = 0xFF2E3242, pw.TextAlign? align}) {
    final img = UrduPdf.widget(t, fontSize: size, argb: argb, bold: bold);
    if (img != null) return img;
    return pw.Text(
      t,
      textAlign: align,
      style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: PdfColor.fromInt(argb)),
    );
  }

  static pw.Widget _kv(SlipKv k) {
    final argb = k.argb ?? 0xFF2E3242;
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(child: _text(k.label, size: 10.5, bold: k.bold, argb: argb)),
        pw.SizedBox(width: 8),
        _text(k.value, size: 10.5, bold: k.bold, argb: argb, align: pw.TextAlign.right),
      ]),
    );
  }

  static pw.Widget _cell(String t, {required bool header, required bool right}) {
    final child = _text(t, size: 9.5, bold: header, argb: header ? 0xFFFFFFFF : 0xFF2E3242, align: right ? pw.TextAlign.right : pw.TextAlign.left);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Align(alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft, child: child),
    );
  }

  static pw.Widget _block(SlipBlock b) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        if (b.heading != null && b.heading!.isNotEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4), child: _text(b.heading!, size: 11.5, bold: true, argb: 0xFF0F9B8E)),
        if (b.hasTable)
          pw.Table(
            columnWidths: {
              for (var i = 0; i < b.headers.length; i++)
                i: pw.FlexColumnWidth(i < b.weights.length ? b.weights[i] : 1),
            },
            border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.6)),
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: _teal),
                children: [for (var i = 0; i < b.headers.length; i++) _cell(b.headers[i], header: true, right: i >= b.rightFrom)],
              ),
              for (final r in b.rows)
                pw.TableRow(
                  children: [for (var i = 0; i < b.headers.length; i++) _cell(i < r.length ? r[i] : '', header: false, right: i >= b.rightFrom)],
                ),
            ],
          ),
        if (b.lines.isNotEmpty) ...[
          if (b.hasTable) pw.SizedBox(height: 4),
          for (final l in b.lines) _kv(l),
        ],
      ]),
    );
  }

  static List<pw.Widget> _widgets(SlipPdfData d) => [
        if (d.shopName.trim().isNotEmpty)
          pw.Center(child: _text(d.shopName.trim(), size: 15, bold: true)),
        if (d.shopPhone.trim().isNotEmpty)
          pw.Center(child: pw.Padding(padding: const pw.EdgeInsets.only(top: 2), child: _text(d.shopPhone.trim(), size: 10, argb: 0xFF8A90A6))),
        pw.SizedBox(height: 8),
        pw.Container(
          color: _teal,
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          child: pw.Center(
            child: pw.Text(d.title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          ),
        ),
        if (d.partyName.trim().isNotEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Center(child: _text(d.partyName.trim(), size: 13, bold: true))),
        if (d.meta.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Column(children: [for (final k in d.meta) _kv(k)])),
        for (final b in d.blocks) _block(b),
        pw.SizedBox(height: 14),
        if (d.footer.isNotEmpty) pw.Center(child: _text(d.footer, size: 10, argb: 0xFF8A90A6)),
      ];

  static Future<Uint8List> build(SlipPdfData d) async {
    final urdu = await _loadUrduFont();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        fontFallback: urdu == null ? const [] : [urdu],
      ),
    );
    // Pass 1: Urdu text yaad karo -> tasveerein -> Pass 2: asli widgets.
    _widgets(d);
    await UrduPdf.flush();
    final widgets = _widgets(d);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
      maxPages: 500,
      build: (ctx) => widgets,
    ));
    return doc.save();
  }

  /// PDF temp folder mein likh kar share sheet kholta hai. File ka path lautata hai.
  static Future<File> save(SlipPdfData d, {String? fileBase, DateTime? now}) async {
    final bytes = await build(d);
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'slips'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = slipFileName(fileBase ?? (d.partyName.isNotEmpty ? '${d.title}_${d.partyName}' : d.title), now ?? DateTime.now());
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  static Future<void> share(SlipPdfData d, {String? fileBase}) async {
    final f = await save(d, fileBase: fileBase);
    try {
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')], subject: d.title);
    } catch (_) {
      // Share sheet na khule to PDF viewer mein kholo (wahan se save/share ho sakta hai).
      final r = await OpenFilex.open(f.path, type: 'application/pdf');
      if (r.type != ResultType.done) rethrow;
    }
  }
}
