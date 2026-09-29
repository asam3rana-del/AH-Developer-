import 'dart:convert';

import '../models/product.dart';
import '../models/stock_movement.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'product_repository.dart';
import 'stock_ledger.dart';

/// Ports the data side of StockTakingActivity.kt (physical count vs system stock).
///
/// Kotlin ke usool jo yahan barqarar hain:
///  * Koi nayi table nahi — har variance line ledger mein `STOCK_TAKE` (reference = ek shared session id)
///    ke saath likhi jati hai, isliye Stock History mein khud dikhti hai.
///  * Sirf wo products chuute hain jin ki gintee likhi gayi. KHALI field = "aaj nahi gina", 0 nahi.
///  * Poore session ki stock/ledger/sync_queue writes ek hi transaction mein (ya sab, ya koi nahi).
///  * Session ke baad ek summary audit entry (action `stock_take`).
///  * Gintee product ki SMALLEST unit mein (Product.stock ki basis) — Kotlin `counted - p.stock` seedha.
///  * Value impact = delta * (cost / smallestUnitFactor) (cost primary unit ka rate hai).

class StockTakingException implements Exception {
  final String message;
  const StockTakingException(this.message);
  @override
  String toString() => message;
}

/// Ek variance line: system vs counted, live Product row ke muqable mein.
class StockTakeVariance {
  final Product product;
  final double counted;

  /// counted - system stock (SMALLEST unit). +ve = stock badhega, -ve = ghatega.
  final double delta;

  const StockTakeVariance(this.product, this.counted, this.delta);

  double get valueImpact => stockTakeValueImpact(product, delta);
}

