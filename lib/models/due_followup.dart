/// Due Reminders follow-up log (table: due_followups).
///
/// Har entry = customer se wasooli ki ek koshish / baat: kab, kis tareeqe se, nateeja kya raha, kya wada
/// hua (tareekh + raqam) aur agla follow-up kab karna hai.
///
/// Saara faisla (aaj kya karna hai, wada toota ya nahi, kis message ki shiddat) PURE functions mein hai
/// taake bina DB / UI ke test ho — test/due_followup_test.dart.
class FollowUpMethod {
  FollowUpMethod._();
  static const whatsapp = 'whatsapp';
  static const call = 'call';
  static const visit = 'visit';
  static const sms = 'sms';
  static const note = 'note';
  static const all = [whatsapp, call, visit, sms, note];
}

class FollowUpOutcome {
  FollowUpOutcome._();

  /// Reminder bhej diya / call kar di, nateeja abhi likha nahi (khud ban'ne wali entry).
  static const sent = 'sent';
  static const paid = 'paid';
  static const promised = 'promised';
  static const partial = 'partial';
  static const noAnswer = 'no_answer';
  static const refused = 'refused';
  static const dispute = 'dispute';
  static const note = 'note';

  /// Nateeja chunne wali sheet ke buttons (is tarteeb mein).
  static const choices = [paid, promised, partial, noAnswer, refused, dispute, note];
}

const int _dayMs = 86400000;

