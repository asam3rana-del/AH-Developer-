import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/shell.dart';
import 'app_database.dart';

/// Ports ShellLedgerActivity.kt + ShellDao (Bottle Shell Ledger). All roles.
///
/// Every save is ONE transaction (customer row + history row + shop-stock
/// log + sync entries), so "owed" and "shop stock" can never disagree with
/// their history. The maths is in PURE functions — see test/shell_test.dart.

const shellIssue = 'ISSUE';
const shellReturn = 'RETURN';

const shopAdd = 'MANUAL_ADD';
const shopRemove = 'MANUAL_REMOVE';
const shopRefill = 'SENT_FOR_REFILL';
const shopCustomerReturn = 'CUSTOMER_RETURN';

/// (reason key, English, Urdu)
const shopReasonLabels = <(String, String, String)>[
  (shopAdd, 'Manual Add', 'دستی اضافہ'),
  (shopRemove, 'Manual Remove', 'دستی کمی'),
  (shopRefill, 'Sent for Refill', 'ری فل کے لیے بھیجی'),
  (shopCustomerReturn, 'Customer Return', 'کسٹمر کی واپسی'),
];

/// New owed count after an issue/return. A return can't exceed what is owed.
int applyIssueReturn({required int owed, required bool isIssue, required int qty}) {
  if (qty <= 0) throw ArgumentError('Enter a valid quantity');
  if (isIssue) return owed + qty;
  if (qty > owed) throw ArgumentError('Return is more than the $owed shells owed');
  return owed - qty;
}

/// Signed change to shop stock for a manual entry (add = +, remove/refill = -).
int shopStockDelta(String reason, int qty) => reason == shopAdd ? qty : -qty;

/// False when a removal would take shop stock below zero.
bool shopStockCanApply({required int current, required int delta}) => current + delta >= 0;

/// Case-insensitive, trimmed search on name or phone.
List<ShellCustomer> filterShellCustomers(List<ShellCustomer> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all.where((c) => c.name.toLowerCase().contains(q) || c.phone.toLowerCase().contains(q)).toList();
}

class ShellSummary {
  final int owedTotal;
  final int shopStock;
  final List<ShellCustomer> customers;
  const ShellSummary(this.owedTotal, this.shopStock, this.customers);
}

class ShellRepository {
  ShellRepository._();
  static final ShellRepository instance = ShellRepository._();

  static Future<void> _enqueue(Transaction txn, String type, String id, String op, Map<String, Object?> payload) =>
      txn.insert('sync_queue', {
        'entityType': type,
        'entityId': id,
        'operation': op,
        'payloadJson': jsonEncode(payload),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'retryCount': 0,
      });

  Future<ShellSummary> summary() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('shell_customers', orderBy: 'shellsOwed DESC, name COLLATE NOCASE ASC');
    final customers = rows.map(ShellCustomer.fromMap).toList();
    final owed = customers.fold<int>(0, (a, c) => a + c.shellsOwed);
    final r = await db.rawQuery('SELECT COALESCE(SUM(delta),0) AS t FROM shop_empty_shell_log');
    return ShellSummary(owed, (r.first['t'] as num).toInt(), customers);
  }

  Future<List<ShellTransaction>> history(int customerId, {int limit = 30}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('shell_transactions',
        where: 'customerId = ?', whereArgs: [customerId], orderBy: 'createdAt DESC, id DESC', limit: limit);
    return rows.map(ShellTransaction.fromMap).toList();
  }

  Future<List<ShopEmptyShellLog>> shopHistory({int limit = 50}) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('shop_empty_shell_log', orderBy: 'createdAt DESC, id DESC', limit: limit);
    return rows.map(ShopEmptyShellLog.fromMap).toList();
  }

  /// Issue or return shells for [name] (existing customer matched by name,
  /// case-insensitively — never a duplicate). A RETURN also adds the empties
  /// to the shop's own stock.
  Future<void> saveIssueReturn({
    required String name,
    String phone = '',
    required bool isIssue,
    required int qty,
    String note = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Enter a customer name');
    if (qty <= 0) throw ArgumentError('Enter a valid quantity');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final found = await txn.query('shell_customers', where: 'name = ? COLLATE NOCASE', whereArgs: [n], limit: 1);
      final int customerId;
      if (found.isEmpty) {
        final owed = applyIssueReturn(owed: 0, isIssue: isIssue, qty: qty);
        final c = ShellCustomer(name: n, phone: phone.trim(), shellsOwed: owed, createdAt: now, updatedAt: now);
        customerId = await txn.insert('shell_customers', c.toMap());
        await _enqueue(txn, 'shell_customer', '$customerId', 'create', {...c.toMap(), 'id': customerId});
      } else {
        final c = ShellCustomer.fromMap(found.first);
        customerId = c.id!;
        final owed = applyIssueReturn(owed: c.shellsOwed, isIssue: isIssue, qty: qty);
        final updated = ShellCustomer(
            id: c.id, name: c.name, phone: c.phone, shellsOwed: owed, createdAt: c.createdAt, serverId: c.serverId, updatedAt: now);
        await txn.update('shell_customers', updated.toMap(), where: 'id = ?', whereArgs: [customerId]);
        await _enqueue(txn, 'shell_customer', '$customerId', 'update', updated.toMap());
      }
      final t = ShellTransaction(
          customerId: customerId, type: isIssue ? shellIssue : shellReturn, qty: qty, note: note.trim(), createdAt: now, updatedAt: now);
      final tid = await txn.insert('shell_transactions', t.toMap());
      await _enqueue(txn, 'shell_transaction', '$tid', 'create', {...t.toMap(), 'id': tid});
      if (!isIssue) {
        final l = ShopEmptyShellLog(
            delta: qty, reason: shopCustomerReturn, note: note.trim().isNotEmpty ? '$n - ${note.trim()}' : n, createdAt: now, updatedAt: now);
        final lid = await txn.insert('shop_empty_shell_log', l.toMap());
        await _enqueue(txn, 'shop_empty_shell_log', '$lid', 'create', {...l.toMap(), 'id': lid});
      }
    });
  }

  /// Manual shop-stock entry. Removal is checked against the CURRENT total
  /// inside the same transaction, so two quick saves can't drive it negative.
  Future<void> saveShopStock({required String reason, required int qty, String note = ''}) async {
    if (qty <= 0) throw ArgumentError('Enter a valid quantity');
    if (reason != shopAdd && reason != shopRemove && reason != shopRefill) throw ArgumentError('Invalid reason');
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final r = await txn.rawQuery('SELECT COALESCE(SUM(delta),0) AS t FROM shop_empty_shell_log');
      final current = (r.first['t'] as num).toInt();
      final delta = shopStockDelta(reason, qty);
      if (!shopStockCanApply(current: current, delta: delta)) {
        throw StateError('Not enough shop stock to remove that much');
      }
      final l = ShopEmptyShellLog(delta: delta, reason: reason, note: note.trim(), createdAt: now, updatedAt: now);
      final lid = await txn.insert('shop_empty_shell_log', l.toMap());
      await _enqueue(txn, 'shop_empty_shell_log', '$lid', 'create', {...l.toMap(), 'id': lid});
    });
  }
}
