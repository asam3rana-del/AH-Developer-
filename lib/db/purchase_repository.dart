
import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import '../models/misc_entities.dart';
import '../models/product.dart';
import '../models/purchase.dart';
import '../models/stock_movement.dart' show MovementType;
import '../services/session.dart';
import '../utils/split_payment.dart';
import '../utils/stock_touch_policy.dart';
import 'app_database.dart';
import 'party_transaction_repository.dart' show addPurchaseLineCost, purchaseItemSmallestQty, reversePurchaseLineCost;
import 'product_repository.dart';
import 'sale_repository.dart' show subtractLinkedPaid;
import '../sync/sync_queue_helper.dart';
import 'stock_ledger.dart';
import 'supplier_repository.dart';

/// One line the user has added to the purchase before saving — mirrors
/// `data class PurchaseLine` in PurchaseRepository.kt.
///
/// [retailRate] / [wholesaleRate]: 0.0 = "product ka rate na badlo"; nonzero = purchase ke waqt product ka
/// salePrice / wholesalePrice update (primary-unit basis, jaise Product ke apne rates).
class PurchaseLine {
  final String itemName;
  final String? barcode;
  final double qty;
  final String unit;
  final double rate;
  final double amount;
  final double retailRate;
  final double wholesaleRate;

  const PurchaseLine({
    required this.itemName,
    required this.barcode,
    required this.qty,
    required this.unit,
    required this.rate,
    required this.amount,
    this.retailRate = 0.0,
    this.wholesaleRate = 0.0,
  });
}

/// Saved bill edit karne ke liye sab kuch (Kotlin `PurchaseEditData`).
class PurchaseEditData {
  final Purchase purchase;
  final List<PurchaseItem> items;
  final String supplierName;
  final List<PurchaseLine> lines;

  /// 'Cash' ya 'Bank' — bill ki pehli cash-out row ka method (Payment chip ke liye).
  final String paymentMethod;

  /// Sirf tab bhari hoti hai jab bill 2+ payment rows se bhara gaya tha (Split Payment dialog dobara kholne ke
  /// liye); normal single-method bill par khali.
  final List<PayEntry> payments;

  const PurchaseEditData({
    required this.purchase,
    required this.items,
    required this.supplierName,
    required this.lines,
    this.paymentMethod = 'Cash',
    this.payments = const [],
  });
}

/// Kisi product ki pichli khareed ka asli rate + jis unit mein likha gaya tha (Kotlin `Pair<Double, String>`).
class LastPurchaseRate {
  final double rate;
  final String unit;
  const LastPurchaseRate(this.rate, this.unit);
}

/// Save par wo galtiyan jo user ko seedhe lafzon mein dikhani hain (toString == message; "Bad state:" nahi).
class PurchaseSaveException implements Exception {
  final String message;
  const PurchaseSaveException(this.message);
  @override
  String toString() => message;
}

/// Kotlin `checkDuplicateAndProceed` ka match rule: same supplier (bara-chhota farq nahi) + same total +
/// same BILL DATE (calendar din; koi time window nahi). Pure => test/purchase_screen_test.dart.
bool isDuplicatePurchase({
  required String candidateSupplier,
  required double candidateTotal,
  required DateTime candidateDate,
  required String wantedSupplier,
  required double wantedTotal,
  required DateTime wantedDate,
}) {
  if (candidateSupplier.trim().toLowerCase() != wantedSupplier.trim().toLowerCase()) return false;
  if ((candidateTotal - wantedTotal).abs() > 0.009) return false;
  return candidateDate.year == wantedDate.year &&
      candidateDate.month == wantedDate.month &&
      candidateDate.day == wantedDate.day;
}

/// Kotlin `SavePurchaseUseCase` ki validation: khali bill, qty <= 0, negative rate. Pehli galti ka paigham,
/// sab theek ho to null. Pure.
String? validatePurchaseLines(List<PurchaseLine> lines) {
  if (lines.isEmpty) return 'Kam az kam ek item add karen';
  for (final l in lines) {
    if (l.qty <= 0.0) return '"${l.itemName}" ki qty 0 se zyada honi chahiye';
    if (l.rate < 0.0) return '"${l.itemName}" ka rate negative nahi ho sakta';
  }
  return null;
}

