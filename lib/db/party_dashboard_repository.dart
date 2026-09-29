import 'dart:math' as math;

import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'due_reminders_repository.dart';
import 'party_repository.dart';
import 'product_repository.dart';
import 'supplier_repository.dart';

/// Ports the data side of PartyDashboardActivity.kt (loadParties / renderTransactionsList /
/// renderItemsList / showEditRatesDialog). UI: lib/screens/party_dashboard_screen.dart.
///
/// Maths / filtering PURE functions mein hai ([partyTotals], [filterPartyRows], [filterTxRows],
/// [filterItemAggs] ...) taake test ho sake — see test/party_dashboard_test.dart.
///
/// Rules (PORTING_PLAN §1):
///  * Party ka closing HAMESHA live ledger se ([PartyRepository.liveCustomerBalances]) — stored
///    `balance` field se nahi (Kotlin "PERMANENT FIX balance drift").
///  * Cashier ke liye cost / purchase data load hi nahi hota (data layer par check).
///  * Rates edit sirf admin (Kotlin mein koi check nahi tha; PORTING_PLAN: Products admin-only).
///
/// Farq (Kotlin se):
///  * `dueStatus` (Overdue / Due Today badge, sirf customers) ab hai: DB v10 `sales.dueDate` +
///    [DueRemindersRepository.customerDueStatus].
///  * Transaction item-name search ka key `S:<invoice>` / `P:<billNo>` hai (Kotlin sirf reference
///    istemal karta tha, jo invoice aur billNo ke ek jaisay hone par takra sakta tha).

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

enum PartyFilter { all, customers, suppliers, receivable, payable }

/// Kotlin `PartyItem` — customer + supplier ek list mein.
class PartyRow {
  final int id;
  final String name;
  final String phone;

  /// opening + live running (+ stuck, sirf customer). Customer > 0 => wo dukaan ko dega.
  final double closing;
  final bool isCustomer;

  /// closing ka wo hissa jo "stuck" hai (0.0 supplier aur zyadatar customers ke liye).
  final double stuck;

  /// sales / purchases / payments mein sab se naya createdAt; null => abhi koi len-den nahi.
  final int? lastActivityAt;

  /// Customer par aaj/purani due date wali sale baqi ho to badge (sirf customers; Kotlin DueStatus).
  final PartyDueStatus? dueStatus;

  const PartyRow({
    required this.id,
    required this.name,
    required this.phone,
    required this.closing,
    required this.isCustomer,
    this.stuck = 0.0,
    this.lastActivityAt,
    this.dueStatus,
  });

  bool get isSettled => closing.abs() < 0.005;

  /// true => dukaan ne is party ko dena hai (\"You'll Give\").
  bool get isGive => partyIsGive(isCustomer: isCustomer, closing: closing);
}

/// Kotlin updateSummaryTotals(): customer aur supplier ka sign rule ULTA hai, is liye alag alag.
///  * Customer closing > 0 => You'll Get,  < 0 => You'll Give
///  * Supplier closing > 0 => You'll Give, < 0 => You'll Get
({double toGet, double toGive}) partyTotals(Iterable<PartyRow> rows) {
  var toGet = 0.0;
  var toGive = 0.0;
  for (final r in rows) {
    if (r.isCustomer) {
      toGet += math.max(r.closing, 0.0);
      toGive += math.max(-r.closing, 0.0);
    } else {
      toGet += math.max(-r.closing, 0.0);
      toGive += math.max(r.closing, 0.0);
    }
  }
  return (toGet: toGet, toGive: toGive);
}

