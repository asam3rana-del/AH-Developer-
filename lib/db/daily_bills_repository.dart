import 'app_database.dart';
import 'customer_repository.dart';
import 'party_reports_repository.dart';
import 'rent_repository.dart';
import '../services/session.dart';

/// "Aaj ke Bills" (Daily Bill): ek din ki saari alag alag sales ek customer ke ek bill ki tarah,
/// saath mein us din ka pichla balance aur din ke baad ka balance.
///
/// Maths PURE functions mein hai ([buildDailyParty], [dailyBillText]) taake bina DB ke test ho sake.
/// Balance ka rule: opening + bills (total - paid) - bill se alag payments. Returned bills shamil nahi.
/// Stuck balance Daily Bill mein NAHI dikhta / count hota (Party Reports / Statement mein wahi rehta hai).

class DayBillItem {
  final String product;
  final double qty;
  final String unit;
  final double unitPrice;
  final double amount;
  const DayBillItem({
    required this.product,
    required this.qty,
    required this.unit,
    required this.unitPrice,
    required this.amount,
  });
}

class DayBill {
  final String invoice;
  final int time;
  final double total;
  final double paid;
  final List<DayBillItem> items;
  const DayBill({
    required this.invoice,
    required this.time,
    required this.total,
    required this.paid,
    this.items = const [],
  });
  double get due => total - paid;
}

class DayPayment {
  final int time;
  final double amount;
  const DayPayment(this.time, this.amount);
}

/// Ek customer ka ek din ka hisaab.
class DailyParty {
  final int id;
  final String name;

  /// Din shuru hone se pehle ka balance (opening + pichli sales - pichli payments). Stuck shamil nahi.
  final double previousBalance;
  final List<DayBill> bills;

  /// Us din bill se alag mili hui payments ("Payment received").
  final List<DayPayment> payments;

  /// Din ke baad ka balance.
  final double closingBalance;

  const DailyParty({
    required this.id,
    required this.name,
    required this.previousBalance,
    required this.bills,
    required this.payments,
    required this.closingBalance,
  });

  double get salesTotal => bills.fold<double>(0, (a, b) => a + b.total);
  double get billPaid => bills.fold<double>(0, (a, b) => a + b.paid);
  double get paymentsTotal => payments.fold<double>(0, (a, p) => a + p.amount);

  /// Aaj kul mila: bill ke saath diya + alag payment.
  double get receivedTotal => billPaid + paymentsTotal;
  int get billCount => bills.length;
}

/// Din ke hisaab se customer ka daily hisaab. [dayStart] <= time < [dayEnd] us din ki lines hain.
/// Din mein koi bill/payment na ho to null.
DailyParty? buildDailyParty({
  required int id,
  required String name,
  required double opening,
  required List<ReportBill> bills,
  required List<ReportPayment> payments,
  required int dayStart,
  required int dayEnd,
  Map<String, List<DayBillItem>> itemsByInvoice = const {},
}) {
  final lines = buildLedgerLines(bills: bills, payments: payments);
  var previous = opening;
  var closing = opening;
  final dayPayments = <DayPayment>[];
  for (final l in lines) {
    if (l.time < dayStart) {
      previous += l.delta;
      closing += l.delta;
    } else if (l.time < dayEnd) {
      closing += l.delta;
      if (l.isPayment) dayPayments.add(DayPayment(l.time, l.cr));
    }
  }
  final dayBills = <DayBill>[
    for (final b in bills)
      if (!b.isReturned && b.createdAt >= dayStart && b.createdAt < dayEnd)
        DayBill(
          invoice: b.id,
          time: b.createdAt,
          total: b.total,
          paid: b.paid,
          items: (itemsByInvoice[b.id] ?? const []).isNotEmpty
              ? itemsByInvoice[b.id]!
              : (isRentInvoice(b.id)
                  ? [DayBillItem(product: 'Daily Rent', qty: 1, unit: '', unitPrice: b.total, amount: b.total)]
                  : const []),
        ),
  ]..sort((a, b) => a.time.compareTo(b.time));
  if (dayBills.isEmpty && dayPayments.isEmpty) return null;
  return DailyParty(
    id: id,
    name: name,
    previousBalance: previous,
    bills: dayBills,
    payments: dayPayments,
    closingBalance: closing,
  );
}

String _n(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);

String _qty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

