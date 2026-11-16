import '../db/due_reminders_repository.dart';
import 'due_followup.dart';
import 'pay_schedule.dart';
import 'qist_plan.dart';

/// Wasooli ek-page: har party ki SIRF EK "agli tareekh" aur teen rang (Late / Aaj / Aage).
///
/// Andar ka saara hisaab wahi (bill ki due date, wada, qist, payment din, follow-up) — yahan sirf faisla
/// hota hai ke screen par kaunsi EK tareekh dikhe. Tarteeb (pehli jo laagu ho):
///  1. Jhagra (dispute) => Aage, "Jhagra" (roz tang na karo).
///  2. Wada (abhi ka, maujooda qarz ka) => wahi tareekh. Wada bill ki due date se zyada ahem hai: wada aage ka
///     ho to bill late hone ke bawajood party "Aage" (wade par) hai; wada toota => Late.
///  3. Qist plan => agli qist; guzri qist mein baqi => Late.
///  4. Warna sab se purani bill due date (bina-date bill: bill + 7 din), payment din aur agla follow-up mein se
///     sab se pehle wali. Guzri hui bill date => Late.
///
/// Sab PURE — test/wasooli_plan_test.dart.

enum WasooliUrgency { late, today, later }

enum WasooliDateKind { promise, qist, payDay, bill, followUp, dispute }

const int _dayMs = 86400000;

