import '../models/product.dart';

/// Product ki expiry (products.expiry, TEXT — pehle se schema aur sync mein tha, bas UI nahi tha).
///
/// Save hamesha `yyyy-MM-dd` mein. Parhte waqt purana / haath se likha format bhi chalta hai:
/// `yyyy-MM-dd`, `dd/MM/yyyy`, `dd-MM-yyyy`, `MM/yyyy` (mahine ka aakhri din). Na samajh aaye => null
/// (product "expiry nahi" mana jata hai, kabhi crash nahi).
///
/// Saara faisla PURE — test/expiry_test.dart.

/// Itne din (ya kam) baqi hon to "jald expire".
const int expiryWarnDays = 30;

DateTime? parseExpiry(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  DateTime? make(int y, int m, int d) {
    if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, m, d);
    return (dt.year == y && dt.month == m && dt.day == d) ? dt : null; // 31 Feb jaisi ghalat tareekh nahi
  }

  var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (m != null) return make(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  m = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$').firstMatch(s);
  if (m != null) return make(int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
  m = RegExp(r'^(\d{1,2})[/\-.](\d{4})$').firstMatch(s);
  if (m != null) {
    final y = int.parse(m.group(2)!), mo = int.parse(m.group(1)!);
    if (mo < 1 || mo > 12 || y < 2000 || y > 2100) return null;
    return DateTime(y, mo + 1, 0); // mahine ka aakhri din
  }
  return null;
}

String formatExpiryForStorage(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Aaj se kitne din baqi (aaj expire = 0, kal guzri = -1).
int daysUntilExpiry(DateTime expiry, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final e = DateTime(expiry.year, expiry.month, expiry.day);
  return (e.difference(today).inHours / 24).round();
}

enum ExpiryStatus { expired, soon, ok }

ExpiryStatus expiryStatusOf(int daysLeft, {int warnDays = expiryWarnDays}) {
  if (daysLeft < 0) return ExpiryStatus.expired;
  if (daysLeft <= warnDays) return ExpiryStatus.soon;
  return ExpiryStatus.ok;
}

class ExpiryRow {
  final Product product;
  final DateTime expiry;
  final int daysLeft;
  final ExpiryStatus status;
  const ExpiryRow(this.product, this.expiry, this.daysLeft, this.status);
}

/// Sirf wo products jin ka stock > 0 hai aur jo expire ho chuke ya [warnDays] ke andar hain.
/// Tarteeb: pehle jo sab se pehle expire (purane expired sab se upar).
List<ExpiryRow> buildExpiryList(Iterable<Product> products, {DateTime? now, int warnDays = expiryWarnDays}) {
  final out = <ExpiryRow>[];
  for (final p in products) {
    if (p.stock <= 1e-9) continue;
    final e = parseExpiry(p.expiry);
    if (e == null) continue;
    final left = daysUntilExpiry(e, now: now);
    final st = expiryStatusOf(left, warnDays: warnDays);
    if (st == ExpiryStatus.ok) continue;
    out.add(ExpiryRow(p, e, left, st));
  }
  out.sort((a, b) {
    final c = a.daysLeft.compareTo(b.daysLeft);
    return c != 0 ? c : a.product.name.toLowerCase().compareTo(b.product.name.toLowerCase());
  });
  return out;
}
