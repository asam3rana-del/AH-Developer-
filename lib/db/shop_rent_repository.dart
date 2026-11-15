import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor, Transaction;

import '../models/misc_entities.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import 'app_database.dart';
import 'expense_repository.dart';

/// Shop Rents: jo dukaneen hum kiraye par lete hain (har ek ka malik alag, mahana rent dena, kabhi advance).
///
/// Tareeqa:
///  * Har dukaan ka ek record + rent ki "terms" (kis mahine se kitna rent). Saal baad rent badle to naya term
///    lagta hai — purane mahine nahi badalte ([rentForMonth]).
///  * Har mahine ka rent ek "charge" (due) ban jata hai ([ensureCharges]); ek dukaan + ek mahina = ek hi charge.
///  * Rent dena ([pay]): sab se purane baqi mahine se bharta hai ([allocateFifo]); zyada de diya to baqi advance ban jata hai.
///  * Advance ([giveAdvance]): landlord ke paas hamara jama paisa — Cash OUT hai, Expense NAHI (profit nahi ghatta).
///  * Advance se rent katna ([applyAdvance]): us mahine ka Expense (Rent) ban jata hai; cash mein ek barabar IN aur
///    OUT likha jata hai taake Cash/Bank ka balance na badle (paisa pehle hi advance ke waqt nikal chuka tha).
///  * Sync: dukaan (terms samet) aur ledger sab devices par sync hote hain (`shop_rent` / `shop_rent_entry`);
///    Expense / Cash rows pehle se sync hoti hain aur ledger unse `expenseServerId` / `cashServerId` se judti hai.
///    Mahine ka charge har device par ek jaisi id (`shop_rent_charge:<dukaan>|<mahina>`) leta hai, is liye do device
///    ek hi mahine ka charge banayen to ek hi rehta hai.
///
/// Maths PURE functions mein hai (bina DB ke test: test/shop_rent_test.dart).

const shopRentCategory = 'Rent';
const _eps = 0.005;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

String _two(int v) => v.toString().padLeft(2, '0');

/// `2026-10` — mahine ki pehchan (string compare bhi sahi tarteeb deta hai).
String ymOf(DateTime d) => '${d.year}-${_two(d.month)}';

DateTime ymToDate(String ym) => DateTime(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)), 1);

String addMonths(String ym, int n) {
  final d = ymToDate(ym);
  return ymOf(DateTime(d.year, d.month + n, 1));
}

/// [a] se [b] tak mahine (a - b ka farq). a = b to 0.
int monthsBetween(String a, String b) {
  final x = ymToDate(a);
  final y = ymToDate(b);
  return (y.year - x.year) * 12 + (y.month - x.month);
}

/// [start] se [end] tak (dono shamil) sab mahine. start > end ho to khali.
List<String> monthsRange(String start, String end) {
  final out = <String>[];
  var cur = start;
  while (cur.compareTo(end) <= 0) {
    out.add(cur);
    cur = addMonths(cur, 1);
    if (out.length > 600) break; // hifazat: 50 saal se zyada nahi
  }
  return out;
}

/// [terms] = {fromYm: rent}. Is [ym] par jo term lagu hai (sab se naya jo ym se pehle ya barabar shuru hua).
/// Koi term itna purana na ho to sab se pehla term.
double rentForMonth(Map<String, double> terms, String ym) {
  if (terms.isEmpty) return 0;
  String? best;
  String? first;
  for (final k in terms.keys) {
    if (first == null || k.compareTo(first) < 0) first = k;
    if (k.compareTo(ym) <= 0 && (best == null || k.compareTo(best) > 0)) best = k;
  }
  return terms[best ?? first]!;
}

/// Mahine ki due tareekh. [dueDay] 31 ho aur mahina chhota ho to mahine ka aakhri din.
DateTime dueDateFor(String ym, int dueDay) {
  final m = ymToDate(ym);
  final last = DateTime(m.year, m.month + 1, 0).day;
  final day = dueDay < 1 ? 1 : (dueDay > last ? last : dueDay);
  return DateTime(m.year, m.month, day);
}

/// Aakhri term ko [months] ya zyada mahine ho gaye? (saal baad rent badalne ki yaad dahani)
bool needsRentReview(String lastTermYm, String nowYm, {int months = 12}) => monthsBetween(lastTermYm, nowYm) >= months;

/// `rent` mein `percent` % izafa, poore rupay mein (jaise 15000 + 10% = 16500).
double increaseByPercent(double rent, double percent) => (rent * (1 + percent / 100)).roundToDouble();

class MonthDue {
  final String ym;
  final double due;
  const MonthDue(this.ym, this.due);
}

