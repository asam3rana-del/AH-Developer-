import '../db/due_reminders_repository.dart' show DueParty;

/// Receivables (customers se lena) ki umar ke hisaab se tafseel — "paisa kahan phansa hai".
///
/// Har baqi bill ki tareekh (dueDate) se aaj tak ke din dekh kar 6 dibbon mein baanta jata hai:
/// abhi waqt hai / 1-7 / 8-30 / 31-60 / 60+ din late / tareekh nahi (ya purana bina-bill hisaab).
/// Raqam har BILL ke hisaab se dibbe mein jati hai; party ki "sab se zyada late" halat [AgingRow.worst] hai.
///
/// Saara hisaab PURE hai (DB / UI nahi) taake test ho — test/receivable_aging_test.dart.
enum AgingBucket { notDue, late1to7, late8to30, late31to60, late60plus, noDate }

/// Dibbon ki tarteeb (screen par isi tarah dikhte hain).
const List<AgingBucket> agingBucketOrder = [
  AgingBucket.notDue,
  AgingBucket.late1to7,
  AgingBucket.late8to30,
  AgingBucket.late31to60,
  AgingBucket.late60plus,
  AgingBucket.noDate,
];

/// Late wale dibbe (noDate / notDue nahi).
const Set<AgingBucket> agingLateBuckets = {
  AgingBucket.late1to7,
  AgingBucket.late8to30,
  AgingBucket.late31to60,
  AgingBucket.late60plus,
};

/// Calendar dinon ka farq (DST wale din par bhi sahi): [fromMillis] se [toMillis] tak.
int calendarDaysBetween(int fromMillis, int toMillis) {
  final a = DateTime.fromMillisecondsSinceEpoch(fromMillis);
  final b = DateTime.fromMillisecondsSinceEpoch(toMillis);
  return DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// [daysLate] <= 0 (aaj ya aage ki tareekh) => notDue.
AgingBucket agingBucketForDays(int daysLate) {
  if (daysLate <= 0) return AgingBucket.notDue;
  if (daysLate <= 7) return AgingBucket.late1to7;
  if (daysLate <= 30) return AgingBucket.late8to30;
  if (daysLate <= 60) return AgingBucket.late31to60;
  return AgingBucket.late60plus;
}

/// Ek party (customer) ki umar ki tafseel.
class AgingRow {
  final DueParty party;

  /// Har dibbe mein is party ki raqam (sirf wo dibbe jin mein kuch ho).
  final Map<AgingBucket, double> byBucket;

  /// Sab se purane late bill ke din (0 = koi bill late nahi).
  final int maxDaysLate;
  const AgingRow({required this.party, required this.byBucket, required this.maxDaysLate});

  double amountIn(AgingBucket b) => byBucket[b] ?? 0.0;

  double get total => byBucket.values.fold<double>(0.0, (a, b) => a + b);

  /// Party ki sab se kharab halat: late ho to us ka dibba, warna tareekh na ho to noDate, warna notDue.
  AgingBucket get worst {
    if (maxDaysLate > 0) return agingBucketForDays(maxDaysLate);
    if (amountIn(AgingBucket.noDate) > 0.009) return AgingBucket.noDate;
    return AgingBucket.notDue;
  }

  bool get isLate => maxDaysLate > 0;
}

/// Poori receivables ka khulasa.
class AgingSummary {
  /// Dibbe ki kul raqam.
  final Map<AgingBucket, double> amount;

  /// Dibbe mein kitni parties ki kuch raqam hai (ek party kai dibbon mein ho sakti hai).
  final Map<AgingBucket, int> parties;
  final double totalDue;
  final int totalParties;

  /// Sab parties, kul raqam ke hisaab se bari pehle.
  final List<AgingRow> rows;
  const AgingSummary({
    required this.amount,
    required this.parties,
    required this.totalDue,
    required this.totalParties,
    required this.rows,
  });

  static const empty = AgingSummary(amount: {}, parties: {}, totalDue: 0, totalParties: 0, rows: []);

  bool get isEmpty => totalParties == 0;

  double amountIn(AgingBucket b) => amount[b] ?? 0.0;
  int partiesIn(AgingBucket b) => parties[b] ?? 0;

  /// Sab late dibbon ka jod.
  double get lateAmount => agingLateBuckets.fold<double>(0.0, (a, b) => a + amountIn(b));

  /// Late raqam ka hissa kul mein (0..1). Kul 0 ho to 0.
  double get lateShare => totalDue <= 0.009 ? 0.0 : (lateAmount / totalDue).clamp(0.0, 1.0).toDouble();

  /// Kisi dibbe ki parties, us dibbe ki raqam ke hisaab se bari pehle.
  List<AgingRow> rowsIn(AgingBucket b) {
    final list = rows.where((r) => r.amountIn(b) > 0.009).toList();
    list.sort((a, c) {
      final d = c.amountIn(b).compareTo(a.amountIn(b));
      return d != 0 ? d : a.party.partyName.toLowerCase().compareTo(c.party.partyName.toLowerCase());
    });
    return list;
  }
}

/// [parties] (Due Reminders ke groups; sirf customers ki sales) -> [AgingSummary]. Advance wali rows chhod di jati hain.
AgingSummary buildAging(Iterable<DueParty> parties, {int? nowMillis}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final amount = <AgingBucket, double>{};
  final count = <AgingBucket, int>{};
  final rows = <AgingRow>[];
  var totalDue = 0.0;
  for (final p in parties) {
    if (p.isAdvance) continue;
    final by = <AgingBucket, double>{};
    var maxLate = 0;
    for (final b in p.bills) {
      if (b.isAdvance || b.due <= 0.009) continue;
      final AgingBucket bucket;
      if (b.dueDate <= 0) {
        bucket = AgingBucket.noDate;
      } else {
        final days = calendarDaysBetween(b.dueDate, now);
        if (days > maxLate) maxLate = days;
        bucket = agingBucketForDays(days);
      }
      by[bucket] = (by[bucket] ?? 0.0) + b.due;
    }
    if (by.isEmpty) continue;
    for (final e in by.entries) {
      amount[e.key] = (amount[e.key] ?? 0.0) + e.value;
      count[e.key] = (count[e.key] ?? 0) + 1;
      totalDue += e.value;
    }
    rows.add(AgingRow(party: p, byBucket: by, maxDaysLate: maxLate));
  }
  rows.sort((a, b) {
    final d = b.total.compareTo(a.total);
    return d != 0 ? d : a.party.partyName.toLowerCase().compareTo(b.party.partyName.toLowerCase());
  });
  return AgingSummary(amount: amount, parties: count, totalDue: totalDue, totalParties: rows.length, rows: rows);
}
