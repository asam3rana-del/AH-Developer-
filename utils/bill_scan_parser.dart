/// Bill Scan (Kotlin BillScanActivity) ka pure parsing hissa: OCR text -> item rows.
/// OCR imperfect hota hai, is liye har row user ko review/edit ke liye dikhai jati hai.
class ScannedLine {
  String name;
  String qty;
  String rate;
  bool include;
  ScannedLine({this.name = '', this.qty = '1', this.rate = '', this.include = true});
}

class ScannedItem {
  final String name;
  final double qty;
  final double rate;
  const ScannedItem(this.name, this.qty, this.rate);
}

final _skipWords = RegExp(
  r'\b(total|subtotal|sub total|discount|paid|balance|change|cash|tax|gst|invoice|inv|bill no|date|time|phone|tel|mob|thank|shukriya|customer|supplier|amount due|due)\b',
  caseSensitive: false,
);
// "1,200" / "1,200,000.50" (hazaron ka comma) ek hi number; "2,5" = 2.5 (decimal comma).
final _numRe = RegExp(r'\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.,]\d+)?');
final _thousandsRe = RegExp(r'^\d{1,3}(?:,\d{3})+(?:\.\d+)?$');

double? _num(String s) =>
    double.tryParse(_thousandsRe.hasMatch(s) ? s.replaceAll(',', '') : s.replaceAll(',', '.'));

bool _near(double a, double b) => (a - b).abs() <= 0.02 * (b.abs() < 1 ? 1 : b.abs());

/// OCR ke poore text se item rows nikalta hai. Header/total/date wali lines chhod deta hai.
List<ScannedLine> parseBillText(String raw) {
  final out = <ScannedLine>[];
  for (final lineRaw in raw.split(RegExp(r'\r?\n'))) {
    final line = lineRaw.trim();
    if (line.length < 3) continue;
    if (_skipWords.hasMatch(line)) continue;
    if (RegExp(r'\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}').hasMatch(line)) continue; // date
    if (!RegExp(r'[A-Za-z\u0600-\u06FF]').hasMatch(line)) continue; // sirf numbers/rules

    final matches = _numRe.allMatches(line).toList();
    if (matches.isEmpty) continue;

    var name = line.substring(0, matches.first.start).replaceAll(RegExp(r'[|:xX×*\-_.]+\s*$'), '').trim();
    if (name.length < 2) {
      // Naam number ke baad bhi ho sakta hai ("2 x Sugar 300").
      name = line.replaceAll(_numRe, ' ').replaceAll(RegExp(r'[|:×*\-_.]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (name.length < 2) continue;

    final nums = [for (final m in matches) _num(m.group(0)!)].whereType<double>().toList();
    if (nums.isEmpty) continue;

    double qty = 1, rate = 0;
    if (nums.length >= 3) {
      final a = nums[nums.length - 3], b = nums[nums.length - 2], c = nums[nums.length - 1];
      if (_near(a * b, c)) {
        qty = a;
        rate = b;
      } else if (_near(b * c, a)) {
        // Amount pehle (ITEM | AMOUNT | QTY | RATE — apni bill ki tarteeb).
        qty = b;
        rate = c;
      } else {
        qty = a;
        rate = b;
      }
    } else if (nums.length == 2) {
      qty = nums[0];
      rate = nums[1];
    } else {
      rate = nums[0];
    }
    if (qty <= 0) qty = 1;
    out.add(ScannedLine(name: name, qty: _fmt(qty), rate: rate > 0 ? _fmt(rate) : ''));
  }
  return out;
}

String _fmt(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Sirf tick wali, valid (naam + qty>0 + rate>0) rows.
List<ScannedItem> confirmedItems(List<ScannedLine> lines) {
  final out = <ScannedItem>[];
  for (final l in lines) {
    if (!l.include) continue;
    final name = l.name.trim();
    final qty = double.tryParse(l.qty.trim()) ?? 0;
    final rate = double.tryParse(l.rate.trim()) ?? 0;
    if (name.isEmpty || qty <= 0 || rate <= 0) continue;
    out.add(ScannedItem(name, qty, rate));
  }
  return out;
}
