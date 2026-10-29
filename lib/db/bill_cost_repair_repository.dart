import '../models/product.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import '../sync/sync_worker.dart';
import 'app_database.dart';

/// Bill Cost Repair (sirf Admin).
///
/// Masla: unit ladder badalne (jaise ctn ko hata kar sirf outer/dabbi rakhne) se pehle bani bills ki
/// `sale_items.cost` us waqt ki purani primary unit (ctn) ke hisaab se "pakki raqam" ban kar likhi reh jati hai,
/// jo asal se kai guna zyada hoti hai (jaise Rs 194,000) aur bill ka profit bohat bada minus dikhata hai.
///
/// Ye tool aisi shak wali lines (cost >> sale amount) aur cost-0 lines (profit = poora bill) dhoondhta hai aur har line ki cost dobara
/// nikalta hai:   naya cost = smallest qty x product ki maujooda cost per smallest unit.
/// Admin list dekh kar "Apply" karta hai; bills sync queue mein jati hain to dono devices par profit theek ho jata hai.

/// Cost is se zyada ho to sale amount ke muqable shak: cost > amount x 1.5.
const double kCostSuspectRatio = 1.5;

/// ...aur farq itna ho (chhoti raqmon par rounding ka shor na aaye).
const double kCostSuspectMinGap = 50.0;

/// Shak wali line? (Sale screen guard aur repair dono yahi use karte hain.)
bool isSuspiciousLineCost(double cost, double amount) {
  if (!cost.isFinite || !amount.isFinite) return false;
  if (cost <= 0) return false;
  return cost > amount * kCostSuspectRatio && (cost - amount) > kCostSuspectMinGap;
}

/// Product ki maujooda cost se line ki sahi cost.
/// [storedFactor] = line par save hui conversionFactor (smallest per entered unit); 0 ho to product ki ladder se.
double repairedLineCost(Product p, double qty, String unit, double storedFactor) {
  final smallestQty = storedFactor > 0 ? qty * storedFactor : p.toSmallestUnits(qty, unit);
  final factor = p.smallestUnitFactor();
  final perSmallest = factor > 0 ? p.cost / factor : p.cost;
  final raw = smallestQty * perSmallest;
  return (raw * 100).roundToDouble() / 100;
}

class CostRepairLine {
  final int itemId;
  final String invoice;
  final int createdAt;
  final String party;
  final String productName;
  final String unit;
  final double qty;
  final double amount;
  final double oldCost;
  final double newCost;
  const CostRepairLine({
    required this.itemId,
    required this.invoice,
    required this.createdAt,
    required this.party,
    required this.productName,
    required this.unit,
    required this.qty,
    required this.amount,
    required this.oldCost,
    required this.newCost,
  });

  /// Is line ka bill-profit par asar (naya profit - purana profit).
  double get profitGain => oldCost - newCost;
}

class CostRepairSkipped {
  final String invoice;
  final String productName;
  final String reason;
  const CostRepairSkipped(this.invoice, this.productName, this.reason);
}

class CostRepairPlan {
  final List<CostRepairLine> lines;
  final List<CostRepairSkipped> skipped;
  const CostRepairPlan(this.lines, this.skipped);
}

class BillCostRepairException implements Exception {
  final String message;
  const BillCostRepairException(this.message);
  @override
  String toString() => message;
}

class BillCostRepairRepository {
  BillCostRepairRepository._();
  static final BillCostRepairRepository instance = BillCostRepairRepository._();

  void _requireAdmin() {
    if (!Session.isAdmin) throw const BillCostRepairException('Sirf Admin ye action kar sakta hai');
  }

