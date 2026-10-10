import '../models/product.dart';

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF ]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Set<String> _tokens(String s) => _norm(s).split(' ').where((t) => t.isNotEmpty).toSet();

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      final del = prev[j] + 1, ins = cur[j - 1] + 1, sub = prev[j - 1] + cost;
      cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Do alfaz ek jaise? Barabar, ya OCR ki ek ghalti (5+ harf par), ya ek doosre ka shuru (4+ harf).
bool _tokenMatch(String a, String b) {
  if (a == b) return true;
  if (a.length >= 4 && b.length >= 4 && (a.startsWith(b) || b.startsWith(a))) return true;
  if (a.length >= 5 && b.length >= 5 && _lev(a, b) <= 1) return true;
  return false;
}

/// Scan hue naam ko maujooda product se milata hai: pehle poora barabar, phir alfaz (OCR ki chhoti ghalti
/// samet) ke hisab se sab se qareebi — sirf tab jab wo wazeh taur par sab se behtar ho. Warna null.
Product? matchScannedProduct(String scanned, List<Product> products) {
  final n = _norm(scanned);
  if (n.isEmpty) return null;
  for (final p in products) {
    if (_norm(p.name) == n) return p;
  }
  final st = _tokens(scanned);
  if (st.isEmpty) return null;
  Product? best;
  var bestScore = 0.0;
  var tie = false;
  for (final p in products) {
    final pt = _tokens(p.name);
    if (pt.isEmpty) continue;
    var matched = 0;
    for (final t in st) {
      if (pt.any((u) => _tokenMatch(t, u))) matched++;
    }
    if (matched == 0) continue;
    final score = matched / (st.length + pt.length - matched);
    if (score > bestScore + 1e-9) {
      best = p;
      bestScore = score;
      tie = false;
    } else if ((score - bestScore).abs() <= 1e-9) {
      tie = true;
    }
  }
  if (best != null && bestScore >= 0.6 && !tie) return best;
  return null;
}
