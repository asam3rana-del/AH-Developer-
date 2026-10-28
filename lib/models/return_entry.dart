import 'dart:convert';

/// Amanat / Loan ki EK entry (ek customer kai bar loan ya amanat le sakta hai).
/// Customer ki `returnEntries` column mein JSON list ke taur par rehti hai (customer ke saath hi sync hoti hai).
/// [amount] hamesha musbat; balance par asar `kind` se nikalta hai (amanat = minus, loan = plus).
class ReturnEntry {
  final int id;
  final double amount;

  /// Kab liya / diya (din ki shuruaat, millis). 0 = maloom nahi.
  final int date;

  /// Is entry ki wapsi ki tarikh. 0 = set nahi.
  final int returnDate;
  final String note;

  const ReturnEntry({required this.id, required this.amount, this.date = 0, this.returnDate = 0, this.note = ''});

  ReturnEntry copyWith({double? amount, int? date, int? returnDate, String? note}) => ReturnEntry(
        id: id,
        amount: amount ?? this.amount,
        date: date ?? this.date,
        returnDate: returnDate ?? this.returnDate,
        note: note ?? this.note,
      );

  Map<String, Object?> toJson() => {'id': id, 'amount': amount, 'date': date, 'returnDate': returnDate, 'note': note};

  static ReturnEntry? fromJson(Object? m) {
    if (m is! Map) return null;
    final id = (m['id'] as num?)?.toInt();
    final amount = (m['amount'] as num?)?.toDouble();
    if (id == null || amount == null) return null;
    return ReturnEntry(
      id: id,
      amount: amount.abs(),
      date: (m['date'] as num?)?.toInt() ?? 0,
      returnDate: (m['returnDate'] as num?)?.toInt() ?? 0,
      note: (m['note'] as String?) ?? '',
    );
  }
}

/// JSON text => entries. Khali / kharab text => khali list (kabhi crash nahi).
List<ReturnEntry> decodeReturnEntries(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <ReturnEntry>[];
  try {
    final v = jsonDecode(raw);
    if (v is! List) return <ReturnEntry>[];
    final out = <ReturnEntry>[];
    for (final e in v) {
      final r = ReturnEntry.fromJson(e);
      if (r != null) out.add(r);
    }
    return out;
  } catch (_) {
    return <ReturnEntry>[];
  }
}

/// Entries => JSON text ('' agar khali).
String encodeReturnEntries(List<ReturnEntry> list) =>
    list.isEmpty ? '' : jsonEncode([for (final e in list) e.toJson()]);

/// Balance par asar: amanat (dukaan ne dena hai) = minus, loan (customer ne dena hai) = plus.
double signedReturnAmount(String kind, double amount) => kind == 'amanat' ? -amount.abs() : amount.abs();

double signedReturnTotal(String kind, List<ReturnEntry> list) =>
    list.fold<double>(0.0, (a, e) => a + signedReturnAmount(kind, e.amount));

int nextReturnEntryId(List<ReturnEntry> list) => list.fold<int>(0, (a, e) => e.id > a ? e.id : a) + 1;

/// Sab entries mein se sab se pehli wapsi ki tarikh (0 = kisi mein nahi).
int earliestReturnDate(List<ReturnEntry> list) {
  var best = 0;
  for (final e in list) {
    if (e.returnDate > 0 && (best == 0 || e.returnDate < best)) best = e.returnDate;
  }
  return best;
}

/// Wapsi / wasooli: [amount] entries mein se FIFO (sab se purani wapsi ki tarikh pehle, tarikh na ho to
/// sab se aakhir mein; barabar par purani date, phir id) ghatata hai. Poori khatam hui entry list se
/// nikal jati hai, adhoori ka amount kam hota hai. [amount] kul se zyada ho to sirf kul tak settle hota hai.
/// Lautata hai: bachi hui entries aur asal mein settle hui raqam.
({List<ReturnEntry> remaining, double settled}) settleEntriesFifo(List<ReturnEntry> entries, double amount) {
  final order = List<ReturnEntry>.of(entries)
    ..sort((a, b) {
      final ar = a.returnDate > 0 ? a.returnDate : 1 << 62;
      final br = b.returnDate > 0 ? b.returnDate : 1 << 62;
      if (ar != br) return ar.compareTo(br);
      if (a.date != b.date) return a.date.compareTo(b.date);
      return a.id.compareTo(b.id);
    });
  var left = amount;
  var settled = 0.0;
  final byId = <int, ReturnEntry?>{for (final e in entries) e.id: e};
  for (final e in order) {
    if (left <= 0.004) break;
    if (left + 0.004 >= e.amount) {
      left -= e.amount;
      settled += e.amount;
      byId[e.id] = null;
    } else {
      byId[e.id] = e.copyWith(amount: e.amount - left);
      settled += left;
      left = 0;
    }
  }
  return (
    remaining: [for (final e in entries) if (byId[e.id] != null) byId[e.id]!],
    settled: settled,
  );
}

