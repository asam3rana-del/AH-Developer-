import 'package:intl/intl.dart';

import '../db/daily_bills_repository.dart' show DailyParty;
import 'bill_doc.dart';

/// Slip PDF ka saara data. Sab PURE (DB / UI / pdf library nahi) taake test ho sake; PDF khud
/// `services/slip_pdf_service.dart` banata hai. Ek hi model Daily Bill, Payment Received/Made,
/// Statement, Party Summary aur Purchase slip ke liye chalta hai.
///
/// Raqam hamesha pehle se likhe hue text mein (`Rs 1,234`) aate hain — PDF builder sirf chhapta hai.

/// "Label ........ value" ki ek line (meta ya totals).
class SlipKv {
  final String label;
  final String value;
  final bool bold;

  /// 0xAARRGGBB; null => aam gehra rang.
  final int? argb;
  const SlipKv(this.label, this.value, {this.bold = false, this.argb});
}

/// Slip ka ek hissa: optional heading, optional table, optional kv lines (totals).
class SlipBlock {
  final String? heading;
  final List<String> headers;
  final List<double> weights;
  final List<List<String>> rows;

  /// Is column se aage (inclusive) ke columns right align (raqam wale). Default: pehla column left, baaqi right.
  final int rightFrom;
  final List<SlipKv> lines;
  const SlipBlock({
    this.heading,
    this.headers = const [],
    this.weights = const [],
    this.rows = const [],
    this.rightFrom = 1,
    this.lines = const [],
  });

  bool get hasTable => headers.isNotEmpty && rows.isNotEmpty;
}

/// PDF ke neeche dhanyawad (Urdu). Shop ki apni `receipt_footer` set ho to wo chalti hai.
const String slipThanks = 'خریداری کا شکریہ';

/// PDF ke neeche payment ki maloomat (Urdu + number).
const String slipPayInfo = 'جاز کیش / راست: 03006296815';

class SlipPdfData {
  final String shopName;
  final String shopPhone;

  /// Teal patti mein bara title, jaise `DAILY BILL`.
  final String title;

  /// Title ke neeche party ka naam (khali ho to nahi dikhta).
  final String partyName;
  final List<SlipKv> meta;
  final List<SlipBlock> blocks;
  final String footer;
  const SlipPdfData({
    required this.title,
    this.shopName = '',
    this.shopPhone = '',
    this.partyName = '',
    this.meta = const [],
    this.blocks = const [],
    this.footer = slipThanks,
  });
}

/// `Rs 1,234` (rupay mein round). Minus ho to `-Rs 1,234`.
String slipMoney(double v) {
  final r = v.round();
  final s = NumberFormat('#,##0').format(r.abs());
  return r < 0 ? '-Rs $s' : 'Rs $s';
}

/// Rate: poora rupya ho to bina decimal, warna 2 decimal.
String slipRate(double v) => NumberFormat(v == v.roundToDouble() ? '#,##0' : '#,##0.00').format(v);

/// Miqdar: poori ho to bina decimal, warna zyada se zyada 3 decimal (aakhri zero hata kar).
String slipQty(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String slipDate(DateTime d) => DateFormat('dd/MM/yyyy').format(d);
String slipDateTime(DateTime d) => DateFormat('dd/MM/yyyy hh:mm a').format(d);
String _time(int ms) => DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(ms));

