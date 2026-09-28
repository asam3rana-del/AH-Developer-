import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';

/// Ports the data side of BalanceSheetActivity.kt (`loadBalanceSheet`).
///
/// Assets = Liabilities + Capital, built from data the app already tracks.
/// The maths lives in PURE functions ([stockValueAtCost], [buildBalanceSheet],
/// [countBalanceDrift]) so it can be unit-tested — see test/balance_sheet_test.dart.
///
/// Admin / Manager only: [BalanceSheetRepository.load] re-checks the role
/// (the screen is also wrapped in a RoleGuard) because this reads cost data.

/// Kotlin FIX: `stock` is in the SMALLEST unit but `cost` is per PRIMARY unit,
/// so value = stock * (cost / smallestUnitFactor) — never stock * cost.
double stockValueAtCost(Iterable<Product> products) {
  double total = 0;
  for (final p in products) {
    final factor = p.smallestUnitFactor();
    final costPerSmallest = factor > 0 ? p.cost / factor : p.cost;
    total += p.stock * costPerSmallest;
  }
  return total;
}

class BalanceSheetFigures {
  // Assets
  final double cashInHand;
  final double bankBalance;
  final double stockValue;
  final double receivables;
  final double advancePaidToSuppliers;
  // Liabilities
  final double payables;
  final double advanceFromCustomers;
  // Equity inputs
  final double netProfit;

  const BalanceSheetFigures({
    required this.cashInHand,
    required this.bankBalance,
    required this.stockValue,
    required this.receivables,
    required this.advancePaidToSuppliers,
    required this.payables,
    required this.advanceFromCustomers,
    required this.netProfit,
  });

  double get totalAssets => cashInHand + bankBalance + stockValue + receivables + advancePaidToSuppliers;
  double get totalLiabilities => payables + advanceFromCustomers;

  /// Balancing figure (the app has no separate "owner capital" entry).
  double get capital => totalAssets - totalLiabilities - netProfit;

  /// Kotlin: totalLiabilities + capital + netProfit (== totalAssets by construction).
  double get totalLiabilitiesAndCapital => totalLiabilities + capital + netProfit;

  bool get cashOrBankNegative => cashInHand < -0.009 || bankBalance < -0.009;
}

/// [sales] / [cogs] = all-time, excluding returned bills. [expenses] = all-time.
BalanceSheetFigures buildBalanceSheet({
  required double cashIn,
  required double cashOut,
  required double bankIn,
  required double bankOut,
  required double stockValue,
  required double receivables,
  required double advancePaidToSuppliers,
  required double payables,
  required double advanceFromCustomers,
  required double sales,
  required double cogs,
  required double expenses,
}) {
  return BalanceSheetFigures(
    cashInHand: cashIn - cashOut,
    bankBalance: bankIn - bankOut,
    stockValue: stockValue,
    receivables: receivables,
    advancePaidToSuppliers: advancePaidToSuppliers,
    payables: payables,
    advanceFromCustomers: advanceFromCustomers,
    netProfit: (sales - cogs) - expenses,
  );
}

/// One party's bills + payments, enough to recompute its true balance.
class PartyLedger {
  final double storedBalance;
  final List<({String id, String status, double total, double paid})> bills;
  final List<({String reference, String billReference, double amount})> payments;
  const PartyLedger({required this.storedBalance, required this.bills, required this.payments});
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

class BalanceSheetData {
  final BalanceSheetFigures figures;
  final int customersDrifted;
  final int suppliersDrifted;
  const BalanceSheetData(this.figures, this.customersDrifted, this.suppliersDrifted);
}

class BalanceSheetRepository {
  BalanceSheetRepository._();
  static final BalanceSheetRepository instance = BalanceSheetRepository._();

  Future<BalanceSheetData> load() async {
    if (!Session.isAdminOrManager) {
      throw StateError('Sirf Admin/Manager is screen ko access kar sakta hai');
    }
    final db = await AppDatabase.instance.database;

    Future<double> scalar(String sql, [List<Object?>? args]) async {
      final r = await db.rawQuery(sql, args);
      if (r.isEmpty) return 0.0;
      return ((r.first.values.first) as num?)?.toDouble() ?? 0.0;
    }

    Future<double> cashTotal(String type, String method) => scalar(
        'SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type=? AND method=?', [type, method]);

    final products = (await db.query('products')).map(Product.fromMap).toList();

    final figures = buildBalanceSheet(
      cashIn: await cashTotal('IN', 'cash'),
      cashOut: await cashTotal('OUT', 'cash'),
      bankIn: await cashTotal('IN', 'bank'),
      bankOut: await cashTotal('OUT', 'bank'),
      stockValue: stockValueAtCost(products),
      receivables: await scalar('SELECT COALESCE(SUM(balance),0) FROM customers WHERE balance>0'),
      advancePaidToSuppliers: await scalar('SELECT COALESCE(SUM(-balance),0) FROM suppliers WHERE balance<0'),
      payables: await scalar('SELECT COALESCE(SUM(balance),0) FROM suppliers WHERE balance>0'),
      advanceFromCustomers: await scalar('SELECT COALESCE(SUM(-balance),0) FROM customers WHERE balance<0'),
      sales: await scalar("SELECT COALESCE(SUM(total),0) FROM sales WHERE status != 'returned'"),
      cogs: await scalar('SELECT COALESCE(SUM(si.cost),0) FROM sale_items si '
          "JOIN sales s ON si.invoice = s.invoice WHERE s.status != 'returned'"),
      expenses: await scalar('SELECT COALESCE(SUM(amount),0) FROM expenses'),
    );

    return BalanceSheetData(
      figures,
      countBalanceDrift(await _ledgers(customers: true)),
      countBalanceDrift(await _ledgers(customers: false)),
    );
  }

  Future<List<PartyLedger>> _ledgers({required bool customers}) async {
    final db = await AppDatabase.instance.database;
    final partyTable = customers ? 'customers' : 'suppliers';
    final billTable = customers ? 'sales' : 'purchases';
    final billKey = customers ? 'invoice' : 'billNo';
    final partyCol = customers ? 'customerId' : 'supplierId';
    final partyType = customers ? 'customer' : 'supplier';

    final parties = await db.query(partyTable, columns: ['id', 'balance']);
    final billRows = await db.query(billTable, columns: [billKey, partyCol, 'status', 'total', 'paid']);
    final payRows = await db.query('payments',
        columns: ['partyId', 'reference', 'billReference', 'amount'], where: 'partyType = ?', whereArgs: [partyType]);

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
          storedBalance: (p['balance'] as num).toDouble(),
          bills: billsBy[p['id'] as int] ?? const [],
          payments: paysBy[p['id'] as int] ?? const [],
        ),
    ];
  }
}
