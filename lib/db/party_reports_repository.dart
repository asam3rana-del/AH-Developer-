import 'party_repository.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'supplier_repository.dart';
import '../models/party.dart';
import '../services/session.dart';

/// Ports the data side of PartyReportsActivity.kt (6 reports: Item, Ledger, Payment History,
/// Statement, Sale/Purchase by Party, Profit&Loss / Purchase Summary).
/// UI: lib/screens/party_reports_screen.dart. Test: test/party_reports_test.dart.
///
/// Maths PURE functions mein hai ([buildLedgerLines], [runLedger], [aggregateItems],
/// [customerPL], [supplierSummary] ...) taake bina DB ke test ho sake.
///
/// Rules (Kotlin FIX comments se):
///  * Returned bills (`status == 'returned'`) SAB reports se bahar — warna returned credit sale
///    party ke Ledger/Statement/Item/P&L mein hamesha ginti rehti hai.
///  * Bill-linked payments Ledger/Statement mein dobara nahi ginte (wo bill ke `paid` mein pehle
///    se hain): sirf wo payments jin ka `billReference` khali ho AUR `reference` party ke apne
///    bills (returned samet) mein se koi na ho.
///  * Closing HAMESHA live ledger se ([PartyRepository.liveCustomerBalances]).
///  * Cost / profit sirf admin/manager — screen RoleGuard ke andar hai (PORTING_PLAN §1).

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Ek bill (sale ya purchase) — reports ko sirf itna chahiye.
class ReportBill {
  final String id; // invoice / billNo
  final double total;
  final double paid;
  final int createdAt;
  final String status;
  const ReportBill({
    required this.id,
    required this.total,
    required this.paid,
    required this.createdAt,
    this.status = 'completed',
  });
  bool get isReturned => status == 'returned';
}

class ReportPayment {
  final String reference;
  final String billReference;
  final double amount;
  final int createdAt;
  const ReportPayment({
    required this.reference,
    this.billReference = '',
    required this.amount,
    required this.createdAt,
  });
}

/// Ledger/Statement ki ek line: Debit (bill total) / Credit (us waqt ada) / delta (balance par asar).
class LedgerLine {
  final int time;
  final double dr;
  final double cr;
  final double delta;

  /// true => bill se alag general payment (Statement mein "Payment received/made" label).
  final bool isPayment;
  const LedgerLine(this.time, this.dr, this.cr, this.delta, {this.isPayment = false});
}

