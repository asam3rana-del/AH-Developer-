import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../models/party.dart';
import '../models/purchase.dart';
import '../models/sale.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'supplier_repository.dart';

/// Ports PartyRepository.kt + PartyUseCases.kt (ViewModel/Factory skip — PORTING_PLAN).
///
/// Rules (PORTING_PLAN §1):
///  * balance / bills / payments badalne wali har cheez ek DB transaction mein.
///  * Screens par jo balance dikhta hai wo HAMESHA ledger se dobara hisaab ho kar aata hai
///    ([liveCustomerBalances] / [liveSupplierBalances]) — stored `balance` field se nahi
///    (Kotlin "PERMANENT FIX balance drift").
///  * Stuck balance sirf admin/manager set/badal sakta hai — yahan data layer par bhi check hai.
///
/// Maths PURE functions mein hai ([partyClosing], [trueBalance], [groupDuplicatePayments],
/// [pickOrphanedPayments] ...) taake test ho sake — see test/party_test.dart.

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Party ka closing figure: opening + live running (+ stuck, sirf customers ke liye).
double partyClosing({required double opening, required double running, double stuck = 0.0}) =>
    opening + running + stuck;

/// true => dukaan ne party ko dena hai ("You'll Give").
///  * Customer closing < 0  => dukaan customer ki devdaar hai
///  * Supplier closing > 0  => dukaan supplier ki devdaar hai
bool partyIsGive({required bool isCustomer, required double closing}) => isCustomer ? closing < 0 : closing > 0;

/// "Dues only" filter. (Kotlin `!= 0.0`; yahan 0.009 ki tolerance taake float noise
/// "Rs 0.00" wali party ko due na dikhaye — baaki jagah bhi yehi hadd hai.)
bool partyHasDue({required double opening, required double running, double stuck = 0.0}) =>
    partyClosing(opening: opening, running: running, stuck: stuck).abs() > 0.009;

/// Search box: naam ya phone mein query (case-insensitive). Khali query => sab.
bool partyMatchesQuery(String name, String phone, String query) {
  final q = query.trim().toLowerCase();
  return q.isEmpty || name.toLowerCase().contains(q) || phone.toLowerCase().contains(q);
}

/// One party's bills + payments, enough to recompute its true balance.
/// (Pehle balance_sheet_repository.dart mein tha — ab yahan ek hi copy hai.)
class PartyLedger {
  final int partyId;
  final double storedBalance;
  final List<({String id, String status, double total, double paid})> bills;
  final List<({String reference, String billReference, double amount})> payments;
  const PartyLedger({this.partyId = 0, required this.storedBalance, required this.bills, required this.payments});
}

/// Kotlin trueCustomerBalance / trueSupplierBalance:
///   sum(total - paid) of non-returned bills  -  sum(payment amounts)
/// where a payment is skipped if it is already inside a bill's `paid`
/// (its reference is a bill id, or its billReference points at a known bill —
/// the id set is built from ALL bills, returned ones included).
double trueBalance(PartyLedger l) {
  final ids = {for (final b in l.bills) b.id};
  final owed = l.bills.where((b) => b.status != 'returned').fold<double>(0, (a, b) => a + b.total - b.paid);
  final paidSeparately = l.payments
      .where((p) => !ids.contains(p.reference) && !(p.billReference.isNotEmpty && ids.contains(p.billReference)))
      .fold<double>(0, (a, p) => a + p.amount);
  return owed - paidSeparately;
}

/// Dry-run of Kotlin `recalculateBalances(dryRun = true)`: how many parties
/// have a stored balance that differs from the recomputed one. Writes nothing.
int countBalanceDrift(Iterable<PartyLedger> parties) =>
    parties.where((p) => (trueBalance(p) - p.storedBalance).abs() > 0.009).length;

