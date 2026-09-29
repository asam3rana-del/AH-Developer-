import 'package:intl/intl.dart';

import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';

/// Ports the data side of MonthlySalesPurchaseActivity.kt.
///
/// Maths PURE functions mein hai ([selectEntries], [groupPeriods]) — test/monthly_test.dart.
/// Admin / Manager only ([MonthlyRepository.load] role dobara check karta hai; purchase amounts cost data hain).

enum GroupMode { month, year }

/// Ek sale/purchase (ya item line) ka waqt aur raqam.
class AmountEntry {
  final int createdAt;
  final double amount;
  const AmountEntry(this.createdAt, this.amount);
}

class PeriodTotals {
  final String key;
  final String label;
  final double sale;
  final double purchase;
  const PeriodTotals({required this.key, required this.label, required this.sale, required this.purchase});
  double get net => sale - purchase;
}

class PartyOption {
  final int id;
  final String name;
  final bool isCustomer;
  const PartyOption(this.id, this.name, this.isCustomer);
}

/// Bill-level row (returned bills pehle hi bahar).
class BillRow {
  final int? partyId; // sales.customerId / purchases.supplierId
  final int createdAt;
  final double total;
  const BillRow(this.partyId, this.createdAt, this.total);
}

/// Item-level row: ek line ki qty * rate.
class ItemLine {
  final int? partyId;
  final int createdAt;
  final double qty;
  final double rate;
  const ItemLine(this.partyId, this.createdAt, this.qty, this.rate);
  double get amount => qty * rate;
}

/// Kotlin applyFiltersAndRender: party + item filters ke baad sale/purchase entries.
///  * item filter ho => item lines (qty*rate), warna poore bill totals.
///  * customer chuna => sirf us ke sales, purchase side khali; supplier chuna => ulta.
///
/// Farq (Kotlin se): party ko *id* se milata hai (Kotlin naam se — same naam ke do parties mil jate the),
/// aur item lines mein returned bills shamil nahi (Kotlin ke item queries status nahi dekhte the).
({List<AmountEntry> sales, List<AmountEntry> purchases}) selectEntries({
  required List<BillRow> allSales,
  required List<BillRow> allPurchases,
  List<ItemLine>? itemSales, // null => item filter nahi
  List<ItemLine>? itemPurchases,
  PartyOption? party,
}) {
  List<AmountEntry> side<T>(List<T> rows, bool applies, int? Function(T) partyOf, int Function(T) at, double Function(T) amt) {
    if (!applies) return const [];
    return [
      for (final r in rows)
        if (party == null || partyOf(r) == party.id) AmountEntry(at(r), amt(r))
    ];
  }

  final saleApplies = party == null || party.isCustomer;
  final purchaseApplies = party == null || !party.isCustomer;

  final sales = itemSales != null
      ? side<ItemLine>(itemSales, saleApplies, (r) => r.partyId, (r) => r.createdAt, (r) => r.amount)
      : side<BillRow>(allSales, saleApplies, (r) => r.partyId, (r) => r.createdAt, (r) => r.total);
  final purchases = itemPurchases != null
      ? side<ItemLine>(itemPurchases, purchaseApplies, (r) => r.partyId, (r) => r.createdAt, (r) => r.amount)
      : side<BillRow>(allPurchases, purchaseApplies, (r) => r.partyId, (r) => r.createdAt, (r) => r.total);
  return (sales: sales, purchases: purchases);
}

double sumAmounts(Iterable<AmountEntry> e) => e.fold(0.0, (a, b) => a + b.amount);

/// Mahine ya saal ke hisaab se group; naya pehle (key ke hisaab se ulta sort).
List<PeriodTotals> groupPeriods(
  List<AmountEntry> sales,
  List<AmountEntry> purchases,
  GroupMode mode, {
  String Function(DateTime firstOfMonth)? monthLabel,
}) {
  final keyFmt = DateFormat(mode == GroupMode.month ? 'yyyy-MM' : 'yyyy');
  final labelFmt = DateFormat('MMMM yyyy');
  String keyOf(AmountEntry e) => keyFmt.format(DateTime.fromMillisecondsSinceEpoch(e.createdAt));

  final saleBy = <String, double>{};
  final purBy = <String, double>{};
  for (final e in sales) {
    saleBy.update(keyOf(e), (v) => v + e.amount, ifAbsent: () => e.amount);
  }
  for (final e in purchases) {
    purBy.update(keyOf(e), (v) => v + e.amount, ifAbsent: () => e.amount);
  }
  final keys = {...saleBy.keys, ...purBy.keys}.toList()..sort((a, b) => b.compareTo(a));

  String label(String key) {
    if (mode == GroupMode.year) return key;
    final y = int.parse(key.substring(0, 4));
    final m = int.parse(key.substring(5, 7));
    final d = DateTime(y, m, 1);
    return (monthLabel ?? labelFmt.format)(d);
  }

  return [
    for (final k in keys)
      PeriodTotals(key: k, label: label(k), sale: saleBy[k] ?? 0.0, purchase: purBy[k] ?? 0.0)
  ];
}

