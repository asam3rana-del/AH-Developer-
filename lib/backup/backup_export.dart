import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show PdfGoogleFonts;

import '../db/app_database.dart';
import '../models/product.dart';
import '../utils/pdf_urdu.dart';

/// Mirrors BackupExportActivity.kt (data + CSV + PDF hissa; screen `backup_export_screen.dart` mein).
/// Sales, Purchases, Day Book, Customers/Suppliers (+ledgers), Products/Stock, Expenses, Cash/Bank
/// ko ek CSV + ek printable PDF mein — all-time ya date range.

const int kAllTimeEnd = 9223372036854775807; // Long.MAX_VALUE

class DayBookRow {
  final int date;
  final String type, ref, party, status;
  final double total, paid;
  const DayBookRow(this.date, this.type, this.ref, this.party, this.total, this.paid, this.status);
}

/// Sale / Purchase ki ek line (Kotlin DayBookSale / DayBookPurchase / ledger rows).
class BillRow {
  final int createdAt;
  final String ref, party, status;
  final double total, paid;
  const BillRow(this.createdAt, this.ref, this.party, this.total, this.paid, this.status);
}

class PartyRow {
  final int id;
  final String name, phone;
  final double openingBalance, balance, stuckBalance;
  const PartyRow(this.id, this.name, this.phone, this.openingBalance, this.balance, this.stuckBalance);
}

class ExpenseRow {
  final int createdAt;
  final String category, description;
  final double amount;
  const ExpenseRow(this.createdAt, this.category, this.description, this.amount);
}

class CashRow {
  final int createdAt;
  final String type, method, reason;
  final double amount;
  const CashRow(this.createdAt, this.type, this.method, this.amount, this.reason);
}

class BackupTotals {
  final double totalSales, totalPurchases, totalExpenses, receivables, payables, stockValue;
  const BackupTotals({
    required this.totalSales,
    required this.totalPurchases,
    required this.totalExpenses,
    required this.receivables,
    required this.payables,
    required this.stockValue,
  });
}

class BackupData {
  final List<DayBookRow> dayBook;
  final List<BillRow> sales, purchases;
  final List<PartyRow> customers, suppliers;
  final Map<int, List<BillRow>> customerLedgers, supplierLedgers;
  final List<Product> products;
  final List<ExpenseRow> expenses;
  final List<CashRow> cashTx;
  final BackupTotals totals;
  const BackupData({
    required this.dayBook,
    required this.sales,
    required this.purchases,
    required this.customers,
    required this.customerLedgers,
    required this.suppliers,
    required this.supplierLedgers,
    required this.products,
    required this.expenses,
    required this.cashTx,
    required this.totals,
  });
}

class ExportFiles {
  final File pdf, csv;
  const ExportFiles(this.pdf, this.csv);
}

class BackupExport {
  BackupExport._();

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0.0;
  static int _i(Object? v) => (v as num?)?.toInt() ?? 0;
  static String _s(Object? v) => v?.toString() ?? '';

  // ---------------- data collection ----------------