class Allocation {
  final String ym;
  final double amount;
  const Allocation(this.ym, this.amount);
}

/// [amount] ko sab se purane baqi mahine se bharna shuru karo ([dues] purane se naye tarteeb mein).
/// `extra` = jo kisi mahine mein na laga (rent poora ho gaya, ya koi baqi nahi).
({List<Allocation> allocs, double extra}) allocateFifo(List<MonthDue> dues, double amount) {
  final out = <Allocation>[];
  var left = amount;
  for (final d in dues) {
    if (left <= _eps) break;
    if (d.due <= _eps) continue;
    final a = left < d.due ? left : d.due;
    out.add(Allocation(d.ym, a));
    left -= a;
  }
  return (allocs: out, extra: left > _eps ? left : 0.0);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class ShopRent {
  final int id;
  final String shopName;
  final String landlord;
  final String phone;
  final int dueDay;
  final String startYm;
  final bool autoApply; // naya rent ban-te hi advance se khud kate
  final bool active;
  final String note;
  final int createdAt;
  const ShopRent({
    required this.id,
    required this.shopName,
    required this.landlord,
    required this.phone,
    required this.dueDay,
    required this.startYm,
    required this.autoApply,
    required this.active,
    required this.note,
    required this.createdAt,
  });

  factory ShopRent.fromMap(Map<String, Object?> m) => ShopRent(
        id: (m['id'] as num).toInt(),
        shopName: (m['shopName'] as String?) ?? '',
        landlord: (m['landlord'] as String?) ?? '',
        phone: (m['phone'] as String?) ?? '',
        dueDay: (m['dueDay'] as num?)?.toInt() ?? 1,
        startYm: (m['startYm'] as String?) ?? ymOf(DateTime.now()),
        autoApply: ((m['autoApply'] as num?)?.toInt() ?? 1) != 0,
        active: ((m['active'] as num?)?.toInt() ?? 1) != 0,
        note: (m['note'] as String?) ?? '',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );

  String get displayName => landlord.trim().isEmpty ? shopName : '$shopName ($landlord)';
}

class RentLedgerEntry {
  final int id;
  final int shopId;
  final String kind; // charge | payment | advance | applied
  final String ym;
  final double amount;
  final String method;
  final String note;
  final int? expenseId;
  final int? cashId;
  final int createdAt;
  const RentLedgerEntry({
    required this.id,
    required this.shopId,
    required this.kind,
    required this.ym,
    required this.amount,
    required this.method,
    required this.note,
    required this.expenseId,
    required this.cashId,
    required this.createdAt,
  });

  factory RentLedgerEntry.fromMap(Map<String, Object?> m) => RentLedgerEntry(
        id: (m['id'] as num).toInt(),
        shopId: (m['shopId'] as num).toInt(),
        kind: (m['kind'] as String?) ?? '',
        ym: (m['ym'] as String?) ?? '',
        amount: (m['amount'] as num).toDouble(),
        method: (m['method'] as String?) ?? 'cash',
        note: (m['note'] as String?) ?? '',
        expenseId: (m['expenseId'] as num?)?.toInt(),
        cashId: (m['cashId'] as num?)?.toInt(),
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// Ek dukaan ka poora hisaab (ledger + terms se, [summarize] mein).
class ShopRentSummary {
  final ShopRent shop;
  final double currentRent; // is mahine ka rent (terms se)
  final String lastTermYm; // aakhri rent kis mahine se laga
  final double charged; // ab tak ka kul rent
  final double settled; // ab tak diya (payment + advance se kata)
  final double advanceBalance; // landlord ke paas hamara advance
  final List<MonthDue> dues; // baqi mahine, purane se naye
  final DateTime? nextDueDate; // sab se purane baqi mahine ki due tareekh
  final bool overdue;
  final bool reviewDue; // saal ho gaya — rent badalne ka waqt
  const ShopRentSummary({
    required this.shop,
    required this.currentRent,
    required this.lastTermYm,
    required this.charged,
    required this.settled,
    required this.advanceBalance,
    required this.dues,
    required this.nextDueDate,
    required this.overdue,
    required this.reviewDue,
  });

  double get outstanding => dues.fold<double>(0, (a, d) => a + d.due);
  bool get isClear => outstanding <= _eps;
}

/// PURE: ledger + terms se summary. [now] se overdue / review nikalte hain.
ShopRentSummary summarize(
  ShopRent shop,
  Map<String, double> terms,
  List<RentLedgerEntry> ledger,
  DateTime now,
) {
  final nowYm = ymOf(now);
  final charges = <String, double>{};
  final settledBy = <String, double>{};
  var advance = 0.0;
  var applied = 0.0;
  var settled = 0.0;
  for (final e in ledger) {
    switch (e.kind) {
      case 'charge':
        charges[e.ym] = (charges[e.ym] ?? 0) + e.amount;
      case 'payment':
        settledBy[e.ym] = (settledBy[e.ym] ?? 0) + e.amount;
        settled += e.amount;
      case 'applied':
        settledBy[e.ym] = (settledBy[e.ym] ?? 0) + e.amount;
        settled += e.amount;
        applied += e.amount;
      case 'advance':
        advance += e.amount;
    }
  }
  final months = charges.keys.toList()..sort();
  final dues = <MonthDue>[];
  var charged = 0.0;
  for (final m in months) {
    charged += charges[m]!;
    final d = charges[m]! - (settledBy[m] ?? 0);
    if (d > _eps) dues.add(MonthDue(m, d));
  }
  DateTime? next;
  var overdue = false;
  if (dues.isNotEmpty) {
    next = dueDateFor(dues.first.ym, shop.dueDay);
    final today = DateTime(now.year, now.month, now.day);
    overdue = next.isBefore(today);
  }
  var lastTerm = shop.startYm;
  for (final k in terms.keys) {
    if (k.compareTo(nowYm) <= 0 && k.compareTo(lastTerm) > 0) lastTerm = k;
  }
  final bal = advance - applied;
  return ShopRentSummary(
    shop: shop,
    currentRent: rentForMonth(terms, nowYm),
    lastTermYm: lastTerm,
    charged: charged,
    settled: settled,
    advanceBalance: bal < _eps ? 0.0 : bal,
    dues: dues,
    nextDueDate: next,
    overdue: overdue,
    reviewDue: needsRentReview(lastTerm, nowYm),
  );
}

class PayResult {
  final double toRent;
  final double toAdvance;
  const PayResult(this.toRent, this.toAdvance);
}

/// Mahine ki report ki ek line.
class MonthReportRow {
  final ShopRent shop;
  final double rent; // is mahine ka rent
  final double paid; // is mahine ke liye diya (cash/bank + advance se kata)
  const MonthReportRow(this.shop, this.rent, this.paid);
  double get due => rent - paid > _eps ? rent - paid : 0.0;
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

class ShopRentRepository {
  ShopRentRepository._();
  static final ShopRentRepository instance = ShopRentRepository._();

  void _requireStaff() {
    if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can manage shop rents');
  }

  static void _checkMethod(String method) {
    if (method != 'cash' && method != 'bank') throw ArgumentError('method must be cash or bank');
  }

  static void _checkAmount(double amount) {
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');
  }

  // ------------------------------------------------------------ reading

  Future<List<ShopRent>> listShops({bool includeInactive = true}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('shop_rents',
        where: includeInactive ? null : 'active = 1', orderBy: 'active DESC, shopName COLLATE NOCASE ASC');
    return rows.map(ShopRent.fromMap).toList();
  }

  Future<Map<String, double>> termsOf(int shopId, {DatabaseExecutor? ex}) async {
    final db = ex ?? await AppDatabase.instance.database;
    final rows = await db.query('shop_rent_terms', where: 'shopId = ?', whereArgs: [shopId]);
    return {for (final r in rows) r['fromYm'] as String: (r['monthlyRent'] as num).toDouble()};
  }

  /// Sirf wo entries jin ka Expense / Cash row ab bhi maujood hai (kisi ne Expense screen se hata di ho to
  /// us payment ko ginte nahi). Purane se naye.
  Future<List<RentLedgerEntry>> _ledger(DatabaseExecutor ex, int shopId) async {
    final rows = await ex.rawQuery(
      'SELECT l.* FROM shop_rent_ledger l '
      'LEFT JOIN expenses e ON e.id = l.expenseId '
      'LEFT JOIN cash_transactions c ON c.id = l.cashId '
      'WHERE l.shopId = ? AND ('
      "  l.kind = 'charge' "
      "  OR (l.kind IN ('payment','applied') AND e.id IS NOT NULL) "
      "  OR (l.kind = 'advance' AND (l.cashId IS NULL OR c.id IS NOT NULL))"
      ') ORDER BY l.createdAt ASC, l.id ASC',
      [shopId],
    );
    return rows.map(RentLedgerEntry.fromMap).toList();
  }

  Future<List<RentLedgerEntry>> history(int shopId) async {
    final db = await AppDatabase.instance.database;
    final l = await _ledger(db, shopId);
    return l.reversed.toList();
  }

  Future<ShopRentSummary?> summaryOf(int shopId, {DateTime? now}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('shop_rents', where: 'id = ?', whereArgs: [shopId], limit: 1);
    if (rows.isEmpty) return null;
    return summarize(ShopRent.fromMap(rows.first), await termsOf(shopId), await _ledger(db, shopId), now ?? DateTime.now());
  }

  Future<List<ShopRentSummary>> summaries({bool includeInactive = true, DateTime? now}) async {
    final n = now ?? DateTime.now();
    final db = await AppDatabase.instance.database;
    final out = <ShopRentSummary>[];
    for (final s in await listShops(includeInactive: includeInactive)) {
      out.add(summarize(s, await termsOf(s.id), await _ledger(db, s.id), n));
    }
    return out;
  }

  /// Is [ym] mahine ki report: har active dukaan ka rent / diya / baqi.
  Future<List<MonthReportRow>> monthReport(String ym) async {
    final db = await AppDatabase.instance.database;
    final out = <MonthReportRow>[];
    for (final s in await listShops(includeInactive: true)) {
      final ledger = await _ledger(db, s.id);
      var rent = 0.0, paid = 0.0;
      var any = false;
      for (final e in ledger) {
        if (e.ym != ym) continue;
        if (e.kind == 'charge') {
          rent += e.amount;
          any = true;
        } else if (e.kind == 'payment' || e.kind == 'applied') {
          paid += e.amount;
        }
      }
      if (any) out.add(MonthReportRow(s, rent, paid));
    }
    return out;
  }

  // ------------------------------------------------------------ shop set-up

  /// Nayi dukaan. [openingAdvance] = jo advance pehle se landlord ko de rakha hai (cash mein koi entry nahi banti —
  /// wo paisa pehle hi nikal chuka hai). [startMonth] se rent ban-na shuru hoga (aam taur par is mahine se).
  Future<int> addShop({
    required String shopName,
    String landlord = '',
    String phone = '',
    required double monthlyRent,
    int dueDay = 1,
    DateTime? startMonth,
    double openingAdvance = 0,
    bool autoApply = true,
    String note = '',
    DateTime? now,
  }) async {
    _requireStaff();
    if (shopName.trim().isEmpty) throw ArgumentError('Dukaan ka naam likhein');
    if (!monthlyRent.isFinite || monthlyRent <= 0) throw ArgumentError('Rent 0 se zyada hona chahiye');
    if (dueDay < 1 || dueDay > 31) throw ArgumentError('Tareekh 1 se 31 ke beech ho');
    if (!openingAdvance.isFinite || openingAdvance < 0) throw ArgumentError('Advance ghalat hai');
    final db = await AppDatabase.instance.database;
    final n = now ?? DateTime.now();
    final startYm = ymOf(startMonth ?? n);
    late int id;
    await db.transaction((txn) async {
      id = await txn.insert('shop_rents', {
        'shopName': shopName.trim(),
        'landlord': landlord.trim(),
        'phone': phone.trim(),
        'dueDay': dueDay,
        'startYm': startYm,
        'autoApply': autoApply ? 1 : 0,
        'active': 1,
        'note': note.trim(),
        'createdAt': n.millisecondsSinceEpoch,
        'updatedAt': n.millisecondsSinceEpoch,
      });
      await txn.insert('shop_rent_terms', {'shopId': id, 'fromYm': startYm, 'monthlyRent': monthlyRent});
      await SyncQueueHelper.enqueueShopRent(txn, id);
      if (openingAdvance > _eps) {
        final advId = await txn.insert('shop_rent_ledger', {
          'shopId': id,
          'kind': 'advance',
          'ym': '',
          'amount': openingAdvance,
          'method': 'cash',
          'note': 'Opening advance',
          'createdAt': n.millisecondsSinceEpoch,
          'updatedAt': n.millisecondsSinceEpoch,
        });
        await SyncQueueHelper.enqueueShopRentEntry(txn, advId);
      }
    });
    await ensureCharges(now: n);
    return id;
  }

  Future<void> updateShop(
    int id, {
    required String shopName,
    String landlord = '',
    String phone = '',
    required int dueDay,
    required bool autoApply,
    String note = '',
  }) async {
    _requireStaff();
    if (shopName.trim().isEmpty) throw ArgumentError('Dukaan ka naam likhein');
    if (dueDay < 1 || dueDay > 31) throw ArgumentError('Tareekh 1 se 31 ke beech ho');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.update(
        'shop_rents',
        {
          'shopName': shopName.trim(),
          'landlord': landlord.trim(),
          'phone': phone.trim(),
          'dueDay': dueDay,
          'autoApply': autoApply ? 1 : 0,
          'note': note.trim(),
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await SyncQueueHelper.enqueueShopRent(txn, id);
    });
  }

  /// Dukaan chhor di / dobara shuru: band dukaan ka naya rent nahi banta; purana hisaab rehta hai.
  Future<void> setActive(int id, bool active) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.update('shop_rents', {'active': active ? 1 : 0, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ?', whereArgs: [id]);
      await SyncQueueHelper.enqueueShopRent(txn, id);
    });
  }

  /// Dukaan hamesha ke liye hatao — sirf tab jab koi payment / advance nahi (sirf rent charges hon).
  Future<void> deleteShop(int id) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final used = await txn.rawQuery(
          "SELECT COUNT(*) AS n FROM shop_rent_ledger WHERE shopId = ? AND kind != 'charge'", [id]);
      if (((used.first['n'] as num?) ?? 0) > 0) {
        throw StateError('Is dukaan ka hisaab (payment/advance) maujood hai — hatane ke bajaye "Band karein" istemal karein');
      }
      // Entity ids row delete se PEHLE (doosre device ki asal serverId na khoye).
      final shopRow = await txn.query('shop_rents', where: 'id = ?', whereArgs: [id], limit: 1);
      final shopEid = shopRow.isEmpty ? null : SyncQueueHelper.shopRentEntityId(shopRow.first);
      final entryEids = <String>[];
      for (final l in await txn.query('shop_rent_ledger', columns: ['id'], where: 'shopId = ?', whereArgs: [id])) {
        final eid = await SyncQueueHelper.shopRentEntryEntityIdFor(txn, (l['id'] as num).toInt());
        if (eid != null) entryEids.add(eid);
      }
      await txn.delete('shop_rent_ledger', where: 'shopId = ?', whereArgs: [id]);
      await txn.delete('shop_rent_terms', where: 'shopId = ?', whereArgs: [id]);
      await txn.delete('shop_rents', where: 'id = ?', whereArgs: [id]);
      for (final eid in entryEids) {
        await SyncQueueHelper.enqueueDelete(txn, 'shop_rent_entry', eid);
      }
      if (shopEid != null) await SyncQueueHelper.enqueueDelete(txn, 'shop_rent', shopEid);
    });
  }

  /// Rent badlen: [fromYm] mahine se [newRent] lagu. Pehle ke mahine nahi badalte. Jo mahine [fromYm] ya baad ke hain
  /// aur jin mein abhi kuch ada nahi hua unka rent bhi naya ho jata hai (adhoore ada wale jaise hain waise).
  Future<void> changeRent(int shopId, {required String fromYm, required double newRent}) async {
    _requireStaff();
    if (!newRent.isFinite || newRent <= 0) throw ArgumentError('Rent 0 se zyada hona chahiye');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.insert('shop_rent_terms', {'shopId': shopId, 'fromYm': fromYm, 'monthlyRent': newRent},
          conflictAlgorithm: ConflictAlgorithm.replace);
      final terms = await termsOf(shopId, ex: txn);
      final charges = await txn.query('shop_rent_ledger',
          where: "shopId = ? AND kind = 'charge' AND ym >= ?", whereArgs: [shopId, fromYm]);
      for (final c in charges) {
        final ym = c['ym'] as String;
        final used = await txn.rawQuery(
            "SELECT COUNT(*) AS n FROM shop_rent_ledger WHERE shopId = ? AND ym = ? AND kind IN ('payment','applied')",
            [shopId, ym]);
        if (((used.first['n'] as num?) ?? 0) > 0) continue;
        await txn.update(
            'shop_rent_ledger', {'amount': rentForMonth(terms, ym), 'updatedAt': DateTime.now().millisecondsSinceEpoch},
            where: 'id = ?', whereArgs: [c['id']]);
        await SyncQueueHelper.enqueueShopRentEntry(txn, (c['id'] as num).toInt());
      }
      await txn.update('shop_rents', {'updatedAt': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [shopId]);
      await SyncQueueHelper.enqueueShopRent(txn, shopId);
    });
  }

  /// Is mahine ka rent maaf / chhutti (jaise dukaan band thi): charge 0 ho jata hai. Sirf jab kuch ada na hua ho.
  Future<void> waiveMonth(int shopId, String ym) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final used = await txn.rawQuery(
          "SELECT COUNT(*) AS n FROM shop_rent_ledger WHERE shopId = ? AND ym = ? AND kind IN ('payment','applied')",
          [shopId, ym]);
      if (((used.first['n'] as num?) ?? 0) > 0) {
        throw StateError('Is mahine mein payment ho chuki hai — pehle wo entry hatayen');
      }
      await txn.update('shop_rent_ledger', {'amount': 0.0, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
          where: "shopId = ? AND kind = 'charge' AND ym = ?", whereArgs: [shopId, ym]);
      for (final c in await txn.query('shop_rent_ledger',
          columns: ['id'], where: "shopId = ? AND kind = 'charge' AND ym = ?", whereArgs: [shopId, ym])) {
        await SyncQueueHelper.enqueueShopRentEntry(txn, (c['id'] as num).toInt());
      }
    });
  }

  // ------------------------------------------------------------ charges

  /// Har active dukaan ke liye [now] ke mahine tak ke wo charges bana do jo abhi bane nahi (roz pehli baar kholne par
  /// ya kai mahine app band rehne par bhi sab ban jate hain). Jin dukaanon mein "advance se khud kate" on hai,
  /// naya rent advance se kat jata hai. Kitne charges bane wo lautata hai.
  Future<int> ensureCharges({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final nowYm = ymOf(n);
    final db = await AppDatabase.instance.database;
    final shops = await db.query('shop_rents', where: 'active = 1');
    var created = 0;
    await db.transaction((txn) async {
      await _backfillSync(txn);
      await _cleanOrphans(txn);
      for (final row in shops) {
        final shop = ShopRent.fromMap(row);
        final terms = await termsOf(shop.id, ex: txn);
        if (terms.isEmpty) continue;
        final have = {
          for (final r in await txn.query('shop_rent_ledger',
              columns: ['ym'], where: "shopId = ? AND kind = 'charge'", whereArgs: [shop.id]))
            r['ym'] as String,
        };
        var made = 0;
        for (final ym in monthsRange(shop.startYm, nowYm)) {
          if (have.contains(ym)) continue;
          final rent = rentForMonth(terms, ym);
          if (rent <= 0) continue;
          final chargeId = await txn.insert('shop_rent_ledger', {
            'shopId': shop.id,
            'kind': 'charge',
            'ym': ym,
            'amount': rent,
            'method': 'cash',
            'note': '',
            'createdAt': dueDateFor(ym, 1).millisecondsSinceEpoch,
            'serverId': SyncQueueHelper.shopRentChargeEntityId(SyncQueueHelper.shopRentEntityId(row), ym),
            'updatedAt': n.millisecondsSinceEpoch,
          });
          await SyncQueueHelper.enqueueShopRentEntry(txn, chargeId);
          made++;
        }
        created += made;
        if (made > 0 && shop.autoApply) {
          await _applyAdvance(txn, shop, n.millisecondsSinceEpoch);
        }
      }
    });
    return created;
  }

  /// Jin ledger entries ka Expense / Cash row kisi aur screen se hat gaya ho unhein (aur advance-adjust ki cash IN row)
  /// saaf karo, taake hisaab aur cash mein farq na rahe.
  ///
  /// Doosre device se aayi entry jis ka Expense/Cash abhi pull nahi hua (`expenseId` khali magar `expenseServerId`
  /// maujood) orphan NAHI hai — wo pull par khud link ho jati hai ([applyShopRentEntries]).
  Future<void> _cleanOrphans(DatabaseExecutor ex) async {
    final rows = await ex.rawQuery(
      'SELECT l.* FROM shop_rent_ledger l '
      'LEFT JOIN expenses e ON e.id = l.expenseId '
      'LEFT JOIN cash_transactions c ON c.id = l.cashId '
      "WHERE (l.kind IN ('payment','applied') AND e.id IS NULL AND (l.expenseId IS NOT NULL OR l.expenseServerId IS NULL)) "
      "   OR (l.kind = 'advance' AND l.cashId IS NOT NULL AND c.id IS NULL)",
    );
    for (final r in rows) {
      final e = RentLedgerEntry.fromMap(r);
      if (e.kind == 'applied' && e.cashId != null) await _deleteCashById(ex, e.cashId!);
      final eid = await SyncQueueHelper.shopRentEntryEntityIdFor(ex, e.id);
      await ex.delete('shop_rent_ledger', where: 'id = ?', whereArgs: [e.id]);
      if (eid != null) await SyncQueueHelper.enqueueDelete(ex, 'shop_rent_entry', eid);
    }
  }

  static const _syncBackfillKey = 'shop_rent_sync_backfilled';

  /// Sync aane se pehle bani dukaneen/ledger (serverId nahi) EK baar queue mein daal do taake doosre devices
  /// par bhi pahunchen. Flag local-only app setting hai (synced keys mein nahi). Doosre device se aayi rows
  /// (serverId wali) dobara push nahi hoti.
  Future<void> _backfillSync(DatabaseExecutor ex) async {
    final done = await ex.query('app_settings', where: 'key = ?', whereArgs: [_syncBackfillKey], limit: 1);
    if (done.isNotEmpty) return;
    await SyncQueueHelper.enqueueAllShopRents(ex, onlyUnsynced: true);
    await ex.insert('app_settings', {'key': _syncBackfillKey, 'value': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ------------------------------------------------------------ money

  static String _desc(ShopRent shop, String ym, String note) {
    final base = '${shop.shopName}${shop.landlord.isEmpty ? '' : ' (${shop.landlord})'} - $ym';
    return note.trim().isEmpty ? base : '$base | ${note.trim()}';
  }

  Future<void> _insertCash(
    DatabaseExecutor txn, {
    required String type,
    required String method,
    required double amount,
    required String reason,
    required int now,
    required void Function(int id) onId,
  }) async {
    final cash = CashTransaction(type: type, method: method, amount: amount, reason: reason, createdAt: now, updatedAt: now);
    final cashId = await txn.insert('cash_transactions', cash.toMap());
    await SyncQueueHelper.enqueueLegacy(txn, 'cash_transaction', '$cashId', 'create', {...cash.toMap(), 'id': cashId});
    onId(cashId);
  }

  Future<void> _deleteCashById(DatabaseExecutor ex, int id) async {
    final rows = await ex.query('cash_transactions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final eid = await SyncQueueHelper.entityIdFor(ex, 'cash_transaction', '$id');
    await ex.delete('cash_transactions', where: 'id = ?', whereArgs: [id]);
    await SyncQueueHelper.enqueueDelete(ex, 'cash_transaction', eid);
  }

  Future<void> _insertAdvance(
    DatabaseExecutor txn,
    ShopRent shop, {
    required double amount,
    required String method,
    required String note,
    required int now,
  }) async {
    int? cashId;
    await _insertCash(
      txn,
      type: 'OUT',
      method: method,
      amount: amount,
      reason: 'Rent Advance: ${shop.shopName}${note.trim().isEmpty ? '' : ' | ${note.trim()}'}',
      now: now,
      onId: (id) => cashId = id,
    );
    final advId = await txn.insert('shop_rent_ledger', {
      'shopId': shop.id,
      'kind': 'advance',
      'ym': '',
      'amount': amount,
      'method': method,
      'note': note.trim(),
      'cashId': cashId,
      'createdAt': now,
      'updatedAt': now,
    });
    await SyncQueueHelper.enqueueShopRentEntry(txn, advId);
  }

  /// Rent do: sab se purane baqi mahine se bharta hai. Baqi rent se zyada diya to extra advance ban jata hai.
  Future<PayResult> pay(
    int shopId, {
    required double amount,
    required String method,
    String note = '',
    DateTime? now,
  }) async {
    _requireStaff();
    _checkMethod(method);
    _checkAmount(amount);
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;
    var toRent = 0.0, toAdvance = 0.0;
    await db.transaction((txn) async {
      final shop = await _shop(txn, shopId);
      final sum = summarize(shop, await termsOf(shopId, ex: txn), await _ledger(txn, shopId), DateTime.fromMillisecondsSinceEpoch(t));
      final plan = allocateFifo(sum.dues, amount);
      for (final a in plan.allocs) {
        final expenseId = await ExpenseRepository.insertExpenseWithCash(
          txn,
          category: shopRentCategory,
          description: _desc(shop, a.ym, note),
          amount: a.amount,
          method: method,
          now: t,
        );
        final payId = await txn.insert('shop_rent_ledger', {
          'shopId': shopId,
          'kind': 'payment',
          'ym': a.ym,
          'amount': a.amount,
          'method': method,
          'note': note.trim(),
          'expenseId': expenseId,
          'createdAt': t,
          'updatedAt': t,
        });
        await SyncQueueHelper.enqueueShopRentEntry(txn, payId);
        toRent += a.amount;
      }
      if (plan.extra > _eps) {
        await _insertAdvance(txn, shop, amount: plan.extra, method: method, note: note.trim().isEmpty ? 'Extra rent' : note, now: t);
        toAdvance = plan.extra;
      }
    });
    return PayResult(toRent, toAdvance);
  }

  /// Advance do (landlord ke paas hamara jama paisa) — Cash/Bank se OUT, lekin Expense nahi.
  Future<void> giveAdvance(int shopId, {required double amount, required String method, String note = '', DateTime? now}) async {
    _requireStaff();
    _checkMethod(method);
    _checkAmount(amount);
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final shop = await _shop(txn, shopId);
      await _insertAdvance(txn, shop, amount: amount, method: method, note: note, now: t);
    });
  }

  /// Baqi rent advance mein se kato (sab se purane mahine se). Kitna kata wo lautata hai.
  Future<double> applyAdvance(int shopId, {DateTime? now}) async {
    _requireStaff();
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;
    var applied = 0.0;
    await db.transaction((txn) async {
      applied = await _applyAdvance(txn, await _shop(txn, shopId), t);
    });
    return applied;
  }

  Future<double> _applyAdvance(Transaction txn, ShopRent shop, int t) async {
    final ledger = await _ledger(txn, shop.id);
    final sum = summarize(shop, await termsOf(shop.id, ex: txn), ledger, DateTime.fromMillisecondsSinceEpoch(t));
    if (sum.advanceBalance <= _eps || sum.dues.isEmpty) return 0.0;
    final plan = allocateFifo(sum.dues, sum.advanceBalance);
    var method = 'cash';
    for (final e in ledger) {
      if (e.kind == 'advance') method = e.method; // aakhri advance ka tareeqa
    }
    var total = 0.0;
    for (final a in plan.allocs) {
      // Cash mein barabar IN + OUT: balance wahi rehta hai (paisa advance dete waqt nikal chuka tha), magar rent
      // ka Expense (profit) is mahine mein ginta hai.
      int? inId;
      await _insertCash(
        txn,
        type: 'IN',
        method: method,
        amount: a.amount,
        reason: 'Rent adjusted from advance: ${shop.shopName} (${a.ym})',
        now: t,
        onId: (id) => inId = id,
      );
      final expenseId = await ExpenseRepository.insertExpenseWithCash(
        txn,
        category: shopRentCategory,
        description: '${_desc(shop, a.ym, '')} | from advance',
        amount: a.amount,
        method: method,
        now: t,
      );
      final appliedId = await txn.insert('shop_rent_ledger', {
        'shopId': shop.id,
        'kind': 'applied',
        'ym': a.ym,
        'amount': a.amount,
        'method': method,
        'note': 'Advance se kata',
        'expenseId': expenseId,
        'cashId': inId,
        'createdAt': t,
        'updatedAt': t,
      });
      await SyncQueueHelper.enqueueShopRentEntry(txn, appliedId);
      total += a.amount;
    }
    return total;
  }

  /// Galat likhi hui payment / advance / advance-adjust hatao (Expense + Cash bhi saath hat-ti hain).
  Future<void> deleteEntry(int ledgerId) async {
    _requireStaff();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query('shop_rent_ledger', where: 'id = ?', whereArgs: [ledgerId], limit: 1);
      if (rows.isEmpty) return;
      final e = RentLedgerEntry.fromMap(rows.first);
      // Entity id row delete se PEHLE.
      final entryEid = await SyncQueueHelper.shopRentEntryEntityIdFor(txn, ledgerId);
      switch (e.kind) {
        case 'payment':
        case 'applied':
          // Doosre device se aayi entry ka Expense abhi link na hua ho to serverId se dhoondo.
          final expSid = rows.first['expenseServerId'];
          final ex = e.expenseId != null
              ? await txn.query('expenses', where: 'id = ?', whereArgs: [e.expenseId], limit: 1)
              : (expSid is String && expSid.isNotEmpty
                  ? await txn.query('expenses', where: 'serverId = ?', whereArgs: [expSid], limit: 1)
                  : const <Map<String, Object?>>[]);
          if (ex.isNotEmpty) await ExpenseRepository.deleteInTxn(txn, Expense.fromMap(ex.first));
          if (e.kind == 'applied' && e.cashId != null) await _deleteCashById(txn, e.cashId!);
        case 'advance':
          final shop = await _shop(txn, e.shopId);
          final sum = summarize(shop, await termsOf(e.shopId, ex: txn), await _ledger(txn, e.shopId), DateTime.now());
          if (sum.advanceBalance + _eps < e.amount) {
            throw StateError('Is advance mein se rent kata ja chuka hai — pehle "Advance se kata" wali entry hatayen');
          }
          if (e.cashId != null) await _deleteCashById(txn, e.cashId!);
        default:
          throw StateError('Ye entry hatai nahi ja sakti (rent maaf karne ke liye "Rent maaf" istemal karein)');
      }
      await txn.delete('shop_rent_ledger', where: 'id = ?', whereArgs: [ledgerId]);
      if (entryEid != null) await SyncQueueHelper.enqueueDelete(txn, 'shop_rent_entry', entryEid);
    });
  }

  Future<ShopRent> _shop(DatabaseExecutor ex, int id) async {
    final rows = await ex.query('shop_rents', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw StateError('Dukaan nahi mili');
    return ShopRent.fromMap(rows.first);
  }
}