/// One bill's worth of stuck duplicate payments (Kotlin `DuplicatePaymentGroup`).
/// [keep] wo row hai jo sahi maani gayi, [remove] baaki sab jo cleanup hatayega.
class DuplicatePaymentGroup {
  final String partyType;
  final int? partyId;
  final String partyName;
  final String reference;
  final Payment keep;
  final List<Payment> remove;
  const DuplicatePaymentGroup({
    required this.partyType,
    required this.partyId,
    required this.partyName,
    required this.reference,
    required this.keep,
    required this.remove,
  });

  double get removeTotal => remove.fold<double>(0, (a, p) => a + p.amount);
}

/// Kotlin `findDuplicatePayments`: (partyType, partyId, reference) ke hisaab se group; jis group
/// mein 1 se zyada rows hon wo duplicate hai. Group mein sab se naya (updatedAt, createdAt, id)
/// row rakha jata hai, baaqi hatane ke liye. Bara nuqsaan wale group pehle.
List<DuplicatePaymentGroup> groupDuplicatePayments(
  List<Payment> all, {
  required Map<int, String> customerNames,
  required Map<int, String> supplierNames,
}) {
  final groups = <String, List<Payment>>{};
  for (final p in all) {
    if (p.partyId == null) continue;
    (groups['${p.partyType}|${p.partyId}|${p.reference}'] ??= []).add(p);
  }
  final out = <DuplicatePaymentGroup>[];
  for (final g in groups.values) {
    if (g.length < 2) continue;
    final sorted = [...g]..sort((a, b) {
        final byUpdated = a.updatedAt.compareTo(b.updatedAt);
        if (byUpdated != 0) return byUpdated;
        final byCreated = a.createdAt.compareTo(b.createdAt);
        if (byCreated != 0) return byCreated;
        return (a.id ?? 0).compareTo(b.id ?? 0);
      });
    final first = g.first;
    final names = first.partyType == 'customer' ? customerNames : supplierNames;
    out.add(DuplicatePaymentGroup(
      partyType: first.partyType,
      partyId: first.partyId,
      partyName: names[first.partyId] ?? '#${first.partyId}',
      reference: first.reference,
      keep: sorted.last,
      remove: sorted.sublist(0, sorted.length - 1),
    ));
  }
  out.sort((a, b) => b.removeTotal.compareTo(a.removeTotal));
  return out;
}

