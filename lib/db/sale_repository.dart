import 'dart:async';

import '../models/misc_entities.dart';
import '../models/product.dart';
import '../models/sale.dart';
import 'app_database.dart';
import 'customer_repository.dart';
import 'product_repository.dart';

/// One line the user has added to the sale bill before saving — mirrors the
/// per-line data SaleActivity.kt keeps in its `lines` list.
class SaleLine {
  final String itemName;
  final String barcode;
  final double qty;
  final String unit;
  final double unitPrice;
  final double cost;
  final double amount;

  const SaleLine({
    required this.itemName,
    required this.barcode,
    required this.qty,
    required this.unit,
    required this.unitPrice,
    required this.cost,
    required this.amount,
  });
}

/// Thrown to abort the transaction early (e.g. stock changed under us) —
/// mirrors SaveAbortedException in SaleActivity.kt.
class SaleStockException implements Exception {
  final String message;
  SaleStockException(this.message);
  @override
  String toString() => message;
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

  /// Mirrors `saveSale()`'s transaction body: checks stock for every line
  /// against current product state, creates the customer if new, inserts
  /// the sale + items, decreases stock per line, updates the customer's
  /// balance for any due amount, and records a cash transaction if anything
  /// was paid. Throws [SaleStockException] if any line's stock is no longer
  /// available (mirrors the Kotlin app rejecting the save and asking the
  /// user to recheck the bill, rather than silently going negative).
  Future<String> saveSale({
    required List<SaleLine> lines,
    required String customerName,
    required double discountInput,
    required double paidInput,
    required String saleType, // 'retail' or 'wholesale'
    required int saleDateMillis,
    String paymentMethod = 'Cash',
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('Add at least one item');
    }

    final subtotal = lines.fold<double>(0, (sum, l) => sum + l.amount);
    // Mirrors DiscountCalculator.compute() inline (kept in sync with
    // lib/utils/discount_calculator.dart — import that instead if you also
    // need to preview totals in the UI before saving).
    final safeSubtotal = subtotal < 0 ? 0.0 : subtotal;
    final discount = discountInput.clamp(0.0, safeSubtotal);
    final total = (safeSubtotal - discount) < 0 ? 0.0 : (safeSubtotal - discount);
    final paid = paidInput.clamp(0.0, total);
    final due = (total - paid) < 0 ? 0.0 : (total - paid);

    if (due > 0.009 && customerName.trim().isEmpty) {
      throw ArgumentError('Due amount ke liye Customer zaroori hai');
    }

    final method = paid <= 0.009 ? 'credit' : paymentMethod;
    final customers = await CustomerRepository.instance.listAll();
    final customer =
        customers.where((c) => c.name.toLowerCase() == customerName.trim().toLowerCase()).firstOrNull;

    final db = await AppDatabase.instance.database;
    final invoice = nextInvoiceNumber(saleDateMillis);
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      // Stock availability check for every line before writing anything —
      // mirrors the Kotlin app grouping lines by barcode and validating
      // against current stock first, aborting the whole save if short.
      final neededByBarcode = <String, double>{};
      final productByBarcode = <String, Product>{};
      for (final line in lines) {
        final rows = await txn.query('products', where: 'barcode=?', whereArgs: [line.barcode], limit: 1);
        if (rows.isEmpty) {
          throw SaleStockException('Stock badal gaya hai — item nahi mila. Bill dobara check karen.');
        }
        final product = Product.fromMap(rows.first);
        productByBarcode[line.barcode] = product;
        final smallest = product.toSmallestUnits(line.qty, line.unit);
        neededByBarcode[line.barcode] = (neededByBarcode[line.barcode] ?? 0) + smallest;
      }
      for (final entry in neededByBarcode.entries) {
        final product = productByBarcode[entry.key]!;
        if (product.stock < entry.value) {
          throw SaleStockException(
            'Stock badal gaya hai — "${product.name}" mein sirf ${_trimNum(product.stock)} ${product.smallestUnitName()} available hai. Bill dobara check karen.',
          );
        }
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
        updatedAt: now,
      );
      await txn.insert('sales', sale.toMap());

      for (final line in lines) {
        await txn.insert('sale_items', {
          'invoice': invoice,
          'barcode': line.barcode,
          'product': line.itemName,
          'qty': line.qty,
          'unit': line.unit,
          'unitPrice': line.unitPrice,
          'cost': line.cost,
          'amount': line.amount,
        });
      }

      await _enqueueSync(txn, 'sale', invoice, 'create', {
        'invoice': invoice,
        'customerId': customerId,
        'total': total,
        'paid': paid,
        'itemCount': lines.length,
      });

      for (final line in lines) {
        final product = productByBarcode[line.barcode]!;
        final smallest = product.toSmallestUnits(line.qty, line.unit);
        await txn.rawUpdate(
          'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [smallest, now, line.barcode],
        );
      }

      if (customerId != null && paid < total) {
        await txn.rawUpdate(
          'UPDATE customers SET balance = balance + ?, dirty = 1 WHERE id = ?',
          [total - paid, customerId],
        );
      }

      if (paid > 0) {
        final cashTx = CashTransaction(
          type: 'IN',
          method: method.toLowerCase(),
          amount: paid,
          reason: 'Sale',
          reference: invoice,
          createdAt: now,
        );
        final cashTxId = await txn.insert('cash_transactions', cashTx.toMap());
        await _enqueueSync(txn, 'cash_transaction', cashTxId.toString(), 'create', cashTx.toMap());
      }
    });

    await ProductRepository.instance.refresh();
    await CustomerRepository.instance.refresh();
    await _notify();
    return invoice;
  }

  Future<void> _enqueueSync(dynamic txn, String entityType, String entityId, String operation, Map<String, Object?> payload) async {
    await txn.insert('sync_queue', {
      'entityType': entityType,
      'entityId': entityId,
      'operation': operation,
      'payloadJson': payload.toString(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'retryCount': 0,
    });
  }

  String _trimNum(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
