import 'package:intl/intl.dart';

import 'bill_doc.dart';

/// Kotlin PrinterHelper.ReceiptLine ka Dart version (sirf woh types jo bill mein lagte hain).
sealed class ReceiptLine {
  const ReceiptLine();
}

class RlCenter extends ReceiptLine {
  final String text;
  final bool bold;
  final bool tight;
  const RlCenter(this.text, {this.bold = false, this.tight = false});
}

class RlLeft extends ReceiptLine {
  final String text;
  const RlLeft(this.text);
}

class RlTwoCol extends ReceiptLine {
  final String left;
  final String right;
  final bool bold;
  const RlTwoCol(this.left, this.right, {this.bold = false});
}

/// Item table: Item | Qty | Rate | Amount. `header` = true => table header row.
class RlItemRow extends ReceiptLine {
  final String name;
  final String qty;
  final String rate;
  final String amount;
  final bool header;
  const RlItemRow(this.name, this.qty, this.rate, this.amount, {this.header = false});
}

class RlBlank extends ReceiptLine {
  final int heightPx;
  const RlBlank([this.heightPx = 10]);
}

class RlDivider extends ReceiptLine {
  const RlDivider();
}

String _q(double v) {
  if (v == v.truncateToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
String _m(double v) => v.toStringAsFixed(2);

/// Header (shop + bill info) — har slip par dohraya jata hai.
List<ReceiptLine> receiptHeader(BillDoc d) {
  final sub = <String>[if (d.shopPhone.trim().isNotEmpty) d.shopPhone.trim()];
  return [
    RlCenter(d.shopName.trim().isEmpty ? 'IBTISAAM Kiryana Store' : d.shopName.trim(), bold: true),
    if (sub.isNotEmpty) RlCenter(sub.join('  •  ')),
    if (d.isPurchase) const RlCenter('PURCHASE BILL', bold: true),
    const RlDivider(),
    RlLeft('${d.isPurchase ? 'Bill No' : 'Invoice'}: ${d.ref}'),
    RlLeft('Date: ${DateFormat('dd/MM/yyyy hh:mm a').format(d.date)}'),
    RlLeft('${d.isPurchase ? 'Supplier' : 'Customer'}: '
        '${d.partyName.trim().isEmpty ? (d.isPurchase ? 'Cash Purchase' : 'Walk-in') : d.partyName.trim()}'),
    const RlDivider(),
  ];
}

/// Item table header + rows. Pehla element hamesha table header (paging isi par tikti hai).
List<ReceiptLine> receiptItems(BillDoc d) => [
      const RlItemRow('ITEM', 'QTY', 'RATE', 'AMOUNT', header: true),
      for (final i in d.items) RlItemRow(i.name, '${_q(i.qty)} ${i.unit}', _m(i.rate), _m(i.amount)),
    ];

/// Totals + footer — sirf aakhri slip par.
List<ReceiptLine> receiptFooter(BillDoc d, {double? netBalance}) {
  final due = d.total - d.paid;
  return [
    const RlDivider(),
    RlTwoCol('Subtotal', _m(d.subtotal)),
    if (d.discount > 0.009) RlTwoCol('Discount', '-${_m(d.discount)}'),
    RlTwoCol('TOTAL', _m(d.total), bold: true),
    RlTwoCol('Paid (${d.paymentMethod})', _m(d.paid)),
    if (due > 0.009) RlTwoCol('DUE', _m(due), bold: true),
    if (netBalance != null && d.partyId != null) ...[
      RlTwoCol('Prev Balance', _m(netBalance - due)),
      RlTwoCol('Net Balance', _m(netBalance), bold: true),
    ],
    const RlDivider(),
    RlCenter(d.receiptFooter.trim().isEmpty ? 'Shukriya! Dobara tashreef layen.' : d.receiptFooter.trim()),
  ];
}

/// Kotlin printReceiptLinesPaged(): lambi bill ko [maxItemsPerPage] rows ke slips mein todta hai.
/// Har slip = header (+ "Page X of Y") + table header + rows + ("Continued" ya footer).
/// Return: har slip ki lines.
List<List<ReceiptLine>> paginateReceipt({
  required List<ReceiptLine> header,
  required List<ReceiptLine> items, // pehla = table header
  required List<ReceiptLine> footer,
  int maxItemsPerPage = 18,
}) {
  final tableHeader = items.isEmpty ? null : items.first;
  final rows = items.isEmpty ? <ReceiptLine>[] : items.sublist(1);
  if (rows.length <= maxItemsPerPage) return [[...header, ...items, ...footer]];
  final pages = <List<ReceiptLine>>[];
  for (var i = 0; i < rows.length; i += maxItemsPerPage) {
    pages.add(rows.sublist(i, i + maxItemsPerPage > rows.length ? rows.length : i + maxItemsPerPage));
  }
  final total = pages.length;
  final out = <List<ReceiptLine>>[];
  for (var idx = 0; idx < total; idx++) {
    final n = idx + 1;
    out.add([
      ...header,
      if (n > 1) RlCenter('-- Page $n of $total (continued) --', tight: true),
      if (tableHeader != null) tableHeader,
      ...pages[idx],
      if (n < total) ...[
        const RlDivider(),
        const RlCenter('-- Continued on next slip --', bold: true, tight: true),
      ] else
        ...footer,
    ]);
  }
  return out;
}
