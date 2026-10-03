
import 'package:sqflite/sqflite.dart';

import '../models/category_unit.dart' as models;
import '../models/product.dart';
import '../services/session.dart';
import 'app_database.dart';
import 'category_unit_repository.dart';
import 'product_repository.dart';
import '../sync/sync_queue_helper.dart';
import '../utils/rate_list_csv.dart';

/// Categories tab ki ek row (ItemsActivity.renderCategories ka Triple).
class CategoryRow {
  final String name;
  final int count;
  final bool uncategorized;
  const CategoryRow(this.name, this.count, this.uncategorized);
}

/// Kotlin `it.category.ifBlank { "" }`.
String categoryKey(Product p) => p.category.trim().isEmpty ? '' : p.category;

/// Pure: pehli row hamesha "Items Not in Any Category", phir har category apne
/// product count ke saath; [query] naam par (case-insensitive) filter karta hai.
List<CategoryRow> buildCategoryRows(List<Product> products, List<models.Category> categories, String query) {
  final counts = <String, int>{};
  for (final p in products) {
    counts[categoryKey(p)] = (counts[categoryKey(p)] ?? 0) + 1;
  }
  final rows = <CategoryRow>[
    CategoryRow(kNoCategoryLabel, counts[''] ?? 0, true),
    for (final c in categories) CategoryRow(c.name, counts[c.name] ?? 0, false),
  ];
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return rows;
  return rows.where((r) => r.name.toLowerCase().contains(q)).toList();
}

const String kNoCategoryLabel = 'Items Not in Any Category';

/// Products tab: naam/searchTag (matchesQuery) YA barcode mein match.
List<Product> filterProducts(List<Product> all, String query) {
  final q = query.trim();
  if (q.isEmpty) return all;
  return all.where((p) => p.matchesQuery(q) || p.barcode.toLowerCase().contains(q.toLowerCase())).toList();
}

/// ItemsActivity ke write-paths (category/unit/product). Har write + uski sync_queue
/// entry ek DB transaction mein (Kotlin SyncQueueHelper.enqueue* jaisa).
/// Cashier ko cost (purchase price) load hi na ho — data layer par bhi (PORTING_PLAN rule).
/// Admin/Manager ke liye list jaisi hai waisi.
List<Product> productsForRole(List<Product> all, String role) {
  if (role == 'admin' || role == 'manager') return all;
  return [for (final p in all) p.copyWith(cost: 0)];
}

/// Items ke badalne wale kaam sirf admin (Products ki tarah). UI ke saath data layer par bhi.
void requireItemsAdmin() {
  if (!Session.isAdmin) {
    throw StateError('Only Admin can change items');
  }
}

class ItemsRepository {
  ItemsRepository._();
  static final ItemsRepository instance = ItemsRepository._();

  /// SyncQueueHelper.enqueueLegacy: asal payload DB se (Android shape) — hamesha data likhne ke BAAD.
  Future<void> _enqueue(DatabaseExecutor db, String type, String id, String op, Map<String, Object?> payload) =>
      SyncQueueHelper.enqueueLegacy(db, type, id, op, payload);

  Future<void> _enqueueProducts(DatabaseExecutor db, List<String> barcodes) async {
    for (final b in barcodes) {
      await SyncQueueHelper.enqueueProduct(db, b);
    }
  }

  Future<void> _refresh() async {
    await ProductRepository.instance.refresh();
    await CategoryRepository.instance.refreshList();
    await UnitRepository.instance.refreshList();
  }

  // ---------- Rate List import (CSV) ----------

