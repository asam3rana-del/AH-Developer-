import '../db/app_database.dart';
import '../db/maintenance_sync.dart';
import '../db/product_repository.dart';
import '../models/product.dart';
import '../services/session.dart';
import '../sync/sync_queue_helper.dart';

/// Ek duplicate group: [keeper] rehta hai, [losers] ka stock keeper mein jama hota hai aur wo hat jate hain.
class MergeGroup {
  final Product keeper;
  final List<Product> losers;
  const MergeGroup(this.keeper, this.losers);

  List<Product> get all => [keeper, ...losers];
  double get combinedStock => all.fold(0.0, (s, p) => s + p.stock);
  double get combinedOpeningStock => all.fold(0.0, (s, p) => s + p.openingStock);
}

/// Merge se pehle dikhane wala plan (kuch likhe baghair).
class MergePlan {
  final List<MergeGroup> groups;

  /// Naam mil gaya lekin unit setup alag (ya sirf kuch sub-groups mergeable) — insaan ko dekhna hai.
  final int skippedUnitMismatch;
  const MergePlan(this.groups, this.skippedUnitMismatch);

  int get productsToRemove => groups.fold(0, (s, g) => s + g.losers.length);
  bool get isEmpty => groups.isEmpty;
}

class MergeResult {
  final int groupsMerged;
  final int productsRemoved;
  final int groupsSkippedUnitMismatch;
  const MergeResult(this.groupsMerged, this.productsRemoved, this.groupsSkippedUnitMismatch);
}

/// Kotlin `UnitKey` — unit + unitSize + secondary/tertiary unit aur qty, sab barabar hon.
String _unitKey(Product p) => [
      p.unit.trim(),
      p.unitSize,
      p.secondaryUnit.trim(),
      p.secondaryUnitQty,
      p.tertiaryUnit.trim(),
      p.tertiaryUnitQty,
    ].join('\u0001');

/// Pure — Kotlin `MergeDuplicateProductsFix.run` ka faisla-wala hissa.
///
/// SAFETY RULE (Kotlin jaisa): sirf wahi products merge hote hain jin ka naam AUR poora unit
/// setup barabar ho. Naam barabar lekin unit alag ho to guess nahi karte — [MergePlan.skippedUnitMismatch].
/// Keeper = sab se taaza `updatedAt` (barabari par list mein pehla).
///
/// Farq (Kotlin se, ehtiyat): khali naam wale products kabhi merge nahi hote.
MergePlan planProductMerge(List<Product> all) {
  final byName = <String, List<Product>>{};
  for (final p in all) {
    final key = p.name.trim().toLowerCase();
    if (key.isEmpty) continue;
    byName.putIfAbsent(key, () => []).add(p);
  }

  final groups = <MergeGroup>[];
  var skipped = 0;

  for (final group in byName.values) {
    if (group.length < 2) continue;

    final byUnit = <String, List<Product>>{};
    for (final p in group) {
      byUnit.putIfAbsent(_unitKey(p), () => []).add(p);
    }
    final mergeable = byUnit.values.where((s) => s.length >= 2).toList();
    if (byUnit.length > 1) skipped++;
    if (mergeable.isEmpty) continue;

    for (final sub in mergeable) {
      var keeper = sub.first;
      for (final p in sub) {
        if (p.updatedAt > keeper.updatedAt) keeper = p;
      }
      final losers = sub.where((p) => p.barcode != keeper.barcode).toList();
      if (losers.isEmpty) continue;
      groups.add(MergeGroup(keeper, losers));
    }
  }
  return MergePlan(groups, skipped);
}

/// Mirrors MergeDuplicateProductsFix.kt.
///
/// Har group ke liye: stock + openingStock keeper par jama; sale_items / purchase_items / returns /
/// stock_movements ka barcode keeper par; loser products delete + sync delete; keeper sync update.
/// `held_bills` ko nahi chhoota (Kotlin jaisa). Barcode badalne wali sales/purchases/returns/stock_movements
/// sync queue mein dobara jati hain (Kotlin mein ye gap tha — pull purana barcode wapas likh deta tha).
class MergeDuplicateProducts {
  MergeDuplicateProducts._();

  /// Sirf dekhne ke liye — DB mein kuch nahi likhta.
  static Future<MergePlan> preview() async {
    final all = await ProductRepository.instance.listAll();
    return planProductMerge(all);
  }

