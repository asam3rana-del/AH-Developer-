import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/product.dart';
import '../models/purchase.dart';
import '../sync/sync_queue_helper.dart';

/// costPending: minus stock (ya product cost 0) par bani sale line ki asal cost purchase aane par bharna.
///
/// `sale_items` par 3 columns hain (DB v33):
///  * `pendingQty`  — is line ki wo qty (smallest units) jis ki asal cost abhi maloom nahi.
///  * `pendingEst`  — us hisse ki andaza shuda cost jo `cost` mein abhi shamil hai (sale ke waqt product ki cost se).
///  * `backfillLog` — JSON `[{"b": billNo, "q": qty, "r": rate, "e": est}]`: kis purchase bill ne kitni cost bhari.
///
/// Purchase save/edit/delete/return/item-edit — sab yahin se guzarte hain taake profit aage peeche theek rahe.
const double kPendingEpsilon = 1e-6;

/// Ek pending line (planning ke liye; DB se alag taake test aasan ho).
class PendingLine {
  final int id;
  final String invoice;
  final double cost;
  final double pendingQty;
  final double pendingEst;
  final String backfillLog;
  const PendingLine({
    required this.id,
    required this.invoice,
    required this.cost,
    required this.pendingQty,
    required this.pendingEst,
    required this.backfillLog,
  });
}

/// Ek line ka naya hal.
class BackfillResult {
  final int id;
  final String invoice;
  final double cost;
  final double pendingQty;
  final double pendingEst;
  final String backfillLog;
  const BackfillResult(this.id, this.invoice, this.cost, this.pendingQty, this.pendingEst, this.backfillLog);
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

List<Map<String, Object?>> decodeBackfillLog(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <Map<String, Object?>>[];
  try {
    final d = jsonDecode(raw);
    if (d is List) {
      return [
        for (final e in d)
          if (e is Map) Map<String, Object?>.from(e),
      ];
    }
  } catch (_) {}
  return <Map<String, Object?>>[];
}

String encodeBackfillLog(List<Map<String, Object?>> log) => log.isEmpty ? '' : jsonEncode(log);

/// Purchase ki [smallestQty] (rate [ratePerSmallest] per smallest unit) ko [lines] (sab se purani sale pehle)
/// par bantna. Sirf badli hui lines wapas deta hai.
List<BackfillResult> planBackfill(
  List<PendingLine> lines, {
  required String billNo,
  required double smallestQty,
  required double ratePerSmallest,
}) {
  final out = <BackfillResult>[];
  var remaining = smallestQty;
  if (remaining <= kPendingEpsilon || !ratePerSmallest.isFinite || ratePerSmallest < 0) return out;
  for (final l in lines) {
    if (remaining <= kPendingEpsilon) break;
    if (l.pendingQty <= kPendingEpsilon) continue;
    final a = remaining < l.pendingQty ? remaining : l.pendingQty;
    final estShare = l.pendingQty > 0 ? l.pendingEst * (a / l.pendingQty) : 0.0;
    var newCost = l.cost - estShare + a * ratePerSmallest;
    if (newCost < 0) newCost = 0;
    var newPending = l.pendingQty - a;
    var newEst = l.pendingEst - estShare;
    if (newPending <= kPendingEpsilon) {
      newPending = 0;
      newEst = 0;
    }
    final log = decodeBackfillLog(l.backfillLog)
      ..add({'b': billNo, 'q': a, 'r': ratePerSmallest, 'e': estShare});
    out.add(BackfillResult(l.id, l.invoice, _round2(newCost), newPending, newEst, encodeBackfillLog(log)));
    remaining -= a;
  }
  return out;
}

/// [billNo] ki bhari hui cost wapas "pending" karna ([barcode] diya ho to sirf us item ki).
/// Sirf badli hui lines wapas deta hai.
List<BackfillResult> planReverse(List<PendingLine> lines, {required String billNo}) {
  final out = <BackfillResult>[];
  for (final l in lines) {
    final log = decodeBackfillLog(l.backfillLog);
    if (!log.any((e) => e['b'] == billNo)) continue;
    var cost = l.cost;
    var pending = l.pendingQty;
    var est = l.pendingEst;
    final keep = <Map<String, Object?>>[];
    for (final e in log) {
      if (e['b'] != billNo) {
        keep.add(e);
        continue;
      }
      final q = (e['q'] as num?)?.toDouble() ?? 0.0;
      final r = (e['r'] as num?)?.toDouble() ?? 0.0;
      final es = (e['e'] as num?)?.toDouble() ?? 0.0;
      cost = cost - q * r + es;
      pending += q;
      est += es;
    }
    if (cost < 0) cost = 0;
    out.add(BackfillResult(l.id, l.invoice, _round2(cost), pending, est, encodeBackfillLog(keep)));
  }
  return out;
}

/// Sale item ki qty badalne par (cost qty ke hisaab se scale hoti hai) pending columns bhi usi ratio se scale.
Map<String, Object?> scaledPendingColumns({
  required double pendingQty,
  required double pendingEst,
  required String backfillLog,
  required double ratio,
}) {
  if (pendingQty <= kPendingEpsilon && backfillLog.isEmpty) {
    return {'pendingQty': pendingQty, 'pendingEst': pendingEst, 'backfillLog': backfillLog};
  }
  final log = [
    for (final e in decodeBackfillLog(backfillLog))
      {
        ...e,
        'q': ((e['q'] as num?)?.toDouble() ?? 0.0) * ratio,
        'e': ((e['e'] as num?)?.toDouble() ?? 0.0) * ratio,
      },
  ];
  final q = pendingQty * ratio;
  return {
    'pendingQty': q <= kPendingEpsilon ? 0.0 : q,
    'pendingEst': q <= kPendingEpsilon ? 0.0 : pendingEst * ratio,
    'backfillLog': encodeBackfillLog(log),
  };
}

class CostBackfill {
  CostBackfill._();

