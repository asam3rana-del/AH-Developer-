/// Bill Scan (Kotlin BillScanActivity) ka pure parsing hissa: OCR text -> item rows.
/// OCR imperfect hota hai, is liye har row user ko review/edit ke liye dikhai jati hai.
///
/// Behtar reading ke liye 2 cheezein:
///  1. [rebuildRowsText]: ML Kit ke text-pieces ko unki jagah (x, y) se dobara qatar (row) mein jorta hai —
///     table wale bill mein naam aur qty/rate alag alag pieces mein aate hain aur text ka tarteeb bigad jata hai.
///  2. [parseBillText]: serial number, pack size ("50kg"), "Rs", "O" ki jagah "0", header lines, phone/NTN lines,
///     aur naam alag line / numbers agli line wali bills ko sambhalta hai.
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

/// OCR ka ek text-piece (line) apni position ke saath (ML Kit ke bounding box se).
class OcrBox {
  final String text;
  final double left, top, right, bottom;
  const OcrBox(this.text, this.left, this.top, this.right, this.bottom);
  double get cy => (top + bottom) / 2;
  double get height => bottom - top;
}

/// Pieces ko upar se neeche rows mein, aur har row mein left se right tarteeb mein jorta hai.
/// Row ka faisla: agle piece ka vertical center pichle piece se aadhi line-height ke andar ho.
String rebuildRowsText(List<OcrBox> boxes) {
  final items = boxes.where((b) => b.text.trim().isNotEmpty).toList();
  if (items.isEmpty) return '';
  items.sort((a, b) => a.cy.compareTo(b.cy));
  final heights = [for (final b in items) if (b.height > 0) b.height]..sort();
  final medianH = heights.isEmpty ? 20.0 : heights[heights.length ~/ 2];
  final threshold = medianH * 0.5;

  final rows = <List<OcrBox>>[];
  for (final b in items) {
    if (rows.isNotEmpty && (b.cy - rows.last.last.cy).abs() <= threshold) {
      rows.last.add(b);
    } else {
      rows.add([b]);
    }
  }

  final lines = <String>[];
  for (final row in rows) {
    row.sort((a, b) => a.left.compareTo(b.left));
    final sb = StringBuffer();
    for (var i = 0; i < row.length; i++) {
      if (i > 0) {
        final gap = row[i].left - row[i - 1].right;
        sb.write(gap > medianH * 0.8 ? '   ' : ' ');
      }
      sb.write(row[i].text.replaceAll(RegExp(r'\s*\r?\n\s*'), ' ').trim());
    }
    lines.add(sb.toString());
  }
  return lines.join('\n');
}

final _skipWords = RegExp(
  r'\b(total|subtotal|sub total|grand|net amount|net payable|discount|paid|balance|change|cash|tax|gst|invoice|inv|bill no|date|time|phone|mob|ph|tel|fax|ntn|cnic|strn|www|http|email|received|signature|thank|shukriya|customer|supplier|amount due|due)\b',
  caseSensitive: false,
);
final _headerWords = RegExp(
  r'\b(description|desc|particulars|item|items|qty|quantity|rate|price|amount|amt|unit|sr|s\.?\s?no)\b',
  caseSensitive: false,
);
final _dateRe = RegExp(r'\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}');
final _letterRe = RegExp(r'[A-Za-z\u0600-\u06FF]');
// "1,200" / "1,200,000.50" (hazaron ka comma) ek hi number; "2,5" = 2.5 (decimal comma).
final _numRe = RegExp(r'\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.,]\d+)?');
final _thousandsRe = RegExp(r'^\d{1,3}(?:,\d{3})+(?:\.\d+)?$');
// Number ke foran baad unit likha ho ("50kg", "5 ltr") => aksar pack size, qty/rate nahi.
final _unitAfterRe = RegExp(
  r'^\s{0,2}(?:kgs?|gms?|g|mg|ml|ltrs?|l|pcs?|dz|doz|dozen|ctn|carton|pkt|pack|box|bag|btl|bottle)\b',
  caseSensitive: false,
);
final _unitWordRe = RegExp(r'^(?:x|kgs?|gms?|pcs?|dz|doz|dozen|ctn|carton|pkt|pack|box|bag|btl|bottle)$', caseSensitive: false);
// Line ke shuru mein "2 x Sugar 300" / "2 pcs Sugar 300": pehla number qty.
final _qtyFirstRe = RegExp(r'^(\d+(?:[.,]\d+)?)\s*(?:x|×|pcs|pc|kg|dz|ctn|pkt)?\s+(?=[A-Za-z\u0600-\u06FF])', caseSensitive: false);
// Line ke shuru mein serial: "1. Sugar", "2) Rice", "3- Oil".
final _serialRe = RegExp(r'^\d{1,3}\s*[.)\-]\s+(?=[A-Za-z\u0600-\u06FF])');