  /// Plan transaction ke ANDAR taaza data se dobara banta hai (preview ke baad agar stock badla ho
  /// to purana plan istemal nahi hota). Sab kuch ek transaction — beech mein fail => kuch nahi badla.
  static Future<MergeResult> run() async {
    final db = await AppDatabase.instance.database;
    late MergePlan plan;

    await db.transaction((txn) async {
      final rows = await txn.query('products', orderBy: 'barcode ASC');
      plan = planProductMerge(rows.map(Product.fromMap).toList());
      if (plan.isEmpty) return;

      final now = DateTime.now().millisecondsSinceEpoch;

      // Barcode badalne se jin docs ke items/barcode badlenge unki ids PEHLE jama (update ke baad nahi milengi);
      // merge ke baad inhein dobara sync queue mein daalte hain, warna server / doosre devices par purana
      // (ab hata hua) barcode reh jata hai aur pull un items ko wapas ghalat barcode par likh deta hai.
      final saleInvoices = <String>{};
      final purchaseBills = <String>{};
      final returnIds = <int>{};
      final movementIds = <int>{};

      for (final g in plan.groups) {
        final keeper = g.keeper;

        for (final loser in g.losers) {
          for (final r in await txn.rawQuery('SELECT DISTINCT invoice AS v FROM sale_items WHERE barcode=?', [loser.barcode])) {
            saleInvoices.add(r['v'] as String);
          }
          for (final r in await txn.rawQuery('SELECT DISTINCT billNo AS v FROM purchase_items WHERE barcode=?', [loser.barcode])) {
            purchaseBills.add(r['v'] as String);
          }
          for (final r in await txn.rawQuery('SELECT id FROM returns WHERE barcode=?', [loser.barcode])) {
            returnIds.add(r['id'] as int);
          }
          for (final r in await txn.rawQuery('SELECT id FROM stock_movements WHERE barcode=?', [loser.barcode])) {
            movementIds.add(r['id'] as int);
          }
          await txn.rawUpdate('UPDATE sale_items SET barcode=? WHERE barcode=?', [keeper.barcode, loser.barcode]);
          await txn.rawUpdate('UPDATE purchase_items SET barcode=? WHERE barcode=?', [keeper.barcode, loser.barcode]);
          await txn.rawUpdate('UPDATE returns SET barcode=? WHERE barcode=?', [keeper.barcode, loser.barcode]);
          await txn.rawUpdate(
            'UPDATE stock_movements SET barcode=?, dirty=1, updatedAt=? WHERE barcode=?',
            [keeper.barcode, now, loser.barcode],
          );
        }

        final merged = keeper.copyWith(
          stock: g.combinedStock,
          openingStock: g.combinedOpeningStock,
          dirty: true,
          updatedAt: now,
        );
        await txn.update('products', merged.toMap(), where: 'barcode=?', whereArgs: [keeper.barcode]);
        for (final loser in g.losers) {
          await txn.delete('products', where: 'barcode=?', whereArgs: [loser.barcode]);
        }

        await enqueueSync(txn, 'product', keeper.barcode, 'update', merged.toMap());
        // Loser ka stock keeper mein aaya — increment_stock (doosre device ki gintee na rundhe).
        final moved = g.combinedStock - keeper.stock;
        if (moved != 0) await SyncQueueHelper.enqueueStockDelta(txn, keeper.barcode, moved);
        for (final loser in g.losers) {
          await enqueueSync(txn, 'product', loser.barcode, 'delete', {'barcode': loser.barcode});
        }
      }

      // Naye barcode wali taaza rows (ab DB mein keeper ka barcode hai) sync queue mein.
      for (final inv in saleInvoices) {
        await SyncQueueHelper.enqueueSale(txn, inv);
      }
      for (final bill in purchaseBills) {
        await SyncQueueHelper.enqueuePurchase(txn, bill);
      }
      for (final id in returnIds) {
        await SyncQueueHelper.enqueueReturn(txn, id);
      }
      for (final id in movementIds) {
        await SyncQueueHelper.enqueueStockMovement(txn, id);
      }

      await logMaintenanceAudit(
        txn,
        username: Session.username ?? 'unknown',
        action: 'merge_duplicate_products',
        reference: '',
        details: '${plan.groups.length} group(s) merged, ${plan.productsToRemove} product row(s) removed',
      );
    });

    if (!plan.isEmpty) await ProductRepository.instance.refresh();
    return MergeResult(plan.groups.length, plan.productsToRemove, plan.skippedUnitMismatch);
  }
}
