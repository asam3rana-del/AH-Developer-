import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/misc_entities.dart';
import 'app_database.dart';
import 'day_book_repository.dart';

/// Ports CashRegisterActivity.kt (daily till open / edit opening / close /
/// reopen + history). The maths are PURE functions so the Kotlin rules can be
/// unit-tested (test/cash_register_test.dart) without a database.

/// `yyyy-MM-dd` (local) — the cash_register primary key. String order == date
/// order, which lastClosedBefore relies on.
String registerDateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Inverse of [registerDateKey]. Null when malformed (Kotlin falls back to today).
DateTime? parseRegisterDateKey(String key) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key);
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// Expected closing = opening + IN - OUT.
double registerExpected({required double opening, required double totalIn, required double totalOut}) =>
    opening + totalIn - totalOut;

/// Kotlin treats |diff| < 0.01 as an exact match.
bool registerIsMatch(double diff) => diff.abs() < 0.01;

/// A day's money movement, split by drawer.
class RegisterFlows {
  final double cashIn, cashOut, bankIn, bankOut;
  const RegisterFlows({this.cashIn = 0, this.cashOut = 0, this.bankIn = 0, this.bankOut = 0});
}

/// Expected / counted / difference for one register against its day's [flows].
class RegisterFigures {
  final double expectedCash, expectedBank;
  final double diffCash, diffBank;

  /// Sum of both drawers, exactly like Kotlin's history row
  /// (a cash shortage and an equal bank excess therefore show as "Matched").
  double get totalDiff => diffCash + diffBank;

  const RegisterFigures(this.expectedCash, this.expectedBank, this.diffCash, this.diffBank);
}

RegisterFigures registerFigures(CashRegister r, RegisterFlows f) {
  final ec = registerExpected(opening: r.openingCash, totalIn: f.cashIn, totalOut: f.cashOut);
  final eb = registerExpected(opening: r.openingBank, totalIn: f.bankIn, totalOut: f.bankOut);
  return RegisterFigures(ec, eb, r.closingCash - ec, r.closingBank - eb);
}

/// One row of REGISTER HISTORY. [figures] is null while the day is still open.
class RegisterHistoryRow {
  final CashRegister register;
  final RegisterFigures? figures;
  const RegisterHistoryRow(this.register, this.figures);
}

/// Result of the whole state of today's screen.
class TodayRegister {
  final String dateKey;
  final CashRegister? register; // null => NOT OPENED
  final RegisterFlows flows;

  /// Only when [register] is null: last CLOSED register's closing figures
  /// (carried forward even across skipped days — Kotlin audit fix).
  final double carryCash, carryBank;
  const TodayRegister(this.dateKey, this.register, this.flows, this.carryCash, this.carryBank);
}

class CashRegisterRepository {
  CashRegisterRepository._();
  static final CashRegisterRepository instance = CashRegisterRepository._();

  static Future<void> _enqueue(Transaction txn, String op, CashRegister r) => txn.insert('sync_queue', {
        'entityType': 'cash_register',
        'entityId': r.date, // Kotlin cashRegisterEntityId = date
        'operation': op,
        'payloadJson': jsonEncode({...r.toMap(), 'closed': r.closed}),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'retryCount': 0,
      });

  Future<RegisterFlows> flowsForDate(DateTime day) async {
    final db = await AppDatabase.instance.database;
    final (start, end) = DayBookRepository.dayBounds(day);
    final rows = await db.rawQuery(
      'SELECT type, method, COALESCE(SUM(amount), 0) AS total FROM cash_transactions '
      'WHERE createdAt >= ? AND createdAt < ? GROUP BY type, method',
      [start, end],
    );
    double cashIn = 0, cashOut = 0, bankIn = 0, bankOut = 0;
    for (final r in rows) {
      final v = (r['total'] as num).toDouble();
      final t = r['type'], m = r['method'];
      if (m == 'cash' && t == 'IN') cashIn = v;
      if (m == 'cash' && t == 'OUT') cashOut = v;
      if (m == 'bank' && t == 'IN') bankIn = v;
      if (m == 'bank' && t == 'OUT') bankOut = v;
    }
    return RegisterFlows(cashIn: cashIn, cashOut: cashOut, bankIn: bankIn, bankOut: bankOut);
  }