  Future<CostRepairPlan> buildPlan() async {
    _requireAdmin();
    final db = await AppDatabase.instance.database;

    final products = {
      for (final r in await db.query('products')) (r['barcode'] as String): Product.fromMap(r),
    };

    final rows = await db.rawQuery(
      'SELECT si.id AS id, si.invoice AS invoice, si.barcode AS barcode, si.product AS product, '
      'si.qty AS qty, si.unit AS unit, si.cost AS cost, si.amount AS amount, '
      'si.conversionFactor AS cf, s.createdAt AS at, c.name AS party '
      'FROM sale_items si JOIN sales s ON s.invoice = si.invoice '
      'LEFT JOIN customers c ON c.id = s.customerId '
      "WHERE s.status = 'active' AND ((si.cost > si.amount * ? AND (si.cost - si.amount) > ?) "
      // Cost 0 par save hui line (profit = poora bill) jo "cost pending" bhi nahi (pendingQty 0): product ki
      // maujooda cost se bharo. Pending lines purchase se khud bharti hain, un ko nahi chheda jata.
      'OR (si.cost <= 0 AND si.amount > 0 AND COALESCE(si.pendingQty, 0) <= 0.000001)) '
      'ORDER BY s.createdAt DESC, si.id',
      [kCostSuspectRatio, kCostSuspectMinGap],
    );

    final lines = <CostRepairLine>[];
    final skipped = <CostRepairSkipped>[];
    for (final r in rows) {
      final invoice = r['invoice'] as String;
      final name = r['product'] as String;
      final p = products[r['barcode'] as String];
      if (p == null) {
        skipped.add(CostRepairSkipped(invoice, name, 'Product ab list mein nahi'));
        continue;
      }
      if (p.cost <= 0) {
        skipped.add(CostRepairSkipped(invoice, name, 'Product ki cost 0 hai — pehle product mein cost likhen'));
        continue;
      }
      final qty = (r['qty'] as num).toDouble();
      final amount = (r['amount'] as num).toDouble();
      final oldCost = (r['cost'] as num).toDouble();
      final cf = (r['cf'] as num?)?.toDouble() ?? 0.0;
      final newCost = repairedLineCost(p, qty, (r['unit'] as String?) ?? '', cf);
      if ((newCost - oldCost).abs() < 0.01) continue;
      if (isSuspiciousLineCost(newCost, amount)) {
        // Product ki apni maujooda cost hi zyada hai — repair se masla theek nahi hoga.
        skipped.add(CostRepairSkipped(invoice, name, 'Product ki maujooda cost bhi sale se bohat zyada hai — product check karen'));
        continue;
      }
      lines.add(CostRepairLine(
        itemId: (r['id'] as num).toInt(),
        invoice: invoice,
        createdAt: (r['at'] as num).toInt(),
        party: ((r['party'] as String?) ?? '').trim().isEmpty ? 'Walk-in' : (r['party'] as String).trim(),
        productName: name,
        unit: (r['unit'] as String?) ?? '',
        qty: qty,
        amount: amount,
        oldCost: oldCost,
        newCost: newCost,
      ));
    }
    return CostRepairPlan(lines, skipped);
  }

  /// Chuni hui lines ki cost update karo, un bills ko sync queue mein daalo. Kitni lines badli wapas deta hai.
  Future<int> apply(List<CostRepairLine> chosen) async {
    _requireAdmin();
    if (chosen.isEmpty) throw const BillCostRepairException('Koi line nahi chuni');
    final db = await AppDatabase.instance.database;
    var changed = 0;
    final invoices = <String>{};
    final details = StringBuffer();
    await db.transaction((txn) async {
      for (final l in chosen) {
        // Sirf tab jab cost abhi bhi wahi purani ho (beech mein sync se badli to chhod do).
        final n = await txn.rawUpdate(
          // pendingEst (costPending line ka andaza) bhi cost ke ratio se, taake pending hissa theek rahe.
          'UPDATE sale_items SET pendingEst = CASE WHEN cost > 0 THEN pendingEst * ? / cost ELSE pendingEst END, '
          'cost = ? WHERE id = ? AND ABS(cost - ?) < 0.01',
          [l.newCost, l.newCost, l.itemId, l.oldCost],
        );
        if (n > 0) {
          changed += n;
          invoices.add(l.invoice);
          if (details.length < 600) {
            details.write('${l.invoice}/${l.productName}: ${l.oldCost.toStringAsFixed(0)}->${l.newCost.toStringAsFixed(0)}; ');
          }
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final inv in invoices) {
        await txn.rawUpdate('UPDATE sales SET dirty = 1, updatedAt = ? WHERE invoice = ?', [now, inv]);
        await SyncQueueHelper.enqueueSale(txn, inv);
      }
    });
    try {
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': 'bill_cost_repair',
        'reference': 'lines=$changed bills=${invoices.length}',
        'details': details.toString(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Audit kabhi save nahi rokta.
    }
    if (invoices.isNotEmpty) {
      try {
        await SyncWorker.instance.triggerNow();
      } catch (_) {}
    }
    return changed;
  }
}
