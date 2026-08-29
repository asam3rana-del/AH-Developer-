import 'dart:async';

import '../models/product.dart';
import 'app_database.dart';

/// Dart port of ProductDao (Database.kt). Room's `Flow<List<Product>>` is
/// mirrored here with a broadcast StreamController that re-queries and
/// re-emits every time the table changes — call [_notify] after any write.
class ProductRepository {
  ProductRepository._();
  static final ProductRepository instance = ProductRepository._();

  final _controller = StreamController<List<Product>>.broadcast();
  bool _primed = false;

  /// Mirrors `@Query("SELECT * FROM products ORDER BY name") fun all(): Flow<List<Product>>`.
  Stream<List<Product>> watchAll() {
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

  Future<List<Product>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Product.fromMap).toList();
  }

  /// Mirrors `find(code): Product?`.
  Future<Product?> find(String barcode) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('products', where: 'barcode=?', whereArgs: [barcode], limit: 1);
    if (rows.isEmpty) return null;
    return Product.fromMap(rows.first);
  }

  /// Mirrors `upsert(p: Product)` (OnConflictStrategy.REPLACE).
  Future<void> upsert(Product product) async {
    final db = await AppDatabase.instance.database;
    await db.insert('products', product.toMap());
    await _notify();
  }

  /// Mirrors `delete(p: Product)`.
  Future<void> delete(Product product) async {
    final db = await AppDatabase.instance.database;
    await db.delete('products', where: 'barcode=?', whereArgs: [product.barcode]);
    await _notify();
  }

  void dispose() => _controller.close();
}
