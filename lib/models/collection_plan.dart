import '../db/due_reminders_repository.dart';

/// Wasooli ka hisaab (PURE — DB / UI nahi): customer ne Rs X diye to wo kin bills par lagenge.
///
/// Raqam SAB SE PURANE bill se shuru karke aage barhti hai (FIFO), phir "Previous balance"
/// (bina bill ka purana hisaab), aur jo bach jaye wo advance.

/// Ek bill ka hissa.
class BillShare {
  final String billRef;
  final double amount;

  /// Is hissa ke baad bill poora ada ho jata hai.
  final bool clearsBill;
  const BillShare(this.billRef, this.amount, {required this.clearsBill});
}

class CollectionPlan {
  final List<BillShare> shares;

  /// "Previous balance" (bina bill wala hisaab) par lagne wali raqam — payment bill se link nahi hoti.
  final double toPreviousBalance;

  /// Sab kuch chukane ke baad bachi raqam (customer ka advance).
  final double advance;

  /// Payment ke baad party ka baaqi (>= 0).
  final double remainingAfter;
  const CollectionPlan({
    required this.shares,
    required this.toPreviousBalance,
    required this.advance,
    required this.remainingAfter,
  });

  double get toBills => shares.fold<double>(0.0, (s, e) => s + e.amount);
}

/// Wasooli ke liye khule bills: sirf asli bills (advance / "Previous balance" nahi), sab se purana pehle.
List<DueBill> openBillsForCollection(Iterable<DueBill> partyRows) {
  final bills = partyRows.where((b) => !b.isBalance && !b.isAdvance && b.due > 0.009).toList()
    ..sort((a, b) {
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return bills;
}

/// "Previous balance" row ka baaqi (nahi ho to 0).
double previousBalanceOf(Iterable<DueBill> partyRows) =>
    partyRows.where((b) => b.isBalance && !b.isAdvance).fold<double>(0.0, (s, b) => s + (b.due > 0 ? b.due : 0.0));

/// [amount] ko [bills] (pehle se purane-pehle tarteeb mein, dekhein [openBillsForCollection]) par bantta hai.
CollectionPlan planCollection({
  required double amount,
  required List<DueBill> bills,
  double previousBalance = 0,
}) {
  var left = amount.isFinite && amount > 0 ? amount : 0.0;
  final shares = <BillShare>[];
  var billsDue = 0.0;
  for (final b in bills) {
    billsDue += b.due;
    if (left <= 0.009) continue;
    final take = left < b.due ? left : b.due;
    shares.add(BillShare(b.id, take, clearsBill: (b.due - take) <= 0.009));
    left -= take;
  }
  var prev = 0.0;
  if (left > 0.009 && previousBalance > 0.009) {
    prev = left < previousBalance ? left : previousBalance;
    left -= prev;
  }
  final advance = left > 0.009 ? left : 0.0;
  final totalDue = billsDue + (previousBalance > 0 ? previousBalance : 0.0);
  final after = totalDue - (amount.isFinite && amount > 0 ? amount : 0.0);
  return CollectionPlan(
    shares: shares,
    toPreviousBalance: prev,
    advance: advance,
    remainingAfter: after > 0.009 ? after : 0.0,
  );
}

String _rs(double v) => v.toStringAsFixed(0);

String _dm(int millis) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.day} ${m[d.month - 1]}';
}

/// Kai khule bills wale customer ka reminder: har bill ki alag line (invoice, tareekh, baqi, kitne din late),
/// taake customer ko saaf pata chale kis bill ka kitna baqi hai.
String itemizedReminderMessage({
  required String partyName,
  required List<DueBill> bills,
  required double total,
  double previousBalance = 0,
  required int nowMillis,
}) {
  final today = startOfDayMillis(nowMillis);
  final b = StringBuffer('Assalam o Alaikum $partyName, aapke ye bills abhi baaki hain:\n');
  for (final x in bills) {
    final dueTxt = x.due.toStringAsFixed(0);
    var line = '• ${x.id}';
    if (x.createdAt > 0) line += ' (${_dm(x.createdAt)})';
    line += ': Rs $dueTxt';
    if (x.dueDate > 0 && x.dueDate < today) {
      final late = ((today - startOfDayMillis(x.dueDate)) / 86400000).round();
      if (late > 0) line += ' — $late din late';
    } else if (x.dueDate <= 0 && x.createdAt > 0) {
      final age = ((today - startOfDayMillis(x.createdAt)) / 86400000).round();
      if (age > 0) line += ' — $age din purana';
    }
    b.writeln(line);
  }
  if (previousBalance > 0.009) b.writeln('• Previous balance: Rs ${_rs(previousBalance)}');
  b.write('Kul baqi: Rs ${_rs(total)}. Barah-e-karam jald ada karein. Shukriya!');
  return b.toString();
}
