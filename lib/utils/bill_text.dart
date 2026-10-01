import 'package:intl/intl.dart';

import '../db/sale_repository.dart' show SaleLine;

String _qty(double v) {
  if (v == v.truncateToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Plain-text customer bill (32 columns — a standard 58mm thermal roll), used
/// by the Print/Share preview and as the plain-text (Copy / WhatsApp) bill.
/// Pure function so it is unit-tested.
String buildSaleBillText({
  required String shopName,
  String shopPhone = '',
  required String invoice,
  required DateTime date,
  required String customer,
  required List<SaleLine> lines,
  required double subtotal,
  required double discount,
  required double total,
  required double paid,
  String paymentMethod = 'Cash',
  double? netBalance,
  int width = 32,
}) {
  final b = StringBuffer();
  String center(String t) {
    if (t.length >= width) return t;
    return ' ' * ((width - t.length) ~/ 2) + t;
  }

  String row(String left, String right) {
    final space = width - left.length - right.length;
    if (space >= 1) return left + ' ' * space + right;
    return '$left\n${' ' * (width - right.length)}$right';
  }

  final rule = '-' * width;
  b.writeln(center(shopName.isEmpty ? 'IBTISAAM Kiryana Store' : shopName));
  if (shopPhone.isNotEmpty) b.writeln(center(shopPhone));
  b.writeln(rule);
  b.writeln('Invoice: $invoice');
  b.writeln('Date: ${DateFormat('dd/MM/yyyy hh:mm a').format(date)}');
  b.writeln('Customer: ${customer.trim().isEmpty ? 'Walk-in' : customer.trim()}');
  b.writeln(rule);
  for (final l in lines) {
    b.writeln(l.itemName);
    b.writeln(row('  ${_qty(l.qty)} ${l.unit} x ${l.unitPrice.toStringAsFixed(2)}', l.amount.toStringAsFixed(2)));
  }
  b.writeln(rule);
  b.writeln(row('Subtotal', subtotal.toStringAsFixed(2)));
  if (discount > 0.009) b.writeln(row('Discount', '-${discount.toStringAsFixed(2)}'));
  b.writeln(row('TOTAL', total.toStringAsFixed(2)));
  b.writeln(row('Paid ($paymentMethod)', paid.toStringAsFixed(2)));
  final due = total - paid;
  if (due > 0.009) b.writeln(row('DUE', due.toStringAsFixed(2)));
  if (netBalance != null) {
    b.writeln(row('Prev Balance', (netBalance - due).toStringAsFixed(2)));
    b.writeln(row('Net Balance', netBalance.toStringAsFixed(2)));
  }
  b.writeln(rule);
  b.writeln(center('Shukriya! Dobara tashreef layen'));
  return b.toString();
}

/// Plain-text supplier (purchase) bill — Kotlin BillPreviewActivity type "purchase" (party label
/// "Supplier"). Copy / WhatsApp text. Pure function => tested.
/// [lines] = (naam, qty, unit, unitCost, amount).
String buildPurchaseBillText({
  required String shopName,
  String shopPhone = '',
  required String billNo,
  required DateTime date,
  required String supplier,
  required List<({String name, double qty, String unit, double unitCost, double amount})> lines,
  required double subtotal,
  required double discount,
  required double total,
  required double paid,
  String paymentMethod = 'Cash',
  double? netBalance,
  int width = 32,
}) {
  final b = StringBuffer();
  String center(String t) {
    if (t.length >= width) return t;
    return ' ' * ((width - t.length) ~/ 2) + t;
  }

  String row(String left, String right) {
    final space = width - left.length - right.length;
    if (space >= 1) return left + ' ' * space + right;
    return '$left\n${' ' * (width - right.length)}$right';
  }

  final rule = '-' * width;
  b.writeln(center(shopName.isEmpty ? 'IBTISAAM Kiryana Store' : shopName));
  if (shopPhone.isNotEmpty) b.writeln(center(shopPhone));
  b.writeln(center('PURCHASE BILL'));
  b.writeln(rule);
  b.writeln('Bill No: $billNo');
  b.writeln('Date: ${DateFormat('dd/MM/yyyy hh:mm a').format(date)}');
  b.writeln('Supplier: ${supplier.trim().isEmpty ? 'Cash Purchase' : supplier.trim()}');
  b.writeln(rule);
  for (final l in lines) {
    b.writeln(l.name);
    b.writeln(row('  ${_qty(l.qty)} ${l.unit} x ${l.unitCost.toStringAsFixed(2)}', l.amount.toStringAsFixed(2)));
  }
  b.writeln(rule);
  b.writeln(row('Subtotal', subtotal.toStringAsFixed(2)));
  if (discount > 0.009) b.writeln(row('Discount', '-${discount.toStringAsFixed(2)}'));
  b.writeln(row('TOTAL', total.toStringAsFixed(2)));
  b.writeln(row('Paid ($paymentMethod)', paid.toStringAsFixed(2)));
  final due = total - paid;
  if (due > 0.009) b.writeln(row('DUE', due.toStringAsFixed(2)));
  if (netBalance != null) {
    b.writeln(row('Prev Balance', (netBalance - due).toStringAsFixed(2)));
    b.writeln(row('Net Balance', netBalance.toStringAsFixed(2)));
  }
  return b.toString();
}

/// Kotlin sharePurchase(): chhota summary text (supplier, bill no, amount, balance, date).
String buildPurchaseShareText({
  required String supplier,
  required String billNo,
  required double total,
  required double balance,
  required DateTime date,
}) =>
    [
      'Purchase Bill',
      'Supplier: $supplier',
      'Bill No: $billNo',
      'Amount: Rs ${total.toStringAsFixed(2)}',
      'Balance: Rs ${balance.toStringAsFixed(2)}',
      'Date: ${DateFormat('dd MMM yyyy').format(date)}',
    ].join('\n');
