import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor;

import '../models/due_followup.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';
import 'due_reminders_repository.dart';

/// Due Reminders follow-up log ka data (table: due_followups). UI: lib/screens/due_reminders_screen.dart.
///
/// Sab devices par sync hota hai (`serverId` + `partyServerId` + `updatedAt`, collection `due_followups`);
/// backup mein DB ke saath shamil hai. Har likhna (add / setResult / delete) usi transaction mein sync queue
/// mein bhi jata hai (`SyncQueueHelper.enqueueDueFollowup`).
/// Maths [buildCollectionFocus] / [followUpState] jaise PURE functions mein hai — test/due_followup_test.dart.
class DueFollowUpRepository {
  DueFollowUpRepository._();
  static final DueFollowUpRepository instance = DueFollowUpRepository._();

  static String _staff() => Session.username ?? '';

  /// Nayi entry. `createdAt` na do to abhi ka waqt. Naye row ki id lautati hai.
  Future<int> add({
    required int partyId,
    required String partyName,
    required String method,
    String outcome = FollowUpOutcome.note,
    double amount = 0,
    int promiseDate = 0,
    int nextFollowUp = 0,
    String note = '',
    int? createdAt,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final id = await txn.insert('due_followups', {
        'partyId': partyId,
        'partyName': partyName,
        'method': method,
        'outcome': outcome,
        'amount': amount,
        'promiseDate': promiseDate <= 0 ? 0 : startOfDayMillis(promiseDate),
        'nextFollowUp': nextFollowUp <= 0 ? 0 : startOfDayMillis(nextFollowUp),
        'note': note.trim(),
        'staff': _staff(),
        'createdAt': createdAt ?? now,
        'updatedAt': now,
      });
      await SyncQueueHelper.enqueueDueFollowup(txn, id);
      return id;
    });
  }

  /// Maujooda entry ka nateeja / wada / agla follow-up / note badalna (jaise "sent" ko asal nateeja dena).
  Future<bool> setResult({
    required int id,
    required String outcome,
    double amount = 0,
    int promiseDate = 0,
    int nextFollowUp = 0,
    String note = '',
  }) async {
    final db = await AppDatabase.instance.database;
    return db.transaction((txn) async {
      final n = await txn.update(
        'due_followups',
        {
          'outcome': outcome,
          'amount': amount,
          'promiseDate': promiseDate <= 0 ? 0 : startOfDayMillis(promiseDate),
          'nextFollowUp': nextFollowUp <= 0 ? 0 : startOfDayMillis(nextFollowUp),
          'note': note.trim(),
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      if (n > 0) await SyncQueueHelper.enqueueDueFollowup(txn, id);
      return n > 0;
    });
  }

  Future<bool> delete(int id) async {
    final db = await AppDatabase.instance.database;
    return db.transaction((txn) async {
      // Entity id row delete se PEHLE (doosre device se aayi entry ki asal serverId na khoye).
      final eid = await SyncQueueHelper.dueFollowupEntityIdFor(txn, id);
      final n = await txn.delete('due_followups', where: 'id = ?', whereArgs: [id]);
      if (n > 0 && eid != null) await SyncQueueHelper.enqueueDelete(txn, 'due_followup', eid);
      return n > 0;
    });
  }

  static const _syncBackfillKey = 'due_followup_sync_backfilled';

  /// Sync aane se pehle (v35) bani follow-ups (serverId nahi) EK baar queue mein daal do taake doosre devices par
  /// bhi pahunchen. Flag local-only app setting hai (synced keys mein nahi). Doosre device se aayi rows (serverId
  /// wali) dobara push nahi hoti. Sirf screen (foreground) se: DeviceTag / branch background isolate mein set nahi.
  Future<void> _backfillSync(DatabaseExecutor ex) async {
    final done = await ex.query('app_settings', where: 'key = ?', whereArgs: [_syncBackfillKey], limit: 1);
    if (done.isNotEmpty) return;
    await SyncQueueHelper.enqueueAllDueFollowups(ex, onlyUnsynced: true);
    await ex.insert('app_settings', {'key': _syncBackfillKey, 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Ek party ki saari entries, nayi pehle.
  Future<List<DueFollowUp>> forParty(int partyId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('due_followups',
        where: 'partyId = ?', whereArgs: [partyId], orderBy: 'createdAt DESC, id DESC');
    return [for (final r in rows) DueFollowUp.fromMap(r)];
  }

  Future<DueFollowUp?> byId(int id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('due_followups', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : DueFollowUp.fromMap(rows.first);
  }

  /// Sab parties ki entries party id ke hisaab se (har list nayi pehle). Screen / dashboard / notification isi se
  /// har party ki halat nikalte hain.
  ///
  /// [backfillSync] sirf screen (foreground) se true: purani (v35) entries ko ek baar sync queue mein daalna.
  Future<Map<int, List<DueFollowUp>>> allByParty({bool backfillSync = false}) async {
    final db = await AppDatabase.instance.database;
    if (backfillSync) await _backfillSync(db);
    final rows = await db.query('due_followups', orderBy: 'createdAt DESC, id DESC');
    final out = <int, List<DueFollowUp>>{};
    for (final r in rows) {
      final f = DueFollowUp.fromMap(r);
      (out[f.partyId] ??= []).add(f);
    }
    return out;
  }

  /// Aaj ki wasooli ka khulasa (dashboard card + notification). Sirf Sales (customers) ke baqi bills.
  Future<CollectionFocus> todaysFocus({int? nowMillis, int topN = 3}) async {
    final bills = await DueRemindersRepository.instance.dueSales();
    final followUps = await allByParty();
    return buildCollectionFocus(groupDueByParty(bills), followUps, nowMillis: nowMillis, topN: topN);
  }

  /// Mahine ka khulasa ([year]/[month]) — kitni baat hui, kitne wade, kitni raqam record hui.
  Future<FollowUpMonthStats> monthStats(int year, int month) async {
    final db = await AppDatabase.instance.database;
    final from = DateTime(year, month, 1).millisecondsSinceEpoch;
    final to = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    final rows = await db.query('due_followups',
        where: 'createdAt >= ? AND createdAt < ?', whereArgs: [from, to]);
    return followUpMonthStats([for (final r in rows) DueFollowUp.fromMap(r)]);
  }
}

/// Ek party ka dashboard / notification wala jaiza.
class PartyFocus {
  final DueParty party;
  final FollowUpState state;

  /// Sab se purane overdue bill ke din (0 = overdue nahi / tareekh nahi).
  final int oldestOverdueDays;
  const PartyFocus({required this.party, required this.state, required this.oldestOverdueDays});

  double get total => party.total;
}

/// "Aaj ki Wasooli" ka khulasa.
class CollectionFocus {
  /// Aaj jin parties par kaam karna hai (toota wada / follow-up ka din / wada aaj ka) aur un ka jod.
  final int actionCount;
  final double actionAmount;

  /// Overdue parties (kisi bill ki tareekh guzri) — "wada pe" wali shamil nahi — aur un ka jod.
  final int overdueCount;
  final double overdueAmount;

  /// Toote hue wade.
  final int brokenCount;

  /// Sab baqi (advance ke ilawa, kisi party wali sales) ka jod aur parties.
  final int totalParties;
  final double totalDue;

  /// Sab se zaroori pehli [topN] parties (toota wada > aaj karna hai > baqi overdue, phir bari raqam).
  final List<PartyFocus> top;

  const CollectionFocus({
    required this.actionCount,
    required this.actionAmount,
    required this.overdueCount,
    required this.overdueAmount,
    required this.brokenCount,
    required this.totalParties,
    required this.totalDue,
    required this.top,
  });

  static const empty = CollectionFocus(
    actionCount: 0,
    actionAmount: 0,
    overdueCount: 0,
    overdueAmount: 0,
    brokenCount: 0,
    totalParties: 0,
    totalDue: 0,
    top: [],
  );

  bool get isEmpty => totalParties == 0;
}

int _oldestOverdueDays(DueParty p, int today) {
  if (!p.hasOverdue(nowMillis: today)) return 0;
  final e = p.earliestDue;
  if (e <= 0) return 0;
  final d = (today - startOfDayMillis(e)) / 86400000;
  return d < 0 ? 0 : d.round();
}

/// Parties + follow-up entries => aaj ka khulasa. PURE (test ke liye).
CollectionFocus buildCollectionFocus(
  Iterable<DueParty> parties,
  Map<int, List<DueFollowUp>> followUps, {
  int? nowMillis,
  int topN = 3,
}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final today = startOfDayMillis(now);
  var actionCount = 0, overdueCount = 0, brokenCount = 0, totalParties = 0;
  var actionAmount = 0.0, overdueAmount = 0.0, totalDue = 0.0;
  final cand = <PartyFocus>[];
  for (final p in parties) {
    if (p.isAdvance || p.total <= 0.009) continue;
    totalParties++;
    totalDue += p.total;
    final id = p.partyId;
    final st = followUpState(id == null ? const <DueFollowUp>[] : (followUps[id] ?? const <DueFollowUp>[]), nowMillis: now);
    final overdue = p.hasOverdue(nowMillis: now);
    if (st.promiseBroken) brokenCount++;
    if (st.needsActionToday) {
      actionCount++;
      actionAmount += p.total;
    }
    final countsOverdue = overdue && !st.onPromise;
    if (countsOverdue) {
      overdueCount++;
      overdueAmount += p.total;
    }
    if (st.needsActionToday || countsOverdue) {
      cand.add(PartyFocus(party: p, state: st, oldestOverdueDays: _oldestOverdueDays(p, today)));
    }
  }
  cand.sort((a, b) {
    final r = followUpRank(a.state).compareTo(followUpRank(b.state));
    if (r != 0) return r;
    final t = b.total.compareTo(a.total);
    return t != 0 ? t : a.party.partyName.toLowerCase().compareTo(b.party.partyName.toLowerCase());
  });
  return CollectionFocus(
    actionCount: actionCount,
    actionAmount: actionAmount,
    overdueCount: overdueCount,
    overdueAmount: overdueAmount,
    brokenCount: brokenCount,
    totalParties: totalParties,
    totalDue: totalDue,
    top: cand.take(topN).toList(),
  );
}

/// Mahine ka follow-up khulasa.
class FollowUpMonthStats {
  /// Kul entries (sent samet).
  final int total;
  final int whatsapp;
  final int calls;
  final int promises;
  final int paidOrPartial;

  /// Paid / partial entries mein likhi hui raqam ka jod.
  final double recorded;
  const FollowUpMonthStats({
    required this.total,
    required this.whatsapp,
    required this.calls,
    required this.promises,
    required this.paidOrPartial,
    required this.recorded,
  });
}

FollowUpMonthStats followUpMonthStats(Iterable<DueFollowUp> entries) {
  var total = 0, wa = 0, calls = 0, promises = 0, paid = 0;
  var recorded = 0.0;
  for (final e in entries) {
    total++;
    if (e.method == FollowUpMethod.whatsapp) wa++;
    if (e.method == FollowUpMethod.call) calls++;
    if (e.outcome == FollowUpOutcome.promised || (e.outcome == FollowUpOutcome.partial && e.promiseDate > 0)) promises++;
    if (e.outcome == FollowUpOutcome.paid || e.outcome == FollowUpOutcome.partial) {
      paid++;
      recorded += e.amount;
    }
  }
  return FollowUpMonthStats(
    total: total,
    whatsapp: wa,
    calls: calls,
    promises: promises,
    paidOrPartial: paid,
    recorded: recorded,
  );
}

/// Party ke WhatsApp reminder ka link. Pehli baar (aur wada na toota ho) wahi purana naram message; baad mein
/// ya wada toota ho to shiddat badhti hai ([reminderLevel] / [followUpMessage]). [g] ek hi bill wali ho to
/// level 0 par us bill ka message, warna poore total ka.
Uri reminderUriFor(DueParty g, List<DueFollowUp> entries, {int? nowMillis}) {
  final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
  final single = g.bills.length == 1 && !g.bills.first.isBalance ? g.bills.first : null;
  final level = reminderLevel(entries, nowMillis: now);
  final st = followUpState(entries, nowMillis: now);
  if (level == 0 && !st.promiseBroken) return single != null ? whatsAppUri(single) : whatsAppUri(g.toTotalBill());
  final today = startOfDayMillis(now);
  var oldest = 0;
  if (g.hasOverdue(nowMillis: now) && g.earliestDue > 0) {
    oldest = ((today - startOfDayMillis(g.earliestDue)) / 86400000).round();
    if (oldest < 0) oldest = 0;
  }
  final msg = followUpMessage(
    level: level,
    name: g.partyName,
    rs: g.total.toStringAsFixed(0),
    oldestDays: oldest,
    brokenPromiseDate: st.promiseBroken ? DateTime.fromMillisecondsSinceEpoch(st.promise!.promiseDate) : null,
    brokenPromiseAmount: st.promiseBroken ? st.promise!.amount : 0,
  );
  return Uri.parse('https://wa.me/${whatsAppDigits(g.partyPhone)}?text=${Uri.encodeComponent(msg)}');
}
