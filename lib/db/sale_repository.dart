import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart' show Transaction;

import '../models/held_bill.dart';
import '../models/misc_entities.dart';
import '../models/product.dart';
import '../models/sale.dart';
import '../services/session.dart';
import '../utils/split_payment.dart';
import '../utils/stock_touch_policy.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'product_repository.dart';

/// One line the user has added to the sale bill before saving — mirrors
/// `SaleLine` (domain) used by SaleActivity.kt's `lines` list. The unit
/// ladder fields are snapshotted so a held bill can be recalled later even if
/// the product's units were edited in between (same as the Kotlin app).
class SaleLine {
  final String itemName;
  final String barcode;
  final double qty;
  final String unit;
  final double unitPrice;
  final double cost;
  final double amount;
  final String mainUnit;
  final String secondaryUnit;
  final double secondaryUnitQty;
  final String tertiaryUnit;
  final double tertiaryUnitQty;

  const SaleLine({
    required this.itemName,
    required this.barcode,
    required this.qty,
    required this.unit,
    required this.unitPrice,
    required this.cost,
    required this.amount,
    this.mainUnit = '',
    this.secondaryUnit = '',
    this.secondaryUnitQty = 0.0,
    this.tertiaryUnit = '',
    this.tertiaryUnitQty = 0.0,
  });

  SaleLine copyWith({double? qty, String? unit, double? unitPrice, double? cost, double? amount}) => SaleLine(
        itemName: itemName,
        barcode: barcode,
        qty: qty ?? this.qty,
        unit: unit ?? this.unit,
        unitPrice: unitPrice ?? this.unitPrice,
        cost: cost ?? this.cost,
        amount: amount ?? this.amount,
        mainUnit: mainUnit,
        secondaryUnit: secondaryUnit,
        secondaryUnitQty: secondaryUnitQty,
        tertiaryUnit: tertiaryUnit,
        tertiaryUnitQty: tertiaryUnitQty,
      );
}

/// Thrown to abort the transaction early (e.g. stock changed under us) —
/// mirrors SaveAbortedException in SaleActivity.kt.
class SaleStockException implements Exception {
  final String message;
  SaleStockException(this.message);
  @override
  String toString() => message;
}

/// Thrown BEFORE anything is written when a credit bill would push a known
/// customer past their credit limit. The screen shows a confirm dialog and,
/// only if the cashier agrees, saves again with `overrideCreditLimit: true`.
/// Mirrors SaveSaleResult / QuickSaleResult.CreditLimitExceeded.
class SaleCreditLimitException implements Exception {
  final String customerName;
  final double creditLimit;
  final double projectedBalance;
  SaleCreditLimitException(this.customerName, this.creditLimit, this.projectedBalance);
  @override
  String toString() =>
      '$customerName ki credit limit ${creditLimit.toStringAsFixed(0)} hai, is bill ke baad balance ${projectedBalance.toStringAsFixed(0)} ho jayega';
}

/// Mirrors QuickSaleSaveResult.
class QuickSaleSaveResult {
  final String invoice;
  final bool isCredit;
  const QuickSaleSaveResult(this.invoice, this.isCredit);
}

/// Everything the Sale screen needs to re-open a saved bill for editing.
/// Mirrors `SaleForEdit`.
class SaleForEdit {
  final Sale sale;
  final List<SaleItem> items;
  final String customerName;
  final List<SaleLine> lines;

  /// Non-empty only when the bill was saved with 2+ payment rows, so the
  /// screen can re-open the Split Payment dialog pre-filled.
  final List<PayEntry> payments;
  const SaleForEdit(this.sale, this.items, this.customerName, this.lines, [this.payments = const []]);
}

/// Last rate charged to a customer for an item. Mirrors `CustomerItemRate`.
class CustomerItemRate {
  final double unitPrice;
  final String unit;
  const CustomerItemRate(this.unitPrice, this.unit);
}

class SaleRepository {
  SaleRepository._();
  static final SaleRepository instance = SaleRepository._();

  final _controller = StreamController<List<Sale>>.broadcast();
  bool _primed = false;

  Stream<List<Sale>> watchAll() {
    if (!_primed) {
      _primed = true;
      _notify();
    }
    return _controller.stream;
  }

  Future<void> _notify() async {
    final rows = await listAll();
    if (!_controller.isClosed) _controller.add(rows);
  }

