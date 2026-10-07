import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'period_close_repository.dart';
import 'customer_repository.dart';
import 'supplier_repository.dart';
import '../sync/device_tag.dart';
import '../sync/sync_queue_helper.dart';

/// A bill a payment can be linked to (Kotlin `BillOption`).
class BillOption {
  final String label;
  final String ref;
  const BillOption(this.label, this.ref);
}

/// One row of the payments report (Kotlin `ReportRow`).
class PaymentRow {
  final Payment payment;
  final String partyName;
  final int? partyId;
  final bool isCustomer;
  const PaymentRow(this.payment, this.partyName, this.partyId, this.isCustomer);
}

/// Ports the payment logic of PartyTransactionActivity.kt
/// (savePayment / updatePayment / deletePayment / applyBillPaidDelta) and the
/// query of PaymentsReportActivity.kt. Every write that touches balance +
/// cash + bill runs in ONE transaction.
class PaymentRepository {
  PaymentRepository._();
  static final PaymentRepository instance = PaymentRepository._();

  static String _reason(bool isCustomer, String partyName, String note) =>
      (isCustomer ? 'Payment received from $partyName' : 'Payment made to $partyName') +
      (note.isNotEmpty ? ' | $note' : '');

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  Future<void> _enqueue(DatabaseExecutor txn, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(txn, type, id, op, payload);

  Future<void> _adjustBalance(DatabaseExecutor txn, bool isCustomer, int partyId, double delta) async {
    await txn.rawUpdate(
      'UPDATE ${isCustomer ? 'customers' : 'suppliers'} SET balance = balance + ?, dirty = 1 WHERE id = ?',
      [delta, partyId],
    );
    await SyncQueueHelper.enqueueBalanceDelta(txn, customer: isCustomer, partyId: partyId, delta: delta);
  }

  /// Applies [delta] to the linked bill's `paid`, clamped to [0, total].
  Future<void> _applyBillPaidDelta(DatabaseExecutor txn, bool isCustomer, String billRef, double delta) async {
    if (billRef.isEmpty || delta == 0) return;
    final table = isCustomer ? 'sales' : 'purchases';
    final key = isCustomer ? 'invoice' : 'billNo';
    final rows = await txn.query(table, where: '$key = ?', whereArgs: [billRef], limit: 1);
    if (rows.isEmpty) return;
    final total = (rows.first['total'] as num).toDouble();
    final paid = (rows.first['paid'] as num).toDouble();
    final newPaid = (paid + delta).clamp(0.0, total).toDouble();
    await txn.update(
      table,
      {'paid': newPaid, 'dirty': 1, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: '$key = ?',
      whereArgs: [billRef],
    );
    await _enqueue(txn, isCustomer ? 'sale' : 'purchase', billRef, 'update', {'paid': newPaid});
  }

  /// Bill ka baaqi (total - paid); bill na mile to null.
  Future<double?> _billRemaining(DatabaseExecutor txn, bool isCustomer, String billRef) async {
    if (billRef.isEmpty) return null;
    final rows = await txn.query(isCustomer ? 'sales' : 'purchases',
        columns: ['total', 'paid'], where: '${isCustomer ? 'invoice' : 'billNo'} = ?', whereArgs: [billRef], limit: 1);
    if (rows.isEmpty) return null;
    final left = (rows.first['total'] as num).toDouble() - (rows.first['paid'] as num).toDouble();
    return left < 0 ? 0.0 : left;
  }

  /// Recent (unreturned) bills of one party, newest first, max 50.
  ///
  /// [alsoInclude]: edit karte waqt payment ka maujooda bill (agar wo naye 50 mein na aaye, ya returned ho)
  /// bhi list mein aaye — warna dropdown use khali kar deta hai aur save par bill ka `paid` ghalat ghat jata hai.
  Future<List<BillOption>> billOptions({
    required bool isCustomer,
    required int partyId,
    String alsoInclude = '',
  }) async {
    final db = await AppDatabase.instance.database;
    final rows = isCustomer
        ? await db.query('sales',
            where: "customerId = ? AND status != 'returned'", whereArgs: [partyId], orderBy: 'createdAt DESC', limit: 50)
        : await db.query('purchases',
            where: "supplierId = ? AND status != 'returned'", whereArgs: [partyId], orderBy: 'createdAt DESC', limit: 50);
    final key = isCustomer ? 'invoice' : 'billNo';
    final out = rows.map((r) {
      final ref = (r[key] as String);
      return BillOption('$ref \u2022 Rs ${(r['total'] as num).toStringAsFixed(2)}', ref);
    }).toList();
    if (alsoInclude.isNotEmpty && !out.any((b) => b.ref == alsoInclude)) {
      final extra = await db.query(isCustomer ? 'sales' : 'purchases',
          where: '$key = ?', whereArgs: [alsoInclude], limit: 1);
      if (extra.isNotEmpty) {
        out.add(BillOption('$alsoInclude \u2022 Rs ${(extra.first['total'] as num).toStringAsFixed(2)}', alsoInclude));
      }
    }
    return out;
  }

  /// Mirrors savePayment(): payment row + party balance + cash entry + bill.
  Future<void> save({
    required bool isCustomer,
    required int partyId,
    required String partyName,
    required double amount,
    required String method,
    required String note,
    required int dateMillis,
    String billRef = '',
  }) async {
    // Repository par bhi guard (Cash/Expense jaisa): NaN / Infinity / <= 0 se party balance kharab na ho.
    if (!amount.isFinite || amount <= 0) throw ArgumentError('Amount must be greater than 0');
    final db = await AppDatabase.instance.database;
    final partyType = isCustomer ? 'customer' : 'supplier';
    // Device-unique (Expense jaisa): do devices par ek hi ms mein ek hi party ka payment ho to reference na takraye.
    final reference = 'manual-$partyType-$partyId-${DeviceTag.current}-${DateTime.now().millisecondsSinceEpoch}';
    await db.transaction((txn) async {
      // Bill ke baaqi se zyada payment: bill ka `paid` total par ruk jata hai, is liye poori raqam
      // bill se jorne par party balance aur bill alag ho jate (advance chupke se gayab). Isliye
      // bill ke baaqi jitna hissa bill se juray, extra hissa alag (general) payment banay.
      final remaining = await _billRemaining(txn, isCustomer, billRef);
      var linked = amount;
      var extra = 0.0;
      var linkRef = billRef;
      if (remaining != null && amount > remaining + 0.009) {
        linked = remaining;
        extra = amount - remaining;
        if (linked <= 0.009) {
          linked = 0.0;
          linkRef = '';
        }
      }
      if (linked > 0.009 || extra <= 0.009) {
        await _insertPayment(txn,
            isCustomer: isCustomer,
            partyType: partyType,
            partyId: partyId,
            partyName: partyName,
            amount: linked > 0.009 ? linked : amount,
            method: method,
            note: note,
            billRef: linkRef,
            dateMillis: dateMillis,
            reference: reference);
      }
      if (extra > 0.009) {
        await _insertPayment(txn,
            isCustomer: isCustomer,
            partyType: partyType,
            partyId: partyId,
            partyName: partyName,
            amount: extra,
            method: method,
            note: linked > 0.009 ? (note.isEmpty ? 'Extra (bill se zyada)' : '$note | Extra (bill se zyada)') : note,
            billRef: '',
            dateMillis: dateMillis,
            reference: linked > 0.009 ? '$reference-x' : reference);
      }
    });
    await _refreshParties();
  }

  /// Ek payment row + party balance + cash row + (agar linked) bill ka `paid`.
  Future<void> _insertPayment(
    DatabaseExecutor txn, {
    required bool isCustomer,
    required String partyType,
    required int partyId,
    required String partyName,
    required double amount,
    required String method,
    required String note,
    required String billRef,
    required int dateMillis,
    required String reference,
  }) async {
    final payment = Payment(
      reference: reference,
      partyType: partyType,
      partyId: partyId,
      amount: amount,
      method: method,
      note: note,
      billReference: billRef,
      createdAt: dateMillis,
    );
    final id = await txn.insert('payments', payment.toMap());
    await _enqueue(txn, 'payment', id.toString(), 'create', payment.toMap());

    // Customer pays us -> they owe less; we pay supplier -> we owe less.
    await _adjustBalance(txn, isCustomer, partyId, -amount);

    final cash = CashTransaction(
      type: isCustomer ? 'IN' : 'OUT',
      method: method.toLowerCase(),
      amount: amount,
      reason: _reason(isCustomer, partyName, note),
      reference: reference,
      createdAt: dateMillis,
    );
    final cashId = await txn.insert('cash_transactions', cash.toMap());
    await _enqueue(txn, 'cash_transaction', cashId.toString(), 'create', cash.toMap());

    await _applyBillPaidDelta(txn, isCustomer, billRef, amount);
  }

  /// Mirrors updatePayment() — balance moves only by the change in amount.
  Future<void> update({
    required Payment original,
    required bool isCustomer,
    required String partyName,
    required double newAmount,
    required String newMethod,
    required String newNote,
    required int newDateMillis,
    required String newBillRef,
  }) async {
    if (!Session.isAdmin) throw StateError('Sirf Admin ye action kar sakta hai');
    if (!newAmount.isFinite || newAmount <= 0) throw ArgumentError('Amount must be greater than 0');
    final db = await AppDatabase.instance.database;
    final delta = newAmount - original.amount;
    await db.transaction((txn) async {
      await PeriodCloseRepository.assertOpen(txn, original.createdAt);
      await PeriodCloseRepository.assertOpen(txn, newDateMillis);
      // Naye bill ka baaqi (is payment ka apna purana hissa wapis jod kar) — usse zyada link nahi ho sakta.
      final left = await _billRemaining(txn, isCustomer, newBillRef);
      if (left != null) {
        final allowed = left + (original.billReference == newBillRef ? original.amount : 0.0);
        if (newAmount > allowed + 0.009) {
          throw ArgumentError('Amount bill ke baaqi (Rs ${allowed.toStringAsFixed(2)}) se zyada hai — amount kam karein ya bill se link hata dein');
        }
      }
      final updated = original.copyWith(
        amount: newAmount,
        method: newMethod,
        note: newNote,
        createdAt: newDateMillis,
        billReference: newBillRef,
      );
      await txn.update('payments', updated.toMap(), where: 'id = ?', whereArgs: [original.id]);
      await _enqueue(txn, 'payment', original.id.toString(), 'update', updated.toMap());

      if (delta != 0 && original.partyId != null) {
        await _adjustBalance(txn, isCustomer, original.partyId!, -delta);
      }

      await txn.update(
        'cash_transactions',
        {
          'amount': newAmount,
          'method': newMethod.toLowerCase(),
          'reason': _reason(isCustomer, partyName, newNote),
          'createdAt': newDateMillis,
          'dirty': 1,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'reference = ?',
        whereArgs: [original.reference],
      );
      for (final c in await txn.query('cash_transactions',
          columns: ['id'], where: 'reference = ?', whereArgs: [original.reference])) {
        await SyncQueueHelper.enqueueCashTransaction(txn, c['id'] as int);
      }

      if (original.billReference == newBillRef) {
        await _applyBillPaidDelta(txn, isCustomer, newBillRef, delta);
      } else {
        await _applyBillPaidDelta(txn, isCustomer, original.billReference, -original.amount);
        await _applyBillPaidDelta(txn, isCustomer, newBillRef, newAmount);
      }
    });
    await _refreshParties();
  }

  /// Mirrors deletePayment() — reverses exactly what save() did.
  Future<void> delete({required Payment payment, required bool isCustomer}) async {
    if (!Session.isAdmin) throw StateError('Sirf Admin ye action kar sakta hai');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await PeriodCloseRepository.assertOpen(txn, payment.createdAt);
      // Tombstone ki entity id (serverId-preferred) row delete se PEHLE nikalti hai.
      await SyncQueueHelper.deletePaymentsByReference(txn, payment.reference);
      await SyncQueueHelper.deleteCashTransactionsByReference(txn, payment.reference);

      if (payment.partyId != null) {
        await _adjustBalance(txn, isCustomer, payment.partyId!, payment.amount);
      }
      await _applyBillPaidDelta(txn, isCustomer, payment.billReference, -payment.amount);
    });
    await _refreshParties();
  }

  /// Standalone payments only (Kotlin FIX Bug 1): rows whose `reference` is a
  /// real sale invoice / purchase billNo are bill-embedded cash rows, not
  /// "Receive/Make Payment" entries, so they are excluded.
  /// [fromMillis] null = all time.
  Future<List<PaymentRow>> report({int? fromMillis}) async {
    final db = await AppDatabase.instance.database;
    final customers = {for (final c in await CustomerRepository.instance.listAll()) c.id: c.name};
    final suppliers = {for (final s in await SupplierRepository.instance.listAll()) s.id: s.name};
    final saleInvoices = (await db.query('sales', columns: ['invoice'])).map((r) => r['invoice'] as String).toSet();
    final billNos = (await db.query('purchases', columns: ['billNo'])).map((r) => r['billNo'] as String).toSet();

    final rows = await db.query(
      'payments',
      where: fromMillis == null ? null : 'createdAt >= ?',
      whereArgs: fromMillis == null ? null : [fromMillis],
      orderBy: 'createdAt DESC',
    );
    final out = <PaymentRow>[];
    for (final m in rows) {
      final p = Payment.fromMap(m);
      if (saleInvoices.contains(p.reference) || billNos.contains(p.reference)) continue;
      if (p.partyType == 'customer') {
        final name = customers[p.partyId];
        if (name != null) out.add(PaymentRow(p, name, p.partyId, true));
      } else if (p.partyType == 'supplier') {
        final name = suppliers[p.partyId];
        if (name != null) out.add(PaymentRow(p, name, p.partyId, false));
      }
    }
    return out;
  }

  Future<void> _refreshParties() async {
    await CustomerRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
  }
}