/// Kotlin: naye len-den wali party sab se upar; jis ka koi len-den nahi wo naam ke hisaab se neeche.
List<PartyRow> sortPartyRows(Iterable<PartyRow> rows) {
  final list = rows.toList();
  list.sort((a, b) {
    final byActivity = (b.lastActivityAt ?? -1).compareTo(a.lastActivityAt ?? -1);
    if (byActivity != 0) return byActivity;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}

bool partyPassesFilter(PartyRow r, PartyFilter f) {
  switch (f) {
    case PartyFilter.all:
      return true;
    case PartyFilter.customers:
      return r.isCustomer;
    case PartyFilter.suppliers:
      return !r.isCustomer;
    // Settled (Rs 0) party na receivable hai na payable.
    case PartyFilter.receivable:
      return !r.isSettled && !r.isGive;
    case PartyFilter.payable:
      return !r.isSettled && r.isGive;
  }
}

/// Filter + naam ki search (Kotlin: sirf naam, case-insensitive substring).
List<PartyRow> filterPartyRows(List<PartyRow> rows, PartyFilter filter, String query) {
  final q = query.trim().toLowerCase();
  return rows.where((r) => partyPassesFilter(r, filter) && r.name.toLowerCase().contains(q)).toList();
}

/// Kotlin `TxRow` — sale ya purchase ki ek line.
class TxRow {
  final String reference; // invoice (sale) ya billNo (purchase)
  final String partyName;
  final double amount;
  final int createdAt;
  final bool isSale;
  final String status;

  const TxRow({
    required this.reference,
    required this.partyName,
    required this.amount,
    required this.createdAt,
    required this.isSale,
    required this.status,
  });

  String get key => '${isSale ? 'S' : 'P'}:$reference';
  bool get isReturned => status == 'returned';
}

/// Transactions ki search: har lafz party ke naam YA us bill ke kisi item (name + searchTag)
/// mein hona chahiye (Kotlin renderTxRows). [itemNamesByKey] ki keys [TxRow.key] hain.
List<TxRow> filterTxRows(List<TxRow> rows, String query, Map<String, List<String>> itemNamesByKey) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (terms.isEmpty) return rows;
  return rows.where((row) {
    final haystack = '${row.partyName} ${(itemNamesByKey[row.key] ?? const <String>[]).join(' ')}'.toLowerCase();
    return terms.every(haystack.contains);
  }).toList();
}

/// Kotlin `ItemAgg` — product + uski ab tak ki bikri / khareed.
class ItemAgg {
  final Product product;
  final int soldQty;
  final double soldAmt;
  final int purQty;
  final double purAmt;

  const ItemAgg({
    required this.product,
    this.soldQty = 0,
    this.soldAmt = 0.0,
    this.purQty = 0,
    this.purAmt = 0.0,
  });
}

/// Items ki search: `Product.matchesQuery` (name + searchTag, har lafz).
List<ItemAgg> filterItemAggs(List<ItemAgg> rows, String query) =>
    rows.where((r) => r.product.matchesQuery(query)).toList();

/// Transactions tab ka data: rows + (bill -> item names) search index.
class DashboardTransactions {
  final List<TxRow> rows;
  final Map<String, List<String>> itemNamesByKey;
  const DashboardTransactions(this.rows, this.itemNamesByKey);
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

class PartyDashboardRepository {
  PartyDashboardRepository._();
  static final PartyDashboardRepository instance = PartyDashboardRepository._();

  void _mergeMax(Map<int, int> into, List<Map<String, Object?>> rows) {
    for (final r in rows) {
      final id = (r['partyId'] as num?)?.toInt();
      if (id == null) continue;
      final at = (r['lastAt'] as num?)?.toInt() ?? 0;
      final cur = into[id];
      if (cur == null || at > cur) into[id] = at;
    }
  }

  /// Parties tab + summary cards. Customer aur supplier ki id-spaces alag hain, is liye
  /// last-activity ke maps bhi alag rakhe gaye hain.
  Future<List<PartyRow>> loadParties() async {
    final db = await AppDatabase.instance.database;
    final customers = await CustomerRepository.instance.listAll();
    final suppliers = await SupplierRepository.instance.listAll();
    final liveCustomer = await PartyRepository.instance.liveCustomerBalances();
    final liveSupplier = await PartyRepository.instance.liveSupplierBalances();

    final dueByCustomer = await DueRemindersRepository.instance.customerDueStatus();

    final customerLastAt = <int, int>{};
    _mergeMax(
        customerLastAt,
        await db.rawQuery(
            'SELECT customerId AS partyId, MAX(createdAt) AS lastAt FROM sales WHERE customerId IS NOT NULL GROUP BY customerId'));
    _mergeMax(
        customerLastAt,
        await db.rawQuery(
            "SELECT partyId AS partyId, MAX(createdAt) AS lastAt FROM payments WHERE partyType = 'customer' AND partyId IS NOT NULL GROUP BY partyId"));

    final supplierLastAt = <int, int>{};
    _mergeMax(
        supplierLastAt,
        await db.rawQuery(
            'SELECT supplierId AS partyId, MAX(createdAt) AS lastAt FROM purchases WHERE supplierId IS NOT NULL GROUP BY supplierId'));
    _mergeMax(
        supplierLastAt,
        await db.rawQuery(
            "SELECT partyId AS partyId, MAX(createdAt) AS lastAt FROM payments WHERE partyType = 'supplier' AND partyId IS NOT NULL GROUP BY partyId"));

    final rows = <PartyRow>[
      for (final c in customers)
        PartyRow(
          id: c.id!,
          name: c.name,
          phone: c.phone,
          closing: partyClosing(opening: c.openingBalance, running: liveCustomer[c.id] ?? 0.0, stuck: c.stuckBalance),
          isCustomer: true,
          stuck: c.stuckBalance,
          lastActivityAt: customerLastAt[c.id],
          dueStatus: dueByCustomer[c.id],
        ),
      for (final s in suppliers)
        PartyRow(
          id: s.id!,
          name: s.name,
          phone: s.phone,
          closing: partyClosing(opening: s.openingBalance, running: liveSupplier[s.id] ?? 0.0),
          isCustomer: false,
          lastActivityAt: supplierLastAt[s.id],
        ),
    ];
    return sortPartyRows(rows);
  }

  /// Transactions tab: sales + purchases ek date-sorted feed. Koi cap nahi (Kotlin FIX:
  /// purane bill 100 ki hadd se ghayab ho jate the) — search se list chhoti karein.
  Future<DashboardTransactions> loadTransactions() async {
    final db = await AppDatabase.instance.database;

    final saleRows = await db.rawQuery('''
      SELECT s.invoice AS ref, COALESCE(c.name, 'Walk-in') AS partyName, s.total AS total,
             s.createdAt AS createdAt, s.status AS status
      FROM sales s LEFT JOIN customers c ON c.id = s.customerId
    ''');
    final purchaseRows = await db.rawQuery('''
      SELECT p.billNo AS ref, COALESCE(su.name, 'Cash Purchase') AS partyName, p.total AS total,
             p.createdAt AS createdAt, p.status AS status
      FROM purchases p LEFT JOIN suppliers su ON su.id = p.supplierId
    ''');

    TxRow toRow(Map<String, Object?> m, bool isSale) => TxRow(
          reference: m['ref'] as String,
          partyName: (m['partyName'] as String?) ?? '',
          amount: (m['total'] as num).toDouble(),
          createdAt: (m['createdAt'] as num).toInt(),
          isSale: isSale,
          status: (m['status'] as String?) ?? 'active',
        );

    final merged = <TxRow>[
      for (final m in saleRows) toRow(m, true),
      for (final m in purchaseRows) toRow(m, false),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // Item-name search index: name + live product ka searchTag (English alias bhi match ho).
    final saleItemNames = await db.rawQuery('''
      SELECT si.invoice AS ref,
             (si.product || ' ' || COALESCE((SELECT searchTag FROM products WHERE products.barcode = si.barcode), '')) AS itemName
      FROM sale_items si
    ''');
    final purchaseItemNames = await db.rawQuery('''
      SELECT pi.billNo AS ref,
             (COALESCE((SELECT name FROM products WHERE products.barcode = pi.barcode), '') || ' ' ||
              COALESCE((SELECT searchTag FROM products WHERE products.barcode = pi.barcode), '')) AS itemName
      FROM purchase_items pi
    ''');
    final index = <String, List<String>>{};
    for (final m in saleItemNames) {
      (index['S:${m['ref']}'] ??= []).add((m['itemName'] as String?) ?? '');
    }
    for (final m in purchaseItemNames) {
      (index['P:${m['ref']}'] ??= []).add((m['itemName'] as String?) ?? '');
    }
    return DashboardTransactions(merged, index);
  }

  /// Items tab: har product + ab tak ki bikri / khareed (returned bills shamil nahi).
  /// Cashier: cost aur purchase totals load hi nahi hote (PORTING_PLAN role rule).
  Future<List<ItemAgg>> loadItems() async {
    final db = await AppDatabase.instance.database;
    final canSeeCost = Session.isAdminOrManager;
    final products = await ProductRepository.instance.listAll();

    final sold = await db.rawQuery('''
      SELECT si.product AS product, COALESCE(SUM(si.amount), 0) AS totalAmount, COALESCE(SUM(si.qty), 0) AS totalQty
      FROM sale_items si JOIN sales s ON si.invoice = s.invoice
      WHERE s.status != 'returned'
      GROUP BY si.product
    ''');
    final soldMap = {for (final m in sold) m['product'] as String: m};

    final purMap = <String, Map<String, Object?>>{};
    if (canSeeCost) {
      final purchased = await db.rawQuery('''
        SELECT p.name AS product, COALESCE(SUM(pi.amount), 0) AS totalAmount, COALESCE(SUM(pi.qty), 0) AS totalQty
        FROM purchase_items pi
        JOIN purchases pu ON pi.billNo = pu.billNo
        JOIN products p ON pi.barcode = p.barcode
        WHERE pu.status != 'returned'
        GROUP BY p.name
      ''');
      for (final m in purchased) {
        purMap[m['product'] as String] = m;
      }
    }

    final rows = [
      for (final p in products)
        ItemAgg(
          product: canSeeCost ? p : p.copyWith(cost: 0.0),
          soldQty: ((soldMap[p.name]?['totalQty'] as num?) ?? 0).toInt(),
          soldAmt: ((soldMap[p.name]?['totalAmount'] as num?) ?? 0).toDouble(),
          purQty: ((purMap[p.name]?['totalQty'] as num?) ?? 0).toInt(),
          purAmt: ((purMap[p.name]?['totalAmount'] as num?) ?? 0).toDouble(),
        ),
    ]..sort((a, b) => a.product.name.toLowerCase().compareTo(b.product.name.toLowerCase()));
    return rows;
  }

  /// Kotlin showEditRatesDialog() ka save: 3 rate (PRIMARY unit par) + sync_queue, ek transaction mein.
  Future<void> saveRates(
    String barcode, {
    required double cost,
    required double salePrice,
    required double wholesalePrice,
  }) async {
    if (!Session.isAdmin) throw StateError('Only Admin can edit rates');
    if (cost < 0 || salePrice < 0 || wholesalePrice < 0) throw ArgumentError('Rates cannot be negative');
    await ProductRepository.instance
        .setAllRates(barcode, cost: cost, salePrice: salePrice, wholesalePrice: wholesalePrice);
  }
}
