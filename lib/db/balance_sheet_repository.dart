import '../models/product.dart';
import 'app_database.dart';
import 'cash_repository.dart' show incomeReasonLike, ownerCapitalReasonLike, ownerDrawingsReasonLike;
import 'party_repository.dart';
import '../services/permissions.dart';
import 'unit_cost.dart';

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
    total += p.stock * costPerSmallestOf(p.cost, p.smallestUnitFactor());
  }
  return total;
}

/// Closings ko (positive total, negative total ka absolute) mein baantna.
({double positive, double negative}) splitClosings(Iterable<double> closings) {
  var pos = 0.0, neg = 0.0;
  for (final c in closings) {
    if (c > 0) {
      pos += c;
    } else if (c < 0) {
      neg += -c;
    }
  }
  return (positive: pos, negative: neg);
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

  /// Malik ne dukaan mein dala (Cash In, category Owner Capital) — all-time.
  final double ownerCapitalIn;

  /// Malik ne ghar ke liye nikala (Cash Out, category Owner Drawings) — all-time.
  final double ownerDrawings;

  /// Sirf is mahine ke drawings (malik ko dikhane ke liye: munafa vs ghar kharch).
  final double ownerDrawingsThisMonth;

  const BalanceSheetFigures({
    required this.cashInHand,
    required this.bankBalance,
    required this.stockValue,
    required this.receivables,
    required this.advancePaidToSuppliers,
    required this.payables,
    required this.advanceFromCustomers,
    required this.netProfit,
    this.ownerCapitalIn = 0,
    this.ownerDrawings = 0,
    this.ownerDrawingsThisMonth = 0,
  });

  double get totalAssets => cashInHand + bankBalance + stockValue + receivables + advancePaidToSuppliers;
  double get totalLiabilities => payables + advanceFromCustomers;

  /// Malik ka kul hissa munafe ke ilawa (Assets - Liabilities - Net Profit). Ye ab bhi balancing figure
  /// hai, lekin neeche ke getters is ko hisson mein todte hain: malik ne dala, ghar le gaya, aur baqi
  /// (opening cash/stock/khate, damage, rounding) jo app alag record nahi karti.
  double get capital => totalAssets - totalLiabilities - netProfit;

  /// Capital ka wo hissa jo Owner Capital / Drawings entries se samjhaya nahi ja sakta:
  /// opening cash / bank (agar Owner Capital mein nahi likha), opening stock, parties ke opening baqi,
  /// damage / stock count ka farq, rounding.
  double get openingAndOther => capital - ownerCapitalIn + ownerDrawings;

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
  double otherIncome = 0,
  double ownerCapitalIn = 0,
  double ownerDrawings = 0,
  double ownerDrawingsThisMonth = 0,
}) {
  return BalanceSheetFigures(
    cashInHand: cashIn - cashOut,
    bankBalance: bankIn - bankOut,
    stockValue: stockValue,
    receivables: receivables,
    advancePaidToSuppliers: advancePaidToSuppliers,
    payables: payables,
    advanceFromCustomers: advanceFromCustomers,
    netProfit: (sales - cogs) + otherIncome - expenses,
    ownerCapitalIn: ownerCapitalIn,
    ownerDrawings: ownerDrawings,
    ownerDrawingsThisMonth: ownerDrawingsThisMonth,
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
    if (!Permissions.can('balance_sheet')) {
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

    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month).millisecondsSinceEpoch;

    // Receivable / payable LIVE ledger se (opening + bills - payments, customer ka stuck bhi) —
    // stored `balance` field se nahi, taake Dashboard / Party list ke figures se mel khaye.
    final custRows = await db.query('customers', columns: ['id', 'openingBalance', 'stuckBalance']);
    final suppRows = await db.query('suppliers', columns: ['id', 'openingBalance']);
    final liveCust = await PartyRepository.instance.liveCustomerBalances();
    final liveSupp = await PartyRepository.instance.liveSupplierBalances();
    final custSplit = splitClosings([
      for (final c in custRows)
        partyClosing(
          opening: (c['openingBalance'] as num?)?.toDouble() ?? 0.0,
          running: liveCust[c['id'] as int] ?? 0.0,
          stuck: (c['stuckBalance'] as num?)?.toDouble() ?? 0.0,
        ),
    ]);
    final suppSplit = splitClosings([
      for (final p in suppRows)
        partyClosing(
          opening: (p['openingBalance'] as num?)?.toDouble() ?? 0.0,
          running: liveSupp[p['id'] as int] ?? 0.0,
        ),
    ]);

    final figures = buildBalanceSheet(
      cashIn: await cashTotal('IN', 'cash'),
      cashOut: await cashTotal('OUT', 'cash'),
      bankIn: await cashTotal('IN', 'bank'),
      bankOut: await cashTotal('OUT', 'bank'),
      stockValue: stockValueAtCost(products),
      receivables: custSplit.positive,
      advancePaidToSuppliers: suppSplit.negative,
      payables: suppSplit.positive,
      advanceFromCustomers: custSplit.negative,
      sales: await scalar("SELECT COALESCE(SUM(total),0) FROM sales WHERE status != 'returned'"),
      cogs: await scalar('SELECT COALESCE(SUM(si.cost),0) FROM sale_items si '
          "JOIN sales s ON si.invoice = s.invoice WHERE s.status != 'returned'"),
      expenses: await scalar('SELECT COALESCE(SUM(amount),0) FROM expenses'),
      otherIncome: await scalar(
          "SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='IN' AND reason LIKE '$incomeReasonLike'"),
      ownerCapitalIn: await scalar(
          "SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='IN' AND reason LIKE '$ownerCapitalReasonLike'"),
      ownerDrawings: await scalar(
          "SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='OUT' AND reason LIKE '$ownerDrawingsReasonLike'"),
      ownerDrawingsThisMonth: await scalar(
          "SELECT COALESCE(SUM(amount),0) FROM cash_transactions WHERE type='OUT' AND reason LIKE '$ownerDrawingsReasonLike' "
          'AND createdAt >= ?',
          [monthStart]),
    );

    return BalanceSheetData(
      figures,
      countBalanceDrift(await PartyRepository.instance.ledgers(customers: true)),
      countBalanceDrift(await PartyRepository.instance.ledgers(customers: false)),
    );
  }
}
