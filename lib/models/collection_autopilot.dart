import '../db/due_followup_repository.dart';
import '../db/due_reminders_repository.dart';
import 'due_followup.dart';

/// Wasooli Autopilot (PURE — DB / UI nahi): "aaj kis ko yaad dilana hai" ki khud-ba-khud banne wali list.
///
/// Masla: late / pending party ka reminder tab tak nahi jata jab tak malik khud yaad rakh kar na bheje, aur
/// reminder bhejne ke baad bhi party list mein barabar "late" dikhti rehti hai — pata hi nahi chalta kis ko
/// aaj ho chuka aur kis ko nahi. Autopilot har late / due / toote-wade wali party ke liye:
///   * kabhi baat nahi hui  => TODO (foran)
///   * aakhri baat ke baad "gap" din guzar gaye => TODO
///   * aaj baat ho chuki (WhatsApp / call / nateeja) => DONE (list se neeche, ginti mein)
///   * gap abhi poora nahi hua => WAITING (kitne din baad phir)
/// Gap: toota wada 1 din, 30+ din purana baqi 2 din, baaqi 3 din. Dispute aur aage ke wade wali party roz nahi satayi jati.
/// Malik ka tay kiya hua follow-up / wada-aaj ka din gap ko override karta hai (sirf aaj ho chuka ho to DONE).

enum TouchReason { brokenPromise, promiseToday, followUpDue, late, dueToday }

enum TouchStatus { todo, doneToday, waiting }

class AutopilotItem {
  final DueParty party;
  final FollowUpState state;
  final TouchReason reason;
  final TouchStatus status;

  /// Sab se purane baqi bill ke din (0 = pata nahi / late nahi).
  final int oldestDays;

  /// Aakhri koshish ko kitne din hue (null = kabhi nahi hui).
  final int? daysSinceTouch;

  /// WAITING: kitne din baad phir yaad dilana hai.
  final int daysUntilTouch;

  /// Aaj is party ko kitni koshishen ho chuki.
  final int touchesToday;
  const AutopilotItem({
    required this.party,
    required this.state,
    required this.reason,
    required this.status,
    required this.oldestDays,
    required this.daysSinceTouch,
    this.daysUntilTouch = 0,
    this.touchesToday = 0,
  });

  double get total => party.total;
  bool get neverTouched => daysSinceTouch == null;
}

class AutopilotQueue {
  /// Aaj yaad dilana baqi (zaroori pehle).
  final List<AutopilotItem> todo;

  /// Aaj ho chuka.
  final List<AutopilotItem> done;

  /// Gap abhi poora nahi / dispute — aaj kuch nahi karna.
  final List<AutopilotItem> waiting;
  const AutopilotQueue({required this.todo, required this.done, required this.waiting});

  static const empty = AutopilotQueue(todo: [], done: [], waiting: []);

  double get todoAmount => todo.fold<double>(0.0, (a, e) => a + e.total);
  double get doneAmount => done.fold<double>(0.0, (a, e) => a + e.total);

  /// Aaj ka kul kaam (baqi + ho chuka).
  int get planned => todo.length + done.length;
  bool get isClear => todo.isEmpty;

  /// Jin late / due parties se abhi tak kabhi baat nahi hui.
  int get neverTouchedCount => todo.where((e) => e.neverTouched).length;

  int get brokenCount => todo.where((e) => e.reason == TouchReason.brokenPromise).length;
}

const int _dayMs = 86400000;