  /// [start]/[end] millis (dono shamil). All-time: `collect(0, kAllTimeEnd)`.
  static Future<BackupData> collect(int start, int end) async {
    final db = await AppDatabase.instance.database;
    final args = [start, end];

    final saleRows = await db.rawQuery(
      "SELECT s.invoice AS ref, COALESCE(c.name, 'Walk-in') AS party, s.total AS total, s.paid AS paid, "
      's.createdAt AS createdAt, s.status AS status '
      'FROM sales s LEFT JOIN customers c ON c.id = s.customerId '
      'WHERE s.createdAt BETWEEN ? AND ? ORDER BY s.createdAt ASC',
      args,
    );
    final purchaseRows = await db.rawQuery(
      "SELECT pu.billNo AS ref, COALESCE(su.name, 'Cash Purchase') AS party, pu.total AS total, pu.paid AS paid, "
      'pu.createdAt AS createdAt, pu.status AS status '
      'FROM purchases pu LEFT JOIN suppliers su ON su.id = pu.supplierId '
      'WHERE pu.createdAt BETWEEN ? AND ? ORDER BY pu.createdAt ASC',
      args,
    );
    BillRow bill(Map<String, Object?> r) => BillRow(
        _i(r['createdAt']), _s(r['ref']), _s(r['party']), _d(r['total']), _d(r['paid']), _s(r['status']));
    final sales = saleRows.map(bill).toList();
    final purchases = purchaseRows.map(bill).toList();

    final dayBook = <DayBookRow>[
      for (final r in sales) DayBookRow(r.createdAt, 'Sale', r.ref, r.party, r.total, r.paid, r.status),
      for (final r in purchases) DayBookRow(r.createdAt, 'Purchase', r.ref, r.party, r.total, r.paid, r.status),
    ]..sort((a, b) => a.date.compareTo(b.date));

    // Customers / Suppliers (sab) + un ke ledgers (sirf range ke andar, naya pehle — Kotlin jaisa).
    final customers = (await db.rawQuery('SELECT * FROM customers ORDER BY name COLLATE NOCASE'))
        .map((r) => PartyRow(_i(r['id']), _s(r['name']), _s(r['phone']), _d(r['openingBalance']), _d(r['balance']),
            _d(r['stuckBalance'])))
        .toList();
    final suppliers = (await db.rawQuery('SELECT * FROM suppliers ORDER BY name COLLATE NOCASE'))
        .map((r) => PartyRow(_i(r['id']), _s(r['name']), _s(r['phone']), _d(r['openingBalance']), _d(r['balance']), 0))
        .toList();

    final customerLedgers = <int, List<BillRow>>{};
    for (final r in await db.rawQuery(
      'SELECT customerId AS pid, invoice AS ref, total, paid, createdAt, status FROM sales '
      'WHERE customerId IS NOT NULL AND createdAt BETWEEN ? AND ? ORDER BY createdAt DESC',
      args,
    )) {
      customerLedgers
          .putIfAbsent(_i(r['pid']), () => [])
          .add(BillRow(_i(r['createdAt']), _s(r['ref']), '', _d(r['total']), _d(r['paid']), _s(r['status'])));
    }
    final supplierLedgers = <int, List<BillRow>>{};
    for (final r in await db.rawQuery(
      'SELECT supplierId AS pid, billNo AS ref, total, paid, createdAt, status FROM purchases '
      'WHERE supplierId IS NOT NULL AND createdAt BETWEEN ? AND ? ORDER BY createdAt DESC',
      args,
    )) {
      supplierLedgers
          .putIfAbsent(_i(r['pid']), () => [])
          .add(BillRow(_i(r['createdAt']), _s(r['ref']), '', _d(r['total']), _d(r['paid']), _s(r['status'])));
    }

    final products = (await db.rawQuery('SELECT * FROM products ORDER BY name COLLATE NOCASE'))
        .map(Product.fromMap)
        .toList();

    final expenses = (await db.rawQuery(
      'SELECT createdAt, category, description, amount FROM expenses WHERE createdAt BETWEEN ? AND ? ORDER BY createdAt ASC',
      args,
    ))
        .map((r) => ExpenseRow(_i(r['createdAt']), _s(r['category']), _s(r['description']), _d(r['amount'])))
        .toList();

    final cashTx = (await db.rawQuery(
      'SELECT createdAt, type, method, amount, reason FROM cash_transactions WHERE createdAt BETWEEN ? AND ? ORDER BY createdAt ASC',
      args,
    ))
        .map((r) => CashRow(_i(r['createdAt']), _s(r['type']), _s(r['method']), _d(r['amount']), _s(r['reason'])))
        .toList();

    // Kotlin FIX: stock smallest unit mein, cost primary unit ka — is liye factor se taqseem.
    var stockValue = 0.0;
    for (final pr in products) {
      final factor = pr.smallestUnitFactor();
      final costPerSmallest = factor > 0 ? pr.cost / factor : pr.cost;
      stockValue += pr.stock * costPerSmallest;
    }

    Future<double> sum(String sql, [List<Object?>? a]) async => _d((await db.rawQuery(sql, a)).first.values.first);

    final totals = BackupTotals(
      totalSales: await sum("SELECT COALESCE(SUM(total),0) FROM sales WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args),
      totalPurchases: await sum("SELECT COALESCE(SUM(total),0) FROM purchases WHERE createdAt BETWEEN ? AND ? AND status!='returned'", args),
      totalExpenses: await sum('SELECT COALESCE(SUM(amount),0) FROM expenses WHERE createdAt BETWEEN ? AND ?', args),
      receivables: await sum('SELECT COALESCE(SUM(balance),0) FROM customers WHERE balance>0'),
      payables: await sum('SELECT COALESCE(SUM(balance),0) FROM suppliers WHERE balance>0'),
      stockValue: stockValue,
    );

    return BackupData(
      dayBook: dayBook,
      sales: sales,
      purchases: purchases,
      customers: customers,
      customerLedgers: customerLedgers,
      suppliers: suppliers,
      supplierLedgers: supplierLedgers,
      products: products,
      expenses: expenses,
      cashTx: cashTx,
      totals: totals,
    );
  }

  // ---------------- formatting ----------------

  static final _fmtDt = DateFormat('dd MMM yyyy hh:mm a');
  static final _fmtD = DateFormat('dd MMM yyyy');
  static String _dt(int ms) => _fmtDt.format(DateTime.fromMillisecondsSinceEpoch(ms));
  static String _n(double v) => v.toStringAsFixed(2);
  static String _rs(double v) => 'Rs ${v.toStringAsFixed(2)}';

  static String rangeText(int start, int end) => start <= 0
      ? 'All Time'
      : '${_fmtD.format(DateTime.fromMillisecondsSinceEpoch(start))}  -  ${_fmtD.format(DateTime.fromMillisecondsSinceEpoch(end))}';

  // ---------------- CSV ----------------

  static String csvEscape(String s) {
    final needsQuote = s.contains(',') || s.contains('"') || s.contains('\n');
    final esc = s.replaceAll('"', '""');
    return needsQuote ? '"$esc"' : esc;
  }

  /// Excel ke liye UTF-8 BOM (Kotlin mein nahi tha) — warna Urdu naam Excel mein kharab dikhte hain.
  static String buildCsv(BackupData data) {
    final sb = StringBuffer('\uFEFF');
    void section(String title) => sb.write('\n=== $title ===\n');
    void row(List<String> cells) => sb.write('${cells.map(csvEscape).join(',')}\n');

    section('BUSINESS SUMMARY');
    row(['Metric', 'Value']);
    row(['Total Sales (period)', _n(data.totals.totalSales)]);
    row(['Total Purchases (period)', _n(data.totals.totalPurchases)]);
    row(['Total Expenses (period)', _n(data.totals.totalExpenses)]);
    row(['Receivables (current)', _n(data.totals.receivables)]);
    row(['Payables (current)', _n(data.totals.payables)]);
    row(['Stock Value (current)', _n(data.totals.stockValue)]);

    section('DAY BOOK');
    row(['Date', 'Type', 'Ref', 'Party', 'Total', 'Paid', 'Status']);
    for (final r in data.dayBook) {
      row([_dt(r.date), r.type, r.ref, r.party, _n(r.total), _n(r.paid), r.status]);
    }

    section('SALES');
    row(['Date', 'Invoice', 'Customer', 'Total', 'Paid', 'Status']);
    for (final r in data.sales) {
      row([_dt(r.createdAt), r.ref, r.party, _n(r.total), _n(r.paid), r.status]);
    }

    section('PURCHASES');
    row(['Date', 'Bill No', 'Supplier', 'Total', 'Paid', 'Status']);
    for (final r in data.purchases) {
      row([_dt(r.createdAt), r.ref, r.party, _n(r.total), _n(r.paid), r.status]);
    }

    section('CUSTOMERS');
    row(['Name', 'Phone', 'Opening Balance', 'Current Balance', 'Stuck Balance']);
    for (final c in data.customers) {
      row([c.name, c.phone, _n(c.openingBalance), _n(c.balance), _n(c.stuckBalance)]);
    }

    section('CUSTOMER LEDGERS');
    for (final c in data.customers) {
      final ledger = data.customerLedgers[c.id];
      if (ledger == null) continue;
      row(['Customer:', c.name]);
      row(['Date', 'Invoice', 'Total', 'Paid', 'Status']);
      for (final r in ledger) {
        row([_dt(r.createdAt), r.ref, _n(r.total), _n(r.paid), r.status]);
      }
      sb.write('\n');
    }

    section('SUPPLIERS');
    row(['Name', 'Phone', 'Opening Balance', 'Current Balance']);
    for (final s in data.suppliers) {
      row([s.name, s.phone, _n(s.openingBalance), _n(s.balance)]);
    }

    section('SUPPLIER LEDGERS');
    for (final s in data.suppliers) {
      final ledger = data.supplierLedgers[s.id];
      if (ledger == null) continue;
      row(['Supplier:', s.name]);
      row(['Date', 'Bill No', 'Total', 'Paid']);
      for (final r in ledger) {
        row([_dt(r.createdAt), r.ref, _n(r.total), _n(r.paid)]);
      }
      sb.write('\n');
    }

    section('PRODUCTS & STOCK');
    row(['Barcode', 'Name', 'Category', 'Stock', 'Sale Price', 'Cost']);
    for (final pr in data.products) {
      row([pr.barcode, pr.name, pr.category, pr.formatStockBreakdown(), _n(pr.salePrice), _n(pr.cost)]);
    }

    section('EXPENSES');
    row(['Date', 'Category', 'Description', 'Amount']);
    for (final e in data.expenses) {
      row([_dt(e.createdAt), e.category, e.description, _n(e.amount)]);
    }

    section('CASH / BANK TRANSACTIONS');
    row(['Date', 'Type', 'Method', 'Amount', 'Reason']);
    for (final c in data.cashTx) {
      row([_dt(c.createdAt), c.type, c.method, _n(c.amount), c.reason]);
    }
    return sb.toString();
  }

  // ---------------- PDF ----------------

  static const _navy = PdfColor.fromInt(0xFF2E3242);
  static const _gray = PdfColor.fromInt(0xFF9AA0B4);
  static const _teal = PdfColor.fromInt(0xFF0F9B8E);
  static const _blue = PdfColor.fromInt(0xFF5B6EE8);
  static const _line = PdfColor.fromInt(0xFFEEF0F7);

  static pw.Font? _urduFont; // ek baar load, phir cache

  /// Urdu font (PDF report / print). assets/fonts/ se, is tarteeb se (pehla jo load ho jaye):
  /// (1) NotoNaskhArabic-Regular.ttf (agar aap rakhein — PDF ke liye sab se behtar Noto font),
  /// (2) UrduFallback.ttf (FreeSerif ka Urdu hissa — jore hue huroof ke "presentation forms" ke saath, PDF library
  ///     ke liye safe), (3) NotoNastaliqUrdu-Regular.ttf — ye font jorne ka kaam sirf GSUB se karta hai jo `pdf`
  ///     library nahi chalati, is liye PDF mein ye aakhri option hai. Phir Google Fonts (internet).
  static Future<pw.Font?> _loadUrduFont() async {
    if (_urduFont != null) return _urduFont;
    for (final path in const [
      'assets/fonts/NotoNaskhArabic-Regular.ttf',
      'assets/fonts/UrduFallback.ttf',
      'assets/fonts/NotoNastaliqUrdu-Regular.ttf',
    ]) {
      try {
        _urduFont = pw.Font.ttf(await rootBundle.load(path));
        return _urduFont;
      } catch (_) {}
    }
    try {
      _urduFont = await PdfGoogleFonts.notoNaskhArabicRegular().timeout(const Duration(seconds: 25));
      return _urduFont;
    } catch (_) {}
    return null;
  }

  static Future<pw.ThemeData> _theme() async {
    final urdu = await _loadUrduFont();
    return pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      fontFallback: urdu == null ? const [] : [urdu],
    );
  }