double? _num(String s) =>
    double.tryParse(_thousandsRe.hasMatch(s) ? s.replaceAll(',', '') : s.replaceAll(',', '.'));

bool _near(double a, double b) => (a - b).abs() <= 0.02 * (b.abs() < 1 ? 1 : b.abs());

class _Num {
  final double v;
  final int start;
  final int end;
  final bool unitAttached;
  const _Num(this.v, this.start, this.end, this.unitAttached);
}

class _Pick {
  final double qty;
  final double rate;
  final int startIdx; // nums mein pehla "data" number (is se pehle ka hissa naam)
  const _Pick(this.qty, this.rate, this.startIdx);
}

List<_Num> _numbersIn(String s) {
  final out = <_Num>[];
  for (final m in _numRe.allMatches(s)) {
    final v = _num(m.group(0)!);
    if (v == null) continue;
    if (v > 10000000) continue; // phone / barcode / NTN jaisa lamba number
    out.add(_Num(v, m.start, m.end, _unitAfterRe.hasMatch(s.substring(m.end))));
  }
  return out;
}

/// "5OO" -> "500": sirf wo tokens jin mein asli digit ho aur baaqi sirf O/o, ./, ho.
String _fixDigits(String s) => s.replaceAllMapped(RegExp(r'\S+'), (m) {
      final t = m.group(0)!;
      if (!RegExp(r'\d').hasMatch(t)) return t;
      if (!RegExp(r'^[\dOo.,]+$').hasMatch(t)) return t;
      return t.replaceAll(RegExp(r'[Oo]'), '0');
    });

String _cleanName(String s) {
  var n = s.trim();
  n = n.replaceAll(RegExp(r'^[|:×*\-_.\s]+'), '').replaceAll(RegExp(r'[|:×*\-_.\s]+$'), '').trim();
  // Shuru/aakhir mein akeli unit ya "x" wali tokens hata do.
  final parts = n.split(RegExp(r'\s+'));
  while (parts.isNotEmpty && _unitWordRe.hasMatch(parts.first)) {
    parts.removeAt(0);
  }
  while (parts.isNotEmpty && _unitWordRe.hasMatch(parts.last)) {
    parts.removeLast();
  }
  return parts.join(' ').trim();
}

/// Numbers se qty / rate chunta hai. qty x rate = amount ka rishta mile to wohi (sab se pakka).
_Pick? _pick(List<_Num> nums) {
  final n = nums.length;
  if (n == 0) return null;
  if (n >= 3) {
    final a = nums[n - 3].v, b = nums[n - 2].v, c = nums[n - 1].v;
    if (_near(a * b, c)) return _Pick(a, b, n - 3); // QTY RATE AMOUNT
    if (_near(b * c, a)) return _Pick(b, c, n - 3); // AMOUNT QTY RATE
  }
  // Pack size wale numbers ("50kg") qty/rate nahi ginte (agar aur numbers hon).
  var cand = [for (var i = 0; i < n; i++) if (!nums[i].unitAttached) i];
  if (cand.isEmpty) cand = [for (var i = 0; i < n; i++) i];
  final m = cand.length;
  if (m >= 3) return _Pick(nums[cand[m - 3]].v, nums[cand[m - 2]].v, cand[m - 3]);
  if (m == 2) return _Pick(nums[cand[0]].v, nums[cand[1]].v, cand[0]);
  return _Pick(1, nums[cand[0]].v, cand[0]);
}