/// Bill ki paid raqam aur cash-out rows. [paid] hamesha `0..grandTotal` mein; rows ka jama paid se zyada ho
/// to aakhri rows se ghata diya jata hai (cash-out == paid), phir bill se linked payments ([linkedPaid],
/// jinki apni cash row hai) pehli rows se kaat li jati hain taake wo paisa do baar na gine.
/// Kotlin `savePurchase` ka `effectivePayments` + `linkedToSkip` loop.
class PurchaseCashPlan {
  final double paid;
  final List<PayEntry> cashRows;
  const PurchaseCashPlan(this.paid, this.cashRows);
}

/// Pure => test/purchase_screen_test.dart.
PurchaseCashPlan planPurchaseCash({
  required double grandTotal,
  required double amountPaid,
  required String singleMethod,
  required List<PayEntry> payments,
  double linkedPaid = 0.0,
}) {
  final clean = cleanPayments(payments);
  final paid = effectivePaidInput(clean, amountPaid).clamp(0.0, grandTotal < 0 ? 0.0 : grandTotal).toDouble();
  final source = clean.isNotEmpty ? clean : (paid > 0.009 ? [PayEntry(singleMethod, paid)] : <PayEntry>[]);
  var remaining = paid;
  final trimmed = <PayEntry>[];
  for (final row in source) {
    if (remaining <= 0.009) break;
    final amount = row.amount > remaining ? remaining : row.amount;
    remaining -= amount;
    trimmed.add(PayEntry(row.method, amount));
  }
  return PurchaseCashPlan(paid, subtractLinkedPaid(trimmed, linkedPaid));
}

class PurchaseRepository {
  PurchaseRepository._();
  static final PurchaseRepository instance = PurchaseRepository._();

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void _requireAdmin() {
    if (!Session.isAdmin) throw const PurchaseSaveException('Sirf Admin ye action kar sakta hai');
  }

  /// Mirrors `genBillNo()`: PUR-<MonYY>-0001, incrementing per month.
  Future<String> nextBillNo() async {
    final db = await AppDatabase.instance.database;
    final prefix = 'PUR-${DateFormat('MMMyy').format(DateTime.now())}-';
    final rows = await db.query('purchases', columns: ['billNo']);
    final existing = rows.map((r) => r['billNo'] as String).toSet();
    var seq = existing.where((b) => b.startsWith(prefix)).length + 1;
    var candidate = '$prefix${seq.toString().padLeft(4, '0')}';
    while (existing.contains(candidate)) {
      seq++;
      candidate = '$prefix${seq.toString().padLeft(4, '0')}';
    }
    return candidate;
  }