/// Kotlin formatQty(): poora ho to integer, warna 2 decimal.
String formatStockTakeQty(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Kotlin valueImpact(): delta smallest unit mein, cost primary unit ka rate — is liye cost ko
/// smallestUnitFactor se taqseem karte hain (warna carton/dozen wale items ka asar factor guna ziyada aata).
double stockTakeValueImpact(Product p, double delta) {
  final factor = p.smallestUnitFactor();
  final costPerSmallest = factor > 0 ? p.cost / factor : p.cost;
  return delta * costPerSmallest;
}

/// Kotlin renderList(): khali query = poori list, warna naam/searchTag (matchesQuery), category, barcode.
List<Product> filterStockTakeProducts(List<Product> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all
      .where((p) => p.matchesQuery(q) || p.category.toLowerCase().contains(q) || p.barcode.toLowerCase().contains(q))
      .toList();
}

/// Kitne items ki gintee likhi ja chuki (sirf wo jo number hain) — Kotlin updateSummary().
int countedItems(Map<String, String> entered) => entered.values.where((t) => double.tryParse(t.trim()) != null).length;

/// null = theek. Kotlin negative gintee bhi maan leta tha; yahan negative rad aur piece-based item mein fraction rad
/// (Product.isValidSmallestQty), taake stock negative ya 1.5 pcs na ho jaye.
String? validateCount(Product p, double? counted) {
  if (counted == null) return null; // khali = gina hi nahi
  if (counted < 0) return '${p.name}: gintee manfi nahi ho sakti';
  if (!p.isValidSmallestQty(counted)) {
    return '${p.name}: gintee poori ${p.smallestUnitName()} mein honi chahiye (fraction nahi)';
  }
  return null;
}

/// Pehli galat gintee ka message (ya null). Review se pehle chalta hai.
String? firstInvalidCount(Map<String, String> entered, Map<String, Product> latest) {
  for (final e in entered.entries) {
    final counted = double.tryParse(e.value.trim());
    final p = latest[e.key];
    if (counted == null || p == null) continue;
    final err = validateCount(p, counted);
    if (err != null) return err;
  }
  return null;
}

/// Kotlin reviewAndSave() ka variance hissa: sirf number wali entries, live product se delta,
/// |delta| > 0.0001 wali lines. Order = entry ka order.
List<StockTakeVariance> buildVariances(Map<String, String> entered, Map<String, Product> latest) {
  final out = <StockTakeVariance>[];
  for (final e in entered.entries) {
    final counted = double.tryParse(e.value.trim());
    if (counted == null) continue;
    final p = latest[e.key];
    if (p == null) continue;
    final delta = counted - p.stock;
    if (delta.abs() > 0.0001) out.add(StockTakeVariance(p, counted, delta));
  }
  return out;
}

/// "ST" + yyMMddHHmmss (Kotlin SimpleDateFormat("yyMMddHHmmss")).
String stockTakeSessionId(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'ST${two(t.year % 100)}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// Ledger line ka note: "system=10 counted=8 — <note>".
String stockTakeLineNote(double system, double counted, String note) {
  final n = note.trim();
  return 'system=${formatStockTakeQty(system)} counted=${formatStockTakeQty(counted)}${n.isNotEmpty ? ' — $n' : ''}';
}

/// Confirm dialog ka matn: pehli 15 lines + "… +N more" + total value impact.
String stockTakeSummaryText(List<StockTakeVariance> variances, {required String header, required String impactLabel}) {
  final b = StringBuffer('${variances.length} $header\n\n');
  for (final v in variances.take(15)) {
    final sign = v.delta > 0 ? '+' : '';
    b.writeln('${v.product.name}: ${formatStockTakeQty(v.product.stock)} \u2192 ${formatStockTakeQty(v.counted)} ($sign${formatStockTakeQty(v.delta)})');
  }
  if (variances.length > 15) b.writeln('… +${variances.length - 15} more');
  final total = variances.fold<double>(0, (a, v) => a + v.valueImpact);
  b.write('\n$impactLabel Rs.${formatStockTakeQty(total)}');
  return b.toString();
}

class StockTakingRepository {
  StockTakingRepository._();
  static final StockTakingRepository instance = StockTakingRepository._();

  Future<List<Product>> loadProducts() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// Taaza products barcode ke hisaab se (review ke waqt purani in-memory copy par bharosa nahi).
  Future<Map<String, Product>> loadLatestByBarcode() async {
    final all = await loadProducts();
    return {for (final p in all) p.barcode: p};
  }

  /// Poori stock take ek transaction mein: har variance ke liye stock badlo + `STOCK_TAKE` ledger row
  /// (reference = session id) + product sync_queue. Phir ek summary audit entry (commit ke baad — audit
  /// kabhi save ko tor nahi sakta). Session id wapas deta hai. Admin/Manager only (role yahan bhi check hota hai).
  ///
  /// Kotlin `decreaseProductStockForce` jaisa: kam karne par SQL guard nahi (gintee >= 0 hai, is liye
  /// stock gintee se neeche nahi jata jab tak review ke baad bhi koi sale na ho).
  Future<String> commit(List<StockTakeVariance> variances, {String note = ''}) async {
    if (!Session.isAdminOrManager) {
      throw const StockTakingException('Stock Taking sirf Admin/Manager kar sakta hai');
    }
    if (variances.isEmpty) throw const StockTakingException('Koi farq nahi');
    final db = await AppDatabase.instance.database;
    final sessionId = stockTakeSessionId(DateTime.now());
    final cleanNote = note.trim();

    await db.transaction((txn) async {
      for (final v in variances) {
        final barcode = v.product.barcode;
        final now = DateTime.now().millisecondsSinceEpoch;
        final n = await txn.rawUpdate(
          'UPDATE products SET stock = stock + ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [v.delta, now, barcode],
        );
        if (n == 0) throw StockTakingException('${v.product.name}: product nahi mila');

        await StockLedger.log(txn,
            barcode: barcode,
            type: MovementType.stockTake,
            signedQty: v.delta,
            reference: sessionId,
            note: stockTakeLineNote(v.product.stock, v.counted, cleanNote),
            now: now);

        final fresh = await txn.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
        await txn.insert('sync_queue', {
          'entityType': 'product',
          'entityId': barcode,
          'operation': 'update',
          'payloadJson': jsonEncode(fresh.first),
          'createdAt': now,
          'retryCount': 0,
        });
      }
    });

    final total = variances.fold<double>(0, (a, v) => a + v.valueImpact);
    await _logAudit(sessionId, 'items_with_variance=${variances.length} value_impact=$total note=$cleanNote');
    await ProductRepository.instance.refresh();
    return sessionId;
  }

  Future<void> _logAudit(String reference, String details) async {
    try {
      final db = await AppDatabase.instance.database;
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': 'stock_take',
        'reference': reference,
        'details': details,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Audit must never break a save that already committed.
    }
  }
}