/// Entries ka kul (musbat) amount.
double returnEntriesTotal(List<ReturnEntry> list) => list.fold<double>(0.0, (a, e) => a + e.amount);

// ---------------------------------------------------------------------------
// Amanat / Loan LOG (DB v32) — party ledger / statement ke liye sirf-dikhane wali history.
// ---------------------------------------------------------------------------

/// Log ki row ki qism.
///  * given     — loan diya / amanat li (entry add hui)
///  * recovered — loan wasool hua / amanat wapas ki (settle)
///  * adjusted  — entry ka amount edit hua ([ReturnLogRow.amount] SIGNED farq: + barha, - kam hua)
///  * removed   — galat entry hata di (bachi hui raqam, musbat)
const kLogGiven = 'given';
const kLogRecovered = 'recovered';
const kLogAdjusted = 'adjusted';
const kLogRemoved = 'removed';

/// Log ki EK row. Customer ke `returnLog` column mein JSON list (customer ke saath hi sync hoti hai).
/// Sirf dikhane ke liye: balance ka asli hisaab `openingBalance` mein hi hai, log kabhi balance nahi badalta.
class ReturnLogRow {
  final int id;
  final String type;

  /// 'amanat' | 'loan' — us waqt party ki qism.
  final String kind;

  /// given / recovered / removed: musbat. adjusted: signed farq.
  final double amount;

  /// Din / waqt (millis). 0 = maloom nahi.
  final int date;
  final String note;

  /// Jis entry se juri hai (0 = koi nahi). Edit par date / note usi row mein update hote hain.
  final int entryId;

  const ReturnLogRow({
    required this.id,
    required this.type,
    required this.kind,
    required this.amount,
    this.date = 0,
    this.note = '',
    this.entryId = 0,
  });

  ReturnLogRow copyWith({double? amount, int? date, String? note}) => ReturnLogRow(
        id: id,
        type: type,
        kind: kind,
        amount: amount ?? this.amount,
        date: date ?? this.date,
        note: note ?? this.note,
        entryId: entryId,
      );

  /// Opening balance par is row ka asar (amanat = minus, loan = plus; wasooli / hatana ulta).
  double get balanceEffect {
    final sign = kind == 'amanat' ? -1.0 : 1.0;
    switch (type) {
      case kLogGiven:
      case kLogAdjusted:
        return sign * amount;
      case kLogRecovered:
      case kLogRemoved:
        return -sign * amount.abs();
    }
    return 0.0;
  }

  Map<String, Object?> toJson() =>
      {'id': id, 'type': type, 'kind': kind, 'amount': amount, 'date': date, 'note': note, 'entryId': entryId};

  static ReturnLogRow? fromJson(Object? m) {
    if (m is! Map) return null;
    final id = (m['id'] as num?)?.toInt();
    final amount = (m['amount'] as num?)?.toDouble();
    final type = m['type'] as String?;
    if (id == null || amount == null || type == null) return null;
    if (type != kLogGiven && type != kLogRecovered && type != kLogAdjusted && type != kLogRemoved) return null;
    final k = (m['kind'] as String?) ?? 'loan';
    return ReturnLogRow(
      id: id,
      type: type,
      kind: k == 'amanat' ? 'amanat' : 'loan',
      amount: type == kLogAdjusted ? amount : amount.abs(),
      date: (m['date'] as num?)?.toInt() ?? 0,
      note: (m['note'] as String?) ?? '',
      entryId: (m['entryId'] as num?)?.toInt() ?? 0,
    );
  }
}

/// JSON text => log rows. Khali / kharab text => khali list (kabhi crash nahi).
List<ReturnLogRow> decodeReturnLog(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <ReturnLogRow>[];
  try {
    final v = jsonDecode(raw);
    if (v is! List) return <ReturnLogRow>[];
    final out = <ReturnLogRow>[];
    for (final e in v) {
      final r = ReturnLogRow.fromJson(e);
      if (r != null) out.add(r);
    }
    return out;
  } catch (_) {
    return <ReturnLogRow>[];
  }
}

/// Log rows => JSON text ('' agar khali).
String encodeReturnLog(List<ReturnLogRow> list) =>
    list.isEmpty ? '' : jsonEncode([for (final e in list) e.toJson()]);

