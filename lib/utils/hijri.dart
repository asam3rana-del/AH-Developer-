/// Tabular (civil) Islamic calendar <-> Gregorian, pure integer maths.
///
/// Kotlin used android.icu IslamicCalendar; Flutter has no built-in Hijri
/// calendar, so this uses the standard 30-year-cycle tabular algorithm.
/// NOTE: real Ramadan start depends on moon sighting and can differ by
/// 1-2 days from this tabular date. Zakat year boundaries are an estimate
/// either way; the user can still edit the year's amounts.
const int _islamicEpochJdn = 1948440; // JDN of 1 Muharram 1 AH (civil epoch)

/// Julian Day Number of a Gregorian calendar date.
int gregorianToJdn(int y, int m, int d) {
  final a = (14 - m) ~/ 12;
  final yy = y + 4800 - a;
  final mm = m + 12 * a - 3;
  return d + (153 * mm + 2) ~/ 5 + 365 * yy + yy ~/ 4 - yy ~/ 100 + yy ~/ 400 - 32045;
}

/// Gregorian (year, month, day) of a Julian Day Number.
({int year, int month, int day}) jdnToGregorian(int jdn) {
  final a = jdn + 32044;
  final b = (4 * a + 3) ~/ 146097;
  final c = a - 146097 * b ~/ 4;
  final d = (4 * c + 3) ~/ 1461;
  final e = c - 1461 * d ~/ 4;
  final m = (5 * e + 2) ~/ 153;
  return (
    year: 100 * b + d - 4800 + m ~/ 10,
    month: m + 3 - 12 * (m ~/ 10),
    day: e - (153 * m + 2) ~/ 5 + 1,
  );
}

/// Julian Day Number of an Islamic date (month 1..12).
int islamicToJdn(int year, int month, int day) =>
    day + (29.5 * (month - 1)).ceil() + (year - 1) * 354 + (3 + 11 * year) ~/ 30 + _islamicEpochJdn - 1;

/// Islamic (year, month, day) of a Julian Day Number.
({int year, int month, int day}) jdnToIslamic(int jdn) {
  final year = (30 * (jdn - _islamicEpochJdn) + 10646) ~/ 10631;
  var month = ((jdn - (29 + islamicToJdn(year, 1, 1))) / 29.5).ceil() + 1;
  if (month > 12) month = 12;
  if (month < 1) month = 1;
  final day = jdn - islamicToJdn(year, month, 1) + 1;
  return (year: year, month: month, day: day);
}

/// Local-midnight DateTime of [year]-[month]-[day] Hijri.
DateTime islamicToDateTime(int year, int month, int day) {
  final g = jdnToGregorian(islamicToJdn(year, month, day));
  return DateTime(g.year, g.month, g.day);
}

/// Hijri year that contains [t] (local calendar day).
int hijriYearOf(DateTime t) => jdnToIslamic(gregorianToJdn(t.year, t.month, t.day)).year;