int _sod(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

int _daysBetween(int fromDay, int toDay) => ((toDay - fromDay) / _dayMs).round();

/// Agle 14 din mein customer ka agla payment din (aaj shamil). Nahi => 0.
int nextPayDay(String raw, int today) {
  final s = PaySchedule.parse(raw);
  if (s == null) return 0;
  final t = DateTime.fromMillisecondsSinceEpoch(today);
  for (var i = 0; i < 32; i++) {
    final d = DateTime(t.year, t.month, t.day + i);
    if (s.isOn(d)) return d.millisecondsSinceEpoch;
  }
  return 0;
}

class WasooliRow {
  final DueParty party;
  final List<DueFollowUp> entries; // sirf maujooda qarz ki, nayi pehle
  final FollowUpState state;
  final WasooliUrgency urgency;
  final WasooliDateKind kind;

  /// Agli tareekh (din ki shuruaat). Late par = jo tareekh guzri.
  final int date;

  /// Is tareekh par kitna (wada / qist ki raqam). 0 = poora baqi.
  final double amount;

  /// Kitni dafa wada toota (maujooda qarz mein).
  final int brokenCount;

  /// Aaj is party se rabta / payment ho chuka.
  final bool touchedToday;
  final int today;

  /// Purane (toote / khatam) wade — party screen par kati hui line mein.
  final List<DueFollowUp> pastPromises;

  const WasooliRow({
    required this.party,
    required this.entries,
    required this.state,
    required this.urgency,
    required this.kind,
    required this.date,
    required this.amount,
    required this.brokenCount,
    required this.touchedToday,
    required this.today,
    required this.pastPromises,
  });

  double get total => party.total;

  /// Late: kitne din guzre. Aage: kitne din baqi. Aaj: 0.
  int get days => urgency == WasooliUrgency.late ? _daysBetween(date, today) : _daysBetween(today, date);

  bool get hasPromise => kind == WasooliDateKind.promise;
}

WasooliRow buildWasooliRow(
  DueParty p,
  List<DueFollowUp> allEntries, {
  required int nowMillis,
  String paySchedule = '',
  QistStatus? qist,
}) {
  final today = _sod(nowMillis);
  final entries = sortFollowUpsNewestFirst(entriesForCurrentDebt(allEntries, p.debtSince));
  final st = followUpState(entries, nowMillis: nowMillis);
  // promiseRecord() toota wada 2 din baad ginta hai; abhi ka khula toota wada us se pehle bhi ginti mein aaye.
  final broken = promiseRecord(entries, nowMillis: nowMillis).broken +
      (st.promiseBroken && !_countedInRecord(st, today) ? 1 : 0);
  final touched = entries.any((e) => _sod(e.createdAt) == today);
  final past = [
    for (final e in entries)
      if (e.promiseDate > 0 && e.outcome != FollowUpOutcome.sent && !identical(e, st.promise)) e,
  ];

  WasooliRow make(WasooliUrgency u, WasooliDateKind k, int date, [double amount = 0]) => WasooliRow(
        party: p,
        entries: entries,
        state: st,
        urgency: u,
        kind: k,
        date: date,
        amount: amount,
        brokenCount: broken,
        touchedToday: touched,
        today: today,
        pastPromises: past,
      );

  WasooliUrgency byDate(int d) => d < today ? WasooliUrgency.late : (d == today ? WasooliUrgency.today : WasooliUrgency.later);

  if (st.dispute) return make(WasooliUrgency.later, WasooliDateKind.dispute, st.nextFollowUp > today ? st.nextFollowUp : today + 7 * _dayMs);

  final promise = st.promise;
  if (promise != null) {
    // "Paisa mila" (partial) wali entry ki raqam MILI hui hai, wade ki nahi => wada = poora baqi.
    final amt = promise.outcome == FollowUpOutcome.partial ? 0.0 : promise.amount;
    return make(byDate(promise.promiseDate), WasooliDateKind.promise, promise.promiseDate, amt);
  }

  if (qist != null && !qist.completed) {
    if (qist.overdue > 0.009) return make(WasooliUrgency.late, WasooliDateKind.qist, qist.nextDate, qist.overdue);
    if (qist.nextDate > 0) return make(byDate(qist.nextDate), WasooliDateKind.qist, qist.nextDate, qist.nextRemaining);
  }

  // Bill ki tareekh: sab se purani due date; bina-date bill => bill + 7 din (tab "late" ginte hain).
  var billDate = p.earliestDue;
  for (final b in p.bills) {
    if (b.isBalance || b.isAdvance || b.dueDate > 0 || b.createdAt <= 0) continue;
    final d = _sod(b.createdAt) + DueParty.undatedGraceDays * _dayMs;
    if (billDate == 0 || d < billDate) billDate = d;
  }
  if (billDate > 0 && _sod(billDate) < today) return make(WasooliUrgency.late, WasooliDateKind.bill, _sod(billDate));

  var best = billDate > 0 ? _sod(billDate) : 0;
  var kind = WasooliDateKind.bill;
  final pay = nextPayDay(paySchedule, today);
  if (pay > 0 && (best == 0 || pay < best)) {
    best = pay;
    kind = WasooliDateKind.payDay;
  }
  final fu = st.nextFollowUp;
  if (fu > 0 && (best == 0 || fu < best)) {
    best = fu < today ? today : fu;
    kind = WasooliDateKind.followUp;
  }
  // "Previous balance" (bina bill / bina tareekh) aur kuch tay nahi => aaj.
  if (best == 0) return make(WasooliUrgency.today, WasooliDateKind.bill, today);
  return make(byDate(best), kind, best);
}

/// Abhi ka khula toota wada promiseRecord() mein pehle se gina gaya (2 din se purana)?
bool _countedInRecord(FollowUpState st, int today) {
  final p = st.promise;
  return p != null && p.promiseDate < today - 2 * _dayMs;
}

enum WasooliFilter { all, late, today, week }

bool wasooliMatches(WasooliFilter f, WasooliRow r) {
  switch (f) {
    case WasooliFilter.all:
      return true;
    case WasooliFilter.late:
      return r.urgency == WasooliUrgency.late;
    case WasooliFilter.today:
      return r.urgency == WasooliUrgency.today;
    case WasooliFilter.week:
      return r.urgency != WasooliUrgency.late && r.date < r.today + 7 * _dayMs;
  }
}

/// Tarteeb: Late (zyada din pehle, phir zyada raqam), Aaj (zyada raqam), Aage (qareeb tareekh). Aaj jin se baat ho
/// chuki wo apne hisse mein neeche.
List<WasooliRow> sortWasooli(Iterable<WasooliRow> rows) {
  final list = rows.toList();
  int rank(WasooliRow r) => r.urgency.index;
  list.sort((a, b) {
    final u = rank(a).compareTo(rank(b));
    if (u != 0) return u;
    final t = (a.touchedToday ? 1 : 0).compareTo(b.touchedToday ? 1 : 0);
    if (t != 0) return t;
    switch (a.urgency) {
      case WasooliUrgency.late:
        final d = b.days.compareTo(a.days);
        if (d != 0) return d;
        return b.total.compareTo(a.total);
      case WasooliUrgency.today:
        return b.total.compareTo(a.total);
      case WasooliUrgency.later:
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : b.total.compareTo(a.total);
    }
  });
  return list;
}

class WasooliSummary {
  final double lateTotal;
  final int lateCount;
  final double todayTotal;
  final int todayCount;
  const WasooliSummary(this.lateTotal, this.lateCount, this.todayTotal, this.todayCount);
}

WasooliSummary summarizeWasooli(Iterable<WasooliRow> rows) {
  var lt = 0.0, tt = 0.0;
  var lc = 0, tc = 0;
  for (final r in rows) {
    if (r.urgency == WasooliUrgency.late) {
      lt += r.total;
      lc++;
    } else if (r.urgency == WasooliUrgency.today) {
      tt += r.hasPromise && r.amount > 0 ? r.amount : r.total;
      tc++;
    }
  }
  return WasooliSummary(lt, lc, tt, tc);
}

/// Jaldi wali tareekhen ("Kal", "3 din", "1 hafta", "Mahine ke aakhir").
int quickPromiseDate(String which, {int? nowMillis}) {
  final t = DateTime.fromMillisecondsSinceEpoch(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  switch (which) {
    case 'kal':
      return DateTime(t.year, t.month, t.day + 1).millisecondsSinceEpoch;
    case '3din':
      return DateTime(t.year, t.month, t.day + 3).millisecondsSinceEpoch;
    case 'hafta':
      return DateTime(t.year, t.month, t.day + 7).millisecondsSinceEpoch;
    case 'mahina':
    default:
      final end = DateTime(t.year, t.month + 1, 0);
      // Aaj hi mahine ka aakhri din ho to agle mahine ka aakhir.
      return (end.day == t.day ? DateTime(t.year, t.month + 2, 0) : end).millisecondsSinceEpoch;
  }
}
