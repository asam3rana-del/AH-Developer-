import '../models/misc_entities.dart';
import '../utils/loc.dart';
import 'app_database.dart';

/// Ports the data side of DayBookActivity.kt (`loadDay`).
///
/// [buildDayBook] is a PURE function (no DB, no Flutter) so the Kotlin
/// double-counting fixes can be unit-tested — see test/day_book_test.dart.

/// Kotlin `DayBookSale` (salesBetween). `customerName` is 'Walk-in' when the sale has no customer.
class DayBookSaleRow {
  final String invoice;
  final String customerName;
  final double total;
  final double paid;
  final int createdAt;
  final String status;
  const DayBookSaleRow({
    required this.invoice,
    required this.customerName,
    required this.total,
    required this.paid,
    required this.createdAt,
    required this.status,
  });
}

/// Kotlin `DayBookPurchase` (purchasesBetween). `supplierName` is 'Cash Purchase' when no supplier.
class DayBookPurchaseRow {
  final String billNo;
  final String supplierName;
  final double total;
  final double paid;
  final int createdAt;
  final String status;
  const DayBookPurchaseRow({
    required this.billNo,
    required this.supplierName,
    required this.total,
    required this.paid,
    required this.createdAt,
    required this.status,
  });
}

enum DayBookKind { sale, purchase, expense, cashIn, cashOut }

/// Kotlin `DayBookEntry`. `refType` is 'sale' | 'purchase' for tap-to-open.
class DayBookEntry {
  final int time;
  final DayBookKind kind;
  final String title;
  final String subtitle;
  final double amount;
  final bool isInflow;
  final String? refType;
  final String? refId;
  const DayBookEntry({
    required this.time,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.isInflow,
    this.refType,
    this.refId,
  });
}

class DayBookSummary {
  final double totalSales;
  final double totalPurchases;
  final double totalExpenses;
  final double cashIn;

  /// Cash out from purchases/manual entries only (expenses are separate).
  final double cashOut;
  const DayBookSummary({
    required this.totalSales,
    required this.totalPurchases,
    required this.totalExpenses,
    required this.cashIn,
    required this.cashOut,
  });

  /// Kotlin: net = cashIn - cashOut - totalExpenses.
  double get net => cashIn - cashOut - totalExpenses;

  /// The "Cash Out" card in Kotlin shows cashOut + expenses.
  double get cashOutWithExpenses => cashOut + totalExpenses;
}

class DayBookData {
  final List<DayBookEntry> entries; // newest first
  final DayBookSummary summary;
  const DayBookData(this.entries, this.summary);
}

String _rs0(double v) => 'Rs ${v.toStringAsFixed(0)}';

String _statusNote(String status, double total, double paid) {
  if (status == 'returned') return Loc.t(' (RETURNED)', ' (واپس)');
  if (paid < total) return ' \u2022 ${Loc.t('Due', 'بقایا')} ${_rs0(total - paid)}';
  return '';
}

/// Only these cash rows are shown on their own line; every other reference is a
/// sale/purchase bill payment already represented by that bill's row + "Paid".
///  - blank            : plain manual Cash In/Out
///  - "manual-…"       : Receive Payment / Make Payment from a party
///  - "return:<bill>"  : dated reversal written by a sale/purchase return
bool isStandaloneCash(CashTransaction c) {
  final r = c.reference.trim();
  return r.isEmpty || c.reference.startsWith('manual-') || c.reference.startsWith('return:');
}