  Future<List<Sale>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('sales', orderBy: 'createdAt DESC');
    return rows.map(Sale.fromMap).toList();
  }

  /// Mirrors invoice generation in `saveSale()`: MMyy + last 8 digits of the
  /// current time in milliseconds.
  String nextInvoiceNumber(int saleDateMillis) {
    final date = DateTime.fromMillisecondsSinceEpoch(saleDateMillis);
    final mmYY = '${date.month.toString().padLeft(2, '0')}${(date.year % 100).toString().padLeft(2, '0')}';
    final suffix = DateTime.now().millisecondsSinceEpoch.toString();
    return mmYY + suffix.substring(suffix.length - 8);
  }

  // ------------------------------------------------------------ Admin guard

  /// Edit / delete / return of a SAVED bill is admin-only. Checked here too
  /// (not just by hiding buttons) so no other screen can bypass it.
  void _requireAdmin() {
    if (!Session.isAdmin) {
      throw ArgumentError('Saved sale mein tabdeeli sirf Admin kar sakta hai');
    }
  }

  Future<void> _logAudit(String action, String reference, String details) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': action,
        'reference': reference,
        'details': details,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Audit must never break a save that already committed.
    }
  }

  Future<void> _increaseStock(Transaction txn, String barcode, double smallest, int now) async {
    await txn.rawUpdate(
      'UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
      [smallest, now, barcode],
    );
  }

  Future<void> _adjustCustomerBalance(Transaction txn, int customerId, double delta, int now) async {
    await txn.rawUpdate(
      'UPDATE customers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
      [delta, now, customerId],
    );
  }

  /// Deletes the cash-drawer rows of [invoice] AND queues each removal so
  /// other devices drop them too (Kotlin deleteCashTransactionsByReference).
  Future<void> _deleteCashByReference(Transaction txn, String invoice) async {
    final rows = await txn.query('cash_transactions', where: 'reference=?', whereArgs: [invoice]);
    for (final r in rows) {
      final id = r['id'];
      await txn.delete('cash_transactions', where: 'id=?', whereArgs: [id]);
      await _enqueueSync(txn, 'cash_transaction', '$id', 'delete', {'id': id, 'reference': invoice});
    }
  }

  // ---------------------------------------------------------------- Load edit

  /// Re-opens a saved bill. Mirrors `LoadSaleForEditUseCase`.
  Future<SaleForEdit?> loadForEdit(String invoice) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    final saleRows = await db.query('sales', where: 'invoice=?', whereArgs: [invoice], limit: 1);
    if (saleRows.isEmpty) return null;
    final sale = Sale.fromMap(saleRows.first);
    final itemRows = await db.query('sale_items', where: 'invoice=?', whereArgs: [invoice], orderBy: 'id ASC');
    final items = itemRows.map(SaleItem.fromMap).toList();

    var customerName = '';
    if (sale.customerId != null) {
      final c = await db.query('customers', where: 'id=?', whereArgs: [sale.customerId], limit: 1);
      if (c.isNotEmpty) customerName = (c.first['name'] as String?) ?? '';
    }

    final lines = <SaleLine>[];
    for (final si in items) {
      final pr = await db.query('products', where: 'barcode=?', whereArgs: [si.barcode], limit: 1);
      final product = pr.isEmpty ? null : Product.fromMap(pr.first);
      lines.add(SaleLine(
        itemName: si.product,
        barcode: si.barcode,
        qty: si.qty,
        unit: si.unit.isEmpty ? (product?.unit ?? '') : si.unit,
        unitPrice: si.unitPrice,
        cost: si.cost,
        amount: si.amount,
        mainUnit: product?.unit ?? '',
        secondaryUnit: product?.secondaryUnit ?? '',
        secondaryUnitQty: product?.secondaryUnitQty ?? 0.0,
        tertiaryUnit: product?.tertiaryUnit ?? '',
        tertiaryUnitQty: product?.tertiaryUnitQty ?? 0.0,
      ));
    }
    // Mirrors paymentsForInvoice(): the bill's own cash-in rows, oldest first.
    // Only 2+ rows count as a split (a single row is the normal method+paid).
    final cashRows = await db.query('cash_transactions',
        where: 'reference=? AND type=? AND reason=?', whereArgs: [invoice, 'IN', 'Sale'], orderBy: 'id ASC');
    final payments = cashRows
        .map((r) => PayEntry(_methodTitle((r['method'] as String?) ?? 'cash'), (r['amount'] as num).toDouble()))
        .toList();
    return SaleForEdit(sale, items, customerName, lines, payments.length >= 2 ? payments : const <PayEntry>[]);
  }

  static String _methodTitle(String m) => m.toLowerCase() == 'bank' ? 'Bank' : 'Cash';

  /// Double-bill alert: an existing, non-returned bill for the same customer
  /// (blank = Walk-in), same total, on the same calendar day as [saleDateMillis].
  /// [excludeInvoice] skips the bill being edited. Returns null when none.
  Future<Sale?> findDuplicateSale({
    required String customerName,
    required double total,
    required int saleDateMillis,
    String? excludeInvoice,
  }) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT s.*, c.name AS _cname FROM sales s LEFT JOIN customers c ON c.id = s.customerId '
      "WHERE s.status != 'returned' ORDER BY s.createdAt DESC",
    );
    final wantedDate = DateTime.fromMillisecondsSinceEpoch(saleDateMillis);
    for (final r in rows) {
      final sale = Sale.fromMap(r);
      if (excludeInvoice != null && sale.invoice == excludeInvoice) continue;
      if (isDuplicateSale(
        candidateCustomer: (r['_cname'] as String?) ?? '',
        candidateTotal: sale.total,
        candidateDate: DateTime.fromMillisecondsSinceEpoch(sale.createdAt),
        wantedCustomer: customerName,
        wantedTotal: total,
        wantedDate: wantedDate,
      )) {
        return sale;
      }
    }
    return null;
  }

  /// Mirrors `saveSale()` (RoomSaleRepository) for BOTH a new bill and — when
  /// [editInvoice] is given — an edit of a saved one (admin only).
  ///
  /// New bill: checks stock for every line against current product state,
  /// creates the customer if new, inserts the sale + items, decreases stock,
  /// adds any due to the customer's balance and records a cash-in.
  ///
  /// Edit: inside the SAME transaction it first gives back stock only for the
  /// original rows that were actually changed/removed ([saleEditDiff]),
  /// reverses the original due, replaces the items and cash rows, updates the
  /// sale row IN PLACE (status is kept), then re-applies stock only for
  /// changed lines. A line left untouched never touches stock, so an edit of
  /// e.g. just the customer can't fail with a false "stock badal gaya".
  ///
  /// Throws [SaleStockException] if a line's stock is no longer available,
  /// [SaleCreditLimitException] (unless [overrideCreditLimit]) or
  /// [ArgumentError] for bad input / a non-admin edit.
  Future<String> saveSale({
    required List<SaleLine> lines,
    required String customerName,
    required double discountInput,
    required double paidInput,
    required String saleType, // 'retail' or 'wholesale'
    required int saleDateMillis,
    String paymentMethod = 'Cash',
    List<PayEntry> payments = const [],
    bool overrideCreditLimit = false,
    String? editInvoice,
  }) async {
    final isEdit = editInvoice != null;
    if (isEdit) _requireAdmin();

    if (lines.isEmpty) {
      throw ArgumentError('Add at least one item');
    }
    for (final line in lines) {
      if (line.qty <= 0.0) {
        throw ArgumentError('"${line.itemName}" ki qty 0 se zyada honi chahiye');
      }
      if (line.unitPrice < 0.0) {
        throw ArgumentError('"${line.itemName}" ka rate negative nahi ho sakta');
      }
    }

    final subtotal = lines.fold<double>(0, (sum, l) => sum + l.amount);
    // Mirrors DiscountCalculator.compute() inline (kept in sync with
    // lib/utils/discount_calculator.dart).
    final safeSubtotal = subtotal < 0 ? 0.0 : subtotal;
    final discount = discountInput.clamp(0.0, safeSubtotal);
    final total = (safeSubtotal - discount) < 0 ? 0.0 : (safeSubtotal - discount);
    // Split Payment: when rows exist their sum IS the paid amount.
    final cleanRows = cleanPayments(payments);
    final paid = effectivePaidInput(cleanRows, paidInput).clamp(0.0, total);
    final due = (total - paid) < 0 ? 0.0 : (total - paid);

    if (due > 0.009 && customerName.trim().isEmpty) {
      throw ArgumentError('Due amount ke liye Customer zaroori hai');
    }

    final db = await AppDatabase.instance.database;

    // `final` so they stay promotable (non-null) inside the transaction closure.
    final Sale? original;
    final List<SaleItem> originalItems;
    if (isEdit) {
      final rows = await db.query('sales', where: 'invoice=?', whereArgs: [editInvoice], limit: 1);
      if (rows.isEmpty) {
        throw ArgumentError('Ye bill nahi mila — shayad delete ho chuka hai');
      }
      original = Sale.fromMap(rows.first);
      final itemRows =
          await db.query('sale_items', where: 'invoice=?', whereArgs: [editInvoice], orderBy: 'id ASC');
      originalItems = itemRows.map(SaleItem.fromMap).toList();
    } else {
      original = null;
      originalItems = const <SaleItem>[];
    }

    final method = paymentMethodLabel(paid: paid, payments: cleanRows, singleMethod: paymentMethod);
    final customers = await CustomerRepository.instance.listAll();
    final customer =
        customers.where((c) => c.name.toLowerCase() == customerName.trim().toLowerCase()).firstOrNull;

    // Credit limit (0 = no limit set). Only a KNOWN customer can exceed it.
    if (customer != null && customer.creditLimit > 0.0 && !overrideCreditLimit) {
      var projected = customer.balance + due;
      // Editing: this bill's OWN old due is already inside `balance`.
      if (original != null && original.customerId == customer.id) {
        projected -= (original.total - original.paid);
      }
      if (projected > customer.creditLimit + 0.009) {
        throw SaleCreditLimitException(customer.name, customer.creditLimit, projected);
      }
    }

    final invoice = editInvoice ?? nextInvoiceNumber(saleDateMillis);
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final diff = original != null ? saleEditDiff(lines, originalItems) : null;
      bool needsStock(int index) => diff == null || diff.changedLineIndices.contains(index);

      if (original != null) {
        // Only original rows that were changed/removed give stock back —
        // untouched rows keep the stock they already deducted.
        for (final si in diff!.itemsToReverse) {
          final pr = await txn.query('products', where: 'barcode=?', whereArgs: [si.barcode], limit: 1);
          final product = pr.isEmpty ? null : Product.fromMap(pr.first);
          await _increaseStock(txn, si.barcode, saleItemSmallestQty(si, product), now);
        }
        // Reverse the original due (or advance) — nonzero either way.
        final originalOutstanding = original.total - original.paid;
        if (original.customerId != null && originalOutstanding.abs() > 0.009) {
          await _adjustCustomerBalance(txn, original.customerId!, -originalOutstanding, now);
        }
        await txn.delete('sale_items', where: 'invoice=?', whereArgs: [invoice]);
        await _deleteCashByReference(txn, invoice);
      }

      // Stock availability check per product (after any reversal above) —
      // aborts the whole save if short. Only lines that will deduct stock
      // are checked, so an untouched line whose product was since deleted
      // can't block an unrelated edit.
      final indicesByBarcode = <String, List<int>>{};
      for (var i = 0; i < lines.length; i++) {
        indicesByBarcode.putIfAbsent(lines[i].barcode, () => <int>[]).add(i);
      }
      final productByBarcode = <String, Product>{};
      for (final entry in indicesByBarcode.entries) {
        final anyNeedsStock = entry.value.any(needsStock);
        final rows = await txn.query('products', where: 'barcode=?', whereArgs: [entry.key], limit: 1);
        if (rows.isEmpty) {
          if (anyNeedsStock) {
            throw SaleStockException('Stock badal gaya hai — item nahi mila. Bill dobara check karen.');
          }
          continue;
        }
        final product = Product.fromMap(rows.first);
        if (anyNeedsStock) {
          final needed = entry.value
              .where(needsStock)
              .fold<double>(0, (sum, i) => sum + product.toSmallestUnits(lines[i].qty, lines[i].unit));
          if (product.stock < needed) {
            throw SaleStockException(
              'Stock badal gaya hai — "${product.name}" mein sirf ${_trimNum(product.stock)} ${product.smallestUnitName()} available hai. Bill dobara check karen.',
            );
          }
        }
        productByBarcode[entry.key] = product;
      }

      int? customerId = customer?.id;
      if (customerId == null && customerName.trim().isNotEmpty) {
        customerId = await txn.insert('customers', {
          'name': customerName.trim(),
          'phone': '',
          'creditLimit': 0.0,
          'openingBalance': 0.0,
          'balance': 0.0,
          'updatedAt': now,
          'dirty': 1,
        });
      }

      // A brand-new bill must not reuse an invoice number (double-tap /
      // retry); an edit reuses its own row, so it is exempt.
      if (original == null) {
        final dup = await txn.query('sales', where: 'invoice=?', whereArgs: [invoice], limit: 1);
        if (dup.isNotEmpty) {
          throw SaleStockException('Invoice number "$invoice" pehle se mojood hai. Dobara try karen.');
        }
      }

      final sale = Sale(
        invoice: invoice,
        customerId: customerId,
        subtotal: subtotal,
        discount: discount,
        tax: 0.0,
        total: total,
        paid: paid,
        paymentMethod: method.toLowerCase(),
        saleType: saleType,
        createdAt: saleDateMillis,
        // A returned sale stays returned through an edit.
        status: original?.status ?? 'active',
        updatedAt: now,
      );
      if (original != null) {
        // True in-place UPDATE keyed by invoice (never delete + re-insert).
        await txn.update('sales', sale.toMap(), where: 'invoice=?', whereArgs: [invoice]);
      } else {
        await txn.insert('sales', sale.toMap());
      }

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // An untouched line keeps the factor frozen when it was first sold;
        // re-stamping it with today's ladder would make a later
        // delete/return reverse a different qty than was deducted.
        final unchangedOriginal = diff?.unchangedOriginalByIndex[i];
        final factor = unchangedOriginal != null
            ? unchangedOriginal.conversionFactor
            : (productByBarcode[line.barcode]?.smallestPerUnitOf(line.unit) ?? 0.0);
        await txn.insert('sale_items', {
          'invoice': invoice,
          'barcode': line.barcode,
          'product': line.itemName,
          'qty': line.qty,
          'unit': line.unit,
          'unitPrice': line.unitPrice,
          'cost': line.cost,
          'amount': line.amount,
          'conversionFactor': factor,
        });
      }

      await _enqueueSync(txn, 'sale', invoice, original != null ? 'update' : 'create', {
        'invoice': invoice,
        'customerId': customerId,
        'total': total,
        'paid': paid,
        'itemCount': lines.length,
      });

      for (var i = 0; i < lines.length; i++) {
        if (!needsStock(i)) continue;
        final line = lines[i];
        final product = productByBarcode[line.barcode];
        if (product == null) continue;
        final smallest = product.toSmallestUnits(line.qty, line.unit);
        await txn.rawUpdate(
          'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [smallest, now, line.barcode],
        );
      }

      if (customerId != null && (total - paid).abs() > 0.009) {
        await _adjustCustomerBalance(txn, customerId, total - paid, now);
      }

      // One cash-in row per payment method (Split Payment); the single-method
      // path is exactly the old one-row behaviour. Dated with the SALE's date
      // (not today) so a back-dated bill shows in the Cash Register on its own
      // day.
      final effectiveRows = cleanRows.isNotEmpty
          ? cleanRows
          : (paid > 0.009 ? [PayEntry(paymentMethod, paid)] : const <PayEntry>[]);
      if (paid > 0.009) {
        // Rows can add up to more than the bill (paid was clamped to total):
        // trim the overshoot off the last rows so cash-in == paid exactly.
        var remaining = paid;
        for (final row in effectiveRows) {
          if (remaining <= 0.009) break;
          final amount = row.amount > remaining ? remaining : row.amount;
          remaining -= amount;
          final cashTx = CashTransaction(
            type: 'IN',
            method: row.method.toLowerCase(),
            amount: amount,
            reason: 'Sale',
            reference: invoice,
            createdAt: saleDateMillis,
          );
          final cashTxId = await txn.insert('cash_transactions', cashTx.toMap());
          await _enqueueSync(txn, 'cash_transaction', cashTxId.toString(), 'create', cashTx.toMap());
        }
      }
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await _notify();
    await _logAudit(
      isEdit ? 'sale_edit' : 'sale_create',
      invoice,
      'total=$total paid=$paid method=$method customer=${customerName.trim().isEmpty ? 'walk-in' : customerName.trim()}',
    );
    return invoice;
  }

  // ------------------------------------------------------------ Delete / Return

  /// Deletes a saved sale (admin only): gives its stock back, reverses its
  /// due/advance on the customer, and removes the bill, its items and its cash
  /// rows — one transaction. Mirrors `deleteSale()`.
  Future<void> deleteSale(String invoice) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    Sale? deleted;
    await db.transaction((txn) async {
      final rows = await txn.query('sales', where: 'invoice=?', whereArgs: [invoice], limit: 1);
      if (rows.isEmpty) throw ArgumentError('Ye bill nahi mila');
      final sale = Sale.fromMap(rows.first);
      final itemRows = await txn.query('sale_items', where: 'invoice=?', whereArgs: [invoice]);
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final r in itemRows) {
        final si = SaleItem.fromMap(r);
        final pr = await txn.query('products', where: 'barcode=?', whereArgs: [si.barcode], limit: 1);
        final product = pr.isEmpty ? null : Product.fromMap(pr.first);
        await _increaseStock(txn, si.barcode, saleItemSmallestQty(si, product), now);
      }
      final outstanding = sale.total - sale.paid;
      if (sale.customerId != null && outstanding.abs() > 0.009) {
        await _adjustCustomerBalance(txn, sale.customerId!, -outstanding, now);
      }
      await txn.delete('sale_items', where: 'invoice=?', whereArgs: [invoice]);
      await txn.delete('sales', where: 'invoice=?', whereArgs: [invoice]);
      await _deleteCashByReference(txn, invoice);
      await _enqueueSync(txn, 'sale', invoice, 'delete', {'invoice': invoice});
      deleted = sale;
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await _notify();
    final s = deleted;
    if (s != null) {
      await _logAudit('sale_delete', invoice,
          'total=${s.total} paid=${s.paid} customerId=${s.customerId ?? 'walk-in'}');
    }
  }

  /// Returns a saved sale (admin only): stock back, one `returns` row per
  /// line (so it shows in Sale Returns reports), customer due reversed, a
  /// dated cash-OUT reversal, and status -> 'returned'. The original sale's
  /// cash history is kept. Mirrors `returnSale()` (HistoryActivity).
  Future<void> returnSale(String invoice) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    Sale? returned;
    await db.transaction((txn) async {
      final rows = await txn.query('sales', where: 'invoice=?', whereArgs: [invoice], limit: 1);
      if (rows.isEmpty) throw ArgumentError('Ye bill nahi mila');
      final sale = Sale.fromMap(rows.first);
      if (sale.status == 'returned') throw ArgumentError('Ye sale pehle hi return ho chuki hai');
      final itemRows = await txn.query('sale_items', where: 'invoice=?', whereArgs: [invoice]);
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final r in itemRows) {
        final si = SaleItem.fromMap(r);
        final pr = await txn.query('products', where: 'barcode=?', whereArgs: [si.barcode], limit: 1);
        final product = pr.isEmpty ? null : Product.fromMap(pr.first);
        await _increaseStock(txn, si.barcode, saleItemSmallestQty(si, product), now);
        final ret = ReturnLine(
          reference: invoice,
          type: 'sale',
          barcode: si.barcode,
          qty: si.qty,
          amount: si.amount,
          createdAt: now,
        );
        final retId = await txn.insert('returns', ret.toMap());
        await _enqueueSync(txn, 'return', retId.toString(), 'create', ret.toMap());
      }

      final outstanding = sale.total - sale.paid;
      if (sale.customerId != null && outstanding.abs() > 0.009) {
        await _adjustCustomerBalance(txn, sale.customerId!, -outstanding, now);
      }

      // Dated reversal instead of deleting the original cash rows: keeps the
      // sale day's history and leaves a visible trace of the return today.
      if (sale.paid > 0.009) {
        final cashRows = await txn.query('cash_transactions', where: 'reference=?', whereArgs: [invoice]);
        final originalTotal = cashRows.fold<double>(0, (sum, r) => sum + (r['amount'] as num).toDouble());
        if (originalTotal > 0.009) {
          final ratio = (sale.paid / originalTotal).clamp(0.0, 1.0);
          for (final r in cashRows) {
            final portion = (r['amount'] as num).toDouble() * ratio;
            if (portion <= 0.009) continue;
            final reversal = CashTransaction(
              type: 'OUT',
              method: (r['method'] as String?) ?? 'cash',
              amount: portion,
              reason: 'Sale Return',
              reference: 'return:$invoice',
              createdAt: now,
            );
            final id = await txn.insert('cash_transactions', reversal.toMap());
            await _enqueueSync(txn, 'cash_transaction', id.toString(), 'create', reversal.toMap());
          }
        }
      }

      await txn.update(
        'sales',
        {'status': 'returned', 'updatedAt': now, 'dirty': 1},
        where: 'invoice=?',
        whereArgs: [invoice],
      );
      await _enqueueSync(txn, 'sale', invoice, 'update', {
        'invoice': invoice,
        'customerId': sale.customerId,
        'total': sale.total,
        'paid': sale.paid,
        'status': 'returned',
      });
      returned = sale;
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await _notify();
    final s = returned;
    if (s != null) {
      await _logAudit('sale_return', invoice, 'total=${s.total} paid=${s.paid}');
    }
  }

  // --------------------------------------------------------- Customer's rate

  /// Last rate charged to [customerId] for [barcode] (most recent, returned
  /// sales excluded) — powers "use this customer's usual rate". Any DB error
  /// just means "no suggestion". Mirrors `lastRateForCustomerItem()`.
  Future<CustomerItemRate?> lastRateForCustomerItem(int customerId, String barcode) async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.rawQuery(
        'SELECT si.unitPrice AS unitPrice, si.unit AS unit FROM sale_items si '
        'JOIN sales s ON si.invoice = s.invoice '
        "WHERE si.barcode = ? AND s.customerId = ? AND s.status != 'returned' "
        'ORDER BY s.createdAt DESC LIMIT 1',
        [barcode, customerId],
      );
      if (rows.isEmpty) return null;
      return CustomerItemRate(
        (rows.first['unitPrice'] as num).toDouble(),
        (rows.first['unit'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- Quick Sale

  /// Mirrors `saveQuickSale()` (RoomSaleRepository): single item, retail,
  /// no discount. Blank customer = cash (fully paid); a name = 100% credit.
  /// Whole write path is one transaction. Throws [SaleStockException],
  /// [SaleCreditLimitException] (unless [overrideCreditLimit]) or
  /// [ArgumentError] for a bad qty/rate.
  Future<QuickSaleSaveResult> saveQuickSale({
    required Product product,
    required double qty,
    required double price,
    required String unit,
    required String customerName,
    bool overrideCreditLimit = false,
  }) async {
    if (qty <= 0.0) throw ArgumentError('Qty 0 se zyada honi chahiye');
    if (price < 0.0) throw ArgumentError('Rate negative nahi ho sakta');

    final name = customerName.trim();
    final isCredit = name.isNotEmpty;
    final amount = qty * price;

    if (isCredit && !overrideCreditLimit) {
      final customers = await CustomerRepository.instance.listAll();
      final existing = customers.where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (existing != null && existing.creditLimit > 0.0) {
        final projected = existing.balance + amount;
        if (projected > existing.creditLimit + 0.009) {
          throw SaleCreditLimitException(existing.name, existing.creditLimit, projected);
        }
      }
    }

    final db = await AppDatabase.instance.database;
    var resultInvoice = '';

    await db.transaction((txn) async {
      final rows = await txn.query('products', where: 'barcode=?', whereArgs: [product.barcode], limit: 1);
      if (rows.isEmpty) throw SaleStockException('Stock badal gaya hai, dobara try karen');
      final current = Product.fromMap(rows.first);
      final smallest = current.toSmallestUnits(qty, unit);
      if (current.stock < smallest) throw SaleStockException('Stock badal gaya hai, dobara try karen');
      if (!current.isValidSmallestQty(smallest)) {
        throw ArgumentError('Qty ($qty $unit) whole ${current.smallestUnitName()} mein convert nahi hoti');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      int? customerId;
      if (isCredit) {
        final custRows = await txn.query('customers', where: 'LOWER(name)=?', whereArgs: [name.toLowerCase()], limit: 1);
        if (custRows.isNotEmpty) {
          customerId = custRows.first['id'] as int;
        } else {
          customerId = await txn.insert('customers', {
            'name': name,
            'phone': '',
            'creditLimit': 0.0,
            'openingBalance': 0.0,
            'balance': 0.0,
            'updatedAt': now,
            'dirty': 1,
          });
        }
      }

      final factor = current.smallestUnitFactor();
      final costPerSmallest = factor > 0 ? current.cost / factor : current.cost;
      final lineCost = smallest * costPerSmallest;

      final invoice = nextInvoiceNumber(now);
      final dup = await txn.query('sales', where: 'invoice=?', whereArgs: [invoice], limit: 1);
      if (dup.isNotEmpty) {
        throw SaleStockException('Invoice number "$invoice" pehle se mojood hai. Dobara try karen.');
      }

      final paid = isCredit ? 0.0 : amount;
      final method = isCredit ? 'credit' : 'cash';

      await txn.insert(
        'sales',
        Sale(
          invoice: invoice,
          customerId: customerId,
          subtotal: amount,
          discount: 0.0,
          tax: 0.0,
          total: amount,
          paid: paid,
          paymentMethod: method,
          saleType: 'retail',
          createdAt: now,
          updatedAt: now,
        ).toMap(),
      );
      await txn.insert('sale_items', {
        'invoice': invoice,
        'barcode': current.barcode,
        'product': current.name,
        'qty': qty,
        'unit': unit,
        'unitPrice': price,
        'cost': lineCost,
        'amount': amount,
        'conversionFactor': current.smallestPerUnitOf(unit),
      });

      await txn.rawUpdate(
        'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
        [smallest, now, current.barcode],
      );
      if (isCredit && customerId != null) {
        await txn.rawUpdate('UPDATE customers SET balance = balance + ?, dirty = 1 WHERE id = ?', [amount, customerId]);
      }

      await _enqueueSync(txn, 'sale', invoice, 'create', {
        'invoice': invoice,
        'customerId': customerId,
        'total': amount,
        'paid': paid,
        'itemCount': 1,
        'quick': true,
      });

      if (paid > 0) {
        final cashTx = CashTransaction(
          type: 'IN',
          method: method,
          amount: paid,
          reason: 'Quick Sale',
          reference: invoice,
          createdAt: now,
        );
        final id = await txn.insert('cash_transactions', cashTx.toMap());
        await _enqueueSync(txn, 'cash_transaction', id.toString(), 'create', cashTx.toMap());
      }
      resultInvoice = invoice;
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await _notify();
    return QuickSaleSaveResult(resultInvoice, isCredit);
  }

  /// Best-selling product names over the last 30 days (top 5), used to put
  /// them first in the Quick Sale item list. Mirrors `topProductNames()`;
  /// any DB error just returns an empty list, like the Kotlin version.
  Future<List<String>> topProductNames() async {
    try {
      final db = await AppDatabase.instance.database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final since = now - const Duration(days: 30).inMilliseconds;
      final rows = await db.rawQuery(
        "SELECT product, SUM(qty) AS totalQty FROM sale_items "
        "WHERE invoice IN (SELECT invoice FROM sales WHERE createdAt BETWEEN ? AND ? AND status != 'returned') "
        "GROUP BY product ORDER BY totalQty DESC LIMIT 5",
        [since, now],
      );
      return rows.map((r) => r['product'] as String).toList();
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------ Hold / Recall

  /// Sale holds only (`HOLD...`), newest first. Purchase holds (`PHOLD...`)
  /// live in the same table and must never show up here.
  Future<List<HeldBill>> heldBills() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'held_bills',
      where: "holdId LIKE 'HOLD%'",
      orderBy: 'createdAt DESC',
    );
    return rows.map(HeldBill.fromMap).toList();
  }

  /// Mirrors HoldBillUseCase: id = "HOLD" + millis.
  Future<void> holdBill(String payload) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('held_bills', HeldBill(holdId: 'HOLD$now', payload: payload, createdAt: now).toMap());
  }

  Future<void> deleteHeldBill(HeldBill bill) async {
    final db = await AppDatabase.instance.database;
    await db.delete('held_bills', where: 'holdId=?', whereArgs: [bill.holdId]);
  }

  Future<void> _enqueueSync(Transaction txn, String entityType, String entityId, String operation, Map<String, Object?> payload) async {
    await txn.insert('sync_queue', {
      'entityType': entityType,
      'entityId': entityId,
      'operation': operation,
      'payloadJson': jsonEncode(payload),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'retryCount': 0,
    });
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
