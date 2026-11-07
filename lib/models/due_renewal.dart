/// Partial payment aane par bill ki due date aage badhana (PURE — DB nahi).
///
/// Qaida: customer ne kuch paisa diya magar bill abhi baqi hai => nayi due date = aaj + muddat.
/// Muddat: customer ki default muddat (dueDays) agar set ho; warna us bill ki apni purani muddat
/// (due - bill ki tareekh, 3..30 din ke andar); warna 7 din. Date kabhi peeche nahi jati
/// (agar purani date pehle hi nayi se aage hai to wahi rehti hai).
const int kDefaultRenewDays = 7;

DateTime _day(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day);
}

/// Bill ki apni muddat (din). Pata na chale to 0.
int billTermDays(int createdAt, int dueDate) {
  if (dueDate <= 0 || createdAt <= 0) return 0;
  final d = _day(dueDate).difference(_day(createdAt)).inHours / 24.0;
  return d.round();
}

/// Nayi due date (millis, din ki shuruaat). `oldDue <= 0` (date set nahi) => 0 yani kuch na badlo.
int renewedDueDate({
  required int nowMillis,
  required int oldDue,
  required int createdAt,
  int customerDays = 0,
}) {
  if (oldDue <= 0) return 0;
  var term = customerDays > 0 ? customerDays : billTermDays(createdAt, oldDue);
  if (customerDays <= 0) {
    term = term <= 0 ? kDefaultRenewDays : term.clamp(3, 30);
  }
  final t = _day(nowMillis);
  final next = DateTime(t.year, t.month, t.day + term).millisecondsSinceEpoch;
  return next > oldDue ? next : oldDue;
}