int nextReturnLogId(List<ReturnLogRow> list) => list.fold<int>(0, (a, e) => e.id > a ? e.id : a) + 1;

/// Log ke sab rows ka kul asar (opening balance ke entries wale hisse jaisa hona chahiye).
double returnLogNet(List<ReturnLogRow> list) => list.fold<double>(0.0, (a, r) => a + r.balanceEffect);

/// Naye entry ke liye 'given' row (entry add hone par).
List<ReturnLogRow> logAddGiven(List<ReturnLogRow> log, String kind, ReturnEntry e, {int? atMillis}) => [
      ...log,
      ReturnLogRow(
        id: nextReturnLogId(log),
        type: kLogGiven,
        kind: kind,
        amount: e.amount.abs(),
        date: e.date > 0 ? e.date : (atMillis ?? 0),
        note: e.note,
        entryId: e.id,
      ),
    ];

/// Entry edit: us entry ki 'given' row ki date / note update; amount ka farq ho to 'adjusted' row.
List<ReturnLogRow> logEditEntry(List<ReturnLogRow> log, String kind, ReturnEntry old, ReturnEntry updated,
    {int? atMillis}) {
  final out = <ReturnLogRow>[
    for (final r in log)
      (r.type == kLogGiven && r.entryId == old.id)
          ? r.copyWith(date: updated.date > 0 ? updated.date : r.date, note: updated.note)
          : r,
  ];
  final delta = updated.amount - old.amount;
  if (delta.abs() > 0.004) {
    out.add(ReturnLogRow(
      id: nextReturnLogId(out),
      type: kLogAdjusted,
      kind: kind,
      amount: delta,
      date: atMillis ?? 0,
      note: updated.note,
      entryId: old.id,
    ));
  }
  return out;
}

/// Entry delete: bachi hui raqam ki 'removed' row (purani rows hamesha rehti hain).
List<ReturnLogRow> logRemoveEntry(List<ReturnLogRow> log, String kind, ReturnEntry old, {int? atMillis}) => [
      ...log,
      ReturnLogRow(
        id: nextReturnLogId(log),
        type: kLogRemoved,
        kind: kind,
        amount: old.amount.abs(),
        date: atMillis ?? 0,
        note: old.note,
        entryId: old.id,
      ),
    ];

/// Settle (wasooli / wapsi): ek 'recovered' row.
List<ReturnLogRow> logRecovered(List<ReturnLogRow> log, String kind, double amount, {int atMillis = 0, String note = ''}) =>
    [
      ...log,
      ReturnLogRow(
        id: nextReturnLogId(log),
        type: kLogRecovered,
        kind: kind,
        amount: amount.abs(),
        date: atMillis,
        note: note,
      ),
    ];

/// Purani entries se (log nahi) pehli dafa log banana: har entry ki maujooda raqam 'given' ke taur par.
/// (Pehle ki wasooliyon ki asal raqam maloom nahi — wo [logGap] ki "untracked" row mein aati hain.)
List<ReturnLogRow> backfillReturnLog(String kind, List<ReturnEntry> entries, {int? atMillis}) {
  var log = <ReturnLogRow>[];
  for (final e in entries) {
    log = logAddGiven(log, kind, e, atMillis: atMillis);
  }
  return log;
}

/// Log aur entries ka farq: entries ka asli asar minus log ka asar. 0 ke qareeb => log poora hai.
/// Nonzero (purani device ne entries badli / log bana nahi) => UI ek "untracked" adjusted row dikhata hai
/// taake ledger hamesha opening balance se milay.
double logGap(String kind, List<ReturnEntry> entries, List<ReturnLogRow> log) {
  final gap = signedReturnTotal(kind, entries) - returnLogNet(log);
  return gap.abs() < 0.009 ? 0.0 : gap;
}

/// Party ledger mein dikhane wali rows: log + (agar log entries se na mile) ek "untracked" adjusted row
/// (id = -1) taake ledger ka kul hamesha entries / opening balance se milay.
List<ReturnLogRow> ledgerLogRows(String kind, List<ReturnEntry> entries, List<ReturnLogRow> log) {
  final k = kind == 'amanat' ? 'amanat' : 'loan';
  final gap = logGap(k, entries, log);
  if (gap == 0.0) return log;
  final sign = k == 'amanat' ? -1.0 : 1.0;
  return [
    ...log,
    ReturnLogRow(id: -1, type: kLogAdjusted, kind: k, amount: gap * sign, date: 0, note: 'untracked'),
  ];
}
