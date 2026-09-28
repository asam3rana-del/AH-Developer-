import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'party_repository.dart';

// PartyLedger / trueBalance / countBalanceDrift ab party_repository.dart mein hain (ek hi copy);
// purane imports (aur test/balance_sheet_test.dart) chalte rahein isliye yahan se re-export.
export 'party_repository.dart' show PartyLedger, trueBalance, countBalanceDrift;

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
      countBalanceDrift(await PartyRepository.instance.ledgers(customers: true)),
      countBalanceDrift(await PartyRepository.instance.ledgers(customers: false)),
    );
  }
}
