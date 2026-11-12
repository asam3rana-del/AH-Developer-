import '../models/collection_autopilot.dart';
import 'app_database.dart';
import 'due_followup_repository.dart';
import 'due_reminders_repository.dart';
import 'qist_repository.dart';

/// Aaj ka poora wasooli manzar: autopilot queue + aaj customers se jitni raqam mili.
class AutopilotDay {
  final AutopilotQueue queue;

  /// Aaj ki tareekh wali customer payments ka jod (Party / Due screen se likhi hui).
  final double collectedToday;
  final int paymentsToday;
  const AutopilotDay({required this.queue, this.collectedToday = 0, this.paymentsToday = 0});

  static const empty = AutopilotDay(queue: AutopilotQueue.empty);
}

class CollectionAutopilotRepository {
  CollectionAutopilotRepository._();
  static final CollectionAutopilotRepository instance = CollectionAutopilotRepository._();

  /// customerId -> payment din (sirf jin ka set hai). Purani DB / ghalti => khali (autopilot pehle jaisa).
  Future<Map<int, String>> _paySchedules() async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('customers', columns: ['id', 'paySchedule'], where: "paySchedule != ''");
      return {for (final r in rows) r['id'] as int: (r['paySchedule'] as String?) ?? ''};
    } catch (_) {
      return const {};
    }
  }

  /// Aaj ki queue (late / pending / toote wade, kis ko aaj ho chuka) + aaj wasool hui raqam.
  /// Notification (background isolate) aur Wasooli Queue screen dono yahi use karte hain.
  Future<AutopilotDay> today({int? nowMillis}) async {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final bills = await DueRemindersRepository.instance.dueSales();
    final followUps = await DueFollowUpRepository.instance.allByParty();
    final queue = buildAutopilot(groupDueByParty(bills), followUps,
        nowMillis: now, paySchedules: await _paySchedules(), qist: await QistRepository.instance.allActive(nowMillis: now));

    var collected = 0.0;
    var count = 0;
    try {
      final db = await AppDatabase.instance.database;
      final start = startOfDayMillis(now);
      final rows = await db.rawQuery(
        "SELECT COALESCE(SUM(amount), 0) AS s, COUNT(*) AS n FROM payments "
        "WHERE partyType = 'customer' AND amount > 0 AND createdAt >= ? AND createdAt < ?",
        [start, start + 86400000],
      );
      if (rows.isNotEmpty) {
        collected = ((rows.first['s'] as num?) ?? 0).toDouble();
        count = ((rows.first['n'] as num?) ?? 0).toInt();
      }
    } catch (_) {
      // Raqam na mile to bhi queue dikhe.
    }
    return AutopilotDay(queue: queue, collectedToday: collected, paymentsToday: count);
  }
}
