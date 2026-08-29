import 'dart:async';

import '../models/category_unit.dart' as models;
import 'app_database.dart';

class CategoryRepository {
  CategoryRepository._();
  static final CategoryRepository instance = CategoryRepository._();

  final _controller = StreamController<List<models.Category>>.broadcast();
  bool _primed = false;

  Stream<List<models.Category>> watchAll() {
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

  Future<List<models.Category>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('categories', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(models.Category.fromMap).toList();
  }

  Future<void> insert(models.Category category) async {
    final db = await AppDatabase.instance.database;
    await db.insert('categories', category.toMap());
    await _notify();
  }
}

class UnitRepository {
  UnitRepository._();
  static final UnitRepository instance = UnitRepository._();

  final _controller = StreamController<List<models.UnitType>>.broadcast();
  bool _primed = false;

  Stream<List<models.UnitType>> watchAll() {
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

  Future<List<models.UnitType>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('units', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(models.UnitType.fromMap).toList();
  }

  Future<void> insert(models.UnitType unit) async {
    final db = await AppDatabase.instance.database;
    await db.insert('units', unit.toMap());
    await _notify();
  }
}
