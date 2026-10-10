import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/bill_scan_parser.dart';
import '../utils/loc.dart';
import '../theme/theme_manager.dart';

/// Kotlin BillScanActivity: bill ki photo -> OCR (on-device ML Kit) -> item rows review/edit ->
/// "CONFIRM & ADD TO PURCHASE". Pop result: List<ScannedItem>.
class BillScanScreen extends StatefulWidget {
  const BillScanScreen({super.key});

  @override
  State<BillScanScreen> createState() => _BillScanScreenState();
}

class _BillScanScreenState extends State<BillScanScreen> {
  final _picker = ImagePicker();
  final List<ScannedLine> _lines = [];
  String? _imagePath;
  bool _busy = false;
  bool _processed = false;
  String _status = '';

  Future<void> _pick(ImageSource source) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(source: source, imageQuality: 95, maxWidth: 3200);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = Loc.t('Could not open camera/gallery: $e', 'کیمرہ/گیلری نہیں کھلی: $e'));
      return;
    }
    if (file == null) return;
    setState(() {
      _imagePath = file!.path;
      _busy = true;
      _processed = false;
      _lines.clear();
      _status = Loc.t('Reading bill…', 'بل پڑھا جا رہا ہے…');
    });
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
      // Text-pieces ko unki jagah se dobara qatar (row) mein jorte hain: table wale bill mein naam aur
      // qty/rate alag pieces mein aate hain aur seedha result.text ka tarteeb bigad jata hai.
      final boxes = <OcrBox>[
        for (final b in result.blocks)
          for (final l in b.lines)
            OcrBox(l.text, l.boundingBox.left, l.boundingBox.top, l.boundingBox.right, l.boundingBox.bottom),
      ];
      final rowsText = rebuildRowsText(boxes);
      var parsed = parseBillText(rowsText);
      var usedText = rowsText;
      if (parsed.isEmpty) {
        parsed = parseBillText(result.text);
        usedText = result.text;
      }
      final billTotal = detectBillTotal(usedText);
      if (!mounted) return;
      var sum = 0.0;
      for (final l in parsed) {
        sum += (double.tryParse(l.qty) ?? 0) * (double.tryParse(l.rate) ?? 0);
      }
      String totalNote = '';
      if (billTotal != null && parsed.isNotEmpty) {
        final ok = (billTotal - sum).abs() <= (billTotal.abs() * 0.01 + 1);
        totalNote = ok
            ? Loc.t(' Items total ${_n(sum)} matches the bill total ✓', ' آئٹمز کا جمع ${_n(sum)} بل کے ٹوٹل سے مل گیا ✓')
            : Loc.t(' Items total ${_n(sum)} but bill total is ${_n(billTotal)} — some line may be misread or missing.',
                ' آئٹمز کا جمع ${_n(sum)} ہے مگر بل کا ٹوٹل ${_n(billTotal)} ہے — کوئی لائن غلط پڑھی گئی یا رہ گئی ہو سکتی ہے۔');
      }
      setState(() {
        _lines.addAll(parsed);
        _processed = true;
        _status = parsed.isEmpty
            ? Loc.t('No items found. Add manually below or scan again.', 'کوئی آئٹم نہیں ملا۔ نیچے دستی طور پر شامل کریں یا دوبارہ سکین کریں۔')
            : Loc.t('${parsed.length} lines detected — check qty/rate, then confirm.',
                    '${parsed.length} لائنیں ملیں — qty/rate چیک کر کے تصدیق کریں۔') +
                totalNote;
      });
    } catch (e) {
      debugPrint('OCR failed: $e');
      if (!mounted) return;
      setState(() {
        _processed = true;
        _status = Loc.t('OCR failed: $e. Try again.', 'OCR فیل: $e۔ دوبارہ کوشش کریں۔');
      });
    } finally {
      await recognizer.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  void _confirm() {
    final items = confirmedItems(_lines);
    if (items.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(Loc.t('Select at least one valid item (name, qty, rate)', 'کم از کم ایک درست آئٹم منتخب کریں'))));
      return;
    }
    Navigator.of(context).pop(items);
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: ThemeManager.palette.fieldFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ThemeManager.palette.border)),
      );

  Widget _row(int index, ScannedLine line) => Container(
        key: ObjectKey(line),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
        decoration: BoxDecoration(
          color: ThemeManager.palette.cardWhite,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ThemeManager.palette.border),
        ),
        child: Column(children: [
          Row(children: [
            Checkbox(value: line.include, onChanged: (v) => setState(() => line.include = v ?? true)),
            Expanded(
              child: TextFormField(
                initialValue: line.name,
                onChanged: (v) => line.name = v,
                decoration: _dec(Loc.t('Item name', 'آئٹم کا نام')),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: ThemeManager.palette.red, size: 20),
              onPressed: () => setState(() => _lines.removeAt(index)),
            ),
          ]),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: line.qty,
                  onChanged: (v) => line.qty = v,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dec('Qty'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  initialValue: line.rate,
                  onChanged: (v) => line.rate = v,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dec('Rate'),
                ),
              ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // OCR (ML Kit) sirf Android / iOS par hai.
      return Scaffold(
        appBar: AppBar(title: Text(Loc.t('Scan Bill', 'بل سکین'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              Loc.t('Bill scan is available only on the Android / iOS app. Add the purchase items manually here.',
                  'بل سکین صرف اینڈرائیڈ / آئی او ایس ایپ میں دستیاب ہے۔ یہاں آئٹم دستی طور پر شامل کریں۔'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final showReview = _processed;
    return Scaffold(
      backgroundColor: ThemeManager.palette.bg,
      appBar: AppBar(backgroundColor: ThemeManager.palette.navy, foregroundColor: Colors.white, title: Text(Loc.t('Scan Bill', 'بل سکین'))),
      body: Column(children: [
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.document_scanner_outlined, size: 18),
                    label: Text(Loc.t('Scan Bill', 'بل سکین')),
                    style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.teal, padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: Text(Loc.t('Gallery', 'گیلری')),
                    style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.navy, padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                Loc.t('Hold the bill flat, in good light, fully inside the frame for best reading.',
                    'بہتر ریڈنگ کے لیے بل سیدھا، اچھی روشنی میں، پورا فریم میں رکھیں۔'),
                style: TextStyle(fontSize: 11, color: ThemeManager.palette.textMuted),
              ),
              const SizedBox(height: 16),
              if (_imagePath != null)
                Container(
                  height: 180,
                  margin: const EdgeInsets.only(bottom: 10),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: ThemeManager.palette.cardWhite,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ThemeManager.palette.border),
                  ),
                  child: Image.file(File(_imagePath!), fit: BoxFit.cover, width: double.infinity),
                ),
              if (_busy) const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
                  child: Text(_status, style: TextStyle(fontSize: 13, color: ThemeManager.palette.textMuted)),
                ),
              if (showReview && _lines.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(Loc.t('Detected Items — Review & Edit', 'ملے ہوئے آئٹمز — دیکھیں اور ایڈٹ کریں'),
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ThemeManager.palette.navyInk)),
                ),
              for (var i = 0; i < _lines.length; i++) _row(i, _lines[i]),
              if (showReview)
                TextButton.icon(
                  onPressed: () => setState(() => _lines.add(ScannedLine())),
                  icon: const Icon(Icons.add),
                  label: Text(Loc.t('Add row manually', 'دستی طور پر قطار شامل کریں')),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
              const SizedBox(height: 40),
            ],
          ),
        ),
        if (showReview)
          Container(
            color: ThemeManager.palette.cardWhite,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _confirm,
                  style: FilledButton.styleFrom(backgroundColor: ThemeManager.palette.navy, padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(Loc.t('CONFIRM & ADD TO PURCHASE', 'تصدیق کریں اور خریداری میں شامل کریں'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