/// Kotlin showLedger()/showStatement() ki merge: non-returned bills + general payments, waqt ke hisaab se.
/// Sort STABLE hai (barabar waqt par bills pehle, phir payments — Kotlin sortBy jaisa).
List<LedgerLine> buildLedgerLines({
  required List<ReportBill> bills,
  required List<ReportPayment> payments,
}) {
  final ownBillIds = {for (final b in bills) b.id}; // returned samet
  final lines = <LedgerLine>[
    for (final b in bills)
      if (!b.isReturned) LedgerLine(b.createdAt, b.total, b.paid, b.total - b.paid),
    for (final p in payments)
      if (p.billReference.isEmpty && !ownBillIds.contains(p.reference))
        LedgerLine(p.createdAt, 0.0, p.amount, -p.amount, isPayment: true),
  ];
  // Dart ka List.sort stable nahi hota — index se stable bana rahe hain.
  final indexed = [for (var i = 0; i < lines.length; i++) (i, lines[i])];
  indexed.sort((a, b) {
    final c = a.$2.time.compareTo(b.$2.time);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

class RunningLine {
  final LedgerLine line;
  final double balance;
  const RunningLine(this.line, this.balance);
}

/// opening se shuru karke har line ke baad running balance.
({List<RunningLine> rows, double closing}) runLedger(double opening, List<LedgerLine> lines) {
  var running = opening;
  final rows = <RunningLine>[];
  for (final l in lines) {
    running += l.delta;
    rows.add(RunningLine(l, running));
  }
  return (rows: rows, closing: running);
}

/// Kotlin: customer closing < 0 => dukaan ko dena hai ("give"); supplier closing > 0 => dena hai.
/// (Ledger sirf `running > 0` par red karta tha; Statement isGive rule istemal karta hai.)
bool reportIsGive({required bool isCustomer, required double closing}) =>
    partyIsGive(isCustomer: isCustomer, closing: closing);

class ItemAgg {
  final String product;
  final double qty;
  final double amount;
  const ItemAgg(this.product, this.qty, this.amount);
}

/// Kotlin showItemReport(): naam ke hisaab se qty + amount jama, amount ghatte hue.
/// Sort stable — barabar amount par pehle aane wala pehle (LinkedHashMap order).
List<ItemAgg> aggregateItems(Iterable<({String name, double qty, double amount})> rows) {
  final map = <String, ItemAgg>{};
  for (final r in rows) {
    final ex = map[r.name];
    map[r.name] = ex == null ? ItemAgg(r.name, r.qty, r.amount) : ItemAgg(r.name, ex.qty + r.qty, ex.amount + r.amount);
  }
  final list = map.values.toList();
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = b.$2.amount.compareTo(a.$2.amount);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

class PaymentEntry {
  final int date;
  final double amount;
  final bool isSale; // true => "Against Sale", false => "Against Purchase"
  const PaymentEntry(this.date, this.amount, this.isSale);
}

/// Kotlin showPaymentHistory(): har non-returned bill ka `paid > 0` ek entry; nayi pehle.
List<PaymentEntry> paymentEntries(List<ReportBill> bills, {required bool isCustomer}) {
  final list = [
    for (final b in bills)
      if (!b.isReturned && b.paid > 0) PaymentEntry(b.createdAt, b.paid, isCustomer),
  ];
  list.sort((a, b) => b.date.compareTo(a.date));
  return list;
}

/// Customer ka Profit & Loss (revenue − cost). `bills` = non-returned bills ki ginti.
class CustomerPL {
  final int bills;
  final double revenue;
  final double cost;
  const CustomerPL(this.bills, this.revenue, this.cost);
  double get profit => revenue - cost;
}

CustomerPL customerPL({required int bills, required Iterable<({double amount, double cost})> items}) {
  var revenue = 0.0;
  var cost = 0.0;
  for (final i in items) {
    revenue += i.amount;
    cost += i.cost;
  }
  return CustomerPL(bills, revenue, cost);
}

/// Supplier ka "Purchase Summary" (supplier ka koi profit nahi hota).
class SupplierSummary {
  final int bills;
  final double purchased;
  final double paid;
  const SupplierSummary(this.bills, this.purchased, this.paid);
  double get due => purchased - paid;
}

SupplierSummary supplierSummary(List<ReportBill> bills) {
  final live = bills.where((b) => !b.isReturned).toList();
  return SupplierSummary(
    live.length,
    live.fold<double>(0, (a, b) => a + b.total),
    live.fold<double>(0, (a, b) => a + b.paid),
  );
}

/// Party list ki ek row (Kotlin partyRow).
class ReportPartyRow {
  final int id;
  final String name;
  final double opening;
  final double stuck;
  final double closing;
  final bool isCustomer;
  const ReportPartyRow({
    required this.id,
    required this.name,
    required this.opening,
    required this.stuck,
    required this.closing,
    required this.isCustomer,
  });
  bool get isGive => reportIsGive(isCustomer: isCustomer, closing: closing);
}

// ---------------------------------------------------------------------------
// DB loaders
// ---------------------------------------------------------------------------

/// Party Reports sirf admin/manager (screen RoleGuard + data layer).
void _requireReportsRole() {
  if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can view party reports');
}

class PartyReportsRepository {
  PartyReportsRepository._();
  static final PartyReportsRepository instance = PartyReportsRepository._();

  /// Kotlin loadParties(): closing = opening + live running (+ stuck, sirf customer).
  Future<List<ReportPartyRow>> loadParties({required bool customers}) async {
    _requireReportsRole();
    if (customers) {
      final list = await CustomerRepository.instance.listAll();
      final live = await PartyRepository.instance.liveCustomerBalances();
      return [
        for (final Customer c in list)
          ReportPartyRow(
            id: c.id!,
            name: c.name,
            opening: c.openingBalance,
            stuck: c.stuckBalance,
            closing: partyClosing(opening: c.openingBalance, running: live[c.id] ?? 0.0, stuck: c.stuckBalance),
            isCustomer: true,
          ),
      ];
    }
    final list = await SupplierRepository.instance.listAll();
    final live = await PartyRepository.instance.liveSupplierBalances();
    return [
      for (final Supplier s in list)
        ReportPartyRow(
          id: s.id!,
          name: s.name,
          opening: s.openingBalance,
          stuck: 0.0,
          closing: partyClosing(opening: s.openingBalance, running: live[s.id] ?? 0.0),
          isCustomer: false,
        ),
    ];
  }

  /// Party ke SAARE bills (returned samet — filter pure helpers karte hain), nayi pehle.
  Future<List<ReportBill>> bills({required bool isCustomer, required int id}) async {
    _requireReportsRole();
    if (isCustomer) {
      final sales = await PartyRepository.instance.salesByCustomer(id);
      return [
        for (final s in sales)
          ReportBill(id: s.invoice, total: s.total, paid: s.paid, createdAt: s.createdAt, status: s.status),
      ];
    }
    final purchases = await PartyRepository.instance.purchasesBySupplier(id);
    return [
      for (final p in purchases)
        ReportBill(id: p.billNo, total: p.total, paid: p.paid, createdAt: p.createdAt, status: p.status),
    ];
  }

  Future<List<ReportPayment>> payments({required bool isCustomer, required int id}) async {
    _requireReportsRole();
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'payments',
      where: 'partyType = ? AND partyId = ?',
      whereArgs: [isCustomer ? 'customer' : 'supplier', id],
      orderBy: 'createdAt ASC',
    );
    return [
      for (final m in rows)
        ReportPayment(
          reference: (m['reference'] as String?) ?? '',
          billReference: (m['billReference'] as String?) ?? '',
          amount: (m['amount'] as num?)?.toDouble() ?? 0.0,
          createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// Ledger + Statement dono ke liye lines.
  Future<List<LedgerLine>> ledgerLines({required bool isCustomer, required int id}) async {
    _requireReportsRole();
    final b = await bills(isCustomer: isCustomer, id: id);
    final p = await payments(isCustomer: isCustomer, id: id);
    return buildLedgerLines(bills: b, payments: p);
  }

  /// Party Report by Item (returned bills ke item nahi).
  Future<List<ItemAgg>> itemReport({required bool isCustomer, required int id}) async {
    _requireReportsRole();
    final db = await AppDatabase.instance.database;
    final rows = isCustomer
        ? await db.rawQuery('''
            SELECT si.product AS name, si.qty AS qty, si.amount AS amount
            FROM sale_items si JOIN sales s ON s.invoice = si.invoice
            WHERE s.customerId = ? AND s.status != 'returned'
            ORDER BY s.createdAt DESC, si.id ASC
          ''', [id])
        // Kotlin: purchase item ka naam pehle row par snapshot; Flutter model mein snapshot nahi,
        // is liye live product naam, warna barcode.
        : await db.rawQuery('''
            SELECT COALESCE(NULLIF((SELECT name FROM products WHERE products.barcode = pi.barcode), ''), pi.barcode) AS name,
                   pi.qty AS qty, pi.amount AS amount
            FROM purchase_items pi JOIN purchases p ON p.billNo = pi.billNo
            WHERE p.supplierId = ? AND p.status != 'returned'
            ORDER BY p.createdAt DESC, pi.id ASC
          ''', [id]);
    return aggregateItems([
      for (final m in rows)
        (
          name: (m['name'] as String?) ?? '',
          qty: (m['qty'] as num?)?.toDouble() ?? 0.0,
          amount: (m['amount'] as num?)?.toDouble() ?? 0.0,
        ),
    ]);
  }

  /// Customer P&L. Cost data hai — sirf admin/manager ke liye (screen guard + yahan bhi check).
  Future<CustomerPL> customerProfit(int customerId, {required bool allowCost}) async {
    if (!allowCost) throw StateError('Cost data sirf admin/manager ke liye hai');
    final db = await AppDatabase.instance.database;
    final billCount = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sales WHERE customerId = ? AND status != 'returned'",
      [customerId],
    );
    final rows = await db.rawQuery('''
      SELECT si.amount AS amount, si.cost AS cost
      FROM sale_items si JOIN sales s ON s.invoice = si.invoice
      WHERE s.customerId = ? AND s.status != 'returned'
    ''', [customerId]);
    return customerPL(
      bills: (billCount.first['c'] as num?)?.toInt() ?? 0,
      items: [
        for (final m in rows)
          (amount: (m['amount'] as num?)?.toDouble() ?? 0.0, cost: (m['cost'] as num?)?.toDouble() ?? 0.0),
      ],
    );
  }
}