  static pw.Widget _heading(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10, bottom: 6),
        child: UrduPdf.widget(t, fontSize: 13, argb: 0xFF0F9B8E, bold: true) ??
            pw.Text(t, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _teal)),
      );

  /// Table ka ek cell: Urdu ho to Noto Nastaliq ki tasveer, warna aam pw.Text.
  static pw.Widget _cell(String t, {bool header = false}) {
    final size = header ? 8.5 : 8.3;
    final child = UrduPdf.widget(t, fontSize: size, argb: header ? 0xFFFFFFFF : 0xFF2E3242, bold: header) ??
        pw.Text(t,
            style: header
                ? pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold, color: PdfColors.white)
                : pw.TextStyle(fontSize: size, color: _navy));
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Align(alignment: pw.Alignment.centerLeft, child: child),
    );
  }

  static pw.Widget _table(List<String> headers, List<double> weights, List<List<String>> rows) {
    if (rows.isEmpty) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text('- no records -', style: const pw.TextStyle(fontSize: 9, color: _gray)),
      );
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Table(
        columnWidths: {for (var i = 0; i < weights.length; i++) i: pw.FlexColumnWidth(weights[i])},
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.6)),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _blue),
            children: [for (final h in headers) _cell(h, header: true)],
          ),
          for (final r in rows) pw.TableRow(children: [for (final c in r) _cell(c)]),
        ],
      ),
    );
  }

  static Future<Uint8List> buildPdf(BackupData data, int start, int end, {DateTime? generatedAt}) async {
    final doc = pw.Document(theme: await _theme());
    final gen = DateFormat('dd MMM yyyy hh:mm a').format(generatedAt ?? DateTime.now());

    final t = data.totals;
    List<pw.Widget> makeWidgets() => <pw.Widget>[
      pw.Text('Grocery POS - Business Backup Report',
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _navy)),
      pw.SizedBox(height: 4),
      pw.Text('Period: ${rangeText(start, end)}     |     Generated: $gen',
          style: const pw.TextStyle(fontSize: 9, color: _gray)),
      pw.SizedBox(height: 6),
      _heading('Business Summary'),
      _table(['Metric', 'Value'], [2, 1], [
        ['Total Sales (period)', _rs(t.totalSales)],
        ['Total Purchases (period)', _rs(t.totalPurchases)],
        ['Total Expenses (period)', _rs(t.totalExpenses)],
        ["Receivables - You'll Get (current)", _rs(t.receivables)],
        ["Payables - You'll Give (current)", _rs(t.payables)],
        ['Current Stock Value (current)', _rs(t.stockValue)],
      ]),
      _heading('Day Book (Roznamcha)'),
      _table(['Date', 'Type', 'Ref#', 'Party', 'Total', 'Paid', 'Status'], [1.6, 0.8, 1, 1.6, 1, 1, 0.9],
          [for (final r in data.dayBook) [_dt(r.date), r.type, r.ref, r.party, _rs(r.total), _rs(r.paid), r.status]]),
      _heading('Sales'),
      _table(['Date', 'Invoice', 'Customer', 'Total', 'Paid', 'Status'], [1.5, 1.2, 1.6, 1, 1, 0.9],
          [for (final r in data.sales) [_dt(r.createdAt), r.ref, r.party, _rs(r.total), _rs(r.paid), r.status]]),
      _heading('Purchases'),
      _table(['Date', 'Bill#', 'Supplier', 'Total', 'Paid', 'Status'], [1.5, 1.2, 1.6, 1, 1, 0.9],
          [for (final r in data.purchases) [_dt(r.createdAt), r.ref, r.party, _rs(r.total), _rs(r.paid), r.status]]),
      _heading('Customers'),
      _table(['Name', 'Phone', 'Opening Bal', 'Current Bal', 'Stuck Bal'], [1.5, 1.1, 1, 1, 1],
          [for (final c in data.customers) [c.name, c.phone, _rs(c.openingBalance), _rs(c.balance), _rs(c.stuckBalance)]]),
      for (final c in data.customers)
        if (data.customerLedgers[c.id] != null) ...[
          _heading('Ledger: ${c.name}'),
          _table(['Date', 'Invoice', 'Total', 'Paid', 'Status'], [1.6, 1.2, 1, 1, 0.9], [
            for (final r in data.customerLedgers[c.id]!) [_dt(r.createdAt), r.ref, _rs(r.total), _rs(r.paid), r.status]
          ]),
        ],
      _heading('Suppliers'),
      _table(['Name', 'Phone', 'Opening Bal', 'Current Bal'], [1.6, 1.2, 1, 1],
          [for (final s in data.suppliers) [s.name, s.phone, _rs(s.openingBalance), _rs(s.balance)]]),
      for (final s in data.suppliers)
        if (data.supplierLedgers[s.id] != null) ...[
          _heading('Ledger: ${s.name}'),
          _table(['Date', 'Bill#', 'Total', 'Paid'], [1.6, 1.2, 1, 1], [
            for (final r in data.supplierLedgers[s.id]!) [_dt(r.createdAt), r.ref, _rs(r.total), _rs(r.paid)]
          ]),
        ],
      _heading('Products & Stock'),
      _table(['Barcode', 'Name', 'Category', 'Stock', 'Sale Price', 'Cost'], [1, 1.6, 1, 1.2, 0.9, 0.9], [
        for (final pr in data.products)
          [pr.barcode, pr.name, pr.category, pr.formatStockBreakdown(), _rs(pr.salePrice), _rs(pr.cost)]
      ]),
      _heading('Expenses'),
      _table(['Date', 'Category', 'Description', 'Amount'], [1.4, 1, 1.8, 0.9],
          [for (final e in data.expenses) [_dt(e.createdAt), e.category, e.description, _rs(e.amount)]]),
      _heading('Cash / Bank Transactions'),
      _table(['Date', 'Type', 'Method', 'Amount', 'Reason'], [1.4, 0.8, 0.9, 0.9, 1.6],
          [for (final c in data.cashTx) [_dt(c.createdAt), c.type, c.method, _rs(c.amount), c.reason]]),
    ];

    // Pass 1: kaunsa Urdu text chahiye (yaad rakhta hai) -> tasveerein banao -> Pass 2: asli widgets.
    makeWidgets();
    await UrduPdf.flush();
    final widgets = makeWidgets();

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 40),
      maxPages: 5000, // default 20 — bari dukan ka full backup us se lamba ho sakta hai
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber}', style: const pw.TextStyle(fontSize: 7.5, color: _gray)),
      ),
      build: (ctx) => widgets,
    ));
    return doc.save();
  }

  // ---------------- run (collect + write files) ----------------

  /// Kotlin `runBackup()`: data jama kar ke PDF + CSV temp `backups/` folder mein likhta hai.
  static Future<ExportFiles> run(int start, int end, String labelForFile) async {
    final data = await collect(start, end);
    final stamp = DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now());
    final baseName = 'GroceryPOS_Backup_${labelForFile}_$stamp';
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'backups'));
    if (!await dir.exists()) await dir.create(recursive: true);

    final pdfFile = File(p.join(dir.path, '$baseName.pdf'));
    await pdfFile.writeAsBytes(await buildPdf(data, start, end), flush: true);
    final csvFile = File(p.join(dir.path, '$baseName.csv'));
    await csvFile.writeAsString(buildCsv(data), flush: true);
    return ExportFiles(pdfFile, csvFile);
  }
}