String _hm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Share / print ke liye saada text bill.
String dailyBillText(DailyParty p, DateTime day, {String shopName = ''}) {
  final sb = StringBuffer();
  if (shopName.trim().isNotEmpty) sb.writeln(shopName.trim());
  sb.writeln('Daily Bill - ${p.name}');
  sb.writeln('Date: ${day.day.toString().padLeft(2, '0')}-${day.month.toString().padLeft(2, '0')}-${day.year}');
  sb.writeln('--------------------------');
  sb.writeln('Previous balance: Rs ${_n(p.previousBalance)}');
  sb.writeln('--------------------------');
  for (final b in p.bills) {
    sb.writeln('${b.invoice}  (${_hm(b.time)})');
    for (final i in b.items) {
      sb.writeln('  ${i.product}  ${_qty(i.qty)}${i.unit.isEmpty ? '' : ' ${i.unit}'} x ${_n(i.unitPrice)} = ${_n(i.amount)}');
    }
    sb.writeln('  Bill total: ${_n(b.total)}${b.paid > 0 ? '   Paid: ${_n(b.paid)}' : ''}');
  }
  sb.writeln('--------------------------');
  sb.writeln('Today\'s sale: Rs ${_n(p.salesTotal)}');
  if (p.receivedTotal > 0) sb.writeln('Received today: Rs ${_n(p.receivedTotal)}');
  sb.writeln('Today\'s balance: Rs ${_n(p.closingBalance)}');
  return sb.toString();
}

class DailyBillsRepository {
  DailyBillsRepository._();
  static final DailyBillsRepository instance = DailyBillsRepository._();

  /// Us din (local) jin customers ki sale ya payment hui, un ka hisaab. Zyada sale wale pehle.
  Future<List<DailyParty>> loadDay(DateTime day) async {
    if (!Session.isAdminOrManager) throw StateError('Only Admin/Manager can view daily bills');
    // Daily Rent: aaj tak ke jo rent bills nahi bane wo ab ban jate hain (sirf rent wale customers ke liye).
    // Rent mein koi masla aaye to baaki Daily Bills phir bhi dikhen; masla screen par bataya jata hai.
    try {
      await RentRepository.instance.ensureRentUpTo(DateTime.now());
      RentRepository.lastError = null;
    } catch (e) {
      RentRepository.lastError = '$e';
    }
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final s = start.millisecondsSinceEpoch;
    final e = end.millisecondsSinceEpoch;
    final db = await AppDatabase.instance.database;

    final saleIds = await db.rawQuery(
      "SELECT DISTINCT customerId AS id FROM sales WHERE customerId IS NOT NULL AND status != 'returned' "
      'AND createdAt >= ? AND createdAt < ?',
      [s, e],
    );
    final payIds = await db.rawQuery(
      "SELECT DISTINCT partyId AS id FROM payments WHERE partyType = 'customer' AND createdAt >= ? AND createdAt < ?",
      [s, e],
    );
    final ids = <int>{
      for (final r in saleIds) if (r['id'] != null) (r['id'] as num).toInt(),
      for (final r in payIds) if (r['id'] != null) (r['id'] as num).toInt(),
    };
    if (ids.isEmpty) return const [];

    // Din ki sab sale items ek query mein.
    final itemRows = await db.rawQuery(
      'SELECT si.invoice AS invoice, si.product AS product, si.qty AS qty, si.unit AS unit, '
      'si.unitPrice AS unitPrice, si.amount AS amount FROM sale_items si JOIN sales s ON s.invoice = si.invoice '
      "WHERE s.createdAt >= ? AND s.createdAt < ? AND s.status != 'returned' ORDER BY si.id ASC",
      [s, e],
    );
    final itemsByInvoice = <String, List<DayBillItem>>{};
    for (final m in itemRows) {
      (itemsByInvoice[(m['invoice'] as String?) ?? ''] ??= []).add(DayBillItem(
        product: (m['product'] as String?) ?? '',
        qty: (m['qty'] as num?)?.toDouble() ?? 0.0,
        unit: (m['unit'] as String?) ?? '',
        unitPrice: (m['unitPrice'] as num?)?.toDouble() ?? 0.0,
        amount: (m['amount'] as num?)?.toDouble() ?? 0.0,
      ));
    }

    final customers = await CustomerRepository.instance.listAll();
    final out = <DailyParty>[];
    for (final c in customers) {
      if (c.id == null || !ids.contains(c.id)) continue;
      final bills = await PartyReportsRepository.instance.bills(isCustomer: true, id: c.id!);
      final pays = await PartyReportsRepository.instance.payments(isCustomer: true, id: c.id!);
      final p = buildDailyParty(
        id: c.id!,
        name: c.name,
        opening: c.openingBalance, // stuckBalance jaan kar shamil nahi
        bills: bills,
        payments: pays,
        dayStart: s,
        dayEnd: e,
        itemsByInvoice: itemsByInvoice,
      );
      if (p != null) out.add(p);
    }
    out.sort((a, b) => b.salesTotal.compareTo(a.salesTotal));
    return out;
  }
}
