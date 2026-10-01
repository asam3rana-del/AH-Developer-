import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'category_unit_repository.dart';
import 'maintenance_sync.dart';
import 'product_repository.dart';
import 'items_repository.dart' show requireItemsAdmin;

/// Kotlin `looksUrdu`: Urdu/Arabic script (U+0600–U+06FF) wali value — saaf English values yahan dobara nahi aati.
bool looksUrdu(String s) => s.runes.any((r) => r >= 0x0600 && r <= 0x06FF);

/// Bulk Translate screen ka load result.
class TranslateValues {
  final List<String> categories; // Urdu categories (sorted)
  final List<String> units; // Urdu units (sorted)
  final List<String> untaggedItems; // Urdu product names jin ka search tag khali hai (sorted)
  const TranslateValues(this.categories, this.units, this.untaggedItems);
}

/// Pure — master table + products par likhi values ko ek set mein mila kar sirf Urdu wali, sorted.
List<String> urduValues(Iterable<String> values) {
  final set = <String>{for (final v in values) if (v.trim().isNotEmpty && looksUrdu(v)) v};
  return set.toList()..sort();
}

/// Mirrors BulkTranslateActivity.kt ke DB hisse. Har write + uski sync_queue entries ek transaction mein.
class BulkTranslateRepository {
  BulkTranslateRepository._();
  static final BulkTranslateRepository instance = BulkTranslateRepository._();

  Future<List<String>> _distinct(DatabaseExecutor db, String table, String col) async {
    final rows = await db.rawQuery('SELECT DISTINCT $col AS v FROM $table');
    return [for (final r in rows) if (r['v'] != null) r['v'] as String];
  }

  Future<TranslateValues> load() async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;

    final cats = <String>[
      ...await _distinct(db, 'categories', 'name'),
      ...await _distinct(db, 'products', 'category'),
    ];
    final units = <String>[
      ...await _distinct(db, 'units', 'name'),
      ...await _distinct(db, 'products', 'unit'),
      ...await _distinct(db, 'products', 'secondaryUnit'),
      ...await _distinct(db, 'products', 'tertiaryUnit'),
    ];
    final untagged = await db.rawQuery("SELECT DISTINCT name AS v FROM products WHERE TRIM(searchTag)=''");

    return TranslateValues(
      urduValues(cats),
      urduValues(units),
      urduValues([for (final r in untagged) r['v'] as String]),
    );
  }

  /// Categories + Units ka batch rename (Kotlin `saveAll`). Khali ya badla-na-hua field chhod diya jata hai.
  /// Master row = naya insert (agar English naam pehle se ho to crash nahi) + purana delete, phir har product
  /// mein cascade. Units 3 columns (unit / secondaryUnit / tertiaryUnit) mein cascade hoti hain.
  /// Wapas: kitni values translate hui.
  Future<int> saveTranslations({
    required Map<String, String> categories,
    required Map<String, String> units,
  }) async {
    requireItemsAdmin();
    final db = await AppDatabase.instance.database;
    var count = 0;

    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final touched = <String>{};

      for (final e in categories.entries) {
        final oldVal = e.key;
        final newVal = e.value.trim();
        if (newVal.isEmpty || newVal == oldVal) continue;

        final hit = await txn.query('products', columns: ['barcode'], where: 'category=?', whereArgs: [oldVal]);
        touched.addAll(hit.map((h) => h['barcode'] as String));

        await txn.insert('categories', {'name': newVal}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.delete('categories', where: 'name=?', whereArgs: [oldVal]);
        await txn.update('products', {'category': newVal, 'dirty': 1, 'updatedAt': now},
            where: 'category=?', whereArgs: [oldVal]);
        await enqueueSync(txn, 'category', newVal, 'create', {'name': newVal});
        await enqueueSync(txn, 'category', oldVal, 'delete', {'name': oldVal});
        count++;
      }

      for (final e in units.entries) {
        final oldVal = e.key;
        final newVal = e.value.trim();
        if (newVal.isEmpty || newVal == oldVal) continue;

        final hit = await txn.query(
          'products',
          columns: ['barcode'],
          where: 'unit=? OR secondaryUnit=? OR tertiaryUnit=?',
          whereArgs: [oldVal, oldVal, oldVal],
        );
        touched.addAll(hit.map((h) => h['barcode'] as String));

        await txn.insert('units', {'name': newVal}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.delete('units', where: 'name=?', whereArgs: [oldVal]);
        for (final col in const ['unit', 'secondaryUnit', 'tertiaryUnit']) {
          await txn.update('products', {col: newVal, 'dirty': 1, 'updatedAt': now},
              where: '$col=?', whereArgs: [oldVal]);
        }
        await enqueueSync(txn, 'unit', newVal, 'create', {'name': newVal});
        await enqueueSync(txn, 'unit', oldVal, 'delete', {'name': oldVal});
        count++;
      }

      // Raw UPDATE sync ko khud nahi chhoote — badle hue products (rename ke BAAD wali row) queue mein.
      await enqueueProductUpdates(txn, touched);
    });

    if (count > 0) {
      await ProductRepository.instance.refresh();
      await CategoryRepository.instance.refreshList();
      await UnitRepository.instance.refreshList();
    }
    return count;
  }

  /// Ek product NAAM ka English search tag (Kotlin `saveCurrentItemAndAdvance`): us naam ke woh saare
  /// products jin ka tag abhi khali hai. Jin par pehle se tag ho unhe nahi chhoota. Wapas: kitne products badle.
  Future<int> saveItemTag(String name, String tag) async {
    requireItemsAdmin();
    final clean = tag.trim();
    if (clean.isEmpty) return 0;
    final db = await AppDatabase.instance.database;
    var changed = 0;

    await db.transaction((txn) async {
      final hit = await txn.query('products',
          columns: ['barcode'], where: "name=? AND TRIM(searchTag)=''", whereArgs: [name]);
      final barcodes = hit.map((h) => h['barcode'] as String).toList();
      if (barcodes.isEmpty) return;

      await txn.update(
        'products',
        {'searchTag': clean, 'dirty': 1, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
        where: "name=? AND TRIM(searchTag)=''",
        whereArgs: [name],
      );
      await enqueueProductUpdates(txn, barcodes);
      changed = barcodes.length;
    });

    if (changed > 0) await ProductRepository.instance.refresh();
    return changed;
  }
}