  Future<List<Purchase>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('purchases', orderBy: 'createdAt DESC');
    return rows.map(Purchase.fromMap).toList();
  }

  // ------------------------------------------------------------------ edit

  /// Saved bill edit karne ke liye kholna (admin only). Mirrors `LoadPurchaseForEditUseCase`.
  Future<PurchaseEditData?> loadForEdit(String billNo) async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;
    final pr = await db.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
    if (pr.isEmpty) return null;
    final purchase = Purchase.fromMap(pr.first);
    final itemRows = await db.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo], orderBy: 'id ASC');
    final items = itemRows.map(PurchaseItem.fromMap).toList();

    var supplierName = '';
    if (purchase.supplierId != null) {
      final s = await db.query('suppliers', where: 'id = ?', whereArgs: [purchase.supplierId], limit: 1);
      if (s.isNotEmpty) supplierName = (s.first['name'] as String?) ?? '';
    }

    final lines = <PurchaseLine>[];
    for (final pi in items) {
      final prod = pi.barcode.isEmpty ? null : await _productOrNull(db, pi.barcode);
      lines.add(PurchaseLine(
        // Line par jama naam pehle; sirf purani rows (itemName == '') ke liye live product naam.
        itemName: pi.itemName.trim().isNotEmpty ? pi.itemName : (prod?.name ?? pi.barcode),
        barcode: pi.barcode.isEmpty ? null : pi.barcode,
        qty: pi.qty,
        unit: pi.unit.isNotEmpty ? pi.unit : (prod?.unit ?? ''),
        rate: pi.unitCost,
        amount: pi.amount,
        retailRate: pi.retailRate,
        wholesaleRate: pi.wholesaleRate,
      ));
    }

    // Bill ki apni cash-out rows (purani pehle) — 2+ rows = split payment.
    final cashRows = await db.query('cash_transactions',
        where: 'reference = ? AND type = ? AND reason = ?', whereArgs: [billNo, 'OUT', 'Purchase'], orderBy: 'id ASC');
    final payments = cashRows
        .map((r) => PayEntry(_methodTitle((r['method'] as String?) ?? 'cash'), (r['amount'] as num).toDouble()))
        .toList();
    final method = payments.isEmpty ? 'Cash' : payments.first.method;

    return PurchaseEditData(
      purchase: purchase,
      items: items,
      supplierName: supplierName,
      lines: lines,
      paymentMethod: method,
      payments: payments.length >= 2 ? payments : const <PayEntry>[],
    );
  }

  static String _methodTitle(String m) => m.toLowerCase() == 'bank' ? 'Bank' : 'Cash';

  Future<Product?> _productOrNull(DatabaseExecutor ex, String barcode) async {
    if (barcode.isEmpty) return null;
    final r = await ex.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    return r.isEmpty ? null : Product.fromMap(r.first);
  }

  // ------------------------------------------------------------ rate / duplicates

  /// Is product ki sab se haali PICHLI khareed (chal rahi edit wala bill [excludeBillNo] chhod kar) ka
  /// asli rate + unit. Running weighted-average cost nahi — jo supplier ne asal mein charge kiya.
  Future<LastPurchaseRate?> findLastPurchaseRate(String barcode, {String? excludeBillNo}) async {
    if (barcode.trim().isEmpty) return null;
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT pi.unitCost AS unitCost, pi.unit AS unit FROM purchase_items pi '
      'JOIN purchases p ON p.billNo = pi.billNo '
      'WHERE pi.barcode = ? AND p.billNo != ? '
      'ORDER BY p.createdAt DESC, pi.id DESC LIMIT 1',
      [barcode, excludeBillNo ?? ''],
    );
    if (rows.isEmpty) return null;
    return LastPurchaseRate((rows.first['unitCost'] as num).toDouble(), (rows.first['unit'] as String?) ?? '');
  }

  /// Kotlin `PurchaseDao.findDuplicateBySupplierInvoice`: usi supplier ka wahi invoice number (khali kabhi
  /// match nahi). [excludeBillNo] = edit ho raha bill, taake khud se na takraye.
  Future<Purchase?> findDuplicateBySupplierInvoice(String supplierName, String invoiceNo, {String? excludeBillNo}) async {
    final inv = invoiceNo.trim();
    if (inv.isEmpty) return null;
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT pu.* FROM purchases pu LEFT JOIN suppliers s ON pu.supplierId = s.id '
      "WHERE pu.supplierInvoiceNo = ? AND pu.supplierInvoiceNo != '' AND pu.billNo != ? "
      'AND s.name = ? COLLATE NOCASE LIMIT 1',
      [inv, excludeBillNo ?? '', supplierName.trim()],
    );
    return rows.isEmpty ? null : Purchase.fromMap(rows.first);
  }

  /// Andaza-wala duplicate alert: usi supplier ka usi total ka, usi bill-date ka, na-return shuda bill.
  Future<Purchase?> findPossibleDuplicate({
    required String supplierName,
    required double total,
    required int dateMillis,
    String? excludeBillNo,
  }) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      'SELECT pu.*, s.name AS _sname FROM purchases pu LEFT JOIN suppliers s ON pu.supplierId = s.id '
      "WHERE pu.status != 'returned' ORDER BY pu.createdAt DESC",
    );
    final wantedDate = DateTime.fromMillisecondsSinceEpoch(dateMillis);
    for (final r in rows) {
      final p = Purchase.fromMap(r);
      if (excludeBillNo != null && p.billNo == excludeBillNo) continue;
      if (isDuplicatePurchase(
        candidateSupplier: (r['_sname'] as String?) ?? '',
        candidateTotal: p.total,
        candidateDate: DateTime.fromMillisecondsSinceEpoch(p.createdAt),
        wantedSupplier: supplierName,
        wantedTotal: total,
        wantedDate: wantedDate,
      )) {
        return p;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ save

  /// Mirrors `RoomPurchaseRepository.savePurchase()` — naya bill YA ([editBillNo] ho to) saved bill ka edit
  /// (admin only). Sab kuch ek transaction mein:
  ///
  ///  * naya supplier (agar naam nahi mila), bill + items (line ka naam / rate / frozen conversionFactor ke
  ///    saath), supplier ka baaqi (`total - paid`), bill ka apna payment row + cash-out rows.
  ///  * har line ka stock + weighted-average cost + ledger (`PURCHASE`), aur retail/wholesale rate agar likha ho.
  ///  * **Edit**: purana bill pehle utara jata hai, magar SIRF badli hui lines ka stock/cost ([purchaseEditDiff]);
  ///    jo line waisi hi rahi use na reverse na dobara add. Kisi reverse hone wali line ka stock baad ki sale se
  ///    kam ho chuka ho to poora edit rok diya jata hai.
  ///  * bill se linked payments (Make Payment > link to bill) `paid` mein pehle se hain — unka cash dobara nahi ginta.
  ///
  /// [payments] = Split Payment rows (khali = single method [paymentMethod] + [amountPaid]).
  Future<String> savePurchase({
    required String supplierName,
    required List<PurchaseLine> lines,
    required double amountPaid,
    required int purchaseDateMillis,
    String paymentMethod = 'Cash',
    String? editBillNo,
    String supplierInvoiceNo = '',
    List<PayEntry> payments = const [],
  }) async {
    final isEdit = editBillNo != null;
    if (isEdit) _requireAdmin();
    if (supplierName.trim().isEmpty) throw const PurchaseSaveException('Supplier name is required');
    final lineError = validatePurchaseLines(lines);
    if (lineError != null) throw PurchaseSaveException(lineError);

    final subtotal = lines.fold<double>(0, (sum, l) => sum + l.amount);
    // Paisa tak durust (poore rupee par round nahi): bill ka total supplier ke bill se match kare.
    final grandTotal = ((subtotal * 100).roundToDouble() / 100).clamp(0.0, double.infinity).toDouble();

    final db = await AppDatabase.instance.database;
    final suppliers = await SupplierRepository.instance.listAll();
    final existingSupplier = suppliers.where((s) => s.name.toLowerCase() == supplierName.trim().toLowerCase()).firstOrNull;
    int? supplierId = existingSupplier?.id;

    final billNo = editBillNo ?? await nextBillNo();
    final now = _now();
    final invoiceNo = supplierInvoiceNo.trim();
    String? auditDetails;

    await db.transaction((txn) async {
      // ---- original (edit)
      Purchase? original;
      var originalItems = <PurchaseItem>[];
      if (isEdit) {
        final pr = await txn.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
        if (pr.isEmpty) throw const PurchaseSaveException('Ye bill nahi mila — shayad delete ho chuka hai');
        original = Purchase.fromMap(pr.first);
        if (original.status == 'returned') throw const PurchaseSaveException('Returned purchase edit nahi ho sakti');
        final ir = await txn.query('purchase_items', where: 'billNo = ?', whereArgs: [billNo], orderBy: 'id ASC');
        originalItems = ir.map(PurchaseItem.fromMap).toList();
      }

      // ---- naya supplier
      if (supplierId == null) {
        final map = <String, Object?>{
          'name': supplierName.trim(),
          'phone': '',
          'openingBalance': 0.0,
          'balance': 0.0,
          'updatedAt': now,
          'dirty': 1,
        };
        final id = await txn.insert('suppliers', map);
        supplierId = id;
        await _enqueue(txn, 'supplier', 'supplier:$id', 'create', {...map, 'id': id});
      }
      final int sid = supplierId!;

      // ---- edit: purana bill utaro (sirf badli hui lines ka stock/cost)
      final diff = original != null ? purchaseEditDiff(lines, originalItems) : null;
      // Edit mein purani line ka stock baad ki sale se kam ho chuka ho to bhi edit allow hai (rate/unit theek
      // karne ke liye): stock beech mein minus ja sakta hai, aur AKHIR mein (nayi qty add hone ke baad) stock
      // minus raha tabhi edit rokta hai. [pendingValue] = us barcode ka stock-value jab tak weighted cost taiyar ho.
      final pendingValue = <String, double>{};
      final reversedBarcodes = <String>{};
      if (original != null) {
        for (final it in diff!.itemsToReverse) {
          await _reverseLine(txn, it, billNo, now, pendingValue);
          reversedBarcodes.add(it.barcode);
        }
        final originalOutstanding = original.total - original.paid;
        if (original.supplierId != null && originalOutstanding.abs() > 0.009) {
          await _adjustSupplierBalance(txn, original.supplierId!, -originalOutstanding, now);
        }
        await txn.delete('purchase_items', where: 'billNo = ?', whereArgs: [billNo]);
        await txn.delete('purchases', where: 'billNo = ?', whereArgs: [billNo]);
        await _deletePaymentsByReference(txn, billNo);
        await _deleteCashByReference(txn, billNo);
      }

      // ---- paid + cash plan (bill se linked payments pehle se `paid` mein hain)
      final linkedPaid = original != null ? await _linkedPaidForBill(txn, billNo) : 0.0;
      final plan = planPurchaseCash(
        grandTotal: grandTotal,
        amountPaid: amountPaid,
        singleMethod: paymentMethod,
        payments: payments,
        linkedPaid: linkedPaid,
      );
      final paid = plan.paid;
      final methodLabel = paymentMethodLabel(paid: paid, payments: cleanPayments(payments), singleMethod: paymentMethod);

      // ---- bill + items
      final purchase = Purchase(
        billNo: billNo,
        supplierId: sid,
        total: grandTotal,
        paid: paid,
        createdAt: purchaseDateMillis,
        subtotal: subtotal,
        discount: 0.0,
        updatedAt: now,
        dueDate: original?.dueDate ?? 0,
        supplierInvoiceNo: invoiceNo,
      );
      await txn.insert('purchases', purchase.toMap());

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final bc = line.barcode ?? '';
        final lineProduct = await _productOrNull(txn, bc);
        // Jo line bilkul nahi badli uski jama shuda conversionFactor barqarar — nayi ladder se dobara stamp
        // karne par baad ka delete/edit/return ghalat qty nikalta.
        final unchangedOriginal = diff?.unchangedOriginalByIndex[i];
        final factor = unchangedOriginal != null
            ? unchangedOriginal.conversionFactor
            : (lineProduct?.smallestPerUnitOf(line.unit) ?? 0.0);
        await txn.insert(
          'purchase_items',
          PurchaseItem(
            billNo: billNo,
            barcode: bc,
            qty: line.qty,
            unitCost: line.rate,
            amount: line.amount,
            unit: line.unit,
            conversionFactor: factor,
            itemName: line.itemName,
            retailRate: line.retailRate,
            wholesaleRate: line.wholesaleRate,
          ).toMap(),
        );
      }

      await _enqueue(txn, 'purchase', billNo, isEdit ? 'update' : 'create', {
        'billNo': billNo,
        'supplierId': sid,
        'total': grandTotal,
        'paid': paid,
        'itemCount': lines.length,
        'supplierInvoiceNo': invoiceNo,
      });

      // ---- stock + weighted-average cost + rates (sirf badli/nayi lines)
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final barcode = line.barcode;
        if (barcode == null || barcode.isEmpty) continue;
        final before = await _productOrNull(txn, barcode);
        if (before == null) continue;

        var touched = false;
        if (diff == null || diff.changedLineIndices.contains(i)) {
          final purchasedSmallest = before.toSmallestUnits(line.qty, line.unit);
          if (!before.isValidSmallestQty(purchasedSmallest)) {
            throw PurchaseSaveException(
              '"${before.name}" ke liye qty (${line.qty} ${line.unit}) whole ${before.smallestUnitName()} mein convert nahi hoti — qty check karen.',
            );
          }
          double newCost;
          if (pendingValue.containsKey(barcode)) {
            // Reverse ke waqt stock kam tha: weighted cost value-based (reverse + add ka net, wahi formula).
            final factor = before.smallestUnitFactor();
            final stockAfter = before.stock + purchasedSmallest;
            final value = (pendingValue[barcode] ?? 0.0) + line.amount;
            pendingValue[barcode] = value;
            newCost = stockAfter > 0 ? (value / stockAfter) * factor : before.cost;
          } else {
            newCost = addPurchaseLineCost(
              productCost: before.cost,
              productStock: before.stock,
              factor: before.smallestUnitFactor(),
              addedSmallestQty: purchasedSmallest,
              lineAmount: line.amount,
            );
          }
          final stockRows = await txn.rawUpdate(
            'UPDATE products SET stock = stock + ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
            [purchasedSmallest, newCost, now, barcode],
          );
          if (stockRows != 1) {
            // Chup chap skip nahi: poori purchase rollback, taake stock aur bill alag na hon.
            throw PurchaseSaveException('"${before.name}" ka stock update nahi ho saka. Purchase save nahi hui — dobara try karen.');
          }
          await SyncQueueHelper.enqueueStockDelta(txn, barcode, purchasedSmallest);
          await StockLedger.log(txn,
              barcode: barcode,
              type: MovementType.purchase,
              signedQty: purchasedSmallest,
              reference: billNo,
              unitCost: newCost,
              now: now);
          touched = true;
        }

        // Retail / wholesale: 0 = "na badlo". Purchase line par jo rate set ho wo product par khud lag jaye,
        // lekin SIRF tab jab yeh bill is item ki sab se nayi date wali purchase ho. Purani date ki entry
        // (back-date) product ka mojooda naya rate nahi badalti.
        if (line.retailRate > 0.0 || line.wholesaleRate > 0.0) {
          final newer = await txn.rawQuery(
            'SELECT 1 FROM purchase_items pi JOIN purchases p ON p.billNo = pi.billNo '
            'WHERE pi.barcode = ? AND p.billNo != ? AND p.createdAt > ? LIMIT 1',
            [barcode, billNo, purchaseDateMillis],
          );
          final newSale = line.retailRate > 0.0 ? line.retailRate : before.salePrice;
          final newWholesale = line.wholesaleRate > 0.0 ? line.wholesaleRate : before.wholesalePrice;
          if (newer.isEmpty && (newSale != before.salePrice || newWholesale != before.wholesalePrice)) {
            await txn.rawUpdate(
              'UPDATE products SET salePrice = ?, wholesalePrice = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
              [newSale, newWholesale, now, barcode],
            );
            touched = true;
          }
        }
        if (touched) await _enqueueProduct(txn, barcode);
      }

      // ---- edit ke baad bhi stock minus ho to rok do (poora transaction rollback)
      for (final bc in reversedBarcodes) {
        final after = await _productOrNull(txn, bc);
        if (after != null && after.stock < -0.0001) {
          throw PurchaseSaveException(
            '"${after.name}" ka stock is edit ke baad minus ho jata — nayi qty purani sale ke hisaab se kam hai. '
            'Qty barha kar dobara try karen ya stock adjustment karen.',
          );
        }
      }

      // ---- supplier ka baaqi
      final outstanding = grandTotal - paid;
      if (outstanding.abs() > 0.009) {
        await _adjustSupplierBalance(txn, sid, outstanding, now);
      }

      // ---- bill ka apna payment row (linked payments apni jagah rehti hain)
      final ownPaid = (paid - linkedPaid) < 0 ? 0.0 : (paid - linkedPaid);
      if (ownPaid > 0.009) {
        final payment = Payment(
          reference: billNo,
          partyType: 'supplier',
          partyId: sid,
          amount: ownPaid,
          method: methodLabel,
          note: isEdit ? 'Purchase payment (edited)' : 'Purchase payment',
          createdAt: purchaseDateMillis,
        );
        final payId = await txn.insert('payments', payment.toMap());
        await _enqueue(txn, 'payment', '$payId', 'create', payment.toMap());
      }

      // ---- cash drawer: har method ki alag row (Day Book / Cash Register method ke hisaab se tor sakein)
      for (final row in plan.cashRows) {
        final cashTx = CashTransaction(
          type: 'OUT',
          method: row.method.toLowerCase(),
          amount: row.amount,
          reason: 'Purchase',
          reference: billNo,
          createdAt: purchaseDateMillis,
        );
        final cashId = await txn.insert('cash_transactions', cashTx.toMap());
        await _enqueue(txn, 'cash_transaction', '$cashId', 'create', cashTx.toMap());
      }

      if (original != null) {
        auditDetails = 'total=${original.total}->$grandTotal paid=${original.paid}->$paid '
            'supplierId=${original.supplierId ?? 'cash'}->$sid';
      }
    });

    // Raw SQL writes ne product/supplier streams ko bypass kiya — screens ko refresh karo.
    await ProductRepository.instance.refresh();
    await SupplierRepository.instance.refresh();
    final details = auditDetails;
    if (details != null) await _logAudit('purchase_edit', billNo, details);
    return billNo;
  }

  // ------------------------------------------------------------ transaction helpers

  /// Edit mein wo purani line jo ab as-is nahi rahi: stock/cost wapas. Stock baad ki sale se kam ho chuka ho
  /// to poora edit rok do (cost galat ho jata) — Kotlin `reverseStockAndCostForItems`.
  Future<void> _reverseLine(
      Transaction txn, PurchaseItem it, String billNo, int now, Map<String, double> pendingValue) async {
    final product = await _productOrNull(txn, it.barcode);
    if (product == null) return;
    final smallest = purchaseItemSmallestQty(it, product);
    if (smallest <= 0) return;

    // Stock is purchase se kam reh gaya (baad ki sale): stock beech mein minus jane do, cost ki value alag
    // rakho; akhri check savePurchase mein hota hai (nayi qty add hone ke baad).
    if (product.stock < smallest || pendingValue.containsKey(it.barcode)) {
      final factor = product.smallestUnitFactor();
      final costPer = factor > 0 ? product.cost / factor : product.cost;
      final current = pendingValue[it.barcode] ?? (product.stock * costPer);
      final value = (current - it.amount) < 0 ? 0.0 : (current - it.amount);
      pendingValue[it.barcode] = value;
      await txn.rawUpdate(
        'UPDATE products SET stock = stock - ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
        [smallest, now, it.barcode],
      );
      await SyncQueueHelper.enqueueStockDelta(txn, it.barcode, -smallest);
      await StockLedger.log(txn,
          barcode: it.barcode,
          type: MovementType.purchaseReversal,
          signedQty: -smallest,
          reference: billNo,
          unitCost: product.cost,
          now: now);
      await _enqueueProduct(txn, it.barcode);
      return;
    }

    final newCost = reversePurchaseLineCost(
      productCost: product.cost,
      productStock: product.stock,
      factor: product.smallestUnitFactor(),
      itemAmount: it.amount,
      smallestQtyToRemove: smallest,
    );
    final n = await txn.rawUpdate(
      'UPDATE products SET stock = stock - ?, cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ? AND stock >= ?',
      [smallest, newCost, now, it.barcode, smallest],
    );
    if (n == 0) {
      throw PurchaseSaveException(
        '"${product.name}" ka stock is purchase ke baad already kam ho chuka hai (sale ya doosri entry se) — '
        'is purchase ko edit karna cost ko galat kar dega. Iski jagah stock adjustment karen.',
      );
    }
    await SyncQueueHelper.enqueueStockDelta(txn, it.barcode, -smallest);
    await StockLedger.log(txn,
        barcode: it.barcode,
        type: MovementType.purchaseReversal,
        signedQty: -smallest,
        reference: billNo,
        unitCost: newCost,
        now: now);
    await _enqueueProduct(txn, it.barcode);
  }

  /// `payments` jo bill se link hain (billReference == bill) magar bill ka apna embedded row nahi
  /// (reference != bill): wo `paid` mein pehle se hain aur apni cash row rakhti hain.
  Future<double> _linkedPaidForBill(Transaction txn, String bill) async {
    final r = await txn.rawQuery(
      'SELECT COALESCE(SUM(amount),0) AS s FROM payments WHERE billReference = ? AND reference != ?',
      [bill, bill],
    );
    if (r.isEmpty) return 0.0;
    return (r.first['s'] as num?)?.toDouble() ?? 0.0;
  }

  Future<void> _adjustSupplierBalance(Transaction txn, int supplierId, double delta, int now) async {
    await txn.rawUpdate(
      'UPDATE suppliers SET balance = balance + ?, dirty = 1, updatedAt = ? WHERE id = ?',
      [delta, now, supplierId],
    );
    await SyncQueueHelper.enqueueBalanceDelta(txn, customer: false, partyId: supplierId, delta: delta);
  }

  // Entity id delete se PEHLE (serverId-preferred) — SyncQueueHelper.delete* isi tarteeb se karta hai.
  Future<void> _deletePaymentsByReference(Transaction txn, String reference) =>
      SyncQueueHelper.deletePaymentsByReference(txn, reference);

  Future<void> _deleteCashByReference(Transaction txn, String reference) =>
      SyncQueueHelper.deleteCashTransactionsByReference(txn, reference);

  Future<void> _enqueueProduct(Transaction txn, String barcode) async {
    final r = await txn.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    if (r.isNotEmpty) await _enqueue(txn, 'product', barcode, 'update', r.first);
  }

  Future<void> _enqueue(
    Transaction txn,
    String entityType,
    String entityId,
    String operation,
    Map<String, Object?> payload,
  ) async {
    // SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
    await SyncQueueHelper.enqueueLegacy(txn, entityType, entityId, operation, payload);
  }

  Future<void> _logAudit(String action, String reference, String details) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': action,
        'reference': reference,
        'details': details,
        'createdAt': _now(),
      });
    } catch (_) {
      // Audit kabhi commit shuda save ko na tode.
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