/// OCR ke poore text se item rows nikalta hai. Header/total/date/phone wali lines chhod deta hai.
List<ScannedLine> parseBillText(String raw) {
  final out = <ScannedLine>[];
  var pendingName = '';
  for (final lineRaw in raw.split(RegExp(r'\r?\n'))) {
    final pending = pendingName;
    pendingName = '';
    final line = lineRaw.trim();
    if (line.length < 3) continue;
    if (_skipWords.hasMatch(line)) continue;
    if (_dateRe.hasMatch(line)) continue;
    if (RegExp(r'\d{9,}').hasMatch(line.replaceAll('-', ''))) continue; // phone / NTN / barcode
    final hasLetters = _letterRe.hasMatch(line);
    if (hasLetters && !RegExp(r'\d').hasMatch(line) && _headerWords.allMatches(line).length >= 2) continue; // column header

    var work = _fixDigits(line);
    work = work.replaceAll(RegExp(r'\b(?:rs|pkr)\b\.?|/-', caseSensitive: false), ' ').replaceAll(RegExp(r'\s{2,}'), '   ').trim();
    work = work.replaceFirst(_serialRe, '');

    // Sirf numbers wali line ("2   300   600"): pichli naam-only line ka data.
    if (!_letterRe.hasMatch(work)) {
      final numOnly = _numbersIn(work);
      if (pending.isNotEmpty && numOnly.length >= 2 && numOnly.length <= 4) {
        final pk = _pick(numOnly);
        if (pk != null && pk.qty > 0) {
          out.add(ScannedLine(name: pending, qty: _fmt(pk.qty), rate: pk.rate > 0 ? _fmt(pk.rate) : ''));
        }
      }
      continue;
    }

    double? leadQty;
    final qf = _qtyFirstRe.firstMatch(work);
    if (qf != null) {
      final rest = work.substring(qf.end);
      final restCount = _numbersIn(rest).length;
      if (restCount == 1) {
        leadQty = _num(qf.group(1)!);
        work = rest;
      } else if (restCount >= 2) {
        work = rest; // pehla number serial tha
      }
    }

    final nums = _numbersIn(work);
    // Koi number nahi, ya sirf pack size ("Sugar 50kg") => ye naam-only line hai, data agli line mein ho sakta hai.
    if (nums.isEmpty || nums.every((e) => e.unitAttached)) {
      final nm = _cleanName(work.replaceAll(RegExp(r'\s{2,}'), ' '));
      if (nm.length >= 3) pendingName = nm;
      continue;
    }

    final pick = _pick(nums);
    if (pick == null) continue;
    var name = _cleanName(work.substring(0, nums[pick.startIdx].start));
    if (name.length < 2) {
      name = _cleanName(work.replaceAll(_numRe, ' ').replaceAll(RegExp(r'\s+'), ' '));
    }
    if (name.length < 2) continue;

    var qty = leadQty ?? pick.qty;
    final rate = pick.rate;
    if (qty <= 0) qty = 1;
    out.add(ScannedLine(name: name, qty: _fmt(qty), rate: rate > 0 ? _fmt(rate) : ''));
  }
  return out;
}

/// Bill par likha kul total (Total / Grand Total / Net Amount wali lines mein sab se bara number).
/// Items ke jore se milane ke liye (OCR ghalti pakadne mein madad).
double? detectBillTotal(String raw) {
  final re = RegExp(r'\b(grand\s*total|net\s*(?:amount|total|payable)|total|sub\s*total)\b', caseSensitive: false);
  double? best;
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (!re.hasMatch(line)) continue;
    final nums = _numbersIn(_fixDigits(line));
    if (nums.isEmpty) continue;
    final v = nums.last.v;
    if (best == null || v > best) best = v;
  }
  return best;
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