/// File ke naam ke liye: sirf harf/ankh/`-_` rakhta hai (Urdu naam bhi chalta hai), baaqi `_`.
String slipFileName(String base, DateTime when) {
  final clean = base.trim().replaceAll(RegExp(r'[^\w\u0600-\u06FF-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final safe = clean.isEmpty || clean == '_' ? 'Slip' : clean;
  return '${safe}_${DateFormat('yyyyMMdd_HHmm').format(when)}.pdf';
}

/// Customer ko dikhne wala saaf naam: `Qasir-Pan-Shop_Bill_05-11-2026.pdf` (waqt nahi, spaces `-`).
String slipCustomerFileName(String party, String kind, DateTime day) {
  final clean = party
      .trim()
      .replaceAll(RegExp(r'[^\w\u0600-\u06FF\s-]+'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  final who = clean.isEmpty || clean == '-' ? '' : '${clean}_';
  final k = kind.replaceAll(RegExp(r'[^\w-]+'), '-');
  return '$who${k}_${DateFormat('dd-MM-yyyy').format(day)}.pdf';
}

/// Slip ke title se saaf naam: `Qasir-Pan-Shop_Payment-Received_05-11-2026.pdf`. [ref] (bill number) ho to kind mein judta hai.
String slipAutoFileName(SlipPdfData d, {DateTime? day, String ref = ''}) {
  const kinds = {
    'DAILY BILL': 'Bill',
    'PAYMENT RECEIVED': 'Payment-Received',
    'PAYMENT MADE': 'Payment-Made',
    'CUSTOMER STATEMENT': 'Statement',
    'SUPPLIER STATEMENT': 'Statement',
    'PARTY SUMMARY': 'Summary',
    'SALE BILL': 'Sale-Bill',
    'PURCHASE BILL': 'Purchase-Bill',
  };
  var kind = kinds[d.title] ?? 'Slip';
  if (ref.trim().isNotEmpty) kind = '$kind-${ref.trim()}';
  return slipCustomerFileName(d.partyName, kind, day ?? DateTime.now());
}

// ---------------------------------------------------------------- Daily Bill

SlipPdfData dailyBillSlipData(DailyParty p, DateTime day, {String shopName = '', String shopPhone = ''}) {
  return SlipPdfData(
    title: 'DAILY BILL',
    shopName: shopName,
    shopPhone: shopPhone,
    partyName: p.name,
    meta: [
      SlipKv('Date', DateFormat('dd-MM-yyyy').format(day)),
      SlipKv('Previous balance', slipMoney(p.previousBalance), bold: true),
    ],
    blocks: [
      for (final b in p.bills)
        SlipBlock(
          heading: '${b.invoice}  (${_time(b.time)})',
          headers: const ['Item', 'Qty', 'Rate', 'Amount'],
          weights: const [3.2, 1.3, 1.1, 1.3],
          rows: [
            for (final i in b.items)
              [i.product, '${slipQty(i.qty)}${i.unit.isEmpty ? '' : ' ${i.unit}'}', slipRate(i.unitPrice), slipMoney(i.amount)],
          ],
          lines: [
            SlipKv('Bill total', slipMoney(b.total), bold: true),
            if (b.paid > 0) SlipKv('Paid', slipMoney(b.paid)),
          ],
        ),
      if (p.payments.isNotEmpty)
        SlipBlock(
          heading: 'Payments received',
          lines: [for (final pm in p.payments) SlipKv(_time(pm.time), slipMoney(pm.amount))],
        ),
      SlipBlock(lines: [
        SlipKv("Today's sale", slipMoney(p.salesTotal)),
        if (p.receivedTotal > 0) SlipKv('Received today', slipMoney(p.receivedTotal)),
        SlipKv("Today's balance", slipMoney(p.closingBalance), bold: true),
      ]),
    ],
  );
}

// ---------------------------------------------------------------- Payment slip

/// [balanceNow]: customer: +ve = customer ne dena hai; supplier: +ve = humne dena hai. null => nahi likha jata.
SlipPdfData paymentSlipData({
  required bool received,
  required String partyName,
  required double amount,
  required DateTime date,
  String shopName = '',
  String shopPhone = '',
  String method = '',
  String billRef = '',
  String note = '',
  String? slipNo,
  double? balanceNow,
}) {
  String? balanceLabel;
  if (balanceNow != null) {
    if (balanceNow.abs() < 0.5) {
      balanceLabel = 'Balance now';
    } else if (received) {
      balanceLabel = balanceNow > 0 ? 'Balance due' : 'Advance with us';
    } else {
      balanceLabel = balanceNow > 0 ? 'Balance payable' : 'Advance with you';
    }
  }
  return SlipPdfData(
    title: received ? 'PAYMENT RECEIVED' : 'PAYMENT MADE',
    shopName: shopName,
    shopPhone: shopPhone,
    partyName: partyName.trim().isEmpty ? '-' : partyName.trim(),
    meta: [
      if (slipNo != null && slipNo.isNotEmpty) SlipKv('Slip', slipNo),
      SlipKv(received ? 'Customer' : 'Supplier', partyName.trim().isEmpty ? '-' : partyName.trim()),
      SlipKv('Date', slipDateTime(date)),
      if (method.trim().isNotEmpty) SlipKv('Method', method.trim().toUpperCase()),
      if (billRef.trim().isNotEmpty) SlipKv('Against Bill', billRef.trim()),
      if (note.trim().isNotEmpty) SlipKv('Note', note.trim()),
    ],
    blocks: [
      SlipBlock(lines: [SlipKv('Amount', slipMoney(amount), bold: true)]),
      if (balanceNow != null && balanceLabel != null)
        SlipBlock(lines: [
          SlipKv(balanceLabel, slipMoney(balanceNow.abs() < 0.5 ? 0 : balanceNow.abs()), bold: true),
        ]),
    ],
  );
}

// ---------------------------------------------------------------- Statement

class SlipStatementEntry {
  /// 0 ya negative => tareekh nahi (khali dikhegi).
  final int createdAt;
  final String text;
  const SlipStatementEntry(this.createdAt, this.text);
}

/// Customer / Supplier statement. [youGive] = true => humne dena hai (Outstanding ke saath likha jata hai).
SlipPdfData statementSlipData({
  required bool isCustomer,
  required String partyName,
  required double closing,
  required bool youGive,
  required List<SlipStatementEntry> entries,
  String shopName = '',
  String shopPhone = '',
  String loanLabel = '',
  double loanOutstanding = 0,
  double daily = 0,
  double stuck = 0,
  DateTime? now,
}) {
  final sorted = [...entries]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return SlipPdfData(
    title: isCustomer ? 'CUSTOMER STATEMENT' : 'SUPPLIER STATEMENT',
    shopName: shopName,
    shopPhone: shopPhone,
    partyName: partyName,
    meta: [
      SlipKv('Date', slipDate(now ?? DateTime.now())),
      SlipKv('Outstanding', slipMoney(closing.abs()), bold: true),
      SlipKv('Status', youGive ? "You'll Give" : "You'll Get"),
      if (loanLabel.isNotEmpty && loanOutstanding.abs() > 0.009) SlipKv(loanLabel, slipMoney(loanOutstanding.abs())),
      if (stuck != 0) ...[
        SlipKv('Daily Payable', slipMoney(daily)),
        SlipKv('Stuck (Purana)', slipMoney(stuck)),
      ],
    ],
    blocks: [
      SlipBlock(
        heading: 'Transactions',
        headers: const ['Date', 'Details'],
        weights: const [1.5, 4],
        rightFrom: 99,
        rows: [
          for (final e in sorted)
            [e.createdAt > 0 ? slipDateTime(DateTime.fromMillisecondsSinceEpoch(e.createdAt)) : '', e.text],
        ],
      ),
    ],
  );
}

// ---------------------------------------------------------------- Party summary

SlipPdfData partySummarySlipData({
  required double toGet,
  required double toGive,
  String shopName = '',
  String shopPhone = '',
  DateTime? now,
}) {
  return SlipPdfData(
    title: 'PARTY SUMMARY',
    shopName: shopName,
    shopPhone: shopPhone,
    meta: [SlipKv('Date', slipDate(now ?? DateTime.now()))],
    blocks: [
      SlipBlock(lines: [
        SlipKv("You'll Get", slipMoney(toGet), bold: true, argb: 0xFF0F9B8E),
        SlipKv("You'll Give", slipMoney(toGive), bold: true, argb: 0xFFD64545),
      ]),
    ],
  );
}

// ---------------------------------------------------------------- Purchase

SlipPdfData purchaseSlipData({
  required String supplier,
  required String billNo,
  required double total,
  required double balance,
  required DateTime date,
  String shopName = '',
  String shopPhone = '',
  String title = 'PURCHASE BILL',
}) {
  return SlipPdfData(
    title: title,
    shopName: shopName,
    shopPhone: shopPhone,
    partyName: supplier,
    meta: [
      SlipKv('Bill No', billNo),
      SlipKv('Date', DateFormat('dd MMM yyyy').format(date)),
    ],
    blocks: [
      SlipBlock(lines: [
        SlipKv('Amount', slipMoney(total), bold: true),
        SlipKv('Balance', slipMoney(balance), bold: true),
      ]),
    ],
  );
}


// ---------------------------------------------------------------- Sale / Purchase bill (BillDoc)

/// Bill Preview ka PDF. [netBalance] sirf tab jab party mili ho (Prev/Net balance likhne ke liye).
SlipPdfData billDocSlipData(BillDoc d, {double? netBalance}) {
  final due = d.total - d.paid;
  final party = d.partyName.trim();
  return SlipPdfData(
    title: d.isPurchase ? 'PURCHASE BILL' : 'SALE BILL',
    shopName: d.shopName,
    shopPhone: d.shopPhone,
    partyName: party.isEmpty ? (d.isPurchase ? 'Cash Purchase' : 'Walk-in') : party,
    meta: [
      SlipKv(d.isPurchase ? 'Bill No' : 'Invoice', d.ref),
      SlipKv('Date', DateFormat('dd MMM yyyy').format(d.date)),
      SlipKv('Payment', d.paymentMethod),
    ],
    blocks: [
      SlipBlock(
        headers: const ['Item', 'Qty', 'Rate', 'Amount'],
        weights: const [3.2, 1.3, 1.1, 1.3],
        rows: [
          for (final i in d.items)
            [i.name, '${slipQty(i.qty)}${i.unit.isEmpty ? '' : ' ${i.unit}'}', slipRate(i.rate), slipMoney(i.amount)],
        ],
        lines: [
          SlipKv('Subtotal', slipMoney(d.subtotal)),
          if (d.discount > 0.009) SlipKv('Discount', '-${slipMoney(d.discount)}'),
          SlipKv('Total', slipMoney(d.total), bold: true),
          SlipKv('Paid', slipMoney(d.paid)),
          if (due > 0.009) SlipKv('Balance Due', slipMoney(due), bold: true, argb: 0xFFD64545),
          if (netBalance != null) ...[
            SlipKv('Prev Balance', slipMoney(netBalance - due)),
            SlipKv('Net Balance', slipMoney(netBalance), bold: true),
          ],
        ],
      ),
    ],
    footer: d.receiptFooter.trim().isEmpty ? slipThanks : d.receiptFooter.trim(),
  );
}
