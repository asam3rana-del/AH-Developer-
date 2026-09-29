import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/category_unit_repository.dart';
import '../db/maintenance_sync.dart';
import '../db/product_repository.dart';

/// Pure — Kotlin `DuplicateUnitFix.dedupedName`.
///
/// [raw] bilkul ek hi lafz do baar ho (beech mein koi bhi space/newline, case-insensitive)
/// to ek saaf lafz wapas deta hai, warna null (kuch theek karne ko nahi).
///   "Box\nBox" -> "Box"      "Box Box" -> "Box"     "box   BOX" -> "box" (pehle wala casing)
///   "Box" -> null            "Big Box" -> null (do ALAG lafz — jaan bujh kar chhode gaye)
String? dedupedUnitName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length == 2 && parts[0].toLowerCase() == parts[1].toLowerCase()) {
    return parts[0];
  }
  return null;
}

/// Mirrors DuplicateUnitFix.kt — har product ki Primary / Secondary / Tertiary unit mein
/// "Box\nBox" jaisi doharai dhoondh kar ek saaf lafz bana deta hai (sab categories mein, ek hi baar).
///
/// Ek hi transaction: products ki rows + sync_queue. Dobara chalana bekhatar hai
/// (saaf DB par 0 wapas aata hai).
///
/// Farq (Kotlin se): `units` master list mein bhi agar "Box\nBox" jaisi row ho to wo saaf naam
/// mein badal di jati hai (warna Unit dropdown mein kachra rehta). Wo bhi count mein shamil hai.
class DuplicateUnitFix {
  DuplicateUnitFix._();

  static const _unitColumns = ['unit', 'secondaryUnit', 'tertiaryUnit'];

  /// Kitni unit values theek hui (products ki distinct values + master list ki rows).
  static Future<int> run() async {
    final db = await AppDatabase.instance.database;
    var fixed = 0;

    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final touched = <String>{};

      for (final col in _unitColumns) {
        final rows = await txn.rawQuery('SELECT DISTINCT $col AS v FROM products');
        for (final r in rows) {
          final old = r['v'] as String?;
          if (old == null) continue;
          final clean = dedupedUnitName(old);
          if (clean == null) continue;

          final hit = await txn.query('products', columns: ['barcode'], where: '$col=?', whereArgs: [old]);
          touched.addAll(hit.map((h) => h['barcode'] as String));
          await txn.update('products', {col: clean, 'dirty': 1, 'updatedAt': now}, where: '$col=?', whereArgs: [old]);
          fixed++;
        }
      }

      // Master `units` list ki gandi rows.
      final masters = await txn.query('units');
      for (final m in masters) {
        final old = m['name'] as String;
        final clean = dedupedUnitName(old);
        if (clean == null) continue;
        await txn.insert('units', {'name': clean}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.delete('units', where: 'name=?', whereArgs: [old]);
        await enqueueSync(txn, 'unit', clean, 'create', {'name': clean});
        await enqueueSync(txn, 'unit', old, 'delete', {'name': old});
        fixed++;
      }

      // Raw UPDATE sync ko khud nahi chhoote — badle hue products ab queue mein.
      await enqueueProductUpdates(txn, touched);
    });

    if (fixed > 0) {
      await ProductRepository.instance.refresh();
      await UnitRepository.instance.refreshList();
    }
    return fixed;
  }
}
