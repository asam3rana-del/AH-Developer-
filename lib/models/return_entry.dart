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
