import '../models/wasooli_plan.dart';
import 'app_database.dart';
import 'due_followup_repository.dart';
import 'due_reminders_repository.dart';
import 'qist_repository.dart';

class WasooliDay {
  final List<WasooliRow> rows;
  final WasooliSummary summary;

  /// Aaj customers se jitna mila.
  final double collectedToday;
  const WasooliDay(this.rows, this.summary, this.collectedToday);
}

/// Wasooli ek-page ka data: sirf customers (Sales) ke baqi, har party ki ek "agli tareekh".
class WasooliRepository {
  WasooliRepository._();
  static final WasooliRepository instance = WasooliRepository._();

  Future<Map<int, String>> _paySchedules() async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('customers', columns: ['id', 'paySchedule'], where: "paySchedule != ''");
      return {for (final r in rows) r['id'] as int: (r['paySchedule'] as String?) ?? ''};
    } catch (_) {
      return const {};
    }
  }

  Future<WasooliDay> load({int? nowMillis}) async {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final bills = await DueRemindersRepository.instance.dueSales();
    final followUps = await DueFollowUpRepository.instance.allByParty(backfillSync: true);
    final pay = await _paySchedules();
    final qist = await QistRepository.instance.allActive(nowMillis: now);
    final dueDays = await DueRemindersRepository.instance.customerDueDaysMap();
    final rows = <WasooliRow>[];
    for (final p in groupDueByParty(bills)) {
      final id = p.partyId;
      if (!p.isSale || id == null || p.isAdvance || p.total <= 0.009) continue;
      rows.add(buildWasooliRow(
        p,
        followUps[id] ?? const [],
        nowMillis: now,
        paySchedule: pay[id] ?? '',
        qist: qist[id],
        customerDueDays: dueDays[id] ?? 0,
      ));
    }
    final sorted = sortWasooli(rows);

    var collected = 0.0;
    try {
      final db = await AppDatabase.instance.database;
      final start = startOfDayMillis(now);
      final r = await db.rawQuery(
        "SELECT COALESCE(SUM(amount), 0) AS s FROM payments "
        "WHERE partyType = 'customer' AND amount > 0 AND createdAt >= ? AND createdAt < ?",
        [start, start + 86400000],
      );
      if (r.isNotEmpty) collected = ((r.first['s'] as num?) ?? 0).toDouble();
    } catch (_) {}
    return WasooliDay(sorted, summarizeWasooli(sorted), collected);
  }

  /// Ek party ki taaza row (party screen par kaam ke baad).
  Future<WasooliRow?> row(int partyId, {int? nowMillis}) async {
    final day = await load(nowMillis: nowMillis);
    for (final r in day.rows) {
      if (r.party.partyId == partyId) return r;
    }
    return null;
  }
}
