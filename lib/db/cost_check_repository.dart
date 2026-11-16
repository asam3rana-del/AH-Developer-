import '../models/product.dart';
import '../services/permissions.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';
import '../sync/sync_worker.dart';
import 'app_database.dart';
import 'product_repository.dart';

/// Cost Check (Admin / fix_bill_cost).
///
/// Masla: product ki `cost` weighted-average hai. Kharab purchases (jaise August ki galat unit wali bills)
/// delete / edit hone par average ulta-seedha ho sakta hai — khaas kar jab stock thora bacha ho. Phir har
/// nayi sale par cost bohat zyada lagti hai aur bill loss dikhata hai, halaanke rate aakhri khareed se upar hai.
///
/// Ye tool har product ki average cost ko uski AAKHRI purchase ke rate se milata hai; bohat farq ho to
/// "aakhri purchase rate" lagane ka option deta hai.

/// Average cost aakhri purchase rate se is guna zyada / kam ho to shak.
const double kCostDriftRatio = 1.5;

/// Average cost (primary unit) aakhri purchase rate (primary unit) se bohat door hai?
bool isCostDrifted(double avgPrimary, double lastPrimary) {
  if (!lastPrimary.isFinite || lastPrimary <= 0) return false;
  if (!avgPrimary.isFinite || avgPrimary <= 0) return true;
  return avgPrimary > lastPrimary * kCostDriftRatio || avgPrimary * kCostDriftRatio < lastPrimary;
}

/// Purchase line ka rate (us line ki unit mein) -> product ki primary unit ka rate.
/// [conversionFactor] = line par save hua smallest-per-unit (0 = purani row, product ki ladder se).
double purchaseRateToPrimary(Product p, double unitCost, String unit, double conversionFactor) {
  final primaryFactor = p.smallestUnitFactor();
  if (conversionFactor > 0 && primaryFactor > 0) {
    // unitCost per (conversionFactor smallest) -> per primary (primaryFactor smallest)
    return unitCost / conversionFactor * primaryFactor;
  }
  return p.toPrimaryUnitRate(unitCost, unit.trim().isEmpty ? p.unit : unit);
}

class CostCheckRow {
  final Product product;
  final double lastRate; // primary unit
  final int lastAt;
  const CostCheckRow(this.product, this.lastRate, this.lastAt);

  double get avg => product.cost;
}

class CostCheckException implements Exception {
  final String message;
  const CostCheckException(this.message);
  @override
  String toString() => message;
}

class CostCheckRepository {
  CostCheckRepository._();
  static final CostCheckRepository instance = CostCheckRepository._();

  void _require() {
    if (!Permissions.can('fix_bill_cost') && !Session.isAdminOrManager) {
      throw const CostCheckException('Sirf Admin / Manager ye kar sakta hai');
    }
  }

  /// Ek product ki aakhri purchase ka rate (primary unit). Koi purchase na ho to null.
  Future<double?> lastPurchaseRate(Product p) async {
    if (!Session.isAdminOrManager) return null;
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT pi.unitCost AS unitCost, pi.unit AS unit, COALESCE(pi.conversionFactor, 0) AS cf
      FROM purchase_items pi JOIN purchases pu ON pi.billNo = pu.billNo
      WHERE pi.barcode = ? AND pi.unitCost > 0
      ORDER BY pu.createdAt DESC LIMIT 1
    ''', [p.barcode]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final v = purchaseRateToPrimary(
      p,
      (r['unitCost'] as num).toDouble(),
      (r['unit'] as String?) ?? '',
      (r['cf'] as num).toDouble(),
    );
    return v.isFinite && v > 0 ? v : null;
  }

  /// Wo products jin ki average cost aakhri purchase rate se bohat door hai.
  Future<List<CostCheckRow>> scan() async {
    _require();
    final db = await AppDatabase.instance.database;
    final products = await ProductRepository.instance.listAll();
    final rows = await db.rawQuery('''
      SELECT pi.barcode AS barcode, pi.unitCost AS unitCost, pi.unit AS unit,
             COALESCE(pi.conversionFactor, 0) AS cf, pu.createdAt AS at
      FROM purchase_items pi JOIN purchases pu ON pi.billNo = pu.billNo
      WHERE pi.unitCost > 0 AND pi.barcode IS NOT NULL AND pi.barcode != ''
      ORDER BY pu.createdAt DESC
    ''');
    final latest = <String, Map<String, Object?>>{};
    for (final r in rows) {
      latest.putIfAbsent(r['barcode'] as String, () => r);
    }
    final out = <CostCheckRow>[];
    for (final p in products) {
      final r = latest[p.barcode];
      if (r == null) continue;
      final rate = purchaseRateToPrimary(
        p,
        (r['unitCost'] as num).toDouble(),
        (r['unit'] as String?) ?? '',
        (r['cf'] as num).toDouble(),
      );
      if (isCostDrifted(p.cost, rate)) out.add(CostCheckRow(p, rate, (r['at'] as num).toInt()));
    }
    out.sort((a, b) => a.product.name.toLowerCase().compareTo(b.product.name.toLowerCase()));
    return out;
  }

  /// Products ki cost naye rate par (primary unit). Kitne badle wapas deta hai.
  Future<int> applyCosts(Map<String, double> costByBarcode) async {
    _require();
    if (costByBarcode.isEmpty) return 0;
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = 0;
    final details = StringBuffer();
    await db.transaction((txn) async {
      for (final e in costByBarcode.entries) {
        final cost = e.value;
        if (!cost.isFinite || cost <= 0) continue;
        final before = await txn.query('products', columns: ['cost', 'name'], where: 'barcode = ?', whereArgs: [e.key]);
        if (before.isEmpty) continue;
        final n = await txn.rawUpdate(
          'UPDATE products SET cost = ?, dirty = 1, updatedAt = ? WHERE barcode = ?',
          [cost, now, e.key],
        );
        if (n > 0) {
          changed += n;
          await SyncQueueHelper.enqueueProduct(txn, e.key);
          if (details.length < 600) {
            final old = (before.first['cost'] as num?)?.toDouble() ?? 0;
            details.write('${before.first['name']}: ${old.toStringAsFixed(2)}->${cost.toStringAsFixed(2)}; ');
          }
        }
      }
    });
    try {
      await db.insert('audit', {
        'username': Session.username ?? 'unknown',
        'action': 'cost_check_fix',
        'reference': 'products=$changed',
        'details': details.toString(),
        'createdAt': now,
      });
    } catch (_) {}
    if (changed > 0) {
      await ProductRepository.instance.refresh();
      try {
        await SyncWorker.instance.triggerNow();
      } catch (_) {}
    }
    return changed;
  }
}