/// Kotlin `findOrphanedPayments`: bill-embedded payment (reference "manual-" se shuru nahi hota)
/// jiska sale/purchase ab maujood nahi. Unknown partyType kabhi orphan nahi maani jati.
List<Payment> pickOrphanedPayments(
  List<Payment> all, {
  required Set<String> saleInvoices,
  required Set<String> purchaseBillNos,
}) {
  bool orphan(Payment p) {
    if (p.reference.startsWith('manual-')) return false;
    switch (p.partyType) {
      case 'supplier':
        return !purchaseBillNos.contains(p.reference);
      case 'customer':
        return !saleInvoices.contains(p.reference);
      default:
        return false;
    }
  }

  return [for (final p in all) if (orphan(p)) p];
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// Kotlin `SavePartyResult`.
enum SavePartyResult { success, nameRequired }

/// How many customers/suppliers had a drifted balance corrected (0/0 = sab theek).
class RecalcResult {
  final int customersFixed;
  final int suppliersFixed;
  const RecalcResult(this.customersFixed, this.suppliersFixed);
}

/// How many duplicate customer/supplier ROWS were merged away (3 same-name = 2 merged).
class MergeResult {
  final int customersMerged;
  final int suppliersMerged;
  const MergeResult(this.customersMerged, this.suppliersMerged);
}

/// Stray payment rows deleted + the balance recalculation that followed.
class CleanupPaymentsResult {
  final int paymentsRemoved;
  final RecalcResult recalc;
  const CleanupPaymentsResult(this.paymentsRemoved, this.recalc);
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

class PartyRepository {
  PartyRepository._();
  static final PartyRepository instance = PartyRepository._();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  // NOTE (Phase 10): payload abhi `Map.toString()` hai (baaki repositories jaisa); entityId mein
  // DeviceTag (`customer:<device>-<id>`) sync phase mein aayega.
  Future<void> _enqueue(DatabaseExecutor ex, String type, String id, String op, Map<String, Object?> payload) =>
      ex.insert('sync_queue', {
        'entityType': type,
        'entityId': id,
        'operation': op,
        'payloadJson': payload.toString(),
        'createdAt': _now(),
        'retryCount': 0,
      });

  String _customerEntityId(Customer c) => c.serverId ?? 'customer:${c.id}';
  String _supplierEntityId(Supplier s) => s.serverId ?? 'supplier:${s.id}';

  Future<void> _refreshParties() async {
    await CustomerRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
  }

  // ---- use cases: validate + save / update -------------------------------

  /// Kotlin SaveCustomerUseCase. Naam trim; khali naam => [SavePartyResult.nameRequired].
  Future<SavePartyResult> addCustomer({
    required String name,
    required String phone,
    required double creditLimit,
    required double openingBalance,
    double stuckBalance = 0.0,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    await saveCustomer(Customer(
      name: trimmed,
      phone: phone.trim(),
      creditLimit: creditLimit,
      openingBalance: openingBalance,
      balance: 0.0,
      stuckBalance: stuckBalance,
    ));
    return SavePartyResult.success;
  }

  Future<SavePartyResult> addSupplier({
    required String name,
    required String phone,
    required double openingBalance,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    await saveSupplier(Supplier(name: trimmed, phone: phone.trim(), openingBalance: openingBalance, balance: 0.0));
    return SavePartyResult.success;
  }

  /// Kotlin UpdateCustomerUseCase. [stuckBalance] null => "chhedna nahi" (purana rahe).
  Future<SavePartyResult> editCustomer(
    Customer existing, {
    required String name,
    required String phone,
    required double creditLimit,
    required double openingBalance,
    double? stuckBalance,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    await updateCustomer(existing.copyWith(
      name: trimmed,
      phone: phone.trim(),
      creditLimit: creditLimit,
      openingBalance: openingBalance,
      stuckBalance: stuckBalance ?? existing.stuckBalance,
    ));
    return SavePartyResult.success;
  }

  Future<SavePartyResult> editSupplier(
    Supplier existing, {
    required String name,
    required String phone,
    required double openingBalance,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return SavePartyResult.nameRequired;
    await updateSupplier(existing.copyWith(name: trimmed, phone: phone.trim(), openingBalance: openingBalance));
    return SavePartyResult.success;
  }

  // ---- raw CRUD (+ sync queue, ek transaction mein) -----------------------

  Future<int> saveCustomer(Customer customer) async {
    final db = await AppDatabase.instance.database;
    final id = await db.transaction((txn) async {
      final row = customer.toMap()..remove('id');
      row['updatedAt'] = _now();
      row['dirty'] = 1;
      // Data-layer role check: cashier stuck balance set nahi kar sakta.
      if (!Session.isAdminOrManager) row['stuckBalance'] = 0.0;
      final newId = await txn.insert('customers', row);
      await _enqueue(txn, 'customer', customer.serverId ?? 'customer:$newId', 'upsert', {...row, 'id': newId});
      return newId;
    });
    await CustomerRepository.instance.refresh();
    return id;
  }

  Future<int> saveSupplier(Supplier supplier) async {
    final db = await AppDatabase.instance.database;
    final id = await db.transaction((txn) async {
      final row = supplier.toMap()..remove('id');
      row['updatedAt'] = _now();
      row['dirty'] = 1;
      final newId = await txn.insert('suppliers', row);
      await _enqueue(txn, 'supplier', supplier.serverId ?? 'supplier:$newId', 'upsert', {...row, 'id': newId});
      return newId;
    });
    await SupplierRepository.instance.refresh();
    return id;
  }

  Future<void> updateCustomer(Customer customer) async {
    if (customer.id == null) throw ArgumentError('updateCustomer: id missing');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final row = customer.toMap()
        ..['updatedAt'] = _now()
        ..['dirty'] = 1;
      if (!Session.isAdminOrManager) {
        // Cashier: stuck amount kabhi nahi badalta — DB wali value hi rahe.
        final cur = await txn.query('customers', columns: ['stuckBalance'], where: 'id = ?', whereArgs: [customer.id]);
        row['stuckBalance'] = cur.isEmpty ? 0.0 : ((cur.first['stuckBalance'] as num?)?.toDouble() ?? 0.0);
      }
      await txn.update('customers', row, where: 'id = ?', whereArgs: [customer.id]);
      await _enqueue(txn, 'customer', _customerEntityId(customer), 'upsert', row);
    });
    await CustomerRepository.instance.refresh();
  }

  Future<void> updateSupplier(Supplier supplier) async {
    if (supplier.id == null) throw ArgumentError('updateSupplier: id missing');
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final row = supplier.toMap()
        ..['updatedAt'] = _now()
        ..['dirty'] = 1;
      await txn.update('suppliers', row, where: 'id = ?', whereArgs: [supplier.id]);
      await _enqueue(txn, 'supplier', _supplierEntityId(supplier), 'upsert', row);
    });
    await SupplierRepository.instance.refresh();
  }

  /// Sale/purchase history chhedi nahi jati (naam se history mein rehti hai); sirf party row
  /// jati hai + sync tombstone (Kotlin deleteCustomer).
  Future<void> deleteCustomer(Customer customer) async {
    if (customer.id == null) return;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete('customers', where: 'id = ?', whereArgs: [customer.id]);
      await _enqueue(txn, 'customer', _customerEntityId(customer), 'delete', const {});
    });
    await CustomerRepository.instance.refresh();
  }

  Future<void> deleteSupplier(Supplier supplier) async {
    if (supplier.id == null) return;
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete('suppliers', where: 'id = ?', whereArgs: [supplier.id]);
      await _enqueue(txn, 'supplier', _supplierEntityId(supplier), 'delete', const {});
    });
    await SupplierRepository.instance.refresh();
  }

  // ---- history -----------------------------------------------------------

  /// Party ki saari sales (returned samet — Kotlin jaisa), sab se nayi pehle.
  Future<List<Sale>> salesByCustomer(int customerId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sales', where: 'customerId = ?', whereArgs: [customerId], orderBy: 'createdAt DESC');
    return rows.map(Sale.fromMap).toList();
  }

  Future<List<Purchase>> purchasesBySupplier(int supplierId) async {
    final db = await AppDatabase.instance.database;
    final rows =
        await db.query('purchases', where: 'supplierId = ?', whereArgs: [supplierId], orderBy: 'createdAt DESC');
    return rows.map(Purchase.fromMap).toList();
  }

  // ---- live balances (ledger se, stored field se nahi) --------------------

  Future<List<PartyLedger>> _loadLedgers(DatabaseExecutor ex, {required bool customers, int? onlyPartyId}) async {
    final partyTable = customers ? 'customers' : 'suppliers';
    final billTable = customers ? 'sales' : 'purchases';
    final billKey = customers ? 'invoice' : 'billNo';
    final partyCol = customers ? 'customerId' : 'supplierId';
    final partyType = customers ? 'customer' : 'supplier';

    final parties = await ex.query(
      partyTable,
      columns: ['id', 'balance'],
      where: onlyPartyId == null ? null : 'id = ?',
      whereArgs: onlyPartyId == null ? null : [onlyPartyId],
    );
    final billRows = await ex.query(
      billTable,
      columns: [billKey, partyCol, 'status', 'total', 'paid'],
      where: onlyPartyId == null ? null : '$partyCol = ?',
      whereArgs: onlyPartyId == null ? null : [onlyPartyId],
    );
    final payRows = await ex.query(
      'payments',
      columns: ['partyId', 'reference', 'billReference', 'amount'],
      where: onlyPartyId == null ? 'partyType = ?' : 'partyType = ? AND partyId = ?',
      whereArgs: onlyPartyId == null ? [partyType] : [partyType, onlyPartyId],
    );

    final billsBy = <int, List<({String id, String status, double total, double paid})>>{};
    for (final b in billRows) {
      final pid = b[partyCol] as int?;
      if (pid == null) continue;
      (billsBy[pid] ??= []).add((
        id: b[billKey] as String,
        status: (b['status'] as String?) ?? 'active',
        total: (b['total'] as num).toDouble(),
        paid: (b['paid'] as num).toDouble(),
      ));
    }
    final paysBy = <int, List<({String reference, String billReference, double amount})>>{};
    for (final p in payRows) {
      final pid = p['partyId'] as int?;
      if (pid == null) continue;
      (paysBy[pid] ??= []).add((
        reference: p['reference'] as String,
        billReference: (p['billReference'] as String?) ?? '',
        amount: (p['amount'] as num).toDouble(),
      ));
    }

    return [
      for (final p in parties)
        PartyLedger(
          partyId: p['id'] as int,
          storedBalance: (p['balance'] as num).toDouble(),
          bills: billsBy[p['id'] as int] ?? const [],
          payments: paysBy[p['id'] as int] ?? const [],
        ),
    ];
  }

  /// Sab parties ke ledger (Balance Sheet ka drift check bhi yahi istemal karta hai).
  Future<List<PartyLedger>> ledgers({required bool customers}) async =>
      _loadLedgers(await AppDatabase.instance.database, customers: customers);

  /// Har customer ka live "running" balance (openingBalance / stuckBalance shamil NAHI —
  /// call site par jorein). Bills + payments se taza hisaab, stored field se nahi.
  Future<Map<int, double>> liveCustomerBalances() async => {
        for (final l in await ledgers(customers: true)) l.partyId: trueBalance(l),
      };

  Future<Map<int, double>> liveSupplierBalances() async => {
        for (final l in await ledgers(customers: false)) l.partyId: trueBalance(l),
      };

  /// Ek party ka live balance (Purchase/Sale entry screens ke "Party balance" ke liye).
  Future<double> liveCustomerBalance(int customerId) async {
    final l = await _loadLedgers(await AppDatabase.instance.database, customers: true, onlyPartyId: customerId);
    return l.isEmpty ? 0.0 : trueBalance(l.first);
  }

  Future<double> liveSupplierBalance(int supplierId) async {
    final l = await _loadLedgers(await AppDatabase.instance.database, customers: false, onlyPartyId: supplierId);
    return l.isEmpty ? 0.0 : trueBalance(l.first);
  }

  // ---- Fix Balances -------------------------------------------------------

  /// Stored `balance` ko ledger ke hisaab se theek karta hai — sirf FARQ ka increment
  /// (raw overwrite nahi), taake doosre device ki unsynced tabdeeli na rundhe.
  Future<RecalcResult> _recalcIn(DatabaseExecutor ex, {required bool dryRun}) async {
    var customersFixed = 0;
    var suppliersFixed = 0;
    for (final isCustomer in const [true, false]) {
      final table = isCustomer ? 'customers' : 'suppliers';
      final type = isCustomer ? 'customer' : 'supplier';
      for (final l in await _loadLedgers(ex, customers: isCustomer)) {
        final delta = trueBalance(l) - l.storedBalance;
        if (delta.abs() <= 0.009) continue;
        if (!dryRun) {
          await ex.rawUpdate(
            'UPDATE $table SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
            [delta, _now(), l.partyId],
          );
          await _enqueue(ex, type, '$type:${l.partyId}', 'increment_balance', {'delta': delta});
        }
        if (isCustomer) {
          customersFixed++;
        } else {
          suppliersFixed++;
        }
      }
    }
    return RecalcResult(customersFixed, suppliersFixed);
  }

  /// Kotlin `recalculateBalances`. [dryRun] = true: sirf ginta hai, kuch likhta nahi.
  Future<RecalcResult> recalculateBalances({bool dryRun = false}) async {
    final db = await AppDatabase.instance.database;
    if (dryRun) return _recalcIn(db, dryRun: true);
    final r = await db.transaction((txn) => _recalcIn(txn, dryRun: false));
    if (r.customersFixed > 0 || r.suppliersFixed > 0) await _refreshParties();
    return r;
  }

  // ---- Merge Duplicates ---------------------------------------------------

  /// Kotlin `mergeDuplicateParties`: bilkul ek jaisa naam (trim, case-insensitive) — sab se
  /// chhoti id rakhi jati hai, baaqi ki sales/purchases/payments us par shift, opening
  /// (aur customers ka stuck) jama, extra row delete. Aakhir mein balances dobara theek.
  /// Sab kuch ek transaction mein — beech mein fail ho to kuch nahi badalta.
  Future<MergeResult> mergeDuplicateParties() async {
    final db = await AppDatabase.instance.database;
    final result = await db.transaction((txn) async {
      final now = _now();
      var customersMerged = 0;
      var suppliersMerged = 0;

      // ---- customers ----
      final customers = (await txn.query('customers', orderBy: 'id ASC')).map(Customer.fromMap).toList();
      final customerGroups = <String, List<Customer>>{};
      for (final c in customers) {
        (customerGroups[c.name.trim().toLowerCase()] ??= []).add(c);
      }
      for (final group in customerGroups.values) {
        if (group.length < 2) continue;
        var keeper = group.first;
        for (final dup in group.skip(1)) {
          final sales = await txn.query('sales', columns: ['invoice'], where: 'customerId = ?', whereArgs: [dup.id]);
          await txn.update('sales', {'customerId': keeper.id, 'dirty': 1, 'updatedAt': now},
              where: 'customerId = ?', whereArgs: [dup.id]);
          for (final s in sales) {
            await _enqueue(txn, 'sale', 'sale:${s['invoice']}', 'update', {'customerId': keeper.id});
          }
          await _repointPayments(txn, 'customer', dup.id!, keeper.id!, now);
          // Stuck amount merge mein ZAYA nahi hona chahiye — opening ki tarah keeper mein jama.
          if (dup.openingBalance != 0.0 || dup.stuckBalance != 0.0) {
            keeper = keeper.copyWith(
              openingBalance: keeper.openingBalance + dup.openingBalance,
              stuckBalance: keeper.stuckBalance + dup.stuckBalance,
              updatedAt: now,
              dirty: true,
            );
            await txn.update('customers', keeper.toMap(), where: 'id = ?', whereArgs: [keeper.id]);
            await _enqueue(txn, 'customer', _customerEntityId(keeper), 'upsert', keeper.toMap());
          }
          await txn.delete('customers', where: 'id = ?', whereArgs: [dup.id]);
          await _enqueue(txn, 'customer', _customerEntityId(dup), 'delete', const {});
          customersMerged++;
        }
      }

      // ---- suppliers ----
      final suppliers = (await txn.query('suppliers', orderBy: 'id ASC')).map(Supplier.fromMap).toList();
      final supplierGroups = <String, List<Supplier>>{};
      for (final s in suppliers) {
        (supplierGroups[s.name.trim().toLowerCase()] ??= []).add(s);
      }
      for (final group in supplierGroups.values) {
        if (group.length < 2) continue;
        var keeper = group.first;
        for (final dup in group.skip(1)) {
          final purchases =
              await txn.query('purchases', columns: ['billNo'], where: 'supplierId = ?', whereArgs: [dup.id]);
          await txn.update('purchases', {'supplierId': keeper.id, 'dirty': 1, 'updatedAt': now},
              where: 'supplierId = ?', whereArgs: [dup.id]);
          for (final p in purchases) {
            await _enqueue(txn, 'purchase', 'purchase:${p['billNo']}', 'update', {'supplierId': keeper.id});
          }
          await _repointPayments(txn, 'supplier', dup.id!, keeper.id!, now);
          if (dup.openingBalance != 0.0) {
            keeper = keeper.copyWith(
              openingBalance: keeper.openingBalance + dup.openingBalance,
              updatedAt: now,
              dirty: true,
            );
            await txn.update('suppliers', keeper.toMap(), where: 'id = ?', whereArgs: [keeper.id]);
            await _enqueue(txn, 'supplier', _supplierEntityId(keeper), 'upsert', keeper.toMap());
          }
          await txn.delete('suppliers', where: 'id = ?', whereArgs: [dup.id]);
          await _enqueue(txn, 'supplier', _supplierEntityId(dup), 'delete', const {});
          suppliersMerged++;
        }
      }

      // Ab saari history keeper par hai — balance ledger se dobara theek.
      if (customersMerged > 0 || suppliersMerged > 0) await _recalcIn(txn, dryRun: false);
      return MergeResult(customersMerged, suppliersMerged);
    });
    if (result.customersMerged > 0 || result.suppliersMerged > 0) await _refreshParties();
    return result;
  }

  Future<void> _repointPayments(DatabaseExecutor txn, String partyType, int fromId, int toId, int now) async {
    final pays = await txn.query('payments',
        columns: ['id', 'serverId'], where: 'partyType = ? AND partyId = ?', whereArgs: [partyType, fromId]);
    await txn.update('payments', {'partyId': toId, 'dirty': 1, 'updatedAt': now},
        where: 'partyType = ? AND partyId = ?', whereArgs: [partyType, fromId]);
    for (final p in pays) {
      await _enqueue(txn, 'payment', (p['serverId'] as String?) ?? '${p['id']}', 'update', {'partyId': toId});
    }
  }

  // ---- Cleanup Payments / Cleanup Orphaned --------------------------------

  Future<({Map<int, String> customers, Map<int, String> suppliers})> _partyNames(DatabaseExecutor ex) async {
    final c = await ex.query('customers', columns: ['id', 'name']);
    final s = await ex.query('suppliers', columns: ['id', 'name']);
    return (
      customers: {for (final r in c) r['id'] as int: r['name'] as String},
      suppliers: {for (final r in s) r['id'] as int: r['name'] as String},
    );
  }

  Future<List<Payment>> _allPayments(DatabaseExecutor ex) async =>
      (await ex.query('payments')).map(Payment.fromMap).toList();

  /// Preview step: kuch delete nahi hota.
  Future<List<DuplicatePaymentGroup>> findDuplicatePayments() async {
    final db = await AppDatabase.instance.database;
    final names = await _partyNames(db);
    return groupDuplicatePayments(await _allPayments(db),
        customerNames: names.customers, supplierNames: names.suppliers);
  }

  /// [groups] = wahi jo preview mein dikhaye gaye (confirm ke beech aayi nayi payment na hate).
  Future<CleanupPaymentsResult> cleanupDuplicatePayments([List<DuplicatePaymentGroup>? groups]) async {
    final target = groups ?? await findDuplicatePayments();
    return _removePayments([for (final g in target) ...g.remove]);
  }

  Future<List<Payment>> findOrphanedPayments() async {
    final db = await AppDatabase.instance.database;
    final invoices = (await db.query('sales', columns: ['invoice'])).map((r) => r['invoice'] as String).toSet();
    final billNos = (await db.query('purchases', columns: ['billNo'])).map((r) => r['billNo'] as String).toSet();
    return pickOrphanedPayments(await _allPayments(db), saleInvoices: invoices, purchaseBillNos: billNos);
  }

  Future<CleanupPaymentsResult> cleanupOrphanedPayments([List<Payment>? payments]) async {
    final target = payments ?? await findOrphanedPayments();
    return _removePayments(target);
  }

  /// Kotlin `SyncQueueHelper.deletePayment` (sirf payment row + sync delete — cash/bill ko
  /// nahi chhedta) phir balances ki dobara ginti. Sab ek transaction mein.
  Future<CleanupPaymentsResult> _removePayments(List<Payment> rows) async {
    final db = await AppDatabase.instance.database;
    var removed = 0;
    final recalc = await db.transaction((txn) async {
      for (final p in rows) {
        if (p.id == null) continue;
        await txn.delete('payments', where: 'id = ?', whereArgs: [p.id]);
        await _enqueue(txn, 'payment', p.serverId ?? '${p.id}', 'delete', const {});
        removed++;
      }
      return removed > 0 ? await _recalcIn(txn, dryRun: false) : const RecalcResult(0, 0);
    });
    if (removed > 0) await _refreshParties();
    return CleanupPaymentsResult(removed, recalc);
  }
}