  Future<CashRegister?> find(String dateKey) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('cash_register', where: 'date = ?', whereArgs: [dateKey], limit: 1);
    return rows.isEmpty ? null : CashRegister.fromMap(rows.first);
  }

  Future<CashRegister?> lastClosedBefore(String dateKey) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('cash_register',
        where: 'date < ? AND closed = 1', whereArgs: [dateKey], orderBy: 'date DESC', limit: 1);
    return rows.isEmpty ? null : CashRegister.fromMap(rows.first);
  }

  /// Everything the screen needs for [day] (default today) in one call.
  Future<TodayRegister> loadToday({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final key = registerDateKey(n);
    final reg = await find(key);
    final flows = await flowsForDate(n);
    if (reg != null) return TodayRegister(key, reg, flows, 0, 0);
    final last = await lastClosedBefore(key);
    return TodayRegister(key, null, flows, last?.closingCash ?? 0, last?.closingBank ?? 0);
  }

  /// Newest first, latest [limit] (Kotlin shows 20). Closed rows carry their
  /// figures for that day; open rows show "In Progress".
  Future<List<RegisterHistoryRow>> history({int limit = 20}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('cash_register', orderBy: 'date DESC', limit: limit);
    final out = <RegisterHistoryRow>[];
    for (final m in rows) {
      final r = CashRegister.fromMap(m);
      if (!r.closed) {
        out.add(RegisterHistoryRow(r, null));
        continue;
      }
      final day = parseRegisterDateKey(r.date) ?? DateTime.now();
      out.add(RegisterHistoryRow(r, registerFigures(r, await flowsForDate(day))));
    }
    return out;
  }

  /// OPEN REGISTER. The exists-check and the insert run in ONE transaction, so
  /// a double-tap cannot overwrite today's row (Kotlin insertIfAbsent).
  /// Returns false when today's register already exists.
  /// Queued as `create_if_absent` so a second device's OPEN is dropped
  /// server-side instead of clobbering the first one's opening balance.
  Future<bool> open({required String dateKey, required double openingCash, required double openingBank}) async {
    _checkMoney(openingCash);
    _checkMoney(openingBank);
    final db = await AppDatabase.instance.database;
    return db.transaction((txn) async {
      final exists = await txn.query('cash_register', columns: ['date'], where: 'date = ?', whereArgs: [dateKey], limit: 1);
      if (exists.isNotEmpty) return false;
      final reg = CashRegister(date: dateKey, openingCash: openingCash, openingBank: openingBank);
      await txn.insert('cash_register', reg.toMap());
      await _enqueue(txn, 'create_if_absent', reg);
      return true;
    });
  }

  /// Edit the opening balance of an OPEN register.
  Future<CashRegister> editOpening(String dateKey, {required double openingCash, required double openingBank}) async {
    _checkMoney(openingCash);
    _checkMoney(openingBank);
    return _update(dateKey, (r) {
      if (r.closed) throw StateError('Register is closed');
      return _copy(r, openingCash: openingCash, openingBank: openingBank);
    });
  }

  /// CLOSE against the physically counted amounts.
  Future<CashRegister> close(String dateKey, {required double countedCash, required double countedBank}) async {
    _checkMoney(countedCash);
    _checkMoney(countedBank);
    return _update(dateKey, (r) {
      if (r.closed) throw StateError('Register is already closed');
      return _copy(r, closingCash: countedCash, closingBank: countedBank, closed: true);
    });
  }

  Future<CashRegister> reopen(String dateKey) => _update(dateKey, (r) => _copy(r, closed: false));

  /// Expected closing recomputed from cash_transactions RIGHT NOW (Kotlin
  /// freshExpected) — the confirm dialog must not trust a stale render.
  Future<(double cash, double bank)> freshExpected(CashRegister r) async {
    final day = parseRegisterDateKey(r.date) ?? DateTime.now();
    final f = await flowsForDate(day);
    return (
      registerExpected(opening: r.openingCash, totalIn: f.cashIn, totalOut: f.cashOut),
      registerExpected(opening: r.openingBank, totalIn: f.bankIn, totalOut: f.bankOut),
    );
  }

  /// Read-modify-write + sync entry in ONE transaction.
  Future<CashRegister> _update(String dateKey, CashRegister Function(CashRegister) change) async {
    final db = await AppDatabase.instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query('cash_register', where: 'date = ?', whereArgs: [dateKey], limit: 1);
      if (rows.isEmpty) throw StateError('Register not found for $dateKey');
      final updated = change(CashRegister.fromMap(rows.first));
      await txn.update('cash_register', updated.toMap(), where: 'date = ?', whereArgs: [dateKey]);
      await _enqueue(txn, 'upsert', updated);
      return updated;
    });
  }

  static CashRegister _copy(CashRegister r,
          {double? openingCash, double? openingBank, double? closingCash, double? closingBank, bool? closed}) =>
      CashRegister(
        date: r.date,
        openingCash: openingCash ?? r.openingCash,
        openingBank: openingBank ?? r.openingBank,
        closingCash: closingCash ?? r.closingCash,
        closingBank: closingBank ?? r.closingBank,
        closed: closed ?? r.closed,
      );

  static void _checkMoney(double v) {
    if (!v.isFinite) throw ArgumentError('Amount must be a valid number');
  }
}