/// [linkedPaidByBill] = sum of `payments.amount` grouped by `billReference`
/// (payments linked to a bill are ALREADY inside that bill's `paid` AND are
/// their own cash row, so they are taken back out of the bill's paid to count
/// each rupee once, on the day the money actually moved).
DayBookData buildDayBook({
  required List<DayBookSaleRow> sales,
  required List<DayBookPurchaseRow> purchases,
  required List<Expense> expenses,
  required List<CashTransaction> cashTx,
  required Map<String, double> linkedPaidByBill,
}) {
  final cash = cashTx.where(isStandaloneCash).toList();
  final entries = <DayBookEntry>[];

  for (final s in sales) {
    entries.add(DayBookEntry(
      time: s.createdAt,
      kind: DayBookKind.sale,
      title: '${Loc.t('Sale', 'سیل')} \u2022 ${s.customerName}',
      subtitle: '${Loc.t('Paid', 'ادا شدہ')}: ${_rs0(s.paid)}${_statusNote(s.status, s.total, s.paid)}',
      amount: s.total,
      isInflow: true,
      refType: 'sale',
      refId: s.invoice,
    ));
  }
  for (final p in purchases) {
    entries.add(DayBookEntry(
      time: p.createdAt,
      kind: DayBookKind.purchase,
      title: '${Loc.t('Purchase', 'خریداری')} \u2022 ${p.supplierName}',
      subtitle: '${Loc.t('Paid', 'ادا شدہ')}: ${_rs0(p.paid)}${_statusNote(p.status, p.total, p.paid)}',
      amount: p.total,
      isInflow: false,
      refType: 'purchase',
      refId: p.billNo,
    ));
  }
  for (final e in expenses) {
    entries.add(DayBookEntry(
      time: e.createdAt,
      kind: DayBookKind.expense,
      title: e.category,
      subtitle: e.description.trim().isEmpty ? Loc.t('Expense', 'خرچہ') : e.description,
      amount: e.amount,
      isInflow: false,
    ));
  }
  for (final c in cash) {
    final isIn = c.type == 'IN';
    entries.add(DayBookEntry(
      time: c.createdAt,
      kind: isIn ? DayBookKind.cashIn : DayBookKind.cashOut,
      title: '${isIn ? Loc.t('Cash In', 'کیش ان') : Loc.t('Cash Out', 'کیش آؤٹ')} \u2022 ${c.method.toUpperCase()}',
      subtitle: c.reason.trim().isEmpty ? Loc.t('Manual entry', 'دستی اندراج') : c.reason,
      amount: c.amount,
      isInflow: isIn,
    ));
  }
  entries.sort((a, b) => b.time.compareTo(a.time));

  final liveSales = sales.where((s) => s.status != 'returned');
  final livePurchases = purchases.where((p) => p.status != 'returned');

  double ownPaid(double paid, double? linked) {
    final v = paid - (linked ?? 0.0);
    return v < 0 ? 0.0 : v;
  }

  final totalSales = liveSales.fold<double>(0, (a, s) => a + s.total);
  final totalPurchases = livePurchases.fold<double>(0, (a, p) => a + p.total);
  final totalExpenses = expenses.fold<double>(0, (a, e) => a + e.amount);
  final salesPaidOwn = liveSales.fold<double>(0, (a, s) => a + ownPaid(s.paid, linkedPaidByBill[s.invoice]));
  final purchasesPaidOwn = livePurchases.fold<double>(0, (a, p) => a + ownPaid(p.paid, linkedPaidByBill[p.billNo]));
  final cashIn = cash.where((c) => c.type == 'IN').fold<double>(0, (a, c) => a + c.amount) + salesPaidOwn;
  final cashOut = cash.where((c) => c.type == 'OUT').fold<double>(0, (a, c) => a + c.amount) + purchasesPaidOwn;

  return DayBookData(
    entries,
    DayBookSummary(
      totalSales: totalSales,
      totalPurchases: totalPurchases,
      totalExpenses: totalExpenses,
      cashIn: cashIn,
      cashOut: cashOut,
    ),
  );
}

class DayBookRepository {
  DayBookRepository._();
  static final DayBookRepository instance = DayBookRepository._();

  /// Local-midnight bounds of [day]. Uses DateTime(y, m, d + 1) instead of
  /// "+ 24h" so a daylight-saving day (23/25 h) is still covered exactly.
  static (int start, int end) dayBounds(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  Future<DayBookData> loadDay(DateTime day) async {
    final db = await AppDatabase.instance.database;
    final (start, end) = dayBounds(day);

    final saleRows = await db.rawQuery(
      "SELECT s.invoice AS invoice, COALESCE(c.name, 'Walk-in') AS customerName, "
      's.total AS total, s.paid AS paid, s.createdAt AS createdAt, s.status AS status '
      'FROM sales s LEFT JOIN customers c ON c.id = s.customerId '
      'WHERE s.createdAt >= ? AND s.createdAt < ? ORDER BY s.createdAt ASC',
      [start, end],
    );
    final purchaseRows = await db.rawQuery(
      "SELECT p.billNo AS billNo, COALESCE(sp.name, 'Cash Purchase') AS supplierName, "
      'p.total AS total, p.paid AS paid, p.createdAt AS createdAt, p.status AS status '
      'FROM purchases p LEFT JOIN suppliers sp ON sp.id = p.supplierId '
      'WHERE p.createdAt >= ? AND p.createdAt < ? ORDER BY p.createdAt ASC',
      [start, end],
    );
    final expenseRows = await db.query('expenses',
        where: 'createdAt >= ? AND createdAt < ?', whereArgs: [start, end], orderBy: 'createdAt ASC');
    final cashRows = await db.query('cash_transactions',
        where: 'createdAt >= ? AND createdAt < ?', whereArgs: [start, end], orderBy: 'createdAt ASC');
    // Payments linked to a bill — ALL dates (a payment made on another day still sits inside this bill's `paid`).
    final linkedRows = await db.rawQuery(
        "SELECT billReference AS ref, SUM(amount) AS total FROM payments WHERE billReference != '' GROUP BY billReference");

    return buildDayBook(
      sales: saleRows
          .map((r) => DayBookSaleRow(
                invoice: r['invoice'] as String,
                customerName: r['customerName'] as String,
                total: (r['total'] as num).toDouble(),
                paid: (r['paid'] as num).toDouble(),
                createdAt: (r['createdAt'] as num).toInt(),
                status: (r['status'] as String?) ?? 'active',
              ))
          .toList(),
      purchases: purchaseRows
          .map((r) => DayBookPurchaseRow(
                billNo: r['billNo'] as String,
                supplierName: r['supplierName'] as String,
                total: (r['total'] as num).toDouble(),
                paid: (r['paid'] as num).toDouble(),
                createdAt: (r['createdAt'] as num).toInt(),
                status: (r['status'] as String?) ?? 'active',
              ))
          .toList(),
      expenses: expenseRows.map(Expense.fromMap).toList(),
      cashTx: cashRows.map(CashTransaction.fromMap).toList(),
      linkedPaidByBill: {
        for (final r in linkedRows) r['ref'] as String: (r['total'] as num).toDouble(),
      },
    );
  }
}