int _sod(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// Entry "koshish" hai (note ke ilawa kuch): WhatsApp / call / visit / sms, ya koi nateeja (paid, promised ...).
bool isTouch(DueFollowUp e) => e.method != FollowUpMethod.note || e.outcome != FollowUpOutcome.note;

/// Do koshishon ke beech kam az kam kitne din (shiddat ke hisaab se).
int touchGapDays({required int oldestDays, required bool broken}) {
  if (broken) return 1;
  if (oldestDays >= 30) return 2;
  return 3;
}

int _reasonRank(TouchReason r) {
  switch (r) {
    case TouchReason.brokenPromise:
      return 0;
    case TouchReason.promiseToday:
      return 1;
    case TouchReason.followUpDue:
      return 2;
    case TouchReason.late:
      return 3;
    case TouchReason.dueToday:
      return 4;
  }
}

/// Parties + follow-up entries => aaj ki autopilot queue. PURE (test ke liye).
AutopilotQueue buildAutopilot(
  Iterable<DueParty> parties,
  Map<int, List<DueFollowUp>> followUps, {
  int? nowMillis,
}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final today = _sod(now);
  final todo = <AutopilotItem>[];
  final done = <AutopilotItem>[];
  final waiting = <AutopilotItem>[];

  for (final p in parties) {
    final id = p.partyId;
    if (id == null || p.isAdvance || p.total <= 0.009) continue;
    final entries = followUps[id] ?? const <DueFollowUp>[];
    final st = followUpState(entries, nowMillis: now);
    final b = classifyCollection(p, st, nowMillis: now);

    TouchReason? found;
    if (st.promiseBroken) {
      found = TouchReason.brokenPromise;
    } else if (st.promiseToday) {
      found = TouchReason.promiseToday;
    } else if (st.followUpDue) {
      found = TouchReason.followUpDue;
    } else if (b.late) {
      found = TouchReason.late;
    } else if (b.dueToday) {
      found = TouchReason.dueToday;
    }
    if (found == null) continue; // abhi koi kaam nahi (wada pe / date door)
    final reason = found;

    final touches = entries.where(isTouch).toList()..sort((a, c) => c.createdAt.compareTo(a.createdAt));
    final touchesToday = touches.where((e) => e.createdAt >= today).length;
    final int? since = touches.isEmpty ? null : ((today - _sod(touches.first.createdAt)) / _dayMs).round();
    final oldest = p.oldestAgeDays(nowMillis: now);

    AutopilotItem item(TouchStatus s, {int wait = 0}) => AutopilotItem(
          party: p,
          state: st,
          reason: reason,
          status: s,
          oldestDays: oldest,
          daysSinceTouch: since,
          daysUntilTouch: wait,
          touchesToday: touchesToday,
        );

    if (st.dispute) {
      waiting.add(item(TouchStatus.waiting));
      continue;
    }
    if (touchesToday > 0) {
      done.add(item(TouchStatus.doneToday));
      continue;
    }
    final scheduled = reason == TouchReason.promiseToday || reason == TouchReason.followUpDue;
    if (since == null || scheduled) {
      todo.add(item(TouchStatus.todo));
      continue;
    }
    final gap = touchGapDays(oldestDays: oldest, broken: reason == TouchReason.brokenPromise);
    if (since >= gap) {
      todo.add(item(TouchStatus.todo));
    } else {
      waiting.add(item(TouchStatus.waiting, wait: gap - since));
    }
  }

  int byPriority(AutopilotItem a, AutopilotItem b) {
    final r = _reasonRank(a.reason).compareTo(_reasonRank(b.reason));
    if (r != 0) return r;
    final t = b.total.compareTo(a.total);
    return t != 0 ? t : a.party.partyName.toLowerCase().compareTo(b.party.partyName.toLowerCase());
  }

  todo.sort(byPriority);
  done.sort(byPriority);
  waiting.sort((a, b) {
    final w = a.daysUntilTouch.compareTo(b.daysUntilTouch);
    return w != 0 ? w : byPriority(a, b);
  });
  return AutopilotQueue(todo: todo, done: done, waiting: waiting);
}

String _rs(double v) => 'Rs ${v.round()}';

/// Malik ke liye notification ka matn (pure). [collectedToday] aaj mili raqam, [paymentsToday] kitni payments.
String autopilotNotificationBody(AutopilotQueue q, {double collectedToday = 0, int paymentsToday = 0, int topN = 3}) {
  final b = StringBuffer();
  if (q.todo.isNotEmpty) {
    b.write('${q.todo.length} parties ko yaad dilana baqi (${_rs(q.todoAmount)})');
    if (q.brokenCount > 0) b.write(' • ${q.brokenCount} ka wada toota');
    if (q.neverTouchedCount > 0) b.write(' • ${q.neverTouchedCount} se abhi tak baat nahi hui');
  } else {
    b.write('Aaj ke sab reminder ho chuke');
  }
  if (q.done.isNotEmpty) b.write(' • ${q.done.length} ko aaj bhej diya');
  if (paymentsToday > 0 || collectedToday > 0.009) {
    b.write(' • aaj wasool: ${_rs(collectedToday)}${paymentsToday > 0 ? ' ($paymentsToday payment)' : ''}');
  }
  if (q.todo.isNotEmpty) {
    b.write('. Pehle: ${q.todo.take(topN).map((e) => '${e.party.partyName} ${_rs(e.total)}').join(', ')}');
    b.write('. Tap karke 1-1 kar ke bhej dein.');
  } else {
    b.write('.');
  }
  return b.toString();
}
