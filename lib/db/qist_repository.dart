import '../models/party.dart';
import '../models/qist_plan.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'party_repository.dart';

/// Qist plan parhna / lagana / hatana. Plan customer row (customers.qistPlan) mein hai, is liye save
/// [PartyRepository.updateCustomer] se — wohi sync queue, koi naya table / collection nahi.
class QistRepository {
  QistRepository._();
  static final QistRepository instance = QistRepository._();

  Future<Customer?> customer(int id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('customers', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Customer.fromMap(rows.first);
  }

  /// Plan banne ([since]) ke baad customer ki wasooli (payments, sirf musbat).
  Future<double> paidSince(int customerId, int since) async {
    final db = await AppDatabase.instance.database;
    final r = await db.rawQuery(
      "SELECT COALESCE(SUM(amount), 0) AS s FROM payments "
      "WHERE partyType = 'customer' AND partyId = ? AND amount > 0 AND createdAt >= ?",
      [customerId, since],
    );
    return (r.first['s'] as num?)?.toDouble() ?? 0.0;
  }

  /// Plan nahi => null.
  Future<QistStatus?> status(int customerId, {int? nowMillis}) async {
    final c = await customer(customerId);
    final plan = c == null ? null : QistPlan.fromJson(c.qistPlan);
    if (plan == null) return null;
    return qistStatus(plan, await paidSince(customerId, plan.createdAt), nowMillis: nowMillis);
  }

  /// Sab customers jin ka plan hai (Autopilot). Ghalti => khali (autopilot pehle jaisa).
  Future<Map<int, QistStatus>> allActive({int? nowMillis}) async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('customers', columns: ['id', 'qistPlan'], where: "qistPlan != ''");
      final out = <int, QistStatus>{};
      for (final r in rows) {
        final id = r['id'] as int;
        final plan = QistPlan.fromJson((r['qistPlan'] as String?) ?? '');
        if (plan == null) continue;
        out[id] = qistStatus(plan, await paidSince(id, plan.createdAt), nowMillis: nowMillis);
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// [plan] null => plan hatao. Sirf admin / manager.
  Future<void> savePlan(int customerId, QistPlan? plan) async {
    if (!Session.isAdminOrManager) throw StateError('Qist plan sirf admin / manager bana sakta hai');
    final c = await customer(customerId);
    if (c == null) throw StateError('Customer nahi mila');
    await PartyRepository.instance.updateCustomer(c.copyWith(qistPlan: plan?.toJson() ?? ''));
  }
}