/// Party / item suggestions (Kotlin: naam `contains`, max 6). Item par matchesQuery (name + searchTag),
/// PORTING_PLAN rule — Kotlin yahan sirf naam dekhta tha.
List<PartyOption> suggestParties(List<PartyOption> all, String query, {int limit = 6}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return all.where((p) => p.name.toLowerCase().contains(q)).take(limit).toList();
}

List<Product> suggestProducts(List<Product> all, String query, {int limit = 6}) {
  if (query.trim().isEmpty) return const [];
  return all.where((p) => p.matchesQuery(query)).take(limit).toList();
}

class MonthlyBase {
  final List<BillRow> sales;
  final List<BillRow> purchases;
  final List<PartyOption> parties;
  final List<Product> products;
  const MonthlyBase(this.sales, this.purchases, this.parties, this.products);
}

class ItemRecords {
  final List<ItemLine> sales;
  final List<ItemLine> purchases;
  const ItemRecords(this.sales, this.purchases);
}

class MonthlyRepository {
  MonthlyRepository._();
  static final MonthlyRepository instance = MonthlyRepository._();

  void _guard() {
    if (!Session.isAdminOrManager) {
      throw StateError('Sirf Admin/Manager is screen ko access kar sakta hai');
    }
  }

  Future<MonthlyBase> load() async {
    _guard();
    final db = await AppDatabase.instance.database;
    final sales = await db.rawQuery("SELECT customerId, createdAt, total FROM sales WHERE status != 'returned'");
    final purchases = await db.rawQuery("SELECT supplierId, createdAt, total FROM purchases WHERE status != 'returned'");
    final customers = await db.rawQuery('SELECT id, name FROM customers');
    final suppliers = await db.rawQuery('SELECT id, name FROM suppliers');
    final products = (await db.query('products')).map(Product.fromMap).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final parties = <PartyOption>[
      for (final c in customers) PartyOption((c['id'] as num).toInt(), (c['name'] ?? '') as String, true),
      for (final s in suppliers) PartyOption((s['id'] as num).toInt(), (s['name'] ?? '') as String, false),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return MonthlyBase(
      [for (final r in sales) BillRow((r['customerId'] as num?)?.toInt(), (r['createdAt'] as num).toInt(), (r['total'] as num).toDouble())],
      [for (final r in purchases) BillRow((r['supplierId'] as num?)?.toInt(), (r['createdAt'] as num).toInt(), (r['total'] as num).toDouble())],
      parties,
      products,
    );
  }

  /// Ek item ki sale / purchase lines (Kotlin saleRecordsForItem / purchaseRecordsForItem).
  Future<ItemRecords> itemRecords(String barcode) async {
    _guard();
    final db = await AppDatabase.instance.database;
    final s = await db.rawQuery(
        'SELECT s.customerId AS partyId, s.createdAt AS createdAt, si.qty AS qty, si.unitPrice AS rate '
        'FROM sale_items si JOIN sales s ON si.invoice = s.invoice '
        "WHERE si.barcode = ? AND s.status != 'returned'",
        [barcode]);
    final p = await db.rawQuery(
        'SELECT pu.supplierId AS partyId, pu.createdAt AS createdAt, pi.qty AS qty, pi.unitCost AS rate '
        'FROM purchase_items pi JOIN purchases pu ON pi.billNo = pu.billNo '
        "WHERE pi.barcode = ? AND pu.status != 'returned'",
        [barcode]);
    ItemLine line(Map<String, Object?> r) => ItemLine((r['partyId'] as num?)?.toInt(), (r['createdAt'] as num).toInt(),
        (r['qty'] as num).toDouble(), (r['rate'] as num).toDouble());
    return ItemRecords([for (final r in s) line(r)], [for (final r in p) line(r)]);
  }
}
