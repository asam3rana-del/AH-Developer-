import 'dart:convert';

/// Qist (installment) plan: bara / purana baqi barabar hisson mein, har qist ki apni tareekh.
///
/// customers.qistPlan (TEXT JSON, DB v37), customer ke saath sync hota hai. Har qist ka alag record NAHI:
/// plan banne ke baad customer ki payments (payments table) jitni aayi, unhein tarteeb se qiston par lagate
/// hain — is liye "Paisa mila" pehle jaisa hi darj hota hai, kuch alag nahi karna. Sab PURE —
/// test/qist_plan_test.dart.
class QistPlan {
  /// Plan ki kul raqam.
  final double total;

  /// Kitni qisten (2..24).
  final int count;

  /// Pehli qist ki tareekh (din ki shuruaat, millis).
  final int firstDate;

  /// Har qist kitne din baad (7 / 15 / 30 ...).
  final int everyDays;

  /// Plan kab bana — is ke baad ki payments qiston mein ginti hain.
  final int createdAt;

  const QistPlan({
    required this.total,
    required this.count,
    required this.firstDate,
    required this.everyDays,
    required this.createdAt,
  });

  bool get valid => total > 0.009 && count >= 1 && count <= 60 && everyDays >= 1 && firstDate > 0;

  /// Qist [i] (0 se) ki raqam — poore rupay; rounding ka farq aakhri qist mein.
  double amountOf(int i) {
    final each = (total / count).floorToDouble();
    return i == count - 1 ? total - each * (count - 1) : each;
  }

  /// Qist [i] (0 se) ki tareekh (din ki shuruaat).
  int dateOf(int i) {
    final d = DateTime.fromMillisecondsSinceEpoch(firstDate);
    return DateTime(d.year, d.month, d.day + i * everyDays).millisecondsSinceEpoch;
  }

  String toJson() => jsonEncode({
        'total': total,
        'count': count,
        'firstDate': firstDate,
        'everyDays': everyDays,
        'createdAt': createdAt,
      });

  /// Khali / kharab JSON => null (plan nahi), kabhi crash nahi.
  static QistPlan? fromJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final p = QistPlan(
        total: (m['total'] as num).toDouble(),
        count: (m['count'] as num).toInt(),
        firstDate: (m['firstDate'] as num).toInt(),
        everyDays: (m['everyDays'] as num).toInt(),
        createdAt: (m['createdAt'] as num).toInt(),
      );
      return p.valid ? p : null;
    } catch (_) {
      return null;
    }
  }
}

class QistStatus {
  final QistPlan plan;

  /// Plan ke baad aayi payments (qiston par lagi).
  final double paid;

  /// Aaj tak jitni qisten due ho chuki, un ki kul raqam.
  final double dueByToday;

  /// Kitni qisten poori ada (tarteeb se).
  final int paidCount;

  /// Agli (pehli adhoori) qist: index (0 se), tareekh, us mein baqi raqam. Sab ada => index == count.
  final int nextIndex;
  final int nextDate;
  final double nextRemaining;

  /// Aaj ki tareekh guzri hui qiston mein baqi raqam (> 0 = late).
  final double overdue;

  const QistStatus({
    required this.plan,
    required this.paid,
    required this.dueByToday,
    required this.paidCount,
    required this.nextIndex,
    required this.nextDate,
    required this.nextRemaining,
    required this.overdue,
  });

  bool get completed => nextIndex >= plan.count;
  double get remaining => (plan.total - paid).clamp(0.0, plan.total).toDouble();
}

int _sod(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// [paidSince] = plan.createdAt ke baad customer ki payments ka jor.
QistStatus qistStatus(QistPlan plan, double paidSince, {int? nowMillis}) {
  final today = _sod(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  var left = paidSince < 0 ? 0.0 : paidSince;
  var paidCount = 0;
  var nextIndex = plan.count;
  var nextRemaining = 0.0;
  var dueByToday = 0.0;
  var overdue = 0.0;
  for (var i = 0; i < plan.count; i++) {
    final amt = plan.amountOf(i);
    final covered = left >= amt - 0.009 ? amt : left;
    left -= covered;
    final rem = amt - covered;
    final date = plan.dateOf(i);
    if (date <= today) {
      dueByToday += amt;
      if (date < today) overdue += rem;
    }
    if (rem <= 0.009) {
      if (nextIndex == plan.count) paidCount++;
    } else if (nextIndex == plan.count) {
      nextIndex = i;
      nextRemaining = rem;
    }
  }
  return QistStatus(
    plan: plan,
    paid: paidSince,
    dueByToday: dueByToday,
    paidCount: paidCount,
    nextIndex: nextIndex,
    nextDate: nextIndex < plan.count ? plan.dateOf(nextIndex) : 0,
    nextRemaining: nextRemaining,
    overdue: overdue,
  );
}

/// Autopilot ke liye: aaj qist ki tareekh hai, ya koi guzri hui qist adhoori hai.
bool qistNeedsTouch(QistStatus s, {int? nowMillis}) {
  if (s.completed) return false;
  final today = _sod(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
  return s.overdue > 0.009 || s.nextDate == today;
}