  static PendingLine _line(Map<String, Object?> r) => PendingLine(
        id: (r['id'] as num).toInt(),
        invoice: r['invoice'] as String,
        cost: (r['cost'] as num).toDouble(),
        pendingQty: (r['pendingQty'] as num?)?.toDouble() ?? 0.0,
        pendingEst: (r['pendingEst'] as num?)?.toDouble() ?? 0.0,
        backfillLog: (r['backfillLog'] as String?) ?? '',
      );

  static Future<void> _write(DatabaseExecutor ex, List<BackfillResult> results) async {
    if (results.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final invoices = <String>{};
    for (final r in results) {
      await ex.update(
        'sale_items',
        {'cost': r.cost, 'pendingQty': r.pendingQty, 'pendingEst': r.pendingEst, 'backfillLog': r.backfillLog},
        where: 'id = ?',
        whereArgs: [r.id],
      );
      invoices.add(r.invoice);
    }
    for (final inv in invoices) {
      await ex.rawUpdate('UPDATE sales SET updatedAt = ?, dirty = 1 WHERE invoice = ?', [now, inv]);
      // Dusre device par bhi bill ki naya cost / pending status pohonche.
      await SyncQueueHelper.enqueueSale(ex, inv);
    }
  }

  /// Purchase ka stock add hone ke BAAD bulao: [smallestQty] us item ki pending sale lines ko (purani pehle) bharta hai.
  /// [ratePerSmallest] = us purchase line ka rate per smallest unit (lineAmount / smallestQty).
  static Future<void> apply(
    DatabaseExecutor ex, {
    required String billNo,
    required String barcode,
    required double smallestQty,
    required double ratePerSmallest,
  }) async {
    if (smallestQty <= kPendingEpsilon) return;
    final rows = await ex.rawQuery(
      'SELECT si.id AS id, si.invoice AS invoice, si.cost AS cost, si.pendingQty AS pendingQty, '
      'si.pendingEst AS pendingEst, si.backfillLog AS backfillLog '
      'FROM sale_items si JOIN sales s ON s.invoice = si.invoice '
      "WHERE si.barcode = ? AND si.pendingQty > ? AND s.status = 'active' "
      'ORDER BY s.createdAt ASC, si.id ASC',
      [barcode, kPendingEpsilon],
    );
    final plan = planBackfill([for (final r in rows) _line(r)],
        billNo: billNo, smallestQty: smallestQty, ratePerSmallest: ratePerSmallest);
    await _write(ex, plan);
  }

  /// Purchase delete / return / edit-reverse par: us bill ki bhari hui cost wapas pending. [barcode] diya ho to
  /// sirf us item ki lines.
  static Future<void> reverse(DatabaseExecutor ex, {required String billNo, String? barcode}) async {
    final rows = await ex.rawQuery(
      'SELECT id, invoice, cost, pendingQty, pendingEst, backfillLog FROM sale_items '
      "WHERE backfillLog LIKE ?${barcode != null ? ' AND barcode = ?' : ''}",
      ['%${jsonEncode(billNo)}%', if (barcode != null) barcode],
    );
    final plan = planReverse([for (final r in rows) _line(r)], billNo: billNo);
    await _write(ex, plan);
  }

  /// Bill ke [barcode] item ki backfill dobara banana: pehle us bill ki purani bhari hui cost wapas pending,
  /// phir bill ki MAUJUDA lines (purchase_items) se dobara. Purchase save/edit/return/item-edit/item-delete sab
  /// stock badalne ke BAAD ye bulate hain; bill ya line na ho to sirf reverse hota hai (delete).
  static Future<void> reallocateBill(DatabaseExecutor ex, {required String billNo, required String barcode}) async {
    await reverse(ex, billNo: billNo, barcode: barcode);
    final pr = await ex.query('purchases', where: 'billNo = ?', whereArgs: [billNo], limit: 1);
    if (pr.isEmpty || (pr.first['status'] as String?) == 'returned') return;
    final prodRows = await ex.query('products', where: 'barcode = ?', whereArgs: [barcode], limit: 1);
    final product = prodRows.isEmpty ? null : Product.fromMap(prodRows.first);
    final items = (await ex.query('purchase_items', where: 'billNo = ? AND barcode = ?', whereArgs: [billNo, barcode]))
        .map(PurchaseItem.fromMap);
    for (final it in items) {
      final smallest = it.conversionFactor > 0
          ? it.qty * it.conversionFactor
          : (product == null ? it.qty : product.toSmallestUnits(it.qty, it.unit.isEmpty ? product.unit : it.unit));
      if (smallest <= kPendingEpsilon) continue;
      await apply(ex, billNo: billNo, barcode: barcode, smallestQty: smallest, ratePerSmallest: it.amount / smallest);
    }
  }

  /// Sale save par: [needed] smallest units bechne hain, [stockBefore] stock tha, [costPerSmallest] product ki cost.
  /// Wapas (pendingQty, pendingEst): jo hissa stock se na dhaka (ya cost 0 hai) wo pending.
  static ({double pendingQty, double pendingEst}) pendingForSale({
    required double needed,
    required double stockBefore,
    required double costPerSmallest,
    required double lineCost,
  }) {
    if (needed <= kPendingEpsilon) return (pendingQty: 0.0, pendingEst: 0.0);
    final covered = costPerSmallest <= 0
        ? 0.0
        : (stockBefore <= 0 ? 0.0 : (stockBefore < needed ? stockBefore : needed));
    final pending = needed - covered;
    if (pending <= kPendingEpsilon) return (pendingQty: 0.0, pendingEst: 0.0);
    return (pendingQty: pending, pendingEst: lineCost * (pending / needed));
  }
}