/// Din ki shuruaat (00:00 local).
int _startOfDay(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

class DueFollowUp {
  final int? id;
  final int partyId;
  final String partyName;
  final String method;
  final String outcome;

  /// Mili hui (paid / partial) ya wada ki hui raqam. 0 = nahi likhi.
  final double amount;

  /// Wada ki tareekh (din ki shuruaat, millis). 0 = wada nahi.
  final int promiseDate;

  /// Agla follow-up kab (din ki shuruaat, millis). 0 = tay nahi.
  final int nextFollowUp;
  final String note;
  final String staff;
  final int createdAt;

  const DueFollowUp({
    this.id,
    required this.partyId,
    this.partyName = '',
    this.method = FollowUpMethod.note,
    this.outcome = FollowUpOutcome.note,
    this.amount = 0,
    this.promiseDate = 0,
    this.nextFollowUp = 0,
    this.note = '',
    this.staff = '',
    required this.createdAt,
  });

  DueFollowUp copyWith({
    String? outcome,
    double? amount,
    int? promiseDate,
    int? nextFollowUp,
    String? note,
  }) =>
      DueFollowUp(
        id: id,
        partyId: partyId,
        partyName: partyName,
        method: method,
        outcome: outcome ?? this.outcome,
        amount: amount ?? this.amount,
        promiseDate: promiseDate ?? this.promiseDate,
        nextFollowUp: nextFollowUp ?? this.nextFollowUp,
        note: note ?? this.note,
        staff: staff,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'partyId': partyId,
        'partyName': partyName,
        'method': method,
        'outcome': outcome,
        'amount': amount,
        'promiseDate': promiseDate,
        'nextFollowUp': nextFollowUp,
        'note': note,
        'staff': staff,
        'createdAt': createdAt,
      };

  factory DueFollowUp.fromMap(Map<String, Object?> m) => DueFollowUp(
        id: (m['id'] as num?)?.toInt(),
        partyId: (m['partyId'] as num?)?.toInt() ?? 0,
        partyName: (m['partyName'] as String?) ?? '',
        method: (m['method'] as String?) ?? FollowUpMethod.note,
        outcome: (m['outcome'] as String?) ?? FollowUpOutcome.note,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        promiseDate: ((m['promiseDate'] as num?) ?? 0).toInt(),
        nextFollowUp: ((m['nextFollowUp'] as num?) ?? 0).toInt(),
        note: (m['note'] as String?) ?? '',
        staff: (m['staff'] as String?) ?? '',
        createdAt: ((m['createdAt'] as num?) ?? 0).toInt(),
      );
}

/// Newest pehle (createdAt, phir id).
List<DueFollowUp> sortFollowUpsNewestFirst(Iterable<DueFollowUp> entries) {
  final list = entries.toList();
  list.sort((a, b) {
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : (b.id ?? 0).compareTo(a.id ?? 0);
  });
  return list;
}

/// Ek party ki follow-up halat (entries se nikali hui).
///
/// Qaide:
///  * "sent" (sirf bheja, nateeja nahi likha) entry wada / agla follow-up / dispute ka faisla nahi badalti —
///    sirf "aakhri baat" ki tareekh aur ginti mein ginti hai.
///  * Wada = sab se nayi (non-sent) entry jis par promiseDate hai. Us ke baad paid / refused / dispute
///    aa jaye to wada khatam (active nahi).
///  * Wada active hai aur tareekh aaj se pehle ki ho => TOOTA (broken).
///  * Agla follow-up = sab se nayi non-sent entry ka nextFollowUp.
///  * Dispute = sab se nayi non-sent entry ka nateeja dispute.
class FollowUpState {
  final DueFollowUp? last;
  final int contactCount;
  final DueFollowUp? promise;
  final bool promiseBroken;
  final int nextFollowUp;
  final bool dispute;
  final int today;

  const FollowUpState({
    required this.last,
    required this.contactCount,
    required this.promise,
    required this.promiseBroken,
    required this.nextFollowUp,
    required this.dispute,
    required this.today,
  });

  /// Kabhi koi baat / reminder nahi hui.
  bool get never => last == null;

  int get lastContactAt => last?.createdAt ?? 0;

  /// Wada hai aur abhi uski tareekh nahi guzri (aaj ya aage).
  bool get onPromise => promise != null && !promiseBroken;

  /// Wada aaj ki tareekh ka hai.
  bool get promiseToday => onPromise && promise!.promiseDate == today;

  /// Tay kiya hua follow-up aaj ya pehle ka hai (aur dispute / aage ke wade ki wajah se roka nahi gaya).
  bool get followUpDue => !dispute && nextFollowUp > 0 && nextFollowUp <= today;

  /// Aaj is party par kaam karna hai: toota wada, follow-up ka din, ya wada aaj ka.
  bool get needsActionToday => promiseBroken || followUpDue || promiseToday;

  /// Aakhri baat ko kitne din hue (kabhi nahi hui => null).
  int? daysSinceContact(int nowMillis) {
    if (last == null) return null;
    final d = (today - _startOfDay(last!.createdAt)) / _dayMs;
    return d < 0 ? 0 : d.round();
  }
}

FollowUpState followUpState(Iterable<DueFollowUp> entries, {int? nowMillis}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final today = _startOfDay(now);
  final all = sortFollowUpsNewestFirst(entries);
  final real = all.where((e) => e.outcome != FollowUpOutcome.sent).toList();

  DueFollowUp? promise;
  for (var i = 0; i < real.length; i++) {
    if (real[i].promiseDate <= 0) continue;
    var resolved = false;
    for (var j = 0; j < i; j++) {
      final o = real[j].outcome;
      if (o == FollowUpOutcome.paid || o == FollowUpOutcome.refused || o == FollowUpOutcome.dispute) {
        resolved = true;
        break;
      }
    }
    if (!resolved) promise = real[i];
    break;
  }

  final governing = real.isEmpty ? null : real.first;
  return FollowUpState(
    last: all.isEmpty ? null : all.first,
    contactCount: all.length,
    promise: promise,
    promiseBroken: promise != null && promise.promiseDate < today,
    nextFollowUp: governing?.nextFollowUp ?? 0,
    dispute: governing?.outcome == FollowUpOutcome.dispute,
    today: today,
  );
}

/// Party ke wade ka record: kitne wade hue, kitne poore (is ke baad paid / partial entry, wada-tareekh ke
/// 2 din ke andar tak) aur kitne toote. Jo wade abhi aane wale / guzre nahi unhe nahi ginta.
({int made, int kept, int broken}) promiseRecord(Iterable<DueFollowUp> entries, {int? nowMillis}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final today = _startOfDay(now);
  final all = sortFollowUpsNewestFirst(entries).reversed.toList(); // purana pehle
  var kept = 0;
  var broken = 0;
  var made = 0;
  for (var i = 0; i < all.length; i++) {
    final p = all[i];
    if (p.promiseDate <= 0 || p.outcome == FollowUpOutcome.sent) continue;
    final deadline = p.promiseDate + 2 * _dayMs;
    var ok = false;
    for (var j = i + 1; j < all.length; j++) {
      final e = all[j];
      if (e.createdAt > deadline) break;
      if (e.outcome == FollowUpOutcome.paid || (e.outcome == FollowUpOutcome.partial && e.amount > 0)) {
        ok = true;
        break;
      }
    }
    if (ok) {
      made++;
      kept++;
    } else if (p.promiseDate < today - 2 * _dayMs) {
      made++;
      broken++;
    }
  }
  return (made: made, kept: kept, broken: broken);
}

/// Filter chips (Due Reminders screen).
/// `focus` / `collectToday` / `late` home ke "Aaj ki Wasooli" card ke hisaab se hain (party chahiye, is liye
/// [partyMatchesFilter] istemal karo); baqi sirf follow-up state se.
enum FollowUpFilter { all, focus, collectToday, late, brokenPromise, today, onPromise, neverContacted, dispute }

bool followUpMatches(FollowUpFilter f, FollowUpState s) {
  switch (f) {
    case FollowUpFilter.all:
      return true;
    case FollowUpFilter.focus:
    case FollowUpFilter.collectToday:
    case FollowUpFilter.late:
      return true; // bill ki tareekh bhi dekhni parti hai => partyMatchesFilter()
    case FollowUpFilter.today:
      return s.needsActionToday;
    case FollowUpFilter.brokenPromise:
      return s.promiseBroken;
    case FollowUpFilter.onPromise:
      return s.onPromise;
    case FollowUpFilter.neverContacted:
      return s.never;
    case FollowUpFilter.dispute:
      return s.dispute;
  }
}

/// Sort ki tarteeb (chhota number pehle): 0 toota wada, 1 aaj karna hai, 2 aam, 3 wada pe (aage ki tareekh),
/// 4 dispute. Wada pe wali party roz na satayi jaye, is liye neeche.
int followUpRank(FollowUpState s) {
  if (s.promiseBroken) return 0;
  if (s.dispute) return 4;
  if (s.needsActionToday) return 1;
  if (s.onPromise) return 3;
  return 2;
}

/// Reminder ki shiddat: pichle 45 din mein jitne WhatsApp / SMS reminder gaye (0 = pehli baar, 1, 2+).
int reminderLevel(Iterable<DueFollowUp> entries, {int? nowMillis}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final since = now - 45 * _dayMs;
  var n = 0;
  for (final e in entries) {
    if (e.createdAt < since) continue;
    if (e.method == FollowUpMethod.whatsapp || e.method == FollowUpMethod.sms) n++;
  }
  return n > 2 ? 2 : n;
}

/// WhatsApp message ka ibarat (level 0 naram, 1 saaf, 2 sakht) + toote wade ka zikr. Roman Urdu (jaisa pehle).
/// [rs] poore rupay ka text, [oldestDays] sab se purane overdue bill ke din (0 = nahi pata / overdue nahi).
String followUpMessage({
  required int level,
  required String name,
  required String rs,
  int oldestDays = 0,
  DateTime? brokenPromiseDate,
  double brokenPromiseAmount = 0,
}) {
  final age = oldestDays > 0 ? ' (sab se purana bill $oldestDays din ka)' : '';
  final promise = brokenPromiseDate == null
      ? ''
      : ' Aap ne ${brokenPromiseDate.day}/${brokenPromiseDate.month} tak'
          '${brokenPromiseAmount > 0 ? ' Rs ${brokenPromiseAmount.toStringAsFixed(0)}' : ''} ada karne ka wada kiya tha, '
          'lekin abhi tak ada nahi hua.';
  switch (level) {
    case 0:
      return 'Assalam o Alaikum $name, aapke hisab mein Rs $rs abhi baaki hai$age.$promise '
          'Barah-e-karam jald ada karein. Shukriya!';
    case 1:
      return 'Assalam o Alaikum $name, pehle bhi yaad dihani ki thi: aapke hisab mein Rs $rs baaki hai$age.$promise '
          'Barah-e-karam aaj ya kal tak ada kar dein. Shukriya!';
    default:
      return 'Assalam o Alaikum $name, aapke hisab mein Rs $rs kaafi arse se baaki hai$age.$promise '
          'Mehrbani kar ke is hafte ke andar ada kar dein, ya ada karne ki tareekh bata dein. Shukriya.';
  }
}