  /// Kotlin `importRateListCsv`: har row Code (barcode) se product dhoondh kar unit / wholesale / retail /
  /// 2nd + 3rd unit lagati hai (last edit wins). Sab ek transaction mein + har product sync queue mein
  /// (Kotlin sirf upsert karta tha, queue nahi — Flutter behtar, "Change Category" jaisa).
  /// Natija: (updated, notFound).
  Future<({int updated, int notFound})> importRateList(List<RateListRow> rows) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    var updated = 0;
    var notFound = 0;
    await db.transaction((txn) async {
      final touched = <String>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in rows) {
        final found = await txn.query('products', where: 'barcode=?', whereArgs: [r.barcode], limit: 1);
        if (found.isEmpty) {
          notFound++;
          continue;
        }
        final existing = Product.fromMap(found.first);
        await txn.update(
          'products',
          {
            'unit': r.unit ?? existing.unit,
            'wholesalePrice': r.wholesale ?? existing.wholesalePrice,
            'salePrice': r.retail ?? existing.salePrice,
            'secondaryUnit': r.secondaryUnit,
            'secondaryUnitQty': r.secondaryUnitQty,
            'tertiaryUnit': r.tertiaryUnit,
            'tertiaryUnitQty': r.tertiaryUnitQty,
            'updatedAt': now,
            'dirty': 1,
          },
          where: 'barcode=?',
          whereArgs: [r.barcode],
        );
        touched.add(r.barcode);
        updated++;
      }
      await _enqueueProducts(txn, touched);
    });
    await _refresh();
    return (updated: updated, notFound: notFound);
  }

  // ---------- categories ----------

  Future<void> addCategory(String name) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.insert('categories', {'name': name}, conflictAlgorithm: ConflictAlgorithm.replace);
      await _enqueue(txn, 'category', name, 'create', {'name': name});
    });
    await _refresh();
  }

  /// Rename: naya category banta hai, products ki category badalti hai, purani hatti hai,
  /// aur badle hue products sync queue mein jate hain.
  Future<void> renameCategory(String oldName, String newName) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final touched = (await txn.query('products', columns: ['barcode'], where: 'category=?', whereArgs: [oldName]))
          .map((r) => r['barcode'] as String)
          .toList();
      await txn.insert('categories', {'name': newName}, conflictAlgorithm: ConflictAlgorithm.replace);
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update('products', {'category': newName, 'dirty': 1, 'updatedAt': now}, where: 'category=?', whereArgs: [oldName]);
      await txn.delete('categories', where: 'name=?', whereArgs: [oldName]);
      await _enqueue(txn, 'category', newName, 'create', {'name': newName});
      await _enqueue(txn, 'category', oldName, 'delete', {'name': oldName});
      await _enqueueProducts(txn, touched);
    });
    await _refresh();
  }

  /// Delete: is category ke products "Items Not in Any Category" (category = '') mein jate hain.
  Future<void> deleteCategory(String name) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final touched = (await txn.query('products', columns: ['barcode'], where: 'category=?', whereArgs: [name]))
          .map((r) => r['barcode'] as String)
          .toList();
      if (touched.isNotEmpty) {
        await txn.update('products', {'category': '', 'dirty': 1, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
            where: 'category=?', whereArgs: [name]);
      }
      await txn.delete('categories', where: 'name=?', whereArgs: [name]);
      await _enqueue(txn, 'category', name, 'delete', {'name': name});
      await _enqueueProducts(txn, touched);
    });
    await _refresh();
  }

  // ---------- units ----------

  Future<void> addUnit(String name) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.insert('units', {'name': name}, conflictAlgorithm: ConflictAlgorithm.replace);
      await _enqueue(txn, 'unit', name, 'create', {'name': name});
    });
    await _refresh();
  }

  /// Kotlin confirmDeleteUnit bhi sirf local delete karta hai (koi sync delete nahi).
  Future<void> deleteUnit(String name) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.delete('units', where: 'name=?', whereArgs: [name]);
    await _refresh();
  }

  // ---------- products ----------

  Future<void> moveProductToCategory(String barcode, String category) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.update('products', {'category': category, 'dirty': 1, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
          where: 'barcode=?', whereArgs: [barcode]);
      await _enqueueProducts(txn, [barcode]);
    });
    await _refresh();
  }

  Future<void> deleteProduct(String barcode) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await SyncQueueHelper.assertProductDeletable(txn, barcode);
      await txn.delete('products', where: 'barcode=?', whereArgs: [barcode]);
      await _enqueue(txn, 'product', barcode, 'delete', {'barcode': barcode});
    });
    await _refresh();
  }
}
